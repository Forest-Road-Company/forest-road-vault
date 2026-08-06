// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";

/// @title AUDIT FINDING C-1 (CRITICAL) — queue settlement burned whole positions for zero USDfr
/// @notice Regression suite for the settlement value-guard in `RedemptionQueue.closeEpoch`.
///
///         THE ORIGINAL DEFECT: `sUSDfr.redemptionTotalAssets()` clamps to 0 once the declared
///         senior impairment reaches the vault's realized assets. `convertToSharesAtRedemption`
///         divides by `redemptionTotalAssets() + 1`, so at the clamp the settlement's
///         `budgetShares` became ASTRONOMICALLY LARGE rather than zero — the `budgetShares == 0`
///         exhaustion guard never fired. `fillShares` therefore took the head request's ENTIRE
///         position, `previewRedeem` of it was 0, and `vault.redeem` burned the shares for zero
///         USDfr. `settlementBudget -= 0` left the throttle inert, the head advanced, and the
///         loop wiped every following request too. `drained` ended true so the abandon guard was
///         bypassed and the epoch closed normally; with no cancel path (ADR-0018) the loss was
///         total and permanent. Any address could trigger it — `closeEpoch` is permissionless.
///
///         THE FIX: the fill's VALUE is checked before any state is mutated. A fill worth zero
///         assets is never taken; the request stays QUEUED and settles later at a real price.
contract Fix_C01_QueueZeroValueFillTest is CreditLayerFixture {
    // ── helpers ──────────────────────────────────────────────────────────

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

    function _defaulted(uint256 principal) internal returns (uint256 id) {
        id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    /// @dev Calls the PERMISSIONLESS `closeEpoch` as a non-KYC bystander via a low-level call,
    ///      so the test observes the resulting STATE in both the fixed and the unfixed world
    ///      (the unfixed contract does not revert here — it silently burns).
    function _tryCloseEpochAsBystander() internal returns (bool ok, bytes memory ret) {
        vm.prank(carol); // carol is deliberately NOT KYC-allowed
        (ok, ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (10)));
    }

    /// @dev Strips the 4-byte selector off revert data so the custom error's args can be decoded.
    function _body(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; ++i) {
            out[i - 4] = ret[i];
        }
    }

    /// @dev Swaps the impairment source for a directly-settable mock, so a test can pin an exact
    ///      conservative mark instead of steering a whole default lifecycle to approximate one.
    function _useMockImpairment() internal returns (MockImpairmentSource src) {
        src = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(src));
    }

    // ── C-1 REMEDIATION (owner-approved 2026-07-22): the $1 ENTRY FLOOR, not deferral ──
    //
    // DESIGN NOTE. These two tests replace the former deferral-behaviour tests
    // (`test_C1R_worthlessDustHead_doesNotBlockTheValuablePositionBehindIt` and
    // `test_C1R_permanence_realizedSeniorLossDoesNotWedgeTheQueueForever`). The wave-1 remediation
    // handled a sub-wei HEAD by DEFERRING it — requeuing it intact at the tail so the valuable
    // position behind it could settle in the same call. That mechanism (and its `RequestDeferred`
    // event / `_deferHead` helpers) was removed on 2026-07-22 in favour of an owner-approved
    // `minRedemptionValue` ENTRY FLOOR (default $1): dust is barred AT THE SOURCE rather than
    // shuffled at settlement, so the dust-wedge is unreachable and settlement stays strict-FIFO,
    // stop-and-wait — no reordering, no array growth, no joiner-stranding edge cases. No fund loss
    // in either design: the C-1 CRITICAL (never burn a position that is worth something) is
    // preserved by the unchanged `assetsOut == 0` value-guard in `closeEpoch`. The two tests below
    // pin the NEW protection in place of the retired deferral behaviour.

    /// @notice ENTRY FLOOR — THE NEW ANTI-DUST PROTECTION (replaces the deferral test). A request
    ///         worth less than `minRedemptionValue` ($1 default) at the REALIZED rate is rejected
    ///         with `Queue_BelowMinRedemption` (exact value/minimum); a request worth >= $1 is
    ///         admitted. Barring dust at entry is what makes the sub-wei head — and therefore the
    ///         old dust-wedge — unreachable under normal operation.
    function test_C1R_entryFloor_barsSubDollarDustAndAdmitsRealRequests() public {
        _stakeVault(alice, 400_000e18);
        uint256 min = queue.minRedemptionValue();
        assertEq(min, 1e18, "precondition: the default $1 floor is active");

        vm.startPrank(alice);
        vault.approve(address(queue), type(uint256).max);

        // (a) a pure-dust request — 1 share, worth 0 under the offset-6 vault — is barred.
        assertEq(vault.convertToAssets(1), 0, "precondition: 1 share prices to zero");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, 0, min));
        queue.requestRedeem(1);

        // (b) a sub-$1 request — strictly positive but below the floor — is barred, its exact
        //     realized value reported in the error.
        uint256 dustShares = vault.convertToShares(min - 1);
        uint256 dustValue = vault.convertToAssets(dustShares);
        assertGt(dustValue, 0, "precondition: strictly positive value");
        assertLt(dustValue, min, "precondition: strictly below $1");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, dustValue, min));
        queue.requestRedeem(dustShares);

        // (c) a request worth >= $1 is admitted and takes its FIFO slot.
        uint256 okShares = vault.convertToShares(2 * min);
        assertGe(vault.convertToAssets(okShares), min, "precondition: at/above the floor");
        uint256 id = queue.requestRedeem(okShares);
        vm.stopPrank();
        assertEq(id, 0, "the admissible request entered");
        (, uint256 remaining,,,) = queue.request(id);
        assertEq(remaining, okShares, "its shares are in custody: nothing burned, nothing deferred");
        assertEq(queue.totalRequests(), 1, "exactly one request exists: no deferral slot was appended");
    }

    /// @notice DUST-WEDGE UNREACHABLE (replaces the permanence/deferral test). With the $1 entry
    ///         floor you cannot construct the old wedge — a sub-wei head sitting in front of a
    ///         payable position — because reaching a sub-wei head requires marking the WHOLE senior
    ///         layer below a wei, at which point every $1+ position is ALSO sub-wei and stopping the
    ///         queue is correct. This proves both halves: (1) the sub-wei head cannot enter, and
    ///         (2) the only state that reaches one — a catastrophic full mark — stops LOUDLY with
    ///         `Queue_HeadNotRedeemable`, burns nothing, and CURES when the mark lifts.
    ///         (The realized-loss and declared-default variants of the loud-stop are covered by
    ///         `test_C1_totalSeniorMark_doesNotBurnQueuedPositionsForZero` and
    ///         `test_C1_queuedHolderIsNotExpropriatedByAStayerWhenTheMarkIsCured`.)
    function test_C1R_dustWedgeUnreachable_catastrophicMarkStopsLoudlyThenCures() public {
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        uint256 aliceId = _queue(alice, aliceShares);
        uint256 bobId = _queue(bob, bobShares);

        // (1) THE WEDGE IS BARRED AT THE SOURCE. There is no way to insert a sub-wei dust head in
        //     front of alice/bob: a sub-$1 request is refused entry, so it can never take the head.
        uint256 min = queue.minRedemptionValue();
        vm.startPrank(alice);
        vault.approve(address(queue), type(uint256).max);
        uint256 dustShares = vault.convertToShares(min - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRedemptionQueue.Queue_BelowMinRedemption.selector, vault.convertToAssets(dustShares), min
            )
        );
        queue.requestRedeem(dustShares);
        vm.stopPrank();

        // (2) The ONLY way to a sub-wei head is a catastrophic mark of the WHOLE senior layer. Mark
        //     it below a wei directly: a mock impairment pinned at the vault's whole realized assets
        //     clamps the conservative exit NAV to zero, so EVERY queued position prices to zero —
        //     there is no dust-vs-payable split to wedge.
        MockImpairmentSource src = _useMockImpairment();
        src.setImpairment(vault.totalAssets());
        assertEq(vault.redemptionTotalAssets(), 0, "precondition: the whole senior layer prices to zero");
        assertEq(vault.previewRedeem(aliceShares), 0, "precondition: alice's $50k position is now sub-wei");
        assertEq(vault.previewRedeem(bobShares), 0, "precondition: so is bob's - no payable position exists");

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(queue.eligibleToSettleAt(aliceId));
        assertGt(queue.availableLiquidity(), 0, "precondition: liquidity is NOT the blocker");

        uint256 epochBefore = queue.currentEpoch();
        uint64 endsAtBefore = queue.epochEndsAt();

        // Settlement STOPS LOUDLY — nothing is payable to ANY holder — and burns nothing.
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_HeadNotRedeemable.selector, aliceId, aliceShares));
        queue.closeEpoch(10);

        {
            (, uint256 aRem, uint256 aClaim,,) = queue.request(aliceId);
            (, uint256 bRem, uint256 bClaim,,) = queue.request(bobId);
            assertEq(aRem, aliceShares, "nothing burned at the catastrophic mark (head)");
            assertEq(bRem, bobShares, "nothing burned (position behind the head)");
            assertEq(aClaim, 0, "no assets fabricated");
            assertEq(bClaim, 0, "no assets fabricated");
        }
        assertEq(queue.head(), aliceId, "the head does not advance over an unredeemable front");
        assertEq(queue.totalQueuedShares(), aliceShares + bobShares, "custody intact");
        assertEq(vault.balanceOf(address(queue)), aliceShares + bobShares, "no shares burned");
        assertEq(queue.currentEpoch(), epochBefore, "the epoch is not consumed by a nil settlement");
        assertEq(queue.epochEndsAt(), endsAtBefore, "the heartbeat window is not burned");
        assertFalse(queue.isSettling(), "the latched settlement released");
        // The block is OBSERVABLE off-chain without sending a transaction (prime directive 4).
        {
            (uint256 vId, uint256 vHeadShares, uint256 vHeadValue, uint256 vBookValue) = queue.headValuation();
            assertEq(vId, aliceId, "headValuation names the head");
            assertEq(vHeadShares, aliceShares, "headValuation reports its shares");
            assertEq(vHeadValue, 0, "headValuation prices the head at zero");
            assertEq(vBookValue, 0, "and the whole queued book at zero: nothing is payable to anyone");
        }

        // (3) IT CURES. Lift the mark; the same positions settle at the restored price — nothing
        //     was lost while the queue was stopped.
        src.setImpairment(0);
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "the mark is cured: exit NAV restored");
        queue.closeEpoch(10);

        (, uint256 aliceRemaining, uint256 aliceClaimable,,) = queue.request(aliceId);
        assertEq(aliceRemaining, 0, "alice settles in full once the mark cures");
        assertGt(aliceClaimable, 0, "and is paid the restored value of her position");
        assertEq(queue.currentEpoch(), epochBefore + 1, "the epoch advances on the successful settlement");
    }

    /// @notice THE OTHER TERMINAL BRANCH, and the R2-I-01 budget-capped case in one. The first
    ///         request fills POSITIVELY and leaves exactly 1 wei of settlement budget; the next
    ///         head is worth real money but 1 wei cannot buy a nonzero slice of it. That is the
    ///         BUDGET-blocked cause, which must still `break` (the head keeps its FIFO place and
    ///         settles next epoch) — it must NOT be mistaken for the worthless-head case and it
    ///         must NOT revert, because value was distributed.
    function test_C1R_budgetCappedZeroValueFill_stopsWithoutDeferringOrReverting() public {
        _stakeVault(alice, 400_000e18);
        uint256 bobShares = _stakeVault(bob, 100_000e18);
        // REACHABILITY NOTE (measured): with an EXACTLY 1:1 vault the residual is unreachable —
        // `previewRedeem(convertToSharesAtRedemption(b)) == b` for every b >= 1, because the
        // share/asset ratio is exactly the 1e6 decimals offset and the two roundings cancel. It
        // takes a rate that is not a whole multiple of the offset, which any nonzero impairment
        // (here the smallest possible, ONE WEI) produces.
        MockImpairmentSource src = _useMockImpairment();
        src.setImpairment(1);

        // 50% of stable liquidity, so the budget lands strictly INSIDE alice's position and the
        // partial/residual arithmetic below is reachable.
        vm.prank(admin);
        queue.setEpochLiquidityBps(5_000);
        uint256 budget = queue.availableLiquidity();
        assertGt(budget, 1, "precondition: a real budget");

        // Size alice's request so it consumes the budget to within EXACTLY one wei.
        // `previewWithdraw` ceils, so this is the SMALLEST share count worth `budget - 1`.
        uint256 aliceShares = vault.previewWithdraw(budget - 1);
        assertEq(vault.previewRedeem(aliceShares), budget - 1, "precondition: alice is worth the budget less a wei");
        uint256 aliceId = _queue(alice, aliceShares);
        uint256 bobId = _queue(bob, bobShares);

        uint256 epochBefore = queue.currentEpoch();
        vm.warp(queue.eligibleToSettleAt(aliceId));
        assertEq(queue.availableLiquidity(), budget, "precondition: the budget did not drift");
        // The 1-wei residual budget buys a nonzero share count that is worth ZERO assets — the
        // exact R2-I-01 dust tail the value-guard closes.
        assertGt(vault.convertToSharesAtRedemption(1), 0, "precondition: a 1-wei budget buys shares");
        assertEq(vault.previewRedeem(vault.convertToSharesAtRedemption(1)), 0, "precondition: worth zero assets");

        queue.closeEpoch(10);

        (, uint256 aliceRemaining, uint256 aliceClaimable,,) = queue.request(aliceId);
        assertEq(aliceRemaining, 0, "alice filled in full");
        assertEq(aliceClaimable, budget - 1, "for the whole budget bar the residual wei");
        // bob is BUDGET-blocked, not deferred: he keeps his FIFO place and is untouched.
        (, uint256 bobRemaining, uint256 bobClaimable,,) = queue.request(bobId);
        assertEq(bobRemaining, bobShares, "R2-I-01: nothing is burned for the residual wei");
        assertEq(bobClaimable, 0, "and nothing is credited");
        assertEq(queue.head(), bobId, "bob KEEPS THE HEAD: a budget block is not a deferral");
        assertEq(queue.totalRequests(), 2, "no slot was appended: no deferral happened");
        // A settlement that distributed value closes the epoch normally (the A-1 abandon guard
        // deliberately does not fire) — the other terminal branch of the guard.
        assertEq(queue.currentEpoch(), epochBefore + 1, "the epoch closes normally after positive fills");
        assertFalse(queue.isSettling(), "settlement released");
    }

    /// @notice ADR-0022 PRICING RESIDUAL — CHARACTERIZATION, NOT A FIX. Reviewer-required. The
    ///         C-1 guard triggers only at EXACTLY zero, so one wei above the clamp a whole
    ///         position is still settled for effectively nothing. This pins the MEASURED
    ///         behaviour so it is an explicit, reviewed residual rather than an incidental one.
    /// @dev OPEN ITEM FOR FOREST ROAD / THE ECONOMIC REVIEWER, not a defect this fix closes:
    ///      whether the queue should refuse fills that are grossly underpriced (not merely
    ///      zero-priced) is an ADR-0022 pricing decision, and widening the guard would itself be
    ///      a fresh DoS on the sole exit path. Recorded in STATE.md. The numbers asserted below
    ///      are measurements, and any change to them is a deliberate re-pricing.
    function test_C1R_residual_nearClampStillDrainsPositionsForDust_ADR0022_PRICING_DECISION() public {
        MockImpairmentSource src = _useMockImpairment();
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        assertEq(aliceShares, bobShares, "precondition: two equal queued positions");
        uint256 aliceId = _queue(alice, aliceShares);
        uint256 bobId = _queue(bob, bobShares);

        // one billion wei (1e-9 USDfr) of value left across the ENTIRE senior layer
        src.setImpairment(vault.totalAssets() - 1e9);
        assertEq(vault.redemptionTotalAssets(), 1e9, "precondition: 1e9 wei of conservative NAV remains");

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(queue.eligibleToSettleAt(aliceId));
        queue.closeEpoch(10);

        (, uint256 aliceRemaining, uint256 aliceClaimable,,) = queue.request(aliceId);
        (, uint256 bobRemaining, uint256 bobClaimable,,) = queue.request(bobId);
        // MEASURED: the guard does NOT fire — both 50,000e18 positions are settled in full for
        // 5e8 wei each, i.e. a recovery of ~1e-14. The budget throttle stays inert (1e9 spent
        // against a budget of ~1e23), the head advances over both, and the epoch closes normally.
        assertEq(aliceRemaining, 0, "residual: the head is filled in FULL at the near-clamp mark");
        assertEq(aliceClaimable, 5e8, "residual: 50,000e18 of principal settles for 5e8 wei");
        assertEq(bobRemaining, 0, "residual: the position behind it is wiped in the SAME call");
        assertEq(bobClaimable, 5e8, "residual: also for 5e8 wei");
        assertEq(queue.head(), 2, "residual: the head advanced over both");
        assertEq(queue.totalQueuedShares(), 0, "residual: the queue is drained");
        assertFalse(queue.isSettling(), "residual: the epoch/heartbeat IS consumed");
    }

    // ── C-1: the position must survive a total senior mark ───────────────

    /// @notice THE REGRESSION. Two queued positions, a default large enough to mark the senior
    ///         layer fully (redemption NAV clamped to 0), then a permissionless `closeEpoch`.
    ///         Nothing may be burned, the head may not advance, and the epoch may not be consumed.
    function test_C1_totalSeniorMark_doesNotBurnQueuedPositionsForZero() public {
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        uint256 aliceId = _queue(alice, aliceShares);
        uint256 bobId = _queue(bob, bobShares);

        // 300k defaulted against 100k of vault assets and no junior capacity: the conservative
        // redemption base clamps to zero.
        _defaulted(300_000e18);
        assertEq(vault.redemptionTotalAssets(), 0, "precondition: redemption NAV clamped to zero");
        assertGt(queue.availableLiquidity(), 0, "precondition: the budget itself is NOT the blocker");
        // the exact pathology: the budget buys an unbounded share count at the clamped base
        assertGt(
            vault.convertToSharesAtRedemption(queue.availableLiquidity()),
            aliceShares + bobShares,
            "precondition: budgetShares explodes rather than going to zero"
        );

        uint256 epochBefore = queue.currentEpoch();
        uint64 endsAtBefore = queue.epochEndsAt();
        vm.warp(queue.eligibleToSettleAt(aliceId)); // past the ADR-0022 cooldown and the heartbeat

        (bool ok, bytes memory ret) = _tryCloseEpochAsBystander();

        // Fixed behaviour: nothing distributable, so the settlement is ABANDONED loudly and the
        // heartbeat is not burned. (Unfixed: the call succeeded and both positions were wiped.)
        //
        // DELIBERATE SEMANTIC UPDATE (C-1 remediation): this assertion used to expect
        // `Queue_NoLiquidity`. It now expects the DISTINCT `Queue_HeadNotRedeemable`. The
        // observable behaviour is otherwise identical (revert, nothing burned, heartbeat intact);
        // only the error changed, so that monitoring can tell a CASH block ("retry when liquidity
        // returns") from a VALUATION block ("the whole senior book is marked below a wei; it
        // clears when the mark cures or is realized"). Reusing one error for both was flagged by
        // all three reviewers as an ops hazard.
        assertFalse(ok, "C-1: a zero-value settlement must not succeed");
        assertEq(
            bytes4(ret), IRedemptionQueue.Queue_HeadNotRedeemable.selector, "abandons with Queue_HeadNotRedeemable"
        );
        {
            (uint256 stuckId, uint256 stuckShares) = abi.decode(_body(ret), (uint256, uint256));
            assertEq(stuckId, aliceId, "the error names the blocked head");
            assertEq(stuckShares, aliceShares, "and reports its untouched position");
            // The block is OBSERVABLE without sending a transaction (CLAUDE.md prime directive 4:
            // it must never look like a silent stall).
            (uint256 vId, uint256 vHeadShares, uint256 vHeadValue, uint256 vBookValue) = queue.headValuation();
            assertEq(vId, aliceId, "headValuation names the head");
            assertEq(vHeadShares, aliceShares, "headValuation reports its shares");
            assertEq(vHeadValue, 0, "headValuation prices the head at zero");
            assertEq(vBookValue, 0, "and the whole queued book at zero: nothing is payable to anyone");
        }

        // The positions are untouched — this is what the unfixed contract destroyed.
        (, uint256 aliceRemaining, uint256 aliceClaimable,,) = queue.request(aliceId);
        (, uint256 bobRemaining, uint256 bobClaimable,,) = queue.request(bobId);
        assertEq(aliceRemaining, aliceShares, "C-1: head position must NOT be burned");
        assertEq(bobRemaining, bobShares, "C-1: the request behind the head must NOT be burned either");
        assertEq(aliceClaimable, 0, "no assets were fabricated");
        assertEq(bobClaimable, 0, "no assets were fabricated");
        assertEq(queue.head(), 0, "the head must not advance over an unfilled request");
        assertEq(queue.totalQueuedShares(), aliceShares + bobShares, "custody intact");
        assertEq(vault.balanceOf(address(queue)), aliceShares + bobShares, "no shares burned");
        assertEq(queue.currentEpoch(), epochBefore, "the epoch is not consumed by a nil settlement");
        assertEq(queue.epochEndsAt(), endsAtBefore, "the heartbeat window is not burned");
        assertFalse(queue.isSettling(), "the latched settlement is released");
    }

    /// @notice The wealth-transfer shape. A queued holder (alice) and a stayer (bob) hold equal
    ///         positions. The mark is later CURED by full repayment. Alice must still be able to
    ///         exit at the restored price and must end up no poorer than bob — under the defect
    ///         her position was burned for zero and bob captured her assets outright.
    function test_C1_queuedHolderIsNotExpropriatedByAStayerWhenTheMarkIsCured() public {
        uint256 aliceShares = _stakeVault(alice, 50_000e18);
        uint256 bobShares = _stakeVault(bob, 50_000e18);
        assertEq(aliceShares, bobShares, "precondition: equal positions");
        uint256 aliceId = _queue(alice, aliceShares);

        uint256 id = _defaulted(300_000e18);
        assertEq(vault.redemptionTotalAssets(), 0, "precondition: fully marked");

        // the permissionless close that used to wipe alice's position
        vm.warp(queue.eligibleToSettleAt(aliceId));
        _tryCloseEpochAsBystander();

        // the borrower repays in full: Defaulted -> Resolved, the mark is cleared, stables return
        _repay(id, 0, 300_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "the mark is cured");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "exit price restored");

        // open the gate fully and settle for real
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(block.timestamp + 2 days); // past the heartbeat in BOTH worlds
        queue.closeEpoch(10);

        (, uint256 remaining, uint256 claimable,,) = queue.request(aliceId);
        assertEq(remaining, 0, "alice's position settles in full once the mark is cured");
        assertGt(claimable, 0, "C-1: the queued holder must not exit with nothing");

        vm.prank(alice);
        uint256 got = queue.claim(aliceId);
        assertEq(got, claimable, "claimed in full");

        // No wealth transferred from the queued holder to the stayer: equal positions in,
        // equal value out.
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqRel(got, bobValue, 1e12, "C-1: queued holder ends level with the stayer");
        assertApproxEqRel(got, 50_000e18, 1e12, "and recovers her principal");
    }

    // ── the guard is on VALUE, and must not over-trigger ─────────────────

    /// @notice The guard is strictly `assetsOut == 0`, NOT "the mark looks bad". A partial
    ///         impairment is the ADR-0022 Option Y exit price and must still settle: the queued
    ///         holder takes the declared mark, exactly as designed. Widening the guard to reject
    ///         "cheap" fills would be a re-pricing decision (and a fresh DoS on the sole exit
    ///         path), so it is deliberately out of scope here.
    function test_C1_partialMarkStillSettlesAtTheConservativePrice() public {
        uint256 aliceShares = _stakeVault(alice, 400_000e18);
        uint256 aliceId = _queue(alice, aliceShares);

        _defaulted(100_000e18); // 25% of the vault: marked, but far from clamped
        assertGt(vault.redemptionTotalAssets(), 0, "precondition: partially, not fully, marked");

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        vm.warp(queue.eligibleToSettleAt(aliceId));
        uint256 expected = vault.previewRedeem(aliceShares);
        queue.closeEpoch(10);

        (, uint256 remaining, uint256 claimable,,) = queue.request(aliceId);
        assertEq(remaining, 0, "the fill is taken, not blocked");
        assertEq(claimable, expected, "settled at the conservative redemption price");
        assertLt(claimable, 400_000e18, "the leaver bears the declared impairment (ADR-0022 Y)");
    }
}
