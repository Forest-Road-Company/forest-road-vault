// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title OPEN_exit_R2: the exit path under continuous accrual (round 2, exit angle)
/// @notice Executed probes of the sUSDfr exit under ADR-0038 accrual with the G2W past-due
///         ramp, the ADR-0034 Y-bis junior draw and the three-layer cascade:
///           P1  A staggered exit cohort settles at every phase of one delinquent facility's life
///               (pre-mark at full accrued NAV, at the mark under 50% weight, mid-ramp, past the
///               ramp) and the loss then lands. Every quote is pinned to the closed-form
///               cascade-ordered conservative NAV, and the value each leaver took from the stayer
///               is measured to the wei.
///           P3  An under-backed USDfr exit on an accruing book: the draw target is computed on
///               the effective supply (physical plus unissued), the exit settles at par, and the
///               junior tranche is charged once across the draw and the later realization.
///           P4  Cure and re-mark on the same unpaid due date: the relief clock persists (S3-F3)
///               and the accrual cohort joins and leaves exactly.
///         (A fifth probe, the same-second ordering of keeper settlement and permissionless mark,
///         was executed and is recorded in the round report; it is a measurement with no
///         seedable defect, so it is not kept here.)
///
/// @dev Mutation proofs (each seeded, observed failing, restored; see the round report):
///        M1 `DefaultAccrualLib.pastDuePrincipal` without the accrued cohort: P1 fails at
///           "past the ramp: paid above the cascade-ordered NAV" and P4 at "pool == face after growth".
///        M2 `AccrualBook.setPastDue` leaving the slope in the cohort on exit: P4 fails at
///           "pool == face at the re-mark".
///        M3 `_exitDrawTarget` dividing by supply instead of backing: P3 fails at
///           "par exit out of the junior draw".
contract OPEN_exit_R2 is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant P = 1_000_000e18;
    uint256 internal constant C1 = 100_000e18; // curator first-loss (layer 1)
    uint256 internal constant B2 = 100_000e18; // sGROVE coverage (layer 2)
    uint256 internal constant RAMP = Config.DEFAULT_REDEEM_COOLDOWN; // 21 days
    uint256 internal constant OFFSET = 1e6; // sUSDfr virtual shares (decimals offset 6)

    struct Leg {
        string label;
        uint256 t;
        uint256 shares;
        uint256 paid;
        uint256 assets; // vault.totalAssets at settlement
        uint256 mark; // pendingSeniorImpairment at settlement
        uint256 face; // reserves.deployedTo(id)
        uint256 supply; // sUSDfr totalSupply after fee checkpoint
        uint256 grossAccrued; // book gross at settlement
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _freshen() internal {
        for (uint256 i = 0; i < 8; ++i) {
            vm.prank(carol);
            (, bool fresh) = reserves.checkpointAccrual(32);
            if (fresh) return;
        }
        revert("OPEN_exit_R2: book still stale after eight checkpoints");
    }

    function _warpTo(uint256 ts) internal {
        require(ts >= block.timestamp, "warpTo backwards");
        if (ts > block.timestamp) _warp(ts - block.timestamp);
        _freshen();
    }

    function _postFirstLoss(uint256 classId, uint256 amount) internal {
        vm.startPrank(ops);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    function _fundCoverage(uint256 amount) internal {
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal returns (uint256 id) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        id = queue.requestRedeem(shares);
        vm.stopPrank();
    }

    function _closeEpoch() internal {
        vm.prank(ops);
        queue.closeEpoch(64);
    }

    function _claim(address who, uint256 id) internal returns (uint256 assets) {
        vm.prank(who);
        assets = queue.claim(id);
    }

    function _gross() internal view returns (uint256) {
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        return s.gross;
    }

    /// @dev Independent closed form of `DefaultAccrualLib.nativeSeniorImpairment` composed with
    ///      `CollateralRegistry.conservativeSeniorMark`, recomputed from public views.
    function _modelMark() internal view returns (uint256 mark) {
        uint256 residual;
        uint256 pastDueSenior;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            uint256 pastDue = defaultManager.pastDuePrincipal(classId);
            uint256 available = curator.poolBalance(classId);
            if (pastDue > available) {
                pastDueSenior += pastDue - available;
                available = 0;
            } else {
                available -= pastDue;
            }
            uint256 declared = defaultManager.declaredDefaultedPrincipal(classId);
            if (declared > available) residual += declared - available;
        }
        residual += pastDueSenior;
        if (residual == 0) return 0;
        uint256 coverage = sGrove.coverageReserve();
        residual = residual > coverage ? residual - coverage : 0;
        pastDueSenior = pastDueSenior > coverage ? pastDueSenior - coverage : 0;
        if (residual == 0) return 0;
        uint256 declaredSenior = residual - pastDueSenior;
        uint256 vaultAssets = vault.totalAssets();
        uint256 elapsed = block.timestamp - defaultManager.pastDueReliefAnchor();
        uint256 executable = vaultAssets > declaredSenior ? vaultAssets - declaredSenior : 0;
        uint256 amount = pastDueSenior < executable ? pastDueSenior : executable;
        if (elapsed >= RAMP) return declaredSenior + amount;
        uint256 w0 = registry.pastDueWeightBps();
        mark = declaredSenior + (amount * (w0 + ((Config.BPS - w0) * elapsed) / RAMP) + Config.BPS - 1) / Config.BPS;
    }

    /// @dev The exit quote the vault must produce for `shares` after a fee checkpoint at this
    ///      timestamp: floor(shares * (RTA + 1) / (supply + 1e6)) with RTA = assets - mark.
    function _modelQuote(uint256 shares) internal view returns (uint256) {
        uint256 assets = vault.totalAssets();
        uint256 mark = _modelMark();
        uint256 rta = mark >= assets ? 0 : assets - mark;
        return Math.mulDiv(shares, rta + 1, vault.totalSupply() + OFFSET, Math.Rounding.Floor);
    }

    function _pinPricing(string memory label) internal returns (uint256 assets, uint256 mark, uint256 supply) {
        vault.accrueFees(); // fee-adjusted supply == totalSupply from here on in this block
        assets = vault.totalAssets();
        mark = defaultManager.pendingSeniorImpairment();
        supply = vault.totalSupply();
        assertEq(mark, _modelMark(), string.concat(label, ": native mark != closed form"));
        uint256 rta = mark >= assets ? 0 : assets - mark;
        assertEq(vault.redemptionTotalAssets(), rta, string.concat(label, ": RTA != assets - mark"));
        assertLe(vault.redemptionTotalAssets(), assets, string.concat(label, ": RTA above realized"));
    }

    function _setup() internal returns (uint256 id, uint256 aliceShares, uint256 t0) {
        _mintFromUSDC(alice, 3_000_000e6);
        _mintFromUSDC(bob, 2_000_000e6);
        _mintFromUSDC(ops, 300_000e6);
        aliceShares = _stake(alice, 1_500_000e18);
        _stake(bob, 1_000_000e18);
        _postFirstLoss(FILM, C1);
        _fundCoverage(B2);
        vm.prank(ops);
        queue.setEpochLiquidityBps(uint16(Config.BPS)); // budget never binds; the pricing is what is probed
        id = _originateAndFund(P);
        t0 = block.timestamp;
        assertEq(curator.poolBalance(FILM), C1, "layer 1 posted");
        assertEq(sGrove.coverageReserve(), B2, "layer 2 funded");
        assertEq(reserves.deployedTo(id), P, "funded face");
    }

    // ─────────────────────────────────────────────────────────────────────
    // P1. Staggered cohort across one delinquent facility's life
    // ─────────────────────────────────────────────────────────────────────

    /// @notice bob places four equal requests so that one settles in each phase: day 40 (coupon
    ///         missed at day 30, mark not yet available), the mark instant (day 51, weight 50%),
    ///         mid-ramp (day 61) and past the ramp (day 73). ops then declares and realizes the
    ///         whole face. Every settlement is pinned to the closed-form cascade-ordered NAV, and
    ///         the value each leaver took from alice, the stayer, is measured.
    Leg[] internal legs;
    uint256 internal facilityId;
    uint256 internal stayerShares;
    uint256 internal fundedAt;

    /// @dev Pin the pricing, quote `shares`, settle the head, claim, and record the leg.
    function _settleLeg(string memory label, uint256 reqId, uint256 shares) internal {
        (uint256 a, uint256 m, uint256 s) = _pinPricing(label);
        uint256 q = vault.previewRedeem(shares);
        assertEq(q, _modelQuote(shares), string.concat(label, ": quote != model"));
        _closeEpoch();
        uint256 paid = _claim(bob, reqId);
        assertEq(paid, q, string.concat(label, ": paid != quote"));
        legs.push(Leg(label, block.timestamp, shares, paid, a, m, reservesFace(facilityId), s, _gross()));
    }

    function test_P1_staggeredExitCohortAcrossPastDueRampUnderAccrual() public onFork {
        (facilityId, stayerShares, fundedAt) = _setup();
        uint256 id = facilityId;
        uint256 t0 = fundedAt;
        uint256 aliceShares = stayerShares;
        uint256 bobShares = vault.balanceOf(bob);
        uint256 slice = bobShares / 4;
        uint256[4] memory reqIds;

        // requests: cooldown 21d each; FIFO order equals settlement order
        _warpTo(t0 + 19 days);
        reqIds[0] = _request(bob, slice);
        _warpTo(t0 + 30 days);
        reqIds[1] = _request(bob, slice);
        _warpTo(t0 + 40 days);
        reqIds[2] = _request(bob, slice);

        // ── leg 0: day 40, coupon missed 10 days ago, mark not yet available ──
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no mark before graceEnd");
        _settleLeg("day40 pre-mark", reqIds[0], slice);

        // ── leg 1: the mark instant. graceEnd = nextPaymentDue + 21d = t0 + 51d ──
        uint256 graceEnd = uint256(bridge.facility(id).nextPaymentDue) + defaultManager.graceWindow(FILM);
        assertEq(graceEnd, t0 + 51 days, "grace end");
        _warpTo(graceEnd + 1);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueReliefAnchor(), block.timestamp, "anchor at the mark");
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "mark engaged");
        reqIds[3] = _request(bob, bobShares - 3 * slice);
        _settleLeg("day51 at-mark w=50%", reqIds[1], slice);

        // ── leg 2: mid-ramp, day 61 ──
        _warpTo(t0 + 61 days);
        _settleLeg("day61 mid-ramp", reqIds[2], slice);

        // ── leg 3: past the ramp, day 73 ──
        _warpTo(t0 + 73 days);
        _settleLeg("day73 past-ramp", reqIds[3], bobShares - 3 * slice);
        assertEq(vault.balanceOf(bob), 0, "bob fully out");

        // ── declaration and full realization at day 80 ──
        _warpTo(t0 + 80 days);
        uint256 stayerNav = _declareAndRealize(id);

        // ── report: what each leaver took from the stayer ──
        uint256 totalPaid;
        for (uint256 i = 0; i < 4; ++i) {
            _reportLeg(legs[i], t0, stayerNav, aliceShares, i == 3);
            totalPaid += legs[i].paid;
        }
        emit log_named_uint("bob total paid", totalPaid);
        emit log_named_uint("bob shares at post-loss NAV", Math.mulDiv(bobShares, stayerNav, aliceShares));
    }

    /// @dev Declare, pin the full-weight mark against the live junior layers, realize the whole
    ///      face, verify the cascade split and return the stayer's post-loss NAV for aliceShares.
    function _declareAndRealize(uint256 id) internal returns (uint256 stayerNav) {
        uint256 predicted = _declareAndPin(id);
        uint256 faceDecl = reservesFace(id);
        uint256 curatorBefore = curator.poolBalance(FILM);
        uint256 coverageBefore = sGrove.coverageReserve();
        uint256 vaultBalBefore = usdfr.balanceOf(address(vault)) + reserves.accrualSnapshot().seniorUnissued;
        _realizeLoss(id, faceDecl, bytes32(0));
        assertEq(curator.poolBalance(FILM), 0, "layer 1 took its whole pool");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 took its whole reserve");
        uint256 vaultBurn = vaultBalBefore - usdfr.balanceOf(address(vault));
        emit log_named_uint("vault burn (layer 3)", vaultBurn);
        assertEq(vaultBurn, faceDecl - curatorBefore - coverageBefore, "layer 3 == face net of both junior layers");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "no mark survives a full realization");
        vault.accrueFees();
        stayerNav = vault.previewRedeem(stayerShares);
        emit log_named_uint("stayer NAV predicted by the declared mark", predicted);
        emit log_named_uint("stayer NAV after the loss", stayerNav);
        // the declared, full-weight, cascade-ordered mark predicted the post-loss NAV (rounding only)
        assertApproxEqAbs(stayerNav, predicted, 2e12, "declared mark != post-loss NAV");
    }

    /// @dev Declare and pin the full-weight mark against the live junior layers; returns the
    ///      stayer NAV the declared mark predicts.
    function _declareAndPin(uint256 id) internal returns (uint256 predicted) {
        (uint256 aPre,, uint256 sPre) = _pinPricing("pre-declare day80");
        uint256 facePre = reservesFace(id);
        _declareDefault(id, keccak256("OPEN_exit_R2 P1 default"));
        (uint256 aDecl, uint256 mDecl, uint256 sDecl) = _pinPricing("post-declare");
        uint256 faceDecl = reservesFace(id);
        // the declaration's stop reconciles the streamed carrier to the canonical closed form:
        // either a sub-unit positive correction (face up) or a sub-unit rounding loss charged to
        // the cascade (face down), and the intra-segment remainder credited to the senior leg.
        // Bounded below one grid unit either way; measured, not assumed.
        uint256 shift = faceDecl > facePre ? faceDecl - facePre : facePre - faceDecl;
        assertLt(shift, 1e12, "declaration reconciliation above one grid unit");
        emit log_named_int("declaration reconciliation (wei, + up / - down)", int256(faceDecl) - int256(facePre));
        shift = aDecl > aPre ? aDecl - aPre : aPre - aDecl;
        assertLt(shift, 1e12, "declaration moved realized assets by a grid unit or more");
        emit log_named_int("declaration vault-asset shift (wei)", int256(aDecl) - int256(aPre));
        assertEq(sDecl, sPre, "declaration does not move supply");
        // full weight, cascade-ordered: mark == face - live curator pool - live coverage exactly
        assertEq(
            mDecl,
            faceDecl - curator.poolBalance(FILM) - sGrove.coverageReserve(),
            "declared mark == face net of both junior layers"
        );
        predicted = Math.mulDiv(stayerShares, (aDecl - mDecl) + 1, sDecl + OFFSET, Math.Rounding.Floor);
    }

    function reservesFace(uint256 id) internal view returns (uint256) {
        return reserves.deployedTo(id);
    }

    function _reportLeg(Leg memory leg, uint256 t0, uint256 stayerNav, uint256 aliceShares, bool pastRamp) internal {
        uint256 atFinal = Math.mulDiv(leg.shares, stayerNav, aliceShares, Math.Rounding.Floor);
        emit log_string(leg.label);
        emit log_named_uint("  t - t0 (days)", (leg.t - t0) / 1 days);
        emit log_named_uint("  gross accrued on the book", leg.grossAccrued);
        emit log_named_uint("  face (deployedTo)", leg.face);
        emit log_named_uint("  vault assets", leg.assets);
        emit log_named_uint("  mark", leg.mark);
        emit log_named_uint("  paid", leg.paid);
        emit log_named_uint("  same shares at post-loss NAV", atFinal);
        emit log_named_int("  taken from the stayer", int256(leg.paid) - int256(atFinal));
        // The rule the code claims: paid <= the full-weight cascade-ordered NAV plus the ramp relief
        // (1 - w) on the marked amount. Past the ramp, paid <= that NAV exactly.
        uint256 fullMark = leg.face > C1 + B2 ? leg.face - C1 - B2 : 0;
        if (fullMark > leg.assets) fullMark = leg.assets;
        uint256 fullQuote = Math.mulDiv(leg.shares, leg.assets - fullMark + 1, leg.supply + OFFSET, Math.Rounding.Floor);
        emit log_named_uint("  full-weight cascade-ordered quote", fullQuote);
        if (pastRamp) assertLe(leg.paid, fullQuote, "past the ramp: paid above the cascade-ordered NAV");
    }

    function _exitAtPar(address who, uint256 u, uint256 target)
        internal
        returns (uint256 drawnCurator, uint256 drawnCoverage)
    {
        uint256 curatorBefore = curator.poolBalance(FILM);
        uint256 coverageBefore = sGrove.coverageReserve();
        uint256 usdcBefore = IERC20(USDC).balanceOf(who);
        vm.prank(who);
        uint256 usdcOut = controller.redeem(u, 0);
        assertEq(usdcOut, u / 1e12, "par exit out of the junior draw");
        assertEq(IERC20(USDC).balanceOf(who) - usdcBefore, usdcOut, "settled");
        drawnCurator = curatorBefore - curator.poolBalance(FILM);
        drawnCoverage = coverageBefore - sGrove.coverageReserve();
        emit log_named_uint("drawn from curator", drawnCurator);
        emit log_named_uint("drawn from coverage", drawnCoverage);
        assertEq(drawnCurator + drawnCoverage, target, "drawn == target");
        assertEq(drawnCurator, target < C1 ? target : C1, "curator first");
        assertEq(reserves.exitPrepaidAbsorption(), target, "prepaid recorded");
    }

    // ─────────────────────────────────────────────────────────────────────
    // P3. Under-backed USDfr exit on an accruing book (ADR-0034 Y-bis)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After 60 days of accrual on a 1M facility, governance recognizes a 300k principal
    ///         impairment (the G3 intervention shape). alice, an unstaked USDfr holder, exits
    ///         500k: the draw target must be computed on the EFFECTIVE supply (physical plus the
    ///         unissued accrued claims), the exit must settle at par, and the junior tranche must
    ///         be charged once across the draw and the later realization.
    function test_P3_underBackedExitDrawsJuniorOnEffectiveSupply() public onFork {
        (uint256 id,, uint256 t0) = _setup();
        _warpTo(t0 + 60 days);
        {
            IContinuousAccrual.Snapshot memory snap = reserves.accrualSnapshot();
            assertGt(snap.unissued, 0, "accrued claims stand unissued");
            assertEq(controller.totalUSDfr(), usdfr.totalSupply() + snap.unissued, "effective = physical + unissued");
        }
        vm.prank(ops);
        reserves.recognizePrincipalImpairment(id, 300_000e18, keccak256("OPEN_exit_R2 P3 impairment"));
        uint256 backing = controller.backingValue();
        uint256 deficit = controller.totalUSDfr() - backing;
        emit log_named_uint("deficit", deficit);
        assertEq(deficit, 300_000e18, "the accrual is symmetric: deficit == impairment exactly");
        // sUSDfr redemption NAV does NOT see a reserve-level impairment (only declared/past-due)
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "vault mark blind to reserve impairment");

        uint256 target = Math.mulDiv(500_000e18, deficit, backing, Math.Rounding.Ceil);
        emit log_named_uint("draw target ceil(u*D/B)", target);
        (uint256 drawnCurator, uint256 drawnCoverage) = _exitAtPar(alice, 500_000e18, target);
        assertEq(
            controller.totalUSDfr() - controller.backingValue(), deficit - target, "deficit telescopes by the draw"
        );
        _declareRealizeAndCheck(id, target, drawnCurator + drawnCoverage);
    }

    /// @dev Declare, measure the rounding close charged to layer 0, realize 300k and check the
    ///      layers: junior charged exactly once for its whole capacity, the vault the rest plus dust.
    function _declareRealizeAndCheck(uint256 id, uint256 target, uint256 drawn) internal {
        _declareDefault(id, keccak256("P3 default"));
        // the declaration's rounding close may charge a sub-unit loss to layer 0 (the prepaid
        // draw) and consume the same amount of the reserve mark; measure it rather than assume it
        uint256 dust = target - reserves.exitPrepaidAbsorption();
        emit log_named_uint("rounding loss charged to the prepaid draw at declaration", dust);
        assertLt(dust, 1e12, "rounding loss above one grid unit");
        uint256 vaultBefore = usdfr.balanceOf(address(vault)) + reserves.accrualSnapshot().seniorUnissued;
        uint256 curatorPre = curator.poolBalance(FILM);
        uint256 coveragePre = sGrove.coverageReserve();
        _realizeLoss(id, 300_000e18, bytes32(0));
        uint256 l1 = curatorPre - curator.poolBalance(FILM);
        uint256 l2 = coveragePre - sGrove.coverageReserve();
        uint256 l3 = vaultBefore - usdfr.balanceOf(address(vault));
        emit log_named_uint("realization layer 1", l1);
        emit log_named_uint("realization layer 2", l2);
        emit log_named_uint("realization layer 3", l3);
        assertEq(reserves.exitPrepaidAbsorption(), 0, "the whole prepaid draw was consumed");
        // junior is charged once: draw + realization layers 1 and 2 == C1 + B2 (its whole capacity)
        assertEq(drawn + l1 + l2, C1 + B2, "junior charged exactly its capacity, once");
        // the vault bears the remainder of the loss plus the sub-unit rounding loss, which is a
        // real extra loss (over-recognized interest already issued) landing past both junior layers
        assertEq(l3, 300_000e18 + dust - (C1 + B2), "vault bears loss + dust net of both junior layers");
        assertGe(controller.backingValue(), controller.totalUSDfr(), "whole again after the loss");
    }

    // ─────────────────────────────────────────────────────────────────────
    // P4. Cure and re-mark under accrual: the relief clock persists (S3-F3) and the
    //     accrual cohort joins and leaves exactly (no double count, no leak)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Mark at day 52, servicer cure at day 55, re-mark at day 58 on the same unpaid due
    ///         date. The anchor must stay at day 52 (no fresh benefit of the doubt), the past-due
    ///         pool must equal the live face exactly after each join, and the exit price must be
    ///         restored exactly while cleared.
    function test_P4_cureAndRemarkUnderAccrualKeepsTheClockAndTheCohortExact() public onFork {
        (uint256 id, uint256 aliceShares, uint256 t0) = _setup();
        uint256 graceEnd = uint256(bridge.facility(id).nextPaymentDue) + defaultManager.graceWindow(FILM);
        _warpTo(graceEnd + 1 days);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        uint256 anchor = defaultManager.pastDueReliefAnchor();
        assertEq(anchor, block.timestamp, "anchor at first mark");
        assertEq(defaultManager.pastDuePrincipal(FILM), reserves.deployedTo(id), "pool == face at the mark");
        _pinPricing("marked day52");

        // cohort tracks growth: three days later the pool still equals the live face to the wei
        _warpTo(t0 + 55 days);
        assertEq(defaultManager.pastDuePrincipal(FILM), reserves.deployedTo(id), "pool == face after growth");
        (, uint256 markBeforeCure,) = _pinPricing("marked day55");
        uint256 quoteMarked = vault.previewRedeem(aliceShares);

        // servicer cure with the attested fact
        bytes32 evidence = keccak256("OPEN_exit_R2 P4 cure");
        _attest(id, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(id, evidence)));
        vm.prank(ops);
        defaultManager.clearPastDue(id, evidence);
        assertEq(defaultManager.pastDuePrincipal(FILM), 0, "pool empty after cure");
        assertEq(reserves.accruedPastDue(FILM), 0, "cohort slope removed after cure");
        (uint256 aCured, uint256 mCured,) = _pinPricing("cured day55");
        assertEq(mCured, 0, "no mark while cured");
        assertEq(vault.redemptionTotalAssets(), aCured, "exit price restored exactly");
        assertGt(vault.previewRedeem(aliceShares), quoteMarked, "cure raised the quote");
        assertEq(defaultManager.pastDueReliefAnchor(), anchor, "anchor survives the cure");
        emit log_named_uint("mark before the cure", markBeforeCure);

        // re-mark the same unpaid due date three days later: the clock must not restart
        _warpTo(t0 + 58 days);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueReliefAnchor(), anchor, "S3-F3: the re-mark keeps the first anchor");
        assertEq(defaultManager.pastDuePrincipal(FILM), reserves.deployedTo(id), "pool == face at the re-mark");
        (, uint256 mRemark,) = _pinPricing("re-marked day58");
        // a restarted clock would price the mark at w0 = 50%; the persisted clock is 6 days in
        uint256 w = registry.pastDueRampWeightBps(block.timestamp - anchor);
        assertGt(w, registry.pastDueWeightBps(), "weight is past w0");
        emit log_named_uint("re-mark weight bps", w);
        emit log_named_uint("re-mark mark", mRemark);

        // and the cohort keeps tracking growth exactly after the second join
        _warpTo(t0 + 61 days);
        assertEq(defaultManager.pastDuePrincipal(FILM), reserves.deployedTo(id), "pool == face after second join");
        _pinPricing("re-marked day61");
    }
}
