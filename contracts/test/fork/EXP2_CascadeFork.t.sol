// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title EXP2_CascadeForkTest — adversarial attempts to INVERT the three-layer loss cascade
/// @notice AUTHORISED local-fork security assessment (never broadcasts; extends the full-protocol
///         `ForkLifecycleFixture`, which forks mainnet and deploys the REAL topology).
///
///         GOAL. Force `sUSDfr` SENIOR principal to absorb a credit loss BEFORE curator
///         first-loss (cascade layer 1) and the sGROVE backstop (layer 2) are exhausted — i.e.
///         skip or invert a limb of the CLAUDE.md §1.3 ordering
///         (curator -> sGROVE -> sUSDfr). Four distinct routes are attempted, each composing two
///         or more legitimate operations in an unexpected order/time:
///
///           A. Race a curator withdrawal against the default declaration (front-run the loss).
///           B. Withdraw curator capital that the conservative senior price is ALREADY crediting,
///              using a permissionless past-due mark plus a governance target cut (the SWEEP-2
///              CSG-F1 inversion shape).
///           C. Use a SECOND default to double-consume the shared sGROVE coverage reserve so the
///              senior absorbs while layer 2 still holds value.
///           D. Drain the subordination floor ahead of a default so the pool is empty when the
///              loss lands.
///
///         In this fork, `ops == address(this)` holds SERVICER_ROLE (declare/realize/markPastDue),
///         is the anchor curator approved on every class, is the originator, and retains
///         DEFAULT_ADMIN on the modules (the fixture never runs `_handover`). That is the maximal
///         insider surface — if the ordering cannot be inverted from here, it cannot be inverted.
///
///         RESULT (asserted, not asserted-away): every route is BLOCKED. The senior tranche is
///         only ever charged the genuine residual AFTER both junior layers are provably exhausted.
contract EXP2_CascadeForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // class 1

    // ── local attack helpers ─────────────────────────────────────────────

    /// @dev Post `amount` (18-dec) curator first-loss on `classId` AS ops (the anchor curator).
    ///      ops == address(this), so mint-then-approve-then-post runs with msg.sender == ops.
    function _postFirstLossOps(uint256 classId, uint256 amount) internal {
        _mintFromUSDC(ops, amount / 1e12);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
    }

    /// @dev Fund the sGROVE coverage reserve (layer 2) with `amount` (18-dec) AS ops.
    function _fundBackstopOps(uint256 amount) internal {
        _mintFromUSDC(ops, amount / 1e12);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
    }

    /// @dev Originate+fund a FILM facility for an explicit (borrowerId, stateId) so two facilities
    ///      can coexist without tripping the per-borrower concentration cap. Mirrors the fixture's
    ///      `_originateAndFund` exactly but parameterises the concentration keys.
    function _originateAndFundFilm(bytes32 borrowerId, bytes32 stateId, uint256 principal)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(tokenId, borrowerId, stateId, principal, 7500, maturity, keccak256("ucc-ref"));
        vm.prank(ops);
        uint256 id =
            bridge.originate(ops, _forkTerms(borrowerId, stateId, principal, 7500, maturity, keccak256("ucc-ref")));
        require(id == tokenId, "EXP2: tokenId drift");
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    // ── ROUTE A — race the curator withdrawal against declareDefault ──────

    /// @notice A curator holding cascade-layer-1 capital tries to pull it out the instant a default
    ///         is declared, to duck the loss it is layer 1 for. R4-EC2 must freeze the class on
    ///         `declareDefault`, and the subsequent `realizeLoss` must charge the curator FIRST.
    function test_A_declareDefaultFreezesFrontRun_curatorAbsorbsBeforeSenior() public onFork {
        deal(USDC, ops, 30_000_000e6);
        deal(USDC, bob, 30_000_000e6);

        // Senior principal at risk, plus curator layer-1 capital sized to fully cover the loss.
        _mintFromUSDC(bob, 2_000_000e6);
        _stake(bob, 2_000_000e18);
        _postFirstLossOps(FILM, 2_000_000e18);
        uint256 tokenId = _originateAndFund(2_000_000e18); // FORK_BORROWER / US-GA, 2M principal

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        assertEq(curator.poolBalance(FILM), 2_000_000e18, "layer-1 pool not seeded");

        // Declare the default — this arms the R4-EC2 class freeze.
        _declareDefault(tokenId, keccak256("evidence-A"));

        // THE FRONT-RUN: the curator tries to withdraw ahead of realizeLoss. Must be refused.
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        curator.withdrawFirstLoss(FILM, 1);

        // Realize the full loss. Curator (layer 1) covers all of it; senior is untouched.
        _realizeLoss(tokenId, 2_000_000e18, bytes32(0));

        assertEq(curator.poolBalance(FILM), 0, "layer 1 was not drained first");
        assertEq(
            usdfr.balanceOf(address(vault)),
            vaultBefore,
            "SENIOR ABSORBED while curator layer-1 capital still stood - cascade inverted"
        );
    }

    // ── ROUTE D — drain the subordination floor before defaulting ─────────

    /// @notice The other half of the race: instead of front-running the DECLARATION, drain the
    ///         first-loss pool while the facility is still performing, so the pool is empty when the
    ///         loss lands. The subordination-headroom rule must forbid withdrawing capital that is
    ///         protecting live exposure.
    function test_D_curatorCannotDrainSubordinationAheadOfLoss() public onFork {
        deal(USDC, ops, 30_000_000e6);
        deal(USDC, bob, 30_000_000e6);

        _mintFromUSDC(bob, 2_000_000e6);
        _stake(bob, 2_000_000e18);
        _postFirstLossOps(FILM, 2_000_000e18);
        _originateAndFund(2_000_000e18); // FILM exposure == 2M == posted first-loss

        // required first-loss == min(target 10M, exposure 2M) == 2M == pool, so headroom is zero:
        // NOTHING is withdrawable while the exposure is live, so the pool cannot be pre-emptied.
        assertEq(curator.headroom(FILM), 0, "subordination floor leaked headroom");

        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, uint256(1), uint256(0))
        );
        curator.withdrawFirstLoss(FILM, 1);
    }

    // ── ROUTE B — withdraw capital the senior price already credits ───────

    /// @notice The SWEEP-2 CSG-F1 inversion shape. A permissionless past-due mark makes the
    ///         conservative senior redemption price extend credit against curator layer-1 capital,
    ///         WITHOUT arming either withdrawal freeze (markPastDue deliberately freezes nothing).
    ///         A single governance target cut then tries to manufacture headroom out of that
    ///         credited capital. The MARKED FLOOR must hold the line: withdrawing the credited
    ///         capital reverts `Curator_HeadroomExceeded`.
    ///
    ///         ADR-0038 pins the size of the credited face. Under `ADR/0038-continuous-interest-accrual-to-susdfr.md`
    ///         ("Decisions received from Forest Road, 2026-09-10", Q1 and Q2) earned interest enters
    ///         backing at full face and accrual does not stop at the past-due mark, and under
    ///         `docs/remediation/CONTINUOUS_ACCRUAL_DESIGN_PANEL_2026-09-10.md` (lines 120 to 128)
    ///         past-due cohorts carry "dynamic conservative-risk accounting until declaration". So
    ///         `markPastDue` first posts the facility's accrued interest into its recorded face
    ///         (`DefaultAccrualLib.prepare` -> `postAccruedLoan`, `AccrualBook.takePosting`), and
    ///         the past-due pool, the marked floor and the reserve face all carry principal PLUS
    ///         60 days of the book's integer-slope carrier (`AccrualBook.sol` lines 12 to 15). The
    ///         figure is derived in closed form below and pinned exactly, so a defect that inflates
    ///         the face and the pool together (rather than one against the other) still fails.
    function test_B_pastDueMarkedFloorBlocksWithdrawalOfCreditedCapital() public onFork {
        deal(USDC, ops, 30_000_000e6);
        deal(USDC, bob, 30_000_000e6);

        _mintFromUSDC(bob, 1_000_000e6);
        _stake(bob, 1_000_000e18);
        _postFirstLossOps(FILM, 3_000_000e18); // 3M layer-1 capital
        uint256 tokenId = _originateAndFund(2_000_000e18); // 2M FILM exposure

        // Age the facility past its payment-due + grace window and mark it past-due (permissionless).
        _warp(60 days);
        defaultManager.markPastDue(tokenId);

        // ADR-0038 Q1/Q2: the marked face is principal plus 60 days of streamed interest, derived
        // from the engine's own arithmetic (fixture note: 2M, 1400 bps, Actual/360, 365-day term,
        // funded and originated in one block, 1e12 reserve grid):
        //   1. `ReserveAccrualLib.loanCeiling` (cash-pay) floors the term interest to whole grid
        //      units: cap = floor(2M * 1400 * 365d / (1e4 * 360d * 1e12)) * 1e12 = 283_888_888_888e12.
        //   2. `AccrualSegments.plan`: the 365-day period total equals that grid cap, so the cap is
        //      reachable at H = ceil(cap * 1e4 * 360d / (2M * 1400)) = 31_536_000 s and the first
        //      technical segment ends one second earlier, at 31_535_999 s.
        //   3. Its endpoint is the grid-floored simple interest at H-1, and `AccrualBook.schedule`
        //      admits the integer slope endpoint / 31_535_999 = 9_002_057_613_142_364 wei/s.
        //   4. `markPastDue` posts via `takePosting`, which takes the streamed clock value without
        //      reconciling the segment remainder: streamed = slope * 60d.
        uint256 marked;
        {
            uint256 basisRate = 2_000_000e18 * 1400;
            uint256 den = 10_000 * 360 days;
            uint256 cap = (basisRate * 365 days / (den * 1e12)) * 1e12;
            uint256 capHit = (cap * den + basisRate - 1) / basisRate; // mulDiv, Rounding.Ceil
            assertEq(capHit, 365 days, "the cap is reached exactly at the 365-day term");
            uint256 segmentSeconds = capHit - 1;
            uint256 endpoint = (basisRate * segmentSeconds / den) / 1e12 * 1e12;
            uint256 slope = endpoint / segmentSeconds;
            assertEq(slope, 9_002_057_613_142_364, "the book's integer slope for this note");
            marked = 2_000_000e18 + slope * 60 days;
        }
        assertEq(marked, 2_046_666_666_666_530_014_976_000, "the exact marked face");
        assertEq(reserves.deployedTo(tokenId), marked, "deployedTo carries the accrued face");
        assertEq(defaultManager.pastDuePrincipal(FILM), marked, "past-due pool not credited");

        // The governance lever CSG-F1 warns about: drop the first-loss target so the EXPOSURE floor
        // (min(target, exposure)) collapses to 0.1M. Under the pre-fix formula this would expose
        // 2.9M of headroom (3M - 0.1M). The marked floor must instead pin required at the
        // credited face, leaving only 3M - marked of genuinely-excess headroom.
        curator.setFirstLossTarget(FILM, 100_000e18);
        assertEq(curator.requiredFirstLoss(FILM), marked, "marked floor did not bind");
        assertEq(curator.headroom(FILM), 3_000_000e18 - marked, "credited capital leaked into headroom");
        assertEq(curator.headroom(FILM), 953_333_333_333_469_985_024_000, "the exact honest excess");

        uint256 free = curator.headroom(FILM); // 3M - marked
        // Attempt to withdraw one wei MORE than the honest excess: that first wei is credited
        // layer-1 capital. Must be refused, protecting the senior redemption price.
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, free + 1, free));
        curator.withdrawFirstLoss(FILM, free + 1);
    }

    // ── ROUTE C — second default double-consumes the sGROVE reserve ───────

    /// @notice The sGROVE coverage reserve is a single SHARED pool (ADR-0035). Two defaulted
    ///         facilities are realized in sequence; the attack hopes the second default re-draws
    ///         coverage the first already spent, or that the senior absorbs while layer 2 still
    ///         holds value. It must not: layer 2 delivers each dollar exactly once, and the senior
    ///         is charged only the true residual AFTER both junior layers are exhausted.
    function test_C_secondDefaultCannotDoubleConsumeBackstop() public onFork {
        deal(USDC, ops, 40_000_000e6);
        deal(USDC, bob, 40_000_000e6);

        // Deep senior tranche; small layer 1; a 2M shared layer-2 reserve.
        _mintFromUSDC(bob, 10_000_000e6);
        _stake(bob, 10_000_000e18);
        _postFirstLossOps(FILM, 1_000_000e18);
        _fundBackstopOps(2_000_000e18);

        // Two FILM facilities, distinct concentration keys, 3M principal each.
        uint256 t1 = _originateAndFundFilm(keccak256("borrowerC1"), keccak256("stateC1"), 3_000_000e18);
        uint256 t2 = _originateAndFundFilm(keccak256("borrowerC2"), keccak256("stateC2"), 3_000_000e18);

        _declareDefault(t1, keccak256("evidence-C1"));
        _declareDefault(t2, keccak256("evidence-C2"));

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        uint256 coverageBefore = sGrove.coverageReserve();
        assertEq(coverageBefore, 2_000_000e18, "layer-2 reserve not seeded");
        assertEq(curator.poolBalance(FILM), 1_000_000e18, "layer-1 pool not seeded");

        // Default #1: 3M loss. Layer 1 takes 1M, layer 2 takes 2M (reserve -> 0), senior takes 0.
        _realizeLoss(t1, 3_000_000e18, bytes32(0));
        assertEq(curator.poolBalance(FILM), 0, "layer 1 not exhausted first");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 not drawn for the residual");
        assertEq(
            usdfr.balanceOf(address(vault)),
            vaultBefore,
            "SENIOR absorbed while layer-2 reserve still held value - cascade inverted"
        );

        // Default #2: 3M loss. Both junior layers are now genuinely empty, so the senior absorbs
        // exactly the residual. The backstop must NOT be re-consumable by the second event.
        _realizeLoss(t2, 3_000_000e18, bytes32(0));
        assertEq(sGrove.coverageReserve(), 0, "layer-2 reserve was refilled/double-consumed");
        assertEq(curator.poolBalance(FILM), 0, "layer-1 pool re-appeared");
        assertEq(
            usdfr.balanceOf(address(vault)),
            vaultBefore - 3_000_000e18,
            "senior charge != genuine residual (double-consume or mis-allocation)"
        );

        // Value-conservation check on layer 2: total coverage delivered across BOTH events equals
        // the funded reserve exactly. A double-consume would have delivered more than 2M.
        assertEq(coverageBefore - sGrove.coverageReserve(), 2_000_000e18, "layer-2 delivered != funded reserve");
    }
}
