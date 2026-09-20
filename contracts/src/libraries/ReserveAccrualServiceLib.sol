// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveManager} from "../ReserveManager.sol";

import {ClaimBridge} from "../ClaimBridge.sol";
import {IAccrualBridge} from "../interfaces/IAccrualLifecycle.sol";
import {AccrualLoans} from "./AccrualLoans.sol";
import {ReserveAccrualLib} from "./ReserveAccrualLib.sol";
import {ReserveAccrualStorageLib} from "./ReserveAccrualStorageLib.sol";
import {ReserveStorageLib} from "./ReserveStorageLib.sol";

/// @title ReserveAccrualServiceLib
/// @notice Bounded signed-date servicing without resetting a positive interest curve.
library ReserveAccrualServiceLib {
    using AccrualLoans for AccrualLoans.State;

    error AccrualService_UnknownFacility(uint256 facilityId);
    error AccrualService_InvalidCeiling();

    event AccrualBoundaryProcessed(
        uint256 indexed facilityId, uint64 indexed at, uint256 capitalized, uint64 nextDue, bool stopped
    );
    event AccrualCeilingReserved(uint256 indexed facilityId, uint256 previousCeiling, uint256 nextCeiling);
    /// @notice Commits only dormant signed-date work; positive scheduled curves are left intact.

    function service(ReserveManager.ReserveStorage storage native, uint256 id) public returns (uint256 capitalized) {
        ReserveAccrualLib.requireFresh();
        ReserveAccrualStorageLib.State storage s = _known(id);
        s.busy = true;
        AccrualLoans.LifecycleWork memory work = s.loans.serviceDormant(id, ReserveAccrualStorageLib.now64());
        capitalized = work.capitalized;
        if (work.nextDue != 0 && work.nextDue > ClaimBridge(s.modules.bridge).facility(id).nextPaymentDue) {
            IAccrualBridge(s.modules.bridge).setAccruedPaymentDue(id, work.nextDue);
        }
        if (work.stopped) {
            uint256 face = native.deployed[id] + ReserveAccrualStorageLib.facilityUnposted(id);
            _trimCeiling(s, id, face);
        }
        s.busy = false;
        emit AccrualBoundaryProcessed(id, work.at, capitalized, work.nextDue, work.stopped);
    }

    /// @notice Whether this known facility has positive chronological work in the bounded queue.
    function scheduled(uint256 id) public view returns (bool) {
        ReserveAccrualStorageLib.State storage s = _known(id);
        return s.loans.book.entries[id].scheduled;
    }

    function _known(uint256 id) private view returns (ReserveAccrualStorageLib.State storage s) {
        s = ReserveAccrualStorageLib.state();
        if (!s.enabled || !s.identities[id].known) revert AccrualService_UnknownFacility(id);
    }

    function _trimCeiling(ReserveAccrualStorageLib.State storage s, uint256 id, uint256 face) private {
        uint256 prior = s.identities[id].reservedCeiling;
        if (face > prior) revert AccrualService_InvalidCeiling();
        s.reservedCeilings -= prior - face;
        s.identities[id].reservedCeiling = face;
        emit AccrualCeilingReserved(id, prior, face);
    }
}
