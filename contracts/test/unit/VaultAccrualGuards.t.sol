// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {VaultAccrualLib} from "../../src/libraries/VaultAccrualLib.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";

/// @dev Controlled ABI replies, including short successes and full-length failures.
contract VaultImpairmentReply {
    struct Reply { uint256 value; uint256 size; bool fails; }
    Reply private pending;
    Reply private performance;

    function configure(uint256 senior, uint256 fee, uint256 firstSize, uint256 secondSize, uint8 failures) external {
        pending = Reply(senior, firstSize, failures & 1 != 0);
        performance = Reply(fee, secondSize, failures & 2 != 0);
    }

    fallback() external {
        Reply memory r = msg.sig == IImpairmentSource.pendingSeniorImpairment.selector ? pending : performance;
        uint256 value = r.value;
        uint256 size = r.size;
        bool fails = r.fails;
        assembly ("memory-safe") {
            let out := mload(0x40)
            mstore(out, value)
            if fails { revert(out, size) }
            return(out, size)
        }
    }
}

/// @dev A failed external read may consume all gas forwarded to it.
contract VaultGasConsumingReply {
    fallback() external { assembly ("memory-safe") { invalid() } }
}

contract VaultRecoveryProbe {
    function validate(address source) external view { VaultAccrualLib.validateImpairmentSource(source); }
    function failure(address source) external view returns (bytes32) {
        return VaultAccrualLib.impairmentRecoveryFailure(source);
    }
}

contract VaultAccrualProbeGuardsTest is Test {
    VaultRecoveryProbe private probe;
    VaultImpairmentReply private source;

    function setUp() public { probe = new VaultRecoveryProbe(); source = new VaultImpairmentReply(); }

    function _replyFailure(bytes4 selector, uint256 value, uint256 size) private pure returns (bytes32) {
        uint256 first = size == 0 ? 0 : size < 32 ? value & (type(uint256).max << ((32 - size) * 8)) : value;
        return keccak256(abi.encode(selector, keccak256(abi.encode(size, bytes32(first)))));
    }

    /// @dev Independent model uses reply metadata, never the production probe's return value.
    function testFuzz_probeMatchesIndependentReplyModel(
        uint256 senior, uint256 fee, uint16 firstSeed, uint16 secondSeed, uint8 flags
    ) public {
        uint256 firstSize = uint256(firstSeed) % 97;
        uint256 secondSize = uint256(secondSeed) % 97;
        source.configure(senior, fee, firstSize, secondSize, flags);
        bool firstFails = flags & 1 != 0 || firstSize < 32;
        bool secondFails = flags & 2 != 0 || secondSize < 32;
        bool readable = !firstFails && !secondFails && fee >= senior;
        if (readable) {
            probe.validate(address(source));
            vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector, address(source)));
            probe.failure(address(source));
        } else {
            bytes32 expected = firstFails
                ? _replyFailure(IImpairmentSource.pendingSeniorImpairment.selector, senior, firstSize)
                : secondFails
                    ? _replyFailure(IImpairmentSource.performanceFeeImpairment.selector, fee, secondSize)
                    : keccak256(abi.encode(IsUSDfr.SUSDfr_InvalidPerformanceFeeImpairment.selector, senior, fee));
            vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, address(source)));
            probe.validate(address(source));
            assertEq(probe.failure(address(source)), expected, "selector, size and first word identify the failure");
        }
    }

    function test_probeHandlesAbsentCodeLargeRepliesAndInsufficientGas() public {
        probe.validate(address(0));
        vm.expectRevert(IsUSDfr.SUSDfr_NoImpairmentSource.selector);
        probe.failure(address(0));
        address codeless = address(0xC0DE);
        assertEq(codeless.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_InvalidImpairmentSource.selector, codeless));
        probe.validate(codeless);
        assertEq(probe.failure(codeless), keccak256(abi.encode(uint256(0), bytes32(0))));

        source.configure(123, 456, 65_536, 65_536, 0);
        probe.validate(address(source));
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector, address(source)));
        probe.failure(address(source));
        source.configure(123, 456, 65_536, 65_536, 2);
        assertEq(probe.failure(address(source)), _replyFailure(IImpairmentSource.performanceFeeImpairment.selector, 456, 65_536));

        (bool ok, bytes memory reason) = address(probe).call{gas: 500_000}(abi.encodeCall(probe.failure, (address(source))));
        assertFalse(ok);
        assertEq(reason.length, 68, "named gas failure preserves both measurements");
        bytes4 selector;
        uint256 available;
        uint256 required;
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
            available := mload(add(reason, 36))
            required := mload(add(reason, 68))
        }
        assertEq(selector, IsUSDfr.SUSDfr_InsufficientImpairmentRecoveryGas.selector);
        assertLt(available, required);
        assertEq(required, 2_150_000);

        VaultGasConsumingReply gasConsumer = new VaultGasConsumingReply();
        uint256 startGas = gasleft();
        (ok, reason) = address(probe).call{gas: 2_300_000}(abi.encodeCall(probe.failure, (address(gasConsumer))));
        uint256 consumed = startGas - gasleft();
        assertTrue(ok, "a read consuming its entire allowance must leave recovery live");
        assertEq(abi.decode(reason, (bytes32)), _replyFailure(IImpairmentSource.pendingSeniorImpairment.selector, 0, 0));
        assertLt(consumed, 1_050_000, "failed read is bounded to its allowance plus call overhead");
    }
}

