// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";

contract BridgeIdleReadProbe is ClaimBridge {
    function readIdleDuringOperation() external nonReentrant returns (bool) {
        return this.creditOperationIdle();
    }
}

contract BridgeIdleReadTest is Test {
    function test_idleReadReflectsTheActualOperationGuard() public {
        BridgeIdleReadProbe probe = new BridgeIdleReadProbe();
        assertTrue(probe.creditOperationIdle());
        assertFalse(probe.readIdleDuringOperation());
        assertTrue(probe.creditOperationIdle());
    }
}

/// @notice Temporary module admission failures cannot change legacy loan delinquency.
contract PikCreditAdmissionTest is CreditLayerFixture {
    bool private pik = true;
    uint256 private loan;

    function _pikFacilities() internal view override returns (bool) {
        return pik;
    }

    function _fixtureFilmTenor() internal pure override returns (uint64) {
        return 365 days;
    }

    function setUp() public override {
        super.setUp();
        _mintUSDfrTo(alice, 1_000_000e18);
        loan = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        _fundFacility(loan, 100_000e18);
    }

    function _afterGrace(uint32 extra) private {
        ClaimBridge.Facility memory f = bridge.facility(loan);
        vm.warp(uint256(f.nextPaymentDue) + 2 * defaultManager.graceWindow(f.classId) + 1 + bound(extra, 0, 120 days));
    }

    function _digest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                bridge.facility(loan),
                reserves.deployedTo(loan),
                registry.totalBookExposure(),
                defaultManager.pastDueContribution(loan),
                defaultManager.impairmentRiskStateHash(),
                controller.totalUSDfr(),
                controller.backingValue(),
                usdfr.balanceOf(address(vault))
            )
        );
    }

    function testFuzz_busyBridgeRefusesWithoutChangingTheLoan(uint32 extra) public {
        _afterGrace(extra);
        uint64 due = bridge.facility(loan).nextPaymentDue;
        bytes32 before_ = _digest();
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.creditOperationIdle, ()), abi.encode(false));
        vm.expectRevert(IDefaultManager.DefaultManager_CreditOperationBusy.selector);
        defaultManager.markPastDue(loan);
        assertEq(_digest(), before_, "temporary admission changed financial state");
        vm.clearMockedCalls();
        assertTrue(bridge.creditOperationIdle());
        defaultManager.markPastDue(loan);
        assertGt(bridge.facility(loan).nextPaymentDue, due, "idle bridge must permit normal PIK settlement");
        assertEq(defaultManager.pastDueContribution(loan), 0);
    }

    function test_missingIdleViewRefusesBeforeLoanClassification() public {
        _afterGrace(0);
        bytes32 before_ = _digest();
        bytes memory reason = abi.encodeWithSignature("GetterUnavailable()");
        vm.mockCallRevert(address(bridge), abi.encodeCall(ClaimBridge.creditOperationIdle, ()), reason);
        vm.expectRevert(reason);
        defaultManager.markPastDue(loan);
        assertEq(_digest(), before_);
    }

    function test_malformedIdleViewRefusesBeforeLoanClassification() public {
        _afterGrace(0);
        bytes32 before_ = _digest();
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.creditOperationIdle, ()), hex"01");
        vm.expectRevert(bytes(""));
        defaultManager.markPastDue(loan);
        assertEq(_digest(), before_);
    }

    function test_cashDelinquencyDoesNotDependOnLegacyPikAdmission() public {
        pik = false;
        uint256 cashLoan = _originateFilm(BORROWER_2, STATE_GA, 100_000e18);
        _fundFacility(cashLoan, 100_000e18);
        ClaimBridge.Facility memory f = bridge.facility(cashLoan);
        vm.warp(uint256(f.nextPaymentDue) + defaultManager.graceWindow(f.classId) + 1);
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.creditOperationIdle, ()), abi.encode(false));
        defaultManager.markPastDue(cashLoan);
        assertEq(defaultManager.pastDueContribution(cashLoan), 100_000e18);
    }
}
