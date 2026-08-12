// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IRedemptionQueue — epoch FIFO exits for sUSDfr (ADR-0010, the QEV analog)
/// @notice The vault's ONLY exit path: capital sits in illiquid amortizing facilities,
///         so sUSDfr redemptions queue and settle at epoch close, strictly FIFO, from
///         a liquidity budget snapshotted per settlement. The §1.3 queue invariants —
///         never distribute more than available liquidity, FIFO holds, no
///         double-claim — are this module's safety spec.
interface IRedemptionQueue {
    // ── Events ───────────────────────────────────────────────────────────
    event RedemptionRequested(uint256 indexed requestId, address indexed owner, uint256 shares, uint256 epoch);
    /// @notice A (possibly partial) fill at settlement: `shares` burned for `assets`.
    event RequestFilled(uint256 indexed requestId, uint256 shares, uint256 assets, uint256 epoch);
    event Claimed(uint256 indexed requestId, address indexed owner, uint256 assets);
    /// @notice A settlement finished and the next epoch opened.
    /// @dev AUDIT NOTE (Q-01 round 4): `distributed` MAY now fall below `minRedemptionValue` on a
    ///      committed settlement, by at most `MIN_RESIDUE_VALUE` (1e-6 USDfr). Before the Q-01
    ///      fix, `!drained && committed` implied `distributed >= minRedemptionValue` by
    ///      construction and was checkable from this event alone. It no longer is. Pair this
    ///      event with `SettlementWithheld` to recompute the abandon predicate off-chain.
    event EpochClosed(uint256 indexed epoch, uint256 budget, uint256 distributed, uint64 nextEpochEndsAt);
    /// @notice Value the Q-01 residue guard deliberately withheld from a settlement, so that a
    ///         partial fill could not leave the head with a residue inside the zero-value window.
    /// @dev Emitted only when the guard actually reduces a fill. The abandon guard credits this
    ///      value back, so the on-chain commit test is
    ///      `settlementDistributed + withheld >= settlementMinValue`. Without this event that
    ///      predicate is not reconstructable from the log (CLAUDE.md §3.1), because `withheld` is
    ///      a stack local that never reaches storage.
    /// @param epoch The settlement's epoch.
    /// @param requestId The head request the value was withheld from.
    /// @param value Withheld USDfr value, strictly below `MIN_RESIDUE_VALUE`.
    event SettlementWithheld(uint256 indexed epoch, uint256 indexed requestId, uint256 value);
    /// @notice One transaction-sized pricing session settled through one aggregate vault burn.
    /// @dev `pricingAssets + 1` over `pricingSupply + 10**vault.decimalsOffset()` is the single
    ///      canonical rate used for selection; the final request receives deterministic floor dust.
    event PricingBatchSettled(
        uint256 indexed epoch,
        uint256 indexed sessionId,
        uint256 firstRequestId,
        uint256 lastRequestId,
        uint256 pricingAssets,
        uint256 pricingSupply,
        uint256 aggregateShares,
        uint256 assetsReceived,
        bytes32 pricingStateHash
    );
    event EpochDurationSet(uint64 duration);
    event EpochLiquidityBpsSet(uint16 bps);
    /// @notice The forced per-request redemption cooldown was set (ADR-0022).
    event RedeemCooldownSet(uint64 cooldown);
    /// @notice The C-1 anti-dust-wedge minimum redemption value was set.
    event MinRedemptionValueSet(uint256 value);

