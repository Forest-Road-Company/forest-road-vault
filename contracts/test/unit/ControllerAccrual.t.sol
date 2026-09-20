// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {USDfr} from "../../src/USDfr.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IContinuousAccrual, IAccrualController, IAccrualToken} from "../../src/interfaces/IContinuousAccrual.sol";
import {ControllerAccrualLib} from "../../src/libraries/ControllerAccrualLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {PointsHook_InsufficientGas} from "../../src/libraries/PointsHookGas.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

contract ControllerAccrualCompliance {
    mapping(address => bool) public isProtocolExempt;
    address public blockedRecipient;

    function isAllowed(address) external pure returns (bool) {
        return true;
    }

    function canTransfer(address, address, address to) external view returns (bool) {
        return blockedRecipient == address(0) || to != blockedRecipient;
    }

    function setBlocked(address account) external {
        blockedRecipient = account;
    }

    function setExempt(address account) external {
        isProtocolExempt[account] = true;
    }
}

contract ControllerAccrualVault {
    address public immutable asset;

    constructor(address token) {
        asset = token;
    }
}

/// @dev Independent one-asset reserve with explicit virtual debits and operation snapshots.
///      Test controls intentionally permit bad modules, stale clocks and malformed operations.
///      It is not a substitute for the production reserve's accrual arithmetic or loan lifecycle.
contract ControllerAccrualReserve is IContinuousAccrual {
    error Reserve_AdmissionDenied();
    error Reserve_RawDeliveryMismatch();

    Modules private _modules;
    Snapshot private _snapshot;
    Delivery private _delivery;
    address private _asset;
    uint256 private _idleUnits;
    uint256 private _backing;
    uint256 private _recognized;
    uint256 public nonce;
    uint256 public exitPrepaidAbsorption;
    bool public paused;
    bool public busy;
    address public lossAbsorber;
    uint256 public depositBonusMint;
    uint256 public armId;
    uint256 public incidentId;

    function configure(Modules memory modules_, address asset) external {
        _modules = modules_;
        _asset = asset;
        _snapshot.enabled = true;
        _snapshot.fresh = true;
        _snapshot.feeRecipient = address(0xfee);
    }

    function setModules(Modules memory modules_) external {
        _modules = modules_;
    }

    function seed(uint256 units, uint256 backing_, uint256 recognized_) external {
        _idleUnits = units;
        _backing = backing_;
        _recognized = recognized_;
    }

    function setBacking(uint256 backing_, uint256 recognized_) external {
        _backing = backing_;
        _recognized = recognized_;
    }

    function setVirtual(uint256 senior, uint256 fee, address feeRecipient) external {
        _snapshot.gross = senior + fee;
        _snapshot.unposted = senior + fee;
        _snapshot.unissued = senior + fee;
        _snapshot.seniorUnissued = senior;
        _snapshot.feeUnissued = fee;
        _snapshot.feeRecipient = feeRecipient;
        _snapshot.accruedThrough = uint64(block.timestamp);
    }

    function setFresh(bool fresh) external {
        _snapshot.fresh = fresh;
    }

    function setBusy(bool busy_) external {
        busy = busy_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setRetention(uint256 retained) external {
        exitPrepaidAbsorption = retained;
    }

    function setLossAbsorber(address source) external {
        lossAbsorber = source;
    }

    function recordExitPrepayment(uint256 amount) external {
        exitPrepaidAbsorption += amount;
    }

    function setPermit(Delivery memory permit) external {
        _delivery = permit;
    }

    function relayDelivery(uint256 nonce_) external {
        IAccrualController(_modules.controller).mintAccrued(nonce_);
    }

    function accrualModules() external view returns (Modules memory) {
        return _modules;
    }

    function accrualSnapshot() external view returns (Snapshot memory) {
        return _snapshot;
    }

    function accrualDelivery() external view returns (Delivery memory) {
        return _delivery;
    }

    function requireAccrualFresh() public view {
        if (!_snapshot.fresh || _delivery.active || busy) revert Reserve_AdmissionDenied();
    }

    /// @dev This component fixture owns no contractual rounding permits; native burns use its normal gate.
    function consumeAccrualLossBurn(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function materializeAccrued(uint8 legs) external returns (uint256 senior, uint256 fee) {
        requireAccrualFresh();
        senior = legs & 1 == 0 ? 0 : _snapshot.seniorUnissued;
        fee = legs & 2 == 0 ? 0 : _snapshot.feeUnissued;
        IERC20 token = IERC20(_modules.token);
        uint256 rawBefore = token.totalSupply();
        uint256 vaultBefore = token.balanceOf(_modules.vault);
        uint256 feeBefore = token.balanceOf(_snapshot.feeRecipient);
        uint256 economicBefore = rawBefore + _snapshot.unissued;
        _delivery.nonce = ++nonce;
        _delivery.senior = senior;
        _delivery.fee = fee;
        _delivery.effectiveSupply = economicBefore;
        _delivery.backing = _backing;
        _delivery.recognizedBacking = _recognized;
        _delivery.pricing = PricingState(100, 100, 100, 100, 100, true);
        _delivery.controller = _modules.controller;
        _delivery.vault = _modules.vault;
        _delivery.feeRecipient = _snapshot.feeRecipient;
        _delivery.accruedThrough = uint64(block.timestamp);
        _delivery.legs = legs;
        _delivery.active = true;
        _snapshot.unissued -= senior + fee;
        _snapshot.seniorUnissued -= senior;
        _snapshot.feeUnissued -= fee;
        IAccrualController(_modules.controller).mintAccrued(nonce);
        uint256 vaultCredit = senior + (_modules.vault == _snapshot.feeRecipient ? fee : 0);
        uint256 feeCredit = fee + (_modules.vault == _snapshot.feeRecipient ? senior : 0);
        if (
            token.totalSupply() != rawBefore + senior + fee
                || token.balanceOf(_modules.vault) != vaultBefore + vaultCredit
                || token.balanceOf(_snapshot.feeRecipient) != feeBefore + feeCredit
                || token.totalSupply() + _snapshot.unissued != economicBefore
        ) revert Reserve_RawDeliveryMismatch();
        delete _delivery;
    }

    function totalBackingValue() external view returns (uint256) {
        return _delivery.active ? _delivery.backing : _backing;
    }

    function recognizedBackingValue() external view returns (uint256) {
        return _delivery.active ? _delivery.recognizedBacking : _recognized;
    }

    function usdc() external view returns (address) {
        return _asset;
    }

    function idleUSDC() external view returns (uint256) {
        return _idleUnits;
    }

    function setArms(uint256 arm, uint256 incident) external {
        armId = arm;
        incidentId = incident;
    }

    function reserveLossArm() external view returns (uint256, uint256, bytes32, bool) {
        return (armId, armId, bytes32(0), true);
    }

    function activeReserveLossIncident() external view returns (uint256, bytes32) {
        return (incidentId, bytes32(0));
    }

    function idleCustodyShortfall() external pure returns (uint256) {
        return 0;
    }

    function depositUSDC(address from, uint256 amount) external returns (uint256 credited) {
        require(!paused, "deposit refused");
        require(IERC20(_asset).transferFrom(from, address(this), amount), "deposit transfer");
        _idleUnits += amount;
        credited = amount * 1e12;
        _backing += credited;
        _recognized += credited;
    }

    function releaseUSDC(address to, uint256 amount) external {
        require(!paused, "release refused");
        _idleUnits -= amount;
        uint256 value = amount * 1e12;
        _backing -= value;
        _recognized -= value;
        require(IERC20(_asset).transfer(to, amount), "release transfer");
    }
}

contract ControllerAccrualPoints {
    MintRedeemController public immutable controller;
    USDfr public immutable token;
    IContinuousAccrual public immutable reserve;
    uint256 public callbacks;
    uint256 public firstRaw;
    uint256 public lastRaw;
    uint256 public firstEconomic;
    uint256 public lastEconomic;
    uint256 public firstBacking;
    uint256 public lastBacking;
    uint256 public rejectedCompositeViews;
    uint256 public rejectedAttacks;
    uint256 public successfulAttacks;
    uint256 public wrongRejections;
    bytes4 public expectedRejection;
    bytes public attack;
    uint256 public injectMint;

    constructor(MintRedeemController controller_, USDfr token_, IContinuousAccrual reserve_) {
        controller = controller_;
        token = token_;
        reserve = reserve_;
    }

    function configure(bytes memory attack_, uint256 extraMint) external {
        attack = attack_;
        injectMint = extraMint;
        callbacks = 0;
        rejectedCompositeViews = 0;
        rejectedAttacks = 0;
        successfulAttacks = 0;
        wrongRejections = 0;
    }

    function expectRejection(bytes4 selector) external {
        expectedRejection = selector;
    }

    function onUSDfrTransfer(address, address, uint256) external {
        ++callbacks;
        uint256 raw = token.totalSupply();
        uint256 economic = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        if (callbacks == 1) {
            firstRaw = raw;
            firstEconomic = economic;
            firstBacking = backing;
        }
        lastRaw = raw;
        lastEconomic = economic;
        lastBacking = backing;
        (bool ok, bytes memory result) =
            address(controller).staticcall(abi.encodeCall(controller.backingInvariantHolds, ()));
        if (!ok && bytes4(result) == IMintRedeemController.Controller_ViewUnavailableMidTransition.selector) {
            ++rejectedCompositeViews;
        }
        if (attack.length != 0) {
            (ok, result) = address(controller).call(attack);
            if (ok) {
                ++successfulAttacks;
            } else {
                ++rejectedAttacks;
                if (result.length < 4 || bytes4(result) != expectedRejection) ++wrongRejections;
            }
        }
        if (injectMint != 0) {
            uint256 amount = injectMint;
            injectMint = 0;
            token.mint(address(this), amount);
        }
    }
}

contract ControllerAccrualExhaustingPoints {
    function onUSDfrTransfer(address, address, uint256) external pure {
        assembly ("memory-safe") {
            invalid()
        }
    }
}

contract ControllerAccrualDrawSource {
    IERC20 public immutable token;
    ControllerAccrualReserve public immutable reserve;
    address public immutable donor;
    uint256 public requested;
    bool public overreport;

    constructor(IERC20 token_, ControllerAccrualReserve reserve_, address donor_) {
        token = token_;
        reserve = reserve_;
        donor = donor_;
    }

    function setOverreport(bool value) external {
        overreport = value;
    }

    function drawForSeniorExit(uint256 amount) external returns (uint256) {
        requested = amount;
        require(token.transferFrom(donor, address(this), amount), "junior transfer");
        reserve.recordExitPrepayment(amount);
        return overreport ? amount + 1 : amount;
    }
}

contract ControllerAccrualTest is Test {
    USDfr private _token;
    MintRedeemController private _controller;
    ControllerAccrualReserve private _reserve;
    ControllerAccrualCompliance private _compliance;
    ControllerAccrualVault private _vault;
    MockERC20 private _asset;
    address private constant HOLDER = address(0xa11ce);
    address private constant FEE = address(0xfee);

    event ContinuousAccrualBound(address indexed reserve);
    event AccruedDeliveryRelayed(uint256 indexed nonce);
    event PointsHookFailed(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        vm.warp(1000);
        _asset = new MockERC20("USD Coin", "USDC", 6);
        _reserve = new ControllerAccrualReserve();
        _compliance = new ControllerAccrualCompliance();
        _token = USDfr(
            address(
                new ERC1967Proxy(
                    address(new USDfr()),
                    abi.encodeCall(USDfr.initialize, (address(this), address(this), address(this), address(this)))
                )
            )
        );
        _vault = new ControllerAccrualVault(address(_token));
        _controller = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(new MintRedeemController()),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (
                            address(this),
                            address(this),
                            address(this),
                            address(_token),
                            address(_compliance),
                            address(_reserve)
                        )
                    )
                )
            )
        );
        _reserve.configure(_modules(), address(_asset));
        _token.grantRole(Roles.MINTER_ROLE, address(_controller));
        _token.setComplianceModule(address(_compliance));
        _compliance.setExempt(address(_vault));
        _compliance.setExempt(address(_controller));
        _controller.setYieldSink(address(_vault), true);
        _controller.setYieldSink(FEE, true);
        _controller.setLossSource(address(_vault), true);
        _controller.grantRole(Roles.CREDIT_ROLE, address(this));
        _controller.grantRole(Roles.LOSS_BURNER_ROLE, address(this));
        _asset.mint(HOLDER, 1e36);
        vm.prank(HOLDER);
        _asset.approve(address(_controller), type(uint256).max);
    }

    function test_bindingIsGovernedOneTimeAndEmitsReserve() public {
        assertEq(_controller.accrualReserve(), address(0));
        _token.setAccrualReserve(address(_reserve));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, HOLDER, bytes32(0))
        );
        vm.prank(HOLDER);
        _controller.enableContinuousAccrual();
        vm.expectEmit(true, false, false, true, address(_controller));
        emit ContinuousAccrualBound(address(_reserve));
        _controller.enableContinuousAccrual();
        assertEq(_controller.accrualReserve(), address(_reserve));
        vm.expectRevert(MintRedeemController.Controller_AccrualAlreadyBound.selector);
        _controller.enableContinuousAccrual();
    }

    function test_bindingRequiresPreviouslyBoundToken() public {
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_WrongModules.selector);
        _controller.enableContinuousAccrual();
        assertEq(_controller.accrualReserve(), address(0));
        _enable();
    }

    function test_bindingRejectsWrongModuleIdentities() public {
        _token.setAccrualReserve(address(_reserve));
        for (uint256 i; i < 3; ++i) {
            IContinuousAccrual.Modules memory m = _modules();
            if (i == 0) m.controller = HOLDER;
            else if (i == 1) m.token = HOLDER;
            else m.vault = HOLDER;
            _reserve.setModules(m);
            vm.expectRevert(ControllerAccrualLib.ControllerAccrual_WrongModules.selector);
            _controller.enableContinuousAccrual();
        }
        _reserve.setModules(_modules());
        _controller.enableContinuousAccrual();
    }

    function test_bindingRejectsAnActivePairedYieldBaseline() public {
        _controller.beginPairedYield();
        _token.setAccrualReserve(address(_reserve));
        vm.expectRevert(MintRedeemController.Controller_AccrualDuringPairedYield.selector);
        _controller.enableContinuousAccrual();
        _controller.clearStalePairedYield();
        _controller.enableContinuousAccrual();
    }

    function test_bindingRejectsAReserveWhoseCodeDisappeared() public {
        _token.setAccrualReserve(address(_reserve));
        vm.etch(address(_reserve), bytes(""));
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_WrongModules.selector);
        _controller.enableContinuousAccrual();
    }

    function test_legacyOptOutReadsOnlyPhysicalSupply() public {
        _seed(1000, 120, 30, 1200, 1200);
        assertEq(_controller.totalUSDfr(), 1000);
        assertEq(_controller.mintableHeadroom(), 200);
        _enable();
        assertEq(_controller.totalUSDfr(), 1150);
        assertEq(_controller.mintableHeadroom(), 50);
    }

    function test_effectiveSupplyIncludesBothLegsInAllSolvencyViews() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1130e18);
        assertEq(_token.totalSupply(), 1000e18);
        assertEq(_controller.totalUSDfr(), 1150e18);
        assertEq(_controller.backingValue(), 1200e18);
        assertEq(_controller.recognizedBackingValue(), 1130e18);
        assertTrue(_controller.creditServicingBackingHolds());
        assertFalse(_controller.backingInvariantHolds());
        assertEq(_controller.backingDeficit(), 0);
        assertEq(_controller.recognizedDeficit(), 20e18);
        assertEq(_controller.mintableHeadroom(), 0);
        (uint256 paid, uint256 burned) = _controller.previewRedeem(115e18);
        assertEq(burned, 115e18);
        assertEq(paid, 113e6);
        _reserve.setBacking(1130e18, 1130e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_MintClosedWhileUnderBacked.selector, 1150e18, 1130e18
            )
        );
        vm.prank(HOLDER);
        _controller.mint(100e6);
    }

    function test_ordinaryYieldCannotSpendVirtualLiabilityBacking() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_BackingInvariantViolated.selector, 1201, 1200)
        );
        _controller.mintYield(address(_vault), 51);
        _controller.mintYield(address(_vault), 50);
        assertEq(_token.totalSupply(), 1050);
        assertEq(_controller.totalUSDfr(), 1200);
        assertEq(_controller.mintableHeadroom(), 0);
    }

    function test_recognizedDeficitUsesEffectiveSupplyOnBothSidesOfYield() public {
        _enable();
        _seed(1000, 120, 30, 1300, 1140);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_RecognizedDeficitWorsened.selector, 10, 11)
        );
        _controller.mintYield(address(_vault), 1);
        assertEq(_controller.recognizedDeficit(), 10);
    }

    function test_declaredDeficitUsesEffectiveSupplyBeforeAndAfterYield() public {
        _enable();
        _seed(1000, 120, 30, 1140, 1140);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_DeficitWorsened.selector, 10, 11));
        _controller.mintYield(address(_vault), 1);
        assertEq(_controller.backingDeficit(), 10);
    }

    function testFuzz_neutralDeliveryPreservesHeadroomAndAllEconomicLevels(
        uint96 rawSeed,
        uint96 seniorSeed,
        uint96 feeSeed,
        uint96 surplusSeed,
        uint96 retentionSeed,
        uint8 maskSeed,
        bool aliasRecipient
    ) public {
        _enable();
        uint256 raw = uint256(rawSeed) + 1;
        uint256 senior = uint256(seniorSeed) + 1;
        uint256 fee = uint256(feeSeed) + 1;
        uint256 supply = raw + senior + fee;
        _seed(raw, senior, fee, supply + surplusSeed, supply + surplusSeed);
        if (aliasRecipient) _reserve.setVirtual(senior, fee, address(_vault));
        _reserve.setRetention(retentionSeed);
        uint256 expected = surplusSeed > retentionSeed ? uint256(surplusSeed) - retentionSeed : 0;
        assertEq(_controller.mintableHeadroom(), expected);
        uint8 mask = maskSeed % 3 + 1;
        (uint256 deliveredSenior, uint256 deliveredFee) = _reserve.materializeAccrued(mask);
        assertEq(deliveredSenior, mask & 1 == 0 ? 0 : senior);
        assertEq(deliveredFee, mask & 2 == 0 ? 0 : fee);
        assertEq(_token.totalSupply(), raw + deliveredSenior + deliveredFee);
        assertEq(_controller.totalUSDfr(), supply);
        assertEq(_controller.mintableHeadroom(), expected);
        assertEq(_controller.backingDeficit(), 0);
        assertEq(_controller.recognizedDeficit(), 0);
        assertTrue(_controller.creditServicingBackingHolds());
        assertTrue(_controller.backingInvariantHolds());
        assertEq(_token.balanceOf(address(_vault)), deliveredSenior + (aliasRecipient ? deliveredFee : 0));
        assertEq(_token.balanceOf(FEE), aliasRecipient ? 0 : deliveredFee);
    }

    function testFuzz_nativeUSDCMintPreservesOutstandingClaims(uint96 seniorSeed, uint96 feeSeed, uint96 amountSeed)
        public
    {
        _enable();
        uint256 senior = uint256(seniorSeed) + 1;
        uint256 fee = uint256(feeSeed) + 1;
        uint256 raw = 1000e18;
        uint256 backing = raw + senior + fee + 1e18;
        _seed(raw, senior, fee, backing, backing);
        uint256 units = uint256(amountSeed) + 1;
        uint256 value = units * 1e12;
        uint256 cashBefore = _asset.balanceOf(HOLDER);
        vm.prank(HOLDER);
        uint256 out = _controller.mint(units);
        assertEq(out, value);
        assertEq(_token.totalSupply(), raw + value);
        assertEq(_controller.totalUSDfr(), raw + senior + fee + value);
        assertEq(_controller.backingValue(), backing + value);
        assertEq(_reserve.accrualSnapshot().unissued, senior + fee);
        assertEq(_asset.balanceOf(HOLDER), cashBefore - units);
        assertEq(_asset.balanceOf(address(_controller)), 0);
        assertEq(_asset.allowance(address(_controller), address(_reserve)), 0);
    }

    function test_nativeMintCannotIncreaseDeficitThroughAMintCallback() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1150e18, 1150e18);
        ControllerAccrualPoints points = _points();
        _token.grantRole(Roles.MINTER_ROLE, address(points));
        points.configure(bytes(""), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_BackingInvariantViolated.selector, 1250e18 + 1, 1250e18
            )
        );
        vm.prank(HOLDER);
        _controller.mint(100e6);
        assertEq(_token.totalSupply(), 1000e18);
        assertEq(_controller.totalUSDfr(), 1150e18);
        assertEq(_asset.balanceOf(address(_reserve)), 1000e6);
        assertEq(_token.balanceOf(address(points)), 0);
    }

    function testFuzz_subParRedeemPricesFullClaimsOnNativeUSDCGrid(
        uint96 rawSeed,
        uint96 virtualSeed,
        uint96 amountSeed,
        uint16 coverageSeed
    ) public {
        _enable();
        uint256 raw = uint256(rawSeed) + 1e18;
        uint256 latent = uint256(virtualSeed) + 1;
        uint256 backing = Math.mulDiv(raw, uint256(coverageSeed % 9999) + 1, 10_000);
        uint256 requested = bound(uint256(amountSeed), 1, raw);
        uint256 burn = requested / 1e12 * 1e12;
        _seed(raw, latent, 0, backing, backing);
        uint256 expectedUnits = Math.mulDiv(burn, backing, raw + latent) / 1e12;
        (uint256 quote, uint256 quotedBurn) = _controller.previewRedeem(requested);
        assertEq(quote, expectedUnits);
        if (expectedUnits == 0) {
            assertEq(quotedBurn, 0);
            assertEq(_token.balanceOf(HOLDER), raw);
            return;
        }
        assertEq(quotedBurn, burn);
        uint256 cashBefore = _asset.balanceOf(HOLDER);
        vm.prank(HOLDER);
        uint256 paid = _controller.redeem(requested, expectedUnits);
        assertEq(paid, expectedUnits);
        uint256 value = paid * 1e12;
        assertEq(_asset.balanceOf(HOLDER), cashBefore + paid);
        assertEq(_token.balanceOf(HOLDER), raw - burn);
        assertEq(_controller.totalUSDfr(), raw + latent - burn);
        assertEq(_controller.backingValue(), backing - value);
        assertGe((backing - value) * (raw + latent), backing * (raw + latent - burn));
        assertEq(_controller.seniorSubParShortfall(), burn - value);
    }

    function test_retentionDoesNotDisappearWhenFeeClaimsBecomePhysical() public {
        _enable();
        _seed(1000e18, 80e18, 20e18, 900e18, 900e18);
        vm.prank(HOLDER);
        assertEq(_controller.redeem(110e18, 90e6), 90e6);
        assertEq(_controller.seniorSubParShortfall(), 20e18);
        _reserve.setRetention(15e18);
        _reserve.setBacking(1030e18, 1030e18);
        assertEq(_controller.totalUSDfr(), 990e18);
        assertEq(_controller.mintableHeadroom(), 5e18);
        _reserve.materializeAccrued(2);
        assertEq(_controller.totalUSDfr(), 990e18);
        assertEq(_controller.mintableHeadroom(), 5e18);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SeniorRetentionBreached.selector, 35e18, 34e18)
        );
        _controller.mintYield(address(_vault), 6e18);
        _controller.mintYield(address(_vault), 5e18);
        assertEq(_controller.mintableHeadroom(), 0);
    }

    function test_pairedYieldPreservesTheEffectiveSurplusWithUnfilledRetention() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _reserve.setRetention(100);
        assertEq(_controller.mintableHeadroom(), 0);
        _controller.beginPairedYield();
        _reserve.setBacking(1210, 1210);
        _controller.mintYield(address(_vault), 10);
        assertEq(_controller.totalUSDfr(), 1160);
        assertEq(_controller.recognizedBackingValue() - _controller.totalUSDfr(), 50);
        assertEq(_controller.mintableHeadroom(), 0);
    }

    function test_pairedYieldStillRejectsAMismatchedEffectiveSurplus() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _reserve.setRetention(100);
        _controller.beginPairedYield();
        _reserve.setBacking(1211, 1211);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SeniorRetentionBreached.selector, 50, 51)
        );
        _controller.mintYield(address(_vault), 10);
        assertEq(_controller.totalUSDfr(), 1150);
        _reserve.setBacking(1210, 1210);
        _controller.mintYield(address(_vault), 10);
        assertEq(_controller.totalUSDfr(), 1160);
    }

    function test_juniorDrawTargetIncludesVirtualClaimsAndPreservesTheirSupply() public {
        _enable();
        _seed(1000e18, 240e18, 60e18, 1200e18, 1200e18);
        ControllerAccrualDrawSource source = _junior();
        (uint256 previewPaid, uint256 previewIn) = _controller.previewRedeem(100e18);
        assertEq(previewIn, 100e18);
        assertEq(previewPaid, 92_307_692);
        uint256 expectedDraw = Math.mulDiv(100e18, 100e18, 1200e18, Math.Rounding.Ceil);
        vm.prank(HOLDER);
        assertEq(_controller.redeem(100e18), 100e6);
        assertEq(source.requested(), expectedDraw);
        assertEq(_reserve.exitPrepaidAbsorption(), expectedDraw);
        assertEq(_token.totalSupply(), 900e18 - expectedDraw);
        assertEq(_controller.totalUSDfr(), 1200e18 - expectedDraw);
        assertEq(_reserve.accrualSnapshot().unissued, 300e18);
        assertEq(_token.balanceOf(address(source)), 0);
    }

    function test_juniorDrawStillRejectsOverreportAgainstTheEffectiveTarget() public {
        _enable();
        _seed(1000e18, 240e18, 60e18, 1200e18, 1200e18);
        ControllerAccrualDrawSource source = _junior();
        source.setOverreport(true);
        uint256 expectedDraw = Math.mulDiv(100e18, 100e18, 1200e18, Math.Rounding.Ceil);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ExitDrawNotDelivered.selector,
                expectedDraw,
                expectedDraw + 1,
                expectedDraw
            )
        );
        vm.prank(HOLDER);
        _controller.redeem(100e18);
        assertEq(_controller.totalUSDfr(), 1300e18);
        assertEq(_reserve.exitPrepaidAbsorption(), 0);
    }

    function test_staleClockReturnsZeroQuotesAndRejectsEconomicWrites() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        _assertPositiveQuotes();
        _reserve.setFresh(false);
        _assertZeroQuotes();
        assertEq(_controller.totalUSDfr(), 1150e18); // Coherent capped level remains readable.
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        vm.prank(HOLDER);
        _controller.mint(100e6);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        vm.prank(HOLDER);
        _controller.redeem(100e18, 0);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.mintYield(address(_vault), 1);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.burnLoss(address(_vault), 1);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.beginPairedYield();
        assertEq(_token.totalSupply(), 1000e18);
        assertEq(_asset.balanceOf(address(_reserve)), 1000e6);
    }

    function test_freshClockWithAnotherOperationAlsoClosesQuotes() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        _assertPositiveQuotes();
        _reserve.setBusy(true);
        assertTrue(_reserve.accrualSnapshot().fresh);
        assertFalse(_reserve.accrualDelivery().active);
        _assertZeroQuotes();
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        vm.prank(HOLDER);
        _controller.mint(100e6);
        _reserve.setBusy(false);
        assertEq(_controller.mintableHeadroom(), 50e18);
    }

    function test_staleConfigurationGatesDoNotBlockEmergencyPause() public {
        _enable();
        _reserve.setFresh(false);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.setYieldSink(HOLDER, true);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.setLossSource(address(_vault), false);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.clearStalePairedYield();
        _controller.pause();
        assertTrue(_controller.paused());
        _controller.unpause();
        assertFalse(_controller.paused());
    }

    function test_currentDeliveryClosesQuotesBeforeControllerEntry() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        _assertPositiveQuotes();
        _reserve.setPermit(_permit(1, 120e18, 30e18, 3));
        _assertZeroQuotes();
        assertEq(_controller.totalUSDfr(), 1150e18);
        vm.expectRevert(ControllerAccrualReserve.Reserve_AdmissionDenied.selector);
        _controller.beginPairedYield();
    }

    function test_deliveryRequiresConfiguredReserveAsCaller() public {
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        _controller.mintAccrued(1);
        _enable();
        _reserve.setPermit(_permit(1, 120, 30, 3));
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        vm.prank(HOLDER);
        _controller.mintAccrued(1);
    }

    function test_deliveryRejectsEveryInvalidPermitField() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        for (uint256 i; i < 11; ++i) {
            IContinuousAccrual.Delivery memory d = _permit(1, 120, 30, 3);
            if (i == 0) {
                d.active = false;
            } else if (i == 1) {
                d.nonce = 2;
            } else if (i == 2) {
                d.controller = HOLDER;
            } else if (i == 3) {
                --d.accruedThrough;
            } else if (i == 4) {
                ++d.accruedThrough;
            } else if (i == 5) {
                d.legs = 0;
            } else if (i == 6) {
                d.legs = 4;
            } else if (i == 7) {
                d.legs = 1;
            } else if (i == 8) {
                d.legs = 2;
            } else if (i == 9) {
                d.pricing.materializationAllowed = false;
            } else {
                d.senior = 0;
                d.fee = 0;
            }
            _reserve.setPermit(d);
            vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
            _reserve.relayDelivery(1);
            assertEq(_token.totalSupply(), 1000);
        }
    }

    function test_deliveryRequiresBothYieldSinksButChecksOnlyPositiveLegs() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _controller.setYieldSink(address(_vault), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                ControllerAccrualLib.ControllerAccrual_UnauthorizedRecipient.selector, address(_vault)
            )
        );
        _reserve.materializeAccrued(3);
        _controller.setYieldSink(address(_vault), true);
        _controller.setYieldSink(FEE, false);
        vm.expectRevert(
            abi.encodeWithSelector(ControllerAccrualLib.ControllerAccrual_UnauthorizedRecipient.selector, FEE)
        );
        _reserve.materializeAccrued(3);
        _reserve.materializeAccrued(1);
        assertEq(_token.balanceOf(address(_vault)), 120);
        assertEq(_reserve.accrualSnapshot().feeUnissued, 30);
        _controller.setYieldSink(FEE, true);
        _reserve.materializeAccrued(2);
        assertEq(_token.balanceOf(FEE), 30);
    }

    function test_deliveryRejectsChangedTokenBindingAndVaultEvenIfSinkAllowed() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        vm.mockCall(address(_token), abi.encodeCall(IAccrualToken.accrualReserve, ()), abi.encode(HOLDER));
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        _reserve.materializeAccrued(3);
        vm.clearMockedCalls();
        _controller.setYieldSink(HOLDER, true);
        IContinuousAccrual.Delivery memory d = _permit(1, 120, 30, 3);
        d.vault = HOLDER;
        _reserve.setPermit(d);
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_InvalidAccrualDelivery.selector, 1));
        _reserve.relayDelivery(1);
    }

    function test_deliveryRequiresNoLivePairedYieldBaseline() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _controller.beginPairedYield();
        vm.expectRevert(MintRedeemController.Controller_AccrualDuringPairedYield.selector);
        _reserve.materializeAccrued(3);
        assertEq(_reserve.accrualSnapshot().unissued, 150);
        assertEq(_reserve.nonce(), 0);
        _controller.clearStalePairedYield();
        _reserve.materializeAccrued(3);
        assertEq(_controller.totalUSDfr(), 1150);
    }

    function test_deliveryAndNativeBurnRemainLiveWhileAllModulesPaused() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _controller.pause();
        _token.pause();
        _reserve.setPaused(true);
        vm.expectEmit(true, false, false, true, address(_controller));
        emit AccruedDeliveryRelayed(1);
        _reserve.materializeAccrued(3);
        assertEq(_token.totalSupply(), 1150);
        assertEq(_controller.totalUSDfr(), 1150);
        _controller.burnLoss(address(_vault), 120);
        assertEq(_controller.totalUSDfr(), 1030);
    }

    function test_blockedFeeCannotPreventSeniorDeliveryAndLossAbsorption() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _compliance.setBlocked(FEE);
        _controller.pause();
        _token.pause();
        _reserve.materializeAccrued(1);
        _controller.burnLoss(address(_vault), 120);
        assertEq(_controller.totalUSDfr(), 1030);
        assertEq(_token.totalSupply(), 1000);
        assertEq(_reserve.accrualSnapshot().feeUnissued, 30);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), FEE));
        _reserve.materializeAccrued(2);
        assertEq(_reserve.nonce(), 1);
        _compliance.setBlocked(address(0));
        _reserve.materializeAccrued(2);
        assertEq(_reserve.nonce(), 2);
        assertEq(_controller.totalUSDfr(), 1030);
    }

    function test_secondLegFailureRollsBackVirtualDebitsSupplyNonceAndControllerGuard() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _compliance.setBlocked(FEE);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), FEE));
        _reserve.materializeAccrued(3);
        assertEq(_reserve.nonce(), 0);
        assertEq(_reserve.accrualSnapshot().unissued, 150);
        assertFalse(_reserve.accrualDelivery().active);
        assertEq(_token.totalSupply(), 1000);
        assertEq(_token.balanceOf(address(_vault)), 0);
        _compliance.setBlocked(address(0));
        _reserve.materializeAccrued(3);
        assertEq(_controller.totalUSDfr(), 1150);
        _controller.mintYield(address(_vault), 1);
    }

    function test_noOpTokenContinuationIsRejectedAtControllerBoundary() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _reserve.setPermit(_permit(1, 120, 30, 3));
        vm.mockCall(address(_token), abi.encodeCall(IAccrualToken.mintAccrued, (1)), bytes(""));
        vm.expectRevert(abi.encodeWithSignature("ControllerAccrual_SupplyDeltaMismatch(uint256,uint256)", 150, 0));
        _reserve.relayDelivery(1); // Deliberately excludes the reserve's own closing proof.
        assertEq(_token.totalSupply(), 1000);
    }

    function test_decreasingRawSupplyIsANamedMismatchRatherThanUnderflow() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _reserve.setPermit(_permit(1, 120, 30, 3));
        vm.mockCall(address(_token), abi.encodeCall(IAccrualToken.mintAccrued, (1)), bytes(""));
        bytes[] memory readings = new bytes[](2);
        readings[0] = abi.encode(uint256(1000));
        readings[1] = abi.encode(uint256(999));
        vm.mockCalls(address(_token), abi.encodeWithSignature("totalSupply()"), readings);
        vm.expectRevert(
            abi.encodeWithSelector(ControllerAccrualLib.ControllerAccrual_SupplyDeltaMismatch.selector, 150, 0)
        );
        _reserve.relayDelivery(1);
    }

    function test_deliveryAmountOverflowIsRejectedBeforeTokenCall() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        IContinuousAccrual.Delivery memory d = _permit(1, type(uint256).max, 1, 3);
        _reserve.setPermit(d);
        vm.expectRevert(ControllerAccrualLib.ControllerAccrual_InvalidDelivery.selector);
        _reserve.relayDelivery(1);
        assertEq(_token.totalSupply(), 1000);
    }

    function test_replayedActivePermitAndZeroNonceReachTokenReplayGuard() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _reserve.materializeAccrued(3);
        _reserve.setPermit(_permit(1, 120, 30, 3));
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, 1, 1));
        _reserve.relayDelivery(1);
        _reserve.setPermit(_permit(0, 120, 30, 3));
        vm.expectRevert(abi.encodeWithSelector(USDfr.USDfr_AccrualNonceUsed.selector, 0, 1));
        _reserve.relayDelivery(0);
        assertEq(_token.totalSupply(), 1150);
    }

    function test_deliveryCallbacksObserveFrozenEffectiveSupplyAndBacking() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        ControllerAccrualPoints points = _points();
        _reserve.materializeAccrued(3);
        assertEq(points.callbacks(), 2);
        assertEq(points.firstRaw(), 1120);
        assertEq(points.lastRaw(), 1150);
        assertEq(points.firstEconomic(), 1150);
        assertEq(points.lastEconomic(), 1150);
        assertEq(points.firstBacking(), 1200);
        assertEq(points.lastBacking(), 1200);
        assertEq(points.rejectedCompositeViews(), 2);
        assertEq(_controller.totalUSDfr(), 1150);
    }

    function test_deliveryCallbacksCannotReenterEconomicOrDeliveryPaths() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        ControllerAccrualPoints points = _points();
        _controller.grantRole(Roles.CREDIT_ROLE, address(points));
        _controller.grantRole(Roles.LOSS_BURNER_ROLE, address(points));
        bytes[] memory attacks = new bytes[](6);
        attacks[0] = abi.encodeWithSignature("mint(uint256)", 1);
        attacks[1] = abi.encodeWithSignature("redeem(uint256)", 1);
        attacks[2] = abi.encodeCall(_controller.mintYield, (address(_vault), 1));
        attacks[3] = abi.encodeCall(_controller.burnLoss, (address(_vault), 1));
        attacks[4] = abi.encodeCall(_controller.beginPairedYield, ());
        attacks[5] = abi.encodeCall(_controller.mintAccrued, (1));
        for (uint256 i; i < attacks.length; ++i) {
            _reserve.setVirtual(120, 30, FEE);
            points.configure(attacks[i], 0);
            points.expectRejection(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
            _reserve.materializeAccrued(3);
            assertEq(points.callbacks(), 2);
            assertEq(points.rejectedAttacks(), 2);
            assertEq(points.successfulAttacks(), 0);
            assertEq(points.wrongRejections(), 0);
        }
    }

    function test_deliveryCallbacksCannotChangePauseRolesOrImplementation() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        ControllerAccrualPoints points = _points();
        _controller.grantRole(bytes32(0), address(points));
        _controller.grantRole(Roles.GUARDIAN_ROLE, address(points));
        _controller.grantRole(Roles.UPGRADER_ROLE, address(points));
        _controller.grantRole(Roles.CREDIT_ROLE, address(points));
        bytes[] memory attacks = new bytes[](7);
        attacks[0] = abi.encodeCall(_controller.pause, ());
        attacks[1] = abi.encodeCall(_controller.unpause, ());
        attacks[2] = abi.encodeWithSignature("grantRole(bytes32,address)", Roles.CREDIT_ROLE, HOLDER);
        attacks[3] = abi.encodeWithSignature("revokeRole(bytes32,address)", Roles.CREDIT_ROLE, address(this));
        attacks[4] = abi.encodeWithSignature("renounceRole(bytes32,address)", Roles.CREDIT_ROLE, address(points));
        attacks[5] =
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(new MintRedeemController()), bytes(""));
        attacks[6] = abi.encodeCall(_controller.clearStalePairedYield, ());
        for (uint256 i; i < attacks.length; ++i) {
            if (i == 1) _controller.pause();
            _reserve.setVirtual(120, 30, FEE);
            points.configure(attacks[i], 0);
            points.expectRejection(
                i == 6
                    ? ControllerAccrualReserve.Reserve_AdmissionDenied.selector
                    : IMintRedeemController.Controller_ViewUnavailableMidTransition.selector
            );
            _reserve.materializeAccrued(3);
            assertEq(points.callbacks(), 2);
            assertEq(points.rejectedAttacks(), 2);
            assertEq(points.successfulAttacks(), 0);
            assertEq(points.wrongRejections(), 0);
            if (i == 1) _controller.unpause();
        }
        assertFalse(_controller.paused());
        assertFalse(_controller.hasRole(Roles.CREDIT_ROLE, HOLDER));
        assertTrue(_controller.hasRole(Roles.CREDIT_ROLE, address(this)));
    }

    function test_deliveryCallbacksCannotChangeSinksOrBinding() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        ControllerAccrualPoints points = _points();
        _controller.grantRole(bytes32(0), address(points));
        bytes[] memory attacks = new bytes[](3);
        attacks[0] = abi.encodeCall(_controller.setYieldSink, (FEE, false));
        attacks[1] = abi.encodeCall(_controller.setLossSource, (address(_vault), false));
        attacks[2] = abi.encodeCall(_controller.enableContinuousAccrual, ());
        for (uint256 i; i < attacks.length; ++i) {
            _reserve.setVirtual(120, 30, FEE);
            points.configure(attacks[i], 0);
            points.expectRejection(
                i == 2
                    ? ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector
                    : ControllerAccrualReserve.Reserve_AdmissionDenied.selector
            );
            _reserve.materializeAccrued(3);
            assertEq(points.callbacks(), 2);
            assertEq(points.rejectedAttacks(), 2);
            assertEq(points.successfulAttacks(), 0);
            assertEq(points.wrongRejections(), 0);
        }
        assertTrue(_controller.isYieldSink(FEE));
        assertTrue(_controller.isLossSource(address(_vault)));
    }

    function test_exhaustingPointsHooksStillLeaveControllerAndReserveProofsFunded() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _token.setPointsModule(address(new ControllerAccrualExhaustingPoints()));
        vm.expectEmit(true, true, false, true, address(_token));
        emit PointsHookFailed(address(0), address(_vault), 120);
        vm.expectEmit(true, true, false, true, address(_token));
        emit PointsHookFailed(address(0), FEE, 30);
        uint256 gasBefore = gasleft();
        _reserve.materializeAccrued{gas: 2_500_000}(3);
        emit log_named_uint("two-leg controller/token delivery gas with exhausted hooks", gasBefore - gasleft());
        assertEq(_token.totalSupply(), 1150);
        assertEq(_controller.totalUSDfr(), 1150);
        assertEq(_reserve.accrualSnapshot().unissued, 0);
        assertEq(_reserve.nonce(), 1);
        assertFalse(_reserve.accrualDelivery().active);
        assertEq(_controller.mintableHeadroom(), 50);
    }

    function test_underfundedControllerDeliveryIsAtomicAndRetryable() public {
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _token.setPointsModule(address(new ControllerAccrualExhaustingPoints()));
        (bool ok, bytes memory reason) =
            address(_reserve).call{gas: 1_200_000}(abi.encodeCall(IContinuousAccrual.materializeAccrued, (3)));
        assertFalse(ok);
        assertEq(bytes4(reason), PointsHook_InsufficientGas.selector);
        assertEq(_reserve.nonce(), 0);
        assertEq(_reserve.accrualSnapshot().unissued, 150);
        assertFalse(_reserve.accrualDelivery().active);
        assertEq(_token.totalSupply(), 1000);
        assertEq(_controller.totalUSDfr(), 1150);
        _reserve.materializeAccrued{gas: 2_500_000}(3);
        assertEq(_controller.totalUSDfr(), 1150);
    }

    function test_upgradePreservesLegacyNamespaceAndNewAccountingBinding() public {
        bytes32 slot = 0x78d32d002402115460f3fdc161605476f91264ca4d3e131f8b3d65ead1f69100;
        _enable();
        _seed(1000, 120, 30, 1200, 1200);
        _reserve.setRetention(100);
        _controller.beginPairedYield();
        _controller.pause();
        _controller.upgradeToAndCall(address(new MintRedeemController()), bytes(""));
        assertEq(vm.load(address(_controller), slot), bytes32(uint256(uint160(address(_token)))));
        assertEq(
            vm.load(address(_controller), bytes32(uint256(slot) + 2)), bytes32(uint256(uint160(address(_reserve))))
        );
        assertEq(vm.load(address(_controller), bytes32(uint256(slot) + 6)), bytes32(uint256(uint160(address(this)))));
        assertEq(
            vm.load(address(_controller), bytes32(uint256(slot) + 10)), bytes32(uint256(uint160(address(_reserve))))
        );
        assertEq(_controller.accrualReserve(), address(_reserve));
        assertEq(_controller.totalUSDfr(), 1150);
        assertTrue(_controller.isYieldSink(FEE));
        assertTrue(_controller.isLossSource(address(_vault)));
        assertTrue(_controller.hasRole(Roles.CREDIT_ROLE, address(this)));
        assertTrue(_controller.paused());
        vm.expectRevert(MintRedeemController.Controller_AccrualDuringPairedYield.selector);
        _reserve.materializeAccrued(3);
        _controller.unpause();
        _reserve.setBacking(1210, 1210);
        _controller.mintYield(address(_vault), 10);
        assertEq(_controller.totalUSDfr(), 1160);
        assertEq(_controller.mintableHeadroom(), 0);
        _reserve.materializeAccrued(3);
        assertEq(_controller.totalUSDfr(), 1160);
    }

    function test_armQuoteAndSettlementRejectAnUnrelatedOpenIncident() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        _assertPositiveQuotes();
        for (uint256 i; i < 2; ++i) {
            _reserve.setArms(11, i == 0 ? 0 : 12);
            (uint256 paid, uint256 burn) = _controller.previewRedeem(100e18);
            assertEq(paid, 0, "quote must reject an incident unrelated to the arm");
            assertEq(burn, 0);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMintRedeemController.Controller_ReserveLossArmFreeze.selector, 11, 100e6, 100e18
                )
            );
            vm.prank(HOLDER);
            _controller.redeem(100e18);
            assertEq(_controller.totalUSDfr(), 1150e18);
        }
        _reserve.setArms(11, 11);
        _assertPositiveQuotes();
        vm.prank(HOLDER);
        assertEq(_controller.redeem(100e18), 100e6);
        assertEq(_controller.totalUSDfr(), 1050e18);
    }

    function test_initializerRejectsEachZeroIdentityBeforeBinding() public {
        MintRedeemController implementation = new MintRedeemController();
        for (uint256 i; i < 6; ++i) {
            address[6] memory args =
                [address(this), address(this), address(this), address(_token), address(_compliance), address(_reserve)];
            args[i] = address(0);
            vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MintRedeemController.initialize, (args[0], args[1], args[2], args[3], args[4], args[5]))
            );
        }
    }

    function test_zeroValueAndZeroEndpointGuardsSurviveAccrualBinding() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        vm.prank(HOLDER);
        _controller.mint(0);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        vm.prank(HOLDER);
        _controller.redeem(0);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        _controller.mintYield(address(_vault), 0);
        vm.expectRevert(IMintRedeemController.Controller_ZeroAmount.selector);
        _controller.burnLoss(address(_vault), 0);
        vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
        _controller.setYieldSink(address(0), true);
        vm.expectRevert(MintRedeemController.Controller_ZeroAddress.selector);
        _controller.setLossSource(address(0), true);
        assertEq(_controller.totalUSDfr(), 1150e18);
    }

    function test_expiredDeadlineFailsBeforeAnyAccruedLiabilityCanMove() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_DeadlinePassed.selector, block.timestamp - 1, block.timestamp
            )
        );
        vm.prank(HOLDER);
        _controller.redeem(100e18, 100e6, block.timestamp - 1);
        assertEq(_controller.totalUSDfr(), 1150e18);
        vm.prank(HOLDER);
        assertEq(_controller.redeem(100e18, 100e6, block.timestamp), 100e6);
    }

    function test_quoteAndSettlementRejectInputsAboveEffectiveSupply() public {
        _enable();
        _seed(1000e18, 120e18, 30e18, 1200e18, 1200e18);
        uint256 input = 1150e18 + 1e12;
        bytes memory reason =
            abi.encodeWithSelector(IMintRedeemController.Controller_RedeemExceedsSupply.selector, input, 1150e18);
        vm.expectRevert(reason);
        _controller.previewRedeem(input);
        vm.expectRevert(reason);
        vm.prank(HOLDER);
        _controller.redeem(input);
        assertEq(_controller.totalUSDfr(), 1150e18);
    }

    function test_revokedJuniorSourceCannotBeDrawnAgainstVirtualClaims() public {
        _enable();
        _seed(1000e18, 240e18, 60e18, 1200e18, 1200e18);
        ControllerAccrualDrawSource source = _junior();
        _controller.setLossSource(address(source), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_ExitDrawSourceNotAuthorised.selector, address(source)
            )
        );
        vm.prank(HOLDER);
        _controller.redeem(100e18);
        assertEq(source.requested(), 0);
        assertEq(_controller.totalUSDfr(), 1300e18);
        assertEq(_reserve.exitPrepaidAbsorption(), 0);
    }

    function _assertPositiveQuotes() private view {
        assertEq(_controller.mintableHeadroom(), 50e18);
        (uint256 paid, uint256 burned) = _controller.previewRedeem(100e18);
        assertEq(paid, 100e6);
        assertEq(burned, 100e18);
    }

    function _assertZeroQuotes() private view {
        assertEq(_controller.mintableHeadroom(), 0);
        (uint256 paid, uint256 burned) = _controller.previewRedeem(100e18);
        assertEq(burned, 0);
        assertEq(paid, 0);
    }

    function _modules() private view returns (IContinuousAccrual.Modules memory) {
        return IContinuousAccrual.Modules(
            address(_token), address(_controller), address(_vault), address(0), address(0), address(0), address(0)
        );
    }

    function _enable() private {
        _token.setAccrualReserve(address(_reserve));
        _controller.enableContinuousAccrual();
    }

    function _seed(uint256 raw, uint256 senior, uint256 fee, uint256 backing, uint256 recognized) private {
        _token.mint(HOLDER, raw);
        uint256 cashUnits = Math.ceilDiv(raw, 1e12);
        _asset.mint(address(_reserve), cashUnits);
        _reserve.seed(cashUnits, backing, recognized);
        _reserve.setVirtual(senior, fee, FEE);
    }

    function _permit(uint256 nonce, uint256 senior, uint256 fee, uint8 mask)
        private
        view
        returns (IContinuousAccrual.Delivery memory d)
    {
        d.nonce = nonce;
        d.senior = senior;
        d.fee = fee;
        d.effectiveSupply = _controller.totalUSDfr();
        d.backing = _controller.backingValue();
        d.recognizedBacking = _controller.recognizedBackingValue();
        d.pricing = IContinuousAccrual.PricingState(100, 100, 100, 100, 100, true);
        d.controller = address(_controller);
        d.vault = address(_vault);
        d.feeRecipient = FEE;
        d.accruedThrough = uint64(block.timestamp);
        d.legs = mask;
        d.active = true;
    }

    function _points() private returns (ControllerAccrualPoints points) {
        points = new ControllerAccrualPoints(_controller, _token, IContinuousAccrual(address(_reserve)));
        _token.setPointsModule(address(points));
    }

    function _junior() private returns (ControllerAccrualDrawSource source) {
        address donor = address(0xbacc);
        source = new ControllerAccrualDrawSource(IERC20(address(_token)), _reserve, donor);
        vm.prank(HOLDER);
        _token.transfer(donor, 200e18);
        vm.prank(donor);
        _token.approve(address(source), type(uint256).max);
        _controller.setLossSource(address(source), true);
        _reserve.setLossAbsorber(address(source));
    }
}
