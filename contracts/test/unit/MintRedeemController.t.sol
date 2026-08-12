// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract MintRedeemControllerTest is TokenLayerFixture {
    // ── mint ─────────────────────────────────────────────────────────────

    function test_mint_oneToOneNormalized6Decimals() public {
        vm.startPrank(alice);
        usdc.approve(address(controller), 250e6);
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.Minted(alice, 250e6, 250e18);
        uint256 out = controller.mint(250e6);
        vm.stopPrank();

        assertEq(out, 250e18);
        assertEq(usdfr.balanceOf(alice), 250e18);
        assertEq(usdc.balanceOf(address(reserves)), 250e6);
        assertTrue(controller.backingInvariantHolds());
        assertEq(controller.totalUSDfr(), controller.backingValue());
    }

    function test_mint_revertsForNonKYC() public {
        vm.startPrank(carol);
        usdc.approve(address(controller), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.mint(10e6);
        vm.stopPrank();
    }

    function test_mint_revertsForBlockedEvenIfAllowlisted() public {
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(alice, true);
        vm.startPrank(alice);
        usdc.approve(address(controller), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, alice));
        controller.mint(10e6);
        vm.stopPrank();
    }

    function test_mint_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        controller.mint(0);
    }

    function test_mint_pausedReverts() public {
        vm.prank(guardian);
        controller.pause();
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.mint(1e6);
    }

    // ── redeem ───────────────────────────────────────────────────────────

    function test_redeem_roundTrip() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.Redeemed(alice, 100e18, 100e6);
        uint256 stableOut = controller.redeem(100e18);
        vm.stopPrank();

        assertEq(stableOut, 100e6);
        assertEq(usdfr.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_redeem_dustBelowStableDecimalsNotSilentlyTaken() public {
        _mintUSDfr(alice, 100e6);
        // 50.5 USDfr + 1 wei: only 50.5e6 USDC out; exactly 50.5e18 burned, 1 wei stays
        vm.prank(alice);
        uint256 out = controller.redeem(50_500000_000000_000001);
        assertEq(out, 50_500000);
        assertEq(usdfr.balanceOf(alice), 100e18 - 50_500000_000000_000000);
    }

    function test_redeem_amountTooSmallReverts() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_AmountTooSmall.selector, 1e11));
        controller.redeem(1e11); // < 1e12 (one USDC unit)
    }

    function test_redeem_revertsForNonKYC() public {
        _mintUSDfr(alice, 10e6);
        vm.prank(alice);
        usdfr.transfer(carol, 10e18); // carol can hold...
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.redeem(10e18); // ...but not redeem
    }

    function test_redeem_insufficientIdleLiquidityReverts() public {
        _mintUSDfr(alice, 100e6);
        // deploy 80 of the 100 idle to a facility
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 80e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientIdleValue.selector, 100e18, 20e18)
        );
        controller.redeem(100e18);
    }

    // ── credit-layer paths ───────────────────────────────────────────────

    function test_mintYield_requiresBackingFirst() public {
        _mintUSDfr(alice, 100e6);
        // no new backing arrived: any yield mint must violate the invariant
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_BackingInvariantViolated.selector, 101e18, 100e18)
        );
        controller.mintYield(address(vault), 1e18);

        // attested receipt arrives (stable lands in the treasury) → mint succeeds
        usdc.mint(creditModule, 1e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 1e6);
        reserves.depositUSDC(creditModule, 1e6);
        vm.stopPrank();
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.YieldMinted(address(vault), 1e18);
        vm.prank(creditModule);
        controller.mintYield(address(vault), 1e18);
        assertEq(usdfr.balanceOf(address(vault)), 1e18);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_mintYield_onlyCreditRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.CREDIT_ROLE)
        );
        vm.prank(alice);
        controller.mintYield(alice, 1e18);
    }

    /// @dev AUDIT FIX (R16-M1/M2) CHANGED THIS TEST DELIBERATELY. It used to burn `alice`, an
    ///      ordinary KYC'd holder, and passed — which is the finding: `USDfr.burn` takes no
    ///      allowance, so this was a forced, non-pro-rata seizure from one named holder. The burn
    ///      now targets the governance-named loss source (the vault, cascade layer 3).
    function test_burnLoss_burnsAndEmits() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 10e18);
        vm.expectEmit(true, false, false, true, address(controller));
        emit IMintRedeemController.LossBurned(address(vault), 10e18);
        vm.prank(creditModule);
        controller.burnLoss(address(vault), 10e18);
        assertEq(usdfr.balanceOf(address(vault)), 0);
    }

    function test_burnLoss_onlyLossBurnerRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.LOSS_BURNER_ROLE
            )
        );
        vm.prank(alice);
        controller.burnLoss(address(vault), 1);
    }

    function test_writedownThenBurnLoss_restoresInvariant() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 10e18);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 50e6);

        // realized loss: writedown 10 → invariant is broken until the cascade burns
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(1, 10e18);
        assertFalse(controller.backingInvariantHolds());

        vm.prank(creditModule);
        controller.burnLoss(address(vault), 10e18);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_burnLoss_reducesExistingDeficitExactlyWithoutRequiringImmediateSolvency() public {
        _mintUSDfr(alice, 100e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), 20e18);
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, 50e6);
        reserves.recordPrincipalWritedown(1, 20e18);
        controller.burnLoss(address(vault), 5e18);
        vm.stopPrank();

        assertEq(controller.totalUSDfr(), 95e18);
        assertEq(controller.backingValue(), 80e18);
        assertFalse(controller.backingInvariantHolds(), "partial absorption leaves only the genuine residual deficit");

        vm.prank(creditModule);
        controller.burnLoss(address(vault), 15e18);
        assertTrue(controller.backingInvariantHolds(), "the final absorption restores absolute backing");
    }

    // ── views ────────────────────────────────────────────────────────────

    function test_modules_wiring() public view {
        (address u, address c, address r) = controller.modules();
        assertEq(u, address(usdfr));
        assertEq(c, address(compliance));
        assertEq(r, address(reserves));
    }

    // ── upgrade ──────────────────────────────────────────────────────────

    function test_upgrade_authorizedOnly() public {
        address newImpl = address(new MintRedeemController());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        controller.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        controller.upgradeToAndCall(newImpl, "");
        assertTrue(controller.backingInvariantHolds());
    }
}
