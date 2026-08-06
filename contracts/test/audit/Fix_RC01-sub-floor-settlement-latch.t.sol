// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev AUDIT FIX (RC-01). Regression guard for the absorbing state introduced by the
///      FRV-FS-05 sub-floor heartbeat guard.
///
///      `settlementDistributed` is cumulative across the chunks of one latched settlement,
///      while `settlementBudget` is snapshotted exactly once (only under `!settling`) and
///      thereafter only shrinks — so `distributed + budget` is pinned to that first
///      snapshot. The bare `maxRequests` chunk exit leaves `stopReason == 0`, which used to
///      skip the completion block entirely and COMMIT with `settling = true`. If that
///      commit happened while the whole snapshot sat below `minRedemptionValue`, no later
///      chunk could ever satisfy the guard, and because the abandon branch reverts, its own
///      `settling = false` was rolled back with it. `closeEpoch` then reverted forever:
///      refilling the treasury could not help (the budget is never re-snapshotted while
///      settling) and no other writer clears `settling`.
///
///      The fix evaluates the floor on EVERY exit, so a sub-floor chunk is rejected BEFORE
///      it commits. The settlement stays restartable.
contract FixRC01SubFloorSettlementLatchTest is CreditLayerFixture {
    function _stake(address who, uint256 amount18) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount18);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount18);
        shares = vault.deposit(amount18, who);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        IERC20Approve(address(vault)).approve(address(queue), shares);
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

    /// @dev A chunk that fully fills a head worth less than the floor and then stops on
    ///      `maxRequests` must NOT commit. Before the fix it latched and dead-ended the
    ///      queue permanently; now it reverts and leaves the settlement restartable.
    function test_RC01_subFloorChunkCannotCommitAndSettlementStaysRestartable() public {
        uint256 sharesA = _stake(alice, 5e18);
        uint256 sharesB = _stake(bob, 100_000e18);
        _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);

        _endEpoch();

        // Ordinary timelocked governance parameters: a small liquidity share puts the
        // one-time snapshot above A's value but below the raised floor.
        vm.startPrank(admin);
        queue.setEpochLiquidityBps(1);
        queue.setMinRedemptionValue(100e18);
        vm.stopPrank();

        uint256 snapshot = queue.availableLiquidity();
        assertGt(snapshot, 5e18, "precondition: the snapshot can fully fill A");
        assertLt(snapshot, 100e18, "precondition: the whole snapshot is below the floor");

        // The sub-floor chunk is rejected instead of latching.
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(1);

        // The settlement never committed, so it is restartable — this is the property
        // whose absence made the original defect permanent.
        assertFalse(queue.isSettling(), "no sub-floor settlement may commit");

        // Restoring liquidity now works. Under the defect this was provably impossible:
        // the budget was never re-snapshotted and the live re-cap could only shrink it.
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        queue.closeEpoch(10);

        (, uint256 remB, uint256 claimB,,) = queue.request(idB);
        assertGt(claimB, 0, "B settled once liquidity was restored");
        assertTrue(remB == 0 || queue.isSettling() || queue.currentEpoch() > 0, "settlement progressed");
    }

    /// @dev The fix must not over-block: a chunk that distributes at or above the floor and
    ///      stops on `maxRequests` still latches open for the next chunk, exactly as before.
    function test_RC01_atOrAboveFloorChunkStillLatchesNormally() public {
        uint256 sharesA = _stake(alice, 100_000e18);
        uint256 sharesB = _stake(bob, 100_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        uint256 idA = _request(alice, sharesA);
        _request(bob, sharesB);

        _endEpoch();

        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "an at-or-above-floor chunk still latches");
        (, uint256 remA,,,) = queue.request(idA);
        assertEq(remA, 0, "A fully filled in chunk 1");
    }
}
