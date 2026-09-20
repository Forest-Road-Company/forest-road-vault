// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccrualBook} from "./AccrualBook.sol";
import {AccrualMath} from "./AccrualMath.sol";
import {AccrualSchedule} from "./AccrualSchedule.sol";
import {AccrualSegments} from "./AccrualSegments.sol";

/// @title AccrualLoans
/// @notice Reserve-local coordination of proved fixed cash and PIK loan terms.
/// @dev All functions are internal. The host authenticates funding, amendments, payments and
///      declaration times; locks callback-visible accounting; executes returned native posting,
///      receipt, rounding-loss and bridge work atomically; and emits the corresponding events.
///      This library makes no external calls or token/custody/registry writes. A caller must never
///      expose an external arbitrary timestamp, term, correction or loss setter around these APIs.
library AccrualLoans {
    using AccrualBook for AccrualBook.Book;
    using AccrualSchedule for AccrualSchedule.Heap;

    /// @notice Work reservations use an elapsed 365-day engineering year.
    uint256 internal constant YEAR = 365 days;
    /// @notice Conservative aggregate autonomous boundary envelope; no individual interval floor.
    uint256 internal constant MAX_ANNUAL_WORK = YEAR + 400;
    /// @notice Maximum chronological work returned by one keeper call.
    uint256 internal constant MAX_BATCH = 32;
    /// @notice The admitted AccrualMath basis domain also bounds every future contractual basis.
    uint256 internal constant MAX_BASIS = type(uint256).max / 10_000;

    /// @notice Embedded in the reserve's own ERC-7201 namespace.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct State {
        AccrualBook.Book book;
        mapping(uint256 facilityId => Loan) loans;
        uint256 annualWork;
    }

    /// @notice Contractual debt and the current arithmetic epoch, distinct from booked history.
    /// @dev unpaidInterest is canonical through the last closed technical segment. Current
    ///      unclosed interest is supplied by loanFace. Cash never adds unpaidInterest to basis.
    ///      Cap-paused loans retain active and their work reservation. nextCapitalization is zero
    ///      when no further signed PIK boundary fits before maturity; for cash it stores the signed
    ///      payment due date and is changed only by an authenticated amendment.
    struct Loan {
        AccrualSegments.Terms terms;
        uint256 principal;
        uint256 unpaidInterest;
        uint256 balanceCeiling;
        uint256 frozenPikBasis;
        uint256 segmentBookBase;
        uint256 segmentCumulativeStart;
        uint256 workWeight;
        uint64 nextCapitalization;
        uint64 paymentInterval;
        uint64 legalMaturity;
        uint64 lastSettlement;
        uint64 closureNonce;
        bool pik;
        bool active;
        bool configured;
        bool permanentlyStopped;
    }

    /// @notice Validated funded terms; rate/day-count support is explicit in this representation.
    /// @dev frozenPikBasis == 0 uses principal for ordinary funding. A nonzero PIK value is only
    ///      for an authenticated prospective migration of an existing frozen contractual cursor;
    ///      it does not import or recreate any historical interest in Book. Cash requires zero.
    struct Funding {
        uint256 principal;
        uint256 balanceCeiling;
        uint256 scale;
        uint256 yearSeconds;
        uint16 rateBps;
        uint64 fundedAt;
        uint64 nextPaymentDue;
        uint64 paymentInterval;
        uint64 maturity;
        bool pik;
        bytes32[3] keys;
        uint256 frozenPikBasis;
    }

    /// @notice Authenticated opening debt at terms.fundedAt, used as the migration cutoff.
    /// @dev recordedFace is the reserve face already backing issued tokens. Only the excess
    ///      of principal plus interest over that face enters Book as newly recognized income.
    ///      periodStart preserves the original contractual rounding cursor. The host must prove
    ///      every field, the legacy asset/identity mapping, the complete portfolio and stop status.
    ///      This internal routine authorizes no migration and performs no native ledger writes.
    struct Opening {
        Funding terms;
        uint256 recordedFace;
        uint256 interest;
        uint64 periodStart;
        bool permanentlyStopped;
    }

    /// @notice Forward terms proved by the bridge's existing signed amendment process.
    /// @dev nextPaymentDue replaces the future signed PIK boundary without capitalizing now.
    struct Amendment {
        uint256 balanceCeiling;
        uint256 yearSeconds;
        uint16 rateBps;
        uint64 nextPaymentDue;
        uint64 paymentInterval;
        uint64 maturity;
    }

    /// @notice Work that the host must execute once, within its protected accounting operation.
    /// @dev posting raises recorded reserve/registry face; roundingLoss then reduces that face
    ///      through the native loss policy. Receipt reductions are separate from those effects.
    ///      A checkpoint's posting is zero: its income remains virtually backed until post or a
    ///      lifecycle operation. capitalized is only a PIK debt reclassification, never new yield.
    struct LifecycleWork {
        uint256 facilityId;
        uint64 closureNonce;
        uint64 at;
        uint256 positiveCorrection;
        uint256 roundingLoss;
        uint256 posting;
        uint256 principalReduction;
        uint256 interestReduction;
        uint256 capitalized;
        uint64 previousDue;
        uint64 nextDue;
        bool stopped;
        bool repaid;
    }

    /// @notice No contractual metadata was configured for this identifier.
    error AccrualLoans_Unknown(uint256 facilityId);
    /// @notice Default/declaration or complete repayment cannot be reversed by an amendment.
    error AccrualLoans_Inactive(uint256 facilityId);
    /// @notice Funded principal, ceiling or optional PIK migration basis is invalid.
    error AccrualLoans_InvalidFunding();
    /// @notice Opening debt cannot reduce recognized backing or discard its contractual cursor.
    error AccrualLoans_InvalidOpening();
    /// @notice Signed due, interval and maturity must define a valid forward schedule.
    error AccrualLoans_InvalidSchedule();
    /// @notice A future balance ceiling exceeds the admitted math domain.
    error AccrualLoans_InvalidCeiling(uint256 ceiling);
    /// @notice The resulting aggregate annual work reservation exceeds the engineering ceiling.
    error AccrualLoans_WorkCapacity(uint256 requested);
    /// @notice A maintenance request must process between one and 32 boundaries.
    error AccrualLoans_BadBatch(uint256 maximum);
    /// @notice A payment must be positive and its combined legs must lie on the reserve grid.
    error AccrualLoans_BadPayment();
    /// @notice Existing PIK payment semantics require a zero separately designated interest leg.
    error AccrualLoans_PikInterestLeg();
    /// @notice A payment cannot discharge more than its contractual claim.
    error AccrualLoans_PaymentAboveDebt();
    /// @notice A closure failed the mathematically proved canonical/interpolation discrepancy bound.
    error AccrualLoans_CorrectionOutsideBound(uint256 discrepancy, uint256 scale);
    /// @notice Retirement requires the entire contractual debt to be discharged and stopped.
    error AccrualLoans_Unsettled(uint256 facilityId);
    /// @notice An amount or closure sequence would exceed its stored integer domain.
    error AccrualLoans_Overflow();

    /// @notice Initializes the reserve-local book at the host's accepted current timestamp.
    function initialize(State storage self, uint64 at, uint16 feeBps) internal {
        self.book.initialize(at, feeBps);
    }

    /// @notice Registers funded fixed-rate debt and opens its first eligible segment.
    /// @dev principal includes the host's proved financed-fee treatment. Both principal and the
    ///      entire future balance ceiling must fit AccrualMath's existing basis domain.
    function fund(State storage self, uint256 facilityId, Funding memory funded) internal {
        if (funded.principal == 0 || funded.principal > MAX_BASIS || funded.balanceCeiling < funded.principal) {
            revert AccrualLoans_InvalidFunding();
        }
        if (funded.frozenPikBasis > MAX_BASIS || (!funded.pik && funded.frozenPikBasis != 0)) {
            revert AccrualLoans_InvalidFunding();
        }
        _validateCeiling(funded.balanceCeiling);
        _validateSchedule(funded.fundedAt, funded.nextPaymentDue, funded.paymentInterval, funded.maturity);
        AccrualMath.periodAmount(
            funded.principal, funded.rateBps, 0, funded.yearSeconds, funded.scale, funded.balanceCeiling
        );
        self.book.register(facilityId, funded.keys, funded.fundedAt);
        Loan storage loan = self.loans[facilityId];
        loan.principal = funded.principal;
        loan.balanceCeiling = funded.balanceCeiling;
        loan.frozenPikBasis = funded.frozenPikBasis == 0 ? funded.principal : funded.frozenPikBasis;
        loan.nextCapitalization = funded.nextPaymentDue;
        loan.paymentInterval = funded.paymentInterval;
        loan.legalMaturity = funded.maturity;
        loan.lastSettlement = funded.fundedAt;
        loan.pik = funded.pik;
        loan.active = true;
        loan.configured = true;
        loan.terms.rateBps = funded.rateBps;
        loan.terms.yearSeconds = funded.yearSeconds;
        loan.terms.scale = funded.scale;
        _replaceWork(self, loan, _weight(funded.pik, funded.rateBps, funded.paymentInterval));
        _newEpoch(loan, funded.fundedAt);
        _open(self, facilityId, loan, funded.fundedAt);
    }

    /// @notice Imports one proved opening debt without charging already recognized principal twice.
    /// @dev Zero new income represents an opening already settled through the legacy system.
    ///      Active PIK inputs must already identify their next future contractual boundary;
    ///      zero is permitted for the final maturity stub. Historical capitalization and all
    ///      balance assertions are proved by the host, not reconstructed from a guessed history.
    ///      Future increments subtract the original period's cumulative entitlement at cutoff,
    ///      retaining fractional entitlement instead of restarting its rounding clock.
    function importOpening(State storage self, uint256 facilityId, Opening memory opening)
        internal
        returns (uint256 income)
    {
        Loan memory imported = _openingLoan(opening);
        uint64 at = opening.terms.fundedAt;
        self.book.register(facilityId, opening.terms.keys, at);
        self.loans[facilityId] = imported;
        Loan storage loan = self.loans[facilityId];
        income = _add(loan.principal, loan.unpaidInterest) - opening.recordedFace;
        if (income != 0) self.book.creditStoppedCorrection(facilityId, income, at);
        if (loan.active) {
            _replaceWork(self, loan, _weight(loan.pik, loan.terms.rateBps, loan.paymentInterval));
            _open(self, facilityId, loan, at);
        }
    }

    /// @dev Constructs the validated opening without mutating the book or its reservation totals.
    function _openingLoan(Opening memory opening) private pure returns (Loan memory loan) {
        Funding memory f = opening.terms;
        uint64 at = f.fundedAt;
        uint256 face = _add(f.principal, opening.interest);
        if (face == 0 || face > f.balanceCeiling || opening.recordedFace > face) {
            revert AccrualLoans_InvalidOpening();
        }
        _validateCeiling(f.balanceCeiling);
        if (f.frozenPikBasis > MAX_BASIS || (!f.pik && f.frozenPikBasis != 0)) {
            revert AccrualLoans_InvalidOpening();
        }
        bool active = !opening.permanentlyStopped && at < f.maturity;
        if (
            opening.periodStart > at || opening.periodStart >= f.maturity || f.paymentInterval == 0
                || (f.nextPaymentDue != 0 && (f.nextPaymentDue > f.maturity || f.paymentInterval > f.nextPaymentDue))
                || (active && f.pik && f.nextPaymentDue != 0 && f.nextPaymentDue <= at)
        ) revert AccrualLoans_InvalidOpening();
        uint256 basis = f.pik && f.frozenPikBasis != 0 ? f.frozenPikBasis : f.principal;
        uint64 periodEnd =
            f.pik && f.nextPaymentDue != 0 && f.nextPaymentDue > opening.periodStart ? f.nextPaymentDue : f.maturity;
        uint64 through = at < periodEnd ? at : periodEnd;
        uint256 previous = AccrualMath.periodAmount(
            basis, f.rateBps, through - opening.periodStart, f.yearSeconds, f.scale, type(uint256).max
        );
        loan.principal = f.principal;
        loan.unpaidInterest = opening.interest;
        loan.balanceCeiling = f.balanceCeiling;
        loan.frozenPikBasis = basis;
        loan.nextCapitalization = f.nextPaymentDue;
        loan.paymentInterval = f.paymentInterval;
        loan.legalMaturity = f.maturity;
        loan.lastSettlement = at;
        loan.pik = f.pik;
        loan.active = active;
        loan.configured = true;
        loan.permanentlyStopped = opening.permanentlyStopped;
        loan.terms = AccrualSegments.Terms({
            basis: basis,
            yearSeconds: f.yearSeconds,
            scale: f.scale,
            cap: _add(previous, f.balanceCeiling - face),
            periodStart: opening.periodStart,
            periodEnd: periodEnd,
            maturity: f.maturity,
            rateBps: f.rateBps
        });
    }

    /// @notice Processes at most 32 chronological boundaries and commits partial progress.
    /// @return work Fixed-capacity result array; only its first processed elements are populated.
    /// @return processed Number of populated work entries and completed boundaries.
    /// @return fresh Whether all due boundaries have been processed through at.
    function checkpoint(State storage self, uint64 at, uint256 maximum)
        internal
        returns (LifecycleWork[] memory work, uint256 processed, bool fresh)
    {
        if (maximum == 0 || maximum > MAX_BATCH) revert AccrualLoans_BadBatch(maximum);
        work = new LifecycleWork[](maximum);
        while (processed < maximum && self.book.schedule.count() != 0) {
            if (self.book.schedule.peek().deadline > at) break;
            (uint256 id, uint64 boundary,) = self.book.finishNext(at);
            Loan storage loan = _loan(self, id);
            LifecycleWork memory item = _work(id, boundary);
            uint256 earned = AccrualSegments.cumulative(loan.terms, boundary) - loan.segmentCumulativeStart;
            loan.unpaidInterest = _add(loan.unpaidInterest, earned);
            loan.lastSettlement = boundary;
            if (loan.pik && boundary == loan.nextCapitalization) {
                _capitalize(loan, item);
                loan.nextCapitalization = _nextDue(boundary, loan.paymentInterval, loan.legalMaturity);
                item.nextDue = loan.nextCapitalization;
                if (boundary < loan.legalMaturity) _newEpoch(loan, boundary);
            }
            if (boundary == loan.legalMaturity) {
                _deactivate(self, loan);
                item.stopped = true;
            } else {
                _open(self, id, loan, boundary);
            }
            work[processed++] = item;
        }
        fresh = self.book.schedule.count() == 0 || self.book.schedule.peek().deadline > at;
        if (fresh) self.book.checkpoint(at);
    }

    /// @notice Aligns exact contractual debt, returns native receipt work, then resumes forward.
    /// @dev The host proves the original attested legs and measured custody. A PIK principal leg
    ///      can discharge uncapitalized interest after capitalized principal; its interest leg is
    ///      zero. Cash legs discharge their own separate balances. Only the sum must lie on-grid.
    function repay(State storage self, uint256 facilityId, uint256 principalLeg, uint256 interestLeg, uint64 at)
        internal
        returns (LifecycleWork memory work)
    {
        Loan storage loan = _loan(self, facilityId);
        uint256 paid = _add(principalLeg, interestLeg);
        if (paid == 0 || paid % loan.terms.scale != 0) revert AccrualLoans_BadPayment();
        if (loan.pik && interestLeg != 0) revert AccrualLoans_PikInterestLeg();
        AccrualSegments.Segment memory prior = AccrualSegments.plan(loan.terms, loan.terms.periodStart);
        bool capPaused = prior.capReachable && prior.capHit <= at;
        work = _close(self, facilityId, loan, at);
        if (loan.pik) {
            if (principalLeg > _add(loan.principal, loan.unpaidInterest)) revert AccrualLoans_PaymentAboveDebt();
            work.principalReduction = principalLeg < loan.principal ? principalLeg : loan.principal;
            work.interestReduction = principalLeg - work.principalReduction;
        } else {
            if (principalLeg > loan.principal || interestLeg > loan.unpaidInterest) {
                revert AccrualLoans_PaymentAboveDebt();
            }
            work.principalReduction = principalLeg;
            work.interestReduction = interestLeg;
        }
        loan.principal -= work.principalReduction;
        loan.unpaidInterest -= work.interestReduction;
        if (loan.principal == 0 && loan.unpaidInterest == 0) {
            _deactivate(self, loan);
            loan.permanentlyStopped = true;
            work.stopped = true;
            work.repaid = true;
        } else if (loan.active && at < loan.legalMaturity) {
            // Replenishing a binding cap starts now; it cannot backfill clipped historical time.
            // Cash principal changes rebase only prospectively. Otherwise keep the original
            // epoch/curve, especially for a partial PIK principal payment in a frozen period.
            if (capPaused || (!loan.pik && principalLeg != 0) || at >= loan.terms.periodEnd) {
                _newEpoch(loan, at);
            } else {
                // No clipped time exists before the cap is reached. Retain the same cumulative
                // curve and expand its ceiling by the proved debt repayment instead of losing
                // the original period's fractional entitlement through an unnecessary restart.
                loan.terms.cap = _add(loan.terms.cap, paid);
            }
            _open(self, facilityId, loan, at);
        } else if (at >= loan.legalMaturity) {
            _deactivate(self, loan);
            work.stopped = true;
        }
    }

    /// @notice Applies authenticated forward terms after closing the old arithmetic at at.
    /// @dev The signed nextPaymentDue replaces the future PIK capitalization date. No principal
    ///      reclassification or PIK rebasing occurs merely because this amendment was signed.
    function amend(State storage self, uint256 facilityId, Amendment memory changed, uint64 at)
        internal
        returns (LifecycleWork memory work)
    {
        Loan storage loan = _loan(self, facilityId);
        if (loan.permanentlyStopped) revert AccrualLoans_Inactive(facilityId);
        _validateCeiling(changed.balanceCeiling);
        _validateSchedule(at, changed.nextPaymentDue, changed.paymentInterval, changed.maturity);
        AccrualMath.periodAmount(loan.terms.basis, changed.rateBps, 0, changed.yearSeconds, loan.terms.scale, 0);
        uint64 previousDue = loan.nextCapitalization;
        work = _close(self, facilityId, loan, at);
        _replaceWork(self, loan, _weight(loan.pik, changed.rateBps, changed.paymentInterval));
        loan.active = true;
        work.previousDue = previousDue;
        work.nextDue = changed.nextPaymentDue;
        loan.nextCapitalization = changed.nextPaymentDue;
        loan.paymentInterval = changed.paymentInterval;
        loan.legalMaturity = changed.maturity;
        loan.balanceCeiling = changed.balanceCeiling;
        loan.terms.rateBps = changed.rateBps;
        loan.terms.yearSeconds = changed.yearSeconds;
        _newEpoch(loan, at);
        _open(self, facilityId, loan, at);
    }

    /// @notice Aligns and permanently stops accrual before the host's default/acceleration action.
    /// @dev The host posts the returned face and resolves any rounding loss before default snapshots.
    function stop(State storage self, uint256 facilityId, uint64 at) internal returns (LifecycleWork memory work) {
        Loan storage loan = _loan(self, facilityId);
        work = _close(self, facilityId, loan, at);
        _deactivate(self, loan);
        loan.permanentlyStopped = true;
        work.stopped = true;
    }

    /// @notice Services signed PIK dates that have no positive queued interest work.
    /// @dev Scheduled loans, cash loans, inactive loans and future dormant dates are unchanged.
    ///      Existing unpaid PIK is capitalized once; only proven zero-income successors are
    ///      skipped arithmetically. The shared Book checkpoint stores already-visible growth
    ///      without adding entitlement, posting, closing/reopening a segment or minting yield.
    ///      The host applies only a nonzero later signed nextDue to its bridge and uses legal
    ///      maturity as the balloon deadline once no signed capitalization boundary remains.
    function serviceDormant(State storage self, uint256 facilityId, uint64 at)
        internal
        returns (LifecycleWork memory work)
    {
        Loan storage loan = _loan(self, facilityId);
        self.book.requireFresh(at);
        work = _work(facilityId, at);
        if (self.book.entries[facilityId].scheduled || !loan.active || !loan.pik) return work;
        if (at < loan.legalMaturity && (loan.nextCapitalization == 0 || loan.nextCapitalization > at)) return work;
        self.book.checkpoint(at);
        _settleDormantPik(loan, work, at);
        loan.lastSettlement = at;
        if (at >= loan.legalMaturity) {
            _deactivate(self, loan);
            work.stopped = true;
        }
    }

    /// @notice Takes already-recognized posting work without resetting a contractual curve.
    function post(State storage self, uint256 facilityId, uint64 at) internal returns (uint256 amount) {
        _loan(self, facilityId);
        self.book.requireFresh(at);
        amount = self.book.takePosting(facilityId, at);
    }

    /// @notice Retires a completely paid, stopped, posted facility while retaining its known-ID tombstone.
    function retire(State storage self, uint256 facilityId, uint64 at) internal {
        Loan storage loan = _loan(self, facilityId);
        if (loan.active || loan.principal != 0 || loan.unpaidInterest != 0) revert AccrualLoans_Unsettled(facilityId);
        self.book.retire(facilityId, at);
    }

    /// @notice Exact contractual face through the book's coherent current frontier, in O(1).
    /// @dev This is not a replacement for the booked accounting carrier used by reserve NAV.
    function loanFace(State storage self, uint256 facilityId, uint64 at)
        internal
        view
        returns (uint256 principal, uint256 interest, uint64 accruedThrough)
    {
        Loan storage loan = _loan(self, facilityId);
        accruedThrough = self.book.snapshot(at).accruedThrough;
        principal = loan.principal;
        interest = loan.unpaidInterest;
        if (self.book.entries[facilityId].scheduled) {
            interest =
                _add(interest, AccrualSegments.cumulative(loan.terms, accruedThrough) - loan.segmentCumulativeStart);
        }
        if (
            loan.active && loan.pik && !self.book.entries[facilityId].scheduled && loan.nextCapitalization != 0
                && loan.nextCapitalization <= accruedThrough && loan.nextCapitalization <= loan.legalMaturity
        ) {
            principal = _add(principal, interest);
            interest = 0;
        }
    }

    /// @dev Stops the local interpolation, aligns the canonical contribution and consumes posting.
    function _close(State storage self, uint256 id, Loan storage loan, uint64 at)
        private
        returns (LifecycleWork memory work)
    {
        self.book.requireFresh(at);
        work = _work(id, at);
        if (loan.closureNonce == type(uint64).max) revert AccrualLoans_Overflow();
        work.closureNonce = ++loan.closureNonce;
        if (self.book.entries[id].scheduled) {
            self.book.stop(id, at);
            uint256 recognized = self.book.earned(id, at) - loan.segmentBookBase;
            uint256 canonical = AccrualSegments.cumulative(loan.terms, at) - loan.segmentCumulativeStart;
            if (canonical > recognized) {
                work.positiveCorrection = canonical - recognized;
                if (work.positiveCorrection > loan.terms.scale) {
                    revert AccrualLoans_CorrectionOutsideBound(work.positiveCorrection, loan.terms.scale);
                }
                self.book.creditStoppedCorrection(id, work.positiveCorrection, at);
            } else {
                work.roundingLoss = recognized - canonical;
                if (work.roundingLoss >= loan.terms.scale) {
                    revert AccrualLoans_CorrectionOutsideBound(work.roundingLoss, loan.terms.scale);
                }
            }
            loan.unpaidInterest = _add(loan.unpaidInterest, canonical);
        } else if (loan.active) {
            _settleDormantPik(loan, work, at);
        }
        work.posting = self.book.takePosting(id, at);
        loan.lastSettlement = at;
    }

    /// @dev Opens only useful positive-entitlement work; zero-rate/cap-paused periods do not loop.
    function _open(State storage self, uint256 id, Loan storage loan, uint64 at) private {
        if (!loan.active || at >= loan.legalMaturity) return;
        if (loan.terms.rateBps == 0 || (!loan.pik && loan.terms.basis == 0)) return;
        // An imported zero-basis PIK period can still capitalize existing unpaid interest,
        // creating a positive basis at its next signed date. Keep that boundary scheduled.
        // A dormant PIK period is skipped only if both its remaining entitlement and every
        // unchanged successor are zero. The prospective next basis includes existing unpaid
        // income, so a pending capitalization that enables a positive next coupon is scheduled.
        // A longer first period is not mistaken for a zero regular short coupon.
        if (loan.pik) {
            uint256 remaining = AccrualSegments.cumulative(loan.terms, loan.terms.periodEnd)
                - AccrualSegments.cumulative(loan.terms, at);
            uint256 nextBasis = _add(_add(loan.principal, loan.unpaidInterest), remaining);
            uint256 room = nextBasis < loan.balanceCeiling ? loan.balanceCeiling - nextBasis : 0;
            if (
                remaining == 0
                    && AccrualMath.periodAmount(
                        nextBasis, loan.terms.rateBps, loan.paymentInterval, loan.terms.yearSeconds, loan.terms.scale, room
                    ) == 0
            ) return;
        }
        if (!loan.pik && AccrualSegments.cumulative(loan.terms, loan.legalMaturity) == 0) return;
        AccrualSegments.Segment memory segment = AccrualSegments.plan(loan.terms, at);
        if (segment.end == at) return;
        loan.segmentBookBase = self.book.earned(id, at);
        loan.segmentCumulativeStart = segment.cumulativeStart;
        self.book.open(id, segment.amount, at, segment.end);
    }

    /// @dev A new arithmetic epoch preserves the signed PIK basis while refreshing available room.
    function _newEpoch(Loan storage loan, uint64 at) private {
        loan.terms.basis = loan.pik ? loan.frozenPikBasis : loan.principal;
        loan.terms.periodStart = at;
        loan.terms.periodEnd = loan.pik && loan.nextCapitalization != 0 ? loan.nextCapitalization : loan.legalMaturity;
        loan.terms.maturity = loan.legalMaturity;
        uint256 face = _add(loan.principal, loan.unpaidInterest);
        loan.terms.cap = face < loan.balanceCeiling ? loan.balanceCeiling - face : 0;
    }

    /// @dev A paused cap or zero-rate interval has no unseen interest recurrence. Capitalize its
    ///      existing PIK U once, then skip only further zero-income dates arithmetically in O(1).
    function _settleDormantPik(Loan storage loan, LifecycleWork memory work, uint64 at) private {
        uint64 due = loan.nextCapitalization;
        if (!loan.pik || due == 0 || due > at || due > loan.legalMaturity) return;
        _capitalize(loan, work);
        uint64 through = at < loan.legalMaturity ? at : loan.legalMaturity;
        uint256 count = uint256(through - due) / loan.paymentInterval + 1;
        uint256 remaining = uint256(loan.legalMaturity - due) / loan.paymentInterval;
        loan.nextCapitalization = count > remaining ? 0 : due + uint64(count * loan.paymentInterval);
        work.nextDue = loan.nextCapitalization;
    }

    /// @dev Reclassifies already accrued PIK debt; does not recognize/post/mint it again.
    function _capitalize(Loan storage loan, LifecycleWork memory work) private {
        work.previousDue = loan.nextCapitalization;
        work.capitalized = loan.unpaidInterest;
        loan.principal = _add(loan.principal, loan.unpaidInterest);
        loan.unpaidInterest = 0;
        loan.frozenPikBasis = loan.principal;
    }

    /// @dev Returns only a real next contractual capitalization date, never inventing maturity compounding.
    function _nextDue(uint64 previous, uint64 interval, uint64 maturity) private pure returns (uint64) {
        return interval <= maturity - previous ? previous + interval : 0;
    }

    /// @dev Reservations persist during cap pauses and are released only on permanent stopping.
    function _deactivate(State storage self, Loan storage loan) private {
        if (loan.active) {
            _replaceWork(self, loan, 0);
            loan.active = false;
        }
    }

    /// @dev Conservative autonomous annual work plus phase/technical/cap allowance, per active loan.
    function _weight(bool pik, uint16 rateBps, uint64 interval) private pure returns (uint256) {
        if (rateBps == 0) return 0;
        return pik ? YEAR / interval + (YEAR % interval == 0 ? 0 : 1) + 4 : 4;
    }

    /// @dev Replacement is atomic: a rejected amendment preserves the prior reservation and terms.
    function _replaceWork(State storage self, Loan storage loan, uint256 replacement) private {
        uint256 requested = self.annualWork - loan.workWeight + replacement;
        if (requested > MAX_ANNUAL_WORK) revert AccrualLoans_WorkCapacity(requested);
        self.annualWork = requested;
        loan.workWeight = replacement;
    }

    /// @dev Validates signed funding/amendment dates without imposing a minimum individual interval.
    function _validateSchedule(uint64 at, uint64 due, uint64 interval, uint64 maturity) private pure {
        if (interval == 0 || due <= at || due > maturity || interval > due || maturity <= at) {
            revert AccrualLoans_InvalidSchedule();
        }
    }

    /// @dev Every future PIK basis must remain inside the already-admitted math domain.
    function _validateCeiling(uint256 ceiling) private pure {
        if (ceiling > MAX_BASIS) revert AccrualLoans_InvalidCeiling(ceiling);
    }

    /// @dev Lookup is separate from Book registration so retired contractual metadata remains readable.
    function _loan(State storage self, uint256 facilityId) private view returns (Loan storage loan) {
        loan = self.loans[facilityId];
        if (!loan.configured) revert AccrualLoans_Unknown(facilityId);
    }

    /// @dev Initializes a result without any externally supplied posting or correction amount.
    function _work(uint256 id, uint64 at) private pure returns (LifecycleWork memory work) {
        work.facilityId = id;
        work.at = at;
    }

    /// @dev Uses a stable named error instead of a generic arithmetic panic at capacity bounds.
    function _add(uint256 first, uint256 second) private pure returns (uint256) {
        if (second > type(uint256).max - first) revert AccrualLoans_Overflow();
        return first + second;
    }
}
