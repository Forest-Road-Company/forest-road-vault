// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";

/// @notice Full legacy repayments cannot close a loan while a payable PIK coupon remains unrecorded.
contract LegacyPikPayoffTest is CreditLayerFixture {
    uint256 private constant P = 1_000_000e18;
    uint256 private id;
    uint64 private firstDue;

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        id = _liveFilmFacility(P);
        firstDue = bridge.facility(id).nextPaymentDue;
    }

    function _refuseFullPayoff(uint64 due) private {
        uint256 face = reserves.deployedTo(id);
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, face);
        uint256 backing = reserves.totalBackingValue();
        uint256 supply = usdfr.totalSupply();
        (uint64 cursor,) = waterfall.pikCursorOf(id);
        vm.expectRevert(abi.encodeWithSignature("Waterfall_PikSettlementRequired(uint256,uint64)", id, due));
        vm.prank(servicer);
        waterfall.distribute(payment);
        assertEq(reserves.deployedTo(id), face, "refused payoff changed debt");
        assertEq(reserves.totalBackingValue(), backing, "refused payoff moved backing");
        assertEq(usdfr.totalSupply(), supply, "refused payoff changed supply");
        (uint64 cursorAfter,) = waterfall.pikCursorOf(id);
        assertEq(cursorAfter, cursor, "refused payoff moved the coupon cursor");
        (,, bool satisfied) = oracle.latestPayload(id, IAttestationOracle.AttestationKind.PaymentReceived);
        assertTrue(satisfied, "refused payoff consumed its attestation");
    }

    function test_elapsedCouponMustBeRecordedBeforeFullPayoff() public {
        vm.warp(firstDue);
        _refuseFullPayoff(firstDue);
        uint256 coupon = waterfall.capitalizePik(id);
        assertGt(coupon, 0);
        _repay(id, 0, P + coupon);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid));
    }

    /// @notice An independent fixed-period arithmetic model prices every coupon in a backlog.
    function testFuzz_everyElapsedCouponSurvivesAPayoffAttempt(uint8 countSeed) public {
        uint256 count = bound(countSeed, 1, 12);
        uint64 interval = bridge.facility(id).paymentInterval;
        vm.warp(uint256(firstDue) + (count - 1) * interval);
        uint256 expected = P;
        uint256 scale = _scale();
        uint256 earned;
        for (uint256 i; i < count; ++i) {
            _refuseFullPayoff(firstDue + uint64(i) * interval);
            uint256 coupon = expected * 1400 * interval / (10_000 * 360 days) / scale * scale;
            assertEq(waterfall.capitalizePik(id), coupon, "coupon differs from independent reference");
            expected += coupon;
            earned += coupon;
            assertEq(reserves.deployedTo(id), expected);
        }
        assertEq(waterfall.pikCapitalisedTotalOf(id), earned);
        _repay(id, 0, expected);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid));
    }

    function test_noElapsedCouponAllowsFullPayoff() public {
        vm.warp(firstDue - 1);
        _repay(id, 0, P);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid));
    }

    function test_partialRepaymentCannotMakeTheFinalPayoffDropABacklog() public {
        vm.warp(uint256(firstDue) + 60 days);
        _repay(id, 0, P * 9 / 10);
        assertEq(reserves.deployedTo(id), P / 10);
        _refuseFullPayoff(firstDue);
    }

    function test_aDeclaredDefaultStillAcceptsItsRecordedRecovery() public {
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.warp(uint256(firstDue) + 60 days);
        _repay(id, 0, P);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved));
    }

    /// @notice Explicit cursor controls cover defensive refusals and the exact asset-grid boundary.
    function test_cursorAndPayableCouponBoundaries() public {
        uint64 interval = bridge.facility(id).paymentInterval;
        uint64 anchor = firstDue - interval;
        uint256 minimumBasis = (_scale() * 600 + 6) / 7;
        for (uint256 mode; mode < 9; ++mode) {
            uint256 snap = vm.snapshotState();
            vm.warp(firstDue);
            uint64 lastAt = mode == 0 ? 0 : anchor;
            uint64 period = mode == 1 ? 0 : interval;
            uint64 funded = mode == 2 ? firstDue : (mode == 8 ? firstDue - 1 : anchor);
            uint16 rate = mode == 4 ? 0 : 1400;
            uint176 basis = uint176(mode >= 5 ? minimumBasis - (mode == 5 ? 1 : 0) : P);
            if (mode == 3) {
                lastAt = firstDue + 390 days;
                vm.warp(uint256(lastAt) + interval);
            }
            if (mode == 7) rate = 10_001;
            _cursor(lastAt, rate, basis, period, funded);
            IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, P);
            if (mode < 3) {
                vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotFunded.selector, id));
            } else if (mode == 6) {
                vm.expectRevert(
                    abi.encodeWithSignature("Waterfall_PikSettlementRequired(uint256,uint64)", id, firstDue)
                );
            } else if (mode == 7) {
                vm.expectRevert(abi.encodeWithSignature("AccrualMath_RateTooLarge(uint16)", uint16(10_001)));
            }
            vm.prank(servicer);
            waterfall.distribute(payment);
            bool refused = mode < 3 || mode == 6 || mode == 7;
            assertEq(reserves.deployedTo(id), refused ? P : 0);
            assertEq(
                uint256(bridge.facility(id).state),
                uint256(refused ? ClaimBridge.LoanState.Active : ClaimBridge.LoanState.Repaid)
            );
            assertTrue(vm.revertToStateAndDelete(snap));
        }
    }

    /// @notice Malformed legacy inputs refuse before a cursor or any accounting balance changes.
    function test_legacyPlannerRefusalsPreserveDebtAndCursor() public {
        for (uint256 mode; mode < 8; ++mode) {
            uint256 snap = vm.snapshotState();
            ClaimBridge.Facility memory f = bridge.facility(id);
            uint64 anchor = firstDue - f.paymentInterval;
            bytes memory refusal;
            if (mode == 0) {
                f.pik = false;
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotDesignated.selector, id);
            } else if (mode == 1) {
                ICollateralRegistry.ClassParams memory params = registry.classParams(f.classId);
                params.model = ICollateralRegistry.CollateralModel.MarkedToMarket;
                vm.mockCall(
                    address(registry), abi.encodeCall(ICollateralRegistry.classParams, (f.classId)), abi.encode(params)
                );
                assertEq(uint256(registry.classParams(f.classId).model), uint256(params.model));
                refusal =
                    abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikClassNotReceivable.selector, id, f.classId);
            } else if (mode == 2) {
                f.rateType = ClaimBridge.RateType.Variable;
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikRateTypeUnsupported.selector, id);
            } else if (mode == 3) {
                f.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikDayCountUnsupported.selector, id);
            } else if (mode == 4) {
                _cursor(anchor, 1400, uint176(P), 0, anchor);
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotFunded.selector, id);
            } else if (mode == 5) {
                vm.mockCall(
                    address(reserves), abi.encodeWithSignature("deployedTo(uint256)", id), abi.encode(uint256(0))
                );
                assertEq(reserves.deployedTo(id), 0);
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNothingOutstanding.selector, id);
            } else if (mode == 6) {
                _cursor(anchor, 1400, uint176(P), f.paymentInterval, firstDue);
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotFunded.selector, id);
            } else {
                _cursor(anchor, 1400, 0, f.paymentInterval, anchor);
                refusal = abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikBelowScaleGrid.selector, id, _scale());
            }
            vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.facility, (id)), abi.encode(f));
            assertEq(
                keccak256(abi.encode(bridge.facility(id))), keccak256(abi.encode(f)), "facility control did not apply"
            );
            vm.warp(firstDue);
            bytes32 cursorBefore = _cursorHash();
            uint256 backingBefore = reserves.totalBackingValue();
            uint256 supplyBefore = usdfr.totalSupply();
            vm.expectRevert(refusal);
            waterfall.capitalizePik(id);
            vm.clearMockedCalls();
            assertEq(reserves.deployedTo(id), P, "refused planner changed physical debt");
            assertEq(reserves.totalBackingValue(), backingBefore);
            assertEq(usdfr.totalSupply(), supplyBefore);
            assertEq(waterfall.pikCapitalisedTotalOf(id), 0);
            assertEq(_cursorHash(), cursorBefore, "refused planner changed its cursor");
            assertTrue(vm.revertToStateAndDelete(snap));
        }
    }

    function _cursorHash() private view returns (bytes32) {
        bytes32 root = 0xcf0c34fc0be88a30eafd83d03dde401c38c60299c8a6f87d9915e05fa29cdd00;
        bytes32 slot = keccak256(abi.encode(id, uint256(root) + 9));
        return keccak256(
            abi.encode(vm.load(address(waterfall), slot), vm.load(address(waterfall), bytes32(uint256(slot) + 1)))
        );
    }

    function _cursor(uint64 lastAt, uint16 rate, uint176 basis, uint64 interval, uint64 funded) private {
        bytes32 root = 0xcf0c34fc0be88a30eafd83d03dde401c38c60299c8a6f87d9915e05fa29cdd00;
        bytes32 slot = keccak256(abi.encode(id, uint256(root) + 9));
        bytes32 first = bytes32(uint256(lastAt) | uint256(rate) << 64 | uint256(basis) << 80);
        bytes32 second = bytes32(uint256(interval) | uint256(funded) << 64);
        vm.store(address(waterfall), slot, first);
        vm.store(address(waterfall), bytes32(uint256(slot) + 1), second);
        assertEq(vm.load(address(waterfall), slot), first, "first cursor control did not apply");
        assertEq(vm.load(address(waterfall), bytes32(uint256(slot) + 1)), second, "second cursor control did not apply");
        (uint64 actualAt, uint16 actualRate) = waterfall.pikCursorOf(id);
        assertEq(actualAt, lastAt);
        assertEq(actualRate, rate);
    }

    function _scale() private pure returns (uint256) {
        return 1e12;
    }
}
