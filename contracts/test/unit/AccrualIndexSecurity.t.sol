// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualIndex} from "../../src/libraries/AccrualIndex.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";
import {AccrualIndexHarness} from "./AccrualIndex.t.sol";

/// @notice Independent security-panel checks of aggregate arithmetic under mixed event traces.
/// @dev The reference stores one exact scaled numerator. It is deliberately bounded to fit a
///      uint256 independently of the implementation's split whole/fraction representation.
contract AccrualIndexSecurityTest is Test {
    uint256 private constant Q = 1e27;
    AccrualIndexHarness private subject;

    struct Segment {
        uint256 amount;
        uint64 duration;
        bool closed;
    }

    function setUp() public {
        subject = new AccrualIndexHarness();
        subject.initialize(0);
    }

    function testFuzz_mixedEventTraceEqualsIndependentNumerator(uint256 seed) public {
        uint256[8] memory rates;
        bool[8] memory active;
        uint256 aggregate;
        uint256 earned;
        uint64 at;
        for (uint256 step; step < 32; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint64 elapsed = uint64(seed % 100_001);
            earned += aggregate * elapsed;
            at += elapsed;
            uint256 slot = (seed >> 64) % rates.length;
            if (active[slot]) {
                subject.remove(rates[slot] / Q, rates[slot] % Q, at);
                aggregate -= rates[slot];
            } else {
                // Exercise full-range fractions, multiple carry words and a zero-rate member.
                rates[slot] = slot == 7 ? 0 : ((seed >> 96) % 1e30) * Q + seed % Q;
                subject.add(rates[slot] / Q, rates[slot] % Q, at);
                aggregate += rates[slot];
            }
            active[slot] = !active[slot];
            if ((seed & 1) == 0) subject.checkpoint(at);
            _assertNumerator(at, earned);
            AccrualIndex.Rate memory liveRate = subject.rate();
            assertEq(liveRate.whole * Q + liveRate.fraction, aggregate);
            // A speculative read must neither mutate the cursor nor choose a rounding partition.
            _assertNumerator(at + 31, earned + aggregate * 31);
            _assertNumerator(at, earned);
        }
    }

    function testFuzz_sameTimestampPermutationAndMaximumClockAgree(uint256 seed) public {
        AccrualIndexHarness reverse = new AccrualIndexHarness();
        reverse.initialize(0);
        uint256[12] memory fractions;
        uint256 aggregate;
        for (uint256 i; i < fractions.length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            fractions[i] = seed % Q;
            aggregate += fractions[i];
            subject.add(0, fractions[i], 0);
        }
        for (uint256 i = fractions.length; i != 0; --i) {
            reverse.add(0, fractions[i - 1], 0);
        }
        uint64 end = type(uint64).max;
        uint256 expected = aggregate * end;
        _assertNumerator(end, expected);
        (uint256 whole, uint256 fraction) = reverse.preview(end);
        assertEq(whole, expected / Q);
        assertEq(fraction, expected % Q);
        for (uint256 i; i < fractions.length; ++i) {
            subject.remove(0, fractions[i], end);
            reverse.remove(0, fractions[fractions.length - i - 1], end);
        }
        assertEq(subject.rate().whole, 0);
        assertEq(subject.rate().fraction, 0);
        assertEq(reverse.rate().whole, 0);
        assertEq(reverse.rate().fraction, 0);
        _assertNumerator(end, expected);
    }

    function test_fractionalCarryCanReachMaximumBeforeNamedCumulativeOverflow() public {
        uint256 wholeRate = type(uint256).max / 2;
        subject.add(wholeRate, Q - 1, 0);
        subject.checkpoint(2);
        (uint256 whole, uint256 fraction) = subject.preview(2);
        assertEq(whole, type(uint256).max);
        assertEq(fraction, Q - 2);
        subject.remove(wholeRate, Q - 1, 2);
        subject.add(0, 2, 2);
        vm.expectRevert(AccrualIndex.AccrualIndex_Overflow.selector);
        subject.checkpoint(3);
        // The failed carry must not consume the remainder or move the clock forward.
        (whole, fraction) = subject.preview(2);
        assertEq(whole, type(uint256).max);
        assertEq(fraction, Q - 2);
    }

    function test_conservativeEndpointStillOwnsFractionalCarry() public {
        AccrualIndex.Rate memory rate = subject.rateFor(1, 3);
        subject.add(rate.whole, rate.fraction, 0);
        subject.remove(rate.whole, rate.fraction, 3);
        (uint256 whole, uint256 fraction) = subject.preview(3);
        assertEq(whole, 0);
        assertEq(fraction, Q - 1);
        // Stopping this segment does not discard already-earned fractional value. An integrating
        // scheduler that reconciles its exact integer endpoint must account for this carry too.
        subject.add(rate.whole, rate.fraction, 3);
        (whole, fraction) = subject.preview(6);
        assertEq(whole, 1);
        assertEq(fraction, Q - 2);
    }

    /// @notice Documents a quantized-rate versus exact-facility-floor integration precondition.
    /// @dev See docs/remediation/accrual-panel/INTEGRATION_REVIEW.md, "Precision must match across
    ///      the attribution seam". This is a documented approximation, not an index arithmetic bug.
    function test_partialIntegralBoundaryRequiresMatchingFacilityAttributionPrecision() public {
        _assertPartialPrecisionMismatch(6);
        _assertPartialPrecisionMismatch(6e18);
    }

    function _assertPartialPrecisionMismatch(uint256 amount) private {
        AccrualIndexHarness partialIndex = new AccrualIndexHarness();
        partialIndex.initialize(0);
        AccrualIndex.Rate memory rate = partialIndex.rateFor(amount, 9);
        partialIndex.add(rate.whole, rate.fraction, 0);
        (uint256 whole, uint256 fraction) = partialIndex.preview(3);
        uint256 exactFacilityFloor = AccrualMath.linearEarned(amount, 9, 3);
        assertEq(exactFacilityFloor, amount / 3);
        assertEq(whole, exactFacilityFloor - 1);
        assertEq(fraction, Q - 2);
        // The primitive advertises a conservative quantization. An integrating reserve must not
        // post exactFacilityFloor against this smaller global whole amount without reconciling
        // precision: its virtualBacking = grossAccrued - grossPosted would otherwise underflow.
    }

    function testFuzz_closingMixedCohortSettlesExactEndpointsWithoutErasingOtherCarry(uint256 seed) public {
        Segment[8] memory segments;
        for (uint256 i; i < segments.length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            segments[i].amount = (seed % 1e35) + 1;
            // Include a uint64-maximum endpoint, two coincident tiny endpoints and arbitrary
            // intervening boundaries. Other facilities' fractions must survive each closure.
            segments[i].duration = i == 7 ? type(uint64).max : uint64((seed >> 128) % 1_000_003 + 1);
            if (i < 2) {
                segments[i].amount = 1;
                segments[i].duration = 3;
            }
            AccrualIndex.Rate memory rate = subject.rateFor(segments[i].amount, segments[i].duration);
            subject.add(rate.whole, rate.fraction, 0);
        }
        uint64 previous;
        for (uint256 completed; completed < segments.length; ++completed) {
            uint256 selected = type(uint256).max;
            uint64 next = type(uint64).max;
            for (uint256 i; i < segments.length; ++i) {
                if (!segments[i].closed && (selected == type(uint256).max || segments[i].duration < next)) {
                    selected = i;
                    next = segments[i].duration;
                }
            }
            uint64 middle = previous + (next - previous) / 2;
            subject.checkpoint(middle);
            _assertNumerator(middle, _cohortNumerator(segments, middle));
            subject.close(segments[selected].amount, segments[selected].duration, next);
            segments[selected].closed = true;
            _assertNumerator(next, _cohortNumerator(segments, next));
            previous = next;
        }
        assertEq(subject.rate().whole, 0);
        assertEq(subject.rate().fraction, 0);
        (uint256 whole, uint256 fraction) = subject.preview(type(uint64).max);
        assertEq(whole * Q, _cohortNumerator(segments, type(uint64).max));
        assertEq(fraction, 0);
    }

    function _cohortNumerator(Segment[8] memory segments, uint64 at) private pure returns (uint256 expected) {
        for (uint256 i; i < segments.length; ++i) {
            uint256 scaledAmount = segments[i].amount * Q;
            expected += segments[i].closed ? scaledAmount : (scaledAmount / segments[i].duration) * at;
        }
    }

    function _assertNumerator(uint64 at, uint256 expected) private view {
        (uint256 whole, uint256 fraction) = subject.preview(at);
        assertEq(whole, expected / Q);
        assertEq(fraction, expected % Q);
    }
}
