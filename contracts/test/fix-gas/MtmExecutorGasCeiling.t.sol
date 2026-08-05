// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// AUDIT SLOT: fixed-gas-limit re-audit of MTM-02's remediation. NEW FILE ONLY.
// Measures the real transaction-level gas that `MtmAtomicExecutor.execute` needs, so the
// keeper's fixed `EXECUTION_GAS_LIMIT` (bounded to [2_000_000 .. 5_000_000]) can be
// compared against a measured floor rather than a comment.

import {console2} from "forge-std/console2.sol";

import {MtmAtomicExecutor} from "../../src/MtmAtomicExecutor.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

contract MtmExecutorGasCeilingTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant ORIGINAL_MARK = 1_000_000e18;
    uint256 internal constant MARGIN_MARK = 769_230e18; // 6,500 bps -> MarginCall
    uint256 internal constant LIQUIDATION_MARK = 625_000e18; // 8,000 bps -> Liquidate
    uint256 internal constant HEALTHY_MARK = 1_000_000e18; // 5,000 bps -> ClearMarginCall

    // mtm-keeper/src/bundle.ts:99 accepts 2..64 signatures. The deployed Valuation
    // threshold is 2 (script/Validate.s.sol:1022). Both ends are measured.
    uint256 internal constant MAX_BUNDLE_SIGNATURES = 64;

    address internal keeper = makeAddr("mtmGasKeeper");
    MtmAtomicExecutor internal executor;

    uint256[] internal sortedPks;

    function setUp() public override {
        super.setUp();
        executor = new MtmAtomicExecutor(address(realOracle), address(defaultManager));

        uint256[] memory pks = new uint256[](MAX_BUNDLE_SIGNATURES);
        for (uint256 i = 0; i < MAX_BUNDLE_SIGNATURES; ++i) {
            pks[i] = uint256(keccak256(abi.encodePacked("mtm-gas-attester", i)));
        }
        // insertion sort by recovered address (the oracle demands strictly ascending signers)
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

    // ── measurement ──────────────────────────────────────────────────────

    struct Measurement {
        uint256 execution; // EVM gas consumed inside the CALL
        uint256 calldataBytes;
        uint256 zeroBytes;
        uint256 nonZeroBytes;
        uint256 cancunTx; // 21000 + 16/4 calldata + execution
        uint256 pragueTx; // EIP-7623 max(standard, floor)
    }

    function _intrinsic(bytes memory data, uint256 execution) internal pure returns (Measurement memory m) {
        m.execution = execution;
        m.calldataBytes = data.length;
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] == 0) ++m.zeroBytes;
            else ++m.nonZeroBytes;
        }
        m.cancunTx = 21_000 + 16 * m.nonZeroBytes + 4 * m.zeroBytes + execution;
        uint256 tokens = m.zeroBytes + 4 * m.nonZeroBytes;
        uint256 standard = 21_000 + 4 * tokens + execution;
        uint256 floorCost = 21_000 + 10 * tokens;
        m.pragueTx = standard > floorCost ? standard : floorCost;
    }

    function _report(string memory label, Measurement memory m) internal pure {
        console2.log("---------------------------------------------");
        console2.log(label);
        console2.log("  execution gas (CALL)      :", m.execution);
        console2.log("  calldata bytes            :", m.calldataBytes);
        console2.log("  calldata zero/non-zero    :", m.zeroBytes, m.nonZeroBytes);
        console2.log("  tx gas, Cancun rules      :", m.cancunTx);
        console2.log("  tx gas, Prague (EIP-7623) :", m.pragueTx);
    }

    /// @dev Cold every account the executor's fan-out touches so the measurement is a
    ///      first-touch transaction, not a warmed test frame.
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
        vm.cool(keeper);
    }

    function _measure(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
        internal
        returns (Measurement memory)
    {
        bytes memory data = abi.encodeCall(MtmAtomicExecutor.execute, (a, sigs));
        _coolEverything();
        vm.prank(keeper);
        uint256 before = gasleft();
        (bool ok,) = address(executor).call(data);
        uint256 spent = before - gasleft();
        require(ok, "execute reverted");
        return _intrinsic(data, spent);
    }

    // ── scenarios ────────────────────────────────────────────────────────

    function test_gasMarginCall_deployedThreshold2() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, MARGIN_MARK, 2);
        _report("MarginCall  / 2 signatures  / cold first touch", _measure(a, sigs));
    }

    function test_gasMarginCall_maxBundleSignatures64() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _freshValuation(id, MARGIN_MARK, MAX_BUNDLE_SIGNATURES);
        _report("MarginCall  / 64 signatures / cold first touch", _measure(a, sigs));
    }

    function test_gasClearMarginCall_deployedThreshold2() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory breach, bytes[] memory breachSigs) =
            _freshValuation(id, MARGIN_MARK, 2);
        vm.prank(keeper);
        executor.execute(breach, breachSigs);
        (IAttestationOracle.AttestationInput memory cure, bytes[] memory cureSigs) =
            _freshValuation(id, HEALTHY_MARK, 2);
        _report("ClearCall   / 2 signatures  / cold first touch", _measure(cure, cureSigs));
    }

    function test_gasClearMarginCall_maxBundleSignatures64() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory breach, bytes[] memory breachSigs) =
            _freshValuation(id, MARGIN_MARK, 2);
        vm.prank(keeper);
        executor.execute(breach, breachSigs);
        (IAttestationOracle.AttestationInput memory cure, bytes[] memory cureSigs) =
            _freshValuation(id, HEALTHY_MARK, MAX_BUNDLE_SIGNATURES);
        _report("ClearCall   / 64 signatures / cold first touch", _measure(cure, cureSigs));
    }

    function test_gasLiquidate_deployedThreshold2() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, LIQUIDATION_MARK, 2);
        _report("Liquidate   / 2 signatures  / cold first touch", _measure(a, sigs));
    }

    function test_gasLiquidate_maxBundleSignatures64() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _freshValuation(id, LIQUIDATION_MARK, MAX_BUNDLE_SIGNATURES);
        _report("Liquidate   / 64 signatures / cold first touch", _measure(a, sigs));
    }

    /// @dev The liquidation fan-out that costs the most: an expired margin call on a facility
    ///      whose class already carries other live defaults (impairment pool + curator freeze +
    ///      vault fee accrual all engage), at the maximum accepted bundle width.
    function test_gasLiquidate_cureExpiryWithLoadedImpairmentPool_max64() public {
        uint256 first = _liveDigitalFacility();
        uint256 second = _liveDigitalFacility();
        uint256 third = _liveDigitalFacility();

        // Put two other facilities of the same class into the impairment pool first.
        (IAttestationOracle.AttestationInput memory l1, bytes[] memory s1) = _freshValuation(first, LIQUIDATION_MARK, 2);
        vm.prank(keeper);
        executor.execute(l1, s1);
        (IAttestationOracle.AttestationInput memory l2, bytes[] memory s2) =
            _freshValuation(second, LIQUIDATION_MARK, 2);
        vm.prank(keeper);
        executor.execute(l2, s2);

        // Open a margin call on the third and let the cure window expire.
        (IAttestationOracle.AttestationInput memory call, bytes[] memory callSigs) =
            _freshValuation(third, MARGIN_MARK, 2);
        vm.prank(keeper);
        executor.execute(call, callSigs);
        uint64 deadline = defaultManager.cureDeadline(third);
        vm.warp(uint256(deadline) + 1);

        (IAttestationOracle.AttestationInput memory expired, bytes[] memory expiredSigs) =
            _valuation(third, MARGIN_MARK, uint64(block.timestamp), MAX_BUNDLE_SIGNATURES);
        _report("Liquidate   / 64 sigs / cure-expiry / loaded pool", _measure(expired, expiredSigs));
    }

    /// @dev The most expensive documented liquidation fan-out: `DefaultManager.liquidate`
    ///      calls `sUSDfr.accrueFees()` first. Stake the vault, let management + performance
    ///      fees become due, then liquidate at the maximum accepted bundle width so the
    ///      crystallization SSTOREs/mints land inside the protective transaction.
    function test_gasLiquidate_withDueFeeCrystallisation_max64() public {
        uint256 id = _liveDigitalFacility();

        // stake so the vault has supply to charge management fees against
        usdc.mint(bob, 1_000_000e6);
        _mintUSDfr(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1_000_000e18);
        vault.deposit(1_000_000e18, bob);
        vm.stopPrank();

        vm.warp(block.timestamp + 170 days);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _valuation(id, LIQUIDATION_MARK, uint64(block.timestamp), MAX_BUNDLE_SIGNATURES);
        _report("Liquidate   / 64 sigs / fee crystallisation due", _measure(a, sigs));
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
        return _valuation(id, value, uint64(block.timestamp), n);
    }

    function _valuation(uint256 id, uint256 value, uint64 asOf, uint256 n)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(value),
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
        sigs = _signN(a, n);
    }

    function _signN(IAttestationOracle.AttestationInput memory a, uint256 n)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = realOracle.attestationDigest(a);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sortedPks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }
}
