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

    /// @notice Assessment identity plus the live overdue face and directional junior capacity.
    /// @dev The identity binds risk revisions, declared claims, wiring and per-class curator
    ///      balances. It excludes posted and unposted past-due amounts: posting is neutral and
    ///      elapsed interest is handled by the separate exposure. A consumer must snapshot all
    ///      three values, reject changed identity, lower exposure or lower capacity, and add
    ///      every later exposure increase to both assessed impairment views. This method does
    ///      not change the exact hashes used by older consumers.
    /// @return riskStateHash Identity unchanged by accrual alone or neutral posting.
    /// @return pastDueExposure Complete recorded plus unposted overdue face, in 18-decimal USDfr.
    /// @return backstopCapacity Current effective global junior capacity; zero on BSC.
    function impairmentAssessmentState()
        external
        view
        returns (bytes32 riskStateHash, uint256 pastDueExposure, uint256 backstopCapacity);

    /// @notice Current effective capacity of the global junior backstop.
    function impairmentBackstopCapacity() external view returns (uint256);
}