/// @dev Records callback results in state because the optional points hook may fail open.
contract VaultRecoveryObserver {
    SUSDfr private immutable VAULT;
    VaultImpairmentReply private immutable SOURCE;
    uint256 public attempts;
    uint256 public refused;

    constructor(SUSDfr vault_, VaultImpairmentReply source_) { VAULT = vault_; SOURCE = source_; }

    function onUSDfrTransfer(address, address, uint256) external {
        ++attempts;
        SOURCE.configure(0, 0, 0, 32, 0);
        (bool ok, bytes memory reason) = address(VAULT).call(abi.encodeCall(VAULT.clearUnreadableImpairmentSource, ()));
        if (!ok && reason.length == 4 && bytes4(reason) == VaultAccrualLib.VaultAccrual_OperationInProgress.selector) ++refused;
        SOURCE.configure(0, 0, 32, 32, 0);
    }
}

abstract contract VaultAccrualNativeGuardsBase is NativeAccrualFixture {
    function _source() private returns (VaultImpairmentReply source) {
        source = new VaultImpairmentReply();
        source.configure(0, 0, 32, 32, 0);
        vm.prank(admin);
        vault.setImpairmentSource(address(source));
    }

    function test_nativeRecoveryPreservesUnpaidInterestAndChargesOnlySubsequentProfit() public {
        _nativeFund(50_000e18);
        VaultImpairmentReply source = _source();
        vm.warp(nativeStart + 45 days);
        IContinuousAccrual.Snapshot memory before_ = reserves.accrualSnapshot();
        assertGt(before_.seniorUnissued, 0);
        assertGt(before_.feeUnissued, 0);
        source.configure(before_.seniorUnissued, before_.seniorUnissued, 32, 32, 0);
        (, uint256 charged) = vault.accrueFees();
        assertEq(charged, 0, "the live mark offsets the earned senior interest");
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        uint256 held = usdfr.balanceOf(address(vault));
        source.configure(before_.seniorUnissued, before_.seniorUnissued, 0, 32, 0);
        bytes32 expected = keccak256(abi.encode(IImpairmentSource.pendingSeniorImpairment.selector,
            keccak256(abi.encode(uint256(0), bytes32(0)))));
        vm.expectEmit(true, false, false, true, address(vault));
        emit IsUSDfr.ImpairmentSourceEmergencyCleared(address(source), expected);
        vm.prank(admin);
        vault.clearUnreadableImpairmentSource();
        assertEq(vault.impairmentSource(), address(0));
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.redemptionTotalAssets(), assets);
        assertEq(vault.totalSupply(), supply);
        assertEq(usdfr.balanceOf(address(vault)), held);
        assertEq(keccak256(abi.encode(reserves.accrualSnapshot())), keccak256(abi.encode(before_)));
        uint256 shareUnit = 10 ** vault.decimals();
        uint256 effectiveSupply = supply + 1e6;
        uint256 expectedHwm = ((assets + 1) * shareUnit + effectiveSupply - 1) / effectiveSupply;
        assertEq(vault.highWaterMark(), expectedHwm, "recovery anchors the full physical and virtual NAV");
        (, charged) = vault.accrueFees();
        assertEq(charged, 0, "operational recovery follows the existing fee-free HWM ratchet");
        _assertNativeBacking();

        vm.warp(nativeStart + 46 days);
        IContinuousAccrual.Snapshot memory after_ = reserves.accrualSnapshot();
        (, charged) = vault.accrueFees();
        assertGt(charged, 0, "new income after recovery still earns the performance fee");
        // One rounded HWM unit spans effectiveSupply/shareUnit asset units. Its
        // ceiling can defer at most that amount of profit; fee/share floors add two.
        uint256 roundingBound = ((effectiveSupply + shareUnit - 1) / shareUnit + 9) / 10 + 2;
        assertApproxEqAbs(vault.convertToAssets(charged),
            (after_.seniorUnissued - before_.seniorUnissued) / 10, roundingBound);
        assertGt(after_.feeUnissued, before_.feeUnissued, "protocol interest fees continue independently");
        _assertNativeBacking();
    }

    function test_nativeDeliveryCallbackCannotClearTheImpairmentSource() public {
        _nativeFund(50_000e18);
        VaultImpairmentReply source = _source();
        VaultRecoveryObserver observer = new VaultRecoveryObserver(vault, source);
        vm.startPrank(admin);
        vault.grantRole(bytes32(0), address(observer));
        usdfr.setPointsModule(address(observer));
        vm.stopPrank();
        vm.warp(nativeStart + 45 days);
        uint256 assets = vault.totalAssets();
        reserves.materializeAccrued(3);
        assertEq(observer.attempts(), 2, "both interest legs reach the observer");
        assertEq(observer.refused(), 2, "recovery refuses every delivery callback before probing the source");
        assertEq(vault.impairmentSource(), address(source));
        assertEq(vault.totalAssets(), assets);
        assertEq(reserves.accrualSnapshot().unissued, 0);
        _assertNativeBacking();
    }
}

contract VaultAccrualNativeCashGuardsTest is VaultAccrualNativeGuardsBase {}
contract VaultAccrualNativePikGuardsTest is VaultAccrualNativeGuardsBase {
    function _pikFacilities() internal pure override returns (bool) { return true; }
}
