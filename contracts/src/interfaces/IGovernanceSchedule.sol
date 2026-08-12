// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IGovernanceSchedule — the live length of the protocol's governance path
/// @notice AUDIT FIX (R6-CF1). The three parameters that together determine how long it takes a
///         proposal to become an executed on-chain act: `votingDelay` + `votingPeriod` on the
///         governor, plus the timelock's `getMinDelay`.
/// @dev WHY THIS INTERFACE EXISTS, AND WHY THE VALUES ARE READ LIVE RATHER THAN COMPILED IN.
///      `CuratorModule`'s guardian pre-arm must outlast the full governance path, or the freeze it
///      buys lapses before governance can possibly ratify it and the protection is decorative.
///      All three parameters are GOVERNANCE-MUTABLE (`GovernorSettings.setVotingDelay` /
///      `setVotingPeriod`, `TimelockController.updateDelay`), so a hardcoded literal — or even the
///      `Config` launch constants alone — silently becomes wrong the day any one of them is
///      retuned. The `Config` sum is kept as a FLOOR; this interface supplies the live reading
///      that overrides it upwards.
///
///      Deliberately NOT the full `IGovernor`: this is a parameter source, and a narrow interface
///      is what lets a future governor implementation satisfy it without inheriting OZ's stack.
interface IGovernanceSchedule {
    /// @notice ERC-6372 clock description. Only `"mode=timestamp"` is commensurable with
    ///         `block.timestamp`; a block-number clock reports voting windows in units that must
    ///         NOT be added to a timestamp, and callers must fall back to their own floor.
    function CLOCK_MODE() external view returns (string memory);

    /// @notice Delay between proposal submission and the start of voting, in clock units.
    function votingDelay() external view returns (uint256);

    /// @notice Length of the voting window, in clock units.
    function votingPeriod() external view returns (uint256);

    /// @notice The timelock that executes passed proposals.
    function timelock() external view returns (address);
}

/// @title ITimelockSchedule — the executing timelock's minimum delay
interface ITimelockSchedule {
    /// @notice Minimum seconds an operation must sit queued before it may execute.
    function getMinDelay() external view returns (uint256);
}
