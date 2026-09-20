// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";

/// @notice Independent adapter with a deliberately simple known storage layout.
/// @dev Its only storage object is heap: the entries length occupies slot zero and positions
///      occupies slot one. The security tests read these slots directly, not through an inspector.
contract AccrualScheduleSecurityHarness {
    using AccrualSchedule for AccrualSchedule.Heap;

    AccrualSchedule.Heap private heap;

    function insert(uint256 id, uint64 deadline) external {
        heap.insert(id, deadline);
    }

    function reschedule(uint256 id, uint64 deadline) external returns (uint64) {
        return heap.reschedule(id, deadline);
    }

    function remove(uint256 id) external returns (AccrualSchedule.Event memory) {
        return heap.remove(id);
    }

    function pop() external returns (AccrualSchedule.Event memory) {
        return heap.pop();
    }

    function peek() external view returns (AccrualSchedule.Event memory) {
        return heap.peek();
    }

    function get(uint256 id) external view returns (AccrualSchedule.Event memory) {
        return heap.get(id);
    }

    function contains(uint256 id) external view returns (bool) {
        return heap.contains(id);
    }

    function count() external view returns (uint256) {
        return heap.count();
    }
}

/// @notice Independent review using an unordered model and direct array/mapping storage reads.
/// @dev Every mutation is inspected before any later pop could repair a malformed intermediate
///      heap. IDs vary in their highest bits while sharing lower bits, complementing the author's
///      shared-high-prefix trace model. No servicing, accrual or capacity policy is implied.
contract AccrualScheduleSecurityTest is Test {
    struct Model {
        uint256[] ids;
        uint64[] times;
        bool[] live;
    }

    AccrualScheduleSecurityHarness private subject;
    uint256 private constant ABSENT = type(uint256).max - 1;
    uint256 private constant NONE = type(uint256).max;

    function setUp() public {
        subject = new AccrualScheduleSecurityHarness();
    }

    function testFuzz_fullWidthMixedTraceChecksRawHeapAndMapAfterEveryAct(uint256 seed) public {
        Model memory model = _model(seed, 24);
        // Start with a populated tree: an insert/pop-heavy random trace alone tends to remain
        // tiny and scarcely exercises deep keyed removal or both repair directions.
        for (uint256 i; i < model.ids.length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            model.times[i] = _deadline(seed, i);
            model.live[i] = true;
            subject.insert(model.ids[i], model.times[i]);
            _assertState(model);
        }
        for (uint256 step; step < 48; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _act(model, seed % model.ids.length, _deadline(seed, step), (seed >> 128) % 6);
            _assertState(model);
        }
    }

    function test_keyedRemovalCanNeedTwoUpwardSwapsImmediately() public {
        Model memory model = _model(91, 15);
        uint64[15] memory times = [uint64(0), 100, 1, 110, 120, 2, 3, 111, 112, 121, 122, 4, 5, 6, 7];
        for (uint256 i; i < times.length; ++i) {
            model.times[i] = times[i];
            model.live[i] = true;
            subject.insert(model.ids[i], times[i]);
            _assertState(model);
        }
        // The final 7 replaces the leaf 111, below ancestors 110 and 100. Verify immediately;
        // subsequent root removals can otherwise conceal a missing or incomplete upward repair.
        _event(subject.remove(model.ids[7]), model.ids[7], times[7]);
        model.live[7] = false;
        _assertState(model);
    }

    function test_equalDeadlineOrderingUsesHighBitsThroughReplaceRemoveAndReuse() public {
        Model memory model = _model(0, 24);
        for (uint256 i = model.ids.length; i != 0; --i) {
            uint256 slot = i - 1;
            model.times[slot] = type(uint64).max;
            model.live[slot] = true;
            subject.insert(model.ids[slot], model.times[slot]);
            _assertState(model);
        }
        assertEq(subject.reschedule(type(uint256).max, 0), type(uint64).max);
        model.times[1] = 0;
        _assertState(model);
        assertEq(subject.reschedule(type(uint256).max, type(uint64).max), 0);
        model.times[1] = type(uint64).max;
        _assertState(model);
        _event(subject.remove(0), 0, type(uint64).max);
        model.live[0] = false;
        _assertState(model);
        subject.insert(0, type(uint64).max);
        model.live[0] = true;
        _assertState(model);
        while (subject.count() != 0) {
            uint256 slot = _minimum(model);
            _event(subject.pop(), model.ids[slot], model.times[slot]);
            model.live[slot] = false;
            _assertState(model);
        }
    }

    function test_invalidOperationsLeaveExactArrayAndReverseMapFingerprint() public {
        Model memory model = _model(31, 24);
        _assertState(model);
        _rejected(
            model,
            abi.encodeCall(subject.pop, ()),
            abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_Empty.selector)
        );
        _rejected(
            model,
            abi.encodeCall(subject.peek, ()),
            abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_Empty.selector)
        );
        for (uint256 i; i < model.ids.length; ++i) {
            model.times[i] = uint64(i % 3);
            model.live[i] = true;
            subject.insert(model.ids[i], model.times[i]);
        }
        _assertState(model);
        for (uint256 i; i < model.ids.length; ++i) {
            _rejected(
                model,
                abi.encodeCall(subject.insert, (model.ids[i], type(uint64).max)),
                abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_AlreadyScheduled.selector, model.ids[i])
            );
        }
        bytes memory missing = abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_NotScheduled.selector, ABSENT);
        _rejected(model, abi.encodeCall(subject.remove, (ABSENT)), missing);
        _rejected(model, abi.encodeCall(subject.reschedule, (ABSENT, uint64(0))), missing);
        _rejected(model, abi.encodeCall(subject.get, (ABSENT)), missing);
        _assertState(model);
    }

    function _act(Model memory model, uint256 slot, uint64 deadline, uint256 action) private {
        uint256 id = model.ids[slot];
        bytes memory missing = abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_NotScheduled.selector, id);
        if (action == 0) {
            if (model.live[slot]) {
                _rejected(
                    model,
                    abi.encodeCall(subject.insert, (id, deadline)),
                    abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_AlreadyScheduled.selector, id)
                );
            } else {
                subject.insert(id, deadline);
                model.times[slot] = deadline;
                model.live[slot] = true;
            }
        } else if (action == 1) {
            if (!model.live[slot]) {
                _rejected(model, abi.encodeCall(subject.reschedule, (id, deadline)), missing);
            } else {
                assertEq(subject.reschedule(id, deadline), model.times[slot]);
                model.times[slot] = deadline;
            }
        } else if (action == 2) {
            if (!model.live[slot]) {
                _rejected(model, abi.encodeCall(subject.remove, (id)), missing);
            } else {
                _event(subject.remove(id), id, model.times[slot]);
                model.live[slot] = false;
            }
        } else if (action == 3) {
            uint256 minimum = _minimum(model);
            if (minimum == NONE) {
                _rejected(
                    model,
                    abi.encodeCall(subject.pop, ()),
                    abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_Empty.selector)
                );
            } else {
                _event(subject.pop(), model.ids[minimum], model.times[minimum]);
                model.live[minimum] = false;
            }
        } else if (action == 4 && model.live[slot]) {
            bytes32 beforeState = _fingerprint(model);
            assertEq(subject.reschedule(id, model.times[slot]), model.times[slot]);
            assertEq(_fingerprint(model), beforeState, "same-time reschedule changed raw storage");
        } else {
            _rejected(
                model,
                abi.encodeCall(subject.remove, (ABSENT)),
                abi.encodeWithSelector(AccrualSchedule.AccrualSchedule_NotScheduled.selector, ABSENT)
            );
        }
    }

    function _model(uint256 seed, uint256 size) private pure returns (Model memory model) {
        model.ids = new uint256[](size);
        model.times = new uint64[](size);
        model.live = new bool[](size);
        model.ids[0] = 0;
        model.ids[1] = type(uint256).max;
        // Bit 250 is set and bit 249 clear; no generated ID can equal either special ID or
        // ABSENT. Distinct high-five-bit prefixes prove uniqueness without a hash assumption.
        uint256 suffix = (seed & ((uint256(1) << 249) - 1)) | (uint256(1) << 250);
        for (uint256 i = 2; i < size; ++i) {
            model.ids[i] = ((i - 2) << 251) | suffix;
        }
    }

    function _deadline(uint256 seed, uint256 step) private pure returns (uint64) {
        if (step % 4 == 0) return 0;
        if (step % 4 == 1) return type(uint64).max;
        if (step % 4 == 2) return 1;
        return uint64(seed >> 64);
    }

    function _minimum(Model memory model) private pure returns (uint256 best) {
        best = NONE;
        for (uint256 i; i < model.ids.length; ++i) {
            if (!model.live[i]) continue;
            if (
                best == NONE || model.times[i] < model.times[best]
                    || (model.times[i] == model.times[best] && model.ids[i] < model.ids[best])
            ) best = i;
        }
    }

    function _assertState(Model memory model) private view {
        uint256 count = uint256(vm.load(address(subject), bytes32(0)));
        assertEq(subject.count(), count);
        uint256 active;
        for (uint256 i; i < model.ids.length; ++i) {
            uint256 position = _position(model.ids[i]);
            assertEq(subject.contains(model.ids[i]), model.live[i]);
            if (!model.live[i]) {
                assertEq(position, 0, "absent ID retains raw reverse position");
            } else {
                ++active;
                assertGt(position, 0, "active ID has no raw reverse position");
                assertLe(position, count, "raw reverse position exceeds array length");
                (uint256 id, uint64 deadline) = _entry(position - 1);
                assertEq(id, model.ids[i], "raw array and reverse map disagree");
                assertEq(deadline, model.times[i], "raw deadline differs from model");
                _event(subject.get(id), id, deadline);
            }
        }
        assertEq(count, active, "raw array cardinality differs from independent model");
        assertEq(_position(ABSENT), 0);
        for (uint256 i = 1; i < count; ++i) {
            (uint256 parentId, uint64 parentTime) = _entry((i - 1) / 2);
            (uint256 childId, uint64 childTime) = _entry(i);
            assertTrue(
                parentTime < childTime || (parentTime == childTime && parentId < childId),
                "raw heap ordering is invalid before any subsequent operation"
            );
        }
        uint256 minimum = _minimum(model);
        if (minimum != NONE) _event(subject.peek(), model.ids[minimum], model.times[minimum]);
    }

    function _fingerprint(Model memory model) private view returns (bytes32 hash) {
        uint256 count = uint256(vm.load(address(subject), bytes32(0)));
        hash = keccak256(abi.encode(count, _position(ABSENT)));
        uint256 base = uint256(keccak256(abi.encode(uint256(0))));
        for (uint256 i; i <= count; ++i) {
            // Include both complete words, including the deadline slot's padding and the
            // first unused entry, so the fingerprint really represents raw storage.
            bytes32 idWord = vm.load(address(subject), bytes32(base + 2 * i));
            bytes32 deadlineWord = vm.load(address(subject), bytes32(base + 2 * i + 1));
            hash = keccak256(abi.encode(hash, idWord, deadlineWord));
        }
        for (uint256 i; i < model.ids.length; ++i) {
            hash = keccak256(abi.encode(hash, _position(model.ids[i])));
        }
    }

    function _entry(uint256 index) private view returns (uint256 id, uint64 deadline) {
        uint256 base = uint256(keccak256(abi.encode(uint256(0))));
        id = uint256(vm.load(address(subject), bytes32(base + 2 * index)));
        deadline = uint64(uint256(vm.load(address(subject), bytes32(base + 2 * index + 1))));
    }

    function _position(uint256 id) private view returns (uint256) {
        return uint256(vm.load(address(subject), keccak256(abi.encode(id, uint256(1)))));
    }

    function _rejected(Model memory model, bytes memory callData, bytes memory expectedError) private {
        bytes32 beforeState = _fingerprint(model);
        (bool success, bytes memory returned) = address(subject).call(callData);
        assertFalse(success, "invalid operation succeeded");
        assertEq(returned, expectedError, "wrong custom error or encoded identifier");
        assertEq(_fingerprint(model), beforeState, "rejected operation changed raw heap storage");
    }

    function _event(AccrualSchedule.Event memory entry, uint256 id, uint64 deadline) private pure {
        assertEq(entry.facilityId, id);
        assertEq(entry.deadline, deadline);
    }
}
