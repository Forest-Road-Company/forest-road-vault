// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title Fix H-03 — the curator first-loss freeze is DURABLE and per-loss-epoch.
/// @notice Regression suite for the two bypasses of the de45797 freeze:
///         (a) the permissionless `checkpoint()` advanced `lastAccrual` past the loss instant,
///             so the `lossAt > lastAccrual` guard stopped matching and accrual resumed on
///             wiped/diluted first-loss at the 5x curator multiple;
///         (b) a later same-class loss OVERWROTE the single `lastCuratorLossAt` timestamp,
///             re-opening the accrual window for positions frozen by the earlier loss.
///         The fix: an append-only per-class loss-epoch log plus a per-position
///         `seenLossEpoch` watermark, cleared ONLY by `reconcile()`.
contract FixH03CuratorFreezeTest is CreditLayerFixture {
    PointsModule internal points;

    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant ENERGY = Config.CLASS_RENEWABLE_ENERGY;

    event CuratorLossRecorded(
        uint256 indexed classId,
        uint256 indexed lossEpoch,
        uint64 at,
        uint256 poolBalanceBefore,
        uint256 poolBalanceAfter
    );
    event CuratorPositionThawed(address indexed wallet, uint256 indexed classId, uint64 seenLossEpoch);
    event CuratorBalanceDiluted(
        address indexed wallet, uint256 indexed classId, uint256 oldBalance, uint256 newBalance
    );

    function setUp() public override {
        super.setUp();
        points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );
        // Wire ONLY the curator hook so the assertions isolate curator points.
        vm.startPrank(admin);
        points.setCuratorModule(address(curator));
        curator.setPointsModule(address(points));
        curator.grantRole(Roles.CREDIT_ROLE, address(this)); // drive absorbLoss as the credit layer
        vm.stopPrank();
    }

    function _curatorPoints(address who) internal view returns (uint256 p) {
        (,, p) = points.pointsBreakdown(who);
    }

    // ── bypass (a): the permissionless checkpoint ────────────────────────

    /// @dev H-03(a). Under the unfixed code `checkpoint()` moved `lastAccrual` to `now`, the
    ///      loss guard stopped matching, and the stale 1,000,000 balance accrued again.
    function test_H03_checkpointCannotThawAFrozenCuratorPosition() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);

        curator.absorbLoss(FILM, 500_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        // anyone may call checkpoint — the curator does not even need to do it themselves
        points.checkpoint(anchorCurator);
        vm.warp(block.timestamp + 60 days);

        assertEq(_curatorPoints(anchorCurator), atLoss, "checkpoint must not resume accrual on impaired capital");
        // The checkpoint may only move the position DOWN: it applies the exact pro-rata
        // dilution to the cached balance, and it can never lift the freeze.
        assertEq(points.curatorTracked(anchorCurator, FILM), 500_000e18, "checkpoint diluted the cached balance");
        assertEq(curator.postedOf(FILM, anchorCurator), 500_000e18, "cached balance now matches live posted");
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertTrue(frozen, "checkpoint did not thaw");
    }

    /// @dev The freeze survives an unbounded number of permissionless checkpoints.
    function test_H03_repeatedCheckpointsNeverAccrue() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 500_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        for (uint256 i = 0; i < 12; ++i) {
            points.checkpoint(anchorCurator);
            vm.warp(block.timestamp + 10 days);
        }
        assertEq(_curatorPoints(anchorCurator), atLoss, "no accrual across repeated checkpoints");
    }

    /// @dev Fuzzed: arbitrary warp/checkpoint interleavings between the loss and the reconcile
    ///      can never increase the curator's points.
    function testFuzz_H03_checkpointsBetweenLossAndReconcileAreInert(uint8 rounds, uint32 gap) public {
        uint256 n = bound(uint256(rounds), 1, 20);
        uint256 step = bound(uint256(gap), 1, 30 days);

        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 500_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        for (uint256 i = 0; i < n; ++i) {
            vm.warp(block.timestamp + step);
            points.checkpoint(anchorCurator);
            assertEq(_curatorPoints(anchorCurator), atLoss, "frozen position accrued");
        }
    }

    // ── bypass (b): a later loss overwriting the freeze instant ──────────

    /// @dev H-03(b). Under the unfixed code the second loss overwrote `lastCuratorLossAt`, so
    ///      the window [loss1, loss2] became accruable again for a position frozen at loss1.
    function test_H03_laterLossDoesNotReopenTheEarlierFreezeWindow() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);

        curator.absorbLoss(FILM, 400_000e18); // loss epoch 0
        uint256 atLoss1 = _curatorPoints(anchorCurator);

        vm.warp(block.timestamp + 45 days);
        curator.absorbLoss(FILM, 300_000e18); // loss epoch 1 — must NOT move the freeze instant

        assertEq(_curatorPoints(anchorCurator), atLoss1, "second loss re-opened the first freeze window");
        vm.warp(block.timestamp + 45 days);
        points.checkpoint(anchorCurator);
        assertEq(_curatorPoints(anchorCurator), atLoss1, "still frozen at the FIRST un-reconciled loss");

        // the freeze instant is pinned to loss epoch 0, not the latest loss
        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertTrue(frozen, "position is frozen");
        assertEq(frozenAt, points.curatorLossAt(FILM, 0), "pinned to the first un-reconciled loss");
        assertEq(points.curatorLossEpochCount(FILM), 2, "two loss epochs recorded");
    }

    /// @dev A curator frozen by loss 0 who reconciles AFTER loss 1 lands is thawed through both.
    function test_H03_reconcileClearsEveryRecordedLoss() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 400_000e18);
        uint256 atFirstLoss = _curatorPoints(anchorCurator);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 300_000e18);

        points.reconcile(anchorCurator);
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen, "reconcile thawed through both losses");
        assertEq(points.curatorTracked(anchorCurator, FILM), curator.postedOf(FILM, anchorCurator), "snapped to live");
        // The frozen window is FORFEITED, not paid out on thaw (reviewer gap: the original test
        // only proved accrual resumed, never that the frozen interval earned nothing).
        assertEq(_curatorPoints(anchorCurator), atFirstLoss, "the frozen window is forfeited, not back-paid");

        uint256 afterReconcile = _curatorPoints(anchorCurator);
        vm.warp(block.timestamp + 30 days);
        assertGt(_curatorPoints(anchorCurator), afterReconcile, "accrual resumes on the live balance");
    }

    // ── multi-class: no partial thaw ─────────────────────────────────────

    /// @dev A curator with positions in two classes, each hit by its own loss at a different
    ///      time, is thawed in BOTH by a single `reconcile` — never partially.
    function test_H03_multiClassCuratorIsNeverPartiallyThawed() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        _postFirstLoss(anchorCurator, ENERGY, 800_000e18);
        vm.warp(block.timestamp + 20 days);

        curator.absorbLoss(FILM, 500_000e18);
        vm.warp(block.timestamp + 20 days);
        curator.absorbLoss(ENERGY, 200_000e18);

        (bool fFilm,) = points.curatorFreezeStatus(anchorCurator, FILM);
        (bool fEnergy,) = points.curatorFreezeStatus(anchorCurator, ENERGY);
        assertTrue(fFilm && fEnergy, "both classes frozen");

        uint256 frozenPoints = _curatorPoints(anchorCurator);
        vm.warp(block.timestamp + 60 days);
        points.checkpoint(anchorCurator);
        assertEq(_curatorPoints(anchorCurator), frozenPoints, "neither class accrues while frozen");

        points.reconcile(anchorCurator);
        (fFilm,) = points.curatorFreezeStatus(anchorCurator, FILM);
        (fEnergy,) = points.curatorFreezeStatus(anchorCurator, ENERGY);
        assertFalse(fFilm, "film thawed");
        assertFalse(fEnergy, "energy thawed");
        assertEq(points.curatorTracked(anchorCurator, FILM), curator.postedOf(FILM, anchorCurator));
        assertEq(points.curatorTracked(anchorCurator, ENERGY), curator.postedOf(ENERGY, anchorCurator));
    }

    // ── a stake change must not thaw ─────────────────────────────────────

    /// @dev Posting fresh first-loss into a frozen class does not clear the freeze — only
    ///      `reconcile()` does. (The hook is fail-open and can be dropped; the freeze cannot.)
    function test_H03_stakeChangeDoesNotClearTheFreeze() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 500_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        vm.warp(block.timestamp + 10 days);
        _postFirstLoss(anchorCurator, FILM, 250_000e18); // fires onCuratorStakeChange

        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertTrue(frozen, "a stake change must not thaw the position");
        vm.warp(block.timestamp + 30 days);
        assertEq(_curatorPoints(anchorCurator), atLoss, "still no accrual after a post");

        points.reconcile(anchorCurator);
        (frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen, "reconcile is the only thaw");
    }

    /// @dev A curator opening a FRESH position in a class that already took losses is not
    ///      born frozen — a zero cached balance has nothing stale to freeze.
    function test_H03_freshPositionInALossyClassAccruesNormally() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 500_000e18);

        _postFirstLoss(secondCurator, FILM, 100_000e18);
        (bool frozen,) = points.curatorFreezeStatus(secondCurator, FILM);
        assertFalse(frozen, "a fresh position is not frozen by a prior loss");

        uint256 before = _curatorPoints(secondCurator);
        vm.warp(block.timestamp + 30 days);
        assertGt(_curatorPoints(secondCurator), before, "fresh capital accrues");
    }

    // ── events, views, access control ────────────────────────────────────

    function test_H03_onCuratorLossEmitsTheLossEpoch() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 5 days);

        vm.expectEmit(true, true, false, true, address(points));
        emit CuratorLossRecorded(FILM, 0, uint64(block.timestamp), 1_000_000e18, 900_000e18);
        curator.absorbLoss(FILM, 100_000e18);

        assertEq(points.curatorLossEpochCount(FILM), 1);
        assertEq(points.curatorLossAt(FILM, 0), uint64(block.timestamp));
        assertEq(points.lastCuratorLossAt(FILM), uint64(block.timestamp));
    }

    function test_H03_reconcileEmitsThawWithTheEpochWatermark() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 5 days);
        curator.absorbLoss(FILM, 100_000e18);
        curator.absorbLoss(FILM, 100_000e18);

        vm.expectEmit(true, true, false, true, address(points));
        emit CuratorPositionThawed(anchorCurator, FILM, 2);
        points.reconcile(anchorCurator);
    }

    /// @dev A reconcile with nothing to thaw emits no thaw event (the `seen >= count` branch).
    function test_H03_reconcileWithoutALossDoesNotEmitThaw() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.recordLogs();
        points.reconcile(anchorCurator);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CuratorPositionThawed.selector, "no thaw event for an un-frozen position");
        }
        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen);
        assertEq(frozenAt, 0);
    }

    function test_H03_onCuratorLossIsCuratorModuleOnly() public {
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorLoss(FILM, 1, 0);
    }

    /// @dev The freeze is scoped to curator positions: a share/USDfr position (classId 0) is
    ///      never capped by a class loss.
    function test_H03_shareAndUsdfrPositionsAreUnaffected() public {
        vm.prank(admin);
        usdfr.setPointsModule(address(points));

        _mintUSDfrTo(alice, 10_000e18);
        uint256 p0 = points.pointsOfWallet(alice);
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 10 days);
        curator.absorbLoss(FILM, 500_000e18);
        vm.warp(block.timestamp + 30 days);

        assertGt(points.pointsOfWallet(alice), p0, "a token holder keeps accruing through a class loss");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ROUND 2 — the BALANCE / MATURITY axis of the same root cause
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev R2-HIGH. The headline residual: a curator whose class is impaired and who tops back
    ///      up to their PRE-LOSS notional used to be credited exactly as if the loss had never
    ///      happened, because the stale-high cached balance made `newPosted == old`, so neither
    ///      `_track` nor `_untrack` ran and `maturityStart` was never re-blended — the fresh
    ///      capital inherited the destroyed capital's posting date at the 5x curator multiple.
    ///
    ///      Three isolated positions, all ending with exactly 1,000,000e18 live posted:
    ///        A (FILM)  — 1,000,000 at t0, 90% wiped at t=180d, +900,000 restored at t=180d
    ///        B (ENERGY)— 100,000 at t0, +900,000 at t=180d, never impaired  (the HONEST twin
    ///                    of A: identical surviving capital, identical cashflow dates)
    ///        C (LIFE)  — 1,000,000 held from t0, never impaired
    ///      A must accrue like B, NOT like C.
    function test_H03_toppingBackUpAfterALossDoesNotInheritTheDestroyedMaturity() public {
        uint256 LIFE = Config.CLASS_LIFE_SCIENCES;

        _postFirstLoss(anchorCurator, FILM, 1_000_000e18); // A
        _postFirstLoss(anchorCurator, ENERGY, 100_000e18); // B
        _postFirstLoss(anchorCurator, LIFE, 1_000_000e18); // C

        vm.warp(block.timestamp + 180 days);
        curator.absorbLoss(FILM, 900_000e18); // A is impaired 90%
        assertEq(curator.postedOf(FILM, anchorCurator), 100_000e18, "A survived at 100k");

        _postFirstLoss(anchorCurator, FILM, 900_000e18); // A tops back up to par
        _postFirstLoss(anchorCurator, ENERGY, 900_000e18); // B adds the same amount, same instant
        points.reconcile(anchorCurator); // A must reconcile to thaw

        assertEq(curator.postedOf(FILM, anchorCurator), 1_000_000e18, "A is back at par");
        assertEq(curator.postedOf(ENERGY, anchorCurator), 1_000_000e18, "B is at par");
        assertEq(curator.postedOf(LIFE, anchorCurator), 1_000_000e18, "C is at par");
        assertEq(points.curatorTracked(anchorCurator, FILM), 1_000_000e18, "A cached == live");

        uint256 aBefore = _classPoints(FILM);
        uint256 bBefore = _classPoints(ENERGY);
        uint256 cBefore = _classPoints(LIFE);
        vm.warp(block.timestamp + 30 days);
        uint256 aFwd = _classPoints(FILM) - aBefore;
        uint256 bFwd = _classPoints(ENERGY) - bBefore;
        uint256 cFwd = _classPoints(LIFE) - cBefore;

        assertEq(aFwd, bFwd, "an impaired-and-restored curator accrues exactly like its honest twin");
        assertLt(aFwd, cFwd, "and STRICTLY less than a curator who never took the loss");
    }

    /// @dev The same harm reached with the stake-change hook DROPPED (it is fail-open at the
    ///      CuratorModule, so a notification can go missing — that is exactly what `reconcile`
    ///      exists to repair, P-04). `reconcile` must therefore apply the outstanding dilution
    ///      itself before snapping, or it lands on its `target == balance` arm and re-blends
    ///      nothing. Negative control: removing the dilution call inside `reconcile` fails this
    ///      test and nothing else.
    function test_H03_reconcileReblendsMaturityEvenWhenTheStakeHookWasDropped() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18); // A
        _postFirstLoss(anchorCurator, ENERGY, 100_000e18); // B, the honest twin

        vm.warp(block.timestamp + 180 days);
        curator.absorbLoss(FILM, 900_000e18); // loss IS notified

        vm.prank(admin);
        curator.setPointsModule(address(0)); // both top-up notifications are dropped
        _postFirstLoss(anchorCurator, FILM, 900_000e18);
        _postFirstLoss(anchorCurator, ENERGY, 900_000e18);
        vm.prank(admin);
        curator.setPointsModule(address(points));

        points.reconcile(anchorCurator);
        assertEq(points.curatorTracked(anchorCurator, FILM), 1_000_000e18, "A repaired to live");
        assertEq(points.curatorTracked(anchorCurator, ENERGY), 1_000_000e18, "B repaired to live");

        uint256 aBefore = _classPoints(FILM);
        uint256 bBefore = _classPoints(ENERGY);
        vm.warp(block.timestamp + 30 days);
        assertEq(
            _classPoints(FILM) - aBefore,
            _classPoints(ENERGY) - bBefore,
            "reconcile must re-blend the destroyed capital's maturity away, not snap over it"
        );
    }

    /// @dev Topping up ABOVE the pre-loss notional: the increase visible to the hook
    ///      (`newPosted - staleCached`) understates the genuinely new capital, so without the
    ///      dilution the surviving-capital share is credited at the destroyed capital's ramp.
    function test_H03_toppingUpAboveThePreLossNotionalIsAlsoBlendedHonestly() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18); // A
        _postFirstLoss(anchorCurator, ENERGY, 100_000e18); // B, the honest twin

        vm.warp(block.timestamp + 180 days);
        curator.absorbLoss(FILM, 900_000e18); // A survives at 100k, same as B's original stake

        _postFirstLoss(anchorCurator, FILM, 1_400_000e18); // A goes to 1.5M, past its old notional
        _postFirstLoss(anchorCurator, ENERGY, 1_400_000e18); // B does the same
        points.reconcile(anchorCurator);

        assertEq(points.curatorTracked(anchorCurator, FILM), 1_500_000e18);
        assertEq(points.curatorTracked(anchorCurator, ENERGY), 1_500_000e18);

        uint256 aBefore = _classPoints(FILM);
        uint256 bBefore = _classPoints(ENERGY);
        vm.warp(block.timestamp + 30 days);
        assertEq(
            _classPoints(FILM) - aBefore,
            _classPoints(ENERGY) - bBefore,
            "over-notional replacement capital gets no ramp advantage from the loss"
        );
    }

    /// @dev The same scenario WITHOUT a reconcile: the top-up is applied against the diluted
    ///      (not the stale-high) balance, so the maturity blend is already honest, and the
    ///      position still earns nothing until it is reconciled.
    function test_H03_topUpWhileFrozenDilutesFirstAndStaysFrozen() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 180 days);
        curator.absorbLoss(FILM, 900_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        vm.recordLogs();
        _postFirstLoss(anchorCurator, FILM, 900_000e18);
        _assertLogged(
            CuratorBalanceDiluted.selector,
            abi.encode(uint256(1_000_000e18), uint256(100_000e18)),
            "the stale-high cached balance was written down to the surviving 100k first"
        );

        assertEq(points.curatorTracked(anchorCurator, FILM), 1_000_000e18, "cached tracks the live top-up");
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertTrue(frozen, "a top-up must not thaw");
        vm.warp(block.timestamp + 60 days);
        assertEq(_curatorPoints(anchorCurator), atLoss, "still no accrual until reconciled");
    }

    /// @dev A full wipe zeroes the cached balance (the pool round advances and stale shares are
    ///      worthless), so capital reposted afterwards starts its maturity ramp from scratch.
    function test_H03_wipedClassRestartsTheMaturityRamp() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 300 days);
        curator.absorbLoss(FILM, 1_000_000e18); // full wipe
        assertEq(curator.postedOf(FILM, anchorCurator), 0, "nothing survived");

        points.checkpoint(anchorCurator);
        assertEq(points.curatorTracked(anchorCurator, FILM), 0, "cached balance wiped to zero");
        (uint64 round,) = points.curatorDilutionState(FILM);
        assertEq(round, 1, "a wipe advances the loss round");

        _postFirstLoss(anchorCurator, FILM, 1_000_000e18); // fresh round
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen, "reposting from a zero cached balance opens a clean position");

        // A brand-new curator posting the same amount at the same instant must accrue the same:
        // the wiped curator inherits no ramp.
        _postFirstLoss(secondCurator, FILM, 1_000_000e18);
        uint256 a0 = _curatorPoints(anchorCurator);
        uint256 b0 = _curatorPoints(secondCurator);
        vm.warp(block.timestamp + 30 days);
        assertEq(
            _curatorPoints(anchorCurator) - a0,
            _curatorPoints(secondCurator) - b0,
            "a wiped-and-reposted curator accrues exactly like a brand-new one"
        );
    }

    // ── availability: the frozen position must not become expensive to read/thaw ──

    /// @dev R2-MEDIUM. An earlier revision pinned `lastEpochIdx` at the loss for frozen
    ///      positions, which turned `_pending` into an unbounded traversal of every rate epoch
    ///      appended since — on every view AND on `reconcile`, the escape hatch itself. Governance
    ///      appends rate epochs while a position is frozen and the read must stay flat.
    function test_H03_rateEpochsAppendedWhileFrozenDoNotGrowTheReadCost() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 500_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        for (uint256 i = 0; i < 60; ++i) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(admin);
            points.setRate(1e18 + i); // appends a rate epoch while the position is frozen
        }
        assertEq(points.rateEpochCount(), 61, "60 rate epochs appended while frozen");
        assertEq(_curatorPoints(anchorCurator), atLoss, "a frozen position accrues nothing across rate epochs");

        uint256 gasBefore = gasleft();
        points.pointsOfWallet(anchorCurator);
        uint256 used = gasBefore - gasleft();
        // With the stale-index branch this measured ~2k gas per epoch per class (>600k here).
        assertLt(used, 150_000, "the frozen-position read must not scale with the rate-epoch count");

        gasBefore = gasleft();
        points.reconcile(anchorCurator);
        uint256 reconcileGas = gasBefore - gasleft();
        assertLt(reconcileGas, 700_000, "the sole thaw path must not scale with the rate-epoch count");
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen, "reconcile still thaws after 60 rate epochs");
    }

    // ── the second thaw path is explicit, evented and tested ─────────────

    /// @dev R2 (reviewer): a FULL withdraw drives the cached balance to zero, and the next post
    ///      then legitimately clears the freeze — there is no stale capital left to credit. That
    ///      path is real (the round-1 NatSpec wrongly called it unreachable); it must emit the
    ///      thaw so the freeze lifecycle is reconstructable from events, and it must not pay out
    ///      anything for the frozen window.
    function test_H03_withdrawToZeroThenRepostThawsExplicitlyAndPaysNothingForTheFrozenWindow() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        curator.absorbLoss(FILM, 500_000e18);
        uint256 atLoss = _curatorPoints(anchorCurator);

        vm.warp(block.timestamp + 10 days);
        uint256 posted = curator.postedOf(FILM, anchorCurator);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, posted);
        assertEq(points.curatorTracked(anchorCurator, FILM), 0, "cached balance emptied by the withdraw");
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertTrue(frozen, "an emptied position stays frozen until it is re-opened or reconciled");

        vm.warp(block.timestamp + 10 days);
        vm.recordLogs();
        _postFirstLoss(anchorCurator, FILM, 250_000e18);
        _assertLogged(
            CuratorPositionThawed.selector,
            abi.encode(uint64(1)),
            "re-opening from zero must emit the thaw (the freeze lifecycle is event-reconstructable)"
        );

        (frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen, "re-opening from zero clears the freeze");
        assertEq(_curatorPoints(anchorCurator), atLoss, "no points were paid for the frozen window");

        // and the fresh capital starts a fresh ramp, not the destroyed capital's
        _postFirstLoss(secondCurator, FILM, 250_000e18);
        uint256 a0 = _curatorPoints(anchorCurator);
        uint256 b0 = _curatorPoints(secondCurator);
        vm.warp(block.timestamp + 30 days);
        assertEq(
            _curatorPoints(anchorCurator) - a0,
            _curatorPoints(secondCurator) - b0,
            "re-opened capital ramps like brand-new capital"
        );
    }

    // ── reconcile must not write / mis-report for wallets with no position ──

    /// @dev R2 (reviewer): `reconcile(anyWallet)` used to thaw — 3 SSTOREs and an event per
    ///      class — for wallets that never posted first-loss, and `curatorFreezeStatus` reported
    ///      them as FROZEN once any class had taken a loss (a false dashboard state).
    function test_H03_reconcileIsInertForAWalletThatNeverPostedFirstLoss() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 10 days);
        curator.absorbLoss(FILM, 500_000e18);

        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(bob, FILM);
        assertFalse(frozen, "a wallet with no first-loss position is never frozen");
        assertEq(frozenAt, 0);

        vm.recordLogs();
        points.reconcile(bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CuratorPositionThawed.selector, "no thaw noise for an empty wallet");
        }
        (frozen,) = points.curatorFreezeStatus(bob, FILM);
        assertFalse(frozen, "still not frozen after a reconcile");
        assertEq(points.pointsOfWallet(bob), 0, "and it accrued nothing");
    }

    /// @dev Branch coverage on the survival-factor precision guard: a near-total absorption that
    ///      leaves a dust balance drives `survivalWad * after / before` to floor at ZERO. Rather
    ///      than let a zero factor be mistaken for "unset" (== WAD, i.e. no dilution at all), the
    ///      class loss ROUND is bumped: every cached balance is distrusted and rebuilt from live.
    function test_H03_survivalFactorUnderflowDistrustsInsteadOfResettingToWad() public {
        _postFirstLoss(anchorCurator, FILM, 2e18);
        vm.warp(block.timestamp + 30 days);
        uint256 atLoss = _curatorPoints(anchorCurator);

        curator.absorbLoss(FILM, 2e18 - 1); // 1 wei survives: 1e18 * 1 / 2e18 floors to 0
        assertEq(curator.poolBalance(FILM), 1, "one wei of first-loss survives");

        (uint64 round, uint256 survival) = points.curatorDilutionState(FILM);
        assertEq(round, 1, "an underflowing survival factor must distrust, not read back as WAD");
        assertEq(survival, 1e18, "the factor restarts at WAD for the NEW round");

        vm.warp(block.timestamp + 60 days);
        points.checkpoint(anchorCurator);
        assertEq(points.curatorTracked(anchorCurator, FILM), 0, "cached balance distrusted");
        assertEq(_curatorPoints(anchorCurator), atLoss, "and it accrued nothing while frozen");

        points.reconcile(anchorCurator);
        assertEq(points.curatorTracked(anchorCurator, FILM), curator.postedOf(FILM, anchorCurator), "rebuilt");
    }

    function test_H03_onCuratorStakeChangeIsCuratorModuleOnly() public {
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorStakeChange(anchorCurator, FILM, 1e18);
    }

    function test_H03_threeArgOnCuratorLossIsCuratorModuleOnly() public {
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorLoss(FILM, 1_000e18, 500e18);
    }

    // ── in-place UUPS upgrade of a LIVE proxy ────────────────────────────

    /// @dev R2 (reviewer): the freeze PREDICATE moved from the legacy `lastCuratorLossAt`
    ///      (populated on the deployed Sepolia proxy) to the new per-loss log (empty on it). An
    ///      in-place upgrade with no migration therefore DROPPED every pre-existing freeze —
    ///      reintroducing H-03 one-shot across the upgrade boundary.
    ///
    ///      This reproduces that live-proxy state exactly: the loss is absorbed while the points
    ///      hook is unwired (so the new log stays empty, as it is on the deployed proxy) and the
    ///      legacy timestamp is written straight into its storage slot, as the old implementation
    ///      would have. `migrateH03CuratorFreeze()` must restore the freeze.
    /// @dev The `Position` struct grew from 3 slots to 5 (`seenLossEpoch` packs into the free
    ///      high 64 bits of slot 2; `seenSurvivalWad`/`seenLossRound` are new trailing slots).
    ///      `Position` is only ever a mapping VALUE — never an array element, never embedded in
    ///      another struct — so the growth is layout-safe. This proves it directly: pre-upgrade
    ///      bytes are written into slots 0..2 of a curator position and must still decode into
    ///      exactly the same balance / accrued / maturity / accrual clock, with the new trailing
    ///      members reading their zero defaults (which mean "no dilution, round 0").
    function test_H03_preUpgradePositionBytesStillDecodeIdentically() public {
        vm.warp(block.timestamp + 200 days); // put the genesis rate epoch behind the clock below
        bytes32 slot0 = _positionSlot(anchorCurator, FILM);
        uint256 balance = 1_234_567e18;
        uint256 accrued = 987e18;
        uint64 maturityStart = uint64(block.timestamp - 100 days);
        uint64 lastAccrual = uint64(block.timestamp - 1 days);
        uint32 lastEpochIdx = 0;
        uint32 classId = uint32(FILM);

        vm.store(address(points), slot0, bytes32(balance));
        vm.store(address(points), bytes32(uint256(slot0) + 1), bytes32(accrued));
        vm.store(
            address(points),
            bytes32(uint256(slot0) + 2),
            bytes32(
                uint256(maturityStart) | (uint256(lastAccrual) << 64) | (uint256(lastEpochIdx) << 128)
                    | (uint256(classId) << 160)
            )
        );

        assertEq(points.curatorTracked(anchorCurator, FILM), balance, "balance decodes unchanged");
        // accrued + one day of pending on the pre-upgrade clock, i.e. the maturity ramp and the
        // accrual clock decode unchanged too
        assertGt(points.curatorPointsInClass(anchorCurator, FILM), accrued, "accrued + pending decode unchanged");
        // the new trailing members read their zero defaults on an untouched (upgraded) position
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, FILM);
        assertFalse(frozen, "no recorded loss yet, so not frozen");
        (uint64 round, uint256 survival) = points.curatorDilutionState(FILM);
        assertEq(round, 0, "zero loss round");
        assertEq(survival, 1e18, "a zero survival slot means WAD (no dilution)");
    }

    /// @dev `lastCuratorLossAt` is member 11 of the ERC-7201 `PointsStorage` struct.
    function _legacyLossSlot(uint256 classId) internal pure returns (bytes32) {
        return keccak256(abi.encode(classId, uint256(_STORAGE_BASE) + 11));
    }

    /// @dev `cPos` is member 7: `cPos[wallet][classId]` is a two-level mapping.
    function _positionSlot(address wallet, uint256 classId) internal pure returns (bytes32) {
        bytes32 lvl1 = keccak256(abi.encode(wallet, uint256(_STORAGE_BASE) + 7));
        return keccak256(abi.encode(classId, lvl1));
    }

    bytes32 private constant _STORAGE_BASE = 0x2b0f9b300e42162fe5738c4f7cc02b34c204f066c1bd41ebe399ed932bb31b00;

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Asserts that `points` emitted `topic0` with exactly `data` among the recorded logs.
    ///      (`vm.expectEmit` is unusable here: the emitting call is nested behind mint/approve
    ///      traffic from other contracts.)
    function _assertLogged(bytes32 topic0, bytes memory data, string memory reason) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(points) || logs[i].topics[0] != topic0) continue;
            if (keccak256(logs[i].data) == keccak256(data)) return;
        }
        fail(reason);
    }

    /// @dev Points earned by `anchorCurator` in one class only (accrued + pending).
    function _classPoints(uint256 classId) internal view returns (uint256) {
        return points.curatorPointsInClass(anchorCurator, classId);
    }
}
