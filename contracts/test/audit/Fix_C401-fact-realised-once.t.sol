// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @title C4-01 / C4-02 — one real loss must be written down ONCE, and `revoke` must be DURABLE
/// @notice REGRESSION SUITE for the campaign-4 High finding.
///
///         C4-01 — THE BUG. `AttestationOracle` burned the EIP-712 DIGEST (`$.used[digest]`), not
///         the underlying economic FACT. `nonce`, `asOf` and `expiry` all sit INSIDE the digest but
///         OUTSIDE the fact, so the identical real-world event — same facility, same kind, same
///         payload commitment — re-signed by the same attester quorum under a fresh `nonce`
///         produced a FRESH digest, sailed past `used[digest]`, and re-satisfied the record. The
///         credit layer then consumed it a second time. `DefaultManager.realizeLoss` gates on
///         `keccak256(tokenId, loss, evidenceHash)`, so ONE real loss was cascaded through the
///         curator pool, the sGROVE backstop and depositor principal TWICE, and
///         `reserves.recordPrincipalWritedown` was applied twice for a single write-down.
///
///         C4-02 — THE SECOND BUG, same root cause. `revoke` cleared `r.satisfied` and nothing
///         else. On 8 of the 9 kinds that made revocation cosmetic: the identical bundle re-signed
///         under a fresh nonce walked straight back in. Only `Valuation` was durable, and only
///         because H-02's high-watermark — a FACT-LEVEL key — already sat outside the digest.
///
///         THE FIX, and WHY THIS KEY. Consumption is now keyed on
///         `keccak256(facilityId, uint8(kind), payload)`: the economic fact, digest salt excluded.
///         A fact leaves `FactStatus.None` exactly once and never returns.
///           - Why not the digest: proved wrong here — it is the salt, not the fact.
///           - Why not (fact, asOf): two signings of one event carry different observation times,
///             so it degenerates back to the same bypass.
///           - Why the payload is the right fact identity: every one-shot kind's payload already
///             commits to its event identity — PaymentReceived to the payment id, TermsAmended to
///             the amendment id, DefaultDeclared/LossRealized/PastDueCured to an EVIDENCE HASH.
///           - Why `Valuation` is EXCLUDED: it is a monotone OBSERVATION SERIES, not a one-shot
///             event, and two genuinely distinct marks legitimately carry the identical value. Its
///             correct uniqueness key is the H-02 watermark (facility, asOf), which already blocks
///             re-presentation. Keying it on the payload would permanently freeze a facility's
///             mark at the first repeated value — a real liveness break, not a theoretical one.
///
///         THE LIVENESS CONSEQUENCE, stated plainly because it is now BINDING ON OPERATIONS: an
///         evidence hash must be unique per real-world event. Two partial write-downs of equal
///         size on one facility require two distinct evidence hashes. Reusing one FAILS CLOSED
///         (`Oracle_FactAlreadyRealised`) rather than double-writing-down, which is the correct
///         direction for a value-custody protocol; the remedy is to attest the second tranche
///         against its own evidence. `test_c401_distinctEvidenceStillAllowsTwoRealWriteDowns`
///         pins that the escape hatch works.
contract FixC401DoubleWriteDownTest is RealOracleFixture {
    uint256 internal constant FILM = 1;
    uint256 internal constant PRINCIPAL = 2_000_000e18;
    uint256 internal constant LOSS = 300_000e18;
    bytes32 internal constant EVIDENCE = keccak256("c4-01-workout-evidence");

    /// @dev Stakes seniors so the cascade's layer 3 has capacity and cannot revert for the wrong
    ///      reason (an absorption-capacity revert would mask the replay, not prove it).
    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev Builds the SAME economic fact under a FRESH nonce — the exact attacker/operator move
    ///      the digest guard could not see. Returns a signed, quorum-valid bundle.
    function _resignSameFact(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        uint256 freshNonce
    ) internal view returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: freshNonce
        });
        sigs = _signedBundle(a);
    }

    // ── C4-01: the economic repro ────────────────────────────────────────

    /// @notice THE HEADLINE REPRO, written to MEASURE THE DAMAGE rather than merely to assert a
    ///         revert. The replay is submitted with a low-level call; if the guard is absent the
    ///         test DRIVES THE EXPLOIT TO COMPLETION — it runs the second `realizeLoss` — so the
    ///         red reads "outstanding fell by 2 x LOSS" and "the vault was burned twice", which is
    ///         the finding itself. A revert-only assertion would have gone red without ever
    ///         showing that one real loss was written down twice.
    function test_c401_oneRealLossCannotBeWrittenDownTwice() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 outstandingBefore = reserves.deployedTo(id);
        uint256 vaultBefore = vault.totalAssets();

        // ── the one legitimate realization ──
        _realizeLoss(id, LOSS, EVIDENCE);
        uint256 outstandingAfter = reserves.deployedTo(id);
        uint256 vaultAfter = vault.totalAssets();
        assertEq(outstandingAfter, outstandingBefore - LOSS, "precondition: the genuine write-down landed once");
        assertLt(vaultAfter, vaultBefore, "precondition: the cascade really reached depositor principal");

        // ── the attack: identical fact, fresh nonce, therefore a FRESH DIGEST ──
        bytes32 payload = keccak256(abi.encode(id, LOSS, EVIDENCE));
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _resignSameFact(id, IAttestationOracle.AttestationKind.LossRealized, payload, 0xC401);

        // This is the crux of the finding: the DIGEST guard has nothing to say here.
        assertFalse(realOracle.digestUsed(realOracle.attestationDigest(a)), "C4-01: the replay digest IS fresh");

        (bool accepted,) = address(realOracle).call(abi.encodeCall(AttestationOracle.attest, (a, sigs)));
        if (accepted) {
            // The guard is gone. Carry the exploit through so the failure below reports the real
            // economic harm instead of a bare "expected revert".
            vm.prank(servicer);
            defaultManager.realizeLoss(id, LOSS, EVIDENCE);
        }
        // Economic assertion FIRST, deliberately: it is the one whose failure text states the
        // finding in money ("outstanding fell twice for one loss").
        assertEq(reserves.deployedTo(id), outstandingAfter, "C4-01: ONE real loss, ONE write-down");
        assertEq(vault.totalAssets(), vaultAfter, "C4-01: seniors burned exactly once");
        assertFalse(accepted, "C4-01: a fresh nonce over an ALREADY-REALISED fact must be rejected");

        // defence in depth: even a direct second `realizeLoss` finds no standing fact.
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        vm.prank(servicer);
        defaultManager.realizeLoss(id, LOSS, EVIDENCE);
        assertEq(reserves.deployedTo(id), outstandingAfter, "C4-01: still exactly one write-down");
    }

    /// @notice The same replay, asserted against the EXACT custom error and the EXACT ledger
    ///         state — so a future change that reverts for some incidental reason (out of gas,
    ///         a threshold change, an expiry) cannot masquerade as this guard still holding.
    function test_c401_replayRevertsWithTheFactLedgerErrorAndConsumedStatus() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _realizeLoss(id, LOSS, EVIDENCE);

        bytes32 payload = keccak256(abi.encode(id, LOSS, EVIDENCE));
        assertEq(
            uint256(realOracle.factStatus(id, IAttestationOracle.AttestationKind.LossRealized, payload)),
            uint256(IAttestationOracle.FactStatus.Consumed),
            "C4-01: the fact ledger records the spend"
        );

        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _resignSameFact(id, IAttestationOracle.AttestationKind.LossRealized, payload, 0xC401);
        bytes32 key = realOracle.factKey(id, IAttestationOracle.AttestationKind.LossRealized, payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector, key, IAttestationOracle.FactStatus.Consumed
            )
        );
        realOracle.attest(a, sigs);
    }

    /// @notice THE LIVENESS ESCAPE HATCH. Two genuinely distinct loss events of the SAME SIZE on
    ///         the same facility remain fully realizable — they simply need their own evidence.
    ///         Without this the fix would be a denial of service on ordinary partial workouts.
    function test_c401_distinctEvidenceStillAllowsTwoRealWriteDowns() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 outstandingBefore = reserves.deployedTo(id);
        _realizeLoss(id, LOSS, keccak256("tranche-1-evidence"));
        _realizeLoss(id, LOSS, keccak256("tranche-2-evidence")); // same amount, different EVENT

        assertEq(reserves.deployedTo(id), outstandingBefore - 2 * LOSS, "two distinct events, two write-downs");
    }

    // ── C4-02: durable revocation on the credit path ─────────────────────

    /// @notice A governance revocation of a discovered-false loss attestation must be DURABLE.
    ///         Before the fix the servicer (or any relayer holding a second signed copy) simply
    ///         re-presented the identical bundle under a fresh nonce and wrote the loss down
    ///         anyway — governance's emergency stop was cosmetic.
    function test_c402_revokedLossFactCannotBeRePresented() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _attestLoss(id, LOSS, EVIDENCE);
        bytes32 payload = keccak256(abi.encode(id, LOSS, EVIDENCE));
        assertTrue(realOracle.isSatisfied(id, IAttestationOracle.AttestationKind.LossRealized));

        // governance discovers the attestation is false and revokes it
        vm.prank(admin);
        realOracle.revoke(id, IAttestationOracle.AttestationKind.LossRealized);
        assertFalse(realOracle.isSatisfied(id, IAttestationOracle.AttestationKind.LossRealized));

        uint256 outstanding = reserves.deployedTo(id);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _resignSameFact(id, IAttestationOracle.AttestationKind.LossRealized, payload, 0xC402);
        assertFalse(realOracle.digestUsed(realOracle.attestationDigest(a)), "C4-02: the replay digest IS fresh");

        // As above: if revocation is not durable, DRIVE THE EXPLOIT so the red reports that the
        // revoked loss was written down anyway — governance's emergency stop being cosmetic is
        // the finding, and a bare "expected revert" would not say so.
        (bool accepted,) = address(realOracle).call(abi.encodeCall(AttestationOracle.attest, (a, sigs)));
        if (accepted) {
            vm.prank(servicer);
            defaultManager.realizeLoss(id, LOSS, EVIDENCE);
        }
        assertEq(reserves.deployedTo(id), outstanding, "C4-02: the revoked loss never landed");
        assertFalse(accepted, "C4-02: a revoked fact must not be re-presentable under a fresh nonce");
        assertEq(
            uint256(realOracle.factStatus(id, IAttestationOracle.AttestationKind.LossRealized, payload)),
            uint256(IAttestationOracle.FactStatus.Revoked),
            "C4-02: revocation leaves a durable tombstone"
        );

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        vm.prank(servicer);
        defaultManager.realizeLoss(id, LOSS, EVIDENCE);
        assertEq(reserves.deployedTo(id), outstanding, "C4-02: and still never lands");
    }
}

