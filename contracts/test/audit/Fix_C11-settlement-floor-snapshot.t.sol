// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

interface IERC20Approve2 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev AUDIT FIX (C-11). Residual on the RC-01 remediation, found by the round-9 audit.
///
///      RC-01 stopped a settlement COMMITTING while its maximum possible distribution was
///      already under the economic floor. It did not stop the floor MOVING underneath a
///      settlement that had already, legitimately, committed. Because `settlementBudget` is
///      captured once and can only shrink, raising `minRedemptionValue` mid-settlement makes
///      both guards permanently unsatisfiable — the same dead end, reached through a
///      governance setter instead of a chunk boundary.
///
///      The RC-01 regression test could not catch this: it sets the floor BEFORE settling,
///      and no invariant handler carries a governance selector.
///
///      The fix captures the floor alongside the budget when a settlement opens, so a live
///      settlement is judged against the parameters it opened under and a governance change
///      takes effect on the NEXT settlement.
contract FixC11SettlementFloorSnapshotTest is CreditLayerFixture {
    function _stake(address who, uint256 amount18) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount18);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount18);
        shares = vault.deposit(amount18, who);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        IERC20Approve2(address(vault)).approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    function _endEpoch() internal {
        uint256 target = uint256(queue.epochEndsAt()) + 1;
        if (queue.head() < queue.totalRequests()) {
            uint256 eligibleAt = queue.eligibleToSettleAt(queue.head());
            if (target < eligibleAt) target = eligibleAt;
        }
        vm.warp(target);
    }

    /// @dev Raising the floor while a settlement is latched must not wedge it.
    function test_C11_raisingTheFloorMidSettlementCannotWedgeCloseEpoch() public {
        // The floor's hard ceiling is 100e18, so the wedge only forms while the settlement's
        // whole distribution stays under that: a small head that fills fully, a large
        // follower that cannot, and a budget below the ceiling.
        uint256 sharesA = _stake(alice, 50e18);
        uint256 sharesB = _stake(bob, 100_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(6); // ≈60e18 of the ≈100,050e18 idle reserve
        _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);

        _endEpoch();

        uint256 budget = queue.availableLiquidity();
        assertGt(budget, 50e18, "precondition: the budget can fill A fully");
        assertLt(budget, 100e18, "precondition: the whole settlement stays under the ceiling");

        // Chunk 1 fills A fully and stops on maxRequests, latching the settlement open.
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "precondition: settlement latched open");

        // Governance now raises the floor far above anything this settlement can still
        // distribute. Pre-fix, both guards read the LIVE value and closeEpoch reverted forever.
        vm.prank(admin);
        queue.setMinRedemptionValue(100e18);

        // The live settlement is judged against the floor it opened under, so it completes.
        queue.closeEpoch(10);
        assertFalse(queue.isSettling(), "the latched settlement must still be able to finish");
        (,, uint256 claimB,,) = queue.request(idB);
        assertGt(claimB, 0, "B settled rather than being wedged behind a moved floor");
    }

    /// @dev The new floor must still bind — on the NEXT settlement, not retroactively.
    function test_C11_theRaisedFloorAppliesToTheFollowingSettlement() public {
        uint256 sharesA = _stake(alice, 100_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        _request(alice, sharesA);
        _endEpoch();
        queue.closeEpoch(10);
        assertFalse(queue.isSettling(), "first settlement completed");

        // A further request far larger than the liquidity available to it, so the head can
        // only fill PARTIALLY and the queue is not drained — the drained carve-out
        // deliberately lets a final tail settle regardless of the floor.
        uint256 sharesB = _stake(bob, 100_000e18);
        _request(bob, sharesB);
        vm.startPrank(admin);
        queue.setEpochLiquidityBps(1);
        queue.setMinRedemptionValue(100e18);
        vm.stopPrank();
        _endEpoch();

        assertLt(queue.availableLiquidity(), 100e18, "precondition: below the raised floor");
        // A fresh settlement captures the NEW floor, so the sub-floor settlement is refused
        // rather than committed — the RC-01 property, still intact under the snapshot.
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);
        assertFalse(queue.isSettling(), "no sub-floor settlement may commit");
    }
}
