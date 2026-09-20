// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";

/// @dev Exercises the library's entry-state predicate independently of a privileged host wrapper.
contract DefaultAccrualIdleHarness {
    DefaultManager.DefaultStorage private state;
    address private immutable OWNER = msg.sender;

    constructor(IContinuousAccrual reserve) {
        state.accrualReserve = reserve;
    }

    function check(bool entered) external view {
        DefaultAccrualLib.requireIdle(state, entered);
    }

    function prepare(uint256 id, bool stop) external returns (bool, uint64) {
        return DefaultAccrualLib.prepare(state, id, stop);
    }

    function setPastDue(uint256 id, bool marked) external {
        DefaultAccrualLib.setPastDue(state, id, marked);
    }

    function seedMarked(uint256 id, uint256 contribution) external {
        require(msg.sender == OWNER, "fixture owner");
        state.pastDueMarked[id] = true;
        state.pastDueContribution[id] = contribution;
        state.pastDuePrincipal[1] = contribution;
        state.pastDueExposure = contribution;
    }

    function rounding(uint256 id, uint256 amount) external {
        DefaultAccrualLib.onRounding(state, id, amount);
    }

    function recorded(uint256 id) external view returns (uint256, uint256, uint256) {
        return (state.pastDueContribution[id], state.pastDuePrincipal[1], state.pastDueExposure);
    }
}