/// @title C4-01 / C4-02 at the oracle surface — every kind, every lifecycle state
/// @notice The contract-level half of the regression. Exercises the fact ledger directly against
///         a bare `AttestationOracle` so the property is pinned for ALL NINE kinds rather than
///         only the credit path that motivated the finding.
contract FixC401OracleFactLedgerTest is Test {
    AttestationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal creditModule = makeAddr("creditModule");

    uint256 internal pk1 = 0xC401A;
    uint256 internal pk2 = 0xC401B;
    uint256 internal nonceCounter;

    uint256 internal constant FACILITY = 42;

    function setUp() public {
        vm.warp(1_750_000_000);
        oracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (admin, guardian, admin))
                )
            )
        );
        vm.startPrank(admin);
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pk1));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pk2));
        oracle.grantRole(Roles.CREDIT_ROLE, creditModule);
        vm.stopPrank();
    }

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        internal
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
    }

    /// @dev A quorum-valid bundle at the kind's CURRENT threshold, signers sorted ascending.
    function _bundle(IAttestationOracle.AttestationInput memory a) internal view returns (bytes[] memory sigs) {
        uint8 m = oracle.threshold(a.kind);
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(pk1) < vm.addr(pk2) ? (pk1, pk2) : (pk2, pk1);
        sigs = new bytes[](m);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lo, digest);
        sigs[0] = abi.encodePacked(r, s, v);
        if (m > 1) {
            (v, r, s) = vm.sign(hi, digest);
            sigs[1] = abi.encodePacked(r, s, v);
        }
    }

    /// @dev Non-Valuation kinds only. Valuation is deliberately keyed on the H-02 watermark.
    function _eventKind(uint8 k) internal pure returns (IAttestationOracle.AttestationKind) {
        // 0..8 skipping 5 (Valuation)
        return IAttestationOracle.AttestationKind(k < 5 ? k : k + 1);
    }

    // ── C4-01 ───────────────────────────────────────────────────────────

    /// @notice For each of the 8 one-shot kinds: attest, then re-sign the IDENTICAL fact under a
    ///         fresh nonce. The digest differs; the fact does not; the second submission reverts.
    function test_c401_everyOneShotKindIsRealisedOnce() public {
        for (uint8 k = 0; k < 8; ++k) {
            IAttestationOracle.AttestationKind kind = _eventKind(k);
            bytes32 payload = keccak256(abi.encode("fact", k));

            IAttestationOracle.AttestationInput memory first = _input(kind, payload, uint64(block.timestamp));
            oracle.attest(first, _bundle(first));
            assertEq(
                uint256(oracle.factStatus(FACILITY, kind, payload)),
                uint256(IAttestationOracle.FactStatus.Recorded),
                "the fact is standing"
            );

            IAttestationOracle.AttestationInput memory replay = _input(kind, payload, uint64(block.timestamp));
            bytes[] memory sigs = _bundle(replay);
            assertFalse(oracle.digestUsed(oracle.attestationDigest(replay)), "C4-01: the replay digest is fresh");
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                    oracle.factKey(FACILITY, kind, payload),
                    IAttestationOracle.FactStatus.Recorded
                )
            );
            oracle.attest(replay, sigs);
        }
    }

    /// @notice The CONSUMED state is equally terminal — this is the shape that produced the
    ///         double write-down, since the credit layer clears `satisfied` on the way through.
    function test_c401_consumedFactCannotBeRestored() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.PaymentReceived;
        bytes32 payload = keccak256("payment-7");

        IAttestationOracle.AttestationInput memory a = _input(kind, payload, uint64(block.timestamp));
        oracle.attest(a, _bundle(a));
        vm.prank(creditModule);
        oracle.consume(FACILITY, kind);
        assertFalse(oracle.isSatisfied(FACILITY, kind), "consumed");
        assertEq(
            uint256(oracle.factStatus(FACILITY, kind, payload)),
            uint256(IAttestationOracle.FactStatus.Consumed),
            "the ledger records the spend"
        );

        IAttestationOracle.AttestationInput memory replay = _input(kind, payload, uint64(block.timestamp));
        bytes[] memory sigs = _bundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, sigs);
        assertFalse(oracle.isSatisfied(FACILITY, kind), "C4-01: a spent fact stays spent");
    }

    // ── C4-02 ───────────────────────────────────────────────────────────

    /// @notice Revocation is durable on all 8 one-shot kinds. Before the fix it was durable on
    ///         ZERO of them (only `Valuation`, via H-02, and that is the 9th).
    function test_c402_revokeIsDurableOnEveryOneShotKind() public {
        for (uint8 k = 0; k < 8; ++k) {
            IAttestationOracle.AttestationKind kind = _eventKind(k);
            bytes32 payload = keccak256(abi.encode("revoke-me", k));

            IAttestationOracle.AttestationInput memory a = _input(kind, payload, uint64(block.timestamp));
            oracle.attest(a, _bundle(a));
            vm.prank(admin);
            oracle.revoke(FACILITY, kind);
            assertEq(
                uint256(oracle.factStatus(FACILITY, kind, payload)),
                uint256(IAttestationOracle.FactStatus.Revoked),
                "C4-02: durable tombstone"
            );

            IAttestationOracle.AttestationInput memory replay = _input(kind, payload, uint64(block.timestamp));
            bytes[] memory sigs = _bundle(replay);
            assertFalse(oracle.digestUsed(oracle.attestationDigest(replay)), "C4-02: the replay digest is fresh");
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                    oracle.factKey(FACILITY, kind, payload),
                    IAttestationOracle.FactStatus.Revoked
                )
            );
            oracle.attest(replay, sigs);
            assertFalse(oracle.isSatisfied(FACILITY, kind), "C4-02: the revoked fact stayed dead");
        }
    }

    /// @notice The 9th kind. `Valuation` is EXCLUDED from the payload-keyed ledger on purpose —
    ///         its uniqueness key is the H-02 watermark. This pins BOTH halves of that decision:
    ///         the same mark value at a NEWER observation time still lands (liveness, which a
    ///         payload key would have destroyed), and the revoked observation itself cannot
    ///         return (durability, which is why revoke was already durable here).
    function test_c402_valuationStaysWatermarkKeyedNotPayloadKeyed() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.Valuation;
        bytes32 mark = bytes32(uint256(750_000e18));

        IAttestationOracle.AttestationInput memory a = _input(kind, mark, uint64(block.timestamp));
        oracle.attest(a, _bundle(a));
        assertEq(
            uint256(oracle.factStatus(FACILITY, kind, mark)),
            uint256(IAttestationOracle.FactStatus.None),
            "C4-01: valuations never enter the payload-keyed ledger"
        );

        vm.prank(admin);
        oracle.revoke(FACILITY, kind);

        // durability: the revoked OBSERVATION cannot come back (asOf <= watermark)
        IAttestationOracle.AttestationInput memory sameTime = _input(kind, mark, a.asOf);
        bytes[] memory staleSigs = _bundle(sameTime);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, a.asOf, a.asOf));
        oracle.attest(sameTime, staleSigs);

        // liveness: the SAME VALUE at a strictly newer observation time is a legitimate new mark
        vm.warp(block.timestamp + 1 days);
        IAttestationOracle.AttestationInput memory fresh = _input(kind, mark, uint64(block.timestamp));
        oracle.attest(fresh, _bundle(fresh));
        (uint256 value,) = oracle.latestValuation(FACILITY);
        assertEq(value, 750_000e18, "an unchanged mark must still be refreshable");
    }

    // ── boundaries ──────────────────────────────────────────────────────

    /// @notice The key is per (facility, kind, payload): none of the three may be conflated.
    ///         A collision here would either double-block (liveness) or double-allow (the bug).
    function testFuzz_c401_factKeyIsExactlyTheTriple(uint256 facA, uint256 facB, bytes32 payA, bytes32 payB)
        public
        view
    {
        IAttestationOracle.AttestationKind kindA = IAttestationOracle.AttestationKind.UCCFiled;
        IAttestationOracle.AttestationKind kindB = IAttestationOracle.AttestationKind.AssignmentExecuted;
        vm.assume(facA != facB && payA != payB);

        assertTrue(oracle.factKey(facA, kindA, payA) != oracle.factKey(facB, kindA, payA), "facility separates");
        assertTrue(oracle.factKey(facA, kindA, payA) != oracle.factKey(facA, kindB, payA), "kind separates");
        assertTrue(oracle.factKey(facA, kindA, payA) != oracle.factKey(facA, kindA, payB), "payload separates");
        // and the salt is absent by construction: the key takes no nonce/asOf/expiry at all
        assertEq(
            oracle.factKey(facA, kindA, payA),
            keccak256(abi.encode(facA, uint8(kindA), payA)),
            "C4-01: the key is the FACT, nothing else"
        );
    }

    /// @notice THE IN-PLACE UPGRADE PATH. A proxy that predates this fix carries live records but
    ///         an EMPTY fact ledger, so every already-realised fact would read `None` and be
    ///         replayable exactly once — the fix would arrive with a one-shot hole in it.
    ///         Modelled by wiping the ledger slot underneath a fact that has genuinely been
    ///         realised (`vm.store`), which is precisely the post-upgrade state. The degradation
    ///         in `attest` must still catch it off the standing record.
    /// @dev The ledger is `OracleStorage` member #4 (slots 0..4: records, thresholds, used,
    ///      valuationWatermarks, factStatuses), so its mapping base is ROOT + 4.
    function test_c401_legacyProxyWithAnEmptyLedgerStillBlocksTheReplay() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.LossRealized;
        bytes32 payload = keccak256("legacy-loss-fact");

        IAttestationOracle.AttestationInput memory a = _input(kind, payload, uint64(block.timestamp));
        oracle.attest(a, _bundle(a));
        vm.prank(creditModule);
        oracle.consume(FACILITY, kind);

        // ── simulate the pre-fix proxy: the record stands, the ledger entry does not exist ──
        bytes32 root = 0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00;
        bytes32 ledgerBase = bytes32(uint256(root) + 4);
        bytes32 slot = keccak256(abi.encode(oracle.factKey(FACILITY, kind, payload), ledgerBase));
        vm.store(address(oracle), slot, bytes32(0));
        assertEq(
            uint256(oracle.factStatus(FACILITY, kind, payload)),
            uint256(IAttestationOracle.FactStatus.None),
            "precondition: the ledger really is empty, as it would be right after an upgrade"
        );
        (bytes32 livePayload,,) = oracle.latestPayload(FACILITY, kind);
        assertEq(livePayload, payload, "precondition: but the pre-upgrade record still stands");

        // The replay must STILL be refused, off the record rather than off the ledger.
        IAttestationOracle.AttestationInput memory replay = _input(kind, payload, uint64(block.timestamp));
        bytes[] memory sigs = _bundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, sigs);

        // and a genuinely NEW fact on the same slot is unaffected (no upgrade-path lockout)
        IAttestationOracle.AttestationInput memory fresh =
            _input(kind, keccak256("a-later-loss"), uint64(block.timestamp));
        oracle.attest(fresh, _bundle(fresh));
        assertTrue(oracle.isSatisfied(FACILITY, kind), "the degradation must not block new facts");
    }

    /// @notice The same fact on a DIFFERENT facility is a different fact — the ledger must not
    ///         leak across facilities and freeze an unrelated loan's gate.
    function test_c401_ledgerDoesNotLeakAcrossFacilities() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.AssignmentExecuted;
        bytes32 payload = keccak256("shared-document-hash");

        IAttestationOracle.AttestationInput memory a = _input(kind, payload, uint64(block.timestamp));
        oracle.attest(a, _bundle(a));

        IAttestationOracle.AttestationInput memory other = _input(kind, payload, uint64(block.timestamp));
        other.facilityId = FACILITY + 1;
        oracle.attest(other, _bundle(other));
        assertTrue(oracle.isSatisfied(FACILITY + 1, kind), "a different facility is a different fact");
    }
}
