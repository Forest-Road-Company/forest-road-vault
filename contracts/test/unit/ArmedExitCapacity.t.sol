// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";

/// @notice Admission during an arm is independent of permissionless coverage contributions.
contract ArmedExitCapacityTest is ProductionCreditFixture {
    uint256 private loan;
    uint256 private arm;
    uint256 private constant EXIT = 500_000e18;

    function setUp() public override {
        super.setUp();
        _mintUSDfrTo(alice, 1_000_000e18);
        _mintUSDfrTo(bob, 1_000_000e18);
        vm.prank(admin);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, anchorCurator, true);
        loan = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        _fundFacility(loan, 500_000e18);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(loan, 250_000e18, keccak256("independent credit mark"));
        (arm,) = _armReserveLoss(52);
    }

    function _refused() private {
        uint256 supply = usdfr.totalSupply();
        uint256 cash = usdc.balanceOf(alice);
        uint256 capital = sGrove.coverageReserve();
        uint256 prepaid = reserves.exitPrepaidAbsorption();
        (uint256 quote, uint256 input) = controller.previewRedeem(EXIT);
        assertEq(quote, 0);
        assertEq(input, 0);
        vm.expectPartialRevert(IMintRedeemController.Controller_ReserveLossArmFreeze.selector);
        vm.prank(alice);
        controller.redeem(EXIT, 0, block.timestamp);
        assertEq(usdfr.totalSupply(), supply);
        assertEq(usdc.balanceOf(alice), cash);
        assertEq(sGrove.coverageReserve(), capital);
        assertEq(reserves.exitPrepaidAbsorption(), prepaid);
    }

    function _fund(uint256 amount) private {
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _resolvedExit() private {
        vm.prank(admin);
        reserves.cancelUnratifiedArm(arm, keccak256("custody confirmed"));
        assertEq(reserves.principalImpairmentOf(loan), 250_000e18);
        vm.prank(alice);
        assertGt(controller.redeem(EXIT, 0, block.timestamp), 0);
        assertEq(reserves.principalImpairmentOf(loan), 250_000e18);
    }

    function test_oneUnitContributionDoesNotChangeAdmission() public {
        _refused();
        _fund(1);
        _refused();
        _resolvedExit();
    }

    function testFuzz_contributionsCannotChangeArmAdmission(uint96 contribution) public {
        uint256 amount = bound(contribution, 1, 100_000e18);
        _refused();
        _fund(amount);
        _refused();
        _resolvedExit();
    }
}
