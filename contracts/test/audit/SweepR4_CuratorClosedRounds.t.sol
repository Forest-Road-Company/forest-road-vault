// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title SWEEP ROUND 4 — S4-R1. The curator CLOSED ROUND must carry a residual claim.
/// @notice SWEEP-3 S3-F1 fixed a genuine LIVENESS brick — a near-total exit draw collapsed the
///         layer-1 share ratio until `postFirstLoss` reverted on `Math.mulDiv` overflow for every
///         curator — by advancing the share round once the price falls to or below 1e-18 and
///         seeding the new round with `totalShares = balance`. The residual `balance` at that
///         instant becomes UNOWNED backing and every stale-round stake is zeroed.
///
///         S3-F1's own NatSpec bounds the forfeiture as dust: "on a 1,000,000e18 pool that caps
///         the forfeited dust at 1e6 wei (1e-12 USDfr)". THAT BOUND ASSUMES A SHARE PRICE NEAR 1.
///         It is `balance <= totalShares / 1e18`, and `totalShares` is NOT bounded by the balance —
///         a post made while the price is already collapsed mints
///         `mulDiv(amount, totalShares, balance)` shares, which inflates `totalShares` by up to
///         1e18x for the SAME balance. After one such recapitalisation the close threshold sits
///         just below the FULL pool, so an arbitrarily small further loss closes the round and
///         forfeits essentially all of the freshly posted capital.
///
///         The probes below assert the property that OUGHT to hold: a curator's claim may fall by
///         the loss the cascade actually absorbed, and by no more than that. A RED is a statement
///         about the tree, not about the test.
contract SweepR4_CuratorClosedRounds is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev The ADR-0034 Y-bis senior-exit draw entry point (`drawForSeniorExit` ->
    ///      `absorbGlobalLoss`). Pranking the DefaultManager is exact: it holds CREDIT_ROLE and is
    ///      the only caller.
    function _globalAbsorbAs(uint256 loss) internal {
        vm.prank(address(defaultManager));
        curator.absorbGlobalLoss(loss);
    }

    /// @dev Drives the FILM pool to a share price just ABOVE the S3-F1 close threshold and then
    ///      recapitalises, which is what inflates `totalShares` against the restored balance.
    ///      Returns the loss that will subsequently be enough to cross the threshold.
    function _armCollapsedRatio() internal returns (uint256 crossingLoss) {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        // Leave the pool one wei ABOVE the close threshold (threshold = totalShares / 1e18).
        uint256 threshold = curator.poolShares(FILM) / 1e18;
        _globalAbsorbAs(curator.poolBalance(FILM) - (threshold + 1));
        assertEq(curator.poolBalance(FILM), threshold + 1, "armed just above the close threshold");
        assertEq(curator.poolRound(FILM), 0, "no round advance yet");

        // Recapitalise. The post prices shares against a 1001-wei book, so `totalShares` explodes
        // while the balance returns to ~1_000e18 — the close threshold now sits just under the
        // WHOLE pool.
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        assertEq(curator.poolRound(FILM), 0, "still the first round");

        uint256 balance = curator.poolBalance(FILM);
        uint256 newThreshold = curator.poolShares(FILM) / 1e18;
        emit log_named_uint("balance after recap ", balance);
        emit log_named_uint("close threshold now ", newThreshold);
        assertLt(newThreshold, balance, "the pool is not already closed");
        crossingLoss = balance - newThreshold;
        emit log_named_uint("loss needed to close", crossingLoss);
    }

    /// @notice THE PROPERTY: closing a round may forfeit only what the cascade actually took.
    ///         A curator whose capital survived a loss must still have a claim on it after the
    ///         round that held it is closed as economically wiped.
    function test_S4_R1_aRoundCloseMustNotForfeitTheSurvivingResidual() public {
        uint256 crossingLoss = _armCollapsedRatio();

        uint256 postedBefore = curator.postedOf(FILM, anchorCurator);
        emit log_named_uint("anchor posted before", postedBefore);

        // A loss SMALLER than the pool crosses the close threshold.
        _globalAbsorbAs(crossingLoss);
        assertGt(curator.poolBalance(FILM), 0, "VACUITY: the pool must still hold real capital");
        emit log_named_uint("pool balance after loss", curator.poolBalance(FILM));

        // An UNRELATED curator recapitalises, which is what closes the round. The anchor takes no
        // action at all — this is not a self-inflicted forfeiture.
        _postFirstLoss(secondCurator, FILM, 1e18);
        assertEq(curator.poolRound(FILM), 1, "the round closed");

        uint256 postedAfter = curator.postedOf(FILM, anchorCurator);
        emit log_named_uint("anchor posted after ", postedAfter);
        emit log_named_uint("anchor loss         ", postedBefore - postedAfter);
        emit log_named_uint("cascade absorbed    ", crossingLoss);

        assertLe(
            postedBefore - postedAfter,
            crossingLoss + 1,
            "S4-R1: the round close destroyed curator claim beyond the loss the cascade absorbed"
        );
    }

    /// @notice THE PROPERTY: whatever the close leaves claimable must be REACHABLE. A claim that
    ///         no call can convert into USDfr is not a claim.
    function test_S4_R1_theResidualClaimMustBeWithdrawable() public {
        uint256 crossingLoss = _armCollapsedRatio();
        uint256 postedBefore = curator.postedOf(FILM, anchorCurator);
        _globalAbsorbAs(crossingLoss);
        _postFirstLoss(secondCurator, FILM, 1e18);
        assertEq(curator.poolRound(FILM), 1, "the round closed");

        uint256 expected = postedBefore - crossingLoss;
        (uint256 closedShares, uint256 carriedShares) = curator.closedRound(FILM, 0);
        assertGt(closedShares, carriedShares, "the closed denominator must retain the collapsed share ratio");
        assertEq(
            carriedShares,
            curator.poolBalance(FILM) - 1e18,
            "the snapshot must carry the pre-trigger capital that survived the loss"
        );
        // Headroom: FILM has no exposure in this fixture, so everything posted is free to leave.
        assertEq(curator.headroom(FILM), curator.poolBalance(FILM), "VACUITY: headroom must be open");

        uint256 balBefore = usdfr.balanceOf(anchorCurator);
        uint256 want = curator.postedOf(FILM, anchorCurator);
        emit log_named_uint("claimable after close", want);
        emit log_named_uint("survived the loss    ", expected);
        if (want != 0) {
            vm.prank(anchorCurator);
            curator.withdrawFirstLoss(FILM, want);
        }
        uint256 got = usdfr.balanceOf(anchorCurator) - balBefore;
        emit log_named_uint("actually withdrawn   ", got);
        assertApproxEqAbs(
            got, expected, 2, "S4-R1: the capital that survived the loss was not recoverable after the close"
        );
    }

    /// @notice THE PROPERTY the brief names explicitly: posting into a NEW round must not erase an
    ///         old residual claim. The fresh capital must ADD to the carried claim, never replace it.
    function test_S4_R1_postingIntoTheNewRoundMustNotEraseTheCarriedClaim() public {
        uint256 crossingLoss = _armCollapsedRatio();
        uint256 postedBefore = curator.postedOf(FILM, anchorCurator);
        _globalAbsorbAs(crossingLoss);
        // secondCurator closes the round; the anchor has still taken no action.
        _postFirstLoss(secondCurator, FILM, 1e18);
        assertEq(curator.poolRound(FILM), 1, "the round closed");

        uint256 carried = postedBefore - crossingLoss;
        // NOW the anchor posts fresh capital into the new round.
        _postFirstLoss(anchorCurator, FILM, 100e18);

        assertApproxEqAbs(
            curator.postedOf(FILM, anchorCurator),
            carried + 100e18,
            2,
            "S4-R1: posting into the new round erased the carried closed-round claim"
        );
    }

    /// @notice THE PROPERTY: several curators crossing the same close divide the residual exactly
    ///         pro-rata, and their claims can never sum to more than the pool holds. This is what
    ///         pins the remaining/remaining decrement in `_settleStaleRound` — without it the first
    ///         settler's ratio would be reused by the second and the two would over-claim.
    function test_S4_R1_severalCuratorsDivideTheResidualProRataAndNeverOverClaim() public {
        // 3:1 between the anchor and the second curator, then arm the collapsed ratio.
        _postFirstLoss(anchorCurator, FILM, 750e18);
        _postFirstLoss(secondCurator, FILM, 250e18);
        uint256 threshold = curator.poolShares(FILM) / 1e18;
        _globalAbsorbAs(curator.poolBalance(FILM) - (threshold + 1));
        _postFirstLoss(anchorCurator, FILM, 750e18);
        _postFirstLoss(secondCurator, FILM, 250e18);

        uint256 anchorBefore = curator.postedOf(FILM, anchorCurator);
        uint256 secondBefore = curator.postedOf(FILM, secondCurator);
        assertGt(anchorBefore, 0, "VACUITY: the anchor must hold a real claim before the close");
        assertGt(secondBefore, 0, "VACUITY: the second curator must hold a real claim before the close");

        uint256 balance = curator.poolBalance(FILM);
        uint256 loss = balance - curator.poolShares(FILM) / 1e18;
        _globalAbsorbAs(loss);
        uint256 residual = curator.poolBalance(FILM);

        // A third party's post closes the round; both curators settle permissionlessly.
        _postFirstLoss(secondCurator, FILM, 1e18);
        assertEq(curator.poolRound(FILM), 1, "the round closed");
        curator.claimClosedRound(FILM, anchorCurator);

        uint256 anchorAfter = curator.postedOf(FILM, anchorCurator);
        uint256 secondAfter = curator.postedOf(FILM, secondCurator);
        emit log_named_uint("anchor after", anchorAfter);
        emit log_named_uint("second after", secondAfter);

        // The second curator's `after` includes their fresh 1e18, which the anchor did not post.
        assertApproxEqAbs(
            anchorAfter * 1e18 / (secondAfter - 1e18),
            3e18,
            1e12,
            "S4-R1: the residual was not divided 3:1 across the close"
        );
        assertLe(
            anchorAfter + secondAfter,
            curator.poolBalance(FILM),
            "S4-R1: settled claims sum to more than the pool holds"
        );
        assertApproxEqAbs(anchorAfter + secondAfter, residual + 1e18, 4, "S4-R1: the residual was not fully attributed");
    }

    /// @notice THE PROPERTY that made the closed-round claim a SNAPSHOT rather than a set-aside
    ///         reserve: the residual is curator capital and must keep absorbing as cascade LAYER 1
    ///         (CLAUDE.md §1.3) after the close. A claim reserve would have stopped it, pushing the
    ///         next loss of that size onto the sGROVE backstop and depositor principal.
    function test_S4_R1_theCarriedResidualKeepsAbsorbingAsLayerOne() public {
        uint256 crossingLoss = _armCollapsedRatio();
        _globalAbsorbAs(crossingLoss);
        uint256 balanceBeforeClose = curator.poolBalance(FILM);
        _postFirstLoss(secondCurator, FILM, 1e18);
        assertEq(curator.poolRound(FILM), 1, "the round closed");

        // THE CLOSE MOVED NO MONEY. `poolBalance` is what `pendingSeniorImpairment` reads as
        // layer-1 credit; if the close had swept the residual into a reserve this would have fallen.
        assertEq(
            curator.poolBalance(FILM),
            balanceBeforeClose + 1e18,
            "S4-R1: the close removed capital from cascade layer 1"
        );

        // And the carried residual really does absorb: layer 1 covers the next loss in full.
        vm.prank(address(defaultManager));
        (uint256 absorbed, uint256 residualLoss) = curator.absorbLoss(FILM, balanceBeforeClose);
        assertEq(absorbed, balanceBeforeClose, "S4-R1: the carried residual did not absorb");
        assertEq(residualLoss, 0, "S4-R1: a loss escaped layer 1 that layer 1 could cover");
    }

    /// @dev One further CLOSE of the FILM round that leaves a LARGE residual behind: arm the ratio
    ///      just above the threshold, recapitalise (which inflates `totalShares`), cross the
    ///      threshold with a small loss, then let a third party's post perform the close. The
    ///      victim (`anchorCurator`) never touches its stake.
    function _closeOnceKeepingResidual() internal {
        uint256 threshold = curator.poolShares(FILM) / 1e18;
        _globalAbsorbAs(curator.poolBalance(FILM) - (threshold + 1));
        _postFirstLoss(secondCurator, FILM, 1_000e18);
        _globalAbsorbAs(curator.poolBalance(FILM) - curator.poolShares(FILM) / 1e18);
        _postFirstLoss(secondCurator, FILM, 1e18);
    }

    /// @notice THE PROPERTY: a stake behind SEVERAL closes is walked forward in ONE call — the
    ///         chain is invisible to the curator — and the value it carries survives the walk.
    ///         A single-hop settle strands such a stake and reds
    ///         `test_S3_F1_layerOneMustStillBeReFundableAfterNearTotalExitDraws`; this pins the walk.
    function test_S4_R1_aStakeBehindSeveralClosesIsWalkedForwardInOneCall() public {
        _armCollapsedRatio();
        _globalAbsorbAs(curator.poolBalance(FILM) - curator.poolShares(FILM) / 1e18);
        _postFirstLoss(secondCurator, FILM, 1e18); // close 1
        _closeOnceKeepingResidual(); // close 2
        _closeOnceKeepingResidual(); // close 3
        assertEq(curator.poolRound(FILM), 3, "VACUITY: three closes must actually have happened");

        uint256 expected = curator.postedOf(FILM, anchorCurator);
        assertGt(expected, 0, "VACUITY: the anchor must still carry a live claim across three closes");
        emit log_named_uint("anchor claim across 3 closes", expected);

        // ONE call, three hops. Nothing was refused and nothing was erased.
        curator.claimClosedRound(FILM, anchorCurator);
        assertEq(curator.postedOf(FILM, anchorCurator), expected, "S4-R1: the walk changed the claim's value");

        // And the post now ADDS to it rather than replacing it.
        _postFirstLoss(anchorCurator, FILM, 10e18);
        assertApproxEqAbs(
            curator.postedOf(FILM, anchorCurator),
            expected + 10e18,
            2,
            "S4-R1: posting after the walk erased the carried claim"
        );
    }

    /// @notice EXPLORATORY (logged, not asserted beyond liveness). How far a LIVE claim can actually
    ///         travel, which is what says whether `MAX_CLOSED_ROUND_HOPS` can ever bind. Each close
    ///         requires a recapitalisation, and that recapitalisation dilutes the sleeping curator,
    ///         so the claim floors to zero long before the hop bound — after which the stake
    ///         short-circuits straight to the live round and no chain is walked at all.
    function test_S4_R1_probe_howFarALiveClaimTravels() public {
        _armCollapsedRatio();
        _globalAbsorbAs(curator.poolBalance(FILM) - curator.poolShares(FILM) / 1e18);
        _postFirstLoss(secondCurator, FILM, 1e18); // close 1
        uint256 lastLive;
        for (uint256 i = 2; i <= 12; ++i) {
            _closeOnceKeepingResidual();
            uint256 claim = curator.postedOf(FILM, anchorCurator);
            emit log_named_uint("closes", curator.poolRound(FILM));
            emit log_named_uint("  anchor claim", claim);
            if (claim != 0) lastLive = curator.poolRound(FILM);
        }
        emit log_named_uint("LAST ROUND AT WHICH THE CLAIM WAS STILL LIVE", lastLive);

        // THE LIVENESS PROPERTY REGARDLESS: layer 1 stays re-fundable in ONE transaction for every
        // curator, however many closes they slept through.
        _postFirstLoss(anchorCurator, FILM, 10e18);
        _postFirstLoss(secondCurator, FILM, 10e18);
        assertGt(curator.poolBalance(FILM), 0, "S4-R1: layer 1 could not be re-funded after a long chain");
    }

    /// @notice THE PROPERTY: the hop bound REFUSES, it never erases — and it is REACHABLE, so this
    ///         is a live guard rather than decoration. Measured by
    ///         `test_S4_R1_probe_howFarALiveClaimTravels`: a sleeping curator's claim settles at one
    ///         wei and stays there indefinitely, so a chain longer than `MAX_CLOSED_ROUND_HOPS`
    ///         genuinely carries value and must not be thrown away.
    function test_S4_R1_theHopBoundRefusesAndThePermissionlessWalkRecovers() public {
        _armCollapsedRatio();
        _globalAbsorbAs(curator.poolBalance(FILM) - curator.poolShares(FILM) / 1e18);
        _postFirstLoss(secondCurator, FILM, 1e18); // close 1
        for (uint256 i = 2; i <= 33; ++i) {
            _closeOnceKeepingResidual();
        }
        assertEq(curator.poolRound(FILM), 33, "VACUITY: 33 closes (> MAX_CLOSED_ROUND_HOPS) must have happened");

        // Beyond the bound `postedOf` cannot value the stake without walking it, and says so by
        // reporting zero rather than by guessing.
        assertEq(curator.postedOf(FILM, anchorCurator), 0, "beyond the hop bound postedOf reports nothing");

        // Posting must REFUSE — loudly, naming where the stake actually sits.
        _mintUSDfrTo(anchorCurator, 10e18);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), 10e18);
        vm.expectRevert(abi.encodeWithSignature("Curator_UnsettledClosedRound(uint256,uint256,uint256)", FILM, 0, 33));
        curator.postFirstLoss(FILM, 10e18);
        vm.stopPrank();

        // The permissionless walk recovers it: 32 hops, then the last one. Called by a stranger.
        curator.claimClosedRound(FILM, anchorCurator);
        curator.claimClosedRound(FILM, anchorCurator);
        uint256 recovered = curator.postedOf(FILM, anchorCurator);
        emit log_named_uint("recovered after the walk", recovered);
        assertGt(recovered, 0, "S4-R1: the refusal was followed by an erasure; the claim did not survive");

        // And the post the guard refused now succeeds, ADDING to the recovered claim.
        vm.startPrank(anchorCurator);
        curator.postFirstLoss(FILM, 10e18);
        vm.stopPrank();
        assertApproxEqAbs(
            curator.postedOf(FILM, anchorCurator),
            recovered + 10e18,
            2,
            "S4-R1: the post erased the claim it had been refused for"
        );
    }

    /// @notice CLEAN NEGATIVE (expected GREEN on the shipped tree). The exact-wipe case is
    ///         unchanged: when the cascade takes EVERYTHING there is nothing left to claim, and
    ///         the round must still advance and layer 1 must still be re-fundable.
    function test_S4_N1_control_anExactWipeLeavesNothingToClaimAndStillReFunds() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        _globalAbsorbAs(1_000e18);
        assertEq(curator.poolBalance(FILM), 0, "the cascade took everything");
        _postFirstLoss(secondCurator, FILM, 500e18);
        assertEq(curator.poolRound(FILM), 1, "the round advanced");
        assertEq(curator.poolShares(FILM), 500e18, "the new round is 1:1");
        assertEq(curator.postedOf(FILM, anchorCurator), 0, "a fully wiped stake claims nothing");
        assertEq(curator.postedOf(FILM, secondCurator), 500e18, "the fresh capital is fully attributed");
    }
}
