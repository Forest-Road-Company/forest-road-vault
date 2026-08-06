// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// AUDIT SLOT: fixed-gas-limit re-audit of MTM-02's remediation. NEW FILE ONLY.
//
// The executor picks its action with `try defaultManager.liquidate(...) catch`. Solidity
// forwards 63/64 of the remaining gas into that try, so a starved gas budget makes the
// INNER call fail while the OUTER frame still has gas left to run `marginCall`. If the
// catch treated an out-of-gas reason as a fall-through condition, an operator (or anyone
// who could influence the submitted gas limit) could downgrade a liquidation to a margin
// call. This sweeps the formerly reachable low-gas band and proves that failure cannot
// downgrade the action; the keeper configuration now rejects the swept range.

import {console2} from "forge-std/console2.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MtmAtomicExecutor} from "../../src/MtmAtomicExecutor.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

contract MtmExecutorGasStarvationTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant ORIGINAL_MARK = 1_000_000e18;
    uint256 internal constant LIQUIDATION_MARK = 625_000e18; // 8,000 bps: hard breach

    address internal keeper = makeAddr("mtmStarveKeeper");
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

    /// @notice Sweep the former config floor through the measured requirement. No starved
    ///         budget may produce a partial or downgraded result.
    function test_noStarvedBudgetEverDowngradesLiquidationOrConsumesTheDigest() public {
        uint256 worstBurn;
        uint256 worstBurnAt;
        uint256 checked;
        for (uint256 txLimit = 100_000; txLimit < 392_000; txLimit += 2_000) {
            uint256 snap = vm.snapshotState();
            uint256 id = _liveDigitalFacility();
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, 2);
            bytes32 digest = realOracle.attestationDigest(a);

            (bool ok, uint256 burnt) = _tryAtTxGasLimit(a, sigs, txLimit);

            assertFalse(ok, "a starved budget must never report success");
            assertFalse(realOracle.digestUsed(digest), "starved attempt consumed the one-use digest");
            assertEq(defaultManager.cureDeadline(id), 0, "starved attempt downgraded liquidation to a margin call");
            assertEq(
                uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "partial state transition"
            );
            if (burnt > worstBurn) {
                worstBurn = burnt;
                worstBurnAt = txLimit;
            }
            ++checked;
            vm.revertToState(snap);
        }
        console2.log("starved budgets swept (100,000 -> 392,000 step 2,000) :", checked);
        console2.log("worst gas burnt by a single failed attempt           :", worstBurn);
        console2.log("  at configured EXECUTION_GAS_LIMIT                  :", worstBurnAt);
    }

    /// @notice The same sweep at the maximum bundle width the keeper accepts
    ///         (mtm-keeper/src/bundle.ts:100 permits up to 64 signatures).
    function test_noStarvedBudgetDowngradesAtMaxBundleWidth() public {
        for (uint256 txLimit = 120_000; txLimit < 1_060_000; txLimit += 20_000) {
            uint256 snap = vm.snapshotState();
            uint256 id = _liveDigitalFacility();
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, 64);
            bytes32 digest = realOracle.attestationDigest(a);

            (bool ok,) = _tryAtTxGasLimit(a, sigs, txLimit);

            assertFalse(ok, "a starved budget must never report success");
            assertFalse(realOracle.digestUsed(digest), "starved attempt consumed the one-use digest");
            assertEq(defaultManager.cureDeadline(id), 0, "starved attempt downgraded liquidation to a margin call");
            assertEq(
                uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "partial state transition"
            );
            vm.revertToState(snap);
        }
        console2.log("64-signature starvation sweep: no downgrade, no digest consumption");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _intrinsic(bytes memory data) internal pure returns (uint256) {
        uint256 zeroBytes;
        uint256 nonZeroBytes;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++zeroBytes;
            else ++nonZeroBytes;
        }
        return 21_000 + 16 * nonZeroBytes + 4 * zeroBytes;
    }

    function _tryAtTxGasLimit(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs, uint256 txGasLimit)
        internal
        returns (bool ok, uint256 burnt)
    {
        bytes memory data = abi.encodeCall(MtmAtomicExecutor.execute, (a, sigs));
        uint256 intrinsic = _intrinsic(data);
        uint256 budget = txGasLimit - intrinsic;
        _cool();
        vm.prank(keeper);
        uint256 before = gasleft();
        (ok,) = address(executor).call{gas: budget}(data);
        burnt = intrinsic + (before - gasleft());
    }

    function _cool() internal {
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
        for (uint256 i = 0; i < sortedPks.length; ++i) {
            vm.cool(vm.addr(sortedPks[i]));
        }
    }

    function _liveDigitalFacility() internal returns (uint256 id) {
        usdc.mint(alice, PRINCIPAL / 1e12);
        _mintUSDfr(alice, PRINCIPAL / 1e12);
        id = _originateDigital(PRINCIPAL, ORIGINAL_MARK);
        _fundFacility(id, PRINCIPAL);
    }

    function _freshValuation(uint256 id, uint256 n)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        vm.warp(block.timestamp + 1);
        a = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(LIQUIDATION_MARK),
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
