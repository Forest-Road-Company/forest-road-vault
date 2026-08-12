// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MtmAtomicExecutor} from "../../src/MtmAtomicExecutor.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {RealOracleFixture} from "../helpers/RealOracleFixture.sol";

contract NonThresholdFailureDefaultManager {
    error ProbeFailure();

    uint256 public marginCalls;

    function cureDeadline(uint256) external pure returns (uint64) {
        return 0;
    }

    function liquidate(uint256) external pure {
        revert ProbeFailure();
    }

    function marginCall(uint256) external {
        ++marginCalls;
    }

    function clearMarginCall(uint256) external pure {}
}

contract MalformedThresholdFailureDefaultManager {
    uint256 public marginCalls;

    function cureDeadline(uint256) external pure returns (uint64) {
        return 0;
    }

    function liquidate(uint256) external pure {
        bytes4 selector = IDefaultManager.DefaultManager_ThresholdNotBreached.selector;
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 4)
        }
    }

    function marginCall(uint256) external {
        ++marginCalls;
    }

    function clearMarginCall(uint256) external pure {}
}

contract CrossFacilityThresholdFailureDefaultManager {
    uint256 public marginCalls;

    function cureDeadline(uint256) external pure returns (uint64) {
        return 0;
    }

    function liquidate(uint256) external pure {
        revert IDefaultManager.DefaultManager_ThresholdNotBreached(999, 1, 2);
    }

    function marginCall(uint256) external {
        ++marginCalls;
    }

    function clearMarginCall(uint256) external pure {}
}

contract CrossFacilityNotDefaultableManager {
    uint256 public marginCalls;

    function cureDeadline(uint256) external pure returns (uint64) {
        return 0;
    }

    function liquidate(uint256) external pure {
        revert IDefaultManager.DefaultManager_NotDefaultable(999);
    }

    function marginCall(uint256) external {
        ++marginCalls;
    }

    function clearMarginCall(uint256) external pure {}
}

contract CrossFacilityCureMissManager {
    uint256 public marginCalls;

    function cureDeadline(uint256) external pure returns (uint64) {
        return 1;
    }

    function liquidate(uint256 tokenId) external pure {
        // canonical liquidation miss for THIS facility -> the executor may fall through
        revert IDefaultManager.DefaultManager_ThresholdNotBreached(tokenId, 6500, 8000);
    }

    function marginCall(uint256) external {
        ++marginCalls;
    }

    function clearMarginCall(uint256) external pure {
        // a cure miss shaped for a DIFFERENT facility must never be accepted as "no action"
        revert IDefaultManager.DefaultManager_ThresholdNotBreached(999, 6500, 6500);
    }
}

