// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract SepoliaForkPreMainnetAuditTest is Test {
    uint256 internal constant FACILITY = 98_765_432;
    uint256 internal constant PK1 = 0xA11CE;
    uint256 internal constant PK2 = 0xB0B;

    AttestationOracle internal oracle;
    ClaimBridge internal bridge;
    MintRedeemController internal controller;
    address internal stable;
    address internal deployer;
    address internal attacker = makeAddr("attacker");
    bool internal forkReady;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forkReady = true;

        string memory manifest = vm.readFile("deployments/11155111.json");
        oracle = AttestationOracle(vm.parseJsonAddress(manifest, ".oracle"));
        bridge = ClaimBridge(vm.parseJsonAddress(manifest, ".bridge"));
        controller = MintRedeemController(vm.parseJsonAddress(manifest, ".controller"));
        stable = vm.parseJsonAddress(manifest, ".stable_TESTNET_MOCK");
        deployer = vm.parseJsonAddress(manifest, ".deployer");
    }

    /// @dev AUDIT FIX (2026-07-21). This was `if (!forkReady) return;` — a SILENT SKIP. Without
    ///      `SEPOLIA_RPC_URL` every test in this file reported `[PASS]` while executing NOTHING,
    ///      and those passes were counted in session totals and quoted as evidence that the
    ///      deployed stack had been checked. `vm.skip` reports SKIPPED instead, so an un-run fork
    ///      suite can never again be mistaken for a passing one. Same class as the mock/handler
    ///      divergence and the `lite`-profile invariant miss: green that means nothing is worse
    ///      than red, because it stops anyone looking.
    modifier forkOnly() {
        vm.skip(!forkReady);
        _;
    }

    function test_sepoliaFork_deployedControllerBlocksNonKycMint() public forkOnly {
        assertEq(block.chainid, 11155111);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, attacker));
        controller.mint(1);
    }

    function test_sepoliaFork_testnetManifestKeepsBootstrapAttester() public forkOnly {
        assertTrue(oracle.hasRole(Roles.ATTESTER_ROLE, deployer));
    }

    /// @notice H-02 on the LIVE deployed Sepolia oracle: revoking a valuation does NOT open a
    ///         rollback window. The emergency stop still zeroes the live mark, but the anti-rollback
    ///         high-watermark SURVIVES, so an older-but-still-validly-signed bundle can no longer be
    ///         replayed to become live.
    /// @dev FLIPPED 2026-07-22. This test previously asserted the PRE-H-02 behaviour — that the
    ///      older valuation is ALLOWED after a revoke — which is the H-02 vulnerability ITSELF. The
    ///      deployed oracle carries the H-02 fix, so the correct assertion is REFUSAL. This is the
    ///      live-fork twin of `PreMainnetFindings.test_h02_revokeDoesNotOpenARollbackWindow`, which
    ///      was flipped when the fix landed; this copy was missed. NB: this is UNRELATED to the
    ///      `resetValuationWatermark` lever removal — it never referenced that lever; the watermark
    ///      protection is unchanged and is what this now pins on the deployed stack.
    function test_sepoliaFork_deployedOracleRefusesOlderValuationAfterRevoke() public forkOnly {
        vm.startPrank(deployer);
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(PK1));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(PK2));
        vm.stopPrank();

        IAttestationOracle.AttestationInput memory oldMark = _input(
            IAttestationOracle.AttestationKind.Valuation,
            bytes32(uint256(600_000e18)),
            uint64(block.timestamp - 120),
            901
        );
        IAttestationOracle.AttestationInput memory newerMark = _input(
            IAttestationOracle.AttestationKind.Valuation,
            bytes32(uint256(900_000e18)),
            uint64(block.timestamp - 60),
            902
        );

        oracle.attest(newerMark, _sigs2(newerMark));
        (uint256 valueBefore, uint64 asOfBefore) = oracle.latestValuation(FACILITY);
        assertEq(valueBefore, 900_000e18);
        assertEq(asOfBefore, newerMark.asOf);
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "watermark tracks the accepted mark");

        vm.prank(deployer);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        // The emergency stop worked (the live mark is gone) but the clock did NOT rewind.
        (uint256 revokedValue, uint64 revokedAsOf) = oracle.latestValuation(FACILITY);
        assertEq(revokedValue, 0, "revoke zeroes the live mark");
        assertEq(revokedAsOf, 0, "revoke zeroes the live asOf");
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "watermark SURVIVES revocation");

        // The older, still validly-signed bundle can no longer be replayed. NB: build the
        // signatures FIRST — `_sigs2` calls `oracle.attestationDigest`, and an external call in the
        // argument list would consume the pending `vm.expectRevert` before `attest` is reached.
        bytes[] memory staleSigs = _sigs2(oldMark);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, oldMark.asOf, newerMark.asOf)
        );
        oracle.attest(oldMark, staleSigs);

        (uint256 valueAfter, uint64 asOfAfter) = oracle.latestValuation(FACILITY);
        assertEq(valueAfter, 0, "no stale mark became live after the refused replay");
        assertEq(asOfAfter, 0, "no live asOf after the refused replay");
    }

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf, uint256 nonce)
        internal
        view
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: kind,
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
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        sigs[0] = _sign(lo, a);
        sigs[1] = _sign(hi, a);
    }
}
