// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IImpairmentSource} from "./IImpairmentSource.sol";

/// @title IRevisionedImpairmentSource — impairment plus an assessment-binding fingerprint
/// @notice Extends the vault's narrow impairment interface with the state identity required by
///         governed recovery assessments. A consumer can bind an assessment to one exact risk
///         snapshot and fail conservatively when that snapshot changes.
interface IRevisionedImpairmentSource is IImpairmentSource {
    /// @notice Monotonic revision advanced whenever protocol-managed impairment risk changes.
    /// @dev Prevents an old assessment becoming active again if risk quantities later return to
    ///      values that happen to match their earlier amounts.
    function impairmentRevision() external view returns (uint256);

    /// @notice Fingerprint of the revision and every live input used to calculate impairment.
    /// @dev Must also include relevant state held by external junior-capacity modules.
    function impairmentStateHash() external view returns (bytes32);

    /// @notice Assessment-binding risk fingerprint excluding only live global backstop capacity.
    /// @dev Lets an assessment distinguish a beneficial global backstop top-up from every
    ///      protocol-risk or curator-capacity change. Consumers must pair this with
    ///      `impairmentBackstopCapacity()` and invalidate if capacity falls below the snapshot.
    function impairmentRiskStateHash() external view returns (bytes32);

    /// @notice Current effective capacity of the global junior backstop.
    function impairmentBackstopCapacity() external view returns (uint256);
}
