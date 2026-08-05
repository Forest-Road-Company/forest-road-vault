// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ComplianceRegistry} from "../../../src/ComplianceRegistry.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {PointsModule} from "../../../src/PointsModule.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

/// @dev Bounded handler for the redesigned per-wallet points system (2026-07-14 directive).
///      `fail_on_revert = true` — every op is bounded to never revert. Exercises BOTH the
///      sUSDfr share hook and the USDfr balance hook (permissionless per-wallet accrual).
///      This handler is also the vault's redemption queue, so share burns are reachable.
contract PointsHandler is Test {
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ComplianceRegistry internal compliance;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    PointsModule internal points;
    address internal complianceAdmin;

    address public constant IDLE_WALLET = address(uint160(uint256(keccak256("points-idle-never-funded"))));

    address[4] public wallets;
    mapping(address => uint256) public lastSeenPoints;

    constructor(
        MockERC20 usdc_,
        USDfr usdfr_,
        ComplianceRegistry compliance_,
        MintRedeemController controller_,
        SUSDfr vault_,
        PointsModule points_,
        address complianceAdmin_,
        address admin_
    ) {
        usdc = usdc_;
        usdfr = usdfr_;
        compliance = compliance_;
        controller = controller_;
        vault = vault_;
        points = points_;
        complianceAdmin = complianceAdmin_;

        vm.prank(admin_);
        vault.setRedemptionQueue(address(this)); // handler acts as the queue for burns

        for (uint256 i = 0; i < 4; ++i) {
            wallets[i] = makeAddr(string(abi.encodePacked("pw", i)));
        }
        // KYC every wallet (needed to MINT/REDEEM at the primary gate); transfers are
        // permissionless. The idle wallet is KYC'd but never funded.
        vm.startPrank(complianceAdmin_);
        compliance.setAllowed(address(this), true);
        compliance.setAllowed(IDLE_WALLET, true);
        for (uint256 i = 0; i < 4; ++i) {
            compliance.setAllowed(wallets[i], true);
        }
        vm.stopPrank();
    }

    // ── ops ──────────────────────────────────────────────────────────────

    function stakeShares(uint256 walletSeed, uint256 amount) external {
        address w = wallets[walletSeed % 4];
        amount = bound(amount, 1e6, 5_000_000e6);
        usdc.mint(w, amount);
        vm.startPrank(w);
        usdc.approve(address(controller), amount);
        uint256 minted = controller.mint(amount);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, w);
        vm.stopPrank();
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = wallets[fromSeed % 4];
        address to = wallets[toSeed % 4];
        uint256 bal = vault.balanceOf(from);
        if (bal == 0 || from == to) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        vault.transfer(to, amount);
    }

    function exitShares(uint256 walletSeed, uint256 amount) external {
        address w = wallets[walletSeed % 4];
        uint256 bal = vault.balanceOf(w);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(w);
        vault.transfer(address(this), amount);
        vault.redeem(amount, address(this), address(this));
    }

    function holdUsdfr(uint256 walletSeed, uint256 amount) external {
        address w = wallets[walletSeed % 4];
        amount = bound(amount, 1e6, 5_000_000e6);
        usdc.mint(w, amount);
        vm.startPrank(w);
        usdc.approve(address(controller), amount);
        controller.mint(amount); // w holds USDfr (accrues at 3x)
        vm.stopPrank();
    }

    function transferUsdfr(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = wallets[fromSeed % 4];
        address to = wallets[toSeed % 4];
        uint256 bal = usdfr.balanceOf(from);
        if (bal == 0 || from == to) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        usdfr.transfer(to, amount);
    }

    function redeemUsdfr(uint256 walletSeed, uint256 amount) external {
        address w = wallets[walletSeed % 4];
        uint256 bal = usdfr.balanceOf(w);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        // redeem needs whole stable units; floor to 1e12 (18->6 dec)
        amount = (amount / 1e12) * 1e12;
        if (amount == 0) return;
        vm.prank(w);
        controller.redeem(amount);
    }

    function pokeCheckpoint(uint256 walletSeed) external {
        points.checkpoint(wallets[walletSeed % 4]);
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 200 days);
        vm.warp(block.timestamp + secs);
    }

    // ── reconciliation views ─────────────────────────────────────────────

    function walletCount() external pure returns (uint256) {
        return 4;
    }

    function walletAt(uint256 i) external view returns (address) {
        return wallets[i];
    }

    function recordSeenPoints(address wallet, uint256 value) external {
        lastSeenPoints[wallet] = value;
    }
}
