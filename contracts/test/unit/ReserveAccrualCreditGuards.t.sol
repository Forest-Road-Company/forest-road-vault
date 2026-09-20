// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {AccrualCeiling} from "../../src/libraries/AccrualCeiling.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReserveCreditHostHarness,
    ReserveCreditBridgeFixture,
    ReserveCreditRegistryFixture,
    ReserveCreditRiskFixture
} from "./ReserveAccrualCredit.t.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @dev Owner-only invalid-state seeders isolate defensive adapter checks from upstream validation.
contract ReserveCreditGuardHost is ReserveCreditHostHarness {
    address private immutable GUARD_OWNER = msg.sender;

    modifier onlyGuardOwner() {
        require(msg.sender == GUARD_OWNER, "fixture owner");
        _;
    }

    /// @dev Test-only pointer to the independently pinned native proxy slot.
    function _native() private pure returns (ReserveManager.ReserveStorage storage n) {
        bytes32 slot = 0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;
        assembly ("memory-safe") {
            n.slot := slot
        }
    }

    function fixtureEnabled(bool enabled) external onlyGuardOwner {
        ReserveAccrualStorageLib.state().enabled = enabled;
    }

    function fixtureNative(uint256 id, address asset, uint256 principal) external onlyGuardOwner {
        ReserveManager.ReserveStorage storage n = _native();
        n.totalDeployedPrincipal = n.totalDeployedPrincipal - n.deployed[id] + principal;
        n.deployed[id] = principal;
        n.usdcToken = IERC20(asset);
    }

    function fixtureReservation(uint256 reserved) external onlyGuardOwner {
        ReserveAccrualStorageLib.state().reservedCeilings = reserved;
    }

    function fixtureDebt(uint256 id, uint256 interest, uint256 scale) external onlyGuardOwner {
        AccrualLoans.Loan storage loan = ReserveAccrualStorageLib.state().loans.loans[id];
        loan.unpaidInterest = interest;
        loan.terms.scale = scale;
    }

    function fixtureDigest(uint256 id) external view returns (bytes32) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        return keccak256(
            abi.encode(
                s.identities[id],
                s.loans.loans[id],
                s.reservedCeilings,
                s.recordedFace,
                s.enabled,
                s.busy,
                s.loans.book.total,
                s.loans.book.registered,
                s.loans.book.posted,
                s.loans.book.seniorIssued,
                s.loans.book.feeIssued
            )
        );
    }
}

