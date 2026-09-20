// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {ReserveIncidentLib} from "../../src/libraries/ReserveIncidentLib.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @notice Regression checks for linked incident bookkeeping in the real reserve proxy.
contract ReserveIncidentExtractionTest is TokenLayerFixture {
    function test_missingLibraryCodeRefusesReturningEntryWithoutChangingArm() public {
        address helper = address(ReserveIncidentLib);
        assertGt(helper.code.length, 0);
        vm.etch(helper, bytes(""));
        assertEq(helper.code.length, 0);
        vm.expectRevert(bytes(""));
        vm.prank(guardian);
        reserves.armReserveLossFreeze(keccak256("missing-returning-helper"));
        (uint256 armId, uint256 incidentId, bytes32 evidence, bool enabled) = reserves.reserveLossArm();
        assertEq(armId, 0);
        assertEq(incidentId, 0);
        assertEq(evidence, bytes32(0));
        assertTrue(enabled);
    }

    function test_missingLibraryCodeRefusesVoidEntryWithoutClosingIncident() public {
        bytes32 evidence = keccak256("missing-void-helper");
        vm.prank(admin);
        uint256 incidentId = reserves.openReserveLossIncident(9, evidence);
        address helper = address(ReserveIncidentLib);
        assertGt(helper.code.length, 0);
        vm.etch(helper, bytes(""));
        assertEq(helper.code.length, 0);
        vm.expectRevert(bytes(""));
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        (uint256 actualId, bytes32 actualEvidence) = reserves.activeReserveLossIncident();
        assertEq(actualId, incidentId);
        assertEq(actualEvidence, evidence);
    }

    /// @dev Independent model: each successful arm consumes one identity; only the measured
    ///      incident loss can be re-credited. Excess recovery stays unrecorded and cannot mint.
    function testFuzz_incidentSequencePreservesIdentityCapacityAndBacking(bytes32 seed, uint8 count) public {
        uint256 rounds = bound(uint256(count), 1, 24);
        uint256 initialUnits = 10_000e6;
        _mintUSDfr(alice, initialUnits);
        uint256 supply = usdfr.totalSupply();
        for (uint256 i = 0; i < rounds; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            uint256 lossUnits = random % 7 == 0 ? 0 : 1 + random % initialUnits;
            uint256 giftUnits = (random >> 96) % 1e6;
            bytes32 evidence = keccak256(abi.encode("incident-sequence", seed, i));
            vm.prank(admin);
            reserves.setGuardianReserveLossArmsEnabled(true);
            vm.prank(guardian);
            (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
            assertEq(armId, i + 1);
            assertEq(incidentId, type(uint256).max - armId);
            if (lossUnits == 0) {
                vm.prank(admin);
                reserves.cancelAndDisable(armId, evidence);
                assertFalse(reserves.reserveLossIncidentUsed(incidentId));
            } else {
                vm.prank(address(reserves));
                assertTrue(usdc.transfer(borrower, lossUnits));
                vm.prank(admin);
                (uint256 opened, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidence, lossUnits * 1e12);
                assertEq(opened, incidentId);
                assertEq(actualLoss, lossUnits * 1e12);
                assertEq(reserves.reserveLossRecoveryCapacity(armId), lossUnits);
                assertEq(reserves.reserveDeficit(), lossUnits * 1e12);
                uint256 backingAfterLoss = reserves.totalBackingValue();
                usdc.mint(address(reserves), lossUnits + giftUnits);
                assertEq(reserves.totalBackingValue(), backingAfterLoss, "unrecorded recovery created backing");
                vm.prank(admin);
                uint256 credited = reserves.creditRecoveredIdleUSDC(armId, evidence);
                assertEq(credited, lossUnits * 1e12);
                assertEq(reserves.reserveLossRecoveryCapacity(armId), 0);
                assertEq(reserves.unrecordedUSDC(), giftUnits);
                vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, armId));
                vm.prank(admin);
                reserves.creditRecoveredIdleUSDC(armId, evidence);
                vm.prank(admin);
                reserves.finalizeAndDisable(armId, evidence);
                assertTrue(reserves.reserveLossIncidentUsed(incidentId));
                vm.prank(address(reserves));
                assertTrue(usdc.transfer(borrower, giftUnits));
            }
            _assertClosed(initialUnits, supply);
        }
    }

    function _assertClosed(uint256 initialUnits, uint256 supply) private view {
        (uint256 armId, uint256 incidentId, bytes32 evidence, bool enabled) = reserves.reserveLossArm();
        assertEq(armId, 0);
        assertEq(incidentId, 0);
        assertEq(evidence, bytes32(0));
        assertFalse(enabled);
        (uint256 active, bytes32 activeEvidence) = reserves.activeReserveLossIncident();
        assertEq(active, 0);
        assertEq(activeEvidence, bytes32(0));
        assertEq(reserves.idleUSDC(), initialUnits);
        assertEq(usdc.balanceOf(address(reserves)), initialUnits);
        assertEq(reserves.reserveDeficit(), 0);
        assertEq(reserves.totalBackingValue(), initialUnits * 1e12);
        assertEq(usdfr.totalSupply(), supply, "recovery changed token supply");
    }
}
