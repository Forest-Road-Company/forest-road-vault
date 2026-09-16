// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Vm} from "forge-std/Vm.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

interface IRunbookMainnetSafe {
    function VERSION() external view returns (string memory);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 safeNonce
    ) external view returns (bytes32);
    function approveHash(bytes32 hashToApprove) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @dev Test-only stand-in for a Safe MultiSend or reviewed keeper executor. The entire loop is
///      one external call, so a failure in any leg bubbles and rolls every earlier leg back.
///      This contract is rehearsal equipment, not production protocol code.
contract RunbookAtomicBatch {
    error RunbookAtomicBatch_LengthMismatch();

    function execute(address[] calldata targets, bytes[] calldata calls) external {
        if (targets.length != calls.length) revert RunbookAtomicBatch_LengthMismatch();
        for (uint256 i = 0; i < targets.length; ++i) {
            (bool ok, bytes memory returndata) = targets[i].call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
    }
}

/// @title OperationalRunbookRehearsalFork
/// @notice Executable rehearsal of Mainnet Launch Runbook Sections 7.5 through 7.8 on the pinned
///         canonical-USDC mainnet fork. These tests prove EVM atomicity, exact thresholds,
///         rollback, timelock role cleanup, keeper race/reorg recovery, threshold-approved calls
///         by the configured Treasury Safe proxy, and post-state checks.
///         They do not claim to prove private relay delivery, AWS custody independence, Safe owner
///         policy, independent hosting, alert delivery, or human response time; those require the
///         real production systems and remain ceremony evidence.
contract OperationalRunbookRehearsalForkTest is ForkLifecycleFixture {
    uint256 private constant CONTROL_FORK_BLOCK = 25_672_419;
    uint256 private constant CLASS5 = Config.CLASS_DIGITAL_ASSETS;
    bytes32 private constant DA_BORROWER = keccak256("RUNBOOK_DA_BORROWER");
    uint256 private constant P = 260_000e18;
    uint256 private constant V_ORIG = 1_000_000e18;
    uint256 private constant V_MARGIN_MISS = 400_001e18; // 6,499 bps
    uint256 private constant V_MARGIN_EXACT = 400_000e18; // 6,500 bps
    uint256 private constant V_LIQ_EXACT = 325_000e18; // 8,000 bps
    uint256 private constant V_HEALTHY = 500_000e18; // 5,200 bps
    uint256 private constant PAST_DUE_INTEREST = 10_000e18;
    bytes32 private constant PAST_DUE_PAYMENT_ID = keccak256("runbook-past-due-payment");
    bytes32 private constant PAST_DUE_CURE_EVIDENCE = keccak256("runbook-past-due-cure");

    struct PastDuePlan {
        uint256 tokenId;
        uint256 marked;
        uint64 previousDue;
        uint64 nextDue;
        IAttestationOracle.AttestationInput paymentAttestation;
        IAttestationOracle.AttestationInput cureAttestation;
        address[] targets;
        bytes[] calls;
    }

    RunbookAtomicBatch private operationsBatch;
    IRunbookMainnetSafe private recoverySafe;
    address private keeperA = makeAddr("runbookKeeperA");
    address private keeperB = makeAddr("runbookKeeperB");

    function _forkBlock() internal pure override returns (uint256) {
        return CONTROL_FORK_BLOCK;
    }

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;

        address configuredTreasury = vm.envOr("MAINNET_FR_TREASURY", address(0));
        if (configuredTreasury == address(0) || configuredTreasury.code.length == 0) {
            forkReady = false;
            return;
        }

        operationsBatch = new RunbookAtomicBatch();
        recoverySafe = IRunbookMainnetSafe(configuredTreasury);
        assertEq(
            keccak256(bytes(recoverySafe.VERSION())), keccak256(bytes("1.4.1")), "review Treasury Safe version drifted"
        );
        assertEq(recoverySafe.getOwners().length, 4, "review Treasury Safe owner count drifted");
        assertEq(recoverySafe.getThreshold(), 2, "review Treasury Safe threshold drifted");

        // ForkLifecycleFixture intentionally stops after seed so most fork suites can retain
        // bootstrap control. This rehearsal needs the actual post-deploy timelock-admin graph.
        // Keep the test operator as the disclosed test-only co-admin so it can install the two
        // contract-shaped ceremony actors below; the timelock receives the same module admin
        // authority that production uses.
        Ctx memory c;
        c.deployer = ops;
        c.opsAdmin = ops;
        c.queueKeeper = ops; // AUDIT FIX (D7-01 round 5): SETTLEMENT_KEEPER_ROLE holder; Deploy._wire fails closed on zero
        c.frTreasury = ops;
        c.feeRecipient = ops;
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true;
        _handover(dep, c);

        // The contract-shaped operations Safe is the caller seen by both role-gated modules.
        // Attestation relay and MTM actions themselves remain permissionless.
        waterfall.grantRole(Roles.SERVICER_ROLE, address(operationsBatch));
        defaultManager.grantRole(Roles.SERVICER_ROLE, address(operationsBatch));
    }

    // ── Section 7.5: DefaultDeclared attestation + accounting effect ─────

    function test_fork_runbook_defaultDeclaration_isAtomic_andLateFailureRollsBack() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 tokenId = _originateAndFund(1_000_000e18);
        bytes32 evidence = keccak256("runbook-default-evidence");

        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _signedInput(
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, evidence)),
            uint64(block.timestamp)
        );

        (address[] memory targets, bytes[] memory calls) = _twoCallBatch(
            address(oracle),
            abi.encodeCall(oracle.attest, (a, sigs)),
            address(defaultManager),
            abi.encodeCall(defaultManager.declareDefault, (tokenId, keccak256("wrong-evidence")))
        );

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, tokenId));
        operationsBatch.execute(targets, calls);

        assertFalse(
            oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.DefaultDeclared),
            "failed batch rolled the attestation back"
        );
        assertFalse(oracle.digestUsed(oracle.attestationDigest(a)), "failed batch did not burn the signed digest");
        assertEq(
            uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Active), "facility stayed active"
        );

        calls[1] = abi.encodeCall(defaultManager.declareDefault, (tokenId, evidence));
        vm.recordLogs();
        vm.prank(keeperA);
        operationsBatch.execute(targets, calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "atomic batch entered default"
        );
        assertTrue(
            oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.DefaultDeclared),
            "default fact remains as the remedy record"
        );
        assertTrue(_saw(logs, keccak256("AttestationSatisfied(uint256,uint8,bytes32,uint64)")));
        assertTrue(_saw(logs, keccak256("DefaultDeclared(uint256,uint256,bytes32)")));
        assertTrue(_saw(logs, keccak256("RemedyInitiated(uint256,uint256,bytes32)")));
    }

    // ── Section 7.6: signed valuation + mandatory MTM action ─────────────

    function test_fork_runbook_mtm_exactThresholds_andAtomicRollback() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        (uint256 originalMark,) = oracle.latestValuation(tokenId);
        assertEq(originalMark, V_ORIG);
        _assertMtmThresholdMissRollsBack(tokenId);

        _executeValuationAction(tokenId, V_MARGIN_EXACT, abi.encodeCall(defaultManager.marginCall, (tokenId)), keeperB);
        assertEq(defaultManager.cureDeadline(tokenId), uint64(block.timestamp + 1 days));
        (uint256 marginLtv,) = defaultManager.currentLtvBps(tokenId);
        assertEq(marginLtv, 6500, "margin action binds at equality");

        _executeValuationAction(tokenId, V_HEALTHY, abi.encodeCall(defaultManager.clearMarginCall, (tokenId)), keeperA);
        assertEq(defaultManager.cureDeadline(tokenId), 0, "healthy fresh bundle cured in the same transaction");

        _executeValuationAction(tokenId, V_LIQ_EXACT, abi.encodeCall(defaultManager.liquidate, (tokenId)), keeperB);
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "hard liquidation binds at 8,000 bps"
        );
    }

    function test_fork_runbook_mtm_cureExpiry_requiresSecondFreshBundle_oneSecondAfterDeadline() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _warp(1);
        (IAttestationOracle.AttestationInput memory margin, bytes[] memory marginSigs) = _signedInput(
            tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(V_MARGIN_EXACT), uint64(block.timestamp)
        );
        (address[] memory targets, bytes[] memory calls) = _twoCallBatch(
            address(oracle),
            abi.encodeCall(oracle.attest, (margin, marginSigs)),
            address(defaultManager),
            abi.encodeCall(defaultManager.marginCall, (tokenId))
        );
        vm.prank(keeperA);
        operationsBatch.execute(targets, calls);
        uint64 deadline = defaultManager.cureDeadline(tokenId);

        _warp(deadline - block.timestamp);
        assertEq(block.timestamp, deadline);
        (IAttestationOracle.AttestationInput memory atDeadline, bytes[] memory deadlineSigs) = _signedInput(
            tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(V_MARGIN_EXACT), uint64(block.timestamp)
        );
        calls[0] = abi.encodeCall(oracle.attest, (atDeadline, deadlineSigs));
        calls[1] = abi.encodeCall(defaultManager.liquidate, (tokenId));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 6500, uint256(8000)
            )
        );
        vm.prank(keeperA);
        operationsBatch.execute(targets, calls);
        assertFalse(oracle.digestUsed(oracle.attestationDigest(atDeadline)), "deadline failure rolled back the mark");

        _warp(1);
        (IAttestationOracle.AttestationInput memory afterDeadline, bytes[] memory afterDeadlineSigs) = _signedInput(
            tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(V_MARGIN_EXACT), uint64(block.timestamp)
        );
        calls[0] = abi.encodeCall(oracle.attest, (afterDeadline, afterDeadlineSigs));
        vm.prank(keeperB);
        operationsBatch.execute(targets, calls);
        assertEq(uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Defaulted));
    }

    function test_fork_runbook_mtm_reorgFailover_andKeeperRace_areIdempotent() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _warp(1);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _signedInput(
            tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(V_MARGIN_EXACT), uint64(block.timestamp)
        );
        bytes32 digest = oracle.attestationDigest(a);
        (address[] memory targets, bytes[] memory calls) = _twoCallBatch(
            address(oracle),
            abi.encodeCall(oracle.attest, (a, sigs)),
            address(defaultManager),
            abi.encodeCall(defaultManager.marginCall, (tokenId))
        );

        uint256 beforeInclusion = vm.snapshotState();
        vm.prank(keeperA);
        operationsBatch.execute(targets, calls);
        assertGt(defaultManager.cureDeadline(tokenId), 0, "keeper A included the action");

        assertTrue(vm.revertToState(beforeInclusion), "simulated reorg removed keeper A's inclusion");
        assertEq(defaultManager.cureDeadline(tokenId), 0, "reorg restored the pre-action state");
        assertFalse(oracle.digestUsed(digest), "reorg restored the signed bundle too");

        vm.prank(keeperB);
        operationsBatch.execute(targets, calls);
        uint64 finalDeadline = defaultManager.cureDeadline(tokenId);
        assertGt(finalDeadline, 0, "keeper B completed failover");

        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, digest));
        vm.prank(keeperA);
        operationsBatch.execute(targets, calls);
        assertEq(defaultManager.cureDeadline(tokenId), finalDeadline, "losing keeper could not duplicate the action");
    }

    // ── Section 7.7: payment-clock cure + PastDueCured clearance ─────────

    function test_fork_runbook_pastDuePaymentAndClear_isAtomic_andLateFailureRollsBack() public onFork {
        PastDuePlan memory p = _preparePastDuePlan();
        p.calls[3] = abi.encodeCall(defaultManager.clearPastDue, (p.tokenId, keccak256("wrong-cure")));

        uint256 borrowerBefore = IERC20(USDC).balanceOf(borrower);
        uint256 reserveBefore = IERC20(USDC).balanceOf(address(reserves));
        uint256 supplyBefore = usdfr.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, p.tokenId));
        vm.prank(keeperA);
        operationsBatch.execute(p.targets, p.calls);

        assertEq(IERC20(USDC).balanceOf(borrower), borrowerBefore, "late failure returned payer USDC");
        assertEq(IERC20(USDC).balanceOf(address(reserves)), reserveBefore, "late failure returned reserve state");
        assertEq(usdfr.totalSupply(), supplyBefore, "late failure rolled fee/yield mints back");
        assertEq(bridge.facility(p.tokenId).nextPaymentDue, p.previousDue, "clock did not advance");
        assertEq(defaultManager.pastDueContribution(p.tokenId), p.marked, "past-due mark stayed intact");
        assertFalse(oracle.digestUsed(oracle.attestationDigest(p.paymentAttestation)));
        assertFalse(oracle.digestUsed(oracle.attestationDigest(p.cureAttestation)));

        p.calls[3] = abi.encodeCall(defaultManager.clearPastDue, (p.tokenId, PAST_DUE_CURE_EVIDENCE));
        vm.recordLogs();
        vm.prank(keeperB);
        operationsBatch.execute(p.targets, p.calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(bridge.facility(p.tokenId).nextPaymentDue, p.nextDue, "payment clock advanced");
        assertEq(defaultManager.pastDueContribution(p.tokenId), 0, "same batch cleared the old mark");
        assertFalse(oracle.isSatisfied(p.tokenId, IAttestationOracle.AttestationKind.PaymentReceived));
        assertFalse(oracle.isSatisfied(p.tokenId, IAttestationOracle.AttestationKind.PastDueCured));
        assertTrue(_saw(logs, keccak256("Distributed(uint256,bytes32,address,uint256,uint256,uint256,uint256)")));
        assertTrue(_saw(logs, keccak256("NextPaymentDueSet(uint256,uint64,uint64)")));
        assertTrue(_saw(logs, keccak256("PastDueCleared(uint256,uint256,uint256)")));
    }

    // ── Section 7.8: permissionless observation + adjudicated loss + timelock cure ────

    function test_fork_runbook_reserveShortfall_exactTimelockRecapitalization_andRoleCleanup() public onFork {
        uint256 lossUnits = 1_000e6;
        uint256 lossValue = reserves.normalizeUSDC(lossUnits);
        _mintFromUSDC(alice, 100_000e6);
        _stake(alice, lossValue);
        uint256 supplyBeforeLoss = controller.totalUSDfr();
        uint256 idleBeforeLoss = reserves.idleUSDC();
        uint256 liveBeforeLoss = IERC20(USDC).balanceOf(address(reserves));
        assertEq(idleBeforeLoss, liveBeforeLoss, "precondition: custody and idle ledger agree");

        controller.pause();
        deal(USDC, address(reserves), liveBeforeLoss - lossUnits);
        uint256 armId;
        {
            vm.prank(carol);
            uint256 observed = reserves.reconcileIdleUSDC();
            assertEq(observed, lossUnits, "permissionless checkpoint measured the native-unit shortfall");
            assertEq(reserves.idleUSDC(), idleBeforeLoss, "observation cannot write down backing");
            assertEq(controller.totalUSDfr(), supplyBeforeLoss, "observation did not move absorbing capital");
            assertTrue(reserves.reserveLossExitsLocked(), "objective shortfall closes protected exits immediately");

            uint256 expectedIncidentId;
            bytes32 evidenceHash = keccak256("runbook-reserve-shortfall-arm");
            vm.prank(ops);
            (armId, expectedIncidentId) = reserves.armReserveLossFreeze(evidenceHash);
            vm.prank(timelock);
            (uint256 incidentId, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidenceHash, lossValue);
            assertEq(incidentId, expectedIncidentId, "incident id is derived from the Guardian arm");
            assertEq(actualLoss, lossValue);
        }
        assertEq(controller.totalUSDfr(), supplyBeforeLoss - lossValue, "the loss was allocated before backing fell");
        assertTrue(controller.backingInvariantHolds(), "reserve-loss allocation preserves backing atomically");

        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(timelock));
        assertFalse(reserves.hasRole(Roles.CONTROLLER_ROLE, address(tl)), "timelock starts without deposit authority");
        assertFalse(reserves.hasRole(Roles.CONTROLLER_ROLE, address(recoverySafe)), "Recovery Safe has no role");

        deal(USDC, address(recoverySafe), lossUnits);
        _executeRecoverySafeCall(USDC, abi.encodeCall(IERC20.approve, (address(reserves), lossUnits)));
        assertEq(IERC20(USDC).allowance(address(recoverySafe), address(reserves)), lossUnits);

        // Deliberately fail AFTER the grant and exact deposit. Timelock atomicity must undo
        // the token transfer, ledger credit, allowance consumption and temporary role.
        {
            (address[] memory badTargets, uint256[] memory badValues, bytes[] memory badCalls) =
                _recoveryBatch(address(tl), address(recoverySafe), lossUnits, true);
            bytes32 badSalt = keccak256("runbook-recovery-intentional-rollback");
            _schedule(tl, badTargets, badValues, badCalls, badSalt);
            _warp(tl.getMinDelay());
            vm.expectRevert(IReserveManager.ReserveManager_ZeroAmount.selector);
            vm.prank(keeperA);
            tl.executeBatch(badTargets, badValues, badCalls, bytes32(0), badSalt);
        }
        assertEq(IERC20(USDC).balanceOf(address(recoverySafe)), lossUnits, "failed batch returned Safe funds");
        assertEq(IERC20(USDC).allowance(address(recoverySafe), address(reserves)), lossUnits, "allowance rolled back");
        assertEq(reserves.idleUSDC(), idleBeforeLoss - lossUnits, "failed batch returned the ledger");
        assertFalse(reserves.hasRole(Roles.CONTROLLER_ROLE, address(tl)), "failed batch returned the role graph");

        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _recoveryBatch(address(tl), address(recoverySafe), lossUnits, false);
        bytes32 salt = keccak256("runbook-recovery-success");
        _schedule(tl, targets, values, calls, salt);
        _warp(tl.getMinDelay());
        vm.recordLogs();
        vm.prank(keeperB); // execution is open, as deployed
        tl.executeBatch(targets, values, calls, bytes32(0), salt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(USDC).balanceOf(address(reserves)), liveBeforeLoss, "live custody restored exactly");
        assertEq(reserves.idleUSDC(), idleBeforeLoss, "idle ledger restored by the exact deposit path");
        assertGe(reserves.totalBackingValue(), usdfr.totalSupply(), "backing restored before unpause");
        assertEq(controller.totalUSDfr(), supplyBeforeLoss - lossValue, "recapitalization cannot reverse realized loss");
        assertEq(IERC20(USDC).allowance(address(recoverySafe), address(reserves)), 0, "exact approval consumed");
        assertFalse(reserves.hasRole(Roles.CONTROLLER_ROLE, address(tl)), "temporary deposit role revoked");
        assertFalse(reserves.hasRole(Roles.CONTROLLER_ROLE, address(recoverySafe)), "Safe still has no protocol role");
        assertTrue(_saw(logs, keccak256("RoleGranted(bytes32,address,address)")));
        assertTrue(_saw(logs, keccak256("USDCDeposited(address,uint256,uint256)")));
        assertTrue(_saw(logs, keccak256("RoleRevoked(bytes32,address,address)")));

        vm.prank(timelock);
        reserves.finalizeAndDisable(armId, keccak256(abi.encode("runbook-finalize", armId)));

        controller.unpause();
        assertFalse(controller.paused(), "user controller unpaused only after every post-check");
        assertTrue(controller.backingInvariantHolds());
    }

    function test_fork_runbook_directUSDCTransfer_neverRepairsRecognizedBacking() public onFork {
        _mintFromUSDC(alice, 100_000e6);
        uint256 donation = 2_000e6;
        uint256 idleBefore = reserves.idleUSDC();
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 liveBefore = IERC20(USDC).balanceOf(address(reserves));

        deal(USDC, address(recoverySafe), donation);
        _executeRecoverySafeCall(USDC, abi.encodeCall(IERC20.transfer, (address(reserves), donation)));
        assertEq(IERC20(USDC).balanceOf(address(reserves)), liveBefore + donation, "tokens arrived live");
        assertEq(reserves.idleUSDC(), idleBefore, "unsolicited tokens did not alter the ledger");
        assertEq(reserves.totalBackingValue(), backingBefore, "unsolicited tokens did not inflate backing");

        vm.prank(carol);
        reserves.reconcileIdleUSDC();
        assertEq(reserves.idleUSDC(), idleBefore, "permissionless reconciliation never ratchets upward");
        assertEq(reserves.totalBackingValue(), backingBefore);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _signedInput(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        private
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        sigs[0] = _runbookSign(lo, digest);
        sigs[1] = _runbookSign(hi, digest);
    }

    function _runbookSign(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _twoCallBatch(address first, bytes memory firstCall, address second, bytes memory secondCall)
        private
        pure
        returns (address[] memory targets, bytes[] memory calls)
    {
        targets = new address[](2);
        calls = new bytes[](2);
        targets[0] = first;
        targets[1] = second;
        calls[0] = firstCall;
        calls[1] = secondCall;
    }

    function _assertMtmThresholdMissRollsBack(uint256 tokenId) private {
        _warp(1);
        (IAttestationOracle.AttestationInput memory miss, bytes[] memory sigs) = _signedInput(
            tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(V_MARGIN_MISS), uint64(block.timestamp)
        );
        (address[] memory targets, bytes[] memory calls) = _twoCallBatch(
            address(oracle),
            abi.encodeCall(oracle.attest, (miss, sigs)),
            address(defaultManager),
            abi.encodeCall(defaultManager.marginCall, (tokenId))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 6499, uint256(6500)
            )
        );
        vm.prank(keeperA);
        operationsBatch.execute(targets, calls);
        (uint256 markAfterFailedBatch,) = oracle.latestValuation(tokenId);
        assertEq(markAfterFailedBatch, V_ORIG, "the rejected action rolled its new valuation back");
        assertFalse(oracle.digestUsed(oracle.attestationDigest(miss)), "failed action did not consume the bundle");
        assertEq(defaultManager.cureDeadline(tokenId), 0);
    }

    function _executeValuationAction(uint256 tokenId, uint256 value, bytes memory action, address keeper) private {
        _warp(1);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signedInput(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(value), uint64(block.timestamp));
        (address[] memory targets, bytes[] memory calls) =
            _twoCallBatch(address(oracle), abi.encodeCall(oracle.attest, (a, sigs)), address(defaultManager), action);
        vm.prank(keeper);
        operationsBatch.execute(targets, calls);
    }

    function _preparePastDuePlan() private returns (PastDuePlan memory p) {
        _mintFromUSDC(alice, 2_000_000e6);
        p.tokenId = _originateAndFund(1_000_000e18);
        ClaimBridge.Facility memory facility = bridge.facility(p.tokenId);
        p.previousDue = facility.nextPaymentDue;
        p.nextDue = facility.nextPaymentDue + facility.paymentInterval;
        _warp(uint256(facility.nextPaymentDue) + defaultManager.graceWindow(facility.classId) + 1 - block.timestamp);
        defaultManager.markPastDue(p.tokenId);
        p.marked = defaultManager.pastDueContribution(p.tokenId);
        assertEq(p.marked, 1_000_000e18);
        assertGt(p.nextDue, block.timestamp, "the attested payment restores the clock");

        uint256 usdcAmount = PAST_DUE_INTEREST / 1e12;
        deal(USDC, borrower, usdcAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), usdcAmount);

        p.targets = new address[](4);
        p.calls = new bytes[](4);
        p.targets[0] = address(oracle);
        p.targets[1] = address(waterfall);
        p.targets[2] = address(oracle);
        p.targets[3] = address(defaultManager);

        {
            IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
                tokenId: p.tokenId,
                paymentId: PAST_DUE_PAYMENT_ID,
                payer: borrower,
                interest: PAST_DUE_INTEREST,
                principal: 0,
                nextPaymentDue: p.nextDue
            });
            bytes[] memory paymentSigs;
            (p.paymentAttestation, paymentSigs) = _signedInput(
                p.tokenId,
                IAttestationOracle.AttestationKind.PaymentReceived,
                keccak256(
                    abi.encode(
                        PAST_DUE_PAYMENT_ID,
                        p.tokenId,
                        USDC,
                        borrower,
                        usdcAmount,
                        PAST_DUE_INTEREST,
                        uint256(0),
                        p.nextDue
                    )
                ),
                uint64(block.timestamp)
            );
            p.calls[0] = abi.encodeCall(oracle.attest, (p.paymentAttestation, paymentSigs));
            p.calls[1] = abi.encodeCall(waterfall.distribute, (payment));
        }

        {
            bytes[] memory cureSigs;
            (p.cureAttestation, cureSigs) = _signedInput(
                p.tokenId,
                IAttestationOracle.AttestationKind.PastDueCured,
                keccak256(abi.encode(p.tokenId, PAST_DUE_CURE_EVIDENCE)),
                uint64(block.timestamp)
            );
            p.calls[2] = abi.encodeCall(oracle.attest, (p.cureAttestation, cureSigs));
        }
    }

    function _liveDigitalFacility() private returns (uint256 tokenId) {
        _mintFromUSDC(alice, 2_000_000e6);
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 180 days);
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(CLASS5, DA_BORROWER, bytes32(0), P, 5000, 1000, maturity, keccak256("runbook-da-ref"));
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, bridge.creditTermsHash(terms));
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(V_ORIG));
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, bridge.creditTermsHash(terms));
        vm.prank(ops);
        assertEq(bridge.originate(ops, terms), tokenId);
        vm.prank(ops);
        waterfall.fund(tokenId, P / 1e12);
    }

    function _recoveryBatch(address tl, address safe, uint256 amount, bool appendFailure)
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        uint256 length = appendFailure ? 4 : 3;
        targets = new address[](length);
        values = new uint256[](length);
        calls = new bytes[](length);
        for (uint256 i = 0; i < length; ++i) {
            targets[i] = address(reserves);
        }
        calls[0] = abi.encodeCall(reserves.grantRole, (Roles.CONTROLLER_ROLE, tl));
        calls[1] = abi.encodeCall(reserves.depositUSDC, (safe, amount));
        if (appendFailure) {
            calls[2] = abi.encodeCall(reserves.depositUSDC, (safe, 0));
            calls[3] = abi.encodeCall(reserves.revokeRole, (Roles.CONTROLLER_ROLE, tl));
        } else {
            calls[2] = abi.encodeCall(reserves.revokeRole, (Roles.CONTROLLER_ROLE, tl));
        }
    }

    /// @dev Rehearses the real Treasury Safe's threshold path with Foundry impersonation on the
    ///      disposable fork. No owner key is loaded and no transaction is proposed or broadcast.
    function _executeRecoverySafeCall(address to, bytes memory data) private {
        uint256 safeNonce = recoverySafe.nonce();
        bytes32 transactionHash =
            recoverySafe.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), safeNonce);
        address[] memory owners = recoverySafe.getOwners();
        (address first, address second) = owners[0] < owners[1] ? (owners[0], owners[1]) : (owners[1], owners[0]);

        vm.prank(first);
        recoverySafe.approveHash(transactionHash);
        vm.prank(second);
        recoverySafe.approveHash(transactionHash);

        bytes memory approvedHashSignatures = abi.encodePacked(
            bytes32(uint256(uint160(first))),
            bytes32(0),
            uint8(1),
            bytes32(uint256(uint160(second))),
            bytes32(0),
            uint8(1)
        );
        assertTrue(
            recoverySafe.execTransaction(
                to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), approvedHashSignatures
            ),
            "threshold-approved Treasury Safe call failed"
        );
    }

    function _schedule(
        TimelockControllerUpgradeable tl,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calls,
        bytes32 salt
    ) private {
        uint256 delay = tl.getMinDelay();
        vm.prank(dep.governor);
        tl.scheduleBatch(targets, values, calls, bytes32(0), salt, delay);
    }

    function _saw(Vm.Log[] memory logs, bytes32 topic0) private pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }
}
