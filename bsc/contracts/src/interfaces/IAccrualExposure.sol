// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IContinuousAccrual} from "./IContinuousAccrual.sol";

/// @title IAccrualExposure
/// @notice Reserve-local unposted earned claims used by the collateral concentration book.
/// @dev Values share the continuous Book's capped frontier and never scan facilities. A source
///      must implement the complete continuous-accrual identity, snapshot and admission surface.
interface IAccrualExposure is IContinuousAccrual {
    /// @notice Returns unposted normalized-18-decimal exposure for one aggregate identity.
    /// @param kind Total=0, class=1, borrower=2, state=3.
    /// @param identity Total uses zero; class uses bytes32(classId); borrower/state use their
    ///      existing identity keys. A zero state represents no state tag and returns zero.
    function accrualExposure(uint8 kind, bytes32 identity) external view returns (uint256);

    /// @notice Additional future funded face already reserved beyond current effective exposure.
    /// @dev Origination must preserve this numeric room, including while pending unfunded claims
    ///      consume registry exposure. Concentration ratios continue to use current exposure.
    function accrualReservedExposure() external view returns (uint256);

    /// @notice Refuses an overlapping source operation without requiring its loan clock current.
    /// @dev Repayment/loss decreases and governed recovery must not depend on keeper freshness.
    function requireAccrualIdle() external view;
}

/// @title IAccrualExposureRegistry
/// @notice Narrow registry continuation for physical posting of already earned exposure.
interface IAccrualExposureRegistry {
    /// @notice Permanently binds the governed reserve that supplies virtual exposure.
    function setAccrualReserve(address reserve) external;

    /// @notice The permanent reserve, or zero while continuous exposure is disabled.
    function accrualReserve() external view returns (address);

    /// @notice Posts an already consumed reserve-local virtual claim into stored registry face.
    /// @dev Only the bound reserve may call. It must first consume identical Book posting and
    ///      write its native reserve face in the same protected operation. This is a neutral
    ///      reclassification, bypassing origination limits while retaining the numeric cap.
    function recordAccruedExposure(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 amount) external;
}
