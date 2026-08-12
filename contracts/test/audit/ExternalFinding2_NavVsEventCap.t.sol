// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title ADR-0035 — conservative NAV against one uncapped live reserve
/// @notice This historical PM-R-11 suite is retained and deliberately re-pointed. The owner
///         decision removes the event ceiling that created its original drawn/undrawn split;
///         every live event now reaches the same physical reserve and replenishment is immediately
///         executable. The tests continue to run against the real SGrove.
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

    /// @dev ADR-0035: `eventCoverage` publishes cumulative draw plus live shared reach, never a
    ///      frozen snapshot. The subtraction therefore equals the physical reserve.
    function _trueRemainingRoomFor(uint256 tokenId) internal view returns (uint256) {
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(tokenId);
        uint256 room = cap > drawn ? cap - drawn : 0;
        uint256 reserve = sGrove.coverageReserve();
        return room < reserve ? room : reserve;
    }

    /// @dev The conservative floor a senior must never be able to exit above.
    function _trueFloorFor(uint256 tokenId, uint256 remainingDeclared) internal view returns (uint256) {
        uint256 room = _trueRemainingRoomFor(tokenId);
        return remainingDeclared > room ? remainingDeclared - room : 0;
    }

    /// @dev Independent reconstruction of the public risk fingerprint. The hash is deliberately
    /// checked from getters here so a mutation that swaps the live reachable-coverage ledger for
    /// the deprecated floor cannot hide behind the revision counter changing on the same draw.
    function _riskHashFromPublicState() internal view returns (bytes32 stateHash) {
        stateHash = keccak256(
            abi.encode(
                block.chainid,
                address(defaultManager),
                defaultManager.impairmentRevision(),
                address(curator),
                defaultManager.backstop(),
                defaultManager.liveDefaultCoverageConsumed(),
                defaultManager.liveDefaultCoverageRemaining(),
                defaultManager.pastDueExposure()
            )
        );
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            stateHash = keccak256(
                abi.encode(
                    stateHash,
                    classId,
                    defaultManager.declaredDefaultedPrincipal(classId),
                    defaultManager.pastDuePrincipal(classId),
                    curator.poolBalance(classId),
                    defaultManager.drawnDefaultPrincipal(classId)
                )
            );
        }
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

    /// @notice THE FIX, RE-POINTED BY ADR-0035. After a partial realization, the reported
    ///         impairment equals the floor supported by remaining principal and shared reserve.
    /// @dev ═══════ INVERTED LOUDLY (SWEEP-3 F-S3-01, MEDIUM) — DO NOT REVERT THESE LINES ═══════
    ///      THIS TEST USED TO MEASURE THE DEFECT AND CALL IT ACCEPTABLE. Its final assertion read
    ///      `assertEq(reported, remainingDeclared - (sGrove.coverageCapacity() - partialLoss),
    ///      "nets capacity MINUS consumed coverage")` and the line under it LOGGED
    ///      `reported - trueFloor` as a "conservative over-mark" without asserting on it. On the
    ///      shipped tree that log printed EXACTLY 150,000e18 — precisely the magnitude this test's
    ///      own comment says PM-R-11 corrected, in the other direction. PM-R-11 overshot, and the
    ///      one test positioned to catch it printed the number instead of asserting it.
    ///      ROOT CAUSE: `consumed` was subtracted TWICE — once implicitly, because
    ///      `liveDefaultCapacityFloor` was recorded from the capacity read AFTER the draw, and once
    ///      explicitly in `ConservativeImpairmentMath`. See the SWEEP-3 F-S3-01 blocks on
    ///      `DefaultManager._drawLayer2ForLiveDefault` and `ConservativeImpairmentMath`.
    ///      The mark now lands EXACTLY on this file's own `_trueFloorFor` definition: conservative
    ///      means "never below the floor", not "arbitrarily above it".
    /// @dev MUTATION: in `ConservativeImpairmentMath`, restore
    ///      `uint256 drawnCap = floorNow < currentCap ? floorNow : currentCap;
    ///       drawnCap = drawnCap > consumed ? drawnCap - consumed : 0;`
    ///      (compiles; both operands still read) -> RED here on the equality and on the
    ///      zero-over-mark assertion.
    function test_pmr11_partialRealizationNeverUnderMarksSeniorImpairment() public {
        assertEq(curator.poolBalance(FILM), 0, "precondition: empty curator pool isolates layer 2");

        uint256 reserve = 1_000_000e18;
        _seedCoverage(reserve);
        uint256 freshCapacity = reserve;
        assertEq(sGrove.coverageCapacity(), freshCapacity, "ADR-0035 capacity is the live reserve");

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
        assertEq(
            defaultManager.impairmentRiskStateHash(),
            _riskHashFromPublicState(),
            "risk fingerprint must include the public reachable-coverage ledger"
        );

        bytes32 riskBeforeDraw = defaultManager.impairmentRiskStateHash();

        // Realize a PARTIAL loss, fully absorbed by sGROVE, consuming part of the event's cap.
        uint256 partialLoss = freshCapacity * 3 / 5;
        vm.prank(servicer);
        _realizeLoss(id, partialLoss, FILM_REF);
        assertNotEq(
            defaultManager.impairmentRiskStateHash(),
            riskBeforeDraw,
            "risk identity must commit the newly reachable-coverage ledger"
        );
        assertEq(
            defaultManager.impairmentRiskStateHash(),
            _riskHashFromPublicState(),
            "risk fingerprint lost the post-draw reachable-coverage ledger"
        );

        (uint256 drawn, uint256 snapshot) = sGrove.eventCoverage(id);
        assertEq(drawn, partialLoss, "sGROVE covered the whole partial loss");
        assertEq(snapshot - drawn, sGrove.coverageReserve(), "event view exposes live shared reach");
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

        // ═════ INVERTED (SWEEP-3 F-S3-01) — the over-mark is ASSERTED AWAY, not logged ═════
        // The old body computed `nettable = sGrove.coverageCapacity() - partialLoss`, which is the
        // POST-draw capacity minus the draw — the consumed coverage removed a second time. The
        // event's own remaining room is its SNAPSHOT less its draw, bounded by the live reserve,
        // which is exactly `_trueRemainingRoomFor`. The mark now equals the floor to the wei.
        assertEq(
            reported,
            remainingDeclared - _trueRemainingRoomFor(id),
            "F-S3-01: nets the event's OWN remaining room -- `consumed` subtracted exactly once"
        );
        emit log_named_uint("conservative over-mark (USDfr, 18dp)", reported - trueFloor);
        assertEq(
            reported - trueFloor,
            0,
            "F-S3-01: the drawn cohort must not be over-marked -- this printed 150,000e18 pre-fix"
        );
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

    // ── ADR-0035 follow-up: replenishment immediately re-arms shared protection ──

    /// @notice A permissionless top-up after a partial draw is real executable protection and
    ///         must lower the mark by exactly the newly reachable amount.
    function test_pmr11_fundCoverageTopUpImmediatelyRearmsTheSharedReserve() public {
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

        // Anyone tops the reserve up; ADR-0035 makes it immediately reachable by this row.
        uint256 capacityBefore = sGrove.coverageCapacity();
        _seedCoverage(5_000_000e18);
        assertGt(sGrove.coverageCapacity(), capacityBefore, "precondition: capacity really did jump");

        uint256 markAfter = defaultManager.pendingSeniorImpairment();
        assertLt(markAfter, markBefore, "real replenishment must lower the executable loss mark");
        assertEq(markAfter, _trueFloorFor(id, remainingDeclared), "mark equals the live executable floor");
    }

    /// @notice A top-up is shared by drawn and undrawn rows; neither owns a frozen allocation.
    function test_f1801_fundCoverageTopUpProtectsTheWholeLiveCohort() public {
        _seedCoverage(1_000_000e18);

        uint256 drawnId = _liveFilmFacility(2_000_000e18);
        _attestDefault(drawnId);
        vm.prank(servicer);
        defaultManager.declareDefault(drawnId, FILM_REF);

        uint256 partialDraw = sGrove.coverageCapacity() * 3 / 5;
        vm.prank(servicer);
        _realizeLoss(drawnId, partialDraw, FILM_REF);

        uint256 undrawnId = _liveFilmFacility(1_000_000e18);
        _attestDefault(undrawnId);
        vm.prank(servicer);
        defaultManager.declareDefault(undrawnId, FILM_REF);

        assertEq(
            defaultManager.drawnDefaultPrincipal(FILM),
            defaultManager.defaultedContribution(drawnId),
            "only the facility that consumed coverage is floor-constrained"
        );
        uint256 markBefore = defaultManager.pendingSeniorImpairment();
        uint256 gross = defaultManager.performanceFeeImpairment();
        assertGt(gross - markBefore, 0, "precondition: live junior credit exists");
        uint256 drawnRoomBefore = _trueRemainingRoomFor(drawnId);

        _seedCoverage(5_000_000e18);

        uint256 markAfter = defaultManager.pendingSeniorImpairment();

        assertGt(_trueRemainingRoomFor(drawnId), drawnRoomBefore, "drawn row reaches replenished reserve");
        assertEq(markAfter, 0, "replenished reserve covers the whole live cohort");
        assertEq(gross, defaultManager.performanceFeeImpairment(), "gross loss identity changed");
    }

    /// @notice Compatibility capacity parameters are the uncapped identity and cannot be governed.
    function test_pmr11_capacityParametersEncodeTheUncappedIdentity() public {
        _seedCoverage(1_000_000e18);
        uint256 id = _liveFilmFacility(2_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 partialDraw = sGrove.coverageCapacity() * 3 / 5; // hoisted (prank consumption)
        vm.prank(servicer);
        _realizeLoss(id, partialDraw, FILM_REF);
        (uint16 bps, uint256 absoluteCap) = sGrove.coverageCapParameters();
        assertEq(bps, Config.BPS, "identity bps");
        assertEq(absoluteCap, type(uint256).max, "no absolute event cap");
        assertEq(sGrove.coverageCapacityAt(sGrove.coverageReserve()), sGrove.coverageReserve());
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

    /// @notice DRAIN-TO-ZERO then REFILL immediately restores executable layer-two capacity.
    function test_pmr11_drainToZeroThenRefillRearmsTheSharedReserve() public {
        _seedCoverage(1_000_000e18);

        // Deep senior book so layer 3 can absorb whatever layer 2 does not.
        _mintUSDfrTo(alice, 8_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 8_000_000e18);
        vault.deposit(8_000_000e18, alice);
        vm.stopPrank();

        // A can drain the whole shared reserve in one realization.
        uint256 a = _liveFilmFacility(3_000_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(a, 1_000_000e18, FILM_REF);
        assertEq(sGrove.coverageCapacity(), 0, "first event exhausted layer two");
        assertGt(defaultManager.liveDefaultCoverageConsumed(), 0, "live defaults hold consumption");

        // Anyone refills the reserve; the still-live event can use it immediately.
        _seedCoverage(500_000e18);
        assertEq(sGrove.coverageCapacity(), 500_000e18, "replenishment restored live capacity");

        vm.prank(servicer);
        _realizeLoss(a, 500_000e18, FILM_REF);
        assertEq(sGrove.coverageCapacity(), 0, "same event can consume the replenishment");

        assertEq(
            defaultManager.pendingSeniorImpairment(),
            _trueFloorFor(a, defaultManager.declaredDefaultedPrincipal(FILM)),
            "mark follows the physical reserve after drain and refill"
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
        uint256 room = sGrove.coverageCapacity();
        assertEq(room, 200_000e18, "precondition: the event can draw the whole reserve");

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

        // The shared reserve still exceeds the second principal, and the closed event leaves no
        // event-owned residue to deduct from it. The later default is therefore fully covered.
        assertGt(sGrove.coverageCapacity(), 500_000e18, "fixture: shared reserve must cover the later default");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "a closed default leaves no residue on the next one");
    }
}
