// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {OracleHandler} from "./handlers/OracleHandler.sol";

/// @dev Stateful-fuzz invariants for the REAL AttestationOracle against an independent
///      ghost state model (CLAUDE.md §1.3 — the mint gate and every attested gate
///      stand on these properties):
///      - PARITY:      isSatisfied / latestPayload / latestValuation always equal the
///                     ghost model built from the handler's accepted submissions —
///                     no fact appears without threshold signatures, none disappears
///                     without consume/revoke
///      - NO REPLAY:   every accepted digest is consumed forever (per-call assert)
///      - MONOTONE:    valuation asOf strictly increases per facility (per-call)
contract OracleInvariants is Test {
    AttestationOracle internal oracle;
    OracleHandler internal handler;
    address internal admin = makeAddr("admin");
    uint256 internal seededCallCount;

    function setUp() public {
        vm.warp(1_750_000_000);
        oracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (admin, makeAddr("guardian"), admin))
                )
            )
        );
        handler = new OracleHandler(oracle, admin);
        vm.startPrank(admin);
        oracle.grantRole(Roles.CREDIT_ROLE, address(handler));
        vm.stopPrank();
        targetContract(address(handler));
        bytes4[] memory selectors = _oracleSelectors();
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Deterministic anti-vacuity. `afterInvariant` runs after every independent campaign
        // execution, so asking its random selector schedule to hit all four specialised replay
        // actions made a valid run probabilistically red. Execute each illegal region through the
        // real handler and oracle once in the snapshot instead; every call below retains its exact
        // expected-revert assertion and updates the independent ghost model.
        handler.replayRealisedFact(0, 1);
        handler.revokeThenReplayFact(1, 1, bytes32(uint256(0xC402)));
        handler.replayStaleValuation(2, 1);
        handler.replayStaleValuation(2, 1);
        handler.replaySupersededFact(2, 2, bytes32(uint256(0x171)));
        seededCallCount = handler.callCount();
    }

    function _oracleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = OracleHandler.attestFact.selector;
        selectors[1] = OracleHandler.consumeFact.selector;
        selectors[2] = OracleHandler.revokeFact.selector;
        selectors[3] = OracleHandler.setThreshold.selector;
        selectors[4] = OracleHandler.warp.selector;
        // C4-01 / C4-02: the two actions that drive INTO the illegal region. Removing either
        // silently deletes this campaign's only stateful coverage of fact-level replay.
        selectors[5] = OracleHandler.replayRealisedFact.selector;
        selectors[6] = OracleHandler.replayStaleValuation.selector;
        selectors[7] = OracleHandler.revokeThenReplayFact.selector;
        // AUDIT R17-01: the ONLY action that reaches the shape where the fact LEDGER is the sole
        // refusal (the live-record shadow guard structurally cannot fire once the slot has moved
        // on). Without it the ledger guard is deletable with the whole C4-01 regression file
        // green — measured. Registering the selector is the whole point; adding the handler
        // function alone changes nothing here.
        selectors[8] = OracleHandler.replaySupersededFact.selector;
    }

    /// @notice Pins the exact selector set used by `targetSelector`. Reach witnesses are seeded
    ///         deterministically above, but removing their stateful fuzz actions must still fail.
    function test_wiring_everyOracleActionIsRegistered() public pure {
        bytes4[] memory selectors = _oracleSelectors();
        assertEq(selectors.length, 9);
        assertEq(selectors[0], OracleHandler.attestFact.selector);
        assertEq(selectors[1], OracleHandler.consumeFact.selector);
        assertEq(selectors[2], OracleHandler.revokeFact.selector);
        assertEq(selectors[3], OracleHandler.setThreshold.selector);
        assertEq(selectors[4], OracleHandler.warp.selector);
        assertEq(selectors[5], OracleHandler.replayRealisedFact.selector);
        assertEq(selectors[6], OracleHandler.replayStaleValuation.selector);
        assertEq(selectors[7], OracleHandler.revokeThenReplayFact.selector);
        assertEq(selectors[8], OracleHandler.replaySupersededFact.selector);
    }

    /// @notice The setup snapshot itself executes every specialised illegal-region witness.
    function test_seedExercisesEveryOracleIllegalRegion() public view {
        assertGt(handler.ghostBlockedFactReplays(), 0);
        assertGt(handler.ghostBlockedRevokedReplays(), 0);
        assertGt(handler.ghostBlockedStaleValuations(), 0);
        assertGt(handler.ghostBlockedSupersededReplays(), 0);
        assertEq(handler.callCount(), seededCallCount);
    }

    /// @notice INVARIANT (differential parity): the oracle's entire visible state
    ///         equals the ghost model at every boundary — facts require threshold
    ///         signatures and vanish only via consume/revoke.
    function invariant_oracle_ghostParity() public view {
        for (uint256 f = 0; f < 3; ++f) {
            for (uint8 k = 0; k < 8; ++k) {
                IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(k);
                assertEq(oracle.isSatisfied(f, kind), handler.ghostSatisfied(f, kind), "SATISFIED DIVERGED FROM MODEL");
                (bytes32 payload, uint64 asOf,) = oracle.latestPayload(f, kind);
                assertEq(payload, handler.ghostPayload(f, kind), "PAYLOAD DIVERGED");
                assertEq(asOf, handler.ghostAsOf(f, kind), "ASOF DIVERGED");
            }
            (uint256 value, uint64 vAsOf) = oracle.latestValuation(f);
            assertEq(
                value,
                uint256(handler.ghostPayload(f, IAttestationOracle.AttestationKind.Valuation)),
                "VALUATION VALUE DIVERGED"
            );
            assertEq(
                vAsOf, handler.ghostAsOf(f, IAttestationOracle.AttestationKind.Valuation), "VALUATION ASOF DIVERGED"
            );
        }
    }

    /// @notice INVARIANT (H-02): the valuation high-watermark never regresses, and matches an
    ///         independent ghost that tracks it across attest / consume / revoke.
    /// @dev The watermark is the sole thing standing between an emergency `revoke` and the
    ///      replay of an older but validly-signed mark straight into
    ///      `ReserveManager.totalBackingValue()`.

    function invariant_oracle_watermarkNeverRegresses() public view {
        for (uint256 f = 0; f <= 3; ++f) {
            assertEq(
                oracle.valuationWatermark(f),
                handler.ghostWatermark(f),
                "H-02: valuation watermark diverged from the independent ghost"
            );
        }
    }

    /// @notice INVARIANT (C4-01 / C4-02): every economic fact the model has seen realised is, in
    ///         the contract, in a state `attest` refuses — and it NEVER returns to `None`. This is
    ///         the "one real loss, one write-down" property at the layer that produces it.
    /// @dev The ghost is keyed exactly as the contract keys it: (facility, kind, payload), with
    ///      the digest's nonce/asOf/expiry salt excluded. Divergence here means either a fact came
    ///      back to life (the finding) or the key drifted from the contract's.
    function invariant_oracle_factLedgerIsConsumeOnce() public view {
        uint256 n = handler.factCount();
        for (uint256 i = 0; i < n; ++i) {
            (uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload) = handler.factAt(i);
            IAttestationOracle.FactStatus onChain = oracle.factStatus(facilityId, kind, payload);
            assertEq(
                uint256(onChain),
                uint256(handler.ghostFactStatus(oracle.factKey(facilityId, kind, payload))),
                "C4-01: fact ledger diverged from the independent ghost"
            );
            assertTrue(
                onChain != IAttestationOracle.FactStatus.None,
                "C4-01: a realised fact returned to None -- it is re-attestable again"
            );
        }
    }

    /// @notice INVARIANT (C4-01, non-vacuity): the campaign must actually REACH the illegal
    ///         region, not merely avoid it. Six vacuous suites have been caught in this
    ///         engagement; a pre-filtered handler would make the invariant above decoration.
    function afterInvariant() public view {
        assertGt(handler.callCount(), seededCallCount, "VACUOUS: oracle handler executed no fuzz action");
        assertGt(
            handler.ghostBlockedFactReplays(),
            0,
            "VACUOUS: no already-realised fact was ever re-presented -- C4-01 is untested here"
        );
        assertGt(
            handler.ghostBlockedRevokedReplays(),
            0,
            "VACUOUS: no REVOKED fact was ever re-presented -- C4-02 is untested here"
        );
        assertGt(
            handler.ghostBlockedStaleValuations(),
            0,
            "VACUOUS: the 9th kind's watermark replay path was never exercised"
        );
        // AUDIT R17-01. Without this the campaign can satisfy every assertion above using only
        // replays the LIVE-RECORD shadow guard already catches, and the primary fact-ledger guard
        // stays deletable. This counter only advances on replays where the record has provably
        // moved on, i.e. where the ledger is the sole refusal.
        assertGt(
            handler.ghostBlockedSupersededReplays(),
            0,
            "VACUOUS: no SUPERSEDED fact was ever re-presented -- the fact ledger is untested here"
        );
    }
}
