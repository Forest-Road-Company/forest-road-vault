// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccrualMath} from "./AccrualMath.sol";

/// @title AccrualCeiling
/// @notice Conservative capacity for the full remaining signed PIK obligation.
/// @dev This bound reserves arithmetic space; it never determines the interest actually earned.
///      The first coupon uses the frozen basis. Successors compound only on signed boundaries.
///      Rounding upward covers cumulative rounding carried through a migration cutoff and every
///      downward-rounded contractual coupon. Exponentiation by squaring takes at most 64 steps.
library AccrualCeiling {
    uint256 internal constant MAX_FACE = type(uint256).max / 10_000;
    uint256 internal constant PRECISION = 1e27;

    /// @notice Current exact face and the authenticated remaining fixed-rate schedule.
    struct Terms {
        uint256 face;
        uint256 frozenBasis;
        uint256 scale;
        uint256 yearSeconds;
        uint16 rateBps;
        uint64 at;
        uint64 nextCapitalization;
        uint64 paymentInterval;
        uint64 maturity;
    }

    /// @notice The conservative reservation exceeds the existing accounting domain.
    error AccrualCeiling_ExposureCapacity();
    /// @notice A remaining schedule must start before maturity and its first future boundary.
    error AccrualCeiling_InvalidSchedule();

    /// @notice Bounds full future face without walking contractual payment dates.
    /// @param p Exact current debt, frozen first basis and signed future terms.
    /// @return ceiling Upper bound on every remaining face, including uncapitalized maturity interest.
    function pik(Terms memory p) internal pure returns (uint256 ceiling) {
        if (p.face > MAX_FACE) revert AccrualCeiling_ExposureCapacity();
        AccrualMath.earnedInterest(p.frozenBasis, p.rateBps, 0, p.yearSeconds);
        if (p.scale == 0) revert AccrualMath.AccrualMath_ZeroScale();
        uint64 firstEnd = p.nextCapitalization == 0 ? p.maturity : p.nextCapitalization;
        if (p.paymentInterval == 0 || firstEnd <= p.at || firstEnd > p.maturity) {
            revert AccrualCeiling_InvalidSchedule();
        }
        if (p.rateBps == 0) return p.face;
        uint256 denominator = 10_000 * p.yearSeconds;
        if (p.scale > type(uint256).max / denominator) revert AccrualCeiling_ExposureCapacity();
        // floor(x + y) - floor(x) <= ceil(y), on the native reserve grid. This covers a
        // migration's retained fractional entitlement without knowing its historical cursor.
        uint256 firstUnits = _mulUp(p.frozenBasis, uint256(p.rateBps) * (firstEnd - p.at), denominator * p.scale);
        if (firstUnits > (MAX_FACE - p.face) / p.scale) revert AccrualCeiling_ExposureCapacity();
        ceiling = p.face + firstUnits * p.scale;
        uint64 remaining = p.maturity - firstEnd;
        uint64 count = remaining / p.paymentInterval;
        if (count != 0) {
            uint256 factor = PRECISION
                + Math.mulDiv(uint256(p.rateBps) * p.paymentInterval, PRECISION, denominator, Math.Rounding.Ceil);
            while (count != 0) {
                if (count & 1 != 0) ceiling = _mulUp(ceiling, factor, PRECISION);
                count >>= 1;
                if (count != 0) factor = _mulUp(factor, factor, PRECISION);
            }
        }
        // The final stub earns simple interest on the last capitalized basis.
        uint64 stub = remaining % p.paymentInterval;
        uint256 tail = _mulUp(ceiling, uint256(p.rateBps) * stub, denominator);
        if (tail > MAX_FACE - ceiling) revert AccrualCeiling_ExposureCapacity();
        return ceiling + tail;
    }

    /// @dev Refuse an unrepresentable bound with a named error before full-precision division.
    function _mulUp(uint256 x, uint256 y, uint256 denominator) private pure returns (uint256 result) {
        (uint256 high,) = Math.mul512(x, y);
        if (high >= denominator) revert AccrualCeiling_ExposureCapacity();
        result = Math.mulDiv(x, y, denominator);
        if (result > MAX_FACE) revert AccrualCeiling_ExposureCapacity();
        if (mulmod(x, y, denominator) != 0) {
            if (result == MAX_FACE) revert AccrualCeiling_ExposureCapacity();
            ++result;
        }
    }
}
