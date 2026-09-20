// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {ICascadeBackstop} from "../../src/interfaces/ICascadeBackstop.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {ReserveStorageLib} from "../../src/libraries/ReserveStorageLib.sol";
import {DeliveryGuardToken} from "./ReserveAccrualDeliveryGuards.t.sol";

/// @dev Tests the allocation library after contractual closure. Seeders are local and owner-only;
///      real closure, authority and shared-capital integration are covered by native lifecycle tests.
contract RoundingGuardHost {
    using AccrualBook for AccrualBook.Book;
    using ReserveStorageLib for ReserveManager.ReserveStorage;

    address private immutable OWNER = msg.sender;

    modifier onlyOwner() {
        require(msg.sender == OWNER, "fixture owner");
        _;
    }

    function seed(address token, address vault, address controller, address curator, address backstop, address notifications)
        external onlyOwner
    {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.modules.token = token;
        s.modules.vault = vault;
        s.modules.controller = controller;
        s.modules.registry = notifications;
        s.modules.defaultManager = notifications;
        s.feeRecipient = address(0xfee);
        s.enabled = true;
        s.busy = true;
        uint64 at = uint64(block.timestamp);
        s.loans.book.initialize(at - 10, 1000);
        s.loans.book.register(1, [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))], at - 10);
        s.loans.book.open(1, 50e18, at - 10, at);
        s.loans.book.finishNext(at);
        s.loans.book.takePosting(1, at);
        s.loans.book.takeIssuance(1, at);
        s.loans.loans[1].terms.scale = 1e12;
        s.loans.loans[1].closureNonce = 9;
        s.identities[1].classId = 1;
        s.recordedFace = 1000e18;
        ReserveManager.ReserveStorage storage n = _native();
        n.deployed[1] = 1000e18;
        n.totalDeployedPrincipal = 1000e18;
        n.lossCurator = ICuratorModule(curator);
        n.lossBackstop = ICascadeBackstop(backstop);
    }

    /// @dev Test-only pointer to the independently pinned native proxy slot.
    function _native() private pure returns (ReserveManager.ReserveStorage storage n) {
        bytes32 slot = 0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;
        assembly ("memory-safe") {
            n.slot := slot
        }
    }

    function fixtureMark(uint256 mark, uint256 prepaid) external onlyOwner {
        ReserveManager.ReserveStorage storage n = _native();
        n.principalImpairment[1] = mark;
        n.totalPrincipalImpairment = mark;
        n.exitPrepaidAbsorption = prepaid;
    }

    function fixtureAdmission(uint8 mode) external onlyOwner {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (mode == 0) s.busy = false;
        if (mode == 1) s.delivery.active = true;
        if (mode == 2) s.rounding.active = true;
        if (mode == 3) s.loans.loans[1].terms.scale = 900;
        if (mode == 4) ++s.loans.loans[1].closureNonce;
        if (mode == 5) --s.loans.book.seniorIssued;
        if (mode == 6) s.feeRecipient = s.modules.vault;
    }

    function fixtureBurn(bool busy, bool active, bool ready, bool delivery, address from, uint256 amount)
        external onlyOwner
    {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.busy = busy;
        s.delivery.active = delivery;
        s.rounding.active = active;
        s.rounding.ready = ready;
        s.rounding.from = from;
        s.rounding.amount = amount;
    }

    function consumeBurn(address caller, address from, uint256 amount) external returns (bool) {
        return ReserveRoundingLib.consumeBurn(caller, from, amount);
    }

    function fixtureCallback(uint8 mode) external {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        require(msg.sender == s.modules.controller && s.rounding.active, "fixture callback");
        if (mode == 5) ++_native().totalDeployedPrincipal;
        if (mode == 6) ++s.loans.book.feeIssued;
    }

    function allocate(uint256 loss) external onlyOwner {
        AccrualLoans.LifecycleWork memory work;
        work.facilityId = 1;
        work.closureNonce = 9;
        work.roundingLoss = loss;
        work.at = uint64(block.timestamp);
        ReserveRoundingLib.allocate(_native(), work);
    }

    function values() public view returns (uint256[7] memory v) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        ReserveManager.ReserveStorage storage n = _native();
        v[0] = n.deployed[1];
        v[1] = n.principalImpairment[1];
        v[2] = n.exitPrepaidAbsorption;
        v[3] = n.backingValue();
        v[4] = s.roundingUnabsorbed;
        v[5] = s.loans.book.snapshot(uint64(block.timestamp)).unissued;
        v[6] = s.loans.book.snapshot(uint64(block.timestamp)).gross;
    }

    function stateDigest() external view returns (bytes32) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        ReserveManager.ReserveStorage storage n = _native();
        return keccak256(abi.encode(values(), n.totalDeployedPrincipal, n.totalPrincipalImpairment,
            s.recordedFace, s.rounding, s.busy, s.delivery.active));
    }

    function roundingActive() external view returns (bool) {
        return ReserveAccrualStorageLib.state().rounding.active;
    }
}

