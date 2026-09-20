// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {MockReserveLossAbsorber} from "../helpers/MockReserveLossAbsorber.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";

/// @dev Seeds each independent refusal condition through the production storage layout.
contract ReserveCounterpartyStateHarness is ReserveManager {
    function seed(uint8 kind, uint256 value) external {
        ReserveStorage storage s;
        assembly { s.slot := RESERVE_STORAGE_LOCATION }
        if (kind == 0) s.activeReserveLossArmId = value;
        else if (kind == 1) s.activeReserveLossIncidentId = value;
        else if (kind == 2) s.recognizedSupplyReduction = value;
        else if (kind == 3) s.reserveDeficit = value;
        else if (kind == 4) s.idleUSDCUnits = value;
        else if (kind == 10) ReserveAccrualStorageLib.state().modules.token = address(uint160(value));
        else revert("unknown fixture state");
    }
}

contract ReserveCounterpartyRegression is TokenLayerFixture {
    ReserveCounterpartyStateHarness private harness;
    address private candidate;

    function setUp() public override {
        super.setUp();
        address implementation = address(new ReserveCounterpartyStateHarness());
        vm.prank(admin);
        reserves.upgradeToAndCall(implementation, "");
        harness = ReserveCounterpartyStateHarness(address(reserves));
        candidate = address(new MockReserveLossAbsorber(controller, address(vault), address(reserves)));
    }

    function test_everyLossConditionRefusesAbsorberReplacement() public {
        for (uint8 kind; kind < 5; ++kind) {
            harness.seed(kind, 1);
            _refuseReplacement(IReserveManager.ReserveManager_ModuleRebindForbidden.selector);
            harness.seed(kind, 0);
        }
        vm.mockCall(address(controller), abi.encodeWithSignature("totalUSDfr()"), abi.encode(uint256(1)));
        vm.mockCall(address(controller), abi.encodeWithSignature("backingValue()"), abi.encode(uint256(0)));
        _refuseReplacement(IReserveManager.ReserveManager_ModuleRebindForbidden.selector);
        vm.clearMockedCalls();
        harness.seed(10, uint160(address(usdfr)));
        _refuseReplacement(ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector);
    }

    function test_healthyReplacementRequiresAdminAndEmitsBothAddresses() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)));
        reserves.setLossAbsorber(candidate);
        assertEq(reserves.lossAbsorber(), address(reserveLossAbsorber));
        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.LossAbsorberSet(address(reserveLossAbsorber), candidate);
        vm.prank(admin);
        reserves.setLossAbsorber(candidate);
        assertEq(reserves.lossAbsorber(), candidate);
    }

    function test_realArmRefusesReplacementUntilCancellation() public {
        bytes32 evidence = keccak256("counterparty replacement regression");
        vm.prank(guardian);
        (uint256 armId,) = reserves.armReserveLossFreeze(evidence);
        _refuseReplacement(IReserveManager.ReserveManager_ModuleRebindForbidden.selector);
        vm.prank(admin);
        reserves.cancelAndDisable(armId, evidence);
        vm.prank(admin);
        reserves.setLossAbsorber(candidate);
        assertEq(reserves.lossAbsorber(), candidate);
    }

    function _refuseReplacement(bytes4 reason) private {
        vm.prank(admin);
        vm.expectRevert(reason);
        reserves.setLossAbsorber(candidate);
        assertEq(reserves.lossAbsorber(), address(reserveLossAbsorber), "refusal changed the counterparty");
    }
}
