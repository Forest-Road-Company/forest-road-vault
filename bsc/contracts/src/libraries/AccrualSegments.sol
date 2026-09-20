// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccrualMath} from "./AccrualMath.sol";

/// @title AccrualSegments
/// @notice Pure fixed-basis entitlement and bounded technical-segment planning.
/// @dev The host supplies authenticated fixed Actual/360 or Actual/365 terms and controls PIK
///      capitalization, cap changes and lifecycle authority. Technical splits never rebase PIK.
///      Cumulative endpoints round the original period's simple interest to the reserve grid;
///      adjacent differences telescope exactly. Interpolating those endpoints is a different
///      partial-time curve from rounding the original simple interest at that instant. Use
///      cumulative for authoritative contractual settlement and handle any discrepancy explicitly
///      in the host's backing/loss accounting. This library makes no such financial-policy choice.
///      It has no state, clock reads, roles, external calls or effects.
library AccrualSegments {
    /// @notice Maximum technical interpolation duration; contractual intervals may be longer.
    uint64 internal constant MAX_SEGMENT_SECONDS = 365 days;

    /// @notice Cached fixed terms for one contractual interest period.
    /// @dev cap is the maximum additional interest for this period, not a total loan balance.
    ///      A technical successor must retain this same basis and periodStart. The host alone
    ///      changes them at a proved contractual transition. Maturity may truncate periodEnd.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Terms {
        uint256 basis;
        uint256 yearSeconds;
        uint256 scale;
        uint256 cap;
        uint64 periodStart;
        uint64 periodEnd;
        uint64 maturity;
        uint16 rateBps;
    }

    /// @notice One bounded segment, its exact endpoint amounts and its termination information.
    /// @dev amount equals cumulativeEnd minus cumulativeStart. An already completed period or
    ///      exhausted cap returns end == start and amount == 0: the host must not open that marker
    ///      in AccrualBook. Otherwise end is strictly later and at most 365 days away. complete
    ///      means this period has no remaining entitlement after end; it does not retire the loan.
    ///      capHit is meaningful only when capReachable, and may be zero for a zero grid cap.
    struct Segment {
        uint256 cumulativeStart;
        uint256 cumulativeEnd;
        uint256 amount;
        uint64 start;
        uint64 end;
        uint64 capHit;
        bool capReachable;
        bool complete;
    }

    /// @notice A contractual period and its maturity must both lie after the original start.
    error AccrualSegments_InvalidPeriod(uint64 periodStart, uint64 periodEnd, uint64 maturity);

    /// @notice The requested timestamp lies outside this period's inclusive effective bounds.
    error AccrualSegments_TimeOutsidePeriod(uint64 at, uint64 periodStart, uint64 effectiveEnd);

    /// @notice Exact cumulative grid-rounded entitlement on the original frozen period basis.
    /// @dev Computes floor(min(simpleInterest(at - periodStart), cap) / scale) * scale using
    ///      AccrualMath's full-precision cap-before-grid calculation. This is the authoritative
    ///      pure curve for early payoff, amendment and default reconciliation by the host; it
    ///      must never be posted against a smaller book gross without matching reconciliation.
    /// @param terms Fixed authenticated terms; existing AccrualMath numeric bounds apply.
    /// @param at Inclusive timestamp from periodStart through min(periodEnd, maturity).
    /// @return amount Total entitlement since periodStart, not a per-checkpoint increment.
    function cumulative(Terms memory terms, uint64 at) internal pure returns (uint256 amount) {
        uint64 effectiveEnd = _effectiveEnd(terms);
        _validateTime(terms.periodStart, effectiveEnd, at);
        amount = _cumulative(terms, at);
    }

    /// @notice Plans the next technical segment without modifying the contractual basis.
    /// @dev Regular technical boundaries are anchored every 365 days to periodStart. A reachable
    ///      cap inserts H-1 and H, where H is the first integer timestamp attaining the whole-grid
    ///      cap. The final one-second segment prevents spreading the capped final increment over
    ///      a long interval. No loop or precomputation proportional to period duration is needed.
    /// @param terms Fixed terms, unchanged across technical successors.
    /// @param technicalStart Requested start within the inclusive effective period bounds. The
    ///      host must use the preceding endpoint except at an authorized lifecycle transition.
    /// @return segment Exact cumulative endpoint difference and bounded scheduling metadata.
    function plan(Terms memory terms, uint64 technicalStart) internal pure returns (Segment memory segment) {
        uint64 effectiveEnd = _effectiveEnd(terms);
        _validateTime(terms.periodStart, effectiveEnd, technicalStart);
        segment.start = technicalStart;
        segment.end = technicalStart;
        segment.cumulativeStart = _cumulative(terms, technicalStart);
        segment.cumulativeEnd = segment.cumulativeStart;

        uint256 gridCap = terms.cap - terms.cap % terms.scale;
        uint256 periodTotal = _cumulative(terms, effectiveEnd);
        if (periodTotal == gridCap) {
            segment.capReachable = true;
            if (gridCap == 0) {
                segment.capHit = terms.periodStart;
            } else {
                // Validation in _cumulative guarantees basis <= MAX/10_000 and rate <=10_000,
                // so their product fits. A positive reachable grid cap proves a positive product.
                // Reachability also proves the ceiling is <= effectiveEnd-periodStart (uint64).
                uint256 elapsed =
                    Math.mulDiv(gridCap, 10_000 * terms.yearSeconds, terms.basis * terms.rateBps, Math.Rounding.Ceil);
                segment.capHit = terms.periodStart + uint64(elapsed);
            }
        }

        if (technicalStart == effectiveEnd || (segment.capReachable && technicalStart >= segment.capHit)) {
            segment.complete = true;
            return segment;
        }

        uint64 remaining = effectiveEnd - technicalStart;
        uint64 technicalRemaining = MAX_SEGMENT_SECONDS - (technicalStart - terms.periodStart) % MAX_SEGMENT_SECONDS;
        segment.end = technicalStart + (remaining < technicalRemaining ? remaining : technicalRemaining);
        if (segment.capReachable) {
            uint64 capBoundary = segment.capHit;
            if (capBoundary - technicalStart > 1) --capBoundary;
            if (capBoundary < segment.end) segment.end = capBoundary;
        }
        segment.cumulativeEnd = _cumulative(terms, segment.end);
        segment.amount = segment.cumulativeEnd - segment.cumulativeStart;
        segment.complete = segment.end == effectiveEnd || (segment.capReachable && segment.end == segment.capHit);
    }

    /// @dev Validates positive contractual and maturity horizons without reading a clock.
    function _effectiveEnd(Terms memory terms) private pure returns (uint64 effectiveEnd) {
        if (terms.periodEnd <= terms.periodStart || terms.maturity <= terms.periodStart) {
            revert AccrualSegments_InvalidPeriod(terms.periodStart, terms.periodEnd, terms.maturity);
        }
        effectiveEnd = terms.periodEnd < terms.maturity ? terms.periodEnd : terms.maturity;
    }

    /// @dev Inclusive bounds also permit querying the original start and exact final endpoint.
    function _validateTime(uint64 periodStart, uint64 effectiveEnd, uint64 at) private pure {
        if (at < periodStart || at > effectiveEnd) {
            revert AccrualSegments_TimeOutsidePeriod(at, periodStart, effectiveEnd);
        }
    }

    /// @dev Called only after validating time bounds; AccrualMath validates every numeric term.
    function _cumulative(Terms memory terms, uint64 at) private pure returns (uint256) {
        return AccrualMath.periodAmount(
            terms.basis, terms.rateBps, at - terms.periodStart, terms.yearSeconds, terms.scale, terms.cap
        );
    }
}
