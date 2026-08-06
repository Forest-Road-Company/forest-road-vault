// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";

/// @dev Directly settable declared-but-unrealized senior impairment (ADR-0022 Option Y).
///      Used by stateful-fuzz handlers that need bounded control of the conservative
///      redemption mark without driving a whole default lifecycle per fuzz call.
contract MockImpairmentSource is IImpairmentSource {
    uint256 internal impairment;
    uint256 internal feeImpairment;

    /// @notice Sets the declared senior impairment reported to `sUSDfr`.
    /// @dev Sets both views to preserve the legacy single-NAV test control.
    /// @param amount The impairment, in USDfr.
    function setImpairment(uint256 amount) external {
        impairment = amount;
        feeImpairment = amount;
    }

    /// @notice Sets independently bounded redemption and performance-fee impairments.
    /// @dev The production invariant requires `performanceAmount >= redemptionAmount`.
    function setImpairments(uint256 redemptionAmount, uint256 performanceAmount) external {
        impairment = redemptionAmount;
        feeImpairment = performanceAmount;
    }

    /// @inheritdoc IImpairmentSource
    function pendingSeniorImpairment() external view returns (uint256) {
        return impairment;
    }

    /// @inheritdoc IImpairmentSource
    function performanceFeeImpairment() external view returns (uint256) {
        return feeImpairment;
    }
}
