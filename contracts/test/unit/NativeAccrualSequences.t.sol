// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualStatefulFixture} from "../helpers/NativeAccrualStatefulFixture.sol";

abstract contract NativeAccrualSequenceChecks is NativeAccrualStatefulFixture {
    function testFuzz_128NativeEventsPreserveIndependentAccounting(uint256 seed) public {
        _sequence(seed, 128);
        _finish();
    }

    function test_4096NativeEventsMeasureAccumulatedDrift() public {
        _sequence(uint256(keccak256("native-continuous-accrual-history")), 4096);
        _finish();
        for (uint256 i; i < nativeActions.length; ++i) {
            emit log_named_uint("completed native action", i);
            emit log_named_uint("operation count", nativeActions[i]);
            assertGt(nativeActions[i], 0, "deterministic history missed an action");
        }
        if (_pikFacilities()) assertGt(nativeCapitalizations, 0, "native PIK dates not reached");
        emit log_named_uint("maximum native book drift, wei", nativeMaximumBookDrift);
        emit log_named_uint("explicit native rounding loss, wei", nativeRoundingLoss);
        emit log_named_uint("senior loss, wei", nativeSeniorLoss);
        emit log_named_uint("native PIK capitalization observations", nativeCapitalizations);
    }

    function test_witnessCompletesEveryNativeAction() public {
        actTime(30 days - 1);
        actReceipt(1);
        actAmend(2000);
        actTime(70 days - 1);
        actPost(0);
        actMaterialize(2);
        for (uint256 i; i < 3; ++i) {
            actTime(120 days - 1);
        }
        actMark(0);
        actCure(0);
        actDeclare(0);
        actLoss(0);
        actCancel(1);
        actFund(1);
        _finish();
        for (uint256 i; i < nativeActions.length; ++i) {
            assertGt(nativeActions[i], 0, "native witness missed an action");
        }
        if (_pikFacilities()) assertGt(nativeCapitalizations, 0, "native witness missed PIK capitalization");
    }

    function _sequence(uint256 seed, uint256 length) private {
        for (uint256 i; i < length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % nativeActions.length;
            uint256 argument = seed >> 32;
            // Each external action owns its temporary log/model memory, as in separate transactions.
            if (action == 0) this.actFund(argument);
            else if (action == 1) this.actTime(argument);
            else if (action == 2) this.actReceipt(argument);
            else if (action == 3) this.actAmend(argument);
            else if (action == 4) this.actMark(argument);
            else if (action == 5) this.actCure(argument);
            else if (action == 6) this.actDeclare(argument);
            else if (action == 7) this.actLoss(argument);
            else if (action == 8) this.actMaterialize(argument);
            else if (action == 9) this.actPost(argument);
            else this.actCancel(argument);
            // This is a history of separate transactions. Renew the test driver's gas
            // allowance between groups, outside every production call. The displayed
            // Forge gas for this long test is not a transaction or production gas budget.
            if (length > 128 && (i + 1) % 128 == 0) vm.resetGasMetering();
        }
    }

    function _finish() private {
        if (_hasDebt()) actReceipt(0);
        actMaterialize(2);
        assertEq(reserves.deployedTo(nativeId), 0, "native sequence left debt");
        assertEq(reserves.accrualSnapshot().unposted, 0, "native sequence left unposted income");
        assertEq(reserves.accrualSnapshot().unissued, 0, "native sequence left unissued income");
        assertNativeStatefulAccounting();
    }
}

contract NativeAccrualCashSequencesTest is NativeAccrualSequenceChecks {}

contract NativeAccrualPikSequencesTest is NativeAccrualSequenceChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
