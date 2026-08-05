// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {GroveVotesAggregator} from "../../src/GroveVotesAggregator.sol";
import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @dev A vote source that checkpoints in BLOCK NUMBERS — the exact mistake the
///      aggregator's constructor guard exists to catch. Only `CLOCK_MODE()` is reachable
///      before the guard fires, so nothing else needs implementing.
contract MockBlockNumberClockVotes {
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }
}

/// @dev A vote source that DECLARES the timestamp clock but actually checkpoints in
///      BLOCK NUMBERS — the half-truth a `CLOCK_MODE()`-string-only guard waves straight
///      through into the silent failure it exists to prevent. The aggregator compares the
///      live `clock()` value as well, so this source is rejected at construction too.
contract MockLyingClockVotes {
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function clock() external view returns (uint48) {
        return uint48(block.number);
    }
}

/// @dev ADR-0026 (L-02) end-to-end: staked GROVE actually votes, through the REAL
///      `FRGovernor` + `TimelockController`, with the `GroveVotesAggregator` as the
///      Governor's single vote source. Every test here pins one of the design
///      properties L-02 exists to guarantee:
///        - staked GROVE keeps exactly its weight, and only once (no double count);
///        - the quorum denominator is GROVE total supply ONLY, so staking cannot move
///          the bar (the block-a-proposal-by-staking exploit);
///        - the Governor is on the TIMESTAMP clock (the silent block-number fallback in
///          `GovernorVotes.clock()`'s try/catch did not fire);
///        - unbonding stake does not vote;
///        - a plain GROVE holder who never stakes is completely unaffected.
contract GovernanceVotesFlowTest is GovernanceFixture {
    /// @dev Comfortably over the 4% quorum (40M) and the 1M proposal threshold.
    uint256 internal constant BIG_STAKE = 50_000_000e18;

    address internal stakedOnlyVoter = makeAddr("stakedOnlyVoter");
    address internal plainHolder = makeAddr("plainGroveHolder");

    // ── helpers (proposal flow mirrors GovernanceFlow/Governance.t.sol) ───

    /// @dev Builds the canonical protocol-parameter proposal used throughout: a
    ///      `WaterfallEngine.setProtocolFee` change, executed by the timelock.
    function _feeProposal(uint16 newFeeBps)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(waterfall);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (newFeeBps));
    }

    /// @dev propose -> warp past votingDelay. Returns the id once voting is Active.
    function _proposeAndOpen(address proposer, uint16 newFeeBps, string memory description)
        internal
        returns (uint256 proposalId)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _feeProposal(newFeeBps);
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending), "pending before delay");
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active), "active after delay");
    }

    /// @dev warp past votingPeriod -> queue -> warp past timelock delay -> execute.
    function _closeQueueExecute(uint256 proposalId, uint16 newFeeBps, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _feeProposal(newFeeBps);
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded), "succeeded on votes");

        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued), "queued in the timelock");

        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed), "executed");
    }

    /// @dev The structural invariants that must hold at every point in every test.
    ///      `expectedSummed` is the EXACT aggregate voting power the test's distribution
    ///      implies — every actor who ever holds or stakes GROVE in this file is in the
    ///      sum, so the equality is total, not a bound. The `assertLe` leg alone would not
    ///      bite: ~50M of stake against a 1e27 fixed supply leaves ~20x of headroom, so a
    ///      2x, 4x or 10x double count would sail through it. The equality is the check;
    ///      the bound is kept only as the genuine "never exceeds supply" statement.
    function _assertVotingUnitsConsistent(uint256 timepoint, uint256 expectedSummed) internal view {
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "sGROVE voting units track active stake exactly");
        uint256 summed = votesAggregator.getPastVotes(frTreasury, timepoint)
            + votesAggregator.getPastVotes(stakedOnlyVoter, timepoint)
            + votesAggregator.getPastVotes(plainHolder, timepoint) + votesAggregator.getPastVotes(secondCurator, timepoint)
            + votesAggregator.getPastVotes(alice, timepoint);
        assertEq(summed, expectedSummed, "aggregate voting power is EXACTLY the delegated + staked total");
        assertLe(summed, grove.getPastTotalSupply(timepoint), "aggregate votes never exceed GROVE supply");
    }

    // ── wiring: the Governor reads the aggregator, on the timestamp clock ─

    /// @notice The Governor's vote source is the aggregator, not GROVE directly —
    ///         without this, staked GROVE is silently disenfranchised.
    function test_votes_governorTokenIsTheAggregator() public view {
        assertEq(address(governor.token()), address(votesAggregator), "governor votes through the aggregator");
        assertEq(address(votesAggregator.grove()), address(grove), "aggregator leg 1 is GROVE");
        assertEq(address(votesAggregator.sGrove()), address(sGrove), "aggregator leg 2 is sGROVE");
    }

    /// @notice The silent killer: `GovernorVotes.clock()`/`CLOCK_MODE()` wrap the token
    ///         call in try/catch and FALL BACK TO BLOCK NUMBERS. Proving the Governor
    ///         reports timestamps proves the fallback did not fire.
    function test_votes_governorIsOnTheTimestampClock() public view {
        assertEq(governor.CLOCK_MODE(), "mode=timestamp", "governor did not fall back to block numbers");
        assertEq(governor.clock(), uint48(block.timestamp), "governor clock is the wall clock");
        assertEq(votesAggregator.CLOCK_MODE(), "mode=timestamp");
        assertEq(grove.CLOCK_MODE(), "mode=timestamp");
        assertEq(sGrove.CLOCK_MODE(), "mode=timestamp", "both sources agree with the aggregator");
        assertEq(sGrove.clock(), uint48(block.timestamp));
    }

    /// @notice The aggregator refuses to be constructed against a source on a different
    ///         clock — the deploy-time guard that turns the silent failure into a revert.
    function test_votes_aggregatorRejectsZeroAndMismatchedSources() public {
        vm.expectRevert(GroveVotesAggregator.Aggregator_ZeroAddress.selector);
        new GroveVotesAggregator(address(0), address(sGrove));
        vm.expectRevert(GroveVotesAggregator.Aggregator_ZeroAddress.selector);
        new GroveVotesAggregator(address(grove), address(0));

        // a block-number source on EITHER leg is rejected at construction. Without this
        // the mismatch surfaces only as every voter silently reading ~0 votes.
        address badClock = address(new MockBlockNumberClockVotes());
        bytes memory expected = abi.encodeWithSelector(
            GroveVotesAggregator.Aggregator_ClockMismatch.selector, "mode=timestamp", "mode=blocknumber&from=default"
        );
        vm.expectRevert(expected);
        new GroveVotesAggregator(badClock, address(sGrove));
        vm.expectRevert(expected);
        new GroveVotesAggregator(address(grove), badClock);
    }

    /// @notice The string is metadata; `clock()` is behaviour. A source that DECLARES
    ///         "mode=timestamp" while checkpointing in block numbers is the one case a
    ///         string-only guard would wave through — straight into the silent failure the
    ///         guard exists to prevent. Constructing against it must revert on the VALUE.
    function test_votes_aggregatorRejectsASourceThatOnlyClaimsTimestamps() public {
        address liar = address(new MockLyingClockVotes());
        assertEq(MockLyingClockVotes(liar).CLOCK_MODE(), "mode=timestamp", "the string half is a clean pass");
        assertTrue(uint48(block.number) != uint48(block.timestamp), "the two clocks genuinely differ here");

        bytes memory expected = abi.encodeWithSelector(
            GroveVotesAggregator.Aggregator_ClockValueMismatch.selector, uint48(block.timestamp), uint48(block.number)
        );
        vm.expectRevert(expected);
        new GroveVotesAggregator(liar, address(sGrove));
        vm.expectRevert(expected);
        new GroveVotesAggregator(address(grove), liar);
    }

    // ── the headline: staked-only power votes at exactly its stake ───────

    /// @notice HEADLINE. An actor whose ONLY governance power is staked GROVE — zero
    ///         GROVE left in the wallet — casts a vote whose recorded weight equals
    ///         their stake exactly. This is the whole point of L-02.
    function test_votes_stakedOnlyActorVotesWithExactlyTheirStake() public {
        _stakeGrove(stakedOnlyVoter, BIG_STAKE);
        vm.warp(block.timestamp + 1); // checkpoint visible at any later snapshot

        // they genuinely hold nothing: pre-L-02 this address had zero governance power
        assertEq(grove.balanceOf(stakedOnlyVoter), 0, "wallet GROVE fully staked");
        assertEq(grove.getVotes(stakedOnlyVoter), 0, "no wallet votes at all");
        assertEq(sGrove.stakedOf(stakedOnlyVoter), BIG_STAKE);
        assertEq(sGrove.getVotes(stakedOnlyVoter), BIG_STAKE, "sGROVE self-delegated on stake");
        assertEq(votesAggregator.getVotes(stakedOnlyVoter), BIG_STAKE, "aggregate is the stake, counted ONCE");

        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "staked voter speaks");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), BIG_STAKE, "Governor sees the staked weight");

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(stakedOnlyVoter, proposalId, 1, BIG_STAKE, "");
        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertEq(forVotes, BIG_STAKE, "recorded For weight IS the stake");
        assertEq(against, 0);
        assertEq(abstain, 0);
        assertTrue(governor.hasVoted(proposalId, stakedOnlyVoter));
        // the treasury shed exactly what the staker staked: no weight created, none lost
        assertEq(grove.getPastVotes(frTreasury, snapshot), Config.GROVE_INITIAL_SUPPLY - BIG_STAKE, "treasury shed it");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    /// @notice A TOP-UP stake books exactly the increment — and does not silently revoke a
    ///         delegation. This is the `false` arm of `if (delegates(msg.sender) == 0)` in
    ///         `stake()`: on every stake after the first, the self-delegation must NOT be
    ///         re-run. Re-running it would move `_getVotingUnits(account)` (the whole
    ///         prior stake) on top of the increment, and — phase 2 — would yank a
    ///         third-party delegation back to the staker without them asking.
    function test_votes_topUpStakeAddsExactlyTheIncrement() public {
        uint256 first = 30_000_000e18;
        uint256 second = 20_000_000e18;
        uint256 third = 5_000_000e18;

        // ── phase 1: top up while self-delegated ──
        _stakeGrove(stakedOnlyVoter, first);
        assertEq(sGrove.getVotes(stakedOnlyVoter), first, "first stake self-delegates and books once");
        assertEq(sGrove.delegates(stakedOnlyVoter), stakedOnlyVoter, "delegate on record after the first stake");
        vm.warp(block.timestamp + 1);

        _stakeGrove(stakedOnlyVoter, second);
        assertEq(sGrove.stakedOf(stakedOnlyVoter), first + second, "stake ledger is the sum");
        assertEq(sGrove.getVotes(stakedOnlyVoter), first + second, "votes are the sum, NOT first counted twice");
        assertEq(sGrove.totalVotingUnits(), first + second);
        assertEq(votesAggregator.getVotes(stakedOnlyVoter), first + second, "aggregate agrees");

        // ── phase 2: delegate away, then top up again ──
        vm.prank(stakedOnlyVoter);
        sGrove.delegate(plainHolder);
        _stakeGrove(stakedOnlyVoter, third);
        assertEq(sGrove.delegates(stakedOnlyVoter), plainHolder, "a top-up did not re-delegate to self");
        assertEq(sGrove.getVotes(stakedOnlyVoter), 0, "the staker keeps no votes while delegated away");
        assertEq(sGrove.getVotes(plainHolder), first + second + third, "the increment followed the delegation");
        assertEq(sGrove.stakedOf(stakedOnlyVoter), first + second + third, "but the STAKE is still the staker's");
        vm.warp(block.timestamp + 1);

        // ── phase 3: the delegate votes with the whole position, once ──
        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "topped-up stake votes");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(plainHolder, snapshot), first + second + third, "Governor sees the sum");
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), 0);

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(plainHolder, proposalId, 1, first + second + third, "");
        vm.prank(plainHolder);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, first + second + third, "recorded weight is the summed stake, counted once");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    /// @notice A staked-only actor can also PROPOSE: `propose` reads
    ///         `getVotes(proposer, clock() - 1)`, which must route through the aggregator.
    function test_votes_stakedOnlyActorCanPropose() public {
        // exactly the threshold, sourced purely from stake
        _stakeGrove(stakedOnlyVoter, Config.GOV_PROPOSAL_THRESHOLD);
        vm.warp(block.timestamp + 1);
        assertEq(grove.balanceOf(stakedOnlyVoter), 0, "zero wallet GROVE");
        assertEq(governor.getVotes(stakedOnlyVoter, governor.clock() - 1), Config.GOV_PROPOSAL_THRESHOLD);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _feeProposal(1_200);
        vm.prank(stakedOnlyVoter);
        uint256 proposalId = governor.propose(targets, values, calldatas, "staked proposer");
        assertEq(governor.proposalProposer(proposalId), stakedOnlyVoter, "staked-only actor is the proposer");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    /// @notice One below the threshold on staked power alone still cannot propose —
    ///         the aggregator adds weight, it does not manufacture it.
    function test_votes_stakedOnlyBelowThresholdCannotPropose() public {
        _stakeGrove(stakedOnlyVoter, Config.GOV_PROPOSAL_THRESHOLD - 1);
        vm.warp(block.timestamp + 1);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _feeProposal(1_200);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector,
                stakedOnlyVoter,
                Config.GOV_PROPOSAL_THRESHOLD - 1,
                Config.GOV_PROPOSAL_THRESHOLD
            )
        );
        vm.prank(stakedOnlyVoter);
        governor.propose(targets, values, calldatas, "underpowered staker");
    }

    /// @notice A full lifecycle carried by staked GROVE ALONE — the treasury casts no
    ///         vote — reaching `Executed` with a real protocol parameter change on-chain.
    function test_votes_proposalPassesOnStakedGroveAloneAndExecutes() public {
        assertEq(waterfall.protocolFeeBps(), 1_000, "launch default");
        _stakeGrove(stakedOnlyVoter, BIG_STAKE); // 50M > 40M quorum
        vm.warp(block.timestamp + 1);

        string memory description = "stakers raise the protocol fee";
        uint256 proposalId = _proposeAndOpen(stakedOnlyVoter, 1_500, description);
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertGt(BIG_STAKE, governor.quorum(snapshot), "stake alone clears quorum");

        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, BIG_STAKE, "the only votes cast are staked votes");

        _closeQueueExecute(proposalId, 1_500, description);
        assertEq(waterfall.protocolFeeBps(), 1_500, "a real parameter change landed via the timelock");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    // ── quorum: GROVE supply only, immune to staking ─────────────────────

    /// @notice Staking must NOT move `quorum(t)`. Summing the two supplies would have
    ///         raised the bar — and let a whale stake before a snapshot purely to block
    ///         a proposal it opposed.
    function test_votes_quorumIsUnaffectedByStaking() public {
        uint256 expected = Config.GROVE_INITIAL_SUPPLY * Config.GOV_QUORUM_FRACTION / governor.quorumDenominator();

        uint256 t1 = block.timestamp - 1;
        uint256 quorumBefore = governor.quorum(t1);
        assertEq(quorumBefore, expected, "4% of the fixed GROVE supply");
        assertEq(sGrove.totalStaked(), 0, "nothing staked yet");

        _stakeGrove(stakedOnlyVoter, 200_000_000e18); // 20% of supply staked
        vm.warp(block.timestamp + 2);

        uint256 t2 = block.timestamp - 1;
        uint256 quorumAfter = governor.quorum(t2);
        assertEq(quorumAfter, quorumBefore, "staking moved the quorum bar by exactly nothing");
        assertEq(quorumAfter, expected);

        // the denominator is GROVE only, and GROVE's supply already contains the stake
        assertEq(votesAggregator.getPastTotalSupply(t2), grove.getPastTotalSupply(t2), "GROVE-only denominator");
        assertEq(grove.getPastTotalSupply(t2), Config.GROVE_INITIAL_SUPPLY, "fixed supply, no mint/burn path");

        // and now the failure this design prevents, made explicit
        uint256 summedSupply = grove.getPastTotalSupply(t2) + sGrove.getPastTotalSupply(t2);
        assertEq(sGrove.getPastTotalSupply(t2), 200_000_000e18, "staked units are real units");
        assertGt(summedSupply, grove.getPastTotalSupply(t2), "summing would double-count the staked GROVE");
        uint256 inflatedQuorum = summedSupply * Config.GOV_QUORUM_FRACTION / governor.quorumDenominator();
        assertGt(inflatedQuorum, quorumAfter, "a summed denominator would have STRICTLY raised the quorum bar");
        assertEq(inflatedQuorum, 48_000_000e18, "4% of 1.2e9 rather than of 1e9");
    }

    /// @notice The quorum bar seen from the FAILING side: staked power above the proposal
    ///         threshold but below quorum carries a proposal to `Defeated`, and the bar it
    ///         failed against is exactly 4% of the fixed GROVE supply.
    function test_votes_stakedPowerBelowQuorumIsDefeated() public {
        uint256 belowQuorum = 39_000_000e18; // > 1M threshold, < 40M quorum
        _stakeGrove(stakedOnlyVoter, belowQuorum);
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _proposeAndOpen(stakedOnlyVoter, 1_500, "39M is not enough");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.quorum(snapshot), 40_000_000e18, "the bar is 4% of the 1e9 GROVE supply");

        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, belowQuorum, "all of the staked weight was cast For");
        assertLt(forVotes, governor.quorum(snapshot), "and it still falls short");

        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated), "quorum not reached");
        assertEq(waterfall.protocolFeeBps(), 1_000, "no parameter change landed");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    /// @notice The quorum design decision with an OUTCOME attached. 41M of staked power
    ///         sits in the band where the choice of denominator flips the result: it clears
    ///         the correct GROVE-only bar (40M) and so `Succeeded`, but a summed
    ///         `grove + sGrove` denominator would have raised the bar to 41.64M and
    ///         `Defeated` it. That is the stake-to-block-a-proposal exploit, priced.
    function test_votes_quorumInflationWouldHaveFlippedThisOutcome() public {
        uint256 pivotalStake = 41_000_000e18;
        _stakeGrove(stakedOnlyVoter, pivotalStake);
        vm.warp(block.timestamp + 1);

        string memory description = "41M is decisive under the correct denominator";
        uint256 proposalId = _proposeAndOpen(stakedOnlyVoter, 1_500, description);
        uint256 snapshot = governor.proposalSnapshot(proposalId);

        uint256 realQuorum = governor.quorum(snapshot);
        assertEq(realQuorum, 40_000_000e18, "GROVE-only denominator: 4% of 1e9");
        assertGe(pivotalStake, realQuorum, "the stake clears the real bar");

        // the counterfactual bar, computed from the same on-chain supplies
        uint256 summedSupply = grove.getPastTotalSupply(snapshot) + sGrove.getPastTotalSupply(snapshot);
        uint256 inflatedQuorum = summedSupply * Config.GOV_QUORUM_FRACTION / governor.quorumDenominator();
        assertEq(inflatedQuorum, 41_640_000e18, "4% of 1.041e9");
        assertLt(pivotalStake, inflatedQuorum, "the SAME votes would have missed the inflated bar");

        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, pivotalStake);

        _closeQueueExecute(proposalId, 1_500, description);
        assertEq(waterfall.protocolFeeBps(), 1_500, "the change landed, because the denominator is GROVE only");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    // ── conservation: staking neither creates nor destroys weight ────────

    /// @notice The treasury's recorded voting weight at a proposal snapshot is IDENTICAL
    ///         whether or not it staked beforehand. Two full proposals, run to
    ///         `Executed`, produce byte-identical `forVotes`.
    function test_votes_weightConservedAcrossStaking() public {
        uint256 treasuryGrove = grove.balanceOf(frTreasury);

        // ── shape A: treasury has staked nothing ──
        string memory descA = "shape A: unstaked treasury";
        uint256 idA = _proposeAndOpen(frTreasury, 1_500, descA);
        uint256 snapA = governor.proposalSnapshot(idA);
        assertEq(sGrove.totalStaked(), 0, "shape A really is unstaked");
        vm.prank(frTreasury);
        governor.castVote(idA, 1);
        (, uint256 forVotesA,) = governor.proposalVotes(idA);
        _closeQueueExecute(idA, 1_500, descA);
        assertEq(waterfall.protocolFeeBps(), 1_500);

        // ── shape B: identical holdings, but half of them staked ──
        uint256 stakeAmount = treasuryGrove / 2;
        _stakeGrove(frTreasury, stakeAmount);
        vm.warp(block.timestamp + 1);
        assertEq(grove.balanceOf(frTreasury), treasuryGrove - stakeAmount, "half the wallet moved into the backstop");
        assertEq(sGrove.stakedOf(frTreasury), stakeAmount);

        string memory descB = "shape B: half-staked treasury";
        uint256 idB = _proposeAndOpen(frTreasury, 1_200, descB);
        uint256 snapB = governor.proposalSnapshot(idB);
        vm.prank(frTreasury);
        governor.castVote(idB, 1);
        (, uint256 forVotesB,) = governor.proposalVotes(idB);
        _closeQueueExecute(idB, 1_200, descB);
        assertEq(waterfall.protocolFeeBps(), 1_200);

        // the property
        assertEq(forVotesB, forVotesA, "staking changed the treasury's voting weight by exactly nothing");
        assertEq(forVotesA, treasuryGrove, "and the weight is the full holding in both shapes");

        // the composition differs even though the total does not — proof it is not a
        // coincidence of the aggregator reading only one leg
        assertEq(grove.getPastVotes(frTreasury, snapA), treasuryGrove, "shape A: all weight on the GROVE leg");
        assertEq(sGrove.getPastVotes(frTreasury, snapA), 0, "shape A: nothing on the sGROVE leg");
        assertEq(grove.getPastVotes(frTreasury, snapB), treasuryGrove - stakeAmount, "shape B: split across legs");
        assertEq(sGrove.getPastVotes(frTreasury, snapB), stakeAmount);
        _assertVotingUnitsConsistent(snapA, Config.GROVE_INITIAL_SUPPLY);
        _assertVotingUnitsConsistent(snapB, Config.GROVE_INITIAL_SUPPLY);
    }

    // ── unbonding does not vote ──────────────────────────────────────────

    /// @notice Requesting exit BEFORE the snapshot removes the weight immediately —
    ///         unbonding stake has no say, and `claimUnstake` is vote-neutral.
    function test_votes_unbondingBeforeSnapshotHasZeroWeight() public {
        _stakeGrove(stakedOnlyVoter, BIG_STAKE);
        vm.warp(block.timestamp + 1);
        assertEq(votesAggregator.getVotes(stakedOnlyVoter), BIG_STAKE, "weight exists before the exit request");

        vm.prank(stakedOnlyVoter);
        uint256 unbondId = sGrove.requestUnstake(BIG_STAKE);
        assertEq(sGrove.getVotes(stakedOnlyVoter), 0, "voting units burned at requestUnstake, not at claim");
        assertEq(sGrove.totalVotingUnits(), 0);
        assertEq(sGrove.totalStaked(), 0);
        assertEq(grove.balanceOf(address(sGrove)), BIG_STAKE, "the GROVE is still custodied, just not voting");
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "unbonder tries to vote");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), 0, "zero weight at the snapshot");

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(stakedOnlyVoter, proposalId, 1, 0, "");
        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 0, "an unbonding position contributes nothing");

        // claiming the matured unbond must not resurrect or re-burn any votes
        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD + 1);
        vm.prank(stakedOnlyVoter);
        sGrove.claimUnstake(unbondId);
        assertEq(sGrove.getVotes(stakedOnlyVoter), 0, "claimUnstake is vote-neutral");
        assertEq(sGrove.totalVotingUnits(), 0);
        assertEq(grove.balanceOf(stakedOnlyVoter), BIG_STAKE, "made whole in GROVE");
        // the unbonded weight is simply GONE from the aggregate at that snapshot: the
        // treasury no longer holds it and no sGROVE leg counts it
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY - BIG_STAKE);
    }

    /// @notice Exiting AFTER the snapshot keeps the weight for that proposal — standard
    ///         Governor semantics, preserved by the sGROVE checkpoints.
    function test_votes_unstakingAfterSnapshotKeepsWeight() public {
        _stakeGrove(stakedOnlyVoter, BIG_STAKE);
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "exit after the snapshot");
        uint256 snapshot = governor.proposalSnapshot(proposalId);

        vm.prank(stakedOnlyVoter);
        sGrove.requestUnstake(BIG_STAKE);
        assertEq(votesAggregator.getVotes(stakedOnlyVoter), 0, "no CURRENT weight after the exit request");
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), BIG_STAKE, "but the SNAPSHOT weight is intact");

        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, BIG_STAKE, "the snapshot governs, exactly as for a GROVE transfer");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    /// @notice A PARTIAL exit burns exactly the requested amount of voting power and
    ///         leaves the remainder voting. Every other unstake in this file is a full
    ///         exit, which cannot distinguish "burn `amount`" from "burn the whole
    ///         position" — this one can, and the remainder is asserted to the wei.
    function test_votes_partialUnbondLeavesTheRemainderVoting() public {
        _stakeGrove(stakedOnlyVoter, BIG_STAKE);
        vm.warp(block.timestamp + 1);

        uint256 exiting = BIG_STAKE / 4; // 12.5M
        uint256 remaining = BIG_STAKE - exiting; // 37.5M
        vm.prank(stakedOnlyVoter);
        sGrove.requestUnstake(exiting);

        assertEq(sGrove.stakedOf(stakedOnlyVoter), remaining, "only the requested slice left the active stake");
        assertEq(sGrove.getVotes(stakedOnlyVoter), remaining, "votes burned by the amount, not by the position");
        assertEq(sGrove.totalStaked(), remaining);
        assertEq(sGrove.totalVotingUnits(), remaining, "supply-side units track the partial burn too");
        assertEq(grove.balanceOf(address(sGrove)), BIG_STAKE, "all the GROVE is still custodied");
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "partial unbonder votes with the rest");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), remaining, "Governor sees exactly the remainder");

        vm.expectEmit(true, false, false, true, address(governor));
        emit IGovernor.VoteCast(stakedOnlyVoter, proposalId, 1, remaining, "");
        vm.prank(stakedOnlyVoter);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, remaining, "recorded weight is the remainder, to the wei");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY - exiting);
    }

    /// @notice When the stake is delegated onward, unbonding must burn from the DELEGATE's
    ///         weight — the staker holds none to burn. Getting this backwards would either
    ///         underflow or leave the delegate voting with weight that no longer exists.
    function test_votes_unstakingBurnsFromTheDelegateNotTheStaker() public {
        _stakeGrove(stakedOnlyVoter, BIG_STAKE);
        vm.prank(stakedOnlyVoter);
        sGrove.delegate(plainHolder);
        vm.warp(block.timestamp + 1);
        assertEq(sGrove.getVotes(plainHolder), BIG_STAKE, "delegate holds all of it before the exit");
        assertEq(sGrove.getVotes(stakedOnlyVoter), 0, "the staker holds none of it");

        uint256 exiting = BIG_STAKE / 2;
        vm.prank(stakedOnlyVoter);
        sGrove.requestUnstake(exiting);
        assertEq(sGrove.getVotes(plainHolder), BIG_STAKE - exiting, "the DELEGATE lost exactly the exited half");
        assertEq(sGrove.getVotes(stakedOnlyVoter), 0, "the staker still holds none - nothing was burned from them");
        assertEq(sGrove.stakedOf(stakedOnlyVoter), BIG_STAKE - exiting, "the stake ledger stays with the STAKER");
        assertEq(sGrove.totalVotingUnits(), BIG_STAKE - exiting);
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "delegate votes the surviving half");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(plainHolder, snapshot), BIG_STAKE - exiting, "Governor sees the reduced delegation");
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), 0);

        vm.prank(plainHolder);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, BIG_STAKE - exiting, "half the position votes, for the delegate, exactly once");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY - exiting);
    }

    // ── anti-regression: plain holders are untouched ─────────────────────

    /// @notice A GROVE holder who never stakes votes exactly as before L-02 — same
    ///         weight, same lifecycle, sGROVE leg contributing zero.
    function test_votes_plainGroveHolderUnaffected() public {
        uint256 amount = 60_000_000e18;
        vm.prank(frTreasury);
        grove.transfer(plainHolder, amount);
        vm.prank(plainHolder);
        grove.delegate(plainHolder);
        vm.warp(block.timestamp + 1);

        string memory description = "plain holder, unchanged behaviour";
        uint256 proposalId = _proposeAndOpen(plainHolder, 1_500, description);
        uint256 snapshot = governor.proposalSnapshot(proposalId);

        assertEq(sGrove.getPastVotes(plainHolder, snapshot), 0, "never staked, sGROVE leg is zero");
        assertEq(grove.getPastVotes(plainHolder, snapshot), amount);
        assertEq(governor.getVotes(plainHolder, snapshot), amount, "aggregate == the GROVE leg alone");

        vm.prank(plainHolder);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, amount);

        _closeQueueExecute(proposalId, 1_500, description);
        assertEq(waterfall.protocolFeeBps(), 1_500, "unchanged path still lands the change");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }

    /// @notice Delegation is per-source: the aggregator refuses to answer or route it,
    ///         rather than returning one source's answer as if it were the whole picture.
    function test_votes_delegationMustHappenOnTheSource() public {
        _stakeGrove(stakedOnlyVoter, BIG_STAKE);
        vm.warp(block.timestamp + 1);

        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        votesAggregator.delegates(stakedOnlyVoter);
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        vm.prank(stakedOnlyVoter);
        votesAggregator.delegate(stakedOnlyVoter);
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        votesAggregator.delegateBySig(stakedOnlyVoter, 0, type(uint256).max, 27, bytes32(0), bytes32(0));

        assertEq(votesAggregator.sGroveDelegates(stakedOnlyVoter), stakedOnlyVoter, "self-delegated by stake()");
        assertEq(votesAggregator.groveDelegates(stakedOnlyVoter), address(0), "never delegated wallet GROVE");

        // a staker CAN delegate their staked votes onward, on the source
        vm.prank(stakedOnlyVoter);
        sGrove.delegate(plainHolder);
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _proposeAndOpen(frTreasury, 1_500, "delegated stake votes");
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(governor.getVotes(stakedOnlyVoter, snapshot), 0, "power moved to the delegate");
        assertEq(governor.getVotes(plainHolder, snapshot), BIG_STAKE, "delegate carries the staked weight");

        vm.prank(plainHolder);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, BIG_STAKE, "counted exactly once, for the delegate");
        _assertVotingUnitsConsistent(snapshot, Config.GROVE_INITIAL_SUPPLY);
    }
}