contract MtmAtomicExecutorTest is RealOracleFixture {
    uint256 internal constant PRINCIPAL = 500_000e18;
    uint256 internal constant ORIGINAL_MARK = 1_000_000e18;
    uint256 internal constant MARGIN_MARK = 769_230e18; // floor(500k * 10_000 / mark) == 6,500
    uint256 internal constant LIQUIDATION_MARK = 625_000e18; // exactly 8,000 bps
    uint256 internal constant HEALTHY_MARK = 1_000_000e18; // 5,000 bps
    uint256 internal constant IN_BAND_MARK = 760_000e18; // ~6,578 bps: margin band, below liquidation

    address internal keeperA = makeAddr("mtmKeeperA");
    address internal keeperB = makeAddr("mtmKeeperB");
    /// @dev Holds no role anywhere in the protocol (G8).
    address internal bystander = makeAddr("mtmBystander");

    MtmAtomicExecutor internal executor;

    function setUp() public override {
        super.setUp();
        executor = new MtmAtomicExecutor(address(realOracle), address(defaultManager));
    }

    function test_constructorPinsRolelessDependenciesAndRejectsBadTargets() public {
        assertEq(address(executor.oracle()), address(realOracle));
        assertEq(address(executor.defaultManager()), address(defaultManager));

        vm.expectRevert(MtmAtomicExecutor.MtmExecutor_ZeroAddress.selector);
        new MtmAtomicExecutor(address(0), address(defaultManager));
        vm.expectRevert(abi.encodeWithSelector(MtmAtomicExecutor.MtmExecutor_NoCode.selector, keeperA));
        new MtmAtomicExecutor(keeperA, address(defaultManager));
        vm.expectRevert(abi.encodeWithSelector(MtmAtomicExecutor.MtmExecutor_NoCode.selector, keeperA));
        new MtmAtomicExecutor(address(realOracle), keeperA);
    }

    function test_executeRejectsNonValuationBeforeConsumingItsDigest() public {
        IAttestationOracle.AttestationInput memory a = _input(
            77,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256("not-a-valuation"),
            uint64(block.timestamp)
        );
        bytes32 digest = realOracle.attestationDigest(a);
        bytes[] memory sigs = _signedBundle(a);

        vm.expectRevert(
            abi.encodeWithSelector(
                MtmAtomicExecutor.MtmExecutor_NotValuation.selector, IAttestationOracle.AttestationKind.DefaultDeclared
            )
        );
        executor.execute(a, sigs);
        assertFalse(realOracle.digestUsed(digest));
    }

    function test_executeExact6500OpensMarginCallForEitherRolelessKeeper() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, MARGIN_MARK);
        bytes32 digest = realOracle.attestationDigest(a);

        vm.expectEmit(true, true, true, true);
        emit MtmAtomicExecutor.MtmActionExecuted(id, digest, keeperA, MtmAtomicExecutor.Action.MarginCall);
        vm.prank(keeperA);
        MtmAtomicExecutor.Action action = executor.execute(a, sigs);

        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.MarginCall));
        (uint256 ltv,) = defaultManager.currentLtvBps(id);
        assertEq(ltv, 6500);
        assertEq(defaultManager.cureDeadline(id), uint64(block.timestamp + 1 days));
        assertTrue(realOracle.digestUsed(digest));
    }

    function test_executeExact8000ChoosesImmediateLiquidationNotMarginCall() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, LIQUIDATION_MARK);

        vm.prank(keeperB);
        MtmAtomicExecutor.Action action = executor.execute(a, sigs);

        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.Liquidate));
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
        assertEq(defaultManager.cureDeadline(id), 0, "hard breach never opened a lesser call");
    }

    function test_executeActiveCallFreshHealthyMarkClearsAtomically() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory breach, bytes[] memory breachSigs) =
            _freshValuation(id, MARGIN_MARK);
        vm.prank(keeperA);
        executor.execute(breach, breachSigs);
        assertGt(defaultManager.cureDeadline(id), 0);

        (IAttestationOracle.AttestationInput memory cure, bytes[] memory cureSigs) = _freshValuation(id, HEALTHY_MARK);
        vm.prank(keeperB);
        MtmAtomicExecutor.Action action = executor.execute(cure, cureSigs);

        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.ClearMarginCall));
        assertEq(defaultManager.cureDeadline(id), 0);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
    }

    function test_executeHardBreachLiquidatesEvenWithActiveCall() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory breach, bytes[] memory breachSigs) =
            _freshValuation(id, MARGIN_MARK);
        executor.execute(breach, breachSigs);
        assertGt(defaultManager.cureDeadline(id), 0);

        (IAttestationOracle.AttestationInput memory hard, bytes[] memory hardSigs) =
            _freshValuation(id, LIQUIDATION_MARK);
        MtmAtomicExecutor.Action action = executor.execute(hard, hardSigs);

        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.Liquidate));
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
        assertEq(defaultManager.cureDeadline(id), 0);
    }

    function test_executeCureExpiryBindsStrictlyOneSecondAfterDeadlineWithSecondFreshMark() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory breach, bytes[] memory breachSigs) =
            _freshValuation(id, MARGIN_MARK);
        executor.execute(breach, breachSigs);
        uint64 deadline = defaultManager.cureDeadline(id);

        vm.warp(deadline);
        (IAttestationOracle.AttestationInput memory atDeadline, bytes[] memory atDeadlineSigs) =
            _valuation(id, MARGIN_MARK, uint64(block.timestamp));
        bytes32 atDeadlineDigest = realOracle.attestationDigest(atDeadline);

        // ASSERTION INVERTED BY THE G8-L1 FIX — read this before "restoring" it.
        // This leg used to assert that the at-deadline relay REVERTED with
        // DefaultManager_ThresholdNotBreached(id, 6500, 6500) and rolled the mark back. That
        // was the defect itself: the cure leg was attempted unconditionally, so a still-breached
        // mark inside the cure window destroyed the keeper's whole relay and left the book on
        // the older valuation. The load-bearing property of this test is the STRICT one-second
        // cure-expiry boundary, and it is asserted more sharply than before: at the deadline no
        // protective action is taken (no liquidation, no new call, no cure) while the mark
        // itself now lands. Do not weaken the `Active` / unchanged-deadline assertions.
        MtmAtomicExecutor.Action atDeadlineAction = executor.execute(atDeadline, atDeadlineSigs);
        assertEq(uint256(atDeadlineAction), uint256(MtmAtomicExecutor.Action.NoActionAvailable));
        assertTrue(realOracle.digestUsed(atDeadlineDigest), "the at-deadline mark is kept, not discarded");
        (, uint64 acceptedAsOfAfter) = realOracle.latestValuation(id);
        assertEq(acceptedAsOfAfter, uint64(deadline), "the at-deadline mark is the accepted one");
        assertEq(
            uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "AT the deadline: no liquidation"
        );
        assertEq(
            defaultManager.cureDeadline(id),
            deadline,
            "AT the deadline: the standing call is neither cleared nor reopened"
        );

        vm.warp(uint256(deadline) + 1);
        (IAttestationOracle.AttestationInput memory afterDeadline, bytes[] memory afterDeadlineSigs) =
            _valuation(id, MARGIN_MARK, uint64(block.timestamp));
        MtmAtomicExecutor.Action action = executor.execute(afterDeadline, afterDeadlineSigs);
        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.Liquidate));
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
    }

    function test_executeNoActionRollsBackOtherwiseValidHealthyValuation() public {
        uint256 id = _liveDigitalFacility();
        (uint256 oldValue, uint64 oldAsOf) = realOracle.latestValuation(id);
        uint64 oldWatermark = realOracle.valuationWatermark(id);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, HEALTHY_MARK + 1);
        bytes32 digest = realOracle.attestationDigest(a);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, uint256(4999), uint256(6500)
            )
        );
        executor.execute(a, sigs);

        (uint256 valueAfter, uint64 asOfAfter) = realOracle.latestValuation(id);
        assertEq(valueAfter, oldValue);
        assertEq(asOfAfter, oldAsOf);
        assertEq(realOracle.valuationWatermark(id), oldWatermark);
        assertFalse(realOracle.digestUsed(digest));
    }

    function test_executeMalformedReorderedAndDuplicateBundlesFailClosed() public {
        uint256 id = _liveDigitalFacility();
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _freshValuation(id, MARGIN_MARK);
        bytes32 digest = realOracle.attestationDigest(a);

        bytes memory first = sigs[0];
        sigs[0] = sigs[1];
        sigs[1] = first;
        address low = vm.addr(attesterPk1) < vm.addr(attesterPk2) ? vm.addr(attesterPk1) : vm.addr(attesterPk2);
        address high = vm.addr(attesterPk1) < vm.addr(attesterPk2) ? vm.addr(attesterPk2) : vm.addr(attesterPk1);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, high, low));
        executor.execute(a, sigs);
        assertFalse(realOracle.digestUsed(digest));

        sigs[1] = sigs[0];
        sigs[0] = first;
        vm.prank(keeperA);
        executor.execute(a, sigs);
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, digest));
        vm.prank(keeperB);
        executor.execute(a, sigs);
    }

    function test_executeStaleMarkAndPausedManagerBothRollBackTheAttestation() public {
        uint256 id = _liveDigitalFacility();
        vm.warp(block.timestamp + 1 days + 2);
        (IAttestationOracle.AttestationInput memory stale, bytes[] memory staleSigs) =
            _valuation(id, LIQUIDATION_MARK, uint64(block.timestamp - 1 days - 1));
        bytes32 staleDigest = realOracle.attestationDigest(stale);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ValuationStale.selector, id, stale.asOf, uint64(1 days)
            )
        );
        executor.execute(stale, staleSigs);
        assertFalse(realOracle.digestUsed(staleDigest));

        (IAttestationOracle.AttestationInput memory fresh, bytes[] memory freshSigs) =
            _valuation(id, LIQUIDATION_MARK, uint64(block.timestamp));
        bytes32 freshDigest = realOracle.attestationDigest(fresh);
        vm.prank(guardian);
        defaultManager.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        executor.execute(fresh, freshSigs);
        assertFalse(realOracle.digestUsed(freshDigest));
    }

    function test_executeNeverDowngradesA_nonThresholdLiquidationFailure() public {
        NonThresholdFailureDefaultManager probe = new NonThresholdFailureDefaultManager();
        MtmAtomicExecutor strictExecutor = new MtmAtomicExecutor(address(realOracle), address(probe));
        IAttestationOracle.AttestationInput memory a =
            _input(999, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), uint64(block.timestamp));
        bytes32 digest = realOracle.attestationDigest(a);
        bytes[] memory sigs = _signedBundle(a);

        vm.expectRevert(NonThresholdFailureDefaultManager.ProbeFailure.selector);
        strictExecutor.execute(a, sigs);

        assertEq(probe.marginCalls(), 0, "non-threshold failures cannot fall back to a lesser action");
        assertFalse(realOracle.digestUsed(digest), "the failed action rolled back the attestation");
    }

    function test_executeNeverDowngradesMalformedOrCrossFacilityThresholdShapedFailures() public {
        IAttestationOracle.AttestationInput memory malformedInput =
            _input(998, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(1e18)), uint64(block.timestamp));
        bytes32 malformedDigest = realOracle.attestationDigest(malformedInput);
        MalformedThresholdFailureDefaultManager malformedProbe = new MalformedThresholdFailureDefaultManager();
        MtmAtomicExecutor malformedExecutor = new MtmAtomicExecutor(address(realOracle), address(malformedProbe));
        bytes[] memory malformedSigs = _signedBundle(malformedInput);

        vm.expectRevert(abi.encodePacked(IDefaultManager.DefaultManager_ThresholdNotBreached.selector));
        malformedExecutor.execute(malformedInput, malformedSigs);
        assertEq(malformedProbe.marginCalls(), 0);
        assertFalse(realOracle.digestUsed(malformedDigest));

        IAttestationOracle.AttestationInput memory crossFacilityInput =
            _input(998, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(2e18)), uint64(block.timestamp));
        bytes32 crossFacilityDigest = realOracle.attestationDigest(crossFacilityInput);
        CrossFacilityThresholdFailureDefaultManager crossFacilityProbe =
            new CrossFacilityThresholdFailureDefaultManager();
        MtmAtomicExecutor crossFacilityExecutor =
            new MtmAtomicExecutor(address(realOracle), address(crossFacilityProbe));
        bytes[] memory crossFacilitySigs = _signedBundle(crossFacilityInput);

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, 999, 1, 2));
        crossFacilityExecutor.execute(crossFacilityInput, crossFacilitySigs);
        assertEq(crossFacilityProbe.marginCalls(), 0);
        assertFalse(realOracle.digestUsed(crossFacilityDigest));
    }

    // ── G8 Lows: a bystander must not be able to turn a keeper relay into a total failure ──
    // Both scenarios below need NO privilege of any kind: `AttestationOracle.attest` is a
    // permissionless relay of a threshold-signed mark, and `DefaultManager.marginCall` /
    // `liquidate` are permissionless triggers. That is also why landing the mark instead of
    // reverting grants the keeper nothing new — anyone could already post the same signed mark
    // directly to the oracle. Do not "simplify" these back into a plain revert expectation.

    /// @notice G8-L1: a bystander's margin call used to make every executor relay of a
    ///         still-in-breach mark revert for the whole cure window, discarding the mark.
    function test_g8_bystanderMarginCallNoLongerRollsBackAnInBreachRelay() public {
        uint256 id = _liveDigitalFacility();

        (IAttestationOracle.AttestationInput memory seed, bytes[] memory seedSigs) = _freshValuation(id, MARGIN_MARK);
        vm.prank(bystander);
        realOracle.attest(seed, seedSigs);
        vm.prank(bystander);
        defaultManager.marginCall(id);
        uint64 standingDeadline = defaultManager.cureDeadline(id);
        assertGt(standingDeadline, 0, "the bystander opened the call with no privilege at all");

        (IAttestationOracle.AttestationInput memory relay, bytes[] memory relaySigs) = _freshValuation(id, IN_BAND_MARK);
        bytes32 digest = realOracle.attestationDigest(relay);

        vm.prank(keeperA);
        MtmAtomicExecutor.Action action = executor.execute(relay, relaySigs);

        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.NoActionAvailable));
        assertTrue(realOracle.digestUsed(digest), "the keeper's mark must land, not roll back");
        (uint256 value,) = realOracle.latestValuation(id);
        assertEq(value, IN_BAND_MARK, "the deteriorated mark is now on the books");
        assertEq(defaultManager.cureDeadline(id), standingDeadline, "the standing call is untouched");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
        (uint256 ltv,) = defaultManager.currentLtvBps(id);
        assertGe(ltv, 6500, "still in the margin band: no lesser action was skipped");
        assertLt(ltv, 8000, "and below liquidation: no stronger action was skipped");
    }

    /// @notice G8-L2: a bystander's liquidation used to brick the executor for that facility
    ///         permanently — every later relay reverted with DefaultManager_NotDefaultable.
    function test_g8_bystanderLiquidationNoLongerBricksTheExecutorForThatFacility() public {
        uint256 id = _liveDigitalFacility();

        (IAttestationOracle.AttestationInput memory seed, bytes[] memory seedSigs) =
            _freshValuation(id, LIQUIDATION_MARK);
        vm.prank(bystander);
        realOracle.attest(seed, seedSigs);
        vm.prank(bystander);
        defaultManager.liquidate(id);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));

        (IAttestationOracle.AttestationInput memory recovery, bytes[] memory recoverySigs) =
            _freshValuation(id, HEALTHY_MARK);
        bytes32 digest = realOracle.attestationDigest(recovery);

        vm.prank(keeperB);
        MtmAtomicExecutor.Action action = executor.execute(recovery, recoverySigs);

        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.NoActionAvailable));
        assertTrue(realOracle.digestUsed(digest), "a defaulted facility must still accept marks");
        (uint256 value,) = realOracle.latestValuation(id);
        assertEq(value, HEALTHY_MARK);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "no state change");
    }

    /// @notice The no-action outcome stays as provenance-strict as the fall-through it sits next
    ///         to: a NotDefaultable or cure-miss payload naming a DIFFERENT facility is bubbled.
    function test_g8_noActionOutcomeRejectsCrossFacilityShapedFailures() public {
        IAttestationOracle.AttestationInput memory notDefaultableInput =
            _input(997, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(3e18)), uint64(block.timestamp));
        bytes32 notDefaultableDigest = realOracle.attestationDigest(notDefaultableInput);
        CrossFacilityNotDefaultableManager notDefaultableProbe = new CrossFacilityNotDefaultableManager();
        MtmAtomicExecutor notDefaultableExecutor =
            new MtmAtomicExecutor(address(realOracle), address(notDefaultableProbe));
        bytes[] memory notDefaultableSigs = _signedBundle(notDefaultableInput);

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, 999));
        notDefaultableExecutor.execute(notDefaultableInput, notDefaultableSigs);
        assertEq(notDefaultableProbe.marginCalls(), 0);
        assertFalse(realOracle.digestUsed(notDefaultableDigest));

        IAttestationOracle.AttestationInput memory cureInput =
            _input(996, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(4e18)), uint64(block.timestamp));
        bytes32 cureDigest = realOracle.attestationDigest(cureInput);
        CrossFacilityCureMissManager cureProbe = new CrossFacilityCureMissManager();
        MtmAtomicExecutor cureExecutor = new MtmAtomicExecutor(address(realOracle), address(cureProbe));
        bytes[] memory cureSigs = _signedBundle(cureInput);

        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ThresholdNotBreached.selector, 999, 6500, 6500)
        );
        cureExecutor.execute(cureInput, cureSigs);
        assertEq(cureProbe.marginCalls(), 0);
        assertFalse(realOracle.digestUsed(cureDigest));
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
        return _valuation(id, value, uint64(block.timestamp));
    }

    function _valuation(uint256 id, uint256 value, uint64 asOf)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = _input(id, IAttestationOracle.AttestationKind.Valuation, bytes32(value), asOf);
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
}
