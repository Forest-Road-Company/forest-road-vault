// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {MockAttestationOracle} from "../helpers/MockAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Completed legacy coupons remain in debt, supply and risk before default freezes the loan.
contract LegacyPikDefaultTest is CreditLayerFixture {
    uint256 internal constant P = 1_000_000e18;
    uint256 internal constant SCALE = 1e12;
    uint256 internal id;
    uint64 internal firstDue;

    event LegacyPikPreparedForDefault(uint256 indexed tokenId, uint256 processed, uint64 pendingDue);
    event LegacyPikRiskRecorded(uint256 indexed tokenId, uint256 indexed classId, uint256 amount, uint256 contribution);
    event DefaultDeclared(uint256 indexed tokenId, uint256 indexed classId, bytes32 remedyRef);

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function setUp() public virtual override {
        super.setUp();
        id = _liveFilmFacility(P);
        firstDue = bridge.facility(id).nextPaymentDue;
        vm.startPrank(admin);
        vault.setManagementFee(0);
        vault.setPerformanceFee(1000);
        waterfall.setProtocolFee(1000);
        defaultManager.setGraceWindow(Config.CLASS_FILM_TAX_CREDITS, 1 days);
        defaultManager.setRemedyRef(Config.CLASS_FILM_TAX_CREDITS, FILM_REF);
        vm.stopPrank();
        vm.startPrank(alice);
        usdfr.approve(address(vault), P);
        vault.deposit(P, alice);
        vm.stopPrank();
    }

    function _declare() internal {
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    function _coupon(uint256 basis) internal view returns (uint256) {
        return basis * 1400 * bridge.facility(id).paymentInterval / (10_000 * 360 days) / SCALE * SCALE;
    }

    function _model(uint256 count) internal view returns (uint256 face, uint256 protocolFees) {
        face = P;
        for (uint256 i; i < count; ++i) {
            uint256 coupon = _coupon(face);
            face += coupon;
            protocolFees += coupon / 10;
        }
    }

    function _assertDefault(uint256 face) internal view {
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
        assertEq(reserves.deployedTo(id), face, "default omitted an earned coupon");
        assertEq(defaultManager.defaultedContribution(id), face, "declared row differs from debt");
        assertEq(defaultManager.declaredDefaultedPrincipal(Config.CLASS_FILM_TAX_CREDITS), face);
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), face);
        assertEq(defaultManager.pastDueContribution(id), 0, "past-due row counted twice");
        assertEq(defaultManager.pastDueExposure(), 0);
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue());
        (,, bool valid) = oracle.latestPayload(id, IAttestationOracle.AttestationKind.DefaultDeclared);
        assertTrue(valid, "default evidence must remain standing");
    }

    function _financialState() internal view returns (bytes32) {
        (uint64 at, uint16 rate) = waterfall.pikCursorOf(id);
        return keccak256(
            abi.encode(
                bridge.facility(id),
                reserves.deployedTo(id),
                usdfr.totalSupply(),
                reserves.totalBackingValue(),
                defaultManager.pastDueContribution(id),
                defaultManager.pastDueExposure(),
                defaultManager.defaultedContribution(id),
                vault.totalSupply(),
                usdfr.balanceOf(feeRecipient),
                at,
                rate
            )
        );
    }

    function test_defaultRecordsCouponBeforeFreezingAndChargesBothFees() public {
        vm.warp(firstDue);
        uint256 coupon = _coupon(P);
        uint256 supply = usdfr.totalSupply();
        uint256 backing = reserves.totalBackingValue();
        uint256 protocol = usdfr.balanceOf(feeRecipient);
        uint256 performance = vault.balanceOf(feeRecipient);
        _attestDefault(id);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit DefaultDeclared(id, Config.CLASS_FILM_TAX_CREDITS, FILM_REF);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _assertDefault(P + coupon);
        assertEq(usdfr.totalSupply() - supply, coupon);
        assertEq(reserves.totalBackingValue() - backing, coupon);
        assertEq(usdfr.balanceOf(feeRecipient) - protocol, coupon / 10);
        assertGt(vault.balanceOf(feeRecipient), performance, "performance fee was omitted");
        vm.warp(block.timestamp + 90 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PikNotPerforming.selector, id, uint8(ClaimBridge.LoanState.Defaulted)
            )
        );
        waterfall.capitalizePik(id);
        assertEq(reserves.deployedTo(id), P + coupon, "defaulted debt continued earning");
    }

    /// @notice Independent arithmetic covers backlog sizes, keeper prefixes and both fee legs.
    function testFuzz_defaultAndKeeperAgreeAcrossCompletedCoupons(uint8 countSeed, uint8 prefixSeed) public {
        uint256 count = bound(countSeed, 1, 12);
        uint256 prefix = bound(prefixSeed, 0, count);
        vm.warp(uint256(firstDue) + (count - 1) * bridge.facility(id).paymentInterval);
        uint256 supply = usdfr.totalSupply();
        uint256 backing = reserves.totalBackingValue();
        uint256 protocol = usdfr.balanceOf(feeRecipient);
        for (uint256 i; i < prefix; ++i) {
            waterfall.capitalizePik(id);
        }
        _declare();
        (uint256 expected, uint256 fees) = _model(count);
        _assertDefault(expected);
        assertEq(waterfall.pikCapitalisedTotalOf(id), expected - P);
        assertEq(usdfr.totalSupply() - supply, expected - P);
        assertEq(reserves.totalBackingValue() - backing, expected - P);
        assertEq(usdfr.balanceOf(feeRecipient) - protocol, fees);
    }

    function test_partialRepaymentPreservesFrozenCouponBasisBeforeDefault() public {
        vm.warp(firstDue - 1);
        _repay(id, 0, P / 2);
        vm.warp(uint256(firstDue) + 2 * bridge.facility(id).paymentInterval);
        (uint256 fullFace,) = _model(3);
        _declare();
        _assertDefault(fullFace - P / 2);
    }

    function test_noCompletedCouponDoesNotInventAStubOrRequireUnpause() public {
        vm.warp(firstDue - 1);
        vm.startPrank(guardian);
        waterfall.pause();
        defaultManager.pause();
        vm.stopPrank();
        _declare();
        _assertDefault(P);
    }

    function test_maturityAllowsOnlyCompletedContractualCoupons() public {
        ClaimBridge.Facility memory f = bridge.facility(id);
        vm.warp(uint256(f.maturity) + 100 days);
        uint256 count = (uint256(f.maturity) - firstDue) / f.paymentInterval + 1;
        while (count > 16) {
            _attestDefault(id);
            vm.prank(servicer);
            defaultManager.settleLegacyPikForDefault(id, FILM_REF, 16);
            count -= 16;
        }
        _declare();
        (uint256 expected,) = _model((uint256(f.maturity) - firstDue) / f.paymentInterval + 1);
        _assertDefault(expected);
        assertEq(waterfall.pendingLegacyPik(id), 0);
    }

    function test_pausedPostingRefusesDefaultWithoutPartialChanges() public {
        vm.warp(firstDue);
        _attestDefault(id);
        vm.prank(guardian);
        waterfall.pause();
        bytes32 beforeState = _financialState();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(_financialState(), beforeState);
        vm.prank(guardian);
        waterfall.unpause();
        _declare();
        _assertDefault(P + _coupon(P));
    }

    function _markWithBlockedPosting() internal {
        uint64 grace = defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS);
        vm.prank(guardian);
        waterfall.pause();
        vm.warp(uint256(firstDue) + 2 * grace + 1);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueContribution(id), P);
        vm.prank(guardian);
        waterfall.unpause();
    }

    function test_markedLoanRecordsInterestWithoutClaimingACure() public {
        _markWithBlockedPosting();
        uint256 coupon = _coupon(P);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PikPastDue.selector, id));
        waterfall.capitalizePik(id);
        uint256 anchor = defaultManager.pastDueReliefAnchor();
        uint256 revision = defaultManager.impairmentRevision();
        _attestDefault(id);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit LegacyPikRiskRecorded(id, Config.CLASS_FILM_TAX_CREDITS, coupon, P + coupon);
        vm.prank(servicer);
        (uint256 processed, uint64 due) = defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
        assertEq(processed, 1);
        assertEq(due, 0);
        assertEq(defaultManager.pastDueContribution(id), P + coupon);
        assertEq(defaultManager.pastDuePrincipal(Config.CLASS_FILM_TAX_CREDITS), P + coupon);
        assertEq(defaultManager.pastDueExposure(), P + coupon);
        assertEq(defaultManager.pastDueReliefAnchor(), anchor, "preparation reset relief clock");
        assertEq(defaultManager.impairmentRevision(), revision + 1, "preparation did not revise the risk record");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
        assertEq(defaultManager.defaultedContribution(id), 0);
        _declare();
        _assertDefault(P + coupon);
    }

    function test_markedDefaultRecordsAndTransfersTheWholeRiskExactlyOnce() public {
        _markWithBlockedPosting();
        vm.warp(uint256(firstDue) + 2 * bridge.facility(id).paymentInterval);
        (uint256 expected,) = _model(3);
        _declare();
        _assertDefault(expected);
        assertEq(defaultManager.pendingSeniorImpairment(), expected);
    }

    function test_preparationIsBoundedAttestedAndServicerOnly() public {
        vm.warp(firstDue);
        bytes32 beforeState = _financialState();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.SERVICER_ROLE)
        );
        vm.prank(alice);
        defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        vm.prank(servicer);
        defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
        _attestDefault(id);
        for (uint256 i; i < 2; ++i) {
            uint256 count = i == 0 ? 0 : 17;
            vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_InvalidPikBatch.selector, count));
            vm.prank(servicer);
            defaultManager.settleLegacyPikForDefault(id, FILM_REF, count);
        }
        assertEq(_financialState(), beforeState);
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit LegacyPikPreparedForDefault(id, 1, 0);
        vm.prank(servicer);
        defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
        _declare();
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        vm.prank(servicer);
        defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
    }

    function test_incorrectServicingReturnCannotFinalizeDefault() public {
        vm.warp(firstDue);
        _attestDefault(id);
        vm.mockCall(address(waterfall), abi.encodeCall(WaterfallEngine.capitalizePik, (id)), abi.encode(uint256(0)));
        bytes32 beforeState = _financialState();
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_LegacyPikMismatch.selector, id));
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(_financialState(), beforeState);
        vm.clearMockedCalls();
    }

    function test_eachPausedPostingDependencyPreservesMarkedDebtOnFailure() public {
        // Use a different posting dependency to build the marked fixture. Removing the
        // WaterfallEngine pause must fail at the operation under test, not at setup.
        vm.prank(guardian);
        controller.pause();
        vm.warp(uint256(firstDue) + 2 * defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueContribution(id), P);
        vm.prank(guardian);
        controller.unpause();
        _attestDefault(id);
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(guardian);
            if (i == 0) reserves.pause();
            else if (i == 1) controller.pause();
            else if (i == 2) usdfr.pause();
            else waterfall.pause();
            bytes32 beforeState = _financialState();
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            vm.prank(servicer);
            defaultManager.declareDefault(id, FILM_REF);
            assertEq(_financialState(), beforeState, "failed posting changed marked debt or fees");
            vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
            vm.prank(servicer);
            defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
            assertEq(_financialState(), beforeState, "failed preparation changed marked debt or fees");
            assertTrue(vm.revertToStateAndDelete(snap));
        }
        _declare();
        _assertDefault(P + _coupon(P));
    }

    function test_preparationRepeatDoesNotChargeTheSameCouponTwice() public {
        vm.warp(firstDue);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.settleLegacyPikForDefault(id, FILM_REF, 1);
        bytes32 afterFirst = _financialState();
        vm.prank(servicer);
        (uint256 processed, uint64 due) = defaultManager.settleLegacyPikForDefault(id, FILM_REF, 16);
        assertEq(processed, 0);
        assertEq(due, 0);
        assertEq(_financialState(), afterFirst, "the second preparation recognized duplicate income");
        _declare();
        _assertDefault(P + _coupon(P));
    }

    function test_bridgeOperationMustFinishBeforeLegacyDefaultPosting() public {
        vm.warp(firstDue);
        _attestDefault(id);
        vm.mockCall(address(bridge), abi.encodeCall(ClaimBridge.creditOperationIdle, ()), abi.encode(false));
        bytes32 beforeState = _financialState();
        vm.expectRevert(IDefaultManager.DefaultManager_CreditOperationBusy.selector);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(_financialState(), beforeState);
        vm.clearMockedCalls();
    }

    function test_incorrectCouponPlanCannotMoveAnyValue() public {
        vm.warp(firstDue);
        _attestDefault(id);
        WaterfallEngine.PikPlan memory plan = waterfall.planPik(id);
        ++plan.dueAt;
        vm.mockCall(address(waterfall), abi.encodeCall(WaterfallEngine.planPik, (id)), abi.encode(plan));
        bytes32 beforeState = _financialState();
        vm.expectRevert(abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_LegacyPikMismatch.selector, id));
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(_financialState(), beforeState);
        vm.clearMockedCalls();
    }

    function test_unwiredLegacyEngineRefusesRatherThanDroppingInterest() public {
        vm.warp(firstDue);
        vm.prank(admin);
        defaultManager.setWaterfall(address(0));
        _attestDefault(id);
        bytes32 beforeState = _financialState();
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_LegacyWaterfallUnavailable.selector);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(_financialState(), beforeState);
    }
}

