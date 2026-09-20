// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";

/// @dev Unrestricted local adapter, not production authorization or a native settlement host.
contract AccrualLoansHarness {
    using AccrualLoans for AccrualLoans.State;
    using AccrualBook for AccrualBook.Book;

    AccrualLoans.State private state;

    function initialize(uint64 at, uint16 fee) external {
        state.initialize(at, fee);
    }

    function fund(uint256 id, AccrualLoans.Funding memory terms) external {
        state.fund(id, terms);
    }

    function checkpoint(uint64 at, uint256 maximum)
        external
        returns (AccrualLoans.LifecycleWork[] memory, uint256, bool)
    {
        return state.checkpoint(at, maximum);
    }

    function repay(uint256 id, uint256 principal, uint256 interest, uint64 at)
        external
        returns (AccrualLoans.LifecycleWork memory)
    {
        return state.repay(id, principal, interest, at);
    }

    function amend(uint256 id, AccrualLoans.Amendment memory terms, uint64 at)
        external
        returns (AccrualLoans.LifecycleWork memory)
    {
        return state.amend(id, terms, at);
    }

    function stop(uint256 id, uint64 at) external returns (AccrualLoans.LifecycleWork memory) {
        return state.stop(id, at);
    }

    function serviceDormant(uint256 id, uint64 at) external returns (AccrualLoans.LifecycleWork memory) {
        return state.serviceDormant(id, at);
    }

    function clockAt() external view returns (uint64) {
        return state.book.total.at;
    }

    function post(uint256 id, uint64 at) external returns (uint256) {
        return state.post(id, at);
    }

    function retire(uint256 id, uint64 at) external {
        state.retire(id, at);
    }

    function loan(uint256 id) external view returns (AccrualLoans.Loan memory) {
        return state.loans[id];
    }

    function face(uint256 id, uint64 at) external view returns (uint256, uint256, uint64) {
        return state.loanFace(id, at);
    }

    function snapshot(uint64 at) external view returns (AccrualBook.Snapshot memory) {
        return state.book.snapshot(at);
    }

    function annualWork() external view returns (uint256) {
        return state.annualWork;
    }

    function count() external view returns (uint256) {
        return AccrualSchedule.count(state.book.schedule);
    }

    function registered() external view returns (uint256) {
        return state.book.registered;
    }

    function next() external view returns (AccrualSchedule.Event memory) {
        return AccrualSchedule.peek(state.book.schedule);
    }

    function markPastDue(uint256 id, bool marked, uint64 at) external {
        state.book.setPastDue(id, marked, at);
    }

    function groupUnposted(bytes32 key, uint64 at) external view returns (uint256) {
        return state.book.groupUnposted(key, at);
    }

    function pastDue(bytes32 key, uint64 at) external view returns (uint256) {
        return state.book.pastDueInterest(key, at);
    }

    function issuance(uint8 legs, uint64 at) external returns (uint256, uint256) {
        return state.book.takeIssuance(legs, at);
    }

    /// @dev Deliberate local storage faults exercise defensive, normally unreachable proof gates.
    function corruptClosure(uint256 id, uint64 nonce, uint256 bookBase, uint256 cumulativeStart) external {
        state.loans[id].closureNonce = nonce;
        state.loans[id].segmentBookBase = bookBase;
        state.loans[id].segmentCumulativeStart = cumulativeStart;
    }
}

