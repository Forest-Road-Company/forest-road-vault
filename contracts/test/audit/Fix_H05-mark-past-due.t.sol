// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title H-5 — permissionless, REVERSIBLE past-due mark-down for receivable classes
/// @notice REGRESSION SUITE for the owner-directed REDESIGN (2026-07-22), closing final-audit
///         findings #1 (HIGH) and #2 (MEDIUM).
///
///         BEFORE (the first H-5 fix, now WRONG): `markPastDue` was permissionless and transitioned
///         the receivable to `LoanState.Defaulted` — the SAME slot `declareDefault` uses. That
///         (a) foreclosed a later `declareDefault`/`RemedyInitiated` FOREVER (no ClaimBridge edge
///         back from Defaulted), so the on-chain legal-remedy trigger the legal wrapper conditions on
///         could never fire for an auto-marked facility; (b) de-gated `realizeLoss` from the
///         `DefaultDeclared` attestation (its gate is only state ∈ {Defaulted, Accelerated}), so the
///         full curator->sGROVE->senior cascade could run on a facility carrying NO attested
///         legal-default fact; and (c) let any bystander freeze a curing facility mid-workout.
///         The DELETED tests below used to assert markPastDue set `Defaulted`, froze the curator,
///         and let `realizeLoss` run without a declare — all of which are now DISALLOWED behaviour.
///
///         AFTER (this redesign): `markPastDue` sets a REVERSIBLE per-facility flag and records the
///         at-risk principal into a SEPARATE past-due pool that `pendingSeniorImpairment` nets
///         against junior capacity exactly like the declared pool — the honest NAV mark. It does NOT
///         transition state, does NOT freeze the curator, and cannot reach `realizeLoss`. The mark is
///         removed by `clearPastDue` (servicer cure) or CONVERTED by `declareDefault` (which releases
///         the past-due contribution before recording the declared one — counted exactly once). So
///         `declareDefault`/`RemedyInitiated` stay reachable, `realizeLoss` stays behind the attested
///         `declareDefault` by construction, and permissionless griefing is defanged.
contract FixH05MarkPastDueTest is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // 1, receivable
    uint256 internal constant DIGITAL = Config.CLASS_DIGITAL_ASSETS; // 5, marked-to-market

    uint256 internal constant PRINCIPAL = 400_000e18;

    event PastDueMarked(uint256 indexed tokenId, uint256 indexed classId, uint64 maturity, uint256 outstanding);
    event PastDueCleared(uint256 indexed tokenId, uint256 indexed classId, uint256 amount);
    event PastDueReanchored(uint256 indexed tokenId, uint256 indexed classId, uint256 amount);

    // ── RE-AUDIT MEDIUM: the performing-cure path must release / re-anchor the past-due mark ──
    // Before this fix, `_releasePastDue` had only two callers (clearPastDue, declareDefault), so a
    // past-due facility that cured through the ORDINARY performing repayment path kept its
    // mark-time snapshot and depressed the conservative NAV until a MANUAL clearPastDue — the H-2
    // stuck-over-mark shape on the past-due pool. `WaterfallEngine.distribute` now calls
    // `onPerformingRepayment` on the performing branches. Both tests below fail without that wiring.

    /// @notice A PERFORMING FULL repayment of a past-due facility clears the mark automatically:
    ///         no manual clearPastDue needed, and the conservative NAV recovers to baseline.
    function test_h5_performingFullRepaymentReleasesThePastDueMark() public {
        _seedSeniors(1_000_000e18);
        uint256 baseImpair = defaultManager.pendingSeniorImpairment();
        uint256 id = _markPastDueFilm(PRINCIPAL);
        assertEq(defaultManager.pastDueContribution(id), PRINCIPAL, "precondition: marked at full outstanding");
        assertEq(defaultManager.pendingSeniorImpairment(), baseImpair + PRINCIPAL, "precondition: NAV depressed");

        // Ordinary performing repayment in full - NOT a servicer clearPastDue, NOT a declareDefault.
        // NOTE: `vm.expectEmit` binds to the next EXTERNAL call, and the past-due cure fires deep
        // inside `distribute`; the internal `_repay` helper's first external call is the USDC mint,
        // which would consume the expectation (identical inlining note in the H-2 suite). Deliver the
        // receipt inline so the expectation binds to `distribute`, whose subtree emits PastDueCleared.
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, PRINCIPAL);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit PastDueCleared(id, FILM, PRINCIPAL);
        vm.prank(servicer);
        waterfall.distribute(payment);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid), "facility repaid");
        assertEq(defaultManager.pastDueContribution(id), 0, "the past-due mark auto-cleared on full repayment");
        assertEq(defaultManager.pastDueExposure(), 0, "pastDueExposure returned to zero");
        assertEq(
            defaultManager.pendingSeniorImpairment(), baseImpair, "the conservative NAV recovered - no stale over-mark"
        );
    }

    /// @notice A PERFORMING PARTIAL paydown of a past-due facility re-anchors the mark DOWN to the
    ///         live outstanding, so the NAV is depressed only by what is still deployed (not the
    ///         whole mark-time snapshot).
    function test_h5_performingPartialPaydownReanchorsThePastDueMarkDown() public {
        _seedSeniors(1_000_000e18);
        uint256 baseImpair = defaultManager.pendingSeniorImpairment();
        uint256 id = _markPastDueFilm(PRINCIPAL);
        uint256 paydown = PRINCIPAL / 4;

        // Inline the receipt (see the note in the full-repayment test): `vm.expectEmit` must bind to
        // `distribute`, not to the `_repay` helper's first external call (the USDC mint).
        IWaterfallEngine.Payment memory payment = _preparePayment(id, 0, paydown);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit PastDueReanchored(id, FILM, paydown);
        vm.prank(servicer);
        waterfall.distribute(payment);

        uint256 remaining = PRINCIPAL - paydown;
        assertEq(reserves.deployedTo(id), remaining, "precondition: deployedTo fell by the paydown");
        assertEq(defaultManager.pastDueContribution(id), remaining, "the mark re-anchored DOWN to live deployedTo");
        assertEq(defaultManager.pastDueExposure(), remaining, "pastDueExposure tracks the re-anchor");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            baseImpair + remaining,
            "NAV depressed only by the still-deployed remainder, not the whole snapshot"
        );
        // still flagged (partial) — a nonzero contribution means the mark persists, so the servicer
        // can still clear the residual (or a further repayment re-anchors it) when it fully cures.
        assertGt(
            defaultManager.pastDueContribution(id), 0, "partial paydown leaves the facility flagged with the residual"
        );
    }

    event GraceWindowSet(uint256 indexed classId, uint64 window);
    event DefaultDeclared(uint256 indexed tokenId, uint256 indexed classId, bytes32 remedyRef);
    event RemedyInitiated(uint256 indexed tokenId, uint256 indexed classId, bytes32 remedyRef);

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Stakes `amount` USDfr into the sUSDfr vault so the conservative-NAV mark is observable.
    function _seedSeniors(uint256 amount) internal {
        _mintUSDfrTo(alice, amount);
        vm.startPrank(alice);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev Warps strictly past `nextPaymentDue + graceWindow` for a facility.
    function _warpPastGrace(uint256 id) internal {
        uint64 nextPaymentDue = bridge.facility(id).nextPaymentDue;
        uint64 grace = defaultManager.graceWindow(bridge.facility(id).classId);
        vm.warp(uint256(nextPaymentDue) + uint256(grace) + 1);
    }

    /// @dev Marks a fresh, funded, past-grace film facility past due (permissionless caller carol).
    function _markPastDueFilm(uint256 principal) internal returns (uint256 id) {
        id = _liveFilmFacility(principal);
        _warpPastGrace(id);
        vm.prank(carol);
        defaultManager.markPastDue(id);
    }

    // ── the default default ──────────────────────────────────────────────

    /// @notice The grace window defaults to the redemption cooldown (the shared Config constant),
    ///         never a hardcoded second copy, and is never seeded above it.
    function test_h5_graceWindowDefaultsToTheRedemptionCooldown() public view {
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            assertEq(
                defaultManager.graceWindow(classId),
                Config.DEFAULT_REDEEM_COOLDOWN,
                "default grace == cooldown constant"
            );
        }
        assertEq(defaultManager.graceWindow(FILM), queue.redeemCooldown(), "default grace == the live redeem cooldown");
    }

    // ── gating: before grace reverts, after grace marks ──────────────────

    /// @notice Before `nextPaymentDue + graceWindow` the trigger reverts — both immediately
    ///         after funding and at the exact end of the grace window.
    function test_h5_beforeGraceReverts() public {
        uint256 id = _liveFilmFacility(PRINCIPAL);
        uint64 nextPaymentDue = bridge.facility(id).nextPaymentDue;
        uint64 grace = defaultManager.graceWindow(FILM);
        uint64 graceEnd = nextPaymentDue + grace;

        // right after funding, long before maturity
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, id, nextPaymentDue, graceEnd)
        );
        defaultManager.markPastDue(id);

        // past maturity but still inside the grace window (exactly at the boundary is still not past)
        vm.warp(uint256(graceEnd));
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, id, nextPaymentDue, graceEnd)
        );
        defaultManager.markPastDue(id);
    }

    /// @notice REDESIGN: after grace, a permissionless caller flags the facility past due. It stays
    ///         `Active` (NOT `Defaulted`), the past-due pool reflects the full outstanding, and the
    ///         conservative senior exit price falls — WITHOUT entering the on-chain default state.
    function test_h5_afterGraceMarksAndImpairmentReflectsIt() public {
        _seedSeniors(1_000_000e18);
        uint256 id = _liveFilmFacility(PRINCIPAL);
        uint64 nextPaymentDue = bridge.facility(id).nextPaymentDue;

        uint256 impairBefore = defaultManager.pendingSeniorImpairment();
        uint256 exitBefore = vault.previewRedeem(10 ** vault.decimals());
        _warpPastGrace(id);

        // permissionless: carol is NOT KYC'd, yet may fire the accounting trigger
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit PastDueMarked(id, FILM, nextPaymentDue, PRINCIPAL);
        vm.prank(carol);
        defaultManager.markPastDue(id);

        // REDESIGN: the facility is NOT driven to Defaulted — it stays performing.
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Active),
            "the facility stays Active (NOT Defaulted)"
        );
        // The impairment flows through the SEPARATE past-due pool, not the declared-default pool.
        assertEq(defaultManager.pastDueContribution(id), PRINCIPAL, "full outstanding entered the past-due pool");
        assertEq(defaultManager.defaultedContribution(id), 0, "NOT in the declared-default pool");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "declared-default class pool untouched");
        assertEq(
            defaultManager.pendingSeniorImpairment(), impairBefore + PRINCIPAL, "senior impairment marks (no junior)"
        );
        assertEq(defaultManager.pastDueExposure(), PRINCIPAL, "pastDueExposure records the mark");
        assertLt(vault.previewRedeem(10 ** vault.decimals()), exitBefore, "senior exit price fell on the past-due mark");
    }

    /// @notice REDESIGN: idempotent via the flag (not via the state, since the facility stays
    ///         Active). A second call reverts `AlreadyPastDue` and never double-counts.
    function test_h5_idempotentSecondCallReverts() public {
        uint256 id = _markPastDueFilm(PRINCIPAL);

        uint256 exposureAfter = defaultManager.pastDueExposure();
        uint256 contribAfter = defaultManager.pastDueContribution(id);

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_AlreadyPastDue.selector, id));
        defaultManager.markPastDue(id);

        assertEq(defaultManager.pastDueExposure(), exposureAfter, "no double count into pastDueExposure");
        assertEq(defaultManager.pastDueContribution(id), contribAfter, "per-facility contribution unchanged");
    }

    /// @notice Marked-to-market classes are rejected — they use the margin path, not the maturity
    ///         clock.
    function test_h5_notReceivableReverts() public {
        // a digital-assets (MTM) facility, funded so it has an outstanding
        _mintUSDfrTo(alice, 200_000e18);
        uint256 id = _originateDigital(100_000e18, 200_000e18);
        _fundFacility(id, 100_000e18);
        _warpPastGrace(id); // grace is seeded for every class; maturity is real

        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotReceivable.selector, id));
        defaultManager.markPastDue(id);
    }

    // ── FINDING #1 (HIGH): the foreclosure of the legal-remedy path is GONE ───

    /// @notice REGRESSION (finding #1). After `markPastDue`, the servicer's `declareDefault` STILL
    ///         works — the facility stayed `Active`, so the transition to `Defaulted`, the
    ///         `DefaultDeclared`/`RemedyInitiated` binding, and the curator freeze all remain
    ///         reachable. Under the OLD fix this reverted `DefaultManager_NotDefaultable` forever.
    function test_h5_declareDefaultStillWorksAfterMarkPastDue() public {
        _seedSeniors(1_000_000e18);
        bytes32 ref = keccak256("remedy-ref-film");
        vm.prank(admin);
        defaultManager.setRemedyRef(FILM, ref);

        uint256 id = _markPastDueFilm(PRINCIPAL);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "still Active after mark");

        _attestDefault(id);
        // both the DefaultDeclared record and the RemedyInitiated legal trigger fire, bound to ref
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit DefaultDeclared(id, FILM, ref);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit RemedyInitiated(id, FILM, ref);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "declareDefault reached Defaulted (foreclosure gone)"
        );
        // now genuinely declared: the curator IS frozen, and the past-due mark converted away
        assertEq(defaultManager.remedyRef(FILM), ref, "remedy ref bound for the off-chain trigger");
        assertEq(curator.unresolvedDefaults(FILM), 1, "declareDefault froze the curator (legal path)");
    }

    /// @notice REGRESSION (finding #1). `realizeLoss` — the cascade — REVERTS on a merely-past-due
    ///         (non-declared) facility: it requires state ∈ {Defaulted, Accelerated}, and a past-due
    ///         facility is still `Active`. So the DefaultDeclared attestation gate on loss
    ///         realization is preserved BY CONSTRUCTION: no cascade without the attested declare.
    function test_h5_realizeLossRevertsOnMerelyPastDue() public {
        _seedSeniors(1_000_000e18);
        uint256 id = _markPastDueFilm(PRINCIPAL);

        // the cascade cannot run on a facility that only ran past its maturity clock
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotInDefault.selector, id));
        vm.prank(servicer);
        defaultManager.realizeLoss(id, PRINCIPAL, FILM_REF);

        // and it stays blocked until a genuine, ATTESTED declareDefault runs
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _realizeLoss(id, PRINCIPAL, FILM_REF); // now permitted with exact loss evidence
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "loss realized only via the attested path");
    }

    // ── FINDING #1 (griefing): markPastDue does NOT freeze the curator ────

    /// @notice REGRESSION (finding #1, griefing). `markPastDue` does NOT freeze the curator: a
    ///         bystander cannot lock first-loss withdrawals on a reversible past-due mark. Contrast
    ///         with `declareDefault`, which DOES freeze (a real `realizeLoss` it could front-run).
    function test_h5_markPastDueDoesNotFreezeTheCurator() public {
        // zero the class first-loss target so `headroom == posted` and the ONLY thing that could
        // block a withdrawal is the default freeze — isolating exactly what this test asserts.
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 0);

        uint256 posted = 50_000e18;
        _postFirstLoss(anchorCurator, FILM, posted);

        _markPastDueFilm(PRINCIPAL);
        assertEq(curator.unresolvedDefaults(FILM), 0, "curator NOT frozen by a past-due mark");

        // the curator can still withdraw its first-loss (target zeroed above, so headroom == posted)
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, posted); // no revert
        assertEq(curator.poolBalance(FILM), 0, "withdrawal succeeded - the pool was never frozen");

        // by contrast, a genuine declared default DOES freeze the class
        uint256 id2 = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id2);
        vm.prank(servicer);
        defaultManager.declareDefault(id2, FILM_REF);
        assertEq(curator.unresolvedDefaults(FILM), 1, "declareDefault froze the curator");
        _postFirstLoss(anchorCurator, FILM, posted);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, posted);
    }

    // ── FINDING #1 (conversion / no double-count) ─────────────────────────

    /// @notice REGRESSION (finding #1). When `declareDefault` runs on a past-due facility it CONVERTS
    ///         the exposure: releases the past-due contribution and records the declared one, so the
    ///         impairment pool counts the facility EXACTLY ONCE — never both. The reported NAV
    ///         impairment is identical before and after the conversion (same at-risk principal).
    function test_h5_noDoubleCountWhenDeclareFollowsMarkPastDue() public {
        _seedSeniors(1_000_000e18);
        uint256 id = _markPastDueFilm(PRINCIPAL);

        uint256 impairPastDue = defaultManager.pendingSeniorImpairment();
        assertEq(defaultManager.pastDueExposure(), PRINCIPAL, "past-due pool holds it");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "declared pool empty pre-declare");

        _attestDefault(id);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit PastDueCleared(id, FILM, PRINCIPAL); // the past-due contribution is released on conversion
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        // exactly once: released from past-due, recorded into declared, NAV unchanged
        assertEq(defaultManager.pastDueExposure(), 0, "past-due pool released on conversion");
        assertEq(defaultManager.pastDueContribution(id), 0, "per-facility past-due contribution cleared");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), PRINCIPAL, "recorded into the declared pool");
        assertEq(defaultManager.defaultedContribution(id), PRINCIPAL, "counted once, in the declared pool");
        assertEq(defaultManager.pendingSeniorImpairment(), impairPastDue, "NAV impairment identical - no double count");
    }

    // ── FINDING #1 (reversibility / terminal reachability) ────────────────

    /// @notice REGRESSION (finding #1). `clearPastDue` (SERVICER) removes the impairment on a facility
    ///         the servicer knows has cured, gated by access control, leaving no stranded over-mark
    ///         (the H-2 lesson) and fully restoring the conservative NAV.
    ///
    ///         REWORKED for the re-audit MEDIUM fix. This test used to fully repay the facility
    ///         (-> Repaid) while it STAYED flagged, then have the servicer clear the standing
    ///         over-mark. The fix now AUTO-RELEASES the mark on a full performing repayment (proven in
    ///         `test_h5_performingFullRepaymentReleasesThePastDueMark` and
    ///         `test_h5_permissionlessGriefingIsDefanged`), so a fully-repaid facility has nothing
    ///         left for the servicer to clear. The servicer `clearPastDue` path this test guards is
    ///         therefore exercised on a facility still flagged after a PARTIAL paydown (the mark
    ///         re-anchored DOWN, the flag persists): access control still gates it, and clearing the
    ///         re-anchored residual restores the NAV with nothing stranded.
    function test_h5_clearPastDueRemovesImpairmentAndReachesTerminal() public {
        _seedSeniors(1_000_000e18);
        uint256 exitClean = vault.previewRedeem(10 ** vault.decimals());
        uint256 id = _markPastDueFilm(PRINCIPAL);
        assertEq(defaultManager.pendingSeniorImpairment(), PRINCIPAL, "marked while past due");
        assertLt(vault.previewRedeem(10 ** vault.decimals()), exitClean, "NAV depressed by the mark");

        // A PARTIAL performing paydown re-anchors the mark DOWN but leaves the facility flagged (still
        // Active/Amortizing with a residual), so the servicer clear path below still has a mark to
        // remove - a full repayment would auto-release it (that path is covered elsewhere).
        uint256 paydown = 250_000e18;
        uint256 residual = PRINCIPAL - paydown;
        _repay(id, 0, paydown);
        assertEq(defaultManager.pastDueContribution(id), residual, "re-anchored DOWN, still flagged");

        // access control: only the servicer clears
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        vm.prank(carol);
        defaultManager.clearPastDue(id, FILM_REF);

        _attestPastDueCure(id, FILM_REF);
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit PastDueCleared(id, FILM, residual);
        vm.prank(servicer);
        defaultManager.clearPastDue(id, FILM_REF);

        assertEq(defaultManager.pastDueContribution(id), 0, "past-due contribution cleared");
        assertEq(defaultManager.pastDueExposure(), 0, "pastDueExposure reconciles to zero on cure");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no residual haircut after the clear");
        assertEq(vault.previewRedeem(10 ** vault.decimals()), exitClean, "conservative NAV fully restored");
    }

    /// @notice `clearPastDue` reverts when the facility is not flagged past due.
    function test_h5_clearPastDueRevertsWhenNotMarked() public {
        uint256 id = _liveFilmFacility(PRINCIPAL);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDueMarked.selector, id));
        vm.prank(servicer);
        defaultManager.clearPastDue(id, FILM_REF);
    }

    /// @notice A past-due mark also reaches terminal via the ATTESTED declare -> full write-off:
    ///         `realizeLoss` runs the cascade and empties both pools.
    function test_h5_clearsToTerminalOnAttestedWriteOff() public {
        _seedSeniors(1_000_000e18);
        uint256 id = _markPastDueFilm(PRINCIPAL);

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF); // converts past-due -> declared
        _realizeLoss(id, PRINCIPAL, FILM_REF);

        assertEq(defaultManager.pastDueExposure(), 0, "past-due pool empty");
        assertEq(defaultManager.defaultedContribution(id), 0, "declared contribution cleared by the write-off");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "pool empty");
    }

    /// @notice `pastDueExposure()` reconciles across a PARTIAL cash recovery while past due.
    ///
    ///         DELIBERATE SEMANTIC CHANGE (re-audit MEDIUM, 2026-07-22), stated loudly per the brief.
    ///         BEFORE: a performing partial paydown did NOT re-anchor the past-due mark - the facility
    ///         never entered the default hooks, so `pastDueContribution` stayed pinned at the
    ///         mark-time SNAPSHOT (400k) - a SAFE but STUCK over-mark relative to the 150k still at
    ///         risk - until a MANUAL `clearPastDue`. That is the H-2 stuck-over-mark shape on the
    ///         past-due pool. AFTER: `WaterfallEngine.distribute` calls `onPerformingRepayment` on the
    ///         performing paydown branch, which re-anchors `pastDueContribution` DOWN to live
    ///         `reserves.deployedTo` (the honest mark). The servicer's `clearPastDue` then removes the
    ///         re-anchored residual. This test asserts the NEW re-anchor (exact equality with live
    ///         at-risk), which is strictly stronger than the old `assertGt` over-mark it replaced.
    function test_h5_pastDueExposurePartialRepaymentThenClear() public {
        _seedSeniors(1_000_000e18);
        uint256 id = _markPastDueFilm(PRINCIPAL);
        assertEq(defaultManager.pastDueExposure(), PRINCIPAL, "full at-risk marked");

        // 250k returns in cash while the facility is still Active (partial -> Amortizing). The
        // performing paydown branch re-anchors the past-due mark DOWN to live deployedTo (150k), so
        // the pool tracks the still-at-risk principal instead of the stale mark-time snapshot.
        uint256 recovered = 250_000e18;
        uint256 remaining = PRINCIPAL - recovered;
        _repay(id, 0, recovered);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Amortizing), "partial -> Amortizing");
        assertEq(defaultManager.pastDueContribution(id), remaining, "mark re-anchored DOWN to live at-risk");
        assertEq(defaultManager.pastDueContribution(id), reserves.deployedTo(id), "mark tracks deployedTo exactly");
        assertEq(defaultManager.pastDueExposure(), remaining, "pastDueExposure tracks the re-anchor");

        // the servicer clears the re-anchored residual on cure
        _clearPastDue(id, FILM_REF);
        assertEq(defaultManager.pastDueContribution(id), 0, "closed out");
        assertEq(defaultManager.pastDueExposure(), 0, "pastDueExposure reconciles to zero");
    }

    // ── FINDING #1 (griefing defanged end-to-end) ─────────────────────────

    /// @notice REGRESSION (finding #1, headline). A bystander marking a CURING facility only depresses
    ///         the NAV REVERSIBLY: the workout is not blocked (state and curator untouched), it still
    ///         cures to terminal, and the conservative NAV is fully restored. This is the whole point
    ///         of the redesign - permissionless is safe because the mark can neither foreclose the
    ///         legal path nor trigger a loss.
    ///
    ///         STRENGTHENED by the re-audit MEDIUM fix. This test used to require the servicer to
    ///         MANUALLY `clearPastDue` after the cure to restore the NAV. The full performing
    ///         repayment now AUTO-RELEASES the mark on the way through (`WaterfallEngine.distribute` ->
    ///         `onPerformingRepayment`), so the NAV recovers with NO servicer action at all - and the
    ///         once-needed manual `clearPastDue` now correctly reverts `NotPastDueMarked` (the flag is
    ///         already down). The griefing surface shrank, not grew: a bystander mark strands nothing.
    function test_h5_permissionlessGriefingIsDefanged() public {
        _seedSeniors(1_000_000e18);
        uint256 exitClean = vault.previewRedeem(10 ** vault.decimals());

        // a healthy facility mid-workout; an anonymous bystander marks it past due
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _warpPastGrace(id);
        vm.prank(carol); // not KYC'd, no role - a pure bystander
        defaultManager.markPastDue(id);

        // griefing checks: the workout is NOT frozen and the legal path is NOT foreclosed
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "workout not frozen");
        assertEq(curator.unresolvedDefaults(FILM), 0, "curator not frozen");
        assertLt(vault.previewRedeem(10 ** vault.decimals()), exitClean, "NAV reversibly depressed");

        // the workout proceeds and cures in full despite the bystander's mark; the full performing
        // repayment AUTO-RELEASES the past-due mark on the way through - no servicer action needed.
        _repay(id, 0, PRINCIPAL);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid), "workout still cured");
        assertEq(defaultManager.pastDueContribution(id), 0, "the mark auto-released on the performing cure");
        assertEq(defaultManager.pastDueExposure(), 0, "pastDueExposure reconciled to zero automatically");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "impairment gone without a manual clear");
        assertEq(vault.previewRedeem(10 ** vault.decimals()), exitClean, "NAV fully restored - grief was reversible");

        // the once-needed manual clear is now redundant AND reverts: nothing is left flagged, so a
        // servicer `clearPastDue` correctly reverts NotPastDueMarked. Proven so the auto-release is
        // unambiguous - a bystander mark leaves the servicer with nothing to clean up.
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDueMarked.selector, id));
        vm.prank(servicer);
        defaultManager.clearPastDue(id, FILM_REF);
    }

    /// @notice A declared default (the servicer path, no prior past-due mark) does NOT touch
    ///         `pastDueExposure` — the two entrants are disjoint.
    function test_h5_declaredDefaultDoesNotTouchPastDueExposure() public {
        uint256 id = _liveFilmFacility(PRINCIPAL);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), PRINCIPAL, "declared into the pool");
        assertEq(defaultManager.pastDueExposure(), 0, "but not into pastDueExposure");
    }

    // ── graceWindow governance surface ───────────────────────────────────

    /// @notice The upper bound is enforced at the shared cooldown constant; equal is allowed, above
    ///         reverts.
    function test_h5_graceWindowUpperBoundEnforced() public {
        vm.prank(admin);
        defaultManager.setGraceWindow(FILM, Config.DEFAULT_REDEEM_COOLDOWN); // exactly the cap: ok
        assertEq(defaultManager.graceWindow(FILM), Config.DEFAULT_REDEEM_COOLDOWN, "set to the cap");

        uint64 tooLong = Config.DEFAULT_REDEEM_COOLDOWN + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_GraceWindowTooLong.selector, tooLong, Config.DEFAULT_REDEEM_COOLDOWN
            )
        );
        vm.prank(admin);
        defaultManager.setGraceWindow(FILM, tooLong);
    }

    /// @notice The setter is DEFAULT_ADMIN-gated and evented, and a lowered window takes effect
    ///         (the facility becomes markable earlier, and marking now sets the reversible flag).
    function test_h5_setGraceWindowAccessControlAndEffect() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        vm.prank(carol);
        defaultManager.setGraceWindow(FILM, 7 days);

        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit GraceWindowSet(FILM, 7 days);
        vm.prank(admin);
        defaultManager.setGraceWindow(FILM, 7 days);

        // a facility now becomes markable at its next scheduled payment + 7 days
        uint256 id = _liveFilmFacility(PRINCIPAL);
        uint64 nextPaymentDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextPaymentDue) + 7 days + 1);
        vm.prank(carol);
        defaultManager.markPastDue(id); // no revert
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "still Active after mark");
        assertEq(defaultManager.pastDueContribution(id), PRINCIPAL, "marked at the new grace");
    }

    /// @notice An unknown class id is rejected by the setter.
    function test_h5_setGraceWindowRejectsUnknownClass() public {
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_UnknownClass.selector, uint256(0)));
        vm.prank(admin);
        defaultManager.setGraceWindow(0, 1 days);
    }

    // ── THE COOLDOWN-COVERAGE PROPERTY (partial, honest) ──────────────────

    /// @notice A senior who requested exit while a facility was performing cannot settle at PAR once
    ///         that facility is marked past due INSIDE the redeemer's cooldown — because
    ///         `markPastDue` now depresses the conservative NAV, and the queue settles at that rate.
    ///         (Residual, honestly stated in NatSpec: the anchors differ, so a redeemer whose
    ///         cooldown elapses BEFORE the mark lands can still exit at par — that par-exit window is
    ///         narrowed, not closed.)
    function test_h5_queuedSeniorCannotSettleAtParOncePastDue() public {
        // lower the grace so the mark lands well inside the cooldown (structural bound still holds)
        vm.startPrank(admin);
        defaultManager.setGraceWindow(FILM, 7 days);
        queue.setEpochLiquidityBps(10_000); // full liquidity: isolate the PRICE effect from throttle
        vm.stopPrank();
        assertLe(defaultManager.graceWindow(FILM), queue.redeemCooldown(), "the lag is bounded by the cooldown");

        // a live facility that will go past due, funded from bob's idle liquidity
        _mintUSDfrTo(bob, PRINCIPAL);
        uint256 id = _originateFilm(BORROWER_2, keccak256("h5-cooldown-state"), PRINCIPAL);
        _fundFacility(id, PRINCIPAL);
        uint64 nextPaymentDue = bridge.facility(id).nextPaymentDue;

        // a senior stakes; alice's mint also leaves 1M idle USDC in the treasury for settlement
        _seedSeniors(1_000_000e18);
        uint256 shares = vault.balanceOf(alice);

        // warp to just before the scheduled payment: the facility still performs, exits at par
        vm.warp(uint256(nextPaymentDue) - 1);
        uint256 parExit = vault.previewRedeem(shares);

        // the senior requests exit at par, hoping to escape before the past-due mark lands
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(shares);
        vm.stopPrank();

        // the payment runs past its 7-day grace — STILL inside alice's 21-day cooldown
        vm.warp(uint256(nextPaymentDue) + 7 days + 1);
        assertLt(block.timestamp, queue.eligibleToSettleAt(reqId), "the mark lands while the request is still cooling");
        vm.prank(carol);
        defaultManager.markPastDue(id);
        // the facility stayed Active; only the conservative NAV moved
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "still Active");
        uint256 impairedExit = vault.previewRedeem(shares);
        assertLt(impairedExit, parExit, "the exit price is marked down before the request can settle");

        // the cooldown elapses; the queue settles at the marked-down rate, not at par
        vm.warp(queue.eligibleToSettleAt(reqId));
        queue.closeEpoch(10);
        (, uint256 remaining, uint256 claimable,,) = queue.request(reqId);
        assertEq(remaining, 0, "fully served: budget was not the constraint");
        assertLt(claimable, parExit, "the queued senior settles BELOW par, having been marked mid-cooldown");
        assertApproxEqAbs(claimable, impairedExit, 1e12, "settled at exactly the conservative past-due rate");

        vm.prank(alice);
        uint256 assets = queue.claim(reqId);
        assertEq(assets, claimable, "claimed the marked-down amount");
    }
}
