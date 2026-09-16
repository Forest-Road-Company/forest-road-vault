// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";

/// @title ATK_MintRedeemControllerForkTest
/// @notice ADVERSARIAL suite against `MintRedeemController` on a pinned mainnet fork. Local only,
///         never broadcasts. Each function ATTEMPTS a real exploit of the permissionless entry
///         points (`mint`, the three `redeem` overloads) and asserts an UNAMBIGUOUS outcome: the
///         violated state if the attack lands, or the exact custom error if the contract blocks it.
///
///         The three invariants under attack (from the task brief):
///           (I1) USDfr supply never exceeds backing.
///           (I2) Mint is CLOSED while the protocol is under-backed.
///           (I3) Redeem cannot extract MORE than a caller's pro-rata share.
///
///         Reachable adversary states exercised here:
///           * PAR (healthy)               — supply == backing.
///           * GENUINELY UNDER-BACKED      — recorded backing < supply with custody intact,
///                                           produced by a governance conservative mark
///                                           (`recognizePrincipalImpairment`). This is the exact
///                                           R16-M3 state and the one that drives sub-par pricing.
///           * CUSTODY HOLE (R4-01)        — the reserve holds less USDC than its idle ledger
///                                           claims (simulated as an on-fork theft via `deal`).
contract ATK_MintRedeemControllerForkTest is ForkLifecycleFixture {
    // ─────────────────────────────────────────────────────────────────────
    // ATTACK GROUP A — MINT (permissionless entry point)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev I1: a par mint must be EXACTLY 1:1 — no share-inflation, no discount, no over-mint.
    ///      The controller has no ERC4626-style share math, so this pins that supply and recorded
    ///      backing move by the identical amount and the backing invariant holds afterward.
    function test_mint_isExactlyOneToOne_noOverMint() public onFork {
        uint256 supply0 = controller.totalUSDfr();
        uint256 backing0 = controller.backingValue();

        uint256 out = _mintFromUSDC(alice, 250_000e6);

        assertEq(out, 250_000e18, "mint must return exactly usdc*1e12");
        assertEq(controller.totalUSDfr(), supply0 + 250_000e18, "supply moved by exactly the mint");
        assertEq(controller.backingValue(), backing0 + 250_000e18, "backing moved by exactly the mint");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "I1 backing invariant holds");
    }

    /// @dev A zero mint must revert cleanly rather than mint nothing / no-op.
    function test_mint_zeroAmountReverts() public onFork {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        controller.mint(0);
        vm.stopPrank();
    }

    /// @dev Hostile actor: `carol` is NOT KYC'd. The KYC gate is the first check on the
    ///      permissionless mint and must refuse her before any value moves.
    function test_mint_nonKYCActorRejected() public onFork {
        vm.startPrank(carol);
        IERC20(USDC).approve(address(controller), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.mint(1000e6);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    // ATTACK GROUP B — REDEEM at PAR (permissionless entry points)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Hostile actor: a non-KYC caller cannot redeem either.
    function test_redeem_nonKYCActorRejected() public onFork {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.redeem(1000e18);
    }

    /// @dev A zero redeem must revert (not silently settle zero).
    function test_redeem_zeroAmountReverts() public onFork {
        vm.prank(alice);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        controller.redeem(0);
    }

    /// @dev I3 + ROUNDING/DUST: a par round-trip must conserve value to the wei, AND a sub-USDC-unit
    ///      of USDfr must NOT be peelable into free cash. Repeated dust redemptions are the classic
    ///      "farm the rounding" attack; here every sub-unit remainder is refused, so nothing
    ///      accumulates to the caller and the whole-unit round-trip returns exactly what was paid in.
    function test_redeem_parRoundTripConservesValue_andSubUnitDustUnfarmable() public onFork {
        uint256 aliceUsdc0 = IERC20(USDC).balanceOf(alice);

        uint256 out = _mintFromUSDC(alice, 1000e6);
        assertEq(out, 1000e18, "minted 1:1");

        // The rounding attack: try to peel a sub-USDC-unit of USDfr into cash. Refused as dust —
        // there is no fraction of a USDC unit to pay out, so the caller can never accumulate value.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_AmountTooSmall.selector, uint256(1e12 - 1))
        );
        controller.redeem(1e12 - 1);

        // The whole-unit round-trip is exactly 1:1: no value created, none destroyed.
        vm.prank(alice);
        uint256 usdcOut = controller.redeem(1000e18);
        assertEq(usdcOut, 1000e6, "par redeem pays exactly 1:1");
        assertEq(usdfr.balanceOf(alice), 0, "all USDfr burned");
        assertEq(IERC20(USDC).balanceOf(alice), aliceUsdc0, "net USDC unchanged: no value extracted");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "I1 still holds");
    }

    /// @dev I3: the two-argument form must refuse to pay ABOVE par. At par the honest price is
    ///      exactly `usdfr/1e12`; demanding one wei more is a slippage floor the caller can never
    ///      clear, so it reverts rather than overpaying out of the pool.
    function test_redeem_twoArg_cannotDemandAbovePar() public onFork {
        _mintFromUSDC(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 1000e6, 1000e6 + 1)
        );
        controller.redeem(1000e18, 1000e6 + 1);
    }

    /// @dev The canonical three-argument form must reject an already-expired deadline (ADR-0034 W),
    ///      closing the "hold the tx until the ratio moves" searcher option.
    function test_redeem_threeArg_expiredDeadlineReverts() public onFork {
        _mintFromUSDC(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_DeadlinePassed.selector, block.timestamp - 1, block.timestamp
            )
        );
        controller.redeem(1000e18, 0, block.timestamp - 1);
    }

    /// @dev CROSS-USER: redeem only ever burns `msg.sender`'s own balance. `bob` is KYC'd but holds
    ///      zero USDfr; he cannot reach `alice`'s position, so his redemption bottoms out on his own
    ///      insufficient balance rather than draining anyone else's cash.
    function test_redeem_crossUser_cannotBurnWithoutBalance() public onFork {
        _mintFromUSDC(alice, 1000e6); // protocol at par, non-empty
        assertEq(usdfr.balanceOf(bob), 0, "attacker starts with no USDfr");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, uint256(0), 1000e18)
        );
        controller.redeem(1000e18);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ATTACK GROUP C — DONATION / FIRST-DEPOSITOR
    // ─────────────────────────────────────────────────────────────────────

    /// @dev I1 + DONATION: pushing USDC straight into the reserve must NOT let anyone mint a claim
    ///      against un-booked cash, and must NOT inflate recorded backing. The donation lands as
    ///      `unrecordedUSDC` (a pure safety buffer) and the very next mint is still exactly 1:1.
    function test_donationToReserve_doesNotInflateClaims_mintStaysOneToOne() public onFork {
        uint256 supply0 = controller.totalUSDfr(); // small protocol-owned seed floor
        uint256 backing0 = controller.backingValue();

        // Attacker donates USDC directly to the reserve before minting.
        IERC20(USDC).transfer(address(reserves), 12_345e6);

        uint256 out = _mintFromUSDC(alice, 1000e6);

        assertEq(out, 1000e18, "donation grants no minting discount: still 1:1");
        assertEq(controller.totalUSDfr(), supply0 + 1000e18, "supply moved by exactly the honest mint");
        assertEq(controller.backingValue(), backing0 + 1000e18, "recorded backing EXCLUDES the donation");
        assertEq(reserves.unrecordedUSDC(), 12_345e6, "donation parked as an unrecorded buffer, not claimable");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "I1 holds; donation cannot be minted against");
    }

    // ─────────────────────────────────────────────────────────────────────
    // ATTACK GROUP D — GENUINELY UNDER-BACKED (custody intact)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev I2, THE HEADLINE INVARIANT: with recorded backing < supply (a governance conservative
    ///      mark, custody intact), the par mint window must be CLOSED. Selling a fresh 1:1 claim into
    ///      a short book hands the new minter a sub-par instrument at par (R4-01 / R16-M3).
    function test_underBacked_mintIsClosed() public onFork {
        _makeUnderBacked();
        assertGt(controller.totalUSDfr(), controller.backingValue(), "precondition: under-backed");

        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector,
                controller.totalUSDfr(),
                controller.backingValue()
            )
        );
        controller.mint(1e6);
        vm.stopPrank();
    }

    /// @dev I3, PAR-FLOOR: the ONE-argument redeem must never silently haircut. In the short book,
    ///      with no junior capital to draw forward, the honest price is below par, so the one-arg
    ///      form (which supplies the par floor) reverts rather than settling the caller short (R17).
    function test_underBacked_oneArgRedeemRefusesSilentHaircut() public onFork {
        _makeUnderBacked();

        vm.prank(alice);
        (uint256 quotedOut,) = controller.previewRedeem(100_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, quotedOut, 100_000e6)
        );
        controller.redeem(100_000e18);
    }

    /// @dev I3, THE CORE ANTI-THEFT PROPERTY: an EXPLICIT sub-par exit (two-arg, minUsdcOut=0) must
    ///      pay AT MOST the caller's pro-rata share, and must NOT worsen the coverage ratio for the
    ///      holders who stay. This is the attack "convert my part-impaired claim to 100% cash and
    ///      leave the rest holding the hole" — the arithmetic below proves the redeemer captures no
    ///      more than `usdfr * backing / supply`, floored, with every wei of rounding accruing to the
    ///      stayers. The crystallised haircut is recorded so a later mark-release cannot recycle it
    ///      as vault yield.
    function test_underBacked_subParRedeemPaysAtMostProRata() public onFork {
        _makeUnderBacked();

        uint256 R = 100_000e18; // whole-USDC-unit aligned, so usdfrIn == R
        uint256 supply0 = controller.totalUSDfr();
        uint256 backing0 = controller.backingValue();
        assertGt(supply0, backing0, "precondition: under-backed");

        uint256 shortfall0 = controller.seniorSubParShortfall();

        vm.prank(alice);
        uint256 usdcOut = controller.redeem(R, 0); // accept any price: the deliberate sub-par election

        // Exact pro-rata (no junior draw available, so drawn == 0): value = floor(R * backing/supply).
        uint256 expectedValueOut = R * backing0 / supply0;
        uint256 expectedUsdcOut = expectedValueOut / 1e12;
        assertEq(usdcOut, expectedUsdcOut, "settles at exactly the floored coverage ratio");

        // (a) redeemer captured AT MOST their pro-rata share.
        assertLe(usdcOut * 1e12, R * backing0 / supply0, "I3: cannot extract above pro-rata");

        // (b) coverage ratio for the holders who STAYED did not fall:
        //     (backing0 - paid) / (supply0 - R) >= backing0 / supply0, cross-multiplied.
        uint256 paidValue = usdcOut * 1e12;
        assertGe(
            (backing0 - paidValue) * supply0,
            backing0 * (supply0 - R),
            "I3: stayers' coverage ratio not worsened by the exit"
        );

        // (c) the crystallised haircut is retained, not leaked back out as yield.
        assertEq(
            controller.seniorSubParShortfall() - shortfall0, R - paidValue, "crystallised senior shortfall recorded"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // ATTACK GROUP E — CUSTODY HOLE (R4-01): fail CLOSED, not first-come-first-served
    // ─────────────────────────────────────────────────────────────────────

    /// @dev I1/I3, R4-01: if the reserve's live USDC falls below its idle ledger (a custody theft,
    ///      simulated here on the fork), BOTH par doors must slam shut. The attack this blocks is the
    ///      run: redeem 100 cents on the dollar, first-come-first-served, until the live balance is
    ///      gone. Mint and redeem both revert with the shortfall error, and `previewRedeem` reports
    ///      "nothing payable" instead of quoting a settleable-looking par price for a call that
    ///      cannot execute.
    function test_custodyHole_mintAndRedeemFailClosed_previewZero() public onFork {
        _mintFromUSDC(alice, 400_000e6); // reserve holds 400k USDC; idle ledger == 400k
        // Simulate the theft: live balance drops below the recorded idle ledger.
        deal(USDC, address(reserves), 300_000e6);
        // A ~100k USDC custody hole is now open (recorded idle > live balance). Exact size is
        // offset by the protocol-owned seed floor, so assert only that the hole exists.
        assertGt(reserves.idleCustodyShortfall(), 0, "custody hole opened (recorded idle exceeds live)");

        // Mint into the hole is refused.
        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector,
                reserves.idleCustodyShortfall(),
                reserves.recognizedBackingValue()
            )
        );
        controller.mint(1e6);
        vm.stopPrank();

        // First-come-first-served par redemption out of the hole is refused (no draining the run).
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector,
                reserves.idleCustodyShortfall(),
                reserves.recognizedBackingValue()
            )
        );
        controller.redeem(1000e18);

        // The permissionless quote surface tells the truth: nothing is payable.
        (uint256 quotedOut, uint256 quotedIn) = controller.previewRedeem(1000e18);
        assertEq(quotedOut, 0, "previewRedeem must not quote a settleable price over a custody hole");
        assertEq(quotedIn, 0, "previewRedeem returns (0,0) when redemption is closed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Shared setup: a genuinely under-backed book with custody intact.
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Mint 1,000,000 USDfr of backing, deploy 200,000 into a real FILM facility, then apply a
    ///      50,000e18 governance conservative mark. That lowers recorded backing WITHOUT burning any
    ///      USDfr and WITHOUT touching custody, so `supply > backing` while `idleCustodyShortfall()`
    ///      stays zero — the precise state the mint-closed and sub-par-redeem paths are built for.
    ///      The test contract is the deployer and holds DEFAULT_ADMIN_ROLE on the reserve, so the
    ///      mark is applied through the real governance function, not a shortcut.
    function _makeUnderBacked() internal returns (uint256 tokenId) {
        _mintFromUSDC(alice, 1_000_000e6);
        tokenId = _originateAndFund(200_000e18);
        reserves.recognizePrincipalImpairment(tokenId, 50_000e18, keccak256("atk-under-backed"));
    }
}
