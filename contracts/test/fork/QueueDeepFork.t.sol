// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title QueueDeepFork — the RedemptionQueue in depth, on the pinned mainnet fork
/// @notice `FullLifecycleFork` drives ONE request through cooldown -> close -> claim. This
///         suite is the deep pass over the sole sUSDfr exit path, on the REAL deployed
///         stack (`Deploy.s.sol` topology, real USDC as the approved stable):
///
///           - strict FIFO across many requests from four holders, over MULTIPLE heartbeats;
///           - a PARTIAL head fill carried across epochs with exact per-epoch arithmetic;
///           - the per-settlement liquidity budget snapshotted, never overshot, and
///             reported exactly in `EpochClosed`;
///           - chunked permissionless `closeEpoch` proven EQUAL to one big call
///             (state-snapshot differential, every observable compared);
///           - claim-anytime-after-fill, and no double claim;
///           - a zero-liquidity epoch (every stable in the treasury deployed) that must NOT
///             burn the heartbeat;
///           - `Queue_AllInCooldown` while every request is still held, and staggered
///             eligibility settling in the right order;
///           - queue custody reconciling EXACTLY after every stage (queue shares == sum
///             queued, queue USDfr == sum unclaimed), and the exchange rate never falling
///             from queue traffic alone.
///
/// @dev PRIVATE FIXTURE EXTENSIONS (declared here, not in `ForkLifecycleFixture`, which this
///      suite must not modify):
///        - a fourth KYC'd holder `dave`;
///        - `_originateAndFundWith(...)` — the fixture's `_originateAndFund` is hard-wired to
///          USDC and the FILM class; the zero-liquidity test must ALSO deploy the deploy
///          script's 1,000e18 mock-stable seed, or `availableLiquidity()` can never reach
///          exactly zero and `Queue_NoLiquidity` is unreachable on this stack;
///        - `_settleAndAssertFifo()` — one settlement plus the full FIFO / budget / custody
///          / rate assertion battery, so every heartbeat in every test is checked in full.
contract QueueDeepForkTest is ForkLifecycleFixture {
    /// @dev A fourth KYC'd holder, so FIFO is exercised across four distinct owners.
    address internal dave = makeAddr("forkDave");

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        compliance.setAllowed(dave, true);
        deal(USDC, dave, 5_000_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. STRICT FIFO — five requests, four holders, drained over many epochs
    // ─────────────────────────────────────────────────────────────────────

    /// @notice §1.3 (redemption queue): FIFO ordering holds, the queue never distributes
    ///         more than the settlement budget, and custody reconciles at every stage —
    ///         proven across a multi-epoch drain of five requests from four holders.
    function test_fork_queue_strictFifoAcrossManyHoldersAndEpochs() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        _mintFromUSDC(ops, 1_000_000e6);
        _mintFromUSDC(dave, 1_000_000e6);

        uint256 shA = _stake(alice, 400_000e18);
        uint256 shB = _stake(bob, 300_000e18);
        uint256 shO = _stake(ops, 200_000e18);
        uint256 shD = _stake(dave, 100_000e18);

        // five requests in a known order; one holder (alice) queues twice, so a FIFO
        // inversion cannot hide behind "one request per address"
        uint256[5] memory sz;
        sz[0] = shA * 5 / 8;
        sz[1] = shB;
        sz[2] = shO;
        sz[3] = shD;
        sz[4] = shA - sz[0];
        assertEq(_requestFrom(alice, sz[0]), 0, "request ids are the FIFO order");
        assertEq(_requestFrom(bob, sz[1]), 1, "request ids are the FIFO order");
        assertEq(_requestFrom(ops, sz[2]), 2, "request ids are the FIFO order");
        assertEq(_requestFrom(dave, sz[3]), 3, "request ids are the FIFO order");
        assertEq(_requestFrom(alice, sz[4]), 4, "request ids are the FIFO order");

        assertEq(queue.totalRequests(), 5, "five queued");
        assertEq(queue.head(), 0, "head at the first request");
        assertEq(queue.totalQueuedShares(), shA + shB + shO + shD, "every staked share is queued");
        _assertCustody("after the five requests");

        // 5% of idle stables per heartbeat against 1,000,000e18 of queued value: the drain
        // MUST span several epochs, which is the point of the test.
        queue.setEpochLiquidityBps(500);
        assertEq(reserves.idleReserve(), 6_000_010e18, "idle USDC: the four mints plus the $10 seed");
        assertEq(
            queue.availableLiquidity(),
            300_000_500_000_000_000_000_000,
            "budget is exactly 5% of idle USDC per heartbeat"
        );

        uint256 epochsRun;
        while (queue.head() < queue.totalRequests()) {
            _warpToSettleable();
            _settleAndAssertFifo(true);
            epochsRun++;
            assertLt(epochsRun, 12, "queue drained in a bounded number of heartbeats");
        }
        assertGe(epochsRun, 3, "the drain genuinely spanned MULTIPLE epochs");
        assertEq(epochsRun, 4, "exactly four heartbeats at 5%/heartbeat of ~6.001m idle");

        // every request fully filled, in order, nothing left queued
        assertEq(queue.head(), 5, "head reached the tail");
        assertEq(queue.totalQueuedShares(), 0, "no shares left in queue custody");
        assertEq(vault.balanceOf(address(queue)), 0, "queue holds no shares once drained");
        for (uint256 i = 0; i < 5; ++i) {
            (, uint256 rem, uint256 claimable,,) = queue.request(i);
            assertEq(rem, 0, "every request fully filled");
            assertGt(claimable, 0, "every request has assets to claim");
        }

        // each owner claims exactly what the queue holds for them
        uint256 totalClaimed;
        totalClaimed += _claimAndAssert(0, alice);
        totalClaimed += _claimAndAssert(1, bob);
        totalClaimed += _claimAndAssert(2, ops);
        totalClaimed += _claimAndAssert(3, dave);
        totalClaimed += _claimAndAssert(4, alice);
        assertEq(usdfr.balanceOf(address(queue)), 0, "queue custody emptied by the claims");
        assertApproxEqAbs(totalClaimed, 1_000_000e18, 10, "the queue returned the staked principal");
        _assertCustody("after every claim");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. PARTIAL HEAD FILL carried across epochs, with EXACT arithmetic
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A request larger than one heartbeat's budget fills in exact budget-sized
    ///         slices; the head does NOT advance until it is complete, and the request
    ///         behind it stays untouched (FIFO under a partial head).
    function test_fork_queue_partialHeadFillCarriesAcrossEpochsWithExactArithmetic() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        _mintFromUSDC(bob, 200_000e6);
        uint256 shA = _stake(alice, 100_000e18);
        uint256 shB = _stake(bob, 50_000e18);
        uint256 idA = _requestFrom(alice, shA);
        uint256 idB = _requestFrom(bob, shB);

        // the shipped daily budget: 167bps of 1,200,010e18 idle == 20,040.167e18 per heartbeat,
        // against a 100,000e18 head — so the head must carry across several epochs
        (, uint16 bps) = queue.epochParams();
        assertEq(bps, Config.DEFAULT_EPOCH_LIQUIDITY_BPS, "running at the shipped daily budget");
        assertEq(reserves.idleReserve(), 1_200_010e18, "idle USDC: both mints plus the $10 seed");
        assertEq(queue.availableLiquidity(), 20_040_167_000_000_000_000_000, "20,040.167 USDfr per heartbeat");

        uint256 rounds;
        uint256 cumulative;
        while (true) {
            _warpToSettleable();
            (uint256 filled, bool lastRound) = _settleHeadSliceExact(idA, idB, shB);
            cumulative += filled;
            rounds++;
            if (lastRound) break;
            assertLt(rounds, 20, "the carry terminates");
        }

        assertGe(rounds, 4, "the head genuinely carried across MULTIPLE epochs");
        assertEq(rounds, 5, "100,000e18 at 20,040.167e18 per heartbeat drains in exactly five heartbeats");
        (, uint256 remFinal, uint256 claimFinal,,) = queue.request(idA);
        assertEq(remFinal, 0, "head fully filled at last");
        assertEq(claimFinal, cumulative, "claimable is the exact sum of every slice");
        assertEq(queue.head(), idB, "head advanced exactly one place once complete");
        assertGt(cumulative, 0, "value was actually delivered");
        _assertCustody("after the head completed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. CHUNKED closeEpoch == ONE BIG CALL (state-snapshot differential)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The permissionless chunked settlement is a pure gas-shape choice: settling in
    ///         three chunks of two must leave the system in the byte-identical state as one
    ///         `closeEpoch(100)`. Proven by running BOTH from the same state snapshot and
    ///         comparing every observable.
    function test_fork_queue_chunkedCloseEpochEqualsOneBigCall() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        _mintFromUSDC(dave, 2_000_000e6);
        uint256 shA = _stake(alice, 120_000e18);
        uint256 shB = _stake(bob, 90_000e18);
        uint256 shD = _stake(dave, 60_000e18);
        _requestFrom(alice, shA / 2);
        _requestFrom(bob, shB / 2);
        _requestFrom(dave, shD / 2);
        _requestFrom(alice, shA - shA / 2);
        _requestFrom(bob, shB - shB / 2);
        _requestFrom(dave, shD - shD / 2);
        assertEq(queue.totalRequests(), 6, "six requests to chunk through");

        queue.setEpochLiquidityBps(10_000); // budget covers the whole queue
        _warpToSettleable();
        uint256 ts = block.timestamp;
        uint256 bn = block.number;
        uint256 snapshotBudget = queue.availableLiquidity();

        uint256 snap = vm.snapshotState();

        // ── path A: three chunks of two ──────────────────────────────────
        queue.closeEpoch(2);
        assertTrue(queue.isSettling(), "settlement LATCHES open across chunks");
        assertEq(queue.currentEpoch(), 1, "the epoch does not advance mid-settlement");
        assertEq(queue.head(), 2, "chunk 1 processed exactly maxRequests");
        uint256 budgetAfterChunk1 = queue.settlementBudgetRemaining();
        assertLt(budgetAfterChunk1, snapshotBudget, "the budget is spent down, not re-snapshotted");
        assertEq(
            budgetAfterChunk1 + usdfr.balanceOf(address(queue)),
            snapshotBudget,
            "budget remaining + distributed == the snapshot, exactly"
        );
        _assertCustody("mid chunked settlement");

        queue.closeEpoch(2);
        assertTrue(queue.isSettling(), "still latched after chunk 2");
        assertEq(queue.head(), 4, "chunk 2 processed exactly maxRequests");

        queue.closeEpoch(2);
        assertFalse(queue.isSettling(), "the drained queue completed the settlement");
        assertEq(queue.head(), 6, "all six filled");
        assertEq(queue.currentEpoch(), 2, "epoch advanced exactly once for the whole settlement");

        uint256[6] memory remA;
        uint256[6] memory claimA;
        for (uint256 i = 0; i < 6; ++i) {
            (, remA[i], claimA[i],,) = queue.request(i);
        }
        uint256 epochEndsA = queue.epochEndsAt();
        uint256 queuedSharesA = queue.totalQueuedShares();
        uint256 queueUsdfrA = usdfr.balanceOf(address(queue));
        uint256 queueSharesA = vault.balanceOf(address(queue));
        uint256 supplyA = vault.totalSupply();
        uint256 assetsA = vault.totalAssets();
        uint256 rateA = vault.currentExchangeRate();

        // ── path B: one big call from the identical starting state ───────
        assertTrue(vm.revertToState(snap), "state reverted for the differential");
        vm.warp(ts); // block env restored explicitly so the two paths are comparable
        vm.roll(bn);
        assertEq(queue.head(), 0, "back at the pre-settlement state");
        assertEq(queue.availableLiquidity(), snapshotBudget, "same starting liquidity");

        queue.closeEpoch(100);

        assertFalse(queue.isSettling(), "one call completed the settlement");
        for (uint256 i = 0; i < 6; ++i) {
            (, uint256 rem, uint256 claimable,,) = queue.request(i);
            assertEq(rem, remA[i], "DIFFERENTIAL: sharesRemaining identical to the chunked run");
            assertEq(claimable, claimA[i], "DIFFERENTIAL: assetsClaimable identical to the chunked run");
        }
        assertEq(queue.head(), 6, "DIFFERENTIAL: head identical");
        assertEq(queue.currentEpoch(), 2, "DIFFERENTIAL: epoch identical");
        assertEq(uint256(queue.epochEndsAt()), epochEndsA, "DIFFERENTIAL: next epoch end identical");
        assertEq(queue.totalQueuedShares(), queuedSharesA, "DIFFERENTIAL: queued shares identical");
        assertEq(usdfr.balanceOf(address(queue)), queueUsdfrA, "DIFFERENTIAL: queue USDfr identical");
        assertEq(vault.balanceOf(address(queue)), queueSharesA, "DIFFERENTIAL: queue shares identical");
        assertEq(vault.totalSupply(), supplyA, "DIFFERENTIAL: vault supply identical");
        assertEq(vault.totalAssets(), assetsA, "DIFFERENTIAL: vault assets identical");
        assertEq(vault.currentExchangeRate(), rateA, "DIFFERENTIAL: exchange rate identical");
        assertLe(queueUsdfrA, snapshotBudget, "never distributed above the snapshot budget");
        _assertCustody("after the single-call settlement");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. BUDGET SNAPSHOT — exact `EpochClosed` numbers, never overshot
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The settlement budget is snapshotted at the first chunk and reported exactly:
    ///         `EpochClosed(epoch, budget, distributed, nextEnd)` where `budget` is the
    ///         snapshot and `distributed <= budget` always. Run at a deliberately tiny
    ///         governance share so the ceiling BINDS.
    function test_fork_queue_epochClosedReportsSnapshotBudgetAndNeverOvershoots() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 400_000e18);
        uint256 id = _requestFrom(alice, shA);

        queue.setEpochLiquidityBps(1); // 0.01% — a hard, binding ceiling
        _warpToSettleable();

        uint256 budget = queue.availableLiquidity();
        assertEq(reserves.idleReserve(), 1_000_010e18, "idle USDC: alice's mint plus the $10 seed");
        assertEq(budget, reserves.idleReserve() * 1 / Config.BPS, "budget is the configured share of idle stables");
        assertEq(budget, 100_001_000_000_000_000_000, "0.01% of 1,000,010 USDfr == 100.001 USDfr");
        uint256 fillShares = vault.convertToSharesAtRedemption(budget);
        uint256 expAssets = vault.previewRedeem(fillShares);
        assertLe(expAssets, budget, "the previewed fill cannot exceed the budget, by construction");
        uint64 nextEnd = uint64(block.timestamp) + Config.DEFAULT_EPOCH_DURATION;

        vm.expectEmit(true, false, false, true, address(queue));
        emit IRedemptionQueue.RequestFilled(id, fillShares, expAssets, 1);
        vm.expectEmit(true, false, false, true, address(queue));
        emit IRedemptionQueue.EpochClosed(1, budget, expAssets, nextEnd);
        queue.closeEpoch(10);

        (, uint256 rem, uint256 claimable,,) = queue.request(id);
        assertEq(claimable, expAssets, "credited exactly the previewed assets");
        assertEq(rem, shA - fillShares, "burned exactly the budgeted shares");
        assertEq(queue.head(), id, "partial head: no advance");
        assertEq(uint256(queue.epochEndsAt()), nextEnd, "the heartbeat restarted from now");
        assertLe(claimable, budget, "BUDGET CEILING: distributed <= snapshot");
        assertLe(budget - claimable, 1, "and the snapshot was spent down to rounding dust");
        _assertCustody("after the budget-capped settlement");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. ZERO-LIQUIDITY EPOCH — must not burn the heartbeat
    // ─────────────────────────────────────────────────────────────────────

    /// @notice AUDIT REGRESSION (A1, permissionless DoS) on the REAL stack: with every
    ///         stable in the treasury deployed into facilities, a settlement snapshots a
    ///         zero budget, reverts `Queue_NoLiquidity`, and does NOT consume the epoch —
    ///         otherwise anyone starves the sole sUSDfr exit by resetting the clock.
    ///         Liquidity returning via a real repayment settles the SAME epoch.
    function test_fork_queue_zeroLiquidityEpochRevertsAndDoesNotBurnHeartbeat() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 500_000e18);
        uint256 id = _requestFrom(alice, shA);

        // Deploy every USDC unit the treasury accounts for, including the locked 10 USDC seed.
        // Zero origination fee so the full principal actually leaves the treasury.
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, 0);
        uint256 usdcIdle = reserves.idleReserve();
        assertEq(usdcIdle, 1_000_010e18, "alice's USDC plus the locked seed is idle");

        uint256 usdcFacility = _originateAndFundWith(Config.CLASS_FILM_TAX_CREDITS, usdcIdle, usdcIdle / 1e12);

        assertEq(reserves.idleReserve(), 0, "every stable is deployed; nothing idle");
        assertEq(queue.availableLiquidity(), 0, "zero distributable liquidity");

        _warpToSettleable();
        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);

        assertEq(queue.currentEpoch(), epochBefore, "the epoch is NOT consumed by an empty settlement");
        assertEq(queue.epochEndsAt(), endsBefore, "the heartbeat clock is NOT reset");
        assertFalse(queue.isSettling(), "the abandoned settlement did not latch open");
        assertEq(queue.settlementBudgetRemaining(), 0, "no budget left behind");
        (, uint256 remStill, uint256 claimStill,,) = queue.request(id);
        assertEq(remStill, shA, "the position is untouched");
        assertEq(claimStill, 0, "nothing settled");
        _assertCustody("after the zero-liquidity settlement");

        // repeat attempts keep failing the same way — no state drift, no clock creep
        vm.expectRevert(IRedemptionQueue.Queue_NoLiquidity.selector);
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), epochBefore, "still not consumed after a second attempt");
        assertEq(queue.epochEndsAt(), endsBefore, "clock still untouched");

        // liquidity returns via a REAL repayment; the same epoch now settles
        _repay(usdcFacility, 0, usdcIdle);
        assertEq(reserves.idleReserve(), usdcIdle, "principal returned to the treasury");
        queue.setEpochLiquidityBps(10_000);
        uint256 budget = queue.availableLiquidity();
        assertEq(budget, usdcIdle, "the full returned principal is distributable");

        // PERMISSIONLESS: an unprivileged, non-KYC'd address settles the epoch
        // AUDIT FIX (D7-01): closeEpoch is keeper-gated. The fork harness itself holds
        // SETTLEMENT_KEEPER_ROLE (Deploy grants it to c.queueKeeper == c.deployer), so this
        // call needs no prank. It previously pranked an outsider to show settlement was
        // permissionless; that property is deliberately gone.
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(id);
        assertEq(rem, 0, "filled in full once liquidity returned");
        assertGt(claimable, 0, "assets credited");
        assertLe(claimable, budget, "still bounded by the snapshot");
        assertEq(queue.currentEpoch(), epochBefore + 1, "NOW the epoch advances: a real settlement happened");
        _assertCustody("after liquidity returned");
        assertEq(_claimAndAssert(id, alice), claimable, "claimable in full");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. STAGGERED ELIGIBILITY — cooldown gate, order, heartbeat accounting
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ADR-0022: three requests made five days apart become eligible five days apart
    ///         and settle in exactly that order. While EVERY request is still held,
    ///         `closeEpoch` reverts `Queue_AllInCooldown(headEligibleAt)` without consuming
    ///         the heartbeat. Once the head is eligible but the NEXT is not, the settlement
    ///         fills the head and closes normally (it distributed > 0), leaving the rest.
    function test_fork_queue_staggeredEligibilitySettlesInStrictOrder() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        queue.setEpochLiquidityBps(10_000); // budget is never the binding constraint here

        uint256 shA = _stake(alice, 100_000e18);
        uint256 t0 = block.timestamp;
        uint256 id0 = _requestFrom(alice, shA);

        _warp(5 days);
        uint256 shB = _stake(bob, 80_000e18);
        uint256 id1 = _requestFrom(bob, shB);

        _warp(5 days);
        uint256 shA2 = _stake(alice, 60_000e18);
        uint256 id2 = _requestFrom(alice, shA2);

        assertEq(queue.eligibleToSettleAt(id0), t0 + Config.DEFAULT_REDEEM_COOLDOWN, "r0 eligibility exact");
        assertEq(queue.eligibleToSettleAt(id1), t0 + 5 days + Config.DEFAULT_REDEEM_COOLDOWN, "r1 eligibility exact");
        assertEq(queue.eligibleToSettleAt(id2), t0 + 10 days + Config.DEFAULT_REDEEM_COOLDOWN, "r2 eligibility exact");

        // ── every request still held: revert, heartbeat untouched ────────
        vm.warp(t0 + Config.DEFAULT_REDEEM_COOLDOWN - 1);
        uint256 epochBefore = queue.currentEpoch();
        uint64 endsBefore = queue.epochEndsAt();
        assertLt(block.timestamp, queue.eligibleToSettleAt(id0), "one second inside the hold");
        vm.expectRevert(
            abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, t0 + Config.DEFAULT_REDEEM_COOLDOWN)
        );
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), epochBefore, "AllInCooldown does not consume the heartbeat");
        assertEq(queue.epochEndsAt(), endsBefore, "AllInCooldown does not reset the clock");
        assertFalse(queue.isSettling());
        _assertCustody("while every request is held");

        // ── head eligible, the rest not: fills the head, closes normally ─
        vm.warp(t0 + Config.DEFAULT_REDEEM_COOLDOWN);
        queue.closeEpoch(10);
        assertEq(_rem(id0), 0, "r0 settled at EXACTLY requestedAt + cooldown");
        assertGt(_claimable(id0), 0, "r0 credited");
        assertEq(_rem(id1), shB, "r1 untouched: still inside its own hold");
        assertEq(_claimable(id1), 0, "r1 credited nothing");
        assertEq(_rem(id2), shA2, "r2 untouched");
        assertEq(_claimable(id2), 0, "r2 credited nothing");
        assertEq(queue.head(), id1, "head advanced to the still-cooling request");
        assertEq(queue.currentEpoch(), epochBefore + 1, "a settlement that DISTRIBUTED closes its epoch");
        assertFalse(queue.isSettling(), "and did not latch open behind the cooldown");
        _assertCustody("after r0 settled");

        // r1 is now the head and still cooling: back to the no-heartbeat-burn branch
        epochBefore = queue.currentEpoch();
        endsBefore = queue.epochEndsAt();
        vm.warp(uint256(endsBefore) + 1);
        assertLt(block.timestamp, queue.eligibleToSettleAt(id1), "heartbeat lapsed while r1 is still held");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRedemptionQueue.Queue_AllInCooldown.selector, t0 + 5 days + Config.DEFAULT_REDEEM_COOLDOWN
            )
        );
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), epochBefore, "heartbeat still not burned");
        assertEq(queue.epochEndsAt(), endsBefore, "clock still untouched");

        // ── r1 then r2, each at its own eligibility, in order ────────────
        vm.warp(t0 + 5 days + Config.DEFAULT_REDEEM_COOLDOWN);
        queue.closeEpoch(10);
        assertEq(_rem(id1), 0, "r1 settled at its own eligibility");
        assertGt(_claimable(id1), 0, "r1 credited");
        assertEq(_rem(id2), shA2, "r2 STILL untouched: order preserved");
        assertEq(_claimable(id2), 0, "r2 credited nothing");
        assertEq(queue.head(), id2, "head advanced to r2");

        vm.warp(t0 + 10 days + Config.DEFAULT_REDEEM_COOLDOWN);
        queue.closeEpoch(10);
        assertEq(_rem(id2), 0, "r2 settled last");
        assertGt(_claimable(id2), 0, "r2 credited");
        assertEq(queue.head(), 3, "queue drained in strict request order");
        _assertCustody("after the staggered drain");

        _claimAndAssert(id0, alice);
        _claimAndAssert(id1, bob);
        _claimAndAssert(id2, alice);
        assertEq(usdfr.balanceOf(address(queue)), 0, "every staggered request claimed in full");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. CLAIM — anytime after a fill, exactly once, and only by the owner
    // ─────────────────────────────────────────────────────────────────────

    /// @notice §1.3 (no double-claim): a partial fill is claimable immediately, a later
    ///         fill is claimable long afterwards, and a claimed amount can never be
    ///         claimed twice. Ends with the full exit: claimed USDfr redeemed to real USDC.
    function test_fork_queue_claimAnytimeAfterFillAndNeverTwice() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 300_000e18);
        uint256 id = _requestFrom(alice, shA);

        // nothing filled yet: claiming must fail loudly
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);

        // ── epoch 1: partial fill, claimed immediately ───────────────────
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 remAfter1, uint256 claim1,,) = queue.request(id);
        assertGt(remAfter1, 0, "only partially filled at the daily budget");
        assertGt(claim1, 0, "there is something to claim");

        uint256 balBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got1 = queue.claim(id);
        assertEq(got1, claim1, "claim returns exactly the filled amount");
        assertEq(usdfr.balanceOf(alice) - balBefore, claim1, "and transfers exactly that");
        (,, uint256 claimableAfter,,) = queue.request(id);
        assertEq(claimableAfter, 0, "claimable zeroed");
        assertEq(usdfr.balanceOf(address(queue)), 0, "queue custody emptied");

        // NO DOUBLE CLAIM
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);
        _assertCustody("after the first claim");

        // ── epoch 2: another fill, left UNCLAIMED for 90 days ────────────
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 remAfter2, uint256 claim2,,) = queue.request(id);
        assertGt(claim2, 0, "a second slice filled");
        assertLt(remAfter2, remAfter1, "and consumed more shares");
        _assertCustody("with an unclaimed fill outstanding");

        _warp(90 days); // "claim anytime": there is no claim deadline
        // a wrong caller can never take it
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, bob));
        queue.claim(id);

        uint256 balBefore2 = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got2 = queue.claim(id);
        assertEq(got2, claim2, "claimed the full second slice 90 days later");
        assertEq(usdfr.balanceOf(alice) - balBefore2, claim2, "exact transfer");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);
        _assertCustody("after the delayed claim");

        // ── the full exit: claimed USDfr back to REAL USDC ───────────────
        uint256 exit = 1_000e18;
        uint256 usdcBefore = usdc(alice);
        vm.startPrank(alice);
        usdfr.approve(address(controller), exit);
        uint256 usdcOut = controller.redeem(exit);
        vm.stopPrank();
        assertEq(usdcOut, 1_000e6, "18-dec USDfr denormalizes to 6-dec USDC");
        assertEq(usdc(alice) - usdcBefore, usdcOut, "real USDC delivered");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds after the exit");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. MID-SETTLEMENT JOIN (documented behaviour, only reachable at cooldown 0)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The contract header states: "Requests joining mid-settlement queue behind the
    ///         current tail and are eligible within the same settlement if budget remains
    ///         (still strictly FIFO)." Under the SHIPPED 21-day cooldown that is unreachable
    ///         — a brand-new request is always inside its hold — so this pins the claim in
    ///         the only state where it can hold: cooldown disabled by governance (a
    ///         deliberate, evented act per ADR-0022).
    function test_fork_queue_midSettlementJoinServedInSameSettlementWhenCooldownDisabled() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        _mintFromUSDC(dave, 2_000_000e6);
        uint256 shA = _stake(alice, 100_000e18);
        uint256 shD = _stake(dave, 70_000e18);
        uint256 shB = _stake(bob, 80_000e18);

        queue.setEpochLiquidityBps(10_000);
        queue.setRedeemCooldown(0);
        assertEq(queue.redeemCooldown(), 0, "hold disabled for this scenario");

        // TWO requests up front: a settlement only LATCHES open when it stops at
        // `maxRequests` with the queue not yet drained. (With a single request,
        // `closeEpoch(1)` drains the queue and closes the epoch in the same call.)
        _requestFrom(alice, shA);
        _requestFrom(dave, shD);
        _warpToSettleable();

        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "settlement latched open at maxRequests");
        assertEq(queue.currentEpoch(), 1, "epoch not yet advanced");
        assertEq(queue.head(), 1, "r0 filled, r1 still queued");
        assertGt(queue.settlementBudgetRemaining(), 0, "budget remains for a joiner");

        // bob joins DURING the open settlement: behind the tail, stamped with epoch 1
        uint256 idJoin = _requestFrom(bob, shB);
        assertEq(idJoin, 2, "the joiner takes the tail slot: it never jumps the queue");
        (,,, uint256 epochRequested,) = queue.request(idJoin);
        assertEq(epochRequested, 1, "the joiner is stamped with the still-open epoch");
        assertEq(queue.totalQueuedShares(), shD + shB, "both pending positions in custody");

        // next chunk serves the PRE-EXISTING r1 (FIFO), and the settlement stays latched
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "still the same settlement");
        assertEq(queue.currentEpoch(), 1, "still epoch 1");
        assertEq(queue.head(), 2, "r1 filled before the joiner: strict FIFO");
        assertEq(_rem(idJoin), shB, "the joiner is still untouched at this point");

        // and now the joiner itself, inside the SAME settlement
        uint256 budgetLeft = queue.settlementBudgetRemaining();
        uint256 expAssets = vault.previewRedeem(shB);
        vm.expectEmit(true, false, false, true, address(queue));
        emit IRedemptionQueue.RequestFilled(idJoin, shB, expAssets, 1);
        queue.closeEpoch(1);

        assertEq(_rem(idJoin), 0, "the mid-settlement joiner was served in the SAME settlement");
        assertEq(_claimable(idJoin), expAssets, "at exactly the previewed conservative redemption value");
        assertEq(queue.currentEpoch(), 2, "settlement completed once the queue drained");
        assertFalse(queue.isSettling(), "and unlatched");
        assertLe(expAssets, budgetLeft, "still bounded by the remaining snapshot budget");
        _assertCustody("after the mid-settlement join");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. EXCHANGE-RATE MONOTONICITY under sustained queue traffic
    // ─────────────────────────────────────────────────────────────────────

    /// @notice §1.3 (sUSDfr exchange-rate monotonicity): queue traffic — requests, partial
    ///         fills, full fills and claims — must never lower the rate. Redemptions price
    ///         at the floor-rounded conservative NAV, so each fill can only leave dust
    ///         BEHIND in the vault; the rate is non-decreasing at every single step.
    function test_fork_queue_exchangeRateNeverFallsFromQueueTraffic() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        _mintFromUSDC(dave, 1_000_000e6);

        uint256 rate = vault.currentExchangeRate();
        uint256 shA = _stake(alice, 300_000e18);
        rate = _assertRateNotFalling(rate, "stake alice");
        uint256 shB = _stake(bob, 200_000e18);
        rate = _assertRateNotFalling(rate, "stake bob");
        uint256 shD = _stake(dave, 100_000e18);
        rate = _assertRateNotFalling(rate, "stake dave");

        // no impairment is declared anywhere in this test, so exit and entry NAV coincide
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "no impairment: exit NAV == entry NAV");

        uint256 id0 = _requestFrom(alice, shA);
        rate = _assertRateNotFalling(rate, "request alice");
        uint256 id1 = _requestFrom(bob, shB);
        rate = _assertRateNotFalling(rate, "request bob");
        uint256 id2 = _requestFrom(dave, shD);
        rate = _assertRateNotFalling(rate, "request dave");

        queue.setEpochLiquidityBps(300);
        uint256 loops;
        while (queue.head() < queue.totalRequests()) {
            _warpToSettleable();
            queue.closeEpoch(50);
            rate = _assertRateNotFalling(rate, "settlement");
            _assertCustody("mid rate-monotonicity drain");
            // claim opportunistically so claims are interleaved with fills
            (,, uint256 c0,,) = queue.request(id0);
            if (c0 > 0) {
                vm.prank(alice);
                queue.claim(id0);
                rate = _assertRateNotFalling(rate, "claim alice");
            }
            loops++;
            assertLt(loops, 25, "the drain terminates");
        }
        assertGe(loops, 3, "the rate was checked across MULTIPLE settlements");

        _claimAndAssert(id1, bob);
        rate = _assertRateNotFalling(rate, "claim bob");
        _claimAndAssert(id2, dave);
        rate = _assertRateNotFalling(rate, "claim dave");

        assertGe(rate, 10 ** vault.decimals() / 1e6, "rate stayed sane");
        assertEq(vault.balanceOf(address(queue)), 0, "queue holds no residual shares");
        assertEq(usdfr.balanceOf(address(queue)), 0, "queue holds no residual USDfr");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. NEGATIVE PATHS + PAUSE, on the deployed stack
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Every guard on the live queue, asserted against its SPECIFIC custom error.
    function test_fork_queue_negativePathsAndPause() public onFork {
        _mintFromUSDC(alice, 500_000e6);
        uint256 shA = _stake(alice, 100_000e18);

        // zero-size request
        vm.prank(alice);
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAmount.selector);
        queue.requestRedeem(0);

        // sub-$1 request (AUDIT N-1, widened by the C-1 anti-dust-wedge entry floor,
        // owner-approved 2026-07-22): 1 share redeems to 0 assets under the offset-6 vault, far
        // below the $1 `minRedemptionValue` floor, so it is barred at entry. The old
        // `Queue_DustRequest` gate (exactly-zero only) was replaced by `Queue_BelowMinRedemption`.
        assertEq(vault.convertToAssets(1), 0, "1 share is worth nothing");
        vm.startPrank(alice);
        vault.approve(address(queue), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, 0, queue.minRedemptionValue())
        );
        queue.requestRedeem(1);
        vm.stopPrank();

        // settlement guards
        uint64 endsAt = queue.epochEndsAt();
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_EpochNotOver.selector, endsAt));
        queue.closeEpoch(10);
        _warp(uint256(endsAt) - block.timestamp + 1);
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAmount.selector);
        queue.closeEpoch(0);

        // views fail loudly on an unknown id
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 0));
        queue.request(0);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 0));
        queue.eligibleToSettleAt(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 0));
        queue.claim(0);

        // governance bounds and access control
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setEpochDuration(0);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setEpochLiquidityBps(0);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setEpochLiquidityBps(uint16(Config.BPS) + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        queue.setEpochLiquidityBps(5_000);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        queue.setRedeemCooldown(0);

        // a real request, so the pause paths have something to act on
        uint256 id = _requestFrom(alice, shA);

        // guardian pause blocks request and settlement, but claim itself remains reachable.
        // This request has not settled yet, so it has nothing claimable.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        queue.pause();
        queue.pause();
        vm.startPrank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.requestRedeem(1e18);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);
        vm.stopPrank();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.closeEpoch(10);
        queue.unpause();

        // and the queue is the vault's SOLE exit: a direct redeem is refused
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1e18, alice, alice);
        assertEq(vault.maxRedeem(alice), 0, "no instant exit for a holder");
        assertEq(vault.maxWithdraw(alice), 0, "no instant withdraw for a holder");

        // after the cooldown the same request settles normally — the guards blocked nothing real
        _warpToSettleable();
        queue.closeEpoch(10);
        (,, uint256 claimable,,) = queue.request(id);
        assertGt(claimable, 0, "the request settles once its gates are satisfied");
        _assertCustody("after the negative-path pass");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. LATCHED SETTLEMENT — live re-cap when liquidity really drains
    // ─────────────────────────────────────────────────────────────────────

    /// @notice AUDIT FIX (H-04, red-team #1) on the real stack, with a REALISTIC cause: a
    ///         chunked settlement latches `settling` open across transactions, and between
    ///         two chunks the treasury deploys capital into a facility. The stale-high
    ///         snapshot budget must NOT be spendable — every chunk re-caps the remaining
    ///         budget at the LIVE `availableLiquidity()`, and the shrink PERSISTS.
    ///
    ///         The persistence half is what TWO post-drain requests discriminate: settlement
    ///         pays USDfr from the vault and consumes NO stable liquidity, so `liveCap` reads
    ///         the SAME number for every request in the chunk. If the cap were applied as a
    ///         per-fill `min()` instead of shrinking the stored budget, each of the two
    ///         requests could spend up to the full live cap and the settlement would
    ///         distribute ~250,000e18 against 201,000e18 of live liquidity. It must not.
    ///         Also pins that a guardian pause mid-settlement freezes the latch intact.
    function test_fork_queue_latchedSettlementReCapsWhenCapitalIsDeployedMidSettlement() public onFork {
        _mintFromUSDC(alice, 1_200_000e6);
        uint256 shA = _stake(alice, 1_000_000e18);
        uint256 id0 = _requestFrom(alice, shA * 75 / 100); // ~750,000e18
        uint256 id1 = _requestFrom(alice, shA * 10 / 100); // ~100,000e18
        uint256 id2 = _requestFrom(alice, shA - shA * 75 / 100 - shA * 10 / 100); // ~150,000e18

        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        uint256 snapshotBudget = queue.availableLiquidity();
        assertEq(snapshotBudget, 1_200_010e18, "the whole idle USDC pool is the snapshot budget");

        // chunk 1: fills id0, stops at maxRequests -> the settlement LATCHES open
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "settlement latched open");
        assertEq(_rem(id0), 0, "id0 fully filled in chunk 1");
        uint256 staleBudget = queue.settlementBudgetRemaining();
        assertEq(staleBudget, snapshotBudget - _claimable(id0), "the snapshot budget carries, undiminished");
        assertGt(staleBudget, 400_000e18, "and is far larger than what liquidity will support");

        // a guardian pause mid-settlement must freeze the latch, not corrupt it
        queue.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.closeEpoch(10);
        assertTrue(queue.isSettling(), "the latch survives a pause");
        assertEq(queue.settlementBudgetRemaining(), staleBudget, "and the budget is untouched by it");
        queue.unpause();

        // BETWEEN CHUNKS the treasury deploys 1,000,000e18 into a real facility, so the
        // live stable liquidity collapses far below the latched snapshot
        waterfall.setOriginationFee(Config.CLASS_FILM_TAX_CREDITS, 0);
        _originateAndFundWith(Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18, 1_000_000e6);
        uint256 liveCap = queue.availableLiquidity();
        assertEq(liveCap, 200_010e18, "live liquidity is the residual USDC plus the $10 seed");
        assertLt(liveCap, staleBudget, "the latched snapshot is now stale-HIGH");

        // chunk 2: id1 fills in full (it fits under the live cap), id2 gets only what is
        // LEFT of that same cap — the two fills SHARE it, they do not each get it.
        uint256 expId1 = vault.previewRedeem(_rem(id1));
        assertLt(expId1, liveCap, "id1 alone fits under the live cap");
        queue.closeEpoch(10);

        assertEq(_claimable(id1), expId1, "id1 filled in full at the previewed value");
        assertEq(_rem(id1), 0, "id1 completed");
        assertGt(_claimable(id2), 0, "id2 got the remainder of the cap");
        assertGt(_rem(id2), 0, "but could NOT be completed from a stale-high budget");
        // THE DISCRIMINATOR: both post-drain fills came out of ONE live cap. A per-fill
        // `min(budget, liveCap)` would have let each of them spend up to 201,000e18
        // (~250,000e18 total, id2 completing in full) against 201,000e18 of live liquidity.
        uint256 distributedAfterDrain = _claimable(id1) + _claimable(id2);
        assertLe(distributedAfterDrain, liveCap, "the LIVE cap is CUMULATIVE across the rest of the settlement");
        assertLe(liveCap - distributedAfterDrain, 1, "and was spent down to rounding dust, exactly once");
        assertEq(queue.head(), id2, "partial head: no advance past id2");
        assertFalse(queue.isSettling(), "settlement completed on the budget running out");
        assertEq(queue.currentEpoch(), 2, "and the epoch advanced exactly once");
        _assertCustody("after the re-capped settlement");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this suite — see the contract-level @dev note)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Queue `shares` for `who`, approving out of their own balance.
    function _requestFrom(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    /// @dev Claim `id` for `owner` and assert the transfer is exactly the claimable amount
    ///      and that a second claim is refused.
    function _claimAndAssert(uint256 id, address owner) internal returns (uint256 assets) {
        (,, uint256 claimable,,) = queue.request(id);
        uint256 before = usdfr.balanceOf(owner);
        vm.prank(owner);
        assets = queue.claim(id);
        assertEq(assets, claimable, "claim returns the exact claimable amount");
        assertEq(usdfr.balanceOf(owner) - before, claimable, "claim transfers the exact claimable amount");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);
    }

    /// @dev Shares still queued on `id` (accessor, so callers keep a shallow stack).
    function _rem(uint256 id) internal view returns (uint256 remaining) {
        (, remaining,,,) = queue.request(id);
    }

    /// @dev Filled-but-unclaimed USDfr on `id`.
    function _claimable(uint256 id) internal view returns (uint256 claimable) {
        (,, claimable,,) = queue.request(id);
    }

    /// @dev CUSTODY RECONCILIATION (asserted after every stage of every test above):
    ///      the queue's sUSDfr balance equals the sum of unfilled shares, and its USDfr
    ///      balance equals the sum of filled-but-unclaimed assets. Nothing is stranded and
    ///      nothing is over-held.
    function _assertCustody(string memory tag) internal view {
        uint256 n = queue.totalRequests();
        uint256 shares;
        uint256 claimable;
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 rem, uint256 claim,,) = queue.request(i);
            shares += rem;
            claimable += claim;
        }
        assertEq(queue.totalQueuedShares(), shares, string.concat(tag, ": totalQueuedShares == sum sharesRemaining"));
        assertEq(vault.balanceOf(address(queue)), shares, string.concat(tag, ": queue sUSDfr == sum queued"));
        assertEq(usdfr.balanceOf(address(queue)), claimable, string.concat(tag, ": queue USDfr == sum unclaimed"));
    }

    /// @dev One settlement plus the whole assertion battery: FIFO (everything before the head
    ///      fully filled, everything after it untouched), the budget ceiling, epoch/latch
    ///      bookkeeping, custody, and rate monotonicity.
    /// @param budgetLimited True when the caller knows the settlement is budget-bound (so an
    ///        incomplete drain must have spent the snapshot down to dust).
    function _settleAndAssertFifo(bool budgetLimited) internal {
        uint256 n = queue.totalRequests();
        uint256[] memory remBefore = new uint256[](n);
        uint256[] memory claimBefore = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            (, remBefore[i], claimBefore[i],,) = queue.request(i);
        }
        uint256 budget = queue.availableLiquidity();
        uint256 epochBefore = queue.currentEpoch();
        uint256 headBefore = queue.head();
        uint256 rateBefore = vault.currentExchangeRate();

        // PERMISSIONLESS: settled by `carol`, who is not KYC'd and holds no role anywhere.
        // AUDIT FIX (D7-01): closeEpoch is keeper-gated. The fork harness itself holds
        // SETTLEMENT_KEEPER_ROLE (Deploy grants it to c.queueKeeper == c.deployer), so this
        // call needs no prank. It previously pranked an outsider to show settlement was
        // permissionless; that property is deliberately gone.
        queue.closeEpoch(50);

        uint256 headAfter = queue.head();
        uint256 distributed;
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 rem, uint256 claim,,) = queue.request(i);
            distributed += claim - claimBefore[i];
            if (i < headAfter) assertEq(rem, 0, "FIFO: every request before the head is FULLY filled");
            if (i > headAfter) {
                assertEq(rem, remBefore[i], "FIFO: requests behind the head are untouched");
                assertEq(claim, claimBefore[i], "FIFO: no out-of-order fill");
            }
        }
        assertGe(headAfter, headBefore, "the head never moves backwards");
        assertLe(distributed, budget, "BUDGET CEILING: never distributes above the snapshot");
        assertEq(queue.currentEpoch(), epochBefore + 1, "a settlement that filled closes its epoch");
        assertFalse(queue.isSettling(), "settlement completed");
        assertEq(queue.settlementBudgetRemaining(), 0, "budget cleared on completion");
        assertGe(vault.currentExchangeRate(), rateBefore, "rate never falls from queue traffic");
        if (budgetLimited && headAfter < n) {
            assertLe(budget - distributed, 1, "a budget-bound epoch spends the snapshot to dust");
        }
        _assertCustody("after a settlement");
    }

    /// @dev One heartbeat of a partial-head carry, with the fill arithmetic computed BEFORE
    ///      the call and asserted exactly afterwards. Extracted from the test body only to
    ///      keep the stack shallow.
    /// @param idHead The head request (the one being sliced).
    /// @param idNext The request queued behind it (must stay untouched while the head is partial).
    /// @param nextShares `idNext`'s full share count.
    /// @return filled Assets credited to the head this heartbeat.
    /// @return lastRound True when this heartbeat completed the head.
    function _settleHeadSliceExact(uint256 idHead, uint256 idNext, uint256 nextShares)
        internal
        returns (uint256 filled, bool lastRound)
    {
        // hoisted BEFORE the call: these are the exact numbers the contract must produce
        uint256 budget = queue.availableLiquidity();
        uint256 budgetShares = vault.convertToSharesAtRedemption(budget);
        (, uint256 remBefore, uint256 claimBefore,,) = queue.request(idHead);
        lastRound = budgetShares >= remBefore;
        uint256 fillShares = lastRound ? remBefore : budgetShares;
        filled = vault.previewRedeem(fillShares);
        uint256 epochBefore = queue.currentEpoch();

        queue.closeEpoch(5);

        (, uint256 rem, uint256 claimable,,) = queue.request(idHead);
        assertEq(remBefore - rem, fillShares, "EXACTLY the budgeted share count was redeemed");
        assertEq(claimable - claimBefore, filled, "EXACTLY the previewed assets were credited");
        assertLe(claimable - claimBefore, budget, "the fill never exceeds the snapshot budget");
        assertEq(queue.currentEpoch(), epochBefore + 1, "each settlement closes its epoch");
        assertFalse(queue.isSettling(), "settlement completed");
        assertEq(queue.settlementBudgetRemaining(), 0, "budget cleared on completion");

        if (!lastRound) {
            assertEq(queue.head(), idHead, "head does NOT advance on a partial fill");
            assertGt(rem, 0, "the head carries its remainder into the next epoch");
            // the budget is spent down to at most 1 wei of rounding dust
            assertLe(budget - filled, 1, "a budget-limited epoch spends the whole snapshot");
            (, uint256 remNext, uint256 claimNext,,) = queue.request(idNext);
            assertEq(remNext, nextShares, "FIFO: the request behind an unfilled head is untouched");
            assertEq(claimNext, 0, "FIFO: no out-of-order fill while the head is partial");
        }
        _assertCustody("mid partial-fill carry");
    }

    /// @dev Warp to the earliest moment the current head can actually settle: past the
    ///      heartbeat AND past the head's ADR-0022 cooldown.
    function _warpToSettleable() internal {
        uint256 target = uint256(queue.epochEndsAt());
        uint256 h = queue.head();
        if (h < queue.totalRequests()) {
            uint256 eligibleAt = queue.eligibleToSettleAt(h);
            if (eligibleAt > target) target = eligibleAt;
        }
        if (block.timestamp < target) _warp(target - block.timestamp);
    }

    /// @dev Assert the sUSDfr exchange rate has not fallen, and return the new rate.
    function _assertRateNotFalling(uint256 previous, string memory tag) internal view returns (uint256 current) {
        current = vault.currentExchangeRate();
        assertGe(current, previous, string.concat(tag, ": exchange rate must never fall from queue traffic"));
    }

    /// @dev Originate through the REAL 2-of-n gate and fund with canonical USDC.
    function _originateAndFundWith(uint256 classId, uint256 principal18, uint256 stableUnits)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 300 days);
        ClaimBridge.OriginationTerms memory terms = _forkTermsFor(
            classId,
            keccak256("QDF_BORROWER"),
            keccak256("US-CA"),
            principal18,
            5000,
            1200,
            maturity,
            keccak256("qdf-ref")
        );
        bytes32 termsHash = bridge.creditTermsHash(terms);
        // P-32: every selected deal-identity fact commits to the exact terms.
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);

        vm.prank(ops);
        uint256 id = bridge.originate(ops, terms);
        require(id == tokenId, "queue fork: tokenId drift");

        vm.prank(ops);
        waterfall.fund(tokenId, stableUnits);
    }

    /// @dev Real-USDC balance of `who` (6-dec).
    function usdc(address who) internal view returns (uint256) {
        return IERC20Like(USDC).balanceOf(who);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