contract DefaultAccrualGuardsTest is RealOracleFixture {
    event DefaultAccrualBound(address indexed reserve);

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
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit DefaultAccrualBound(address(reserves));
        defaultManager.setAccrualReserve(address(reserves));
        assertEq(defaultManager.accrualReserve(), address(reserves));
    }

    function _rejectSource(address source) private {
        vm.prank(admin);
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_WrongModules.selector);
        defaultManager.setAccrualReserve(source);
        assertEq(defaultManager.accrualReserve(), address(0), "failed binding stored a source");
    }

    function _rejectReply(address target, bytes memory request, bytes memory reply) private {
        vm.mockCall(target, request, reply);
        _rejectSource(address(reserves));
        vm.clearMockedCalls();
    }

    function _checkReply(address target, bytes memory request) private {
        (bool ok, bytes memory original) = target.staticcall(request);
        assertTrue(ok, "fixture read failed");
        for (uint256 word; word < original.length / 32; ++word) {
            bytes memory changed = bytes.concat(original);
            assembly ("memory-safe") {
                mstore(add(add(changed, 32), mul(word, 32)), not(0))
            }
            _rejectReply(target, request, changed);
            // A valid-width foreign address must also fail each identity comparison.
            if (target == address(controller) && word == 1) continue;
            assembly ("memory-safe") {
                mstore(add(add(changed, 32), mul(word, 32)), 0xbad)
            }
            _rejectReply(target, request, changed);
        }
        _rejectReply(target, request, new bytes(original.length - 1));
        _rejectReply(target, request, bytes.concat(original, bytes32(0)));
        vm.mockCallRevert(target, request, abi.encodeWithSignature("Fixture_ReadRefused()"));
        _rejectSource(address(reserves));
        vm.clearMockedCalls();
    }

    function test_bindingValidatesEveryIdentityAndExactReadBeforeWriting() public {
        _checkReply(address(reserves), abi.encodeWithSignature("accrualModules()"));
        _checkReply(address(usdfr), abi.encodeWithSignature("accrualReserve()"));
        _checkReply(address(bridge), abi.encodeWithSignature("modules()"));
        _checkReply(address(controller), abi.encodeWithSignature("modules()"));
        _bind();
    }

    function test_bindingIsAuthorizedPermanentAndNativeToThisReserve() public {
        _rejectSource(address(0));
        _rejectSource(address(0xBADC0DE));
        _rejectSource(address(registry));
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        defaultManager.setAccrualReserve(address(reserves));
        assertEq(defaultManager.accrualReserve(), address(0));
        _bind();
        vm.prank(admin);
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_AlreadyBound.selector);
        defaultManager.setAccrualReserve(address(reserves));
    }

    function test_bindingRefusesBackstopChangesMadeDuringConfiguration() public {
        address original = defaultManager.backstop();
        vm.prank(admin);
        defaultManager.setBackstop(address(0));
        _rejectSource(address(reserves));
        assertEq(defaultManager.backstop(), address(0), "binding silently repaired governance state");
        vm.prank(admin);
        defaultManager.setBackstop(original);
        _bind();
    }

    function test_bindingRequiresAnExactReadableBackstopReply() public {
        bytes memory request = abi.encodeWithSignature("reserveLossModules()");
        (bool ok, bytes memory original) = address(reserves).staticcall(request);
        assertTrue(ok);
        assertEq(original.length, 160);
        uint256[3] memory lengths = [uint256(0), 32, 159];
        for (uint256 i; i < lengths.length; ++i) {
            _rejectReply(address(reserves), request, new bytes(lengths[i]));
        }
        _rejectReply(address(reserves), request, bytes.concat(original, bytes1(0)));
        _rejectReply(address(reserves), request, bytes.concat(original, bytes32(0)));
        // A revert carrying an otherwise valid tuple must never be accepted as a reply.
        vm.mockCallRevert(address(reserves), request, original);
        _rejectSource(address(reserves));
        vm.clearMockedCalls();
        _bind();
    }

    function test_bindingRefusesNonCanonicalBackstopAddressBits() public {
        bytes memory request = abi.encodeWithSignature("reserveLossModules()");
        (bool ok, bytes memory reply) = address(reserves).staticcall(request);
        assertTrue(ok);
        uint256 nonCanonical = uint256(uint160(defaultManager.backstop())) | (uint256(1) << 160);
        assembly ("memory-safe") {
            mstore(add(reply, 64), nonCanonical)
        }
        _rejectReply(address(reserves), request, reply);
        _bind();
    }

    function testFuzz_bindingRequiresTheSameFullWidthBackstopWord(uint256 candidate) public {
        bytes memory request = abi.encodeWithSignature("reserveLossModules()");
        (bool ok, bytes memory reply) = address(reserves).staticcall(request);
        assertTrue(ok);
        assertEq(reply.length, 160);
        assembly ("memory-safe") {
            mstore(add(reply, 64), candidate)
        }
        if (candidate == uint256(uint160(defaultManager.backstop()))) {
            vm.mockCall(address(reserves), request, reply);
            _bind();
            vm.clearMockedCalls();
        } else {
            _rejectReply(address(reserves), request, reply);
            _bind();
        }
    }

    function test_boundBackstopAllowsOnlyConfirmationOfTheExistingAddress() public {
        address original = defaultManager.backstop();
        _bind();
        vm.prank(admin);
        defaultManager.setBackstop(original);
        address[2] memory replacements = [address(0), address(registry)];
        for (uint256 i; i < replacements.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(DefaultAccrualLib.DefaultAccrual_WrongModules.selector);
            defaultManager.setBackstop(replacements[i]);
            assertEq(defaultManager.backstop(), original, "bound route changed");
        }
    }

    function _rejectCallbackCaller() private {
        bytes memory reason =
            abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, address(this));
        vm.expectRevert(reason);
        defaultManager.onAccrualPosted(1, 1);
        vm.expectRevert(reason);
        defaultManager.onAccrualRounding(1, 1);
    }

    function test_postingAndRoundingCallbacksRequireTheSourceAndAnIdleDelivery() public {
        _rejectCallbackCaller();
        _bind();
        _rejectCallbackCaller();
        vm.prank(address(reserves));
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_NotMarked.selector, 1));
        defaultManager.onAccrualPosted(1, 1);
        IContinuousAccrual.Delivery memory delivery;
        delivery.active = true;
        vm.mockCall(address(reserves), abi.encodeWithSignature("accrualDelivery()"), abi.encode(delivery));
        vm.prank(address(reserves));
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_OperationInProgress.selector);
        defaultManager.onAccrualPosted(1, 1);
        vm.prank(address(reserves));
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_OperationInProgress.selector);
        defaultManager.onAccrualRounding(1, 1);
        vm.clearMockedCalls();
        uint256 revision = defaultManager.impairmentRevision();
        vm.prank(address(reserves));
        defaultManager.onAccrualRounding(1, 1);
        assertEq(defaultManager.impairmentRevision(), revision, "unmarked callback invented risk history");
        assertEq(defaultManager.pastDueExposure(), 0);
    }

    function test_nestedMutationRefusesOnlyAfterTheSourceIsEnabled() public {
        DefaultAccrualIdleHarness absent = new DefaultAccrualIdleHarness(IContinuousAccrual(address(0)));
        absent.check(true);
        DefaultAccrualIdleHarness host = new DefaultAccrualIdleHarness(IContinuousAccrual(address(reserves)));
        host.check(true);
        IContinuousAccrual.Snapshot memory snapshot;
        snapshot.enabled = true;
        vm.mockCall(address(reserves), abi.encodeWithSignature("accrualSnapshot()"), abi.encode(snapshot));
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_OperationInProgress.selector);
        host.check(true);
        host.check(false);
        vm.clearMockedCalls();
    }

    /// @notice The explicit legacy entry cannot bypass native default checkpointing.
    function test_legacyPreparationRefusesAnEnabledNativeBook() public {
        _bind();
        IContinuousAccrual.Snapshot memory snapshot;
        snapshot.enabled = true;
        snapshot.fresh = true;
        vm.mockCall(address(reserves), abi.encodeCall(IContinuousAccrual.accrualSnapshot, ()), abi.encode(snapshot));
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_NotLegacyPik.selector, uint256(17)));
        vm.prank(servicer);
        defaultManager.settleLegacyPikForDefault(17, bytes32(0), 1);
        vm.clearMockedCalls();
    }

    function test_unknownDebtCannotBePreparedOrAddedToTheMarkedCohort() public {
        DefaultAccrualIdleHarness host = new DefaultAccrualIdleHarness(IContinuousAccrual(address(reserves)));
        IContinuousAccrual.Snapshot memory snapshot;
        snapshot.enabled = true;
        vm.mockCall(address(reserves), abi.encodeWithSignature("accrualSnapshot()"), abi.encode(snapshot));
        assertFalse(reserves.accruedDebt(17).known, "fixture unexpectedly registered the debt");
        bytes memory reason = abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_UnknownFacility.selector, 17);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(reason);
            host.prepare(17, i != 0);
            vm.expectRevert(reason);
            host.setPastDue(17, i != 0);
        }
        vm.clearMockedCalls();
        (bool tracked, uint64 due) = host.prepare(17, false);
        assertFalse(tracked);
        assertEq(due, 0);
        host.setPastDue(17, true);
    }

    function test_markedRoundingCannotEraseMoreThanItsRecordedContribution() public {
        DefaultAccrualIdleHarness host = new DefaultAccrualIdleHarness(IContinuousAccrual(address(reserves)));
        uint256[3] memory amounts = [uint256(0), uint256(1e18), type(uint256).max - 1];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            host.seedMarked(17, amount);
            vm.prank(address(reserves));
            vm.expectRevert(
                abi.encodeWithSelector(
                    DefaultAccrualLib.DefaultAccrual_RoundingExceedsContribution.selector, 17, amount + 1, amount
                )
            );
            host.rounding(17, amount + 1);
            vm.prank(address(reserves));
            host.rounding(17, 0);
            (uint256 row, uint256 classTotal, uint256 globalTotal) = host.recorded(17);
            assertEq(row, amount);
            assertEq(classTotal, amount);
            assertEq(globalTotal, amount);
        }
    }
}
