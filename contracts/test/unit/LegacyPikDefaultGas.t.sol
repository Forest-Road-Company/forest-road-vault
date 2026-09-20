// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {Config} from "../../src/libraries/Config.sol";

contract LegacyGasColdWitness {
    uint256 private value = 1;

    function read() external view returns (uint256) {
        return value;
    }
}

/// @notice Setup occurs in the fixture transaction; measured calls start in a fresh test frame.
/// @dev The witness verifies cold account/storage accounting without vm.cool or recorded accesses.
///      Points and seven-day vesting exercise optional fee hooks; production vesting remains off.
abstract contract LegacyPikGasFixture is CreditLayerFixture {
    uint256 internal constant PRINCIPAL = 1_000_000e18;
    uint256 internal constant CALL_BUDGET = 15_000_000;
    uint256 internal facilityId;
    uint64 internal firstDue;
    LegacyGasColdWitness private witness;

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function _fixturePaymentInterval() internal pure override returns (uint64) {
        return 7 days;
    }

    function _marked() internal pure virtual returns (bool) {
        return true;
    }

    function _coupons() internal pure virtual returns (uint256) {
        return 16;
    }

    function _publishAssessment() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual override {
        super.setUp();
        facilityId = _liveFilmFacility(PRINCIPAL);
        firstDue = bridge.facility(facilityId).nextPaymentDue;
        PointsModule points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );
        vm.startPrank(admin);
        vault.setPointsModule(address(points));
        usdfr.setPointsModule(address(points));
        vault.setManagementFee(0);
        vault.setPerformanceFee(1000);
        vault.setYieldVestingPeriod(7 days);
        waterfall.setProtocolFee(1000);
        defaultManager.setGraceWindow(Config.CLASS_FILM_TAX_CREDITS, 1 days);
        defaultManager.setRemedyRef(Config.CLASS_FILM_TAX_CREDITS, FILM_REF);
        vm.stopPrank();
        vm.startPrank(alice);
        usdfr.approve(address(vault), PRINCIPAL);
        vault.deposit(PRINCIPAL, alice);
        vm.stopPrank();
        if (_marked()) {
            vm.prank(guardian);
            waterfall.pause();
            vm.warp(uint256(firstDue) + 2 days + 1);
            defaultManager.markPastDue(facilityId);
            assertEq(defaultManager.pastDueContribution(facilityId), PRINCIPAL);
            vm.prank(guardian);
            waterfall.unpause();
        }
        vm.warp(uint256(firstDue) + (_coupons() - 1) * 7 days);
        _attestDefault(facilityId);
        if (_publishAssessment()) {
            vm.prank(admin);
            assessedImpairmentSource.setAssessment(
                0, uint64(block.timestamp + 7 days), keccak256("gas-measurement-assessment")
            );
            (,,, bool active,) = assessedImpairmentSource.currentAssessment();
            assertTrue(active, "gas fixture requires a live recovery assessment");
        }
        witness = new LegacyGasColdWitness();
    }

    function _assertColdFrame() internal {
        uint256 beforeFirst = gasleft();
        assertEq(witness.read(), 1);
        uint256 first = beforeFirst - gasleft();
        uint256 beforeSecond = gasleft();
        assertEq(witness.read(), 1);
        uint256 second = beforeSecond - gasleft();
        assertGt(first, second + 3500, "fixture did not begin with cold account and storage accesses");
        emit log_named_uint("cold witness gas", first);
        emit log_named_uint("warm witness gas", second);
    }

    function _model(uint256 coupons) internal pure returns (uint256 face) {
        face = PRINCIPAL;
        for (uint256 i; i < coupons; ++i) {
            face += face * 1400 * 7 days / (10_000 * 360 days) / 1e12 * 1e12;
        }
    }

    function _callDefault() internal returns (bool success, bytes memory result) {
        _assertColdFrame();
        vm.prank(servicer);
        uint256 beforeCall = gasleft();
        (success, result) = address(defaultManager).call{gas: CALL_BUDGET}(
            abi.encodeCall(IDefaultManager.declareDefault, (facilityId, FILM_REF))
        );
        uint256 spent = beforeCall - gasleft();
        emit log_named_uint("default cold caller gas", spent);
        assertLt(spent, CALL_BUDGET, "call exhausted the measured-call budget");
    }

    function _assertDeclared() internal view {
        uint256 expected = _model(16);
        assertEq(defaultManager.defaultedContribution(facilityId), expected);
        assertEq(reserves.deployedTo(facilityId), expected);
        assertEq(defaultManager.pastDueContribution(facilityId), 0);
        assertEq(uint256(bridge.facility(facilityId).state), uint256(ClaimBridge.LoanState.Defaulted));
    }
}

