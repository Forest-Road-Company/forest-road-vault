// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";

/// @dev Local arithmetic adapter. Production must authenticate the opening and execute native work.
contract AccrualOpeningHarness {
    using AccrualLoans for AccrualLoans.State;
    using AccrualBook for AccrualBook.Book;

    AccrualLoans.State private state;

    function initialize(uint64 at) external {
        state.initialize(at, 1000);
    }

    function importOpening(uint256 id, AccrualLoans.Opening memory opening) external returns (uint256) {
        return state.importOpening(id, opening);
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

    function checkpoint(uint64 at) external returns (AccrualLoans.LifecycleWork[] memory, uint256, bool) {
        return state.checkpoint(at, 32);
    }

    function repay(uint256 id, uint256 principal, uint256 interest, uint64 at)
        external
        returns (AccrualLoans.LifecycleWork memory)
    {
        return state.repay(id, principal, interest, at);
    }

    function stop(uint256 id, uint64 at) external returns (AccrualLoans.LifecycleWork memory) {
        return state.stop(id, at);
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

    function service(uint256 id, uint64 at) external {
        state.serviceDormant(id, at);
    }

    function amend(uint256 id, AccrualLoans.Amendment memory changed, uint64 at)
        external
        returns (AccrualLoans.LifecycleWork memory)
    {
        return state.amend(id, changed, at);
    }

    function post(uint256 id, uint64 at) external returns (uint256) {
        return state.post(id, at);
    }

    function earned(uint256 id, uint64 at) external view returns (uint256) {
        return state.book.earned(id, at);
    }

    function mark(uint256 id, bool marked, uint64 at) external {
        state.book.setPastDue(id, marked, at);
    }

    function issue(uint8 legs, uint64 at) external returns (uint256, uint256) {
        return state.book.takeIssuance(legs, at);
    }

    function retire(uint256 id, uint64 at) external {
        state.retire(id, at);
    }
}

contract AccrualOpeningImportTest is Test {
    uint64 private constant T = 1_900_000_000;
    uint64 private constant Q = 90 days;
    uint64 private constant CUT = T + 45 days;
    AccrualOpeningHarness private h;

    function setUp() public {
        h = new AccrualOpeningHarness();
        h.initialize(CUT);
    }

    function _opening(bool pik) private pure returns (AccrualLoans.Opening memory o) {
        o.terms = AccrualLoans.Funding({
            principal: 100_000e18,
            balanceCeiling: 300_000e18,
            scale: 1e12,
            yearSeconds: 360 days,
            rateBps: 1400,
            fundedAt: CUT,
            nextPaymentDue: T + Q,
            paymentInterval: Q,
            maturity: T + 365 days,
            pik: pik,
            keys: [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))],
            frozenPikBasis: 0
        });
        o.recordedFace = 100_000e18;
        o.interest = 1_750e18;
        o.periodStart = T;
    }

    function test_cashOpeningCreatesOnlyUnreceivedIncomeAndRetainsItsCursor() public {
        AccrualLoans.Opening memory o = _opening(false);
        assertEq(h.importOpening(1, o), 1_750e18);
        AccrualBook.Snapshot memory s = h.snapshot(CUT);
        assertEq(s.gross, 1_750e18);
        assertEq(s.seniorUnissued, 1_575e18);
        assertEq(s.feeUnissued, 175e18);
        AccrualLoans.Loan memory loan = h.loan(1);
        assertEq(loan.terms.periodStart, T);
        assertEq(loan.segmentCumulativeStart, 1_750e18);
        (uint256 principal, uint256 interest,) = h.face(1, T + Q);
        assertEq(principal, 100_000e18);
        assertEq(interest, 3_500e18);
    }

    function test_pikOpeningDoesNotChargePreviouslyRecognizedCapitalizationAgain() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.principal = 110_000e18;
        o.recordedFace = 110_000e18;
        o.terms.frozenPikBasis = 120_000e18;
        o.interest = 2_100e18;
        assertEq(h.importOpening(1, o), 2_100e18);
        assertEq(h.snapshot(CUT).feeUnissued, 210e18);
        (, uint256 count, bool fresh) = h.checkpoint(T + Q);
        assertEq(count, 1);
        assertTrue(fresh);
        (uint256 principal, uint256 interest,) = h.face(1, T + Q);
        assertEq(principal, 114_200e18);
        assertEq(interest, 0);
        assertEq(h.loan(1).frozenPikBasis, 114_200e18);
    }

    function test_unrecognizedPikCapitalizationEntersTheOpeningIncomeOnce() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.principal = 110_000e18;
        o.interest = 1_925e18;
        assertEq(h.importOpening(1, o), 11_925e18);
        assertEq(h.snapshot(CUT).gross, 11_925e18);
        assertEq(h.snapshot(CUT).feeUnissued, 1_192.5e18);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_KnownFacility.selector, 1));
        h.importOpening(1, o);
        assertEq(h.snapshot(CUT).gross, 11_925e18);
    }

    function test_settledOpeningStartsWithZeroNewFeesAndPreservesFutureEntitlement() public {
        AccrualLoans.Opening memory o = _opening(false);
        o.interest = 0;
        assertEq(h.importOpening(1, o), 0);
        assertEq(h.snapshot(CUT).gross, 0);
        assertEq(h.snapshot(CUT).feeUnissued, 0);
        (uint256 principal, uint256 interest,) = h.face(1, T + Q);
        assertEq(principal, 100_000e18);
        assertEq(interest, 1_750e18);
    }

    function test_stoppedOpeningNeverEarnsAfterItsDeclaredCutoff() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.permanentlyStopped = true;
        assertEq(h.importOpening(1, o), o.interest);
        assertEq(h.count(), 0);
        assertEq(h.annualWork(), 0);
        (uint256 principal, uint256 interest,) = h.face(1, T + 1_000 days);
        assertEq(principal, o.terms.principal);
        assertEq(interest, o.interest);
        assertEq(h.snapshot(T + 1_000 days).gross, o.interest);
        assertFalse(h.loan(1).active);
        assertTrue(h.loan(1).permanentlyStopped);
    }

    function test_invalidOpeningBalancesAndCursorsRevertWithoutRegisteringDebt() public {
        for (uint256 mode; mode < 12; ++mode) {
            AccrualLoans.Opening memory o = _opening(mode >= 8);
            if (mode == 0) {
                o.terms.principal = 0;
                o.interest = 0;
                o.recordedFace = 0;
            } else if (mode == 1) {
                o.terms.balanceCeiling = o.terms.principal;
            } else if (mode == 2) {
                o.recordedFace = o.terms.principal + o.interest + 1;
            } else if (mode == 3) {
                o.terms.frozenPikBasis = 1;
            } else if (mode == 4) {
                o.periodStart = CUT + 1;
            } else if (mode == 5) {
                o.periodStart = CUT;
                o.terms.maturity = CUT;
                o.terms.nextPaymentDue = 0;
            } else if (mode == 6) {
                o.terms.paymentInterval = 0;
            } else if (mode == 7) {
                o.terms.nextPaymentDue = o.terms.maturity + 1;
            } else if (mode == 8) {
                o.terms.paymentInterval = o.terms.nextPaymentDue + 1;
            } else if (mode == 9) {
                o.terms.nextPaymentDue = CUT;
            } else if (mode == 10) {
                o.terms.nextPaymentDue = CUT - 1;
            } else if (mode == 11) {
                o.terms.frozenPikBasis = type(uint256).max / 10_000 + 1;
            }
            vm.expectRevert(AccrualLoans.AccrualLoans_InvalidOpening.selector);
            h.importOpening(mode + 1, o);
            _assertEmpty(mode + 1);
        }
    }

    function test_numericOpeningLimitsFailWithNamedErrors() public {
        AccrualLoans.Opening memory o = _opening(false);
        o.terms.principal = type(uint256).max;
        vm.expectRevert(AccrualLoans.AccrualLoans_Overflow.selector);
        h.importOpening(1, o);
        _assertEmpty(1);
        o = _opening(false);
        o.terms.balanceCeiling = type(uint256).max / 10_000 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(AccrualLoans.AccrualLoans_InvalidCeiling.selector, o.terms.balanceCeiling)
        );
        h.importOpening(1, o);
        o = _opening(false);
        o.terms.scale = 0;
        vm.expectRevert(AccrualMath.AccrualMath_ZeroScale.selector);
        h.importOpening(1, o);
        o = _opening(false);
        o.terms.rateBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, uint16(10_001)));
        h.importOpening(1, o);
        o = _opening(false);
        o.terms.yearSeconds = 366 days;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, 366 days));
        h.importOpening(1, o);
        o = _opening(false);
        o.terms.principal = type(uint256).max / 20_000;
        o.recordedFace = o.terms.principal;
        o.terms.balanceCeiling = type(uint256).max / 10_000;
        o.terms.scale = 1;
        o.terms.fundedAt = type(uint64).max - 1;
        o.terms.maturity = type(uint64).max;
        o.terms.nextPaymentDue = 0;
        o.periodStart = 0;
        vm.expectRevert(AccrualLoans.AccrualLoans_Overflow.selector);
        h.importOpening(1, o);
        _assertEmpty(1);
    }

    function test_importHonorsInitializationIdentityAndClockGuards() public {
        AccrualLoans.Opening memory o = _opening(false);
        AccrualOpeningHarness uninitialized = new AccrualOpeningHarness();
        vm.expectRevert(AccrualBook.AccrualBook_NotInitialized.selector);
        uninitialized.importOpening(1, o);
        o.terms.keys[1] = o.terms.keys[0];
        vm.expectRevert(AccrualBook.AccrualBook_InvalidKeys.selector);
        h.importOpening(1, o);
        _assertEmpty(1);
        o = _opening(false);
        o.terms.fundedAt = CUT - 1;
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_TimeReversed.selector, CUT, CUT - 1));
        h.importOpening(1, o);
        _assertEmpty(1);
    }

    function test_workAdmissionFailureRollsBackTheCreditedOpeningAndIdentity() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.paymentInterval = 1;
        o.terms.nextPaymentDue = CUT + 1;
        o.periodStart = CUT;
        h.importOpening(1, o);
        uint256 weight = 365 days + 4;
        assertEq(h.annualWork(), weight);
        bytes32 beforeLoan = keccak256(abi.encode(h.loan(1)));
        bytes32 beforeBook = keccak256(abi.encode(h.snapshot(CUT)));
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_WorkCapacity.selector, weight * 2));
        h.importOpening(2, o);
        assertEq(h.annualWork(), weight);
        assertEq(h.registered(), 1);
        assertEq(h.count(), 1);
        assertEq(keccak256(abi.encode(h.loan(1))), beforeLoan);
        assertEq(keccak256(abi.encode(h.snapshot(CUT))), beforeBook);
        assertFalse(h.loan(2).configured);
        o.terms.paymentInterval = Q;
        o.terms.nextPaymentDue = T + Q;
        h.importOpening(2, o);
        assertEq(h.registered(), 2, "failed import retained its known-ID tombstone");
    }

    function test_portfolioCapacityCannotPartiallyImportTheExtraRow() public {
        AccrualLoans.Opening memory o = _opening(false);
        o.terms.rateBps = 0;
        for (uint256 id = 1; id <= 100; ++id) {
            h.importOpening(id, o);
        }
        vm.expectRevert(AccrualBook.AccrualBook_Capacity.selector);
        h.importOpening(101, o);
        assertEq(h.registered(), 100);
        assertEq(h.snapshot(CUT).gross, 100 * o.interest);
        assertFalse(h.loan(101).configured);
    }

    function test_maturedOpeningIsStaticAndAnAmendmentMustExplicitlyRestartIt() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.maturity = CUT - 1;
        o.terms.nextPaymentDue = 0;
        h.importOpening(1, o);
        assertFalse(h.loan(1).active);
        assertFalse(h.loan(1).permanentlyStopped);
        assertEq(h.annualWork(), 0);
        assertEq(h.count(), 0);
        (uint256 principal, uint256 interest,) = h.face(1, CUT + 365 days);
        assertEq(principal, o.terms.principal);
        assertEq(interest, o.interest);
        AccrualLoans.Amendment memory changed = AccrualLoans.Amendment({
            balanceCeiling: o.terms.balanceCeiling,
            yearSeconds: 360 days,
            rateBps: 1400,
            nextPaymentDue: CUT + Q,
            paymentInterval: Q,
            maturity: CUT + 365 days
        });
        h.amend(1, changed, CUT);
        assertTrue(h.loan(1).active);
        (, interest,) = h.face(1, CUT + Q);
        assertEq(interest, o.interest + 3_500e18);
    }

    function test_finalPikStubStopsAtMaturityWithoutInventingACapitalization() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.nextPaymentDue = 0;
        o.terms.maturity = T + 60 days;
        h.importOpening(1, o);
        (, uint256 count, bool fresh) = h.checkpoint(o.terms.maturity);
        assertEq(count, 1);
        assertTrue(fresh);
        (uint256 principal, uint256 interest,) = h.face(1, T + 365 days);
        assertEq(principal, o.terms.principal);
        assertEq(interest, 2_333_333_333e12);
        assertFalse(h.loan(1).active);
        assertEq(h.annualWork(), 0);
    }

    function test_pastDueCashAndInterestOnlyCashPreserveTheirSeparateDebts() public {
        AccrualLoans.Opening memory o = _opening(false);
        o.terms.nextPaymentDue = CUT - 1;
        h.importOpening(1, o);
        (uint256 principal, uint256 interest,) = h.face(1, T + Q);
        assertEq(principal, o.terms.principal);
        assertEq(interest, 3_500e18);
        o.terms.principal = 0;
        o.recordedFace = 0;
        h.importOpening(2, o);
        assertTrue(h.loan(2).active);
        (principal, interest,) = h.face(2, T + Q);
        assertEq(principal, 0);
        assertEq(interest, o.interest);
        h.repay(2, 0, o.interest, CUT);
        assertTrue(h.loan(2).permanentlyStopped);
        assertEq(h.loan(2).unpaidInterest, 0);
    }

    function test_capExhaustionDoesNotBackfillClippedTimeAfterOpeningPayment() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.balanceCeiling = o.terms.principal + o.interest;
        h.importOpening(1, o);
        assertEq(h.count(), 0);
        uint64 paidAt = CUT + 10 days;
        h.repay(1, 1_000e18, 0, paidAt);
        assertEq(h.loan(1).terms.periodStart, paidAt);
        assertEq(h.loan(1).frozenPikBasis, o.terms.principal);
        (uint256 principal, uint256 interest,) = h.face(1, paidAt + 1 days);
        assertEq(principal, o.terms.principal - 1_000e18);
        assertEq(interest, o.interest + 38_888_888e12);
    }

    function test_remainingCeilingAppliesOnlyToFutureIncome() public {
        AccrualLoans.Opening memory o = _opening(false);
        o.terms.balanceCeiling = o.terms.principal + o.interest + 100e18;
        h.importOpening(1, o);
        (uint256 principal, uint256 interest,) = h.face(1, CUT + 1 days);
        assertEq(principal, o.terms.principal);
        assertEq(interest, o.interest + 38_888_888e12);
        (, uint256 count, bool fresh) = h.checkpoint(CUT + 10 days);
        assertEq(count, 2, "binding cap must retain both exact technical endpoints");
        assertTrue(fresh);
        (principal, interest,) = h.face(1, CUT + 10 days);
        assertEq(principal, o.terms.principal);
        assertEq(interest, o.interest + 100e18);
        assertEq(h.snapshot(CUT + 10 days).gross, o.interest + 100e18);
    }

    function test_interestOnlyPikSchedulesTheBoundaryThatCreatesItsNextBasis() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.principal = 0;
        o.recordedFace = 0;
        h.importOpening(1, o);
        assertEq(h.count(), 1, "pending unpaid PIK must create the next positive basis on its signed date");
        (, uint256 count, bool fresh) = h.checkpoint(T + Q);
        assertEq(count, 1);
        assertTrue(fresh);
        (uint256 principal, uint256 interest,) = h.face(1, T + Q + 1 days);
        assertEq(principal, o.interest);
        assertEq(interest, 680_555e12);
    }

    function test_stoppedOpeningCannotRestartEvenWhenItsOldDueDatePrecedesTheCursor() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.permanentlyStopped = true;
        o.periodStart = CUT - 1;
        o.terms.nextPaymentDue = CUT - 2;
        h.importOpening(1, o);
        assertEq(h.loan(1).terms.periodEnd, o.terms.maturity);
        AccrualLoans.Amendment memory changed = AccrualLoans.Amendment({
            balanceCeiling: o.terms.balanceCeiling,
            yearSeconds: 360 days,
            rateBps: 1400,
            nextPaymentDue: CUT + Q,
            paymentInterval: Q,
            maturity: CUT + 365 days
        });
        vm.expectRevert(abi.encodeWithSelector(AccrualLoans.AccrualLoans_Inactive.selector, 1));
        h.amend(1, changed, CUT);
        assertEq(h.count(), 0);
        assertEq(h.snapshot(CUT + 365 days).gross, o.interest);
    }

    function test_openingRetainsAllAuthenticatedTermsAndCannotReuseARetiredIdentifier() public {
        AccrualLoans.Opening memory o = _opening(true);
        o.terms.frozenPikBasis = 123_456e18;
        h.importOpening(1, o);
        AccrualLoans.Loan memory loan = h.loan(1);
        assertTrue(loan.configured);
        assertTrue(loan.pik);
        assertTrue(loan.active);
        assertEq(loan.terms.basis, o.terms.frozenPikBasis);
        assertEq(loan.frozenPikBasis, o.terms.frozenPikBasis);
        assertEq(loan.terms.scale, o.terms.scale);
        assertEq(loan.terms.yearSeconds, o.terms.yearSeconds);
        assertEq(loan.terms.rateBps, o.terms.rateBps);
        assertEq(loan.terms.periodStart, o.periodStart);
        assertEq(loan.terms.periodEnd, o.terms.nextPaymentDue);
        assertEq(loan.terms.maturity, o.terms.maturity);
        assertEq(loan.balanceCeiling, o.terms.balanceCeiling);
        assertEq(loan.paymentInterval, o.terms.paymentInterval);
        assertEq(loan.nextCapitalization, o.terms.nextPaymentDue);
        assertEq(loan.legalMaturity, o.terms.maturity);
        assertEq(loan.lastSettlement, CUT);
        h.stop(1, CUT);
        h.repay(1, o.terms.principal + o.interest, 0, CUT);
        h.retire(1, CUT);
        assertEq(h.registered(), 0);
        vm.expectRevert(abi.encodeWithSelector(AccrualBook.AccrualBook_KnownFacility.selector, 1));
        h.importOpening(1, o);
    }

    function _assertEmpty(uint256 id) private view {
        assertFalse(h.loan(id).configured);
        assertEq(h.registered(), 0);
        assertEq(h.annualWork(), 0);
        assertEq(h.count(), 0);
        assertEq(h.snapshot(CUT).gross, 0);
    }

    /// @dev Computes integer entitlement directly from bounded products, independently of the importer.
    function testFuzz_openingPreservesFractionalEntitlementAcrossTheCut(
        uint96 basisSeed,
        uint16 rateSeed,
        uint32 cutSeed,
        uint32 laterSeed,
        bool pik,
        bool sixDecimals
    ) public {
        AccrualLoans.Opening memory o = _opening(pik);
        uint256 scale = sixDecimals ? 1e12 : 1;
        uint256 basis = (uint256(basisSeed) % 1e24 + 1) * scale;
        uint256 rate = uint256(rateSeed) % 10_001;
        uint64 cut = T + uint64(uint256(cutSeed) % (Q - 1)) + 1;
        uint64 later = cut + uint64(uint256(laterSeed) % (T + Q - cut + 1));
        uint256 divisor = 10_000 * 360 days;
        uint256 earnedBefore = basis * rate * (cut - T) / divisor / scale * scale;
        uint256 earnedLater = basis * rate * (later - T) / divisor / scale * scale;
        o.terms.principal = basis;
        o.recordedFace = basis;
        o.terms.balanceCeiling = basis * 3;
        o.terms.scale = scale;
        o.terms.rateBps = uint16(rate);
        o.terms.fundedAt = cut;
        o.interest = earnedBefore;
        AccrualOpeningHarness fresh = new AccrualOpeningHarness();
        fresh.initialize(cut);
        assertEq(fresh.importOpening(1, o), earnedBefore);
        (uint256 principal, uint256 interest,) = fresh.face(1, later);
        assertEq(principal, basis);
        assertEq(interest, earnedLater, "the cutoff discarded or duplicated fractional entitlement");
        assertEq(fresh.snapshot(cut).feeUnissued, earnedBefore / 10);
    }
}
