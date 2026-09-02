// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {SGrove} from "../../src/SGrove.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title EXP5_TheftForkTest — DIRECT FUND THEFT attempts against the full protocol on a mainnet fork
/// @notice ATTACK GOAL: drain the ReserveManager USDC, withdraw another user's sGROVE stake or
///         sUSDfr shares, sweep the sGROVE coverage reserve, or extract the curator first-loss
///         pool, using every privileged entry point reachable from an unprivileged account plus
///         any token-transfer path that does not check ownership.
///
///         All attacks below are driven by `carol`, who is an ORDINARY funded wallet: NOT KYC'd,
///         holds NONE of CONTROLLER_ROLE / CREDIT_ROLE / SETTLEMENT_KEEPER_ROLE / RESERVE_ADMIN,
///         and owns none of the victim positions. Victim state (real reserve USDC, a real sGROVE
///         stake, real sUSDfr shares, a real queued redemption) is established through the normal
///         KYC'd user paths so that a SUCCESSFUL drain would be provable as a state violation.
///
///         RESULT: every route is blocked. Each test asserts the SPECIFIC custom error the protocol
///         reverts with, and re-reads the target balance/position afterwards to prove nothing moved.
///         `DSRA` is out of scope by construction: ReserveManager's own NatSpec records that
///         "Mainnet v1 intentionally has no ... DSRA", so there is no DSRA balance to sweep.
///
///         MAINNET SAFETY: inherits ForkLifecycleFixture, which forks mainnet locally and never
///         broadcasts. `onFork` SKIPs when no RPC is configured.
contract EXP5_TheftForkTest is ForkLifecycleFixture {
    // The attacker: an ordinary, unprivileged, non-KYC'd wallet funded with USDC in setUp.
    function _attacker() internal view returns (address) {
        return carol;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TARGET 1: ReserveManager USDC custody.
    //   Routes: releaseUSDC (CONTROLLER_ROLE), recordDeployment / recordPrincipalWritedown /
    //   recordPayment (CREDIT_ROLE). None reachable from an unprivileged caller.
    // ─────────────────────────────────────────────────────────────────────────
    function test_EXP5_reserveManager_cannotBeDrainedByUnprivilegedCaller() public onFork {
        address attacker = _attacker();

        // Establish real loot: alice mints USDfr from 1,000,000 real USDC, which is custodied by
        // the reserve as idle backing.
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 reserveUsdcBefore = IERC20(USDC).balanceOf(address(reserves));
        uint256 idleBefore = reserves.idleReserve();
        uint256 attackerUsdcBefore = IERC20(USDC).balanceOf(attacker);
        assertGt(reserveUsdcBefore, 0, "precondition: reserve must hold USDC to steal");

        // Route 1: the controller-only out-door.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CONTROLLER_ROLE
            )
        );
        reserves.releaseUSDC(attacker, 500_000e6);

        // Route 2: the credit-layer deployment door (moves USDC to an arbitrary `to`).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        reserves.recordDeployment(999_999, attacker, 500_000e6);

        // Route 3: the write-down door (would erase backing so a redeem over-pays).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        reserves.recordPrincipalWritedown(999_999, 500_000e18);

        // Route 4: the atomic payment door (would let the attacker "account" a repayment it did
        // not make and later pull the principal leg).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        reserves.recordPayment(999_999, attacker, 1, 0);

        // Nothing moved.
        assertEq(IERC20(USDC).balanceOf(address(reserves)), reserveUsdcBefore, "reserve USDC changed");
        assertEq(reserves.idleReserve(), idleBefore, "reserve idle backing changed");
        assertEq(IERC20(USDC).balanceOf(attacker), attackerUsdcBefore, "attacker USDC changed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TARGET 2: another user's sGROVE stake, and the sGROVE coverage reserve.
    //   Stake/unstake positions are strictly msg.sender-bound and non-transferable; the coverage
    //   reserve exits only through the CREDIT_ROLE-gated `coverShortfall`.
    // ─────────────────────────────────────────────────────────────────────────
    function test_EXP5_sGrove_cannotWithdrawAnotherStakeNorSweepCoverage() public onFork {
        address attacker = _attacker();
        uint256 groveAmt = 1_000e18;

        // Bob acquires a real sGROVE stake. GROVE genesis supply is minted to the treasury
        // (== this test contract); fall back to `deal` if seeding moved it.
        if (grove.balanceOf(address(this)) >= groveAmt) {
            grove.transfer(bob, groveAmt);
        } else {
            deal(address(grove), bob, groveAmt);
        }
        vm.startPrank(bob);
        grove.approve(address(sGrove), groveAmt);
        sGrove.stake(groveAmt);
        vm.stopPrank();
        assertEq(sGrove.stakedOf(bob), groveAmt, "precondition: bob must hold a real stake");

        uint256 sgroveGroveBefore = grove.balanceOf(address(sGrove));

        // Route 1: attacker tries to start unbonding against bob's stake. requestUnstake reads
        // only msg.sender's balance, which is zero.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_InsufficientStake.selector, groveAmt, uint256(0)));
        sGrove.requestUnstake(groveAmt);

        // Route 2: bob starts a legitimate unbond, then the attacker tries to claim it. claimUnstake
        // reads only msg.sender's own unbond list, so the attacker sees an empty list.
        vm.prank(bob);
        uint256 unbondId = sGrove.requestUnstake(groveAmt);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_UnknownUnbond.selector, unbondId));
        sGrove.claimUnstake(unbondId);

        // Route 3: attacker tries to sweep the backstop coverage reserve directly. coverShortfall
        // transfers USDfr to the caller and is CREDIT_ROLE-gated (only the DefaultManager).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        sGrove.coverShortfall(1, 1e18);

        // Bob's staked+unbonding GROVE is intact in custody; the attacker got nothing.
        assertEq(grove.balanceOf(address(sGrove)), sgroveGroveBefore, "sGrove GROVE custody changed");
        assertEq(grove.balanceOf(attacker), 0, "attacker received GROVE");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TARGET 3: another user's sUSDfr shares.
    //   ERC-4626 exits are queue-only; shares are ERC-20 but only move with an allowance.
    // ─────────────────────────────────────────────────────────────────────────
    function test_EXP5_sUSDfr_cannotRedeemWithdrawOrPullAnotherUsersShares() public onFork {
        address attacker = _attacker();

        // Bob acquires real sUSDfr shares through the normal mint -> stake path.
        _mintFromUSDC(bob, 500_000e6);
        uint256 shares = _stake(bob, 500_000e18);
        assertGt(shares, 0, "precondition: bob must hold shares");
        uint256 bobSharesBefore = vault.balanceOf(bob);

        // Route 1: attacker redeems bob's shares as `owner`. maxRedeem(non-queue) == 0.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, bob, shares, uint256(0))
        );
        vault.redeem(shares, attacker, bob);

        // Route 2: attacker withdraws assets naming bob as `owner`. maxWithdraw(non-queue) == 0.
        uint256 assetsWanted = 100_000e18;
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, bob, assetsWanted, uint256(0)
            )
        );
        vault.withdraw(assetsWanted, attacker, bob);

        // Route 3: attacker pulls bob's shares via ERC-20 transferFrom with no allowance.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, attacker, uint256(0), shares)
        );
        vault.transferFrom(bob, attacker, shares);

        // Route 4: even bob cannot bypass the queue to redeem his OWN shares instantly
        // (the sole exit is the RedemptionQueue; maxRedeem(bob) == 0 because bob != queue).
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, bob, shares, uint256(0))
        );
        vault.redeem(shares, bob, bob);

        assertEq(vault.balanceOf(bob), bobSharesBefore, "bob's shares changed");
        assertEq(vault.balanceOf(attacker), 0, "attacker received shares");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TARGET 4: the curator first-loss pool.
    //   The only paths that move pool USDfr OUT to the caller are the cascade functions
    //   absorbLoss / absorbGlobalLoss (CREDIT_ROLE). withdrawFirstLoss is msg.sender-bound and
    //   the attacker holds no stake.
    // ─────────────────────────────────────────────────────────────────────────
    function test_EXP5_curatorPool_cannotBeExtractedByUnprivilegedCaller() public onFork {
        address attacker = _attacker();
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;

        // Route 1: the per-class cascade draw (transfers pool USDfr to msg.sender).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        curator.absorbLoss(classId, 1e18);

        // Route 2: the classless global cascade draw (transfers aggregate pool USDfr to msg.sender).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CREDIT_ROLE
            )
        );
        curator.absorbGlobalLoss(1e18);

        // Route 3: attacker tries to withdraw first-loss it does not own. The withdrawal-freeze
        // guards run before the stake check, so pin the expected revert to the live freeze state
        // (a healthy fully-wired fork lands on Curator_InsufficientStake for a zero stake).
        bytes memory expectedErr;
        if (curator.reserveManager() == address(0)) {
            expectedErr = abi.encodeWithSelector(ICuratorModule.Curator_ReserveNotWired.selector);
        } else if (curator.custodyFreezeActive()) {
            expectedErr = abi.encodeWithSelector(ICuratorModule.Curator_CustodyLossFrozen.selector);
        } else {
            expectedErr = abi.encodeWithSelector(
                ICuratorModule.Curator_InsufficientStake.selector, classId, attacker, uint256(1e18), uint256(0)
            );
        }
        vm.prank(attacker);
        vm.expectRevert(expectedErr);
        curator.withdrawFirstLoss(classId, 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TARGET 3b (queue): another user's queued redemption proceeds, and settlement control.
    //   claim is owner-bound; closeEpoch is SETTLEMENT_KEEPER_ROLE-gated (D7-01 fix).
    // ─────────────────────────────────────────────────────────────────────────
    function test_EXP5_queue_cannotClaimAnothersRequestNorForceSettlement() public onFork {
        address attacker = _attacker();

        // Bob queues a real redemption of his sUSDfr.
        _mintFromUSDC(bob, 500_000e6);
        uint256 shares = _stake(bob, 500_000e18);
        vm.startPrank(bob);
        IERC20(address(vault)).approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(shares);
        vm.stopPrank();

        // Route 1: attacker claims bob's request. claim checks r.owner != msg.sender first.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, reqId, attacker));
        queue.claim(reqId);

        // Route 2: attacker tries to drive settlement (controls when the budget is sampled).
        // The keeper-role check runs before the pause/epoch checks, so no warp is needed.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.SETTLEMENT_KEEPER_ROLE
            )
        );
        queue.closeEpoch(10);

        // The request and its owner are unchanged; nothing was claimed.
        (address owner,,,,) = queue.request(reqId);
        assertEq(owner, bob, "request owner changed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSITION: donate-then-sweep. Send USDC straight into the ReserveManager (a "donation"),
    //   then try to have that surplus credited/paid to the attacker. The reserve treats bare
    //   transfers as donations that do NOT increase backing, and the only credit path
    //   (creditRecoveredIdleUSDC) is RESERVE_ADMIN + arm-bound. So the donated value is stranded
    //   as `unrecordedUSDC` and cannot be pulled back out by anyone unprivileged.
    // ─────────────────────────────────────────────────────────────────────────
    function test_EXP5_composition_donatedUsdcCannotBeSweptBack() public onFork {
        address attacker = _attacker();
        uint256 donation = 250_000e6;

        uint256 idleBefore = reserves.idleReserve();
        uint256 backingBefore = reserves.totalBackingValue();

        // A raw transfer straight into the treasury.
        vm.prank(bob);
        IERC20(USDC).transfer(address(reserves), donation);

        // The donation is NOT recognised as backing (ADR: donations do not increase reported
        // backing), so it never becomes a redeemable claim for anyone.
        assertEq(reserves.idleReserve(), idleBefore, "donation wrongly credited to idle backing");
        assertEq(reserves.totalBackingValue(), backingBefore, "donation wrongly credited to backing");
        assertEq(reserves.unrecordedUSDC(), donation, "donation not observable as unrecorded surplus");

        // The attacker cannot credit the surplus to recorded idle (RESERVE_ADMIN + arm-bound).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ReserveLossCallerNotAdmin.selector, attacker)
        );
        reserves.creditRecoveredIdleUSDC(1, bytes32(0));

        // ...and still cannot release it (controller-only), even though it is physically present.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CONTROLLER_ROLE
            )
        );
        reserves.releaseUSDC(attacker, donation);
    }
}
