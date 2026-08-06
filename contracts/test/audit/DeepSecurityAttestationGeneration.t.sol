// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @notice Local defensive proofs for lifecycle records that lack a signed generation.
/// @dev Every record below enters through the production AttestationOracle with its real
///      EIP-712 domain and the configured two-attester quorum.
contract DeepSecurityAttestationGenerationTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 400_000e18;

    function test_olderUnsubmittedTermsRecordCanRestoreSupersededTerms() public {
        uint256 id = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS,
            BORROWER_1,
            STATE_GA,
            PRINCIPAL,
            FILM_LTV_BPS,
            FILM_RATE_BPS,
            uint64(block.timestamp + 600 days),
            FILM_REF
        );
        terms.renewable = true;
        terms.renewalTermsHash = keccak256("initial-renewal");

        _setSatisfied(id, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        _setSatisfied(id, IAttestationOracle.AttestationKind.UCCFiled, true);
        _attestCreditTerms(id, bridge.creditTermsHash(terms));
        vm.prank(originator);
        id = bridge.originate(custodian, terms);
        vm.prank(address(waterfall));
        bridge.transitionState(id, ClaimBridge.LoanState.Active);

        uint64 signedAt = uint64(block.timestamp);
        ClaimBridge.Amendment memory older = _amendment(
            1_200,
            uint64(block.timestamp + 500 days),
            uint64(block.timestamp + 40 days),
            keccak256("older-schedule"),
            keccak256("older-renewal")
        );
        bytes32 olderId = keccak256("older-amendment");
        (IAttestationOracle.AttestationInput memory olderInput, bytes[] memory olderSigs) = _prepareRecord(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(olderId, id, older)),
            signedAt,
            uint64(block.timestamp + 90 days)
        );

        vm.warp(block.timestamp + 1 days);
        ClaimBridge.Amendment memory newer = _amendment(
            1_800,
            uint64(signedAt + 650 days),
            uint64(signedAt + 50 days),
            keccak256("newer-schedule"),
            keccak256("newer-renewal")
        );
        bytes32 newerId = keccak256("newer-amendment");
        _attest(
            id,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(newerId, id, newer)),
            uint64(block.timestamp)
        );
        vm.prank(originator);
        bridge.amendTerms(id, newerId, newer);
        assertEq(bridge.facility(id).interestRateBps, 1_800);

        // The genuinely signed older bundle was never submitted before. The oracle accepts
        // its lower asOf after the newer amendment because only Valuation has a watermark.
        realOracle.attest(olderInput, olderSigs);
        vm.prank(originator);
        bridge.amendTerms(id, olderId, older);

        ClaimBridge.Facility memory rolledBack = bridge.facility(id);
        assertEq(rolledBack.interestRateBps, 1_200);
        assertEq(rolledBack.maturity, older.maturity);
        assertEq(rolledBack.paymentScheduleHash, older.paymentScheduleHash);
    }

    function test_olderUnsubmittedCureRecordCanClearALaterPastDueCycle() public {
        uint256 id = _liveFilmFacility(PRINCIPAL);
        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + uint256(defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS)) + 1);
        defaultManager.markPastDue(id);

        bytes32 olderEvidence = keccak256("cycle-one-unused-cure");
        (IAttestationOracle.AttestationInput memory olderInput, bytes[] memory olderSigs) = _prepareRecord(
            id,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(id, olderEvidence)),
            uint64(block.timestamp),
            uint64(block.timestamp + 30 days)
        );

        // Clear cycle one with a different, newer cure record. The older signed record
        // remains unused and therefore is not stopped by digest replay protection.
        vm.warp(block.timestamp + 1);
        bytes32 currentEvidence = keccak256("cycle-one-current-cure");
        _attestPastDueCure(id, currentEvidence);
        vm.prank(servicer);
        defaultManager.clearPastDue(id, currentEvidence);
        assertEq(defaultManager.pastDueContribution(id), 0);

        // The unchanged overdue clock permits a new mark. The old record is then accepted
        // and clears this distinct lifecycle generation.
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueContribution(id), PRINCIPAL);
        realOracle.attest(olderInput, olderSigs);
        vm.prank(servicer);
        defaultManager.clearPastDue(id, olderEvidence);
        assertEq(defaultManager.pastDueContribution(id), 0);
    }

    function _prepareRecord(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        uint64 asOf,
        uint64 expiry
    ) private returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: expiry,
            nonce: ++nonceCounter
        });
        sigs = _signedBundle(a);
    }

    function _amendment(
        uint16 interestRateBps,
        uint64 maturity,
        uint64 nextPaymentDue,
        bytes32 paymentScheduleHash,
        bytes32 renewalTermsHash
    ) private pure returns (ClaimBridge.Amendment memory a) {
        a = ClaimBridge.Amendment({
            interestRateBps: interestRateBps,
            maturity: maturity,
            paymentInterval: 30 days,
            nextPaymentDue: nextPaymentDue,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: true,
            paymentScheduleHash: paymentScheduleHash,
            rateIndexRef: bytes32(0),
            renewalTermsHash: renewalTermsHash
        });
    }
}
