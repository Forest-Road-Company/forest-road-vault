// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";

contract IncidentMediumRegression is TokenLayerFixture {
    function test_medium_legacyIncidentCannotBlockNewLossResolution() public {
        _mintUSDfr(alice, 100e6);
        bytes32 evidence = keccak256("separate-legacy-and-current-incidents");
        vm.startPrank(admin);
        uint256 old = reserves.openReserveLossIncident(1, evidence);
        reserves.closeReserveLossIncident(old);
        vm.stopPrank();
        vm.prank(guardian);
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        assertEq(armId, 2);
        assertNotEq(incidentId, old);
        assertFalse(reserves.reserveLossIncidentUsed(incidentId));
        vm.prank(address(reserves));
        assertTrue(usdc.transfer(borrower, 10e6));
        vm.prank(admin);
        (uint256 opened, uint256 loss) = reserves.ratifyAndOpen(armId, evidence, 10e18);
        assertEq(opened, incidentId);
        assertEq(loss, 10e18);
        assertTrue(reserves.reserveLossIncidentUsed(old));
        assertTrue(reserves.reserveLossIncidentUsed(incidentId));
        usdc.mint(address(reserves), 10e6);
        vm.prank(admin);
        assertEq(reserves.creditRecoveredIdleUSDC(armId, evidence), 10e18);
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, evidence);
        assertEq(reserves.reserveDeficit(), 0);
        assertTrue(controller.backingInvariantHolds());
    }

    function testFuzz_medium_armSkipsHistoricalIdsAndKeepsItsCursor(uint8 countSeed) public {
        uint256 count = bound(uint256(countSeed), 1, 64);
        bytes32 evidence = keccak256("historical-id-set");
        vm.startPrank(admin);
        for (uint256 i = 1; i <= count; ++i) {
            uint256 id = reserves.openReserveLossIncident(i, evidence);
            reserves.closeReserveLossIncident(id);
            assertTrue(reserves.reserveLossIncidentUsed(id));
        }
        vm.stopPrank();
        vm.prank(guardian);
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        assertEq(armId, count + 1);
        assertEq(incidentId, type(uint256).max - armId);
        assertFalse(reserves.reserveLossIncidentUsed(incidentId));
        vm.startPrank(admin);
        reserves.cancelAndDisable(armId, evidence);
        reserves.setGuardianReserveLossArmsEnabled(true);
        vm.stopPrank();
        vm.prank(guardian);
        (uint256 next, uint256 nextIncident) = reserves.armReserveLossFreeze(evidence);
        assertEq(next, count + 2);
        assertNotEq(nextIncident, incidentId);
        assertFalse(reserves.reserveLossIncidentUsed(nextIncident));
    }

    function test_medium_largeLegacyNonceDoesNotConsumeUnusedLowerIds() public {
        bytes32 evidence = keccak256("noncontiguous-legacy-number");
        vm.startPrank(admin);
        uint256 old = reserves.openReserveLossIncident(LossEventIds.CUSTODY_EVENT_NAMESPACE_START - 1, evidence);
        reserves.closeReserveLossIncident(old);
        vm.stopPrank();
        vm.prank(guardian);
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        assertEq(armId, 1);
        assertNotEq(incidentId, old);
    }
}
