// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {ProductionCreditFixture, SignedOracleDriver} from "../helpers/ProductionCreditFixture.sol";
import {CascadeSeniorityHandler} from "./handlers/CascadeSeniorityHandler.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title INV_CascadeSeniority — Phase D invariant suite for SENIORITY AND THE LOSS CASCADE
/// @notice Independent audit deliverable. Encodes `audit/SYSTEM_MODEL.md` section 6:
///
///   INV-5 (cascade ordering)       losses absorb curator first-loss -> sGROVE coverage ->
///                                  senior principal, in that order, never skipping or
///                                  inverting a layer, and never touching layer N+1 while
///                                  layer N still has capacity.
///   INV-6 (senior not subordinated) curator capital is never paid from repayments; it is
///                                  released only as exposure falls; sUSDfr receives all
///                                  interest after the protocol fee.
///   INV-7 (subordination headroom)  curatorWithdrawable <= poolBalance -
///                                  min(firstLossTarget, classExposure), at all times.
///
/// @dev WHY THIS SUITE EXISTS ALONGSIDE `test/invariant/CreditInvariants.t.sol`.
///      That suite checks the cascade min-chain, but its reference model reads the CONTRACTS'
///      own pre-call balances and per-event ledger. It therefore cannot falsify a wrong
///      CAPACITY — a mis-accounted curator pool would be inherited by the reference model and
///      the two would agree. This suite rebuilds every capacity from the handler's own inputs
///      and makes the model-versus-contract equality an invariant in its own right
///      (`invariant_INV5_layer1CapacityMatchesIndependentModel`,
///      `invariant_INV5_layer2CapacityMatchesIndependentModel`). It also runs cascade layer 2
///      against the REAL `SGrove` rather than `MockCascadeBackstop`, over four collateral
///      classes rather than one, with ADR-0035's one shared reserve actively driven through
///      funded-slack, reserve-binding, exhaustion, and replenishment regimes.
///
///      ANTI-VACUITY IS ASSERTED, NOT LOGGED. `afterInvariant()` fails the campaign if the
///      interesting states were never reached: no loss realized, no layer actually charged, no
///      reserve-binding draw, no curator pool ever wiped, no interest ever distributed, no
///      frozen withdrawal ever refused. A green campaign that never got there is worse than no
///      campaign.
///
///      `fail_on_revert = true` (repo default) is load-bearing and is NOT relaxed here.
contract INV_CascadeSeniority is ProductionCreditFixture {
    CascadeSeniorityHandler internal cascadeHandler;

    function setUp() public override {
        super.setUp();

        SignedOracleDriver oracleDriver = new SignedOracleDriver(realOracle, admin, attesterPk1, attesterPk2);
        cascadeHandler = new CascadeSeniorityHandler(
            CascadeSeniorityHandler.Wiring({
                usdc: address(usdc),
                usdfr: address(usdfr),
                reserves: address(reserves),
                controller: address(controller),
                vault: address(vault),
                registry: address(registry),
                bridge: address(bridge),
                oracle: address(oracleDriver),
                curator: address(curator),
                waterfall: address(waterfall),
                defaultManager: address(defaultManager),
                sGrove: address(sGrove),
                admin: admin,
                guardian: guardian,
                servicer: servicer,
                originator: originator,
                custodian: custodian,
                borrower: borrower,
                feeRecipient: feeRecipient,
                curatorA: anchorCurator,
                curatorB: secondCurator,
                senior: alice,
                coverageFunder: bob
            })
        );

        // Deterministic floor for the `afterInvariant` anti-vacuity assertions. Forge restarts
        // every run from the post-`setUp` state and `afterInvariant` samples ONE run, so narrow
        // shapes cannot be asserted on a single run's fuzz luck without flaking. The wiring
        // tooth stays `fuzzActionEntries` / `fuzzRealizeEntries`, which the seed never touches.
        cascadeHandler.seedCascadeShapes();

        targetContract(address(cascadeHandler));

        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = CascadeSeniorityHandler.depositSenior.selector;
        selectors[1] = CascadeSeniorityHandler.postFirstLoss.selector;
        selectors[2] = CascadeSeniorityHandler.withdrawFirstLoss.selector;
        selectors[3] = CascadeSeniorityHandler.curatorRaceWithdrawThenDefault.selector;
        selectors[4] = CascadeSeniorityHandler.fundCoverage.selector;
        // ADR-0035 identity probe: capacity must remain exactly the shared live reserve.
        selectors[5] = CascadeSeniorityHandler.checkUncappedCapacity.selector;
        // INV-7's inputs must MOVE while the headroom formula is under test, not sit static.
        selectors[6] = CascadeSeniorityHandler.setFirstLossTarget.selector;
        selectors[7] = CascadeSeniorityHandler.originateAndFund.selector;
        selectors[8] = CascadeSeniorityHandler.repay.selector;
        selectors[9] = CascadeSeniorityHandler.declareDefault.selector;
        selectors[10] = CascadeSeniorityHandler.liftDefaultFreeze.selector;
        selectors[11] = CascadeSeniorityHandler.realizeLoss.selector;
        // The Phase-C-named outstanding interaction, driven inside the campaign as well as by the
        // seed: a fully wiped curator round together with a reserve-bound layer-2 draw.
        selectors[12] = CascadeSeniorityHandler.stressWipedRoundWithReserveBound.selector;
        // Fee accrual runs alongside every cascade leg and is time-dependent; a static clock
        // would hide any interaction between fee dilution and the cascade.
        selectors[13] = CascadeSeniorityHandler.writeDownReserveCustodyLoss.selector;
        selectors[14] = CascadeSeniorityHandler.warp.selector;
        // AUDIT R6-CF1. Governance closing an adjudicated custody incident is the ONLY legitimate
        // release of the curator custody freeze. Without this caller the campaign's first custody
        // loss would leave the freeze armed for the rest of every run, and INV-7's positive
        // withdrawal branch would be starved — coverage lost silently behind a green campaign.
        selectors[15] = CascadeSeniorityHandler.closeCustodyIncident.selector;
        // AUDIT FINDING (campaign 5). The two entry guards on `DefaultManager.absorbReserveLoss`
        // had NO coverage of any kind: not deterministic, not stateful. They are hand-rolled
        // `msg.sender`/namespace checks rather than `onlyRole` modifiers, so the runtime `onlyRole(`
        // enumeration behind `AccessControlSurfaceInvariants` is structurally blind to them.
        // Registering this selector is the whole point — the handler function alone would be dead
        // code that merely READS as coverage.
        //
        // MERGE NOTE (2026-08-07): R6-CF1 and this finding EACH landed a 16th action on this
        // handler independently, and each pinned `new bytes4[](16)` with itself at index 15. A
        // textual merge would have silently dropped one of the two and turned its invariant into
        // decoration. Both are registered here, the array is [17], and
        // `test_wiring_everyHandlerActionIsRegistered` is re-derived below over all seventeen.
        selectors[16] = CascadeSeniorityHandler.probeReserveLossEntryGuards.selector;
        // AUDIT FIX (SWEEP-2 CSG-F1). The one loss path with NO freeze — and the region this
        // campaign could not reach at all: `CascadeSeniorityHandler` had zero `markPastDue`
        // occurrences, so INV-7 stayed green through a measured HIGH in which layer-1 capital the
        // conservative senior NAV was crediting walked out. Registering both selectors is
        // load-bearing: the mark opens the region and the cure lets the campaign leave it, so
        // INV-7's POSITIVE branch is not starved for the rest of every run.
        selectors[17] = CascadeSeniorityHandler.markPastDue.selector;
        selectors[18] = CascadeSeniorityHandler.clearPastDueMark.selector;
        targetSelector(FuzzSelector({addr: address(cascadeHandler), selectors: selectors}));

        // Keep the protocol's own accounts out of the fuzzer's sender set: every action here is
        // executed through an explicit `vm.prank` by the role that is actually entitled to it.
        excludeSender(address(cascadeHandler));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SELECTOR-REGISTRATION GUARD (deterministic; not an invariant)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Every action this handler exposes MUST be in the `targetSelector` whitelist.
    /// @dev Adding a handler function does nothing if the suite has a selector whitelist and the
    ///      new selector was not registered — the function is then dead code that reads as extra
    ///      coverage. `afterInvariant` cannot catch that reliably: a per-run "this selector fired"
    ///      counter flakes, because with fourteen selectors the chance a specific one is never
    ///      drawn in a `depth`-call run is `(14/15)^depth` — about 11% at lite's depth 32, 1.4e-4
    ///      at the default depth of 128, and 5.6e-9 at heavy's 256. Over 256 default-profile runs
    ///      that is a genuine ~1.9% campaign flake, which is not acceptable in a permanently
    ///      shipped suite.
    ///      This test is the deterministic replacement: it fails immediately and every time if a
    ///      selector is missing, without depending on fuzz luck at all.
    function test_wiring_everyHandlerActionIsRegistered() public view {
        FuzzSelector[] memory targeted = targetSelectors();
        assertEq(targeted.length, 1, "expected exactly one targeted selector set");
        assertEq(targeted[0].addr, address(cascadeHandler), "selector set is not bound to the handler");

        bytes4[19] memory expected = [
            CascadeSeniorityHandler.depositSenior.selector,
            CascadeSeniorityHandler.postFirstLoss.selector,
            CascadeSeniorityHandler.withdrawFirstLoss.selector,
            CascadeSeniorityHandler.curatorRaceWithdrawThenDefault.selector,
            CascadeSeniorityHandler.fundCoverage.selector,
            CascadeSeniorityHandler.checkUncappedCapacity.selector,
            CascadeSeniorityHandler.setFirstLossTarget.selector,
            CascadeSeniorityHandler.originateAndFund.selector,
            CascadeSeniorityHandler.repay.selector,
            CascadeSeniorityHandler.declareDefault.selector,
            CascadeSeniorityHandler.liftDefaultFreeze.selector,
            CascadeSeniorityHandler.realizeLoss.selector,
            CascadeSeniorityHandler.stressWipedRoundWithReserveBound.selector,
            CascadeSeniorityHandler.writeDownReserveCustodyLoss.selector,
            CascadeSeniorityHandler.warp.selector,
            CascadeSeniorityHandler.closeCustodyIncident.selector,
            CascadeSeniorityHandler.probeReserveLossEntryGuards.selector,
            CascadeSeniorityHandler.markPastDue.selector,
            CascadeSeniorityHandler.clearPastDueMark.selector
        ];
        assertEq(targeted[0].selectors.length, expected.length, "registered selector count != action count");
        for (uint256 i = 0; i < expected.length; ++i) {
            bool found;
            for (uint256 j = 0; j < targeted[0].selectors.length; ++j) {
                if (targeted[0].selectors[j] == expected[i]) found = true;
            }
            assertTrue(found, "a handler action is missing from the targetSelector whitelist");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INV-5 — cascade ordering
    // ─────────────────────────────────────────────────────────────────────

    /// @notice INV-5 (conservation across the three layers). Every realized loss is fully and
    ///         exactly allocated: curator first-loss + sGROVE coverage + senior principal equals
    ///         the loss. Nothing created, nothing destroyed, nothing left unallocated.
    /// @dev All four accumulators are the handler's OWN modeled splits, and each was asserted
    ///      against measured token movements at the moment it was recorded. This invariant is the
    ///      standing statement that they still reconcile in aggregate.
    function invariant_INV5_cascadeAllocatesEveryLossExactly() public view {
        assertEq(
            cascadeHandler.ghostAbsorbedL1() + cascadeHandler.ghostCoveredL2() + cascadeHandler.ghostBurnedL3(),
            cascadeHandler.ghostLossRealized(),
            "INV-5: the three cascade layers do not sum to the realized loss"
        );
    }

    /// @notice INV-5 (ordering). Layer 2 never draws while layer 1 has first-loss capacity, and
    ///         layer 3 never burns senior principal while either junior layer has capacity.
    /// @dev Both counters are incremented by the handler's per-call differential model, which
    ///      computes each layer's capacity from the handler's OWN posts, withdrawals, coverage
    ///      funding and the shared live reserve — never from the contracts' own residuals.
    function invariant_INV5_neverSkipsOrInvertsALayer() public view {
        assertEq(
            cascadeHandler.ghostL2DrewWithL1Capacity(),
            0,
            "INV-5: sGROVE coverage was drawn while curator first-loss remained"
        );
        assertEq(
            cascadeHandler.ghostL3BurnedWithJuniorCapacity(),
            0,
            "INV-5: senior principal was burned while a junior layer still had capacity"
        );
    }

    /// @notice CLAUDE.md §1.3 (access control) for the CUSTODY-loss entry point.
    ///         `DefaultManager.absorbReserveLoss` — the single call that burns curator first-loss,
    ///         draws the sGROVE backstop and burns senior principal for a custody loss — admits
    ///         NOBODY but the bound ReserveManager, and admits NO facility-namespace incident id,
    ///         in ANY state this campaign reaches.
    /// @dev AUDIT FINDING (campaign 5). Both guards are hand-rolled `if (...) revert` checks, not
    ///      `onlyRole` modifiers, so `AccessControlSurfaceInvariants` — which builds its probe
    ///      table by scanning `src/` for the literal `onlyRole(` — cannot see either one. They had
    ///      ZERO executions anywhere in the repository: 8 of the 13 reserve-cascade custom errors
    ///      were never referenced by any test, and `DefaultManager_ReserveLossCallerNotReserve`,
    ///      the SOLE access control on the entry point, was never fired at all.
    ///
    ///      `guardAdmissions` is what carries a bypass out of the handler: the probe fires the raw
    ///      call, so when a guard holds the EVM has already rolled the attempt back and there is no
    ///      state left to assert on. If a guard is deleted the call really executes the cascade,
    ///      the counter increments, and this fails on the next evaluation.
    function invariant_reserveLossEntryGuardsAdmitNoOutsider() public view {
        assertEq(
            cascadeHandler.guardAdmissions(),
            0,
            "DefaultManager.absorbReserveLoss admitted a call it must refuse (see lastAdmittedGuard)"
        );
    }

    /// @notice INV-5 (layer 1 capacity is what the model says it is). The curator module's pool
    ///         balances, share supply, share round and total USDfr custody are reproduced exactly
    ///         from the handler's own posts, withdrawals and modeled absorptions.
    /// @dev This is the check the existing suite structurally cannot make: it proves the CAPACITY
    ///      the ordering rule is evaluated against is itself correct, not merely self-consistent.
    function invariant_INV5_layer1CapacityMatchesIndependentModel() public view {
        uint256 modeled;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(curator.poolBalance(c), cascadeHandler.mPool(c), "INV-5: curator pool balance != model");
            assertEq(curator.poolShares(c), cascadeHandler.mShares(c), "INV-5: curator share supply != model");
            assertEq(curator.poolRound(c), cascadeHandler.mRound(c), "INV-5: curator share round != model");
            assertEq(
                curator.unresolvedDefaults(c), cascadeHandler.mFrozen(c), "INV-5: unresolved-default count != model"
            );
            modeled += cascadeHandler.mPool(c);
        }
        assertEq(
            usdfr.balanceOf(address(curator)),
            modeled,
            "INV-5: curator module USDfr custody != the sum of the modeled pools"
        );
    }

    /// @notice INV-5 (layer 2 capacity is what the model says it is). The sGROVE coverage reserve
    ///         and cumulative per-event observability are reproduced exactly. ADR-0035's second
    ///         event-view word is computed as `drawn + live reserve`, never snapshotted.
    function invariant_INV5_layer2CapacityMatchesIndependentModel() public view {
        assertEq(sGrove.coverageReserve(), cascadeHandler.mCoverageReserve(), "INV-5: sGROVE coverage reserve != model");
        assertEq(
            usdfr.balanceOf(address(sGrove)),
            cascadeHandler.mCoverageReserve(),
            "INV-5: sGROVE USDfr custody != the modeled coverage reserve"
        );
        uint256 n = cascadeHandler.allFacilityCount();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = cascadeHandler.allFacilityAt(i);
            (uint256 drawn, uint256 cap) = sGrove.eventCoverage(id);
            assertEq(drawn, cascadeHandler.mEventDrawn(id), "INV-5: per-event coverage drawn != model");
            assertEq(cap, cascadeHandler.mEventCap(id), "INV-5: event live-reach view != model");
            assertEq(cap - drawn, sGrove.coverageReserve(), "INV-5: event view froze a stale snapshot");
        }
        // AUDIT R6-CF1: a closed incident's per-event ledger persists in SGrove, and governance
        // may now close one, so EVERY incident ever opened is checked rather than only the last.
        uint256 incidents = cascadeHandler.custodyIncidentCount();
        for (uint256 i = 0; i < incidents; ++i) {
            uint256 custodyId = cascadeHandler.custodyIncidentAt(i);
            (uint256 drawn, uint256 cap) = sGrove.eventCoverage(custodyId);
            assertEq(drawn, cascadeHandler.mEventDrawn(custodyId), "INV-5: custody coverage drawn != model");
            assertEq(cap, cascadeHandler.mEventCap(custodyId), "INV-5: custody live-reach view != model");
            assertEq(cap - drawn, sGrove.coverageReserve(), "INV-5: custody view froze a stale snapshot");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INV-6 — senior never subordinated
    // ─────────────────────────────────────────────────────────────────────

    /// @notice INV-6 (interest split). Cumulative distributed interest equals cumulative protocol
    ///         fee plus cumulative senior yield plus cumulative withheld fee, exactly.
    /// @dev The fee rate used is the handler's own `Config`-sourced constant, never
    ///      `WaterfallEngine.protocolFeeBps()`, so this cannot be satisfied by re-deriving the
    ///      production expression.
    /// @dev AUDIT FIX (ADV-1) — STRENGTHENED FROM TWO LEGS TO THREE, NOT WEAKENED. The two-way
    ///      identity `interest == fee + toVault` is false once a protocol fee may be WITHHELD and
    ///      retained as backing rather than minted. Folding `ghostFeeWithheldForImpairment` into
    ///      `ghostFeeToRecipient` would have kept this line green while breaking
    ///      `invariant_INV6_protocolFeeTookExactlyItsRate`, which reconciles against the fee
    ///      recipient's REAL balance — so the third leg is named, not absorbed. Every unit of
    ///      distributed interest still lands, to the wei, in exactly one of three modeled legs.
    function invariant_INV6_interestSplitsIntoFeeAndSeniorExactly() public view {
        assertEq(
            cascadeHandler.ghostFeeToRecipient() + cascadeHandler.ghostYieldToVault()
                + cascadeHandler.ghostFeeWithheldForImpairment(),
            cascadeHandler.ghostInterestPaid(),
            "INV-6: distributed interest != protocol fee + senior yield + withheld fee"
        );
    }

    /// @notice INV-6 (the senior claim, reconstructed end to end). The vault's USDfr assets equal
    ///         everything seniors deposited, plus every unit of post-fee interest routed to them,
    ///         minus exactly the cascade layer-3 burns they absorbed. No other flow may touch it.
    /// @dev This is the strongest form of "senior is never subordinated" available at rest: if
    ///      any repayment had been diverted to junior capital, or any junior layer had been paid
    ///      out of senior assets, this equality would break.
    function invariant_INV6_seniorAssetsAreExactlyDepositsPlusYieldMinusCascadeLoss() public view {
        assertEq(
            usdfr.balanceOf(address(vault)),
            cascadeHandler.ghostSeniorDeposited() + cascadeHandler.ghostYieldToVault() - cascadeHandler.ghostBurnedL3(),
            "INV-6: senior vault assets != deposits + post-fee interest - cascade layer-3 losses"
        );
    }

    /// @notice INV-6 (curator capital is never paid from repayments). Curator custody is exactly
    ///         what curators posted, less what they withdrew, less what the cascade absorbed —
    ///         and no distribution ever moved it.
    function invariant_INV6_curatorCapitalIsNeverPaidFromRepayments() public view {
        assertEq(
            cascadeHandler.ghostCuratorPaidFromRepayment(),
            0,
            "INV-6: a repayment moved value into curator first-loss capital"
        );
        assertEq(
            usdfr.balanceOf(address(curator)),
            cascadeHandler.modelCuratorTotal(),
            "INV-6: curator custody != posts - withdrawals - absorptions"
        );
    }

    /// @notice INV-6 (the protocol fee took exactly its rate and nothing more). The fee
    ///         recipient's USDfr holding equals the modeled origination fees plus the modeled
    ///         interest fees.
    /// @dev Both rates come from `Config`. A fee leg that over-collected at the senior's expense
    ///      breaks this and `invariant_INV6_seniorAssetsAre...` together.
    function invariant_INV6_protocolFeeTookExactlyItsRate() public view {
        assertEq(
            usdfr.balanceOf(feeRecipient),
            cascadeHandler.ghostOriginationFees() + cascadeHandler.ghostFeeToRecipient(),
            "INV-6: fee recipient holds more or less USDfr than the modeled fee rates allow"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INV-7 — subordination headroom
    // ─────────────────────────────────────────────────────────────────────

    /// @notice INV-7. `curatorWithdrawable <= poolBalance - requiredFirstLoss(class)` at all times,
    ///         where the requirement is
    ///         `max(min(firstLossTarget, classExposure), declaredDefaulted + pastDue)`.
    /// @dev The inequality is the audited claim; the equality below is the stronger statement the
    ///      implementation actually makes, and is asserted so a silently loosened formula fails
    ///      here rather than passing an inequality it happens to satisfy.
    ///
    ///      ══════════ AUDIT FIX (SWEEP-2 CSG-F1) — THIS INVARIANT WAS THE DEFECT'S ORACLE ══════
    ///      Until SWEEP-2 the model bound was `poolBalance - min(firstLossTarget, classExposure)`
    ///      and this test asserted the contract EQUALLED it. That formula is the one CSG-F1 showed
    ///      is too weak: the conservative senior NAV credits cascade layer 1 at
    ///      `min(declaredDefaulted + pastDue, poolBalance)`, which on any class whose exposure
    ///      exceeds its target is LARGER — so capital the senior redemption price was already
    ///      extending credit for was withdrawable, and this invariant CERTIFIED THAT AS CORRECT.
    ///      MEASURED: a curator withdrew 800,000e18 of layer-1 capital, the senior redemption price
    ///      fell 1,000,000e18 -> 650,000e18, and this campaign stayed green — partly because
    ///      `CascadeSeniorityHandler` has no `markPastDue` action at all, so the sharpest region is
    ///      never visited statefully. DO NOT NARROW THE MODEL BACK.
    function invariant_INV7_subordinationHeadroomHolds() public view {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 modelBound = cascadeHandler.modelHeadroom(c);
            assertLe(curator.headroom(c), modelBound, "INV-7: withdrawable exceeds the subordination headroom");
            assertEq(curator.headroom(c), modelBound, "INV-7: headroom diverged from the independent formula");
            // The exposure input itself must be the one the model believes it is, otherwise the
            // bound above could be satisfied against a wrong right-hand side.
            assertEq(registry.classExposure(c), cascadeHandler.mExposure(c), "INV-7: class exposure != model");
            assertEq(curator.firstLossTarget(c), cascadeHandler.mTarget(c), "INV-7: first-loss target != model");
        }
    }

    /// @notice INV-7 (enforced through timing, not just configuration). No completed withdrawal
    ///         ever left a pool below its subordination requirement, and no withdrawal was ever
    ///         accepted while the class carried an unresolved default.
    /// @dev The handler includes an explicitly adversarial action that pulls the maximum legal
    ///      first-loss and declares the default on the very next instruction
    ///      (`curatorRaceWithdrawThenDefault`), because withdrawal timing around a
    ///      known-imminent loss is the curator's only real lever (SYSTEM_MODEL section 2).
    function invariant_INV7_noWithdrawalEverBreachedSubordination() public view {
        assertEq(
            cascadeHandler.ghostWithdrawBreaches(),
            0,
            "INV-7: a completed withdrawal left the pool below min(target, exposure)"
        );
        assertEq(
            cascadeHandler.ghostFrozenWithdrawAccepted(),
            0,
            "INV-7: a withdrawal succeeded while the class carried an unresolved default"
        );
        // AUDIT FIX (SWEEP-2 CSG-F1) — THE FOURTH GHOST. The two counters above bound the POOL
        // against its requirement; this one bounds the CREDIT the senior price is extending, and
        // they are different statements. The measured HIGH broke this one while both of the others
        // stayed at zero.
        assertEq(
            cascadeHandler.ghostCreditReductions(),
            0,
            "INV-7: a withdrawal reduced min(declared + pastDue, poolBalance) -- layer-1 credit escaped"
        );
    }

    /// @notice INV-7 / AUDIT R6-CF1. No curator withdrawal ever completed while a reserve-CUSTODY
    ///         loss was recognised and unabsorbed.
    /// @dev THE FINDING, expressed as a standing property. `withdrawFirstLoss` was gated only by
    ///      `unresolvedDefaults`, whose sole writer is the FACILITY path (`freezeOnDefault` from
    ///      `declareDefault`/`liquidate`). The custody path armed nothing, so a curator could pull
    ///      every dollar of headroom between an adjudicated custody incident being recognised and
    ///      its write-down executing, and hand a LAYER 1 loss to the sGROVE backstop and the
    ///      senior vault. The handler drives the withdrawal INTO that window on every class rather
    ///      than filtering it out, and counts acceptance here.
    function invariant_INV7_noWithdrawalEverEscapedTheCustodyFreeze() public view {
        assertEq(
            cascadeHandler.ghostCustodyFrozenWithdrawAccepted(),
            0,
            "R6-CF1: a curator withdrawal succeeded while a reserve-custody loss was unabsorbed"
        );
    }

    /// @notice INV-5 / AUDIT R6-CF1. The contract's custody-freeze predicate agrees with the
    ///         handler's INDEPENDENT model of the recognition-to-absorption window at every
    ///         reachable state.
    /// @dev Same reason `invariant_INV5_layer1CapacityMatchesIndependentModel` exists: a guard
    ///      checked only against the contract's own view of when it should fire cannot falsify a
    ///      wrong window. The model here carries only the open-incident limb, so this equality
    ///      ALSO fails loudly if a different limb (a latched deficit, a live USDC shortfall, an
    ///      under-backed protocol) ever fires in this campaign — which would mean the campaign had
    ///      wandered out of the solvent regime it claims to test.
    function invariant_INV5_custodyFreezeMatchesIndependentModel() public view {
        assertEq(
            curator.custodyFreezeActive(),
            cascadeHandler.mCustodyFrozen(),
            "R6-CF1: custody freeze != independent model of the recognition-to-absorption window"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  ANTI-VACUITY — asserted, and it is the whole point
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Fails the campaign if the states these invariants claim to test were never
    ///         reached. Runs once per invariant run, against that run's counters.
    /// @dev TWO BASES, following the house pattern established by `CollateralInvariants`:
    ///
    ///      (1) THE WIRING TOOTH — `fuzzActionEntries` and `fuzzRealizeEntries` are incremented
    ///          at the top of the registered selectors only. The deterministic seed never touches
    ///          them. If a selector is missing from `targetSelector`, or the handler is not the
    ///          target contract, these are exactly zero and the campaign FAILS even though every
    ///          other counter is non-zero from the seed. `realizeLoss` is one of twelve selectors
    ///          over a 128-call run, so zero entries means a wiring break, not fuzz luck.
    ///
    ///      (2) SEED-BACKED SHAPE FLOORS — one run's fuzz reach for narrow conjunctions (a pool
    ///          wiped in the SAME event as a reserve-bound layer-2 draw) is too thin to assert
    ///          without flaking, so `seedCascadeShapes` drives one of each before every run.
    ///          What these guarantee is that every run was evaluated against a state in which all
    ///          three layers had really been charged, the shared reserve had really bound, a pool
    ///          had really been wiped and its round advanced, interest had really been
    ///          distributed, and a frozen withdrawal had really been refused. Everything above
    ///          that floor is the fuzz campaign's own reach and is printed below, not asserted.
    function afterInvariant() public view {
        _report();
        // ── (1) wiring ──────────────────────────────────────────────────
        // `fuzzActionEntries` increments at the top of EVERY registered selector, so it is zero
        // if and only if the handler is not being driven at all — no fuzz-luck dependence.
        // Per-selector coverage is guarded deterministically by
        // `test_wiring_everyHandlerActionIsRegistered` and evidenced by the run's call table;
        // `fuzzRealizeEntries` is reported above rather than asserted, for the flake reason
        // documented on that test.
        assertGt(cascadeHandler.fuzzActionEntries(), 0, "NO FUZZ ACTION EXECUTED (targetSelector wiring broken)");
        assertGt(cascadeHandler.callCount(), 0, "NO HANDLER ACTION COMPLETED");

        // ── (2) INV-5 reach: all three layers actually charged ──────────
        assertGt(cascadeHandler.ghostLossEvents(), 0, "NO LOSS WAS EVER REALIZED (INV-5 IS VACUOUS)");
        assertGt(cascadeHandler.ghostAbsorbedL1(), 0, "LAYER 1 NEVER ABSORBED ANYTHING");
        assertGt(cascadeHandler.ghostCoveredL2(), 0, "LAYER 2 NEVER DELIVERED COVERAGE");
        assertGt(cascadeHandler.ghostBurnedL3(), 0, "LAYER 3 NEVER BURNED SENIOR PRINCIPAL");
        assertGt(cascadeHandler.ghostReserveLossEvents(), 0, "NO AUTHENTICATED CUSTODY LOSS WAS EXECUTED");
        assertGt(cascadeHandler.ghostReserveWriteDownEvents(), 0, "DIRECT CUSTODY WRITE-DOWN PATH WAS NOT REACHED");
        assertGt(cascadeHandler.ghostReserveReconcileEvents(), 0, "AUTHENTICATED RECONCILE LOSS PATH WAS NOT REACHED");
        assertEq(
            cascadeHandler.ghostCustodyF18IsolationChecks(),
            cascadeHandler.ghostReserveLossEvents(),
            "A CUSTODY LOSS DID NOT PROVE F-18-01 ACCOUNTING ISOLATION"
        );

        // ── (2) the shared reserve was exercised in BOTH regimes ────────
        // AUDIT FIX (SWEEP-2 CSG-F1) REACH. The one loss path with NO freeze. Before this round the
        // handler had zero `markPastDue` occurrences, so the region the measured HIGH lives in was
        // never visited and INV-7 was green against a formula that permitted it. All four counters
        // are asserted together: entering the region, being REFUSED inside it on the headroom rule
        // (not on a freeze), leaving it, and never being accepted.
        assertGt(cascadeHandler.ghostPastDueMarks(), 0, "THE UNFROZEN PAST-DUE REGION WAS NEVER ENTERED");
        assertGt(cascadeHandler.ghostPastDueClears(), 0, "THE PAST-DUE REGION WAS NEVER LEFT (INV-7 POSITIVE STARVES)");
        assertGt(
            cascadeHandler.ghostCreditedWithdrawRejections(),
            0,
            "NO WITHDRAWAL WAS EVER REFUSED BY THE MARKED FLOOR (CSG-F1 GUARD IS VACUOUS)"
        );
        assertEq(
            cascadeHandler.ghostCreditedWithdrawAccepted(),
            0,
            "INV-7: a withdrawal succeeded against layer-1 capital the conservative NAV was crediting"
        );

        assertGt(cascadeHandler.ghostCapChanges(), 0, "THE UNCAPPED CAPACITY IDENTITY WAS NEVER CHECKED");
        assertGt(cascadeHandler.ghostCapBindingDraws(), 0, "THE LIVE RESERVE NEVER BOUND A DRAW");
        assertGt(cascadeHandler.ghostCapSlackDraws(), 0, "THE RESERVE-SLACK REGIME WAS NEVER REACHED");

        // ── (2) the interaction Phase C named as outstanding ────────────
        assertGt(cascadeHandler.ghostPoolWipes(), 0, "A CURATOR POOL WAS NEVER FULLY WIPED");
        assertGt(
            cascadeHandler.ghostWipeWithBindingCap(), 0, "WIPED CURATOR ROUND + RESERVE-BOUND LAYER 2 NEVER CO-OCCURRED"
        );
        assertGt(cascadeHandler.ghostRoundAdvances(), 0, "A WIPED POOL NEVER ADVANCED ITS SHARE ROUND");
        assertGt(cascadeHandler.ghostLossesAfterRoundAdvance(), 0, "NO LOSS WAS EVER REALIZED IN A POST-WIPE ROUND");

        // ── (2) INV-6 reach ─────────────────────────────────────────────
        assertGt(cascadeHandler.ghostDistributions(), 0, "NO REPAYMENT WAS EVER DISTRIBUTED (INV-6 IS VACUOUS)");
        assertGt(cascadeHandler.ghostInterestPaid(), 0, "NO INTEREST WAS EVER DISTRIBUTED");
        assertGt(cascadeHandler.ghostFeeToRecipient(), 0, "THE PROTOCOL FEE LEG NEVER CARRIED VALUE");
        assertGt(cascadeHandler.ghostYieldToVault(), 0, "THE SENIOR INTEREST LEG NEVER CARRIED VALUE");
        // AUDIT FIX (ADV-1) REACH. An invariant that passes because its handler never reaches the
        // region is worthless, and the fee-withholding region is only entered while an UNABSORBED
        // senior residual stands — a state this campaign has to actually construct (declare a
        // default that outruns curator first-loss and the sGROVE backstop). Without this line the
        // three-legged INV-6 identity above would be satisfiable by a campaign in which the third
        // leg is permanently zero, i.e. by a build where ADV-1 was never fixed at all.
        assertGt(
            cascadeHandler.ghostFeeWithheldForImpairment(),
            0,
            "ADV-1: THE FEE-WITHHOLDING REGION WAS NEVER REACHED (the INV-6 third leg is vacuous)"
        );
        assertGt(cascadeHandler.ghostPrincipalRepaid(), 0, "NO PRINCIPAL WAS EVER REPAID");

        // ── (2) INV-7 reach: the formula's inputs actually moved ────────
        assertGt(cascadeHandler.ghostCuratorPosts(), 0, "NO FIRST-LOSS CAPITAL WAS EVER POSTED");
        assertGt(cascadeHandler.ghostCuratorWithdrawals(), 0, "NO CURATOR WITHDRAWAL EVER SUCCEEDED");
        assertGt(cascadeHandler.ghostTargetChanges(), 0, "THE FIRST-LOSS TARGET NEVER MOVED");
        assertGt(cascadeHandler.ghostTargetBindingObs(), 0, "min(target, exposure) NEVER BOUND ON THE TARGET LEG");
        assertGt(cascadeHandler.ghostExposureBindingObs(), 0, "min(target, exposure) NEVER BOUND ON THE EXPOSURE LEG");
        assertGt(cascadeHandler.ghostExposureIncreases(), 0, "EXPOSURE NEVER INCREASED");
        assertGt(cascadeHandler.ghostExposureDecreases(), 0, "EXPOSURE NEVER DECREASED");
        assertGt(cascadeHandler.ghostDefaultsDeclared(), 0, "NO DEFAULT WAS EVER DECLARED");
        assertGt(cascadeHandler.ghostFrozenWithdrawRejections(), 0, "THE DEFAULT FREEZE NEVER REFUSED A WITHDRAWAL");
        // AUDIT R6-CF1. Both regimes must have been visited: the custody freeze must have REFUSED
        // a withdrawal (with its own selector, not any revert), and an incident must have been
        // CLOSED so the free regime was reachable too. A campaign that only ever saw one of the
        // two proves nothing about the guard.
        assertGt(
            cascadeHandler.ghostCustodyFrozenWithdrawRejections(),
            0,
            "THE CUSTODY FREEZE NEVER REFUSED A WITHDRAWAL (R6-CF1 IS VACUOUS)"
        );
        assertGt(
            cascadeHandler.ghostCustodyIncidentCloses(),
            0,
            "NO CUSTODY INCIDENT WAS EVER CLOSED (FREE REGIME UNREACHED)"
        );
        // The adversarial ordering itself must have been visited, with value actually pulled.
        assertGt(cascadeHandler.ghostRaceAttempts(), 0, "THE WITHDRAW-THEN-DEFAULT RACE WAS NEVER RUN");
        assertGt(cascadeHandler.ghostRaceValuePulled(), 0, "THE RACE NEVER PULLED ANY FIRST-LOSS CAPITAL");

        // ── (2) reserve-loss ENTRY guards were actually ENTERED ─────────
        // A green `invariant_reserveLossEntryGuardsAdmitNoOutsider` proves nothing if the probe
        // never fired, and it proves nothing if every probe bounced off some UNRELATED revert
        // before reaching the guard under test. Both are asserted, not logged.
        assertGt(
            cascadeHandler.guardAttempts(cascadeHandler.guardIdAt(0)),
            0,
            "THE absorbReserveLoss CALLER GUARD WAS NEVER PROBED (ITS INVARIANT IS VACUOUS)"
        );
        assertGt(
            cascadeHandler.guardAttempts(cascadeHandler.guardIdAt(1)),
            0,
            "THE absorbReserveLoss NAMESPACE GUARD WAS NEVER PROBED (ITS INVARIANT IS VACUOUS)"
        );
        assertEq(
            cascadeHandler.guardRefusedAsSpecified(cascadeHandler.guardIdAt(0)),
            cascadeHandler.guardAttempts(cascadeHandler.guardIdAt(0)),
            "A CALLER PROBE WAS REFUSED BY SOMETHING OTHER THAN THE GUARD UNDER TEST"
        );
        assertEq(
            cascadeHandler.guardRefusedAsSpecified(cascadeHandler.guardIdAt(1)),
            cascadeHandler.guardAttempts(cascadeHandler.guardIdAt(1)),
            "A NAMESPACE PROBE WAS REFUSED BY SOMETHING OTHER THAN THE GUARD UNDER TEST"
        );

        _report();
    }

    /// @dev Readout only. Everything above the deterministic seed floor is this run's fuzz reach.
    function _report() private view {
        console2.log("-- INV_CascadeSeniority campaign reach ------------------");
        console2.log("handler calls completed        ", cascadeHandler.callCount());
        console2.log("fuzz selector entries          ", cascadeHandler.fuzzActionEntries());
        console2.log("  of which realizeLoss         ", cascadeHandler.fuzzRealizeEntries());
        console2.log("  of which custody loss        ", cascadeHandler.fuzzReserveLossEntries());
        console2.log("loss events                    ", cascadeHandler.ghostLossEvents());
        console2.log("  custody-loss events          ", cascadeHandler.ghostReserveLossEvents());
        console2.log("    direct / reconcile         ", cascadeHandler.ghostReserveWriteDownEvents());
        console2.log("                               ", cascadeHandler.ghostReserveReconcileEvents());
        console2.log("  total loss realized          ", cascadeHandler.ghostLossRealized());
        console2.log("  layer 1 (curator) absorbed   ", cascadeHandler.ghostAbsorbedL1());
        console2.log("  layer 2 (sGROVE) covered     ", cascadeHandler.ghostCoveredL2());
        console2.log("  layer 3 (senior) burned      ", cascadeHandler.ghostBurnedL3());
        console2.log("reserve-BINDING draws          ", cascadeHandler.ghostCapBindingDraws());
        console2.log("reserve-SLACK draws            ", cascadeHandler.ghostCapSlackDraws());
        console2.log("capacity identity checks       ", cascadeHandler.ghostCapChanges());
        console2.log("pool wipes                     ", cascadeHandler.ghostPoolWipes());
        console2.log("  wipe + reserve bound         ", cascadeHandler.ghostWipeWithBindingCap());
        console2.log("share-round advances           ", cascadeHandler.ghostRoundAdvances());
        console2.log("losses in a post-wipe round    ", cascadeHandler.ghostLossesAfterRoundAdvance());
        console2.log("distributions                  ", cascadeHandler.ghostDistributions());
        console2.log("  interest distributed         ", cascadeHandler.ghostInterestPaid());
        console2.log("  protocol fee leg             ", cascadeHandler.ghostFeeToRecipient());
        console2.log("  senior leg                   ", cascadeHandler.ghostYieldToVault());
        console2.log("  fee withheld (ADV-1)         ", cascadeHandler.ghostFeeWithheldForImpairment());
        console2.log("  principal repaid             ", cascadeHandler.ghostPrincipalRepaid());
        console2.log("origination fees modeled       ", cascadeHandler.ghostOriginationFees());
        console2.log("senior deposits                ", cascadeHandler.ghostSeniorDeposits());
        console2.log("curator posts / withdrawals    ", cascadeHandler.ghostCuratorPosts());
        console2.log("                               ", cascadeHandler.ghostCuratorWithdrawals());
        console2.log("  value withdrawn              ", cascadeHandler.ghostCuratorWithdrawn());
        console2.log("adversarial race attempts      ", cascadeHandler.ghostRaceAttempts());
        console2.log("  value pulled pre-default     ", cascadeHandler.ghostRaceValuePulled());
        console2.log("frozen-withdraw refusals       ", cascadeHandler.ghostFrozenWithdrawRejections());
        console2.log("custody-frozen refusals        ", cascadeHandler.ghostCustodyFrozenWithdrawRejections());
        console2.log("custody incidents opened/closed", cascadeHandler.custodyIncidentCount());
        console2.log("                               ", cascadeHandler.ghostCustodyIncidentCloses());
        console2.log("first-loss target changes      ", cascadeHandler.ghostTargetChanges());
        console2.log("  target-leg binding obs       ", cascadeHandler.ghostTargetBindingObs());
        console2.log("  exposure-leg binding obs     ", cascadeHandler.ghostExposureBindingObs());
        console2.log("defaults declared / lifted     ", cascadeHandler.ghostDefaultsDeclared());
        console2.log("                               ", cascadeHandler.ghostFreezeLifts());
        console2.log("facilities live / ever         ", cascadeHandler.facilityCount());
        console2.log("                               ", cascadeHandler.allFacilityCount());
        console2.log("absorbReserveLoss outsider probes", cascadeHandler.ghostReserveLossOutsiderProbes());
        console2.log("absorbReserveLoss namespace probes", cascadeHandler.ghostReserveLossNamespaceProbes());
        cascadeHandler.reachReport();
    }
}
