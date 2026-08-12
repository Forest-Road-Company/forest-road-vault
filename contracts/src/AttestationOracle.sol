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
/// @dev Replay safety operates at TWO levels, and the second one is load-bearing:
///      1. BUNDLE level — every accepted EIP-712 digest is consumed forever (`used`). This stops
///         a byte-identical resubmission and nothing more.
///      2. FACT level (AUDIT FIX C4-01/C4-02) — every one-shot fact, keyed on
///         (facilityId, kind, payload) with the digest's `nonce`/`asOf`/`expiry` salt EXCLUDED, is
///         realisable exactly once (`factStatuses`). Level 1 alone was bypassable by re-signing
///         the SAME real-world event under a fresh nonce, which caused one real loss to be
///         written down twice and made governance `revoke` cosmetic on 8 of the 9 kinds.
///      `Valuation` is the 9th kind and is excluded from level 2 on purpose: it is a monotone
///      observation series whose uniqueness key is the per-facility high-watermark, requiring
///      strictly increasing attested `asOf`, so a stale-but-genuinely-signed mark can never roll
///      back a newer one and a revoked observation can never return. `asOf` is the ATTESTED
///      observation time inside the signed struct — freshness rules (ADR-0015/0017) are
///      meaningless against submission time.
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
        // ── AUDIT FIX (C4-01 / C4-02): per-FACT consume-once ledger (append-only TAIL) ──
        // Keyed by `_factKey(facilityId, kind, payload)` — the economic fact, with the digest's
        // replay salt (nonce/asOf/expiry) deliberately excluded. `used[digest]` above is keyed on
        // the SIGNATURE BUNDLE and is therefore defeated by re-signing the identical fact under a
        // fresh nonce; this ledger is keyed on the EVENT and is not. Must stay last: inserting
        // mid-struct would shift every field below it and corrupt a deployed proxy.
        mapping(bytes32 factKey => FactStatus) factStatuses;
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

        // ══ AUDIT FIX (C4-01 / C4-02) — DO NOT DELETE. THE DIGEST GUARD ABOVE IS NOT ENOUGH. ══
        // `nonce`, `asOf` and `expiry` live INSIDE the digest and OUTSIDE the economic fact, so the
        // SAME real-world event re-signed by the same quorum under a fresh nonce yields a fresh
        // digest and walks straight past `used[digest]`. Measured before this guard existed: one
        // 300,000e18 loss on one facility was cascaded and written down TWICE (outstanding fell
        // 2,000,000 -> 1,400,000 instead of -> 1,700,000), and a loss attestation that GOVERNANCE
        // HAD REVOKED landed anyway. Both repros live in
        // `test/audit/Fix_C401-fact-realised-once.t.sol`.
        //
        // The consume-once key is therefore the FACT — (facilityId, kind, payload) — not the
        // bundle. Every one-shot kind's payload already commits to its event identity (payment id,
        // amendment id, or an evidence hash), so this is exact rather than approximate.
        //
        // `Valuation` is DELIBERATELY EXCLUDED, and this is not an oversight: a valuation is a
        // monotone OBSERVATION SERIES, not a one-shot event. Two genuinely distinct marks may
        // legitimately carry the identical value, so payload-keying would freeze a facility's mark
        // permanently at the first repeat — a live-fire liveness break on the MTM margin path and
        // `ReserveManager.totalBackingValue()`. Its uniqueness key is the H-02 high-watermark
        // (facility, asOf) enforced below, which already makes both replay AND revocation durable.
        // If you ever add Valuation here, read `test_c402_valuationStaysWatermarkKeyedNotPayloadKeyed`
        // first.
        //
        // OPERATIONAL CONSEQUENCE, now binding: an evidence hash must be unique per real-world
        // event. Two equal-sized partial write-downs on one facility need two distinct evidence
        // hashes; reusing one FAILS CLOSED here rather than double-writing-down.
        bool oneShot = a.kind != AttestationKind.Valuation;
        bytes32 factKey_;
        if (oneShot) {
            factKey_ = _factKey(a.facilityId, a.kind, a.payload);
            FactStatus status = $.factStatuses[factKey_];
            // ── PRIMARY LEDGER GUARD (C4-01) — DO NOT DELETE, AND DO NOT ASSUME THE SHADOW ──
            // ── GUARD BELOW COVERS IT. THEY COVER DISJOINT STATES.                        ──
            // AUDIT R17-01 (the same defect class, one round later): every C4-01 regression
            // replayed a fact while the record slot STILL HELD THAT PAYLOAD, so the legacy shadow
            // guard below caught all of them and this line was deletable with the whole C4-01 file
            // green — MEASURED: 11 of 11 passing with the C4-01 half of this line removed.
            //
            // The state only THIS line sees is a SUPERSEDED fact: `records[facility][kind]` holds
            // ONE payload, so the moment a second fact of the same kind lands on the same facility
            // (two partial write-downs, two servicing payments, two amendments — the ordinary
            // multi-event facility) every EARLIER fact's record is gone while its ledger entry
            // stands. Re-signing tranche 1 under a fresh nonce then walks past the digest guard
            // AND past the shadow guard, and `DefaultManager.realizeLoss` writes tranche 1 down a
            // second time. `test/audit/Fix_C401b-superseded-fact-replay.t.sol` drives exactly that
            // to completion in money, and `OracleHandler.replaySupersededFact` reaches it in the
            // stateful campaign with a non-vacuity counter behind it.
            if (status != FactStatus.None) revert Oracle_FactAlreadyRealised(factKey_, status);
            // UPGRADE-PATH DEGRADATION, exactly parallel to H-02's `max` below and for the same
            // reason. On an IN-PLACE UUPS upgrade of a proxy that predates this fix, `factStatuses`
            // starts EMPTY while live records stand, so every already-realised fact would read
            // `None` and be replayable exactly once. The live record is the one piece of pre-upgrade
            // evidence available: if this submission reproduces the CURRENT record for the slot, the
            // fact has demonstrably been through here before. That covers the most recent — and by
            // far the most valuable — fact per (facility, kind), which is precisely what a holder of
            // a duplicate pre-signed bundle would target. On a FRESH deploy this branch is
            // UNREACHABLE (a standing record implies a non-`None` ledger entry), so it costs
            // correctness nothing and degrades the rule gracefully instead of to nothing at all.
            // It cannot distinguish Consumed from Revoked on the legacy path; `satisfied` is all
            // the pre-upgrade state says, so it reports the closest honest status.
            //
            // SHADOW GUARD (upgrade path only) — DO NOT DELETE EITHER, and do not mistake it for a
            // second copy of the guard above. It is keyed on the LIVE RECORD, so it is blind to
            // every superseded fact (see the primary guard's note); the primary guard is in turn
            // blind to a proxy whose ledger predates this fix. Deleting this line reds
            // `test_c401_legacyProxyWithAnEmptyLedgerStillBlocksTheReplay`; deleting the primary
            // guard reds `test/audit/Fix_C401b-superseded-fact-replay.t.sol`. Neither test can
            // stand in for the other.
            Record storage legacy = $.records[a.facilityId][a.kind];
            if (legacy.asOf != 0 && legacy.payload == a.payload) {
                revert Oracle_FactAlreadyRealised(
                    factKey_, legacy.satisfied ? FactStatus.Recorded : FactStatus.Consumed
                );
            }
        }

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
        // AUDIT FIX (C4-01): burn the FACT here, after every check has passed.
        //
        // CORRECTION (audit R17-01). An earlier revision of this comment justified the ordering as
        // stopping "an unauthorized relayer permanently poisoning a legitimate fact's key with a
        // garbage bundle". That reasoning is WRONG and is removed rather than repeated: every
        // failure between here and the top of the function REVERTS (`Oracle_NotAttester`,
        // `Oracle_UnorderedSigners`, `ECDSA`'s own malformed-signature revert), which unwinds any
        // write made earlier in the same call. The ordering is therefore checks-effects hygiene —
        // correct, and worth keeping — but it is NOT what prevents that denial of service; the
        // revert is. Do not rely on the ordering for a property only the revert provides.
        if (oneShot) $.factStatuses[factKey_] = FactStatus.Recorded;
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
        // AUDIT FIX (C4-01) — DO NOT DELETE. `satisfied = false` alone was the entire reason ONE
        // real loss could be written down twice: it left the record re-satisfiable, and the digest
        // guard could not see a re-signing of the same fact. Recording the spend against the FACT
        // key is what makes consumption terminal. Skipped for `Valuation`, which is not a one-shot
        // fact and is keyed on the H-02 watermark (see `attest`); writing a status for it would
        // block the legitimate re-marking of an unchanged value.
        if (kind != AttestationKind.Valuation) {
            $.factStatuses[_factKey(facilityId, kind, r.payload)] = FactStatus.Consumed;
        }
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
        } else {
            // AUDIT FIX (C4-02) — DO NOT DELETE. Before this line, `revoke` was COSMETIC on 8 of
            // the 9 kinds: it cleared `satisfied` and nothing stopped the identical bundle being
            // re-signed under a fresh nonce and re-consumed, so governance's emergency stop on a
            // discovered-false attestation could be undone by any relayer. Measured: a REVOKED
            // 300,000e18 loss was written down anyway. `Valuation` was the sole durable kind, and
            // only because H-02's watermark (seeded in the branch above) is already a fact-level
            // key — which is exactly why the other eight now get a fact-level tombstone here.
            //
            // The tombstone is PERMANENT BY DESIGN, with no governance lever to lift it. That is
            // the same reasoning that deleted `resetValuationWatermark` (see the note below):
            // governance acts through a PUBLIC timelock queue, so any "un-revoke" lever would let
            // a holder of the revoked pre-signed bundle race it and re-open this exact hole.
            //
            // RE-ESTABLISHING A REVOKED FACT — CORRECTED, audit R17-03. An earlier revision of
            // this comment said, without qualification, "the attesters sign a NEW fact — a new
            // evidence hash". THAT IS ONLY TRUE FOR THE KINDS WHOSE PAYLOAD CARRIES A FREE
            // EVENT-IDENTITY FIELD, and an operator who trusted it on the kind that does not
            // would find the facility bricked. The two cases, both pinned in
            // `test/audit/Fix_C402b-revocation-escape-hatch.t.sol`:
            //
            //   WORKS — DefaultDeclared / LossRealized / PastDueCured (free `evidenceHash`),
            //   PaymentReceived (free `paymentId`), and TermsAmended (free `amendmentId`).
            //   The documentary kinds are deal-identity facts under P-32, so ClaimBridge binds
            //   their payloads to the exact terms hash as well; a new document hash is a fresh
            //   oracle fact but cannot restore the mint gate, and the exact hash is tombstoned.
            //
            //   DOES NOT WORK — CreditIssued. The H-4/P-32 terms binding makes
            //   `ClaimBridge._requireMintAttestations` demand the deal-identity payloads equal
            //   `_creditTermsHash(facility)` EXACTLY, and that hash is a pure function of the signed terms: there is no free
            //   field to vary. Once revoked, that (facilityId, CreditIssued, termsHash) triple is
            //   dead forever, so a PENDING facility cannot be funded and cannot be amended
            //   (`amendTerms` requires Active/Amortizing). The remedy is NOT a re-attestation: it
            //   is `ClaimBridge.cancelPending` — which reverses the recorded concentration
            //   exposure and burns the position — followed by re-origination at a FRESH facility
            //   id, whose different id gives the identical terms a different fact key. Before the
            //   token is minted the same applies to `nextId`: those exact terms are dead at that
            //   id and origination must move to a different id or different terms.
            $.factStatuses[_factKey(facilityId, kind, r.payload)] = FactStatus.Revoked;
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

    /// @inheritdoc IAttestationOracle
    function factKey(uint256 facilityId, AttestationKind kind, bytes32 payload) external pure returns (bytes32) {
        return _factKey(facilityId, kind, payload);
    }

    /// @inheritdoc IAttestationOracle
    function factStatus(uint256 facilityId, AttestationKind kind, bytes32 payload) external view returns (FactStatus) {
        return _storage().factStatuses[_factKey(facilityId, kind, payload)];
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

    /// @dev AUDIT FIX (C4-01). The consume-once key for an economic FACT. `nonce`, `asOf` and
    ///      `expiry` are deliberately ABSENT: they are replay salt that varies between two
    ///      signings of the SAME real-world event, which is precisely how the digest guard was
    ///      bypassed. Do not add them back.
    function _factKey(uint256 facilityId, AttestationKind kind, bytes32 payload) private pure returns (bytes32) {
        return keccak256(abi.encode(facilityId, uint8(kind), payload));
    }

    function _storage() private pure returns (OracleStorage storage $) {
        assembly {
            $.slot := ORACLE_STORAGE_LOCATION
        }
    }
}
