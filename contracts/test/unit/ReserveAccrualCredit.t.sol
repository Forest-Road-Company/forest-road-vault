// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {ReserveStorageLib} from "../../src/libraries/ReserveStorageLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @dev Test-owner-only seeders install native funding and module identities. Production register,
///      checkpoint, posting, amendment and stop wrappers and their linked libraries remain real.
contract ReserveCreditHostHarness is ReserveManager {
    using AccrualLoans for AccrualLoans.State;

    address private immutable OWNER = msg.sender;

    function seed(IContinuousAccrual.Modules calldata m, address asset) external {
        require(msg.sender == OWNER, "fixture owner");
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        s.modules = m;
        s.enabled = true;
        s.loans.initialize(uint64(block.timestamp), 1000);
        s.feeRecipient = address(0xfee);
        ReserveManager.ReserveStorage storage n = _fixtureNative();
        n.usdcToken = IERC20(asset);
        _grantRole(DEFAULT_ADMIN_ROLE, OWNER);
        _grantRole(Roles.GUARDIAN_ROLE, m.registry);
        _grantRole(Roles.CREDIT_ROLE, OWNER);
        _grantRole(Roles.CREDIT_ROLE, m.defaultManager);
    }

    function seedFunded(uint256 id, uint256 principal) external {
        require(msg.sender == OWNER, "fixture owner");
        ReserveManager.ReserveStorage storage n = _fixtureNative();
        n.deployed[id] = principal;
        n.totalDeployedPrincipal += principal;
    }

    function rawFace(uint256 id) external view returns (uint256) {
        return _fixtureNative().deployed[id];
    }

    /// @dev Test-only seeding pointer to the independently pinned native proxy slot. Production
    ///      libraries receive the original host pointer; they have no native storage getter.
    function _fixtureNative() private pure returns (ReserveManager.ReserveStorage storage n) {
        bytes32 slot = 0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;
        assembly ("memory-safe") {
            n.slot := slot
        }
    }
}

contract ReserveCreditBridgeFixture {
    address private immutable OWNER = msg.sender;
    ReserveManager public reserve;
    mapping(uint256 => ClaimBridge.Facility) private loans;

    function configure(ReserveManager source) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve = source;
    }

    function setLoan(uint256 id, ClaimBridge.Facility calldata f) external {
        require(msg.sender == OWNER, "fixture owner");
        loans[id] = f;
    }

    function facility(uint256 id) external view returns (ClaimBridge.Facility memory) {
        return loans[id];
    }

    function setAccruedPaymentDue(uint256 id, uint64 due) external {
        require(msg.sender == address(reserve), "fixture source");
        require(loans[id].pik && due > loans[id].nextPaymentDue && due <= loans[id].maturity, "signed due");
        loans[id].nextPaymentDue = due;
    }

    function amend(uint256 id, IAccrualLifecycle.Terms calldata terms) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve.amendAccruingLoan(id, terms);
    }
}

