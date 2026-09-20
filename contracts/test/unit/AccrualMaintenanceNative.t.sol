// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccrualMaintenance} from "../../script/AccrualMaintenance.s.sol";
import {ContinuousAccrualDeployment} from "../../script/ContinuousAccrualDeployment.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Real native reserve, bridge, registry, waterfall and token modules, with the credit
///      fixture's mock documentary oracle and backstop. No operator credentials are used.
abstract contract AccrualMaintenanceNativeFixture is CreditLayerFixture {
    AccrualMaintenance internal runner;
    uint64 internal start;
    uint256 internal constant PRINCIPAL = 360e18;

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(admin);
        ContinuousAccrualDeployment.configure(
            address(reserves),
            IContinuousAccrual.Modules({
                token: address(usdfr),
                controller: address(controller),
                vault: address(vault),
                waterfall: address(waterfall),
                bridge: address(bridge),
                registry: address(registry),
                defaultManager: address(defaultManager)
            })
        );
        vm.stopPrank();
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 100_000e18);
        runner = new AccrualMaintenance();
        start = uint64(block.timestamp);
    }

    function _fixtureFilmTenor() internal pure override returns (uint64) {
        return 360 days;
    }

    function _fixturePaymentInterval() internal pure override returns (uint64) {
        return 90 days;
    }
}

contract AccrualMaintenanceNativeCashTest is AccrualMaintenanceNativeFixture {
    function test_cashStreamsWithoutMaintenanceBetweenBoundariesAndStopsAtMaturity() public {
        uint256 id = _liveFilmFacility(PRINCIPAL);
        vm.warp(start + 180 days);
        IContinuousAccrual.Snapshot memory middle = reserves.accrualSnapshot();
        // The cash ceiling is reached at maturity. Its final one-second segment keeps
        // the endpoint exact; the preceding stream interpolates a native-unit-rounded endpoint.
        uint256 scale = 10 ** (18 - IERC20Metadata(address(usdc)).decimals());
        uint256 duration = 360 days - 1;
        uint256 endpoint = (PRINCIPAL * 1400 * duration / (10_000 * 360 days)) / scale * scale;
        uint256 streamed = (endpoint / duration) * 180 days;
        assertEq(middle.gross, streamed, "integer per-second stream on the rounded endpoint");
        assertEq(reserves.accruedDebt(id).interest, 25.2e18, "authoritative contractual debt at the same time");
        AccrualMaintenance.Report memory noWork = runner.run(address(reserves), block.chainid, 32, 4);
        assertEq(noWork.batches, 0);
        assertTrue(noWork.fresh);
        vm.warp(start + 380 days);
        assertFalse(reserves.accrualSnapshot().fresh);
        AccrualMaintenance.Report memory report = runner.run(address(reserves), block.chainid, 32, 4);
        assertEq(report.processed, 2, "maturity-minus-one and maturity are separate technical events");
        assertEq(report.batches, 1);
        assertTrue(report.fresh);
        IContinuousAccrual.Snapshot memory closed = reserves.accrualSnapshot();
        assertEq(closed.gross, 50.4e18, "one Actual/360 year on a frozen 360 principal at 14 percent");
        assertEq(closed.feeUnissued, 5.04e18);
        assertEq(closed.seniorUnissued, 45.36e18);
        IAccrualLifecycle.Debt memory debt = reserves.accruedDebt(id);
        assertEq(debt.principal, PRINCIPAL);
        assertEq(debt.interest, 50.4e18);
        vm.warp(start + 720 days);
        assertEq(reserves.accrualSnapshot().gross, closed.gross, "matured debt cannot resume earning");
    }
}

contract AccrualMaintenanceNativePikTest is AccrualMaintenanceNativeFixture {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function test_sharedQuarterlyDateCommits32ThenCompletesTheRemainingEight() public {
        for (uint256 i; i < 40; ++i) {
            _liveFilmFacility(PRINCIPAL);
        }
        vm.warp(start + 90 days);
        assertFalse(reserves.accrualSnapshot().fresh);
        AccrualMaintenance.Report memory first = runner.run(address(reserves), block.chainid, 32, 1);
        assertEq(first.processed, 32);
        assertEq(first.batches, 1);
        assertFalse(first.fresh);
        assertEq(first.accruedThrough, start + 90 days, "shared date may remain unchanged after real work");
        AccrualMaintenance.Report memory second = runner.run(address(reserves), block.chainid, 32, 4);
        assertEq(second.processed, 8);
        assertEq(second.batches, 1);
        assertTrue(second.fresh);
        assertEq(reserves.accrualSnapshot().gross, 504e18, "40 notes each earn 12.6 in the signed quarter");
        for (uint256 id = 1; id <= 40; ++id) {
            IAccrualLifecycle.Debt memory debt = reserves.accruedDebt(id);
            assertEq(debt.principal, 372.6e18);
            assertEq(debt.interest, 0);
            assertEq(bridge.facility(id).nextPaymentDue, start + 180 days);
        }
        AccrualMaintenance.Report memory repeat = runner.run(address(reserves), block.chainid, 32, 4);
        assertEq(repeat.processed, 0);
        assertEq(repeat.batches, 0);
        assertEq(reserves.accrualSnapshot().gross, 504e18, "repeating maintenance cannot recognize income twice");
    }

    function test_missedQuarterlyRunsRecoverUsingTheSignedCompoundingDates() public {
        uint256 id = _liveFilmFacility(PRINCIPAL);
        vm.warp(start + 270 days);
        AccrualMaintenance.Report memory report = runner.run(address(reserves), block.chainid, 2, 4);
        assertEq(report.processed, 3);
        assertEq(report.batches, 2);
        assertTrue(report.fresh);
        // 360 * 1.035^3, with every signed coupon exactly representable in native units.
        IAccrualLifecycle.Debt memory debt = reserves.accruedDebt(id);
        assertEq(debt.principal, 399.138435e18);
        assertEq(debt.interest, 0);
        assertEq(reserves.accrualSnapshot().gross, 39.138435e18);
        assertEq(bridge.facility(id).nextPaymentDue, start + 360 days);
    }
}
