// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {USDfr} from "../../src/USDfr.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IContinuousAccrual, IAccrualVault} from "../../src/interfaces/IContinuousAccrual.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualSchedule} from "../../src/libraries/AccrualSchedule.sol";
import {VaultAccrualLib} from "../../src/libraries/VaultAccrualLib.sol";
import {VaultFeeMath} from "../../src/libraries/VaultFeeMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev Authoritative mint relay fixture; it derives the permit from its single reserve.
///      Principal seeding is test-owner-only and is not a production reserve receipt path.
contract SUSDfrAccrualController {
    address private immutable OWNER = msg.sender;
    USDfr public token;
    address public reserve;

    function configure(USDfr token_, address reserve_) external {
        require(msg.sender == OWNER, "fixture owner");
        token = token_;
        reserve = reserve_;
    }

    function modules() external view returns (address, address, address) {
        return (address(token), address(0), reserve);
    }

    function seed(address receiver, uint256 amount) external {
        require(msg.sender == OWNER, "fixture owner");
        token.mint(receiver, amount);
    }

    function mintAccrued(uint256 nonce) external {
        require(msg.sender == reserve, "fixture reserve");
        token.mintAccrued(nonce);
    }
}

/// @dev Contractual arithmetic is intentionally outside this fixture: endpoint inputs are
///      test-owner-only. Real Book accounting owns gross, reservations, fees and issuance.
///      Materialization derives every amount from Book and proves physical USDfr deltas.
contract SUSDfrAccrualReserve is IContinuousAccrual {
    using AccrualBook for AccrualBook.Book;
    using AccrualSchedule for AccrualSchedule.Heap;

    address private immutable OWNER = msg.sender;
    AccrualBook.Book private book;
    Modules private configured;
    Delivery private delivery;
    Snapshot private frozen;
    address public feeRecipient;
    bool public busy;
    bool public lastPermission;
    uint8 public lastLegs;
    uint256 public nonce;
    uint256 public nextId;

    error Fixture_Busy();
    error Fixture_DeliveryDenied();

    function configure(USDfr token, SUSDfr vault, SUSDfrAccrualController controller, address recipient) external {
        require(msg.sender == OWNER, "fixture owner");
        configured.token = address(token);
        configured.vault = address(vault);
        configured.controller = address(controller);
        feeRecipient = recipient;
        book.initialize(uint64(block.timestamp), 1000);
    }

    function addInterest(uint256 amount, uint64 duration) external {
        require(msg.sender == OWNER, "fixture owner");
        uint256 id = nextId++;
        uint64 at = uint64(block.timestamp);
        book.register(id, [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))], at);
        book.open(id, amount, at, at + duration);
    }

    function finishDue() external {
        uint64 at = uint64(block.timestamp);
        while (book.schedule.count() != 0 && book.schedule.peek().deadline <= at) {
            book.finishNext(at);
        }
    }

    function setBusy(bool value) external {
        require(msg.sender == OWNER, "fixture owner");
        busy = value;
    }

    function setFeeRecipient(address recipient) external {
        require(msg.sender == OWNER, "fixture owner");
        feeRecipient = recipient;
    }

    function setLoanFee(uint16 bps) external {
        require(msg.sender == OWNER, "fixture owner");
        book.setFee(bps, uint64(block.timestamp));
    }

    function accrualModules() external view returns (Modules memory) {
        return configured;
    }

    function accrualSnapshot() public view returns (Snapshot memory s) {
        if (delivery.active) return frozen;
        AccrualBook.Snapshot memory b = book.snapshot(uint64(block.timestamp));
        s = Snapshot(
            b.gross,
            b.unposted,
            b.unissued,
            b.seniorUnissued,
            b.feeUnissued,
            feeRecipient,
            b.accruedThrough,
            true,
            b.fresh
        );
    }

    function accrualDelivery() external view returns (Delivery memory) {
        return delivery;
    }

    function requireAccrualFresh() public view {
        if (busy || delivery.active) revert Fixture_Busy();
        book.requireFresh(uint64(block.timestamp));
    }

    function materializeAccrued(uint8 legs) external returns (uint256 senior, uint256 fee) {
        requireAccrualFresh();
        PricingState memory pricing = IAccrualVault(configured.vault).accrualPricingState();
        if (!pricing.materializationAllowed) revert Fixture_DeliveryDenied();
        lastPermission = pricing.materializationAllowed;
        lastLegs = legs;
        frozen = accrualSnapshot();
        (senior, fee) = book.takeIssuance(legs, uint64(block.timestamp));
        if (senior == 0 && fee == 0) return (0, 0);
        USDfr token = USDfr(configured.token);
        uint256 supplyBefore = token.totalSupply();
        uint256 vaultBefore = token.balanceOf(configured.vault);
        uint256 feeBefore = token.balanceOf(feeRecipient);
        delivery = Delivery(
            ++nonce,
            senior,
            fee,
            supplyBefore + frozen.unissued,
            supplyBefore + frozen.unissued,
            supplyBefore + frozen.unissued,
            pricing,
            configured.controller,
            configured.vault,
            feeRecipient,
            uint64(block.timestamp),
            legs,
            true
        );
        SUSDfrAccrualController(configured.controller).mintAccrued(nonce);
        require(token.totalSupply() == supplyBefore + senior + fee, "fixture supply delta");
        if (feeRecipient == configured.vault) {
            require(token.balanceOf(configured.vault) == vaultBefore + senior + fee, "fixture alias delta");
        } else {
            require(token.balanceOf(configured.vault) == vaultBefore + senior, "fixture senior delta");
            require(token.balanceOf(feeRecipient) == feeBefore + fee, "fixture fee delta");
        }
        delete delivery;
    }
}

