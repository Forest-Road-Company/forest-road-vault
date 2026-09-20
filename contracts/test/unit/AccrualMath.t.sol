// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AccrualMath} from "../../src/libraries/AccrualMath.sol";

/// @dev External wrappers let tests assert a library failure's exact revert data.
contract AccrualMathHarness {
    function earnedInterest(uint256 basis, uint16 rateBps, uint64 elapsed, uint256 yearSeconds)
        external
        pure
        returns (uint256)
    {
        return AccrualMath.earnedInterest(basis, rateBps, elapsed, yearSeconds);
    }

    function periodAmount(
        uint256 basis,
        uint16 rateBps,
        uint64 duration,
        uint256 yearSeconds,
        uint256 scale,
        uint256 cap
    ) external pure returns (uint256) {
        return AccrualMath.periodAmount(basis, rateBps, duration, yearSeconds, scale, cap);
    }

    function linearEarned(uint256 endpointAmount, uint64 duration, uint64 elapsed) external pure returns (uint256) {
        return AccrualMath.linearEarned(endpointAmount, duration, elapsed);
    }

    function linearDelta(uint256 endpointAmount, uint64 duration, uint64 previousElapsed, uint64 elapsed)
        external
        pure
        returns (uint256)
    {
        return AccrualMath.linearDelta(endpointAmount, duration, previousElapsed, elapsed);
    }
}

