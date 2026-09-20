// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../ClaimBridge.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IAccrualLifecycle, IAccrualBridge, IAccrualRegistry, IAccrualRisk} from "../interfaces/IAccrualLifecycle.sol";
import {AccrualBook} from "./AccrualBook.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {AccrualCeiling} from "./AccrualCeiling.sol";
import {ReserveAccrualLib} from "./ReserveAccrualLib.sol";
import {ReserveRoundingLib} from "./ReserveRoundingLib.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";
import {ReserveCreditLib} from "./ReserveCreditLib.sol";

/// @title ReserveAccrualCreditLib
/// @notice Authenticated fixed-rate loan lifecycle and native receivable posting in the reserve.
/// @dev Public methods execute by delegatecall in the reserve. Its host supplies nonReentrant;
///      these methods additionally authenticate the immutable module and close callback admission.
library ReserveAccrualCreditLib {
    using AccrualBook for AccrualBook.Book;
    using AccrualLoans for AccrualLoans.State;
    using ReserveStorageLib for ReserveStorageLib.ReserveStorage;

    uint256 internal constant MAX_EXPOSURE = type(uint256).max / 10_000;

    /// @notice This event is restricted to the immutable module that proves its economic facts.
    error AccrualCredit_WrongCaller(address expected, address caller);
    /// @notice The funded bridge and measured native receivable disagree.
    error AccrualCredit_InvalidFunding(uint256 facilityId);
    /// @notice The first release supports fixed Actual/360 and Actual/365 cash, and fixed Actual/360 PIK.
    error AccrualCredit_UnsupportedTerms(uint256 facilityId);
    /// @notice A known funded identifier cannot be registered or bound a second time.
    error AccrualCredit_AlreadyKnown(uint256 facilityId);
    /// @notice An event cannot address an omitted or unfunded receivable.
    error AccrualCredit_Unknown(uint256 facilityId);
    /// @notice All funded future ceilings and present pending exposure must fit the registry domain.
    error AccrualCredit_ExposureCapacity();
    /// @notice Past-due baseline installation requires existing growth to be posted first.
    error AccrualCredit_UnpostedRisk(uint256 facilityId);
    /// @notice The exposure key discriminator must be total=0, class=1, borrower=2 or state=3.
    error AccrualCredit_InvalidExposureKind(uint8 kind);
    /// @notice A measured receipt or native face failed the exact contractual accounting identity.
    error AccrualCredit_ReceiptMismatch(uint256 facilityId);
    /// @notice Native loss reductions cannot leave a running contractual clock or exceed stopped debt.
    error AccrualCredit_InvalidWriteDown(uint256 facilityId);
    /// @notice An accrued facility must use its authenticated lifecycle rather than a legacy upward/receipt setter.
    error AccrualCredit_UseAccrualLifecycle(uint256 facilityId);

    /// @notice Gates legacy funding ledger writes to the one bound waterfall before registration.
    function requireUnregisteredFunding(uint256 id) internal view {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (!s.enabled) return;
        _caller(s.modules.waterfall);
        if (s.identities[id].known) revert AccrualCredit_UseAccrualLifecycle(id);
    }

    /// @notice Legacy PIK/receipt ledgers cannot bypass continuous recognition after activation.
    function requireLegacy(uint256 id) internal view {
        if (ReserveAccrualStorageLib.state().enabled) revert AccrualCredit_UseAccrualLifecycle(id);
    }

    /// @notice Continuous recognition began on authenticated funded terms, from the funding block.
    event AccruingLoanRegistered(
        uint256 indexed facilityId,
        address indexed asset,
        uint256 indexed classId,
        uint256 principal,
        uint256 balanceCeiling,
        uint16 rateBps,
        uint32 yearSeconds,
        uint64 fundedAt,
        bool pik
    );
    /// @notice Existing earned interest moved from the virtual carrier to recorded face, without minting.
    event AccruedLoanPosted(uint256 indexed facilityId, address indexed asset, uint256 amount, uint256 faceAfter);
    /// @notice A keeper completed a chronological technical or signed contractual boundary.
    event AccrualBoundaryProcessed(
        uint256 indexed facilityId, uint64 indexed at, uint256 capitalized, uint64 nextDue, bool stopped
    );
    /// @notice The signed old curve closed before applying a forward amendment or declaration.
    event AccrualLoanAligned(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint64 at,
        uint256 positiveCorrection,
        uint256 roundingLoss,
        bool stopped
    );
    /// @notice Marked cohort membership changed without changing contractual interest entitlement.
    event AccrualPastDueSet(uint256 indexed facilityId, bool marked);
    /// @notice The remaining maximum future face reservation changed after a proved lifecycle event.
    event AccrualCeilingReserved(uint256 indexed facilityId, uint256 previousCeiling, uint256 nextCeiling);

    /// @notice Registers exactly the just-funded Active bridge facility; no caller supplies its terms.
    function register(uint256 id) public {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _caller(s.modules.waterfall);
        if (s.identities[id].known) revert AccrualCredit_AlreadyKnown(id);
        ClaimBridge.Facility memory f = ClaimBridge(s.modules.bridge).facility(id);
        ReserveStorageLib.ReserveStorage storage native = ReserveStorageLib.layout();
        address asset = native.facilityAsset[id];
        if (f.state != ClaimBridge.LoanState.Active || asset == address(0) || native.deployed[id] != f.principal) {
            revert AccrualCredit_InvalidFunding(id);
        }
        uint32 yearSeconds = _year(id, f.rateType, f.dayCountConvention, f.pik);
        uint256 scale = native.requireListed(asset).scale;
        uint64 at = ReserveAccrualStorageLib.now64();
        uint256 ceiling = ReserveAccrualLib.loanCeiling(
            AccrualCeiling.Terms({
                face: f.principal,
                frozenBasis: f.principal,
                scale: scale,
                yearSeconds: yearSeconds,
                rateBps: f.interestRateBps,
                at: at,
                nextCapitalization: f.nextPaymentDue,
                paymentInterval: f.paymentInterval,
                maturity: f.maturity
            }),
            f.pik
        );
        _admitAdditional(s, ceiling - f.principal);
        s.busy = true;
        AccrualLoans.Funding memory funded = AccrualLoans.Funding({
            principal: f.principal,
            balanceCeiling: ceiling,
            scale: scale,
            yearSeconds: yearSeconds,
            rateBps: f.interestRateBps,
            fundedAt: at,
            nextPaymentDue: f.nextPaymentDue,
            paymentInterval: f.paymentInterval,
            maturity: f.maturity,
            pik: f.pik,
            keys: ReserveAccrualStorageLib.keys(f.classId, f.borrowerId, f.stateId),
            frozenPikBasis: 0
        });
        s.loans.fund(id, funded);
        s.identities[id] = ReserveAccrualStorageLib.Identity({
            asset: asset,
            classId: f.classId,
            borrowerId: f.borrowerId,
            stateId: f.stateId,
            reservedCeiling: ceiling,
            known: true
        });
        s.recordedFace += f.principal;
        s.reservedCeilings += ceiling;
        s.busy = false;
        _emitRegistered(id, asset, f.classId, funded);
    }

    /// @notice Bounded permissionless maintenance; does not mint or transfer every facility's face.
    function checkpoint(uint256 maximum) public returns (uint256 processed, bool fresh) {
        ReserveAccrualLib.requireIdle();
        ReserveAccrualStorageLib.State storage s = _enabled();
        s.busy = true;
        AccrualLoans.LifecycleWork[] memory work;
        (work, processed, fresh) = s.loans.checkpoint(ReserveAccrualStorageLib.now64(), maximum);
        for (uint256 i; i < processed; ++i) {
            AccrualLoans.LifecycleWork memory item = work[i];
            // A migrated legacy receipt can have advanced the native servicing date ahead
            // of this coupon. Keep the bridge monotone while the canonical coupon clock catches up.
            if (
                item.nextDue != 0
                    && item.nextDue > ClaimBridge(s.modules.bridge).facility(item.facilityId).nextPaymentDue
            ) {
                IAccrualBridge(s.modules.bridge).setAccruedPaymentDue(item.facilityId, item.nextDue);
            }
            if (item.stopped) {
                _replaceCeiling(
                    s,
                    item.facilityId,
                    ReserveStorageLib.layout().deployed[item.facilityId]
                        + ReserveAccrualStorageLib.facilityUnposted(item.facilityId)
                );
            }
            emit AccrualBoundaryProcessed(item.facilityId, item.at, item.capitalized, item.nextDue, item.stopped);
        }
        s.busy = false;
    }

    /// @notice Neutral posting for a single facility before impairment or another native ledger act.
    function post(uint256 id) public returns (uint256 amount) {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _identity(s, id);
        s.busy = true;
        amount = s.loans.post(id, ReserveAccrualStorageLib.now64());
        _post(s, id, amount);
        s.busy = false;
    }

    /// @notice Matches both signed receipt legs against debt, then measures the exact native cash arrival.
    /// @dev The waterfall consumes the attestation first and decreases registry exposure immediately
    ///      after this returns. No token issuance, interest routing or duplicate fee occurs here.
    function repay(uint256 id, address payer, uint256 principal, uint256 interest)
        public
        returns (uint256 outstanding)
    {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _caller(s.modules.waterfall);
        _identity(s, id);
        ReserveRoundingLib.prepare(id);
        s.busy = true;
        AccrualLoans.LifecycleWork memory work =
            s.loans.repay(id, principal, interest, ReserveAccrualStorageLib.now64());
        _aligned(s, work);
        uint256 total = principal + interest;
        uint256 scale = s.loans.loans[id].terms.scale;
        uint256 received = ReserveCreditLib.payAccrued(
            ReserveStorageLib.layout(),
            id,
            s.identities[id].asset,
            payer,
            total / scale,
            work.principalReduction,
            work.interestReduction
        );
        if (received != total) revert AccrualCredit_ReceiptMismatch(id);
        s.recordedFace -= total;
        outstanding = ReserveStorageLib.layout().deployed[id];
        if (outstanding != s.loans.loans[id].principal + s.loans.loans[id].unpaidInterest) {
            revert AccrualCredit_ReceiptMismatch(id);
        }
        if (work.repaid || s.loans.loans[id].permanentlyStopped) _replaceCeiling(s, id, outstanding);
        s.busy = false;
    }

    /// @notice Completes retirement only after the native face, bridge state and risk hooks have closed.
    function retire(uint256 id) public {
        ReserveAccrualStorageLib.State storage s = _fresh();
        if (msg.sender != s.modules.waterfall && msg.sender != s.modules.defaultManager) {
            revert AccrualCredit_WrongCaller(s.modules.waterfall, msg.sender);
        }
        _identity(s, id);
        ClaimBridge.LoanState state = ClaimBridge(s.modules.bridge).facility(id).state;
        if (
            ReserveStorageLib.layout().deployed[id] != 0
                || (state != ClaimBridge.LoanState.Repaid && state != ClaimBridge.LoanState.Resolved)
        ) {
            revert AccrualCredit_ReceiptMismatch(id);
        }
        s.loans.retire(id, ReserveAccrualStorageLib.now64());
        _replaceCeiling(s, id, 0);
    }

    /// @notice Synchronizes a native declared-loss face reduction, without pretending it was a cash receipt.
    /// @dev Called before the host's existing native write-down. Only permanently stopped debt can shrink.
    function writeDown(uint256 id, uint256 amount) public {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _caller(s.modules.defaultManager);
        _identity(s, id);
        AccrualLoans.Loan storage loan = s.loans.loans[id];
        uint256 face = loan.principal + loan.unpaidInterest;
        if (!loan.permanentlyStopped || amount > face || ReserveAccrualStorageLib.facilityUnposted(id) != 0) {
            revert AccrualCredit_InvalidWriteDown(id);
        }
        uint256 principal = amount < loan.principal ? amount : loan.principal;
        loan.principal -= principal;
        loan.unpaidInterest -= amount - principal;
        s.recordedFace -= amount;
        _replaceCeiling(s, id, face - amount);
    }

    /// @notice Replaces only future terms after the bridge consumes its exact signed amendment.
    function amend(uint256 id, IAccrualLifecycle.Terms memory terms) public {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _caller(s.modules.bridge);
        _identity(s, id);
        AccrualLoans.Loan storage loan = s.loans.loans[id];
        if (terms.yearSeconds != 360 days && (loan.pik || terms.yearSeconds != 365 days)) {
            revert AccrualCredit_UnsupportedTerms(id);
        }
        uint64 at = ReserveAccrualStorageLib.now64();
        (uint256 principal, uint256 interest,) = s.loans.loanFace(id, at);
        AccrualCeiling.Terms memory remaining;
        remaining.face = principal + interest;
        // Closing a dormant elapsed PIK boundary capitalizes existing interest before
        // the new rate starts. Otherwise an amendment preserves the frozen first basis.
        remaining.frozenBasis = !loan.pik
            ? principal
            : (loan.nextCapitalization != 0 && loan.nextCapitalization <= at ? remaining.face : loan.frozenPikBasis);
        remaining.scale = loan.terms.scale;
        remaining.yearSeconds = terms.yearSeconds;
        remaining.rateBps = terms.rateBps;
        remaining.at = at;
        remaining.nextCapitalization = terms.nextPaymentDue;
        remaining.paymentInterval = terms.paymentInterval;
        remaining.maturity = terms.maturity;
        uint256 ceiling = ReserveAccrualLib.loanCeiling(remaining, loan.pik);
        _replaceCeiling(s, id, ceiling);
        ReserveRoundingLib.prepare(id);
        s.busy = true;
        AccrualLoans.LifecycleWork memory work = s.loans.amend(
            id,
            AccrualLoans.Amendment({
                balanceCeiling: ceiling,
                yearSeconds: terms.yearSeconds,
                rateBps: terms.rateBps,
                nextPaymentDue: terms.nextPaymentDue,
                paymentInterval: terms.paymentInterval,
                maturity: terms.maturity
            }),
            at
        );
        _aligned(s, work);
        s.busy = false;
    }

    /// @notice Stops at declaration and posts the full earned claim before any default snapshot.
    function stop(uint256 id) public {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _caller(s.modules.defaultManager);
        _identity(s, id);
        ReserveRoundingLib.prepare(id);
        s.busy = true;
        AccrualLoans.LifecycleWork memory work = s.loans.stop(id, ReserveAccrualStorageLib.now64());
        _aligned(s, work);
        _replaceCeiling(s, id, ReserveStorageLib.layout().deployed[id]);
        s.busy = false;
    }

    /// @notice Sets a cohort only after posting its initial marked face, preventing double counting.
    function setPastDue(uint256 id, bool marked) public {
        ReserveAccrualStorageLib.State storage s = _fresh();
        _caller(s.modules.defaultManager);
        _identity(s, id);
        if (marked && ReserveAccrualStorageLib.facilityUnposted(id) != 0) revert AccrualCredit_UnpostedRisk(id);
        s.loans.book.setPastDue(id, marked, ReserveAccrualStorageLib.now64());
        emit AccrualPastDueSet(id, marked);
    }

    /// @notice Constant-time earned additions to registry exposure; zero state has no jurisdiction book.
    function exposure(uint8 kind, bytes32 key) public view returns (uint256 amount) {
        if (kind > 3) revert AccrualCredit_InvalidExposureKind(kind);
        if (kind == 0) return ReserveAccrualStorageLib.unposted();
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (!s.enabled || (kind == 3 && key == bytes32(0))) return 0;
        return s.loans.book.groupUnposted(keccak256(abi.encode(kind, key)), ReserveAccrualStorageLib.now64());
    }

    /// @notice Future face already reserved, additional to the current registry's effective exposure.
    function reservedExposure() public view returns (uint256 amount) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (!s.enabled) return 0;
        uint256 effectiveFace = s.recordedFace + ReserveAccrualStorageLib.unposted();
        return s.reservedCeilings > effectiveFace ? s.reservedCeilings - effectiveFace : 0;
    }

    /// @notice Growing marked-cohort face not yet included in the default manager's recorded mark.
    function pastDue(uint256 classId) public view returns (uint256 amount) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (!s.enabled) return 0;
        return s.loans.book.pastDueInterest(keccak256(abi.encode(uint8(1), classId)), ReserveAccrualStorageLib.now64());
    }

    function _aligned(ReserveAccrualStorageLib.State storage s, AccrualLoans.LifecycleWork memory work) private {
        _post(s, work.facilityId, work.posting);
        if (work.roundingLoss != 0) ReserveRoundingLib.allocate(work);
        emit AccrualLoanAligned(
            work.facilityId, work.closureNonce, work.at, work.positiveCorrection, work.roundingLoss, work.stopped
        );
    }

    function _emitRegistered(uint256 id, address asset, uint256 classId, AccrualLoans.Funding memory funded) private {
        emit AccruingLoanRegistered(
            id,
            asset,
            classId,
            funded.principal,
            funded.balanceCeiling,
            funded.rateBps,
            uint32(funded.yearSeconds),
            funded.fundedAt,
            funded.pik
        );
    }

    function _post(ReserveAccrualStorageLib.State storage s, uint256 id, uint256 amount) private {
        if (amount == 0) return;
        ReserveAccrualStorageLib.Identity storage identity = s.identities[id];
        ReserveStorageLib.ReserveStorage storage native = ReserveStorageLib.layout();
        native.deployed[id] += amount;
        native.totalDeployedPrincipal += amount;
        s.recordedFace += amount;
        IAccrualRegistry(s.modules.registry).recordAccruedExposure(
            identity.classId, identity.borrowerId, identity.stateId, amount
        );
        if (s.loans.book.entries[id].pastDue) IAccrualRisk(s.modules.defaultManager).onAccrualPosted(id, amount);
        emit AccruedLoanPosted(id, identity.asset, amount, native.deployed[id]);
    }

    function _admitAdditional(ReserveAccrualStorageLib.State storage s, uint256 additional) private view {
        uint256 effective = ICollateralRegistry(s.modules.registry).totalBookExposure();
        uint256 future = reservedExposure();
        if (
            effective > MAX_EXPOSURE || future > MAX_EXPOSURE - effective
                || additional > MAX_EXPOSURE - effective - future
        ) {
            revert AccrualCredit_ExposureCapacity();
        }
    }

    function _replaceCeiling(ReserveAccrualStorageLib.State storage s, uint256 id, uint256 next) private {
        uint256 previous = s.identities[id].reservedCeiling;
        if (next > previous) _admitAdditional(s, next - previous);
        s.reservedCeilings = s.reservedCeilings - previous + next;
        s.identities[id].reservedCeiling = next;
        emit AccrualCeilingReserved(id, previous, next);
    }

    function _year(uint256 id, ClaimBridge.RateType rate, ClaimBridge.DayCountConvention convention, bool pik)
        private
        pure
        returns (uint32)
    {
        if (rate != ClaimBridge.RateType.Fixed) revert AccrualCredit_UnsupportedTerms(id);
        if (convention == ClaimBridge.DayCountConvention.Actual360) return uint32(360 days);
        if (!pik && convention == ClaimBridge.DayCountConvention.Actual365) return uint32(365 days);
        revert AccrualCredit_UnsupportedTerms(id);
    }

    function _fresh() private view returns (ReserveAccrualStorageLib.State storage s) {
        ReserveAccrualLib.requireFresh();
        return _enabled();
    }

    function _enabled() private view returns (ReserveAccrualStorageLib.State storage s) {
        s = ReserveAccrualStorageLib.state();
        if (!s.enabled) revert ReserveAccrualLib.ReserveAccrual_NotEnabled();
    }

    function _identity(ReserveAccrualStorageLib.State storage s, uint256 id) private view {
        if (!s.identities[id].known) revert AccrualCredit_Unknown(id);
    }

    function _caller(address expected) private view {
        if (msg.sender != expected) revert AccrualCredit_WrongCaller(expected, msg.sender);
    }
}