contract SUSDfrAccrualCompliance {
    address public blocked;
    bool public denyExempt;

    function setBlocked(address receiver) external {
        blocked = receiver;
    }

    function setDenyExempt(bool value) external {
        denyExempt = value;
    }

    function isProtocolExempt(address) external view returns (bool) {
        return !denyExempt;
    }

    function canTransfer(address, address, address to) external view returns (bool) {
        return blocked == address(0) || to != blocked;
    }
}

contract SUSDfrAccrualImpairment is IImpairmentSource {
    uint256 public pendingSeniorImpairment;
    uint256 public performanceFeeImpairment;

    function set(uint256 senior, uint256 performance) external {
        pendingSeniorImpairment = senior;
        performanceFeeImpairment = performance;
    }
}

contract SUSDfrAccrualFailingPoints {
    error Fixture_PointsUnavailable();

    function onSharesTransfer(address, address, uint256) external pure {
        revert Fixture_PointsUnavailable();
    }
}

/// @dev Records assertions as state, so fail-open hook handling cannot disguise a failed probe.
contract SUSDfrAccrualObserver {
    SUSDfr public immutable vault;
    uint256 public callbacks;
    uint256 public rejected;
    bool public pricesMatch = true;
    bool public capacitiesClosed = true;
    bool public mutationsRejected = true;
    bool public deliveryBlocked = true;
    bytes32 public expected;
    bytes public attack;
    bytes4 public expectedError;

    constructor(SUSDfr vault_) {
        vault = vault_;
    }

    function vector() public view returns (uint256[10] memory p) {
        p[0] = vault.totalAssets();
        p[1] = vault.redemptionTotalAssets();
        p[2] = vault.convertToAssets(1e24);
        p[3] = vault.convertToShares(1e18);
        p[4] = vault.previewDeposit(1e18);
        p[5] = vault.previewMint(1e24);
        p[6] = vault.previewRedeem(1e24);
        p[7] = vault.previewWithdraw(1e18);
        p[8] = vault.feeExchangeRate();
        p[9] = vault.convertToSharesAtRedemption(1e18);
    }

    function configure(uint256[10] memory prices, bytes memory call_, bytes4 error_) external {
        expected = keccak256(abi.encode(prices));
        attack = call_;
        expectedError = error_;
        callbacks = 0;
        rejected = 0;
        pricesMatch = true;
        capacitiesClosed = true;
        mutationsRejected = true;
        deliveryBlocked = true;
    }

    function onUSDfrTransfer(address, address, uint256) external {
        _observe();
    }

    function onSharesTransfer(address, address, uint256) external {
        _observe();
    }

    function _observe() private {
        ++callbacks;
        pricesMatch = pricesMatch && keccak256(abi.encode(vector())) == expected;
        capacitiesClosed = capacitiesClosed && vault.maxDeposit(address(this)) == 0 && vault.maxMint(address(this)) == 0
            && vault.maxWithdraw(vault.redemptionQueue()) == 0 && vault.maxRedeem(vault.redemptionQueue()) == 0;
        deliveryBlocked = deliveryBlocked && !vault.accrualPricingState().materializationAllowed;
        if (attack.length != 0) {
            (bool ok, bytes memory result) = address(vault).call(attack);
            bool correct = !ok && result.length >= 4 && bytes4(result) == expectedError;
            mutationsRejected = mutationsRejected && correct;
            if (correct) ++rejected;
        }
    }
}

