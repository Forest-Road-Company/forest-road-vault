// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IReserveLossTimelock - the executing timelock's minimum delay
/// @notice BSC instance (ADR-0037 D3(b)): there is NO Governor. `IReserveLossGovernor`, which
///         declared `votingDelay`, `votingPeriod`, `timelock`, `clock` and `CLOCK_MODE`, is deleted
///         with it. The only on-chain timing dependency ReserveManager has left is the timelock's
///         own minimum delay, and that single read is now load-bearing twice over: it must be
///         READABLE as exactly one word, which fails closed against a permissive fallback, a proxy
///         with an empty implementation slot, or a Safe at the address; and it must be at least
///         `Config.TIMELOCK_MIN_DELAY`, so a timelock deployed with - or later retuned to - a
///         shorter delay than the protocol's own floor cannot be installed as the timing source.
/// @dev Do not reduce the check to `target.code.length != 0`.
interface IReserveLossTimelock {
    /// @notice Minimum seconds an operation must sit queued before it may execute.
    function getMinDelay() external view returns (uint256);
}
