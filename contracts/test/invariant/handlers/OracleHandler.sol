// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationOracle} from "../../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../../src/libraries/Roles.sol";

/// @dev Bounded handler driving the REAL oracle with genuine EIP-712 bundles while
///      maintaining an independent ghost model of what the state MUST be. Per-call
///      asserts pin no-replay and valuation monotonicity; the invariant functions
///      check full state parity. `fail_on_revert = true`: every submission is
///      constructed valid; a revert is a finding.
contract OracleHandler is Test {
    AttestationOracle internal oracle;
    address internal admin;

    uint256[3] internal pks = [uint256(0xFEED1), uint256(0xFEED2), uint256(0xFEED3)];
    uint256 internal nonce;

    // ── ghost model ──────────────────────────────────────────────────────
    mapping(uint256 => mapping(IAttestationOracle.AttestationKind => bool)) public ghostSatisfied;
    mapping(uint256 => mapping(IAttestationOracle.AttestationKind => bytes32)) public ghostPayload;
    mapping(uint256 => mapping(IAttestationOracle.AttestationKind => uint64)) public ghostAsOf;
    /// @dev H-02: the ghost model's copy of the per-facility valuation high-watermark. It is
    ///      tracked SEPARATELY from `ghostAsOf` for the same reason the contract keeps it
    ///      outside the record: `revoke` zeroes the live mark but must NOT rewind this.
    mapping(uint256 => uint64) public ghostWatermark;
    uint256 public callCount;

    // ── C4-01 / C4-02 ghost fact ledger ──────────────────────────────────
    /// @dev The independent model of "which economic facts have been realised". Keyed exactly as
    ///      the contract keys them — (facility, kind, payload), NO nonce/asOf/expiry — because the
    ///      whole finding was that the digest carries salt the fact does not.
    struct Fact {
        uint256 facilityId;
        IAttestationOracle.AttestationKind kind;
        bytes32 payload;
    }

    Fact[] internal facts;
    mapping(bytes32 => IAttestationOracle.FactStatus) public ghostFactStatus;

    /// @dev REACHABILITY COUNTERS. `afterInvariant` asserts these are non-zero, so this campaign
    ///      cannot degrade into decoration: if a future refactor pre-filters the replay actions so
    ///      they never actually reach the illegal region, the suite goes RED rather than green-and
    ///      -vacuous. (Campaign 5's lesson, applied here deliberately.)
    uint256 public ghostBlockedFactReplays; // one-shot kinds: Oracle_FactAlreadyRealised
    uint256 public ghostBlockedRevokedReplays; // specifically from the Revoked tombstone (C4-02)
    uint256 public ghostBlockedStaleValuations; // the 9th kind, blocked by the H-02 watermark
    /// @dev AUDIT R17-01. Replays where the LIVE-RECORD shadow guard in `attest` is structurally
    ///      unable to fire (the record has moved on to a later payload), so the fact LEDGER is the
    ///      sole refusal. `replayRealisedFact` reaches this shape only by luck — it needs the
    ///      fuzzer to have landed two facts on one (facility, kind) slot and then to pick the older
    ///      one — which is why the primary ledger guard was deletable with the C4-01 regression
    ///      file green. `replaySupersededFact` drives it deterministically, and the non-vacuity
    ///      assertion in `afterInvariant` keeps it that way.
    uint256 public ghostBlockedSupersededReplays;

    constructor(AttestationOracle oracle_, address admin_) {
        oracle = oracle_;
        admin = admin_;
        vm.startPrank(admin_);
        for (uint256 i = 0; i < 3; ++i) {
            oracle_.grantRole(Roles.ATTESTER_ROLE, vm.addr(pks[i]));
        }
        vm.stopPrank();
        // SEED one fact so `replayRealisedFact` has a target from call #1 and never needs an
        // "if empty, return" early exit — a pre-filter would be exactly the vacuity trap.
        _seedFact(0, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("c4-seed"));
    }

    function _seedFact(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload) internal {
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        oracle.attest(a, _bundle(a));
        ghostSatisfied[facilityId][kind] = true;
        ghostPayload[facilityId][kind] = payload;
        ghostAsOf[facilityId][kind] = a.asOf;
        _recordFact(facilityId, kind, payload, IAttestationOracle.FactStatus.Recorded);
    }

    function _factKey(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(facilityId, uint8(kind), payload));
    }

    function _recordFact(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        IAttestationOracle.FactStatus status
    ) internal {
        if (kind == IAttestationOracle.AttestationKind.Valuation) return;
        bytes32 key = _factKey(facilityId, kind, payload);
        if (ghostFactStatus[key] == IAttestationOracle.FactStatus.None) {
            facts.push(Fact({facilityId: facilityId, kind: kind, payload: payload}));
        }
        ghostFactStatus[key] = status;
    }

    function factCount() external view returns (uint256) {
        return facts.length;
    }

    function factAt(uint256 i) external view returns (uint256, IAttestationOracle.AttestationKind, bytes32) {
        Fact storage f = facts[i];
        return (f.facilityId, f.kind, f.payload);
    }

    /// @dev A quorum-valid bundle at the kind's CURRENT threshold, signers sorted ascending.
    function _bundle(IAttestationOracle.AttestationInput memory a) internal view returns (bytes[] memory sigs) {
        uint8 m = oracle.threshold(a.kind);
        bytes32 digest = oracle.attestationDigest(a);
        uint256[3] memory sorted = _sortedPks();
        sigs = new bytes[](m);
        for (uint256 i = 0; i < m; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sorted[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _sortedPks() internal view returns (uint256[3] memory sorted) {
        sorted = pks;
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && vm.addr(sorted[j - 1]) > vm.addr(sorted[j]); --j) {
                (sorted[j - 1], sorted[j]) = (sorted[j], sorted[j - 1]);
            }
        }
    }

    function attestFact(uint256 facSeed, uint8 kindSeed, bytes32 payloadSeed) external {
        uint256 facilityId = facSeed % 3;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(kindSeed % 9);

        bytes32 payload = payloadSeed;
        uint64 asOf = uint64(block.timestamp);
        if (kind == IAttestationOracle.AttestationKind.Valuation) {
            if (payload == bytes32(0)) payload = bytes32(uint256(1e18)); // nonzero mark
            // H-02: strictly newer than the WATERMARK (which survives revocation), not just
            // than the live mark. Warp past it if needed so the handler stays revert-free.
            uint64 last = ghostAsOf[facilityId][kind];
            uint64 mark = ghostWatermark[facilityId];
            if (mark > last) last = mark;
            if (asOf <= last) {
                vm.warp(uint256(last) + 1);
                asOf = uint64(block.timestamp);
            }
        } else {
            // C4-01: nonce/asOf are signature-bundle metadata and do not make a consumed or
            // revoked economic fact new. This success-path handler therefore commits a unique
            // fact payload for every action; deterministic replay rejection is pinned in
            // Fix_C401FactReplay rather than hidden behind an unexpected invariant revert.
            payload = keccak256(abi.encode("oracle-invariant-fact", facilityId, kind, payloadSeed, nonce + 1));
        }

        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        assertFalse(oracle.digestUsed(digest), "REPLAY MODEL: fresh digest already used");
        bytes[] memory sigs = _bundle(a);

        // C4-01: the fuzzer reuses dictionary payloads (bytes32(0) above all), so this branch is
        // reached organically as well as by `replayRealisedFact`. NOT pre-filtered on purpose: the
        // illegal input is submitted and the REVERT is asserted, rather than skipped.
        bytes32 key = _factKey(facilityId, kind, payload);
        if (kind != IAttestationOracle.AttestationKind.Valuation) {
            IAttestationOracle.FactStatus modelled = ghostFactStatus[key];
            if (modelled != IAttestationOracle.FactStatus.None) {
                vm.expectRevert(
                    abi.encodeWithSelector(IAttestationOracle.Oracle_FactAlreadyRealised.selector, key, modelled)
                );
                oracle.attest(a, sigs);
                ghostBlockedFactReplays++;
                if (modelled == IAttestationOracle.FactStatus.Revoked) ghostBlockedRevokedReplays++;
                callCount++;
                return;
            }
        }

        oracle.attest(a, sigs);
        assertTrue(oracle.digestUsed(digest), "NO-REPLAY: digest not consumed");

        ghostSatisfied[facilityId][kind] = true;
        ghostPayload[facilityId][kind] = payload;
        ghostAsOf[facilityId][kind] = asOf;
        if (kind == IAttestationOracle.AttestationKind.Valuation) ghostWatermark[facilityId] = asOf;
        _recordFact(facilityId, kind, payload, IAttestationOracle.FactStatus.Recorded);
        callCount++;
    }

    /// @notice C4-01 / C4-02 REACHABILITY ACTION. Takes a fact the model says has ALREADY been
    ///         realised and re-presents it under a FRESH nonce with a genuinely quorum-signed
    ///         bundle — the exact move that defeated `used[digest]`. The submission is made, not
    ///         skipped; the guard's revert is the assertion.
    /// @dev Deleting the guard in `AttestationOracle.attest` makes this go red immediately: the
    ///      `vm.expectRevert` is unmet on the first call. That is the reachability proof.
    function replayRealisedFact(uint256 pick, uint256 saltSeed) external {
        Fact storage f = facts[pick % facts.length]; // never empty: seeded in the constructor
        bytes32 key = _factKey(f.facilityId, f.kind, f.payload);
        IAttestationOracle.FactStatus modelled = ghostFactStatus[key];

        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: f.facilityId,
            kind: f.kind,
            payload: f.payload,
            asOf: uint64(block.timestamp),
            // a DIFFERENT nonce -> a DIFFERENT digest -> the level-1 replay guard is silent
            expiry: uint64(block.timestamp + 1 hours),
            nonce: uint256(keccak256(abi.encode(saltSeed, ++nonce)))
        });
        bytes[] memory sigs = _bundle(a);
        assertFalse(oracle.digestUsed(oracle.attestationDigest(a)), "C4-01: the replay digest IS fresh");

        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_FactAlreadyRealised.selector, key, modelled));
        oracle.attest(a, sigs);

        ghostBlockedFactReplays++;
        if (modelled == IAttestationOracle.FactStatus.Revoked) ghostBlockedRevokedReplays++;
        callCount++;
    }

    /// @notice C4-02 REACHABILITY ACTION — the governance-revocation scenario end to end, in one
    ///         call so it is reached deterministically rather than by luck. `replayRealisedFact`
    ///         alone could not reach it: only the newest payload per (facility, kind) is ever
    ///         revoked, so revoked keys are a vanishing fraction of the fact array and the
    ///         `afterInvariant` non-vacuity assertion correctly reported C4-02 as UNTESTED. That
    ///         is the vacuity trap working — do not "fix" it by relaxing the assertion.
    ///
    ///         Sequence: establish a fact, have GOVERNANCE REVOKE it, then immediately re-present
    ///         the identical fact under a fresh nonce with a quorum-valid bundle. Before the fix
    ///         that re-presentation was ACCEPTED, which is what made `revoke` cosmetic on 8 of the
    ///         9 kinds.
    function revokeThenReplayFact(uint256 facSeed, uint8 kindSeed, bytes32 payloadSeed) external {
        uint256 facilityId = facSeed % 3;
        // one-shot kinds only: Valuation's durability comes from the watermark, and
        // `replayStaleValuation` covers that path.
        uint8 k = kindSeed % 8;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(k < 5 ? k : k + 1);

        // ESTABLISH a fresh, never-seen fact for this slot (salted with the call counter so it is
        // always new — this is setup, not a skip of the illegal input that follows).
        bytes32 payload = keccak256(abi.encode("c4-02", payloadSeed, ++nonce));
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        oracle.attest(a, _bundle(a));
        ghostSatisfied[facilityId][kind] = true;
        ghostPayload[facilityId][kind] = payload;
        ghostAsOf[facilityId][kind] = a.asOf;
        _recordFact(facilityId, kind, payload, IAttestationOracle.FactStatus.Recorded);

        // GOVERNANCE REVOKES it.
        vm.prank(admin);
        oracle.revoke(facilityId, kind);
        ghostSatisfied[facilityId][kind] = false;
        _recordFact(facilityId, kind, payload, IAttestationOracle.FactStatus.Revoked);

        // THE ILLEGAL INPUT: the identical fact, fresh nonce, fresh digest, valid quorum.
        IAttestationOracle.AttestationInput memory replay = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        bytes[] memory sigs = _bundle(replay);
        assertFalse(oracle.digestUsed(oracle.attestationDigest(replay)), "C4-02: the replay digest IS fresh");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                _factKey(facilityId, kind, payload),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        oracle.attest(replay, sigs);

        assertFalse(oracle.isSatisfied(facilityId, kind), "C4-02: the revoked fact stayed dead");
        ghostBlockedFactReplays++;
        ghostBlockedRevokedReplays++;
        callCount++;
    }

    /// @notice R17-01 REACHABILITY ACTION — the shape in which the fact LEDGER is the ONLY guard.
    /// @dev WHY THIS EXISTS AS ITS OWN ACTION, and why removing it silently deletes real coverage.
    ///      `attest` refuses a realised fact on two DISJOINT paths: the fact ledger (permanent, per
    ///      payload) and the live-record shadow (`records[facility][kind].payload == a.payload`,
    ///      the in-place-upgrade degradation, which only ever remembers the NEWEST payload on a
    ///      slot). Every replay that arrives while the record still holds that payload is caught by
    ///      the shadow guard, so the ledger guard was DELETABLE with the entire C4-01 regression
    ///      file green — measured, 11 of 11 passing.
    ///
    ///      The shape where the ledger is load-bearing is an ordinary multi-event facility: fact A
    ///      lands and is SPENT, fact B lands on the same slot and overwrites the record, and A is
    ///      then re-signed under a fresh nonce. `used[digest]` is silent (fresh digest), the shadow
    ///      guard is silent (the record names B), and without the ledger the credit layer writes A
    ///      down a second time. This action drives exactly that order — establish, consume,
    ///      supersede, replay — and asserts the supersession held before submitting the illegal
    ///      input, so it cannot decay into a re-run of `replayRealisedFact`.
    /// @param facSeed Selects the facility slot.
    /// @param kindSeed Selects the one-shot kind (Valuation excluded: it is watermark-keyed).
    /// @param payloadSeed Fuzzes the two payloads.
    function replaySupersededFact(uint256 facSeed, uint8 kindSeed, bytes32 payloadSeed) external {
        uint256 facilityId = facSeed % 3;
        uint8 k = kindSeed % 8;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(k < 5 ? k : k + 1);

        // ── A: establish, then SPEND. The ledger holds `Consumed`; the record still holds A. ──
        bytes32 payloadA = keccak256(abi.encode("r17-01-A", payloadSeed, ++nonce));
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payloadA,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        oracle.attest(a, _bundle(a));
        _recordFact(facilityId, kind, payloadA, IAttestationOracle.FactStatus.Recorded);
        oracle.consume(facilityId, kind); // handler holds CREDIT_ROLE
        _recordFact(facilityId, kind, payloadA, IAttestationOracle.FactStatus.Consumed);

        // ── B: the SUPERSEDING fact. From here the shadow guard is blind to A. ──
        bytes32 payloadB = keccak256(abi.encode("r17-01-B", payloadSeed, ++nonce));
        IAttestationOracle.AttestationInput memory b = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payloadB,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        oracle.attest(b, _bundle(b));
        ghostSatisfied[facilityId][kind] = true;
        ghostPayload[facilityId][kind] = payloadB;
        ghostAsOf[facilityId][kind] = b.asOf;
        _recordFact(facilityId, kind, payloadB, IAttestationOracle.FactStatus.Recorded);

        // NOT VACUOUS: if the record did not actually move on, this action degenerates into
        // `replayRealisedFact` and proves nothing about the ledger guard.
        (bytes32 livePayload,,) = oracle.latestPayload(facilityId, kind);
        assertEq(livePayload, payloadB, "R17-01: reach action failed to supersede -- it would be vacuous");

        // ── THE ILLEGAL INPUT: fact A again, fresh nonce, quorum-valid, record moved on. ──
        IAttestationOracle.AttestationInput memory replay = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payloadA,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        bytes[] memory sigs = _bundle(replay);
        assertFalse(oracle.digestUsed(oracle.attestationDigest(replay)), "R17-01: the replay digest IS fresh");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                _factKey(facilityId, kind, payloadA),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, sigs);

        ghostBlockedFactReplays++;
        ghostBlockedSupersededReplays++;
        callCount++;
    }

    /// @notice The 9th kind's mirror image. `Valuation` is excluded from the fact ledger by design,
    ///         so its replay must be blocked by the H-02 WATERMARK instead. Re-presents a mark at
    ///         an `asOf` at or below the watermark and asserts the stale guard catches it — proving
    ///         no kind is left with an unguarded replay path.
    function replayStaleValuation(uint256 facSeed, uint256 valueSeed) external {
        uint256 facilityId = facSeed % 3;
        uint64 mark = ghostWatermark[facilityId];
        uint64 live = ghostAsOf[facilityId][IAttestationOracle.AttestationKind.Valuation];
        if (live > mark) mark = live;
        if (mark == 0) {
            // no mark yet for this facility: establish one, so the next visit lands in the
            // illegal region. (This is the ESTABLISHING branch, not a skip of the illegal input.)
            uint64 asOf = uint64(block.timestamp);
            if (asOf == 0) return;
            IAttestationOracle.AttestationInput memory seed = IAttestationOracle.AttestationInput({
                facilityId: facilityId,
                kind: IAttestationOracle.AttestationKind.Valuation,
                payload: bytes32(uint256(bound(valueSeed, 1, 1e30))),
                asOf: asOf,
                expiry: uint64(block.timestamp + 1 hours),
                nonce: ++nonce
            });
            oracle.attest(seed, _bundle(seed));
            ghostSatisfied[facilityId][IAttestationOracle.AttestationKind.Valuation] = true;
            ghostPayload[facilityId][IAttestationOracle.AttestationKind.Valuation] = seed.payload;
            ghostAsOf[facilityId][IAttestationOracle.AttestationKind.Valuation] = asOf;
            ghostWatermark[facilityId] = asOf;
            callCount++;
            return;
        }

        // squarely inside the illegal region: an observation no newer than the watermark
        uint64 staleAsOf = uint64(bound(valueSeed, 1, mark));
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(uint256(bound(valueSeed, 1, 1e30))),
            asOf: staleAsOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonce
        });
        bytes[] memory sigs = _bundle(a);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, staleAsOf, mark));
        oracle.attest(a, sigs);
        ghostBlockedStaleValuations++;
        callCount++;
    }

    function consumeFact(uint256 facSeed, uint8 kindSeed) external {
        uint256 facilityId = facSeed % 3;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(kindSeed % 9);
        if (!ghostSatisfied[facilityId][kind]) return;
        bytes32 payload = ghostPayload[facilityId][kind];
        oracle.consume(facilityId, kind); // handler holds CREDIT_ROLE
        ghostSatisfied[facilityId][kind] = false; // payload/asOf retained (audit)
        // C4-01: consumption is terminal for the FACT, not just for the satisfied flag.
        _recordFact(facilityId, kind, payload, IAttestationOracle.FactStatus.Consumed);
        callCount++;
    }

    function revokeFact(uint256 facSeed, uint8 kindSeed) external {
        uint256 facilityId = facSeed % 3;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(kindSeed % 9);
        if (!ghostSatisfied[facilityId][kind] && ghostPayload[facilityId][kind] == bytes32(0)) return;
        bytes32 payload = ghostPayload[facilityId][kind];
        vm.prank(admin);
        oracle.revoke(facilityId, kind);
        ghostSatisfied[facilityId][kind] = false;
        // C4-02: revocation must leave a DURABLE tombstone on the one-shot kinds (no-op for
        // Valuation, whose durability comes from the watermark seeded in the branch below).
        _recordFact(facilityId, kind, payload, IAttestationOracle.FactStatus.Revoked);
        if (kind == IAttestationOracle.AttestationKind.Valuation) {
            // H-02: seed the watermark from the live mark before wiping, exactly as the
            // contract does -- the monotonic clock must survive an emergency revocation.
            uint64 live = ghostAsOf[facilityId][kind];
            if (live > ghostWatermark[facilityId]) ghostWatermark[facilityId] = live;
            ghostPayload[facilityId][kind] = bytes32(0);
            ghostAsOf[facilityId][kind] = 0;
        }
        callCount++;
    }

    function setThreshold(uint8 kindSeed, uint8 m) external {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(kindSeed % 9);
        // the high-value kinds are floored at 2-of-n (audit fix) — bound accordingly so
        // this bounded handler never trips Oracle_BadThreshold
        bool highValue = kind == IAttestationOracle.AttestationKind.CreditIssued
            || kind == IAttestationOracle.AttestationKind.Valuation
            || kind == IAttestationOracle.AttestationKind.PaymentReceived
            || kind == IAttestationOracle.AttestationKind.DefaultDeclared
            || kind == IAttestationOracle.AttestationKind.LossRealized
            || kind == IAttestationOracle.AttestationKind.PastDueCured
            || kind == IAttestationOracle.AttestationKind.TermsAmended;
        m = uint8(bound(m, highValue ? 2 : 1, 3));
        vm.prank(admin);
        oracle.setThreshold(kind, m);
        callCount++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 minutes, 7 days);
        vm.warp(block.timestamp + secs);
        callCount++;
    }
}
