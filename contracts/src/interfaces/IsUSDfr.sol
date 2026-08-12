// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IsUSDfr
/// @notice The yield-bearing ERC-4626 vault over USDfr (ADR-0005). Yield accrues via the
///         assets/shares exchange rate; exits are routed through the epoch redemption
///         queue (ADR-0010) — the vault's instant withdraw/redeem paths are restricted
///         to the queue module.
interface IsUSDfr is IERC4626 {
    /// @notice Emitted when the redemption queue address is set.
    event RedemptionQueueUpdated(address indexed queue);

    /// @notice Instant exit attempted by an account other than the redemption queue.
    error SUSDfr_QueueOnly();
    /// @notice Share movement involving a sanctioned (blocked) party.
    error SUSDfr_TransferBlocked(address from, address to);
    /// @notice A management-fee rate above the permanent v1 cap was requested.
    error SUSDfr_ManagementFeeTooHigh(uint16 requestedBps);
    /// @notice A performance-fee rate above the permanent v1 cap was requested.
    error SUSDfr_PerformanceFeeTooHigh(uint16 requestedBps);
    /// @notice A fee checkpoint was attempted during a transient share update or
    ///         while a cross-module fee-accounting operation was locked.
    error SUSDfr_FeeAccrualReentrant();
    /// @notice A two-phase fee-accounting operation was completed by the wrong caller
    ///         or with the wrong operation type.
    error SUSDfr_InvalidFeeOperation(address caller, uint8 expectedKind, uint8 actualKind);
    /// @notice Share supply changed during a fee-neutral marked-NAV operation.
    error SUSDfr_FeeOperationSupplyChanged(uint256 expectedSupply, uint256 actualSupply);
    /// @notice A replacement fee recipient was not marked as a protocol-exempt address.
    error SUSDfr_FeeRecipientNotExempt(address recipient);
    /// @notice A proposed impairment source has no code or cannot return a uint256 impairment.
    error SUSDfr_InvalidImpairmentSource(address source);
    /// @notice A source reported less performance-fee impairment than redemption impairment.
    error SUSDfr_InvalidPerformanceFeeImpairment(uint256 pendingImpairment, uint256 performanceImpairment);
    /// @notice Emergency clearing was requested while the current impairment source is valid.
    error SUSDfr_ImpairmentSourceStillReadable(address source);
    /// @notice Emergency clearing was requested when no impairment source is configured.
    error SUSDfr_NoImpairmentSource();
    /// @notice Too little gas was supplied to prove source failure and finish recovery safely.
    error SUSDfr_InsufficientImpairmentRecoveryGas(uint256 available, uint256 required);
    /// @notice Emitted when the (fail-open) points hook reverted on a share move (P-04 telemetry).

