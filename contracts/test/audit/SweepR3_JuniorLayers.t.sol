// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @title SWEEP ROUND 3 — CuratorModule share-ratio probes
/// @notice ADVERSARY PROBES. Each test asserts the property that OUGHT to hold; a RED here is a
///         statement about the shipped tree, not about the test.
///
///         S3-F1. `CuratorModule` advances a class's share round ONLY on an EXACT wipe
///         (`pool.balance == 0`). A NEAR-total absorption — one wei short — leaves the round
///         standing with a collapsed share price, and `postFirstLoss` mints
///         `mulDiv(amount, totalShares, balance)`, so each such absorption multiplies the
///         share/balance ratio by `total / residual`. Three one-wei residuals overflow `mulDiv`
///         and layer-1 recapitalisation for that class reverts for EVERY curator, permanently:
///         no holder of less than the whole share supply can withdraw the last wei either
///         (`postedOf` floors to zero), so nothing on any permissioned or permissionless path
///         can drive the balance to the exact zero the round advance requires.
contract SweepR3_JuniorLayers is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev Drives layer 1 through the SAME entry point the ADR-0034 Y-bis senior-exit draw uses
    ///      (`DefaultManager.drawForSeniorExit` -> `CuratorModule.absorbGlobalLoss`). Pranking the
    ///      DefaultManager is exact: it holds CREDIT_ROLE and is the only caller.
    function _globalAbsorbAs(uint256 loss) internal {
        vm.prank(address(defaultManager));
        curator.absorbGlobalLoss(loss);
    }

    /// @dev The per-class facility route (`realizeLoss` -> `absorbLoss`), same prank rationale.
    function _classAbsorbAs(uint256 classId, uint256 loss) internal {
        vm.prank(address(defaultManager));
        curator.absorbLoss(classId, loss);
    }

    function _tryPost(address who, uint256 amount) internal returns (bool ok) {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(curator), amount);
        try curator.postFirstLoss(FILM, amount) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
    }

    // ── S3-F1 ────────────────────────────────────────────────────────────

    /// @notice THE PROPERTY: layer 1 must remain re-fundable after the cascade has drawn it down.
    ///         Cascade layer 1 exists to be replenished; a class whose first-loss vault can never
    ///         take another dollar has no layer 1 at all for the rest of the deployment.
    function test_S3_F1_layerOneMustStillBeReFundableAfterNearTotalExitDraws() public {
        _postFirstLoss(anchorCurator, FILM, 900e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        assertEq(curator.poolBalance(FILM), 1_000e18, "seeded");
        assertEq(curator.poolShares(FILM), 1_000e18, "1:1 at genesis");

        // Three near-total draws, each leaving ONE WEI standing, with an ordinary
        // recapitalisation in between. Nothing here is privileged beyond the cascade itself.
        for (uint256 i = 0; i < 3; ++i) {
            uint256 bal = curator.poolBalance(FILM);
            _globalAbsorbAs(bal - 1);
            emit log_named_uint("cycle", i);
            emit log_named_uint("  poolBalance", curator.poolBalance(FILM));
            emit log_named_uint("  poolShares ", curator.poolShares(FILM));
            assertEq(curator.poolBalance(FILM), 1, "VACUITY: a near-total draw must leave the pool non-zero");
            emit log_named_uint("  poolRound  ", curator.poolRound(FILM));
            if (i < 2) _postFirstLoss(anchorCurator, FILM, 1_000e18);
        }

        bool anchorCanPost = _tryPost(anchorCurator, 1_000e18);
        bool secondCanPost = _tryPost(secondCurator, 1_000e18);

        // EVIDENCE, LOGGED not asserted so this test states exactly ONE property. On the shipped
        // tree nobody can clear the one wei that keeps the round from advancing either: `postedOf`
        // floors to zero for every holder of less than the whole share supply, so there is no
        // permissioned OR permissionless route back to the exact zero the round advance needs.
        emit log_named_uint("anchor postedOf", curator.postedOf(FILM, anchorCurator));
        emit log_named_uint("second postedOf", curator.postedOf(FILM, secondCurator));
        vm.prank(anchorCurator);
        try curator.withdrawFirstLoss(FILM, 1) {
            emit log("the last wei IS withdrawable");
        } catch {
            emit log("the last wei is NOT withdrawable by ANY curator");
        }

        emit log_named_uint("FINAL poolBalance", curator.poolBalance(FILM));
        emit log_named_uint("FINAL poolShares ", curator.poolShares(FILM));
        assertTrue(anchorCanPost, "S3-F1: the anchor curator can no longer fund cascade layer 1 for this class");
        assertTrue(secondCanPost, "S3-F1: no curator can fund cascade layer 1 for this class");
    }

    /// @notice THE SAME SURFACE ON THE FACILITY ROUTE (`realizeLoss` -> `absorbLoss`), so the
    ///         defect is not specific to the ADR-0034 Y-bis draw.
    function test_S3_F1_theFacilityRouteInflatesTheShareRatioIdentically() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        for (uint256 i = 0; i < 2; ++i) {
            _classAbsorbAs(FILM, curator.poolBalance(FILM) - 1);
            _postFirstLoss(anchorCurator, FILM, 1_000e18);
        }
        emit log_named_uint("shares", curator.poolShares(FILM));
        emit log_named_uint("balance", curator.poolBalance(FILM));
        assertLe(
            curator.poolShares(FILM) / curator.poolBalance(FILM),
            1e18,
            "S3-F1: share/balance ratio exceeded 1e18 after two near-total absorptions"
        );
    }

    /// @notice DISCRIMINATING CONTROL. The identical sequence with a FULL draw wipes the pool to
    ///         zero, the round advances on the next post, and recapitalisation works forever.
    ///         The defect is the one-wei residual, not the size of the loss.
    function test_S3_F1_control_aFullDrawAdvancesTheRoundAndRecapitalisationKeepsWorking() public {
        _postFirstLoss(anchorCurator, FILM, 900e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        for (uint256 i = 0; i < 6; ++i) {
            uint256 bal = curator.poolBalance(FILM);
            _globalAbsorbAs(bal); // FULL wipe
            assertEq(curator.poolBalance(FILM), 0, "full draw empties the pool");
            _postFirstLoss(anchorCurator, FILM, 1_000e18);
            assertEq(curator.poolRound(FILM), i + 1, "the round advanced");
            assertEq(curator.poolShares(FILM), 1_000e18, "shares reset to 1:1");
        }
        assertEq(curator.poolBalance(FILM), 1_000e18, "layer 1 is fully re-funded");
    }

    /// @notice CLEAN NEGATIVE (executed, expected GREEN). The inflated ratio does NOT corrupt
    ///         attribution: every curator's `postedOf` still tracks their pro-rata share of the
    ///         surviving balance, and the shipped `totalShares >= balance` property still holds.
    ///         The defect is a liveness one, not a value-conservation one.
    function test_S3_N1_theInflatedRatioStillAttributesValueCorrectly() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        _globalAbsorbAs(1_000e18 - 1); // ratio -> 1e21
        _postFirstLoss(anchorCurator, FILM, 600e18);
        _postFirstLoss(secondCurator, FILM, 400e18);
        assertGe(curator.poolShares(FILM), curator.poolBalance(FILM), "share price never exceeds 1");
        uint256 a = curator.postedOf(FILM, anchorCurator);
        uint256 b = curator.postedOf(FILM, secondCurator);
        emit log_named_uint("anchor postedOf", a);
        emit log_named_uint("second postedOf", b);
        assertApproxEqAbs(a, 600e18, 2, "anchor keeps its fresh 600e18 (its wiped stake is worth ~1 wei)");
        assertApproxEqAbs(b, 400e18, 2, "second curator keeps its fresh 400e18");
        assertLe(a + b, curator.poolBalance(FILM), "no curator can claim more than the pool holds");
    }
}

