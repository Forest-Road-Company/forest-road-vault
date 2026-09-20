// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {RecoveryTopUpDistributor} from "../../src/RecoveryTopUpDistributor.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_RecoveryTopUpForkTest: adversarial attacks on `RecoveryTopUpDistributor` on the pinned
///        mainnet fork (block 25,500,000), with the distributor funded from REAL USDC minted into
///        USDfr through the primary gate.
/// @notice `Deploy.s.sol` does not deploy the distributor (ADR-0029 defers it from mainnet v1), so each
///         test deploys it the way its NatSpec and ADR-0027 describe: a UUPS proxy, admin/guardian/
///         upgrader = the retained ops admin (standing in for the timelock, as every other module in
///         `ForkLifecycleFixture`), wired to the live USDfr and made protocol-exempt in the
///         ComplianceRegistry ("Deployment and operating requirements", ADR-0027). Rounds are funded
///         with USDfr that `ops` mints from real USDC, so `createRound`'s balance-delta check and every
///         payout run against the production token with its compliance and points hooks live.
///
///         Attacker is `carol` (no KYC, no role) wherever the call is permissionless; the named role
///         is used where it is not. Three properties under attack:
///           P1. a leaf pays only its recorded recipient, once, in its own round, on its own chain and
///               distributor; no forgery, redirect, partial claim, inflation or replay is reachable.
///           P2. a round can never pay more than it was funded with, and can never reach another
///               round's funding; unclaimed funds return only after the deadline and only to the
///               recorded refund recipient.
///           P3. the distributor holds no protocol power (no mint, no burn, no vault exit, no queue
///               claim, no allowance) and carol holds no distributor power.

