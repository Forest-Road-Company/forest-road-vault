// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {ContinuousAccrualMigration} from "../../script/ContinuousAccrualMigration.sol";
import {ContinuousAccrualDeployment} from "../../script/ContinuousAccrualDeployment.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract NativeOpeningToolingTest is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;
    using stdStorage for StdStorage;

    function _modules() private view returns (IContinuousAccrual.Modules memory) {
        return IContinuousAccrual.Modules(address(usdfr), address(controller), address(vault), address(waterfall),
            address(bridge), address(registry), address(defaultManager));
    }

    function prepareWithIds(uint256[] memory ids) external {
        vm.startPrank(admin);
        ContinuousAccrualMigration.prepare(address(reserves), _modules(), ids);
        vm.stopPrank();
    }

    function quote(IAccrualMigration.Opening memory opening) external view returns (bytes32) {
        return ContinuousAccrualMigration.openingPayload(address(reserves), opening);
    }

    function _prepare() private {
        uint256[] memory ids = new uint256[](1);
        ids[0] = nativeId;
        this.prepareWithIds(ids);
    }

    function _legacyQuorum(uint256 value) private {
        stdstore.target(address(realOracle)).sig(IAttestationOracle.threshold.selector)
            .with_key(uint256(IAttestationOracle.AttestationKind.AccrualOpening)).checked_write(value);
        assertEq(realOracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), value,
            "legacy threshold fixture was not applied");
    }

    function test_preparationAndEncodedImportCompleteTheRealNativeLifecycle() public {
        _legacyFund(50_000e18);
        vm.warp(nativeStart + 45 days);
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(uint64(block.timestamp));
        nativeReference = n;
        _prepare();
        assertTrue(reserves.accrualMigration().active);
        assertTrue(realOracle.hasRole(Roles.CREDIT_ROLE, address(reserves)));
        IAccrualMigration.Opening memory opening = _referenceOpening();
        assertEq(this.quote(opening), _openingPayload(opening), "tooling changed the independently encoded fact");
        _signOpening(opening);
        IAccrualMigration.Opening[] memory rows = new IAccrualMigration.Opening[](1);
        rows[0] = opening;
        bytes memory data = ContinuousAccrualMigration.importCalldata(rows);
        vm.prank(admin);
        (bool ok,) = address(reserves).call(data);
        assertTrue(ok, "reviewable import calldata did not execute");
        assertEq(reserves.accrualMigration().imported, 1);
        assertEq(reserves.deployedTo(nativeId), n.principal + n.interest);
        _enableOpening();
        ContinuousAccrualDeployment.validate(address(reserves), _modules());
        _nativeAdvance(nativeStart + 365 days);
        _nativePayAll();
    }

    function test_preparationInitializesTheMissingLegacyQuorum() public {
        _legacyFund(50_000e18);
        _legacyQuorum(0);
        _prepare();
        assertEq(realOracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), 2);
        assertTrue(reserves.accrualMigration().active);
    }

    function test_preparationPreservesAHigherConfiguredQuorum() public {
        _legacyFund(50_000e18);
        vm.prank(admin);
        realOracle.setThreshold(IAttestationOracle.AttestationKind.AccrualOpening, 3);
        _prepare();
        assertEq(realOracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), 3);
    }

    function test_failedPreparationRollsBackBindingsRolesAndThreshold() public {
        _legacyFund(50_000e18);
        _legacyQuorum(0);
        vm.expectRevert(ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        this.prepareWithIds(new uint256[](0));
        assertEq(usdfr.accrualReserve(), address(0));
        assertEq(bridge.accrualReserve(), address(0));
        assertEq(defaultManager.accrualReserve(), address(0));
        assertEq(reserves.accrualModules().token, address(0));
        assertFalse(realOracle.hasRole(Roles.CREDIT_ROLE, address(reserves)));
        assertEq(realOracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), 0);
        assertEq(vault.totalAssets(), SENIOR_CAPITAL);
    }

    function test_toolingRequiresAFrozenSessionForItsOpeningPayload() public {
        vm.expectRevert(ContinuousAccrualMigration.AccrualMigrationTool_NotPreparing.selector);
        this.quote(_referenceOpening());
        _legacyFund(50_000e18);
        _prepare();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        bytes32 payload = this.quote(opening);
        opening.approvalRef = keccak256("replacement approval");
        assertNotEq(this.quote(opening), payload, "replacement approval was omitted from the signed data");
    }
}

contract NativeOpeningPikToolingTest is NativeOpeningToolingTest {
    function _pikFacilities() internal pure override returns (bool) { return true; }
}
