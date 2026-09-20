// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ITimelockSchedule - the executing timelock's minimum delay
/// @notice AUDIT FIX (R6-CF1), as reduced for this instance. On Ethereum this file also declared
///         `IGovernanceSchedule` (`votingDelay` + `votingPeriod` + `timelock` + `CLOCK_MODE`),
///         because a guardian pre-arm had to outlast a Governor vote plus the timelock delay or the
///         freeze it bought lapsed before governance could possibly ratify it.
/// @dev BSC instance (ADR-0037 D3(b)): there is no Governor, so there is no vote to outlast and no
///      voting parameter to read. The governance path is exactly the timelock's minimum delay,
///      which remains GOVERNANCE-MUTABLE (`TimelockController.updateDelay`) and is therefore still
///      read LIVE rather than compiled in. The `Config` launch constant stays a FLOOR; this
///      interface supplies the live reading that overrides it upwards.
interface ITimelockSchedule {
    /// @notice Minimum seconds an operation must sit queued before it may execute.
    function getMinDelay() external view returns (uint256);
}