contract SUSDfrAccrualTest is Test {
    event PointsHookFailed(address indexed from, address indexed to, uint256 value);

    USDfr private token;
    SUSDfr private vault;
    SUSDfrAccrualController private controller;
    SUSDfrAccrualReserve private reserve;
    SUSDfrAccrualCompliance private compliance;
    SUSDfrAccrualObserver private observer;
    address private implementation;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    address private constant QUEUE = address(0x1234);
    address private constant FEE = address(0xfee);

    function setUp() public {
        vm.warp(1000);
        controller = new SUSDfrAccrualController();
        reserve = new SUSDfrAccrualReserve();
        compliance = new SUSDfrAccrualCompliance();
        token = USDfr(
            address(
                new ERC1967Proxy(
                    address(new USDfr()),
                    abi.encodeCall(USDfr.initialize, (address(this), address(controller), address(this), address(this)))
                )
            )
        );
        implementation = address(new SUSDfr());
        vault = SUSDfr(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        SUSDfr.initialize,
                        (address(this), address(this), address(this), address(token), address(compliance), FEE)
                    )
                )
            )
        );
        controller.configure(token, address(reserve));
        reserve.configure(token, vault, controller, FEE);
        token.setComplianceModule(address(compliance));
        vault.setRedemptionQueue(QUEUE);
        vault.setPerformanceFee(0);
        token.setAccrualReserve(address(reserve));
        vault.setAccrualReserve(address(reserve));
        observer = new SUSDfrAccrualObserver(vault);
        _deposit(ALICE, 100e18);
    }

    function _deposit(address holder, uint256 assets) private returns (uint256 shares) {
        controller.seed(holder, assets);
        vm.startPrank(holder);
        token.approve(address(vault), assets);
        shares = vault.deposit(assets, holder);
        vm.stopPrank();
    }

    function _earn(uint256 endpoint, uint64 elapsed) private {
        reserve.addInterest(endpoint, 100);
        vm.warp(block.timestamp + elapsed);
    }

    function _observe(bytes memory attack, bytes4 expectedError) private {
        observer.configure(observer.vector(), attack, expectedError);
        token.setPointsModule(address(observer));
        vault.setPointsModule(address(observer));
    }

    function test_virtualAssetsAndEntryPricesIncludeExactlyTheSeniorClaim() public {
        _earn(20e18, 50);
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertEq(vault.totalAssets(), 109e18);
        assertEq(vault.previewDeposit(109e18 + 1), vault.totalSupply() + 1e6);
        assertEq(vault.previewMint(vault.totalSupply() + 1e6), 109e18 + 1);
        uint256 quote = vault.previewDeposit(10e18);
        assertEq(_deposit(BOB, 10e18), quote);
        assertEq(vault.totalAssets(), 119e18);
    }

    function test_feeRecipientAliasCountsBothVirtualLegsAndBothPhysicalMintsOnce() public {
        reserve.setFeeRecipient(address(vault));
        _earn(20e18, 50);
        assertEq(vault.totalAssets(), 110e18);
        _observe("", bytes4(0));
        reserve.materializeAccrued(3);
        assertEq(token.balanceOf(address(vault)), 110e18);
        assertEq(vault.totalAssets(), 110e18);
        assertEq(observer.callbacks(), 2);
        assertTrue(observer.pricesMatch());
        assertTrue(observer.capacitiesClosed());
    }

    function test_neutralDeliveryKeepsGrossFeeRateWhenVaultFeesArePending() public {
        vault.setPerformanceFee(2000);
        _earn(20e18, 50);
        uint256 grossFeeRate = vault.feeExchangeRate();
        uint256 supplyBefore = vault.totalSupply();
        _observe("", bytes4(0));
        reserve.materializeAccrued(3);
        assertEq(observer.callbacks(), 2);
        assertTrue(observer.pricesMatch(), "every price remains coherent during neutral token delivery");
        assertEq(vault.feeExchangeRate(), grossFeeRate);
        assertEq(vault.totalSupply(), supplyBefore);
    }

    function test_hostBusyClosesAllCapacitiesEvenWhenTheLoanClockIsFresh() public {
        uint256 shares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.transfer(QUEUE, shares);
        reserve.setBusy(true);
        assertTrue(reserve.accrualSnapshot().fresh);
        assertEq(vault.maxDeposit(ALICE), 0);
        assertEq(vault.maxMint(ALICE), 0);
        assertEq(vault.maxWithdraw(QUEUE), 0);
        assertEq(vault.maxRedeem(QUEUE), 0);
        vm.expectRevert(SUSDfrAccrualReserve.Fixture_Busy.selector);
        vault.accrueFees();
        reserve.setBusy(false);
        assertGt(vault.maxDeposit(ALICE), 0);
        assertGt(vault.maxRedeem(QUEUE), 0);
    }

    function test_queueRedeemMaterializesVirtualAssetsThroughThePrivateGuardedWindow() public {
        _earn(20e18, 50);
        uint256 shares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.transfer(QUEUE, shares);
        uint256 quote = vault.previewRedeem(shares);
        assertGt(quote, token.balanceOf(address(vault)));
        vm.prank(QUEUE);
        uint256 received = vault.redeem(shares, ALICE, QUEUE);
        assertEq(received, quote);
        assertEq(token.balanceOf(ALICE), quote);
        assertTrue(reserve.lastPermission());
        assertEq(reserve.lastLegs(), 1);
        assertEq(reserve.accrualSnapshot().seniorUnissued, 0);
        assertEq(reserve.accrualSnapshot().feeUnissued, 1e18);
        assertTrue(vault.accrualPricingState().materializationAllowed);
    }

    function test_dueBoundaryClosesEntryUntilTheAuthoritativeBookIsCaughtUp() public {
        _earn(20e18, 100);
        assertEq(vault.totalAssets(), 118e18);
        assertEq(vault.maxDeposit(ALICE), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccrualBook.AccrualBook_BoundaryPending.selector, uint64(block.timestamp), uint64(block.timestamp)
            )
        );
        vault.accrueFees();
        reserve.finishDue();
        assertGt(vault.maxDeposit(ALICE), 0);
        vault.accrueFees();
    }

    /// @dev The ordinary optimizer-100 campaign runs this deployment check. Instrumented
    ///      no-optimizer coverage excludes only this test explicitly because its code differs.
    function test_deploymentCodeFitsProductionLimit() public view {
        assertLe(implementation.code.length, 24_576);
    }

    function test_boundVaultKeepsItsHistoricalNamespace() public view {
        bytes32 slot = bytes32(
            uint256(keccak256(abi.encode(uint256(keccak256("forestroad.storage.VaultAccrual")) - 1))) & ~uint256(0xff)
        );
        assertEq(slot, 0x0a3fe45ec0c706c92dec0dc11a11f80ca1f2f84db6d7d4d4986a86500415b200);
        assertEq(address(uint160(uint256(vm.load(address(vault), slot)))), address(reserve));
        bytes32 legacy = 0x916ccd28d6453e4642f179fb55de273623b632994ad01fe3a90e7b8b8a7e8900;
        assertEq(address(uint160(uint256(vm.load(address(vault), legacy)))), address(compliance));
        assertEq(address(uint160(uint256(vm.load(address(vault), bytes32(uint256(legacy) + 1))))), QUEUE);
    }

    function test_bindingIsPermanentAndGovernedAndDisablesVesting() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, bytes32(0))
        );
        vault.setAccrualReserve(address(reserve));
        vm.expectRevert(VaultAccrualLib.VaultAccrual_AlreadyBound.selector);
        vault.setAccrualReserve(address(reserve));
        vm.expectRevert(SUSDfr.SUSDfr_AccrualVestingConflict.selector);
        vault.setYieldVestingPeriod(1);
        vault.setYieldVestingPeriod(0);
        assertEq(vault.yieldVestingPeriod(), 0);
        assertEq(vault.accrualReserve(), address(reserve));
    }

    function test_unboundVaultRejectsVestingConflictAndInvalidReserveIdentity() public {
        SUSDfr fresh = SUSDfr(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        SUSDfr.initialize,
                        (address(this), address(this), address(this), address(token), address(compliance), FEE)
                    )
                )
            )
        );
        fresh.setYieldVestingPeriod(1 days);
        vm.expectRevert(SUSDfr.SUSDfr_AccrualVestingConflict.selector);
        fresh.setAccrualReserve(address(reserve));
        fresh.setYieldVestingPeriod(0);
        vm.expectRevert(VaultAccrualLib.VaultAccrual_WrongModules.selector);
        fresh.setAccrualReserve(address(0));
        vm.expectRevert(VaultAccrualLib.VaultAccrual_WrongModules.selector);
        fresh.setAccrualReserve(address(reserve));
        assertEq(fresh.accrualReserve(), address(0));
    }

    function test_vaultCannotPermanentlyBindASecondReserveWhileItsTokenRemainsBoundToTheFirst() public {
        SUSDfr fresh = SUSDfr(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        SUSDfr.initialize,
                        (address(this), address(this), address(this), address(token), address(compliance), FEE)
                    )
                )
            )
        );
        SUSDfrAccrualReserve second = new SUSDfrAccrualReserve();
        second.configure(token, fresh, controller, FEE);
        vm.expectRevert(VaultAccrualLib.VaultAccrual_WrongModules.selector);
        fresh.setAccrualReserve(address(second));
        assertEq(fresh.accrualReserve(), address(0));
        assertEq(token.accrualReserve(), address(reserve));
    }

    function test_constructorConfigurationAndPointsValidationHaveSpecificErrors() public {
        vm.expectRevert(SUSDfr.SUSDfr_ZeroAddress.selector);
        new ERC1967Proxy(
            implementation,
            abi.encodeCall(
                SUSDfr.initialize, (address(0), address(this), address(this), address(token), address(compliance), FEE)
            )
        );
        compliance.setDenyExempt(true);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_FeeRecipientNotExempt.selector, FEE));
        new ERC1967Proxy(
            implementation,
            abi.encodeCall(
                SUSDfr.initialize,
                (address(this), address(this), address(this), address(token), address(compliance), FEE)
            )
        );
        compliance.setDenyExempt(false);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_PointsModuleNotAContract.selector, ALICE));
        vault.setPointsModule(ALICE);
        vault.grantRole(Roles.CREDIT_ROLE, BOB);
        vault.revokeRole(Roles.CREDIT_ROLE, BOB);
        assertFalse(vault.hasRole(Roles.CREDIT_ROLE, BOB));
    }

    function test_legacyVestingDeadlineFallbackRetainsTheOriginalRecognitionCurve() public {
        SUSDfr fresh = SUSDfr(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        SUSDfr.initialize,
                        (address(this), address(this), address(this), address(token), address(compliance), FEE)
                    )
                )
            )
        );
        fresh.setPerformanceFee(0);
        controller.seed(ALICE, 100e18);
        vm.startPrank(ALICE);
        token.approve(address(fresh), 100e18);
        fresh.deposit(100e18, ALICE);
        vm.stopPrank();
        fresh.setYieldVestingPeriod(1 days);
        fresh.grantRole(Roles.CREDIT_ROLE, address(this));
        fresh.beginYieldNotification();
        controller.seed(address(fresh), 10e18);
        fresh.notifyYield(10e18);
        bytes32 deadlineSlot = bytes32(uint256(0x916ccd28d6453e4642f179fb55de273623b632994ad01fe3a90e7b8b8a7e8900) + 12);
        assertEq(uint256(vm.load(address(fresh), deadlineSlot)), block.timestamp + 1 days);
        // Explicit legacy-storage image: older proxies predate the appended absolute deadline.
        vm.store(address(fresh), deadlineSlot, bytes32(0));
        assertEq(fresh.vestingDeadline(), block.timestamp + 1 days);
        vm.warp(block.timestamp + 12 hours);
        assertEq(fresh.unvestedYield(), 5e18);
        assertEq(fresh.totalAssets(), 105e18);
    }

    function test_failedShareHookIsEventedAndReleasesThePricingSnapshot() public {
        vault.setPerformanceFee(2000);
        _earn(20e18, 50);
        uint256 shares = vault.accrualPricingState().feeAdjustedShares - vault.totalSupply();
        vault.setPointsModule(address(new SUSDfrAccrualFailingPoints()));
        vm.expectEmit(true, true, false, true, address(vault));
        emit PointsHookFailed(address(0), FEE, shares);
        vault.accrueFees();
        assertEq(vault.balanceOf(FEE), shares);
        assertTrue(vault.accrualPricingState().materializationAllowed);
        assertGt(vault.maxDeposit(ALICE), 0);
    }

    function test_failedPhysicalDeliveryRollsBackBookIssuanceAndThePrivateWindow() public {
        _earn(20e18, 50);
        uint256 shares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.transfer(QUEUE, shares);
        compliance.setBlocked(address(vault));
        vm.prank(QUEUE);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, address(0), address(vault)));
        vault.redeem(shares, ALICE, QUEUE);
        assertEq(reserve.accrualSnapshot().seniorUnissued, 9e18);
        assertEq(reserve.nonce(), 0);
        assertEq(vault.balanceOf(QUEUE), shares);
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertTrue(vault.accrualPricingState().materializationAllowed);
        compliance.setBlocked(address(0));
        vm.prank(QUEUE);
        vault.redeem(shares, ALICE, QUEUE);
        assertEq(reserve.accrualSnapshot().seniorUnissued, 0);
    }

    function test_localDepositSnapshotCoversUnderlyingAndShareCallbacks() public {
        _earn(20e18, 50);
        controller.seed(BOB, 10e18);
        vm.prank(BOB);
        token.approve(address(vault), 10e18);
        _observe(
            abi.encodeCall(SUSDfr.deposit, (1, BOB)), ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector
        );
        vm.prank(BOB);
        vault.deposit(10e18, BOB);
        assertEq(observer.callbacks(), 2);
        assertTrue(observer.pricesMatch());
        assertTrue(observer.capacitiesClosed());
        assertTrue(observer.deliveryBlocked());
        assertTrue(observer.mutationsRejected());
        assertEq(observer.rejected(), 2);
        assertGt(vault.maxDeposit(BOB), 0);
    }

    function test_localWithdrawalSnapshotCoversShareBurnAndUnderlyingTransfer() public {
        _earn(20e18, 50);
        reserve.materializeAccrued(1);
        uint256 shares = vault.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        vault.transfer(QUEUE, shares);
        _observe(
            abi.encodeCall(SUSDfr.redeem, (1, BOB, QUEUE)),
            ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector
        );
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(QUEUE);
        assertEq(vault.redeem(shares, ALICE, QUEUE), quote);
        assertEq(observer.callbacks(), 2);
        assertTrue(observer.pricesMatch());
        assertTrue(observer.capacitiesClosed());
        assertTrue(observer.deliveryBlocked());
        assertTrue(observer.mutationsRejected());
        assertEq(observer.rejected(), 2);
    }

    function test_feeShareMintSnapshotUsesProjectedSupplyForEveryPrice() public {
        vault.setPerformanceFee(2000);
        _earn(20e18, 50);
        uint256[10] memory expected = observer.vector();
        IContinuousAccrual.PricingState memory pricing = vault.accrualPricingState();
        expected[8] = Math.mulDiv(1e24, pricing.performanceAssets + 1, pricing.feeAdjustedShares + 1e6);
        observer.configure(expected, abi.encodeCall(SUSDfr.accrueFees, ()), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        vault.setPointsModule(address(observer));
        (, uint256 performanceShares) = vault.accrueFees();
        assertGt(performanceShares, 0);
        assertEq(observer.callbacks(), 1);
        assertTrue(observer.pricesMatch());
        assertTrue(observer.capacitiesClosed());
        assertTrue(observer.deliveryBlocked());
        assertTrue(observer.mutationsRejected());
        assertEq(keccak256(abi.encode(observer.vector())), keccak256(abi.encode(expected)));
    }

    function test_privilegedDeliveryCallbackCannotChangeVaultRolesAllowanceOrConfiguration() public {
        vault.grantRole(bytes32(0), address(observer));
        vault.grantRole(Roles.GUARDIAN_ROLE, address(observer));
        vault.grantRole(Roles.UPGRADER_ROLE, address(observer));
        bytes[] memory attacks = new bytes[](8);
        attacks[0] = abi.encodeWithSignature("grantRole(bytes32,address)", Roles.CREDIT_ROLE, BOB);
        attacks[1] = abi.encodeWithSignature("revokeRole(bytes32,address)", bytes32(0), address(this));
        attacks[2] = abi.encodeWithSignature("approve(address,uint256)", BOB, type(uint256).max);
        attacks[3] = abi.encodeCall(SUSDfr.setPointsModule, (address(0)));
        attacks[4] = abi.encodeCall(SUSDfr.setRedemptionQueue, (BOB));
        attacks[5] = abi.encodeCall(SUSDfr.pause, ());
        attacks[6] = abi.encodeCall(SUSDfr.setPerformanceFee, (1));
        attacks[7] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementation, bytes(""));
        for (uint256 i; i < attacks.length; ++i) {
            _earn(20e18, 10);
            _observe(attacks[i], VaultAccrualLib.VaultAccrual_OperationInProgress.selector);
            reserve.materializeAccrued(3);
            assertEq(observer.callbacks(), 2);
            assertTrue(observer.mutationsRejected());
            assertEq(observer.rejected(), 2);
            assertTrue(observer.pricesMatch());
            token.setPointsModule(address(0));
            vault.setPointsModule(address(0));
        }
        assertTrue(vault.hasRole(bytes32(0), address(this)));
        assertFalse(vault.hasRole(Roles.CREDIT_ROLE, BOB));
        assertEq(vault.allowance(address(observer), BOB), 0);
        assertFalse(vault.paused());
        assertEq(vault.redemptionQueue(), QUEUE);
    }

    function test_dualImpairmentExcludesJuniorSupportFromStreamedPerformanceFee() public {
        vault.setPerformanceFee(2000);
        SUSDfrAccrualImpairment source = new SUSDfrAccrualImpairment();
        vault.setImpairmentSource(address(source));
        source.set(2e18, 20e18);
        _earn(20e18, 50);
        assertEq(vault.totalAssets(), 109e18);
        assertEq(vault.redemptionTotalAssets(), 107e18);
        assertEq(vault.accrualPricingState().performanceAssets, 89e18);
        (, uint256 beforeCure) = vault.accrueFees();
        assertEq(beforeCure, 0);
        reserve.materializeAccrued(3);
        assertEq(token.balanceOf(FEE), 1e18);
        source.set(0, 0);
        (, uint256 afterCure) = vault.accrueFees();
        assertGt(afterCure, 0);
        assertApproxEqAbs(vault.convertToAssets(afterCure), 1.8e18, 1);
        (, uint256 repeated) = vault.accrueFees();
        assertEq(repeated, 0);
    }

    function test_zeroOwnedClaimDoesNotRequestPhysicalMaterialization() public {
        reserve.setLoanFee(10_000);
        _earn(20e18, 50);
        uint256 shares = vault.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        vault.transfer(QUEUE, shares);
        vm.prank(QUEUE);
        vault.redeem(shares, ALICE, QUEUE);
        assertEq(reserve.nonce(), 0);
        assertEq(reserve.accrualSnapshot().feeUnissued, 10e18);
        assertEq(reserve.lastLegs(), 0);
    }

    function test_aliasWithdrawalMaterializesBothOwnedLegs() public {
        reserve.setFeeRecipient(address(vault));
        _earn(20e18, 50);
        uint256 shares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.transfer(QUEUE, shares);
        uint256 quote = vault.previewRedeem(shares);
        vm.prank(QUEUE);
        assertEq(vault.redeem(shares, BOB, QUEUE), quote);
        assertEq(reserve.lastLegs(), 3);
        assertEq(reserve.accrualSnapshot().unissued, 0);
    }

    function testFuzz_neutralDeliveryConservesAllPricesAndSelectedClaims(
        uint96 endpoint,
        uint24 durationSeed,
        uint24 elapsedSeed,
        uint16 feeSeed,
        uint8 maskSeed,
        bool aliasFee
    ) public {
        uint64 duration = uint64(uint256(durationSeed) % 365 days + 1);
        uint64 elapsed = uint64(uint256(elapsedSeed) % duration);
        uint8 legs = uint8(uint256(maskSeed) % 3 + 1);
        reserve.setLoanFee(uint16(uint256(feeSeed) % 10_001));
        if (aliasFee) reserve.setFeeRecipient(address(vault));
        reserve.addInterest(endpoint, duration);
        vm.warp(block.timestamp + elapsed);
        IContinuousAccrual.Snapshot memory before_ = reserve.accrualSnapshot();
        uint256 assets = vault.totalAssets();
        uint256[10] memory prices = observer.vector();
        (uint256 senior, uint256 fee) = reserve.materializeAccrued(legs);
        assertEq(senior, legs == 2 ? 0 : before_.seniorUnissued);
        assertEq(fee, legs == 1 ? 0 : before_.feeUnissued);
        assertEq(vault.totalAssets(), assets);
        assertEq(keccak256(abi.encode(observer.vector())), keccak256(abi.encode(prices)));
        assertEq(reserve.accrualSnapshot().unissued, before_.unissued - senior - fee);
        assertEq(token.balanceOf(address(vault)), 100e18 + senior + (aliasFee ? fee : 0));
    }

    function testFuzz_streamedFeesDoNotChangeTheQuotedDepositOrMint(
        uint96 grossSeed,
        uint80 flowSeed,
        uint16 managementSeed,
        uint16 performanceSeed,
        bool exactShares
    ) public {
        vault.setManagementFee(uint16(uint256(managementSeed) % 201));
        vault.setPerformanceFee(uint16(uint256(performanceSeed) % 2001));
        uint256 endpoint = uint256(grossSeed) % 1_000_000e18;
        reserve.addInterest(endpoint, 365 days);
        vm.warp(block.timestamp + 90 days);
        uint256 amount = uint256(flowSeed) % 10_000e18 + 1;
        uint256 assets = exactShares ? vault.previewMint(amount * 1e6) : amount;
        uint256 shares = exactShares ? amount * 1e6 : vault.previewDeposit(assets);
        uint256 assetsBefore = vault.totalAssets();
        controller.seed(BOB, assets);
        vm.startPrank(BOB);
        token.approve(address(vault), assets);
        if (exactShares) assertEq(vault.mint(shares, BOB), assets);
        else assertEq(vault.deposit(assets, BOB), shares);
        vm.stopPrank();
        assertEq(vault.balanceOf(BOB), shares);
        assertEq(vault.totalAssets(), assetsBefore + assets);
        uint256 supply = vault.totalSupply();
        vault.accrueFees();
        assertEq(vault.totalSupply(), supply);
    }
}

