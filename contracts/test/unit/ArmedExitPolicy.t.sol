// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Isolated invalid-state checks for each custody-resolution predicate.
contract ArmResolutionStateProbe is ReserveManager {
    function injectCancelState(uint8 kind) external {
        bytes32 location = RESERVE_STORAGE_LOCATION;
        ReserveStorage storage native;
        assembly {
            native.slot := location
        }
        if (kind == 1) delete native.lossController;
        else if (kind == 2) native.recognizedSupplyReduction = 1;
        else if (kind == 3) native.reserveDeficit = 1;
        else if (kind == 4) native.activeReserveLossIncidentId = 124;
        else revert();
    }
}

/// @notice Approved pending-arm policy: junior support stays committed until resolution.
contract ArmedExitPolicyTest is CreditLayerFixture {
    uint256 private loan;
    uint256 private constant EXIT = 500_000e18;

    function _book(uint256 curatorCapital, uint256 backstopCapital) private {
        _mintUSDfrTo(alice, 1_000_000e18);
        _mintUSDfrTo(bob, 1_000_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, anchorCurator, true);
        if (curatorCapital != 0) _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, curatorCapital);
        if (backstopCapital != 0) {
            vm.prank(bob);
            usdfr.transfer(address(backstopMock), backstopCapital);
        }
        loan = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        _fundFacility(loan, 500_000e18);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(loan, 250_000e18, keccak256("credit mark"));
    }

    function _digest() private view returns (bytes32) {
        uint256[11] memory values;
        values[0] = usdfr.totalSupply();
        values[1] = usdfr.balanceOf(alice);
        values[2] = usdc.balanceOf(alice);
        values[3] = reserves.recognizedBackingValue();
        values[4] = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        values[5] = backstopMock.coverageReserve();
        values[6] = reserves.exitPrepaidAbsorption();
        values[7] = reserves.principalImpairmentOf(loan);
        values[8] = usdfr.balanceOf(address(vault));
        values[9] = usdc.balanceOf(address(reserves));
        values[10] = usdfr.balanceOf(address(defaultManager));
        return keccak256(abi.encode(values, defaultManager.impairmentRiskStateHash()));
    }

    function testFuzz_pendingArmPreservesBothJuniorLayers(uint64 units, bool useCurator, bool useBackstop) public {
        uint256 amount = bound(uint256(units), 1, 10_000e6) * 1e12;
        if (!useCurator && !useBackstop) useCurator = true;
        _book(useCurator ? amount : 0, useBackstop ? amount : 0);
        (uint256 armId,) = _armReserveLoss(31);
        bytes32 before_ = _digest();
        (uint256 quote, uint256 input) = controller.previewRedeem(EXIT);
        assertEq(quote, 0, "pending-arm advisory quote must be suspended");
        assertEq(input, 0);
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(EXIT, 0, block.timestamp);
        assertEq(_digest(), before_, "refusal must roll back the entire allocation");
        (uint256 stillArmed,,,) = reserves.reserveLossArm();
        assertEq(stillArmed, armId);
    }

    function test_discountedExitWithoutJuniorSupportWaitsForResolution() public {
        _book(0, 0);
        (uint256 armId,) = _armReserveLoss(32);
        bytes32 before_ = _digest();
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(EXIT, 0, block.timestamp);
        assertEq(_digest(), before_);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, keccak256("custody reconciled"));
        vm.prank(alice);
        uint256 paid = controller.redeem(EXIT, 0, block.timestamp);
        assertGt(paid, 0);
        assertLt(paid * 1e12, EXIT);
        assertEq(reserves.exitPrepaidAbsorption(), 0);
    }

    function test_falseAlarmResolutionRetainsCreditMarkAndRestoresNormalExit() public {
        _book(1_000e18, 2_000e18);
        (uint256 armId,) = _armReserveLoss(33);
        bytes32 before_ = _digest();
        bytes32 evidence = keccak256("custody reconciled; credit mark retained");
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.GuardianReserveLossArmsEnabled(false);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.UnratifiedReserveLossArmCancelled(armId, evidence, 250_000e18);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, evidence);
        assertEq(_digest(), before_, "cancellation must not change financial state");
        (uint256 active,,, bool enabled) = reserves.reserveLossArm();
        assertEq(active, 0);
        assertFalse(enabled);
        assertTrue(reserves.reserveLossExitsLocked(), "the credit deficit retains the reserve exit interlock");
        vm.prank(alice);
        uint256 paid = controller.redeem(EXIT, 0, block.timestamp);
        assertGt(paid, 0);
        assertLt(paid * 1e12, EXIT);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0);
        assertEq(backstopMock.coverageReserve(), 0);
        assertEq(reserves.principalImpairmentOf(loan), 250_000e18);
        vm.expectRevert(IReserveManager.ReserveManager_GuardianArmsDisabled.selector);
        vm.prank(guardian);
        reserves.armReserveLossFreeze(keccak256("second warning"));
    }

    function test_legacyIncidentRefusalPreservesJuniorProtection() public {
        _book(1_000e18, 2_000e18);
        (uint256 armId,) = _armReserveLoss(34);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        vm.prank(admin);
        reserves.openReserveLossIncident(123, keccak256("different incident"));
        bytes32 before_ = _digest();
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(EXIT, 0, block.timestamp);
        assertEq(_digest(), before_);
    }
}

/// @notice Governance resolution is restricted to an unused, objectively reconciled arm.
contract UnratifiedArmResolutionTest is TokenLayerFixture {
    bytes32 private constant EVIDENCE = keccak256("resolution evidence");

    function test_cancellationRequiresGovernance() public {
        (uint256 armId,) = _armReserveLoss(41);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        reserves.cancelUnratifiedArm(armId, EVIDENCE);
    }

    function test_cancellationRequiresEvidenceAndExactActiveArm() public {
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveArm.selector);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(1, EVIDENCE);
        (uint256 armId,) = _armReserveLoss(42);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroEvidenceHash.selector);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmMismatch.selector, armId, armId + 1));
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId + 1, EVIDENCE);
    }

    function test_cancellationRefusesPhysicalShortfall() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(43);
        _createReserveShortfall(1e18);
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, EVIDENCE);
    }

    function test_cancellationRefusesAnActiveOtherIncident() public {
        (uint256 armId,) = _armReserveLoss(44);
        // Production entry points refuse this combination. Retain the defensive check
        // against inconsistent historical storage through a test-only implementation.
        ArmResolutionStateProbe implementation = new ArmResolutionStateProbe();
        vm.prank(admin);
        reserves.upgradeToAndCall(address(implementation), abi.encodeCall(implementation.injectCancelState, (4)));
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, EVIDENCE);
    }

    function test_cancellationCannotReplaceSettlementOfItsOwnIncident() public {
        _mintUSDfr(alice, 100e6);
        (uint256 armId,) = _armReserveLoss(45);
        _createReserveShortfall(1e18);
        _ratifyCurrentReserveLoss(1e18);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyRatified.selector, armId));
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, EVIDENCE);
    }

    function testFuzz_cancellationRefusesInvalidCustodyState(uint8 kind) public {
        kind = uint8(bound(kind, 1, 3));
        (uint256 armId,) = _armReserveLoss(46);
        ArmResolutionStateProbe implementation = new ArmResolutionStateProbe();
        vm.prank(admin);
        reserves.upgradeToAndCall(address(implementation), abi.encodeCall(implementation.injectCancelState, (kind)));
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        vm.prank(admin);
        reserves.cancelUnratifiedArm(armId, EVIDENCE);
    }
}
