// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {CommitmentLedgerFactory} from "../../src/CommitmentLedgerFactory.sol";
import {ICommitmentLedger} from "../../src/interfaces/ICommitmentLedger.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev The real manager is the only caller of the ledger. This harness keeps that caller
/// relationship intact while exposing the manager's principal getter and the delegatecall path.
contract CommitmentLedgerManagerHarness {
    CommitmentLedger public immutable ledger;
    mapping(uint256 eventId => uint256) internal principal;
    mapping(uint256 eventId => bool) internal registered;
    mapping(uint256 classId => uint256) internal pastDue;
    address internal curatorModule;
    address internal backstopModule;

    constructor() {
        ledger = new CommitmentLedger(address(this));
    }

    function setPrincipal(uint256 eventId, uint256 amount) external {
        principal[eventId] = amount;
        if (!registered[eventId]) {
            registered[eventId] = true;
            ledger.register(eventId, 1, amount);
        } else {
            ledger.updatePrincipal(eventId, amount);
        }
    }

    function register(uint256 eventId, uint256 classId, uint256 amount) external {
        principal[eventId] = amount;
        registered[eventId] = true;
        ledger.register(eventId, classId, amount);
    }

    function updatePrincipal(uint256 eventId, uint256 amount) external {
        principal[eventId] = amount;
        ledger.updatePrincipal(eventId, amount);
    }

    function setImpairmentInputs(address curator_, address backstop_) external {
        curatorModule = curator_;
        backstopModule = backstop_;
    }

    function setPastDuePrincipal(uint256 classId, uint256 amount) external {
        pastDue[classId] = amount;
    }

    function pastDuePrincipal(uint256 classId) external view returns (uint256) {
        return pastDue[classId];
    }

    function backstop() external view returns (address) {
        return backstopModule;
    }

    function modules()
        external
        view
        returns (
            address bridge,
            address registry,
            address reserves,
            address controller,
            address curator,
            address oracle,
            address vault,
            address commitmentLedger
        )
    {
        return (address(0), address(0), address(0), address(0), curatorModule, address(0), address(0), address(ledger));
    }

    function defaultedContribution(uint256 eventId) external view returns (uint256) {
        return principal[eventId];
    }

    function sync(uint256 eventId, uint256 room, uint256 remainingPrincipal, uint256 covered)
        external
        returns (bool firstDraw)
    {
        return ledger.sync(eventId, room, remainingPrincipal, covered);
    }

    function release(uint256 eventId) external {
        ledger.release(eventId);
        registered[eventId] = false;
        principal[eventId] = 0;
    }

    function delegateCover(address backstop_, address asset, uint256 eventId, uint256 residual)
        external
        returns (uint256 covered)
    {
        (bool ok, bytes memory data) = address(ledger).delegatecall(
            abi.encodeCall(ICommitmentLedger.coverDelegate, (backstop_, asset, eventId, residual))
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        return abi.decode(data, (uint256));
    }
}

contract LedgerCuratorPools {
    mapping(uint256 classId => uint256) public poolBalance;

    function setPoolBalance(uint256 classId, uint256 amount) external {
        poolBalance[classId] = amount;
    }
}

contract LedgerBackstopReserve {
    uint256 public coverageReserve;

    function setCoverageReserve(uint256 amount) external {
        coverageReserve = amount;
    }
}

/// @dev Production DefaultManager entry points are nonReentrant.  This small guarded harness
///      preserves that lock around the delegatecall while a hostile backstop attempts to call
///      the same value-moving path recursively.
contract GuardedCommitmentLedgerManagerHarness is ReentrancyGuard {
    CommitmentLedger public immutable ledger;

    constructor() {
        ledger = new CommitmentLedger(address(this));
    }

    function delegateCover(address backstop, address asset, uint256 eventId, uint256 residual)
        external
        nonReentrant
        returns (uint256 covered)
    {
        (bool ok, bytes memory data) = address(ledger).delegatecall(
            abi.encodeCall(ICommitmentLedger.coverDelegate, (backstop, asset, eventId, residual))
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        return abi.decode(data, (uint256));
    }
}

contract LedgerBackstop {
    IERC20 internal immutable asset;
    uint256 internal available;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function setAvailable(uint256 amount) external {
        available = amount;
    }

    function coverShortfall(uint256, uint256 amount) external returns (uint256 covered) {
        covered = amount < available ? amount : available;
        uint256 balance = asset.balanceOf(address(this));
        if (covered > balance) covered = balance;
        if (covered != 0) require(asset.transfer(msg.sender, covered), "transfer");
        available -= covered;
    }
}

contract OverReportingBackstop {
    function coverShortfall(uint256, uint256 amount) external pure returns (uint256) {
        return amount + 1;
    }
}

contract NoDeliveryBackstop {
    function coverShortfall(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }
}

contract ReentrantLedgerBackstop {
    IERC20 internal immutable asset;
    GuardedCommitmentLedgerManagerHarness internal immutable manager;
    bool public attempted;
    bool public blocked;

    constructor(IERC20 asset_, GuardedCommitmentLedgerManagerHarness manager_) {
        asset = asset_;
        manager = manager_;
    }

    function coverShortfall(uint256 eventId, uint256 amount) external returns (uint256 covered) {
        if (!attempted) {
            attempted = true;
            try manager.delegateCover(address(this), address(asset), eventId, amount) returns (uint256) {
                // A successful recursive value-moving call would invalidate the lock proof.
            } catch {
                blocked = true;
            }
        }
        covered = amount;
        require(asset.transfer(msg.sender, covered), "transfer");
    }
}

contract CommitmentLedgerTest is Test {
    MockERC20 internal asset;
    CommitmentLedgerManagerHarness internal manager;
    CommitmentLedger internal ledger;

    function setUp() public {
        asset = new MockERC20("Ledger USDfr", "lUSDfr", 18);
        manager = new CommitmentLedgerManagerHarness();
        ledger = manager.ledger();
    }

    function test_factoryCreatesManagerOwnedLedger() public {
        CommitmentLedgerFactory factory = new CommitmentLedgerFactory();
        CommitmentLedger child = factory.create(address(manager));
        assertEq(child.manager(), address(manager));

        vm.expectRevert(CommitmentLedger.CommitmentLedger_ZeroManager.selector);
        factory.create(address(0));
    }

    function test_constructorRejectsZeroManager() public {
        vm.expectRevert(CommitmentLedger.CommitmentLedger_ZeroManager.selector);
        new CommitmentLedger(address(0));
    }

    function test_syncAndViewsTrackEachEventAndAggregate() public {
        manager.setPrincipal(7, 90);
        manager.setPrincipal(9, 80);

        vm.expectEmit(true, false, false, true, address(ledger));
        emit ICommitmentLedger.CommitmentSynced(7, 100, 90, 90, 90);
        assertTrue(manager.sync(7, 100, 90, 10));

        vm.expectEmit(true, false, false, true, address(ledger));
        emit ICommitmentLedger.CommitmentSynced(9, 50, 80, 50, 140);
        assertTrue(manager.sync(9, 50, 80, 5));

        (uint256 room7, uint256 principal7, uint256 deliverable7) = ledger.state(7);
        assertEq(room7, 100);
        assertEq(principal7, 90);
        assertEq(deliverable7, 90);
        assertEq(ledger.deliverable(9), 50);
        assertEq(ledger.deliverableAggregate(), 140);
        assertEq(ledger.remainingAggregate(), 150);
        assertEq(ledger.consumed(7), 10);
        assertEq(ledger.consumedAggregate(), 15);
        (uint256 classId, bool drawn, uint256 committedRoom, uint256 recordedPrincipal) = ledger.eventInfo(7);
        assertEq(classId, 1);
        assertTrue(drawn);
        assertEq(committedRoom, 100);
        assertEq(recordedPrincipal, 90);

        // The manager's live principal is authoritative for the view, so a repayment lowers
        // deliverability without pretending the committed room itself changed.
        manager.setPrincipal(7, 20);
        (,, deliverable7) = ledger.state(7);
        assertEq(deliverable7, 20);
        assertEq(ledger.deliverableAggregate(), 70);
    }

    function test_registerAndUpdateExposeInvalidClassDuplicateAndUnknownEventGuards() public {
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, 0));
        manager.register(1, 0, 100);

        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_InvalidClass.selector, 6));
        manager.register(1, 6, 100);

        manager.register(7, 2, 100);
        (uint256 classId,, uint256 remainingCoverage, uint256 remainingPrincipal) = ledger.eventInfo(7);
        assertEq(classId, 2, "raw harness must preserve the requested class");
        assertEq(remainingCoverage, 0);
        assertEq(remainingPrincipal, 100);

        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_AlreadyRegistered.selector, 7));
        manager.register(7, 3, 100);

        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_UnknownEvent.selector, 8));
        manager.updatePrincipal(8, 50);
    }

    function test_conservativeResidualsAccountsPastDueCuratorAndSharedReserveExactly() public {
        LedgerCuratorPools curator = new LedgerCuratorPools();
        LedgerBackstopReserve backstop = new LedgerBackstopReserve();
        manager.setImpairmentInputs(address(curator), address(backstop));

        curator.setPoolBalance(1, 70);
        curator.setPoolBalance(2, 30);
        manager.setPastDuePrincipal(1, 20);
        manager.setPastDuePrincipal(2, 50);
        backstop.setCoverageReserve(60);

        manager.register(11, 1, 100);
        manager.register(12, 2, 80);
        manager.register(13, 1, 10);
        assertTrue(manager.sync(11, 100, 100, 1), "fixture must include a drawn row");

        (uint256 residual, uint256 pastDueSenior) = ledger.conservativeResiduals();
        assertEq(residual, 100, "gross 260 less past-due junior 70 and declared junior 90");
        assertEq(pastDueSenior, 0, "past-due curator and prioritized reserve cover the full past-due cohort");
    }

    function test_conservativeResidualsIsDeclarationOrderIndependentUnderADR0035() public {
        LedgerCuratorPools curator = new LedgerCuratorPools();
        LedgerBackstopReserve backstop = new LedgerBackstopReserve();
        curator.setPoolBalance(1, 70);
        curator.setPoolBalance(2, 30);
        backstop.setCoverageReserve(60);

        CommitmentLedgerManagerHarness forwardManager = new CommitmentLedgerManagerHarness();
        CommitmentLedgerManagerHarness reverseManager = new CommitmentLedgerManagerHarness();
        forwardManager.setImpairmentInputs(address(curator), address(backstop));
        reverseManager.setImpairmentInputs(address(curator), address(backstop));
        forwardManager.setPastDuePrincipal(1, 20);
        forwardManager.setPastDuePrincipal(2, 50);
        reverseManager.setPastDuePrincipal(1, 20);
        reverseManager.setPastDuePrincipal(2, 50);

        forwardManager.register(11, 1, 100);
        forwardManager.register(12, 2, 80);
        forwardManager.register(13, 1, 10);
        reverseManager.register(13, 1, 10);
        reverseManager.register(12, 2, 80);
        reverseManager.register(11, 1, 100);

        (uint256 forwardResidual, uint256 forwardPastDueSenior) = forwardManager.ledger().conservativeResiduals();
        (uint256 reverseResidual, uint256 reversePastDueSenior) = reverseManager.ledger().conservativeResiduals();
        assertEq(forwardResidual, 100);
        assertEq(reverseResidual, forwardResidual, "one shared uncapped reserve makes declaration order immaterial");
        assertEq(reversePastDueSenior, forwardPastDueSenior);
    }

    function test_principalRetainsTheFullW6WordWidth() public {
        uint256 large = uint256(type(uint120).max) + 1;
        manager.setPrincipal(1, large);
        (,,, uint256 recorded) = ledger.eventInfo(1);
        assertEq(recorded, large);

        manager.setPrincipal(1, type(uint256).max);
        (,,, recorded) = ledger.eventInfo(1);
        assertEq(recorded, type(uint256).max);
    }

    function test_coverageRetainsTheFullW6WordWidth() public {
        uint256 maximum = type(uint256).max;
        manager.setPrincipal(1, maximum);
        assertTrue(manager.sync(1, maximum, maximum, 1));
        (,, uint256 recorded,) = ledger.eventInfo(1);
        assertEq(recorded, maximum);
    }

    function test_syncZeroCoveredLeavesTheRegisteredEventUndrawn() public {
        manager.setPrincipal(1, 100);
        assertFalse(manager.sync(1, 100, 100, 0));
        assertEq(ledger.eventCount(), 1);
        assertEq(ledger.eventAt(0), 1);
        assertEq(ledger.deliverableAggregate(), 0);
        assertEq(ledger.remainingAggregate(), 0);
        assertEq(ledger.consumedAggregate(), 0);
        (uint256 room, uint256 principal_, uint256 deliverable) = ledger.state(1);
        assertEq(room, 0);
        assertEq(principal_, 100);
        assertEq(deliverable, 0);
    }

    function test_releaseIsExactOnceAndDoesNotStrandState() public {
        manager.setPrincipal(4, 100);
        manager.sync(4, 80, 100, 25);

        vm.expectEmit(true, false, false, true, address(ledger));
        emit ICommitmentLedger.CommitmentReleased(4, 80, 0);
        manager.release(4);
        assertEq(ledger.deliverableAggregate(), 0);
        assertEq(ledger.remainingAggregate(), 0);
        assertEq(ledger.consumedAggregate(), 0);
        assertEq(ledger.consumed(4), 0);

        // A second release is an intentional no-op, not a revert or an underflow.
        manager.release(4);
        assertEq(ledger.deliverableAggregate(), 0);
        assertEq(ledger.remainingAggregate(), 0);
    }

    function test_releasePreservesDeclarationOrderForTheTwoSidedLadder() public {
        manager.setPrincipal(1, 100);
        manager.setPrincipal(2, 100);
        manager.setPrincipal(3, 100);
        manager.release(2);

        assertEq(ledger.eventCount(), 2);
        assertEq(ledger.eventAt(0), 1);
        assertEq(ledger.eventAt(1), 3);
    }

    function test_syncUpdatesAExistingEventWithoutDoubleDrawing() public {
        manager.setPrincipal(3, 100);
        manager.sync(3, 100, 100, 30);
        manager.setPrincipal(3, 60);
        assertFalse(manager.sync(3, 70, 60, 20));

        assertEq(ledger.consumed(3), 50);
        assertEq(ledger.consumedAggregate(), 50);
        assertEq(ledger.remainingAggregate(), 70);
        assertEq(ledger.deliverable(3), 60);
        assertEq(ledger.deliverableAggregate(), 60);
    }

    function test_unauthorizedSyncAndReleaseRevertWithCaller() public {
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, address(this)));
        ledger.register(1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, address(this)));
        ledger.updatePrincipal(1, 1);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, address(this)));
        ledger.sync(1, 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(CommitmentLedger.CommitmentLedger_NotManager.selector, address(this)));
        ledger.release(1);
    }

    function test_coverDelegateRequiresDelegatecallContext() public {
        LedgerBackstop backstop = new LedgerBackstop(asset);
        vm.expectRevert(CommitmentLedger.CommitmentLedger_DirectCall.selector);
        ledger.coverDelegate(address(backstop), address(asset), 1, 10);
    }

    function test_coverDelegateTransfersExactlyWhatBackstopReports() public {
        LedgerBackstop backstop = new LedgerBackstop(asset);
        asset.mint(address(backstop), 40);
        backstop.setAvailable(40);

        uint256 covered = manager.delegateCover(address(backstop), address(asset), 1, 30);
        assertEq(covered, 30);
        assertEq(asset.balanceOf(address(manager)), 30);
        assertEq(asset.balanceOf(address(backstop)), 10);
    }

    function test_coverDelegateBlocksReentrantValueMovingCall() public {
        GuardedCommitmentLedgerManagerHarness guarded = new GuardedCommitmentLedgerManagerHarness();
        ReentrantLedgerBackstop backstop = new ReentrantLedgerBackstop(asset, guarded);
        asset.mint(address(backstop), 30);

        uint256 covered = guarded.delegateCover(address(backstop), address(asset), 7, 30);

        assertEq(covered, 30);
        assertTrue(backstop.attempted(), "backstop callback was not exercised");
        assertTrue(backstop.blocked(), "manager reentrancy lock did not block recursive coverage");
        assertEq(asset.balanceOf(address(guarded)), 30, "outer coverage delivery changed");
        assertEq(asset.balanceOf(address(backstop)), 0, "backstop balance was not debited exactly once");
    }

    function test_coverDelegateRejectsOverReportAndNoDelivery() public {
        OverReportingBackstop over = new OverReportingBackstop();
        vm.expectRevert(
            abi.encodeWithSelector(CommitmentLedger.DefaultManager_BackstopContractViolated.selector, 10, 11, 0)
        );
        manager.delegateCover(address(over), address(asset), 1, 10);

        NoDeliveryBackstop none = new NoDeliveryBackstop();
        vm.expectRevert(
            abi.encodeWithSelector(CommitmentLedger.DefaultManager_BackstopContractViolated.selector, 10, 10, 0)
        );
        manager.delegateCover(address(none), address(asset), 1, 10);
    }

    function test_coverDelegateZeroResidualOrBackstopIsNoOp() public {
        LedgerBackstop backstop = new LedgerBackstop(asset);
        assertEq(manager.delegateCover(address(backstop), address(asset), 1, 0), 0);
        assertEq(manager.delegateCover(address(0), address(asset), 1, 10), 0);
    }

    function test_deliverableAggregateUsesBoundedLiveEventSet() public {
        uint256 count = 32;
        for (uint256 i = 1; i <= count; ++i) {
            manager.setPrincipal(i, 100);
            manager.sync(i, 100, 100, 1);
        }
        uint256 before = gasleft();
        uint256 aggregate = ledger.deliverableAggregate();
        uint256 used = before - gasleft();
        assertEq(aggregate, count * 100);
        // This is a bounded-set guard, not a claim of O(1): the production ledger must not grow
        // without a corresponding live commitment, and this upper bound makes the loop's cost
        // explicit for the largest set exercised by the validation fixture.
        assertLt(used, 300_000, "bounded live event set exceeded its read budget");
    }
}
