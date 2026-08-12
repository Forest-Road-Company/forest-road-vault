// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";

contract RedemptionQueueTest is CreditLayerFixture {
    function _stake(address who, uint256 amount18) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount18);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount18);
        shares = vault.deposit(amount18, who);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        IERC20Like(address(vault)).approve(address(queue), shares);
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

    function _startCappedYieldStream(uint256 amount) internal {
        vm.startPrank(admin);
        vault.setYieldVestingPeriod(Config.MAX_YIELD_VESTING_PERIOD);
        vault.grantRole(Roles.CREDIT_ROLE, address(this));
        queue.setEpochLiquidityBps(uint16(Config.BPS));
        vm.stopPrank();

        _mintUSDfrTo(alice, amount);
        vm.prank(alice);
        assertTrue(usdfr.transfer(address(this), amount));
        vault.beginYieldNotification();
        assertTrue(usdfr.transfer(address(vault), amount));
        vault.notifyYield(amount);
    }

    // ── initialize ───────────────────────────────────────────────────────

    function test_initialize_zeroAddressReverts() public {
        RedemptionQueue impl = new RedemptionQueue();
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                RedemptionQueue.initialize,
                (address(0), guardian, admin, address(vault), address(usdfr), address(reserves))
            )
        );
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                RedemptionQueue.initialize, (admin, guardian, admin, address(0), address(usdfr), address(reserves))
            )
        );
    }

    function test_initialize_defaultsAndWiring() public view {
        assertEq(queue.currentEpoch(), 1);
        assertEq(queue.epochEndsAt(), uint64(1_750_000_000) + Config.DEFAULT_EPOCH_DURATION);
        (uint64 duration, uint16 bps) = queue.epochParams();
        assertEq(duration, Config.DEFAULT_EPOCH_DURATION);
        assertEq(bps, Config.DEFAULT_EPOCH_LIQUIDITY_BPS);
        assertEq(queue.redeemCooldown(), Config.DEFAULT_REDEEM_COOLDOWN);
        (address v, address u, address r) = queue.modules();
        assertEq(v, address(vault));
        assertEq(u, address(usdfr));
        assertEq(r, address(reserves));
        assertFalse(queue.isSettling());
        assertEq(vault.redemptionQueue(), address(queue), "vault admits the queue as sole exit");
    }

    // ── requestRedeem ────────────────────────────────────────────────────

    function test_requestRedeem_locksSharesFIFO() public {
        uint256 sharesA = _stake(alice, 100_000e18);
        uint256 sharesB = _stake(bob, 50_000e18);

        vm.startPrank(alice);
        IERC20Like(address(vault)).approve(address(queue), sharesA);
        vm.expectEmit(true, true, false, true);
        emit IRedemptionQueue.RedemptionRequested(0, alice, sharesA, 1);
        uint256 idA = queue.requestRedeem(sharesA);
        vm.stopPrank();
        uint256 idB = _request(bob, sharesB);

        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(queue.totalRequests(), 2);
        assertEq(queue.head(), 0);
        assertEq(queue.totalQueuedShares(), sharesA + sharesB);
        assertEq(vault.balanceOf(address(queue)), sharesA + sharesB, "shares in queue custody");
        assertEq(vault.balanceOf(alice), 0);

        (address owner, uint256 remaining, uint256 claimable, uint256 epoch,) = queue.request(idA);
        assertEq(owner, alice);
        assertEq(remaining, sharesA);
        assertEq(claimable, 0);
        assertEq(epoch, 1);
        assertEq(queue.eligibleToSettleAt(idA), block.timestamp + Config.DEFAULT_REDEEM_COOLDOWN);
    }

    function test_requestRedeem_zeroReverts() public {
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAmount.selector);
        vm.prank(alice);
        queue.requestRedeem(0);
    }

    /// @dev AUDIT REGRESSION (N-1), widened by the C-1 anti-dust-wedge entry floor
    ///      (owner-approved 2026-07-22): a request must be worth at least `minRedemptionValue`
    ///      (default $1) of REALIZED USDfr to enter the queue. The OLD gate rejected only the
    ///      exactly-zero (sub-1-wei) case with `Queue_DustRequest`; the entry floor replaced it
    ///      with `Queue_BelowMinRedemption(value, minimum)` so a sub-wei head can never wedge the
    ///      queue (see the C-1 regression suite). A pure-dust request and any sub-$1 request are
    ///      both rejected; a request worth >= $1 is admitted.
    function test_requestRedeem_belowMinRedemptionRejected() public {
        _stake(alice, 100_000e18);
        uint256 min = queue.minRedemptionValue();
        assertEq(min, Config.DEFAULT_MIN_REDEMPTION_VALUE, "default $1 floor is active");

        vm.startPrank(alice);
        IERC20Like(address(vault)).approve(address(queue), type(uint256).max);

        // (a) 1 share redeems to 0 assets (1e6 virtual-share offset) → below the floor
        assertEq(vault.convertToAssets(1), 0, "1 share is worth nothing");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, 0, min));
        queue.requestRedeem(1);

        // (b) a sub-$1 request — strictly positive but below the floor — is rejected, with its
        //     exact realized value reported in the error.
        uint256 belowShares = vault.convertToShares(min - 1);
        uint256 belowValue = vault.convertToAssets(belowShares);
        assertGt(belowValue, 0, "precondition: strictly positive value");
        assertLt(belowValue, min, "precondition: strictly below the $1 floor");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, belowValue, min));
        queue.requestRedeem(belowShares);

        // (c) a request worth >= $1 is admitted and takes its FIFO slot.
        uint256 okShares = vault.convertToShares(2 * min);
        assertGe(vault.convertToAssets(okShares), min, "precondition: at/above the floor");
        uint256 id = queue.requestRedeem(okShares);
        vm.stopPrank();
        assertEq(id, 0, "the admissible request entered the queue");
        (, uint256 remaining,,,) = queue.request(id);
        assertEq(remaining, okShares, "and its shares are in queue custody");
    }

    // ── closeEpoch: settlement mechanics ─────────────────────────────────

    function test_closeEpoch_beforeEndReverts() public {
        uint64 endsAt = queue.epochEndsAt();
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_EpochNotOver.selector, endsAt));
        queue.closeEpoch(10);
    }

    function test_closeEpoch_zeroMaxRequestsReverts() public {
        _endEpoch();
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAmount.selector);
        queue.closeEpoch(0);
    }

    function test_closeEpoch_oneNativeUnitShortfallBlocksAndReturnedUnitClearsObservation() public {
        uint256 shares = _stake(alice, 100e18);
        _request(alice, shares);
        _endEpoch();

        _createReserveShortfall(1e12); // one native six-decimal USDC unit
        vm.expectRevert(IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector);
        queue.closeEpoch(1);

        vm.prank(borrower);
        usdc.transfer(address(reserves), 1);
        assertFalse(reserves.reserveLossExitsLocked(), "physical return clears only the objective guard");
        queue.closeEpoch(1);
    }

    function test_closeEpoch_persistentArmCannotExpireAndNeedsExplicitCancellation() public {
        uint256 shares = _stake(alice, 100e18);
        _request(alice, shares);
        _endEpoch();
        (uint256 armId,) = _armReserveLoss(700);

        vm.warp(block.timestamp + 1000 days);
        vm.expectRevert(IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector);
        queue.closeEpoch(1);

        vm.prank(admin);
        reserves.cancelAndDisable(armId, keccak256("queue-arm-cancelled"));
        queue.closeEpoch(1);
    }

    function test_closeEpoch_headInCooldownDoesNotBurnHeartbeat() public {
        uint256 shares = _stake(alice, 10_000e18);
        uint256 requestId = _request(alice, shares);
        uint256 eligibleAt = queue.eligibleToSettleAt(requestId);

        vm.warp(uint256(queue.epochEndsAt()) + 1);
        assertLt(block.timestamp, eligibleAt, "heartbeat ended before cooldown elapsed");
        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();

        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, eligibleAt));
        queue.closeEpoch(10);

        assertEq(queue.currentEpoch(), epochBefore, "heartbeat not consumed while head is cooling down");
        assertEq(queue.epochEndsAt(), endsBefore, "clock not reset while head is cooling down");
        assertFalse(queue.isSettling());

        vm.warp(eligibleAt);
        queue.closeEpoch(10);
        (, uint256 remaining, uint256 claimable,,) = queue.request(requestId);
        assertGt(claimable, 0);
        assertLt(remaining, shares);
    }

    /// @dev AUDIT REGRESSION (A1, permissionless DoS): a settlement that snapshots zero
    ///      distributable liquidity while requests are queued must REVERT without
    ///      advancing the 30-day epoch — else anyone resets the clock by zeroing idle
    ///      liquidity, starving the sole exit path. Here all capital is deployed (the
    ///      realistic zero-idle case; also what a griefer forces atomically).
    function test_closeEpoch_zeroLiquidityDoesNotBurnEpoch() public {
        uint256 shares = _stake(alice, 100_000e18);
        _request(alice, shares);
        // deploy ALL idle liquidity to a facility → idleReserve 0 → budget 0.
        // (zero origination fee so the full principal leaves the treasury)
        vm.prank(admin);
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, 0);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        _fundFacility(id, 100_000e18);
        assertEq(queue.availableLiquidity(), 0, "no idle liquidity");

        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();
        _endEpoch();
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);
        // the epoch is NOT consumed — clock untouched, still settleable
        assertEq(queue.currentEpoch(), epochBefore, "epoch must not advance on empty settlement");
        assertEq(queue.epochEndsAt(), endsBefore, "clock must not reset");
        assertFalse(queue.isSettling());

        // once liquidity returns (repayment), the same epoch settles normally
        _repay(id, 0, 100_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000); // full budget so the 100k request fills
        queue.closeEpoch(10);
        (, uint256 remaining, uint256 claimable,,) = queue.request(0);
        assertEq(remaining, 0, "filled once liquidity returned");
        assertGt(claimable, 0);
        assertEq(queue.currentEpoch(), epochBefore + 1, "now advanced after a real settlement");
    }

    /// @dev AUDIT REGRESSION (FRV-FS-05): a nonzero but economically meaningless
    ///      partial fill must not consume the settlement heartbeat. The whole attempted
    ///      fill rolls back, preserving FIFO and the original epoch until useful
    ///      liquidity is available.
    function test_closeEpoch_dustFillDoesNotBurnEpoch() public {
        uint256 shares = _stake(alice, 100e18);
        uint256 requestId = _request(alice, shares);
        vm.prank(admin);
        queue.setEpochLiquidityBps(1); // 0.01 USDfr budget: below the $1 floor

        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();
        _endEpoch();
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);

        (, uint256 remaining, uint256 claimable,,) = queue.request(requestId);
        assertEq(remaining, shares, "dust partial fill rolled back");
        assertEq(claimable, 0, "no dust claim created");
        assertEq(queue.currentEpoch(), epochBefore, "heartbeat not consumed by dust");
        assertEq(queue.epochEndsAt(), endsBefore, "epoch deadline unchanged");

        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        queue.closeEpoch(10);
        (, remaining, claimable,,) = queue.request(requestId);
        assertEq(remaining, 0, "same epoch fills when meaningful liquidity returns");
        assertGt(claimable, queue.minRedemptionValue());
    }

    /// @dev Disabling the request-entry floor must not restore the original zero-liquidity
    ///      heartbeat burn. The zero-distribution guard is independent of the dust threshold.
    function test_closeEpoch_zeroLiquidityDoesNotBurnEpochWhenFloorDisabled() public {
        uint256 shares = _stake(alice, 100e18);
        _request(alice, shares);
        vm.startPrank(admin);
        queue.setMinRedemptionValue(0);
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, 0);
        vm.stopPrank();
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100e18);
        _fundFacility(id, 100e18);
        assertEq(queue.availableLiquidity(), 0, "no idle liquidity");

        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();
        _endEpoch();
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);

        assertEq(queue.currentEpoch(), epochBefore, "zero-liquidity heartbeat not consumed");
        assertEq(queue.epochEndsAt(), endsBefore, "zero-liquidity deadline unchanged");
    }

    function test_closeEpoch_emptyQueueAdvancesEpoch() public {
        _stake(alice, 10_000e18); // some liquidity exists, nobody queued
        _endEpoch();
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), 2);
        assertFalse(queue.isSettling());
        assertEq(queue.epochEndsAt(), uint64(block.timestamp) + Config.DEFAULT_EPOCH_DURATION);
    }

    function test_closeEpoch_fullFillSingleRequest() public {
        uint256 shares = _stake(alice, 100_000e18);
        _request(alice, shares);
        // idle stables: 100k USDC in treasury; budget = 50% = 50k... the request needs
        // 100k. Add more liquidity so the fill is full: bob deposits 150k (unstaked)
        _mintUSDfrTo(bob, 150_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);

        _endEpoch();
        uint256 expectedAssets = vault.previewRedeem(shares);
        queue.closeEpoch(10);

        (, uint256 remaining, uint256 claimable,,) = queue.request(0);
        assertEq(remaining, 0, "fully filled");
        assertEq(claimable, expectedAssets);
        assertEq(queue.head(), 1);
        assertEq(queue.totalQueuedShares(), 0);
        assertEq(queue.currentEpoch(), 2);
        assertEq(usdfr.balanceOf(address(queue)), expectedAssets, "assets custodied for claim");
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice G4 regression: the post-outflow stream cap used to run once per request, so the
    ///         first request changed the rate paid to the second inside one keeper transaction.
    ///         One aggregate burn makes both FIFO positions share one canonical quote.
    function test_G4_cappedStreamCannotCreateTwoPricesInsideOneBatch() public {
        uint256 sharesA = _stake(alice, 100e18);
        uint256 sharesB = _stake(bob, 100e18);
        _startCappedYieldStream(1_000e18);
        assertGt(vault.unvestedYield(), 0, "precondition: live stream");

        uint256 idA = _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);
        _endEpoch();

        uint256 prePreparationQuote = vault.previewRedeem(sharesA + sharesB);
        uint256 queueAssetsBefore = usdfr.balanceOf(address(queue));
        queue.closeEpoch(2);

        (, uint256 remainingA, uint256 claimA,,) = queue.request(idA);
        (, uint256 remainingB, uint256 claimB,,) = queue.request(idB);
        assertEq(remainingA, 0);
        assertEq(remainingB, 0);
        // This test previously asserted equality to the quote taken BEFORE settlement-wide
        // stream preparation, thereby enshrining M-2's missing NAV step. The prepared quote is
        // deliberately higher; claims must instead equal the one aggregate receipt actually
        // delivered by the vault.
        assertEq(
            claimA + claimB,
            usdfr.balanceOf(address(queue)) - queueAssetsBefore,
            "claims must equal the one aggregate receipt"
        );
        assertGt(claimA + claimB, prePreparationQuote, "the pre-pricing stream recognition did not occur");
        assertApproxEqAbs(claimA, claimB, 1, "one batch paid two exchange rates");
    }

    function test_G4_feeCheckpointAndStreamCapStillProduceOneBatchPrice() public {
        uint256 sharesA = _stake(alice, 200e18);
        uint256 sharesB = _stake(bob, 200e18);
        _startCappedYieldStream(2_000e18);
        uint16 maxFee = vault.maxManagementFeeBps();
        vm.prank(admin);
        vault.setManagementFee(maxFee);

        uint256 idA = _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);
        vm.warp(block.timestamp + 365 days);
        uint256 quotedAfterFeeSimulation = vault.previewRedeem(sharesA + sharesB);
        queue.closeEpoch(2);

        (,, uint256 claimA,,) = queue.request(idA);
        (,, uint256 claimB,,) = queue.request(idB);
        assertEq(claimA + claimB, quotedAfterFeeSimulation, "checkpoint diverged from aggregate preview");
        assertApproxEqAbs(claimA, claimB, 1, "fee checkpoint created two batch prices");
    }

    /// @notice M-2 regression. The earlier G4 tests proved only that requests grouped inside
    ///         one call shared a quote; they did not prove that `maxRequests` was economically
    ///         neutral. Post-outflow stream recognition therefore let a keeper choose the NAV
    ///         step by choosing one request or two. Preparation now uses the full remaining
    ///         settlement budget, so one-request chunks and one aggregate chunk are equivalent.
    function test_M2_keeperChunkSizeCannotChooseCapStreamEconomics() public {
        uint256 sharesA = _stake(alice, 100e18);
        uint256 sharesB = _stake(bob, 100e18);
        _startCappedYieldStream(1_000e18);
        uint256 idA = _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);
        _endEpoch();

        uint256 snap = vm.snapshotState();
        queue.closeEpoch(1);
        queue.closeEpoch(1);
        (,, uint256 chunkedA,,) = queue.request(idA);
        (,, uint256 chunkedB,,) = queue.request(idB);
        uint256 chunkedUnvested = vault.unvestedYield();
        uint256 chunkedSupply = vault.totalSupply();

        assertTrue(vm.revertToState(snap), "failed to restore the identical pricing state");
        queue.closeEpoch(2);
        (,, uint256 aggregateA,,) = queue.request(idA);
        (,, uint256 aggregateB,,) = queue.request(idB);

        assertApproxEqAbs(chunkedA, aggregateA, 1, "keeper chunking changed the first FIFO price");
        assertApproxEqAbs(chunkedB, aggregateB, 1, "keeper chunking changed the second FIFO price");
        assertApproxEqAbs(
            chunkedA + chunkedB, aggregateA + aggregateB, 1, "keeper chunking changed aggregate settlement value"
        );
        assertEq(vault.unvestedYield(), chunkedUnvested, "keeper chunking changed retained stream value");
        assertEq(vault.totalSupply(), chunkedSupply, "keeper chunking changed fee-adjusted supply");
    }

    /// @notice G4 inter-transaction boundary: a changed conservative mark creates a new,
    ///         explicit pricing session without resetting FIFO, cooldown, epoch, or budget.
    function test_G4_markRevisionStartsNewSessionWithoutResettingSettlement() public {
        MockImpairmentSource source = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
        vm.prank(admin);
        queue.setEpochLiquidityBps(uint16(Config.BPS));
        vm.prank(complianceAdmin);
        compliance.setAllowed(carol, true);

        uint256 sharesA = _stake(alice, 100e18);
        uint256 sharesB = _stake(bob, 100e18);
        uint256 sharesC = _stake(carol, 100e18);
        uint256 idA = _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);
        uint256 idC = _request(carol, sharesC);
        _endEpoch();

        uint256 quoteA = vault.previewRedeem(sharesA);
        queue.closeEpoch(1);
        (,, uint256 claimA,,) = queue.request(idA);
        uint256 budgetAfterA = queue.settlementBudgetRemaining();
        assertEq(claimA, quoteA, "first session diverged from its quote");
        assertEq(queue.pricingSessionCount(), 1, "first session not recorded");
        assertEq(queue.head(), idB, "FIFO reset after first session");
        assertTrue(queue.isSettling(), "maxRequests boundary ended the settlement");
        assertEq(queue.currentEpoch(), 1, "session boundary advanced the epoch");

        source.setImpairment(60e18);
        uint256 quoteB = vault.previewRedeem(sharesB);
        assertLt(quoteB, quoteA, "adverse mark did not change the next session quote");
        queue.closeEpoch(1);

        (,, uint256 claimB,,) = queue.request(idB);
        assertEq(claimB, quoteB, "second session diverged from its revised quote");
        assertEq(queue.pricingSessionCount(), 2, "mark revision did not create a new session");
        assertEq(queue.head(), idC, "mark revision reset or jumped FIFO");
        assertTrue(queue.isSettling(), "mark revision ended the live settlement");
        assertEq(queue.currentEpoch(), 1, "mark revision advanced the epoch");
        assertEq(
            queue.settlementBudgetRemaining(),
            budgetAfterA - claimB,
            "mark revision reset or inflated the latched budget"
        );
    }

    function test_closeEpoch_budgetIgnoresUnaccountedUSDCDonation() public {
        _stake(alice, 100_000e18); // 100k USDC idle
        usdc.mint(address(reserves), 500_000e6);
        assertEq(
            queue.availableLiquidity(),
            100_000e18 * uint256(Config.DEFAULT_EPOCH_LIQUIDITY_BPS) / uint256(Config.BPS),
            "only accounted USDC is distributable"
        );
    }

    function test_closeEpoch_partialFillAtBudget() public {
        uint256 shares = _stake(alice, 100_000e18); // only alice's 100k USDC idle
        _request(alice, shares);
        _endEpoch();
        // budget = configured bps of 100k; the 100k request fills partially
        queue.closeEpoch(10);

        (, uint256 remaining, uint256 claimable,,) = queue.request(0);
        assertEq(
            claimable,
            100_000e18 * uint256(Config.DEFAULT_EPOCH_LIQUIDITY_BPS) / uint256(Config.BPS),
            "filled exactly to the budget"
        );
        assertGt(remaining, 0, "head partially filled");
        assertEq(queue.head(), 0, "head does not advance on partial fill");
        assertEq(queue.currentEpoch(), 2, "settlement completed (budget out)");
        assertFalse(queue.isSettling());

        // liquidity returns (repayment inflow); next epoch fills the rest
        _mintUSDfrTo(bob, 200_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        _endEpoch();
        queue.closeEpoch(10);
        (, remaining, claimable,,) = queue.request(0);
        assertEq(remaining, 0, "drained across epochs");
        assertEq(queue.head(), 1);
    }

    function test_closeEpoch_fifoStrict() public {
        uint256 sharesA = _stake(alice, 60_000e18);
        uint256 sharesB = _stake(bob, 60_000e18);
        _request(alice, sharesA);
        _request(bob, sharesB);
        // idle 120k → default budget is smaller than A: A partially fills, B gets nothing — FIFO
        _endEpoch();
        queue.closeEpoch(10);

        (, uint256 remA, uint256 claimA,,) = queue.request(0);
        (, uint256 remB, uint256 claimB,,) = queue.request(1);
        assertGt(remA, 0, "head is only partially filled under the default daily budget");
        assertGt(claimA, 0);
        assertEq(remB, sharesB, "later request waits untouched");
        assertEq(claimB, 0, "no out-of-order fill");
    }

    function test_closeEpoch_chunkedSettlementKeepsEpochOpen() public {
        uint256 sharesA = _stake(alice, 10_000e18);
        uint256 sharesB = _stake(bob, 10_000e18);
        _request(alice, sharesA);
        _request(bob, sharesB);
        _mintUSDfrTo(bob, 100_000e18); // plenty of liquidity
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);

        _endEpoch();
        queue.closeEpoch(1); // chunk 1: fills A only
        assertTrue(queue.isSettling(), "settlement still open");
        assertGt(queue.settlementBudgetRemaining(), 0, "budget carries across chunks");
        assertEq(queue.currentEpoch(), 1, "epoch advances only when settlement completes");
        assertEq(queue.head(), 1);

        queue.closeEpoch(1); // chunk 2: fills B, completes
        assertFalse(queue.isSettling());
        assertEq(queue.currentEpoch(), 2);
        assertEq(queue.head(), 2);
    }

    function test_closeEpoch_requestDuringSettlementEligibleFIFO() public {
        uint256 sharesA = _stake(alice, 10_000e18);
        _request(alice, sharesA);
        uint256 sharesB = _stake(bob, 10_000e18);
        _mintUSDfrTo(bob, 100_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);

        _endEpoch();
        queue.closeEpoch(1); // fills A; settlement would complete ONLY if queue drained…
        // …but B requests mid-settlement (settling stays true until a closing call)
        assertEq(queue.currentEpoch(), 2, "queue was drained by the first chunk: epoch closed");

        // B requests in the new epoch; a fresh settlement serves them
        _request(bob, sharesB);
        _endEpoch();
        queue.closeEpoch(10);
        (, uint256 remB,,,) = queue.request(1);
        assertEq(remB, 0);
    }

    function test_closeEpoch_eventNumbers() public {
        uint256 shares = _stake(alice, 40_000e18);
        _request(alice, shares);
        _mintUSDfrTo(bob, 60_000e18); // idle 100k → budget 50k
        vm.prank(admin);
        queue.setEpochLiquidityBps(5_000);
        _endEpoch();
        uint256 expectedAssets = vault.previewRedeem(shares);
        vm.expectEmit(true, false, false, true);
        emit IRedemptionQueue.RequestFilled(0, shares, expectedAssets, 1);
        vm.expectEmit(true, false, false, true);
        emit IRedemptionQueue.EpochClosed(
            1, 50_000e18, expectedAssets, uint64(block.timestamp) + Config.DEFAULT_EPOCH_DURATION
        );
        queue.closeEpoch(10);
    }

    // ── claim ────────────────────────────────────────────────────────────

    function test_claim_transfersOnceAndOnlyOnce() public {
        uint256 shares = _stake(alice, 10_000e18);
        _request(alice, shares);
        _mintUSDfrTo(bob, 100_000e18);
        _endEpoch();
        queue.closeEpoch(10);

        (,, uint256 claimable,,) = queue.request(0);
        vm.expectEmit(true, true, false, true);
        emit IRedemptionQueue.Claimed(0, alice, claimable);
        vm.prank(alice);
        uint256 got = queue.claim(0);
        assertEq(got, claimable);
        assertEq(usdfr.balanceOf(alice), claimable);
        assertEq(usdfr.balanceOf(address(queue)), 0);

        // NO DOUBLE-CLAIM (§1.3)
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, 0));
        vm.prank(alice);
        queue.claim(0);
    }

    function test_claim_partialFillClaimableEarly() public {
        uint256 shares = _stake(alice, 100_000e18); // budget will be the configured daily bps
        _request(alice, shares);
        _endEpoch();
        queue.closeEpoch(10);

        vm.prank(alice);
        uint256 got = queue.claim(0);
        assertEq(
            got,
            100_000e18 * uint256(Config.DEFAULT_EPOCH_LIQUIDITY_BPS) / uint256(Config.BPS),
            "partial fill claimable before the rest arrives"
        );
        (, uint256 remaining, uint256 claimable,,) = queue.request(0);
        assertGt(remaining, 0);
        assertEq(claimable, 0);
    }

    function test_claim_guards() public {
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 0));
        vm.prank(alice);
        queue.claim(0);
        // the request() view guards identically
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 7));
        queue.request(7);

        uint256 shares = _stake(alice, 10_000e18);
        _request(alice, shares);
        // unfilled: nothing claimable
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, 0));
        vm.prank(alice);
        queue.claim(0);

        _mintUSDfrTo(bob, 100_000e18);
        _endEpoch();
        queue.closeEpoch(10);
        // only the owner claims
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, 0, bob));
        vm.prank(bob);
        queue.claim(0);
    }

    // ── the full exit: claim then redeem USDfr → stables ─────────────────

    function test_exit_endToEnd_claimThenRedeemStable() public {
        uint256 shares = _stake(alice, 10_000e18);
        _request(alice, shares);
        _mintUSDfrTo(bob, 100_000e18);
        _endEpoch();
        queue.closeEpoch(10);
        vm.prank(alice);
        uint256 assets = queue.claim(0);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        controller.redeem(assets);
        assertEq(usdc.balanceOf(alice) - usdcBefore, assets / 1e12, "full round trip");
        assertTrue(controller.backingInvariantHolds());
    }

    // ── ADR-0016 interplay: queued shares stop accruing points ───────────

    function test_points_queuedSharesAccrueNothing() public {
        PointsModule points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );
        vm.prank(admin);
        vault.setPointsModule(address(points));

        uint256 shares = _stake(alice, 10_000e18);
        vm.warp(block.timestamp + 30 days);
        uint256 pointsAtRequest = points.pointsOfWallet(alice);
        assertGt(pointsAtRequest, 0, "accrued while staked");

        _request(alice, shares);
        // alice's share position dropped to zero (moved to the queue): accrual STOPS.
        vm.warp(block.timestamp + 60 days);
        assertEq(points.pointsOfWallet(alice), pointsAtRequest, "no accrual after exit request");
        (uint256 aliceShares,) = points.trackedBalances(alice);
        assertEq(aliceShares, 0, "alice share position released to the queue");
    }

    // ── governance ───────────────────────────────────────────────────────

    function test_setEpochDuration_boundsAndAccess() public {
        vm.expectEmit(false, false, false, true);
        emit IRedemptionQueue.EpochDurationSet(7 days);
        vm.prank(admin);
        queue.setEpochDuration(7 days);
        (uint64 duration,) = queue.epochParams();
        assertEq(duration, 7 days);

        vm.prank(admin);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setEpochDuration(0);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        queue.setEpochDuration(1 days);
    }

    function test_setEpochLiquidityBps_boundsAndAccess() public {
        vm.expectEmit(false, false, false, true);
        emit IRedemptionQueue.EpochLiquidityBpsSet(10_000);
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);

        vm.startPrank(admin);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setEpochLiquidityBps(0);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setEpochLiquidityBps(10_001);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        queue.setEpochLiquidityBps(5_000);
    }

    // ── ADR-0022: forced cooldown governance + boundary ──────────────────

    /// @notice ═══════════ INVERTED (SWEEP-2 CSG-F2) — DO NOT RESTORE THE ORIGINAL ═══════════════
    ///         THIS TEST ASSERTED THE DEFECT AS A FEATURE. It pinned, verbatim:
    ///             vm.prank(admin); queue.setRedeemCooldown(7 days);   // "a shortening lets a
    ///                                                                 //  queued request out sooner"
    ///             // zero is a permitted, deliberate governance act (disables the hold)
    ///             vm.prank(admin); queue.setRedeemCooldown(0);
    ///             assertEq(queue.redeemCooldown(), 0);
    ///         Both of those are the G2W loss-dodge. `CollateralRegistry.conservativeSeniorMark`
    ///         ramps the UNATTESTED past-due discount in over `Config.DEFAULT_REDEEM_COOLDOWN`, and
    ///         `ConservativeImpairmentMath` states the resulting safety property as "a senior who
    ///         requests AT or AFTER the mark cannot settle before `requestedAt +
    ///         DEFAULT_REDEEM_COOLDOWN`, by which point the weight is FULL". MEASURED: on a
    ///         2,000,000e18 senior tranche with an 800,000e18 unattested mark,
    ///         `setRedeemCooldown(7 days)` let a reactor settle INSIDE the ramp for 133,360e18 more
    ///         than the honest full-weight price and the holder who STAYED lost exactly 133,360e18.
    ///         `setRedeemCooldown(0)` deletes the ramp outright.
    ///
    ///         NOT WEAKENED: every other property the original asserted — the event, the effect,
    ///         the UNIFORM application to in-flight requests, and the access control — is still
    ///         asserted, on values inside the legal range.
    /// @dev MUTATION: `if (cooldown < Config.DEFAULT_REDEEM_COOLDOWN && cooldown == type(uint64).max
    ///      || cooldown > Config.MAX_REDEEM_COOLDOWN)` (compiles, both operands still read) -> RED
    ///      here on the first `expectRevert`.
    function test_setRedeemCooldown_effectEventAccessAndUniformity() public {
        // authorized: sets, emits, takes effect
        vm.expectEmit(false, false, false, true);
        emit IRedemptionQueue.RedeemCooldownSet(28 days);
        vm.prank(admin);
        queue.setRedeemCooldown(28 days);
        assertEq(queue.redeemCooldown(), 28 days);

        // ADR-0022: applies UNIFORMLY to in-flight requests (eligibility recomputed against
        // the current value) — a change moves a queued request's eligibility with it.
        uint256 shares = _stake(alice, 100_000e18);
        uint256 id = _request(alice, shares);
        uint256 requestedAt = block.timestamp;
        assertEq(queue.eligibleToSettleAt(id), requestedAt + 28 days);
        vm.prank(admin);
        queue.setRedeemCooldown(Config.DEFAULT_REDEEM_COOLDOWN);
        assertEq(
            queue.eligibleToSettleAt(id),
            requestedAt + Config.DEFAULT_REDEEM_COOLDOWN,
            "eligibility tracks current cooldown"
        );

        // INVERTED: shortening BELOW the G2W relief ramp is now REFUSED, and zero with it.
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        vm.prank(admin);
        queue.setRedeemCooldown(7 days);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        vm.prank(admin);
        queue.setRedeemCooldown(0);
        // ...and the fat-finger that permanently freezes every senior exit is refused too.
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        vm.prank(admin);
        queue.setRedeemCooldown(type(uint64).max);
        assertEq(queue.redeemCooldown(), Config.DEFAULT_REDEEM_COOLDOWN, "no refused call took effect");

        // unauthorized caller is rejected
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        queue.setRedeemCooldown(21 days);
    }

    // ── C-1: minRedemptionValue anti-dust-wedge floor governance ─────────

    /// @dev The C-1 anti-dust-wedge entry floor is governance-settable (DEFAULT_ADMIN only),
    ///      capped at $100 so it can never lock ordinary redeemers out of the sole exit path,
    ///      emits `MinRedemptionValueSet`, and takes effect on the next request. Owner-approved
    ///      entry-floor design (2026-07-22) that replaced the former sub-wei deferral.
    function test_setMinRedemptionValue_boundsAccessEventAndEffect() public {
        assertEq(queue.minRedemptionValue(), Config.DEFAULT_MIN_REDEMPTION_VALUE, "default $1");

        // authorized: sets, emits, view reflects it
        vm.expectEmit(false, false, false, true);
        emit IRedemptionQueue.MinRedemptionValueSet(5e18);
        vm.prank(admin);
        queue.setMinRedemptionValue(5e18);
        assertEq(queue.minRedemptionValue(), 5e18);

        // capped at $100: one wei over reverts
        vm.prank(admin);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setMinRedemptionValue(100e18 + 1);

        // exactly $100 is allowed (the boundary)
        vm.prank(admin);
        queue.setMinRedemptionValue(100e18);
        assertEq(queue.minRedemptionValue(), 100e18);

        // zero is a permitted, deliberate governance act (disables the floor)
        vm.prank(admin);
        queue.setMinRedemptionValue(0);
        assertEq(queue.minRedemptionValue(), 0);

        // unauthorized caller is rejected
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        queue.setMinRedemptionValue(1e18);

        // EFFECT: raise the floor to $10 — a $9 request is now rejected, a $20 request admitted.
        vm.prank(admin);
        queue.setMinRedemptionValue(10e18);
        _stake(alice, 100_000e18);
        vm.startPrank(alice);
        IERC20Like(address(vault)).approve(address(queue), type(uint256).max);
        uint256 belowShares = vault.convertToShares(9e18);
        uint256 belowValue = vault.convertToAssets(belowShares);
        assertLt(belowValue, 10e18, "precondition: below the raised floor");
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, belowValue, 10e18));
        queue.requestRedeem(belowShares);
        uint256 okShares = vault.convertToShares(20e18);
        assertGe(vault.convertToAssets(okShares), 10e18, "precondition: at/above the raised floor");
        queue.requestRedeem(okShares);
        vm.stopPrank();
    }

    /// @dev CLAUDE.md boundary rigor: settlement is gated by `block.timestamp < eligibleAt`,
    ///      so the request settles at EXACTLY `requestedAt + cooldown` and reverts one second
    ///      before. The heartbeat has long since lapsed here, isolating the cooldown edge.
    function test_cooldownBoundary_settlesAtEligibleRevertsOneSecondBefore() public {
        uint256 shares = _stake(alice, 100_000e18);
        _mintUSDfrTo(bob, 150_000e18); // stable liquidity for a full fill
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000);
        uint256 id = _request(alice, shares);
        uint256 eligibleAt = queue.eligibleToSettleAt(id);

        // exactly one second before eligibility → blocked, heartbeat not consumed
        vm.warp(eligibleAt - 1);
        uint256 epochBefore = queue.currentEpoch();
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, eligibleAt));
        queue.closeEpoch(1);
        assertEq(queue.currentEpoch(), epochBefore, "heartbeat not burned at cooldown - 1s");

        // exactly at eligibility → settles
        vm.warp(eligibleAt);
        queue.closeEpoch(1);
        (, uint256 remaining, uint256 claimable,,) = queue.request(id);
        assertEq(remaining, 0, "settles at exactly requestedAt + cooldown");
        assertGt(claimable, 0);
    }

    /// @dev AUDIT (H-04, red-team #1): a chunked settlement latches `settling` open across calls.
    ///      The per-chunk `min(budget, availableLiquidity())` re-cap means a stale-high snapshot
    ///      cannot be spent after liquidity drains mid-settlement.
    function test_closeEpoch_latchedSettlementReCapsBudgetWhenLiquidityDrops() public {
        uint256 sharesA = _stake(alice, 100_000e18);
        uint256 sharesB = _stake(bob, 100_000e18);
        // the two stakes already left 200k idle stable in reserves (mint routes stable there)
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000); // 100%
        uint256 idA = _request(alice, sharesA);
        uint256 idB = _request(bob, sharesB);

        _endEpoch(); // past cooldown + heartbeat
        // chunk 1 fills A fully then stops at maxRequests=1 → settlement LATCHES open
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "settlement latched open");
        (, uint256 remA,,,) = queue.request(idA);
        assertEq(remA, 0, "A fully filled in chunk 1");

        // live liquidity collapses mid-settlement (modelled via the governance liquidity share).
        // The stale snapshot budget still holds ~100k, but availableLiquidity() is now tiny.
        vm.prank(admin);
        queue.setEpochLiquidityBps(1);
        uint256 liveNow = queue.availableLiquidity();
        assertLt(liveNow, 1_000e18, "live liquidity collapsed vs the ~100k stale snapshot budget");

        // chunk 2: B is capped to LIVE liquidity by the per-chunk min(), NOT the stale budget
        queue.closeEpoch(10);
        (, uint256 remB, uint256 claimB,,) = queue.request(idB);
        assertGt(remB, 0, "B not fully filled from the stale snapshot budget");
        assertLe(claimB, liveNow + 1, "B fill capped at live liquidity, not the stale budget");
    }

    // ── pause ────────────────────────────────────────────────────────────

    function test_pause_blocksNewSettlementPathsButAllowsSettledClaims() public {
        uint256 aliceShares = _stake(alice, 10_000e18);
        uint256 claimId = _request(alice, aliceShares);
        _endEpoch();
        queue.closeEpoch(10);
        (,, uint256 claimable,,) = queue.request(claimId);
        assertGt(claimable, 0, "precondition: the request has settled assets");

        uint256 bobShares = _stake(bob, 10_000e18);
        vm.prank(guardian);
        queue.pause();

        vm.startPrank(bob);
        IERC20Like(address(vault)).approve(address(queue), bobShares);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.requestRedeem(bobShares);
        vm.stopPrank();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.closeEpoch(10);

        uint256 before = usdfr.balanceOf(alice);
        vm.prank(alice);
        queue.claim(claimId);
        assertEq(usdfr.balanceOf(alice) - before, claimable, "pause cannot trap already-settled assets");

        vm.prank(guardian);
        queue.unpause();
        _request(bob, bobShares);
    }

    function test_pause_onlyGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        queue.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        queue.unpause();
    }

    // ── upgrade authorization ────────────────────────────────────────────

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new RedemptionQueue());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        queue.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        queue.upgradeToAndCall(newImpl, "");
    }

    // ── fuzz: budget ceiling and FIFO under arbitrary sizes ──────────────

    /// @dev QUEUE NEVER OVER-DISTRIBUTES (§1.3): for any stake/queue/liquidity split,
    ///      settled assets never exceed the snapshot budget, and FIFO holds.
    function testFuzz_settlement_respectsBudgetAndFIFO(uint256 stakeA, uint256 stakeB, uint256 extraLiq) public {
        stakeA = bound(stakeA, 1e18, 500_000e18);
        stakeB = bound(stakeB, 1e18, 500_000e18);
        extraLiq = bound(extraLiq, 0, 1_000_000e18);
        stakeA -= stakeA % 1e12;
        stakeB -= stakeB % 1e12;
        extraLiq -= extraLiq % 1e12;

        uint256 sharesA = _stake(alice, stakeA);
        uint256 sharesB = _stake(bob, stakeB);
        _request(alice, sharesA);
        _request(bob, sharesB);
        if (extraLiq != 0) _mintUSDfrTo(bob, extraLiq);

        uint256 budget =
            (stakeA + stakeB + extraLiq) * uint256(Config.DEFAULT_EPOCH_LIQUIDITY_BPS) / uint256(Config.BPS);
        _endEpoch();
        if (budget < queue.minRedemptionValue()) {
            uint256 epochBefore = queue.currentEpoch();
            vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
            queue.closeEpoch(100);
            (, uint256 untouchedA, uint256 dustClaimA,,) = queue.request(0);
            (, uint256 untouchedB, uint256 dustClaimB,,) = queue.request(1);
            assertEq(untouchedA, sharesA, "dust settlement leaves A untouched");
            assertEq(untouchedB, sharesB, "dust settlement leaves B untouched");
            assertEq(dustClaimA + dustClaimB, 0, "dust settlement creates no claim");
            assertEq(queue.currentEpoch(), epochBefore, "dust settlement preserves the heartbeat");
            return;
        }
        queue.closeEpoch(100);

        (, uint256 remA, uint256 claimA,,) = queue.request(0);
        (, uint256 remB, uint256 claimB,,) = queue.request(1);
        assertLe(claimA + claimB, budget, "NEVER over-distributes the budget");
        if (claimB > 2) {
            assertEq(remA, 0, "FIFO: B filled only after A fully served");
        }
        assertEq(vault.balanceOf(address(queue)), remA + remB, "share custody exact");
        assertEq(usdfr.balanceOf(address(queue)), claimA + claimB, "asset custody exact");
        assertTrue(controller.backingInvariantHolds());
    }

    /// @dev COVERAGE (CLAUDE.md 1.2): the unknown-request revert branch of
    ///      `eligibleToSettleAt` was the queue's last uncovered branch. It is the view a
    ///      redeemer (and the frontend) uses to learn when their position becomes settleable,
    ///      so it must fail loudly on a bad id rather than return a misleading timestamp.
    function test_eligibleToSettleAt_revertsForUnknownRequestAndIsExactForAReal() public {
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 0));
        queue.eligibleToSettleAt(0);

        uint256 shares = _stake(alice, 10_000e18);
        uint256 id = _request(alice, shares);
        assertEq(
            queue.eligibleToSettleAt(id),
            block.timestamp + queue.redeemCooldown(),
            "eligibility is requestedAt plus the cooldown, exactly"
        );
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, id + 1));
        queue.eligibleToSettleAt(id + 1);
    }
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
}
