// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev H-04 FOLLOW-UP (live settlement cap). `closeEpoch` re-caps the remaining
///      settlement budget by the LIVE `availableLiquidity()` on every fill. The cap must
///      shrink the PERSISTED remaining budget, not merely the individual fill:
///      settlement pays USDfr out of the vault and does not itself consume the treasury's
///      stable liquidity, so `availableLiquidity()` is CONSTANT across the fills of one
///      latched settlement. A purely local `min(settlementBudget, liveCap)` therefore lets
///      every fill re-spend the same post-drain cap, and N small requests cumulatively
///      distribute up to N x liveCap (bounded only by the stale snapshot) — which is
///      exactly the stale-snapshot spend H-04 set out to close.
///
///      This suite pins BOTH sides of the fix:
///        - `test_liveCapIsCumulative*` is the mutation-killer: on the pre-fix
///          (local-min) source it fails at 16,000e18 distributed against a 5,000e18 live
///          cap (3.2x over).
///        - `test_shrinkIsSticky*` / `test_flashInflated*` pin the deliberate
///          conservatism (the shrink is monotone — recovered or flash-inflated liquidity
///          cannot re-inflate a latched budget) AND prove it strands nothing: the
///          settlement always terminates and the next epoch serves the remainder in FIFO
///          order with custody reconciled.
///        - `test_a1Guard*` pins that the persisted write does not leak through the A1
///          zero-liquidity abandon path (which reverts, so the write rolls back).
contract OpenQueueLiveCapFindingTest is CreditLayerFixture {
    // ── 1. The defect: the live cap must be cumulative, not per-fill ──────

    /// @notice MUTATION-KILLER. Five small requests, liquidity drained mid-settlement.
    ///         Post-drain fills must not cumulatively exceed the live cap.
    function test_fixedBehavior_liveCapIsCumulativeAcrossMultipleSmallRequestsAfterLiquidityDrain() public {
        uint256 shares = _stake(alice, 20_000e18);
        uint256 slice = shares / 5;

        for (uint256 i = 0; i < 5; ++i) {
            _request(alice, slice);
        }

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        _endEpoch();

        queue.closeEpoch(1);
        (,, uint256 firstFill,,) = queue.request(0);
        assertGt(firstFill, 0, "first request filled under the original high budget");
        assertTrue(queue.isSettling(), "settlement remains latched across chunks");

        _drainIdleLiquidity(15_000e18);

        uint256 liveCapAfterDrain = queue.availableLiquidity();
        assertGt(liveCapAfterDrain, 0, "some live liquidity remains");
        assertLt(liveCapAfterDrain, firstFill * 2, "live cap is smaller than two small requests");

        queue.closeEpoch(10);

        uint256 distributedAfterDrain;
        for (uint256 i = 1; i < 5; ++i) {
            (,, uint256 claimable,,) = queue.request(i);
            distributedAfterDrain += claimable;
        }

        assertLe(distributedAfterDrain, liveCapAfterDrain, "post-drain fills must not cumulatively exceed the live cap");
        // and the cap actually BINDS here — otherwise the assertion above is vacuous
        assertLt(liveCapAfterDrain, 4 * firstFill, "the four remaining slices could not all be paid from the cap");
        _assertFifoAndCustody(5);
    }

    // ── 2. Attacking the fix: is the persisted shrink over-tight? ─────────

    /// @notice The shrink is MONOTONE and STICKY for the rest of a latched settlement:
    ///         liquidity restored mid-settlement does NOT re-inflate the budget. This is
    ///         deliberate conservatism (the cap may only ever lower the budget), and it
    ///         costs at most a heartbeat — proven below by draining the remainder in the
    ///         very next epoch, FIFO intact.
    function test_shrinkIsStickyWithinTheLatchedSettlementAndStrandsNothing() public {
        uint256 shares = _stake(alice, 20_000e18);
        uint256 slice = shares / 5;
        for (uint256 i = 0; i < 5; ++i) {
            _request(alice, slice);
        }
        uint256 sliceAssets = vault.previewRedeem(slice);
        assertEq(sliceAssets, 4_000e18, "each slice redeems to exactly 4,000 USDfr at the 1:1 opening rate");

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        _endEpoch();

        // chunk 1 under the full snapshot budget: request 0 fills entirely
        queue.closeEpoch(1);
        assertEq(queue.head(), 1, "request 0 fully filled");
        assertEq(queue.settlementBudgetRemaining(), 20_000e18 - sliceAssets, "budget is snapshot minus fill 0");

        _drainIdleLiquidity(15_000e18);
        uint256 liveCap = queue.availableLiquidity();
        assertEq(liveCap, 5_000e18, "post-drain live cap: 20,000 idle minus the 15,000 deployed");

        // chunk 2 LATCHES the shrink: the remaining budget collapses 16,000 -> 5,000,
        // then request 1 fills for 4,000, leaving 1,000.
        queue.closeEpoch(1);
        assertEq(queue.head(), 2, "request 1 fully filled");
        assertTrue(queue.isSettling(), "still latched: maxRequests stopped the chunk, not the budget");
        assertEq(queue.settlementBudgetRemaining(), liveCap - sliceAssets, "the SHRUNK budget, not the stale snapshot");
        assertEq(queue.settlementBudgetRemaining(), 1_000e18, "exactly 1,000 USDfr of settlement budget survives");

        // liquidity comes flooding back mid-settlement...
        _mintUSDfrTo(bob, 500_000e18);
        assertGt(queue.availableLiquidity(), 500_000e18, "live liquidity fully restored and then some");
        assertEq(queue.settlementBudgetRemaining(), 1_000e18, "STICKY: recovery does not re-inflate a latched budget");

        // ...and the latched settlement still only spends the shrunk remainder.
        queue.closeEpoch(10);
        assertFalse(queue.isSettling(), "settlement terminated (budget dust), it did not hang latched");
        assertEq(queue.currentEpoch(), 2, "the epoch advanced normally");
        (, uint256 rem2, uint256 claim2,,) = queue.request(2);
        assertEq(claim2, 1_000e18, "request 2 took a PARTIAL head fill of exactly the shrunk remainder");
        assertEq(rem2, slice - vault.convertToSharesAtRedemption(1_000e18), "partial head: shares burned pro rata");
        assertEq(queue.head(), 2, "partial head does not advance");

        uint256 postDrainTotal = sliceAssets + 1_000e18;
        assertEq(postDrainTotal, liveCap, "post-drain distribution equals the live cap exactly, never above it");
        _assertFifoAndCustody(5);

        // NOT STRANDED: the very next epoch serves the remainder against real liquidity.
        _endEpoch();
        queue.closeEpoch(10);
        assertEq(queue.head(), 5, "every request drained in the following epoch");
        assertFalse(queue.isSettling(), "queue drained: settlement closed");
        assertEq(queue.totalQueuedShares(), 0, "no shares left in custody");
        for (uint256 i = 0; i < 5; ++i) {
            (, uint256 rem, uint256 claimable,,) = queue.request(i);
            assertEq(rem, 0, "request fully filled");
            assertEq(claimable, sliceAssets, "each slice paid its full 4,000 USDfr");
        }
        _assertFifoAndCustody(5);
    }

    /// @notice The cap can only LOWER the budget: a mid-settlement liquidity spike cannot
    ///         raise it above the original snapshot either. (Closes the mirror-image
    ///         concern that the persisted assignment might become an inflation vector.)
    function test_flashInflatedLiquidityCannotRaiseALatchedSettlementBudget() public {
        uint256 shares = _stake(alice, 20_000e18);
        uint256 slice = shares / 5;
        for (uint256 i = 0; i < 5; ++i) {
            _request(alice, slice);
        }
        vm.prank(admin);
        queue.setEpochLiquidityBps(1_000); // 10% share: the snapshot BINDS from the start
        _endEpoch();

        uint256 snapshot = queue.availableLiquidity();
        assertEq(snapshot, 2_000e18, "10% of the 20,000 idle stables");

        queue.closeEpoch(1);
        assertEq(queue.settlementBudgetRemaining(), 0, "the whole snapshot went into the partial head fill");

        // 25x the liquidity mid-settlement; the budget must stay spent.
        _mintUSDfrTo(bob, 500_000e18);
        assertGt(queue.availableLiquidity(), snapshot * 25, "live liquidity dwarfs the snapshot");
        assertEq(queue.settlementBudgetRemaining(), 0, "a spike cannot resurrect an exhausted budget");

        (,, uint256 claim0,,) = queue.request(0);
        assertEq(claim0, snapshot, "distributed exactly the snapshot, never above it");
        _assertFifoAndCustody(5);
    }

    // ── 3. The A1 zero-liquidity guard still holds under the persisted write ──

    /// @notice REGRESSION (A1): with every stable deployed, the first settlement chunk
    ///         writes `settlementBudget = 0` from the live cap and then ABANDONS via
    ///         `Queue_NoLiquidity` — the revert rolls the write back, the heartbeat is not
    ///         burned, and nothing latches open. The persisted shrink must not turn this
    ///         permissionless-DoS guard into a state-mutating path.
    function test_a1GuardIntact_zeroLiquidityDoesNotBurnTheHeartbeatUnderThePersistedShrink() public {
        uint256 shares = _stake(alice, 20_000e18);
        _request(alice, shares);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);

        _drainIdleLiquidity(20_000e18); // deploy EVERY idle stable
        assertEq(reserves.idleReserve(), 0, "nothing idle in the treasury");
        assertEq(queue.availableLiquidity(), 0, "zero distributable liquidity");

        _endEpoch();
        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();

        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);

        assertEq(queue.currentEpoch(), epochBefore, "epoch NOT consumed by the empty settlement");
        assertEq(queue.epochEndsAt(), endsBefore, "heartbeat clock NOT reset");
        assertFalse(queue.isSettling(), "no latched settlement left behind");
        assertEq(queue.settlementBudgetRemaining(), 0, "no budget left behind");
        (, uint256 rem, uint256 claimable,,) = queue.request(0);
        assertEq(rem, shares, "position untouched");
        assertEq(claimable, 0, "nothing settled");
        _assertFifoAndCustody(1);
    }

    /// @notice A mid-settlement drain to ZERO after an earlier chunk already paid out:
    ///         the shrink takes the budget to 0, settlement terminates cleanly (it does
    ///         NOT hit the A1 abandon-revert, because this settlement distributed > 0),
    ///         and no latch is left open for a later chunk to re-spend.
    function test_midSettlementDrainToZeroTerminatesCleanlyWithoutLatching() public {
        uint256 shares = _stake(alice, 20_000e18);
        uint256 slice = shares / 5;
        for (uint256 i = 0; i < 5; ++i) {
            _request(alice, slice);
        }
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        _endEpoch();

        uint256 idleBeforeChunk = reserves.idleReserve();
        queue.closeEpoch(1);
        assertEq(queue.head(), 1, "request 0 filled in chunk 1");
        assertTrue(queue.isSettling(), "latched for the next chunk");
        // ROOT-CAUSE PIN: settlement pays USDfr out of the VAULT; it does not consume the
        // treasury's idle stables. `availableLiquidity()` is therefore CONSTANT across the
        // fills of one settlement, which is exactly why a purely LOCAL `min(budget, liveCap)`
        // could be re-spent by every fill.
        assertEq(reserves.idleReserve(), idleBeforeChunk, "a queue fill does not move idle stables");
        assertEq(queue.availableLiquidity(), 20_000e18, "and so the live cap is unchanged by the fill");

        _drainIdleLiquidity(20_000e18); // deploy every remaining idle stable
        assertEq(queue.availableLiquidity(), 0, "live liquidity is now zero");

        queue.closeEpoch(10);
        assertFalse(queue.isSettling(), "zero live cap ends the settlement, no stale latch survives");
        assertEq(queue.currentEpoch(), 2, "a settlement that distributed > 0 advances the epoch");
        assertEq(queue.settlementBudgetRemaining(), 0, "budget zeroed");
        assertEq(queue.head(), 1, "no request past the head was paid from zero liquidity");
        for (uint256 i = 1; i < 5; ++i) {
            (, uint256 rem, uint256 claimable,,) = queue.request(i);
            assertEq(rem, slice, "untouched");
            assertEq(claimable, 0, "paid nothing from a zero live cap");
        }
        _assertFifoAndCustody(5);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev §1.3 queue invariants, spot-checked: FIFO (everything before the head is
    ///      fully filled, nothing after it is partially advanced past the head) and
    ///      custody reconciliation (queue share/USDfr balances equal the sum of parts).
    function _assertFifoAndCustody(uint256 n) internal view {
        uint256 h = queue.head();
        uint256 sumShares;
        uint256 sumClaimable;
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 rem, uint256 claimable,,) = queue.request(i);
            if (i < h) assertEq(rem, 0, "FIFO INVERTED: a request before the head is not fully filled");
            if (i > h) assertEq(claimable, 0, "FIFO INVERTED: a request after the head was paid");
            sumShares += rem;
            sumClaimable += claimable;
        }
        assertEq(queue.totalQueuedShares(), sumShares, "QUEUED SHARES != SUM OF REQUESTS");
        assertEq(IERC20(address(vault)).balanceOf(address(queue)), sumShares, "SHARE CUSTODY DRIFTED");
        assertEq(usdfr.balanceOf(address(queue)), sumClaimable, "ASSET CUSTODY != UNCLAIMED FILLS");
    }

    /// @dev Deploys `principal` of idle treasury stables into a film facility at a zero
    ///      origination fee, so `availableLiquidity()` drops by exactly `principal`.
    function _drainIdleLiquidity(uint256 principal) internal {
        vm.prank(admin);
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, 0);
        uint256 idleBefore = reserves.idleReserve();
        uint256 facilityId = _originateFilm(BORROWER_1, STATE_GA, principal);
        _fundFacility(facilityId, principal);
        assertEq(reserves.idleReserve(), idleBefore - principal, "the drain moved exactly `principal` out of idle");
    }

    function _stake(address who, uint256 amount18) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount18);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount18);
        shares = vault.deposit(amount18, who);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        IERC20(address(vault)).approve(address(queue), shares);
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
}
