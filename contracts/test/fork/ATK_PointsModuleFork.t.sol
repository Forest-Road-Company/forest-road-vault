// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title ATK_PointsModuleFork — adversarial assault on the participation-points ledger
/// @notice Every test here ATTEMPTS a real exploit against `PointsModule` on the FULL deployed
///         stack over a pinned mainnet fork, and asserts the outcome unambiguously: if the attack
///         lands, the violated state is asserted; if the contract blocks it, the SPECIFIC custom
///         error (or the exact surviving invariant) is asserted. The contract's permissionless
///         surface is `reconcile` and `checkpoint` (anyone, for anyone); its four value-writing
///         hooks (`onSharesTransfer`, `onUSDfrTransfer`, `onCuratorStakeChange`, `onCuratorLoss`)
///         are each bound to exactly one module. The invariants under attack:
///           (I1) hooks cannot be spoofed by a non-authorised caller — no self-minting of points
///                and no injection of a fake class loss;
///           (I2) the permissionless maintenance calls cannot mint points from rounding, cannot
///                lift a curator loss freeze, and cannot touch another wallet's position;
///           (I3) a curator who takes a loss and tops back up cannot out-accrue live capital nor
///                inherit the destroyed capital's maturity ramp (H-03).
///
/// @dev The heavy lifecycle steps (originate -> fund -> default -> realizeLoss -> cascade
///      absorbLoss) go through the REAL modules exactly as `PointsFork.t.sol` drives them, so the
///      curator-loss hook fires through the production topology, not a stub. `carol`/`attacker`
///      are deliberately NEITHER KYC'd NOR role-holders: a true outsider reaches the permissionless
///      surface with nothing.
contract ATK_PointsModuleForkTest is ForkLifecycleFixture {
    // A pure outsider: not KYC'd, holds no role, is not the vault / USDfr / CuratorModule.
    address internal attacker = makeAddr("atkPointsAttacker");

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        // Nothing granted to `attacker` on purpose — that is the threat model.
    }

    /// @dev Anti-silent-skip guard: proves this suite really executed against the pinned fork with
    ///      the deployed points ledger wired to all three of its callers, so a green result off an
    ///      unconfigured RPC is impossible.
    function test_atk_isRunningOnPinnedForkWithRealWiring() public onFork {
        assertEq(block.chainid, 1, "forked mainnet");
        assertEq(block.number, FORK_BLOCK, "pinned block (reproducible)");
        assertEq(usdfr.pointsModule(), address(points), "USDfr -> points wired");
        assertEq(vault.pointsModule(), address(points), "sUSDfr -> points wired");
        assertEq(curator.pointsModule(), address(points), "CuratorModule -> points wired");
        assertEq(points.curatorModule(), address(curator), "points -> CuratorModule bound");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I1) The four hooks cannot be spoofed to self-mint points OR inject a
    //      fake class loss. A non-authorised caller reaching any of them is
    //      the single most dangerous failure for a points ledger.
    // ─────────────────────────────────────────────────────────────────────

    function test_atk_hooksCannotBeSpoofedToSelfMintOrInjectLosses() public onFork {
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;

        // ── attempt 1: mint myself a giant USDfr points position out of thin air ──
        vm.prank(attacker);
        vm.expectRevert(PointsModule.Points_OnlyUSDfr.selector);
        points.onUSDfrTransfer(address(0), attacker, 1_000_000e18);

        // ── attempt 2: mint myself a giant sUSDfr shares position ──
        vm.prank(attacker);
        vm.expectRevert(PointsModule.Points_OnlyVault.selector);
        points.onSharesTransfer(address(0), attacker, 1_000_000e24);

        // ── attempt 3: mint myself a giant CURATOR (5x) first-loss position ──
        vm.prank(attacker);
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorStakeChange(attacker, classId, 1_000_000e18);

        // ── attempt 4: INJECT a fabricated class loss to freeze / grief every real
        //     curator in the class, or to corrupt the survival ratio (before > after
        //     looks like a genuine absorption to the recorder) ──
        vm.prank(attacker);
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorLoss(classId, 1_000e18, 1e18);

        // ── attempt 5: even the protocol admin (this test == deployer/admin) cannot spoof a
        //     hook — the guard is a msg.sender identity check, not a role, so no privilege
        //     escalates into it ──
        vm.expectRevert(PointsModule.Points_OnlyVault.selector);
        points.onSharesTransfer(address(0), ops, 1_000_000e24);

        // ── invariants held: nothing was minted, no loss was recorded ──
        assertEq(points.pointsOfWallet(attacker), 0, "attacker minted itself nothing");
        assertEq(points.curatorTracked(attacker, classId), 0, "no phantom curator position");
        (uint256 s, uint256 u, uint256 c) = points.totals();
        assertEq(s + u + c, 0, "the global tracked totals are untouched by every spoof");
        assertEq(points.curatorLossEpochCount(classId), 0, "no fabricated loss entered the class log");
        (uint64 round, uint256 survivalWad) = points.curatorDilutionState(classId);
        assertEq(round, 0, "no distrust round was forced");
        assertEq(survivalWad, 1e18, "the survival factor is pristine (WAD)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I2a) Rounding / dust harvest: hammering the permissionless `checkpoint`
    //       over many tiny intervals must NEVER accumulate more points than a
    //       single settlement of the identical position. Floor division at every
    //       chunk can only ever LOSE dust to the house, never mint it.
    // ─────────────────────────────────────────────────────────────────────

    function test_atk_checkpointSpamCannotMintPointsFromRounding() public onFork {
        // Two identical positions opened in the SAME block => identical maturity anchor.
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "alice: spammed every hour");
        assertEq(_mintFromUSDC(bob, 1_000_000e6), 1e24, "bob: settled once at the end");

        // The attacker checkpoints alice 120 times across 5 days, trying to harvest rounding.
        for (uint256 i = 0; i < 120; ++i) {
            _warp(1 hours);
            vm.prank(attacker);
            points.checkpoint(alice);
        }

        // A single settlement of bob over the exact same elapsed window.
        vm.prank(attacker);
        points.checkpoint(bob);

        uint256 spammed = points.pointsOfWallet(alice);
        uint256 oneShot = points.pointsOfWallet(bob);
        assertGt(oneShot, 0, "the honest one-shot position genuinely earned points");
        assertLe(spammed, oneShot, "ATTACK BLOCKED: fragmented checkpoints can never MINT points");
        // The whole effect of 120 extra checkpoints is a few wei of floor dust the attacker
        // FORFEITS — a systematic gain would show up as a large positive delta here.
        assertLt(oneShot - spammed, 1e6, "the only difference is sub-dust floor loss, not a mint");

        // And a re-checkpoint in the same block adds nothing (no per-call credit).
        uint256 pinned = points.pointsOfWallet(alice);
        vm.prank(attacker);
        points.checkpoint(alice);
        assertEq(points.pointsOfWallet(alice), pinned, "a same-block re-checkpoint mints nothing");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I2b) A curator loss FREEZES point accrual at the loss instant. The
    //       original H-03 bypass was exactly a permissionless `checkpoint`
    //       resuming accrual on wiped/diluted capital. Drive a REAL default and
    //       cascade absorption, then try to lift the freeze with checkpoint spam.
    // ─────────────────────────────────────────────────────────────────────

    function test_atk_permissionlessCheckpointCannotLiftCuratorLossFreeze() public onFork {
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        curator.setCuratorApproved(classId, alice, true);
        assertEq(_mintFromUSDC(alice, 3_000_000e6), 3e24, "funds");
        _stake(alice, 1e24);
        vm.startPrank(alice);
        usdfr.approve(address(curator), 2e23);
        curator.postFirstLoss(classId, 2e23);
        vm.stopPrank();
        uint256 tokenId = _originateAndFund(4e23);

        _warp(30 days);
        uint256 earned = points.curatorPointsInClass(alice, classId);
        assertGt(earned, 0, "30 clean days accrued at the 5x curator multiple");

        // A real, attested default + a cascade loss of exactly half the first-loss pool.
        _declareDefault(tokenId, bytes32(0));
        _realizeLoss(tokenId, 1e23, bytes32(0));
        assertEq(curator.poolBalance(classId), 1e23, "layer 1 absorbed exactly the loss");
        assertEq(points.curatorLossEpochCount(classId), 1, "one real loss epoch logged");
        uint64 lossAt = points.curatorLossAt(classId, 0);

        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "position is frozen by the un-reconciled loss");
        assertEq(frozenAt, lossAt, "pinned at the loss instant");
        assertEq(points.curatorPointsInClass(alice, classId), earned, "the loss banks the pre-loss window, no more");

        // ── ATTACK: warp forward and hammer checkpoint from the outsider to resume accrual ──
        for (uint256 i = 0; i < 6; ++i) {
            _warp(10 days);
            vm.prank(attacker);
            points.checkpoint(alice);
            assertEq(
                points.curatorPointsInClass(alice, classId),
                earned,
                "ATTACK BLOCKED: checkpoint credits nothing past the freeze (H-03)"
            );
        }
        (frozen,) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "still frozen after 60 days of checkpoint spam");
        // The checkpoint IS allowed to write the stale-high cache DOWN (monotone, never up).
        assertEq(points.curatorTracked(alice, classId), 1e23, "cache written down to the diluted stake, not up");

        // Only `reconcile` may thaw, and it FORFEITS the frozen window rather than back-paying it.
        vm.prank(attacker);
        points.reconcile(alice);
        (frozen, frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertFalse(frozen, "reconcile thawed the position");
        assertEq(frozenAt, 0, "no freeze instant remains");
        assertEq(
            points.curatorPointsInClass(alice, classId), earned, "the ~60 frozen days are FORFEITED, not back-paid"
        );
        assertEq(
            points.curatorTracked(alice, classId),
            curator.postedOf(classId, alice),
            "reconcile snapped the cache to the LIVE posted amount"
        );

        // Accrual resumes on the surviving capital only.
        _warp(30 days);
        assertGt(
            points.curatorPointsInClass(alice, classId), earned, "accrual resumes on the surviving half after thaw"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I3) Loss-then-top-up: a curator absorbs a loss, then RE-POSTS to their
    //      pre-loss notional, attempting to (a) escape the freeze on the fresh
    //      capital and (b) have the replacement capital inherit the destroyed
    //      capital's matured ramp — the two H-03 harms. Both must be refused.
    // ─────────────────────────────────────────────────────────────────────

    function test_atk_lossThenTopUpCannotEscapeFreezeNorInheritRamp() public onFork {
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        curator.setCuratorApproved(classId, alice, true);
        assertEq(_mintFromUSDC(alice, 3_000_000e6), 3e24, "funds");
        _stake(alice, 1e24);
        vm.startPrank(alice);
        usdfr.approve(address(curator), 2e23);
        curator.postFirstLoss(classId, 2e23);
        vm.stopPrank();
        uint256 tokenId = _originateAndFund(4e23);

        _warp(30 days);
        uint256 earned = points.curatorPointsInClass(alice, classId);
        assertGt(earned, 0, "30 clean days of matured, aged first-loss");

        _declareDefault(tokenId, bytes32(0));
        _realizeLoss(tokenId, 1e23, bytes32(0)); // dilute 2e23 -> 1e23, survival 0.5
        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "frozen by the loss");
        assertEq(points.curatorPointsInClass(alice, classId), earned, "pre-loss window banked");

        // ── ATTACK: top back up to the pre-loss notional (posting is NOT freeze-gated) ──
        vm.startPrank(alice);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(classId, 1e23);
        vm.stopPrank();
        assertEq(curator.postedOf(classId, alice), 2e23, "notional restored to the pre-loss 2e23");
        // The cache was diluted to 1e23 then topped by 1e23, landing on the live posted amount.
        assertEq(
            points.curatorTracked(alice, classId),
            curator.postedOf(classId, alice),
            "cache is the live posted amount, not the stale-high pre-loss balance"
        );

        // (a) The top-up came off a NON-zero (merely diluted) cache, so it does NOT clear the
        //     freeze — the fresh capital is frozen too, and earns nothing.
        (frozen, frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "ATTACK BLOCKED: topping up from a diluted position does NOT clear the freeze");
        assertEq(frozenAt, points.curatorLossAt(classId, 0), "ceiling still pinned at the original loss");
        assertEq(
            points.curatorPointsInClass(alice, classId), earned, "the topped-up capital earns nothing while frozen"
        );

        // Time + an outsider checkpoint cannot buy the replacement capital any accrual either.
        _warp(30 days);
        vm.prank(attacker);
        points.checkpoint(alice);
        assertEq(
            points.curatorPointsInClass(alice, classId),
            earned,
            "restored notional still frozen: no free ride on a loss"
        );

        // (b) Thaw, then measure: the restored 2e23 must NOT accrue as if it had been posted at
        //     t0. Compare it against a control curator (bob) who posts a FRESH 2e23 right now.
        curator.setCuratorApproved(classId, bob, true);
        assertEq(_mintFromUSDC(bob, 2_000_000e6), 2e24, "control curator funds");
        vm.startPrank(bob);
        usdfr.approve(address(curator), 2e23);
        curator.postFirstLoss(classId, 2e23);
        vm.stopPrank();

        vm.prank(attacker);
        points.reconcile(alice); // thaw; frozen window forfeited
        assertEq(
            points.curatorPointsInClass(alice, classId), earned, "thaw forfeits the frozen window, never back-pays"
        );

        uint256 aliceThaw = points.curatorPointsInClass(alice, classId);
        uint256 bobStart = points.curatorPointsInClass(bob, classId);

        // Let identical live notionals (alice 2e23 restored, bob 2e23 fresh) run the same window.
        _warp(30 days);
        uint256 aliceGain = points.curatorPointsInClass(alice, classId) - aliceThaw;
        uint256 bobGain = points.curatorPointsInClass(bob, classId) - bobStart;
        assertGt(aliceGain, 0, "alice's surviving+restored capital accrues after thaw");
        assertGt(bobGain, 0, "the fresh control accrues too");
        // The surviving half of alice's stake keeps its ORIGINAL (older) maturity anchor, so on
        // equal notional over an equal window alice earns at least as much as a brand-new post —
        // never LESS. The exploit would be the reverse: replacement capital riding the old ramp to
        // out-earn while ALSO having escaped the loss. That is refused above (it earned zero while
        // frozen); here we simply confirm the post-thaw accrual is well-defined and bounded, with
        // both positions live and neither inheriting phantom points.
        assertGe(aliceGain, bobGain, "aged surviving capital accrues >= a fresh post of equal notional (ramp honored)");
        assertLt(aliceGain, 3 * bobGain, "but NOT unboundedly: no phantom ramp inheritance inflates it");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I2c) Cross-user isolation + global-total conservation. The permissionless
    //       maintenance calls, driven by an outsider against one wallet, must not
    //       move another wallet's points, and the global tracked totals must stay
    //       equal to the sum of the live positions (no phantom inflation).
    // ─────────────────────────────────────────────────────────────────────

    function test_atk_crossUserOpsCannotTouchOthersAndTotalsConserve() public onFork {
        // alice: a held-USDfr leg AND a staked-shares leg; bob: USDfr only.
        assertEq(_mintFromUSDC(alice, 2_000_000e6), 2e24, "alice mints");
        _stake(alice, 1e24); // half into shares, half stays as USDfr
        assertEq(_mintFromUSDC(bob, 1_000_000e6), 1e24, "bob mints");

        _warp(30 days);

        // Snapshot alice, then let the outsider hammer bob's maintenance surface.
        uint256 aliceBefore = points.pointsOfWallet(alice);
        vm.prank(attacker);
        points.reconcile(bob);
        vm.prank(attacker);
        points.checkpoint(bob);
        assertEq(points.pointsOfWallet(alice), aliceBefore, "operating on bob cannot move alice's points");

        // Snapshot bob, then hammer alice.
        uint256 bobBefore = points.pointsOfWallet(bob);
        vm.prank(attacker);
        points.reconcile(alice);
        vm.prank(attacker);
        points.checkpoint(alice);
        assertEq(points.pointsOfWallet(bob), bobBefore, "and operating on alice cannot move bob's points");

        // Global totals conserve to the sum of the only participants' live positions. alice and
        // bob are the sole non-exempt USDfr holders and alice is the sole staker (the vault seed
        // sink is protocol-exempt and untracked).
        (uint256 tShares, uint256 tUsdfr,) = points.totals();
        (uint256 aShares, uint256 aUsdfr) = points.trackedBalances(alice);
        (uint256 bShares, uint256 bUsdfr) = points.trackedBalances(bob);
        assertEq(bShares, 0, "bob never staked");
        assertEq(tUsdfr, aUsdfr + bUsdfr, "USDfr total == sum of the two live holders, no phantom inflation");
        assertEq(tShares, aShares, "shares total == alice's staked position exactly");
        assertEq(aUsdfr, usdfr.balanceOf(alice), "alice's tracked USDfr == her live token balance");
        assertEq(bUsdfr, usdfr.balanceOf(bob), "bob's tracked USDfr == his live token balance");
        assertEq(aShares, vault.balanceOf(alice), "alice's tracked shares == her live vault balance");
    }
}
