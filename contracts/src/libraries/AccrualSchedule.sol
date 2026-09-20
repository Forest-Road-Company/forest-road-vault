// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title AccrualSchedule — one indexed next event per facility
/// @notice A binary min-heap ordered by (deadline, full-width facility ID).
/// @dev Count, membership, event lookup and minimum lookup are O(1). Insert, reschedule, keyed
///      removal and minimum removal are O(log n), without tombstones or a scan over other events.
///      Zero is a valid facility ID and deadline; every uint256 ID and uint64 deadline is accepted.
///      The caller owns authorization, contractual chronology, processing capacity and events.
///      This library reads no clock, makes no external calls and selects no admission policy.
///      Embed Heap in the host's ERC-7201 storage namespace. Do not directly overwrite its fields
///      or delete a nonempty Heap: Solidity does not clear mapping entries when deleting a struct.
///      Existing OpenZeppelin/Solady heaps do not expose indexed keyed removal or swap hooks for
///      a position map; packing this 320-bit ordering key into uint256 would narrow valid inputs.
library AccrualSchedule {
    /// @notice An explicit facility identifier and its next scheduled timestamp.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Event {
        uint256 facilityId;
        uint64 deadline;
    }

    /// @notice Heap entries and the one-based position of each scheduled facility.
    /// @dev Mapping zero means absent; it does not reserve facility ID zero or timestamp zero.
    ///      No separate storage namespace or initialization transaction is required.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Heap {
        Event[] entries;
        mapping(uint256 facilityId => uint256 position) positions;
    }

    /// @notice An empty schedule has no event to inspect or remove.
    error AccrualSchedule_Empty();

    /// @notice A facility already has its one permitted next event.
    /// @param facilityId The duplicate identifier; use reschedule to change its deadline.
    error AccrualSchedule_AlreadyScheduled(uint256 facilityId);

    /// @notice The requested facility has no event in this schedule.
    /// @param facilityId The missing identifier.
    error AccrualSchedule_NotScheduled(uint256 facilityId);

    /// @notice Returns the number of scheduled facilities, in O(1).
    /// @param self The host's schedule.
    /// @return size Number of live entries; no stale or duplicate entries are retained.
    function count(Heap storage self) internal view returns (uint256 size) {
        size = self.entries.length;
    }

    /// @notice Reports whether a facility has a next event, in O(1).
    /// @param self The host's schedule.
    /// @param facilityId The full-width identifier, including zero.
    /// @return scheduled Whether the identifier is present.
    function contains(Heap storage self, uint256 facilityId) internal view returns (bool scheduled) {
        scheduled = self.positions[facilityId] != 0;
    }

    /// @notice Returns the earliest event; equal deadlines prefer the smaller facility ID.
    /// @dev Reverts with AccrualSchedule_Empty if empty. It does not check whether the event is due.
    /// @param self The host's schedule.
    /// @return next The minimum event, copied into memory without mutating storage.
    function peek(Heap storage self) internal view returns (Event memory next) {
        if (self.entries.length == 0) revert AccrualSchedule_Empty();
        next = self.entries[0];
    }

    /// @notice Returns one facility's next event, in O(1).
    /// @dev Reverts with AccrualSchedule_NotScheduled if the identifier is absent.
    /// @param self The host's schedule.
    /// @param facilityId The full-width identifier, including zero.
    /// @return next The identified event, copied into memory.
    function get(Heap storage self, uint256 facilityId) internal view returns (Event memory next) {
        uint256 position = self.positions[facilityId];
        if (position == 0) revert AccrualSchedule_NotScheduled(facilityId);
        next = self.entries[position - 1];
    }

    /// @notice Inserts a facility's first next event, in O(log n).
    /// @dev Duplicate IDs revert. The caller must validate authority, timing and servicing capacity.
    /// @param self The host's schedule.
    /// @param facilityId Full-width identifier; zero is permitted.
    /// @param deadline Explicit timestamp; zero and uint64-max are permitted.
    function insert(Heap storage self, uint256 facilityId, uint64 deadline) internal {
        if (self.positions[facilityId] != 0) revert AccrualSchedule_AlreadyScheduled(facilityId);
        uint256 index = self.entries.length;
        self.entries.push(Event(facilityId, deadline));
        self.positions[facilityId] = index + 1;
        _siftUp(self, index);
    }

    /// @notice Replaces a present facility's deadline in either direction, in O(log n).
    /// @dev A missing ID reverts. An identical deadline is an exact no-op. Moving backward in time
    ///      is mechanically valid here; the host must enforce any contractual chronology policy.
    /// @param self The host's schedule.
    /// @param facilityId The existing full-width identifier.
    /// @param deadline The replacement timestamp, including either uint64 endpoint.
    /// @return previousDeadline The replaced value, allowing the host to emit its transition event.
    function reschedule(Heap storage self, uint256 facilityId, uint64 deadline)
        internal
        returns (uint64 previousDeadline)
    {
        uint256 position = self.positions[facilityId];
        if (position == 0) revert AccrualSchedule_NotScheduled(facilityId);
        uint256 index = position - 1;
        previousDeadline = self.entries[index].deadline;
        if (deadline == previousDeadline) return previousDeadline;
        self.entries[index].deadline = deadline;
        if (deadline < previousDeadline) {
            _siftUp(self, index);
        } else {
            _siftDown(self, index);
        }
    }

    /// @notice Removes a particular facility's event in O(log n), leaving no position tombstone.
    /// @dev A missing identifier reverts. The host decides who may cancel or retire an event.
    /// @param self The host's schedule.
    /// @param facilityId The full-width identifier to remove.
    /// @return removed The old event, allowing the host to emit its transition event.
    function remove(Heap storage self, uint256 facilityId) internal returns (Event memory removed) {
        uint256 position = self.positions[facilityId];
        if (position == 0) revert AccrualSchedule_NotScheduled(facilityId);
        removed = _removeAt(self, position - 1);
    }

    /// @notice Removes and returns the earliest event in O(log n).
    /// @dev Reverts if empty. The host must check due time and process the returned contractual
    ///      event atomically; this data structure neither validates nor performs that processing.
    /// @param self The host's schedule.
    /// @return removed The minimum event, including its full-width facility ID.
    function pop(Heap storage self) internal returns (Event memory removed) {
        if (self.entries.length == 0) revert AccrualSchedule_Empty();
        removed = _removeAt(self, 0);
    }

    /// @dev Removes a known valid index, fills its hole with the last entry, then repairs either
    ///      upward or downward. No external call can observe the temporary relocation.
    function _removeAt(Heap storage self, uint256 index) private returns (Event memory removed) {
        removed = self.entries[index];
        uint256 last = self.entries.length - 1;
        if (index != last) {
            Event memory replacement = self.entries[last];
            self.entries[index] = replacement;
            self.positions[replacement.facilityId] = index + 1;
        }
        self.entries.pop();
        delete self.positions[removed.facilityId];
        if (index < last) {
            if (index != 0 && _less(self.entries[index], self.entries[(index - 1) / 2])) {
                _siftUp(self, index);
            } else {
                _siftDown(self, index);
            }
        }
    }

    /// @dev Moves an entry upward until its parent is earlier or it becomes the root.
    function _siftUp(Heap storage self, uint256 index) private {
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (!_less(self.entries[index], self.entries[parent])) break;
            _swap(self, index, parent);
            index = parent;
        }
    }

    /// @dev Visits only internal nodes. `index < size / 2` guarantees that 2*index+1 exists and
    ///      that both child-index calculations fit uint256, without a narrowing capacity bound.
    function _siftDown(Heap storage self, uint256 index) private {
        uint256 size = self.entries.length;
        while (index < size / 2) {
            uint256 child = 2 * index + 1;
            uint256 right = child + 1;
            if (right < size && _less(self.entries[right], self.entries[child])) child = right;
            if (!_less(self.entries[child], self.entries[index])) break;
            _swap(self, index, child);
            index = child;
        }
    }

    /// @dev Swaps two distinct live entries and updates both reverse positions atomically.
    function _swap(Heap storage self, uint256 first, uint256 second) private {
        Event memory left = self.entries[first];
        Event memory right = self.entries[second];
        self.entries[first] = right;
        self.entries[second] = left;
        self.positions[right.facilityId] = first + 1;
        self.positions[left.facilityId] = second + 1;
    }

    /// @dev Strict lexicographic order with no packed or narrowed facility identifier.
    function _less(Event storage left, Event storage right) private view returns (bool) {
        return left.deadline < right.deadline || (left.deadline == right.deadline && left.facilityId < right.facilityId);
    }
}
