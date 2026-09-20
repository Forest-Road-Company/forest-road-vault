// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";

/// @notice The approved arm policy with canonical USDC and the real shared backstop.
contract ArmedExitPolicyForkTest is ForkLifecycleFixture {
    function test_forkPendingArmProtectsJuniorCapitalUntilGovernedResolution() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        _mintFromUSDC(bob, 1_000_000e6);
        _mintFromUSDC(ops, 3_000e6);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, ops, true);
        usdfr.approve(address(curator), 1_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1_000e18);
        usdfr.approve(address(sGrove), 2_000e18);
        sGrove.fundCoverage(2_000e18);
        uint256 id = _originateAndFund(100_000e18);
        reserves.recognizePrincipalImpairment(id, 50_000e18, keccak256("independent credit mark"));
        (uint256 armId,) = reserves.armReserveLossFreeze(keccak256("custody warning"));
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 cashBefore = IERC20(USDC).balanceOf(alice);
        uint256 prepaidBefore = reserves.exitPrepaidAbsorption();
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(500_000e18, 0, block.timestamp);
        assertEq(controller.totalUSDfr(), supplyBefore);
        assertEq(IERC20(USDC).balanceOf(alice), cashBefore);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 1_000e18);
        assertEq(sGrove.coverageReserve(), 2_000e18);
        assertEq(reserves.exitPrepaidAbsorption(), prepaidBefore);

        reserves.cancelUnratifiedArm(armId, keccak256("physical custody reconciled"));
        assertEq(reserves.principalImpairmentOf(id), 50_000e18);
        assertTrue(reserves.reserveLossExitsLocked());
        vm.prank(alice);
        uint256 paid = controller.redeem(500_000e18, 0, block.timestamp);
        assertGt(paid, 0);
        assertLt(paid, 500_000e6);
        assertEq(IERC20(USDC).balanceOf(alice), cashBefore + paid);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0);
        assertEq(sGrove.coverageReserve(), 0);
        assertEq(reserves.principalImpairmentOf(id), 50_000e18);
    }
    function test_forkArmAdmissionDoesNotDependOnCoverageContribution() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        _mintFromUSDC(ops, 1e6);
        uint256 id = _originateAndFund(100_000e18);
        reserves.recognizePrincipalImpairment(id, 50_000e18, keccak256("credit mark"));
        (uint256 armId,) = reserves.armReserveLossFreeze(keccak256("custody warning"));
        assertEq(sGrove.coverageReserve(), 0);
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(500_000e18, 0, block.timestamp);
        usdfr.approve(address(sGrove), 1);
        sGrove.fundCoverage(1);
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(500_000e18, 0, block.timestamp);
        assertEq(sGrove.coverageReserve(), 1);
        assertEq(reserves.exitPrepaidAbsorption(), 0);
        reserves.cancelUnratifiedArm(armId, keccak256("physical custody reconciled"));
        vm.prank(alice);
        assertGt(controller.redeem(500_000e18, 0, block.timestamp), 0);
        assertEq(reserves.principalImpairmentOf(id), 50_000e18);
    }
}
