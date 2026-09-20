// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";

contract LegacyIncidentIsolationTest is TokenLayerFixture {
    function testFuzz_unratifiedArmRefusesEveryLegacyNonce(uint64 nonce) public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId, uint256 expectedIncident) = _armReserveLoss(901);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        vm.prank(admin);
        reserves.openReserveLossIncident(nonce, keccak256("legacy-record"));
        (uint256 active,) = reserves.activeReserveLossIncident();
        assertEq(active, 0);
        assertFalse(reserves.reserveLossIncidentUsed(expectedIncident));
        (uint256 quote, uint256 burn) = controller.previewRedeem(10e18);
        assertEq(quote, 0);
        assertEq(burn, 0);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, keccak256("reconciled"));
        vm.startPrank(admin);
        uint256 legacy = reserves.openReserveLossIncident(uint256(nonce) + 1, keccak256("legacy-after-resolution"));
        reserves.closeReserveLossIncident(legacy);
        vm.stopPrank();
    }

    function test_legacyNonceCannotUseTheReservedNamespace() public {
        uint256 invalidNonce = uint256(1) << 255;
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidIncidentNonce.selector, invalidNonce)
        );
        vm.prank(admin);
        reserves.openReserveLossIncident(invalidNonce, keccak256("invalid-namespace"));
        (uint256 active,) = reserves.activeReserveLossIncident();
        assertEq(active, 0);
    }

    function test_unratifiedArmAlsoRefusesLegacyClose() public {
        (uint256 armId, uint256 incidentId) = _armReserveLoss(902);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        (uint256 active,,,) = reserves.reserveLossArm();
        assertEq(active, armId);
        assertFalse(reserves.reserveLossIncidentUsed(incidentId));
    }

    function test_ratifiedArmKeepsItsIncidentUntilCheckedFinalization() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId, uint256 incidentId) = _armReserveLoss(903);
        _createReserveShortfall(10e18);
        _ratifyCurrentReserveLoss(10e18);
        uint256 backing = reserves.recognizedBackingValue();
        uint256 supply = controller.totalUSDfr();
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        (uint256 current,) = reserves.activeReserveLossIncident();
        assertEq(current, incidentId);
        assertEq(reserves.recognizedBackingValue(), backing);
        assertEq(controller.totalUSDfr(), supply);
        _createReserveShortfall(1e18);
        _ratifyCurrentReserveLoss(1e18);
        assertEq(reserves.reserveDeficit(), 11e18);
        usdc.mint(address(reserves), 11e6);
        vm.startPrank(admin);
        reserves.creditRecoveredIdleUSDC(armId, keccak256("actual-recovery"));
        reserves.finalizeAndDisable(armId, keccak256("resolved"));
        vm.stopPrank();
        (current,,,) = reserves.reserveLossArm();
        assertEq(current, 0);
        assertEq(reserves.reserveDeficit(), 0);
    }
}