/// @title ADR-0035 — SGrove standing-key access to the shared reserve
/// @notice `eventCovered` stays cumulative for observability, but no longer subtracts from a
///         ceiling. Every real replenishment is immediately reachable by the standing exit key.
contract SweepR3_ExitKeyRoom is GovernanceFixture {
    uint256 internal constant EXIT_KEY = LossEventIds.CUSTODY_EVENT_NAMESPACE_START;

    /// @notice ADR-0035 deliberately reverses S3-F2's lifetime-room policy. Cumulative draws remain
    ///         observable, but they cannot withhold newly funded coverage from a live shortfall.
    function test_ADR0035_restoringTheCoverageReserveRestoresSeniorExitReach() public {
        _fundCoverage(100_000e18);
        vm.prank(address(defaultManager));
        uint256 first = sGrove.coverShortfall(EXIT_KEY, 100_000e18);
        assertEq(first, 100_000e18, "one exit must be able to exhaust the shared reserve");
        assertEq(sGrove.coverageReserve(), 0, "reserve was not exhausted");

        // Forest Road tops the backstop back up to EXACTLY where it started.
        _fundCoverage(100_000e18);
        assertEq(sGrove.coverageReserve(), 100_000e18, "reserve fully restored to its pre-draw level");

        vm.prank(address(defaultManager));
        uint256 second = sGrove.coverShortfall(EXIT_KEY, 50_000e18);
        emit log_named_uint("reserve standing at the second exit draw", 100_000e18);
        emit log_named_uint("layer 2 delivered to the second exit draw", second);
        assertEq(second, 50_000e18, "ADR-0035: exact restoration did not re-arm shared reserve");
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(EXIT_KEY);
        assertEq(drawn, 150_000e18, "the lifetime cumulative draw on the standing exit key");
        assertEq(cap - drawn, 50_000e18, "event view does not expose the remaining live reserve");
    }

    /// @notice Every top-up, including one below cumulative draws, becomes exactly reachable.
    function test_ADR0035_replenishmentHasNoCumulativeDrawThreshold() public {
        _fundCoverage(100_000e18);
        vm.prank(address(defaultManager));
        uint256 drawn = sGrove.coverShortfall(EXIT_KEY, 100_000e18);
        assertEq(drawn, 100_000e18, "cumulative drawn");

        _fundCoverage(50_000e18);
        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(EXIT_KEY, 50_000e18), 50_000e18, "first refill was not fully reachable");

        _fundCoverage(10_000e18);
        vm.prank(address(defaultManager));
        uint256 third = sGrove.coverShortfall(EXIT_KEY, 100_000e18);
        assertEq(third, 10_000e18, "second refill was not fully reachable");
        emit log_named_uint("USDfr funded after the first draw", 60_000e18);
        emit log_named_uint("extra layer-2 capacity that bought", third);
    }
}

