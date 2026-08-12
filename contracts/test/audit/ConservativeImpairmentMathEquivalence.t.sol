// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";
import {ConservativeImpairmentMath} from "../../src/ConservativeImpairmentMath.sol";
import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {ICommitmentLedger} from "../../src/interfaces/ICommitmentLedger.sol";
import {IConservativeImpairmentBook} from "../../src/interfaces/IConservativeImpairmentBook.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Independent reconstruction of ADR-0022 from the ledger's published event rows. W7 retires
///      the old aggregate-only pre-extraction differential: event count, class, drawn state and
///      per-event principal are now necessary inputs, so an oracle that sees only class aggregates
///      is proven incapable of grading the implementation.
contract PerEventImpairmentReference {
    struct Snapshot {
        address backstop;
        address registry;
        address vault;
        address ledger;
        address curator;
        uint256 gross;
        uint256 pastDueGross;
        uint256 pastDueResidual;
        uint256 reserveAfterPastDue;
        uint256 pastDueLayerTwo;
        uint256[5] curatorAfterPastDue;
    }

    struct Walk {
        uint256 reserve;
        uint256 delivered;
        uint256[5] curator;
    }

    struct EventRow {
        uint256 classId;
        bool drawn;
        uint256 room;
        uint256 principal;
    }

    function pendingSeniorImpairment(address book) external view returns (uint256) {
        IConservativeImpairmentBook source = IConservativeImpairmentBook(book);
        Snapshot memory s = _snapshot(source);
        if (s.gross == 0) return 0;
        (uint256 residual, uint256 pastDueSenior) = _seniorResidual(ICommitmentLedger(s.ledger), s);
        return ICollateralRegistry(s.registry).conservativeSeniorMark(
            pastDueSenior, residual, s.vault, source.pastDueReliefAnchor()
        );
    }

    function _snapshot(IConservativeImpairmentBook source) private view returns (Snapshot memory s) {
        (, s.registry,,, s.curator,, s.vault, s.ledger) = source.modules();
        for (uint256 classIndex = 0; classIndex < Config.NUM_CLASSES; ++classIndex) {
            uint256 classId = classIndex + 1;
            uint256 pastDue = source.pastDuePrincipal(classId);
            uint256 pool = s.curator == address(0) ? 0 : ICuratorModule(s.curator).poolBalance(classId);
            uint256 curatorTake = _min(pastDue, pool);
            s.pastDueGross += pastDue;
            s.pastDueResidual += pastDue - curatorTake;
            s.curatorAfterPastDue[classIndex] = pool - curatorTake;
        }

        ICommitmentLedger ledger = ICommitmentLedger(s.ledger);
        uint256 count = ledger.eventCount();
        for (uint256 i = 0; i < count; ++i) {
            (,,, uint256 principal) = ledger.eventInfo(ledger.eventAt(i));
            s.gross += principal;
        }
        s.gross += s.pastDueGross;
        if (s.gross == 0) return s;

        s.backstop = source.backstop();
        if (s.backstop != address(0)) {
            s.reserveAfterPastDue = ICascadeBackstop(s.backstop).coverageReserve();
            s.pastDueLayerTwo = _min(s.pastDueResidual, s.reserveAfterPastDue);
            s.reserveAfterPastDue -= s.pastDueLayerTwo;
        }
    }

    function _seniorResidual(ICommitmentLedger ledger, Snapshot memory s)
        private
        view
        returns (uint256 residual, uint256 pastDueSenior)
    {
        uint256 forward = _declaredDelivery(ledger, s, false);
        uint256 reverse = _declaredDelivery(ledger, s, true);
        uint256 declaredJunior = _min(forward, reverse);
        uint256 pastDueJunior = s.pastDueGross - s.pastDueResidual + s.pastDueLayerTwo;
        residual = s.gross - pastDueJunior - declaredJunior;
        pastDueSenior = s.pastDueResidual - s.pastDueLayerTwo;
    }

    function _declaredDelivery(ICommitmentLedger ledger, Snapshot memory s, bool reverse)
        private
        view
        returns (uint256 delivered)
    {
        Walk memory walk;
        walk.reserve = s.reserveAfterPastDue;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            walk.curator[i] = s.curatorAfterPastDue[i];
        }
        uint256 count = ledger.eventCount();
        for (uint256 offset = 0; offset < count; ++offset) {
            uint256 index = reverse ? count - 1 - offset : offset;
            _applyEvent(ledger, ledger.eventAt(index), s, walk);
        }
        delivered = walk.delivered;
    }

    function _applyEvent(ICommitmentLedger ledger, uint256 eventId, Snapshot memory s, Walk memory walk) private view {
        EventRow memory row;
        (row.classId, row.drawn, row.room, row.principal) = ledger.eventInfo(eventId);
        if (row.principal == 0) return;

        uint256 curatorTake = _min(row.principal, walk.curator[row.classId - 1]);
        walk.curator[row.classId - 1] -= curatorTake;
        row.principal -= curatorTake;
        walk.delivered += curatorTake;
        if (row.principal == 0 || walk.reserve == 0 || s.backstop == address(0)) return;

        uint256 layerTwo = _min(row.principal, walk.reserve);
        walk.delivered += layerTwo;
        walk.reserve -= layerTwo;
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}

