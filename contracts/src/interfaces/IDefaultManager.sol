// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRevisionedImpairmentSource} from "./IRevisionedImpairmentSource.sol";
import {IReserveLossAbsorber} from "./IReserveLossAbsorber.sol";

/// @title IDefaultManager — default handling and the three-layer loss cascade
/// @notice Two remedy families (ADR-0015):
///         RECEIVABLE classes — `declareDefault` freezes the position and emits the
///         per-class remedy reference that triggers off-chain UCC enforcement
///         (assigned-receivable foreclosure, secondary-market credit sale); recoveries
///         return via the waterfall; `realizeLoss` settles the final shortfall.
///         MARKED-TO-MARKET class — the fast path: permissionless `marginCall` when the
///         attested mark breaches the class margin-call LTV (cure window starts),
///         permissionless `liquidate` on liquidation-LTV breach or cure expiry.
///
///         `realizeLoss` executes the cascade ATOMICALLY with the principal write-down
///         (ADR-0012): curator first-loss → sGROVE backstop → sUSDfr vault principal,
///         in that order, never skipping or inverting a layer (CLAUDE.md §1.3).
/// @dev The inherited `absorbReserveLoss` surface is retained-but-unreachable production ABI.
///      ReserveManager performs live custody cascades inline; the retained entry emits no event
///      and must not be represented as coverage of that shipped path.
interface IDefaultManager is IRevisionedImpairmentSource, IReserveLossAbsorber {
    // ── Events ───────────────────────────────────────────────────────────
    event DefaultDeclared(uint256 indexed tokenId, uint256 indexed classId, bytes32 remedyRef);
    /// @notice The off-chain enforcement trigger (UCC remedies / custodian liquidation).
    event RemedyInitiated(uint256 indexed tokenId, uint256 indexed classId, bytes32 remedyRef);
    event Accelerated(uint256 indexed tokenId);
    event MarginCalled(uint256 indexed tokenId, uint256 ltvBps, uint64 cureDeadline);
    event MarginCallCleared(uint256 indexed tokenId, uint256 ltvBps);
    event LiquidationInitiated(uint256 indexed tokenId, uint256 ltvBps);
    /// @notice The cascade record: loss == absorbed (curator) + covered (backstop) +
    ///         depositorLoss (vault), burned in the same transaction as the write-down.
    event LossRealized(
        uint256 indexed tokenId,
        uint256 indexed classId,
        uint256 loss,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 depositorLoss
    );
    event RemedyRefSet(uint256 indexed classId, bytes32 remedyRef);
    event CureWindowSet(uint256 indexed classId, uint64 window);
    event BackstopSet(address indexed backstop);
    /// @notice The append-only per-event commitment ledger wired to this manager.
    event CommitmentLedgerSet(address indexed ledger);
    /// @notice A receivable facility that ran past `maturity + graceWindow` was flagged past due by
    ///         the permissionless `markPastDue` trigger (AUDIT FIX H-5, REDESIGNED 2026-07-22). This
    ///         is a REVERSIBLE ACCOUNTING mark ONLY. It does NOT transition the facility to
    ///         `Defaulted`, does NOT freeze the curator, does NOT emit `RemedyInitiated`, and does
    ///         NOT assert a `DefaultDeclared` attestation — the facility stays `Active`/`Amortizing`
    ///         and the servicer's legal `declareDefault` (and the loss cascade it gates) remain fully
    ///         reachable. The recorded `outstanding` depresses the conservative senior redemption NAV
    ///         (`pendingSeniorImpairment`) until the mark is cleared (`clearPastDue`) or converted by
    ///         `declareDefault`.
    /// @param tokenId The facility marked past due.
    /// @param classId Its collateral class.
    /// @param maturity The facility's absolute maturity timestamp that was breached.
    /// @param outstanding The at-risk principal recorded into the past-due impairment pool.
    event PastDueMarked(uint256 indexed tokenId, uint256 indexed classId, uint64 maturity, uint256 outstanding);
    /// @notice A facility's past-due mark was removed (AUDIT FIX H-5, REDESIGNED 2026-07-22): either
    ///         a servicer cure (`clearPastDue`) or a conversion into a declared default
    ///         (`declareDefault` on a past-due facility, which releases the reversible past-due
    ///         contribution before recording the declared-default contribution, so the facility is
    ///         counted exactly once). `amount` left the past-due pool and `pastDueExposure`.
    /// @param tokenId The facility whose past-due mark was removed.
    /// @param classId Its collateral class.
    /// @param amount The at-risk principal released from the past-due pool, in USDfr.
    event PastDueCleared(uint256 indexed tokenId, uint256 indexed classId, uint256 amount);
    /// @notice A past-due facility's mark was re-anchored DOWN to live deployed principal after a
    ///         partial performing repayment (AUDIT FIX re-audit MEDIUM). `amount` left the past-due
    ///         pool because that much principal was paid down; the facility stays flagged with the
    ///         reduced contribution. A FULL repayment emits `PastDueCleared` instead (mark removed).
    /// @param tokenId The facility whose past-due mark was reduced.
    /// @param classId Its collateral class.
    /// @param amount The at-risk principal de-recognised from the past-due pool, in USDfr.
    event PastDueReanchored(uint256 indexed tokenId, uint256 indexed classId, uint256 amount);
    /// @notice The per-class past-due grace window was set (AUDIT FIX H-5). Bounded at
    ///         `Config.DEFAULT_REDEEM_COOLDOWN`. NB: this bound gives only PARTIAL coverage of the
    ///         par-exit window — the grace is maturity-anchored while the redemption cooldown is
    ///         request-anchored, so a redeemer who queued well before maturity can still have its
    ///         cooldown elapse before the mark lands (see `markPastDue` and `setGraceWindow`).
    event GraceWindowSet(uint256 indexed classId, uint64 window);
    /// @notice Unrealized-impairment contribution left the class's pool WITHOUT a realized loss
    ///         (ADR-0022). `amount` is the portion de-recognised by this call, NEVER the
    ///         realized loss (that is reported by `LossRealized`), so summing this event and
    ///         `LossRealized` reconstructs the impairment pool from logs alone.
    /// @dev    THREE emitters, and the last two are AUDIT FIX H-2 — consumers that assumed this
    ///         event implies the facility is now `Resolved` MUST be updated (subgraph, frontend):
    ///           1. `onDefaultResolved` — the whole remainder, on a clean full recovery;
    ///           2. `onDefaultRecovery` — principal returned in cash on a PARTIAL recovery; the
    ///              facility stays `Defaulted`/`Accelerated` and keeps a non-zero contribution;
    ///           3. `realizeLoss` (`_reduceDefaulted`) — the backstop clamp, for any remainder
    ///              above the principal still outstanding after the write-down.
    /// @param tokenId The facility whose contribution moved.
    /// @param classId The collateral class whose impairment pool shrank.
    /// @param amount The impairment de-recognised by this call, in USDfr.
    event DefaultImpairmentCleared(uint256 indexed tokenId, uint256 indexed classId, uint256 amount);
    /// @notice Monotonic risk-state revision used to invalidate stale professional assessments.
    /// @dev Advances on every declared-default, past-due, recovery, realization, and backstop
    ///      wiring transition that can change the conservative impairment state.
    event ImpairmentRevisionAdvanced(uint256 indexed revision);
    /// @notice Complete protocol-level custody-loss allocation before ReserveManager records the
    ///         backing reduction. Any non-zero residual is deliberately recorded as insolvency and
    ///         leaves mint/redeem fail-closed pending governance recapitalisation.

