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
        assertEq(defaultManager.pastDuePrincipal(FILM), 2_000_000e18, "past-due pool not credited");

        // The governance lever CSG-F1 warns about: drop the first-loss target so the EXPOSURE floor
        // (min(target, exposure)) collapses to 0.1M. Under the pre-fix formula this would expose
        // 2.9M of headroom (3M - 0.1M). The marked floor must instead pin required at the credited
        // 2M, leaving only 1M genuinely-excess headroom.
        curator.setFirstLossTarget(FILM, 100_000e18);
        assertEq(curator.requiredFirstLoss(FILM), 2_000_000e18, "marked floor did not bind");
        assertEq(curator.headroom(FILM), 1_000_000e18, "credited capital leaked into headroom");

        uint256 free = curator.headroom(FILM); // 1M
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
