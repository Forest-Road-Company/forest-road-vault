// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {FRGovernor} from "../../src/FRGovernor.sol";
import {GroveVotesAggregator} from "../../src/GroveVotesAggregator.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";

contract ForkToggleImpairment is IImpairmentSource {
    bool internal unavailable;

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        if (unavailable) revert("fork impairment unavailable");
        return 0;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        if (unavailable) revert("fork performance impairment unavailable");
        return 0;
    }
}

/// @title GovernanceFork — the WHOLE governance path, on a pinned mainnet fork
/// @notice `FullLifecycleFork` exercises the credit/liquidity stack. This file exercises the
///         thing that CONTROLS it: `FRGovernor` -> `TimelockController` -> a real parameter
///         landing on a deployed module, including the 2-day timelock that no live-testnet QA
///         run has ever waited out (`script/QA.s.sol` DEFERRED every time-gated step).
///
///         Every test carries `onFork`, so a run without an RPC key SKIPS rather than
///         reporting a false pass.
///
/// @dev DEPLOYMENT POSTURE — the one place this file departs from the fixture, stated plainly.
///      `ForkLifecycleFixture` deliberately does NOT run `Deploy._handover`, so it keeps the
///      operator posture (the deployer holds `DEFAULT_ADMIN_ROLE` everywhere and can turn
///      parameters directly). Under that posture the TIMELOCK holds `DEFAULT_ADMIN_ROLE` on
///      NOTHING, so a governance proposal could not land a single parameter change and every
///      test here would be theatre. `setUp` therefore calls the REAL `Deploy._handover`
///      (`keepOpsAdmin = true`, i.e. the exact posture recorded in
///      `deployments/11155111.json`) on top of the fixture: the timelock GAINS
///      `DEFAULT_ADMIN_ROLE` on every module, `RESERVE_ADMIN_ROLE` moves to the timelock, and
///      the deployer's temporary timelock `DEFAULT_ADMIN_ROLE` is renounced. Nothing in the
///      fixture is modified; the handover is the deploy script's own code path.
///
///      GOVERNANCE ARITHMETIC at these parameters (Config): GROVE supply 1e27, quorum 4% =
///      40,000,000e18, proposal threshold 1,000,000e18, voting delay 1 day, voting period
///      7 days, timelock min delay 2 days. A full lifecycle therefore takes 10 days + 2s.
contract GovernanceForkTest is ForkLifecycleFixture {
    // ── EIP-1967 implementation slot (upgrade assertions) ────────────────
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev `TimelockController.OperationState.Ready` encoded the way the timelock encodes it.
    bytes32 internal constant READY_BITMAP = bytes32(uint256(1) << 2);

    /// @dev 4% of the fixed 1e27 GROVE supply.
    uint256 internal constant QUORUM = 40_000_000e18;

    FRGovernor internal governor;
    GroveVotesAggregator internal agg;
    TimelockControllerUpgradeable internal tl;

    /// @dev An actor whose ONLY governance power is staked GROVE (L-02 headline).
    address internal staker = makeAddr("forkStakedOnlyVoter");

    /// @dev A whole proposal, kept together so `queue`/`execute`/`cancel` re-derive the
    ///      identical id rather than rebuilding the arrays by hand each time.
    struct Prop {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string desc;
    }

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;

        governor = FRGovernor(payable(dep.governor));
        agg = GroveVotesAggregator(dep.votesAggregator);
        tl = TimelockControllerUpgradeable(payable(dep.timelock));

        // The production handover (see the contract NatSpec). Without it the timelock holds
        // DEFAULT_ADMIN on no module and governance cannot change anything.
        Ctx memory hc;
        hc.deployer = ops;
        hc.opsAdmin = ops;
        hc.proposalGuardian = makeAddr("governanceForkProposalGuardian");
        hc.queueKeeper = ops; // AUDIT FIX (D7-01 round 5): SETTLEMENT_KEEPER_ROLE holder; Deploy._wire fails closed on zero
        hc.frTreasury = ops;
        hc.feeRecipient = ops;
        hc.attester2 = attester2Addr;
        hc.keepOpsAdmin = true;
        _handover(dep, hc);

        // Genesis delegation and the handover are checkpointed at the CURRENT timestamp;
        // `propose` reads `getVotes(proposer, clock() - 1)`, so move one second past them or
        // the treasury would read zero votes and could not propose.
        _warp(1);
    }

    // ── proposal helpers ─────────────────────────────────────────────────

    function _prop1(address target, bytes memory data, string memory desc) internal pure returns (Prop memory p) {
        p.targets = new address[](1);
        p.targets[0] = target;
        p.values = new uint256[](1);
        p.calldatas = new bytes[](1);
        p.calldatas[0] = data;
        p.desc = desc;
    }

    function _prop2(address t0, bytes memory d0, address t1, bytes memory d1, string memory desc)
        internal
        pure
        returns (Prop memory p)
    {
        p.targets = new address[](2);
        p.targets[0] = t0;
        p.targets[1] = t1;
        p.values = new uint256[](2);
        p.calldatas = new bytes[](2);
        p.calldatas[0] = d0;
        p.calldatas[1] = d1;
        p.desc = desc;
    }

    function _prop4(
        address t0,
        bytes memory d0,
        address t1,
        bytes memory d1,
        address t2,
        bytes memory d2,
        address t3,
        bytes memory d3,
        string memory desc
    ) internal pure returns (Prop memory p) {
        p.targets = new address[](4);
        p.targets[0] = t0;
        p.targets[1] = t1;
        p.targets[2] = t2;
        p.targets[3] = t3;
        p.values = new uint256[](4);
        p.calldatas = new bytes[](4);
        p.calldatas[0] = d0;
        p.calldatas[1] = d1;
        p.calldatas[2] = d2;
        p.calldatas[3] = d3;
        p.desc = desc;
    }

    /// @dev The canonical "turn a real dial on a deployed module" proposal used throughout.
    function _bpsProp(uint16 bps, string memory desc) internal view returns (Prop memory) {
        return _prop1(address(queue), abi.encodeCall(queue.setEpochLiquidityBps, (bps)), desc);
    }

    function _descHash(Prop memory p) internal pure returns (bytes32) {
        return keccak256(bytes(p.desc));
    }

    /// @dev The timelock operation id the Governor will schedule for `p`. Mirrors
    ///      `GovernorTimelockControl._timelockSalt` (private there), which is
    ///      `bytes20(governor) ^ descriptionHash`.
    function _opId(Prop memory p) internal view returns (bytes32) {
        bytes32 salt = bytes20(address(governor)) ^ _descHash(p);
        return tl.hashOperationBatch(p.targets, p.values, p.calldatas, bytes32(0), salt);
    }

    function _propose(Prop memory p, address proposer) internal returns (uint256 id) {
        vm.prank(proposer);
        id = governor.propose(p.targets, p.values, p.calldatas, p.desc);
    }

    function _assertState(uint256 id, IGovernor.ProposalState expected, string memory what) internal view {
        assertEq(uint8(governor.state(id)), uint8(expected), what);
    }

    /// @dev propose -> delay -> vote For -> period -> queue -> timelock delay -> execute.
    ///      Only valid while the Config-default governance settings are in force.
    function _runToExecuted(Prop memory p, address proposer, address voter) internal returns (uint256 id) {
        id = _propose(p, proposer);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        vm.prank(voter);
        governor.castVote(id, 1);
        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        bytes32 dh = _descHash(p);
        governor.queue(p.targets, p.values, p.calldatas, dh);
        _warp(Config.TIMELOCK_MIN_DELAY);
        governor.execute(p.targets, p.values, p.calldatas, dh);
    }

    /// @dev The Governor's EIP-712 domain, asserted field by field. On this fork the chain-id
    ///      leg is mainnet's, so a ballot signed here is not replayable on another chain.
    function _assertGovernorEip712Domain() internal view {
        (, string memory n, string memory ver, uint256 cid, address vc,,) = governor.eip712Domain();
        assertEq(n, "Forest Road Governor");
        assertEq(ver, "1");
        assertEq(cid, 1, "the ballot is bound to mainnet's chain-id on this fork");
        assertEq(vc, address(governor), "and to this Governor specifically");
    }

    function _governorDomainSeparator() internal view returns (bytes32) {
        (, string memory n, string memory ver, uint256 cid, address vc,,) = governor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(n)),
                keccak256(bytes(ver)),
                cid,
                vc
            )
        );
    }

    /// @dev A real EIP-712 `Ballot` signature at the voter's CURRENT nonce.
    function _signBallot(uint256 pk, address voter, uint256 proposalId, uint8 support)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, governor.nonces(voter)));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _governorDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Move GROVE from the treasury into `who`'s STAKE, leaving their wallet empty, and
    ///      advance one second so the checkpoint is readable at any later timepoint.
    function _giveStakedGrove(address who, uint256 amount) internal {
        grove.transfer(who, amount); // ops == address(this) == the genesis treasury
        vm.startPrank(who);
        grove.approve(address(sGrove), amount);
        sGrove.stake(amount);
        vm.stopPrank();
        _warp(1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. WIRING: the Governor reads the aggregator, on the timestamp clock
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The Governor's vote source is the ADR-0026 aggregator (not GROVE directly), and
    ///         the whole stack is on the TIMESTAMP clock — proving `GovernorVotes.clock()`'s
    ///         silent try/catch fallback to BLOCK NUMBERS did not fire on this deploy. That
    ///         fallback is the failure mode that shows up only as every voter reading ~0.
    function test_govFork_governorTokenIsAggregatorOnTimestampClock() public onFork {
        assertEq(address(governor.token()), address(agg), "governor votes through the aggregator");
        assertEq(address(agg.grove()), address(grove), "aggregator leg 1 is GROVE");
        assertEq(address(agg.sGrove()), address(sGrove), "aggregator leg 2 is sGROVE");

        assertEq(governor.CLOCK_MODE(), "mode=timestamp", "no silent block-number fallback");
        assertEq(governor.clock(), uint48(block.timestamp), "governor clock IS the wall clock");
        assertEq(agg.CLOCK_MODE(), "mode=timestamp");
        assertEq(agg.clock(), uint48(block.timestamp));
        assertEq(grove.CLOCK_MODE(), "mode=timestamp");
        assertEq(grove.clock(), uint48(block.timestamp));
        assertEq(sGrove.CLOCK_MODE(), "mode=timestamp");
        assertEq(sGrove.clock(), uint48(block.timestamp));

        // launch parameters, as deployed
        assertEq(governor.votingDelay(), 1 days);
        assertEq(governor.votingPeriod(), 7 days);
        assertEq(governor.proposalThreshold(), 1_000_000e18);
        assertEq(governor.quorumNumerator(), 4);
        assertEq(governor.quorumDenominator(), 100);
        assertEq(governor.timelock(), address(tl));
        assertEq(tl.getMinDelay(), 2 days, "the 2-day timelock is live");
        assertEq(governor.name(), "Forest Road Governor");
    }

    /// @notice Delegation is per-source: the aggregator refuses to answer or route it rather
    ///         than returning one leg's answer as if it were the whole picture.
    function test_govFork_aggregatorRefusesToRouteDelegation() public onFork {
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        agg.delegates(ops);
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        agg.delegate(ops);
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        agg.delegateBySig(ops, 0, type(uint256).max, 27, bytes32(0), bytes32(0));

        assertEq(agg.groveDelegates(ops), ops, "the treasury self-delegated at seed");
        assertEq(agg.sGroveDelegates(ops), address(0), "nothing staked, so no sGROVE delegate");
    }

    /// @notice FORK-SPECIFIC. The aggregator's constructor guard, aimed at the single likeliest
    ///         deployer mistake, checked against REAL mainnet bytecode: pasting a token address
    ///         (USDC) or a wallet where a vote source belongs. Neither is an `IERC5805`, and
    ///         both must fail LOUDLY at construction rather than silently zeroing every voter.
    function test_govFork_aggregatorRejectsRealNonVoteSources() public onFork {
        // an EOA: `extcodesize` guard fires before the call
        vm.expectRevert(abi.encodeWithSelector(GroveVotesAggregator.Aggregator_NotAContract.selector, alice));
        new GroveVotesAggregator(alice, address(sGrove));

        // REAL USDC: has code, but no CLOCK_MODE() — the empty `actual` is the signature of
        // "this address is not a vote source at all"
        bytes memory expected =
            abi.encodeWithSelector(GroveVotesAggregator.Aggregator_ClockMismatch.selector, "mode=timestamp", "");
        vm.expectRevert(expected);
        new GroveVotesAggregator(USDC, address(sGrove));
        vm.expectRevert(expected);
        new GroveVotesAggregator(address(grove), USDC);
    }

    /// @notice The timelock topology the whole file rests on: the Governor is the only
    ///         PROPOSER/CANCELLER, execution is OPEN (address(0) holds EXECUTOR), the timelock
    ///         holds DEFAULT_ADMIN on the modules, and the deployer's bootstrap timelock admin
    ///         is gone.
    function test_govFork_timelockRoleTopologyAfterHandover() public onFork {
        bytes32 proposerRole = tl.PROPOSER_ROLE();
        bytes32 cancellerRole = tl.CANCELLER_ROLE();
        bytes32 executorRole = tl.EXECUTOR_ROLE();
        bytes32 tlAdmin = tl.DEFAULT_ADMIN_ROLE();

        assertTrue(tl.hasRole(proposerRole, address(governor)), "governor proposes");
        assertTrue(tl.hasRole(cancellerRole, address(governor)), "governor cancels");
        assertTrue(tl.hasRole(executorRole, address(0)), "execution is open (address(0))");
        assertFalse(tl.hasRole(proposerRole, ops), "the operator EOA cannot schedule");
        assertFalse(tl.hasRole(tlAdmin, ops), "deployer's bootstrap timelock admin was renounced");
        assertTrue(tl.hasRole(tlAdmin, address(tl)), "the timelock administers itself");

        assertTrue(queue.hasRole(bytes32(0), address(tl)), "timelock is admin of the queue");
        assertTrue(registry.hasRole(bytes32(0), address(tl)), "timelock is admin of the registry");
        assertTrue(waterfall.hasRole(bytes32(0), address(tl)), "timelock is admin of the waterfall");
        assertTrue(sGrove.hasRole(bytes32(0), address(tl)), "timelock is admin of the backstop");
        assertTrue(reserves.hasRole(Roles.RESERVE_ADMIN_ROLE, address(tl)), "R6 M-1: reserve admin is governance");
        assertTrue(queue.hasRole(Roles.UPGRADER_ROLE, address(tl)), "upgrades are the timelock's alone");
        assertFalse(queue.hasRole(Roles.UPGRADER_ROLE, ops), "no EOA may upgrade a module");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. THE FULL LIFECYCLE, LANDING A REAL PARAMETER CHANGE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice HEADLINE LIFECYCLE. propose -> votingDelay -> castVote -> votingPeriod -> queue
    ///         -> TIMELOCK_MIN_DELAY -> execute, landing TWO real parameter changes on TWO
    ///         deployed modules atomically. Every boundary is asserted at the exact second,
    ///         and `queue`/`execute` are called by `carol` — an address with zero votes and no
    ///         KYC — because both are permissionless once the vote has passed.
    function test_govFork_fullLifecycleLandsRealParameterChanges() public onFork {
        (, uint16 bpsBefore) = queue.epochParams();
        (uint16 borrowerBefore,,) = registry.limits();
        assertEq(bpsBefore, 167, "ADR-0022 launch default");
        assertEq(borrowerBefore, 10_000, "RAMP posture: wide open");

        Prop memory p = _prop2(
            address(queue),
            abi.encodeCall(queue.setEpochLiquidityBps, (uint16(5_000))),
            address(registry),
            abi.encodeCall(registry.setBorrowerLimit, (uint16(2_500))),
            "FR-1: raise the epoch liquidity share and re-tighten the borrower limit"
        );

        uint256 t0 = block.timestamp;
        uint256 id = _propose(p, ops);
        assertEq(governor.proposalProposer(id), ops);
        assertEq(governor.proposalSnapshot(id), t0 + 1 days, "snapshot = propose + GOV_VOTING_DELAY");
        assertEq(governor.proposalDeadline(id), t0 + 8 days, "deadline = snapshot + GOV_VOTING_PERIOD");
        assertEq(governor.proposalEta(id), 0, "not queued yet");
        assertTrue(governor.proposalNeedsQueuing(id), "every proposal goes through the timelock");
        _assertState(id, IGovernor.ProposalState.Pending, "pending immediately after propose");

        // exactly AT the snapshot it is still Pending; one second later it is Active
        _warp(1 days);
        _assertState(id, IGovernor.ProposalState.Pending, "still pending AT the snapshot second");
        _warp(1);
        _assertState(id, IGovernor.ProposalState.Active, "active one second past the snapshot");

        uint256 snapshot = governor.proposalSnapshot(id);
        assertEq(governor.getVotes(ops, snapshot), Config.GROVE_INITIAL_SUPPLY, "treasury holds the whole supply");
        assertEq(governor.quorum(snapshot), QUORUM, "4% of 1e27");

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(ops, id, 1, Config.GROVE_INITIAL_SUPPLY, "");
        governor.castVote(id, 1);

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(id);
        assertEq(forVotes, Config.GROVE_INITIAL_SUPPLY, "recorded For weight");
        assertEq(against, 0);
        assertEq(abstain, 0);
        assertTrue(governor.hasVoted(id, ops));

        // exactly AT the deadline it is still Active; one second later it has Succeeded
        _warp(7 days - 1); // now == proposalDeadline
        assertEq(block.timestamp, governor.proposalDeadline(id), "standing exactly on the deadline second");
        _assertState(id, IGovernor.ProposalState.Active, "still active AT the deadline second");
        _warp(1);
        _assertState(id, IGovernor.ProposalState.Succeeded, "succeeded one second past the deadline");

        // queueing is permissionless
        bytes32 dh = _descHash(p);
        bytes32 opId = _opId(p);
        uint256 queuedAt = block.timestamp;
        vm.prank(carol);
        governor.queue(p.targets, p.values, p.calldatas, dh);
        assertEq(governor.proposalEta(id), queuedAt + 2 days, "eta = queue + TIMELOCK_MIN_DELAY");
        assertEq(tl.getTimestamp(opId), queuedAt + 2 days, "the timelock scheduled exactly that operation");
        assertTrue(tl.isOperationPending(opId));
        assertFalse(tl.isOperationReady(opId), "not ready for two more days");
        _assertState(id, IGovernor.ProposalState.Queued, "queued in the timelock");
        // nothing has changed on-chain yet — the delay is the whole point
        (, uint16 bpsMid) = queue.epochParams();
        assertEq(bpsMid, 167, "the parameter is UNCHANGED while the operation waits");

        _warp(2 days); // now == eta, which the timelock treats as Ready
        assertTrue(tl.isOperationReady(opId), "ready exactly AT the eta");

        // execution is permissionless too
        vm.prank(carol);
        governor.execute(p.targets, p.values, p.calldatas, dh);

        _assertState(id, IGovernor.ProposalState.Executed, "executed");
        assertTrue(tl.isOperationDone(opId));
        {
            (uint64 durationAfter, uint16 bpsAfter) = queue.epochParams();
            (uint16 borrowerAfter, uint16 stateAfter,) = registry.limits();
            assertEq(bpsAfter, 5_000, "the queue parameter ACTUALLY changed on-chain");
            assertEq(borrowerAfter, 2_500, "and so did the registry limit, in the same atomic batch");
            assertEq(durationAfter, Config.DEFAULT_EPOCH_DURATION, "untouched dials are untouched");
            assertEq(stateAfter, 10_000, "untouched dials are untouched");
        }
        assertEq(block.timestamp, t0 + 10 days + 1, "the whole lifecycle is 1d delay + 7d vote + 2d timelock");
    }

    /// @notice ADR-0031 governance path on a pinned Ethereum fork. The real Governor and
    ///         two-day Timelock atomically exempt a replacement recipient, enable management
    ///         fees, vary performance fees, and redirect future fee shares. A later proposal
    ///         retunes management prospectively. Finally, governance installs a readable
    ///         impairment source and clears it only after it fails, proving the liveness
    ///         recovery is also reachable through the production authority path.
    function test_govFork_feeStackSettersExecuteThroughGovernorAndTimelock() public onFork {
        _mintFromUSDC(alice, 1_000e6);
        uint256 aliceShares = _stake(alice, 1_000e18);
        address replacement = makeAddr("forkGovernedFeeRecipient");

        // The emergency path probes with a fixed 200k gas budget. Prove that budget is
        // sufficient for the source wired by the production deployment itself; otherwise a
        // healthy production source could be falsely classified as unreadable and cleared.
        address productionSource = vault.impairmentSource();
        assertNotEq(productionSource, address(0), "production deploy wires an impairment source");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector, productionSource));
        vault.clearUnreadableImpairmentSource();
        assertEq(vault.impairmentSource(), productionSource, "a healthy production source cannot be cleared");

        Prop memory enable = _prop4(
            address(compliance),
            abi.encodeCall(compliance.setProtocolExempt, (replacement, true)),
            address(vault),
            abi.encodeCall(vault.setManagementFee, (uint16(100))),
            address(vault),
            abi.encodeCall(vault.setPerformanceFee, (uint16(1_500))),
            address(vault),
            abi.encodeCall(vault.setFeeRecipient, (replacement)),
            "FR-fees-1: enable management, retune performance, and rotate the fee recipient"
        );
        _runToExecuted(enable, ops, ops);

        assertTrue(compliance.isProtocolExempt(replacement));
        assertEq(vault.managementFeeBps(), 100);
        assertEq(vault.performanceFeeBps(), 1_500);
        assertEq(vault.feeRecipient(), replacement);

        _warp(365 days);
        uint256 replacementSharesBefore = vault.balanceOf(replacement);
        (uint256 managementShares, uint256 performanceShares) = vault.accrueFees();
        assertGt(managementShares, 0, "enabled management fee crystallizes on the fork");
        assertEq(performanceShares, 0, "principal alone is not performance");
        assertEq(vault.balanceOf(replacement) - replacementSharesBefore, managementShares);
        assertApproxEqAbs(
            vault.convertToAssets(aliceShares), 990e18, 1e9, "one prospective year at 1% leaves the investor with 99%"
        );

        Prop memory retune = _prop1(
            address(vault),
            abi.encodeCall(vault.setManagementFee, (uint16(50))),
            "FR-fees-2: retune the prospective annual management fee"
        );
        _runToExecuted(retune, ops, ops);
        assertEq(vault.managementFeeBps(), 50, "second timelocked proposal varies the rate prospectively");

        ForkToggleImpairment source = new ForkToggleImpairment();
        Prop memory installSource = _prop1(
            address(vault),
            abi.encodeCall(vault.setImpairmentSource, (address(source))),
            "FR-fees-3: install a validated impairment source"
        );
        _runToExecuted(installSource, ops, ops);
        assertEq(vault.impairmentSource(), address(source));

        source.setUnavailable(true);
        vm.expectRevert("fork impairment unavailable");
        vault.accrueFees();

        Prop memory recoverSource = _prop1(
            address(vault),
            abi.encodeCall(vault.clearUnreadableImpairmentSource, ()),
            "FR-fees-4: clear the failed impairment source"
        );
        _runToExecuted(recoverSource, ops, ops);
        assertEq(vault.impairmentSource(), address(0), "timelocked recovery restores a usable marked NAV");
        vault.accrueFees();
    }

    /// @notice The parameter change is not cosmetic: FORK-SPECIFIC end-to-end proof that a
    ///         governance-set dial governs REAL money. 1,000,000 USDC of stable liquidity sits
    ///         in the treasury; governance raises the per-heartbeat share from 167bps to
    ///         5000bps; the very next settlement fills a queued redemption for 500,000 USDfr
    ///         instead of the 16,700 the old dial allowed. Also the first time the 21-day
    ///         ADR-0022 cooldown and a 2-day timelock have been waited out in the same run.
    function test_govFork_parameterChangeGovernsARealUSDCSettlement() public onFork {
        // 999,990 USDC of real mainnet USDC + the locked 10 USDC seed == 1,000,000e18 idle
        _mintFromUSDC(alice, 999_990e6);
        uint256 shares = _stake(alice, 999_000e18);
        assertEq(reserves.idleReserve(), 1_000_000e18, "stable liquidity, 18-dec normalized");
        assertEq(queue.availableLiquidity(), 16_700e18, "167bps of 1,000,000e18");

        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 requestId = queue.requestRedeem(shares);
        vm.stopPrank();
        assertEq(requestId, 0);
        uint256 requestedAt = block.timestamp;

        // the governance lifecycle, spelled out here so the module's own event can be asserted
        // on the EXECUTE call specifically (it is the timelock, not the voter, that emits it)
        Prop memory p = _bpsProp(5_000, "FR-2: widen the settlement throughput cap");
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        governor.castVote(id, 1);
        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        bytes32 dh = _descHash(p);
        governor.queue(p.targets, p.values, p.calldatas, dh);
        _warp(Config.TIMELOCK_MIN_DELAY);
        vm.expectEmit(false, false, false, true, address(queue));
        emit IRedemptionQueue.EpochLiquidityBpsSet(5_000);
        governor.execute(p.targets, p.values, p.calldatas, dh);

        (, uint16 bpsAfter) = queue.epochParams();
        assertEq(bpsAfter, 5_000);
        assertEq(queue.availableLiquidity(), 500_000e18, "5000bps of the SAME 1,000,000e18");

        // the ADR-0022 forced hold still binds: 10 days into the governance process the
        // request is nowhere near settleable, and closeEpoch says so by NAME
        assertEq(queue.eligibleToSettleAt(requestId), requestedAt + 21 days);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, requestedAt + 21 days));
        queue.closeEpoch(10);

        _warp(11 days + 1); // past the 21-day cooldown
        queue.closeEpoch(10);

        (, uint256 sharesRemaining, uint256 assetsClaimable,,) = queue.request(requestId);
        assertLe(assetsClaimable, 500_000e18, "the budget is a hard ceiling, never overshot");
        assertGe(assetsClaimable, 500_000e18 - 2, "and it filled the budget to within rounding dust");
        assertGt(assetsClaimable, 16_700e18 * 29, "far beyond anything the OLD 167bps dial could fill");
        assertGt(sharesRemaining, 0, "budget-bound partial fill, as intended");

        uint256 balBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = queue.claim(requestId);
        assertEq(claimed, assetsClaimable, "claimed exactly what was filled");
        assertEq(usdfr.balanceOf(alice) - balBefore, assetsClaimable, "USDfr actually delivered");
        assertTrue(controller.backingInvariantHolds(), "backing invariant survives the whole path");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. L-02: staked GROVE is a first-class governance citizen
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE L-02 HEADLINE, on the fork. An actor whose ONLY voting power is STAKED
    ///         GROVE — zero left in the wallet — proposes AND votes, at a weight exactly equal
    ///         to their stake, and carries a real parameter change to `Executed` without the
    ///         treasury casting a single vote. Pre-L-02 this address had zero governance power.
    function test_govFork_stakedOnlyActorProposesVotesAndExecutes() public onFork {
        uint256 stakeAmount = 50_000_000e18; // > 40M quorum, > 1M threshold
        _giveStakedGrove(staker, stakeAmount);

        assertEq(grove.balanceOf(staker), 0, "wallet GROVE fully staked");
        assertEq(grove.getVotes(staker), 0, "the GROVE leg contributes nothing");
        assertEq(sGrove.stakedOf(staker), stakeAmount);
        assertEq(sGrove.getVotes(staker), stakeAmount, "stake() self-delegated");
        assertEq(agg.getVotes(staker), stakeAmount, "aggregate == the stake, counted exactly ONCE");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "voting units track active stake");

        Prop memory p = _bpsProp(1_200, "FR-3: stakers alone widen the settlement cap");
        uint256 id = _propose(p, staker); // proposal threshold met from stake alone
        assertEq(governor.proposalProposer(id), staker, "a staked-only actor IS the proposer");

        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        uint256 snapshot = governor.proposalSnapshot(id);
        assertEq(governor.getVotes(staker, snapshot), stakeAmount, "the Governor sees the staked weight");
        assertEq(governor.quorum(snapshot), QUORUM);
        assertGt(stakeAmount, QUORUM, "stake alone clears quorum");

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(staker, id, 1, stakeAmount, "");
        vm.prank(staker);
        governor.castVote(id, 1);

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(id);
        assertEq(forVotes, stakeAmount, "recorded For weight IS the stake, to the wei");
        assertEq(against, 0);
        assertEq(abstain, 0);

        // the treasury shed exactly what the staker staked: no weight created, none lost
        assertEq(
            grove.getPastVotes(ops, snapshot),
            Config.GROVE_INITIAL_SUPPLY - stakeAmount,
            "aggregate voting power is conserved across staking"
        );
        assertEq(
            agg.getPastVotes(ops, snapshot) + agg.getPastVotes(staker, snapshot),
            Config.GROVE_INITIAL_SUPPLY,
            "no double count anywhere in the system"
        );

        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        _assertState(id, IGovernor.ProposalState.Succeeded, "carried by staked GROVE alone");
        bytes32 dh = _descHash(p);
        governor.queue(p.targets, p.values, p.calldatas, dh);
        _warp(Config.TIMELOCK_MIN_DELAY);
        governor.execute(p.targets, p.values, p.calldatas, dh);

        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 1_200, "staked GROVE landed a real parameter change through the timelock");
    }

    /// @notice Staking must not move the quorum bar. Summing the two supplies would raise it —
    ///         and would let a whale stake immediately before a snapshot purely to block a
    ///         proposal it opposed, then unbond. The counterfactual bar is computed from the
    ///         same on-chain supplies so the exploit is priced, not merely asserted away.
    function test_govFork_quorumIsUnmovedByStaking() public onFork {
        uint256 tBefore = block.timestamp - 1;
        assertEq(sGrove.totalStaked(), 0, "nothing staked yet");
        assertEq(governor.quorum(tBefore), QUORUM, "4% of the fixed GROVE supply");

        _giveStakedGrove(staker, 200_000_000e18); // 20% of supply staked
        _warp(1);

        uint256 tAfter = block.timestamp - 1;
        assertEq(governor.quorum(tAfter), QUORUM, "staking moved the bar by exactly nothing");
        assertEq(agg.getPastTotalSupply(tAfter), grove.getPastTotalSupply(tAfter), "GROVE-only denominator");
        assertEq(grove.getPastTotalSupply(tAfter), Config.GROVE_INITIAL_SUPPLY, "fixed supply: no mint/burn path");
        assertEq(sGrove.getPastTotalSupply(tAfter), 200_000_000e18, "staked units are real units");

        // the failure this design prevents, made explicit
        uint256 summed = grove.getPastTotalSupply(tAfter) + sGrove.getPastTotalSupply(tAfter);
        uint256 inflated = summed * Config.GOV_QUORUM_FRACTION / governor.quorumDenominator();
        assertEq(inflated, 48_000_000e18, "a summed denominator would be 4% of 1.2e9");
        assertGt(inflated, QUORUM, "i.e. it would have STRICTLY raised the bar for everyone");
    }

    /// @notice A proposal that fails quorum ends Defeated, and nothing lands. 39M of staked
    ///         power clears the 1M proposal threshold but falls short of the 40M quorum.
    function test_govFork_proposalFailingQuorumIsDefeated() public onFork {
        uint256 belowQuorum = 39_000_000e18;
        _giveStakedGrove(staker, belowQuorum);

        Prop memory p = _bpsProp(9_000, "FR-4: 39M is not enough");
        uint256 id = _propose(p, staker);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);

        uint256 snapshot = governor.proposalSnapshot(id);
        assertEq(governor.quorum(snapshot), QUORUM, "the bar it will fail against");
        vm.prank(staker);
        governor.castVote(id, 1);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, belowQuorum, "every available vote was cast For");
        assertLt(forVotes, QUORUM, "and it still falls short");

        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        _assertState(id, IGovernor.ProposalState.Defeated, "quorum not reached");

        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 167, "no parameter change landed");

        // and a Defeated proposal cannot be forced through the timelock
        bytes32 dh = _descHash(p);
        bytes32 expectedStates = bytes32(uint256(1) << uint8(IGovernor.ProposalState.Succeeded));
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector, id, IGovernor.ProposalState.Defeated, expectedStates
            )
        );
        governor.queue(p.targets, p.values, p.calldatas, dh);
    }

    /// @notice A proposal that reaches quorum but is voted DOWN also ends Defeated — the
    ///         "against" arm, which the quorum-failure test above cannot distinguish.
    function test_govFork_proposalVotedDownIsDefeated() public onFork {
        _giveStakedGrove(staker, 50_000_000e18);

        Prop memory p = _bpsProp(9_000, "FR-5: the treasury votes this down");
        uint256 id = _propose(p, staker);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);

        vm.prank(staker);
        governor.castVote(id, 1); // 50M For
        governor.castVote(id, 0); // 950M Against (the treasury)

        (uint256 against, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 50_000_000e18);
        assertEq(against, Config.GROVE_INITIAL_SUPPLY - 50_000_000e18, "950M against");
        assertGt(forVotes + against, QUORUM, "quorum IS reached; the vote simply lost");

        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        _assertState(id, IGovernor.ProposalState.Defeated, "against > for");
        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 167, "nothing landed");
    }

    /// @notice Unbonding stake stops voting the instant `requestUnstake` is called — and the
    ///         21-day unbond is waited out here, so `claimUnstake` is proven vote-neutral too.
    function test_govFork_unbondingStakeHasNoVotingPower() public onFork {
        uint256 stakeAmount = 50_000_000e18;
        _giveStakedGrove(staker, stakeAmount);
        assertEq(agg.getVotes(staker), stakeAmount, "weight exists before the exit request");

        vm.prank(staker);
        uint256 unbondId = sGrove.requestUnstake(stakeAmount);
        assertEq(sGrove.getVotes(staker), 0, "units burned at requestUnstake, not at claim");
        assertEq(sGrove.totalVotingUnits(), 0);
        assertEq(grove.balanceOf(address(sGrove)), stakeAmount, "the GROVE is still custodied, just not voting");
        _warp(1);

        Prop memory p = _bpsProp(1_100, "FR-6: an unbonder tries to vote");
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        uint256 snapshot = governor.proposalSnapshot(id);
        assertEq(governor.getVotes(staker, snapshot), 0, "zero weight at the snapshot");

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(staker, id, 1, 0, "");
        vm.prank(staker);
        governor.castVote(id, 1);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 0, "an unbonding position contributes nothing");

        _warp(Config.SGROVE_UNBONDING_PERIOD + 1);
        vm.prank(staker);
        sGrove.claimUnstake(unbondId);
        assertEq(sGrove.getVotes(staker), 0, "claimUnstake is vote-neutral");
        assertEq(grove.balanceOf(staker), stakeAmount, "made whole in GROVE");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. NEGATIVE PATHS — the timelock and the roles must actually bite
    // ─────────────────────────────────────────────────────────────────────

    /// @notice EXECUTION BEFORE THE TIMELOCK DELAY REVERTS — at the exact second. One second
    ///         before the eta the timelock refuses by name; one second later (== eta) the same
    ///         call lands the change. This is the 2-day gate no live QA run has ever waited.
    function test_govFork_executeBeforeTimelockDelayReverts() public onFork {
        Prop memory p = _bpsProp(2_000, "FR-7: the delay must bite");
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        governor.castVote(id, 1);
        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);

        bytes32 dh = _descHash(p);
        bytes32 opId = _opId(p);
        uint256 queuedAt = block.timestamp;
        governor.queue(p.targets, p.values, p.calldatas, dh);
        uint256 eta = queuedAt + Config.TIMELOCK_MIN_DELAY;
        assertEq(governor.proposalEta(id), eta);

        // t = eta - 1: one second short
        _warp(Config.TIMELOCK_MIN_DELAY - 1);
        assertEq(block.timestamp, eta - 1);
        assertFalse(tl.isOperationReady(opId));
        _assertState(id, IGovernor.ProposalState.Queued, "still Queued, not Expired or anything else");
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector, opId, READY_BITMAP
            )
        );
        governor.execute(p.targets, p.values, p.calldatas, dh);
        (, uint16 bpsStillOld) = queue.epochParams();
        assertEq(bpsStillOld, 167, "nothing changed on the failed execution");

        // t = eta: ready to the second
        _warp(1);
        assertEq(block.timestamp, eta);
        governor.execute(p.targets, p.values, p.calldatas, dh);
        (, uint16 bpsNew) = queue.epochParams();
        assertEq(bpsNew, 2_000, "the same call lands one second later");
    }

    /// @notice A Succeeded proposal cannot skip the timelock: calling `execute` without ever
    ///         queueing hits an UNSET timelock operation and reverts with the same named error.
    function test_govFork_executeWithoutQueueingReverts() public onFork {
        Prop memory p = _bpsProp(3_000, "FR-8: no skipping the queue step");
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        governor.castVote(id, 1);
        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        _assertState(id, IGovernor.ProposalState.Succeeded, "passed, but not queued");

        bytes32 dh = _descHash(p);
        bytes32 opId = _opId(p);
        assertEq(tl.getTimestamp(opId), 0, "the operation was never scheduled");
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector, opId, READY_BITMAP
            )
        );
        governor.execute(p.targets, p.values, p.calldatas, dh);

        // and the ordinary path still works afterwards
        governor.queue(p.targets, p.values, p.calldatas, dh);
        _warp(Config.TIMELOCK_MIN_DELAY);
        governor.execute(p.targets, p.values, p.calldatas, dh);
        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 3_000);
    }

    /// @notice Queueing before the vote closes, double voting, and double execution all revert
    ///         with the exact Governor errors — the ordinary sequencing guarantees.
    function test_govFork_sequencingGuardsRevertExactly() public onFork {
        Prop memory p = _bpsProp(4_000, "FR-9: sequencing");
        uint256 id = _propose(p, ops);
        bytes32 dh = _descHash(p);

        // queue while Pending
        bytes32 succeededBitmap = bytes32(uint256(1) << uint8(IGovernor.ProposalState.Succeeded));
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector, id, IGovernor.ProposalState.Pending, succeededBitmap
            )
        );
        governor.queue(p.targets, p.values, p.calldatas, dh);

        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);

        // queue while Active
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector, id, IGovernor.ProposalState.Active, succeededBitmap
            )
        );
        governor.queue(p.targets, p.values, p.calldatas, dh);

        governor.castVote(id, 1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorAlreadyCastVote.selector, ops));
        governor.castVote(id, 1);

        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        governor.queue(p.targets, p.values, p.calldatas, dh);

        // double queue
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector, id, IGovernor.ProposalState.Queued, succeededBitmap
            )
        );
        governor.queue(p.targets, p.values, p.calldatas, dh);

        _warp(Config.TIMELOCK_MIN_DELAY);
        governor.execute(p.targets, p.values, p.calldatas, dh);

        // double execute
        bytes32 execBitmap = bytes32(
            (uint256(1) << uint8(IGovernor.ProposalState.Succeeded))
                | (uint256(1) << uint8(IGovernor.ProposalState.Queued))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector, id, IGovernor.ProposalState.Executed, execBitmap
            )
        );
        governor.execute(p.targets, p.values, p.calldatas, dh);

        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 4_000, "the parameter landed exactly once");
    }

    /// @notice A proposer may cancel while Pending; nobody else may, and a cancelled proposal
    ///         can never be queued or executed.
    function test_govFork_cancelWhilePending() public onFork {
        Prop memory p = _bpsProp(6_000, "FR-10: cancelled before it ever votes");
        uint256 id = _propose(p, ops);
        bytes32 dh = _descHash(p);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, carol));
        vm.prank(carol);
        governor.cancel(p.targets, p.values, p.calldatas, dh);

        governor.cancel(p.targets, p.values, p.calldatas, dh);
        _assertState(id, IGovernor.ProposalState.Canceled, "the proposer withdrew it");

        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        bytes32 succeededBitmap = bytes32(uint256(1) << uint8(IGovernor.ProposalState.Succeeded));
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                id,
                IGovernor.ProposalState.Canceled,
                succeededBitmap
            )
        );
        governor.queue(p.targets, p.values, p.calldatas, dh);
        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 167, "nothing landed");
    }

    /// @notice An address with no voting power cannot propose, and the Governor says by how
    ///         much it fell short.
    function test_govFork_belowThresholdCannotPropose() public onFork {
        Prop memory p = _bpsProp(7_000, "FR-11: underpowered");
        assertEq(governor.getVotes(carol, governor.clock() - 1), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, carol, 0, Config.GOV_PROPOSAL_THRESHOLD
            )
        );
        vm.prank(carol);
        governor.propose(p.targets, p.values, p.calldatas, p.desc);

        // and one wei of staked power short of the threshold is still short
        _giveStakedGrove(staker, Config.GOV_PROPOSAL_THRESHOLD - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector,
                staker,
                Config.GOV_PROPOSAL_THRESHOLD - 1,
                Config.GOV_PROPOSAL_THRESHOLD
            )
        );
        vm.prank(staker);
        governor.propose(p.targets, p.values, p.calldatas, p.desc);
    }

    /// @notice Governance is the ONLY route to these dials. A non-admin calling the module
    ///         setter directly, and a non-proposer scheduling on the timelock directly, both
    ///         revert with the exact AccessControl error.
    function test_govFork_privilegedPathsAreClosedToEveryoneElse() public onFork {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        queue.setEpochLiquidityBps(5_000);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        registry.setBorrowerLimit(2_500);

        // scheduling on the timelock is PROPOSER-gated (only the Governor holds it)
        Prop memory p = _bpsProp(5_000, "FR-12: schedule it myself");
        bytes32 proposerRole = tl.PROPOSER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, proposerRole)
        );
        vm.prank(carol);
        tl.scheduleBatch(p.targets, p.values, p.calldatas, bytes32(0), bytes32(0), 2 days);

        // and the timelock's own delay cannot be changed from outside itself
        vm.expectRevert(abi.encodeWithSelector(TimelockControllerUpgradeable.TimelockUnauthorizedCaller.selector, ops));
        tl.updateDelay(1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. GOVERNANCE OVER GOVERNANCE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Governance can re-tune ITSELF: one atomic proposal changes the Governor's voting
    ///         period and the timelock's minimum delay, and the NEXT proposal demonstrably runs
    ///         on the new numbers. Both setters are unreachable from an EOA beforehand.
    function test_govFork_governanceRetunesItsOwnSettingsAndTimelockDelay() public onFork {
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, ops));
        governor.setVotingPeriod(uint32(14 days));

        Prop memory p = _prop2(
            address(governor),
            abi.encodeCall(governor.setVotingPeriod, (uint32(14 days))),
            address(tl),
            abi.encodeCall(tl.updateDelay, (3 days)),
            "FR-13: slow governance down"
        );
        _runToExecuted(p, ops, ops);

        assertEq(governor.votingPeriod(), 14 days, "the Governor re-tuned itself");
        assertEq(tl.getMinDelay(), 3 days, "and the timelock re-tuned its own delay");
        assertEq(governor.votingDelay(), 1 days, "untouched settings are untouched");

        // the new numbers actually govern the next proposal
        Prop memory p2 = _bpsProp(8_000, "FR-14: run on the new settings");
        uint256 t0 = block.timestamp;
        uint256 id2 = _propose(p2, ops);
        assertEq(governor.proposalSnapshot(id2), t0 + 1 days);
        assertEq(governor.proposalDeadline(id2), t0 + 1 days + 14 days, "the NEW 14-day voting period applies");

        _warp(1 days + 1);
        governor.castVote(id2, 1);
        _warp(7 days);
        _assertState(id2, IGovernor.ProposalState.Active, "still voting where the old period would have closed");
        _warp(7 days + 1);
        _assertState(id2, IGovernor.ProposalState.Succeeded, "succeeded at the new deadline");

        bytes32 dh2 = _descHash(p2);
        uint256 queuedAt = block.timestamp;
        governor.queue(p2.targets, p2.values, p2.calldatas, dh2);
        assertEq(governor.proposalEta(id2), queuedAt + 3 days, "the NEW 3-day timelock delay applies");

        _warp(2 days);
        bytes32 opId2 = _opId(p2);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector, opId2, READY_BITMAP
            )
        );
        governor.execute(p2.targets, p2.values, p2.calldatas, dh2);

        _warp(1 days);
        governor.execute(p2.targets, p2.values, p2.calldatas, dh2);
        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 8_000);
    }

    /// @notice CLAUDE.md §2.2 negative QA: "upgrade without the timelock" must fail. No EOA can
    ///         upgrade a module or the Governor itself; a governance proposal can, and the
    ///         proxy's state survives the swap.
    function test_govFork_upgradesOnlyThroughGovernance() public onFork {
        address newImpl = address(new RedemptionQueue());
        bytes32 implBefore = vm.load(address(queue), IMPL_SLOT);
        assertTrue(address(uint160(uint256(implBefore))) != newImpl, "a genuinely different implementation");

        // the operator EOA cannot upgrade the module...
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, Roles.UPGRADER_ROLE)
        );
        queue.upgradeToAndCall(newImpl, "");

        // ...nor the Governor, whose _authorizeUpgrade is onlyGovernance
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, ops));
        governor.upgradeToAndCall(newImpl, "");

        Prop memory p =
            _prop1(address(queue), abi.encodeCall(queue.upgradeToAndCall, (newImpl, "")), "FR-15: upgrade the queue");
        _runToExecuted(p, ops, ops);

        assertEq(
            address(uint160(uint256(vm.load(address(queue), IMPL_SLOT)))),
            newImpl,
            "the proxy points at the new implementation"
        );
        (uint64 duration, uint16 bps) = queue.epochParams();
        assertEq(bps, 167, "proxy state survived the upgrade");
        assertEq(duration, Config.DEFAULT_EPOCH_DURATION);
        assertEq(queue.currentEpoch(), 1);
        assertTrue(queue.hasRole(bytes32(0), address(tl)), "roles survived the upgrade");
    }

    /// @notice A GASLESS (EIP-712) ballot relayed by a third party, cast by a staked-only
    ///         voter. The signed digest binds to the mainnet fork's chain-id and to this
    ///         Governor, and the nonce makes it single-use — a replay is rejected by name.
    function test_govFork_castVoteBySigFromAStakedOnlyVoter() public onFork {
        (address sigVoter, uint256 sigPk) = makeAddrAndKey("forkSigVoter");
        uint256 stakeAmount = 50_000_000e18;
        _giveStakedGrove(sigVoter, stakeAmount);

        Prop memory p = _bpsProp(1_300, "FR-17: a signed ballot");
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);

        _assertGovernorEip712Domain();
        assertEq(governor.nonces(sigVoter), 0, "first ballot from this voter");
        bytes memory sig = _signBallot(sigPk, sigVoter, id, 1);

        // relayed by an address with no votes and no KYC
        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(sigVoter, id, 1, stakeAmount, "");
        vm.prank(carol);
        governor.castVoteBySig(id, 1, sigVoter, sig);

        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, stakeAmount, "the signed ballot carried the FULL staked weight");
        assertEq(governor.nonces(sigVoter), 1, "the nonce was consumed");

        // the same signature cannot be replayed
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, sigVoter));
        vm.prank(carol);
        governor.castVoteBySig(id, 1, sigVoter, sig);
    }

    /// @notice The Governor's own privileged surface: `relay` (which would let governance move
    ///         anything the Governor holds) is reachable only through the timelock, and the
    ///         Governor refuses plain ETH deposits.
    function test_govFork_governorRelayAndDepositGuards() public onFork {
        bytes memory transferCall = abi.encodeCall(grove.transfer, (ops, 1e18));
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, ops));
        governor.relay(address(grove), 0, transferCall);

        vm.deal(ops, 1 ether);
        (bool ok, bytes memory ret) = address(governor).call{value: 1 ether}("");
        assertFalse(ok, "the Governor is not a wallet");
        assertEq(bytes4(ret), IGovernor.GovernorDisabledDeposit.selector, "and says so by name");
        assertEq(address(governor).balance, 0);
    }

    /// @notice G1c regression. This test previously asserted that an unstoppable queued
    ///         operation was safe; it is not. The approved proposal guardian now reaches the
    ///         Governor's Timelock cancellation role without holding that role directly.
    function test_govFork_proposalGuardianCanCancelQueuedOperation() public onFork {
        Prop memory p = _bpsProp(9_500, "G1c: guardian can stop this once queued");
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        governor.castVote(id, 1);
        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        bytes32 dh = _descHash(p);
        bytes32 opId = _opId(p);
        governor.queue(p.targets, p.values, p.calldatas, dh);
        _assertState(id, IGovernor.ProposalState.Queued, "queued and waiting out the delay");

        bytes32 cancellerRole = tl.CANCELLER_ROLE();
        assertTrue(tl.hasRole(cancellerRole, address(governor)), "only the Governor holds CANCELLER");
        assertFalse(tl.hasRole(cancellerRole, ops), "not the operator EOA");
        assertFalse(tl.hasRole(cancellerRole, alice));
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), ops), "and no EOA can grant itself CANCELLER");
        address vetoPrincipal = governor.proposalGuardian();
        assertTrue(vetoPrincipal != address(0), "deployment must bind an approved veto principal");
        assertTrue(vetoPrincipal != ops, "M-5/M-6: the veto principal must be separate from ops");

        // the operator cannot cancel the timelock operation
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, cancellerRole)
        );
        tl.cancel(opId);

        // An unrelated account cannot route the Governor's Timelock role.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, alice));
        governor.cancel(p.targets, p.values, p.calldatas, dh);

        // The approved guardian can, and cancellation consumes both Governor and Timelock state.
        vm.prank(vetoPrincipal);
        governor.cancel(p.targets, p.values, p.calldatas, dh);
        _assertState(id, IGovernor.ProposalState.Canceled, "guardian veto recorded by Governor");
        assertFalse(tl.isOperation(opId), "queued Timelock operation was disarmed");

        _warp(Config.TIMELOCK_MIN_DELAY);
        vm.expectRevert();
        governor.execute(p.targets, p.values, p.calldatas, dh);
        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 167, "the vetoed change must never land");
    }

    /// @notice A proposal whose action REVERTS takes nothing with it: the batch is atomic, the
    ///         timelock operation stays undone, and the proposal is not marked Executed.
    ///         `setEpochLiquidityBps(0)` is rejected by the module's own parameter guard.
    function test_govFork_revertingActionRollsTheWholeBatchBack() public onFork {
        Prop memory p = _prop2(
            address(queue),
            abi.encodeCall(queue.setEpochLiquidityBps, (uint16(5_000))),
            address(queue),
            abi.encodeCall(queue.setEpochLiquidityBps, (uint16(0))), // Queue_BadParams
            "FR-16: a bad second action"
        );
        uint256 id = _propose(p, ops);
        _warp(uint256(Config.GOV_VOTING_DELAY) + 1);
        governor.castVote(id, 1);
        _warp(uint256(Config.GOV_VOTING_PERIOD) + 1);
        bytes32 dh = _descHash(p);
        bytes32 opId = _opId(p);
        governor.queue(p.targets, p.values, p.calldatas, dh);
        _warp(Config.TIMELOCK_MIN_DELAY);

        vm.expectRevert(IRedemptionQueue.Queue_BadParams.selector);
        governor.execute(p.targets, p.values, p.calldatas, dh);

        (, uint16 bps) = queue.epochParams();
        assertEq(bps, 167, "the FIRST action was rolled back with the second");
        assertFalse(tl.isOperationDone(opId), "the timelock operation is still pending, not consumed");
        _assertState(id, IGovernor.ProposalState.Queued, "and the proposal is not Executed");
    }
}
