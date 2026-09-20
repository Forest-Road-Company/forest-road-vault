// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccrualSchedule} from "./AccrualSchedule.sol";

/// @title AccrualBook
/// @notice Additive continuous loan-interest accounting, posting, issuance and risk cohorts.
/// @dev Embed Book in the reserve's ERC-7201 namespace. All methods are internal and perform no
///      external calls. The host validates funded contractual terms and owns authority, timestamps,
///      capacity admission, cash custody, registry posting and token issuance. Segment slopes are
///      integer normalized wei per second, so facility and aggregate amounts add exactly. The
///      remainder is recognized once at the scheduled endpoint, or cumulatively before an
///      authenticated lifecycle change. At most one year per technical segment bounds the interim
///      lag below 31,536,000 normalized wei per facility relative to its endpoint interpolation.
///      Technical segment boundaries do not themselves change a loan's contractual PIK basis.
library AccrualBook {
    using AccrualSchedule for AccrualSchedule.Heap;

    uint64 internal constant MAX_SEGMENT_SECONDS = 365 days;
    uint32 internal constant MAX_FACILITIES = 100;

    /// @notice An exactly additive integer rate and its settled value.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Clock {
        uint256 value;
        uint256 rate;
        uint64 at;
    }

    /// @notice Recognition and posting totals for one exposure grouping.
    struct Group {
        Clock clock;
        uint256 posted;
    }

    /// @notice A funded facility's cumulative recognition and current technical segment.
    /// @dev keys are distinct domain-separated class, borrower and jurisdiction identifiers.
    struct Entry {
        Clock clock;
        uint256 posted;
        uint256 segmentAmount;
        uint256 roundingCredited;
        uint64 start;
        uint64 end;
        bytes32[3] keys;
        bool known;
        bool registered;
        bool scheduled;
        bool pastDue;
    }

    /// @notice The reserve-local authoritative book.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Book {
        Clock total;
        mapping(uint256 facilityId => Entry) entries;
        mapping(bytes32 key => Group) groups;
        mapping(bytes32 classKey => Clock) pastDueUnposted;
        AccrualSchedule.Heap schedule;
        uint256 posted;
        uint256 seniorIssued;
        uint256 feeIssued;
        uint256 feeBaseGross;
        uint256 feeBaseAmount;
        uint32 registered;
        uint16 feeBps;
        bool initialized;
        uint256 unearned;
    }

    /// @notice A coherent view capped at the first unprocessed boundary.
    struct Snapshot {
        uint256 gross;
        uint256 fee;
        uint256 unposted;
        uint256 unissued;
        uint256 seniorUnissued;
        uint256 feeUnissued;
        uint64 accruedThrough;
        bool fresh;
    }

    /// @notice An uninitialized book cannot accept accounting changes.
    error AccrualBook_NotInitialized();
    /// @notice Reinitialization would discard existing obligations.
    error AccrualBook_AlreadyInitialized();
    /// @notice An interest fee cannot exceed the gross interest earned.
    error AccrualBook_InvalidFee(uint16 feeBps);
    /// @notice Issuance selects senior (1), protocol fee (2), or both (3), and no other mask.
    error AccrualBook_InvalidIssuanceLegs(uint8 legs);
    /// @notice The initial 100-facility admission envelope is full.
    error AccrualBook_Capacity();
    /// @notice Facility identifiers cannot be reused, including after retirement.
    error AccrualBook_KnownFacility(uint256 facilityId);
    /// @notice The facility is not registered in this book.
    error AccrualBook_UnknownFacility(uint256 facilityId);
    /// @notice A facility can have only one active technical segment.
    error AccrualBook_AlreadyScheduled(uint256 facilityId);
    /// @notice Technical segments must be positive and no longer than one year.
    error AccrualBook_InvalidSegment(uint64 start, uint64 end);
    /// @notice Exposure grouping identifiers must be nonzero and pairwise distinct.
    error AccrualBook_InvalidKeys();
    /// @notice An accounting clock cannot be read or changed backwards.
    error AccrualBook_TimeReversed(uint64 previous, uint64 requested);
    /// @notice Chronological maintenance must process the earliest boundary first.
    error AccrualBook_BoundaryPending(uint64 boundary, uint64 requested);
    /// @notice No scheduled boundary is due at the supplied time.
    error AccrualBook_NoBoundaryDue();
    /// @notice Retirement requires no scheduled segment and no unposted interest.
    error AccrualBook_UnsettledFacility(uint256 facilityId);
    /// @notice An arithmetic result would exceed uint256.
    error AccrualBook_Overflow();

    /// @notice Records the start of the book and the configured gross-interest fee.
    function initialize(Book storage self, uint64 at, uint16 feeBps) internal {
        if (self.initialized) revert AccrualBook_AlreadyInitialized();
        _validateFee(feeBps);
        self.total.at = at;
        self.feeBps = feeBps;
        self.initialized = true;
    }

    /// @notice Registers a proved funded facility and its immutable exposure identities.
    /// @dev Does not itself create interest, change principal or install a contractual schedule.
    function register(Book storage self, uint256 facilityId, bytes32[3] memory keys, uint64 at) internal {
        _requireInitialized(self);
        requireFresh(self, at);
        Entry storage e = self.entries[facilityId];
        if (e.known) revert AccrualBook_KnownFacility(facilityId);
        if (self.registered == MAX_FACILITIES) revert AccrualBook_Capacity();
        if (
            keys[0] == 0 || keys[1] == 0 || keys[2] == 0 || keys[0] == keys[1] || keys[0] == keys[2]
                || keys[1] == keys[2]
        ) revert AccrualBook_InvalidKeys();
        _settleTotal(self, at);
        e.clock.at = at;
        e.keys = keys;
        e.known = true;
        e.registered = true;
        ++self.registered;
    }

    /// @notice Starts a proved fixed-endpoint segment at the accounting frontier.
    /// @dev A host may continue a completed segment at its historical boundary during catch-up.
    ///      It must install the successor atomically with finishNext; no external callback may see
    ///      a missing successor. The endpoint excludes amounts recognized by earlier segments.
    function open(Book storage self, uint256 facilityId, uint256 amount, uint64 start, uint64 end) internal {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, start);
        if (e.scheduled) revert AccrualBook_AlreadyScheduled(facilityId);
        if (end <= start || end - start > MAX_SEGMENT_SECONDS) {
            revert AccrualBook_InvalidSegment(start, end);
        }
        _settleTotal(self, start);
        // Reserve the entire endpoint before admitting a slope. Otherwise several individually
        // valid endpoints could make every future NAV read overflow, after admission succeeded.
        if (amount > type(uint256).max - self.total.value - self.unearned) revert AccrualBook_Overflow();
        self.unearned += amount;
        uint256 rate = amount / (end - start);
        _changeRate(self, e, rate, true, start);
        e.start = start;
        e.end = end;
        e.segmentAmount = amount;
        e.roundingCredited = 0;
        e.scheduled = true;
        self.schedule.insert(facilityId, end);
    }

    /// @notice Reads effective recognition and remaining obligations without a facility scan.
    /// @dev A never-enabled book returns zero and fresh, for an explicit legacy/off state.
    function snapshot(Book storage self, uint64 at) internal view returns (Snapshot memory s) {
        s.accruedThrough = at;
        s.fresh = true;
        if (!self.initialized) return s;
        if (self.schedule.count() != 0) {
            uint64 boundary = self.schedule.peek().deadline;
            if (boundary <= at) {
                s.accruedThrough = boundary;
                s.fresh = false;
            }
        }
        s.gross = _preview(self.total, s.accruedThrough);
        s.fee = _add(self.feeBaseAmount, Math.mulDiv(s.gross - self.feeBaseGross, self.feeBps, 10_000));
        s.unposted = s.gross - self.posted;
        s.feeUnissued = s.fee - self.feeIssued;
        s.seniorUnissued = s.gross - s.fee - self.seniorIssued;
        s.unissued = _add(s.feeUnissued, s.seniorUnissued);
    }

    /// @notice Rejects a price-sensitive mutation when a boundary is due but unprocessed.
    function requireFresh(Book storage self, uint64 at) internal view {
        _requireTime(self, at);
        if (self.schedule.count() != 0 && self.schedule.peek().deadline == at) {
            revert AccrualBook_BoundaryPending(at, at);
        }
    }

    /// @notice Cumulative recognized interest for a single registered facility.
    function earned(Book storage self, uint256 facilityId, uint64 at) internal view returns (uint256) {
        Entry storage e = _entry(self, facilityId);
        return _preview(e.clock, _frontier(self, at));
    }

    /// @notice Unposted gross interest for one class, borrower or jurisdiction, in O(1).
    function groupUnposted(Book storage self, bytes32 key, uint64 at) internal view returns (uint256) {
        Group storage g = self.groups[key];
        return _preview(g.clock, _frontier(self, at)) - g.posted;
    }

    /// @notice Additional unposted interest on the live past-due cohort of one class.
    /// @dev The default manager adds its existing recorded-face risk to this amount. Posting
    ///      transfers the identical amount to that recorded face; clearing a cohort removes it.
    function pastDueInterest(Book storage self, bytes32 classKey, uint64 at) internal view returns (uint256) {
        return _preview(self.pastDueUnposted[classKey], _frontier(self, at));
    }

    /// @notice Settles already streamed growth without recognizing a new rounding remainder.
    function checkpoint(Book storage self, uint64 at) internal {
        _requireInitialized(self);
        _requireTime(self, at);
        _settleTotal(self, at);
    }

    /// @notice Recognizes the exact cumulative segment interpolation before a lifecycle action.
    /// @dev Idempotent at the same time and independent of earlier reconciliations. The host may
    ///      call this before an authenticated repayment/amendment/default. Ordinary keeper
    ///      checkpoints use checkpoint instead. This operation cannot change the segment's basis.
    function reconcile(Book storage self, uint256 facilityId, uint64 at) internal returns (uint256 extra) {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, at);
        if (!e.scheduled) return 0;
        uint64 elapsed = at - e.start;
        uint64 duration = e.end - e.start;
        uint256 remainder = e.segmentAmount % duration;
        uint256 cumulative = Math.mulDiv(remainder, elapsed, duration);
        extra = cumulative - e.roundingCredited;
        e.roundingCredited = cumulative;
        _credit(self, e, extra, at);
    }

    /// @notice Finishes the earliest due technical segment and recognizes its endpoint exactly.
    /// @return facilityId The facility whose successor the host must install or explicitly stop.
    /// @return boundary The deterministic endpoint timestamp, which may precede the current clock.
    /// @return extra The previously unrecognized rounding remainder credited at this boundary.
    function finishNext(Book storage self, uint64 at)
        internal
        returns (uint256 facilityId, uint64 boundary, uint256 extra)
    {
        _requireInitialized(self);
        if (self.schedule.count() == 0) revert AccrualBook_NoBoundaryDue();
        AccrualSchedule.Event memory next = self.schedule.peek();
        if (next.deadline > at) revert AccrualBook_NoBoundaryDue();
        facilityId = next.facilityId;
        boundary = next.deadline;
        extra = reconcile(self, facilityId, boundary);
        Entry storage e = self.entries[facilityId];
        _changeRate(self, e, e.clock.rate, false, boundary);
        self.schedule.pop();
        e.scheduled = false;
    }

    /// @notice Stops future recognition at an authenticated lifecycle timestamp.
    /// @dev Credits exact partial interpolation before removing the integer slope. Recognized
    ///      income is retained for posting and the native loss cascade; it is never cancelled.
    function stop(Book storage self, uint256 facilityId, uint64 at) internal returns (uint256 extra) {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, at);
        if (!e.scheduled) return 0;
        extra = reconcile(self, facilityId, at);
        uint256 remaining = e.segmentAmount - e.clock.rate * (at - e.start) - e.roundingCredited;
        _changeRate(self, e, e.clock.rate, false, at);
        self.unearned -= remaining;
        self.schedule.remove(facilityId);
        e.scheduled = false;
    }

    /// @notice Credits a proved positive contractual correction after a segment has stopped.
    /// @dev The host must derive the canonical discrepancy, prove its applicable bound (including
    ///      the possible one-scale-unit positive difference), and prevent replay. This internal
    ///      accounting primitive grants no external authority and does not validate signed terms.
    ///      The entry must be registered and unscheduled. Reserve the correction against complete
    ///      portfolio commitments before consuming it through the ordinary global, facility,
    ///      exposure-group and past-due credit path. No historical counter is reduced or reset.
    ///      Zero is permitted and advances the shared accounting clock without recognizing income.
    /// @param self The reserve-local book.
    /// @param facilityId The registered facility with no active segment.
    /// @param amount The independently proved additional gross entitlement.
    /// @param at The chronological correction timestamp; an in-progress boundary may equal it.
    function creditStoppedCorrection(Book storage self, uint256 facilityId, uint256 amount, uint64 at) internal {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, at);
        if (e.scheduled) revert AccrualBook_AlreadyScheduled(facilityId);
        _settleTotal(self, at);
        if (amount > type(uint256).max - self.total.value - self.unearned) revert AccrualBook_Overflow();
        self.unearned += amount;
        _credit(self, e, amount, at);
    }

    /// @notice Transfers a facility's recognized income to its recorded reserve/registry face.
    /// @dev The host must raise both recorded faces by returned amount in the same protected
    ///      operation. No token is minted here. This call does not reconcile new rounding income.
    function takePosting(Book storage self, uint256 facilityId, uint64 at) internal returns (uint256 amount) {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, at);
        _settleTotal(self, at);
        _checkpoint(e.clock, at);
        amount = e.clock.value - e.posted;
        e.posted = e.clock.value;
        self.posted = _add(self.posted, amount);
        for (uint256 i; i < 3; ++i) {
            Group storage g = self.groups[e.keys[i]];
            g.posted = _add(g.posted, amount);
        }
        if (e.pastDue) {
            Clock storage risk = self.pastDueUnposted[e.keys[0]];
            _checkpoint(risk, at);
            risk.value -= amount;
        }
    }

    /// @notice Transfers outstanding senior/fee obligations to physical token issuance.
    /// @dev The host must mint both returned amounts under its coherent snapshot/operation lock,
    ///      prove raw token deltas, and revert the entire operation on failure. Permission to call
    ///      this library is not permission to mint elsewhere. No rounding income is added here.
    function takeIssuance(Book storage self, uint64 at) internal returns (uint256 senior, uint256 fee) {
        return takeIssuance(self, 3, at);
    }

    /// @notice Transfers selected senior and/or protocol-fee obligations to physical issuance.
    /// @dev Unselected obligations remain virtual and their issued counters do not change. The
    ///      host must mint exactly the returned amounts under its coherent operation lock and
    ///      prove raw token deltas. Selection neither forfeits nor redirects the other claim.
    ///      This method advances the shared accounting clock even if selected amounts are zero.
    /// @param self The reserve-local book.
    /// @param legs Senior only (1), protocol fee only (2), or both (3).
    /// @param at The current chronological timestamp, with all due boundaries processed.
    /// @return senior The selected senior entitlement to issue, otherwise zero.
    /// @return fee The selected protocol-fee entitlement to issue, otherwise zero.
    function takeIssuance(Book storage self, uint8 legs, uint64 at) internal returns (uint256 senior, uint256 fee) {
        _requireInitialized(self);
        if (legs == 0 || legs > 3) revert AccrualBook_InvalidIssuanceLegs(legs);
        requireFresh(self, at);
        Snapshot memory s = snapshot(self, at);
        _settleTotal(self, at);
        if ((legs & 1) != 0) {
            senior = s.seniorUnissued;
            self.seniorIssued = _add(self.seniorIssued, senior);
        }
        if ((legs & 2) != 0) {
            fee = s.feeUnissued;
            self.feeIssued = _add(self.feeIssued, fee);
        }
    }

    /// @notice Changes the configured fee prospectively after settling the previous fee epoch.
    /// @dev Keeping the same rate is a no-op and cannot reset fractional fee rounding. The existing
    ///      vault performance fee is separate and consumes the resulting senior entitlement.
    function setFee(Book storage self, uint16 feeBps, uint64 at) internal {
        _requireInitialized(self);
        _validateFee(feeBps);
        requireFresh(self, at);
        if (self.feeBps == feeBps) return;
        Snapshot memory s = snapshot(self, at);
        _settleTotal(self, at);
        self.feeBaseGross = s.gross;
        self.feeBaseAmount = s.fee;
        self.feeBps = feeBps;
    }

    /// @notice Adds or removes a facility from the class's continuously growing past-due cohort.
    /// @dev Existing unposted interest joins/leaves along with the slope. The default-manager
    ///      host must keep recorded-face contributions synchronized with takePosting separately.
    function setPastDue(Book storage self, uint256 facilityId, bool enabled, uint64 at) internal {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, at);
        if (e.pastDue == enabled) return;
        _settleTotal(self, at);
        _checkpoint(e.clock, at);
        Clock storage risk = self.pastDueUnposted[e.keys[0]];
        _checkpoint(risk, at);
        uint256 unposted = e.clock.value - e.posted;
        if (enabled) {
            risk.value = _add(risk.value, unposted);
            risk.rate = _add(risk.rate, e.clock.rate);
        } else {
            risk.value -= unposted;
            risk.rate -= e.clock.rate;
        }
        e.pastDue = enabled;
    }

    /// @notice Frees an admission slot after the host proves the facility has been fully resolved.
    /// @dev Historical recognition, posting, exposure groups and the known-ID tombstone survive.
    function retire(Book storage self, uint256 facilityId, uint64 at) internal {
        Entry storage e = _entry(self, facilityId);
        _requireTime(self, at);
        if (e.scheduled || e.clock.value != e.posted) revert AccrualBook_UnsettledFacility(facilityId);
        _settleTotal(self, at);
        setPastDue(self, facilityId, false, at);
        e.registered = false;
        --self.registered;
    }

    function _changeRate(Book storage self, Entry storage e, uint256 rate, bool add, uint64 at) private {
        _settleTotal(self, at);
        self.total.rate = add ? _add(self.total.rate, rate) : self.total.rate - rate;
        _rate(e.clock, rate, add, at);
        for (uint256 i; i < 3; ++i) {
            _rate(self.groups[e.keys[i]].clock, rate, add, at);
        }
        if (e.pastDue) _rate(self.pastDueUnposted[e.keys[0]], rate, add, at);
    }

    function _credit(Book storage self, Entry storage e, uint256 amount, uint64 at) private {
        _settleTotal(self, at);
        _checkpoint(e.clock, at);
        self.unearned -= amount;
        self.total.value = _add(self.total.value, amount);
        e.clock.value = _add(e.clock.value, amount);
        for (uint256 i; i < 3; ++i) {
            Clock storage c = self.groups[e.keys[i]].clock;
            _checkpoint(c, at);
            c.value = _add(c.value, amount);
        }
        if (e.pastDue) {
            Clock storage risk = self.pastDueUnposted[e.keys[0]];
            _checkpoint(risk, at);
            risk.value = _add(risk.value, amount);
        }
    }

    function _rate(Clock storage c, uint256 amount, bool add, uint64 at) private {
        _checkpoint(c, at);
        c.rate = add ? _add(c.rate, amount) : c.rate - amount;
    }

    function _checkpoint(Clock storage c, uint64 at) private {
        c.value = _preview(c, at);
        c.at = at;
    }

    function _settleTotal(Book storage self, uint64 at) private {
        uint256 previous = self.total.value;
        _checkpoint(self.total, at);
        self.unearned -= self.total.value - previous;
    }

    function _preview(Clock storage c, uint64 at) private view returns (uint256 value) {
        if (at < c.at) revert AccrualBook_TimeReversed(c.at, at);
        uint256 elapsed = at - c.at;
        uint256 growth;
        unchecked {
            growth = c.rate * elapsed;
        }
        if (elapsed != 0 && growth / elapsed != c.rate) revert AccrualBook_Overflow();
        value = _add(c.value, growth);
    }

    function _frontier(Book storage self, uint64 at) private view returns (uint64) {
        if (self.schedule.count() != 0) {
            uint64 boundary = self.schedule.peek().deadline;
            if (boundary < at) return boundary;
        }
        return at;
    }

    function _requireTime(Book storage self, uint64 at) private view {
        if (at < self.total.at) revert AccrualBook_TimeReversed(self.total.at, at);
        if (self.schedule.count() != 0) {
            uint64 boundary = self.schedule.peek().deadline;
            if (boundary < at) revert AccrualBook_BoundaryPending(boundary, at);
        }
    }

    function _entry(Book storage self, uint256 facilityId) private view returns (Entry storage e) {
        _requireInitialized(self);
        e = self.entries[facilityId];
        if (!e.registered) revert AccrualBook_UnknownFacility(facilityId);
    }

    function _requireInitialized(Book storage self) private view {
        if (!self.initialized) revert AccrualBook_NotInitialized();
    }

    function _validateFee(uint16 feeBps) private pure {
        if (feeBps > 10_000) revert AccrualBook_InvalidFee(feeBps);
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a + b;
        }
        if (result < a) revert AccrualBook_Overflow();
    }
}
