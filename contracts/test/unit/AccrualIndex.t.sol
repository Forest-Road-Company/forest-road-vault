// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualIndex} from "../../src/libraries/AccrualIndex.sol";

contract AccrualIndexHarness {
    using AccrualIndex for AccrualIndex.Index;

    AccrualIndex.Index private index;

    function initialize(uint64 at) external {
        index.initialize(at);
    }

    function rateFor(uint256 amount, uint64 duration) external pure returns (AccrualIndex.Rate memory) {
        return AccrualIndex.rateFor(amount, duration);
    }

    function add(uint256 whole, uint256 fraction, uint64 at) external {
        index.addRate(AccrualIndex.Rate(whole, fraction), at);
    }

    function remove(uint256 whole, uint256 fraction, uint64 at) external {
        index.removeRate(AccrualIndex.Rate(whole, fraction), at);
    }

    function checkpoint(uint64 at) external returns (uint256) {
        return index.checkpoint(at);
    }

    function close(uint256 amount, uint64 duration, uint64 at) external {
        index.closeSegment(amount, duration, at);
    }

    function preview(uint64 at) external view returns (uint256, uint256) {
        return index.preview(at);
    }

    function rate() external view returns (AccrualIndex.Rate memory) {
        return index.rate;
    }
}

/// @notice Independent integer-numerator properties for the aggregate arithmetic substrate.
/// @dev These tests do not claim to validate a contractual scheduler or a deployed accrual system.
contract AccrualIndexTest is Test {
    uint256 private constant Q = 1e27;
    AccrualIndexHarness private eager;
    AccrualIndexHarness private lazy;

    function setUp() public {
        eager = new AccrualIndexHarness();
        lazy = new AccrualIndexHarness();
        eager.initialize(0);
        lazy.initialize(0);
    }

    function testFuzz_checkpointPartitionDoesNotEraseFractionalInterest(uint64 rawRate, uint32 a, uint32 b) public {
        uint256 fraction = bound(rawRate, 1, Q - 1);
        uint64 first = uint64(bound(a, 1, 365 days));
        uint64 end = first + uint64(bound(b, 1, 365 days));
        eager.add(3, fraction, 0);
        lazy.add(3, fraction, 0);
        eager.checkpoint(first);
        eager.checkpoint(end);
        lazy.checkpoint(end);
        _equalAt(eager, lazy, end);
        (uint256 whole, uint256 remainder) = eager.preview(end);
        uint256 numerator = (3 * Q + fraction) * end;
        assertEq(whole, numerator / Q);
        assertEq(remainder, numerator % Q);
    }

    function testFuzz_rateChangeSettlesOldRateAndPreservesCarry(uint96 a, uint96 b, uint32 rawAt) public {
        uint256 first = bound(a, 1, Q - 1);
        uint256 second = bound(b, 1, Q - 1);
        uint64 at = uint64(bound(rawAt, 1, 365 days));
        eager.add(2, first, 0);
        eager.add(5, second, at);
        eager.remove(2, first, at + 100);
        (uint256 whole, uint256 remainder) = eager.preview(at + 200);
        uint256 numerator = (2 * Q + first) * (at + 100) + (5 * Q + second) * 200;
        assertEq(whole, numerator / Q);
        assertEq(remainder, numerator % Q);
        AccrualIndex.Rate memory remaining = eager.rate();
        assertEq(remaining.whole, 5);
        assertEq(remaining.fraction, second);
    }

    function testFuzz_removeEveryRateStopsAccrualExactly(uint96 rawA, uint96 rawB) public {
        uint256 a = bound(rawA, 1, Q - 1);
        uint256 b = bound(rawB, 1, Q - 1);
        eager.add(0, a, 0);
        eager.add(0, b, 0);
        eager.remove(0, a, 23);
        eager.remove(0, b, 23);
        (uint256 beforeWhole, uint256 beforeFraction) = eager.preview(23);
        (uint256 afterWhole, uint256 afterFraction) = eager.preview(type(uint64).max);
        assertEq(afterWhole, beforeWhole);
        assertEq(afterFraction, beforeFraction);
        assertEq(eager.rate().whole, 0);
        assertEq(eager.rate().fraction, 0);
    }

    function testFuzz_quotedRateIsConservativeAndDoesNotMultiplyPrincipalByPrecision(uint256 amount, uint64 rawDuration)
        public
        view
    {
        uint64 duration = uint64(bound(rawDuration, 1, type(uint64).max));
        AccrualIndex.Rate memory rate = eager.rateFor(amount, duration);
        assertEq(rate.whole, amount / duration);
        // The independent numerator here is bounded by uint64.max * 1e27, regardless of amount.
        uint256 numerator = (amount % duration) * Q;
        assertEq(rate.fraction, numerator / duration);
        assertLt(numerator - rate.fraction * duration, duration);
    }

    function test_largeWholeAmountDoesNotOverflowThroughPrecisionScaling() public {
        uint256 amount = type(uint256).max / 10_000;
        AccrualIndex.Rate memory rate = eager.rateFor(amount, 365 days);
        eager.add(rate.whole, rate.fraction, 0);
        (uint256 total, uint256 fraction) = eager.preview(365 days);
        assertLe(total, amount);
        assertLe(amount - total, 1);
        assertLt(fraction, Q);
    }

    function test_fractionBorrowAndCarryCancelExactly() public {
        eager.add(1, Q - 1, 0);
        eager.add(0, 2, 0);
        assertEq(eager.rate().whole, 2);
        assertEq(eager.rate().fraction, 1);
        eager.remove(1, Q - 1, 1);
        assertEq(eager.rate().whole, 0);
        assertEq(eager.rate().fraction, 2);
        (uint256 whole, uint256 fraction) = eager.preview(1);
        assertEq(whole, 2);
        assertEq(fraction, 1);
    }

    function testFuzz_completeSegmentsEndExactlyWithoutDoubleCountingFraction(uint128 amount, uint32 rawDuration)
        public
    {
        uint64 duration = uint64(bound(rawDuration, 1, 365 days));
        AccrualIndex.Rate memory rate = eager.rateFor(amount, duration);
        for (uint64 i; i < 3; ++i) {
            eager.add(rate.whole, rate.fraction, i * duration);
            eager.checkpoint(i * duration + duration / 2);
            eager.close(amount, duration, (i + 1) * duration);
            (uint256 whole, uint256 fraction) = eager.preview((i + 1) * duration);
            assertEq(whole, uint256(amount) * (i + 1));
            assertEq(fraction, 0);
            assertEq(eager.rate().whole, 0);
            assertEq(eager.rate().fraction, 0);
        }
    }

    function test_endpointCorrectionPreservesOtherRunningSegments() public {
        // One wei over three seconds cannot be represented exactly as a finite per-second rate.
        AccrualIndex.Rate memory thirds = eager.rateFor(1, 3);
        eager.add(thirds.whole, thirds.fraction, 0);
        eager.add(0, Q / 2, 1);
        eager.close(1, 3, 3);
        (uint256 whole, uint256 fraction) = eager.preview(4);
        assertEq(whole, 2); // 1 completed wei plus 1.5 wei from the other segment.
        assertEq(fraction, Q / 2);
        eager.remove(0, Q / 2, 4);
        (uint256 frozenWhole, uint256 frozenFraction) = eager.preview(100);
        assertEq(frozenWhole, whole);
        assertEq(frozenFraction, fraction);
    }

    function testFuzz_closeSegmentPreservesFullAmountAndClockWidths(uint256 amount, uint64 rawDuration) public {
        uint64 duration = uint64(bound(rawDuration, 1, type(uint64).max));
        AccrualIndex.Rate memory rate = eager.rateFor(amount, duration);
        eager.add(rate.whole, rate.fraction, 0);
        eager.close(amount, duration, duration);
        (uint256 whole, uint256 fraction) = eager.preview(duration);
        assertEq(whole, amount);
        assertEq(fraction, 0);
        assertEq(eager.rate().whole, 0, "closing a wide amount must remove its entire rate");
        assertEq(eager.rate().fraction, 0);
    }

    function test_closeSegmentRejectsZeroDuration() public {
        vm.expectRevert(AccrualIndex.AccrualIndex_ZeroDuration.selector);
        eager.close(0, 0, 0);
    }

    function test_endpointCarryOverflowRollsBackRateRemoval() public {
        eager.add(type(uint256).max, 0, 0);
        eager.remove(type(uint256).max, 0, 1);
        AccrualIndex.Rate memory thirds = eager.rateFor(1, 3);
        eager.add(thirds.whole, thirds.fraction, 1);
        eager.checkpoint(4);
        (uint256 beforeWhole, uint256 beforeFraction) = eager.preview(4);
        assertEq(beforeWhole, type(uint256).max);
        assertEq(beforeFraction, Q - 1);

        // Projection still fits; only the exact endpoint's fractional carry overflows.
        // This must reject atomically, including the rate removal inside closeSegment.
        vm.expectRevert(AccrualIndex.AccrualIndex_Overflow.selector);
        eager.close(1, 3, 4);
        (uint256 afterWhole, uint256 afterFraction) = eager.preview(4);
        assertEq(afterWhole, beforeWhole);
        assertEq(afterFraction, beforeFraction);
        assertEq(eager.rate().whole, thirds.whole);
        assertEq(eager.rate().fraction, thirds.fraction);
    }

    function test_rejectsUninitializedAndDoubleInitialization() public {
        AccrualIndexHarness unopened = new AccrualIndexHarness();
        vm.expectRevert(AccrualIndex.AccrualIndex_NotInitialized.selector);
        unopened.preview(0);
        vm.expectRevert(AccrualIndex.AccrualIndex_AlreadyInitialized.selector);
        eager.initialize(1);
    }

    function test_rejectsZeroDurationInvalidFractionAndTimeReversal() public {
        vm.expectRevert(AccrualIndex.AccrualIndex_ZeroDuration.selector);
        eager.rateFor(1, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualIndex.AccrualIndex_InvalidFraction.selector, Q));
        eager.add(0, Q, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualIndex.AccrualIndex_InvalidFraction.selector, Q));
        eager.remove(0, Q, 0);
        eager.checkpoint(8);
        vm.expectRevert(abi.encodeWithSelector(AccrualIndex.AccrualIndex_TimeReversed.selector, uint64(8), uint64(7)));
        eager.checkpoint(7);
    }

    function test_rejectsRateUnderflowWithoutChangingCheckpoint() public {
        eager.add(2, 5, 0);
        vm.expectRevert(AccrualIndex.AccrualIndex_RateUnderflow.selector);
        eager.remove(2, 6, 2);
        vm.expectRevert(AccrualIndex.AccrualIndex_RateUnderflow.selector);
        eager.remove(3, 0, 2);
        (uint256 whole, uint256 fraction) = eager.preview(1);
        assertEq(whole, 2);
        assertEq(fraction, 5);
    }

    function test_rejectsWholeRateOverflowIncludingFractionCarry() public {
        eager.add(type(uint256).max, Q - 1, 0);
        vm.expectRevert(AccrualIndex.AccrualIndex_Overflow.selector);
        eager.add(1, 0, 0);
        vm.expectRevert(AccrualIndex.AccrualIndex_Overflow.selector);
        eager.add(0, 1, 0);
    }

    function test_rejectsProductAndCumulativeAccruedOverflow() public {
        eager.add(type(uint256).max, 0, 0);
        vm.expectRevert(AccrualIndex.AccrualIndex_Overflow.selector);
        eager.preview(2);
        eager.checkpoint(1);
        vm.expectRevert(AccrualIndex.AccrualIndex_Overflow.selector);
        eager.checkpoint(2);
    }

    function test_zeroRateAndSameTimestampCheckpointAreNoOps() public {
        eager.add(0, 0, 0);
        assertEq(eager.checkpoint(0), 0);
        eager.remove(0, 0, type(uint64).max);
        (uint256 whole, uint256 fraction) = eager.preview(type(uint64).max);
        assertEq(whole, 0);
        assertEq(fraction, 0);
    }

    function _equalAt(AccrualIndexHarness left, AccrualIndexHarness right, uint64 at) private view {
        (uint256 lw, uint256 lf) = left.preview(at);
        (uint256 rw, uint256 rf) = right.preview(at);
        assertEq(lw, rw);
        assertEq(lf, rf);
    }
}
