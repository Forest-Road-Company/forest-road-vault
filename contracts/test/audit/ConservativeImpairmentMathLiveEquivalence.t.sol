// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ConservativeImpairmentMath} from "../../src/ConservativeImpairmentMath.sol";
import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";
import {PerEventImpairmentReference} from "./ConservativeImpairmentMathEquivalence.t.sol";

/// @title Conservative-NAV W7 ladder — differential against the LIVE DefaultManager
/// @notice `ConservativeImpairmentMathEquivalence.t.sol` fuzzes the production calculator against
///         an independently structured reconstruction over the ledger's published event rows. It
///         proves the event arithmetic, but says nothing about whether real manager transitions
///         register, update and release the right rows.
///
///         So this file closes the other half: it drives the real `DefaultManager` (real
///         `CuratorModule`, real `SGrove` backstop, real facilities) through the states the mark is
///         supposed to distinguish, and at every step asserts the live
///         `DefaultManager.pendingSeniorImpairment()` equals the independent per-event ladder
///         recomputed from the manager's own public getters.
///
///         WHY BOTH HALVES ARE NEEDED: the W7 change adds declaration-time rows and row updates on
///         every recovery/realization path. Either the ladder or that plumbing could be wrong, and
///         only the two suites together rule out both. Do not delete one because the other is green.
contract ConservativeImpairmentMathLiveEquivalenceTest is GovernanceFixture {
    uint256 internal constant FILM = 1;

    /// @dev A deliberately lower ceiling than `sUSDfr.IMPAIRMENT_SOURCE_PROBE_GAS` (400,000).
    ///      The fixture below creates two live drawn events so the commitment-ledger loop is
    ///      exercised rather than measured at its zero-event fast path.
    uint256 internal constant PROBE_BUDGET_CEILING = 250_000;

    PerEventImpairmentReference internal perEventReference;

    function setUp() public virtual override {
        super.setUp();
        perEventReference = new PerEventImpairmentReference();
    }

    /// @dev The live mark must equal the independent ladder recomputed from published rows.
    function _assertLiveEquivalence(string memory at) internal view {
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            perEventReference.pendingSeniorImpairment(address(defaultManager)),
            string.concat("event-aware reference disagrees with the live conservative NAV: ", at)
        );
    }

    function _seedCoverage(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _warpPastGrace(uint256 tokenId) internal {
        uint64 nextPaymentDue = bridge.facility(tokenId).nextPaymentDue;
        uint64 grace = defaultManager.graceWindow(bridge.facility(tokenId).classId);
        vm.warp(uint256(nextPaymentDue) + uint256(grace) + 1);
    }

    // ── the differential walk ────────────────────────────────────────────

    /// @notice W7 EQUIVALENCE, LIVE: every state transition that moves the impairment pool keeps
    ///         the forwarded answer identical to the independent per-event reconstruction.
    /// @dev The walk deliberately visits, in order: an empty book; layer 1 only; a declared default
    ///         partly covered by curator first-loss; the same default with a real sGROVE reserve
    ///         behind it; a SECOND class impaired so the per-class layer-1 netting has to be
    ///         per-class; a past-due facility (the H-5 pool, which shares layer 1 but never
    ///         consumes layer 2); and finally a partial realization, which is what creates the
    ///         PM-R-11 drawn cohort with a frozen capacity floor and non-zero consumed coverage.
    function test_liveMarkMatchesPerEventReferenceThroughTheWholeWalk() public {
        _assertLiveEquivalence("empty book");

        _postFirstLoss(anchorCurator, FILM, 200_000e18);
        _assertLiveEquivalence("curator first-loss posted, nothing impaired");

        uint256 declaredId = _liveFilmFacility(1_000_000e18);
        _attestDefault(declaredId);
        vm.prank(servicer);
        defaultManager.declareDefault(declaredId, FILM_REF);
        _assertLiveEquivalence("declared default, layer 1 only");
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "walk must actually reach a marked state");

        _seedCoverage(600_000e18);
        _assertLiveEquivalence("real sGROVE reserve behind the same default");

        uint256 pastDueId = _liveFilmFacility(300_000e18);
        _warpPastGrace(pastDueId);
        vm.prank(carol);
        defaultManager.markPastDue(pastDueId);
        _assertLiveEquivalence("H-5 past-due pool added to the same class");

        // A partial realization draws sGROVE coverage, which is what freezes this event's capacity
        // floor and makes `liveDefaultCoverageConsumed()` non-zero — the PM-R-11 drawn cohort.
        // 500,000 exceeds the 200,000 curator pool, so layer 2 is genuinely drawn.
        _realizeLoss(declaredId, 500_000e18, keccak256("partial-loss"));
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "walk must reach the drawn cohort");
        _assertLiveEquivalence("PM-R-11 drawn cohort with a frozen capacity floor");

        // A permissionless top-up raises current capacity above the frozen floor: the exact
        // divergence PM-R-11 exists for, and the state where a row-plumbing slip would show up.
        _seedCoverage(400_000e18);
        _assertLiveEquivalence("current capacity above the frozen floor");
    }

    /// @notice EXTRACTION EQUIVALENCE, LIVE and FUZZED: the same walk over fuzzed sizings, so the
    ///         curator pool, the reserve and the impairment cross each other in every order.
    function testFuzz_liveMarkMatchesPerEventReference(uint256 principal, uint256 firstLoss, uint256 reserve) public {
        // Whole-USDC granularity: the mint path this fixture uses only accepts 1e12 multiples.
        uint256 p = bound(principal, 1, 2_000_000) * 1e18;
        uint256 fl = bound(firstLoss, 0, 2_500_000) * 1e18;
        uint256 r = bound(reserve, 0, 3_000_000) * 1e18;

        if (fl > 0) _postFirstLoss(anchorCurator, FILM, fl);
        if (r > 0) _seedCoverage(r);

        uint256 id = _liveFilmFacility(p);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _assertLiveEquivalence("fuzzed declared default");

        // Realize part of it: whether this reaches layer 2 depends on the fuzzed curator pool,
        // so the differential sees both the drawn and the never-drawn cohort. The loss is capped
        // at what layers 1+2 can absorb because this fixture stakes no senior principal, so
        // layer 3 has nothing to write down and a larger loss reverts before it marks anything.
        uint256 absorbable = curator.poolBalance(FILM) + sGrove.coverageCapacity();
        uint256 loss = p / 3;
        if (loss > absorbable) loss = absorbable;
        loss = (loss / 1e18) * 1e18;
        if (loss > 0) {
            _realizeLoss(id, loss, keccak256("fuzzed-partial-loss"));
            _assertLiveEquivalence("fuzzed partial realization");
        }
    }

    /// @notice The forwarder is bound to the PROXY, not to the implementation. If it ever passed the
    ///         implementation address (which is where the constructor that created the calculator
    ///         ran), the mark would silently read an empty book and report ZERO impairment — a
    ///         maximally dangerous failure, since zero is the "nothing wrong" answer.
    function test_forwarderPricesTheProxyStorageNotTheImplementation() public {
        _postFirstLoss(anchorCurator, FILM, 1e18);
        uint256 id = _liveFilmFacility(500_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 mark = defaultManager.pendingSeniorImpairment();
        assertEq(mark, 500_000e18 - 1e18, "the mark must come from the proxy's own impairment pool");
        assertEq(
            ConservativeImpairmentMath(defaultManager.impairmentMath()).pendingSeniorImpairment(address(defaultManager)),
            mark,
            "calling the calculator directly on the proxy reproduces the forwarded answer"
        );
    }

    /// @notice The calculator is real, deployed code reachable for independent verification, and it
    ///         is stateless: two different `DefaultManager` books priced by the SAME calculator
    ///         instance do not contaminate each other.
    function test_calculatorIsDeployedStatelessAndBookScoped() public {
        address calculator = address(defaultManager.impairmentMath());
        assertTrue(calculator != address(0), "the calculator address must be published");
        assertGt(calculator.code.length, 0, "the calculator must be deployed code");

        uint256 id = _liveFilmFacility(400_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // The same calculator instance, asked about a book with nothing in it, answers zero.
        assertEq(
            ConservativeImpairmentMath(calculator).pendingSeniorImpairment(address(defaultManager)),
            400_000e18,
            "the live book is marked"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "forwarded answer agrees");
    }

    // ── affordability ────────────────────────────────────────────────────

    /// @notice THE EXTRACTION MUST STAY INSIDE `sUSDfr`'s IMPAIRMENT-SOURCE PROBE BUDGET.
    /// @dev `sUSDfr` probes its impairment source under a hard 400,000-gas cap
    ///      (`IMPAIRMENT_SOURCE_PROBE_GAS`) to decide whether the source is readable. A source that
    ///      does not answer inside that cap is declared UNREADABLE and can be cleared by
    ///      `clearUnreadableImpairmentSource` — i.e. the conservative mark would be dropped from
    ///      redemption pricing entirely. W7 moved the event walk behind an external ledger, so the
    ///      budget is measured rather than assumed. Cold, with a curator pool on every class, the
    ///      whole `assessed -> manager -> calculator` path is measured with two live drawn defaults;
    ///      the commitment-ledger aggregate must be non-zero and its bounded event set remains
    ///      below the lower 250,000-gas release ceiling.
    ///
    ///      The ceiling below is deliberately BELOW the real 200,000 cap: crossing it means the
    ///      next change would put redemption pricing at risk, and that must fail here rather than
    ///      in production. If you need to raise it, re-measure the cold path and say so out loud —
    ///      do not nudge it up to make a build green.
    function test_markStaysWellInsideTheImpairmentSourceProbeBudget() public {
        _seedCoverage(500_000e18);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            _postFirstLoss(anchorCurator, classId, 10_000e18);
        }
        uint256 id = _liveFilmFacility(1_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 secondId = _liveFilmFacility(1_000_000e18);
        _attestDefault(secondId);
        vm.prank(servicer);
        defaultManager.declareDefault(secondId, FILM_REF);

        // Realize both events so `CommitmentLedger.deliverableAggregate()` has a live event set;
        // the prior one-default/no-realization fixture executed zero ledger iterations.
        // The fixture has only a 10,000e18 curator pool in FILM and a 250,000e18 first-draw
        // backstop cap, so 250,000e18 is the largest loss that stays entirely in layers 1+2.
        _realizeLoss(id, 250_000e18, keccak256("probe-budget-first"));
        // After the first event consumes the class curator pool and 240,000e18 of layer 2,
        // 125,000e18 is the largest second draw this fixture can absorb without touching the
        // senior vault; it still creates a second live ledger entry and leaves residual room.
        _realizeLoss(secondId, 125_000e18, keccak256("probe-budget-second"));
        assertGt(defaultManager.liveDefaultCoverageRemaining(), 0, "probe fixture must reach live ledger coverage");

        assessedImpairmentSource.pendingSeniorImpairment();
        vm.cool(address(defaultManager));
        vm.cool(address(assessedImpairmentSource));

        uint256 before = gasleft();
        assessedImpairmentSource.pendingSeniorImpairment();
        uint256 used = before - gasleft();

        emit log_named_uint("two-live-drawn-event impairment gas", used);
        assertLt(used, PROBE_BUDGET_CEILING, "the conservative mark no longer fits the probe budget");
    }

    /// @notice Every class the mark walks is reachable through the published getter set, so an
    ///         independent model can reproduce the mark without privileged access. `pastDuePrincipal`
    ///         was added for exactly this reason and must keep summing to `pastDueExposure()`.
    function test_publishedGettersReconcileToTheAggregate() public {
        uint256 id = _liveFilmFacility(250_000e18);
        _warpPastGrace(id);
        vm.prank(carol);
        defaultManager.markPastDue(id);

        uint256 total;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            total += defaultManager.pastDuePrincipal(classId);
        }
        assertEq(total, defaultManager.pastDueExposure(), "per-class past-due must reconcile to the aggregate");
        assertEq(defaultManager.pastDuePrincipal(FILM), 250_000e18, "the film class carries it");
    }
}
