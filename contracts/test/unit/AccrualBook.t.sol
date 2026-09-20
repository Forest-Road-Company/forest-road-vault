// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";

/// @dev Test-only wrapper. Production hosts must prove terms, authority and actual token deltas.
contract AccrualBookHarness {
    using AccrualBook for AccrualBook.Book;

    AccrualBook.Book internal book;

    function initialize(uint64 at, uint16 fee) external {
        book.initialize(at, fee);
    }

    function register(uint256 id, bytes32[3] memory keys, uint64 at) external {
        book.register(id, keys, at);
    }

    function open(uint256 id, uint256 amount, uint64 start, uint64 end) external {
        book.open(id, amount, start, end);
    }

    function snapshot(uint64 at) external view returns (AccrualBook.Snapshot memory) {
        return book.snapshot(at);
    }

    function earned(uint256 id, uint64 at) external view returns (uint256) {
        return book.earned(id, at);
    }

    function groupUnposted(bytes32 key, uint64 at) external view returns (uint256) {
        return book.groupUnposted(key, at);
    }

    function pastDueInterest(bytes32 key, uint64 at) external view returns (uint256) {
        return book.pastDueInterest(key, at);
    }

    function checkpoint(uint64 at) external {
        book.checkpoint(at);
    }

    function reconcile(uint256 id, uint64 at) external returns (uint256) {
        return book.reconcile(id, at);
    }

    function finishNext(uint64 at) external returns (uint256, uint64, uint256) {
        return book.finishNext(at);
    }

    function stop(uint256 id, uint64 at) external returns (uint256) {
        return book.stop(id, at);
    }

    function creditStoppedCorrection(uint256 id, uint256 amount, uint64 at) external {
        book.creditStoppedCorrection(id, amount, at);
    }

    function takePosting(uint256 id, uint64 at) external returns (uint256) {
        return book.takePosting(id, at);
    }

    function takeIssuance(uint64 at) external returns (uint256, uint256) {
        return book.takeIssuance(at);
    }

    function takeIssuance(uint8 legs, uint64 at) external returns (uint256, uint256) {
        return book.takeIssuance(legs, at);
    }

    function setFee(uint16 fee, uint64 at) external {
        book.setFee(fee, at);
    }

    function setPastDue(uint256 id, bool enabled, uint64 at) external {
        book.setPastDue(id, enabled, at);
    }

    function retire(uint256 id, uint64 at) external {
        book.retire(id, at);
    }

    function requireFresh(uint64 at) external view {
        book.requireFresh(at);
    }

    function registered() external view returns (uint32) {
        return book.registered;
    }

    /// @dev Invalid-storage injection solely to pin the defensive projection overflow errors.
    ///      Normal admission cannot reach these states because it reserves complete endpoints.
    function corruptProjection(uint256 value, uint256 rate) external {
        book.total.value = value;
        book.total.rate = rate;
    }

    function next() external view returns (AccrualSchedule.Event memory) {
        return AccrualSchedule.peek(book.schedule);
    }
}

