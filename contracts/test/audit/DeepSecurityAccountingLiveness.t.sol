// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @notice Local defensive proofs for conservative-settlement and loss-path liveness.
contract DeepSecurityAccountingLivenessTest is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @notice ══════════ INVERTED (SWEEP-2 CSG-F1) — DO NOT RESTORE THE ORIGINAL ASSERTIONS ══════
    ///         THIS TEST WAS THE FINDING, WRITTEN DOWN AS EXPECTED LIVENESS, AND ITS NAME SAID SO:
    ///         `test_excessCuratorCapitalCanRaiseSettlementThenBeWithdrawn`. Its closing block read:
    ///             // A merely past-due facility does not freeze curator withdrawals. Class exposure
    ///             // is 20m but the requirement is capped at the fixed 10m target, so the same 10m
    ///             // can leave after the higher settlement price has been locked in.
    ///             vm.prank(secondCurator);
    ///             curator.withdrawFirstLoss(FILM, target);
    ///             assertEq(curator.poolBalance(FILM), target);
    ///             assertEq(usdfr.balanceOf(secondCurator), target);
    ///         That is layer-1 capital walking out AFTER it had removed the conservative senior mark
    ///         and AFTER a senior settlement had been priced and locked at the improved level — the
    ///         cascade run backwards, with the senior queue paid out of a credit the junior then
    ///         withdrew. It is exactly the "post to lift the mark, settle, withdraw" round trip
    ///         SWEEP-2 CSG-F1 measured at 350,000e18 of destroyed senior exit value on a smaller
    ///         book. `min(firstLossTarget, classExposure)` was the wrong bound; the conservative
    ///         NAV credits `min(declared + pastDue, poolBalance)`.
    ///
    ///         WHAT REMAINS TRUE AND IS STILL ASSERTED: everything up to the settlement. The
    ///         second curator's capital DOES lift the mark, the improved quote IS what the epoch
    ///         locks in, and the claim pays it. Only the exit is now refused, and refused on the
    ///         HEADROOM rule — the class is still not frozen (`unresolvedDefaults == 0`).
    /// @dev MUTATION: drop the `marked` term from `CuratorModule._requiredFirstLoss` -> RED here on
    ///      the `expectRevert`.
    function test_excessCuratorCapitalRaisesSettlementAndIsThenLockedIn() public {
        uint256 seniorAssets = 50_000_000e18;
        uint256 requestAssetTarget = 100_000e18;
        uint256 target = Config.DEFAULT_FIRST_LOSS_PER_CLASS;
        uint256 principal = 20_000_000e18;

        _openLaunchRampLimitsForFilm();
        _mintUSDfrTo(alice, seniorAssets);
        vm.startPrank(alice);
        usdfr.approve(address(vault), seniorAssets);
        vault.deposit(seniorAssets, alice);
        uint256 requestShares = vault.convertToShares(requestAssetTarget);
        vault.approve(address(queue), requestShares);
        uint256 requestId = queue.requestRedeem(requestShares);
        vm.stopPrank();

        _postFirstLoss(anchorCurator, FILM, target);
        uint256 facilityId = _originateFilm(BORROWER_1, STATE_GA, principal);
        _fundFacility(facilityId, principal);

        uint64 nextDue = bridge.facility(facilityId).nextPaymentDue;
        vm.warp(uint256(nextDue) + uint256(defaultManager.graceWindow(FILM)) + 1);
        defaultManager.markPastDue(facilityId);

        // OWNER DECISION (Forest Road, 2026-08-07): the past-due cohort's post-curator residual is
        // `principal - target`, but it is UNATTESTED, so it enters the conservative NAV at the
        // governed weight rather than on the same footing as an attested declared default. The
        // executable clamp is not binding here (50m of senior assets stand behind a 10m residual).
        assertEq(defaultManager.pendingSeniorImpairment(), registry.weightedPastDueImpairment(principal - target));
        uint256 impairedQuote = vault.previewRedeem(requestShares);

        // A second approved curator temporarily posts exactly the pool's excess headroom.
        // This removes the conservative senior mark even though the past-due principal is
        // unchanged and no recovery/default resolution has occurred.
        _postFirstLoss(secondCurator, FILM, target);
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
        uint256 temporarilyImprovedQuote = vault.previewRedeem(requestShares);
        assertGt(temporarilyImprovedQuote, impairedQuote);

        queue.closeEpoch(10);
        (, uint256 sharesRemaining, uint256 assetsClaimable,,) = queue.request(requestId);
        assertEq(sharesRemaining, 0);
        assertEq(assetsClaimable, temporarilyImprovedQuote);

        // INVERTED (SWEEP-2 CSG-F1). The mark credits `min(declared + pastDue, poolBalance)` —
        // here the WHOLE 20m pool against a 20m past-due principal — so NOTHING may leave, and the
        // second curator's capital cannot fund the improved settlement and then walk.
        assertEq(curator.unresolvedDefaults(FILM), 0, "still NOT a class freeze: this is a headroom floor");
        assertEq(curator.headroom(FILM), 0, "the past-due mark credits the entire pool");
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, target, uint256(0))
        );
        vm.prank(secondCurator);
        curator.withdrawFirstLoss(FILM, target);
        assertEq(curator.poolBalance(FILM), 2 * target, "layer-1 capital that lifted the mark stayed put");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "and the mark it lifted stays lifted");
        assertEq(usdfr.balanceOf(secondCurator), 0, "no junior capital escaped the settlement it priced");

        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        queue.claim(requestId);
        assertEq(usdfr.balanceOf(alice) - aliceBefore, temporarilyImprovedQuote);
    }

    function test_pausedReserveManagerDoesNotBlockNeverPausableLossRecognition() public {
        uint256 principal = 1_000_000e18;
        uint256 loss = 100_000e18;
        bytes32 evidence = keccak256("paused-reserve-loss");

        _postFirstLoss(anchorCurator, FILM, loss);
        uint256 facilityId = _liveFilmFacility(principal);
        _attestDefault(facilityId);
        vm.prank(servicer);
        defaultManager.declareDefault(facilityId, FILM_REF);
        _attestLoss(facilityId, loss, evidence);

        uint256 poolBefore = curator.poolBalance(FILM);
        uint256 deployedBefore = reserves.deployedTo(facilityId);
        vm.prank(guardian);
        reserves.pause();
        assertTrue(reserves.paused(), "precondition: ReserveManager is paused");

        vm.prank(servicer);
        defaultManager.realizeLoss(facilityId, loss, evidence);

        assertEq(curator.poolBalance(FILM), poolBefore - loss);
        assertEq(reserves.deployedTo(facilityId), deployedBefore - loss);
        assertTrue(reserves.paused(), "loss recognition does not silently unpause custody paths");
    }

    function _openLaunchRampLimitsForFilm() internal {
        vm.startPrank(admin);
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = Config.RAMP_CONCENTRATION_LIMIT_BPS;
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        registry.setStateLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        vm.stopPrank();
    }
}
