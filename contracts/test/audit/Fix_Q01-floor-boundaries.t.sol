// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IVaultU {
    function previewWithdraw(uint256) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
}

/// @title Fix_Q01 — floor boundaries for the residue-preservation credit
///
/// @dev The Q-01 fix withholds up to `MIN_RESIDUE_VALUE` (1e12 wei = 1e-6 USDfr) from a partial
///      fill so the residue it leaves is never priced at zero. That withholding reduces
///      `settlementDistributed`, which is the exact quantity the abandon guard tests against
///      `settlementMinValue` - and that test is a CLIFF, not proportional. It REVERTS wholesale
///      rather than settling slightly less.
///
///      A first draft shipped without accounting for that. A dedicated attack round proved the
///      consequence: a settlement the frozen build COMMITS became a repeating `Queue_NoLiquidity`
///      refusal, freezing every request behind the head. The repair credits the withheld amount
///      back in the commit test: `distributed != 0 && distributed + withheld >= settlementMinValue`.
///
///      WHY THIS FILE IS BUILT THE WAY IT IS. My first attempt at these boundary tests used
///      generic scenarios (stake, queue, settle at various floors) and passed on ALL of them - it
///      also passed with the credit deleted, i.e. it was vacuous. The credit only matters inside a
///      1e-6 USDfr band where `settlementMinValue <= budget < headValue < settlementMinValue +
///      MIN_RESIDUE_VALUE`, and a generic scenario never lands there. So this file constructs that
///      band explicitly, following the attack PoC that first exhibited it.
///
///      TO PROVE THESE GUARDS CAN FAIL: delete `+ withheld` from the abandon guard in
///      `RedemptionQueue.closeEpoch`. `test_boundary_creditRescuesTheSettlementItWithheldFrom`
///      MUST fail. A boundary suite that survives that mutation is testing nothing.
contract FixQ01FloorBoundaries is CreditLayerFixture {
    uint256 internal constant MIN_RESIDUE_VALUE = 1e12; // must mirror RedemptionQueue
    uint256 internal constant MAX_MIN_REDEMPTION_VALUE = 100e18; // must mirror RedemptionQueue

    function _stake(address who, uint256 amount18) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdfr.approve(address(vault), amount18);
        shares = vault.deposit(amount18, who);
        vm.stopPrank();
    }

    function _queue(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        IERC20Min(address(vault)).approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    /// @dev Build the narrow band the credit governs, with the floor placed `floorGap` wei below
    ///      the epoch budget. Returns the head request id and the budget.
    function _armBand(uint256 floorGap) internal returns (uint256 idHead, uint256 budget) {
        _mintUSDfrTo(alice, 5_900e18);
        vm.prank(alice);
        usdfr.transfer(bob, 3_000e18);

        _stake(alice, 400e18);
        uint256 bobShares = _stake(bob, 3_000e18);

        budget = queue.availableLiquidity();
        require(budget <= MAX_MIN_REDEMPTION_VALUE, "budget must fit under the floor ceiling");
        require(budget > floorGap, "floor gap larger than the budget");

        vm.prank(admin);
        queue.setMinRedemptionValue(budget - floorGap);

        // Head worth a hair MORE than the budget, so the fill is budget-bound and the residue
        // lands inside the dead zone - which is what makes the fix's guard fire at all.
        uint256 headShares = IVaultU(address(vault)).previewWithdraw(budget + 1e6);
        idHead = _queue(alice, headShares);
        _queue(bob, bobShares); // a victim behind, so a wholesale revert has a visible cost
        vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // The load-bearing case: the credit must rescue exactly the settlement it withheld from.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Inside the band, the settlement COMMITS - it is not refused by its own withholding.
    /// @dev This is the test the first draft of the fix failed. `floorGap = 1e6` puts the floor
    ///      1e6 wei under the budget, so a settlement paying the full budget clears it while one
    ///      paying `budget - MIN_RESIDUE_VALUE` does not. Without the credit this reverts
    ///      `Queue_NoLiquidity` and everything behind the head is frozen.
    function test_boundary_creditRescuesTheSettlementItWithheldFrom() public {
        (uint256 idHead,) = _armBand(1e6);

        queue.closeEpoch(10);

        (, uint256 rem, uint256 claimable,,) = queue.request(idHead);
        assertGt(claimable, 0, "the head must have been paid: the credit did not rescue the commit");
        if (rem != 0) {
            assertGe(
                IVaultU(address(vault)).previewRedeem(rem),
                MIN_RESIDUE_VALUE,
                "residue left below the margin: it can decay into the dead zone"
            );
        }
    }

    /// @notice Well ABOVE the band the credit is irrelevant and behaviour is unchanged.
    /// @dev Pins that the credit is not silently relaxing the floor in ordinary states. With the
    ///      floor a whole USDfr under the budget, the settlement clears on its own merits.
    function test_boundary_farAboveTheBand_creditIsInert() public {
        (uint256 idHead,) = _armBand(1e18);

        queue.closeEpoch(10);

        (,, uint256 claimable,,) = queue.request(idHead);
        assertGt(claimable, 0, "an ordinary settlement well clear of the floor must commit");
    }

    /// @notice At the exact margin width the settlement still commits.
    /// @dev `floorGap == MIN_RESIDUE_VALUE` is the edge: the withholding is exactly the distance
    ///      to the floor. An off-by-one in the credit (`>` instead of `>=`) fails here and nowhere
    ///      else, which is the entire reason this case exists.
    function test_boundary_atExactlyTheMarginWidth() public {
        (uint256 idHead,) = _armBand(MIN_RESIDUE_VALUE);

        queue.closeEpoch(10);

        (,, uint256 claimable,,) = queue.request(idHead);
        assertGt(claimable, 0, "off-by-one at the exact margin width");
    }

    /// @notice One wei inside the margin - the tightest edge the credit governs.
    function test_boundary_oneWeiInsideTheMargin() public {
        (uint256 idHead,) = _armBand(MIN_RESIDUE_VALUE - 1);

        queue.closeEpoch(10);

        (,, uint256 claimable,,) = queue.request(idHead);
        assertGt(claimable, 0, "off-by-one one wei inside the margin");
    }

    // ─────────────────────────────────────────────────────────────────────
    // The `distributed != 0` conjunct - A-1 anti-DoS the credit must NOT relax.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A settlement distributing literally nothing still abandons, credit or not.
    /// @dev A-1 heartbeat protection: without it anyone resets the epoch clock by atomically
    ///      zeroing idle liquidity, starving the sole exit. The credit may rescue a settlement
    ///      that paid SOMETHING and fell just short; it must never rescue one that paid nothing.
    ///      If this fails, the credit has escaped the `distributed != 0` conjunct and A-1 reopens.
    function test_boundary_zeroDistributionStillAbandons() public {
        (uint256 idHead,) = _armBand(1e6);

        uint256 idle = reserves.idleReserve();
        if (idle != 0) {
            vm.prank(address(controller));
            reserves.releaseUSDC(address(0xdEaD), idle / 1e12);
        }
        assertEq(queue.availableLiquidity(), 0, "budget must be zero for this test to mean anything");

        vm.expectRevert();
        queue.closeEpoch(10);

        (, uint256 rem, uint256 claimable,,) = queue.request(idHead);
        assertGt(rem, 0, "nothing should have been filled");
        assertEq(claimable, 0, "nothing should have been paid");
        assertEq(queue.head(), idHead, "head must not advance on a zero-distribution settlement");
    }

    // ─────────────────────────────────────────────────────────────────────
    // The credit's UPPER bound - it must never exceed what was actually withheld.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A settlement can never commit on more credit than the fix actually withheld.
    /// @dev The credit exists to stop a DELIBERATE withholding from being the reason a settlement
    ///      misses its floor. It must not become a way to commit a settlement that genuinely
    ///      distributed too little - that would relax the A-1 anti-DoS floor, which is the one
    ///      thing the credit must never do.
    ///
    ///      Round 3 found this bound behaviourally live but pinned by NO test: mutating
    ///      `withheld = previewRedeem(budgetCappedFill) - previewRedeem(fillShares)` to
    ///      `withheld = previewRedeem(budgetCappedFill)` - an over-credit - survives the entire
    ///      non-fork suite. My earlier boundary tests prove the credit cannot be DELETED; nothing
    ///      proved it cannot be INFLATED. This closes that direction.
    ///
    ///      The assertion is the economic one rather than a peek at an internal: whatever the
    ///      settlement committed on, the head must have been paid at least
    ///      `settlementMinValue - MIN_RESIDUE_VALUE`. An over-credit commits a settlement that paid
    ///      materially less than that, so it fails here and only here.
    ///
    ///      TO PROVE THIS GUARD CAN FAIL: drop the `- $.vault.previewRedeem(fillShares)` term from
    ///      the `withheld` computation in `closeEpoch`. This test MUST fail.
    ///      WHY THE FLOOR IS RAISED AFTER ENTRY, rather than simply set high. My first attempt at
    ///      this test asserted on an ordinary in-band settlement and was VACUOUS — the inflated
    ///      credit survived it. The reason is structural and worth recording, because it bounds the
    ///      round-3 finding: the Q-01 branch fires only when the residue is under `minResidue`
    ///      (1e-6 USDfr), so the head is worth `budget + eps` with `eps < MIN_RESIDUE_VALUE`; and
    ///      `requestRedeem` refuses anything under `minRedemptionValue`, so the floor is pinned at
    ///      or below the head's value, i.e. at or below the budget. In that regime the CORRECT
    ///      credit already clears the floor, so inflating it changes nothing and no assertion can
    ///      see the difference.
    ///
    ///      The two credits diverge only when the floor exceeds what the settlement can distribute,
    ///      which entry alone cannot produce. Governance raising `minRedemptionValue` between entry
    ///      and settlement does — `settlementMinValue` is captured when the settlement OPENS
    ///      (the C-11 latch), not when the request was made. That is the discriminating state, and
    ///      it is a reachable one: the floor is a live timelocked dial.
    function test_boundary_creditNeverExceedsWhatWasWithheld() public {
        (uint256 idHead, uint256 budget) = _armBand(1e6);

        // Raise the floor ABOVE what this settlement can pay, but below twice it. A correct credit
        // (<= MIN_RESIDUE_VALUE) cannot bridge that gap and must abandon; an inflated credit
        // (the whole budget-capped fill) can, and would commit a settlement that distributed less
        // than its own economic floor — relaxing A-1, which the credit must never do.
        uint256 raised = budget + 1e17;
        if (raised > MAX_MIN_REDEMPTION_VALUE) raised = MAX_MIN_REDEMPTION_VALUE;
        require(raised > budget + MIN_RESIDUE_VALUE, "floor must exceed budget by more than the margin");
        vm.prank(admin);
        queue.setMinRedemptionValue(raised);

        vm.expectRevert();
        queue.closeEpoch(10);

        (,, uint256 claimable,,) = queue.request(idHead);
        assertEq(
            claimable, 0, "settlement committed on more credit than was withheld: the A-1 economic floor was relaxed"
        );
    }

    /// @notice A settlement whose head is paid FAR below the floor must not commit.
    /// @dev The complement of the test above, from the other side. Here the floor is placed well
    ///      above anything the budget can pay, so no legitimate credit can bridge the gap. An
    ///      over-credit implementation would commit anyway; the correct one refuses.
    function test_boundary_creditCannotBridgeAGapLargerThanTheMargin() public {
        _mintUSDfrTo(alice, 5_900e18);
        _stake(alice, 400e18);

        uint256 budget = queue.availableLiquidity();
        // Floor an entire USDfr above the budget: no withholding of 1e-6 USDfr can close that.
        vm.prank(admin);
        queue.setMinRedemptionValue(budget + 1e18 > MAX_MIN_REDEMPTION_VALUE ? MAX_MIN_REDEMPTION_VALUE : budget + 1e18);

        uint256 headShares = IVaultU(address(vault)).previewWithdraw(queue.minRedemptionValue() + 1e18);
        uint256 idHead = _queue(alice, headShares);
        vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);

        vm.expectRevert();
        queue.closeEpoch(10);

        (,, uint256 claimable,,) = queue.request(idHead);
        assertEq(claimable, 0, "nothing should have been paid on a gap the credit cannot bridge");
    }

    // ─────────────────────────────────────────────────────────────────────
    // The setter's deliberate hole at (0, MIN_RESIDUE_VALUE).
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The floor accepts 0 and `>= MIN_RESIDUE_VALUE`, and refuses strictly between.
    /// @dev Round 3 found the fix's safety rests on `minRedemptionValue >= MIN_RESIDUE_VALUE`, but
    ///      the setter bounded only the top. Raising the lower bound outright was NOT the right
    ///      repair: zero is a documented, deliberately supported configuration (the floor is
    ///      disableable, per the C-11 note on `settlementMinValue`) and three existing tests rely
    ///      on it, including the Q-01 cure sweep. So the accepted range has a hole, and this test
    ///      exists to stop someone closing it with a single `>=` and silently removing that
    ///      capability.
    function test_boundary_floorSetterRejectsOnlyTheUnsafeBand() public {
        vm.startPrank(admin);

        queue.setMinRedemptionValue(0); // floor disabled: legal
        assertEq(queue.minRedemptionValue(), 0);

        queue.setMinRedemptionValue(MIN_RESIDUE_VALUE); // exactly the margin: legal
        assertEq(queue.minRedemptionValue(), MIN_RESIDUE_VALUE);

        queue.setMinRedemptionValue(1e18); // the default: legal
        queue.setMinRedemptionValue(MAX_MIN_REDEMPTION_VALUE); // the ceiling: legal

        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setMinRedemptionValue(1); // inside the unsafe band

        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setMinRedemptionValue(MIN_RESIDUE_VALUE - 1); // top edge of the unsafe band

        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setMinRedemptionValue(MAX_MIN_REDEMPTION_VALUE + 1); // above the ceiling

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Floor extremes, on the configurable range.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A zero floor never refuses, and a ceiling floor refuses only for the right reason.
    /// @dev `setMinRedemptionValue` accepts 0 through `MAX_MIN_REDEMPTION_VALUE`. At 0 the abandon
    ///      guard reduces to `distributed != 0`. At the ceiling a small budget legitimately cannot
    ///      clear the floor - refusing is correct there - but it must never refuse with
    ///      `Queue_HeadNotRedeemable`, which would mean a zero-priced head, i.e. Q-01 returning.
    function test_boundary_floorExtremes() public {
        uint256[2] memory floors = [uint256(0), MAX_MIN_REDEMPTION_VALUE];

        for (uint256 i = 0; i < floors.length; i++) {
            uint256 snap = vm.snapshotState();

            _mintUSDfrTo(alice, 5_900e18);
            _stake(alice, 400e18);
            vm.prank(admin);
            queue.setMinRedemptionValue(floors[i]);

            // The head must clear the ENTRY floor as well as exceed the budget: at the ceiling
            // setting, `minRedemptionValue` is larger than the whole epoch budget, so a
            // budget-sized request is correctly rejected by `requestRedeem` before settlement is
            // ever reached. Size it above both.
            uint256 budget = queue.availableLiquidity();
            uint256 target = budget + 1e6 > floors[i] + 1e18 ? budget + 1e6 : floors[i] + 1e18;
            uint256 headShares = IVaultU(address(vault)).previewWithdraw(target);
            uint256 idHead = _queue(alice, headShares);
            vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);

            try queue.closeEpoch(10) {
                (, uint256 rem,,,) = queue.request(idHead);
                if (rem != 0) {
                    assertGt(
                        IVaultU(address(vault)).previewRedeem(rem),
                        0,
                        "Q-01 REGRESSION: residue priced to zero at this floor"
                    );
                }
            } catch (bytes memory err) {
                assertTrue(
                    bytes4(err) != IRedemptionQueue.Queue_HeadNotRedeemable.selector,
                    "Q-01 REGRESSION: head priced to zero at this floor"
                );
            }

            emit log_named_uint("floor tested (wei)", floors[i]);
            vm.revertToState(snap);
        }
    }
}
