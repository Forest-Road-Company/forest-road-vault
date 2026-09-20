// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MtmAtomicExecutor} from "../../src/MtmAtomicExecutor.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Correctness checks for the permissionless atomic valuation keeper on a pinned fork.
/// @dev Exercises current deployment wiring with continuous accrual enabled: mark acceptance
///      and rollback, facility eligibility, collateral thresholds, paused paths and freshness.
///      Liquidation uses the closed contractual face; margin calls and cures use the posted
///      streamed face. Eligible actions require a fresh book. Ineligible facilities return
///      the common state error before accessing their accrual records.
contract ATK_MtmAtomicExecutorForkTest is ForkLifecycleFixture {
    uint256 private constant CLASS5 = Config.CLASS_DIGITAL_ASSETS;
    bytes32 private constant DA_BORROWER = keccak256("FORK_DA_BORROWER");
    uint16 private constant MAX_LTV = 5000;
    uint16 private constant MARGIN_LTV = 6500;
    uint16 private constant LIQ_LTV = 8000;
    uint64 private constant MARK_AGE = 1 days;
    uint64 private constant CURE_WINDOW = 1 days;

    // The working facility (see MtmDigitalAssetsFork): 260,000 USDfr against a 1,000,000 mark.
    uint256 private constant P = 260_000e18;
    uint256 private constant V_ORIG = 1_000_000e18; // LTV 2600
    uint256 private constant V_HEALTHY = 500_000e18; // LTV 5200
    uint256 private constant V_MARGIN_EXACT = 400_000e18; // LTV 6500 on the principal
    uint256 private constant V_LIQ_EXACT = 325_000e18; // LTV 8000 on the principal
    uint256 private constant DA_RATE_BPS = 1000;
    uint256 private constant DA_TENOR = 180 days;

    // One second of accrual on the working facility, both bases (derived and pinned in
    // MtmDigitalAssetsFork::_pinOneSecondFigures; re-proved against the live engine in T2 here).
    //   I1       canonical contractual interest, floored to the 1e12 grid: the CLOSED face liquidate sees.
    //   I1_BOOK  the book's integer per-second slope: the POSTED face marginCall/clearMarginCall see.
    uint256 private constant I1 = 835_000_000_000_000;
    uint256 private constant I1_BOOK = 835_905_349_788_152;

    // A mark inside the one-second window where the two bases straddle the 8,000 bps threshold:
    //   (P + I1)      * 1e4 / V_STAR = 7999   (closed face: liquidate refuses)
    //   (P + I1_BOOK) * 1e4 / V_STAR = 8000   (posted face: marginCall opens a call AT the hard threshold)
    // The window is ((P + I1) * 1.25, (P + I1_BOOK) * 1.25], about 1.13e12 wei of mark value wide.
    uint256 private constant V_STAR = 325_000e18 + 1_044e12;

    MtmAtomicExecutor private executor;

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        executor = MtmAtomicExecutor(dep.mtmExecutor);
        require(address(executor.oracle()) == address(oracle), "executor oracle wiring");
        require(address(executor.defaultManager()) == address(defaultManager), "executor manager wiring");
    }

    // ─────────────────────────────────────────────────────────────────────
    // T1. The refusal surface: every non-canonical failure aborts the whole relay and
    //     the signed bundle stays usable; constructor guards; replay and same-block relays.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Executor surface enumerated (contracts/src/MtmAtomicExecutor.sol):
    ///         constructor :59-61 (zero address, no code x2); execute :75 (kind gate, before any
    ///         oracle call), :80 (oracle.attest bubbles), :101-102 (non-canonical liquidate failure
    ///         bubbles), :120 (marginCall failure bubbles). The relay is all-or-nothing, so each
    ///         refused bundle keeps its digest unburnt and the book on the prior mark.
    function test_atk_executor_refusalSurface_everyNonCanonicalFailureRollsTheMarkBack() public onFork {
        // Constructor guards (MtmAtomicExecutor.sol:59-61).
        vm.expectRevert(MtmAtomicExecutor.MtmExecutor_ZeroAddress.selector);
        new MtmAtomicExecutor(address(0), address(defaultManager));
        vm.expectRevert(MtmAtomicExecutor.MtmExecutor_ZeroAddress.selector);
        new MtmAtomicExecutor(address(oracle), address(0));
        vm.expectRevert(abi.encodeWithSelector(MtmAtomicExecutor.MtmExecutor_NoCode.selector, carol));
        new MtmAtomicExecutor(carol, address(defaultManager));
        vm.expectRevert(abi.encodeWithSelector(MtmAtomicExecutor.MtmExecutor_NoCode.selector, carol));
        new MtmAtomicExecutor(address(oracle), carol);

        uint256 id = _liveDigitalFacility(); // funded now, marked V_ORIG asOf now
        (uint256 markBefore, uint64 asOfBefore) = oracle.latestValuation(id);
        assertEq(markBefore, V_ORIG);

        // (a) A non-Valuation kind is refused before the oracle is touched (:75-77): the digest of a
        //     perfectly valid, signed PaymentReceived-shaped bundle is not consumed and the fact does
        //     not land, so the executor cannot be used as a generic attestation relay.
        {
            _warp(1);
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _signed(
                id, IAttestationOracle.AttestationKind.CreditIssued, keccak256("not-a-mark"), uint64(block.timestamp)
            );
            bytes32 digest = oracle.attestationDigest(a);
            vm.expectRevert(
                abi.encodeWithSelector(
                    MtmAtomicExecutor.MtmExecutor_NotValuation.selector, IAttestationOracle.AttestationKind.CreditIssued
                )
            );
            vm.prank(carol);
            executor.execute(a, sigs);
            assertFalse(oracle.digestUsed(digest), "kind gate precedes digest consumption");
        }

        // (b) A mark for a NOT-YET-MINTED id. The oracle accepts it (class-5 origination needs exactly
        //     such a mark), so `attest` would land it; through the executor `liquidate` reaches
        //     `bridge.facility` and bubbles `Bridge_UnknownToken` (:101-102). The executor is therefore
        //     NOT a channel for the pre-origination mark: that stays a direct `attest` responsibility.
        {
            uint256 unminted = bridge.totalOriginated() + 1;
            _relayExpectRevert(
                carol, unminted, V_ORIG, abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, unminted)
            );
            (uint256 v, uint64 t) = oracle.latestValuation(unminted);
            assertEq(v, 0, "no mark landed for the unminted id");
            assertEq(t, 0);
        }

        // (c) A receivable-class facility (FILM) with a mark: `DefaultManager_NotMarkedToMarket` bubbles.
        {
            uint256 filmId = _originateAndFund(100_000e18);
            _relayExpectRevert(
                carol,
                filmId,
                V_ORIG,
                abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, filmId)
            );
            (uint256 v,) = oracle.latestValuation(filmId);
            assertEq(v, 0, "the FILM facility carries no mark");
        }

        // (d) A fresh HEALTHY mark with no call standing: liquidate misses canonically (5200 < 8000),
        //     no call is active, so `marginCall` runs and its own miss (5200 < 6500) bubbles from :120.
        //     The mark is rolled back (the conservative direction, per the contract NatSpec), the
        //     digest is unburnt, and the very same bundle can then be relayed directly via `attest`.
        {
            _warp(1);
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
                _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_HEALTHY), uint64(block.timestamp));
            bytes32 digest = oracle.attestationDigest(a);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 5200, uint256(MARGIN_LTV)
                )
            );
            vm.prank(carol);
            executor.execute(a, sigs);
            assertFalse(oracle.digestUsed(digest), "healthy relay rolled the digest back");
            (uint256 v, uint64 t) = oracle.latestValuation(id);
            assertEq(v, markBefore, "book still on the prior mark");
            assertEq(t, asOfBefore);
            // The refused bundle is not damaged: a direct relay of the identical bytes lands it.
            vm.prank(carol);
            oracle.attest(a, sigs);
            (v, t) = oracle.latestValuation(id);
            assertEq(v, V_HEALTHY, "the same bundle lands through the plain oracle path");
            assertEq(t, uint64(block.timestamp));
        }

        // (e) A STALE mark (asOf older than maxMarkAge, still above the watermark): `liquidate`'s
        //     `DefaultManager_ValuationStale` is not canonical and bubbles; nothing lands.
        {
            _warp(uint256(MARK_AGE) + 2);
            uint64 staleAsOf = uint64(block.timestamp) - MARK_AGE - 1;
            (, uint64 latestAsOf) = oracle.latestValuation(id);
            assertGt(staleAsOf, latestAsOf, "stale bundle is still above the H-02 watermark");
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
                _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_LIQ_EXACT), staleAsOf);
            bytes32 digest = oracle.attestationDigest(a);
            vm.expectRevert(
                abi.encodeWithSelector(IDefaultManager.DefaultManager_ValuationStale.selector, id, staleAsOf, MARK_AGE)
            );
            vm.prank(carol);
            executor.execute(a, sigs);
            assertFalse(oracle.digestUsed(digest), "stale relay rolled back");
            (uint256 v,) = oracle.latestValuation(id);
            assertEq(v, V_HEALTHY, "stale breached mark did not displace the healthy one");
        }

        // (f) A paused protective layer: `EnforcedPause` bubbles (the contract forbids widening the
        //     catch to it: "the protective layer is down"). Guardian is ops on this deploy.
        {
            vm.prank(ops);
            defaultManager.pause();
            _relayExpectRevert(
                carol, id, V_LIQ_EXACT, abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector)
            );
            vm.prank(ops);
            defaultManager.unpause();
        }

        // (g) A real action, then the two same-block replays: the burnt digest and the H-02 watermark.
        {
            (, bytes32 digest, IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
                _relayExpect(carol, id, V_MARGIN_EXACT, MtmAtomicExecutor.Action.MarginCall);
            assertEq(defaultManager.cureDeadline(id), uint64(block.timestamp) + CURE_WINDOW, "call opened");

            vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, digest));
            vm.prank(carol);
            executor.execute(a, sigs);

            (IAttestationOracle.AttestationInput memory b, bytes[] memory bSigs) =
                _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_LIQ_EXACT), uint64(block.timestamp));
            b.nonce = uint256(keccak256("second-relay-same-second"));
            bytes32 bDigest = oracle.attestationDigest(b);
            bSigs = _sigsFor(bDigest);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAttestationOracle.Oracle_StaleValuation.selector, uint64(block.timestamp), uint64(block.timestamp)
                )
            );
            vm.prank(carol);
            executor.execute(b, bSigs);
            assertEq(
                uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "no second action landed"
            );
            assertEq(
                defaultManager.cureDeadline(id), uint64(block.timestamp) + CURE_WINDOW, "the standing call is unchanged"
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // T2. Selection: the hard breach wins over a standing call, the executor honours
    //     liquidate's own (closed-face) verdict, and a Defaulted relay is idempotent.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Branches: :87 liquidate success; :99-100 canonical NotDefaultable (G8-L2) keeps the
    ///         mark; :103-119 the no-call fallback to marginCall. Also the (KNOWN) accrued-face basis
    ///         as the EXECUTOR sees it: `liquidate` judges the closed canonical face, `marginCall` the
    ///         posted streamed face, and at V_STAR they disagree by one basis point for exactly one
    ///         second. The executor never overrides liquidate's own rule: it reports what each action's
    ///         own check decided, so a MarginCalled event can carry ltv 8000 (the hard threshold) with
    ///         `liquidate` still refusing at 7999 in the same second.
    function test_atk_executor_hardBreachWinsOverStandingCall_defaultedRelayIdempotent_basisWindow() public onFork {
        uint256 id = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);

        // Re-prove the two one-second figures against the live engine before relying on them.
        _warp(1);
        assertEq(reserves.accruedDebt(id).interest, I1, "canonical one-second interest");
        assertEq(reserves.accrualSnapshot().gross, I1_BOOK, "streamed one-second slope");
        assertEq((P + I1) * Config.BPS / V_STAR, 7999, "closed face at V_STAR");
        assertEq((P + I1_BOOK) * Config.BPS / V_STAR, 8000, "posted face at V_STAR");

        // (a) V_STAR at fundedAt + 1: liquidate refuses on the closed face (7999); no call stands, so the
        //     executor opens a margin call whose own event carries the posted-face LTV 8000.
        {
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
                _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_STAR), uint64(block.timestamp));
            bytes32 digest = oracle.attestationDigest(a);
            vm.expectEmit(true, false, false, true, address(defaultManager));
            emit IDefaultManager.MarginCalled(id, 8000, uint64(block.timestamp) + CURE_WINDOW);
            vm.expectEmit(true, true, true, true, address(executor));
            emit MtmAtomicExecutor.MtmActionExecuted(id, digest, carol, MtmAtomicExecutor.Action.MarginCall);
            vm.prank(carol);
            MtmAtomicExecutor.Action action = executor.execute(a, sigs);
            assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.MarginCall));
            (uint256 ltv,) = defaultManager.currentLtvBps(id);
            assertEq(ltv, 8000, "the view and the call both read the posted face: AT the hard threshold");
            assertEq(reserves.deployedTo(id), P + I1_BOOK, "posted face after marginCall's prepare(post)");
            // Direct liquidate in the same second: prepare(stop) closes the book to the canonical face
            // (P + I1) and refuses at 7999. Same mark, same second, one basis point apart.
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, 7999, uint256(LIQ_LTV)
                )
            );
            vm.prank(carol);
            defaultManager.liquidate(id);
            assertEq(reserves.deployedTo(id), P + I1_BOOK, "the refused liquidate rolled its closure back");
        }

        // (b) One second later the same value liquidates: the closed face has grown by a full second
        //     (P + 1,671e12) and clears 8000. The standing call does not slow the hard breach down:
        //     liquidate is tried first, succeeds, deletes the call; no clear/reopen is attempted.
        {
            vm.recordLogs();
            (, bytes32 digest,,) = _relayExpect(carol, id, V_STAR, MtmAtomicExecutor.Action.Liquidate);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(reserves.deployedTo(id), P + _coupon(P, DA_RATE_BPS, block.timestamp - fundedAt), "closed face");
            assertEq(reserves.deployedTo(id), P + 1_671e12, "two canonical seconds");
            assertTrue(_saw(logs, keccak256("LiquidationInitiated(uint256,uint256)")), "liquidation event");
            assertTrue(_saw(logs, keccak256("RemedyInitiated(uint256,uint256,bytes32)")), "remedy event");
            assertFalse(_saw(logs, keccak256("MarginCallCleared(uint256)")), "no clear attempted");
            assertFalse(_saw(logs, keccak256("MarginCallCleared(uint256,uint256)")), "no clear attempted");
            assertFalse(_saw(logs, keccak256("MarginCalled(uint256,uint256,uint64)")), "no second call opened");
            assertEq(_liquidationLtv(logs), 8000, "liquidate's own verdict on the closed face");
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
            assertEq(defaultManager.cureDeadline(id), 0, "the standing call was consumed by the liquidation");
            assertTrue(oracle.digestUsed(digest));
        }

        // (c) A Defaulted facility (G8-L2): `_mtmFacility` reports the exact canonical
        //     `DefaultManager_NotDefaultable(id)`; the executor keeps the mark and reports
        //     NoActionAvailable. Nothing in the default book moves.
        uint256 declaredBefore = defaultManager.declaredDefaultedPrincipal(CLASS5);
        uint256 backingBefore = reserves.totalBackingValue();
        {
            vm.recordLogs();
            (, bytes32 digest,,) =
                _relayExpect(carol, id, V_LIQ_EXACT - 1e18, MtmAtomicExecutor.Action.NoActionAvailable);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(oracle.digestUsed(digest), "the mark is KEPT on a defaulted facility");
            assertFalse(_saw(logs, keccak256("RemedyInitiated(uint256,uint256,bytes32)")), "no second remedy");
            assertFalse(_saw(logs, keccak256("LiquidationInitiated(uint256,uint256)")), "no second liquidation");
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
            assertEq(defaultManager.declaredDefaultedPrincipal(CLASS5), declaredBefore, "impairment pool unchanged");
            assertEq(reserves.totalBackingValue(), backingBefore, "a post-default mark does not move backing");
        }

        // (d) Same second, second bundle: H-02 refuses at the oracle, before any selection (:80).
        {
            (IAttestationOracle.AttestationInput memory b, bytes[] memory bSigs) = _signed(
                id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_LIQ_EXACT - 2e18), uint64(block.timestamp)
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAttestationOracle.Oracle_StaleValuation.selector, uint64(block.timestamp), uint64(block.timestamp)
                )
            );
            vm.prank(carol);
            executor.execute(b, bSigs);
            (uint256 v,) = oracle.latestValuation(id);
            assertEq(v, V_LIQ_EXACT - 1e18, "the first mark of the second stands");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // T3. A bystander (or the servicer by hand) opens the call; the executor's cure leg.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Branches: :103-118 activeCall fallback; :113-114 clearMarginCall success; :115-117
    ///         canonical cure miss (G8-L1) keeps the mark. The cure-expiry boundary is strict: at the
    ///         deadline second nothing is done and the mark lands (the code's G8-L1 behaviour; ADR-0032
    ///         "Decision" still says the whole transaction reverts there). One second later the same
    ///         value liquidates through the cure-expired trigger. After that, the borrower's cure
    ///         cannot land as a cure: the executor keeps the mark with no action, and the direct
    ///         `clearMarginCall` refuses.
    function test_atk_executor_bystanderCall_breachedRelayLands_cureClears_deadlineIsStrict() public onFork {
        uint256 id = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);

        // The servicer acts by hand: direct mark, direct marginCall.
        _mark(id, V_MARGIN_EXACT);
        vm.prank(ops);
        defaultManager.marginCall(id);
        uint64 deadline1 = defaultManager.cureDeadline(id);
        assertEq(deadline1, uint64(block.timestamp) + CURE_WINDOW);

        // (a) carol relays a still-breached fresh mark: liquidate misses (6500 < 8000), the call is
        //     active, clearMarginCall misses canonically (6500 >= 6500) so the mark is KEPT and the
        //     standing call is untouched. Before G8-L1 this relay reverted for the whole cure window.
        {
            uint256 backing0 = reserves.totalBackingValue();
            uint256 gross0 = reserves.accrualSnapshot().gross;
            (, bytes32 digest,,) = _relayExpect(carol, id, V_MARGIN_EXACT, MtmAtomicExecutor.Action.NoActionAvailable);
            assertTrue(oracle.digestUsed(digest), "still-breached mark kept");
            assertEq(defaultManager.cureDeadline(id), deadline1, "standing call untouched");
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
            // The executor's NatSpec (:28) and ADR-0032 say marks feed `totalBackingValue`. On this
            // source nothing outside DefaultManager._ltv and ClaimBridge reads `latestValuation`:
            // backing moved by exactly the second of accrual, not by the kept 400,000 mark.
            assertEq(
                reserves.totalBackingValue() - backing0,
                reserves.accrualSnapshot().gross - gross0,
                "a kept in-breach mark moves no backing; only the elapsed second of accrual does"
            );
        }

        // (b) The cure: a fresh healthy mark clears the call in the same transaction.
        {
            vm.recordLogs();
            _relayExpect(carol, id, V_HEALTHY, MtmAtomicExecutor.Action.ClearMarginCall);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(_saw(logs, keccak256("MarginCallCleared(uint256,uint256)")), "cleared");
            assertEq(defaultManager.cureDeadline(id), 0, "call cleared");
        }

        // (c) Re-breach through the executor: a new call, a new deadline.
        _relayExpect(carol, id, V_MARGIN_EXACT, MtmAtomicExecutor.Action.MarginCall);
        uint64 deadline2 = defaultManager.cureDeadline(id);
        assertEq(deadline2, uint64(block.timestamp) + CURE_WINDOW);

        // (d) AT the deadline second: not expired (strictly after), not a hard breach, not cured.
        //     The G8-L1 code keeps the mark and does nothing; the facility stays Active with the
        //     same deadline. (ADR-0032 text: "the whole transaction reverts"; the code does not.)
        {
            _warpTo(deadline2);
            (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) = _signed(
                id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_MARGIN_EXACT), uint64(block.timestamp)
            );
            bytes32 digest = oracle.attestationDigest(a);
            vm.expectEmit(true, true, true, true, address(executor));
            emit MtmAtomicExecutor.MtmActionExecuted(id, digest, carol, MtmAtomicExecutor.Action.NoActionAvailable);
            vm.prank(carol);
            executor.execute(a, sigs);
            assertTrue(oracle.digestUsed(digest), "the at-deadline mark lands");
            assertEq(
                uint256(bridge.facility(id).state),
                uint256(ClaimBridge.LoanState.Active),
                "no liquidation AT the deadline"
            );
            assertEq(defaultManager.cureDeadline(id), deadline2, "call neither cleared nor reopened");
        }

        // (e) One second after: the cure-expired trigger liquidates on the closed accrued face.
        {
            vm.recordLogs();
            _relayExpect(carol, id, V_MARGIN_EXACT, MtmAtomicExecutor.Action.Liquidate);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 closedFace = P + _coupon(P, DA_RATE_BPS, block.timestamp - fundedAt);
            assertEq(reserves.deployedTo(id), closedFace, "closed face at liquidation");
            uint256 expectedLtv = closedFace * Config.BPS / V_MARGIN_EXACT;
            assertGe(expectedLtv, MARGIN_LTV, "cure-expired trigger needs >= 6500");
            assertLt(expectedLtv, LIQ_LTV, "and this was NOT a hard breach");
            assertEq(
                _liquidationLtv(logs),
                expectedLtv,
                "liquidate's own verdict on the closed face (6501: a day and five seconds of accrual)"
            );
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
            assertEq(defaultManager.cureDeadline(id), 0);
        }

        // (f) The borrower's cure lands late. Through the executor the healthy mark is kept but no
        //     action is available; directly, clearMarginCall refuses. The liquidation stands.
        {
            (, bytes32 digest,,) = _relayExpect(borrower, id, V_HEALTHY, MtmAtomicExecutor.Action.NoActionAvailable);
            assertTrue(oracle.digestUsed(digest), "late cure mark is kept as a mark only");
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "not reopened");
            vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
            vm.prank(borrower);
            defaultManager.clearMarginCall(id);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // T4. A due, unprocessed book boundary closes the whole protective path, executor included,
    //     until ANYONE cranks; the refused bundle is then relayed unchanged.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Branch :101-102 (`_revert(reason)` for a non-canonical, non-DefaultManager error).
    ///         `liquidate`, `marginCall` and `clearMarginCall` all call `DefaultAccrualLib.prepare`,
    ///         which calls `ReserveManager.requireAccrualFresh`; at the facility's own segment end
    ///         (maturity - 1 s here) the book reverts `AccrualBook_BoundaryPending(at, at)` (the `==`
    ///         branch). The executor cannot checkpoint, so the canonical protective relay is closed
    ///         for the facility (and for every class-5 facility) until a permissionless
    ///         `checkpointAccrual`. The mtm-keeper never calls it (mtm-keeper/src has no reference).
    function test_atk_executor_dueBookBoundaryBlocksAllProtection_untilAnyoneCheckpoints() public onFork {
        uint256 id = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);

        // Walk to the only boundary of a cash loan: the planner ends the technical segment one second
        // before maturity (AccrualSegments.plan: capBoundary = capHit - 1). Confirm from the book itself.
        _warpTo(fundedAt + uint64(DA_TENOR) - 1);
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertFalse(s.fresh, "a boundary is due at this second");
        assertEq(s.accruedThrough, uint64(block.timestamp), "and it is due at exactly now (the == branch)");
        uint64 boundary = uint64(block.timestamp);

        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(V_LIQ_EXACT), uint64(block.timestamp));
        bytes32 digest = oracle.attestationDigest(a);
        bytes memory pending =
            abi.encodeWithSelector(AccrualBook.AccrualBook_BoundaryPending.selector, boundary, boundary);

        // (a) The executor bubbles the book's error and rolls the mark back: a hard breach cannot be
        //     acted on and cannot even be recorded through the canonical path.
        vm.expectRevert(pending);
        vm.prank(carol);
        executor.execute(a, sigs);
        assertFalse(oracle.digestUsed(digest), "bundle intact");
        (uint256 v,) = oracle.latestValuation(id);
        assertEq(v, V_ORIG, "book still on the origination mark");

        // (b) Nobody can act directly either: all three entry points share the freshness gate.
        vm.prank(ops);
        vm.expectRevert(pending);
        defaultManager.liquidate(id);
        vm.prank(ops);
        vm.expectRevert(pending);
        defaultManager.marginCall(id);
        vm.prank(ops);
        vm.expectRevert(pending);
        defaultManager.clearMarginCall(id);

        // (c) The plain oracle relay is NOT gated: the mark could land, but only unprotected.
        //     (Not exercised on this bundle, which must stay unburnt for (e).)

        // (d) Anyone cranks: one boundary processed, book fresh again, same second.
        vm.prank(carol);
        (uint256 processed, bool fresh) = reserves.checkpointAccrual(32);
        assertEq(processed, 1, "the segment end processed");
        assertTrue(fresh, "book fresh");

        // (e) The identical bundle now liquidates: 179 days 23:59:59 of accrual on the closed face.
        vm.expectEmit(true, true, true, true, address(executor));
        emit MtmAtomicExecutor.MtmActionExecuted(id, digest, carol, MtmAtomicExecutor.Action.Liquidate);
        vm.prank(carol);
        MtmAtomicExecutor.Action action = executor.execute(a, sigs);
        assertEq(uint256(action), uint256(MtmAtomicExecutor.Action.Liquidate));
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted));
        uint256 closedFace = P + _coupon(P, DA_RATE_BPS, DA_TENOR - 1);
        assertEq(reserves.deployedTo(id), closedFace, "closed face at the segment end");
        assertEq(closedFace * Config.BPS / V_LIQ_EXACT, 8399, "8399 bps on the accrued face (8000 on principal)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Pending and repaid facilities keep an accepted valuation without starting a margin action.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Every direct margin entrypoint returns NotDefaultable for these states.
    /// @dev The executor attempts liquidation first, recognizes that state error and keeps the
    ///      attested mark. Direct calls use the same eligibility rule before accrual work.
    function test_atk_executor_pendingAndRepaidFacility_relayKeepsMarkWithNoAction() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateDigital(P, V_ORIG, MAX_LTV); // Pending
        uint256 backingBefore = reserves.totalBackingValue();

        // Direct refusals on an unfunded facility use the common state error.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.marginCall(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.liquidate(id);

        // (a) The executor lands a breached mark on the Pending facility with no action, exactly as
        //     `attest` would. The consequence is the M-01 re-validation at funding, not a remedy:
        //     the low mark supports only 162,500 of the 260,000 principal.
        {
            (, bytes32 digest,,) = _relayExpect(carol, id, V_LIQ_EXACT, MtmAtomicExecutor.Action.NoActionAvailable);
            assertTrue(oracle.digestUsed(digest));
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending));
            assertEq(defaultManager.cureDeadline(id), 0, "no call on an unfunded facility");
            assertEq(reserves.totalBackingValue(), backingBefore, "an unfunded facility's mark moves no backing");
            uint256 maxByValue = V_LIQ_EXACT * uint256(MAX_LTV) / Config.BPS;
            assertEq(maxByValue, 162_500e18);
            vm.prank(ops);
            vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, P, maxByValue));
            waterfall.fund(id, P / 1e12);
        }

        // Recover the mark and fund: Active.
        _mark(id, V_ORIG);
        _fundDigital(id, P);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));

        // (b) Repay in full at the exact contractual figures: Repaid, nothing outstanding.
        _warp(1);
        IAccrualLifecycle.Debt memory d = reserves.accruedDebt(id);
        assertEq(d.interest, I1, "one canonical second owed");
        _repay(id, d.interest, d.principal);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid));
        assertEq(reserves.deployedTo(id), 0);

        // (c) A breached mark on a Repaid facility: kept, no action, no call, no backing move.
        backingBefore = reserves.totalBackingValue();
        {
            vm.recordLogs();
            (, bytes32 digest,,) = _relayExpect(carol, id, V_LIQ_EXACT, MtmAtomicExecutor.Action.NoActionAvailable);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(oracle.digestUsed(digest));
            assertFalse(_saw(logs, keccak256("MarginCalled(uint256,uint256,uint64)")));
            assertFalse(_saw(logs, keccak256("LiquidationInitiated(uint256,uint256)")));
            assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Repaid));
            assertEq(defaultManager.cureDeadline(id), 0);
            assertEq(reserves.totalBackingValue(), backingBefore, "a repaid facility's mark moves no backing");
        }
        // All three direct paths refuse the repaid facility before accessing its retired book entry.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.liquidate(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.marginCall(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.clearMarginCall(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (local; the shared fixture is not modified)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Relay `value` for `id` as `who` one second from now, expecting `expected` and the
    ///      canonical completion event; asserts the mark landed (digest burnt, latest == value @ now).
    function _relayExpect(address who, uint256 id, uint256 value, MtmAtomicExecutor.Action expected)
        private
        returns (
            MtmAtomicExecutor.Action action,
            bytes32 digest,
            IAttestationOracle.AttestationInput memory a,
            bytes[] memory sigs
        )
    {
        _warp(1);
        (a, sigs) = _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(value), uint64(block.timestamp));
        digest = oracle.attestationDigest(a);
        vm.expectEmit(true, true, true, true, address(executor));
        emit MtmAtomicExecutor.MtmActionExecuted(id, digest, who, expected);
        vm.prank(who);
        action = executor.execute(a, sigs);
        assertEq(uint256(action), uint256(expected), "action");
        assertTrue(oracle.digestUsed(digest), "digest burnt");
        (uint256 v, uint64 t) = oracle.latestValuation(id);
        assertEq(v, value, "mark landed");
        assertEq(t, uint64(block.timestamp), "mark asOf");
    }

    /// @dev Relay `value` for `id` as `who` one second from now, expecting exactly `revertData`;
    ///      asserts the digest is unburnt afterwards.
    function _relayExpectRevert(address who, uint256 id, uint256 value, bytes memory revertData) private {
        _warp(1);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signed(id, IAttestationOracle.AttestationKind.Valuation, bytes32(value), uint64(block.timestamp));
        bytes32 digest = oracle.attestationDigest(a);
        vm.expectRevert(revertData);
        vm.prank(who);
        executor.execute(a, sigs);
        assertFalse(oracle.digestUsed(digest), "refused relay left the digest unburnt");
    }

    /// @dev Build and sign a bundle WITHOUT submitting it (the fixture's `_attestAt` submits).
    function _signed(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf)
        private
        view
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: uint256(keccak256(abi.encode("atk-mtm-executor", facilityId, kind, payload, asOf, block.timestamp)))
        });
        sigs = _sigsFor(oracle.attestationDigest(a));
    }

    function _sigsFor(bytes32 digest) private pure returns (bytes[] memory sigs) {
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(lo, digest);
        sigs[0] = abi.encodePacked(r0, s0, v0);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hi, digest);
        sigs[1] = abi.encodePacked(r1, s1, v1);
    }

    /// @dev Post a fresh 2-of-n mark directly (one second on, for the H-02 watermark).
    function _mark(uint256 facilityId, uint256 value) private {
        _warp(1);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signed(facilityId, IAttestationOracle.AttestationKind.Valuation, bytes32(value), uint64(block.timestamp));
        oracle.attest(a, sigs);
    }

    function _originateDigital(uint256 principal, uint256 markValue, uint16 ltvBps) private returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("da-custody"));
        _mark(tokenId, markValue);
        uint64 maturity = uint64(block.timestamp + DA_TENOR);
        _attestDaTerms(tokenId, principal, ltvBps, uint16(DA_RATE_BPS), maturity);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, _daTerms(principal, ltvBps, uint16(DA_RATE_BPS), maturity));
        require(id == tokenId, "atk mtm executor: tokenId drift");
    }

    function _attestDaTerms(uint256 tokenId, uint256 principal, uint16 ltvBps, uint16 interestRateBps, uint64 maturity)
        private
    {
        bytes32 want = bridge.creditTermsHash(_daTerms(principal, ltvBps, interestRateBps, maturity));
        (bytes32 assignment,, bool assignmentStanding) =
            oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted);
        if (!assignmentStanding || assignment != want) {
            _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, want);
        }
        (bytes32 credit,, bool creditStanding) =
            oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.CreditIssued);
        if (!creditStanding || credit != want) {
            _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, want);
        }
    }

    function _fundDigital(uint256 tokenId, uint256 principal) private {
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    function _daTerms(uint256 principal, uint16 ltvBps, uint16 interestRateBps, uint64 maturity)
        private
        view
        returns (ClaimBridge.OriginationTerms memory)
    {
        return _forkTermsFor(
            CLASS5, DA_BORROWER, bytes32(0), principal, ltvBps, interestRateBps, maturity, keccak256("da-ref")
        );
    }

    /// @dev 260,000 of principal, funded, marked at 1,000,000 (LTV 2600).
    function _liveDigitalFacility() private returns (uint256 tokenId) {
        _mintFromUSDC(alice, 2_000_000e6);
        tokenId = _originateDigital(P, V_ORIG, MAX_LTV);
        _fundDigital(tokenId, P);
    }

    /// @dev Actual/360 simple interest floored to the 1e12 grid: the canonical closed-face figure.
    function _coupon(uint256 principal, uint256 rateBps, uint256 secs) private pure returns (uint256) {
        return (principal * rateBps * secs / (10_000 * 360 days)) / 1e12 * 1e12;
    }

    function _warpTo(uint64 target) private {
        require(target >= block.timestamp, "warpTo backwards");
        _warp(target - block.timestamp);
    }

    function _saw(Vm.Log[] memory logs, bytes32 topic0) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }

    /// @dev The `ltvBps` argument of the (single) LiquidationInitiated event in `logs`.
    function _liquidationLtv(Vm.Log[] memory logs) private pure returns (uint256 ltv) {
        bytes32 topic0 = keccak256("LiquidationInitiated(uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                require(!found, "two liquidation events");
                found = true;
                ltv = abi.decode(logs[i].data, (uint256));
            }
        }
        require(found, "no LiquidationInitiated event");
    }
}
