// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @title R17-01 — the C4-01 PRIMARY LEDGER GUARD, pinned where it is the ONLY guard
/// @notice THE DEFECT THIS FILE EXISTS FOR IS A COVERAGE DEFECT, and it is the same class that has
///         recurred in every round of this engagement: a guard that can be deleted with its own
///         regression suite green.
///
///         MEASURED, on the merged tree before this file existed. Replace
///
///             if (status != FactStatus.None) revert Oracle_FactAlreadyRealised(factKey_, status);
///
///         in `AttestationOracle.attest` with
///
///             if (status == FactStatus.Revoked) revert Oracle_FactAlreadyRealised(factKey_, status);
///
///         — i.e. delete the ENTIRE C4-01 half of the guard, keeping only the C4-02 tombstone —
///         and `test/audit/Fix_C401-fact-realised-once.t.sol` runs 11 passed / 0 failed, including
///         its headline economic repro `test_c401_oneRealLossCannotBeWrittenDownTwice`.
///
///         WHY IT STAYS GREEN. `attest` refuses a realised fact on TWO disjoint paths:
///           1. the fact LEDGER — `factStatuses[(facility, kind, payload)]`, which remembers every
///              fact ever realised, for ever; and
///           2. the LIVE-RECORD shadow — `records[facility][kind].payload == a.payload`, the
///              in-place-upgrade degradation, which remembers only the MOST RECENT fact per slot.
///         Every replay in the original suite is presented while the record still holds that very
///         payload, so path 2 catches all of them and path 1 is never the load-bearing one. The
///         two paths even report the same `FactStatus` in those states, so not one assertion moves.
///
///         WHERE PATH 1 IS THE ONLY GUARD — and it is the ordinary case, not a corner. The record
///         slot holds ONE payload per (facility, kind). A facility with TWO events of one kind —
///         two partial write-downs, two servicing payments, two amendments — has its first fact's
///         record overwritten by its second. From that moment the shadow guard is blind to fact 1
///         while the ledger still holds it. Re-signing fact 1 under a fresh nonce then walks past
///         `used[digest]` (fresh digest), past the shadow guard (record has moved on), and
///         `DefaultManager.realizeLoss` writes tranche 1 down A SECOND TIME. That is the original
///         C4-01 harm, alive in the shape the regression suite never visited.
///
///         The first test below drives that to completion IN MONEY rather than asserting a bare
///         revert, so deleting the guard reports "outstanding fell by 3 x LOSS for 2 real losses".
contract FixC401bSupersededFactTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 2_000_000e18;
    uint256 internal constant LOSS = 300_000e18;
    bytes32 internal constant EVIDENCE_1 = keccak256("r17-01-workout-tranche-1");
    bytes32 internal constant EVIDENCE_2 = keccak256("r17-01-workout-tranche-2");

    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev The SAME economic fact under a FRESH nonce — the move the digest guard cannot see.
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

    /// @notice THE ECONOMIC REPRO FOR THE PRIMARY LEDGER GUARD. Two genuinely distinct write-downs
    ///         land (the liveness case the C4-01 fix deliberately preserves), which SUPERSEDES
    ///         tranche 1 in the record slot. Tranche 1 is then re-signed under a fresh nonce. Only
    ///         the fact ledger stands between that bundle and a third write-down of a loss that
    ///         happened twice.
    /// @dev Written to MEASURE THE DAMAGE: the replay goes in via a low-level call and, if it is
    ///      accepted, the exploit is carried through `realizeLoss` so the red reads in money.
    function test_r1701_supersededLossFactCannotBeWrittenDownAgain() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 outstandingBefore = reserves.deployedTo(id);

        // ── two REAL, DISTINCT loss events, exactly as operations are required to file them ──
        _realizeLoss(id, LOSS, EVIDENCE_1);
        _realizeLoss(id, LOSS, EVIDENCE_2);
        uint256 outstandingAfter = reserves.deployedTo(id);
        uint256 vaultAfter = vault.totalAssets();
        assertEq(outstandingAfter, outstandingBefore - 2 * LOSS, "precondition: two real losses, two write-downs");

        bytes32 payload1 = keccak256(abi.encode(id, LOSS, EVIDENCE_1));
        bytes32 payload2 = keccak256(abi.encode(id, LOSS, EVIDENCE_2));

        // THE CRUX: the record slot has MOVED ON to tranche 2, so the live-record shadow guard is
        // structurally blind to tranche 1. If this assertion ever fails the test has stopped
        // testing the ledger guard and is testing the shadow guard again.
        (bytes32 livePayload,,) = realOracle.latestPayload(id, IAttestationOracle.AttestationKind.LossRealized);
        assertEq(livePayload, payload2, "NOT TESTING THE LEDGER GUARD: the record still holds tranche 1");
        assertTrue(livePayload != payload1, "tranche 1 must be superseded for this test to mean anything");

        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _resignSameFact(id, IAttestationOracle.AttestationKind.LossRealized, payload1, 0x1701);
        assertFalse(realOracle.digestUsed(realOracle.attestationDigest(a)), "R17-01: the replay digest IS fresh");

        (bool accepted,) = address(realOracle).call(abi.encodeCall(AttestationOracle.attest, (a, sigs)));
        if (accepted) {
            vm.prank(servicer);
            defaultManager.realizeLoss(id, LOSS, EVIDENCE_1);
        }
        assertEq(reserves.deployedTo(id), outstandingAfter, "R17-01: TWO real losses, THREE write-downs");
        assertEq(vault.totalAssets(), vaultAfter, "R17-01: seniors burned a third time for two losses");
        assertFalse(accepted, "R17-01: a SUPERSEDED fact must not be re-presentable under a fresh nonce");

        // and the ledger reports the honest reason
        bytes32 key = realOracle.factKey(id, IAttestationOracle.AttestationKind.LossRealized, payload1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector, key, IAttestationOracle.FactStatus.Consumed
            )
        );
        realOracle.attest(a, sigs);

        // defence in depth: no standing fact for tranche 1 means the credit path refuses it too
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        vm.prank(servicer);
        defaultManager.realizeLoss(id, LOSS, EVIDENCE_1);
        assertEq(reserves.deployedTo(id), outstandingAfter, "R17-01: still exactly two write-downs");
    }

    /// @notice The mirror liveness case, so the guard is not read as "one fact per facility ever":
    ///         a THIRD genuinely distinct loss still lands after the replay has been refused.
    function test_r1701_supersedingDoesNotBlockGenuinelyNewFacts() public {
        _seedSeniors(3_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 outstandingBefore = reserves.deployedTo(id);
        _realizeLoss(id, LOSS, EVIDENCE_1);
        _realizeLoss(id, LOSS, EVIDENCE_2);
        _realizeLoss(id, LOSS, keccak256("r17-01-workout-tranche-3"));
        assertEq(reserves.deployedTo(id), outstandingBefore - 3 * LOSS, "three distinct events, three write-downs");
    }
}