contract LegacyPikUnmarkedGasTest is LegacyPikGasFixture {
    function _marked() internal pure override returns (bool) {
        return false;
    }

    function test_sixteenUnmarkedCouponsFitTheTransactionBudget() public {
        (bool success, bytes memory result) = _callDefault();
        assertTrue(success, "bounded declaration failed");
        assertEq(result.length, 0);
        _assertDeclared();
    }
}

contract LegacyPikMarkedGasTest is LegacyPikGasFixture {
    function test_sixteenMarkedCouponsFitTheTransactionBudget() public {
        (bool success, bytes memory result) = _callDefault();
        assertTrue(success, "bounded marked declaration failed");
        assertEq(result.length, 0);
        _assertDeclared();
    }
}

contract LegacyPikPendingGasTest is LegacyPikGasFixture {
    function _coupons() internal pure override returns (uint256) {
        return 40;
    }

    function test_longBacklogReturnsTypedPendingWithinTheTransactionBudget() public {
        (bool success, bytes memory result) = _callDefault();
        assertFalse(success);
        assertEq(
            result,
            abi.encodeWithSelector(
                DefaultAccrualLib.DefaultAccrual_LegacyPikPending.selector, facilityId, firstDue + 16 * 7 days
            )
        );
        assertEq(reserves.deployedTo(facilityId), PRINCIPAL, "failed declaration retained a partial posting");
        assertEq(defaultManager.pastDueContribution(facilityId), PRINCIPAL);
        assertEq(defaultManager.defaultedContribution(facilityId), 0);
    }

    function test_sixteenPreparedCouponsFitTheTransactionBudgetAndRetainRisk() public {
        _assertColdFrame();
        vm.prank(servicer);
        uint256 beforeCall = gasleft();
        (bool success, bytes memory result) = address(defaultManager).call{gas: CALL_BUDGET}(
            abi.encodeCall(IDefaultManager.settleLegacyPikForDefault, (facilityId, FILM_REF, 16))
        );
        uint256 spent = beforeCall - gasleft();
        emit log_named_uint("preparation cold caller gas", spent);
        assertLt(spent, CALL_BUDGET);
        assertTrue(success, "bounded preparation failed");
        (uint256 processed, uint64 pending) = abi.decode(result, (uint256, uint64));
        assertEq(processed, 16);
        assertEq(pending, firstDue + 16 * 7 days);
        assertEq(reserves.deployedTo(facilityId), _model(16));
        assertEq(defaultManager.pastDueContribution(facilityId), _model(16));
        assertEq(defaultManager.defaultedContribution(facilityId), 0);
    }
}

contract LegacyPikAssessedUnmarkedGasTest is LegacyPikUnmarkedGasTest {
    function _publishAssessment() internal pure override returns (bool) {
        return true;
    }
}

contract LegacyPikAssessedMarkedGasTest is LegacyPikMarkedGasTest {
    function _publishAssessment() internal pure override returns (bool) {
        return true;
    }
}

contract LegacyPikAssessedPendingGasTest is LegacyPikPendingGasTest {
    function _publishAssessment() internal pure override returns (bool) {
        return true;
    }
}
