// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {ReserveAccrualServiceLib} from "../../src/libraries/ReserveAccrualServiceLib.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {
    ReserveCreditHostHarness,
    ReserveCreditBridgeFixture,
    ReserveCreditRegistryFixture,
    ReserveCreditRiskFixture
} from "./ReserveAccrualCredit.t.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @dev Owner-only invalid-state controls test defensive checks; normal funding uses the real adapter.
contract ReserveServiceHostHarness is ReserveCreditHostHarness {
    address private immutable SERVICE_OWNER = msg.sender;

    function fixtureEnabled(bool enabled) external {
        require(msg.sender == SERVICE_OWNER, "fixture owner");
        ReserveAccrualStorageLib.state().enabled = enabled;
    }

    function fixtureCeiling(uint256 id, uint256 ceiling) external {
        require(msg.sender == SERVICE_OWNER, "fixture owner");
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.reservedCeilings = s.reservedCeilings - s.identities[id].reservedCeiling + ceiling;
        s.identities[id].reservedCeiling = ceiling;
    }

    function fixtureState(uint256 id) external view returns (uint256 ceiling, uint256 total, uint64 due, bool active) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        return (
            s.identities[id].reservedCeiling,
            s.reservedCeilings,
            s.loans.loans[id].nextCapitalization,
            s.loans.loans[id].active
        );
    }
}

