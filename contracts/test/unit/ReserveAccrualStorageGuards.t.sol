// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";

contract ReserveAccrualStorageProbe {
    using AccrualBook for AccrualBook.Book;

    function initialize(uint64 at) external {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.enabled = true;
        s.loans.book.initialize(at, 1000);
    }

    function seed(uint256 id, uint64 start, uint64 duration, uint256 rate) external {
        AccrualBook.Book storage book = ReserveAccrualStorageLib.state().loans.book;
        book.register(id, ReserveAccrualStorageLib.keys(1, bytes32(id), bytes32(id + 100)), start);
        book.open(id, rate * duration, start, start + duration);
    }

    function post(uint256 id) external returns (uint256) {
        return ReserveAccrualStorageLib.state().loans.book.takePosting(id, ReserveAccrualStorageLib.now64());
    }

    function setEnabled(bool enabled) external { ReserveAccrualStorageLib.state().enabled = enabled; }
    function now64() external view returns (uint64) { return ReserveAccrualStorageLib.now64(); }
    function frontier() external view returns (uint64) {
        return ReserveAccrualStorageLib.frontier(ReserveAccrualStorageLib.state());
    }
    function unposted() external view returns (uint256) { return ReserveAccrualStorageLib.unposted(); }
    function facilityUnposted(uint256 id) external view returns (uint256) {
        return ReserveAccrualStorageLib.facilityUnposted(id);
    }
}

contract ReserveAccrualStorageGuardsTest is Test {
    uint64 private constant START = 1_000_000;
    ReserveAccrualStorageProbe private probe;

    function setUp() public {
        vm.warp(START);
        probe = new ReserveAccrualStorageProbe();
        probe.initialize(START);
    }

    function test_clockOverflowIsExplicitWhileDisabledAndUnknownViewsRemainZero() public {
        probe.seed(1, START, 100, 13);
        vm.warp(type(uint64).max);
        assertEq(probe.now64(), type(uint64).max);
        vm.warp(uint256(type(uint64).max) + 1);
        vm.expectRevert(ReserveAccrualStorageLib.ReserveAccrual_TimeOverflow.selector);
        probe.now64();
        vm.expectRevert(ReserveAccrualStorageLib.ReserveAccrual_TimeOverflow.selector);
        probe.frontier();
        vm.expectRevert(ReserveAccrualStorageLib.ReserveAccrual_TimeOverflow.selector);
        probe.unposted();
        vm.expectRevert(ReserveAccrualStorageLib.ReserveAccrual_TimeOverflow.selector);
        probe.facilityUnposted(1);
        assertEq(probe.facilityUnposted(999), 0);
        probe.setEnabled(false);
        assertEq(probe.unposted(), 0);
        assertEq(probe.facilityUnposted(1), 0);
    }

    function test_oneOverdueBoundaryCapsEveryFacilityAndPreservesPriorPosting() public {
        probe.seed(1, START, 100, 13);
        probe.seed(2, START, 200, 7);
        vm.warp(START + 40);
        assertEq(probe.post(1), 520);
        assertEq(probe.unposted(), 280);
        vm.warp(START + 100);
        assertEq(probe.frontier(), START + 100);
        assertEq(probe.unposted(), 1480);
        vm.warp(START + 1 days);
        assertEq(probe.frontier(), START + 100);
        assertEq(probe.facilityUnposted(1), 780);
        assertEq(probe.facilityUnposted(2), 700);
        assertEq(probe.unposted(), 1480);
        assertEq(probe.facilityUnposted(999), 0);
        probe.setEnabled(false);
        assertEq(probe.unposted(), 0);
        assertEq(probe.facilityUnposted(1), 0);
    }

    /// @dev The reference walks all rows and sums their individual elapsed interest, including
    ///      independently tracked postings. The production views read one aggregate clock.
    function testFuzz_sharedClockMatchesAnIndependentRowSum(uint256 seed, uint8 countSeed, uint16 elapsedSeed)
        public
    {
        uint256 count = uint256(countSeed) % 9;
        uint256[] memory rates = new uint256[](count);
        uint256[] memory posted = new uint256[](count);
        uint64 now_ = START + 10 + uint64(elapsedSeed);
        uint64 earliest = now_;
        for (uint256 i; i < count; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint64 duration = 30 + uint64(seed % 1000);
            rates[i] = 1 + uint256(uint64(seed >> 64));
            probe.seed(i + 1, START, duration, rates[i]);
            if (START + duration < earliest) earliest = START + duration;
        }
        vm.warp(START + 10);
        for (uint256 i; i < count; i += 2) {
            posted[i] = 10 * rates[i];
            assertEq(probe.post(i + 1), posted[i]);
        }
        vm.warp(now_);
        uint256 expected;
        for (uint256 i; i < count; ++i) {
            uint256 row = rates[i] * (earliest - START) - posted[i];
            expected += row;
            assertEq(probe.facilityUnposted(i + 1), row, "facility clock differs from independent row");
        }
        assertEq(probe.frontier(), earliest, "frontier differs from earliest pending row");
        assertEq(probe.unposted(), expected, "aggregate clock differs from independently summed rows");
        assertEq(probe.facilityUnposted(count + 1), 0);
    }
}

contract ReserveAccrualStorageNativeTest is NativeAccrualFixture {
    function _pikFacilities() internal pure override returns (bool) { return true; }

    function test_overdueNativeViewsStayAtTheSharedFrontierUntilCatchup() public {
        _nativeFund(50_000e18);
        uint64 boundary = nativeStart + 90 days;
        vm.warp(boundary);
        uint256 backing = reserves.totalBackingValue();
        uint256 deployed = reserves.deployedPrincipal();
        uint256 face = reserves.deployedTo(nativeId);
        uint256 unposted = reserves.unpostedAccruedLoan(nativeId);
        assertGt(unposted, 0);
        assertFalse(reserves.accrualSnapshot().fresh);
        uint64 later = boundary + 60 days;
        vm.warp(later);
        assertEq(reserves.totalBackingValue(), backing, "backing advanced past a pending boundary");
        assertEq(reserves.deployedPrincipal(), deployed, "aggregate exposure advanced past a pending boundary");
        assertEq(reserves.deployedTo(nativeId), face, "facility exposure advanced past a pending boundary");
        assertEq(reserves.unpostedAccruedLoan(nativeId), unposted);
        _assertNativeBacking();
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, boundary, later));
        reserves.requireAccrualFresh();
        _nativeAdvance(later);
        assertTrue(reserves.accrualSnapshot().fresh);
        assertGt(reserves.totalBackingValue(), backing);
    }
}