/// @dev Independent bounded integer arithmetic for the pre-extraction numeric formula.
///      Only the pinned fractional-power primitive is shared; products fit directly in uint256.
contract SUSDfrAccrualFeeMathTest is Test {
    function test_directManagementFeeRetainsTheSameAnnualFormula() public pure {
        assertEq(VaultFeeMath.managementFeeAssets(100e18, 0, 365 days), 0);
        assertApproxEqAbs(VaultFeeMath.managementFeeAssets(100e18, 200, 365 days), 2e18, 100);
    }

    function testFuzz_linkedFeesMatchTheOriginalScalarFormula(
        uint112 supply,
        uint96 assets,
        uint96 performanceSeed,
        uint64 hwmSeed,
        uint32 elapsed,
        uint16 managementSeed,
        uint16 performanceFeeSeed
    ) public pure {
        VaultFeeMath.Inputs memory p = VaultFeeMath.Inputs({
            supply: supply,
            markedAssets: assets,
            performanceMarkedAssets: uint256(performanceSeed) % (uint256(assets) + 1),
            highWaterMark: uint256(hwmSeed) % 4e18,
            elapsed: elapsed,
            virtualShares: 1e6,
            shareUnit: 1e24,
            managementFeeBps: uint16(uint256(managementSeed) % 201),
            performanceFeeBps: uint16(uint256(performanceFeeSeed) % 2001)
        });
        VaultFeeMath.Calculation memory actual = VaultFeeMath.calculate(p);
        VaultFeeMath.Calculation memory reference_ = _reference(p);
        assertEq(abi.encode(actual), abi.encode(reference_));
    }

    function test_zeroSupplyAndLegacyHwmKeepTheirHistoricalFeeRules() public pure {
        VaultFeeMath.Inputs memory p;
        p.elapsed = 365 days;
        p.markedAssets = 100e18;
        p.performanceMarkedAssets = 100e18;
        p.virtualShares = 1e6;
        p.shareUnit = 1e24;
        p.managementFeeBps = 200;
        p.performanceFeeBps = 2000;
        assertEq(VaultFeeMath.calculate(p).managementShares, 0);
        p.supply = 100e24;
        VaultFeeMath.Calculation memory actual = VaultFeeMath.calculate(p);
        assertGt(actual.managementShares, 0);
        assertEq(actual.performanceShares, 0);
        assertEq(abi.encode(actual), abi.encode(_reference(p)));
    }

    function _reference(VaultFeeMath.Inputs memory p) private pure returns (VaultFeeMath.Calculation memory c) {
        c.elapsed = p.elapsed;
        if (p.supply == 0) return c;
        uint256 base = p.supply + p.virtualShares;
        if (p.managementFeeBps != 0 && p.elapsed != 0 && p.markedAssets != 0) {
            uint256 retained = uint256(
                FixedPointMathLib.powWad(
                    int256(1e18 - uint256(p.managementFeeBps) * 1e14), int256(p.elapsed * 1e18 / 365 days)
                )
            );
            c.managementAssets = p.markedAssets * (1e18 - retained) / 1e18;
            c.managementShares = c.managementAssets * base / (p.markedAssets + 1 - c.managementAssets);
        }
        if (p.highWaterMark == 0) return c;
        uint256 investorAssets = (p.performanceMarkedAssets + 1) * base / (base + c.managementShares);
        uint256 hurdleNumerator = p.highWaterMark * base;
        uint256 hurdle = hurdleNumerator / p.shareUnit + (hurdleNumerator % p.shareUnit == 0 ? 0 : 1);
        if (investorAssets <= hurdle) return c;
        c.profitAssets = investorAssets - hurdle;
        c.performanceAssets = c.profitAssets * p.performanceFeeBps / 10_000;
        uint256 feeAssets = c.managementAssets + c.performanceAssets;
        c.performanceShares = feeAssets * base / (p.markedAssets + 1 - feeAssets) - c.managementShares;
    }
}

