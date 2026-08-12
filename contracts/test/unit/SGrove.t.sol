// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SGrove} from "../../src/SGrove.sol";
import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

contract SGroveTest is GovernanceFixture {
    /// @dev ADR-0035 retains event ids for draw observability, never for capacity allocation.
    uint256 internal constant EVENT_1 = 1;
    uint256 internal constant EVENT_2 = 2;

    function _vaultHurdleAssets() internal view returns (uint256) {
        return Math.mulDiv(vault.highWaterMark(), vault.totalSupply() + 1e6, 10 ** vault.decimals(), Math.Rounding.Ceil);
    }

    // ── initialize ───────────────────────────────────────────────────────

    function test_supportsCompleteCascadeBackstopInterface() public view {
        assertTrue(sGrove.supportsInterface(type(ICascadeBackstop).interfaceId));
        assertFalse(sGrove.supportsInterface(0xffffffff));
    }

    function test_initialize_zeroAddressRevertsAndDefaults() public {
        SGrove impl = new SGrove();
        vm.expectRevert(SGrove.SGrove_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                SGrove.initialize, (address(0), guardian, admin, address(grove), address(usdfr), address(vault))
            )
        );
        vm.expectRevert(SGrove.SGrove_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SGrove.initialize, (admin, guardian, admin, address(0), address(usdfr), address(vault)))
        );
        vm.expectRevert(SGrove.SGrove_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SGrove.initialize, (admin, guardian, admin, address(grove), address(usdfr), address(0)))
        );

        uint64 unbonding = sGrove.params();
        assertEq(unbonding, Config.SGROVE_UNBONDING_PERIOD, "ADR-0014 unbonding");
        (address g, address u, address feeVaultAddr) = sGrove.modules();
        assertEq(g, address(grove));
        assertEq(u, address(usdfr));
        assertEq(feeVaultAddr, address(vault));
    }

    // ── stake / unbond / claim ───────────────────────────────────────────

    function test_stake_movesGroveAndTracks() public {
        vm.prank(frTreasury);
        grove.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 1_000e18);
        vm.expectEmit(true, false, false, true);
        emit SGrove.Staked(alice, 1_000e18);
        sGrove.stake(1_000e18);
        vm.stopPrank();
        assertEq(sGrove.stakedOf(alice), 1_000e18);
        assertEq(sGrove.totalStaked(), 1_000e18);
        assertEq(grove.balanceOf(address(sGrove)), 1_000e18);

        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        vm.prank(alice);
        sGrove.stake(0);
    }

    function test_unstake_fullCooldownCycle() public {
        _stakeGrove(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_InsufficientStake.selector, 1_001e18, 1_000e18));
        sGrove.requestUnstake(1_001e18);

        uint64 expectedRelease = uint64(block.timestamp) + uint64(Config.SGROVE_UNBONDING_PERIOD);
        vm.expectEmit(true, true, false, true);
        emit SGrove.UnstakeRequested(alice, 0, 400e18, expectedRelease);
        vm.prank(alice);
        uint256 id = sGrove.requestUnstake(400e18);
        assertEq(sGrove.stakedOf(alice), 600e18, "unbonding stake leaves the active total immediately");
        assertEq(sGrove.totalStaked(), 600e18);

        // cannot claim before the ADR-0014 cooldown elapses
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_StillUnbonding.selector, id, expectedRelease));
        sGrove.claimUnstake(id);

        vm.warp(uint256(expectedRelease));
        vm.expectEmit(true, true, false, true);
        emit SGrove.UnstakeClaimed(alice, id, 400e18);
        vm.prank(alice);
        sGrove.claimUnstake(id);
        assertEq(grove.balanceOf(alice), 400e18);

        // no double-claim; unknown ids revert
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, id));
        sGrove.claimUnstake(id);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, 9));
        sGrove.claimUnstake(9);
        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.requestUnstake(0);
        vm.stopPrank();
    }

    // ── coverage reserve + coverShortfall (the ICascadeBackstop contract) ─

    function test_fundCoverage_permissionless() public {
        _fundCoverage(100_000e18);
        assertEq(sGrove.coverageReserve(), 100_000e18);
        assertEq(sGrove.coverageCapacity(), 100_000e18, "ADR-0035 capacity is the live reserve");

        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.fundCoverage(0);
    }

    function testFuzz_counterfactualCapacityAndPublishedParametersAreExact(uint256 reserve) public view {
        reserve = bound(reserve, 0, type(uint192).max);

        (uint16 publishedBps, uint256 absoluteCap) = sGrove.coverageCapParameters();
        assertEq(publishedBps, Config.BPS);
        assertEq(absoluteCap, type(uint256).max);
        assertEq(sGrove.coverageCapacityAt(reserve), reserve, "ADR-0035 counterfactual must be identity");
    }

    function test_capacityWritersDoNotMutateVaultHurdleDuringPastDueWorkout() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000_000e18);
        vault.deposit(1_000_000e18, alice);
        vm.stopPrank();

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        // OWNER DECISION (Forest Road, 2026-08-07): an UNATTESTED, permissionless past-due mark
        // carries the governed forward weight (`CollateralRegistry.pastDueWeightBps`, 50% at
        // launch) of the charge the cascade could EXECUTE, not the full outstanding an attested
        // `declareDefault` asserts. The GROSS pool is still the whole 1,000,000e18 — see the
        // `performanceFeeImpairment` assertions below, which are deliberately unweighted.
        // The executable clamp is not binding here: the vault holds 1,000,000e18.
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18);
        uint256 hurdleBefore = _vaultHurdleAssets();
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        _mintUSDfrTo(bob, 1_000_000e18);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), 1_000_000e18);
        sGrove.fundCoverage(1_000_000e18);
        vm.stopPrank();

        // ADR-0035 makes the whole 1,000,000e18 reserve executable immediately.
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
        assertEq(defaultManager.performanceFeeImpairment(), 1_000_000e18);
        assertEq(_vaultHurdleAssets(), hurdleBefore, "junior funding must not create a permanent HWM credit");
        (, uint256 fundingFeeShares) = vault.accrueFees();
        assertEq(fundingFeeShares, 0, "permissionless backstop funding is not senior performance");

        _clearPastDue(id, keccak256("sgrove-capacity-cure"));
        (, uint256 cureFeeShares) = vault.accrueFees();
        assertEq(cureFeeShares, 0, "a full cure after sGROVE capacity writes cannot mint performance shares");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore);
    }

    function test_coverShortfall_drainsOnlyTheLiveReserve() public {
        _fundCoverage(100_000e18);
        // A request inside the live reserve is delivered in full.
        vm.expectEmit(true, false, false, true);
        emit ICascadeBackstop.ShortfallCovered(address(defaultManager), 80_000e18, 80_000e18);
        vm.prank(address(defaultManager));
        uint256 covered = sGrove.coverShortfall(EVENT_1, 80_000e18);
        assertEq(covered, 80_000e18, "live reserve is the only bound");
        assertEq(usdfr.balanceOf(address(defaultManager)), 80_000e18, "delivered in-call");
        assertEq(sGrove.coverageReserve(), 20_000e18, "physical reserve decremented exactly");

        // The same event may consume what remains; its id owns no separate allowance.
        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(EVENT_1, 80_000e18), 20_000e18, "same event drains the reserve");

        // A later event gets zero until actual replenishment.
        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(EVENT_2, 80_000e18), 0, "empty layer two cannot protect later loss");
    }

    /// @dev ADR-0035: chunking and one-shot realization share the same physical reserve bound.
    function test_coverShortfall_chunkingOneEventConsumesExactlyTheReserve() public {
        _fundCoverage(100_000e18);
        uint256 drawn;
        // Ten bites at the same event consume the same 100k a one-shot request could consume.
        for (uint256 i = 0; i < 10; ++i) {
            vm.prank(address(defaultManager));
            drawn += sGrove.coverShortfall(EVENT_1, 80_000e18);
        }
        assertEq(drawn, 100_000e18, "chunking cannot exceed or preserve the shared reserve");
        assertEq(sGrove.coverageReserve(), 0, "reserve is exhausted");
        (uint256 eventDrawn, uint256 eventCap) = sGrove.eventCoverage(EVENT_1);
        assertEq(eventDrawn, 100_000e18, "cumulative draw remains observable");
        assertEq(eventCap - eventDrawn, 0, "live reach is zero, not a frozen snapshot");
    }

    /// @dev Many small chunks can never exceed the physical reserve.
    function testFuzz_coverShortfall_chunkedDrawsNeverExceedTheReserve(uint256 chunk, uint8 times) public {
        _fundCoverage(100_000e18);
        chunk = bound(chunk, 1, 60_000e18);
        uint256 n = uint256(bound(times, 1, 20));
        uint256 drawn;
        for (uint256 i = 0; i < n; ++i) {
            vm.prank(address(defaultManager));
            drawn += sGrove.coverShortfall(EVENT_1, chunk);
        }
        assertLe(drawn, 100_000e18, "cumulative draw never exceeds the funded reserve");
        assertEq(sGrove.coverageReserve(), 100_000e18 - drawn, "reserve decremented exactly");
    }

    function test_coverShortfall_smallRequestFullyCovered() public {
        _fundCoverage(100_000e18);
        vm.prank(address(defaultManager));
        uint256 covered = sGrove.coverShortfall(EVENT_1, 10_000e18);
        assertEq(covered, 10_000e18, "requests inside the reserve cover fully");
    }

    function test_coverShortfall_emptyReserveCoversZero() public {
        vm.prank(address(defaultManager));
        uint256 covered = sGrove.coverShortfall(EVENT_1, 10_000e18);
        assertEq(covered, 0);
    }

    function test_coverShortfall_guards() public {
        vm.prank(address(defaultManager));
        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.coverShortfall(EVENT_1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.CREDIT_ROLE)
        );
        vm.prank(alice);
        sGrove.coverShortfall(EVENT_1, 1e18);
    }

    // ── rewards ──────────────────────────────────────────────────────────

    uint256 internal constant DUR = 7 days; // Config.SGROVE_REWARDS_DURATION
    // Streaming loses at most (duration-1) wei to rate flooring, plus a few wei of
    // per-token/per-staker mulDiv rounding — negligible vs the 1e18-scale amounts here.
    uint256 internal constant STREAM_DUST = 1e7;

    function _notifyRewards(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.notifyRewards(amount);
        vm.stopPrank();
    }

    // AUDIT FIX (R4-EC1): rewards now STREAM over the duration rather than landing
    // instantly. Warping to periodFinish streams the whole (floored) amount, so the
    // pro-rata split matches the old instant behaviour up to rate-flooring dust.
    function test_rewards_proRataByStake() public {
        _stakeGrove(alice, 300e18);
        _stakeGrove(secondCurator, 100e18); // any address can stake
        _notifyRewards(1_000e18);
        assertEq(sGrove.pendingRewards(alice), 0, "nothing streamed yet at t0");
        vm.warp(block.timestamp + DUR); // fully stream

        assertApproxEqAbs(sGrove.pendingRewards(alice), 750e18, STREAM_DUST, "3/4 by stake");
        assertApproxEqAbs(sGrove.pendingRewards(secondCurator), 250e18, STREAM_DUST, "1/4 by stake");

        vm.prank(alice);
        uint256 got = sGrove.claimRewards();
        assertApproxEqAbs(got, 750e18, STREAM_DUST);
        assertEq(usdfr.balanceOf(alice), got);
        assertEq(sGrove.pendingRewards(alice), 0);

        vm.prank(alice);
        vm.expectRevert(SGrove.SGrove_NothingToClaim.selector);
        sGrove.claimRewards();
    }

    function test_rewards_unbondingStakeStopsEarning() public {
        _stakeGrove(alice, 100e18);
        _stakeGrove(secondCurator, 100e18);
        vm.prank(alice);
        sGrove.requestUnstake(100e18); // alice exits the earning set immediately
        _notifyRewards(500e18);
        vm.warp(block.timestamp + DUR);
        assertEq(sGrove.pendingRewards(alice), 0, "unbonding earns nothing");
        assertApproxEqAbs(sGrove.pendingRewards(secondCurator), 500e18, STREAM_DUST, "remaining staker earns all");
    }

    // A staker who joins partway through a stream earns only the portion streamed AFTER
    // they join — the streaming analogue of "late staker earns only new rewards".
    function test_rewards_lateStakerEarnsOnlyNewRewards() public {
        _stakeGrove(alice, 100e18);
        _notifyRewards(100e18); // 100 over 7d, alice sole staker
        vm.warp(block.timestamp + DUR / 2); // half streams to alice alone (~50)
        _stakeGrove(secondCurator, 100e18); // joins at the halfway point
        vm.warp(block.timestamp + DUR / 2); // remaining ~50 splits 50/50 (~25 each)

        assertApproxEqAbs(sGrove.pendingRewards(alice), 75e18, STREAM_DUST, "50 solo + 25 shared");
        assertApproxEqAbs(sGrove.pendingRewards(secondCurator), 25e18, STREAM_DUST, "only the post-join half");
    }

    // AUDIT FIX (R4-EC1): a front-runner who stakes right before a notification and exits
    // immediately after earns ~nothing — the deposit-before-harvest sandwich is defeated
    // because rewards accrue per second held, not as a lump sum.
    function test_rewards_sandwichEarnsNothing() public {
        _stakeGrove(alice, 100e18); // honest long-term staker
        _stakeGrove(secondCurator, 100e18); // the sandwicher, in position pre-notify
        _notifyRewards(700e18);
        vm.prank(secondCurator);
        sGrove.requestUnstake(100e18); // exits in the same block as the notify
        vm.warp(block.timestamp + DUR);

        assertEq(sGrove.pendingRewards(secondCurator), 0, "sandwich captured nothing");
        assertApproxEqAbs(sGrove.pendingRewards(alice), 700e18, STREAM_DUST, "honest staker earns it all");
    }

    function test_notifyRewards_guards() public {
        vm.expectRevert(SGrove.SGrove_NoStakers.selector);
        sGrove.notifyRewards(1e18);
        _stakeGrove(alice, 1e18);
        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.notifyRewards(0);
    }

    /// @dev AUDIT REGRESSION (R4-EC1): a notification too small to yield a non-zero
    ///      per-second rate reverts rather than silently stranding USDfr. The threshold
    ///      is now the duration (amount/duration must be >= 1 wei/sec), not the stake.
    /// @dev audit R5-UP1: notifyRewards must fail LOUD (not a raw 0x12 panic) if the
    ///      streaming window was never seeded — the state a broken in-place upgrade
    ///      (appended fields, no reinitializer) would leave. Unreachable via the public
    ///      API (initialize seeds it, setRewardsDuration rejects 0), so we force it via
    ///      storage: rewardsDuration packs at namespaced-slot base+10, byte offset 16.
    function test_notifyRewards_zeroDurationRevertsLoud() public {
        _stakeGrove(alice, 1_000e18);
        bytes32 base = 0x8947529af82e5c31b771fc0b2221fa39dd660e5ffcb6bd0eae7a66d91fc54b00;
        // periodFinish/lastUpdateTime (same slot, lower offsets) are still 0 here, so
        // zeroing the whole slot only clears rewardsDuration.
        vm.store(address(sGrove), bytes32(uint256(base) + 10), bytes32(0));
        (,,, uint64 dur) = sGrove.rewardSchedule();
        assertEq(dur, 0, "rewardsDuration zeroed for the test");
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), 1e18);
        vm.expectRevert(SGrove.SGrove_BadParams.selector);
        sGrove.notifyRewards(1e18);
        vm.stopPrank();
    }

    function test_notifyRewards_dustReverts() public {
        _stakeGrove(alice, 1_000e18);
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), 1e18);
        // (DUR - 1) wei over DUR seconds → rate floors to 0 → dust guard reverts
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_RewardDust.selector, DUR - 1, DUR));
        sGrove.notifyRewards(DUR - 1);
        // exactly DUR wei is 1 wei/sec — accepted
        sGrove.notifyRewards(DUR);
        vm.stopPrank();
        vm.warp(block.timestamp + DUR);
        assertGt(sGrove.pendingRewards(alice), 0);
    }

    // Notifying mid-stream rolls the undistributed remainder into a fresh full-duration
    // stream — nothing is lost and nothing over-distributes.
    function test_notifyRewards_rollsOverRemainder() public {
        _stakeGrove(alice, 100e18);
        _notifyRewards(700e18);
        vm.warp(block.timestamp + DUR / 2); // ~350 streamed, ~350 remaining
        _notifyRewards(700e18); // roll the ~350 remainder + 700 into a new 7d stream
        (uint256 rate, uint64 finish,,) = sGrove.rewardSchedule();
        assertEq(finish, uint64(block.timestamp) + DUR, "fresh full-duration window");
        // rate ≈ (700 + 350 remaining) / 7d
        assertApproxEqAbs(rate, uint256(1050e18) / DUR, 1e6, "blended rate");
        vm.warp(block.timestamp + DUR);
        // alice is the only staker throughout → she earns the full 1400 (minus dust)
        assertApproxEqAbs(
            sGrove.pendingRewards(alice), 1400e18, STREAM_DUST, "all funded rewards stream to the sole staker"
        );
    }

    // AUDIT FIX (M-1): a mid-stream notification that would LOWER the drip rate is
    // rejected, so nobody can call notifyRewards(dust) to perpetually re-stretch and
    // dilute the remaining stream. Rate-preserving/raising top-ups are still allowed.
    function test_notifyRewards_cannotDiluteMidStream() public {
        _stakeGrove(alice, 100e18);
        _notifyRewards(700e18);
        (uint256 rate0,,,) = sGrove.rewardSchedule();
        vm.warp(block.timestamp + DUR / 2); // half-streamed, half remaining

        // a dust notify would re-spread the remainder over a fresh 7d → lower rate → revert
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                SGrove.SGrove_RewardRateWouldDecrease.selector,
                (1 + (DUR / 2) * rate0) / DUR, // blended rate of a 1-wei mid-stream notify
                rate0
            )
        );
        sGrove.notifyRewards(1);
        vm.stopPrank();

        // a genuine top-up that raises the rate is accepted (the legit rollover path)
        _notifyRewards(700e18);
        (uint256 rate1,,,) = sGrove.rewardSchedule();
        assertGe(rate1, rate0, "legit top-up holds or raises the rate");
    }

    function test_rewardPerToken_zeroWhileNoStakers() public view {
        // no stakers → rewardPerToken is flat; the view never divides by zero
        assertEq(sGrove.rewardPerToken(), 0);
        assertEq(sGrove.lastTimeRewardApplicable(), 0);
    }

    function test_earned_aliasesPending() public {
        _stakeGrove(alice, 100e18);
        _notifyRewards(700e18);
        vm.warp(block.timestamp + DUR / 2);
        assertEq(sGrove.earned(alice), sGrove.pendingRewards(alice), "earned == pendingRewards");
        assertGt(sGrove.earned(alice), 0);
    }

    function test_setRewardsDuration_setsWhenIdle() public {
        (,,, uint64 dur0) = sGrove.rewardSchedule();
        assertEq(dur0, DUR);
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit SGrove.RewardsDurationSet(14 days);
        sGrove.setRewardsDuration(14 days);
        (,,, uint64 dur1) = sGrove.rewardSchedule();
        assertEq(dur1, 14 days);
    }

    function test_setRewardsDuration_guards() public {
        // bounds
        vm.startPrank(admin);
        vm.expectRevert(SGrove.SGrove_BadParams.selector);
        sGrove.setRewardsDuration(0);
        vm.expectRevert(SGrove.SGrove_BadParams.selector);
        sGrove.setRewardsDuration(365 days + 1);
        vm.stopPrank();

        // cannot change mid-stream
        _stakeGrove(alice, 100e18);
        _notifyRewards(700e18);
        (, uint64 finish,,) = sGrove.rewardSchedule();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_StreamActive.selector, finish));
        sGrove.setRewardsDuration(14 days);

        // once the stream ends, it can be changed again
        vm.warp(block.timestamp + DUR);
        vm.prank(admin);
        sGrove.setRewardsDuration(14 days);
    }

    function test_setRewardsDuration_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        sGrove.setRewardsDuration(14 days);
    }

    /// @dev AUDIT REGRESSION (L): unbonding period is bounded so it can't overflow
    ///      releaseAt into a small value (which would defeat the cooldown).
    function test_setUnbondingPeriod_upperBound() public {
        vm.startPrank(admin);
        sGrove.setUnbondingPeriod(365 days); // the ceiling is allowed
        uint64 p = sGrove.params();
        assertEq(p, 365 days);
        vm.expectRevert(SGrove.SGrove_BadParams.selector);
        sGrove.setUnbondingPeriod(365 days + 1);
        vm.stopPrank();
    }

    // ── governance setters ───────────────────────────────────────────────

    function test_setters_boundsAndAccess() public {
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true);
        emit SGrove.UnbondingPeriodSet(7 days);
        sGrove.setUnbondingPeriod(7 days);
        vm.expectRevert(SGrove.SGrove_BadParams.selector);
        sGrove.setUnbondingPeriod(0);
        vm.stopPrank();
    }

    // ── pause: user paths only, never the cascade ────────────────────────

    function test_pause_blocksUserPathsNeverCoverage() public {
        _stakeGrove(alice, 100e18);
        _fundCoverage(10_000e18);
        vm.prank(guardian);
        sGrove.pause();

        vm.startPrank(alice);
        grove.approve(address(sGrove), 1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sGrove.stake(1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sGrove.requestUnstake(1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sGrove.claimUnstake(0);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sGrove.claimRewards();
        vm.stopPrank();

        // the cascade is NEVER pausable
        vm.prank(address(defaultManager));
        uint256 covered = sGrove.coverShortfall(EVENT_1, 1_000e18);
        assertEq(covered, 1_000e18);

        vm.prank(guardian);
        sGrove.unpause();
        vm.prank(alice);
        sGrove.requestUnstake(1);
    }

    function test_pause_onlyGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        sGrove.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        sGrove.unpause();
    }

    // ── upgrade authorization ────────────────────────────────────────────

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new SGrove());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        sGrove.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        sGrove.upgradeToAndCall(newImpl, "");
    }

    // ── fuzz: reward conservation + live-reserve exactness ──────────────

    /// @dev Streamed reward accounting conserves value: for any two stakes and two
    ///      streamed distributions (each fully warped through), stakers together can never
    ///      claim more than was notified, and recover it all up to bounded flooring dust.
    function testFuzz_rewards_conserveValue(uint256 a, uint256 b, uint256 r1, uint256 r2) public {
        a = bound(a, 1e18, 100_000_000e18);
        b = bound(b, 1e18, 100_000_000e18);
        // >= 1e18 keeps each rate well above 1 wei/sec; round to whole USDC units (1e12)
        // as the USDfr mock requires.
        r1 = bound(r1, 1e18, 1_000_000e18);
        r2 = bound(r2, 1e18, 1_000_000e18);
        r1 -= r1 % 1e12;
        r2 -= r2 % 1e12;
        _stakeGrove(alice, a);
        _notifyRewards(r1);
        vm.warp(block.timestamp + DUR); // fully stream r1 to alice
        _stakeGrove(secondCurator, b);
        _notifyRewards(r2);
        vm.warp(block.timestamp + DUR); // fully stream r2 to alice+second

        uint256 pa = sGrove.pendingRewards(alice);
        uint256 pb = sGrove.pendingRewards(secondCurator);
        assertLe(pa + pb, r1 + r2, "never over-distributes");
        // dust = rate flooring (< DUR wei per stream) + per-token index granularity
        // (~stake/WAD per settlement) — bounded, never in stakers' favour
        uint256 maxDust = (a + b) / 1e18 * 2 + 2 * DUR + 8;
        assertGe(pa + pb + maxDust, r1 + r2, "dust bounded");
        // r1 streamed entirely while alice was the sole staker → she captured all of it
        assertGe(pa + maxDust, r1, "first stream belongs to the sole staker");
    }

    /// @dev ADR-0035 delivery is exact for any reserve and request.
    function testFuzz_coverShortfall_liveReserveExact(uint256 reserve, uint256 request) public {
        reserve = bound(reserve, 0, 10_000_000e18);
        reserve -= reserve % 1e12;
        request = bound(request, 1, 10_000_000e18);
        if (reserve != 0) _fundCoverage(reserve);

        vm.prank(address(defaultManager));
        uint256 covered = sGrove.coverShortfall(EVENT_1, request);
        assertEq(covered, request < reserve ? request : reserve, "covered = min(request, live reserve)");
        assertEq(sGrove.coverageReserve(), reserve - covered, "reserve decremented exactly");
        assertLe(covered, request, "ICascadeBackstop: covered <= amount");
    }
}
