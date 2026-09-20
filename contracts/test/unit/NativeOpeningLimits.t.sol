// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {NativeOpeningStorageProbe} from "../helpers/NativeOpeningStorageProbe.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {Config} from "../../src/libraries/Config.sol";

contract NativeOpeningLimitsTest is NativeOpeningFixture {
    NativeOpeningStorageProbe internal probe;

    function setUp() public virtual override {
        super.setUp();
        _legacyFund(50_000e18);
        _bindOpeningConsumers();
        probe = new NativeOpeningStorageProbe();
        (bytes32 slot,,) = _location(7, 0);
        assertEq(
            address(uint160(uint256(vm.load(address(defaultManager), slot)))),
            address(reserves),
            "test default namespace does not match the deployed manager"
        );
    }

    function _location(uint8 field, uint256 id) private returns (bytes32 slot, uint256 mask, uint256 offset) {
        vm.record();
        probe.read(field, id);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(probe));
        assertEq(reads.length, 1, "field probe did not read exactly one slot");
        assertEq(writes.length, 0, "field probe wrote state");
        slot = reads[0];
        bytes32 original = vm.load(address(probe), slot);
        vm.store(address(probe), slot, bytes32(type(uint256).max));
        mask = probe.read(field, id);
        bool found;
        for (uint256 i; i < 32; ++i) {
            vm.store(address(probe), slot, bytes32(uint256(1) << (8 * i)));
            if (probe.read(field, id) != 0) {
                offset = 8 * i;
                found = true;
                break;
            }
        }
        assertTrue(found, "field packing was not discovered");
        vm.store(address(probe), slot, original);
    }

    function _seed(address target, uint8 field, uint256 id, uint256 value)
        private
        returns (bytes32 slot, bytes32 old)
    {
        uint256 mask;
        uint256 offset;
        (slot, mask, offset) = _location(field, id);
        assertLe(value, mask, "test value does not fit its field");
        old = vm.load(target, slot);
        vm.store(target, slot, bytes32((uint256(old) & ~(mask << offset)) | (value << offset)));
        assertEq((uint256(vm.load(target, slot)) >> offset) & mask, value, "test seed was not applied");
    }

    function _mustRejectImport(IAccrualMigration.Opening memory opening, bytes4 reason) private {
        _signOpening(opening);
        vm.expectPartialRevert(reason);
        _importOne(opening);
        assertEq(reserves.accrualMigration().imported, 0, "invalid opening imported debt");
        assertEq(reserves.deployedTo(nativeId), 50_000e18, "invalid opening changed face");
        (,, bool satisfied) = realOracle.latestPayload(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(satisfied, "invalid opening consumed a fact");
    }

    function test_migrationAndActivationRefuseBothAccountingLocks() public {
        for (uint8 field = 1; field <= 2; ++field) {
            (bytes32 slot, bytes32 old) = _seed(address(reserves), field, 0, 1);
            vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
            _beginOne();
            vm.prank(admin);
            vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
            reserves.enableContinuousAccrual();
            vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
            _step(2, "");
            vm.store(address(reserves), slot, old);
        }
        _beginOne();
        assertTrue(reserves.accrualMigration().active);
    }

    function test_nonceCannotWrapOrReuseAnOldSession() public {
        (bytes32 slot, bytes32 old) = _seed(address(reserves), 0, 0, type(uint256).max);
        assertEq(reserves.accrualMigration().nonce, type(uint256).max);
        vm.expectRevert(ReserveMigrationLib.AccrualMigration_NonceOverflow.selector);
        _beginOne();
        assertFalse(reserves.accrualMigration().active);
        vm.store(address(reserves), slot, old);
        _beginOne();
        assertEq(reserves.accrualMigration().nonce, 1);
    }

    function test_feeConfigurationIsValidAtBeginAndUnchangedAtActivation() public {
        vm.mockCall(
            address(waterfall),
            abi.encodeWithSignature("protocolFeeBps()"),
            abi.encode(uint16(Config.MAX_PROTOCOL_FEE_BPS + 1))
        );
        vm.expectPartialRevert(ReserveAccrualLib.ReserveAccrual_InvalidFee.selector);
        _beginOne();
        vm.clearMockedCalls();
        vm.mockCall(address(waterfall), abi.encodeWithSignature("feeRecipient()"), abi.encode(address(0)));
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        _beginOne();
        vm.clearMockedCalls();
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signOpening(opening);
        _importOne(opening);
        vm.mockCall(address(waterfall), abi.encodeWithSignature("protocolFeeBps()"), abi.encode(uint16(999)));
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        reserves.enableContinuousAccrual();
        vm.clearMockedCalls();
        vm.mockCall(address(waterfall), abi.encodeWithSignature("feeRecipient()"), abi.encode(address(0x1234)));
        vm.prank(admin);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        reserves.enableContinuousAccrual();
        vm.clearMockedCalls();
        _enableOpening();
    }

    function test_activationProvesEveryStoredCompletionTotal() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signOpening(opening);
        _importOne(opening);
        uint8[3] memory fields = [uint8(4), uint8(5), uint8(6)];
        for (uint256 i; i < fields.length; ++i) {
            (bytes32 slot, bytes32 old) = _seed(address(reserves), fields[i], 0, 0);
            vm.prank(admin);
            vm.expectPartialRevert(ReserveAccrualLib.ReserveAccrual_MigrationIncomplete.selector);
            reserves.enableContinuousAccrual();
            assertTrue(reserves.accrualMigration().active);
            vm.store(address(reserves), slot, old);
        }
        _enableOpening();
    }

    function test_knownIdentityCannotBeImportedAgain() public {
        _beginOne();
        (bytes32 slot, bytes32 old) = _seed(address(reserves), 12, nativeId, 1);
        vm.expectRevert(ReserveMigrationLib.AccrualMigration_InvalidBatch.selector);
        _importOne(_referenceOpening());
        assertEq(reserves.accrualMigration().imported, 0);
        vm.store(address(reserves), slot, old);
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signOpening(opening);
        _importOne(opening);
        _enableOpening();
    }

    function test_aggregateExposureReservationCannotExceedTheArithmeticDomain() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        vm.mockCall(
            address(registry), abi.encodeWithSignature("totalBookExposure()"), abi.encode(AccrualLoans.MAX_BASIS + 1)
        );
        _mustRejectImport(opening, ReserveMigrationLib.AccrualMigration_ExposureCapacity.selector);
        vm.clearMockedCalls();
        // A fresh approval is unnecessary: the failed transaction never consumed this fact.
        (bytes32 slot, bytes32 old) = _seed(address(reserves), 3, 0, AccrualLoans.MAX_BASIS);
        vm.expectRevert(ReserveMigrationLib.AccrualMigration_ExposureCapacity.selector);
        _importOne(opening);
        vm.store(address(reserves), slot, old);
        vm.mockCall(
            address(registry), abi.encodeWithSignature("totalBookExposure()"), abi.encode(AccrualLoans.MAX_BASIS)
        );
        vm.expectRevert(ReserveMigrationLib.AccrualMigration_ExposureCapacity.selector);
        _importOne(opening);
        vm.clearMockedCalls();
        _importOne(opening);
        _enableOpening();
    }

    function test_openingSumAndFutureCashCapacityCannotOverflow() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        opening.interest = (AccrualLoans.MAX_BASIS / _nativeScale() + 1) * _nativeScale();
        _mustRejectImport(opening, ReserveMigrationLib.AccrualMigration_ExposureCapacity.selector);
        // Replace the rejected approval only after explicitly revoking the pending action.
        vm.prank(admin);
        realOracle.revoke(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
        opening.interest = AccrualLoans.MAX_BASIS / _nativeScale() * _nativeScale() - opening.principal;
        _mustRejectImport(opening, ReserveMigrationLib.AccrualMigration_ExposureCapacity.selector);
        _step(2, "");
        assertFalse(reserves.accrualMigration().active);
    }

    function test_defaultOpeningRefusesImpossibleRiskAndPreservesLegacyDrawnTotals() public {
        _attestDefault(nativeId);
        vm.prank(servicer);
        defaultManager.declareDefault(nativeId, FILM_REF);
        _beginOne();
        vm.prank(address(reserves));
        vm.expectPartialRevert(DefaultAccrualLib.DefaultAccrual_InvalidOpening.selector);
        defaultManager.onAccrualOpening(nativeId, 50_000e18 + 1);
        IAccrualMigration.Opening memory opening = _referenceOpening();
        opening.interest = 100e18;
        _signOpening(opening);
        (bytes32 slot, bytes32 old) = _seed(address(defaultManager), 8, nativeId, 1);
        vm.expectPartialRevert(DefaultAccrualLib.DefaultAccrual_InvalidOpening.selector);
        _importOne(opening);
        vm.store(address(defaultManager), slot, old);
        (slot, old) = _seed(address(defaultManager), 9, nativeId, 1);
        assertEq(defaultManager.defaultedContribution(nativeId), 1);
        vm.expectPartialRevert(DefaultAccrualLib.DefaultAccrual_InvalidOpening.selector);
        _importOne(opening);
        vm.store(address(defaultManager), slot, old);
        _seed(address(defaultManager), 10, nativeId, 7e18);
        _seed(address(defaultManager), 11, Config.CLASS_FILM_TAX_CREDITS, 50_000e18);
        assertEq(defaultManager.coverageConsumedByDefault(nativeId), 7e18);
        _importOne(opening);
        assertEq(
            defaultManager.drawnDefaultPrincipal(Config.CLASS_FILM_TAX_CREDITS),
            50_100e18,
            "import omitted the legacy drawn class contribution"
        );
        _enableOpening();
    }
}
