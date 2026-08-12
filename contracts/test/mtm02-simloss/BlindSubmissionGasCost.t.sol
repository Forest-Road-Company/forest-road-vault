// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MtmAtomicExecutor} from "../../src/MtmAtomicExecutor.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

/// @title MTM-02 remediation history — pre-local-action-check blind-submission gas lens
/// @notice This release-bound fixture measures the deterministic revert cost exposed after RPC
///         simulation was removed and before local action selection was added. The production
///         worker now rejects these exact paused, stale, non-live and no-action states before
///         relay release; keeping the lens records the bounded harm that drove that remediation.
/// @dev Read-only historical measurement. The current keeper behavior is covered by its unit and
///      compiled fork-worker tests; this fixture intentionally exercises the contracts directly.
contract BlindSubmissionGasCostTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant ORIGINAL_MARK = 1_000_000e18;
    uint256 internal constant MARGIN_MARK = 769_230e18; // 6,500 bps -> margin call
    uint256 internal constant MIDBAND_MARK = 700_000e18; // ~7,142 bps -> mid-band
    uint256 internal constant HEALTHY_MARK = 1_000_000e18; // 5,000 bps -> no action available

    address internal keeperA = makeAddr("mtmKeeperA");
    MtmAtomicExecutor internal executor;

    function setUp() public override {
        super.setUp();
        executor = new MtmAtomicExecutor(address(realOracle), address(defaultManager));
    }

    function _liveDigitalFacility() internal returns (uint256 id) {
        _mintUSDfr(alice, PRINCIPAL / 1e12);
        id = _originateDigital(PRINCIPAL, ORIGINAL_MARK);
        _fundFacility(id, PRINCIPAL);
    }

    function _freshValuation(uint256 id, uint256 value)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        vm.warp(block.timestamp + 1);
        a = _input(id, IAttestationOracle.AttestationKind.Valuation, bytes32(value), uint64(block.timestamp));
        sigs = _signedBundle(a);
    }

    function _input(uint256 id, IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        internal
        returns (IAttestationOracle.AttestationInput memory a)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
    }

    /// @dev Measure the gas an EOA is actually CHARGED for a top-level `execute` that reverts.
    function _measure(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
        internal
        returns (bool ok, uint256 gasUsed)
    {
        bytes memory payload = abi.encodeCall(MtmAtomicExecutor.execute, (a, sigs));
        vm.prank(keeperA);
        uint256 before = gasleft();
        (ok,) = address(executor).call(payload);
        gasUsed = before - gasleft();
    }

    /// @notice BASELINE: a submission that succeeds.
    function test_gas_successfulMarginCall() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, MARGIN_MARK);
        (bool ok, uint256 used) = _measure(a, sigs);
        assertTrue(ok, "baseline must succeed");
        emit log_named_uint("GAS successful MarginCall            ", used);
    }

    /// @notice PRE-FIX WASTE CLASS 1 — healthy facility, no active call: `marginCall` reverts
    ///         DefaultManager_ThresholdNotBreached. The current keeper predicts this locally.
    function test_gas_wasted_healthyFacilityNoActionAvailable() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, HEALTHY_MARK);
        (bool ok, uint256 used) = _measure(a, sigs);
        assertFalse(ok, "healthy facility must revert: no protective action is available");
        emit log_named_uint("GAS WASTED healthy/no-action revert  ", used);
        assertFalse(realOracle.digestUsed(realOracle.attestationDigest(a)), "digest rolled back -> keeper retries");
    }

    /// @notice WASTE CLASS 2 — CLOSED ON-CHAIN BY THE G8-L1 FIX. Mid-band inside the cure window:
    ///         liquidate misses the hard threshold and `activeCall` is true. The cure leg used to
    ///         be attempted unconditionally, so `clearMarginCall` reverted (LTV still at/above the
    ///         margin-call threshold) and the whole transaction — including the mark — was thrown
    ///         away. There was never any protective action to take here: the call already stands.
    /// @dev ASSERTIONS INVERTED DELIBERATELY. This class no longer costs a burnt transaction at
    ///      all: the relay succeeds, reports `NoActionAvailable` and KEEPS the mark, so the
    ///      keeper's local prediction is now an optimization rather than the only thing standing
    ///      between a bystander's margin call and a discarded valuation. Do not "restore" the
    ///      revert expectation — it asserted the defect.
    function test_gas_wasted_midBandDuringCureWindow() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a1, bytes[] memory s1) = _freshValuation(id, MARGIN_MARK);
        vm.prank(keeperA);
        executor.execute(a1, s1); // opens the margin call -> cureDeadline != 0
        uint64 standingDeadline = defaultManager.cureDeadline(id);
        assertTrue(standingDeadline != 0, "cure window must be open");

        (IAttestationOracle.AttestationInput memory a2, bytes[] memory s2) = _freshValuation(id, MIDBAND_MARK);
        (bool ok, uint256 used) = _measure(a2, s2);
        assertTrue(ok, "mid-band inside the cure window is a no-action outcome, not a failure");
        emit log_named_uint("GAS no-action mid-band cure-window   ", used);
        assertTrue(realOracle.digestUsed(realOracle.attestationDigest(a2)), "the mark is kept");
        (uint256 value,) = realOracle.latestValuation(id);
        assertEq(value, MIDBAND_MARK, "the deteriorated mark is on the books");
        assertEq(defaultManager.cureDeadline(id), standingDeadline, "the standing call is untouched");
    }

    /// @notice WASTE CLASS 3 — CLOSED ON-CHAIN BY THE G8-L2 FIX. The facility is already
    ///         liquidated, so `_mtmFacility` rejects every protective entry point identically
    ///         with DefaultManager_NotDefaultable. Bubbling that revert bricked the canonical
    ///         relay path for the facility permanently, for anyone, after a single permissionless
    ///         `liquidate` by any bystander.
    /// @dev ASSERTIONS INVERTED DELIBERATELY — see the note on waste class 2.
    function test_gas_wasted_facilityAlreadyLiquidated() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a1, bytes[] memory s1) = _freshValuation(id, 625_000e18);
        vm.prank(keeperA);
        executor.execute(a1, s1);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "must be liquidated");

        (IAttestationOracle.AttestationInput memory a2, bytes[] memory s2) = _freshValuation(id, MARGIN_MARK);
        (bool ok, uint256 used) = _measure(a2, s2);
        assertTrue(ok, "a defaulted facility still accepts marks; it takes no further action");
        emit log_named_uint("GAS no-action already-liquidated     ", used);
        assertTrue(realOracle.digestUsed(realOracle.attestationDigest(a2)), "the mark is kept");
        assertEq(
            uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "and nothing else changed"
        );
    }

    /// @notice PRE-FIX WASTE CLASS 4 — DefaultManager paused. The current keeper reads both pause
    ///         states from the same block snapshot before releasing a transaction.
    function test_gas_wasted_defaultManagerPaused() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, MARGIN_MARK);
        vm.prank(guardian);
        defaultManager.pause();
        (bool ok, uint256 used) = _measure(a, sigs);
        assertFalse(ok, "a paused DefaultManager must revert");
        emit log_named_uint("GAS WASTED DefaultManager-paused rvt ", used);
        assertFalse(realOracle.digestUsed(realOracle.attestationDigest(a)), "digest rolled back -> keeper retries");
    }

    /// @notice PRE-FIX WASTE CLASS 5 — the mark is older than the class `maxMarkAge`. The current
    ///         keeper checks this against the earliest possible inclusion timestamp.
    function test_gas_wasted_markOlderThanMaxMarkAge() public {
        uint256 id = _liveDigitalFacility();
        uint64 watermark = uint64(block.timestamp);
        uint64 maxMarkAge = registry.classParams(5).maxMarkAge;
        emit log_named_uint("class maxMarkAge (seconds)           ", maxMarkAge);

        // Advance well past maxMarkAge, then build a bundle whose `asOf` is newer than the
        // watermark (so the oracle accepts it) but far older than maxMarkAge, with an expiry
        // still in the future. This passed every check in the pre-remediation keeper:
        //   paused=false, threshold met, block.timestamp <= expiry, asOf != 0,
        //   asOf <= block.timestamp, payload != 0, asOf > max(watermark, latestValuation.asOf).
        // The current keeper does compare (earliest execution - asOf) against maxMarkAge.
        vm.warp(block.timestamp + maxMarkAge + 100);
        IAttestationOracle.AttestationInput memory a = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(MARGIN_MARK),
            asOf: watermark + 1,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++nonceCounter
        });
        assertGt(a.asOf, watermark, "keeper watermark check passes");
        assertLt(a.asOf, uint64(block.timestamp), "keeper asOf<=now check passes");
        assertGt(a.expiry, uint64(block.timestamp), "keeper expiry check passes");
        assertGt(uint256(block.timestamp) - a.asOf, maxMarkAge, "but the mark IS older than maxMarkAge");

        bytes[] memory sigs = _signedBundle(a);
        (bool ok, uint256 used) = _measure(a, sigs);
        assertFalse(ok, "a mark older than maxMarkAge must revert on-chain");
        emit log_named_uint("GAS WASTED stale-mark revert         ", used);
        assertTrue(realOracle.digestUsed(realOracle.attestationDigest(a)) == false, "rolled back -> keeper retries");
    }
}
