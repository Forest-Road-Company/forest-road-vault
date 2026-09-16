// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";

/// @title EXP4_WaterfallForkTest — adversarial attack on WATERFALL VALUE CONSERVATION
/// @notice AUTHORISED pre-audit red-team on a pinned mainnet fork (no broadcast, no mainnet, no
///         real value). GOAL: make a repayment distribution CREATE or DESTROY value, or
///         SUBORDINATE senior (`sUSDfr`) to junior (curator). Three families of route are tried,
///         each composing legitimate operations in an illegitimate order/amount:
///
///           (A) a DISTRIBUTION WITH A MISMATCHED PRINCIPAL — attest one interest/principal split
///               and distribute a different one; and declare a principal larger than the facility's
///               live outstanding.
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

    // ────────────────────────────────────────────────────────────────────────
    // Positive control: the honest repayment path conserves value exactly.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice A full, healthy repayment mints EXACTLY the interest it received as new supply and
    ///         raises backing by EXACTLY the same amount — nothing created, nothing destroyed — and
    ///         routes the yield to the senior vault, never to junior curator capital.
    function test_valueConservation_healthyRepayConservesValueAndPaysSenior() public onFork {
        _mintFromUSDC(alice, 1_000_000e6); // seed idle liquidity for funding

        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);
        uint256 outstanding = reserves.deployedTo(tokenId);
        assertEq(outstanding, principal, "funded amount must equal principal");

        uint256 interest = 10_000e18; // whole USDC units

        uint256 supplyBefore = controller.totalUSDfr();
        uint256 backingBefore = controller.backingValue();
        uint256 vaultBefore = usdfr.balanceOf(address(vault));

        _repay(tokenId, interest, outstanding); // full repayment -> facility closes to Repaid

        uint256 supplyAfter = controller.totalUSDfr();
        uint256 backingAfter = controller.backingValue();

        // VALUE CONSERVATION: the only new supply is the interest, and backing rose by the identical
        // amount of real cash that arrived. Over-issuance (value creation) would make the supply
        // delta exceed the interest; a leak would make backing rise by less than it received.
        assertEq(backingAfter - backingBefore, interest, "backing must rise by exactly the cash received");
        assertEq(supplyAfter - supplyBefore, interest, "supply must rise by exactly the interest minted");

        // SENIORITY: the senior vault received the yield. Curator (junior) capital is never paid out
        // of a repayment, so the senior is not subordinated to the junior on the yield path.
        assertGt(usdfr.balanceOf(address(vault)), vaultBefore, "senior vault must receive the yield");
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

    /// @notice A distribution declaring MORE principal than the facility's live outstanding is
    ///         refused even with a perfectly matching attestation. Without this, a servicer could
    ///         drive `deployedTo` negative (a value-destroying underflow) or release exposure the
    ///         borrower never repaid.
    function test_attack_principalExceedsOutstanding_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);

        uint256 outstanding = reserves.deployedTo(tokenId);
        uint256 interest = 1_000e18;
        uint256 principalTooHigh = outstanding + ONE_USDC_VALUE; // one whole USDC beyond the claim
        uint64 nextDue = uint64(block.timestamp + 45 days);

        uint256 stable = (interest + principalTooHigh) / 1e12;
        bytes32 paymentId = keccak256(abi.encode("EXP4-exceeds", tokenId));
        bytes32 payload =
            keccak256(abi.encode(paymentId, tokenId, USDC, borrower, stable, interest, principalTooHigh, nextDue));
        _attest(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload);

        IWaterfallEngine.Payment memory p = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principalTooHigh,
            nextPaymentDue: nextDue
        });

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWaterfallEngine.Waterfall_PrincipalExceedsOutstanding.selector, tokenId, principalTooHigh, outstanding
            )
        );
        waterfall.distribute(p);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Route B: REPAYING TWICE.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice After a facility is fully repaid (state Repaid) any further distribution is refused
    ///         at the lifecycle gate, so recovery cash cannot be routed a second time against a
    ///         closed position.
    function test_attack_repayTwice_onClosedFacility_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 500_000e18;
        uint256 tokenId = _originateAndFund(principal);
        uint256 outstanding = reserves.deployedTo(tokenId);

        _repay(tokenId, 10_000e18, outstanding); // full repayment -> Repaid

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
    ///         (facilityId, kind, payload) triple, so the re-attestation fails closed — the same
    ///         cash cannot fund two principal releases.
    function test_attack_repayTwice_reAttestSpentFact_reverts() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        uint256 principal = 200_000e18;
        uint256 tokenId = _originateAndFund(principal);

        uint256 interest = 1_000e18;
        uint256 principalPaid = 100_000e18; // partial -> facility stays performing (Amortizing)
        uint256 stable = (interest + principalPaid) / 1e12;

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
