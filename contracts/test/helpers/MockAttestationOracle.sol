// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";

/// @dev Test stand-in for the AttestationOracle: attestation truth is set directly.
///      The VIEW semantics match the real oracle exactly (that equivalence is what
///      the real oracle's unit suite proves), so consumer logic under test — the
///      ClaimBridge mint gate, the margin path, the payment gate — is production
///      logic. `attest` accepts anything (signature machinery is the real contract's
///      job); `consume`/`revoke` mirror the real state transitions.
contract MockAttestationOracle is IAttestationOracle {
    struct Record {
        bytes32 payload;
        uint64 asOf;
        bool satisfied;
    }

    mapping(uint256 => mapping(AttestationKind => Record)) internal records;
    mapping(AttestationKind => uint8) public thresholds;
    mapping(bytes32 => bool) public usedDigests;

    // ── direct test setters ──────────────────────────────────────────────

    function setSatisfied(uint256 facilityId, AttestationKind kind, bool ok) external {
        records[facilityId][kind].satisfied = ok;
        emit Attested(facilityId, kind, msg.sender, uint64(block.timestamp));
    }

    function setValuation(uint256 facilityId, uint256 value, uint64 asOf) external {
        Record storage r = records[facilityId][AttestationKind.Valuation];
        r.payload = bytes32(value);
        r.asOf = asOf;
    }

    function setPayload(uint256 facilityId, AttestationKind kind, bytes32 payload, uint64 asOf, bool ok) external {
        records[facilityId][kind] = Record({payload: payload, asOf: asOf, satisfied: ok});
    }

    // ── IAttestationOracle surface ───────────────────────────────────────

    function attest(AttestationInput calldata a, bytes[] calldata) external {
        Record storage r = records[a.facilityId][a.kind];
        r.payload = a.payload;
        r.asOf = a.asOf;
        r.satisfied = true;
        emit AttestationSatisfied(a.facilityId, a.kind, a.payload, a.asOf);
    }

    function consume(uint256 facilityId, AttestationKind kind) external {
        Record storage r = records[facilityId][kind];
        if (!r.satisfied) revert Oracle_NotSatisfied(facilityId, kind);
        r.satisfied = false;
        emit AttestationConsumed(facilityId, kind, msg.sender);
    }

    function revoke(uint256 facilityId, AttestationKind kind) external {
        Record storage r = records[facilityId][kind];
        r.satisfied = false;
        if (kind == AttestationKind.Valuation) {
            r.payload = bytes32(0);
            r.asOf = 0;
        }
        emit AttestationRevoked(facilityId, kind);
    }

    function setThreshold(AttestationKind kind, uint8 threshold_) external {
        thresholds[kind] = threshold_;
        emit ThresholdSet(kind, threshold_);
    }

    function isSatisfied(uint256 facilityId, AttestationKind kind) external view returns (bool) {
        return records[facilityId][kind].satisfied;
    }

    function latestValuation(uint256 facilityId) external view returns (uint256, uint64) {
        Record storage r = records[facilityId][AttestationKind.Valuation];
        return (uint256(r.payload), r.asOf);
    }

    function latestPayload(uint256 facilityId, AttestationKind kind) external view returns (bytes32, uint64, bool) {
        Record storage r = records[facilityId][kind];
        return (r.payload, r.asOf, r.satisfied);
    }

    // ── H-02 watermark (mirrors the real oracle's observable semantics) ──
    mapping(uint256 facilityId => uint64) public watermarks;

    /// @inheritdoc IAttestationOracle
    function valuationWatermark(uint256 facilityId) external view returns (uint64) {
        return watermarks[facilityId];
    }

    // resetValuationWatermark removed to mirror the real oracle (owner decision 2026-07-22).

    function threshold(AttestationKind kind) external view returns (uint8) {
        return thresholds[kind];
    }

    function digestUsed(bytes32 digest) external view returns (bool) {
        return usedDigests[digest];
    }

    function attestationDigest(AttestationInput calldata a) external view returns (bytes32) {
        return keccak256(
            abi.encode(block.chainid, address(this), a.facilityId, a.kind, a.payload, a.asOf, a.expiry, a.nonce)
        );
    }
}