    event PointsHookFailed(address indexed from, address indexed to, uint256 value);
    /// @notice Protocol fee shares were minted for time-based management fees.
    event ManagementFeeAccrued(uint256 elapsed, uint256 feeAssets, uint256 feeShares);
    /// @notice Protocol fee shares were minted on marked NAV above the global high-water mark.
    event PerformanceFeeAccrued(
        uint256 oldHighWaterMark, uint256 newHighWaterMark, uint256 profitAssets, uint256 feeAssets, uint256 feeShares
    );
    /// @notice A fee-neutral flow adjusted the global high-water mark.
    event HighWaterMarkAdjusted(uint256 oldHighWaterMark, uint256 newHighWaterMark);
    /// @notice An authorized module checkpointed fees and locked a junior-capacity operation.
    event FeeNeutralMarkedNavChangeStarted(address indexed module, uint256 supply);
    /// @notice The authorized junior-capacity operation released its checkpoint lock.
    event FeeNeutralMarkedNavChangeCompleted(address indexed module, uint256 supply);
    /// @notice The WaterfallEngine locked fee checkpoints before delivering senior yield.
    event YieldNotificationStarted(address indexed module);
    /// @notice Governance cleared a fee-operation lock left behind by a faulty trusted module.
    event FeeOperationEmergencyCleared(address indexed module, uint8 indexed operationKind);
    /// @notice The queue prepared one settlement chunk against the full remaining settlement
    ///         outflow bound before taking any price quote.
    /// @param maxAssets Maximum USDfr that the live settlement can still distribute.
    /// @param projectedHeld Physical USDfr that would remain if that full bound left the vault.
    /// @param instantlyRecognized Previously-unvested yield released before pricing.
    event RedemptionPricingPrepared(uint256 maxAssets, uint256 projectedHeld, uint256 instantlyRecognized);
    /// @notice Timelocked governance changed the prospective annual management-fee rate.
    event ManagementFeeSet(uint16 oldFeeBps, uint16 newFeeBps);
    /// @notice Timelocked governance changed the prospective global performance-fee rate.
    event PerformanceFeeSet(uint16 oldFeeBps, uint16 newFeeBps);
    /// @notice Timelocked governance changed the recipient of future vault fee shares.
    event VaultFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Timelocked governance cleared an unreadable impairment source without checkpointing it.
    /// @dev `failureHash` commits to the failed selector and bounded return evidence, or
    ///      to the semantically invalid pair of impairment values.
    event ImpairmentSourceEmergencyCleared(address indexed source, bytes32 failureHash);

    /// @notice Current fee-net realized exchange rate: assets per one whole sUSDfr token.
    /// @dev Simulates fee shares due at this timestamp even before a checkpoint transaction.
    function currentExchangeRate() external view returns (uint256);

    /// @notice Crystallizes management and global high-water-mark performance fees.
    /// @dev Permissionless. Fee shares mint to `feeRecipient`; no backing assets leave.
    /// @return managementShares Shares minted for the time-based management fee.
    /// @return performanceShares Shares minted for profit above the high-water mark.
    function accrueFees() external returns (uint256 managementShares, uint256 performanceShares);

    /// @notice Prepares queue redemption pricing against the live settlement's full remaining
    ///         outflow bound, then checkpoints fees once against the prepared state.
    /// @dev Queue-only. Using the settlement bound rather than the caller-selected request count
    ///      makes optional-stream recognition independent of keeper chunking (G4/M-2).
    /// @param maxAssets Maximum USDfr the settlement can still distribute.
    /// @return instantlyRecognized Previously-unvested yield released before pricing.
    function prepareRedemptionPricing(uint256 maxAssets) external returns (uint256 instantlyRecognized);

    /// @notice Checkpoints fees and locks checkpoints before an authorized junior-capacity change.
    /// @dev Must be paired atomically with `endFeeNeutralMarkedNavChange` by the same module.
    ///      Junior-capacity effects are excluded by the impairment source's independent
    ///      performance-fee view; this function never infers a capital flow from a NAV re-read.
    function beginFeeNeutralMarkedNavChange() external;

    /// @notice Releases an authorized junior-capacity operation's checkpoint lock.
    /// @dev The caller and share supply must match the opening snapshot.
    function endFeeNeutralMarkedNavChange() external;

    /// @notice Locks vault fee checkpoints before the WaterfallEngine delivers senior yield.
    /// @dev Must be paired atomically with `notifyYield` by the same module.
    function beginYieldNotification() external;

    /// @notice Clears a fee-operation lock that survived a successful trusted-module call.
    /// @dev Timelocked emergency recovery only. Correct module paths open and close their
    ///      lock atomically, so a persistent lock means the trusted caller is faulty.
    function clearStaleFeeOperation() external;

    /// @notice Current global performance-fee rate, in basis points of profit.
    function performanceFeeBps() external view returns (uint16);

    /// @notice Permanent v1 performance-fee ceiling, in basis points.
    function maxPerformanceFeeBps() external pure returns (uint16);

    /// @notice Current annualized management-fee rate, in basis points.
    function managementFeeBps() external view returns (uint16);

