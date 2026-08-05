// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";
import {Config} from "../../src/libraries/Config.sol";
import {SGroveHandler} from "./handlers/SGroveHandler.sol";

/// @dev Stateful-fuzz invariants for the sGROVE backstop (CLAUDE.md §1.3 — the
///      cascade's layer 2 must be exactly as strong as claimed, no more):
///      - GROVE CUSTODY: staked + unbonding GROVE is exactly what the contract holds —
///        no path leaks or seizes stake (ADR-0021: coverage never converts GROVE)
///      - USDFR CUSTODY: contract balance == coverage reserve + (rewards notified −
///        claimed): coverage and rewards never bleed into each other
///      - REWARD CONSERVATION: claimed + pending never exceed notified
///      - PER-EVENT CAP: asserted per fuzzed draw in the handler (differential)
///
///      Plus the ADR-0026 (L-02) GOVERNANCE properties. The spec's original phrasing
///      ("total votable == circulating delegated GROVE + staked GROVE") is FALSE as an
///      equality — a staker may `delegate(address(0))` and be staked yet votable by
///      nobody — so it is restated as four checkable properties:
///      - VOTING UNITS TRACK STAKE: `totalVotingUnits() == totalStaked()`, exactly
///      - CUSTODY STAYS UNDELEGATED: the whole no-double-count argument's precondition
///      - VOTES NEVER EXCEED SUPPLY: sum over all delegates <= GROVE total supply
///      - STAKE IS BACKED BY CUSTODY: `totalStaked() <= grove.balanceOf(sGrove)`
///      - FIRST STAKE AUTO-SELF-DELEGATES: staking CREDITS the staker (see below)
///      - VOTES == DELEGATED STAKE: exact conservation on the sGROVE leg, zero slack
///      - CLOCKS AGREE: all three governance surfaces run on the timestamp clock
///      - PAST READS: the quantities the Governor actually calls are bounded too
///      - QUORUM DENOMINATOR IS GROVE-ONLY: staking cannot move the quorum bar
///
///      REVIEW NOTE (why the last five exist). An adversarial review of the first four
///      showed all of them stayed green under a mutation that DELETED the auto-self-
///      delegation from `SGrove.stake` — every staker silently disenfranchised, which is
///      precisely the bug L-02 exists to prevent — because conservation statements are
///      symmetric: with nobody delegated, both sides of every sum collapse to zero. It
///      also showed the aggregate `<=` bound carries slack far larger than a small double
///      count, that the Governor-facing past-read path had no invariant at all, and that
///      `SGrove.clock()` could be flipped to block numbers with all eight green.
contract GovernanceInvariants is GovernanceFixture {
    SGroveHandler internal handler;

    function setUp() public override {
        super.setUp();
        // a KYC'd USDfr source for the handler's coverage/reward funding
        address funder = makeAddr("sgFunder");
        vm.prank(complianceAdmin);
        compliance.setAllowed(funder, true);
        _mintUSDfrTo(funder, 50_000_000e18);

        handler = new SGroveHandler(grove, sGrove, usdfr, frTreasury, funder, address(defaultManager), guardian);
        // Deterministic anti-vacuity floor: establishes every delegation shape (self, cross,
        // revoke, to-treasury, to-backstop) and a non-zero balance on both vote legs BEFORE
        // the campaign starts, so `afterInvariant`'s shape assertions are real assertions
        // rather than a coin flip on fuzzer luck. Forge restarts every run from this state.
        // `actors[0]` is left un-delegated on purpose — see `seedGovernanceShapes`.
        handler.seedGovernanceShapes();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = SGroveHandler.stake.selector;
        selectors[1] = SGroveHandler.requestUnstake.selector;
        selectors[2] = SGroveHandler.claimUnstake.selector;
        selectors[3] = SGroveHandler.fundCoverage.selector;
        selectors[4] = SGroveHandler.notifyRewards.selector;
        selectors[5] = SGroveHandler.claimRewards.selector;
        selectors[6] = SGroveHandler.coverShortfall.selector;
        selectors[7] = SGroveHandler.warp.selector;
        // ADR-0026 (L-02): delegation on BOTH vote sources, plus wallet-GROVE funding so
        // the GROVE leg moves non-zero votes (otherwise invariant 3 is vacuous).
        selectors[8] = SGroveHandler.delegate.selector;
        selectors[9] = SGroveHandler.delegateGrove.selector;
        selectors[10] = SGroveHandler.fundActorGrove.selector;
        // gap 9: the EIP-712 / gasless delegation path, so a domain regression on upgrade
        // is caught at invariant level and not only in the unit suite.
        selectors[11] = SGroveHandler.delegateBySig.selector;
        // gap 8: the guardian pause window, so the `whenNotPaused` false branches are
        // reached and the voting-unit accounting is shown to survive a pause.
        selectors[12] = SGroveHandler.setPaused.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (GROVE custody): the contract holds exactly the active
    ///         stakes plus unclaimed unbonds — coverage never touches GROVE.
    function invariant_sgrove_groveCustodyExact() public view {
        assertEq(sGrove.totalStaked(), handler.sumStaked(), "TOTAL STAKED != SUM OF STAKES");
        assertEq(
            grove.balanceOf(address(sGrove)),
            sGrove.totalStaked() + handler.ghostUnbondingOutstanding(),
            "GROVE CUSTODY LEAKED OR SEIZED"
        );
    }

    /// @notice INVARIANT (USDfr custody): coverage and rewards reconcile exactly and
    ///         never bleed into each other.
    function invariant_sgrove_usdfrCustodyExact() public view {
        assertEq(
            usdfr.balanceOf(address(sGrove)),
            sGrove.coverageReserve() + handler.ghostRewardsNotified() - handler.ghostRewardsClaimed(),
            "USDFR CUSTODY DRIFTED"
        );
    }

    /// @notice INVARIANT (reward conservation): stakers can never claim more than
    ///         was notified; the undistributed remainder is bounded index dust.
    function invariant_sgrove_rewardsConserve() public view {
        assertLe(
            handler.ghostRewardsClaimed() + handler.sumPendingRewards(),
            handler.ghostRewardsNotified(),
            "REWARDS OVER-DISTRIBUTED"
        );
    }

    // ── governance voting (ADR-0026 / L-02) ──────────────────────────────

    /// @notice INVARIANT (sGROVE voting units == active stake, CLAUDE.md §1.3 accounting
    ///         reconciliation): the checkpointed voting supply is exactly the actively
    ///         staked GROVE — never more, never less.
    /// @dev PRECISELY what this catches, and what it does not (corrected after review — the
    ///      earlier claim that this was "the tripwire for every ordering bug" was wrong, and
    ///      the file's own mutation evidence already disproved it):
    ///        CAUGHT — the `_transferVotingUnits` mint dropped from `stake`, or a second
    ///        burn added in `claimUnstake` (both leave units BEHIND stake); the burn dropped
    ///        from `requestUnstake` (leaves units AHEAD of stake).
    ///        NOT CAUGHT — anything that leaves the TOTAL right while misrouting it. Both
    ///        the self-delegate-after-increment ordering bug and the deletion of the
    ///        auto-self-delegation entirely leave `_getTotalSupply()` exactly equal to
    ///        `totalStaked()`; the first is caught by
    ///        `invariant_sgrove_votesEqualDelegatedStake`, the second ONLY by
    ///        `invariant_sgrove_firstStakeAutoSelfDelegates`.
    ///      Exact equality, no tolerance.
    function invariant_sgrove_votingUnitsTrackStakeExactly() public view {
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "VOTING UNITS != ACTIVE STAKE");
    }

    /// @notice INVARIANT (no double count, CLAUDE.md §1.3 backing/conservation): the GROVE
    ///         the backstop custodies is NEVER delegated, so it contributes to nobody's
    ///         balance votes and reappears exactly once as the staker's sGROVE votes.
    /// @dev The precondition the entire `GroveVotesAggregator` composition rests on. If
    ///      `SGrove` ever gained a path that delegated its own holdings, every staked GROVE
    ///      would vote twice — once through the custodian's delegate and once through the
    ///      staker — and the aggregate could exceed the token supply.
    /// @dev REVIEW FIX (gap 7): this used to also assert `grove.getVotes(sGrove) == 0`. That
    ///      is NOT a production invariant and has been removed. `GroveToken` is a standard
    ///      `ERC20Votes`; ANY holder may legally `grove.delegate(address(sGrove))`, which
    ///      gives the backstop address votes with nothing broken. The old assertion passed
    ///      only because the handler never offered the backstop as a delegation target. It
    ///      now does — and the invariant `setUp` seeds exactly that delegation permanently,
    ///      so the removed assertion is provably false in this campaign's own base state.
    ///      What remains is the real precondition: the backstop never delegates its OWN
    ///      custody, which is what would double-count the staked GROVE.
    function invariant_sgrove_custodyStaysUndelegated() public view {
        assertEq(grove.delegates(address(sGrove)), address(0), "BACKSTOP CUSTODY BECAME DELEGATED");
    }

    /// @notice INVARIANT (value conservation applied to voting power, CLAUDE.md §1.3): the
    ///         sum of aggregate voting power over every actor AND every delegate can never
    ///         exceed the GROVE total supply.
    /// @dev `<=`, never `==`: undelegated wallet GROVE, GROVE revoked to `address(0)`, and
    ///      unbonding GROVE are all votable by nobody, so the sum is legitimately short.
    ///      Delegates are deduped — several actors may point at the same delegate, and
    ///      counting that delegate twice would manufacture a false failure. This is the
    ///      invariant that catches a double count: if `SGrove.stake` self-delegated AFTER
    ///      incrementing `staked`, a staker who had revoked to `address(0)` and re-staked
    ///      would book their prior stake twice, and the sum would cross the supply.
    /// @dev NOTE ON SLACK (review): this bound is legitimately loose — `slack = undelegated
    ///      wallet GROVE + stake delegated to address(0) + unbonding GROVE` — so a double
    ///      count smaller than the concurrent slack does not cross it. It is the right
    ///      SAFETY bound, but it is not a conservation statement. The conservation statement
    ///      lives in `invariant_sgrove_votesEqualDelegatedStake`, which has zero slack.
    function invariant_votes_neverExceedGroveSupply() public view {
        (address[] memory seen, uint256 n) = _voteCandidates();
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            total += votesAggregator.getVotes(seen[i]);
        }
        assertLe(total, grove.totalSupply(), "AGGREGATE VOTES EXCEED GROVE SUPPLY (DOUBLE COUNT)");
    }

    /// @notice INVARIANT (L-02's core promise): staking CREDITS the staker. An account that
    ///         has never re-pointed its sGROVE delegate by hand, yet holds active stake,
    ///         MUST be self-delegated — because `SGrove.stake` self-delegates a staker with
    ///         no delegate on record, and nothing else in the system can have done it.
    /// @dev REVIEW FIX (gap 1 — the critical false green). Deleting
    ///      `if (delegates(msg.sender) == address(0)) _delegate(msg.sender, msg.sender);`
    ///      from `SGrove.stake` disenfranchises every staker, and left ALL eight of the
    ///      original invariants green at 32,768 calls: every conservation statement is
    ///      symmetric, so with nobody delegated both sides collapse to zero and balance.
    ///      Only an asymmetric claim — "this account MUST have a delegate" — bites, and it
    ///      needs the handler's `everDelegated` ghost to know the delegate was not set by
    ///      hand. `actors[0]` is seeded with stake and never hand-delegated, so this
    ///      invariant has teeth from the base state of every run.
    ///
    ///      The vote check is `>=`, not `==`, on purpose and it is not a weakening: other
    ///      actors may legally delegate their stake INTO this account, which only adds. The
    ///      exact per-delegate equality is asserted in
    ///      `invariant_sgrove_votesEqualDelegatedStake`; here the load-bearing claim is that
    ///      the staker's own stake is represented at all.
    function invariant_sgrove_firstStakeAutoSelfDelegates() public view {
        address[] memory list = handler.actorList();
        for (uint256 i = 0; i < list.length; ++i) {
            address a = list[i];
            if (handler.everDelegated(a)) continue; // delegate was set by hand; nothing to infer
            if (sGrove.stakedOf(a) == 0) continue; // never staked; no claim
            assertEq(sGrove.delegates(a), a, "AUTO SELF-DELEGATION LOST (STAKER DISENFRANCHISED)");
            assertGe(sGrove.getVotes(a), sGrove.stakedOf(a), "STAKER VOTES DO NOT COVER OWN ACTIVE STAKE");
        }
    }

    /// @notice INVARIANT (exact value conservation on the sGROVE leg, CLAUDE.md §1.3): the
    ///         voting power the backstop hands out equals, to the wei, the active stake that
    ///         has a delegate — no more (double count) and no less (lost votes), and every
    ///         wei is credited to the RIGHT account.
    /// @dev REVIEW FIX (gap 2). `invariant_votes_neverExceedGroveSupply` is a `<=` with
    ///      slack that routinely exceeds the staked total; the self-delegate-after-increment
    ///      mutation cleared it by only 0.009% of supply, so a smaller double count would be
    ///      invisible. This is the zero-slack statement. The sGROVE voting-unit holders are
    ///      exactly the handler's three actors (nothing else in the fixture ever stakes), so
    ///      the delegation graph is fully enumerable and the per-delegate expected value is
    ///      computable exactly.
    ///
    ///      Two assertions, deliberately: the per-candidate one catches units credited to
    ///      the WRONG account even when the total happens to balance; the total one catches
    ///      units credited to an account outside the enumerated set.
    function invariant_sgrove_votesEqualDelegatedStake() public view {
        (address[] memory seen, uint256 n) = _voteCandidates();
        address[] memory list = handler.actorList();

        uint256 counted;
        for (uint256 i = 0; i < n; ++i) {
            uint256 expected;
            for (uint256 j = 0; j < list.length; ++j) {
                if (sGrove.delegates(list[j]) == seen[i]) expected += sGrove.stakedOf(list[j]);
            }
            uint256 actual = sGrove.getVotes(seen[i]);
            assertEq(actual, expected, "sGROVE VOTES CREDITED TO THE WRONG ACCOUNT");
            counted += actual;
        }

        uint256 votable;
        for (uint256 j = 0; j < list.length; ++j) {
            // a staker delegated to address(0) is staked but votable by nobody
            if (sGrove.delegates(list[j]) != address(0)) votable += sGrove.stakedOf(list[j]);
        }
        assertEq(counted, votable, "sGROVE VOTES != DELEGATED ACTIVE STAKE");
    }

    /// @notice INVARIANT (EIP-6372): all three governance surfaces run on, and declare, the
    ///         same timestamp clock, in every reachable state.
    /// @dev REVIEW FIX (gap 3). `GovernorVotes.clock()` and `CLOCK_MODE()` each wrap the
    ///      token call in try/catch and FALL BACK TO BLOCK NUMBERS silently, so a `SGrove`
    ///      that checkpointed in block numbers while GROVE checkpointed in timestamps would
    ///      surface only as every voter reading ~0 votes — with every other check green.
    ///      Flipping `SGrove.clock()` to `block.number` left all eight original invariants
    ///      passing. This makes that mutation loud. Both halves are pinned: the declared
    ///      mode string (what tooling and `Validate.s.sol` read) and the live value (what the
    ///      checkpoint keys are actually made of).
    function invariant_governance_clocksAgree() public view {
        assertEq(uint256(sGrove.clock()), block.timestamp, "SGROVE NOT ON THE TIMESTAMP CLOCK");
        assertEq(uint256(grove.clock()), block.timestamp, "GROVE NOT ON THE TIMESTAMP CLOCK");
        assertEq(uint256(votesAggregator.clock()), block.timestamp, "AGGREGATOR NOT ON THE TIMESTAMP CLOCK");
        assertEq(sGrove.CLOCK_MODE(), "mode=timestamp", "SGROVE CLOCK_MODE DRIFT");
        assertEq(grove.CLOCK_MODE(), "mode=timestamp", "GROVE CLOCK_MODE DRIFT");
        assertEq(votesAggregator.CLOCK_MODE(), "mode=timestamp", "AGGREGATOR CLOCK_MODE DRIFT");
    }

    /// @notice INVARIANT (the quantities the Governor actually reads): aggregate PAST voting
    ///         power at a past timepoint never exceeds the PAST total supply at that same
    ///         timepoint.
    /// @dev REVIEW FIX (gap 4). Every other votes invariant here reads `getVotes`, which
    ///      `FRGovernor` never calls — the Governor reads `getPastVotes` against
    ///      `getPastTotalSupply`. This walks the checkpoint arrays instead of the live
    ///      totals, so a checkpoint-keying bug (wrong clock unit, checkpoint written at the
    ///      wrong timepoint) shows up here even when the live reads reconcile.
    ///      The candidate set is built from CURRENT delegates: an account that was a
    ///      delegate at `t` but is not one now would be omitted, which can only make the sum
    ///      smaller, so the `<=` direction is still sound.
    function invariant_votes_pastReadsNeverExceedPastSupply() public view {
        if (block.timestamp == 0) return; // no past timepoint exists yet
        uint256 t = block.timestamp - 1;
        (address[] memory seen, uint256 n) = _voteCandidates();
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            total += votesAggregator.getPastVotes(seen[i], t);
        }
        assertLe(total, votesAggregator.getPastTotalSupply(t), "PAST AGGREGATE VOTES EXCEED PAST SUPPLY");
    }

    /// @notice INVARIANT (ADR-0026 composition rule, differential): the aggregator's answer
    ///         is the SUM of both legs, present and past, for every account — it never drops
    ///         a leg and never counts one twice.
    /// @dev The `<=` bound above cannot see a DROPPED leg: losing every staker's votes makes
    ///      the sum smaller, which satisfies the bound. That failure mode is the whole point
    ///      of L-02 (a staker who is silently unrepresented at the Governor), so it needs an
    ///      equality. This is a reference-model check in the CLAUDE.md §1.5 sense: the
    ///      expected value is computed independently from the two sources the ADR names, and
    ///      the immutable aggregator exists precisely to freeze this rule.
    function invariant_votes_aggregatorComposesBothLegs() public view {
        (address[] memory seen, uint256 n) = _voteCandidates();
        uint256 t = block.timestamp == 0 ? 0 : block.timestamp - 1;
        for (uint256 i = 0; i < n; ++i) {
            address c = seen[i];
            assertEq(
                votesAggregator.getVotes(c), grove.getVotes(c) + sGrove.getVotes(c), "AGGREGATOR DROPPED A VOTE LEG"
            );
            if (block.timestamp == 0) continue;
            assertEq(
                votesAggregator.getPastVotes(c, t),
                grove.getPastVotes(c, t) + sGrove.getPastVotes(c, t),
                "AGGREGATOR DROPPED A VOTE LEG ON THE PAST READ"
            );
        }
    }

    /// @notice INVARIANT (ADR-0026 quorum design): the quorum denominator is GROVE's total
    ///         supply ALONE, and no reachable sequence of staking, unstaking or delegation
    ///         moves it.
    /// @dev REVIEW FIX (gap 5). Summing the two supplies would inflate the denominator and
    ///      silently raise the quorum bar for everyone — and be actively exploitable: a
    ///      whale could stake immediately before a proposal snapshot purely to raise the
    ///      denominator and block a proposal it opposed, then unbond. The unit suite pins
    ///      the static case; only an invariant pins "no reachable sequence moves it".
    ///      `GroveToken` mints once at genesis and has no mint or burn path, so the constant
    ///      is `GROVE_INITIAL_SUPPLY` exactly.
    function invariant_quorumDenominatorIsGroveOnly() public view {
        if (block.timestamp == 0) return;
        uint256 t = block.timestamp - 1;
        assertEq(
            votesAggregator.getPastTotalSupply(t), grove.getPastTotalSupply(t), "QUORUM DENOMINATOR IS NOT GROVE-ONLY"
        );
        assertEq(
            votesAggregator.getPastTotalSupply(t), Config.GROVE_INITIAL_SUPPLY, "STAKING MOVED THE QUORUM DENOMINATOR"
        );
    }

    /// @notice INVARIANT (stake is backed by real custody, CLAUDE.md §1.3 backing): every
    ///         unit of voting-eligible stake is a GROVE the backstop actually holds.
    /// @dev Weaker than `invariant_sgrove_groveCustodyExact` by design — it survives any
    ///      future donation/unbonding accounting change and states the one-directional
    ///      solvency claim the vote weighting depends on.
    /// @dev REVIEW NOTE (gap 10): honestly, this is STRICTLY DOMINATED by
    ///      `invariant_sgrove_groveCustodyExact` (an equality whose other addend is
    ///      non-negative) and cannot fail independently of it today. Kept deliberately as
    ///      the standalone statement of the solvency claim, not counted as a distinct
    ///      property; if the custody equality is ever relaxed, this is what must survive.
    function invariant_sgrove_stakeIsBackedByCustody() public view {
        assertLe(sGrove.totalStaked(), grove.balanceOf(address(sGrove)), "STAKE EXCEEDS CUSTODIED GROVE");
    }

    /// @notice Call-summary LOGGING. Not a guard — see `afterInvariant`.
    /// @dev REVIEW FIX (gap 6). This function used to be one of the eight "passing tests"
    ///      while consisting of nothing but `console2.log`: it could not fail, yet its own
    ///      NatSpec presented it as the anti-vacuity mechanism, and a real campaign was
    ///      observed in which sGROVE self-delegations were 0 and everything stayed green.
    ///      The load-bearing checks now live in `afterInvariant()` as assertions. This stays
    ///      as what it always actually was: a readout. The seed in `setUp` contributes a
    ///      fixed floor to these counters (5 sGROVE delegations, 2 GROVE delegations,
    ///      300_000e18 wallet GROVE); anything above that floor is fuzzer-driven.
    function invariant_callSummary() public view {
        console2.log("calls                    ", handler.callCount());
        console2.log("sGROVE delegate calls    ", handler.ghostSGroveDelegateCalls());
        console2.log("  self / cross / revoke  ", handler.ghostSGroveSelfDelegations());
        console2.log("                         ", handler.ghostSGroveCrossDelegations());
        console2.log("                         ", handler.ghostSGroveNullDelegations());
        console2.log("  -> backstop / treasury ", handler.ghostSGroveToBackstop());
        console2.log("                         ", handler.ghostSGroveToTreasury());
        console2.log("  of which delegateBySig ", handler.ghostDelegateBySigCalls());
        console2.log("GROVE delegate calls     ", handler.ghostGroveDelegateCalls());
        console2.log("  self / cross / revoke  ", handler.ghostGroveSelfDelegations());
        console2.log("                         ", handler.ghostGroveCrossDelegations());
        console2.log("                         ", handler.ghostGroveNullDelegations());
        console2.log("  -> backstop / treasury ", handler.ghostGroveToBackstop());
        console2.log("                         ", handler.ghostGroveToTreasury());
        console2.log("wallet GROVE funded      ", handler.ghostActorGroveFunded());
        console2.log("max actor aggregate votes", handler.ghostMaxActorAggregateVotes());
        console2.log("max GROVE-leg votes      ", handler.ghostMaxGroveLegVotes());
        console2.log("max sGROVE-leg votes     ", handler.ghostMaxSGroveLegVotes());
        console2.log("guardian pause toggles   ", handler.ghostPauseToggles());
    }

    /// @notice ANTI-VACUITY, asserted. Runs once at the end of every invariant run.
    /// @dev REVIEW FIX (gap 6). These are the checks `invariant_callSummary` claimed to be
    ///      making and never made. They are assertions, so a campaign in which the
    ///      delegation shapes were never reached — which would make the conservation
    ///      invariants trivially true — FAILS instead of passing quietly.
    ///
    ///      Deliberate design point, stated plainly so it is not mistaken for something
    ///      stronger: these counters have a floor established by `seedGovernanceShapes` in
    ///      `setUp`, and forge restarts every run from that state, so they are deterministic
    ///      rather than dependent on fuzzer luck. That is the point — asserting on raw
    ///      fuzzer luck is flaky (at `lite` depth 32 about 5% of runs never emit a single
    ///      sGROVE self-delegation). What these therefore guarantee is that every run was
    ///      evaluated against a state in which all five delegation shapes exist and BOTH
    ///      vote legs carry non-zero power. The fuzz-driven counts above that floor are
    ///      reported by `invariant_callSummary` for the reviewer to read.
    function afterInvariant() public view {
        assertGt(handler.callCount(), 0, "NO HANDLER ACTION EXECUTED (selector wiring broken)");
        assertGt(handler.ghostSGroveDelegateCalls(), 0, "sGROVE DELEGATION NEVER EXERCISED");
        assertGt(handler.ghostSGroveSelfDelegations(), 0, "sGROVE SELF-DELEGATION SHAPE NEVER REACHED");
        assertGt(handler.ghostSGroveCrossDelegations(), 0, "sGROVE CROSS-DELEGATION SHAPE NEVER REACHED");
        assertGt(handler.ghostSGroveNullDelegations(), 0, "sGROVE REVOCATION SHAPE NEVER REACHED");
        assertGt(handler.ghostSGroveToBackstop(), 0, "DELEGATION TO THE BACKSTOP NEVER EXPLORED");
        assertGt(handler.ghostSGroveToTreasury(), 0, "DELEGATION TO A NON-STAKING THIRD PARTY NEVER EXPLORED");
        assertGt(handler.ghostGroveDelegateCalls(), 0, "GROVE DELEGATION NEVER EXERCISED");
        assertGt(handler.ghostGroveToBackstop(), 0, "WALLET GROVE DELEGATED TO THE BACKSTOP NEVER EXPLORED");
        assertGt(handler.ghostActorGroveFunded(), 0, "WALLET-GROVE LEG NEVER FUNDED (GROVE LEG VACUOUS)");
        assertGt(handler.ghostMaxActorAggregateVotes(), 0, "VOTES INVARIANT WAS VACUOUS (0 <= supply)");
        assertGt(handler.ghostMaxGroveLegVotes(), 0, "GROVE LEG NEVER CARRIED A VOTE");
        assertGt(handler.ghostMaxSGroveLegVotes(), 0, "sGROVE LEG NEVER CARRIED A VOTE");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev The complete, deduped set of addresses that can hold voting power in this
    ///      campaign: the actors, each actor's GROVE and sGROVE delegate, the Forest Road
    ///      treasury and the backstop itself. Completeness matters — the conservation
    ///      invariants are only sound if no vote-holding account is left out — and it holds
    ///      because voting power can only sit with a current delegate of an actor, with the
    ///      treasury (the genesis holder), or with the backstop.
    function _voteCandidates() private view returns (address[] memory seen, uint256 n) {
        address[] memory list = handler.actorList();
        seen = new address[](list.length * 3 + 2);
        n = _addCandidate(seen, n, frTreasury);
        n = _addCandidate(seen, n, address(sGrove));
        for (uint256 i = 0; i < list.length; ++i) {
            n = _addCandidate(seen, n, list[i]);
            n = _addCandidate(seen, n, votesAggregator.groveDelegates(list[i]));
            n = _addCandidate(seen, n, votesAggregator.sGroveDelegates(list[i]));
        }
    }

    /// @dev Appends `who` to `seen` unless it is the zero address or already present.
    ///      Deduping is load-bearing: `getVotes` is per-delegate, so a delegate shared by
    ///      two actors would otherwise be summed twice and could exceed the supply for a
    ///      reason that is not a bug.
    function _addCandidate(address[] memory seen, uint256 n, address who) private pure returns (uint256) {
        if (who == address(0)) return n;
        for (uint256 i = 0; i < n; ++i) {
            if (seen[i] == who) return n;
        }
        seen[n] = who;
        return n + 1;
    }
}
