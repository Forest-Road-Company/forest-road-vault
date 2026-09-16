// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";

/// @dev A hostile participation-points module. `USDfr._update` invokes `onUSDfrTransfer`
///      inside every mint/burn (the deliberately fail-open points hook, ADR-0016), so a module
///      the attacker controls is the ONLY attacker-influenceable callback on the mint path:
///      canonical USDC has no transfer callback, and the ReserveManager is `nonReentrant`.
///      On each hook it re-enters `MintRedeemController.mint` and `.redeem` to try to inflate
///      supply while the outer mint holds the reentrancy lock. It swallows the inner revert so
///      the outer token `try/catch` stays fail-open; the flags below record whether any
///      re-entrant call actually got through.
contract HostileBackingPointsModule {
    IMintRedeemController private immutable controller;
    bool public callAttempted;
    bool public reentrancySucceeded;

    constructor(address controller_) {
        controller = IMintRedeemController(controller_);
    }

    function onUSDfrTransfer(address, address, uint256) external {
        callAttempted = true;
        // Both entry points are `nonReentrant`; while the outer mint holds the lock these must
        // revert. If either returned, supply was expanded re-entrantly and the flag latches.
        try controller.mint(1) returns (uint256) {
            reentrancySucceeded = true;
        } catch {}
        try controller.redeem(1) returns (uint256) {
            reentrancySucceeded = true;
        } catch {}
    }

    // USDfr only ever calls `onUSDfrTransfer`; a fallback keeps any unexpected selector harmless.
    fallback() external {}
}

