// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev SWEEP-3 S3-F1 (MEDIUM) — the near-total-absorption share-ratio collapse, INVERTED.
///
///      ══════════════════ THESE TWO TESTS WERE SEVERITY CALIBRATION FOR A LIVE DEFECT ══════════
///      As written by the adversary they both OPENED with
///          `assertTrue(_postReverts(), "precondition: layer 1 is bricked")`
///      and then measured how long the brick lasted. The brick was real: three near-total
///      absorptions with ordinary recapitalisation in between drove the share/balance ratio past
///      1e42 and `postFirstLoss` reverted on `Math.mulDiv` overflow for EVERY curator, while
///      `postedOf` floored to zero for every holder of less than the whole share supply — so
///      nobody could withdraw the surviving wei that kept the round from advancing.
///
///      THEY ARE NOW INVERTED, NOT WEAKENED. The precondition is asserted in the OPPOSITE
///      direction — layer 1 must NEVER be bricked — and the two calibration facts they
///      established (only a later full draw cured it; governance had no lever) are retained as
///      the reasons the fix had to be structural rather than operational. If a regression
///      re-opens the collapse these go red on the very first assertion.
///      See `CuratorModule._advanceRoundIfWiped` and the block in `postFirstLoss`.
contract SweepR3_Recovery is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev The exact sequence that used to brick the class: three absorptions each ONE WEI short
    ///      of the whole pool, with a full recapitalisation between them.
    function _threeNearTotalAbsorptions() internal {
        _postFirstLoss(anchorCurator, FILM, 900e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        for (uint256 i = 0; i < 3; ++i) {
            uint256 bal = curator.poolBalance(FILM);
            vm.prank(address(defaultManager));
            curator.absorbGlobalLoss(bal - 1);
            if (i < 2) _postFirstLoss(anchorCurator, FILM, 1_000e18);
        }
    }

    function _postReverts() internal returns (bool reverted) {
        _mintUSDfrTo(anchorCurator, 1_000e18);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), 1_000e18);
        try curator.postFirstLoss(FILM, 1_000e18) {
            reverted = false;
        } catch {
            reverted = true;
        }
        vm.stopPrank();
    }

    /// @notice INVERTED (SWEEP-3 S3-F1). Layer 1 stays fundable through the sequence that used to
    ///         brick it, and it does NOT need a later full draw to rescue it.
    /// @dev MUTATION: in `CuratorModule._advanceRoundIfWiped`, replace the predicate with
    ///      `if (shares == 0 || pool.balance > shares / (MAX_SHARE_INFLATION / MAX_SHARE_INFLATION))`
    ///      (compiles; both operands still read; reduces to the pre-fix `balance == 0`) -> RED here.
    function test_S3_F1_layerOneStaysFundableThroughNearTotalAbsorptions() public {
        _threeNearTotalAbsorptions();
        assertFalse(_postReverts(), "S3-F1: layer 1 must never be bricked by a near-total absorption");
        // The ratio is normalised in STORAGE, not merely survivable at the next post.
        assertLe(
            curator.poolShares(FILM),
            curator.poolBalance(FILM) * 1e18,
            "S3-F1: the share/balance ratio must never stand above 1e18"
        );
    }

    /// @notice RETAINED CALIBRATION, INVERTED PRECONDITION. A full draw still advances the round
    ///         and recapitalisation still works — the exact-wipe behaviour is unchanged by the fix.
    function test_S3_F1_calib_aFullDrawStillAdvancesTheRoundAndLayerOneStaysFundable() public {
        _threeNearTotalAbsorptions();
        assertFalse(_postReverts(), "precondition INVERTED: layer 1 is NOT bricked after the fix");
        uint256 roundBefore = curator.poolRound(FILM);
        uint256 dust = curator.poolBalance(FILM);
        vm.prank(address(defaultManager));
        curator.absorbGlobalLoss(dust);
        assertEq(curator.poolBalance(FILM), 0, "the dust is gone");
        assertFalse(_postReverts(), "a full draw leaves layer 1 fundable");
        assertGt(curator.poolRound(FILM), roundBefore, "a full wipe still advances the round");
    }

    /// @notice RETAINED CALIBRATION, INVERTED PRECONDITION. This is WHY the fix had to be in the
    ///         contract: timelocked governance has no lever on this module that touches
    ///         `pools[classId]`, so an operational runbook could never have cleared the brick.
    function test_S3_F1_calib_governanceStillHasNoLeverOnThePoolAndNoLongerNeedsOne() public {
        _threeNearTotalAbsorptions();
        assertFalse(_postReverts(), "precondition INVERTED: layer 1 is NOT bricked after the fix");
        uint256 balanceBefore = curator.poolBalance(FILM);
        uint256 sharesBefore = curator.poolShares(FILM);
        // Everything timelocked governance can reach on this module: targets, approvals, pause,
        // the points hook, the reserve/governor wiring. None of them touches `pools[classId]`.
        vm.startPrank(admin);
        curator.setFirstLossTarget(FILM, 0);
        curator.setCuratorApproved(FILM, admin, true);
        vm.stopPrank();
        assertEq(curator.poolBalance(FILM), balanceBefore, "governance still cannot move the pool balance");
        assertEq(curator.poolShares(FILM), sharesBefore, "governance still cannot move the pool shares");
    }
}
