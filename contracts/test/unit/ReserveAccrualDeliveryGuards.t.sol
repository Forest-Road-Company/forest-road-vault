// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";

contract DeliveryGuardToken is ERC20 {
    constructor() ERC20("Delivery fixture", "DFX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Isolates the reserve's closing proofs from the controller's earlier independent checks.
///      Owner-only seeders create invalid local states; this is not a production reserve fixture.
contract DeliveryGuardHost {
    using AccrualBook for AccrualBook.Book;

    address private immutable OWNER = msg.sender;
    DeliveryGuardToken private custody;

    modifier onlyOwner() {
        require(msg.sender == OWNER, "fixture owner");
        _;
    }

    function seed(address token, address controller, address vault, address fee, address asset) external onlyOwner {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.modules.token = token;
        s.modules.controller = controller;
        s.modules.vault = vault;
        s.modules.waterfall = OWNER;
        s.feeRecipient = fee;
        s.enabled = true;
        uint64 at = uint64(block.timestamp);
        s.loans.book.initialize(at, 1000);
        s.loans.book.register(1, [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))], at);
        s.loans.book.open(1, 100e18, at, at + 10);
        ReserveManager.ReserveStorage storage n = _native();
        n.totalDeployedPrincipal = 1000e18;
        n.idleUSDCUnits = 10e6;
        n.usdcToken = IERC20(asset);
        custody = DeliveryGuardToken(asset);
        custody.mint(address(this), 10e6);
    }

    /// @dev Test-only native storage pointer pinned independently of the library under review.
    function _native() private pure returns (ReserveManager.ReserveStorage storage n) {
        bytes32 slot = 0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;
        assembly ("memory-safe") {
            n.slot := slot
        }
    }

    function fixtureAdmission(bool enabled, uint256 nonce) external onlyOwner {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.enabled = enabled;
        s.nonce = nonce;
    }

    function fixtureCallback(uint8 mode) external {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        require(msg.sender == s.modules.controller && s.delivery.active, "fixture callback");
        if (mode == 4 || mode == 5) --s.loans.book.seniorIssued;
        if (mode == 5) ++s.loans.book.feeIssued;
        if (mode == 6) --_native().totalDeployedPrincipal;
        if (mode == 7) custody.burn(address(this), 1);
    }

    function materializeAccrued(uint8 legs) external returns (uint256 senior, uint256 fee) {
        return ReserveAccrualLib.materialize(_native(), legs);
    }

    function setFee(uint16 bps, address recipient) external {
        ReserveAccrualLib.setFee(_native(), bps, recipient);
    }

    function accrualSnapshot() external view returns (IContinuousAccrual.Snapshot memory) {
        return ReserveAccrualLib.snapshot();
    }

    function accrualDelivery() external view returns (IContinuousAccrual.Delivery memory) {
        return abi.decode(ReserveAccrualLib.deliveryData(), (IContinuousAccrual.Delivery));
    }

    function stateDigest() external view returns (bytes32) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        (uint256 backing, uint256 recognized) = ReserveAccrualLib.rawBacking(_native());
        return keccak256(
            abi.encode(
                ReserveAccrualLib.snapshot(),
                s.loans.book.seniorIssued,
                s.loans.book.feeIssued,
                s.nonce,
                s.delivery,
                s.busy,
                backing,
                recognized,
                custody.balanceOf(address(this))
            )
        );
    }
}

contract DeliveryGuardVault {
    DeliveryGuardHost private immutable reserve;
    DeliveryGuardToken private immutable token;
    address private immutable OWNER = msg.sender;
    bool private allowed = true;

    constructor(DeliveryGuardHost reserve_, DeliveryGuardToken token_) {
        reserve = reserve_;
        token = token_;
    }

    function fixtureAllowed(bool value) external {
        require(msg.sender == OWNER, "fixture owner");
        allowed = value;
    }

    function accrualPricingState() external view returns (IContinuousAccrual.PricingState memory p) {
        IContinuousAccrual.Snapshot memory s = reserve.accrualSnapshot();
        p.entryAssets = token.balanceOf(address(this)) + s.seniorUnissued;
        p.materializationAllowed = allowed;
    }
}

