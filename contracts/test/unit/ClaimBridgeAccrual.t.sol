// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualExposure} from "../../src/interfaces/IAccrualExposure.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {BridgeAccrualLib} from "../../src/libraries/BridgeAccrualLib.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualMath} from "../../src/libraries/AccrualMath.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Fixed identity replies isolate module wiring from unrelated token/custody implementations.
contract BridgeAccrualEndpoint {
    mapping(bytes4 => bytes) private replies;
    bool private rejects;

    function reply(bytes4 selector, bytes calldata data) external {
        replies[selector] = data;
    }

    function setRejects(bool value) external {
        rejects = value;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(!rejects, "fixture endpoint rejected");
        return replies[bytes4(input)];
    }
}

/// @dev Uses the actual loan coordinator and Book. Funding/native-face effects are explicit
///      test facts; this is not a substitute for production reserve/token/custody integration.
contract BridgeAccrualSource is IAccrualExposure, IERC721Receiver {
    using AccrualLoans for AccrualLoans.State;
    using AccrualBook for AccrualBook.Book;

    ClaimBridge public immutable bridge;
    CollateralRegistry public immutable registry;
    AttestationOracle public immutable oracle;
    BridgeAccrualEndpoint public immutable token;
    BridgeAccrualEndpoint public immutable controller;
    BridgeAccrualEndpoint public immutable waterfall;
    Modules private modules_;
    AccrualLoans.State private loans;
    bool public enabled;
    bool public busy;
    bool public rejectAmendment;
    address public nativeController;
    uint256 public amendments;
    uint64 public amendmentAt;
    bytes32 public observedOldFacility;
    bool public observedConsumed;
    IAccrualLifecycle.Terms private lastTerms_;
    mapping(uint256 => uint256) public nativeFace;

    error Fixture_Busy();
    error Fixture_AmendRejected();
    error Fixture_WrongCaller();

    constructor(ClaimBridge bridge_, CollateralRegistry registry_, AttestationOracle oracle_) {
        bridge = bridge_;
        registry = registry_;
        oracle = oracle_;
        token = new BridgeAccrualEndpoint();
        controller = new BridgeAccrualEndpoint();
        waterfall = new BridgeAccrualEndpoint();
        modules_ = Modules({
            token: address(token),
            controller: address(controller),
            vault: address(this),
            waterfall: address(waterfall),
            bridge: address(bridge_),
            registry: address(registry_),
            defaultManager: address(this)
        });
        token.reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(this)));
        controller.reply(bytes4(keccak256("modules()")), abi.encode(address(token), address(this), address(this)));
        waterfall.reply(
            bytes4(keccak256("modules()")),
            abi.encode(
                address(bridge_),
                address(registry_),
                address(this),
                address(controller),
                address(this),
                address(oracle_)
            )
        );
        nativeController = address(controller);
        loans.initialize(uint64(block.timestamp), 0);
    }

    function setEnabled(bool value) external {
        enabled = value;
    }

    function setBusy(bool value) external {
        busy = value;
    }

    function setRejectAmendment(bool value) external {
        rejectAmendment = value;
    }

    function setNativeController(address value) external {
        nativeController = value;
    }

    function setModules(Modules calldata value) external {
        modules_ = value;
    }

    function accrualModules() external view returns (Modules memory) {
        return modules_;
    }

    function lossController() external view returns (address) {
        return nativeController;
    }

    function accrualDelivery() external pure returns (Delivery memory d) {
        return d;
    }

    function materializeAccrued(uint8) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function accrualReservedExposure() external pure returns (uint256) {
        return 0;
    }

    function requireAccrualIdle() public view {
        if (busy) revert Fixture_Busy();
    }

    function requireAccrualFresh() external view {
        requireAccrualIdle();
        if (enabled) loans.book.requireFresh(uint64(block.timestamp));
    }

    function accrualSnapshot() external view returns (Snapshot memory s) {
        AccrualBook.Snapshot memory b = loans.book.snapshot(uint64(block.timestamp));
        s.gross = b.gross;
        s.unposted = b.unposted;
        s.unissued = b.unissued;
        s.seniorUnissued = b.seniorUnissued;
        s.feeUnissued = b.feeUnissued;
        s.accruedThrough = b.accruedThrough;
        s.enabled = enabled;
        s.fresh = b.fresh;
    }

    function accrualExposure(uint8 kind, bytes32 identity) external view returns (uint256) {
        if (kind == 0) return loans.book.snapshot(uint64(block.timestamp)).unposted;
        if (kind == 3 && identity == 0) return 0;
        return loans.book.groupUnposted(keccak256(abi.encode(kind, identity)), uint64(block.timestamp));
    }

    function fund(uint256 id) external {
        ClaimBridge.Facility memory f = bridge.facility(id);
        require(enabled && f.state == ClaimBridge.LoanState.Active, "fixture funding state");
        loans.fund(
            id,
            AccrualLoans.Funding({
                principal: f.principal,
                balanceCeiling: f.principal * 3,
                scale: 1,
                yearSeconds: f.dayCountConvention == ClaimBridge.DayCountConvention.Actual360 ? 360 days : 365 days,
                rateBps: f.interestRateBps,
                fundedAt: uint64(block.timestamp),
                nextPaymentDue: f.nextPaymentDue,
                paymentInterval: f.paymentInterval,
                maturity: f.maturity,
                pik: f.pik,
                keys: [
                    keccak256(abi.encode(uint8(1), bytes32(f.classId))),
                    keccak256(abi.encode(uint8(2), f.borrowerId)),
                    keccak256(abi.encode(uint8(3), f.stateId))
                ],
                frozenPikBasis: 0
            })
        );
        nativeFace[id] = f.principal;
    }

    function amendAccruingLoan(uint256 id, IAccrualLifecycle.Terms calldata terms) external {
        if (msg.sender != address(bridge)) revert Fixture_WrongCaller();
        requireAccrualIdle();
        loans.book.requireFresh(uint64(block.timestamp));
        busy = true;
        observedOldFacility = keccak256(abi.encode(bridge.facility(id)));
        (bytes32 payload,, bool live) = oracle.latestPayload(id, IAttestationOracle.AttestationKind.TermsAmended);
        observedConsumed = !live
            && oracle.factStatus(id, IAttestationOracle.AttestationKind.TermsAmended, payload)
                == IAttestationOracle.FactStatus.Consumed;
        lastTerms_ = terms;
        amendmentAt = uint64(block.timestamp);
        ++amendments;
        AccrualLoans.LifecycleWork memory work = loans.amend(
            id,
            AccrualLoans.Amendment({
                balanceCeiling: loans.loans[id].balanceCeiling,
                yearSeconds: terms.yearSeconds,
                rateBps: terms.rateBps,
                nextPaymentDue: terms.nextPaymentDue,
                paymentInterval: terms.paymentInterval,
                maturity: terms.maturity
            }),
            uint64(block.timestamp)
        );
        _post(work);
        if (rejectAmendment) revert Fixture_AmendRejected();
        busy = false;
    }

    function checkpointAccrual(uint256 maximum) external returns (uint256 processed, bool fresh) {
        requireAccrualIdle();
        busy = true;
        AccrualLoans.LifecycleWork[] memory work;
        (work, processed, fresh) = loans.checkpoint(uint64(block.timestamp), maximum);
        for (uint256 i; i < processed; ++i) {
            if (work[i].nextDue != 0) bridge.setAccruedPaymentDue(work[i].facilityId, work[i].nextDue);
        }
        busy = false;
    }

    function repayPrincipal(uint256 id, uint256 amount) external {
        AccrualLoans.LifecycleWork memory work = loans.repay(id, amount, 0, uint64(block.timestamp));
        busy = true;
        _post(work);
        nativeFace[id] -= amount;
        busy = false;
        ClaimBridge.Facility memory f = bridge.facility(id);
        registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, amount);
    }

    function _post(AccrualLoans.LifecycleWork memory work) private {
        require(work.roundingLoss == 0, "fixture BSC rounding");
        nativeFace[work.facilityId] += work.posting;
        if (work.posting != 0) {
            ClaimBridge.Facility memory f = bridge.facility(work.facilityId);
            registry.recordAccruedExposure(f.classId, f.borrowerId, f.stateId, work.posting);
        }
    }

    function loanFace(uint256 id) external view returns (uint256, uint256, uint64) {
        return loans.loanFace(id, uint64(block.timestamp));
    }

    function frozenBasis(uint256 id) external view returns (uint256) {
        return loans.loans[id].frozenPikBasis;
    }

    function nextCapitalization(uint256 id) external view returns (uint64) {
        return loans.loans[id].nextCapitalization;
    }

    function lastTerms() external view returns (IAccrualLifecycle.Terms memory) {
        return lastTerms_;
    }

    function advance(uint256 id, uint64 nextDue) external {
        busy = true;
        bridge.setAccruedPaymentDue(id, nextDue);
        busy = false;
    }

    function attack(bytes calldata callData) external returns (bool ok, bytes memory result) {
        busy = true;
        (ok, result) = address(bridge).call(callData);
        busy = false;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract ClaimBridgeAccrualTest is Test, IERC721Receiver {
    ClaimBridge private bridge;
    CollateralRegistry private registry;
    AttestationOracle private oracle;
    BridgeAccrualSource private source;
    address private implementation;
    uint256 private nonce;
    uint64 private constant START = 1_750_000_000;
    uint256 private constant AMOUNT = 3_600_000e18;
    uint256 private constant KEY_A = 0xA11CE;
    uint256 private constant KEY_B = 0xB0B;
    bytes32 private constant BORROWER = keccak256("bridge-accrual-borrower");
    bytes32 private constant STATE = keccak256("US-GA");
    bytes32 private constant LOCATION = 0xc9c2da543a2a10e4b712709fb6548fb2c0c97cecbac3457453966d18f1663f00;

    function setUp() public {
        vm.warp(START);
        registry = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(new CollateralRegistry()),
                    abi.encodeCall(CollateralRegistry.initialize, (address(this), address(this)))
                )
            )
        );
        oracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (address(this), address(this), address(this)))
                )
            )
        );
        implementation = address(new ClaimBridge());
        bridge = ClaimBridge(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        ClaimBridge.initialize,
                        (address(this), address(this), address(this), address(registry), address(oracle))
                    )
                )
            )
        );
        for (uint256 c = 1; c <= 3; ++c) {
            ICollateralRegistry.ClassParams memory p;
            p.name = "Accrual fixture";
            p.active = true;
            p.maxLtvBps = 8000;
            p.maxMaturity = 730 days;
            p.concentrationLimitBps = 10_000;
            if (c == 3) {
                p.model = ICollateralRegistry.CollateralModel.MarkedToMarket;
                p.marginCallLtvBps = 8500;
                p.liquidationLtvBps = 9000;
                p.maxMarkAge = 1 days;
            }
            registry.setClass(c, p);
            bridge.setRequiredMintAttestations(c, 7);
        }
        registry.setBorrowerLimit(10_000);
        registry.setStateLimit(10_000);
        registry.setConcentrationFloor(0);
        registry.grantRole(Roles.CREDIT_ROLE, address(bridge));
        bridge.grantRole(Roles.CREDIT_ROLE, address(this));
        bridge.grantRole(Roles.ORIGINATOR_ROLE, address(this));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(KEY_A));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(KEY_B));
        oracle.grantRole(Roles.CREDIT_ROLE, address(bridge));
        source = new BridgeAccrualSource(bridge, registry, oracle);
        registry.grantRole(Roles.CREDIT_ROLE, address(source));
    }

    function test_bindingIsPermanentAndPreservesHistoricalStorage() public {
        uint256 id = _originate(_terms(false), address(this));
        bytes32 before_ = _historicalHash(id);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit ClaimBridge.AccrualReserveSet(address(source));
        _bind();
        assertEq(bridge.accrualReserve(), address(source));
        assertEq(vm.load(address(bridge), bytes32(uint256(LOCATION) + 5)), bytes32(uint256(uint160(address(source)))));
        assertEq(_historicalHash(id), before_);
        vm.expectRevert(ClaimBridge.Bridge_AccrualAlreadyBound.selector);
        bridge.setAccrualReserve(address(source));
    }

    function test_bindingRejectsUnauthorizedAndWrongBridgeRegistry() public {
        vm.prank(address(123));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(123), bytes32(0))
        );
        bridge.setAccrualReserve(address(source));
        IContinuousAccrual.Modules memory m = source.accrualModules();
        m.bridge = address(source);
        source.setModules(m);
        _rejectBind(address(source));
        m.bridge = address(bridge);
        m.registry = address(source);
        source.setModules(m);
        _rejectBind(address(source));
    }

    function test_bindingRejectsCodeLengthsDirtyAddressesAndMissingReplies() public {
        _rejectBind(address(0));
        _rejectBind(address(123));
        BridgeAccrualEndpoint endpoint = new BridgeAccrualEndpoint();
        endpoint.setRejects(true);
        _rejectBind(address(endpoint));
        endpoint.setRejects(false);
        endpoint.reply(IContinuousAccrual.accrualModules.selector, hex"01");
        _rejectBind(address(endpoint));
        uint256[7] memory words;
        for (uint256 i; i < 7; ++i) {
            words[i] = uint256(uint160(address(source)));
        }
        words[0] = 1 << 200;
        endpoint.reply(IContinuousAccrual.accrualModules.selector, abi.encode(words));
        _rejectBind(address(endpoint));
        words[0] = 123;
        endpoint.reply(IContinuousAccrual.accrualModules.selector, abi.encode(words));
        _rejectBind(address(endpoint));
    }

    function test_bindingRejectsTokenControllerAndNativeRouteMismatch() public {
        source.token().reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(123)));
        _rejectBind(address(source));
        source.token().reply(bytes4(keccak256("accrualReserve()")), hex"00");
        _rejectBind(address(source));
        source.token().reply(bytes4(keccak256("accrualReserve()")), abi.encode(address(source)));
        source.controller().reply(
            bytes4(keccak256("modules()")), abi.encode(address(123), address(source), address(source))
        );
        _rejectBind(address(source));
        source.controller().reply(
            bytes4(keccak256("modules()")), abi.encode(address(source.token()), uint256(1) << 200, address(source))
        );
        _rejectBind(address(source));
        source.controller().reply(
            bytes4(keccak256("modules()")), abi.encode(address(source.token()), address(source), address(123))
        );
        _rejectBind(address(source));
        source.controller().reply(
            bytes4(keccak256("modules()")), abi.encode(address(source.token()), address(source), address(source))
        );
        source.setNativeController(address(123));
        _rejectBind(address(source));
        source.setNativeController(address(source.controller()));
        source.setBusy(true);
        vm.expectRevert(BridgeAccrualSource.Fixture_Busy.selector);
        bridge.setAccrualReserve(address(source));
        assertEq(bridge.accrualReserve(), address(0));
    }

    function test_bindingPinsEveryExistingWaterfallModule() public {
        address[6] memory route = [
            address(bridge),
            address(registry),
            address(source),
            address(source.controller()),
            address(source),
            address(oracle)
        ];
        for (uint256 i; i < 6; ++i) {
            address saved = route[i];
            route[i] = address(123);
            source.waterfall().reply(bytes4(keccak256("modules()")), abi.encode(route));
            _rejectBind(address(source));
            route[i] = saved;
        }
        source.waterfall().reply(bytes4(keccak256("modules()")), abi.encode(route));
        _bind();
    }

    function test_enabledFundingSupportsFixedCash360And365() public {
        _activate();
        ClaimBridge.OriginationTerms memory t = _terms(false);
        uint256 first = _originate(t, address(this));
        bridge.checkFundable(first);
        t.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        uint256 second = _originate(t, address(this));
        bridge.checkFundable(second);
    }

    function test_pendingUnsupportedCashCannotFundAfterActivation() public {
        ClaimBridge.OriginationTerms memory t = _terms(false);
        t.rateType = ClaimBridge.RateType.Variable;
        t.rateIndexRef = keccak256("future-benchmark");
        uint256 variableId = _originate(t, address(this));
        t.rateType = ClaimBridge.RateType.Fixed;
        t.rateIndexRef = 0;
        t.dayCountConvention = ClaimBridge.DayCountConvention.Thirty360;
        uint256 thirtyId = _originate(t, address(this));
        bridge.checkFundable(variableId);
        bridge.checkFundable(thirtyId);
        _activate();
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualUnsupportedTerms.selector, variableId));
        bridge.checkFundable(variableId);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualUnsupportedTerms.selector, thirtyId));
        bridge.checkFundable(thirtyId);
    }

    function test_existingPikOriginationScopeCannotBeBroadenedByActivation() public {
        _activate();
        ClaimBridge.OriginationTerms memory t = _terms(true);
        t.rateType = ClaimBridge.RateType.Variable;
        t.rateIndexRef = keccak256("unsupported-pik-index");
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(address(this), t);
        t.rateType = ClaimBridge.RateType.Fixed;
        t.rateIndexRef = 0;
        t.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(address(this), t);
        t.dayCountConvention = ClaimBridge.DayCountConvention.Actual360;
        t.classId = 3;
        t.stateId = 0;
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(address(this), t);
    }

    function test_existingPikAmendmentScopeStillRejectsVariableAndActual365() public {
        _activate();
        uint256 id = _fund(true);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 100 days));
        a.rateType = ClaimBridge.RateType.Variable;
        a.rateIndexRef = keccak256("unsupported-pik-index");
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(id, keccak256("unsupported-pik"), a);
        a.rateType = ClaimBridge.RateType.Fixed;
        a.rateIndexRef = 0;
        a.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.amendTerms(id, keccak256("unsupported-pik"), a);
        assertEq(source.amendments(), 0);
    }

    function test_markedOriginationAndFundingRetainValuationAgeAndLtvBounds() public {
        _activate();
        ClaimBridge.OriginationTerms memory t = _terms(false);
        t.classId = 3;
        t.stateId = 0;
        _attestTerms(1, t);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_ValuationStale.selector, 0, uint64(0), uint64(1 days))
        );
        bridge.originate(address(this), t);
        _attest(_input(1, IAttestationOracle.AttestationKind.Valuation, bytes32(AMOUNT)));
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, AMOUNT, AMOUNT * 7500 / 10_000)
        );
        bridge.originate(address(this), t);
        vm.warp(START + 1);
        _attest(_input(1, IAttestationOracle.AttestationKind.Valuation, bytes32(AMOUNT * 2)));
        assertEq(bridge.originate(address(this), t), 1);
        bridge.checkFundable(1);
        vm.warp(START + 2);
        _attest(_input(1, IAttestationOracle.AttestationKind.Valuation, bytes32(AMOUNT)));
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, AMOUNT, AMOUNT * 7500 / 10_000)
        );
        bridge.checkFundable(1);
        vm.warp(START + 1 days + 3);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_ValuationStale.selector, 1, uint64(START + 2), uint64(1 days))
        );
        bridge.checkFundable(1);
    }

    function test_fundedCancellationAndFrozenNftTransferRemainRefused() public {
        _activate();
        uint256 id = _fund(false);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_NotPending.selector, id));
        bridge.cancelPending(id);
        bridge.transitionState(id, ClaimBridge.LoanState.Defaulted);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_PositionFrozen.selector, id));
        bridge.transferFrom(address(this), address(source), id);
        bridge.transitionState(id, ClaimBridge.LoanState.Accelerated);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_PositionFrozen.selector, id));
        bridge.transferFrom(address(this), address(source), id);
        assertEq(bridge.ownerOf(id), address(this));
    }

    function test_disabledBindingPreservesLegacyAmendmentAndPikDueBehavior() public {
        _bind();
        uint256 cash = _originate(_terms(false), address(this));
        bridge.transitionState(cash, ClaimBridge.LoanState.Active);
        ClaimBridge.Amendment memory a = _amendment(cash, 2000, uint64(START + 100 days));
        a.rateType = ClaimBridge.RateType.Variable;
        a.rateIndexRef = keccak256("legacy-index");
        a.dayCountConvention = ClaimBridge.DayCountConvention.Thirty360;
        _amend(cash, a, keccak256("disabled-amend"));
        assertEq(source.amendments(), 0);
        assertEq(uint8(bridge.facility(cash).rateType), uint8(ClaimBridge.RateType.Variable));
        uint256 pik = _originate(_terms(true), address(this));
        bridge.transitionState(pik, ClaimBridge.LoanState.Active);
        bridge.setNextPaymentDue(pik, uint64(START + 180 days));
        assertEq(bridge.facility(pik).nextPaymentDue, START + 180 days);
    }

    function test_amendmentSeesConsumedAttestationAndOldTermsThenAppliesOnlyFutureRate() public {
        _activate();
        uint256 id = _fund(false);
        vm.warp(START + 10 days);
        ClaimBridge.Facility memory prior = bridge.facility(id);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 100 days));
        ClaimBridge.OriginationTerms memory changed = _terms(false);
        changed.interestRateBps = a.interestRateBps;
        changed.nextPaymentDue = a.nextPaymentDue;
        changed.paymentScheduleHash = a.paymentScheduleHash;
        bytes32 expectedHash = bridge.creditTermsHash(changed);
        _attestAmendment(id, a, keccak256("prospective-rate"));
        vm.expectEmit(true, true, false, true, address(bridge));
        emit ClaimBridge.TermsAmended(id, keccak256("prospective-rate"), expectedHash);
        bridge.amendTerms(id, keccak256("prospective-rate"), a);
        assertTrue(source.observedConsumed());
        assertEq(source.observedOldFacility(), keccak256(abi.encode(prior)));
        assertEq(source.amendmentAt(), START + 10 days);
        assertEq(source.lastTerms().yearSeconds, 360 days);
        assertEq(bridge.facility(id).interestRateBps, 2000);
        (, uint256 interest,) = source.loanFace(id);
        assertEq(interest, 10_000e18);
        vm.warp(START + 20 days);
        (, interest,) = source.loanFace(id);
        assertEq(interest, 30_000e18);
    }

    function test_cash365AmendmentForwardsCorrectYearSeconds() public {
        _activate();
        uint256 id = _fund(false);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 100 days));
        a.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        _amend(id, a, keccak256("cash-365"));
        assertEq(source.lastTerms().yearSeconds, 365 days);
        vm.warp(START + 365);
        (, uint256 interest,) = source.loanFace(id);
        assertEq(interest, AMOUNT * 2000 * 365 / (10_000 * 365 days));
    }

    function test_signedRenewalRestartsAfterMaturityWithoutAccruingAcrossTheStoppedGap() public {
        _activate();
        ClaimBridge.OriginationTerms memory t = _terms(false);
        t.maturity = START + 90 days;
        t.renewable = true;
        t.renewalTermsHash = keccak256("signed-renewal-option");
        uint256 id = _originate(t, address(this));
        _fundId(id);
        vm.warp(START + 100 days);
        source.checkpointAccrual(32);
        (, uint256 interest,) = source.loanFace(id);
        assertEq(interest, 90_000e18);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 120 days));
        a.maturity = START + 180 days;
        _amend(id, a, keccak256("signed-forward-renewal"));
        assertEq(source.lastTerms().maturity, a.maturity);
        assertEq(bridge.facility(id).maturity, a.maturity);
        (, interest,) = source.loanFace(id);
        assertEq(interest, 90_000e18);
        vm.warp(START + 110 days);
        (, interest,) = source.loanFace(id);
        assertEq(interest, 110_000e18);
    }

    function test_enabledAmendmentRejectsUnsupportedTermsBeforeConsumingFact() public {
        _activate();
        uint256 id = _fund(false);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 100 days));
        a.rateType = ClaimBridge.RateType.Variable;
        a.rateIndexRef = keccak256("future-index");
        bytes32 amendment = keccak256("unsupported-variable");
        _attestAmendment(id, a, amendment);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualUnsupportedTerms.selector, id));
        bridge.amendTerms(id, amendment, a);
        assertTrue(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.TermsAmended));
        a.rateType = ClaimBridge.RateType.Fixed;
        a.rateIndexRef = 0;
        a.dayCountConvention = ClaimBridge.DayCountConvention.Thirty360;
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualUnsupportedTerms.selector, id));
        bridge.amendTerms(id, amendment, a);
        assertEq(source.amendments(), 0);
    }

    function test_amendmentFailureRollsBackOracleBridgeBookAndRegistry() public {
        _activate();
        uint256 id = _fund(false);
        vm.warp(START + 10 days);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 100 days));
        bytes32 amendment = keccak256("rejected-by-source");
        _attestAmendment(id, a, amendment);
        bytes32 prior = _economicHash(id);
        source.setRejectAmendment(true);
        vm.expectRevert(BridgeAccrualSource.Fixture_AmendRejected.selector);
        bridge.amendTerms(id, amendment, a);
        assertEq(_economicHash(id), prior);
        assertTrue(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.TermsAmended));
        assertEq(
            uint8(
                oracle.factStatus(
                    id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendment, id, a))
                )
            ),
            uint8(IAttestationOracle.FactStatus.Recorded)
        );
        assertEq(source.amendments(), 0);
        assertFalse(source.busy());
        source.setRejectAmendment(false);
        bridge.amendTerms(id, amendment, a);
        assertEq(source.amendments(), 1);
    }

    function test_realOraclePreventsReplayEvenWithNewSignedNonce() public {
        _activate();
        uint256 id = _fund(false);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 100 days));
        bytes32 amendment = keccak256("real-fact-once");
        _amend(id, a, amendment);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, id));
        bridge.amendTerms(id, amendment, a);
        bytes32 payload = keccak256(abi.encode(amendment, id, a));
        IAttestationOracle.AttestationInput memory input =
            _input(id, IAttestationOracle.AttestationKind.TermsAmended, payload);
        bytes[] memory signatures = _signatures(input);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(id, input.kind, payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(input, signatures);
        assertEq(source.amendments(), 1);
    }

    function test_amendmentCannotReuseAttestationForDifferentTermsOrFacility() public {
        _activate();
        uint256 first = _fund(false);
        uint256 second = _fund(false);
        ClaimBridge.Amendment memory a = _amendment(first, 2000, uint64(START + 100 days));
        bytes32 amendment = keccak256("exact-shape");
        _attestAmendment(first, a, amendment);
        a.interestRateBps = 2001;
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, first));
        bridge.amendTerms(first, amendment, a);
        a.interestRateBps = 2000;
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, second));
        bridge.amendTerms(second, amendment, a);
        assertEq(source.amendments(), 0);
    }

    function test_partialPikPaymentAndAmendmentPreserveFrozenBasisUntilNewSignedDate() public {
        _activate();
        uint256 id = _fund(true);
        vm.warp(START + 10 days);
        source.repayPrincipal(id, AMOUNT / 4);
        assertEq(source.frozenBasis(id), AMOUNT);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 120 days));
        _amend(id, a, keccak256("new-signed-pik-date"));
        assertEq(source.frozenBasis(id), AMOUNT);
        assertEq(source.nextCapitalization(id), START + 120 days);
        (uint256 principal, uint256 interest,) = source.loanFace(id);
        assertEq(principal, AMOUNT * 3 / 4);
        assertEq(interest, 10_000e18);
        vm.warp(START + 90 days);
        (uint256 processed, bool fresh) = source.checkpointAccrual(32);
        assertEq(processed, 0);
        assertTrue(fresh);
        assertEq(source.frozenBasis(id), AMOUNT);
        vm.warp(START + 120 days);
        source.checkpointAccrual(32);
        (principal, interest,) = source.loanFace(id);
        assertEq(principal, AMOUNT * 3 / 4 + 230_000e18);
        assertEq(interest, 0);
        assertEq(source.frozenBasis(id), principal);
        assertEq(bridge.facility(id).nextPaymentDue, START + 210 days);
    }

    function test_signedPikAmendmentCanReplaceTheFutureDateWithAnEarlierOne() public {
        _activate();
        uint256 id = _fund(true);
        vm.warp(START + 10 days);
        ClaimBridge.Amendment memory a = _amendment(id, 2000, uint64(START + 60 days));
        a.paymentInterval = 30 days;
        _amend(id, a, keccak256("earlier-signed-date"));
        assertEq(source.frozenBasis(id), AMOUNT);
        assertEq(source.nextCapitalization(id), START + 60 days);
        (uint256 principal, uint256 interest,) = source.loanFace(id);
        assertEq(principal, AMOUNT);
        assertEq(interest, 10_000e18);
        vm.warp(START + 60 days);
        source.checkpointAccrual(32);
        (principal, interest,) = source.loanFace(id);
        assertEq(principal, AMOUNT + 110_000e18);
        assertEq(interest, 0);
        assertEq(bridge.facility(id).nextPaymentDue, START + 90 days);
    }

    function test_reservedDueCallbackAcceptsAmortizingAndExactMaturity() public {
        _activate();
        uint256 id = _fund(true);
        bridge.transitionState(id, ClaimBridge.LoanState.Amortizing);
        source.advance(id, uint64(START + 365 days));
        assertEq(bridge.facility(id).nextPaymentDue, START + 365 days);
    }

    function test_onlyBoundReserveCanAdvancePikDueAndCallbackWorksWhileBusy() public {
        _activate();
        uint256 id = _fund(true);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, address(this)));
        bridge.setAccruedPaymentDue(id, uint64(START + 180 days));
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualDueManaged.selector, id));
        bridge.setNextPaymentDue(id, uint64(START + 180 days));
        vm.expectEmit(true, false, false, true, address(bridge));
        emit ClaimBridge.NextPaymentDueSet(id, uint64(START + 90 days), uint64(START + 180 days));
        source.advance(id, uint64(START + 180 days));
        assertEq(bridge.facility(id).nextPaymentDue, START + 180 days);
    }

    function test_reservedDueCallbackRejectsZeroSamePastMaturityCashAndClosedState() public {
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, address(this)));
        bridge.setAccruedPaymentDue(1, 0);
        _activate();
        uint256 cash = _fund(false);
        uint256 pik = _fund(true);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        source.advance(cash, uint64(START + 180 days));
        uint64[3] memory bad = [uint64(0), uint64(START + 90 days), uint64(START + 365 days + 1)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
            source.advance(pik, bad[i]);
        }
        bridge.transitionState(pik, ClaimBridge.LoanState.Repaid);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_InvalidTransition.selector,
                pik,
                ClaimBridge.LoanState.Repaid,
                ClaimBridge.LoanState.Repaid
            )
        );
        source.advance(pik, uint64(START + 180 days));
    }

    function test_permissionlessBoundedCatchupUpdatesSignedDatesAndSkipsTerminalZero() public {
        _activate();
        ClaimBridge.OriginationTerms memory t = _terms(true);
        t.maturity = START + 180 days;
        uint256 id = _originate(t, address(this));
        _fundId(id);
        vm.warp(START + 180 days);
        vm.prank(address(123));
        (uint256 processed, bool fresh) = source.checkpointAccrual(1);
        assertEq(processed, 1);
        assertFalse(fresh);
        assertEq(bridge.facility(id).nextPaymentDue, START + 180 days);
        vm.prank(address(456));
        (processed, fresh) = source.checkpointAccrual(1);
        assertEq(processed, 1);
        assertTrue(fresh);
        assertEq(source.nextCapitalization(id), 0);
        assertEq(bridge.facility(id).nextPaymentDue, START + 180 days);
    }

    function test_staleAdmissionAndAmendmentCloseWhileRecoveryRemainsIdleOnly() public {
        _activate();
        uint256 pik = _fund(true);
        uint256 cash = _fund(false);
        uint256 pending = _originate(_terms(false), address(this));
        ClaimBridge.Amendment memory a = _amendment(cash, 2000, uint64(START + 100 days));
        bytes32 amendment = keccak256("stale-amend");
        _attestAmendment(cash, a, amendment);
        vm.warp(START + 90 days);
        bytes memory reason = abi.encodeWithSelector(
            AccrualBook.AccrualBook_BoundaryPending.selector, uint64(block.timestamp), uint64(block.timestamp)
        );
        vm.expectRevert(reason);
        bridge.checkFundable(pending);
        vm.expectRevert(reason);
        bridge.amendTerms(cash, amendment, a);
        assertTrue(oracle.isSatisfied(cash, IAttestationOracle.AttestationKind.TermsAmended));
        ClaimBridge.OriginationTerms memory t = _terms(false);
        vm.expectRevert(reason);
        bridge.originate(address(this), t);
        bridge.cancelPending(pending);
        bridge.transitionState(cash, ClaimBridge.LoanState.Amortizing);
        bridge.setNextPaymentDue(cash, uint64(START + 180 days));
        bridge.pause();
        bridge.unpause();
        source.checkpointAccrual(32);
        assertEq(bridge.facility(pik).nextPaymentDue, START + 180 days);
    }

    function test_busyBlocksEveryGovernanceRoleNftAndLegacyLifecycleMutation() public {
        _activate();
        uint256 active = _originate(_terms(false), address(source));
        _fundId(active);
        uint256 pending = _originate(_terms(false), address(source));
        bridge.grantRole(bytes32(0), address(source));
        bridge.grantRole(Roles.CREDIT_ROLE, address(source));
        bridge.grantRole(Roles.ORIGINATOR_ROLE, address(source));
        bridge.grantRole(Roles.GUARDIAN_ROLE, address(source));
        bridge.grantRole(Roles.UPGRADER_ROLE, address(source));
        bytes[] memory calls = new bytes[](17);
        calls[0] = abi.encodeCall(bridge.setRequiredMintAttestations, (1, 7));
        calls[1] = abi.encodeCall(bridge.pause, ());
        calls[2] = abi.encodeCall(bridge.unpause, ());
        calls[3] = abi.encodeWithSignature("grantRole(bytes32,address)", Roles.CREDIT_ROLE, address(123));
        calls[4] = abi.encodeWithSignature("revokeRole(bytes32,address)", bytes32(0), address(this));
        calls[5] = abi.encodeWithSignature("renounceRole(bytes32,address)", Roles.CREDIT_ROLE, address(source));
        calls[6] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementation, bytes(""));
        calls[7] = abi.encodeCall(bridge.approve, (address(123), active));
        calls[8] = abi.encodeCall(bridge.setApprovalForAll, (address(123), true));
        calls[9] = abi.encodeCall(bridge.transferFrom, (address(source), address(this), active));
        calls[10] =
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(source), address(this), active);
        calls[11] = abi.encodeCall(bridge.originate, (address(source), _terms(false)));
        calls[12] = abi.encodeCall(bridge.cancelPending, (pending));
        calls[13] = abi.encodeCall(bridge.transitionState, (active, ClaimBridge.LoanState.Amortizing));
        calls[14] = abi.encodeCall(bridge.setNextPaymentDue, (active, uint64(START + 180 days)));
        calls[15] = abi.encodeCall(
            bridge.amendTerms, (active, keccak256("busy"), _amendment(active, 2000, uint64(START + 100 days)))
        );
        calls[16] = abi.encodeCall(bridge.checkFundable, (pending));
        bytes32 prior = _historicalHash(active);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = source.attack(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(reason), BridgeAccrualSource.Fixture_Busy.selector);
        }
        assertEq(_historicalHash(active), prior);
        assertTrue(bridge.hasRole(bytes32(0), address(this)));
        assertEq(bridge.getApproved(active), address(0));
        assertFalse(bridge.isApprovedForAll(address(source), address(123)));
    }

    function test_idleNftApprovalsTransferRoleChangesAndUpgradeStillWork() public {
        _activate();
        uint256 id = _fund(false);
        bridge.approve(address(123), id);
        assertEq(bridge.getApproved(id), address(123));
        bridge.setApprovalForAll(address(456), true);
        assertTrue(bridge.isApprovedForAll(address(this), address(456)));
        bridge.transferFrom(address(this), address(source), id);
        assertEq(bridge.ownerOf(id), address(source));
        bridge.grantRole(Roles.CREDIT_ROLE, address(123));
        bridge.revokeRole(Roles.CREDIT_ROLE, address(123));
        assertFalse(bridge.hasRole(Roles.CREDIT_ROLE, address(123)));
        bridge.upgradeToAndCall(implementation, "");
        assertEq(bridge.accrualReserve(), address(source));
    }

    function test_optimizedDeploymentFitsEip170() public view {
        assertLe(implementation.code.length, 24_576);
    }

    function testFuzz_cashAmendmentMatchesIndependentPiecewiseCurve(
        uint96 amountSeed,
        uint16 oldSeed,
        uint16 newSeed,
        uint32 elapsedSeed,
        bool actual365
    ) public {
        _activate();
        ClaimBridge.OriginationTerms memory t = _terms(false);
        t.principal = uint256(amountSeed) % 1e24 + 1e18;
        t.interestRateBps = oldSeed % 10_000 + 1;
        uint256 id = _originate(t, address(this));
        _fundId(id);
        uint64 elapsed = uint64(elapsedSeed % uint32(60 days) + 1);
        vm.warp(START + elapsed);
        ClaimBridge.Amendment memory a = _amendment(id, newSeed % 10_000 + 1, uint64(START + 100 days));
        if (actual365) a.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        _amend(id, a, keccak256("fuzz-piecewise"));
        uint256 oldIncome = t.principal * t.interestRateBps * elapsed / (10_000 * 360 days);
        vm.warp(START + elapsed + 1 days);
        (uint256 principal, uint256 interest,) = source.loanFace(id);
        uint256 year = actual365 ? 365 days : 360 days;
        assertEq(principal, t.principal);
        assertEq(interest, oldIncome + t.principal * a.interestRateBps * 1 days / (10_000 * year));
        assertTrue(source.observedConsumed());
    }

    function testFuzz_pikCallbackAcceptsOnlyStrictForwardDatesWithinMaturity(uint64 dateSeed, bool validRange) public {
        _activate();
        uint256 id = _fund(true);
        uint64 nextDue = validRange ? uint64(START + 90 days + 1 + dateSeed % uint64(275 days)) : dateSeed;
        if (nextDue <= START + 90 days || nextDue > START + 365 days) {
            vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
            source.advance(id, nextDue);
            assertEq(bridge.facility(id).nextPaymentDue, START + 90 days);
        } else {
            source.advance(id, nextDue);
            assertEq(bridge.facility(id).nextPaymentDue, nextDue);
        }
    }

    function testFuzz_consumedAmendmentCannotMoveOldPikBasis(uint16 rateSeed, uint32 elapsedSeed, uint96 paidSeed)
        public
    {
        _activate();
        uint256 id = _fund(true);
        uint64 elapsed = uint64(elapsedSeed % uint32(60 days) + 1);
        vm.warp(START + elapsed);
        source.repayPrincipal(id, uint256(paidSeed) % (AMOUNT / 2) + 1);
        uint256 before_ = source.frozenBasis(id);
        ClaimBridge.Amendment memory a = _amendment(id, rateSeed % 10_000 + 1, uint64(START + 120 days));
        _amend(id, a, keccak256("fuzz-frozen-pik"));
        assertEq(source.frozenBasis(id), before_);
        assertEq(before_, AMOUNT);
        assertEq(source.nextCapitalization(id), a.nextPaymentDue);
    }

    function _bind() private {
        bridge.setAccrualReserve(address(source));
        registry.setAccrualReserve(address(source));
    }

    function _activate() private {
        _bind();
        source.setEnabled(true);
    }

    function _fund(bool pik) private returns (uint256 id) {
        id = _originate(_terms(pik), address(this));
        _fundId(id);
    }

    function _fundId(uint256 id) private {
        bridge.checkFundable(id);
        bridge.transitionState(id, ClaimBridge.LoanState.Active);
        source.fund(id);
    }

    function _originate(ClaimBridge.OriginationTerms memory t, address holder) private returns (uint256 id) {
        id = bridge.totalOriginated() + 1;
        _attestTerms(id, t);
        assertEq(bridge.originate(holder, t), id);
    }

    function _attestTerms(uint256 id, ClaimBridge.OriginationTerms memory t) private {
        bytes32 payload = bridge.creditTermsHash(t);
        _attest(_input(id, IAttestationOracle.AttestationKind.AssignmentExecuted, payload));
        _attest(_input(id, IAttestationOracle.AttestationKind.UCCFiled, payload));
        _attest(_input(id, IAttestationOracle.AttestationKind.CreditIssued, payload));
    }

    function _terms(bool pik) private pure returns (ClaimBridge.OriginationTerms memory t) {
        t.classId = 1;
        t.borrowerId = BORROWER;
        t.stateId = STATE;
        t.principal = AMOUNT;
        t.ltvBps = 7500;
        t.interestRateBps = 1000;
        t.maturity = START + 365 days;
        t.fundingRecipient = address(123);
        t.paymentInterval = 90 days;
        t.nextPaymentDue = START + 90 days;
        t.paymentScheduleHash = keccak256("signed-quarterly");
        t.offchainRef = keccak256("signed-facility-ref");
        t.pik = pik;
    }

    function _amendment(uint256 id, uint16 rate, uint64 due) private view returns (ClaimBridge.Amendment memory a) {
        ClaimBridge.Facility memory f = bridge.facility(id);
        a.interestRateBps = rate;
        a.maturity = f.maturity;
        a.paymentInterval = f.paymentInterval;
        a.nextPaymentDue = due;
        a.dayCountConvention = f.dayCountConvention;
        a.paymentScheduleHash = keccak256(abi.encode(id, rate, due));
    }

    function _amend(uint256 id, ClaimBridge.Amendment memory a, bytes32 amendment) private {
        _attestAmendment(id, a, amendment);
        bridge.amendTerms(id, amendment, a);
    }

    function _attestAmendment(uint256 id, ClaimBridge.Amendment memory a, bytes32 amendment) private {
        _attest(_input(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendment, id, a))));
    }

    function _input(uint256 id, IAttestationOracle.AttestationKind kind, bytes32 payload)
        private
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 365 days),
            nonce: ++nonce
        });
    }

    function _signatures(IAttestationOracle.AttestationInput memory a) private view returns (bytes[] memory sigs) {
        uint256 first = vm.addr(KEY_A) < vm.addr(KEY_B) ? KEY_A : KEY_B;
        uint256 second = first == KEY_A ? KEY_B : KEY_A;
        sigs = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(first, oracle.attestationDigest(a));
        sigs[0] = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(second, oracle.attestationDigest(a));
        sigs[1] = abi.encodePacked(r, s, v);
    }

    function _attest(IAttestationOracle.AttestationInput memory a) private {
        oracle.attest(a, _signatures(a));
    }

    function _rejectBind(address candidate) private {
        vm.expectRevert(abi.encodeWithSelector(BridgeAccrualLib.BridgeAccrual_InvalidReserve.selector, candidate));
        bridge.setAccrualReserve(candidate);
        assertEq(bridge.accrualReserve(), address(0));
    }

    function _historicalHash(uint256 id) private view returns (bytes32 result) {
        result = keccak256(abi.encode(bridge.facility(id), bridge.ownerOf(id), bridge.totalOriginated()));
        for (uint256 i; i < 5; ++i) {
            result = keccak256(abi.encode(result, vm.load(address(bridge), bytes32(uint256(LOCATION) + i))));
        }
        for (uint256 c = 1; c <= 3; ++c) {
            result = keccak256(abi.encode(result, bridge.requiredMintAttestations(c)));
        }
    }

    function _economicHash(uint256 id) private view returns (bytes32) {
        (uint256 principal, uint256 interest, uint64 through) = source.loanFace(id);
        return keccak256(
            abi.encode(
                bridge.facility(id),
                principal,
                interest,
                through,
                source.accrualSnapshot(),
                source.nativeFace(id),
                registry.totalBookExposure(),
                registry.classExposure(1)
            )
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
