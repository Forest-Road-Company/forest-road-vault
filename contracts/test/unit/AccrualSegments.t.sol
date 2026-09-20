// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualSegments} from "../../src/libraries/AccrualSegments.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";

/// @dev External pure adapter for exact errors and immutable-input assertions.
contract AccrualSegmentsHarness {
    function cumulative(AccrualSegments.Terms memory terms, uint64 at) external pure returns (uint256) {
        return AccrualSegments.cumulative(terms, at);
    }

    function plan(AccrualSegments.Terms memory terms, uint64 start)
        external
        pure
        returns (AccrualSegments.Segment memory)
    {
        return AccrualSegments.plan(terms, start);
    }
}

/// @dev Bounded reference cases use direct uint256 products, independently of mulDiv. The
///      full-width cap properties check the first-hit inequalities against reviewed AccrualMath,
///      not a copy of the planner's ceiling division. Run each fuzz property at least 10,000 times.
contract AccrualSegmentsTest is Test {
    uint64 private constant YEAR = 365 days;
    uint64 private constant T = 1_900_000_000;
    AccrualSegmentsHarness private subject;

    function setUp() public {
        subject = new AccrualSegmentsHarness();
    }

    function test_quarterlyActual360And365RetainTheirContractualBasis() public view {
        AccrualSegments.Terms memory terms = _terms();
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.end, T + 90 days);
        assertEq(segment.amount, 35_000e18);
        assertEq(segment.cumulativeStart, 0);
        assertEq(segment.cumulativeEnd, 35_000e18);
        assertTrue(segment.complete);
        assertFalse(segment.capReachable);
        terms.yearSeconds = YEAR;
        segment = subject.plan(terms, T);
        assertEq(segment.amount, uint256(1_000_000e18) * 1400 * 90 days / (10_000 * YEAR) / 1e12 * 1e12);
        assertLt(segment.amount, 35_000e18);
        assertEq(terms.basis, 1_000_000e18);
        assertEq(terms.periodStart, T);
    }

    function test_longPeriodSplitsAnnuallyWithoutCompoundingPik() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.yearSeconds = YEAR;
        terms.periodEnd = T + 3 * YEAR + 1;
        terms.maturity = terms.periodEnd;
        bytes32 original = keccak256(abi.encode(terms));
        uint256 total;
        uint64 start = T;
        for (uint256 i; i < 4; ++i) {
            AccrualSegments.Segment memory segment = subject.plan(terms, start);
            assertEq(segment.start, start);
            assertEq(segment.end, i == 3 ? terms.periodEnd : T + uint64(i + 1) * YEAR);
            assertEq(segment.amount, i == 3 ? 4439e12 : 140_000e18);
            total += segment.amount;
            start = segment.end;
            assertEq(segment.complete, i == 3);
        }
        assertEq(total, subject.cumulative(terms, terms.periodEnd));
        assertEq(keccak256(abi.encode(terms)), original);
    }

    function test_requestedPartialStartKeepsOriginalTechnicalAnchor() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.periodEnd = T + 2 * YEAR;
        terms.maturity = terms.periodEnd;
        AccrualSegments.Segment memory segment = subject.plan(terms, T + 1 days);
        assertEq(segment.end, T + YEAR);
        assertEq(segment.cumulativeStart, subject.cumulative(terms, T + 1 days));
        assertEq(segment.amount, subject.cumulative(terms, T + YEAR) - segment.cumulativeStart);
    }

    function test_maturityTruncatesTheContractualPeriod() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.maturity = T + 17 days;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.end, terms.maturity);
        assertTrue(segment.complete);
        assertEq(segment.amount, uint256(1_000_000e18) * 1400 * 17 days / (10_000 * 360 days) / 1e12 * 1e12);
    }

    function test_bindingCapSplitsAtPenultimateSecondThenAtTheHit() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = uint256(360 days) * 1e18;
        terms.rateBps = 10_000;
        terms.periodEnd = T + YEAR;
        terms.maturity = terms.periodEnd;
        terms.cap = 1 days * 1e18 + 99;
        AccrualSegments.Segment memory first = subject.plan(terms, T);
        assertTrue(first.capReachable);
        assertEq(first.capHit, T + 1 days);
        assertEq(first.end, T + 1 days - 1);
        assertEq(first.amount, uint256(1 days - 1) * 1e18);
        assertFalse(first.complete);
        AccrualSegments.Segment memory last = subject.plan(terms, first.end);
        assertEq(last.end - last.start, 1);
        assertEq(last.end, first.capHit);
        assertEq(last.amount, 1e18);
        assertEq(last.cumulativeEnd, 1 days * 1e18);
        assertTrue(last.complete);
    }

    function test_capReachedInFirstSecondHasNoEmptyPreCapSegment() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = uint256(360 days) * 1e18;
        terms.rateBps = 10_000;
        terms.cap = 5e17;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.end, T + 1);
        assertEq(segment.amount, 5e17);
        assertTrue(segment.complete);
        assertTrue(segment.capReachable);
    }

    function test_capAtContractEndStillInsertsThePenultimateSecond() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = uint256(360 days) * 1e18;
        terms.rateBps = 10_000;
        terms.cap = uint256(90 days) * 1e18;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.capHit, terms.periodEnd);
        assertEq(segment.end, terms.periodEnd - 1);
        assertFalse(segment.complete);
        segment = subject.plan(terms, segment.end);
        assertEq(segment.end, terms.periodEnd);
        assertEq(segment.amount, 1e18);
        assertTrue(segment.complete);
    }

    function test_exhaustedGridCapReturnsAnExplicitNoSegmentMarker() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.cap = 1e12 - 1;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.start, T);
        assertEq(segment.end, T);
        assertEq(segment.capHit, T);
        assertEq(segment.amount, 0);
        assertEq(segment.cumulativeEnd, 0);
        assertTrue(segment.capReachable);
        assertTrue(segment.complete);
        terms.cap = 0;
        segment = subject.plan(terms, T + 1);
        assertEq(segment.end, T + 1);
        assertEq(segment.amount, 0);
        assertTrue(segment.complete);
    }

    function test_requestsAtAndAfterCapReturnTheSameCumulativeAmount() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = uint256(360 days) * 1e18;
        terms.rateBps = 10_000;
        terms.cap = 5e18;
        for (uint64 elapsed = 5; elapsed <= 6; ++elapsed) {
            AccrualSegments.Segment memory segment = subject.plan(terms, T + elapsed);
            assertEq(segment.end, T + elapsed);
            assertEq(segment.cumulativeStart, 5e18);
            assertEq(segment.cumulativeEnd, 5e18);
            assertEq(segment.amount, 0);
            assertTrue(segment.complete);
        }
    }

    function test_exactPeriodEndReturnsNoSegmentAndFullEntitlement() public view {
        AccrualSegments.Terms memory terms = _terms();
        AccrualSegments.Segment memory segment = subject.plan(terms, terms.periodEnd);
        assertEq(segment.end, segment.start);
        assertEq(segment.amount, 0);
        assertEq(segment.cumulativeStart, 35_000e18);
        assertTrue(segment.complete);
    }

    function test_zeroBasisAndRateProduceBoundedZeroAmountSegments() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.periodEnd = T + 2 * YEAR;
        terms.maturity = terms.periodEnd;
        terms.rateBps = 0;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.end, T + YEAR);
        assertEq(segment.amount, 0);
        assertFalse(segment.capReachable);
        assertFalse(segment.complete);
        terms.rateBps = 1400;
        terms.basis = 0;
        segment = subject.plan(terms, T);
        assertEq(segment.end, T + YEAR);
        assertEq(segment.amount, 0);
    }

    function test_microscopicAmountCanHaveZeroIntegerSlopeUntilItsEndpoint() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = 1;
        terms.rateBps = 10_000;
        terms.yearSeconds = YEAR;
        terms.scale = 1;
        terms.periodEnd = T + YEAR;
        terms.maturity = terms.periodEnd;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.amount, 1);
        assertEq(segment.amount / (segment.end - segment.start), 0);
        assertEq(subject.cumulative(terms, segment.end), 1);
    }

    function test_partialInterpolationCanExceedOrTrailTheWholeReserveGrid() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = uint256(360 days) * 10;
        terms.rateBps = 10_000;
        terms.scale = 100;
        terms.periodEnd = T + 10;
        terms.maturity = T + 19;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        assertEq(segment.amount, 100);
        assertEq(subject.cumulative(terms, T + 5), 0);
        assertEq(segment.amount * 5 / 10, 50);
        terms.periodEnd = T + 19;
        segment = subject.plan(terms, T);
        assertEq(segment.amount, 100);
        assertEq(subject.cumulative(terms, T + 10), 100);
        assertEq(segment.amount * 10 / 19, 52);
    }

    function test_maximumTimestampAdditionDoesNotWrap() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.periodStart = type(uint64).max - 1000;
        terms.periodEnd = type(uint64).max;
        terms.maturity = type(uint64).max;
        AccrualSegments.Segment memory segment = subject.plan(terms, terms.periodStart);
        assertEq(segment.end, type(uint64).max);
        assertEq(segment.end - segment.start, 1000);
        assertTrue(segment.complete);
    }

    function test_fullWidthReachableCapSurvivesUncappedInterestOverflow() public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = type(uint256).max / 10_000;
        terms.rateBps = 10_000;
        terms.scale = 1;
        terms.periodStart = 0;
        terms.periodEnd = type(uint64).max;
        terms.maturity = type(uint64).max;
        terms.cap = type(uint256).max;
        AccrualSegments.Segment memory segment = subject.plan(terms, 0);
        assertTrue(segment.capReachable);
        assertGt(segment.capHit, YEAR);
        assertEq(subject.cumulative(terms, segment.capHit), type(uint256).max);
        assertLt(subject.cumulative(terms, segment.capHit - 1), type(uint256).max);
        segment = subject.plan(terms, segment.capHit - 1);
        assertEq(segment.end - segment.start, 1);
        assertEq(segment.cumulativeEnd, type(uint256).max);
        assertGt(segment.amount, 0);
        assertTrue(segment.complete);
    }

    function test_invalidPeriodsAndMaturitiesHaveExactErrors() public {
        AccrualSegments.Terms memory terms = _terms();
        terms.periodEnd = T;
        _invalidPeriod(terms);
        terms.periodEnd = T - 1;
        _invalidPeriod(terms);
        terms.periodEnd = T + 1;
        terms.maturity = T;
        _invalidPeriod(terms);
        terms.maturity = T - 1;
        _invalidPeriod(terms);
    }

    function test_timesOutsideEffectivePeriodHaveExactErrors() public {
        AccrualSegments.Terms memory terms = _terms();
        terms.maturity = T + 1;
        _invalidTime(terms, T - 1, T + 1);
        _invalidTime(terms, T + 2, T + 1);
    }

    function test_allEntryPointsValidateTermsEvenOnZeroEntitlement() public {
        AccrualSegments.Terms memory terms = _terms();
        terms.cap = 0;
        terms.scale = 0;
        _invalidTerms(terms, abi.encodeWithSelector(AccrualMath.AccrualMath_ZeroScale.selector));
        terms.scale = 1;
        terms.basis = type(uint256).max / 10_000 + 1;
        _invalidTerms(terms, abi.encodeWithSelector(AccrualMath.AccrualMath_BasisTooLarge.selector, terms.basis));
        terms.basis = 0;
        terms.rateBps = 10_001;
        _invalidTerms(terms, abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, terms.rateBps));
        terms.rateBps = 0;
        terms.yearSeconds = 364 days;
        _invalidTerms(
            terms, abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, terms.yearSeconds)
        );
    }

    function testFuzz_cumulativeMatchesIndependentFormula(
        uint128 basis,
        uint16 rateSeed,
        uint64 durationSeed,
        uint64 elapsedSeed,
        uint256 cap,
        uint256 scaleSeed,
        bool actual365
    ) public view {
        AccrualSegments.Terms memory terms = _boundedTerms(basis, rateSeed, cap, scaleSeed, actual365);
        uint64 duration = uint64(uint256(durationSeed) % (type(uint64).max - 7) + 1);
        terms.periodStart = 7;
        terms.periodEnd = 7 + duration;
        terms.maturity = terms.periodEnd;
        uint64 elapsed = uint64(uint256(elapsedSeed) % (uint256(duration) + 1));
        assertEq(subject.cumulative(terms, 7 + elapsed), _reference(terms, elapsed));
    }

    function testFuzz_successorsTelescopeWithoutRebasing(
        uint128 basis,
        uint16 rateSeed,
        uint64 durationSeed,
        uint128 cap,
        uint64 scaleSeed,
        bool actual365
    ) public view {
        AccrualSegments.Terms memory terms = _boundedTerms(basis, rateSeed, cap, scaleSeed, actual365);
        uint64 duration = durationSeed % (10 * YEAR) + 1;
        terms.periodEnd = T + duration;
        terms.maturity = terms.periodEnd;
        uint64 at = T;
        uint256 total;
        uint256 steps;
        while (true) {
            AccrualSegments.Segment memory segment = subject.plan(terms, at);
            assertEq(segment.cumulativeStart, total);
            assertEq(segment.amount, segment.cumulativeEnd - segment.cumulativeStart);
            assertLe(segment.end - segment.start, YEAR);
            total += segment.amount;
            ++steps;
            assertLe(steps, 12);
            if (segment.complete) break;
            assertGt(segment.end, at);
            at = segment.end;
        }
        assertEq(total, _reference(terms, duration));
        assertEq(terms.basis, basis);
        assertEq(terms.periodStart, T);
    }

    function testFuzz_capHitIsTheFirstGridSaturation(
        uint128 basisSeed,
        uint16 rateSeed,
        uint64 durationSeed,
        uint128 cap,
        uint64 scaleSeed
    ) public view {
        AccrualSegments.Terms memory terms = _boundedTerms(basisSeed, rateSeed, cap, scaleSeed, false);
        terms.basis = uint256(basisSeed) + 1;
        terms.rateBps = uint16(uint256(rateSeed) % 10_000 + 1);
        uint64 duration = uint64(uint256(durationSeed) % (type(uint64).max - T) + 1);
        terms.periodEnd = T + duration;
        terms.maturity = terms.periodEnd;
        uint256 gridCap = terms.cap / terms.scale * terms.scale;
        AccrualSegments.Segment memory segment = subject.plan(terms, T);
        bool reachable = _reference(terms, duration) == gridCap;
        assertEq(segment.capReachable, reachable);
        if (reachable) {
            if (gridCap == 0) {
                assertEq(segment.capHit, T);
            } else {
                uint256 numerator = gridCap * 10_000 * terms.yearSeconds;
                uint256 denominator = terms.basis * terms.rateBps;
                uint256 expected = numerator / denominator + (numerator % denominator == 0 ? 0 : 1);
                assertEq(segment.capHit, T + expected);
                assertEq(_reference(terms, segment.capHit - T), gridCap);
                assertLt(_reference(terms, segment.capHit - T - 1), gridCap);
            }
        }
    }

    function testFuzz_partialCurveDifferenceHasExplicitGridAndIntegerBounds(
        uint128 basis,
        uint16 rateSeed,
        uint64 durationSeed,
        uint64 elapsedSeed,
        uint128 cap,
        uint64 scaleSeed
    ) public view {
        AccrualSegments.Terms memory terms = _boundedTerms(basis, rateSeed, cap, scaleSeed, false);
        uint64 duration = durationSeed % (2 * YEAR) + 1;
        terms.periodEnd = T + duration;
        terms.maturity = terms.periodEnd;
        uint64 start = T + elapsedSeed % duration;
        AccrualSegments.Segment memory segment = subject.plan(terms, start);
        if (segment.end == segment.start) return;
        uint64 length = segment.end - segment.start;
        uint64 elapsed = uint64(uint256(elapsedSeed) % (uint256(length) + 1));
        uint256 interpolation = segment.cumulativeStart + segment.amount * elapsed / length;
        uint256 integerStream = segment.cumulativeStart + (segment.amount / length) * elapsed;
        uint256 curve = _reference(terms, start - T + elapsed);
        assertGe(interpolation, integerStream);
        assertLt(interpolation - integerStream, length);
        if (interpolation > curve) assertLt(interpolation - curve, terms.scale);
        else assertLe(curve - interpolation, terms.scale);
        if (integerStream > curve) assertLt(integerStream - curve, terms.scale);
        else assertLt(curve - integerStream, terms.scale + length);
        if (elapsed == length) assertEq(interpolation, segment.cumulativeEnd);
    }

    function testFuzz_fullWidthCapHitAndMaximumTimestamp(
        uint256 basisSeed,
        uint16 rateSeed,
        uint256 cap,
        uint64 durationSeed,
        bool ethereumGrid
    ) public view {
        AccrualSegments.Terms memory terms = _terms();
        terms.basis = basisSeed % (type(uint256).max / 10_000) + 1;
        terms.rateBps = uint16(uint256(rateSeed) % 10_000 + 1);
        terms.cap = cap;
        terms.scale = ethereumGrid ? 1e12 : 1;
        uint64 duration = durationSeed == 0 ? 1 : durationSeed;
        terms.periodStart = type(uint64).max - duration;
        terms.periodEnd = type(uint64).max;
        terms.maturity = type(uint64).max;
        AccrualSegments.Segment memory segment = subject.plan(terms, terms.periodStart);
        assertGe(segment.end, segment.start);
        assertLe(segment.end - segment.start, YEAR);
        uint256 gridCap = cap / terms.scale * terms.scale;
        assertEq(segment.capReachable, subject.cumulative(terms, terms.periodEnd) == gridCap);
        if (segment.capReachable) {
            assertGe(segment.capHit, terms.periodStart);
            assertLe(segment.capHit, terms.periodEnd);
            assertEq(subject.cumulative(terms, segment.capHit), gridCap);
            if (gridCap != 0) {
                assertLt(subject.cumulative(terms, segment.capHit - 1), gridCap);
                segment = subject.plan(terms, segment.capHit - 1);
                assertEq(segment.end - segment.start, 1);
                assertEq(segment.cumulativeEnd, gridCap);
                assertTrue(segment.complete);
            }
        }
    }

    function _terms() private pure returns (AccrualSegments.Terms memory terms) {
        terms = AccrualSegments.Terms({
            basis: 1_000_000e18,
            yearSeconds: 360 days,
            scale: 1e12,
            cap: type(uint256).max,
            periodStart: T,
            periodEnd: T + 90 days,
            maturity: T + 4 * 90 days,
            rateBps: 1400
        });
    }

    function _boundedTerms(uint128 basis, uint16 rateSeed, uint256 cap, uint256 scaleSeed, bool actual365)
        private
        pure
        returns (AccrualSegments.Terms memory terms)
    {
        terms = _terms();
        terms.basis = basis;
        terms.rateBps = rateSeed % 10_001;
        terms.cap = cap;
        terms.scale = scaleSeed == 0 ? 1 : scaleSeed;
        terms.yearSeconds = actual365 ? YEAR : 360 days;
    }

    function _reference(AccrualSegments.Terms memory terms, uint64 elapsed) private pure returns (uint256) {
        uint256 raw = terms.basis * terms.rateBps * elapsed / (10_000 * terms.yearSeconds);
        return (raw < terms.cap ? raw : terms.cap) / terms.scale * terms.scale;
    }

    function _invalidPeriod(AccrualSegments.Terms memory terms) private {
        bytes memory errorData = abi.encodeWithSelector(
            AccrualSegments.AccrualSegments_InvalidPeriod.selector, terms.periodStart, terms.periodEnd, terms.maturity
        );
        vm.expectRevert(errorData);
        subject.plan(terms, T);
        vm.expectRevert(errorData);
        subject.cumulative(terms, T);
    }

    function _invalidTime(AccrualSegments.Terms memory terms, uint64 at, uint64 end) private {
        bytes memory errorData = abi.encodeWithSelector(
            AccrualSegments.AccrualSegments_TimeOutsidePeriod.selector, at, terms.periodStart, end
        );
        vm.expectRevert(errorData);
        subject.plan(terms, at);
        vm.expectRevert(errorData);
        subject.cumulative(terms, at);
    }

    function _invalidTerms(AccrualSegments.Terms memory terms, bytes memory errorData) private {
        vm.expectRevert(errorData);
        subject.plan(terms, T);
        vm.expectRevert(errorData);
        subject.cumulative(terms, T);
        vm.expectRevert(errorData);
        subject.plan(terms, terms.periodEnd);
    }
}
