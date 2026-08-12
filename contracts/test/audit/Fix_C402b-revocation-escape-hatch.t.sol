// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @title R17-03 — the C4-02 tombstone's escape hatch, verified rather than asserted
/// @notice THE CLAIM UNDER TEST. `AttestationOracle.revoke` documented its permanent tombstone
///         with an escape hatch: "If a fact must genuinely be re-established after revocation, the
///         attesters sign a NEW fact — a new evidence hash — which is the honest record of a new
///         attester decision."
///
///         THAT CLAIM IS ONLY TRUE FOR PART OF THE SURFACE, and the part where it is false is the
///         mint gate — the highest-value gate in the protocol. Re-establishment works exactly when
///         the consumer lets the attesters vary something inside the payload:
///           - DefaultDeclared / LossRealized / PastDueCured — free `evidenceHash`;
///           - PaymentReceived — free `paymentId`;
///           - TermsAmended — free `amendmentId`;
///           - the documentary kinds — `ClaimBridge` gates on `isSatisfied` only, never on content.
///         It does NOT work for `CreditIssued`. The H-4 terms binding makes
///         `ClaimBridge._requireTermsAttested` demand payload == `creditTermsHash(terms)` EXACTLY,
///         and that hash is a pure function of the signed terms. There is no evidence hash, no
///         nonce, nothing free. Once governance revokes it, that (facilityId, CreditIssued,
///         termsHash) triple is dead for ever, and no quantity of new attester decisions can
///         re-establish it: every honest re-signing produces the identical payload.
///
///         CONSEQUENCE, which is why this is worth a regression file rather than a comment edit: a
///         PENDING facility whose CreditIssued is revoked can never be funded, and it cannot be
///         repaired by amendment either — `amendTerms` requires Active/Amortizing, and a Pending
///         facility is neither. An operator following the old comment would re-sign the same terms,
///         watch it revert, and be left holding a facility that still consumes class / borrower /
///         state concentration headroom.
///
///         THE ACTUAL REMEDY, pinned below so the corrected comment is executable rather than
///         aspirational: `ClaimBridge.cancelPending` (M-02) reverses the recorded exposure and
///         burns the position, after which the identical terms re-originate cleanly at a FRESH
///         facility id — a different id is a different fact key. The tombstone is not lifted; it is
///         side-stepped honestly, with the dead facility retired on-chain.
contract FixC402bEscapeHatchTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 1_000_000e18;
    uint256 internal constant LOSS = 200_000e18;

    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    // ── the half of the claim that IS true ───────────────────────────────

    /// @notice EVIDENCE-KEYED KINDS: the documented escape hatch works exactly as written. A loss
    ///         attestation is revoked, the attesters re-decide and sign the SAME economic loss
    ///         against NEW evidence, and the write-down proceeds. The revoked fact stays dead.
    function test_r1703_evidenceKeyedFactCanBeReEstablishedAfterRevocation() public {
        _seedSeniors(2_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        bytes32 badEvidence = keccak256("r17-03-evidence-withdrawn");
        _attestLoss(id, LOSS, badEvidence);
        vm.prank(admin);
        realOracle.revoke(id, IAttestationOracle.AttestationKind.LossRealized);
        assertEq(
            uint256(
                realOracle.factStatus(
                    id, IAttestationOracle.AttestationKind.LossRealized, keccak256(abi.encode(id, LOSS, badEvidence))
                )
            ),
            uint256(IAttestationOracle.FactStatus.Revoked),
            "precondition: the tombstone stands"
        );

        // THE ESCAPE HATCH: a NEW attester decision, recorded under NEW evidence.
        uint256 outstandingBefore = reserves.deployedTo(id);
        bytes32 freshEvidence = keccak256("r17-03-evidence-re-established");
        _realizeLoss(id, LOSS, freshEvidence);
        assertEq(reserves.deployedTo(id), outstandingBefore - LOSS, "the re-established loss must land");

        // and the revoked fact is still dead — the hatch re-establishes, it does not un-revoke
        bytes32 deadPayload = keccak256(abi.encode(id, LOSS, badEvidence));
        bytes32 key = realOracle.factKey(id, IAttestationOracle.AttestationKind.LossRealized, deadPayload);
        IAttestationOracle.AttestationInput memory replay = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.LossRealized,
            payload: deadPayload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0x1703
        });
        bytes[] memory sigs = _signedBundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector, key, IAttestationOracle.FactStatus.Revoked
            )
        );
        realOracle.attest(replay, sigs);
    }

    // ── the half of the claim that is FALSE ──────────────────────────────

    /// @notice CREDIT-ISSUED: the documented escape hatch DOES NOT EXIST. The payload is the terms
    ///         commitment, so the attesters have nothing to vary. Re-signing the identical terms —
    ///         which is the only honest thing they can sign — is refused by the tombstone, and the
    ///         PENDING facility is left unfundable and unamendable.
    /// @dev This test is the verification of the finding. It asserts the DEFECT (no re-attestation
    ///      path) deliberately and loudly, so that if someone later gives `CreditIssued` a free
    ///      identity field — a salt, an origination id, a version — this goes red and the corrected
    ///      comment in `AttestationOracle.revoke` must be revisited in the same change.
    function test_r1703_creditIssuedHasNoReAttestationPathAfterRevocation() public {
        _mintUSDfrTo(alice, PRINCIPAL); // idle liquidity so funding could otherwise succeed
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        bytes32 termsHash = bridge.creditTermsHash(
            _facilityTerms(
                Config.CLASS_FILM_TAX_CREDITS,
                BORROWER_1,
                STATE_GA,
                PRINCIPAL,
                FILM_LTV_BPS,
                FILM_RATE_BPS,
                bridge.facility(id).maturity,
                FILM_REF
            )
        );
        (bytes32 attested,,) = realOracle.latestPayload(id, IAttestationOracle.AttestationKind.CreditIssued);
        assertEq(attested, termsHash, "precondition: the mint gate is bound to exactly these terms");

        // governance discovers the CreditIssued quorum was wrong and revokes it
        vm.prank(admin);
        realOracle.revoke(id, IAttestationOracle.AttestationKind.CreditIssued);

        // funding is now refused — the class's required-attestation mask includes CreditIssued, so
        // the mask loop refuses first; the H-4 terms binding immediately behind it has no standing
        // fact to read either.
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.CreditIssued
            )
        );
        bridge.checkFundable(id);

        // THE CLAIMED ESCAPE HATCH, attempted: the attesters re-decide and sign the same terms
        // again, because the terms ARE the fact and there is nothing else they could honestly
        // sign. The tombstone refuses it.
        IAttestationOracle.AttestationInput memory reSign = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.CreditIssued,
            payload: termsHash,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 0x1703C
        });
        bytes[] memory sigs = _signedBundle(reSign);
        assertFalse(realOracle.digestUsed(realOracle.attestationDigest(reSign)), "the re-signing digest IS fresh");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                realOracle.factKey(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        realOracle.attest(reSign, sigs);

        // and the amendment route is closed too: `amendTerms` requires Active/Amortizing, and a
        // facility that cannot be funded can never reach either state.
        assertTrue(bridge.facility(id).state == ClaimBridge.LoanState.Pending, "the facility is stuck Pending");
    }

    /// @notice THE REMEDY THAT ACTUALLY WORKS, so the corrected comment is executable. Retire the
    ///         dead facility with `cancelPending` — which reverses its concentration exposure —
    ///         then re-originate the IDENTICAL terms at a fresh id. The different facility id gives
    ///         the same terms a different fact key, so the tombstone does not follow them.
    function test_r1703_cancelPendingAndReOriginateIsTheWorkingRemedy() public {
        _mintUSDfrTo(alice, 2 * PRINCIPAL);
        uint256 dead = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        uint256 exposureWhilePending = registry.borrowerExposure(BORROWER_1);
        assertEq(exposureWhilePending, PRINCIPAL, "precondition: the dead facility holds real headroom");

        vm.prank(admin);
        realOracle.revoke(dead, IAttestationOracle.AttestationKind.CreditIssued);

        // retire it: exposure is returned and the position burned (M-02)
        vm.prank(originator);
        bridge.cancelPending(dead);
        assertEq(registry.borrowerExposure(BORROWER_1), 0, "cancelPending must return the concentration headroom");
        assertTrue(bridge.facility(dead).state == ClaimBridge.LoanState.Cancelled, "the dead facility is retired");

        // re-originate the SAME terms at a fresh id: same terms hash, different facility, so a
        // different fact key — the tombstone does not follow.
        uint256 fresh = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        assertTrue(fresh != dead, "re-origination must take a fresh id");
        bridge.checkFundable(fresh); // must not revert
        _fundFacility(fresh, PRINCIPAL);
        assertTrue(bridge.facility(fresh).state == ClaimBridge.LoanState.Active, "the replacement facility funds");
    }

    /// @notice P-32 closes the documentary escape hatch too. A fresh filing payload is accepted
    ///         as a new oracle fact, but the mint gate rejects it because AssignmentExecuted and
    ///         UCCFiled are deal-identity facts bound to the exact terms hash. Replaying that
    ///         exact hash is then refused by the C4-02 tombstone. Pinned so the kind-by-kind
    ///         split is executable rather than a stale comment.
    function test_r1703_documentaryKindsRemainBoundAfterRevocation() public {
        _mintUSDfrTo(alice, PRINCIPAL);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);

        bytes32 termsHash = bridge.creditTermsHash(
            _facilityTerms(
                Config.CLASS_FILM_TAX_CREDITS,
                BORROWER_1,
                STATE_GA,
                PRINCIPAL,
                FILM_LTV_BPS,
                FILM_RATE_BPS,
                bridge.facility(id).maturity,
                FILM_REF
            )
        );

        vm.prank(admin);
        realOracle.revoke(id, IAttestationOracle.AttestationKind.UCCFiled);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.UCCFiled
            )
        );
        bridge.checkFundable(id);

        // A NEW filing is a fresh oracle fact, but its payload is not the signed deal identity.
        bytes32 freshPayload = keccak256("re-filed-ucc-1");
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, freshPayload, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationNotBoundToDeal.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.UCCFiled,
                termsHash,
                freshPayload
            )
        );
        bridge.checkFundable(id);

        // Replaying the exact deal identity would satisfy ClaimBridge, but C4-02 makes the
        // revoked fact key durable, so a fresh nonce cannot resurrect it.
        IAttestationOracle.AttestationInput memory replay = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.UCCFiled,
            payload: termsHash,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
        bytes[] memory replaySigs = _signedBundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                realOracle.factKey(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        realOracle.attest(replay, replaySigs);

        assertTrue(
            bridge.facility(id).state == ClaimBridge.LoanState.Pending, "the revoked facility remains unfundable"
        );
    }
}
