// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Collateral ratios include earned cash interest before its receipt on either chain.
contract NativeCollateralThresholdsTest is NativeAccrualFixture {
    uint256 private constant PRINCIPAL = 100_000e18;

    function _fundDigitalNote() private returns (uint256 id, uint64 fundedAt) {
        id = _originateDigital(PRINCIPAL, 400_000e18);
        _fundFacility(id, PRINCIPAL);
        fundedAt = uint64(block.timestamp);
    }

    /// @dev Independent signed-note arithmetic: 1000 bps Actual/360, floored to the reserve unit.
    function _referenceFace(uint64 fundedAt) private view returns (uint256) {
        uint256 scale = _nativeScale();
        uint256 coupon = (PRINCIPAL * 1000 * (block.timestamp - fundedAt) / (10_000 * 360 days)) / scale * scale;
        return PRINCIPAL + coupon;
    }

    function testFuzz_unreceivedInterestEntersCollateralRatio(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 2 days, 29 days));
        (uint256 id, uint64 fundedAt) = _fundDigitalNote();
        vm.warp(uint256(fundedAt) + elapsed);
        // Place the reference ratio halfway inside its integer-basis-point interval. This
        // keeps reserve-unit rounding away from the boundary without an assertion tolerance.
        uint256 mark = _referenceFace(fundedAt) * 20_000 / 10_001;
        _setValuation(id, mark, uint64(block.timestamp));
        (uint256 ltv,) = defaultManager.currentLtvBps(id);
        assertEq(ltv, 5000, "collateral ratio omitted or duplicated earned interest");
        assertLt(PRINCIPAL * Config.BPS / mark, 5000, "principal-only arithmetic must fail this fixture");
        assertEq(reserves.accruedDebt(id).interest, _referenceFace(fundedAt) - PRINCIPAL, "independent coupon");
    }

    function test_marginBoundaryUsesAccruedFaceAt6499And6500() public {
        (uint256 id, uint64 fundedAt) = _fundDigitalNote();
        vm.warp(uint256(fundedAt) + 7 days + 1);
        // Target the middle of integer LTV 6499: canonical and streamed rounding
        // must both remain below 6500 without relying on a one-wei boundary.
        _setValuation(id, _referenceFace(fundedAt) * (2 * Config.BPS) / 12999, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 6499, 6500)
        );
        defaultManager.marginCall(id);
        assertEq(defaultManager.cureDeadline(id), 0, "below-threshold call changed the deadline");

        vm.warp(block.timestamp + 1);
        _setValuation(id, _referenceFace(fundedAt) * (2 * Config.BPS) / 13001, uint64(block.timestamp));
        uint64 deadline = uint64(block.timestamp + Config.DEFAULT_MARGIN_CURE_WINDOW);
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.MarginCalled(id, 6500, deadline);
        defaultManager.marginCall(id);
        assertEq(defaultManager.cureDeadline(id), deadline);
    }

    function test_liquidationBoundaryUsesAccruedFaceAt7999And8000() public {
        (uint256 id, uint64 fundedAt) = _fundDigitalNote();
        vm.warp(uint256(fundedAt) + 7 days + 1);
        _setValuation(id, _referenceFace(fundedAt) * (2 * Config.BPS) / 15999, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 7999, 8000)
        );
        defaultManager.liquidate(id);
        assertEq(defaultManager.cureDeadline(id), 0, "no margin-call shortcut may trigger liquidation");

        vm.warp(block.timestamp + 1);
        _setValuation(id, _referenceFace(fundedAt) * (2 * Config.BPS) / 16001, uint64(block.timestamp));
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.LiquidationInitiated(id, 8000);
        defaultManager.liquidate(id);
        assertEq(defaultManager.declaredDefaultedPrincipal(Config.CLASS_DIGITAL_ASSETS), _referenceFace(fundedAt));
    }
}
