// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev Minimal live timing surface used by ReserveManager's C-01 Guardian pre-arm.
interface IReserveLossGovernor {
    function votingDelay() external view returns (uint256);
    function votingPeriod() external view returns (uint256);
    function timelock() external view returns (address);
    function clock() external view returns (uint48);
    function CLOCK_MODE() external view returns (string memory);
}

interface IReserveLossTimelock {
    function getMinDelay() external view returns (uint256);
}
