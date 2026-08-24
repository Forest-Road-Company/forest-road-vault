// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {stdError} from "forge-std/StdError.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Cantina informational #1: `_quoteRedeem` computes `usdfrIn + drawn` before any balance
///         check, so a max-sized input with a live junior draw panics instead of returning a
///         controller error. Mirrors the ADR-0034 Y fixture so the draw is genuinely live.
contract PoC_CantinaI1_OversizedRedeemPanics is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant ALICE_IN = 1_000_000e18;
    uint256 internal constant BOB_IN = 1_000_000e18;
    uint256 internal constant FIRST_LOSS = 200_000e18;
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant MARK = 100_000e18;

    uint256 internal facility;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _mintUSDfrTo(alice, ALICE_IN);
        _mintUSDfrTo(bob, BOB_IN);
        _postFirstLoss(anchorCurator, FILM, FIRST_LOSS);
        facility = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        _fundFacility(facility, PRINCIPAL);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(facility, MARK, keccak256("conservative-mark"));
    }

    /// @notice CONTROL. The state is genuinely under-backed and the draw is live, so the finding
    ///         is about a reachable path rather than a hypothetical one.
    function test_control_theStateIsUnderBackedAndAnOrdinaryExitSettles() public {
        assertLt(controller.backingValue(), controller.totalUSDfr(), "under-backed");
        vm.prank(alice);
        assertGt(controller.redeem(100_000e18, 0), 0, "an ordinary exit settles");
    }

    /// @notice THE FINDING. A max-sized input panics on the unchecked `usdfrIn + drawn`.
    function test_maxSizedInputPanicsInsteadOfReturningAControllerError() public {
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError); // Panic(0x11)
        controller.redeem(type(uint256).max, 0);
    }

    /// @notice CONTRAST. An oversized but non-overflowing request reverts cleanly on the burn,
    ///         which is the answer a caller should get in both cases.
    function test_anOversizedButNonOverflowingRequestRevertsCleanly() public {
        uint256 held = usdfr.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        controller.redeem(held + 1e18, 0);
    }

    /// @notice THE PROPOSED BOUND. `usdfrIn <= totalSupply` is true for every legitimate
    ///         redemption and is strictly cheaper than a balance read, since the controller
    ///         already holds `supplyBefore`.
    function test_theSupplyBoundWouldHaveCaughtItWithoutABalanceRead() public view {
        uint256 supply = controller.totalUSDfr();
        assertLt(supply, type(uint256).max / 2, "supply is nowhere near the overflow boundary");
        assertGe(supply, usdfr.balanceOf(alice), "no holder can exceed total supply");
    }
}