    // ── Errors ───────────────────────────────────────────────────────────
    error DefaultManager_ZeroAddress();
    error DefaultManager_ZeroAmount();
    error DefaultManager_ZeroEvidenceHash();
    error DefaultManager_UnknownClass(uint256 classId);
    error DefaultManager_NotDefaultable(uint256 tokenId);
    /// @notice No attested DefaultDeclared fact for this facility (ADR-0020).
    error DefaultManager_DefaultNotAttested(uint256 tokenId);
    error DefaultManager_NotMarkedToMarket(uint256 tokenId);
    error DefaultManager_NoValuation(uint256 tokenId);
    error DefaultManager_ValuationStale(uint256 tokenId, uint64 asOf, uint64 maxAge);
    error DefaultManager_ThresholdNotBreached(uint256 tokenId, uint256 ltvBps, uint256 thresholdBps);
    error DefaultManager_NoMarginCall(uint256 tokenId);
    error DefaultManager_AlreadyMarginCalled(uint256 tokenId);
    error DefaultManager_NotInDefault(uint256 tokenId);
    error DefaultManager_LossExceedsOutstanding(uint256 tokenId, uint256 loss, uint256 outstanding);
    /// @notice Loss exceeded every cascade layer INCLUDING the vault's assets — the
    ///         protocol cannot realize it without impairing unstaked USDfr. Requires
    ///         governance intervention; failing loudly is the designed behavior.
    error DefaultManager_LossExceedsAbsorptionCapacity(uint256 tokenId, uint256 depositorLoss, uint256 vaultAssets);
    error DefaultManager_BackstopContractViolated(uint256 requested, uint256 covered, uint256 received);
    /// @notice A proposed backstop has no code or cannot return an ABI-encoded capacity.
    error DefaultManager_InvalidBackstop(address backstop);
    /// @notice A commitment-ledger migration was attempted with live declared principal or
    ///         consumed layer-2 coverage. Replacing the ledger would erase per-event state.
    error DefaultManager_CommitmentLedgerMigrationUnsafe(uint256 liveRisk);
    /// @notice The commitment ledger is already wired; migration is one-way and cannot replace it.
    error DefaultManager_CommitmentLedgerAlreadySet(address ledger);
    /// @notice `onDefaultResolved` was called for a facility that is not in `Resolved` state.
    error DefaultManager_NotResolved(uint256 tokenId);
    /// @notice `markPastDue` was called on a non-receivable (marked-to-market) facility — those
    ///         use the margin-call / liquidation path, not the maturity clock (AUDIT FIX H-5).
    error DefaultManager_NotReceivable(uint256 tokenId);
    /// @notice `markPastDue` was called before the facility ran past `maturity + graceWindow`.
    /// @param tokenId The facility.
    /// @param maturity Its maturity timestamp.
    /// @param graceEnd The first timestamp at which it becomes markable (`maturity + graceWindow`).
    error DefaultManager_NotPastDue(uint256 tokenId, uint64 maturity, uint64 graceEnd);
    /// @notice `markPastDue` was called on a facility already flagged past due — the mark is
    ///         idempotent and must not double-count into the impairment pool (AUDIT FIX H-5).
    error DefaultManager_AlreadyPastDue(uint256 tokenId);
    /// @notice `clearPastDue` was called on a facility that is not currently flagged past due
    ///         (AUDIT FIX H-5).
    error DefaultManager_NotPastDueMarked(uint256 tokenId);
    /// @notice `setGraceWindow` was asked to set a window above `Config.DEFAULT_REDEEM_COOLDOWN`,
    ///         which would let the marking lag exceed the redemption cooldown (AUDIT FIX H-5).
    error DefaultManager_GraceWindowTooLong(uint64 window, uint64 maxWindow);
    error DefaultManager_ReserveLossCallerNotReserve(address caller);
    error DefaultManager_InvalidReserveLossIncident(uint256 incidentId);
    /// @notice `drawForSeniorExit` was called by something other than the wired MintRedeemController
    ///         (ADR-0034 Y-bis). Caller identity, not a role: there is exactly one correct caller.
    error DefaultManager_ExitDrawCallerNotController(address caller);

