// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";

/// @title ATK_ReserveIncidentFork: the ADR-0033 arm / incident / deficit state machine, attacked
///        on the pinned mainnet fork (block 25,500,000) with the continuous-accrual book enabled.
/// @notice Target: `contracts/src/libraries/ReserveIncidentLib.sol` (1 of 27 branches reached by
///         the first two rounds) through `ReserveManager.armReserveLossFreeze`, `cancelAndDisable`,
///         `ratifyAndOpen`, `creditRecoveredIdleUSDC`, `finalizeAndDisable`,
///         `openReserveLossIncident`, `closeReserveLossIncident`, `resolveReserveDeficit`, and the
///         interlocks they drive (`reserveLossExitsLocked`, `curatorWithdrawalsLocked`, the
///         controller's armed-par-exit and under-backed gates, the queue's settlement freeze).
///
///         `ops` (this contract) holds DEFAULT_ADMIN, RESERVE_ADMIN and GUARDIAN on the reserve, so
///         the role-bearing calls are made directly; `carol` (no KYC, no role) is used wherever
///         the door is permissionless. The role-less sweep of every entry point already exists in
///         `ATK_ReserveManagerFork.test_gatedMutators_rejectRolelessAttacker` and is not repeated.
///
///         Never broadcasts. Never touches a real key.
contract ATK_ReserveIncidentForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant SCALE = 1e12;

    // Mirrors of the IReserveManager events, so `vm.expectEmit` can name them from the test.
    event ReserveLossArmed(uint256 indexed armId, uint256 indexed incidentId, bytes32 evidenceHash);
    event ReserveLossArmCancelled(uint256 indexed armId, bytes32 indexed evidenceHash);
    event ReserveLossArmFinalized(uint256 indexed armId, uint256 indexed incidentId, bytes32 indexed evidenceHash);
    event GuardianReserveLossArmsEnabled(bool enabled);
    event ReserveLossIncidentOpened(uint256 indexed incidentId, uint256 indexed armId, bytes32 evidenceHash);
    event ReserveLossIncidentClosed(uint256 indexed incidentId);
    event ReserveDeficitResolved(uint256 previousDeficit, bytes32 evidenceHash);
    event RecoveredIdleUSDCCredited(
        uint256 indexed armId, uint256 nativeUnits, uint256 value, bytes32 indexed evidenceHash
    );
    event ReserveLossRecognized(
        uint256 indexed incidentId, uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired
    );
    event ReserveLossAllocated(
        uint256 indexed incidentId,
        uint256 backingReduction,
        uint256 surplusAbsorbed,
        uint256 curatorAbsorbed,
        uint256 backstopCovered,
        uint256 seniorBurned,
        uint256 residualDeficit
    );
    event ReserveDeficitUpdated(uint256 indexed incidentId, uint256 previousDeficit, uint256 currentDeficit);
    event IdleUSDCWrittenDown(uint256 amount, uint256 remaining);
    event ReserveLossRatified(
        uint256 indexed armId,
        uint256 indexed incidentId,
        uint256 approvedMaxLoss,
        uint256 actualLoss,
        bytes32 evidenceHash
    );

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _postFirstLossOps(uint256 classId, uint256 amount) internal {
        _mintFromUSDC(ops, (amount + SCALE - 1) / SCALE);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
    }

    function _fundBackstopOps(uint256 amount) internal {
        _mintFromUSDC(ops, amount / SCALE);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
    }

    /// @dev Remove `units` of canonical USDC from the reserve's custody without touching its ledger:
    ///      the objective shortfall ADR-0033 section 1 derives from the live balance.
    function _steal(uint256 units) internal {
        deal(USDC, address(reserves), IERC20(USDC).balanceOf(address(reserves)) - units);
    }

    /// @dev A permissionless, un-accounted USDC transfer into the reserve (a donation, or the
    ///      thief returning the funds). Raises the live balance only.
    function _donate(uint256 units) internal {
        vm.prank(carol);
        require(IERC20(USDC).transfer(address(reserves), units), "donation transfer failed");
    }

    function _incidentOf(uint256 armId) internal pure returns (uint256) {
        return type(uint256).max - armId;
    }

    function _supplyMinusBacking() internal view returns (int256) {
        return int256(controller.totalUSDfr()) - int256(controller.backingValue());
    }

    function _assertLocked(bool locked, string memory tag) internal view {
        assertEq(reserves.reserveLossExitsLocked(), locked, string.concat(tag, ": reserveLossExitsLocked"));
        assertEq(reserves.curatorWithdrawalsLocked(), locked, string.concat(tag, ": curatorWithdrawalsLocked"));
    }

    /// @dev Count the logs `reserves` emitted with `topic0` since `vm.recordLogs()`.
    function _countReserveLogs(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reserves) && logs[i].topics[0] == topic0) ++n;
        }
    }

    function _findReserveLog(Vm.Log[] memory logs, bytes32 topic0) internal view returns (Vm.Log memory found) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reserves) && logs[i].topics[0] == topic0) return logs[i];
        }
        revert("log not found");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. A healthy arm: what it freezes, what stays live, every out-of-order
    //    transition, and the one exit the timelock can always take.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ADR-0033 sections 2, 4 and 5 on the live fork. A Guardian arm with no shortfall
    ///         locks curator withdrawals, queue settlement and the PAR direct exit (Cantina 3.1.4),
    ///         and nothing else: mint, coupon receipt, default declaration, loss realisation and
    ///         staking all still run. Driven out of order by the right roles, every
    ///         transition refuses with its specific error and the arm survives untouched.
    ///         `cancelAndDisable` is the exit, it consumes the arm and disables further Guardian
    ///         arms atomically, and DEFAULT_ADMIN alone can re-enable them; the next arm takes the
    ///         next id.
    function test_atk_healthyArm_freezesOnlyTheExitsAndHasOneDoor() public onFork {
        _mintFromUSDC(bob, 2_000_000e6);
        uint256 bobShares = _stake(bob, 1_000_000e18);
        _postFirstLossOps(FILM, 100_000e18);
        _mintFromUSDC(alice, 100_000e6);
        uint256 tokenId = _originateAndFund(500_000e18);
        bytes32 evidence = keccak256("atk-incidents-anticipatory-arm");
        _assertLocked(false, "before the arm");

        // ── the arm ──
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossArmed(1, _incidentOf(1), evidence);
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        assertEq(armId, 1, "first arm id");
        assertEq(incidentId, _incidentOf(1), "incident id is structurally derived from the arm");
        assertTrue(LossEventIds.isCustodyEvent(incidentId), "upper namespace");
        _assertLocked(true, "armed");
        assertTrue(reserves.custodyLossUnabsorbed(), "curator's five-limb predicate latches on the arm");
        assertEq(reserves.idleCustodyShortfall(), 0, "no objective shortfall: this is an anticipatory arm");

        _healthyArm_outOfOrder(evidence, incidentId);
        _healthyArm_frozen(bobShares);
        _healthyArm_live(tokenId);
        _assertLocked(true, "still armed after ordinary business");
        _healthyArm_door(evidence, incidentId);
    }

    /// @dev Every transition driven out of order by the role that owns it. The arm survives.
    function _healthyArm_outOfOrder(bytes32 evidence, uint256 incidentId) internal {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, 1));
        reserves.armReserveLossFreeze(evidence);
        vm.expectRevert(IReserveManager.ReserveManager_ShortfallCured.selector);
        reserves.ratifyAndOpen(1, evidence, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmMismatch.selector, 1, 2));
        reserves.ratifyAndOpen(2, evidence, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_ArmEvidenceMismatch.selector, evidence, keccak256("other")
            )
        );
        reserves.ratifyAndOpen(1, keccak256("other"), type(uint256).max);
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveIncident.selector);
        reserves.finalizeAndDisable(1, evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmMismatch.selector, 1, 2));
        reserves.finalizeAndDisable(2, evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmMismatch.selector, 1, 0));
        reserves.cancelAndDisable(0, evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, 1));
        reserves.creditRecoveredIdleUSDC(1, evidence);
        vm.expectRevert(IReserveManager.ReserveManager_NoReserveDeficit.selector);
        reserves.resolveReserveDeficit(evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, 1));
        reserves.closeReserveLossIncident(incidentId);
        // Disabling future arms never clears the standing one (ADR-0033 section 2).
        reserves.setGuardianReserveLossArmsEnabled(false);
        (uint256 stillArmed,,, bool enabled) = reserves.reserveLossArm();
        assertEq(stillArmed, 1, "the arm persists through a disable");
        assertFalse(enabled, "arms disabled");
        reserves.setGuardianReserveLossArmsEnabled(true);
    }

    /// @dev What the arm freezes: the par direct exit, queue settlement, curator withdrawal.
    function _healthyArm_frozen(uint256 bobShares) internal {
        (uint256 previewOut, uint256 previewIn) = controller.previewRedeem(100e18);
        assertEq(previewOut, 0, "previewRedeem quotes nothing at par under an unratified arm");
        assertEq(previewIn, 0, "and burns nothing");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveLossArmFreeze.selector, 1, 100e6, 100e18)
        );
        controller.redeem(100e18);
        vm.startPrank(bob);
        vault.approve(address(queue), bobShares / 4);
        uint256 reqId = queue.requestRedeem(bobShares / 4);
        vm.stopPrank();
        (, uint256 sharesQueued,,,) = queue.request(reqId);
        assertEq(sharesQueued, bobShares / 4, "requesting a queue position is still allowed");
        vm.expectRevert(IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector);
        queue.closeEpoch(50);
        vm.expectRevert(ICuratorModule.Curator_CustodyLossFrozen.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
    }

    /// @dev What stays live: mint, staking, coupon receipt, default declaration, loss realisation.
    function _healthyArm_live(uint256 tokenId) internal {
        uint256 minted = _mintFromUSDC(alice, 10_000e6);
        assertEq(minted, 10_000e18, "mint is open under an anticipatory arm (custody is intact)");
        uint256 staked = _stake(bob, 10_000e18);
        assertGt(staked, 0, "staking into the senior vault is open under the arm");
        _warp(30 days);
        uint256 coupon = (uint256(500_000e18) * 1400 * 30 days / (10_000 * 360 days)) / SCALE * SCALE;
        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        _repay(tokenId, coupon, 0);
        assertGt(usdfr.balanceOf(address(vault)), vaultBefore, "the coupon reached the senior vault");
        _declareDefault(tokenId, keccak256("atk-incidents-default"));
        uint256 poolBefore = curator.poolBalance(FILM);
        _realizeLoss(tokenId, 40_000e18, bytes32(0));
        assertEq(poolBefore - curator.poolBalance(FILM), 40_000e18, "layer one absorbed the facility loss");
        assertEq(_supplyMinusBacking(), 0, "no deficit: the loss was burned from first-loss capital");
    }

    /// @dev The door: cancel consumes the arm and disables further arms in one transaction.
    function _healthyArm_door(bytes32 evidence, uint256 incidentId) internal {
        // The disable is emitted before the cancel event: the interlock never briefly re-opens
        // with arms still enabled (ADR-0033 section 4, "never briefly releases").
        vm.expectEmit(true, true, true, true, address(reserves));
        emit GuardianReserveLossArmsEnabled(false);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossArmCancelled(1, evidence);
        reserves.cancelAndDisable(1, evidence);
        (uint256 armAfter, uint256 incidentAfter, bytes32 evidenceAfter, bool enabledAfter) = reserves.reserveLossArm();
        assertEq(armAfter, 0, "arm consumed");
        assertEq(incidentAfter, 0, "no derived incident without an arm");
        assertEq(evidenceAfter, bytes32(0), "evidence cleared");
        assertFalse(enabledAfter, "guardian arms disabled by the cancel");
        assertFalse(reserves.reserveLossIncidentUsed(incidentId), "an unratified arm never consumed its incident id");
        _assertLocked(false, "cancelled");
        vm.expectRevert(IReserveManager.ReserveManager_GuardianArmsDisabled.selector);
        reserves.armReserveLossFreeze(evidence);
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveArm.selector);
        reserves.cancelAndDisable(1, evidence);
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveArm.selector);
        reserves.finalizeAndDisable(1, evidence);
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveArm.selector);
        reserves.ratifyAndOpen(1, evidence, 1);

        // Par exits reopen with the cancel.
        vm.prank(alice);
        uint256 out = controller.redeem(100e18);
        assertEq(out, 100e6, "par redemption reopened");

        // Only DEFAULT_ADMIN reopens the Guardian's authority. A legacy incident standing refuses a
        // new arm; once closed, its consumed id (the next arm's own) is skipped by the cursor
        // (P-38's fix, commit e49d9cc), so the next arm takes id 3.
        reserves.setGuardianReserveLossArmsEnabled(true);
        reserves.openReserveLossIncident(2, keccak256("legacy-2"));
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyActive.selector, _incidentOf(2))
        );
        reserves.armReserveLossFreeze(keccak256("second"));
        reserves.closeReserveLossIncident(_incidentOf(2));
        (uint256 secondArm, uint256 secondIncident) = reserves.armReserveLossFreeze(keccak256("second"));
        assertEq(secondArm, 3, "the cursor skipped the consumed id 2");
        assertEq(secondIncident, _incidentOf(3), "derived from the new arm");
        _assertLocked(true, "re-armed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. A real theft: the approval boundary, the register from events, a second
    //    tranche under the same arm, and finalisation.
    // ─────────────────────────────────────────────────────────────────────────

    struct Book {
        uint256 armId;
        uint256 incidentId;
        bytes32 evidence;
        uint256 lossUnits;
        uint256 loss;
        uint256 curatorBefore;
        uint256 coverageBefore;
        uint256 vaultBefore;
        uint256 supplyBefore;
        uint256 backingBefore;
        uint256 idleBefore;
    }

    /// @notice ADR-0033 sections 4, 6 and 7. An 800,000 USDC theft against 250,000 of curator
    ///         first-loss, 400,000 of sGROVE coverage and 4,000,000 of senior capital.
    ///         `approvedMaxLoss` one unit below the live shortfall refuses with the exact pair
    ///         and changes nothing; the exact amount executes. The cascade's register is
    ///         reconstructed from the reserve's events alone and reconciled against every
    ///         module balance. A second tranche of 100,000 reuses the same incident under the
    ///         same arm, the recovery ceiling accumulates, and `finalizeAndDisable` closes the
    ///         incident, consumes the arm and disables further arms in one transaction, after
    ///         which settlement and curator withdrawals reopen.
    function test_atk_theft_approvalBoundary_registerFromEvents_secondTranche_finalize() public onFork {
        Book memory b;
        _mintFromUSDC(bob, 5_000_000e6);
        _stake(bob, 4_000_000e18);
        _postFirstLossOps(FILM, 250_000e18);
        _fundBackstopOps(400_000e18);
        b.lossUnits = 800_000e6;
        b.loss = 800_000e18;
        _steal(b.lossUnits);
        b.evidence = keccak256("atk-incidents-theft");
        (b.armId, b.incidentId) = reserves.armReserveLossFreeze(b.evidence);
        b.curatorBefore = curator.poolBalance(FILM);
        b.coverageBefore = sGrove.coverageReserve();
        b.vaultBefore = vault.totalAssets();
        b.supplyBefore = controller.totalUSDfr();
        b.backingBefore = controller.backingValue();
        b.idleBefore = reserves.idleUSDC();
        assertEq(b.supplyBefore, b.backingBefore, "precondition: no surplus, the whole loss needs a burn");
        assertEq(reserves.idleCustodyShortfall(), b.loss, "the objective shortfall is the theft");

        // While the shortfall stands, mint and both direct exits are shut by R4-01, before pricing.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ReserveCustodyShortfall.selector,
                b.loss,
                reserves.recognizedBackingValue()
            )
        );
        controller.mint(1e6);

        // ── approval boundary: one unit under refuses, exact executes ──
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_LossExceedsApproval.selector, b.loss, b.loss - 1)
        );
        reserves.ratifyAndOpen(b.armId, b.evidence, b.loss - 1);
        assertEq(controller.totalUSDfr(), b.supplyBefore, "a refused ratification burned nothing");
        assertEq(reserves.idleUSDC(), b.idleBefore, "and wrote nothing down");
        assertEq(reserves.reserveLossRecoveryCapacity(b.armId), 0, "and opened no recovery ceiling");
        (uint256 openId,) = reserves.activeReserveLossIncident();
        assertEq(openId, 0, "and opened no incident");

        vm.recordLogs();
        (uint256 opened, uint256 actual) = reserves.ratifyAndOpen(b.armId, b.evidence, b.loss);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(opened, b.incidentId, "the incident is the arm's derived id");
        assertEq(actual, b.loss, "actual loss is the live shortfall");

        // ── the register, from events alone ──
        assertEq(_countReserveLogs(logs, ReserveLossIncidentOpened.selector), 1, "one incident opened");
        {
            Vm.Log memory l = _findReserveLog(logs, ReserveLossIncidentOpened.selector);
            assertEq(uint256(l.topics[1]), b.incidentId, "opened: incident");
            assertEq(uint256(l.topics[2]), b.armId, "opened: arm");
            assertEq(abi.decode(l.data, (bytes32)), b.evidence, "opened: evidence");
        }
        {
            Vm.Log memory l = _findReserveLog(logs, ReserveLossRecognized.selector);
            (uint256 red, uint256 surplus, uint256 required) = abi.decode(l.data, (uint256, uint256, uint256));
            assertEq(uint256(l.topics[1]), b.incidentId, "recognized: incident");
            assertEq(red, b.loss, "recognized: backing reduction");
            assertEq(surplus, 0, "recognized: no surplus to absorb");
            assertEq(required, b.loss, "recognized: the whole loss needs a burn");
        }
        {
            Vm.Log memory l = _findReserveLog(logs, ReserveLossAllocated.selector);
            (uint256 red, uint256 surplus, uint256 cur, uint256 back, uint256 sen, uint256 res) =
                abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(red, b.loss, "allocated: backing reduction");
            assertEq(surplus, 0, "allocated: surplus");
            assertEq(cur, 250_000e18, "allocated: curator took its whole pool");
            assertEq(back, 400_000e18, "allocated: sGROVE took its whole reserve (ADR-0035, no cap)");
            assertEq(sen, 150_000e18, "allocated: senior took the residual");
            assertEq(res, 0, "allocated: no deficit");
            // The event-derived register reconciles to every module balance.
            assertEq(b.curatorBefore - curator.poolBalance(FILM), cur, "curator balance moved by the event amount");
            assertEq(b.coverageBefore - sGrove.coverageReserve(), back, "sGROVE reserve moved by the event amount");
            assertEq(b.vaultBefore - vault.totalAssets(), sen, "vault assets moved by the event amount");
            assertEq(b.supplyBefore - controller.totalUSDfr(), cur + back + sen, "supply fell by the three burns");
            assertEq(b.backingBefore - controller.backingValue(), red, "backing fell by the write-down");
        }
        assertEq(_countReserveLogs(logs, ReserveDeficitUpdated.selector), 0, "no deficit latched");
        {
            Vm.Log memory l = _findReserveLog(logs, IdleUSDCWrittenDown.selector);
            (uint256 amt, uint256 remaining) = abi.decode(l.data, (uint256, uint256));
            assertEq(amt, b.loss, "written down: the loss");
            assertEq(remaining, reserves.normalizeUSDC(reserves.idleUSDC()), "written down: the remaining idle ledger");
            assertEq(b.idleBefore - reserves.idleUSDC(), b.lossUnits, "the ledger fell by exactly the theft");
        }
        {
            Vm.Log memory l = _findReserveLog(logs, ReserveLossRatified.selector);
            (uint256 approvedMax, uint256 actualLoss, bytes32 ev) = abi.decode(l.data, (uint256, uint256, bytes32));
            assertEq(uint256(l.topics[1]), b.armId, "ratified: arm");
            assertEq(uint256(l.topics[2]), b.incidentId, "ratified: incident");
            assertEq(approvedMax, b.loss, "ratified: approval");
            assertEq(actualLoss, b.loss, "ratified: actual");
            assertEq(ev, b.evidence, "ratified: evidence");
        }
        assertEq(reserves.reserveLossRecoveryCapacity(b.armId), b.lossUnits, "recovery ceiling = the write-down");
        assertTrue(reserves.reserveLossIncidentUsed(b.incidentId), "the derived id is now consumed");
        assertEq(reserves.idleCustodyShortfall(), 0, "the ledger now matches custody");
        assertEq(_supplyMinusBacking(), 0, "backing invariant holds after the cascade");
        _assertLocked(true, "ratified but not finalised: arm and incident both stand");

        // With the incident open under its own arm, the PAR direct exit is released while the
        // queue and curator stay shut until finalisation (the documented ADR-0033 section 5 shape).
        _mintFromUSDC(alice, 1_000e6);
        vm.prank(alice);
        assertEq(controller.redeem(500e18), 500e6, "par exit reopens once the arm's own incident is open");
        vm.expectRevert(IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector);
        queue.closeEpoch(50);

        // ── a second tranche under the same arm reuses the same incident ──
        vm.expectRevert(IReserveManager.ReserveManager_ShortfallCured.selector);
        reserves.ratifyAndOpen(b.armId, b.evidence, b.loss);
        _steal(100_000e6);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_LiveShortfallExists.selector, 100_000e6));
        reserves.finalizeAndDisable(b.armId, b.evidence); // an un-ratified live shortfall cannot be finalised away
        uint256 vaultMid = vault.totalAssets();
        uint256 supplyMid = controller.totalUSDfr();
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossAllocated(b.incidentId, 100_000e18, 0, 0, 0, 100_000e18, 0);
        (uint256 opened2, uint256 actual2) = reserves.ratifyAndOpen(b.armId, b.evidence, type(uint256).max);
        assertEq(opened2, b.incidentId, "same incident");
        assertEq(actual2, 100_000e18, "charges only the live amount, not the approval");
        assertEq(vaultMid - vault.totalAssets(), 100_000e18, "junior exhausted: senior carries the second tranche");
        assertEq(supplyMid - controller.totalUSDfr(), 100_000e18, "burned from senior");
        assertEq(reserves.reserveLossRecoveryCapacity(b.armId), 900_000e6, "the ceiling accumulates per tranche");

        // ── finalise: one transaction closes, consumes, disables ──
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmMismatch.selector, b.armId, 9));
        reserves.finalizeAndDisable(9, b.evidence);
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        reserves.cancelAndDisable(b.armId, b.evidence); // an open incident cannot be cancelled away
        vm.recordLogs();
        reserves.finalizeAndDisable(b.armId, keccak256("finalize-evidence"));
        logs = vm.getRecordedLogs();
        assertEq(_countReserveLogs(logs, ReserveDeficitResolved.selector), 0, "no deficit to resolve");
        assertEq(_countReserveLogs(logs, ReserveLossIncidentClosed.selector), 1, "incident closed");
        assertEq(_countReserveLogs(logs, GuardianReserveLossArmsEnabled.selector), 1, "arms disabled");
        assertEq(_countReserveLogs(logs, ReserveLossArmFinalized.selector), 1, "arm finalised");
        {
            Vm.Log memory l = _findReserveLog(logs, ReserveLossArmFinalized.selector);
            assertEq(uint256(l.topics[1]), b.armId, "finalized: arm");
            assertEq(uint256(l.topics[2]), b.incidentId, "finalized: incident");
            assertEq(l.topics[3], keccak256("finalize-evidence"), "finalized: evidence");
        }
        (uint256 armAfter,,, bool enabledAfter) = reserves.reserveLossArm();
        assertEq(armAfter, 0, "arm consumed");
        assertFalse(enabledAfter, "guardian arms disabled");
        (uint256 openAfter,) = reserves.activeReserveLossIncident();
        assertEq(openAfter, 0, "incident closed");
        assertEq(reserves.reserveLossRecoveryCapacity(b.armId), 900_000e6, "the ceiling survives finalisation");
        _assertLocked(false, "finalised");
        assertFalse(reserves.custodyLossUnabsorbed(), "curator predicate released");
        // Settlement and curator withdrawals are live again.
        uint256 exitShares = vault.convertToShares(1_000e18);
        vm.startPrank(bob);
        vault.approve(address(queue), exitShares);
        queue.requestRedeem(exitShares);
        vm.stopPrank();
        _warp(Config.DEFAULT_REDEEM_COOLDOWN + 1);
        queue.closeEpoch(50);
        // The curator's pool was wiped to zero by the cascade; a fresh post must be possible again
        // and a withdrawal of it must be gated only by the ordinary rules, not by the incident.
        _postFirstLossOps(FILM, 1_000e18);
        curator.withdrawFirstLoss(FILM, 1e18);
        assertEq(_supplyMinusBacking(), 0, "backing invariant holds at the end");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Legacy bookkeeping is isolated from an active arm.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Both legacy operations refuse while checked ratification and finalization stay available.
    function test_legacyIncidentCannotChangeAnActiveArm() public onFork {
        _mintFromUSDC(bob, 5_000_000e6);
        _stake(bob, 4_000_000e18);
        _postFirstLossOps(FILM, 300_000e18);
        _fundBackstopOps(500_000e18);
        _steal(1_000_000e6);
        bytes32 evidence = keccak256("legacy-isolation");
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        reserves.openReserveLossIncident(7, keccak256("unrelated-record"));
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        reserves.openReserveLossIncident(armId, keccak256("same-identity"));
        assertFalse(reserves.reserveLossIncidentUsed(incidentId));
        (uint256 opened, uint256 actual) = reserves.ratifyAndOpen(armId, evidence, 1_000_000e18);
        assertEq(opened, incidentId);
        assertEq(actual, 1_000_000e18);
        assertEq(_supplyMinusBacking(), 0);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        reserves.closeReserveLossIncident(incidentId);
        _steal(50_000e6);
        (opened, actual) = reserves.ratifyAndOpen(armId, evidence, 50_000e18);
        assertEq(opened, incidentId);
        assertEq(actual, 50_000e18);
        assertEq(reserves.idleCustodyShortfall(), 0);
        assertEq(_supplyMinusBacking(), 0);
        reserves.finalizeAndDisable(armId, keccak256("resolved"));
        (uint256 armNow,,,) = reserves.reserveLossArm();
        assertEq(armNow, 0);
        _assertLocked(false, "checked finalization completed");
        uint256 legacy = reserves.openReserveLossIncident(7, keccak256("independent-record"));
        reserves.closeReserveLossIncident(legacy);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Recovered custody: the arm-bound ceiling, before and after finalisation,
    //    and a loss that a standing surplus absorbs without any burn.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ADR-0033 section 7 on the fork. After a 300,000 USDC theft is ratified
    ///         (100,000 curator, 200,000 senior), a 450,000 donation blocks finalisation until
    ///         credited; the credit is capped at the 300,000 ceiling, the remaining 150,000 stays
    ///         unrecorded, a second credit refuses, a wrong arm id refuses, and finalisation then
    ///         completes. The ceiling survives finalisation: a later return is still creditable
    ///         up to what remains. A second arm then meets a standing surplus (the credited
    ///         recovery exceeded what was burned from the survivors' backing), so a 200,000 theft
    ///         is absorbed by surplus alone: no burn, no incident deficit, immediate finalisation.
    function test_atk_recoveryCeiling_survivesFinalize_andSurplusAbsorbsWithoutBurn() public onFork {
        _mintFromUSDC(bob, 2_000_000e6);
        _stake(bob, 1_000_000e18);
        _postFirstLossOps(FILM, 100_000e18);
        _steal(300_000e6);
        bytes32 evidence = keccak256("atk-incidents-recovery");
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        uint256 supplyBefore = controller.totalUSDfr();
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossAllocated(incidentId, 300_000e18, 0, 100_000e18, 0, 200_000e18, 0);
        reserves.ratifyAndOpen(armId, evidence, 300_000e18);
        assertEq(supplyBefore - controller.totalUSDfr(), 300_000e18, "300k burned");
        assertEq(reserves.reserveLossRecoveryCapacity(armId), 300_000e6, "ceiling");

        // ── the return arrives before finalisation ──
        _donate(450_000e6);
        assertEq(reserves.unrecordedUSDC(), 450_000e6, "physical surplus visible, not backing");
        uint256 backingBefore = controller.backingValue();
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_RecoveredUSDCNotCredited.selector, armId, 300_000e6)
        );
        reserves.finalizeAndDisable(armId, evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, 2));
        reserves.creditRecoveredIdleUSDC(2, evidence); // a wrong arm has no ceiling
        vm.expectEmit(true, true, true, true, address(reserves));
        emit RecoveredIdleUSDCCredited(armId, 300_000e6, 300_000e18, keccak256("credit"));
        uint256 credited = reserves.creditRecoveredIdleUSDC(armId, keccak256("credit"));
        assertEq(credited, 300_000e18, "credit capped at the ceiling, not the 450k surplus");
        assertEq(controller.backingValue() - backingBefore, 300_000e18, "backing restored by the credit");
        assertEq(controller.totalUSDfr(), supplyBefore - 300_000e18, "no claim was re-minted");
        assertEq(reserves.unrecordedUSDC(), 150_000e6, "the excess stays unrecorded");
        assertEq(reserves.reserveLossRecoveryCapacity(armId), 0, "ceiling exhausted");
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, armId));
        reserves.creditRecoveredIdleUSDC(armId, evidence);
        assertEq(_supplyMinusBacking(), -300_000e18, "the survivors now hold a 300k surplus");

        reserves.finalizeAndDisable(armId, evidence);
        _assertLocked(false, "finalised");
        // After finalisation a further return has no ceiling left on this arm.
        _donate(1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, armId));
        reserves.creditRecoveredIdleUSDC(armId, evidence);

        // ── second arm: surplus absorbs the whole loss, nothing burns ──
        reserves.setGuardianReserveLossArmsEnabled(true);
        bytes32 evidence2 = keccak256("atk-incidents-second-theft");
        (uint256 armId2, uint256 incidentId2) = reserves.armReserveLossFreeze(evidence2);
        assertEq(armId2, 2, "second arm");
        // The live balance still carries 151,000 of un-accounted donations. Set it to the ledger
        // less 200,000 so the objective shortfall is exactly 200,000 (the donations are swept
        // into the theft; only the ledger-versus-balance gap is ever ratified).
        deal(USDC, address(reserves), reserves.idleUSDC() - 200_000e6);
        assertEq(reserves.idleCustodyShortfall(), 200_000e18, "objective shortfall 200k");
        uint256 supplyMid = controller.totalUSDfr();
        uint256 curatorMid = curator.poolBalance(FILM);
        uint256 vaultMid = vault.totalAssets();
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossRecognized(incidentId2, 200_000e18, 200_000e18, 0);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossAllocated(incidentId2, 200_000e18, 200_000e18, 0, 0, 0, 0);
        (, uint256 actual2) = reserves.ratifyAndOpen(armId2, evidence2, 250_000e18);
        assertEq(actual2, 200_000e18, "charged the live amount, under the approval");
        assertEq(controller.totalUSDfr(), supplyMid, "no burn at all");
        assertEq(curator.poolBalance(FILM), curatorMid, "curator untouched");
        assertEq(vault.totalAssets(), vaultMid, "senior untouched");
        (,, uint256 supplyReductionRequired) = reserves.recognizedReserveLoss();
        assertEq(supplyReductionRequired, 0, "nothing left to absorb");
        assertEq(_supplyMinusBacking(), -100_000e18, "surplus shrank from 300k to 100k");
        assertEq(
            reserves.reserveLossRecoveryCapacity(armId2), 200_000e6, "a surplus-absorbed loss still opens a ceiling"
        );
        // Partial return, credit, finalise; the remainder of the ceiling survives.
        _donate(50_000e6);
        assertEq(reserves.creditRecoveredIdleUSDC(armId2, evidence2), 50_000e18, "partial credit");
        reserves.finalizeAndDisable(armId2, evidence2);
        assertEq(reserves.reserveLossRecoveryCapacity(armId2), 150_000e6, "150k of ceiling survives finalisation");
        _donate(170_000e6);
        assertEq(reserves.creditRecoveredIdleUSDC(armId2, evidence2), 150_000e18, "late recovery credited to the cap");
        assertEq(reserves.reserveLossRecoveryCapacity(armId2), 0, "exhausted");
        assertEq(reserves.unrecordedUSDC(), 20_000e6, "everything beyond the ceiling stays a donation");
        assertLe(_supplyMinusBacking(), int256(0), "backing invariant holds");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. An arm over a deficit: (A) a residual the cascade could not carry and
    //    (B) a mark with no shortfall. Which releases are shut, and every door.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ADR-0033 section 8 and the open round's "sub-unit deficit" shape, produced here
    ///         through the custody cascade itself: curator 1,999,999,999,999,999,999 wei, no
    ///         sGROVE, the senior vault holding only the 10 USDfr seed, and a 12 USDC theft. The
    ///         cascade exhausts all three layers and latches a residual deficit of exactly 1 wei.
    ///         `finalizeAndDisable`, `cancelAndDisable` and `resolveReserveDeficit` are all shut;
    ///         mint is closed and the par floor refuses. Three funded routes are tested:
    ///         recapitalization by one micro-USDC, a discounted exit rounded to that native unit,
    ///         and a returned unit credited through the arm's recovery ceiling. Each creates
    ///         surplus above the one-wei remainder. Recovery credit and finalization retain
    ///         their role checks; legacy close cannot replace the arm's finalization.
    ///
    ///         Part B: a conservative mark with custody intact, then an unratified arm.
    ///         Direct exits wait for resolution. Explicit false-alarm cancellation preserves
    ///         the credit mark, after which the ordinary discounted exit can settle.
    function test_atk_armOverADeficit_everyReleaseShut_everyDoorOvershoots() public onFork {
        // ── Part A: the residual ──
        _mintFromUSDC(alice, 100e6);
        _postFirstLossOps(FILM, 2e18 - 1);
        assertEq(curator.poolBalance(FILM), 2e18 - 1, "off-grid first-loss");
        assertEq(sGrove.coverageReserve(), 0, "no layer two");
        uint256 vaultAssets = vault.totalAssets();
        assertEq(vaultAssets, 10e18, "only the seed stands in the senior vault");
        uint256 lossUnits = 12e6;
        _steal(lossUnits);
        bytes32 evidence = keccak256("atk-incidents-residual");
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(evidence);
        uint256 supplyBefore = controller.totalUSDfr();
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveDeficitUpdated(incidentId, 0, 1);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossAllocated(incidentId, 12e18, 0, 2e18 - 1, 0, 10e18, 1);
        reserves.ratifyAndOpen(armId, evidence, 12e18);
        assertEq(supplyBefore - controller.totalUSDfr(), 12e18 - 1, "burned everything the layers held");
        assertEq(vault.totalAssets(), 0, "senior exhausted");
        assertEq(curator.poolBalance(FILM), 0, "layer one exhausted");
        assertEq(reserves.reserveDeficit(), 1, "a 1-wei residual is latched");
        assertEq(_supplyMinusBacking(), 1, "effective supply exceeds backing by exactly the residual");
        _assertLocked(true, "deficit");

        // Every release is shut.
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_DeficitStillExists.selector, 1, 1));
        reserves.finalizeAndDisable(armId, evidence);
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        reserves.cancelAndDisable(armId, evidence);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyActive.selector, incidentId)
        );
        reserves.resolveReserveDeficit(evidence);
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, armId));
        reserves.creditRecoveredIdleUSDC(armId, evidence);
        uint256 supplyNow = controller.totalUSDfr();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, supplyNow, supplyNow - 1
            )
        );
        controller.mint(1e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 999_999, 1_000_000)
        );
        controller.redeem(1e18);
        vm.expectRevert(IRedemptionQueue.Queue_ReserveLossSettlementFrozen.selector);
        queue.closeEpoch(50);

        // Door 1: carol recapitalizes one micro-USDC.
        uint256 snap = vm.snapshotState();
        vm.startPrank(carol);
        IERC20(USDC).approve(address(reserves), 1);
        reserves.recapitalize(1);
        vm.stopPrank();
        assertEq(_supplyMinusBacking(), -(int256(SCALE) - 1), "one unit against a 1-wei hole: surplus 1e12 - 1");
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveDeficitResolved(1, keccak256("fin"));
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossIncidentClosed(incidentId);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit GuardianReserveLossArmsEnabled(false);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveLossArmFinalized(armId, incidentId, keccak256("fin"));
        reserves.finalizeAndDisable(armId, keccak256("fin"));
        assertEq(reserves.reserveDeficit(), 0, "deficit cleared by finalisation");
        _assertLocked(false, "door 1");
        assertTrue(vm.revertToState(snap), "revert 1");

        // Door 2: alice's sub-par exit, charged one whole unit.
        snap = vm.snapshotState();
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 out = controller.redeem(1e18, 999_999);
        assertEq(out, 999_999, "one unit below par");
        assertEq(IERC20(USDC).balanceOf(alice) - usdcBefore, 999_999, "paid");
        assertEq(controller.seniorSubParShortfall(), SCALE, "a whole unit crystallised against a 1-wei hole");
        assertEq(_supplyMinusBacking(), -(int256(SCALE) - 1), "surplus 1e12 - 1 for the survivors");
        reserves.finalizeAndDisable(armId, evidence);
        _assertLocked(false, "door 2");
        assertTrue(vm.revertToState(snap), "revert 2");

        // Door 3: one unit returned and credited through the arm's ceiling.
        snap = vm.snapshotState();
        _donate(1);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_RecoveredUSDCNotCredited.selector, armId, 1)
        );
        reserves.finalizeAndDisable(armId, evidence); // still a deficit AND an uncredited return: which fires first
        assertEq(reserves.creditRecoveredIdleUSDC(armId, evidence), SCALE, "one unit credited");
        assertEq(reserves.reserveLossRecoveryCapacity(armId), lossUnits - 1, "ceiling decremented");
        assertEq(_supplyMinusBacking(), -(int256(SCALE) - 1), "surplus 1e12 - 1");
        reserves.finalizeAndDisable(armId, evidence);
        _assertLocked(false, "door 3");
        assertTrue(vm.revertToState(snap), "revert 3");

        // Legacy close cannot bypass the active arm's finalization checks.
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        reserves.closeReserveLossIncident(incidentId);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyActive.selector, incidentId)
        );
        reserves.resolveReserveDeficit(evidence);

        // Clean up Part A through door 1 so Part B starts from a released machine.
        vm.startPrank(carol);
        IERC20(USDC).approve(address(reserves), 1);
        reserves.recapitalize(1);
        vm.stopPrank();
        reserves.finalizeAndDisable(armId, evidence);
        reserves.setGuardianReserveLossArmsEnabled(true);

        // ── Part B: a 1-wei mark, custody intact, then an arm ──
        _mintFromUSDC(bob, 1_000_000e6);
        uint256 tokenId = _originateAndFund(500_000e18);
        // Remove the surplus door 1 left so the mark alone decides the sign.
        uint256 surplus = uint256(-_supplyMinusBacking());
        assertEq(surplus, SCALE - 1, "door 1's surplus");
        reserves.recognizePrincipalImpairment(tokenId, surplus + 1, keccak256("mark"));
        assertEq(_supplyMinusBacking(), 1, "under-backed by one wei, custody intact");
        assertEq(reserves.idleCustodyShortfall(), 0, "no objective shortfall");
        (uint256 armB,) = reserves.armReserveLossFreeze(keccak256("arm-over-mark"));
        assertEq(armB, 2, "second arm");
        vm.expectRevert(IReserveManager.ReserveManager_ShortfallCured.selector);
        reserves.ratifyAndOpen(armB, keccak256("arm-over-mark"), type(uint256).max);
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        reserves.cancelAndDisable(armB, keccak256("arm-over-mark"));
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveIncident.selector);
        reserves.finalizeAndDisable(armB, keccak256("arm-over-mark"));
        vm.expectRevert(IReserveManager.ReserveManager_NoReserveDeficit.selector);
        reserves.resolveReserveDeficit(keccak256("arm-over-mark"));
        _checkMarkedArmResolution(tokenId, armB);
        assertEq(_supplyMinusBacking(), -(int256(SCALE) - 1), "overshoot into surplus");
        _assertLocked(false, "Part B released");
        // And the reversible door for the timelock: release the mark instead.
        reserves.setGuardianReserveLossArmsEnabled(true);
        reserves.recognizePrincipalImpairment(tokenId, SCALE, keccak256("mark-2"));
        assertEq(_supplyMinusBacking(), 1, "under-backed by one wei again");
        (uint256 armC,) = reserves.armReserveLossFreeze(keccak256("arm-over-mark-2"));
        assertEq(armC, 3, "third arm");
        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        reserves.cancelAndDisable(armC, keccak256("arm-over-mark-2"));
        reserves.releasePrincipalImpairment(tokenId, SCALE, keccak256("release"));
        reserves.setGuardianReserveLossArmsEnabled(false); // already disabled: the cancel must not re-emit
        vm.recordLogs();
        reserves.cancelAndDisable(armC, keccak256("arm-over-mark-2"));
        Vm.Log[] memory cancelLogs = vm.getRecordedLogs();
        assertEq(
            _countReserveLogs(cancelLogs, GuardianReserveLossArmsEnabled.selector), 0, "no redundant disable event"
        );
        assertEq(_countReserveLogs(cancelLogs, ReserveLossArmCancelled.selector), 1, "cancelled");
        _assertLocked(false, "mark released, arm cancelled");
    }

    function _checkMarkedArmResolution(uint256 tokenId, uint256 armId) private {
        bytes32 beforeState = _markedExitState(tokenId);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_ReserveLossArmFreeze.selector, armId, 999_999, 1e18)
        );
        controller.redeem(1e18, 999_999);
        assertEq(_markedExitState(tokenId), beforeState, "refused exit preserves financial state");

        reserves.cancelUnratifiedArm(armId, keccak256("custody reconciled; retain credit mark"));
        assertEq(_markedExitState(tokenId), beforeState, "cancellation preserves financial state");
        (uint256 activeArm,,,) = reserves.reserveLossArm();
        assertEq(activeArm, 0, "the exact arm is resolved");
        uint256 mark = reserves.principalImpairmentOf(tokenId);
        assertGt(mark, 0, "credit mark remains live");
        vm.prank(bob);
        assertEq(controller.redeem(1e18, 999_999), 999_999, "discounted exit settles after resolution");
        assertEq(reserves.principalImpairmentOf(tokenId), mark, "settlement retains the mark");
    }

    function _markedExitState(uint256 tokenId) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                controller.totalUSDfr(),
                reserves.principalImpairmentOf(tokenId),
                IERC20(USDC).balanceOf(bob),
                usdfr.balanceOf(bob),
                reserves.recognizedBackingValue(),
                reserves.exitPrepaidAbsorption()
            )
        );
    }
}
