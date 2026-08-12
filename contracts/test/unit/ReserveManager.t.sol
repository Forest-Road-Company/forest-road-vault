// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ReserveManager} from "../../src/ReserveManager.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IReserveLossAbsorber} from "../../src/interfaces/IReserveLossAbsorber.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract LyingReserveLossAbsorber is IReserveLossAbsorber {
    address internal immutable source;

    constructor(address source_) {
        source = source_;
    }

    function reserveLossSource() external view returns (address) {
        return source;
    }

    function absorbReserveLoss(uint256, uint256 backingReduction)
        external
        pure
        returns (ReserveLossAllocation memory allocation)
    {
        // Claims senior supply was burned while deliberately changing no supply.
        allocation.seniorBurned = backingReduction;
    }
}

/// @dev Test-only curator that changes backing during a custody cascade while reporting an
///      otherwise honest zero layer-one allocation. The terminal ReserveManager post-check must
///      reject that extra write-down rather than certify a stale expected deficit.
contract BackingMutatingReserveLossCurator {
    IERC20 internal immutable usdfr;
    address internal immutable vault;
    IReserveManager internal immutable reserves;
    uint256 internal immutable facilityId;
    uint256 internal immutable writeDown;

    constructor(IERC20 usdfr_, address vault_, IReserveManager reserves_, uint256 facilityId_, uint256 writeDown_) {
        usdfr = usdfr_;
        vault = vault_;
        reserves = reserves_;
        facilityId = facilityId_;
        writeDown = writeDown_;
    }

    function modules() external view returns (address, address, address) {
        return (address(usdfr), address(1), vault);
    }

    function reserveManager() external view returns (address) {
        return address(reserves);
    }

    function absorbGlobalLoss(uint256 loss) external returns (uint256 absorbed, uint256 residual) {
        reserves.recordPrincipalWritedown(facilityId, writeDown);
        return (0, loss);
    }
}

