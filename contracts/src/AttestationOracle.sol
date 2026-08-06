// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title AttestationOracle — the off-chain → on-chain synchronization layer (ADR-0007)
/// @notice Authorized attesters co-sign facts (EIP-712 typed data); once a kind's
///         m-of-n threshold of DISTINCT attester signatures over the IDENTICAL struct
///         is relayed here, the fact becomes on-chain truth: the ClaimBridge mint gate,
///         the WaterfallEngine's payment gate, the DefaultManager's default/loss and
///         margin paths, and signed facility amendments all read it.
///
///         ⚠ TRUST BOUNDARY (ADR-0007 — the protocol's primary trust assumption): the
///         protocol executes faithfully on whatever authorized attesters assert. A
///         false attestation, or a compromised attester key set reaching a kind's
///         threshold, means the protocol acts on false information. Mitigations are
///         m-of-n thresholds (≥2 for high-value kinds), governance-managed attester
///         rotation, guardian pause on submissions, and governance revocation — not
///         trustlessness. Forest Road's conscious acceptance of this boundary is a
///         pre-mainnet ownership item (brief Part 11 gate 6).
/// @dev Replay safety: every accepted bundle's EIP-712 digest is consumed forever;
///      Valuation additionally requires strictly increasing attested `asOf`, so a
///      stale-but-genuinely-signed mark can never roll back a newer one. `asOf` is the
///      ATTESTED observation time inside the signed struct — freshness rules
///      (ADR-0015/0017) are meaningless against submission time.
contract AttestationOracle is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    UUPSUpgradeable,
    IAttestationOracle
{
    struct Record {
        bytes32 payload;
        uint64 asOf;
        bool satisfied;
    }

    /// @custom:storage-location erc7201:forestroad.storage.AttestationOracle
    struct OracleStorage {
        mapping(uint256 facilityId => mapping(AttestationKind kind => Record)) records;
        mapping(AttestationKind kind => uint8) thresholds;
        mapping(bytes32 digest => bool) used;
        // ── AUDIT FIX (H-02): valuation anti-rollback high-watermark (append-only TAIL) ──
        // The highest `asOf` ever ACCEPTED for a facility, held OUTSIDE the record so that
        // `revoke` can zero the live mark (an emergency stop) without rewinding the monotonic
        // clock. Must stay last: inserting mid-struct would shift every field below it and
        // corrupt a deployed proxy.
        mapping(uint256 facilityId => uint64) valuationWatermarks;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.AttestationOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ORACLE_STORAGE_LOCATION =
        0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00;

    /// @dev keccak256("Attestation(uint256 facilityId,uint8 kind,bytes32 payload,uint64 asOf,uint64 expiry,uint256 nonce)")
    bytes32 private constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(uint256 facilityId,uint8 kind,bytes32 payload,uint64 asOf,uint64 expiry,uint256 nonce)");

    error Oracle_ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the oracle. Every kind defaults to a 1-of-n threshold
    ///         except the high-value kinds `CreditIssued` and `Valuation`, which
    ///         start at 2-of-n (ADR-0007).
    /// @param admin Governance timelock (attester set, thresholds, revocation).
    /// @param guardian Emergency pauser (submissions only — reads never pause).
    /// @param upgrader Upgrade authority (timelock).
    function initialize(address admin, address guardian, address upgrader) external initializer {
        if (admin == address(0) || guardian == address(0) || upgrader == address(0)) revert Oracle_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init("ForestRoadAttestationOracle", "1");
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        OracleStorage storage $ = _storage();
        for (uint8 k = 0; k < 9; ++k) {
            AttestationKind kind = AttestationKind(k);
            // AUDIT FIX (M): every kind that authorizes a VALUE-MOVING or state-freezing
            // action defaults to 2-of-n so no single compromised attester key can act
            // alone — CreditIssued/Valuation (mint gate + backing), PaymentReceived
            // (authorizes a waterfall distribution), DefaultDeclared (drives the loss
            // path). Documentary assignment/perfection kinds start 1-of-n.
            uint8 m = (
                kind == AttestationKind.CreditIssued || kind == AttestationKind.Valuation
                    || kind == AttestationKind.PaymentReceived || kind == AttestationKind.DefaultDeclared
                    || kind == AttestationKind.LossRealized || kind == AttestationKind.PastDueCured
                    || kind == AttestationKind.TermsAmended
            ) ? 2 : 1;
            $.thresholds[kind] = m;
            emit ThresholdSet(kind, m);
        }
    }

    // ── Submission ───────────────────────────────────────────────────────

    /// @inheritdoc IAttestationOracle
    /// @dev Signatures must be sorted by ascending recovered signer address — the
    ///      cheapest possible distinctness proof for the m-of-n check.
    function attest(AttestationInput calldata a, bytes[] calldata signatures) external whenNotPaused {
        if (block.timestamp > a.expiry) revert Oracle_Expired(a.expiry);
        if (a.asOf == 0 || a.asOf > block.timestamp) revert Oracle_BadAsOf(a.asOf);

        OracleStorage storage $ = _storage();
        uint8 required = $.thresholds[a.kind];
        // Fail closed if a new kind is introduced without an initialized threshold, or
        // if an unsafe legacy upgrade leaves the threshold slot unset. `setThreshold`
        // rejects zero, but submission must enforce the invariant independently.
        if (required == 0) revert Oracle_BadThreshold();
        if (signatures.length < required) revert Oracle_ThresholdNotMet(required, signatures.length);

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(ATTESTATION_TYPEHASH, a.facilityId, uint8(a.kind), a.payload, a.asOf, a.expiry, a.nonce)
            )
        );
        if ($.used[digest]) revert Oracle_DigestAlreadyUsed(digest);
        $.used[digest] = true;

        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= prev) revert Oracle_UnorderedSigners(prev, signer);
            if (!hasRole(Roles.ATTESTER_ROLE, signer)) revert Oracle_NotAttester(signer);
            prev = signer;
            emit Attested(a.facilityId, a.kind, signer, uint64(block.timestamp));
        }

        Record storage r = $.records[a.facilityId][a.kind];
        if (a.kind == AttestationKind.Valuation) {
            if (uint256(a.payload) == 0) revert Oracle_ZeroValuation();
            // AUDIT FIX (H-02). Strictly newer marks only, measured against the per-facility
            // HIGH-WATERMARK rather than the live record. `revoke` zeroes `r.asOf`, so
            // comparing against the record alone let an older but validly-signed bundle be
            // replayed the instant governance revoked a bad mark -- and that mark feeds
            // `ReserveManager.totalBackingValue()`, the right-hand side of the backing
            // invariant. Taking `max` with `r.asOf` is deliberate belt-and-braces: on a
            // FRESH deploy the watermark already dominates, but on an in-place upgrade of a
            // proxy that predates this fix the watermark starts at zero while a live mark
            // stands, and the max makes the rule degrade to the OLD behaviour rather than to
            // no rule at all.
            uint64 floor_ = $.valuationWatermarks[a.facilityId];
            if (r.asOf > floor_) floor_ = r.asOf;
            if (a.asOf <= floor_) revert Oracle_StaleValuation(a.asOf, floor_);
            $.valuationWatermarks[a.facilityId] = a.asOf;
        }
        r.payload = a.payload;
        r.asOf = a.asOf;
        r.satisfied = true;
        emit AttestationSatisfied(a.facilityId, a.kind, a.payload, a.asOf);
    }

    // ── Credit-layer consumption ─────────────────────────────────────────

    /// @inheritdoc IAttestationOracle
    /// @dev Never pausable: consumption is part of loss/payment processing, and
    ///      suppressing it would strand already-attested value flows.
    function consume(uint256 facilityId, AttestationKind kind) external onlyRole(Roles.CREDIT_ROLE) {
        OracleStorage storage $ = _storage();
        Record storage r = $.records[facilityId][kind];
        if (!r.satisfied) revert Oracle_NotSatisfied(facilityId, kind);
        r.satisfied = false; // payload + asOf retained for audit
        emit AttestationConsumed(facilityId, kind, msg.sender);
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @inheritdoc IAttestationOracle
    function revoke(uint256 facilityId, AttestationKind kind) external onlyRole(DEFAULT_ADMIN_ROLE) {
        OracleStorage storage $ = _storage();
        Record storage r = $.records[facilityId][kind];
        if (!r.satisfied && r.payload == bytes32(0)) revert Oracle_NotSatisfied(facilityId, kind);
        r.satisfied = false;
        if (kind == AttestationKind.Valuation) {
            // AUDIT FIX (H-02): SEED the watermark from the live mark BEFORE wiping it. The
            // additive floor in `attest` alone does not cover the upgrade path -- on a proxy
            // that predates this fix the watermark is zero, so revoking first would drop the
            // floor to zero and re-open exactly the rollback window this closes. Seeding here
            // makes the monotonic clock survive revocation on every path.
            if (r.asOf > $.valuationWatermarks[facilityId]) $.valuationWatermarks[facilityId] = r.asOf;
            // a revoked mark must not keep steering the margin path or the backing
            r.payload = bytes32(0);
            r.asOf = 0;
        }
        emit AttestationRevoked(facilityId, kind);
    }

    // AUDIT / OWNER DECISION (2026-07-22): `resetValuationWatermark` was REMOVED. The H-02
    // anti-rollback watermark itself is unchanged (see `attest`/`revoke` and
    // `valuationWatermarks`). The governance recovery lever that could lower a stuck watermark
    // was deleted because it was also an attack surface -- governance actions go through a PUBLIC
    // timelock queue, so a queued reset let a holder of a pre-signed OLDER valuation race the
    // watermark down the instant it executed, re-opening the very rollback the watermark prevents.
    // The rare "watermark stuck at a far-future asOf" recovery case is covered by the oracle's
    // UUPS upgrade path (also timelock-gated), so the dedicated lever was redundant with an
    // existing path while adding a race surface. Tradeoff accepted by the owner.

    /// @inheritdoc IAttestationOracle
    /// @dev AUDIT FIX: the value-moving / state-freezing kinds are floored at 2-of-n so
    ///      governance can't (accidentally or maliciously) lower them back to 1-of-n and
    ///      undo the single-attester protection (ADR-0007 high-value kinds).
    function setThreshold(AttestationKind kind, uint8 threshold_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (threshold_ == 0) revert Oracle_BadThreshold();
        if (
            threshold_ < 2
                && (
                    kind == AttestationKind.CreditIssued || kind == AttestationKind.Valuation
                        || kind == AttestationKind.PaymentReceived || kind == AttestationKind.DefaultDeclared
                        || kind == AttestationKind.LossRealized || kind == AttestationKind.PastDueCured
                        || kind == AttestationKind.TermsAmended
                )
        ) revert Oracle_BadThreshold();
        _storage().thresholds[kind] = threshold_;
        emit ThresholdSet(kind, threshold_);
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses attestation submissions (the lever against suspect attesters).
    ///         Reads and consumption never pause.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses submissions.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IAttestationOracle
    function isSatisfied(uint256 facilityId, AttestationKind kind) external view returns (bool) {
        return _storage().records[facilityId][kind].satisfied;
    }

    /// @inheritdoc IAttestationOracle
    function latestValuation(uint256 facilityId) external view returns (uint256 value, uint64 asOf) {
        Record storage r = _storage().records[facilityId][AttestationKind.Valuation];
        return (uint256(r.payload), r.asOf);
    }

    /// @inheritdoc IAttestationOracle
    function latestPayload(uint256 facilityId, AttestationKind kind)
        external
        view
        returns (bytes32 payload, uint64 asOf, bool satisfied)
    {
        Record storage r = _storage().records[facilityId][kind];
        return (r.payload, r.asOf, r.satisfied);
    }

    /// @inheritdoc IAttestationOracle
    function valuationWatermark(uint256 facilityId) external view returns (uint64) {
        return _storage().valuationWatermarks[facilityId];
    }

    /// @inheritdoc IAttestationOracle
    function threshold(AttestationKind kind) external view returns (uint8) {
        return _storage().thresholds[kind];
    }

    /// @inheritdoc IAttestationOracle
    function digestUsed(bytes32 digest) external view returns (bool) {
        return _storage().used[digest];
    }

    /// @notice The EIP-712 struct digest for an attestation (attester tooling aid).
    function attestationDigest(AttestationInput calldata a) external view override returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(ATTESTATION_TYPEHASH, a.facilityId, uint8(a.kind), a.payload, a.asOf, a.expiry, a.nonce)
            )
        );
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (OracleStorage storage $) {
        assembly {
            $.slot := ORACLE_STORAGE_LOCATION
        }
    }
}
