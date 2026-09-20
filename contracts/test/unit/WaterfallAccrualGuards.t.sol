// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";

import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle, IAccrualServicing} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IAccrualExposure} from "../../src/interfaces/IAccrualExposure.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {WaterfallAccrualLib} from "../../src/libraries/WaterfallAccrualLib.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";

contract WaterfallAccrualBindingGuardsTest is RealOracleFixture {
    event AccrualReserveSet(address indexed reserve);

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        reserves.configureContinuousAccrual(
            IContinuousAccrual.Modules(
                address(usdfr),
                address(controller),
                address(vault),
                address(waterfall),
                address(bridge),
                address(registry),
                address(defaultManager)
            )
        );
        usdfr.setAccrualReserve(address(reserves));
        vm.stopPrank();
    }

    function _bind() private {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(waterfall));
        emit AccrualReserveSet(address(reserves));
        waterfall.setAccrualReserve(address(reserves));
        assertEq(waterfall.accrualReserve(), address(reserves));
    }

    function _refuse(address reserve) private {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(WaterfallAccrualLib.WaterfallAccrual_InvalidReserve.selector, reserve));
        waterfall.setAccrualReserve(reserve);
        assertEq(waterfall.accrualReserve(), address(0), "refused binding changed the source");
    }

    function _reply(address target, bytes memory request, bytes memory changed) private {
        vm.mockCall(target, request, changed);
        _refuse(address(reserves));
        vm.clearMockedCalls();
    }

    function _checkReply(address target, bytes memory request) private {
        (bool ok, bytes memory original) = target.staticcall(request);
        assertTrue(ok);
        assertGt(original.length, 0);
        for (uint256 word; word < original.length / 32; ++word) {
            bytes memory changed = bytes.concat(original);
            assembly ("memory-safe") {
                mstore(add(add(changed, 32), mul(word, 32)), not(0))
            }
            _reply(target, request, changed);
            if (target == address(controller) && word == 1) continue;
            uint256 foreign = uint256(uint160(address(this)));
            assembly ("memory-safe") {
                mstore(add(add(changed, 32), mul(word, 32)), foreign)
            }
            _reply(target, request, changed);
        }
        _reply(target, request, new bytes(original.length - 1));
        _reply(target, request, bytes.concat(original, bytes32(0)));
        vm.mockCallRevert(target, request, abi.encodeWithSignature("Fixture_ReadRefused()"));
        _refuse(address(reserves));
        vm.clearMockedCalls();
    }

    function test_bindingChecksEveryFixedAbiReplyAndNativeIdentity() public {
        _checkReply(address(reserves), abi.encodeWithSignature("accrualModules()"));
        _checkReply(address(usdfr), abi.encodeWithSignature("accrualReserve()"));
        _checkReply(address(controller), abi.encodeWithSignature("modules()"));
        _checkReply(address(reserves), abi.encodeWithSignature("lossController()"));
        _checkReply(address(bridge), abi.encodeWithSignature("modules()"));
        bytes memory code = address(reserves).code;
        vm.etch(address(reserves), bytes(""));
        assertEq(address(reserves).code.length, 0);
        _refuse(address(reserves));
        vm.etch(address(reserves), code);
        assertEq(address(reserves).codehash, keccak256(code));
        _bind();
    }

    function test_bindingIsAuthorizedPermanentAndRestrictedToTheNativeReserve() public {
        _refuse(address(0));
        _refuse(address(registry));
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        waterfall.setAccrualReserve(address(reserves));
        assertEq(waterfall.accrualReserve(), address(0));
        _bind();
        vm.prank(admin);
        vm.expectRevert(WaterfallEngine.Waterfall_AccrualAlreadyBound.selector);
        waterfall.setAccrualReserve(address(reserves));
    }
}

