// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IContinuousAccrual} from "./interfaces/IContinuousAccrual.sol";
import {IAccrualRisk, IAccrualRoundingRisk} from "./interfaces/IAccrualLifecycle.sol";
import {DefaultBackstopLib} from "./libraries/DefaultBackstopLib.sol";
import {DefaultAccrualLib} from "./libraries/DefaultAccrualLib.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPausableModule} from "./interfaces/IMintRedeemController.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ClaimBridge} from "./ClaimBridge.sol";
import {CommitmentLedgerFactory} from "./CommitmentLedgerFactory.sol";
import {ConservativeImpairmentMath} from "./ConservativeImpairmentMath.sol";
import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {ICascadeBackstop} from "./interfaces/ICascadeBackstop.sol";
import {ICommitmentLedger} from "./interfaces/ICommitmentLedger.sol";
import {ICommitmentPrincipalSource} from "./interfaces/ICommitmentPrincipalSource.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {IDefaultManager} from "./interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveLossAbsorber} from "./interfaces/IReserveLossAbsorber.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {DefaultInitLib} from "./libraries/DefaultInitLib.sol";
import {DefaultLossLib} from "./libraries/DefaultLossLib.sol";
import {LossEventIds} from "./libraries/LossEventIds.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title DefaultManager — remedies and the three-layer loss cascade
/// @notice RECEIVABLE classes: `declareDefault` freezes the position (the on-chain half
///         of the dual-record freeze) and emits `RemedyInitiated` with the class's
///         legal-wrapper remedy reference — the trigger for off-chain UCC enforcement.
///         MARKED-TO-MARKET class (ADR-0015): a fast, PERMISSIONLESS margin path —
///         anyone may `marginCall`/`liquidate` because the attested mark is the whole
///         evidence; the protocol just checks thresholds. Freshness asymmetry is
///         deliberate and protocol-protective: protective triggers accept the latest
///         mark at any age, while CURING a margin call demands a fresh mark within the
///         class's `maxMarkAge`.
///
///         THE CASCADE (CLAUDE.md §1.3 ordering, ADR-0014): `realizeLoss` burns, in one
///         transaction and in strict order — curator first-loss → sGROVE backstop →
///         sUSDfr vault principal — and pairs the burns with the principal write-down
///         so supply and backing fall together (ADR-0012). No layer is skippable: the
///         curator pool is always drained to its balance before the backstop is asked,
///         and the backstop before any depositor impairment.
/// @dev Pause policy: only the PERMISSIONLESS triggers (marginCall/clearMarginCall/
///      liquidate) are pausable — the guardian's lever if the oracle misbehaves. The
///      manager pause does not gate declareDefault/accelerate/realizeLoss. Owner policy
///      requires completed legacy PIK posting before default; paused posting dependencies
///      therefore block that declaration until servicing resumes.
contract DefaultManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IDefaultManager,
    ICommitmentPrincipalSource,
    IAccrualRisk,
    IAccrualRoundingRisk
{
    // Native backstop capability probes live in DefaultBackstopLib.

    /// @custom:storage-location erc7201:forestroad.storage.DefaultManager
    struct DefaultStorage {
        ClaimBridge bridge;
        ICollateralRegistry registry;
        IReserveManager reserves;
        IMintRedeemController controller;
        ICuratorModule curator;
        IAttestationOracle oracle;
        IERC20 usdfr;
        address vault; // sUSDfr — cascade layer 3
        ICascadeBackstop backstop; // sGROVE — cascade layer 2 (zero until Phase H)
        mapping(uint256 tokenId => uint64) cureDeadlines; // 0 = no active margin call
        mapping(uint256 classId => bytes32) remedyRefs;
        mapping(uint256 classId => uint64) cureWindows;
        // Recorded face of declared facilities, including their recognized income. Declaration,
        // opening migration, cash recoveries, realized losses and resolution keep these class
        // totals equal to the sum of live per-facility contributions and ledger rows.
        mapping(uint256 classId => uint256) declaredDefaultedPrincipal;
        mapping(uint256 tokenId => uint256) defaultedContribution;
        // ── Historical PM-R-11 per-event observability (append-only layout) ──
        // ADR-0035 makes consumed coverage self-reflecting in the physical reserve, so the mark no
        // longer deducts this aggregate. The per-token and aggregate values remain for audit
        // history and are released when a default closes.
        mapping(uint256 tokenId => uint256) coverageConsumedByDefault;
        uint256 liveDefaultCoverageConsumed;
        // ── DEPRECATED BY THE SWEEP-3 F-S3-01 LEDGER — READ BY NOTHING, WRITTEN BY NOTHING ──
        // Formerly "the smallest backstop capacity observed at any draw by a still-live default",
        // used as an INFERRED PROXY for what the drawn cohort could still reach. It cannot be one:
        // a MINIMUM over per-event ceilings, minus a SUM over per-event draws, is not any event's
        // availability, and the subtraction charged the first event's consumption to every later
        // one (see `coverageRemainingByDefault` at the tail for the measurement). Replaced by the
        // exact event ledger below. ADR-0035 subsequently removed event-owned ceilings entirely;
        // that ledger now carries demand and class/order metadata while applying one live reserve.
        //
        // THE SLOT STAYS DECLARED, UNDER ITS ORIGINAL NAME, AND STAYS HERE. Removing it would shift
        // every field after it and RENAMING it reads to the storage gates as a removal plus an
        // insertion in the middle — both are layout BREAKS on a UUPS proxy, which is exactly what
        // those gates exist to refuse. It reads as whatever the last pre-fix write left behind
        // (zero on a fresh deployment) and no code path may read it again.
        uint256 liveDefaultCapacityFloor;
        // Reversible risk marks for performing receivables past their governed grace window.
        // Posted and virtual accrued income remain in the risk view. Cure, repayment and native
        // rounding corrections reduce the mark; declaration transfers it to declared risk once.
        mapping(uint256 classId => uint64) graceWindows;
        mapping(uint256 tokenId => bool) pastDueMarked;
        uint256 pastDueExposure;
        mapping(uint256 tokenId => uint256) pastDueContribution;
        mapping(uint256 classId => uint256) pastDuePrincipal;
        // ── ADR-0027: assessment invalidation (append-only TAIL) ─────────────
        // Monotonic even when aggregate risk amounts later return to their previous values, so an
        // assessment made before an intervening default/past-due/recovery event cannot resurrect.
        uint256 impairmentRevision;
        // Historical F-18-01 drawn-cohort accounting, retained for layout and observability.
        // ADR-0035 removes the frozen per-event cap, so the conservative mark no longer gives this
        // cohort a distinct layer-2 formula; every live event reaches the same shared reserve.
        mapping(uint256 classId => uint256) drawnDefaultPrincipal;
        // ── OWNER DECISION 2026-08-07 (G2W): the unattested-past-due RELIEF CLOCK ────────
        // (append-only TAIL; must stay last.) When the UNATTESTED past-due cohort last went
        // EMPTY -> non-empty. `ConservativeImpairmentMath` ramps the cohort's forward weight from
        // the governed launch weight (`CollateralRegistry.pastDueWeightBps`) back to FULL over one
        // `Config.DEFAULT_REDEEM_COOLDOWN` measured from here — a benefit of the doubt WITH AN
        // EXPIRY, so an unattested mark is lighter than an attested default only for as long as
        // the servicer plausibly has not yet had time to attest.
        //
        // ZERO IS THE FAIL-SAFE, DELIBERATELY. This slot is appended to a namespaced struct, so it
        // reads zero on every proxy upgraded from a pre-G2W implementation and on any path that
        // somehow reaches the ramp without a mark. `block.timestamp - 0` is always >= the ramp
        // length, which yields FULL weight — i.e. the pre-G2W behaviour, the conservative one. An
        // unset anchor must never be readable as "freshly marked, maximum relief".
        //
        // WHY THIS IS ONE GLOBAL SLOT AND NOT A PER-CLASS MAPPING — reviewed and kept, see the
        // COHORT CLOCK note on `ConservativeImpairmentMath.pendingSeniorImpairment`.
        //
        // `uint256`, NOT `uint64`, DELIBERATELY. It occupies a whole slot either way (the field
        // before it is a mapping, so there is nothing to pack with), so the narrow type would buy
        // no storage and would add a mask on every read plus a truncating cast on the write.
        uint256 pastDueReliefAnchor;
        // Historical per-event coverage slots retained in place for upgrade safety. ADR-0035
        // removes event-owned ceilings; the standalone ledger records the remaining-principal
        // claim of a drawn event while applying the one physical reserve during its cascade walk.
        mapping(uint256 tokenId => uint256) coverageRemainingByDefault;
        uint256 liveDefaultCoverageRemaining;
        // ── AUDIT FIX (SWEEP-3 S3-F3): THE PAYMENT-EPISODE RELIEF CLOCK (append-only TAIL) ──
        // (must stay last.) The G2W relief ramp is a benefit of the doubt extended to ONE
        // DELINQUENT PAYMENT EPISODE. An episode is identified by the OBJECTIVE, servicer-attested
        // fact that defines it: the pair (`tokenId`, `ClaimBridge.Facility.nextPaymentDue`). This
        // per-facility record is the SOURCE OF TRUTH for when that episode's relief began, and it
        // is PERSISTENT — it survives `clearPastDue`, `declareDefault` and every re-mark.
        //
        // `due` IS A HIGH-WATER MARK, NOT A COPY. It only ever ratchets UP, so relief can only be
        // restarted by an event that ADVANCES the due date: `WaterfallEngine.distribute` ->
        // `ClaimBridge.setNextPaymentDue` (an attested performing payment; the bridge itself
        // enforces `nextDue > previous`) or `ClaimBridge.amendTerms` (a `TermsAmended` quorum).
        // Both are authenticated servicing transitions. Bookkeeping that does NOT advance the due
        // date — `clearPastDue`, `onPerformingRepayment`'s partial re-anchor, a bystander re-mark —
        // leaves `due` alone, so `startedAt` is REUSED and the relief keeps decaying from where it
        // was. That is the whole fix: see the block in `markPastDue`.
        //
        // uint64 EACH, PACKED INTO ONE SLOT DELIBERATELY. `nextPaymentDue` is already `uint64` on
        // `ClaimBridge.Facility`, and a `uint64` unix second overflows in the year 584,942,417,355.
        // One slot is one `SSTORE` on the only path that writes it.
        //
        // ZERO IS THE FAIL-SAFE. A never-marked facility reads `(0, 0)`; `nextPaymentDue` is
        // required to be strictly greater than `block.timestamp` at origination and amendment, so
        // it is always non-zero and the FIRST mark of any facility always takes the fresh-episode
        // branch. A `startedAt` that somehow read zero would make the registry compute
        // `elapsed == block.timestamp`, which is past the ramp, i.e. FULL weight — conservative.
        mapping(uint256 tokenId => ReliefEpisode) reliefEpisode;
        // ── F1 standalone commitment ledger (append-only TAIL) ────────────────
        // The ledger owns per-event remaining principal and class/draw metadata. Keeping the
        // shared-reserve cascade walk outside this implementation preserves the EIP-170 margin
        // while the address tail leaves every pre-existing ERC-7201 field in place.
        ICommitmentLedger commitmentLedger;
        // Optional legacy PIK settlement route, also checked when the native source is bound.
        // A zero address bypasses the legacy settlement call before marking a late facility.
        IPausableModule waterfall;
        // Permanent native accrual source, tail appended for the live proxy.
        IContinuousAccrual accrualReserve;
    }

    /// @dev AUDIT FIX (SWEEP-3 S3-F3). One delinquent payment episode's relief clock. Stored only
    ///      as a mapping VALUE (never embedded), so the storage gate permits a tail append here.
    /// @custom:member due The high-water `ClaimBridge.Facility.nextPaymentDue` this episode is keyed
    ///         to. Monotone non-decreasing; only an advance opens a new episode.
    /// @custom:member startedAt The timestamp of the FIRST `markPastDue` of that episode. Reused by
    ///         every later re-mark of the same episode, which is what makes the ramp's expiry
    ///         un-rewindable by clear-and-re-mark.
    struct ReliefEpisode {
        uint64 due;
        uint64 startedAt;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.DefaultManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DEFAULT_STORAGE_LOCATION =
        0x336a2060fa754acf2cdfdb8c351983bf3b455537ad219c0e1b705a95a2f8a200;

    /// @dev ADR-0034 Y-bis standing key for senior-exit coverage observability. ADR-0035 removes
    ///      all capacity semantics from the key: each exit draws from the same live reserve and a
    ///      replenishment is immediately available. The fixed namespace remains so historical
    ///      cumulative draws stay reconstructable and cannot collide with facility token ids.
    uint256 private constant SENIOR_EXIT_EVENT_ID = LossEventIds.CUSTODY_EVENT_NAMESPACE_START;

    /// @notice The stateless ADR-0022 conservative-redemption NAV calculator this manager forwards
    ///         `pendingSeniorImpairment()` to.
    /// @dev **EIP-170 EXTRACTION — DO NOT INLINE THE ARITHMETIC BACK INTO THIS CONTRACT.** This
    ///      manager reached 215 bytes of runtime margin, which blocked further remediation work.
    ///      The drawn/undrawn + curator + backstop netting is the largest self-contained block
    ///      here that writes no storage, so it moved to `ConservativeImpairmentMath` and this
    ///      manager keeps only the forwarder. See `ConservativeImpairmentMath` for the algorithm
    ///      and `ConservativeImpairmentMathEquivalence.t.sol` for the bit-identical-result proof.
    ///
    ///      IMMUTABLE, AND DEPLOYED BY THIS CONSTRUCTOR ON PURPOSE. An immutable lives in the
    ///      implementation's runtime code, so it is readable through the proxy and occupies no
    ///      storage slot — the extraction therefore does not touch the ERC-7201 layout. Deploying
    ///      the calculator here rather than in `Deploy.s.sol` keeps the deployer's CREATE nonce
    ///      sequence identical, which is what `ValidateMainnet._validateMainnetCreateAddresses`
    ///      reconstructs from `(deployer, nonce)`; a standalone script deployment would have
    ///      shifted every address after `DefaultManager` and invalidated the approved deployment
    ///      receipt. The child is stateless and unprivileged, so nothing is delegated but
    ///      arithmetic. Each new implementation deploys its own — that is intended: the calculator
    ///      is versioned with the manager that trusts it.
    ///
    ///      THE TRADE, MEASURED: this recovers 407 bytes of runtime margin (215 -> 622) and costs
    ///      +21,836 gas per read of the mark and +65,530 on `sUSDfr.previewRedeem`, because the
    ///      calculator reads this manager back through the proxy. Four cheaper-looking designs were
    ///      measured and every one of them ended with LESS margin than doing nothing. See
    ///      `ConservativeImpairmentMath` for the table before proposing a batched getter.
    ConservativeImpairmentMath public immutable impairmentMath;
    CommitmentLedgerFactory internal immutable commitmentLedgerFactory;

    /// @dev Source accounting and host governance cannot overlap.
    modifier accrualIdle() {
        DefaultAccrualLib.requireIdle(_storage(), _reentrancyGuardEntered());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        impairmentMath = new ConservativeImpairmentMath();
        commitmentLedgerFactory = new CommitmentLedgerFactory();
        _disableInitializers();
    }

    /// @notice Wiring bundle for `initialize` (11 flat addresses exceed stack depth).
    struct InitModules {
        address bridge; // facility register (freeze transitions)
        address registry; // collateral registry (class model + exposure release)
        address reserves; // treasury (outstanding principal + write-downs)
        address controller; // mint controller (cascade burns; asserts backing)
        address curator; // curator first-loss module (cascade layer 1)
        address oracle; // attestation oracle (margin-path marks; ADR-0007 trust)
        address usdfr; // the USDfr token
        address vault; // the sUSDfr vault (cascade layer 3)
    }

    /// @notice Initializes the manager; every class starts with the default cure window.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser (permissionless triggers only).
    /// @param upgrader Upgrade authority (timelock).
    /// @param m The wired protocol modules (see `InitModules` field docs).
    function initialize(address admin, address guardian, address upgrader, InitModules calldata m)
        external
        initializer
    {
        if (admin == address(0) || guardian == address(0) || upgrader == address(0)) {
            revert DefaultManager_ZeroAddress();
        }
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        // THE MODULE WIRING AND THE PER-CLASS WINDOW SEED LIVE IN `DefaultInitLib`, EXTRACTED
        // 2026-09-10 FOR EIP-170. See that library's header for why this function and not a cascade
        // function was chosen. The `initializer` modifier, the four `__X_init` calls and the three
        // role grants stay HERE deliberately: they are internal members of the inherited
        // OpenZeppelin contracts, which a delegatecall library cannot reach, and keeping them in
        // view is what lets an auditor read the initialisation guard and the role grants together.
        //
        // The ledger is created HERE and passed in because `commitmentLedgerFactory` is an
        // `immutable` on the implementation, and a delegatecall library runs in the proxy's context
        // where the caller's immutables are not readable. The comment it replaces still applies:
        // the implementation constructor deployed the factory; it now deploys one ledger owned by
        // this proxy, keeping the child creation code out of this runtime.
        //
        // The H-5 grace-window reasoning moved with the loop; it is in `DefaultInitLib.wire`.
        DefaultInitLib.wire(_storage(), m, address(commitmentLedgerFactory.create(address(this))));
    }

    /// @notice The configured engine called for bounded PIK servicing before past-due marking.
    /// @return The engine address, or zero before wiring.
    function waterfallEngine() external view returns (address) {
        return address(_storage().waterfall);
    }

    /// @notice Permanently binds the native risk book to the token's verified accrual reserve.
    function setAccrualReserve(address reserve) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle nonReentrant {
        DefaultAccrualLib.bind(_storage(), reserve);
    }

    /// @notice The permanent continuous-interest source, or zero before activation binding.
    function accrualReserve() external view returns (address) {
        return address(_storage().accrualReserve);
    }

    /// @inheritdoc IAccrualRisk
    /// @dev Narrow reserve continuation, including within guarded default preparation. No public
    ///      pricing gate or second reentrancy guard may block this authenticated reclassification.
    function onAccrualPosted(uint256 tokenId, uint256 amount) external {
        DefaultAccrualLib.onPosted(_storage(), tokenId, amount);
    }

    /// @notice Reconciles an attested opening after the bound reserve has posted its native face.
    /// @dev A narrow reserve-only continuation; returns the existing past-due flag even at zero contribution.
    function onAccrualOpening(uint256 tokenId, uint256 income) external returns (bool marked) {
        return DefaultAccrualLib.onOpening(_storage(), tokenId, income);
    }

    /// @inheritdoc IAccrualRoundingRisk
    /// @dev Reserve-only risk continuation after native posting and a proved rounding write-down.
    function onAccrualRounding(uint256 tokenId, uint256 amount) external {
        DefaultAccrualLib.onRounding(_storage(), tokenId, amount);
    }

    function setWaterfall(address engine) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {
        DefaultStorage storage $ = _storage();
        if (address($.accrualReserve) != address(0) && engine != address($.waterfall)) {
            revert DefaultAccrualLib.DefaultAccrual_WrongModules();
        }
        if (engine != address(0)) {
            // Must at least answer the one call this contract will ever make on it.
            IPausableModule(engine).paused();
        }
        $.waterfall = IPausableModule(engine);
        emit WaterfallSet(engine);
    }

    /// @inheritdoc IDefaultManager
    /// @dev W6-B3/W7 migration path for a proxy upgraded from an implementation that predates the
    ///      append-only ledger address. W7 registers rows at DECLARATION, not first draw, so a
    ///      fresh child is safe only while there is no live declared principal at all.
    function initializeCommitmentLedger() external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {
        DefaultAccrualLib.installEmptyLedger(_storage(), address(commitmentLedgerFactory), false);
    }

    /// @inheritdoc IDefaultManager
    function replaceCommitmentLedger() external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {
        DefaultAccrualLib.installEmptyLedger(_storage(), address(commitmentLedgerFactory), true);
    }

    // ── Receivable remedy path (SERVICER_ROLE; posting prerequisites apply) ───────────

    /// @inheritdoc IDefaultManager
    /// @dev Phase G (ADR-0020): declaring default requires the attested off-chain fact
    ///      — SERVICER_ROLE gates who may execute it, the DefaultDeclared attestation
    ///      gates whether it is true. The attestation stays standing (not consumed):
    ///      it remains the on-chain record backing the remedy process.
    function declareDefault(uint256 tokenId, bytes32 evidenceHash)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
    {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
        DefaultLossLib.consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, evidenceHash)),
            false
        );
        // Pin all pre-default management/performance economics before the conservative
        // marked NAV changes. The new impairment then lowers NAV against the old HWM.
        DefaultAccrualLib.prepare($, tokenId, true);
        IsUSDfr($.vault).accrueFees();
        delete $.cureDeadlines[tokenId]; // a margin path in flight is superseded
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Defaulted);
        // AUDIT FIX (R4-EC2): freeze curator withdrawals for the class until governance
        // resolves the workout, so a curator cannot front-run the coming realizeLoss.
        $.curator.freezeOnDefault(f.classId);
        // AUDIT FIX (H-5, REDESIGN): if the facility was flagged past due, RELEASE that reversible
        // past-due contribution IMMEDIATELY BEFORE recording the declared-default contribution —
        // adjacent internal writes, no external call between them — so the facility is counted
        // EXACTLY ONCE and there is never a window where both the past-due and the declared marks
        // apply. A no-op when the facility was not flagged.
        _releasePastDue($, tokenId, f.classId);
        _recordDefaulted($, tokenId, f.classId); // ADR-0022: enter the impairment pool
        DefaultLossLib.advanceImpairmentRevision($);
        bytes32 ref = $.remedyRefs[f.classId];
        emit DefaultDeclared(tokenId, f.classId, ref);
        emit RemedyInitiated(tokenId, f.classId, ref);
    }

    /// @inheritdoc IDefaultManager
    function settleLegacyPikForDefault(uint256 tokenId, bytes32 evidenceHash, uint256 maxPeriods)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
        returns (uint256 processed, uint64 pendingDue)
    {
        return DefaultAccrualLib.settleLegacyPikForDefault(_storage(), tokenId, evidenceHash, maxPeriods);
    }

    /// @inheritdoc IDefaultManager
    function accelerate(uint256 tokenId) external onlyRole(Roles.SERVICER_ROLE) accrualIdle nonReentrant {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Defaulted) revert DefaultManager_NotInDefault(tokenId);
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Accelerated);
        emit Accelerated(tokenId);
    }

    /// @inheritdoc IDefaultManager
    /// @dev THE BODY LIVES IN `DefaultLossLib`, EXTRACTED 2026-09-10 FOR EIP-170. The modifiers
    ///      stay HERE, because a delegatecall library cannot see the caller's modifiers: this
    ///      function is the only authorised way in, and `onlyRole(SERVICER_ROLE)` plus
    ///      `nonReentrant` are what make it so. See the library header for the ADR-0012 ordering
    ///      rule that the moved body depends on.
    function realizeLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
    {
        DefaultLossLib.realizeLoss(_storage(), tokenId, loss, evidenceHash);
    }

    /// @notice Retained-but-unreachable ABI for allocating an idle-reserve backing reduction.
    /// @dev No production source calls this entry in this tree: ReserveManager executes the live
    ///      custody cascade inline through `_drawJuniorReserveLoss`. This compatibility path moves
    ///      all three capital layers but emits no transition event of its own, so its tests must
    ///      not be counted as coverage of the shipped custody-loss entry. Custody losses have no
    ///      collateral class. Layer 1 is therefore allocated pro-rata by
    ///      the five curator pools' SNAPSHOTTED balances: the capital actually standing at risk.
    ///      Every partial write-down for one adjudicated incident reuses the same upper-namespace
    ///      `incidentId` for durable observability. ADR-0035 gives that id no separate allowance.
    ///      This path deliberately never writes facility-default consumption accounting.
    function absorbReserveLoss(uint256 incidentId, uint256 requiredSupplyReduction)
        external
        nonReentrant
        returns (IReserveLossAbsorber.ReserveLossAllocation memory allocation)
    {
        DefaultStorage storage $ = _storage();
        if (msg.sender != address($.reserves)) revert DefaultManager_ReserveLossCallerNotReserve(msg.sender);
        if (!LossEventIds.isCustodyEvent(incidentId)) revert DefaultManager_InvalidReserveLossIncident(incidentId);

        IsUSDfr($.vault).accrueFees();

        // ── layer 1: all curator pools, weighted by balances snapshotted before any call ──
        uint256 residual;
        (allocation.curatorAbsorbed, residual) = $.curator.absorbGlobalLoss(requiredSupplyReduction);

        // ── layer 2: SGrove's shared live reserve, keyed only for observability ──
        // NO LAYER-0 PREPAYMENT CONSUMPTION HERE, DELIBERATELY. See `exitPrepaidAbsorption`:
        // `ReserveManager._recognizeReserveLoss` sizes `requiredSupplyReduction` off LIVE supply and
        // backing, so an earlier exit draw has already shrunk it. Consuming the ledger here would
        // credit the same draw a second time.
        allocation.backstopCovered = DefaultLossLib.coverFromBackstop($, incidentId, residual);
        residual -= allocation.backstopCovered;

        // Both junior layers transferred their USDfr here. Burn every received unit before
        // the ReserveManager lowers backing, exactly as facility `realizeLoss` does.
        uint256 selfBurn = allocation.curatorAbsorbed + allocation.backstopCovered;
        if (selfBurn != 0) $.controller.burnLoss(address(this), selfBurn);

        // ── layer 3: senior vault, but only after both junior layers are exhausted ──
        if (residual != 0) {
            uint256 vaultAssets = IsUSDfr($.vault).totalAssets();
            allocation.seniorBurned = residual < vaultAssets ? residual : vaultAssets;
            if (allocation.seniorBurned != 0) {
                $.controller.burnLoss($.vault, allocation.seniorBurned);
                residual -= allocation.seniorBurned;
            }
        }
        allocation.residualDeficit = residual;
    }

    /// @notice The ReserveManager authorised to request reserve-loss absorption.
    function reserveLossSource() external view returns (address) {
        return address(_storage().reserves);
    }

    /// @inheritdoc IDefaultManager
    /// @dev ADR-0034 Y-bis — THE ATOMIC JUNIOR DRAW. Read
    ///      `ADR/0034-exit-pricing-in-cascade-order.md` before touching this.
    ///
    ///      WHY IT EXISTS. `MintRedeemController._quoteRedeem` prices the direct exit off GROSS
    ///      `totalBackingValue()`, which nets NOTHING against junior capital, while the `sUSDfr`
    ///      path prices off `pendingSeniorImpairment()`, which DOES. A holder redeeming while
    ///      curator first-loss capital sat intact therefore absorbed a loss the junior tranche
    ///      contracted to take first — the locked §1.3 cascade run backwards. Forest Road decided
    ///      (2026-08-08) that the residual price and the draw are NOT alternatives: the residual
    ///      price PROMISES more than gross-marked backing, and the difference sits in the curator
    ///      pool and the sGROVE backstop, not in `ReserveManager`'s USDC. So junior capital is
    ///      drawn AT THE MOMENT OF THE EXIT and cascade order is enforced AT SETTLEMENT.
    ///
    ///      ORDER IS UNREPRESENTABLE-BACKWARDS, NOT MERELY CHECKED. Layer 2 is only ever offered
    ///      `residual`, a value that exists solely as layer 1's SECOND RETURN. There is no
    ///      expression in scope from which the backstop could be handed `required`. Layer 1 is
    ///      called unconditionally. `absorbGlobalLoss` clamps to the pools' total, so a non-zero
    ///      `residual` means the curator pools are EXHAUSTED — the ordering property is a theorem
    ///      about the dataflow, not an assertion in it. Inverting it requires rewriting the
    ///      function, not deleting a guard.
    ///
    ///      LAYER 1 IS CLASS-LESS, AND FOREST ROAD SIGNED THAT OFF ON 2026-09-09. This block used
    ///      to end "THIS NEEDS FOREST ROAD SIGN-OFF AND MUST NOT BE GLOSSED"; ADR-0034 Y-bis is
    ///      amended and now says pooled rather than per class, with the reasoning recorded there.
    ///
    ///      A redemption has no collateral class, and the deficit it prices against
    ///      (`totalUSDfr() - backingValue()`) is a BLEND: part class-attributable credit
    ///      impairment, part class-LESS custody shortfall that an idle write-down can produce with
    ///      no facility involved at all. Splitting one blended number into class shares is
    ///      arbitrary in exactly the custody part. Pooling is also not new here: ADR-0033 already
    ///      mandates pro rata across all five pools for an adjudicated custody loss, so this uses
    ///      `absorbGlobalLoss` pro-rata by the five pools' SNAPSHOTTED balances, exactly as
    ///      `_drawJuniorReserveLoss` does — "the capital actually standing at risk".
    ///
    ///      THE BOUNDARY IS LOAD-BEARING AND THIS AMENDMENT DOES NOT CROSS IT. A REALISED credit
    ///      loss is still charged to the class that caused it, at `absorbLoss(f.classId, ...)`
    ///      above. That must not be pooled: first-loss is POSTED per class, curators are APPROVED
    ///      per class, and ADR-0004 computes subordination headroom per class against posted
    ///      capital. Pooling realised losses would let one class's default consume another class's
    ///      curator stake and would break that model.
    ///
    ///      DISCLOSURE, per the ADR: a curator's posted first-loss CAN be drawn to price a
    ///      redemption whose deficit arose in another class. That is a commercial term of posting
    ///      first-loss and belongs wherever curator terms are published.
    ///
    ///      LAYER 3 IS NOT REACHED HERE, AND THAT TOO IS AN OPEN QUESTION. ADR-0034 X places
    ///      unstaked USDfr holders LAST — behind the `sUSDfr` vault — so the honest full order for
    ///      a direct exit is curator -> sGROVE -> sUSDfr -> unstaked holder. Y-bis's binding
    ///      implementation requirements name only layers 1 and 2, and this implements exactly
    ///      that. The consequence is that once junior capital is exhausted the exiting holder
    ///      takes a haircut while the senior vault sits intact, which inverts X's layers 3 and 4.
    ///      Extending the draw to the vault is a localised change here; it is NOT taken
    ///      unilaterally because it would let any KYC'd unstaked holder burn senior vault
    ///      principal on demand.
    ///
    ///      IT NEVER REVERTS ON INSUFFICIENCY, BY DESIGN. Both layers clamp to what they hold, so
    ///      `drawn < required` is an ordinary answer and the controller settles at the
    ///      partially-improved price. Exhausted junior capital degrades CONTINUOUSLY to exactly
    ///      today's gross price. Reverting instead would reintroduce the R16 exit deadlock that
    ///      ADR-0034 exists to remove.
    ///
    ///      IT DOES NOT BURN, AND MUST NOT. `controller.burnLoss` is `nonReentrant` ON THE
    ///      CONTROLLER and `redeem` already holds that lock, so the `realizeLoss` shape (draw,
    ///      then call back into `burnLoss`) reverts with `ReentrancyGuardReentrantCall` here. The
    ///      drawn USDfr is left standing at this contract and the controller burns it IN PLACE.
    ///      Anyone "restoring symmetry" with `realizeLoss` will brick every under-backed exit.
    ///
    ///      CALLER IDENTITY, NOT A ROLE. There is exactly one correct caller and a role can be
    ///      granted to a second one. This deliberately does not widen the ACL surface.
    function drawForSeniorExit(uint256 required) external nonReentrant returns (uint256 drawn) {
        DefaultStorage storage $ = _storage();
        // AUDIT NOTE (ADR-0034 Y-bis) — LOAD-BEARING, DO NOT DELETE. Without it ANY address could
        // burn down curator first-loss capital and the sGROVE coverage reserve at will, with the
        // proceeds stranded at this contract. Falsified by
        // `test_Y_G01_theExitDrawRefusesAnyCallerThatIsNotTheController`.
        if (msg.sender != address($.controller)) revert DefaultManager_ExitDrawCallerNotController(msg.sender);
        // NO ZERO CHECK HERE, DELIBERATELY (house rule M6: do not carry an unfalsifiable guard).
        // `CuratorModule.absorbGlobalLoss` already reverts `Curator_ZeroAmount` on a zero request,
        // so a local check could never be the one that fires.

        // ── layer 1: curator first-loss, pro-rata over the standing pools ──
        (uint256 absorbed, uint256 residual) = $.curator.absorbGlobalLoss(required);
        // ── layer 2: the sGROVE backstop, and ONLY for what layer 1 declined ──
        uint256 covered = DefaultLossLib.coverFromBackstop($, SENIOR_EXIT_EVENT_ID, residual);

        drawn = absorbed + covered;
        if (drawn != 0) {
            // The ledger lives in `ReserveManager` — see its `exitPrepaidAbsorption` field NatSpec
            // for why (the bound is the recognised mark, which is that contract's state).
            $.reserves.recordExitPrepayment(drawn);
            // ADR-0027: junior pool balances just moved, so any assessment taken against the old
            // balances is stale. Same reason `realizeLoss` advances it.
            DefaultLossLib.advanceImpairmentRevision($);
        }
        emit SeniorExitDrawn(required, absorbed, covered);
    }

    // ── Past-due accounting trigger (permissionless; NOT pausable) ───────
    /// @inheritdoc IDefaultManager
    /// @dev A permissionless accounting mark leaves the facility's legal state unchanged.
    ///      Accrued debt is checkpointed first. Cash and PIK income can increase the mark;
    ///      repayment, cure and realized corrections reconcile it through their native callbacks.
    ///      Legacy PIK settlement is attempted before a bounded extension of the grace window.
    function markPastDue(uint256 tokenId) external nonReentrant {
        DefaultStorage storage $ = _storage();
        // Bring native debt current before deciding whether its payment is overdue.
        bool tracked;
        ClaimBridge.Facility memory f;
        {
            uint64 paymentDue;
            (tracked, paymentDue) = DefaultAccrualLib.prepare($, tokenId, false);
            f = $.bridge.facility(tokenId);
            if (paymentDue != 0) f.nextPaymentDue = paymentDue;
        }
        if ($.registry.classParams(f.classId).model != ICollateralRegistry.CollateralModel.Receivable) {
            revert DefaultManager_NotReceivable(tokenId);
        }
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
        if ($.pastDueMarked[tokenId]) revert DefaultManager_AlreadyPastDue(tokenId);
        uint64 graceEnd = f.nextPaymentDue + $.graceWindows[f.classId];
        if (block.timestamp <= graceEnd) revert DefaultManager_NotPastDue(tokenId, f.nextPaymentDue, graceEnd);
        // Legacy PIK tries the real settlement call. A failed call grants one extra class
        // grace window; native facilities already passed their own maintenance check above.
        if (!tracked && f.pik && address($.waterfall) != address(0)) {
            if (DefaultAccrualLib.settlePikPeriod($, tokenId)) {
                emit PikPeriodSettledInsteadOfMark(tokenId, f.classId, f.nextPaymentDue);
                return;
            }
            if (block.timestamp <= _pikExtendedGraceEnd($, graceEnd, f)) {
                revert DefaultManager_PikCrankBlocked(tokenId);
            }
        }
        // Close the fee epoch before the new risk mark affects senior redemption value.
        IsUSDfr($.vault).accrueFees();
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        // A new authenticated payment date opens an episode; clearing and remarking the
        // same date preserves its original relief clock.
        ReliefEpisode memory episode = $.reliefEpisode[tokenId];
        if (f.nextPaymentDue > episode.due) {
            episode = ReliefEpisode({due: f.nextPaymentDue, startedAt: uint64(block.timestamp)});
            $.reliefEpisode[tokenId] = episode;
        }
        if ($.pastDueExposure == 0 || uint256(episode.startedAt) < $.pastDueReliefAnchor) {
            $.pastDueReliefAnchor = episode.startedAt;
        }
        $.pastDueMarked[tokenId] = true;
        $.pastDueContribution[tokenId] = outstanding;
        $.pastDuePrincipal[f.classId] += outstanding;
        $.pastDueExposure += outstanding;
        DefaultAccrualLib.setPastDue($, tokenId, true);
        DefaultLossLib.advanceImpairmentRevision($);
        emit PastDueMarked(tokenId, f.classId, f.nextPaymentDue, outstanding);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-5, REDESIGN). The reversibility half of `markPastDue`. SERVICER_ROLE-gated
    ///      because the servicer processes payments and is the party that knows a facility has cured.
    ///      State-agnostic on purpose: a facility that reached `Repaid`/`Resolved` while still
    ///      flagged (e.g. a bystander marked it, then it cured through the ordinary performing
    ///      repayment path) can always be cleaned up here, so a past-due over-mark can never strand —
    ///      the H-2 lesson. Removes the facility's at-risk principal from the past-due pool and the
    ///      `pastDueExposure` aggregate, restoring the conservative senior NAV.
    function clearPastDue(uint256 tokenId, bytes32 evidenceHash) external onlyRole(Roles.SERVICER_ROLE) nonReentrant {
        // C4-01: separate cure events for separate due revisions need distinct durable evidence;
        // signature nonce/asOf remain transport salt and are deliberately not fact identity.
        if (evidenceHash == bytes32(0)) revert DefaultManager_ZeroEvidenceHash();
        DefaultStorage storage $ = _storage();
        if (!$.pastDueMarked[tokenId]) revert DefaultManager_NotPastDueMarked(tokenId);
        DefaultLossLib.consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(tokenId, evidenceHash)),
            true
        );
        DefaultAccrualLib.prepare($, tokenId, false);
        IsUSDfr($.vault).accrueFees();
        uint256 classId = $.bridge.facility(tokenId).classId;
        _releasePastDue($, tokenId, classId);
        DefaultLossLib.advanceImpairmentRevision($);
    }

    // ── Marked-to-market fast path (permissionless; pausable) ────────────

    /// @inheritdoc IDefaultManager
    function marginCall(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
        DefaultAccrualLib.prepare($, tokenId, false);
        if ($.cureDeadlines[tokenId] != 0) revert DefaultManager_AlreadyMarginCalled(tokenId);

        (uint256 ltv, uint64 asOf) = _ltv($, tokenId);
        if (asOf == 0 || block.timestamp - asOf > p.maxMarkAge) {
            revert DefaultManager_ValuationStale(tokenId, asOf, p.maxMarkAge);
        }
        if (ltv < p.marginCallLtvBps) {
            revert DefaultManager_ThresholdNotBreached(tokenId, ltv, p.marginCallLtvBps);
        }
        uint64 deadline = uint64(block.timestamp) + $.cureWindows[f.classId];
        $.cureDeadlines[tokenId] = deadline;
        emit MarginCalled(tokenId, ltv, deadline);
    }

    /// @inheritdoc IDefaultManager
    /// @dev Margin calls, liquidation and curing all require a mark within the class's maxMarkAge.
    function clearMarginCall(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
        DefaultAccrualLib.prepare($, tokenId, false);
        if ($.cureDeadlines[tokenId] == 0) revert DefaultManager_NoMarginCall(tokenId);

        (uint256 ltv, uint64 asOf) = _ltv($, tokenId);
        if (block.timestamp - asOf > p.maxMarkAge) {
            revert DefaultManager_ValuationStale(tokenId, asOf, p.maxMarkAge);
        }
        if (ltv >= p.marginCallLtvBps) {
            revert DefaultManager_ThresholdNotBreached(tokenId, ltv, p.marginCallLtvBps);
        }
        delete $.cureDeadlines[tokenId];
        emit MarginCallCleared(tokenId, ltv);
    }

    /// @inheritdoc IDefaultManager
    function liquidate(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
        DefaultAccrualLib.prepare($, tokenId, true);

        (uint256 ltv, uint64 asOf) = _ltv($, tokenId);
        if (asOf == 0 || block.timestamp - asOf > p.maxMarkAge) {
            revert DefaultManager_ValuationStale(tokenId, asOf, p.maxMarkAge);
        }
        uint64 deadline = $.cureDeadlines[tokenId];
        // liquidation triggers: hard threshold breach, OR an expired margin call that
        // is still in margin-call breach (a recovered LTV survives cure expiry)
        bool hardBreach = ltv >= p.liquidationLtvBps;
        bool cureExpired = deadline != 0 && block.timestamp > deadline && ltv >= p.marginCallLtvBps;
        if (!hardBreach && !cureExpired) {
            revert DefaultManager_ThresholdNotBreached(tokenId, ltv, p.liquidationLtvBps);
        }

        IsUSDfr($.vault).accrueFees();
        delete $.cureDeadlines[tokenId];
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Defaulted);
        // AUDIT FIX (R4-EC2): freeze curator withdrawals for the class (see declareDefault).
        $.curator.freezeOnDefault(f.classId);
        _recordDefaulted($, tokenId, f.classId); // ADR-0022: enter the impairment pool
        DefaultLossLib.advanceImpairmentRevision($);
        bytes32 ref = $.remedyRefs[f.classId];
        emit LiquidationInitiated(tokenId, ltv);
        emit RemedyInitiated(tokenId, f.classId, ref);
    }

    // ── Credit-layer hook (ADR-0022 impairment lifecycle) ────────────────

    /// @inheritdoc IDefaultManager
    /// @dev Called by the WaterfallEngine when a defaulted facility recovers its full
    ///      outstanding and closes to `Resolved` WITHOUT a realized loss — the remaining
    ///      unrealized-impairment contribution must leave the pool, else the conservative
    ///      redemption NAV would stay depressed forever after a clean recovery. Gated by
    ///      CREDIT_ROLE AND a defensive check that the loan really is Resolved, so a
    ///      CREDIT_ROLE caller cannot prematurely zero a still-defaulted loan's contribution
    ///      (which would UNDER-mark impairment — the unsafe direction).
    function onDefaultResolved(uint256 tokenId) external accrualIdle nonReentrant onlyRole(Roles.CREDIT_ROLE) {
        DefaultLossLib.onDefaultResolved(_storage(), tokenId);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-2), the recovery half. `onDefaultResolved` only fires when a workout
    ///      recovers the outstanding IN FULL. A PARTIAL recovery — the ordinary shape of a
    ///      workout — lowered `reserves.deployedTo(tokenId)` while `defaultedContribution`
    ///      stayed pinned at its declare-time snapshot, and nothing on-chain could ever clear
    ///      the difference: `realizeLoss` is the only other decrement and a servicer must not
    ///      write off principal that is still being collected. Measured before this hook: a
    ///      2,000,000e18 facility returning 1,900,000e18 in cash kept `pendingSeniorImpairment()`
    ///      at 2,000,000e18 indefinitely against 100,000e18 of genuinely at-risk principal — a
    ///      permanent, un-clearable haircut on every senior exit. Four such ordinary workouts
    ///      drove `redemptionTotalAssets()` to zero against a solvent vault.
    ///
    ///      IT CANNOT UNDER-MARK. The new mark is exactly `reserves.deployedTo(tokenId)`, which
    ///      is the largest senior loss this facility can still produce: `realizeLoss` reverts
    ///      with `DefaultManager_LossExceedsOutstanding` when `loss > deployedTo`. And
    ///      `deployedTo` never rises again for a defaulted facility — it only grows in
    ///      `ReserveManager.recordDeployment`/`recordFeeCapitalization`, whose sole callers sit
    ///      inside `WaterfallEngine.fund`, which reverts unless the facility is `Pending`, a
    ///      state the ClaimBridge machine cannot re-enter. So the mark is an upper bound at the
    ///      moment it is written and stays one for the rest of the facility's life.
    ///
    ///      IT CANNOT RATCHET. The re-anchor is one-directional (`stillAtRisk < c` only), so
    ///      repeat calls, calls with nothing recovered, and calls interleaved with `realizeLoss`
    ///      in either order all converge on the same fixed point and never raise the mark.
    ///
    ///      THREAT MODEL. Both this hook and the `_reduceDefaulted` clamp trust `deployedTo` to
    ///      fall only against real cash or a real write-down. That holds only while CREDIT_ROLE
    ///      is held by protocol modules alone: a CREDIT_ROLE grant to an EOA could call
    ///      `ReserveManager.recordPayment`/`recordPrincipalWritedown` directly, lowering
    ///      `deployedTo` without cash arriving or the cascade running, after which this
    ///      de-recognises a genuine loss. CREDIT_ROLE must never leave the module set.
    function onDefaultRecovery(uint256 tokenId) external accrualIdle nonReentrant onlyRole(Roles.CREDIT_ROLE) {
        DefaultLossLib.onDefaultRecovery(_storage(), tokenId);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (re-audit MEDIUM, 2026-07-22). The PAST-DUE counterpart of
    ///      `onDefaultRecovery`. A past-due facility stays Active/Amortizing (`markPastDue` never
    ///      transitions state), so it cures through the ORDINARY performing repayment path in
    ///      `WaterfallEngine.distribute` — which had no past-due hook. Left unwired, the past-due
    ///      pool kept its mark-time `pastDueContribution` snapshot while `deployedTo` fell, so the
    ///      conservative redemption NAV stayed depressed by the full snapshot until a manual
    ///      `clearPastDue`: a partial paydown over-marked by the un-amortized remainder, and a full
    ///      repayment left the whole snapshot standing. That is the H-2 stuck-over-mark shape, on
    ///      the past-due pool. This re-anchors the contribution DOWN to live `deployedTo` on every
    ///      performing repayment and fully clears the flag when the facility is repaid in full.
    ///
    ///      ONE-DIRECTIONAL AND IDEMPOTENT, exactly like `onDefaultRecovery`: it only shrinks the
    ///      mark (`stillAtRisk < c`), so repeat calls and calls with nothing paid down converge and
    ///      never raise it. A no-op for a facility that is not flagged, so it is safe to call on
    ///      EVERY performing repayment. Same threat model: it trusts `deployedTo` to fall only
    ///      against real cash or a real write-down, which holds only while CREDIT_ROLE stays inside
    ///      the module set.
    function onPerformingRepayment(uint256 tokenId) external onlyRole(Roles.CREDIT_ROLE) accrualIdle {
        DefaultStorage storage $ = _storage();
        if (!$.pastDueMarked[tokenId]) return; // no-op: the facility was never past-due
        uint256 classId = $.bridge.facility(tokenId).classId;
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        if (stillAtRisk == 0) {
            _releasePastDue($, tokenId, classId); // repaid in full: clear the mark entirely
            DefaultLossLib.advanceImpairmentRevision($);
            return;
        }
        uint256 c = $.pastDueContribution[tokenId];
        if (stillAtRisk >= c) return; // idempotent: nothing paid down since the last anchor
        uint256 derecognized = c - stillAtRisk;
        $.pastDueContribution[tokenId] = stillAtRisk;
        $.pastDuePrincipal[classId] -= derecognized;
        $.pastDueExposure -= derecognized;
        DefaultLossLib.advanceImpairmentRevision($);
        emit PastDueReanchored(tokenId, classId, derecognized);
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @inheritdoc IDefaultManager
    function setRemedyRef(uint256 classId, bytes32 remedyRef_) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {
        _requireKnownClass(classId);
        _storage().remedyRefs[classId] = remedyRef_;
        emit RemedyRefSet(classId, remedyRef_);
    }

    /// @inheritdoc IDefaultManager
    function setCureWindow(uint256 classId, uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {
        _requireKnownClass(classId);
        if (window == 0) revert DefaultManager_ZeroAmount();
        _storage().cureWindows[classId] = window;
        emit CureWindowSet(classId, window);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-5). Capped at `Config.DEFAULT_REDEEM_COOLDOWN` — the grace window can only
    ///      ever be LOWERED from its default, never raised past the redemption cooldown. Zero is
    ///      permitted (mark the instant past maturity — maximally conservative). Governance-gated and
    ///      evented; a purely accounting parameter. NB (final-audit #2): this cap bounds the
    ///      maturity-anchored marking lag, but the redemption cooldown is REQUEST-anchored
    ///      (`requestedAt + redeemCooldown`) and `RedemptionQueue.setRedeemCooldown` is separately
    ///      governed and unbounded, so the cap does NOT guarantee the cooldown fully covers the lag —
    ///      a partial par-exit window (a redeemer who queued before maturity) survives. Closing it
    ///      fully is a deeper economic-design item, deliberately NOT done here; the residual is
    ///      documented rather than hidden.
    function setGraceWindow(uint256 classId, uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle {
        _requireKnownClass(classId);
        if (window > Config.DEFAULT_REDEEM_COOLDOWN) {
            revert DefaultManager_GraceWindowTooLong(window, Config.DEFAULT_REDEEM_COOLDOWN);
        }
        _storage().graceWindows[classId] = window;
        emit GraceWindowSet(classId, window);
    }

    /// @inheritdoc IDefaultManager
    function setBackstop(address backstop_) external onlyRole(DEFAULT_ADMIN_ROLE) accrualIdle nonReentrant {
        DefaultBackstopLib.set(_storage(), backstop_);
    }

    // ── Guardian (permissionless triggers only) ──────────────────────────

    /// @notice Pauses the permissionless margin-path triggers. Emergency use only
    ///         (e.g. suspect marks); the manager pause does not gate role-based remedies; required PIK posting may still block default.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) accrualIdle {
        _pause();
    }

    /// @notice Unpauses the permissionless triggers.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) accrualIdle {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IDefaultManager
    function currentLtvBps(uint256 tokenId) external view returns (uint256 ltvBps, uint64 asOf) {
        return _ltv(_storage(), tokenId);
    }

    /// @inheritdoc IDefaultManager
    function cureDeadline(uint256 tokenId) external view returns (uint64) {
        return _storage().cureDeadlines[tokenId];
    }

    /// @inheritdoc IDefaultManager
    function remedyRef(uint256 classId) external view returns (bytes32) {
        return _storage().remedyRefs[classId];
    }

    /// @inheritdoc IDefaultManager
    function cureWindow(uint256 classId) external view returns (uint64) {
        return _storage().cureWindows[classId];
    }

    /// @inheritdoc IDefaultManager
    function graceWindow(uint256 classId) external view returns (uint64) {
        return _storage().graceWindows[classId];
    }

    /// @inheritdoc IDefaultManager
    function pastDueExposure() external view returns (uint256) {
        return DefaultAccrualLib.pastDueExposure(_storage());
    }

    /// @inheritdoc IDefaultManager
    function pastDueContribution(uint256 tokenId) external view returns (uint256) {
        return DefaultAccrualLib.contribution(_storage(), tokenId);
    }

    /// @inheritdoc IDefaultManager
    function backstop() external view returns (address) {
        return address(_storage().backstop);
    }

    /// @inheritdoc IDefaultManager
    function declaredDefaultedPrincipal(uint256 classId) external view returns (uint256) {
        return _storage().declaredDefaultedPrincipal[classId];
    }

    /// @inheritdoc IDefaultManager
    function impairmentRevision() external view returns (uint256) {
        return _storage().impairmentRevision;
    }

    /// @inheritdoc IDefaultManager
    /// @dev Exact operational fingerprint, including live backstop capacity.
    function impairmentStateHash() external view returns (bytes32 stateHash) {
        return DefaultAccrualLib.exactStateHash(_storage());
    }

    /// @inheritdoc IDefaultManager
    /// @dev Includes every risk identity/input and exact per-class curator capacity, but
    ///      deliberately excludes the global backstop's live capacity. The assessed wrapper
    ///      snapshots that capacity separately so an increase (which can only protect seniors)
    ///      remains valid while any decrease fails conservatively.
    function impairmentRiskStateHash() external view returns (bytes32 stateHash) {
        return _impairmentRiskStateHash(_storage());
    }

    /// @inheritdoc IDefaultManager
    function impairmentBackstopCapacity() external view returns (uint256) {
        return _impairmentBackstopCapacity(_storage());
    }

    /// @notice Revision-bound assessment identity and separately measured overdue face.
    /// @return riskStateHash Risk identity unchanged by elapsed income or neutral posting.
    /// @return pastDueExposure_ Recorded plus unposted overdue face in USDfr.
    /// @return backstopCapacity Effective global junior capacity; zero on BSC.
    function impairmentAssessmentState()
        external
        view
        returns (bytes32 riskStateHash, uint256 pastDueExposure_, uint256 backstopCapacity)
    {
        return DefaultAccrualLib.assessmentState(_storage());
    }

    function _impairmentRiskStateHash(DefaultStorage storage $) private view returns (bytes32) {
        return DefaultAccrualLib.riskStateHash($);
    }

    function _impairmentBackstopCapacity(DefaultStorage storage $) private view returns (uint256) {
        return address($.backstop) == address(0) ? 0 : $.backstop.coverageCapacity();
    }

    /// @inheritdoc IDefaultManager
    /// @dev Conservative senior impairment follows curator first-loss and the shared sGROVE
    ///      backstop. An enabled native-accrual reserve uses DefaultAccrualLib so unreceived
    ///      earned interest participates. The legacy route retains the immutable
    ///      ConservativeImpairmentMath calculator. Both routes use constant-class aggregates
    ///      rather than a walk over historical default events.
    function pendingSeniorImpairment() external view returns (uint256) {
        DefaultStorage storage $ = _storage();
        if (address($.accrualReserve) != address(0) && $.accrualReserve.accrualSnapshot().enabled) {
            return DefaultAccrualLib.nativeSeniorImpairment($);
        }
        return impairmentMath.pendingSeniorImpairment(address(this));
    }

    /// @notice Gross live impairment used for protocol-level performance-fee accounting.
    /// @dev Performance fees use the gross live impairment before curator or backstop
    ///      capacity. Junior capital improves the redemption mark but is contributed capital,
    ///      not senior investment performance. The gross amount automatically returns to zero
    ///      when the underlying declared/past-due impairment cures, so no permanent HWM credit
    ///      or explicit release path is required.
    /// @return impairment Gross declared/past-due principal, in 18-decimal USDfr units.
    function performanceFeeImpairment() external view returns (uint256 impairment) {
        return DefaultAccrualLib.performanceImpairment(_storage());
    }

    /// @notice A facility's remaining declared-but-unrealized contribution to the impairment pool.
    /// @dev Exposed so an independent model can recompute `pendingSeniorImpairment` from first
    ///      principles rather than trusting it — see `invariant_pendingImpairmentNeverUnderMarks`.
    ///      The impairment path has now produced three distinct under-marking bugs, so the
    ///      per-facility inputs are made observable rather than inferred.
    /// @param tokenId The facility.
    /// @return contribution Remaining at-risk principal this facility contributes.
    function defaultedContribution(uint256 tokenId) external view returns (uint256 contribution) {
        return _storage().defaultedContribution[tokenId];
    }

    function drawnDefaultPrincipal(uint256 classId) external view returns (uint256 principal) {
        return _storage().drawnDefaultPrincipal[classId];
    }

    /// @inheritdoc IDefaultManager
    /// @dev Added when the conservative-NAV arithmetic was extracted to
    ///      `ConservativeImpairmentMath`: it was the one impairment input with no public getter, so
    ///      the calculator could not read it. It is also the per-class breakdown of
    ///      `pastDueExposure()`, which an independent model needs to recompute the mark from first
    ///      principles. DO NOT REMOVE — `ConservativeImpairmentMath` reads it, and without it the
    ///      mark silently loses the whole H-5 past-due pool.
    function pastDuePrincipal(uint256 classId) external view returns (uint256 principal) {
        return DefaultAccrualLib.pastDuePrincipal(_storage(), classId);
    }

    /// @inheritdoc IDefaultManager
    /// @dev OWNER DECISION 2026-08-07 (G2W). Published because the conservative-NAV arithmetic
    ///      lives in `ConservativeImpairmentMath`, which is not this contract and therefore cannot
    ///      read this slot directly; it is also what operations and the frontend need to answer
    ///      "when does the loud stop return?" (`anchor + Config.DEFAULT_REDEEM_COOLDOWN`).
    ///      DO NOT REMOVE — without it the calculator cannot see the relief clock at all, and a
    ///      compiler that resolved the read to zero would hand every standing cohort FULL weight,
    ///      silently discarding the owner decision. Pinned by
    ///      `test_g2w_ramp_theAnchorIsWrittenSoAFreshMarkGetsTheGovernedRelief`.
    ///      ZERO MEANS UNSET AND FAILS SAFE (full weight); see the storage-struct comment.
    function pastDueReliefAnchor() external view returns (uint256 anchor) {
        return _storage().pastDueReliefAnchor;
    }

    function coverageConsumedByDefault(uint256 tokenId) external view returns (uint256 consumed) {
        return _storage().coverageConsumedByDefault[tokenId];
    }

    /// @notice sGROVE coverage already drawn by defaults that are still declared-but-unrealized.
    /// @dev Historical consumption observability retained under ADR-0035. The conservative mark
    ///      reads the physical reserve directly rather than subtracting this aggregate; consumed
    ///      USDfr has already left that reserve. Released when the event row closes.
    /// @return consumed The aggregate consumed coverage, in USDfr.
    function liveDefaultCoverageConsumed() external view returns (uint256 consumed) {
        return _storage().liveDefaultCoverageConsumed;
    }

    /// @dev Compatibility alias for pre-ADR-0035 observers. The obsolete storage word remains in
    ///      place for upgrade safety, but this view reports the live ledger aggregate: the
    ///      remaining-principal claim of drawn rows, not a frozen backstop floor.
    function liveDefaultCapacityFloor() external view returns (uint256 capacityFloor) {
        return _storage().commitmentLedger.deliverableAggregate();
    }

    /// @notice Aggregate remaining principal of live defaults that have drawn layer two.
    /// @dev ADR-0035 compatibility view. It is a demand-side claim, not physical capacity;
    ///      `CommitmentLedger.conservativeResiduals()` applies the shared reserve separately.
    function liveDefaultCoverageRemaining() external view returns (uint256 remaining) {
        return _storage().commitmentLedger.deliverableAggregate();
    }

    /// @notice Remaining-principal claim for a drawn event; zero once its row is released.
    /// @dev Physical layer-2 delivery still depends on the one shared live reserve.
    function coverageRemainingByDefault(uint256 tokenId) external view returns (uint256 remaining) {
        return _storage().commitmentLedger.deliverable(tokenId);
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules()
        external
        view
        returns (
            address bridge,
            address registry,
            address reserves,
            address controller,
            address curator,
            address oracle,
            address vault,
            address commitmentLedger
        )
    {
        DefaultStorage storage $ = _storage();
        return (
            address($.bridge),
            address($.registry),
            address($.reserves),
            address($.controller),
            address($.curator),
            address($.oracle),
            $.vault,
            address($.commitmentLedger)
        );
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _ltv(DefaultStorage storage $, uint256 tokenId) private view returns (uint256 ltvBps, uint64 asOf) {
        return DefaultAccrualLib.loanToValue($, tokenId);
    }

    /// @dev The margin path exists only for live marked-to-market facilities.
    ///      Every margin entry validates this before touching continuous-interest state.
    function _mtmFacility(DefaultStorage storage $, uint256 tokenId)
        private
        view
        returns (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p)
    {
        f = $.bridge.facility(tokenId);
        p = $.registry.classParams(f.classId);
        if (p.model != ICollateralRegistry.CollateralModel.MarkedToMarket) {
            revert DefaultManager_NotMarkedToMarket(tokenId);
        }
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
    }

    function _requireKnownClass(uint256 classId) private pure {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert DefaultManager_UnknownClass(classId);
    }

    /// @dev ADR-0022: capture the loan's current outstanding as its at-risk contribution to the
    ///      class's unrealized-impairment pool. Called once, when the loan enters default.
    function _recordDefaulted(DefaultStorage storage $, uint256 tokenId, uint256 classId) private {
        DefaultAccrualLib.recordDefaulted($, tokenId, classId);
    }

    /// @dev AUDIT FIX (H-5, REDESIGN): remove a facility's reversible past-due mark from the
    ///      per-facility, per-class and global aggregates and clear its flag. Idempotent — a no-op
    ///      for a facility that is not flagged — so its callers cannot double-release. Callers:
    ///      `declareDefault` (calls it unconditionally to CONVERT a past-due facility to the
    ///      declared pool), `clearPastDue` (servicer cure, guards on the flag first), and
    ///      `onPerformingRepayment` (full-repayment branch). Together with the partial-repayment
    ///      re-anchor in `onPerformingRepayment` (which shrinks `pastDuePrincipal`/`pastDueExposure`
    ///      directly), these are the ONLY ways the past-due pool shrinks, so it always equals the
    ///      sum of the live per-facility contributions.
    function _releasePastDue(DefaultStorage storage $, uint256 tokenId, uint256 classId) private {
        DefaultAccrualLib.releasePastDue($, tokenId, classId);
    }

    /// @dev An incoming backstop must declare the full delivery interface and expose every read
    ///      surface the conservative-NAV path uses. A capacity-only or read-only stand-in must
    ///      never be installed: the realization path calls `coverShortfall` to deliver value.

    /// @dev ERC-165 identity probe, bounded so a hostile candidate cannot burn the caller's gas.
    ///      This is an installation check; outgoing readability remains independent so a legacy
    ///      incumbent can still be replaced when its capacity view has become unreadable.

    /// @dev Capability probe for every read the conservative-NAV path requires. ERC-165 identity
    ///      is deliberately not used: an already-deployed SGrove may implement the complete
    ///      surface while advertising an interface id from before `coverageReserve()` and
    ///      `remainingCoverage()` were added. Bounded staticcalls keep malformed or hostile
    ///      candidates from consuming unbounded validation gas.

    /// @dev Upgrade authorization is role-only. A UUPS upgrade executes this hook in the
    ///      incumbent implementation, so it cannot truthfully enforce an ordering dependency on
    ///      APIs introduced by the candidate. Backstop capability is enforced when the dependency
    ///      is installed through `setBackstop`; no false in-place ordering guarantee is claimed.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        DefaultAccrualLib.requireIdle(_storage(), _reentrancyGuardEntered());
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        DefaultAccrualLib.requireIdle(_storage(), _reentrancyGuardEntered());
        return super._revokeRole(role, account);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        DefaultAccrualLib.requireIdle(_storage(), _reentrancyGuardEntered());
    }

    /// @dev The one bound on how long a protocol-side blocker may delay a PIK mark: ONE extra class
    ///      grace window past the ordinary `graceEnd`, and not a second more.
    ///
    ///      COMPUTED IN uint256 ON PURPOSE. `graceEnd` is a `uint64` sum that 0.8.x would revert on
    ///      overflow, and a revert here would brick `markPastDue` for a facility whose due date sits
    ///      near the end of the `uint64` range - the same denial of service the bounded probes exist
    ///      to prevent. Widening makes the extension saturate harmlessly instead: a comparison
    ///      against `block.timestamp` can never be satisfied past that horizon anyway.
    ///
    ///      A ZERO GRACE WINDOW MEANS NO EXTENSION. A class whose risk owner granted no cure period
    ///      does not acquire one because the crank stalled; the facility is markable on the ordinary
    ///      clock. That is deliberate and is the conservative direction.
    function _pikExtendedGraceEnd(DefaultStorage storage $, uint64 graceEnd, ClaimBridge.Facility memory f)
        private
        view
        returns (uint256)
    {
        uint256 window = uint256($.graceWindows[f.classId]);
        uint256 bound = uint256(graceEnd) + window;

        // THE BOUND MAY NOT EXPIRE BEFORE THE OBLIGATION IT WOULD MARK EXISTS. ROUND EIGHT, and this
        // is the one defect it found that two independent verifiers both reproduced with their own
        // fixtures and both rated medium.
        //
        // `capitalizePik` advances the schedule only while the NEXT period still ends on or before
        // maturity (`WaterfallEngine.sol`: `if (nextDue > plan.previousDue && nextDue <= plan.maturity)`).
        // On a facility whose maturity is not a whole number of intervals away, the final crank
        // therefore capitalises and then SKIPS `setNextPaymentDue`, which freezes `f.nextPaymentDue`
        // at the second-to-last date for the rest of the facility's life. The engine reports the
        // resulting clock desync as protocol-blocked for ever, correctly.
        //
        // The extension was anchored on that frozen date, so it expired `2 x window` after it - and
        // when `paymentInterval > 2 x window` that instant falls BEFORE MATURITY. A PIK facility was
        // then marked past due while the protocol was refusing its crank AND the borrower owed
        // nothing at all: under PIK there is no cash obligation before maturity, because `distribute`
        // reverts `Waterfall_PikCashInterestNotPermitted` on any PIK interest leg. A credit event
        // manufactured out of the protocol's own schedule arithmetic, with no pause, no amendment and
        // no privileged action anywhere in the path.
        //
        // IT IS ORDINARY CONFIGURATION, NOT A CONTRIVANCE, and it cannot be configured away. A
        // quarterly PIK facility (90-day interval) against the 21-day class grace default satisfies
        // `paymentInterval > 2 x window`, and `setGraceWindow` is hard-capped at
        // `Config.DEFAULT_REDEEM_COOLDOWN` (21 days) while `paymentInterval` is bounded only by
        // `<= nextPaymentDue`. MEASURED by the verifiers on a 90-day/410-day facility: marked SEVEN
        // DAYS BEFORE MATURITY, 1,147,523.000625e18 of exposure, senior impairment
        // 73,761.5003125e18 immediately and 147,523.000625e18 at full ramp.
        //
        // SO THE TERMINAL PERIOD GETS ITS WINDOW FROM MATURITY. The test below is the engine's own
        // skip condition, recomputed from fields this contract already reads: once
        // `nextPaymentDue + paymentInterval > maturity` the schedule can never advance again, so the
        // frozen date is not an obligation and the only one left is the balloon at maturity.
        //
        // THIS IS NOT THE MATURITY TEST ROUND SEVEN REMOVED, and the difference is the whole point.
        // That one used maturity to decide WHETHER to shelter, which is what made it reachable
        // through every predicate nobody had enumerated. This one uses maturity to decide WHEN THE
        // OBLIGATION EXISTS, and the bound is still a single capped elapsed-time window measured from
        // it. A matured non-payer is markable one window after the balloon falls due, which is round
        // six's requirement, and nothing mid-term is sheltered one second longer than before: for any
        // facility whose schedule can still advance the test is false and `bound` is untouched.
        //
        // It also answers what the 2026-09-10 handover recorded as an open Forest Road question -
        // "should a PIK balloon get its cure window from maturity rather than from a stale
        // `nextPaymentDue`" - in the only direction that does not manufacture a credit event.
        if (uint256(f.nextPaymentDue) + uint256(f.paymentInterval) > uint256(f.maturity)) {
            uint256 terminal = uint256(f.maturity) + window;
            if (terminal > bound) bound = terminal;
        }
        return bound;
    }

    function _storage() private pure returns (DefaultStorage storage $) {
        assembly {
            $.slot := DEFAULT_STORAGE_LOCATION
        }
    }
}