/// @title SWEEP ROUND 3 — S3-F3: the G2W relief-ramp anchor can be rewound indefinitely
/// @notice `DefaultManager.markPastDue` re-anchors the cohort relief clock on EMPTY -> NON-EMPTY.
///         The shipped guard closes the case its own NatSpec names ("mark a dust facility every 20
///         days"), and `test_g2w_ramp_aSecondMarkCannotRewindTheCohortClock` pins it. It does NOT
///         close the case where the cohort is EMPTIED and the SAME, still-past-due facility is
///         re-marked: `clearPastDue` (SERVICER_ROLE + a `PastDueCured` quorum — finding A-02
///         records that the attester IS the servicer) empties the cohort, and the very next
///         permissionless `markPastDue` — the protocol's own self-healing act, which any bystander
///         is expected to perform — sets the anchor to NOW and hands the whole cohort its 50%
///         relief back. Repeat inside the ramp and `Config.DEFAULT_REDEEM_COOLDOWN`'s expiry, the
///         thing that makes the D5-03 under-mark BOUNDED IN TIME, never fires again.
contract SweepR3_ReliefAnchorRewind is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant RAMP = Config.DEFAULT_REDEEM_COOLDOWN;

    function _openLaunchRampLimitsForFilm() internal {
        vm.startPrank(admin);
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = Config.RAMP_CONCENTRATION_LIMIT_BPS;
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        registry.setStateLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _warpPastGrace(uint256 id) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        vm.warp(uint256(f.nextPaymentDue) + uint256(defaultManager.graceWindow(f.classId)) + 1);
    }

    /// @notice THE PROPERTY: the relief-ramp expiry is a TIME BOUND on the D5-03 under-mark. A
    ///         facility that has been continuously past due, uncured and unattested for longer
    ///         than one `DEFAULT_REDEEM_COOLDOWN` must be marked at FULL weight, whatever
    ///         bookkeeping happened in between.
    function test_S3_F3_theReliefExpiryMustNotBeRewindableByAClearAndReMark() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGrace(id);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        uint256 firstMarkAt = block.timestamp;

        vm.warp(block.timestamp + RAMP);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "precondition: the relief has expired");

        // The servicer clears the mark (no cure has occurred — the facility is still past due,
        // still Active, still owing exactly 400,000e18).
        _clearPastDue(id, FILM_REF);
        assertEq(defaultManager.pastDueExposure(), 0, "cohort emptied");

        // ...and a BYSTANDER immediately re-marks it. This is the H-5 self-healing path.
        vm.prank(carol);
        defaultManager.markPastDue(id);

        emit log_named_uint("continuously past due for (days)", (block.timestamp - firstMarkAt) / 1 days);
        emit log_named_uint("relief anchor (now == rewound)", defaultManager.pastDueReliefAnchor());
        emit log_named_uint("block.timestamp", block.timestamp);
        emit log_named_uint("pendingSeniorImpairment", defaultManager.pendingSeniorImpairment());
        assertEq(defaultManager.pastDueContribution(id), 400_000e18, "same facility, same principal at risk");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            400_000e18,
            "S3-F3: the expired relief came BACK - the ramp's time bound is rewindable"
        );
    }

    /// @notice THE CONSEQUENCE, ITERATED. Twenty-day cycles hold the cohort at maximum relief for
    ///         ever: the loud stop the owner decision promises "returns on its own with nobody
    ///         having to act" never returns at all.
    function test_S3_F3_twentyDayCyclesHoldTheCohortAtMaximumReliefForever() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGrace(id);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        uint256 start = block.timestamp;

        uint256 worst;
        for (uint256 i = 0; i < 6; ++i) {
            vm.warp(block.timestamp + 20 days);
            _clearPastDue(id, keccak256(abi.encode("cycle", i)));
            vm.prank(carol);
            defaultManager.markPastDue(id);
            uint256 mark = defaultManager.pendingSeniorImpairment();
            emit log_named_uint("cycle", i);
            emit log_named_uint("  days past due", (block.timestamp - start) / 1 days);
            emit log_named_uint("  pendingSeniorImpairment", mark);
            if (mark > worst) worst = mark;
        }
        assertEq(
            worst,
            400_000e18,
            "S3-F3: after 120 days continuously past due the honest full-weight mark was never reached"
        );
    }

    /// @notice DISCRIMINATING CONTROL. WITHOUT the clear, the identical facility over the identical
    ///         120 days reaches full weight after the first ramp and stays there. The rewind, not
    ///         the passage of time, is what suppresses the mark.
    function test_S3_F3_control_leftAloneTheSameFacilityReachesFullWeightAndStaysThere() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGrace(id);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        vm.warp(block.timestamp + RAMP); // the one ramp the relief is worth
        for (uint256 i = 0; i < 6; ++i) {
            vm.warp(block.timestamp + 20 days);
            emit log_named_uint("control cycle", i);
            emit log_named_uint("  pendingSeniorImpairment", defaultManager.pendingSeniorImpairment());
            assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "full weight, undisturbed");
        }
    }
}
