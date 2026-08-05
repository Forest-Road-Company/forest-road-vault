// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
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
///           - the FRESHNESS ASYMMETRY, which is the load-bearing safety property of the
///             class: a STALE mark still authorizes the protocol-PROTECTIVE actions
///             (`marginCall`, `liquidate`) but can never authorize the protocol-HARMFUL one
///             (`clearMarginCall`);
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

    /// @notice CURE ROUTE 2 — repay principal. The LTV numerator falls through the real
    ///         waterfall (attested PaymentReceived, exposure released, interest routed senior), and
    ///         the margin path keeps working while the facility is Amortizing.
    function test_fork_mtm_cureByRepayingPrincipal_throughTheRealWaterfall() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);

        uint256 vaultHeldBefore = usdfr.balanceOf(address(vault));
        uint256 feeRecipientBefore = usdfr.balanceOf(ops);

        // 5,000 interest + 60,000 principal
        _repay(tokenId, 5_000e18, 60_000e18);

        // principal leg
        assertEq(reserves.deployedTo(tokenId), 200_000e18, "outstanding fell to 200,000");
        assertEq(registry.classExposure(CLASS5), 200_000e18, "class exposure released in step");
        assertEq(
            uint256(bridge.facility(tokenId).state),
            uint256(ClaimBridge.LoanState.Amortizing),
            "partial principal starts amortization"
        );

        // interest leg, exactly: fee 10% of 5,000 = 500; all 4,500 remaining goes senior.
        assertEq(usdfr.balanceOf(ops) - feeRecipientBefore, 500e18, "10% protocol fee on gross interest");
        assertEq(
            usdfr.balanceOf(address(vault)) - vaultHeldBefore,
            4_500e18,
            "senior receives every unit after the protocol fee"
        );

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
        _repay(tokenId, 0, 60_000e18);
        _warp(uint256(MARK_AGE) + 1);
        (uint256 ltv, uint64 asOfNow) = defaultManager.currentLtvBps(tokenId);
        assertEq(ltv, 5000, "the numbers say cured");
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
        assertEq(ltvFresh, 5000, "identical LTV to the refused attempt");
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
    ///         impairment mark is released, the NFT unfreezes, and no loss is ever realized.
    function test_fork_mtm_liquidationRecoveredInFullResolvesAndClearsImpairment() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 800_000e18);
        uint256 tokenId = _originateDigital(P, V_ORIG, MAX_LTV);
        _fundDigital(tokenId, P);

        uint256 supplyBefore = usdfr.totalSupply();
        uint256 vaultBefore = vault.totalAssets();

        _mark(tokenId, V_LIQ_EXACT);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);
        assertEq(defaultManager.pendingSeniorImpairment(), P, "the whole outstanding is marked at risk");
        assertLt(vault.redemptionTotalAssets(), vault.totalAssets(), "exit price marked down");

        // the custodian liquidates the collateral and returns the full outstanding
        _repay(tokenId, 0, P);

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

        // no loss was ever realized: supply and the senior vault are untouched
        assertEq(usdfr.totalSupply(), supplyBefore, "nothing burned");
        assertEq(vault.totalAssets(), vaultBefore, "seniors took no principal loss");
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

        // A new valuation, observed now, reconfirms the same hard breach.
        _mark(tokenId, V_LIQ_EXACT);
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
        // `block.timestamp > deadline` is false, and 6500 < 8000, so
        // neither trigger holds. The error names the LIQUIDATION threshold, not the margin one.
        _warp(uint256(Config.DEFAULT_MARGIN_CURE_WINDOW));
        assertEq(uint64(block.timestamp), deadline, "sitting exactly on the deadline");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 6500, uint256(LIQ_LTV)
            )
        );
        defaultManager.liquidate(tokenId);
        assertEq(defaultManager.cureDeadline(tokenId), deadline, "the call is untouched by a failed liquidation");

        // one second later the cure has expired and the breach still stands
        _warp(1);
        _mark(tokenId, V_MARGIN_EXACT);
        uint256 impairmentBefore = defaultManager.pendingSeniorImpairment();
        vm.expectEmit(true, false, false, true, address(defaultManager));
        emit IDefaultManager.LiquidationInitiated(tokenId, 6500);
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
        assertEq(defaultManager.declaredDefaultedPrincipal(CLASS5), P, "the whole outstanding is at risk");
        assertEq(
            defaultManager.pendingSeniorImpairment() - impairmentBefore,
            P - 40_000e18,
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
        _mark(tokenId, V_MARGIN_EXACT);
        vm.prank(carol);
        defaultManager.marginCall(tokenId);
        uint64 deadline = defaultManager.cureDeadline(tokenId);

        _warp(uint256(Config.DEFAULT_MARGIN_CURE_WINDOW) + 1);
        assertGt(block.timestamp, uint256(deadline), "the cure window has expired");

        // collateral recovered before anyone pulled the trigger
        _mark(tokenId, V_HEALTHY);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, tokenId, 5200, uint256(LIQ_LTV)
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
    ///         receivable default — curator first-loss, then sGROVE, then senior principal —
    ///         with every figure pinned exactly, including the PM-R-11 impairment netting.
    function test_fork_mtm_liquidationIntoTheThreeLayerCascade() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 800_000e18);
        uint256 tokenId = _originateDigital(P, V_ORIG, MAX_LTV);
        _fundDigital(tokenId, P);

        // layer 1: 50,000 curator first-loss on class 5. layer 2: a 100,000 sGROVE reserve,
        // of which the per-EVENT cap (5000 bps, PM-R-07) makes 50,000 reachable.
        _mintFromUSDC(ops, 500_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), 50_000e18);
        curator.postFirstLoss(CLASS5, 50_000e18);
        usdfr.approve(address(sGrove), 100_000e18);
        sGrove.fundCoverage(100_000e18);
        vm.stopPrank();
        assertEq(sGrove.coverageCapacity(), 50_000e18, "50% per-event cap on a 100,000 reserve");

        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 supplyBefore = usdfr.totalSupply();

        // hard breach -> permissionless liquidation
        _mark(tokenId, V_LIQ_EXACT);
        vm.prank(carol);
        defaultManager.liquidate(tokenId);

        // ADR-0022 conservative NAV BEFORE realization: 260,000 at risk, less 50,000 of
        // curator capital, less the 50,000 the backstop could still cover = 160,000.
        assertEq(defaultManager.declaredDefaultedPrincipal(CLASS5), P, "the whole outstanding entered the pool");
        assertEq(defaultManager.pendingSeniorImpairment(), 160_000e18, "260k - 50k curator - 50k backstop");

        // realize 200,000 of loss: 50,000 curator + 50,000 backstop + 100,000 senior
        _attestLoss(tokenId, 200_000e18, bytes32(0));
        vm.expectEmit(true, true, false, true, address(defaultManager));
        emit IDefaultManager.LossRealized(tokenId, CLASS5, 200_000e18, 50_000e18, 50_000e18, 100_000e18);
        vm.prank(ops);
        defaultManager.realizeLoss(tokenId, 200_000e18, bytes32(0));

        // layer by layer, in order, nothing skipped
        assertEq(curator.poolBalance(CLASS5), 0, "layer 1 drained to zero FIRST");
        assertEq(sGrove.coverageReserve(), 50_000e18, "layer 2 drew exactly its per-event cap");
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(tokenId);
        assertEq(drawn, 50_000e18, "coverage drawn is recorded per EVENT");
        assertEq(cap, 50_000e18, "and the cap was snapshotted at the first draw (PM-R-07)");
        assertEq(vault.totalAssets(), vaultAssetsBefore - 100_000e18, "layer 3 took only the residual");

        // supply and backing fell together (ADR-0012)
        assertEq(supplyBefore - usdfr.totalSupply(), 200_000e18, "the whole loss was burned");
        assertEq(reserves.deployedTo(tokenId), 60_000e18, "principal written down by exactly the loss");
        assertEq(registry.classExposure(CLASS5), 60_000e18, "and exposure released in the same transaction");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "BACKING INVARIANT holds through the cascade");

        // PM-R-11: the remaining 60,000 can no longer net ANY backstop coverage — this event
        // already consumed its snapshotted cap, so the conservative NAV must stop crediting it.
        assertEq(defaultManager.defaultedContribution(tokenId), 60_000e18, "60,000 still unrealized");
        assertEq(defaultManager.liveDefaultCoverageConsumed(), 50_000e18, "and 50,000 of coverage is spent");
        assertEq(sGrove.coverageCapacity(), 25_000e18, "the raw capacity a FRESH event would see");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            60_000e18,
            "but this event nets nothing: 60,000 marked in full (PM-R-11)"
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
    ///         paths never do — and a declared default supersedes a margin call in flight.
    function test_fork_mtm_guardianPausesTriggersButNotTheRemedyPath() public onFork {
        uint256 tokenId = _liveDigitalFacility();
        _mark(tokenId, V_MARGIN_EXACT);
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

        // realizeLoss is likewise unpausable
        _realizeLoss(tokenId, 1e18, bytes32(0));
        assertEq(reserves.deployedTo(tokenId), P - 1e18, "loss realized while paused");

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
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.CreditIssued,
            bridge.creditTermsHash(_daTerms(principal, ltvBps, interestRateBps, maturity))
        );
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

    function _usdc(address who) private view returns (uint256) {
        return IERC20Minimal(USDC).balanceOf(who);
    }
}

/// @dev Minimal ERC-20 view surface, so the suite does not drag a full token import in for one
///      balance read.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}
