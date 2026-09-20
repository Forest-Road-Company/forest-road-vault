// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
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

    /// @notice FIXED 2026-09-09. A max-sized input now returns a decodable controller error.
    /// @dev THIS TEST IS INVERTED FROM THE FINDING IT RECORDS. It used to assert
    ///      `stdError.arithmeticError`, i.e. the `Panic(0x11)` Cantina 3.1.1 reported, and passing
    ///      meant the defect was present. `_quoteRedeem` now bounds `usdfrIn` against
    ///      `supply - drawn` BEFORE the addition, which is the remedy ADR-0034 section W specified
    ///      and the form the BSC instance already carried. Bounding the SUM rather than the addend
    ///      makes the overflow unrepresentable rather than merely unlikely.
    function test_FIXED_maxSizedInputReturnsAControllerErrorNotAPanic() public {
        // The selector is the property. The arguments carry the GRID-ROUNDED input and
        // `supply - drawn` rather than the raw request and raw supply, which is correct and is
        // exactly why the bound is on the sum: pinning those two numbers here would pin the draw
        // sizing as well and red on any unrelated change to it.
        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_RedeemExceedsSupply.selector);
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
