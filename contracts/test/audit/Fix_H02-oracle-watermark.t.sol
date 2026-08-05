// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev H-02 regression suite: `AttestationOracle.revoke()` must NOT rewind the
///      valuation anti-rollback high-watermark. Before the fix, revoking a bad or
///      compromised mark opened a window in which an OLDER but still validly-signed
///      mark could be replayed and become live — and since facility 0's mark feeds
///      `ReserveManager.totalBackingValue()`, that directly re-inflated backing.
///      Revocation must still zero the LIVE mark's value/validity (the emergency stop);
///      it just must not rewind the monotonic clock.
contract FixH02OracleWatermarkTest is Test {
    AttestationOracle internal oracle;
    ReserveManager internal reserves;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal usdfr = makeAddr("usdfr");

    uint256 internal pk1 = 0xA11CE;
    uint256 internal pk2 = 0xB0B;

    uint256 internal constant FACILITY = 1;
    uint256 internal constant OTHER_FACILITY = 2;
    uint256 internal constant RESERVE_INSTRUMENT_ID = 0;

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
        vm.stopPrank();
    }

    // ── the UPGRADE path (what the revoke-side seeding exists for) ───────

    /// @notice On a proxy that PREDATES this fix, `revoke` must still not open the window.
    /// @dev The seeding inside `revoke` is unreachable on a fresh deployment — `attest` always
    ///      advances the watermark, so it already dominates `r.asOf`. It exists solely for an
    ///      IN-PLACE UPGRADE, where a live mark stands (`r.asOf == T`) while the newly-added
    ///      watermark slot is still zero. Without seeding, revoking first would drop the floor
    ///      to zero and re-open exactly the rollback this fix closes. That state is constructed
    ///      here by zeroing the watermark slot directly, because no in-contract path can reach
    ///      it. Mutation-verified: deleting the seeding makes this test fail and nothing else.
    function test_h02_upgradedProxyWithAZeroWatermarkIsStillProtected() public {
        IAttestationOracle.AttestationInput memory oldMark =
            _valuation(FACILITY, bytes32(uint256(600_000e18)), uint64(block.timestamp - 120), 1);
        IAttestationOracle.AttestationInput memory newerMark =
            _valuation(FACILITY, bytes32(uint256(900_000e18)), uint64(block.timestamp - 60), 2);

        oracle.attest(newerMark, _sigs2(newerMark));

        // Simulate the pre-fix proxy: a live mark, but no watermark recorded yet.
        // Namespace base + 3 is `valuationWatermarks` (records, thresholds, used, then this).
        bytes32 base = 0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00;
        bytes32 slot = keccak256(abi.encode(FACILITY, uint256(base) + 3));
        vm.store(address(oracle), slot, bytes32(0));
        assertEq(oracle.valuationWatermark(FACILITY), 0, "constructed the legacy state");
        (, uint64 liveAsOf) = oracle.latestValuation(FACILITY);
        assertEq(liveAsOf, newerMark.asOf, "the live mark is untouched");

        // Revoke must SEED the watermark from the live mark on its way out.
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "revoke seeded the watermark");

        // ...so the older, validly-signed bundle still cannot be replayed.
        bytes[] memory staleSigs = _sigs2(oldMark);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, oldMark.asOf, newerMark.asOf)
        );
        oracle.attest(oldMark, staleSigs);
    }

    function test_h02_attestSeedsItsFloorFromALegacyLiveRecord() public {
        IAttestationOracle.AttestationInput memory liveMark =
            _valuation(FACILITY, bytes32(uint256(900_000e18)), uint64(block.timestamp - 60), 1);
        oracle.attest(liveMark, _sigs2(liveMark));

        // Simulate the exact in-place-upgrade state: the old record is live while the
        // newly appended watermark mapping still reads zero.
        bytes32 base = 0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00;
        bytes32 slot = keccak256(abi.encode(FACILITY, uint256(base) + 3));
        vm.store(address(oracle), slot, bytes32(0));

        IAttestationOracle.AttestationInput memory newerMark =
            _valuation(FACILITY, bytes32(uint256(950_000e18)), uint64(block.timestamp), 2);
        oracle.attest(newerMark, _sigs2(newerMark));
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf);
    }

    // ── the finding itself ───────────────────────────────────────────────

    /// @dev The exact PreMainnetFindings reproduction, now defeated.
    function test_h02_revokeDoesNotOpenARollbackWindow() public {
        IAttestationOracle.AttestationInput memory oldMark =
            _valuation(FACILITY, bytes32(uint256(600_000e18)), uint64(block.timestamp - 120), 1);
        IAttestationOracle.AttestationInput memory newerMark =
            _valuation(FACILITY, bytes32(uint256(900_000e18)), uint64(block.timestamp - 60), 2);

        oracle.attest(newerMark, _sigs2(newerMark));
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "watermark tracks the accepted mark");

        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        // the watermark survived the revocation ...
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "revoke must not rewind the watermark");
        // ... so the older, still validly signed bundle can no longer be replayed
        bytes[] memory sigs = _sigs2(oldMark);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, oldMark.asOf, newerMark.asOf)
        );
        oracle.attest(oldMark, sigs);

        (uint256 value, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(value, 0, "the revoked facility still has no live mark");
        assertEq(asOf, 0, "no live asOf after revocation");
    }

    // ── the emergency-stop behaviour that must be PRESERVED ──────────────

    function test_h02_revokeStillZeroesTheLiveMark() public {
        IAttestationOracle.AttestationInput memory mark =
            _valuation(FACILITY, bytes32(uint256(750_000e18)), uint64(block.timestamp), 3);
        oracle.attest(mark, _sigs2(mark));
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.Valuation));

        vm.expectEmit(true, true, false, true, address(oracle));
        emit IAttestationOracle.AttestationRevoked(FACILITY, IAttestationOracle.AttestationKind.Valuation);
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        (uint256 value, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(value, 0, "emergency stop: the mark's value is zeroed");
        assertEq(asOf, 0, "emergency stop: the live asOf is zeroed");
        assertFalse(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.Valuation));
        assertEq(oracle.valuationWatermark(FACILITY), mark.asOf, "only the clock survives");
    }

    /// @dev An honest, genuinely newer mark still lands after a revocation — the fix
    ///      must not brick the facility.
    function test_h02_strictlyNewerMarkStillLandsAfterRevoke() public {
        IAttestationOracle.AttestationInput memory mark =
            _valuation(FACILITY, bytes32(uint256(750_000e18)), uint64(block.timestamp), 4);
        oracle.attest(mark, _sigs2(mark));
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        vm.warp(block.timestamp + 1 hours);
        IAttestationOracle.AttestationInput memory fresh =
            _valuation(FACILITY, bytes32(uint256(400_000e18)), uint64(block.timestamp), 5);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit IAttestationOracle.AttestationSatisfied(
            FACILITY, IAttestationOracle.AttestationKind.Valuation, fresh.payload, fresh.asOf
        );
        oracle.attest(fresh, _sigs2(fresh));

        (uint256 value, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(value, 400_000e18);
        assertEq(asOf, fresh.asOf);
        assertTrue(oracle.isSatisfied(FACILITY, IAttestationOracle.AttestationKind.Valuation));
        assertEq(oracle.valuationWatermark(FACILITY), fresh.asOf, "watermark advances with the fresh mark");
    }

    // ── boundaries and scoping ───────────────────────────────────────────

    /// @dev Off-by-one around the watermark, after a revoke: equal is rejected,
    ///      watermark + 1 is accepted.
    function test_h02_watermarkBoundaryAfterRevoke() public {
        uint64 t = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory mark = _valuation(FACILITY, bytes32(uint256(100e18)), t, 6);
        oracle.attest(mark, _sigs2(mark));
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        vm.warp(uint256(t) + 10);
        IAttestationOracle.AttestationInput memory equalAsOf = _valuation(FACILITY, bytes32(uint256(200e18)), t, 7);
        bytes[] memory sigsEqual = _sigs2(equalAsOf);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, t, t));
        oracle.attest(equalAsOf, sigsEqual);

        IAttestationOracle.AttestationInput memory plusOne = _valuation(FACILITY, bytes32(uint256(200e18)), t + 1, 8);
        oracle.attest(plusOne, _sigs2(plusOne));
        (uint256 value, uint64 asOf) = oracle.latestValuation(FACILITY);
        assertEq(value, 200e18);
        assertEq(asOf, t + 1);
        assertEq(oracle.valuationWatermark(FACILITY), t + 1);
    }

    /// @dev The watermark is per-facility: revoking (or marking) one facility never
    ///      constrains another.
    function test_h02_watermarkIsPerFacility() public {
        uint64 t = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory a = _valuation(FACILITY, bytes32(uint256(1e18)), t, 9);
        oracle.attest(a, _sigs2(a));
        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        assertEq(oracle.valuationWatermark(OTHER_FACILITY), 0, "an unmarked facility has no watermark");
        IAttestationOracle.AttestationInput memory b = _valuation(OTHER_FACILITY, bytes32(uint256(2e18)), t - 500, 10);
        oracle.attest(b, _sigs2(b));
        (uint256 value, uint64 asOf) = oracle.latestValuation(OTHER_FACILITY);
        assertEq(value, 2e18);
        assertEq(asOf, t - 500);
        assertEq(oracle.valuationWatermark(FACILITY), t, "the other facility's watermark is untouched");
    }

    /// @dev `consume` (CREDIT_ROLE) must not rewind the clock either.
    function test_h02_watermarkSurvivesConsume() public {
        uint64 t = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory mark = _valuation(FACILITY, bytes32(uint256(300e18)), t, 13);
        oracle.attest(mark, _sigs2(mark));

        vm.prank(admin);
        oracle.grantRole(Roles.CREDIT_ROLE, address(this));
        oracle.consume(FACILITY, IAttestationOracle.AttestationKind.Valuation);
        assertEq(oracle.valuationWatermark(FACILITY), t, "consume keeps the watermark");

        IAttestationOracle.AttestationInput memory older = _valuation(FACILITY, bytes32(uint256(400e18)), t - 1, 14);
        bytes[] memory sigs = _sigs2(older);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, t - 1, t));
        oracle.attest(older, sigs);
    }

    /// @dev Non-Valuation kinds neither set nor are gated by the watermark (a revoked
    ///      documentary fact keeps its payload for audit, unchanged behaviour).
    function test_h02_nonValuationKindsAreUnaffected() public {
        uint64 t = uint64(block.timestamp);
        IAttestationOracle.AttestationInput memory doc = IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: IAttestationOracle.AttestationKind.AssignmentExecuted,
            payload: keccak256("assignment"),
            asOf: t,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: 15
        });
        bytes[] memory one = new bytes[](1);
        one[0] = _sign(pk1, doc);
        oracle.attest(doc, one);
        assertEq(oracle.valuationWatermark(FACILITY), 0, "documentary facts do not move the watermark");

        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        (bytes32 payload, uint64 asOf, bool satisfied) =
            oracle.latestPayload(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(payload, doc.payload, "documentary payload retained for audit");
        assertEq(asOf, t);
        assertFalse(satisfied);

        // an older documentary fact may still be re-attested (no monotonicity rule)
        doc.asOf = t - 100;
        doc.nonce = 16;
        one[0] = _sign(pk1, doc);
        oracle.attest(doc, one);
        (, asOf, satisfied) = oracle.latestPayload(FACILITY, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertEq(asOf, t - 100);
        assertTrue(satisfied);
        assertEq(oracle.valuationWatermark(FACILITY), 0);
    }

    /// @dev Fuzz: no sequence of (mark, revoke, replay) can ever make an accepted
    ///      valuation `asOf` regress below the highest ever accepted.
    function testFuzz_h02_watermarkNeverRegresses(uint64 firstDelta, uint64 secondDelta, bool revokeBetween) public {
        uint64 base = uint64(block.timestamp);
        uint64 first = base - uint64(bound(firstDelta, 1, 10_000));
        uint64 second = base - uint64(bound(secondDelta, 1, 10_000));

        IAttestationOracle.AttestationInput memory a = _valuation(FACILITY, bytes32(uint256(1e18)), first, 20);
        oracle.attest(a, _sigs2(a));
        if (revokeBetween) {
            vm.prank(admin);
            oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);
        }

        IAttestationOracle.AttestationInput memory b = _valuation(FACILITY, bytes32(uint256(2e18)), second, 21);
        bytes[] memory sigs = _sigs2(b);
        if (second <= first) {
            vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, second, first));
            oracle.attest(b, sigs);
            assertEq(oracle.valuationWatermark(FACILITY), first, "watermark held against the stale replay");
        } else {
            oracle.attest(b, sigs);
            assertEq(oracle.valuationWatermark(FACILITY), second, "watermark advanced");
        }
        assertGe(oracle.valuationWatermark(FACILITY), first, "the watermark never regresses");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _valuation(uint256 facilityId, bytes32 payload, uint64 asOf, uint256 nonce)
        internal
        view
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: nonce
        });
    }

    function _sign(uint256 pk, IAttestationOracle.AttestationInput memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _sigs2(IAttestationOracle.AttestationInput memory a) internal view returns (bytes[] memory sigs) {
        (uint256 lo, uint256 hi) = vm.addr(pk1) < vm.addr(pk2) ? (pk1, pk2) : (pk2, pk1);
        sigs = new bytes[](2);
        sigs[0] = _sign(lo, a);
        sigs[1] = _sign(hi, a);
    }
}
