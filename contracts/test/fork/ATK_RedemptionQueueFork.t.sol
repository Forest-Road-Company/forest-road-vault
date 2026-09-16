// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";

/// @title ATK_RedemptionQueueFork — adversarial assault on the sUSDfr RedemptionQueue (ADR-0010)
/// @notice AUTHORISED pre-audit attack on the owner's own code, on a pinned mainnet fork. Local
///         `forge` only; nothing here broadcasts or moves real value. Independent of the existing
///         EXP3/QueueDeep suites: this file exists to try to BREAK the four §1.3 queue invariants
///         directly, from the PERMISSIONLESS surface (`requestRedeem`, `claim`) an adversary can
///         reach with no role, and to compose the gated `closeEpoch` out of order/time around them.
///
///         The four invariants under attack, one map each:
///           (A) cannot claim ANOTHER holder's position;
///           (B) NO double-claim;
///           (C) FIFO holds (a later request can never be served ahead of an incomplete head);
///           (D) NEVER distributes more than the available/snapshotted liquidity.
///
///         Plus two attacks the sibling suites do NOT run, chosen because they probe the exact
///         places accounting could silently leak:
///           (E) mid-settlement LIQUIDITY PUMP: inject fresh treasury liquidity between two
///               settlement chunks and try to make the latched settlement spend MORE than the
///               budget it snapshotted. The snapshot must be a one-way ratchet DOWN (H-04), so
///               new money is invisible to the open settlement — otherwise (D) is violable by any
///               depositor who can time a mint against the keeper.
///           (F) USDfr DONATION: dump USDfr straight onto the queue contract and try to (i) steal
///               it, or (ii) make a real position claim MORE than it was credited. `claim` pays
///               `assetsClaimable`, never `balanceOf(this)`, so a donation must be inert — stuck,
///               unclaimable, and unable to inflate any position.
///
///         Every outcome is made unambiguous: where the protocol blocks the attack the test
///         asserts the SPECIFIC custom error; where it would succeed it asserts the violated
///         state. On this stack every route is blocked — the reverts and the ceilings ARE the
///         result being proven.
///
/// @dev Extends `ForkLifecycleFixture` (the REAL `Deploy.s.sol` topology, real USDC). The harness
///      (`address(this)`) holds `SETTLEMENT_KEEPER_ROLE` and `DEFAULT_ADMIN_ROLE` on the queue, so
///      it drives `closeEpoch`/governance. Attackers are unprivileged actors (`bob`, `carol`, and
///      a bespoke re-entrant contract) with no role anywhere.
contract ATK_RedemptionQueueForkTest is ForkLifecycleFixture {
    // ═════════════════════════════════════════════════════════════════════════
    // (A) CANNOT CLAIM ANOTHER HOLDER'S POSITION
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK: a non-owner sweeps a filled request. Tried BEFORE a fill (the owner gate
    ///         must fire regardless of whether there is anything to take) and AFTER a fill (there
    ///         is real USDfr in custody). BLOCKED by `r.owner != msg.sender` -> `Queue_NotRequestOwner`.
    function test_attack_cannotClaimAnotherHoldersPosition() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 300_000e18);
        uint256 id = _requestFrom(alice, shA);

        // Route 1 — steal BEFORE any fill: the owner check precedes the claimable check, so a
        // role-less, non-KYC'd attacker is refused even though there is nothing yet to take.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, carol));
        queue.claim(id);

        // Fill the position so there is genuine value to steal.
        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(id);
        assertEq(rem, 0, "alice's request is fully filled");
        assertGt(claimable, 0, "there is USDfr in custody to steal");

        // Route 2 — steal AFTER the fill, from two distinct non-owners.
        uint256 bobBefore = usdfr.balanceOf(bob);
        uint256 carolBefore = usdfr.balanceOf(carol);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, bob));
        queue.claim(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, carol));
        queue.claim(id);
        assertEq(usdfr.balanceOf(bob), bobBefore, "thief bob received nothing");
        assertEq(usdfr.balanceOf(carol), carolBefore, "thief carol received nothing");
        assertEq(usdfr.balanceOf(address(queue)), claimable, "the value is still in custody for the owner");

        // The rightful owner still gets exactly their fill, and only once.
        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        assertEq(queue.claim(id), claimable, "owner claims the exact fill");
        assertEq(usdfr.balanceOf(alice) - aliceBefore, claimable, "and receives it");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (B) NO DOUBLE-CLAIM — sequential, across epochs, and cross-user on a fresh slice
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK: extract a position more than once. `claim` zeroes `assetsClaimable`
    ///         (effects-first) before the transfer, so a repeat claim of the SAME assets reverts
    ///         `Queue_NothingClaimable`. A later epoch crediting a NEW slice is legitimate income,
    ///         not a double-claim; and an attacker cannot race in to take that fresh slice either
    ///         (the owner gate still fires). Cumulative received can never exceed cumulative filled.
    function test_attack_noDoubleClaimAcrossEpochsAndNoCrossUserOnFreshSlice() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 500_000e18);
        queue.setEpochLiquidityBps(1); // tiny budget => an oversized request fills in slices
        uint256 id = _requestFrom(alice, shA);

        // ── epoch 1: a slice fills, claimed once ─────────────────────────────
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem1, uint256 c1,,) = queue.request(id);
        assertGt(c1, 0, "epoch 1 filled a slice");
        assertGt(rem1, 0, "but not the whole oversized request");

        uint256 before1 = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got1 = queue.claim(id);
        assertEq(got1, c1, "claim pays exactly the filled slice");
        assertEq(usdfr.balanceOf(alice) - before1, c1, "and transfers exactly that");

        // sequential double-claim: nothing left
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);

        // ── epoch 2: a SECOND slice fills, left unclaimed ────────────────────
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem2, uint256 c2,,) = queue.request(id);
        assertGt(c2, 0, "epoch 2 filled another slice");
        assertLt(rem2, rem1, "and consumed more shares");

        // an attacker tries to race in and take the fresh, unclaimed slice: still owner-gated
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, bob));
        queue.claim(id);

        // cross-epoch double-claim: the owner's claim pays ONLY the new slice, never re-pays c1
        uint256 before2 = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got2 = queue.claim(id);
        assertEq(got2, c2, "claim pays only the NEW slice, not the already-claimed one");
        assertEq(usdfr.balanceOf(alice) - before2, c2, "exact transfer of the new slice only");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);

        // CONSERVATION: total received == total filled, never more.
        assertEq(got1 + got2, c1 + c2, "cumulative claimed == cumulative filled - no double extraction");
        assertEq(usdfr.balanceOf(address(queue)), 0, "no unclaimed residue mis-accounted");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (C) FIFO HOLDS — a later request can never be served ahead of an incomplete head
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK: a small request queued BEHIND a large head tries to be served first by
    ///         exploiting a per-epoch budget too small to ever complete the head. BLOCKED: the
    ///         settlement cursor walks strictly from `head`; a partial head never advances, so the
    ///         request behind it stays untouched across arbitrarily many epochs and cannot claim.
    function test_attack_fifoCannotBeJumpedAheadOfPartialHead() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 500_000e6);
        uint256 shA = _stake(alice, 400_000e18); // large head
        uint256 shB = _stake(bob, 50_000e18); // small, queued behind

        queue.setEpochLiquidityBps(1); // budget can only ever nibble the head
        uint256 idA = _requestFrom(alice, shA);
        uint256 idB = _requestFrom(bob, shB);
        assertEq(idA, 0, "alice is the head");
        assertEq(idB, 1, "bob is strictly behind");

        // Two full heartbeats; bob must stay completely untouched both times.
        for (uint256 i = 0; i < 2; ++i) {
            _warpToSettleable();
            queue.closeEpoch(10);

            (, uint256 remA, uint256 cA,,) = queue.request(idA);
            (, uint256 remB, uint256 cB,,) = queue.request(idB);
            assertGt(cA, 0, "the head received a slice");
            assertGt(remA, 0, "the oversized head is still incomplete");
            assertEq(remB, shB, "FIFO: bob's shares untouched while the head is partial");
            assertEq(cB, 0, "FIFO: bob credited nothing ahead of the head");
            assertEq(queue.head(), idA, "the head never advances past an incomplete request");
        }

        // Bob cannot claim a jumped fill (there is none).
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, idB));
        queue.claim(idB);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (D) NEVER DISTRIBUTES MORE THAN AVAILABLE LIQUIDITY — oversized single request
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK: queue a position far larger than the liquidity budget and try to make the
    ///         keeper pay out more than the snapshot. The oversized request only partially fills,
    ///         capped by `availableLiquidity()`; distributed USDfr never exceeds the snapshot.
    function test_attack_oversizedRequestCannotOverdrawTheBudget() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 500_000e18);
        queue.setEpochLiquidityBps(1); // a hard, binding ceiling far below the request value
        uint256 id = _requestFrom(alice, shA);

        _warpToSettleable();
        uint256 budget = queue.availableLiquidity();
        assertGt(budget, 0, "there is some budget");
        assertLt(budget, vault.previewRedeem(shA), "the request is worth far more than one budget");

        queue.closeEpoch(10);

        (, uint256 rem, uint256 claimable,,) = queue.request(id);
        assertGt(rem, 0, "the oversized request could not complete from one budget");
        assertLe(claimable, budget, "BUDGET CEILING: never distributes above the snapshot");
        assertLe(budget - claimable, 1, "the snapshot was spent down to at most rounding dust, not exceeded");
        assertEq(usdfr.balanceOf(address(queue)), claimable, "queue holds exactly what it distributed");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (E) MID-SETTLEMENT LIQUIDITY PUMP — the snapshot is a one-way ratchet DOWN
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK (not run by the sibling suites): latch a settlement open, then inject fresh
    ///         treasury liquidity BETWEEN chunks and try to make the still-open settlement spend
    ///         the new money. `closeEpoch` snapshots the budget once (under `!settling`) and only
    ///         ever SHRINKS it (`if budget > liveCap: budget = liveCap`); a mid-settlement INCREASE
    ///         in `availableLiquidity()` must be invisible to the open settlement. If it were not,
    ///         any depositor could time a mint against the keeper to break invariant (D).
    ///
    ///         Discriminator: a fresh mint between chunks raises `availableLiquidity()` well above
    ///         the snapshot, yet the tail request must draw ONLY from the snapshot's remainder.
    function test_attack_snapshotBudgetCannotBePumpedMidSettlement() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 shA = _stake(alice, 2_000_000e18);
        assertGt(shA, 0, "setup: attacker must own vault shares before requesting redemption");

        // 5% of ~2,000,010e18 idle == ~100,000e18 snapshot budget.
        queue.setEpochLiquidityBps(500);
        uint256 snapshotBudget = queue.availableLiquidity();
        assertGt(snapshotBudget, 0, "there is a budget to snapshot");

        // req0 worth ~half the budget (fills fully in one chunk, so the settlement latches open);
        // req1 worth ~2x the budget (can only ever partially fill from the snapshot's remainder).
        uint256 req0Shares = vault.convertToSharesAtRedemption(snapshotBudget / 2);
        uint256 req1Shares = vault.convertToSharesAtRedemption(snapshotBudget * 2);
        uint256 id0 = _requestFrom(alice, req0Shares);
        uint256 id1 = _requestFrom(alice, req1Shares);
        assertEq(id0, 0, "req0 is the head");
        assertEq(id1, 1, "req1 is behind it");

        _warpToSettleable();
        // Re-read: requesting does not touch idle liquidity, so this equals the pre-request budget
        // and is exactly what the contract will snapshot on the first chunk.
        snapshotBudget = queue.availableLiquidity();

        // ── chunk 1: fills req0 fully, LATCHES the settlement open ────────────
        queue.closeEpoch(1);
        assertTrue(queue.isSettling(), "settlement latched open across chunks");
        assertEq(queue.head(), id1, "req0 complete, req1 is now the head");
        (, uint256 rem0, uint256 c0,,) = queue.request(id0);
        assertEq(rem0, 0, "req0 fully filled in chunk 1");
        assertGt(c0, 0, "req0 credited");
        uint256 budgetLeft = queue.settlementBudgetRemaining();
        assertEq(budgetLeft + c0, snapshotBudget, "budget remaining + distributed == the snapshot, exactly");

        // ── PUMP: a large fresh mint raises live liquidity far above the snapshot ─
        _mintFromUSDC(bob, 3_000_000e6);
        uint256 livePost = queue.availableLiquidity();
        assertGt(livePost, snapshotBudget, "fresh liquidity genuinely exceeds the latched snapshot");
        assertGt(livePost, snapshotBudget * 2, "and does so by a wide margin (the pump is real)");

        // ── chunk 2: the tail must draw ONLY from the snapshot's remainder ───
        queue.closeEpoch(10);
        (, uint256 rem1, uint256 c1,,) = queue.request(id1);
        assertGt(rem1, 0, "req1 could NOT be completed - the fresh money was invisible to it");
        assertLe(c1, budgetLeft, "req1 drew at most the snapshot's REMAINDER, not the pumped liquidity");

        // The whole settlement distributed no more than the original snapshot, despite live
        // liquidity being >2x larger at close.
        uint256 distributed = c0 + c1;
        assertLe(distributed, snapshotBudget, "SNAPSHOT RATCHET: total distributed <= the one snapshot");
        assertLt(distributed, livePost, "and far below the liquidity actually available at close");
        assertFalse(queue.isSettling(), "settlement completed on the snapshot budget running out");
        assertEq(queue.currentEpoch(), 2, "epoch advanced exactly once");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (F) USDfr DONATION — inert: cannot be stolen, cannot inflate a claim
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK (not run by the sibling suites): dump USDfr straight onto the queue contract
    ///         and try to (i) extract it, or (ii) make a legitimately-filled position claim more
    ///         than it was credited. `claim` pays `r.assetsClaimable`, never `balanceOf(this)`, so
    ///         the donation is inert: it is stranded, unclaimable by anyone, and inflates nothing.
    function test_attack_usdfrDonationCannotBeStolenOrInflateClaims() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 100_000e18);
        uint256 id = _requestFrom(alice, shA);

        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem, uint256 credited,,) = queue.request(id);
        assertEq(rem, 0, "alice's request is fully filled");
        assertGt(credited, 0, "alice is credited a real amount");
        assertEq(usdfr.balanceOf(address(queue)), credited, "queue holds exactly the credited amount");

        // DONATION: bob dumps USDfr onto the queue, hoping to be able to pull it back out, or to
        // pad alice's payout so the excess can be routed somewhere.
        _mintFromUSDC(bob, 200_000e6);
        uint256 donation = 50_000e18;
        vm.prank(bob);
        usdfr.transfer(address(queue), donation);
        assertEq(usdfr.balanceOf(address(queue)), credited + donation, "the queue now over-holds by the donation");

        // (i) The donor cannot recover the donation: he owns no request, and there is no sweep.
        uint256 unknownId = queue.totalRequests();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, unknownId));
        queue.claim(unknownId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, bob));
        queue.claim(id);

        // (ii) The real owner claims EXACTLY the credited amount - the donation does not inflate it.
        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got = queue.claim(id);
        assertEq(got, credited, "claim pays the CREDITED amount, not the queue's inflated balance");
        assertEq(usdfr.balanceOf(alice) - aliceBefore, credited, "owner received exactly what it was owed");

        // The donation is stranded: still in the queue, still unclaimable, accounting intact.
        assertEq(usdfr.balanceOf(address(queue)), donation, "the donation is stuck, benefiting no one");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (B') NO DOUBLE-CLAIM VIA RE-ENTRANCY
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK: a contract owner re-enters `claim` during its own payout to withdraw twice.
    ///         BLOCKED in depth: `claim` is `nonReentrant` AND zeroes `assetsClaimable` before the
    ///         transfer, AND USDfr exposes no recipient callback (its `_update` hook targets the
    ///         PointsModule, never the payee) - so the re-entrant hook never even fires. Proven by
    ///         a single fill received, the re-entry counter at zero, and the second claim reverting.
    function test_attack_reentrantClaimCannotDoubleWithdraw() public onFork {
        ATK_QueueClaimReenterer attacker = new ATK_QueueClaimReenterer();
        compliance.setAllowed(address(attacker), true); // deposit path is KYC-gated on the receiver

        _mintFromUSDC(alice, 1_000_000e6);
        uint256 amt = 100_000e18;
        vm.prank(alice);
        usdfr.transfer(address(attacker), amt);
        uint256 rid = attacker.stakeAndRequest(queue, vault, IERC20(address(usdfr)), amt);

        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(rid);
        assertEq(rem, 0, "attacker's request fully filled");
        assertGt(claimable, 0, "there is a fill to try to double-take");

        uint256 before = usdfr.balanceOf(address(attacker));
        uint256 got = attacker.attackClaim();
        assertEq(got, claimable, "the re-entrant claim path still pays exactly ONE fill");
        assertEq(usdfr.balanceOf(address(attacker)) - before, claimable, "attacker received exactly one fill");
        assertEq(attacker.reenterCount(), 0, "USDfr has no payee callback: the re-entrancy hook never fired");

        // A second, direct claim confirms the position is drained.
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, rid));
        attacker.attackClaim();
        assertEq(usdfr.balanceOf(address(attacker)) - before, claimable, "still exactly one fill after the re-claim");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (G) DUST / UNKNOWN / EMPTY — the griefing and fat-finger surface on the entry points
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice ATTACK: cheap griefing and malformed calls on the permissionless entry points. A
    ///         zero request, a sub-$1 dust request (a FIFO-slot squatter), an unknown-id claim,
    ///         and a claim on a real-but-unfilled request - each must revert with its SPECIFIC
    ///         error, and none may take a queue slot or move value.
    function test_attack_dustEmptyAndUnknownRequestsBlocked() public onFork {
        _mintFromUSDC(alice, 500_000e6);
        uint256 shA = _stake(alice, 100_000e18);

        // zero-size request
        vm.prank(alice);
        vm.expectRevert(IRedemptionQueue.Queue_ZeroAmount.selector);
        queue.requestRedeem(0);

        // sub-$1 dust request: 1 share redeems to 0 assets under the offset-6 vault, below the
        // $1 `minRedemptionValue` floor (C-1 anti-dust-wedge). A cheap FIFO squatter is refused.
        assertEq(vault.convertToAssets(1), 0, "1 share is worth nothing at the realized rate");
        vm.startPrank(alice);
        vault.approve(address(queue), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IRedemptionQueue.Queue_BelowMinRedemption.selector, 0, queue.minRedemptionValue())
        );
        queue.requestRedeem(1);
        vm.stopPrank();

        // no dust ever entered the queue
        assertEq(queue.totalRequests(), 0, "no griefing request took a slot");

        // claim on an unknown id fails loudly
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_UnknownRequest.selector, 0));
        queue.claim(0);

        // a real request that has NOT settled yet has nothing to claim
        uint256 id = _requestFrom(alice, shA);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // helpers (private to this suite; the shared fixture is not modified)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Queue `shares` for `who`, approving out of their own vault balance.
    function _requestFrom(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    /// @dev Warp to the earliest moment the current head can actually settle: past the heartbeat
    ///      AND past the head's ADR-0022 forced cooldown.
    function _warpToSettleable() internal {
        uint256 target = uint256(queue.epochEndsAt());
        uint256 h = queue.head();
        if (h < queue.totalRequests()) {
            uint256 eligibleAt = queue.eligibleToSettleAt(h);
            if (eligibleAt > target) target = eligibleAt;
        }
        if (block.timestamp < target) _warp(target - block.timestamp);
    }
}