contract ReserveManagerTest is TokenLayerFixture {
    function _deposit(address from, uint256 units) internal {
        vm.prank(from);
        usdc.approve(address(reserves), units);
        vm.prank(creditModule);
        reserves.depositUSDC(from, units);
    }

    function _activeArmEvidence() internal view returns (bytes32 evidenceHash) {
        (,, evidenceHash,) = reserves.reserveLossArm();
    }

    function _expectInvalidGovernanceTiming() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_InvalidGovernanceTiming.selector,
                address(reserveLossGovernor),
                address(reserveLossTimelock)
            )
        );
        vm.prank(admin);
        reserves.setReserveLossModules(
            address(reserveLossCurator),
            address(reserveLossBackstop),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
    }

    function test_reserveLossArmAndCancellationEventsCarryFullIdentity() public {
        bytes32 armedEvidence = keccak256("event-arm");
        uint256 expectedArmId = 1;
        uint256 expectedIncidentId = type(uint256).max - expectedArmId;

        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.ReserveLossArmed(expectedArmId, expectedIncidentId, armedEvidence);
        vm.prank(guardian);
        (uint256 armId, uint256 incidentId) = reserves.armReserveLossFreeze(armedEvidence);
        assertEq(armId, expectedArmId);
        assertEq(incidentId, expectedIncidentId);

        bytes32 cancellationEvidence = keccak256("event-cancel");
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.GuardianReserveLossArmsEnabled(false);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.ReserveLossArmCancelled(armId, cancellationEvidence);
        vm.prank(admin);
        reserves.cancelAndDisable(armId, cancellationEvidence);
    }

    function test_reserveLossRecognitionAllocationRatificationAndFinalizationEventsCarryExactAccounting() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        (uint256 armId, uint256 incidentId) = _armReserveLoss(701);
        bytes32 armedEvidence = _activeArmEvidence();
        _createReserveShortfall(25e18);

        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.ReserveLossIncidentOpened(incidentId, armId, armedEvidence);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IReserveManager.ReserveLossRecognized(incidentId, 25e18, 0, 25e18);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IReserveManager.ReserveLossAllocated(incidentId, 25e18, 0, 0, 0, 25e18, 0);
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.IdleUSDCWrittenDown(25e18, 75e18);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.ReserveLossRatified(armId, incidentId, 25e18, 25e18, armedEvidence);
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, armedEvidence, 25e18);

        bytes32 finalEvidence = keccak256("event-finalize");
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IReserveManager.ReserveLossIncidentClosed(incidentId);
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.GuardianReserveLossArmsEnabled(false);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit IReserveManager.ReserveLossArmFinalized(armId, incidentId, finalEvidence);
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, finalEvidence);
    }

    function test_reserveDeficitUpdateAndResolutionEventsCarryExactAmounts() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        (uint256 armId, uint256 incidentId) = _armReserveLoss(702);
        bytes32 armedEvidence = _activeArmEvidence();
        _createReserveShortfall(50e18);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IReserveManager.ReserveDeficitUpdated(incidentId, 0, 40e18);
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, armedEvidence, 50e18);

        vm.startPrank(bob);
        usdc.approve(address(reserves), 40e6);
        reserves.recapitalize(40e6);
        vm.stopPrank();

        bytes32 resolutionEvidence = keccak256("event-deficit-resolved");
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.ReserveDeficitResolved(40e18, resolutionEvidence);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit IReserveManager.ReserveLossIncidentClosed(incidentId);
        vm.expectEmit(false, false, false, true, address(reserves));
        emit IReserveManager.GuardianReserveLossArmsEnabled(false);
        vm.expectEmit(true, true, true, true, address(reserves));
        emit IReserveManager.ReserveLossArmFinalized(armId, incidentId, resolutionEvidence);
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, resolutionEvidence);
    }

    function test_recoveredIdleUSDCEventBindsArmEvidenceUnitsAndValue() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(703);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);

        vm.prank(borrower);
        usdc.transfer(address(reserves), 50e6);
        bytes32 recoveryEvidence = keccak256("event-recovery");
        vm.expectEmit(true, true, false, true, address(reserves));
        emit IReserveManager.RecoveredIdleUSDCCredited(armId, 50e6, 50e18, recoveryEvidence);
        vm.prank(admin);
        reserves.creditRecoveredIdleUSDC(armId, recoveryEvidence);
    }

    function test_setReserveLossModulesRejectsGovernorWithWrongTimelock() public {
        reserveLossGovernor.setTimelock(address(1));
        _expectInvalidGovernanceTiming();
    }

    function test_setReserveLossModulesRejectsGovernorWhoseClockReverts() public {
        reserveLossGovernor.setClockReverts(true);
        _expectInvalidGovernanceTiming();
    }

    function test_setReserveLossModulesRejectsGovernorWhoseClockValueIsNotLiveTimestamp() public {
        vm.mockCall(
            address(reserveLossGovernor), abi.encodeWithSignature("clock()"), abi.encode(uint48(block.timestamp - 1))
        );
        _expectInvalidGovernanceTiming();
    }

    function test_setReserveLossModulesRejectsGovernorWithNonTimestampClockMode() public {
        reserveLossGovernor.setInvalidClockMode(true);
        _expectInvalidGovernanceTiming();
    }

    function test_setReserveLossModulesRejectsUnreadableVotingDelay() public {
        vm.mockCallRevert(address(reserveLossGovernor), abi.encodeWithSignature("votingDelay()"), bytes("unreadable"));
        _expectInvalidGovernanceTiming();
    }

    function test_setReserveLossModulesRejectsUnreadableVotingPeriod() public {
        vm.mockCallRevert(address(reserveLossGovernor), abi.encodeWithSignature("votingPeriod()"), bytes("unreadable"));
        _expectInvalidGovernanceTiming();
    }

    function test_setReserveLossModulesRejectsUnreadableTimelockDelay() public {
        vm.mockCallRevert(address(reserveLossTimelock), abi.encodeWithSignature("getMinDelay()"), bytes("unreadable"));
        _expectInvalidGovernanceTiming();
    }

    function test_cancelAndDisableRejectsReleaseWhileObjectiveShortfallExists() public {
        _mintUSDfr(alice, 10e6);
        (uint256 armId,) = _armReserveLoss(704);
        _createReserveShortfall(1e18);

        vm.expectRevert(IReserveManager.ReserveManager_InterlockReleaseForbidden.selector);
        vm.prank(admin);
        reserves.cancelAndDisable(armId, keccak256("forbidden-release"));
    }

    function test_armRejectsWhenLegacyIncidentIsAlreadyActive() public {
        uint256 incidentId = _openReserveLossIncident(705);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyActive.selector, incidentId)
        );
        vm.prank(guardian);
        reserves.armReserveLossFreeze(keccak256("incident-already-active"));
    }

    function test_finalizeRejectsArmThatHasNoActiveIncident() public {
        (uint256 armId,) = _armReserveLoss(706);
        vm.expectRevert(IReserveManager.ReserveManager_NoActiveIncident.selector);
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("no-active-incident"));
    }

    function test_terminalPostCheckRejectsBackingMutationInsideCascade() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        uint256 facilityId = 707;
        vm.prank(creditModule);
        reserves.recordDeployment(facilityId, borrower, 1e6);
        BackingMutatingReserveLossCurator mutator = new BackingMutatingReserveLossCurator(
            IERC20(address(usdfr)), address(vault), IReserveManager(address(reserves)), facilityId, 1e18
        );
        vm.startPrank(admin);
        reserves.grantRole(Roles.CREDIT_ROLE, address(mutator));
        reserves.setReserveLossModules(
            address(mutator),
            address(reserveLossBackstop),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(707);
        bytes32 evidenceHash = _activeArmEvidence();
        _createReserveShortfall(25e18);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_PostLossDeficitMismatch.selector, 0, 1e18)
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 25e18);
    }

    function test_USDCOnly_exactDepositAndNormalization() public {
        _deposit(alice, 125e6);
        assertEq(reserves.usdc(), address(usdc));
        assertEq(reserves.idleUSDC(), 125e6);
        assertEq(reserves.idleReserve(), 125e18);
        assertEq(reserves.totalBackingValue(), 125e18);
        assertEq(reserves.normalizeUSDC(1), 1e12);
        assertEq(reserves.denormalizeUSDC(1e12), 1);
    }

    function test_directDonationNeverCreatesBacking() public {
        usdc.mint(address(reserves), 50e6);
        assertEq(usdc.balanceOf(address(reserves)), 50e6);
        assertEq(reserves.idleReserve(), 0);
        assertEq(reserves.reconcileIdleUSDC(), 0);
        assertEq(reserves.totalBackingValue(), 0);
    }

    function test_reconcileObservesCustodyLossWithoutChangingAccounting() public {
        _mintUSDfr(alice, 100e6);
        _createReserveShortfall(25e18);

        (uint256 recorded, uint256 live, uint256 shortfall) = reserves.observeIdleUSDC();
        assertEq(recorded, 100e6);
        assertEq(live, 75e6);
        assertEq(shortfall, 25e6);
        assertEq(reserves.reconcileIdleUSDC(), 25e6, "checkpoint returns native-unit shortfall");
        assertEq(reserves.idleReserve(), 100e18, "observation must not irreversibly write down backing");
        (,, uint256 pending) = reserves.recognizedReserveLoss();
        assertEq(pending, 0, "permissionless observation cannot create an accounting loss");
        assertTrue(reserves.reserveLossExitsLocked(), "objective shortfall must close both protected exits");
        assertTrue(
            reserves.curatorWithdrawalsLocked(), "the curator-facing compatibility view must expose the same lock"
        );
    }

    function test_armDerivesUniqueUpperNamespaceAndCannotBeReplaced() public {
        (uint256 armId, uint256 incidentId) = _armReserveLoss(7);
        assertEq(armId, 1);
        assertEq(incidentId, type(uint256).max - armId);
        assertGe(incidentId, 1 << 255, "custody incidents occupy only the upper namespace");
        assertFalse(reserves.reserveLossIncidentUsed(incidentId), "an arm is not an adjudication");
        (uint256 storedArm, uint256 storedIncident,, bool enabled) = reserves.reserveLossArm();
        assertEq(storedArm, armId);
        assertEq(storedIncident, incidentId);
        assertTrue(enabled);

        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmAlreadyActive.selector, armId));
        vm.prank(guardian);
        reserves.armReserveLossFreeze(keccak256("replacement"));

        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ArmMismatch.selector, armId, armId + 1));
        vm.prank(admin);
        reserves.cancelAndDisable(armId + 1, keccak256("stale"));

        vm.prank(admin);
        reserves.cancelAndDisable(armId, keccak256("cancelled"));
        assertFalse(reserves.reserveLossExitsLocked());
        (storedArm, storedIncident,, enabled) = reserves.reserveLossArm();
        assertEq(storedArm, 0);
        assertEq(storedIncident, 0);
        assertFalse(enabled, "terminal transition disables later Guardian arms");
    }

    function test_ratificationRequiresTheArmedEvidenceHash() public {
        _mintUSDfr(alice, 10e6);
        (uint256 armId,) = _armReserveLoss(71);
        bytes32 expectedEvidence = _activeArmEvidence();
        bytes32 suppliedEvidence = keccak256("different-incident");
        _createReserveShortfall(1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_ArmEvidenceMismatch.selector, expectedEvidence, suppliedEvidence
            )
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, suppliedEvidence, 1e18);
        assertEq(reserves.idleReserve(), 10e18, "mismatched evidence cannot recognize a loss");

        vm.prank(admin);
        (, uint256 actualLoss) = reserves.ratifyAndOpen(armId, expectedEvidence, 1e18);
        assertEq(actualLoss, 1e18);
    }

    function test_activeArmBlocksLossModuleAndControllerRebinding() public {
        _armReserveLoss(72);

        vm.expectRevert(IReserveManager.ReserveManager_ModuleRebindForbidden.selector);
        vm.prank(admin);
        reserves.setLossController(address(controller));

        vm.expectRevert(IReserveManager.ReserveManager_ModuleRebindForbidden.selector);
        vm.prank(admin);
        reserves.setReserveLossModules(
            address(reserveLossCurator),
            address(reserveLossBackstop),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
    }

    function test_unabsorbableLossRecordsDeficitAndLaterLossRemainsRecordable() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        _armReserveLoss(8);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);

        assertEq(controller.totalUSDfr(), 90e18, "only available senior assets burned");
        assertEq(controller.backingValue(), 50e18, "real backing loss remains recorded");
        assertEq(reserves.reserveDeficit(), 40e18, "unabsorbed loss is latched");
        assertFalse(controller.backingInvariantHolds(), "genuine insolvency deliberately freezes user paths");

        _createReserveShortfall(10e18);
        _ratifyCurrentReserveLoss(10e18);
        assertEq(controller.totalUSDfr(), 90e18, "no newly funded layer was available for the second loss");
        assertEq(controller.backingValue(), 40e18);
        assertEq(reserves.reserveDeficit(), 50e18, "the later real loss remains recordable");

        vm.startPrank(bob);
        usdc.approve(address(controller), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, 90e18, 40e18)
        );
        controller.mint(1e6);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 444_444, 1_000_000)
        );
        vm.prank(alice);
        controller.redeem(1e18);

        assertEq(usdfr.balanceOf(alice), minted - 10e18, "failed mint/redeem cannot move holder balances");
    }

    function test_recoveredCapitalIsCreditedWithoutMintAndFinalizesAtomically() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(81);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);
        assertEq(reserves.reserveDeficit(), 40e18);
        assertEq(reserves.reserveLossRecoveryCapacity(armId), 50e6);

        vm.prank(borrower);
        usdc.transfer(address(reserves), 50e6);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_RecoveredUSDCNotCredited.selector, armId, 50e6)
        );
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("premature-close"));

        vm.prank(admin);
        uint256 credited = reserves.creditRecoveredIdleUSDC(armId, keccak256("returned-custody-capital"));
        assertEq(credited, 50e18);
        assertEq(reserves.idleReserve(), 100e18, "recovered principal is no longer stranded");
        assertEq(controller.totalUSDfr(), 90e18, "crediting recovery never remints burned claims");
        assertEq(reserves.reserveLossRecoveryCapacity(armId), 0);
        assertTrue(controller.backingInvariantHolds(), "returned capital restores direct backing");

        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("recovery-finalized"));
        assertEq(reserves.reserveDeficit(), 0);
        (uint256 activeArm,,,) = reserves.reserveLossArm();
        assertEq(activeArm, 0);
        (uint256 activeIncident,) = reserves.activeReserveLossIncident();
        assertEq(activeIncident, 0);
        assertFalse(reserves.reserveLossExitsLocked());
    }

    function test_lateRecoveryAfterFinalizationCanStillBeCreditedWithoutMint() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(82);
        _createReserveShortfall(25e18);
        _ratifyCurrentReserveLoss(25e18);
        assertEq(controller.totalUSDfr(), 75e18);
        assertEq(controller.backingValue(), 75e18);

        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("finalized-before-recovery"));
        assertFalse(reserves.reserveLossExitsLocked());

        vm.prank(borrower);
        usdc.transfer(address(reserves), 25e6);
        vm.prank(admin);
        uint256 credited = reserves.creditRecoveredIdleUSDC(armId, keccak256("late-recovery"));
        assertEq(credited, 25e18);
        assertEq(reserves.idleReserve(), 100e18, "late returned custody capital cannot remain stranded");
        assertEq(controller.totalUSDfr(), 75e18, "recovery credit cannot reverse completed claim burns");
        assertEq(controller.backingValue(), 100e18, "late recovery restores backing without issuance");
    }

    function test_lossAbsorberContractViolationFiresExactSelector() public {
        _mintUSDfr(alice, 100e6);
        reserveLossCurator.setReportMode(2);
        _armReserveLoss(9);
        _createReserveShortfall(1e18);
        (uint256 armId,,,) = reserves.reserveLossArm();
        bytes32 evidenceHash = _activeArmEvidence();

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_LossAbsorberContractViolated.selector, 1e18, 0)
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 1e18);

        assertEq(reserves.idleReserve(), 100e18, "failed independent post-check rolls accounting back");
        assertEq(controller.totalUSDfr(), 100e18);
    }

    function test_ratificationUsesSeniorOnlyWhenJuniorModulesAreEmpty() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        _armReserveLoss(3);
        _createReserveShortfall(25e18);
        _ratifyCurrentReserveLoss(30e18);

        assertEq(controller.totalUSDfr(), 75e18, "vault principal absorbed the custody loss");
        assertEq(controller.backingValue(), 75e18, "backing fell by the same amount");
        assertTrue(controller.backingInvariantHolds(), "C-01: write-down cannot create a deficit");
    }

    function test_ratificationRechecksCuredAndApprovedAmountAtExecution() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(4);
        bytes32 evidenceHash = _activeArmEvidence();
        _createReserveShortfall(25e18);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_LossExceedsApproval.selector, 25e18, 20e18)
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 20e18);
        assertEq(reserves.idleReserve(), 100e18, "failed ceiling check cannot write down backing");

        vm.prank(borrower);
        usdc.transfer(address(reserves), 25e6);
        vm.expectRevert(IReserveManager.ReserveManager_ShortfallCured.selector);
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 25e18);

        vm.prank(admin);
        reserves.cancelAndDisable(armId, keccak256("objective-state-selects-cancel"));
        assertEq(controller.totalUSDfr(), minted);
    }

    function test_ratificationAbsorbsReducedShortfallRatherThanStaleApprovedAmount() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        (uint256 armId,) = _armReserveLoss(41);
        _createReserveShortfall(25e18);
        vm.prank(borrower);
        usdc.transfer(address(reserves), 15e6);

        bytes32 evidenceHash = _activeArmEvidence();
        vm.prank(admin);
        (, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidenceHash, 25e18);
        assertEq(actualLoss, 10e18, "execution must rederive the current canonical shortfall");
        assertEq(controller.totalUSDfr(), 90e18, "only the live loss is burned");
        assertEq(controller.backingValue(), 90e18, "only the live loss is written down");
    }

    function test_reserveLossCallerGuardFiresExactSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_ReserveLossCallerNotAdmin.selector, alice)
        );
        vm.prank(alice);
        reserves.ratifyAndOpen(1, keccak256("unauthorized"), 1e18);
    }

    function test_lossAllocationMismatchFiresExactSelector() public {
        _mintUSDfr(alice, 100e6);
        reserveLossCurator.setReportMode(1);
        _armReserveLoss(91);
        _createReserveShortfall(1e18);
        (uint256 armId,,,) = reserves.reserveLossArm();
        bytes32 evidenceHash = _activeArmEvidence();
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_LossAllocationMismatch.selector, 0, 0, 1e18, 0)
        );
        vm.prank(admin);
        reserves.ratifyAndOpen(armId, evidenceHash, 1e18);
    }

    function test_invalidLossAbsorberFiresExactSelector() public {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossAbsorber.selector, address(0)));
        vm.prank(admin);
        reserves.setReserveLossModules(
            address(0),
            address(reserveLossBackstop),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
    }

    function test_invalidLossControllerFiresExactSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_InvalidLossController.selector, address(0))
        );
        vm.prank(admin);
        reserves.setLossController(address(0));
    }

    function test_deficitStillExistsFiresExactSelector() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();
        (uint256 armId,) = _armReserveLoss(92);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);
        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_DeficitStillExists.selector, 40e18, 40e18)
        );
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("not-recapitalized"));
    }

    function test_noRecoveredUSDCFiresExactSelector() public {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_NoRecoveredUSDC.selector, 1));
        vm.prank(admin);
        reserves.creditRecoveredIdleUSDC(1, keccak256("none"));
    }

    /// @dev The predecessor asserted that timing drift causing permanent deadlock was safe. It was not.
    function test_timingChangeCannotInvalidateArmOrBlockRatification() public {
        uint256 minted = _mintUSDfr(alice, 10e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();
        vm.prank(guardian);
        (uint256 armId,) = reserves.armReserveLossFreeze(keccak256("persistent-arm"));
        reserveLossGovernor.setVotingPeriod(30 days);
        reserveLossGovernor.setInvalidClockMode(true);
        vm.warp(block.timestamp + 365 days);
        _createReserveShortfall(1e18);
        bytes32 evidenceHash = _activeArmEvidence();
        vm.prank(admin);
        (uint256 incidentId, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidenceHash, 1e18);
        assertEq(actualLoss, 1e18);
        assertEq(incidentId, type(uint256).max - armId);
    }

    /// @dev The predecessor asserted timestamp-only release as safe. An arm now needs a transaction.
    function test_preArmCannotReleaseWithoutExplicitGovernanceResolution() public {
        vm.prank(guardian);
        (uint256 armId,) = reserves.armReserveLossFreeze(keccak256("persistent"));
        vm.warp(block.timestamp + 1000 days);
        assertTrue(reserves.reserveLossExitsLocked());
        vm.prank(admin);
        reserves.setGuardianReserveLossArmsEnabled(false);
        assertTrue(reserves.reserveLossExitsLocked(), "kill switch cannot release an existing arm");

        vm.expectRevert(IReserveManager.ReserveManager_GuardianArmsDisabled.selector);
        vm.prank(guardian);
        reserves.armReserveLossFreeze(keccak256("blocked-rearm"));

        vm.prank(admin);
        reserves.cancelAndDisable(armId, keccak256("explicit-release"));
        assertFalse(reserves.reserveLossExitsLocked());
    }

    function test_reserveLossIncidentUsesUniqueUpperNamespaceAndExactClose() public {
        uint256 incidentId = _openReserveLossIncident(7);
        assertEq(incidentId, type(uint256).max - 7);
        assertGe(incidentId, 1 << 255, "custody incidents occupy only the upper namespace");
        assertTrue(reserves.reserveLossIncidentUsed(incidentId));

        vm.expectRevert(
            abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentMismatch.selector, incidentId, incidentId - 1)
        );
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId - 1);

        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);

        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_IncidentAlreadyUsed.selector, incidentId));
        vm.prank(admin);
        reserves.openReserveLossIncident(7, keccak256("reused"));
    }

    function test_legacyWriteDownPathIsDisabledRegardlessOfIncidentState() public {
        _deposit(alice, 10e6);
        vm.expectRevert(IReserveManager.ReserveManager_LegacyPathDisabled.selector);
        vm.prank(admin);
        reserves.writeDownIdleUSDC(1e18);
    }

    /// @dev RENAMED (SWEEP-3 F-S3-02 STEP 2). The old name and the old assertion message —
    ///      "pre-existing deficit suppresses a second automatic cascade" — described the DELETED
    ///      record-only branch, not the arithmetic. The numbers below are unchanged to the wei
    ///      because in THIS state there is genuinely no capital left: layer 1 was never posted,
    ///      the backstop is unfunded and the vault was burned to zero by the first loss. The
    ///      second loss IS now offered to all three layers; they simply have nothing to give.
    ///      `SweepR2_Remediation.t.sol::test_S3_F2_freshLayer1CapitalAbsorbsALaterLossEvenWithA
    ///      LatchedInsolvency` is the same shape WITH capital, and it moves.
    function test_unabsorbableLossRecordsDeficitAndTheLaterLossFindsNoCapitalLeft() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        _armReserveLoss(8);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);

        assertEq(controller.totalUSDfr(), 90e18, "only available senior assets burned");
        assertEq(controller.backingValue(), 50e18, "real backing loss remains recorded");
        assertEq(reserves.reserveDeficit(), 40e18, "unabsorbed loss is latched");
        assertFalse(controller.backingInvariantHolds(), "genuine insolvency deliberately freezes user paths");

        assertEq(vault.totalAssets(), 0, "precondition: layer 3 was burned to zero, so nothing is left to absorb");
        _createReserveShortfall(10e18);
        _ratifyCurrentReserveLoss(10e18);
        assertEq(controller.totalUSDfr(), 90e18, "every layer was consulted and every layer was empty");
        assertEq(controller.backingValue(), 40e18);
        assertEq(reserves.reserveDeficit(), 50e18, "the later real loss remains recordable");

        vm.startPrank(bob);
        usdc.approve(address(controller), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, 90e18, 40e18)
        );
        controller.mint(1e6);
        vm.stopPrank();

        // The one-argument convenience path carries a par minimum. Sub-par redemption is
        // available only through an explicit loss-tolerant quote, so this attempt fails on its
        // minimum rather than pretending the non-worsening redemption itself is unsafe.
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SlippageExceeded.selector, 444_444, 1_000_000)
        );
        vm.prank(alice);
        controller.redeem(1e18);

        assertEq(usdfr.balanceOf(alice), minted - 10e18, "failed mint/redeem cannot move holder balances");
    }

    function test_deficitRequiresExactRecapitalisationCloseAndArmFinalization() public {
        _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        (uint256 armId, uint256 incidentId) = _armReserveLoss(81);
        _createReserveShortfall(50e18);
        _ratifyCurrentReserveLoss(50e18);
        assertEq(reserves.reserveDeficit(), 40e18);

        vm.startPrank(admin);
        reserves.grantRole(Roles.CONTROLLER_ROLE, admin);
        vm.stopPrank();
        vm.prank(bob);
        usdc.approve(address(reserves), 40e6);
        vm.prank(admin);
        reserves.depositUSDC(bob, 40e6);
        vm.prank(admin);
        reserves.revokeRole(Roles.CONTROLLER_ROLE, admin);
        assertTrue(controller.backingInvariantHolds(), "recapitalisation must restore direct backing first");

        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256("recovery"));
        assertEq(reserves.reserveDeficit(), 0, "arm finalization clears only the stale latch");
        (uint256 activeIncident,) = reserves.activeReserveLossIncident();
        assertEq(activeIncident, 0, "finalization closes the exact arm-derived incident");
        assertTrue(reserves.reserveLossIncidentUsed(incidentId));
        assertTrue(controller.backingInvariantHolds());
    }

    function test_legacyLossAbsorberCannotInfluenceArmBoundCascade() public {
        _mintUSDfr(alice, 100e6);
        LyingReserveLossAbsorber liar = new LyingReserveLossAbsorber(address(reserves));
        vm.prank(admin);
        reserves.setLossAbsorber(address(liar));
        _armReserveLoss(9);
        _createReserveShortfall(1e18);
        _ratifyCurrentReserveLoss(1e18);

        assertEq(reserves.idleReserve(), 99e18, "arm-bound recognition follows physical custody");
        assertEq(controller.totalUSDfr(), 100e18, "legacy absorber cannot claim a synthetic burn");
        assertEq(reserves.reserveDeficit(), 1e18, "the genuine unabsorbed loss remains latched");
    }

    function test_writeDownWithoutJuniorModulesUsesSeniorOnlyAfterIncidentApproval() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        _armReserveLoss(3);
        _createReserveShortfall(25e18);
        _ratifyCurrentReserveLoss(25e18);

        assertEq(controller.totalUSDfr(), 75e18, "vault principal absorbed the custody loss");
        assertEq(controller.backingValue(), 75e18, "backing fell by the same amount");
        assertTrue(controller.backingInvariantHolds(), "C-01: write-down cannot create a deficit");
    }

    function test_reconcileWithoutJuniorModulesUsesSeniorOnlyAfterAuthentication() public {
        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        vault.deposit(minted, alice);
        vm.stopPrank();

        _createReserveShortfall(25e18);
        _armReserveLoss(4);
        (, uint256 actualLoss) = _ratifyCurrentReserveLoss(25e18);
        assertEq(actualLoss, 25e18);

        assertEq(controller.totalUSDfr(), 75e18, "supply absorbed the reconciled loss");
        assertEq(controller.backingValue(), 75e18, "recorded backing matches live custody");
        assertTrue(controller.backingInvariantHolds(), "C-02: reconciliation cannot create a deficit");
    }

    function test_deploymentMovesIdleIntoFacilityWithoutChangingBacking() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 80e6);
        assertEq(reserves.idleReserve(), 20e18);
        assertEq(reserves.deployedTo(7), 80e18);
        assertEq(reserves.deployedPrincipal(), 80e18);
        assertEq(reserves.totalBackingValue(), 100e18);
        assertEq(usdc.balanceOf(borrower), 80e6);
    }

    function test_atomicPaymentRequiresCashAndReducesOnlyPrincipalLeg() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 100e6);

        usdc.mint(bob, 15e6);
        vm.prank(bob);
        usdc.approve(address(reserves), 15e6);
        vm.prank(creditModule);
        uint256 received = reserves.recordPayment(7, bob, 15e6, 10e18);

        assertEq(received, 15e18);
        assertEq(reserves.deployedTo(7), 90e18);
        assertEq(reserves.idleReserve(), 15e18);
        assertEq(reserves.totalBackingValue(), 105e18, "five dollars of interest increased backing");
    }

    function test_atomicPaymentWithoutApprovalLeavesAccountingUntouched() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 100e6);
        usdc.mint(bob, 10e6);

        vm.expectRevert();
        vm.prank(creditModule);
        reserves.recordPayment(7, bob, 10e6, 10e18);
        assertEq(reserves.deployedTo(7), 100e18);
        assertEq(reserves.idleReserve(), 0);
    }

    function test_feeCapitalizationKeepsRetainedCashAndAddsReceivable() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 98e6);
        vm.prank(creditModule);
        reserves.recordFeeCapitalization(7, 2e18);

        assertEq(reserves.idleReserve(), 2e18, "OID cash remains in treasury");
        assertEq(reserves.deployedTo(7), 100e18, "borrower owes full face");
        assertEq(reserves.totalBackingValue(), 102e18, "cash and capitalized receivable are distinct assets");
    }

    function test_writedownIsDurableAndCannotExceedFacility() public {
        _deposit(alice, 100e6);
        vm.prank(creditModule);
        reserves.recordDeployment(7, borrower, 100e6);
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(7, 30e18);
        assertEq(reserves.deployedTo(7), 70e18);
        assertEq(reserves.totalBackingValue(), 70e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IReserveManager.ReserveManager_InsufficientDeployedPrincipal.selector, 7, 71e18, 70e18
            )
        );
        vm.prank(creditModule);
        reserves.recordPrincipalWritedown(7, 71e18);
    }

    function test_nonCreditCannotMutatePrincipal() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.CREDIT_ROLE)
        );
        vm.prank(alice);
        reserves.recordDeployment(1, borrower, 1);
    }

    function test_valueConversionRejectsSubUSDCPrecision() public {
        vm.expectRevert(abi.encodeWithSelector(IReserveManager.ReserveManager_ValueNotUSDCExact.selector, 1e12 + 1));
        reserves.denormalizeUSDC(1e12 + 1);
    }

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new ReserveManager());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        reserves.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        reserves.upgradeToAndCall(newImpl, "");
    }
}
