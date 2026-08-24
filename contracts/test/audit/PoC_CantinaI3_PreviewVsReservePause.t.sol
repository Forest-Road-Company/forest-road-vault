// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @notice Cantina informational #3, claim 1: `previewRedeem` does not consult the
///         ReserveManager pause, so it can quote a price no redemption can settle.
contract PoC_CantinaI3_PreviewVsReservePause is TokenLayerFixture {
    function test_previewQuotesAFullPriceWhileTheReservePauseBlocksEveryRedemption() public {
        _mintUSDfr(alice, 100e6);

        (uint256 before,) = controller.previewRedeem(100e18);
        assertEq(before, 100e6, "baseline: par");

        vm.prank(guardian);
        reserves.pause();

        // The view is unmoved.
        (uint256 quoted,) = controller.previewRedeem(100e18);
        assertEq(quoted, 100e6, "previewRedeem still publishes the full price");

        // Every redemption reverts.
        vm.prank(alice);
        vm.expectRevert();
        controller.redeem(100e18, 0);
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