/// @title EXP1_BackingForkTest
/// @notice ADVERSARIAL, AUTHORISED, LOCAL-FORK ONLY. Attempts to break the protocol's headline
///         safety invariant: `USDfr.totalSupply() <= backingValue()` at conservative marks
///         (ADR-0012, CLAUDE.md 1.3). Every route below tries to expand supply past backing, or
///         to extract par cash out of a hole, and asserts the exact outcome: the specific custom
///         error when the protocol blocks it, or the violated state if it does not.
///
///         Substrate: `ForkLifecycleFixture` deploys the FULL protocol onto a pinned mainnet fork
///         with REAL USDC. No broadcast, no mainnet, no real value (CLAUDE.md prime directive 1):
///         `forge test` never broadcasts, the fork is local and ephemeral, and `Deploy.run()`
///         (which carries the chain-id-1 hard revert) is never called - only the internal phases.
contract EXP1_BackingForkTest is ForkLifecycleFixture {
    uint256 private constant SCALE = 1e12; // 6-dec USDC -> 18-dec USDfr

    // ---------------------------------------------------------------------
    // ROUTE 1 - mint against a manipulated/stale mark: a governance impairment
    //           pulls recorded backing BELOW supply with custody perfectly
    //           intact. The protocol must refuse to sell a fresh 1:1 claim into
    //           the hole (that would be R4-01 restated on the valuation axis).
    // ---------------------------------------------------------------------
    function test_route1_MintClosedWhileUnderBacked_afterImpairment() external onFork {
        // Seed idle liquidity, then originate+fund a real FILM facility so there is deployed
        // principal to mark down. `_originateAndFund` drives the real 2-of-n oracle gate.
        _mintFromUSDC(alice, 3_000_000e6);
        uint256 tokenId = _originateAndFund(1_000_000e18);

        uint256 supplyPre = controller.totalUSDfr();
        uint256 backingPre = controller.backingValue();
        assertTrue(controller.backingInvariantHolds(), "should start whole");

        // Governance recognises a large conservative impairment on the deployed principal. This
        // LOWERS recorded backing with custody perfectly intact (no USDC moves).
        uint256 impair = 500_000e18;
        reserves.recognizePrincipalImpairment(tokenId, impair, keccak256("EXP1-stale-mark"));

        // The book is now genuinely short: supply exceeds backing by exactly the mark.
        assertEq(controller.totalUSDfr(), supplyPre, "supply is unchanged by a valuation mark");
        assertEq(controller.backingValue(), backingPre - impair, "backing fell by the mark");
        assertGt(controller.totalUSDfr(), controller.backingValue(), "protocol is under-backed");
        assertFalse(controller.backingInvariantHolds(), "invariant view reports short");

        // THE ATTACK: mint fresh USDfr into the hole (would dilute holders and expand supply
        // while backing cannot catch up). Must be refused up front.
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector,
                controller.totalUSDfr(),
                controller.backingValue()
            )
        );
        controller.mint(1_000e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // ROUTE 2 - re-enter the mint path through the fail-open points hook, the
    //           only attacker-influenceable callback on the mint path. Try to
    //           expand supply re-entrantly while the outer mint is mid-flight.
    // ---------------------------------------------------------------------
    function test_route2_MintReentrancyViaHostilePointsModuleIsContained() external onFork {
        HostileBackingPointsModule hostile = new HostileBackingPointsModule(address(controller));
        // Install the hostile module (USDfr DEFAULT_ADMIN is retained by the harness pre-handover).
        usdfr.setPointsModule(address(hostile));

        uint256 supplyPre = controller.totalUSDfr();
        uint256 backingPre = controller.backingValue();

        // Mint fires USDfr._update -> hostile.onUSDfrTransfer, which re-enters mint & redeem.
        uint256 minted = _mintFromUSDC(alice, 1_000e6);
        assertEq(minted, 1_000e6 * SCALE, "mint credited 1:1");

        // The hook ran, but neither re-entrant call got through the reentrancy guard.
        assertTrue(hostile.callAttempted(), "hook must have executed");
        assertFalse(hostile.reentrancySucceeded(), "reentrancy must be blocked");

        // Supply expanded by exactly the backing delivered; the invariant holds to the wei.
        assertEq(controller.totalUSDfr(), supplyPre + minted, "supply grew by minted only");
        assertEq(controller.backingValue(), backingPre + minted, "backing grew by minted only");
        assertTrue(controller.backingInvariantHolds(), "invariant intact after reentrancy attempt");
    }

    // ---------------------------------------------------------------------
    // ROUTE 3 - exploit rounding in the 6<->18 decimal mint/redeem conversion
    //           to manufacture a wei of unbacked supply or over-pay a redeem.
    // ---------------------------------------------------------------------
    function test_route3_MintRedeemRoundingCannotOutrunBacking() external onFork {
        // Odd, non-round deposit so any asymmetric rounding would surface.
        uint256 depositUSDC = 1_000_001e6;
        uint256 minted = _mintFromUSDC(alice, depositUSDC);
        assertEq(minted, depositUSDC * SCALE, "mint is exact x1e12, no rounding slack");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "supply within backing after mint");
        assertTrue(controller.backingInvariantHolds(), "whole after mint");

        // Round-trip: redeeming can never return MORE than was deposited (redeem floors down),
        // and the pool stays whole afterwards.
        vm.prank(alice);
        uint256 got = controller.redeem(minted);
        assertLe(got, depositUSDC, "redeem never over-pays the deposit");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "supply within backing after redeem");

        // Sub-unit dust cannot be redeemed for rounded-up cash: it reverts rather than paying out
        // unbacked value (rounding up would create backing-free cash - R16-L3).
        _mintFromUSDC(bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_AmountTooSmall.selector, uint256(1e6)));
        controller.redeem(1e6); // worth less than one whole USDC unit
    }

    // ---------------------------------------------------------------------
    // ROUTE 4 - mint during a paused / emergency state. Supply EXPANSION must
    //           never be available while either the token or the controller is
    //           paused (a pause must never be a one-way valve).
    // ---------------------------------------------------------------------
    function test_route4_MintBlockedWhileTokenOrControllerPaused() external onFork {
        _mintFromUSDC(alice, 1_000e6); // works while live
        uint256 supplyPre = controller.totalUSDfr();

        // (a) USDfr token pause: the mint's final `usdfr.mint` reverts inside `_update` - a
        //     mint's `from == address(0)` can never qualify for the protocol-leg carve-out.
        usdfr.pause();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.mint(1_000e6);
        vm.stopPrank();
        usdfr.unpause();

        // (b) Controller pause: refused by `whenNotPaused` before any state moves.
        controller.pause();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.mint(1_000e6);
        vm.stopPrank();
        controller.unpause();

        assertEq(controller.totalUSDfr(), supplyPre, "no supply expanded under either pause");
        assertTrue(controller.backingInvariantHolds(), "invariant intact");
    }

    // ---------------------------------------------------------------------
    // ROUTE 5 - mint while the reserve is short of physical custody: its live
    //           USDC balance is below its recorded idle ledger. Selling a new
    //           par claim out of a reserve KNOWN to be short is R4-01.
    // ---------------------------------------------------------------------
    function test_route5_MintBlockedWhileReserveCustodyShort() external onFork {
        _mintFromUSDC(alice, 1_000_000e6);

        // Simulate a custody loss: physically remove USDC from the reserve WITHOUT touching its
        // idle ledger, so `idleCustodyShortfall()` becomes non-zero. Fork-local balance write;
        // no value leaves the test. Sizing off the RECORDED idle ledger guarantees a shortfall
        // regardless of any seeded slack.
        uint256 recorded = reserves.idleUSDC(); // 6-dec recorded idle units
        uint256 hole = 100_000e6;
        assertGt(recorded, hole, "precondition: recorded idle exceeds the hole to open");
        deal(USDC, address(reserves), recorded - hole);

        assertGt(reserves.idleCustodyShortfall(), 0, "custody shortfall is now visible");

        // THE ATTACK: mint at par out of the short reserve. Must be refused up front.
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector,
                reserves.idleCustodyShortfall(),
                reserves.recognizedBackingValue()
            )
        );
        controller.mint(1_000e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // ROUTE 6 - the origination-fee (OID) capitalisation path. `fund` raises
    //           recorded backing by the capitalised fee, then mints that fee to
    //           the fee recipient: a candidate for supply expanding past
    //           backing. Confirm it stays coverage-neutral (supply <= backing).
    // ---------------------------------------------------------------------
    function test_route6_OriginationFeeOIDKeepsBackingInvariant() external onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        uint256 supplyPre = controller.totalUSDfr();
        uint256 backingPre = controller.backingValue();
        assertEq(supplyPre, backingPre, "balanced after 1:1 mints");

        // The origination fee is capitalised into the receivable face and minted to the fee
        // recipient (clamped to headroom - the healthy path mints the full fee).
        _originateAndFund(1_000_000e18);

        assertLe(controller.totalUSDfr(), controller.backingValue(), "OID fee mint did not outrun backing");
        assertTrue(controller.backingInvariantHolds(), "invariant intact after funding");
        // Every wei of supply created is fully covered: the fee-recipient mint is matched by the
        // capitalised receivable face, so backing grew by at least as much as supply.
        uint256 supplyGrowth = controller.totalUSDfr() - supplyPre;
        uint256 backingGrowth = controller.backingValue() - backingPre;
        assertGe(backingGrowth, supplyGrowth, "backing growth >= supply growth (coverage-neutral OID)");
    }

    // ---------------------------------------------------------------------
    // ROUTE 7 - try to extract PAR cash out of an under-backed book. After a
    //           recognised impairment (supply > backing, custody intact), the
    //           exit must be quoted STRICTLY sub-par: a first mover cannot
    //           convert their claim to 100% cash and dump the hole on the
    //           holders who stayed. This is the redemption side of the invariant.
    // ---------------------------------------------------------------------
    function test_route7_NoParExtractionOutOfAnUnderBackedBook() external onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        uint256 tokenId = _originateAndFund(1_000_000e18);

        // Pull recorded backing below supply with custody intact.
        reserves.recognizePrincipalImpairment(tokenId, 500_000e18, keccak256("EXP1-run-mark"));
        assertGt(controller.totalUSDfr(), controller.backingValue(), "precondition: under-backed");
        assertEq(reserves.idleCustodyShortfall(), 0, "custody is intact, only the mark moved");

        // THE ATTACK, priced: ask the protocol what a 100,000 USDfr exit is worth right now.
        uint256 exit = 100_000e18;
        (uint256 previewOut, uint256 previewIn) = controller.previewRedeem(exit);
        assertEq(previewIn, exit, "the whole whole-unit position would burn");
        assertGt(previewOut, 0, "something is payable");
        // Strictly sub-par: the quoted cash is worth LESS than the USDfr burned. Par extraction
        // out of the hole is refused - the redeemer is offered the honest coverage ratio only.
        assertLt(previewOut * SCALE, previewIn, "exit is quoted strictly below par, no par drain");
    }
}
