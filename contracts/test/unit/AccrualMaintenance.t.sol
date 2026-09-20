// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AccrualMaintenance, IAccrualCheckpointSource} from "../../script/AccrualMaintenance.s.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";

contract AccrualMaintenanceLoopHarness is AccrualMaintenance {
    function _checkpoint(IAccrualCheckpointSource source, uint256 maximum)
        internal
        override
        returns (uint256 processed, bool fresh)
    {
        return source.checkpointAccrual(maximum);
    }
}

/// @dev A bounded work queue with independently observable pending work and call count.
contract AccrualMaintenanceSourceFixture {
    enum Mode {
        Normal,
        ZeroWork,
        OverLimit,
        WrongFresh,
        Backwards,
        DisableAfter,
        CompetingKeeper
    }

    uint256 public pending;
    uint256 public calls;
    uint64 private boundary;
    Mode private mode;
    bool private manual;
    IContinuousAccrual.Snapshot private supplied;

    constructor(uint256 count) {
        pending = count;
        boundary = uint64(block.timestamp - 1);
    }

    function setMode(Mode value) external {
        mode = value;
    }

    function setSnapshot(bool enabled, bool fresh, uint64 through) external {
        manual = true;
        supplied.enabled = enabled;
        supplied.fresh = fresh;
        supplied.accruedThrough = through;
    }

    function accrualSnapshot() external view returns (IContinuousAccrual.Snapshot memory s) {
        if (manual) return supplied;
        s.enabled = mode != Mode.DisableAfter || calls == 0;
        s.fresh = pending == 0;
        s.accruedThrough = s.fresh ? uint64(block.timestamp) : boundary;
    }

    function checkpointAccrual(uint256 maximum) external returns (uint256 processed, bool fresh) {
        ++calls;
        if (mode == Mode.ZeroWork) return (0, false);
        if (mode == Mode.OverLimit) return (maximum + 1, false);
        if (mode == Mode.CompetingKeeper) {
            pending = 0;
            return (0, true);
        }
        processed = pending < maximum ? pending : maximum;
        pending -= processed;
        fresh = pending == 0;
        if (mode == Mode.WrongFresh) fresh = !fresh;
        if (mode == Mode.Backwards) --boundary;
    }
}

