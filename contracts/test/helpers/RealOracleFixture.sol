// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "./CreditLayerFixture.sol";

/// @dev The full protocol stack wired to the REAL AttestationOracle: every fact enters
///      through EIP-712 m-of-n signatures (no mock setters anywhere). Inheriting suites
///      exercise the production synchronization layer end-to-end — the mint gate, the
///      payment gate, the margin path, and the treasury sync all run on verified
///      attester signatures.
abstract contract RealOracleFixture is CreditLayerFixture {
    uint256 internal attesterPk1 = 0xA77E57E1;
    uint256 internal attesterPk2 = 0xA77E57E2;
    AttestationOracle internal realOracle;
    uint256 internal nonceCounter;

    function _deployOracle() internal override returns (IAttestationOracle) {
        realOracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (admin, guardian, admin))
                )
            )
        );
        return IAttestationOracle(address(realOracle));
    }

    /// @dev Runs inside the fixture's admin prank: attester set + consumer role.
    function _postWireOracle() internal override {
        realOracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(attesterPk1));
        realOracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(attesterPk2));
        realOracle.grantRole(Roles.CREDIT_ROLE, address(waterfall)); // consumes PaymentReceived
        realOracle.grantRole(Roles.CREDIT_ROLE, address(defaultManager)); // consumes loss/cure facts
        realOracle.grantRole(Roles.CREDIT_ROLE, address(bridge)); // consumes amended-terms facts
    }

    // ── real-signature attestation plumbing ──────────────────────────────

    function _signedBundle(IAttestationOracle.AttestationInput memory a) internal view returns (bytes[] memory sigs) {
        uint8 m = realOracle.threshold(a.kind);
        bytes32 digest = realOracle.attestationDigest(a);
        (uint256 loPk, uint256 hiPk) =
            vm.addr(attesterPk1) < vm.addr(attesterPk2) ? (attesterPk1, attesterPk2) : (attesterPk2, attesterPk1);
        sigs = new bytes[](m);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(loPk, digest);
        sigs[0] = abi.encodePacked(r, s, v);
        if (m > 1) {
            (v, r, s) = vm.sign(hiPk, digest);
            sigs[1] = abi.encodePacked(r, s, v);
        }
    }

    function _attest(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        internal
    {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
        realOracle.attest(a, _signedBundle(a));
    }

    // ── overrides: every fixture fact becomes a real signed attestation ──

    function _setSatisfied(uint256 facilityId, IAttestationOracle.AttestationKind kind, bool ok) internal override {
        if (kind == IAttestationOracle.AttestationKind.Valuation) {
            return; // valuations only enter through _setValuation (real signed mark)
        }
        if (ok) {
            _attest(
                facilityId,
                kind,
                keccak256(abi.encodePacked("fact", facilityId, uint8(kind), nonceCounter)),
                uint64(block.timestamp)
            );
        } else {
            vm.prank(admin);
            realOracle.revoke(facilityId, kind);
        }
    }

    function _setValuation(uint256 facilityId, uint256 value, uint64 asOf) internal override {
        _attest(facilityId, IAttestationOracle.AttestationKind.Valuation, bytes32(value), asOf);
    }

    /// @dev AUDIT FIX (H-4): the terms commitment enters through a REAL 2-of-n CreditIssued
    ///      bundle, so the mint-gate binding is exercised against production signature logic.
    function _attestCreditTerms(uint256 facilityId, bytes32 termsHash) internal override {
        _attest(facilityId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, uint64(block.timestamp));
    }

    function _attestPayment(uint256 tokenId, uint256 interest, uint256 principal) internal override {
        uint256 usdcAmount = (interest + principal) / 1e12;
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(
                abi.encode(
                    _paymentId(tokenId, interest, principal),
                    tokenId,
                    address(usdc),
                    borrower,
                    usdcAmount,
                    interest,
                    principal,
                    _nextDue(tokenId, principal)
                )
            ),
            uint64(block.timestamp)
        );
    }

    function _attestDefault(uint256 tokenId) internal override {
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, FILM_REF)),
            uint64(block.timestamp)
        );
    }

    function _attestLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash) internal override {
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(tokenId, loss, evidenceHash)),
            uint64(block.timestamp)
        );
    }

    function _attestPastDueCure(uint256 tokenId, bytes32 evidenceHash) internal override {
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(tokenId, evidenceHash)),
            uint64(block.timestamp)
        );
    }
}
