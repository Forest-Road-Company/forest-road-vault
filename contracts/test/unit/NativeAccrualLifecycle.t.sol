// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {Config} from "../../src/libraries/Config.sol";

abstract contract NativeAccrualLifecycleChecks is NativeAccrualFixture {
    function test_twoDefaultsConsumeSharedJuniorCapitalOnlyOnce() public {
        _nativeFund(50_000e18);
        uint256 firstId = nativeId;
        AccrualDebtReference.Note memory first = nativeReference;
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, CURATOR_CAPITAL);
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 90 days);
        AccrualDebtReference.advance(first, uint64(block.timestamp));
        _nativeDeclare();
        _nativeLoss(30_000e18);
        uint256 secondId = nativeId;
        AccrualDebtReference.Note memory second = nativeReference;
        nativeId = firstId;
        nativeReference = first;
        nativeWrittenOff = 0;
        _nativeDeclare();
        _nativeLoss(nativeReference.principal + nativeReference.interest);
        nativeId = secondId;
        nativeReference = second;
        nativeWrittenOff = 30_000e18;
        _nativeLoss(nativeReference.principal + nativeReference.interest);
        assertEq(registry.totalBookExposure(), 0, "two resolved facilities left exposure");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "two resolved facilities left impairment");
    }

    function testFuzz_nativeReceiptOrDefaultReconcilesIndependentDebt(
        uint64 principalSeed,
        uint32 timeSeed,
        bool declared
    ) public {
        uint256 principal = (uint256(principalSeed) % 50_000 + 1) * 1e18;
        _nativeFund(principal);
        _nativeAdvance(nativeStart + uint64(uint256(timeSeed) % 350 days + 1));
        if (declared) {
            _nativeDeclare();
            uint256 gross = reserves.accrualSnapshot().gross;
            _nativeAdvance(uint64(block.timestamp + 45 days));
            assertEq(reserves.accrualSnapshot().gross, gross, "default resumed earning");
            _nativeLoss(nativeReference.principal + nativeReference.interest);
        } else {
            _nativePayAll();
        }
        uint256 finalGross = reserves.accrualSnapshot().gross;
        assertGe(finalGross, nativeReference.earned, "contractual income disappeared at closure");
        assertLt(finalGross - nativeReference.earned, _nativeScale(), "closure left unaccounted book drift");
        assertEq(reserves.deployedTo(nativeId), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(defaultManager.pendingSeniorImpairment(), 0);
    }

    function test_overpaymentRevertsWithoutConsumingTheSignedReceiptOrChangingAccounting() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 30 days);
        uint256 amount = nativeReference.principal + nativeReference.interest + _nativeScale();
        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: nativeId,
            paymentId: keccak256("native-overpayment-must-revert"),
            payer: borrower,
            interest: 0,
            principal: amount,
            nextPaymentDue: 0
        });
        _submitNativeReceipt(payment, amount / _nativeScale());
        bytes32 before_ = _receiptState();
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        vm.prank(servicer);
        waterfall.distribute(payment);
        assertEq(_receiptState(), before_, "refused receipt changed native accounting");
        (,, bool valid) = realOracle.latestPayload(nativeId, IAttestationOracle.AttestationKind.PaymentReceived);
        assertTrue(valid, "refused receipt consumed its attestation");
    }

    function _receiptState() private view returns (bytes32) {
        uint256[6] memory amounts = [
            controller.totalUSDfr(),
            registry.totalBookExposure(),
            vault.totalAssets(),
            vault.totalSupply(),
            IERC20(_nativeAsset()).balanceOf(borrower),
            usdfr.balanceOf(feeRecipient)
        ];
        return keccak256(abi.encode(reserves.accruedDebt(nativeId), reserves.accrualSnapshot(), amounts));
    }

    function test_bothFeesCrystallizeBeforeAnyInterestReceipt() public {
        _nativeFund(50_000e18);
        uint256 protocolBefore = usdfr.balanceOf(feeRecipient);
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        uint256 sharesBefore = vault.totalSupply();
        uint256 rateBefore = vault.currentExchangeRate();
        _nativeAdvance(nativeStart + 90 days);
        IContinuousAccrual.Snapshot memory claims = reserves.accrualSnapshot();
        uint256 protocolFee = claims.gross / 10;
        uint256 seniorIncome = claims.gross - protocolFee;
        assertGt(claims.gross, 0, "income not reached");
        assertEq(
            usdfr.balanceOf(feeRecipient) + claims.feeUnissued - protocolBefore,
            protocolFee,
            "protocol fee on unreceived income"
        );
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, protocolFee, "earned protocol fee delivery");
        assertEq(reserves.accrualSnapshot().feeUnissued, 0, "delivered fee still virtual");
        assertEq(vault.totalAssets(), SENIOR_CAPITAL + seniorIncome, "senior received wrong income leg");
        uint256 performanceAssets = seniorIncome / 10;
        uint256 virtualShares = 10 ** (vault.decimals() - usdfr.decimals());
        uint256 expectedFeeShares =
            performanceAssets * (sharesBefore + virtualShares) / (SENIOR_CAPITAL + seniorIncome + 1 - performanceAssets);
        (uint256 management, uint256 performance) = vault.accrueFees();
        assertEq(management, 0, "fixture management fee");
        assertEq(performance, expectedFeeShares, "performance fee on unreceived income");
        assertEq(vault.balanceOf(vault.feeRecipient()) - feeSharesBefore, expectedFeeShares, "fee shares not delivered");
        assertGt(expectedFeeShares, 0, "performance fee not reached");
        assertGe(vault.currentExchangeRate(), rateBefore, "yield alone reduced senior exchange rate");
        assertEq(nativeReference.paid, 0, "test already received interest");
        _assertNativeBacking();
    }

    function test_materializationAndReceiptDoNotRecognizeIncomeTwice() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 90 days);
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 rawSupplyBefore = usdfr.totalSupply();
        uint256 unissuedBefore = reserves.accrualSnapshot().unissued;
        uint256 assetsBefore = vault.totalAssets();
        uint256 rateBefore = vault.currentExchangeRate();
        reserves.materializeAccrued(3);
        assertEq(reserves.totalBackingValue(), backingBefore, "delivery changed backing");
        assertEq(controller.totalUSDfr(), supplyBefore, "delivery minted a second entitlement");
        assertEq(usdfr.totalSupply(), rawSupplyBefore + unissuedBefore, "physical delivery did not match claims");
        assertEq(reserves.accrualSnapshot().unissued, 0, "physical delivery left virtual claims");
        assertEq(vault.totalAssets(), assetsBefore, "delivery changed senior income");
        assertEq(vault.currentExchangeRate(), rateBefore, "delivery changed price");
        _nativePayAll();
        assertEq(uint256(bridge.facility(nativeId).state), uint256(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(nativeId), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.accrualSnapshot().gross, nativeReference.earned, "final receipt exceeded contractual income");
        assertEq(
            vault.totalAssets(),
            SENIOR_CAPITAL + nativeReference.earned - nativeReference.earned / 10,
            "final senior income after contractual reconciliation"
        );
        assertEq(nativeReference.principal + nativeReference.interest, 0);
    }

    function test_defaultPostsAllIncomeAndStopsBeforeOrderedLosses() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 90 days);
        _nativeDeclare();
        uint256 stoppedIncome = reserves.accrualSnapshot().gross;
        _nativeAdvance(nativeStart + 180 days);
        assertEq(reserves.accrualSnapshot().gross, stoppedIncome, "defaulted loan kept earning");
        _nativeLoss(30_000e18);
        _nativeLoss(nativeReference.principal + nativeReference.interest);
        assertEq(uint256(bridge.facility(nativeId).state), uint256(ClaimBridge.LoanState.Resolved));
        assertEq(reserves.deployedTo(nativeId), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "resolved debt still impaired senior NAV");
    }

    function test_paymentAndAmendmentPreserveIndependentFrozenBasis() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 30 days);
        _nativeReceipt(12_500e18, 0);
        _nativeAdvance(nativeStart + 45 days);
        _nativeAmendRate(2000);
        _nativeAdvance(nativeStart + 90 days);
        _nativePayAll();
        assertEq(registry.totalBookExposure(), 0, "amended and repaid exposure did not clear");
    }

    function test_maturityStopsIncomeWithoutInventingAStubCapitalization() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 365 days);
        uint256 principal = nativeReference.principal;
        uint256 income = reserves.accrualSnapshot().gross;
        _nativeAdvance(nativeStart + 730 days);
        assertEq(nativeReference.principal, principal, "maturity stub compounded");
        assertEq(reserves.accrualSnapshot().gross, income, "post-maturity income");
        _nativePayAll();
    }
}

contract NativeAccrualCashLifecycleTest is NativeAccrualLifecycleChecks {
    function test_pastDueMarkAndCureCheckpointWithoutStoppingEarnedCash() public {
        _nativeFund(50_000e18);
        _nativeAdvance(nativeStart + 120 days);
        defaultManager.markPastDue(nativeId);
        uint256 gross = reserves.accrualSnapshot().gross;
        _nativeAdvance(nativeStart + 150 days);
        assertGt(reserves.accrualSnapshot().gross, gross, "past due stopped earning");
        assertEq(
            defaultManager.pastDueContribution(nativeId), reserves.deployedTo(nativeId), "marked interest cohort drift"
        );
        assertEq(
            defaultManager.pastDuePrincipal(Config.CLASS_FILM_TAX_CREDITS),
            reserves.deployedTo(nativeId),
            "unposted earned interest escaped the marked cohort"
        );
        _clearPastDue(nativeId, keccak256("native-accrual-cure"));
        assertEq(defaultManager.pastDueContribution(nativeId), 0, "cure left marked interest");
        _nativeAdvance(nativeStart + 160 days);
        _nativePayAll();
    }
}

contract NativeAccrualPikLifecycleTest is NativeAccrualLifecycleChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
