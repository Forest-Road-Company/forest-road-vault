// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";

/// @dev Test-only external adapter and storage inspector. Production authorization belongs to
///      the eventual host; this intentionally unrestricted harness is not a deployable module.
contract AccrualScheduleHarness {
    using AccrualSchedule for AccrualSchedule.Heap;

    AccrualSchedule.Heap private heap;

    function count() external view returns (uint256) {
        return heap.count();
    }

    function contains(uint256 facilityId) external view returns (bool) {
        return heap.contains(facilityId);
    }

    function peek() external view returns (AccrualSchedule.Event memory) {
        return heap.peek();
    }

    function get(uint256 facilityId) external view returns (AccrualSchedule.Event memory) {
        return heap.get(facilityId);
    }

    function insert(uint256 facilityId, uint64 deadline) external {
        heap.insert(facilityId, deadline);
    }

    function reschedule(uint256 facilityId, uint64 deadline) external returns (uint64) {
        return heap.reschedule(facilityId, deadline);
    }

    function remove(uint256 facilityId) external returns (AccrualSchedule.Event memory) {
        return heap.remove(facilityId);
    }

    function pop() external returns (AccrualSchedule.Event memory) {
        return heap.pop();
    }

    /// @dev Returns every entry and reverse positions for a supplied universe, including absent
    ///      identifiers. This exposes stale mapping entries that an entries-only inspection misses.
    function inspect(uint256[] calldata ids)
        external
        view
        returns (AccrualSchedule.Event[] memory entries, uint256[] memory positions)
    {
        entries = heap.entries;
        positions = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            positions[i] = heap.positions[ids[i]];
        }
    }
}

