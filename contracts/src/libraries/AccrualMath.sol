// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AccrualMath — pure arithmetic on a fixed contractual interest basis
/// @notice Computes simple interest and cumulative fractions without changing a facility's basis.
/// @dev These primitives do not select an accrual architecture, capitalization schedule or rounding
///      policy. In particular, interpolating `periodAmount` is not identical to applying
///      `earnedInterest` at each instant: rounding the endpoint to a reserve unit changes the
///      intermediate curve. With a nonbinding cap their integer outputs differ by at most one reserve
///      unit; the unrounded endpoint interpolation differs by strictly less than one unit. A binding
///      cap can make the difference larger. Callers must choose the contractual policy explicitly.
///      No storage, clock reads, roles, external calls, fee allocation or token operations occur here.
library AccrualMath {
    /// @notice The supplied basis exceeds the registry's existing maximum safe exposure.
    /// @param basis The invalid normalized principal basis.
    error AccrualMath_BasisTooLarge(uint256 basis);

    /// @notice The annual nominal rate exceeds the protocol's existing 100% ceiling.
    /// @param rateBps The invalid annual rate, in basis points.
    error AccrualMath_RateTooLarge(uint16 rateBps);

    /// @notice Only the unambiguous Actual/360 and Actual/365 denominators are supported.
    /// @param yearSeconds The unsupported interest-year denominator, in seconds.
    error AccrualMath_UnsupportedYear(uint256 yearSeconds);

    /// @notice Uncapped earned interest cannot be represented in uint256.
    /// @dev `periodAmount` can still return a valid capped result for these otherwise valid terms.
    error AccrualMath_AmountOverflow();

    /// @notice A reserve unit must contain at least one normalized wei.
    error AccrualMath_ZeroScale();

    /// @notice A cumulative linear interval must have a positive duration.
    error AccrualMath_ZeroDuration();

    /// @notice The requested cumulative elapsed time lies beyond the fixed interval.
    /// @param elapsed The requested elapsed time, in seconds.
    /// @param duration The fixed interval duration, in seconds.
    error AccrualMath_ElapsedExceedsDuration(uint64 elapsed, uint64 duration);

    /// @notice A delta must run forward from its earlier cumulative checkpoint.
    /// @param previousElapsed The previous cumulative elapsed time, in seconds.
    /// @param elapsed The new cumulative elapsed time, in seconds.
    error AccrualMath_ReversedWindow(uint64 previousElapsed, uint64 elapsed);

    /// @notice Simple interest earned over cumulative elapsed time on an unchanged basis.
    /// @dev Floors once to normalized wei using full-precision multiplication and division. A zero
    ///      basis, rate or elapsed time returns zero, after validating all input bounds. The uint64
    ///      elapsed bound and the 10,000 bps ceiling make `rateBps * elapsed` safe in uint256.
    /// @param basis Frozen normalized principal, at most uint256-max / 10,000 as in the registry.
    /// @param rateBps Fixed annual nominal rate, from zero through 10,000 inclusive.
    /// @param elapsed Cumulative elapsed seconds on that basis; this function does not read the clock.
    /// @param yearSeconds Exactly 360 days or 365 days, as specified by the note.
    /// @return amount Earned interest, rounded down to normalized wei.
    function earnedInterest(uint256 basis, uint16 rateBps, uint64 elapsed, uint256 yearSeconds)
        internal
        pure
        returns (uint256 amount)
    {
        uint256 denominator = _validateTerms(basis, rateBps, yearSeconds);
        uint256 coefficient = uint256(rateBps) * elapsed;
        (uint256 high,) = Math.mul512(basis, coefficient);
        if (high >= denominator) revert AccrualMath_AmountOverflow();
        amount = Math.mulDiv(basis, coefficient, denominator);
    }

    /// @notice The fixed-period amount, capped and rounded down to a whole reserve unit.
    /// @dev Reproduces the existing PIK amount/cap/grid order. The cap is a maximum ADDITIONAL
    ///      amount, not a total facility-balance ceiling. A cap below one reserve unit yields zero;
    ///      deciding whether to advance a zero-amount period belongs to the servicing layer.
    ///      A capped result remains computable even when uncapped interest would exceed uint256.
    /// @param basis Frozen normalized principal, at most uint256-max / 10,000.
    /// @param rateBps Fixed annual nominal rate, from zero through 10,000 inclusive.
    /// @param duration Actual elapsed seconds in the fixed contractual period; zero is permitted.
    /// @param yearSeconds Exactly 360 days or 365 days.
    /// @param scale Normalized wei in one reserve unit; nonzero. Ethereum USDC uses 1e12, BSC uses 1.
    /// @param cap Maximum additional normalized interest recognizable for this period.
    /// @return amount The capped interest amount, a whole multiple of `scale`.
    function periodAmount(
        uint256 basis,
        uint16 rateBps,
        uint64 duration,
        uint256 yearSeconds,
        uint256 scale,
        uint256 cap
    ) internal pure returns (uint256 amount) {
        if (scale == 0) revert AccrualMath_ZeroScale();
        uint256 denominator = _validateTerms(basis, rateBps, yearSeconds);
        uint256 coefficient = uint256(rateBps) * duration;
        (uint256 high,) = Math.mul512(basis, coefficient);
        if (high >= denominator) {
            // The exact quotient exceeds every uint256 cap; do not evaluate an overflowing div.
            amount = cap;
        } else {
            amount = Math.mulDiv(basis, coefficient, denominator);
            if (amount > cap) amount = cap;
        }
        amount = (amount / scale) * scale;
    }

    /// @notice Cumulative linear fraction of an already fixed endpoint amount.
    /// @dev Floors once to normalized wei. At zero elapsed it returns zero; at the exact duration
    ///      it returns the endpoint, even for uint256-max amounts. This is an optional interpolation
    ///      primitive, not a declaration that grid-rounded endpoint interpolation is contractual.
    /// @param endpointAmount The fixed amount earned at the end of the interval.
    /// @param duration Positive interval duration, in seconds.
    /// @param elapsed Cumulative elapsed seconds, no greater than `duration`.
    /// @return amount The cumulative floor-rounded fraction of `endpointAmount`.
    function linearEarned(uint256 endpointAmount, uint64 duration, uint64 elapsed)
        internal
        pure
        returns (uint256 amount)
    {
        if (duration == 0) revert AccrualMath_ZeroDuration();
        if (elapsed > duration) revert AccrualMath_ElapsedExceedsDuration(elapsed, duration);
        amount = Math.mulDiv(endpointAmount, elapsed, duration);
    }

    /// @notice Newly earned amount between two cumulative linear checkpoints.
    /// @dev Subtracts cumulative floors, so arbitrary adjacent checkpoints telescope exactly.
    ///      Flooring `endpointAmount * (elapsed - previousElapsed) / duration` instead would discard
    ///      a fresh remainder at every call and make earned value depend on checkpoint frequency.
    /// @param endpointAmount The fixed amount earned at the end of the interval.
    /// @param duration Positive interval duration, in seconds.
    /// @param previousElapsed Earlier cumulative elapsed seconds.
    /// @param elapsed Later cumulative elapsed seconds, at most `duration`.
    /// @return amount Incremental earned amount between the two checkpoints.
    function linearDelta(uint256 endpointAmount, uint64 duration, uint64 previousElapsed, uint64 elapsed)
        internal
        pure
        returns (uint256 amount)
    {
        if (previousElapsed > elapsed) revert AccrualMath_ReversedWindow(previousElapsed, elapsed);
        amount =
            linearEarned(endpointAmount, duration, elapsed) - linearEarned(endpointAmount, duration, previousElapsed);
    }

    /// @dev Validates the existing admission bounds and returns the positive interest denominator.
    function _validateTerms(uint256 basis, uint16 rateBps, uint256 yearSeconds)
        private
        pure
        returns (uint256 denominator)
    {
        if (basis > type(uint256).max / 10_000) revert AccrualMath_BasisTooLarge(basis);
        if (rateBps > 10_000) revert AccrualMath_RateTooLarge(rateBps);
        if (yearSeconds != 360 days && yearSeconds != 365 days) {
            revert AccrualMath_UnsupportedYear(yearSeconds);
        }
        denominator = 10_000 * yearSeconds;
    }
}
