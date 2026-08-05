// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev Deliberately violates exact-transfer behavior so the reserve accounting's
///      no-value and short-receipt failure modes can be executed.
contract AdversarialUSDC is ERC20 {
    enum Mode {
        Normal,
        NoTransfer,
        ShortTransfer
    }

    Mode internal mode;

    constructor() ERC20("Adversarial USDC", "aUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(Mode next) external {
        mode = next;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (mode == Mode.NoTransfer) return;
            if (mode == Mode.ShortTransfer) value -= 1;
        }
        super._update(from, to, value);
    }
}

/// @dev Exercises every guard-clause revert path and pause/unpause pair not already
///      hit by the behavioral suites — CLAUDE.md §1.2 requires 100% branch coverage
///      on value/accounting contracts, and guards are branches.
contract GuardBranchesTest is TokenLayerFixture {
    // ── controller ───────────────────────────────────────────────────────

    function test_controller_initialize_zeroAddressReverts() public {
        MintRedeemController impl = new MintRedeemController();
        vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                MintRedeemController.initialize,
                (address(0), guardian, admin, address(usdfr), address(compliance), address(reserves))
            )
        );
        vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                MintRedeemController.initialize,
                (admin, guardian, admin, address(usdfr), address(compliance), address(0))
            )
        );
    }

    function test_controller_redeem_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        controller.redeem(0);
    }

    function test_controller_mintYield_zeroChecks() public {
        vm.startPrank(creditModule);
        vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
        controller.mintYield(address(0), 1);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        controller.mintYield(alice, 0);
        vm.stopPrank();
    }

    function test_controller_burnLoss_zeroChecks() public {
        vm.startPrank(creditModule);
        vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
        controller.burnLoss(address(0), 1);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        controller.burnLoss(alice, 0);
        vm.stopPrank();
    }

    function test_controller_unpause() public {
        vm.startPrank(guardian);
        controller.pause();
        controller.unpause();
        vm.stopPrank();
        _mintUSDfr(alice, 1e6); // mint works again
        assertEq(usdfr.balanceOf(alice), 1e18);
    }

    // ── reserves ─────────────────────────────────────────────────────────

    function _adversarialReserve() internal returns (AdversarialUSDC token, ReserveManager manager) {
        token = new AdversarialUSDC();
        manager = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(new ReserveManager()),
                    abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(token)))
                )
            )
        );
        vm.startPrank(admin);
        manager.grantRole(Roles.CREDIT_ROLE, creditModule);
        manager.grantRole(Roles.CONTROLLER_ROLE, address(controller));
        vm.stopPrank();
    }

    function test_reserves_initialize_rejectsEveryZeroPrincipalAndNonUSDCDecimals() public {
        ReserveManager impl = new ReserveManager();
        address[5] memory args = [admin, admin, guardian, admin, address(usdc)];
        for (uint256 i; i < args.length; ++i) {
            address saved = args[i];
            args[i] = address(0);
            vm.expectRevert(IReserveManager.ReserveManager_ZeroAddress.selector);
            new ERC1967Proxy(
                address(impl), abi.encodeCall(ReserveManager.initialize, (args[0], args[1], args[2], args[3], args[4]))
            );
            args[i] = saved;
        }

        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidUSDCDecimals.selector, uint8(18)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(dai)))
        );
    }

    function test_reserves_depositUSDC_rejectsUnauthorizedAndZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NotDepositor.selector, alice));
        reserves.depositUSDC(alice, 1);

        vm.prank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.depositUSDC(alice, 0);
    }

    function test_reserves_depositUSDC_zeroAddressReverts() public {
        vm.prank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAddress.selector);
        reserves.depositUSDC(address(0), 1);
    }

    function test_reserves_depositUSDC_controllerRoleAloneCanDeposit() public {
        usdc.mint(address(controller), 1e6);
        vm.prank(address(controller));
        usdc.approve(address(reserves), 1e6);
        vm.prank(address(controller));
        assertEq(reserves.depositUSDC(address(controller), 1e6), 1e18);
    }

    function test_reserves_depositUSDC_rejectsNoValueAndShortReceipt() public {
        (AdversarialUSDC token, ReserveManager manager) = _adversarialReserve();
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(address(manager), type(uint256).max);

        token.setMode(AdversarialUSDC.Mode.NoTransfer);
        vm.prank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_NoValueReceived.selector);
        manager.depositUSDC(alice, 2e6);

        token.setMode(AdversarialUSDC.Mode.ShortTransfer);
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_UnexpectedUSDCReceipt.selector, 2e6, 2e6 - 1)
        );
        manager.depositUSDC(alice, 2e6);
    }

    function test_reserves_writeDownIdleUSDC_exactnessAndBounds() public {
        vm.prank(alice);
        usdc.approve(address(reserves), 1e6);
        vm.prank(creditModule);
        reserves.depositUSDC(alice, 1e6);

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_WriteDownExceedsIdle.selector, 2e18, 1e18)
        );
        reserves.writeDownIdleUSDC(2e18);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, 1));
        reserves.writeDownIdleUSDC(1);
        reserves.writeDownIdleUSDC(1e18);
        vm.stopPrank();
        assertEq(reserves.idleReserve(), 0);
    }

    function test_reserves_writeDownIdleUSDC_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.writeDownIdleUSDC(0);
    }

    function test_reserves_recordDeployment_zeroChecks() public {
        _mintUSDfr(alice, 10e6);
        vm.startPrank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAddress.selector);
        reserves.recordDeployment(1, address(0), 1e6);
        vm.expectRevert(IReserveManager.ReserveManager_SelfDeployment.selector);
        reserves.recordDeployment(1, address(reserves), 1e6);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.recordDeployment(1, borrower, 0);
        vm.stopPrank();
    }

    function test_reserves_recordDeployment_insufficientIdleReverts() public {
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientIdleValue.selector, 1e18, 0));
        reserves.recordDeployment(1, borrower, 1e6);
    }

    function test_reserves_recordFeeCapitalization_exactnessAndBounds() public {
        vm.startPrank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.recordFeeCapitalization(1, 0);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, 1));
        reserves.recordFeeCapitalization(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientIdleValue.selector, 1e18, 0));
        reserves.recordFeeCapitalization(1, 1e18);
        vm.stopPrank();
    }

    function test_reserves_recordPayment_zeroAmountReverts() public {
        vm.prank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.recordPayment(1, borrower, 0, 0);
    }

    function test_reserves_recordPayment_rejectsZeroPayerAndBadReceipts() public {
        vm.prank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAddress.selector);
        reserves.recordPayment(1, address(0), 1, 0);

        (AdversarialUSDC token, ReserveManager manager) = _adversarialReserve();
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(address(manager), type(uint256).max);

        token.setMode(AdversarialUSDC.Mode.NoTransfer);
        vm.prank(creditModule);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_UnexpectedUSDCReceipt.selector, 2e6, 0));
        manager.recordPayment(1, alice, 2e6, 0);

        token.setMode(AdversarialUSDC.Mode.ShortTransfer);
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_UnexpectedUSDCReceipt.selector, 2e6, 2e6 - 1)
        );
        manager.recordPayment(1, alice, 2e6, 0);
    }

    function test_reserves_recordPayment_principalBounds() public {
        vm.prank(bob);
        usdc.approve(address(reserves), 2e6);

        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_PrincipalExceedsPayment.selector, 2e18, 1e18)
        );
        reserves.recordPayment(1, bob, 1e6, 2e18);

        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientDeployedPrincipal.selector, 1, 1e18, 0)
        );
        reserves.recordPayment(1, bob, 1e6, 1e18);
    }

    function test_reserves_recordPrincipalWritedown_zeroAndInsufficient() public {
        vm.startPrank(creditModule);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.recordPrincipalWritedown(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientDeployedPrincipal.selector, 1, 5, 0)
        );
        reserves.recordPrincipalWritedown(1, 5);
        vm.stopPrank();
    }

    function test_reserves_unpause() public {
        _mintUSDfr(alice, 5e6);
        vm.startPrank(guardian);
        reserves.pause();
        reserves.unpause();
        vm.stopPrank();
        vm.prank(address(controller));
        reserves.releaseUSDC(bob, 1e6); // works again
    }

    function test_reserves_releaseUSDC_allGuards() public {
        _mintUSDfr(alice, 1e6);
        vm.startPrank(address(controller));
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAddress.selector);
        reserves.releaseUSDC(address(0), 1);
        vm.expectRevert(IReserveManager.ReserveManager_SelfDeployment.selector);
        reserves.releaseUSDC(address(reserves), 1);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.releaseUSDC(bob, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InsufficientIdleValue.selector, 2e18, 1e18)
        );
        reserves.releaseUSDC(bob, 2e6);
        vm.stopPrank();
    }

    // ── vault ────────────────────────────────────────────────────────────

    function test_vault_initialize_zeroAddressReverts() public {
        SUSDfr impl = new SUSDfr();
        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                SUSDfr.initialize, (address(0), guardian, admin, address(usdfr), address(compliance), feeRecipient)
            )
        );
        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SUSDfr.initialize, (admin, guardian, admin, address(usdfr), address(0), feeRecipient))
        );
        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SUSDfr.initialize, (admin, guardian, admin, address(usdfr), address(compliance), address(0)))
        );
    }

    function test_vault_initialize_rejectsNonExemptFeeRecipient() public {
        SUSDfr impl = new SUSDfr();
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_FeeRecipientNotExempt.selector, carol));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SUSDfr.initialize, (admin, guardian, admin, address(usdfr), address(compliance), carol))
        );
    }

    function test_vault_unpause() public {
        vm.startPrank(guardian);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        uint256 minted = _mintUSDfr(alice, 5e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice); // works again
        vm.stopPrank();
    }

    function test_vault_mint_exactShares() public {
        uint256 minted = _mintUSDfr(alice, 5e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        uint256 assets = vault.mint(1e24, alice);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), 1e24);
        assertLe(assets, minted);
    }
}
