// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AccrualIndex
/// @notice A clock-based sum of fixed rates with a carried fractional remainder.
/// @dev This arithmetic primitive schedules no contractual events and chooses no financial
///      policy. Its caller must checkpoint at each contractual boundary before changing rates.
///      Whole and fractional words are separate so a large principal need not fit after being
///      multiplied by the precision. Remainders survive checkpoints and rate changes.
library AccrualIndex {
    uint256 internal constant PRECISION = 1e27;

    /// @notice Whole normalized asset units and a fraction smaller than PRECISION, per second.
    struct Rate {
        uint256 whole;
        uint256 fraction;
    }

    /// @notice Cumulative earned units and the fixed rate applicable since the last checkpoint.
    /// @dev Embed in an ERC-7201 namespace; this library has no independent storage namespace.
    struct Index {
        uint256 accrued;
        uint256 remainder;
        Rate rate;
        uint64 lastAt;
        bool initialized;
    }

    /// @notice The index must be initialized before any use.
    error AccrualIndex_NotInitialized();
    /// @notice Initialization cannot discard an existing index.
    error AccrualIndex_AlreadyInitialized();
    /// @notice A contractual segment needs a nonzero duration.
    error AccrualIndex_ZeroDuration();
    /// @notice A supplied fractional rate is outside its normalized range.
    error AccrualIndex_InvalidFraction(uint256 fraction);
    /// @notice Checkpoints and reads cannot run backwards.
    error AccrualIndex_TimeReversed(uint64 lastAt, uint64 requestedAt);
    /// @notice An aggregate or its projected accrued value exceeds uint256.
    error AccrualIndex_Overflow();
    /// @notice A removed rate exceeds the aggregate rate.
    error AccrualIndex_RateUnderflow();

    /// @notice Opens an empty index at an explicit timestamp, including timestamp zero.
    function initialize(Index storage self, uint64 at) internal {
        if (self.initialized) revert AccrualIndex_AlreadyInitialized();
        self.lastAt = at;
        self.initialized = true;
    }

    /// @notice Computes a conservative rate for a fixed total over a fixed duration.
    /// @dev The rate error is less than 1/PRECISION unit per second. A caller that must end at
    ///      exactly `amount` must account for its endpoint remainder at the contractual boundary.
    ///      This function does not select a reserve scale or round a note's contractual interest.
    function rateFor(uint256 amount, uint64 duration) internal pure returns (Rate memory rate) {
        if (duration == 0) revert AccrualIndex_ZeroDuration();
        rate.whole = amount / duration;
        rate.fraction = Math.mulDiv(amount % duration, PRECISION, duration);
    }

    /// @notice Returns cumulative whole units and the carried fraction at `at`, without writes.
    function preview(Index storage self, uint64 at) internal view returns (uint256 whole, uint256 fraction) {
        if (!self.initialized) revert AccrualIndex_NotInitialized();
        if (at < self.lastAt) revert AccrualIndex_TimeReversed(self.lastAt, at);
        uint256 elapsed = uint256(at) - self.lastAt;
        // fraction < 1e27 and elapsed <= uint64.max, so this product and sum fit uint256.
        uint256 fractionalGrowth = self.rate.fraction * elapsed + self.remainder;
        uint256 wholeGrowth;
        unchecked {
            wholeGrowth = self.rate.whole * elapsed;
        }
        if (elapsed != 0 && wholeGrowth / elapsed != self.rate.whole) revert AccrualIndex_Overflow();
        whole = _add(self.accrued, _add(wholeGrowth, fractionalGrowth / PRECISION));
        fraction = fractionalGrowth % PRECISION;
    }

    /// @notice Persists the same cumulative value that preview reports.
    function checkpoint(Index storage self, uint64 at) internal returns (uint256 whole) {
        uint256 fraction;
        (whole, fraction) = preview(self, at);
        self.accrued = whole;
        self.remainder = fraction;
        self.lastAt = at;
    }

    /// @notice Adds a rate after settling every second earned under the previous aggregate.
    function addRate(Index storage self, Rate memory rate, uint64 at) internal {
        _validate(rate);
        checkpoint(self, at);
        uint256 fractions = self.rate.fraction + rate.fraction;
        self.rate.whole = _add(_add(self.rate.whole, rate.whole), fractions / PRECISION);
        self.rate.fraction = fractions % PRECISION;
    }

    /// @notice Removes a rate after settling every second earned under the previous aggregate.
    /// @dev A fractional borrow must decrement the whole rate; truncating each summand instead
    ///      would leave phantom accrual after the last facility was removed.
    function removeRate(Index storage self, Rate memory rate, uint64 at) internal {
        _validate(rate);
        checkpoint(self, at);
        uint256 whole = self.rate.whole;
        uint256 fraction = self.rate.fraction;
        if (whole < rate.whole || (whole == rate.whole && fraction < rate.fraction)) {
            revert AccrualIndex_RateUnderflow();
        }
        whole -= rate.whole;
        if (fraction < rate.fraction) {
            --whole;
            fraction += PRECISION;
        }
        self.rate.whole = whole;
        self.rate.fraction = fraction - rate.fraction;
    }

    /// @notice Removes a complete fixed-amount segment and settles its exact fractional endpoint.
    /// @dev The caller must establish that `rateFor(amount, duration)` ran for precisely the full
    ///      segment. A prematurely terminated segment must use removeRate instead. Truncating that
    ///      rate loses `mulmod(amount, PRECISION, duration)` fractional units over the full segment.
    ///      Add only this remainder: adding the apparent whole-unit shortfall while retaining the
    ///      index fraction would count almost an additional unit again on subsequent segments.
    function closeSegment(Index storage self, uint256 amount, uint64 duration, uint64 at) internal {
        removeRate(self, rateFor(amount, duration), at);
        uint256 fraction = self.remainder + mulmod(amount, PRECISION, duration);
        self.accrued = _add(self.accrued, fraction / PRECISION);
        self.remainder = fraction % PRECISION;
    }

    function _validate(Rate memory rate) private pure {
        if (rate.fraction >= PRECISION) revert AccrualIndex_InvalidFraction(rate.fraction);
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a + b;
        }
        if (result < a) revert AccrualIndex_Overflow();
    }
}
