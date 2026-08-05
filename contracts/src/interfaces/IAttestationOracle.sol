// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IAttestationOracle
/// @notice Off-chain → on-chain synchronization layer (ADR-0007). Facilities may not
///         mint, and material state may not advance, without the required attestations.
/// @dev TRUST NOTE (state prominently everywhere): the protocol executes faithfully on
///      whatever authorized attesters assert. A false attestation or compromised
///      attester key means the protocol acts on false information. This is the
///      protocol's primary trust assumption (ADR-0007; brief Part 11 gate 6).
interface IAttestationOracle {
    /// @notice Attestation kinds, per ADR-0007 / the legal-wrapper sync table.
    enum AttestationKind {
        AssignmentExecuted,
        UCCFiled,
        CreditIssued,
        PaymentReceived,
        DefaultDeclared,
        Valuation,
        LossRealized,
        PastDueCured,
        TermsAmended
    }

    /// @notice One attested fact, signed by m-of-n authorized attesters over EIP-712.
    /// @param facilityId The facility.
    /// @param kind The attestation kind.
    /// @param payload Kind-specific commitment. Valuation stores the 18-decimal value
    ///        directly; operational facts commit to their complete action parameters
    ///        (terms, payment id/payer/amounts/due date, evidence hash, or amendment id).
    /// @param asOf The ATTESTED observation time (inside the signed payload — not the
    ///        submission block time; freshness rules depend on this, ADR-0017 §4).
    /// @param expiry Submission deadline for this signed bundle.
    /// @param nonce Uniqueness salt (any unused value; digests are consume-once).
    struct AttestationInput {
        uint256 facilityId;
        AttestationKind kind;
        bytes32 payload;
        uint64 asOf;
        uint64 expiry;
        uint256 nonce;
    }

    // ── Events ───────────────────────────────────────────────────────────
    /// @notice Emitted once per recovered signer of an accepted attestation.
    event Attested(uint256 indexed facilityId, AttestationKind indexed kind, address indexed attester, uint64 at);
    /// @notice The fact is now on-chain truth (threshold met).
    event AttestationSatisfied(uint256 indexed facilityId, AttestationKind indexed kind, bytes32 payload, uint64 asOf);
    /// @notice A one-shot fact was consumed by the credit layer (e.g. a
    ///         PaymentReceived spent by its distribution).
    event AttestationConsumed(uint256 indexed facilityId, AttestationKind indexed kind, address indexed by);
    /// @notice Governance revoked a fact (e.g. discovered-false attestation).
    event AttestationRevoked(uint256 indexed facilityId, AttestationKind indexed kind);
    event ThresholdSet(AttestationKind indexed kind, uint8 threshold);
    // NOTE: `ValuationWatermarkReset` and the `resetValuationWatermark` lever were REMOVED
    // (owner decision 2026-07-22). The H-02 anti-rollback watermark itself is unchanged; a stuck
    // watermark is recovered via the oracle's timelocked UUPS upgrade, not a dedicated lever.

    // ── Errors ───────────────────────────────────────────────────────────
    error Oracle_Expired(uint64 expiry);
    error Oracle_BadAsOf(uint64 asOf);
    error Oracle_DigestAlreadyUsed(bytes32 digest);
    error Oracle_ThresholdNotMet(uint8 required, uint256 provided);
    error Oracle_NotAttester(address recovered);
    error Oracle_UnorderedSigners(address prev, address current);
    error Oracle_ZeroValuation();
    error Oracle_StaleValuation(uint64 asOf, uint64 existing);
    error Oracle_NotSatisfied(uint256 facilityId, AttestationKind kind);
    error Oracle_BadThreshold();

    // ── Submission (permissionless relay of attester signatures) ─────────
    /// @notice Records `a` as on-chain truth if at least the kind's threshold of
    ///         DISTINCT authorized attesters signed exactly this struct (EIP-712).
    ///         Anyone may relay the bundle; the signatures are the authority.
    function attest(AttestationInput calldata a, bytes[] calldata signatures) external;

    // ── Credit-layer consumption ─────────────────────────────────────────
    /// @notice Clears the satisfied flag of a one-shot fact (payload/asOf retained
    ///         for audit). Only a wired CREDIT_ROLE module may consume a fact.
    function consume(uint256 facilityId, AttestationKind kind) external;

    // ── Governance ───────────────────────────────────────────────────────
    /// @notice Revokes a fact (clears satisfied; a revoked Valuation is zeroed so the
    ///         margin path blocks until a fresh mark). Timelocked governance only.
    function revoke(uint256 facilityId, AttestationKind kind) external;

    // NOTE (owner decision 2026-07-22): the `resetValuationWatermark` recovery lever was REMOVED.
    // The H-02 anti-rollback watermark itself is unchanged. Rationale: the lever was also an
    // attack surface -- governance goes through a PUBLIC timelock queue, so a queued reset let a
    // holder of a pre-signed OLDER valuation race the watermark down the instant it executed,
    // re-opening the rollback the watermark prevents. The rare "watermark stuck at a far-future
    // asOf after an attester-quorum compromise" recovery is instead handled by the oracle's
    // timelocked UUPS upgrade (redundant with the lever, without the race surface). This
    // supersedes the 2026-07-21 decision to keep it.

    /// @notice Sets a kind's m-of-n threshold (>= 1). Timelocked governance only.
    function setThreshold(AttestationKind kind, uint8 threshold_) external;

    // ── Views ────────────────────────────────────────────────────────────
    /// @notice True if `facilityId` has a currently valid attestation of `kind`.
    function isSatisfied(uint256 facilityId, AttestationKind kind) external view returns (bool);

    /// @notice Latest attested valuation mark for a facility (conservative, haircut).
    /// @return value 18-dec USD mark (0 = no valid mark).
    /// @return asOf Attested observation time of the mark (staleness checks per
    ///         ADR-0015 for marked-to-market classes).
    function latestValuation(uint256 facilityId) external view returns (uint256 value, uint64 asOf);

    /// @notice Latest recorded fact for (facility, kind).
    function latestPayload(uint256 facilityId, AttestationKind kind)
        external
        view
        returns (bytes32 payload, uint64 asOf, bool satisfied);

    /// @notice The facility's valuation anti-rollback high-watermark: the highest attested
    ///         `asOf` ever ACCEPTED for this facility, preserved across `revoke` and `consume`.
    ///         A new `Valuation` must beat it strictly.
    /// @param facilityId The facility identifier.
    /// @return highestAsOf Highest accepted observation time (0 = never marked).
    function valuationWatermark(uint256 facilityId) external view returns (uint64 highestAsOf);

    /// @notice Current m-of-n threshold for a kind.
    function threshold(AttestationKind kind) external view returns (uint8);

    /// @notice True if an attestation digest was already submitted (replay guard).
    function digestUsed(bytes32 digest) external view returns (bool);

    /// @notice The EIP-712 digest attesters sign for `a`.
    /// @dev Exposed for signing tools, atomic executors, and replay-safe relayers.
    function attestationDigest(AttestationInput calldata a) external view returns (bytes32);
}
