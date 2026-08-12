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
        if (ok) _recordFact(facilityId, kind, payload, FactStatus.Recorded);
    }

    // ── IAttestationOracle surface ───────────────────────────────────────

    function attest(AttestationInput calldata a, bytes[] calldata) external {
        // C4-01: the production-shaped entry point enforces the consume-once fact ledger.
        if (a.kind != AttestationKind.Valuation) {
            bytes32 key = factKey(a.facilityId, a.kind, a.payload);
            FactStatus status = factStatuses[key];
            if (status != FactStatus.None) revert Oracle_FactAlreadyRealised(key, status);
        }
        Record storage r = records[a.facilityId][a.kind];
        r.payload = a.payload;
        r.asOf = a.asOf;
        r.satisfied = true;
        _recordFact(a.facilityId, a.kind, a.payload, FactStatus.Recorded);
        emit AttestationSatisfied(a.facilityId, a.kind, a.payload, a.asOf);
    }

    function consume(uint256 facilityId, AttestationKind kind) external {
        Record storage r = records[facilityId][kind];
        if (!r.satisfied) revert Oracle_NotSatisfied(facilityId, kind);
        r.satisfied = false;
        _recordFact(facilityId, kind, r.payload, FactStatus.Consumed);
        emit AttestationConsumed(facilityId, kind, msg.sender);
    }

    function revoke(uint256 facilityId, AttestationKind kind) external {
        Record storage r = records[facilityId][kind];
        r.satisfied = false;
        if (kind == AttestationKind.Valuation) {
            r.payload = bytes32(0);
            r.asOf = 0;
        } else {
            _recordFact(facilityId, kind, r.payload, FactStatus.Revoked); // C4-02: durable tombstone
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

    // ── C4-01 / C4-02 consume-once fact ledger ───────────────────────────
    //
    // ⚠ READ THIS BEFORE RELYING ON A MOCK-BASED SUITE FOR REPLAY BEHAVIOUR.
    // The mock MODELS the ledger (so `factStatus` reads truthfully and consumers that branch on
    // it behave as they will in production) and ENFORCES it on `attest`, the production-shaped
    // entry point. It deliberately does NOT enforce it in `setSatisfied` / `setValuation` /
    // `setPayload`: those are the explicit "force this exact oracle state" setters that consumer
    // fixtures use to reach states cheaply, and they can construct states the REAL oracle refuses
    // — exactly as they already can for thresholds, signatures, expiry and the H-02 watermark.
    // Consequence, stated plainly: a mock-based suite that re-presents an identical
    // (facility, kind, payload) through a setter is describing a scenario the production oracle
    // now REJECTS. The enforcement itself is proved only against the real contract, in
    // `test/audit/Fix_C401-fact-realised-once.t.sol`, `test/unit/AttestationOracle.t.sol` and
    // `test/invariant/OracleInvariants.t.sol`. Do not "prove" C4-01 here.
    mapping(bytes32 => FactStatus) internal factStatuses;

    /// @inheritdoc IAttestationOracle
    function factKey(uint256 facilityId, AttestationKind kind, bytes32 payload) public pure returns (bytes32) {
        return keccak256(abi.encode(facilityId, uint8(kind), payload));
    }

    /// @inheritdoc IAttestationOracle
    function factStatus(uint256 facilityId, AttestationKind kind, bytes32 payload) external view returns (FactStatus) {
        return factStatuses[factKey(facilityId, kind, payload)];
    }

    function _recordFact(uint256 facilityId, AttestationKind kind, bytes32 payload, FactStatus status) internal {
        if (kind == AttestationKind.Valuation) return; // valuations key on the watermark, not the payload
        factStatuses[factKey(facilityId, kind, payload)] = status;
    }
}