contract DeliveryGuardController {
    DeliveryGuardHost private immutable reserve;
    DeliveryGuardToken private immutable token;
    address private immutable OWNER = msg.sender;
    uint8 private mode;
    address internal constant STRANGER = address(0xbad);

    constructor(DeliveryGuardHost reserve_, DeliveryGuardToken token_) {
        reserve = reserve_;
        token = token_;
    }

    function fixtureMode(uint8 value) external {
        require(msg.sender == OWNER, "fixture owner");
        mode = value;
    }

    function isYieldSink(address) external pure returns (bool) {
        return true;
    }

    function mintAccrued(uint256 nonce) external {
        require(msg.sender == address(reserve), "fixture reserve");
        IContinuousAccrual.Delivery memory d = reserve.accrualDelivery();
        require(d.active && d.nonce == nonce, "fixture permit");
        token.mint(d.vault, d.senior);
        token.mint(d.feeRecipient, d.fee);
        if (mode == 1) token.mint(STRANGER, 1);
        if (mode == 2 || mode == 3) {
            token.burn(mode == 2 ? d.vault : d.feeRecipient, 1);
            token.mint(STRANGER, 1);
        }
        if (mode >= 4) reserve.fixtureCallback(mode);
    }
}

contract ReserveAccrualDeliveryGuardsTest is Test {
    DeliveryGuardHost private reserve;
    DeliveryGuardToken private token;
    DeliveryGuardVault private vault;
    DeliveryGuardController private controller;
    address private constant FEE = address(0xfee);

    function setUp() public {
        vm.warp(1_800_000_000);
        reserve = new DeliveryGuardHost();
        token = new DeliveryGuardToken();
        vault = new DeliveryGuardVault(reserve, token);
        controller = new DeliveryGuardController(reserve, token);
        reserve.seed(address(token), address(controller), address(vault), FEE, address(new DeliveryGuardToken()));
        token.mint(address(vault), 1000e18);
        vm.warp(block.timestamp + 5);
        assertEq(reserve.accrualSnapshot().gross, 50e18);
        assertEq(reserve.accrualSnapshot().seniorUnissued, 45e18);
        assertEq(reserve.accrualSnapshot().feeUnissued, 5e18);
    }

    function _digest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                reserve.stateDigest(),
                token.totalSupply(),
                token.balanceOf(address(vault)),
                token.balanceOf(FEE),
                token.balanceOf(address(0xbad))
            )
        );
    }

    function _positiveDelivery() private {
        controller.fixtureMode(0);
        (uint256 senior, uint256 fee) = reserve.materializeAccrued(3);
        assertEq(senior, 45e18);
        assertEq(fee, 5e18);
        assertEq(token.totalSupply(), 1050e18);
        assertEq(token.balanceOf(address(vault)), 1045e18);
        assertEq(token.balanceOf(FEE), 5e18);
        assertEq(reserve.accrualSnapshot().unissued, 0);
        assertFalse(reserve.accrualDelivery().active);
        bytes32 before_ = _digest();
        (senior, fee) = reserve.materializeAccrued(3);
        assertEq(senior + fee, 0);
        assertEq(_digest(), before_, "empty delivery changed state");
    }

    /// @dev Each mode changes just the first failing measurement; expected deltas are independent constants.
    function test_eachClosingProofRefusesItsOwnMismatchAndRollsBack() public {
        uint256[7] memory expected = [uint256(1050e18), 1045e18, 5e18, 1050e18, 1045e18, 1060e18, 1060e18];
        for (uint8 measurement; measurement < 7; ++measurement) {
            controller.fixtureMode(measurement + 1);
            uint256 actual = expected[measurement];
            if (measurement == 0 || measurement == 3 || measurement == 4) ++actual;
            else actual -= measurement == 6 ? 1e12 : 1;
            bytes32 before_ = _digest();
            vm.expectRevert(
                abi.encodeWithSelector(
                    ReserveAccrualLib.ReserveAccrual_DeliveryMismatch.selector,
                    measurement,
                    expected[measurement],
                    actual
                )
            );
            reserve.materializeAccrued(measurement == 4 ? 1 : 3);
            assertEq(_digest(), before_, "failed proof leaked state or balances");
        }
        _positiveDelivery();
    }

    function test_disabledDeliveryRefusesWithoutConsumingClaims() public {
        reserve.fixtureAdmission(false, 0);
        bytes32 before_ = _digest();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotEnabled.selector);
        reserve.materializeAccrued(3);
        assertEq(_digest(), before_);
        reserve.fixtureAdmission(true, 0);
        _positiveDelivery();
    }

    function test_feeSynchronizationChecksCallerActivationAndBound() public {
        bytes32 before_ = _digest();
        vm.prank(address(0x123));
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotWaterfall.selector);
        reserve.setFee(1000, FEE);
        assertEq(_digest(), before_);
        reserve.fixtureAdmission(false, 0);
        before_ = _digest();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NotEnabled.selector);
        reserve.setFee(1000, FEE);
        assertEq(_digest(), before_);
        reserve.fixtureAdmission(true, 0);
        before_ = _digest();
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_InvalidFee.selector, 2001));
        reserve.setFee(2001, FEE);
        assertEq(_digest(), before_);
        reserve.setFee(1000, FEE);
        _positiveDelivery();
    }

    function test_busyVaultRefusesBeforeIssuanceAndNonceUse() public {
        vault.fixtureAllowed(false);
        bytes32 before_ = _digest();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_VaultBusy.selector);
        reserve.materializeAccrued(3);
        assertEq(_digest(), before_);
        vault.fixtureAllowed(true);
        _positiveDelivery();
    }

    function test_exhaustedNonceRefusesWithSpecificErrorAndNoIssuance() public {
        reserve.fixtureAdmission(true, type(uint256).max);
        bytes32 before_ = _digest();
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_NonceOverflow.selector);
        reserve.materializeAccrued(3);
        assertEq(_digest(), before_);
        reserve.fixtureAdmission(true, 0);
        _positiveDelivery();
    }

    /// @dev Finds the explicit admission refusal, rather than mistaking an empty out-of-gas result for it.
    function test_deliveryGasAdmissionHasAnExplicitRefusalAndASuccessfulContinuation() public {
        bool sawRefusal;
        bool sawSuccess;
        bytes32 before_ = _digest();
        for (uint256 budget = 600_000; budget <= 4_000_000; budget += 100_000) {
            uint256 saved = vm.snapshotState();
            (bool ok, bytes memory result) =
                address(reserve).call{gas: budget}(abi.encodeCall(DeliveryGuardHost.materializeAccrued, (3)));
            if (ok) {
                assertEq(reserve.accrualSnapshot().unissued, 0);
                assertEq(token.totalSupply(), 1050e18);
                sawSuccess = true;
            } else if (bytes4(result) == ReserveAccrualLib.ReserveAccrual_InsufficientDeliveryGas.selector) {
                assertEq(result.length, 36);
                uint256 available;
                assembly ("memory-safe") {
                    available := mload(add(result, 36))
                }
                assertGt(available, 0);
                assertLe(available, 550_000);
                assertEq(_digest(), before_, "gas refusal leaked state");
                sawRefusal = true;
            }
            assertTrue(vm.revertToStateAndDelete(saved));
            if (sawRefusal && sawSuccess) break;
        }
        assertTrue(sawRefusal, "explicit delivery gas refusal was never reached");
        assertTrue(sawSuccess, "sufficient continuation gas never succeeded");
        _positiveDelivery();
    }
}
