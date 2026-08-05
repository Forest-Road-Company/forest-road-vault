// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title PM-R-11 — conservative NAV vs the PM-R-07 per-EVENT coverage cap
/// @notice REGRESSION SUITE for the finding reported 2026-07-21.
///
///         THE BUG. `DefaultManager.pendingSeniorImpairment()` netted the residual declared
///         default against `backstop.coverageCapacity()` — the GLOBAL figure describing what a
///         *fresh* event could draw right now. Since PM-R-07 the sGROVE cap is cumulative PER
///         EVENT and snapshotted at that event's first draw, so an event that has already drawn
///         can only reach `snapshot - drawn`. After a partial `realizeLoss` the two diverge, the
///         NAV netted more coverage than the loss could actually reach, `redemptionTotalAssets()`
///         read HIGH, and a queued senior exited above the true conservative floor — pushing the
///         difference onto the seniors who stayed. Measured at 150,000 USDfr on a 1M reserve.
///         That also contradicted the function's own NatSpec, which claimed it "never under-marks".
///
///         THE FIX (PM-R-11). `DefaultManager` now tracks the sGROVE coverage consumed by
///         still-live declared defaults and deducts it from the netted capacity. There is no
///         enumerable set of declared facilities, so the deduction is an AGGREGATE rather than a
///         per-facility netting. That is deliberate and it errs the safe way: the deduction is at
///         least as large as any single event's consumption, so the netted coverage never exceeds
///         what the declared defaults can genuinely still draw. It may OVER-mark impairment (NAV
///         lower, exits cheaper, remaining seniors protected) and can no longer under-mark.
///
///         These tests run against the REAL `SGrove`, deliberately. The ADR-0022 suite uses
///         `MockCascadeBackstop`, whose `coverShortfall` IGNORED `eventId` and capped per CALL —
///         it could not express PM-R-07's semantics, which is exactly why this went unnoticed.
///         (The mock has since been corrected to mirror the real per-event cap.)
contract ExternalFinding2NavVsEventCapTest is GovernanceFixture {
    uint256 internal constant FILM = 1;

    /// @dev Puts `amount` USDfr into the real sGROVE coverage reserve.
    function _seedCoverage(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    /// @dev The coverage genuinely still reachable BY THIS EVENT, per PM-R-07: the cap
    ///      snapshotted at its first draw, less what it has consumed, bounded by the reserve.
    function _trueRemainingRoomFor(uint256 tokenId) internal view returns (uint256) {
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(tokenId);
        if (cap == 0) {
            cap = sGrove.coverageCapacity(); // never drawn: a fresh snapshot would be taken now
            drawn = 0;
        }
        uint256 room = cap > drawn ? cap - drawn : 0;
        uint256 reserve = sGrove.coverageReserve();
        return room < reserve ? room : reserve;
    }

    /// @dev The conservative floor a senior must never be able to exit above.
    function _trueFloorFor(uint256 tokenId, uint256 remainingDeclared) internal view returns (uint256) {
        uint256 room = _trueRemainingRoomFor(tokenId);
        return remainingDeclared > room ? remainingDeclared - room : 0;
    }

    // ── the regression ───────────────────────────────────────────────────

    /// @notice FRV-FS-04: an unprivileged, protective sGROVE contribution must not
    ///         invalidate a live professional recovery assessment. The exact operational
    ///         hash still changes for monitoring, but the directional binding recognizes
    ///         that global junior capacity only increased.
    function test_permissionlessCoverageDustCannotVoidLiveAssessment() public {
        uint256 id = _liveFilmFacility(6_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        AssessedImpairmentSource assessed = AssessedImpairmentSource(
            address(
                new ERC1967Proxy(
                    address(new AssessedImpairmentSource()),
                    abi.encodeCall(AssessedImpairmentSource.initialize, (admin, admin, address(defaultManager)))
                )
            )
        );
        vm.prank(admin);
        assessed.setAssessment(500e18, uint64(block.timestamp + 7 days), keccak256("professional-memo"));
        bytes32 exactBefore = defaultManager.impairmentStateHash();
        bytes32 riskBefore = defaultManager.impairmentRiskStateHash();

        _seedCoverage(1e12); // one micro-USDfr: economically dust, permissionless

        assertNotEq(defaultManager.impairmentStateHash(), exactBefore, "capacity remains visible operationally");
        assertEq(defaultManager.impairmentRiskStateHash(), riskBefore, "book risk itself did not change");
        assertEq(assessed.pendingSeniorImpairment(), 500e18, "dust cannot restore the zero-recovery floor");
        (,,, bool active,) = assessed.currentAssessment();
        assertTrue(active, "beneficial global coverage preserves the assessment");
    }

    /// @notice THE FIX. After a partial realization consumes part of the event's snapshotted cap,
    ///         the reported impairment is at or above the true floor — never below it.
    function test_pmr11_partialRealizationNeverUnderMarksSeniorImpairment() public {
        assertEq(curator.poolBalance(FILM), 0, "precondition: empty curator pool isolates layer 2");

        uint256 reserve = 1_000_000e18;
        _seedCoverage(reserve);
        uint256 freshCapacity = reserve * Config.SGROVE_PER_EVENT_COVERAGE_CAP_BPS / Config.BPS;
        assertEq(sGrove.coverageCapacity(), freshCapacity, "fresh capacity is capBps of the reserve");

        uint256 principal = 2_000_000e18;
        uint256 id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // Before any draw, nothing is consumed and the mark is exact.
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "nothing consumed yet");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            principal - freshCapacity,
            "pre-draw: the full fresh capacity is legitimately nettable"
        );
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            _trueFloorFor(id, principal),
            "pre-draw: reported == true floor exactly"
        );

        // Realize a PARTIAL loss, fully absorbed by sGROVE, consuming part of the event's cap.
        uint256 partialLoss = freshCapacity * 3 / 5;
        vm.prank(servicer);
        _realizeLoss(id, partialLoss, FILM_REF);

        (uint256 drawn, uint256 snapshot) = sGrove.eventCoverage(id);
        assertEq(drawn, partialLoss, "sGROVE covered the whole partial loss");
        assertEq(snapshot, freshCapacity, "the event's cap was snapshotted at its first draw");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), partialLoss, "consumption is tracked");
        // The per-facility view the independent invariant model reads (PM-R-11): the facility's
        // remaining at-risk contribution falls by exactly the realized loss.
        assertEq(
            defaultManager.defaultedContribution(id),
            principal - partialLoss,
            "defaultedContribution tracks the remaining unrealized principal"
        );

        uint256 remainingDeclared = principal - partialLoss;
        uint256 reported = defaultManager.pendingSeniorImpairment();
        uint256 trueFloor = _trueFloorFor(id, remainingDeclared);

        // THE PROPERTY. Before PM-R-11 this was `reported < trueFloor` by 150,000e18.
        assertGe(reported, trueFloor, "PM-R-11: reported impairment is NEVER below the true floor");

        // And the exact arithmetic: capacity, less what this default already spent.
        uint256 nettable = sGrove.coverageCapacity() - partialLoss;
        assertEq(reported, remainingDeclared - nettable, "nets capacity MINUS consumed coverage");
        emit log_named_uint("conservative over-mark (USDfr, 18dp)", reported - trueFloor);
    }

    /// @notice The consequence that matters: the vault's redemption NAV sits at or below the
    ///         conservative floor, so a senior exiting mid-workout cannot take more than their share.
    function test_pmr11_redemptionNavNeverExceedsTheConservativeFloor() public {
        _seedCoverage(1_000_000e18);
        uint256 freshCapacity = sGrove.coverageCapacity();

        _mintUSDfrTo(alice, 3_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 3_000_000e18);
        vault.deposit(3_000_000e18, alice);
        vm.stopPrank();

        uint256 principal = 2_000_000e18;
        uint256 id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 partialLoss = freshCapacity * 3 / 5;
        vm.prank(servicer);
        _realizeLoss(id, partialLoss, FILM_REF);

        uint256 trueFloor = _trueFloorFor(id, principal - partialLoss);
        uint256 total = vault.totalAssets();
        uint256 conservativeNav = total > trueFloor ? total - trueFloor : 0;

        assertLe(
            vault.redemptionTotalAssets(),
            conservativeNav,
            "PM-R-11: redemption NAV never sits above the true conservative floor"
        );
    }

    // ── the round-2 follow-up: capacity inflation must not re-open the bug ──

    /// @notice A permissionless `fundCoverage` top-up AFTER a partial draw must not hand the
    ///         drawn default coverage it can no longer reach.
    /// @dev The first PM-R-11 patch netted `coverageCapacity() - consumed` against a LIVE
    ///      capacity. `fundCoverage` is role-less and unpausable, so anyone could raise the
    ///      capacity mid-workout and push the mark back below the true floor — the original bug,
    ///      through a second door. The netting is now additionally pinned to the capacity that
    ///      stood at the draw.
    function test_pmr11_fundCoverageTopUpCannotReInflateTheNetting() public {
        _seedCoverage(1_000_000e18);
        uint256 id = _liveFilmFacility(2_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // NB: hoisted — `vm.prank` applies to the VERY NEXT call, and reading
        // `coverageCapacity()` inside the argument list would consume it.
        uint256 partialDraw = sGrove.coverageCapacity() * 3 / 5;
        vm.prank(servicer);
        _realizeLoss(id, partialDraw, FILM_REF);

        uint256 markBefore = defaultManager.pendingSeniorImpairment();
        uint256 remainingDeclared = defaultManager.declaredDefaultedPrincipal(FILM);
        assertGe(markBefore, _trueFloorFor(id, remainingDeclared), "precondition: conservative");

        // Anyone tops the reserve up. The drawn event's ceiling is unchanged (its cap was
        // snapshotted at its first draw), so the mark must not fall.
        uint256 capacityBefore = sGrove.coverageCapacity();
        _seedCoverage(5_000_000e18);
        assertGt(sGrove.coverageCapacity(), capacityBefore, "precondition: capacity really did jump");

        uint256 markAfter = defaultManager.pendingSeniorImpairment();
        assertEq(markAfter, markBefore, "a top-up must not lower the mark for an already-drawn default");
        assertGe(
            markAfter,
            _trueFloorFor(id, defaultManager.declaredDefaultedPrincipal(FILM)),
            "still at or above the true conservative floor"
        );
    }

    /// @notice Governance raising `perEventCapBps` after a partial draw must not re-open it either.
    function test_pmr11_perEventCapRaiseCannotReInflateTheNetting() public {
        _seedCoverage(1_000_000e18);
        uint256 id = _liveFilmFacility(2_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 partialDraw = sGrove.coverageCapacity() * 3 / 5; // hoisted (prank consumption)
        vm.prank(servicer);
        _realizeLoss(id, partialDraw, FILM_REF);
        uint256 markBefore = defaultManager.pendingSeniorImpairment();

        uint256 capacityBefore = sGrove.coverageCapacity();
        vm.prank(admin);
        sGrove.setPerEventCap(uint16(Config.BPS)); // 100% — the largest possible raise
        assertGt(sGrove.coverageCapacity(), capacityBefore, "precondition: capacity really did jump");

        assertEq(
            defaultManager.pendingSeniorImpairment(),
            markBefore,
            "a cap raise must not lower the mark for an already-drawn default"
        );
    }

    /// @notice The pinned floor must be dropped once no live default holds consumption, so an
    ///         unrelated later default is not penalised by an old workout's floor.
    function test_pmr11_capacityFloorIsClearedWithTheLastLiveConsumption() public {
        _seedCoverage(1_000_000e18);
        uint256 first = _liveFilmFacility(400_000e18);
        _attestDefault(first);
        vm.prank(servicer);
        defaultManager.declareDefault(first, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(first, 400_000e18, FILM_REF); // fully realized -> released
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "consumption released");

        _seedCoverage(5_000_000e18); // reserve grows a lot afterwards

        uint256 second = _liveFilmFacility(500_000e18);
        _attestDefault(second);
        vm.prank(servicer);
        defaultManager.declareDefault(second, FILM_REF);

        // No live consumption => net the FULL current capacity, exactly. With the reserve
        // topped up the capacity now exceeds the declared principal, so the mark is zero —
        // which is itself the point: a stale floor would have left a non-zero mark here.
        uint256 capacityNow = sGrove.coverageCapacity();
        uint256 expected = 500_000e18 > capacityNow ? 500_000e18 - capacityNow : 0;
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            expected,
            "a stale floor must not depress a later, undrawn default"
        );
        assertEq(expected, 0, "sanity: the topped-up capacity fully covers this default");
    }

    /// @notice DRAIN-TO-ZERO then REFILL must not re-seed the capacity floor.
    /// @dev Round-3 audit finding, and the third variant of this same defect. The floor used
    ///      `0` as a "not yet set" sentinel, but zero is a LEGITIMATE floor: `coverShortfall`
    ///      clamps `covered` to the reserve, so an event whose cap was snapshotted against a
    ///      LARGER reserve can, once other events have drawn the reserve down, take what is left
    ///      to zero. The next draw then read `floorNow == 0` as "unset" and re-seeded the floor at
    ///      the post-refill capacity — handing live defaults coverage no event could reach, with
    ///      NO governance action required, since `fundCoverage` is permissionless.
    function test_pmr11_drainToZeroThenRefillDoesNotReSeedTheFloor() public {
        _seedCoverage(1_000_000e18);

        // Deep senior book so layer 3 can absorb whatever layer 2 does not.
        _mintUSDfrTo(alice, 8_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 8_000_000e18);
        vault.deposit(8_000_000e18, alice);
        vm.stopPrank();

        // A snapshots its cap against the FULL reserve by drawing a dust amount.
        uint256 a = _liveFilmFacility(3_000_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(a, 1, FILM_REF);
        (, uint256 snapA) = sGrove.eventCoverage(a);
        assertEq(snapA, 500_000e18, "A's cap snapshotted against the full 1M reserve");

        // B drains the reserve down below A's snapshot.
        // A DIFFERENT borrower, so the two facilities do not trip the per-borrower
        // concentration limit while still sharing the one global coverage reserve.
        _mintUSDfrTo(alice, 2_000_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 2_000_000e18);
        _fundFacility(b, 2_000_000e18);
        _attestDefault(b);
        vm.prank(servicer);
        defaultManager.declareDefault(b, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(b, 500_000e18, FILM_REF);

        // ...and C drains it further. Each fresh event's cap is only half of what is LEFT, so it
        // takes two of them to get the reserve strictly below A's (larger, earlier) snapshot.
        _mintUSDfrTo(alice, 1_000_000e18);
        uint256 c = _originateFilm(keccak256("borrower-3"), STATE_GA, 1_000_000e18);
        _fundFacility(c, 1_000_000e18);
        _attestDefault(c);
        vm.prank(servicer);
        defaultManager.declareDefault(c, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(c, 250_000e18, FILM_REF);
        assertLt(sGrove.coverageReserve(), snapA, "reserve now strictly below A's snapshot");

        // A draws again: its room exceeds what is left, so `covered` clamps to the reserve and
        // takes it to (near) zero — driving the capacity, and therefore the floor, to zero.
        vm.prank(servicer);
        _realizeLoss(a, 600_000e18, FILM_REF);
        assertEq(sGrove.coverageCapacity(), 0, "capacity, and so the pinned floor, is now zero");
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "live defaults hold consumption");

        // Anyone refills the reserve, hugely. This must NOT lift the pinned floor.
        _seedCoverage(20_000_000e18);
        assertGt(sGrove.coverageCapacity(), 0, "precondition: capacity jumped");

        // A further draw by a still-live default must not re-seed the floor upward.
        vm.prank(servicer);
        _realizeLoss(a, 100_000e18, FILM_REF);

        assertGe(
            defaultManager.pendingSeniorImpairment(),
            _trueFloorFor(a, defaultManager.declaredDefaultedPrincipal(FILM)),
            "PM-R-11 round 3: drain-then-refill must not push the mark below the true floor"
        );
    }

    /// @notice The deduction must be RELEASED when the default closes out, or a long-lived
    ///         deployment would ratchet it upward forever and permanently over-mark impairment.
    function test_pmr11_consumptionIsReleasedWhenTheDefaultIsFullyRealized() public {
        _seedCoverage(1_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(servicer);
        _realizeLoss(id, 100_000e18, FILM_REF);
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "consumed while the default is live");

        // Realize the remainder: the facility's impairment contribution reaches zero.
        vm.prank(servicer);
        _realizeLoss(id, 300_000e18, FILM_REF);
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "nothing left unrealized");
        assertEq(defaultManager.defaultedContribution(id), 0, "the facility's contribution is spent");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "PM-R-11: consumption released on full realization");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no live default, no mark");
    }

    /// @notice The `onDefaultResolved` release path — a CLEAN recovery after coverage was drawn.
    /// @dev Round-2 audit found this branch had zero coverage: deleting the
    ///      `_releaseCoverageConsumption` call in `onDefaultResolved` left all 743 tests green.
    ///      Without it, a facility that drew coverage and then recovered in full would leave its
    ///      consumption deducted forever, permanently over-marking every future default's NAV.
    function test_pmr11_consumptionIsReleasedOnACleanResolve() public {
        _seedCoverage(1_000_000e18);
        uint256 principal = 400_000e18;
        uint256 id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        vm.prank(servicer);
        _realizeLoss(id, 100_000e18, FILM_REF); // draws coverage, leaves the default live
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "coverage drawn while live");

        // The borrower repays the whole remaining outstanding: the facility reaches Resolved and
        // `WaterfallEngine.distribute` fires the `onDefaultResolved` hook.
        _repay(id, 0, reserves.deployedTo(id));

        assertEq(
            defaultManager.liveDefaultCoverageConsumed(), 0, "PM-R-11: a clean resolve must release the consumption"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no live default, no mark");
    }

    /// @notice The recorded consumption must be `covered`, not the `residual` requested.
    /// @dev Round-2 audit found every earlier test drew in a state where the backstop covered the
    ///      residual IN FULL, so `covered == residual` and swapping them survived the suite. This
    ///      forces the partial-coverage branch — the one PM-R-11 is actually about — by asking for
    ///      more than the event's room.
    function test_pmr11_recordsCoveredNotRequestedResidual() public {
        _seedCoverage(200_000e18);
        uint256 room = sGrove.coverageCapacity(); // 50% of 200k = 100k
        assertEq(room, 100_000e18, "precondition: the event can draw at most 100k");

        uint256 id = _liveFilmFacility(600_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // Stake enough that layer 3 can absorb what layer 2 cannot, so the call does not revert.
        _mintUSDfrTo(alice, 900_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 900_000e18);
        vault.deposit(900_000e18, alice);
        vm.stopPrank();

        uint256 loss = 300_000e18; // 3x the event's room: layer 2 is truncated
        vm.prank(servicer);
        _realizeLoss(id, loss, FILM_REF);

        (uint256 drawn,) = sGrove.eventCoverage(id);
        assertEq(drawn, room, "layer 2 delivered only its room, not the full residual");
        assertLt(drawn, loss, "precondition: this IS the partial-coverage branch");
        assertEq(
            defaultManager.liveDefaultCoverageConsumed(),
            drawn,
            "PM-R-11 records COVERED, not the residual that was requested"
        );
    }

    /// @notice A second, independent default must not have the first one's consumption held
    ///         against it once the first has closed out.
    function test_pmr11_aLaterDefaultIsNotPenalisedByAClosedOne() public {
        _seedCoverage(1_000_000e18);

        uint256 first = _liveFilmFacility(400_000e18);
        _attestDefault(first);
        vm.prank(servicer);
        defaultManager.declareDefault(first, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(first, 400_000e18, FILM_REF);
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "first default closed out");

        uint256 second = _liveFilmFacility(500_000e18);
        _attestDefault(second);
        vm.prank(servicer);
        defaultManager.declareDefault(second, FILM_REF);

        // The fresh capacity is smaller now (the reserve was drawn down), but nothing is
        // deducted on top of it, because no live default has consumed anything.
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            500_000e18 - sGrove.coverageCapacity(),
            "a closed default leaves no residue on the next one"
        );
    }
}
