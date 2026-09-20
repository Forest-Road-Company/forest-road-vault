// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualExposure} from "../../src/interfaces/IAccrualExposure.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Fixed-ABI endpoint fixture; no economic token/controller behavior is simulated here.
contract RegistryAccrualEndpoint {
    mapping(bytes4 => bytes) private replies;
    bool private failed;

    function reply(bytes4 selector, bytes memory data) external {
        replies[selector] = data;
    }

    function fail(bool value) external {
        failed = value;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        require(!failed, "fixture endpoint failure");
        return replies[msg.sig];
    }
}

/// @dev Authoritative real Book with test-only authenticated-fact and peripheral identity adapters.
contract RegistryAccrualSource is IAccrualExposure {
    using AccrualBook for AccrualBook.Book;

    AccrualBook.Book private book;
    CollateralRegistry public immutable registry;
    RegistryAccrualEndpoint public immutable token;
    RegistryAccrualEndpoint public immutable controller;
    RegistryAccrualEndpoint public immutable bridge;
    Modules private configured;
    bool public busy;
    uint256 public reserved;
    mapping(uint256 => uint256) public nativePosted;

    struct Identity {
        uint256 classId;
        bytes32 borrower;
        bytes32 stateId;
    }

    mapping(uint256 => Identity) private identities;

    error Fixture_Busy();
    error Fixture_BadExposureKind();

    constructor(CollateralRegistry registry_) {
        registry = registry_;
        token = new RegistryAccrualEndpoint();
        controller = new RegistryAccrualEndpoint();
        bridge = new RegistryAccrualEndpoint();
        configured = Modules(
            address(token),
            address(controller),
            address(this),
            address(this),
            address(bridge),
            address(registry_),
            address(this)
        );
        token.reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(this)));
        controller.reply(bytes4(keccak256("modules()")), abi.encode(address(token), address(0), address(this)));
        bridge.reply(bytes4(keccak256("modules()")), abi.encode(address(registry_), address(0)));
        book.initialize(uint64(block.timestamp), 0);
    }

    function setModules(Modules memory value) external {
        configured = value;
    }

    function setBusy(bool value) external {
        busy = value;
    }

    function setReserved(uint256 value) external {
        reserved = value;
    }

    function accrualModules() external view returns (Modules memory) {
        return configured;
    }

    function accrualDelivery() external pure returns (Delivery memory d) {
        return d;
    }

    function accrualSnapshot() external view returns (Snapshot memory s) {
        AccrualBook.Snapshot memory b = book.snapshot(uint64(block.timestamp));
        s.gross = b.gross;
        s.unposted = b.unposted;
        s.unissued = b.unissued;
        s.seniorUnissued = b.seniorUnissued;
        s.feeUnissued = b.feeUnissued;
        s.accruedThrough = b.accruedThrough;
        s.fresh = b.fresh;
        s.enabled = true;
    }

    function requireAccrualIdle() public view {
        if (busy) revert Fixture_Busy();
    }

    function requireAccrualFresh() external view {
        requireAccrualIdle();
        book.requireFresh(uint64(block.timestamp));
    }

    function accrualReservedExposure() external view returns (uint256) {
        return reserved;
    }

    function accrualExposure(uint8 kind, bytes32 identity) external view returns (uint256) {
        if (kind == 0) return book.snapshot(uint64(block.timestamp)).unposted;
        if (kind > 3) revert Fixture_BadExposureKind();
        if (kind == 3 && identity == 0) return 0;
        return book.groupUnposted(_key(kind, identity), uint64(block.timestamp));
    }

    function materializeAccrued(uint8) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function stream(uint256 id, uint256 classId, bytes32 borrower, bytes32 stateId, uint256 amount, uint64 duration)
        external
    {
        _register(id, classId, borrower, stateId);
        book.open(id, amount, uint64(block.timestamp), uint64(block.timestamp) + duration);
    }

    function earned(uint256 id, uint256 classId, bytes32 borrower, bytes32 stateId, uint256 amount) external {
        _register(id, classId, borrower, stateId);
        book.creditStoppedCorrection(id, amount, uint64(block.timestamp));
    }

    function finish() external {
        book.finishNext(uint64(block.timestamp));
    }

    function post(uint256 id) external returns (uint256 amount) {
        requireAccrualIdle();
        book.requireFresh(uint64(block.timestamp));
        busy = true;
        amount = book.takePosting(id, uint64(block.timestamp));
        nativePosted[id] += amount;
        Identity memory i = identities[id];
        registry.recordAccruedExposure(i.classId, i.borrower, i.stateId, amount);
        busy = false;
    }

    function directPost(uint256 classId, bytes32 borrower, bytes32 stateId, uint256 amount) external {
        registry.recordAccruedExposure(classId, borrower, stateId, amount);
    }

    function attack(bytes memory call_) external returns (bool ok, bytes memory result) {
        busy = true;
        (ok, result) = address(registry).call(call_);
        busy = false;
    }

    function _register(uint256 id, uint256 classId, bytes32 borrower, bytes32 stateId) private {
        identities[id] = Identity(classId, borrower, stateId);
        book.register(id, [_key(1, bytes32(classId)), _key(2, borrower), _key(3, stateId)], uint64(block.timestamp));
    }

    function _key(uint8 kind, bytes32 identity) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, identity));
    }
}