contract AccrualMaintenanceTest is Test {
    AccrualMaintenanceLoopHarness private runner;
    AccrualMaintenanceSourceFixture private source;

    function setUp() public {
        vm.warp(1_750_000_000);
        runner = new AccrualMaintenanceLoopHarness();
        source = new AccrualMaintenanceSourceFixture(40);
    }

    function testFuzz_budgetsConservePendingWork(uint16 count, uint8 size, uint8 budget) public {
        uint256 initial = bound(count, 0, 2048);
        uint256 maximum = bound(size, 1, 32);
        uint256 maxBatches = bound(budget, 1, 32);
        source = new AccrualMaintenanceSourceFixture(initial);
        AccrualMaintenance.Report memory report = runner.run(address(source), block.chainid, maximum, maxBatches);
        uint256 capacity = maximum * maxBatches;
        uint256 completed = initial < capacity ? initial : capacity;
        assertEq(report.processed, completed, "completed work must match the independent capacity bound");
        assertEq(source.pending(), initial - completed, "completed and pending work must conserve the queue");
        assertEq(report.batches, (completed + maximum - 1) / maximum, "exact transaction count");
        assertEq(source.calls(), report.batches);
        assertEq(report.fresh, initial == completed);
        assertEq(report.accruedThrough, uint64(block.timestamp - (report.fresh ? 0 : 1)));
    }

    function test_partialProgressSurvivesNextInvocation() public {
        AccrualMaintenance.Report memory first = runner.run(address(source), block.chainid, 32, 1);
        assertEq(first.processed, 32);
        assertEq(first.batches, 1);
        assertFalse(first.fresh);
        assertEq(source.pending(), 8);
        // Simultaneous dates can leave the frontier unchanged despite useful completed work.
        assertEq(first.accruedThrough, block.timestamp - 1);
        AccrualMaintenance.Report memory second = runner.run(address(source), block.chainid, 32, 4);
        assertEq(second.processed, 8);
        assertEq(second.batches, 1);
        assertTrue(second.fresh);
        assertEq(source.pending(), 0);
        assertEq(source.calls(), 2);
    }

    function test_freshBookNeedsNoTransaction() public {
        source = new AccrualMaintenanceSourceFixture(0);
        AccrualMaintenance.Report memory report = runner.run(address(source), block.chainid, 32, 4);
        assertTrue(report.fresh);
        assertEq(report.processed, 0);
        assertEq(report.batches, 0);
        assertEq(source.calls(), 0);
    }

    function test_concurrentCompletionAllowsAZeroWorkFreshResult() public {
        source.setMode(AccrualMaintenanceSourceFixture.Mode.CompetingKeeper);
        AccrualMaintenance.Report memory report = runner.run(address(source), block.chainid, 32, 4);
        assertEq(report.processed, 0);
        assertEq(report.batches, 1);
        assertTrue(report.fresh);
    }

    function test_wrongChainRefusesBeforeAnyCheckpoint() public {
        uint256 wrong = block.chainid + 1;
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_WrongChain.selector, block.chainid, wrong)
        );
        runner.run(address(source), wrong, 32, 4);
        assertEq(source.calls(), 0);
    }

    function test_bothLimitsRejectZeroAndValuesAbove32() public {
        uint256[2] memory invalid = [uint256(0), uint256(33)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_InvalidLimits.selector, invalid[i], 4)
            );
            runner.run(address(source), block.chainid, invalid[i], 4);
            vm.expectRevert(
                abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_InvalidLimits.selector, 32, invalid[i])
            );
            runner.run(address(source), block.chainid, 32, invalid[i]);
        }
        assertEq(source.calls(), 0);
    }

    function test_codelessReserveIsAnExplicitConfigurationError() public {
        address missing = makeAddr("absent-maintenance-reserve");
        vm.etch(missing, hex"");
        vm.expectRevert(abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_NoCode.selector, missing));
        runner.run(missing, block.chainid, 32, 4);
    }

    function test_disabledRecognitionRefusesMaintenance() public {
        source.setSnapshot(false, true, uint64(block.timestamp));
        vm.expectRevert(AccrualMaintenance.AccrualMaintenance_NotEnabled.selector);
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_futureFrontierIsRefused() public {
        uint64 future = uint64(block.timestamp + 1);
        source.setSnapshot(true, false, future);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_InvalidSnapshot.selector, future, false)
        );
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_oldFrontierCannotClaimFreshness() public {
        uint64 old = uint64(block.timestamp - 1);
        source.setSnapshot(true, true, old);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_InvalidSnapshot.selector, old, true)
        );
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_incompleteZeroWorkIsRefused() public {
        source.setMode(AccrualMaintenanceSourceFixture.Mode.ZeroWork);
        vm.expectRevert(AccrualMaintenance.AccrualMaintenance_NoProgress.selector);
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_oversizedReportedProgressIsRefused() public {
        source.setMode(AccrualMaintenanceSourceFixture.Mode.OverLimit);
        vm.expectRevert(abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_InvalidProgress.selector, 33, 32));
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_inconsistentFreshnessIsRefused() public {
        source.setMode(AccrualMaintenanceSourceFixture.Mode.WrongFresh);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualMaintenance.AccrualMaintenance_IncoherentResult.selector, true, false)
        );
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_backwardFrontierIsRefused() public {
        source.setMode(AccrualMaintenanceSourceFixture.Mode.Backwards);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccrualMaintenance.AccrualMaintenance_ClockMovedBackwards.selector,
                uint64(block.timestamp - 1),
                uint64(block.timestamp - 2)
            )
        );
        runner.run(address(source), block.chainid, 32, 4);
    }

    function test_disablingRecognitionDuringMaintenanceIsRefused() public {
        source.setMode(AccrualMaintenanceSourceFixture.Mode.DisableAfter);
        vm.expectRevert(AccrualMaintenance.AccrualMaintenance_NotEnabled.selector);
        runner.run(address(source), block.chainid, 32, 4);
    }
}
