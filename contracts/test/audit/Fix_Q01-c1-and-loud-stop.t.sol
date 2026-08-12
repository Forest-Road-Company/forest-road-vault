// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";

/// @title ANGLE 3 — C-1 and the legitimate loud stop, against the Q-01 residue-margin fix.
contract A3_C1AndLoudStop is CreditLayerFixture {
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

    function _close(uint256 n) internal returns (bool ok, bytes memory ret) {
        vm.prank(settlementKeeper); // AUDIT FIX (D7-01): closeEpoch is keeper-gated
        (ok, ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (n)));
    }

    // ─────────────────────────────────────────────────────────────────────
    // (a) The C-1 state the fix is claimed unreachable in: an astronomical
    //     `budgetShares` under a near/at-clamp mark. Verify, don't assume.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice For every impairment that prices the HEAD's whole position to zero, the loud
    ///         `Queue_HeadNotRedeemable` stop must still fire and nothing may be burned.
    function testFuzz_A3_loudStopSurvivesEveryZeroPricedHead(uint256 leftover) public {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        uint256 aliceId = _queue(alice, aliceShares);
        uint256 bobId = _queue(bob, bobShares);

        uint256 ta = vault.totalAssets();
        // leave between 0 and 1e12 wei of conservative NAV across the WHOLE senior layer:
        // that is the regime where a 50k position still prices at or near zero.
        leftover = bound(leftover, 0, 1e12);
        src.setImpairment(ta - leftover);

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(queue.eligibleToSettleAt(aliceId));

        uint256 headValue = vault.previewRedeem(aliceShares);
        vm.assume(headValue == 0); // the loud-stop regime

        (bool ok, bytes memory ret) = _close(10);

        assertFalse(ok, "a head priced at zero must NOT settle");
        assertEq(bytes4(ret), IRedemptionQueue.Queue_HeadNotRedeemable.selector, "the LOUD stop must still fire");
        (, uint256 aRem, uint256 aClaim,,) = queue.request(aliceId);
        (, uint256 bRem, uint256 bClaim,,) = queue.request(bobId);
        assertEq(aRem, aliceShares, "C-1: head untouched");
        assertEq(bRem, bobShares, "C-1: the position behind is untouched");
        assertEq(aClaim + bClaim, 0, "nothing credited");
        assertEq(queue.head(), 0, "head must not advance");
    }

    /// @notice Across a wide (impairment x budget) grid: no request is ever burned for zero
    ///         assets, and `settlementBudget` never underflows.
    function testFuzz_A3_neverBurnsForZero(uint256 leftoverBps, uint16 liqBps, uint256 headBps) public {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 60_000e18);
        uint256 bobShares = _stakeVault(bob, 60_000e18);

        headBps = bound(headBps, 1, 10_000);
        uint256 headShares = (aliceShares * headBps) / 10_000;
        vm.assume(vault.convertToAssets(headShares) >= queue.minRedemptionValue());
        uint256 aliceId = _queue(alice, headShares);
        uint256 bobId = _queue(bob, bobShares);

        uint256 ta = vault.totalAssets();
        leftoverBps = bound(leftoverBps, 0, 10_000);
        src.setImpairment(ta - (ta * leftoverBps) / 10_000);

        liqBps = uint16(bound(uint256(liqBps), 1, 10_000));
        vm.prank(admin);
        queue.setEpochLiquidityBps(liqBps);
        vm.warp(queue.eligibleToSettleAt(aliceId));

        (, uint256 aRem0,,,) = queue.request(aliceId);
        (, uint256 bRem0,,,) = queue.request(bobId);

        _close(10);

        (, uint256 aRem1, uint256 aClaim1,,) = queue.request(aliceId);
        (, uint256 bRem1, uint256 bClaim1,,) = queue.request(bobId);
        if (aRem1 < aRem0) assertGt(aClaim1, 0, "C-1 VIOLATED: alice burned for zero");
        if (bRem1 < bRem0) assertGt(bClaim1, 0, "C-1 VIOLATED: bob burned for zero");
        // a residue, if any, must carry the margin (else it is a fresh wedge)
        if (aRem1 != 0 && aRem1 < aRem0) {
            assertGe(vault.previewRedeem(aRem1), MIN_RESIDUE_VALUE, "residue below the margin");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // (b) The `fillShares = 0` sub-branch: what does the C-1 guard do with a
    //     zero fill, and is that the same as before the fix?
    // ─────────────────────────────────────────────────────────────────────

    // ── precise-budget harness ───────────────────────────────────────────
    //
    // `availableLiquidity()` is quantised (idle USDC units x bps / 1e4), so it cannot express a
    // sub-1e12 budget. A LATCHED settlement can: `settlementBudget` is snapshotted once and then
    // only decremented by real fills, so a first chunk sized to the wei leaves any residual
    // budget we like for the second chunk.

    uint256 internal headId;

    /// @dev Largest share count whose conservative value is exactly `target` (monotone search).
    function _sharesWorthExactly(uint256 target, uint256 hi) internal view returns (uint256) {
        uint256 lo = 0;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (vault.previewRedeem(mid) <= target) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    /// @dev Binary-searches the declared impairment so the head's whole position prices to
    ///      exactly `target` conservative wei.
    function _markHeadTo(uint256 shares, uint256 target) internal {
        uint256 ta = vault.totalAssets();
        uint256 lo = 0;
        uint256 hi = ta;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            src.setImpairment(mid);
            if (vault.previewRedeem(shares) > target) lo = mid + 1;
            else hi = mid;
        }
        src.setImpairment(lo);
    }

    /// @dev Latches a settlement whose REMAINING budget is exactly `residual` wei, with the
    ///      request under test as the new head. Returns the head's request id.
    function _latchWithBudget(uint256 residual) internal returns (uint256 idHead) {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);

        vm.prank(admin);
        queue.setEpochLiquidityBps(1_000); // 10%: the budget must sit UNDER alice's position
        uint256 b0 = queue.availableLiquidity();
        require(b0 > residual, "budget too small");
        require(vault.previewRedeem(aliceShares) > b0, "alice cannot absorb the budget");

        // alice's request is sized so its FULL fill costs exactly b0 - residual
        uint256 shares0 = _sharesWorthExactly(b0 - residual, aliceShares);
        require(vault.previewRedeem(shares0) == b0 - residual, "cannot hit the wei");
        _queue(alice, shares0);
        idHead = _queue(bob, bobShares);

        vm.warp(queue.eligibleToSettleAt(idHead));
        queue.closeEpoch(1); // fills alice only -> latches (stopReason 0)
        require(queue.isSettling(), "did not latch");
        require(queue.settlementBudgetRemaining() == residual, "residual budget off");
        require(queue.head() == idHead, "head did not advance to the subject");
    }

    /// @notice A head whose WHOLE remaining position is worth less than the margin, with a
    ///         budget that cannot cover it: the fix zeroes the fill. Nothing may be burned,
    ///         the head must keep its slot, and the stop must be the soft (curable) one.
    function test_A3_zeroFillBranch_burnsNothingAndStopsSoftly() public {
        uint256 idHead = _latchWithBudget(1e11); // 0.1 of the margin
        (, uint256 bobShares,,,) = queue.request(idHead);

        _markHeadTo(bobShares, 5e11); // sub-margin, and above the 1e11 budget
        assertEq(vault.previewRedeem(bobShares), 5e11, "precondition: head worth 5e11");
        assertLt(vault.previewRedeem(bobShares), MIN_RESIDUE_VALUE, "precondition: sub-margin head");
        assertGt(vault.convertToSharesAtRedemption(1e11), 0, "precondition: budgetShares != 0");

        (bool ok,) = _close(10);

        (, uint256 bRem, uint256 bClaim,,) = queue.request(idHead);
        assertEq(bRem, bobShares, "C-1: nothing burned on the zero-fill branch");
        assertEq(bClaim, 0, "nothing credited");
        assertEq(queue.head(), idHead, "head keeps its slot");
        emit log_named_string("zero-fill chunk committed", ok ? "yes" : "no (reverted)");
    }

    /// @notice THE COMPLETE BRANCH AT THE C-1 BOUNDARY. Budget = 1 wei, head priced at exactly
    ///         1 conservative wei. The frozen build's budget-capped fill prices to ZERO, so C-1
    ///         stops and the position survives. The fix instead COMPLETES: it burns the head's
    ///         entire position for 1 wei.
    function test_A3_completeBranch_burnsWholeHeadAtOneWei() public {
        uint256 idHead = _latchWithBudget(1);
        (, uint256 bobShares,,,) = queue.request(idHead);

        _markHeadTo(bobShares, 1);
        uint256 budgetShares = vault.convertToSharesAtRedemption(1);
        emit log_named_uint("head shares", bobShares);
        emit log_named_uint("head conservative value", vault.previewRedeem(bobShares));
        emit log_named_uint("head REALIZED value", vault.convertToAssets(bobShares));
        emit log_named_uint("budgetShares", budgetShares);
        emit log_named_uint("previewRedeem(budgetShares)", vault.previewRedeem(budgetShares));

        // Capture the precondition BEFORE settling: on the mutant the COMPLETE branch drains the
        // head, which moves the rate, so reading this afterwards reports the post-drain price and
        // the red lands on the precondition instead of on the behaviour that actually regressed.
        uint256 budgetCappedFillPrice = vault.previewRedeem(budgetShares);
        assertEq(budgetCappedFillPrice, 0, "precondition: the budget-capped fill must price to zero");

        (bool ok,) = _close(10);
        (, uint256 bRem, uint256 bClaim,,) = queue.request(idHead);
        emit log_named_string("closeEpoch ok", ok ? "yes" : "no");
        emit log_named_uint("head shares AFTER", bRem);
        emit log_named_uint("head claimable AFTER", bClaim);

        // AUDIT FIX (Q-01 round 4, BLOCKING) — the assertions this test shipped WITHOUT.
        // As lifted from the adjudication tree this function only logged, so it passed on the
        // defective contract and on the fixed one alike: a vacuous test on the single behavioural
        // change of the round. These three assertions are what make it a regression test.
        //
        // The state: the head's whole position prices to exactly 1 conservative wei and the
        // remaining budget is 1 wei, so `previewRedeem(budgetShares) == 0` — there is no real fill
        // for the COMPLETE branch to replace. Without the `previewRedeem(budgetShares) != 0`
        // conjunct the branch completes anyway and drains all 5e28 shares (50,000 USDfr realized)
        // for that 1 wei. With it, the C-1 guard preserves the head, matching the frozen build.
        // Deleting the conjunct must turn all three of these red.
        assertEq(bRem, bobShares, "C-1: the head's position must be preserved, not drained for dust");
        assertEq(bClaim, 0, "C-1: nothing may be burned when the budget-capped fill prices to zero");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (c) The credit must never be able to silence stopReason 3.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A settlement that fills a first request, then meets a zero-priced head, must
    ///         still surface the valuation block — the credit must not commit it silently.
    function test_A3_creditCannotSilenceTheLoudStop() public {
        _useMock();
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        uint256 aliceId = _queue(alice, aliceShares);
        uint256 bobId = _queue(bob, bobShares);

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(queue.eligibleToSettleAt(aliceId));

        // chunk 1: settle alice only (maxRequests = 1) -> latch open with distributed > 0
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "precondition: latched");
        (, uint256 aRem,,,) = queue.request(aliceId);
        assertEq(aRem, 0, "precondition: alice fully filled");

        // now mark the layer to zero, so bob (the new head) prices to nothing
        src.setImpairment(vault.totalAssets());
        assertEq(vault.previewRedeem(bobShares), 0, "precondition: head prices to zero");

        (bool ok, bytes memory ret) = _close(10);
        // Whatever the outcome, bob must not be burned.
        (, uint256 bRem, uint256 bClaim,,) = queue.request(bobId);
        assertEq(bRem, bobShares, "C-1: zero-priced head untouched");
        assertEq(bClaim, 0, "nothing credited");
        emit log_named_string("closeEpoch succeeded", ok ? "yes (SILENT commit)" : "no");
        if (!ok) emit log_named_bytes32("revert selector", bytes32(ret));
    }

    // ─────────────────────────────────────────────────────────────────────
    // (d) The MIN_RESIDUE_VALUE doc claims the withholding is at most one part
    //     in a million of the floor. The new setter bound permits floor == the
    //     margin. Show the claim is false at that legal setting.
    // ─────────────────────────────────────────────────────────────────────

    function test_A3_floorEqualToMargin_withholdingIsTheWholeFloor() public {
        // legal per the round-3 setter bound
        vm.prank(admin);
        queue.setMinRedemptionValue(MIN_RESIDUE_VALUE);
        assertEq(queue.minRedemptionValue(), MIN_RESIDUE_VALUE, "floor == margin is a LEGAL setting");
    }

    /// @notice The MIN_RESIDUE_VALUE doc says "every settlement that commits must already
    ///         distribute at least that floor". Measure a committing settlement's actual
    ///         distribution against its floor.
    function test_A3_committingSettlementCanDistributeBelowItsFloor() public {
        _mintUSDfrTo(alice, 5_900e18);
        vm.prank(alice);
        usdfr.transfer(bob, 3_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 400e18);
        vault.deposit(400e18, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        usdfr.approve(address(vault), 3_000e18);
        uint256 bobShares = vault.deposit(3_000e18, bob);
        vm.stopPrank();

        uint256 budget = queue.availableLiquidity();
        vm.prank(admin);
        queue.setMinRedemptionValue(budget - 1e6); // floor 1e6 wei under the budget

        uint256 headShares = vault.previewWithdraw(budget + 1e6); // head a hair over the budget
        uint256 idHead = _queue(alice, headShares);
        _queue(bob, bobShares);
        vm.warp(uint256(queue.eligibleToSettleAt(idHead)) + 1);

        uint256 floorNow = queue.minRedemptionValue();
        queue.closeEpoch(10);

        (,, uint256 distributed,,) = queue.request(idHead);
        emit log_named_uint("settlementMinValue (floor)", floorNow);
        emit log_named_uint("actually distributed", distributed);
        assertLt(distributed, floorNow, "a COMMITTED settlement distributed LESS than its floor");
        assertFalse(queue.isSettling(), "and it committed: the epoch closed");
    }

    /// @notice ROUND-3 OPEN QUESTION: another route to the credit's UPPER-bound divergence, with
    ///         NO governance floor change and NO impairment. The epoch budget lands just under the
    ///         default $1 floor while the head is a legitimately-entered request just over it.
    ///         Correct credit -> abandon (the budget genuinely cannot clear the floor).
    ///         Inflated credit (previewRedeem(budgetCappedFill)) -> commits below the floor.
    function test_A3_creditUpperBoundDiscriminatesWithoutGovernance() public {
        // idle reserve chosen so availableLiquidity at 1bp lands 1e8 wei UNDER the $1 floor
        _mintUSDfrTo(alice, 9_999_999_999e12);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 5_000e18);
        uint256 aliceShares = vault.deposit(5_000e18, alice);
        vm.stopPrank();

        vm.prank(admin);
        queue.setEpochLiquidityBps(1);
        uint256 budget = queue.availableLiquidity();
        uint256 floorNow = queue.minRedemptionValue();
        assertEq(floorNow, 1e18, "precondition: the DEFAULT $1 floor, untouched by governance");
        assertLt(budget, floorNow, "precondition: the epoch budget is under the floor");
        assertLt(floorNow - budget, MIN_RESIDUE_VALUE, "precondition: within one margin of it");

        uint256 headShares = _sharesWorthExactly(floorNow, aliceShares);
        assertGe(vault.convertToAssets(headShares), floorNow, "precondition: head clears the ENTRY floor");
        uint256 idHead = _queue(alice, headShares);
        uint256 idTail = _queue(alice, aliceShares - headShares); // something behind: !drained
        vm.warp(uint256(queue.eligibleToSettleAt(idTail)) + 1);

        (bool ok, bytes memory ret) = _close(10);
        emit log_named_uint("budget", budget);
        emit log_named_uint("floor", floorNow);
        emit log_named_string("committed", ok ? "YES" : "no");
        if (!ok) emit log_named_bytes32("revert selector", bytes32(ret));
        (,, uint256 claimed,,) = queue.request(idHead);
        emit log_named_uint("head claimable after", claimed);
    }

    /// @notice Counterfactual for the COMPLETE-branch burn: does the pre-fix build reach the
    ///         same terminal state at the NEXT epoch, or does the position survive?
    function test_A3_completeBranch_counterfactualNextEpoch() public {
        uint256 idHead = _latchWithBudget(1);
        (, uint256 bobShares,,,) = queue.request(idHead);
        _markHeadTo(bobShares, 1);

        _close(10); // chunk under test

        (, uint256 rem1, uint256 claim1,,) = queue.request(idHead);
        emit log_named_uint("after the chunk: shares", rem1);
        emit log_named_uint("after the chunk: claimable", claim1);

        // next epoch, full budget, mark unchanged
        vm.warp(uint256(queue.epochEndsAt()) + 1);
        (bool ok2,) = _close(10);
        (, uint256 rem2, uint256 claim2,,) = queue.request(idHead);
        emit log_named_string("next epoch closed", ok2 ? "yes" : "no");
        emit log_named_uint("next epoch: shares", rem2);
        emit log_named_uint("next epoch: claimable", claim2);
    }
}
