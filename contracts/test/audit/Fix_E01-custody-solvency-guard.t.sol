// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev AUDIT R4-01 / MA-1 — the custody-solvency guard on every USDC out-door.
///
/// The property under test is a single sentence: **no USDC leaves the ReserveManager while the
/// recorded idle ledger exceeds live custody.** `ReserveManager` has exactly two external USDC
/// out-doors — `recordDeployment` (the credit door, CREDIT_ROLE) and `_release` reached through
/// `releaseUSDC` (the exit door, CONTROLLER_ROLE). Both are gated by
/// `_requireIdleFullyCustodied`, which reverts `ReserveManager_IdleCustodyShortfall(recorded, live)`.
///
/// Why these tests are shaped the way they are (this is the load-bearing part): every amount
/// exercised below is chosen to be **within live custody**. That is deliberate. If the test asked
/// to move more than the contract physically holds, the ERC-20 transfer would revert on its own
/// and the test would pass with the guard deleted — proving nothing. By moving an amount the
/// contract *can* pay, the only thing standing between the caller and the cash is the guard, so
/// removing the guard turns each of these reverts into a success.
///
/// Covered here:
///   1. the credit door, independently;
///   2. the exit door, independently;
///   3. the property over both doors under bounded fuzzing;
///   4. the specific error selector and its `(recorded, live)` operands — the finding recorded
///      `ReserveManager_IdleCustodyShortfall` as declared-but-never-thrown, so asserting a bare
///      revert would not close it;
///   5. the second-order limb: recognition must write the recorded ledger down to live custody so
///      that recognition -> absorption *clears* the shortfall and reopens both doors, rather than
///      latching the protocol shut.
contract Fix_E01CustodySolvencyGuardTest is TokenLayerFixture {
    uint256 private constant FACILITY_ID = 4101;

    /// @dev Moves `units` of USDC out of the reserve's custody without touching the recorded
    ///      ledger — the on-chain signature of a custody loss (bridge failure, compromised
    ///      custodian, mis-swept treasury). Recorded stays high, live drops.
    function _loseCustody(uint256 units) private {
        vm.prank(address(reserves));
        usdc.transfer(borrower, units);
    }

    function _fundReserve(uint256 usdcUnits) private {
        _mintUSDfr(alice, usdcUnits);
    }

    // ─── 1. the credit door ──────────────────────────────────────────────────

    function test_creditDoorFreezesWhileCustodyIsShort() public {
        _fundReserve(100e6);
        _loseCustody(25e6);

        assertEq(reserves.idleUSDC(), 100e6, "recorded ledger is untouched by a custody loss");
        assertEq(usdc.balanceOf(address(reserves)), 75e6, "live custody is short");

        // 50e6 is comfortably payable out of the 75e6 actually held: without the guard this
        // transfer succeeds and turns known-missing cash into an illiquid facility.
        uint256 liveBefore = usdc.balanceOf(address(reserves));
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 75e6)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, 50e6);

        assertEq(usdc.balanceOf(address(reserves)), liveBefore, "no USDC may leave through the credit door");
        assertEq(reserves.deployedTo(FACILITY_ID), 0, "no facility may be funded from a short reserve");
    }

    // ─── 2. the exit door ────────────────────────────────────────────────────

    function test_exitDoorFreezesWhileCustodyIsShort() public {
        _fundReserve(100e6);
        _loseCustody(25e6);

        uint256 liveBefore = usdc.balanceOf(address(reserves));
        uint256 bobBefore = usdc.balanceOf(bob);

        // Again: 50e6 <= the 75e6 held, so the par exit is physically payable. Only the guard
        // stops the protocol paying a full-value exit out of a reserve it knows is short.
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 75e6)
        );
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 50e6);

        assertEq(usdc.balanceOf(address(reserves)), liveBefore, "no USDC may leave through the exit door");
        assertEq(usdc.balanceOf(bob), bobBefore, "no par exit may be paid from a short reserve");
    }

    /// @dev A one-unit shortfall is still a shortfall. Guards that compare with the wrong strictness
    ///      survive coarse fixtures; this pins the boundary at recorded == live + 1.
    function test_bothDoorsFreezeOnASingleMissingUnit() public {
        _fundReserve(100e6);
        _loseCustody(1);

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 100e6 - 1)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, 1e6);

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 100e6 - 1)
        );
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 1e6);

        assertEq(usdc.balanceOf(address(reserves)), 100e6 - 1, "custody untouched");
    }

    /// @dev The exact converse: with custody whole, both doors must still work. A guard that simply
    ///      bricked the reserve would pass every test above, so the negative case is required to
    ///      show the guard discriminates on the shortfall and not on the call itself.
    function test_bothDoorsOpenWhenCustodyIsWhole() public {
        _fundReserve(100e6);
        assertEq(reserves.idleCustodyShortfall(), 0, "precondition: custody is whole");

        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, 40e6);
        assertEq(reserves.deployedTo(FACILITY_ID), 40e18, "credit door open when fully custodied");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 10e6);
        assertEq(usdc.balanceOf(bob) - bobBefore, 10e6, "exit door open when fully custodied");
    }

    // ─── 3. the property, over both doors ────────────────────────────────────

    /// @dev Property: for every reachable (recorded, live) with recorded > live, and every amount
    ///      the contract could physically pay, both out-doors revert with the custody error and the
    ///      reserve's USDC balance is unchanged.
    function testFuzz_noUSDCLeavesWhileRecordedIdleExceedsLiveCustody(
        uint256 depositUnits,
        uint256 missingUnits,
        uint256 amountUnits
    ) public {
        depositUnits = bound(depositUnits, 2, 1_000_000e6);
        missingUnits = bound(missingUnits, 1, depositUnits - 1);
        _fundReserve(depositUnits);
        _loseCustody(missingUnits);

        uint256 recorded = reserves.idleUSDC();
        uint256 live = usdc.balanceOf(address(reserves));
        assertGt(recorded, live, "fixture must actually be short");

        // Only amounts the reserve could physically pay. Anything larger would revert inside the
        // ERC-20 regardless of the guard, and would not discriminate.
        amountUnits = bound(amountUnits, 1, live);

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, recorded, live)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, amountUnits);

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, recorded, live)
        );
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, amountUnits);

        assertEq(usdc.balanceOf(address(reserves)), live, "custody balance must be untouched by both attempts");
        assertEq(reserves.idleUSDC(), recorded, "recorded ledger must be untouched by both attempts");
        assertEq(reserves.deployedTo(FACILITY_ID), 0, "no principal may be recorded as deployed");
    }

    // ─── 5. the second-order limb: recognition must clear, not latch ─────────

    /// @dev The addendum recorded that the merged arm-bound absorption stopped writing the recorded
    ///      idle ledger down to live custody, so recognition -> absorption never cleared the
    ///      shortfall and the guard latched the protocol shut forever. This asserts the repaired
    ///      behaviour: after ratification the ledger equals live custody, the shortfall is zero,
    ///      and both doors reopen.
    function test_recognitionWritesLedgerDownToLiveCustodyAndReopensBothDoors() public {
        _fundReserve(100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        _armReserveLoss(4101);
        _loseCustody(25e6);
        assertEq(reserves.idleCustodyShortfall(), 25e18, "precondition: a recognized shortfall exists");

        _ratifyCurrentReserveLoss(25e18);

        // The limb itself.
        assertEq(reserves.idleUSDC(), 75e6, "absorption wrote the ledger down to live custody");
        assertEq(usdc.balanceOf(address(reserves)), 75e6, "live custody unchanged by recognition");
        assertEq(reserves.idleCustodyShortfall(), 0, "recognition must clear the shortfall, not latch it");
        (,, uint256 pending) = reserves.recognizedReserveLoss();
        assertEq(pending, 0, "cascade must not be bricked by recognition");

        // ...and the guard, being a predicate rather than a latch, must now let cash out again.
        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, 30e6);
        assertEq(reserves.deployedTo(FACILITY_ID), 30e18, "credit door reopens after absorption");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 20e6);
        assertEq(usdc.balanceOf(bob) - bobBefore, 20e6, "exit door reopens after absorption");
    }

    /// @dev The other clearing path: restoring the missing custody must also reopen the doors,
    ///      with no governance action at all.
    function test_restoringCustodyReopensBothDoors() public {
        _fundReserve(100e6);
        _loseCustody(25e6);

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 75e6)
        );
        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, 10e6);

        usdc.mint(address(reserves), 25e6);
        assertEq(reserves.idleCustodyShortfall(), 0, "custody restored");

        vm.prank(creditModule);
        reserves.recordDeployment(FACILITY_ID, borrower, 10e6);
        assertEq(reserves.deployedTo(FACILITY_ID), 10e18, "credit door reopens once custody is whole");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 10e6);
        assertEq(usdc.balanceOf(bob) - bobBefore, 10e6, "exit door reopens once custody is whole");
    }
}
