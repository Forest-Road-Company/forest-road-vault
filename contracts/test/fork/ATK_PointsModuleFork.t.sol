// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";

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

    /// @dev Mirror of `ReserveRoundingLib.AccrualRoundingAllocated` for `vm.expectEmit`: the
    ///      reserve's per-layer record of one sub-native-unit closure correction (ADR-0038).
    event AccrualRoundingAllocated(
        uint256 indexed facilityId,
        uint64 indexed closureNonce,
        uint256 amount,
        uint256 prepaid,
        uint256 curator,
        uint256 backstop,
        uint256 senior,
        uint256 unabsorbed,
        uint256 markConsumed
    );

    // ── ADR-0038 closure figures for the fixture's facility shape ─────────
    // The fixture note is fixed 1400 bps, Actual/360 (31,104,000 s per year), USDC grid 1e12,
    // maturity funded + 365 days, no PIK. ADR/0038-continuous-interest-accrual-to-susdfr.md,
    // "Implementation mechanism and checkpoint, 2026-09-11": "Maturity or earlier default
    // declaration stops earning." The declaration closes the streamed segment and reconciles the
    // interpolated recognition E against the grid-floored canonical interest C
    // (docs/remediation/accrual-panel/LIFECYCLE_ACCOUNTING_2026-09-11.md, lines 51-57); an excess
    // E - C is a rounding shortfall charged through Ethereum's native order, curator then sGROVE
    // then senior (CONTINUOUS_ACCRUAL_OWNER_DIRECTIONS_2026-09-11.md, lines 48-49;
    // ACCRUAL_BUILD_LOG_2026-09-12.md, "WP3f/WP4: rounding continuation and ordered correction";
    // LIFECYCLE_ACCOUNTING_2026-09-11.md, lines 182-189). `_adr0038Closure` below is the
    // closed-form derivation; every constant here is asserted equal to it by the test that uses it.
    //   4e23 facility, day 30:  recognized 4,666,666,666,636,563,503,188
    //                           canonical  4,666,666,666,000,000,000,000
    //                           dust               636,563,503,188   (below 1e12, one USDC unit)
    uint256 internal constant DUST_4E23_30D = 636_563_503_188;
    // PointsModule `_recordCuratorLoss` folds WAD * after / before into the class survival factor,
    // compounded: WAD * (2e23 - dust) / 2e23 = 999,999,999,996,817,182 at the dust epoch, then
    // times (1e23 - dust) / (2e23 - dust) at the real loss.
    uint256 internal constant SURV_2E23_DUST_1E23 = 499_999_999_996_817_182;
    // `_applyCuratorDilution` writes a checkpointed cache to bal * survival / WAD, truncated to the
    // wei: 2e23 * SURV / WAD, which sits 96,812 wei under the live pool of 99,999,999,999,363,436,496,812.
    uint256 internal constant CACHE_2E23_DUST_1E23 = 99_999_999_999_363_436_400_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant NOTE_RATE_BPS = 1400;
    uint256 internal constant NOTE_YEAR_SECONDS = 31_104_000; // Actual/360
    uint256 internal constant NOTE_GRID = 1e12; // one USDC unit in 18-decimal USDfr
    uint256 internal constant NOTE_TENOR = 365 days;

    /// @dev Grid-floored simple interest on the fixture note (AccrualMath.periodAmount with the
    ///      full-year grid cap, which is not binding before maturity).
    function _noteGrid(uint256 principal, uint256 elapsed) internal pure returns (uint256 x) {
        x = (principal * NOTE_RATE_BPS * elapsed) / (10_000 * NOTE_YEAR_SECONDS);
        x -= x % NOTE_GRID;
    }

    /// @dev Closed-form ADR-0038 closure `elapsed` seconds after funding, mirroring the engine
    ///      independently. AccrualSegments.plan ends the first technical segment one second before
    ///      the instant the whole-grid cap is attained (capHit - 1); AccrualBook.open streams that
    ///      segment at the integer slope amount / duration; AccrualBook.reconcile credits the
    ///      mulDiv remainder at the closure instant; AccrualLoans._close compares the recognized
    ///      total with cumulative(terms, at) and reports E - C as `roundingLoss` when positive.
    function _adr0038Closure(uint256 principal, uint256 elapsed)
        internal
        pure
        returns (uint256 recognized, uint256 canonical)
    {
        uint256 gridCap = _noteGrid(principal, NOTE_TENOR);
        uint256 den = principal * NOTE_RATE_BPS;
        uint256 capHit = (gridCap * 10_000 * NOTE_YEAR_SECONDS + den - 1) / den; // Rounding.Ceil
        uint256 end = NOTE_TENOR;
        if (capHit > 1) --capHit;
        if (capHit < end) end = capHit;
        uint256 segment = _noteGrid(principal, end);
        recognized = (segment / end) * elapsed + ((segment % end) * elapsed) / end;
        canonical = _noteGrid(principal, elapsed);
    }

    /// @dev The fixture's evidence-bound declaration with the ADR-0038 closure pinned inside the
    ///      same call: the reserve must emit `AccrualRoundingAllocated` for closure nonce 1 with
    ///      the whole `dust` charged to layer 1 (curator) and nothing to the prepaid mark, sGROVE,
    ///      senior or the unabsorbed remainder. `vm.expectEmit` sits immediately before the
    ///      declaration because the fixture's attest call would otherwise be the call under watch.
    function _declareDefaultPinningDust(uint256 tokenId, uint256 dust) internal {
        _attest(tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(tokenId, bytes32(0))));
        vm.expectEmit(true, true, false, true, address(reserves));
        emit AccrualRoundingAllocated(tokenId, 1, dust, 0, dust, 0, 0, 0, 0);
        vm.prank(ops);
        defaultManager.declareDefault(tokenId, bytes32(0));
    }

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

    /// @notice (I2b) A permissionless `checkpoint` cannot lift a curator loss freeze (H-03), driven
    ///         through a REAL attested default and the production cascade.
    /// @dev ADR-0038 makes the declaration itself the first curator loss. Thirty days of streamed
    ///      recognition exceed the grid-floored canonical coupon by `DUST_4E23_30D`, and the reserve
    ///      charges that excess through the native order, curator first: ADR/0038, "Implementation
    ///      mechanism and checkpoint, 2026-09-11" ("Maturity or earlier default declaration stops
    ///      earning"); CONTINUOUS_ACCRUAL_OWNER_DIRECTIONS_2026-09-11.md lines 48-49 ("Ethereum
    ///      uses curator, sGROVE, then senior"); ACCRUAL_BUILD_LOG_2026-09-12.md, "WP3f/WP4:
    ///      rounding continuation and ordered correction"; accrual-panel/
    ///      LIFECYCLE_ACCOUNTING_2026-09-11.md lines 51-57 and 182-189. The test pins that closure
    ///      exactly (the per-layer event, the pool, epoch 0, the compounded survival factor) and
    ///      then the 1e23 loss on the already-diluted pool. Before ADR-0038 nothing accrued between
    ///      funding and declaration, so the old `poolBalance == 1e23` figure was the stale design.
    ///      That the sub-unit correction registers as a curator loss epoch is current behaviour,
    ///      recorded as an open owner question in the 2026-09-15 fork triage (C4, RC-C4-2).
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

        // ADR-0038: the closure figure, derived in closed form here and pinned to the constant.
        uint256 dust;
        {
            (uint256 recognized, uint256 canonical) = _adr0038Closure(4e23, 30 days);
            dust = recognized - canonical;
            assertEq(dust, DUST_4E23_30D, "closed-form ADR-0038 closure dust for 4e23 at day 30");
            assertLt(dust, NOTE_GRID, "a closure correction is strictly below one native unit (AccrualLoans._close)");
            assertEq(
                reserves.accruedDebt(tokenId).interest, canonical, "the contractual coupon is the canonical figure"
            );
        }

        // A real, attested default. The declaration stops the segment and charges the dust to
        // layer 1; the helper pins the per-layer event (curator = dust, backstop 0, senior 0,
        // unabsorbed 0, prepaid 0).
        _declareDefaultPinningDust(tokenId, dust);
        assertEq(
            curator.poolBalance(classId),
            2e23 - dust,
            "ADR-0038: sub-unit closure correction charged to layer 1 at declaration"
        );
        assertEq(reserves.roundingLossUnabsorbed(), 0, "nothing fell through the cascade");
        assertEq(points.curatorLossEpochCount(classId), 1, "the dust correction is curator loss epoch 0");

        // Then a cascade loss of half the ORIGINAL first-loss pool, on the already-diluted pool.
        _realizeLoss(tokenId, 1e23, bytes32(0));
        assertEq(
            curator.poolBalance(classId), 2e23 - dust - 1e23, "layer 1 absorbed exactly the loss on top of the dust"
        );
        assertEq(points.curatorLossEpochCount(classId), 2, "dust epoch 0 plus the real loss epoch 1");
        uint64 lossAt = points.curatorLossAt(classId, 0);
        assertEq(lossAt, uint64(block.timestamp), "epoch 0 is the declaration instant");
        assertEq(points.curatorLossAt(classId, 1), lossAt, "the real loss shares the declaration instant");
        uint256 survival;
        {
            // PointsModule._recordCuratorLoss: WAD * after / before, compounded over both epochs.
            uint256 survivalDust = WAD * (2e23 - dust) / 2e23;
            survival = survivalDust * (2e23 - dust - 1e23) / (2e23 - dust);
            assertEq(survival, SURV_2E23_DUST_1E23, "closed-form compounded survival factor");
            (uint64 round, uint256 survivalWad) = points.curatorDilutionState(classId);
            assertEq(round, 0, "both ratios were usable: no distrust round");
            assertEq(survivalWad, survival, "survival compounds the dust epoch and the real loss");
        }

        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "position is frozen by the un-reconciled loss");
        assertEq(frozenAt, lossAt, "pinned at the first unseen epoch: the declaration instant");
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
        // `_applyCuratorDilution` writes bal * survival / WAD, truncated to the wei, so the cache
        // lands 96,812 wei under the live pool and never above it.
        assertEq(2e23 * survival / WAD, CACHE_2E23_DUST_1E23, "closed-form WAD-truncated cache");
        assertEq(
            points.curatorTracked(alice, classId),
            CACHE_2E23_DUST_1E23,
            "cache written down by the compounded survival factor, not up"
        );
        assertLe(
            points.curatorTracked(alice, classId),
            curator.postedOf(classId, alice),
            "never above the live posted amount"
        );

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
        assertEq(curator.postedOf(classId, alice), 2e23 - dust - 1e23, "alice is the only curator: posted == pool");

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
    //      capital's matured ramp: the two H-03 harms. Both must be refused.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice (I3) A curator who absorbs a loss and tops back up can neither escape the freeze on
    ///         the fresh capital nor have it inherit the destroyed capital's maturity ramp (H-03).
    /// @dev Under ADR-0038 the declaration charges `DUST_4E23_30D` to the curator pool before the
    ///      1e23 loss (citations on the sibling test above), so a 1e23 top-up restores the notional
    ///      to 2e23 - dust, not 2e23: the pool was diluted twice (2e23 -> 2e23 - dust -> 1e23 - dust)
    ///      and the re-post adds exactly 1e23 to the diluted position. Epoch 0 is the dust epoch at
    ///      the declaration instant; the real loss is epoch 1 at the same timestamp, so the freeze
    ///      ceiling is unchanged. Before ADR-0038 nothing accrued between funding and declaration
    ///      and the old `postedOf == 2e23` figure held; it is the stale design.
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

        // ADR-0038: the closure figure, derived in closed form here and pinned to the constant.
        uint256 dust;
        {
            (uint256 recognized, uint256 canonical) = _adr0038Closure(4e23, 30 days);
            dust = recognized - canonical;
            assertEq(dust, DUST_4E23_30D, "closed-form ADR-0038 closure dust for 4e23 at day 30");
        }
        // The declaration charges the dust to layer 1 (per-layer event pinned inside the helper).
        _declareDefaultPinningDust(tokenId, dust);
        assertEq(curator.poolBalance(classId), 2e23 - dust, "ADR-0038: dust charged to layer 1 at declaration");
        _realizeLoss(tokenId, 1e23, bytes32(0)); // dilute (2e23 - dust) -> (1e23 - dust)
        assertEq(
            curator.poolBalance(classId), 2e23 - dust - 1e23, "layer 1 absorbed exactly the loss on top of the dust"
        );
        assertEq(points.curatorLossEpochCount(classId), 2, "dust epoch 0 plus the real loss epoch 1");
        assertEq(
            points.curatorLossAt(classId, 1), points.curatorLossAt(classId, 0), "both epochs at the declaration instant"
        );
        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "frozen by the loss");
        assertEq(points.curatorPointsInClass(alice, classId), earned, "pre-loss window banked");

        // ── ATTACK: top back up by the lost 1e23 (posting is NOT freeze-gated) ──
        vm.startPrank(alice);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(classId, 1e23);
        vm.stopPrank();
        assertEq(
            curator.postedOf(classId, alice),
            2e23 - dust,
            "notional restored to the pre-loss 2e23 less the ADR-0038 dust charged at declaration"
        );
        // The cache was diluted to the WAD-truncated 2e23 * survival / WAD, then topped by the
        // difference to the live posted amount (`onCuratorStakeChange` tracks newPosted - old).
        assertEq(
            points.curatorTracked(alice, classId),
            curator.postedOf(classId, alice),
            "cache is the live posted amount, not the stale-high pre-loss balance"
        );

        // (a) The top-up came off a NON-zero (merely diluted) cache, so it does NOT clear the
        //     freeze: the fresh capital is frozen too, and earns nothing.
        (frozen, frozenAt) = points.curatorFreezeStatus(alice, classId);
        assertTrue(frozen, "ATTACK BLOCKED: topping up from a diluted position does NOT clear the freeze");
        assertEq(frozenAt, points.curatorLossAt(classId, 0), "ceiling still pinned at the first unseen epoch");
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

        // (b) Thaw, then measure: the restored 2e23 - dust must NOT accrue as if it had been
        //     posted at t0. Compare it against a control curator (bob) who posts a FRESH 2e23
        //     right now (dust more than alice, so the comparison is not tilted in her favour).
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

        // Let the two live notionals (alice 2e23 - dust restored, bob 2e23 fresh) run the same window.
        _warp(30 days);
        uint256 aliceGain = points.curatorPointsInClass(alice, classId) - aliceThaw;
        uint256 bobGain = points.curatorPointsInClass(bob, classId) - bobStart;
        assertGt(aliceGain, 0, "alice's surviving+restored capital accrues after thaw");
        assertGt(bobGain, 0, "the fresh control accrues too");
        // The surviving part of alice's stake keeps its ORIGINAL (older) maturity anchor, so on
        // (dust short of) equal notional over an equal window alice earns at least as much as a
        // brand-new post, never LESS. The exploit would be the reverse: replacement capital riding
        // the old ramp to out-earn while ALSO having escaped the loss. That is refused above (it
        // earned zero while frozen); here we simply confirm the post-thaw accrual is well-defined
        // and bounded, with both positions live and neither inheriting phantom points.
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
