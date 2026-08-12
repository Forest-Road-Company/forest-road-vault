// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev ADVERSARY SWEEP ROUND 3 — ReserveManager / DefaultManager / the extraction seam.
///      Probes only; nothing here is a fix. Each test states the property it asserts and, when
///      the shipped tree does not satisfy it, is expected RED.
contract SweepR3_ReserveDefaultSeam is CreditLayerFixture {
    uint256 internal constant FILM = 1;

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _defaulted(uint256 principal) internal returns (uint256 id) {
        id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    /// @dev Compose the historical two-loss seam with the selected arm-bound custody workflow.
    ///      A standing arm may ratify a later incremental physical shortfall; each amount is still
    ///      rederived from the live token balance and checked against its approved ceiling.
    function _applyCustodyLoss(uint256 context, uint256 loss) internal {
        (uint256 armId,,,) = reserves.reserveLossArm();
        if (armId == 0) _armReserveLoss(context);
        _createReserveShortfall(loss);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(loss);
        assertEq(actualLoss, loss, "fixture: ratification must use the canonical live loss");
    }

    // ────────────────────────────────────────────────────────────────────
    // S3-F1 — the PM-R-11 drawn-cohort clamp subtracts the consumed coverage TWICE.
    //
    // `ConservativeImpairmentMath` computes the layer-2 credit a DRAWN event may still reach as
    //     drawnCap = min(liveDefaultCapacityFloor, coverageCapacity()) - liveDefaultCoverageConsumed
    // Both terms of the `min` are read AFTER the draw and are therefore ALREADY net of it:
    // `DefaultManager.realizeLoss` records `liveDefaultCapacityFloor = backstop.coverageCapacity()`
    // AFTER `_coverFromBackstop` has moved the USDfr out, and the NAV's `currentCap` is the live
    // capacity. Subtracting `consumed` from either of them a second time removes the same coverage
    // twice, so the drawn cohort is credited less layer-2 capacity than `SGrove` would actually
    // hand it if `realizeLoss` were called again in the same block.
    //
    // THE SOURCE OF TRUTH is `SGrove.eventCoverage(eventId) -> (drawn, cap)`: the event's remaining
    // room is `cap - drawn`, clamped by the live reserve. The assertion below reads it directly, so
    // it is a differential against the backstop rather than a restatement of the NAV's own formula.
    // ────────────────────────────────────────────────────────────────────
    function test_S3_F1_theDrawnCohortIsCreditedTheCoverageItsEventCanStillReach() public {
        _stakeVault(alice, 500e18);
        _fundBackstop(100e18);

        uint256 tokenId = _defaulted(300e18);
        _attestLoss(tokenId, 50e18, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(tokenId, 50e18, FILM_REF);

        // The whole class is now DRAWN: 250e18 of declared principal, no curator pool.
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 250e18, "fixture: declared pool");
        assertEq(defaultManager.drawnDefaultPrincipal(FILM), 250e18, "fixture: the cohort is fully drawn");
        assertEq(curator.poolBalance(FILM), 0, "fixture: layer 1 must be empty so layer 2 is the only credit");

        (uint256 eventDrawn, uint256 eventCap) = backstopMock.eventCoverage(tokenId);
        uint256 liveCapacity = backstopMock.coverageCapacity();
        uint256 roomLeft = eventCap - eventDrawn;
        uint256 reachable = roomLeft < liveCapacity ? roomLeft : liveCapacity;

        emit log_named_uint("event cumulative reach view ", eventCap);
        emit log_named_uint("event coverage already drawn", eventDrawn);
        emit log_named_uint("live shared reserve capacity", liveCapacity);
        emit log_named_uint("STILL REACHABLE by this event", reachable);
        emit log_named_uint("liveDefaultCoverageRemaining", defaultManager.liveDefaultCoverageRemaining());
        emit log_named_uint("liveDefaultCoverageConsumed ", defaultManager.liveDefaultCoverageConsumed());
        emit log_named_uint("pendingSeniorImpairment()   ", defaultManager.pendingSeniorImpairment());

        assertGt(reachable, 0, "fixture: the drawn event must still have room, or the probe proves nothing");

        // The honest post-junior senior residual: the drawn principal less the layer-2 coverage the
        // event can still reach.
        uint256 honest = 250e18 - reachable;
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            honest,
            "S3-F1: the drawn cohort was denied coverage its own event can still reach (consumed subtracted twice)"
        );
    }

    /// @dev The control that makes the attribution unambiguous: with the SAME book and the SAME
    ///      backstop balance but NO draw ever taken (so `consumed == 0` and the clamp branch is not
    ///      entered), the undrawn cohort IS credited the full live capacity. Any difference between
    ///      the two tests is the clamp, not the fixture.
    function test_S3_F1_control_anUndrawnCohortIsCreditedTheFullLiveCapacity() public {
        _stakeVault(alice, 500e18);
        _fundBackstop(50e18); // the post-draw balance of the test above

        uint256 tokenId = _defaulted(250e18); // the post-realization declared pool of the test above
        tokenId; // silence

        assertEq(defaultManager.drawnDefaultPrincipal(FILM), 0, "control: nothing drawn");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 0, "control: no consumption");
        assertEq(curator.poolBalance(FILM), 0, "control: layer 1 empty");

        emit log_named_uint("live coverage capacity   ", backstopMock.coverageCapacity());
        emit log_named_uint("pendingSeniorImpairment()", defaultManager.pendingSeniorImpairment());

        assertEq(
            defaultManager.pendingSeniorImpairment(),
            250e18 - 50e18,
            "control: an UNDRAWN cohort nets the whole live capacity"
        );
    }

    // ────────────────────────────────────────────────────────────────────
    // S3-F2 — the SWEEP-2 F-S2-02 remediation carries the pre-existing G3 valuation deficit into
    // `_recordPostLossDeficit`, which LATCHES it as `reserveDeficit`. The record-only branch is
    // then armed for every LATER custody loss, and F-S2-02's own defect returns one transaction
    // after it was fixed.
    //
    // `_allocateReserveLoss` deliberately carries `deficitBefore` OUT of the cascade — its own
    // comment says it "is NOT re-charged to any layer; it is only re-published so the
    // reconciliation closes". `_recordPostLossDeficit` then writes that re-published number
    // straight into `$.reserveDeficit`, which is the LATCH that decides whether the NEXT loss gets
    // a cascade at all. `custodyLossUnabsorbed()` limb 2 documents that latch as meaning "the
    // cascade could not absorb the whole loss" — here the cascade absorbed 100% of it.
    //
    // It cannot be cleared while the workout runs: `resolveReserveDeficit` refuses while
    // `supply > backing`, and a standing G3 mark is exactly that state.
    // ────────────────────────────────────────────────────────────────────
    function test_S3_F2_aSecondCustodyLossOnAStandingMarkSkipsTheCascadeEntirely() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        uint256 id = _liveFilmFacility(1_000_000e18);

        // The G3 valuation act: under-backed with NO incident, NO reserveDeficit, NO live shortfall.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 400_000e18, keccak256("adjudication"));
        uint256 markDeficit = controller.totalUSDfr() - controller.backingValue();
        assertEq(reserves.reserveDeficit(), 0, "precondition: no latch -- this is a mark, not insolvency");

        // ── custody loss #1: the F-S2-02 fix works, the cascade runs ──
        uint256 pool0 = curator.poolBalance(FILM);
        _applyCustodyLoss(91, 50_000e18);
        assertEq(pool0 - curator.poolBalance(FILM), 50_000e18, "F-S2-02: loss #1 charges layer 1 in full");

        // …and on the shipped tree the carried, UNCASCADED mark deficit is now the LATCH. Logged
        // rather than asserted: it is the MECHANISM, not the property under test, so a remediation
        // that stops latching it must not red this test on the way to making the property hold.
        emit log_named_uint("mark deficit (never offered to the cascade)", markDeficit);
        emit log_named_uint("reserveDeficit LATCHED after loss #1     ", reserves.reserveDeficit());

        // ── custody loss #2, identical in every way ──
        uint256 pool1 = curator.poolBalance(FILM);
        uint256 backstop1 = usdfr.balanceOf(address(backstopMock));
        uint256 vault1 = vault.totalAssets();
        _applyCustodyLoss(92, 50_000e18);

        emit log_named_uint("layer 1 charged by loss #1", pool0 - pool1);
        emit log_named_uint("layer 1 charged by loss #2", pool1 - curator.poolBalance(FILM));
        emit log_named_uint("layer 2 charged by loss #2", backstop1 - usdfr.balanceOf(address(backstopMock)));
        emit log_named_uint("layer 3 charged by loss #2", vault1 - vault.totalAssets());
        emit log_named_uint("reserveDeficit after loss #2", reserves.reserveDeficit());

        assertEq(
            pool1 - curator.poolBalance(FILM),
            50_000e18,
            "S3-F2: the SECOND custody loss must charge layer 1 too -- the cascade was skipped entirely"
        );
    }

    /// @dev The discriminating control. The IDENTICAL pair of custody losses with NO G3 mark
    ///      standing: both charge layer 1 in full, so the difference is the carried mark deficit
    ///      being latched, not the fixture, not the incident id, and not the second write-down.
    function test_S3_F2_control_twoCustodyLossesWithNoMarkBothChargeLayer1() public {
        _postFirstLoss(anchorCurator, FILM, 300_000e18);
        _liveFilmFacility(1_000_000e18);

        uint256 pool0 = curator.poolBalance(FILM);
        _applyCustodyLoss(93, 50_000e18);
        uint256 pool1 = curator.poolBalance(FILM);
        assertEq(pool0 - pool1, 50_000e18, "control: loss #1 charges layer 1");
        assertEq(reserves.reserveDeficit(), 0, "control: a fully absorbed loss latches nothing");

        _applyCustodyLoss(94, 50_000e18);

        assertEq(pool1 - curator.poolBalance(FILM), 50_000e18, "control: loss #2 ALSO charges layer 1");
    }
}
