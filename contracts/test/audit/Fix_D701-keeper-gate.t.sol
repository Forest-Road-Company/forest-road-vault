// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev A would-be flash-loan attacker. The whole D7-01 class depends on getting the budget
///      SAMPLE and the FILLS into the attacker's OWN transaction, because a flash loan cannot
///      span two transactions. This contract models exactly that: inflate, settle, repay, all
///      atomically. With the gate in place it cannot take the middle step.
contract AtomicSettler {
    IRedemptionQueue private immutable QUEUE;

    constructor(address queue_) {
        QUEUE = IRedemptionQueue(queue_);
    }

    function inflateSettleRepay(uint256 maxRequests) external {
        // (the borrow and repay legs are elided — the gate stops us before they matter)
        QUEUE.closeEpoch(maxRequests);
    }
}

/// @title Fix_D701 — `closeEpoch` is gated on SETTLEMENT_KEEPER_ROLE
/// @notice AUDIT FIX (D7-01 + the starvation mirror). `closeEpoch` samples the epoch liquidity
///         budget as a spot read and re-reads it every chunk, both inside the caller's
///         transaction. While the call was permissionless an attacker could hold a flash loan
///         across the sample and the fills — measured at $1.62M of excess budget from Morpho
///         alone, $4.31M stacked with Aave — or latch a settlement at a moment of their
///         choosing. Gating the call removes the attacker's ability to place it in their own
///         transaction, which closes the CLASS rather than the instances.
///
///         Supersedes ADR-0018 §2 ("Chunked, permissionless settlement").
///
///         These tests exist because the fixture grants the role broadly so the ~169 existing
///         call sites keep testing what they were written to test. That grant is NOT coverage of
///         the modifier. This file is.
contract Fix_D701KeeperGate is CreditLayerFixture {
    AtomicSettler internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = new AtomicSettler(address(queue));
        _seedAQueuedRequest();
    }

    function _seedAQueuedRequest() internal {
        _mintUSDfrTo(alice, 1_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(500_000e18, alice);
        vault.approve(address(queue), type(uint256).max);
        queue.requestRedeem(shares);
        vm.stopPrank();
        vm.warp(block.timestamp + Config.DEFAULT_REDEEM_COOLDOWN + Config.DEFAULT_EPOCH_DURATION + 1);
    }

    function _expectUnauthorized(address who) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, who, Roles.SETTLEMENT_KEEPER_ROLE
            )
        );
    }

    // ── The gate itself ──────────────────────────────────────────────────

    /// @notice AUTHORIZED path: the keeper settles normally.
    function test_d701_keeperMaySettle() public {
        vm.prank(settlementKeeper);
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), 2, "the keeper's settlement must advance the epoch");
    }

    /// @notice UNAUTHORIZED path, with the SPECIFIC error. This is the D7-01 remediation.
    function test_d701_outsiderMayNotSettle() public {
        _expectUnauthorized(carol);
        vm.prank(carol);
        queue.closeEpoch(10);
    }

    /// @notice A queued redeemer cannot settle their own exit either. Worth pinning explicitly:
    ///         it is the most sympathetic caller and the most likely to be "helpfully" re-opened.
    function test_d701_ownRequestOwnerMayNotSettle() public {
        _expectUnauthorized(alice);
        vm.prank(alice);
        queue.closeEpoch(10);
    }

    /// @notice THE CLASS, not the instance: a contract cannot pull settlement into its own
    ///         transaction, which is what every flash-loan variant of D7-01 requires.
    function test_d701_contractCannotPullSettlementIntoItsOwnTransaction() public {
        _expectUnauthorized(address(attacker));
        attacker.inflateSettleRepay(10);
    }

    /// @notice The role check fires BEFORE `whenNotPaused`, so pause state is not probeable by an
    ///         unauthorized caller and the error is stable regardless of pause.
    function test_d701_roleCheckPrecedesPauseCheck() public {
        vm.prank(guardian);
        queue.pause();

        _expectUnauthorized(carol);
        vm.prank(carol); // NOT EnforcedPause — the role check runs first
        queue.closeEpoch(10);
    }

    // ── Role administration ──────────────────────────────────────────────

    /// @notice Only DEFAULT_ADMIN administers the role.
    function test_d701_onlyAdminMayGrantTheRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, queue.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(carol);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, carol);
    }

    /// @notice TWO HOLDERS. The deploy grants the hot keeper AND a manual backstop, so a keeper
    ///         outage degrades to manual operation instead of freezing the only senior exit.
    function test_d701_asecondHolderCanSettleIfTheFirstIsDown() public {
        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, bob); // the backstop

        vm.prank(admin);
        queue.revokeRole(Roles.SETTLEMENT_KEEPER_ROLE, settlementKeeper); // hot keeper compromised

        _expectUnauthorized(settlementKeeper);
        vm.prank(settlementKeeper);
        queue.closeEpoch(10);

        vm.prank(bob);
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), 2, "the backstop holder must be able to settle");
    }

    /// @notice THE COST, asserted rather than argued. Revoking every holder freezes the
    ///         protocol's only senior exit. This is the liveness price of closing D7-01, and it
    ///         is why the role must always have at least two holders and be monitored. If this
    ///         test ever starts failing, someone has added a permissionless fallback — which
    ///         re-opens D7-01 and must be an explicit, ADR-recorded decision, not a drive-by.
    function test_d701_revokingEveryHolderFreezesTheOnlyExit() public {
        vm.startPrank(admin);
        queue.revokeRole(Roles.SETTLEMENT_KEEPER_ROLE, settlementKeeper);
        queue.revokeRole(Roles.SETTLEMENT_KEEPER_ROLE, address(this));
        vm.stopPrank();

        _expectUnauthorized(carol);
        vm.prank(carol);
        queue.closeEpoch(10);

        // ...and it is RECOVERABLE by governance, which is what bounds the exposure.
        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, settlementKeeper);
        vm.prank(settlementKeeper);
        queue.closeEpoch(10);
        assertEq(queue.currentEpoch(), 2, "a regrant must restore settlement");
    }

    /// @notice The gate must not change settlement SEMANTICS — only who may trigger them.
    ///         Same board, same outcome, whichever authorized holder calls.
    function test_d701_gateChangesWhoNotWhat() public {
        uint256 snap = vm.snapshotState();

        vm.prank(settlementKeeper);
        queue.closeEpoch(10);
        (,, uint256 claimableA,,) = queue.request(0);
        uint256 epochA = queue.currentEpoch();

        vm.revertToState(snap);

        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, bob);
        vm.prank(bob);
        queue.closeEpoch(10);
        (,, uint256 claimableB,,) = queue.request(0);

        assertEq(claimableB, claimableA, "settlement outcome must not depend on WHICH keeper called");
        assertEq(queue.currentEpoch(), epochA, "nor must the epoch");
    }
}
