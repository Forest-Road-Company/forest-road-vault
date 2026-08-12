// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {RecoveryTopUpDistributor} from "../../src/RecoveryTopUpDistributor.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SGrove} from "../../src/SGrove.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";

/// @dev Compiler-visible probe for ReserveManager's ERC-7201 storage root. Production contracts
///      intentionally hold this struct at a namespaced assembly slot, which makes their ordinary
///      `forge inspect ... storage-layout` output empty. Declaring the exact production type as a
///      conventional state variable forces solc to emit its member slots and offsets.
contract StorageLayoutAggregateProbe {
    AssessedImpairmentSource.AssessmentStorage internal assessmentStorage;
    AttestationOracle.OracleStorage internal oracleStorage;
    AttestationOracle.Record internal oracleRecord;
    ClaimBridge.BridgeStorage internal bridgeStorage;
    ClaimBridge.Facility internal facility;
    CollateralRegistry.RegistryStorage internal registryStorage;
    CommitmentLedger.CommitmentLedgerStorage internal commitmentLedgerStorage;
    CommitmentLedger.Entry internal commitmentEntry;
    ComplianceRegistry.ComplianceStorage internal complianceStorage;
    CuratorModule.ClassPool internal classPool;
    // AUDIT FIX (SWEEP-4 S4-R1). The closed-round residual-claim snapshot.
    CuratorModule.ClosedRound internal closedRound;
    CuratorModule.CuratorStake internal curatorStake;
    CuratorModule.CuratorStorage internal curatorStorage;
    DefaultManager.DefaultStorage internal defaultStorage;
    // AUDIT FIX (SWEEP-3 S3-F3). The per-facility delinquent payment episode's relief clock.
    DefaultManager.ReliefEpisode internal reliefEpisode;
    MintRedeemController.ControllerStorage internal controllerStorage;
    PointsModule.PointsStorage internal pointsStorage;
    PointsModule.Position internal position;
    PointsModule.RateEpoch internal rateEpoch;
    RecoveryTopUpDistributor.DistributorStorage internal distributorStorage;
    RecoveryTopUpDistributor.Round internal round;
    RedemptionQueue.QueueStorage internal queueStorage;
    RedemptionQueue.Request internal request;
    ReserveManager.ReserveStorage internal reserveStorage;
    SGrove.SGroveStorage internal sGroveStorage;
    SGrove.Unbond internal unbond;
    USDfr.USDfrStorage internal usdfrStorage;
    WaterfallEngine.WaterfallStorage internal waterfallStorage;
    ICollateralRegistry.ClassParams internal classParams;
    SUSDfr.SUSDfrStorage internal sUsdfrStorage;
}
