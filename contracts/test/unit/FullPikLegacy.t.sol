// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockAttestationOracle} from "../helpers/MockAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Independent full-interest reference and numerical refusal checks for legacy PIK servicing.
contract FullPikLegacyTest is CreditLayerFixture {
    uint256 private constant P = 1_000_000e18;
    uint256 private constant SCALE = 1e12;
    bytes32 private constant BORROWER = keccak256("legacy-full-interest-borrower");
    bytes32 private constant STATE = keccak256("legacy-full-interest-state");
    bytes32 private constant RESERVE_ROOT = 0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;
    bytes32 private constant WATERFALL_ROOT = 0xcf0c34fc0be88a30eafd83d03dde401c38c60299c8a6f87d9915e05fa29cdd00;
    uint256 private id;

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        _mintUSDfrTo(alice, 10_000_000e18);
        id = _originateFilm(BORROWER, STATE, P);
        _fundFacility(id, P);
    }

    function _amend(uint16 rate) private {
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 maturity =
            f.renewable ? uint64(block.timestamp) + uint64(registry.classParams(f.classId).maxMaturity) - 1 : f.maturity;
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: rate,
            maturity: maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: uint64(block.timestamp) + f.paymentInterval,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: true,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: keccak256("full-interest-renewal")
        });
        bytes32 amendment = keccak256(abi.encode("full-interest-amendment", block.timestamp, maturity, rate));
        MockAttestationOracle(address(oracle)).setPayload(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendment, id, a)),
            uint64(block.timestamp),
            true
        );
        vm.prank(originator);
        bridge.amendTerms(id, amendment, a);
    }

    function _coupon(uint256 frozenBasis, uint16 rate) private pure returns (uint256) {
        return frozenBasis * rate / 120_000 / SCALE * SCALE;
    }

    /// @notice A separate model follows 36 coupons, prospective rate changes and partial repayments.
    function testFuzz_legacyEventHistoryRecordsEverySignedCoupon(uint256 seed) public {
        _amend(10_000);
        _amend(10_000);
        uint256 expected = P;
        uint256 earned;
        uint16 periodRate = 1400;
        for (uint256 i; i < 36; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint16 nextRate = uint16(5000 + seed % 5001);
            _amend(nextRate);
            uint256 frozenBasis = expected;
            if (seed % 8 == 0) {
                uint256 repayment = expected / 100 / SCALE * SCALE;
                _repay(id, 0, repayment);
                expected -= repayment;
            }
            uint256 coupon = _coupon(frozenBasis, periodRate);
            vm.warp(block.timestamp + 30 days);
            assertEq(waterfall.capitalizePik(id), coupon, "full signed coupon differs from independent model");
            expected += coupon;
            earned += coupon;
            periodRate = nextRate;
            assertEq(reserves.deployedTo(id), expected);
            assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), expected);
            assertEq(waterfall.pikCapitalisedTotalOf(id), earned);
            assertLe(usdfr.totalSupply(), reserves.totalBackingValue());
        }
    }

    function test_legacyFullPikPaysBothConfiguredFees() public {
        vm.startPrank(admin);
        waterfall.setProtocolFee(1000);
        vault.setManagementFee(0);
        vault.setPerformanceFee(1000);
        vm.stopPrank();
        vm.startPrank(alice);
        usdfr.approve(address(vault), 5_000_000e18);
        vault.deposit(5_000_000e18, alice);
        vm.stopPrank();
        _amend(10_000);
        _amend(10_000);
        uint256 expected = P;
        uint256 fees;
        uint256 protocolBefore = usdfr.balanceOf(feeRecipient);
        uint256 performanceBefore = vault.balanceOf(feeRecipient);
        uint256 assetsBefore = vault.totalAssets();
        for (uint256 i; i < 20; ++i) {
            vm.warp(block.timestamp + 30 days);
            uint256 coupon = _coupon(expected, i == 0 ? 1400 : 10_000);
            assertEq(waterfall.capitalizePik(id), coupon);
            expected += coupon;
            fees += coupon / 10;
        }
        assertGt(expected, 3 * P);
        assertEq(reserves.deployedTo(id), expected);
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, fees);
        assertEq(vault.totalAssets(), assetsBefore + expected - P - fees);
        assertGt(vault.balanceOf(feeRecipient), performanceBefore);
        assertEq(vault.managementFeeBps(), 0);
    }

    function _face(uint256 amount) private {
        vm.store(address(reserves), keccak256(abi.encode(id, uint256(RESERVE_ROOT) + 3)), bytes32(amount));
        assertEq(reserves.deployedTo(id), amount, "reserve storage control did not apply");
    }

    function _basis(uint176 value, uint16 rate) private {
        bytes32 slot = keccak256(abi.encode(id, uint256(WATERFALL_ROOT) + 9));
        uint256 lastAt = uint256(vm.load(address(waterfall), slot)) & type(uint64).max;
        vm.store(address(waterfall), slot, bytes32(lastAt | uint256(rate) << 64 | uint256(value) << 80));
        (, uint16 actualRate) = waterfall.pikCursorOf(id);
        uint176 actualBasis = uint176(uint256(vm.load(address(waterfall), slot)) >> 80);
        assertEq(actualBasis, value, "basis control did not apply");
        assertEq(actualRate, rate, "rate control did not apply");
    }

    function test_legacyNumericRefusalsPreserveState() public {
        uint256 maxExposure = type(uint256).max / 10_000;
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            if (i == 0) _face(maxExposure + 1);
            else if (i == 1) _face(maxExposure - _coupon(P, 1400) + SCALE);
            else if (i == 2) _face(type(uint176).max);
            else _basis(type(uint176).max, 1400);
            // Keep a backlog for the exposure-domain cases so the separate next-basis guard cannot mask them.
            vm.warp(block.timestamp + (i == 2 ? 30 days : 60 days));
            uint256 faceBefore = reserves.deployedTo(id);
            vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikExposureCapacity.selector, id));
            waterfall.planPik(id);
            vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikExposureCapacity.selector, id));
            waterfall.capitalizePik(id);
            assertEq(reserves.deployedTo(id), faceBefore);
            assertEq(waterfall.pikCapitalisedTotalOf(id), 0);
            assertTrue(vm.revertToStateAndDelete(snap));
        }
    }

    function test_legacyCursorRateValidationRefusesExplicitly() public {
        _basis(uint176(P), 10_001);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(AccrualMath.AccrualMath_RateTooLarge.selector, uint16(10_001)));
        waterfall.planPik(id);
    }

    function test_legacyFundingRefusesAnUnrepresentableCursorBeforeValueMoves() public {
        uint256 pending = _originateFilm(keccak256("cursor-capacity-pending"), STATE, P);
        ClaimBridge.Facility memory f = bridge.facility(pending);
        f.principal = (uint256(type(uint176).max) / SCALE + 1) * SCALE;
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.facility, (pending)), abi.encode(f));
        uint256 deployedBefore = reserves.deployedPrincipal();
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikExposureCapacity.selector, pending));
        vm.prank(servicer);
        waterfall.fund(pending, f.principal / SCALE);
        assertEq(reserves.deployedPrincipal(), deployedBefore);
        vm.clearMockedCalls();
    }
}