/// @dev A contract that owns a redemption request and attempts to re-enter `claim` during its own
///      USDfr payout. USDfr exposes no payee callback, so `receive()` never fires and `reenterCount`
///      stays 0 - the attempt is structurally impossible, on top of the queue's `nonReentrant`
///      guard and effects-first zeroing.
contract ATK_QueueClaimReenterer {
    RedemptionQueue private q;
    uint256 private reqId;
    uint256 public reenterCount;
    bool private inClaim;

    /// @dev Stake `assets` USDfr into the vault as THIS contract, then queue the shares so this
    ///      contract is the request owner. Assumes the USDfr is already held here.
    function stakeAndRequest(RedemptionQueue q_, SUSDfr v_, IERC20 u_, uint256 assets) external returns (uint256) {
        q = q_;
        u_.approve(address(v_), assets);
        uint256 shares = v_.deposit(assets, address(this));
        v_.approve(address(q_), shares);
        reqId = q_.requestRedeem(shares);
        return reqId;
    }

    /// @dev Claim; if USDfr called back into `receive()` mid-transfer, we would re-enter `claim`.
    function attackClaim() external returns (uint256 assets) {
        inClaim = true;
        assets = q.claim(reqId);
        inClaim = false;
    }

    receive() external payable {
        if (inClaim) {
            reenterCount += 1;
            q.claim(reqId); // re-entrant double-claim attempt (never reached on this stack)
        }
    }
}