contract ATK_RecoveryTopUpForkTest is ForkLifecycleFixture {
    struct Leaf {
        uint256 index;
        uint256 requestId;
        address account;
        uint256 amount;
    }

    address internal refund = makeAddr("topUpRefund");
    address internal dave = makeAddr("forkDave");

    // Canonical allocation used by every round unless a test overrides a leaf:
    //   alice idx 0   req 11  300e18
    //   bob   idx 1   req 22  200e18
    //   carol idx 257 req 33  100e18   (index 257 = word 1 bit 1: exercises the bitmap word boundary)
    //   dave  idx 3   req 44   50e18
    uint256 internal constant TOTAL = 650e18;

    // ─────────────────────────────────────────────────────────────────────────
    // P1: forgery, redirect, partial claim, replay, cross-chain, cross-distributor
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: carol holds every published proof (they are public) and tries every way of
    ///         turning someone else's allocation into her own money: redirecting alice's leaf to
    ///         herself, taking more or less than the recorded amount, moving it to another request
    ///         id, another index, another round, a copy of the round on a second distributor, and a
    ///         Sepolia-generated allocation file published on mainnet. Then she relays alice's real
    ///         claim (allowed) and replays it (must fail). Finally she claims her own leaf with no
    ///         KYC: transfers are permissionless by the 2026-07-14 directive, so this must pay.
    function test_ATK_carol_cannotForgeRedirectOrReplay_fundsOnlyReachLeafRecipient() public onFork {
        RecoveryTopUpDistributor d = _deployDistributor();
        (bytes32 root, bytes32[4] memory h) = _tree(d, 0, _canonical());
        assertEq(_fundRound(d, root, TOTAL, uint64(block.timestamp + 30 days)), 0, "first round id");
        assertEq(usdfr.balanceOf(address(d)), TOTAL, "round fully funded with real USDfr");

        _forgeries(d, h);
        _crossDomain(d, root, h);
        _relayReplayAndOwnLeaf(d, h);
    }

    /// @dev (a) to (g): every single-field forgery of alice's leaf, as carol, with alice's real proof.
    function _forgeries(RecoveryTopUpDistributor d, bytes32[4] memory h) internal {
        bytes32[] memory pA = _proof(h, 0); // alice's genuine proof, public information
        vm.startPrank(carol);
        // (a) redirect alice's leaf to carol
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 0, 0));
        d.claim(0, 0, 11, carol, 300e18, pA);
        // (b) inflate the amount by one wei
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 0, 0));
        d.claim(0, 0, 11, alice, 300e18 + 1, pA);
        // (c) partial claim of one wei (no partial claims: the amount is bound into the leaf)
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 0, 0));
        d.claim(0, 0, 11, alice, 1, pA);
        // (d) another request id
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 0, 0));
        d.claim(0, 0, 12, alice, 300e18, pA);
        // (e) another index (would also dodge the bitmap if it verified)
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 0, 5));
        d.claim(0, 5, 11, alice, 300e18, pA);
        // (f) a round that does not exist yet
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_UnknownRound.selector, 1));
        d.claim(1, 0, 11, alice, 300e18, pA);
        // (g) zero recipient / zero amount are refused before any proof work
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAddress.selector);
        d.claim(0, 0, 11, address(0), 300e18, pA);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAmount.selector);
        d.claim(0, 0, 11, alice, 0, pA);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(carol), 0, "carol received nothing from any forgery");
        assertEq(usdfr.balanceOf(alice), 0, "alice untouched");
    }

    /// @dev (h) a Sepolia-generated allocation file published on mainnet; (i) the same root and
    ///      funding copied onto a second distributor. Neither proof may verify.
    function _crossDomain(RecoveryTopUpDistributor d, bytes32 root, bytes32[4] memory h) internal {
        // (h) chain id 11155111 in the leaf; everything else identical. block.chainid == 1 on the fork.
        assertEq(block.chainid, 1, "fork chain id");
        bytes32 sepoliaLeaf = keccak256(
            bytes.concat(keccak256(abi.encode(uint256(11155111), address(d), uint256(1), 0, 11, alice, 300e18)))
        );
        assertEq(
            keccak256(bytes.concat(keccak256(abi.encode(uint256(1), address(d), uint256(1), 0, 11, alice, 300e18)))),
            d.leafHash(1, 0, 11, alice, 300e18),
            "leafHash binds chain id 1 and this distributor"
        );
        assertTrue(sepoliaLeaf != d.leafHash(1, 0, 11, alice, 300e18), "chain id is part of the leaf");
        assertEq(_fundRound(d, sepoliaLeaf, 300e18, uint64(block.timestamp + 30 days)), 1, "round 1");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 1, 0));
        d.claim(1, 0, 11, alice, 300e18, new bytes32[](0));

        // (i) second distributor, same root, same funding: alice's proof for `d` binds address(d)
        RecoveryTopUpDistributor d2 = _deployDistributor();
        assertEq(_fundRound(d2, root, TOTAL, uint64(block.timestamp + 30 days)), 0, "d2 round id");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_InvalidProof.selector, 0, 0));
        d2.claim(0, 0, 11, alice, 300e18, _proof(h, 0));

        assertEq(usdfr.balanceOf(carol), 0, "carol received nothing");
        assertEq(usdfr.balanceOf(alice), 0, "alice untouched");
        assertEq(usdfr.balanceOf(address(d)), TOTAL + 300e18, "d holds round 0 + round 1");
        assertEq(usdfr.balanceOf(address(d2)), TOTAL, "d2 holds its own round");
    }

    /// @dev (j) carol relays alice's genuine claim; (k) replays it; (l) claims her own leaf with no KYC.
    function _relayReplayAndOwnLeaf(RecoveryTopUpDistributor d, bytes32[4] memory h) internal {
        bytes32[] memory pA = _proof(h, 0);
        // (j) funds go to alice, never to the relayer
        vm.expectEmit(true, true, true, true, address(d));
        emit RecoveryTopUpDistributor.TopUpClaimed(0, 0, 11, alice, 300e18);
        vm.prank(carol);
        d.claim(0, 0, 11, alice, 300e18, pA);
        assertEq(usdfr.balanceOf(alice), 300e18, "alice paid exactly her allocation");
        assertEq(usdfr.balanceOf(carol), 0, "relayer receives nothing");
        assertTrue(d.isClaimed(0, 0), "bit 0 set");
        assertEq(d.round(0).claimed, 300e18, "claimed accounting");

        // (k) replay
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_AlreadyClaimed.selector, 0, 0));
        d.claim(0, 0, 11, alice, 300e18, pA);

        // (l) carol claims HER OWN leaf with no KYC and no role. Index 257 lives in bitmap word 1,
        //     bit 1; bob's index 1 lives in word 0, bit 1. The two must not alias.
        vm.prank(carol);
        d.claim(0, 257, 33, carol, 100e18, _proof(h, 2));
        assertEq(usdfr.balanceOf(carol), 100e18, "non-KYC recipient is paid (transfers are permissionless)");
        assertTrue(d.isClaimed(0, 257), "bit 257 set");
        assertFalse(d.isClaimed(0, 1), "bob's index 1 is not aliased by index 257");
        assertEq(d.round(0).claimed, 400e18, "claimed accounting after two claims");
        assertEq(usdfr.balanceOf(address(d)), TOTAL - 400e18 + 300e18, "distributor balance reconciles");

        // KYC is enforced at the primary gate, not on holding: carol cannot redeem what she was paid.
        vm.startPrank(carol);
        usdfr.approve(address(controller), 100e18);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.redeem(100e18, 0);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2: deadline boundary, reclaim gating, refund recipient
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: carol tries to sweep a live round (reclaim is admin-only); governance tries to
    ///         sweep it early (must be refused up to and including the deadline second); at deadline
    ///         + 1 claims close and exactly `funded - claimed` returns to the recorded refund
    ///         recipient, never to the caller. A claim after the sweep reports the sweep, not expiry.
    function test_ATK_deadlineBoundary_reclaimOnlyAfterExpiry_onlyByAdmin_onlyToRefundRecipient() public onFork {
        RecoveryTopUpDistributor d = _deployDistributor();
        Leaf[4] memory L = _canonical();
        (bytes32 root, bytes32[4] memory h) = _tree(d, 0, L);
        uint64 deadline = uint64(block.timestamp + 30 days);
        _fundRound(d, root, TOTAL, deadline);

        // carol cannot sweep, before or after expiry
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        d.reclaimExpired(0);

        // at exactly the deadline second: claims still open, sweep still refused
        vm.warp(deadline);
        vm.prank(carol);
        d.claim(0, 0, 11, alice, 300e18, _proof(h, 0));
        assertEq(usdfr.balanceOf(alice), 300e18, "claim at t == deadline pays");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_NotExpired.selector, 0, deadline));
        d.reclaimExpired(0);

        // one second later: claims closed
        vm.warp(uint256(deadline) + 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_Expired.selector, 0, deadline));
        d.claim(0, 1, 22, bob, 200e18, _proof(h, 1));
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        d.reclaimExpired(0);

        // governance sweeps: exactly funded - claimed, to the RECORDED refund recipient
        uint256 opsBefore = usdfr.balanceOf(ops);
        vm.expectEmit(true, true, false, true, address(d));
        emit RecoveryTopUpDistributor.RoundReclaimed(0, refund, TOTAL - 300e18);
        vm.prank(ops);
        d.reclaimExpired(0);
        assertEq(usdfr.balanceOf(refund), TOTAL - 300e18, "refund recipient receives the unclaimed remainder");
        assertEq(usdfr.balanceOf(ops), opsBefore, "the admin caller receives nothing");
        assertEq(usdfr.balanceOf(address(d)), 0, "distributor emptied");
        assertTrue(d.round(0).reclaimed, "round marked reclaimed");

        // after the sweep: claim reports the sweep (checked before expiry), second sweep refused
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_RoundReclaimed.selector, 0));
        d.claim(0, 1, 22, bob, 200e18, _proof(h, 1));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_RoundReclaimed.selector, 0));
        d.reclaimExpired(0);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_UnknownRound.selector, 7));
        d.reclaimExpired(7);

        // createRound input gates (admin path), including a deadline in the past
        vm.startPrank(ops);
        usdfr.approve(address(d), type(uint256).max);
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroRoot.selector);
        d.createRound(bytes32(0), 1e18, uint64(block.timestamp + 1), refund, keccak256("e"));
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAmount.selector);
        d.createRound(root, 0, uint64(block.timestamp + 1), refund, keccak256("e"));
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroAddress.selector);
        d.createRound(root, 1e18, uint64(block.timestamp + 1), address(0), keccak256("e"));
        vm.expectRevert(RecoveryTopUpDistributor.TopUp_ZeroEvidenceHash.selector);
        d.createRound(root, 1e18, uint64(block.timestamp + 1), refund, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_BadDeadline.selector, uint64(block.timestamp))
        );
        d.createRound(root, 1e18, uint64(block.timestamp), refund, keccak256("e"));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P2: under-funding, duplicate index, duplicate request id across and within rounds
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: governance publishes a round whose leaves sum to 650e18 but funds only 250e18
    ///         (the contract cannot see the tree's total). Carol, as relayer, chooses the claim order.
    ///         The round must drain first-come-first-served up to EXACTLY its own funding and never
    ///         touch round 0's 650e18 sitting in the same contract. The allocation file also carries
    ///         two off-chain errors the contract does not check: a duplicate index (dave and bob both
    ///         at index 1) and a duplicate request id (dave and alice both request 11). Then a third
    ///         round pays bob's request 22 again: the "exclude amounts already paid" rule of the
    ///         NatSpec is shown to be off-chain only.
    function test_ATK_underfundedRoundDrainsInClaimOrder_neverReachesAnotherRoundsFunds() public onFork {
        RecoveryTopUpDistributor d = _deployDistributor();
        Leaf[4] memory L0 = _canonical();
        (bytes32 root0, bytes32[4] memory h0) = _tree(d, 0, L0);
        uint64 deadline = uint64(block.timestamp + 30 days);
        _fundRound(d, root0, TOTAL, deadline); // round 0: fully funded, the victim balance

        Leaf[4] memory L1 = _canonical();
        L1[2].amount = 200e18; // carol: so that dave + carol == 250e18 exactly
        L1[3].index = 1; // dave collides with bob's index
        L1[3].requestId = 11; // dave collides with alice's request id
        (bytes32 root1, bytes32[4] memory h1) = _tree(d, 1, L1);
        assertEq(_fundRound(d, root1, 250e18, deadline), 1, "round 1"); // tree sums to 750e18, funded 250e18
        assertEq(usdfr.balanceOf(address(d)), TOTAL + 250e18, "both rounds held in one balance");

        vm.startPrank(carol);
        // alice's 300e18 leaf is valid but exceeds the round's funding on its own
        vm.expectRevert(
            abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_AllocationExceedsFunding.selector, 1, 300e18, 250e18)
        );
        d.claim(1, 0, 11, alice, 300e18, _proof(h1, 0));
        // dave (index 1, request 11) pays: 50e18
        d.claim(1, 1, 11, dave, 50e18, _proof(h1, 3));
        assertEq(usdfr.balanceOf(dave), 50e18, "dave paid");
        // bob (index 1, request 22) is now blocked by the duplicate index, not by funding
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_AlreadyClaimed.selector, 1, 1));
        d.claim(1, 1, 22, bob, 200e18, _proof(h1, 1));
        // carol's 200e18 lands exactly on the funding line (claimed == funded is allowed)
        d.claim(1, 257, 33, carol, 200e18, _proof(h1, 2));
        assertEq(d.round(1).claimed, 250e18, "round 1 exactly exhausted");
        // nothing further from round 1, whatever the order
        vm.expectRevert(
            abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_AllocationExceedsFunding.selector, 1, 550e18, 250e18)
        );
        d.claim(1, 0, 11, alice, 300e18, _proof(h1, 0));
        vm.stopPrank();

        _afterRoundOneExhausted(d, h0, deadline);
    }

    /// @dev Second half of the under-funding attack (split only to stay within the stack limit).
    function _afterRoundOneExhausted(RecoveryTopUpDistributor d, bytes32[4] memory h0, uint64 deadline) internal {
        // round 0's funding is intact: every round-0 leaf still pays in full
        assertEq(usdfr.balanceOf(address(d)), TOTAL, "round 1 drained only its own 250e18");
        vm.startPrank(carol);
        d.claim(0, 0, 11, alice, 300e18, _proof(h0, 0));
        d.claim(0, 1, 22, bob, 200e18, _proof(h0, 1));
        d.claim(0, 257, 33, carol, 100e18, _proof(h0, 2));
        d.claim(0, 3, 44, dave, 50e18, _proof(h0, 3));
        vm.stopPrank();
        assertEq(usdfr.balanceOf(address(d)), 0, "every round-0 allocation paid after round 1 was exhausted");
        assertEq(usdfr.balanceOf(alice), 300e18, "alice: request 11 paid once in round 0");
        assertEq(usdfr.balanceOf(dave), 100e18, "dave: 50e18 (round 1, request 11) + 50e18 (round 0, request 44)");
        assertEq(usdfr.balanceOf(carol), 300e18, "carol: 200e18 (round 1) + 100e18 (round 0)");

        // round 2: bob's request 22 again, after it was already paid in round 0. Nothing on-chain
        // links request ids across rounds; the NatSpec's exclusion of amounts already paid is an
        // off-chain rule of the allocation calculation.
        bytes32 leaf2 = d.leafHash(2, 0, 22, bob, 200e18);
        _fundRound(d, leaf2, 200e18, deadline);
        vm.prank(carol);
        d.claim(2, 0, 22, bob, 200e18, new bytes32[](0));
        assertEq(usdfr.balanceOf(bob), 400e18, "bob: request 22 paid in round 0 AND round 2");

        // after expiry round 1 has nothing left to reclaim: the zero-amount branch emits but moves nothing
        vm.warp(uint256(deadline) + 1);
        uint256 refundBefore = usdfr.balanceOf(refund);
        vm.expectEmit(true, true, false, true, address(d));
        emit RecoveryTopUpDistributor.RoundReclaimed(1, refund, 0);
        vm.prank(ops);
        d.reclaimExpired(1);
        assertEq(usdfr.balanceOf(refund), refundBefore, "nothing to refund from an exhausted round");
        assertTrue(d.round(1).reclaimed, "round 1 closed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P3: the distributor holds no protocol power; carol holds no distributor power
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: ADR-0027 says the distributor "cannot mint USDfr, cannot withdraw from sUSDfr,
    ///         cannot use queue claim balances". Executed as the distributor address against the live
    ///         modules with alice holding shares and a queued request, then as carol against every
    ///         privileged entry point of the distributor and its implementation.
    function test_ATK_distributorHoldsNoProtocolPower_andCarolHoldsNoDistributorPower() public onFork {
        RecoveryTopUpDistributor d = _deployDistributor();
        address dist = address(d);

        _mintFromUSDC(alice, 1_000e6);
        uint256 shares = _stake(alice, 500e18);
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(shares);
        vm.stopPrank();
        uint256 supply = usdfr.totalSupply();

        // ── as the distributor ──
        vm.startPrank(dist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, dist, Roles.MINTER_ROLE)
        );
        usdfr.mint(dist, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, dist, Roles.MINTER_ROLE)
        );
        usdfr.burn(alice, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, dist, Roles.MINTER_ROLE)
        );
        usdfr.mintAccrued(1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, alice, 1e18, uint256(0))
        );
        vault.withdraw(1e18, dist, alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, alice, uint256(1), uint256(0))
        );
        vault.redeem(1, dist, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, dist, uint256(0), uint256(1))
        );
        usdfr.transferFrom(alice, dist, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, dist, uint256(0), uint256(1))
        );
        vault.transferFrom(alice, dist, 1);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, reqId, dist));
        queue.claim(reqId);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, dist));
        controller.mint(1e6);
        vm.stopPrank();
        assertEq(usdfr.totalSupply(), supply, "supply unchanged by the distributor");
        assertEq(usdfr.balanceOf(dist), 0, "distributor holds nothing it was not funded with");

        // role census: the distributor holds no role on any module
        address[15] memory mods = [
            address(compliance),
            address(usdfr),
            address(reserves),
            address(controller),
            address(vault),
            address(points),
            address(registry),
            address(oracle),
            address(bridge),
            address(curator),
            address(waterfall),
            address(defaultManager),
            address(queue),
            address(grove),
            address(sGrove)
        ];
        bytes32[14] memory roles = [
            bytes32(0),
            Roles.UPGRADER_ROLE,
            Roles.GUARDIAN_ROLE,
            Roles.MINTER_ROLE,
            Roles.CONTROLLER_ROLE,
            Roles.CREDIT_ROLE,
            Roles.LOSS_BURNER_ROLE,
            Roles.FEE_ACCOUNTING_ROLE,
            Roles.COMPLIANCE_ADMIN_ROLE,
            Roles.RESERVE_ADMIN_ROLE,
            Roles.ORIGINATOR_ROLE,
            Roles.ATTESTER_ROLE,
            Roles.SERVICER_ROLE,
            Roles.SETTLEMENT_KEEPER_ROLE
        ];
        for (uint256 i = 0; i < mods.length; ++i) {
            for (uint256 j = 0; j < roles.length; ++j) {
                assertFalse(IAccessControl(mods[i]).hasRole(roles[j], dist), "distributor holds a protocol role");
            }
        }

        // ── as carol, against the distributor ──
        address impl = address(new RecoveryTopUpDistributor());
        vm.startPrank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        d.createRound(keccak256("r"), 1e18, uint64(block.timestamp + 1 days), carol, keccak256("e"));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        d.grantRole(bytes32(0), carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        d.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        d.unpause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.UPGRADER_ROLE)
        );
        d.upgradeToAndCall(impl, "");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        d.initialize(carol, carol, carol, address(usdfr));
        // the bare implementation: cannot be initialised, cannot be upgraded outside a proxy
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RecoveryTopUpDistributor(impl).initialize(carol, carol, carol, address(usdfr));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        RecoveryTopUpDistributor(impl).upgradeToAndCall(impl, "");
        vm.stopPrank();

        // the upgrader path works for its holder and only there
        vm.prank(ops);
        d.upgradeToAndCall(impl, "");
        assertEq(d.usdfr(), address(usdfr), "state survives the upgrade (ERC-7201 slot)");
        assertEq(d.nextRoundId(), 0, "no round was created by any of the above");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // P1/P2: sanctions and pauses on the real token; the deadline keeps running
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: carol relays a claim to a sanctioned recipient (USDfr refuses and the claim bit
    ///         must NOT be consumed), then under a USDfr pause and under a distributor pause. A pause
    ///         does not stop the deadline: if the guardian holds the pause across it, every unclaimed
    ///         allocation returns to the refund recipient. Executed with the numbers.
    function test_ATK_sanctionedRecipientAndPausesBlockClaims_deadlineKeepsRunningUnderPause() public onFork {
        RecoveryTopUpDistributor d = _deployDistributor();
        Leaf[4] memory L = _canonical();
        (bytes32 root, bytes32[4] memory h) = _tree(d, 0, L);
        uint64 deadline = uint64(block.timestamp + 30 days);
        _fundRound(d, root, TOTAL, deadline);
        assertTrue(compliance.isProtocolExempt(address(d)), "ADR-0027 wiring: distributor protocol-exempt");

        // sanctioned recipient: USDfr refuses the payout; the bitmap and accounting roll back
        vm.prank(ops);
        compliance.setJurisdictionBlocked(bob, true);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(d), bob));
        d.claim(0, 1, 22, bob, 200e18, _proof(h, 1));
        assertFalse(d.isClaimed(0, 1), "a refused payout does not consume the leaf");
        assertEq(d.round(0).claimed, 0, "a refused payout is not counted");
        vm.prank(ops);
        compliance.setJurisdictionBlocked(bob, false);
        vm.prank(carol);
        d.claim(0, 1, 22, bob, 200e18, _proof(h, 1));
        assertEq(usdfr.balanceOf(bob), 200e18, "bob paid once the freeze is lifted");

        // USDfr pause: the distributor is protocol-exempt but alice is not, so no user leg opens
        vm.prank(ops);
        usdfr.pause();
        vm.prank(carol);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        d.claim(0, 0, 11, alice, 300e18, _proof(h, 0));
        vm.prank(ops);
        usdfr.unpause();

        // distributor pause: claims refused, carol cannot lift it, admin sweep is still deadline-gated
        vm.prank(ops);
        d.pause();
        vm.prank(carol);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        d.claim(0, 0, 11, alice, 300e18, _proof(h, 0));
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        d.unpause();
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_NotExpired.selector, 0, deadline));
        d.reclaimExpired(0);

        // the pause is held across the deadline
        vm.warp(uint256(deadline) + 1);
        vm.prank(ops);
        d.unpause();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(RecoveryTopUpDistributor.TopUp_Expired.selector, 0, deadline));
        d.claim(0, 0, 11, alice, 300e18, _proof(h, 0));
        vm.prank(ops);
        d.reclaimExpired(0);
        assertEq(
            usdfr.balanceOf(refund), TOTAL - 200e18, "450e18 of unclaimed allocations returned to the refund recipient"
        );
        assertEq(usdfr.balanceOf(alice), 0, "alice's 300e18 never reached her");
        assertEq(usdfr.balanceOf(address(d)), 0, "distributor emptied");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploys the distributor as ADR-0027 describes: UUPS proxy, live USDfr, protocol-exempt.
    function _deployDistributor() internal returns (RecoveryTopUpDistributor d) {
        d = RecoveryTopUpDistributor(
            address(
                new ERC1967Proxy(
                    address(new RecoveryTopUpDistributor()),
                    abi.encodeCall(RecoveryTopUpDistributor.initialize, (ops, ops, ops, address(usdfr)))
                )
            )
        );
        vm.prank(ops);
        compliance.setProtocolExempt(address(d), true);
        assertEq(d.usdfr(), address(usdfr), "wired to the live USDfr");
    }

    /// @dev Governance funds a round with USDfr minted from REAL USDC at the primary gate.
    function _fundRound(RecoveryTopUpDistributor d, bytes32 root, uint256 funded, uint64 deadline)
        internal
        returns (uint256 roundId)
    {
        uint256 minted = _mintFromUSDC(ops, funded / 1e12);
        assertEq(minted, funded, "1:1 mint from USDC");
        uint256 before = usdfr.balanceOf(address(d));
        vm.startPrank(ops);
        usdfr.approve(address(d), funded);
        roundId = d.createRound(root, funded, deadline, refund, keccak256(abi.encode("workout-evidence", root, funded)));
        vm.stopPrank();
        assertEq(usdfr.balanceOf(address(d)) - before, funded, "balance delta equals funded");
        RecoveryTopUpDistributor.Round memory r = d.round(roundId);
        assertEq(r.merkleRoot, root, "root recorded");
        assertEq(r.funded, funded, "funded recorded");
        assertEq(r.claimDeadline, deadline, "deadline recorded");
        assertEq(r.refundRecipient, refund, "refund recipient recorded");
    }

    function _canonical() internal view returns (Leaf[4] memory L) {
        L[0] = Leaf(0, 11, alice, 300e18);
        L[1] = Leaf(1, 22, bob, 200e18);
        L[2] = Leaf(257, 33, carol, 100e18);
        L[3] = Leaf(3, 44, dave, 50e18);
    }

    /// @dev Four-leaf tree with OZ sorted-pair hashing: root = H(H(l0,l1), H(l2,l3)).
    function _tree(RecoveryTopUpDistributor d, uint256 roundId, Leaf[4] memory L)
        internal
        view
        returns (bytes32 root, bytes32[4] memory h)
    {
        for (uint256 i = 0; i < 4; ++i) {
            h[i] = d.leafHash(roundId, L[i].index, L[i].requestId, L[i].account, L[i].amount);
        }
        root = _pair(_pair(h[0], h[1]), _pair(h[2], h[3]));
    }

    function _proof(bytes32[4] memory h, uint256 i) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = h[i ^ 1];
        p[1] = i < 2 ? _pair(h[2], h[3]) : _pair(h[0], h[1]);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }
}
