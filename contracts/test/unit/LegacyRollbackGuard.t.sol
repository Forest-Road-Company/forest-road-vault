// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";

contract RollbackPhaseProbe is ReserveManager {
    function injectPhase(uint8 kind) external {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (kind == 0) s.migration.active = true;
        else if (kind == 1) s.recordedFace = 1;
        else s.roundingUnabsorbed = 1;
    }
}
contract LegacyRollbackGuardTest is TokenLayerFixture {
    function test_legacyBookPassesReadOnlyGuard() public view { reserves.requireLegacyRollbackSafe(); }
    function testFuzz_importOrRecordedNativeStateRefusesRollback(uint8 kind) public {
        kind = uint8(bound(kind, 0, 2));
        RollbackPhaseProbe impl = new RollbackPhaseProbe();
        vm.prank(admin);
        reserves.upgradeToAndCall(address(impl), abi.encodeCall(impl.injectPhase, (kind)));
        vm.expectRevert(kind == 0
            ? ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector
            : IReserveManager.ReserveManager_LegacyRollbackUnsafe.selector);
        reserves.requireLegacyRollbackSafe();
    }
}
contract ActivatedRollbackGuardTest is NativeAccrualFixture {
    function test_activationRefusesRollbackEvenWithAnEmptyBook() public {
        vm.expectRevert(IReserveManager.ReserveManager_LegacyRollbackUnsafe.selector);
        reserves.requireLegacyRollbackSafe();
    }
}
