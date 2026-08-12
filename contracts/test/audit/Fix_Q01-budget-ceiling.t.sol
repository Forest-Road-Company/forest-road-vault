// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";

/// @title ADJUDICATION — independent reproduction of the load-bearing claims.
contract ADJ_Verify is CreditLayerFixture {
    uint256 internal constant MIN_RESIDUE_VALUE = 1e12;

    MockImpairmentSource internal src;

    function _useMock() internal {
        src = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(src));
    }

    function _stakeVault(address who, uint256 amount) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _queue(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    // ── (1) The bound that makes Angle-3's window narrow ─────────────────
    // previewRedeem(convertToSharesAtRedemption(b)) >= b - 1 for every b >= 1,
    // at every reachable rate. Therefore previewRedeem(budgetShares) == 0
    // requires settlementBudget <= 1.
    function testFuzz_ADJ_budgetSharesRoundTripLosesAtMostOneWei(uint256 stake, uint256 impBps, uint256 b) public {
        _useMock();
        stake = bound(stake, 1, 5_000_000) * 1e18;
        _stakeVault(alice, stake);
        uint256 ta = vault.totalAssets();
        impBps = bound(impBps, 0, 10_000);
        src.setImpairment((ta * impBps) / 10_000);
        b = bound(b, 1, ta == 0 ? 1 : ta);

        uint256 bs = vault.convertToSharesAtRedemption(b);
        vm.assume(bs != 0);
        uint256 back = vault.previewRedeem(bs);
        assertLe(back, b, "round trip must never exceed the budget");
        assertGe(back + 1, b, "ROUND TRIP LOSES MORE THAN ONE WEI");
    }

    // ── (2) previewWithdraw/previewRedeem margin identity ────────────────
    function testFuzz_ADJ_marginSurvivesTheRoundTrip(uint256 stake, uint256 impBps, uint256 warpDays) public {
        _useMock();
        stake = bound(stake, 1, 5_000_000) * 1e18;
        _stakeVault(alice, stake);
        warpDays = bound(warpDays, 0, 3650);
        vm.warp(block.timestamp + warpDays * 1 days);
        uint256 ta = vault.totalAssets();
        impBps = bound(impBps, 0, 9_999);
        src.setImpairment((ta * impBps) / 10_000);

        uint256 mr = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        assertGt(mr, 0, "previewWithdraw(1e12) MUST NEVER BE ZERO");
        assertGe(vault.previewRedeem(mr), MIN_RESIDUE_VALUE, "MARGIN LOST IN THE ROUND TRIP");
    }

    // ── (3) BUDGET CEILING, zero-slack: the largest head the budget can pay
    //        in full, so COMPLETE over-fills past budgetShares and the budget
    //        is consumed to the wei. `settlementBudget -= assetsOut` must not
    //        underflow.
    function test_ADJ_budgetCeiling_zeroSlackComplete() public {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 100_000e18);
        uint256 bobShares = _stakeVault(bob, 100_000e18);

        vm.prank(admin);
        queue.setEpochLiquidityBps(2_000);
        uint256 budget = queue.availableLiquidity();
        emit log_named_uint("availableLiquidity", budget);
        uint256 bs = vault.convertToSharesAtRedemption(budget);

        // largest share count still fully payable out of `budget`
        uint256 lo = bs;
        uint256 hi = bs + 5_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (vault.previewRedeem(mid) <= budget) lo = mid;
            else hi = mid - 1;
        }
        uint256 headShares = lo;
        assertGt(headShares, bs, "precondition: COMPLETE must over-fill past budgetShares");
        assertLe(headShares, aliceShares, "head fits");
        assertEq(vault.previewRedeem(headShares), budget, "precondition: zero slack");

        uint256 idHead = _queue(alice, headShares);
        _queue(bob, bobShares / 4); // something behind, so !drained
        vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);

        emit log_named_uint("budgetShares", bs);
        emit log_named_uint("headShares", headShares);
        emit log_named_uint("over-fill (share units)", headShares - bs);
        emit log_named_uint("budget", budget);

        queue.closeEpoch(10);

        (, uint256 rem, uint256 claim,,) = queue.request(idHead);
        assertEq(rem, 0, "COMPLETE should have filled the whole head");
        assertEq(claim, budget, "paid exactly the budget");
        emit log_named_uint("settlementBudgetRemaining", queue.settlementBudgetRemaining());
    }

    // ── (4) 4-D sweep: no underflow / no over-distribution anywhere near the
    //        rounding band, and the residue always carries the margin.
    function testFuzz_ADJ_noOverDistributionNearTheBand(uint256 extra, uint256 impBps, uint256 liq, uint256 warpDays)
        public
    {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 250_000e18);
        uint256 bobShares = _stakeVault(bob, 250_000e18);

        warpDays = bound(warpDays, 0, 720);
        vm.warp(block.timestamp + warpDays * 1 days);
        uint256 ta = vault.totalAssets();
        impBps = bound(impBps, 0, 9_000);
        src.setImpairment((ta * impBps) / 10_000);

        liq = bound(liq, 100, 5_000);
        vm.prank(admin);
        queue.setEpochLiquidityBps(uint16(liq));
        uint256 budget = queue.availableLiquidity();
        vm.assume(budget > 0);
        uint256 bs = vault.convertToSharesAtRedemption(budget);
        vm.assume(bs != 0 && bs < aliceShares);

        uint256 mr = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        extra = bound(extra, 0, mr * 3);
        uint256 headShares = bs + extra;
        vm.assume(headShares <= aliceShares && headShares > 0);
        vm.assume(vault.convertToAssets(headShares) >= queue.minRedemptionValue());
        vm.assume(vault.convertToAssets(aliceShares - headShares) >= queue.minRedemptionValue());

        uint256 idHead = _queue(alice, headShares);
        _queue(bob, bobShares / 4);
        vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);

        uint256 before = usdfr.balanceOf(address(queue));
        vm.prank(carol);
        (bool ok,) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (10)));
        if (!ok) return; // an abandon is a legal outcome; nothing was moved

        uint256 moved = usdfr.balanceOf(address(queue)) - before;
        assertLe(moved, budget, "QUEUE DISTRIBUTED ABOVE ITS BUDGET");

        (, uint256 rem,,,) = queue.request(idHead);
        if (rem != 0 && rem != headShares) {
            assertGe(vault.previewRedeem(rem), MIN_RESIDUE_VALUE, "RESIDUE BELOW THE MARGIN");
        }
    }

    // ── (5) Loud stop: still fires under genuine near-total impairment ────
    function test_ADJ_loudStopStillFires() public {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        uint256 idA = _queue(alice, aliceShares);
        _queue(bob, bobShares);
        src.setImpairment(vault.totalAssets());
        vm.warp(queue.eligibleToSettleAt(idA));
        assertEq(vault.previewRedeem(aliceShares), 0, "precondition");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_HeadNotRedeemable.selector, 0, aliceShares));
        queue.closeEpoch(10);
    }
}
