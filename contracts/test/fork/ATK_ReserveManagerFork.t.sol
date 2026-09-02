// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";

/// @title ATK_ReserveManagerForkTest — adversarial assault on the USDC treasury
/// @notice AUTHORISED local-fork attack on the owner's own pre-audit ReserveManager. Never
///         broadcasts, never moves real value. Every function here is a concrete exploit
///         ATTEMPT against `src/ReserveManager.sol`, run through the REAL deploy topology on a
///         pinned mainnet fork (canonical 6-decimal USDC, real role wiring).
///
///         The attacker is `carol`: funded with real USDC by the fixture, holding NO protocol
///         role (not CONTROLLER, not CREDIT, not RESERVE_ADMIN, not GUARDIAN, not DEFAULT_ADMIN,
///         not the wired lossAbsorber) and not even KYC'd. Everything an outside adversary can
///         actually reach is reached from `carol`.
///
///         Attack surface reasoning:
///           * TRUE permissionless entry points that mutate state: `recapitalize` (pull-in of
///             new backing) and `reconcileIdleUSDC` (observation). Both are hit hardest below.
///           * The other entry points named "permissionless" in the brief (`depositUSDC`,
///             `ratifyAndOpen`, `creditRecoveredIdleUSDC`, `recordExitPrepayment`,
///             `consumeExitPrepayment`) are in fact role/binding gated; they are attacked from
///             the hostile role-less actor and must reject with the SPECIFIC custom error.
///           * REENTRANCY is not separately exploitable: the reserve is hard-bound at
///             `initialize` to canonical USDC (decimals==6 check), which exposes no transfer
///             hook/callback, and every value-mover additionally carries `nonReentrant`. There is
///             no attacker-controlled token to swap in, so no callback surface exists to reenter.
///
///         Where an attack is blocked, the test asserts the exact revert. Where a permissionless
///         op SUCCEEDS, the test asserts the SAFE post-state (real USDC in, no backing inflation,
///         no interlock release, the sum-of-parts identity intact) — so a genuine accounting bug
///         would surface as a failed value assertion, not a passing "it reverted".
contract ATK_ReserveManagerForkTest is ForkLifecycleFixture {
    /// @dev The protocol's core reserve identity (CLAUDE.md 1.3 "reserve accounting reconciles to
    ///      the sum of its parts"): reported backing == recorded idle (normalized) + deployed
    ///      principal - conservative impairment. Any permissionless op that broke this would fail
    ///      here.
    function _assertReconciles(string memory ctx) internal view {
        assertEq(
            reserves.totalBackingValue(),
            reserves.normalizeUSDC(reserves.idleUSDC()) + reserves.deployedPrincipal()
                - reserves.totalPrincipalImpairment(),
            ctx
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. recapitalize (PERMISSIONLESS): a one-way donation of real backing that
    //    the attacker can never pull back out, and that cannot inflate backing
    //    beyond the USDC actually delivered.
    // ─────────────────────────────────────────────────────────────────────────
    function test_recapitalize_permissionlessDonationCannotBeExtracted() public onFork {
        uint256 amount = 250_000e6;
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 idleBefore = reserves.idleUSDC();
        uint256 carolBefore = IERC20(USDC).balanceOf(carol);

        vm.startPrank(carol);
        IERC20(USDC).approve(address(reserves), amount);
        uint256 credited = reserves.recapitalize(amount);
        vm.stopPrank();

        // Backing rose by EXACTLY the real USDC delivered (18-dec value), not a wei more.
        assertEq(credited, reserves.normalizeUSDC(amount), "credited must equal delivered value");
        assertEq(reserves.idleUSDC(), idleBefore + amount, "idle must rise by delivered units");
        assertEq(
            reserves.totalBackingValue(), backingBefore + reserves.normalizeUSDC(amount), "backing rises by delivered"
        );
        assertEq(IERC20(USDC).balanceOf(carol), carolBefore - amount, "attacker actually paid it in");
        _assertReconciles("recapitalize broke sum-of-parts");

        // The attacker cannot round-trip: releaseUSDC is CONTROLLER_ROLE only. No permissionless
        // exit exists, so `recapitalize` is a pure donation and can never be a deposit/withdraw
        // value extraction.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CONTROLLER_ROLE
            )
        );
        reserves.releaseUSDC(carol, amount);

        // Zero-value recapitalize is rejected (no empty accounting churn / event spam).
        vm.prank(carol);
        vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
        reserves.recapitalize(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. DONATION / share-inflation: a raw USDC transfer to the treasury must NOT
    //    be counted as backing. If it were, an attacker could inflate reported
    //    backing (and thus the mint headroom) for free.
    // ─────────────────────────────────────────────────────────────────────────
    function test_directDonationDoesNotInflateBacking() public onFork {
        uint256 donation = 500_000e6;
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 idleBefore = reserves.idleUSDC();
        uint256 unrecordedBefore = reserves.unrecordedUSDC();

        vm.prank(carol);
        require(IERC20(USDC).transfer(address(reserves), donation), "donation transfer failed");

        assertEq(reserves.totalBackingValue(), backingBefore, "raw donation MUST NOT inflate backing");
        assertEq(reserves.idleUSDC(), idleBefore, "raw donation MUST NOT increase recorded idle");
        assertEq(
            reserves.unrecordedUSDC(), unrecordedBefore + donation, "donation is visible only as unrecorded surplus"
        );
        _assertReconciles("donation broke sum-of-parts");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. reconcileIdleUSDC (PERMISSIONLESS): pure observation. It must never
    //    mutate accounting, and there must be no permissionless path to "write
    //    down" recorded idle down to a drained live balance (the only such path,
    //    the legacy writeDownIdleUSDC, is a hard tombstone).
    // ─────────────────────────────────────────────────────────────────────────
    function test_reconcileIdleUSDC_isObservationOnly() public onFork {
        // Establish a known idle position we fully control.
        uint256 seed = 100_000e6;
        vm.startPrank(carol);
        IERC20(USDC).approve(address(reserves), seed);
        reserves.recapitalize(seed);
        vm.stopPrank();

        uint256 recorded = reserves.idleUSDC();
        uint256 backingBefore = reserves.totalBackingValue();

        // Healthy state: reconcile reports zero shortfall and mutates nothing.
        vm.prank(carol);
        uint256 sf0 = reserves.reconcileIdleUSDC();
        assertEq(sf0, 0, "no shortfall while fully custodied");
        assertEq(reserves.idleUSDC(), recorded, "reconcile must not mutate recorded idle");
        assertEq(reserves.totalBackingValue(), backingBefore, "reconcile must not mutate backing");

        // Simulate a real custody theft of exactly 1,234 USDC by lowering the live balance.
        deal(USDC, address(reserves), recorded - 1_234e6);

        // The permissionless observer now REPORTS the exact live shortfall...
        vm.prank(carol);
        uint256 sf1 = reserves.reconcileIdleUSDC();
        assertEq(sf1, 1_234e6, "reconcile must report the exact live shortfall");
        (,, uint256 obsSf) = reserves.observeIdleUSDC();
        assertEq(obsSf, 1_234e6, "observe agrees with reconcile");

        // ...but it does NOT realize/hide the loss: recorded idle is untouched, so an attacker
        // cannot use the permissionless path to quietly reprice backing down onto the drained
        // balance. Loss realization is reachable only through the gated arm/ratify path.
        assertEq(reserves.idleUSDC(), recorded, "reconcile must not write down recorded idle");

        // The only idle write-down entry point is permanently disabled for everyone.
        vm.prank(carol);
        vm.expectRevert(IReserveManager.ReserveManager_LegacyPathDisabled.selector);
        reserves.writeDownIdleUSDC(1_234e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. NO IDLE DOUBLE-CREDIT: a physical USDC surplus (donation, or returned
    //    funds) cannot be swept into recorded backing without a ratified arm's
    //    recovery capacity — not by the attacker, and not even by the reserve
    //    admin absent that arm-bound capacity.
    // ─────────────────────────────────────────────────────────────────────────
    function test_surplusCannotBeCreditedIntoBacking_noDoubleCredit() public onFork {
        uint256 donation = 300_000e6;
        vm.prank(carol);
        require(IERC20(USDC).transfer(address(reserves), donation), "donation transfer failed");

        uint256 backingAfterDonation = reserves.totalBackingValue();
        assertGt(reserves.unrecordedUSDC(), 0, "surplus is present to attempt to credit");

        // Attacker cannot self-credit the surplus (reserve-admin gated).
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ReserveLossCallerNotAdmin.selector, carol)
        );
        reserves.creditRecoveredIdleUSDC(1, keccak256("attacker-recovery"));

        // Even the RESERVE_ADMIN (this contract) cannot convert an un-armed surplus into backing:
        // with no ratified arm, arm-1 recovery capacity is zero, so the credit is refused. This is
        // the anti-double-credit guard — recovery is bounded by what a governance ratification
        // actually wrote down.
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, uint256(1)));
        reserves.creditRecoveredIdleUSDC(1, keccak256("admin-recovery"));

        assertEq(reserves.totalBackingValue(), backingAfterDonation, "surplus never entered backing");
        _assertReconciles("double-credit probe broke sum-of-parts");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. COMPOSE: recapitalize while a custody-loss arm is active. The
    //    permissionless deposit of backing must succeed (you can always add
    //    money) but must NOT release the fail-closed interlock the arm asserts.
    // ─────────────────────────────────────────────────────────────────────────
    function test_recapitalizeDuringActiveArm_doesNotReleaseInterlock() public onFork {
        // Guardian (this contract) arms a reserve-loss freeze.
        (uint256 armId,) = reserves.armReserveLossFreeze(bytes32("arm-evidence"));
        assertTrue(reserves.reserveLossExitsLocked(), "arming must lock exits");
        assertTrue(reserves.curatorWithdrawalsLocked(), "arming must lock curator withdrawals");

        uint256 amount = 100_000e6;
        uint256 backingBefore = reserves.totalBackingValue();

        vm.startPrank(carol);
        IERC20(USDC).approve(address(reserves), amount);
        uint256 credited = reserves.recapitalize(amount);
        vm.stopPrank();

        assertEq(credited, reserves.normalizeUSDC(amount), "recapitalize still credits real value");
        assertEq(reserves.totalBackingValue(), backingBefore + reserves.normalizeUSDC(amount), "backing rose");

        // The interlock is untouched: a permissionless top-up cannot be used to unfreeze exits or
        // consume the guardian's arm.
        assertTrue(reserves.reserveLossExitsLocked(), "recapitalize MUST NOT release the interlock");
        (uint256 armIdAfter,,,) = reserves.reserveLossArm();
        assertEq(armIdAfter, armId, "the active arm must persist");
        _assertReconciles("armed recapitalize broke sum-of-parts");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. HOSTILE-ACTOR SWEEP of every mutating entry point. Each must reject the
    //    role-less attacker with its SPECIFIC error — no privileged action is
    //    reachable by an unauthorized role in any state (CLAUDE.md 1.3).
    // ─────────────────────────────────────────────────────────────────────────
    function test_gatedMutators_rejectRolelessAttacker() public onFork {
        bytes32 evid = keccak256("attack-evidence");
        bytes32 ADMIN = bytes32(0); // DEFAULT_ADMIN_ROLE

        // depositUSDC: custom depositor gate (not OZ AccessControl).
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NotDepositor.selector, carol));
        reserves.depositUSDC(carol, 1);

        // releaseUSDC: CONTROLLER_ROLE.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CONTROLLER_ROLE
            )
        );
        reserves.releaseUSDC(carol, 1);

        // CREDIT_ROLE surface: deployment, fee capitalization, payment, write-down.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        reserves.recordDeployment(1, carol, 1);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        reserves.recordFeeCapitalization(1, 1);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        reserves.recordPayment(1, carol, 1, 0);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        reserves.recordPrincipalWritedown(1, 1);

        // DEFAULT_ADMIN surface: impairment marks, module wiring, incident/deficit controls.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.recognizePrincipalImpairment(1, 1, evid);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.releasePrincipalImpairment(1, 1, evid);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.setLossController(carol);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.setLossAbsorber(carol);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.setReserveLossModules(carol, carol, carol, carol, carol);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.setGuardianReserveLossArmsEnabled(true);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.openReserveLossIncident(1, evid);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.closeReserveLossIncident(1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.resolveReserveDeficit(evid);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.cancelAndDisable(1, evid);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, ADMIN));
        reserves.finalizeAndDisable(1, evid);

        // GUARDIAN surface: arming and pausing.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        reserves.armReserveLossFreeze(evid);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        reserves.pause();

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        reserves.unpause();

        // RESERVE_ADMIN surface: the arm-bound loss/recovery execution path.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ReserveLossCallerNotAdmin.selector, carol)
        );
        reserves.ratifyAndOpen(1, evid, type(uint256).max);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ReserveLossCallerNotAdmin.selector, carol)
        );
        reserves.creditRecoveredIdleUSDC(1, evid);

        // lossAbsorber-only compatibility ledger.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NotLossAbsorber.selector, carol));
        reserves.recordExitPrepayment(1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NotLossAbsorber.selector, carol));
        reserves.consumeExitPrepayment(1, 1);

        // Nothing the attacker just tried moved any accounting.
        _assertReconciles("hostile sweep perturbed sum-of-parts");
    }
}