/// @notice Preparation progresses even when one default transaction cannot fit the entire backlog.
contract LegacyPikDefaultBatchTest is LegacyPikDefaultTest {
    function _fixturePaymentInterval() internal pure override returns (uint64) {
        return 7 days;
    }

    function test_longMarkedBacklogProgressesInBoundedBatchesBeforeDeclaration() public {
        _markWithBlockedPosting();
        vm.warp(uint256(firstDue) + 39 * bridge.facility(id).paymentInterval);
        _attestDefault(id);
        bytes32 beforeState = _financialState();
        uint64 remaining = firstDue + 16 * bridge.facility(id).paymentInterval;
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_LegacyPikPending.selector, id, remaining)
        );
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(_financialState(), beforeState, "refused declaration retained a partial batch");
        uint256 revision = defaultManager.impairmentRevision();
        vm.prank(servicer);
        (uint256 processed, uint64 due) = defaultManager.settleLegacyPikForDefault(id, FILM_REF, 16);
        assertEq(processed, 16);
        assertEq(due, remaining);
        (uint256 intermediate,) = _model(16);
        assertEq(defaultManager.pastDueContribution(id), intermediate);
        assertEq(defaultManager.impairmentRevision(), revision + 1, "assessment identity did not change");
        vm.prank(servicer);
        (processed, due) = defaultManager.settleLegacyPikForDefault(id, FILM_REF, 16);
        assertEq(processed, 16);
        assertEq(due, firstDue + 32 * bridge.facility(id).paymentInterval);
        (intermediate,) = _model(32);
        assertEq(defaultManager.pastDueContribution(id), intermediate);
        assertEq(defaultManager.impairmentRevision(), revision + 2);
        _declare();
        (uint256 expected,) = _model(40);
        _assertDefault(expected);
    }
}