    // ── Errors ───────────────────────────────────────────────────────────
    error Queue_ZeroAddress();
    error Queue_ZeroAmount();
    error Queue_EpochNotOver(uint64 endsAt);
    error Queue_NotSettling();
    error Queue_UnknownRequest(uint256 requestId);
    error Queue_NotRequestOwner(uint256 requestId, address caller);
    error Queue_NothingClaimable(uint256 requestId);
    error Queue_BadParams();
    /// @notice A settlement could distribute nothing while requests are queued: it snapshotted
    ///         zero distributable liquidity, or the remaining budget could not buy a nonzero
    ///         slice of the head (C-1, the dust-tail case). The epoch is NOT consumed and no
    ///         position is burned; retry when liquidity returns.
    ///         Contrast `Queue_HeadNotRedeemable`, which is a VALUATION block, not a cash one.
    error Queue_NoLiquidity();
    /// @notice C-1 remediation. The settlement front cannot be redeemed for any nonzero amount
    ///         at the conservative redemption NAV (ADR-0022) — a declared senior impairment has
    ///         marked the queued book down below a wei, so there is nothing to pay ANY holder.
    ///         Settlement stops LOUDLY rather than stalling silently: the epoch is not consumed,
    ///         no position is burned, and every request keeps its shares and its place. It clears
    ///         when the mark is cured or realized. `headValuation()` reports the state off-chain.
    ///         The `minRedemptionValue` entry floor bars a dust head from arising except under a
    ///         near-total senior loss, so under normal operation this block coincides with the
    ///         whole senior layer being marked below a wei, not one dust position blocking solvent
    ///         ones behind it.
    /// @param requestId The head request settlement stopped at.
    /// @param sharesRemaining Its unfilled shares, untouched.
    error Queue_HeadNotRedeemable(uint256 requestId, uint256 sharesRemaining);
    /// @notice Every queued request is still within its forced cooldown (ADR-0022) — the
    ///         heartbeat is NOT consumed; `eligibleAt` is when the head becomes settleable.
    error Queue_AllInCooldown(uint256 eligibleAt);
    /// @notice The request is worth less than `minRedemptionValue` at the realized rate — rejected
    ///         (C-1 anti-dust-wedge floor + N-1 anti-griefing). `value` is its realized worth.
    error Queue_BelowMinRedemption(uint256 value, uint256 minimum);
    /// @notice C-01 shared exit interlock: an objective custody shortfall, persistent arm,
    ///         adjudicated incident, unabsorbed loss or deficit prevents new senior settlement.
    error Queue_ReserveLossSettlementFrozen();
    error Queue_PricingQuoteChanged(uint256 quotedAssets, uint256 receivedAssets);
    error Queue_PricingBudgetExceeded(uint256 quotedAssets, uint256 remainingBudget);
    error Queue_PricingAllocationMismatch(uint256 receivedAssets, uint256 allocatedAssets);
    error Queue_PricingRangeInvalid(uint256 expectedRequestId, uint256 actualRequestId);
    error Queue_PricingSessionExhausted();

    // ── User paths ───────────────────────────────────────────────────────
    /// @notice Queues `shares` for redemption (transfers them into queue custody —
    ///         accrual-bearing participation ends here; see the ADR-0016 note in the
    ///         implementation). Strict FIFO position; no cancellation (queue-jump
    ///         gaming is not worth the surface in v1 — ADR-0010). Strict FIFO with no
    ///         reordering. Reverts `Queue_BelowMinRedemption` if the request is worth less than
    ///         `minRedemptionValue` (default $1) at the realized rate — the C-1 anti-dust-wedge
    ///         floor. A head worth < 1 wei at the conservative mark is never burned and never
    ///         requeued; settlement stops loudly (`Queue_HeadNotRedeemable`) until the mark cures.
    ///         No cancellation, so ADR-0018 stands.
    function requestRedeem(uint256 shares) external returns (uint256 requestId);

    /// @notice Transfers the filled USDfr of `requestId` to its owner. Callable by the
    ///         owner only, any time after (partial) fill; zeroes the claimable amount.
    function claim(uint256 requestId) external returns (uint256 assets);

