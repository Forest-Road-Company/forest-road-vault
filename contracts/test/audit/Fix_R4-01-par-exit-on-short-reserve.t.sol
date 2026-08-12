// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @title AUDIT FIX (R4-01) — PAR REDEMPTION AGAINST A RESERVE THE CONTRACT KNOWS IS SHORT
/// @notice THE FINDING. `ReserveManager.observeIdleUSDC()` computes, for free and permissionlessly,
///         the exact gap between the idle ledger's CLAIM about custodied USDC and the USDC actually
///         held — and publishes it to anyone. Nothing consumed it. `totalBackingValue()` counted the
///         claim, `MintRedeemController.backingInvariantHolds()` therefore reported TRUE in the very
///         block in which `observeIdleUSDC()` reported a shortfall to the same caller, and
///         `redeem` went on paying 100 cents on the dollar, first-come-first-served, until the live
///         balance was exhausted — at which point the next redeemer received the token's raw
///         `ERC20InsufficientBalance`: a bare ERC-20 revert with no protocol meaning, undecodable by
///         the frontend and indistinguishable from a wallet-side mistake.
///
///         This is the same fail-open shape round 6 found in the C-01 redesign, reached from the
///         LEDGER rather than the cascade.
///
/// @dev THE FIX, and the seam with the C-01 reserve-loss workstream.
///      RECOGNITION is made honest, permissionless and immediate: `idleCustodyShortfall()` is a pure
///      derivation from `USDC.balanceOf(reserve)`, `recognizedBackingValue()` is backing net of it,
///      and `backingInvariantHolds()` is measured against that. ABSORPTION — who eats the loss,
///      the incident latch, the junior-to-senior cascade — is untouched and stays authenticated.
///      `totalBackingValue()` deliberately keeps the RECORDED-LEDGER basis because C-01's
///      `_allocateReserveLoss` derives `backingAfter` from it inside the same transaction; netting
///      the shortfall in there would subtract the same dollars twice. The two compatibility tests
///      at the bottom of this file are the anti-collision proof and must stay green.
///
///      RED-PHASE PROVENANCE: written before the fix and run against the unfixed build, where six
///      of these ten failed — including the raw-`ERC20InsufficientBalance` reproduction — while the
///      four compatibility/boundary tests passed unchanged.
contract Fix_R4_01_ParExitOnShortReserve is TokenLayerFixture {
    address internal sink = makeAddr("custody-sink");

    /// @dev Simulates a custody loss: USDC leaves the treasury with no ledger entry behind it.
    ///      Deliberately NOT a protocol path — the whole point is an out-of-band gap the ledger
    ///      does not know about but the balance does.
    function _drainCustody(uint256 units) internal {
        vm.prank(address(reserves));
        usdc.transfer(sink, units);
    }

    // ── 1. RECOGNITION ───────────────────────────────────────────────────

    function test_R4_01_backingInvariantMustNotReportTrueOnAReserveItCanSeeIsShort() public {
        _mintUSDfr(alice, 100e6);
        assertTrue(controller.backingInvariantHolds());
        assertEq(reserves.idleCustodyShortfall(), 0);
        assertEq(reserves.recognizedBackingValue(), 100e18);

        _drainCustody(25e6);

        (uint256 recorded, uint256 live, uint256 shortfall) = reserves.observeIdleUSDC();
        assertEq(recorded, 100e6);
        assertEq(live, 75e6);
        assertEq(shortfall, 25e6, "the contract publishes the exact gap");

        // The defect: these two numbers used to disagree with the line above.
        assertEq(reserves.idleCustodyShortfall(), 25e18, "the gap must be recognised in USD terms");
        assertEq(reserves.recognizedBackingValue(), 75e18, "backing must not count absent cash");
        assertEq(reserves.totalBackingValue(), 100e18, "the RECORDED basis is deliberately unchanged (C-01)");
        assertEq(
            controller.recognizedBackingValue(), 75e18, "the controller must surface the honest basis to the frontend"
        );
        assertFalse(controller.backingInvariantHolds(), "R4-01: par backing reported against absent cash");
    }

    /// @dev The identity that ties the two bases together, so neither can drift from the other.
    function testFuzz_R4_01_recognitionIdentityHolds(uint256 mintUnits, uint256 drainUnits) public {
        mintUnits = bound(mintUnits, 1, 1_000_000e6);
        drainUnits = bound(drainUnits, 0, mintUnits);
        _mintUSDfr(alice, mintUnits);
        if (drainUnits != 0) _drainCustody(drainUnits);

        (,, uint256 shortfallUnits) = reserves.observeIdleUSDC();
        assertEq(shortfallUnits, drainUnits);
        assertEq(reserves.idleCustodyShortfall(), drainUnits * 1e12);
        assertEq(
            reserves.recognizedBackingValue(),
            reserves.totalBackingValue() - reserves.idleCustodyShortfall(),
            "recognition identity"
        );
        // Recognised backing may never count USDC the contract is not holding.
        assertLe(
            reserves.recognizedBackingValue(),
            usdc.balanceOf(address(reserves)) * 1e12 + reserves.deployedPrincipal(),
            "recognised backing counted cash that is not there"
        );
    }

    // ── 2. THE EXIT ──────────────────────────────────────────────────────

    function test_R4_01_redeemMustNotPayParWhileTheReserveIsKnownShort() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdfrBefore = usdfr.balanceOf(alice);

        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 25e18, 75e18)
        );
        vm.prank(alice);
        controller.redeem(10e18);

        assertEq(usdc.balanceOf(alice), usdcBefore, "R4-01: paid par out of a known-short reserve");
        assertEq(usdfr.balanceOf(alice), usdfrBefore, "R4-01: burned supply on a failed exit");
    }

    function test_R4_01_mintMustNotSellNewClaimsIntoAKnownShortReserve() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        vm.startPrank(bob);
        usdc.approve(address(controller), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 25e18, 75e18)
        );
        controller.mint(10e6);
        vm.stopPrank();
    }

    // ── 3. THE LAST REDEEMER GETS A PROTOCOL ERROR, NOT A RAW TOKEN REVERT ─

    /// @dev The exhausted-reserve tail of the finding. Pre-fix this reverted
    ///      `ERC20InsufficientBalance(reserve, 0, 1e6)` straight out of the token.
    function test_R4_01_exhaustedReserveFailsWithAProtocolErrorNotERC20InsufficientBalance() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(100e6); // every last unit gone; the ledger still claims 100e6
        assertEq(usdc.balanceOf(address(reserves)), 0);
        assertEq(reserves.idleUSDC(), 100e6, "the ledger's claim is untouched, which is the point");

        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_IdleCustodyShortfall.selector, 100e6, 0));
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 1e6);

        // And nothing anywhere on the exit path may surface the bare token error.
        vm.prank(alice);
        try controller.redeem(1e18) {
            revert("R4-01: released cash the reserve does not hold");
        } catch (bytes memory err) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            assertTrue(
                sel != IERC20Errors.ERC20InsufficientBalance.selector,
                "R4-01: raw token revert instead of a protocol error"
            );
            assertEq(
                sel,
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector,
                "the exit must fail with the protocol's own error"
            );
        }
    }

    // ── 4. IT REOPENS ────────────────────────────────────────────────────

    function test_R4_01_restoringCustodyReopensParBusinessWithNoGovernanceAction() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);
        assertFalse(controller.backingInvariantHolds());

        // Anyone may make the treasury whole; recognition is permissionless in BOTH directions and
        // needs no role, no keeper and no incident. This is the compatibility contract with C-01's
        // "recognition becomes permissionless and immediate".
        usdc.mint(address(reserves), 25e6);

        assertEq(reserves.idleCustodyShortfall(), 0);
        assertTrue(controller.backingInvariantHolds(), "restored custody must reopen the protocol");
        vm.prank(alice);
        controller.redeem(10e18);
        assertEq(usdfr.balanceOf(alice), 90e18);
    }

    /// @dev A live surplus (an unsolicited donation) is NOT a shortfall and must not close
    ///      anything. It is also not backing — the pre-existing donation rule is untouched.
    function test_R4_01_aDonationSurplusDoesNotCloseTheProtocol() public {
        _mintUSDfr(alice, 100e6);
        usdc.mint(address(reserves), 40e6);

        (,, uint256 shortfall) = reserves.observeIdleUSDC();
        assertEq(shortfall, 0);
        assertEq(reserves.idleCustodyShortfall(), 0);
        assertTrue(controller.backingInvariantHolds());
        assertEq(reserves.totalBackingValue(), 100e18, "a donation is still not backing");
        assertEq(reserves.recognizedBackingValue(), 100e18, "and a surplus does not inflate it either");

        vm.prank(alice);
        controller.redeem(10e18);
    }

    /// @dev Boundary: ONE unit of USDC (1e-6) missing is enough. There is no tolerance band,
    ///      because paying par out of a known-short pool is the harm and it is done on the FIRST
    ///      dollar out, not the last.
    function test_R4_01_oneMissingUnitIsEnoughToCloseParExits() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(1);

        assertEq(reserves.idleCustodyShortfall(), 1e12);
        assertFalse(controller.backingInvariantHolds(), "a one-unit gap is still a gap");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector, 1e12, 100e18 - 1e12
            )
        );
        vm.prank(alice);
        controller.redeem(1e18);
    }

    // ── 5. COMPATIBILITY WITH THE C-01 CASCADE (anti-collision; must stay green) ─────

    /// @notice The authenticated absorption path must still run WHILE the shortfall stands — that
    ///         is the whole reason recognition and absorption are kept in different functions.
    /// @dev If a future change routes `MintRedeemController._assertBacking` (which also guards
    ///      `burnLoss`) through `recognizedBackingValue()`, this test goes red: `reconcileIdleUSDC`
    ///      burns supply BEFORE it lowers `idleUSDCUnits`, so the shortfall is still standing at
    ///      every intermediate cascade burn and a recognition-aware assertion would revert them.
    function test_R4_01_authenticatedAbsorptionStillRunsWhileTheShortfallStands() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        _drainCustody(25e6);
        assertFalse(controller.backingInvariantHolds(), "the gap is recognised before absorption runs");
        _armReserveLoss(41);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(25e18);
        assertEq(actualLoss, 25e18, "the cascade must recognize the canonical live shortfall");

        assertEq(controller.totalUSDfr(), 75e18, "senior principal absorbed the custody loss");
        assertEq(reserves.reserveDeficit(), 0);
        assertEq(reserves.idleCustodyShortfall(), 0, "absorption wrote the ledger down to live custody");
        assertTrue(controller.backingInvariantHolds(), "absorption closes the recognised gap");
    }

    /// @notice And once absorbed, par business reopens through the ordinary user path.
    function test_R4_01_absorptionReopensParExits() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 40e18);
        vault.deposit(40e18, alice);
        vm.stopPrank();

        _drainCustody(25e6);
        _armReserveLoss(42);
        _ratifyCurrentReserveLoss(25e18);

        vm.prank(alice);
        uint256 out = controller.redeem(10e18);
        assertEq(out, 10e6);
        assertEq(usdfr.balanceOf(alice), minted - 40e18 - 10e18);
    }

    // ── 6. ACCESS CONTROL IS STILL CHECKED FIRST ─────────────────────────

    /// @dev The new guard must never mask the role check, or custody state becomes probeable by
    ///      an unauthorised caller through the difference in revert reason.
    function test_R4_01_roleCheckStillPrecedesTheShortfallGuard() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, Roles.CONTROLLER_ROLE)
        );
        vm.prank(bob);
        reserves.releaseUSDC(bob, 1e6);
    }

    /// @dev And KYC still precedes it on the controller: a non-allowed address gets the KYC error
    ///      whether or not the reserve is short.
    function test_R4_01_kycStillPrecedesTheShortfallGuard() public {
        _mintUSDfr(alice, 100e6);
        _drainCustody(25e6);

        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        vm.prank(carol);
        controller.redeem(1e18);
    }
}
