// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CuratorModule} from "../../src/CuratorModule.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev Bounded handler for the H-03 curator first-loss freeze. `fail_on_revert = true`, so
///      every op is clamped to a always-valid range. It interleaves post / withdraw / absorbLoss
///      / checkpoint / reconcile / warp across TWO curators and TWO classes — the surface the
///      round-1 fix left entirely outside stateful fuzzing (the reviewer's finding: `PointsHandler`
///      has no curator or loss entrypoint at all, so the 5x curator stream, the highest-multiple
///      one, was only ever exercised by single-curator unit tests).
contract H03FreezeHandler is Test {
    CuratorModule internal curator;
    PointsModule internal points;
    IERC20 internal usdfr;

    address[2] public curators;
    uint256[2] public classIds;

    /// @dev Per-(curator, class) high-water mark of points, for the monotonicity check. It lives
    ///      on the HANDLER: state written inside an `invariant_*` function does NOT survive to the
    ///      next call, so a ghost kept there never populates and the check silently degrades to a
    ///      no-op — confirmed here by negative control (a build with the freeze predicate removed
    ///      passed a ghost-on-the-test-contract version at 32,768 calls).
    mapping(address => mapping(uint256 => uint256)) public highWater;

    constructor(
        CuratorModule curator_,
        PointsModule points_,
        IERC20 usdfr_,
        address[2] memory cs,
        uint256[2] memory ids
    ) {
        curator = curator_;
        points = points_;
        usdfr = usdfr_;
        curators = cs;
        classIds = ids;
    }

    function curatorCount() external pure returns (uint256) {
        return 2;
    }

    function classCount() external pure returns (uint256) {
        return 2;
    }

    function curatorAt(uint256 i) external view returns (address) {
        return curators[i];
    }

    function classAt(uint256 i) external view returns (uint256) {
        return classIds[i];
    }

    // ── ops ──────────────────────────────────────────────────────────────

    /// @dev Ceiling on a class's internal share count. `postFirstLoss` mints
    ///      `amount * totalShares / poolBalance` shares, so a collapsed share price inflates the
    ///      count without bound and `pool.totalShares += shares` eventually overflows. That is a
    ///      pre-existing `CuratorModule` property, unrelated to the H-03 freeze; this handler
    ///      stays inside the realistic regime rather than papering over it (see `absorbLoss`).
    uint256 internal constant MAX_POOL_SHARES = 1e48;

    function post(uint256 cSeed, uint256 clsSeed, uint256 amount) external {
        address who = curators[cSeed % 2];
        uint256 cls = classIds[clsSeed % 2];
        if (curator.poolShares(cls) > MAX_POOL_SHARES) return;
        uint256 bal = usdfr.balanceOf(who);
        if (bal < 1e18) return;
        amount = bound(amount, 1e18, bal > 5_000_000e18 ? 5_000_000e18 : bal);
        vm.prank(who);
        curator.postFirstLoss(cls, amount);
    }

    function withdraw(uint256 cSeed, uint256 clsSeed, uint256 amount) external {
        address who = curators[cSeed % 2];
        uint256 cls = classIds[clsSeed % 2];
        uint256 posted = curator.postedOf(cls, who);
        if (posted == 0) return; // nothing to pull (also guards the zero-balance pool)
        amount = bound(amount, 1, posted);
        vm.prank(who);
        curator.withdrawFirstLoss(cls, amount);
    }

    /// @dev Drives the cascade's layer-1 absorption directly (the handler holds CREDIT_ROLE).
    function absorbLoss(uint256 clsSeed, uint256 loss) external {
        uint256 cls = classIds[clsSeed % 2];
        uint256 pool = curator.poolBalance(cls);
        if (pool == 0) return;
        loss = bound(loss, 1, pool);
        // Anything past half the pool is escalated to a FULL wipe, which advances the pool round
        // and resets shares. Partial absorptions therefore halve the share price at most, which
        // keeps the class out of the share-inflation regime described on MAX_POOL_SHARES while
        // still exercising both branches the freeze cares about: pro-rata dilution and a wipe.
        if (loss > pool / 2) loss = pool;
        curator.absorbLoss(cls, loss);
    }

    function pokeCheckpoint(uint256 cSeed) external {
        points.checkpoint(curators[cSeed % 2]);
    }

    function pokeReconcile(uint256 cSeed) external {
        address who = curators[cSeed % 2];
        points.reconcile(who);
        // Reconcile is the refresh against live state: immediately after it, the cached balance
        // must equal `postedOf` EXACTLY for every class — no dust, no stale high water mark.
        for (uint256 j = 0; j < 2; ++j) {
            assertEq(
                points.curatorTracked(who, classIds[j]),
                curator.postedOf(classIds[j], who),
                "RECONCILE DID NOT SNAP THE CACHED BALANCE TO LIVE postedOf"
            );
        }
    }

    /// @dev THE H-03 PROPERTY, checked where it is actually observable: nothing but time passes
    ///      across this call, so any position frozen before AND after — at the same loss instant —
    ///      must have earned exactly zero over the interval. A `checkpoint` beforehand, a top-up
    ///      back to the pre-loss notional, a later same-class loss: none of them may re-open it.
    ///
    ///      This lives in the handler rather than in an `invariant_*` function on purpose: it is
    ///      a before/after property over a single call, which an invariant hook (stateless across
    ///      calls, see `highWater`) cannot express.
    function warp(uint256 secs) external {
        bool[2][2] memory wasFrozen;
        uint64[2][2] memory at;
        uint256[2][2] memory before;
        for (uint256 i = 0; i < 2; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                (wasFrozen[i][j], at[i][j]) = points.curatorFreezeStatus(curators[i], classIds[j]);
                before[i][j] = points.curatorPointsInClass(curators[i], classIds[j]);
            }
        }

        vm.warp(block.timestamp + bound(secs, 1 hours, 120 days));

        for (uint256 i = 0; i < 2; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                uint256 nowPts = points.curatorPointsInClass(curators[i], classIds[j]);
                (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(curators[i], classIds[j]);
                if (wasFrozen[i][j] && frozen && at[i][j] == frozenAt) {
                    assertEq(nowPts, before[i][j], "FROZEN CURATOR POSITION ACCRUED OVER A PURE TIME STEP");
                }
                assertGe(nowPts, before[i][j], "CURATOR POINTS DECREASED");
            }
        }
    }

    /// @dev Records the per-position points high-water mark; the monotonicity invariant reads it.
    function recordHighWater(address w, uint256 cls, uint256 pts) external {
        highWater[w][cls] = pts;
    }
}

