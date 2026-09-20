// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {DefaultManager} from "../DefaultManager.sol";
import {WaterfallEngine} from "../WaterfallEngine.sol";
import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";
import {IsUSDfr} from "../interfaces/IsUSDfr.sol";
import {DefaultLossLib} from "./DefaultLossLib.sol";
import {CommitmentLedgerFactory} from "../CommitmentLedgerFactory.sol";
import {ICommitmentLedger} from "../interfaces/ICommitmentLedger.sol";
import {ClaimBridge} from "../ClaimBridge.sol";
import {IContinuousAccrual, IAccrualToken} from "../interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle, IAccrualReceipts, IAccrualServicing} from "../interfaces/IAccrualLifecycle.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IAccrualExposure} from "../interfaces/IAccrualExposure.sol";
import {Config} from "./Config.sol";
import {IDefaultManager} from "../interfaces/IDefaultManager.sol";
import {IAccrualMigration} from "../interfaces/IAccrualMigration.sol";

/// @title DefaultAccrualLib
/// @notice Linked continuous-interest support for the native default and past-due books.
/// @dev Runs in DefaultManager's context and uses its append-only namespace. The host retains
///      governance and operation guards. Recorded risk is posted face; the reserve supplies only
///      its additional unposted marked cohort. Posting transfers between those terms neutrally.
library DefaultAccrualLib {
    /// @dev Retain one eighth of sampled gas; no return-data allocation follows a failed call.
    uint256 private constant PIK_SETTLE_RESERVE_SHIFT = 3;
    bytes4 private constant PIK_CAPITALIZE_SELECTOR = 0x41a3f095;

    /// @notice Tries one legacy PIK period only after the bridge's operation has finished.
    /// @dev A missing or malformed bridge idle view refuses the operation. Its refusal occurs
    ///      outside the bounded call, so it cannot be reclassified as a failed loan settlement.
    function settlePikPeriod(DefaultManager.DefaultStorage storage $, uint256 tokenId) public returns (bool settled) {
        if (!$.bridge.creditOperationIdle()) revert IDefaultManager.DefaultManager_CreditOperationBusy();
        address engine = address($.waterfall);
        if (engine == address(0)) return false;
        uint256 available = gasleft();
        uint256 forwarded = available - (available >> PIK_SETTLE_RESERVE_SHIFT);
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            mstore(0x00, PIK_CAPITALIZE_SELECTOR)
            mstore(0x04, tokenId)
            ok := call(forwarded, engine, 0, 0x00, 0x24, 0x00, 0x00)
            size := returndatasize()
        }
        settled = ok && size >= 32;
    }

    /// @notice Maximum coupons in one default preparation transaction.
    uint256 private constant MAX_LEGACY_PIK_PERIODS = 16;

    /// @notice Legacy interest cannot be recorded without the configured servicing engine.
    error DefaultAccrual_LegacyWaterfallUnavailable();
    /// @notice More completed coupons must be recorded before the loan may enter default.
    error DefaultAccrual_LegacyPikPending(uint256 facilityId, uint64 nextDue);
    /// @notice A preparation batch must contain between one and 16 coupons.
    error DefaultAccrual_InvalidPikBatch(uint256 periods);
    /// @notice The explicit legacy preparation entry cannot service a continuous book or cash loan.
    error DefaultAccrual_NotLegacyPik(uint256 facilityId);
    /// @notice The servicing engine did not apply the exact planned coupon and cursor movement.
    error DefaultAccrual_LegacyPikMismatch(uint256 facilityId);

    /// @notice Records bounded legacy coupons under the same standing default evidence as declaration.
    /// @dev The host supplies its servicer and reentrancy guards. A past-due loan remains marked;
    ///      each coupon increases its risk contribution before issuance. No cure is asserted.
    /// @return processed Completed contractual coupons recorded in this transaction.
    /// @return pendingDue Next payable elapsed coupon, or zero when declaration can proceed.
    function settleLegacyPikForDefault(
        DefaultManager.DefaultStorage storage $,
        uint256 id,
        bytes32 evidenceHash,
        uint256 maxPeriods
    ) public returns (uint256 processed, uint64 pendingDue) {
        if (maxPeriods == 0 || maxPeriods > MAX_LEGACY_PIK_PERIODS) {
            revert DefaultAccrual_InvalidPikBatch(maxPeriods);
        }
        if (address($.accrualReserve) != address(0) && $.accrualReserve.accrualSnapshot().enabled) {
            revert DefaultAccrual_NotLegacyPik(id);
        }
        ClaimBridge.Facility memory f = $.bridge.facility(id);
        if (!f.pik) revert DefaultAccrual_NotLegacyPik(id);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert IDefaultManager.DefaultManager_NotDefaultable(id);
        }
        DefaultLossLib.consumeExact(
            $, id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidenceHash)), false
        );
        (processed, pendingDue) = _settleLegacyPik($, id, f, maxPeriods);
        if (processed != 0 && $.pastDueMarked[id]) DefaultLossLib.advanceImpairmentRevision($);
        emit IDefaultManager.LegacyPikPreparedForDefault(id, processed, pendingDue);
    }

    /// @dev Uses the existing signed, frozen legacy coupon planner. No partial-period coupon or
    ///      post-maturity compounding is invented. A blocked posting reverts the entire batch.
    function _settleLegacyPik(
        DefaultManager.DefaultStorage storage $,
        uint256 id,
        ClaimBridge.Facility memory f,
        uint256 maxPeriods
    ) private returns (uint256 processed, uint64 pendingDue) {
        if (!f.pik || $.reserves.deployedTo(id) == 0) return (0, 0);
        if (!$.bridge.creditOperationIdle()) revert IDefaultManager.DefaultManager_CreditOperationBusy();
        address engine = address($.waterfall);
        if (engine.code.length == 0) revert DefaultAccrual_LegacyWaterfallUnavailable();
        WaterfallEngine waterfall = WaterfallEngine(engine);
        pendingDue = waterfall.pendingLegacyPik(id);
        while (pendingDue != 0 && processed < maxPeriods) {
            WaterfallEngine.PikPlan memory plan = waterfall.planPik(id);
            if (plan.dueAt != pendingDue) revert DefaultAccrual_LegacyPikMismatch(id);
            uint256 beforeFace = $.reserves.deployedTo(id);
            if ($.pastDueMarked[id]) {
                // Preserve the previous fee epoch before increasing the conservative risk mark.
                IsUSDfr($.vault).accrueFees();
                $.pastDueContribution[id] += plan.amount;
                $.pastDuePrincipal[f.classId] += plan.amount;
                $.pastDueExposure += plan.amount;
                emit IDefaultManager.LegacyPikRiskRecorded(id, f.classId, plan.amount, $.pastDueContribution[id]);
            }
            uint256 posted = waterfall.capitalizePik(id);
            (uint64 lastAt,) = waterfall.pikCursorOf(id);
            if (posted != plan.amount || lastAt != pendingDue || $.reserves.deployedTo(id) != beforeFace + posted) {
                revert DefaultAccrual_LegacyPikMismatch(id);
            }
            ++processed;
            pendingDue = waterfall.pendingLegacyPik(id);
        }
    }

    /// @notice Removes a recorded past-due contribution without resetting its relief episode.
    /// @dev Shared by default conversion, authenticated cure and terminal performing repayment.
    function releasePastDue(DefaultManager.DefaultStorage storage $, uint256 id, uint256 classId) public {
        if (!$.pastDueMarked[id]) return;
        setPastDue($, id, false);
        uint256 released = $.pastDueContribution[id];
        $.pastDueMarked[id] = false;
        $.pastDueContribution[id] = 0;
        $.pastDuePrincipal[classId] -= released;
        $.pastDueExposure -= released;
        emit IDefaultManager.PastDueCleared(id, classId, released);
    }

    /// @notice Captures the fully prepared face in the declared class aggregate and commitment row.
    function recordDefaulted(DefaultManager.DefaultStorage storage $, uint256 id, uint256 classId) public {
        uint256 outstanding = $.reserves.deployedTo(id);
        $.defaultedContribution[id] = outstanding;
        $.declaredDefaultedPrincipal[classId] += outstanding;
        $.commitmentLedger.register(id, classId, outstanding);
    }

    /// @notice Installs a fresh manager-owned ledger after proving both live-risk carriers empty.
    /// @param $ The calling DefaultManager proxy's existing namespace.
    /// @param factory The immutable factory supplied by the current manager implementation.
    /// @param replaceExisting False for first installation; true for governed replacement.
    /// @dev The host retains its DEFAULT_ADMIN_ROLE and accrualIdle gates. The void public
    ///      entry also retains Solidity's code-existence guard on the linked library call.
    function installEmptyLedger(DefaultManager.DefaultStorage storage $, address factory, bool replaceExisting)
        public
    {
        address previous = address($.commitmentLedger);
        if (!replaceExisting && previous != address(0)) {
            revert IDefaultManager.DefaultManager_CommitmentLedgerAlreadySet(previous);
        }
        uint256 consumed = $.liveDefaultCoverageConsumed;
        if (consumed != 0) revert IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe(consumed);
        uint256 declared;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            declared += $.declaredDefaultedPrincipal[classId];
        }
        if (declared != 0) revert IDefaultManager.DefaultManager_CommitmentLedgerMigrationUnsafe(declared);
        address ledger = address(CommitmentLedgerFactory(factory).create(address(this)));
        $.commitmentLedger = ICommitmentLedger(ledger);
        if (replaceExisting) emit IDefaultManager.CommitmentLedgerReplaced(previous, ledger);
        else emit IDefaultManager.CommitmentLedgerSet(ledger);
    }

    /// @notice A permanent accrual source has already been bound.
    error DefaultAccrual_AlreadyBound();
    /// @notice The source, token or native module routes do not describe this same system.
    error DefaultAccrual_WrongModules();
    /// @notice An accrual delivery cannot overlap a risk or governance mutation.
    error DefaultAccrual_OperationInProgress();
    /// @notice Only the permanently bound reserve may reclassify a posted risk contribution.
    error DefaultAccrual_CallerNotReserve(address caller);
    /// @notice The reserve attempted to post risk for a facility outside the marked cohort.
    error DefaultAccrual_NotMarked(uint256 facilityId);
    /// @notice An enabled continuous book must contain every funded facility subject to risk actions.
    error DefaultAccrual_UnknownFacility(uint256 facilityId);
    /// @notice A rounding notification exceeds the recorded marked contribution it can reduce.
    error DefaultAccrual_RoundingExceedsContribution(uint256 facilityId, uint256 amount, uint256 contribution);

    /// @notice The native risk manager has bound its permanent continuous accounting source.
    event DefaultAccrualBound(address indexed reserve);
    /// @notice Previously virtual marked interest is now included in the recorded contribution.
    event PastDueAccrualPosted(
        uint256 indexed facilityId, uint256 indexed classId, uint256 amount, uint256 recordedContribution
    );

    /// @notice An independently proved native rounding loss reduces recorded marked risk.
    event PastDueRoundingRecognized(
        uint256 indexed facilityId, uint256 indexed classId, uint256 amount, uint256 recordedContribution
    );

    /// @notice Binds after the underlying token, validating every native module identity.
    /// @dev The host authenticates governance. No write precedes complete fixed-ABI validation.
    function bind(DefaultManager.DefaultStorage storage $, address reserve) public {
        if (address($.accrualReserve) != address(0)) revert DefaultAccrual_AlreadyBound();
        if (reserve != address($.reserves) || reserve.code.length == 0) revert DefaultAccrual_WrongModules();
        (bool ok, bytes memory data) = reserve.staticcall(abi.encodeCall(IContinuousAccrual.accrualModules, ()));
        if (!ok || data.length != 224) revert DefaultAccrual_WrongModules();
        uint256[7] memory words = abi.decode(data, (uint256[7]));
        for (uint256 i; i < 7; ++i) {
            if (words[i] > type(uint160).max) revert DefaultAccrual_WrongModules();
        }
        IContinuousAccrual.Modules memory m = abi.decode(data, (IContinuousAccrual.Modules));
        if (
            m.defaultManager != address(this) || m.token != address($.usdfr) || m.controller != address($.controller)
                || m.vault != $.vault || m.bridge != address($.bridge) || m.registry != address($.registry)
                || m.waterfall != address($.waterfall) || m.waterfall == address(0)
        ) revert DefaultAccrual_WrongModules();
        (ok, data) = address($.usdfr).staticcall(abi.encodeCall(IAccrualToken.accrualReserve, ()));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != uint256(uint160(reserve))) {
            revert DefaultAccrual_WrongModules();
        }
        (ok, data) = address($.bridge).staticcall(abi.encodeCall(ClaimBridge.modules, ()));
        if (!ok || data.length != 64) revert DefaultAccrual_WrongModules();
        uint256[2] memory bridgeWords = abi.decode(data, (uint256[2]));
        if (
            bridgeWords[0] != uint256(uint160(address($.registry)))
                || bridgeWords[1] != uint256(uint160(address($.oracle)))
        ) revert DefaultAccrual_WrongModules();
        (ok, data) = address($.controller).staticcall(abi.encodeCall(IMintRedeemController.modules, ()));
        if (!ok || data.length != 96) revert DefaultAccrual_WrongModules();
        uint256[3] memory controllerWords = abi.decode(data, (uint256[3]));
        if (
            controllerWords[0] != uint256(uint160(address($.usdfr))) || controllerWords[1] > type(uint160).max
                || controllerWords[2] != uint256(uint160(reserve))
        ) revert DefaultAccrual_WrongModules();
        $.accrualReserve = IContinuousAccrual(reserve);
        emit DefaultAccrualBound(reserve);
    }

    /// @notice Refuses conflicting callbacks without disabling paused loss recognition.
    function requireIdle(DefaultManager.DefaultStorage storage $, bool entered) public view {
        if (address($.accrualReserve) == address(0) || !$.accrualReserve.accrualSnapshot().enabled) return;
        if (entered) revert DefaultAccrual_OperationInProgress();
        IAccrualExposure(address($.accrualReserve)).requireAccrualIdle();
    }

    /// @notice Advances posted face, or permanently stops it before a default snapshot.
    /// @dev Before activation, a default records completed legacy PIK coupons first. A backlog
    ///      above 32 requires preparatory batches. Once enabled, native freshness and registration
    ///      are mandatory: an unknown funded face cannot bypass accrued accounting.
    /// @return tracked Whether this loan belongs to the continuous accounting book.
    /// @return paymentDue The authoritative PIK date for marking, or zero for the legacy/cash path.
    function prepare(DefaultManager.DefaultStorage storage $, uint256 id, bool stop)
        public
        returns (bool tracked, uint64 paymentDue)
    {
        IContinuousAccrual source = $.accrualReserve;
        if (address(source) == address(0) || !source.accrualSnapshot().enabled) {
            if (stop) {
                (, uint64 pendingDue) = _settleLegacyPik($, id, $.bridge.facility(id), MAX_LEGACY_PIK_PERIODS);
                if (pendingDue != 0) revert DefaultAccrual_LegacyPikPending(id, pendingDue);
            }
            return (false, 0);
        }
        source.requireAccrualFresh();
        IAccrualLifecycle lifecycle = IAccrualLifecycle(address(source));
        IAccrualLifecycle.Debt memory debt = lifecycle.accruedDebt(id);
        tracked = debt.known;
        if (!tracked) revert DefaultAccrual_UnknownFacility(id);
        if (stop) {
            lifecycle.stopAccruingLoan(id);
        } else {
            if (debt.pik) {
                IAccrualServicing servicing = IAccrualServicing(address(source));
                if (!servicing.accrualLoanScheduled(id)) {
                    servicing.serviceAccruedLoan(id);
                    debt = lifecycle.accruedDebt(id);
                }
                // Zero denotes no further signed capitalization. It never makes an old
                // coupon date a new delinquency, nor invents a capitalization at maturity.
                paymentDue = debt.nextCapitalization == 0 ? debt.maturity : debt.nextCapitalization;
            }
            lifecycle.postAccruedLoan(id);
        }
    }

    /// @notice Sets the bound reserve's additional-interest risk membership exactly once.
    /// @dev Called before retirement and after posting, so membership cannot remove unrecorded
    ///      marked income. The host calls this inside its existing guarded risk operation;
    ///      repayment hooks run after the reserve receipt returns idle and before retirement.
    function setPastDue(DefaultManager.DefaultStorage storage $, uint256 id, bool marked) public {
        if (address($.accrualReserve) == address(0)) return;
        if (!$.accrualReserve.accrualSnapshot().enabled) return;
        IAccrualLifecycle source = IAccrualLifecycle(address($.accrualReserve));
        if (!source.accruedDebt(id).known) revert DefaultAccrual_UnknownFacility(id);
        source.setAccrualPastDue(id, marked);
    }

    /// @notice Reclassifies an already-counted marked receivable from virtual to recorded risk.
    /// @dev This is the reserve's narrow posting callback, including during a guarded default
    ///      preparation. It intentionally does not require a second reentrancy guard or advance
    ///      impairmentRevision: aggregate economic risk and assessment identity do not change.
    function onPosted(DefaultManager.DefaultStorage storage $, uint256 id, uint256 amount) public {
        if (address($.accrualReserve) == address(0) || msg.sender != address($.accrualReserve)) {
            revert DefaultAccrual_CallerNotReserve(msg.sender);
        }
        if ($.accrualReserve.accrualDelivery().active) revert DefaultAccrual_OperationInProgress();
        if (!$.pastDueMarked[id]) revert DefaultAccrual_NotMarked(id);
        uint256 classId = $.bridge.facility(id).classId;
        $.pastDueContribution[id] += amount;
        $.pastDuePrincipal[classId] += amount;
        $.pastDueExposure += amount;
        emit PastDueAccrualPosted(id, classId, amount, $.pastDueContribution[id]);
    }

    /// @notice An opening must preserve existing risk and classify every newly recorded unit.
    error DefaultAccrual_InvalidOpening(uint256 facilityId);

    /// @notice Opening income has been included in the declared or past-due risk carrier.
    event OpeningRiskRecorded(uint256 indexed facilityId, uint256 income, bool declared, bool pastDue);

    /// @notice Reconciles only the currently preparing reserve's attested opening.
    function onOpening(DefaultManager.DefaultStorage storage $, uint256 id, uint256 income)
        public
        returns (bool marked)
    {
        address reserve = address($.accrualReserve);
        if (reserve == address(0) || msg.sender != reserve) revert DefaultAccrual_CallerNotReserve(msg.sender);
        if (!IAccrualMigration(reserve).accrualMigration().active) revert DefaultAccrual_OperationInProgress();
        ClaimBridge.Facility memory f = $.bridge.facility(id);
        uint256 face = $.reserves.deployedTo(id);
        if (income > face) revert DefaultAccrual_InvalidOpening(id);
        bool declared = f.state == ClaimBridge.LoanState.Defaulted || f.state == ClaimBridge.LoanState.Accelerated;
        marked = $.pastDueMarked[id];
        if (declared) {
            if (marked || $.defaultedContribution[id] != face - income) revert DefaultAccrual_InvalidOpening(id);
            $.defaultedContribution[id] = face;
            $.declaredDefaultedPrincipal[f.classId] += income;
            if ($.coverageConsumedByDefault[id] != 0) $.drawnDefaultPrincipal[f.classId] += income;
            $.commitmentLedger.updatePrincipal(id, face);
        } else if (marked) {
            $.pastDueContribution[id] += income;
            $.pastDuePrincipal[f.classId] += income;
            $.pastDueExposure += income;
        }
        if (income != 0 && (declared || marked)) {
            ++$.impairmentRevision;
            emit IDefaultManager.ImpairmentRevisionAdvanced($.impairmentRevision);
        }
        emit OpeningRiskRecorded(id, income, declared, marked);
    }

    /// @notice Recognizes only the risk reduction from an already executed native rounding loss.
    /// @dev The bound reserve proves the discrepancy, posts its recognized face, performs the
    ///      native write-down/cascade and calls this continuation while its operation is busy.
    ///      No Book history, fee allocation, supply or custody is changed here. An unmarked
    ///      performing loan will instead enter any later default snapshot at its corrected face.
    function onRounding(DefaultManager.DefaultStorage storage $, uint256 id, uint256 amount) public {
        if (address($.accrualReserve) == address(0) || msg.sender != address($.accrualReserve)) {
            revert DefaultAccrual_CallerNotReserve(msg.sender);
        }
        if ($.accrualReserve.accrualDelivery().active) revert DefaultAccrual_OperationInProgress();
        if (!$.pastDueMarked[id] || amount == 0) return;
        uint256 contribution_ = $.pastDueContribution[id];
        if (amount > contribution_) revert DefaultAccrual_RoundingExceedsContribution(id, amount, contribution_);
        uint256 classId = $.bridge.facility(id).classId;
        $.pastDueContribution[id] = contribution_ - amount;
        $.pastDuePrincipal[classId] -= amount;
        $.pastDueExposure -= amount;
        $.impairmentRevision += 1;
        emit IDefaultManager.ImpairmentRevisionAdvanced($.impairmentRevision);
        emit PastDueRoundingRecognized(id, classId, amount, contribution_ - amount);
    }

    /// @notice Physical delivery of all vault-owned claims before a native facility-loss burn.
    /// @dev The reserve proves supply and recipient deltas. Paused expansion does not prohibit
    ///      delivery. A separate protocol fee remains earned for later permissionless delivery,
    ///      so its recipient's restrictions cannot block settlement of an attested loan loss.
    function materialize(DefaultManager.DefaultStorage storage $) public {
        if (address($.accrualReserve) == address(0)) return;
        IContinuousAccrual.Snapshot memory claims = $.accrualReserve.accrualSnapshot();
        if (claims.enabled) $.accrualReserve.materializeAccrued(claims.feeRecipient == $.vault ? 3 : 1);
    }

    /// @notice Retires a fully written-off, stopped facility after native resolution and risk release.
    /// @dev Ordinary receipt retirement is owned by the waterfall after its recovery hooks. This
    ///      continuation is only for a terminal default loss; the source verifies zero posted face
    ///      and the bridge's resolved state before releasing the Book admission slot.
    function retireAfterLoss(DefaultManager.DefaultStorage storage $, uint256 id) public {
        if (address($.accrualReserve) != address(0) && $.accrualReserve.accrualSnapshot().enabled) {
            IAccrualReceipts(address($.accrualReserve)).retireAccruedLoan(id);
        }
    }

    /// @notice Recorded plus unposted marked risk for one facility.
    function contribution(DefaultManager.DefaultStorage storage $, uint256 id) public view returns (uint256 amount) {
        amount = $.pastDueContribution[id];
        if ($.pastDueMarked[id] && address($.accrualReserve) != address(0)) {
            amount += IAccrualLifecycle(address($.accrualReserve)).unpostedAccruedLoan(id);
        }
    }

    /// @notice Recorded plus unposted marked risk for one class, without facility enumeration.
    function pastDuePrincipal(DefaultManager.DefaultStorage storage $, uint256 classId)
        internal
        view
        returns (uint256 amount)
    {
        amount = $.pastDuePrincipal[classId];
        if (address($.accrualReserve) != address(0)) {
            amount += IAccrualLifecycle(address($.accrualReserve)).accruedPastDue(classId);
        }
    }

    /// @notice The complete global marked cohort, using only the fixed native class set.
    function pastDueExposure(DefaultManager.DefaultStorage storage $) public view returns (uint256 amount) {
        amount = $.pastDueExposure;
        if (address($.accrualReserve) == address(0)) return amount;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            amount += IAccrualLifecycle(address($.accrualReserve)).accruedPastDue(classId);
        }
    }

    /// @notice Gross impairment for the existing performance-fee basis, including streamed risk.
    function performanceImpairment(DefaultManager.DefaultStorage storage $) public view returns (uint256 amount) {
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            amount += $.declaredDefaultedPrincipal[classId] + pastDuePrincipal($, classId);
        }
    }

    /// @notice BSC's exact senior impairment in one fixed-class walk, independent of default count.
    /// @dev BSC has no shared backstop. Each class's curator pool serves its past-due cohort first,
    ///      and then its declared claims; partitioning those claims into events cannot change the
    ///      sum delivered by that class's pool. This is equivalent to both native ledger orders.
    ///      The registry retains the exact existing executable clamp and relief ramp. Do not use
    ///      this curator-only formula on Ethereum, where residual demand also uses a shared reserve.
    function bscSeniorImpairment(DefaultManager.DefaultStorage storage $) public view returns (uint256) {
        uint256 residual;
        uint256 pastDueSenior;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 pastDue = pastDuePrincipal($, classId);
            uint256 available = $.curator.poolBalance(classId);
            if (pastDue > available) {
                pastDueSenior += pastDue - available;
                available = 0;
            } else {
                available -= pastDue;
            }
            uint256 declared = $.declaredDefaultedPrincipal[classId];
            if (declared > available) residual += declared - available;
        }
        residual += pastDueSenior;
        if (residual == 0) return 0;
        return $.registry.conservativeSeniorMark(pastDueSenior, residual, $.vault, $.pastDueReliefAnchor);
    }

    /// @notice Existing attested LTV calculation, moved here to preserve host runtime margin.
    /// @dev Deployed face includes unreceived earned interest on continuously tracked notes.
    ///      The order of the zero-mark check and checked multiplication/division is unchanged.
    function loanToValue(DefaultManager.DefaultStorage storage $, uint256 tokenId)
        public
        view
        returns (uint256 ltvBps, uint64 asOf)
    {
        uint256 value;
        (value, asOf) = $.oracle.latestValuation(tokenId);
        if (value == 0) revert IDefaultManager.DefaultManager_NoValuation(tokenId);
        ltvBps = $.reserves.deployedTo(tokenId) * Config.BPS / value;
    }

    /// @notice Exact legacy operational fingerprint, retained for existing assessment wrappers.
    function exactStateHash(DefaultManager.DefaultStorage storage $) public view returns (bytes32) {
        return keccak256(abi.encode(riskStateHash($), uint256(0)));
    }

    /// @notice Separates accrued overdue face from the identity of the assessed risk book.
    /// @dev Risk membership, repayment, declaration, loss and opening changes advance the
    ///      manager's revision. Neutral posting does not. Curator pools remain exact inputs.
    ///      This chain has no global backstop, so the separate capacity value is always zero.
    ///      A caller must reserve the entire increase in exposure. Omitting that adjustment
    ///      would let overdue interest increase an assessed senior exit price.
    function assessmentState(DefaultManager.DefaultStorage storage $)
        public
        view
        returns (bytes32 riskHash, uint256 exposure, uint256 capacity)
    {
        riskHash = keccak256(
            abi.encode(
                keccak256("forestroad.assessment.accrual.v1"),
                block.chainid,
                address(this),
                $.impairmentRevision,
                address($.curator),
                $.commitmentLedger.remainingPrincipalAggregate(),
                address($.accrualReserve),
                $.pastDueReliefAnchor
            )
        );
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            riskHash = keccak256(
                abi.encode(
                    riskHash,
                    classId,
                    $.declaredDefaultedPrincipal[classId],
                    $.curator.poolBalance(classId),
                    $.drawnDefaultPrincipal[classId]
                )
            );
        }
        exposure = pastDueExposure($);
        capacity = uint256(0);
    }

    /// @notice Preserves the native risk fingerprint and includes the moving unreceived cohort.
    /// @dev Time alone changes this hash when marked interest grows. Posting does not, since its
    ///      decrease in the reserve's cohort exactly equals the recorded contribution increase.
    function riskStateHash(DefaultManager.DefaultStorage storage $) public view returns (bytes32 stateHash) {
        // The same cohort participates in the global and per-class fingerprints. Read each
        // once so an invalidated assessed mark still fits the existing cold recovery probe.
        uint256[3] memory marked;
        uint256 exposure = $.pastDueExposure;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 extra;
            if (address($.accrualReserve) != address(0)) {
                extra = IAccrualLifecycle(address($.accrualReserve)).accruedPastDue(classId);
            }
            marked[classId - 1] = $.pastDuePrincipal[classId] + extra;
            exposure += extra;
        }
        stateHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.impairmentRevision,
                address($.curator),
                $.commitmentLedger.remainingPrincipalAggregate(),
                exposure
            )
        );
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            stateHash = keccak256(
                abi.encode(
                    stateHash,
                    classId,
                    $.declaredDefaultedPrincipal[classId],
                    marked[classId - 1],
                    $.curator.poolBalance(classId),
                    $.drawnDefaultPrincipal[classId]
                )
            );
        }
    }
}
