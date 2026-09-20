// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";

abstract contract NativeOpeningPriorReceiptChecks is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function testFuzz_paymentBeforeMigrationPreservesUnpaidInterestAndItsOriginalBasis(uint64 seed) public {
        _legacyFund(50_000e18);
        uint256 principalPaid = (uint256(seed) % 30_000 + 1) * 1e18;
        uint256 legacyReceivedIncome = _payBeforeOpening(principalPaid, nativeStart + 45 days, bytes32(uint256(1)));
        if (seed % 2 == 0) {
            uint256 second = nativeReference.principal / 3 / _nativeScale() * _nativeScale();
            legacyReceivedIncome += _payBeforeOpening(second, nativeStart + 60 days, bytes32(uint256(2)));
            principalPaid += second;
        }
        assertEq(
            reserves.deployedTo(nativeId), nativeReference.principal, "legacy receipt did not reduce recorded face"
        );
        _prepareOne(nativeStart + 75 days + 137);
        assertEq(nativeReference.frozenBasis, 50_000e18, "reference lost the original frozen basis");
        _enableOpening();
        _assertNativeDebt();
        _nativeAdvance(nativeStart + 90 days);
        if (_pikFacilities()) {
            assertEq(nativeReference.principal, 51_750e18 - principalPaid, "partial payment changed PIK coupon basis");
        }
        _nativeAdvance(nativeStart + 365 days);
        _nativePayAll();
        assertEq(
            reserves.accrualSnapshot().gross,
            nativeReference.earned - legacyReceivedIncome,
            "migration duplicated received income or discarded unpaid income"
        );
        assertEq(registry.totalBookExposure(), 0);
    }

    function _payBeforeOpening(uint256 principal, uint64 at, bytes32 paymentId) private returns (uint256 income) {
        vm.warp(at);
        AccrualDebtReference.Note memory n = nativeReference;
        n.advance(at);
        income = n.pik ? 0 : n.interest;
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: nativeId,
            paymentId: paymentId,
            payer: borrower,
            interest: income,
            principal: principal,
            nextPaymentDue: f.nextPaymentDue + f.paymentInterval
        });
        _submitNativeReceipt(payment, (principal + income) / _nativeScale());
        vm.prank(servicer);
        waterfall.distribute(payment);
        n.pay(principal, income, at);
        nativeReference = n;
    }
}

contract NativeOpeningPriorCashReceiptsTest is NativeOpeningPriorReceiptChecks {}

contract NativeOpeningPriorPikReceiptsTest is NativeOpeningPriorReceiptChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