contract CollateralRegistryAccrualTest is Test {
    uint256 private constant MAX = type(uint256).max / 10_000;
    bytes32 private constant LOCATION = 0xd1052ad481f6f823017e987ee43475f3a84883a50e791c5b4260ba144e440700;
    bytes32 private constant B1 = keccak256("borrower one");
    bytes32 private constant B2 = keccak256("borrower two");
    bytes32 private constant S1 = keccak256("state one");
    bytes32 private constant S2 = keccak256("state two");
    CollateralRegistry private r;
    RegistryAccrualSource private source;
    address private implementation;

    function setUp() public {
        vm.warp(1_900_000_000);
        implementation = address(new CollateralRegistry());
        r = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    implementation, abi.encodeCall(CollateralRegistry.initialize, (address(this), address(this)))
                )
            )
        );
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            r.setClass(c, _class(10_000));
        }
        r.setBorrowerLimit(10_000);
        r.setStateLimit(10_000);
        r.setConcentrationFloor(0);
        r.grantRole(Roles.CREDIT_ROLE, address(this));
        source = new RegistryAccrualSource(r);
    }

    function test_bindingPreservesEveryHistoricalSlotAndIsPermanent() public {
        r.recordExposureIncrease(1, B1, S1, 100);
        bytes32 before_ = _legacyHash();
        _bind();
        assertEq(_legacyHash(), before_);
        assertEq(vm.load(address(r), bytes32(uint256(LOCATION) + 14)), bytes32(uint256(uint160(address(source)))));
        assertEq(r.accrualReserve(), address(source));
        vm.expectRevert(CollateralRegistry.Registry_AccrualAlreadyBound.selector);
        r.setAccrualReserve(address(source));
    }

    function test_bindingIsGovernedAndRejectsWrongRegistryAndTokenRoute() public {
        vm.prank(address(123));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(123), bytes32(0))
        );
        r.setAccrualReserve(address(source));
        IContinuousAccrual.Modules memory m = source.accrualModules();
        m.registry = address(source);
        source.setModules(m);
        _rejectBind();
        m.registry = address(r);
        source.setModules(m);
        source.token().reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(123)));
        _rejectBind();
        source.token().reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(source)));
        _bind();
    }

    function test_continuousGrowthChangesEveryDisclosureAndAdmissionDimension() public {
        _base();
        _bind();
        r.setClass(1, _class(3000));
        r.setBorrowerLimitOverride(B1, 3000);
        r.setStateLimit(3000);
        assertEq(r.classConcentrationBps(1), 2500);
        source.stream(1, 1, B1, S1, 200, 100);
        vm.warp(block.timestamp + 50);
        assertEq(r.totalBookExposure(), 500);
        assertEq(r.classExposure(1), 200);
        assertEq(r.borrowerExposure(B1), 200);
        assertEq(r.stateExposure(S1), 200);
        assertEq(r.stateExposure(0), 0);
        assertEq(r.classConcentrationBps(1), 4000);
        (bool c, bool b, bool s) = r.isOverConcentrated(1, B1, S1);
        assertTrue(c && b && s);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = B1;
        ids[1] = B2;
        assertTrue(r.overConcentratedBorrowers(ids)[0]);
        assertFalse(r.overConcentratedBorrowers(ids)[1]);
        ids[0] = S1;
        ids[1] = 0;
        assertTrue(r.overConcentratedStates(ids)[0]);
        assertFalse(r.overConcentratedStates(ids)[1]);
        assertEq(r.overConcentratedClasses(), 1);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ConcentrationExceeded.selector, 1, 201, 3000)
        );
        r.recordExposureIncrease(1, B1, S1, 1);
    }

    function test_eachBorrowerAndStateAdmissionUsesEarnedExposure() public {
        _base();
        _bind();
        source.earned(1, 1, B1, S1, 100);
        r.setBorrowerLimitOverride(B1, 3000);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, B1, 201, 3000)
        );
        r.checkConcentration(1, B1, S1, 1);
        r.setBorrowerLimitOverride(B1, 10_000);
        r.setStateLimit(3000);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_StateConcentrationExceeded.selector, S1, 201, 3000)
        );
        r.checkConcentration(1, B1, S1, 1);
    }

    function test_postingIsNeutralAndInactiveBreachedClassesCannotVetoIt() public {
        _base();
        _bind();
        source.earned(1, 1, B1, S1, 100);
        ICollateralRegistry.ClassParams memory p = _class(1000);
        p.active = false;
        r.setClass(1, p);
        bytes32 before_ = _exposureHash();
        assertEq(source.post(1), 100);
        assertEq(source.nativePosted(1), 100);
        assertEq(_exposureHash(), before_);
        assertEq(uint256(vm.load(address(r), bytes32(uint256(LOCATION) + 5))), 500);
        assertEq(source.post(1), 0);
        assertEq(_exposureHash(), before_);
    }

    function test_virtualClaimsCannotBeUsedToPassRawDecreaseUnderflow() public {
        _base();
        _bind();
        source.earned(1, 1, B1, S1, 100);
        vm.expectRevert(ICollateralRegistry.Registry_ExposureUnderflow.selector);
        r.recordExposureDecrease(1, B1, S1, 101);
        assertEq(r.classExposure(1), 200);
        source.post(1);
        r.recordExposureDecrease(1, B1, S1, 200);
        assertEq(r.classExposure(1), 0);
        assertEq(r.totalBookExposure(), 300);
    }

    function test_staleAdmissionClosesButRawRecoveryStillWorks() public {
        _base();
        _bind();
        source.stream(1, 1, B1, S1, 100, 100);
        vm.warp(block.timestamp + 100);
        assertEq(r.totalBookExposure(), 500);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccrualBook.AccrualBook_BoundaryPending.selector, uint64(block.timestamp), uint64(block.timestamp)
            )
        );
        r.checkConcentration(1, B1, S1, 0);
        r.recordExposureDecrease(2, B2, S2, 1);
        assertEq(r.totalBookExposure(), 499);
        source.finish();
        assertGt(r.concentrationHeadroom(1, B1, S1), 0);
    }

    function test_busyBlocksAllAdmissionConfigurationAndLegacyDecreases() public {
        _base();
        _bind();
        r.grantRole(bytes32(0), address(source));
        r.grantRole(Roles.CREDIT_ROLE, address(source));
        r.grantRole(Roles.UPGRADER_ROLE, address(source));
        r.setBorrowerLimitOverride(B1, 9000);
        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeCall(r.setBorrowerLimit, (5000));
        calls[1] = abi.encodeCall(r.setStateLimit, (5000));
        calls[2] = abi.encodeCall(r.setConcentrationFloor, (1000));
        calls[3] = abi.encodeCall(r.setPastDueWeight, (5000));
        calls[4] = abi.encodeCall(r.setClass, (1, _class(5000)));
        calls[5] = abi.encodeCall(r.recordExposureIncrease, (1, B1, S1, 1));
        calls[6] = abi.encodeCall(r.recordCapitalizedExposure, (1, B1, S1, 1));
        calls[7] = abi.encodeCall(r.recordExposureDecrease, (1, B1, S1, 1));
        calls[8] = abi.encodeWithSignature("grantRole(bytes32,address)", Roles.CREDIT_ROLE, address(123));
        calls[9] = abi.encodeWithSignature("revokeRole(bytes32,address)", bytes32(0), address(this));
        calls[10] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementation, bytes(""));
        bytes32[] memory empty = new bytes32[](0);
        calls[11] = abi.encodeCall(r.syncConcentrationBreaches, (empty, empty));
        calls[12] = abi.encodeCall(r.setBorrowerLimitOverride, (B1, uint16(5000)));
        calls[13] = abi.encodeCall(r.clearBorrowerLimitOverride, (B1));
        calls[14] = abi.encodeWithSignature("renounceRole(bytes32,address)", Roles.CREDIT_ROLE, address(source));
        bytes32 before_ = _exposureHash();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = source.attack(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(reason), RegistryAccrualSource.Fixture_Busy.selector);
        }
        assertEq(_exposureHash(), before_);
        assertTrue(r.hasRole(bytes32(0), address(this)));
        source.setBusy(true);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
        source.setBusy(false);
    }

    function test_onlyBoundReserveCanPostWithoutCreditRole() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_AccrualReserveOnly.selector, address(this)));
        r.recordAccruedExposure(1, B1, S1, 1);
        _bind();
        source.earned(1, 1, B1, S1, 1);
        assertFalse(r.hasRole(Roles.CREDIT_ROLE, address(source)));
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_AccrualReserveOnly.selector, address(this)));
        r.recordAccruedExposure(1, B1, S1, 1);
        assertEq(source.post(1), 1);
    }

    function test_reservedFutureFaceRestrictsPendingOriginationAndLegacyCapitalization() public {
        _bind();
        source.setReserved(MAX - 100);
        assertEq(r.concentrationHeadroom(1, B1, S1), 100);
        r.recordExposureIncrease(1, B1, S1, 100);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        r.recordExposureIncrease(1, B1, S1, 1);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        r.recordCapitalizedExposure(1, B1, S1, 1);
        assertEq(r.totalBookExposure(), 100);
    }

    function test_neutralPostingDoesNotReserveFutureFaceTwice() public {
        _bind();
        source.earned(1, 1, B1, S1, 100);
        source.setReserved(MAX - 100);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
        source.post(1);
        assertEq(r.totalBookExposure(), 100);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
    }

    function test_unknownAndOversizedReservePostingHasSpecificErrors() public {
        _bind();
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_UnknownClass.selector, 0));
        source.directPost(0, B1, S1, 1);
        source.earned(1, 1, B1, S1, MAX);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        source.directPost(1, B1, S1, 1);
        source.post(1);
        assertEq(r.totalBookExposure(), MAX);
    }

    function test_viewsRejectImpossibleEffectiveExposureByName() public {
        _bind();
        source.earned(1, 1, B1, S1, MAX + 1);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        r.totalBookExposure();
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        r.classExposure(1);
    }

    function test_deploymentSizeFitsProductionLimit() public view {
        assertLe(implementation.code.length, 24576);
    }

    function test_bindingRejectsMissingCodeMalformedAbiAndDirtyModuleWords() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_InvalidAccrualReserve.selector, address(0)));
        r.setAccrualReserve(address(0));
        RegistryAccrualEndpoint bad = new RegistryAccrualEndpoint();
        bad.fail(true);
        _reject(address(bad));
        bad.fail(false);
        bad.reply(IContinuousAccrual.accrualModules.selector, hex"01");
        _reject(address(bad));
        uint256[7] memory words;
        for (uint256 i; i < 7; ++i) {
            words[i] = uint256(uint160(address(source)));
        }
        words[0] = uint256(1) << 160;
        bad.reply(IContinuousAccrual.accrualModules.selector, abi.encode(words));
        _reject(address(bad));
        words[0] = 0;
        bad.reply(IContinuousAccrual.accrualModules.selector, abi.encode(words));
        _reject(address(bad));
        source.token().reply(bytes4(keccak256("accrualReserve()")), hex"00");
        _rejectBind();
    }

    function test_bindingRejectsWrongControllerAndBridgeBeforePermanentWrite() public {
        bytes4 selector = bytes4(keccak256("modules()"));
        source.controller().reply(selector, abi.encode(address(0), address(0), address(source)));
        _rejectBind();
        source.controller().reply(selector, abi.encode(address(source.token()), uint256(1) << 160, address(source)));
        _rejectBind();
        source.controller().reply(selector, abi.encode(address(source.token()), address(0), address(0)));
        _rejectBind();
        source.controller().reply(selector, abi.encode(address(source.token()), address(0), address(source)));
        source.bridge().reply(selector, abi.encode(address(0), address(0)));
        _rejectBind();
        source.bridge().reply(selector, abi.encode(address(r), uint256(1) << 160));
        _rejectBind();
        source.bridge().reply(selector, abi.encode(address(r), address(0)));
        _bind();
    }

    function test_bindingRejectsInitialCurrentOrFutureOverflowAndBusySource() public {
        source.setReserved(MAX + 1);
        _rejectBind();
        source.setReserved(0);
        source.setBusy(true);
        vm.expectRevert(RegistryAccrualSource.Fixture_Busy.selector);
        r.setAccrualReserve(address(source));
        source.setBusy(false);
        source.earned(1, 1, B1, S1, MAX + 1);
        _rejectBind();
    }

    function test_bindingRejectsMissingExposureSelectorsAndPreservesRawBook() public {
        RegistryAccrualEndpoint bad = new RegistryAccrualEndpoint();
        IContinuousAccrual.Modules memory m = source.accrualModules();
        bad.reply(IContinuousAccrual.accrualModules.selector, abi.encode(m));
        source.token().reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(bad)));
        source.controller().reply(
            bytes4(keccak256("modules()")), abi.encode(address(source.token()), address(0), address(bad))
        );
        _reject(address(bad));
        bad.reply(IAccrualExposure.accrualExposure.selector, abi.encode(uint256(0)));
        _reject(address(bad));
        bad.reply(IAccrualExposure.accrualReservedExposure.selector, abi.encode(uint256(0)));
        r.setAccrualReserve(address(bad));
        assertEq(r.totalBookExposure(), 0);
    }

    function test_successfulLegacyCapitalizationStillReportsDriftWithoutConcentrationVeto() public {
        _base();
        _bind();
        r.setClass(1, _class(1000));
        r.setStateLimit(1000);
        r.recordCapitalizedExposure(1, B1, S1, 100);
        assertEq(r.classExposure(1), 200);
        assertEq(r.totalBookExposure(), 500);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_UnknownClass.selector, 0));
        r.recordCapitalizedExposure(0, B1, S1, 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = S1;
        r.recordExposureDecrease(1, B1, S1, 200);
        r.syncConcentrationBreaches(new bytes32[](0), ids);
        assertFalse(r.overConcentratedStates(ids)[0]);
        r.revokeRole(Roles.CREDIT_ROLE, address(this));
        assertFalse(r.hasRole(Roles.CREDIT_ROLE, address(this)));
    }

    function test_stateCanBeTheUniqueHeadroomConstraintAndZeroStateSkipsIt() public {
        _base();
        _bind();
        r.setStateLimit(3000);
        assertEq(r.concentrationHeadroom(1, B1, S1), 28);
        assertEq(r.concentrationHeadroom(1, B1, 0), MAX - 400);
        assertEq(r.concentrationHeadroom(0, B1, S1), 0);
    }

    function test_bootstrapHeadroomIncludesCurrentAccrualAndHasAnExactAdmissionEdge() public {
        _base();
        _bind();
        source.earned(1, 1, B1, S1, 100);
        r.setClass(1, _class(5000));
        r.setBorrowerLimitOverride(B1, 5000);
        r.setStateLimit(5000);
        r.setConcentrationFloor(2000);
        assertEq(r.concentrationHeadroom(1, B1, S1), 800);
        r.checkConcentration(1, B1, S1, 800);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ConcentrationExceeded.selector, 1, 1001, 5000)
        );
        r.checkConcentration(1, B1, S1, 801);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        r.setConcentrationFloor(MAX + 1);
    }

    function test_postingWritesNativeDimensionsBeforeBreachEventsReadTheSource() public {
        _base();
        _bind();
        r.setClass(1, _class(3000));
        r.setBorrowerLimitOverride(B1, 3000);
        r.setStateLimit(3000);
        source.earned(1, 1, B1, S1, 100);
        vm.recordLogs();
        source.post(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 classTopic = keccak256("ConcentrationDrift(uint256,uint256,uint256,uint16,bool)");
        bytes32 borrowerTopic = keccak256("BorrowerConcentrationDrift(bytes32,uint256,uint256,uint16,bool)");
        bytes32 stateTopic = keccak256("StateConcentrationDrift(bytes32,uint256,uint256,uint16,bool)");
        uint256 matched;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(r)
                    && (
                        logs[i].topics[0] == classTopic || logs[i].topics[0] == borrowerTopic
                            || logs[i].topics[0] == stateTopic
                    )
            ) {
                assertEq(logs[i].data, abi.encode(uint256(200), uint256(500), uint16(3000), true));
                ++matched;
            }
        }
        assertEq(matched, 3);
        bytes32[] memory borrowers = new bytes32[](1);
        borrowers[0] = B1;
        vm.recordLogs();
        r.syncConcentrationBreaches(borrowers, new bytes32[](0));
        assertEq(vm.getRecordedLogs().length, 0, "posting already announced the same effective breach");
    }

    function test_constantViewCostDoesNotGrowWithFacilityPopulation() public {
        _bind();
        source.earned(1, 1, B1, S1, 1);
        vm.cool(address(r));
        vm.cool(address(source));
        uint256 start = gasleft();
        uint256 value = r.classExposure(1);
        uint256 oneCost = start - gasleft();
        assertEq(value, 1);
        for (uint256 id = 2; id <= 100; ++id) {
            source.earned(id, 1, B1, S1, 1);
        }
        vm.cool(address(r));
        vm.cool(address(source));
        start = gasleft();
        value = r.classExposure(1);
        uint256 hundredCost = start - gasleft();
        assertEq(value, 100);
        assertLe(hundredCost, oneCost + 100);
    }

    function test_legacyWeightAndSaturatingMarksRemainUnchangedAfterBinding() public {
        _bind();
        uint256 defaultWeight = r.pastDueWeightBps();
        assertGt(defaultWeight, 0);
        assertEq(r.weightedPastDueImpairment(10000), defaultWeight);
        r.setPastDueWeight(5000);
        assertEq(r.pastDueWeightBps(), 5000);
        assertEq(r.pastDueRampWeightBps(0), 5000);
        assertEq(r.pastDueRampWeightBps(Config.DEFAULT_REDEEM_COOLDOWN), 10000);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_InvalidPastDueWeight.selector, 0));
        r.setPastDueWeight(0);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_InvalidPastDueWeight.selector, 10000));
        r.setPastDueWeight(10000);
        RegistryAccrualEndpoint vault = new RegistryAccrualEndpoint();
        vault.reply(bytes4(keccak256("totalAssets()")), abi.encode(uint256(100)));
        assertEq(r.conservativeSeniorMark(100, 120, address(vault), block.timestamp), 60);
        assertEq(r.conservativeSeniorMark(10, 30, address(vault), block.timestamp), 25);
        assertEq(r.conservativeSeniorMark(100, 120, address(vault), 0), 100);
        vault.reply(bytes4(keccak256("totalAssets()")), abi.encode(uint256(10)));
        assertEq(r.conservativeSeniorMark(100, 120, address(vault), block.timestamp), 20);
    }

    function test_rawBorrowerAndStateChecksCannotBorrowVirtualBalance() public {
        _base();
        _bind();
        source.earned(1, 3, bytes32(uint256(9)), bytes32(uint256(10)), 100);
        vm.expectRevert(ICollateralRegistry.Registry_ExposureUnderflow.selector);
        r.recordExposureDecrease(3, B1, S1, 1);
        vm.expectRevert(ICollateralRegistry.Registry_ExposureUnderflow.selector);
        r.recordExposureDecrease(1, bytes32(uint256(9)), S1, 1);
        vm.expectRevert(ICollateralRegistry.Registry_ExposureUnderflow.selector);
        r.recordExposureDecrease(1, B1, bytes32(uint256(10)), 1);
    }

    function testFuzz_fullWidthNumericRoomIncludesPendingAndFutureClaims(
        uint256 rawSeed,
        uint256 earnedSeed,
        uint96 roomSeed
    ) public {
        uint256 raw = rawSeed % MAX;
        uint256 interest = earnedSeed % (MAX - raw + 1);
        r.recordExposureIncrease(1, B1, S1, raw);
        _bind();
        source.earned(1, 1, B1, S1, interest);
        uint256 available = MAX - raw - interest;
        uint256 room = roomSeed < available ? roomSeed : available;
        source.setReserved(available - room);
        assertEq(r.concentrationHeadroom(1, B1, S1), room);
        r.recordExposureIncrease(1, B1, S1, room);
        assertEq(r.totalBookExposure(), raw + interest + room);
        assertEq(r.concentrationHeadroom(1, B1, S1), 0);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        r.recordExposureIncrease(1, B1, S1, 1);
    }

    function testFuzz_postingAndDecreaseConserveAllFourDimensions(
        uint96 rawSeed,
        uint96 earnedSeed,
        uint96 reductionSeed,
        bool noState
    ) public {
        uint256 raw = uint256(rawSeed) + 1;
        uint256 interest = earnedSeed;
        bytes32 stateId = noState ? bytes32(0) : S1;
        r.recordExposureIncrease(1, B1, stateId, raw);
        _bind();
        source.earned(1, 1, B1, stateId, interest);
        assertEq(r.totalBookExposure(), raw + interest);
        source.post(1);
        uint256 reduction = uint256(reductionSeed) % (raw + interest + 1);
        r.recordExposureDecrease(1, B1, stateId, reduction);
        uint256 expected = raw + interest - reduction;
        assertEq(r.totalBookExposure(), expected);
        assertEq(r.classExposure(1), expected);
        assertEq(r.borrowerExposure(B1), expected);
        assertEq(r.stateExposure(stateId), noState ? 0 : expected);
    }

    function testFuzz_headroomMatchesIndependentCurrentAndReservedModel(
        uint64 a,
        uint64 b,
        uint64 earnedSeed,
        uint16 limitSeed,
        uint64 budgetSeed
    ) public {
        uint256 first = uint256(a) % 1e9 + 1;
        uint256 other = uint256(b) % 1e9 + 1;
        uint256 interest = uint256(earnedSeed) % 1e9;
        r.recordExposureIncrease(1, B1, S1, first);
        r.recordExposureIncrease(2, B2, S2, other);
        _bind();
        source.earned(1, 1, B1, S1, interest);
        uint16 limit = limitSeed % 10_000 + 1;
        r.setClass(1, _class(limit));
        r.setBorrowerLimitOverride(B1, limit);
        r.setStateLimit(limit);
        uint256 total = first + other + interest;
        uint256 current = first + interest;
        uint256 budget = uint256(budgetSeed) % 1e9;
        source.setReserved(MAX - total - budget);
        uint256 low;
        uint256 high = budget;
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2;
            if (current + mid <= uint256(limit) * (total + mid) / 10_000) low = mid;
            else high = mid - 1;
        }
        uint256 room = r.concentrationHeadroom(1, B1, S1);
        assertEq(room, low);
        if (room != 0) r.checkConcentration(1, B1, S1, room);
        (bool ok,) = address(r).staticcall(abi.encodeCall(r.checkConcentration, (1, B1, S1, room + 1)));
        assertFalse(ok);
    }

    function testFuzz_earnedClaimsCanCrossLimitsBeforeAnyPosting(uint96 amountSeed, uint16 limitSeed) public {
        uint256 amount = uint256(amountSeed) + 1;
        uint16 limit = limitSeed % 9999 + 1;
        r.recordExposureIncrease(1, B1, S1, amount);
        r.recordExposureIncrease(2, B2, S2, amount);
        _bind();
        source.earned(1, 1, B1, S1, amount);
        r.setClass(1, _class(limit));
        r.setBorrowerLimitOverride(B1, limit);
        r.setStateLimit(limit);
        bool expected = 2 * amount > uint256(limit) * (3 * amount) / 10_000;
        (bool c, bool b, bool s) = r.isOverConcentrated(1, B1, S1);
        assertEq(c, expected);
        assertEq(b, expected);
        assertEq(s, expected);
        assertEq(r.classConcentrationBps(1), 6666);
    }

    function _bind() private {
        r.setAccrualReserve(address(source));
    }

    function _base() private {
        r.recordExposureIncrease(1, B1, S1, 100);
        r.recordExposureIncrease(2, B2, S2, 300);
    }

    function _class(uint16 limit) private pure returns (ICollateralRegistry.ClassParams memory p) {
        p.name = "Fixture class";
        p.active = true;
        p.maxLtvBps = 8000;
        p.maxMaturity = 365 days;
        p.concentrationLimitBps = limit;
    }

    function _rejectBind() private {
        vm.expectRevert(
            abi.encodeWithSelector(CollateralRegistry.Registry_InvalidAccrualReserve.selector, address(source))
        );
        r.setAccrualReserve(address(source));
        assertEq(r.accrualReserve(), address(0));
    }

    function _reject(address candidate) private {
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.Registry_InvalidAccrualReserve.selector, candidate));
        r.setAccrualReserve(candidate);
        assertEq(r.accrualReserve(), address(0));
    }

    function _legacyHash() private view returns (bytes32) {
        bytes32[14] memory words;
        for (uint256 i; i < 14; ++i) {
            words[i] = vm.load(address(r), bytes32(uint256(LOCATION) + i));
        }
        return keccak256(
            abi.encode(words, r.classParams(1), r.classExposure(1), r.borrowerExposure(B1), r.stateExposure(S1))
        );
    }

    function _exposureHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                r.totalBookExposure(),
                r.classExposure(1),
                r.borrowerExposure(B1),
                r.stateExposure(S1),
                r.classConcentrationBps(1),
                r.overConcentratedClasses()
            )
        );
    }
}