/// @title AccrualScheduleTest — indexed heap checked against a separate linear minimum model
/// @dev Run all fuzz properties with at least 10,000 cases. The model stores an unordered fixed
///      universe with active flags; it never reproduces insertion, sifting or removal algorithms.
contract AccrualScheduleTest is Test {
    struct Model {
        uint256[] ids;
        uint64[] deadlines;
        bool[] active;
    }

    AccrualScheduleHarness internal subject;

    function setUp() public {
        subject = new AccrualScheduleHarness();
    }

    function test_emptyReadsAndRemovalsHaveSpecificErrors() public {
        assertEq(subject.count(), 0);
        assertFalse(subject.contains(0));
        assertFalse(subject.contains(type(uint256).max));
        vm.expectRevert(AccrualSchedule.AccrualSchedule_Empty.selector);
        subject.peek();
        vm.expectRevert(AccrualSchedule.AccrualSchedule_Empty.selector);
        subject.pop();
        _expectMissing(0);
        subject.get(0);
        _expectMissing(type(uint256).max);
        subject.remove(type(uint256).max);
        _expectMissing(7);
        subject.reschedule(7, 1);
    }

    function test_zeroIdAndZeroDeadlineAreValidAndReusable() public {
        subject.insert(0, 0);
        assertTrue(subject.contains(0));
        _assertEvent(subject.peek(), 0, 0);
        assertEq(subject.reschedule(0, type(uint64).max), 0);
        _assertEvent(subject.get(0), 0, type(uint64).max);
        _assertEvent(subject.remove(0), 0, type(uint64).max);
        assertEq(subject.count(), 0);
        assertFalse(subject.contains(0));
        subject.insert(0, 0);
        _assertEvent(subject.pop(), 0, 0);
        assertFalse(subject.contains(0));
    }

    function test_maximumIdentifiersAndTimestampsAreNotNarrowed() public {
        uint256 highId = (uint256(1) << 255) + 1;
        subject.insert(type(uint256).max, type(uint64).max);
        subject.insert(highId, type(uint64).max);
        subject.insert(1, type(uint64).max);
        _assertEvent(subject.pop(), 1, type(uint64).max);
        _assertEvent(subject.pop(), highId, type(uint64).max);
        _assertEvent(subject.pop(), type(uint256).max, type(uint64).max);
        assertEq(subject.count(), 0);
    }

    function test_duplicateCannotReplaceAnExistingDeadline() public {
        subject.insert(0, 17);
        vm.expectRevert(abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_AlreadyScheduled.selector, uint256(0)));
        subject.insert(0, 0);
        assertEq(subject.count(), 1);
        _assertEvent(subject.get(0), 0, 17);
    }

    function test_missingMutationCannotChangeOtherFacilities() public {
        subject.insert(1, 8);
        _expectMissing(2);
        subject.remove(2);
        _expectMissing(2);
        subject.reschedule(2, 0);
        _assertEvent(subject.peek(), 1, 8);
        assertEq(subject.count(), 1);
    }

    function test_descendingInsertionsDrainInDeadlineOrder() public {
        for (uint64 i = 16; i != 0; --i) {
            subject.insert(i, i);
        }
        for (uint64 i = 1; i <= 16; ++i) {
            _assertEvent(subject.pop(), i, i);
            assertFalse(subject.contains(i));
        }
        assertEq(subject.count(), 0);
    }

    function test_equalDeadlinesUseFullIdentifierOrder() public {
        subject.insert(17, 0);
        subject.insert(type(uint256).max, 0);
        subject.insert(1, 0);
        subject.insert(0, 0);
        _assertEvent(subject.pop(), 0, 0);
        _assertEvent(subject.pop(), 1, 0);
        _assertEvent(subject.pop(), 17, 0);
        _assertEvent(subject.pop(), type(uint256).max, 0);
    }

    function test_rescheduleLeafMovesUpToRoot() public {
        for (uint64 i = 1; i <= 7; ++i) {
            subject.insert(i, i * 10);
        }
        assertEq(subject.reschedule(7, 0), 70);
        _assertEvent(subject.peek(), 7, 0);
        assertEq(subject.count(), 7);
        _assertEvent(subject.get(7), 7, 0);
        _assertEvent(subject.remove(7), 7, 0);
        for (uint64 i = 1; i <= 6; ++i) {
            _assertEvent(subject.pop(), i, i * 10);
        }
    }

    function test_rescheduleRootMovesDownThroughRightChild() public {
        subject.insert(1, 10);
        subject.insert(2, 30);
        subject.insert(3, 20);
        subject.insert(4, 50);
        subject.insert(5, 40);
        subject.insert(6, 35);
        assertEq(subject.reschedule(1, 100), 10);
        _assertEvent(subject.pop(), 3, 20);
        _assertEvent(subject.pop(), 2, 30);
        _assertEvent(subject.pop(), 6, 35);
        _assertEvent(subject.pop(), 5, 40);
        _assertEvent(subject.pop(), 4, 50);
        _assertEvent(subject.pop(), 1, 100);
    }

    function test_rescheduleDoesNotSwapPastAnEarlierParentOrChild() public {
        subject.insert(1, 10);
        subject.insert(2, 20);
        subject.insert(3, 30);
        assertEq(subject.reschedule(2, 19), 20);
        assertEq(subject.reschedule(1, 11), 10);
        _assertEvent(subject.pop(), 1, 11);
        _assertEvent(subject.pop(), 2, 19);
        _assertEvent(subject.pop(), 3, 30);
    }

    function test_sameDeadlineRescheduleIsExactNoOp() public {
        subject.insert(2, 10);
        subject.insert(1, 10);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        (AccrualSchedule.Event[] memory beforeEntries, uint256[] memory beforePositions) = subject.inspect(ids);
        assertEq(subject.reschedule(2, 10), 10);
        (AccrualSchedule.Event[] memory afterEntries, uint256[] memory afterPositions) = subject.inspect(ids);
        assertEq(abi.encode(beforeEntries, beforePositions), abi.encode(afterEntries, afterPositions));
    }

    function test_rescheduleToAnEqualDeadlineUsesIdentifierTieBreaker() public {
        subject.insert(2, 10);
        subject.insert(1, 20);
        subject.reschedule(1, 10);
        _assertEvent(subject.peek(), 1, 10);
        subject.reschedule(1, 20);
        _assertEvent(subject.peek(), 2, 10);
    }

    function test_removeRootMiddleAndLastLeavesNoTombstones() public {
        for (uint64 i = 1; i <= 7; ++i) {
            subject.insert(i, i);
        }
        _assertEvent(subject.remove(7), 7, 7); // the last array element
        _assertEvent(subject.remove(2), 2, 2); // replacement needs to move down
        _assertEvent(subject.remove(1), 1, 1); // root
        assertFalse(subject.contains(7));
        assertFalse(subject.contains(2));
        assertFalse(subject.contains(1));
        _assertEvent(subject.pop(), 3, 3);
        _assertEvent(subject.pop(), 4, 4);
        _assertEvent(subject.pop(), 5, 5);
        _assertEvent(subject.pop(), 6, 6);
        assertEq(subject.count(), 0);
        subject.insert(2, 0);
        _assertEvent(subject.pop(), 2, 0);
    }

    function test_removeMiddleCanRequireAnUpwardRepair() public {
        // The valid heap is [1,10,2,11,12,3,4]. Replacing the 11 leaf with the last 4 puts
        // it below parent 10: only a DOWNWARD repair would leave an invalid heap here.
        subject.insert(1, 1);
        subject.insert(2, 10);
        subject.insert(3, 2);
        subject.insert(4, 11);
        subject.insert(5, 12);
        subject.insert(6, 3);
        subject.insert(7, 4);
        _assertEvent(subject.remove(4), 4, 11);
        // Inspect NOW. Draining alone is insufficient: later root removals can repair this
        // transient violation and still return a sorted stream with the upward repair deleted.
        Model memory model = _newModel(bytes32(0));
        uint64[7] memory deadlines = [uint64(1), 10, 2, 11, 12, 3, 4];
        for (uint256 i = 1; i <= 7; ++i) {
            model.active[i] = i != 4;
            model.deadlines[i] = deadlines[i - 1];
        }
        _assertModel(model);
        _assertEvent(subject.pop(), 1, 1);
        _assertEvent(subject.pop(), 3, 2);
        _assertEvent(subject.pop(), 6, 3);
        _assertEvent(subject.pop(), 7, 4);
        _assertEvent(subject.pop(), 2, 10);
        _assertEvent(subject.pop(), 5, 12);
    }

    function test_removeSingletonDeletesPositionAndAllowsIdReuse() public {
        subject.insert(type(uint256).max, 0);
        _assertEvent(subject.remove(type(uint256).max), type(uint256).max, 0);
        assertFalse(subject.contains(type(uint256).max));
        _expectMissing(type(uint256).max);
        subject.get(type(uint256).max);
        subject.insert(type(uint256).max, type(uint64).max);
        _assertEvent(subject.pop(), type(uint256).max, type(uint64).max);
    }

    function test_readsAndMutationsDoNotInferChronologyFromBlockTime() public {
        vm.warp(100);
        subject.insert(1, 0);
        subject.insert(2, type(uint64).max);
        _assertEvent(subject.pop(), 1, 0);
        subject.reschedule(2, 1);
        _assertEvent(subject.pop(), 2, 1);
    }

    function testFuzz_fullWidthEventRoundTrips(uint256 facilityId, uint64 first, uint64 second) public {
        subject.insert(facilityId, first);
        assertTrue(subject.contains(facilityId));
        assertEq(subject.count(), 1);
        _assertEvent(subject.get(facilityId), facilityId, first);
        _assertEvent(subject.peek(), facilityId, first);
        assertEq(subject.reschedule(facilityId, second), first);
        _assertEvent(subject.remove(facilityId), facilityId, second);
        assertFalse(subject.contains(facilityId));
        assertEq(subject.count(), 0);
    }

    function testFuzz_equalDeadlineInsertionPermutationIsDeterministic(bytes32 seed, uint64 deadline) public {
        Model memory model = _newModel(seed);
        uint256 offset = uint256(seed) % 16;
        uint256 stride = ((uint256(seed) >> 8) % 16) | 1;
        for (uint256 i; i < 16; ++i) {
            uint256 slot = (offset + i * stride) % 16;
            subject.insert(model.ids[slot], deadline);
        }
        // IDs in the model are ascending; the independently chosen insertion permutation is not.
        for (uint256 i; i < 16; ++i) {
            _assertEvent(subject.pop(), model.ids[i], deadline);
        }
        assertEq(subject.count(), 0);
    }

    function testFuzz_unorderedInsertionsDrainAgainstLinearMinimum(bytes32 seed, uint64[16] memory deadlines) public {
        Model memory model = _newModel(seed);
        for (uint256 i; i < 16; ++i) {
            model.deadlines[i] = deadlines[i];
            model.active[i] = true;
            subject.insert(model.ids[i], deadlines[i]);
        }
        _assertModel(model);
        for (uint256 i; i < 16; ++i) {
            uint256 slot = _minimum(model);
            _assertEvent(subject.pop(), model.ids[slot], model.deadlines[slot]);
            model.active[slot] = false;
            _assertModel(model);
        }
    }

    function testFuzz_mixed32StepTraceMatchesIndependentModel(bytes32 seed) public {
        _trace(seed, 32);
    }

    function testFuzz_mixed64StepTraceMatchesIndependentModel(bytes32 seed) public {
        _trace(seed, 64);
    }

    function testFuzz_arbitraryRemovalPermutationLeavesNoTombstones(bytes32 seed, uint64[16] memory deadlines) public {
        Model memory model = _newModel(seed);
        for (uint256 i; i < 16; ++i) {
            model.deadlines[i] = deadlines[i];
            model.active[i] = true;
            subject.insert(model.ids[i], deadlines[i]);
        }
        uint256 offset = uint256(seed) % 16;
        uint256 stride = ((uint256(seed) >> 8) % 16) | 1;
        for (uint256 i; i < 16; ++i) {
            uint256 slot = (offset + i * stride) % 16;
            _assertEvent(subject.remove(model.ids[slot]), model.ids[slot], model.deadlines[slot]);
            model.active[slot] = false;
            _assertModel(model);
        }
        for (uint256 i; i < 16; ++i) {
            subject.insert(model.ids[i], 0);
        }
        for (uint256 i; i < 16; ++i) {
            _assertEvent(subject.pop(), model.ids[i], 0);
        }
    }

    function testFuzz_repeatedUpwardAndDownwardReplacement(bytes32 seed, uint64[16] memory deadlines) public {
        Model memory model = _newModel(seed);
        for (uint256 i; i < 16; ++i) {
            model.deadlines[i] = deadlines[i];
            model.active[i] = true;
            subject.insert(model.ids[i], deadlines[i]);
        }
        for (uint256 i; i < 16; ++i) {
            assertEq(subject.reschedule(model.ids[i], 0), model.deadlines[i]);
            model.deadlines[i] = 0;
            _assertModel(model);
            assertEq(subject.reschedule(model.ids[i], type(uint64).max), 0);
            model.deadlines[i] = type(uint64).max;
            _assertModel(model);
        }
    }

    /// @dev Uses an unordered 16-facility universe with every input bit above the low nibble
    ///      preserved. IDs are distinct by construction, without assuming hash collision freedom.
    function _newModel(bytes32 seed) private pure returns (Model memory model) {
        model.ids = new uint256[](16);
        model.deadlines = new uint64[](16);
        model.active = new bool[](16);
        uint256 base = uint256(seed) & ~uint256(15);
        for (uint256 i; i < 16; ++i) {
            model.ids[i] = base | i;
        }
    }

    function _trace(bytes32 seed, uint256 steps) private {
        Model memory model = _newModel(seed);
        for (uint256 step; step < steps; ++step) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, step)));
            uint256 slot = (entropy >> 8) % 16;
            uint64 deadline = uint64(entropy >> 16);
            if (step % 8 == 0) deadline = 0;
            if (step % 8 == 1) deadline = type(uint64).max;
            _act(model, slot, deadline, entropy % 6);
            _assertModel(model);
        }
        // Consume every remaining event and every previously removed ID's reverse-map entry.
        while (subject.count() != 0) {
            uint256 slot = _minimum(model);
            _assertEvent(subject.pop(), model.ids[slot], model.deadlines[slot]);
            model.active[slot] = false;
            _assertModel(model);
        }
    }

    function _act(Model memory model, uint256 slot, uint64 deadline, uint256 operation) private {
        uint256 id = model.ids[slot];
        if (operation == 0) {
            if (model.active[slot]) {
                vm.expectRevert(abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_AlreadyScheduled.selector, id));
                subject.insert(id, deadline);
            } else {
                subject.insert(id, deadline);
                model.active[slot] = true;
                model.deadlines[slot] = deadline;
            }
        } else if (operation == 1) {
            if (model.active[slot]) {
                assertEq(subject.reschedule(id, deadline), model.deadlines[slot]);
                model.deadlines[slot] = deadline;
            } else {
                _expectMissing(id);
                subject.reschedule(id, deadline);
            }
        } else if (operation == 2) {
            if (model.active[slot]) {
                _assertEvent(subject.remove(id), id, model.deadlines[slot]);
                model.active[slot] = false;
            } else {
                _expectMissing(id);
                subject.remove(id);
            }
        } else if (operation == 3) {
            uint256 minimum = _minimum(model);
            if (minimum == type(uint256).max) {
                vm.expectRevert(AccrualSchedule.AccrualSchedule_Empty.selector);
                subject.pop();
            } else {
                _assertEvent(subject.pop(), model.ids[minimum], model.deadlines[minimum]);
                model.active[minimum] = false;
            }
        } else if (operation == 4) {
            assertEq(subject.contains(id), model.active[slot]);
            if (model.active[slot]) {
                _assertEvent(subject.get(id), id, model.deadlines[slot]);
            } else {
                _expectMissing(id);
                subject.get(id);
            }
        } else {
            uint256 minimum = _minimum(model);
            if (minimum == type(uint256).max) {
                vm.expectRevert(AccrualSchedule.AccrualSchedule_Empty.selector);
                subject.peek();
            } else {
                _assertEvent(subject.peek(), model.ids[minimum], model.deadlines[minimum]);
            }
        }
    }

    /// @dev Independent linear scan over unsorted model slots. uint256-max is a SLOT sentinel,
    ///      not an identifier sentinel: it cannot collide with any of the 16 valid model indices.
    function _minimum(Model memory model) private pure returns (uint256 minimum) {
        minimum = type(uint256).max;
        for (uint256 i; i < model.ids.length; ++i) {
            if (!model.active[i]) continue;
            if (
                minimum == type(uint256).max || model.deadlines[i] < model.deadlines[minimum]
                    || (model.deadlines[i] == model.deadlines[minimum] && model.ids[i] < model.ids[minimum])
            ) minimum = i;
        }
    }

    /// @dev Checks reverse positions for active AND absent IDs after every operation, as well as
    ///      every stored record, the parent ordering invariant, the count and the independent min.
    function _assertModel(Model memory model) private view {
        (AccrualSchedule.Event[] memory entries, uint256[] memory positions) = subject.inspect(model.ids);
        uint256 expectedCount;
        for (uint256 i; i < model.ids.length; ++i) {
            if (model.active[i]) {
                ++expectedCount;
                assertGt(positions[i], 0, "active model ID lost its position");
                assertLe(positions[i], entries.length, "reverse position is out of range");
                _assertEvent(entries[positions[i] - 1], model.ids[i], model.deadlines[i]);
            } else {
                assertEq(positions[i], 0, "removed or absent ID has a tombstone");
            }
        }
        assertEq(entries.length, expectedCount, "stored cardinality differs from independent model");
        assertEq(subject.count(), expectedCount);
        for (uint256 i = 1; i < entries.length; ++i) {
            AccrualSchedule.Event memory parent = entries[(i - 1) / 2];
            AccrualSchedule.Event memory child = entries[i];
            assertTrue(
                parent.deadline < child.deadline
                    || (parent.deadline == child.deadline && parent.facilityId < child.facilityId),
                "stored parent follows its child"
            );
        }
        uint256 minimum = _minimum(model);
        if (minimum != type(uint256).max) {
            _assertEvent(subject.peek(), model.ids[minimum], model.deadlines[minimum]);
        }
    }

    function _assertEvent(AccrualSchedule.Event memory actual, uint256 id, uint64 deadline) private pure {
        assertEq(actual.facilityId, id, "wrong facility ID");
        assertEq(actual.deadline, deadline, "wrong deadline");
    }

    function _expectMissing(uint256 id) private {
        vm.expectRevert(abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_NotScheduled.selector, id));
    }
}
