// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @notice Cantina informational #3, claim 1: `previewRedeem` does not consult the
///         ReserveManager pause, so it can quote a price no redemption can settle.
contract PoC_CantinaI3_PreviewVsReservePause is TokenLayerFixture {
    /// @notice FIXED 2026-09-09. INVERTED FROM THE FINDING IT RECORDS.
    /// @dev This used to assert that the quote was UNMOVED by the reserve pause, and passing meant
    ///      Cantina 3.1.3 was present: `previewRedeem` read the controller and token pauses but not
    ///      the reserve's, so it published a settleable price for a redemption whose every release
    ///      is `whenNotPaused`. ADR-0034 section W deferred the fix to "the next controller
    ///      upgrade" and told integrators to read `ReserveManager.paused()` alongside the quote
    ///      meanwhile. This is that upgrade. The BSC instance already carried the fix, and the
    ///      Ethereum tree now uses the same `IPausableModule` pointer, which exists because
    ///      `ReserveManager` inherits `paused()` and never declares it on its own interface.
    function test_FIXED_previewGoesSilentWhileTheReservePauseBlocksEveryRedemption() public {
        _mintUSDfr(alice, 100e6);

        (uint256 before,) = controller.previewRedeem(100e18);
        assertEq(before, 100e6, "baseline: par");

        vm.prank(guardian);
        reserves.pause();

        // The view now agrees with the call it is quoting for.
        (uint256 quoted, uint256 burned) = controller.previewRedeem(100e18);
        assertEq(quoted, 0, "previewRedeem must not publish a price the reserve pause blocks");
        assertEq(burned, 0, "and must not claim any USDfr would burn");

        // Every redemption still reverts, which is what the quote now reflects.
        vm.prank(alice);
        vm.expectRevert();
        controller.redeem(100e18, 0);

        // And the quote returns once the pause lifts.
        vm.prank(guardian);
        reserves.unpause();
        (uint256 after_,) = controller.previewRedeem(100e18);
        assertEq(after_, 100e6, "the quote must come back when the reserve reopens");
    }

    /// @notice Claim 2, for contrast: the undrawn quote is a LOWER bound, so passing it back as
    ///         `minUsdcOut` cannot revert on slippage. It settles equal or better, never worse.
    function test_theUndrawnQuoteIsALowerBoundNotAnUnsettleablePrice() public {
        _mintUSDfr(alice, 100e6);
        (uint256 quoted,) = controller.previewRedeem(100e18);
        vm.prank(alice);
        uint256 got = controller.redeem(100e18, quoted); // quoted used as the floor
        assertGe(got, quoted, "settlement is never below the published quote");
    }
}
