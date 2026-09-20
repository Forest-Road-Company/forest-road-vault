// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {LossEventIds} from "./LossEventIds.sol";
import {ReserveCascadeLib} from "./ReserveCascadeLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveArmLib - per-asset custody-loss resolution
/// @notice The host keeps authorization and operation guards. Linked bodies use the reserve's
///         namespace and address, so custody measurements belong to the proxy.
/// @dev Arms transition from Armed to Ratified to Finalized. Governance can instead cancel
///      an Armed false alarm. The explicit credit-preserving cancellation additionally proves
///      physical custody and leaves all credit marks and prepayments intact.
library ReserveArmLib {
    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;

    /// @notice Opens a custody-loss adjudication for one asset.
    /// @dev THE ASSET IS A FIELD OF THE ARM AND NEVER ENTERS THE ID. `nextReserveLossArmId` stays a
    ///      single global monotone counter, so there is exactly one id source and no shared,
    ///      never-cleared used-marker to poison. "Used" is the arm's own state. `activeArmOf` gives
    ///      singularity PER ASSET, so an incident in one asset cannot block another's adjudication.
    ///
    ///      THE ID SPACE IS BOUNDED. Arm ids are refused once they would reach
    ///      `LossEventIds.CUSTODY_EVENT_NAMESPACE_START`, because beyond it a custody incident id
    ///      would collide with another loss family's namespace and two different events would share
    ///      one identifier in the register.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param asset The asset under adjudication.
    /// @param evidenceHash Commitment to the incident record; every later act must match it.
    /// @return armId The new arm's id.
    /// @return incidentId The cascade-facing id derived from it.
    function arm(ReserveStorageLib.ReserveStorage storage $, address asset, bytes32 evidenceHash)
        public
        returns (uint256 armId, uint256 incidentId)
    {
        $.requireListed(asset);
        if (!$.guardianReserveLossArmsEnabled) revert IReserveManager.ReserveManager_GuardianArmsDisabled();
        uint256 active = $.activeArmOf[asset];
        if (active != 0) revert IReserveManager.ReserveManager_ArmAlreadyActive(active);
        armId = $.nextReserveLossArmId + 1;
        if (armId >= LossEventIds.CUSTODY_EVENT_NAMESPACE_START) revert IReserveManager.ReserveManager_ArmIdExhausted();
        incidentId = LossEventIds.custodyEventId(armId);
        $.nextReserveLossArmId = armId;
        $.activeArmOf[asset] = armId;
        $.openArmCount += 1;
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        a.asset = asset;
        a.state = IReserveManager.ArmState.Armed;
        a.evidenceHash = evidenceHash;
        emit IReserveManager.ReserveLossArmed(armId, asset, incidentId, evidenceHash);
    }

    /// @notice Abandons an arm that was opened but never ratified.
    /// @dev ARMED ONLY, AND ONLY WHILE NOTHING IS LIVE. A ratified arm has already moved value
    ///      through the cascade and cannot be walked back by cancelling; `requireInterlockReleasable`
    ///      additionally refuses while any recognised reduction, deficit or standing shortfall
    ///      exists, or while the controller reports supply above backing. Cancelling is the "we were
    ///      wrong, nothing happened" path, so it must not be reachable in a state where something
    ///      did.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param asset The asset whose arm is being cancelled.
    /// @param expectedArmId The arm the caller believes is active; a mismatch reverts.
    /// @param evidenceHash Commitment to the cancellation record.
    function cancel(
        ReserveStorageLib.ReserveStorage storage $,
        address asset,
        uint256 expectedArmId,
        bytes32 evidenceHash
    ) public {
        uint256 armId = requireActiveArm($, asset, expectedArmId);
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        if (a.state != IReserveManager.ArmState.Armed) {
            revert IReserveManager.ReserveManager_ArmStateInvalid(armId, a.state);
        }
        requireInterlockReleasable($);
        closeArm($, a, asset);
        emit IReserveManager.ReserveLossArmCancelled(armId, asset, evidenceHash);
    }

    /// @notice Cancels the exact false alarm while preserving every credit-accounting tally.
    /// @dev The host authenticates governance and rejects overlapping accrual operations.
    ///      Only the selected asset is read externally; unreadable custody cannot prove resolution.
    function cancelUnratified(
        ReserveStorageLib.ReserveStorage storage $,
        address asset,
        uint256 expectedArmId,
        bytes32 evidenceHash
    ) public {
        if (evidenceHash == bytes32(0)) revert IReserveManager.ReserveManager_ZeroEvidenceHash();
        uint256 armId = requireActiveArm($, asset, expectedArmId);
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        if (a.state != IReserveManager.ArmState.Armed) {
            revert IReserveManager.ReserveManager_ArmStateInvalid(armId, a.state);
        }
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        if (
            $.recognizedSupplyReduction != 0 || $.reserveDeficit != 0 || $.totalCustodyShortfallValue != 0
                || r.custodyShortfallUnits != 0 || address($.lossController).code.length == 0
                || IERC20(asset).balanceOf(address(this)) < ReserveStorageLib.custodiedUnits(r)
        ) revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        closeArm($, a, asset);
        emit IReserveManager.UnratifiedReserveLossArmCancelled(armId, asset, evidenceHash, $.totalPrincipalImpairment);
    }

    /// @notice Refreshes custody, then recognizes the complete latched loss through the cascade.
    /// @dev Refresh the selected asset after identity and evidence checks, before reading the
    ///      loss and enforcing the approved ceiling. Reconciliation reduces backing through idle
    ///      debits or an unapplied loss
    ///      deduction. Ratification must not charge it again. The latch and its unapplied part
    ///      move into this arm's recovery ledgers; the aggregate backing deduction remains.
    ///
    ///      RE-ENTRANT BY DESIGN. `Armed` on the first tranche and `Ratified` on every later one, so
    ///      a shortfall that is discovered in stages is adjudicated under a single arm and a single
    ///      evidence hash rather than fragmenting into several incidents.
    ///
    ///      BOUNDED BY ITS OWN APPROVAL, and the bound is a ceiling on the loss rather than a target:
    ///      the actual figure comes from the latch, and `approvedMaxLoss` only refuses to recognise
    ///      more than the proposal authorised.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param asset The asset under adjudication.
    /// @param expectedArmId The arm the caller believes is active.
    /// @param evidenceHash Must equal the arm's own committed hash.
    /// @param approvedMaxLoss Ceiling on the 18-decimal loss this act may recognise.
    /// @return incidentId The cascade-facing id for this recognition.
    /// @return actualLoss The 18-decimal loss actually recognised.
    function ratify(
        ReserveStorageLib.ReserveStorage storage $,
        address asset,
        uint256 expectedArmId,
        bytes32 evidenceHash,
        uint256 approvedMaxLoss
    ) public returns (uint256 incidentId, uint256 actualLoss) {
        uint256 armId = requireActiveArm($, asset, expectedArmId);
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        if (a.state == IReserveManager.ArmState.None || a.state == IReserveManager.ArmState.Finalized) {
            revert IReserveManager.ReserveManager_ArmStateInvalid(armId, a.state);
        }
        if (evidenceHash != a.evidenceHash) {
            revert IReserveManager.ReserveManager_ArmEvidenceMismatch(a.evidenceHash, evidenceHash);
        }
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        uint256 shortfallUnits = r.custodyShortfallUnits;
        shortfallUnits += $.reconcileCustody(asset);
        if (shortfallUnits == 0) revert IReserveManager.ReserveManager_ShortfallCured();
        actualLoss = shortfallUnits * r.scale;
        if (actualLoss > approvedMaxLoss) {
            revert IReserveManager.ReserveManager_LossExceedsApproval(actualLoss, approvedMaxLoss);
        }
        incidentId = LossEventIds.custodyEventId(armId);
        a.recoveryCapacityUnits += shortfallUnits;
        $.armUnappliedCustodyLossUnits[armId] += $.pendingUnappliedCustodyLossUnits[asset];
        $.pendingUnappliedCustodyLossUnits[asset] = 0;
        a.state = IReserveManager.ArmState.Ratified;
        r.custodyShortfallUnits = 0;
        $.totalCustodyShortfallValue -= actualLoss;
        ReserveCascadeLib.recognizeAndAbsorb($, incidentId, actualLoss);
        emit IReserveManager.IdleUnitsWrittenDown(asset, actualLoss, r.units * r.scale);
        emit IReserveManager.ReserveLossRatified(armId, asset, incidentId, approvedMaxLoss, actualLoss, evidenceHash);
    }

    /// @notice Credits tokens that came back after a ratified loss, up to what that loss recognised.
    /// @dev THE ASSET IS READ FROM THE ARM RECORD and never supplied by the caller, so a recovery
    ///      cannot be credited against the wrong asset's tally.
    ///
    ///      MEASURED, AND DOUBLY BOUNDED. `availableRecoveredUnits` credits only the SURPLUS the
    ///      proxy physically holds over recorded custody (`units + deferredUnits - unappliedLoss`),
    ///      and never more than the arm's remaining recovery capacity. So a recovery cannot be conjured from
    ///      an accounting entry, and it can never restore more than was written down. That is
    ///      ADR-0025's "up only on proof", with the proof being tokens actually in custody.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param armId The arm the recovery belongs to.
    /// @param evidenceHash Commitment to the recovery record.
    /// @return credited 18-decimal value credited back into backing.
    function creditRecovered(ReserveStorageLib.ReserveStorage storage $, uint256 armId, bytes32 evidenceHash)
        public
        returns (uint256 credited)
    {
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        if (a.state == IReserveManager.ArmState.None) revert IReserveManager.ReserveManager_NoActiveArm();
        uint256 units = availableRecoveredUnits($, armId);
        if (units == 0) revert IReserveManager.ReserveManager_NoRecoveredUnits(armId);
        address asset = a.asset;
        a.recoveryCapacityUnits -= units;
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        credited = units * r.scale;
        uint256 unapplied = $.armUnappliedCustodyLossUnits[armId];
        $.armUnappliedCustodyLossUnits[armId] = unapplied - $.restoreCustody(asset, units, unapplied);
        emit IReserveManager.RecoveredIdleUnitsCredited(armId, asset, units, credited, evidenceHash);
    }

    /// @notice Closes a ratified arm once nothing is outstanding.
    /// @dev Requires cleared supply reduction, latch and reserve deficit, no uncredited recovery,
    ///      and live custody covering both recorded custody net of known losses and all deferred
    ///      obligations. This catches a further unrecorded loss and an unfunded deferred claim.
    ///      A historical unapplied deduction may remain after closure; late recovery stays bound
    ///      to this arm's remaining recovery capacity.
    ///
    ///      IT DISABLES FUTURE GUARDIAN ARMS GLOBALLY rather than per asset. The guardian-arm
    ///      privilege is one privilege, and that is the accepted cost of the arm state machine:
    ///      re-enabling is a `DEFAULT_ADMIN_ROLE` act through `setGuardianReserveLossArmsEnabled`.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param asset The asset whose arm is being closed.
    /// @param expectedArmId The arm the caller believes is active.
    /// @param evidenceHash Commitment to the finalization record.
    function finalize(
        ReserveStorageLib.ReserveStorage storage $,
        address asset,
        uint256 expectedArmId,
        bytes32 evidenceHash
    ) public {
        uint256 armId = requireActiveArm($, asset, expectedArmId);
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        if (a.state != IReserveManager.ArmState.Ratified) {
            revert IReserveManager.ReserveManager_ArmStateInvalid(armId, a.state);
        }
        if ($.recognizedSupplyReduction != 0) {
            revert IReserveManager.ReserveManager_RecognizedLossOutstanding($.recognizedSupplyReduction);
        }
        uint256 latched = $.assets[asset].custodyShortfallUnits;
        if (latched != 0) revert IReserveManager.ReserveManager_LiveShortfallExists(latched);
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        uint256 owed = ReserveStorageLib.custodiedUnits(r);
        if (owed < r.deferredUnits) owed = r.deferredUnits;
        uint256 live = IERC20(asset).balanceOf(address(this));
        if (live < owed) revert IReserveManager.ReserveManager_LiveShortfallExists(owed - live);
        uint256 availableRecovery = availableRecoveredUnits($, armId);
        if (availableRecovery != 0) {
            revert IReserveManager.ReserveManager_RecoveredUnitsNotCredited(armId, availableRecovery);
        }
        uint256 recordedDeficit = ReserveCascadeLib.requireDeficitCured($);
        if (recordedDeficit != 0) {
            $.reserveDeficit = 0;
            emit IReserveManager.ReserveDeficitResolved(recordedDeficit, evidenceHash);
        }
        closeArm($, a, asset);
        emit IReserveManager.ReserveLossArmFinalized(armId, asset, LossEventIds.custodyEventId(armId), evidenceHash);
    }

    /// @dev THREE CHECKS, NOT ONE. There must BE an active arm for the asset; it must be the arm the
    ///      caller named; and the arm's own recorded asset must be the asset passed in. The third
    ///      looks redundant against `activeArmOf` and is not - it is what makes the two indexes prove
    ///      each other rather than one being trusted.
    function requireActiveArm(ReserveStorageLib.ReserveStorage storage $, address asset, uint256 expectedArmId)
        internal
        view
        returns (uint256 armId)
    {
        armId = $.activeArmOf[asset];
        if (armId == 0) revert IReserveManager.ReserveManager_NoActiveArm();
        if (expectedArmId != armId) revert IReserveManager.ReserveManager_ArmMismatch(armId, expectedArmId);
        address armAsset = $.arms[armId].asset;
        if (armAsset != asset) revert IReserveManager.ReserveManager_ArmAssetMismatch(armId, armAsset, asset);
    }

    /// @dev The single writer of arm closure, shared by `cancel` and `finalize` so the two cannot
    ///      drift. Closing always disarms the guardian privilege, which is why it is here rather
    ///      than duplicated at both call sites.
    function closeArm(ReserveStorageLib.ReserveStorage storage $, ReserveStorageLib.LossArm storage a, address asset)
        internal
    {
        a.state = IReserveManager.ArmState.Finalized;
        $.activeArmOf[asset] = 0;
        $.openArmCount -= 1;
        if ($.guardianReserveLossArmsEnabled) {
            $.guardianReserveLossArmsEnabled = false;
            emit IReserveManager.GuardianReserveLossArmsEnabled(false);
        }
    }

    /// @dev The interlock: nothing recognised, no deficit, no standing shortfall, and a controller
    ///      that reports supply at or below backing. A missing controller is treated as FORBIDDEN
    ///      rather than as permission, because an unwired loss controller cannot attest to solvency
    ///      and fail-open here would release the interlock in exactly the misconfiguration where it
    ///      matters most.
    function requireInterlockReleasable(ReserveStorageLib.ReserveStorage storage $) internal view {
        if ($.recognizedSupplyReduction != 0 || $.reserveDeficit != 0 || $.totalCustodyShortfallValue != 0) {
            revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        }
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0) || controller.totalUSDfr() > controller.backingValue()) {
            revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        }
    }

    /// @dev A recovery requires delivered tokens above recorded custody net of every known loss.
    ///      The arm-specific ceiling also applies to a closed arm's late recovery. Crediting one
    ///      arm raises recorded custody, so the same tokens cannot be credited to another arm.
    function availableRecoveredUnits(ReserveStorageLib.ReserveStorage storage $, uint256 armId)
        internal
        view
        returns (uint256)
    {
        ReserveStorageLib.LossArm storage a = $.arms[armId];
        uint256 capacity = a.recoveryCapacityUnits;
        if (capacity == 0) return 0;
        address asset = a.asset;
        ReserveStorageLib.ReserveAsset storage r = $.assets[asset];
        uint256 owed = ReserveStorageLib.custodiedUnits(r);
        uint256 live = IERC20(asset).balanceOf(address(this));
        if (live <= owed) return 0;
        uint256 surplus = live - owed;
        return surplus < capacity ? surplus : capacity;
    }
}
