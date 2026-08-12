// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {GroveToken} from "../../../src/GroveToken.sol";
import {SGrove} from "../../../src/SGrove.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {Config} from "../../../src/libraries/Config.sol";

/// @dev Bounded handler for the sGROVE backstop (fail_on_revert = true). Per-call
///      DIFFERENTIAL asserts pin ADR-0035's shared-reserve draw; ghosts let the invariant
///      functions prove custody and reward conservation.
contract SGroveHandler is Test {
    GroveToken internal grove;
    SGrove internal sGrove;
    USDfr internal usdfr;
    address internal frTreasury;
    address internal usdfrFunder; // KYC'd source of USDfr for rewards/coverage
    address internal coverageCaller; // holds CREDIT_ROLE on sGrove (DefaultManager)
    address internal guardian; // holds GUARDIAN_ROLE on sGrove (pause/unpause)

    address[3] public actors;
    /// @dev Signing keys for the same three actors, so `delegateBySig` (and therefore the
    ///      EIP-712 domain seeded in `SGrove.initialize`) is exercised at invariant level.
    uint256[3] internal actorKeys;

    /// @dev EIP-712 struct hash for `IVotes.delegateBySig`.
    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    /// @dev EIP-712 domain type hash.
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // ── ghost state ──────────────────────────────────────────────────────
    uint256 public ghostUnbondingOutstanding; // requested, not yet claimed
    uint256 public ghostRewardsNotified;
    uint256 public ghostRewardsClaimed;
    uint256 public callCount;

    // ── governance ghosts (ADR-0026 / L-02, anti-vacuity evidence) ───────
    // Split by TARGET KIND so a run can prove all three delegation shapes were
    // actually reached, not just that `delegate` was called.
    uint256 public ghostSGroveDelegateCalls;
    uint256 public ghostSGroveSelfDelegations;
    uint256 public ghostSGroveCrossDelegations;
    uint256 public ghostSGroveNullDelegations;
    uint256 public ghostGroveDelegateCalls;
    uint256 public ghostGroveSelfDelegations;
    uint256 public ghostGroveCrossDelegations;
    uint256 public ghostGroveNullDelegations;
    uint256 public ghostActorGroveFunded;
    /// @dev Largest aggregate voting power ever observed on an actor. Zero here means the
    ///      votes invariant only ever compared 0 <= supply, i.e. it was vacuous.
    uint256 public ghostMaxActorAggregateVotes;
    /// @dev Peak votes seen on EACH LEG separately. `ghostMaxActorAggregateVotes` alone
    ///      cannot distinguish "the aggregate was non-zero because the GROVE leg carried
    ///      everything and the sGROVE leg was dead" — which is exactly the shape mutation D
    ///      (staking never credits the staker) produces. These two split that apart.
    uint256 public ghostMaxGroveLegVotes;
    uint256 public ghostMaxSGroveLegVotes;
    /// @dev Delegations aimed at the two NON-ACTOR targets (gap 7): the backstop itself and
    ///      the Forest Road treasury. Delegating TO the backstop is legal for any holder, so
    ///      it must be explored rather than assumed impossible.
    uint256 public ghostSGroveToBackstop;
    uint256 public ghostSGroveToTreasury;
    uint256 public ghostGroveToBackstop;
    uint256 public ghostGroveToTreasury;
    /// @dev Guardian pause/unpause transitions actually taken.
    uint256 public ghostPauseToggles;
    /// @dev `delegateBySig` calls that recovered the right signer and landed.
    uint256 public ghostDelegateBySigCalls;

    /// @notice True once this handler has EXPLICITLY re-pointed `who`'s sGROVE delegate.
    /// @dev The ghost that gives `invariant_sgrove_firstStakeAutoSelfDelegates` its teeth:
    ///      for an actor nobody has ever delegated by hand, the ONLY way their sGROVE
    ///      delegate can be non-zero is `SGrove.stake`'s auto-self-delegation. Delete that
    ///      line from `stake` and every such actor is left at `address(0)` while holding
    ///      stake — silently disenfranchised, the exact bug L-02 exists to prevent, and
    ///      invisible to every conservation invariant (both sides collapse to zero).
    mapping(address => bool) public everDelegated;

    constructor(
        GroveToken grove_,
        SGrove sGrove_,
        USDfr usdfr_,
        address frTreasury_,
        address usdfrFunder_,
        address coverageCaller_,
        address guardian_
    ) {
        grove = grove_;
        sGrove = sGrove_;
        usdfr = usdfr_;
        frTreasury = frTreasury_;
        usdfrFunder = usdfrFunder_;
        coverageCaller = coverageCaller_;
        guardian = guardian_;
        (actors[0], actorKeys[0]) = makeAddrAndKey("sgActor0");
        (actors[1], actorKeys[1]) = makeAddrAndKey("sgActor1");
        (actors[2], actorKeys[2]) = makeAddrAndKey("sgActor2");
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        if (sGrove.paused()) return; // `stake` is `whenNotPaused`; fail_on_revert = true
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(frTreasury);
        grove.transfer(actor, amount);
        vm.startPrank(actor);
        grove.approve(address(sGrove), amount);
        sGrove.stake(amount);
        vm.stopPrank();
        _recordVotes();
        callCount++;
    }

    function requestUnstake(uint256 actorSeed, uint256 amount) external {
        if (sGrove.paused()) return; // `whenNotPaused`
        address actor = actors[actorSeed % 3];
        uint256 staked = sGrove.stakedOf(actor);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        vm.prank(actor);
        sGrove.requestUnstake(amount);
        ghostUnbondingOutstanding += amount;
        callCount++;
    }

    function claimUnstake(uint256 actorSeed, uint256 idSeed) external {
        if (sGrove.paused()) return; // `whenNotPaused`
        address actor = actors[actorSeed % 3];
        SGrove.Unbond[] memory list = sGrove.unbondsOf(actor);
        if (list.length == 0) return;
        uint256 id = idSeed % list.length;
        if (list[id].amount == 0 || block.timestamp < list[id].releaseAt) return;
        vm.prank(actor);
        sGrove.claimUnstake(id);
        ghostUnbondingOutstanding -= list[id].amount;
        callCount++;
    }

    function fundCoverage(uint256 amount) external {
        amount = bound(amount, 1, 500_000e18);
        vm.startPrank(usdfrFunder);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
        callCount++;
    }

    function notifyRewards(uint256 amount) external {
        uint256 ts = sGrove.totalStaked();
        if (ts == 0) return;
        // AUDIT FIX (R4-EC1): rewards now stream, so the dust guard reverts when
        // amount/duration rounds to 0. Bound at/above the duration so the per-second rate
        // is always >= 1 wei/sec, clearing the guard.
        (uint256 curRate, uint64 finish,, uint64 dur) = sGrove.rewardSchedule();
        amount = bound(amount, uint256(dur) + 1, 500_000e18);
        // AUDIT FIX (M-1): a mid-stream notify that would LOWER the rate reverts. Skip
        // those (a legitimate precondition) rather than trip fail_on_revert; the fuzzer
        // still exercises rate-raising top-ups and fresh post-finish streams.
        if (block.timestamp < finish) {
            uint256 leftover = (uint256(finish) - block.timestamp) * curRate;
            if ((amount + leftover) / dur < curRate) return;
        }
        vm.startPrank(usdfrFunder);
        usdfr.approve(address(sGrove), amount);
        sGrove.notifyRewards(amount);
        vm.stopPrank();
        ghostRewardsNotified += amount;
        callCount++;
    }

    function claimRewards(uint256 actorSeed) external {
        if (sGrove.paused()) return; // `whenNotPaused`
        address actor = actors[actorSeed % 3];
        if (sGrove.pendingRewards(actor) == 0) return;
        vm.prank(actor);
        uint256 got = sGrove.claimRewards();
        ghostRewardsClaimed += got;
        callCount++;
    }

    /// @dev ADR-0035 differential: covered is exactly `min(request, live reserve)`. Event ids are
    ///      deliberately revisited so cumulative observability is also checked across chunks.
    function coverShortfall(uint256 eventId, uint256 amount) external {
        eventId = bound(eventId, 1, 3);
        amount = bound(amount, 1, 1_000_000e18);
        uint256 reserveBefore = sGrove.coverageReserve();
        (uint256 drawnBefore, uint256 reachableBefore) = sGrove.eventCoverage(eventId);
        uint256 expected = amount < reserveBefore ? amount : reserveBefore;
        uint256 callerBefore = usdfr.balanceOf(coverageCaller);

        vm.prank(coverageCaller);
        uint256 covered = sGrove.coverShortfall(eventId, amount);

        assertEq(covered, expected, "ADR-0035: covered != min(request, shared reserve)");
        assertEq(usdfr.balanceOf(coverageCaller) - callerBefore, covered, "ICascadeBackstop delivery");
        assertEq(sGrove.coverageReserve(), reserveBefore - covered, "reserve decrement exact");
        (uint256 drawnAfter, uint256 reachableAfter) = sGrove.eventCoverage(eventId);
        assertEq(drawnAfter, drawnBefore + covered, "per-event cumulative tracking exact");
        assertEq(reachableBefore, drawnBefore + reserveBefore, "event view before draw is not live");
        assertEq(reachableAfter, drawnAfter + sGrove.coverageReserve(), "event view after draw is not live");
        assertEq(reachableAfter, reachableBefore, "draw must transfer reserve into cumulative observability exactly");
        callCount++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 30 days);
        vm.warp(block.timestamp + secs);
        callCount++;
    }

    // ── governance / delegation (ADR-0026, L-02) ─────────────────────────

    /// @notice Re-points an actor's sGROVE (ACTIVE STAKE) votes.
    /// @dev Reaches all three shapes — self, another actor, and `address(0)` (revoking) —
    ///      and REVISITS them, because the target seed is bounded to four values over a
    ///      three-actor set. Revoking then re-staking is the sequence that exercises the
    ///      load-bearing ordering in `SGrove.stake` (self-delegate BEFORE the balance
    ///      increment): after `delegate(address(0))` the staker has a zero delegate again,
    ///      so the next `stake` re-runs `_delegate(msg.sender, msg.sender)` with a NON-ZERO
    ///      prior stake — the exact state in which the wrong order double-books `amount`.
    ///      Never reverts: `VotesUpgradeable.delegate` is unguarded and unpausable, and a
    ///      no-op re-delegation to the same target is legal.
    function delegate(uint256 actorSeed, uint256 targetSeed) external {
        _doSGroveDelegate(actors[actorSeed % 3], _delegateTarget(targetSeed));
        callCount++;
    }

    /// @notice Re-points an actor's sGROVE votes over an EIP-712 signature (gasless path).
    /// @dev The only invariant-level exercise of `SGrove`'s EIP-712 domain. The digest is
    ///      rebuilt here from `Config.SGROVE_NAME` / version "1" INDEPENDENTLY of the
    ///      contract, so an upgrade that forgot `__EIP712_init` (or changed the name) would
    ///      recover a different signer, fail `_useCheckedNonce`, and trip `fail_on_revert`.
    ///      Never reverts otherwise: the nonce is read live and the expiry is in the future.
    function delegateBySig(uint256 actorSeed, uint256 targetSeed) external {
        uint256 idx = actorSeed % 3;
        address actor = actors[idx];
        address target = _delegateTarget(targetSeed);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(Config.SGROVE_NAME)),
                keccak256(bytes("1")),
                block.chainid,
                address(sGrove)
            )
        );
        uint256 nonce = sGrove.nonces(actor);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", domainSeparator, keccak256(abi.encode(DELEGATION_TYPEHASH, target, nonce, expiry))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKeys[idx], digest);
        sGrove.delegateBySig(target, nonce, expiry, v, r, s);
        // The signature landed only if the recovered signer was the actor: assert it.
        assertEq(sGrove.delegates(actor), target, "delegateBySig: EIP-712 domain/nonce drift");
        assertEq(sGrove.nonces(actor), nonce + 1, "delegateBySig: nonce not consumed");
        _classifySGrove(actor, target);
        everDelegated[actor] = true;
        ghostSGroveDelegateCalls++;
        ghostDelegateBySigCalls++;
        _recordVotes();
        callCount++;
    }

    /// @notice Re-points an actor's WALLET GROVE votes (the other leg of the aggregate).
    /// @dev Without this the GROVE side of `invariant_votes_neverExceedGroveSupply` would
    ///      only ever see the treasury's static self-delegation.
    function delegateGrove(uint256 actorSeed, uint256 targetSeed) external {
        _doGroveDelegate(actors[actorSeed % 3], _delegateTarget(targetSeed));
        callCount++;
    }

    /// @notice Guardian pause / unpause of the backstop.
    /// @dev Be precise about what this does NOT do (corrected after review): it does NOT
    ///      reach the `whenNotPaused` FALSE branch. All four pausable actions early-return
    ///      on `sGrove.paused()`, so `EnforcedPause` is never produced anywhere in this
    ///      suite. That is deliberate — reaching a revert branch is incompatible with
    ///      `fail_on_revert = true` without an in-handler `vm.expectRevert`, so the revert
    ///      paths are pinned in the unit suite instead (`SGroveVotes.t.sol`).
    ///      What this action DOES deliver is the half that only a stateful campaign can:
    ///      every invariant is evaluated inside real pause windows, and it shows a pause does
    ///      NOT disturb the voting-unit accounting: `delegate`/`delegateBySig` are
    ///      unpausable by design, so votes can be re-pointed mid-pause and
    ///      `totalVotingUnits() == totalStaked()` must survive it.
    function setPaused(uint256 seed) external {
        bool want = seed % 2 == 0;
        if (want == sGrove.paused()) return; // `pause`/`unpause` revert on a no-op transition
        vm.prank(guardian);
        if (want) sGrove.pause();
        else sGrove.unpause();
        assertEq(sGrove.paused(), want, "pause state did not follow the guardian call");
        ghostPauseToggles++;
        callCount++;
    }

    /// @notice Moves treasury GROVE into an actor's WALLET without staking it.
    /// @dev Anti-vacuity for `delegateGrove`: `stake` transfers and stakes the same amount
    ///      in one call, so actors would otherwise hold ~0 wallet GROVE and every GROVE
    ///      delegation would move zero votes. Deliberately never sends GROVE to the
    ///      backstop, so `invariant_sgrove_groveCustodyExact` is unaffected.
    function fundActorGrove(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1, 250_000e18);
        vm.prank(frTreasury);
        grove.transfer(actor, amount);
        ghostActorGroveFunded += amount;
        _recordVotes();
        callCount++;
    }

    /// @notice One-shot deterministic seed, called from the invariant `setUp` ONLY — never
    ///         a fuzz target.
    /// @dev Anti-vacuity, made deterministic instead of probabilistic. `afterInvariant`
    ///      asserts that the delegation shapes were reached; relying on the fuzzer for that
    ///      is flaky (at `lite` depth 32 roughly 5% of runs never emit a single sGROVE
    ///      self-delegation, and the reviewer observed exactly such a run passing green).
    ///      Forge re-runs every invariant run from the post-`setUp` state, so writing these
    ///      ghosts here makes them a floor under EVERY run, and the console summary still
    ///      reports the total so fuzz-driven growth above this floor is visible.
    ///
    ///      Two choices here are load-bearing and must not be "tidied":
    ///      1. `actors[0]` is deliberately NEVER hand-delegated, so `everDelegated[actor0]`
    ///         stays false while it holds stake. It is the standing live probe for
    ///         `invariant_sgrove_firstStakeAutoSelfDelegates`; delegating it here would make
    ///         that invariant vacuous from the base state onwards.
    ///      2. `actors[2]` delegates its WALLET GROVE to the backstop address. That is a
    ///         perfectly legal thing for any holder to do, and it is why
    ///         `grove.getVotes(address(sGrove)) == 0` was removed as an "invariant": it is
    ///         not one. `grove.delegates(address(sGrove)) == address(0)` is.
    function seedGovernanceShapes() external {
        _seedStake(actors[0], 100_000e18);
        _seedStake(actors[1], 200_000e18);
        _seedStake(actors[2], 300_000e18);

        _doSGroveDelegate(actors[1], actors[1]); // self
        _doSGroveDelegate(actors[2], actors[1]); // cross (actor -> actor)
        _doSGroveDelegate(actors[2], frTreasury); // external: treasury
        _doSGroveDelegate(actors[2], address(sGrove)); // external: the backstop itself
        _doSGroveDelegate(actors[2], address(0)); // revoke

        _seedFundActorGrove(actors[1], 150_000e18);
        _seedFundActorGrove(actors[2], 150_000e18);
        _doGroveDelegate(actors[1], actors[1]); // self
        _doGroveDelegate(actors[2], address(sGrove)); // wallet GROVE votes -> backstop
        _recordVotes();
    }

    // ── reconciliation views ─────────────────────────────────────────────

    /// @dev The actor set, so the invariant contract can enumerate and dedupe delegates.
    function actorList() external view returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            list[i] = actors[i];
        }
    }

    /// @dev Delegation targets: each of the three actors (self and cross both reachable),
    ///      `address(0)` (the revoke case), the Forest Road treasury, and the BACKSTOP
    ///      ITSELF. The last two are gap 7: a third party that holds no stake of its own can
    ///      legally be someone's delegate, and delegating TO `address(sGrove)` is legal for
    ///      any holder — so the conservation invariants must survive both rather than pass
    ///      because the shape was never offered.
    function _delegateTarget(uint256 targetSeed) private view returns (address) {
        uint256 pick = bound(targetSeed, 0, 5);
        if (pick < 3) return actors[pick];
        if (pick == 3) return address(0);
        if (pick == 4) return frTreasury;
        return address(sGrove);
    }

    /// @dev Tracks the peak aggregate voting power seen on any actor, purely as
    ///      anti-vacuity evidence for `invariant_votes_neverExceedGroveSupply`, plus the
    ///      peak on each LEG separately (a non-zero aggregate carried entirely by the GROVE
    ///      leg would not prove the sGROVE leg ever moved a vote).
    function _recordVotes() private {
        for (uint256 i = 0; i < 5; ++i) {
            address who = i < 3 ? actors[i] : (i == 3 ? frTreasury : address(sGrove));
            uint256 g = grove.getVotes(who);
            uint256 sg = sGrove.getVotes(who);
            if (i < 3 && g + sg > ghostMaxActorAggregateVotes) ghostMaxActorAggregateVotes = g + sg;
            if (g > ghostMaxGroveLegVotes) ghostMaxGroveLegVotes = g;
            if (sg > ghostMaxSGroveLegVotes) ghostMaxSGroveLegVotes = sg;
        }
    }

    /// @dev Shared body of `delegate` and the seed: re-points `actor`'s sGROVE votes and
    ///      records the shape. Never reverts — `VotesUpgradeable.delegate` is unguarded and
    ///      unpausable, and a no-op re-delegation to the same target is legal.
    function _doSGroveDelegate(address actor, address target) private {
        vm.prank(actor);
        sGrove.delegate(target);
        _classifySGrove(actor, target);
        everDelegated[actor] = true;
        ghostSGroveDelegateCalls++;
        _recordVotes();
    }

    /// @dev Shared body of `delegateGrove` and the seed.
    function _doGroveDelegate(address actor, address target) private {
        vm.prank(actor);
        grove.delegate(target);
        if (target == address(0)) ghostGroveNullDelegations++;
        else if (target == actor) ghostGroveSelfDelegations++;
        else ghostGroveCrossDelegations++;
        if (target == address(sGrove)) ghostGroveToBackstop++;
        if (target == frTreasury) ghostGroveToTreasury++;
        ghostGroveDelegateCalls++;
        _recordVotes();
    }

    /// @dev Buckets an sGROVE delegation by target kind (anti-vacuity evidence only).
    function _classifySGrove(address actor, address target) private {
        if (target == address(0)) ghostSGroveNullDelegations++;
        else if (target == actor) ghostSGroveSelfDelegations++;
        else ghostSGroveCrossDelegations++;
        if (target == address(sGrove)) ghostSGroveToBackstop++;
        if (target == frTreasury) ghostSGroveToTreasury++;
    }

    /// @dev Seed-only stake. Mirrors `stake` without touching `callCount` (the seed is not
    ///      a fuzzed call and must not inflate the call summary).
    function _seedStake(address actor, uint256 amount) private {
        vm.prank(frTreasury);
        grove.transfer(actor, amount);
        vm.startPrank(actor);
        grove.approve(address(sGrove), amount);
        sGrove.stake(amount);
        vm.stopPrank();
    }

    /// @dev Seed-only wallet-GROVE funding (no staking), so the GROVE leg is non-zero.
    function _seedFundActorGrove(address actor, uint256 amount) private {
        vm.prank(frTreasury);
        grove.transfer(actor, amount);
        ghostActorGroveFunded += amount;
    }

    function sumStaked() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += sGrove.stakedOf(actors[i]);
        }
    }

    function sumPendingRewards() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += sGrove.pendingRewards(actors[i]);
        }
    }
}
