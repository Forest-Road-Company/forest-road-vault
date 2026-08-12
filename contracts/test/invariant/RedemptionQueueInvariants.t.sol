// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockImpairmentSource} from "../helpers/MockImpairmentSource.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {QueueHandler} from "./handlers/QueueHandler.sol";

/// @dev Stateful-fuzz invariants for the redemption queue (CLAUDE.md §1.3):
///      - OVER-DISTRIBUTION: settled assets never exceed the settlement's snapshot
///        budget (asserted per settlement in the handler, across chunked closes)
///      - FIFO: requests before the head are fully filled; requests after it are
///        untouched — ordering never inverts
///      - NO DOUBLE-CLAIM: claims pay exactly once (per-call assert) and custody
///        reconciles: queue USDfr == Σ unclaimed fills, queue shares == Σ queued
///      - ZERO-VALUE FILL (AUDIT C-1): a `RequestFilled` with shares > 0 must always
///        carry assets > 0 — a settlement may never burn a position for nothing
///      - LIVENESS (C-1 REMEDIATION): a settlement that REFUSES to settle must not be
///        denying a request that could have been paid. Asserted at the revert site in
///        `QueueHandler._assertNoPayableRequestWasDenied`, because the property is only
///        meaningful at the moment `closeEpoch` reverts. The handler previously tolerated
///        `Queue_NoLiquidity` unconditionally, which made a permanently bricked queue read
///        green; it is now selector-checked AND liveness-checked.
///      - BACKING + MONOTONICITY continue to hold through queue traffic
contract RedemptionQueueInvariants is CreditLayerFixture {
    QueueHandler internal handler;
    MockImpairmentSource internal impairmentSource;

    function setUp() public override {
        super.setUp();
        // Drive both ADR-0022 views independently. The previous single-slot mock collapsed
        // redemption NAV and performance-fee NAV into one value, making the dual-NAV exit
        // law unreachable throughout the queue assurance tier.
        impairmentSource = new MockImpairmentSource();
        vm.prank(admin);
        vault.setImpairmentSource(address(impairmentSource));
        handler = new QueueHandler(
            usdc, usdfr, compliance, reserves, controller, vault, queue, complianceAdmin, impairmentSource
        );
        // AUDIT FIX (D7-01): `closeEpoch` is keeper-gated, and the handler calls it with itself
        // as `msg.sender`. Without this grant EVERY settlement in the campaign reverts on access
        // control. That would be caught — `closeEpochChunk` tolerates exactly three selectors and
        // asserts on anything else — but the grant belongs here regardless: the handler stands in
        // for the keeper, and the campaign must exercise settlement, not the modifier.
        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, address(handler));
        // AUDIT FINDING (campaign 5): the handler also stands in for GOVERNANCE, for exactly two
        // setters and for the duration of one action. `probeWithheldCredit` has to put
        // `availableLiquidity()` inside a window one `MIN_RESIDUE_VALUE` wide above the entry
        // floor; at the shipped 167 bps and a $1 floor that means an idle reserve of $59.88, which
        // no campaign that has ever staked anything can reach. The probe therefore widens the
        // floor to its hard maximum and narrows the liquidity share to 1 bp, and RESTORES BOTH on
        // every exit path — see `QueueHandler._openWithholdingWindow`. Without this grant that
        // guard is unreachable and the campaign is back to the state the finding recorded.
        // This is NOT coverage of the setters' access control; that lives in
        // `AccessControlSurfaceInvariants`, which runs its own fixture.
        // (read the role BEFORE the prank — a view call would consume it)
        bytes32 queueAdminRole = queue.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        queue.grantRole(queueAdminRole, address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = QueueHandler.stake.selector;
        selectors[1] = QueueHandler.request.selector;
        selectors[2] = QueueHandler.closeEpochChunk.selector;
        selectors[3] = QueueHandler.claim.selector;
        selectors[4] = QueueHandler.addLiquidity.selector;
        selectors[5] = QueueHandler.drainLiquidity.selector;
        selectors[6] = QueueHandler.donateToVault.selector;
        selectors[7] = QueueHandler.warp.selector;
        selectors[8] = QueueHandler.setImpairment.selector;
        selectors[9] = QueueHandler.setDualImpairment.selector;
        // AUDIT G11/G12.2: the UNFILTERED sub-floor request. Without this selector registered the
        // campaign never presents `requestRedeem` with an inadmissible input and the entry-floor
        // guard is never executed. Removing it re-opens the vacuity this finding recorded.
        selectors[10] = QueueHandler.requestBelowFloor.selector;
        // AUDIT FINDING (campaign 5, 2 x HIGH): the four deliberate drivers into the Q-01 / A1 /
        // claim-owner illegal regions. WITHOUT THESE FOUR SELECTORS the campaign is back to the
        // state the finding recorded: deleting the residue-margin block, its
        // `previewRedeem(budgetShares) != 0` conjunct, the `+ withheld` credit or the claim owner
        // check leaves every campaign green. Removing any of them re-opens exactly that hole.
        selectors[11] = QueueHandler.probeResidueMargin.selector;
        selectors[12] = QueueHandler.probeCompleteAtZeroPrice.selector;
        selectors[13] = QueueHandler.probeWithheldCredit.selector;
        selectors[14] = QueueHandler.claimAsNonOwner.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (queue FIFO, §1.3): ordering never inverts.
    function invariant_queue_fifoHolds() public view {
        assertTrue(handler.fifoHolds(), "FIFO INVERTED");
    }

    /// @notice Internal aggregate-versus-parts consistency check.
    /// @dev This is deliberately not claimed as an independent correctness oracle. The
    ///      event-reconstructed model lives in `ProductionQueueInvariants.t.sol`.
    function invariant_queue_internalAggregateMatchesItems() public view {
        assertEq(vault.balanceOf(address(queue)), queue.totalQueuedShares(), "SHARE CUSTODY DRIFTED");
        assertEq(queue.totalQueuedShares(), handler.sumSharesRemaining(), "QUEUED SHARES != SUM OF REQUESTS");
        assertEq(usdfr.balanceOf(address(queue)), handler.sumClaimable(), "ASSET CUSTODY != UNCLAIMED FILLS");
        assertEq(
            handler.ghostTotalFilled(),
            handler.ghostTotalClaimed() + handler.sumClaimable(),
            "FILLED != CLAIMED + CLAIMABLE"
        );
    }

    /// @notice INVARIANT (backing, ADR-0012) through queue traffic.
    function invariant_backing_holdsThroughQueueTraffic() public view {
        assertLe(controller.totalUSDfr(), controller.backingValue(), "BACKING VIOLATED");
    }

    /// @notice INVARIANT (monotonicity): no queue operation lowers the exchange rate
    ///         (there are no loss events in this handler).
    /// @dev AUDIT R15-04. This previously compared the live rate against `handler.rateFloor()`,
    ///      which the handler re-anchors to the post-action rate as the last state-touching
    ///      statement of every registered selector — so the assertion was `assertGe(x, x)` and
    ///      made no cross-call statement. The real check is per-call inside
    ///      `_assertAndAdvanceRateFloor`, which bounds any drop by the ERC-4626 rounding
    ///      discontinuity and then requires an observable protocol-fee witness plus the geometric
    ///      fee-retention floor. This asserts that verdict rather than restating a tautology.
    function invariant_exchangeRate_neverFallsFromQueueOps() public view {
        assertFalse(handler.sawUnexplainedRateDrop(), "RATE FELL FROM QUEUE TRAFFIC WITHOUT A FEE CAUSE");
    }

    /// @notice INVARIANT (ADR-0031 dual-NAV hurdle law): the asset hurdle after
    ///         a deposit or a one-exit queue chunk equals the independently derived
    ///         pre-flow carry, within one HWM-rate rounding unit.
    /// @dev The handler derives the deposit law as `H + assets` and the exit law as
    ///      `max(H - assets, H * postSupply / preSupply)`. It does not consult the
    ///      post-flow HWM to decide whether a fee or decline was legitimate.
    function invariant_feeHurdle_followsPreFlowReferenceLaw() public view {
        assertFalse(handler.hurdleCarryViolation(), "FEE HURDLE FLOW LAW VIOLATED");
    }

    /// @notice INVARIANT (AUDIT C-1, CRITICAL): a settlement never burns shares for zero
    ///         assets. Under a declared senior impairment the conservative redemption base
    ///         collapses, and the pre-fix code filled a request's ENTIRE position at a price
    ///         of zero — permanently destroying it. Any fill with shares > 0 must return
    ///         assets > 0; otherwise the position stays queued.
    function invariant_queue_neverFillsForZeroAssets() public view {
        assertFalse(handler.sawZeroValueFill(), "POSITION BURNED FOR ZERO ASSETS");
    }

    // ─────────────────────────────────────────────────────────────────────
    // AUDIT FINDING (campaign 5, 2 x HIGH): "BOTH ARMS OF THE Q-01 FIX ARE DELETABLE WITH EVERY
    // STATEFUL CAMPAIGN GREEN", plus the `+ withheld` credit and `claim`'s owner check.
    //
    // These four invariants are the campaign's verdict on guards that the deterministic audit
    // suites caught and the stateful tier did not. Each one reads a ghost that
    // `QueueHandler`'s deliberate probes write; the probes construct the illegal region rather
    // than waiting for the fuzzer to wander into a window ~1e-6 USDfr wide.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice INVARIANT (Q-01 ARM A, HIGH): a partial fill never leaves a residue worth less
    ///         than `MIN_RESIDUE_VALUE` at the rate that priced it.
    /// @dev A sub-margin residue is a PERMANENT WEDGE: next settlement the residue IS the head,
    ///      the C-1 value guard prices it at zero, and `Queue_HeadNotRedeemable` reverts
    ///      `closeEpoch` wholesale for every request behind it, with no cancel path (ADR-0018)
    ///      and no parameter that cures it.
    /// @dev The check runs at the moment of the fill (`QueueHandler._recordFillsAndCheckResidue
    ///      Margin`), not over open requests here: a later declared impairment legitimately
    ///      re-prices an already-compliant residue below the margin, and an invariant that
    ///      scanned open requests would have to be weakened until it said nothing.
    function invariant_queue_partialFillAlwaysLeavesTheResidueMargin() public view {
        assertFalse(
            handler.sawSubMarginResidue(),
            "Q-01 ARM A VIOLATED: a partial fill left a residue inside the zero-value window"
        );
    }

    /// @notice INVARIANT (Q-01 ARM B, HIGH): a head whose budget-capped fill prices to ZERO is
    ///         preserved, never completed.
    /// @dev Without the `previewRedeem(budgetShares) != 0` conjunct the COMPLETE branch fires in
    ///      exactly the state where the pre-fix code reached `assetsOut == 0` and preserved the
    ///      head — draining an entire position for as little as one wei. Note what does NOT catch
    ///      it: the fill is worth 1 wei, not 0, so `invariant_queue_neverFillsForZeroAssets` stays
    ///      green; FIFO, custody and the budget ceiling all reconcile.
    function invariant_queue_zeroPricedBudgetFillNeverCompletesTheHead() public view {
        assertFalse(
            handler.sawZeroPricedHeadDrained(),
            "Q-01 ARM B VIOLATED: a position was drained by the COMPLETE branch for a fill worth zero"
        );
    }

    /// @notice INVARIANT (A1 abandon guard): the protocol's own deliberate withholding can never
    ///         be the reason a settlement misses its captured economic floor.
    /// @dev `previewRedeem(fillShares) + withheld == previewRedeem(budgetCappedFill)` is an
    ///      identity, so with the credit the guard evaluates bit-for-bit the predicate the
    ///      pre-Q-01 code evaluated. Delete the credit and a payable settlement is abandoned and
    ///      rolled back — and a rolled-back settlement leaves every ledger reconciling, which is
    ///      why nothing else here sees it.
    function invariant_queue_withholdingNeverCostsASettlementItsFloor() public view {
        assertFalse(
            handler.sawWithholdingCostASettlementItsFloor(),
            "A1 CREDIT VIOLATED: a settlement the budget could pay for was abandoned over its own withholding"
        );
    }

    /// @notice INVARIANT (§1.3 access control): `claim` is reachable only by the request owner.
    function invariant_queue_claimIsOwnerOnly() public view {
        assertFalse(handler.sawNonOwnerClaim(), "CLAIM OWNER GUARD VIOLATED: a non-owner claimed");
    }

    /// @notice INVARIANT (aggregate): no registered guard was ever bypassed.
    /// @dev One number carries every probe's verdict — reverting and behavioural alike — out of
    ///      the handler, including probes whose state change was rolled back by the guard itself.
    function invariant_queue_noRegisteredGuardWasBypassed() public view {
        assertEq(
            handler.guardAdmissions(),
            0,
            string(abi.encodePacked("GUARD BYPASSED: ", handler.guardLabel(handler.lastAdmittedGuard())))
        );
    }

    /// @notice Anti-vacuity. `settlementsUnderImpairment` is the C-1 witness: settlements
    ///         actually executed while the conservative exit base was marked below the realized
    ///         base. It is measured (a few per run) but NOT asserted, because a given 128-call
    ///         sequence may never line up impairment + cooldown + heartbeat + liquidity, which
    ///         would make the assertion flaky. Non-vacuity is proven deterministically instead:
    ///         reverting the C-1 guard makes `invariant_queue_neverFillsForZeroAssets` fail, and
    ///         `test/audit/Fix_C01-queue-zero-value-fill.t.sol` reproduces the loss directly.
    function invariant_reachTelemetry() public view {
        handler.callCount();
        handler.settlementsUnderImpairment();
        // AUDIT G11/G12.2: `minAdmittedEntryValue` is a MEASUREMENT of the admissible band the
        // handler chose, not evidence about the contract — see its declaration. The entry floor's
        // real reach witnesses are the two beside it.
        handler.minAdmittedEntryValue();
        handler.subFloorAttempts();
        handler.subFloorRefusals();
        // measured reach witnesses (not asserted, per the anti-vacuity note above): confirm the
        // $1 entry floor left the interesting settlement states reachable — the loud C-1 stop, the
        // budget block, positive fills, and the cooldown hold.
        handler.loudStops();
        handler.noLiquidityStops();
        handler.cooldownStops();
        handler.positiveSettlements();
        handler.dualNavStates();
        handler.hurdleCarryChecks();
        // AUDIT FINDING (campaign 5): reach witnesses for the four repaired guards. Measured, not
        // asserted per run — a sequence whose board never clears legitimately makes no probe. The
        // seed-independent claims are the four deterministic companions below, and
        // `probeSetupAbandons` is reported so a run that assembled NOTHING says so out loud
        // instead of reading as coverage.
        handler.partialFillsObserved();
        handler.residueBandProbes();
        handler.completeAtZeroProbes();
        handler.withheldCreditProbes();
        handler.nonOwnerClaimProbes();
        handler.probeSetupAbandons();
    }

    // ── deterministic companions for the four repaired guards ────────────
    //
    // AUDIT FINDING (campaign 5). Each proves, seed-independently, that its probe ASSEMBLES the
    // illegal region — the claim `afterInvariant` cannot make, because it speaks for one run.
    // A probe that silently never assembles is the failure mode this whole finding is about.

    /// @notice Q-01 ARM A: the probe reaches the sub-margin band and the guard holds there.
    function test_queue_residueMarginProbeReachesTheIllegalBand() public {
        handler.probeResidueMargin(0);
        assertGt(handler.residueBandProbes(), 0, "VACUOUS: the arm-A probe never entered the sub-margin band");
        assertGt(handler.partialFillsObserved(), 0, "VACUOUS: the arm-A probe never produced a partial fill");
        assertFalse(handler.sawSubMarginResidue(), "arm A bypassed on the deterministic drive");
    }

    /// @notice Pins the handler's `MIN_RESIDUE_VALUE` mirror to the value the CONTRACT ships.
    /// @dev The contract's constant is private, so the arm-A post-condition is asserted against a
    ///      mirror in the handler. If the shipped constant were raised, the mirror would silently
    ///      police a weaker margin than the contract promises — the exact shape of a guard that
    ///      looks tested and is not. The probe leaves a residue of exactly
    ///      `previewWithdraw(MIN_RESIDUE_VALUE)`, so its priced value bounds the constant from
    ///      both sides.
    function test_queue_residueMarginIsProbedAtTheShippedConstant() public {
        handler.probeResidueMargin(0);
        (, uint256 remaining,,,) = queue.request(queue.head());
        assertGt(remaining, 0, "precondition: the probe must leave a residue");
        uint256 value = vault.previewRedeem(remaining);
        assertGe(value, 1e12, "the shipped MIN_RESIDUE_VALUE is BELOW the handler's mirror");
        assertLt(value, 2e12, "the shipped MIN_RESIDUE_VALUE is ABOVE the handler's mirror: the check is now weaker");
    }

    /// @notice Q-01 ARM B: the probe assembles the exactly-one-wei settlement budget with a head
    ///         priced at exactly one conservative wei, and the head survives.
    function test_queue_completeAtZeroProbeReachesTheOneWeiBudget() public {
        handler.probeCompleteAtZeroPrice(0);
        assertGt(handler.completeAtZeroProbes(), 0, "VACUOUS: the arm-B probe never assembled the 1-wei budget state");
        assertFalse(handler.sawZeroPricedHeadDrained(), "arm B bypassed on the deterministic drive");
    }

    /// @notice A1 `+ withheld` credit: the probe lands the settlement budget inside the window
    ///         where the credit is load-bearing, and the settlement commits.
    function test_queue_withheldCreditProbeReachesTheFloorWindow() public {
        handler.probeWithheldCredit(0);
        assertGt(handler.withheldCreditProbes(), 0, "VACUOUS: the credit probe never landed in the floor window");
        assertFalse(
            handler.sawWithholdingCostASettlementItsFloor(), "the '+ withheld' credit was bypassed on the drive"
        );
    }

    /// @notice The credit probe's governance window is PUT BACK, and its bounds are the shipped
    ///         ones.
    /// @dev Two failure modes this pins. (1) If the restore is ever skipped, every other property
    ///      in this campaign silently becomes a statement about a 1 bp liquidity share and a $100
    ///      entry floor — a configuration the protocol does not ship. (2) The handler mirrors
    ///      `MAX_MIN_REDEMPTION_VALUE` (private in the contract); if the shipped cap ever moves,
    ///      the window either stops opening or starts reverting, and the probe would quietly turn
    ///      into a no-op.
    function test_queue_governanceWindowIsRestoredAndMatchesTheShippedBounds() public {
        (uint64 durationBefore, uint16 bpsBefore) = queue.epochParams();
        uint256 floorBefore = queue.minRedemptionValue();
        assertEq(bpsBefore, Config.DEFAULT_EPOCH_LIQUIDITY_BPS, "precondition: shipped bps");
        assertEq(floorBefore, Config.DEFAULT_MIN_REDEMPTION_VALUE, "precondition: shipped floor");

        handler.probeWithheldCredit(0);
        assertGt(handler.withheldCreditProbes(), 0, "precondition: the probe must have opened the window");

        (uint64 durationAfter, uint16 bpsAfter) = queue.epochParams();
        assertEq(bpsAfter, bpsBefore, "epochLiquidityBps was NOT restored after the credit probe");
        assertEq(durationAfter, durationBefore, "epochDuration must not be touched at all");
        assertEq(queue.minRedemptionValue(), floorBefore, "minRedemptionValue was NOT restored");

        // and the mirrored cap is exactly the contract's: 100e18 is accepted, one wei more is not
        vm.startPrank(admin);
        queue.setMinRedemptionValue(100e18);
        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        queue.setMinRedemptionValue(100e18 + 1);
        queue.setMinRedemptionValue(floorBefore);
        vm.stopPrank();
    }

    /// @notice `claim` owner check: a foreign caller is refused with the exact error and operands.
    function test_queue_claimOwnerGuardRefusesEveryForeignCaller() public {
        handler.probeResidueMargin(0); // creates a partially filled request with a real claimable
        uint256 id = queue.head();
        (address owner,, uint256 claimable,,) = queue.request(id);
        assertGt(claimable, 0, "precondition: the probe must leave something claimable");

        uint256 probesBefore = handler.nonOwnerClaimProbes();
        handler.claimAsNonOwner(id, 0);
        assertEq(handler.nonOwnerClaimProbes() - probesBefore, 1, "the non-owner claim probe did not fire");
        assertFalse(handler.sawNonOwnerClaim(), "a non-owner claim was admitted");
        (,, uint256 stillClaimable,,) = queue.request(id);
        assertEq(stillClaimable, claimable, "a refused claim must move nothing");

        address stranger = makeAddr("queueStranger");
        assertTrue(stranger != owner, "pick a stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, stranger));
        queue.claim(id);
    }

    function afterInvariant() public view {
        assertGt(handler.callCount(), 0, "VACUOUS: queue handler executed no successful action");
        // AUDIT G11/G12: the per-guard reached / NOT-REACHED table. Reported, not asserted —
        // `afterInvariant` speaks for a single run, so a per-run floor on a probe that legitimately
        // early-returns would be a flaky gate. The seed-independent claim is
        // `test_queue_entryFloorRefusesEverySubFloorRequest`.
        handler.reachReport();
    }

    /// @notice INVARIANT (C-1 remediation, owner-approved 2026-07-22 — replaces the deferral
    ///         invariant). Deferral is GONE; the anti-dust-wedge protection is now an ENTRY FLOOR
    ///         plus STRICT FIFO. Two guarantees, pinned together:
    ///           (i)  ENTRY FLOOR — the queue REFUSES every request worth less than
    ///                `minRedemptionValue` at the realized rate. Dust is barred at the source, so a
    ///                sub-wei head (and thus the old wedge) cannot arise except under a catastrophic
    ///                full mark, where stopping the queue is correct.
    ///           (ii) STRICT FIFO, NO REORDERING — a fill of request[j] implies every earlier
    ///                request[i<j] is fully filled. With deferral removed there is no sanctioned
    ///                reordering; a regression that filled out of order fails here.
    ///
    /// @dev AUDIT G11/G12.2 — WHAT CHANGED AND WHY. Half (i) previously read
    ///          `assertGe(handler.minAdmittedEntryValue(), queue.minRedemptionValue())`.
    ///      That ghost is written only inside `QueueHandler.request()`, which — as
    ///      `fail_on_revert = true` obliges it to — first bounds its fuzzed share count into the
    ///      admissible band `[previewWithdraw(floor), balance]`. The assertion was therefore a
    ///      restatement of the handler's own `bound()` and would have held with the guard at
    ///      `RedemptionQueue.sol:255` deleted outright. Worse, because no handler action ever
    ///      presented an inadmissible request, the guard was never executed by the invariant tier
    ///      at all.
    ///      It now asserts the CONTRACT's verdict on inputs the handler deliberately steers into
    ///      the illegal region (`QueueHandler.requestBelowFloor`), which is the only form of this
    ///      property that can fail if the floor is removed. DO NOT revert this to a comparison
    ///      against `minAdmittedEntryValue`.
    function invariant_queue_entryFloorAndStrictFifo() public view {
        assertFalse(
            handler.sawSubFloorAdmission(),
            "ENTRY FLOOR VIOLATED: the queue admitted a request worth less than minRedemptionValue"
        );
        assertTrue(handler.strictFifoNoReordering(), "FIFO REORDERED: a later request filled before an earlier one");
    }

    /// @notice ANTI-VACUITY FOR THE ENTRY FLOOR, deterministic and seed-independent.
    /// @dev The campaign's sub-floor attempt count is reported by `invariant_reachTelemetry`, but
    ///      it cannot be ASSERTED there: `afterInvariant` speaks for one run, and a run whose
    ///      actors happen to hold no shares makes no admissible attempt. This test constructs the
    ///      state instead, so the guard is proven live on every CI run. It is also the mutation
    ///      target: delete the `Queue_BelowMinRedemption` branch and this goes red immediately.
    function test_queue_entryFloorRefusesEverySubFloorRequest() public {
        uint256 floor = queue.minRedemptionValue();
        assertGt(floor, 0, "precondition: the fixture must run with the entry floor enabled");

        handler.stake(0, 1_000_000e6); // give actor 0 a real position
        uint256 minShares = vault.previewWithdraw(floor);
        assertGt(minShares, 1, "precondition: the floor must be worth more than one share");

        uint256 refusalsBefore = handler.subFloorRefusals();
        uint256 attemptsBefore = handler.subFloorAttempts();
        // 1 share, half the floor, and one share short of the floor: the boundary and its interior
        handler.requestBelowFloor(0, 0);
        handler.requestBelowFloor(0, type(uint256).max);
        handler.requestBelowFloor(0, minShares / 2);

        assertEq(handler.subFloorAttempts() - attemptsBefore, 3, "the sub-floor probe did not fire");
        assertEq(
            handler.subFloorRefusals() - refusalsBefore,
            3,
            "the entry floor did not refuse with Queue_BelowMinRedemption"
        );
        assertFalse(handler.sawSubFloorAdmission(), "a sub-floor request was admitted");
        assertEq(handler.trackedCount(), 0, "a refused request must leave no queue entry behind");

        // and the exact error, with its exact operands — CLAUDE.md §1.1
        address actor = handler.actors(0);
        uint256 shares = minShares - 1;
        uint256 value = vault.convertToAssets(shares);
        vm.startPrank(actor);
        vault.approve(address(queue), shares);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, value, floor));
        queue.requestRedeem(shares);
        vm.stopPrank();
    }

    /// @dev Deterministic replay of the minimized stateful-fuzz sequence that crosses a
    ///      performance-fee boundary on the final donation while marked NAV is below realized
    ///      NAV. The fee-net realized rate may dip because fee shares price at marked NAV, but
    ///      the drop must have a live fee witness and remain within the configured retention.
    function test_replayDonationFeeBoundary() public {
        handler.stake(94446426643442109126640261916808043146796632266977683132435080660167634197544, 2333676741);
        handler.addLiquidity(355360995128290207526555867154017053217, 3239848503639513299632596982123011963);
        handler.request(type(uint256).max - 1, 2);
        handler.donateToVault(15029, 5048);
        handler.setImpairment(22039);
        handler.addLiquidity(101813707234905528312600269383929285169089729197245048122744754035109822201857, 17480);
        handler.warp(1316048495971916762851034678043622395748160509573944438);
        handler.donateToVault(1046363171, 20515);
        handler.closeEpochChunk(272228);
        handler.setImpairment(82958233443515981797617248150871913915139671888812545405552);
        handler.addLiquidity(7916, 1663);
        handler.stake(11442, 19897);
        handler.claim(56126904728136);
        handler.addLiquidity(3194, 3468);
        handler.addLiquidity(122, type(uint256).max - 1);
        handler.donateToVault(64157510423, 0);
        handler.donateToVault(6660766673705532623945607677468126048052062289164, 14);
        handler.donateToVault(1434492526631, 1068402467652765715914788239152104767859890020550378540063);
        handler.request(22005, 8894);

        uint256 actorSeed = 114685323391364422540926128203744780688149623448181870419688387382330015790308;
        uint256 amountSeed = 1060804828604824288318705940506914651891775092770903821469780513244836411995;
        address actor = handler.actors(actorSeed % 3);
        uint256 amount = bound(amountSeed, 1, usdfr.balanceOf(actor));
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 markedAssetsBefore = vault.redemptionTotalAssets();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(actor);
        usdfr.transfer(address(vault), amount);

        uint256 rateAfter = vault.currentExchangeRate();
        assertEq(vault.totalAssets(), totalAssetsBefore + amount, "donation must increase realized NAV exactly");
        assertEq(
            vault.redemptionTotalAssets(), markedAssetsBefore + amount, "donation must increase marked NAV exactly"
        );
        assertLt(rateAfter, rateBefore, "regression must reach the conservative-NAV fee boundary");
        assertGt(vault.feeExchangeRate(), vault.highWaterMark(), "rate dip must have a pending-fee witness");
        uint256 retainedRate = rateBefore * (10_000 - vault.performanceFeeBps()) / 10_000;
        assertGe(rateAfter, retainedRate, "pending performance fee exceeded its finite dilution bound");

        (uint256 managementShares, uint256 performanceShares) = vault.accrueFees();
        assertEq(managementShares, 0);
        assertGt(performanceShares, 0);
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore + performanceShares);
        assertEq(vault.currentExchangeRate(), rateAfter, "fee preview and crystallization must be continuous");
        assertGe(vault.highWaterMark(), vault.feeExchangeRate(), "checkpoint must clear the pending fee");
    }
}
