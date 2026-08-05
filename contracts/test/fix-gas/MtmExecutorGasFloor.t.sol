// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// Release-bound regression for the fixed-gas-limit re-audit of MTM-02's remediation.
// It proves why the former 100,000-gas configuration floor was unsafe and whether an
// out-of-gas protective transaction consumes the one-use attestation digest. The
// TypeScript configuration now enforces the reviewed [2,000,000 .. 5,000,000] range.

import {console2} from "forge-std/console2.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MtmAtomicExecutor} from "../../src/MtmAtomicExecutor.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

contract MtmExecutorGasFloorTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant ORIGINAL_MARK = 1_000_000e18;
    uint256 internal constant LIQUIDATION_MARK = 625_000e18;

    uint256 internal constant PRE_FIX_KEEPER_MIN_GAS_LIMIT = 100_000;
    uint256 internal constant KEEPER_MAX_PERMITTED_GAS_LIMIT = 5_000_000;

    address internal keeper = makeAddr("mtmFloorKeeper");
    MtmAtomicExecutor internal executor;
    uint256[] internal sortedPks;

    function setUp() public override {
        super.setUp();
        executor = new MtmAtomicExecutor(address(realOracle), address(defaultManager));
        uint256[] memory pks = new uint256[](64);
        for (uint256 i = 0; i < 64; ++i) {
            pks[i] = uint256(keccak256(abi.encodePacked("mtm-gas-attester", i)));
        }
        for (uint256 i = 1; i < pks.length; ++i) {
            uint256 key = pks[i];
            uint256 j = i;
            while (j > 0 && vm.addr(pks[j - 1]) > vm.addr(key)) {
                pks[j] = pks[j - 1];
                --j;
            }
            pks[j] = key;
        }
        vm.startPrank(admin);
        for (uint256 i = 0; i < pks.length; ++i) {
            sortedPks.push(pks[i]);
            realOracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pks[i]));
        }
        vm.stopPrank();
    }

    function _intrinsic(bytes memory data) internal pure returns (uint256) {
        uint256 zeroBytes;
        uint256 nonZeroBytes;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++zeroBytes;
            else ++nonZeroBytes;
        }
        return 21_000 + 16 * nonZeroBytes + 4 * zeroBytes;
    }

    /// @dev Emulate a transaction submitted with total gas limit `txGasLimit`: the intrinsic
    ///      cost is charged before execution begins, so the executor frame sees the remainder.
    function _tryAtTxGasLimit(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs, uint256 txGasLimit)
        internal
        returns (bool ok)
    {
        bytes memory data = abi.encodeCall(MtmAtomicExecutor.execute, (a, sigs));
        uint256 budget = txGasLimit - _intrinsic(data);
        _coolEverything();
        vm.prank(keeper);
        (ok,) = address(executor).call{gas: budget}(data);
    }

    /// @dev A real keeper transaction is a first touch: nothing is pre-warmed.
    function _coolEverything() internal {
        vm.cool(address(executor));
        vm.cool(address(realOracle));
        vm.cool(address(defaultManager));
        vm.cool(address(bridge));
        vm.cool(address(curator));
        vm.cool(address(vault));
        vm.cool(address(registry));
        vm.cool(address(waterfall));
        vm.cool(address(reserves));
        vm.cool(address(usdfr));
        vm.cool(address(usdc));
        vm.cool(address(queue));
        vm.cool(address(backstopMock));
        vm.cool(address(assessedImpairmentSource));
        vm.cool(address(controller));
        for (uint256 i = 0; i < sortedPks.length; ++i) {
            vm.cool(vm.addr(sortedPks[i]));
        }
    }

    // ── the former config floor was a guaranteed out-of-gas ──────────────

    function test_preFixFloor100kGuaranteesOutOfGasAndRollsBackTheDigest() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, LIQUIDATION_MARK, 2);
        bytes32 digest = realOracle.attestationDigest(a);

        bool ok = _tryAtTxGasLimit(a, sigs, PRE_FIX_KEEPER_MIN_GAS_LIMIT);

        assertFalse(ok, "the former EXECUTION_GAS_LIMIT=100000 floor must fail");
        assertFalse(realOracle.digestUsed(digest), "out-of-gas must roll back the one-use digest");
        assertEq(defaultManager.cureDeadline(id), 0, "no protective action was taken");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "facility unprotected");
        console2.log("100,000 gas limit -> liquidation FAILED, position unprotected, digest intact");
    }

    /// @dev Binary-search the true transaction-level floor for the cheapest realistic
    ///      protective transaction (the deployed 2-of-n threshold, liquidation branch).
    function test_measuredFloor_liquidate2of2() public {
        uint256 floorGas = _searchFloor(LIQUIDATION_MARK, 2);
        console2.log("measured tx-gas floor, Liquidate / 2 signatures :", floorGas);
        assertGt(floorGas, PRE_FIX_KEEPER_MIN_GAS_LIMIT, "former config floor is below the measured requirement");
    }

    function test_measuredFloor_liquidate64Signatures() public {
        uint256 floorGas = _searchFloor(LIQUIDATION_MARK, 64);
        console2.log("measured tx-gas floor, Liquidate / 64 signatures:", floorGas);
        assertLt(floorGas, KEEPER_MAX_PERMITTED_GAS_LIMIT, "config ceiling cannot fund the widest bundle");
    }

    /// @dev Quantifies the formerly permitted fatal range so the TypeScript floor cannot
    ///      be relaxed back below the release evidence without an explicit review.
    function test_preFixPermittedRangeContainedGuaranteedFailureValues() public {
        uint256 floorGas = _searchFloor(LIQUIDATION_MARK, 64);
        uint256 unsafeSpan = floorGas - PRE_FIX_KEEPER_MIN_GAS_LIMIT;
        console2.log("formerly permitted fatal span (64-sig liquidation):", unsafeSpan);
        console2.log("  = every EXECUTION_GAS_LIMIT in [100000 ..", floorGas - 1);
        assertGt(unsafeSpan, 0);
    }

    function _searchFloor(uint256 mark, uint256 n) internal returns (uint256) {
        uint256 low = PRE_FIX_KEEPER_MIN_GAS_LIMIT;
        uint256 high = KEEPER_MAX_PERMITTED_GAS_LIMIT;
        // invariant: `low` fails, `high` succeeds
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            uint256 snap = vm.snapshotState();
            uint256 id = _liveDigitalFacility();
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, mark, n);
            bool ok = _tryAtTxGasLimit(a, sigs, mid);
            vm.revertToState(snap);
            if (ok) high = mid;
            else low = mid;
        }
        return high;
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _liveDigitalFacility() internal returns (uint256 id) {
        usdc.mint(alice, PRINCIPAL / 1e12);
        _mintUSDfr(alice, PRINCIPAL / 1e12);
        id = _originateDigital(PRINCIPAL, ORIGINAL_MARK);
        _fundFacility(id, PRINCIPAL);
    }

    function _freshValuation(uint256 id, uint256 value, uint256 n)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        vm.warp(block.timestamp + 1);
        a = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(value),
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
        bytes32 digest = realOracle.attestationDigest(a);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sortedPks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }
}