/// @dev Plumbing-only host for defensive library branches unreachable through validated
///      SUSDfr calls, such as an invalid internal selector or overlapping local begin.
contract SUSDfrAccrualLibraryHarness {
    function bind(address reserve, address token) external {
        VaultAccrualLib.bind(reserve, token);
    }

    function boundReserve() external view returns (address) {
        return address(VaultAccrualLib.state().reserve);
    }

    function begin(IContinuousAccrual.PricingState memory p, uint256 gross) external {
        VaultAccrualLib.begin(p, gross);
    }

    function end() external {
        VaultAccrualLib.end();
    }

    function cachedPrice(uint8 kind) external view returns (bool, uint256) {
        return VaultAccrualLib.cachedPrice(kind);
    }

    function requireIdle() external view {
        VaultAccrualLib.requireIdle();
    }

    function capture(address token, uint256 unvested, address source, uint256 shares, bool allowed)
        external
        view
        returns (IContinuousAccrual.PricingState memory)
    {
        return VaultAccrualLib.capture(token, unvested, source, shares, allowed);
    }

    function pricedAssets(address token, uint256 unvested, address source, uint8 kind)
        external
        view
        returns (uint256)
    {
        return VaultAccrualLib.pricedAssets(token, unvested, source, kind);
    }
}

