// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {Config} from "../../src/libraries/Config.sol";

contract CommitmentLedgerInvariantCurator {
    mapping(uint256 classId => uint256) public poolBalance;

    function setPoolBalance(uint256 classId, uint256 amount) external {
        poolBalance[classId] = amount;
    }
}

contract CommitmentLedgerInvariantBackstop {
    uint256 public coverageReserve;

    function setCoverageReserve(uint256 amount) external {
        coverageReserve = amount;
    }
}

contract CommitmentLedgerInvariantManager {
    CommitmentLedger public immutable ledger;
    CommitmentLedgerInvariantCurator public immutable curator;
    CommitmentLedgerInvariantBackstop public immutable reserve;
    mapping(uint256 classId => uint256) public pastDuePrincipal;

    constructor(CommitmentLedgerInvariantCurator curator_, CommitmentLedgerInvariantBackstop reserve_) {
        curator = curator_;
        reserve = reserve_;
        ledger = new CommitmentLedger(address(this));
    }

    function register(uint256 eventId, uint256 classId, uint256 principal) external {
        ledger.register(eventId, classId, principal);
    }

    function updatePrincipal(uint256 eventId, uint256 principal) external {
        ledger.updatePrincipal(eventId, principal);
    }

    function sync(uint256 eventId, uint256 room, uint256 principal, uint256 covered) external {
        ledger.sync(eventId, room, principal, covered);
    }

    function release(uint256 eventId) external {
        ledger.release(eventId);
    }

    function setPastDuePrincipal(uint256 classId, uint256 principal) external {
        pastDuePrincipal[classId] = principal;
    }

    function backstop() external view returns (address) {
        return address(reserve);
    }

    function modules()
        external
        view
        returns (
            address bridge,
            address registry,
            address reserves,
            address controller,
            address curatorAddress,
            address oracle,
            address vault,
            address commitmentLedger
        )
    {
        return
            (address(0), address(0), address(0), address(0), address(curator), address(0), address(0), address(ledger));
    }
}

/// @dev Stateful driver bounded to eight live events. Every action is total under
///      `fail_on_revert=true`; rejected inputs are mapped into the live domain rather than hidden.
contract CommitmentLedgerInvariantHandler {
    uint256 internal constant MAX_EVENTS = 8;
    uint256 internal constant MAX_VALUE = 1_000_000_000e18;

    CommitmentLedgerInvariantManager public immutable manager;
    CommitmentLedgerInvariantCurator public immutable curator;
    CommitmentLedgerInvariantBackstop public immutable reserve;
    mapping(uint256 eventId => bool) public known;
    uint256 public calls;

    constructor(
        CommitmentLedgerInvariantManager manager_,
        CommitmentLedgerInvariantCurator curator_,
        CommitmentLedgerInvariantBackstop reserve_
    ) {
        manager = manager_;
        curator = curator_;
        reserve = reserve_;
    }

    function seed() external {
        known[1] = true;
        manager.register(1, 1, 100e18);
        curator.setPoolBalance(1, 25e18);
        reserve.setCoverageReserve(30e18);
        manager.setPastDuePrincipal(2, 10e18);
    }

    function upsert(uint256 eventSeed, uint256 classSeed, uint256 principalSeed) external {
        ++calls;
        uint256 eventId = eventSeed % MAX_EVENTS + 1;
        uint256 principal = principalSeed % (MAX_VALUE + 1);
        if (known[eventId]) {
            manager.updatePrincipal(eventId, principal);
        } else {
            known[eventId] = true;
            manager.register(eventId, classSeed % Config.NUM_CLASSES + 1, principal);
        }
    }

    function release(uint256 eventSeed) external {
        ++calls;
        uint256 eventId = eventSeed % MAX_EVENTS + 1;
        if (!known[eventId]) return;
        known[eventId] = false;
        manager.release(eventId);
    }

    function sync(uint256 eventSeed, uint256 roomSeed, uint256 principalSeed, uint256 coveredSeed) external {
        ++calls;
        uint256 eventId = eventSeed % MAX_EVENTS + 1;
        if (!known[eventId]) return;
        uint256 principal = principalSeed % (MAX_VALUE + 1);
        manager.sync(eventId, roomSeed % (MAX_VALUE + 1), principal, coveredSeed % MAX_VALUE + 1);
    }

    function setPastDue(uint256 classSeed, uint256 principalSeed) external {
        ++calls;
        manager.setPastDuePrincipal(classSeed % Config.NUM_CLASSES + 1, principalSeed % (MAX_VALUE + 1));
    }

    function setPool(uint256 classSeed, uint256 amountSeed) external {
        ++calls;
        curator.setPoolBalance(classSeed % Config.NUM_CLASSES + 1, amountSeed % (MAX_VALUE + 1));
    }

    function setReserve(uint256 amountSeed) external {
        ++calls;
        reserve.setCoverageReserve(amountSeed % (MAX_VALUE + 1));
    }
}