    // ── Settlement (KEEPER-GATED — budget rules enforce safety) ──────────
    /// @notice Settles the epoch once its end has passed: snapshots the liquidity
    ///         budget on first call, then fills requests strictly FIFO (head request
    ///         may fill partially) until the budget, the queue, or `maxRequests` is
    ///         exhausted. Call repeatedly to process a long queue; the epoch advances
    ///         when settlement completes.
    ///         C-1: a fill is NEVER taken at a price of zero. If the head's whole remainder
    ///         prices to zero (senior front not redeemable at the conservative mark), settlement
    ///         stops with `Queue_HeadNotRedeemable` without consuming the epoch or burning
    ///         anything; the head keeps its FIFO place and settles when the mark cures.
    /// @dev    Requires `SETTLEMENT_KEEPER_ROLE`; reverts `AccessControlUnauthorizedAccount`
    ///         otherwise, and does so BEFORE the pause check. Gated because the epoch liquidity
    ///         budget is a spot read taken inside this call, which made it flash-loan
    ///         manipulable while permissionless (D7-01). Supersedes ADR-0018 §2.
    function closeEpoch(uint256 maxRequests) external;

    // ── Governance ───────────────────────────────────────────────────────
    /// @notice Sets the epoch cadence. Timelocked governance only.
    function setEpochDuration(uint64 duration) external;

    /// @notice Sets the share of stable liquidity distributable per settlement.
    function setEpochLiquidityBps(uint16 bps) external;

    /// @notice Sets the forced per-request redemption cooldown (ADR-0022). Timelocked
    ///         governance only. Applies uniformly to in-flight requests.
    function setRedeemCooldown(uint64 cooldown) external;

    /// @notice Sets the C-1 anti-dust-wedge minimum redemption value (realized USDfr).
    ///         Timelocked governance only; capped so it can never lock ordinary redeemers out.
    function setMinRedemptionValue(uint256 value) external;

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice Current epoch number (starts at 1).
    function currentEpoch() external view returns (uint256);

    /// @notice When the current epoch can settle.
    function epochEndsAt() external view returns (uint64);

    /// @notice True while a settlement is in progress (between first and last
    ///         `closeEpoch` chunk).
    function isSettling() external view returns (bool);

    /// @notice The liquidity budget remaining in the active settlement (0 when idle).
    function settlementBudgetRemaining() external view returns (uint256);

    /// @notice Number of completed transaction-sized pricing sessions.
    /// @dev Monotone across epoch boundaries; lets monitoring distinguish a deliberate price
    ///      revision boundary from two prices inside one session.
    function pricingSessionCount() external view returns (uint256);

    /// @notice What a settlement starting now could distribute: the governance-set
    ///         share of the treasury's idle canonical-USDC liquidity.
    function availableLiquidity() external view returns (uint256);

    /// @notice The forced per-request redemption cooldown, in seconds (ADR-0022).
    function redeemCooldown() external view returns (uint64);

    /// @notice The C-1 anti-dust-wedge minimum redemption value, in realized USDfr (default $1).
    function minRedemptionValue() external view returns (uint256);

    /// @notice The earliest timestamp at which `requestId` may be settled by `closeEpoch`
    ///         (its `requestedAt + redeemCooldown`).
    function eligibleToSettleAt(uint256 requestId) external view returns (uint256);

    /// @notice A request's state.
    /// @return owner The requester.
    /// @return sharesRemaining Shares still queued (not yet filled).
    /// @return assetsClaimable Filled USDfr not yet claimed.
    /// @return epochRequested The epoch the request joined.
    /// @return requestedAt The timestamp the request was made (the cooldown clock, ADR-0022).
    function request(uint256 requestId)
        external
        view
        returns (
            address owner,
            uint256 sharesRemaining,
            uint256 assetsClaimable,
            uint256 epochRequested,
            uint256 requestedAt
        );

    /// @notice Total requests ever made.
    function totalRequests() external view returns (uint256);

    /// @notice Index of the first not-fully-filled request (== totalRequests when the
    ///         queue is drained).
    function head() external view returns (uint256);

    /// @notice Total shares currently queued across all requests.
    function totalQueuedShares() external view returns (uint256);
}
