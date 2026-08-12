// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract SUSDfrTest is TokenLayerFixture {
    address internal queue = makeAddr("queue");

    function _stake(address user, uint256 usdcAmount) internal returns (uint256 shares) {
        uint256 minted = _mintUSDfr(user, usdcAmount);
        vm.startPrank(user);
        usdfr.approve(address(vault), minted);
        shares = vault.deposit(minted, user);
        vm.stopPrank();
    }

    // ── metadata ─────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(vault.name(), Config.SUSDFR_NAME);
        assertEq(vault.symbol(), Config.SUSDFR_SYMBOL);
        assertEq(vault.asset(), address(usdfr));
        assertEq(vault.decimals(), 18 + 6); // decimals offset (donation defense)
    }

    // ── deposit / KYC gate ───────────────────────────────────────────────

    function test_deposit_mintsSharesAtInitialRate() public {
        uint256 shares = _stake(alice, 100e6);
        assertEq(vault.balanceOf(alice), shares);
        // initial rate: 1 USDfr per 1e18 "share-units" of exchange rate view
        assertEq(vault.currentExchangeRate(), 1e18);
        assertEq(vault.convertToAssets(shares), 100e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_deposit_permissionlessButSanctionedReceiverReverts() public {
        // 2026-07-14 directive: staking is permissionless — a non-KYC'd receiver can receive
        // shares (KYC lives only at the USDfr mint/redeem primary gate).
        uint256 minted = _mintUSDfr(alice, 10e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, carol); // carol not KYC'd — succeeds
        vm.stopPrank();
        assertGt(vault.balanceOf(carol), 0, "permissionless deposit mints shares");

        // sanctions freeze still applies to the share mint: a blocked receiver is denied.
        uint256 minted2 = _mintUSDfr(alice, 10e6);
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(carol, true);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted2);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_TransferBlocked.selector, address(0), carol));
        vault.deposit(minted2, carol);
        vm.stopPrank();
    }

    function test_deposit_pausedReverts() public {
        uint256 minted = _mintUSDfr(alice, 10e6);
        vm.prank(guardian);
        vault.pause();
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        // audit fix: maxDeposit returns 0 while paused (ERC-4626 conformance), so the
        // deposit is rejected by the max check with ERC4626ExceededMaxDeposit BEFORE
        // reaching the whenNotPaused guard in _deposit. Both mean "no deposit while
        // paused"; assert deposit still reverts and maxDeposit/maxMint advertise 0.
        assertEq(vault.maxDeposit(alice), 0, "no deposit capacity while paused");
        assertEq(vault.maxMint(alice), 0, "no mint capacity while paused");
        vm.expectRevert();
        vault.deposit(minted, alice);
        vm.stopPrank();

        // unpausing restores capacity
        vm.prank(guardian);
        vault.unpause();
        vm.prank(alice);
        vault.deposit(minted, alice);
    }

    // ── exchange rate dynamics ───────────────────────────────────────────

    function test_exchangeRate_risesOnYield_neverForUser() public {
        uint256 shares = _stake(alice, 100e6);
        uint256 rateBefore = vault.currentExchangeRate();

        _receiveYield(address(vault), 10e6); // 10 USDfr yield into the vault

        uint256 rateAfter = vault.currentExchangeRate();
        assertGt(rateAfter, rateBefore);
        // alice's claim grew without any new shares
        assertEq(vault.balanceOf(alice), shares);
        assertGt(vault.convertToAssets(shares), 100e18);
    }

    function test_exchangeRate_fallsOnlyViaExplicitLossBurn() public {
        uint256 shares = _stake(alice, 100e6);

        // realized loss: deploy, write down, burn from the vault (cascade layer 3)
        vm.startPrank(creditModule);
        reserves.recordDeployment(1, borrower, 50e6);
        reserves.recordPrincipalWritedown(1, 20e18);
        controller.burnLoss(address(vault), 20e18);
        vm.stopPrank();

        assertLt(vault.currentExchangeRate(), 1e18);
        assertLt(vault.convertToAssets(shares), 100e18);
        assertTrue(controller.backingInvariantHolds());
    }

    // ── queue-only exits ─────────────────────────────────────────────────

    function test_withdraw_revertsForUsers() public {
        _stake(alice, 100e6);
        // OZ's max* checks fire first (maxWithdraw/maxRedeem are 0 for non-queue)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, alice, 1e18, 0));
        vault.withdraw(1e18, alice, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, alice, 1e18, 0));
        vault.redeem(1e18, alice, alice);
    }

    function test_withdraw_queueOnlyGuardBlocksNonQueueCaller() public {
        // defense-in-depth: even with queue-owned shares and allowance, a non-queue
        // CALLER cannot exit
        vm.prank(admin);
        vault.setRedemptionQueue(queue);
        vm.prank(complianceAdmin);
        compliance.setAllowed(queue, true);
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        vault.transfer(queue, shares);
        vm.prank(queue);
        vault.approve(bob, shares);
        vm.prank(bob);
        vm.expectRevert(IsUSDfr.SUSDfr_QueueOnly.selector);
        vault.redeem(shares, bob, queue);
    }

    function test_prepareRedemptionPricing_queueOnly() public {
        vm.prank(admin);
        vault.setRedemptionQueue(queue);

        vm.expectRevert(IsUSDfr.SUSDfr_QueueOnly.selector);
        vault.prepareRedemptionPricing(1e18);
    }

    function test_maxWithdrawAndRedeem_zeroForNonQueue() public {
        _stake(alice, 100e6);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    /// @dev audit R5-T2: while paused, `_withdraw` reverts, so maxWithdraw/maxRedeem must
    ///      advertise 0 even for the queue (ERC-4626 conformance, mirroring maxDeposit/Mint).
    function test_maxWithdrawAndRedeem_zeroWhilePaused() public {
        vm.prank(admin);
        vault.setRedemptionQueue(queue);
        vm.prank(complianceAdmin);
        compliance.setAllowed(queue, true);
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        vault.transfer(queue, shares);
        assertGt(vault.maxRedeem(queue), 0, "capacity before pause");

        vm.prank(guardian);
        vault.pause();
        assertEq(vault.maxWithdraw(queue), 0, "no withdraw capacity while paused");
        assertEq(vault.maxRedeem(queue), 0, "no redeem capacity while paused");
    }

    function test_queue_canRedeemSharesItHolds() public {
        vm.prank(admin);
        vault.setRedemptionQueue(queue);
        vm.prank(complianceAdmin);
        compliance.setAllowed(queue, true); // queue receives shares on transfer-in

        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        vault.transfer(queue, shares); // queue escrows shares (Phase F mechanics)

        assertGt(vault.maxRedeem(queue), 0);
        vm.prank(queue);
        uint256 assets = vault.redeem(shares, queue, queue);
        assertEq(assets, 100e18);
        assertEq(usdfr.balanceOf(queue), 100e18);
    }

    function test_setRedemptionQueue_adminOnlyAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit IsUSDfr.RedemptionQueueUpdated(queue);
        vm.prank(admin);
        vault.setRedemptionQueue(queue);
        assertEq(vault.redemptionQueue(), queue);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        vault.setRedemptionQueue(alice);

        vm.prank(admin);
        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        vault.setRedemptionQueue(address(0));
    }

    // ── donation resistance ──────────────────────────────────────────────

    function test_donation_cannotStealFromLaterDepositor() public {
        // attacker donates USDfr directly to the vault before bob deposits
        uint256 minted = _mintUSDfr(alice, 1_000e6);
        vm.prank(alice);
        usdfr.transfer(address(vault), minted); // 1000e18 donation, zero shares out

        uint256 bobShares = _stake(bob, 100e6);
        // bob must not lose principal to rounding (virtual-share offset defends)
        uint256 bobAssets = vault.convertToAssets(bobShares);
        // offset-6 virtual shares: any dilution from a 10x donation is < 0.01%%
        assertGe(bobAssets, 100e18 * 9999 / 10000);
    }

    // ── upgrade ──────────────────────────────────────────────────────────

    function test_upgrade_authorizedOnly() public {
        address newImpl = address(new SUSDfr());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        vault.upgradeToAndCall(newImpl, "");
        uint256 shares = _stake(alice, 50e6);
        vm.prank(admin);
        vault.upgradeToAndCall(newImpl, "");
        assertEq(vault.balanceOf(alice), shares); // state survives
    }

    /// @dev COVERAGE (CLAUDE.md 1.2): the `pointsModule()` view was the vault's last
    ///      unexercised function. The hook is optional and fail-open, so the view is how an
    ///      operator confirms whether points accrual is wired at all — worth a real assertion,
    ///      not just a line touched.
    ///
    ///      RE-POINTED 2026-08-11 (P-48), disposition recorded rather than deleted. This test
    ///      previously installed `makeAddr("pointsModule")` -- a CODELESS address -- and asserted
    ///      only that the getter read it back, so it demonstrated the bricked state and asserted
    ///      nothing about it; the section-5 DoD pass named it a weak assertion on exactly that
    ///      ground. `setPointsModule` now refuses a codeless module (the C4-USDFR-01 remediation
    ///      extended to the vault), so the wiring is exercised with a REAL module. The refusal
    ///      and the brick it prevents are pinned in
    ///      `test/audit/P48_VaultCodelessPointsModule.t.sol`; no coverage is lost.
    function test_pointsModule_viewReflectsWiring() public {
        vm.prank(admin);
        vault.setPointsModule(address(0));
        assertEq(vault.pointsModule(), address(0), "cleared reads back as disabled");

        address module = address(new SUSDfrViewWiringPoints());
        vm.prank(admin);
        vault.setPointsModule(module);
        assertEq(vault.pointsModule(), module, "wired module reads back");
    }
}

/// @dev P-48: a real (inert) points module, so the wiring view is exercised without installing
///      the codeless address the setter now refuses.
contract SUSDfrViewWiringPoints is IPointsModule {
    function onSharesTransfer(address, address, uint256) external pure {}
    function onUSDfrTransfer(address, address, uint256) external pure {}
    function onCuratorStakeChange(address, uint256, uint256) external pure {}
    function onCuratorLoss(uint256, uint256, uint256) external pure {}
}
