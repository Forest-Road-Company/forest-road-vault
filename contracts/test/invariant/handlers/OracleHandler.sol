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

    constructor(AttestationOracle oracle_, address admin_) {
        oracle = oracle_;
        admin = admin_;
        vm.startPrank(admin_);
        for (uint256 i = 0; i < 3; ++i) {
            oracle_.grantRole(Roles.ATTESTER_ROLE, vm.addr(pks[i]));
        }
        vm.stopPrank();
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

        uint8 m = oracle.threshold(kind);
        uint256[3] memory sorted = _sortedPks();
        bytes[] memory sigs = new bytes[](m);
        for (uint256 i = 0; i < m; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sorted[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
        oracle.attest(a, sigs);
        assertTrue(oracle.digestUsed(digest), "NO-REPLAY: digest not consumed");

        ghostSatisfied[facilityId][kind] = true;
        ghostPayload[facilityId][kind] = payload;
        ghostAsOf[facilityId][kind] = asOf;
        if (kind == IAttestationOracle.AttestationKind.Valuation) ghostWatermark[facilityId] = asOf;
        callCount++;
    }

    function consumeFact(uint256 facSeed, uint8 kindSeed) external {
        uint256 facilityId = facSeed % 3;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(kindSeed % 9);
        if (!ghostSatisfied[facilityId][kind]) return;
        oracle.consume(facilityId, kind); // handler holds CREDIT_ROLE
        ghostSatisfied[facilityId][kind] = false; // payload/asOf retained (audit)
        callCount++;
    }

    function revokeFact(uint256 facSeed, uint8 kindSeed) external {
        uint256 facilityId = facSeed % 3;
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind(kindSeed % 9);
        if (!ghostSatisfied[facilityId][kind] && ghostPayload[facilityId][kind] == bytes32(0)) return;
        vm.prank(admin);
        oracle.revoke(facilityId, kind);
        ghostSatisfied[facilityId][kind] = false;
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