contract RoundingGuardVault {
    DeliveryGuardToken private immutable token;

    constructor(DeliveryGuardToken token_) { token = token_; }

    function totalAssets() external view returns (uint256) { return token.balanceOf(address(this)); }
}

contract RoundingGuardJunior {
    DeliveryGuardToken private immutable token;
    RoundingGuardHost private immutable reserve;
    address private immutable OWNER = msg.sender;
    uint8 private mode;
    uint256 public calls;

    constructor(DeliveryGuardToken token_, RoundingGuardHost reserve_) { token = token_; reserve = reserve_; }

    function fixtureMode(uint8 value) external {
        require(msg.sender == OWNER, "fixture owner");
        mode = value;
    }

    function poolBalance(uint256) external view returns (uint256) { return token.balanceOf(address(this)); }
    function remainingCoverage(uint256) external view returns (uint256) { return token.balanceOf(address(this)); }

    function _deliver(uint256 loss) private returns (uint256 amount) {
        require(msg.sender == address(reserve), "fixture reserve");
        ++calls;
        amount = token.balanceOf(address(this));
        if (amount > loss) amount = loss;
        require(token.transfer(address(reserve), mode == 3 ? amount - 1 : amount), "fixture transfer");
    }

    function absorbLoss(uint256 classId, uint256 loss) external returns (uint256 absorbed, uint256 residual) {
        require(classId == 1, "fixture class");
        absorbed = _deliver(loss);
        residual = loss - absorbed;
        if (mode == 1) ++absorbed;
        if (mode == 2) ++residual;
    }

    function coverShortfall(uint256 id, uint256 loss) external returns (uint256 covered) {
        require(id == 1, "fixture facility");
        covered = _deliver(loss);
        if (mode == 1) ++covered;
    }
}

contract RoundingGuardNotifications {
    address private immutable reserve;
    uint256 public registryReduction;
    uint256 public riskReduction;

    constructor(address reserve_) { reserve = reserve_; }

    function recordAccruedWriteDown(uint256 classId, bytes32, bytes32, uint256 amount) external {
        require(msg.sender == reserve && classId == 1, "fixture registry callback");
        registryReduction += amount;
    }

    function onAccrualRounding(uint256 id, uint256 amount) external {
        require(msg.sender == reserve && id == 1, "fixture risk callback");
        riskReduction += amount;
    }
}

contract RoundingGuardController {
    DeliveryGuardToken private immutable token;
    RoundingGuardHost private immutable reserve;
    address private immutable vault;
    address private immutable OWNER = msg.sender;
    uint8 private mode;
    uint256 public calls;

    constructor(DeliveryGuardToken token_, RoundingGuardHost reserve_, address vault_) {
        token = token_; reserve = reserve_; vault = vault_;
    }

    function fixtureMode(uint8 value) external {
        require(msg.sender == OWNER, "fixture owner");
        mode = value;
    }

    function burnLoss(address from, uint256 amount) external {
        require(msg.sender == address(reserve), "fixture reserve");
        ++calls;
        if (mode != 1) require(reserve.consumeBurn(msg.sender, from, amount), "fixture permit");
        token.burn(from, amount);
        if (calls != 1) return;
        if (mode == 2) token.mint(address(0xbad), 1);
        if (mode == 3 || mode == 4) {
            token.burn(vault, 1);
            token.mint(mode == 3 ? address(reserve) : address(0xbad), 1);
        }
        if (mode == 5 || mode == 6) reserve.fixtureCallback(mode);
    }
}

