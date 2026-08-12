// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
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
import {GuardProbe} from "./GuardProbe.sol";

/// @dev Bounded handler for REDEMPTION QUEUE stateful fuzzing (§1.3 queue invariants).
///      `fail_on_revert = true`: every path is bounded to never revert. The
///      never-over-distributes property is asserted PER SETTLEMENT here (budget
///      snapshot mirrored at settlement start, distribution accumulated across
///      chunks); FIFO and custody properties are checked by the invariant functions.
contract QueueHandler is GuardProbe {
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
    ///      the smallest REALIZED value at which any request was admitted.
    ///
    ///      AUDIT G11/G12.2 — READ THIS BEFORE ASSERTING ON IT. This ghost is written ONLY inside
    ///      `request()`, and `request()` bounds its fuzzed share count into the ADMISSIBLE band
    ///      before calling. `minAdmittedEntryValue >= minRedemptionValue` is therefore true by
    ///      construction of the handler and says NOTHING about the contract; the invariant that
    ///      asserted exactly that was restating the handler's own `bound()`. It is kept as a
    ///      reported measurement, and the real property now lives in `requestBelowFloor` below,
    ///      which fires UNFILTERED sub-floor requests at the guard.
    uint256 public minAdmittedEntryValue = type(uint256).max;
    /// @dev AUDIT G11/G12.2. The entry floor's real witnesses: unfiltered sub-floor requests
    ///      actually attempted, and refusals actually observed carrying `Queue_BelowMinRedemption`.
    uint256 public subFloorAttempts;
    uint256 public subFloorRefusals;
    /// @dev Set if the queue ever ADMITTED a request worth less than `minRedemptionValue`.
    ///      Asserted by `invariant_queue_entryFloorAndStrictFifo`.
    bool public sawSubFloorAdmission;
    /// @dev Guard id for the reach ledger; also the label printed by `reachReport()`.
    bytes32 internal constant GUARD_ENTRY_FLOOR = "queue.requestRedeem entry floor";

    // ─────────────────────────────────────────────────────────────────────────────────────────
    // AUDIT FINDING (campaign 5, 2 x HIGH) — "BOTH ARMS OF THE Q-01 FIX ARE DELETABLE WITH EVERY
    // STATEFUL CAMPAIGN GREEN", plus three adjacent guards on the same contract.
    //
    // THE DEFECT WAS IN THIS HANDLER, NOT IN `RedemptionQueue`. Deleting the residue-margin block
    // (arm A), its `previewRedeem(budgetShares) != 0` conjunct (arm B), the `+ withheld` credit in
    // the A1 abandon guard, or `claim`'s owner check left all thirteen invariant campaigns green.
    // The deterministic audit suites caught every one of them; the stateful tier caught none.
    //
    // WHY. Two structural reasons, and they are the same two campaign 5 recorded for the entry
    // floor:
    //   1. `closeEpochChunk` samples the settlement budget from whatever `availableLiquidity()`
    //      happens to be. Arms A and B live in a window ~1e-6 USDfr wide around the head's exact
    //      value, and arm B needs a LATCHED settlement whose remaining budget is exactly 1 wei.
    //      Uniform fuzzing does not find a 1-wei target by accident; it has to be AIMED.
    //   2. Neither arm REVERTS. `_fireAtGuard` cannot police them — deleting them leaves
    //      `closeEpoch` succeeding and every custody / FIFO / backing / budget-ceiling invariant
    //      reconciling exactly as before. What changes is only WHAT WAS FILLED. So the property
    //      has to be evaluated as a post-condition and reported through
    //      `_recordBehaviouralGuard`.
    //
    // The four probes below therefore CONSTRUCT the exact illegal region and then assert the
    // specified outcome. DO NOT "simplify" them by bounding the constructed sizes toward something
    // the fuzzer would reach on its own — that is the pre-filtering this finding is about, and it
    // is the single change that would make all four vacuous again.
    // ─────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Mirrors `RedemptionQueue.MIN_RESIDUE_VALUE` (private there). If the contract's
    ///      constant ever changes, this must change with it or the arm-A post-condition silently
    ///      weakens — it is asserted against the shipped value in
    ///      `RedemptionQueueInvariants.test_queue_residueMarginIsProbedAtTheShippedConstant`.
    uint256 internal constant MIN_RESIDUE_VALUE = 1e12;

    /// @dev Mirrors `RedemptionQueue.MAX_MIN_REDEMPTION_VALUE` (private there). Pinned to the
    ///      shipped bound by `test_queue_governanceWindowMatchesTheShippedSetterBounds`.
    uint256 internal constant MAX_MIN_REDEMPTION_VALUE = 100e18;

    bytes32 internal constant GUARD_RESIDUE_MARGIN = "queue.closeEpoch residue margin";
    bytes32 internal constant GUARD_COMPLETE_AT_ZERO = "queue.closeEpoch completeAtZero";
    bytes32 internal constant GUARD_WITHHELD_CREDIT = "queue.closeEpoch withheld credit";
    bytes32 internal constant GUARD_CLAIM_OWNER = "queue.claim owner";

    /// @dev Q-01 ARM A. Set if any partial fill ever left a residue worth < MIN_RESIDUE_VALUE.
    bool public sawSubMarginResidue;
    /// @dev Q-01 ARM B. Set if a head whose budget-capped fill priced to ZERO was nonetheless
    ///      drained by the COMPLETE branch.
    bool public sawZeroPricedHeadDrained;
    /// @dev A1 `+ withheld` credit. Set if a settlement that distributed at least its captured
    ///      economic floor ONCE THE DELIBERATE WITHHOLDING IS CREDITED BACK was nevertheless
    ///      abandoned and rolled back.
    bool public sawWithholdingCostASettlementItsFloor;
    /// @dev `claim` owner check. Set if a non-owner ever successfully claimed.
    bool public sawNonOwnerClaim;

    // Reach witnesses. Each counts calls that actually ENTERED the illegal region, not calls
    // attempted — a probe whose preconditions never assembled proves nothing, and
    // `probeSetupAbandons` says so out loud rather than letting a green tick imply coverage.
    uint256 public partialFillsObserved;
    uint256 public residueBandProbes;
    uint256 public completeAtZeroProbes;
    uint256 public withheldCreditProbes;
    uint256 public nonOwnerClaimProbes;
    uint256 public probeSetupAbandons;
    /// @dev Shipped `epochLiquidityBps`, parked in storage across `probeWithheldCredit`'s window
    ///      so the function stays under the stack limit.
    uint16 private _shippedBps;
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
        // AUDIT G11/G12.2: register the entry floor as a probed guard boundary so the reach
        // ledger can report whether the campaign actually attacked it.
        _registerGuard(
            GUARD_ENTRY_FLOOR,
            IRedemptionQueue.Queue_BelowMinRedemption.selector,
            "RedemptionQueue.requestRedeem: minRedemptionValue entry floor"
        );
        // AUDIT FINDING (campaign 5). Registered UP FRONT, before any of them has been reached,
        // so `reachReport()` can print a guard as NOT REACHED. A ledger that only lists guards it
        // has already hit can never show the vacuity it exists to expose.
        //
        // The three settlement guards are BEHAVIOURAL: their refusal is a different fill, not a
        // revert, so they carry `bytes4(0)` as their expected selector and are reported through
        // `_recordBehaviouralGuard`. `claim`'s owner check does revert, so it is a normal
        // `_fireAtGuard` probe.
        _registerGuard(GUARD_RESIDUE_MARGIN, bytes4(0), "RedemptionQueue.closeEpoch: Q-01 arm A residue margin");
        _registerGuard(
            GUARD_COMPLETE_AT_ZERO, bytes4(0), "RedemptionQueue.closeEpoch: Q-01 arm B previewRedeem(budgetShares)!=0"
        );
        _registerGuard(GUARD_WITHHELD_CREDIT, bytes4(0), "RedemptionQueue.closeEpoch: A1 abandon '+ withheld' credit");
        _registerGuard(
            GUARD_CLAIM_OWNER, IRedemptionQueue.Queue_NotRequestOwner.selector, "RedemptionQueue.claim: request owner"
        );
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

    /// @notice AUDIT G11/G12.2 — THE ENTRY FLOOR, ATTACKED RATHER THAN RESTATED.
    ///
    ///         `request()` above bounds its share count into the admissible band because
    ///         `fail_on_revert = true` requires the handler never to revert. That is the correct
    ///         way to write a POSITIVE action, but it means the campaign never once presented the
    ///         queue with a sub-minimum request — so the guard at `RedemptionQueue.sol:255` was
    ///         never executed by the invariant tier, and the invariant that claimed to police it
    ///         was asserting the handler's own `bound()` back to itself.
    ///
    ///         This action does the opposite: it deliberately steers the fuzzed input INTO the
    ///         illegal region and requires the CONTRACT to refuse it, with the exact
    ///         `Queue_BelowMinRedemption` selector. The refusal is the property.
    ///
    /// @dev The `convertToAssets(shares) >= floor` early return is NOT the pre-filter this finding
    ///      is about, and the distinction matters. It filters TOWARD the illegal region, never
    ///      away from it: `previewWithdraw` rounds UP, so `minShares - 1` is not guaranteed to be
    ///      worth less than the floor once the rate moves, and admitting such a request would be
    ///      correct behaviour. `convertToAssets` is the ERC-4626 realized-value view that the
    ///      floor is SPECIFIED against (see the NatSpec at `RedemptionQueue.requestRedeem`), so it
    ///      is the reference model here, not a mirror of the implementation's branch.
    ///
    /// @dev DO NOT "fix" this action by bounding shares up to the admissible band. Doing so
    ///      restores exactly the vacuity that audit finding G11/G12.2 recorded.
    function requestBelowFloor(uint256 actorSeed, uint256 sharesSeed) external {
        uint256 floor = queue.minRedemptionValue();
        if (floor == 0) return; // governance disabled the floor: there is no guard to police
        address actor = actors[actorSeed % 3];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        uint256 minShares = vault.previewWithdraw(floor);
        if (minShares < 2) return; // the floor is worth under two shares: no sub-floor count exists
        uint256 shares = bound(sharesSeed, 1, minShares - 1);
        if (shares > bal) shares = bal;
        if (vault.convertToAssets(shares) >= floor) return; // rounding: this one is legitimately admissible

        // Approve first, so the ONLY thing left that can refuse the call is the entry floor. An
        // allowance failure would masquerade as a guard and make the probe look reached when it
        // was not — the reach ledger would show it as `RefusedOtherwise`, but better to remove
        // the ambiguity entirely.
        vm.prank(actor);
        vault.approve(address(queue), shares);

        Verdict verdict = _fireAtGuard(
            GUARD_ENTRY_FLOOR, actor, address(queue), abi.encodeCall(IRedemptionQueue.requestRedeem, (shares))
        );
        subFloorAttempts++;
        if (verdict == Verdict.Admitted) {
            sawSubFloorAdmission = true;
        } else if (verdict == Verdict.RefusedAsSpecified) {
            subFloorRefusals++;
        }
        // Assert at the call site as well as in the invariant. If the floor is ever bypassed the
        // queue holds a request this handler never tracked, and every custody/FIFO invariant would
        // then fail for a confusing downstream reason; failing here names the actual cause.
        assertTrue(verdict != Verdict.Admitted, "ENTRY FLOOR BYPASSED: a sub-minimum request was admitted");
        callCount++;
    }

    // ─────────────────────────────────────────────────────────────────────
    // AUDIT FINDING (campaign 5) — construction primitives for the probes.
    // Every one of these only ever moves the board TOWARD a guard boundary. None of them
    // inspects the contract's branch condition to decide whether to proceed.
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Settlement + ghost bookkeeping shared by the probes.
    /// @dev IN SYNC WITH `closeEpochChunk`. `invariant_queue_internalAggregateMatchesItems` reads
    ///      `ghostTotalFilled`; a probe that settles without updating it fails that invariant for
    ///      a reason that has nothing to do with the guard under test, which is the classic way a
    ///      real counterexample gets misdiagnosed as a handler bug and the probe deleted.
    function _probeSettle(uint256 maxRequests) private returns (bool ok, bytes memory ret) {
        if (!queue.isSettling()) {
            ghostBudget = queue.availableLiquidity();
            ghostSettlementDistributed = 0;
        }
        vault.accrueFees();
        uint256 balBefore = usdfr.balanceOf(address(queue));
        vm.recordLogs();
        (ok, ret) = address(queue).call(abi.encodeCall(IRedemptionQueue.closeEpoch, (maxRequests)));
        if (!ok) return (ok, ret);
        _recordFillsAndCheckResidueMargin();
        uint256 delta = usdfr.balanceOf(address(queue)) - balBefore;
        if (delta > 0) positiveSettlements++;
        ghostSettlementDistributed += delta;
        ghostTotalFilled += delta;
        assertLe(ghostSettlementDistributed, ghostBudget, "QUEUE OVER-DISTRIBUTED ITS BUDGET");
    }

    /// @dev Mints USDfr through the real KYC-gated path and stakes it, in whole USDC units.
    ///      Minting raises the IDLE RESERVE, and therefore `availableLiquidity()`, by the same
    ///      amount — every caller below sizes against the budget only AFTER its staking is done.
    function _stakeExact(address actor, uint256 assets18) private returns (bool) {
        uint256 units = assets18 / 1e12;
        if (units == 0) return false;
        uint256 amount = units * 1e12;
        if (vault.maxDeposit(actor) < amount) return false;
        usdc.mint(actor, units);
        vm.startPrank(actor);
        usdc.approve(address(controller), units);
        controller.mint(units);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();
        return true;
    }

    /// @dev Queues a PURPOSE-SIZED request and keeps `tracked` dense against `totalRequests`,
    ///      which every FIFO/custody view in this handler depends on.
    /// @dev The entry-floor check here is a SETUP precondition, not a pre-filter around the guard
    ///      under test: `requestBelowFloor` is what attacks the floor. A probe that tripped it
    ///      would revert under `fail_on_revert = true` and take the whole campaign down for a
    ///      reason unrelated to Q-01.
    function _queueFor(address actor, uint256 shares) private returns (uint256 id, bool ok) {
        if (shares == 0 || vault.balanceOf(actor) < shares) return (0, false);
        if (vault.convertToAssets(shares) < queue.minRedemptionValue()) return (0, false);
        vm.startPrank(actor);
        vault.approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
        assertEq(id, tracked.length, "request ids are dense");
        tracked.push(Tracked({owner: actor, originalShares: shares, claimed: 0}));
        ok = true;
    }

    /// @dev Raises the idle reserve to at least `targetIdle` by an ordinary KYC'd mint.
    function _mintIdleAtLeast(uint256 targetIdle) private {
        uint256 idle = reserves.idleReserve();
        if (idle >= targetIdle) return;
        uint256 units = Math.ceilDiv(targetIdle - idle, 1e12);
        address actor = actors[0];
        usdc.mint(actor, units);
        vm.startPrank(actor);
        usdc.approve(address(controller), units);
        controller.mint(units);
        vm.stopPrank();
    }

    /// @dev Lowers the idle reserve to exactly `targetIdle` by ordinary KYC'd redemptions.
    /// @dev Only USDfr held by the three actors can be unwound; USDfr already staked into the
    ///      vault or already paid into the queue is not reachable, so this can legitimately fail
    ///      on a mature board. It returns false rather than pretending, and the caller counts a
    ///      `probeSetupAbandons` — a silent success here would be exactly the kind of pretend
    ///      coverage this finding is about.
    function _drainIdleTo(uint256 targetIdle) private returns (bool) {
        uint256 idle = reserves.idleReserve();
        if (idle <= targetIdle) return idle == targetIdle;
        uint256 excess = idle - targetIdle;
        for (uint256 i = 0; i < 3 && excess != 0; ++i) {
            address actor = actors[i];
            uint256 bal = usdfr.balanceOf(actor);
            uint256 amount = bal < excess ? bal : excess;
            amount = (amount / 1e12) * 1e12;
            if (amount == 0) continue;
            vm.prank(actor);
            controller.redeem(amount);
            excess -= amount;
        }
        return reserves.idleReserve() == targetIdle;
    }

    /// @dev Settles the existing book away so a probe's PURPOSE-SIZED request lands at the FIFO
    ///      head. Strict FIFO means a probe cannot aim at anything but the head, and the head is
    ///      whatever the campaign queued earlier — so without this the three settlement probes
    ///      would only ever fire on a fresh board and their reach would be a coin flip.
    function _clearBoard() private returns (bool) {
        uint256 n = queue.totalRequests();
        if (queue.head() >= n) return true;
        impairmentSource.setImpairments(0, 0); // a live mark can stop the settlement loud
        vault.accrueFees();
        uint256 need = vault.previewRedeem(queue.totalQueuedShares());
        (, uint16 bps) = queue.epochParams();
        _mintIdleAtLeast(Math.mulDiv(need + 1e18, Config.BPS, bps, Math.Rounding.Ceil));
        uint256 t = queue.eligibleToSettleAt(n - 1); // ADR-0022: the LAST request's forced hold
        uint256 e = uint256(queue.epochEndsAt());
        if (e > t) t = e;
        if (block.timestamp < t) vm.warp(t);
        for (uint256 i = 0; i < 3 && queue.head() < queue.totalRequests(); ++i) {
            (bool ok,) = _probeSettle(64);
            if (!ok) break;
        }
        return queue.head() >= queue.totalRequests();
    }

    /// @dev Warps forward to the later of `eligibleAt` (the ADR-0022 forced hold) and the current
    ///      heartbeat, so the settlement a probe is about to run is admissible. Never backwards.
    function _warpTo(uint256 eligibleAt) private {
        uint256 t = eligibleAt;
        uint256 e = uint256(queue.epochEndsAt());
        if (e > t) t = e;
        if (block.timestamp < t) vm.warp(t);
    }

    /// @dev Largest share count whose CONSERVATIVE value does not exceed `target`.
    function _sharesPricedAtMost(uint256 target, uint256 hi) private view returns (uint256 lo) {
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (vault.previewRedeem(mid) <= target) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev Marks the declared senior impairment so `shares` prices to EXACTLY `target`
    ///      conservative wei. The plateau of impairments mapping to a given price is about
    ///      `feeAdjustedSupply / shares` wide, so the caller must keep `shares` a small fraction
    ///      of supply (the probe below stakes explicit ballast for exactly that reason) or the
    ///      search steps straight over the target.
    function _markSharesTo(uint256 shares, uint256 target) private returns (bool) {
        uint256 lo = 0;
        uint256 hi = vault.totalAssets();
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            impairmentSource.setImpairments(mid, mid);
            if (vault.previewRedeem(shares) > target) lo = mid + 1;
            else hi = mid;
        }
        impairmentSource.setImpairments(lo, lo);
        // The performance-fee view moves with the same mark, so `feeAdjustedSupply` is not quite
        // constant across the search and it can land one plateau low. Walk back deterministically.
        for (uint256 i = 0; i < 64 && vault.previewRedeem(shares) != target; ++i) {
            if (lo == 0) break;
            lo -= 1;
            impairmentSource.setImpairments(lo, lo);
        }
        return vault.previewRedeem(shares) == target;
    }

    /// @notice AUDIT FINDING (campaign 5, HIGH) — Q-01 ARM A, ATTACKED RATHER THAN ASSUMED.
    ///
    ///         Arm A is the residue-margin block in `closeEpoch`: when a budget-capped partial
    ///         fill would leave the head with LESS than `MIN_RESIDUE_VALUE` behind, the fill is
    ///         re-cut so the residue carries the whole margin. Delete it and the residue lands
    ///         inside the zero-value window, where the next settlement's C-1 guard prices the
    ///         whole head at zero and reverts `closeEpoch` WHOLESALE, forever, for everyone
    ///         behind it.
    ///
    ///         The campaign never once produced that state: the illegal region is a window about
    ///         1e-6 USDfr wide around the head's exact conservative value, and
    ///         `closeEpochChunk` takes whatever `availableLiquidity()` happens to be. This action
    ///         computes the head's size FROM the budget so the residue lands at half a margin —
    ///         squarely inside the band — and lets the contract's post-condition be the property.
    ///
    /// @dev DO NOT "fix" this by sizing the request from a bounded fuzz seed. The band is far
    ///      narrower than any bound a fuzzer would explore, and that is precisely why arm A
    ///      survived thirteen campaigns.
    function probeResidueMargin(uint256 actorSeed) external {
        // PER-RUN COST BUDGET, not a filter. The construction below is DETERMINISTIC given the
        // board, so repeating it inside one run re-tests the same boundary at the price of a full
        // board clear each time. State does not carry across runs, so at 256 runs the boundary is
        // still attacked hundreds of times. Raising this only costs wall-clock; LOWERING IT TO
        // ZERO is what would make the guard vacuous again.
        if (residueBandProbes >= 3) return;
        if (queue.isSettling() || !_clearBoard()) {
            probeSetupAbandons++;
            return;
        }
        impairmentSource.setImpairments(0, 0);
        vault.accrueFees();

        address actor = actors[actorSeed % 3];
        (, uint16 bps) = queue.epochParams();
        uint256 floorValue = queue.minRedemptionValue();
        // The head has to clear the entry floor AND sit above the budget, so give the budget a
        // floor of two entry floors before anything is sized against it.
        _mintIdleAtLeast(Math.mulDiv(2 * floorValue + 4 * MIN_RESIDUE_VALUE, Config.BPS, bps, Math.Rounding.Ceil));

        uint256 minResidue = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        uint256 headShares = vault.convertToSharesAtRedemption(queue.availableLiquidity()) + minResidue / 2;
        // Staking raises idle and therefore the budget by `bps/BPS` of the stake, so the head has
        // to be re-derived after it. 5% covers that feedback with room; a LARGER multiple would
        // leave the surplus parked in the vault every call and compound the board's size until an
        // ERC-4626 conversion overflows mid-campaign.
        if (minResidue < 2 || !_stakeExact(actor, (vault.convertToAssets(headShares) * 105) / 100 + 1e18)) {
            probeSetupAbandons++;
            return;
        }
        // re-derive against the post-stake budget: THIS is the number the settlement will use
        minResidue = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        uint256 budgetShares = vault.convertToSharesAtRedemption(queue.availableLiquidity());
        headShares = budgetShares + minResidue / 2;
        (uint256 id, bool queued) = _queueFor(actor, headShares);
        if (!queued) {
            probeSetupAbandons++;
            return;
        }
        uint256 t = queue.eligibleToSettleAt(id);
        uint256 e = uint256(queue.epochEndsAt());
        if (e > t) t = e;
        if (block.timestamp < t) vm.warp(t);

        // REACH LEDGER: count this as having entered the illegal region only if the conditions
        // arm A is written for actually hold at the moment of settlement — INCLUDING that the
        // residue the unguarded code would leave is genuinely sub-margin. At a share price far
        // above par `minResidue` collapses to a handful of share units and half of it can still
        // be worth more than `MIN_RESIDUE_VALUE`; the guard is then inert, the settlement is
        // ordinary, and counting it would overstate reach.
        uint256 budget = queue.availableLiquidity();
        budgetShares = vault.convertToSharesAtRedemption(budget);
        minResidue = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        if (
            budgetShares != 0 && headShares > budgetShares && headShares - budgetShares < minResidue
                && vault.previewRedeem(headShares) > budget
                && vault.previewRedeem(headShares - budgetShares) < MIN_RESIDUE_VALUE
        ) residueBandProbes++;
        else probeSetupAbandons++;

        // The post-condition is asserted inside `_recordFillsAndCheckResidueMargin`, which runs on
        // this settlement whether or not the region check above passed.
        _probeSettle(1);
        rateFloor = vault.currentExchangeRate(); // a valuation-driving action, like setImpairment
        callCount++;
    }

    /// @notice AUDIT FINDING (campaign 5, HIGH) — Q-01 ARM B, ATTACKED RATHER THAN ASSUMED.
    ///
    ///         Arm B is the `previewRedeem(budgetShares) != 0` conjunct on the COMPLETE branch.
    ///         Without it, a head whose budget-capped fill prices to ZERO is COMPLETED instead of
    ///         preserved — the C-1 principle inverted, draining an entire position for as little
    ///         as one wei.
    ///
    ///         The state is narrow and it cannot be stumbled into:
    ///         `previewRedeem(convertToSharesAtRedemption(b)) >= b - 1` at every reachable rate,
    ///         so `previewRedeem(budgetShares) == 0` requires `settlementBudget == 1` EXACTLY.
    ///         `availableLiquidity()` is quantised to whole USDC units and cannot express 1 wei,
    ///         so only a LATCHED settlement can — this action sizes a first request so its
    ///         complete fill leaves exactly one wei behind, then marks the next head to exactly
    ///         one conservative wei.
    ///
    /// @dev DO NOT relax the `settlementBudgetRemaining() == 1` check into `<= dust`. One wei is
    ///      not a rounding convenience here; it is the only budget at which the branch is
    ///      reachable at all, and a loosened check would settle a state where arm B is inert.
    function probeCompleteAtZeroPrice(uint256 actorSeed) external {
        if (completeAtZeroProbes >= 3) return; // per-run cost budget — see `probeResidueMargin`
        if (queue.isSettling() || !_clearBoard()) {
            probeSetupAbandons++;
            return;
        }
        impairmentSource.setImpairments(0, 0);
        vault.accrueFees();

        // `% 3` FIRST, then rotate. `actors[(actorSeed + 1) % 3]` panics on
        // `actorSeed == type(uint256).max` — which the invariant fuzzer's dictionary supplies
        // routinely, and which under `fail_on_revert = true` takes the whole campaign down.
        uint256 slot = actorSeed % 3;
        address filler = actors[slot];
        address victim = actors[(slot + 1) % 3];
        address ballast = actors[(slot + 2) % 3];

        // BALLAST — load-bearing. `_markSharesTo` can only land the victim on exactly one
        // conservative wei if one unit of declared impairment moves its price by less than a wei,
        // i.e. if the victim is a small fraction of supply. Twenty times its size is comfortable.
        uint256 victimBefore = vault.balanceOf(victim);
        if (!_stakeExact(ballast, 20_000e18) || !_stakeExact(victim, 1_000e18)) {
            probeSetupAbandons++;
            return;
        }
        uint256 victimShares = vault.balanceOf(victim) - victimBefore;

        (, uint16 bps) = queue.epochParams();
        uint256 floorValue = queue.minRedemptionValue();
        // The latching chunk must clear the RC-01 reachability test
        // (`distributed + budget >= settlementMinValue`), so start the budget above the floor.
        _mintIdleAtLeast(Math.mulDiv(2 * floorValue + 1e18, Config.BPS, bps, Math.Rounding.Ceil));
        // the filler must be able to absorb the WHOLE budget to the last wei; its own stake feeds
        // back into the budget through the idle reserve, hence the 5% (see `probeResidueMargin`
        // for why a larger multiple is not free).
        if (!_stakeExact(filler, (queue.availableLiquidity() * 105) / 100 + 1e18)) {
            probeSetupAbandons++;
            return;
        }
        uint256 budget = queue.availableLiquidity();
        if (budget <= floorValue) {
            probeSetupAbandons++;
            return;
        }
        uint256 fillerShares = _sharesPricedAtMost(budget - 1, vault.balanceOf(filler));
        if (vault.previewRedeem(fillerShares) != budget - 1) {
            probeSetupAbandons++;
            return;
        }
        (, bool okFiller) = _queueFor(filler, fillerShares);
        (uint256 victimId, bool okVictim) = _queueFor(victim, victimShares);
        if (!okFiller || !okVictim) {
            probeSetupAbandons++;
            return;
        }
        uint256 t = queue.eligibleToSettleAt(victimId);
        uint256 e = uint256(queue.epochEndsAt());
        if (e > t) t = e;
        if (block.timestamp < t) vm.warp(t);

        // chunk 1 — fill the filler ONLY, so the settlement latches with exactly 1 wei of budget
        (bool okLatch,) = _probeSettle(1);
        if (
            !okLatch || !queue.isSettling() || queue.settlementBudgetRemaining() != 1 || queue.head() != victimId
                || !_markSharesTo(victimShares, 1)
        ) {
            probeSetupAbandons++;
            rateFloor = vault.currentExchangeRate();
            callCount++;
            return;
        }
        uint256 bs = vault.convertToSharesAtRedemption(1);
        if (
            bs == 0 || bs >= victimShares || vault.previewRedeem(bs) != 0
                || victimShares - bs >= vault.previewWithdraw(MIN_RESIDUE_VALUE)
        ) {
            probeSetupAbandons++;
            rateFloor = vault.currentExchangeRate();
            callCount++;
            return;
        }
        completeAtZeroProbes++;

        _probeSettle(1);
        (, uint256 remaining, uint256 claimable,,) = queue.request(victimId);
        // THE SPECIFIED OUTCOME: C-1 preserves the head. Nothing burned, nothing credited.
        bool held = remaining == victimShares && claimable == 0;
        if (!held) sawZeroPricedHeadDrained = true;
        _recordBehaviouralGuard(GUARD_COMPLETE_AT_ZERO, held);
        assertTrue(
            held,
            "Q-01 ARM B BYPASSED: the COMPLETE branch drained a head whose budget-capped fill "
            "priced to ZERO - an entire position burned for one wei"
        );
        rateFloor = vault.currentExchangeRate();
        callCount++;
    }

    /// @notice AUDIT FINDING (campaign 5) — the A1 abandon guard's `+ withheld` CREDIT.
    ///
    ///         When arm A withholds value from a fill, the abandon guard credits that value back
    ///         before testing the settlement against its captured economic floor. Delete the
    ///         credit and a settlement that the budget could pay for is ABANDONED AND ROLLED BACK
    ///         because of the protocol's own deliberate withholding — a liveness failure the
    ///         campaign cannot see, because a rolled-back settlement leaves every ledger
    ///         reconciling perfectly.
    ///
    ///         The credit is only load-bearing in one place: when the settlement's WHOLE BUDGET
    ///         sits within `MIN_RESIDUE_VALUE` above the captured floor. That is forced, not
    ///         chosen — `distributed + withheld == previewRedeem(budgetShares)`, which is the
    ///         budget to within a wei, so `distributed < floor <= distributed + withheld` pins the
    ///         budget into a window one margin wide. A LATCHED settlement cannot be used to
    ///         sidestep it either: `settlementDistributed` is cumulative, so a second chunk always
    ///         carries the first chunk's fills and clears the floor on those alone.
    ///
    ///         So the probe drives `availableLiquidity()` onto one exact value. Three levers, all
    ///         real protocol operations: KYC'd mints raise the idle reserve, KYC'd redemptions
    ///         lower it, and governance sets `epochLiquidityBps` / `minRedemptionValue`. The
    ///         governance pair is what makes the window REACHABLE AT ALL on a board of realistic
    ///         size: at the shipped 167 bps and a $1 floor the target idle reserve is $59.88, so
    ///         any campaign that has ever staked anything is permanently out of range. Widening
    ///         the floor to its $100 maximum and narrowing the liquidity share to 1 bp moves the
    ///         target to $1,000,000 of idle reserve. Both are restored immediately afterwards, so
    ///         the rest of the campaign still runs on the shipped parameters.
    ///
    /// @dev DO NOT replace the exact idle tuning with "mint some liquidity", and do not drop the
    ///      governance window as "not how it will be configured". Off-window the credit changes
    ///      nothing and this action degenerates into a second `closeEpochChunk` — which is exactly
    ///      the state the finding recorded.
    function probeWithheldCredit(uint256 actorSeed) external {
        // PER-RUN COST BUDGET — one assembly per run. This probe drains the idle reserve to a
        // single exact value, which is destructive to the board; the construction is deterministic
        // so repeating it re-tests the same boundary.
        if (withheldCreditProbes != 0) return;
        if (queue.isSettling() || !_clearBoard()) {
            probeSetupAbandons++;
            return;
        }
        impairmentSource.setImpairments(0, 0);
        vault.accrueFees();

        // Open the window. `_restoreWithholdingWindow()` is called on EVERY exit path below.
        _openWithholdingWindow();

        address actor = actors[actorSeed % 3];
        // THE WINDOW. `availableLiquidity() == idleUnits * bps * 1e8`, so pick the smallest idle
        // that puts the budget strictly above the floor, and require it to still be comfortably
        // below `floor + MIN_RESIDUE_VALUE` — that gap is what the head's value has to fit into.
        (uint256 budget, uint256 targetIdle) = _withholdingWindowTarget();
        if (!_stakeExact(actor, 4 * queue.minRedemptionValue() + 1e18)) {
            _restoreWithholdingWindow();
            probeSetupAbandons++;
            return;
        }
        _mintIdleAtLeast(targetIdle);
        if (
            budget == 0 // this bps quantises too coarsely to land in the window
                || !_drainIdleTo(targetIdle) // the board is too large to unwind to the target
                || queue.availableLiquidity() != budget
        ) {
            _restoreWithholdingWindow();
            probeSetupAbandons++;
            return;
        }

        // The head's conservative value, placed at the midpoint of the legal band: above the
        // budget (so COMPLETE cannot fire), within one margin of it (so the withhold branch does),
        // and far enough below `floor + MIN_RESIDUE_VALUE` that the fill it leaves lands STRICTLY
        // under the floor — which is the whole point: without the credit that settlement dies.
        uint256 headShares =
            vault.previewWithdraw(budget + (queue.minRedemptionValue() + MIN_RESIDUE_VALUE - budget) / 2);
        (uint256 id, bool queued) = _queueFor(actor, headShares);
        if (!queued) {
            _restoreWithholdingWindow();
            probeSetupAbandons++;
            return;
        }
        _warpTo(queue.eligibleToSettleAt(id));

        if (!_withholdingRegionHolds(headShares, budget)) {
            _restoreWithholdingWindow();
            probeSetupAbandons++;
            rateFloor = vault.currentExchangeRate();
            callCount++;
            return;
        }
        withheldCreditProbes++;

        (bool ok, bytes memory ret) = _probeSettle(1);
        // Restore BEFORE asserting, so a failing campaign leaves the queue on shipped parameters
        // and the shrunk replay is read against the configuration the protocol actually ships.
        _restoreWithholdingWindow();
        // THE SPECIFIED OUTCOME: the settlement COMMITS. `distributed + withheld` clears the
        // captured floor even though `distributed` alone does not.
        if (!ok) sawWithholdingCostASettlementItsFloor = true;
        _recordBehaviouralGuard(GUARD_WITHHELD_CREDIT, ok);
        assertTrue(
            ok,
            string(
                abi.encodePacked(
                    "A1 '+ withheld' CREDIT BYPASSED: a settlement the budget could pay for was "
                    "abandoned because the Q-01 guard's own withholding pushed it under the floor; "
                    "closeEpoch reverted ",
                    vm.toString(ret)
                )
            )
        );
        rateFloor = vault.currentExchangeRate();
        callCount++;
    }

    /// @dev The exact `availableLiquidity()` the `+ withheld` credit is load-bearing at, and the
    ///      idle reserve that produces it. `budget == 0` means this `epochLiquidityBps` quantises
    ///      too coarsely for any idle reserve to land inside the window.
    function _withholdingWindowTarget() private view returns (uint256 budget, uint256 targetIdle) {
        uint256 floorValue = queue.minRedemptionValue();
        (, uint16 bps) = queue.epochParams();
        uint256 step = uint256(bps) * 1e8; // budget per whole USDC unit of idle
        uint256 k = Math.ceilDiv(floorValue + 1, step);
        budget = k * step;
        targetIdle = k * 1e12;
        if (budget > floorValue + (MIN_RESIDUE_VALUE * 3) / 4) return (0, 0);
    }

    /// @dev The five conditions that make the `+ withheld` credit decide this settlement.
    /// @dev The last one is the point of the whole construction: `previewRedeem(headShares -
    ///      minResidue)` is what the settlement will DISTRIBUTE, and it must be STRICTLY under the
    ///      floor, so the commit rests entirely on crediting the withholding back.
    /// @dev THE ROUND-TRIP CONDITION IS NOT A RESTATEMENT OF THE GUARD, and it is not optional.
    ///      `convertToSharesAtRedemption` floors and `previewRedeem` floors, so the budget's
    ///      round trip loses up to `ceil((feeAdjustedSupply + 1e6) / (redemptionAssets + 1))^-1`
    ///      wei — one wei in the ordinary regime (24-decimal shares against 18-decimal assets),
    ///      but ARBITRARILY MANY once repeated donations push the share price above one asset per
    ///      share unit, which this campaign's `donateToVault` reaches. In that regime the budget
    ///      genuinely cannot pay the floor and ABANDONING IS CORRECT — the credit is not what
    ///      decides the settlement, so the call is outside the guard's region and counting it as a
    ///      bypass would be a false red. The condition is a statement about the RATE, not about
    ///      the abandon predicate.
    function _withholdingRegionHolds(uint256 headShares, uint256 budget) private view returns (bool) {
        uint256 minResidue = vault.previewWithdraw(MIN_RESIDUE_VALUE);
        uint256 budgetShares = vault.convertToSharesAtRedemption(queue.availableLiquidity());
        return queue.availableLiquidity() == budget && headShares > minResidue
            && vault.previewRedeem(headShares) > budget && budgetShares != 0 && headShares > budgetShares
            && headShares - budgetShares < minResidue && vault.previewRedeem(budgetShares) + 1 >= budget
            && vault.previewRedeem(headShares - minResidue) != 0
            && vault.previewRedeem(headShares - minResidue) < queue.minRedemptionValue();
    }

    /// @dev Widens `minRedemptionValue` to its hard maximum and narrows `epochLiquidityBps` to
    ///      one basis point, so the budget window the `+ withheld` credit lives in corresponds to
    ///      an idle reserve a real campaign can actually reach. Returns the shipped bps so the
    ///      caller can put it back.
    /// @dev These are the QUEUE'S OWN governance setters, called with the queue's own admin role;
    ///      nothing is poked into storage behind the contract's back, so both changes go through
    ///      the same validation and events production governance would.
    function _openWithholdingWindow() private {
        (, _shippedBps) = queue.epochParams();
        queue.setMinRedemptionValue(MAX_MIN_REDEMPTION_VALUE);
        queue.setEpochLiquidityBps(1);
    }

    /// @dev Puts the shipped parameters back, on EVERY exit path. If this is ever skipped, the
    ///      remainder of the run silently tests a 1 bp liquidity share and a $100 entry floor, and
    ///      every other queue property in this campaign becomes a statement about a configuration
    ///      the protocol does not ship.
    function _restoreWithholdingWindow() private {
        queue.setEpochLiquidityBps(_shippedBps);
        queue.setMinRedemptionValue(Config.DEFAULT_MIN_REDEMPTION_VALUE);
    }

    /// @notice AUDIT FINDING (campaign 5) — `claim`'s `Queue_NotRequestOwner` check, UNFILTERED.
    ///
    ///         The campaign's `claim` action always pranks the request's owner, so the guard was
    ///         never once executed with a foreign caller. This action does the opposite and lets
    ///         the refusal be the property.
    ///
    /// @dev The search for a request with something claimable filters TOWARD the guard, not away
    ///      from it: `claim` checks ownership BEFORE claimability, so the guard executes either
    ///      way, but its DELETION is only observable when there is value to move.
    function claimAsNonOwner(uint256 reqSeed, uint256 actorSeed) external {
        if (tracked.length == 0) return;
        uint256 id = reqSeed % tracked.length;
        for (uint256 i = 0; i < tracked.length; ++i) {
            uint256 candidate = (id + i) % tracked.length;
            (,, uint256 claimable,,) = queue.request(candidate);
            if (claimable != 0) {
                id = candidate;
                break;
            }
        }
        address owner = tracked[id].owner;
        // `% 3` FIRST, then rotate — see `probeCompleteAtZeroPrice`: `actorSeed + 1` panics on
        // `type(uint256).max`, which the fuzzer supplies routinely.
        uint256 slot = actorSeed % 3;
        address caller = actors[slot];
        if (caller == owner) caller = actors[(slot + 1) % 3];
        if (caller == owner) return; // degenerate: every actor owns it
        nonOwnerClaimProbes++;
        Verdict verdict =
            _fireAtGuard(GUARD_CLAIM_OWNER, caller, address(queue), abi.encodeCall(IRedemptionQueue.claim, (id)));
        if (verdict == Verdict.Admitted) sawNonOwnerClaim = true;
        assertTrue(verdict != Verdict.Admitted, "CLAIM OWNER GUARD BYPASSED: a non-owner drove another account's claim");
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
        // AUDIT FINDING (campaign 5, 2 x HIGH) — Q-01 ARM A. Every settlement the campaign runs
        // is now judged against the residue-margin post-condition, not just the deliberate probe.
        _recordFillsAndCheckResidueMargin();
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
    ///      and returned no assets, AND for the Q-01 ARM A post-condition on the chunk's LAST
    ///      fill. (Deferral is GONE post-2026-07-22 — there is no `RequestDeferred` to parse;
    ///      the queue only ever appends via `request()`, so `tracked` indices stay dense against
    ///      `totalRequests`.)
    ///
    ///      AUDIT FINDING (campaign 5, 2 x HIGH) — WHY THE CHECK LIVES HERE AND NOT IN AN
    ///      INVARIANT FUNCTION. Q-01 arm A guarantees a property of the MOMENT OF THE FILL:
    ///      a partial fill leaves at least `MIN_RESIDUE_VALUE` behind AT THE CONSERVATIVE RATE
    ///      THAT PRICED IT. It is NOT a standing property of open requests — a later declared
    ///      impairment legitimately re-prices an already-compliant residue below the margin, and
    ///      an invariant function evaluating `previewRedeem(sharesRemaining)` on every open
    ///      request would fire on that and have to be weakened until it said nothing. Parsing
    ///      `RequestFilled` gives the exact "was this request filled IN THIS CHUNK" predicate the
    ///      property needs, so the assertion can stay at full strength.
    ///
    ///      Only the chunk's LAST fill can be partial (the settlement loop breaks the moment a
    ///      request is left with `sharesRemaining != 0`), so one check per chunk is exhaustive.
    function _recordFillsAndCheckResidueMargin() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("RequestFilled(uint256,uint256,uint256,uint256)");
        bool sawAnyFill;
        uint256 lastFilledId;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(queue) || logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] == sig) {
                (uint256 shares, uint256 assets,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                if (shares > 0 && assets == 0) sawZeroValueFill = true;
                sawAnyFill = true;
                lastFilledId = uint256(logs[i].topics[1]);
            }
        }
        if (!sawAnyFill) return;
        (, uint256 remaining,,,) = queue.request(lastFilledId);
        if (remaining == 0) return; // the last fill COMPLETED its request: arm A has nothing to say
        partialFillsObserved++;
        _assertResidueCarriesTheMargin(remaining);
    }

    /// @dev The Q-01 ARM A post-condition, stated in VALUE terms against the vault's own public
    ///      pricing view — deliberately NOT by re-running the contract's `sharesRemaining -
    ///      fillShares < previewWithdraw(MIN_RESIDUE_VALUE)` branch, which would make this a
    ///      tautology and leave the guard exactly as deletable as the finding found it.
    ///
    ///      `previewRedeem` rounds down and the conservative rate can only rise across the
    ///      `redeem` calls this chunk just made (the burn removes assets and shares at that same
    ///      rate, and the rounding is in the vault's favour), so reading the price AFTER the
    ///      chunk is a conservative reading of the price the fill was made at. A residue that
    ///      satisfied the margin at fill time therefore still satisfies it here.
    function _assertResidueCarriesTheMargin(uint256 remaining) internal {
        bool held = vault.previewRedeem(remaining) >= MIN_RESIDUE_VALUE;
        if (!held) sawSubMarginResidue = true;
        _recordBehaviouralGuard(GUARD_RESIDUE_MARGIN, held);
        assertTrue(
            held,
            "Q-01 ARM A BYPASSED: a partial fill left a residue worth less than MIN_RESIDUE_VALUE - "
            "the head is now a permanent wedge (Queue_HeadNotRedeemable forever)"
        );
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
