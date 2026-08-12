// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {F1BlastRadiusBase} from "./F1_BlastRadius.t.sol";

/// @title F1 D1 independent physical-bound check
/// @notice This is deliberately separate from the differential gate.  It executes the real
///         SGrove cascade to exhaustion in both event orders, then compares the production credit
///         with the lower physical delivery.  It does not reimplement the clamp arithmetic or
///         use a mock backstop.  The partial-drawn fixture has no curator pool, so every credited
///         unit is a layer-2 unit and the bound is directly comparable. Under ADR-0035 the three
///         live events share 380,000e18 of residual reserve against 505,000e18 of residual
///         principal, so either exhaustive realization order must drain exactly 380,000e18.
contract F1D1IndependentPhysicalBoundTest is F1BlastRadiusBase {
    function test_D1_partialDrawnCreditIsInsideExecutedPhysicalBounds() public {
        _sPartialDrawn();

        uint256 forward = _deliverable(true);
        uint256 reverse = _deliverable(false);
        uint256 lower = forward < reverse ? forward : reverse;
        uint256 upper = forward > reverse ? forward : reverse;
        uint256 credited = defaultManager.performanceFeeImpairment() - defaultManager.pendingSeniorImpairment();

        emit log_named_uint("D1 physical forward delivery", forward);
        emit log_named_uint("D1 physical reverse delivery", reverse);
        emit log_named_uint("D1 physical lower bound", lower);
        emit log_named_uint("D1 physical upper bound", upper);
        emit log_named_uint("D1 production credit", credited);

        assertEq(forward, 380_000e18, "D1 forward SGrove delivery changed");
        assertEq(reverse, 380_000e18, "D1 reverse SGrove delivery changed");
        assertGe(credited, lower, "D1 production credit under-marks below executed delivery");
        assertLe(credited, upper, "F1 production credit exceeds executed delivery");
    }
}