    /// @notice Permanent v1 management-fee ceiling, in basis points.
    function maxManagementFeeBps() external pure returns (uint16);

    /// @notice Time basis used to interpret the annual management-fee rate.
    function managementFeeYear() external pure returns (uint64);

    /// @notice Global post-fee high-water mark, in the same units as `feeExchangeRate`.
    function highWaterMark() external view returns (uint256);

    /// @notice Gross rate used for HWM accounting after fee-neutral junior-capital credit.
    /// @dev Unlike `currentExchangeRate`, this does not simulate pending fee shares. It can be
    ///      below the redemption-NAV rate while junior capital protects a live impairment.
    function feeExchangeRate() external view returns (uint256);

    /// @notice Recipient of sUSDfr management/performance fee shares.
    function feeRecipient() external view returns (address);

    /// @notice Last timestamp through which the management fee was accrued.
    function lastFeeAccrual() external view returns (uint64);

    /// @notice Sets the prospective management fee. Timelocked governance only.
    function setManagementFee(uint16 feeBps) external;

    /// @notice Sets the prospective performance fee. Timelocked governance only.
    function setPerformanceFee(uint16 feeBps) external;

    /// @notice Changes the recipient of future vault fee shares. Timelocked governance only.
    function setFeeRecipient(address recipient) external;

    /// @notice Clears a configured impairment source only when a bounded read demonstrably fails.
    /// @dev Timelocked governance recovery path. It deliberately cannot replace a readable source
    ///      or install a new source; normal changes must use the checkpointed setter. Any marked-NAV
    ///      lift is ratcheted fee-free, permanently waiving performance fees embedded in that lift.
    function clearUnreadableImpairmentSource() external;

    /// @notice Sets or clears the conservative marked-NAV impairment source.
    /// @dev Timelocked governance only. A non-zero replacement must pass an ABI read before
    ///      the old valuation period is checkpointed and the replacement is stored.
    function setImpairmentSource(address source) external;

    /// @notice Current conservative marked-NAV impairment source, or zero when unwired.
    function impairmentSource() external view returns (address);

    /// @notice The redemption queue module (sole permitted caller of withdraw/redeem).
    function redemptionQueue() external view returns (address);

    /// @notice Sets the redemption queue. Only DEFAULT_ADMIN_ROLE (timelocked governance).
    function setRedemptionQueue(address queue) external;

    /// @notice Recognizes realized senior yield immediately or starts optional vesting (ADR-0023).
    /// @dev Called by the WaterfallEngine right after it delivers `amount` USDfr into the
    ///      vault. Moves no value. With a zero vesting period, recognition and the resulting
    ///      performance-fee checkpoint complete in the caller's repayment transaction. A
    ///      non-zero governance setting defers recognition linearly as an optional
    ///      market-smoothing policy. Gated by CREDIT_ROLE.
    /// @param amount The realized yield just delivered into the vault.
    function notifyYield(uint256 amount) external;

    /// @notice Realized senior yield not yet released into the exchange rate (ADR-0023).
    function unvestedYield() external view returns (uint256);

    /// @notice The asset base exits price against: realized assets LESS the
    ///         declared-but-unrealized senior impairment (ADR-0022 Option Y).
    /// @dev Always `<= totalAssets()`, so redemption NAV <= deposit NAV.
    function redemptionTotalAssets() external view returns (uint256);

    /// @notice Shares that `assets` buys at the conservative redemption NAV, rounded DOWN.
    /// @dev The floor-rounded counterpart to `previewWithdraw` (which rounds up). The queue caps
    ///      its settlement budget with this so `previewRedeem(result) <= assets` holds by
    ///      construction and settlement can never distribute above the budget (CLAUDE.md §1.3).
    /// @param assets The budget, in USDfr.
    /// @return The largest share count whose conservative redemption value does not exceed `assets`.
    function convertToSharesAtRedemption(uint256 assets) external view returns (uint256);
}