/// @dev Malformed fixed-ABI module responses for binding preflight tests only.
contract SUSDfrAccrualBindingEndpoint {
    mapping(bytes4 => bytes) private reply;
    mapping(bytes4 => bool) private failed;

    function setReply(bytes4 selector, bytes memory data) external {
        reply[selector] = data;
    }

    function setFailed(bytes4 selector, bool value) external {
        failed[selector] = value;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        require(!failed[selector], "fixture read failed");
        return reply[selector];
    }
}

contract SUSDfrAccrualLibraryTest is Test {
    SUSDfrAccrualLibraryHarness private h;
    USDfr private token;

    function setUp() public {
        h = new SUSDfrAccrualLibraryHarness();
        token = USDfr(
            address(
                new ERC1967Proxy(
                    address(new USDfr()),
                    abi.encodeCall(USDfr.initialize, (address(this), address(this), address(this), address(this)))
                )
            )
        );
    }

    function test_everyCachedFieldIsIndependentAndOverlappingWritesFail() public {
        IContinuousAccrual.PricingState memory p = IContinuousAccrual.PricingState(100, 110, 80, 70, 120, true);
        h.begin(p, 99);
        uint256[5] memory expected = [uint256(100), 110, 80, 70, 120];
        for (uint8 i; i < 5; ++i) {
            (bool active, uint256 value) = h.cachedPrice(i);
            assertTrue(active);
            assertEq(value, expected[i]);
        }
        vm.expectRevert(VaultAccrualLib.VaultAccrual_InvalidPriceKind.selector);
        h.cachedPrice(5);
        vm.expectRevert(VaultAccrualLib.VaultAccrual_OperationInProgress.selector);
        h.begin(p, 99);
        vm.expectRevert(VaultAccrualLib.VaultAccrual_OperationInProgress.selector);
        h.requireIdle();
        IContinuousAccrual.PricingState memory captured = h.capture(address(token), 0, address(0), 500, true);
        assertEq(captured.assets, p.assets);
        assertEq(captured.feeAdjustedShares, p.feeAdjustedShares);
        assertFalse(captured.materializationAllowed);
        h.end();
        h.requireIdle();
        (bool stillActive,) = h.cachedPrice(0);
        assertFalse(stillActive);
    }

    function test_captureUsesSeparateSaturatingMarksAndRejectsInvalidOrdering() public {
        SUSDfrAccrualImpairment source = new SUSDfrAccrualImpairment();
        token.mint(address(h), 100);
        source.set(110, 120);
        IContinuousAccrual.PricingState memory p = h.capture(address(token), 10, address(source), 500, true);
        assertEq(p.assets, 90);
        assertEq(p.entryAssets, 100);
        assertEq(p.redemptionAssets, 0);
        assertEq(p.performanceAssets, 0);
        assertEq(p.feeAdjustedShares, 500);
        assertFalse(p.materializationAllowed);
        p = h.capture(address(token), 101, address(source), 500, false);
        assertEq(p.assets, 0);
        source.set(3, 2);
        vm.expectRevert(
            abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment.selector, uint256(3), uint256(2))
        );
        h.capture(address(token), 0, address(source), 500, true);
        vm.expectRevert(VaultAccrualLib.VaultAccrual_InvalidPriceKind.selector);
        h.pricedAssets(address(token), 0, address(source), 1);
    }

    function test_bindingRejectsMalformedAndInconsistentModuleRepliesBeforeWriting() public {
        SUSDfrAccrualBindingEndpoint source = new SUSDfrAccrualBindingEndpoint();
        SUSDfrAccrualBindingEndpoint token_ = new SUSDfrAccrualBindingEndpoint();
        SUSDfrAccrualBindingEndpoint controller_ = new SUSDfrAccrualBindingEndpoint();
        bytes4 modules = IContinuousAccrual.accrualModules.selector;
        bytes4 bound = bytes4(keccak256("accrualReserve()"));
        bytes4 controllerModules = bytes4(keccak256("modules()"));
        IContinuousAccrual.Modules memory m;
        m.token = address(token_);
        m.controller = address(controller_);
        m.vault = address(h);
        source.setReply(modules, abi.encode(m));
        token_.setReply(bound, abi.encode(address(source)));
        controller_.setReply(controllerModules, abi.encode(address(token_), address(0), address(source)));

        source.setFailed(modules, true);
        _rejectBinding(source, token_);
        source.setFailed(modules, false);
        source.setReply(modules, hex"00");
        _rejectBinding(source, token_);
        uint256[7] memory words;
        words[0] = uint256(uint160(address(token_)));
        words[1] = uint256(uint160(address(controller_)));
        words[2] = uint256(uint160(address(h)));
        words[6] = uint256(1) << 160;
        source.setReply(modules, abi.encode(words));
        _rejectBinding(source, token_);
        source.setReply(modules, abi.encode(m));

        token_.setFailed(bound, true);
        _rejectBinding(source, token_);
        token_.setFailed(bound, false);
        token_.setReply(bound, hex"00");
        _rejectBinding(source, token_);
        token_.setReply(bound, abi.encode(address(0)));
        _rejectBinding(source, token_);
        token_.setReply(bound, abi.encode(address(source)));

        controller_.setFailed(controllerModules, true);
        _rejectBinding(source, token_);
        controller_.setFailed(controllerModules, false);
        controller_.setReply(controllerModules, hex"00");
        _rejectBinding(source, token_);
        controller_.setReply(controllerModules, abi.encode(address(0), address(0), address(source)));
        _rejectBinding(source, token_);
        controller_.setReply(controllerModules, abi.encode(address(token_), uint256(1) << 160, address(source)));
        _rejectBinding(source, token_);
        controller_.setReply(controllerModules, abi.encode(address(token_), address(0), address(0)));
        _rejectBinding(source, token_);
        controller_.setReply(controllerModules, abi.encode(address(token_), address(0), address(source)));
        h.bind(address(source), address(token_));
        assertEq(h.boundReserve(), address(source));
    }

    function _rejectBinding(SUSDfrAccrualBindingEndpoint source, SUSDfrAccrualBindingEndpoint token_) private {
        vm.expectRevert(VaultAccrualLib.VaultAccrual_WrongModules.selector);
        h.bind(address(source), address(token_));
        assertEq(h.boundReserve(), address(0));
    }
}