/// @dev Settable manager/curator/backstop/vault double around the real CommitmentLedger. Unlike
///      the retired fixture, its declared cohort can be constructed only from registered events;
///      this keeps the differential's synthetic state inside W7's encoded data model.
contract ImpairmentBookDouble is IConservativeImpairmentBook {
    error ForbiddenBackstopRead();

    CommitmentLedger public immutable ledger;
    address public immutable registryAddress;

    uint256[6] public declared;
    uint256[6] public pastDue;
    uint256[6] public drawn;
    uint256[6] public pool;
    uint256 public reserve;
    uint256 public vaultAssets = type(uint128).max;
    uint256 public reliefAnchor;
    address public backstopAddress;
    bool public backstopReverts;

    constructor(address registry_) {
        registryAddress = registry_;
        ledger = new CommitmentLedger(address(this));
        backstopAddress = address(this);
    }

    function addEvent(uint256 eventId, uint256 classId, uint256 principal, bool hasDrawn, uint256 remainingRoom)
        external
    {
        ledger.register(eventId, classId, principal);
        declared[classId] += principal;
        if (hasDrawn && principal != 0) {
            drawn[classId] += principal;
            ledger.sync(eventId, remainingRoom, principal, 1);
        }
    }

    function resyncEvent(uint256 eventId, uint256 remainingRoom, uint256 principal, uint256 covered) external {
        ledger.sync(eventId, remainingRoom, principal, covered);
    }

    function setPool(uint256 classId, uint256 amount) external {
        pool[classId] = amount;
    }

    function setPastDue(uint256 classId, uint256 amount) external {
        pastDue[classId] = amount;
    }

    /// @dev Lets the retired aggregate-precondition proof inject its formerly dangerous state.
    ///      W7's calculator must remain bound to event rows rather than reviving these aggregates.
    function setLegacyAggregates(uint256 classId, uint256 declared_, uint256 pastDue_, uint256 drawn_) external {
        declared[classId] = declared_;
        pastDue[classId] = pastDue_;
        drawn[classId] = drawn_;
    }

    function setLayerTwo(uint256 reserve_, uint16, uint256) external {
        reserve = reserve_;
    }

    function setBackstop(address backstop_) external {
        backstopAddress = backstop_;
    }

    function setVaultAssets(uint256 assets) external {
        vaultAssets = assets;
    }

    function setReliefAnchor(uint256 anchor) external {
        reliefAnchor = anchor;
    }

    function armBackstopRevert(bool armed) external {
        backstopReverts = armed;
    }

    function declaredDefaultedPrincipal(uint256 classId) external view returns (uint256) {
        return declared[classId];
    }

    function pastDuePrincipal(uint256 classId) external view returns (uint256) {
        return pastDue[classId];
    }

    function drawnDefaultPrincipal(uint256 classId) external view returns (uint256) {
        return drawn[classId];
    }

    function liveDefaultCoverageConsumed() external view returns (uint256) {
        return ledger.consumedAggregate();
    }

    function liveDefaultCoverageRemaining() external view returns (uint256) {
        return ledger.deliverableAggregate();
    }

    function backstop() external view returns (address) {
        return backstopAddress;
    }

    function pastDueReliefAnchor() external view returns (uint256) {
        return reliefAnchor;
    }

    function modules() external view returns (address, address, address, address, address, address, address, address) {
        return (
            address(0),
            registryAddress,
            address(0),
            address(0),
            address(this),
            address(0),
            address(this),
            address(ledger)
        );
    }

    function poolBalance(uint256 classId) external view returns (uint256) {
        return pool[classId];
    }

    function totalAssets() external view returns (uint256) {
        return vaultAssets;
    }

    function coverageReserve() external view returns (uint256) {
        if (backstopReverts) revert ForbiddenBackstopRead();
        return reserve;
    }

    function coverageCapacity() external view returns (uint256) {
        if (backstopReverts) revert ForbiddenBackstopRead();
        return _capacityAt(reserve);
    }

    function coverageCapacityAt(uint256 reserve_) external view returns (uint256) {
        if (backstopReverts) revert ForbiddenBackstopRead();
        return _capacityAt(reserve_);
    }

    function coverageCapParameters() external view returns (uint16 proportionalBps, uint256 absoluteCap_) {
        if (backstopReverts) revert ForbiddenBackstopRead();
        return (uint16(Config.BPS), type(uint256).max);
    }

    function _capacityAt(uint256 reserve_) private pure returns (uint256) {
        return reserve_;
    }
}

