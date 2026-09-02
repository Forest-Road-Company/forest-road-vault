// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title EXP3_QueueFork — adversarial assault on the sUSDfr RedemptionQueue (ADR-0010)
/// @notice AUTHORISED pre-audit attack on the owner's own code, on a pinned mainnet fork.
///         Local `forge` only; nothing here broadcasts or moves real value.
///
///         GOAL (every distinct route attempted, outcome made unambiguous):
///           (1) claim ANOTHER holder's filled position;
///           (2) DOUBLE-CLAIM one position — sequentially, across an epoch boundary, via a
///               re-entrant contract owner, AND via a hostile USDfr points module that fires a
///               genuine callback into the queue during the payout;
///           (3) JUMP the strict FIFO ordering (get a request behind the head served first);
///           (4) make the queue DISTRIBUTE MORE than the snapshotted settlement budget /
///               available liquidity — as an outsider (trigger settlement at all) and as the
///               keeper (over-pay an oversized request);
///           (5) CANCEL a request and then re-claim / re-join to double-dip or queue-jump.
///
///         Each attack composes legitimate operations in an unexpected order/time. Where the
///         protocol blocks the attack, the test asserts the SPECIFIC custom error; where it
///         would succeed, it asserts the violated state. On this stack every route is blocked,
///         so the assertions are the reverts — that is the result being proven, not an omission.
///
/// @dev Extends `ForkLifecycleFixture` (the REAL `Deploy.s.sol` topology, real USDC). The
///      harness (`address(this)`) holds `SETTLEMENT_KEEPER_ROLE` and `DEFAULT_ADMIN_ROLE` on the
///      queue AND `DEFAULT_ADMIN_ROLE` on USDfr (testnet `keepOpsAdmin`), so it — and only it —
///      can drive `closeEpoch`/governance and install a points module. Attackers are separate
///      unprivileged actors (`bob`, `carol`, and two bespoke re-entrant contracts).
contract EXP3_QueueForkTest is ForkLifecycleFixture {
    // ─────────────────────────────────────────────────────────────────────
    // (1) CLAIM ANOTHER HOLDER'S POSITION
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: a non-owner tries to sweep a filled request's USDfr. Tried both before a
    ///         fill (owner check must fire regardless of claimable state) and after a fill (the
    ///         value is really sitting there). BLOCKED by the `r.owner != msg.sender` guard.
    function test_attack_cannotClaimAnotherHoldersPosition() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 300_000e18);
        uint256 id = _requestFrom(alice, shA);

        // Route A: steal BEFORE any fill — the owner check precedes the claimable check.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, bob));
        queue.claim(id);

        // Fill the position so there is real value to steal.
        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(id);
        assertEq(rem, 0, "alice's request is fully filled");
        assertGt(claimable, 0, "there is USDfr to steal");

        // Route B: steal AFTER the fill, from two different non-owners.
        uint256 bobBefore = usdfr.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, bob));
        queue.claim(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NotRequestOwner.selector, id, carol));
        queue.claim(id);
        assertEq(usdfr.balanceOf(bob), bobBefore, "the thief received nothing");
        assertEq(usdfr.balanceOf(address(queue)), claimable, "the value is still in queue custody for the owner");

        // The rightful owner still gets exactly their fill.
        uint256 aliceBefore = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got = queue.claim(id);
        assertEq(got, claimable, "owner claims the exact fill");
        assertEq(usdfr.balanceOf(alice) - aliceBefore, claimable, "and receives it");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (2) DOUBLE-CLAIM ONE POSITION
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: extract a position's assets more than once — sequentially and across an
    ///         epoch boundary (claim epoch-1 slice, let epoch-2 add another, then try to re-claim
    ///         the first). BLOCKED: `claim` zeroes `assetsClaimable` (effects-first) before the
    ///         transfer, so a second claim of the SAME assets reverts `Queue_NothingClaimable`.
    ///         A later epoch crediting a NEW slice is legitimate income, not a double-claim; the
    ///         cumulative received can never exceed the cumulative filled.
    function test_attack_cannotDoubleClaimAcrossEpochsOrSequentially() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 500_000e18);
        queue.setEpochLiquidityBps(1); // tiny budget => oversized request fills in slices
        uint256 id = _requestFrom(alice, shA);

        // ── epoch 1: partial fill, claimed once ──────────────────────────
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

        // ── epoch 2: a SECOND slice fills, left initially unclaimed ───────
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem2, uint256 c2,,) = queue.request(id);
        assertGt(c2, 0, "epoch 2 filled another slice");
        assertLt(rem2, rem1, "and consumed more shares");

        // cross-epoch double-claim attempt: claiming now must pay ONLY the new slice c2,
        // never re-pay the already-claimed c1.
        uint256 before2 = usdfr.balanceOf(alice);
        vm.prank(alice);
        uint256 got2 = queue.claim(id);
        assertEq(got2, c2, "claim pays only the NEW slice, not the re-claimed old one");
        assertEq(usdfr.balanceOf(alice) - before2, c2, "exact transfer of the new slice only");

        // and again: drained
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);

        // CONSERVATION: total received == total filled, never more.
        assertEq(got1 + got2, c1 + c2, "cumulative claimed equals cumulative filled - no double extraction");
        assertEq(usdfr.balanceOf(address(queue)), 0, "no unclaimed residue left mis-accounted");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (2b) DOUBLE-CLAIM VIA RE-ENTRANCY — DEFAULT (honest) POINTS MODULE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: a contract owner re-enters `claim` during its own USDfr payout to withdraw
    ///         the fill twice. On the DEFAULT stack this is structurally impossible: USDfr exposes
    ///         no recipient callback — its `_update` points hook targets the protocol PointsModule,
    ///         never the payee — so the re-entrant hook never fires. Proven by: a single fill
    ///         received, the re-entry counter at zero, and the second manual claim reverting
    ///         `NothingClaimable`. The HOSTILE-module variant below fires the callback for real.
    function test_attack_reentrantClaimCannotDoubleWithdraw() public onFork {
        QueueClaimReenterer attacker = new QueueClaimReenterer();
        // KYC the attacker contract on the sanctions gate (defensive; share/USDfr holding is
        // permissionless for a non-sanctioned party either way).
        compliance.setAllowed(address(attacker), true);

        // Fund the attacker with USDfr via a legitimate holder transfer, then it stakes and queues
        // as its OWN account so it is the request owner (claim is owner-gated).
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

        uint256 balBefore = usdfr.balanceOf(address(attacker));
        uint256 got = attacker.attackClaim();
        assertEq(got, claimable, "the re-entrant claim path still pays exactly ONE fill");
        assertEq(usdfr.balanceOf(address(attacker)) - balBefore, claimable, "attacker received exactly one fill");
        assertEq(attacker.reenterCount(), 0, "USDfr has no payee callback: the re-entrancy hook never fired");

        // A second, direct claim confirms the position is drained.
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, rid));
        attacker.attackClaim();
        assertEq(
            usdfr.balanceOf(address(attacker)) - balBefore,
            claimable,
            "still exactly one fill after the failed re-claim"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // (2c) DOUBLE-CLAIM VIA RE-ENTRANCY — HOSTILE USDfr POINTS MODULE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK (stronger): the previous test relies on the DEFAULT points module never
    ///         calling the payee. Here the attacker contract is INSTALLED AS the USDfr points
    ///         module (a legitimate governance act), so the payout transfer inside `claim` DOES
    ///         fire `onUSDfrTransfer` into the attacker — a genuine callback — while the outer
    ///         `claim` is still executing. The re-entrant `claim(reqId)` is nonetheless BLOCKED in
    ///         depth: the queue's `nonReentrant` guard is still held AND `assetsClaimable` was
    ///         already zeroed (effects-first). Proven by: the hook DID fire, the re-entrant claim
    ///         REVERTED, exactly ONE fill was received, and the position is drained.
    ///
    ///         This composes two legitimate operations in an unexpected way (set the points hook,
    ///         then claim through it), which is exactly the class of attack the suite targets.
    function test_attack_reentrantViaHostilePointsModuleStillBlocked() public onFork {
        QueuePointsReenterer attacker = new QueuePointsReenterer(queue);
        compliance.setAllowed(address(attacker), true);

        _mintFromUSDC(alice, 1_000_000e6);
        uint256 amt = 100_000e18;
        vm.prank(alice);
        usdfr.transfer(address(attacker), amt);
        uint256 rid = attacker.stakeAndRequest(vault, IERC20(address(usdfr)), amt);

        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(rid);
        assertEq(rem, 0, "attacker's request fully filled");
        assertGt(claimable, 0, "there is a fill to try to double-take");

        // Install the hostile contract AS the USDfr participation-points module. Now the payout
        // transfer in `claim` will call back into it (the honest module targets the ledger, not
        // the payee). The harness holds USDfr DEFAULT_ADMIN_ROLE under the testnet keepOpsAdmin.
        usdfr.setPointsModule(address(attacker));
        attacker.arm();

        uint256 balBefore = usdfr.balanceOf(address(attacker));
        uint256 got = attacker.attackClaim();

        assertTrue(attacker.reentryFired(), "the hostile hook DID fire on the payout (a genuine callback)");
        assertTrue(attacker.reentryReverted(), "and the re-entrant claim REVERTED (nonReentrant + effects-first)");
        assertFalse(attacker.reentrySucceeded(), "the re-entrant claim never succeeded");
        assertEq(got, claimable, "the outer claim pays exactly ONE fill");
        assertEq(usdfr.balanceOf(address(attacker)) - balBefore, claimable, "received exactly one fill, not two");
        assertEq(usdfr.balanceOf(address(queue)), 0, "no residue: the queue paid out exactly what it held");

        // Position is drained; a manual re-claim reverts (no double-spend by any route).
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, rid));
        attacker.attackClaim();
    }

    // ─────────────────────────────────────────────────────────────────────
    // (3) JUMP THE FIFO ORDERING
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: a small request queued BEHIND a large head tries to be served first (jump
    ///         the queue) by exploiting a tiny per-epoch budget that can never complete the head.
    ///         BLOCKED: settlement walks a strict cursor from `head`; a partial head never
    ///         advances the head, so every later request stays untouched across arbitrarily many
    ///         epochs. The behind-request is not served while the head is incomplete.
    function test_attack_cannotJumpFifoAheadOfAPartialHead() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _mintFromUSDC(bob, 500_000e6);
        uint256 shA = _stake(alice, 400_000e18); // large head
        uint256 shB = _stake(bob, 50_000e18); // small, queued behind

        queue.setEpochLiquidityBps(1); // budget can only ever nibble the head
        uint256 idA = _requestFrom(alice, shA);
        uint256 idB = _requestFrom(bob, shB);
        assertEq(idA, 0, "alice is the head");
        assertEq(idB, 1, "bob is strictly behind");

        // Two full settlement epochs; bob must remain completely untouched both times.
        for (uint256 i = 0; i < 2; ++i) {
            _warpToSettleable();
            queue.closeEpoch(10);

            (, uint256 remA, uint256 cA,,) = queue.request(idA);
            (, uint256 remB, uint256 cB,,) = queue.request(idB);
            assertGt(cA, 0, "the head received a slice");
            assertGt(remA, 0, "the oversized head is still incomplete");
            assertEq(remB, shB, "FIFO: bob's shares are untouched while the head is partial");
            assertEq(cB, 0, "FIFO: bob is credited nothing ahead of the head");
            assertEq(queue.head(), idA, "the head never advances past an incomplete request");
        }

        // Bob cannot claim a jumped fill either (there is none).
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, idB));
        queue.claim(idB);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (4) DISTRIBUTE MORE THAN AVAILABLE LIQUIDITY / THE BUDGET
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK route A: an outsider tries to DRIVE settlement at all (the pre-D7-01
    ///         permissionless surface, where a flash loan could warp the liquidity snapshot).
    ///         BLOCKED: `closeEpoch` is `onlyRole(SETTLEMENT_KEEPER_ROLE)` and the role check
    ///         runs before `whenNotPaused`, so an unprivileged caller can never place the call
    ///         inside their own transaction — asserted for a non-KYC'd, role-less attacker.
    function test_attack_outsiderCannotTriggerSettlement() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 100_000e18);
        _requestFrom(alice, shA);
        _warpToSettleable(); // epoch genuinely over: the block is the ROLE, not the timing

        assertFalse(queue.hasRole(Roles.SETTLEMENT_KEEPER_ROLE, carol), "attacker holds no keeper role");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SETTLEMENT_KEEPER_ROLE
            )
        );
        queue.closeEpoch(10);

        // bob (KYC'd, but still role-less) is equally refused.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, Roles.SETTLEMENT_KEEPER_ROLE
            )
        );
        queue.closeEpoch(10);
    }

    /// @notice ATTACK route B: even the legitimate keeper cannot make the queue pay out MORE than
    ///         the snapshotted budget by queueing a position far larger than the liquidity. The
    ///         oversized request only partially fills, capped by `availableLiquidity()`, and the
    ///         USDfr actually distributed never exceeds the snapshot. This is the §1.3 queue
    ///         invariant "distributed assets never exceed the settlement budget".
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
        assertGt(rem, 0, "the oversized request could not be completed from one budget");
        // BUDGET CEILING (§1.3): never distributes above the snapshot. This is the security
        // invariant; the companion `assertGe` shows the binding budget was actually spent (the cap
        // is not a no-op), with a wide tolerance so wei-scale conservative-rate rounding on
        // `previewRedeem(convertToSharesAtRedemption(budget))` can never fail the test spuriously.
        assertLe(claimable, budget, "never distributes above the snapshot");
        assertGe(claimable, budget - 1e9, "the binding budget was spent down to rounding dust, not left unspent");
        assertEq(usdfr.balanceOf(address(queue)), claimable, "queue holds exactly what it distributed");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds throughout");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (5) CANCEL THEN RE-CLAIM / RE-JOIN
    // ─────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: cancel a queued request to (a) pull shares back and re-join at a better
    ///         FIFO slot, or (b) re-claim after settlement. BLOCKED by absence: the queue exposes
    ///         no cancel path (ADR-0010/0018 — "no cancellation"), the shares are locked in queue
    ///         custody, and the vault refuses every non-queue exit (`_withdraw` is queue-only, and
    ///         `maxRedeem`/`maxWithdraw` report 0 for a holder). A settled request cannot be
    ///         re-claimed. There is therefore no cancel-then-reclaim primitive to abuse.
    function test_attack_noCancelPathToRejoinOrReclaim() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 shA = _stake(alice, 100_000e18);
        uint256 id = _requestFrom(alice, shA);

        // Custody moved to the queue; alice can no longer touch the shares.
        assertEq(vault.balanceOf(alice), 0, "alice no longer holds the shares");
        assertEq(vault.balanceOf(address(queue)), shA, "the queue custodies the shares - no cancel to reverse it");
        assertEq(vault.maxRedeem(alice), 0, "no instant redeem for a holder - the queue is the sole exit");
        assertEq(vault.maxWithdraw(alice), 0, "no instant withdraw for a holder");

        // There is no queue cancel entrypoint; the only vault exit is queue-gated, so alice cannot
        // withdraw the queued shares out from under the FIFO order. (Bare revert: OZ ERC-4626
        // rejects on max-capacity before the queue-only guard is even reached.)
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shA, alice, alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1e18, alice, alice);

        // Settle and claim; the request is now spent and cannot be "cancelled" back into a fresh
        // claim.
        queue.setEpochLiquidityBps(10_000);
        _warpToSettleable();
        queue.closeEpoch(10);
        (, uint256 rem, uint256 claimable,,) = queue.request(id);
        assertEq(rem, 0, "filled in full");
        assertGt(claimable, 0, "assets credited");

        vm.prank(alice);
        assertEq(queue.claim(id), claimable, "claimed once");
        // No re-claim of a settled/'cancelled' position.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_NothingClaimable.selector, id));
        queue.claim(id);

        // Custody is fully released and reconciled: nothing stranded that a cancel could double-spend.
        assertEq(vault.balanceOf(address(queue)), 0, "no queued shares left");
        assertEq(usdfr.balanceOf(address(queue)), 0, "no unclaimed USDfr left");
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this suite; the fixture is not modified)
    // ─────────────────────────────────────────────────────────────────────

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
///      USDfr payout via an ETH-style `receive()` callback. USDfr exposes no payee callback, so
///      `receive()` never fires and `reenterCount` stays 0 — the attempt is structurally
///      impossible, on top of the queue's `nonReentrant` guard and effects-first zeroing.
contract QueueClaimReenterer {
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

/// @dev A contract that owns a redemption request AND is installed as the USDfr points module, so
///      the payout transfer inside `claim` fires `onUSDfrTransfer` into it — a REAL callback,
///      unlike the ETH `receive()` route above. It uses that callback to re-enter `claim`. Both
///      the queue's `nonReentrant` guard and its effects-first `assetsClaimable = 0` block the
///      double-spend; the re-entrant call reverts and is swallowed by USDfr's fail-open hook
///      wrapper, so the outer claim still pays exactly one fill.
contract QueuePointsReenterer {
    RedemptionQueue private immutable q;
    uint256 private reqId;
    bool private armed;
    bool public reentryFired;
    bool public reentryReverted;
    bool public reentrySucceeded;

    constructor(RedemptionQueue q_) {
        q = q_;
    }

    /// @dev Stake `assets` USDfr into the vault as THIS contract and queue the shares (owner-gated
    ///      claim requires this contract to be the request owner). USDfr already held here.
    function stakeAndRequest(SUSDfr v_, IERC20 u_, uint256 assets) external returns (uint256) {
        u_.approve(address(v_), assets);
        uint256 shares = v_.deposit(assets, address(this));
        v_.approve(address(q), shares);
        reqId = q.requestRedeem(shares);
        return reqId;
    }

    function arm() external {
        armed = true;
    }

    function attackClaim() external returns (uint256 assets) {
        assets = q.claim(reqId);
    }

    /// @dev The USDfr participation-points hook (`IPointsModule.onUSDfrTransfer`). It fires inside
    ///      the payout transfer of the OUTER `claim`, while that call's `nonReentrant` guard is
    ///      still held and `assetsClaimable` has already been zeroed. The re-entrant claim must
    ///      revert; if it ever returned, the position would have been double-spent.
    function onUSDfrTransfer(address, address, uint256) external {
        if (!armed) return;
        armed = false; // one-shot: no unbounded recursion
        reentryFired = true;
        try q.claim(reqId) returns (uint256) {
            reentrySucceeded = true; // a double-spend — must never happen
        } catch {
            reentryReverted = true; // expected: nonReentrant + effects-first
        }
    }
}
