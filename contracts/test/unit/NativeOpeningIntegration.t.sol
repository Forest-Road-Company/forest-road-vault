// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {NativeAccrualCoverageFunding} from "../helpers/NativeAccrualFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {IAccrualMigration} from "../../src/interfaces/IAccrualMigration.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {ReserveMigrationLib} from "../../src/libraries/ReserveMigrationLib.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ICommitmentLedger} from "../../src/interfaces/ICommitmentLedger.sol";
import {CommitmentLedger} from "../../src/CommitmentLedger.sol";

abstract contract NativeOpeningIntegrationChecks is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function test_openingPostsNativeFaceAndBothFeesBeforeReceipts() public {
        _legacyFund(50_000e18);
        uint256 shares = vault.totalSupply();
        uint256 protocolBefore = usdfr.balanceOf(feeRecipient);
        uint256 rate = vault.currentExchangeRate();
        _prepareOne(nativeStart + 45 days);
        uint256 income = nativeReference.earned;
        assertEq(reserves.deployedTo(nativeId), 50_000e18 + income, "opening omitted native income");
        assertEq(registry.totalBookExposure(), 50_000e18 + income, "opening omitted registry income");
        IAccrualMigration.Progress memory p = reserves.accrualMigration();
        assertEq(p.expected, 1);
        assertEq(p.imported, 1);
        assertEq(p.originalFace, 50_000e18);
        assertEq(p.importedOriginalFace, p.originalFace);
        assertEq(p.nextFacilityId, 0);
        assertTrue(p.active);
        (,, bool satisfied) = realOracle.latestPayload(nativeId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertFalse(satisfied, "opening fact was not consumed");
        _enableOpening();
        IContinuousAccrual.Snapshot memory snapshot = reserves.accrualSnapshot();
        assertEq(snapshot.gross, income, "opening income recorded twice or omitted");
        assertEq(snapshot.unposted, 0, "native opening still virtual");
        assertEq(snapshot.unissued, income, "opening moved or lost physical claims");
        assertEq(snapshot.feeUnissued, income / 10, "opening protocol fee");
        uint256 senior = income - income / 10;
        assertEq(vault.totalAssets(), SENIOR_CAPITAL + senior);
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, income / 10, "opening protocol fee delivery");
        uint256 performanceAssets = senior / 10;
        uint256 virtualShares = 10 ** (vault.decimals() - usdfr.decimals());
        uint256 expected =
            performanceAssets * (shares + virtualShares) / (SENIOR_CAPITAL + senior + 1 - performanceAssets);
        (uint256 management, uint256 performance) = vault.accrueFees();
        assertEq(management, 0);
        assertEq(performance, expected, "opening performance fee");
        assertGt(performance, 0, "performance fee path not reached");
        assertGe(vault.currentExchangeRate(), rate, "opening yield reduced senior rate");
        _assertNativeDebt();
        _assertNativeBacking();
        _nativeAdvance(nativeStart + 90 days);
        _nativePayAll();
        assertEq(reserves.deployedTo(nativeId), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.accrualSnapshot().gross, nativeReference.earned, "receipt recognized interest twice");
    }

    function test_historicalCouponCursorContinuesWithoutResettingRounding() public {
        _legacyFund(50_003e18);
        _prepareOne(nativeStart + 135 days + 123);
        _enableOpening();
        _assertNativeDebt();
        _nativeAdvance(nativeStart + 150 days + 37);
        _nativeReceipt(10_000e18, 0);
        _nativeAdvance(nativeStart + 165 days + 83);
        _nativeAmendRate(1733);
        _nativeAdvance(nativeStart + 365 days);
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0, "migrated history left registry exposure");
    }

    function test_delayedActivationUsesKeeperAndRefusesStaleFinancialEntry() public {
        _legacyFund(50_000e18);
        _prepareOne(nativeStart + 45 days);
        uint64 later = nativeStart + (_pikFacilities() ? uint64(200 days) : uint64(400 days));
        vm.warp(later);
        _enableOpening();
        assertFalse(reserves.accrualSnapshot().fresh, "delayed fixture did not need maintenance");
        vm.expectRevert();
        reserves.requireAccrualFresh();
        uint256 shares = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1e18, alice);
        assertEq(vault.totalSupply(), shares, "stale deposit changed supply");
        _nativeAdvance(later);
        assertTrue(reserves.accrualSnapshot().fresh);
        _nativePayAll();
    }

    function test_declaredOpeningPreservesRiskAndStopsIncomeBeforeCascade() public {
        _legacyFund(50_000e18);
        vm.warp(nativeStart + 45 days);
        AccrualDebtReference.Note memory n = nativeReference;
        n.stop(uint64(block.timestamp));
        nativeReference = n;
        _attestDefault(nativeId);
        vm.prank(servicer);
        defaultManager.declareDefault(nativeId, FILM_REF);
        uint256 revision = defaultManager.impairmentRevision();
        _prepareOne(nativeStart + 135 days);
        uint256 face = n.principal + n.interest;
        assertEq(defaultManager.defaultedContribution(nativeId), face, "declared opening contribution");
        assertEq(
            defaultManager.declaredDefaultedPrincipal(Config.CLASS_FILM_TAX_CREDITS),
            face,
            "declared opening class total"
        );
        assertEq(defaultManager.impairmentRevision(), revision + 1, "opening did not stale the risk assessment");
        {
            (,,,,,,, address ledger) = defaultManager.modules();
            (, uint256 ledgerFace,) = ICommitmentLedger(ledger).state(nativeId);
            assertEq(ledgerFace, face, "opening omitted the declared ledger row");
            assertEq(CommitmentLedger(ledger).remainingPrincipalForClass(Config.CLASS_FILM_TAX_CREDITS),
                face, "opening omitted the constant-time class aggregate");
        }
        _enableOpening();
        uint256 junior = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        if (_nativeBackstop() != address(0)) {
            junior += NativeAccrualCoverageFunding(_nativeBackstop()).coverageReserve();
        }
        uint256 residual = face > junior ? face - junior : 0;
        assertGt(residual, 0, "declared opening did not reach senior risk");
        assertEq(defaultManager.pendingSeniorImpairment(), residual, "opening omitted ledger risk before loss");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets() - residual, "opening redemption mark");
        uint256 income = reserves.accrualSnapshot().gross;
        _nativeAdvance(nativeStart + 220 days);
        assertEq(reserves.accrualSnapshot().gross, income, "declared opening resumed earning");
        _nativeLoss(12_000e18);
        _nativeLoss(nativeReference.principal + nativeReference.interest);
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
        assertEq(defaultManager.defaultedContribution(nativeId), 0);
    }

    function test_maturedOpeningHasNoFurtherIncomeOrInventedCapitalization() public {
        _legacyFund(50_000e18);
        _prepareOne(nativeStart + 400 days);
        _enableOpening();
        uint256 income = reserves.accrualSnapshot().gross;
        _nativeAdvance(nativeStart + 800 days);
        assertEq(reserves.accrualSnapshot().gross, income, "matured opening kept earning");
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0);
    }

    function test_zeroIncomeOpeningDoesNotChargeLegacyPrincipal() public {
        _legacyFund(50_000e18);
        _prepareOne(nativeStart);
        uint256 revision = defaultManager.impairmentRevision();
        _enableOpening();
        assertEq(reserves.accrualSnapshot().gross, 0, "legacy principal was charged as income");
        assertEq(vault.totalAssets(), SENIOR_CAPITAL);
        assertEq(defaultManager.impairmentRevision(), revision);
        _nativeAdvance(nativeStart + 91 days);
        _nativePayAll();
    }

    function testFuzz_migratedDebtMatchesReferenceThroughMaturity(uint64 principalSeed, uint32 atSeed) public {
        _legacyFund((uint256(principalSeed) % 40_000 + 10_000) * 1e18);
        uint64 at = nativeStart + uint64(uint256(atSeed) % 350 days);
        _prepareOne(at);
        _enableOpening();
        _assertNativeDebt();
        _nativeAdvance(nativeStart + 365 days);
        _nativePayAll();
        assertEq(reserves.accrualSnapshot().gross, nativeReference.earned, "migration changed earned income");
    }

    function test_openingRiskCallbackRequiresTheBoundPreparingReserve() public {
        _legacyFund(50_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, address(this))
        );
        defaultManager.onAccrualOpening(nativeId, 1e18);
        _bindOpeningConsumers();
        vm.prank(address(reserves));
        vm.expectRevert(DefaultAccrualLib.DefaultAccrual_OperationInProgress.selector);
        defaultManager.onAccrualOpening(nativeId, 1e18);
        _beginOne();
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_CallerNotReserve.selector, address(this))
        );
        defaultManager.onAccrualOpening(nativeId, 1e18);
    }
}

