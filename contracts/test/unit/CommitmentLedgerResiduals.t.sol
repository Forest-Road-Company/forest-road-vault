// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {ICommitmentLedger} from "../../src/interfaces/ICommitmentLedger.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CommitmentLedgerReference} from "../helpers/CommitmentLedgerReference.sol";

contract ResidualCuratorFixture {
    mapping(uint256 => uint256) public poolBalance;

    function set(uint256 classId, uint256 amount) external { poolBalance[classId] = amount; }
}

contract ResidualReserveFixture {
    uint256 public coverageReserve;

    function set(uint256 amount) external { coverageReserve = amount; }
}

/// @dev Both ledgers have the same source and economic inputs, with opposite declaration orders.
///      The reference retains the entire original contract except its name and import paths.
contract CommitmentLedgerResidualsTest is Test {
    struct Row {
        bool live;
        uint256 classId;
        uint256 principal;
    }

    struct Totals {
        uint256 pastDueDemand;
        uint256 declaredDemand;
        uint256 reserve;
        uint256 pastDueDelivered;
    }

    bool private constant HAS_BACKSTOP = true;
    CommitmentLedger private candidate;
    CommitmentLedgerReference private baseline;
    ResidualCuratorFixture private pools;
    ResidualReserveFixture private sharedReserve;
    mapping(uint256 => uint256) private marked;
    address private curatorAddress;
    address private backstopAddress;

    function setUp() public {
        candidate = new CommitmentLedger(address(this));
        baseline = new CommitmentLedgerReference(address(this));
        pools = new ResidualCuratorFixture();
        sharedReserve = new ResidualReserveFixture();
    }

    function modules() external view returns (address, address, address, address, address, address, address, address) {
        return (address(0), address(0), address(0), address(0), curatorAddress, address(0), address(0), address(candidate));
    }

    function backstop() external view returns (address) { return backstopAddress; }
    function pastDuePrincipal(uint256 classId) external view returns (uint256) { return marked[classId]; }

    function _random(uint256 seed, uint256 coordinate) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, coordinate)));
    }

    function _inputs(uint256 seed, bool absentCurator, bool absentBackstop) private {
        curatorAddress = absentCurator ? address(0) : address(pools);
        backstopAddress = !HAS_BACKSTOP || absentBackstop ? address(0) : address(sharedReserve);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 r = _random(seed, classId);
            marked[classId] = r & 3 == 0 ? 0 : ((r >> 32) & 0xfffff) * 1e18;
            pools.set(classId, r & 7 == 0 ? 0 : (r & 0xffffff) * 1e18);
        }
        uint256 reserveSeed = _random(seed, 0);
        sharedReserve.set(reserveSeed & 3 == 0 ? 0 : (reserveSeed & 0x1ffffff) * 1e18);
    }

    function _rows(uint256 seed, uint256 count) private returns (uint256[] memory byClass) {
        uint256[] memory order = new uint256[](count);
        uint256[] memory classes = new uint256[](count);
        uint256[] memory principal = new uint256[](count);
        byClass = new uint256[](Config.NUM_CLASSES);
        for (uint256 i; i < count; ++i) {
            uint256 r = _random(seed, i);
            order[i] = i;
            classes[i] = 1 + (r >> 64) % Config.NUM_CLASSES;
            principal[i] = r & 7 == 0 ? 0 : (r & 0xfffff) * 1e18;
            byClass[classes[i] - 1] += principal[i];
        }
        for (uint256 i = count; i > 1; --i) {
            uint256 j = _random(seed, count + i) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }
        for (uint256 i; i < count; ++i) {
            uint256 k = order[i];
            candidate.register(k + 1, classes[k], principal[k]);
            k = order[count - 1 - i];
            baseline.register(k + 1, classes[k], principal[k]);
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) { return a < b ? a : b; }

    /// @dev Tests the proposed aggregate equation against the unchanged row-walking reference.
    function _proposed(uint256[] memory byClass) private view returns (uint256 residual, uint256 pastDueSenior) {
        Totals memory t;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 pastDue = marked[classId];
            uint256 pool = curatorAddress == address(0) ? 0 : pools.poolBalance(classId);
            uint256 pastDueCurator = _min(pastDue, pool);
            t.pastDueDemand += pastDue - pastDueCurator;
            uint256 declared = byClass[classId - 1];
            t.declaredDemand += declared - _min(declared, pool - pastDueCurator);
        }
        if (HAS_BACKSTOP && backstopAddress != address(0)) t.reserve = sharedReserve.coverageReserve();
        t.pastDueDelivered = _min(t.pastDueDemand, t.reserve);
        pastDueSenior = t.pastDueDemand - t.pastDueDelivered;
        residual = pastDueSenior + t.declaredDemand - _min(t.declaredDemand, t.reserve - t.pastDueDelivered);
    }

    function _compare(uint256[] memory byClass) private view {
        (uint256 expected, uint256 expectedPastDue) = baseline.conservativeResiduals();
        (uint256 proposed, uint256 proposedPastDue) = _proposed(byClass);
        assertEq(proposed, expected, "proposed residual disagrees with unchanged reference");
        assertEq(proposedPastDue, expectedPastDue, "proposed past-due residual disagrees with unchanged reference");
        (uint256 actual, uint256 actualPastDue) = candidate.conservativeResiduals();
        assertEq(actual, expected, "candidate residual disagrees with unchanged reference");
        assertEq(actualPastDue, expectedPastDue, "candidate past-due residual disagrees with unchanged reference");
    }

    function testFuzz_residualsMatchTheOriginalAcrossCountsClassesPoolsAndOrders(
        uint256 seed, uint8 countSeed, bool absentCurator, bool absentBackstop
    ) public {
        _inputs(seed, absentCurator, absentBackstop);
        _compare(_rows(seed, uint256(countSeed) % 201));
    }

    function test_emptyZeroPrincipalAndExhaustedPoolsMatchTheOriginal() public {
        uint256[] memory totals = new uint256[](Config.NUM_CLASSES);
        _compare(totals);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            candidate.register(classId, classId, 0);
            uint256 reverseClass = Config.NUM_CLASSES + 1 - classId;
            baseline.register(reverseClass, reverseClass, 0);
        }
        _compare(totals);
        curatorAddress = address(pools);
        backstopAddress = HAS_BACKSTOP ? address(sharedReserve) : address(0);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            marked[classId] = 100e18;
            pools.set(classId, 100e18);
            candidate.updatePrincipal(classId, 50e18);
            baseline.updatePrincipal(classId, 50e18);
            totals[classId - 1] = 50e18;
        }
        _compare(totals);
        sharedReserve.set(1);
        _compare(totals);
        curatorAddress = address(0);
        _compare(totals);
        sharedReserve.set(type(uint128).max);
        _compare(totals);
        backstopAddress = address(0);
        _compare(totals);
    }


    function _checkRows(Row[] memory rows) private view {
        uint256[] memory totals = new uint256[](Config.NUM_CLASSES);
        uint256 live;
        for (uint256 id; id < rows.length; ++id) {
            Row memory row = rows[id];
            if (row.live) ++live;
            totals[row.live ? row.classId - 1 : 0] += row.principal;
            (uint256 actualClass, bool actualDrawn, uint256 actualCoverage, uint256 actualPrincipal) = candidate.eventInfo(id);
            (uint256 originalClass, bool originalDrawn, uint256 originalCoverage, uint256 originalPrincipal) = baseline.eventInfo(id);
            assertEq(actualClass, row.classId, "row class differs from history model");
            assertEq(actualPrincipal, row.principal, "row principal differs from history model");
            assertEq(actualClass, originalClass, "row class differs from original");
            assertEq(actualPrincipal, originalPrincipal, "row principal differs from original");
            assertEq(actualCoverage, originalCoverage, "coverage changed");
            assertEq(actualDrawn, originalDrawn, "drawn status changed");
            assertEq(candidate.consumed(id), baseline.consumed(id), "consumption changed");
            assertEq(candidate.deliverable(id), baseline.deliverable(id), "deliverable changed");
        }
        assertEq(candidate.eventCount(), live, "live count differs from history model");
        assertEq(baseline.eventCount(), live, "reference live count differs from history model");
        uint256[] memory recomputed = new uint256[](Config.NUM_CLASSES);
        for (uint256 i; i < live; ++i) {
            uint256 eventId = candidate.eventAt(i);
            assertEq(eventId, baseline.eventAt(i), "survivor enumeration order changed");
            assertTrue(rows[eventId].live, "enumerated row is not live");
            (uint256 classId,,, uint256 principal) = candidate.eventInfo(eventId);
            recomputed[classId - 1] += principal;
        }
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            assertEq(recomputed[classId - 1], totals[classId - 1], "enumerated rows differ from history model");
            assertEq(candidate.remainingPrincipalForClass(classId), recomputed[classId - 1], "class total drifted from live rows");
        }
        assertEq(candidate.remainingAggregate(), baseline.remainingAggregate(), "coverage aggregate changed");
        assertEq(candidate.deliverableAggregate(), baseline.deliverableAggregate(), "deliverable aggregate changed");
        assertEq(candidate.consumedAggregate(), baseline.consumedAggregate(), "consumed aggregate changed");
        _compare(totals);
    }

    function _history(uint256 seed, uint256 steps) private returns (uint256[6] memory calls) {
        Row[] memory rows = new Row[](16);
        _inputs(seed, false, false);
        _checkRows(rows);
        for (uint256 i; i < steps; ++i) {
            uint256 r = _random(seed, i);
            uint256 id = (r >> 32) % rows.length;
            uint256 next = r & 7 == 0 ? 0 : (r >> 64) % 1e30;
            uint256 action = r % 6;
            if (action <= 1) {
                if (!rows[id].live) {
                    uint256 classId = 1 + (r >> 160) % Config.NUM_CLASSES;
                    candidate.register(id, classId, next);
                    baseline.register(id, classId, next);
                    rows[id] = Row(true, classId, next);
                    ++calls[0];
                } else {
                    candidate.updatePrincipal(id, next);
                    baseline.updatePrincipal(id, next);
                    rows[id].principal = next;
                    ++calls[1];
                }
            } else if (action == 2) {
                if (rows[id].live) {
                    uint256 room = (r >> 128) % 1e30;
                    uint256 covered = 1 + (r >> 200) % 1e25;
                    assertEq(candidate.sync(id, room, next, covered), baseline.sync(id, room, next, covered));
                    rows[id].principal = next;
                    ++calls[2];
                }
            } else if (action == 3) {
                candidate.release(id);
                baseline.release(id);
                if (rows[id].live) ++calls[3];
                delete rows[id];
            } else if (action == 4) {
                _inputs(r, (r >> 192) & 1 == 0, (r >> 193) & 1 == 0);
                ++calls[4];
            } else {
                assertFalse(candidate.sync(id, 1e30, next, 0), "zero-covered sync changed draw status");
                assertFalse(baseline.sync(id, 1e30, next, 0));
                ++calls[5];
            }
            _checkRows(rows);
        }
    }

    function testFuzz_classTotalsStayExactThroughRepeatedPrincipalChanges(uint256 seed) public {
        _history(seed, 512);
    }

    function test_longHistoryExercisesEveryPrincipalWriterWithoutDrift() public {
        // This witness models separate transactions and measures accounting, not transaction gas.
        // The randomized 512-step tests and the separate gas test keep normal metering enabled.
        vm.pauseGasMetering();
        uint256[6] memory calls = _history(20260912, 8192);
        vm.resumeGasMetering();
        for (uint256 i; i < calls.length; ++i) {
            assertGt(calls[i], 0, "long history missed an action");
            emit log_named_uint(string.concat("history action ", vm.toString(i)), calls[i]);
        }
    }

    function test_nonzeroCoverageCannotCreateAnUnregisteredRow() public {
        bytes memory expected = abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_UnknownEvent.selector, 909);
        vm.expectRevert(expected);
        candidate.sync(909, 100, 90, 10);
        vm.expectRevert(expected);
        baseline.sync(909, 100, 90, 10);
        assertEq(candidate.eventCount(), 0);
        assertEq(candidate.remainingPrincipalForClass(1), 0);
        assertEq(candidate.remainingAggregate(), 0);
        assertEq(candidate.consumedAggregate(), 0);
        assertFalse(candidate.sync(909, 100, 90, 0));
    }

    function test_classPrincipalGetterRejectsEveryUnsupportedClassBoundary() public {
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, 0));
        candidate.remainingPrincipalForClass(0);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, Config.NUM_CLASSES + 1));
        candidate.remainingPrincipalForClass(Config.NUM_CLASSES + 1);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, type(uint256).max));
        candidate.remainingPrincipalForClass(type(uint256).max);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            assertEq(candidate.remainingPrincipalForClass(classId), 0);
        }
    }

    /// @dev Cold ledger/module accounts and cold source slots; the executing caller account stays warm.
    function _coldGas(address target) private returns (uint256 used) {
        address curator = address(pools);
        address reserve = address(sharedReserve);
        vm.record();
        (uint256 expected, uint256 expectedPastDue) = ICommitmentLedger(target).conservativeResiduals();
        (bytes32[] memory reads,) = vm.accesses(address(this));
        for (uint256 i; i < reads.length; ++i) vm.coolSlot(address(this), reads[i]);
        vm.cool(target);
        vm.cool(curator);
        vm.cool(reserve);
        uint256 before_ = gasleft();
        (uint256 actual, uint256 actualPastDue) = ICommitmentLedger(target).conservativeResiduals();
        used = before_ - gasleft();
        assertEq(actual, expected);
        assertEq(actualPastDue, expectedPastDue);
    }

    function test_gasAtZeroFiftyAndTwoHundredRows() public {
        curatorAddress = address(pools);
        backstopAddress = HAS_BACKSTOP ? address(sharedReserve) : address(0);
        sharedReserve.set(1000e18);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            marked[classId] = 30e18;
            pools.set(classId, 20e18);
        }
        uint256 firstGas;
        uint256 fiftyGas;
        for (uint256 count; count <= 200; ++count) {
            if (count == 0 || count == 50 || count == 200) {
                uint256 actualGas = _coldGas(address(candidate));
                uint256 originalGas = _coldGas(address(baseline));
                emit log_named_uint(string.concat("candidate residual gas at ", vm.toString(count), " rows"), actualGas);
                emit log_named_uint(string.concat("reference residual gas at ", vm.toString(count), " rows"), originalGas);
                if (count == 0) firstGas = actualGas;
                else {
                    assertLe(actualGas, firstGas + 100, "residual read gas grew with row count");
                    assertLt(actualGas, originalGas, "aggregate did not reduce populated-book read cost");
                    if (count == 50) fiftyGas = actualGas;
                    else assertEq(actualGas, fiftyGas, "populated-book read gas depends on row count");
                }
            }
            if (count == 200) break;
            uint256 classId = 1 + count % Config.NUM_CLASSES;
            candidate.register(count + 1, classId, 100e18);
            baseline.register(count + 1, classId, 100e18);
        }
    }
}
