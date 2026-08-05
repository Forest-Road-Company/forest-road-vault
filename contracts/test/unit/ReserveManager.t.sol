// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ReserveManager} from "../../src/ReserveManager.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract ReserveManagerTest is TokenLayerFixture {
    function _deposit(address from, uint256 units) internal {
        vm.prank(from);
        usdc.approve(address(reserves), units);
        vm.prank(creditModule);
        reserves.depositUSDC(from, units);
    }

    function test_USDCOnly_exactDepositAndNormalization() public {
        _deposit(alice, 125e6);
        assertEq(reserves.usdc(), address(usdc));
        assertEq(reserves.idleUSDC(), 125e6);
        assertEq(reserves.idleReserve(), 125e18);
        assertEq(reserves.totalBackingValue(), 125e18);
        assertEq(reserves.normalizeUSDC(1), 1e12);
        assertEq(reserves.denormalizeUSDC(1e12), 1);
    }

    function test_directDonationNeverCreatesBacking() public {
        usdc.mint(address(reserves), 50e6);
        assertEq(usdc.balanceOf(address(reserves)), 50e6);
        assertEq(reserves.idleReserve(), 0);
        assertEq(reserves.reconcileIdleUSDC(), 0);
        assertEq(reserves.totalBackingValue(), 0);
    }

    function test_reconcileOnlyLowersAndCannotReverseWriteDown() public {
        _deposit(alice, 100e6);
        vm.prank(admin);
        reserves.writeDownIdleUSDC(40e18);
        assertEq(reserves.idleReserve(), 60e18);
        assertEq(usdc.balanceOf(address(reserves)), 100e6);

        reserves.reconcileIdleUSDC();
        assertEq(reserves.idleReserve(), 60e18, "live surplus cannot reverse a governance write-down");
    }

    function test_reconcileDetectsCustodyLoss() public {
        _deposit(alice, 100e6);
        vm.prank(address(reserves));
        usdc.transfer(bob, 25e6);
        assertEq(reserves.reconcileIdleUSDC(), 75e6);
        assertEq(reserves.idleReserve(), 75e18);
    }

    function test_deploymentMovesIdleIntoFacilityWithoutChangingBacking() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 80e6);
        assertEq(reserves.idleReserve(), 20e18);
        assertEq(reserves.deployedTo(7), 80e18);
        assertEq(reserves.deployedPrincipal(), 80e18);
        assertEq(reserves.totalBackingValue(), 100e18);
        assertEq(usdc.balanceOf(borrower), 80e6);
    }

    function test_atomicPaymentRequiresCashAndReducesOnlyPrincipalLeg() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 100e6);

        usdc.mint(bob, 15e6);
        vm.prank(bob);
        usdc.approve(address(reserves), 15e6);
        vm.prank(creditModule);
        uint256 received = reserves.recordPayment(7, bob, 15e6, 10e18);

        assertEq(received, 15e18);
        assertEq(reserves.deployedTo(7), 90e18);
        assertEq(reserves.idleReserve(), 15e18);
        assertEq(reserves.totalBackingValue(), 105e18, "five dollars of interest increased backing");
    }

    function test_atomicPaymentWithoutApprovalLeavesAccountingUntouched() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 100e6);
        usdc.mint(bob, 10e6);

        vm.expectRevert();
        vm.prank(creditModule);
        reserves.recordPayment(7, bob, 10e6, 10e18);
        assertEq(reserves.deployedTo(7), 100e18);
        assertEq(reserves.idleReserve(), 0);
    }

    function test_feeCapitalizationKeepsRetainedCashAndAddsReceivable() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 98e6);
        vm.prank(creditModule);
        reserves.recordFeeCapitalization(7, 2e18);

        assertEq(reserves.idleReserve(), 2e18, "OID cash remains in treasury");
        assertEq(reserves.deployedTo(7), 100e18, "borrower owes full face");
        assertEq(reserves.totalBackingValue(), 102e18, "cash and capitalized receivable are distinct assets");
    }

    function test_writedownIsDurableAndCannotExceedFacility() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 100e6);
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(7, 30e18);
        assertEq(reserves.deployedTo(7), 70e18);
        assertEq(reserves.totalBackingValue(), 70e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_InsufficientDeployedPrincipal.selector, 7, 71e18, 70e18
            )
        );
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(7, 71e18);
    }

    function test_nonCreditCannotMutatePrincipal() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.CREDIT_ROLE)
        );
        vm.prank(alice);
        reserves.recordDeployment(1, borrower, 1);
    }

    function test_valueConversionRejectsSubUSDCPrecision() public {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, 1e12 + 1));
        reserves.denormalizeUSDC(1e12 + 1);
    }

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new ReserveManager());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        reserves.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        reserves.upgradeToAndCall(newImpl, "");
    }
}
