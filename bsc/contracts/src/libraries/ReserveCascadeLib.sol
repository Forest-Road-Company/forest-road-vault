// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveLossAbsorber} from "../interfaces/IReserveLossAbsorber.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {LossEventIds} from "./LossEventIds.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveCascadeLib - custody-loss recognition, two-layer absorption, and principal marks
/// @notice ADR-0037 D3a(ii): this instance has NO cascade layer two. A ratified custody loss runs
///         curator first-loss, then senior principal, and until first-loss is posted it runs
///         straight to senior principal. That must appear on the disclosure surface in those words.
/// @dev CASCADE ORDER IS STILL A THEOREM, and with layer two gone it must be restated rather than
///      assumed. `residual` is layer 1's SECOND return value; `absorbGlobalLoss` clamps its first
///      return to the curator pools' total; therefore a non-zero residual means the curator pools
///      are exhausted; therefore senior principal is charged only what layer 1 declined. Senior is
///      never subordinated to junior, and the ordering cannot be inverted because the senior charge
///      is computed from a number layer 1 produced.
///
///      EIP-170: `recognizeAndAbsorb` is a `public` library function, deployed separately and
///      reached by `delegatecall`. Role checks and `nonReentrant` stay in the PROXY-SIDE function.
library ReserveCascadeLib {
    /// @notice Preserves the native authenticated exit-prepayment ledger transition.
    function recordExitPrepayment(uint256 amount) public {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (msg.sender != address($.lossAbsorber)) revert IReserveManager.ReserveManager_NotLossAbsorber(msg.sender);
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        uint256 outstanding = $.exitPrepaidAbsorption + amount;
        $.exitPrepaidAbsorption = outstanding;
        emit IReserveManager.ExitPrepaymentRecorded(amount, outstanding);
    }

    /// @notice Preserves the native authenticated exit-prepayment ledger transition.
    function consumeExitPrepayment(uint256 facilityId, uint256 loss) public returns (uint256 used) {
        ReserveStorageLib.ReserveStorage storage $ = ReserveStorageLib.layout();
        if (msg.sender != address($.lossAbsorber)) revert IReserveManager.ReserveManager_NotLossAbsorber(msg.sender);
        uint256 prepaid = $.exitPrepaidAbsorption;
        if (prepaid == 0) return 0;
        uint256 releasable = $.principalImpairment[facilityId];
        if (releasable > loss) releasable = loss;
        used = prepaid < releasable ? prepaid : releasable;
        if (used == 0) return 0;
        uint256 outstanding = prepaid - used;
        $.exitPrepaidAbsorption = outstanding;
        emit IReserveManager.ExitPrepaymentConsumed(facilityId, used, outstanding);
    }

    /// @notice Records an evidence-backed conservative mark on one facility's principal.
    /// @dev A VALUATION transition, not a cascade transition: it moves no value and burns no
    ///      claims. Keeping the two separate is what ensures an honest conservative mark is never
    ///      conditional on the loss layers having enough immediately burnable capital.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility being marked.
    /// @param amount The 18-decimal mark to add.
    /// @param evidenceHash Commitment to the assessment record; may not be zero.
    function recognizeImpairment(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        uint256 amount,
        bytes32 evidenceHash
    ) public {
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        if (evidenceHash == bytes32(0)) revert IReserveManager.ReserveManager_ZeroEvidenceHash();
        uint256 recognized = $.principalImpairment[facilityId];
        uint256 face = $.deployed[facilityId];
        if (amount > face - recognized) {
            revert IReserveManager.ReserveManager_ImpairmentExceedsFace(facilityId, amount, face - recognized);
        }
        uint256 facilityImpairment = recognized + amount;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment + amount;
        $.totalPrincipalImpairment = total;
        emit IReserveManager.PrincipalImpairmentRecognized(
            facilityId, amount, facilityImpairment, total, ReserveStorageLib.backingValue($), evidenceHash
        );
    }

    /// @notice Reverses a conservative mark, bounded by the amount previously recognized.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility being un-marked.
    /// @param amount The 18-decimal mark to release.
    /// @param evidenceHash Commitment to the assessment record; may not be zero.
    function releaseImpairment(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        uint256 amount,
        bytes32 evidenceHash
    ) public {
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        if (evidenceHash == bytes32(0)) revert IReserveManager.ReserveManager_ZeroEvidenceHash();
        uint256 recognized = $.principalImpairment[facilityId];
        if (amount > recognized) {
            revert IReserveManager.ReserveManager_ImpairmentReleaseExceedsRecognized(facilityId, amount, recognized);
        }
        uint256 facilityImpairment = recognized - amount;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment - amount;
        $.totalPrincipalImpairment = total;
        emit IReserveManager.PrincipalImpairmentReleased(facilityId, amount, facilityImpairment, total, evidenceHash);
    }

    /// @notice Removes realized facility principal and consumes its corresponding mark.
    /// @dev A write-down is the REALIZATION of loss, so a mark already carried against that loss
    ///      must be consumed or the same dollar is counted once in face and again in valuation.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility.
    /// @param amount The 18-decimal principal removed.
    function writeDownPrincipal(ReserveStorageLib.ReserveStorage storage $, uint256 facilityId, uint256 amount)
        public
    {
        if (amount == 0) revert IReserveManager.ReserveManager_ZeroAmount();
        uint256 deployed = $.deployed[facilityId];
        if (amount > deployed) {
            revert IReserveManager.ReserveManager_InsufficientDeployedPrincipal(facilityId, amount, deployed);
        }
        $.deployed[facilityId] = deployed - amount;
        $.totalDeployedPrincipal -= amount;
        uint256 recognized = $.principalImpairment[facilityId];
        if (recognized != 0) {
            _consumeImpairment($, facilityId, recognized, amount < recognized ? amount : recognized);
        }
        emit IReserveManager.PrincipalWrittenDown(facilityId, amount);
    }

    /// @notice Releases only the mark the facility's smaller remaining face can no longer support.
    /// @dev H-1: cash collection is NOT evidence that a governance-adjudicated impairment
    ///      recovered. Treating every repayment dollar as recovery made backing depend on the order
    ///      of repayment and write-down, and could silently reopen par exits against a claim that
    ///      is still impaired. Only the arithmetically unavoidable excess is released.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param facilityId The facility.
    /// @param remainingFace The facility's face principal after the repayment.
    /// @dev `internal`, NOT `public`, for the same reason as `recognizeAndAbsorb`: its only caller is
    ///      `ReserveCreditLib.pay`, a library, and a public library-to-library call leaves a
    ///      placeholder halmos cannot link.
    function clampImpairment(ReserveStorageLib.ReserveStorage storage $, uint256 facilityId, uint256 remainingFace)
        internal
    {
        uint256 recognized = $.principalImpairment[facilityId];
        if (recognized <= remainingFace) return;
        _consumeImpairment($, facilityId, recognized, recognized - remainingFace);
    }

    /// @notice Clears a cured reserve-deficit latch with supporting evidence.
    /// @dev Refuses while any arm is open, and refuses unless the live supply/backing reading
    ///      actually shows the deficit cured. The latch is a record of a hole the cascade could not
    ///      fill; clearing it on authority alone would erase that record.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param evidenceHash Commitment to the resolution record.
    function resolveDeficit(ReserveStorageLib.ReserveStorage storage $, bytes32 evidenceHash) public {
        uint256 recordedDeficit = $.reserveDeficit;
        if (recordedDeficit == 0) revert IReserveManager.ReserveManager_NoReserveDeficit();
        if ($.openArmCount != 0) revert IReserveManager.ReserveManager_InterlockReleaseForbidden();
        requireDeficitCured($);
        $.reserveDeficit = 0;
        emit IReserveManager.ReserveDeficitResolved(recordedDeficit, evidenceHash);
    }

    /// @dev Fails closed on an absent controller and on any live supply-over-backing deficit.
    function requireDeficitCured(ReserveStorageLib.ReserveStorage storage $)
        internal
        view
        returns (uint256 recordedDeficit)
    {
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) {
            revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        }
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        recordedDeficit = $.reserveDeficit;
        if (supply > backing) {
            revert IReserveManager.ReserveManager_DeficitStillExists(recordedDeficit, supply - backing);
        }
    }

    function _consumeImpairment(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 facilityId,
        uint256 recognized,
        uint256 consumed
    ) private {
        uint256 facilityImpairment = recognized - consumed;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment - consumed;
        $.totalPrincipalImpairment = total;
        emit IReserveManager.PrincipalImpairmentRealized(facilityId, consumed, facilityImpairment, total);
    }

    /// @notice Recognizes a custody loss against backing and absorbs the resulting supply hole.
    /// @dev Recognition NO LONGER debits a tally: `reconcileIdleUnits` already lowered it when the
    ///      shortfall was latched, so this reconstructs the pre-loss level from the controller's
    ///      live reading plus the amount being recognized, exactly as the absorption step already
    ///      did. Debiting again here would charge the same dollar twice.
    /// @param $ The reserve's ERC-7201 storage.
    /// @param incidentId The arm's derived upper-namespace custody event id.
    /// @param backingReduction The 18-decimal value of the ratified shortfall.
    /// @dev `internal`, NOT `public`, and the visibility is load-bearing (2026-09-08). Its only
    ///      caller is `ReserveArmLib.ratify`, which is itself a library. A `public` library function
    ///      called from another library leaves an UNLINKED PLACEHOLDER in the calling library's
    ///      bytecode, and halmos cannot resolve library-to-library placeholders: it fails `setUp()`
    ///      with "contract hexcode contains library placeholder" and every symbolic property in
    ///      `BackingSymbolic` reports as failed. Making it `internal` inlines it into the one caller,
    ///      costs `ReserveManager` nothing (it does not call this), and keeps the 26 proofs. If a
    ///      second caller ever appears, weigh the duplicated bytes against that.
    function recognizeAndAbsorb(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 incidentId,
        uint256 backingReduction
    ) internal {
        _recognize($, incidentId, backingReduction);
        if ($.recognizedSupplyReduction != 0) _absorb($, incidentId);
    }

    /// @dev Retires only credit whose surplus backing this custody loss consumed. Surplus
    ///      beyond the prepaid balance absorbs loss first. Retired credit cannot offset a later
    ///      facility loss after the capital supporting it has already been spent.
    function _retireCustodyPrepayment(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 incidentId,
        uint256 surplusBefore,
        uint256 surplusAbsorbed
    ) private {
        uint256 prepaid = $.exitPrepaidAbsorption;
        uint256 freeSurplus = surplusBefore > prepaid ? surplusBefore - prepaid : 0;
        if (surplusAbsorbed <= freeSurplus) return;
        uint256 used = surplusAbsorbed - freeSurplus;
        uint256 outstanding = prepaid - used;
        $.exitPrepaidAbsorption = outstanding;
        emit IReserveManager.ExitPrepaymentAbsorbedByCustody(incidentId, used, outstanding);
    }

    function _recognize(ReserveStorageLib.ReserveStorage storage $, uint256 incidentId, uint256 backingReduction)
        private
    {
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) {
            revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        }
        uint256 supplyBefore = controller.totalUSDfr();

        // THE CASCADE DOES NOT TAKE THE LOSS CONTROLLER'S WORD FOR THE ONE NUMBER THAT DECIDES
        // WHETHER LOSSES ARE BORNE AT ALL. Restored 2026-09-08; the Ethereum instance refuses the
        // same class of inconsistency at `ReserveCascadeLib._recognize` and this rewrite
        // dropped it, which left the reconstruction below trusting an unchecked figure.
        //
        // WHY A MISREPORT IS NOT MERELY WRONG BUT SILENT. `backingBeforeLoss` adds
        // `backingReduction` back, so an UNDER-reported backing manufactures a surplus of exactly
        // the loss being recognised: `surplusAbsorbed` then equals the whole loss,
        // `supplyReductionRequired` is zero, and the cascade never runs. No curator draw, no senior
        // burn, no deficit latched, while this reserve's own tally has already fallen. Supply then
        // exceeds backing with every loss ledger reading zero.
        //
        // WHY EQUALITY IS THE RIGHT TEST AND NOT A TOLERANCE. `MintRedeemController.backingValue()`
        // is a pass-through to this reserve's `totalBackingValue()`, which is
        // `ReserveStorageLib.backingValue($)` verbatim. In every honest state the two are THE SAME
        // NUMBER read twice, not two estimates that might drift. Any divergence at all means the
        // configured loss controller is not reporting this reserve's books, and that is a stop.
        uint256 reportedBacking = controller.backingValue();
        uint256 ownBacking = ReserveStorageLib.backingValue($);
        if (reportedBacking != ownBacking) {
            revert IReserveManager.ReserveManager_LossAllocationMismatch(
                ownBacking, reportedBacking, backingReduction, supplyBefore
            );
        }

        uint256 backingBeforeLoss = reportedBacking + backingReduction;

        uint256 surplusBefore = backingBeforeLoss > supplyBefore ? backingBeforeLoss - supplyBefore : 0;
        uint256 surplusAbsorbed = backingReduction < surplusBefore ? backingReduction : surplusBefore;
        uint256 supplyReductionRequired = backingReduction - surplusAbsorbed;
        _retireCustodyPrepayment($, incidentId, surplusBefore, surplusAbsorbed);

        emit IReserveManager.ReserveLossRecognized(
            incidentId, backingReduction, surplusAbsorbed, supplyReductionRequired
        );

        if (supplyReductionRequired == 0) {
            IReserveLossAbsorber.ReserveLossAllocation memory allocation;
            allocation.surplusAbsorbed = surplusAbsorbed;
            _emitAllocated(incidentId, backingReduction, allocation);
            return;
        }
        $.recognizedBackingReduction += backingReduction;
        $.recognizedSurplusAbsorbed += surplusAbsorbed;
        $.recognizedSupplyReduction += supplyReductionRequired;
    }

    function _absorb(ReserveStorageLib.ReserveStorage storage $, uint256 incidentId) private {
        if (!LossEventIds.isCustodyEvent(incidentId)) {
            revert IReserveManager.ReserveManager_InvalidReserveLossIncident(incidentId);
        }
        uint256 requiredSupplyReduction = $.recognizedSupplyReduction;
        if (requiredSupplyReduction == 0) revert IReserveManager.ReserveManager_NoRecognizedReserveLoss();
        IMintRedeemController controller = $.lossController;
        // The backstop limb of this guard is deleted: it was the only one that could never be
        // satisfied on this instance, and leaving it would brick the whole custody cascade on the
        // first ratified loss. The three surviving limbs stay fail-closed.
        if (
            address($.lossCurator) == address(0) || address($.lossVault) == address(0)
                || address($.lossUSDfr) == address(0)
        ) revert IReserveManager.ReserveManager_InvalidLossAbsorber(address(0));
        if (address(controller) == address(0)) {
            revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        }

        $.lossVault.accrueFees();
        uint256 supplyBefore = controller.totalUSDfr();
        // Recognition has already lowered backing by `recognizedBackingReduction`. Reconstruct the
        // pre-loss level so the standing valuation hole and any previously latched cascade residual
        // are carried through the new delta rather than charged or latched twice.
        uint256 backingBeforeLoss = controller.backingValue() + $.recognizedBackingReduction;
        uint256 deficitBefore = supplyBefore > backingBeforeLoss ? supplyBefore - backingBeforeLoss : 0;
        IReserveLossAbsorber.ReserveLossAllocation memory allocation;
        uint256 residual;
        (allocation.curatorAbsorbed, residual) = _drawJunior($.lossCurator, $.lossUSDfr, requiredSupplyReduction);
        // allocation.backstopCovered stays zero by construction: there is no layer two to offer it.

        if (allocation.curatorAbsorbed != 0) controller.burnLoss(address(this), allocation.curatorAbsorbed);

        if (residual != 0) {
            uint256 vaultAssets = $.lossVault.totalAssets();
            allocation.seniorBurned = residual < vaultAssets ? residual : vaultAssets;
            if (allocation.seniorBurned != 0) {
                controller.burnLoss(address($.lossVault), allocation.seniorBurned);
                residual -= allocation.seniorBurned;
            }
        }
        allocation.residualDeficit = residual;
        allocation.surplusAbsorbed = $.recognizedSurplusAbsorbed;

        _finalize($, incidentId, requiredSupplyReduction, supplyBefore, deficitBefore, allocation);
    }

    function _finalize(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 incidentId,
        uint256 requiredSupplyReduction,
        uint256 supplyBefore,
        uint256 deficitBefore,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private {
        uint256 observedDeficit = _verify($, requiredSupplyReduction, supplyBefore, deficitBefore, allocation);
        uint256 backingReduction = $.recognizedBackingReduction;
        $.recognizedBackingReduction = 0;
        $.recognizedSurplusAbsorbed = 0;
        $.recognizedSupplyReduction = 0;

        // Only the portion of the pre-loss hole that was already a cascade residual is carried into
        // the latch. A standing valuation mark is an output/price constraint, not a new custody
        // shortfall; the current loss has already been offered unconditionally above.
        uint256 previousDeficit = $.reserveDeficit;
        uint256 carriedValuationDeficit = deficitBefore > previousDeficit ? deficitBefore - previousDeficit : 0;
        uint256 nextDeficit = observedDeficit - carriedValuationDeficit;
        if (nextDeficit != previousDeficit) {
            $.reserveDeficit = nextDeficit;
            emit IReserveManager.ReserveDeficitUpdated(incidentId, previousDeficit, nextDeficit);
        }
        _emitAllocated(incidentId, backingReduction, allocation);
    }

    function _verify(
        ReserveStorageLib.ReserveStorage storage $,
        uint256 requiredSupplyReduction,
        uint256 supplyBefore,
        uint256 deficitBefore,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private view returns (uint256 observedDeficit) {
        IMintRedeemController controller = $.lossController;
        uint256 supplyAfter = controller.totalUSDfr();
        // `backstopCovered` is a literal zero here, so every equality below is arithmetically
        // unchanged from the three-layer form and the tests that pin them carry over.
        uint256 reportedBurn = allocation.curatorAbsorbed + allocation.backstopCovered + allocation.seniorBurned;
        uint256 observedBurn = supplyAfter > supplyBefore ? 0 : supplyBefore - supplyAfter;
        if (reportedBurn > requiredSupplyReduction || observedBurn != reportedBurn) {
            revert IReserveManager.ReserveManager_LossAbsorberContractViolated(reportedBurn, observedBurn);
        }
        uint256 expectedAccounted = $.recognizedBackingReduction - $.recognizedSurplusAbsorbed;
        uint256 reportedAccounted = reportedBurn + allocation.residualDeficit;
        if (expectedAccounted != requiredSupplyReduction || reportedAccounted != expectedAccounted) {
            revert IReserveManager.ReserveManager_LossAllocationMismatch(
                $.recognizedSurplusAbsorbed, allocation.surplusAbsorbed, expectedAccounted, reportedAccounted
            );
        }
        uint256 backingAfter = controller.backingValue();
        observedDeficit = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
        uint256 expectedDeficit = deficitBefore + requiredSupplyReduction;
        expectedDeficit = expectedDeficit > reportedBurn ? expectedDeficit - reportedBurn : 0;
        if (observedDeficit != expectedDeficit) {
            revert IReserveManager.ReserveManager_PostLossDeficitMismatch(expectedDeficit, observedDeficit);
        }
    }

    /// @dev Layer 1 only. A residual is senior loss BY CONSTRUCTION: there is no layer two to offer
    ///      it to. The measured USDfr balance delta against layer 1 is retained unchanged; it is
    ///      ADR-0025's "up only on proof" rule applied to junior delivery, and it is what stops a
    ///      curator that reports an absorption it did not fund from shrinking the senior charge.
    function _drawJunior(ICuratorModule curator, IERC20 usdfr, uint256 requiredSupplyReduction)
        private
        returns (uint256 curatorAbsorbed, uint256 residual)
    {
        uint256 balanceBefore = usdfr.balanceOf(address(this));
        (curatorAbsorbed, residual) = curator.absorbGlobalLoss(requiredSupplyReduction);
        if (curatorAbsorbed > requiredSupplyReduction || residual != requiredSupplyReduction - curatorAbsorbed) {
            revert IReserveManager.ReserveManager_LossAllocationMismatch(
                0, 0, requiredSupplyReduction, curatorAbsorbed + residual
            );
        }
        uint256 balanceAfter = usdfr.balanceOf(address(this));
        uint256 received = balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore;
        if (received != curatorAbsorbed) {
            revert IReserveManager.ReserveManager_LossAbsorberContractViolated(curatorAbsorbed, received);
        }
    }

    function _emitAllocated(
        uint256 incidentId,
        uint256 backingReduction,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private {
        emit IReserveManager.ReserveLossAllocated(
            incidentId,
            backingReduction,
            allocation.surplusAbsorbed,
            allocation.curatorAbsorbed,
            allocation.backstopCovered,
            allocation.seniorBurned,
            allocation.residualDeficit
        );
    }
}