    /// @notice A senior exit drew junior capital forward through the cascade (ADR-0034 Y-bis).
    /// @param required What the controller asked the junior layers to fund.
    /// @param curatorAbsorbed Layer 1 — curator first-loss, pro-rata over the standing pools.
    /// @param backstopCovered Layer 2 — sGROVE, and only for what layer 1 declined.
    event SeniorExitDrawn(uint256 required, uint256 curatorAbsorbed, uint256 backstopCovered);

    /// @notice Draws junior capital forward to fund a cascade-ordered senior exit price, in the
    ///         same transaction as the redemption (ADR-0034 Y-bis).
    /// @dev Callable ONLY by the wired MintRedeemController. Never reverts on insufficiency —
    ///      returns what the junior layers could actually provide, which may be zero. The drawn
    ///      USDfr is left standing at the DefaultManager for the CONTROLLER to burn: this contract
    ///      must not call `burnLoss`, which is `nonReentrant` on a controller already inside
    ///      `redeem`. See the implementation NatSpec.
    /// @param required Junior capital the exit price needs, in 18-decimal USDfr units.
    /// @return drawn USDfr actually transferred here by layers 1 and 2 (`<= required`).
    function drawForSeniorExit(uint256 required) external returns (uint256 drawn);

    // ── Receivable remedy path (SERVICER_ROLE) ───────────────────────────
    /// @notice Declares default: freezes the position (dual-record freeze) and emits
    ///         the class remedy reference for off-chain enforcement.
    function declareDefault(uint256 tokenId, bytes32 evidenceHash) external;