contract ReserveAccrualCreditGuardsTest is Test {
    ReserveCreditGuardHost private reserve;
    ReserveCreditBridgeFixture private bridge;
    ReserveCreditRegistryFixture private registry;
    ReserveCreditRiskFixture private risk;
    MockERC20 private asset;
    uint64 private start;
    uint256 private constant PRINCIPAL = 1000e18;
    uint256 private constant SCALE = 1e12;
    uint256 private constant LIMIT = type(uint256).max / 10_000;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = uint64(block.timestamp);
        asset = new MockERC20("Credit guard fixture", "CGF", 6);
        reserve = new ReserveCreditGuardHost();
        bridge = new ReserveCreditBridgeFixture();
        registry = new ReserveCreditRegistryFixture();
        risk = new ReserveCreditRiskFixture();
        bridge.configure(reserve);
        registry.configure(reserve);
        risk.configure(reserve);
        reserve.seed(
            IContinuousAccrual.Modules(
                address(this),
                address(this),
                address(this),
                address(this),
                address(bridge),
                address(registry),
                address(risk)
            ),
            address(asset)
        );
    }

    function _terms(bool pik) private view returns (ClaimBridge.Facility memory f) {
        f.classId = 1;
        f.borrowerId = keccak256("credit guard borrower");
        f.stateId = keccak256("credit guard state");
        f.principal = PRINCIPAL;
        f.interestRateBps = 1000;
        f.maturity = start + 360 days;
        f.paymentInterval = 90 days;
        f.nextPaymentDue = start + 90 days;
        f.rateType = ClaimBridge.RateType.Fixed;
        f.dayCountConvention = ClaimBridge.DayCountConvention.Actual360;
        f.state = ClaimBridge.LoanState.Active;
        f.pik = pik;
    }

    function _seed(uint256 id, ClaimBridge.Facility memory f) private {
        bridge.setLoan(id, f);
        registry.seed(f);
        reserve.seedFunded(id, f.principal);
    }

    function _fund(uint256 id, bool pik) private {
        _seed(id, _terms(pik));
        reserve.registerAccruingLoan(id);
    }

    function _expectRegistration(bytes memory reason) private {
        bytes32 before_ = reserve.fixtureDigest(1);
        uint256 face = reserve.rawFace(1);
        vm.expectRevert(reason);
        reserve.registerAccruingLoan(1);
        assertEq(reserve.fixtureDigest(1), before_);
        assertEq(reserve.rawFace(1), face);
        assertFalse(reserve.accruedDebt(1).known);
    }

    function test_registrationRefusesInactiveMissingAssetOrMismatchedNativeFace() public {
        ClaimBridge.Facility memory f = _terms(false);
        _seed(1, f);
        bytes memory reason = abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_InvalidFunding.selector, 1);
        f.state = ClaimBridge.LoanState.Pending;
        bridge.setLoan(1, f);
        _expectRegistration(reason);
        f.state = ClaimBridge.LoanState.Active;
        bridge.setLoan(1, f);
        reserve.fixtureNative(1, address(0), PRINCIPAL);
        _expectRegistration(reason);
        reserve.fixtureNative(1, address(asset), PRINCIPAL + 1);
        _expectRegistration(reason);
        reserve.fixtureNative(1, address(asset), PRINCIPAL);
        reserve.registerAccruingLoan(1);
        assertTrue(reserve.accruedDebt(1).known);
    }

    function test_numericCeilingsRefuseBeforeRegistrationAndPreserveTheBoundary() public {
        bytes memory reason = abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_ExposureCapacity.selector);
        for (uint8 mode; mode < 3; ++mode) {
            uint256 saved = vm.snapshotState();
            ClaimBridge.Facility memory f = _terms(mode == 0);
            f.principal = mode == 1 ? LIMIT + 1 : LIMIT;
            _seed(1, f);
            // Isolate the numeric guard from a second refusal in portfolio admission.
            vm.mockCall(address(registry), abi.encodeWithSignature("totalBookExposure()"), abi.encode(uint256(0)));
            _expectRegistration(
                mode == 0 ? abi.encodeWithSelector(AccrualCeiling.AccrualCeiling_ExposureCapacity.selector) : reason
            );
            vm.clearMockedCalls();
            assertTrue(vm.revertToStateAndDelete(saved));
        }
        ClaimBridge.Facility memory boundary = _terms(false);
        boundary.principal = LIMIT - LIMIT % SCALE;
        boundary.interestRateBps = 0;
        _seed(1, boundary);
        reserve.registerAccruingLoan(1);
        assertEq(reserve.accruedDebt(1).balanceCeiling, boundary.principal);
        assertEq(reserve.accrualReservedExposure(), 0);
    }

    function test_portfolioAdmissionIncludesPresentAndAlreadyReservedExposure() public {
        _seed(1, _terms(false));
        bytes memory reason = abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_ExposureCapacity.selector);
        vm.mockCall(address(registry), abi.encodeWithSignature("totalBookExposure()"), abi.encode(LIMIT + 1));
        _expectRegistration(reason);
        vm.clearMockedCalls();
        reserve.fixtureReservation(LIMIT);
        _expectRegistration(reason);
        reserve.fixtureReservation(0);
        vm.mockCall(address(registry), abi.encodeWithSignature("totalBookExposure()"), abi.encode(LIMIT));
        _expectRegistration(reason);
        vm.clearMockedCalls();
        reserve.registerAccruingLoan(1);
        assertEq(reserve.accrualReservedExposure(), 100e18);
    }

    function test_cashMaturityMustBeInTheFutureAndExistingInterestMustFit() public {
        ClaimBridge.Facility memory f = _terms(false);
        _seed(1, f);
        for (uint64 offset; offset < 2; ++offset) {
            f.maturity = start - offset;
            bridge.setLoan(1, f);
            _expectRegistration(abi.encodeWithSelector(AccrualLoans.AccrualLoans_InvalidSchedule.selector));
        }
        f.maturity = start + 360 days;
        bridge.setLoan(1, f);
        reserve.registerAccruingLoan(1);
        reserve.fixtureDebt(1, LIMIT, SCALE);
        bytes32 before_ = reserve.fixtureDigest(1);
        vm.expectRevert(ReserveAccrualCreditLib.AccrualCredit_ExposureCapacity.selector);
        bridge.amend(1, IAccrualLifecycle.Terms(1000, uint32(360 days), start + 90 days, 90 days, f.maturity));
        assertEq(reserve.fixtureDigest(1), before_);
        reserve.fixtureDebt(1, 0, SCALE);
        bridge.amend(1, IAccrualLifecycle.Terms(1000, uint32(360 days), start + 90 days, 90 days, f.maturity));
        assertEq(reserve.accruedDebt(1).balanceCeiling, 1100e18);
    }

    function test_amendmentDayCountCannotChangeTheSupportedContractDomain() public {
        _fund(1, false);
        _fund(2, true);
        for (uint256 id = 1; id <= 2; ++id) {
            bytes32 before_ = reserve.fixtureDigest(id);
            uint32 year = uint32(id == 1 ? 359 days : 365 days);
            vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_UnsupportedTerms.selector, id));
            bridge.amend(id, IAccrualLifecycle.Terms(1000, year, start + 90 days, 90 days, start + 360 days));
            assertEq(reserve.fixtureDigest(id), before_);
        }
        bridge.amend(1, IAccrualLifecycle.Terms(1000, uint32(365 days), start + 90 days, 90 days, start + 365 days));
        assertEq(reserve.accruedDebt(1).balanceCeiling, 1100e18);
    }

    function test_receiptChecksBothNativeUnitConversionAndRemainingFace() public {
        _fund(1, false);
        for (uint8 mode; mode < 2; ++mode) {
            uint256 saved = vm.snapshotState();
            uint256 payment = 100e18;
            uint256 units = mode == 0 ? payment : payment / SCALE;
            if (mode == 0) reserve.fixtureDebt(1, 0, 1);
            else reserve.fixtureNative(1, address(asset), PRINCIPAL + 1);
            asset.mint(address(this), units);
            asset.approve(address(reserve), units);
            bytes32 before_ = reserve.fixtureDigest(1);
            uint256 face = reserve.rawFace(1);
            vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_ReceiptMismatch.selector, 1));
            reserve.repayAccruingLoan(1, address(this), payment, 0);
            assertEq(reserve.fixtureDigest(1), before_);
            assertEq(reserve.rawFace(1), face);
            assertEq(asset.balanceOf(address(this)), units);
            assertEq(asset.balanceOf(address(reserve)), 0);
            assertEq(asset.allowance(address(this), address(reserve)), units);
            assertEq(registry.rawTotal(), PRINCIPAL);
            assertTrue(vm.revertToStateAndDelete(saved));
        }
        asset.mint(address(this), 100e6);
        asset.approve(address(reserve), 100e6);
        assertEq(reserve.repayAccruingLoan(1, address(this), 100e18, 0), 900e18);
        assertEq(asset.balanceOf(address(reserve)), 100e6);
        assertEq(reserve.accruedDebt(1).principal, 900e18);
    }

    function test_retirementRequiresOneOfTheTwoBoundModules() public {
        _fund(1, false);
        address caller = address(0x123);
        bytes32 before_ = reserve.fixtureDigest(1);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, address(this), caller)
        );
        reserve.retireAccruedLoan(1);
        assertEq(reserve.fixtureDigest(1), before_);
    }

    function test_disabledMaintenanceAndInvalidExposureKindsRefuseExplicitly() public {
        reserve.fixtureEnabled(false);
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotEnabled.selector);
        reserve.checkpointAccrual(32);
        for (uint8 kind = 4; kind <= 5; ++kind) {
            uint8 invalid = kind == 4 ? 4 : type(uint8).max;
            vm.expectRevert(
                abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_InvalidExposureKind.selector, invalid)
            );
            reserve.accrualExposure(invalid, bytes32(0));
        }
        reserve.fixtureEnabled(true);
        (uint256 processed, bool fresh) = reserve.checkpointAccrual(32);
        assertEq(processed, 0);
        assertTrue(fresh);
    }

    /// @dev Direct bounded integer arithmetic supplies the reference, including native-unit rounding.
    function testFuzz_cashFundingAndAmendmentCeilingsMatchIndependentArithmetic(
        uint128 principalSeed,
        uint16 rateSeed,
        uint32 durationSeed,
        bool actual365
    ) public {
        ClaimBridge.Facility memory f = _terms(false);
        f.principal = (uint256(principalSeed) % 1e30 + 1) * SCALE;
        f.interestRateBps = uint16(uint256(rateSeed) % 10_001);
        uint256 duration = 90 days + uint256(durationSeed) % (10 * 365 days);
        f.maturity = start + uint64(duration);
        f.dayCountConvention =
            actual365 ? ClaimBridge.DayCountConvention.Actual365 : ClaimBridge.DayCountConvention.Actual360;
        uint32 year = uint32(actual365 ? 365 days : 360 days);
        uint256 expectedInterest = f.principal * f.interestRateBps * duration / (uint256(year) * 10_000 * SCALE) * SCALE;
        _seed(1, f);
        reserve.registerAccruingLoan(1);
        assertEq(reserve.accruedDebt(1).balanceCeiling, f.principal + expectedInterest);
        assertEq(reserve.accrualReservedExposure(), expectedInterest);
        assertEq(reserve.accrualSnapshot().gross, 0);
        uint16 newRate = uint16((uint256(f.interestRateBps) + 137) % 10_001);
        duration += 1 days;
        expectedInterest = f.principal * newRate * duration / (uint256(year) * 10_000 * SCALE) * SCALE;
        bridge.amend(
            1, IAccrualLifecycle.Terms(newRate, year, f.nextPaymentDue, f.paymentInterval, start + uint64(duration))
        );
        assertEq(reserve.accruedDebt(1).balanceCeiling, f.principal + expectedInterest);
        assertEq(reserve.accrualReservedExposure(), expectedInterest);
        assertEq(reserve.accrualSnapshot().gross, 0);
        assertEq(reserve.rawFace(1), f.principal);
    }
}
