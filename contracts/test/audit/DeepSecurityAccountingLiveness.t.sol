// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @notice Local defensive proofs for conservative-settlement and loss-path liveness.
contract DeepSecurityAccountingLivenessTest is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    function test_excessCuratorCapitalCanRaiseSettlementThenBeWithdrawn() public {
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

        assertEq(defaultManager.pendingSeniorImpairment(), principal - target);
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

        // A merely past-due facility does not freeze curator withdrawals. Class exposure
        // is 20m but the requirement is capped at the fixed 10m target, so the same 10m
        // can leave after the higher settlement price has been locked in.
        vm.prank(secondCurator);
        curator.withdrawFirstLoss(FILM, target);
        assertEq(curator.poolBalance(FILM), target);
        assertEq(defaultManager.pendingSeniorImpairment(), principal - target);
        assertEq(usdfr.balanceOf(secondCurator), target);

        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        queue.claim(requestId);
        assertEq(usdfr.balanceOf(alice) - aliceBefore, temporarilyImprovedQuote);
        assertGt(temporarilyImprovedQuote, vault.previewRedeem(requestShares));
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
