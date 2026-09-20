// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveManager} from "../ReserveManager.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {LossEventIds} from "./LossEventIds.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveIncidentLib
/// @notice Native reserve incident bookkeeping with the original host storage and event identity.
/// @dev ReserveManager retains its authority, reentrancy and accrual-idle guards. It also retains
///      fee preparation and cascade calls. This helper locates no storage and calls no public
///      library function; every operation runs through a linked call in the reserve context.
library ReserveIncidentLib {
    /// @notice Opens the native legacy incident with its original unique event identity.
    /// @dev Legacy bookkeeping is unavailable while an arm owns the custody incident lifecycle.
    function openIncident(ReserveManager.ReserveStorage storage $, uint256 incidentNonce, bytes32 evidenceHash)
        public
        returns (uint256 incidentId)
    {
        if ($.activeReserveLossArmId != 0) {
            revert IReserveManager.ReserveManager_ArmAlreadyActive($.activeReserveLossArmId);
        }
        if (incidentNonce >= LossEventIds.CUSTODY_EVENT_NAMESPACE_START) {
            revert IReserveManager.ReserveManager_InvalidIncidentNonce(incidentNonce);
        }
        if ($.activeReserveLossIncidentId != 0) {
            revert IReserveManager.ReserveManager_IncidentAlreadyActive($.activeReserveLossIncidentId);
        }
        incidentId = LossEventIds.custodyEventId(incidentNonce);
        if ($.reserveLossIncidentUsed[incidentId]) {
            revert IReserveManager.ReserveManager_IncidentAlreadyUsed(incidentId);
        }
        $.reserveLossIncidentUsed[incidentId] = true;
        $.activeReserveLossIncidentId = incidentId;
        $.activeReserveLossEvidenceHash = evidenceHash;
        emit IReserveManager.ReserveLossIncidentOpened(incidentId, incidentNonce, evidenceHash);
    }

    /// @notice Closes only the currently active native incident.
    /// @dev An arm-owned incident must close through the arm's checked finalization route.
    function closeIncident(ReserveManager.ReserveStorage storage $, uint256 incidentId) public {
        if ($.activeReserveLossArmId != 0) {
            revert IReserveManager.ReserveManager_ArmAlreadyActive($.activeReserveLossArmId);
        }
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) revert IReserveManager.ReserveManager_NoActiveIncident();
        if (incidentId != active) revert IReserveManager.ReserveManager_IncidentMismatch(active, incidentId);
        $.activeReserveLossIncidentId = 0;
        $.activeReserveLossEvidenceHash = bytes32(0);
        emit IReserveManager.ReserveLossIncidentClosed(incidentId);
    }

    /// @notice Clears a recorded deficit only after the controller proves no deficit remains.
    /// @dev The caller supplies the host namespace after its existing entry checks.
    function resolveDeficit(ReserveManager.ReserveStorage storage $, bytes32 evidenceHash) public {
        uint256 recordedDeficit = $.reserveDeficit;
        if (recordedDeficit == 0) revert IReserveManager.ReserveManager_NoReserveDeficit();
        if ($.activeReserveLossIncidentId != 0) {
            revert IReserveManager.ReserveManager_IncidentAlreadyActive($.activeReserveLossIncidentId);
        }
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 observedDeficit = supply > backing ? supply - backing : 0;
        if (observedDeficit != 0) {
            revert IReserveManager.ReserveManager_DeficitStillExists(recordedDeficit, observedDeficit);
        }
        $.reserveDeficit = 0;
        emit IReserveManager.ReserveDeficitResolved(recordedDeficit, evidenceHash);
    }

    /// @notice Arms one native custody incident under the host's guardian authority.
    /// @dev The caller supplies the host namespace after its existing entry checks.
    function arm(ReserveManager.ReserveStorage storage $, bytes32 evidenceHash)
        public
        returns (uint256 armId, uint256 incidentId)
    {
        if (!$.guardianReserveLossArmsEnabled) revert IReserveManager.ReserveManager_GuardianArmsDisabled();
        if ($.activeReserveLossArmId != 0) {
            revert IReserveManager.ReserveManager_ArmAlreadyActive($.activeReserveLossArmId);
        }
        if ($.activeReserveLossIncidentId != 0) {
            revert IReserveManager.ReserveManager_IncidentAlreadyActive($.activeReserveLossIncidentId);
        }
        // Legacy incidents share the custody identity namespace. Skip identities they
        // already consumed; the monotone cursor prevents rescanning those rows next time.
        armId = $.nextReserveLossArmId;
        do {
            ++armId;
            if (armId >= LossEventIds.CUSTODY_EVENT_NAMESPACE_START) {
                revert IReserveManager.ReserveManager_ArmIdExhausted();
            }
            incidentId = LossEventIds.custodyEventId(armId);
        } while ($.reserveLossIncidentUsed[incidentId]);
        assert(LossEventIds.isCustodyEvent(incidentId));
        $.nextReserveLossArmId = armId;
        $.activeReserveLossArmId = armId;
        $.activeReserveLossArmEvidenceHash = evidenceHash;
        emit IReserveManager.ReserveLossArmed(armId, incidentId, evidenceHash);
    }

    /// @notice Cancels the exact arm only when its native interlock can be released.
    /// @dev The caller supplies the host namespace after its existing entry checks.
    function cancel(ReserveManager.ReserveStorage storage $, uint256 expectedArmId, bytes32 evidenceHash) public {
        uint256 armId = _requireActiveArm($, expectedArmId);
        _requireInterlockReleasable($);
        _consumeArmAndDisable($);
        emit IReserveManager.ReserveLossArmCancelled(armId, evidenceHash);
    }

    /// @notice Cancels a false alarm without releasing any independent credit impairment.
    /// @dev The host retains governance authority and its operation-idle check.
    function cancelUnratified(ReserveManager.ReserveStorage storage $, uint256 expectedArmId, bytes32 evidenceHash)
        public
    {
        if (evidenceHash == bytes32(0)) revert IReserveManager.ReserveManager_ZeroEvidenceHash();
        uint256 armId = _requireActiveArm($, expectedArmId);
        if ($.reserveLossIncidentUsed[LossEventIds.custodyEventId(armId)]) {
            revert IReserveManager.ReserveManager_ArmAlreadyRatified(armId);
        }
        if (
            $.activeReserveLossIncidentId != 0 || $.recognizedSupplyReduction != 0 || $.reserveDeficit != 0
                || address($.lossController).code.length == 0 || _liveShortfallUnits($) != 0
        ) revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        _consumeArmAndDisable($);
        emit IReserveManager.UnratifiedReserveLossArmCancelled(armId, evidenceHash, $.totalPrincipalImpairment);
    }

    /// @notice Credits measured native recovery up to the original incident capacity.
    /// @dev The caller supplies the host namespace after its existing entry checks.
    function creditRecovery(ReserveManager.ReserveStorage storage $, uint256 armId, bytes32 evidenceHash)
        public
        returns (uint256 credited)
    {
        uint256 capacity = $.reserveLossRecoveryCapacityUnits[armId];
        uint256 units = _availableRecoveredUSDC($, armId);
        if (units == 0) revert IReserveManager.ReserveManager_NoRecoveredUSDC(armId);
        $.idleUSDCUnits += units;
        $.reserveLossRecoveryCapacityUnits[armId] = capacity - units;
        credited = ReserveStorageLib.normalize(units);
        emit IReserveManager.RecoveredIdleUSDCCredited(armId, units, credited, evidenceHash);
    }

    /// @notice Finalizes the exact fully settled arm and disables further guardian arms.
    /// @dev The caller supplies the host namespace after its existing entry checks.
    function finalize(ReserveManager.ReserveStorage storage $, uint256 expectedArmId, bytes32 evidenceHash) public {
        uint256 armId = _requireActiveArm($, expectedArmId);
        uint256 incidentId = LossEventIds.custodyEventId(armId);
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) revert IReserveManager.ReserveManager_NoActiveIncident();
        if (incidentId != active) revert IReserveManager.ReserveManager_IncidentMismatch(active, incidentId);
        if ($.recognizedSupplyReduction != 0) {
            revert IReserveManager.ReserveManager_RecognizedLossOutstanding($.recognizedSupplyReduction);
        }
        uint256 liveShortfall = _liveShortfallUnits($);
        if (liveShortfall != 0) revert IReserveManager.ReserveManager_LiveShortfallExists(liveShortfall);
        uint256 availableRecovery = _availableRecoveredUSDC($, armId);
        if (availableRecovery != 0) {
            revert IReserveManager.ReserveManager_RecoveredUSDCNotCredited(armId, availableRecovery);
        }
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 observedDeficit = supply > backing ? supply - backing : 0;
        uint256 recordedDeficit = $.reserveDeficit;
        if (observedDeficit != 0) {
            revert IReserveManager.ReserveManager_DeficitStillExists(recordedDeficit, observedDeficit);
        }
        if (recordedDeficit != 0) {
            $.reserveDeficit = 0;
            emit IReserveManager.ReserveDeficitResolved(recordedDeficit, evidenceHash);
        }
        $.activeReserveLossIncidentId = 0;
        $.activeReserveLossEvidenceHash = bytes32(0);
        emit IReserveManager.ReserveLossIncidentClosed(incidentId);
        _consumeArmAndDisable($);
        emit IReserveManager.ReserveLossArmFinalized(armId, incidentId, evidenceHash);
    }

    function _requireInterlockReleasable(ReserveManager.ReserveStorage storage $) private view {
        if (
            $.activeReserveLossIncidentId != 0 || $.recognizedSupplyReduction != 0 || $.reserveDeficit != 0
                || _liveShortfallUnits($) != 0
        ) revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0) || controller.totalUSDfr() > controller.backingValue()) {
            revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        }
    }

    function _requireActiveArm(ReserveManager.ReserveStorage storage $, uint256 expectedArmId)
        private
        view
        returns (uint256 armId)
    {
        armId = $.activeReserveLossArmId;
        if (armId == 0) revert IReserveManager.ReserveManager_NoActiveArm();
        if (expectedArmId != armId) revert IReserveManager.ReserveManager_ArmMismatch(armId, expectedArmId);
    }

    function _consumeArmAndDisable(ReserveManager.ReserveStorage storage $) private {
        $.activeReserveLossArmId = 0;
        $.activeReserveLossArmEvidenceHash = bytes32(0);
        if ($.guardianReserveLossArmsEnabled) {
            $.guardianReserveLossArmsEnabled = false;
            emit IReserveManager.GuardianReserveLossArmsEnabled(false);
        }
    }

    function _availableRecoveredUSDC(ReserveManager.ReserveStorage storage $, uint256 armId)
        private
        view
        returns (uint256 units)
    {
        uint256 capacity = $.reserveLossRecoveryCapacityUnits[armId];
        uint256 live = $.usdcToken.balanceOf(address(this));
        uint256 recorded = $.idleUSDCUnits;
        if (capacity == 0 || live <= recorded) return 0;
        uint256 surplus = live - recorded;
        return surplus < capacity ? surplus : capacity;
    }

    function _liveShortfallUnits(ReserveManager.ReserveStorage storage $) private view returns (uint256) {
        uint256 live = $.usdcToken.balanceOf(address(this));
        return $.idleUSDCUnits > live ? $.idleUSDCUnits - live : 0;
    }
}
