// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
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
///      role-gated paths (declareDefault/accelerate/realizeLoss) are deliberately NOT
///      pausable: suppressing loss recognition is never an emergency remedy.
contract DefaultManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IDefaultManager,
    ICommitmentPrincipalSource
{
    uint256 private constant BACKSTOP_PROBE_GAS = 200_000;
    uint256 private constant COVER_DELEGATE_SELECTOR =
        0xc4e35fac00000000000000000000000000000000000000000000000000000000;

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
        // ── ADR-0022 conservative-redemption-NAV impairment tracking (append-only tail) ──
        // Per-class outstanding principal of loans in Defaulted/Accelerated state whose loss
        // is NOT yet realized. `pendingSeniorImpairment()` nets this against junior capacity
        // (curator pool per class, then sGROVE) to mark redemptions. It moves on exactly four
        // paths, and this list is exhaustive:
        //   += deployedTo                     at declare/liquidate (`_recordDefaulted`);
        //   -= the realized loss              at `realizeLoss` (`_reduceDefaulted`);
        //   -= the whole remainder            at a clean resolve (`onDefaultResolved`);
        //   -= principal RECOVERED IN CASH    at a partial recovery (`onDefaultRecovery`), and
        //                                     again as a backstop clamp inside
        //                                     `_reduceDefaulted` (AUDIT FIX H-2).
        // The last path is the H-2 fix: a recovery on a still-defaulted facility lowers
        // `deployedTo` in the ReserveManager, and without it the contribution stayed pinned at
        // the pre-recovery snapshot — an over-mark that nothing on-chain could ever clear.
        // Every decrement is mirrored one-for-one into `defaultedContribution[tokenId]` below,
        // so the class pool is always exactly the sum of its live per-token contributions.
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
        // ── AUDIT FIX H-5: permissionless past-due accounting trigger (append-only TAIL) ──
        // (REDESIGNED 2026-07-22 — final-audit findings #1/#2.) Receivable classes store `maturity`
        // but never read it after funding, so between a missed payment and a servicer's discretionary
        // `declareDefault` a past-due facility was priced at PAR and seniors exited at par.
        //
        // The FIRST H-5 fix drove `markPastDue` into `LoanState.Defaulted` — the SAME slot
        // `declareDefault` uses — which (a) permanently foreclosed a later `declareDefault`/
        // `RemedyInitiated` (no ClaimBridge edge back from Defaulted), (b) de-gated `realizeLoss`
        // from the `DefaultDeclared` attestation, and (c) let anyone freeze a curing facility.
        //
        // THE REDESIGN. `markPastDue` no longer touches `LoanState` or the curator: it sets a
        // REVERSIBLE per-facility `pastDueMarked` flag and records the facility's at-risk principal
        // into a SEPARATE past-due pool (`pastDueContribution` per token, `pastDuePrincipal` per
        // class, `pastDueExposure` the global aggregate). `pendingSeniorImpairment` adds
        // `pastDuePrincipal[classId]` alongside `declaredDefaultedPrincipal[classId]` when it nets
        // against junior capacity, so a past-due facility depresses the conservative senior NAV — the
        // honest mark — WITHOUT foreclosing the legal path or being able to trigger a loss (a merely
        // past-due facility stays `Active`/`Amortizing`, and `realizeLoss` requires
        // `Defaulted`/`Accelerated`, reachable only via the attested `declareDefault`). The mark is
        // removed/reduced by four paths: `clearPastDue` (servicer cure); `declareDefault` (converts
        // to the declared pool, releasing before recording so the facility counts exactly once,
        // never both); and `onPerformingRepayment` (called by the waterfall on the ordinary
        // performing repayment path — re-anchors the mark DOWN to live `deployedTo` as the facility
        // amortizes, and fully clears it on a full repayment, so a facility that cures through the
        // normal path stops depressing the NAV without a manual clear — the H-2 re-anchor, applied
        // to the past-due pool). Any residual over-mark is the safe direction (NAV lower, exits
        // cheaper, seniors protected) and is always clearable on-chain, so unlike H-2 it can never
        // strand.
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
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || m.bridge == address(0)
                || m.registry == address(0) || m.reserves == address(0) || m.controller == address(0)
                || m.curator == address(0) || m.oracle == address(0) || m.usdfr == address(0) || m.vault == address(0)
        ) revert DefaultManager_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        DefaultStorage storage $ = _storage();
        $.bridge = ClaimBridge(m.bridge);
        $.registry = ICollateralRegistry(m.registry);
        $.reserves = IReserveManager(m.reserves);
        $.controller = IMintRedeemController(m.controller);
        $.curator = ICuratorModule(m.curator);
        $.oracle = IAttestationOracle(m.oracle);
        $.usdfr = IERC20(m.usdfr);
        $.vault = m.vault;
        // The implementation constructor deployed the factory; it now deploys one ledger owned
        // by this proxy, keeping the child creation code out of this runtime.
        $.commitmentLedger = ICommitmentLedger(address(commitmentLedgerFactory.create(address(this))));
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.cureWindows[classId] = Config.DEFAULT_MARGIN_CURE_WINDOW;
            emit CureWindowSet(classId, Config.DEFAULT_MARGIN_CURE_WINDOW);
            // AUDIT FIX (H-5): the past-due grace window defaults to (and is capped at) the
            // redemption cooldown. Governance may only ever lower it (see `setGraceWindow`'s cap).
            // The cap bounds the maturity-anchored marking lag; it does NOT fully cover the
            // request-anchored redemption cooldown (a partial par-exit window survives — documented).
            $.graceWindows[classId] = Config.DEFAULT_REDEEM_COOLDOWN;
            emit GraceWindowSet(classId, Config.DEFAULT_REDEEM_COOLDOWN);
        }
    }

    /// @inheritdoc IDefaultManager
    /// @dev W6-B3/W7 migration path for a proxy upgraded from an implementation that predates the
    ///      append-only ledger address. W7 registers rows at DECLARATION, not first draw, so a
    ///      fresh child is safe only while there is no live declared principal at all.
    function initializeCommitmentLedger() external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefaultStorage storage $ = _storage();
        address current = address($.commitmentLedger);
        if (current != address(0)) revert DefaultManager_CommitmentLedgerAlreadySet(current);
        uint256 consumed = $.liveDefaultCoverageConsumed;
        if (consumed != 0) revert DefaultManager_CommitmentLedgerMigrationUnsafe(consumed);
        uint256 declared;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            declared += $.declaredDefaultedPrincipal[classId];
        }
        if (declared != 0) revert DefaultManager_CommitmentLedgerMigrationUnsafe(declared);
        address ledger = address(commitmentLedgerFactory.create(address(this)));
        $.commitmentLedger = ICommitmentLedger(ledger);
        emit CommitmentLedgerSet(ledger);
    }

    // ── Receivable remedy path (SERVICER_ROLE; never pausable) ───────────

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
        _consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, evidenceHash)),
            false
        );
        // Pin all pre-default management/performance economics before the conservative
        // marked NAV changes. The new impairment then lowers NAV against the old HWM.
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
        _advanceImpairmentRevision($);
        bytes32 ref = $.remedyRefs[f.classId];
        emit DefaultDeclared(tokenId, f.classId, ref);
        emit RemedyInitiated(tokenId, f.classId, ref);
    }

    /// @inheritdoc IDefaultManager
    function accelerate(uint256 tokenId) external onlyRole(Roles.SERVICER_ROLE) nonReentrant {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Defaulted) revert DefaultManager_NotInDefault(tokenId);
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Accelerated);
        emit Accelerated(tokenId);
    }

    /// @inheritdoc IDefaultManager
    /// @dev Order matters for ADR-0012: all burns execute BEFORE the write-down, so the
    ///      backing invariant asserted inside each `burnLoss` sees supply falling while
    ///      backing is still whole; the write-down then drops backing by exactly the
    ///      amount supply already fell. Nothing in between can observe a violation.
    function realizeLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
    {
        if (loss == 0) revert DefaultManager_ZeroAmount();
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Defaulted && f.state != ClaimBridge.LoanState.Accelerated) {
            revert DefaultManager_NotInDefault(tokenId);
        }
        // Block-scoped so `outstanding` does not survive into the cascade body: ADR-0034 Y-bis's
        // layer-0 local (`allocatable`) pushed this function over the stack limit otherwise.
        {
            uint256 outstanding = $.reserves.deployedTo(tokenId);
            if (loss > outstanding) revert DefaultManager_LossExceedsOutstanding(tokenId, loss, outstanding);
        }
        // C4-01: the durable oracle fact key uses the economic evidence identity, not
        // signature salt; a zero evidence id would collapse distinct equal-sized events.
        if (evidenceHash == bytes32(0)) revert DefaultManager_ZeroEvidenceHash();
        _consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(tokenId, loss, evidenceHash)),
            true
        );

        // Crystallize all pre-loss fees before any cascade leg moves value. The HWM then
        // remains at the pre-loss post-fee peak, so recovery from this loss is never charged
        // again as performance. A later revert rolls this checkpoint back atomically.
        IsUSDfr($.vault).accrueFees();

        // ── layer 0: junior absorption ALREADY PAID FORWARD by senior exits ───
        // ADR-0034 Y-bis — LOAD-BEARING, DO NOT DELETE. See `exitPrepaidAbsorption`'s field
        // NatSpec for the full derivation. Without this the junior tranche pays TWICE for one
        // loss: once at the exit draw, again here.
        uint256 allocatable = loss - $.reserves.consumeExitPrepayment(tokenId, loss);

        // ── layer 1: curator first-loss (always consulted first) ──────────
        uint256 absorbed;
        uint256 residual;
        if (allocatable != 0) (absorbed, residual) = $.curator.absorbLoss(f.classId, allocatable);

        // ── layer 2: sGROVE backstop (only for the residual) ──────────────
        // ADR-0035 draws from the shared live reserve. The event row is synchronized inside the
        // helper so its post-draw principal state never has to live in this frame.
        uint256 covered = _drawLayer2ForLiveDefault($, tokenId, f.classId, residual);

        // ── burn junior layers' absorption from this contract ─────────────
        uint256 selfBurn = absorbed + covered;
        if (selfBurn != 0) $.controller.burnLoss(address(this), selfBurn);

        // ── layer 3: depositor principal (only past BOTH junior layers) ───
        // NOTE (ADR-0034 Y-bis): `allocatable`, not `loss`. The layer-0 prepayment has already
        // been burned out of junior capital by the exit that drew it, so charging the vault for
        // it here would burn the same dollar of supply twice.
        uint256 depositorLoss = allocatable - selfBurn;
        if (depositorLoss != 0) {
            // ADR-0023: bound by the vault's VESTED assets, not its raw USDfr balance. The
            // balance also contains realized yield still streaming in, which is not yet
            // credited to any share. Burning into it would leave `unvestedYield()` above the
            // balance, collapsing `totalAssets()` to zero for the rest of the stream — a
            // §1.3 exchange-rate monotonicity break far larger than the loss itself, and
            // fatal to the TWAP rate oracle. Bounding here keeps `balance >= unvested` true
            // by construction; the vault's own clamp is then unreachable defence-in-depth.
            // Strictly the CONSERVATIVE direction: it can only make `realizeLoss` revert
            // earlier into the existing governance-intervention path, never absorb more.
            uint256 vaultAssets = IsUSDfr($.vault).totalAssets();
            if (vaultAssets < depositorLoss) {
                // beyond total absorption capacity: unstaked USDfr would be impaired —
                // fail loudly; governance must intervene (CLAUDE.md prime directive 4).
                //
                // AUDIT FIX (G3) — WHAT "INTERVENE" NOW MEANS ON-CHAIN. This revert rolls back
                // the whole call INCLUDING `reserves.recordPrincipalWritedown` below, so before
                // G3 there was no way to state that the unabsorbable portion had become
                // worthless: backing stayed at face, `backingInvariantHolds()` reported true
                // against that fiction, and 1:1 minting continued. The intervention is
                // `ReserveManager.recognizePrincipalImpairment(tokenId, residual, evidence)` —
                // a governance valuation act that lowers backing without burning supply, leaving
                // this cascade to allocate whatever capital does exist. DO NOT relax this bound
                // to "make the loss go through": that would impair unstaked USDfr holders, who
                // sit outside the §1.3 cascade entirely.
                revert DefaultManager_LossExceedsAbsorptionCapacity(tokenId, depositorLoss, vaultAssets);
            }
            $.controller.burnLoss($.vault, depositorLoss);
        }

        // ── pair the write-down with the burns, atomically (ADR-0012) ─────
        $.reserves.recordPrincipalWritedown(tokenId, loss);
        $.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, loss);
        // ADR-0022: the realized portion leaves the at-risk (unrealized-impairment) pool —
        // it is now reflected in the vault's balance via the layer-3 burn above.
        _reduceDefaulted($, tokenId, f.classId, loss);
        // A write-down can be the final act of a workout (including a zero-recovery
        // resolution, or cash recovered before the residual is written off). Previously
        // only WaterfallEngine's final cash repayment could enter `Resolved`, so a full
        // write-off left a zero-outstanding NFT permanently `Defaulted`/`Accelerated`.
        // Transition here once the atomic write-down has exhausted the outstanding.
        if ($.reserves.deployedTo(tokenId) == 0) {
            $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Resolved);
        }
        _advanceImpairmentRevision($);

        emit LossRealized(tokenId, f.classId, loss, absorbed, covered, depositorLoss);
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
        // `ReserveManager._allocateReserveLoss` sizes `requiredSupplyReduction` off LIVE supply and
        // backing, so an earlier exit draw has already shrunk it. Consuming the ledger here would
        // credit the same draw a second time.
        allocation.backstopCovered = _coverFromBackstop($, incidentId, residual);
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
    ///      LAYER 1 IS CLASS-LESS, AND THAT IS A DELIBERATE DEVIATION FROM THE LETTER OF Y-bis.
    ///      Y-bis says "curator first-loss PER CLASS". A redemption has no collateral class, and
    ///      the deficit it prices against (`totalUSDfr() - backingValue()`) is not class-attributed
    ///      on-chain — it can be produced by a class-less idle write-down with no facility
    ///      involved at all. So this uses `absorbGlobalLoss`, pro-rata by the five pools'
    ///      SNAPSHOTTED balances, exactly as the live ReserveManager custody cascade's
    ///      `_drawJuniorReserveLoss` does: "the capital actually standing at risk". A curator may
    ///      reasonably object to funding another class's exit price. THIS NEEDS FOREST ROAD
    ///      SIGN-OFF AND MUST NOT BE GLOSSED.
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
        uint256 covered = _coverFromBackstop($, SENIOR_EXIT_EVENT_ID, residual);

        drawn = absorbed + covered;
        if (drawn != 0) {
            // The ledger lives in `ReserveManager` — see its `exitPrepaidAbsorption` field NatSpec
            // for why (the bound is the recognised mark, which is that contract's state).
            $.reserves.recordExitPrepayment(drawn);
            // ADR-0027: junior pool balances just moved, so any assessment taken against the old
            // balances is stale. Same reason `realizeLoss` advances it.
            _advanceImpairmentRevision($);
        }
        emit SeniorExitDrawn(required, absorbed, covered);
    }

    // ── Past-due accounting trigger (permissionless; NOT pausable) ───────

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-5, REDESIGNED 2026-07-22 — final-audit findings #1/#2). Receivable classes
    ///      (1-4) store `maturity` but never read it after funding, so a facility that had defaulted
    ///      on payment was priced at PAR — and seniors exited at par — for the whole window between
    ///      the missed payment and a SERVICER's discretionary `declareDefault`. This closes that gap
    ///      by giving the maturity clock an on-chain, permissionless, REVERSIBLE consequence.
    ///
    ///      REVERSIBLE MARK, NOT A DEFAULT. The first H-5 fix drove the facility to
    ///      `LoanState.Defaulted` — the same slot `declareDefault` uses — which foreclosed a later
    ///      `declareDefault`/`RemedyInitiated` (the on-chain legal-remedy trigger) forever and
    ///      de-gated `realizeLoss` from the `DefaultDeclared` attestation. This redesign instead sets
    ///      a REVERSIBLE per-facility flag and records the facility's at-risk principal into a
    ///      SEPARATE past-due pool that `pendingSeniorImpairment` nets against junior capacity
    ///      exactly like the declared pool. The facility stays `Active`/`Amortizing`, so:
    ///        - `declareDefault`/`RemedyInitiated` stay reachable (it only reverts on
    ///          non-Active/Amortizing), and it CONVERTS the mark (releases past-due, records
    ///          declared) — no double count; and
    ///        - `realizeLoss` (state ∈ {Defaulted, Accelerated}) is UNREACHABLE from a merely
    ///          past-due facility, so the `DefaultDeclared` gate on loss realization is preserved by
    ///          construction — the cascade cannot run without the attested `declareDefault`.
    ///
    ///      NO CURATOR FREEZE. Unlike `declareDefault`/`liquidate`, this does NOT
    ///      `curator.freezeOnDefault`: a reversible past-due mark must not freeze first-loss (that
    ///      was the permissionless-griefing sting). The curator freeze stays on the attested
    ///      `declareDefault` only, where a `realizeLoss` it could front-run actually exists.
    ///
    ///      PERMISSIONLESS IS SAFE HERE. With the redesign a bystander call can only depress the
    ///      conservative NAV reversibly — it can neither foreclose the legal path nor trigger a loss
    ///      — so anyone may assert the maturity clock elapsed (senior-protective) with no griefing
    ///      surface: a curing workout is not blocked (state and curator untouched) and the mark
    ///      clears (`clearPastDue`) or converts (`declareDefault`).
    ///
    ///      NO UNDER-MARK. `outstanding` is `reserves.deployedTo` at mark time — the full at-risk
    ///      principal and the largest loss the facility can produce (`realizeLoss` reverts above it,
    ///      and `deployedTo` never rises for a facility past funding) — so the mark is an upper
    ///      bound: over-mark direction only. A partial repayment after the mark (facility still
    ///      Active) lets the snapshot exceed live `deployedTo` — a safe OVER-mark that the servicer
    ///      clears via `clearPastDue`, and that `declareDefault` re-anchors to fresh `deployedTo` on
    ///      conversion. It can never STRAND: `clearPastDue` is callable in any state.
    ///
    ///      ACCOUNTING, NOT LEGAL (ADR-0007 legal-sync; CLAUDE.md prime directive 6). It starts the
    ///      accounting clock ONLY: no `DefaultDeclared` attestation is required and no
    ///      `RemedyInitiated` is emitted. The servicer's legal declaration remains separate.
    ///
    ///      NOT PAUSABLE. It reads no oracle mark — only `maturity` (immutable) and `block.timestamp`
    ///      — so there is no oracle-misbehaviour vector to suppress.
    function markPastDue(uint256 tokenId) external nonReentrant {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        // Receivable classes only: marked-to-market facilities are priced by their attested mark
        // and handled by the permissionless margin path, not the maturity clock.
        if ($.registry.classParams(f.classId).model != ICollateralRegistry.CollateralModel.Receivable) {
            revert DefaultManager_NotReceivable(tokenId);
        }
        // Only a live, performing facility can be marked.
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
        // Idempotent: the facility stays Active/Amortizing, so the state check no longer bars a
        // second call — guard on the flag so the past-due pool cannot double-count.
        if ($.pastDueMarked[tokenId]) revert DefaultManager_AlreadyPastDue(tokenId);
        uint64 graceEnd = f.nextPaymentDue + $.graceWindows[f.classId];
        if (block.timestamp <= graceEnd) revert DefaultManager_NotPastDue(tokenId, f.nextPaymentDue, graceEnd);

        // Marking is permissionless, so checkpoint deterministically inside the transition:
        // transaction ordering cannot choose whether elapsed pre-mark economics are charged.
        IsUSDfr($.vault).accrueFees();
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        // OWNER DECISION 2026-08-07 (G2W) — START THE COHORT RELIEF CLOCK, AND ONLY ON
        // EMPTY -> NON-EMPTY. LOAD-BEARING, DO NOT DELETE and DO NOT MAKE UNCONDITIONAL.
        //   - Deleting the write leaves the anchor at zero forever, which fails SAFE (full weight)
        //     but silently discards the owner decision — falsified by
        //     `test_g2w_ramp_theAnchorIsWrittenSoAFreshMarkGetsTheGovernedRelief`.
        //   - Making it unconditional lets a SECOND `markPastDue` re-anchor the clock to now and
        //     hand the whole standing cohort its relief back, indefinitely: mark a dust facility
        //     every 20 days and the 21-day expiry never fires. That is the attack the ramp exists
        //     to close — falsified by
        //     `test_g2w_ramp_aSecondMarkCannotRewindTheCohortClock`.
        // The test is on `pastDueExposure` BEFORE it is incremented below, so "empty" means "this
        // is the mark that creates the cohort".
        //
        // ── AUDIT FIX (SWEEP-3 S3-F3) — THE CLOCK IS KEYED TO THE PAYMENT EPISODE ──────────────
        //
        // LOAD-BEARING. DO NOT COLLAPSE THIS BACK TO AN UNCONDITIONAL
        // `if ($.pastDueExposure == 0) $.pastDueReliefAnchor = block.timestamp;`.
        //
        // WHAT WAS WRONG. The guard above closed the case its own comment names (a SECOND mark
        // while the cohort stands). It did NOT close the case where the cohort is EMPTIED and the
        // SAME, still-past-due facility is re-marked. `clearPastDue` (SERVICER_ROLE plus a
        // `PastDueCured` quorum — and finding A-02 records that the attester IS the servicer)
        // empties the cohort, and then the very next PERMISSIONLESS `markPastDue` — the protocol's
        // own self-healing act, which the H-5 design expects any bystander to perform — re-anchored
        // the clock to NOW and handed the whole cohort its 50% relief back.
        //
        // MEASURED: the same facility, uncured, unattested, still `Active`, past due for 120 days,
        // held at `pendingSeniorImpairment == 200,000e18` at EVERY 20-day cycle while the honest
        // full-weight mark is 400,000e18. The control — the identical facility left alone — holds
        // 400,000e18 throughout. THE REWIND, NOT THE PASSAGE OF TIME, SUPPRESSED THE MARK.
        // That defeats the owner decision's own stated bound: "the loud stop returns on its own
        // with nobody having to act ... This is what bounds the D5-03 under-mark to a window
        // instead of leaving it permanent." Seniors exiting inside the perpetual window take value
        // from seniors who stay.
        //
        // WHY A "STOOD CLEAR FOR A FULL RAMP" QUARANTINE WAS NOT ENOUGH, AND WAS REPLACED. The
        // first attempt at this fix refused a fresh window to any empty->non-empty transition that
        // happened within one ramp of the emptying. It closed the immediate clear-and-re-mark and
        // left the SAME attack at half duty cycle: clear, WAIT ONE RAMP with the book quiet, and
        // re-mark the same never-cured facility. The quarantine does not fire, the anchor is set to
        // NOW, and the identical facility is back at maximum relief — for ever, on a 42-day cycle.
        // It is also blind by construction: a single global cohort timestamp cannot tell "this
        // facility's episode" from "the book was quiet", so it can only ever guess.
        //
        // WHAT THE CLOCK IS ACTUALLY KEYED TO NOW. An OBJECTIVE DELINQUENT PAYMENT EPISODE:
        // the pair (`tokenId`, `ClaimBridge.Facility.nextPaymentDue`). `$.reliefEpisode[tokenId]`
        // stores that episode's due-date HIGH-WATER MARK and the timestamp of its FIRST mark, and
        // it is PERSISTENT — `clearPastDue`, `declareDefault` and `onPerformingRepayment` do not
        // touch it. So:
        //   - re-marking the SAME `nextPaymentDue` REUSES the original `startedAt`, whatever
        //     bookkeeping happened in between and however long the book stood clear. The relief
        //     keeps decaying and expires exactly one ramp after the episode's first mark, once;
        //   - a partial repayment that does NOT advance the due date is not a new episode either
        //     (`onPerformingRepayment` re-anchors the AMOUNT, never the clock);
        //   - only an authenticated servicing transition that ADVANCES `nextPaymentDue` — the
        //     attested performing payment through `WaterfallEngine.distribute` ->
        //     `ClaimBridge.setNextPaymentDue`, or a `TermsAmended`-quorum `amendTerms` — opens a
        //     new episode and re-arms the relief. That is RAMP-5, now tied to the servicing fact
        //     rather than to whether the book happened to be quiet.
        // The high-water comparison is `>`, not `!=`, so a due date moved BACKWARD can never buy a
        // fresh window; it reuses the older, more-elapsed timestamp, which is the safe direction.
        //
        // THE COHORT ANCHOR IS DERIVED, AND THE VIEW STAYS O(1). `ConservativeImpairmentMath` and
        // `CollateralRegistry.conservativeSeniorMark` still read ONE scalar
        // (`pastDueReliefAnchor`) — there is no enumeration on the pricing path, which is a hard
        // requirement for a view the redemption price is computed from. That scalar is maintained
        // here as the MINIMUM over the live cohort's episode starts, i.e. the OLDEST episode, i.e.
        // the MOST elapsed, i.e. the HIGHEST weight and the LARGEST mark:
        //   - joining a LIVE cohort takes `min(anchor, startedAt)`, so a fresh mark can never lift
        //     the cohort off an older episode's spent clock (RAMP-4), and the order in which two
        //     facilities are marked cannot change the answer;
        //   - on an EMPTY cohort the standing value is stale and unobservable (there is no past-due
        //     principal to weight), so it is REPLACED by this episode's `startedAt` — which, for a
        //     re-mark, is the ORIGINAL timestamp, not `block.timestamp`. That is what makes the
        //     rewind unreachable.
        // A release does NOT recompute the minimum: leaving the anchor on a departed facility's
        // older episode only ever OVER-marks the survivors, and D5-03 records under-marking as the
        // dangerous direction. Recomputing it would need an unbounded scan.
        //
        // Falsified by `test_S3_F3_theReliefExpiryMustNotBeRewindableByAClearAndReMark`,
        // `test_S3_F3_twentyDayCyclesHoldTheCohortAtMaximumReliefForever`,
        // `test_S5_episode_aFullRampOfQuietDoesNotBuyTheSameEpisodeAFreshWindow`,
        // `test_S5_episode_alternatingTwoFacilitiesCannotRewindEitherClock`,
        // `test_S5_episode_aPartialRepaymentThatDoesNotAdvanceTheDueDateDoesNotRestartRelief` and
        // `test_S5_episode_aGenuineNewPaymentEpisodeDoesRestartRelief`; RAMP-5
        // (`test_g2w_ramp_theCohortClockRestartsOnceThePoolEmpties`) pins the other direction.
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
        _advanceImpairmentRevision($);
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
        _consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(tokenId, evidenceHash)),
            true
        );
        IsUSDfr($.vault).accrueFees();
        uint256 classId = $.bridge.facility(tokenId).classId;
        _releasePastDue($, tokenId, classId);
        _advanceImpairmentRevision($);
    }

    // ── Marked-to-market fast path (permissionless; pausable) ────────────

    /// @inheritdoc IDefaultManager
    function marginCall(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
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
    /// @dev Curing demands FRESH evidence: the mark must be within the class's
    ///      `maxMarkAge`. (Protective triggers accept any-age marks; see contract note.)
    function clearMarginCall(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
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
        _advanceImpairmentRevision($);
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
    function onDefaultResolved(uint256 tokenId) external nonReentrant onlyRole(Roles.CREDIT_ROLE) {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Resolved) revert DefaultManager_NotResolved(tokenId);
        uint256 c = $.defaultedContribution[tokenId];
        if (c != 0) {
            if ($.coverageConsumedByDefault[tokenId] != 0) $.drawnDefaultPrincipal[f.classId] -= c;
            $.defaultedContribution[tokenId] = 0;
            $.declaredDefaultedPrincipal[f.classId] -= c;
            emit DefaultImpairmentCleared(tokenId, f.classId, c);
        }
        _releaseCoverageConsumption($, tokenId); // PM-R-11: no longer a live default
        _advanceImpairmentRevision($);
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
    ///      `ReserveManager.recordPrincipalReturn`/`recordPrincipalWritedown` directly, lowering
    ///      `deployedTo` without cash arriving or the cascade running, after which this
    ///      de-recognises a genuine loss. CREDIT_ROLE must never leave the module set.
    function onDefaultRecovery(uint256 tokenId) external nonReentrant onlyRole(Roles.CREDIT_ROLE) {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        // Defensive, mirroring `onDefaultResolved`: a CREDIT_ROLE caller must not be able to
        // re-anchor a facility that is not actually in default (its contribution is zero in
        // every other state anyway, so this is belt-and-braces, not load-bearing arithmetic).
        if (f.state != ClaimBridge.LoanState.Defaulted && f.state != ClaimBridge.LoanState.Accelerated) {
            revert DefaultManager_NotInDefault(tokenId);
        }
        uint256 c = $.defaultedContribution[tokenId];
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        if (stillAtRisk >= c) return; // idempotent: nothing recovered since the last anchor
        uint256 derecognized = c - stillAtRisk;
        if ($.coverageConsumedByDefault[tokenId] != 0) {
            $.drawnDefaultPrincipal[f.classId] -= derecognized;
        }
        $.defaultedContribution[tokenId] = stillAtRisk;
        $.declaredDefaultedPrincipal[f.classId] -= derecognized;
        emit DefaultImpairmentCleared(tokenId, f.classId, derecognized);
        // If recovery emptied the mark, release its historical consumption and live ledger row.
        // Unreachable from `WaterfallEngine.distribute` (a zero outstanding routes to
        // `onDefaultResolved` instead), kept so the two hooks cannot diverge.
        if (stillAtRisk == 0) _releaseCoverageConsumption($, tokenId);
        else $.commitmentLedger.updatePrincipal(tokenId, stillAtRisk);
        _advanceImpairmentRevision($);
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
    function onPerformingRepayment(uint256 tokenId) external onlyRole(Roles.CREDIT_ROLE) {
        DefaultStorage storage $ = _storage();
        if (!$.pastDueMarked[tokenId]) return; // no-op: the facility was never past-due
        uint256 classId = $.bridge.facility(tokenId).classId;
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        if (stillAtRisk == 0) {
            _releasePastDue($, tokenId, classId); // repaid in full: clear the mark entirely
            _advanceImpairmentRevision($);
            return;
        }
        uint256 c = $.pastDueContribution[tokenId];
        if (stillAtRisk >= c) return; // idempotent: nothing paid down since the last anchor
        uint256 derecognized = c - stillAtRisk;
        $.pastDueContribution[tokenId] = stillAtRisk;
        $.pastDuePrincipal[classId] -= derecognized;
        $.pastDueExposure -= derecognized;
        _advanceImpairmentRevision($);
        emit PastDueReanchored(tokenId, classId, derecognized);
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @inheritdoc IDefaultManager
    function setRemedyRef(uint256 classId, bytes32 remedyRef_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        _storage().remedyRefs[classId] = remedyRef_;
        emit RemedyRefSet(classId, remedyRef_);
    }

    /// @inheritdoc IDefaultManager
    function setCureWindow(uint256 classId, uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function setGraceWindow(uint256 classId, uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        if (window > Config.DEFAULT_REDEEM_COOLDOWN) {
            revert DefaultManager_GraceWindowTooLong(window, Config.DEFAULT_REDEEM_COOLDOWN);
        }
        _storage().graceWindows[classId] = window;
        emit GraceWindowSet(classId, window);
    }

    /// @inheritdoc IDefaultManager
    function setBackstop(address backstop_) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _validateBackstop(backstop_);
        DefaultStorage storage $ = _storage();
        address oldBackstop = address($.backstop);
        if (oldBackstop != backstop_) {
            // Bill elapsed management fees against the outgoing NAV whenever it remains
            // readable. If it is broken, install the already-validated replacement first so
            // governance retains a one-transaction repair path.
            bool oldReadable = oldBackstop == address(0) || _isBackstopReadable(oldBackstop);
            if (oldReadable) IsUSDfr($.vault).beginFeeNeutralMarkedNavChange();
            $.backstop = ICascadeBackstop(backstop_);
            _advanceImpairmentRevision($);
            if (!oldReadable) IsUSDfr($.vault).beginFeeNeutralMarkedNavChange();
            IsUSDfr($.vault).endFeeNeutralMarkedNavChange();
        }
        emit BackstopSet(backstop_);
    }

    // ── Guardian (permissionless triggers only) ──────────────────────────

    /// @notice Pauses the permissionless margin-path triggers. Emergency use only
    ///         (e.g. suspect marks); role-gated remedy paths are never pausable.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the permissionless triggers.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
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
        return _storage().pastDueExposure;
    }

    /// @inheritdoc IDefaultManager
    function pastDueContribution(uint256 tokenId) external view returns (uint256) {
        return _storage().pastDueContribution[tokenId];
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
        DefaultStorage storage $ = _storage();
        return keccak256(abi.encode(_impairmentRiskStateHash($), _impairmentBackstopCapacity($)));
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

    function _impairmentRiskStateHash(DefaultStorage storage $) private view returns (bytes32 stateHash) {
        stateHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.impairmentRevision,
                address($.curator),
                address($.backstop),
                $.liveDefaultCoverageConsumed,
                // F-S3-01: the reachable-coverage ledger replaces the deprecated capacity floor
                // here too. An ADR-0027 assessment must invalidate when the layer-2 credit the NAV
                // can net MOVES, and after this fix that quantity is this one; hashing the frozen
                // deprecated slot would make the identity blind to every draw and release.
                $.commitmentLedger.deliverableAggregate(),
                $.pastDueExposure
            )
        );
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            stateHash = keccak256(
                abi.encode(
                    stateHash,
                    classId,
                    $.declaredDefaultedPrincipal[classId],
                    $.pastDuePrincipal[classId],
                    $.curator.poolBalance(classId),
                    $.drawnDefaultPrincipal[classId]
                )
            );
        }
    }

    function _impairmentBackstopCapacity(DefaultStorage storage $) private view returns (uint256) {
        return address($.backstop) == address(0) ? 0 : $.backstop.coverageCapacity();
    }

    /// @inheritdoc IDefaultManager
    /// @dev ADR-0022 conservative-redemption NAV. The senior (sUSDfr) principal that
    ///      declared-but-unrealized defaults would impair AFTER the junior layers absorb, in
    ///      strict cascade order: curator first-loss per CLASS, then the global sGROVE backstop.
    ///
    ///      **THE ARITHMETIC LIVES IN `ConservativeImpairmentMath`, NOT HERE (EIP-170).** This
    ///      manager had 215 bytes of runtime margin, so the drawn/undrawn split, the per-class
    ///      curator netting, the PM-R-11 / F-18-01 backstop netting and the OWNER DECISION
    ///      2026-08-07 (G2W) unattested-past-due clamp-and-ramp were extracted verbatim behind the
    ///      `IImpairmentSource` seam. Read that contract for the algorithm and the reasoning it
    ///      carries; the answer here is bit-identical to the pre-extraction body and
    ///      `ConservativeImpairmentMathEquivalence.t.sol` fuzzes that claim rather than asserting
    ///      it. DO NOT re-inline: the margin recovered by this extraction is what unblocks further
    ///      remediation in this contract. Concretely, the G2W synthesis costs 204 bytes and this
    ///      contract had 215 — without the extraction the two changes could not both ship.
    ///
    ///      The forwarder passes `address(this)`, which under a proxy is the PROXY — the account
    ///      whose ERC-7201 storage holds the impairment pool. The calculator reads it back through
    ///      the narrow read-only `IConservativeImpairmentBook`, so it can observe this manager but
    ///      never act on it.
    function pendingSeniorImpairment() external view returns (uint256) {
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
        DefaultStorage storage $ = _storage();
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            impairment += $.declaredDefaultedPrincipal[classId] + $.pastDuePrincipal[classId];
        }
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
        return _storage().pastDuePrincipal[classId];
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

    function _consumeExact(
        DefaultStorage storage $,
        uint256 tokenId,
        IAttestationOracle.AttestationKind kind,
        bytes32 expected,
        bool consume
    ) private {
        (bytes32 payload,, bool ok) = $.oracle.latestPayload(tokenId, kind);
        if (!ok || payload != expected) revert DefaultManager_DefaultNotAttested(tokenId);
        if (consume) $.oracle.consume(tokenId, kind);
    }

    /// @dev Attested LTV in bps: outstanding principal over the latest mark. A facility
    ///      with no mark at all cannot use the margin path (reverts NoValuation).
    /// @dev LAYER 2 helper shared by facility `realizeLoss` and `drawForSeniorExit`. The retained
    ///      `absorbReserveLoss` compatibility entry also calls it, but no production source calls
    ///      that entry; live custody losses use `ReserveManager._drawJuniorReserveLoss` and its own
    ///      equivalent balance-delta check. This helper takes `residual` — layer 1's leftover — and
    ///      NOTHING ELSE, which makes "never before layer 1, never for more than layer 1 declined"
    ///      a property of the dataflow rather than a comment.
    ///
    ///      THE STRICT EQUALITY IS THE `ICascadeBackstop` CONTRACT (AUDIT FIX L) — DO NOT RELAX IT
    ///      TO `received >= covered`. Over-delivery would strand USDfr at this contract AND make
    ///      the senior layer over-absorb, because every caller computes its layer-3 charge from
    ///      `covered`. Falsified in both directions by the existing backstop-double suites.
    /// @dev Layer 2 for a facility default: draw the shared reserve, then mark this row drawn.
    ///      ADR-0035 gives a drawn row no frozen room; its claim bound is only its remaining
    ///      principal, and the ledger applies the live shared reserve during every mark-time walk.
    function _drawLayer2ForLiveDefault(DefaultStorage storage $, uint256 tokenId, uint256 classId, uint256 residual)
        private
        returns (uint256 covered)
    {
        bool firstDraw;
        covered = _coverFromBackstop($, tokenId, residual);
        if (covered == 0) return 0;
        uint256 remainingPrincipal = $.defaultedContribution[tokenId];
        firstDraw = $.commitmentLedger.sync(tokenId, remainingPrincipal, remainingPrincipal, covered);
        if (firstDraw) {
            // Historical drawn-cohort observability; no distinct cap arithmetic survives.
            $.drawnDefaultPrincipal[classId] += $.defaultedContribution[tokenId];
        }
        $.coverageConsumedByDefault[tokenId] += covered;
        $.liveDefaultCoverageConsumed += covered;
    }

    function _coverFromBackstop(DefaultStorage storage $, uint256 eventId, uint256 residual)
        private
        returns (uint256 covered)
    {
        address backstopAddress = address($.backstop);
        address asset = address($.usdfr);
        address ledger = address($.commitmentLedger);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, COVER_DELEGATE_SELECTOR)
            mstore(add(ptr, 0x04), backstopAddress)
            mstore(add(ptr, 0x24), asset)
            mstore(add(ptr, 0x44), eventId)
            mstore(add(ptr, 0x64), residual)
            let ok := delegatecall(gas(), ledger, ptr, 0x84, ptr, 0x20)
            if iszero(ok) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            covered := mload(ptr)
        }
    }

    function _ltv(DefaultStorage storage $, uint256 tokenId) private view returns (uint256 ltvBps, uint64 asOf) {
        uint256 value;
        (value, asOf) = $.oracle.latestValuation(tokenId);
        if (value == 0) revert DefaultManager_NoValuation(tokenId);
        ltvBps = $.reserves.deployedTo(tokenId) * Config.BPS / value;
    }

    /// @dev The margin path exists only for live marked-to-market facilities.
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
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        $.defaultedContribution[tokenId] = outstanding;
        $.declaredDefaultedPrincipal[classId] += outstanding;
        // The event must exist before its first draw so the conservative walk can allocate its
        // class curator capital and the one shared ADR-0035 reserve.
        $.commitmentLedger.register(tokenId, classId, outstanding);
    }

    /// @dev ADR-0022: reduce a loan's impairment contribution (and its class pool) by up to
    ///      `amount` (clamped so a partial/over realizeLoss can never underflow the pool), then
    ///      re-anchor what is left to the principal that is actually still at risk.
    ///
    ///      AUDIT FIX (H-2). The contribution was snapshotted from `deployedTo` at declare and
    ///      only ever decremented by realized loss, but a principal RECOVERY on a defaulted
    ///      facility (`WaterfallEngine.distribute` on a Defaulted/Accelerated loan) reduces
    ///      `deployedTo` without telling this contract. Recover part, write off the rest, and the
    ///      loan lands at `deployedTo == 0` with a contribution equal to the CASH RECOVERED —
    ///      stranded forever, because `Resolved` is only reachable through `distribute`'s
    ///      `outstanding == 0` branch and `distribute` reverts once outstanding is zero. The
    ///      On the pre-ADR-0035 tree the stranded mark also pinned
    ///      `liveDefaultCoverageConsumed` and its capacity floor, under-netting the backstop for
    ///      every FUTURE default. Those fields are now historical, but the stuck mark itself is
    ///      still the defect this re-anchor prevents.
    ///
    ///      The re-anchor is `min(remaining, deployedTo(tokenId))`, taken AFTER
    ///      `recordPrincipalWritedown` so `deployedTo` is already net of this loss. It cannot
    ///      UNDER-mark: `realizeLoss` reverts when `loss > deployedTo(tokenId)`, so the largest
    ///      senior loss this facility can ever still produce is exactly its current
    ///      `deployedTo`, and `deployedTo` never rises for a defaulted loan (it only grows in
    ///      `recordDeployment`/`recordFeeCapitalization`, both reachable only from a Pending
    ///      facility). Everything the clamp removes is principal that is provably no longer
    ///      losable — either repaid in cash or already written down.
    ///
    ///      BELT AND BRACES ONLY, since the H-2 remediation. `onDefaultRecovery` now re-anchors
    ///      at RECOVERY time, so on the wired path this clamp finds `derecognized == 0` and is a
    ///      no-op. It still fires — and must be kept — when the engine's `defaultManager` wiring
    ///      is zero (the optional-wiring configuration `WaterfallEngine.distribute` explicitly
    ///      supports), which is the only remaining way `deployedTo` can fall behind the mark.
    ///
    ///      THREAT MODEL: the no-under-mark argument depends on CREDIT_ROLE being held by
    ///      protocol modules only. A CREDIT_ROLE grant to an EOA could call
    ///      `ReserveManager.recordPrincipalReturn`/`recordPrincipalWritedown` directly, dropping
    ///      `deployedTo` with no cash arriving and no cascade run, after which this clamp would
    ///      de-recognise a genuine loss.
    function _reduceDefaulted(DefaultStorage storage $, uint256 tokenId, uint256 classId, uint256 amount) private {
        uint256 c = $.defaultedContribution[tokenId];
        uint256 dec = amount < c ? amount : c;
        uint256 remaining = c - dec;
        // H-2: principal recovered in cash since the declare is no longer at risk.
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        uint256 derecognized = stillAtRisk < remaining ? remaining - stillAtRisk : 0;
        dec += derecognized;
        if (dec != 0) {
            if ($.coverageConsumedByDefault[tokenId] != 0) $.drawnDefaultPrincipal[classId] -= dec;
            $.defaultedContribution[tokenId] = c - dec;
            $.declaredDefaultedPrincipal[classId] -= dec;
        }
        // The realized part is already reported by `LossRealized`; the clamped part is
        // impairment de-recognised WITHOUT a loss, so it emits the same event the clean-resolve
        // path uses — the impairment pool stays reconstructable from events alone.
        if (derecognized != 0) emit DefaultImpairmentCleared(tokenId, classId, derecognized);
        // Once nothing of this default is left unrealized, release its row and historical
        // consumption counters. The live reserve already reflects every actual draw.
        uint256 updated = $.defaultedContribution[tokenId];
        if (updated == 0) _releaseCoverageConsumption($, tokenId);
        else $.commitmentLedger.updatePrincipal(tokenId, updated);
    }

    /// @dev Drop `tokenId`'s historical sGROVE consumption and live principal row. Idempotent: a
    ///      second call is a no-op, so the two terminal callers cannot double-release.
    function _releaseCoverageConsumption(DefaultStorage storage $, uint256 tokenId) private {
        uint256 consumed = $.coverageConsumedByDefault[tokenId];
        if (consumed != 0) {
            $.coverageConsumedByDefault[tokenId] = 0;
            $.liveDefaultCoverageConsumed -= consumed;
        }
        $.commitmentLedger.release(tokenId);
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
        if (!$.pastDueMarked[tokenId]) return;
        uint256 c = $.pastDueContribution[tokenId];
        $.pastDueMarked[tokenId] = false;
        $.pastDueContribution[tokenId] = 0;
        $.pastDuePrincipal[classId] -= c;
        $.pastDueExposure -= c;
        // AUDIT FIX (SWEEP-3 S3-F3) — THE EPISODE RECORD IS DELIBERATELY NOT TOUCHED HERE.
        // `$.reliefEpisode[tokenId]` must SURVIVE a release: that persistence is the entire fix.
        // Clearing it (or clearing `pastDueReliefAnchor`) would hand the very next `markPastDue`
        // of the same, still-delinquent, still-unattested payment episode a fresh benefit of the
        // doubt, which is the rewind this finding is about. Only an ADVANCE of the facility's
        // `nextPaymentDue` — an authenticated servicing transition — may open a new episode.
        emit PastDueCleared(tokenId, classId, c);
    }

    /// @dev One bump per externally observable risk transition. Checked arithmetic deliberately
    ///      fails loudly at the theoretical uint256 limit rather than wrapping and reviving a
    ///      centuries-old assessment.
    function _advanceImpairmentRevision(DefaultStorage storage $) private {
        $.impairmentRevision += 1;
        emit ImpairmentRevisionAdvanced($.impairmentRevision);
    }

    /// @dev An incoming backstop must declare the full delivery interface and expose every read
    ///      surface the conservative-NAV path uses. A capacity-only or read-only stand-in must
    ///      never be installed: the realization path calls `coverShortfall` to deliver value.
    function _validateBackstop(address backstop_) private view {
        if (backstop_ == address(0)) return; // unsetting the backstop stays permitted
        if (!_declaresBackstopInterface(backstop_)) revert DefaultManager_InvalidBackstop(backstop_);
        if (!_isBackstopReadable(backstop_)) revert DefaultManager_InvalidBackstop(backstop_);
    }

    /// @dev ERC-165 identity probe, bounded so a hostile candidate cannot burn the caller's gas.
    ///      This is an installation check; outgoing readability remains independent so a legacy
    ///      incumbent can still be replaced when its capacity view has become unreadable.
    function _declaresBackstopInterface(address backstop_) private view returns (bool declares) {
        bytes memory interfaceCall = abi.encodeCall(IERC165.supportsInterface, (type(ICascadeBackstop).interfaceId));
        assembly ("memory-safe") {
            mstore(0x00, 0)
            let success :=
                staticcall(BACKSTOP_PROBE_GAS, backstop_, add(interfaceCall, 0x20), mload(interfaceCall), 0x00, 0x20)
            declares := and(and(success, iszero(lt(returndatasize(), 0x20))), eq(mload(0x00), 1))
        }
    }

    /// @dev Capability probe for every read the conservative-NAV path requires. ERC-165 identity
    ///      is deliberately not used: an already-deployed SGrove may implement the complete
    ///      surface while advertising an interface id from before `coverageReserve()` and
    ///      `remainingCoverage()` were added. Bounded staticcalls keep malformed or hostile
    ///      candidates from consuming unbounded validation gas.
    function _isBackstopReadable(address backstop_) private view returns (bool readable) {
        return _probeBackstopWords(backstop_, ICascadeBackstop.coverageCapacity.selector, false, 1)
            && _probeBackstopWords(backstop_, ICascadeBackstop.coverageCapacityAt.selector, true, 1)
            && _probeBackstopWords(backstop_, ICascadeBackstop.coverageCapParameters.selector, false, 2)
            && _probeBackstopWords(backstop_, ICascadeBackstop.coverageReserve.selector, false, 1)
            && _probeBackstopWords(backstop_, ICascadeBackstop.remainingCoverage.selector, true, 1);
    }

    function _probeBackstopWords(address target, bytes4 selector, bool withArgument, uint256 returnWords)
        private
        view
        returns (bool ok)
    {
        assembly ("memory-safe") {
            // `bytes4` values are ABI-left-aligned in a stack word.
            mstore(0x00, selector)
            if withArgument { mstore(0x04, 0) }
            let size := add(4, mul(32, withArgument))
            let success := staticcall(BACKSTOP_PROBE_GAS, target, 0x00, size, 0x00, 0x20)
            ok := and(success, iszero(lt(returndatasize(), mul(returnWords, 0x20))))
        }
    }

    /// @dev Upgrade authorization is role-only. A UUPS upgrade executes this hook in the
    ///      incumbent implementation, so it cannot truthfully enforce an ordering dependency on
    ///      APIs introduced by the candidate. Backstop capability is enforced when the dependency
    ///      is installed through `setBackstop`; no false in-place ordering guarantee is claimed.
    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (DefaultStorage storage $) {
        assembly {
            $.slot := DEFAULT_STORAGE_LOCATION
        }
    }
}
