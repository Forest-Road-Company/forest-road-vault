// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICommitmentLedger} from "./interfaces/ICommitmentLedger.sol";
import {IConservativeImpairmentBook} from "./interfaces/IConservativeImpairmentBook.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {Config} from "./libraries/Config.sol";

/// @title CommitmentLedger — live-event principal and conservative residual accounting
/// @notice Per-class totals price declared defaults in constant time. Each curator pool first
///         covers past-due demand and then declared principal of its class; the rest is senior.
/// @dev This BSC instance has no shared backstop. Existing fields remain in place and new state
///      appends at the end of the ledger namespace. The manager is the only writer.
contract CommitmentLedger is ICommitmentLedger {
    bytes32 private constant COMMITMENT_LEDGER_STORAGE_LOCATION =
        0x4284dece5550b2153beac9968b0c4d027165d14c7409a89f67ea4baed9160d00;

    /// @notice The manager address supplied to the constructor was zero.
    error CommitmentLedger_ZeroManager();
    /// @notice Only the deploying `DefaultManager` proxy may mutate the ledger.
    /// @param caller The rejected caller.
    error CommitmentLedger_NotManager(address caller);
    /// @notice `register` was called for an event id that is already live.
    /// @param eventId The duplicate event id.
    error CommitmentLedger_AlreadyRegistered(uint256 eventId);
    /// @notice `updatePrincipal` was called for an event id that is not live.
    /// @param eventId The unknown event id.
    error CommitmentLedger_UnknownEvent(uint256 eventId);
    /// @notice A registration named a class outside `1..Config.NUM_CLASSES`.
    /// @param classId The rejected class id.
    error CommitmentLedger_InvalidClass(uint256 classId);

    /// @dev One live declared default. The Ethereum tree carried two more words here - a
    ///      `remainingCoverage` layer-two claim bound and a `consumed` draw tally. Both are
    ///      identically zero with no backstop, and the W6 storage baseline that argued for
    ///      retaining them is an UPGRADE constraint on Ethereum which does not bind a genesis
    ///      deployment on a fresh chain.
    struct Entry {
        uint256 remainingPrincipal;
    }

    /// @custom:storage-location erc7201:forestroad.storage.CommitmentLedger
    /// @dev GENESIS LAYOUT. This struct is laid out freely because BSC is a fresh deployment with
    ///      virgin storage. From genesis onward it is TAIL-APPEND ONLY, exactly as on Ethereum.
    struct CommitmentLedgerStorage {
        mapping(uint256 eventId => Entry) entries;
        uint256[] eventIds;
        mapping(uint256 eventId => uint256) eventIndexPlusOne;
        uint256 aggregateRemainingPrincipal;
        mapping(uint256 eventId => uint8) eventClass;
        // Per-class remaining principal, appended without moving any existing ledger field.
        mapping(uint256 classId => uint256) remainingPrincipalByClass;
    }

    /// @notice The `DefaultManager` proxy that deployed this ledger and is its only writer.
    address public immutable manager;

    /// @param manager_ The deploying `DefaultManager` proxy.
    constructor(address manager_) {
        if (manager_ == address(0)) revert CommitmentLedger_ZeroManager();
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert CommitmentLedger_NotManager(msg.sender);
        _;
    }

    /// @inheritdoc ICommitmentLedger
    function register(uint256 eventId, uint256 classId, uint256 remainingPrincipal) external onlyManager {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert CommitmentLedger_InvalidClass(classId);
        CommitmentLedgerStorage storage $ = _storage();
        if ($.eventIndexPlusOne[eventId] != 0) revert CommitmentLedger_AlreadyRegistered(eventId);
        $.eventIds.push(eventId);
        $.eventIndexPlusOne[eventId] = $.eventIds.length;
        $.eventClass[eventId] = uint8(classId);
        _setPrincipal($, eventId, remainingPrincipal);
        emit CommitmentRegistered(eventId, classId, remainingPrincipal);
    }

    /// @inheritdoc ICommitmentLedger
    function updatePrincipal(uint256 eventId, uint256 remainingPrincipal) external onlyManager {
        CommitmentLedgerStorage storage $ = _storage();
        if ($.eventIndexPlusOne[eventId] == 0) revert CommitmentLedger_UnknownEvent(eventId);
        _setPrincipal($, eventId, remainingPrincipal);
        emit CommitmentPrincipalUpdated(eventId, remainingPrincipal);
    }

    /// @inheritdoc ICommitmentLedger
    function release(uint256 eventId) external onlyManager {
        CommitmentLedgerStorage storage $ = _storage();
        uint256 indexPlusOne = $.eventIndexPlusOne[eventId];
        if (indexPlusOne == 0) return;
        uint256 released = $.entries[eventId].remainingPrincipal;
        _setPrincipal($, eventId, 0);
        uint256 index = indexPlusOne - 1;
        uint256 length = $.eventIds.length;
        // Preserve the existing eventAt enumeration order when a live row is removed.
        // Residual reads use per-class totals and never walk this array.
        for (uint256 i = index; i + 1 < length; ++i) {
            uint256 shiftedId = $.eventIds[i + 1];
            $.eventIds[i] = shiftedId;
            $.eventIndexPlusOne[shiftedId] = i + 1;
        }
        $.eventIds.pop();
        delete $.eventIndexPlusOne[eventId];
        delete $.eventClass[eventId];
        delete $.entries[eventId];
        emit CommitmentReleased(eventId, released, $.aggregateRemainingPrincipal);
    }

    /// @inheritdoc ICommitmentLedger
    /// @dev Class pools are independent. Their aggregate declared delivery is min(class principal,
    ///      pool remaining after past-due demand), regardless of the order individual rows arrive.
    function conservativeResiduals() external view returns (uint256 residual, uint256 pastDueSenior) {
        CommitmentLedgerStorage storage $ = _storage();
        IConservativeImpairmentBook source = IConservativeImpairmentBook(manager);
        (,,,, address curatorAddress,,,) = source.modules();
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 pastDue = source.pastDuePrincipal(classId);
            uint256 pool = curatorAddress == address(0) ? 0 : ICuratorModule(curatorAddress).poolBalance(classId);
            uint256 curatorForPastDue = _min(pastDue, pool);
            pastDueSenior += pastDue - curatorForPastDue;
            uint256 principal = $.remainingPrincipalByClass[classId];
            residual += principal - _min(principal, pool - curatorForPastDue);
        }
        residual += pastDueSenior;
    }

    /// @inheritdoc ICommitmentLedger
    function remainingPrincipalAggregate() external view returns (uint256) {
        return _storage().aggregateRemainingPrincipal;
    }

    /// @inheritdoc ICommitmentLedger
    function eventCount() external view returns (uint256) {
        return _storage().eventIds.length;
    }

    /// @inheritdoc ICommitmentLedger
    function eventAt(uint256 index) external view returns (uint256 eventId) {
        return _storage().eventIds[index];
    }

    /// @inheritdoc ICommitmentLedger
    function eventInfo(uint256 eventId) external view returns (uint256 classId, uint256 remainingPrincipal) {
        CommitmentLedgerStorage storage $ = _storage();
        return ($.eventClass[eventId], $.entries[eventId].remainingPrincipal);
    }

    /// @notice Total remaining principal for one admitted class, without enumerating event rows.
    /// @param classId Class in the configured range `1..Config.NUM_CLASSES`.
    /// @return The sum of remaining principal in all live rows of this class.
    function remainingPrincipalForClass(uint256 classId) external view returns (uint256) {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert CommitmentLedger_InvalidClass(classId);
        return _storage().remainingPrincipalByClass[classId];
    }

    /// @dev Every principal-changing path uses this writer, including registration and release.
    function _setPrincipal(CommitmentLedgerStorage storage $, uint256 eventId, uint256 next) private {
        Entry storage entry = $.entries[eventId];
        uint256 previous = entry.remainingPrincipal;
        uint256 classId = $.eventClass[eventId];
        $.remainingPrincipalByClass[classId] = $.remainingPrincipalByClass[classId] - previous + next;
        $.aggregateRemainingPrincipal = $.aggregateRemainingPrincipal - previous + next;
        entry.remainingPrincipal = next;
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }

    function _storage() private pure returns (CommitmentLedgerStorage storage $) {
        assembly {
            $.slot := COMMITMENT_LEDGER_STORAGE_LOCATION
        }
    }
}
