// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev End-to-end token-layer lifecycle (CLAUDE.md §1.1 integration bar):
///      mint → stake → deploy → interest accrual → partial repayment →
///      loss through writedown+burn → redeem — with the backing invariant checked
///      at every stage and value conservation asserted at the end.
contract TokenLayerFlowTest is TokenLayerFixture {
    function test_fullLifecycle_depositThroughLossAndRedeem() public {
        // ── 1. Two depositors mint USDfr 1:1 ─────────────────────────────
        uint256 aliceUSDfr = _mintUSDfr(alice, 500_000e6); // 500k
        uint256 bobUSDfr = _mintUSDfr(bob, 300_000e6); // 300k
        assertEq(controller.totalUSDfr(), 800_000e18);
        assertTrue(controller.backingInvariantHolds());

        // ── 2. Alice stakes into the vault ────────────────────────────────
        vm.startPrank(alice);
        usdfr.approve(address(vault), aliceUSDfr);
        uint256 aliceShares = vault.deposit(aliceUSDfr, alice);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 500_000e18);
        uint256 rate0 = vault.currentExchangeRate();

        // ── 3. Credit layer deploys 400k to facility #1 (film class) ─────
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 400_000e6);
        assertEq(reserves.deployedPrincipal(), 400_000e18);
        assertTrue(controller.backingInvariantHolds()); // composition shift only

        // ── 4. Interest arrives (attested receipt), yield mints to vault ──
        _receiveYield(address(vault), 12_000e6); // 12k interest
        uint256 rate1 = vault.currentExchangeRate();
        assertGt(rate1, rate0);
        assertTrue(controller.backingInvariantHolds());

        // ── 5. Partial principal repayment is pulled and recorded atomically ───────
        usdc.mint(borrower, 100_000e6);
        vm.prank(borrower);
        usdc.approve(address(reserves), 100_000e6);
        vm.prank(creditModule);
        reserves.recordPayment(1, borrower, 100_000e6, 100_000e18);
        assertEq(reserves.deployedPrincipal(), 300_000e18);
        assertTrue(controller.backingInvariantHolds());

        // ── 6. A loss: 50k written down, absorbed from the vault (layer 3
        //       stand-in until the cascade modules land in Phase E) ────────
        vm.startPrank(creditModule);
        reserves.recordPrincipalWritedown(1, 50_000e18);
        controller.burnLoss(address(vault), 50_000e18);
        vm.stopPrank();
        uint256 rate2 = vault.currentExchangeRate();
        assertLt(rate2, rate1); // explicit, evented fall — never silent
        assertTrue(controller.backingInvariantHolds());

        // ── 7. Bob redeems his unstaked USDfr for USDC ────────────────────
        vm.prank(bob);
        uint256 bobOut = controller.redeem(bobUSDfr);
        assertEq(bobOut, 300_000e6);
        assertTrue(controller.backingInvariantHolds());

        // ── 8. Value conservation check ───────────────────────────────────
        // Alice's vault claim = 500k + 12k yield − 50k loss = 462k
        assertEq(vault.convertToAssets(aliceShares), 462_000e18);
        assertEq(controller.totalUSDfr(), 462_000e18);
    }

    function test_negativeQA_mintOverBackingImpossible() public {
        // there is no path to mint without depositing backing first: a yield mint
        // with no backing reverts atomically
        _mintUSDfr(alice, 1_000e6);
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_BackingInvariantViolated.selector, 1_001e18, 1_000e18
            )
        );
        controller.mintYield(alice, 1e18);
    }

    function test_negativeQA_redeemBeyondIdleLiquidityBlocked() public {
        _mintUSDfr(alice, 1_000e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 900e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientIdleValue.selector, 1_000e18, 100e18)
        );
        controller.redeem(1_000e18);
    }
}
