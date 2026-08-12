// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import {SGrove} from "../../src/SGrove.sol";
import {Config} from "../../src/libraries/Config.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @dev Storage-layout-identical harness: it adds ONE view over OZ's internal
///      `_numCheckpoints` and no state of its own. Tests upgrade the live proxy to this
///      (the fixture gives `admin` UPGRADER_ROLE) at the point they need to assert HOW
///      MANY checkpoints a write produced — the same-timestamp collapse and "a reverted
///      call writes no checkpoint" are not observable through the public API otherwise.
contract SGroveCheckpointHarness is SGrove {
    function numCheckpointsOf(address account) external view returns (uint32) {
        return _numCheckpoints(account);
    }
}

/// @title SGroveVotes — unit suite for the staked-GROVE voting half (ADR-0026, L-02)
/// @notice Every test here pins ONE property of the `VotesUpgradeable` integration in
///         `SGrove`. The load-bearing ones are the double-count tests, and the ordering
///         they guard is reachable on exactly two paths — the paths where `stake` takes
///         its auto-self-delegate branch, i.e. where `delegates(msg.sender)` is still
///         `address(0)`:
///           1. the FIRST stake — `test_stake_mintsVotingUnitsAndAutoSelfDelegates`
///              (prior balance 0, so a wrong ordering doubles: 2000e18 for a 1000e18 stake);
///           2. a re-stake after `delegate(address(0))` —
///              `test_stake_afterDelegatingToZero_reStakeCountsExactlyOnce`
///              (prior balance NON-zero, so a wrong ordering yields 200e18 instead of 150e18).
///         Those two are the ordering guards. A second stake by an already-delegated
///         staker CANNOT expose the ordering (the guard short-circuits and `_delegate` is
///         never called), so `test_stake_secondStakeDoesNotReDelegateAndDoesNotDoubleCount`
///         earns its place for a different reason: its log scan is the only assertion on
///         the pure stake path that catches REMOVAL of the guard, which is otherwise
///         value-invisible there.
contract SGroveVotesTest is GovernanceFixture {
    /// @dev keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)")
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant DELEGATE_CHANGED_TOPIC = keccak256("DelegateChanged(address,address,address)");

    uint256 internal constant EVENT_1 = 1;

    /// @dev Number of checkpoints written for `account`, via a code-identical harness
    ///      implementation (see `SGroveCheckpointHarness`). Upgrading is a read trick, not
    ///      part of the property under test: the harness adds no state and overrides no
    ///      behaviour, so everything asserted after this call is the same code path.
    function _checkpointCount(address account) internal returns (uint32) {
        // deploy FIRST: `vm.prank` applies to the next call OR create, and the CREATE
        // would otherwise eat the prank and leave the upgrade unauthorized.
        address impl = address(new SGroveCheckpointHarness());
        vm.prank(admin);
        sGrove.upgradeToAndCall(impl, "");
        return SGroveCheckpointHarness(address(sGrove)).numCheckpointsOf(account);
    }

    // ── stake mints voting units ─────────────────────────────────────────

    /// @dev A first stake checkpoints the stake as voting units AND auto-self-delegates,
    ///      so a staker never has to send a second transaction to be enfranchised.
    function test_stake_mintsVotingUnitsAndAutoSelfDelegates() public {
        assertEq(sGrove.delegates(alice), address(0), "no delegate before the first stake");
        assertEq(sGrove.getVotes(alice), 0);
        assertEq(sGrove.totalVotingUnits(), 0);

        vm.prank(frTreasury);
        grove.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 1_000e18);
        // _delegate fires first (old balance is 0, so no DelegateVotesChanged from it),
        // then _transferVotingUnits mints the units to the fresh self-delegation.
        vm.expectEmit(true, true, true, false, address(sGrove));
        emit IVotes.DelegateChanged(alice, address(0), alice);
        vm.expectEmit(true, false, false, true, address(sGrove));
        emit IVotes.DelegateVotesChanged(alice, 0, 1_000e18);
        vm.expectEmit(true, false, false, true, address(sGrove));
        emit SGrove.Staked(alice, 1_000e18);
        sGrove.stake(1_000e18);
        vm.stopPrank();

        assertEq(sGrove.delegates(alice), alice, "auto self-delegated on the first stake");
        assertEq(sGrove.getVotes(alice), 1_000e18, "voting units == active stake");
        assertEq(sGrove.totalVotingUnits(), 1_000e18);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "totalVotingUnits == totalStaked");
        assertEq(sGrove.stakedOf(alice), 1_000e18);
    }

    /// @dev The GUARD-EXISTENCE test. `stake` self-delegates only when the staker has NO
    ///      delegate on record, so a second stake by an already-self-delegated staker must
    ///      skip `_delegate` entirely: no `DelegateChanged`, and the increment booked once.
    ///
    ///      Be precise about what this does and does NOT pin. It does NOT pin the
    ///      `_delegate`-before-increment ORDERING: on this path `delegates(alice) == alice`,
    ///      so the guard short-circuits and `_delegate` is unreachable — mutating the
    ///      ordering leaves this path at exactly 150e18 either way. (Verified empirically;
    ///      the ordering guards are tests 1 and 3, see the contract NatSpec.) What it DOES
    ///      pin is that the guard is still there at all: dropping `if (delegates(...) ==
    ///      address(0))` and self-delegating unconditionally is value-invisible on THIS
    ///      path — OZ's `_moveDelegateVotes` no-ops when `from == to` — so the
    ///      `getRecordedLogs` scan below is the only assertion here that catches it.
    ///      (Elsewhere the same mutant is caught indirectly, because unconditional
    ///      self-delegation CLOBBERS an explicit delegation: verified, it also fails
    ///      `test_delegate_movesStakeAndCreditsDelegateOnLaterStakes`,
    ///      `test_pause_freezesElectorateButNotDelegationOrReads` and the log scan in
    ///      `test_stake_afterFullExit_reusesTheSurvivingDelegateRecordExactly`.)
    function test_stake_secondStakeDoesNotReDelegateAndDoesNotDoubleCount() public {
        _stakeGrove(alice, 100e18);
        assertEq(sGrove.getVotes(alice), 100e18);

        vm.prank(frTreasury);
        grove.transfer(alice, 50e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 50e18);
        vm.recordLogs();
        sGrove.stake(50e18);
        vm.stopPrank();

        // The scan is only meaningful if it actually saw sGROVE logs — without the
        // positive assertion, a recording that captured nothing would pass vacuously.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSGroveLog;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(sGrove)) {
                sawSGroveLog = true;
                assertTrue(logs[i].topics[0] != DELEGATE_CHANGED_TOPIC, "second stake must not re-delegate");
            }
        }
        assertTrue(sawSGroveLog, "the log scan must not be vacuous: sGROVE did emit (Staked, DelegateVotesChanged)");

        assertEq(sGrove.delegates(alice), alice, "delegate unchanged");
        assertEq(sGrove.getVotes(alice), 150e18, "votes == 100 + 50 exactly, never 250");
        assertEq(sGrove.totalVotingUnits(), 150e18, "supply of voting units booked once");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(sGrove.stakedOf(alice), 150e18);
    }

    /// @dev The branch where a wrong ordering silently double counts to 200: delegating to
    ///      `address(0)` clears the delegate on record (votes drop to 0, but the voting
    ///      UNITS are still checkpointed in the total supply), so the NEXT stake takes the
    ///      auto-self-delegate branch again with a NON-ZERO prior balance. `_delegate` must
    ///      move only the OLD 100; `_transferVotingUnits` then adds only the new 50.
    function test_stake_afterDelegatingToZero_reStakeCountsExactlyOnce() public {
        _stakeGrove(alice, 100e18);

        vm.prank(alice);
        sGrove.delegate(address(0));
        assertEq(sGrove.delegates(alice), address(0), "delegate cleared");
        assertEq(sGrove.getVotes(alice), 0, "votes parked: nobody holds them");
        assertEq(sGrove.totalVotingUnits(), 100e18, "units stay checkpointed in the supply");
        assertEq(sGrove.totalStaked(), 100e18, "the stake itself is untouched");

        vm.prank(frTreasury);
        grove.transfer(alice, 50e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 50e18);
        // re-self-delegation happens because `delegates(alice) == address(0)` again
        vm.expectEmit(true, true, true, false, address(sGrove));
        emit IVotes.DelegateChanged(alice, address(0), alice);
        sGrove.stake(50e18);
        vm.stopPrank();

        assertEq(sGrove.delegates(alice), alice, "re-self-delegated");
        assertEq(sGrove.getVotes(alice), 150e18, "exactly 150: a wrong ordering yields 200");
        assertEq(sGrove.totalVotingUnits(), 150e18);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
    }

    /// @dev The OTHER zero-stake re-entry: a FULL exit leaves `staked == 0` but the
    ///      delegate record on file (`delegates(alice) == alice`), so the re-stake must
    ///      SKIP the auto-self-delegate branch and reuse the surviving record. The exact
    ///      value is what matters: 70e18, never 140e18, and never 0 (which is what a
    ///      "clear the delegate on full exit" implementation would strand the returning
    ///      staker with until they sent a second transaction).
    function test_stake_afterFullExit_reusesTheSurvivingDelegateRecordExactly() public {
        _stakeGrove(alice, 100e18);
        vm.prank(alice);
        sGrove.requestUnstake(100e18);
        assertEq(sGrove.stakedOf(alice), 0, "fully exited");
        assertEq(sGrove.getVotes(alice), 0);
        assertEq(sGrove.delegates(alice), alice, "but the delegate record survives");

        vm.prank(frTreasury);
        grove.transfer(alice, 70e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 70e18);
        vm.recordLogs();
        sGrove.stake(70e18);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSGroveLog;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(sGrove)) {
                sawSGroveLog = true;
                assertTrue(logs[i].topics[0] != DELEGATE_CHANGED_TOPIC, "the surviving record is reused, not rewritten");
            }
        }
        assertTrue(sawSGroveLog, "the log scan must not be vacuous");

        assertEq(sGrove.delegates(alice), alice, "still self-delegated");
        assertEq(sGrove.getVotes(alice), 70e18, "exactly the re-staked amount, enfranchised immediately");
        assertEq(sGrove.totalVotingUnits(), 70e18);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(sGrove.stakedOf(alice), 70e18);
    }

    /// @dev A call that REVERTS must move no governance weight and push no checkpoint —
    ///      the revert paths themselves are covered in `SGrove.t.sol`, this pins that the
    ///      voting half is left untouched (state is rolled back, and no checkpoint is
    ///      written at the current timepoint that a later `getPastVotes` could read).
    function test_revertedStakeAndUnstake_moveNoVotingUnits() public {
        _stakeGrove(alice, 100e18);
        uint32 checkpointsBefore = _checkpointCount(alice);
        assertEq(checkpointsBefore, 1, "the stake wrote exactly one checkpoint");

        vm.prank(alice);
        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.stake(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SGrove.SGrove_InsufficientStake.selector, 100e18 + 1, 100e18));
        sGrove.requestUnstake(100e18 + 1);

        vm.prank(alice);
        vm.expectRevert(SGrove.SGrove_ZeroAmount.selector);
        sGrove.requestUnstake(0);

        assertEq(sGrove.getVotes(alice), 100e18, "votes unchanged by the reverted calls");
        assertEq(sGrove.totalVotingUnits(), 100e18, "unit supply unchanged");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(sGrove.stakedOf(alice), 100e18);
        assertEq(_checkpointCount(alice), checkpointsBefore, "no checkpoint written by a reverted call");
        assertEq(sGrove.delegates(alice), alice, "delegate record unchanged");
    }

    /// @dev An explicit delegation moves the WHOLE active stake, and every later stake by
    ///      the delegator credits the delegate — not the delegator.
    function test_delegate_movesStakeAndCreditsDelegateOnLaterStakes() public {
        _stakeGrove(alice, 100e18);

        vm.expectEmit(true, true, true, false, address(sGrove));
        emit IVotes.DelegateChanged(alice, alice, bob);
        vm.prank(alice);
        sGrove.delegate(bob);
        assertEq(sGrove.getVotes(alice), 0, "delegator keeps none");
        assertEq(sGrove.getVotes(bob), 100e18, "delegate holds the full stake");
        assertEq(sGrove.totalVotingUnits(), 100e18, "delegation never changes the supply");

        vm.prank(frTreasury);
        grove.transfer(alice, 40e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 40e18);
        sGrove.stake(40e18);
        vm.stopPrank();

        assertEq(sGrove.delegates(alice), bob, "still delegated to bob");
        assertEq(sGrove.getVotes(alice), 0, "the later stake does NOT credit alice");
        assertEq(sGrove.getVotes(bob), 140e18, "the later stake credits bob");
        assertEq(sGrove.totalVotingUnits(), 140e18);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
    }

    // ── unbonding does not vote ──────────────────────────────────────────

    /// @dev `requestUnstake` burns the voting units in the same call — an exiting staker
    ///      loses governance weight the instant they queue, not 21 days later. The
    ///      unbonding amount then votes for NOBODY.
    function test_requestUnstake_burnsVotesImmediatelyPartialAndFull() public {
        _stakeGrove(alice, 1_000e18);

        vm.expectEmit(true, false, false, true, address(sGrove));
        emit IVotes.DelegateVotesChanged(alice, 1_000e18, 600e18);
        vm.prank(alice);
        sGrove.requestUnstake(400e18);
        assertEq(sGrove.getVotes(alice), 600e18, "partial unbond burns exactly the requested amount");
        assertEq(sGrove.totalVotingUnits(), 600e18, "the 400 unbonding votes for nobody");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());

        vm.expectEmit(true, false, false, true, address(sGrove));
        emit IVotes.DelegateVotesChanged(alice, 600e18, 0);
        vm.prank(alice);
        sGrove.requestUnstake(600e18);
        assertEq(sGrove.getVotes(alice), 0, "full unbond leaves no weight");
        assertEq(sGrove.totalVotingUnits(), 0, "the whole position votes for nobody");
        assertEq(sGrove.totalStaked(), 0);
        assertEq(sGrove.delegates(alice), alice, "the delegate record survives a full exit");
    }

    /// @dev Unbonding stake must not vote through the delegate either.
    function test_requestUnstake_burnsFromTheDelegateNotTheDelegator() public {
        _stakeGrove(alice, 500e18);
        vm.prank(alice);
        sGrove.delegate(bob);
        assertEq(sGrove.getVotes(bob), 500e18);

        vm.prank(alice);
        sGrove.requestUnstake(200e18);
        assertEq(sGrove.getVotes(bob), 300e18, "the delegate loses the unbonding weight");
        assertEq(sGrove.getVotes(alice), 0);
        assertEq(sGrove.totalVotingUnits(), 300e18);
    }

    /// @dev The ABSTAINING staker's exit. With `delegates(alice) == address(0)` nobody
    ///      holds alice's weight, yet her units are still checkpointed in the total supply.
    ///      `_transferVotingUnits(alice, address(0), amt)` must burn from the SUPPLY while
    ///      `_moveDelegateVotes(address(0), address(0), amt)` no-ops. An implementation
    ///      that decremented the delegator's own checkpoint instead would underflow here
    ///      and permanently strand an abstaining staker's exit.
    function test_requestUnstake_whileAbstaining_burnsSupplyAndCannotUnderflow() public {
        _stakeGrove(alice, 100e18);
        vm.prank(alice);
        sGrove.delegate(address(0));
        assertEq(sGrove.delegates(alice), address(0), "abstaining");
        assertEq(sGrove.getVotes(alice), 0, "nobody holds the weight");
        assertEq(sGrove.totalVotingUnits(), 100e18, "but the units are still in the supply");

        vm.prank(alice);
        uint256 id = sGrove.requestUnstake(40e18);

        assertEq(sGrove.getVotes(alice), 0, "still nobody holds it");
        assertEq(sGrove.totalVotingUnits(), 60e18, "the supply burned exactly the unbonded amount");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(sGrove.stakedOf(alice), 60e18);
        assertEq(sGrove.delegates(alice), address(0), "unbonding does not re-enfranchise");

        // and the exit completes: the GROVE really comes back
        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(alice);
        sGrove.claimUnstake(id);
        assertEq(grove.balanceOf(alice), 40e18, "the abstaining staker's exit is not stranded");
        assertEq(sGrove.totalVotingUnits(), 60e18, "claim is still vote-neutral while abstaining");
    }

    /// @dev Delegating AFTER queueing an exit must move only the ACTIVE stake — the
    ///      unbonding 40 is already burned and must not reappear in the delegate's hands.
    ///      (Guards the mutant where `_delegate` moves the pre-unbond balance.)
    function test_requestUnstake_thenDelegate_movesOnlyActiveStake() public {
        _stakeGrove(alice, 100e18);
        vm.prank(alice);
        sGrove.requestUnstake(40e18);
        assertEq(sGrove.getVotes(alice), 60e18, "alice holds only the active stake");

        vm.prank(alice);
        sGrove.delegate(bob);

        assertEq(sGrove.getVotes(alice), 0, "delegator keeps none");
        assertEq(sGrove.getVotes(bob), 60e18, "the delegate gets the ACTIVE 60, never the pre-unbond 100");
        assertEq(sGrove.totalVotingUnits(), 60e18, "delegation never changes the supply");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
    }

    /// @dev `claimUnstake` is vote-neutral: the units were already burned at request time,
    ///      so touching them again would double-burn (and underflow) or double-credit.
    function test_claimUnstake_isVoteNeutral() public {
        _stakeGrove(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = sGrove.requestUnstake(400e18);

        uint256 votesBefore = sGrove.getVotes(alice);
        uint256 supplyBefore = sGrove.totalVotingUnits();
        assertEq(votesBefore, 600e18);
        assertEq(supplyBefore, 600e18);

        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(alice);
        sGrove.claimUnstake(id);

        assertEq(sGrove.getVotes(alice), votesBefore, "claim changes no vote balance");
        assertEq(sGrove.totalVotingUnits(), supplyBefore, "claim changes no voting-unit supply");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(grove.balanceOf(alice), 400e18, "the GROVE did come back");
    }

    // ── checkpoint history ───────────────────────────────────────────────

    /// @dev Historical lookups are what the Governor actually calls. A timepoint between
    ///      two stakes must read the EARLIER value, and a timepoint before the first stake
    ///      must read zero.
    function test_getPastVotes_readsTheCheckpointHistory() public {
        uint256 t0 = block.timestamp;
        _stakeGrove(alice, 100e18);
        uint256 t1 = block.timestamp;

        vm.warp(t1 + 1_000);
        vm.prank(frTreasury);
        grove.transfer(alice, 50e18);
        vm.startPrank(alice);
        grove.approve(address(sGrove), 50e18);
        sGrove.stake(50e18);
        vm.stopPrank();
        uint256 t2 = block.timestamp;

        vm.warp(t2 + 1_000);

        assertEq(sGrove.getPastVotes(alice, t0 - 1), 0, "no votes before the first stake");
        assertEq(sGrove.getPastVotes(alice, t1), 100e18, "at T1: the first stake only");
        assertEq(sGrove.getPastVotes(alice, t1 + 500), 100e18, "between T1 and T2: still the T1 value");
        assertEq(sGrove.getPastVotes(alice, t2 - 1), 100e18, "one second before T2: still the T1 value");
        assertEq(sGrove.getPastVotes(alice, t2), 150e18, "at T2: both stakes");
        assertEq(sGrove.getPastTotalSupply(t1 + 500), 100e18, "the unit supply is checkpointed too");
        assertEq(sGrove.getPastTotalSupply(t2), 150e18);
    }

    /// @dev Two stakes in the SAME timestamp. Under `mode=timestamp` two transactions in
    ///      one block share a checkpoint KEY, so `Checkpoints` must UPDATE the existing
    ///      checkpoint in place rather than push a second one — and a later
    ///      `getPastVotes(alice, t)` must read the COLLAPSED final value (150e18), not the
    ///      intermediate 100e18. This is the normal case in production (a staker topping up
    ///      twice in one block), yet every other history test here warps between stakes.
    function test_getPastVotes_twoStakesInOneTimestampCollapseToOneCheckpoint() public {
        uint256 t = block.timestamp;
        _stakeGrove(alice, 100e18);
        _stakeGrove(alice, 50e18); // same block: the helper never warps
        assertEq(block.timestamp, t, "both stakes really landed on one timestamp");

        assertEq(_checkpointCount(alice), 1, "same key collapses to ONE checkpoint, not two");
        assertEq(sGrove.getVotes(alice), 150e18);

        vm.warp(t + 1);
        assertEq(sGrove.getPastVotes(alice, t), 150e18, "reads the collapsed value, never the intermediate 100e18");
        assertEq(sGrove.getPastTotalSupply(t), 150e18, "and the supply collapses the same way");
        assertEq(sGrove.getPastVotes(alice, t - 1), 0, "nothing before the block");
        assertEq(sGrove.getPastTotalSupply(t - 1), 0);
    }

    /// @dev The same-key path with the two directions NETTING: a stake and a partial
    ///      unbond in one block must leave a single checkpoint holding the net 60e18.
    ///      A push-per-write implementation would leave two checkpoints at one key, and
    ///      `upperLookupRecent` would then be free to return the stale 100e18.
    function test_getPastVotes_stakeAndUnstakeInOneTimestampNetOut() public {
        uint256 t = block.timestamp;
        _stakeGrove(alice, 100e18);
        vm.prank(alice);
        sGrove.requestUnstake(40e18);
        assertEq(block.timestamp, t, "both writes really landed on one timestamp");

        assertEq(_checkpointCount(alice), 1, "one key, one checkpoint");
        assertEq(sGrove.getVotes(alice), 60e18);

        vm.warp(t + 1);
        assertEq(sGrove.getPastVotes(alice, t), 60e18, "history reads the NET value, not the pre-unbond 100e18");
        assertEq(sGrove.getPastTotalSupply(t), 60e18);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
    }

    /// @dev Delegate-SIDE history across a delegation change — the exact shape the
    ///      Governor uses when weight is delegated: it reads `getPastVotes(delegate,
    ///      snapshot)`. Each delegate must hold the weight for exactly the window it was
    ///      delegated, with no overlap (the same 100e18 must never be readable in two
    ///      delegates' histories at one timepoint) and no gap.
    function test_getPastVotes_delegateHistoryAcrossADelegationChange() public {
        _stakeGrove(alice, 100e18);
        uint256 tSelf = block.timestamp; // alice self-delegated

        vm.warp(tSelf + 1_000);
        vm.prank(alice);
        sGrove.delegate(bob);
        uint256 tBob = block.timestamp;

        vm.warp(tBob + 1_000);
        vm.prank(alice);
        sGrove.delegate(carol); // delegation is open to non-KYC addresses
        uint256 tCarol = block.timestamp;

        vm.warp(tCarol + 1_000);

        // window 1: alice holds it
        assertEq(sGrove.getPastVotes(alice, tSelf), 100e18, "at tSelf alice holds her own weight");
        assertEq(sGrove.getPastVotes(bob, tSelf), 0, "bob holds nothing yet");
        assertEq(sGrove.getPastVotes(carol, tSelf), 0);

        // window 2: bob holds it, alice holds nothing
        assertEq(sGrove.getPastVotes(alice, tBob), 0, "alice is emptied at the delegation timepoint");
        assertEq(sGrove.getPastVotes(bob, tBob), 100e18, "bob holds it from tBob");
        assertEq(sGrove.getPastVotes(bob, tBob + 500), 100e18, "and keeps it for the whole window");
        assertEq(sGrove.getPastVotes(carol, tBob + 500), 0, "no overlap with the next delegate");

        // window 3: carol holds it
        assertEq(sGrove.getPastVotes(bob, tCarol), 0, "bob is emptied when the delegation moves on");
        assertEq(sGrove.getPastVotes(carol, tCarol), 100e18, "carol holds it from tCarol");
        assertEq(sGrove.getVotes(carol), 100e18, "and still does now");

        // one delegate at a time, and the supply never moved
        assertEq(sGrove.getPastTotalSupply(tBob + 500), 100e18, "delegation never mints or burns units");
        assertEq(sGrove.getPastTotalSupply(tCarol), 100e18);
        assertEq(_checkpointCount(bob), 2, "bob: one checkpoint in, one out");
    }

    /// @dev The timestamp clock means `getPastVotes(a, block.timestamp)` is a FUTURE lookup
    ///      and reverts — the Governor always reads `snapshot < clock()`.
    function test_getPastVotes_futureLookupReverts() public {
        _stakeGrove(alice, 100e18);
        uint48 nowClock = uint48(block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, block.timestamp, nowClock)
        );
        sGrove.getPastVotes(alice, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, block.timestamp, nowClock)
        );
        sGrove.getPastTotalSupply(block.timestamp);
    }

    // ── NO DOUBLE COUNT, end to end ──────────────────────────────────────

    /// @dev The whole point of ADR-0026. Staking moves GROVE out of the wallet (killing
    ///      that much balance-vote weight) and mints exactly the same weight as sGROVE
    ///      votes. Aggregate voting power is INVARIANT under staking.
    function test_noDoubleCount_stakingPreservesAggregateVotingPower() public {
        vm.prank(frTreasury);
        grove.transfer(alice, 1_000e18);
        vm.prank(alice);
        grove.delegate(alice);
        vm.warp(block.timestamp + 1);

        uint256 groveBefore = grove.getVotes(alice);
        uint256 sGroveBefore = sGrove.getVotes(alice);
        uint256 aggregateBefore = groveBefore + sGroveBefore;
        assertEq(groveBefore, 1_000e18, "wallet GROVE votes");
        assertEq(sGroveBefore, 0);
        assertEq(votesAggregator.getVotes(alice), aggregateBefore, "aggregator agrees pre-stake");

        vm.startPrank(alice);
        grove.approve(address(sGrove), 400e18);
        sGrove.stake(400e18);
        vm.stopPrank();

        assertEq(grove.getVotes(alice), groveBefore - 400e18, "wallet votes fell by exactly the stake");
        assertEq(sGrove.getVotes(alice), sGroveBefore + 400e18, "sGROVE votes rose by exactly the stake");
        assertEq(grove.getVotes(alice) + sGrove.getVotes(alice), aggregateBefore, "aggregate voting power is unchanged");
        assertEq(votesAggregator.getVotes(alice), aggregateBefore, "the aggregator sees no change either");

        // and the custodied GROVE votes for nobody in the meantime
        assertEq(grove.getVotes(address(sGrove)), 0, "custodied GROVE has no balance votes");

        // the global bound: every delegate's aggregate weight together <= GROVE supply
        uint256 total = grove.getVotes(frTreasury) + grove.getVotes(alice) + sGrove.getVotes(alice);
        assertLe(total, grove.totalSupply(), "sum of aggregate votes never exceeds GROVE supply");
    }

    /// @dev The mechanism that makes the above true: `SGrove` never delegates the GROVE it
    ///      custodies, so that GROVE contributes to nobody's balance votes. This must hold
    ///      across stakes AND unstakes.
    function test_custodiedGroveStaysUndelegated() public {
        assertEq(grove.delegates(address(sGrove)), address(0), "undelegated at genesis");
        _stakeGrove(alice, 100e18);
        _stakeGrove(bob, 250e18);
        assertEq(grove.delegates(address(sGrove)), address(0), "still undelegated after stakes");
        assertEq(grove.getVotes(address(sGrove)), 0);
        assertEq(grove.balanceOf(address(sGrove)), 350e18, "it really is holding the GROVE");

        vm.prank(alice);
        uint256 id = sGrove.requestUnstake(100e18);
        vm.warp(block.timestamp + Config.SGROVE_UNBONDING_PERIOD);
        vm.prank(alice);
        sGrove.claimUnstake(id);
        assertEq(grove.delegates(address(sGrove)), address(0), "still undelegated after an unstake cycle");
        assertEq(grove.getVotes(address(sGrove)), 0);
    }

    /// @dev Quorum comes from GROVE's supply ONLY, so staking must not move the
    ///      denominator. Summing the supplies would let a whale stake before a snapshot
    ///      purely to raise the bar and block a proposal.
    function test_stakingDoesNotMoveTheQuorumDenominator() public {
        vm.warp(block.timestamp + 1);
        uint256 t = block.timestamp - 1;
        uint256 quorumBefore = votesAggregator.getPastTotalSupply(t);
        assertEq(quorumBefore, grove.totalSupply(), "denominator is GROVE supply");

        _stakeGrove(alice, 1_000_000e18);
        vm.warp(block.timestamp + 1);

        assertEq(
            votesAggregator.getPastTotalSupply(block.timestamp - 1),
            quorumBefore,
            "staking does not inflate the quorum denominator"
        );
        assertEq(sGrove.totalVotingUnits(), 1_000_000e18, "the units exist, they just are not quorum");
    }

    // ── EIP-6372 clock ───────────────────────────────────────────────────

    /// @dev A clock mismatch is the silent killer: `GovernorVotes` wraps both calls in
    ///      try/catch and FALLS BACK TO BLOCK NUMBERS, so a missing override surfaces only
    ///      as every voter reading ~0.
    function test_clock_isTimestampAndMatchesGrove() public {
        assertEq(sGrove.clock(), uint48(block.timestamp), "clock() == block.timestamp");
        assertEq(keccak256(bytes(sGrove.CLOCK_MODE())), keccak256("mode=timestamp"), "CLOCK_MODE is timestamps");
        assertEq(keccak256(bytes(sGrove.CLOCK_MODE())), keccak256(bytes(grove.CLOCK_MODE())), "both sources agree");
        assertEq(sGrove.clock(), grove.clock(), "and tick together");

        vm.warp(block.timestamp + 12_345);
        assertEq(sGrove.clock(), uint48(block.timestamp), "clock tracks time, not blocks");
    }

    // ── EIP-712 / delegateBySig ──────────────────────────────────────────

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            sGrove.eip712Domain();
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract
            )
        );
    }

    function _delegationDigest(address delegatee, uint256 nonce, uint256 expiry) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
    }

    /// @dev `__Votes_init` is empty in OZ 5.4.0, so the domain had to be seeded explicitly
    ///      in `initialize`. If it were not, gasless delegation would sign against an
    ///      unset (empty-name) domain and every off-chain signer would be incompatible.
    function test_eip712Domain_isSeededWithTheConfiguredName() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = sGrove.eip712Domain();
        assertEq(fields, hex"0f", "name/version/chainId/verifyingContract present");
        assertEq(name, Config.SGROVE_NAME, "domain name == Config.SGROVE_NAME");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(sGrove));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    /// @dev Full gasless-delegation round trip with a real signature, relayed by a third
    ///      party. The stake must move to the delegatee and the nonce must burn.
    function test_delegateBySig_roundTrip() public {
        (address signer, uint256 pk) = makeAddrAndKey("sgroveDelegator");
        _stakeGrove(signer, 700e18);
        assertEq(sGrove.getVotes(signer), 700e18, "self-delegated by the stake");

        uint256 nonce = sGrove.nonces(signer);
        assertEq(nonce, 0);
        uint256 expiry = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _delegationDigest(bob, nonce, expiry));

        vm.expectEmit(true, true, true, false, address(sGrove));
        emit IVotes.DelegateChanged(signer, signer, bob);
        vm.prank(carol); // any relayer, including a non-KYC address
        sGrove.delegateBySig(bob, nonce, expiry, v, r, s);

        assertEq(sGrove.delegates(signer), bob, "signature delegated to bob");
        assertEq(sGrove.getVotes(bob), 700e18, "bob holds the whole staked position");
        assertEq(sGrove.getVotes(signer), 0);
        assertEq(sGrove.nonces(signer), 1, "nonce consumed");
        assertEq(sGrove.totalVotingUnits(), 700e18, "delegation never mints or burns units");

        // the same signature cannot be replayed
        vm.expectRevert(abi.encodeWithSelector(NoncesUpgradeable.InvalidAccountNonce.selector, signer, 1));
        sGrove.delegateBySig(bob, nonce, expiry, v, r, s);
    }

    function test_delegateBySig_expiredSignatureReverts() public {
        (address signer, uint256 pk) = makeAddrAndKey("sgroveDelegator");
        _stakeGrove(signer, 100e18);

        uint256 expiry = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _delegationDigest(bob, 0, expiry));
        vm.expectRevert(abi.encodeWithSelector(IVotes.VotesExpiredSignature.selector, expiry));
        sGrove.delegateBySig(bob, 0, expiry, v, r, s);

        assertEq(sGrove.delegates(signer), signer, "delegation unchanged");
        assertEq(sGrove.getVotes(signer), 100e18);
    }

    /// @dev The malformed / wrong-signer paths. Replay and expiry are covered above; this
    ///      pins that a signature that does not recover to the staker can never move the
    ///      staker's weight — the relayer-facing attack surface, since `delegateBySig` is
    ///      callable by anyone.
    function test_delegateBySig_invalidSignatureReverts() public {
        (address signer, uint256 pk) = makeAddrAndKey("sgroveDelegator");
        _stakeGrove(signer, 100e18);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = _delegationDigest(bob, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // 1. garbage `v`: ecrecover yields address(0), which OZ rejects outright
        vm.prank(carol);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        sGrove.delegateBySig(bob, 0, expiry, 0, r, s);

        // 2. malleable high-`s`: rejected by selector WITH the offending value
        bytes32 highS =
            bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        sGrove.delegateBySig(bob, 0, expiry, v == 27 ? 28 : 27, r, highS);

        // 3. a well-formed signature from the WRONG key: it recovers to the stranger, so
        //    it delegates the STRANGER's (zero) weight and never touches the staker's
        (address stranger, uint256 strangerPk) = makeAddrAndKey("sgroveStranger");
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(strangerPk, digest);
        vm.prank(carol);
        sGrove.delegateBySig(bob, 0, expiry, v2, r2, s2);
        assertEq(sGrove.delegates(stranger), bob, "the signature bound the signer it recovered to");
        assertEq(sGrove.nonces(stranger), 1, "and burned THAT signer's nonce");

        // the staker is untouched by all three
        assertEq(sGrove.delegates(signer), signer, "still self-delegated");
        assertEq(sGrove.getVotes(signer), 100e18, "weight never moved");
        assertEq(sGrove.getVotes(bob), 0, "bob gained nothing: the stranger had no units");
        assertEq(sGrove.nonces(signer), 0, "and the staker's nonce is unspent");
        assertEq(sGrove.totalVotingUnits(), 100e18);
    }

    // ── the cascade never touches governance weight ──────────────────────

    /// @dev A cascade draw spends the USDfr COVERAGE RESERVE, never the staked GROVE
    ///      (ADR-0021 — there is no on-chain GROVE/USD path). A staker whose coverage was
    ///      drained keeps 100% of their votes.
    function test_coverShortfall_doesNotChangeAnyVotingWeight() public {
        _stakeGrove(alice, 1_000e18);
        _stakeGrove(bob, 500e18);
        _fundCoverage(100_000e18);

        uint256 aliceVotes = sGrove.getVotes(alice);
        uint256 bobVotes = sGrove.getVotes(bob);
        uint256 supply = sGrove.totalVotingUnits();
        assertEq(aliceVotes, 1_000e18);
        assertEq(bobVotes, 500e18);
        assertEq(supply, 1_500e18);

        vm.prank(address(defaultManager));
        uint256 covered = sGrove.coverShortfall(EVENT_1, 80_000e18);
        assertEq(covered, 80_000e18, "the uncapped draw really happened");
        assertEq(sGrove.coverageReserve(), 20_000e18);

        assertEq(sGrove.getVotes(alice), aliceVotes, "cascade draw leaves alice's votes intact");
        assertEq(sGrove.getVotes(bob), bobVotes, "and bob's");
        assertEq(sGrove.totalVotingUnits(), supply, "and the unit supply");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
    }

    // ── guardian pause ───────────────────────────────────────────────────

    /// @dev A documented consequence, not an accident: pausing freezes the ELECTORATE
    ///      (no new stake in, no stake out) while leaving delegation and every vote READ
    ///      fully live, so an in-flight proposal can still be voted and counted.
    function test_pause_freezesElectorateButNotDelegationOrReads() public {
        _stakeGrove(alice, 1_000e18);
        uint256 pastPoint = block.timestamp;
        vm.warp(block.timestamp + 1);

        vm.prank(frTreasury);
        grove.transfer(alice, 10e18);
        vm.prank(alice);
        grove.approve(address(sGrove), 10e18);

        vm.prank(guardian);
        sGrove.pause();

        // the electorate is frozen
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sGrove.stake(10e18);
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sGrove.requestUnstake(1e18);

        // delegation still works while paused
        vm.prank(alice);
        sGrove.delegate(bob);
        assertEq(sGrove.delegates(alice), bob, "delegate is not pausable");
        assertEq(sGrove.getVotes(bob), 1_000e18, "and it moved the weight");
        assertEq(sGrove.getVotes(alice), 0);

        // every read still works while paused
        assertEq(sGrove.totalVotingUnits(), 1_000e18);
        assertEq(sGrove.getPastVotes(alice, pastPoint), 1_000e18, "history is readable while paused");
        assertEq(sGrove.getPastTotalSupply(pastPoint), 1_000e18);
        assertEq(sGrove.clock(), uint48(block.timestamp));
        assertEq(votesAggregator.getVotes(bob), 1_000e18, "the aggregator reads through a pause");

        vm.prank(guardian);
        sGrove.unpause();
        vm.prank(alice);
        sGrove.stake(10e18);
        assertEq(sGrove.getVotes(bob), 1_010e18, "post-unpause stake credits the delegate");
    }

    // ── fuzz: the two structural equalities ──────────────────────────────

    /// @dev `totalVotingUnits() == totalStaked()` and the sum of the individual delegates'
    ///      weights equals the unit supply, for arbitrary stake / unstake sequences.
    function testFuzz_votingUnitsTrackStakeExactly(uint256 a, uint256 b, uint256 unstakeA, bool delegateAway) public {
        a = bound(a, 1, 1_000_000e18);
        b = bound(b, 1, 1_000_000e18);
        unstakeA = bound(unstakeA, 1, a);

        _stakeGrove(alice, a);
        _stakeGrove(bob, b);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units == stake after stakes");
        assertEq(sGrove.getVotes(alice) + sGrove.getVotes(bob), a + b, "weights sum to the supply");

        if (delegateAway) {
            vm.prank(alice);
            sGrove.delegate(bob);
            assertEq(sGrove.getVotes(bob), a + b, "delegation concentrates, never creates");
            assertEq(sGrove.getVotes(alice), 0);
            assertEq(sGrove.totalVotingUnits(), a + b, "delegation never changes the supply");
        }

        vm.prank(alice);
        sGrove.requestUnstake(unstakeA);
        assertEq(sGrove.totalVotingUnits(), a + b - unstakeA, "unbonding burns exactly");
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked(), "units == stake after unbonding");
        assertEq(
            sGrove.getVotes(alice) + sGrove.getVotes(bob), sGrove.totalVotingUnits(), "weights still sum to the supply"
        );
    }

    /// @dev Repeated stakes never inflate: N stakes of `chunk` give exactly N*chunk votes.
    function testFuzz_repeatedStakesNeverDoubleCount(uint256 chunk, uint8 times) public {
        chunk = bound(chunk, 1, 10_000e18);
        uint256 n = bound(times, 1, 12);
        for (uint256 i = 0; i < n; ++i) {
            _stakeGrove(alice, chunk);
        }
        assertEq(sGrove.getVotes(alice), chunk * n, "votes == sum of stakes, exactly");
        assertEq(sGrove.totalVotingUnits(), chunk * n);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(sGrove.stakedOf(alice), chunk * n);
    }
}
