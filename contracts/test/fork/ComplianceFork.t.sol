// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ComplianceFork — the 2026-07-14 compliance posture, proved on real deployed contracts
/// @notice The directive is narrow and easy to get wrong in either direction:
///
///           * KYC (`allowed`) gates the PRIMARY path ONLY — `MintRedeemController.mint` and
///             `.redeem`. It must never touch holding, transferring, staking, queueing or
///             claiming.
///           * SANCTIONS (`blocked`) are the ONLY on-chain transfer restriction, and they apply
///             to USDfr and sUSDfr in both directions.
///           * The sanctions check PRECEDES the protocol exemption (audit R2-H-01), so a
///             sanctioned wallet cannot launder value out through an exempt module.
///           * Every internal value-moving module is `protocolExempt`, so a COMPLIANCE_ADMIN
///             list error can never brick the never-pausable cascade / settlement / rewards.
///
///         Each of those four is pinned below against the FULL stack deployed by the real
///         `Deploy.s.sol` onto a pinned mainnet fork, against REAL USDC.
///
/// @dev Every test carries `onFork`, so a run without an RPC key SKIPS — it can never be
///      mistaken for a pass. Nothing here is modified outside this file.
contract ComplianceForkTest is ForkLifecycleFixture {
    // ── local helpers (this file only; the shared fixture is not modified) ────────────

    /// @dev Warp past both the epoch heartbeat and the ADR-0022 redemption cooldown, then
    ///      settle. Returns the amount the request became entitled to.
    function _settleQueue(uint256 reqId) private returns (uint256 claimable) {
        _warp(uint256(Config.DEFAULT_REDEEM_COOLDOWN) + uint256(Config.DEFAULT_EPOCH_DURATION) + 1);
        queue.closeEpoch(50);
        (,, claimable,,) = queue.request(reqId);
    }

    /// @dev Put `who`'s vault shares into the redemption queue.
    function _queue(address who, uint256 shares) private returns (uint256 reqId) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        reqId = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 1. TOPOLOGY — what the real deploy actually wired
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice The exemption set and role topology the deploy script produced, asserted
    ///         address-by-address. The NEGATIVE half matters as much as the positive: an
    ///         over-broad exemption set would silently disable the sanctions freeze for
    ///         whatever it covered.
    function test_fork_complianceTopologyAsDeployed() public onFork {
        // USDfr's sole transfer gate must be wired, or `canTransfer` is never consulted.
        assertEq(usdfr.complianceModule(), address(compliance), "USDfr -> ComplianceRegistry wired");

        // EXEMPT: every internal value-moving module, plus the fee recipient.
        assertTrue(compliance.isProtocolExempt(address(vault)), "vault exempt");
        assertTrue(compliance.isProtocolExempt(address(queue)), "queue exempt");
        assertTrue(compliance.isProtocolExempt(address(reserves)), "reserves exempt");
        assertTrue(compliance.isProtocolExempt(address(controller)), "controller exempt");
        assertTrue(compliance.isProtocolExempt(address(curator)), "curator exempt");
        assertTrue(compliance.isProtocolExempt(address(sGrove)), "sGrove exempt");
        assertTrue(compliance.isProtocolExempt(address(defaultManager)), "defaultManager exempt");
        assertTrue(compliance.isProtocolExempt(address(waterfall)), "waterfall exempt");
        assertTrue(compliance.isProtocolExempt(ops), "feeRecipient exempt (== ops in this shape)");

        // NOT EXEMPT: modules that never hold or move USDfr/sUSDfr. Exemption is a hole in
        // the sanctions net, so anything that does not need it must not have it.
        assertFalse(compliance.isProtocolExempt(address(points)), "points not exempt");
        assertFalse(compliance.isProtocolExempt(address(bridge)), "bridge not exempt");
        assertFalse(compliance.isProtocolExempt(address(registry)), "registry not exempt");
        assertFalse(compliance.isProtocolExempt(address(oracle)), "oracle not exempt");
        assertFalse(compliance.isProtocolExempt(address(grove)), "grove not exempt");
        assertFalse(compliance.isProtocolExempt(timelock), "timelock not exempt");
        assertFalse(compliance.isProtocolExempt(alice), "an ordinary user is not exempt");

        // Roles: list admin is operational, exemption + upgrade are governance.
        bytes32 defaultAdmin = compliance.DEFAULT_ADMIN_ROLE();
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, ops), "ops is COMPLIANCE_ADMIN");
        assertTrue(compliance.hasRole(defaultAdmin, ops), "fixture keeps DEFAULT_ADMIN with ops");
        assertTrue(compliance.hasRole(Roles.UPGRADER_ROLE, timelock), "upgrade authority is the timelock");
        assertFalse(compliance.hasRole(Roles.UPGRADER_ROLE, ops), "ops cannot upgrade");
        assertFalse(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, alice), "a user is not a list admin");

        // KYC state as seeded.
        assertTrue(compliance.isAllowed(alice), "alice KYC'd");
        assertTrue(compliance.isAllowed(bob), "bob KYC'd");
        assertFalse(compliance.isAllowed(carol), "carol NOT KYC'd");
        assertFalse(compliance.isJurisdictionBlocked(carol), "carol not sanctioned, merely un-KYC'd");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 2. KYC GATES THE PRIMARY PATH — AND NOTHING ELSE
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice Non-KYC `carol` cannot MINT. Exact error, exact argument.
    function test_fork_kyc_nonKycCannotMint() public onFork {
        vm.startPrank(carol);
        IERC20(USDC).approve(address(controller), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.mint(10_000e6);
        vm.stopPrank();

        assertEq(usdfr.balanceOf(carol), 0, "no USDfr minted");
        assertEq(IERC20(USDC).balanceOf(carol), 1_000_000e6, "carol's real USDC untouched");
    }

    /// @notice Non-KYC `carol` cannot REDEEM even while HOLDING USDfr she legitimately received
    ///         by transfer. This is the exact shape of the directive: the secondary market is
    ///         open, the primary window is not.
    function test_fork_kyc_nonKycCannotRedeemButMayHold() public onFork {
        _mintFromUSDC(alice, 100_000e6);
        vm.prank(alice);
        usdfr.transfer(carol, 40_000e18);
        assertEq(usdfr.balanceOf(carol), 40_000e18, "non-KYC carol HOLDS USDfr");

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.redeem(10_000e18);

        assertEq(usdfr.balanceOf(carol), 40_000e18, "balance untouched by the failed redeem");
    }

    /// @notice Non-KYC addresses transfer USDfr freely — as SENDER and as RECIPIENT, and
    ///         between two non-KYC parties. KYC status must not appear in `canTransfer` at all.
    function test_fork_kyc_nonKycTransfersUSDfrFreely() public onFork {
        address dave = makeAddr("forkDave"); // also never KYC'd
        _mintFromUSDC(alice, 200_000e6);

        // KYC'd -> non-KYC
        vm.prank(alice);
        usdfr.transfer(carol, 50_000e18);
        assertEq(usdfr.balanceOf(carol), 50_000e18, "KYC'd -> non-KYC allowed");

        // non-KYC -> non-KYC (neither party has ever been through KYC)
        vm.prank(carol);
        usdfr.transfer(dave, 20_000e18);
        assertEq(usdfr.balanceOf(dave), 20_000e18, "non-KYC -> non-KYC allowed");
        assertEq(usdfr.balanceOf(carol), 30_000e18, "sender debited exactly");

        // non-KYC -> KYC'd
        vm.prank(dave);
        usdfr.transfer(bob, 20_000e18);
        assertEq(usdfr.balanceOf(bob), 20_000e18, "non-KYC -> KYC'd allowed");
        assertEq(usdfr.balanceOf(dave), 0, "sender fully debited");

        // ERC-20 approval/transferFrom path is equally ungated.
        vm.prank(carol);
        usdfr.approve(dave, 30_000e18);
        vm.prank(dave);
        usdfr.transferFrom(carol, dave, 30_000e18);
        assertEq(usdfr.balanceOf(dave), 30_000e18, "transferFrom by a non-KYC spender allowed");
        assertEq(usdfr.balanceOf(carol), 0, "carol fully debited");

        // And the registry agrees, directly.
        assertTrue(compliance.canTransfer(address(usdfr), carol, dave), "canTransfer ignores KYC");
        assertFalse(compliance.isAllowed(carol), "...even though neither is allowlisted");
        assertFalse(compliance.isAllowed(dave), "...neither of them");
    }

    /// @notice Non-KYC `carol` can STAKE, TRANSFER SHARES, QUEUE an exit and CLAIM USDfr — the
    ///         entire secondary lifecycle — while still being refused at the redeem window.
    ///         Staking is deliberately NOT the KYC gate (sUSDfr `_deposit` is permissionless).
    function test_fork_kyc_nonKycStakesTransfersSharesAndExitsQueue() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        vm.prank(alice);
        usdfr.transfer(carol, 300_000e18);

        // STAKE — permissionless.
        uint256 shares = _stake(carol, 300_000e18);
        assertGt(shares, 0, "non-KYC carol received vault shares");
        assertEq(vault.balanceOf(carol), shares, "shares credited to carol");

        // TRANSFER SHARES — permissionless, both directions.
        vm.prank(carol);
        vault.transfer(bob, 1_000);
        assertEq(vault.balanceOf(bob), 1_000, "non-KYC -> KYC'd share transfer allowed");
        vm.prank(bob);
        vault.transfer(carol, 1_000);
        assertEq(vault.balanceOf(carol), shares, "KYC'd -> non-KYC share transfer allowed");

        // QUEUE + CLAIM — permissionless.
        uint256 reqId = _queue(carol, shares);
        uint256 claimable = _settleQueue(reqId);
        assertGt(claimable, 0, "non-KYC request settled normally");

        uint256 before = usdfr.balanceOf(carol);
        vm.prank(carol);
        uint256 paid = queue.claim(reqId);
        assertEq(paid, claimable, "claim paid exactly the settled amount");
        assertEq(usdfr.balanceOf(carol) - before, claimable, "USDfr delivered to a non-KYC claimant");

        // ...but the primary window is still shut.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.redeem(1_000e18);
    }

    /// @notice Revoking KYC closes the primary window immediately and touches nothing else.
    function test_fork_kyc_revocationClosesPrimaryOnly() public onFork {
        uint256 minted = _mintFromUSDC(alice, 100_000e6);
        assertEq(minted, 100_000e18, "6-dec USDC normalized to 18-dec");

        compliance.setAllowed(alice, false);
        assertFalse(compliance.isAllowed(alice), "KYC revoked");

        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, alice));
        controller.mint(1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, alice));
        controller.redeem(1_000e18);
        vm.stopPrank();

        // Secondary is untouched: she may still move and stake what she holds.
        vm.prank(alice);
        usdfr.transfer(bob, 10_000e18);
        assertEq(usdfr.balanceOf(bob), 10_000e18, "de-KYC'd holder may still transfer");
        uint256 shares = _stake(alice, 10_000e18);
        assertGt(shares, 0, "de-KYC'd holder may still stake");

        // Re-allow and the window reopens — exact round trip.
        compliance.setAllowed(alice, true);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        usdfr.approve(address(controller), 5_000e18);
        uint256 out = controller.redeem(5_000e18);
        vm.stopPrank();
        assertEq(out, 5_000e6, "18-dec USDfr denormalizes to 6-dec USDC");
        assertEq(IERC20(USDC).balanceOf(alice) - usdcBefore, 5_000e6, "real USDC returned");
    }

    /// @notice `isAllowed = allowed && !blocked` — a sanctions block overrides an allowlist
    ///         entry at the primary gate, so a sanctioned KYC'd user cannot mint or redeem.
    function test_fork_kyc_blockOverridesAllowlistAtPrimaryGate() public onFork {
        _mintFromUSDC(alice, 50_000e6);
        assertTrue(compliance.isAllowed(alice), "allowlisted before");

        compliance.setJurisdictionBlocked(alice, true);
        assertTrue(compliance.isJurisdictionBlocked(alice), "sanctioned");
        assertFalse(compliance.isAllowed(alice), "allowlist entry is overridden by the block");

        vm.startPrank(alice);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, alice));
        controller.mint(1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, alice));
        controller.redeem(1_000e18);
        vm.stopPrank();
    }

    /// @notice Protocol exemption is NOT a KYC bypass. `ops` is `protocolExempt` (it is the fee
    ///         recipient), so its transfers survive a block — but the primary gate reads
    ///         `isAllowed`, which the exemption does not touch.
    function test_fork_exemptionIsNotAKycBypass() public onFork {
        assertTrue(compliance.isProtocolExempt(ops), "ops is exempt (fee recipient)");
        _mintFromUSDC(ops, 20_000e6);

        compliance.setJurisdictionBlocked(ops, true);

        // Transfers survive (exempt party) ...
        assertTrue(compliance.canTransfer(address(usdfr), ops, alice), "exempt sender still permitted");
        vm.prank(ops);
        usdfr.transfer(alice, 1_000e18);
        assertEq(usdfr.balanceOf(alice), 1_000e18, "exempt-but-blocked party still transfers");

        // ... the primary gate does not.
        vm.startPrank(ops);
        IERC20(USDC).approve(address(controller), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, ops));
        controller.mint(1_000e6);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 3. SANCTIONS ARE THE ONLY TRANSFER RESTRICTION
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice A sanctioned address can neither SEND nor RECEIVE USDfr; unblocking restores
    ///         both. Exact custom error with exact `(from,to)` arguments.
    function test_fork_sanctions_blockedCannotSendOrReceiveUSDfr() public onFork {
        _mintFromUSDC(alice, 100_000e6);
        _mintFromUSDC(bob, 100_000e6);

        compliance.setJurisdictionBlocked(alice, true);

        // SEND blocked.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, bob));
        usdfr.transfer(bob, 1e18);

        // RECEIVE blocked.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, bob, alice));
        usdfr.transfer(alice, 1e18);

        // transferFrom is gated identically (the gate lives in `_update`, not the entrypoint).
        vm.prank(bob);
        usdfr.approve(carol, 1e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, bob, alice));
        usdfr.transferFrom(bob, alice, 1e18);

        // Balances unmoved.
        assertEq(usdfr.balanceOf(alice), 100_000e18, "alice's balance frozen, not seized");
        assertEq(usdfr.balanceOf(bob), 100_000e18, "bob unaffected");

        // Unblock -> both directions restored.
        compliance.setJurisdictionBlocked(alice, false);
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        vm.prank(bob);
        usdfr.transfer(alice, 2e18);
        assertEq(usdfr.balanceOf(alice), 100_000e18 - 1e18 + 2e18, "exact balance after the round trip");
    }

    /// @notice The same freeze applies to sUSDfr SHARES, with the vault's own error.
    function test_fork_sanctions_blockedCannotSendOrReceiveShares() public onFork {
        _mintFromUSDC(alice, 500_000e6);
        _mintFromUSDC(bob, 500_000e6);
        uint256 aliceShares = _stake(alice, 200_000e18);
        _stake(bob, 200_000e18);

        compliance.setJurisdictionBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_TransferBlocked.selector, alice, bob));
        vault.transfer(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_TransferBlocked.selector, bob, alice));
        vault.transfer(alice, 1);

        assertEq(vault.balanceOf(alice), aliceShares, "shares frozen, not seized");

        // A blocked party cannot MINT new shares either (the share mint is `from == 0`,
        // `to == blocked`) — and it fails on the USDfr leg first, which is the earlier gate.
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, address(vault)));
        vault.deposit(1_000e18, alice);
        vm.stopPrank();

        compliance.setJurisdictionBlocked(alice, false);
        vm.prank(alice);
        vault.transfer(bob, 5);
        assertEq(vault.balanceOf(alice), aliceShares - 5, "restored after unblock");
    }

    /// @notice BURNS are never blockable (`to == address(0)` short-circuits) — otherwise a
    ///         sanctions entry could stall the loss cascade or a redemption settlement.
    /// @dev The only USDfr burn authority is MINTER/BURNER (the controller and the credit
    ///      modules), and every USER path to a burn is KYC-gated first, so a burn FROM a
    ///      sanctioned wallet is unreachable through a user call. To exercise the token gate
    ///      itself we prank the REAL MINTER_ROLE holder (the deployed controller) — that is a
    ///      faithful stand-in for the cascade's `burnLoss`, which is exactly this call.
    function test_fork_sanctions_burnsAreNeverBlocked() public onFork {
        _mintFromUSDC(alice, 10_000e6);
        compliance.setJurisdictionBlocked(alice, true);

        assertTrue(compliance.canTransfer(address(usdfr), alice, address(0)), "burn from a blocked wallet allowed");
        assertTrue(compliance.canTransfer(address(usdfr), address(0), address(0)), "zero-to-zero allowed");

        uint256 supplyBefore = usdfr.totalSupply();
        vm.prank(address(controller));
        usdfr.burn(alice, 4_000e18);
        assertEq(usdfr.balanceOf(alice), 6_000e18, "burn executed against a sanctioned holder");
        assertEq(usdfr.totalSupply(), supplyBefore - 4_000e18, "supply fell by exactly the burn");
    }

    /// @notice GROVE is NOT sanctions-gated. Asserted so the boundary is explicit and
    ///         reviewable rather than assumed: `GroveToken._update` consults no compliance
    ///         module, so a sanctioned wallet can still move the governance token (and stake
    ///         it). The freeze covers the value-bearing instruments (USDfr, sUSDfr) only.
    function test_fork_sanctions_groveTokenIsNotGated() public onFork {
        vm.prank(ops);
        grove.transfer(alice, 1_000e18);
        compliance.setJurisdictionBlocked(alice, true);

        vm.prank(alice);
        grove.transfer(bob, 400e18);
        assertEq(grove.balanceOf(bob), 400e18, "GROVE moves despite the sanctions entry (documented gap)");
        assertEq(grove.balanceOf(alice), 600e18, "sender debited exactly");

        // And a sanctioned holder can still stake GROVE into sGROVE (no USDfr leg on entry).
        vm.startPrank(alice);
        grove.approve(address(sGrove), 600e18);
        sGrove.stake(600e18);
        vm.stopPrank();
        assertEq(sGrove.stakedOf(alice), 600e18, "sanctioned wallet can still take a backstop position");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 4. R2-H-01 — SANCTIONS PRECEDE THE PROTOCOL EXEMPTION
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice The registry-level statement of R2-H-01: the exempt counterparty does NOT
    ///         rescue a sanctioned party, in either direction. If the exemption were checked
    ///         first (the pre-fix ordering) every one of these would return `true`.
    function test_fork_r2h01_exemptCounterpartyDoesNotRescueABlockedParty() public onFork {
        compliance.setJurisdictionBlocked(alice, true);

        address[8] memory mods = [
            address(vault),
            address(queue),
            address(reserves),
            address(controller),
            address(curator),
            address(sGrove),
            address(defaultManager),
            address(waterfall)
        ];
        for (uint256 i = 0; i < mods.length; ++i) {
            assertTrue(compliance.isProtocolExempt(mods[i]), "module is exempt");
            assertFalse(compliance.canTransfer(address(usdfr), alice, mods[i]), "blocked -> exempt module DENIED");
            assertFalse(compliance.canTransfer(address(usdfr), mods[i], alice), "exempt module -> blocked DENIED");
            // The module itself is never treated as blocked when talking to a clean party.
            assertTrue(compliance.canTransfer(address(usdfr), mods[i], bob), "exempt module -> clean allowed");
            assertTrue(compliance.canTransfer(address(usdfr), bob, mods[i]), "clean -> exempt module allowed");
        }
    }

    /// @notice R2-H-01, live, on the ENTRY leg: a sanctioned wallet cannot push value INTO the
    ///         exempt vault, queue or curator module.
    function test_fork_r2h01_blockedCannotRouteValueIntoExemptModules() public onFork {
        _mintFromUSDC(alice, 500_000e6);
        uint256 shares = _stake(alice, 200_000e18);
        compliance.setJurisdictionBlocked(alice, true);

        // vault deposit
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, address(vault)));
        vault.deposit(1_000e18, alice);
        vm.stopPrank();

        // queue entry (share custody transfer alice -> queue)
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_TransferBlocked.selector, alice, address(queue)));
        queue.requestRedeem(shares);
        vm.stopPrank();

        // curator first-loss posting (USDfr alice -> curator)
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, alice, true);
        vm.startPrank(alice);
        usdfr.approve(address(curator), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, address(curator)));
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1_000e18);
        vm.stopPrank();
    }

    /// @notice R2-H-01, live, on the EXIT leg — the attack the fix exists to stop. Alice queues
    ///         an exit while clean, is then sanctioned. Settlement (a module-to-module leg) must
    ///         STILL complete — the queue is never-pausable — but the final payout to the
    ///         sanctioned wallet must be refused. Unblocking pays exactly the settled amount.
    function test_fork_r2h01_blockedCannotExitThroughTheExemptQueue() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shares = _stake(alice, 400_000e18);
        uint256 reqId = _queue(alice, shares);

        compliance.setJurisdictionBlocked(alice, true);

        // SETTLEMENT still runs: vault -> queue is exempt-to-exempt, so a sanctions entry
        // cannot brick the queue for everybody else.
        uint256 claimable = _settleQueue(reqId);
        assertGt(claimable, 0, "settlement completed despite the sanctions entry");

        // But the payout leg queue -> alice is refused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(queue), alice));
        queue.claim(reqId);

        (,, uint256 stillClaimable,,) = queue.request(reqId);
        assertEq(stillClaimable, claimable, "the claim is preserved, not consumed by the failed attempt");

        // Delisted -> paid, exactly.
        compliance.setJurisdictionBlocked(alice, false);
        uint256 before = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = queue.claim(reqId);
        assertEq(paid, claimable, "paid exactly the settled amount");
        assertEq(usdfr.balanceOf(alice) - before, claimable, "delivered to the wallet");
        (,, uint256 afterClaim,,) = queue.request(reqId);
        assertEq(afterClaim, 0, "no double-claim");
    }

    /// @notice R2-H-01 on the sGROVE reward leg: a sanctioned backstop staker cannot pull
    ///         accrued USDfr rewards out of the exempt sGROVE module.
    function test_fork_r2h01_blockedCannotPullRewardsFromExemptSGrove() public onFork {
        _mintFromUSDC(ops, 500_000e6);
        vm.prank(ops);
        grove.transfer(alice, 1_000e18);

        vm.startPrank(alice);
        grove.approve(address(sGrove), 1_000e18);
        sGrove.stake(1_000e18);
        vm.stopPrank();

        vm.startPrank(ops);
        usdfr.approve(address(sGrove), 70_000e18);
        sGrove.notifyRewards(70_000e18);
        vm.stopPrank();
        _warp(Config.SGROVE_REWARDS_DURATION);

        uint256 pending = sGrove.pendingRewards(alice);
        assertGt(pending, 0, "rewards accrued to the staker");

        compliance.setJurisdictionBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(sGrove), alice));
        sGrove.claimRewards();

        compliance.setJurisdictionBlocked(alice, false);
        vm.prank(alice);
        uint256 claimed = sGrove.claimRewards();
        assertEq(claimed, pending, "claimed exactly what had accrued");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 5. THE EXEMPTION MUST MAKE THE PROTOCOL UN-FREEZABLE
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice THE HEADLINE OF THIS FILE. A COMPLIANCE_ADMIN sanctions EVERY protocol module —
    ///         the worst-case list error, or a captured/compromised list admin. Because every
    ///         module is `protocolExempt`, the whole protocol must still run: mint, stake,
    ///         originate, fund, repay+waterfall, default, the three-layer cascade, epoch
    ///         settlement and claim. Nothing here may revert.
    function test_fork_blockingEveryModuleCannotFreezeTheProtocol() public onFork {
        // Pre-position capital while the lists are clean.
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(ops, 500_000e6);
        uint256 shares = _stake(alice, 800_000e18);
        vm.startPrank(ops);
        usdfr.approve(address(curator), 100_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 100_000e18);
        usdfr.approve(address(sGrove), 150_000e18);
        sGrove.fundCoverage(150_000e18);
        vm.stopPrank();

        // Sanction every module.
        address[8] memory mods = [
            address(vault),
            address(queue),
            address(reserves),
            address(controller),
            address(curator),
            address(sGrove),
            address(defaultManager),
            address(waterfall)
        ];
        for (uint256 i = 0; i < mods.length; ++i) {
            compliance.setJurisdictionBlocked(mods[i], true);
            assertTrue(compliance.isJurisdictionBlocked(mods[i]), "module listed as blocked");
        }

        // MINT still works (a clean user into an exempt controller/reserves).
        uint256 minted = _mintFromUSDC(bob, 300_000e6);
        assertEq(minted, 300_000e18, "mint unaffected by module blocks");

        // STAKE still works.
        uint256 bobShares = _stake(bob, 100_000e18);
        assertGt(bobShares, 0, "stake unaffected");

        // ORIGINATE + FUND still work.
        uint256 tokenId = _originateAndFund(400_000e18);
        assertEq(bridge.ownerOf(tokenId), ops, "facility minted");

        // REPAY -> waterfall (yield mint into the blocked-but-exempt vault) still works.
        uint256 vaultHeldBefore = usdfr.balanceOf(address(vault));
        _repay(tokenId, 20_000e18, 50_000e18);
        assertGt(usdfr.balanceOf(address(vault)) - vaultHeldBefore, 0, "interest reached the vault");
        assertEq(vault.unvestedYield(), 0, "launch recognizes the senior yield immediately");

        // THE CASCADE still works — the thing that must never be pausable.
        uint256 coverageBefore = sGrove.coverageReserve();
        uint256 vaultAssetsBefore = vault.totalAssets();
        _declareDefault(tokenId, bytes32(0));
        _realizeLoss(tokenId, 300_000e18, bytes32(0));
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "layer 1 absorbed first");
        assertLt(sGrove.coverageReserve(), coverageBefore, "layer 2 drew next");
        assertLt(vault.totalAssets(), vaultAssetsBefore, "layer 3 took the residual");

        // SETTLEMENT + CLAIM still work, to a clean wallet.
        uint256 reqId = _queue(alice, shares / 4);
        uint256 claimable = _settleQueue(reqId);
        assertGt(claimable, 0, "epoch settled with every module blocked");
        uint256 before = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = queue.claim(reqId);
        assertEq(paid, claimable, "claim paid in full");
        assertEq(usdfr.balanceOf(alice) - before, claimable, "delivered");

        // And the backing invariant survived the whole thing.
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    /// @notice De-listing a module (the upgrade path the toggle exists for) DOES take the
    ///         exemption away — proving the exemption is live state, not a compile-time
    ///         constant, and that the previous test was not vacuous.
    function test_fork_exemptionIsLiveState_delistingReimposesTheFreeze() public onFork {
        _mintFromUSDC(alice, 100_000e6);
        compliance.setJurisdictionBlocked(address(vault), true);

        // Exempt: unaffected.
        assertTrue(compliance.canTransfer(address(usdfr), alice, address(vault)), "exempt while listed");
        uint256 shares = _stake(alice, 10_000e18);
        assertGt(shares, 0, "deposit succeeded under the exemption");

        // De-list the module while it is still on the sanctions list -> now frozen.
        compliance.setProtocolExempt(address(vault), false);
        assertFalse(compliance.isProtocolExempt(address(vault)), "exemption removed");
        assertFalse(compliance.canTransfer(address(usdfr), alice, address(vault)), "freeze now bites");
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10_000e18);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, address(vault)));
        vault.deposit(10_000e18, alice);
        vm.stopPrank();

        // Restore.
        compliance.setProtocolExempt(address(vault), true);
        uint256 more = _stake(alice, 10_000e18);
        assertGt(more, 0, "restored");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 6. `canTransfer` TRUTH TABLE
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice The complete decision table of the deployed registry, asserted exhaustively,
    ///         including that the `token` argument is inert (retained for ABI stability only).
    function test_fork_canTransferTruthTable() public onFork {
        address dave = makeAddr("forkDave"); // unknown to every list
        compliance.setJurisdictionBlocked(carol, true); // sanctioned, never KYC'd
        compliance.setJurisdictionBlocked(bob, true); // sanctioned, IS KYC'd

        // clean <-> clean
        assertTrue(compliance.canTransfer(address(usdfr), alice, dave), "KYC'd -> unknown");
        assertTrue(compliance.canTransfer(address(usdfr), dave, alice), "unknown -> KYC'd");
        assertTrue(compliance.canTransfer(address(usdfr), dave, dave), "self-transfer");

        // blocked as sender / recipient, regardless of KYC status
        assertFalse(compliance.canTransfer(address(usdfr), carol, alice), "blocked non-KYC sender");
        assertFalse(compliance.canTransfer(address(usdfr), alice, carol), "blocked non-KYC recipient");
        assertFalse(compliance.canTransfer(address(usdfr), bob, alice), "blocked KYC'd sender");
        assertFalse(compliance.canTransfer(address(usdfr), alice, bob), "blocked KYC'd recipient");
        assertFalse(compliance.canTransfer(address(usdfr), bob, carol), "both blocked");

        // burns are unconditional
        assertTrue(compliance.canTransfer(address(usdfr), carol, address(0)), "blocked burn");
        assertTrue(compliance.canTransfer(address(usdfr), alice, address(0)), "clean burn");

        // mints (from == 0) follow the recipient only
        assertTrue(compliance.canTransfer(address(usdfr), address(0), alice), "mint to a clean wallet");
        assertFalse(compliance.canTransfer(address(usdfr), address(0), carol), "mint to a blocked wallet DENIED");

        // exemption rescues the MODULE, never the sanctioned counterparty
        assertTrue(compliance.canTransfer(address(usdfr), address(vault), alice), "exempt -> clean");
        assertFalse(compliance.canTransfer(address(usdfr), address(vault), carol), "exempt -> blocked DENIED");
        assertFalse(compliance.canTransfer(address(usdfr), carol, address(vault)), "blocked -> exempt DENIED");

        // the `token` argument is inert
        assertEq(
            compliance.canTransfer(address(usdfr), alice, carol),
            compliance.canTransfer(address(0), alice, carol),
            "token arg does not change the answer (blocked case)"
        );
        assertEq(
            compliance.canTransfer(DAI, alice, dave),
            compliance.canTransfer(address(vault), alice, dave),
            "token arg does not change the answer (clean case)"
        );
    }

    /// @notice Fuzzed statement of the same rule, so it holds on inputs nobody enumerated:
    ///         `canTransfer` is exactly "to == 0, or neither party is (blocked && !exempt)".
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_fork_canTransferMatchesTheSpec(address from, address to, bool blockFrom, bool blockTo)
        public
        onFork
    {
        vm.assume(from != address(0) && to != address(0));
        vm.assume(from != to);
        // Keep the fuzzer off addresses whose list state the deploy already set.
        vm.assume(!compliance.isProtocolExempt(from) && !compliance.isProtocolExempt(to));
        vm.assume(!compliance.isJurisdictionBlocked(from) && !compliance.isJurisdictionBlocked(to));

        if (blockFrom) compliance.setJurisdictionBlocked(from, true);
        if (blockTo) compliance.setJurisdictionBlocked(to, true);

        assertEq(compliance.canTransfer(address(usdfr), from, to), !(blockFrom || blockTo), "spec: transfer");
        assertTrue(compliance.canTransfer(address(usdfr), from, address(0)), "spec: burns always allowed");
        // KYC never enters the transfer decision.
        compliance.setAllowed(from, true);
        assertEq(compliance.canTransfer(address(usdfr), from, to), !(blockFrom || blockTo), "KYC is not consulted");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 7. ROLE GATING — AUTHORIZED **AND** UNAUTHORIZED CALLER FOR EVERY MUTATOR
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice `setAllowed`: COMPLIANCE_ADMIN only, event asserted, zero address rejected.
    function test_fork_roleGate_setAllowed() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        compliance.setAllowed(carol, true);
        assertFalse(compliance.isAllowed(carol), "unauthorized call changed nothing");

        // A DEFAULT_ADMIN that is not a COMPLIANCE_ADMIN is also refused (roles do not nest).
        address govOnly = makeAddr("forkGovOnly");
        compliance.grantRole(compliance.DEFAULT_ADMIN_ROLE(), govOnly);
        vm.prank(govOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, govOnly, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        compliance.setAllowed(carol, true);

        // Authorized.
        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.AllowlistUpdated(carol, true);
        compliance.setAllowed(carol, true);
        assertTrue(compliance.isAllowed(carol), "authorized call took effect");

        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.AllowlistUpdated(carol, false);
        compliance.setAllowed(carol, false);
        assertFalse(compliance.isAllowed(carol), "revocation took effect");

        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setAllowed(address(0), true);
    }

    /// @notice `setJurisdictionBlocked`: COMPLIANCE_ADMIN only, event asserted, zero rejected.
    function test_fork_roleGate_setJurisdictionBlocked() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        compliance.setJurisdictionBlocked(alice, true);
        assertFalse(compliance.isJurisdictionBlocked(alice), "unauthorized call changed nothing");

        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.JurisdictionBlockUpdated(alice, true);
        compliance.setJurisdictionBlocked(alice, true);
        assertTrue(compliance.isJurisdictionBlocked(alice), "listed");

        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.JurisdictionBlockUpdated(alice, false);
        compliance.setJurisdictionBlocked(alice, false);
        assertFalse(compliance.isJurisdictionBlocked(alice), "de-listed");

        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setJurisdictionBlocked(address(0), true);
    }

    /// @notice `setAllowedBatch`: role-gated, applies to every entry, rejects a zero entry
    ///         WHOLESALE (the earlier entries in the same call are rolled back).
    function test_fork_roleGate_setAllowedBatch() public onFork {
        address[] memory batch = new address[](3);
        batch[0] = carol;
        batch[1] = makeAddr("forkBatch1");
        batch[2] = makeAddr("forkBatch2");

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        compliance.setAllowedBatch(batch, true);

        compliance.setAllowedBatch(batch, true);
        assertTrue(compliance.isAllowed(batch[0]), "batch entry 0 allowed");
        assertTrue(compliance.isAllowed(batch[1]), "batch entry 1 allowed");
        assertTrue(compliance.isAllowed(batch[2]), "batch entry 2 allowed");

        // Non-KYC carol is now KYC'd purely by the batch, and can mint.
        uint256 minted = _mintFromUSDC(carol, 1_000e6);
        assertEq(minted, 1_000e18, "batch onboarding opened the primary window");

        compliance.setAllowedBatch(batch, false);
        assertFalse(compliance.isAllowed(batch[0]), "batch revocation entry 0");
        assertFalse(compliance.isAllowed(batch[2]), "batch revocation entry 2");

        // A zero address anywhere reverts the whole batch.
        address[] memory bad = new address[](2);
        bad[0] = makeAddr("forkBatch3");
        bad[1] = address(0);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setAllowedBatch(bad, true);
        assertFalse(compliance.isAllowed(bad[0]), "the valid entry was rolled back too");
    }

    /// @notice `setProtocolExempt` is DEFAULT_ADMIN (timelocked governance) — strictly ABOVE
    ///         the list admin. A COMPLIANCE_ADMIN who is not also DEFAULT_ADMIN must not be
    ///         able to punch a hole in the sanctions net, nor to remove a module's protection.
    function test_fork_roleGate_setProtocolExempt() public onFork {
        bytes32 defaultAdmin = compliance.DEFAULT_ADMIN_ROLE();

        // A pure list admin cannot touch exemptions.
        address listAdmin = makeAddr("forkListAdmin");
        compliance.grantRole(Roles.COMPLIANCE_ADMIN_ROLE, listAdmin);
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, listAdmin), "is a list admin");
        assertFalse(compliance.hasRole(defaultAdmin, listAdmin), "but not governance");

        vm.prank(listAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, listAdmin, defaultAdmin)
        );
        compliance.setProtocolExempt(carol, true);
        assertFalse(compliance.isProtocolExempt(carol), "no hole punched");

        vm.prank(listAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, listAdmin, defaultAdmin)
        );
        compliance.setProtocolExempt(address(vault), false);
        assertTrue(compliance.isProtocolExempt(address(vault)), "vault protection intact");

        // An unrelated caller likewise.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, defaultAdmin)
        );
        compliance.setProtocolExempt(carol, true);

        // Governance can.
        vm.expectEmit(true, false, false, true, address(compliance));
        emit ComplianceRegistry.ProtocolExemptUpdated(carol, true);
        compliance.setProtocolExempt(carol, true);
        assertTrue(compliance.isProtocolExempt(carol), "governance set the exemption");
        compliance.setProtocolExempt(carol, false);
        assertFalse(compliance.isProtocolExempt(carol), "and removed it");

        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setProtocolExempt(address(0), true);
    }

    /// @notice The registry's own upgrade authority is the TIMELOCK, not ops and not the list
    ///         admin; and an upgrade preserves every list (namespaced ERC-7201 storage).
    function test_fork_roleGate_upgradeIsTimelockOnlyAndPreservesLists() public onFork {
        compliance.setAllowed(carol, true);
        compliance.setJurisdictionBlocked(bob, true);
        address newImpl = address(new ComplianceRegistry());

        // Unauthorized: an ordinary wallet, and the DEFAULT_ADMIN (ops) — UPGRADER is separate.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.UPGRADER_ROLE)
        );
        compliance.upgradeToAndCall(newImpl, "");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, Roles.UPGRADER_ROLE)
        );
        compliance.upgradeToAndCall(newImpl, "");

        // Authorized: the timelock.
        vm.prank(timelock);
        compliance.upgradeToAndCall(newImpl, "");

        assertTrue(compliance.isAllowed(carol), "allowlist survived the upgrade");
        assertTrue(compliance.isJurisdictionBlocked(bob), "blocklist survived the upgrade");
        assertTrue(compliance.isProtocolExempt(address(vault)), "exemption set survived");
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, ops), "roles survived");
    }

    /// @notice The USDfr -> registry wiring is DEFAULT_ADMIN-only, and it is LOAD-BEARING:
    ///         with `complianceModule == address(0)` the token skips `canTransfer` entirely and
    ///         the sanctions freeze silently disappears. That is precisely the pre-redeploy
    ///         audit finding the deploy script's `setComplianceModule` call closes, so it is
    ///         pinned here rather than assumed — an unwired module is a governance-only
    ///         mistake, never a user-reachable one.
    function test_fork_usdfrRegistryWiringIsGovernanceOnlyAndLoadBearing() public onFork {
        _mintFromUSDC(alice, 50_000e6);
        compliance.setJurisdictionBlocked(alice, true);
        bytes32 defaultAdmin = usdfr.DEFAULT_ADMIN_ROLE();

        // Unauthorized cannot unwire it.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, defaultAdmin)
        );
        usdfr.setComplianceModule(address(0));
        assertEq(usdfr.complianceModule(), address(compliance), "still wired");

        // The freeze bites while wired.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, bob));
        usdfr.transfer(bob, 1e18);

        // Governance unwires -> the gate is gone (documented fail-open of an unset module).
        usdfr.setComplianceModule(address(0));
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        assertEq(usdfr.balanceOf(bob), 1e18, "an UNWIRED module leaves USDfr ungated");

        // Re-wire -> the freeze returns.
        usdfr.setComplianceModule(address(compliance));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, bob));
        usdfr.transfer(bob, 1e18);
    }

    /// @notice The settlement keeper is permissionless, and stays permissionless for a party
    ///         who is BOTH un-KYC'd and sanctioned. `closeEpoch` is the sole liveness path for
    ///         the sUSDfr exit; gating it on compliance state would hand an outage to the list.
    /// @dev AUDIT FIX (D7-01) — this test was `..._settlementKeeperIsPermissionlessEvenWhenSanctioned`
    ///      and used carol purely as a stand-in for "any address at all". `closeEpoch` is now
    ///      keeper-gated, so that framing is gone. The property it was really protecting is NOT:
    ///      compliance must never gate settlement. A sanctioned, never-KYC'd keeper must still be
    ///      able to settle an epoch for a CLEAN beneficiary, because the alternative is that a
    ///      sanctions listing against an operator freezes withdrawals for innocent users.
    ///      Both halves are now asserted: the role is required, and sanctions are irrelevant to it.
    function test_fork_sanctionsDoNotGateSettlement_butTheKeeperRoleDoes() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shares = _stake(alice, 400_000e18);
        uint256 reqId = _queue(alice, shares);

        compliance.setJurisdictionBlocked(carol, true); // carol: never KYC'd AND sanctioned
        _warp(uint256(Config.DEFAULT_REDEEM_COOLDOWN) + uint256(Config.DEFAULT_EPOCH_DURATION) + 1);

        // (a) THE GATE BITES. Without the role, carol cannot settle — this is the D7-01 fix.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SETTLEMENT_KEEPER_ROLE
            )
        );
        queue.closeEpoch(50);

        // (b) SANCTIONS ARE IRRELEVANT TO IT. Give the same sanctioned, never-KYC'd address the
        // keeper role and it settles normally for a clean beneficiary. Compliance gates who may
        // HOLD and TRANSFER; it must never gate who may operate the settlement crank.
        vm.prank(ops); // `ops` is this fixture's DEFAULT_ADMIN (== address(this))
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, carol);

        vm.prank(carol);
        queue.closeEpoch(50);

        (,, uint256 claimable,,) = queue.request(reqId);
        assertGt(claimable, 0, "a sanctioned keeper still settled the epoch for a clean user");

        uint256 before = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = queue.claim(reqId);
        assertEq(paid, claimable, "and the clean beneficiary was paid exactly");
        assertEq(usdfr.balanceOf(alice) - before, claimable, "delivered");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 8. POINTS × COMPLIANCE (the exemption set is also the points exclusion set)
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice Points accrue to a NON-KYC holder (participation is not KYC-gated) and never to
    ///         a protocol-exempt module — otherwise the modules' own float would dilute every
    ///         real participant.
    function test_fork_points_nonKycAccruesAndExemptModulesDoNot() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        vm.prank(alice);
        usdfr.transfer(carol, 200_000e18);
        _stake(alice, 500_000e18); // the vault now holds real USDfr float

        (, uint256 carolTracked) = points.trackedBalances(carol);
        assertEq(carolTracked, 200_000e18, "non-KYC holder is tracked at exactly her balance");

        (, uint256 vaultTracked) = points.trackedBalances(address(vault));
        assertEq(vaultTracked, 0, "the exempt vault's USDfr float is NOT tracked");
        assertGt(usdfr.balanceOf(address(vault)), 0, "...even though it really holds USDfr");

        _warp(30 days);
        assertGt(points.pointsOfWallet(carol), 0, "non-KYC wallet accrues points");
        assertEq(points.pointsOfWallet(address(vault)), 0, "exempt module accrues none");
        assertEq(points.pointsOfWallet(address(queue)), 0, "exempt queue accrues none");

        // Points accrual is unaffected by a sanctions entry on the holder (points are a
        // non-financial ledger; the freeze bites on transfer, not on accrual).
        uint256 snapshot = points.pointsOfWallet(carol);
        compliance.setJurisdictionBlocked(carol, true);
        _warp(30 days);
        assertGt(points.pointsOfWallet(carol), snapshot, "accrual continues while frozen");
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // 9. SANCTIONS DO NOT LEAK INTO THE UNDERLYING STABLE
    // ─────────────────────────────────────────────────────────────────────────────────

    /// @notice The freeze is a PROTOCOL-token rule. Real USDC is a third-party token the
    ///         registry has no authority over — a sanctioned wallet still moves its own USDC.
    ///         Asserted so nobody mistakes the registry for a freeze on the collateral itself.
    function test_fork_sanctionsDoNotReachRealUSDC() public onFork {
        compliance.setJurisdictionBlocked(carol, true);
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(carol);
        IERC20(USDC).transfer(alice, 1_000e6);
        assertEq(IERC20(USDC).balanceOf(alice) - before, 1_000e6, "real USDC is outside the registry's reach");
    }
}
