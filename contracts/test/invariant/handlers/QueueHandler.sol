// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ComplianceRegistry} from "../../../src/ComplianceRegistry.sol";
import {IRedemptionQueue} from "../../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {RedemptionQueue} from "../../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockImpairmentSource} from "../../helpers/MockImpairmentSource.sol";

/// @dev Bounded handler for REDEMPTION QUEUE stateful fuzzing (§1.3 queue invariants).
///      `fail_on_revert = true`: every path is bounded to never revert. The
///      never-over-distributes property is asserted PER SETTLEMENT here (budget
///      snapshot mirrored at settlement start, distribution accumulated across
///      chunks); FIFO and custody properties are checked by the invariant functions.
contract QueueHandler is Test {
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ComplianceRegistry internal compliance;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    RedemptionQueue internal queue;
    /// @dev AUDIT C-1: bounded control of the ADR-0022 conservative redemption mark, so the
    ///      fuzzer actually reaches the impaired-NAV region where a settlement fill can be
    ///      worth zero. Without it the zero-value-fill invariant below would be vacuous.
    MockImpairmentSource internal impairmentSource;

    address[3] public actors;

    struct Tracked {
        address owner;
        uint256 originalShares;
        uint256 claimed;
    }

    Tracked[] public tracked; // index == requestId (we are the only requesters)

    // ── ghost state ──────────────────────────────────────────────────────
    uint256 public ghostBudget; // active settlement's snapshot
    uint256 public ghostSettlementDistributed;
    uint256 public ghostTotalFilled; // all-time assets moved into queue custody
    uint256 public ghostTotalClaimed;
    uint256 public rateFloor;
    uint256 public callCount;
    /// @dev AUDIT C-1 ghost: set if any `RequestFilled` ever carried shares > 0 with assets == 0.
    bool public sawZeroValueFill;
    /// @dev Anti-vacuity witness: settlement calls actually made while the conservative
    ///      redemption base was marked strictly below the realized base.
    uint256 public settlementsUnderImpairment;
    /// @dev C-1 ENTRY-FLOOR witness (owner-approved 2026-07-22, replaces the deferral counter):
    ///      the smallest REALIZED value at which any request was admitted. The invariant asserts
    ///      this never dips below `minRedemptionValue` — dust is barred at the source. `max`
    ///      until the first admission (vacuously satisfies the floor while the queue is empty).
    uint256 public minAdmittedEntryValue = type(uint256).max;
    // ── settlement-reach witnesses (measured, NOT asserted — anti-vacuity per the callSummary
    //    comment). They confirm the $1 entry floor did not make the interesting states
    //    unreachable: the loud C-1 stop, the budget block, positive fills, and the cooldown hold.
    uint256 public loudStops; // Queue_HeadNotRedeemable — the C-1 catastrophic-mark stop
    uint256 public noLiquidityStops; // Queue_NoLiquidity — budget/dust-tail block
    uint256 public cooldownStops; // Queue_AllInCooldown — ADR-0022 forced hold
    uint256 public positiveSettlements; // chunks that distributed > 0 assets
    uint256 public dualNavStates; // impairment updates with performance NAV below redemption NAV
    uint256 public hurdleCarryChecks; // value-moving deposit/one-exit reference checks
    bool public hurdleCarryViolation;
    /// @dev AUDIT R15-04 witness. `rateFloor` advances after EVERY action, so comparing the live
    ///      rate against it at invariant time is `assertGe(x, x)` and states nothing across calls.
    ///      The substantive check is per-call, below; this ghost carries its verdict out so the
    ///      top-level invariant asserts something the handler actually established.
    bool public sawUnexplainedRateDrop;

    struct RateSnapshot {
        uint256 rate;
        uint256 feeRate;
        uint256 highWaterMark;
        uint256 feeRecipientShares;
        uint256 lastFeeAccrual;
        uint256 observedAt;
        uint256 supply;
        uint16 performanceFeeBps;
        uint16 managementFeeBps;
    }

    constructor(
        MockERC20 usdc_,
        USDfr usdfr_,
        ComplianceRegistry compliance_,
        ReserveManager reserves_,
        MintRedeemController controller_,
        SUSDfr vault_,
        RedemptionQueue queue_,
        address complianceAdmin_,
        MockImpairmentSource impairmentSource_
    ) {
        impairmentSource = impairmentSource_;
        usdc = usdc_;
        usdfr = usdfr_;
        compliance = compliance_;
        reserves = reserves_;
        controller = controller_;
        vault = vault_;
        queue = queue_;
        actors[0] = makeAddr("queueActor0");
        actors[1] = makeAddr("queueActor1");
        actors[2] = makeAddr("queueActor2");
        vm.startPrank(complianceAdmin_);
        for (uint256 i = 0; i < 3; ++i) {
            compliance.setAllowed(actors[i], true);
        }
        vm.stopPrank();
        rateFloor = vault.currentExchangeRate();
    }

    // ── bounded operations ───────────────────────────────────────────────

    function _rateSnapshot() private view returns (RateSnapshot memory snapshot) {
        snapshot.rate = vault.currentExchangeRate();
        snapshot.feeRate = vault.feeExchangeRate();
        snapshot.highWaterMark = vault.highWaterMark();
        snapshot.feeRecipientShares = vault.balanceOf(vault.feeRecipient());
        snapshot.lastFeeAccrual = vault.lastFeeAccrual();
        snapshot.observedAt = block.timestamp;
        snapshot.supply = vault.totalSupply();
        snapshot.performanceFeeBps = vault.performanceFeeBps();
        snapshot.managementFeeBps = vault.managementFeeBps();
    }

    function _roundingBound(uint256 rateBefore) private view returns (uint256) {
        uint256 effectiveSupply = vault.totalSupply() + 1e6;
        uint256 oneShareRateImpact = Math.ceilDiv(rateBefore, effectiveSupply);
        uint256 oneAssetRateImpact = Math.ceilDiv(10 ** vault.decimals(), effectiveSupply);
        return oneShareRateImpact + oneAssetRateImpact + 2;
    }

    function _hurdleAssets() private view returns (uint256) {
        return Math.mulDiv(vault.highWaterMark(), vault.totalSupply() + 1e6, 10 ** vault.decimals(), Math.Rounding.Ceil);
    }

    /// @dev Independent ADR-0031 reference law. The expected hurdle is derived from
    ///      PRE-flow state and the actual principal/supply movement; the post-flow HWM
    ///      is only the output being checked and is never used as a legality witness.
    function _checkHurdleCarry(uint256 expectedHurdle) private {
        uint256 actualHurdle = _hurdleAssets();
        uint256 roundingDust = Math.ceilDiv(vault.totalSupply() + 1e6, 10 ** vault.decimals());
        bool valid = actualHurdle >= expectedHurdle && actualHurdle - expectedHurdle <= roundingDust;
        if (!valid) hurdleCarryViolation = true;
        assertTrue(valid, "FEE HURDLE VIOLATED THE PRE-FLOW REFERENCE LAW");
        hurdleCarryChecks++;
    }

    function _hasProtocolFeeWitness(RateSnapshot memory before_) private view returns (bool) {
        if (vault.balanceOf(vault.feeRecipient()) > before_.feeRecipientShares) return true;
        if (before_.performanceFeeBps != 0 && before_.feeRate > before_.highWaterMark) return true;
        if (vault.performanceFeeBps() != 0 && vault.feeExchangeRate() > vault.highWaterMark()) return true;
        if (
            before_.managementFeeBps != 0 && before_.supply != 0 && before_.lastFeeAccrual != 0
                && before_.observedAt > before_.lastFeeAccrual
        ) return true;
        return vault.managementFeeBps() != 0 && vault.totalSupply() != 0 && vault.lastFeeAccrual() != 0
            && block.timestamp > vault.lastFeeAccrual();
    }

    function _minimumFeeRetainedRate(RateSnapshot memory before_) private view returns (uint256 retainedRate) {
        retainedRate = before_.rate;
        uint16 managementBps = before_.managementFeeBps;
        if (vault.managementFeeBps() > managementBps) managementBps = vault.managementFeeBps();
        if (managementBps != 0 && before_.lastFeeAccrual != 0) {
            uint256 elapsed = block.timestamp - before_.lastFeeAccrual;
            uint256 annualFeeWad = Math.mulDiv(managementBps, 1e18, Config.BPS);
            uint256 elapsedYearsWad = Math.mulDiv(elapsed, 1e18, Config.MANAGEMENT_FEE_YEAR);
            uint256 retentionWad =
                uint256(FixedPointMathLib.powWad(int256(1e18 - annualFeeWad), int256(elapsedYearsWad)));
            retainedRate = Math.mulDiv(retainedRate, retentionWad, 1e18, Math.Rounding.Floor);
        }

        uint16 performanceBps = before_.performanceFeeBps;
        if (vault.performanceFeeBps() > performanceBps) performanceBps = vault.performanceFeeBps();
        if (performanceBps != 0) {
            retainedRate = Math.mulDiv(retainedRate, Config.BPS - performanceBps, Config.BPS, Math.Rounding.Floor);
        }
    }

    function _assertAndAdvanceRateFloor(RateSnapshot memory before_) private {
        uint256 rateAfter = vault.currentExchangeRate();
        if (rateAfter < before_.rate) {
            // First admit only the finite ERC-4626 integer discontinuity: one
            // share-rounding step, one asset-rounding step, and two final
            // division units. Anything larger needs an observable protocol-fee
            // cause and is subject to the configured economic fee cap below.
            uint256 roundingBound = _roundingBound(before_.rate);
            uint256 rateDrop = before_.rate - rateAfter;
            if (rateDrop > roundingBound) {
                if (!_hasProtocolFeeWitness(before_)) sawUnexplainedRateDrop = true;
                assertTrue(
                    _hasProtocolFeeWitness(before_), "QUEUE ACTION LOWERED RATE WITHOUT ROUNDING OR A PROTOCOL FEE"
                );

                // Independent finite bound: an annual AUM fee retains the
                // configured geometric fraction, and a performance checkpoint
                // retains at least (1 - feeBps) even when fee shares are priced
                // from conservative marked NAV rather than realized NAV.
                assertGe(
                    rateAfter + roundingBound,
                    _minimumFeeRetainedRate(before_),
                    "QUEUE ACTION DILUTION EXCEEDED THE COMBINED PROTOCOL-FEE BOUND"
                );
            }
        }
        // Every state-changing handler action advances the evented floor, so
        // later calls cannot hide a drop behind a constructor-time baseline. NOTE (R15-04): this
        // is why the top-level invariant must assert `sawUnexplainedRateDrop`, not a comparison
        // against `rateFloor` — the floor equals the live rate at every invariant evaluation.
        rateFloor = rateAfter;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        vault.accrueFees();
        uint256 hurdleBefore = _hurdleAssets();
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1, 2_000_000e6);
        uint256 assets = amount * 1e12;
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(controller), amount);
        controller.mint(amount);
        usdfr.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
        _checkHurdleCarry(hurdleBefore + assets);
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    function request(uint256 actorSeed, uint256 shares) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        address actor = actors[actorSeed % 3];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        // C-1 ENTRY FLOOR (owner-approved 2026-07-22): a request must be worth at least
        // `minRedemptionValue` of REALIZED USDfr to enter, else `requestRedeem` reverts
        // `Queue_BelowMinRedemption`. This is a bounded, never-reverting handler
        // (`fail_on_revert = true`), so bound the fuzzed shares to the admissible band
        // [minShares, bal]. `previewWithdraw(floor)` ceils, so `convertToAssets` of it is
        // guaranteed >= floor. If the actor's whole balance is worth less than the floor there is
        // nothing admissible to request this call (the actor stakes more later).
        uint256 floor = queue.minRedemptionValue();
        uint256 minShares = vault.previewWithdraw(floor);
        if (minShares == 0) minShares = 1; // floor disabled (not in this handler): keep shares >= 1
        if (bal < minShares) return;
        shares = bound(shares, minShares, bal);
        uint256 entryValue = vault.convertToAssets(shares);
        // The floor must hold at entry — assert it, so a regression that admitted dust fails loudly
        // here rather than only in the invariant.
        assertGe(entryValue, floor, "ENTRY FLOOR VIOLATED: sub-min request would be admitted");
        vm.startPrank(actor);
        vault.approve(address(queue), shares);
        uint256 id = queue.requestRedeem(shares);
        vm.stopPrank();
        assertEq(id, tracked.length, "request ids are dense");
        tracked.push(Tracked({owner: actor, originalShares: shares, claimed: 0}));
        if (entryValue < minAdmittedEntryValue) minAdmittedEntryValue = entryValue; // floor witness
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    /// @dev PER-SETTLEMENT BUDGET CHECK (§1.3 "never distributes more than available
    ///      liquidity"): mirror the snapshot at settlement start, accumulate assets
    ///      moved into queue custody across chunks, assert <= snapshot.
    function closeEpochChunk(uint256 maxRequests) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        if (!queue.isSettling()) {
            if (block.timestamp < queue.epochEndsAt()) return; // nothing to settle yet
            if (queue.head() < queue.totalRequests() && block.timestamp < queue.eligibleToSettleAt(queue.head())) {
                return; // ADR-0022: head is still in its forced cooldown; heartbeat is not consumed
            }
            // the A1 fix reverts a zero-budget settlement while requests are pending
            // (epoch not consumed); skip that case so the bounded handler never reverts
            if (queue.availableLiquidity() == 0 && queue.head() < queue.totalRequests()) return;
            ghostBudget = queue.availableLiquidity();
            ghostSettlementDistributed = 0;
        }
        // Pin the pre-flow hurdle after crystallizing any independently due fee.
        // The queue's own redeem checkpoint is then a no-op, so a one-request chunk
        // exposes exactly one principal/supply flow to the reference law below.
        vault.accrueFees();
        uint256 hurdleBefore = _hurdleAssets();
        uint256 supplyBefore = vault.totalSupply();
        maxRequests = bound(maxRequests, 1, 5);
        uint256 balBefore = usdfr.balanceOf(address(queue));
        if (vault.redemptionTotalAssets() < vault.totalAssets()) settlementsUnderImpairment++;
        // AUDIT C-1: the settlement is DELIBERATELY called under an arbitrary conservative mark
        // (pre-guarding it away would make the zero-value-fill invariant vacuous). The only
        // tolerated failure is the loud abandon — anything else is a real handler bug.
        vm.recordLogs();
        (bool ok, bytes memory ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (maxRequests)));
        if (!ok) {
            bytes4 sel = bytes4(ret);
            // The three loud, non-destructive abandons, and nothing else:
            //   Queue_NoLiquidity      — no budget, or the budget cannot buy a wei of the head
            //   Queue_HeadNotRedeemable— the settlement front prices to zero (C-1 remediation)
            //   Queue_AllInCooldown    — ADR-0022 hold: the head is still within its forced
            //     cooldown, so nothing is yet settleable. The heartbeat is NOT consumed and
            //     nothing is burned; the block clears the instant the head's cooldown elapses.
            //     (The chunk-start guard above pre-filters the common case, but a latched
            //     multi-chunk settlement can still walk onto a still-cooling request.)
            //     Deliberately tolerated.
            assertTrue(
                sel == IRedemptionQueue.Queue_NoLiquidity.selector
                    || sel == IRedemptionQueue.Queue_HeadNotRedeemable.selector
                    || sel == IRedemptionQueue.Queue_AllInCooldown.selector,
                string(abi.encodePacked("UNEXPECTED SETTLEMENT REVERT ", vm.toString(sel)))
            );
            // LIVENESS (C-1 remediation). The wave-1 guard read GREEN here because ANY
            // `Queue_NoLiquidity` was tolerated, so a permanently bricked queue was
            // indistinguishable from a healthy idle one. A refusal to settle is only legitimate
            // if NOTHING could have been paid to ANYONE — never because a worthless request sits
            // in front of a payable one.
            _assertNoPayableRequestWasDenied();
            // measured reach witnesses (not asserted): the interesting stop states remain
            // reachable under the $1 entry floor.
            if (sel == IRedemptionQueue.Queue_HeadNotRedeemable.selector) loudStops++;
            else if (sel == IRedemptionQueue.Queue_NoLiquidity.selector) noLiquidityStops++;
            else cooldownStops++;
            _assertAndAdvanceRateFloor(rateBefore);
            callCount++;
            return;
        }
        _recordFills();
        uint256 delta = usdfr.balanceOf(address(queue)) - balBefore;
        if (delta > 0) positiveSettlements++;
        ghostSettlementDistributed += delta;
        ghostTotalFilled += delta;
        assertLe(ghostSettlementDistributed, ghostBudget, "QUEUE OVER-DISTRIBUTED ITS BUDGET");
        if (maxRequests == 1 && delta != 0) {
            uint256 assetCarry = delta >= hurdleBefore ? 0 : hurdleBefore - delta;
            uint256 proRataCarry =
                Math.mulDiv(hurdleBefore, vault.totalSupply() + 1e6, supplyBefore + 1e6, Math.Rounding.Ceil);
            _checkHurdleCarry(Math.max(assetCarry, proRataCarry));
        }
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    /// @dev AUDIT C-1: sets the declared senior impairment the vault prices exits against.
    ///      Bounded well past the vault's assets so the fuzzer reaches the CLAMPED base
    ///      (`redemptionTotalAssets() == 0`) that made `budgetShares` explode.
    function setImpairment(uint256 amount) external {
        impairmentSource.setImpairment(bound(amount, 0, 20_000_000e18));
        // This is the handler's explicit economic valuation event, not queue
        // traffic. It can create or remove a pending performance-fee liability,
        // so re-anchor here; every actual queue action remains checked against
        // its immediately preceding rate.
        rateFloor = vault.currentExchangeRate();
        callCount++;
    }

    /// @dev Drives the production ordering `performance impairment >= redemption
    ///      impairment` while independently varying both views. A strict inequality is
    ///      the junior-credit state that the old single-slot campaign could not express.
    function setDualImpairment(uint256 redemptionAmount, uint256 extraPerformanceImpairment) external {
        redemptionAmount = bound(redemptionAmount, 0, 20_000_000e18);
        extraPerformanceImpairment = bound(extraPerformanceImpairment, 0, 20_000_000e18 - redemptionAmount);
        uint256 performanceAmount = redemptionAmount + extraPerformanceImpairment;
        impairmentSource.setImpairments(redemptionAmount, performanceAmount);
        if (performanceAmount > redemptionAmount) dualNavStates++;
        rateFloor = vault.currentExchangeRate();
        callCount++;
    }

    /// @dev C-1 REMEDIATION LIVENESS CHECK. Walks every open request and fails if any of them
    ///      COULD have been paid an economically meaningful amount out of the current budget at
    ///      the current mark, while `closeEpoch` refused to settle. "Could have been paid" is the
    ///      settlement's own arithmetic — `previewRedeem(min(sharesRemaining, budgetShares))` —
    ///      checked against the same `minRedemptionValue` that protects the heartbeat from dust
    ///      fills. A nonzero amount below that floor is deliberately deferred, not a wedge.
    function _assertNoPayableRequestWasDenied() internal view {
        uint256 budgetShares = vault.convertToSharesAtRedemption(queue.availableLiquidity());
        if (budgetShares == 0) return; // genuinely no budget: refusing is correct
        uint256 cooldown = queue.redeemCooldown();
        for (uint256 i = queue.head(); i < tracked.length; ++i) {
            (, uint256 remaining,,, uint256 requestedAt) = queue.request(i);
            if (remaining == 0) continue;
            // A request still inside its ADR-0022 hold legitimately blocks everything behind it
            // (designed FIFO + cooldown behaviour, not a wedge) — stop the walk there.
            if (block.timestamp < requestedAt + cooldown) break;
            uint256 fill = remaining < budgetShares ? remaining : budgetShares;
            uint256 payableAssets = vault.previewRedeem(fill);
            uint256 floor = queue.minRedemptionValue();
            if (floor == 0) {
                assertEq(payableAssets, 0, "QUEUE WEDGED: a payable request was denied settlement");
            } else {
                assertLt(payableAssets, floor, "QUEUE WEDGED: an economically meaningful request was denied settlement");
            }
        }
    }

    /// @dev Scans the settlement's logs for the C-1 signature: a fill that burned shares
    ///      and returned no assets. (Deferral is GONE post-2026-07-22 — there is no
    ///      `RequestDeferred` to parse; the queue only ever appends via `request()`, so
    ///      `tracked` indices stay dense against `totalRequests`.)
    function _recordFills() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("RequestFilled(uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(queue) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == sig) {
                (uint256 shares, uint256 assets,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                if (shares > 0 && assets == 0) sawZeroValueFill = true;
            }
        }
    }

    function claim(uint256 reqSeed) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        if (tracked.length == 0) return;
        uint256 id = reqSeed % tracked.length;
        (,, uint256 claimable,,) = queue.request(id);
        if (claimable == 0) return;
        Tracked storage t = tracked[id];
        uint256 balBefore = usdfr.balanceOf(t.owner);
        vm.prank(t.owner);
        uint256 got = queue.claim(id);
        assertEq(got, claimable, "claim returns the full claimable");
        assertEq(usdfr.balanceOf(t.owner) - balBefore, claimable, "NO DOUBLE/UNDER CLAIM");
        t.claimed += got;
        ghostTotalClaimed += got;
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    function addLiquidity(uint256 actorSeed, uint256 amount) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1, 1_000_000e6);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(controller), amount);
        controller.mint(amount);
        vm.stopPrank();
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    function drainLiquidity(uint256 actorSeed, uint256 amount) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        uint256 idle = usdc.balanceOf(address(reserves));
        uint256 max = bal < idle * 1e12 ? bal : idle * 1e12;
        if (max < 1e12) return;
        amount = bound(amount, 1e12, max);
        vm.prank(actor);
        controller.redeem(amount);
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    function donateToVault(uint256 actorSeed, uint256 amount) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        usdfr.transfer(address(vault), amount);
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    function warp(uint256 secs) external {
        RateSnapshot memory rateBefore = _rateSnapshot();
        secs = bound(secs, 1 hours, 40 days);
        vm.warp(block.timestamp + secs);
        _assertAndAdvanceRateFloor(rateBefore);
        callCount++;
    }

    // ── reconciliation views ─────────────────────────────────────────────

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    function sumSharesRemaining() external view returns (uint256 total) {
        for (uint256 i = 0; i < tracked.length; ++i) {
            (, uint256 remaining,,,) = queue.request(i);
            total += remaining;
        }
    }

    function sumClaimable() external view returns (uint256 total) {
        for (uint256 i = 0; i < tracked.length; ++i) {
            (,, uint256 claimable,,) = queue.request(i);
            total += claimable;
        }
    }

    /// @dev FIFO (§1.3): every request before the head is fully filled; every request
    ///      after the head is completely untouched.
    function fifoHolds() external view returns (bool) {
        uint256 head = queue.head();
        for (uint256 i = 0; i < tracked.length; ++i) {
            (, uint256 remaining, uint256 claimable,,) = queue.request(i);
            if (i < head && remaining != 0) return false;
            if (i > head) {
                bool untouched = remaining == tracked[i].originalShares && claimable == 0 && tracked[i].claimed == 0;
                if (!untouched) return false;
            }
        }
        return true;
    }

    /// @dev STRICT FIFO, NO REORDERING (C-1 remediation, owner-approved 2026-07-22). With deferral
    ///      removed there is no sanctioned FIFO departure: a fill of request[j] implies EVERY
    ///      earlier request[i<j] is fully filled. Stated directly (independently of `head`) so a
    ///      regression that reordered the book — filling a later request while an earlier one still
    ///      has shares — fails loudly.
    function strictFifoNoReordering() external view returns (bool) {
        for (uint256 j = 0; j < tracked.length; ++j) {
            (, uint256 remainingJ, uint256 claimableJ,,) = queue.request(j);
            bool touchedJ = claimableJ > 0 || tracked[j].claimed > 0 || remainingJ < tracked[j].originalShares;
            if (!touchedJ) continue;
            for (uint256 i = 0; i < j; ++i) {
                (, uint256 remainingI,,,) = queue.request(i);
                if (remainingI != 0) return false; // an earlier request was skipped: reordering
            }
        }
        return true;
    }
}
