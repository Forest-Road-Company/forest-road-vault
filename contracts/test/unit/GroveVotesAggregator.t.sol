// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";

import {GroveVotesAggregator} from "../../src/GroveVotesAggregator.sol";
import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @title GroveVotesAggregator unit suite (ADR-0026, L-02)
/// @notice Pins the aggregator's composition rule — SUM for votes, GROVE-ONLY for the
///         quorum denominator — plus the constructor clock guard, the deliberate
///         non-swallowing of either leg, and the per-source delegation posture.
contract GroveVotesAggregatorTest is GovernanceFixture {
    string internal constant TIMESTAMP_MODE = "mode=timestamp";
    string internal constant BLOCK_MODE = "mode=blocknumber&from=default";

    /// @dev A timepoint strictly before any contract in the fixture existed.
    uint256 internal genesisTimepoint;

    function setUp() public virtual override {
        super.setUp();
        // fixture deploys at 1_750_000_000 and warps +1; this is strictly earlier
        genesisTimepoint = block.timestamp - 2;
    }

    // ── constructor: wiring ──────────────────────────────────────────────

    /// @notice Immutables return exactly the wired sources.
    function test_constructor_wiresImmutables() public view {
        assertEq(address(votesAggregator.grove()), address(grove), "grove immutable");
        assertEq(address(votesAggregator.sGrove()), address(sGrove), "sGrove immutable");
    }

    /// @notice Both sources reporting the timestamp clock constructs cleanly (the
    ///         happy branch of both `_requireTimestampClock` call sites).
    function test_constructor_acceptsTimestampClockOnBothLegs() public {
        MockTimestampClockVotes mockGrove = new MockTimestampClockVotes();
        MockTimestampClockVotes mockSGrove = new MockTimestampClockVotes();
        GroveVotesAggregator agg = new GroveVotesAggregator(address(mockGrove), address(mockSGrove));
        assertEq(address(agg.grove()), address(mockGrove), "grove leg accepted");
        assertEq(address(agg.sGrove()), address(mockSGrove), "sGrove leg accepted");
    }

    // ── constructor: zero-address branches (both sides of the `||`) ──────

    /// @notice A zero GROVE address reverts — left operand of the zero check.
    function test_constructor_revertsOnZeroGrove() public {
        vm.expectRevert(GroveVotesAggregator.Aggregator_ZeroAddress.selector);
        new GroveVotesAggregator(address(0), address(sGrove));
    }

    /// @notice A zero sGROVE address reverts — right operand of the zero check.
    function test_constructor_revertsOnZeroSGrove() public {
        vm.expectRevert(GroveVotesAggregator.Aggregator_ZeroAddress.selector);
        new GroveVotesAggregator(address(grove), address(0));
    }

    // ── constructor: the clock guard, per leg ────────────────────────────

    /// @notice A GROVE source on the block-number clock reverts with the exact
    ///         (expected, actual) pair — first `_requireTimestampClock` call site.
    function test_constructor_revertsOnGroveClockMismatch() public {
        MockBlockNumberClockVotes badGrove = new MockBlockNumberClockVotes();
        string memory expected = TIMESTAMP_MODE;
        string memory actual = BLOCK_MODE;
        vm.expectRevert(
            abi.encodeWithSelector(GroveVotesAggregator.Aggregator_ClockMismatch.selector, expected, actual)
        );
        new GroveVotesAggregator(address(badGrove), address(sGrove));
    }

    /// @notice An sGROVE source on the block-number clock reverts with the exact
    ///         (expected, actual) pair — second `_requireTimestampClock` call site.
    ///         The GROVE leg here is the REAL, correct token, so only the sGROVE
    ///         check can be what fired.
    function test_constructor_revertsOnSGroveClockMismatch() public {
        MockBlockNumberClockVotes badSGrove = new MockBlockNumberClockVotes();
        string memory expected = TIMESTAMP_MODE;
        string memory actual = BLOCK_MODE;
        vm.expectRevert(
            abi.encodeWithSelector(GroveVotesAggregator.Aggregator_ClockMismatch.selector, expected, actual)
        );
        new GroveVotesAggregator(address(grove), address(badSGrove));
    }

    /// @notice Any non-timestamp mode string is rejected, not just the OZ default —
    ///         the guard is an exact-match, not a substring sniff.
    function test_constructor_revertsOnArbitraryClockMode() public {
        MockCustomClockVotes weird = new MockCustomClockVotes("mode=timestamp ");
        string memory expected = TIMESTAMP_MODE;
        string memory actual = "mode=timestamp ";
        vm.expectRevert(
            abi.encodeWithSelector(GroveVotesAggregator.Aggregator_ClockMismatch.selector, expected, actual)
        );
        new GroveVotesAggregator(address(weird), address(sGrove));
    }

    // ── constructor: the clock VALUE guard (the "lying clock") ───────────

    /// @notice A GROVE source that DECLARES `mode=timestamp` while actually running on
    ///         block numbers is rejected — the string alone is metadata, the live `clock()`
    ///         value is the behaviour, and this is precisely the silent mismatch the guard
    ///         exists to make loud. First `_requireTimestampClock` call site.
    function test_constructor_revertsOnGroveClockValueMismatch() public {
        MockLyingClockVotes liar = new MockLyingClockVotes(uint48(block.number));
        // the lie is exactly what makes it dangerous: the STRING check waves it through
        assertEq(liar.CLOCK_MODE(), TIMESTAMP_MODE, "declares the timestamp clock");
        assertTrue(liar.clock() != uint48(block.timestamp), "but does not run on it");

        vm.expectRevert(
            abi.encodeWithSelector(
                GroveVotesAggregator.Aggregator_ClockValueMismatch.selector,
                uint48(block.timestamp),
                uint48(block.number)
            )
        );
        new GroveVotesAggregator(address(liar), address(sGrove));
    }

    /// @notice The same guard on the sGROVE leg, and at the nastiest magnitude: a source
    ///         one single second out of step is still rejected. The GROVE leg here is the
    ///         REAL, correct token, so only the second call site can be what fired.
    function test_constructor_revertsOnSGroveClockValueMismatchByOneSecond() public {
        uint48 drifted = uint48(block.timestamp) + 1;
        MockLyingClockVotes liar = new MockLyingClockVotes(drifted);
        vm.expectRevert(
            abi.encodeWithSelector(
                GroveVotesAggregator.Aggregator_ClockValueMismatch.selector, uint48(block.timestamp), drifted
            )
        );
        new GroveVotesAggregator(address(grove), address(liar));
    }

    // ── constructor: sources that are not vote sources at all ────────────

    /// @notice A source that is not an `IERC5805` at all — e.g. a deployer wiring a plain
    ///         ERC-20 as GROVE — is rejected with a NAMED error carrying an EMPTY `actual`.
    /// @dev This test previously pinned a bare `vm.expectRevert(bytes(""))`, deliberately, so
    ///      that adding a typed error would break it and force the assertion to be tightened.
    ///      That is exactly what happened: `_requireTimestampClock` now wraps the
    ///      `CLOCK_MODE()` call so a missing selector re-throws as
    ///      `Aggregator_ClockMismatch("mode=timestamp", "")` instead of the undiagnosable
    ///      empty-returndata revert. The empty `actual` IS the diagnosis: "this address is
    ///      not a vote source at all" (CLAUDE.md prime directive 4).
    function test_constructor_revertsNamedOnNonVotesSource() public {
        assertGt(address(usdc).code.length, 0, "precondition: a real contract");
        vm.expectRevert(
            abi.encodeWithSelector(GroveVotesAggregator.Aggregator_ClockMismatch.selector, TIMESTAMP_MODE, "")
        );
        new GroveVotesAggregator(address(usdc), address(sGrove));
    }

    /// @notice A codeless (EOA) source is rejected with its OWN named error.
    /// @dev The `try` around `CLOCK_MODE()` does NOT cover this case — Solidity emits the
    ///      `extcodesize` guard BEFORE the call and outside the `try`, so a codeless address
    ///      still produced a bare empty-returndata revert until an explicit `code.length`
    ///      check was added. Proven by this test failing with
    ///      "call reverted as expected, but without data" before that check existed. Pasting a
    ///      wallet address where a module belongs is the likeliest deployer slip, so it gets a
    ///      distinct error rather than being folded into the clock mismatch.
    function test_constructor_revertsNamedOnCodelessSource() public {
        address eoa = makeAddr("notAContract");
        assertEq(eoa.code.length, 0, "precondition: no code");
        vm.expectRevert(abi.encodeWithSelector(GroveVotesAggregator.Aggregator_NotAContract.selector, eoa));
        new GroveVotesAggregator(address(grove), eoa);
    }

    /// @notice The codeless check covers the GROVE leg too (both `_requireTimestampClock`
    ///         call sites), not just the sGROVE one.
    function test_constructor_revertsNamedOnCodelessGroveLeg() public {
        address eoa = makeAddr("notAContractEither");
        vm.expectRevert(abi.encodeWithSelector(GroveVotesAggregator.Aggregator_NotAContract.selector, eoa));
        new GroveVotesAggregator(eoa, address(sGrove));
    }

    // ── EIP-6372 clock ───────────────────────────────────────────────────

    /// @notice `clock()` is the live block timestamp (not a cached or forwarded value).
    function test_clock_isBlockTimestamp() public {
        assertEq(votesAggregator.clock(), uint48(block.timestamp), "clock now");
        vm.warp(block.timestamp + 12_345);
        assertEq(votesAggregator.clock(), uint48(block.timestamp), "clock after warp");
    }

    /// @notice `CLOCK_MODE()` is exactly the timestamp mode both sources report.
    function test_clockMode_isTimestamp() public view {
        assertEq(votesAggregator.CLOCK_MODE(), TIMESTAMP_MODE, "aggregator mode");
        assertEq(grove.CLOCK_MODE(), TIMESTAMP_MODE, "grove agrees");
        assertEq(sGrove.CLOCK_MODE(), TIMESTAMP_MODE, "sGrove agrees");
    }

    // ── getPastVotes: the SUM ────────────────────────────────────────────

    /// @notice Before either source has a checkpoint for an account, past votes are 0.
    /// @dev A SMOKE CHECK, not a pin. Every assertion here is against zero, so it cannot
    ///      discriminate between a correct aggregator and most broken ones (an aggregator
    ///      that dropped a leg entirely would still pass). The discriminating value
    ///      assertions live in `test_getPastVotes_isExactSumOfBothLegs` and the fuzz test;
    ///      do not count this test as covering the composition rule.
    function test_getPastVotes_zeroBeforeAnyCheckpoint() public {
        assertEq(grove.getPastVotes(alice, genesisTimepoint), 0, "grove leg empty");
        assertEq(sGrove.getPastVotes(alice, genesisTimepoint), 0, "sGrove leg empty");
        assertEq(votesAggregator.getPastVotes(alice, genesisTimepoint), 0, "sum empty");
        address nobody = makeAddr("nobody");
        assertEq(votesAggregator.getPastVotes(nobody, genesisTimepoint), 0, "unknown account");
        // even at the latest readable timepoint, an account with nothing has nothing
        assertEq(votesAggregator.getPastVotes(nobody, block.timestamp - 1), 0, "still nothing later");
    }

    /// @notice `getPastVotes` is the exact arithmetic sum of both legs at every
    ///         timepoint in a wallet-only -> wallet+stake -> stake-only progression.
    function test_getPastVotes_isExactSumOfBothLegs() public {
        // t1: alice self-delegates GROVE and holds 100, stakes nothing
        vm.prank(alice);
        grove.delegate(alice);
        vm.prank(frTreasury);
        grove.transfer(alice, 100e18);
        vm.warp(block.timestamp + 1);
        uint256 t1 = block.timestamp - 1;

        // t2: alice stakes 40 -> wallet 60 (delegated to self) + stake 40
        vm.startPrank(alice);
        grove.approve(address(sGrove), 40e18);
        sGrove.stake(40e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        uint256 t2 = block.timestamp - 1;

        // t3: alice stakes the remaining 60 -> wallet 0 + stake 100
        vm.startPrank(alice);
        grove.approve(address(sGrove), 60e18);
        sGrove.stake(60e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        uint256 t3 = block.timestamp - 1;

        _assertSumAt(alice, t1);
        _assertSumAt(alice, t2);
        _assertSumAt(alice, t3);

        // and the absolute values, so this is not a tautology over two zeroes
        assertEq(votesAggregator.getPastVotes(alice, t1), 100e18, "t1 wallet only");
        assertEq(grove.getPastVotes(alice, t2), 60e18, "t2 wallet leg");
        assertEq(sGrove.getPastVotes(alice, t2), 40e18, "t2 stake leg");
        assertEq(votesAggregator.getPastVotes(alice, t2), 100e18, "t2 sum");
        assertEq(grove.getPastVotes(alice, t3), 0, "t3 wallet leg drained");
        assertEq(votesAggregator.getPastVotes(alice, t3), 100e18, "t3 stake only");
    }

    /// @notice Staking never changes an account's aggregate voting power, and never
    ///         changes anyone else's — the GROVE the backstop custodies is left
    ///         undelegated, so it reappears exactly once as sGROVE votes.
    function test_getPastVotes_stakingLeavesAggregatePowerUnchanged() public {
        vm.prank(alice);
        grove.delegate(alice);
        vm.prank(frTreasury);
        grove.transfer(alice, 250e18);
        vm.warp(block.timestamp + 1);
        uint256 tBefore = block.timestamp - 1;

        uint256 aliceBefore = votesAggregator.getPastVotes(alice, tBefore);
        uint256 treasuryBefore = votesAggregator.getPastVotes(frTreasury, tBefore);
        assertEq(aliceBefore, 250e18, "alice holds 250 delegated to self");

        vm.startPrank(alice);
        grove.approve(address(sGrove), 250e18);
        sGrove.stake(250e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        uint256 tAfter = block.timestamp - 1;

        assertEq(votesAggregator.getPastVotes(alice, tAfter), aliceBefore, "alice power preserved");
        assertEq(votesAggregator.getPastVotes(frTreasury, tAfter), treasuryBefore, "no leakage to treasury");
        // and the backstop itself votes for nobody
        assertEq(votesAggregator.getPastVotes(address(sGrove), tAfter), 0, "backstop holds no votes");
        assertEq(grove.getPastVotes(address(sGrove), tAfter), 0, "custodied GROVE is undelegated");
    }

    /// @notice Unbonding stake stops voting the instant `requestUnstake` lands, and
    ///         `claimUnstake` is vote-neutral.
    function test_getPastVotes_unbondingRemovesPowerImmediately() public {
        _stakeGrove(alice, 100e18);
        vm.warp(block.timestamp + 1);
        assertEq(votesAggregator.getPastVotes(alice, block.timestamp - 1), 100e18, "staked votes");

        vm.prank(alice);
        uint256 unbondId = sGrove.requestUnstake(40e18);
        vm.warp(block.timestamp + 1);
        uint256 tUnbonding = block.timestamp - 1;
        assertEq(votesAggregator.getPastVotes(alice, tUnbonding), 60e18, "unbonding does not vote");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units track active stake");

        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD + 1);
        vm.prank(alice);
        sGrove.claimUnstake(unbondId);
        vm.warp(block.timestamp + 1);
        assertEq(votesAggregator.getPastVotes(alice, block.timestamp - 1), 60e18, "claim is vote-neutral");
        assertEq(grove.getPastVotes(alice, block.timestamp - 1), 0, "returned GROVE is undelegated");
    }

    /// @notice The load-bearing `stake` ordering survives the nastiest case: a staker who
    ///         deliberately abstained by delegating sGROVE to `address(0)` and then stakes
    ///         again. `delegates()` reads zero, so `stake` self-delegates and moves the
    ///         PRIOR stake — the new amount must still be booked exactly once.
    /// @dev Also documents a real behavioural consequence: that re-stake silently
    ///      re-enfranchises the abstainer.
    function test_getPastVotes_reStakeAfterAbstainingDoesNotDoubleCount() public {
        _stakeGrove(alice, 100e18);
        assertEq(sGrove.getVotes(alice), 100e18, "self-delegated on first stake");

        vm.prank(alice);
        sGrove.delegate(address(0)); // deliberate abstention
        assertEq(sGrove.delegates(alice), address(0), "abstained");
        assertEq(sGrove.getVotes(alice), 0, "no votes while abstaining");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units still reconcile");

        _stakeGrove(alice, 50e18); // stakes again -> re-self-delegates

        assertEq(sGrove.stakedOf(alice), 150e18, "stake accounting");
        assertEq(sGrove.getVotes(alice), 150e18, "150, NOT 200 -- amount booked once");
        assertEq(sGrove.totalVotingUnits(), 150e18, "supply booked once");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units == active stake");

        vm.warp(block.timestamp + 1);
        uint256 t = block.timestamp - 1;
        assertEq(votesAggregator.getPastVotes(alice, t), 150e18, "aggregate is not inflated");
        assertLe(votesAggregator.getPastVotes(alice, t), votesAggregator.getPastTotalSupply(t), "bounded by supply");
    }

    // ── getPastVotes: neither leg is swallowed ───────────────────────────

    /// @notice A future lookup on the GROVE leg propagates — proving the aggregator does
    ///         not wrap it in try/catch (a deliberate design property).
    /// @dev The sGROVE leg here is a mock that answers ANY timepoint without reverting, so
    ///      the revert can only have come from GROVE. This isolation is load-bearing: with
    ///      the REAL sGROVE wired, both legs share the timestamp clock and throw the
    ///      IDENTICAL `ERC5805FutureLookup(future, uint48(block.timestamp))`, so
    ///      `vm.expectRevert` could not tell which leg threw and a try/catch swallowing the
    ///      GROVE leg would pass. Mirrors `..._propagatesFutureLookupFromSGroveLeg`.
    function test_getPastVotes_propagatesFutureLookupFromGroveLeg() public {
        MockTimestampClockVotes tolerantSGrove = new MockTimestampClockVotes();
        GroveVotesAggregator agg = new GroveVotesAggregator(address(grove), address(tolerantSGrove));
        // sanity: the sGROVE leg really does tolerate a future timepoint
        assertEq(tolerantSGrove.getPastVotes(alice, block.timestamp + 1_000), 0, "mock leg tolerant");

        uint256 future = block.timestamp;
        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, future, uint48(block.timestamp))
        );
        agg.getPastVotes(alice, future);
    }

    /// @notice A future lookup on the sGROVE leg propagates too. The GROVE leg here is
    ///         a mock that answers any timepoint without reverting, so the revert can
    ///         only have come from sGROVE.
    function test_getPastVotes_propagatesFutureLookupFromSGroveLeg() public {
        MockTimestampClockVotes tolerantGrove = new MockTimestampClockVotes();
        GroveVotesAggregator agg = new GroveVotesAggregator(address(tolerantGrove), address(sGrove));
        // sanity: the GROVE leg really does tolerate a future timepoint
        assertEq(tolerantGrove.getPastVotes(alice, block.timestamp + 1_000), 0, "mock leg tolerant");

        uint256 future = block.timestamp;
        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, future, uint48(block.timestamp))
        );
        agg.getPastVotes(alice, future);
    }

    /// @notice The quorum read propagates a future lookup as well.
    /// @dev No mock isolation needed here: `getPastTotalSupply` reads ONE leg (GROVE), so
    ///      there is no second source the revert could have come from.
    function test_getPastTotalSupply_propagatesFutureLookup() public {
        uint256 future = block.timestamp;
        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, future, uint48(block.timestamp))
        );
        votesAggregator.getPastTotalSupply(future);
    }

    // ── getPastTotalSupply: GROVE ONLY (the easiest thing to get wrong) ──

    /// @notice The quorum denominator is GROVE total supply ONLY and does not move when
    ///         GROVE is staked — otherwise a whale could stake before a snapshot purely
    ///         to raise the bar and block a proposal.
    function test_getPastTotalSupply_isGroveOnlyAndUnmovedByStaking() public {
        vm.warp(block.timestamp + 1);
        uint256 tBefore = block.timestamp - 1;
        assertEq(votesAggregator.getPastTotalSupply(tBefore), grove.getPastTotalSupply(tBefore), "matches GROVE");
        assertEq(votesAggregator.getPastTotalSupply(tBefore), Config.GROVE_INITIAL_SUPPLY, "== fixed supply");
        assertEq(sGrove.totalVotingUnits(), 0, "nothing staked yet");

        // a very large stake — 40% of the entire supply
        uint256 whaleStake = Config.GROVE_INITIAL_SUPPLY * 4 / 10;
        _stakeGrove(alice, whaleStake);
        vm.warp(block.timestamp + 1);
        uint256 tAfter = block.timestamp - 1;

        assertEq(sGrove.totalVotingUnits(), whaleStake, "sGROVE supply moved");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units == active stake");
        assertEq(votesAggregator.getPastTotalSupply(tAfter), grove.getPastTotalSupply(tAfter), "still GROVE only");
        assertEq(votesAggregator.getPastTotalSupply(tAfter), Config.GROVE_INITIAL_SUPPLY, "denominator constant");
        assertEq(
            votesAggregator.getPastTotalSupply(tAfter),
            votesAggregator.getPastTotalSupply(tBefore),
            "staking did not move quorum"
        );
        // explicitly NOT the sum of the two supplies
        assertTrue(
            votesAggregator.getPastTotalSupply(tAfter) != Config.GROVE_INITIAL_SUPPLY + whaleStake,
            "supplies are not summed"
        );
    }

    // ── getVotes: the current-power SUM ──────────────────────────────────

    /// @notice `getVotes` is the exact sum of the two current-vote legs, including the
    ///         fully-staked case that a GROVE-only read would report as dead.
    function test_getVotes_isExactSumOfCurrentLegs() public {
        assertEq(votesAggregator.getVotes(alice), 0, "no power yet");

        vm.prank(alice);
        grove.delegate(alice);
        vm.prank(frTreasury);
        grove.transfer(alice, 300e18);
        assertEq(votesAggregator.getVotes(alice), grove.getVotes(alice) + sGrove.getVotes(alice), "sum, wallet only");
        assertEq(votesAggregator.getVotes(alice), 300e18, "wallet power");

        vm.startPrank(alice);
        grove.approve(address(sGrove), 300e18);
        sGrove.stake(300e18);
        vm.stopPrank();

        assertEq(grove.getVotes(alice), 0, "wallet leg drained");
        assertEq(sGrove.getVotes(alice), 300e18, "stake leg");
        assertEq(votesAggregator.getVotes(alice), grove.getVotes(alice) + sGrove.getVotes(alice), "sum, staked");
        assertEq(votesAggregator.getVotes(alice), 300e18, "fully-staked holder is not dead");
    }

    // ── delegation is per-source ─────────────────────────────────────────

    /// @notice `delegates` refuses to answer — there is no single honest answer.
    function test_delegates_revertsDelegateOnSource() public {
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        votesAggregator.delegates(alice);
    }

    /// @notice `delegate` refuses — delegate on each source directly.
    function test_delegate_revertsDelegateOnSource() public {
        vm.prank(alice);
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        votesAggregator.delegate(bob);
    }

    /// @notice `delegateBySig` refuses — no gasless route through the aggregator.
    function test_delegateBySig_revertsDelegateOnSource() public {
        vm.expectRevert(GroveVotesAggregator.Aggregator_DelegateOnSource.selector);
        votesAggregator.delegateBySig(bob, 0, type(uint256).max, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    /// @notice The per-source readers each return their OWN source's answer, and they
    ///         genuinely differ when an account delegates differently on each — which
    ///         is exactly why the single-answer `delegates` cannot exist.
    function test_groveAndSGroveDelegates_differPerSource() public {
        // no delegation anywhere yet
        assertEq(votesAggregator.groveDelegates(alice), address(0), "grove: undelegated");
        assertEq(votesAggregator.sGroveDelegates(alice), address(0), "sGrove: undelegated");

        // alice ends up with 150 GROVE and stakes 100 of it, so the wallet leg carries a
        // NON-ZERO residual — otherwise the GROVE-delegation half of this test would only
        // ever be asserted at zero and would prove nothing about routing.
        vm.prank(frTreasury);
        grove.transfer(alice, 50e18);
        vm.prank(alice);
        grove.delegate(bob); // wallet GROVE -> bob
        _stakeGrove(alice, 100e18); // gives alice 100 more, stakes it, self-delegates
        assertEq(grove.balanceOf(alice), 50e18, "50 GROVE left in the wallet");
        assertEq(votesAggregator.sGroveDelegates(alice), alice, "stake auto self-delegates");

        vm.prank(alice);
        sGrove.delegate(carol); // staked GROVE -> carol

        assertEq(votesAggregator.groveDelegates(alice), bob, "grove leg -> bob");
        assertEq(votesAggregator.sGroveDelegates(alice), carol, "sGrove leg -> carol");
        assertTrue(
            votesAggregator.groveDelegates(alice) != votesAggregator.sGroveDelegates(alice), "two delegations differ"
        );
        // and they mirror the sources exactly
        assertEq(votesAggregator.groveDelegates(alice), grove.delegates(alice), "mirrors GROVE");
        assertEq(votesAggregator.sGroveDelegates(alice), sGrove.delegates(alice), "mirrors sGROVE");

        // the power really did split
        vm.warp(block.timestamp + 1);
        uint256 t = block.timestamp - 1;
        assertEq(votesAggregator.getPastVotes(bob, t), 50e18, "bob carries alice's residual wallet GROVE");
        assertEq(votesAggregator.getPastVotes(carol, t), 100e18, "carol carries the stake votes");
        assertEq(votesAggregator.getPastVotes(alice, t), 0, "alice delegated everything away");
        assertEq(
            votesAggregator.getPastVotes(bob, t) + votesAggregator.getPastVotes(carol, t),
            150e18,
            "split, not duplicated: the two legs sum to alice's whole holding"
        );
    }

    /// @notice The converse of the split case, and the most natural real-world pattern:
    ///         BOTH legs delegated to the SAME account. This is where a double count would
    ///         concentrate in one delegate, so the exact-equality assertion here is the
    ///         one that would catch it.
    function test_getPastVotes_sameDelegateOnBothLegsSumsExactlyOnce() public {
        vm.prank(frTreasury);
        grove.transfer(alice, 70e18);
        vm.prank(alice);
        grove.delegate(bob); // wallet GROVE -> bob
        _stakeGrove(alice, 130e18); // gives alice 130 more, stakes it, self-delegates
        vm.prank(alice);
        sGrove.delegate(bob); // staked GROVE -> bob as well

        assertEq(votesAggregator.groveDelegates(alice), bob, "grove leg -> bob");
        assertEq(votesAggregator.sGroveDelegates(alice), bob, "sGrove leg -> bob too");
        assertEq(grove.balanceOf(alice), 70e18, "wallet leg");
        assertEq(sGrove.stakedOf(alice), 130e18, "stake leg");

        vm.warp(block.timestamp + 1);
        uint256 t = block.timestamp - 1;

        assertEq(grove.getPastVotes(bob, t), 70e18, "bob's GROVE leg");
        assertEq(sGrove.getPastVotes(bob, t), 130e18, "bob's sGROVE leg");
        // 200, NOT 400 and NOT 330 (= 200 + the 130 GROVE the backstop custodies)
        assertEq(votesAggregator.getPastVotes(bob, t), 200e18, "counted exactly once");
        assertEq(votesAggregator.getPastVotes(alice, t), 0, "alice kept nothing");
        assertEq(
            votesAggregator.getPastVotes(alice, t) + votesAggregator.getPastVotes(bob, t),
            200e18,
            "conservation: delegator + delegate together hold exactly alice's 200, no more"
        );
        assertEq(grove.getPastVotes(address(sGrove), t), 0, "custodied GROVE votes for nobody");
        assertLe(
            votesAggregator.getPastVotes(bob, t), votesAggregator.getPastTotalSupply(t), "bounded by the denominator"
        );
    }

    // ── the aggregate safety property ────────────────────────────────────

    /// @notice With mixed holdings, delegations and stakes, the sum of every delegate's
    ///         aggregate voting power never exceeds GROVE total supply — the no-double-
    ///         count guarantee that makes summing the two sources safe.
    function test_aggregateVotesNeverExceedGroveTotalSupply() public {
        // alice: 100 GROVE, wallet delegated to bob, 40 staked (auto self-delegated)
        vm.prank(frTreasury);
        grove.transfer(alice, 100e18);
        vm.prank(alice);
        grove.delegate(bob);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 40e18);
        sGrove.stake(40e18);
        vm.stopPrank();

        // bob: 200 GROVE self-delegated, 50 staked then re-delegated to carol
        vm.prank(frTreasury);
        grove.transfer(bob, 200e18);
        vm.startPrank(bob);
        grove.delegate(bob);
        grove.approve(address(sGrove), 50e18);
        sGrove.stake(50e18);
        sGrove.delegate(carol);
        vm.stopPrank();

        // carol: 50 GROVE, never delegated -> abstains entirely
        vm.prank(frTreasury);
        grove.transfer(carol, 50e18);

        vm.warp(block.timestamp + 1);
        uint256 t = block.timestamp - 1;

        uint256 supply = votesAggregator.getPastTotalSupply(t);
        assertEq(supply, Config.GROVE_INITIAL_SUPPLY, "denominator unmoved by all of that");

        uint256 treasuryVotes = votesAggregator.getPastVotes(frTreasury, t);
        uint256 aliceVotes = votesAggregator.getPastVotes(alice, t);
        uint256 bobVotes = votesAggregator.getPastVotes(bob, t);
        uint256 carolVotes = votesAggregator.getPastVotes(carol, t);

        // exact expected split (not just an inequality)
        assertEq(treasuryVotes, Config.GROVE_INITIAL_SUPPLY - 350e18, "treasury keeps the rest");
        assertEq(aliceVotes, 40e18, "alice: stake only (wallet went to bob)");
        assertEq(bobVotes, 210e18, "bob: own 150 wallet + alice's 60 wallet");
        assertEq(carolVotes, 50e18, "carol: bob's staked votes, own wallet abstains");

        uint256 total = treasuryVotes + aliceVotes + bobVotes + carolVotes;
        assertLe(total, supply, "no double count");
        assertEq(total, supply - 50e18, "exactly carol's undelegated wallet is the gap");

        // the physical accounting behind it
        assertEq(sGrove.totalVotingUnits(), 90e18, "voting units == staked GROVE");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units reconcile to stake");
        assertEq(grove.balanceOf(address(sGrove)), 90e18, "backstop custodies that GROVE");
        assertEq(grove.getPastVotes(address(sGrove), t), 0, "and votes none of it");
    }

    /// @notice Fuzzed: however the treasury splits GROVE across three actors that each
    ///         self-delegate, stake an arbitrary slice and put an arbitrary part of that
    ///         slice into unbonding, the aggregate never exceeds GROVE total supply.
    /// @dev Unbonding is the ONE path where the `sum <= supply` bound has genuine slack:
    ///      `requestUnstake` burns the voting units immediately while the GROVE itself
    ///      stays in the backstop's (undelegated) custody, so that GROVE is in the
    ///      denominator and in nobody's numerator. The exact-equality assertion pins the
    ///      size of that gap at `aUnstake`, so a bug that either kept unbonding stake
    ///      voting or destroyed extra votes shows up as a wrong number, not a satisfied
    ///      inequality.
    function testFuzz_aggregateVotesNeverExceedGroveTotalSupply(
        uint256 aGive,
        uint256 aStake,
        uint256 aUnstake,
        uint256 bGive
    ) public {
        aGive = bound(aGive, 0, 1_000_000e18);
        aStake = bound(aStake, 0, aGive);
        aUnstake = bound(aUnstake, 0, aStake);
        bGive = bound(bGive, 0, 1_000_000e18);

        vm.prank(alice);
        grove.delegate(alice);
        vm.prank(bob);
        grove.delegate(bob);

        if (aGive != 0) {
            vm.prank(frTreasury);
            grove.transfer(alice, aGive);
        }
        if (aStake != 0) {
            vm.startPrank(alice);
            grove.approve(address(sGrove), aStake);
            sGrove.stake(aStake);
            vm.stopPrank();
        }
        if (aUnstake != 0) {
            vm.prank(alice);
            sGrove.requestUnstake(aUnstake);
        }
        if (bGive != 0) {
            vm.prank(frTreasury);
            grove.transfer(bob, bGive);
        }

        vm.warp(block.timestamp + 1);
        uint256 t = block.timestamp - 1;
        uint256 supply = votesAggregator.getPastTotalSupply(t);

        assertEq(supply, Config.GROVE_INITIAL_SUPPLY, "quorum denominator is constant");
        assertEq(votesAggregator.getPastVotes(alice, t), aGive - aUnstake, "alice loses exactly the unbonding stake");
        assertEq(grove.getPastVotes(alice, t), aGive - aStake, "her wallet leg");
        assertEq(sGrove.getPastVotes(alice, t), aStake - aUnstake, "her ACTIVE stake leg");
        assertEq(votesAggregator.getPastVotes(bob, t), bGive, "bob keeps his");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units reconcile");
        assertEq(sGrove.totalStaked(), aStake - aUnstake, "active stake excludes unbonding");
        assertEq(grove.balanceOf(address(sGrove)), aStake, "but the backstop still custodies all of it");

        uint256 total = votesAggregator.getPastVotes(frTreasury, t) + votesAggregator.getPastVotes(alice, t)
            + votesAggregator.getPastVotes(bob, t) + votesAggregator.getPastVotes(carol, t)
            + votesAggregator.getPastVotes(address(sGrove), t);
        assertLe(total, supply, "no double count");
        // the gap is exactly the unbonding GROVE: custodied, undelegated, voting for nobody
        assertEq(total, supply - aUnstake, "nothing lost beyond the unbonding slice");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Asserts the aggregator's answer is the exact arithmetic sum of both legs.
    function _assertSumAt(address account, uint256 timepoint) internal view {
        assertEq(
            votesAggregator.getPastVotes(account, timepoint),
            grove.getPastVotes(account, timepoint) + sGrove.getPastVotes(account, timepoint),
            "aggregator == grove + sGrove"
        );
    }
}

// ── mocks ────────────────────────────────────────────────────────────────

/// @dev A vote source stuck on the OZ default block-number clock — the exact failure the
///      aggregator's constructor guard exists to turn into a deploy-time revert.
contract MockBlockNumberClockVotes is IERC5805 {
    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external pure {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {}
}

/// @dev A vote source reporting an arbitrary clock-mode string, to prove the guard is an
///      exact match rather than a prefix/substring check.
contract MockCustomClockVotes is IERC5805 {
    string private mode;

    constructor(string memory mode_) {
        mode = mode_;
    }

    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external view returns (string memory) {
        return mode;
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external pure {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {}
}

/// @dev A vote source that DECLARES the timestamp clock but reports a fixed, unrelated
///      `clock()` value — the "lying clock". `CLOCK_MODE()` is metadata a source can get
///      right while checkpointing on something else entirely, which is why the constructor
///      compares the live value too.
contract MockLyingClockVotes is IERC5805 {
    uint48 private reported;

    constructor(uint48 reported_) {
        reported = reported_;
    }

    function clock() external view returns (uint48) {
        return reported;
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external pure {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {}
}

/// @dev A correctly-clocked vote source that answers ANY timepoint without reverting.
///      Used as the GROVE leg so that a future-lookup revert can only have come from the
///      sGROVE leg — proving the aggregator swallows neither.
contract MockTimestampClockVotes is IERC5805 {
    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external pure {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {}
}