contract ReserveAccrualRoundingGuardsTest is Test {
    struct Model {
        uint256 loss;
        uint256 mark;
        uint256 prepaid;
        uint256 curator;
        uint256 backstop;
        uint256 senior;
        uint256 unabsorbed;
    }

    RoundingGuardHost private reserve;
    DeliveryGuardToken private token;
    RoundingGuardVault private vault;
    RoundingGuardController private controller;
    RoundingGuardJunior private curator;
    RoundingGuardJunior private backstop;
    RoundingGuardNotifications private notifications;
    uint256 private constant LOSS = 900;

    event AccrualRoundingAllocated(uint256 indexed facilityId, uint64 indexed closureNonce, uint256 amount,
        uint256 prepaid, uint256 curator, uint256 backstop, uint256 senior, uint256 unabsorbed, uint256 markConsumed);

    function _hasBackstop() private pure returns (bool) { return true; }

    function setUp() public {
        vm.warp(1_800_000_000);
        reserve = new RoundingGuardHost();
        token = new DeliveryGuardToken();
        vault = new RoundingGuardVault(token);
        controller = new RoundingGuardController(token, reserve, address(vault));
        curator = new RoundingGuardJunior(token, reserve);
        backstop = new RoundingGuardJunior(token, reserve);
        notifications = new RoundingGuardNotifications(address(reserve));
        reserve.seed(address(token), address(vault), address(controller), address(curator), address(backstop), address(notifications));
        token.mint(address(vault), 1000);
        token.mint(address(curator), 200);
        if (_hasBackstop()) token.mint(address(backstop), 300);
        assertEq(reserve.values()[5], 5e18);
    }

    function _digest() private view returns (bytes32) {
        return keccak256(abi.encode(reserve.stateDigest(), token.totalSupply(),
            token.balanceOf(address(reserve)), token.balanceOf(address(vault)), token.balanceOf(address(curator)),
            token.balanceOf(address(backstop)), token.balanceOf(address(0xbad)), curator.calls(), backstop.calls(),
            controller.calls(), notifications.registryReduction(), notifications.riskReduction()));
    }

    function _expectInvalid(uint256 loss) private {
        bytes32 before_ = _digest();
        vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
        reserve.allocate(loss);
        assertEq(_digest(), before_, "invalid allocation changed state");
    }

    function test_allocationAdmissionChecksEveryRequiredStateAndClaim() public {
        // Full prepayment prevents a later burn guard from masking the allocator's own admission.
        reserve.fixtureMark(LOSS, LOSS);
        for (uint8 mode; mode < 7; ++mode) {
            uint256 saved = vm.snapshotState();
            reserve.fixtureAdmission(mode);
            _expectInvalid(LOSS);
            assertTrue(vm.revertToStateAndDelete(saved));
        }
        _expectInvalid(0);
        reserve.allocate(LOSS);
        assertFalse(reserve.roundingActive());
        assertEq(controller.calls(), 0);
    }

    function test_burnPermitRequiresExactCallerStateAndAmountAndCannotBeReused() public {
        vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
        reserve.consumeBurn(address(reserve), address(vault), 123);
        vm.prank(address(controller));
        assertFalse(reserve.consumeBurn(address(reserve), address(vault), 123));
        for (uint8 mode; mode < 7; ++mode) {
            uint256 saved = vm.snapshotState();
            uint256 requested = mode == 5 ? 124 : (mode == 6 ? 0 : 123);
            reserve.fixtureBurn(mode != 0, true, mode != 2, mode == 1, address(vault), mode == 6 ? 0 : 123);
            bytes32 before_ = _digest();
            vm.prank(address(controller));
            vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
            reserve.consumeBurn(mode == 3 ? address(0xbad) : address(reserve),
                mode == 4 ? address(0xbad) : address(vault), requested);
            assertEq(_digest(), before_);
            assertTrue(vm.revertToStateAndDelete(saved));
        }
        reserve.fixtureBurn(true, true, true, false, address(vault), 123);
        vm.prank(address(controller));
        assertTrue(reserve.consumeBurn(address(reserve), address(vault), 123));
        vm.prank(address(controller));
        vm.expectRevert(ReserveRoundingLib.AccrualRounding_InvalidContinuation.selector);
        reserve.consumeBurn(address(reserve), address(vault), 123);
    }

    function test_controllerMustConsumeItsArmedBurn() public {
        controller.fixtureMode(1);
        _expectInvalid(LOSS);
        controller.fixtureMode(0);
        reserve.allocate(LOSS);
        assertFalse(reserve.roundingActive());
    }

    function _expectDelta(uint8 measurement, uint256 expected, uint256 actual) private {
        bytes32 before_ = _digest();
        vm.expectRevert(abi.encodeWithSelector(ReserveRoundingLib.AccrualRounding_DeltaMismatch.selector,
            measurement, expected, actual));
        reserve.allocate(LOSS);
        assertEq(_digest(), before_, "failed rounding proof leaked state or capital");
    }

    function test_allFiveClosingMeasurementsRejectTheirOwnMismatch() public {
        uint256 senior = LOSS - 200 - (_hasBackstop() ? 300 : 0);
        uint256[5] memory expected = [token.totalSupply() - LOSS, uint256(0), 1000 - senior, 1000e18 - LOSS, 5e18];
        for (uint8 mode; mode < 5; ++mode) {
            controller.fixtureMode(mode + 2);
            uint256 actual = expected[mode];
            if (mode == 2 || mode == 4) --actual;
            else ++actual;
            _expectDelta(mode == 4 ? 7 : mode, expected[mode], actual);
        }
        controller.fixtureMode(0);
        reserve.allocate(LOSS);
        assertEq(reserve.values()[5], 5e18);
    }

    function test_curatorReturnResidualAndDeliveryAreIndependentlyMeasured() public {
        for (uint8 mode = 1; mode <= 3; ++mode) {
            curator.fixtureMode(mode);
            uint256 expected = mode == 2 ? LOSS - 200 : 200;
            _expectDelta(mode + 3, expected, mode == 3 ? expected - 1 : expected + 1);
        }
        curator.fixtureMode(0);
        reserve.allocate(LOSS);
        assertEq(token.balanceOf(address(curator)), 0);
    }

    function test_backstopReportedAndDeliveredCoverageAreIndependentlyMeasured() public {
        backstop.fixtureMode(1);
        _expectDelta(8, 300, 301);
        backstop.fixtureMode(3);
        _expectDelta(9, 500, 499);
        backstop.fixtureMode(0);
        reserve.allocate(LOSS);
        assertEq(token.balanceOf(address(backstop)), 0);
    }

    function _capital(address account, uint256 amount) private {
        token.burn(account, token.balanceOf(account));
        token.mint(account, amount);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) { return a < b ? a : b; }

    /// @dev Independent sequential allocation with explicit exhausted-capital and prepaid-mark arithmetic.
    function testFuzz_roundingConservesValueAndFeesThroughTheOrderedCascade(uint256 seed) public {
        Model memory m;
        m.loss = 1 + uint16(seed) % 2000;
        uint256 mark = uint16(seed >> 16) % 2500;
        uint256 prepaid = uint16(seed >> 32) % 2500;
        uint256 curatorCapital = uint16(seed >> 48) % 1000;
        uint256 backstopCapital = _hasBackstop() ? uint16(seed >> 64) % 1000 : 0;
        uint256 seniorCapital = uint16(seed >> 80) % 1500;
        _capital(address(curator), curatorCapital);
        _capital(address(backstop), backstopCapital);
        _capital(address(vault), seniorCapital);
        reserve.fixtureMark(mark, prepaid);
        uint256 supply = token.totalSupply();
        m.mark = _min(mark, m.loss);
        m.prepaid = _min(prepaid, m.mark);
        m.curator = _min(curatorCapital, m.loss - m.prepaid);
        m.backstop = _min(backstopCapital, m.loss - m.prepaid - m.curator);
        m.senior = _min(seniorCapital, m.loss - m.prepaid - m.curator - m.backstop);
        m.unabsorbed = m.loss - m.prepaid - m.curator - m.backstop - m.senior;
        vm.expectEmit(true, true, false, true, address(reserve));
        emit AccrualRoundingAllocated(1, 9, m.loss, m.prepaid, m.curator, m.backstop, m.senior, m.unabsorbed, m.mark);
        reserve.allocate(m.loss);
        uint256[7] memory v = reserve.values();
        assertEq(v[0], 1000e18 - m.loss);
        assertEq(v[1], mark - m.mark);
        assertEq(v[2], prepaid - m.prepaid);
        assertEq(v[3], 1000e18 - mark - (m.loss - m.mark));
        assertEq(v[4], m.unabsorbed);
        assertEq(v[5], 5e18, "earned fee claim was consumed");
        assertEq(v[6], 50e18, "earned gross was rewritten");
        assertEq(token.totalSupply(), supply - m.curator - m.backstop - m.senior);
        assertEq(token.balanceOf(address(curator)), curatorCapital - m.curator);
        assertEq(token.balanceOf(address(backstop)), backstopCapital - m.backstop);
        assertEq(token.balanceOf(address(vault)), seniorCapital - m.senior);
        assertEq(token.balanceOf(address(reserve)), 0);
        assertEq(notifications.registryReduction(), m.loss);
        assertEq(notifications.riskReduction(), m.loss);
        assertFalse(reserve.roundingActive());
    }

    function test_roundingGasAdmissionRefusesExplicitlyAndLaterCompletes() public {
        bool refused;
        bool succeeded;
        bytes32 before_ = _digest();
        for (uint256 budget = 400_000; budget <= 4_000_000; budget += 100_000) {
            uint256 saved = vm.snapshotState();
            (bool ok, bytes memory result) = address(reserve).call{gas: budget}(abi.encodeCall(RoundingGuardHost.allocate, (LOSS)));
            if (ok) {
                assertEq(reserve.values()[0], 1000e18 - LOSS);
                assertFalse(reserve.roundingActive());
                succeeded = true;
            } else if (bytes4(result) == ReserveRoundingLib.AccrualRounding_InsufficientGas.selector) {
                assertEq(result.length, 4);
                assertEq(_digest(), before_);
                refused = true;
            }
            assertTrue(vm.revertToStateAndDelete(saved));
            if (refused && succeeded) break;
        }
        assertTrue(refused, "explicit rounding gas refusal not reached");
        assertTrue(succeeded, "sufficient rounding continuation never completed");
    }
}
