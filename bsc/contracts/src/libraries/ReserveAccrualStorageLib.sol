// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IContinuousAccrual} from "../interfaces/IContinuousAccrual.sol";
import {AccrualBook} from "./AccrualBook.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {AccrualSchedule} from "./AccrualSchedule.sol";

/// @title ReserveAccrualStorageLib
/// @notice The reserve's own continuous-accrual namespace and storage-only backing helpers.
/// @dev No external reads enter these helpers, including on BSC. Every financial clock is
///      capped at the earliest unresolved event; only authenticated host transitions write it.
library ReserveAccrualStorageLib {
    using AccrualSchedule for AccrualSchedule.Heap;

    /// @notice Immutable identities copied from the funded bridge record.
    struct Identity {
        address asset;
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 reservedCeiling;
        bool known;
    }

    /// @notice One exact burn within a reserve-derived contractual rounding correction.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Rounding {
        uint256 facilityId;
        uint64 closureNonce;
        address from;
        uint256 amount;
        bool active;
        bool ready;
    }

    /// @notice The one-time native import session, with a bounded positive-face roster.
    /// @dev LAYOUT-FROZEN: embedded storage; append future fields to State instead.
    struct Migration {
        uint64 cutoff;
        uint32 expected;
        uint32 imported;
        uint16 feeBps;
        bool active;
        uint256 nonce;
        uint256 originalFace;
        uint256 importedOriginalFace;
        bytes32 sessionKey;
        uint256[] facilityIds;
        mapping(uint256 facilityId => bytes32) frozenRecords;
    }

    /// @custom:storage-location erc7201:forestroad.storage.ContinuousAccrual
    struct State {
        AccrualLoans.State loans;
        IContinuousAccrual.Modules modules;
        mapping(uint256 facilityId => Identity) identities;
        address feeRecipient;
        uint256 reservedCeilings;
        uint256 nonce;
        IContinuousAccrual.Delivery delivery;
        IContinuousAccrual.Snapshot deliverySnapshot;
        bool enabled;
        bool busy;
        uint256 recordedFace;
        Rounding rounding;
        uint256 roundingUnabsorbed;
        Migration migration;
    }

    bytes32 private constant ACCRUAL_STORAGE_LOCATION =
        0x2420c1d967401a6739c551e175fd4dfa8e9cd5ee804155e89721bed004930b00;

    /// @notice The chain clock cannot be represented by the admitted schedule domain.
    error ReserveAccrual_TimeOverflow();

    /// @notice Accesses this reserve's independent accounting namespace.
    function state() internal pure returns (State storage $) {
        assembly {
            $.slot := ACCRUAL_STORAGE_LOCATION
        }
    }

    /// @notice Current checked schedule timestamp; no truncating casts are permitted.
    function now64() internal view returns (uint64) {
        if (block.timestamp > type(uint64).max) revert ReserveAccrual_TimeOverflow();
        return uint64(block.timestamp);
    }

    /// @notice Portfolio clock frontier, including an unresolved endpoint at equality.
    function frontier(State storage s) internal view returns (uint64 at) {
        at = now64();
        AccrualSchedule.Heap storage queue = s.loans.book.schedule;
        if (queue.count() != 0) {
            uint64 boundary = queue.peek().deadline;
            if (boundary < at) at = boundary;
        }
    }

    /// @notice Earned receivable not yet transferred to the native deployed-face ledger.
    function unposted() internal view returns (uint256) {
        State storage s = state();
        if (!s.enabled) return 0;
        AccrualBook.Book storage book = s.loans.book;
        uint64 at = frontier(s);
        return book.total.value + book.total.rate * (at - book.total.at) - book.posted;
    }

    /// @notice Facility's effective face increment; resolved historic entries return zero.
    function facilityUnposted(uint256 facilityId) internal view returns (uint256) {
        State storage s = state();
        if (!s.enabled) return 0;
        AccrualBook.Entry storage entry = s.loans.book.entries[facilityId];
        if (!entry.known) return 0;
        uint64 at = frontier(s);
        return entry.clock.value + entry.clock.rate * (at - entry.clock.at) - entry.posted;
    }

    /// @notice Domain-separated, constant-time exposure keys for the immutable facility identities.
    function keys(uint256 classId, bytes32 borrowerId, bytes32 stateId)
        internal
        pure
        returns (bytes32[3] memory result)
    {
        result[0] = keccak256(abi.encode(uint8(1), classId));
        result[1] = keccak256(abi.encode(uint8(2), borrowerId));
        result[2] = keccak256(abi.encode(uint8(3), stateId));
    }
}
