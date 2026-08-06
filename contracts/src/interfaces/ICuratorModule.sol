// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICuratorModule — per-class curator first-loss vaults (ADR-0004)
/// @notice Curators (anchor: Forest Road, $10M/class default; additional curators
///         pluggable per class) post USDfr first-loss capital that absorbs realized
///         losses BEFORE the sGROVE backstop and depositor principal (CLAUDE.md §1.3
///         cascade ordering). Multi-curator stakes in one class share losses exactly
///         pro-rata via internal shares. Withdrawals are constrained by subordination
///         headroom: posted capital protecting live exposure cannot leave.
interface ICuratorModule {
    // ── Events ───────────────────────────────────────────────────────────
    event CuratorApproved(uint256 indexed classId, address indexed curator, bool approved);
    event FirstLossTargetSet(uint256 indexed classId, uint256 target);
    // `round` disambiguates share attribution across a wipe-out (audit fix, §3.1).
    event FirstLossPosted(
        uint256 indexed classId, address indexed curator, uint256 amount, uint256 shares, uint256 round
    );
    event FirstLossWithdrawn(
        uint256 indexed classId, address indexed curator, uint256 amount, uint256 shares, uint256 round
    );
    /// @notice Emitted on every cascade layer-1 absorption (residual > 0 escalates).
    event LossAbsorbed(uint256 indexed classId, uint256 loss, uint256 absorbed, uint256 residual);
    /// @notice Emitted when a fully-wiped class pool restarts a new share round.
    event PoolRoundAdvanced(uint256 indexed classId, uint256 newRound);
    /// @notice Emitted when a default entering a class freezes curator withdrawals.
    ///         `count` is the number of unresolved defaults now outstanding on the class.
    event ClassDefaultFrozen(uint256 indexed classId, uint256 count);
    /// @notice Emitted when governance lifts one default freeze from a class.
    event ClassDefaultFreezeLifted(uint256 indexed classId, uint256 count);

    // ── Errors ───────────────────────────────────────────────────────────
    error Curator_ZeroAddress();
    error Curator_ZeroAmount();
    error Curator_UnknownClass(uint256 classId);
    error Curator_NotApprovedCurator(uint256 classId, address curator);
    error Curator_InsufficientStake(uint256 classId, address curator, uint256 requested, uint256 posted);
    error Curator_HeadroomExceeded(uint256 classId, uint256 requested, uint256 headroom);
    /// @notice Withdrawals are frozen because the class has an unresolved default
    ///         (audit R4-EC2: stops a curator front-running realizeLoss to duck a loss).
    error Curator_ClassDefaultFrozen(uint256 classId);
    /// @notice liftDefaultFreeze called on a class with no outstanding default freeze.
    error Curator_NotFrozen(uint256 classId);

    // ── Curator paths ────────────────────────────────────────────────────
    /// @notice Posts `amount` USDfr of first-loss capital to `classId`'s pool.
    ///         Caller must be an approved curator for the class.
    function postFirstLoss(uint256 classId, uint256 amount) external;

    /// @notice Withdraws `amount` USDfr of the caller's stake, capped by BOTH the
    ///         caller's pro-rata stake and the class's subordination headroom.
    function withdrawFirstLoss(uint256 classId, uint256 amount) external;

    // ── Cascade (credit layer only) ──────────────────────────────────────
    /// @notice Absorbs up to `loss` from the class pool (cascade layer 1). Transfers
    ///         the absorbed USDfr to `msg.sender` (the DefaultManager), which burns it
    ///         in the same transaction against the principal write-down (ADR-0012).
    /// @return absorbed Amount taken from the pool (== min(loss, pool balance)).
    /// @return residual Loss remaining for the next cascade layer.
    function absorbLoss(uint256 classId, uint256 loss) external returns (uint256 absorbed, uint256 residual);

    // ── Default freeze (audit R4-EC2) ────────────────────────────────────
    /// @notice Records that a facility in `classId` has entered default, freezing curator
    ///         withdrawals for the class until governance lifts it. Called by the
    ///         DefaultManager (CREDIT_ROLE) on declareDefault / liquidate. Increments an
    ///         unresolved-default counter so concurrent defaults each require a lift.
    function freezeOnDefault(uint256 classId) external;

    /// @notice Governance (timelock) lifts one default freeze from `classId` once a
    ///         workout resolves. Reverts if the class has no outstanding freeze.
    function liftDefaultFreeze(uint256 classId) external;

    /// @notice Number of unresolved defaults freezing withdrawals on a class (0 = open).
    function unresolvedDefaults(uint256 classId) external view returns (uint256);

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current pool balance for a class (18-dec USDfr).
    function poolBalance(uint256 classId) external view returns (uint256);

    /// @notice A curator's current pro-rata stake value in a class (0 if their shares
    ///         belong to a wiped-out round).
    function postedOf(uint256 classId, address curator) external view returns (uint256);

    /// @notice Required subordination for a class: min(first-loss target, live class
    ///         exposure). Capital up to this level cannot be withdrawn.
    function requiredFirstLoss(uint256 classId) external view returns (uint256);

    /// @notice Withdrawable excess above the subordination requirement.
    function headroom(uint256 classId) external view returns (uint256);

    /// @notice Governance-set first-loss target for a class (ADR-0004: $10M default).
    function firstLossTarget(uint256 classId) external view returns (uint256);

    /// @notice True if `curator` may post first-loss to `classId`.
    function isApprovedCurator(uint256 classId, address curator) external view returns (bool);
}