/// @dev Read-only protocol quotes against a controlled table of facility and source states.
contract WaterfallAccrualStatusFixture {
    ClaimBridge.Facility private f;
    IAccrualLifecycle.Debt private d;
    bool private scheduled;
    bool private fresh;
    bool private busy;

    error Fixture_Busy();

    function configure(
        ClaimBridge.Facility memory facility_,
        IAccrualLifecycle.Debt memory debt_,
        bool scheduled_,
        bool fresh_,
        bool busy_
    ) external {
        f = facility_;
        d = debt_;
        scheduled = scheduled_;
        fresh = fresh_;
        busy = busy_;
    }

    function facility(uint256) external view returns (ClaimBridge.Facility memory) {
        return f;
    }

    function accruedDebt(uint256) external view returns (IAccrualLifecycle.Debt memory) {
        return d;
    }

    function accrualLoanScheduled(uint256) external view returns (bool) {
        return scheduled;
    }

    function accrualSnapshot() external view returns (IContinuousAccrual.Snapshot memory s) {
        s.enabled = true;
        s.fresh = fresh;
    }

    function requireAccrualIdle() external view {
        if (busy) revert Fixture_Busy();
    }

    function status() external view returns (bool, bool) {
        return WaterfallAccrualLib.status(address(this), address(this), 1);
    }
}

contract WaterfallAccrualStatusGuardsTest is Test {
    WaterfallAccrualStatusFixture private fixture;

    function setUp() public {
        fixture = new WaterfallAccrualStatusFixture();
    }

    /// @dev Modes are explicit expected outcomes from the servicing rules. Principal and time
    ///      vary independently; the table includes principal-free but interest-bearing debt.
    function testFuzz_statusMatchesTheServicingTruthTable(uint8 scenario, uint176 principalSeed, uint32 timeSeed)
        public
    {
        uint256 mode = uint256(scenario) % 14;
        uint64 at = 1_000_000 + uint64(timeSeed);
        vm.warp(at);
        ClaimBridge.Facility memory f;
        f.pik = true;
        f.state = ClaimBridge.LoanState.Active;
        IAccrualLifecycle.Debt memory d = IAccrualLifecycle.Debt({
            principal: 1 + uint256(principalSeed),
            interest: 0,
            balanceCeiling: type(uint256).max,
            accruedThrough: at,
            nextCapitalization: at,
            maturity: at + 1 days,
            pik: true,
            active: true,
            known: true
        });
        bool scheduled = true;
        bool fresh = true;
        bool busy;
        if (mode == 1) scheduled = false;
        if (mode == 2) {
            scheduled = false;
            fresh = false;
        }
        if (mode == 3) busy = true;
        if (mode == 4) d.known = false;
        if (mode == 5) f.pik = false;
        if (mode == 6) d.active = false;
        if (mode == 7) d.nextCapitalization = 0;
        if (mode == 8) d.nextCapitalization = at + 1;
        if (mode == 9) d.maturity = at - 1;
        if (mode == 10) d.principal = 0;
        if (mode == 11) f.state = ClaimBridge.LoanState.Defaulted;
        if (mode == 12) f.state = ClaimBridge.LoanState.Amortizing;
        if (mode == 13) {
            d.interest = d.principal;
            d.principal = 0;
        }
        fixture.configure(f, d, scheduled, fresh, busy);
        (bool due, bool blocked) = fixture.status();
        assertEq(due, mode < 2 || mode >= 12, "due quote disagrees with servicing case");
        assertEq(blocked, mode >= 2 && mode <= 4, "blocked quote disagrees with servicing case");
    }
}

