// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {SGrove} from "../../src/SGrove.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_SGroveForkTest — adversarial assault on the sGROVE backstop (src/SGrove.sol)
///
/// @notice AUTHORISED local-fork attack on the owner's own pre-audit code. Never broadcasts,
///         never moves real value. The whole protocol is deployed via the real Deploy script
///         (ForkLifecycleFixture) on a pinned mainnet fork with REAL USDC/GROVE.
///
///         GROVE mints its entire fixed supply to the treasury, which on the fork is
///         `ops == address(this)`, so the harness distributes staking GROVE with `grove.transfer`
///         and mints reward/coverage USDfr through the real KYC-gated `controller.mint` path.
///
///         Each test ATTEMPTS a real exploit and makes the outcome unambiguous: if an attack
///         lands, it asserts the violated state; if the contract blocks it, it asserts the exact
///         custom error. The three invariants under fire (SGrove NatSpec + CLAUDE.md 1.3):
///           (I1) the 21-day unbonding cooldown cannot be bypassed;
///           (I2) rewards cannot be double-claimed or stolen cross-user;
///           (I3) the coverage reserve (layer-2 capital) is only reachable by CREDIT_ROLE.
contract ATK_SGroveForkTest is ForkLifecycleFixture {
    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Give `who` GROVE (from the genesis treasury == address(this)) and stake it.
    function _stakeGrove(address who, uint256 amount) internal {
        grove.transfer(who, amount); // msg.sender == ops == treasury holds the full supply
        vm.startPrank(who);
        grove.approve(address(sGrove), amount);
        sGrove.stake(amount);
        vm.stopPrank();
    }

    /// @dev Mint `usdfrAmount` (18-dec) USDfr to ops and approve the backstop to pull it.
    function _opsUSDfr(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / 1e12); // 6-dec USDC in, 18-dec USDfr out
        usdfr.approve(address(sGrove), type(uint256).max); // ops == address(this)
    }

    // ── (I1) COMPOSE: request then claim early / twice / cross-user ───────

    /// @notice ATTACK: bypass the 21-day cooldown by claiming early, replaying a claim, or
    ///         reaching another staker's unbond. Expected: every bypass reverts; the claim only
    ///         succeeds at exactly releaseAt.
    function test_unbonding_cooldown_cannot_be_bypassed() public onFork {
        _stakeGrove(alice, 1_000e18);

        // request unbonding of part of the stake
        uint64 releaseAt = uint64(uint256(block.timestamp) + Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(alice);
        uint256 id = sGrove.requestUnstake(400e18);
        assertEq(id, 0, "first unbond id");
        assertEq(sGrove.stakedOf(alice), 600e18, "active stake reduced immediately");

        // ATTACK 1: claim the instant the clock starts -> must be blocked
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_StillUnbonding.selector, uint256(0), releaseAt));
        vm.prank(alice);
        sGrove.claimUnstake(0);

        // ATTACK 2: claim one second before release -> still blocked
        _warp(Config.SGROVE_UNBONDING_PERIOD - 1);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_StillUnbonding.selector, uint256(0), releaseAt));
        vm.prank(alice);
        sGrove.claimUnstake(0);

        // ATTACK 3 (cross-user): bob tries to seize alice's unbond slot -> his own list is
        // empty, so he cannot reach it. Proves claims are strictly per-msg.sender.
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, uint256(0)));
        vm.prank(bob);
        sGrove.claimUnstake(0);

        // legitimate claim lands at exactly releaseAt
        _warp(1);
        uint256 groveBefore = grove.balanceOf(alice);
        vm.prank(alice);
        sGrove.claimUnstake(0);
        assertEq(grove.balanceOf(alice) - groveBefore, 400e18, "exactly the unbonded GROVE returned");

        // ATTACK 4 (double-claim): replay the same matured unbond -> slot is spent
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, uint256(0)));
        vm.prank(alice);
        sGrove.claimUnstake(0);

        // ATTACK 5 (over-withdraw): request more than remains active -> blocked
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_InsufficientStake.selector, 600e18 + 1, uint256(600e18)));
        vm.prank(alice);
        sGrove.requestUnstake(600e18 + 1);

        // a second unbond gets a fresh, non-colliding id
        vm.prank(alice);
        uint256 id2 = sGrove.requestUnstake(600e18);
        assertEq(id2, 1, "ids increment, never reuse a spent slot");
        assertEq(sGrove.stakedOf(alice), 0, "all active stake now unbonding");
    }

    // ── (I2) rewards: JIT sandwich + cross-user siphon + double-claim ─────

    /// @notice ATTACK: a whale stakes AFTER a full reward stream has accrued to a lone earlier
    ///         staker, and tries to (a) capture retroactive rewards and (b) siphon the earlier
    ///         staker's accrual by poking the global index. The R4-EC1 streaming design must make
    ///         the latecomer earn nothing, and the earlier staker's full accrual must survive the
    ///         whale's stake and be claimable exactly once.
    function test_reward_stream_no_retroactive_or_cross_user_theft() public onFork {
        _stakeGrove(alice, 1_000e18); // lone staker

        // stream 700 USDfr over the 7-day window
        _opsUSDfr(700e18);
        sGrove.notifyRewards(700e18);

        // let the entire stream elapse; alice (sole staker) is owed ~all of it
        _warp(Config.SGROVE_REWARDS_DURATION);
        uint256 alicePending = sGrove.pendingRewards(alice);
        assertApproxEqAbs(alicePending, 700e18, 1e9, "lone staker earns the whole stream (modulo dust)");

        // ATTACK: a whale stakes 1000x alice AFTER the stream ended. Staking pokes the global
        // reward index (banking alice's share into it), the classic siphon setup.
        _stakeGrove(bob, 1_000_000e18);

        // the latecomer must have earned exactly nothing (no retroactive rewards)
        assertEq(sGrove.pendingRewards(bob), 0, "latecomer earns zero from past accrual");

        // and cannot claim anything cross-user
        vm.expectRevert(SGrove.SGrove_NothingToClaim.selector);
        vm.prank(bob);
        sGrove.claimRewards();

        // alice's accrual survived the whale's stake untouched and pays out exactly once
        uint256 aliceUsdfrBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got = sGrove.claimRewards();
        assertApproxEqAbs(got, 700e18, 1e9, "earlier staker keeps her full accrual");
        assertEq(usdfr.balanceOf(alice) - aliceUsdfrBefore, got, "claim actually delivered the USDfr");

        // ATTACK (double-claim): immediate replay -> nothing left
        vm.expectRevert(SGrove.SGrove_NothingToClaim.selector);
        vm.prank(alice);
        sGrove.claimRewards();
    }

    /// @notice ATTACK: an unbonding position keeps earning rewards. requestUnstake removes the
    ///         stake from the earning set immediately, so a staker who exits before a stream must
    ///         accrue nothing from it. Expected: the exited staker earns zero.
    function test_unbonding_position_earns_no_rewards() public onFork {
        _stakeGrove(alice, 1_000e18);
        _stakeGrove(bob, 1_000e18);

        // alice exits her whole position BEFORE any stream
        vm.prank(alice);
        sGrove.requestUnstake(1_000e18);
        assertEq(sGrove.stakedOf(alice), 0, "alice no longer in the earning set");

        // now a stream runs; only bob should earn
        _opsUSDfr(700e18);
        sGrove.notifyRewards(700e18);
        _warp(Config.SGROVE_REWARDS_DURATION);

        assertEq(sGrove.pendingRewards(alice), 0, "unbonding stake earns nothing");
        assertApproxEqAbs(sGrove.pendingRewards(bob), 700e18, 1e9, "the sole active staker earns it all");

        vm.expectRevert(SGrove.SGrove_NothingToClaim.selector);
        vm.prank(alice);
        sGrove.claimRewards();
    }

    // ── (I3) coverage reserve: only CREDIT_ROLE may draw it ───────────────

    /// @notice ATTACK: an adversary drains the layer-2 coverage reserve directly. `coverShortfall`
    ///         is the only USDfr-out path besides one's own rewards, and it is CREDIT_ROLE-gated.
    ///         Expected: a non-role caller reverts with AccessControlUnauthorizedAccount and the
    ///         reserve is untouched.
    function test_coverage_reserve_not_drainable_by_unauthorized() public onFork {
        // fund the reserve permissionlessly (fee routing / seeds / anyone)
        _opsUSDfr(500e18);
        sGrove.fundCoverage(500e18);
        assertEq(sGrove.coverageReserve(), 500e18, "reserve seeded");
        assertEq(sGrove.coverageCapacity(), 500e18, "capacity == live reserve (ADR-0035)");
        assertEq(sGrove.remainingCoverage(1), 500e18, "shared reserve reachable by the next event");

        // a hostile EOA holds no CREDIT_ROLE
        assertFalse(sGrove.hasRole(Roles.CREDIT_ROLE, carol), "attacker has no cascade role");

        // ATTACK: carol tries to pull the whole reserve to herself
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        vm.prank(carol);
        sGrove.coverShortfall(1, 500e18);

        // ATTACK: a legitimate staker is equally powerless against the reserve
        _stakeGrove(alice, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.CREDIT_ROLE)
        );
        vm.prank(alice);
        sGrove.coverShortfall(1, 500e18);

        assertEq(sGrove.coverageReserve(), 500e18, "reserve untouched after both attacks");
    }

    // ── notifyRewards griefing / dust / no-stakers guards ─────────────────

    /// @notice ATTACK: dilute an in-flight stream by re-stretching its remainder over a fresh full
    ///         window with a dust top-up (audit M-1), deferring stakers' owed yield indefinitely.
    ///         Expected: a mid-stream notify that would lower the drip rate reverts.
    function test_mid_stream_dilution_grief_blocked() public onFork {
        _stakeGrove(alice, 1_000e18);
        _opsUSDfr(800e18);
        sGrove.notifyRewards(700e18); // start a live stream

        // some time passes so the remainder < a full window
        _warp(1 hours);

        // ATTACK: 1-wei top-up would re-stretch the remainder and slow the drip
        (uint256 currentRate, uint64 periodFinish,, uint64 duration) = sGrove.rewardSchedule();
        uint256 newRate = (1 + (periodFinish - uint64(block.timestamp)) * currentRate) / duration;
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_RewardRateWouldDecrease.selector, newRate, currentRate));
        sGrove.notifyRewards(1);
    }

    /// @notice ATTACK: strand USDfr by notifying with no stakers, or with an amount so small the
    ///         per-second rate rounds to zero (pulls funds in, streams nothing). Expected: both
    ///         revert loudly rather than silently trapping value.
    function test_notify_guards_reject_no_stakers_and_dust() public onFork {
        _opsUSDfr(800e18);

        // ATTACK 1: notify before anyone stakes -> would strand rewards with no earner
        vm.expectRevert(SGrove.SGrove_NoStakers.selector);
        sGrove.notifyRewards(100e18);

        // ATTACK 2: with a staker present, a dust notify rounds the rate to 0
        _stakeGrove(alice, 1_000e18);
        (,,, uint64 duration) = sGrove.rewardSchedule();
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_RewardDust.selector, uint256(1), duration));
        sGrove.notifyRewards(1);
    }

    // ── zero-amount / unknown-slot input guards (fail loudly) ─────────────

    /// @notice ATTACK: poke the value-moving entry points with zero / unknown inputs to find a
    ///         silent success path. Expected: each reverts with its specific error.
    function test_zero_and_unknown_input_guards() public onFork {
        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.stake(0);

        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        vm.prank(alice);
        sGrove.requestUnstake(0);

        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.fundCoverage(0);

        // claimUnstake against an empty list and claimRewards with nothing accrued
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, uint256(0)));
        vm.prank(alice);
        sGrove.claimUnstake(0);

        vm.expectRevert(SGrove.SGrove_NothingToClaim.selector);
        vm.prank(alice);
        sGrove.claimRewards();
    }
}