contract AccrualBookTest is Test {
    AccrualBookHarness private h;
    bytes32 private constant CLASS = bytes32(uint256(1));
    bytes32 private constant BORROWER = bytes32(uint256(2));
    bytes32 private constant STATE = bytes32(uint256(3));

    function setUp() public {
        h = new AccrualBookHarness();
    }

    function _keys() private pure returns (bytes32[3] memory) {
        return [CLASS, BORROWER, STATE];
    }

    function _start(uint256 id, uint256 amount, uint64 start, uint64 end) private {
        h.initialize(start, 1000);
        h.register(id, _keys(), start);
        h.open(id, amount, start, end);
    }

    function test_unenabledBookHasZeroFreshSnapshot() public view {
        AccrualBook.Snapshot memory s = h.snapshot(100);
        assertEq(s.gross, 0);
        assertEq(s.unissued, 0);
        assertTrue(s.fresh);
        assertEq(s.accruedThrough, 100);
    }

    function test_initializationAndKnownFacilityErrorsAreExact() public {
        vm.expectRevert(AccrualBook.AccrualBook_NotInitialized.selector);
        h.register(0, _keys(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_InvalidFee.selector, uint16(10_001)));
        h.initialize(0, 10_001);
        h.initialize(0, 1000);
        vm.expectRevert(AccrualBook.AccrualBook_AlreadyInitialized.selector);
        h.initialize(0, 1000);
        h.register(0, _keys(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_KnownFacility.selector, uint256(0)));
        h.register(0, _keys(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnknownFacility.selector, uint256(1)));
        h.open(1, 0, 0, 1);
    }

    function test_segmentErrorsRollbackRegistrationAndScheduling() public {
        h.initialize(0, 1000);
        bytes32[3] memory bad = [CLASS, CLASS, STATE];
        vm.expectRevert(AccrualBook.AccrualBook_InvalidKeys.selector);
        h.register(0, bad, 0);
        assertEq(h.registered(), 0);
        h.register(0, _keys(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_InvalidSegment.selector, uint64(1), uint64(1)));
        h.open(0, 100, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_InvalidSegment.selector, uint64(0), uint64(365 days + 1))
        );
        h.open(0, 100, 0, 365 days + 1);
        h.open(0, 100, 0, 100);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_AlreadyScheduled.selector, uint256(0)));
        h.open(0, 100, 0, 100);
        assertEq(h.next().deadline, 100);
    }

    function test_partialReconciliationAndBoundaryAreNotCountedTwice() public {
        _start(0, 109, 0, 10);
        assertEq(h.earned(0, 3), 30);
        assertEq(h.reconcile(0, 3), 2);
        assertEq(h.reconcile(0, 3), 0);
        assertEq(h.takePosting(0, 3), 32);
        assertEq(h.reconcile(0, 6), 3);
        assertEq(h.earned(0, 6), 65);
        (uint256 id, uint64 boundary, uint256 extra) = h.finishNext(12);
        assertEq(id, 0);
        assertEq(boundary, 10);
        assertEq(extra, 4);
        AccrualBook.Snapshot memory s = h.snapshot(12);
        assertEq(s.gross, 109);
        assertEq(s.fee, 10);
        assertEq(s.unposted, 77);
        assertTrue(s.fresh);
        assertEq(h.takePosting(0, 12), 77);
        (uint256 senior, uint256 fee) = h.takeIssuance(12);
        assertEq(senior, 99);
        assertEq(fee, 10);
        s = h.snapshot(12);
        assertEq(s.unposted, 0);
        assertEq(s.unissued, 0);
        assertEq(h.groupUnposted(CLASS, 12), 0);
    }

    function test_staleSnapshotNeverExtrapolatesBeyondBoundary() public {
        _start(type(uint256).max, 109, 0, 10);
        AccrualBook.Snapshot memory s = h.snapshot(1000);
        assertEq(s.gross, 100);
        assertEq(s.accruedThrough, 10);
        assertFalse(s.fresh);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(10), uint64(10))
        );
        h.takeIssuance(10);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(10), uint64(11))
        );
        h.checkpoint(11);
        vm.expectRevert(AccrualBook.AccrualBook_NoBoundaryDue.selector);
        h.finishNext(9);
        assertEq(h.snapshot(1000).gross, 100);
    }

    function test_stopPostsExactPartialFaceAndKeepsRecognizedLiability() public {
        _start(0, 6, 0, 9);
        assertEq(h.snapshot(3).gross, 0);
        assertEq(h.stop(0, 3), 2);
        assertEq(h.takePosting(0, 3), 2);
        AccrualBook.Snapshot memory s = h.snapshot(1000);
        assertEq(s.gross, 2);
        assertEq(s.unposted, 0);
        assertEq(s.unissued, 2);
        assertEq(h.groupUnposted(BORROWER, 1000), 0);
        h.retire(0, 3);
        assertEq(h.registered(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_KnownFacility.selector, uint256(0)));
        h.register(0, _keys(), 3);
    }

    function test_pastDueCohortMovesWithPostingAndClear() public {
        _start(0, 109, 0, 10);
        h.setPastDue(0, true, 2);
        assertEq(h.pastDueInterest(CLASS, 3), 30);
        h.reconcile(0, 3);
        assertEq(h.pastDueInterest(CLASS, 3), 32);
        h.takePosting(0, 3);
        assertEq(h.pastDueInterest(CLASS, 6), 30);
        h.setPastDue(0, false, 6);
        assertEq(h.pastDueInterest(CLASS, 8), 0);
        assertEq(h.earned(0, 8), 82);
        h.setPastDue(0, true, 8);
        h.finishNext(10);
        assertEq(h.pastDueInterest(CLASS, 10), 77);
        h.takePosting(0, 10);
        assertEq(h.pastDueInterest(CLASS, 20), 0);
        h.retire(0, 20);
    }

    function test_feeChangeIsProspectiveAndSameRateCannotResetRounding() public {
        _start(0, 1000, 0, 1000);
        h.setFee(1000, 9);
        assertEq(h.snapshot(10).fee, 1);
        h.setFee(2000, 10);
        assertEq(h.snapshot(20).fee, 3);
        (uint256 senior, uint256 fee) = h.takeIssuance(20);
        assertEq(senior, 17);
        assertEq(fee, 3);
        h.setFee(10_000, 20);
        assertEq(h.snapshot(30).seniorUnissued, 0);
        assertEq(h.snapshot(30).feeUnissued, 10);
        h.setFee(0, 30);
        assertEq(h.snapshot(40).seniorUnissued, 10);
    }

    function test_everyPostingAndIssuanceAdvancesGlobalMutationTime() public {
        _start(0, 100, 0, 100);
        h.takePosting(0, 10);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(10), uint64(9)));
        h.checkpoint(9);
        h.takeIssuance(20);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(20), uint64(19)));
        h.setFee(2000, 19);
    }

    function test_selectiveIssuancePreservesTheUnselectedVirtualClaim() public {
        _start(0, 1000, 0, 1000);
        (uint256 senior, uint256 fee) = h.takeIssuance(2, 40);
        assertEq(senior, 0);
        assertEq(fee, 4);
        assertEq(h.snapshot(40).seniorUnissued, 36);
        assertEq(h.snapshot(40).feeUnissued, 0);
        (senior, fee) = h.takeIssuance(1, 50);
        assertEq(senior, 45);
        assertEq(fee, 0);
        assertEq(h.snapshot(50).seniorUnissued, 0);
        assertEq(h.snapshot(50).feeUnissued, 1);
        (senior, fee) = h.takeIssuance(50);
        assertEq(senior, 0);
        assertEq(fee, 1);
        assertEq(h.snapshot(50).unissued, 0);
        assertEq(h.snapshot(50).unposted, 50);
    }

    function test_selectiveIssuanceInterleavesWithProspectiveFeeEpochs() public {
        _start(0, 1000, 0, 1000);
        (uint256 senior, uint256 fee) = h.takeIssuance(1, 30);
        assertEq(senior, 27);
        assertEq(fee, 0);
        h.setFee(2000, 30);
        (senior, fee) = h.takeIssuance(2, 40);
        assertEq(senior, 0);
        assertEq(fee, 5);
        assertEq(h.snapshot(40).seniorUnissued, 8);
        (senior, fee) = h.takeIssuance(1, 40);
        assertEq(senior, 8);
        assertEq(fee, 0);
        assertEq(h.snapshot(40).unissued, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(40), uint64(39)));
        h.setFee(10_000, 39);
    }

    function test_zeroSelectedClaimStillAdvancesSharedTime() public {
        _start(0, 100, 0, 100);
        h.setFee(0, 0);
        (uint256 senior, uint256 fee) = h.takeIssuance(2, 25);
        assertEq(senior, 0);
        assertEq(fee, 0);
        assertEq(h.snapshot(25).seniorUnissued, 25);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(25), uint64(24)));
        h.setFee(10_000, 24);
    }

    function test_invalidIssuanceMasksHaveNamedErrorsAndCannotSettle() public {
        vm.expectRevert(AccrualBook.AccrualBook_NotInitialized.selector);
        h.takeIssuance(1, 0);
        _start(0, 100, 0, 100);
        for (uint256 mask; mask <= type(uint8).max; ++mask) {
            if (mask >= 1 && mask <= 3) continue;
            vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_InvalidIssuanceLegs.selector, uint8(mask)));
            h.takeIssuance(uint8(mask), 50);
        }
        h.setFee(2000, 0);
        assertEq(h.snapshot(50).seniorUnissued, 40);
        assertEq(h.snapshot(50).feeUnissued, 10);
    }

    function test_stoppedCorrectionPreservesPostingIssuanceAndPastDueConservation() public {
        _start(0, 109, 0, 10);
        h.setPastDue(0, true, 2);
        h.stop(0, 3);
        assertEq(h.takePosting(0, 3), 32);
        (uint256 senior, uint256 fee) = h.takeIssuance(3);
        assertEq(senior, 29);
        assertEq(fee, 3);
        h.creditStoppedCorrection(0, 1, 3);
        AccrualBook.Snapshot memory s = h.snapshot(3);
        assertEq(s.gross, 33);
        assertEq(s.unposted, 1);
        assertEq(s.seniorUnissued, 1);
        assertEq(s.feeUnissued, 0);
        assertEq(h.earned(0, 3), 33);
        assertEq(h.groupUnposted(CLASS, 3), 1);
        assertEq(h.groupUnposted(BORROWER, 3), 1);
        assertEq(h.groupUnposted(STATE, 3), 1);
        assertEq(h.pastDueInterest(CLASS, 3), 1);
        assertEq(h.takePosting(0, 3), 1);
        assertEq(h.pastDueInterest(CLASS, 3), 0);
        h.setFee(10_000, 3);
        h.creditStoppedCorrection(0, 2, 4);
        (senior, fee) = h.takeIssuance(2, 4);
        assertEq(senior, 0);
        assertEq(fee, 2);
        assertEq(h.snapshot(4).seniorUnissued, 1);
        assertEq(h.snapshot(4).gross, 35);
    }

    function test_stoppedCorrectionRequiresRegisteredUnscheduledFacility() public {
        vm.expectRevert(AccrualBook.AccrualBook_NotInitialized.selector);
        h.creditStoppedCorrection(0, 1, 0);
        _start(0, 109, 0, 10);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnknownFacility.selector, uint256(1)));
        h.creditStoppedCorrection(1, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_AlreadyScheduled.selector, uint256(0)));
        h.creditStoppedCorrection(0, 1, 0);
        h.stop(0, 0);
        h.retire(0, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnknownFacility.selector, uint256(0)));
        h.creditStoppedCorrection(0, 1, 0);
    }

    function test_stoppedCorrectionRejectsBackdatedAndOverdueTimeButAllowsCurrentBoundary() public {
        _start(0, 0, 0, 30);
        h.register(1, _keys(), 0);
        h.creditStoppedCorrection(1, 0, 20);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(20), uint64(19)));
        h.creditStoppedCorrection(1, 1, 19);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(30), uint64(31))
        );
        h.creditStoppedCorrection(1, 1, 31);
        h.creditStoppedCorrection(1, 1, 30);
        assertFalse(h.snapshot(30).fresh);
        assertEq(h.snapshot(30).gross, 1);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(30), uint64(30))
        );
        h.takeIssuance(1, 30);
        h.finishNext(30);
        assertTrue(h.snapshot(30).fresh);
    }

    function test_stoppedCorrectionReservesAgainstOtherFacilityEndpoints() public {
        _start(0, type(uint256).max - 7, 0, 10);
        h.register(1, _keys(), 0);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        h.creditStoppedCorrection(1, 8, 0);
        h.creditStoppedCorrection(1, 7, 0);
        assertEq(h.snapshot(0).gross, 7);
        h.finishNext(10);
        assertEq(h.snapshot(10).gross, type(uint256).max);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        h.creditStoppedCorrection(1, 1, 10);
        h.creditStoppedCorrection(1, 0, 10);
        assertEq(h.earned(1, 10), 7);
    }

    function test_stoppedCorrectionAcceptsCanonicalOneScaleUnitGap() public {
        // Raw cumulative slope 2/3, technical [1,4], close 2: canonical floor(4/3)-
        // floor(2/3) = 1, whereas endpoint interpolation floor(2 * (2-1) / 3) = 0.
        _start(0, 2, 1, 4);
        h.stop(0, 2);
        assertEq(h.earned(0, 2), 0);
        h.creditStoppedCorrection(0, 1, 2);
        assertEq(h.earned(0, 2), 1);
        assertEq(h.snapshot(2).gross, 1);
    }

    function test_stoppedCorrectionSupportsFullWidthAmountAndTimestamp() public {
        uint64 at = type(uint64).max;
        h.initialize(at, 10_000);
        h.register(type(uint256).max, _keys(), at);
        h.creditStoppedCorrection(type(uint256).max, type(uint256).max, at);
        (uint256 senior, uint256 fee) = h.takeIssuance(1, at);
        assertEq(senior, 0);
        assertEq(fee, 0);
        assertEq(h.snapshot(at).feeUnissued, type(uint256).max);
        (senior, fee) = h.takeIssuance(2, at);
        assertEq(senior, 0);
        assertEq(fee, type(uint256).max);
        assertEq(h.takePosting(type(uint256).max, at), type(uint256).max);
        h.retire(type(uint256).max, at);
        assertEq(h.snapshot(at).unissued, 0);
        assertEq(h.snapshot(at).unposted, 0);
    }

    function test_capacityReleasesOnlyAfterResolution() public {
        h.initialize(0, 1000);
        for (uint256 id; id < 100; ++id) {
            h.register(id, _keys(), 0);
        }
        vm.expectRevert(AccrualBook.AccrualBook_Capacity.selector);
        h.register(100, _keys(), 0);
        h.open(0, 10, 0, 10);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnsettledFacility.selector, uint256(0)));
        h.retire(0, 1);
        h.stop(0, 1);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnsettledFacility.selector, uint256(0)));
        h.retire(0, 1);
        h.takePosting(0, 1);
        h.retire(0, 1);
        h.register(100, _keys(), 1);
        assertEq(h.registered(), 100);
    }

    function test_uint256EndpointFitsWithoutPrecisionMultiplication() public {
        _start(0, type(uint256).max, 0, 365 days);
        h.reconcile(0, 365 days - 1);
        h.finishNext(365 days);
        assertEq(h.snapshot(365 days).gross, type(uint256).max);
        assertEq(h.earned(0, 365 days), type(uint256).max);
    }

    function test_uint64TimeEndpointDoesNotWrap() public {
        uint64 end = type(uint64).max;
        _start(0, 19, end - 10, end);
        assertEq(h.reconcile(0, end - 1), 8);
        h.finishNext(end);
        assertEq(h.snapshot(end).gross, 19);
    }

    function test_corruptProjectionUsesNamedOverflowErrors() public {
        h.initialize(0, 1000);
        h.corruptProjection(0, type(uint256).max);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        h.snapshot(2);
        h.corruptProjection(type(uint256).max, 1);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        h.snapshot(1);
    }

    function test_zeroEndpointAndUnscheduledOperations() public {
        _start(0, 0, 0, 10);
        h.setPastDue(0, true, 0);
        assertEq(h.reconcile(0, 5), 0);
        h.finishNext(10);
        assertEq(h.stop(0, 10), 0);
        assertEq(h.reconcile(0, 10), 0);
        assertEq(h.takePosting(0, 10), 0);
        h.retire(0, 10);
        vm.expectRevert(AccrualBook.AccrualBook_NoBoundaryDue.selector);
        h.finishNext(10);
    }

    function testFuzz_cadenceDoesNotChangeFeesOrTerminalRecognition(uint192 amount, uint32 rawDuration, uint32 rawAt)
        public
    {
        uint64 duration = uint64(bound(rawDuration, 2, 365 days));
        uint64 at = uint64(bound(rawAt, 0, duration - 1));
        _start(0, amount, 0, duration);
        h.reconcile(0, at);
        uint256 posted = h.takePosting(0, at);
        (uint256 senior, uint256 fee) = h.takeIssuance(at);
        h.finishNext(duration);
        uint256 rest = h.takePosting(0, duration);
        (uint256 lastSenior, uint256 lastFee) = h.takeIssuance(duration);
        assertEq(posted + rest, amount);
        assertEq(fee + lastFee, uint256(amount) / 10);
        assertEq(senior + lastSenior, uint256(amount) - uint256(amount) / 10);
        AccrualBook.Snapshot memory s = h.snapshot(duration);
        assertEq(s.unposted, 0);
        assertEq(s.unissued, 0);
    }
}