    /// @notice Shifts a Defaulted facility to Accelerated (waterfall acceleration).
    function accelerate(uint256 tokenId) external;

    /// @notice Realizes a shortfall for a Defaulted/Accelerated facility through the cascade,
    ///         atomically with the principal write-down. If the write-down exhausts the remaining
    ///         outstanding principal, the facility transitions to `Resolved`.
    function realizeLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash) external;

    function coverageConsumedByDefault(uint256 tokenId) external view returns (uint256 consumed);
    function liveDefaultCoverageConsumed() external view returns (uint256 consumed);
    /// @notice Compatibility alias for the live drawn-row deliverable aggregate.
    /// @dev Its historical storage word remains untouched for upgrade safety.
    function liveDefaultCapacityFloor() external view returns (uint256 capacityFloor);
    /// @notice AUDIT FIX (SWEEP-3 F-S3-01) — replaces `liveDefaultCapacityFloor()`. See the
    ///         implementation NatSpec for why the floor could not be netted without
    ///         double-subtracting the consumed coverage.
    function liveDefaultCoverageRemaining() external view returns (uint256 remaining);
    function coverageRemainingByDefault(uint256 tokenId) external view returns (uint256 remaining);

    // ── Past-due accounting trigger (permissionless — on-chain maturity) ──
    /// @notice Permissionlessly flags a RECEIVABLE facility that ran past `maturity + graceWindow`
    ///         as past due (AUDIT FIX H-5, REDESIGNED 2026-07-22). This is a REVERSIBLE accounting
    ///         mark that depresses the conservative senior redemption NAV (`pendingSeniorImpairment`)
    ///         by the facility's at-risk principal — the honest mark once a payment is overdue. It
    ///         does NOT transition the facility to `Defaulted`, does NOT freeze the curator, does NOT
    ///         require a `DefaultDeclared` attestation, and does NOT emit `RemedyInitiated`: the
    ///         facility stays `Active`/`Amortizing`, so the servicer's legal `declareDefault` (and
    ///         the loss cascade it gates) stay fully reachable. Permissionless is safe under this
    ///         redesign because a bystander call can only depress NAV reversibly — it can neither
    ///         foreclose the legal-remedy path nor trigger a loss. Idempotent: reverts
    ///         `DefaultManager_AlreadyPastDue` on a second call. Reverts `DefaultManager_NotReceivable`
    ///         for marked-to-market classes (they use the margin path), `DefaultManager_NotDefaultable`
    ///         if the facility is not `Active`/`Amortizing`, and `DefaultManager_NotPastDue` before
    ///         the grace end.
    function markPastDue(uint256 tokenId) external;

    /// @notice Clears a facility's past-due mark and removes its at-risk principal from the past-due
    ///         impairment pool, restoring the conservative senior NAV (AUDIT FIX H-5, REDESIGNED
    ///         2026-07-22). SERVICER_ROLE-gated: the servicer processes payments and is the party
    ///         that knows a facility has cured. Callable in any facility state (so a facility that
    ///         reached `Repaid`/`Resolved` while still flagged can always be cleaned up — there is
    ///         no stranded over-mark). Reverts `DefaultManager_NotPastDueMarked` if not flagged.
    function clearPastDue(uint256 tokenId, bytes32 evidenceHash) external;

    // ── Marked-to-market fast path (permissionless — on-chain conditions) ─
    /// @notice Starts a margin call when the attested LTV breaches the class
    ///         margin-call threshold. Anyone may call; the mark is the evidence.
    function marginCall(uint256 tokenId) external;

    /// @notice Clears an active margin call with a FRESH attested mark showing the
    ///         LTV back under the margin-call threshold.
    function clearMarginCall(uint256 tokenId) external;

    /// @notice Freezes the facility for collateral liquidation when the liquidation
    ///         LTV is breached, or when a margin call's cure window expires unhealed.
    function liquidate(uint256 tokenId) external;

    // ── Governance ───────────────────────────────────────────────────────
    /// @notice Sets the off-chain remedy reference for a class (legal-wrapper pointer).
    function setRemedyRef(uint256 classId, bytes32 remedyRef_) external;

    /// @notice Sets the margin-call cure window for a marked-to-market class.
    function setCureWindow(uint256 classId, uint64 window) external;

    /// @notice Sets the per-class past-due grace window used by `markPastDue` (AUDIT FIX H-5).
    ///         Reverts `DefaultManager_GraceWindowTooLong` above `Config.DEFAULT_REDEEM_COOLDOWN`.
    ///         NB: the bound bounds the maturity-anchored marking lag, but does NOT fully cover the
    ///         request-anchored redemption cooldown — a partial par-exit window survives (documented
    ///         residual, not closed here).
    function setGraceWindow(uint256 classId, uint64 window) external;

    /// @notice Wires the sGROVE backstop (Phase H). Zero address = no layer 2 yet.
    function setBackstop(address backstop_) external;

    /// @notice Creates the commitment ledger for a pre-ledger proxy after an upgrade.
    /// @dev Governance-only and one-way. It is permitted only before any layer-2 coverage has
    ///      been consumed, because creating a fresh ledger after a draw would erase that event's
    ///      residual-principal record and could overstate future coverage.
    function initializeCommitmentLedger() external;

    /// @notice Wired module addresses, including the append-only commitment ledger tail.
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
        );

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current attested LTV of a facility in bps (outstanding / mark).
    function currentLtvBps(uint256 tokenId) external view returns (uint256 ltvBps, uint64 asOf);

    /// @notice Active margin-call cure deadline (0 = no active margin call).
    function cureDeadline(uint256 tokenId) external view returns (uint64);

    /// @notice Per-class off-chain remedy reference.
    function remedyRef(uint256 classId) external view returns (bytes32);

    /// @notice Per-class margin-call cure window (seconds).
    function cureWindow(uint256 classId) external view returns (uint64);

    /// @notice Per-class past-due grace window (seconds) applied after `maturity` before a
    ///         facility becomes markable via `markPastDue` (AUDIT FIX H-5).
    function graceWindow(uint256 classId) external view returns (uint64);

    /// @notice The wired cascade backstop (zero until Phase H).
    function backstop() external view returns (address);

    /// @notice Clears a facility's remaining unrealized-impairment contribution once it has
    ///         cleanly resolved (recovered in full, no realized loss). Callable by the credit
    ///         layer (WaterfallEngine) only; reverts unless the facility is `Resolved` (ADR-0022).
    function onDefaultResolved(uint256 tokenId) external;

    /// @notice Re-anchors a still-defaulted facility's unrealized-impairment contribution to the
    ///         principal that is genuinely still at risk (`ReserveManager.deployedTo`), after a
    ///         PARTIAL principal recovery returned cash on the workout (ADR-0022, AUDIT FIX H-2).
    ///         Callable by the credit layer (WaterfallEngine) only; reverts with
    ///         `DefaultManager_NotInDefault` unless the facility is `Defaulted`/`Accelerated`.
    ///         Idempotent and one-directional — it only ever LOWERS the mark, to a value that is
    ///         still an upper bound on the loss the facility can realize, so it can never
    ///         under-mark a genuine outstanding loss. Emits `DefaultImpairmentCleared` for the
    ///         de-recognised amount when it moves.
    /// @param tokenId The facility whose impairment contribution is re-anchored.
    function onDefaultRecovery(uint256 tokenId) external;

    /// @notice CREDIT_ROLE hook, called by `WaterfallEngine.distribute` on a PERFORMING repayment.
    ///         The past-due counterpart of `onDefaultRecovery`: re-anchors a past-due facility's
    ///         mark DOWN to live deployed principal as it amortizes, and fully clears the flag on a
    ///         full repayment — so a past-due facility that cures through the ordinary performing
    ///         path stops depressing the conservative redemption NAV without a manual `clearPastDue`.
    ///         One-directional, idempotent, and a no-op for a facility that is not past-due-flagged
    ///         (safe to call on every performing repayment).
    /// @param tokenId The facility being repaid.
    function onPerformingRepayment(uint256 tokenId) external;

    /// @notice Per-class outstanding principal of loans in default whose loss is not yet
    ///         realized (ADR-0022 impairment pool).
    function declaredDefaultedPrincipal(uint256 classId) external view returns (uint256);

    /// @notice Historical per-class principal of declared facilities that have drawn layer two.
    /// @dev Retained for observability; ADR-0035 gives the cohort no distinct coverage formula.
    function drawnDefaultPrincipal(uint256 classId) external view returns (uint256);

    /// @notice Per-class at-risk principal of facilities currently flagged past due by
    ///         `markPastDue` (AUDIT FIX H-5) — the class breakdown of `pastDueExposure()`.
    /// @dev Read by `ConservativeImpairmentMath` to rebuild the conservative mark. Part of the
    ///      published surface so an independent model can recompute `pendingSeniorImpairment()`
    ///      from first principles instead of trusting it.
    function pastDuePrincipal(uint256 classId) external view returns (uint256);

    /// @notice The start of the G2W relief ramp for the standing unattested past-due cohort
    ///         (OWNER DECISION 2026-08-07): the OLDEST live delinquent payment episode's first
    ///         mark.
    /// @dev Read by `ConservativeImpairmentMath` to ramp the unattested cohort's forward weight
    ///      back to full over one `Config.DEFAULT_REDEEM_COOLDOWN`. ZERO MEANS UNSET and fails
    ///      SAFE to full weight — never read zero as "freshly marked".
    ///
    ///      AUDIT FIX (SWEEP-3 S3-F3). This is now a DERIVED minimum over `reliefEpisode` starts,
    ///      not a timestamp re-armed by whichever `markPastDue` happened to find the cohort empty.
    ///      A clear-and-re-mark of the same payment episode therefore restores the ORIGINAL start,
    ///      so the ramp's expiry — the thing that bounds the D5-03 under-mark in TIME — cannot be
    ///      rewound. It is a MINIMUM (oldest, most elapsed, largest mark) so the residual after a
    ///      release runs in the over-marking direction.
    /// @return anchor The block timestamp the oldest live episode's relief began at.
    function pastDueReliefAnchor() external view returns (uint256 anchor);

    // AUDIT FIX (SWEEP-3 S3-F3) — NO `reliefEpisode(tokenId)` GETTER, AND THAT IS A BUDGET
    // DECISION, NOT AN OVERSIGHT. The per-facility episode record
    // (`DefaultManager.DefaultStorage.reliefEpisode`) is the source of truth for the relief clock
    // and publishing it would be genuinely useful to operations and the audit register. MEASURED:
    // the two-field getter costs `DefaultManager` 159 runtime bytes and lands it at 24,579 — THREE
    // BYTES OVER EIP-170. The guard fits (156 bytes spare without it); the getter does not, and a
    // view is not worth shaving a guard for. The economically meaningful surface is published
    // anyway: `pastDueReliefAnchor()` IS the derived episode start the redemption price is
    // computed from, and it is what the S3-F3 acceptance tests assert against. If operations needs
    // the per-facility breakdown, read the slot with `eth_getStorageAt` off-chain or add it to a
    // standalone lens contract — do NOT re-add it here without first recovering the budget.

    /// @notice The senior (sUSDfr) principal that declared-but-unrealized defaults would impair
    ///         after the junior layers (curator first-loss per class, then sGROVE) absorb — the
    ///         conservative mark deducted from redemption NAV (ADR-0022).
    function pendingSeniorImpairment() external view override returns (uint256);

    /// @inheritdoc IRevisionedImpairmentSource
    function impairmentRevision() external view override returns (uint256);

    /// @inheritdoc IRevisionedImpairmentSource
    function impairmentStateHash() external view override returns (bytes32);

    /// @inheritdoc IRevisionedImpairmentSource
    function impairmentRiskStateHash() external view override returns (bytes32);

    /// @inheritdoc IRevisionedImpairmentSource
    function impairmentBackstopCapacity() external view override returns (uint256);

    /// @notice Aggregate at-risk principal of facilities currently flagged past due by `markPastDue`
    ///         (AUDIT FIX H-5). It moves on exactly three paths: `+=` at `markPastDue`, `-=` at
    ///         `clearPastDue` (servicer cure), and `-=` at `declareDefault` when it converts a
    ///         past-due facility into a declared default. Falls to zero as each flagged facility is
    ///         cleared or converted.
    function pastDueExposure() external view returns (uint256);

    /// @notice A single facility's at-risk principal currently recorded in the past-due pool by
    ///         `markPastDue` (0 if not flagged) (AUDIT FIX H-5).
    function pastDueContribution(uint256 tokenId) external view returns (uint256);
}