/// @title R17-01 at the oracle surface — the shadow guard cannot see a superseded fact
/// @notice The contract-level half. Proves the STRUCTURAL claim the economic test rests on: once a
///         second fact lands on a (facility, kind) slot, the live-record shadow guard is silent on
///         the first, so the ledger is the sole remaining refusal. Asserted for every one-shot
///         kind, and asserted for BOTH the Recorded and the Consumed lifecycle states.
contract FixC401bOracleSupersessionTest is Test {
    AttestationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal creditModule = makeAddr("creditModule");

    uint256 internal pk1 = 0x1701A;
    uint256 internal pk2 = 0x1701B;
    uint256 internal nonceCounter;

    uint256 internal constant FACILITY = 77;

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

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
    }

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

    /// @dev Non-Valuation kinds only (0..8 skipping 5).
    function _eventKind(uint8 k) internal pure returns (IAttestationOracle.AttestationKind) {
        return IAttestationOracle.AttestationKind(k < 5 ? k : k + 1);
    }

    /// @notice For each of the 8 one-shot kinds: land fact A, land fact B on the SAME slot (which
    ///         supersedes A in the record), then replay A. The shadow guard cannot fire — the
    ///         record holds B — so the revert can only come from the fact ledger.
    function test_r1701_supersededFactIsRefusedOnEveryOneShotKind() public {
        for (uint8 k = 0; k < 8; ++k) {
            IAttestationOracle.AttestationKind kind = _eventKind(k);
            bytes32 payloadA = keccak256(abi.encode("superseded", k));
            bytes32 payloadB = keccak256(abi.encode("superseding", k));

            IAttestationOracle.AttestationInput memory first = _input(kind, payloadA);
            oracle.attest(first, _bundle(first));
            IAttestationOracle.AttestationInput memory second = _input(kind, payloadB);
            oracle.attest(second, _bundle(second));

            // the structural precondition: the shadow guard's only input now names B, not A
            (bytes32 livePayload,,) = oracle.latestPayload(FACILITY, kind);
            assertEq(livePayload, payloadB, "NOT TESTING THE LEDGER: the record did not move on");

            IAttestationOracle.AttestationInput memory replay = _input(kind, payloadA);
            bytes[] memory sigs = _bundle(replay);
            assertFalse(oracle.digestUsed(oracle.attestationDigest(replay)), "R17-01: the replay digest is fresh");
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                    oracle.factKey(FACILITY, kind, payloadA),
                    IAttestationOracle.FactStatus.Recorded
                )
            );
            oracle.attest(replay, sigs);

            // the superseding fact is untouched: this is a refusal, not a slot-wide freeze
            assertTrue(oracle.isSatisfied(FACILITY, kind), "the standing fact must survive the refusal");
        }
    }

    /// @notice The CONSUMED variant — the shape that produces the double write-down in the credit
    ///         layer, since consumption clears `satisfied` but leaves the payload behind, and the
    ///         next fact then overwrites that payload.
    function test_r1701_supersededConsumedFactIsRefused() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.PaymentReceived;
        bytes32 payloadA = keccak256("payment-11");
        bytes32 payloadB = keccak256("payment-12");

        IAttestationOracle.AttestationInput memory a = _input(kind, payloadA);
        oracle.attest(a, _bundle(a));
        vm.prank(creditModule);
        oracle.consume(FACILITY, kind);
        assertEq(
            uint256(oracle.factStatus(FACILITY, kind, payloadA)),
            uint256(IAttestationOracle.FactStatus.Consumed),
            "precondition: payment 11 is spent"
        );

        IAttestationOracle.AttestationInput memory b = _input(kind, payloadB);
        oracle.attest(b, _bundle(b));
        (bytes32 livePayload,,) = oracle.latestPayload(FACILITY, kind);
        assertEq(livePayload, payloadB, "NOT TESTING THE LEDGER: the record did not move on");

        IAttestationOracle.AttestationInput memory replay = _input(kind, payloadA);
        bytes[] memory sigs = _bundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, payloadA),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, sigs);
    }

    /// @notice The C4-02 half of the same shape: a REVOKED fact that has since been superseded is
    ///         still dead. Without the ledger the tombstone would be reachable only while the
    ///         revoked payload happened to be the newest one on its slot.
    function test_r1701_supersededRevokedFactStaysDead() public {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.LossRealized;
        bytes32 payloadA = keccak256("false-loss");
        bytes32 payloadB = keccak256("true-loss");

        IAttestationOracle.AttestationInput memory a = _input(kind, payloadA);
        oracle.attest(a, _bundle(a));
        vm.prank(admin);
        oracle.revoke(FACILITY, kind);

        IAttestationOracle.AttestationInput memory b = _input(kind, payloadB);
        oracle.attest(b, _bundle(b));
        (bytes32 livePayload,,) = oracle.latestPayload(FACILITY, kind);
        assertEq(livePayload, payloadB, "NOT TESTING THE LEDGER: the record did not move on");

        IAttestationOracle.AttestationInput memory replay = _input(kind, payloadA);
        bytes[] memory sigs = _bundle(replay);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(FACILITY, kind, payloadA),
                IAttestationOracle.FactStatus.Revoked
            )
        );
        oracle.attest(replay, sigs);
    }
}
