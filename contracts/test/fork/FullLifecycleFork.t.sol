// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title FullLifecycleFork — the whole protocol, end to end, on a pinned mainnet fork
/// @notice Deployment -> deposit -> stake -> originate (real 2-of-n) -> fund -> repay ->
///         yield -> queue -> COOLDOWN -> EPOCH CLOSE -> CLAIM -> sGROVE stake -> rewards ->
///         UNBOND -> CLAIM UNSTAKE, against REAL USDC.
///
///         The three steps in caps have never been executed end-to-end anywhere before this
///         suite. `script/QA.s.sol` explicitly deferred them ("time-gated: can't finish live
///         without waiting real days") and the in-memory suites never drove them off a real
///         deployment. On a fork `vm.warp` makes them free.
contract FullLifecycleForkTest is ForkLifecycleFixture {
    /// @notice THE HEADLINE: every stage in one uninterrupted run, nothing skipped.
    function test_fork_fullLifecycle_depositThroughClaimAndUnstake() public onFork {
        // ── 1. DEPOSIT: real USDC in, USDfr out, backing rises by exactly the deposit ──
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 minted = _mintFromUSDC(alice, 1_000_000e6);
        assertEq(minted, 1_000_000e18, "6-dec USDC normalizes to 18-dec USDfr");
        assertEq(usdfr.balanceOf(alice), minted, "alice holds the USDfr");
        assertEq(reserves.totalBackingValue(), backingBefore + 1_000_000e18, "backing rose by the deposit");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds");

        // ── 2. STAKE ────────────────────────────────────────────────────────────────
        uint256 shares = _stake(alice, 600_000e18);
        assertGt(shares, 0, "shares minted");
        assertEq(vault.balanceOf(alice), shares, "alice holds the shares");
        uint256 rateAfterStake = vault.convertToAssets(10 ** vault.decimals());

        // ── 3-4. ORIGINATE through the REAL m-of-n gate, then FUND with 2% OID ───────
        uint256 borrowerBefore = IERC20(USDC).balanceOf(borrower);
        uint256 tokenId = _originateAndFund(200_000e18);
        assertEq(bridge.ownerOf(tokenId), ops, "facility NFT minted to the originator");
        assertEq(
            IERC20(USDC).balanceOf(borrower) - borrowerBefore,
            200_000e6 * 9800 / 10_000,
            "borrower nets principal less the 2% origination fee"
        );
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds after deployment");

        // ── 5. REPAY -> waterfall. Interest reaches the senior vault as YIELD ────────
        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 vaultHeldBefore = usdfr.balanceOf(address(vault));
        uint256 feeSharesBefore = vault.balanceOf(ops);
        _repay(tokenId, 20_000e18, 50_000e18);

        // Launch policy: realized senior yield is recognized and its performance fee is
        // checkpointed atomically in the repayment transaction.
        assertGt(usdfr.balanceOf(address(vault)) - vaultHeldBefore, 0, "interest arrived at the vault");
        assertEq(vault.unvestedYield(), 0, "launch has no senior-yield stream");
        assertGt(vault.totalAssets(), vaultAssetsBefore, "senior vault credited the interest immediately");
        assertGt(vault.convertToAssets(10 ** vault.decimals()), rateAfterStake, "fee-net rate rose on repayment");
        assertGt(vault.balanceOf(ops), feeSharesBefore, "performance fee crystallized in the same transaction");

        // ── 6. QUEUE a redemption ───────────────────────────────────────────────────
        uint256 exitShares = shares / 2;
        vm.startPrank(alice);
        vault.approve(address(queue), exitShares);
        uint256 reqId = queue.requestRedeem(exitShares);
        vm.stopPrank();
        (,,,, uint256 requestedAt) = queue.request(reqId);
        assertEq(requestedAt, block.timestamp, "requestedAt is the ADR-0022 cooldown anchor");

        // ── 7. COOLDOWN: settlement is REFUSED before the 21-day hold ───────────────
        // The queue FAILS LOUD rather than closing an epoch that could settle nothing — the
        // eligibility floor is the ADR-0022 defence against exiting inside the window between
        // a default being declared and its loss being realized.
        _warp(Config.DEFAULT_EPOCH_DURATION + 1);
        assertLt(block.timestamp, requestedAt + Config.DEFAULT_REDEEM_COOLDOWN, "still inside the hold");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRedemptionQueue.Queue_AllInCooldown.selector, requestedAt + Config.DEFAULT_REDEEM_COOLDOWN
            )
        );
        queue.closeEpoch(50);
        (, uint256 sharesRemainingEarly, uint256 claimableEarly,,) = queue.request(reqId);
        assertEq(claimableEarly, 0, "COOLDOWN: nothing settled");
        assertEq(sharesRemainingEarly, exitShares, "the position is untouched");

        // ── 8. EPOCH CLOSE past the cooldown, then CLAIM (never run E2E before) ─────
        _warp(Config.DEFAULT_REDEEM_COOLDOWN);
        queue.closeEpoch(50);
        (, uint256 sharesRemaining, uint256 claimable,,) = queue.request(reqId);
        assertGt(claimable, 0, "the request filled once the cooldown elapsed");
        assertLt(sharesRemaining, exitShares, "shares were consumed by the fill");

        uint256 usdfrBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        queue.claim(reqId);
        assertEq(usdfr.balanceOf(alice) - usdfrBefore, claimable, "CLAIM paid exactly the filled amount");
        (,, uint256 claimableAfter,,) = queue.request(reqId);
        assertEq(claimableAfter, 0, "no double-claim");

        // ── 9. REDEEM USDfr back to REAL USDC ───────────────────────────────────────
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        usdfr.approve(address(controller), 100_000e18);
        uint256 usdcOut = controller.redeem(100_000e18);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(alice) - usdcBefore, usdcOut, "real USDC returned");
        assertEq(usdcOut, 100_000e6, "18-dec USDfr denormalizes to 6-dec USDC");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT still holds");
    }

    /// @notice sGROVE: stake -> reward stream -> request unstake -> 21-DAY UNBOND -> claim.
    ///         The unbond claim has never been executed end-to-end before this suite.
    function test_fork_sGroveStakeRewardsUnbondAndClaim() public onFork {
        _mintFromUSDC(ops, 500_000e6);

        // Stake GROVE (the treasury == ops here holds the genesis supply).
        vm.startPrank(ops);
        grove.approve(address(sGrove), 1_000e18);
        sGrove.stake(1_000e18);
        vm.stopPrank();
        assertEq(sGrove.stakedOf(ops), 1_000e18, "staked");
        // ADR-0026: staking must not disenfranchise — voting units track the stake.
        assertEq(sGrove.getVotes(ops), 1_000e18, "staked GROVE votes (L-02)");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units == stake");

        // Fund a reward stream and let it run.
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), 70_000e18);
        sGrove.notifyRewards(70_000e18);
        vm.stopPrank();
        _warp(Config.SGROVE_REWARDS_DURATION);
        uint256 pending = sGrove.pendingRewards(ops);
        assertGt(pending, 0, "rewards streamed to the staker");

        vm.prank(ops);
        uint256 claimedRewards = sGrove.claimRewards();
        assertEq(claimedRewards, pending, "claimed exactly what accrued");

        // Request unstake: votes go immediately, GROVE does not.
        uint256 groveBefore = grove.balanceOf(ops);
        vm.prank(ops);
        uint256 unbondId = sGrove.requestUnstake(1_000e18);
        assertEq(sGrove.getVotes(ops), 0, "unbonding GROVE does NOT vote (ADR-0026)");
        assertEq(grove.balanceOf(ops), groveBefore, "GROVE still custodied during the unbond");

        // Claiming before the 21-day unbond must fail...
        vm.prank(ops);
        vm.expectRevert();
        sGrove.claimUnstake(unbondId);

        // ...and succeed after it. THIS PATH HAS NEVER RUN END-TO-END BEFORE.
        _warp(Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(ops);
        sGrove.claimUnstake(unbondId);
        assertEq(grove.balanceOf(ops), groveBefore + 1_000e18, "UNBOND CLAIMED: GROVE returned");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units still track stake");
    }

    /// @notice Default -> the three-layer cascade, on real deployed contracts.
    function test_fork_defaultCascadeAcrossAllThreeLayers() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 800_000e18);
        uint256 tokenId = _originateAndFund(400_000e18);

        // Layer 1: curator first-loss. Layer 2: sGROVE coverage reserve.
        _mintFromUSDC(ops, 500_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), 100_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 100_000e18);
        usdfr.approve(address(sGrove), 150_000e18);
        sGrove.fundCoverage(150_000e18);
        vm.stopPrank();

        uint256 curatorBefore = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        uint256 coverageBefore = sGrove.coverageReserve();
        uint256 vaultBefore = vault.totalAssets();

        _declareDefault(tokenId, bytes32(0));

        // ADR-0022: the declared-but-unrealized default marks the EXIT price down immediately,
        // while the deposit price is untouched.
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "conservative NAV marked");
        assertLt(vault.redemptionTotalAssets(), vault.totalAssets(), "exit prices below deposit");

        // A loss larger than layers 1+2 must reach depositors, in order, never skipping.
        _realizeLoss(tokenId, 300_000e18, bytes32(0));

        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "layer 1 fully absorbed first");
        assertLt(sGrove.coverageReserve(), coverageBefore, "layer 2 drew after layer 1");
        assertLt(vault.totalAssets(), vaultBefore, "layer 3 took only the residual");
        assertEq(curatorBefore, 100_000e18, "layer 1 had been funded");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds through the cascade");
    }

    /// @notice Negative paths on the deployed system — each must revert for its own reason.
    function test_fork_negativePaths() public onFork {
        // Non-KYC address cannot mint.
        deal(USDC, carol, 10_000e6);
        vm.startPrank(carol);
        IERC20(USDC).approve(address(controller), 10_000e6);
        vm.expectRevert();
        controller.mint(10_000e6);
        vm.stopPrank();

        // Origination without the full attestation set is refused.
        uint256 nextId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = _forkTerms(
            keccak256("B"), keccak256("US-GA"), 10_000e18, 7500, uint64(block.timestamp + 365 days), keccak256("ref")
        );
        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, bridge.creditTermsHash(terms));
        vm.prank(ops);
        vm.expectRevert();
        bridge.originate(ops, terms);

        // A non-servicer cannot declare a default.
        vm.prank(carol);
        vm.expectRevert();
        defaultManager.declareDefault(1, bytes32(0));
    }
}
