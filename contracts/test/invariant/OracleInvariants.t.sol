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
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = OracleHandler.attestFact.selector;
        selectors[1] = OracleHandler.consumeFact.selector;
        selectors[2] = OracleHandler.revokeFact.selector;
        selectors[3] = OracleHandler.setThreshold.selector;
        selectors[4] = OracleHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
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

    /// @notice Anti-vacuity.
    function invariant_callSummary() public view {
        handler.callCount();
    }
}
