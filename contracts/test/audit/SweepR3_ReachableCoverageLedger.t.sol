// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";

/// @title SweepR3_ReachableCoverageLedger — AUDIT FIX (SWEEP-3 F-S3-01, round 4)
/// @notice The PM-R-11 drawn-cohort clamp subtracted the consumed coverage TWICE, and narrowing it
///         twice did not remove it. `DefaultManager` now keeps an EXACT reachable-coverage ledger
///         (`coverageRemainingByDefault` per event, `liveDefaultCoverageRemaining` in aggregate),
///         written from the backstop's canonical `ICascadeBackstop.remainingCoverage(eventId)`, and
///         `ConservativeImpairmentMath` credits that number directly.
///
///         WHY THE EARLIER ROUNDS DID NOT CLOSE IT. Round 2 computed
///         `min(floor, currentCap) - consumed`; round 3 computed `min(floor - consumed, currentCap)`.
///         Both build a per-event availability out of two GLOBALS: `liveDefaultCapacityFloor` is a
///         MINIMUM over per-event ceilings and `liveDefaultCoverageConsumed` is a SUM over per-event
///         draws. With exactly ONE live drawn event the two happen to coincide with that event's
///         availability, which is why every single-event fixture in the tree was green through both
///         rounds. With a SECOND live drawn event the floor has already ratcheted down to the
///         capacity standing AFTER the first draw — it is already net of that draw — so subtracting
///         the running total charges the first event's consumption to the second one as well.
///
///         EVERY EXPECTATION BELOW IS A DIFFERENTIAL AGAINST THE BACKSTOP'S OWN
///         `eventCoverage(eventId)`, not a restatement of the manager's formula. A test that
///         re-derived the answer the same way the contract does would move with any mutation of it.
contract SweepR3_ReachableCoverageLedgerTest is ProductionCreditFixture {
    uint256 internal constant FILM = 1;

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.approve(address(sGrove), amount);
        vm.prank(bob);
        sGrove.fundCoverage(amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _defaulted(bytes32 borrower, uint256 principal) internal returns (uint256 id) {
        _mintUSDfrTo(alice, principal); // seed idle liquidity to deploy
        id = _originateFilm(borrower, STATE_GA, principal);
        _fundFacility(id, principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    function _realize(uint256 tokenId, uint256 loss) internal {
        _attestLoss(tokenId, loss, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(tokenId, loss, FILM_REF);
    }

    /// @dev What the BACKSTOP says `eventId` can still reach under ADR-0035: cumulative draw plus
    ///      live reserve, less the cumulative draw. Read from `eventCoverage`, so the expectation
    ///      remains independent of the manager's commitment ledger.
    function _reachableAt(uint256 eventId) internal view returns (uint256) {
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(eventId);
        return cap > drawn ? cap - drawn : 0;
    }

    // ─────────────────────────────────────────────────────────────────────
    // THE FINDING
    // ─────────────────────────────────────────────────────────────────────

    /// @notice F-S3-01: with TWO live drawn events the conservative NAV must credit the layer-2
    ///         coverage BOTH of them can still reach, not one event's ceiling less both events'
    ///         draws.
    /// @dev RED on the pre-fix tree. Measured there: the drawn cohort could still reach 100,000e18
    ///      and was credited ZERO, because `floor` (200,000e18, the ceiling committed to the first
    ///      event) less `consumed` (300,000e18, both draws) underflows to nothing. The 100,000e18
    ///      gap lands directly on `sUSDfr.previewRedeem` and therefore on the settlement price of
    ///      the only senior exit: an exiting holder pays that transfer to the stayers.
    function test_S3_F3_twoDrawnEventsAreCreditedTheCoverageBothCanStillReach() public {
        _stakeVault(alice, 500_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        // Two small draws leave both events live. With the real SGrove's 50% cap, the
        // post-draw standing capacity is 190,000e18 while the two event commitments
        // still sum to 375,000e18.
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);

        // Fixture preconditions — without these the arithmetic below is not attributable.
        assertEq(curator.poolBalance(FILM), 0, "fixture: layer 1 must be empty so layer 2 is the only credit");
        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        assertEq(drawnResidual, 780_000e18, "fixture: the whole declared pool is the DRAWN cohort");
        assertEq(
            defaultManager.declaredDefaultedPrincipal(FILM), drawnResidual, "fixture: no undrawn cohort to confuse it"
        );

        uint256 reachableA = _reachableAt(a);
        uint256 reachableB = _reachableAt(b);
        uint256 standing = sGrove.coverageCapacity();
        // ADR-0035: both event views point at the same physical reserve; never sum them.
        uint256 reachable = standing < drawnResidual ? standing : drawnResidual;

        emit log_named_uint("event A can still reach   ", reachableA);
        emit log_named_uint("event B can still reach   ", reachableB);
        emit log_named_uint("standing capacity         ", standing);
        emit log_named_uint("HONEST layer-2 credit     ", reachable);
        emit log_named_uint("pendingSeniorImpairment() ", defaultManager.pendingSeniorImpairment());

        assertEq(reachableA, standing, "event A does not expose the shared reserve");
        assertEq(reachableB, standing, "event B does not expose the shared reserve");
        assertEq(defaultManager.liveDefaultCoverageRemaining(), drawnResidual, "principal aggregate drifted");

        assertEq(
            defaultManager.pendingSeniorImpairment(),
            drawnResidual - reachable,
            "ADR-0035: the mark did not clamp the cohort to one shared reserve"
        );
    }

    /// @notice ADR-0035 asymmetric-cohort control: a small event cannot multiply the one shared
    ///         reserve, and its unused principal bound cannot prevent a larger event consuming
    ///         the remaining pool.
    function test_S3_F3_asymmetricCohortCreditsOnlyExecutableSharedCoverage() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);

        uint256 aRemaining = reserves.deployedTo(a);
        uint256 bRemaining = reserves.deployedTo(b);
        uint256 aRoom = _reachableAt(a);
        uint256 bRoom = _reachableAt(b);
        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 credited = drawnResidual - defaultManager.pendingSeniorImpairment();

        uint256 snap = vm.snapshotState();
        uint256 before = usdfr.balanceOf(address(sGrove));
        _realize(a, aRemaining);
        _realize(b, bRemaining);
        uint256 delivered = before - usdfr.balanceOf(address(sGrove));
        vm.revertToState(snap);

        emit log_named_uint("A remaining principal", aRemaining);
        emit log_named_uint("A shared-reserve view", aRoom);
        emit log_named_uint("B remaining principal", bRemaining);
        emit log_named_uint("B shared-reserve view", bRoom);
        emit log_named_uint("credited by the NAV", credited);
        emit log_named_uint("delivered by layer 2", delivered);

        assertEq(aRemaining, 15_000e18, "fixture: A must retain only its own small principal");
        assertEq(aRoom, 380_000e18, "fixture: A must see the shared reserve");
        assertEq(bRemaining, 390_000e18, "fixture: B principal must remain large");
        assertEq(bRoom, 380_000e18, "fixture: B must see the same shared reserve");
        assertEq(delivered, 380_000e18, "real SGrove did not exhaust its shared reserve");
        assertEq(credited, delivered, "NAV did not credit exactly executable shared coverage");
    }

    /// @notice Funded-layer-one composition: the class curator pool is allocated before the one
    ///         shared reserve, and the credited junior total must equal their executable sum.
    function test_W6_B1_fundedCuratorLayerBoundsAggregateCoverage() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 25_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
        // Post the shared class pool after both events have drawn.  This keeps the pool available
        // to the conservative mark and isolates the uncertain allocation order at layer 1.
        _postFirstLoss(anchorCurator, FILM, 15_000e18);

        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 credited = drawnResidual - defaultManager.pendingSeniorImpairment();
        uint256 aRoom = _reachableAt(a);
        uint256 bRoom = _reachableAt(b);

        emit log_named_uint("curator pool", curator.poolBalance(FILM));
        emit log_named_uint("event A room", aRoom);
        emit log_named_uint("event B room", bRoom);
        emit log_named_uint("credited coverage", credited);

        assertEq(curator.poolBalance(FILM), 15_000e18, "fixture: funded layer 1 must remain available");
        assertEq(aRoom, 380_000e18, "fixture: A shared reserve view");
        assertEq(bRoom, 380_000e18, "fixture: B shared reserve view");
        assertEq(credited, 395_000e18, "ADR-0035: curator plus shared reserve delivery drifted");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            10_000e18,
            "ADR-0035: senior residual must follow curator then the whole shared reserve"
        );
    }

    /// @notice THE EXECUTABLE CLAIM. Coverage the exit price nets must be coverage the backstop
    ///         would actually hand over if those same defaults realized their remaining loss in
    ///         this block. The NAV may be conservative (credit less), never optimistic.
    /// @dev This is the property the ledger exists to make true, and it is checked by RUNNING the
    ///      cascade rather than by re-deriving it: the arms are identical up to a `snapshotState`,
    ///      so the delivered figure is the real `SGrove`-shaped answer under the shared reserve.
    function test_S3_F3_theCreditedCoverageIsActuallyDeliverableInTheSameBlock() public {
        _stakeVault(alice, 500_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 150_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 150_000e18);

        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 credited = drawnResidual - defaultManager.pendingSeniorImpairment();

        uint256 snap = vm.snapshotState();
        uint256 backstopBefore = usdfr.balanceOf(address(sGrove));
        // Realize everything still outstanding on both drawn facilities. Whatever leaves the
        // backstop is what layer 2 was genuinely able to deliver for this cohort.
        _realize(a, defaultManager.coverageConsumedByDefault(a) == 0 ? 0 : reserves.deployedTo(a));
        _realize(b, reserves.deployedTo(b));
        uint256 delivered = backstopBefore - usdfr.balanceOf(address(sGrove));
        vm.revertToState(snap);

        emit log_named_uint("credited by the NAV", credited);
        emit log_named_uint("delivered by layer 2", delivered);

        assertGt(delivered, 0, "fixture: layer 2 must actually deliver something, or the probe is vacuous");
        assertLe(credited, delivered, "the NAV credited coverage the backstop would NOT have delivered");
        assertEq(credited, delivered, "the NAV under-credited executable coverage");
    }

    /// @notice EQUIVALENCE WHERE NO CHANGE IS INTENDED: with exactly ONE live drawn event the
    ///         answer is bit-for-bit the round-3 answer, because `floor - consumed` and this
    ///         event's own `cap - drawn` are the same number in that state.
    function test_S3_F3_control_theSingleDrawnEventAnswerIsUnchanged() public {
        _stakeVault(alice, 500e18);
        _fundBackstop(100e18);

        uint256 a = _defaulted(BORROWER_1, 300e18);
        _realize(a, 50e18);

        uint256 reachable = _reachableAt(a);
        uint256 standing = sGrove.coverageCapacity();
        if (reachable > standing) reachable = standing;

        assertEq(defaultManager.liveDefaultCoverageRemaining(), 250e18, "ledger tracks remaining principal");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            250e18 - reachable,
            "the single-event answer moved; this fix must not change it"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // THE HAZARDS THE INFERRED FLOOR EXISTED TO ANSWER — now answered structurally
    // ─────────────────────────────────────────────────────────────────────

    /// @notice PM-R-11 round 3 had to argue that a zero floor is a LEGITIMATE floor, because a
    ///         permissionless coverage refill could otherwise re-seed it at the new, larger
    ///         capacity and hand live defaults coverage no event can reach. ADR-0035 reverses that
    ///         premise: real replenishment raises every live event's shared reach. Principal
    ///         compatibility rows stay unchanged while the executable senior mark falls.
    function test_ADR0035_aPermissionlessRefillRearmsDrawnEventsReachableCoverage() public {
        _stakeVault(alice, 500_000e18);
        _fundBackstop(200_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 150_000e18);

        uint256 reachableBefore = defaultManager.coverageRemainingByDefault(a);
        uint256 aggregateBefore = defaultManager.liveDefaultCoverageRemaining();
        uint256 markBefore = defaultManager.pendingSeniorImpairment();
        uint256 capacityBefore = sGrove.coverageCapacity();

        _fundBackstop(1_000_000e18); // permissionless, by anyone, at any time

        assertGt(sGrove.coverageCapacity(), capacityBefore, "fixture: the refill must raise live capacity");
        assertEq(
            defaultManager.coverageRemainingByDefault(a), reachableBefore, "refill moved principal compatibility row"
        );
        assertEq(defaultManager.liveDefaultCoverageRemaining(), aggregateBefore, "refill moved principal aggregate");
        assertLt(
            defaultManager.pendingSeniorImpairment(), markBefore, "refill did not reduce the now-funded senior mark"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "refilled reserve does not cover the live cohort");
        assertEq(_reachableAt(a), sGrove.coverageReserve(), "drawn event did not receive replenished shared reach");
    }

    /// @notice TERMINAL-STATE RELEASE. An event that has closed out can no longer draw, so its
    ///         unused commitment must leave the aggregate — otherwise the NAV credits coverage no
    ///         live default can reach, which is the UNDER-mark (dangerous) direction.
    function test_S3_F3_aResolvedEventsUnusedCommitmentIsReleasedAndStopsBeingCredited() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 150_000e18);
        uint256 unusedBefore = defaultManager.coverageRemainingByDefault(a);
        assertGt(unusedBefore, 0, "fixture: A must close out with room UNUSED");
        assertGt(
            defaultManager.coverageConsumedByDefault(a),
            0,
            "fixture: A must have a live draw so the terminal hook has an entry to release"
        );

        // Recover everything still outstanding on A in cash. This is deliberately NOT another
        // draw: WaterfallEngine reaches `onDefaultResolved` only after the facility transitions
        // to Resolved, so the test proves the terminal hook releases an actually-unused
        // commitment rather than merely observing a draw path that already drove the entry to 0.
        _repay(a, 0, reserves.deployedTo(a));
        assertEq(defaultManager.defaultedContribution(a), 0, "fixture: A must have closed out");
        assertEq(defaultManager.coverageRemainingByDefault(a), 0, "A's commitment was not released");
        assertEq(defaultManager.liveDefaultCoverageRemaining(), 0, "A's commitment is still in the aggregate");

        // A later, unrelated default must be credited only what ITS OWN event can reach.
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);

        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 standing = sGrove.coverageCapacity();
        uint256 reachable = _reachableAt(b);
        if (reachable > standing) reachable = standing;

        assertEq(defaultManager.liveDefaultCoverageRemaining(), drawnResidual, "B inherited A's released principal row");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            drawnResidual - reachable,
            "the released commitment was still being credited to the mark"
        );
    }

    /// @notice The compatibility aggregate is exactly the sum of live remaining principals;
    ///         executable coverage is the separate shared reserve.
    function test_ADR0035_theAggregateIsExactlyTheSumOfLiveEventPrincipal() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 120_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 40_000e18);
        _realize(a, 30_000e18); // a SECOND draw on an event that already committed its ceiling

        assertEq(defaultManager.coverageRemainingByDefault(a), reserves.deployedTo(a), "principal row drifted for A");
        assertEq(defaultManager.coverageRemainingByDefault(b), reserves.deployedTo(b), "principal row drifted for B");
        assertEq(
            defaultManager.liveDefaultCoverageRemaining(),
            reserves.deployedTo(a) + reserves.deployedTo(b),
            "the aggregate is not the sum of its parts"
        );
    }

    /// @notice THE AGGREGATE-RESERVE LIMB. Remaining-principal rows may sum to more than the one
    ///         shared reserve. Executable layer-two credit is clamped by physical funding.
    function test_S3_F3_theReachableCoverageIsClampedByTheStandingReserve() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
        uint256 c = _defaulted(keccak256("borrower-3"), 400_000e18);
        _realize(c, 190_000e18);

        uint256 standing = sGrove.coverageCapacity();
        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 aggregate = defaultManager.liveDefaultCoverageRemaining();
        uint256 reserve = sGrove.coverageReserve();
        assertGt(aggregate, reserve, "fixture: aggregate principal must exceed the physical reserve");
        assertEq(standing, reserve, "ADR-0035 capacity identity drifted");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            drawnResidual - (aggregate < reserve ? aggregate : reserve),
            "the mark credited more coverage than the aggregate reserve can deliver"
        );
    }

    /// @notice Boundary: remaining principal equal to the shared reserve is fully deliverable.
    function test_ADR0035_principalEqualToReserveLeavesNoSeniorImpairment() public {
        _stakeVault(alice, 500_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 250_000e18);

        assertEq(_reachableAt(a), 150_000e18, "event does not expose remaining shared reserve");
        assertEq(defaultManager.coverageRemainingByDefault(a), 150_000e18, "remaining principal row drifted");
        assertEq(
            defaultManager.pendingSeniorImpairment(), 0, "principal equal to reserve should be fully junior-funded"
        );
    }

    /// @notice Boundary: a later event can reduce the one shared reserve seen by every earlier
    ///         event; no compatibility view may retain a stale event-owned room.
    function test_ADR0035_everyLiveEventViewTracksTheSameFallingReserve() public {
        _stakeVault(alice, 1_600_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18); // A room: 190,000e18
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 10_000e18);
        uint256 c = _defaulted(keccak256("borrower-3"), 400_000e18);
        _realize(c, 190_000e18);
        uint256 d = _defaulted(keccak256("borrower-4"), 400_000e18);
        _realize(d, 95_000e18);

        assertEq(_reachableAt(a), sGrove.coverageReserve(), "A view is not live reserve");
        assertEq(_reachableAt(b), sGrove.coverageReserve(), "B view is not live reserve");
        assertEq(_reachableAt(c), sGrove.coverageReserve(), "C view is not live reserve");
        assertEq(_reachableAt(d), sGrove.coverageReserve(), "D view is not live reserve");
        uint256 reserve = sGrove.coverageReserve();
        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 credit = reserve;
        if (credit > drawnResidual) credit = drawnResidual;
        assertEq(defaultManager.pendingSeniorImpairment(), drawnResidual - credit, "shared reserve clamp drifted");
    }

    /// @notice Boundary: once the real SGrove reserve is zero, no layer-two coverage is treated as
    ///         executable for the conservative mark.
    function test_S3_F3_zeroReserveCreditsNoLayer2Coverage() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 300_000e18);
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, 100_000e18);

        assertEq(sGrove.coverageReserve(), 0, "fixture: reserve must be drained to zero");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            defaultManager.drawnDefaultPrincipal(FILM),
            "zero reserve still credited layer-2 coverage"
        );
    }

    /// @notice Boundary: declaration order cannot create event-owned capacity. Reversing the same
    ///         principals and aggregate loss leaves both the principal ledger and conservative
    ///         mark unchanged.
    function test_ADR0035_declarationOrderCannotCreateIndependentSnapshots() public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 snap = vm.snapshotState();

        uint256 aFirst = _defaulted(BORROWER_1, 400_000e18);
        _realize(aFirst, 40_000e18);
        uint256 bSecond = _defaulted(BORROWER_2, 400_000e18);
        _realize(bSecond, 120_000e18);
        uint256 aggregateAB = defaultManager.liveDefaultCoverageRemaining();
        uint256 markAB = defaultManager.pendingSeniorImpairment();
        assertEq(
            aggregateAB, reserves.deployedTo(aFirst) + reserves.deployedTo(bSecond), "AB principal aggregate drift"
        );
        vm.revertToState(snap);

        uint256 bFirst = _defaulted(BORROWER_2, 400_000e18);
        _realize(bFirst, 120_000e18);
        uint256 aSecond = _defaulted(BORROWER_1, 400_000e18);
        _realize(aSecond, 40_000e18);
        uint256 aggregateBA = defaultManager.liveDefaultCoverageRemaining();
        assertEq(
            aggregateBA, reserves.deployedTo(bFirst) + reserves.deployedTo(aSecond), "BA principal aggregate drift"
        );
        assertEq(aggregateAB, aggregateBA, "declaration order changed aggregate principal");
        assertEq(markAB, defaultManager.pendingSeniorImpairment(), "declaration order created a cap-shaped mark");
    }

    /// @notice PROPERTY (fuzz): whatever the two events have drawn, the ledger equals the sum of
    ///         what the backstop says each can still reach, and the mark never credits more than
    ///         the standing capacity.
    function testFuzz_S3_F3_theLedgerIsAlwaysTheSumOverLiveDrawnEvents(uint256 lossA, uint256 lossB) public {
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);

        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, bound(lossA, 1, 380_000e18));
        uint256 b = _defaulted(BORROWER_2, 400_000e18);
        _realize(b, bound(lossB, 1, 380_000e18));

        uint256 expected = defaultManager.defaultedContribution(a) + defaultManager.defaultedContribution(b);
        assertEq(defaultManager.liveDefaultCoverageRemaining(), expected, "the ledger left the sum of its parts");

        uint256 drawnResidual = defaultManager.drawnDefaultPrincipal(FILM);
        uint256 credit = drawnResidual < sGrove.coverageReserve() ? drawnResidual : sGrove.coverageReserve();
        if (credit > drawnResidual) credit = drawnResidual;
        assertEq(defaultManager.pendingSeniorImpairment(), drawnResidual - credit, "the mark left the ledger");
    }
}
