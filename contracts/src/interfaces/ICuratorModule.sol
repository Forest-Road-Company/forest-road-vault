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
    /// @notice Share units were divided by a power of two to retain representability.
    event PoolSharesNormalized(uint256 indexed classId, uint256 shift, uint256 totalShares);
    /// @notice AUDIT FIX (SWEEP-4 S4-R1). A round was CLOSED as economically wiped while a
    ///         residual balance still stood, so the residual's ownership was snapshotted for the
    ///         closing cohort instead of being forfeited to the pool.
    /// @param classId The class whose round closed.
    /// @param closedRound The round that closed.
    /// @param residual The USDfr still standing in the pool at the close.
    /// @param closedShares Shares of the closed round that share `residual` pro-rata.
    /// @param carriedShares Shares of the SUCCEEDING round the closed cohort collectively owns
    ///        (equal to `residual`, because the new round opens at a share price of exactly 1).
    event ClosedRoundSnapshotted(
        uint256 indexed classId,
        uint256 indexed closedRound,
        uint256 residual,
        uint256 closedShares,
        uint256 carriedShares
    );
    /// @notice AUDIT FIX (SWEEP-4 S4-R1). A curator's stale-round stake was walked forward through
    ///         one or more CLOSED rounds. `settledShares == 0` means the stale stake was genuinely
    ///         worth nothing and was cleared; `toRound` below the class's live round means the walk
    ///         hit `MAX_CLOSED_ROUND_HOPS` and `claimClosedRound` must be called again.
    /// @param classId The class whose stake was settled.
    /// @param curator The stake's owner (the settler may be anyone).
    /// @param fromRound The round the stake held before the walk.
    /// @param toRound The round the stake holds after it.
    /// @param staleShares Shares held at `fromRound`.
    /// @param settledShares Shares held at `toRound`.
    event ClosedRoundSettled(
        uint256 indexed classId,
        address indexed curator,
        uint256 indexed fromRound,
        uint256 toRound,
        uint256 staleShares,
        uint256 settledShares
    );
    /// @notice Emitted when a default entering a class freezes curator withdrawals.
    ///         `count` is the number of unresolved defaults now outstanding on the class.
    event ClassDefaultFrozen(uint256 indexed classId, uint256 count);
    /// @notice Emitted when governance lifts one default freeze from a class.
    event ClassDefaultFreezeLifted(uint256 indexed classId, uint256 count);
    /// @notice AUDIT FIX (R6-CF1). The ReserveManager whose custody-loss window gates withdrawals.
    event ReserveManagerUpdated(address indexed reserves);
    /// @notice AUDIT FIX (R6-CF1). The governor the pre-arm duration is derived from (0 = the
    ///         `Config` launch parameters are used as the floor and nothing overrides them).
    event GovernorUpdated(address indexed governor);
    /// @notice AUDIT FIX (R6-CF1). A guardian armed the custody freeze ahead of governance.
    /// @param guardian The arming guardian.
    /// @param expiry Unix time at which the pre-arm lapses on its own.
    /// @param count Consecutive pre-arms used out of the budget, after this one.
    event CustodyFreezePreArmed(address indexed guardian, uint64 expiry, uint32 count);
    /// @notice AUDIT FIX (R6-CF1). Governance declared a FALSE ALARM: the guardian pre-arm limb is
    ///         cleared and the budget replenished. This can NEVER release a genuine custody freeze
    ///         — the derived limbs in `IReserveManager.custodyLossUnabsorbed` stand on their own.
    event CustodyFreezePreArmCancelled(uint64 previousExpiry);
    /// @notice AUDIT FIX (F3-PA-a). Governance replenished the guardian's pre-arm budget while
    ///         LEAVING the standing pre-arm in force — "we looked, the incident is real, keep
    ///         going". `expiry` is echoed unchanged precisely so an observer can verify that the
    ///         protection survived the replenishment.
    /// @param spent Budget units returned to the guardian.
    /// @param expiry The standing pre-arm expiry, unchanged by this call.
    event CustodyFreezePreArmBudgetReplenished(uint32 spent, uint64 expiry);
    /// @notice AUDIT FIX (F3-PA-b). A previous pre-arm had lapsed and layer-1 capital had stood
    ///         unfrozen for the full `custodyPreArmCooldown()`, so the consecutive counter reset
    ///         and this arm opened a NEW episode.
    /// @param spent Budget the lapsed episode had used.
    /// @param lapsedExpiry Expiry of the episode that just ended.
    event CustodyFreezePreArmEpisodeReset(uint32 spent, uint64 lapsedExpiry);
    /// @notice AUDIT FIX (F3-PA-c). THE CAP BOUND. One pre-arm window no longer outlasts the live
    ///         governance path, so the freeze WILL lapse before governance can ratify it unless
    ///         `replenishCustodyPreArmBudget` carries it. Emitted at the arm so the condition can
    ///         never arise silently; `script/Validate.s.sol` refuses a deployment in this regime.
    /// @param livePath The unbounded `votingDelay + votingPeriod + minDelay` reading, in seconds.
    /// @param duration The window actually granted, bounded by `CUSTODY_PRE_ARM_MAX_PATH`.
    /// @param count Consecutive pre-arms used out of the budget, after this one.
    event CustodyFreezePreArmTruncated(uint256 livePath, uint64 duration, uint32 count);

    // ── Errors ───────────────────────────────────────────────────────────
    error Curator_ZeroAddress();
    error Curator_ZeroAmount();
    /// @notice The proposed points module has no code. Refused for the same reason
    ///         `USDfr.setPointsModule` refuses it (C4-USDFR-01): the points hooks return no
    ///         data, so solc emits an `extcodesize` guard that reverts OUTSIDE the fail-open
    ///         `try` — turning a hook that must never block the cascade into one that always
    ///         does. See P-48b.
    /// @param module The codeless address that was refused.
    error Curator_PointsModuleNotAContract(address module);
    error Curator_UnknownClass(uint256 classId);
    error Curator_NotApprovedCurator(uint256 classId, address curator);
    error Curator_InsufficientStake(uint256 classId, address curator, uint256 requested, uint256 posted);
    error Curator_HeadroomExceeded(uint256 classId, uint256 requested, uint256 headroom);
    /// @notice Withdrawals are frozen because the class has an unresolved default
    ///         (audit R4-EC2: stops a curator front-running realizeLoss to duck a loss).
    error Curator_ClassDefaultFrozen(uint256 classId);
    /// @notice liftDefaultFreeze called on a class with no outstanding default freeze.
    error Curator_NotFrozen(uint256 classId);
    /// @notice AUDIT FIX (R6-CF1). Withdrawals are frozen because a reserve-CUSTODY loss is
    ///         recognised, observable or incompletely absorbed, or because a guardian has
    ///         pre-armed the freeze. Curator capital is cascade LAYER 1 for that loss and may not
    ///         exit ahead of it — the custody twin of `Curator_ClassDefaultFrozen` (R4-EC2).
    error Curator_CustodyLossFrozen();
    /// @notice AUDIT FIX (R6-CF1). No ReserveManager is wired, so the custody-loss window cannot
    ///         be evaluated. Withdrawals fail CLOSED rather than proceeding blind.
    error Curator_ReserveNotWired();
    /// @notice AUDIT FIX (R6-CF1). The guardian's consecutive pre-arm budget is spent. Only
    ///         governance can replenish it, which is what bounds a unilateral guardian freeze.
    error Curator_PreArmBudgetExhausted(uint32 requested, uint32 max);
    /// @notice AUDIT FIX (R6-CF1). `cancelCustodyPreArm` with nothing armed and no budget used.
    error Curator_NoPreArm();
    /// @notice AUDIT FIX (R6-CF1). `setReserveManager` was given an address that is not a
    ///         ReserveManager. Wiring the freeze to the wrong contract would make the guard read
    ///         someone else's state, so this fails loudly rather than accepting it.
    error Curator_InvalidReserveManager(address reserves);
    /// @notice AUDIT FIX (R6-CF1). `setGovernor` was given an address with no code, which could
    ///         never supply a live governance path.
    error Curator_InvalidGovernor(address governor);
    error Curator_ReserveManagerChangeFrozen();
    error Curator_ReserveLossWithdrawalsFrozen();
    error Curator_ShareCapacityExceeded(uint256 amount, uint256 availableShares);
    /// @notice AUDIT FIX (SWEEP-4 S4-R1). The caller holds a stake in a round that closed more than
    ///         one round ago, so a single conversion cannot bring it to the live round. Call
    ///         `claimClosedRound` (permissionless) until `stakeRound == liveRound`, then retry.
    ///         Posting or withdrawing is REFUSED rather than silently erasing the residual claim.
    error Curator_UnsettledClosedRound(uint256 classId, uint256 stakeRound, uint256 liveRound);

    // ── Curator paths ────────────────────────────────────────────────────
    /// @notice Posts `amount` USDfr of first-loss capital to `classId`'s pool.
    ///         Caller must be an approved curator for the class.
    function postFirstLoss(uint256 classId, uint256 amount) external;

    /// @notice Withdraws `amount` USDfr of the caller's stake, capped by BOTH the
    ///         caller's pro-rata stake and the class's subordination headroom.
    function withdrawFirstLoss(uint256 classId, uint256 amount) external;

    /// @notice AUDIT FIX (SWEEP-4 S4-R1). Converts `curator`'s stake in a CLOSED round into its
    ///         pro-rata slice of the succeeding round's shares. PERMISSIONLESS — anyone may settle
    ///         anyone, because a curator who cannot settle cannot post or withdraw either, and
    ///         layer-1 liveness must not depend on one address being available.
    /// @dev Moves NO value: the shares it assigns were minted at the close and have been part of
    ///      `poolShares(classId)` ever since. It is a pure re-attribution of ownership, which is why
    ///      it is not pausable and not gated by either withdrawal freeze — neither of those governs
    ///      attribution, and both still bind on `withdrawFirstLoss`.
    ///      Idempotent: a stake already on the live round is a no-op. Call it repeatedly to walk a
    ///      stake through several consecutive closes.
    function claimClosedRound(uint256 classId, address curator) external;

    // ── Cascade (credit layer only) ──────────────────────────────────────
    /// @notice Absorbs up to `loss` from the class pool (cascade layer 1). Transfers
    ///         the absorbed USDfr to `msg.sender` (the DefaultManager), which burns it
    ///         in the same transaction against the principal write-down (ADR-0012).
    /// @return absorbed Amount taken from the pool (== min(loss, pool balance)).
    /// @return residual Loss remaining for the next cascade layer.
    function absorbLoss(uint256 classId, uint256 loss) external returns (uint256 absorbed, uint256 residual);

    /// @notice Absorbs a classless protocol loss across all five pools, weighted by balances
    ///         snapshotted before any pool is changed. Rounding dust is assigned deterministically
    ///         to the lowest-numbered non-empty pools with snapshot headroom.
    /// @dev Transfers the aggregate absorbed USDfr to the caller for same-transaction burning.
    function absorbGlobalLoss(uint256 loss) external returns (uint256 absorbed, uint256 residual);

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

    // ── Custody-loss freeze (audit R6-CF1) ───────────────────────────────

    /// @notice AUDIT FIX (R6-CF1). True while curator first-loss capital is frozen by a
    ///         reserve-CUSTODY loss (recognised, observable, or incompletely absorbed) or by a
    ///         live guardian pre-arm. Class-independent: a custody loss is allocated across ALL
    ///         five pools by `absorbGlobalLoss`, so the freeze is protocol-wide.
    /// @dev Reads as TRUE when no ReserveManager is wired. "Cannot tell" must never read as
    ///      "clear" on a guard whose whole job is to stop capital leaving ahead of a loss.
    function custodyFreezeActive() external view returns (bool);

    /// @notice AUDIT FIX (R6-CF1). Guardian arms the custody freeze ahead of governance, for
    ///         losses that are known but not yet visible on-chain (a custodian insolvency, a legal
    ///         seizure, an off-chain balance frozen). A guardian may ARM but has NO release.
    function preArmCustodyFreeze() external;

    /// @notice AUDIT FIX (R6-CF1). Governance declares a FALSE ALARM: clears the guardian pre-arm
    ///         limb and replenishes the pre-arm budget.
    /// @dev It CANNOT release a real custody freeze: the derived limbs are unaffected. That is why
    ///      giving governance this cancel does not hand it a loss-dodging lever.
    ///
    ///      AUDIT FIX (F3-PA-a). This is the FALSE-ALARM lever only. To keep a REAL incident frozen
    ///      while returning budget to the guardian, use `replenishCustodyPreArmBudget` — using this
    ///      one for that purpose destroys the protection it was called to extend.
    function cancelCustodyPreArm() external;

    /// @notice AUDIT FIX (F3-PA-a). Governance returns the guardian's pre-arm budget WITHOUT
    ///         touching the standing pre-arm — "we looked, the incident is real, keep going".
    /// @dev THE HIGH THIS CLOSES: `cancelCustodyPreArm` was the only replenishment path and it
    ///      zeroes `custodyPreArmExpiry`, so regaining budget destroyed the active protection and
    ///      opened a window in which curator first-loss could leave ahead of a loss it is cascade
    ///      LAYER 1 for. Reverts with `Curator_NoPreArm` when no budget has been spent.
    function replenishCustodyPreArmBudget() external;

    /// @notice AUDIT FIX (R6-CF1). Current guardian pre-arm: lapse time and CONSECUTIVE budget used
    ///         within the current episode (see `custodyPreArmCooldown`).
    function custodyPreArm() external view returns (uint64 expiry, uint32 count);

    /// @notice AUDIT FIX (R6-CF1). How long one guardian pre-arm lasts. DERIVED from the live
    ///         governance path (`votingDelay + votingPeriod + timelock minDelay`) with the `Config`
    ///         launch parameters as a floor, so it can never expire before governance could
    ///         possibly have ratified it.
    /// @dev Strictly greater than `custodyPreArmGovernancePath()` at every parameterisation.
    function custodyPreArmDuration() external view returns (uint64);

    /// @notice AUDIT FIX (F3-PA-c). The governance path the duration was derived from: the longer
    ///         of the `Config` launch floor and the live reading, bounded by
    ///         `CUSTODY_PRE_ARM_MAX_PATH`.
    function custodyPreArmGovernancePath() external view returns (uint64);

    /// @notice AUDIT FIX (F3-PA-c). False when the path bound BINDS — i.e. one pre-arm window no
    ///         longer outlasts the LIVE governance path and `replenishCustodyPreArmBudget` must
    ///         carry the difference. `script/Validate.s.sol` refuses a deployment where this is
    ///         false, and `preArmCustodyFreeze` emits `CustodyFreezePreArmTruncated` when it arms
    ///         into that regime.
    function custodyPreArmCoversLiveGovernancePath() external view returns (bool);

    /// @notice AUDIT FIX (F3-PA-b). How long layer-1 capital must stand UNFROZEN after a pre-arm
    ///         lapses before the guardian's consecutive budget resets and a new episode may open.
    function custodyPreArmCooldown() external view returns (uint64);

    /// @notice AUDIT FIX (R6-CF1). Wires the ReserveManager whose custody-loss window gates
    ///         withdrawals. Timelocked governance only; zero explicitly unwires (and freezes).
    function setReserveManager(address reserves) external;

    /// @notice AUDIT FIX (R6-CF1). Wires the governor the pre-arm duration is derived from. Zero
    ///         leaves the `Config` launch parameters standing as the sole source.
    function setGovernor(address governor) external;
    function governanceUnpause() external;

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current pool balance for a class (18-dec USDfr).
    function poolBalance(uint256 classId) external view returns (uint256);

    /// @notice A curator's current pro-rata stake value in a class.
    /// @dev AUDIT FIX (SWEEP-4 S4-R1, FOUR-INPUT COMPOSITION). Live-round values are exact. A
    ///      closed-round value is a conservative pre-settlement quote because the executable
    ///      remaining/remaining allocation depends on settlement order. Partial holders round
    ///      down; only the unique holder of a snapshot's whole remaining cohort may receive its
    ///      one-unit remainder. It may read zero for sub-wei carry or beyond the bounded walk
    ///      without erasing the claim; call `claimClosedRound` to materialize the exact live stake.
    function postedOf(uint256 classId, address curator) external view returns (uint256);

    /// @notice AUDIT FIX (SWEEP-4 S4-R1). The residual-claim snapshot for a CLOSED round.
    /// @param classId The class.
    /// @param round The closed round.
    /// @return closedShares Shares of `round` that have not yet been settled.
    /// @return carriedShares Shares of round `round + 1` those unsettled shares collectively own.
    function closedRound(uint256 classId, uint256 round)
        external
        view
        returns (uint256 closedShares, uint256 carriedShares);

    /// @notice Required subordination for a class: min(first-loss target, live class
    ///         exposure). Capital up to this level cannot be withdrawn.
    function requiredFirstLoss(uint256 classId) external view returns (uint256);

    /// @notice Withdrawable excess above the subordination requirement.
    function headroom(uint256 classId) external view returns (uint256);

    /// @notice Governance-set first-loss target for a class (ADR-0004: $10M default).
    function firstLossTarget(uint256 classId) external view returns (uint256);

    /// @notice True if `curator` may post first-loss to `classId`.
    function isApprovedCurator(uint256 classId, address curator) external view returns (bool);

    function reserveManager() external view returns (address);
    function modules() external view returns (address usdfr, address registry, address feeVault);
}