contract ReserveAccrualServiceTest is Test {
    ReserveServiceHostHarness private reserve;
    ReserveCreditBridgeFixture private bridge;
    ReserveCreditRegistryFixture private registry;
    ReserveCreditRiskFixture private risk;
    address private asset;
    uint64 private start;
    uint256 private constant SCALE = 1e12;

    event AccrualBoundaryProcessed(
        uint256 indexed facilityId, uint64 indexed at, uint256 capitalized, uint64 nextDue, bool stopped
    );
    event AccrualCeilingReserved(uint256 indexed facilityId, uint256 previousCeiling, uint256 nextCeiling);

    function setUp() public {
        vm.warp(1_800_000_000);
        start = uint64(block.timestamp);
        asset = address(new MockERC20("Service fixture", "SVC", 6));
        reserve = new ReserveServiceHostHarness();
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
            asset
        );
    }

    function _fund(uint256 id, uint256 principal, uint16 rate, bool pik) private {
        ClaimBridge.Facility memory f;
        f.classId = 1;
        f.borrowerId = keccak256(abi.encode("service borrower", id));
        f.stateId = keccak256("service jurisdiction");
        f.principal = principal;
        f.interestRateBps = rate;
        f.maturity = start + 365 days;
        f.nextPaymentDue = start + 90 days;
        f.paymentInterval = 90 days;
        f.rateType = ClaimBridge.RateType.Fixed;
        f.dayCountConvention = ClaimBridge.DayCountConvention.Actual360;
        f.pik = pik;
        f.state = ClaimBridge.LoanState.Active;
        bridge.setLoan(id, f);
        registry.seed(f);
        reserve.seedFunded(id, principal);
        reserve.registerAccruingLoan(id);
    }

    function test_unknownOrDisabledServiceRefusesWithItsExactError() public {
        bytes memory error_ =
            abi.encodeWithSelector(ReserveAccrualServiceLib.AccrualService_UnknownFacility.selector, 1);
        vm.expectRevert(error_);
        reserve.serviceAccruedLoan(1);
        vm.expectRevert(error_);
        reserve.accrualLoanScheduled(1);
        _fund(1, SCALE, 1, true);
        reserve.fixtureEnabled(false);
        vm.expectRevert(error_);
        reserve.serviceAccruedLoan(1);
        vm.expectRevert(error_);
        reserve.accrualLoanScheduled(1);
        reserve.fixtureEnabled(true);
        assertFalse(reserve.accrualLoanScheduled(1));
        assertEq(reserve.serviceAccruedLoan(1), 0);
    }

    function test_positiveCurveIsPreservedAndDueWorkRequiresCheckpoint() public {
        _fund(1, 360_000e18, 1000, true);
        vm.warp(start + 45 days);
        assertTrue(reserve.accrualLoanScheduled(1));
        bytes32 before_ = keccak256(abi.encode(reserve.accrualSnapshot(), reserve.accruedDebt(1)));
        assertEq(reserve.serviceAccruedLoan(1), 0);
        assertEq(keccak256(abi.encode(reserve.accrualSnapshot(), reserve.accruedDebt(1))), before_);
        vm.warp(start + 90 days);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, start + 90 days, start + 90 days)
        );
        reserve.serviceAccruedLoan(1);
        (uint256 processed, bool fresh) = reserve.checkpointAccrual(32);
        assertEq(processed, 1);
        assertTrue(fresh);
        before_ = keccak256(abi.encode(reserve.accrualSnapshot(), reserve.accruedDebt(1)));
        assertEq(reserve.serviceAccruedLoan(1), 0);
        assertEq(keccak256(abi.encode(reserve.accrualSnapshot(), reserve.accruedDebt(1))), before_);
    }

    /// @dev Independently walks the four signed coupon dates; no production date helper is imported.
    function testFuzz_dormantDatesAndMaturityPreserveFaceAndReleaseOnlyFutureCapacity(uint32 elapsed, uint8 units)
        public
    {
        uint256 principal = (uint256(units) % 10 + 1) * SCALE;
        _fund(1, principal, 1, true);
        (uint256 openingCeiling,,,) = reserve.fixtureState(1);
        assertGt(openingCeiling, principal, "positive signed term reserves future capacity");
        uint64 at = start + uint64(uint256(elapsed) % 730 days);
        vm.warp(at);
        uint64 due = start + 90 days;
        bool advanced;
        while (due != 0 && due <= at) {
            advanced = true;
            due = due + 90 days <= start + 365 days ? due + 90 days : 0;
        }
        bool stopped = at >= start + 365 days;
        uint64 eventDue = advanced ? due : 0;
        uint256 expectedCeiling = stopped ? principal : openingCeiling;
        if (stopped) {
            vm.expectEmit(true, false, false, true, address(reserve));
            emit AccrualCeilingReserved(1, openingCeiling, principal);
        }
        vm.expectEmit(true, true, false, true, address(reserve));
        emit AccrualBoundaryProcessed(1, at, 0, eventDue, stopped);
        assertEq(reserve.serviceAccruedLoan(1), 0, "zero coupon manufactured principal");
        (uint256 ceiling, uint256 total, uint64 actualDue, bool active) = reserve.fixtureState(1);
        assertEq(ceiling, expectedCeiling, "facility future capacity");
        assertEq(total, expectedCeiling, "portfolio future capacity");
        assertEq(actualDue, due, "signed date arithmetic");
        assertEq(active, !stopped, "maturity state");
        assertEq(bridge.facility(1).nextPaymentDue, eventDue == 0 ? start + 90 days : eventDue);
        assertEq(reserve.deployedTo(1), principal, "servicing changed debt face");
        assertEq(reserve.accrualSnapshot().gross, 0, "servicing created income");
        assertEq(reserve.accrualReservedExposure(), expectedCeiling - principal);
        bytes32 before_ = keccak256(abi.encode(reserve.accrualSnapshot(), reserve.accruedDebt(1)));
        assertEq(reserve.serviceAccruedLoan(1), 0);
        assertEq(
            keccak256(abi.encode(reserve.accrualSnapshot(), reserve.accruedDebt(1))), before_, "repeat service drift"
        );
        reserve.requireAccrualIdle();
    }

    function test_dormantCashDoesNotInventPikDateWork() public {
        _fund(1, SCALE, 1, false);
        vm.warp(start + 365 days);
        assertFalse(reserve.accrualLoanScheduled(1));
        (uint256 ceiling, uint256 total, uint64 due, bool active) = reserve.fixtureState(1);
        bytes32 before_ = keccak256(abi.encode(ceiling, total, due, active));
        assertEq(reserve.serviceAccruedLoan(1), 0);
        (ceiling, total, due, active) = reserve.fixtureState(1);
        assertEq(keccak256(abi.encode(ceiling, total, due, active)), before_, "cash received PIK-only state work");
        assertEq(bridge.facility(1).nextPaymentDue, start + 90 days);
        assertEq(reserve.deployedTo(1), SCALE);
        assertEq(reserve.accrualSnapshot().gross, 0);
    }

    function test_invalidMaturityCeilingRefusesAndRollsBackTheStop() public {
        _fund(1, SCALE, 1, true);
        reserve.fixtureCeiling(1, SCALE - 1);
        vm.warp(start + 365 days);
        vm.expectRevert(ReserveAccrualServiceLib.AccrualService_InvalidCeiling.selector);
        reserve.serviceAccruedLoan(1);
        (uint256 ceiling, uint256 total, uint64 due, bool active) = reserve.fixtureState(1);
        assertEq(ceiling, SCALE - 1);
        assertEq(total, SCALE - 1);
        assertEq(due, start + 90 days);
        assertTrue(active);
        reserve.requireAccrualIdle();
    }
}
