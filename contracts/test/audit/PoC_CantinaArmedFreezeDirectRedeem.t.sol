// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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

        (uint256 quoted,) = controller.previewRedeem(100e18);
        assertEq(quoted, 100e6, "the armed protocol still quotes PAR to a direct holder");

        vm.prank(alice);
        uint256 got = controller.redeem(100e18, 0);
        assertEq(got, 100e6, "DIRECT REDEMPTION SETTLED AT PAR WHILE THE INTERLOCK WAS ARMED");
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

        // Alice reads the ReserveLossArmed event and leaves at par, in the arm window.
        vm.prank(alice);
        assertEq(controller.redeem(100e18, 0), 100e6, "alice exits whole");
        assertEq(controller.totalUSDfr(), 100e18, "alice is out");

        // The loss the Guardian was signalling now materialises: 50 USDC gone from custody.
        _createReserveShortfall(50e18);
        assertEq(reserves.idleCustodyShortfall(), 50e18);

        // Bob is now frozen out entirely -- `_requireCustodiedReserve` shuts the door behind alice.
        (uint256 bobGets,) = controller.previewRedeem(100e18);
        assertEq(bobGets, 0, "the door alice walked through is now shut");
        vm.prank(bob);
        vm.expectRevert();
        controller.redeem(100e18, 0);

        // Bob's remaining claim is 100e18 USDfr against 50e18 of recognised backing. Had the
        // interlock held alice too, the same 50e18 hole would have sat under 200e18 of supply.
        assertEq(reserves.recognizedBackingValue(), 50e18, "bob's cohort carries the whole hole");
    }
}
