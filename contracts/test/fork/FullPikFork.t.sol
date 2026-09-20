// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Full signed PIK debt survives origination, renewal and repayment using real reserve tokens.
contract FullPikForkTest is ForkLifecycleFixture {
    function test_fork_fullPikRenewalAndRepayment() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        _stake(alice, 600_000e18);
        uint64 start = uint64(block.timestamp);
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            Config.CLASS_FILM_TAX_CREDITS,
            keccak256("full-pik-borrower"),
            keccak256("US-GA"),
            100_000e18,
            7500,
            10_000,
            start + 360 days,
            keccak256("full-pik-note")
        );
        t.pik = true;
        t.paymentInterval = 90 days;
        t.nextPaymentDue = start + 90 days;
        t.renewable = true;
        t.renewalTermsHash = keccak256("signed-renewal-terms");
        uint256 id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        assertEq(bridge.originate(ops, t), id);
        waterfall.fund(id, 100_000e6);
        _warp(180 days);
        (, bool fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh);
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps,
            maturity: start + 540 days,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: f.paymentScheduleHash,
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendmentId = keccak256("full-pik-renewal");
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendmentId, id, a)));
        bridge.amendTerms(id, amendmentId, a);
        _warp(360 days);
        (, fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh);
        reserves.serviceAccruedLoan(id);
        uint256 expected = t.principal;
        for (uint256 i; i < 6; ++i) {
            expected += expected / 4 / 1e12 * 1e12;
        }
        assertGt(expected, 3 * t.principal);
        assertEq(reserves.deployedTo(id), expected);
        assertEq(registry.totalBookExposure(), expected);
        assertEq(reserves.accrualSnapshot().gross, expected - t.principal);
        uint256 grossBefore = reserves.accrualSnapshot().gross;
        _repay(id, 0, expected);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.accrualSnapshot().gross, grossBefore, "receipt cannot earn the income again");
        assertTrue(bridge.facility(id).state == ClaimBridge.LoanState.Repaid);
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue());
        emit log_named_uint("full signed face repaid on pinned fork", expected);
    }
}
