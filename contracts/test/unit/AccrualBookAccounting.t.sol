// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";

/// @dev Test host records independent physical-posting/issuance stand-ins. It does not claim to
///      validate actual reserve, registry, token callbacks, roles, or production integration.
contract AccrualBookAccountingHarness {
    using AccrualBook for AccrualBook.Book;
    using AccrualSchedule for AccrualSchedule.Heap;

    AccrualBook.Book internal book;
    uint256 public postedFace;
    uint256 public physicalSenior;
    uint256 public physicalFee;

    function initialize(uint64 at, uint16 feeBps) external {
        book.initialize(at, feeBps);
    }

    function register(uint256 id, bytes32[3] calldata keys, uint64 at) external {
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

    function requireFresh(uint64 at) external view {
        book.requireFresh(at);
    }

    function reconcile(uint256 id, uint64 at) external returns (uint256) {
        return book.reconcile(id, at);
    }

    function stop(uint256 id, uint64 at) external returns (uint256) {
        return book.stop(id, at);
    }

    function correct(uint256 id, uint256 amount, uint64 at) external {
        book.creditStoppedCorrection(id, amount, at);
    }

    function finishNext(uint64 at) external returns (uint256, uint64, uint256) {
        return book.finishNext(at);
    }

    function post(uint256 id, uint64 at) external returns (uint256 amount) {
        amount = book.takePosting(id, at);
        postedFace += amount;
    }

    function issue(uint64 at) external returns (uint256 senior, uint256 fee) {
        (senior, fee) = book.takeIssuance(at);
        physicalSenior += senior;
        physicalFee += fee;
    }

    function issue(uint8 legs, uint64 at) external returns (uint256 senior, uint256 fee) {
        (senior, fee) = book.takeIssuance(legs, at);
        physicalSenior += senior;
        physicalFee += fee;
    }

    function setFee(uint16 feeBps, uint64 at) external {
        book.setFee(feeBps, at);
    }

    function setPastDue(uint256 id, bool enabled, uint64 at) external {
        book.setPastDue(id, enabled, at);
    }

    function retire(uint256 id, uint64 at) external {
        book.retire(id, at);
    }

    function registeredCount() external view returns (uint256) {
        return book.registered;
    }

    function scheduledCount() external view returns (uint256) {
        return book.schedule.count();
    }

    function reservation() external view returns (uint256 recognized, uint256 unearned) {
        return (book.total.value, book.unearned);
    }

    function next() external view returns (uint256 id, uint64 deadline) {
        AccrualSchedule.Event memory event_ = book.schedule.peek();
        return (event_.facilityId, event_.deadline);
    }
}

/// @notice Independent accounting model: six facilities with shared class, borrower and state tags.
/// @dev The model sums each facility at every observation; it has no global or group rate index.
///      Exact partial entitlements use direct bounded multiplication, never library math helpers.
contract AccrualBookAccountingTest is Test {
    uint256 private constant COUNT = 6;
    uint64 private constant YEAR = 365 days;

    struct FacilityModel {
        uint256 base;
        uint256 amount;
        uint256 credited;
        uint256 posted;
        uint64 start;
        uint64 end;
        bool scheduled;
        bool pastDue;
    }

    struct Model {
        FacilityModel[6] facilities;
        uint256 feeBaseGross;
        uint256 feeBaseAmount;
        uint256 seniorIssued;
        uint256 feeIssued;
        uint16 feeBps;
    }

    AccrualBookAccountingHarness internal subject;

    function setUp() public {
        subject = new AccrualBookAccountingHarness();
    }

    function test_sixOverNineReconciliationNeverOutrunsGlobalGross() public {
        _single(subject, 6, 9, 3333);
        assertEq(subject.snapshot(3).gross, 0);
        assertEq(subject.earned(0, 3), 0);
        assertEq(subject.reconcile(0, 3), 2);
        assertEq(subject.snapshot(3).gross, 2);
        assertEq(subject.earned(0, 3), 2);
        assertEq(subject.reconcile(0, 3), 0);
        assertEq(subject.post(0, 3), 2);
        assertEq(subject.snapshot(3).unposted, 0);
        (,, uint256 residual) = subject.finishNext(9);
        assertEq(residual, 4);
        assertEq(subject.earned(0, 9), 6);
        assertEq(subject.snapshot(9).gross, 6);
        assertEq(subject.snapshot(9).fee, 1);
        assertEq(subject.post(0, 9), 4);
        (uint256 senior, uint256 fee) = subject.issue(9);
        assertEq(senior, 5);
        assertEq(fee, 1);
        assertEq(subject.snapshot(9).unissued, 0);
    }

    function test_twoFractionalFacilitiesNeverPoolAnUnattributableWei() public {
        subject.initialize(0, 0);
        _open(subject, 0, 2, 0, 3);
        _open(subject, 1, 2, 0, 3);
        assertEq(subject.snapshot(2).gross, 0);
        assertEq(subject.reconcile(_id(0), 2), 1);
        assertEq(subject.reconcile(_id(1), 2), 1);
        assertEq(subject.snapshot(2).gross, 2);
        assertEq(subject.stop(_id(0), 2), 0);
        assertEq(subject.post(_id(0), 2), 1);
        subject.retire(_id(0), 2);
        subject.finishNext(3);
        assertEq(subject.snapshot(3).gross, 3);
        assertEq(subject.post(_id(1), 3), 2);
        subject.issue(3);
        assertEq(subject.postedFace(), 3);
        assertEq(subject.physicalSenior(), 3);
    }

    function test_pastDueSharingTracksPostingCureAndStoppedClaims() public {
        subject.initialize(0, 0);
        _open(subject, 0, 101, 0, 10);
        _open(subject, 2, 205, 0, 10);
        bytes32 classKey = _tag(1, 0);
        assertEq(subject.post(_id(0), 2), 20);
        subject.setPastDue(_id(0), true, 2);
        subject.setPastDue(_id(2), true, 2);
        assertEq(subject.pastDueInterest(classKey, 4), 100);
        assertEq(subject.reconcile(_id(2), 4), 2);
        assertEq(subject.pastDueInterest(classKey, 4), 102);
        assertEq(subject.post(_id(2), 4), 82);
        assertEq(subject.pastDueInterest(classKey, 4), 20);
        subject.setPastDue(_id(0), false, 4);
        assertEq(subject.pastDueInterest(classKey, 4), 0);
        subject.setPastDue(_id(0), true, 5);
        assertEq(subject.pastDueInterest(classKey, 5), 50);
        subject.stop(_id(0), 5);
        assertEq(subject.pastDueInterest(classKey, 7), 90);
        assertEq(subject.post(_id(0), 7), 30);
        assertEq(subject.pastDueInterest(classKey, 7), 60);
        subject.setPastDue(_id(0), false, 7);
        subject.setPastDue(_id(0), false, 7);
        assertEq(subject.pastDueInterest(classKey, 7), 60);
    }

    function test_sameFeeSettingAndFrequentIssuanceCannotEraseFeeRounding() public {
        _single(subject, 100, 100, 1000);
        for (uint64 at = 1; at <= 10; ++at) {
            subject.setFee(1000, at);
            subject.checkpoint(at);
            subject.issue(at);
        }
        assertEq(subject.physicalSenior(), 9);
        assertEq(subject.physicalFee(), 1);
        assertEq(subject.snapshot(10).fee, 1);
        assertEq(subject.snapshot(10).unissued, 0);
    }

    function test_feeEpochChangesPreservePreviouslyIssuedAllocations() public {
        _single(subject, 101, 100, 3333);
        subject.issue(3);
        assertEq(subject.physicalSenior(), 3);
        assertEq(subject.physicalFee(), 0);
        subject.setFee(6667, 3);
        AccrualBook.Snapshot memory s = subject.snapshot(6);
        assertEq(s.gross, 6);
        assertEq(s.fee, 2);
        assertEq(s.seniorUnissued, 1);
        assertEq(s.feeUnissued, 2);
        subject.issue(6);
        subject.setFee(10_000, 50);
        s = subject.snapshot(60);
        assertEq(s.gross, 60);
        assertEq(s.fee, 41);
        assertEq(s.seniorUnissued + subject.physicalSenior(), 19);
        subject.issue(60);
        assertEq(subject.physicalFee(), 41);
        assertEq(subject.physicalSenior(), 19);
    }

    function test_tiedBoundariesCapAllViewsUntilEveryEndpointIsFinished() public {
        subject.initialize(0, 0);
        _open(subject, 1, 9, 0, 5);
        _open(subject, 0, 6, 0, 5);
        AccrualBook.Snapshot memory s = subject.snapshot(8);
        assertFalse(s.fresh);
        assertEq(s.accruedThrough, 5);
        assertEq(s.gross, 10);
        assertEq(subject.earned(_id(0), 8), 5);
        assertEq(subject.earned(_id(1), 8), 5);
        (uint256 id, uint64 deadline, uint256 residual) = subject.finishNext(8);
        assertEq(id, 0);
        assertEq(deadline, 5);
        assertEq(residual, 1);
        s = subject.snapshot(8);
        assertEq(s.gross, 11);
        assertFalse(s.fresh);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(5), uint64(8)));
        subject.issue(8);
        (id, deadline, residual) = subject.finishNext(8);
        assertEq(id, type(uint256).max);
        assertEq(deadline, 5);
        assertEq(residual, 4);
        s = subject.snapshot(8);
        assertTrue(s.fresh);
        assertEq(s.gross, 15);
        assertEq(s.accruedThrough, 8);
    }

    function test_zeroAmountStillHasDeterministicScheduleAndCanRetire() public {
        _single(subject, 0, 10, 10_000);
        subject.setPastDue(0, true, 3);
        assertEq(subject.reconcile(0, 7), 0);
        assertEq(subject.snapshot(9).gross, 0);
        assertFalse(subject.snapshot(10).fresh);
        subject.finishNext(10);
        assertEq(subject.post(0, 10), 0);
        subject.retire(0, 10);
        assertEq(subject.registeredCount(), 0);
        assertEq(subject.scheduledCount(), 0);
        assertEq(subject.pastDueInterest(_tag(1, 0), 10), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_KnownFacility.selector, uint256(0)));
        subject.register(0, _keys(0), 10);
    }

    function test_fullWidthEndpointAndFeeDoNotNeedAnIntermediateProduct() public {
        _single(subject, type(uint256).max, YEAR, 10_000);
        uint64 middle = YEAR / 2;
        uint256 q = type(uint256).max / YEAR;
        uint256 r = type(uint256).max % YEAR;
        uint256 expected = q * middle + r * middle / YEAR;
        subject.reconcile(0, middle);
        assertEq(subject.snapshot(middle).gross, expected);
        assertEq(subject.post(0, middle), expected);
        subject.issue(middle);
        subject.finishNext(YEAR);
        assertEq(subject.snapshot(YEAR).gross, type(uint256).max);
        assertEq(subject.snapshot(YEAR).fee, type(uint256).max);
        subject.post(0, YEAR);
        subject.issue(YEAR);
        assertEq(subject.postedFace(), type(uint256).max);
        assertEq(subject.physicalFee(), type(uint256).max);
        assertEq(subject.physicalSenior(), 0);
        assertEq(subject.snapshot(YEAR).unposted, 0);
        assertEq(subject.snapshot(YEAR).unissued, 0);
    }

    function test_timestampZeroAndMaximumAreExplicitValidEndpoints() public {
        uint64 start = type(uint64).max - 1;
        subject.initialize(start, 0);
        subject.register(type(uint256).max, _keys(0), start);
        subject.open(type(uint256).max, 7, start, type(uint64).max);
        assertEq(subject.snapshot(start).gross, 0);
        subject.finishNext(type(uint64).max);
        assertEq(subject.snapshot(type(uint64).max).gross, 7);
        subject.issue(type(uint64).max);
        assertEq(subject.physicalSenior(), 7);
    }

    function test_endpointEqualityIsStaleAndEarlierGlobalTimeHasNamedFailure() public {
        _single(subject, 13, 10, 0);
        subject.checkpoint(4);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(4), uint64(3)));
        subject.snapshot(3);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(10), uint64(10))
        );
        subject.requireFresh(10);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, uint64(10), uint64(11))
        );
        subject.checkpoint(11);
        vm.expectRevert(AccrualBook.AccrualBook_NoBoundaryDue.selector);
        subject.finishNext(9);
        assertEq(subject.scheduledCount(), 1);
    }

    function test_retirementPreservesHistoricalGrossAndExposurePosting() public {
        _single(subject, 17, 10, 1000);
        subject.stop(0, 5);
        assertEq(subject.earned(0, 5), 8);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnsettledFacility.selector, uint256(0)));
        subject.retire(0, 5);
        subject.post(0, 5);
        subject.retire(0, 5);
        assertEq(subject.snapshot(100).gross, 8);
        assertEq(subject.snapshot(100).unposted, 0);
        assertEq(subject.groupUnposted(_tag(1, 0), 100), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_UnknownFacility.selector, uint256(0)));
        subject.earned(0, 100);
        subject.issue(100);
        assertEq(subject.physicalSenior(), 8);
    }

    function test_issuanceCannotBeFollowedByRetroactiveFeePoisoning() public {
        _single(subject, 100, 100, 0);
        subject.issue(50);
        assertEq(subject.physicalSenior(), 50);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(50), uint64(0)));
        subject.setFee(10_000, 0);
        assertEq(subject.snapshot(50).gross, 50);
        assertEq(subject.snapshot(50).seniorUnissued, 0);
        subject.setFee(10_000, 50);
        assertEq(subject.snapshot(60).fee, 10);
        subject.issue(60);
        assertEq(subject.physicalSenior(), 50);
        assertEq(subject.physicalFee(), 10);
    }

    function test_postingAndRiskWritesAdvanceTheSharedAccountingClock() public {
        _single(subject, 100, 100, 0);
        subject.post(0, 30);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(30), uint64(29)));
        subject.setFee(1000, 29);
        subject.setPastDue(0, true, 40);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(40), uint64(39)));
        subject.checkpoint(39);
        assertEq(subject.pastDueInterest(_tag(1, 0), 40), 10);
        subject.stop(0, 50);
        subject.post(0, 50);
        subject.retire(0, 60);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, uint64(60), uint64(59)));
        subject.checkpoint(59);
    }

    function test_combinedEndpointsCannotPoisonFutureNavWithOverflow() public {
        subject.initialize(0, 0);
        subject.register(_id(0), _keys(0), 0);
        subject.register(_id(1), _keys(1), 0);
        subject.open(_id(0), type(uint256).max - 7, 0, 10);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        subject.open(_id(1), 8, 0, 10);
        assertEq(subject.scheduledCount(), 1);
        subject.open(_id(1), 7, 0, 10);
        (uint256 recognized, uint256 unearned) = subject.reservation();
        assertEq(recognized, 0);
        assertEq(unearned, type(uint256).max);
        subject.finishNext(10);
        subject.finishNext(10);
        assertEq(subject.snapshot(10).gross, type(uint256).max);
        (recognized, unearned) = subject.reservation();
        assertEq(recognized, type(uint256).max);
        assertEq(unearned, 0);
        subject.issue(10);
        subject.post(_id(0), 10);
        subject.post(_id(1), 10);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        subject.open(_id(0), 1, 10, 11);
        assertEq(subject.physicalSenior(), type(uint256).max);
        assertEq(subject.postedFace(), type(uint256).max);
    }

    function test_reservationConsumesGrowthAndRemaindersButPostingAndIssuanceAreNeutral() public {
        _single(subject, 17, 10, 0);
        subject.checkpoint(3);
        _assertReservationPair(3, 14);
        assertEq(subject.reconcile(0, 3), 2);
        _assertReservationPair(5, 12);
        subject.post(0, 3);
        _assertReservationPair(5, 12);
        subject.issue(3);
        _assertReservationPair(5, 12);
        subject.setPastDue(0, true, 4);
        _assertReservationPair(6, 11);
        subject.setFee(2000, 5);
        _assertReservationPair(7, 10);
        subject.finishNext(10);
        _assertReservationPair(17, 0);
    }

    function testFuzz_mixed32StepTrace(uint256 seed) public {
        _trace(seed, 32);
    }

    function testFuzz_mixed64StepTrace(uint256 seed) public {
        _trace(seed, 64);
    }

    function testFuzz_partialReconciliationsPreserveExactEndpoint(uint128 amount, uint24 durationSeed, uint256 seed)
        public
    {
        uint64 duration = uint64(uint256(durationSeed) % YEAR + 1);
        _single(subject, amount, duration, 1234);
        uint64 at;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            at += uint64(seed % (duration - at));
            subject.reconcile(0, at);
            uint256 exact = uint256(amount) * at / duration;
            assertEq(subject.snapshot(at).gross, exact);
            assertEq(subject.earned(0, at), exact);
            assertEq(subject.reconcile(0, at), 0);
            subject.post(0, at);
            subject.issue(at);
        }
        subject.finishNext(duration);
        subject.post(0, duration);
        subject.issue(duration);
        assertEq(subject.snapshot(duration).gross, amount);
        assertEq(subject.postedFace(), amount);
        assertEq(subject.physicalSenior() + subject.physicalFee(), amount);
        assertEq(subject.physicalFee(), uint256(amount) * 1234 / 10_000);
    }

    function testFuzz_issuePostingOrderPreservesEveryEffectiveQuantity(
        uint128 first,
        uint128 second,
        uint16 feeSeed,
        uint24 durationSeed,
        uint24 atSeed
    ) public {
        uint64 duration = uint64(uint256(durationSeed) % YEAR + 1);
        uint64 at = uint64(uint256(atSeed) % duration);
        uint16 feeBps = uint16(uint256(feeSeed) % 10_001);
        AccrualBookAccountingHarness other = new AccrualBookAccountingHarness();
        subject.initialize(0, feeBps);
        other.initialize(0, feeBps);
        _open(subject, 0, first, 0, duration);
        _open(subject, 1, second, 0, duration);
        _open(other, 0, first, 0, duration);
        _open(other, 1, second, 0, duration);
        for (uint256 i; i < 2; ++i) {
            subject.reconcile(_id(i), at);
            other.reconcile(_id(i), at);
        }
        uint256 gross = uint256(first) * at / duration + uint256(second) * at / duration;
        subject.post(_id(0), at);
        subject.post(_id(1), at);
        subject.issue(at);
        other.issue(2, at);
        other.post(_id(1), at);
        other.issue(1, at);
        other.post(_id(0), at);
        assertEq(subject.postedFace(), gross);
        assertEq(other.postedFace(), gross);
        assertEq(subject.physicalSenior(), other.physicalSenior());
        assertEq(subject.physicalFee(), other.physicalFee());
        assertEq(subject.physicalFee(), gross * feeBps / 10_000);
        assertEq(subject.snapshot(at).unposted, 0);
        assertEq(subject.snapshot(at).unissued, 0);
        assertEq(other.snapshot(at).unposted, 0);
        assertEq(other.snapshot(at).unissued, 0);
    }

    function testFuzz_sameFeeEpochSurvivesArbitraryCheckpointPartition(
        uint128 amount,
        uint16 feeSeed,
        uint24 durationSeed,
        uint256 seed
    ) public {
        uint64 duration = uint64(uint256(durationSeed) % YEAR + 1);
        uint16 feeBps = uint16(uint256(feeSeed) % 10_001);
        _single(subject, amount, duration, feeBps);
        uint64 at;
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            at += uint64(seed % (duration - at));
            subject.setFee(feeBps, at);
            subject.checkpoint(at);
            subject.issue(uint8((seed >> 128) % 3 + 1), at);
        }
        subject.finishNext(duration);
        subject.issue(duration);
        assertEq(subject.physicalFee(), uint256(amount) * feeBps / 10_000);
        assertEq(subject.physicalSenior(), uint256(amount) - uint256(amount) * feeBps / 10_000);
        assertEq(subject.snapshot(duration).unissued, 0);
    }

    function testFuzz_fullWidthEarlyStopReleasesOnlyUnearnedAdmissionRoom(
        uint128 tail,
        uint24 durationSeed,
        uint24 stopSeed
    ) public {
        uint64 duration = uint64(uint256(durationSeed) % YEAR + 1);
        uint64 stopAt = uint64(uint256(stopSeed) % duration);
        uint256 amount = type(uint256).max - tail;
        subject.initialize(0, 371);
        subject.register(_id(0), _keys(0), 0);
        subject.register(_id(1), _keys(1), 0);
        subject.open(_id(0), amount, 0, duration);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        subject.open(_id(1), uint256(tail) + 1, 0, duration);
        subject.stop(_id(0), stopAt);
        uint256 earned = (amount / duration) * stopAt + (amount % duration) * stopAt / duration;
        assertEq(subject.earned(_id(0), stopAt), earned);
        _assertReservationPair(earned, 0);
        subject.post(_id(0), stopAt);
        subject.issue(stopAt);
        subject.open(_id(1), type(uint256).max - earned, stopAt, stopAt + duration);
        _assertReservationPair(earned, type(uint256).max - earned);
        subject.finishNext(stopAt + duration);
        _assertReservationPair(type(uint256).max, 0);
        subject.post(_id(1), stopAt + duration);
        subject.issue(stopAt + duration);
        assertEq(subject.postedFace(), type(uint256).max);
        assertEq(subject.physicalSenior() + subject.physicalFee(), type(uint256).max);
        uint256 fee = (type(uint256).max / 10_000) * 371 + (type(uint256).max % 10_000) * 371 / 10_000;
        assertEq(subject.physicalFee(), fee);
    }

    function testFuzz_stoppedCorrectionCannotBorrowOtherReservedEndpointRoom(uint128 room, uint128 rawCredit) public {
        uint256 credit = uint256(rawCredit) % (uint256(room) + 1);
        subject.initialize(0, 731);
        subject.register(_id(0), _keys(0), 0);
        subject.register(_id(1), _keys(1), 0);
        subject.open(_id(1), type(uint256).max - room, 0, 1);
        subject.correct(_id(0), credit, 0);
        _assertReservationPair(credit, type(uint256).max - room);
        assertEq(subject.earned(_id(0), 0), credit);
        vm.expectRevert(AccrualBook.AccrualBook_Overflow.selector);
        subject.correct(_id(0), uint256(room) - credit + 1, 0);
        subject.finishNext(1);
        uint256 gross = type(uint256).max - room + credit;
        _assertReservationPair(gross, 0);
        subject.issue(2, 1);
        subject.post(_id(1), 1);
        subject.issue(1, 1);
        subject.post(_id(0), 1);
        assertEq(subject.postedFace(), gross);
        assertEq(subject.physicalSenior() + subject.physicalFee(), gross);
        assertEq(subject.snapshot(1).unposted, 0);
        assertEq(subject.snapshot(1).unissued, 0);
    }

    function testFuzz_stoppedCorrectionAndFeeEpochKeepAllHistoricalClaims(
        uint128 amount,
        uint128 correction,
        uint16 feeSeed,
        uint16 nextFeeSeed,
        uint8 maskSeed
    ) public {
        uint16 feeBps = uint16(uint256(feeSeed) % 10_001);
        uint16 nextFeeBps = uint16(uint256(nextFeeSeed) % 10_001);
        uint8 mask = uint8(uint256(maskSeed) % 3 + 1);
        _single(subject, amount, 3, feeBps);
        subject.setPastDue(0, true, 0);
        subject.stop(0, 1);
        uint256 earned = uint256(amount) / 3;
        subject.post(0, 1);
        subject.issue(mask, 1);
        subject.setFee(nextFeeBps, 1);
        subject.correct(0, correction, 1);
        uint256 gross = earned + correction;
        // An unchanged rate keeps its original fractional base; a changed rate starts a
        // prospective epoch after exactly the already-earned amount, regardless of issuance.
        uint256 fee = feeBps == nextFeeBps
            ? gross * feeBps / 10_000
            : earned * feeBps / 10_000 + uint256(correction) * nextFeeBps / 10_000;
        _assertCorrectedClaims(gross, fee, correction, 1);
        if (mask != 3) subject.issue(3 ^ mask, 1);
        subject.issue(1);
        subject.post(0, 1);
        assertEq(subject.physicalFee(), fee);
        assertEq(subject.physicalSenior(), gross - fee);
        assertEq(subject.postedFace(), gross);
        assertEq(subject.pastDueInterest(_tag(1, 0), 1), 0);
        subject.retire(0, 1);
        assertEq(subject.snapshot(1).unissued, 0);
        assertEq(subject.snapshot(1).unposted, 0);
    }

    function _assertCorrectedClaims(uint256 gross, uint256 fee, uint256 unposted, uint64 at) private view {
        AccrualBook.Snapshot memory s = subject.snapshot(at);
        assertEq(s.gross, gross);
        assertEq(s.fee, fee);
        assertEq(subject.physicalFee() + s.feeUnissued, fee);
        assertEq(subject.physicalSenior() + s.seniorUnissued, gross - fee);
        assertEq(subject.postedFace() + s.unposted, gross);
        assertEq(s.unposted, unposted);
        assertEq(subject.earned(0, at), gross);
        for (uint256 domain = 1; domain <= 3; ++domain) {
            assertEq(subject.groupUnposted(_tag(domain, 0), at), unposted);
        }
        assertEq(subject.pastDueInterest(_tag(1, 0), at), unposted);
        _assertReservationPair(gross, 0);
    }

    function _trace(uint256 seed, uint256 steps) private {
        Model memory model;
        model.feeBps = uint16(seed % 10_001);
        subject.initialize(0, model.feeBps);
        for (uint256 i; i < COUNT; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = seed % 1e28;
            uint64 end = uint64((seed >> 128) % 23 + 1);
            _open(subject, i, amount, 0, end);
            _modelOpen(model.facilities[i], amount, 0, end);
        }
        uint64 at;
        _assertModel(model, at);
        for (uint256 step; step < steps; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 11;
            if (action == 0) {
                at += uint64((seed >> 64) % 7 + 1);
                _assertModel(model, at);
                _finishDue(model, at);
            } else {
                _action(model, action, (seed >> 32) % COUNT, at, seed);
            }
            _assertModel(model, at);
        }
    }

    function _action(Model memory model, uint256 action, uint256 i, uint64 at, uint256 seed) private {
        FacilityModel memory f = model.facilities[i];
        uint256 id = _id(i);
        if (action == 1) {
            uint256 extra = _modelReconcile(model.facilities[i], at);
            assertEq(subject.reconcile(id, at), extra);
        } else if (action == 2) {
            uint256 amount = _modelEarned(f, at) - f.posted;
            assertEq(subject.post(id, at), amount);
            model.facilities[i].posted += amount;
        } else if (action == 3) {
            bool enabled = seed & (1 << 80) != 0;
            subject.setPastDue(id, enabled, at);
            model.facilities[i].pastDue = enabled;
        } else if (action == 4) {
            _issueSelected(model, uint8((seed >> 128) % 3 + 1), at);
        } else if (action == 5 || action == 9) {
            uint16 feeBps = action == 9 ? model.feeBps : uint16((seed >> 96) % 10_001);
            subject.setFee(feeBps, at);
            if (feeBps != model.feeBps) {
                uint256 gross = _modelGross(model, at);
                model.feeBaseAmount = _modelFee(model, gross);
                model.feeBaseGross = gross;
                model.feeBps = feeBps;
            }
        } else if (action == 6) {
            if (!f.scheduled) {
                uint256 amount = (seed >> 64) % 1e28;
                uint64 end = at + uint64((seed >> 160) % 23 + 1);
                subject.open(id, amount, at, end);
                _modelOpen(model.facilities[i], amount, at, end);
            }
        } else if (action == 7) {
            subject.checkpoint(at);
        } else if (action == 8) {
            uint256 extra = _modelReconcile(model.facilities[i], at);
            assertEq(subject.stop(id, at), extra);
            if (f.scheduled) {
                model.facilities[i].base = _modelEarned(model.facilities[i], at);
                model.facilities[i].scheduled = false;
            }
        } else if (!f.scheduled) {
            uint256 correction = (seed >> 96) % 1e12;
            subject.correct(id, correction, at);
            model.facilities[i].base += correction;
        }
    }

    function _issueSelected(Model memory model, uint8 legs, uint64 at) private {
        uint256 gross = _modelGross(model, at);
        uint256 fee = _modelFee(model, gross);
        (uint256 seniorIssued, uint256 feeIssued) = subject.issue(legs, at);
        assertEq(seniorIssued, legs == 2 ? 0 : gross - fee - model.seniorIssued);
        assertEq(feeIssued, legs == 1 ? 0 : fee - model.feeIssued);
        model.seniorIssued += seniorIssued;
        model.feeIssued += feeIssued;
    }

    function _finishDue(Model memory model, uint64 at) private {
        while (true) {
            (bool found, uint256 i, uint64 boundary) = _minimum(model);
            if (!found || boundary > at) return;
            FacilityModel memory f = model.facilities[i];
            uint256 residual = f.amount - (f.amount / (f.end - f.start)) * (f.end - f.start) - f.credited;
            (uint256 actualId, uint64 actualBoundary, uint256 actualResidual) = subject.finishNext(at);
            assertEq(actualId, _id(i));
            assertEq(actualBoundary, boundary);
            assertEq(actualResidual, residual);
            model.facilities[i].base += f.amount;
            model.facilities[i].scheduled = false;
            _assertModel(model, at);
        }
    }

    function _assertModel(Model memory model, uint64 at) private view {
        (bool found, uint256 nextIndex, uint64 boundary) = _minimum(model);
        uint64 through = found && boundary <= at ? boundary : at;
        _assertTotals(model, at, through);
        _assertModelReservation(model, through);
        assertEq(subject.snapshot(at).fresh, !found || boundary > at);
        if (found) {
            (uint256 actualId, uint64 actualBoundary) = subject.next();
            assertEq(actualId, _id(nextIndex));
            assertEq(actualBoundary, boundary);
        }
        for (uint256 domain = 1; domain <= 3; ++domain) {
            uint256 groups = domain == 2 ? 3 : 2;
            for (uint256 group; group < groups; ++group) {
                _assertGroup(model, domain, group, at, through);
            }
        }
    }

    function _assertTotals(Model memory model, uint64 at, uint64 through) private view {
        uint256 gross = _modelGross(model, through);
        uint256 fee = _modelFee(model, gross);
        uint256 posted;
        uint256 scheduled;
        for (uint256 i; i < COUNT; ++i) {
            assertEq(subject.earned(_id(i), at), _modelEarned(model.facilities[i], through));
            posted += model.facilities[i].posted;
            if (model.facilities[i].scheduled) ++scheduled;
        }
        AccrualBook.Snapshot memory s = subject.snapshot(at);
        assertEq(s.gross, gross);
        assertEq(s.fee, fee);
        assertEq(s.unposted, gross - posted);
        assertEq(s.seniorUnissued, gross - fee - model.seniorIssued);
        assertEq(s.feeUnissued, fee - model.feeIssued);
        assertEq(s.unissued, gross - model.seniorIssued - model.feeIssued);
        assertEq(s.accruedThrough, through);
        assertEq(subject.registeredCount(), COUNT);
        assertEq(subject.scheduledCount(), scheduled);
        assertEq(subject.postedFace() + s.unposted, gross);
        assertEq(subject.physicalSenior() + s.seniorUnissued, gross - fee);
        assertEq(subject.physicalFee() + s.feeUnissued, fee);
    }

    function _assertGroup(Model memory model, uint256 domain, uint256 group, uint64 at, uint64 through) private view {
        uint256 unposted;
        uint256 risk;
        for (uint256 i; i < COUNT; ++i) {
            if ((domain == 2 ? i % 3 : i % 2) != group) continue;
            uint256 amount = _modelEarned(model.facilities[i], through) - model.facilities[i].posted;
            unposted += amount;
            if (model.facilities[i].pastDue) risk += amount;
        }
        assertEq(subject.groupUnposted(_tag(domain, group), at), unposted);
        if (domain == 1) assertEq(subject.pastDueInterest(_tag(domain, group), at), risk);
    }

    function _assertModelReservation(Model memory model, uint64 through) private view {
        uint256 future;
        for (uint256 i; i < COUNT; ++i) {
            FacilityModel memory f = model.facilities[i];
            if (f.scheduled) future += f.amount - (_modelEarned(f, through) - f.base);
        }
        (uint256 recognized, uint256 unearned) = subject.reservation();
        assertEq(recognized + unearned, _modelGross(model, through) + future);
    }

    function _assertReservationPair(uint256 expectedRecognized, uint256 expectedUnearned) private view {
        (uint256 recognized, uint256 unearned) = subject.reservation();
        assertEq(recognized, expectedRecognized);
        assertEq(unearned, expectedUnearned);
    }

    function _modelOpen(FacilityModel memory f, uint256 amount, uint64 start, uint64 end) private pure {
        f.amount = amount;
        f.credited = 0;
        f.start = start;
        f.end = end;
        f.scheduled = true;
    }

    function _modelReconcile(FacilityModel memory f, uint64 at) private pure returns (uint256 extra) {
        if (!f.scheduled) return 0;
        uint256 duration = f.end - f.start;
        uint256 elapsed = at - f.start;
        uint256 exact = f.amount * elapsed / duration;
        uint256 integerStream = (f.amount / duration) * elapsed;
        uint256 cumulative = exact - integerStream;
        extra = cumulative - f.credited;
        f.credited = cumulative;
    }

    function _modelEarned(FacilityModel memory f, uint64 at) private pure returns (uint256) {
        if (!f.scheduled) return f.base;
        return f.base + (f.amount / (f.end - f.start)) * (at - f.start) + f.credited;
    }

    function _modelGross(Model memory model, uint64 at) private pure returns (uint256 gross) {
        for (uint256 i; i < COUNT; ++i) {
            gross += _modelEarned(model.facilities[i], at);
        }
    }

    function _modelFee(Model memory model, uint256 gross) private pure returns (uint256) {
        return model.feeBaseAmount + (gross - model.feeBaseGross) * model.feeBps / 10_000;
    }

    function _minimum(Model memory model) private pure returns (bool found, uint256 index, uint64 deadline) {
        for (uint256 i; i < COUNT; ++i) {
            FacilityModel memory f = model.facilities[i];
            if (!f.scheduled) continue;
            if (!found || f.end < deadline || (f.end == deadline && _id(i) < _id(index))) {
                found = true;
                index = i;
                deadline = f.end;
            }
        }
    }

    function _single(AccrualBookAccountingHarness h, uint256 amount, uint64 duration, uint16 feeBps) private {
        h.initialize(0, feeBps);
        _open(h, 0, amount, 0, duration);
    }

    function _open(AccrualBookAccountingHarness h, uint256 i, uint256 amount, uint64 start, uint64 end) private {
        h.register(_id(i), _keys(i), start);
        h.open(_id(i), amount, start, end);
    }

    function _keys(uint256 i) private pure returns (bytes32[3] memory keys) {
        keys[0] = _tag(1, i % 2);
        keys[1] = _tag(2, i % 3);
        keys[2] = _tag(3, i % 2);
    }

    function _tag(uint256 domain, uint256 group) private pure returns (bytes32) {
        return bytes32((domain << 128) | (group + 1));
    }

    function _id(uint256 i) private pure returns (uint256) {
        if (i == 0) return 0;
        if (i == 1) return type(uint256).max;
        if (i == 2) return uint256(1) << 255;
        if (i == 3) return (uint256(1) << 192) + 5;
        return i == 4 ? 77 : 42;
    }
}
