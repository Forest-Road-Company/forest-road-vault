// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {ReserveRoundingLib} from "../../src/libraries/ReserveRoundingLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title MtmDigitalAssetsFork — the marked-to-market Digital Assets class (ADR-0015),
///        end to end on a pinned mainnet fork
/// @notice Class 5 is the ONLY class whose remedy model is margin/liquidation rather than
///         legal enforcement, and the only one whose mint gate reads a VALUATION. Nothing in
///         the repo had ever driven that path against the real deploy script's wiring and a
///         real 6-decimal USDC leg: `script/QA.s.sol` never originated a class-5 facility at
///         all, and the in-memory `DefaultManager` unit suite uses a hand-built fixture whose
///         class parameters are set by the test rather than by `Deploy.s.sol`.
///
///         What this suite pins, and why each matters:
///           - the class-5 MINT GATE is `AssignmentExecuted | CreditIssued | Valuation`
///             (bits 0, 2 and 7), NOT the receivable set
///             `AssignmentExecuted | UCCFiled | CreditIssued`. A facility must therefore mint
///             with no UCC filing ever attested, and must NOT mint without a fresh mark.
///             AUDIT FIX (H-4): `CreditIssued` joined this gate — it is the 2-of-n quorum whose
///             payload binds the facility's terms — so the asymmetry is now about the UCC
///             filing alone, not about whether an amount was ever authorized;
///           - the marked-to-market origination extension: mark freshness (`maxMarkAge`) and
///             the value bound `principal <= value * ltvBps / BPS`, at origination AND again
///             at funding (the M-01 re-validation);
///           - the full margin lifecycle: healthy -> mark falls -> permissionless
///             `marginCall` -> `cureDeadline` -> cure (fresh mark OR principal repayment) ->
///             `clearMarginCall`; and separately cure expiry -> `liquidate`;
///           - fresh valuation evidence is required for margin calls, liquidation and cures;
///             an expired mark cannot authorize any of those three actions;
///           - the thresholds binding EXACTLY at 6500 / 8000 bps (6499 and 7999 must not);
///           - liquidation feeding the same three-layer cascade and ADR-0022 impairment pool
///             as a receivable default, with exact per-layer figures.
///
/// @dev FIXTURE CAPABILITIES ADDED LOCALLY (the shared fixture is not modified): a valuation
///      builder/signer (`_signedValuation`) so a bundle can be constructed and handed to
///      `vm.expectRevert` without the digest call consuming the cheatcode, and `_mark`, which
///      advances one second before each mark because the H-02 anti-rollback watermark demands
///      a STRICTLY increasing `asOf` — two marks in one block are rejected by design.
contract MtmDigitalAssetsForkTest is ForkLifecycleFixture {
    // ── the class under test ─────────────────────────────────────────────
    uint256 private constant CLASS5 = Config.CLASS_DIGITAL_ASSETS;
    bytes32 private constant DA_BORROWER = keccak256("FORK_DA_BORROWER");

    // Deploy.s.sol's genesis class-5 parameters. Asserted field-by-field in
    // `test_fork_mtm_classParamsAndMintGateDifferFromReceivableClasses`, then used as
    // literals everywhere else so a silent parameter change fails loudly here.
    uint16 private constant MAX_LTV = 5000;
    uint16 private constant MARGIN_LTV = 6500;
    uint16 private constant LIQ_LTV = 8000;
    uint64 private constant MARK_AGE = 1 days;

    // The working facility: 260,000 USDfr of principal against a 1,000,000 mark.
    // 260k is chosen because 10000/6500 and 10000/8000 both divide it exactly, so the two
    // thresholds land on WHOLE marks and the boundary can be pinned to the bps rather than
    // asserted "approximately".
    uint256 private constant P = 260_000e18;
    uint256 private constant V_ORIG = 1_000_000e18; // LTV 2600
    uint256 private constant V_MARGIN_EXACT = 400_000e18; // LTV 6500 exactly -> callable
    uint256 private constant V_MARGIN_MISS = 400_001e18; // LTV 6499 -> NOT callable
    uint256 private constant V_LIQ_EXACT = 325_000e18; // LTV 8000 exactly -> liquidatable
    uint256 private constant V_LIQ_MISS = 325_001e18; // LTV 7999 -> NOT liquidatable
    uint256 private constant V_HEALTHY = 500_000e18; // LTV 5200

    // ADR-0038 (continuous accrual) figures for the working facility. `_mark` warps one second
    // before every mark (H-02 watermark), so at any margin action taken straight after a mark
    // the facility has earned exactly ONE SECOND of 1000 bps Actual/360 interest, and under
    // ADR-0038 Q1/Q2 ("Full face"; accrual stops "At default declaration") that second is part
    // of the at-risk face. Three distinct one-second figures exist; each is derived, and
    // `_pinOneSecondFigures` proves every literal against its closed form and the live engine:
    //   I1        the canonical contractual interest, floored to the 1e12 USDC grid
    //             (AccrualSegments.cumulative): _coupon(P, 1000, 1) = floor(835,905,349,794,238 / 1e12) * 1e12.
    //   I1_BOOK   the book's integer per-second slope (AccrualBook.open: amount / (end - start)).
    //             The 13,000e18 ceiling is reached exactly at the 180-day maturity, so the planner
    //             (AccrualSegments.plan) ends the only technical segment one second before it:
    //             duration 180 days - 1 = 15,551,999 s, endpoint _coupon(P, 1000, 15,551,999) =
    //             12,999,999,164e12, slope = 12,999,999,164e12 / 15,551,999 = 835,905,349,788,152.
    //   I1_ROUND  the closure rounding loss: the book streamed I1_BOOK but the contract owes I1, so
    //             AccrualLoans._close burns I1_BOOK - I1 through the three-layer cascade
    //             (ReserveRoundingLib.allocate: curator, then sGROVE, then senior).
    //   I1_SENIOR the senior share of the streamed second, materialized at closure: I1_BOOK less
    //             the floored 10% protocol interest fee (AccrualBook.snapshot: mulDiv(gross, 1000, 10_000)).
    //   I1_REM    the segment remainder the integer slope leaves behind: endpoint - slope * duration
    //             = 12,999,999,164e12 - 835,905,349,788,152 * 15,551,999 = 9,884,152 wei. Before an
    //             authenticated lifecycle action the book recognizes its cumulative share exactly
    //             (AccrualBook.reconcile: floor(remainder * elapsed / duration)), so the gross the
    //             book has streamed `secs` after funding is `_streamed(secs)` below, not slope * secs.
    uint256 private constant DA_RATE_BPS = 1000;
    uint256 private constant DA_TENOR = 180 days;
    uint256 private constant I1 = 835_000_000_000_000;
    uint256 private constant I1_BOOK = 835_905_349_788_152;
    uint256 private constant I1_ROUND = I1_BOOK - I1; // 905,349,788,152
    uint256 private constant I1_SENIOR = I1_BOOK - I1_BOOK / 10; // 752,314,814,809,337
    uint256 private constant I1_REM = 9_884_152;

    // ─────────────────────────────────────────────────────────────────────
    // 1. THE CLASS ITSELF: parameters and the mint-gate asymmetry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Class 5's model, thresholds and mint gate are structurally different from the
    ///         four receivable classes — pinned exactly, from the REAL deploy script's seeding.
    function test_fork_mtm_classParamsAndMintGateDifferFromReceivableClasses() public onFork {
        ICollateralRegistry.ClassParams memory p = registry.classParams(CLASS5);
        assertEq(
            uint256(p.model),
            uint256(ICollateralRegistry.CollateralModel.MarkedToMarket),
            "class 5 is the marked-to-market model (ADR-0015)"
        );
        assertTrue(p.active, "class 5 is live at genesis");
        assertEq(uint256(p.maxLtvBps), uint256(MAX_LTV), "initial draw ceiling is 50%");
        assertEq(uint256(p.maxMaturity), 365 days, "one-year maximum tenor");
        assertEq(uint256(p.marginCallLtvBps), uint256(MARGIN_LTV), "margin call at 65%");
        assertEq(uint256(p.liquidationLtvBps), uint256(LIQ_LTV), "liquidation at 80%");
        assertEq(uint256(p.maxMarkAge), uint256(MARK_AGE), "marks go stale after one day");

        // The receivable classes carry NO margin model at all — the fields are zero, so the
        // margin path cannot be reached for them even by mis-set thresholds.
        for (uint256 classId = 1; classId <= 4; ++classId) {
            ICollateralRegistry.ClassParams memory r = registry.classParams(classId);
            assertEq(
                uint256(r.model), uint256(ICollateralRegistry.CollateralModel.Receivable), "classes 1-4 are receivable"
            );
            assertEq(uint256(r.marginCallLtvBps), 0, "no margin threshold on a receivable class");
            assertEq(uint256(r.liquidationLtvBps), 0, "no liquidation threshold either");
            assertEq(uint256(r.maxMarkAge), 0, "and no mark-freshness bound");
        }

        // THE MINT-GATE ASYMMETRY.
        uint256 bitAssignment = 1 << uint256(IAttestationOracle.AttestationKind.AssignmentExecuted);
        uint256 bitUcc = 1 << uint256(IAttestationOracle.AttestationKind.UCCFiled);
        uint256 bitCredit = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
        uint256 bitValuation = 1 << uint256(IAttestationOracle.AttestationKind.Valuation);

        // AUDIT FIX (H-4): CreditIssued (bit 2) joined EVERY class gate — it is the 2-of-n
        // quorum whose payload the mint gate binds the facility's terms to. Class 5's gate is
        // therefore bits 0, 2 and 5 == 37 in the clean-v1 compact enum; the asymmetry
        // that remains is UCCFiled.
        assertEq(bridge.requiredMintAttestations(CLASS5), bitAssignment | bitCredit | bitValuation, "class 5 gate");
        assertEq(bridge.requiredMintAttestations(CLASS5), 37, "class 5 gate is bits 0, 2 and 5 == 37");
        for (uint256 classId = 1; classId <= 4; ++classId) {
            assertEq(bridge.requiredMintAttestations(classId), bitAssignment | bitUcc | bitCredit, "receivable gate");
            assertEq(bridge.requiredMintAttestations(classId), 7, "receivable gate is bits 0,1,2 == 7");
        }
        // Neither gate is a superset of the other: this is a DIFFERENT evidence set, not a
        // looser one.
        assertEq(bridge.requiredMintAttestations(CLASS5) & bitUcc, 0, "class 5 does not require a UCC filing");
        assertTrue(bridge.requiredMintAttestations(CLASS5) & bitCredit != 0, "but it DOES require attested terms");
        assertEq(bridge.requiredMintAttestations(1) & bitValuation, 0, "receivables do not require a mark");

        // The mark is a high-value kind: a single compromised attester cannot move it.
        assertEq(uint256(oracle.threshold(IAttestationOracle.AttestationKind.Valuation)), 2, "marks are 2-of-n");
        // Every class is seeded with the ADR-0015 cure window at initialize().
        assertEq(
            uint256(defaultManager.cureWindow(CLASS5)),
            uint256(Config.DEFAULT_MARGIN_CURE_WINDOW),
            "class 5 cure window"
        );
        assertEq(defaultManager.backstop(), address(sGrove), "cascade layer 2 is wired");
    }

    /// @notice The class-5 gate demands a VALUATION and still does not demand a UCC filing.
    /// @dev DELIBERATE SEMANTIC UPDATE (AUDIT FIX H-4). This test previously asserted that a
    ///      class-5 facility mints with CreditIssued NEVER ATTESTED AT ALL — i.e. with no
    ///      attested amount or counterparty anywhere. That is exactly the hole H-4 closes, so
    ///      the assertion is inverted: CreditIssued is now attested and BOUND to the terms.
    ///      What survives unchanged is the real asymmetry — no UCC filing is ever required.
    function test_fork_mtm_mintGate_requiresAValuationAndNotTheReceivableSet() public onFork {
        uint256 nextId = bridge.totalOriginated() + 1;
        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("da-custody"));

        uint64 maturity = uint64(block.timestamp + 180 days);
        _attestDaTerms(nextId, P, MAX_LTV, 1000, maturity);
        ClaimBridge.OriginationTerms memory terms = _daTerms(P, MAX_LTV, 1000, maturity);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector, CLASS5, IAttestationOracle.AttestationKind.Valuation
            )
        );
        bridge.originate(ops, terms);

        // The mark is attested against the NOT-YET-MINTED id — `originate` reads `$.nextId`.
        // That operational subtlety is the whole reason a class-5 origination is a two-step
        // dance, so pin it explicitly.
        assertEq(bridge.totalOriginated() + 1, nextId, "the failed originate did not consume the id");
        _mark(nextId, V_ORIG);
        (uint256 markValue, uint64 markAsOf) = oracle.latestValuation(nextId);
        assertEq(markValue, V_ORIG, "the mark is recorded against the future tokenId");
        assertEq(markAsOf, uint64(block.timestamp), "and observed now");

        maturity = uint64(block.timestamp + 180 days);
        _attestDaTerms(nextId, P, MAX_LTV, 1000, maturity);
        terms = _daTerms(P, MAX_LTV, 1000, maturity);
        vm.prank(ops);
        uint256 tokenId = bridge.originate(ops, terms);
        assertEq(tokenId, nextId, "minted the id the mark was attested against");

        // THE ASYMMETRY, stated as facts about the live oracle: the facility exists and these
        // two receivable-class facts were NEVER attested for it.
        assertFalse(
            oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.UCCFiled),
            "no UCC filing was ever attested for this facility"
        );
        // AUDIT FIX (H-4): the terms quorum IS attested for this facility, and its payload
        // commits to the exact facility that minted.
        (bytes32 termsPayload,, bool termsOk) =
            oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.CreditIssued);
        assertTrue(termsOk, "the terms quorum stands");
        assertEq(termsPayload, bridge.creditTermsHash(terms), "and it commits to THESE terms");
        assertTrue(oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.Valuation), "the mark stands");

        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        assertEq(f.classId, CLASS5, "class 5");
        assertEq(uint256(f.state), uint256(ClaimBridge.LoanState.Pending), "minted pending");
        assertEq(uint256(f.interestRateBps), 1000, "signed facility rate");
        assertEq(f.principal, P, "principal recorded");
        assertEq(registry.classExposure(CLASS5), P, "exposure booked atomically at mint");

        // The converse: the RECEIVABLE gate is not satisfied by Assignment + Valuation.
        uint256 filmId = bridge.totalOriginated() + 1;
        _attest(filmId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("assign"));
        _mark(filmId, V_ORIG);
        uint64 filmMaturity = uint64(block.timestamp + 180 days);
        ClaimBridge.OriginationTerms memory filmTerms =
            _forkTerms(keccak256("FILM_B"), keccak256("US-GA"), P, 7500, filmMaturity, keccak256("ref"));
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.UCCFiled
            )
        );
        bridge.originate(ops, filmTerms);
    }

    /// @notice The marked-to-market origination extension: a STALE mark blocks the mint, and
    ///         the value bound `principal <= value * ltvBps / BPS` binds to the wei.
    function test_fork_mtm_mintGate_staleMarkRefusedAndValueBoundBindsExactly() public onFork {
        uint256 nextId = bridge.totalOriginated() + 1;
        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("da-custody"));
        _mark(nextId, V_ORIG);
        (, uint64 staleAsOf) = oracle.latestValuation(nextId);

        // one second past the freshness bound
        _warp(uint256(MARK_AGE) + 1);
        uint64 maturity = uint64(block.timestamp + 180 days);
        _attestDaTerms(nextId, P, MAX_LTV, 1000, maturity);
        ClaimBridge.OriginationTerms memory terms = _daTerms(P, MAX_LTV, 1000, maturity);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_ValuationStale.selector, 0, staleAsOf, MARK_AGE));
        bridge.originate(ops, terms);

        // exactly AT the bound the mark is still good (the check is `>`, not `>=`)
        _mark(nextId, V_ORIG);
        (, uint64 freshAsOf) = oracle.latestValuation(nextId);
        _warp(uint256(MARK_AGE));
        assertEq(block.timestamp - freshAsOf, uint256(MARK_AGE), "the mark is exactly maxMarkAge old");

        // value bound: maxByValue = 1,000,000 * 5000 / 10000 = 500,000
        uint256 maxByValue = V_ORIG * uint256(MAX_LTV) / Config.BPS;
        assertEq(maxByValue, 500_000e18, "the draw ceiling implied by the mark");
        maturity = uint64(block.timestamp + 180 days);
        _attestDaTerms(nextId, maxByValue + 1, MAX_LTV, 1000, maturity);
        terms = _daTerms(maxByValue + 1, MAX_LTV, 1000, maturity);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, maxByValue + 1, maxByValue));
        bridge.originate(ops, terms);

        // an ltvBps above the class ceiling is refused before the value bound is even reached
        // (and before the terms binding — the on-chain conditions run first)
        vm.prank(ops);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(ops, _daTerms(P, MAX_LTV + 1, 1000, maturity));

        // and so is a tenor beyond the class's 365-day maximum
        uint64 tooLong = uint64(block.timestamp + 366 days);
        vm.prank(ops);
        vm.expectRevert(ClaimBridge.Bridge_BadFacility.selector);
        bridge.originate(ops, _daTerms(P, MAX_LTV, 1000, tooLong));

        // exactly at the value bound, it mints (terms re-attested for the amount drawn)
        _attestDaTerms(nextId, maxByValue, MAX_LTV, 1000, maturity);
        vm.prank(ops);
        uint256 tokenId = bridge.originate(ops, _daTerms(maxByValue, MAX_LTV, 1000, maturity));
        assertEq(bridge.facility(tokenId).principal, maxByValue, "principal == the exact value bound");
    }

    /// @notice The M-01 re-validation on the marked-to-market path: a mark that decays or
    ///         falls BETWEEN origination and funding stops capital leaving the treasury.
    function test_fork_mtm_fundGate_revalidatesFreshnessAndValueBound() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 tokenId = _originateDigital(P, V_ORIG, MAX_LTV);

        // (a) the mark FALLS below the value bound while the facility sits pending
        _mark(tokenId, V_HEALTHY); // 500,000 -> maxByValue 250,000 < principal 260,000
        uint256 maxByValue = V_HEALTHY * uint256(MAX_LTV) / Config.BPS;
        assertEq(maxByValue, 250_000e18, "the fallen mark supports only 250k");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, P, maxByValue));
        waterfall.fund(tokenId, P / 1e12);

        // (b) the mark RECOVERS but goes stale before the servicer acts
        _mark(tokenId, V_ORIG);
        (, uint64 asOf) = oracle.latestValuation(tokenId);
        _warp(uint256(MARK_AGE) + 1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_ValuationStale.selector, tokenId, asOf, MARK_AGE));
        waterfall.fund(tokenId, P / 1e12);

        // (c) fresh mark, within the bound: funds move, with the 2% OID applied
        _mark(tokenId, V_ORIG);
        uint256 borrowerBefore = _usdc(borrower);
        vm.prank(ops);
        waterfall.fund(tokenId, P / 1e12);

        assertEq(_usdc(borrower) - borrowerBefore, 254_800e6, "borrower nets 260,000 less the 2% origination fee");
        assertEq(reserves.deployedTo(tokenId), P, "deployed principal is the FULL claim (fee capitalized)");
        assertEq(
            uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Active), "facility is now active"
        );
        (uint256 ltv,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltv, 2600, "260,000 against a 1,000,000 mark is 2600 bps");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds after deployment");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. THE MARGIN LIFECYCLE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The margin-call threshold binds EXACTLY at 6500 bps: 6499 must not call, 6500
    ///         must — and the call is permissionless (carol holds nothing and is not KYC'd).
    function test_fork_mtm_marginCallThresholdBindsExactlyAt6500AndIsPermissionless() public onFork {
        uint256 tokenId = _liveDigitalFacility();

        // carol is the adversarial "anyone": no roles, no KYC.
        assertFalse(compliance.isAllowed(carol), "carol is deliberately not KYC'd");
        assertFalse(defaultManager.hasRole(Roles.SERVICER_ROLE, carol), "carol is not a servicer");
        assertFalse(defaultManager.hasRole(Roles.GUARDIAN_ROLE, carol), "carol is not the guardian");
        assertFalse(defaultManager.hasRole(bytes32(0), carol), "carol is not an admin");

        // healthy: 2600 bps
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 2600, uint256(MARGIN_LTV)
            )
        );
        defaultManager.marginCall(tokenId);

        // one bps short: 6499
        _mark(tokenId, V_MARGIN_MISS);
        (uint256 ltvMiss,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltvMiss, 6499, "400,001 supports an LTV of 6499 bps");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 6499, uint256(MARGIN_LTV)
            )
        );
        defaultManager.marginCall(tokenId);
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "no cure window opened");

        // exactly at the threshold: 6500
        _mark(tokenId, V_MARGIN_EXACT);
        (uint256 ltvHit,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltvHit, 6500, "400,000 supports an LTV of exactly 6500 bps");

        uint64 expectedDeadline = uint64(block.timestamp) + Config.DEFAULT_MARGIN_CURE_WINDOW;
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.MarginCalled(tokenId, 6500, expectedDeadline);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), expectedDeadline, "cure window opened for exactly one day");

        // a second call while one stands is refused
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_AlreadyMarginCalled.selector, tokenId));
        defaultManager.marginCall(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), expectedDeadline, "the deadline was not extended");
    }

    /// @notice CURE ROUTE 1 — post more collateral. Off-chain the borrower tops up custody;
    ///         on-chain that is a fresh, higher mark, and it clears the call.
    function test_fork_mtm_cureByPostingCollateral_freshHigherMarkClearsTheCall() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        assertGt(uint256(defaultManager.cureDeadline(tokenId)), 0, "call stands");

        // still breached: curing is refused on the threshold, not silently accepted
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 6500, uint256(MARGIN_LTV)
            )
        );
        defaultManager.clearMarginCall(tokenId);

        // collateral posted -> mark rises to 500,000 -> LTV 5200
        _mark(tokenId, V_HEALTHY);
        (uint256 ltv,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltv, 5200, "260,000 against a 500,000 mark is 5200 bps");

        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.MarginCallCleared(tokenId, 5200);
        vm.prank(carol);
        defaultManager.clearMarginCall(tokenId);
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "cure window closed");

        // and the state is genuinely back to normal
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoMarginCall.selector, tokenId));
        defaultManager.clearMarginCall(tokenId);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 5200, uint256(MARGIN_LTV)
            )
        );
        defaultManager.marginCall(tokenId);
    }

    /// @notice CURE ROUTE 2, repay principal. The LTV numerator falls through the real
    ///         waterfall (attested PaymentReceived, exposure released) and the margin path keeps
    ///         working while the facility is Amortizing.
    ///
    ///         ADR-0038 changed the interest leg. Interest is recognized continuously and a cash
    ///         interest leg DISCHARGES what the engine has already accrued rather than minting new
    ///         income: a leg above the accrued coupon is refused (`AccrualLoans_PaymentAboveDebt`,
    ///         ADR-0038 "Decision" item 4, "Recognition must not double-count"). So the cure runs
    ///         twelve hours after the margin call, inside `MARK_AGE`, and pays exactly the engine's
    ///         coupon, which is pinned to the note's closed form. The 10% protocol interest fee is
    ///         NOT minted inside `distribute` ("A receipt matching recognized income reclassifies
    ///         that same claim into cash and does not charge either fee again",
    ///         docs/remediation/CONTINUOUS_ACCRUAL_OWNER_DIRECTIONS_2026-09-11.md, "Both existing
    ///         fees on both interest types"); it stays a reserve claim that anyone can deliver
    ///         through `materializeAccrued` (ADR-0038 "Implementation mechanism and checkpoint").
    ///         This test drives that delivery from a roleless caller and pins the PHYSICAL split
    ///         that the pre-ADR-0038 version pinned at receipt, to the wei: the fee is the floored
    ///         10% of the gross the book has STREAMED to the receipt (`_streamed`, the integer
    ///         slope plus the reconciled remainder share, ADR-0038 "Implementation mechanism and
    ///         checkpoint": the exact cumulative interpolation is recognized before a lifecycle
    ///         action), the senior vault holds the canonical coupon less that fee (the streamed
    ///         excess over the coupon is the closure rounding loss, burned from the senior because
    ///         no junior capital is posted in this shape, ADR-0038 Q3), nothing is left virtual,
    ///         and fee plus senior equal the coupon exactly, so the income is charged once and
    ///         nothing is created. A one-wei drift in the fee rounding fails this test.
    function test_fork_mtm_cureByRepayingPrincipal_throughTheRealWaterfall() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        uint256 fundedAt = block.timestamp;
        _mark(tokenId, V_MARGIN_EXACT);
        _pinOneSecondFigures(tokenId);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);

        // ADR-0038: interest accrues to the second and the cash interest leg is bounded by it.
        // Twelve hours inside the one-day mark window earns the coupon the borrower pays below.
        _warp(12 hours);
        uint256 elapsed = block.timestamp - fundedAt;
        assertEq(elapsed, 12 hours + 1, "one mark second plus twelve hours since funding");
        uint256 interest = reserves.accruedDebt(tokenId).interest;
        assertEq(interest, _coupon(P, DA_RATE_BPS, elapsed), "engine coupon is the Actual/360 note on the USDC grid");
        assertEq(interest, 36_111_947e12, "260,000 at 10% for 43,201 s = 36,111,947,016,197,954,552, floored to 1e12");

        uint256 vaultHeldBefore = usdfr.balanceOf(address(vault));
        uint256 feeRecipientBefore = usdfr.balanceOf(ops);
        assertEq(reserves.accrualSnapshot().feeRecipient, ops, "ops is the accrual fee recipient on this deploy");

        // the earned coupon + 60,000 principal
        _repay(tokenId, interest, 60_000e18);

        // principal leg
        assertEq(reserves.deployedTo(tokenId), 200_000e18, "outstanding fell to 200,000");
        assertEq(registry.classExposure(CLASS5), 200_000e18, "class exposure released in step");
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Amortizing),
            "partial principal starts amortization"
        );

        // interest leg under ADR-0038. The receipt reclassifies already-recognized income: no
        // fee is minted inside distribute (that would be the second yield mint the owner
        // direction forbids), the 10% fee is retained as a reserve claim, and its delivery is
        // permissionless. Legs 3 delivers both claims so the vault figure below does not depend
        // on whether the sub-grid rounding path already materialized the senior leg at receipt.
        // The split is exact: the fee is floor(streamed gross / 10) where the streamed gross is
        // the slope times 43,201 s plus the reconciled remainder share floor(9,884,152 * 43,201 /
        // 15,551,999) = 27,456 wei; the senior vault holds the coupon less that fee because the
        // streamed excess over the coupon (16,197,982,008 wei) is burned from the senior.
        assertEq(usdfr.balanceOf(ops) - feeRecipientBefore, 0, "no fee mint inside distribute: not a second yield mint");
        assertEq(
            _streamed(elapsed),
            36_111_947_016_197_982_008,
            "streamed gross at the receipt = 835,905,349,788,152 * 43,201 + 27,456"
        );
        uint256 feeClaim = reserves.accrualSnapshot().feeUnissued;
        assertEq(feeClaim, _streamed(elapsed) / 10, "the 10% protocol fee is retained as a reserve claim");
        vm.prank(carol);
        (, uint256 feeDelivered) = reserves.materializeAccrued(3);
        assertEq(feeDelivered, feeClaim, "delivery converts the whole retained fee claim");
        uint256 feeDelta = usdfr.balanceOf(ops) - feeRecipientBefore;
        uint256 vaultDelta = usdfr.balanceOf(address(vault)) - vaultHeldBefore;
        assertEq(feeDelta, feeDelivered, "the delivered fee lands with the fee recipient");
        assertEq(feeDelta, _streamed(elapsed) / 10, "10% protocol fee on the streamed gross, physically delivered");
        assertEq(vaultDelta, interest - _streamed(elapsed) / 10, "senior receives every unit after the protocol fee");
        assertEq(
            vaultDelta + feeDelta, interest, "fee plus senior equal the coupon exactly: charged once, nothing created"
        );
        assertEq(reserves.accrualSnapshot().feeUnissued, 0, "no fee claim left virtual");
        assertEq(reserves.accrualSnapshot().seniorUnissued, 0, "no senior claim left virtual");

        // the margin arithmetic now clears on the SAME (still fresh) mark
        (uint256 ltv, uint64 asOf) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltv, 5000, "200,000 against a 400,000 mark is 5000 bps");
        assertLe(block.timestamp - asOf, uint256(MARK_AGE), "the mark is still fresh");

        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.MarginCallCleared(tokenId, 5000);
        vm.prank(carol);
        defaultManager.clearMarginCall(tokenId);
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "cured by repayment");

        // and the margin path still functions in the Amortizing state
        _mark(tokenId, 307_692e18); // 200,000 / 307,692 = 6500.06 bps
        (uint256 ltvAmort,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltvAmort, 6500, "breached again while amortizing");
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        assertGt(uint256(defaultManager.cureDeadline(tokenId)), 0, "margin path works in Amortizing");
    }

    /// @notice Every value-changing margin action requires a fresh professional mark.
    ///         A stale low valuation cannot open a margin call or liquidate a borrower, and
    ///         a stale high valuation cannot clear an existing call.
    function test_fork_mtm_staleMarkCannotTriggerOrCureMarginAction() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);
        _mark(tokenId, V_MARGIN_EXACT);
        (, uint64 breachAsOf) = defaultManager.currentLtvBps(tokenId);

        // let the mark go two days stale — twice the class bound
        _warp(2 days);
        assertGt(block.timestamp - breachAsOf, uint256(MARK_AGE), "the mark is stale");

        // A stale observation cannot newly encumber the facility.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ValuationStale.selector, tokenId, breachAsOf, MARK_AGE
            )
        );
        defaultManager.marginCall(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), 0, "no cure window opened from stale evidence");

        // A fresh appraisal of the same breach can open the call.
        _mark(tokenId, V_MARGIN_EXACT);
        uint64 expectedDeadline = uint64(block.timestamp) + Config.DEFAULT_MARGIN_CURE_WINDOW;
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        (, breachAsOf) = defaultManager.currentLtvBps(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), expectedDeadline, "fresh evidence opens the cure window");

        // Make the arithmetic clear, then let the standing mark become stale.
        uint64 paidAt = uint64(block.timestamp);
        _repay(tokenId, 0, 60_000e18);
        _warp(uint256(MARK_AGE) + 1);
        (uint256 ltv, uint64 asOfNow) = defaultManager.currentLtvBps(tokenId);
        assertEq(
            ltv, _paydownFace(fundedAt, paidAt) * Config.BPS / V_MARGIN_EXACT, "debt includes both accrual periods"
        );
        assertLt(ltv, MARGIN_LTV, "the position is healthy including earned interest");
        assertEq(asOfNow, breachAsOf, "but the evidence is now stale");

        // HARMFUL: refused. The staleness check precedes the threshold check, so this is the
        // error we must see — the LTV being fine is exactly what makes the test meaningful.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ValuationStale.selector, tokenId, breachAsOf, MARK_AGE
            )
        );
        defaultManager.clearMarginCall(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), expectedDeadline, "the call still stands");

        // A fresh mark at the same value releases it.
        _mark(tokenId, V_MARGIN_EXACT);
        (uint256 ltvFresh,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltvFresh, _paydownFace(fundedAt, paidAt) * Config.BPS / V_MARGIN_EXACT, "fresh mark uses current debt");
        assertLt(ltvFresh, MARGIN_LTV, "fresh evidence still shows a healthy position");
        vm.prank(carol);
        defaultManager.clearMarginCall(tokenId);
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "cured on fresh evidence only");
    }

    /// @notice Mark freshness binds EXACTLY at `maxMarkAge`: a mark aged to the second is
    ///         still cure-worthy evidence; one second older is not. The check is `>`, not `>=`.
    function test_fork_mtm_markFreshnessBindsExactlyAtMaxMarkAge() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);

        // a healthy mark, aged ONE SECOND past the bound
        _mark(tokenId, V_HEALTHY);
        (, uint64 tooOld) = oracle.latestValuation(tokenId);
        _warp(uint256(MARK_AGE) + 1);
        assertEq(block.timestamp - tooOld, uint256(MARK_AGE) + 1, "one second past the bound");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ValuationStale.selector, tokenId, tooOld, MARK_AGE)
        );
        defaultManager.clearMarginCall(tokenId);

        // a fresh mark aged EXACTLY to the bound still cures
        _mark(tokenId, V_HEALTHY);
        (, uint64 justOld) = oracle.latestValuation(tokenId);
        _warp(uint256(MARK_AGE));
        assertEq(block.timestamp - justOld, uint256(MARK_AGE), "exactly at the bound");
        vm.prank(carol);
        defaultManager.clearMarginCall(tokenId);
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "cured on evidence exactly at the age limit");
    }

    /// @notice The other liquidation outcome: custodied collateral is SOLD and the proceeds
    ///         recover the facility in full. The position closes to Resolved, the ADR-0022
    ///         impairment mark is released, the NFT unfreezes, and no credit loss is realized.
    ///
    ///         Under ADR-0038 (Q1 "Full face", Q2 accrual stops "At default declaration") the
    ///         face at risk is the principal PLUS the one second of interest earned before the
    ///         mark, so "recovered in full" means the custodian returns principal and that
    ///         second (`I1`). Closure aligns the streamed second (`I1_BOOK`) to the contractual
    ///         `I1`: the senior share of the streamed second is materialized to the vault and the
    ///         `I1_ROUND` excess is burned through the cascade (Q3), which with no junior capital
    ///         in this shape reaches the senior. Both are pinned exactly, so the only movement in
    ///         supply and senior NAV is that sub-grid closure figure and nothing else.
    ///
    ///         The FINAL `marginCall` assertion is unchanged and stays red under the C3-RC2 /
    ///         C6 contract finding (a retired facility answers `AccrualBook_UnknownFacility`
    ///         before `DefaultManager_NotDefaultable`); it is not this repair's to resolve.
    function test_fork_mtm_liquidationRecoveredInFullResolvesAndClearsImpairment() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 800_000e18);
        uint256 tokenId = _originateDigital(P, V_ORIG, MAX_LTV);
        _fundDigital(tokenId, P);

        uint256 supplyBefore = usdfr.totalSupply();
        uint256 vaultBefore = vault.totalAssets();

        _mark(tokenId, V_LIQ_EXACT);
        _pinOneSecondFigures(tokenId);
        // closure: the streamed second aligns to the contractual second and the excess is a
        // rounding loss that the cascade allocates to the SENIOR, because no curator first-loss
        // or sGROVE coverage is posted in this shape
        vm.expectEmit(true, false, false, true, address(reserves));
        emit ReserveRoundingLib.AccrualRoundingAllocated(tokenId, 1, I1_ROUND, 0, 0, 0, I1_ROUND, 0, 0);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(tokenId, 1, uint64(block.timestamp), 0, I1_ROUND, true);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);
        assertEq(reserves.deployedTo(tokenId), P + I1, "face = principal + canonical one-second interest");
        assertEq(defaultManager.pendingSeniorImpairment(), P + I1, "the whole outstanding is marked at risk");
        assertLt(vault.redemptionTotalAssets(), vault.totalAssets(), "exit price marked down");
        assertEq(
            vault.totalAssets(), vaultBefore + I1_SENIOR - I1_ROUND, "senior: materialized claim less the rounding loss"
        );

        // the custodian liquidates the collateral and returns the full outstanding: principal
        // and the one second of interest the face carries
        _repay(tokenId, I1, P);

        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Resolved),
            "a fully recovered default closes to Resolved (M-03)"
        );
        assertEq(reserves.deployedTo(tokenId), 0, "nothing outstanding");
        assertEq(registry.classExposure(CLASS5), 0, "class exposure released in full");
        assertEq(defaultManager.declaredDefaultedPrincipal(CLASS5), 0, "impairment pool emptied");
        assertEq(defaultManager.defaultedContribution(tokenId), 0, "this facility contributes nothing");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "the conservative NAV mark is released");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "exit price back to the deposit price");

        // no credit loss was realized: supply and the senior vault moved only by the closure
        // figures pinned above (the materialized senior second less the rounding loss)
        assertEq(usdfr.totalSupply(), supplyBefore + I1_SENIOR - I1_ROUND, "only the closure rounding loss was burned");
        assertEq(vault.totalAssets(), vaultBefore + I1_SENIOR - I1_ROUND, "seniors took no principal loss");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds");

        // the dual-record freeze lifts with the resolution
        vm.prank(ops);
        bridge.transferFrom(ops, alice, tokenId);
        assertEq(bridge.ownerOf(tokenId), alice, "a resolved position can move again");

        // and the margin path is permanently closed for a closed facility
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, tokenId));
        defaultManager.marginCall(tokenId);
    }

    /// @notice The liquidation threshold binds EXACTLY at 8000 bps, needs no prior margin
    ///         call on a hard breach, but refuses a stale mark until a fresh professional
    ///         valuation reconfirms the breach.
    function test_fork_mtm_liquidationThresholdBindsExactlyAt8000_andRequiresAFreshMark() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);

        // one bps short of the hard threshold
        _mark(tokenId, V_LIQ_MISS);
        (uint256 ltvMiss,) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltvMiss, 7999, "325,001 supports an LTV of 7999 bps");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 7999, uint256(LIQ_LTV)
            )
        );
        defaultManager.liquidate(tokenId);
        assertEq(uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Active), "still active at 7999");

        // exactly at it, and stale
        _mark(tokenId, V_LIQ_EXACT);
        (uint256 ltvHit, uint64 asOf) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltvHit, 8000, "325,000 supports an LTV of exactly 8000 bps");
        _warp(2 days);
        assertGt(block.timestamp - asOf, uint256(MARK_AGE), "and the mark is now stale");

        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "no margin call ever opened");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ValuationStale.selector, tokenId, asOf, uint256(MARK_AGE)
            )
        );
        defaultManager.liquidate(tokenId);

        // Rebuild both sides of the boundary from the independently computed accrued face.
        // Updating only the old mark's expected event would stop checking equality at 8000.
        _warp(1);
        assertEq(reserves.accruedDebt(tokenId).interest, _cashFace(fundedAt) - P, "independent earned coupon");
        assertGt(
            _cashFace(fundedAt) * Config.BPS / V_LIQ_EXACT, LIQ_LTV, "old principal-only mark is above the boundary"
        );
        _markNow(tokenId, _cashFace(fundedAt) * Config.BPS / (uint256(LIQ_LTV) - 1));
        (uint256 accruedMiss,) = defaultManager.currentLtvBps(tokenId);
        assertEq(accruedMiss, 7999, "accrued debt one basis point below liquidation");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 7999, uint256(LIQ_LTV)
            )
        );
        defaultManager.liquidate(tokenId);
        assertEq(uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Active));

        _warp(1);
        _markNow(tokenId, _cashFace(fundedAt) * Config.BPS / uint256(LIQ_LTV));
        (uint256 accruedHit,) = defaultManager.currentLtvBps(tokenId);
        assertEq(accruedHit, 8000, "accrued debt exactly at liquidation");
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.LiquidationInitiated(tokenId, 8000);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);

        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "a hard breach skips the margin stage entirely"
        );
    }

    /// @notice The cure window binds to the SECOND: at the deadline liquidation is refused;
    ///         one second later it fires — and it drags the facility into the freeze,
    ///         the curator lock and the ADR-0022 impairment pool.
    function test_fork_mtm_cureWindowExpiry_liquidatesOneSecondPastTheDeadline() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);
        _mintFromUSDC(ops, 200_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), 40_000e18);
        curator.postFirstLoss(CLASS5, 40_000e18);
        vm.stopPrank();

        _mark(tokenId, V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        uint64 deadline = defaultManager.cureDeadline(tokenId);

        // exactly AT the deadline the original mark is still fresh (`age == maxMarkAge`),
        // `block.timestamp > deadline` is false, and accrued LTV remains below 8000, so
        // neither trigger holds. The error names the LIQUIDATION threshold, not the margin one.
        _warp(uint256(Config.DEFAULT_MARGIN_CURE_WINDOW));
        assertEq(uint64(block.timestamp), deadline, "sitting exactly on the deadline");
        assertGe(_cashFace(fundedAt) * Config.BPS / V_MARGIN_EXACT, MARGIN_LTV);
        assertLt(_cashFace(fundedAt) * Config.BPS / V_MARGIN_EXACT, LIQ_LTV);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector,
                tokenId,
                _cashFace(fundedAt) * Config.BPS / V_MARGIN_EXACT,
                uint256(LIQ_LTV)
            )
        );
        defaultManager.liquidate(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), deadline, "the call is untouched by a failed liquidation");

        // one second later the cure has expired and the breach still stands
        _warp(1);
        _mark(tokenId, V_MARGIN_EXACT);
        uint256 impairmentBefore = defaultManager.pendingSeniorImpairment();
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.LiquidationInitiated(tokenId, _cashFace(fundedAt) * Config.BPS / V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);

        assertEq(
            uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Defaulted), "liquidation froze it"
        );
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "the cure window is cleared on liquidation");

        // the freeze is real, on all three records:
        // 1. the NFT cannot move (dual-record freeze)
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_PositionFrozen.selector, tokenId));
        bridge.transferFrom(ops, alice, tokenId);
        // 2. the curator cannot withdraw ahead of the loss (R4-EC2)
        assertEq(curator.unresolvedDefaults(CLASS5), 1, "class 5 curator pool frozen");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, CLASS5));
        curator.withdrawFirstLoss(CLASS5, 1e18);
        // 3. the senior EXIT price marks down immediately, while the deposit price does not
        assertEq(
            defaultManager.declaredDefaultedPrincipal(CLASS5), _cashFace(fundedAt), "full contractual face is at risk"
        );
        assertEq(
            curator.poolBalance(CLASS5),
            40_000e18 - _closureRounding(fundedAt),
            "curator absorbs the rounding correction first"
        );
        assertEq(
            defaultManager.pendingSeniorImpairment() - impairmentBefore,
            _cashFace(fundedAt) - 40_000e18 + _closureRounding(fundedAt),
            "impairment = outstanding less the curator first-loss layer"
        );
        assertLt(vault.redemptionTotalAssets(), vault.totalAssets(), "exit price below deposit price (ADR-0022)");

        // and the margin path is closed for a frozen facility
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, tokenId));
        defaultManager.marginCall(tokenId);
    }

    /// @notice A recovered LTV survives cure expiry: once the collateral is back above the
    ///         margin threshold, an EXPIRED window no longer authorizes liquidation — and the
    ///         call can still be cleared, because clearing is only ever possible when the
    ///         evidence says the position is healthy.
    function test_fork_mtm_recoveredLtvSurvivesCureExpiry() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        uint64 fundedAt = uint64(block.timestamp);
        _mark(tokenId, V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        uint64 deadline = defaultManager.cureDeadline(tokenId);

        _warp(uint256(Config.DEFAULT_MARGIN_CURE_WINDOW) + 1);
        assertGt(block.timestamp, uint256(deadline), "the cure window has expired");

        // collateral recovered before anyone pulled the trigger
        _mark(tokenId, V_HEALTHY);
        assertLt(_cashFace(fundedAt) * Config.BPS / V_HEALTHY, MARGIN_LTV, "recovery includes the elapsed coupon");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector,
                tokenId,
                _cashFace(fundedAt) * Config.BPS / V_HEALTHY,
                uint256(LIQ_LTV)
            )
        );
        defaultManager.liquidate(tokenId);
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Active),
            "an expired window alone does not liquidate a healthy position"
        );

        // clearing after expiry is permitted, and is safe by construction: it requires a fresh
        // mark UNDER the margin threshold, which is exactly the state in which `liquidate`
        // would refuse anyway.
        vm.prank(carol);
        defaultManager.clearMarginCall(tokenId);
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "call cleared after expiry");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. LIQUIDATION INTO THE CASCADE
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A marked-to-market liquidation feeds the SAME three-layer cascade as a
    ///         receivable default, curator first-loss, then sGROVE, then senior principal,
    ///         with every figure pinned exactly, including the PM-R-11 impairment netting.
    ///
    ///         Under ADR-0038 (Q1 "Full face", Q2 accrual stops "At default declaration", Q3
    ///         reversal "Through the three-layer cascade") the face that enters the impairment
    ///         pool is the principal plus the one second of interest earned before the mark
    ///         (`I1`), and the closure's sub-grid rounding loss (`I1_ROUND`, the streamed
    ///         `I1_BOOK` less the contractual `I1`) is itself allocated through the cascade, so
    ///         layer 1 absorbs it FIRST and every later figure carries it. The senior share of
    ///         the streamed second (`I1_SENIOR`) is materialized to the vault at closure.
    function test_fork_mtm_liquidationIntoTheThreeLayerCascade() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 800_000e18);
        uint256 tokenId = _originateDigital(P, V_ORIG, MAX_LTV);
        _fundDigital(tokenId, P);

        // layer 1: 50,000 curator first-loss on class 5. layer 2: the full 100,000
        // shared sGROVE reserve under ADR-0035.
        _mintFromUSDC(ops, 500_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), 50_000e18);
        curator.postFirstLoss(CLASS5, 50_000e18);
        usdfr.approve(address(sGrove), 100_000e18);
        sGrove.fundCoverage(100_000e18);
        vm.stopPrank();
        assertEq(sGrove.coverageCapacity(), 100_000e18, "capacity equals the 100,000 reserve");

        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 supplyBefore = usdfr.totalSupply();

        // hard breach -> permissionless liquidation. One second has accrued since funding (the
        // mark second); ADR-0038 Q1 puts it into the at-risk face, and closure allocates the
        // streamed-versus-contractual excess through the cascade: layer 1 absorbs it FIRST.
        _mark(tokenId, V_LIQ_EXACT);
        _pinOneSecondFigures(tokenId);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit ReserveRoundingLib.AccrualRoundingAllocated(tokenId, 1, I1_ROUND, 0, I1_ROUND, 0, 0, 0, 0);
        vm.expectEmit(true, false, false, true, address(reserves));
        emit ReserveAccrualCreditLib.AccrualLoanAligned(tokenId, 1, uint64(block.timestamp), 0, I1_ROUND, true);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);

        // ADR-0022 conservative NAV BEFORE realization: the face (260,000 + I1) at risk, less
        // the curator capital left after the rounding loss, less the 100,000 shared reserve.
        assertEq(reserves.deployedTo(tokenId), P + I1, "face = principal + canonical one-second interest");
        assertEq(defaultManager.declaredDefaultedPrincipal(CLASS5), P + I1, "the whole outstanding entered the pool");
        assertEq(curator.poolBalance(CLASS5), 50_000e18 - I1_ROUND, "layer 1 absorbed the closure rounding loss");
        assertEq(sGrove.coverageReserve(), 100_000e18, "layer 2 untouched while layer 1 had capital");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            (P + I1) - (50_000e18 - I1_ROUND) - 100_000e18,
            "face - curator - 100k backstop"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), 110_000e18 + I1 + I1_ROUND, "= 110,000 + I1 + I1_ROUND");

        // realize 200,000 of loss: what is left of the 50,000 curator layer + 100,000 backstop
        // + the residual on senior, which is 50,000 plus the rounding loss the curator already
        // absorbed
        bytes32 lossEvidence = _attestLoss(tokenId, 200_000e18, bytes32(0));
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit IDefaultManager.LossRealized(
            tokenId, CLASS5, 200_000e18, 50_000e18 - I1_ROUND, 100_000e18, 50_000e18 + I1_ROUND
        );
        vm.prank(ops);
        defaultManager.realizeLoss(tokenId, 200_000e18, lossEvidence);

        // layer by layer, in order, nothing skipped
        assertEq(curator.poolBalance(CLASS5), 0, "layer 1 drained to zero FIRST");
        assertEq(sGrove.coverageReserve(), 0, "layer 2 exhausted the shared reserve");
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(tokenId);
        assertEq(drawn, 100_000e18, "coverage drawn is recorded per EVENT");
        assertEq(cap, 100_000e18, "event view is cumulative draw plus zero live reserve");
        assertEq(
            vault.totalAssets(),
            vaultAssetsBefore + I1_SENIOR - 50_000e18 - I1_ROUND,
            "layer 3 took only the residual (after receiving the materialized senior second)"
        );

        // supply and backing fell together (ADR-0012): the materialized senior second was
        // minted at closure, then the loss and the rounding excess were burned
        assertEq(supplyBefore + I1_SENIOR - usdfr.totalSupply(), 200_000e18 + I1_ROUND, "the whole loss was burned");
        assertEq(reserves.deployedTo(tokenId), 60_000e18 + I1, "face written down by exactly the loss");
        assertEq(registry.classExposure(CLASS5), 60_000e18 + I1, "and exposure released in the same transaction");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds through the cascade");

        // PM-R-11: the remaining 60,000 + I1 can no longer net any backstop coverage because
        // the physical shared reserve is empty.
        assertEq(defaultManager.defaultedContribution(tokenId), 60_000e18 + I1, "60,000 + I1 still unrealized");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 100_000e18, "and 100,000 of coverage is spent");
        assertEq(sGrove.coverageCapacity(), 0, "no live reserve remains");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            60_000e18 + I1,
            "but this event nets nothing: 60,000 + I1 marked in full (PM-R-11)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. NEGATIVES, GOVERNANCE, GUARDIAN, ORACLE INTERACTION
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Everything about the margin path that must NOT work.
    function test_fork_mtm_negativePaths() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);

        // (a) a RECEIVABLE facility is not reachable from the margin path at all
        uint256 filmId = _originateAndFund(200_000e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, filmId));
        defaultManager.marginCall(filmId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, filmId));
        defaultManager.liquidate(filmId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, filmId));
        defaultManager.clearMarginCall(filmId);

        // (b) an UNFUNDED (Pending) class-5 facility cannot be margin-called: there is no
        //     deployed principal to be over-levered against.
        uint256 pendingId = _originateDigital(P, V_ORIG, MAX_LTV);
        assertEq(reserves.deployedTo(pendingId), 0, "nothing deployed yet");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, pendingId));
        defaultManager.marginCall(pendingId);

        // (c) an unknown facility bubbles the register's own error
        uint256 unknownId = bridge.totalOriginated() + 99;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, unknownId));
        defaultManager.marginCall(unknownId);

        // (d) clearing a call that does not exist
        _fundDigital(pendingId, P);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoMarginCall.selector, pendingId));
        defaultManager.clearMarginCall(pendingId);

        // (e) realizeLoss cannot be used on a live marked-to-market facility, and is
        //     role-gated even for a facility that IS in default
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotInDefault.selector, pendingId));
        defaultManager.realizeLoss(pendingId, 1e18, bytes32(0));
        _mark(pendingId, V_LIQ_EXACT);
        vm.prank(carol);
        defaultManager.liquidate(pendingId);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.realizeLoss(pendingId, 1e18, bytes32(0));
    }

    /// @notice Guardian policy: the PERMISSIONLESS triggers pause, the role-gated remedy
    ///         paths never do, and a declared default supersedes a margin call in flight.
    ///
    ///         Under ADR-0038 (Q1 "Full face", Q2 accrual stops "At default declaration") the
    ///         face the declaration freezes is the principal plus the one second of interest
    ///         earned before the mark (`I1`), so the write-down realized while paused is
    ///         measured against `P + I1`, not `P`.
    function test_fork_mtm_guardianPausesTriggersButNotTheRemedyPath() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
        _pinOneSecondFigures(tokenId);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        uint64 deadline = defaultManager.cureDeadline(tokenId);
        assertGt(uint256(deadline), 0, "a margin call is in flight");

        assertTrue(defaultManager.hasRole(Roles.GUARDIAN_ROLE, ops), "ops is the guardian on this deploy");
        vm.prank(ops);
        defaultManager.pause();

        vm.prank(carol);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.marginCall(tokenId);
        vm.prank(carol);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.clearMarginCall(tokenId);
        vm.prank(carol);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.liquidate(tokenId);

        // Loss recognition is NEVER suppressible: declareDefault works while paused, and it
        // supersedes the margin call rather than leaving a stale cure window behind.
        _declareDefault(tokenId, bytes32(0));
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Defaulted),
            "declared while the triggers were paused"
        );
        assertEq(uint256(defaultManager.cureDeadline(tokenId)), 0, "the in-flight margin call was superseded");

        // realizeLoss is likewise unpausable; the declaration froze the face at P + I1
        assertEq(reserves.deployedTo(tokenId), P + I1, "declared face = principal + canonical one-second interest");
        _realizeLoss(tokenId, 1e18, bytes32(0));
        assertEq(reserves.deployedTo(tokenId), P + I1 - 1e18, "loss realized while paused, against the accrued face");

        // a non-guardian cannot unpause
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        defaultManager.unpause();
        vm.prank(ops);
        defaultManager.unpause();
        assertFalse(defaultManager.paused(), "unpaused");
    }

    /// @notice Governance of the cure window: gated, validated, and effective on the next call.
    function test_fork_mtm_cureWindowGovernance() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        defaultManager.setCureWindow(CLASS5, 6 hours);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_UnknownClass.selector, uint256(6)));
        defaultManager.setCureWindow(6, 6 hours);

        vm.prank(ops);
        vm.expectRevert(IDefaultManager.DefaultManager_ZeroAmount.selector);
        defaultManager.setCureWindow(CLASS5, 0);

        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.CureWindowSet(CLASS5, 6 hours);
        vm.prank(ops);
        defaultManager.setCureWindow(CLASS5, 6 hours);
        assertEq(uint256(defaultManager.cureWindow(CLASS5)), 6 hours, "window shortened");

        // and it governs the NEXT call's deadline
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
        uint64 expected = uint64(block.timestamp) + 6 hours;
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), expected, "the new window is in force");

        // the shorter window really does expire sooner
        _warp(6 hours + 1);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);
        assertEq(uint256(bridge.facility(tokenId).state), uint256(ClaimBridge.LoanState.Defaulted), "liquidated");
    }

    /// @notice The oracle side of the margin path: a REVOKED mark blocks every margin action
    ///         (fail-closed), the H-02 watermark SURVIVES the revocation so a pre-signed OLDER
    ///         appraisal can never be replayed, and the facility recovers ONLY via a genuinely
    ///         NEWER mark. The `resetValuationWatermark` lever was removed (owner decision
    ///         2026-07-22): recovery is a fresh appraisal, never a lowered floor, and the
    ///         anti-rollback protection is intact without it.
    function test_fork_mtm_revokedMarkBlocksTheMarginPathAndTheH02WatermarkHolds() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
        (, uint64 markAsOf) = oracle.latestValuation(tokenId);
        assertEq(oracle.valuationWatermark(tokenId), markAsOf, "watermark tracks the accepted mark");

        // governance revokes the (suspect) mark
        vm.prank(ops);
        oracle.revoke(tokenId, IAttestationOracle.AttestationKind.Valuation);
        (uint256 valueAfter, uint64 asOfAfter) = oracle.latestValuation(tokenId);
        assertEq(valueAfter, 0, "a revoked mark stops steering anything");
        assertEq(uint256(asOfAfter), 0, "and its timestamp is wiped");
        assertEq(oracle.valuationWatermark(tokenId), markAsOf, "but the H-02 watermark SURVIVES the revocation");

        // with no mark, every margin action fails closed
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, tokenId));
        defaultManager.currentLtvBps(tokenId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, tokenId));
        defaultManager.marginCall(tokenId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NoValuation.selector, tokenId));
        defaultManager.liquidate(tokenId);

        // a genuine appraisal OBSERVED BEFORE the surviving watermark cannot be replayed — this
        // is the H-02 anti-rollback lock, intact WITHOUT any recovery lever.
        uint64 genuineAsOf = markAsOf - 1 hours;
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signedValuation(tokenId, V_HEALTHY, genuineAsOf);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, genuineAsOf, markAsOf)
        );
        oracle.attest(a, sigs);

        // RECOVERY WITHOUT A LEVER: the supported path is a genuinely NEWER appraisal, which
        // clears the surviving watermark on its own and re-arms the facility on the margin path.
        _mark(tokenId, V_HEALTHY);
        (, uint64 freshAsOf) = oracle.latestValuation(tokenId);
        assertGt(freshAsOf, markAsOf, "the recovery mark is strictly newer than the surviving watermark");
        (uint256 ltv, uint64 asOfNow) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltv, 5200, "the recovered mark drives the LTV again");
        assertEq(asOfNow, freshAsOf, "at its genuinely-observed time");
        assertEq(oracle.valuationWatermark(tokenId), freshAsOf, "and the watermark re-ratchets to the fresh mark");
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (local to this suite; the shared fixture is not modified)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Post a fresh 2-of-n mark. Advances one second first: the H-02 anti-rollback
    ///      watermark requires a STRICTLY increasing `asOf`, so two marks cannot share a block.
    function _mark(uint256 facilityId, uint256 value) private {
        _warp(1);
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signedValuation(facilityId, value, uint64(block.timestamp));
        oracle.attest(a, sigs);
    }

    /// @dev Build and sign a Valuation bundle WITHOUT submitting it. The fixture's `_attestAt`
    ///      cannot be used where a revert is expected, because it calls `oracle.attestationDigest`
    ///      internally and that external call would consume the pending `vm.expectRevert`.
    function _signedValuation(uint256 facilityId, uint256 value, uint64 asOf)
        private
        view
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(value),
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: uint256(keccak256(abi.encode("mtm-fork", facilityId, value, asOf, block.timestamp)))
        });
        bytes32 digest = oracle.attestationDigest(a);
        // signatures must be sorted ascending by signer address; the oracle enforces it
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(lo, digest);
        sigs[0] = abi.encodePacked(r0, s0, v0);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(hi, digest);
        sigs[1] = abi.encodePacked(r1, s1, v1);
    }

    /// @dev Originate a class-5 facility through its own mint gate (Assignment + Valuation).
    function _originateDigital(uint256 principal, uint256 markValue, uint16 ltvBps) private returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, keccak256("da-custody"));
        _mark(tokenId, markValue);
        uint64 maturity = uint64(block.timestamp + 180 days);
        _attestDaTerms(tokenId, principal, ltvBps, 1000, maturity);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, _daTerms(principal, ltvBps, 1000, maturity));
        require(id == tokenId, "mtm fork: tokenId drift");
    }

    /// @dev AUDIT FIX (H-4): the CreditIssued quorum committing to a class-5 facility's exact
    ///      terms. Class 5 now carries the same terms attestation as every other class — its
    ///      gate asymmetry is about UCCFiled, not about whether an amount was ever authorized.
    function _attestDaTerms(uint256 tokenId, uint256 principal, uint16 ltvBps, uint16 interestRateBps, uint64 maturity)
        private
    {
        bytes32 want = bridge.creditTermsHash(_daTerms(principal, ltvBps, interestRateBps, maturity));
        // P-32: AssignmentExecuted is a deal-identity fact on class 5 as well. If a
        // preceding negative leg left an arbitrary assignment payload standing, replace
        // it with the exact terms commitment before exercising the credit/mark branch.
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

    /// @dev The standard subject: 260,000 of principal, funded, marked at 1,000,000 (LTV 2600).
    function _liveDigitalFacility() private returns (uint256 tokenId) {
        _mintFromUSDC(alice, 2_000_000e6);
        tokenId = _originateDigital(P, V_ORIG, MAX_LTV);
        _fundDigital(tokenId, P);
    }

    /// @dev Reference debt comes only from signed principal, rate and elapsed time.
    function _cashFace(uint64 fundedAt) private view returns (uint256) {
        return P + _coupon(P, DA_RATE_BPS, block.timestamp - fundedAt);
    }

    function _paydownFace(uint64 fundedAt, uint64 paidAt) private view returns (uint256) {
        return P - 60_000e18 + _coupon(P, DA_RATE_BPS, paidAt - fundedAt)
            + _coupon(P - 60_000e18, DA_RATE_BPS, block.timestamp - paidAt);
    }

    function _closureRounding(uint64 fundedAt) private view returns (uint256) {
        uint256 elapsed = block.timestamp - fundedAt;
        uint256 canonical = _coupon(P, DA_RATE_BPS, elapsed);
        uint256 recognized = _streamed(elapsed);
        assertGe(recognized, canonical, "fixture must have a downward rounding correction");
        return recognized - canonical;
    }

    /// @dev Caller advances time before deriving the current-time mark, preserving the oracle watermark.
    function _markNow(uint256 tokenId, uint256 value) private {
        (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) =
            _signedValuation(tokenId, value, uint64(block.timestamp));
        oracle.attest(a, sigs);
    }

    /// @dev Actual/360 simple interest on the signed note, floored to the 1e12 USDC grid: the
    ///      contractual figure the engine's `accruedDebt(id).interest` must equal
    ///      (AccrualSegments.cumulative), as `FullLifecycleFork` pins it.
    function _coupon(uint256 principal, uint256 rateBps, uint256 secs) private pure returns (uint256) {
        return (principal * rateBps * secs / (10_000 * 360 days)) / 1e12 * 1e12;
    }

    /// @dev Exactly one second after funding (the `_mark` second, before any lifecycle action):
    ///      proves the `I1*` literals against their closed forms AND against the live engine, so
    ///      no figure used in the ADR-0038 assertions is a magic number. The facility is the only
    ///      one in the book, so the portfolio gross is its streamed slope.
    function _pinOneSecondFigures(uint256 tokenId) private view {
        assertEq(I1, _coupon(P, DA_RATE_BPS, 1), "I1 = floor(P * 10% * 1 s / 360 d) on the 1e12 grid");
        assertEq(
            I1_BOOK,
            _coupon(P, DA_RATE_BPS, DA_TENOR - 1) / (DA_TENOR - 1),
            "I1_BOOK = the segment endpoint amount / its 15,551,999 s duration"
        );
        assertEq(I1_ROUND, 905_349_788_152, "I1_ROUND = I1_BOOK - I1");
        assertEq(I1_SENIOR, 752_314_814_809_337, "I1_SENIOR = I1_BOOK less the floored 10% fee");
        assertEq(
            I1_REM,
            _coupon(P, DA_RATE_BPS, DA_TENOR - 1) - I1_BOOK * (DA_TENOR - 1),
            "I1_REM = the segment endpoint less slope * duration (AccrualBook.open: segmentAmount % duration)"
        );
        assertEq(reserves.accruedDebt(tokenId).interest, I1, "engine: canonical one-second interest");
        IContinuousAccrual.Snapshot memory s = reserves.accrualSnapshot();
        assertEq(s.gross, I1_BOOK, "engine: one second of the book slope");
        assertEq(s.feeUnissued, I1_BOOK / 10, "engine: 10% fee claim on the streamed second");
        assertEq(s.seniorUnissued, I1_SENIOR, "engine: the senior share of the streamed second");
    }

    /// @dev The gross the book has recognized for the working facility `secs` after funding, at
    ///      an authenticated lifecycle action: the integer slope times elapsed (AccrualBook.open)
    ///      plus the reconciled share of the segment remainder (AccrualBook.reconcile:
    ///      floor(remainder * elapsed / duration), credited by `stop` inside AccrualLoans._close).
    ///      Posting (a margin call's `takePosting`) settles the slope only and does not move the
    ///      segment start, so `secs` is measured from funding. A pure helper rather than a local:
    ///      one more local in the cure test is stack-too-deep.
    function _streamed(uint256 secs) private pure returns (uint256) {
        return I1_BOOK * secs + (I1_REM * secs) / (DA_TENOR - 1);
    }

    function _usdc(address who) private view returns (uint256) {
        return IERC20Minimal(USDC).balanceOf(who);
    }
}

/// @dev Minimal ERC-20 view surface, so the suite does not drag a full token import in for one
///      balance read.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}
