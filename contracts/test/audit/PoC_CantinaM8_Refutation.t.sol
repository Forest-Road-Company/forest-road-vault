// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @title Cantina finding #8 — "Direct redemptions ignore the past due impairment mark"
/// @notice Every factual claim in the Forest Road response, as an executable assertion.
///
///         The finding argues that `markPastDue` charges the sUSDfr cohort while the direct exit
///         keeps quoting par, leaving a residual that unstaked holders escape — reversing the
///         ADR-0034 X ordering. The mechanism does not hold: `pendingSeniorImpairment()` applies
///         curator first-loss and the sGROVE backstop before returning, and the past-due portion
///         is then clamped to what sUSDfr can actually absorb. No residual can exist.
contract PoC_CantinaM8_Refutation is GovernanceFixture {
    function _markPastDueFacility(uint256 principal, uint256 curatorCapital, uint256 staked)
        internal
        returns (uint256 id)
    {
        id = _liveFilmFacility(principal);
        if (curatorCapital != 0) _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, curatorCapital);
        if (staked != 0) {
            _mintUSDfrTo(bob, staked);
            vm.startPrank(bob);
            usdfr.approve(address(vault), staked);
            vault.deposit(staked, bob);
            vm.stopPrank();
        }
        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        vm.warp(block.timestamp + 30 days); // expire the G2W relief ramp: full weight
    }

    /// @notice CLAIM 1. The vault reads the assessed source, and with no assessment published it
    ///         passes the conservative base through unchanged — so the figures quoted in the
    ///         response are the ones the vault actually prices against.
    function test_claim1_theAssessedSourceAgreesWithTheConservativeBase() public {
        _markPastDueFacility(1_000_000e18, 0, 2_000_000e18);
        assertEq(
            assessedImpairmentSource.pendingSeniorImpairment(),
            defaultManager.pendingSeniorImpairment(),
            "assessed source must pass the conservative base through"
        );
        assertEq(address(vault.impairmentSource()), address(assessedImpairmentSource), "vault reads assessed source");
    }

    /// @notice CLAIM 2. Curator first-loss is netted BEFORE the senior, one for one.
    function test_claim2_curatorFirstLossNetsOneForOne() public {
        uint256 withoutJunior = defaultManager.pendingSeniorImpairment();
        assertEq(withoutJunior, 0, "clean start");

        _markPastDueFacility(1_000_000e18, 200_000e18, 2_000_000e18);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            800_000e18,
            "200k of curator first-loss must reduce the 1,000,000e18 senior mark to 800,000e18"
        );
    }

    /// @notice CLAIM 3. The past-due portion is clamped to sUSDfr's executable capacity, so it can
    ///         never charge more than the senior-staked layer can absorb.
    function test_claim3_thePastDueMarkIsClampedToSeniorCapacity() public {
        _markPastDueFacility(1_000_000e18, 0, 50_000e18);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            50_000e18,
            "a 1,000,000e18 past-due facility against a 50,000e18 vault marks exactly 50,000e18"
        );
    }

    /// @notice CLAIM 4. Therefore no residual escapes to the unstaked cohort: the direct exit
    ///         quoting par is the cascade honouring its order, not inverting it.
    function test_claim4_noResidualExistsForTheUnstakedCohort() public {
        _markPastDueFacility(1_000_000e18, 0, 50_000e18);
        _mintUSDfrTo(alice, 200_000e18);

        assertLe(
            defaultManager.pendingSeniorImpairment(),
            vault.totalAssets(),
            "the mark never exceeds senior-staked capacity, so nothing is left over"
        );
        vm.prank(alice);
        assertEq(controller.redeem(200_000e18, 0), 200_000e18 / 1e12, "unstaked exits at par, correctly");
    }

    /// @notice CLAIM 5, VOLUNTEERED. `declaredSenior` is deliberately NOT clamped. A declared
    ///         default above senior-staked capacity does leave an excess the direct exit cannot
    ///         see — role-gated, and terminating at `realizeLoss`.
    function test_claim5_declaredDefaultAboveCapacityIsNotCoveredByTheClamp() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _mintUSDfrTo(bob, 50_000e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 50_000e18);
        vault.deposit(50_000e18, bob);
        vm.stopPrank();
        _mintUSDfrTo(alice, 200_000e18);

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18, "declared marks at full weight");
        assertEq(vault.redemptionTotalAssets(), 0, "senior-staked NAV clamps to zero");
        assertGt(
            defaultManager.pendingSeniorImpairment() - vault.totalAssets(),
            900_000e18,
            "an excess above senior capacity exists here, unlike the past-due path"
        );
        vm.prank(alice);
        assertEq(controller.redeem(200_000e18, 0), 200_000e18 / 1e12, "and the direct exit still quotes par");
    }
}
