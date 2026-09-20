// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";
import {IAccrualRoundingRisk, IAccrualRoundingRegistry} from "../interfaces/IAccrualLifecycle.sol";
import {AccrualBook} from "./AccrualBook.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {AccrualSegments} from "./AccrualSegments.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {ReserveAccrualLib} from "./ReserveAccrualLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";
import {ReserveCascadeLib} from "./ReserveCascadeLib.sol";

/// @title ReserveRoundingLib
/// @notice Allocates a proved sub-native-unit contractual discrepancy through BSC's native loss order.
/// @dev Gross earned income and both earned fee claims are retained. This library owns no independent
///      write-off authority: the reserve supplies its just-derived, nonce-bound lifecycle work.
library ReserveRoundingLib {
    using AccrualBook for AccrualBook.Book;
    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;

    error AccrualRounding_InvalidContinuation();
    error AccrualRounding_DeltaMismatch(uint8 measurement, uint256 expected, uint256 actual);
    error AccrualRounding_InsufficientGas();

    /// @notice The exact discrepancy, its native loss allocation, and the explicitly unabsorbed remainder.
    event AccrualRoundingAllocated(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint256 amount,
        uint256 prepaid,
        uint256 curator,
        uint256 senior,
        uint256 unabsorbed,
        uint256 markConsumed
    );

    /// @notice Reconciles interpolation and delivers the vault's pre-loss claims before closing the loan.
    /// @dev Preparation exposes a coherent pre-loss book; the reserve's outer operation guard remains
    ///      held. No receipt, basis change, face write-down or burn has occurred during these callbacks.
    ///      A separate fee recipient retains its earned claim for permissionless delivery. Its transfer
    ///      restrictions must not block repayment or senior loss allocation. If the vault also owns
    ///      the fee claim, both legs must be physical before its assets can fund a loss.
    function prepare(uint256 id) public {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        AccrualLoans.Loan storage loan = s.loans.loans[id];
        if (loan.terms.scale == 1 || !s.loans.book.entries[id].scheduled) return;
        uint64 at = ReserveAccrualStorageLib.now64();
        s.loans.book.reconcile(id, at);
        uint256 recognized = s.loans.book.earned(id, at) - loan.segmentBookBase;
        uint256 canonical = AccrualSegments.cumulative(loan.terms, at) - loan.segmentCumulativeStart;
        if (recognized <= canonical) return;
        ReserveAccrualLib.prepareNativeLoss();
        IsUSDfr(s.modules.vault).accrueFees();
    }

    /// @notice Consumes one armed burn; all unrelated controller operations retain the busy gate.
    function consumeBurn(address caller, address from, uint256 amount) public returns (bool) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (msg.sender != s.modules.controller) revert AccrualRounding_InvalidContinuation();
        ReserveAccrualStorageLib.Rounding storage r = s.rounding;
        if (!r.active) return false;
        if (
            !s.busy || s.delivery.active || !r.ready || caller != address(this) || from != r.from || amount != r.amount
                || amount == 0
        ) revert AccrualRounding_InvalidContinuation();
        r.ready = false;
        return true;
    }

    /// @notice Uses prepaid marks, this facility's curator class, then clamped senior assets.
    function allocate(AccrualLoans.LifecycleWork memory work) public {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        uint256 loss = work.roundingLoss;
        AccrualLoans.Loan storage loan = s.loans.loans[work.facilityId];
        if (
            !s.busy || s.delivery.active || s.rounding.active || loss == 0 || loss >= loan.terms.scale
                || work.closureNonce != loan.closureNonce || _unissuedVaultAssets(s, work.at) != 0
        ) revert AccrualRounding_InvalidContinuation();
        ReserveStorageLib.ReserveStorage storage native = ReserveStorageLib.layout();
        uint256[5] memory before_ = _measure(s, native);
        uint256 mark = native.principalImpairment[work.facilityId];
        if (mark > loss) mark = loss;
        uint256 prepaid = native.exitPrepaidAbsorption;
        if (prepaid > mark) prepaid = mark;
        if (prepaid != 0) {
            native.exitPrepaidAbsorption -= prepaid;
            emit IReserveManager.ExitPrepaymentConsumed(work.facilityId, prepaid, native.exitPrepaidAbsorption);
        }
        s.rounding.facilityId = work.facilityId;
        s.rounding.closureNonce = work.closureNonce;
        s.rounding.active = true;
        uint256 junior = _curator(s, native, work.facilityId, loss - prepaid);
        if (junior != 0) _burn(s, address(this), junior);
        uint256 senior = loss - prepaid - junior;
        uint256 available = IsUSDfr(s.modules.vault).totalAssets();
        if (senior > available) senior = available;
        if (senior != 0) _burn(s, s.modules.vault, senior);
        uint256 unabsorbed = loss - prepaid - junior - senior;
        s.roundingUnabsorbed += unabsorbed;
        ReserveCascadeLib.writeDownPrincipal(native, work.facilityId, loss);
        s.recordedFace -= loss;
        _notify(s, work.facilityId, loss);
        uint256[5] memory after_ = _measure(s, native);
        _equal(0, before_[0] - junior - senior, after_[0]);
        _equal(1, before_[1], after_[1]);
        _equal(2, before_[2] - senior, after_[2]);
        uint256 reduction = loss - mark;
        _equal(3, before_[3] > reduction ? before_[3] - reduction : 0, after_[3]);
        _equal(7, before_[4], after_[4]); // Outstanding fee claims are neither canceled nor spent.
        delete s.rounding;
        emit AccrualRoundingAllocated(
            work.facilityId, work.closureNonce, loss, prepaid, junior, senior, unabsorbed, mark
        );
    }

    function _curator(
        ReserveAccrualStorageLib.State storage s,
        ReserveStorageLib.ReserveStorage storage native,
        uint256 id,
        uint256 loss
    ) private returns (uint256 absorbed) {
        if (loss == 0) return 0;
        uint256 classId = s.identities[id].classId;
        ICuratorModule curator = native.lossCurator;
        uint256 expected = curator.poolBalance(classId);
        if (expected > loss) expected = loss;
        uint256 before_ = IERC20(s.modules.token).balanceOf(address(this));
        uint256 residual;
        (absorbed, residual) = curator.absorbLoss{gas: _forwardGas()}(classId, loss);
        _equal(4, expected, absorbed);
        _equal(5, loss - absorbed, residual);
        _equal(6, before_ + absorbed, IERC20(s.modules.token).balanceOf(address(this)));
    }

    function _burn(ReserveAccrualStorageLib.State storage s, address from, uint256 amount) private {
        s.rounding.from = from;
        s.rounding.amount = amount;
        s.rounding.ready = true;
        IMintRedeemController(s.modules.controller).burnLoss{gas: _forwardGas()}(from, amount);
        if (s.rounding.ready) revert AccrualRounding_InvalidContinuation();
    }

    function _notify(ReserveAccrualStorageLib.State storage s, uint256 id, uint256 amount) private {
        ReserveAccrualStorageLib.Identity storage identity = s.identities[id];
        IAccrualRoundingRegistry(s.modules.registry).recordAccruedWriteDown(
            identity.classId, identity.borrowerId, identity.stateId, amount
        );
        IAccrualRoundingRisk(s.modules.defaultManager).onAccrualRounding(id, amount);
    }

    function _measure(ReserveAccrualStorageLib.State storage s, ReserveStorageLib.ReserveStorage storage native)
        private
        view
        returns (uint256[5] memory values)
    {
        IERC20 token = IERC20(s.modules.token);
        values[0] = token.totalSupply();
        values[1] = token.balanceOf(address(this));
        values[2] = token.balanceOf(s.modules.vault);
        values[3] = native.backingValue();
        values[4] = s.loans.book.snapshot(ReserveAccrualStorageLib.now64()).unissued;
    }

    function _unissuedVaultAssets(ReserveAccrualStorageLib.State storage s, uint64 at)
        private
        view
        returns (uint256 owned)
    {
        AccrualBook.Snapshot memory claims = s.loans.book.snapshot(at);
        owned = claims.seniorUnissued;
        if (s.feeRecipient == s.modules.vault) owned += claims.feeUnissued;
    }

    function _forwardGas() private view returns (uint256) {
        uint256 available = gasleft();
        uint256 retained = available >> 3;
        if (retained < 450_000) retained = 450_000;
        if (available <= retained + 200_000) revert AccrualRounding_InsufficientGas();
        return available - retained;
    }

    function _equal(uint8 measurement, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert AccrualRounding_DeltaMismatch(measurement, expected, actual);
    }
}