contract AccrualLoansTest is Test {
    uint64 private constant T = 1_900_000_000;
    uint64 private constant Q = 90 days;
    uint256 private constant P = 1_000_000e18;
    uint256 private constant YEAR = 365 days;
    AccrualLoansHarness private h;

    function setUp() public {
        h = _harness();
    }

    function test_fundingStartsAtFundingAndRetainsFirstSignedDue() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.fundedAt = T + 80 days;
        h.fund(1, f);
        AccrualLoans.Loan memory loan = h.loan(1);
        assertEq(loan.terms.periodStart, f.fundedAt);
        assertEq(loan.nextCapitalization, T + Q);
        assertEq(h.next().deadline, T + Q);
        (AccrualLoans.LifecycleWork[] memory work, uint256 n, bool fresh) = h.checkpoint(T + Q, 32);
        assertEq(n, 1);
        assertTrue(fresh);
        uint256 expected = P * 1400 * 10 days / (10_000 * 360 days) / 1e12 * 1e12;
        assertEq(work[0].capitalized, expected);
        assertEq(h.loan(1).principal, P + expected);
        assertEq(h.loan(1).nextCapitalization, T + 2 * Q);
    }

    function test_cashContinuouslyEarnsWithoutAdvancingItsDueOrCompounding() public {
        h.fund(1, _funding(false));
        assertEq(h.next().deadline, T + 4 * Q);
        (uint256 principal, uint256 interest,) = h.face(1, T + 2 * Q);
        assertEq(principal, P);
        assertEq(interest, 70_000e18);
        assertEq(h.loan(1).nextCapitalization, T + Q);
        (AccrualLoans.LifecycleWork[] memory work, uint256 n, bool fresh) = h.checkpoint(T + 4 * Q, 32);
        assertEq(n, 1);
        assertTrue(fresh);
        assertEq(work[0].capitalized, 0);
        assertEq(work[0].posting, 0);
        assertEq(h.loan(1).principal, P);
        assertEq(h.loan(1).unpaidInterest, 140_000e18);
        assertEq(h.loan(1).nextCapitalization, T + Q);
    }

    function test_hundredQuarterlyLoansCommitFourBoundedBatchesWithoutPosting() public {
        for (uint256 id = 1; id <= 100; ++id) {
            h.fund(id, _funding(true));
        }
        assertEq(h.annualWork(), 900); // ceil(365/90)=5, plus four bounded event allowances.
        uint256 processed;
        for (uint256 batch; batch < 4; ++batch) {
            (AccrualLoans.LifecycleWork[] memory work, uint256 n, bool fresh) = h.checkpoint(T + Q, 32);
            assertEq(n, batch == 3 ? 4 : 32);
            assertEq(fresh, batch == 3);
            for (uint256 i; i < n; ++i) {
                assertEq(work[i].posting, 0);
                assertEq(work[i].capitalized, 35_000e18);
            }
            processed += n;
            AccrualBook.Snapshot memory s = h.snapshot(T + Q);
            assertEq(s.unposted, s.gross);
        }
        assertEq(processed, 100);
        assertEq(h.snapshot(T + Q).gross, 3_500_000e18);
    }

    function test_oneSecondPiKCanBeAdmittedButTwoCannotExceedCapacity() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.paymentInterval = 1;
        f.nextPaymentDue = T + 1;
        h.fund(1, f);
        assertEq(h.annualWork(), YEAR + 4);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_WorkCapacity.selector, 2 * (YEAR + 4)));
        h.fund(2, f);
        assertEq(h.registered(), 1);
        assertFalse(h.loan(2).configured);
        assertEq(h.count(), 1);
        (, uint256 n, bool fresh) = h.checkpoint(T + 100, 32);
        assertEq(n, 32);
        assertFalse(fresh);
        (, n, fresh) = h.checkpoint(T + 100, 32);
        assertEq(n, 32);
        assertFalse(fresh);
        (, n, fresh) = h.checkpoint(T + 100, 32);
        assertEq(n, 32);
        assertFalse(fresh);
        (, n, fresh) = h.checkpoint(T + 100, 32);
        assertEq(n, 4);
        assertTrue(fresh);
    }

    function test_zeroRateAndZeroWholeCouponDoNotCreateHotQueues() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.rateBps = 0;
        f.paymentInterval = 1;
        f.nextPaymentDue = T + 1;
        h.fund(1, f);
        assertEq(h.count(), 0);
        assertEq(h.annualWork(), 0);
        (, uint256 n, bool fresh) = h.checkpoint(T + Q, 32);
        assertEq(n, 0);
        assertTrue(fresh);
        f.principal = 1;
        f.balanceCeiling = 3;
        f.scale = 1;
        f.rateBps = 1;
        f.fundedAt = T + Q;
        f.nextPaymentDue = f.fundedAt + 1;
        h.fund(2, f);
        assertEq(h.count(), 0);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.rateBps = 10_000;
        a.nextPaymentDue = T + 2 * Q;
        a.paymentInterval = Q;
        a.balanceCeiling = 3 * P;
        h.amend(1, a, T + Q);
        assertEq(h.loan(1).frozenPikBasis, P);
        assertEq(h.count(), 1);
    }

    function test_partialPikPaymentKeepsFrozenBasisAndUnchangedCurve() public {
        h.fund(1, _funding(true));
        AccrualLoans.LifecycleWork memory work = h.repay(1, 900_000e18, 0, T + Q / 2);
        assertEq(work.principalReduction, 900_000e18);
        assertEq(work.interestReduction, 0);
        assertEq(h.loan(1).principal, 100_000e18);
        assertEq(h.loan(1).frozenPikBasis, P);
        assertEq(h.loan(1).terms.periodStart, T);
        h.checkpoint(T + Q, 32);
        assertEq(h.loan(1).principal, 135_000e18);
        assertEq(h.loan(1).frozenPikBasis, 135_000e18);
        assertEq(h.snapshot(T + Q).gross, 35_000e18);
    }

    function test_cashPrincipalReceiptRebasesOnlyProspectively() public {
        h.fund(1, _funding(false));
        h.repay(1, 500_000e18, 0, T + 180 days);
        assertEq(h.loan(1).principal, 500_000e18);
        assertEq(h.loan(1).unpaidInterest, 70_000e18);
        assertEq(h.loan(1).terms.basis, 500_000e18);
        assertEq(h.loan(1).terms.periodStart, T + 180 days);
        assertEq(h.loan(1).nextCapitalization, T + Q);
        h.checkpoint(T + 360 days, 32);
        assertEq(h.loan(1).unpaidInterest, 105_000e18);
    }

    function test_cashInterestReceiptDoesNotReMintOrChangePrincipalBasis() public {
        h.fund(1, _funding(false));
        AccrualLoans.LifecycleWork memory work = h.repay(1, 0, 35_000e18, T + Q);
        assertEq(work.principalReduction, 0);
        assertEq(work.interestReduction, 35_000e18);
        assertEq(work.posting, 35_000e18);
        assertEq(h.loan(1).principal, P);
        assertEq(h.loan(1).unpaidInterest, 0);
        assertEq(h.loan(1).terms.periodStart, T);
        // Lifecycle reconciliation recognizes only the outstanding interpolation remainder.
        // Receipt does not add another coupon to the existing accrued income.
        assertEq(h.snapshot(T + Q).gross, 35_000e18);
        assertEq(h.snapshot(T + Q).unissued, 35_000e18);
    }

    function test_completePikPayoffIncludesCurrentUncapitalizedInterest() public {
        h.fund(1, _funding(true));
        AccrualLoans.LifecycleWork memory work = h.repay(1, P + 17_500e18, 0, T + Q / 2);
        assertEq(work.principalReduction, P);
        assertEq(work.interestReduction, 17_500e18);
        assertTrue(work.repaid);
        assertTrue(work.stopped);
        assertEq(h.count(), 0);
        assertEq(h.annualWork(), 0);
        h.retire(1, T + Q / 2);
        assertEq(h.registered(), 0);
        AccrualLoans.Funding memory reused = _funding(true);
        reused.fundedAt = T + Q / 2;
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_KnownFacility.selector, 1));
        h.fund(1, reused);
    }

    function test_cashPayoffCannotEraseUnpaidCashInterest() public {
        h.fund(1, _funding(false));
        AccrualLoans.LifecycleWork memory work = h.repay(1, P, 0, T + Q);
        assertFalse(work.repaid);
        assertEq(h.loan(1).principal, 0);
        assertEq(h.loan(1).unpaidInterest, 35_000e18);
        assertEq(h.loan(1).terms.basis, 0);
        assertEq(h.count(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_Unsettled.selector, 1));
        h.retire(1, T + Q);
        work = h.repay(1, 0, 35_000e18, T + Q);
        assertTrue(work.repaid);
    }

    function test_provedPositiveCorrectionCanEqualScaleAndCannotReplay() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = uint256(360 days) * 2 / 3;
        f.balanceCeiling = 3 * f.principal;
        f.scale = 1;
        f.rateBps = 10_000;
        f.nextPaymentDue = T + 4;
        f.paymentInterval = 4;
        f.maturity = T + 8;
        h.fund(1, f);
        h.repay(1, 1, 0, T + 1);
        AccrualLoans.LifecycleWork memory work = h.stop(1, T + 2);
        assertEq(work.positiveCorrection, 1);
        assertEq(work.roundingLoss, 0);
        assertEq(work.posting, 1);
        assertEq(h.snapshot(T + 2).gross, 1);
        assertEq(h.loan(1).unpaidInterest, 1);
        AccrualLoans.LifecycleWork memory again = h.stop(1, T + 2);
        assertEq(again.closureNonce, work.closureNonce + 1);
        assertEq(again.positiveCorrection, 0);
        assertEq(again.roundingLoss, 0);
        assertEq(again.posting, 0);
    }

    function test_negativeRoundingLossIsReturnedWithoutErasingGrossOrFees() public {
        AccrualLoans.Funding memory f = _funding(false);
        f.principal = uint256(360 days) * 10;
        f.balanceCeiling = 3 * f.principal;
        f.scale = 100;
        f.rateBps = 10_000;
        f.nextPaymentDue = T + 10;
        f.paymentInterval = 10;
        f.maturity = T + 10;
        h.fund(1, f);
        AccrualLoans.LifecycleWork memory work = h.repay(1, 100, 0, T + 5);
        assertEq(work.roundingLoss, 50);
        assertEq(work.positiveCorrection, 0);
        assertEq(work.posting, 50);
        assertEq(h.snapshot(T + 5).gross, 50);
        assertEq(h.snapshot(T + 5).fee, 5);
        assertEq(h.loan(1).unpaidInterest, 0);
        assertEq(f.principal + work.posting - work.roundingLoss - work.principalReduction, h.loan(1).principal);
    }

    function test_capPauseRetainsWorkAndRepaymentRestartsWithoutBackfill() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = uint256(360 days) * 1e18;
        f.balanceCeiling = f.principal + 10 days * 1e18;
        f.rateBps = 10_000;
        h.fund(1, f);
        (, uint256 n, bool fresh) = h.checkpoint(T + 20 days, 32);
        assertEq(n, 2);
        assertTrue(fresh);
        assertEq(h.count(), 0);
        assertEq(h.loan(1).unpaidInterest, 10 days * 1e18);
        uint256 reserved = h.annualWork();
        AccrualLoans.LifecycleWork memory work = h.repay(1, 5 days * 1e18, 0, T + 20 days);
        assertEq(work.capitalized, 0);
        assertEq(h.loan(1).terms.periodStart, T + 20 days);
        assertEq(h.loan(1).frozenPikBasis, f.principal);
        assertEq(h.snapshot(T + 20 days).gross, 10 days * 1e18);
        assertEq(h.annualWork(), reserved);
        h.checkpoint(T + 25 days, 32);
        assertEq(h.loan(1).unpaidInterest, 15 days * 1e18);
        assertEq(h.snapshot(T + 25 days).gross, 15 days * 1e18);
    }

    function test_capDormancySkipsOnlyZeroIncomePeriodsWithoutChangingTotalDebt() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = uint256(360 days) * 1e18;
        f.balanceCeiling = f.principal + 1 days * 1e18;
        f.rateBps = 10_000;
        h.fund(1, f);
        h.checkpoint(T + 200 days, 32);
        (uint256 principal, uint256 interest,) = h.face(1, T + 200 days);
        assertEq(principal, f.balanceCeiling);
        assertEq(interest, 0);
        AccrualLoans.LifecycleWork memory work = h.repay(1, 1e18, 0, T + 200 days);
        assertEq(work.capitalized, 1 days * 1e18);
        assertEq(work.previousDue, T + Q);
        assertEq(work.nextDue, T + 3 * Q);
        assertEq(h.loan(1).frozenPikBasis, f.balanceCeiling);
        assertEq(h.loan(1).principal, f.balanceCeiling - 1e18);
        assertEq(h.loan(1).terms.periodStart, T + 200 days);
    }

    function test_amendmentReplacesSignedDueAndRateWithoutCapitalizationOrBackfill() public {
        AccrualLoans.Funding memory f = _funding(true);
        h.fund(1, f);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.rateBps = 2800;
        a.nextPaymentDue = T + 120 days;
        a.paymentInterval = 120 days;
        AccrualLoans.LifecycleWork memory work = h.amend(1, a, T + 30 days);
        assertEq(work.capitalized, 0);
        assertEq(h.loan(1).principal, P);
        assertEq(h.loan(1).frozenPikBasis, P);
        assertEq(h.loan(1).terms.periodStart, T + 30 days);
        assertEq(h.loan(1).nextCapitalization, T + 120 days);
        assertEq(h.loan(1).unpaidInterest, 11_666666666e12);
        h.checkpoint(T + 120 days, 32);
        assertEq(h.loan(1).principal, P + 11_666666666e12 + 70_000e18);
    }

    function test_partialPikReceiptThenAmendmentStillKeepsOriginalFrozenBasis() public {
        AccrualLoans.Funding memory f = _funding(true);
        h.fund(1, f);
        h.repay(1, 900_000e18, 0, T + 45 days);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.rateBps = 2800;
        a.nextPaymentDue = T + 120 days;
        a.paymentInterval = 120 days;
        h.amend(1, a, T + 50 days);
        assertEq(h.loan(1).principal, 100_000e18);
        assertEq(h.loan(1).frozenPikBasis, P);
        assertEq(h.loan(1).terms.basis, P);
        h.checkpoint(T + 120 days, 32);
        uint256 beforeIncome = P * 1400 * 50 days / (10_000 * 360 days) / 1e12 * 1e12;
        uint256 afterIncome = P * 2800 * 70 days / (10_000 * 360 days) / 1e12 * 1e12;
        assertEq(h.loan(1).principal, 100_000e18 + beforeIncome + afterIncome);
    }

    function test_signedCeilingCutPausesFutureAccrualWithoutCancellingExistingDebt() public {
        AccrualLoans.Funding memory f = _funding(true);
        h.fund(1, f);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.balanceCeiling = 0;
        h.amend(1, a, T + 30 days);
        assertEq(h.count(), 0);
        assertEq(h.loan(1).principal, P);
        assertEq(h.loan(1).unpaidInterest, 11_666666666e12);
        assertGt(h.annualWork(), 0);
    }

    function test_staleLifecycleCallsRevertUntilSeparateMaintenanceCommits() public {
        h.fund(1, _funding(true));
        bytes32 beforeLoan = keccak256(abi.encode(h.loan(1)));
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, T + Q, T + 2 * Q));
        h.repay(1, 1e18, 0, T + 2 * Q);
        assertEq(keccak256(abi.encode(h.loan(1))), beforeLoan);
        (, uint256 n, bool fresh) = h.checkpoint(T + 2 * Q, 1);
        assertEq(n, 1);
        assertFalse(fresh);
        h.checkpoint(T + 2 * Q, 1);
        h.repay(1, 1e18, 0, T + 2 * Q);
    }

    function test_maturityStopsInterestWithoutInventingFinalPikCompounding() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.maturity = T + 100 days;
        h.fund(1, f);
        h.checkpoint(f.maturity, 32);
        AccrualLoans.Loan memory loan = h.loan(1);
        assertEq(loan.principal, P + 35_000e18);
        assertEq(loan.unpaidInterest, (P + 35_000e18) * 1400 * 10 days / (10_000 * 360 days) / 1e12 * 1e12);
        assertFalse(loan.active);
        assertEq(h.count(), 0);
        assertEq(h.annualWork(), 0);
        assertEq(h.snapshot(f.maturity + Q).gross, h.snapshot(f.maturity).gross);
    }

    function test_defaultStopsEarlierAndRecoveryNeverRestartsOrCapitalizes() public {
        h.fund(1, _funding(true));
        h.stop(1, T + Q / 2);
        (uint256 principal, uint256 interest,) = h.face(1, T + 2 * Q);
        assertEq(principal, P);
        assertEq(interest, 17_500e18);
        AccrualLoans.LifecycleWork memory work = h.repay(1, P + 17_500e18, 0, T + 2 * Q);
        assertEq(work.capitalized, 0);
        assertTrue(work.repaid);
        assertEq(h.count(), 0);
        AccrualLoans.Amendment memory a = _amendment(_funding(true));
        a.nextPaymentDue = T + 3 * Q;
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_Inactive.selector, 1));
        h.amend(1, a, T + 2 * Q);
    }

    function test_signedRenewalAfterMaturityStartsNowAndCannotBackfillTheGap() public {
        AccrualLoans.Funding memory f = _funding(false);
        f.maturity = T + Q;
        h.fund(1, f);
        h.checkpoint(f.maturity, 32);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.nextPaymentDue = T + 3 * Q;
        a.maturity = T + 4 * Q;
        h.amend(1, a, T + 2 * Q);
        assertEq(h.loan(1).unpaidInterest, 35_000e18);
        assertEq(h.loan(1).terms.periodStart, T + 2 * Q);
        assertEq(h.snapshot(T + 2 * Q).gross, 35_000e18);
        assertTrue(h.loan(1).active);
    }

    function test_postingAndSelectiveIssuanceRemainIndependentOfContractDebt() public {
        h.fund(1, _funding(false));
        h.markPastDue(1, true, T);
        uint256 gross = h.snapshot(T + Q).gross;
        assertEq(h.groupUnposted(bytes32(uint256(1)), T + Q), gross);
        assertEq(h.pastDue(bytes32(uint256(1)), T + Q), gross);
        (uint256 senior, uint256 fee) = h.issuance(1, T + Q);
        assertEq(senior, gross - gross / 10);
        assertEq(fee, 0);
        assertEq(h.post(1, T + Q), gross);
        assertEq(h.groupUnposted(bytes32(uint256(1)), T + Q), 0);
        assertEq(h.pastDue(bytes32(uint256(1)), T + Q), 0);
        (senior, fee) = h.issuance(2, T + Q);
        assertEq(senior, 0);
        assertEq(fee, gross / 10);
        (uint256 principal, uint256 interest,) = h.face(1, T + Q);
        assertEq(principal, P);
        assertEq(interest, 35_000e18);
    }

    function test_invalidPaymentsAndAmendmentsRollBackExactLoanAndBookState() public {
        AccrualLoans.Funding memory f = _funding(true);
        h.fund(1, f);
        bytes32 beforeState = _stateHash(1, T + 1);
        vm.expectRevert(AccrualLoans.AccrualLoans_BadPayment.selector);
        h.repay(1, 0, 0, T + 1);
        vm.expectRevert(AccrualLoans.AccrualLoans_BadPayment.selector);
        h.repay(1, 1, 0, T + 1);
        vm.expectRevert(AccrualLoans.AccrualLoans_PikInterestLeg.selector);
        h.repay(1, 0, 1e12, T + 1);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        h.repay(1, 4 * P, 0, T + 1);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.nextPaymentDue = T + 1;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidSchedule.selector);
        h.amend(1, a, T + 1);
        assertEq(_stateHash(1, T + 1), beforeState);
    }

    function test_migrationRetainsProvedFrozenBasisButCreatesNoHistoricalIncome() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.fundedAt = T + Q / 2;
        f.principal = P / 10;
        f.frozenPikBasis = P;
        h.fund(1, f);
        assertEq(h.snapshot(f.fundedAt).gross, 0);
        assertEq(h.loan(1).principal, P / 10);
        assertEq(h.loan(1).terms.basis, P);
        h.checkpoint(T + Q, 32);
        assertEq(h.loan(1).principal, P / 10 + 17_500e18);
        assertEq(h.loan(1).frozenPikBasis, P / 10 + 17_500e18);
        assertEq(h.snapshot(T + Q).gross, 17_500e18);
    }

    function test_longFirstCouponIsNotSuppressedByZeroRegularCoupons() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = 360 days / 2;
        f.balanceCeiling = 3 * f.principal;
        f.rateBps = 10_000;
        f.scale = 1;
        f.paymentInterval = 1;
        f.nextPaymentDue = T + 4;
        f.maturity = T + 8;
        h.fund(1, f);
        assertEq(h.count(), 1);
        h.checkpoint(T + 4, 32);
        assertEq(h.loan(1).principal, f.principal + 2);
        assertEq(h.snapshot(T + 4).gross, 2);
        assertEq(h.count(), 0);
    }

    function test_pendingCapitalizationCannotSuppressPositiveSuccessorCoupon() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = 360 days - 1;
        f.balanceCeiling = 3 * f.principal;
        f.rateBps = 10_000;
        f.scale = 1;
        f.paymentInterval = 1;
        f.nextPaymentDue = T + 3;
        f.maturity = T + 8;
        h.fund(1, f);
        // Keep the pending U while replacing the due with a one-second residual coupon.
        AccrualLoans.Amendment memory a = _amendment(f);
        h.amend(1, a, T + 2);
        assertEq(h.loan(1).unpaidInterest, 1);
        assertEq(h.count(), 1);
        bytes32 beforeService = _stateHash(1, T + 2);
        h.serviceDormant(1, T + 2);
        assertEq(_stateHash(1, T + 2), beforeService, "a zero-amount queued segment can enable future income");
        h.checkpoint(T + 3, 32);
        assertEq(h.loan(1).principal, 360 days);
        assertEq(h.count(), 1);
        h.checkpoint(T + 4, 32);
        assertEq(h.loan(1).principal, 360 days + 1);
    }

    function test_preCapPaymentRetainsOriginalFractionAndExpandsOnlyFutureCap() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = uint256(360 days) * 2 / 3;
        f.balanceCeiling = f.principal + 3;
        f.rateBps = 10_000;
        f.scale = 1;
        f.paymentInterval = 9;
        f.nextPaymentDue = T + 9;
        f.maturity = T + 18;
        h.fund(1, f);
        h.repay(1, 1, 0, T + 2);
        assertEq(h.loan(1).terms.periodStart, T);
        assertEq(h.loan(1).terms.cap, 4);
        h.stop(1, T + 3);
        assertEq(h.loan(1).unpaidInterest, 2);
        assertEq(h.snapshot(T + 3).gross, 2);
    }

    function test_annualTechnicalSplitsDoNotChangeLongSignedPikBasis() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.paymentInterval = 3 * 365 days;
        f.nextPaymentDue = T + f.paymentInterval;
        f.maturity = T + 4 * 365 days;
        f.yearSeconds = 365 days;
        h.fund(1, f);
        assertEq(h.next().deadline, T + 365 days);
        h.checkpoint(T + 2 * 365 days, 32);
        assertEq(h.loan(1).principal, P);
        assertEq(h.loan(1).unpaidInterest, 280_000e18);
        assertEq(h.loan(1).terms.periodStart, T);
        assertEq(h.loan(1).terms.basis, P);
        h.checkpoint(T + 3 * 365 days, 32);
        assertEq(h.loan(1).principal, P + 420_000e18);
        assertEq(h.loan(1).frozenPikBasis, P + 420_000e18);
    }

    function test_capacityRejectsSlot101WithoutChangingAnyAcceptedSchedule() public {
        AccrualLoans.Funding memory f = _funding(false);
        for (uint256 id = 1; id <= 100; ++id) {
            h.fund(id, f);
        }
        bytes32 beforeState = _stateHash(1, T);
        vm.expectRevert(AccrualBook.AccrualBook_Capacity.selector);
        h.fund(101, f);
        assertEq(_stateHash(1, T), beforeState);
        assertFalse(h.loan(101).configured);
    }

    function test_workCapacityAmendmentRollsBackReconciliationPostingAndTerms() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.paymentInterval = 1;
        f.nextPaymentDue = T + 1;
        h.fund(1, f);
        h.fund(2, _funding(true));
        bytes32 beforeState = _stateHash(2, T);
        AccrualLoans.Amendment memory a = _amendment(f);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_WorkCapacity.selector, 2 * (YEAR + 4)));
        h.amend(2, a, T);
        assertEq(_stateHash(2, T), beforeState);
        assertEq(h.loan(1).paymentInterval, 1);
    }

    function test_cashLegsAreBoundedIndependentlyAndOnlyTheirSumMustBeOnGrid() public {
        AccrualLoans.Funding memory f = _funding(false);
        h.fund(1, f);
        bytes32 beforeState = _stateHash(1, T + Q);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        h.repay(1, P + 1e12, 0, T + Q);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        h.repay(1, 0, 35_000e18 + 1e12, T + Q);
        assertEq(_stateHash(1, T + Q), beforeState);
        AccrualLoans.LifecycleWork memory work = h.repay(1, 1, 1e12 - 1, T + Q);
        assertEq(work.principalReduction, 1);
        assertEq(work.interestReduction, 1e12 - 1);
        assertEq(h.loan(1).principal, P - 1);
        assertEq(h.loan(1).unpaidInterest, 35_000e18 - 1e12 + 1);
    }

    function test_dormantMaturityReceiptReleasesReservedWorkAndStops() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.balanceCeiling = f.principal;
        h.fund(1, f);
        assertEq(h.count(), 0);
        AccrualLoans.LifecycleWork memory work = h.repay(1, 1e18, 0, f.maturity + 1);
        assertTrue(work.stopped);
        assertFalse(work.repaid);
        assertEq(work.nextDue, 0);
        assertFalse(h.loan(1).active);
        assertEq(h.annualWork(), 0);
    }

    function test_pausedAmendmentReportsOriginalBridgeDueWhileAdvancingSignedFuture() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.balanceCeiling = f.principal;
        h.fund(1, f);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.balanceCeiling = 3 * P;
        a.nextPaymentDue = T + 3 * Q;
        AccrualLoans.LifecycleWork memory work = h.amend(1, a, T + 2 * Q);
        assertEq(work.previousDue, T + Q);
        assertEq(work.nextDue, T + 3 * Q);
        assertEq(h.loan(1).terms.periodStart, T + 2 * Q);
        assertEq(h.snapshot(T + 2 * Q).gross, 0);
    }

    function test_partialRecoveryDoesNotResumeAnEarlierDeclaredLoan() public {
        h.fund(1, _funding(true));
        h.stop(1, T + 1);
        h.repay(1, 1e18, 0, T + 2);
        assertTrue(h.loan(1).permanentlyStopped);
        assertFalse(h.loan(1).active);
        assertEq(h.count(), 0);
    }

    function test_paymentSumOverflowHasNamedErrorAndPreservesState() public {
        h.fund(1, _funding(false));
        bytes32 beforeState = _stateHash(1, T);
        vm.expectRevert(AccrualLoans.AccrualLoans_Overflow.selector);
        h.repay(1, type(uint256).max, 1, T);
        assertEq(_stateHash(1, T), beforeState);
    }

    function test_defensiveClosureNonceOverflowRollsBack() public {
        h.fund(1, _funding(true));
        h.corruptClosure(1, type(uint64).max, 0, 0);
        bytes32 beforeState = _stateHash(1, T);
        vm.expectRevert(AccrualLoans.AccrualLoans_Overflow.selector);
        h.stop(1, T);
        assertEq(_stateHash(1, T), beforeState);
    }

    function test_defensiveCanonicalProofBoundsRejectCorruptBaselines() public {
        h.fund(1, _funding(true));
        h.repay(1, 1e18, 0, T + Q / 2);
        AccrualLoans.Loan memory loan = h.loan(1);
        h.corruptClosure(1, loan.closureNonce, loan.segmentBookBase, 0);
        bytes32 beforeState = _stateHash(1, T + Q / 2);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualLoans.AccrualLoans_CorrectionOutsideBound.selector, 17_500e18, 1e12)
        );
        h.stop(1, T + Q / 2);
        assertEq(_stateHash(1, T + Q / 2), beforeState);
        h.corruptClosure(1, loan.closureNonce, 0, loan.segmentCumulativeStart);
        beforeState = _stateHash(1, T + Q / 2);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualLoans.AccrualLoans_CorrectionOutsideBound.selector, 17_500e18, 1e12)
        );
        h.stop(1, T + Q / 2);
        assertEq(_stateHash(1, T + Q / 2), beforeState);
    }

    function test_remainingFundingAndDateDomainGuards() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = type(uint256).max;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidFunding.selector);
        h.fund(1, f);
        f = _funding(true);
        f.frozenPikBasis = type(uint256).max / 10_000 + 1;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidFunding.selector);
        h.fund(1, f);
        f = _funding(false);
        f.frozenPikBasis = P;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidFunding.selector);
        h.fund(1, f);
        f = _funding(true);
        f.nextPaymentDue = T;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidSchedule.selector);
        h.fund(1, f);
        f = _funding(true);
        f.nextPaymentDue = f.maturity + 1;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidSchedule.selector);
        h.fund(1, f);
        f = _funding(true);
        f.paymentInterval = f.nextPaymentDue + 1;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidSchedule.selector);
        h.fund(1, f);
        f = _funding(true);
        f.maturity = T;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidSchedule.selector);
        h.fund(1, f);
    }

    function test_unknownBatchFundingAndScheduleGuards() public {
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_Unknown.selector, 1));
        h.stop(1, T);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_BadBatch.selector, 0));
        h.checkpoint(T, 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_BadBatch.selector, 33));
        h.checkpoint(T, 33);
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = 0;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidFunding.selector);
        h.fund(1, f);
        f = _funding(true);
        f.balanceCeiling = P - 1;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidFunding.selector);
        h.fund(1, f);
        f = _funding(true);
        f.balanceCeiling = type(uint256).max / 10_000 + 1;
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_InvalidCeiling.selector, f.balanceCeiling));
        h.fund(1, f);
        f = _funding(true);
        f.paymentInterval = 0;
        vm.expectRevert(AccrualLoans.AccrualLoans_InvalidSchedule.selector);
        h.fund(1, f);
        f = _funding(true);
        f.yearSeconds = 364 days;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, f.yearSeconds));
        h.fund(1, f);
    }

    function testFuzz_pikPartialPaymentKeepsFullCurrentCoupon(uint96 units, uint32 elapsedSeed, uint64 paidSeed)
        public
    {
        uint256 principal = (uint256(units) % 1_000_000_000 + 1000) * 1e12;
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = principal;
        f.balanceCeiling = 3 * principal;
        h.fund(1, f);
        uint64 elapsed = uint64(uint256(elapsedSeed) % (Q - 1) + 1);
        uint256 paid = (uint256(paidSeed) % (principal / 1e12 - 1) + 1) * 1e12;
        h.repay(1, paid, 0, T + elapsed);
        assertEq(h.loan(1).frozenPikBasis, principal);
        h.checkpoint(T + Q, 32);
        uint256 coupon = principal * 1400 * Q / (10_000 * 360 days) / 1e12 * 1e12;
        assertEq(h.loan(1).principal, principal - paid + coupon);
        assertEq(h.loan(1).unpaidInterest, 0);
    }

    function testFuzz_cashPayoffMatchesCanonicalFaceAndExplicitRounding(uint96 units, uint32 elapsedSeed) public {
        AccrualLoans.Funding memory f = _funding(false);
        f.principal = (uint256(units) + 1) * 1e12;
        f.balanceCeiling = 3 * f.principal;
        h.fund(1, f);
        uint64 elapsed = uint64(uint256(elapsedSeed) % (4 * Q - 1) + 1);
        uint256 exact = f.principal * 1400 * elapsed / (10_000 * 360 days) / 1e12 * 1e12;
        AccrualLoans.LifecycleWork memory work = h.repay(1, f.principal, exact, T + elapsed);
        assertTrue(work.repaid);
        assertEq(work.principalReduction, f.principal);
        assertEq(work.interestReduction, exact);
        assertLe(work.positiveCorrection, f.scale);
        assertLt(work.roundingLoss, f.scale);
        assertEq(h.snapshot(T + elapsed).gross - work.roundingLoss, exact);
        assertEq(h.count(), 0);
    }

    function testFuzz_bscCanonicalClosureNeverCreatesNegativeRounding(uint128 principalSeed, uint32 elapsedSeed)
        public
    {
        AccrualLoans.Funding memory f = _funding(false);
        f.principal = uint256(principalSeed) + 1;
        f.balanceCeiling = 3 * f.principal;
        f.scale = 1;
        h.fund(1, f);
        uint64 elapsed = uint64(uint256(elapsedSeed) % (4 * Q - 1) + 1);
        AccrualLoans.LifecycleWork memory work = h.stop(1, T + elapsed);
        assertEq(work.roundingLoss, 0);
        assertLe(work.positiveCorrection, 1);
        uint256 exact = f.principal * 1400 * elapsed / (10_000 * 360 days);
        assertEq(h.snapshot(T + elapsed).gross, exact);
        assertEq(h.loan(1).unpaidInterest, exact);
    }

    function testFuzz_chunkSizeDoesNotChangeQuarterlyRecurrence(uint8 chunkSeed, uint8 countSeed) public {
        AccrualLoansHarness other = _harness();
        uint256 loans = uint256(countSeed) % 8 + 1;
        for (uint256 id = 1; id <= loans; ++id) {
            h.fund(id, _funding(true));
            other.fund(id, _funding(true));
        }
        uint256 chunk = uint256(chunkSeed) % 32 + 1;
        bool fresh;
        while (!fresh) (,, fresh) = h.checkpoint(T + 4 * Q, chunk);
        fresh = false;
        while (!fresh) (,, fresh) = other.checkpoint(T + 4 * Q, 32);
        assertEq(abi.encode(h.snapshot(T + 4 * Q)), abi.encode(other.snapshot(T + 4 * Q)));
        for (uint256 id = 1; id <= loans; ++id) {
            assertEq(abi.encode(h.loan(id)), abi.encode(other.loan(id)));
        }
    }

    function testFuzz_fullWidthBasisAndEndpointStayWithinProvedCeiling(
        uint256 basisSeed,
        uint64 durationSeed,
        uint16 rateSeed,
        bool sixDecimals
    ) public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = basisSeed % (type(uint256).max / 10_000) + 1;
        f.balanceCeiling = type(uint256).max / 10_000;
        f.scale = sixDecimals ? 1e12 : 1;
        f.yearSeconds = 365 days;
        f.rateBps = rateSeed % 10_001;
        f.paymentInterval = durationSeed % uint64(365 days) + 1;
        f.nextPaymentDue = T + f.paymentInterval;
        f.maturity = f.nextPaymentDue;
        h.fund(1, f);
        h.checkpoint(f.maturity, 32);
        uint256 product = f.principal * f.rateBps;
        uint256 denominator = 10_000 * 365 days;
        // Independent quotient/remainder decomposition: the raw triple product can overflow.
        uint256 raw =
            product / denominator * f.paymentInterval + product % denominator * f.paymentInterval / denominator;
        uint256 cap = f.balanceCeiling - f.principal;
        uint256 expected = raw < cap ? raw : cap;
        expected -= expected % f.scale;
        (uint256 principal, uint256 interest,) = h.face(1, f.maturity);
        assertEq(principal + interest, f.principal + expected);
        assertEq(h.snapshot(f.maturity).gross, expected);
        assertEq(h.count(), 0);
    }

    function testFuzz_repeatedPikReceiptsConserveNativePostingProofAndIssuance(uint96 units) public {
        AccrualLoans.Funding memory f = _funding(true);
        f.principal = (uint256(units) % 1_000_000_000 + 5000) * 1e12;
        f.balanceCeiling = 3 * f.principal;
        h.fund(1, f);
        uint256 paid = f.principal / (10 * 1e12) * 1e12;
        uint256 posted;
        uint256 losses;
        uint256 minted;
        for (uint64 step = 1; step <= 4; ++step) {
            uint64 at = T + step * 18 days;
            AccrualLoans.LifecycleWork memory work = h.repay(1, paid, 0, at);
            posted += work.posting;
            losses += work.roundingLoss;
            assertEq(h.loan(1).frozenPikBasis, f.principal);
            assertEq(h.loan(1).terms.periodStart, T);
            (uint256 senior, uint256 fee) = h.issuance(step % 2 == 0 ? 1 : 2, at);
            minted += senior + fee;
        }
        h.checkpoint(T + Q, 32);
        uint256 coupon = f.principal * 1400 * Q / (10_000 * 360 days) / 1e12 * 1e12;
        assertEq(h.loan(1).principal, f.principal - 4 * paid + coupon);
        assertEq(h.snapshot(T + Q).gross - losses, coupon);
        posted += h.post(1, T + Q);
        (uint256 finalSenior, uint256 finalFee) = h.issuance(3, T + Q);
        minted += finalSenior + finalFee;
        assertEq(posted, h.snapshot(T + Q).gross);
        assertEq(minted, posted);
        assertEq(f.principal + posted - losses - 4 * paid, h.loan(1).principal);
        assertEq(h.groupUnposted(bytes32(uint256(1)), T + Q), 0);
    }

    function testFuzz_forwardRateAmendmentKeepsBothProvedIncomeEpochs(
        uint96 units,
        uint16 oldRateSeed,
        uint16 newRateSeed
    ) public {
        AccrualLoans.Funding memory f = _funding(false);
        f.principal = (uint256(units) + 1) * 1e12;
        f.balanceCeiling = 3 * f.principal;
        f.rateBps = oldRateSeed % 10_001;
        h.fund(1, f);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.rateBps = newRateSeed % 10_001;
        AccrualLoans.LifecycleWork memory beforeWork = h.amend(1, a, T + 30 days);
        AccrualLoans.LifecycleWork memory afterWork = h.stop(1, T + 150 days);
        uint256 oldIncome = f.principal * f.rateBps * 30 days / (10_000 * 360 days) / 1e12 * 1e12;
        uint256 newIncome = f.principal * a.rateBps * 120 days / (10_000 * 360 days) / 1e12 * 1e12;
        assertEq(h.loan(1).unpaidInterest, oldIncome + newIncome);
        assertEq(
            h.snapshot(T + 150 days).gross - beforeWork.roundingLoss - afterWork.roundingLoss, oldIncome + newIncome
        );
        assertEq(h.loan(1).principal, f.principal);
        assertEq(h.loan(1).nextCapitalization, T + Q);
    }

    function test_dormantServiceRejectsUnknownAndStaleWorkBeforeAnyMutation() public {
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_Unknown.selector, 999));
        h.serviceDormant(999, T);
        h.fund(1, _funding(true));
        AccrualLoans.Funding memory zero = _funding(true);
        zero.rateBps = 0;
        h.fund(2, zero);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, T + Q, T + Q));
        h.serviceDormant(2, T + Q);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, T + Q, T + Q + 1));
        h.serviceDormant(2, T + Q + 1);
        assertEq(h.loan(2).nextCapitalization, T + Q);
        assertEq(h.loan(2).lastSettlement, T);
    }

    function test_dormantServiceDoesNotCloseAQueuedPositiveOrFutureEnablingSegment() public {
        h.fund(1, _funding(true));
        bytes32 beforeState = _stateHash(1, T + Q / 2);
        AccrualLoans.LifecycleWork memory work = h.serviceDormant(1, T + Q / 2);
        assertEq(_stateHash(1, T + Q / 2), beforeState);
        assertEq(work.capitalized, 0);
        assertEq(work.closureNonce, 0);
        assertEq(work.posting, 0);
        assertEq(h.clockAt(), T);
        assertEq(h.next().deadline, T + Q);
    }

    function test_zeroRateDormantDatesAdvanceWithoutNewIncomeOrBridgeStubCapitalization() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.rateBps = 0;
        f.maturity = T + 3 * Q + 5 days;
        h.fund(1, f);
        bytes32 beforeState = _stateHash(1, T + Q - 1);
        h.serviceDormant(1, T + Q - 1);
        assertEq(_stateHash(1, T + Q - 1), beforeState);
        AccrualLoans.LifecycleWork memory work = h.serviceDormant(1, T + 2 * Q + 1);
        assertEq(work.previousDue, T + Q);
        assertEq(work.nextDue, T + 3 * Q);
        assertEq(work.capitalized, 0);
        assertEq(h.snapshot(T + 2 * Q + 1).gross, 0);
        assertEq(h.count(), 0);
        assertEq(h.clockAt(), T + 2 * Q + 1);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, T + 2 * Q + 1, T + Q));
        h.post(1, T + Q);
        work = h.serviceDormant(1, T + 3 * Q);
        assertEq(work.previousDue, T + 3 * Q);
        assertEq(work.nextDue, 0);
        assertFalse(work.stopped);
        assertTrue(h.loan(1).active);
        beforeState = _stateHash(1, T + 3 * Q + 1);
        h.serviceDormant(1, T + 3 * Q + 1);
        assertEq(_stateHash(1, T + 3 * Q + 1), beforeState);
        work = h.serviceDormant(1, f.maturity);
        assertEq(work.capitalized, 0);
        assertEq(work.previousDue, 0);
        assertEq(work.nextDue, 0);
        assertTrue(work.stopped);
        assertFalse(h.loan(1).active);
        assertFalse(h.loan(1).permanentlyStopped);
        assertEq(h.loan(1).principal, P);
        assertEq(h.annualWork(), 0);
        beforeState = _stateHash(1, f.maturity + 1);
        h.serviceDormant(1, f.maturity + 1);
        assertEq(_stateHash(1, f.maturity + 1), beforeState);
        AccrualLoans.Amendment memory a = _amendment(f);
        a.rateBps = 1400;
        a.nextPaymentDue = f.maturity + Q;
        a.maturity = f.maturity + 2 * Q;
        h.amend(1, a, f.maturity + 1);
        assertTrue(h.loan(1).active);
        assertEq(h.snapshot(f.maturity + 1).gross, 0);
        assertEq(h.count(), 1);
    }

    function test_dormantServiceCheckpointsSharedTimeWithoutChangingOtherLiveIncome() public {
        AccrualLoans.Funding memory zero = _funding(true);
        zero.rateBps = 0;
        h.fund(1, zero);
        h.fund(2, _funding(false));
        AccrualBook.Snapshot memory beforeBook = h.snapshot(T + Q);
        assertGt(beforeBook.gross, 0);
        h.serviceDormant(1, T + Q);
        assertEq(keccak256(abi.encode(h.snapshot(T + Q))), keccak256(abi.encode(beforeBook)));
        assertEq(h.clockAt(), T + Q);
        assertEq(h.count(), 1);
        assertEq(h.next().deadline, T + 4 * Q);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, T + Q, T + Q - 1));
        h.post(2, T + Q - 1);
    }

    function test_dormantServiceLeavesCashAndPermanentlyStoppedDebtUnchanged() public {
        AccrualLoans.Funding memory f = _funding(false);
        f.rateBps = 0;
        h.fund(1, f);
        bytes32 beforeState = _stateHash(1, T + Q);
        h.serviceDormant(1, T + Q);
        assertEq(_stateHash(1, T + Q), beforeState);
        f.pik = true;
        h.fund(2, f);
        h.stop(2, T + 1);
        beforeState = _stateHash(2, T + Q);
        h.serviceDormant(2, T + Q);
        assertEq(_stateHash(2, T + Q), beforeState);
        assertTrue(h.loan(2).permanentlyStopped);
    }

    function test_dormantServiceSupportsFullWidthLastDatesInConstantWork() public {
        AccrualLoans.Funding memory f = _funding(true);
        f.rateBps = 0;
        f.paymentInterval = 1;
        f.nextPaymentDue = T + 1;
        f.maturity = type(uint64).max;
        h.fund(type(uint256).max, f);
        AccrualLoans.LifecycleWork memory work = h.serviceDormant(type(uint256).max, type(uint64).max - 1);
        assertEq(work.previousDue, T + 1);
        assertEq(work.nextDue, type(uint64).max);
        assertEq(work.capitalized, 0);
        work = h.serviceDormant(type(uint256).max, type(uint64).max);
        assertEq(work.nextDue, 0);
        assertTrue(work.stopped);
        assertEq(h.loan(type(uint256).max).lastSettlement, type(uint64).max);
        assertEq(h.snapshot(type(uint64).max).gross, 0);
    }

    function testFuzz_dormantZeroDateSkipMatchesIndependentDivision(uint32 intervalSeed, uint32 spanSeed, uint64 atSeed)
        public
    {
        AccrualLoans.Funding memory f = _funding(true);
        f.rateBps = 0;
        f.paymentInterval = uint64(uint256(intervalSeed) % 365 days + 1);
        f.nextPaymentDue = T + f.paymentInterval;
        f.maturity = T + f.paymentInterval * uint64(uint256(spanSeed) % 10_000 + 2) + f.paymentInterval / 2;
        uint64 at = T + uint64(uint256(atSeed) % (uint256(f.maturity - T) + f.paymentInterval));
        h.fund(1, f);
        AccrualLoans.LifecycleWork memory work = h.serviceDormant(1, at);
        uint256 elapsed = (at < f.maturity ? at : f.maturity) - T;
        uint256 successor = uint256(T) + (elapsed / f.paymentInterval + 1) * f.paymentInterval;
        uint64 expected = successor > f.maturity ? 0 : uint64(successor);
        assertEq(h.loan(1).nextCapitalization, expected);
        assertEq(h.loan(1).principal, P);
        assertEq(h.loan(1).unpaidInterest, 0);
        assertEq(work.capitalized, 0);
        assertEq(work.posting, 0);
        assertEq(h.snapshot(at).gross, 0);
        assertEq(h.count(), 0);
        assertEq(h.loan(1).active, at < f.maturity);
    }

    function testFuzz_dormantCapServicesUnpaidPikOnceAndConservesEveryBookClaim(
        uint64 capSeed,
        uint32 atSeed,
        uint8 legSeed
    ) public {
        AccrualLoans.Funding memory f = _funding(true);
        uint256 cap = (uint256(capSeed) % 30_000 + 1) * 1e18;
        f.balanceCeiling = P + cap;
        h.fund(1, f);
        h.markPastDue(1, true, T);
        h.checkpoint(T + Q - 1, 32);
        assertEq(h.count(), 0);
        assertEq(h.loan(1).unpaidInterest, cap);
        assertEq(h.loan(1).principal, P);
        h.issuance(1 + legSeed % 3, T + Q - 1);
        uint64 at = T + Q + uint64(uint256(atSeed) % (4 * Q));
        AccrualBook.Snapshot memory beforeBook = h.snapshot(at);
        AccrualLoans.LifecycleWork memory work = h.serviceDormant(1, at);
        assertEq(work.capitalized, cap);
        assertEq(work.posting, 0);
        assertEq(work.positiveCorrection, 0);
        assertEq(work.roundingLoss, 0);
        assertEq(h.loan(1).principal, P + cap);
        assertEq(h.loan(1).unpaidInterest, 0);
        assertEq(keccak256(abi.encode(h.snapshot(at))), keccak256(abi.encode(beforeBook)));
        assertEq(h.pastDue(f.keys[0], at), cap);
        for (uint256 i; i < 3; ++i) {
            assertEq(h.groupUnposted(f.keys[i], at), cap);
        }
        assertEq(h.annualWork(), at >= f.maturity ? 0 : 9);
        bytes32 beforeState = _stateHash(1, at);
        work = h.serviceDormant(1, at);
        assertEq(work.capitalized, 0);
        assertEq(_stateHash(1, at), beforeState);
    }

    function _harness() private returns (AccrualLoansHarness result) {
        result = new AccrualLoansHarness();
        result.initialize(T, 1000);
    }

    function _funding(bool pik) private pure returns (AccrualLoans.Funding memory f) {
        f = AccrualLoans.Funding({
            principal: P,
            balanceCeiling: 3 * P,
            scale: 1e12,
            yearSeconds: 360 days,
            rateBps: 1400,
            fundedAt: T,
            nextPaymentDue: T + Q,
            paymentInterval: Q,
            maturity: T + 4 * Q,
            pik: pik,
            keys: [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))],
            frozenPikBasis: 0
        });
    }

    function _amendment(AccrualLoans.Funding memory f) private pure returns (AccrualLoans.Amendment memory) {
        return AccrualLoans.Amendment(
            f.balanceCeiling, f.yearSeconds, f.rateBps, f.nextPaymentDue, f.paymentInterval, f.maturity
        );
    }

    function _stateHash(uint256 id, uint64 at) private view returns (bytes32) {
        return keccak256(abi.encode(h.loan(id), h.snapshot(at), h.annualWork(), h.count(), h.registered()));
    }
}