/// @notice CLAUDE.md §1.3 — conservative senior NAV must equal an independent aggregate model
///         across every reachable event-registration, principal, curator, reserve, and past-due state.
/// @dev Under ADR-0035 all events consume one uncapped shared reserve. Consequently declaration
///      order cannot change total junior delivery: each class contributes
///      `min(classPrincipal, remainingClassCurator)` and layer two contributes
///      `min(totalResidual, remainingSharedReserve)`. This invariant deliberately derives that
///      closed form without copying either production walk.
contract CommitmentLedgerInvariants is StdInvariant, Test {
    CommitmentLedgerInvariantCurator internal curator;
    CommitmentLedgerInvariantBackstop internal reserve;
    CommitmentLedgerInvariantManager internal manager;
    CommitmentLedgerInvariantHandler internal handler;
    CommitmentLedger internal ledger;

    function setUp() public {
        curator = new CommitmentLedgerInvariantCurator();
        reserve = new CommitmentLedgerInvariantBackstop();
        manager = new CommitmentLedgerInvariantManager(curator, reserve);
        ledger = manager.ledger();
        handler = new CommitmentLedgerInvariantHandler(manager, curator, reserve);
        handler.seed();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = CommitmentLedgerInvariantHandler.upsert.selector;
        selectors[1] = CommitmentLedgerInvariantHandler.release.selector;
        selectors[2] = CommitmentLedgerInvariantHandler.sync.selector;
        selectors[3] = CommitmentLedgerInvariantHandler.setPastDue.selector;
        selectors[4] = CommitmentLedgerInvariantHandler.setPool.selector;
        selectors[5] = CommitmentLedgerInvariantHandler.setReserve.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_conservativeResidualMatchesIndependentSharedReserveModel() public view {
        uint256[5] memory remainingCurator;
        uint256 pastDueResidual;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 classId = i + 1;
            uint256 pastDue = manager.pastDuePrincipal(classId);
            uint256 pool = curator.poolBalance(classId);
            uint256 curatorForPastDue = _min(pastDue, pool);
            pastDueResidual += pastDue - curatorForPastDue;
            remainingCurator[i] = pool - curatorForPastDue;
        }

        uint256 liveReserve = reserve.coverageReserve();
        uint256 pastDueLayerTwo = _min(pastDueResidual, liveReserve);
        liveReserve -= pastDueLayerTwo;

        uint256[5] memory declaredByClass;
        uint256 declaredGross;
        uint256 count = ledger.eventCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 eventId = ledger.eventAt(i);
            (uint256 classId,,, uint256 principal) = ledger.eventInfo(eventId);
            assertGe(classId, 1, "registered event lost its class");
            assertLe(classId, Config.NUM_CLASSES, "registered event class escaped the configured set");
            declaredByClass[classId - 1] += principal;
            declaredGross += principal;
        }

        uint256 declaredCurator;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            declaredCurator += _min(declaredByClass[i], remainingCurator[i]);
        }
        uint256 declaredAfterCurator = declaredGross - declaredCurator;
        uint256 declaredLayerTwo = _min(declaredAfterCurator, liveReserve);
        uint256 expectedResidual = pastDueResidual - pastDueLayerTwo + declaredAfterCurator - declaredLayerTwo;
        uint256 expectedPastDueSenior = pastDueResidual - pastDueLayerTwo;

        (uint256 actualResidual, uint256 actualPastDueSenior) = ledger.conservativeResiduals();
        assertEq(actualResidual, expectedResidual, "CONSERVATIVE RESIDUAL != INDEPENDENT SHARED-RESERVE MODEL");
        assertEq(actualPastDueSenior, expectedPastDueSenior, "PAST-DUE SENIOR RESIDUAL != INDEPENDENT MODEL");
    }

    function invariant_eventEnumerationRemainsUniqueAndBounded() public view {
        uint256 count = ledger.eventCount();
        assertLe(count, 8, "LIVE EVENT SET EXCEEDED HANDLER BOUND");
        for (uint256 i = 0; i < count; ++i) {
            uint256 left = ledger.eventAt(i);
            assertTrue(handler.known(left), "ENUMERATED EVENT IS NOT LIVE IN THE DRIVER");
            for (uint256 j = i + 1; j < count; ++j) {
                assertTrue(left != ledger.eventAt(j), "DUPLICATE EVENT IN LIVE ENUMERATION");
            }
        }
    }

    function test_seedExercisesNonzeroDeclaredPastDueCuratorAndReserveInputs() public view {
        assertEq(ledger.eventCount(), 1);
        assertEq(manager.pastDuePrincipal(2), 10e18);
        assertEq(curator.poolBalance(1), 25e18);
        assertEq(reserve.coverageReserve(), 30e18);
        (uint256 residual,) = ledger.conservativeResiduals();
        assertGt(residual, 0, "seed made the conservative calculation vacuous");
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