/// @title ConservativeImpairmentMath — W7 event-aware differential
/// @notice The production calculator delegates exact cascade measurement to CommitmentLedger.
///         These tests compare that result with a separately structured reconstruction over the
///         ledger's published rows, and pin cases that the retired aggregate oracle could not
///         distinguish.
contract ConservativeImpairmentMathEquivalenceTest is Test {
    uint256 internal constant MAX_AMOUNT = 2_000_000e18;

    ConservativeImpairmentMath internal math;
    PerEventImpairmentReference internal oracle;
    ImpairmentBookDouble internal book;
    CollateralRegistry internal registry;

    function setUp() public {
        math = new ConservativeImpairmentMath();
        oracle = new PerEventImpairmentReference();
        registry = new CollateralRegistry();
        book = new ImpairmentBookDouble(address(registry));
        vm.warp(365 days);
    }

    function testFuzz_eventAwareMathMatchesIndependentReference(
        uint256[5] memory eventSeeds,
        uint256[5] memory classSeeds,
        uint256 backstopSeed,
        uint256 policySeed
    ) public {
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            book.setPool(i + 1, uint256(uint96(classSeeds[i])) % (MAX_AMOUNT + 1));
            book.setPastDue(i + 1, uint256(uint96(classSeeds[i] >> 96)) % (MAX_AMOUNT + 1));
        }
        for (uint256 i = 0; i < 5; ++i) {
            uint256 seed = eventSeeds[i];
            uint256 principal = uint256(uint96(seed)) % (MAX_AMOUNT + 1);
            uint256 room = uint256(uint96(seed >> 96)) % (MAX_AMOUNT + 1);
            uint256 classId = (seed >> 192) % Config.NUM_CLASSES + 1;
            bool hasDrawn = (seed >> 200) & 1 != 0;
            book.addEvent(i + 1, classId, principal, hasDrawn, room);
        }

        book.setLayerTwo(
            uint256(uint96(backstopSeed)) % (5 * MAX_AMOUNT + 1),
            uint16((backstopSeed >> 192) % (Config.BPS + 1)),
            uint256(uint96(backstopSeed >> 96)) % (5 * MAX_AMOUNT + 1)
        );
        book.setVaultAssets(uint256(uint96(policySeed)) % (10 * MAX_AMOUNT + 1));
        uint256 elapsed = uint256(uint32(policySeed >> 96)) % (2 * Config.DEFAULT_REDEEM_COOLDOWN + 1);
        book.setReliefAnchor(block.timestamp - elapsed);

        assertEq(
            math.pendingSeniorImpairment(address(book)),
            oracle.pendingSeniorImpairment(address(book)),
            "event-aware calculator diverged from independent ladder"
        );
    }

    function test_ADR0035_eventPartitionDoesNotChangeSharedReserveDelivery() public {
        ImpairmentBookDouble one = new ImpairmentBookDouble(address(registry));
        ImpairmentBookDouble three = new ImpairmentBookDouble(address(registry));
        one.setLayerTwo(400_000e18, 5_000, type(uint256).max);
        three.setLayerTwo(400_000e18, 5_000, type(uint256).max);
        one.addEvent(1, 1, 600_000e18, false, 0);
        three.addEvent(1, 1, 200_000e18, false, 0);
        three.addEvent(2, 1, 200_000e18, false, 0);
        three.addEvent(3, 1, 200_000e18, false, 0);

        assertEq(one.declaredDefaultedPrincipal(1), three.declaredDefaultedPrincipal(1));
        assertEq(one.drawnDefaultPrincipal(1), three.drawnDefaultPrincipal(1));
        assertEq(math.pendingSeniorImpairment(address(one)), 200_000e18, "one event did not use shared reserve");
        assertEq(math.pendingSeniorImpairment(address(three)), 200_000e18, "event partition changed shared reserve");
        assertEq(
            math.pendingSeniorImpairment(address(three)),
            oracle.pendingSeniorImpairment(address(three)),
            "independent model must preserve ADR-0035 event-partition equivalence"
        );
    }

    function test_fundedPoolThatStrandsNoRoomCreditsEveryDeliverableWei() public {
        book.setPool(1, 15_000e18);
        book.setLayerTwo(400_000e18, 5_000, type(uint256).max);
        book.addEvent(1, 1, 390_000e18, true, 190_000e18);
        book.addEvent(2, 1, 390_000e18, true, 185_000e18);

        uint256 mark = math.pendingSeniorImpairment(address(book));
        assertEq(mark, 365_000e18, "15,000 curator plus 400,000 reserve must be deliverable");
        assertEq(mark, oracle.pendingSeniorImpairment(address(book)), "funded control reference mismatch");
    }

    function test_mixedDrawnAndUndrawnUseTheSameSharedReserve() public {
        book.setLayerTwo(400_000e18, 5_000, type(uint256).max);
        book.addEvent(1, 1, 150_000e18, true, 90_000e18);
        book.addEvent(2, 1, 200_000e18, false, 0);

        assertEq(math.pendingSeniorImpairment(address(book)), oracle.pendingSeniorImpairment(address(book)));
        assertEq(math.pendingSeniorImpairment(address(book)), 0, "shared reserve fully funds the mixed cohort");
    }

    function test_zeroImpairmentNeverTouchesTheBackstop() public {
        book.armBackstopRevert(true);
        assertEq(math.pendingSeniorImpairment(address(book)), 0, "empty book must mark at zero");
        assertEq(oracle.pendingSeniorImpairment(address(book)), 0, "reference must share the early return");

        book.addEvent(1, 1, 1, false, 0);
        vm.expectRevert(ImpairmentBookDouble.ForbiddenBackstopRead.selector);
        math.pendingSeniorImpairment(address(book));
    }

    function test_unwiredBackstopLeavesDeclaredPrincipalWithSeniors() public {
        book.setBackstop(address(0));
        book.addEvent(1, 1, 100e18, false, 0);
        assertEq(math.pendingSeniorImpairment(address(book)), 100e18);
        assertEq(math.pendingSeniorImpairment(address(book)), oracle.pendingSeniorImpairment(address(book)));
    }

    function test_consumedAggregateDoesNotMoveTheMarkWhenRoomAndPrincipalDoNotMove() public {
        book.setLayerTwo(900e18, 10_000, type(uint256).max);
        book.addEvent(1, 1, 1_000e18, true, 500e18);
        uint256 before = math.pendingSeniorImpairment(address(book));
        uint256 consumedBefore = book.liveDefaultCoverageConsumed();
        book.resyncEvent(1, 500e18, 1_000e18, 777e18);
        assertGt(book.liveDefaultCoverageConsumed(), consumedBefore, "control: consumed must move");
        assertEq(math.pendingSeniorImpairment(address(book)), before, "consumed aggregate was subtracted twice");
    }

    function testFuzz_pastDueReliefRampStillMatchesIndependentReference(uint32 elapsedIn) public {
        book.setPastDue(1, 600_000e18);
        book.setLayerTwo(0, 0, 0);
        book.setVaultAssets(1_200_000e18);
        uint256 elapsed = uint256(elapsedIn) % (2 * Config.DEFAULT_REDEEM_COOLDOWN + 1);
        book.setReliefAnchor(block.timestamp - elapsed);

        uint256 mark = math.pendingSeniorImpairment(address(book));
        assertEq(mark, oracle.pendingSeniorImpairment(address(book)), "relief-ramp reference mismatch");
        book.setReliefAnchor(block.timestamp - elapsed - 1);
        assertGe(math.pendingSeniorImpairment(address(book)), mark, "past-due mark fell as relief elapsed");
    }
}
