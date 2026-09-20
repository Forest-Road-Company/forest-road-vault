// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

contract FullPikAccrualTest is NativeAccrualFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function _issue(uint16 rate, uint64 duration) private returns (uint256 id) {
        ClaimBridge.OriginationTerms memory t = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS,
            BORROWER_1,
            STATE_GA,
            100_000e18,
            FILM_LTV_BPS,
            rate,
            uint64(block.timestamp) + duration,
            FILM_REF
        );
        t.pik = true;
        bytes32 h = bridge.creditTermsHash(t);
        _attest(1, IAttestationOracle.AttestationKind.CreditIssued, h, uint64(block.timestamp));
        _attest(1, IAttestationOracle.AttestationKind.AssignmentExecuted, h, uint64(block.timestamp));
        _attest(1, IAttestationOracle.AttestationKind.UCCFiled, h, uint64(block.timestamp));
        vm.prank(originator);
        id = bridge.originate(custodian, t);
        _fundFacility(id, t.principal);
    }

    function _uncapped(uint256 principal, uint16 rate, uint256 duration) private view returns (uint256 face) {
        face = principal;
        while (duration != 0) {
            uint256 period = duration < 90 days ? duration : 90 days;
            face += face * rate * period / (10_000 * 360 days) / _nativeScale() * _nativeScale();
            duration -= period;
        }
    }

    function _finish(uint256 id) private returns (uint256 face) {
        vm.warp(bridge.facility(id).maturity);
        (, bool fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh, "all contractual periods processed");
        reserves.serviceAccruedLoan(id);
        face = reserves.deployedTo(id);
    }

    function test_fullSignedPikInterestAndBothFeesAreRecognized() public {
        uint256 id = _issue(6000, uint64(730 days));
        uint256 expected = _uncapped(100_000e18, 6000, 730 days);
        uint256 recorded = _finish(id);
        assertEq(recorded, expected);
        assertGt(recorded, 300_000e18);
        uint256 income = expected - 100_000e18;
        assertEq(reserves.accrualSnapshot().gross, income);
        assertEq(reserves.accrualSnapshot().feeUnissued, income / 10);
        assertEq(vault.totalAssets(), SENIOR_CAPITAL + income - income / 10);
        uint256 protocolBefore = usdfr.balanceOf(feeRecipient);
        reserves.materializeAccrued(2);
        assertEq(usdfr.balanceOf(feeRecipient) - protocolBefore, income / 10);
        (uint256 management, uint256 performance) = vault.accrueFees();
        assertEq(management, 0);
        assertGt(performance, 0, "PIK must pay the performance fee as well");
        assertEq(registry.totalBookExposure(), expected);
        _assertNativeBacking();
        emit log_named_uint("uncapped signed-term face", expected);
        emit log_named_uint("recorded face", recorded);
        emit log_named_uint("omitted interest", expected - recorded);
    }

    function test_signedRateIncreaseRecomputesFullPikCapacity() public {
        uint256 id = _issue(1400, uint64(730 days));
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: 6000,
            maturity: nativeStart + uint64(730 days),
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendment = keccak256("signed-rate-increase");
        _attest(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendment, id, a)),
            uint64(block.timestamp)
        );
        vm.prank(originator);
        bridge.amendTerms(id, amendment, a);
        assertEq(bridge.facility(id).maturity, a.maturity);
        uint256 recorded = _finish(id);
        assertEq(recorded, _uncapped(100_000e18, 6000, 730 days));
        assertGt(recorded, 300_000e18);
    }

    function testFuzz_allAcceptedFixedPikTermsAccrueInFull(uint16 rawRate, uint16 rawDays) public {
        uint16 rate = uint16(bound(rawRate, 1, 10_000));
        uint64 duration = uint64(bound(rawDays, 365, 730) * 1 days);
        uint256 id = _issue(rate, duration);
        assertEq(_finish(id), _uncapped(100_000e18, rate, duration));
    }

    function _modelIssue(uint16 rate) private {
        nativeId = _issue(rate, uint64(730 days));
        AccrualDebtReference.Note memory n;
        n.principal = 100_000e18;
        n.ceiling = type(uint256).max / 10_000;
        n.scale = _nativeScale();
        n.year = 360 days;
        n.rate = rate;
        n.interval = 90 days;
        n.due = nativeStart + n.interval;
        n.maturity = nativeStart + 730 days;
        n.pik = true;
        n.open(nativeStart);
        nativeReference = n;
    }

    function test_defaultAboveFormerCapStopsFullInterestAndPreservesCascade() public {
        _modelIssue(6000);
        _nativeAdvance(nativeStart + 725 days);
        uint256 before_ = nativeReference.principal + nativeReference.interest;
        assertGt(before_, 300_000e18);
        _nativeDeclare();
        _nativeLoss(16_000e18);
        _nativeAdvance(nativeStart + 800 days);
        assertEq(reserves.deployedTo(nativeId), before_ - 16_000e18);
    }

    function test_repaymentBeforeAmendmentPreservesFrozenPikBasis() public {
        _modelIssue(6000);
        _nativeAdvance(nativeStart + 15 days);
        _nativeReceipt(90_000e18, 0);
        _nativeAmendRate(10_000);
        _nativeAdvance(nativeStart + 90 days);
        _nativeAdvance(nativeStart + 730 days);
        _nativePayAll();
        assertEq(reserves.deployedTo(nativeId), 0);
        assertEq(registry.totalBookExposure(), 0);
    }

    function testFuzz_eventHistoryPreservesFullDebtAndOrderedCorrection(uint256 seed) public {
        _modelIssue(10_000);
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _nativeAdvance(uint64(block.timestamp) + uint64(1 days + seed % (15 days)));
            if (seed % 3 == 0) {
                uint256 paid = nativeReference.principal / 20 / _nativeScale() * _nativeScale();
                if (paid != 0) _nativeReceipt(paid, 0);
            } else if (seed % 3 == 1) {
                _nativeAmendRate(uint16(1 + seed % 10_000));
            }
            assertGe(
                reserves.accruedDebt(nativeId).balanceCeiling, nativeReference.principal + nativeReference.interest
            );
        }
        _nativeAdvance(nativeStart + 725 days);
        if (seed & 1 == 0) {
            _nativeDeclare();
            _nativeLoss(16_000e18);
            _nativeAdvance(nativeStart + 800 days);
        } else {
            _nativeAdvance(nativeStart + 730 days);
            _nativePayAll();
            assertEq(registry.totalBookExposure(), 0);
        }
    }
}
