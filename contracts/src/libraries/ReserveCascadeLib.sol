// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReserveManager} from "../ReserveManager.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IReserveLossAbsorber} from "../interfaces/IReserveLossAbsorber.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {ICascadeBackstop} from "../interfaces/ICascadeBackstop.sol";
import {LossEventIds} from "./LossEventIds.sol";

/// @title ReserveCascadeLib
/// @notice Ethereum's native custody-loss accounting, separated to leave room for continuous accrual.
/// @dev No storage is declared or located here. ReserveManager passes its original live namespace
///      pointer and retains all external authorization, arm/evidence and reentrancy checks. The
///      curator -> sGROVE -> senior order and the existing surplus/residual accounting are retained.
library ReserveCascadeLib {
    /// @notice Records a custody loss against the exact native reserve state.
    /// @dev The host authenticates the arm, evidence, loss approval and reentrancy guard.
    function recognize(ReserveManager.ReserveStorage storage $, uint256 nativeUnits, uint256 backingReduction) public {
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) revert IReserveManager.ReserveManager_InvalidLossController(address(0));
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 backingBefore = controller.backingValue();
        if (backingReduction > backingBefore) {
            revert IReserveManager.ReserveManager_LossAllocationMismatch(0, 0, backingReduction, backingBefore);
        }

        uint256 surplusBefore = backingBefore > supplyBefore ? backingBefore - supplyBefore : 0;
        uint256 surplusAbsorbed = backingReduction < surplusBefore ? backingReduction : surplusBefore;
        uint256 supplyReductionRequired = backingReduction - surplusAbsorbed;
        _retireCustodyPrepayment($, $.activeReserveLossIncidentId, surplusBefore, surplusAbsorbed);

        // Recognition lowers backing first. Every subsequent burn is checked as a precise,
        // non-worsening reduction of the now-visible deficit by MintRedeemController.
        $.idleUSDCUnits -= nativeUnits;
        emit IReserveManager.ReserveLossRecognized(
            $.activeReserveLossIncidentId, backingReduction, surplusAbsorbed, supplyReductionRequired
        );

        if (supplyReductionRequired == 0) {
            IReserveLossAbsorber.ReserveLossAllocation memory allocation;
            allocation.surplusAbsorbed = surplusAbsorbed;
            _emitReserveLossAllocated($.activeReserveLossIncidentId, backingReduction, allocation);
            return;
        }
        $.recognizedBackingReduction += backingReduction;
        $.recognizedSurplusAbsorbed += surplusAbsorbed;
        $.recognizedSupplyReduction += supplyReductionRequired;
    }

    /// @dev Retires only credit whose surplus backing this custody loss consumed. Surplus
    ///      beyond the prepaid balance absorbs loss first. Retired credit cannot offset a later
    ///      facility loss after the capital supporting it has already been spent.
    function _retireCustodyPrepayment(
        ReserveManager.ReserveStorage storage $,
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

    /// @notice Allocates the recognized loss through curator, sGROVE and senior assets.
    /// @dev Executes in the reserve context; every transfer and supply/backing delta remains proved.
    function absorb(ReserveManager.ReserveStorage storage $, uint256 incidentId) public {
        if (!LossEventIds.isCustodyEvent(incidentId)) {
            revert IReserveManager.ReserveManager_InvalidReserveLossIncident(incidentId);
        }
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) revert IReserveManager.ReserveManager_NoActiveIncident();
        if (incidentId != active) revert IReserveManager.ReserveManager_IncidentMismatch(active, incidentId);

        uint256 requiredSupplyReduction = $.recognizedSupplyReduction;
        if (requiredSupplyReduction == 0) revert IReserveManager.ReserveManager_NoRecognizedReserveLoss();
        IMintRedeemController controller = $.lossController;
        if (
            address($.lossCurator) == address(0) || address($.lossBackstop) == address(0)
                || address($.lossVault) == address(0) || address($.lossUSDfr) == address(0)
        ) revert IReserveManager.ReserveManager_InvalidLossAbsorber(address(0));
        if (address(controller) == address(0)) revert IReserveManager.ReserveManager_InvalidLossController(address(0));

        $.lossVault.accrueFees();
        uint256 supplyBefore = controller.totalUSDfr();
        // Recognition has already lowered backing by `recognizedBackingReduction`. Reconstruct
        // the pre-loss level so the standing valuation hole and any previously latched cascade
        // residual are carried through the new delta rather than charged or latched twice.
        uint256 backingAfterRecognition = controller.backingValue();
        uint256 backingBeforeLoss = backingAfterRecognition + $.recognizedBackingReduction;
        uint256 deficitBefore = supplyBefore > backingBeforeLoss ? supplyBefore - backingBeforeLoss : 0;
        IReserveLossAbsorber.ReserveLossAllocation memory allocation;
        uint256 residual;
        (allocation.curatorAbsorbed, allocation.backstopCovered, residual) =
            _drawJuniorReserveLoss($.lossCurator, $.lossBackstop, $.lossUSDfr, incidentId, requiredSupplyReduction);

        uint256 juniorBurn = allocation.curatorAbsorbed + allocation.backstopCovered;
        if (juniorBurn != 0) controller.burnLoss(address(this), juniorBurn);

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

        _finalizeReserveLoss($, incidentId, requiredSupplyReduction, supplyBefore, deficitBefore, allocation);
    }

    function _finalizeReserveLoss(
        ReserveManager.ReserveStorage storage $,
        uint256 incidentId,
        uint256 requiredSupplyReduction,
        uint256 supplyBefore,
        uint256 deficitBefore,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private {
        uint256 observedDeficit =
            _verifyReserveLoss($, requiredSupplyReduction, supplyBefore, deficitBefore, allocation);
        uint256 backingReduction = $.recognizedBackingReduction;
        $.recognizedBackingReduction = 0;
        $.recognizedSurplusAbsorbed = 0;
        $.recognizedSupplyReduction = 0;

        // Only the portion of the pre-loss hole that was already a cascade residual is carried
        // into the latch. A standing valuation mark is an output/price constraint, not a new
        // custody shortfall; the current loss has already been offered unconditionally above.
        uint256 previousDeficit = $.reserveDeficit;
        uint256 carriedValuationDeficit = deficitBefore > previousDeficit ? deficitBefore - previousDeficit : 0;
        uint256 nextDeficit = observedDeficit - carriedValuationDeficit;
        if (nextDeficit != previousDeficit) {
            $.reserveDeficit = nextDeficit;
            emit IReserveManager.ReserveDeficitUpdated(incidentId, previousDeficit, nextDeficit);
        }
        _emitReserveLossAllocated(incidentId, backingReduction, allocation);
    }

    function _verifyReserveLoss(
        ReserveManager.ReserveStorage storage $,
        uint256 requiredSupplyReduction,
        uint256 supplyBefore,
        uint256 deficitBefore,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private view returns (uint256 observedDeficit) {
        IMintRedeemController controller = $.lossController;
        uint256 supplyAfter = controller.totalUSDfr();
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

    function _drawJuniorReserveLoss(
        ICuratorModule curator,
        ICascadeBackstop backstop,
        IERC20 usdfr,
        uint256 incidentId,
        uint256 requiredSupplyReduction
    ) private returns (uint256 curatorAbsorbed, uint256 backstopCovered, uint256 residual) {
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

        if (residual != 0) {
            balanceBefore = balanceAfter;
            backstopCovered = backstop.coverShortfall(incidentId, residual);
            balanceAfter = usdfr.balanceOf(address(this));
            received = balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore;
            if (backstopCovered > residual || received != backstopCovered) {
                revert IReserveManager.ReserveManager_LossAbsorberContractViolated(backstopCovered, received);
            }
            residual -= backstopCovered;
        }
    }

    function _emitReserveLossAllocated(
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
