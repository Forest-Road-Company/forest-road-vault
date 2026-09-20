// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualCeiling} from "../../src/libraries/AccrualCeiling.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";

contract AccrualCeilingHarness {
    function ceiling(AccrualCeiling.Terms memory p) external pure returns (uint256) {
        return AccrualCeiling.pik(p);
    }
}

contract AccrualCeilingTest is Test {
    AccrualCeilingHarness private h = new AccrualCeilingHarness();

    function _terms() private pure returns (AccrualCeiling.Terms memory p) {
        p = AccrualCeiling.Terms({
            face: 100_000e18,
            frozenBasis: 100_000e18,
            scale: 1,
            yearSeconds: 360 days,
            rateBps: 6000,
            at: 1,
            nextCapitalization: 1 + 90 days,
            paymentInterval: 90 days,
            maturity: 1 + 730 days
        });
    }

    /// @dev Independent integer reference, retaining the first coupon's pre-cutoff fraction.
    function _reference(AccrualCeiling.Terms memory p, uint64 periodStart) private pure returns (uint256 face) {
        uint64 end = p.nextCapitalization == 0 ? p.maturity : p.nextCapitalization;
        uint256 denominator = 10_000 * p.yearSeconds;
        uint256 atEnd = p.frozenBasis * p.rateBps * (end - periodStart) / denominator / p.scale;
        uint256 before_ = p.frozenBasis * p.rateBps * (p.at - periodStart) / denominator / p.scale;
        face = p.face + (atEnd - before_) * p.scale;
        while (end < p.maturity) {
            uint64 elapsed = p.maturity - end;
            if (elapsed > p.paymentInterval) elapsed = p.paymentInterval;
            face += face * p.rateBps * elapsed / denominator / p.scale * p.scale;
            end += elapsed;
        }
    }

    function test_fullQuarterlyInterestFitsWithoutThreeTimesRestriction() public view {
        AccrualCeiling.Terms memory p = _terms();
        uint256 expected = _reference(p, p.at);
        assertEq(expected, 311000657691471354166666);
        uint256 upper = h.ceiling(p);
        assertGe(upper, expected);
        assertLt(upper - expected, 100);
    }

    function testFuzz_boundCoversIndependentCompoundingAndMigrationCarry(
        uint128 rawFace,
        uint32 rawInterval,
        uint16 rawCount,
        uint16 rawRate,
        uint64 seed
    ) public view {
        AccrualCeiling.Terms memory p = _terms();
        p.scale = seed & 1 == 0 ? 1 : 1e12;
        p.face = bound(rawFace, 1, 1e24) * p.scale;
        p.frozenBasis = p.face * (seed % 3);
        p.rateBps = uint16(bound(rawRate, 0, 10_000));
        p.yearSeconds = seed & 2 == 0 ? 360 days : 365 days;
        p.paymentInterval = uint64(bound(rawInterval, 1, 90 days));
        uint64 elapsed = uint64(seed % p.paymentInterval);
        p.at = 1 + elapsed;
        p.nextCapitalization = 1 + p.paymentInterval;
        uint64 count = uint64(bound(rawCount, 0, 32));
        p.maturity = p.nextCapitalization + count * p.paymentInterval + uint64(seed % p.paymentInterval);
        uint256 upper = h.ceiling(p);
        uint256 expected = _reference(p, 1);
        assertGe(upper, expected, "capacity must cover every earned unit");
        assertGe(upper, p.face);
    }

    function test_migrationRetainsOneNativeUnitOfRoundingCarry() public view {
        AccrualCeiling.Terms memory p = _terms();
        p.scale = 1e12;
        p.face = 360e12;
        p.frozenBasis = p.face;
        p.rateBps = 10_000;
        p.at = 1 days;
        p.nextCapitalization = 1 + 1 days;
        p.maturity = p.nextCapitalization;
        assertEq(_reference(p, 1), p.face + p.scale);
        assertEq(h.ceiling(p), p.face + p.scale);
    }

    function test_finalStubKeepsFrozenBasisAfterPrincipalRepayment() public view {
        AccrualCeiling.Terms memory p = _terms();
        p.face = 10_000e18;
        p.nextCapitalization = 0;
        p.maturity = p.at + 45 days;
        assertEq(h.ceiling(p), 17_500e18);
    }

    function test_secondlyScheduleHasBoundedCalculationCost() public view {
        AccrualCeiling.Terms memory p = _terms();
        p.rateBps = 10_000;
        p.paymentInterval = 1;
        p.nextCapitalization = p.at + 1;
        uint256 before_ = gasleft();
        uint256 upper = h.ceiling{gas: 100_000}(p);
        uint256 used = before_ - gasleft();
        assertGt(upper, 7 * p.face);
        assertLt(upper, 8 * p.face);
        assertLt(used, 100_000);
    }

    function test_zeroRateReservesOnlyPresentFace() public view {
        AccrualCeiling.Terms memory p = _terms();
        p.rateBps = 0;
        assertEq(h.ceiling(p), p.face);
    }

    function test_zeroFrozenBasisStillCompoundsPresentInterestAtFirstBoundary() public view {
        AccrualCeiling.Terms memory p = _terms();
        p.frozenBasis = 0;
        assertGe(h.ceiling(p), _reference(p, p.at));
        assertGt(h.ceiling(p), p.face);
    }

    function test_factorRoundingCoversLargeRepresentableDebt() public view {
        AccrualCeiling.Terms memory p = _terms();
        p.face = 1e60;
        p.frozenBasis = p.face;
        p.rateBps = 1;
        p.paymentInterval = 1;
        p.nextCapitalization = p.at + 1;
        p.maturity = p.at + 2;
        assertGe(h.ceiling(p), _reference(p, p.at));
    }

    function test_largeFirstCouponAndTailRefuseBeforeArithmeticOverflow() public {
        AccrualCeiling.Terms memory p = _terms();
        p.face = 1;
        p.frozenBasis = AccrualCeiling.MAX_FACE;
        p.rateBps = 10_000;
        p.nextCapitalization = type(uint64).max;
        p.maturity = p.nextCapitalization;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
        p.nextCapitalization = p.at + 720 days;
        p.maturity = p.nextCapitalization;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
        p = _terms();
        p.face = AccrualCeiling.MAX_FACE;
        p.frozenBasis = 0;
        p.maturity = p.nextCapitalization + 1 days;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
    }

    function test_roundingCannotOverflowTheCapacityBoundary() public {
        AccrualCeiling.Terms memory p = _terms();
        p.face = AccrualCeiling.MAX_FACE * 20 / 23 + 1;
        p.frozenBasis = 0;
        p.maturity = p.nextCapitalization + p.paymentInterval;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
    }

    function test_invalidScheduleRefusesWithNamedError() public {
        AccrualCeiling.Terms memory p = _terms();
        p.paymentInterval = 0;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_InvalidSchedule.selector);
        h.ceiling(p);
        p = _terms();
        p.nextCapitalization = p.at;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_InvalidSchedule.selector);
        h.ceiling(p);
        p = _terms();
        p.nextCapitalization = p.maturity + 1;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_InvalidSchedule.selector);
        h.ceiling(p);
    }

    function test_capacityAndMathAdmissionRefuseWithNamedErrors() public {
        AccrualCeiling.Terms memory p = _terms();
        p.face = AccrualCeiling.MAX_FACE + 1;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
        p = _terms();
        p.face = AccrualCeiling.MAX_FACE;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
        p = _terms();
        p.frozenBasis = AccrualCeiling.MAX_FACE + 1;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_BasisTooLarge.selector, p.frozenBasis));
        h.ceiling(p);
        p = _terms();
        p.rateBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, p.rateBps));
        h.ceiling(p);
        p = _terms();
        p.yearSeconds = 1;
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_UnsupportedYear.selector, p.yearSeconds));
        h.ceiling(p);
        p = _terms();
        p.scale = 0;
        vm.expectRevert(AccrualMath.AccrualMath_ZeroScale.selector);
        h.ceiling(p);
        p.scale = type(uint256).max;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
    }

    function test_unrepresentableLongScheduleRefusesRatherThanClipping() public {
        AccrualCeiling.Terms memory p = _terms();
        p.rateBps = 10_000;
        p.maturity = type(uint64).max;
        vm.expectRevert(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector);
        h.ceiling(p);
    }
}