/// @dev The registry has an independent raw ledger and queries the real source's effective addition.
///      A callback verifies accounting neutrality and proves privileged mutation is refused.
contract ReserveCreditRegistryFixture {
    address private immutable OWNER = msg.sender;
    ReserveManager public reserve;
    uint256 public rawTotal;
    uint256 public expectedBacking;
    uint256 public observations;
    mapping(bytes32 => uint256) private raw;

    function configure(ReserveManager source) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve = source;
    }

    function seed(ClaimBridge.Facility calldata f) external {
        require(msg.sender == OWNER, "fixture owner");
        rawTotal += f.principal;
        raw[keccak256(abi.encode(uint8(1), f.classId))] += f.principal;
        raw[keccak256(abi.encode(uint8(2), f.borrowerId))] += f.principal;
        if (f.stateId != 0) raw[keccak256(abi.encode(uint8(3), f.stateId))] += f.principal;
    }

    function expectBacking(uint256 amount) external {
        require(msg.sender == OWNER, "fixture owner");
        expectedBacking = amount;
    }

    function decrease(ClaimBridge.Facility calldata f, uint256 amount) external {
        require(msg.sender == OWNER, "fixture owner");
        rawTotal -= amount;
        raw[keccak256(abi.encode(uint8(1), f.classId))] -= amount;
        raw[keccak256(abi.encode(uint8(2), f.borrowerId))] -= amount;
        if (f.stateId != 0) raw[keccak256(abi.encode(uint8(3), f.stateId))] -= amount;
    }

    function totalBookExposure() public view returns (uint256) {
        return rawTotal + reserve.accrualExposure(0, 0);
    }

    function exposure(uint8 kind, bytes32 key) external view returns (uint256) {
        return raw[keccak256(abi.encode(kind, key))] + reserve.accrualExposure(kind, key);
    }

    function recordAccruedExposure(uint256 classId, bytes32 borrower, bytes32 stateId, uint256 amount) external {
        require(msg.sender == address(reserve), "fixture source");
        rawTotal += amount;
        raw[keccak256(abi.encode(uint8(1), classId))] += amount;
        raw[keccak256(abi.encode(uint8(2), borrower))] += amount;
        if (stateId != 0) raw[keccak256(abi.encode(uint8(3), stateId))] += amount;
        require(totalBookExposure() == reserve.deployedPrincipal(), "posting exposure neutrality");
        if (expectedBacking != 0) require(reserve.totalBackingValue() == expectedBacking, "posting backing neutrality");
        (bool ok, bytes memory reason) = address(reserve).call(abi.encodeCall(ReserveManager.pause, ()));
        require(!ok && bytes4(reason) == ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector, "busy mutation");
        ++observations;
    }
}

contract ReserveCreditRiskFixture {
    address private immutable OWNER = msg.sender;
    ReserveManager public reserve;
    mapping(uint256 => uint256) public posted;

    function configure(ReserveManager source) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve = source;
    }

    function mark(uint256 id, bool value) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve.setAccrualPastDue(id, value);
    }

    function stop(uint256 id) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve.stopAccruingLoan(id);
    }

    function onAccrualPosted(uint256 id, uint256 amount) external {
        require(msg.sender == address(reserve), "fixture source");
        posted[id] += amount;
    }

    function writeDown(uint256 id, uint256 amount) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve.recordPrincipalWritedown(id, amount);
    }

    function retire(uint256 id) external {
        require(msg.sender == OWNER, "fixture owner");
        reserve.retireAccruedLoan(id);
    }
}