/// @title Stateful-fuzz invariants for the H-03 curator first-loss freeze.
/// @notice Ties to CLAUDE.md 1.3 "no privileged action is reachable by an unauthorized role in
///         any state" only indirectly — PointsModule holds no value. These encode the freeze's
///         own safety spec, which the round-1 fix asserted only in single-curator unit tests:
///         - FREEZE HOLDS: while a position is frozen by an un-reconciled class loss, and no new
///           loss has landed, its points do not move. Not via `checkpoint`, not via a top-up.
///           (Asserted inside `H03FreezeHandler.warp` — a before/after property over one call.)
///         - NEVER OVER-STATED: a position that is NOT frozen never has a cached balance ABOVE
///           the live `postedOf` — i.e. every clear of the freeze went through a live-balance
///           refresh; and `reconcile` snaps it EXACTLY (asserted in the handler).
///         - MONOTONIC: curator points never decrease, even as the cached balance is written
///           down by a loss (the write-down must never claw back already-earned points).
contract FixH03CuratorFreezeInvariants is CreditLayerFixture {
    PointsModule internal points;
    H03FreezeHandler internal handler;

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

        address[2] memory cs = [anchorCurator, secondCurator];
        uint256[2] memory ids = [Config.CLASS_FILM_TAX_CREDITS, Config.CLASS_RENEWABLE_ENERGY];

        handler = new H03FreezeHandler(curator, points, IERC20(address(usdfr)), cs, ids);

        vm.startPrank(admin);
        points.setCuratorModule(address(curator));
        curator.setPointsModule(address(points));
        curator.grantRole(Roles.CREDIT_ROLE, address(handler));
        curator.setCuratorApproved(Config.CLASS_RENEWABLE_ENERGY, secondCurator, true);
        vm.stopPrank();

        // fund both curators and pre-approve, so the handler's ops can never revert on funding
        for (uint256 i = 0; i < 2; ++i) {
            _mintUSDfrTo(cs[i], 20_000_000e18);
            vm.prank(cs[i]);
            usdfr.approve(address(curator), type(uint256).max);
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = H03FreezeHandler.post.selector;
        selectors[1] = H03FreezeHandler.withdraw.selector;
        selectors[2] = H03FreezeHandler.absorbLoss.selector;
        selectors[3] = H03FreezeHandler.pokeCheckpoint.selector;
        selectors[4] = H03FreezeHandler.pokeReconcile.selector;
        selectors[5] = H03FreezeHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Points already earned are never clawed back — in particular the pro-rata write-down
    ///      of a stale cached balance reduces future accrual only, never the `accrued` ledger.
    ///      (The freeze-holds property itself is asserted inside `H03FreezeHandler.warp`, where a
    ///      before/after comparison over a single call is expressible; an `invariant_*` hook is
    ///      stateless across calls and cannot carry it — see the note on `highWater`.)
    function invariant_H03_curatorPointsAreMonotonic() public {
        for (uint256 i = 0; i < handler.curatorCount(); ++i) {
            address w = handler.curatorAt(i);
            for (uint256 j = 0; j < handler.classCount(); ++j) {
                uint256 cls = handler.classAt(j);
                uint256 pts = points.curatorPointsInClass(w, cls);
                assertGe(pts, handler.highWater(w, cls), "CURATOR POINTS DECREASED");
                handler.recordHighWater(w, cls, pts);
            }
        }
    }

    /// @dev A position is only ever un-frozen through a path that refreshed it against the live
    ///      posted amount (`reconcile`, or re-opening from a zero cached balance), so an un-frozen
    ///      position must NEVER over-state the curator's live first-loss — over-statement is
    ///      exactly the H-03 harm (impaired capital earning at the 5x multiple).
    ///
    ///      The bound is one-sided rather than exact on purpose. Lazy share-scale normalisation
    ///      conserves the backing pool, but independently floored holder claims can discard one
    ///      remainder per holder. A single aggregate pool scalar cannot generally restore every
    ///      remainder without permitting aggregate claims above the pool. Chained normalisations
    ///      can therefore leave the raw cache two wei above a live claim; the durable skeptic
    ///      witness exercises that case. `pokeReconcile` still asserts exact equality when the
    ///      ledger is explicitly refreshed against live state.
    uint256 internal constant RENORMALISATION_DUST_WEI = 2;

    function invariant_H03_unfrozenPositionsNeverOverstateLivePosted() public view {
        for (uint256 i = 0; i < handler.curatorCount(); ++i) {
            address w = handler.curatorAt(i);
            for (uint256 j = 0; j < handler.classCount(); ++j) {
                uint256 cls = handler.classAt(j);
                (bool frozen,) = points.curatorFreezeStatus(w, cls);
                if (frozen) continue;
                assertLe(
                    points.curatorTracked(w, cls),
                    curator.postedOf(cls, w) + RENORMALISATION_DUST_WEI,
                    "UNFROZEN CURATOR POSITION OVER-STATES LIVE FIRST-LOSS"
                );
            }
        }
    }

    /// @dev The tracked-curator total reconciles to the sum of the per-position cached balances
    ///      even as losses write them down (the dilution must adjust the total in lockstep).
    function invariant_H03_curatorTotalReconciles() public view {
        (,, uint256 totalCurator) = points.totals();
        uint256 sum;
        for (uint256 i = 0; i < handler.curatorCount(); ++i) {
            for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
                sum += points.curatorTracked(handler.curatorAt(i), c);
            }
        }
        assertEq(totalCurator, sum, "TRACKED CURATOR TOTAL != SUM OF POSITIONS");
    }
}
