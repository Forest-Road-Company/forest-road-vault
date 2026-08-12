// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICommitmentLedger} from "./interfaces/ICommitmentLedger.sol";
import {ICascadeBackstop} from "./interfaces/ICascadeBackstop.sol";
import {IConservativeImpairmentBook} from "./interfaces/IConservativeImpairmentBook.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {Config} from "./libraries/Config.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CommitmentLedger — live-event conservative-cascade ledger
/// @notice The shared backstop reserve is one uncapped pool under ADR-0035. This module records
///         declaration-ordered event principal and class data, then walks the forward and reverse
///         cascades while drawing each event only from the reserve still physically live.
/// @dev The manager is the proxy that deploys this module during initialization. Keeping the
///      ledger behind a separate contract leaves the DefaultManager implementation below EIP-170
///      while preserving the manager's existing ERC-7201 layout as an append-only address tail.
contract CommitmentLedger is ICommitmentLedger {
    bytes32 private constant COMMITMENT_LEDGER_STORAGE_LOCATION =
        0x4284dece5550b2153beac9968b0c4d027165d14c7409a89f67ea4baed9160d00;

    error CommitmentLedger_ZeroManager();
    error CommitmentLedger_NotManager(address caller);
    error CommitmentLedger_AlreadyRegistered(uint256 eventId);
    error CommitmentLedger_UnknownEvent(uint256 eventId);
    error CommitmentLedger_InvalidClass(uint256 classId);
    error DefaultManager_BackstopContractViolated(uint256 residual, uint256 covered, uint256 received);
    error CommitmentLedger_DirectCall();

    struct Entry {
        // W6 storage compatibility: these three words are already baselined. Under ADR-0035,
        // `remainingCoverage` is the event's remaining-principal claim bound, not a snapshotted
        // coverage ceiling; the shared reserve is applied separately during the cascade walk.
        uint256 remainingCoverage;
        uint256 remainingPrincipal;
        uint256 consumed;
    }

    /// @inheritdoc ICommitmentLedger
    function register(uint256 eventId, uint256 classId, uint256 remainingPrincipal) external onlyManager {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert CommitmentLedger_InvalidClass(classId);
        CommitmentLedgerStorage storage $ = _storage();
        if ($.eventIndexPlusOne[eventId] != 0) revert CommitmentLedger_AlreadyRegistered(eventId);
        $.eventIds.push(eventId);
        $.eventIndexPlusOne[eventId] = $.eventIds.length;
        Entry storage entry = $.entries[eventId];
        entry.remainingPrincipal = remainingPrincipal;
        $.eventMetadata[eventId] = uint8(classId);
        emit CommitmentRegistered(eventId, classId, remainingPrincipal);
    }

    /// @inheritdoc ICommitmentLedger
    function updatePrincipal(uint256 eventId, uint256 remainingPrincipal) external onlyManager {
        CommitmentLedgerStorage storage $ = _storage();
        if ($.eventIndexPlusOne[eventId] == 0) revert CommitmentLedger_UnknownEvent(eventId);
        Entry storage entry = $.entries[eventId];
        uint256 oldDeliverable = _min(entry.remainingCoverage, entry.remainingPrincipal);
        uint256 newDeliverable = _min(entry.remainingCoverage, remainingPrincipal);
        $.aggregateDeliverable = $.aggregateDeliverable - oldDeliverable + newDeliverable;
        entry.remainingPrincipal = remainingPrincipal;
        emit CommitmentPrincipalUpdated(eventId, remainingPrincipal);
    }

    /// @custom:storage-location erc7201:forestroad.storage.CommitmentLedger
    struct CommitmentLedgerStorage {
        mapping(uint256 eventId => Entry) entries;
        uint256[] eventIds;
        mapping(uint256 eventId => uint256) eventIndexPlusOne;
        uint256 aggregateDeliverable;
        uint256 aggregateRemaining;
        uint256 aggregateConsumed;
        // W7 tail append: class plus drawn flag for declaration-time rows.
        mapping(uint256 eventId => uint8) eventMetadata;
    }

    struct ResidualState {
        uint256 pastDueGross;
        uint256 pastDueResidual;
        uint256 gross;
        uint256 reserve;
        uint256 pastDueLayerTwo;
        address backstop;
        uint256[5] availableCurator;
    }

    address public immutable manager;

    uint8 private constant DRAWN_FLAG = 1 << 7;
    uint8 private constant CLASS_MASK = DRAWN_FLAG - 1;

    constructor(address manager_) {
        if (manager_ == address(0)) revert CommitmentLedger_ZeroManager();
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert CommitmentLedger_NotManager(msg.sender);
        _;
    }

    /// @inheritdoc ICommitmentLedger
    /// @dev Called by DefaultManager with `delegatecall`, so SGrove sees the manager as its
    ///      caller and sends the asset directly to the manager. A direct call cannot impersonate
    ///      that context because the immutable manager differs from `address(this)`.
    function coverDelegate(address backstop, address asset, uint256 eventId, uint256 residual)
        external
        returns (uint256 covered)
    {
        if (address(this) != manager) revert CommitmentLedger_DirectCall();
        if (residual == 0 || backstop == address(0)) return 0;
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        covered = ICascadeBackstop(backstop).coverShortfall(eventId, residual);
        uint256 received = token.balanceOf(address(this)) - before;
        if (covered > residual || received != covered) {
            revert DefaultManager_BackstopContractViolated(residual, covered, received);
        }
    }

    /// @inheritdoc ICommitmentLedger
    function sync(uint256 eventId, uint256 remainingCoverage, uint256 remainingPrincipal, uint256 covered)
        external
        onlyManager
        returns (bool firstDraw)
    {
        return _sync(_storage(), eventId, remainingCoverage, remainingPrincipal, covered);
    }

    function _sync(
        CommitmentLedgerStorage storage $,
        uint256 eventId,
        uint256 remainingCoverage,
        uint256 remainingPrincipal,
        uint256 covered
    ) private returns (bool firstDraw) {
        if (covered == 0) return false;
        if ($.eventIndexPlusOne[eventId] == 0) revert CommitmentLedger_UnknownEvent(eventId);
        Entry storage entry = $.entries[eventId];
        firstDraw = $.eventMetadata[eventId] & DRAWN_FLAG == 0;
        uint256 oldDeliverable = _min(entry.remainingCoverage, entry.remainingPrincipal);
        uint256 newDeliverable = _min(remainingCoverage, remainingPrincipal);
        $.aggregateDeliverable = $.aggregateDeliverable - oldDeliverable + newDeliverable;
        $.aggregateRemaining = $.aggregateRemaining - entry.remainingCoverage + remainingCoverage;
        $.eventMetadata[eventId] |= DRAWN_FLAG;
        entry.consumed += covered;
        $.aggregateConsumed += covered;
        entry.remainingCoverage = remainingCoverage;
        entry.remainingPrincipal = remainingPrincipal;
        emit CommitmentSynced(eventId, remainingCoverage, remainingPrincipal, newDeliverable, $.aggregateDeliverable);
    }

    /// @inheritdoc ICommitmentLedger
    function release(uint256 eventId) external onlyManager {
        CommitmentLedgerStorage storage $ = _storage();
        Entry storage entry = $.entries[eventId];
        uint256 indexPlusOne = $.eventIndexPlusOne[eventId];
        if (indexPlusOne == 0) return;
        uint256 released = _min(entry.remainingCoverage, entry.remainingPrincipal);
        $.aggregateDeliverable -= released;
        $.aggregateRemaining -= entry.remainingCoverage;
        $.aggregateConsumed -= entry.consumed;
        uint256 index = indexPlusOne - 1;
        uint256 length = $.eventIds.length;
        // Declaration order is part of the conservative forward/reverse ladder. Compacting with
        // a swap-and-pop would silently invent a third order after any terminal release, so shift
        // the bounded live set and preserve the relative order of every survivor.
        for (uint256 i = index; i + 1 < length; ++i) {
            uint256 shiftedId = $.eventIds[i + 1];
            $.eventIds[i] = shiftedId;
            $.eventIndexPlusOne[shiftedId] = i + 1;
        }
        $.eventIds.pop();
        delete $.eventIndexPlusOne[eventId];
        delete $.eventMetadata[eventId];
        delete $.entries[eventId];
        emit CommitmentReleased(eventId, released, $.aggregateDeliverable);
    }

    /// @inheritdoc ICommitmentLedger
    function deliverableAggregate() external view returns (uint256) {
        return _storage().aggregateDeliverable;
    }

    /// @inheritdoc ICommitmentLedger
    function conservativeResiduals() external view returns (uint256 residual, uint256 pastDueSenior) {
        CommitmentLedgerStorage storage $ = _storage();
        IConservativeImpairmentBook source = IConservativeImpairmentBook(manager);
        (,,,, address curatorAddress,,,) = source.modules();

        ResidualState memory s;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 classId = i + 1;
            uint256 pastDue = source.pastDuePrincipal(classId);
            uint256 pool = curatorAddress == address(0) ? 0 : ICuratorModule(curatorAddress).poolBalance(classId);
            uint256 curatorForPastDue = _min(pastDue, pool);
            s.pastDueGross += pastDue;
            s.pastDueResidual += pastDue - curatorForPastDue;
            s.availableCurator[i] = pool - curatorForPastDue;
        }

        for (uint256 i = 0; i < $.eventIds.length; ++i) {
            s.gross += $.entries[$.eventIds[i]].remainingPrincipal;
        }
        s.gross += s.pastDueGross;
        if (s.gross == 0) return (0, 0);

        s.backstop = source.backstop();
        if (s.backstop != address(0)) {
            s.reserve = ICascadeBackstop(s.backstop).coverageReserve();
            if (s.pastDueResidual != 0 && s.reserve != 0) {
                s.pastDueLayerTwo = _min(s.pastDueResidual, s.reserve);
                s.reserve -= s.pastDueLayerTwo;
            }
        }

        uint256[5] memory forwardCurator;
        uint256[5] memory reverseCurator;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            forwardCurator[i] = s.availableCurator[i];
            reverseCurator[i] = s.availableCurator[i];
        }
        uint256 forward = _declaredJuniorDelivery($, s, forwardCurator, false);
        uint256 reverse = _declaredJuniorDelivery($, s, reverseCurator, true);
        uint256 declaredJunior = _min(forward, reverse);
        uint256 pastDueJunior = s.pastDueGross - s.pastDueResidual + s.pastDueLayerTwo;
        residual = s.gross - pastDueJunior - declaredJunior;
        pastDueSenior = s.pastDueResidual - s.pastDueLayerTwo;
    }

    function _declaredJuniorDelivery(
        CommitmentLedgerStorage storage $,
        ResidualState memory s,
        uint256[5] memory curatorAvailable,
        bool reverse
    ) private view returns (uint256 delivered) {
        uint256 reserve = s.reserve;
        uint256 length = $.eventIds.length;
        for (uint256 k = 0; k < length; ++k) {
            uint256 eventId = reverse ? $.eventIds[length - 1 - k] : $.eventIds[k];
            Entry storage entry = $.entries[eventId];
            uint256 principal = entry.remainingPrincipal;
            if (principal == 0) continue;

            uint256 classIndex = ($.eventMetadata[eventId] & CLASS_MASK) - 1;
            uint256 curatorTake = _min(principal, curatorAvailable[classIndex]);
            if (curatorTake != 0) {
                curatorAvailable[classIndex] -= curatorTake;
                principal -= curatorTake;
                delivered += curatorTake;
            }
            if (principal == 0 || reserve == 0 || s.backstop == address(0)) continue;

            // ADR-0035: drawn and undrawn events reach the same shared live reserve. No row owns
            // a ceiling and no first-draw snapshot can survive a replenishment.
            uint256 layerTwo = _min(principal, reserve);
            delivered += layerTwo;
            reserve -= layerTwo;
        }
    }

    function remainingAggregate() external view returns (uint256) {
        return _storage().aggregateRemaining;
    }

    function consumed(uint256 eventId) external view returns (uint256) {
        return _storage().entries[eventId].consumed;
    }

    function consumedAggregate() external view returns (uint256) {
        return _storage().aggregateConsumed;
    }

    /// @inheritdoc ICommitmentLedger
    function deliverable(uint256 eventId) external view returns (uint256) {
        Entry memory entry = _storage().entries[eventId];
        return _min(entry.remainingCoverage, entry.remainingPrincipal);
    }

    /// @inheritdoc ICommitmentLedger
    function state(uint256 eventId)
        external
        view
        returns (uint256 remainingCoverage, uint256 remainingPrincipal, uint256 eventDeliverable)
    {
        Entry memory entry = _storage().entries[eventId];
        remainingPrincipal = entry.remainingPrincipal;
        return (entry.remainingCoverage, remainingPrincipal, _min(entry.remainingCoverage, remainingPrincipal));
    }

    function eventCount() external view returns (uint256) {
        return _storage().eventIds.length;
    }

    function eventAt(uint256 index) external view returns (uint256 eventId) {
        return _storage().eventIds[index];
    }

    /// @inheritdoc ICommitmentLedger
    function eventInfo(uint256 eventId)
        external
        view
        returns (uint256 classId, bool drawn, uint256 remainingCoverage, uint256 remainingPrincipal)
    {
        Entry storage entry = _storage().entries[eventId];
        uint8 metadata = _storage().eventMetadata[eventId];
        classId = metadata & CLASS_MASK;
        drawn = metadata & DRAWN_FLAG != 0;
        remainingCoverage = entry.remainingCoverage;
        remainingPrincipal = entry.remainingPrincipal;
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
