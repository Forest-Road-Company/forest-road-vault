// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ContinuousAccrualDeployment} from "./ContinuousAccrualDeployment.sol";
import {IContinuousAccrual} from "../src/interfaces/IContinuousAccrual.sol";
import {IAccrualMigration} from "../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {AttestationOracle} from "../src/AttestationOracle.sol";
import {ClaimBridge} from "../src/ClaimBridge.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Local preparation and calldata helpers for human-operated native opening migrations.
/// @dev No broadcast entrypoint or signing key is provided. Rehearse the complete roster and
///      all proposed openings before importing its first batch; only an unimported session
///      can be cancelled. Economic balances and coupon epochs come from the note's attesters.
library ContinuousAccrualMigration {
    error AccrualMigrationTool_NotPreparing();

    /// @notice Bind every consumer, establish the opening quorum floor and freeze the complete roster.
    /// @dev The caller must administer all consumers and the oracle. Existing higher quorums stay
    ///      unchanged. One EVM invocation reverts as a unit, including bindings and role grants.
    ///      An operator-owned script that sends separate transactions must preserve this boundary
    ///      in its reviewed executor if it requires atomic preparation.
    function prepare(address reserve, IContinuousAccrual.Modules memory m, uint256[] memory ids) internal {
        ContinuousAccrualDeployment.bind(reserve, m);
        (, address oracleAddress) = ClaimBridge(m.bridge).modules();
        AttestationOracle oracle = AttestationOracle(oracleAddress);
        if (oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening) < 2) {
            oracle.setThreshold(IAttestationOracle.AttestationKind.AccrualOpening, 2);
        }
        oracle.grantRole(Roles.CREDIT_ROLE, reserve);
        IAccrualMigration(reserve).prepareContinuousAccrualMigration(abi.encode(uint8(0), abi.encode(ids)));
    }

    /// @notice Reproduce the exact payload that the opening quorum must authenticate at the cutoff.
    /// @dev Quote unimported rows after preparation, against the frozen native record. The oracle's
    ///      asOf must equal progress.cutoff; approvalRef permits a replacement of a revoked fact.
    function openingPayload(address reserve, IAccrualMigration.Opening memory opening)
        internal view returns (bytes32)
    {
        IAccrualMigration.Progress memory progress = IAccrualMigration(reserve).accrualMigration();
        if (!progress.active) revert AccrualMigrationTool_NotPreparing();
        IContinuousAccrual.Modules memory m = IContinuousAccrual(reserve).accrualModules();
        ClaimBridge.Facility memory f = ClaimBridge(m.bridge).facility(opening.facilityId);
        bytes32 record = keccak256(abi.encode(
            progress.sessionKey, opening.facilityId, ReserveManager(reserve).usdc(),
            ReserveManager(reserve).deployedTo(opening.facilityId), keccak256(abi.encode(f))
        ));
        return keccak256(abi.encode(
            keccak256("AccrualOpening(bytes32 frozenRecord,bytes32 opening)"),
            record, keccak256(abi.encode(opening))
        ));
    }

    /// @notice Encode one import transaction for review; the reserve enforces its eight-row limit.
    /// @dev After all imports, activate with enableContinuousAccrual(), run bounded keeper
    ///      checkpoints until fresh, then use ContinuousAccrualDeployment.validate().
    function importCalldata(IAccrualMigration.Opening[] memory openings) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccrualMigration.prepareContinuousAccrualMigration,
            (abi.encode(uint8(1), abi.encode(openings))));
    }
}
