// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @title PoC for the Cantina Managed question on `MintRedeemController._redeem` (line 594)
/// @notice Does `armReserveLossFreeze` close the direct redemption door? Measured, not argued.
contract PoC_CantinaArmedFreezeDirectRedeem is TokenLayerFixture {
    /// @notice REACHABILITY. With the interlock armed and NOTHING physically missing, the two
    ///         consumers named in ADR-0033 §5 are shut and the direct exit is wide open at par.
    function test_PoC_armedFreezeLeavesTheDirectExitOpenAtPar() public {
        _mintUSDfr(alice, 100e6);

        assertEq(reserves.idleCustodyShortfall(), 0, "precondition: nothing physically missing");
        assertFalse(reserves.reserveLossExitsLocked(), "precondition: interlock open");

        _armReserveLoss(1);

        // The shared interlock is ON. Queue settlement (RedemptionQueue.closeEpoch) and curator
        // withdrawals (CuratorModule.custodyFreezeActive) both read these and fail closed.
        assertTrue(reserves.reserveLossExitsLocked(), "queue settlement must be frozen");
        assertTrue(reserves.curatorWithdrawalsLocked(), "curator withdrawals must be frozen");
        assertTrue(reserves.custodyLossUnabsorbed(), "curator freeze predicate must be true");
        // ...and still nothing is physically missing, so `_requireCustodiedReserve` sees nothing.
        assertEq(reserves.idleCustodyShortfall(), 0, "arm is pre-physical by construction");

        // FIXED 2026-09-09. The direct door now shuts with the other two.
        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        controller.redeem(100e18, 0);
    }

    /// @notice THE GUARD IS NOT A PERMANENT FREEZE: opening the incident lifts it.
    /// @dev This is the property that made the predicate's second limb worth getting right. The
    ///      guard keys on `activeReserveLossIncidentId`, which only `ratifyAndOpen` sets, NOT on
    ///      the `incidentId` that `reserveLossArm` returns — that one is DERIVED
    ///      (`custodyEventId(armId)`) and is non-zero for any standing arm, so a guard keyed on it
    ///      could never fire at all. Asserted on the SELECTOR rather than on success, because once
    ///      the loss is physical `_requireCustodiedReserve` legitimately holds the door shut for
    ///      its own reasons; what must stop is THIS guard.
    function test_FIXED_openingTheIncidentLiftsTheArmFreeze() public {
        _mintUSDfr(alice, 100e6);
        _armReserveLoss(3);

        vm.prank(alice);
        (bool okBefore, bytes memory dataBefore) =
            address(controller).call(abi.encodeWithSignature("redeem(uint256,uint256)", uint256(100e18), uint256(0)));
        assertFalse(okBefore, "the armed window must refuse");
        assertEq(bytes4(dataBefore), IMintRedeemController.Controller_ReserveLossArmFreeze.selector, "armed freeze");

        // The signalled loss becomes physical and governance ratifies it.
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);

        vm.prank(alice);
        (bool okAfter, bytes memory dataAfter) =
            address(controller).call(abi.encodeWithSignature("redeem(uint256,uint256)", uint256(100e18), uint256(0)));
        if (!okAfter) {
            assertTrue(
                bytes4(dataAfter) != IMintRedeemController.Controller_ReserveLossArmFreeze.selector,
                "the ARM freeze must lift once the incident is open, whatever else refuses"
            );
        }
    }

    /// @notice MATERIALITY. The escape is not cosmetic. The holder who acted on the public
    ///         `ReserveLossArmed` event leaves whole; the holder who did not is frozen outright
    ///         the moment the signalled loss becomes physical.
    function test_PoC_theEscapeLeavesWhoeverStayedFrozen() public {
        _mintUSDfr(alice, 100e6);
        _mintUSDfr(bob, 100e6);
        assertEq(controller.totalUSDfr(), 200e18);
        assertEq(controller.backingValue(), 200e18);

        _armReserveLoss(2);

        // FIXED 2026-09-09. Alice can no longer read the ReserveLossArmed event and leave at par.
        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        controller.redeem(100e18, 0);
        assertEq(controller.totalUSDfr(), 200e18, "nobody escaped the arm window");

        // The loss the Guardian was signalling now materialises: 50 USDC gone from custody.
        _createReserveShortfall(50e18);
        assertEq(reserves.idleCustodyShortfall(), 50e18);

        // THE MATERIALITY, INVERTED. The same 50e18 hole now sits under the WHOLE 200e18 of supply
        // rather than under whoever was too slow, which is exactly what ADR-0033 section 5's
        // interlock is for. Both holders are frozen together by `_requireCustodiedReserve`.
        assertEq(reserves.recognizedBackingValue(), 150e18, "the hole is carried by the full cohort");
        vm.prank(bob);
        vm.expectRevert();
        controller.redeem(100e18, 0);
        vm.prank(alice);
        vm.expectRevert();
        controller.redeem(100e18, 0);
    }
}
