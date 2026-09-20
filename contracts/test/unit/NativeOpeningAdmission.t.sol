// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Config} from "../../src/libraries/Config.sol";

contract NativeOpeningAdmissionTest is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function setUp() public override {
        super.setUp();
        _legacyFund(50_000e18);
        _bindOpeningConsumers();
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                reserves.accrualMigration(),
                reserves.deployedTo(1),
                reserves.deployedTo(2),
                registry.totalBookExposure(),
                usdfr.totalSupply(),
                usdfr.balanceOf(address(vault)),
                usdfr.balanceOf(feeRecipient),
                defaultManager.impairmentRevision()
            )
        );
    }

    function _reject(uint8 action, bytes memory body, bytes4 reason) private {
        bytes32 before_ = _state();
        vm.expectPartialRevert(reason);
        _step(action, body);
        assertEq(_state(), before_, "refused migration changed native state");
    }

    /// @dev These cases deliberately correct rejected or obsolete approvals. Revoke the
    ///      pending action explicitly before presenting its separately signed replacement.
    function _signReplacementOpening(IAccrualMigration.Opening memory opening) private {
        (,, bool pending) = realOracle.latestPayload(opening.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
        if (pending) {
            vm.prank(admin);
            realOracle.revoke(opening.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
        }
        _signOpening(opening);
    }

    function _rejectOpening(IAccrualMigration.Opening memory opening, bytes4 reason) private {
        _signReplacementOpening(opening);
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](1);
        batch[0] = opening;
        _reject(1, abi.encode(batch), reason);
        (,, bool satisfied) =
            realOracle.latestPayload(opening.facilityId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(satisfied, "refused opening consumed its signature");
    }

    function test_eventsDescribeTheOpeningSessionAndItsAccounting() public {
        vm.warp(nativeStart + 45 days);
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(uint64(block.timestamp));
        nativeReference = n;
        uint256[] memory ids = new uint256[](1);
        ids[0] = nativeId;
        bytes32 session = keccak256(
            abi.encode(
                block.chainid,
                address(reserves),
                uint256(1),
                uint64(block.timestamp),
                keccak256(abi.encode(ids)),
                reserves.accrualModules(),
                waterfall.protocolFeeBps(),
                feeRecipient
            )
        );
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualMigrationBegun(1, session, uint64(block.timestamp), 1, 50_000e18);
        _beginOne();
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualMigrationCancelled(1, session);
        _step(2, "");
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signReplacementOpening(opening);
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit DefaultAccrualLib.OpeningRiskRecorded(nativeId, n.interest, false, false);
        vm.expectEmit(true, true, false, true, address(reserves));
        emit ReserveMigrationLib.AccrualOpeningImported(
            2, nativeId, 50_000e18, n.principal, n.interest, n.interest, false, false
        );
        _importOne(opening);
        vm.expectEmit(false, false, false, true, address(reserves));
        emit ReserveAccrualLib.AccrualEnabled(uint64(block.timestamp), waterfall.protocolFeeBps(), feeRecipient);
        _enableOpening();
    }

    function test_adminOnlyAndActionEncodingCannotBypassPreparation() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = nativeId;
        bytes32 before_ = _state();
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(this), bytes32(0))
        );
        reserves.prepareContinuousAccrualMigration(abi.encode(uint8(0), abi.encode(ids)));
        assertEq(_state(), before_);
        _reject(3, "", ReserveMigrationLib.AccrualMigration_InvalidAction.selector);
        _reject(
            1, abi.encode(new IAccrualMigration.Opening[](0)), ReserveMigrationLib.AccrualMigration_NotStarted.selector
        );
        _reject(2, "", ReserveMigrationLib.AccrualMigration_NotStarted.selector);
        _beginOne();
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_AlreadyStarted.selector);
        _reject(2, hex"01", ReserveMigrationLib.AccrualMigration_InvalidBatch.selector);
    }

    function test_rosterRequiresAllPositiveFaceExactlyOnceInOrder() public {
        _reject(0, abi.encode(new uint256[](0)), ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        _reject(0, abi.encode(new uint256[](101)), ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        uint256[] memory ids = new uint256[](1);
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        _legacyFund(10_000e18);
        ids[0] = 1;
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        ids[0] = 2;
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_InvalidRoster.selector);
        ids[0] = 1;
        ids[1] = 2;
        _beginOpening(ids);
        assertEq(reserves.accrualMigration().originalFace, 60_000e18);
        assertEq(reserves.accrualMigration().nextFacilityId, 1);
    }

    function test_preparationRequiresReadyOracleAndEveryConsumerBinding() public {
        vm.prank(admin);
        realOracle.revokeRole(Roles.CREDIT_ROLE, address(reserves));
        uint256[] memory ids = new uint256[](1);
        ids[0] = nativeId;
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_OracleNotReady.selector);
        vm.prank(admin);
        realOracle.grantRole(Roles.CREDIT_ROLE, address(reserves));
        vm.mockCall(
            address(realOracle),
            abi.encodeCall(IAttestationOracle.threshold, (IAttestationOracle.AttestationKind.AccrualOpening)),
            abi.encode(uint8(1))
        );
        _reject(0, abi.encode(ids), ReserveMigrationLib.AccrualMigration_OracleNotReady.selector);
        vm.clearMockedCalls();
        vm.mockCall(address(bridge), abi.encodeWithSignature("accrualReserve()"), abi.encode(address(0)));
        _reject(0, abi.encode(ids), ReserveAccrualLib.ReserveAccrual_WrongModules.selector);
        vm.clearMockedCalls();
        _beginOne();
        assertTrue(reserves.accrualMigration().active);
    }

    function test_nativeRecordChangesRefuseImportBeforeConsumption() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signReplacementOpening(opening);
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        f.interestRateBps += 1;
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.facility, (nativeId)), abi.encode(f));
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](1);
        batch[0] = opening;
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_RecordChanged.selector);
        vm.clearMockedCalls();
        _importOne(opening);
        _enableOpening();
        _assertNativeDebt();
    }

    function test_openingFactBindsPayloadAndExactCutoff() public {
        vm.warp(nativeStart + 45 days);
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(uint64(block.timestamp));
        nativeReference = n;
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](1);
        batch[0] = opening;
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_AttestationRequired.selector);
        _attest(
            nativeId,
            IAttestationOracle.AttestationKind.AccrualOpening,
            _openingPayload(opening),
            reserves.accrualMigration().cutoff - 1
        );
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_AttestationRequired.selector);
        // The rejected timestamp still recorded this one-shot oracle fact. A new signed
        // reference authorizes the same balances without pretending the old fact never existed.
        opening.approvalRef = keccak256("corrected-cutoff-approval");
        _signReplacementOpening(opening);
        batch[0] = opening;
        batch[0].interest += _nativeScale();
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_AttestationRequired.selector);
        batch[0].interest -= _nativeScale();
        _importOne(opening);
        _enableOpening();
        _assertNativeDebt();
    }

    function test_cancelRestoresAdmissionAndInvalidatesPreviousSessionSignature() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signReplacementOpening(opening);
        IAccrualMigration.Progress memory old = reserves.accrualMigration();
        _step(2, "");
        assertFalse(reserves.accrualMigration().active);
        assertFalse(reserves.accrualSnapshot().enabled);
        assertEq(reserves.accrualMigration().nextFacilityId, 0);
        _beginOne();
        IAccrualMigration.Progress memory fresh = reserves.accrualMigration();
        assertEq(fresh.nonce, old.nonce + 1, "cancel reused nonce");
        assertNotEq(fresh.sessionKey, old.sessionKey, "cancel reused signature domain");
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](1);
        batch[0] = opening;
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_AttestationRequired.selector);
        _signReplacementOpening(opening);
        _importOne(opening);
        _reject(2, "", ReserveMigrationLib.AccrualMigration_CannotCancelImportedDebt.selector);
        _enableOpening();
        _assertNativeDebt();
    }

    function test_partialBookRefusesNavAndLifecycleUntilEveryRowIsImported() public {
        _legacyFund(10_000e18);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        _beginOpening(ids);
        IAccrualMigration.Opening memory first =
            IAccrualMigration.Opening(1, 50_000e18, 0, 0, nativeStart, 0, bytes32(0));
        _signReplacementOpening(first);
        _importOne(first);
        assertEq(reserves.accrualMigration().imported, 1);
        assertEq(reserves.accrualMigration().nextFacilityId, 2);
        bytes32 before_ = _state();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
        vault.totalAssets();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
        controller.totalUSDfr();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
        reserves.requireAccrualFresh();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
        defaultManager.markPastDue(1);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_MigrationIncomplete.selector, uint32(1), uint32(2))
        );
        reserves.enableContinuousAccrual();
        assertEq(_state(), before_, "partial-book refusal changed state");
        IAccrualMigration.Opening memory second = _referenceOpening();
        _signReplacementOpening(second);
        _importOne(second);
        _enableOpening();
        _assertNativeDebt();
        _assertNativeBacking();
        _reject(2, "", ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector);
    }

    function test_batchFailureRollsBackEveryRowAndAttestationThenCanResume() public {
        _legacyFund(10_000e18);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        _beginOpening(ids);
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](2);
        batch[0] = IAccrualMigration.Opening(1, 50_000e18, 100e18, 0, nativeStart, 0, bytes32(0));
        batch[1] = IAccrualMigration.Opening(2, 10_000e18, 20e18, 0, nativeStart, 0, bytes32(0));
        _signReplacementOpening(batch[0]);
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_AttestationRequired.selector);
        (,, bool satisfied) = realOracle.latestPayload(1, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(satisfied, "rolled-back first row consumed opening");
        assertFalse(reserves.accruedDebt(1).known, "rolled-back first row registered debt");
        _signReplacementOpening(batch[1]);
        _step(1, abi.encode(batch));
        assertEq(reserves.accrualMigration().imported, 2);
        _enableOpening();
        assertEq(reserves.accrualSnapshot().gross, 120e18);
        assertEq(reserves.deployedTo(1), 50_100e18);
        assertEq(reserves.deployedTo(2), 10_020e18);
        _assertNativeBacking();
    }

    function test_emptyOversizedRepeatedAndOutOfOrderBatchesAreRefused() public {
        _beginOne();
        _reject(
            1,
            abi.encode(new IAccrualMigration.Opening[](0)),
            ReserveMigrationLib.AccrualMigration_InvalidBatch.selector
        );
        _reject(
            1,
            abi.encode(new IAccrualMigration.Opening[](9)),
            ReserveMigrationLib.AccrualMigration_InvalidBatch.selector
        );
        _reject(
            1,
            abi.encode(new IAccrualMigration.Opening[](2)),
            ReserveMigrationLib.AccrualMigration_InvalidBatch.selector
        );
        IAccrualMigration.Opening[] memory batch = new IAccrualMigration.Opening[](1);
        batch[0] = _referenceOpening();
        batch[0].facilityId = 2;
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_InvalidBatch.selector);
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signReplacementOpening(opening);
        _importOne(opening);
        batch[0] = opening;
        _reject(1, abi.encode(batch), ReserveMigrationLib.AccrualMigration_InvalidBatch.selector);
        _enableOpening();
    }

    function test_cashOpeningCannotEraseBackingOrInventPrincipalOrCapitalization() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        opening.principal += _nativeScale();
        _rejectOpening(opening, ReserveMigrationLib.AccrualMigration_InvalidFacility.selector);
        opening.principal -= 2 * _nativeScale();
        _rejectOpening(opening, ReserveMigrationLib.AccrualMigration_InvalidFacility.selector);
        opening.principal += _nativeScale();
        opening.nextCapitalization = nativeStart + 90 days;
        _rejectOpening(opening, ReserveMigrationLib.AccrualMigration_InvalidFacility.selector);
        opening.nextCapitalization = 0;
        opening.periodStart = nativeStart + 1;
        _rejectOpening(opening, ReserveMigrationLib.AccrualMigration_InvalidFacility.selector);
        opening.periodStart = nativeStart;
        _signReplacementOpening(opening);
        _importOne(opening);
        _enableOpening();
    }

    function test_revokedOpeningCanBeReauthorizedWithIdenticalBalances() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signReplacementOpening(opening);
        vm.prank(admin);
        realOracle.revoke(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
        vm.expectPartialRevert(ReserveMigrationLib.AccrualMigration_AttestationRequired.selector);
        _importOne(opening);
        assertEq(reserves.accrualMigration().imported, 0);
        opening.approvalRef = keccak256("replacement-opening-approval");
        _signReplacementOpening(opening);
        _importOne(opening);
        _enableOpening();
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0);
    }

    function test_recordedOpeningRemainsUsableAfterTheSignatureSubmissionDeadline() public {
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        _signReplacementOpening(opening);
        vm.warp(block.timestamp + 2 hours);
        (,, bool satisfied) = realOracle.latestPayload(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertTrue(satisfied, "recorded fact incorrectly treated as an unsubmitted signature");
        _importOne(opening);
        _enableOpening();
        _nativeAdvance(uint64(block.timestamp));
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0);
    }
}

contract NativeOpeningPikScheduleTest is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function test_importCannotChangeTheQuorumSignedPikDate() public {
        _legacyFund(50_000e18);
        vm.warp(nativeStart + 135 days);
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(uint64(block.timestamp));
        nativeReference = n;
        _bindOpeningConsumers();
        _beginOne();
        IAccrualMigration.Opening memory opening = _referenceOpening();
        uint64 correct = opening.nextCapitalization;
        _signOpening(opening);
        uint64[3] memory wrong = [uint64(0), correct - 1, correct + 1];
        for (uint256 i; i < wrong.length; ++i) {
            opening.nextCapitalization = wrong[i];
            vm.expectRevert(
                abi.encodeWithSelector(ReserveMigrationLib.AccrualMigration_AttestationRequired.selector, nativeId)
            );
            _importOne(opening);
            assertEq(reserves.accrualMigration().imported, 0);
        }
        opening.nextCapitalization = correct;
        _importOne(opening);
        assertEq(bridge.facility(nativeId).nextPaymentDue, correct, "native PIK cursor not synchronized");
        _enableOpening();
        _nativeAdvance(nativeStart + 150 days);
        _nativeAmendRate(1700);
        _nativePayAll();
    }
}