contract WaterfallAccrualNativeGuardsTest is NativeAccrualFixture {
    /// @notice Native PIK keeps its scheduled due date and final balloon while legacy preparation changes.
    function test_nativePikMarkingUsesTheScheduleThenTheMaturityBalloon() public {
        _nativeFund(50_000e18);
        uint64 due = bridge.facility(nativeId).nextPaymentDue;
        uint64 maturity = bridge.facility(nativeId).maturity;
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        _nativeAdvance(nativeStart + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, nativeId, due, due + grace)
        );
        defaultManager.markPastDue(nativeId);
        _nativeAdvance(maturity);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_NotPastDue.selector, nativeId, maturity, maturity + grace
            )
        );
        defaultManager.markPastDue(nativeId);
        _nativeAdvance(maturity + grace + 1);
        uint256 face = reserves.deployedTo(nativeId);
        defaultManager.markPastDue(nativeId);
        assertEq(defaultManager.pastDueContribution(nativeId), face);
        assertEq(reserves.deployedTo(nativeId), face, "native mark invented another coupon");
    }

    function test_legacyCouponViewRefusesAnEnabledNativeBook() public {
        assertTrue(reserves.accrualSnapshot().enabled);
        vm.expectRevert(abi.encodeWithSelector(WaterfallEngine.Waterfall_AccrualManagedPik.selector, uint256(17)));
        waterfall.pendingLegacyPik(17);
    }

    event AccrualCheckpointed(uint256 indexed tokenId, uint256 processed, bool fresh, uint256 capitalized);

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function _status(uint256 id, bool due, bool blocked) private view {
        assertEq(waterfall.pikCrankIsDue(id), due, "native due quote differs");
        assertEq(waterfall.pikCrankBlockedByProtocol(id), blocked, "native blocked quote differs");
    }

    function _refuseCrank(bytes memory reason) private {
        vm.expectRevert(reason);
        waterfall.capitalizePik(nativeId);
        vm.clearMockedCalls();
    }

    function test_checkpointRefusesCashUnfundedEmptyAndNonperformingDebt() public {
        _nativeFund(50_000e18);
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        bytes memory facilityCall = abi.encodeCall(ClaimBridge.facility, (nativeId));
        f.pik = false;
        vm.mockCall(address(bridge), facilityCall, abi.encode(f));
        _refuseCrank(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotDesignated.selector, nativeId));
        f.pik = true;
        for (uint8 state_; state_ <= uint8(ClaimBridge.LoanState.Resolved); ++state_) {
            if (state_ == uint8(ClaimBridge.LoanState.Active) || state_ == uint8(ClaimBridge.LoanState.Amortizing)) {
                continue;
            }
            f.state = ClaimBridge.LoanState(state_);
            vm.mockCall(address(bridge), facilityCall, abi.encode(f));
            _refuseCrank(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotPerforming.selector, nativeId, state_));
        }
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(nativeId);
        bytes memory debtCall = abi.encodeCall(IAccrualLifecycle.accruedDebt, (nativeId));
        d.known = false;
        vm.mockCall(address(reserves), debtCall, abi.encode(d));
        _refuseCrank(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNotFunded.selector, nativeId));
        d.known = true;
        d.principal = 0;
        d.interest = 0;
        vm.mockCall(address(reserves), debtCall, abi.encode(d));
        _refuseCrank(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikNothingOutstanding.selector, nativeId));
        bytes memory busy = abi.encodeWithSelector(ReserveAccrualLib.ReserveAccrual_OperationInProgress.selector);
        vm.mockCallRevert(address(reserves), abi.encodeCall(IAccrualExposure.requireAccrualIdle, ()), busy);
        _refuseCrank(busy);
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function test_nativeScheduledQuotesMatchTheCrankAndItsPauseGate() public {
        _nativeFund(50_000e18);
        _status(nativeId, false, false);
        uint64 due = nativeStart + 90 days;
        vm.warp(due);
        _status(nativeId, true, false);
        vm.prank(guardian);
        waterfall.pause();
        _status(nativeId, false, true);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        waterfall.capitalizePik(nativeId);
        vm.prank(guardian);
        waterfall.unpause();
        vm.expectEmit(true, false, false, true, address(waterfall));
        emit AccrualCheckpointed(nativeId, 1, true, 1_750e18);
        uint256 amount = waterfall.capitalizePik(nativeId);
        assertEq(amount, 1_750e18, "selected principal change is the contractual PIK amount");
        _nativeAdvance(due);
        _status(nativeId, false, false);
    }

    function test_nativeDormantQuoteWaitsForSharedWorkAndServicingAdvancesItsDate() public {
        _nativeFund(_nativeScale());
        uint256 dormant = nativeId;
        assertFalse(reserves.accrualLoanScheduled(dormant));
        _status(dormant, false, false);
        _nativeFund(50_000e18);
        uint64 due = nativeStart + 90 days;
        vm.warp(due);
        assertFalse(reserves.accrualSnapshot().fresh);
        _status(dormant, false, true);
        vm.expectEmit(true, false, false, true, address(waterfall));
        emit AccrualCheckpointed(dormant, 1, true, 0);
        assertEq(waterfall.capitalizePik(dormant), 0);
        assertEq(reserves.accruedDebt(dormant).nextCapitalization, due + 90 days);
        _status(dormant, false, false);
        _nativeAdvance(due);
        _status(nativeId, false, false);
        vm.warp(due + 90 days);
        reserves.checkpointAccrual(32);
        _status(dormant, true, false);
        assertEq(waterfall.capitalizePik(dormant), 0);
        _status(dormant, false, false);
        _assertNativeBacking();
    }
}
