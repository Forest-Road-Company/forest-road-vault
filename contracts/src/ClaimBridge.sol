// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {Config} from "./libraries/Config.sol";
import {LossEventIds} from "./libraries/LossEventIds.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ClaimBridge — tokenized facility positions (the CALIBER analog, ADR-0006)
/// @notice Each ERC-721 token is the on-chain position of record for one identified,
///         lien-perfected facility. THE SYNCHRONIZED MINT GATE (CLAUDE.md §1.3): a
///         facility cannot mint unless every attestation kind required for its class is
///         currently satisfied, and the deal-identity attestations (`AssignmentExecuted`,
///         `UCCFiled` and `CreditIssued`) commit to EXACTLY the terms being minted (AUDIT
///         FIX H-4 / P-32 — full payload binding; `Valuation` retains its mark payload), AND all on-chain
///         conditions hold (class active, LTV and maturity within class parameters, every
///         concentration limit respected — checked atomically through the registry).
///         Attestations that merely EXIST at a facility id are not sufficient: they must
///         attest to this obligor, this class, this amount, this tenor and this lien.
///         Escrow release is contractually
///         conditioned off-chain on the existence of this token (legal wrapper §3).
///
///         Positions are transfer-restricted: facilities are held by protocol/SPV
///         custody addresses; transfers require governance execution, and DEFAULTED or
///         ACCELERATED positions are frozen entirely.
contract ClaimBridge is
    Initializable,
    ERC721Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    enum RateType {
        Fixed,
        Variable
    }

    enum DayCountConvention {
        Actual360,
        Actual365,
        Thirty360
    }

    enum LoanState {
        Pending, // minted, awaiting funding
        Active, // funded, performing
        Amortizing, // in scheduled repayment
        Repaid, // closed, made whole
        Defaulted, // default declared — token frozen
        Accelerated, // waterfall shifted to acceleration — token frozen
        Cancelled, // AUDIT FIX (M-02): pending facility retired before funding — NFT burned
        Resolved // AUDIT FIX (M-03): defaulted facility worked out to full principal recovery

    }

    struct Facility {
        uint256 classId;
        bytes32 borrowerId; // stable pseudonymous borrower key (off-chain KYB record)
        bytes32 stateId; // US state key for tax-credit classes (zero elsewhere)
        uint256 principal; // 18-dec
        uint16 ltvBps;
        // Contractual annual rate for THIS facility, supplied and signed per facility.
        uint16 interestRateBps;
        uint64 maturity; // absolute timestamp
        address fundingRecipient; // attested destination; the servicer cannot redirect funding
        uint64 paymentInterval; // contractual seconds between scheduled payments
        uint64 nextPaymentDue; // absolute due date used by permissionless past-due marking
        RateType rateType;
        DayCountConvention dayCountConvention;
        bool renewable;
        bytes32 paymentScheduleHash; // full amortization schedule
        bytes32 rateIndexRef; // required for variable-rate facilities
        bytes32 renewalTermsHash; // required when renewable
        bytes32 offchainRef; // UCC filing / SPV-series / escrow reference hash
        LoanState state;
    }

    struct OriginationTerms {
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 principal;
        uint16 ltvBps;
        uint16 interestRateBps;
        uint64 maturity;
        address fundingRecipient;
        uint64 paymentInterval;
        uint64 nextPaymentDue;
        RateType rateType;
        DayCountConvention dayCountConvention;
        bool renewable;
        bytes32 paymentScheduleHash;
        bytes32 rateIndexRef;
        bytes32 renewalTermsHash;
        bytes32 offchainRef;
    }

    struct Amendment {
        uint16 interestRateBps;
        uint64 maturity;
        uint64 paymentInterval;
        uint64 nextPaymentDue;
        RateType rateType;
        DayCountConvention dayCountConvention;
        bool renewable;
        bytes32 paymentScheduleHash;
        bytes32 rateIndexRef;
        bytes32 renewalTermsHash;
    }

    /// @custom:storage-location erc7201:forestroad.storage.ClaimBridge
    struct BridgeStorage {
        ICollateralRegistry registry;
        IAttestationOracle oracle;
        uint256 nextId;
        mapping(uint256 tokenId => Facility) facilities;
        // per-class required attestation kinds for minting (bitmask over
        // IAttestationOracle.AttestationKind)
        mapping(uint256 classId => uint256) requiredMintAttestations;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.ClaimBridge")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BRIDGE_STORAGE_LOCATION =
        0xc9c2da543a2a10e4b712709fb6548fb2c0c97cecbac3457453966d18f1663f00;

    /// @dev AUDIT FIX (§3.1 reconstructability): carries the full originated terms so
    ///      the register — including WHEN principal is due (`maturity`) and WHICH
    ///      perfected lien backs it (`offchainRef`) — is reconstructable purely from
    ///      events, not only from the mutable `facility()` view.
    event Originated(uint256 indexed tokenId, uint256 indexed classId, bytes32 indexed borrowerId, bytes32 termsHash);
    event NextPaymentDueSet(uint256 indexed tokenId, uint64 previousDue, uint64 nextDue);
    event TermsAmended(uint256 indexed tokenId, bytes32 indexed amendmentId, bytes32 termsHash);
    event StateChanged(uint256 indexed tokenId, LoanState from, LoanState to);
    event RequiredAttestationsSet(uint256 indexed classId, uint256 kindsMask);

    /// @dev Number of `IAttestationOracle.AttestationKind` values. The mint-gate setter and the
    ///      `originate` gate loop BOTH derive from this, so a future kind cannot be accepted by
    ///      governance while remaining unread by the gate (PM-R-09).
    uint256 private constant KIND_COUNT = 9;
    /// @dev Every valid attestation-kind bit set.
    uint256 private constant KINDS_MASK_ALL = (1 << KIND_COUNT) - 1;
    /// @dev AUDIT FIX (H-4): the `CreditIssued` bit. This kind is the TERMS attestation —
    ///      the 2-of-n quorum that authorizes an amount for a counterparty — so it is
    ///      mandatory in every class's mint gate and its payload is bound in `originate`.
    uint256 private constant BIT_CREDIT_ISSUED = 1 << uint256(uint8(IAttestationOracle.AttestationKind.CreditIssued));

    error Bridge_ZeroAddress();
    /// @notice A mint-gate mask carried bits outside the known `AttestationKind` range, or was
    ///         empty. Either would leave the gate weaker than it reads (PM-R-09).
    /// @param kindsMask The rejected mask.
    error Bridge_BadAttestationMask(uint256 kindsMask);
    error Bridge_BadFacility();
    error Bridge_AttestationMissing(uint256 classId, IAttestationOracle.AttestationKind kind);
    /// @notice AUDIT FIX (H-4): the currently-satisfied `CreditIssued` attestation at this
    ///         facility id does not commit to THESE terms. Either no terms were attested, or
    ///         the attested terms describe a different obligor/class/amount/tenor/lien.
    /// @param facilityId The facility id the gate read.
    /// @param expected The terms hash of the facility being originated/funded.
    /// @param attested The terms hash actually carried by the attestation (zero if none).
    error Bridge_TermsNotAttested(uint256 facilityId, bytes32 expected, bytes32 attested);
    /// @notice A deal-identity attestation is present but commits to different terms.
    /// @param classId The collateral class whose mint gate failed.
    /// @param kind The deal-identity attestation kind.
    /// @param expected The terms hash of the facility being originated/funded.
    /// @param attested The terms hash carried by the attestation.
    error Bridge_AttestationNotBoundToDeal(
        uint256 classId, IAttestationOracle.AttestationKind kind, bytes32 expected, bytes32 attested
    );
    error Bridge_ValuationStale(uint256 tokenIdOrZero, uint64 asOf, uint64 maxAge);
    error Bridge_LtvExceedsValue(uint256 principal, uint256 maxByValue);
    error Bridge_InvalidTransition(uint256 tokenId, LoanState from, LoanState to);
    error Bridge_PositionFrozen(uint256 tokenId);
    error Bridge_TransferRestricted();
    error Bridge_UnknownToken(uint256 tokenId);
    error Bridge_FacilityMatured(uint256 tokenId);
    error Bridge_ClassInactive(uint256 classId);
    error Bridge_NotPending(uint256 tokenId);
    error Bridge_TermsAmendmentNotAttested(uint256 tokenId);
    error Bridge_FacilityEventNamespaceExhausted(uint256 nextId);

    uint16 public constant MAX_INTEREST_RATE_BPS = 10_000;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the position register.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param registry The collateral registry (class params + concentration).
    /// @param oracle The attestation oracle (mint gate; ADR-0007 trust note applies).
    function initialize(address admin, address guardian, address upgrader, address registry, address oracle)
        external
        initializer
    {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || registry == address(0)
                || oracle == address(0)
        ) revert Bridge_ZeroAddress();
        __ERC721_init("Forest Road Facility", "frFACILITY");
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        BridgeStorage storage $ = _storage();
        $.registry = ICollateralRegistry(registry);
        $.oracle = IAttestationOracle(oracle);
        $.nextId = 1;
    }

    // ── governance ───────────────────────────────────────────────────────

    /// @notice Sets the attestation kinds required to mint a facility of `classId`
    ///         (bitmask over AttestationKind). Timelocked governance only.
    /// @dev AUDIT FIX (PM-R-09). Previously ANY `uint256` was stored, while `originate` only ever
    ///      reads bits `0..KIND_COUNT-1`. A mask carrying a high bit therefore READ stricter than
    ///      it behaved — the silent fail-open class this protocol has been bitten by before. Two
    ///      rejections now, both fail-loud:
    ///        - bits outside the known `AttestationKind` range: a governance typo can no longer
    ///          silently widen the mint gate;
    ///        - an EMPTY mask: a zero gate makes the §1.3 "NFT mint gate" invariant vacuous for
    ///          that class (a facility could mint with NO attested off-chain fact at all).
    ///          `Validate.s.sol` already asserts every class's gate is non-zero; this makes the
    ///          contract enforce what validation merely checked after the fact.
    ///
    ///      AUDIT FIX (H-4): a mask omitting `CreditIssued` is now rejected as well. `originate`
    ///      binds the facility's TERMS to the `CreditIssued` payload unconditionally, so a class
    ///      whose declared gate omitted that bit would read weaker than it behaves — and, before
    ///      the binding existed, such a class (the digital-assets class) had NO attested amount
    ///      or counterparty at all.
    /// @param classId The collateral class.
    /// @param kindsMask Bitmask over `AttestationKind`; must be within `KINDS_MASK_ALL` and
    ///        must include the `CreditIssued` bit.
    function setRequiredMintAttestations(uint256 classId, uint256 kindsMask) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (kindsMask & ~KINDS_MASK_ALL != 0 || kindsMask & BIT_CREDIT_ISSUED == 0) {
            revert Bridge_BadAttestationMask(kindsMask);
        }
        _storage().requiredMintAttestations[classId] = kindsMask;
        emit RequiredAttestationsSet(classId, kindsMask);
    }

    // ── origination (THE synchronized mint gate) ─────────────────────────

    /// @notice Mints the position NFT for an underwritten facility — ONLY if every
    ///         off-chain condition (required attestations, with every deal-identity quorum
    ///         committing to EXACTLY these terms) AND on-chain condition (class params,
    ///         LTV, maturity, concentration) holds. Escrow releases off-chain only after
    ///         this token exists.
    /// @dev AUDIT FIX (H-4) — FULL PAYLOAD BINDING. The gate previously proved only that
    ///      attestations EXISTED at the facility id it was about to mint; it never proved
    ///      they attested to the facility's TERMS. Two consequences, both measured:
    ///        - SEQUENCE DESYNC: `nextId` only advances on a SUCCESSFUL mint, so a reverted
    ///          or reordered origination left a fully-attested bundle sitting at the id the
    ///          next call would read. A completely unattested borrower could then originate
    ///          against another obligor's attestations (and, for a marked-to-market class,
    ///          against another obligor's appraisal).
    ///        - UNBOUNDED PRINCIPAL: for the four Receivable classes nothing on-chain bound
    ///          the amount at all — `ltvBps <= maxLtvBps` is a ratio with no denominator —
    ///          so a bundle diligenced for a $500k receivable could mint any principal.
    ///      Both close by requiring the deal-identity payloads to equal
    ///      `creditTermsHash(...)` over the exact terms being minted. `Valuation` is excluded
    ///      because its payload is the mark. This reuses the
    ///      `latestPayload` primitive already used by the attestation consumers. Note the attested principal IS the on-chain principal bound:
    ///      the amount is now a signed term, not an originator-chosen input, so the LTV
    ///      ratio's denominator (`principal * BPS / ltvBps`) is attested too.
    /// @param holder Custody address for the position (SPV series custodian).
    /// @param terms Complete contractual and operational facility terms.
    /// @return tokenId The minted facility id.
    function originate(address holder, OriginationTerms calldata terms)
        external
        onlyRole(Roles.ORIGINATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        Facility memory f;
        f.classId = terms.classId;
        f.borrowerId = terms.borrowerId;
        f.stateId = terms.stateId;
        f.principal = terms.principal;
        f.ltvBps = terms.ltvBps;
        f.interestRateBps = terms.interestRateBps;
        f.maturity = terms.maturity;
        f.fundingRecipient = terms.fundingRecipient;
        f.paymentInterval = terms.paymentInterval;
        f.nextPaymentDue = terms.nextPaymentDue;
        f.rateType = terms.rateType;
        f.dayCountConvention = terms.dayCountConvention;
        f.renewable = terms.renewable;
        f.paymentScheduleHash = terms.paymentScheduleHash;
        f.rateIndexRef = terms.rateIndexRef;
        f.renewalTermsHash = terms.renewalTermsHash;
        f.offchainRef = terms.offchainRef;
        f.state = LoanState.Pending;
        return _originate(holder, f);
    }

    /// @dev The external ABI deliberately exposes each signed term separately. Packing them
    ///      into the already-storage-compatible `Facility` shape here keeps the gate below
    ///      Solidity's stack limit without weakening or duplicating any validation.
    function _originate(address holder, Facility memory f) private returns (uint256 tokenId) {
        BridgeStorage storage $ = _storage();
        if (holder == address(0)) revert Bridge_ZeroAddress();
        // Facility defaults and protocol custody incidents share SGrove's uint256 event key.
        // Confining sequential facility ids to the lower half makes the upper incident namespace
        // structurally disjoint without changing any existing id or increment semantics.
        if (!LossEventIds.isFacilityEvent($.nextId)) {
            revert Bridge_FacilityEventNamespaceExhausted($.nextId);
        }
        if (
            // State concentration is meaningful for tax-credit facilities only. A tax-credit
            // origination must carry a state key; every other class must carry none, or the
            // registry's state dimension is either bypassed or polluted by an unrelated class.
            f.principal == 0 || f.borrowerId == bytes32(0) || f.fundingRecipient == address(0) || f.interestRateBps == 0
                || f.interestRateBps > MAX_INTEREST_RATE_BPS || f.paymentInterval == 0
                || f.paymentScheduleHash == bytes32(0) || f.offchainRef == bytes32(0)
                || ((f.classId == Config.CLASS_FILM_TAX_CREDITS) == (f.stateId == bytes32(0)))
        ) revert Bridge_BadFacility();

        // ── on-chain conditions ───────────────────────────────────────────
        ICollateralRegistry.ClassParams memory p = $.registry.classParams(f.classId);
        if (f.ltvBps == 0 || f.ltvBps > p.maxLtvBps) revert Bridge_BadFacility();
        if (f.maturity <= block.timestamp || f.maturity > block.timestamp + p.maxMaturity) {
            revert Bridge_BadFacility();
        }
        if (f.nextPaymentDue <= block.timestamp || f.nextPaymentDue > f.maturity) revert Bridge_BadFacility();
        if (f.rateType == RateType.Variable && f.rateIndexRef == bytes32(0)) revert Bridge_BadFacility();
        if (f.rateType == RateType.Fixed && f.rateIndexRef != bytes32(0)) revert Bridge_BadFacility();
        if (f.renewable != (f.renewalTermsHash != bytes32(0))) revert Bridge_BadFacility();

        // ── off-chain conditions: required attestations, all satisfied NOW ─
        // AUDIT FIX (P-32): every deal-identity attestation is bound to the same terms hash.
        // Valuation is deliberately excluded: its payload is the mark, not a deal identity.
        _requireMintAttestations($, f.classId, $.nextId, _creditTermsHash(f));

        // ── marked-to-market extension (ADR-0015): fresh mark, value-bounded draw ─
        if (p.model == ICollateralRegistry.CollateralModel.MarkedToMarket) {
            (uint256 value, uint64 asOf) = $.oracle.latestValuation($.nextId);
            if (asOf == 0 || block.timestamp - asOf > p.maxMarkAge) {
                revert Bridge_ValuationStale(0, asOf, p.maxMarkAge);
            }
            uint256 maxByValue = value * f.ltvBps / Config.BPS;
            if (f.principal > maxByValue) revert Bridge_LtvExceedsValue(f.principal, maxByValue);
        }

        // ── concentration: enforced atomically in the registry ────────────
        $.registry.recordExposureIncrease(f.classId, f.borrowerId, f.stateId, f.principal);

        tokenId = $.nextId++;
        $.facilities[tokenId] = f;
        _safeMint(holder, tokenId);
        emit Originated(tokenId, f.classId, f.borrowerId, _creditTermsHash(f));
    }

    /// @notice Re-validates that a PENDING facility still satisfies its origination gate
    ///         immediately before funding (AUDIT FIX M-01). Origination checks are
    ///         point-in-time; a facility can sit pending while state decays. This re-runs
    ///         the time-sensitive gates — class still active, maturity and the first payment
    ///         due date not passed, every required attestation STILL satisfied (a revoked one
    ///         now blocks funding), and
    ///         for a marked-to-market class the mark still fresh and the draw still within
    ///         the value bound — so capital never deploys against stale/expired state.
    ///         Reverts on the first failure; `WaterfallEngine.fund` calls it before deploying.
    /// @dev AUDIT FIX (H-4): re-runs the TERMS BINDING too, against the terms actually stored on
    ///      the token. Fixing only `originate` would leave the funding path open — this function
    ///      repeated the same existence-only read, so a facility whose `CreditIssued` quorum was
    ///      revoked and re-attested to different terms could still draw capital.
    /// @param tokenId The pending facility about to be funded.
    function checkFundable(uint256 tokenId) external view {
        BridgeStorage storage $ = _storage();
        Facility storage f = _facility($, tokenId);
        if (f.state != LoanState.Pending) revert Bridge_NotPending(tokenId);
        ICollateralRegistry.ClassParams memory p = $.registry.classParams(f.classId);
        if (!p.active) revert Bridge_ClassInactive(f.classId);
        if (f.maturity <= block.timestamp) revert Bridge_FacilityMatured(tokenId);
        if (f.nextPaymentDue <= block.timestamp) revert Bridge_BadFacility();

        // AUDIT FIX (P-32): re-check every deal-identity attestation against the stored terms;
        // Valuation retains its mark payload and is checked below by its own freshness/value limb.
        _requireMintAttestations($, f.classId, tokenId, _creditTermsHash(f));

        if (p.model == ICollateralRegistry.CollateralModel.MarkedToMarket) {
            (uint256 value, uint64 asOf) = $.oracle.latestValuation(tokenId);
            if (asOf == 0 || block.timestamp - asOf > p.maxMarkAge) {
                revert Bridge_ValuationStale(tokenId, asOf, p.maxMarkAge);
            }
            uint256 maxByValue = value * f.ltvBps / Config.BPS;
            if (f.principal > maxByValue) revert Bridge_LtvExceedsValue(f.principal, maxByValue);
        }
    }

    /// @notice Retires a PENDING facility that will never be funded (AUDIT FIX M-02):
    ///         atomically reverses its recorded book exposure and burns the position NFT,
    ///         so an abandoned or erroneous origination cannot permanently consume
    ///         class/borrower/state/total concentration headroom. Pending only — a funded
    ///         facility must run its lifecycle. Originator-gated (symmetric with mint).
    function cancelPending(uint256 tokenId) external onlyRole(Roles.ORIGINATOR_ROLE) nonReentrant {
        BridgeStorage storage $ = _storage();
        Facility storage f = _facility($, tokenId);
        if (f.state != LoanState.Pending) revert Bridge_NotPending(tokenId);
        // release exposure BEFORE burning: same-tx reversal keeps the concentration book
        // and the NFT set describing the same reality (registry decrease is CREDIT_ROLE,
        // which the bridge already holds for origination's increase).
        $.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, f.principal);
        f.state = LoanState.Cancelled;
        emit StateChanged(tokenId, LoanState.Pending, LoanState.Cancelled);
        _burn(tokenId);
    }

    // ── lifecycle state machine ──────────────────────────────────────────

    /// @notice Advances a facility's lifecycle. Only the credit layer (CREDIT_ROLE —
    ///         WaterfallEngine/DefaultManager in Phase E). Transitions are a strict
    ///         guarded machine; anything else reverts.
    function transitionState(uint256 tokenId, LoanState to) external onlyRole(Roles.CREDIT_ROLE) nonReentrant {
        BridgeStorage storage $ = _storage();
        Facility storage f = _facility($, tokenId);
        LoanState from = f.state;
        bool ok = (from == LoanState.Pending && to == LoanState.Active)
            || (from == LoanState.Active && to == LoanState.Amortizing)
            || ((from == LoanState.Active || from == LoanState.Amortizing) && to == LoanState.Repaid)
            || ((from == LoanState.Active || from == LoanState.Amortizing) && to == LoanState.Defaulted)
            || (from == LoanState.Defaulted && to == LoanState.Accelerated)
        // AUDIT FIX (M-03): a defaulted/accelerated facility that recovers its full
        // outstanding principal closes out to Resolved and unfreezes the position.
        || ((from == LoanState.Defaulted || from == LoanState.Accelerated) && to == LoanState.Resolved);
        if (!ok) revert Bridge_InvalidTransition(tokenId, from, to);
        f.state = to;
        emit StateChanged(tokenId, from, to);
    }

    /// @notice Advances the due date after an exact, attested payment.
    function setNextPaymentDue(uint256 tokenId, uint64 nextDue) external onlyRole(Roles.CREDIT_ROLE) nonReentrant {
        BridgeStorage storage $ = _storage();
        Facility storage f = _facility($, tokenId);
        if (f.state != LoanState.Active && f.state != LoanState.Amortizing) {
            revert Bridge_InvalidTransition(tokenId, f.state, f.state);
        }
        uint64 previous = f.nextPaymentDue;
        if (nextDue <= previous || nextDue > f.maturity) revert Bridge_BadFacility();
        f.nextPaymentDue = nextDue;
        emit NextPaymentDueSet(tokenId, previous, nextDue);
    }

    /// @notice Applies a quorum-attested servicing amendment or renewal.
    function amendTerms(uint256 tokenId, bytes32 amendmentId, Amendment calldata a)
        external
        onlyRole(Roles.ORIGINATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        BridgeStorage storage $ = _storage();
        Facility storage f = _facility($, tokenId);
        if (f.state != LoanState.Active && f.state != LoanState.Amortizing) revert Bridge_BadFacility();
        ICollateralRegistry.ClassParams memory p = $.registry.classParams(f.classId);
        if (
            amendmentId == bytes32(0) || a.interestRateBps == 0 || a.interestRateBps > MAX_INTEREST_RATE_BPS
                || a.paymentInterval == 0 || a.nextPaymentDue <= block.timestamp || a.nextPaymentDue > a.maturity
                || a.maturity <= block.timestamp || a.maturity > block.timestamp + p.maxMaturity
                || a.paymentScheduleHash == bytes32(0)
        ) revert Bridge_BadFacility();
        if (a.maturity > f.maturity && !f.renewable) revert Bridge_BadFacility();
        if (a.rateType == RateType.Variable && a.rateIndexRef == bytes32(0)) revert Bridge_BadFacility();
        if (a.rateType == RateType.Fixed && a.rateIndexRef != bytes32(0)) revert Bridge_BadFacility();
        if (a.renewable != (a.renewalTermsHash != bytes32(0))) revert Bridge_BadFacility();

        bytes32 expected = keccak256(abi.encode(amendmentId, tokenId, a));
        (bytes32 payload,, bool ok) = $.oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.TermsAmended);
        if (!ok || payload != expected) revert Bridge_TermsAmendmentNotAttested(tokenId);
        $.oracle.consume(tokenId, IAttestationOracle.AttestationKind.TermsAmended);

        f.interestRateBps = a.interestRateBps;
        f.maturity = a.maturity;
        f.paymentInterval = a.paymentInterval;
        f.nextPaymentDue = a.nextPaymentDue;
        f.rateType = a.rateType;
        f.dayCountConvention = a.dayCountConvention;
        f.renewable = a.renewable;
        f.paymentScheduleHash = a.paymentScheduleHash;
        f.rateIndexRef = a.rateIndexRef;
        f.renewalTermsHash = a.renewalTermsHash;
        emit TermsAmended(tokenId, amendmentId, _creditTermsHash(f));
    }

    // ── views ────────────────────────────────────────────────────────────

    /// @notice Full facility record (reverts for unknown tokens).
    function facility(uint256 tokenId) external view returns (Facility memory) {
        return _facility(_storage(), tokenId);
    }

    /// @notice The `CreditIssued` payload an attester quorum must sign to authorize a facility
    ///         on EXACTLY these terms (AUDIT FIX H-4). Attester tooling and the mint gate derive
    ///         the commitment from this one function, so they cannot drift apart.
    /// @dev The facility id is NOT in the preimage because it is the oracle record's key and is
    ///      already covered by the EIP-712 digest (`AttestationOracle.attest` hashes
    ///      `a.facilityId`). The per-facility interest rate IS in the preimage: pricing is a
    ///      signed loan term, not a collateral-class parameter.
    /// @param terms Complete contractual and operational facility terms.
    /// @return The terms commitment.
    function creditTermsHash(OriginationTerms calldata terms) external pure returns (bytes32) {
        return keccak256(abi.encode(terms));
    }

    function _creditTermsHash(Facility memory f) private pure returns (bytes32) {
        OriginationTerms memory t = OriginationTerms({
            classId: f.classId,
            borrowerId: f.borrowerId,
            stateId: f.stateId,
            principal: f.principal,
            ltvBps: f.ltvBps,
            interestRateBps: f.interestRateBps,
            maturity: f.maturity,
            fundingRecipient: f.fundingRecipient,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash,
            offchainRef: f.offchainRef
        });
        return keccak256(abi.encode(t));
    }

    /// @notice Required mint-attestation mask for a class.
    function requiredMintAttestations(uint256 classId) external view returns (uint256) {
        return _storage().requiredMintAttestations[classId];
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules() external view returns (address registry, address oracle) {
        BridgeStorage storage $ = _storage();
        return (address($.registry), address($.oracle));
    }

    /// @notice Total facilities ever originated.
    function totalOriginated() external view returns (uint256) {
        return _storage().nextId - 1;
    }

    // ── guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses origination. Emergency use only.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses origination.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── internals ────────────────────────────────────────────────────────

    /// @dev Transfer restriction: positions move only under governance execution
    ///      (custody changes are legal events), and NEVER while frozen
    ///      (Defaulted/Accelerated) — the on-chain half of the dual-record freeze.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        BridgeStorage storage $ = _storage();
        address owner = _ownerOf(tokenId);
        if (owner != address(0)) {
            LoanState st = $.facilities[tokenId].state;
            if (st == LoanState.Defaulted || st == LoanState.Accelerated) revert Bridge_PositionFrozen(tokenId);
            if (to != address(0) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Bridge_TransferRestricted();
        }
        return super._update(to, tokenId, auth);
    }

    /// @dev AUDIT FIX (P-32). Requires every selected mint-gate attestation to be currently
    ///      satisfied. AssignmentExecuted, UCCFiled and CreditIssued are deal identity facts and
    ///      must carry the exact `creditTermsHash`; Valuation is intentionally left on its own mark
    ///      payload and checked by the marked-to-market branch.
    function _requireMintAttestations(BridgeStorage storage $, uint256 classId, uint256 facilityId, bytes32 termsHash)
        private
        view
    {
        uint256 mask = $.requiredMintAttestations[classId];
        // Preserve the original missing-attestation precedence: a present bit is checked before
        // any payload comparison, so a genuinely absent documentary fact remains
        // `Bridge_AttestationMissing` rather than looking like a malformed commitment.
        for (uint256 k = 0; k < KIND_COUNT; ++k) {
            if (mask & (1 << k) == 0) continue;
            IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(uint8(k));
            (,, bool ok) = $.oracle.latestPayload(facilityId, kind);
            if (!ok) revert Bridge_AttestationMissing(classId, kind);
        }

        // Check the existing terms-quorum limb first to preserve H-4's established error surface.
        // Documentary payloads are then checked below; P-32 adds those checks without changing the
        // diagnostics callers already receive for a mismatched CreditIssued bundle.
        if (mask & BIT_CREDIT_ISSUED != 0) {
            (bytes32 payload,,) = $.oracle.latestPayload(facilityId, IAttestationOracle.AttestationKind.CreditIssued);
            if (payload != termsHash) {
                revert Bridge_TermsNotAttested(facilityId, termsHash, payload);
            }
        }

        for (uint256 k = 0; k < KIND_COUNT; ++k) {
            if (mask & (1 << k) == 0) continue;
            IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(uint8(k));
            if (_isDealIdentityKind(kind) && kind != IAttestationOracle.AttestationKind.CreditIssued) {
                (bytes32 payload,,) = $.oracle.latestPayload(facilityId, kind);
                if (payload != termsHash) {
                    revert Bridge_AttestationNotBoundToDeal(classId, kind, termsHash, payload);
                }
            }
        }
    }

    function _isDealIdentityKind(IAttestationOracle.AttestationKind kind) private pure returns (bool) {
        return kind == IAttestationOracle.AttestationKind.AssignmentExecuted
            || kind == IAttestationOracle.AttestationKind.UCCFiled
            || kind == IAttestationOracle.AttestationKind.CreditIssued;
    }

    function _facility(BridgeStorage storage $, uint256 tokenId) private view returns (Facility storage f) {
        if (tokenId == 0 || tokenId >= $.nextId) revert Bridge_UnknownToken(tokenId);
        f = $.facilities[tokenId];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (BridgeStorage storage $) {
        assembly {
            $.slot := BRIDGE_STORAGE_LOCATION
        }
    }
}
