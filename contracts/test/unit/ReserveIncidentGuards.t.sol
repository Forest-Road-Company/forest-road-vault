// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveManager} from "../../src/ReserveManager.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @notice Test-only invalid-state injection for defensive checks retained by the extraction.
/// @dev These setters do not establish that normal protocol entry points reach these states.
contract ReserveIncidentStateProbe is ReserveManager {
    function injectDefensiveState(uint8 kind) external {
        bytes32 location = RESERVE_STORAGE_LOCATION;
        ReserveStorage storage native;
        assembly {
            native.slot := location
        }
        if (kind == 1) {
            delete native.lossController;
        } else if (kind == 2) {
            native.recognizedSupplyReduction = 1;
        } else if (kind == 3) {
            native.nextReserveLossArmId = (uint256(1) << 255) - 1;
        } else if (kind == 4) {
            // Model a legacy incident without an active arm; the current arm lifecycle
            // cannot reach this shape through the legacy closer.
            native.activeReserveLossArmId = 0;
            native.activeReserveLossArmEvidenceHash = bytes32(0);
        } else if (kind == 5) {
            native.activeReserveLossIncidentId = LossEventIds.custodyEventId(9);
        } else {
            revert();
        }
    }
}

contract ReserveIncidentGuardsTest is TokenLayerFixture {
    function test_openIncidentRefusesAnExistingActiveIncident() public {
        vm.prank(admin);
        uint256 id = reserves.openReserveLossIncident(1, keccak256("first"));
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyActive.selector, id));
        vm.prank(admin);
        reserves.openReserveLossIncident(2, keccak256("second"));
    }

    function test_closeIncidentRefusesWhenNoneIsActive() public {
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveIncident.selector);
        vm.prank(admin);
        reserves.closeReserveLossIncident(1);
    }

    function test_cancelRefusesWhenNoArmExists() public {
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveArm.selector);
        vm.prank(admin);
        reserves.cancelAndDisable(1, keccak256("no-arm"));
    }

    function test_cancelRefusesIndependentPrincipalImpairment() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 100e6);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(1, 1e18, keccak256("mark"));
        (uint256 armId,) = _armReserveLoss(1);
        assertEq(reserves.reserveDeficit(), 0);
        assertGt(controller.totalUSDfr(), controller.backingValue());
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        vm.prank(admin);
        reserves.cancelAndDisable(armId, keccak256("impaired"));
    }

    function test_resolveDeficitRequiresClosedIncidentAndActualRestoredBacking() public {
        (, uint256 incidentId) = _loss();
        _inject(4); // Historical legacy incident, explicitly constructed for this guard.
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyActive.selector, incidentId)
        );
        vm.prank(admin);
        reserves.resolveReserveDeficit(keccak256("still-open"));
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_DeficitStillExists.selector, 10e18, 10e18)
        );
        vm.prank(admin);
        reserves.resolveReserveDeficit(keccak256("unfunded"));
        vm.startPrank(bob);
        usdc.approve(address(reserves), 10e6);
        reserves.recapitalize(10e6);
        vm.stopPrank();
        bytes32 evidence = keccak256("funded");
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.ReserveDeficitResolved(10e18, evidence);
        vm.prank(admin);
        reserves.resolveReserveDeficit(evidence);
        assertEq(reserves.reserveDeficit(), 0);
    }

    function test_finalizeRefusesAnIncidentFromAnotherArm() public {
        (uint256 armId, uint256 expectedIncident) = _armReserveLoss(1);
        _inject(5); // Production legacy open now refuses while an arm exists.
        uint256 differentIncident = LossEventIds.custodyEventId(9);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_IncidentMismatch.selector, differentIncident, expectedIncident
            )
        );
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("wrong-incident"));
    }

    function test_finalizeRefusesANewPhysicalShortfall() public {
        (uint256 armId,) = _loss();
        _createReserveShortfall(1e18);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_LiveShortfallExists.selector, 1e6));
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("new-shortfall"));
    }

    function test_injectedRecognizedLossPreventsFinalization() public {
        (uint256 armId,) = _loss();
        _inject(2);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_RecognizedLossOutstanding.selector, 1));
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("recognized"));
    }

    function test_injectedMissingControllerRefusesFinalization() public {
        (uint256 armId,) = _loss();
        _inject(1);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(0))
        );
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("no-controller"));
    }

    function test_injectedMissingControllerRefusesDeficitResolution() public {
        (, uint256 incidentId) = _loss();
        _inject(4); // Historical legacy incident, explicitly constructed for this guard.
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        _inject(1);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(0))
        );
        vm.prank(admin);
        reserves.resolveReserveDeficit(keccak256("no-controller"));
    }

    function test_injectedExhaustedArmIdentityRefusesNewArm() public {
        _inject(3);
        vm.expectRevert(IReserveManager.ReserveManager_ArmIdExhausted.selector);
        vm.prank(guardian);
        reserves.armReserveLossFreeze(keccak256("exhausted"));
    }

    function _loss() private returns (uint256 armId, uint256 incidentId) {
        _mintUSDfr(alice, 100e6);
        (armId, incidentId) = _armReserveLoss(1);
        _createReserveShortfall(10e18);
        _ratifyCurrentReserveLoss(10e18);
        assertEq(reserves.reserveDeficit(), 10e18);
    }

    function _inject(uint8 kind) private {
        ReserveIncidentStateProbe implementation = new ReserveIncidentStateProbe();
        vm.prank(admin);
        reserves.upgradeToAndCall(address(implementation), bytes(""));
        ReserveIncidentStateProbe(address(reserves)).injectDefensiveState(kind);
    }
}
