// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {ReserveIncidentLib} from "../../src/libraries/ReserveIncidentLib.sol";

/// @notice Symbolic checks execute the actual linked incident helper on a fresh namespace.
contract ReserveIncidentSymbolic is Test {
    ReserveManager.ReserveStorage private native;

    function check_armPreservesIdentityAndEvidence(uint256 previous, bytes32 evidence) public {
        vm.assume(previous < (uint256(1) << 255) - 1);
        native.nextReserveLossArmId = previous;
        native.guardianReserveLossArmsEnabled = true;
        (uint256 armId, uint256 incidentId) = ReserveIncidentLib.arm(native, evidence);
        assert(armId == previous + 1);
        assert(incidentId == type(uint256).max - armId);
        assert(native.nextReserveLossArmId == armId);
        assert(native.activeReserveLossArmId == armId);
        assert(native.activeReserveLossArmEvidenceHash == evidence);
        assert(native.guardianReserveLossArmsEnabled);
    }

    function check_legacyClosePreservesUsedIdentity(uint256 nonce, bytes32 evidence) public {
        vm.assume(nonce < (uint256(1) << 255));
        uint256 incidentId = ReserveIncidentLib.openIncident(native, nonce, evidence);
        assert(incidentId == type(uint256).max - nonce);
        assert(native.reserveLossIncidentUsed[incidentId]);
        assert(native.activeReserveLossIncidentId == incidentId);
        assert(native.activeReserveLossEvidenceHash == evidence);
        ReserveIncidentLib.closeIncident(native, incidentId);
        assert(native.activeReserveLossIncidentId == 0);
        assert(native.activeReserveLossEvidenceHash == bytes32(0));
        assert(native.reserveLossIncidentUsed[incidentId]);
    }
}
