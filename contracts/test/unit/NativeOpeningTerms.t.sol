// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";
import {AccrualCeiling} from "../../src/libraries/AccrualCeiling.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";

contract NativeOpeningTermsTest is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function _badRecord(ClaimBridge.Facility memory f, bytes4 reason) private {
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.facility, (nativeId)), abi.encode(f));
        vm.expectPartialRevert(reason);
        _beginOne();
        assertFalse(reserves.accrualMigration().active, "invalid native record froze the book");
        vm.clearMockedCalls();
    }

    function test_onlyLiveSupportedNativeRecordsCanEnterTheFrozenRoster() public {
        _legacyFund(50_000e18);
        _bindOpeningConsumers();
        ClaimBridge.Facility memory original = bridge.facility(nativeId);
        for (uint256 i; i < 11; ++i) {
            ClaimBridge.Facility memory f = abi.decode(abi.encode(original), (ClaimBridge.Facility));
            if (i == 0) {
                f.principal = 0;
            } else if (i == 1) {
                f.paymentInterval = 0;
            } else if (i == 2) {
                f.maturity = 0;
            } else if (i == 3) {
                f.nextPaymentDue = 0;
            } else if (i == 4) {
                f.nextPaymentDue = f.maturity + 1;
            } else if (i == 5) {
                f.state = ClaimBridge.LoanState.Pending;
            } else if (i == 6) {
                f.state = ClaimBridge.LoanState.Resolved;
            } else if (i == 7) {
                f.rateType = ClaimBridge.RateType.Variable;
            } else if (i == 8) {
                f.interestRateBps = 10_001;
            } else if (i == 9) {
                f.dayCountConvention = ClaimBridge.DayCountConvention.Thirty360;
            } else {
                f.pik = true;
                f.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
            }
            _badRecord(
                f,
                i < 7
                    ? ReserveMigrationLib.AccrualMigration_InvalidFacility.selector
                    : ReserveMigrationLib.AccrualMigration_UnsupportedTerms.selector
            );
        }
        _beginOne();
        assertTrue(reserves.accrualMigration().active);
    }

    function test_completeRosterReservesTheAggregatePikMaintenanceBudgetBeforeImport() public {
        _legacyFund(500e18);
        _legacyFund(500e18);
        _bindOpeningConsumers();
        uint256[] memory ids = new uint256[](2);
        for (uint256 id = 1; id <= 2; ++id) {
            ids[id - 1] = id;
            ClaimBridge.Facility memory f = bridge.facility(id);
            f.pik = true;
            f.paymentInterval = 1;
            f.nextPaymentDue = nativeStart + 1;
            vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.facility, (id)), abi.encode(f));
        }
        vm.expectPartialRevert(AccrualLoans.AccrualLoans_WorkCapacity.selector);
        _beginOpening(ids);
        assertFalse(reserves.accrualMigration().active, "unsupported workload stranded migration");
        vm.clearMockedCalls();
        _beginOpening(ids);
        assertEq(reserves.accrualMigration().expected, 2);
    }

    function test_pikOpeningAndFutureInterestMustFitArithmeticCapacity() public {
        _legacyFund(50_000e18);
        _bindOpeningConsumers();
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        f.pik = true;
        IAccrualMigration.Opening memory opening = _referenceOpening();
        opening.nextCapitalization = f.nextPaymentDue;
        uint256 limitOnGrid = AccrualLoans.MAX_BASIS / _nativeScale() * _nativeScale();
        for (uint256 i; i < 4; ++i) {
            opening.principal = i == 0 ? limitOnGrid + _nativeScale() : limitOnGrid;
            opening.interest = i == 1 ? _nativeScale() : 0;
            opening.frozenPikBasis = i == 3 ? limitOnGrid + _nativeScale() : limitOnGrid;
            if (i == 3) opening.principal = 50_000e18;
            vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.facility, (nativeId)), abi.encode(f));
            _beginOne();
            _signOpening(opening);
            bytes4 reason = i < 2
                ? ReserveMigrationLib.AccrualMigration_ExposureCapacity.selector
                : i == 2
                    ? AccrualCeiling.AccrualCeiling_ExposureCapacity.selector
                    : AccrualMath.AccrualMath_BasisTooLarge.selector;
            vm.expectPartialRevert(reason);
            _importOne(opening);
            assertEq(reserves.accrualMigration().imported, 0);
            _step(2, "");
            // Cancelling preparation does not revoke its still-pending signed opening.
            vm.prank(admin);
            realOracle.revoke(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
            vm.clearMockedCalls();
        }
    }

    function test_actual365CashUsesTheSignedDayCountThroughMaturity() public {
        _legacyFund(50_000e18);
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual365,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendmentId = keccak256("opening-actual365-terms");
        _attest(
            nativeId,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, nativeId, a)),
            uint64(block.timestamp)
        );
        vm.prank(originator);
        bridge.amendTerms(nativeId, amendmentId, a);
        AccrualDebtReference.Note memory n = nativeReference;
        n.year = 365 days;
        n.ceiling = 57_000e18;
        n.open(nativeStart);
        nativeReference = n;
        _prepareOne(nativeStart + 45 days + 123);
        _enableOpening();
        _nativeAdvance(nativeStart + 365 days);
        _nativePayAll();
        assertEq(reserves.accrualSnapshot().gross, 7_000e18, "signed Actual365 income");
    }
}

contract NativeOpeningQuantizationTest is NativeOpeningFixture {
    function test_everyOpeningAmountUsesTheNativeAssetGrid() public {
        _legacyFund(50_000e18);
        assertGt(_nativeScale(), 1, "quantization fixture did not select a fractional native grid");
        _bindOpeningConsumers();
        _beginOne();
        for (uint256 i; i < 3; ++i) {
            IAccrualMigration.Opening memory opening = _referenceOpening();
            if (i == 0) ++opening.principal;
            else if (i == 1) ++opening.interest;
            else ++opening.frozenPikBasis;
            _signOpening(opening);
            vm.expectPartialRevert(ReserveMigrationLib.AccrualMigration_InexactOpening.selector);
            _importOne(opening);
            assertEq(reserves.accrualMigration().imported, 0);
            (,, bool satisfied) = realOracle.latestPayload(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
            assertTrue(satisfied, "inexact amount consumed opening fact");
            vm.prank(admin);
            realOracle.revoke(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
        }
        IAccrualMigration.Opening memory valid = _referenceOpening();
        _signOpening(valid);
        _importOne(valid);
        _enableOpening();
        _assertNativeDebt();
    }
}