contract ReserveAccrualCreditTest is Test {
    ReserveCreditHostHarness private reserve;
    ReserveCreditBridgeFixture private bridge;
    ReserveCreditRegistryFixture private registry;
    ReserveCreditRiskFixture private risk;
    address private ASSET;
    uint256 private constant PRINCIPAL = 360_000e18;
    bytes32 private constant BORROWER = keccak256("credit borrower");
    bytes32 private constant STATE = keccak256("credit state");
    uint64 private start;

    function setUp() public {
        vm.warp(1_750_000_000);
        start = uint64(block.timestamp);
        ASSET = address(new MockERC20("USD Coin", "USDC", 6));
        reserve = new ReserveCreditHostHarness();
        bridge = new ReserveCreditBridgeFixture();
        registry = new ReserveCreditRegistryFixture();
        risk = new ReserveCreditRiskFixture();
        bridge.configure(reserve);
        registry.configure(reserve);
        risk.configure(reserve);
        reserve.seed(
            IContinuousAccrual.Modules({
                token: address(this),
                controller: address(this),
                vault: address(this),
                waterfall: address(this),
                bridge: address(bridge),
                registry: address(registry),
                defaultManager: address(risk)
            }),
            ASSET
        );
    }

    function _terms(bool pik) private view returns (ClaimBridge.Facility memory f) {
        f.classId = 1;
        f.borrowerId = BORROWER;
        f.stateId = STATE;
        f.principal = PRINCIPAL;
        f.interestRateBps = 1000;
        f.maturity = start + 360 days;
        f.paymentInterval = 90 days;
        f.nextPaymentDue = start + 90 days;
        f.rateType = ClaimBridge.RateType.Fixed;
        f.dayCountConvention = ClaimBridge.DayCountConvention.Actual360;
        f.state = ClaimBridge.LoanState.Active;
        f.pik = pik;
    }

    function _seed(uint256 id, ClaimBridge.Facility memory f) private {
        bridge.setLoan(id, f);
        registry.seed(f);
        reserve.seedFunded(id, f.principal);
    }

    function _fund(uint256 id, bool pik) private {
        _seed(id, _terms(pik));
        reserve.registerAccruingLoan(id);
    }

    function test_cashStreamsIntoBackingExposureAndBothFeeClaimsBeforeReceipt() public {
        _fund(1, false);
        vm.warp(start + 45 days);
        IContinuousAccrual.Snapshot memory s = reserve.accrualSnapshot();
        assertEq(s.gross, _cashStream(1000, 360 days, 45 days));
        assertEq(s.feeUnissued, s.gross / 10);
        assertEq(s.seniorUnissued, s.gross - s.feeUnissued);
        assertEq(s.unposted, s.gross);
        assertEq(s.unissued, s.gross);
        assertEq(reserve.totalBackingValue(), PRINCIPAL + s.gross);
        assertEq(registry.totalBookExposure(), PRINCIPAL + s.gross);
        assertEq(registry.exposure(1, bytes32(uint256(1))), PRINCIPAL + s.gross);
        assertEq(registry.exposure(2, BORROWER), PRINCIPAL + s.gross);
        assertEq(registry.exposure(3, STATE), PRINCIPAL + s.gross);
        assertEq(reserve.accrualExposure(3, 0), 0);
    }

    function test_postingPreservesEconomicLevelsAndClosesPrivilegedCallback() public {
        _fund(1, false);
        vm.warp(start + 30 days);
        IContinuousAccrual.Snapshot memory before_ = reserve.accrualSnapshot();
        uint256 backing = reserve.totalBackingValue();
        registry.expectBacking(backing);
        assertEq(reserve.postAccruedLoan(1), before_.gross);
        assertEq(reserve.rawFace(1), backing);
        assertEq(reserve.totalBackingValue(), backing);
        assertEq(registry.totalBookExposure(), backing);
        assertEq(reserve.accrualSnapshot().unposted, 0);
        assertEq(reserve.accrualSnapshot().unissued, before_.unissued);
        assertEq(registry.observations(), 1);
        assertEq(reserve.postAccruedLoan(1), 0);
        assertEq(registry.observations(), 1);
    }

    function test_unpostedBackingRemainsWhenAllPostedPrincipalIsImpaired() public {
        _fund(1, false);
        reserve.recognizePrincipalImpairment(1, PRINCIPAL, keccak256("native full mark"));
        vm.warp(start + 30 days);
        uint256 gross = reserve.accrualSnapshot().gross;
        assertGt(gross, 1000e18);
        assertEq(reserve.totalBackingValue(), gross);
    }

    function test_pikQuarterCompoundsOnlyAtSignedBoundaryAndCashDoesNotAdvanceDue() public {
        _fund(1, true);
        _fund(2, false);
        vm.warp(start + 90 days);
        assertFalse(reserve.accrualSnapshot().fresh);
        vm.expectRevert(
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, start + 90 days, start + 90 days)
        );
        reserve.postAccruedLoan(1);
        (uint256 processed, bool fresh) = reserve.checkpointAccrual(32);
        assertGt(processed, 0);
        assertTrue(fresh);
        IAccrualLifecycle.Debt memory pik = reserve.accruedDebt(1);
        IAccrualLifecycle.Debt memory cash = reserve.accruedDebt(2);
        assertEq(pik.principal, PRINCIPAL + 9000e18);
        assertEq(pik.interest, 0);
        assertEq(cash.principal, PRINCIPAL);
        assertEq(cash.interest, 9000e18);
        assertEq(bridge.facility(1).nextPaymentDue, start + 180 days);
        assertEq(bridge.facility(2).nextPaymentDue, start + 90 days);
        assertEq(reserve.rawFace(1), PRINCIPAL);
        assertEq(reserve.accrualSnapshot().gross, 9000e18 + _cashStream(1000, 360 days, 90 days));
    }

    function test_defaultClosesCompleteFaceAndStopsFutureInterest() public {
        _fund(1, false);
        vm.warp(start + 45 days);
        risk.stop(1);
        IAccrualLifecycle.Debt memory d = reserve.accruedDebt(1);
        assertFalse(d.active);
        assertEq(d.principal, PRINCIPAL);
        assertEq(d.interest, 4500e18);
        assertEq(reserve.rawFace(1), PRINCIPAL + 4500e18);
        assertEq(reserve.accrualReservedExposure(), 0);
        vm.warp(start + 180 days);
        assertEq(reserve.accrualSnapshot().gross, 4500e18);
        assertEq(reserve.totalBackingValue(), PRINCIPAL + 4500e18);
    }

    function test_maturityReleasesUnusedFutureCapacityWithoutPostingOrIssuingIncome() public {
        _fund(1, true);
        uint256 fullFace = PRINCIPAL;
        for (uint256 i; i < 4; ++i) {
            fullFace += fullFace * 1000 * 90 days / (10_000 * 360 days);
        }
        assertEq(reserve.accrualReservedExposure(), fullFace - PRINCIPAL);
        vm.warp(start + 360 days);
        (uint256 processed, bool fresh) = reserve.checkpointAccrual(32);
        // Four signed coupons plus the scheduler's one-second endpoint split when
        // the conservative reservation equals this exactly representable final face.
        assertEq(processed, 5);
        assertTrue(fresh);
        IAccrualLifecycle.Debt memory d = reserve.accruedDebt(1);
        assertFalse(d.active);
        assertGt(d.principal, PRINCIPAL);
        assertEq(reserve.accrualReservedExposure(), 0, "matured debt cannot reserve unearnable growth");
        assertEq(reserve.rawFace(1), PRINCIPAL, "retiring capacity is not posting");
        assertEq(reserve.accrualSnapshot().unissued, reserve.accrualSnapshot().gross);
        assertEq(reserve.deployedTo(1), d.principal + d.interest);
    }

    function test_pastDueGrowthMovesIntoRiskCarrierOnceOnPosting() public {
        _fund(1, false);
        vm.warp(start + 5 days);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_UnpostedRisk.selector, 1));
        risk.mark(1, true);
        reserve.postAccruedLoan(1);
        risk.mark(1, true);
        assertEq(reserve.accruedPastDue(1), 0);
        vm.warp(start + 10 days);
        uint256 growing = reserve.unpostedAccruedLoan(1);
        assertGt(growing, 0);
        assertEq(reserve.accruedPastDue(1), growing);
        reserve.postAccruedLoan(1);
        assertEq(risk.posted(1), growing);
        assertEq(reserve.accruedPastDue(1), 0);
        risk.mark(1, false);
        vm.warp(start + 20 days);
        assertEq(reserve.accruedPastDue(1), 0);
    }

    /// @dev The adapter supports zero-income epochs even though the current production bridge
    ///      refuses a zero-rate amendment. This fixture isolates dormant-cursor accounting.
    function test_dormantCouponCapitalizesBeforeAmendedCapacityIsReserved() public {
        _fund(1, true);
        vm.warp(start + 45 days);
        bridge.amend(1, IAccrualLifecycle.Terms(0, uint32(360 days), start + 90 days, 90 days, start + 360 days));
        vm.warp(start + 91 days);
        bridge.amend(1, IAccrualLifecycle.Terms(6000, uint32(360 days), start + 180 days, 90 days, start + 360 days));
        uint256 scale = 1e12;
        uint256 expected = PRINCIPAL + PRINCIPAL * 1000 * 45 days / (10_000 * 360 days) / scale * scale;
        expected += expected * 6000 * 89 days / (10_000 * 360 days) / scale * scale;
        for (uint256 i; i < 2; ++i) {
            expected += expected * 6000 * 90 days / (10_000 * 360 days) / scale * scale;
        }
        assertGe(reserve.accruedDebt(1).balanceCeiling, expected);
        vm.warp(start + 360 days);
        (, bool fresh) = reserve.checkpointAccrual(32);
        assertTrue(fresh);
        reserve.postAccruedLoan(1);
        assertEq(reserve.rawFace(1), expected);
    }

    function test_signedAmendmentPreservesOldIncomeAndAppliesNewRateProspectively() public {
        _fund(1, false);
        vm.warp(start + 30 days);
        bridge.amend(1, IAccrualLifecycle.Terms(2000, uint32(360 days), start + 120 days, 90 days, start + 360 days));
        assertEq(reserve.accrualSnapshot().gross, 3000e18);
        assertEq(reserve.rawFace(1), PRINCIPAL + 3000e18);
        vm.warp(start + 60 days);
        assertEq(reserve.accrualSnapshot().gross, 3000e18 + _cashStream(2000, 330 days, 30 days));
        assertEq(reserve.accruedDebt(1).principal, PRINCIPAL);
    }

    function test_permissionlessCatchupCommitsBoundedProgressFor100Loans() public {
        for (uint256 id = 1; id <= 100; ++id) {
            _fund(id, true);
        }
        vm.warp(start + 90 days);
        (uint256 n, bool fresh) = reserve.checkpointAccrual(32);
        assertEq(n, 32);
        assertFalse(fresh);
        (n, fresh) = reserve.checkpointAccrual(32);
        assertEq(n, 32);
        assertFalse(fresh);
        (n, fresh) = reserve.checkpointAccrual(32);
        assertEq(n, 32);
        assertFalse(fresh);
        (n, fresh) = reserve.checkpointAccrual(32);
        assertEq(n, 4);
        assertTrue(fresh);
        assertEq(reserve.accrualSnapshot().gross, 900_000e18);
    }

    function test_unsupportedFundedTermsFailBeforeRegistration() public {
        ClaimBridge.Facility memory f = _terms(false);
        f.rateType = ClaimBridge.RateType.Variable;
        _seed(1, f);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_UnsupportedTerms.selector, 1));
        reserve.registerAccruingLoan(1);
        assertFalse(reserve.accruedDebt(1).known);
        f.rateType = ClaimBridge.RateType.Fixed;
        f.dayCountConvention = ClaimBridge.DayCountConvention.Thirty360;
        bridge.setLoan(1, f);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_UnsupportedTerms.selector, 1));
        reserve.registerAccruingLoan(1);
    }

    function test_fundedRegistrationAndLifecycleAuthoritiesCannotBeSubstituted() public {
        _seed(1, _terms(false));
        address stranger = makeAddr("unbound event sender");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, address(this), stranger)
        );
        reserve.registerAccruingLoan(1);
        reserve.registerAccruingLoan(1);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_AlreadyKnown.selector, 1));
        reserve.registerAccruingLoan(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveAccrualCreditLib.AccrualCredit_WrongCaller.selector, address(risk), address(this)
            )
        );
        reserve.stopAccruingLoan(1);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_Unknown.selector, 2));
        reserve.postAccruedLoan(2);
    }

    function test_cashSupportsActual365WithoutPikBalanceCap() public {
        ClaimBridge.Facility memory f = _terms(false);
        f.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        f.interestRateBps = 10_000;
        f.maturity = start + 4 * 365 days;
        _seed(1, f);
        reserve.registerAccruingLoan(1);
        assertEq(reserve.accruedDebt(1).balanceCeiling, PRINCIPAL * 5);
        vm.warp(f.maturity);
        (, bool fresh) = reserve.checkpointAccrual(32);
        assertTrue(fresh);
        assertEq(reserve.accrualSnapshot().gross, PRINCIPAL * 4);
        assertEq(reserve.accruedDebt(1).principal, PRINCIPAL);
        assertFalse(reserve.accruedDebt(1).active);
        vm.warp(f.maturity + 365 days);
        assertEq(reserve.accrualSnapshot().gross, PRINCIPAL * 4);
    }

    function testFuzz_postingOrderDoesNotChangeBackingOrFees(uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, 1, 89 days));
        _fund(1, true);
        _fund(2, false);
        vm.warp(start + elapsed);
        IContinuousAccrual.Snapshot memory before_ = reserve.accrualSnapshot();
        uint256 backing = reserve.totalBackingValue();
        reserve.postAccruedLoan(2);
        reserve.postAccruedLoan(1);
        IContinuousAccrual.Snapshot memory after_ = reserve.accrualSnapshot();
        assertEq(after_.gross, before_.gross);
        assertEq(after_.feeUnissued, before_.feeUnissued);
        assertEq(after_.seniorUnissued, before_.seniorUnissued);
        assertEq(after_.unposted, 0);
        assertEq(reserve.totalBackingValue(), backing);
        assertEq(registry.totalBookExposure(), backing);
        assertEq(reserve.deployedTo(1) + reserve.deployedTo(2), backing);
    }

    /// @dev Independent signed-terms model for these exactly grid-aligned cash ceilings. The
    ///      final grid increment belongs to the maturity second; the preceding segment therefore
    ///      ends at H-1. Between boundaries the published stream uses an integer per-second rate.
    ///      No production planner, accumulator, storage term or quoted output supplies this value.
    function _cashStream(uint256 rateBps, uint256 horizon, uint256 elapsed) private pure returns (uint256) {
        uint256 endpoint = horizon - 1;
        uint256 nativeCoupon = PRINCIPAL * rateBps * endpoint / (10_000 * 360 days * 1e12);
        return (nativeCoupon * 1e12 / endpoint) * elapsed;
    }

    function _pay(uint256 id, uint256 principal, uint256 interest) private returns (uint256 outstanding) {
        uint256 total = principal + interest;
        assertEq(total % 1e12, 0, "receipt must lie on USDC grid");
        MockERC20(ASSET).mint(address(this), total / 1e12);
        MockERC20(ASSET).approve(address(reserve), total / 1e12);
        outstanding = reserve.repayAccruingLoan(id, address(this), principal, interest);
        registry.decrease(bridge.facility(id), total);
    }

    function test_cashReceiptMovesClaimToMeasuredCashWithoutSecondRecognitionOrFee() public {
        _fund(1, false);
        vm.warp(start + 30 days);
        assertEq(_pay(1, 0, 3000e18), PRINCIPAL);
        IContinuousAccrual.Snapshot memory afterCoupon = reserve.accrualSnapshot();
        assertEq(afterCoupon.gross, 3000e18);
        assertEq(afterCoupon.feeUnissued, 300e18);
        assertEq(afterCoupon.seniorUnissued, 2700e18);
        assertEq(reserve.idleUSDC(), 3000e6);
        assertEq(MockERC20(ASSET).balanceOf(address(reserve)), 3000e6);
        assertEq(reserve.accruedDebt(1).principal, PRINCIPAL);
        assertEq(reserve.accruedDebt(1).interest, 0);
        assertEq(_pay(1, 50_000e18, 0), PRINCIPAL - 50_000e18);
        assertEq(reserve.accrualSnapshot().gross, afterCoupon.gross);
        assertEq(reserve.accrualSnapshot().feeUnissued, afterCoupon.feeUnissued);
        assertEq(reserve.totalBackingValue(), PRINCIPAL + 3000e18);
        assertEq(registry.totalBookExposure(), PRINCIPAL - 50_000e18);
    }

    function test_fullPikPayoffIncludesCurrentUncapitalizedInterestAndCanRetire() public {
        _fund(1, true);
        vm.warp(start + 45 days);
        uint256 face = PRINCIPAL + 4500e18;
        assertEq(_pay(1, face, 0), 0);
        assertEq(reserve.accruedDebt(1).principal, 0);
        assertEq(reserve.accruedDebt(1).interest, 0);
        assertFalse(reserve.accruedDebt(1).active);
        assertEq(reserve.totalBackingValue(), face);
        assertEq(reserve.accrualSnapshot().gross, 4500e18);
        assertEq(reserve.accrualSnapshot().feeUnissued, 450e18);
        assertEq(reserve.accrualReservedExposure(), 0);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_ReceiptMismatch.selector, 1));
        reserve.retireAccruedLoan(1);
        ClaimBridge.Facility memory f = bridge.facility(1);
        f.state = ClaimBridge.LoanState.Repaid;
        bridge.setLoan(1, f);
        reserve.retireAccruedLoan(1);
        assertTrue(reserve.accruedDebt(1).known);
        vm.warp(start + 180 days);
        assertEq(reserve.accrualSnapshot().gross, 4500e18);
    }

    function test_cashPrincipalPayoffCannotEraseOutstandingInterest() public {
        _fund(1, false);
        vm.warp(start + 30 days);
        assertEq(_pay(1, PRINCIPAL, 0), 3000e18);
        assertEq(reserve.accruedDebt(1).principal, 0);
        assertEq(reserve.accruedDebt(1).interest, 3000e18);
        assertEq(_pay(1, 0, 3000e18), 0);
        assertEq(reserve.accrualSnapshot().gross, 3000e18);
        assertEq(reserve.totalBackingValue(), PRINCIPAL + 3000e18);
    }

    function test_receiptWithoutApprovalRollsBackAlignmentPostingAndDebt() public {
        _fund(1, false);
        vm.warp(start + 30 days);
        uint256 gross = reserve.accrualSnapshot().gross;
        MockERC20(ASSET).mint(address(this), 3000e6);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(reserve), 0, 3000e6)
        );
        reserve.repayAccruingLoan(1, address(this), 0, 3000e18);
        assertEq(reserve.accrualSnapshot().gross, gross);
        assertEq(reserve.rawFace(1), PRINCIPAL);
        assertEq(registry.rawTotal(), PRINCIPAL);
        assertEq(reserve.accruedDebt(1).interest, 3000e18);
        assertEq(MockERC20(ASSET).balanceOf(address(reserve)), 0);
        reserve.requireAccrualFresh();
    }

    function test_onlyStoppedPostedDebtCanBeWrittenDownAndCashInterestRecoveryRemains() public {
        _fund(1, false);
        vm.expectRevert(abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_InvalidWriteDown.selector, 1));
        risk.writeDown(1, 1e18);
        vm.warp(start + 30 days);
        risk.stop(1);
        risk.writeDown(1, 100_000e18);
        registry.decrease(bridge.facility(1), 100_000e18);
        assertEq(reserve.accruedDebt(1).principal, PRINCIPAL - 100_000e18);
        assertEq(reserve.accruedDebt(1).interest, 3000e18);
        assertEq(_pay(1, 0, 3000e18), PRINCIPAL - 100_000e18);
        assertEq(reserve.accrualSnapshot().gross, 3000e18);
        assertEq(reserve.accrualReservedExposure(), 0);
    }

    function test_legacyCreditSettersCannotBypassKnownContinuousDebt() public {
        _fund(1, true);
        bytes memory reason =
            abi.encodeWithSelector(ReserveAccrualCreditLib.AccrualCredit_UseAccrualLifecycle.selector, 1);
        vm.expectRevert(reason);
        reserve.recordDeployment(1, address(0x1234), 1e6);
        vm.expectRevert(reason);
        reserve.recordFeeCapitalization(1, 1e18);
        vm.expectRevert(reason);
        reserve.recordPikCapitalization(1, 1e18);
        vm.expectRevert(reason);
        reserve.recordPayment(1, address(this), 1e6, 1e18);
    }
}