/// @title AccrualMathTest — independent arithmetic, bounds and checkpoint-cadence properties
/// @dev Run every fuzz property at 10,000 runs using the repository's heavy profile. These tests
///      intentionally use direct bounded integer arithmetic and quotient/remainder decomposition
///      as references, rather than calling Math.mulDiv or repeating its implementation.
contract AccrualMathTest is Test {
    AccrualMathHarness internal subject;

    function setUp() public {
        subject = new AccrualMathHarness();
    }

    function test_actual360And365UseDifferentContractualDenominators() public view {
        assertEq(subject.earnedInterest(360_000e18, 1400, 30 days, 360 days), 4200e18);
        assertEq(subject.earnedInterest(365_000e18, 1400, 30 days, 365 days), 4200e18);
        assertLt(
            subject.earnedInterest(1_000_000e18, 1400, 30 days, 365 days),
            subject.earnedInterest(1_000_000e18, 1400, 30 days, 360 days)
        );
    }

    function test_zeroInputsEarnNothing() public view {
        assertEq(subject.earnedInterest(0, 1400, 30 days, 360 days), 0);
        assertEq(subject.earnedInterest(1_000_000e18, 0, 30 days, 360 days), 0);
        assertEq(subject.earnedInterest(1_000_000e18, 1400, 0, 360 days), 0);
        assertEq(subject.periodAmount(1_000_000e18, 1400, 0, 360 days, 1e12, type(uint256).max), 0);
        assertEq(subject.periodAmount(1_000_000e18, 1400, 30 days, 360 days, 1e12, 0), 0);
    }

    function test_maximumLegacyBasisAndElapsedDoNotOverflow() public view {
        uint256 expected = uint256(type(uint176).max) * 10_000 * type(uint64).max / (10_000 * 360 days);
        assertEq(subject.earnedInterest(type(uint176).max, 10_000, type(uint64).max, 360 days), expected);
    }

    function test_basisAboveLegacyCursorWidthIsNotTruncated() public view {
        uint256 basis = uint256(type(uint176).max) + 1;
        assertEq(subject.earnedInterest(basis, 10_000, 360 days, 360 days), basis);
        basis = type(uint256).max / 10_000;
        assertEq(subject.earnedInterest(basis, 10_000, 365 days, 365 days), basis);
    }

    function test_uncappedOverflowHasNamedErrorButCappedAmountRemainsAvailable() public {
        uint256 basis = type(uint256).max / 10_000;
        vm.expectRevert(AccrualMath.AccrualMath_AmountOverflow.selector);
        subject.earnedInterest(basis, 10_000, type(uint64).max, 360 days);
        assertEq(subject.periodAmount(basis, 10_000, type(uint64).max, 360 days, 1e12, 100e18 + 777), 100e18);
        assertEq(
            subject.periodAmount(basis, 10_000, type(uint64).max, 360 days, 1, type(uint256).max), type(uint256).max
        );
    }

    function test_exactUint256OverflowBoundaryPreservesCappedServiceability() public {
        uint256 basis = type(uint256).max / 10_000;
        uint64 lastRepresentableDuration = uint64(360 days) * 10_000;
        assertEq(subject.earnedInterest(basis, 10_000, lastRepresentableDuration, 360 days), basis * 10_000);
        vm.expectRevert(AccrualMath.AccrualMath_AmountOverflow.selector);
        subject.earnedInterest(basis, 10_000, lastRepresentableDuration + 1, 360 days);
        assertEq(subject.periodAmount(basis, 10_000, lastRepresentableDuration + 1, 360 days, 1, 100e18), 100e18);
    }

    function test_rateAtCeilingIsSimpleInterestOnFrozenBasis() public view {
        assertEq(subject.earnedInterest(1_000_000e18, 10_000, 360 days, 360 days), 1_000_000e18);
        assertEq(subject.earnedInterest(1_000_000e18, 10_000, 720 days, 360 days), 2_000_000e18);
    }

    function test_firstPartialPeriodChargesOnlyElapsedFundingTime() public view {
        uint256 amount = subject.periodAmount(1_000_000e18, 1400, 5 days, 360 days, 1e12, type(uint256).max);
        assertEq(amount, 1_944_444444e12);
        assertLt(amount, subject.periodAmount(1_000_000e18, 1400, 30 days, 360 days, 1e12, type(uint256).max));
    }

    function test_periodCapsAdditionalAmountAndFloorsToReserveGrid() public view {
        assertEq(subject.periodAmount(360_000e18, 1400, 30 days, 360 days, 1e12, 100e18 + 777), 100e18);
        assertEq(subject.periodAmount(360_000e18, 1400, 30 days, 360 days, 1, 100e18 + 777), 100e18 + 777);
        assertEq(subject.periodAmount(360_000e18, 1400, 30 days, 360 days, 1e12, 1e12 - 1), 0);
        assertEq(subject.periodAmount(1, 1, 1, 360 days, 1, type(uint256).max), 0);
    }

    function test_periodRejectsZeroScale() public {
        vm.expectRevert(AccrualMath.AccrualMath_ZeroScale.selector);
        subject.periodAmount(1e18, 1400, 30 days, 360 days, 0, type(uint256).max);
    }

    function test_earnedRejectsBasisBeyondRegistryExposureBound() public {
        uint256 invalid = type(uint256).max / 10_000 + 1;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_BasisTooLarge.selector, invalid));
        subject.earnedInterest(invalid, 1400, 30 days, 360 days);
    }

    function test_earnedRejectsRateAboveExistingCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, uint16(10_001)));
        subject.earnedInterest(1e18, 10_001, 30 days, 360 days);
    }

    function test_earnedRejectsAmbiguousOrZeroYearEvenForZeroIncome() public {
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, uint256(0)));
        subject.earnedInterest(0, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, uint256(366 days)));
        subject.earnedInterest(1e18, 1400, 30 days, 366 days);
    }

    function test_linearEndpointsAreExactAtFullUint256Width() public view {
        assertEq(subject.linearEarned(type(uint256).max, type(uint64).max, 0), 0);
        assertEq(subject.linearEarned(type(uint256).max, type(uint64).max, type(uint64).max), type(uint256).max);
        assertEq(subject.linearEarned(0, type(uint64).max, type(uint64).max), 0);
        assertEq(subject.linearEarned(type(uint256).max, 2, 1), type(uint256).max / 2);
    }

    function test_linearRejectsZeroDurationEvenForZeroAmount() public {
        vm.expectRevert(AccrualMath.AccrualMath_ZeroDuration.selector);
        subject.linearEarned(0, 0, 0);
    }

    function test_linearRejectsElapsedBeyondEndpoint() public {
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMath.AccrualMath_ElapsedExceedsDuration.selector, uint64(31), uint64(30))
        );
        subject.linearEarned(1e18, 30, 31);
    }

    function test_deltaRejectsReversedWindow() public {
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_ReversedWindow.selector, uint64(20), uint64(10)));
        subject.linearDelta(1e18, 30, 20, 10);
    }

    function test_deltaRejectsZeroDurationAndOutOfBoundsEnd() public {
        vm.expectRevert(AccrualMath.AccrualMath_ZeroDuration.selector);
        subject.linearDelta(0, 0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMath.AccrualMath_ElapsedExceedsDuration.selector, uint64(31), uint64(30))
        );
        subject.linearDelta(1e18, 30, 0, 31);
    }

    function test_deltaPreservesRemainderThatPerCallProrationWouldLose() public view {
        // Naively flooring 10 / 3 on each of three calls recognizes nine, not ten.
        assertEq(subject.linearDelta(10, 3, 0, 1), 3);
        assertEq(subject.linearDelta(10, 3, 1, 2), 3);
        assertEq(subject.linearDelta(10, 3, 2, 3), 4);
        assertEq(subject.linearDelta(10, 3, 2, 2), 0);
    }

    function test_endpointInterpolationIsNotTheExactInterestCurve() public view {
        uint256 endpoint = subject.periodAmount(1_000_000e18, 1400, 30 days, 360 days, 1e12, type(uint256).max);
        uint256 direct = subject.earnedInterest(1_000_000e18, 1400, 15 days, 360 days);
        uint256 interpolated = subject.linearEarned(endpoint, 30 days, 15 days);
        assertLt(interpolated, direct, "the two rounding policies were silently conflated");
        assertLt(direct - interpolated, 1e12);
    }

    function test_integerCurveDifferenceCanEqualOneSmallReserveUnit() public view {
        // The unrounded endpoint interpolation is < one unit lower, but flooring it again can
        // make the INTEGER difference equal that unit. With scale=1 this is a real one-wei case.
        uint256 endpoint = subject.periodAmount(360 days, 10_000, 2, 365 days, 1, type(uint256).max);
        assertEq(endpoint, 1);
        assertEq(subject.earnedInterest(360 days, 10_000, 1, 365 days), 0);
        // A rational raw endpoint of 4/3 produces floor(4/3 * 3/4)=1 versus floor(1 * 3/4)=0.
        endpoint = subject.periodAmount(360 days / 3, 10_000, 4, 360 days, 1, type(uint256).max);
        assertEq(endpoint, 1);
        assertEq(subject.earnedInterest(360 days / 3, 10_000, 3, 360 days), 1);
        assertEq(subject.linearEarned(endpoint, 4, 3), 0);
    }

    function test_bindingCapChangesCurveByMoreThanOneReserveUnit() public view {
        uint256 endpoint = subject.periodAmount(1_000_000e18, 10_000, 360 days, 360 days, 1e12, 100e18);
        uint256 interpolated = subject.linearEarned(endpoint, 360 days, 180 days);
        uint256 direct = subject.earnedInterest(1_000_000e18, 10_000, 180 days, 360 days);
        assertEq(interpolated, 50e18);
        assertGt(direct - interpolated, 1e12);
    }

    function testFuzz_earnedMatchesIndependentBoundedNumerator(
        uint176 basis,
        uint16 rawRate,
        uint64 elapsed,
        bool use365
    ) public view {
        uint16 rateBps = uint16(bound(rawRate, 0, 10_000));
        uint256 yearSeconds = use365 ? 365 days : 360 days;
        // 176 + ceil(log2(10_000)) + 64 = 254 bits: the reference product cannot overflow.
        uint256 expected = uint256(basis) * rateBps * elapsed / (10_000 * yearSeconds);
        assertEq(subject.earnedInterest(basis, rateBps, elapsed, yearSeconds), expected);
    }

    function testFuzz_fullAdmittedBasisMatchesIndependentDivision(
        uint256 rawBasis,
        uint16 rawRate,
        uint64 rawElapsed,
        bool use365
    ) public view {
        uint256 basis = bound(rawBasis, 0, type(uint256).max / 10_000);
        uint16 rateBps = uint16(bound(rawRate, 0, 10_000));
        uint256 yearSeconds = use365 ? 365 days : 360 days;
        uint64 elapsed = uint64(bound(rawElapsed, 0, yearSeconds));
        uint256 expected = _referenceCappedInterest(basis, rateBps, elapsed, yearSeconds, type(uint256).max);
        assertEq(subject.earnedInterest(basis, rateBps, elapsed, yearSeconds), expected);
    }

    function testFuzz_fullAdmittedBasisAndTimeAlwaysRespectCap(
        uint256 rawBasis,
        uint16 rawRate,
        uint64 duration,
        uint256 cap,
        bool use365,
        bool ethereumGrid
    ) public view {
        uint256 basis = bound(rawBasis, 0, type(uint256).max / 10_000);
        uint16 rateBps = uint16(bound(rawRate, 0, 10_000));
        uint256 yearSeconds = use365 ? 365 days : 360 days;
        uint256 scale = ethereumGrid ? 1e12 : 1;
        uint256 limited = _referenceCappedInterest(basis, rateBps, duration, yearSeconds, cap);
        assertEq(subject.periodAmount(basis, rateBps, duration, yearSeconds, scale, cap), limited - limited % scale);
    }

    function testFuzz_periodMatchesExactCapAndBothChainGrids(
        uint176 basis,
        uint16 rawRate,
        uint64 duration,
        uint256 cap,
        bool use365,
        bool ethereumGrid
    ) public view {
        uint16 rateBps = uint16(bound(rawRate, 0, 10_000));
        uint256 yearSeconds = use365 ? 365 days : 360 days;
        uint256 scale = ethereumGrid ? 1e12 : 1;
        uint256 raw = uint256(basis) * rateBps * duration / (10_000 * yearSeconds);
        uint256 expected = raw < cap ? raw : cap;
        expected -= expected % scale;
        uint256 actual = subject.periodAmount(basis, rateBps, duration, yearSeconds, scale, cap);
        assertEq(actual, expected);
        assertLe(actual, cap);
        assertLe(actual, raw);
        assertEq(actual % scale, 0);
    }

    function testFuzz_periodSupportsAnyPositiveArithmeticGrid(
        uint176 basis,
        uint16 rawRate,
        uint64 duration,
        uint256 rawScale,
        uint256 cap
    ) public view {
        uint16 rateBps = uint16(bound(rawRate, 0, 10_000));
        uint256 scale = rawScale == 0 ? 1 : rawScale;
        uint256 raw = uint256(basis) * rateBps * duration / (10_000 * 360 days);
        uint256 limited = raw < cap ? raw : cap;
        uint256 actual = subject.periodAmount(basis, rateBps, duration, 360 days, scale, cap);
        assertEq(actual, limited - limited % scale);
        assertLt(limited - actual, scale);
    }

    function testFuzz_linearFullWidthMatchesIndependentQuotientRemainder(
        uint256 endpoint,
        uint64 rawDuration,
        uint64 rawElapsed
    ) public view {
        uint64 duration = rawDuration == 0 ? 1 : rawDuration;
        uint64 elapsed = uint64(bound(rawElapsed, 0, duration));
        uint256 expected = _referenceFraction(endpoint, duration, elapsed);
        assertEq(subject.linearEarned(endpoint, duration, elapsed), expected);
        assertLe(expected, endpoint);
    }

    function testFuzz_deltaIsIndependentOfAnArbitraryCheckpoint(
        uint256 endpoint,
        uint64 rawDuration,
        uint64 rawStart,
        uint64 rawMiddle,
        uint64 rawEnd
    ) public view {
        uint64 duration = rawDuration == 0 ? 1 : rawDuration;
        uint64 start = uint64(bound(rawStart, 0, duration));
        uint64 middle = uint64(bound(rawMiddle, start, duration));
        uint64 end = uint64(bound(rawEnd, middle, duration));
        uint256 first = subject.linearDelta(endpoint, duration, start, middle);
        uint256 second = subject.linearDelta(endpoint, duration, middle, end);
        assertEq(first + second, subject.linearDelta(endpoint, duration, start, end));
        assertEq(
            first + second, _referenceFraction(endpoint, duration, end) - _referenceFraction(endpoint, duration, start)
        );
    }

    function testFuzz_manySmallCheckpointsRecoverExactEndpoint(uint256 endpoint, uint8 rawCount) public view {
        uint64 count = uint64(bound(rawCount, 1, 64));
        uint256 credited;
        for (uint64 elapsed = 1; elapsed <= count; ++elapsed) {
            credited += subject.linearDelta(endpoint, count, elapsed - 1, elapsed);
        }
        assertEq(credited, endpoint);
    }

    function testFuzz_uncappedEndpointInterpolationDifferenceIsBounded(
        uint176 basis,
        uint16 rawRate,
        uint64 rawDuration,
        uint64 rawElapsed,
        bool use365,
        bool ethereumGrid
    ) public view {
        uint64 duration = rawDuration == 0 ? 1 : rawDuration;
        uint64 elapsed = uint64(bound(rawElapsed, 0, duration));
        uint16 rateBps = uint16(bound(rawRate, 0, 10_000));
        uint256 yearSeconds = use365 ? 365 days : 360 days;
        uint256 scale = ethereumGrid ? 1e12 : 1;
        uint256 endpoint = subject.periodAmount(basis, rateBps, duration, yearSeconds, scale, type(uint256).max);
        uint256 direct = subject.earnedInterest(basis, rateBps, elapsed, yearSeconds);
        uint256 interpolated = subject.linearEarned(endpoint, duration, elapsed);
        assertLe(interpolated, direct);
        // Flooring the prorated endpoint introduces up to a further fractional normalized wei.
        assertLe(direct - interpolated, scale);
    }

    function testFuzz_deltaCannotExceedRemainingEndpoint(
        uint256 endpoint,
        uint64 rawDuration,
        uint64 rawStart,
        uint64 rawEnd
    ) public view {
        uint64 duration = rawDuration == 0 ? 1 : rawDuration;
        uint64 start = uint64(bound(rawStart, 0, duration));
        uint64 end = uint64(bound(rawEnd, start, duration));
        uint256 earnedBefore = subject.linearEarned(endpoint, duration, start);
        uint256 delta = subject.linearDelta(endpoint, duration, start, end);
        assertLe(delta, endpoint - earnedBefore);
        assertEq(earnedBefore + delta, subject.linearEarned(endpoint, duration, end));
    }

    function testFuzz_invalidBasisAlwaysRejects(uint80 excess) public {
        uint256 basis = type(uint256).max / 10_000 + 1 + excess;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_BasisTooLarge.selector, basis));
        subject.earnedInterest(basis, 0, 0, 360 days);
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_BasisTooLarge.selector, basis));
        subject.periodAmount(basis, 0, 0, 360 days, 1, 0);
    }

    function testFuzz_invalidRateAlwaysRejects(uint16 rawRate) public {
        uint16 rateBps = uint16(bound(rawRate, 10_001, type(uint16).max));
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, rateBps));
        subject.earnedInterest(0, rateBps, 0, 360 days);
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, rateBps));
        subject.periodAmount(0, rateBps, 0, 360 days, 1, 0);
    }

    function testFuzz_invalidYearAlwaysRejects(uint256 rawYear) public {
        uint256 yearSeconds = rawYear;
        if (yearSeconds == 360 days || yearSeconds == 365 days) ++yearSeconds;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, yearSeconds));
        subject.earnedInterest(0, 0, 0, yearSeconds);
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, yearSeconds));
        subject.periodAmount(0, 0, 0, yearSeconds, 1, 0);
    }

    function testFuzz_outOfRangeCumulativeTimeAlwaysRejects(uint64 rawDuration, uint64 rawExcess) public {
        uint64 duration = uint64(bound(rawDuration, 1, type(uint64).max - 1));
        uint64 elapsed = uint64(bound(rawExcess, uint256(duration) + 1, type(uint64).max));
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMath.AccrualMath_ElapsedExceedsDuration.selector, elapsed, duration)
        );
        subject.linearEarned(0, duration, elapsed);
    }

    /// @dev Exact floor(a*t/d) without a potentially overflowing a*t intermediate. The remainder
    ///      and time are uint64-bounded, so their product fits in uint128. The quotient term and
    ///      final sum cannot exceed `amount` because elapsed <= duration.
    function _referenceFraction(uint256 amount, uint64 duration, uint64 elapsed) private pure returns (uint256) {
        return (amount / duration) * elapsed + ((amount % duration) * elapsed) / duration;
    }

    /// @dev Exact capped simple interest by quotient/remainder decomposition, with neither 512-bit
    ///      multiplication nor an overflowing intermediate. The remainder product fits in 118 bits;
    ///      compare the whole term with cap BEFORE multiplying, then compare the fractional part.
    function _referenceCappedInterest(uint256 basis, uint16 rateBps, uint64 elapsed, uint256 yearSeconds, uint256 cap)
        private
        pure
        returns (uint256)
    {
        uint256 coefficient = uint256(rateBps) * elapsed;
        if (coefficient == 0) return 0;
        uint256 denominator = 10_000 * yearSeconds;
        uint256 wholeBasis = basis / denominator;
        if (wholeBasis > cap / coefficient) return cap;
        uint256 whole = wholeBasis * coefficient;
        uint256 fraction = ((basis % denominator) * coefficient) / denominator;
        if (fraction > cap - whole) return cap;
        return whole + fraction;
    }
}
