// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {AccrualLoans} from "../../src/libraries/AccrualLoans.sol";
import {ReserveCreditLib} from "../../src/libraries/ReserveCreditLib.sol";

/// @title EXP4_WaterfallForkTest — adversarial attack on WATERFALL VALUE CONSERVATION
/// @notice AUTHORISED pre-audit red-team on a pinned mainnet fork (no broadcast, no mainnet, no
///         real value). GOAL: make a repayment distribution CREATE or DESTROY value, or
///         SUBORDINATE senior (`sUSDfr`) to junior (curator). Three families of route are tried,
///         each composing legitimate operations in an illegitimate order/amount:
///
///           (A) a DISTRIBUTION WITH A MISMATCHED PRINCIPAL: attest one interest/principal split
///               and distribute a different one; and declare a principal larger than the facility's
///               contractual principal (under ADR-0038 continuous accrual the engine bound, which is
///               tighter than the legacy `deployedTo` bound once interest has streamed).
///           (B) REPAYING TWICE — replay a single real-world payment event, both by re-distributing
///               against a closed facility and by re-attesting the already-spent economic fact.
///           (C) A FACILITY FUNDED AT AN AMOUNT OTHER THAN ITS PRINCIPAL — under-fund and over-fund
///               relative to the originated (attested) principal.
///
///         For each route the test asserts the exact custom error the protocol reverts with, so a
///         PASS is provable evidence the route is closed. The first test is a positive-control that
///         proves the LEGITIMATE repayment path conserves value exactly (supply and backing move in
///         lockstep, senior receives the yield) — so a regression that started creating value would
///         turn that green assertion red rather than passing silently.
contract EXP4_WaterfallForkTest is ForkLifecycleFixture {
    // 1 whole USDC expressed in 18-decimal USD value (normalize scale is 1e12).
    uint256 internal constant ONE_USDC_VALUE = 1e18;
    // 1 USDC base unit (1e-6 USDC) in 18-decimal value: the reserve grid every engine figure sits on.
    uint256 internal constant USDC_GRID = 1e12;
    // The fixture note (ForkLifecycleFixture._forkTermsFor): fixed 1400 bps, Actual/360, 30-day interval.
    uint256 internal constant NOTE_RATE_BPS = 1400;

    // ────────────────────────────────────────────────────────────────────────
    // Positive control: the honest repayment path conserves value exactly.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice A full, healthy repayment after one earned month conserves value EXACTLY. Under
    ///         continuous accrual the engine has already recognised the coupon as it streamed, and
    ///         the cash interest leg DISCHARGES that contractual claim rather than minting a second
    ///         one (ADR/0038, "Decision" item 4: "Recognition must not double-count"; "Loss-bearing
    ///         cash and PIK without changing the contractual basis": "Payment reduces the correct
    ///         principal and interest components while moving measured USDC into custody"). So,
    ///         measured from the PRE-ACCRUAL baseline, economic supply and backing each rise by
    ///         exactly one coupon: nothing created, nothing destroyed. The receipt's own accounting
    ///         event pins the discharge split, and `Distributed` pins that the legacy interest route
    ///         (fee, toVault) minted nothing on top. The senior vault holds the yield; junior
    ///         curator capital is never paid out of a repayment.
    function test_valueConservation_healthyRepayConservesValueAndPaysSenior() public onFork {
        _mintFromUSDC(alice, 1_000_000e6); // seed idle liquidity for funding

        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);
        uint256 outstanding = reserves.deployedTo(tokenId);
        assertEq(outstanding, principal, "funded amount must equal principal");

        // Baselines are captured BEFORE the month elapses. The conservation statement ADR-0038
        // makes is that accrual and receipt together add exactly one coupon on both sides of the
        // balance sheet; capturing after the warp would only measure the sub-grid rounding the
        // receipt absorbs, which is not the property this control exists to pin.
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 backingBefore = controller.backingValue();
        uint256 vaultBefore = usdfr.balanceOf(address(vault));

        _warp(30 days);
        // One earned monthly coupon on the signed note, floored to USDC's grid (the engine's
        // `AccrualMath.periodAmount` floor; accrual-panel MATH_VALIDATION.md, "Intentional
        // reserve-grid floor"). 500,000e18 x 1400 x 2,592,000 / (10,000 x 31,104,000) =
        // 5,833,333,333,333,333,333,333 -> 5,833,333,333,000,000,000,000 on the grid.
        uint256 interest = _coupon(principal, 30 days);
        assertEq(interest, 5_833_333_333_000_000_000_000, "closed-form Actual/360 coupon on the USDC grid");
        assertEq(reserves.accruedDebt(tokenId).interest, interest, "engine coupon matches the signed note");
        assertEq(reserves.accruedDebt(tokenId).principal, principal, "contractual principal untouched by accrual");

        // Exact coupon + contractual principal: the receipt that closes the facility.
        uint256 stableAmount = (interest + principal) / USDC_GRID;
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        IWaterfallEngine.Payment memory p =
            _prepAttestedReceipt(tokenId, interest, principal, f.nextPaymentDue + f.paymentInterval, "EXP4-payoff");

        // ORDERING PINS. (1) the reserve records the receipt as a discharge of exactly `principal`
        // and exactly the accrued coupon (ADR-0038 Decision 4); (2) the facility closes Repaid;
        // (3) the waterfall settles the accrued receipt with nothing outstanding; (4) `Distributed`
        // carries fee = 0 and toVault = 0 (net minted amounts): no legacy-route yield was minted on
        // top of the accrued recognition.
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveCreditLib.AccruedPaymentReceived(tokenId, USDC, borrower, stableAmount, principal, interest);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit ClaimBridge.StateChanged(tokenId, ClaimBridge.LoanState.Active, ClaimBridge.LoanState.Repaid);
        vm.expectEmit(true, true, false, true, address(waterfall));
        emit WaterfallEngine.AccruedReceiptSettled(tokenId, p.paymentId, 0);
        vm.expectEmit(true, true, true, true, address(waterfall));
        emit IWaterfallEngine.Distributed(tokenId, p.paymentId, borrower, interest, principal, 0, 0);
        vm.prank(ops);
        waterfall.distribute(p); // full repayment -> facility closes to Repaid

        uint256 supplyAfter = controller.totalUSDfr();
        uint256 backingAfter = controller.backingValue();

        // VALUE CONSERVATION: the only new economic supply is the coupon, and backing rose by the
        // identical amount of real cash that arrived. Over-issuance (value creation, e.g. the
        // coupon recognised at accrual AND minted again at receipt) would make the supply delta
        // exceed the coupon; a leak would make backing rise by less than it received.
        assertEq(backingAfter - backingBefore, interest, "backing must rise by exactly the cash received");
        assertEq(supplyAfter - supplyBefore, interest, "supply must rise by exactly the interest minted");

        // SENIORITY: the senior vault received the yield. Curator (junior) capital is never paid out
        // of a repayment, so the senior is not subordinated to the junior on the yield path.
        assertGt(usdfr.balanceOf(address(vault)), vaultBefore, "senior vault must receive the yield");

        // CLOSURE: the contractual claim is fully discharged and nothing remains deployed.
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Repaid), "facility closed");
        assertEq(reserves.deployedTo(tokenId), 0, "nothing outstanding after the payoff");
        assertEq(reserves.accruedDebt(tokenId).principal, 0, "engine principal discharged");
        assertEq(reserves.accruedDebt(tokenId).interest, 0, "engine interest discharged");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Route A: a distribution with a MISMATCHED PRINCIPAL.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Attest a payment committing to one (interest, principal) split, then try to
    ///         distribute a DIFFERENT principal against it. The waterfall recomputes the expected
    ///         receipt hash from the submitted struct and refuses: one attested receipt authorizes
    ///         exactly one distribution, so a servicer cannot release more exposure (destroy the
    ///         borrower's obligation) than the attesters signed for.
    function test_attack_mismatchedPrincipal_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);

        uint256 interest = 1_000e18;
        uint256 principalHonest = 100_000e18; // what the attesters actually sign
        uint256 principalFake = 200_000e18; // what the servicer tries to push through

        // Attest the HONEST receipt (any payload is accepted by the oracle; economic meaning is
        // enforced downstream by the waterfall's exact-hash check).
        uint256 stableHonest = (interest + principalHonest) / 1e12;
        bytes32 paymentId = keccak256(abi.encode("EXP4-mismatch", tokenId));
        uint64 nextDue = 0;
        bytes32 honestPayload =
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableHonest, interest, principalHonest, nextDue));
        _attest(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, honestPayload);

        // Distribute a struct whose principal DIVERGES from the attested one.
        IWaterfallEngine.Payment memory forged = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principalFake,
            nextPaymentDue: nextDue
        });

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId));
        waterfall.distribute(forged);
    }

    /// @notice A distribution declaring MORE principal than the facility's CONTRACTUAL principal is
    ///         refused even with a perfectly matching attestation, and the refusal moves nothing.
    ///         Under continuous accrual (ADR-0038) `_settleReceipt` returns through
    ///         `repayAccruingLoan`, so the gate is the engine's `principalLeg > loan.principal`
    ///         check (`AccrualLoans_PaymentAboveDebt`), not the legacy `deployedTo` comparison
    ///         (`Waterfall_PrincipalExceedsOutstanding`), which is unreachable on this path.
    ///         Specified by docs/remediation/accrual-panel/LIFECYCLE_ACCOUNTING_2026-09-11.md,
    ///         "Repayment, amendments and cap replenishment", row "Cash principal receipt": "Bound
    ///         principal by P"; and docs/remediation/ACCRUAL_BUILD_LOG_2026-09-12.md, "2026-09-12,
    ///         WP3f and WP4, native lifecycle regression foundation": "refusal of a signed
    ///         overpayment with unchanged accounting and an unconsumed attestation".
    ///
    ///         Three receipts, each with a ZERO interest leg so the principal leg is the only defect:
    ///           1. at t0, one whole USDC above the claim (the original attack; at t0 contractual
    ///              principal and `deployedTo` coincide);
    ///           2. after 30 days, a principal leg EQUAL to the grid-aligned `deployedTo`, which now
    ///              carries the streamed coupon: WITHIN the legacy bound, ABOVE contractual
    ///              principal. The legacy check would have admitted this receipt and released a
    ///              month of interest exposure recorded as principal; the engine refuses it. This
    ///              case is what distinguishes the two bounds (a `deployedTo`-shaped bound passes
    ///              case 1);
    ///           3. after 30 days, one USDC base unit (the grid) above contractual principal: the
    ///              bound is exact, with no tolerance.
    ///         Without the bound a servicer could drive the loan's principal negative (a
    ///         value-destroying underflow) or release exposure the borrower never repaid.
    function test_attack_principalExceedsOutstanding_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);

        uint256 outstanding = reserves.deployedTo(tokenId);
        assertEq(outstanding, principal, "t0: deployedTo equals contractual principal");
        assertEq(reserves.accruedDebt(tokenId).principal, principal, "t0: engine principal");

        // Case 1: t0, one whole USDC beyond the claim. A refused receipt leaves its attestation
        // standing, which blocks any later PaymentReceived with `Oracle_UnconsumedFact`, so each
        // case runs from a snapshot of the funded state.
        uint256 funded = vm.snapshotState();
        _expectPrincipalRefused(tokenId, outstanding + ONE_USDC_VALUE, "EXP4-exceeds-t0");
        // Equal-strength evidence: nothing consumed, nothing moved, state unchanged.
        (,, bool stillOk) = oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
        assertTrue(stillOk, "refused receipt must not consume its attestation");
        assertEq(reserves.deployedTo(tokenId), outstanding, "deployedTo unchanged by the refusal");
        assertEq(reserves.accruedDebt(tokenId).principal, principal, "contractual principal unchanged");
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Active), "still Active");
        vm.revertToState(funded);

        // Case 2: after a month `deployedTo` = principal + streamed coupon. Its grid-aligned value is
        // exactly principal + the canonical coupon (principal is on-grid; the streamed carrier sits
        // between the floored coupon and the next grid unit).
        _warp(30 days);
        uint256 coupon = _coupon(principal, 30 days);
        assertEq(coupon, 5_833_333_333_000_000_000_000, "closed-form Actual/360 coupon on the USDC grid");
        uint256 deployedNow = reserves.deployedTo(tokenId);
        uint256 principalWithinDeployed = deployedNow / USDC_GRID * USDC_GRID;
        assertEq(principalWithinDeployed, principal + coupon, "grid-aligned deployedTo is principal plus the coupon");
        assertGt(principalWithinDeployed, principal, "premise: strictly between P and deployedTo");
        assertLe(principalWithinDeployed, deployedNow, "premise: within the legacy bound");
        uint256 accrued = vm.snapshotState();
        _expectPrincipalRefused(tokenId, principalWithinDeployed, "EXP4-exceeds-30d-deployedTo");
        assertEq(reserves.accruedDebt(tokenId).principal, principal, "contractual principal unchanged (30d)");
        assertEq(reserves.accruedDebt(tokenId).interest, coupon, "accrued interest unchanged (30d)");
        vm.revertToState(accrued);

        // Case 3: the smallest representable excess. The bound is `principalLeg > loan.principal`,
        // exact to the grid.
        _expectPrincipalRefused(tokenId, principal + USDC_GRID, "EXP4-exceeds-30d-grid");
        assertEq(reserves.accruedDebt(tokenId).principal, principal, "contractual principal unchanged (grid)");
        (,, bool stillOkLate) = oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
        assertTrue(stillOkLate, "refused receipt must not consume its attestation (30d)");
    }

    // ────────────────────────────────────────────────────────────────────────
    // Route B: REPAYING TWICE.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice After a facility is fully repaid (state Repaid) any further distribution is refused
    ///         at the lifecycle gate, so recovery cash cannot be routed a second time against a
    ///         closed position. Under continuous accrual the payoff is the earned coupon plus the
    ///         contractual principal (docs/remediation/accrual-panel/LIFECYCLE_ACCOUNTING_2026-09-11.md,
    ///         "Repayment, amendments and cap replenishment", row "Full cash payoff": "require the
    ///         attested principal and interest legs to discharge P and U"); an arbitrary interest
    ///         leg at origination is refused by the engine, so the month must first elapse.
    function test_attack_repayTwice_onClosedFacility_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);

        _warp(30 days);
        uint256 coupon = _coupon(principal, 30 days);
        assertEq(coupon, 5_833_333_333_000_000_000_000, "closed-form Actual/360 coupon on the USDC grid");
        assertEq(reserves.accruedDebt(tokenId).interest, coupon, "engine coupon matches the signed note");
        assertEq(reserves.accruedDebt(tokenId).principal, principal, "contractual principal");

        _repay(tokenId, coupon, principal); // full payoff: coupon + contractual principal -> Repaid
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Repaid), "facility closed");
        assertEq(reserves.deployedTo(tokenId), 0, "nothing outstanding");

        // A second distribution (state-gate fires before the attestation is even read).
        IWaterfallEngine.Payment memory second = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: keccak256(abi.encode("EXP4-second", tokenId)),
            payer: borrower,
            interest: 1e18,
            principal: 0,
            nextPaymentDue: 0
        });

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotDistributable.selector, tokenId));
        waterfall.distribute(second);
    }

    /// @notice The single most direct "repay twice" route: consume a PaymentReceived fact through a
    ///         real distribution, then RE-SIGN THE IDENTICAL ECONOMIC FACT under a fresh nonce and
    ///         resubmit it. The oracle's fact-level consume-once ledger (C4-01/C4-02) tombstones the
    ///         (facilityId, kind, payload) triple, so the re-attestation fails closed: the same
    ///         cash cannot fund two principal releases. The first receipt is a PARTIAL coupon after
    ///         one earned month; under continuous accrual it discharges exactly its own amount of
    ///         the contractual interest (docs/remediation/accrual-panel/LIFECYCLE_ACCOUNTING_2026-09-11.md,
    ///         "Repayment, amendments and cap replenishment", row "Cash interest-only receipt":
    ///         "Match the attested interest against unpaid contractual cash interest. Reduce U ...
    ///         by the matched amount"), which this test pins to the wei.
    function test_attack_repayTwice_reAttestSpentFact_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 200_000e18;
        uint256 tokenId = _originateAndFund(principal);

        // One earned month: 200,000e18 x 1400 x 2,592,000 / (10,000 x 31,104,000) =
        // 2,333,333,333,333,333,333,333 -> 2,333,333,333,000,000,000,000 on the grid.
        _warp(30 days);
        uint256 coupon = _coupon(principal, 30 days);
        assertEq(coupon, 2_333_333_333_000_000_000_000, "closed-form Actual/360 coupon on the USDC grid");
        assertEq(reserves.accruedDebt(tokenId).interest, coupon, "engine coupon matches the signed note");

        uint256 interest = 1_000e18; // a partial coupon (1,000 of the 2,333.33 accrued)
        uint256 principalPaid = 100_000e18; // partial -> facility stays performing (Amortizing)
        uint256 stable = (interest + principalPaid) / USDC_GRID;

        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        uint64 nextDue = f.nextPaymentDue + f.paymentInterval;

        bytes32 paymentId = keccak256(abi.encode("EXP4-replay", tokenId, interest, principalPaid));
        bytes32 payload =
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stable, interest, principalPaid, nextDue));

        // Deliver the borrower's cash and run the first (legitimate) distribution, consuming the fact.
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stable);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stable);
        _attest(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload);

        IWaterfallEngine.Payment memory p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principalPaid,
            nextPaymentDue: nextDue
        });
        vm.prank(ops);
        waterfall.distribute(p); // consumes the PaymentReceived fact

        // The partial interest leg discharged exactly itself: 2,333,333,333e12 - 1,000e18 =
        // 1,333,333,333,000,000,000,000 remains; the principal leg discharged exactly itself.
        assertEq(reserves.accruedDebt(tokenId).interest, coupon - interest, "partial interest leg discharged exactly");
        assertEq(reserves.accruedDebt(tokenId).interest, 1_333_333_333_000_000_000_000, "remaining coupon, pinned");
        assertEq(
            reserves.accruedDebt(tokenId).principal,
            principal - principalPaid,
            "partial principal leg discharged exactly"
        );
        assertEq(
            uint8(bridge.facility(tokenId).state),
            uint8(ClaimBridge.LoanState.Amortizing),
            "partial principal -> Amortizing"
        );
        // The ledger, not only the revert below, records the spend.
        assertEq(
            uint8(oracle.factStatus(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload)),
            uint8(IAttestationOracle.FactStatus.Consumed),
            "fact tombstoned as Consumed"
        );

        // Now attempt the double-spend: re-sign the SAME (facilityId, kind, payload) under a fresh
        // nonce. Build the bundle first (that call happens before expectRevert binds), then submit.
        bytes32 factKey = oracle.factKey(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload);
        (IAttestationOracle.AttestationInput memory replay, bytes[] memory sigs) =
            _signPaymentAttestation(tokenId, payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector, factKey, IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(replay, sigs);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Route C: a facility FUNDED AT AN AMOUNT OTHER THAN ITS PRINCIPAL.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Under-funding (deploying less USDC than the originated principal) is refused: the
    ///         position NFT, reserve accounting and registry exposure must all describe the same
    ///         number, so a facility whose deployed principal is less than its claimed principal
    ///         (which would over-state backing) cannot be created.
    function test_attack_fundBelowPrincipal_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originatePendingFilm(principal);

        uint256 usdcAmount = principal / 1e12 - 1e6; // one whole USDC short
        uint256 value = reserves.normalizeUSDC(usdcAmount);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PrincipalMismatch.selector, tokenId, principal, value)
        );
        waterfall.fund(tokenId, usdcAmount);
    }

    /// @notice Over-funding (deploying more USDC than the originated principal) is refused too. An
    ///         over-deployment would move more idle backing out of the treasury than the recorded
    ///         claim accounts for, destroying value on the reserve's balance sheet.
    function test_attack_fundAbovePrincipal_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originatePendingFilm(principal);

        uint256 usdcAmount = principal / 1e12 + 1e6; // one whole USDC over
        uint256 value = reserves.normalizeUSDC(usdcAmount);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IWaterfallEngine.Waterfall_PrincipalMismatch.selector, tokenId, principal, value)
        );
        waterfall.fund(tokenId, usdcAmount);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────────────

    /// @dev The fixture note's contractual coupon for `elapsed` seconds on `principal`: fixed
    ///      `NOTE_RATE_BPS`, Actual/360, floored to USDC's 1e12 grid exactly as the engine's
    ///      `AccrualMath.periodAmount` does (accrual-panel MATH_VALIDATION.md, "Intentional
    ///      reserve-grid floor").
    function _coupon(uint256 principal, uint256 elapsed) internal pure returns (uint256) {
        return (principal * NOTE_RATE_BPS * elapsed / (10_000 * 360 days)) / USDC_GRID * USDC_GRID;
    }

    /// @dev Funds the borrower with the receipt's exact stable amount, approves the reserve, submits a
    ///      REAL 2-of-n PaymentReceived attestation for (interest, principalRepaid, nextDue), and
    ///      returns the matching `Payment` struct. The caller distributes it (so `vm.expectEmit` and
    ///      `vm.expectRevert` bind to `distribute` alone). The cash is real so a guard, never a
    ///      missing balance, is what decides the receipt.
    function _prepAttestedReceipt(
        uint256 tokenId,
        uint256 interest,
        uint256 principalRepaid,
        uint64 nextDue,
        string memory tag
    ) internal returns (IWaterfallEngine.Payment memory p) {
        uint256 stableAmount = (interest + principalRepaid) / USDC_GRID;
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), stableAmount);
        bytes32 paymentId = keccak256(abi.encode(tag, tokenId, interest, principalRepaid));
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stableAmount, interest, principalRepaid, nextDue))
        );
        p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principalRepaid,
            nextPaymentDue: nextDue
        });
    }

    /// @dev Attests and distributes a receipt whose ONLY defect is a principal leg of
    ///      `principalTooHigh` (interest leg zero) and requires the engine's
    ///      `AccrualLoans_PaymentAboveDebt` refusal. The attestation is submitted before the revert
    ///      binds, so only `distribute` is under `vm.expectRevert`.
    function _expectPrincipalRefused(uint256 tokenId, uint256 principalTooHigh, string memory tag) internal {
        IWaterfallEngine.Payment memory p =
            _prepAttestedReceipt(tokenId, 0, principalTooHigh, uint64(block.timestamp + 45 days), tag);
        vm.prank(ops);
        vm.expectRevert(AccrualLoans.AccrualLoans_PaymentAboveDebt.selector);
        waterfall.distribute(p);
    }

    /// @dev Originates a FILM facility through the real m-of-n mint gate but leaves it PENDING
    ///      (unfunded), so the funding-amount checks can be exercised directly. Mirrors the fork
    ///      fixture's `_originateAndFund` minus the `fund` call.
    function _originatePendingFilm(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(
            tokenId, keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref")
        );
        vm.prank(ops);
        uint256 id = bridge.originate(
            ops,
            _forkTerms(keccak256("FORK_BORROWER"), keccak256("US-GA"), principal, 7500, maturity, keccak256("ucc-ref"))
        );
        require(id == tokenId, "EXP4: tokenId drift");
    }

    /// @dev Builds (but does not submit) a genuine 2-of-n PaymentReceived attestation bundle for
    ///      `payload`, signed by both attester keys, signatures sorted ascending by signer address.
    ///      Returned so the caller can submit it under `vm.expectRevert` (the digest read happens
    ///      here, before the revert binds to `oracle.attest`).
    function _signPaymentAttestation(uint256 facilityId, bytes32 payload)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: IAttestationOracle.AttestationKind.PaymentReceived,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        sigs[0] = _signDigest(lo, digest);
        sigs[1] = _signDigest(hi, digest);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
