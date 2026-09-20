// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";

/// @notice Lifecycle and collateral-model refusals precede interest-book maintenance.
contract DefaultMarginEligibilityTest is NativeAccrualFixture {
    function _refuseEveryMarginEntry(uint256 id, bytes memory reason) private {
        bytes32 facilityBefore = keccak256(abi.encode(bridge.facility(id)));
        bytes32 bookBefore = keccak256(abi.encode(reserves.accrualSnapshot()));
        uint256 revisionBefore = defaultManager.impairmentRevision();
        uint256 supplyBefore = usdfr.totalSupply();

        vm.expectRevert(reason);
        defaultManager.marginCall(id);
        vm.expectRevert(reason);
        defaultManager.clearMarginCall(id);
        vm.expectRevert(reason);
        defaultManager.liquidate(id);

        assertEq(keccak256(abi.encode(bridge.facility(id))), facilityBefore, "refusal changed the facility");
        assertEq(keccak256(abi.encode(reserves.accrualSnapshot())), bookBefore, "refusal changed the book");
        assertEq(defaultManager.impairmentRevision(), revisionBefore, "refusal changed risk history");
        assertEq(usdfr.totalSupply(), supplyBefore, "refusal changed issued value");
    }

    function test_pendingDigitalFacilityReportsItsLifecycleRefusal() public {
        uint256 id = _originateDigital(100_000e18, 400_000e18);
        assertFalse(reserves.accruedDebt(id).known, "pending loan entered the debt book");
        _refuseEveryMarginEntry(id, abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
    }

    function test_cancelledDigitalFacilityReportsItsLifecycleRefusal() public {
        uint256 id = _originateDigital(100_000e18, 400_000e18);
        vm.prank(originator);
        bridge.cancelPending(id);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Cancelled));
        _refuseEveryMarginEntry(id, abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
    }

    function test_repaidDigitalFacilityReportsItsLifecycleRefusal() public {
        uint256 id = _originateDigital(100_000e18, 400_000e18);
        _fundFacility(id, 100_000e18);
        _repay(id, 0, 100_000e18);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid));
        _refuseEveryMarginEntry(id, abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
    }

    function test_resolvedDigitalFacilityReportsItsLifecycleRefusal() public {
        uint256 id = _originateDigital(100_000e18, 400_000e18);
        _fundFacility(id, 100_000e18);
        vm.warp(block.timestamp + 1);
        _setValuation(id, 100_000e18, uint64(block.timestamp));
        defaultManager.liquidate(id);
        _repay(id, reserves.accruedDebt(id).interest, 100_000e18);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved));
        _refuseEveryMarginEntry(id, abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
    }

    function test_pendingReceivableReportsItsCollateralModelRefusal() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        _refuseEveryMarginEntry(
            id, abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id)
        );
    }
}
