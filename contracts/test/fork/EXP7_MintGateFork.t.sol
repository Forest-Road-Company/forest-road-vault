// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title EXP7_MintGateForkTest
/// @notice ADVERSARIAL, AUTHORISED, LOCAL-FORK ONLY. Attacks the SYNCHRONIZED NFT MINT GATE
///         (CLAUDE.md 1.3 "NFT mint gate") and the CONCENTRATION admission controls on the
///         FULL protocol, deployed onto a pinned mainnet fork by `ForkLifecycleFixture`.
///
///         The mint gate's promise (ClaimBridge.originate / .checkFundable, AUDIT FIXES H-4 /
///         P-32 / M-01 / M-02): a facility NFT cannot mint, and reserve capital cannot deploy
///         ("escrow" cannot release), unless EVERY attestation kind required for the class is
///         currently satisfied AND the deal-identity quorums (AssignmentExecuted / UCCFiled /
///         CreditIssued) commit to EXACTLY these terms AND every on-chain condition (class
///         active, LTV/maturity in range, concentration respected) holds atomically.
///
///         Each route below composes legitimate operations in an unexpected order or at an
///         unexpected time to try to defeat one of those clauses, and makes the outcome
///         UNAMBIGUOUS: it asserts the exact custom error the protocol reverts with when it
///         blocks the attack, or the violated state if the attack succeeds.
///
///         Attack goals attempted (from the brief):
///           - originate a facility whose attestations are NOT all satisfied      (route 1)
///           - reuse ONE deal's paperwork for ANOTHER / mint unbounded principal   (route 2)
///           - originate a deal whose identity attestation is bound to OTHER terms (route 3)
///           - release escrow (deploy reserves) against a REVOKED attestation      (route 4)
///           - release escrow against terms RE-ATTESTED to a DIFFERENT deal        (route 5)
///           - release escrow WITHOUT a live NFT position (funding a cancelled id) (route 6)
///           - originate PAST a per-borrower concentration limit by SPLITTING it   (route 7)
///         Plus a non-vacuity control (route 0): a fully-correct origination succeeds.
///
///         MAINNET SAFETY (CLAUDE.md prime directive 1): `forge test` never broadcasts, the
///         fork is local and ephemeral, no real key is touched, no real value moves.
contract EXP7_MintGateForkTest is ForkLifecycleFixture {
    uint256 private constant SCALE = 1e12; // 6-dec USDC -> 18-dec USDfr

    bytes32 private constant STATE_GA = keccak256("US-GA");

    // ---------------------------------------------------------------------
    // Local origination helper: attest the FILM gate for the terms, then mint
    // the position NFT — but DO NOT fund. Mirrors `_originateAndFund`'s mint
    // half so a test can leave a facility PENDING and then attack the funding
    // path independently.
    // ---------------------------------------------------------------------
    function _originateFilmOnly(bytes32 borrowerId, bytes32 stateId, uint256 principal, bytes32 ref)
        internal
        returns (uint256 tokenId)
    {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(tokenId, borrowerId, stateId, principal, 7500, maturity, ref);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, _forkTerms(borrowerId, stateId, principal, 7500, maturity, ref));
        require(id == tokenId, "EXP7: tokenId drift");
    }

    // =====================================================================
    // ROUTE 0 (control) — a fully-correct FILM origination MUST succeed, so
    //   the negative routes below cannot pass vacuously by rejecting
    //   everything indiscriminately.
    // =====================================================================
    function test_route0_control_legitimateOriginationSucceeds() external onFork {
        bytes32 borrowerId = keccak256("EXP7-honest-borrower");
        uint256 principal = 1_000_000e18;

        uint256 expectedId = bridge.totalOriginated() + 1;
        uint256 id = _originateFilmOnly(borrowerId, STATE_GA, principal, keccak256("ref-honest"));

        assertEq(id, expectedId, "id should advance by one");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending), "minted Pending");
        assertEq(bridge.ownerOf(id), ops, "NFT held by the custody holder");
        assertEq(registry.borrowerExposure(borrowerId), principal, "exposure booked exactly once");
    }

    // =====================================================================
    // ROUTE 1 — originate with a REQUIRED attestation missing.
    //   Attest AssignmentExecuted + UCCFiled but withhold the CreditIssued
    //   terms quorum, then originate. The gate must refuse: a facility cannot
    //   mint while any required off-chain fact is unattested.
    //   EXPECT: Bridge_AttestationMissing(FILM, CreditIssued).
    // =====================================================================
    function test_route1_originateWithMissingCreditIssued_blocked() external onFork {
        bytes32 borrowerId = keccak256("EXP7-missing-attn");
        uint256 principal = 1_000_000e18;
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);

        ClaimBridge.OriginationTerms memory terms =
            _forkTerms(borrowerId, STATE_GA, principal, 7500, maturity, keccak256("ref-1"));
        bytes32 termsHash = bridge.creditTermsHash(terms);

        // Two of the three deal-identity facts are attested; the TERMS quorum is deliberately absent.
        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.CreditIssued
            )
        );
        bridge.originate(ops, terms);

        // Nothing minted, nothing booked.
        assertEq(bridge.totalOriginated(), nextId - 1, "no NFT minted");
        assertEq(registry.borrowerExposure(borrowerId), 0, "no exposure booked");
    }

    // =====================================================================
    // ROUTE 2 — reuse ANOTHER deal's paperwork / mint UNBOUNDED principal
    //   (the H-4 sequence-desync + unbounded-principal class).
    //   A quorum diligences and signs a SMALL $500k receivable at the next
    //   facility id. Before anyone originates it, the attacker tries to mint
    //   a $50m facility against that same, already-satisfied attestation slot.
    //   Because `nextId` only advances on a SUCCESSFUL mint, the bundle sits
    //   exactly where the gate will read it — the pre-H-4 hole. The terms
    //   binding must reject it: the attested CreditIssued payload commits to
    //   the $500k terms, not the $50m ones.
    //   EXPECT: Bridge_TermsNotAttested(nextId, hash(bigTerms), hash(smallTerms)).
    // =====================================================================
    function test_route2_reuseAnotherDealsPaperworkForBiggerPrincipal_blocked() external onFork {
        bytes32 borrowerId = keccak256("EXP7-desync-borrower");
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);

        // The quorum signs the SMALL, diligenced deal at `nextId` (but it is never originated).
        ClaimBridge.OriginationTerms memory smallTerms =
            _forkTerms(borrowerId, STATE_GA, 500_000e18, 7500, maturity, keccak256("ref-small"));
        _attestFilmGate(nextId, borrowerId, STATE_GA, 500_000e18, 7500, maturity, keccak256("ref-small"));
        bytes32 attestedHash = bridge.creditTermsHash(smallTerms);

        // The attacker reuses that attestation slot to mint 100x the signed amount.
        ClaimBridge.OriginationTerms memory bigTerms =
            _forkTerms(borrowerId, STATE_GA, 50_000_000e18, 7500, maturity, keccak256("ref-small"));
        bytes32 bigHash = bridge.creditTermsHash(bigTerms);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, nextId, bigHash, attestedHash)
        );
        bridge.originate(ops, bigTerms);

        assertEq(bridge.totalOriginated(), nextId - 1, "no oversized NFT minted");
        assertEq(registry.borrowerExposure(borrowerId), 0, "no $50m exposure booked");
    }

    // =====================================================================
    // ROUTE 3 — a deal-identity attestation bound to a DIFFERENT deal (P-32).
    //   CreditIssued and UCCFiled commit to the correct terms, but the
    //   AssignmentExecuted quorum commits to an unrelated deal's hash. The
    //   gate must require EVERY deal-identity payload to equal these terms,
    //   not merely to exist.
    //   EXPECT: Bridge_AttestationNotBoundToDeal(FILM, AssignmentExecuted, expected, wrong).
    // =====================================================================
    function test_route3_dealIdentityAttestationBoundToOtherTerms_blocked() external onFork {
        bytes32 borrowerId = keccak256("EXP7-p32-borrower");
        uint256 principal = 1_000_000e18;
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);

        ClaimBridge.OriginationTerms memory terms =
            _forkTerms(borrowerId, STATE_GA, principal, 7500, maturity, keccak256("ref-3"));
        bytes32 termsHash = bridge.creditTermsHash(terms);
        bytes32 wrongHash = keccak256("EXP7-some-other-deal-assignment");

        // Assignment is bound to an UNRELATED deal; UCC and Credit are bound correctly.
        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, wrongHash);
        _attest(nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationNotBoundToDeal.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.AssignmentExecuted,
                termsHash,
                wrongHash
            )
        );
        bridge.originate(ops, terms);

        assertEq(registry.borrowerExposure(borrowerId), 0, "no exposure booked");
    }

    // =====================================================================
    // ROUTE 4 — release escrow (deploy reserves) against a REVOKED attestation.
    //   Originate a clean facility (Pending, NFT minted). Governance then
    //   revokes the CreditIssued terms quorum (e.g. discovered false). The
    //   servicer tries to fund it anyway. `checkFundable` re-runs the gate at
    //   funding time (AUDIT FIX M-01), so the deploy must be refused even
    //   though origination once passed.
    //   EXPECT: Bridge_AttestationMissing(FILM, CreditIssued) bubbling out of fund().
    // =====================================================================
    function test_route4_fundAfterCreditIssuedRevoked_blocked() external onFork {
        // Seed idle reserves so liquidity can never be the reason funding fails.
        _mintFromUSDC(alice, 2_000_000e6);

        bytes32 borrowerId = keccak256("EXP7-revoke-borrower");
        uint256 principal = 1_000_000e18;
        uint256 id = _originateFilmOnly(borrowerId, STATE_GA, principal, keccak256("ref-4"));

        // Governance emergency-revokes the terms quorum (address(this) retains DEFAULT_ADMIN
        // on the oracle under the fork's keepOpsAdmin posture).
        oracle.revoke(id, IAttestationOracle.AttestationKind.CreditIssued);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.CreditIssued
            )
        );
        waterfall.fund(id, principal / SCALE);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending), "never funded");
    }

    // =====================================================================
    // ROUTE 5 — release escrow against terms RE-ATTESTED to a DIFFERENT deal.
    //   A sharper H-4 funding-path variant: after revoking the CreditIssued
    //   quorum, the attacker re-attests a FRESH CreditIssued at the same id but
    //   pointing at a DIFFERENT terms hash (a payload the quorum will sign for
    //   some other deal). The record now reads "satisfied", so a naive
    //   existence check would pass — but the gate compares the payload to the
    //   facility's STORED terms and must reject the divergence.
    //   EXPECT: Bridge_TermsNotAttested(id, hash(storedTerms), divergedHash).
    // =====================================================================
    function test_route5_fundAfterCreditIssuedReboundToOtherTerms_blocked() external onFork {
        _mintFromUSDC(alice, 2_000_000e6);

        bytes32 borrowerId = keccak256("EXP7-rebind-borrower");
        uint256 principal = 1_000_000e18;
        uint64 maturity = uint64(block.timestamp + 365 days);
        bytes32 ref = keccak256("ref-5");
        uint256 id = _originateFilmOnly(borrowerId, STATE_GA, principal, ref);
        bytes32 storedTermsHash =
            bridge.creditTermsHash(_forkTerms(borrowerId, STATE_GA, principal, 7500, maturity, ref));

        // Revoke the correct terms quorum, then re-attest a satisfied CreditIssued that points
        // at an unrelated deal. (The revoked exact-terms fact is tombstoned; a DIFFERENT payload
        // is a fresh fact key and is accepted by the oracle.)
        oracle.revoke(id, IAttestationOracle.AttestationKind.CreditIssued);
        bytes32 divergedHash = keccak256("EXP7-diverged-terms");
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, divergedHash);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, id, storedTermsHash, divergedHash)
        );
        waterfall.fund(id, principal / SCALE);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending), "never funded");
    }

    // =====================================================================
    // ROUTE 6 — release escrow WITHOUT a live NFT position.
    //   Originate then cancel a facility (the NFT is BURNED, exposure reversed,
    //   state -> Cancelled). Attempt to fund the dead id. Escrow release is
    //   contractually conditioned on the token existing; funding a burned
    //   position must revert.
    //   EXPECT: Waterfall_NotFundable(id).
    // =====================================================================
    function test_route6_fundCancelledPositionWithoutNft_blocked() external onFork {
        _mintFromUSDC(alice, 2_000_000e6);

        bytes32 borrowerId = keccak256("EXP7-cancel-borrower");
        uint256 principal = 1_000_000e18;
        uint256 id = _originateFilmOnly(borrowerId, STATE_GA, principal, keccak256("ref-6"));

        // Retire the pending facility: burns the NFT and reverses the booked exposure.
        vm.prank(ops);
        bridge.cancelPending(id);
        assertEq(registry.borrowerExposure(borrowerId), 0, "exposure reversed on cancel");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Cancelled), "position cancelled");

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotFundable.selector, id));
        waterfall.fund(id, principal / SCALE);
    }

    // =====================================================================
    // ROUTE 7 — originate PAST a per-borrower concentration limit by SPLITTING.
    //   The fork seeds every concentration dimension WIDE OPEN (100% ramp), so
    //   first bind a real per-borrower limit through governance (address(this)
    //   retains DEFAULT_ADMIN under keepOpsAdmin). With a 2m bootstrap floor and
    //   a 50% per-borrower limit, the absolute per-borrower allowance is 1m.
    //   The attacker splits a 1.4m position for one borrower into two 0.7m
    //   originations, each individually under the 1m allowance, hoping the
    //   ordering slips both past. The admission rule is monotone in the amount
    //   added and measured against the cumulative book, so the SECOND must fail.
    //   EXPECT: piece 1 mints; piece 2 reverts
    //           Registry_BorrowerConcentrationExceeded(borrower, 1.4m, 5000).
    // =====================================================================
    function test_route7_concentrationSplitPerBorrower_blocked() external onFork {
        // Bind a real per-borrower limit and a small bootstrap floor so the limit actually bites.
        registry.setConcentrationFloor(2_000_000e18);
        registry.setBorrowerLimit(5000); // 50% of max(book, floor)

        bytes32 borrowerId = keccak256("EXP7-conc-borrower");
        uint256 piece = 700_000e18; // 0.7m each; 1.4m combined > 1m allowance

        // Piece 1: 0.7m < 1m allowance -> admitted.
        uint256 id1 = _originateFilmOnly(borrowerId, STATE_GA, piece, keccak256("split-1"));
        assertEq(registry.borrowerExposure(borrowerId), piece, "piece 1 booked");
        assertEq(uint256(bridge.facility(id1).state), uint256(ClaimBridge.LoanState.Pending), "piece 1 minted");

        // Piece 2: attested honestly for its own terms, but its exposure would push the
        // borrower to 1.4m > 1m. The atomic registry check must reject it.
        uint256 id2 = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        _attestFilmGate(id2, borrowerId, STATE_GA, piece, 7500, maturity, keccak256("split-2"));
        ClaimBridge.OriginationTerms memory t2 =
            _forkTerms(borrowerId, STATE_GA, piece, 7500, maturity, keccak256("split-2"));

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector,
                borrowerId,
                uint256(1_400_000e18),
                uint256(5000)
            )
        );
        bridge.originate(ops, t2);

        // The book still reflects only the single admitted piece — the split did not slip through.
        assertEq(registry.borrowerExposure(borrowerId), piece, "second piece not booked");
        assertEq(bridge.totalOriginated(), id1, "no second NFT minted");
    }
}