contract NativeOpeningCashIntegrationTest is NativeOpeningIntegrationChecks {
    function test_pastDueOpeningUpdatesRiskAndCurePreservesEarning() public {
        _legacyFund(50_000e18);
        vm.warp(nativeStart + 120 days);
        defaultManager.markPastDue(nativeId);
        uint256 revision = defaultManager.impairmentRevision();
        _prepareOne(uint64(block.timestamp));
        uint256 face = nativeReference.principal + nativeReference.interest;
        assertEq(defaultManager.pastDueContribution(nativeId), face);
        assertEq(defaultManager.pastDuePrincipal(Config.CLASS_FILM_TAX_CREDITS), face);
        assertEq(defaultManager.pastDueExposure(), face);
        assertEq(defaultManager.impairmentRevision(), revision + 1);
        _enableOpening();
        _nativeAdvance(nativeStart + 135 days);
        assertEq(
            defaultManager.pastDueContribution(nativeId),
            reserves.deployedTo(nativeId),
            "marked migrated income escaped risk"
        );
        _clearPastDue(nativeId, keccak256("opening-past-due-cure"));
        assertEq(defaultManager.pastDueContribution(nativeId), 0);
        _nativeAdvance(nativeStart + 150 days);
        _nativePayAll();
    }
}

contract NativeOpeningPikIntegrationTest is NativeOpeningIntegrationChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function test_legacyCapitalizedIncomeIsNotChargedAgain() public {
        _legacyFund(50_000e18);
        vm.warp(nativeStart + 90 days);
        waterfall.capitalizePik(nativeId);
        uint256 legacyFace = reserves.deployedTo(nativeId);
        assertGt(legacyFace, 50_000e18, "legacy capitalization not reached");
        _prepareOne(nativeStart + 135 days);
        _enableOpening();
        assertEq(
            reserves.accrualSnapshot().gross,
            nativeReference.principal + nativeReference.interest - legacyFace,
            "legacy recognized PIK was charged twice"
        );
        _nativeAdvance(nativeStart + 180 days);
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0);
    }
}
