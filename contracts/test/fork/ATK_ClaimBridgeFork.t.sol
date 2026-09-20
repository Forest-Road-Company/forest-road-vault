// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAccrualLifecycle} from "../../src/interfaces/IAccrualLifecycle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_ClaimBridgeFork: adversarial attacks on the facility position register against the
///        FULL protocol on a pinned mainnet fork with REAL USDC.
///
/// @notice This suite does not document the bridge, it tries to BREAK the invariant it must hold
///         (CLAUDE.md 1.3, "NFT mint gate"): a Loan NFT cannot mint unless all required
///         attestations are satisfied AND on-chain conditions hold, and escrow (reserve capital)
///         cannot release without the NFT. `EXP7_MintGateFork` already covers a missing kind, a
///         reused bundle at a bigger principal, a deal-identity kind bound elsewhere, funding after
///         revocation or re-binding, funding a cancelled id and a split concentration limit. Nothing
///         here repeats those routes; every attack below extends past them.
///
///         The attacker is `carol`: not KYC'd, holding no protocol role, funded with 1,000,000
///         USDC by the fixture. `ops` is used only to reach a legitimate state; the attack itself
///         is made by carol wherever the surface is reachable by her, and by ops OUT OF ORDER
///         wherever the surface is role-gated (the gate then has to hold against the operator's
///         own mistakes and against a compromised operator key).
///
///         Attacks attempted (each outcome is made unambiguous: a blocked attack asserts the
///         specific custom error AND the untouched state, a successful exploit would fail on the
///         violated quantity so the message names the money):
///           A1. originate with terms that diverge from the attested terms in ONE field at a
///               time, over every field of `OriginationTerms` (18 fields), plus the internally
///               consistent two-field variants that reach the gate for the fields a sanity check
///               catches first. Every one must revert; the honest terms must still mint after.
///           A2. originate twice on one satisfied gate: the second call must not mint a second
///               NFT and must not book a second exposure.
///           A3. carol originates against a fully attested gate; the attestations must survive
///               her attempt untouched so the real originator can still use them. Then the one
///               input the originator alone controls (`holder`) is shown to carry no value.
///           A4. release escrow without an NFT: fund a never-originated id, the id a reverted
///               originate would have taken, id 0, and a FULLY ATTESTED id that was never minted.
///           A5. replay a signed amendment: same amendment id, same fact re-signed under a fresh
///               nonce, a fresh amendment id with identical content, an amendment attested for a
///               different facility, a maturity extension on a non-renewable facility, and the
///               reserve-only PIK due-date writer called by carol and by ops. Then (A5b) SIGNED
///               amendments that would carry a live facility outside the accrual envelope: a
///               maturity extension on a non-renewable note, a 30/360 or variable-rate
///               re-pricing the engine cannot service, a due date already in the past, and a
///               PIK note moved off Actual/360. Each is attested by the quorum and must still
///               be refused, with the signature left standing rather than spent.
///           A6. the lifecycle state machine driven out of order by ops (distribute before fund,
///               default on Pending, amend on Pending, originate while paused, originate over an
///               exhausted class limit, originate and fund on an inactive class, re-bind the
///               accrual source as the admin, cancel an Active facility), every role-gated
///               entry point called by carol, and (A6c) funding a Pending facility on a STALE
///               schedule: at its first due date, past it, and at maturity, to the second.
///           A7. the terms-hash preimage binds every field: toggling any single field, `pik`
///               included, changes `creditTermsHash`, the on-chain gate consumes the same
///               commitment the view exposes, and a PIK facility mints only under its PIK hash.
///
///         MAINNET SAFETY (CLAUDE.md prime directive 1): `forge test` never broadcasts, the fork
///         is local and ephemeral, no real key is touched, no real value moves.
contract ATK_ClaimBridgeForkTest is ForkLifecycleFixture {
    uint256 private constant SCALE = 1e12; // 6-dec USDC -> 18-dec USDfr

    bytes32 private constant STATE_GA = keccak256("US-GA");
    bytes32 private constant BORROWER = keccak256("ATK-CB-borrower");
    bytes32 private constant REF = keccak256("ATK-CB-ucc-ref");
    uint256 private constant PRINCIPAL = 1_000_000e18;
    uint16 private constant LTV = 7500;

    /// @dev Number of fields in `ClaimBridge.OriginationTerms`. Every field is a static type, so
    ///      `abi.encode(terms)` is exactly one 32-byte word per field; A1 and A7 assert that
    ///      identity so a field added to the struct without a matching case in `_diverge` fails
    ///      loudly instead of silently escaping the gate coverage.
    uint256 private constant TERMS_FIELD_COUNT = 18;

    // ─────────────────────────────────────────────────────────────────────
    // A1: every single-field divergence from the attested terms is refused
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the mint gate's full-payload binding (AUDIT FIX H-4 / P-32). The quorum
    ///         signs terms T at the next facility id; the originator then submits T2 that differs
    ///         from T in exactly one field. A failure here means a signed bundle for one deal
    ///         mints a different deal: a larger principal, a different obligor or state, a
    ///         redirected funding recipient, a different rate, tenor or schedule, a different
    ///         lien reference, or a PIK facility signed as cash-pay. Any of those is capital
    ///         deployed against paperwork that does not describe it.
    function test_atk_originateWithDivergentTermsIsRefusedFieldByField() public onFork {
        uint256 id = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        ClaimBridge.OriginationTerms memory base = _baseTerms(maturity);
        bytes32 attested = bridge.creditTermsHash(base);

        // The loop below covers every field. If the struct grows this identity breaks first.
        assertEq(
            abi.encode(base).length,
            TERMS_FIELD_COUNT * 32,
            "OriginationTerms field count changed: extend _diverge or the gate has uncovered fields"
        );

        // Preconditions that keep the +1 divergences valid on-chain terms, so they reach the
        // attestation gate rather than the earlier sanity checks.
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        assertLt(LTV, p.maxLtvBps, "precondition: ltv + 1 stays within the class ceiling");
        assertLt(
            uint256(maturity) + 1, block.timestamp + p.maxMaturity, "precondition: maturity + 1s stays within tenor"
        );
        assertEq(
            uint256(p.model),
            uint256(ICollateralRegistry.CollateralModel.Receivable),
            "precondition: FILM is a receivable class, so a PIK toggle alone reaches the gate"
        );

        _attestFilmGate(id, BORROWER, STATE_GA, PRINCIPAL, LTV, maturity, REF);
        uint256 exposureBefore = registry.borrowerExposure(BORROWER);
        uint256 classBefore = registry.classExposure(Config.CLASS_FILM_TAX_CREDITS);

        for (uint256 i = 0; i < TERMS_FIELD_COUNT; ++i) {
            _attackDivergentField(id, base, attested, i);
        }

        // Fields that a sanity check catches in single-field form are also bound at the gate:
        // make each internally consistent (two fields) so the ATTESTATION comparison is what
        // refuses them, not the shape check.
        ClaimBridge.OriginationTerms memory t = _copy(base);
        t.classId = Config.CLASS_RENEWABLE_ENERGY;
        t.stateId = bytes32(0); // a non-film class must carry no state key
        _expectTermsNotAttested(id, t, attested, "classId moved to another vertical");

        t = _copy(base);
        t.rateType = ClaimBridge.RateType.Variable;
        t.rateIndexRef = keccak256("ATK-CB-SOFR");
        _expectTermsNotAttested(id, t, attested, "rateType switched to variable with an index");

        t = _copy(base);
        t.renewable = true;
        t.renewalTermsHash = keccak256("ATK-CB-renewal");
        _expectTermsNotAttested(id, t, attested, "renewable with a renewal hash");

        // Nothing minted, nothing booked, across every attempt.
        assertEq(bridge.totalOriginated(), id - 1, "a divergent origination minted an NFT");
        assertEq(registry.borrowerExposure(BORROWER), exposureBefore, "a divergent origination booked exposure");
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), classBefore, "class exposure moved");

        // The rejected attempts did not consume or disturb the bundle: the honest terms mint,
        // and the register commits to exactly the attested hash.
        vm.expectEmit(true, true, true, true, address(bridge));
        emit ClaimBridge.Originated(id, Config.CLASS_FILM_TAX_CREDITS, BORROWER, attested);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, base);
        assertEq(minted, id, "honest origination takes the attested id");
        assertEq(registry.borrowerExposure(BORROWER), exposureBefore + PRINCIPAL, "honest exposure booked once");
        assertEq(bridge.facility(id).principal, PRINCIPAL, "stored principal is the attested principal");
        assertEq(bridge.facility(id).fundingRecipient, borrower, "stored recipient is the attested recipient");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2: one satisfied gate mints exactly one NFT
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the one-gate-one-mint property. Origination does not consume the three
    ///         deal-identity facts (`checkFundable` re-reads them at funding), so the bundle at
    ///         the minted id stays satisfied for the life of the facility. A second `originate`
    ///         with byte-identical terms must read the NEXT id, where nothing is attested, and
    ///         refuse. A failure here means one signed deal books two facilities and two
    ///         exposures against one lien: 1,000,000e18 of phantom claim.
    function test_atk_originateTwiceOnOneGateCannotMintASecondNft() public onFork {
        (uint256 id, ClaimBridge.OriginationTerms memory base) = _originatePendingFilm();
        bytes32 attested = bridge.creditTermsHash(base);

        // The gate's facts are live after the mint; this is what a replay would try to reuse.
        assertTrue(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.AssignmentExecuted), "assignment live");
        assertTrue(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.UCCFiled), "ucc live");
        assertTrue(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.CreditIssued), "credit live");
        assertEq(
            uint256(oracle.factStatus(id, IAttestationOracle.AttestationKind.CreditIssued, attested)),
            uint256(IAttestationOracle.FactStatus.Recorded),
            "origination leaves the terms fact Recorded, not Consumed"
        );

        // ATTACK: re-run originate with the identical terms while the bundle is still satisfied.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.AssignmentExecuted
            )
        );
        bridge.originate(ops, base);

        // No second NFT exists in either register view.
        assertEq(bridge.totalOriginated(), id, "a second originate advanced the register");
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, id + 1));
        bridge.facility(id + 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id + 1));
        bridge.ownerOf(id + 1);
        assertEq(bridge.balanceOf(ops), 1, "the holder owns exactly one position");
        assertEq(registry.borrowerExposure(BORROWER), PRINCIPAL, "exposure booked exactly once");
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), PRINCIPAL, "class exposure booked exactly once");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3: carol cannot originate, and her attempt leaves the gate intact
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the originator gate from the roleless attacker, then the one input the
    ///         originator alone controls. A failure in the first half means anyone can mint the
    ///         position of record for a fully attested deal. A failure in the second half means
    ///         the custody `holder` (which is NOT in the signed preimage) carries value: the
    ///         funding leg or the transfer restriction would follow the holder rather than the
    ///         attested `fundingRecipient` and governance.
    function test_atk_carolCannotOriginateAndTheHolderCarriesNoValue() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        ClaimBridge.OriginationTerms memory base = _baseTerms(maturity);
        bytes32 attested = bridge.creditTermsHash(base);
        _attestFilmGate(id, BORROWER, STATE_GA, PRINCIPAL, LTV, maturity, REF);

        // ATTACK: carol originates against the satisfied gate, naming herself as holder.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.ORIGINATOR_ROLE
            )
        );
        bridge.originate(carol, base);

        assertEq(bridge.totalOriginated(), id - 1, "carol minted");
        assertEq(registry.borrowerExposure(BORROWER), 0, "carol booked exposure");

        // The three facts are exactly as the quorum left them: Recorded and satisfied.
        IAttestationOracle.AttestationKind[3] memory kinds = [
            IAttestationOracle.AttestationKind.AssignmentExecuted,
            IAttestationOracle.AttestationKind.UCCFiled,
            IAttestationOracle.AttestationKind.CreditIssued
        ];
        for (uint256 k = 0; k < 3; ++k) {
            assertTrue(oracle.isSatisfied(id, kinds[k]), "carol's attempt cleared a satisfied fact");
            (bytes32 payload,, bool ok) = oracle.latestPayload(id, kinds[k]);
            assertTrue(ok, "fact no longer satisfied");
            assertEq(payload, attested, "fact payload disturbed");
            assertEq(
                uint256(oracle.factStatus(id, kinds[k], attested)),
                uint256(IAttestationOracle.FactStatus.Recorded),
                "fact status left Recorded"
            );
        }

        // The legitimate originator can still use the bundle. It names carol as holder, which is
        // the one input the gate does not bind: prove that confers nothing.
        vm.prank(ops);
        uint256 minted = bridge.originate(carol, base);
        assertEq(minted, id, "legitimate origination after carol's attempt");
        assertEq(bridge.ownerOf(id), carol, "carol holds the position of record");

        // Funding follows the ATTESTED recipient, not the holder.
        uint256 carolUsdcBefore = IERC20(USDC).balanceOf(carol);
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(borrower);
        uint256 units = PRINCIPAL / SCALE;
        uint256 feeUnits = units * waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS) / Config.BPS;
        vm.prank(ops);
        waterfall.fund(id, units);
        assertEq(IERC20(USDC).balanceOf(carol), carolUsdcBefore, "the holder received funding");
        assertEq(
            IERC20(USDC).balanceOf(borrower) - borrowerUsdcBefore,
            units - feeUnits,
            "the attested recipient nets principal minus the OID fee"
        );
        assertEq(reserves.deployedTo(id), PRINCIPAL, "deployed exactly the attested principal");

        // The holder cannot move the position: transfers need governance execution.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TransferRestricted.selector));
        bridge.transferFrom(carol, alice, id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TransferRestricted.selector));
        bridge.safeTransferFrom(carol, alice, id);
        assertEq(bridge.ownerOf(id), carol, "position moved");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4: escrow cannot release without an NFT
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the second half of the invariant: reserve capital cannot deploy to a
    ///         facility id that carries no position NFT. Tried on a never-originated id, the id a
    ///         reverted originate would have taken, id 0, and an id whose full mint bundle is
    ///         attested but never minted. A failure here means USDC leaves the treasury against
    ///         a facility the register does not know: 1,000,000 USDC with no claim behind it.
    function test_atk_escrowCannotReleaseWithoutAnNft() public onFork {
        _mintFromUSDC(alice, 2_000_000e6); // liquidity is never the reason a fund fails here
        uint256 idleBefore = reserves.idleUSDC();
        uint256 deployedBefore = reserves.deployedPrincipal();
        uint256 borrowerBefore = IERC20(USDC).balanceOf(borrower);
        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        ClaimBridge.OriginationTerms memory base = _baseTerms(maturity);
        uint256 units = PRINCIPAL / SCALE;

        // (a) never originated
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, nextId));
        waterfall.fund(nextId, units);

        // (b) a reverted originate does not advance `nextId`: the id it would have taken is the
        //     same id as (a), still unknown to the register, and still not fundable. This is
        //     the same assertion as (a) at the same id, on purpose: it proves the revert left
        //     no half-written facility behind.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.AssignmentExecuted
            )
        );
        bridge.originate(ops, base);
        assertEq(bridge.totalOriginated(), nextId - 1, "a reverted originate advanced nextId");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, nextId));
        waterfall.fund(nextId, units);

        // (c) id 0 is never a facility
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 0));
        waterfall.fund(0, units);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, 0));
        bridge.checkFundable(0);

        // (d) a FULLY ATTESTED bundle is still not an NFT
        _attestFilmGate(nextId, BORROWER, STATE_GA, PRINCIPAL, LTV, maturity, REF);
        assertTrue(oracle.isSatisfied(nextId, IAttestationOracle.AttestationKind.CreditIssued), "bundle attested");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, nextId));
        waterfall.fund(nextId, units);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_UnknownToken.selector, nextId));
        bridge.checkFundable(nextId);

        // (e) carol, on the same id, is stopped at the door
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        waterfall.fund(nextId, units);

        assertEq(reserves.deployedTo(nextId), 0, "capital deployed to an id with no NFT");
        assertEq(reserves.deployedTo(0), 0, "capital deployed to id 0");
        assertEq(reserves.deployedPrincipal(), deployedBefore, "deployed principal moved without an NFT");
        assertEq(reserves.idleUSDC(), idleBefore, "idle USDC left the treasury without an NFT");
        assertEq(IERC20(USDC).balanceOf(borrower), borrowerBefore, "the recipient was paid without an NFT");

        // Control: the same bundle, once minted, funds at exactly the attested principal. The
        // OID fee's stables never leave the treasury (ADR-0019), so idle falls by the net draw.
        vm.prank(ops);
        uint256 id = bridge.originate(ops, base);
        assertEq(id, nextId, "control mint takes the attested id");
        uint256 feeUnits = units * waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS) / Config.BPS;
        vm.prank(ops);
        waterfall.fund(id, units);
        assertEq(reserves.deployedTo(id), PRINCIPAL, "control fund deployed exactly principal");
        assertEq(reserves.idleUSDC(), idleBefore - (units - feeUnits), "control fund drew principal net of the OID fee");
        assertEq(IERC20(USDC).balanceOf(borrower), borrowerBefore + units - feeUnits, "recipient paid net of the fee");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5: a signed amendment executes once
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks amendment replay. A servicing amendment is a signed one-shot fact keyed by
    ///         (facility, kind, payload) where the payload commits to the amendment id, the token
    ///         id and the full amendment struct. A failure here means one quorum signature
    ///         re-prices or re-schedules a live facility more than once, an amendment for one
    ///         facility lands on another, a non-renewable facility gets extended, or a roleless
    ///         address drives the PIK due-date cursor.
    function test_atk_amendmentReplayIsRefusedAndAccruedDueIsReserveOnly() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(PRINCIPAL);
        ClaimBridge.Facility memory before = bridge.facility(id);
        assertEq(uint256(before.state), uint256(ClaimBridge.LoanState.Active), "precondition: Active");
        assertEq(bridge.accrualReserve(), address(reserves), "precondition: continuous accrual is bound");
        assertTrue(reserves.accrualSnapshot().enabled, "precondition: continuous accrual is enabled");

        ClaimBridge.Amendment memory a = _amendmentFor(before, 1500, keccak256("ATK-CB-amended-schedule"));
        bytes32 amendmentId = keccak256("ATK-CB-amendment-1");
        bytes32 payload = keccak256(abi.encode(amendmentId, id, a));

        // (0) unattested: refused before anything is written
        _refuseAmendment(id, amendmentId, a);

        // Seven days of accrual at the signed 1,400 bps, then the legitimate amendment to
        // 1,500 bps: attested, applied once, fact consumed, the closed curve exact to the wei.
        _warp(7 days);
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, payload);
        _applyAmendmentAndVerify(id, before, amendmentId, a, payload);
        ClaimBridge.Facility memory after1 = bridge.facility(id);
        uint256 closedAt1400 = _gridInterest(PRINCIPAL, before.interestRateBps, 7 days);
        assertEq(reserves.accruedDebt(id).interest, closedAt1400, "interest closed at the OLD rate over 7 days");

        // (1) REPLAY the same amendment id: the fact is spent, nothing stands to be read.
        _refuseAmendment(id, amendmentId, a);

        // (2) RE-SIGN the identical fact under a fresh nonce: the oracle refuses at the ledger,
        //     the fact stays spent and the replay stays refused.
        _refuseResignedFact(id, payload);
        _refuseAmendment(id, amendmentId, a);

        // Seven more days accrue at the NEW rate exactly once: the amendment took effect one
        // time, and only from its block.
        _warp(7 days);
        uint256 expected14 = closedAt1400 + _gridInterest(PRINCIPAL, a.interestRateBps, 7 days);
        assertEq(reserves.accruedDebt(id).interest, expected14, "interest after the amendment runs at the NEW rate");

        // (3) A FRESH amendment id with identical economic content is a NEW signed event and is
        //     accepted by design (the amendment id is the event identity). Applied on a live
        //     curve it must be state-neutral: no register field, no debt field and no gross
        //     accrued amount may move at the block it is applied.
        _applyIdenticalAmendmentIsNeutral(id, a, after1);

        // (4) An amendment attested for THIS facility cannot be applied to ANOTHER facility.
        _refuseCrossFacilityAmendment(id, a, before.interestRateBps);

        // (5) A non-renewable facility cannot be extended by an UNSIGNED amendment: the shape
        //     check refuses it before the oracle is read. The SIGNED extension, which is the
        //     case that would matter if this shape check were lost, is A5b's first case; it
        //     needs its own facility because the amendment-3 fact from (4) still stands on
        //     this one and the oracle admits one unconsumed TermsAmended fact per facility.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector));
        bridge.amendTerms(id, keccak256("ATK-CB-extend"), _extendedBy(a, 1));
        assertEq(bridge.facility(id).maturity, before.maturity, "maturity extended on a non-renewable facility");

        // (6) The PIK due-date writer is reserve-only: carol, and even ops (originator, servicer
        //     and admin here), are refused by identity before any state is read.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, carol));
        bridge.setAccruedPaymentDue(id, before.nextPaymentDue + 1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualReserveOnly.selector, ops));
        bridge.setAccruedPaymentDue(id, before.nextPaymentDue + 1);
        assertEq(bridge.facility(id).nextPaymentDue, before.nextPaymentDue, "due date moved by a non-reserve");
    }

    /// @dev A5 (3): a second amendment with identical content under a fresh id, applied on a live
    ///      curve. The REGISTER and the CONTRACTUAL DEBT must be exactly where they were. The
    ///      reserve's STREAMED book is not exact by design: an amendment is a close, a close
    ///      settles the running segment onto the USDC grid, and the sub-unit remainder is an
    ///      explicit rounding loss pushed through the cascade (ACCRUAL_BUILD_LOG 2026-09-12,
    ///      "explicit rounding losses are checked against the actual curator, shared-reserve and
    ///      senior allocations"). Measured on this note: `deployedTo` fell by 664,011,072,000 wei
    ///      and the senior vault absorbed the rounding loss; `gross` rose by 239,039 wei from the
    ///      interpolation alignment; 2,624,999,999,333,598,868,896 wei of USDfr were issued, being
    ///      the senior and fee claim the book had already recognized for the closed segment, net
    ///      of that rounding burn. Every rounding movement is bounded by ONE native unit (1e12
    ///      wei) and can only go one way, and issuance can never exceed the recognized claim; a
    ///      wei beyond that, or in the wrong direction, is value created or destroyed by a
    ///      signature and is the "applied twice" finding.
    function _applyIdenticalAmendmentIsNeutral(
        uint256 id,
        ClaimBridge.Amendment memory a,
        ClaimBridge.Facility memory after1
    ) internal {
        IAccrualLifecycle.Debt memory debtBefore = reserves.accruedDebt(id);
        IContinuousAccrual.Snapshot memory snapBefore = reserves.accrualSnapshot();
        uint256 deployedBefore = reserves.deployedTo(id);
        uint256 vaultBefore = vault.totalAssets();
        uint256 roundingBefore = reserves.roundingLossUnabsorbed();
        uint256 supplyBefore = usdfr.totalSupply();

        bytes32 amendmentId2 = keccak256("ATK-CB-amendment-2");
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendmentId2, id, a)));
        vm.prank(ops);
        bridge.amendTerms(id, amendmentId2, a);

        // Register: exact.
        _assertFacilityEq(bridge.facility(id), after1, "second identical amendment drifted the register");

        // Contractual debt: exact.
        IAccrualLifecycle.Debt memory debtAfter = reserves.accruedDebt(id);
        assertEq(debtAfter.principal, debtBefore.principal, "identical re-amendment moved principal");
        assertEq(debtAfter.interest, debtBefore.interest, "identical re-amendment moved contractual interest");
        assertEq(debtAfter.balanceCeiling, debtBefore.balanceCeiling, "identical re-amendment moved the ceiling");
        assertEq(debtAfter.accruedThrough, debtBefore.accruedThrough, "identical re-amendment moved accruedThrough");
        assertEq(debtAfter.nextCapitalization, debtBefore.nextCapitalization, "identical re-amendment moved next due");
        assertEq(debtAfter.maturity, debtBefore.maturity, "identical re-amendment moved maturity");
        assertEq(debtAfter.active, debtBefore.active, "identical re-amendment changed active");

        // Streamed book: one-directional and under one native unit.
        IContinuousAccrual.Snapshot memory snapAfter = reserves.accrualSnapshot();
        assertGe(snapAfter.gross, snapBefore.gross, "identical re-amendment LOST recognized face");
        assertLt(snapAfter.gross - snapBefore.gross, SCALE, "close alignment created a whole native unit");
        uint256 deployedAfter = reserves.deployedTo(id);
        assertLe(deployedAfter, deployedBefore, "identical re-amendment INVENTED deployed face");
        assertLt(deployedBefore - deployedAfter, SCALE, "grid settlement dropped a whole native unit");
        assertLe(vault.totalAssets(), vaultBefore, "identical re-amendment PAID the senior vault");
        assertLt(vaultBefore - vault.totalAssets(), SCALE, "senior absorbed a whole native unit of rounding");
        assertLt(reserves.roundingLossUnabsorbed() - roundingBefore, SCALE, "unabsorbed rounding grew by a native unit");
        // Issuance: a close posts the segment and physically issues the claim the book had ALREADY
        // recognized (`unissued` falls by exactly what is minted, less the rounding burn). It must
        // never mint beyond that recognized claim, and backing must hold after the mint.
        uint256 issued = snapBefore.unissued - snapAfter.unissued;
        assertLe(
            usdfr.totalSupply() - supplyBefore, issued, "identical re-amendment MINTED beyond the recognized claim"
        );
        assertLt(issued - (usdfr.totalSupply() - supplyBefore), SCALE, "issuance short of the claim by a native unit");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing broken by an identical re-amendment");
    }

    /// @dev Contractual fixed-rate interest on the Actual/360 note, floored to the USDC grid the
    ///      accrual engine settles on (`AccrualMath.periodAmount`).
    function _gridInterest(uint256 principal, uint16 rateBps, uint256 secs) internal pure returns (uint256) {
        return principal * uint256(rateBps) * secs / (Config.BPS * 360 days) / SCALE * SCALE;
    }

    /// @dev A5: `amendTerms` must refuse with the exact not-attested error and leave the rate alone.
    function _refuseAmendment(uint256 id, bytes32 amendmentId, ClaimBridge.Amendment memory a) internal {
        uint16 rateBefore = bridge.facility(id).interestRateBps;
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, id));
        bridge.amendTerms(id, amendmentId, a);
        assertEq(bridge.facility(id).interestRateBps, rateBefore, "an unattested or replayed amendment re-priced");
    }

    /// @dev A5: the legitimate first application, with the event and every amendable and
    ///      non-amendable field checked, and the fact shown Consumed.
    function _applyAmendmentAndVerify(
        uint256 id,
        ClaimBridge.Facility memory before,
        bytes32 amendmentId,
        ClaimBridge.Amendment memory a,
        bytes32 payload
    ) internal {
        vm.expectEmit(true, true, true, true, address(bridge));
        emit ClaimBridge.TermsAmended(id, amendmentId, bridge.creditTermsHash(_amended(before, a)));
        vm.prank(ops);
        bridge.amendTerms(id, amendmentId, a);

        ClaimBridge.Facility memory after1 = bridge.facility(id);
        assertEq(after1.interestRateBps, a.interestRateBps, "rate amended");
        assertEq(after1.paymentScheduleHash, a.paymentScheduleHash, "schedule amended");
        assertEq(after1.principal, before.principal, "principal is not an amendable term");
        assertEq(after1.pik, before.pik, "pik is not an amendable term");
        assertEq(after1.fundingRecipient, before.fundingRecipient, "recipient is not an amendable term");
        assertEq(after1.offchainRef, before.offchainRef, "lien reference is not an amendable term");
        assertEq(after1.maturity, before.maturity, "maturity unchanged by this amendment");
        assertFalse(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.TermsAmended), "fact consumed");
        assertEq(
            uint256(oracle.factStatus(id, IAttestationOracle.AttestationKind.TermsAmended, payload)),
            uint256(IAttestationOracle.FactStatus.Consumed),
            "fact status Consumed"
        );
    }

    /// @dev A5: the same fact re-signed under a fresh nonce is refused at the oracle ledger.
    function _refuseResignedFact(uint256 id, bytes32 payload) internal {
        (IAttestationOracle.AttestationInput memory input, bytes[] memory sigs) =
            _signedBundle(id, IAttestationOracle.AttestationKind.TermsAmended, payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(id, IAttestationOracle.AttestationKind.TermsAmended, payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        oracle.attest(input, sigs);
        assertFalse(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.TermsAmended), "re-sign revived the fact");
    }

    /// @dev A5: an amendment attested for facility `id` does not apply to a second facility.
    function _refuseCrossFacilityAmendment(uint256 id, ClaimBridge.Amendment memory a, uint16 rateBefore) internal {
        uint256 id2 = _originateAndFund(PRINCIPAL);
        bytes32 amendmentId3 = keccak256("ATK-CB-amendment-3");
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendmentId3, id, a)));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsAmendmentNotAttested.selector, id2));
        bridge.amendTerms(id2, amendmentId3, a);
        assertEq(bridge.facility(id2).interestRateBps, rateBefore, "facility 2 re-priced by facility 1's fact");
    }

    /// @dev An amendment that keeps the facility's schedule and only re-prices it.
    function _amendmentFor(ClaimBridge.Facility memory f, uint16 rateBps, bytes32 scheduleHash)
        internal
        pure
        returns (ClaimBridge.Amendment memory)
    {
        return ClaimBridge.Amendment({
            interestRateBps: rateBps,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: f.nextPaymentDue,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: scheduleHash,
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0)
        });
    }

    /// @dev `a` with its maturity pushed out by `secs`, built as a fresh struct (a memory-to-memory
    ///      assignment would alias `a`).
    function _extendedBy(ClaimBridge.Amendment memory a, uint64 secs)
        internal
        pure
        returns (ClaimBridge.Amendment memory)
    {
        return ClaimBridge.Amendment({
            interestRateBps: a.interestRateBps,
            maturity: a.maturity + secs,
            paymentInterval: a.paymentInterval,
            nextPaymentDue: a.nextPaymentDue,
            rateType: a.rateType,
            dayCountConvention: a.dayCountConvention,
            renewable: a.renewable,
            paymentScheduleHash: a.paymentScheduleHash,
            rateIndexRef: a.rateIndexRef,
            renewalTermsHash: a.renewalTermsHash
        });
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5b: a SIGNED amendment cannot carry a facility outside the accrual envelope
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the amendment shape gates WITH the quorum's signature in hand, so a
    ///         refusal cannot ride on `Bridge_TermsAmendmentNotAttested` firing later in the
    ///         function. Every amendment below is attested for the facility it targets and
    ///         would apply if only the attestation mattered. A failure here means a signed
    ///         amendment extends a non-renewable note past its maturity, puts a live cash-pay
    ///         note on a 30/360 or floating basis the continuous engine cannot service (which
    ///         freezes it), sets a due date that has already passed, or moves a PIK note off
    ///         Actual/360: in each case 1,000,000e18 of deployed capital accruing on terms the
    ///         engine will mis-price or refuse to service.
    ///
    ///         Also pinned, because it is what a refused signature turns into: the refused fact
    ///         is left STANDING and unconsumed, and while it stands the oracle admits no
    ///         replacement TermsAmended fact for that facility (`Oracle_UnconsumedFact`), so a
    ///         wrongly signed amendment cannot be quietly superseded; governance revokes it and
    ///         the exact fact is tombstoned. The same signed shape with the one offending field
    ///         restored then applies, which proves the refusals were the envelope and not the
    ///         signature path.
    function test_atk_attestedAmendmentCannotLeaveTheAccrualEnvelope() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        uint256 id = _originateAndFund(PRINCIPAL);
        uint256 pid = _originateAndFundPik();
        _warp(7 days); // both curves are live, so an applied amendment would be a book close
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Facility memory pf = bridge.facility(pid);
        assertFalse(f.renewable, "precondition: the cash-pay note is non-renewable");
        assertTrue(pf.pik, "precondition: the second note is PIK");
        assertTrue(reserves.accrualSnapshot().enabled, "precondition: continuous accrual is enabled");

        bytes memory badFacility = abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector);
        bytes memory unsupported = abi.encodeWithSelector(ClaimBridge.Bridge_AccrualUnsupportedTerms.selector, id);

        // (a) maturity + 1 s on a non-renewable note, signed.
        ClaimBridge.Amendment memory a = _extendedBy(_amendmentFor(f, 1500, ENV_SCHEDULE), 1);
        bytes32 standing = _refuseSignedAmendment(id, keccak256("ATK-CB-env-extend"), a, badFacility, f, "extension");

        // While the refused fact stands no replacement can be signed for the facility, so the
        // bad signature is neither spent nor buried. Governance revokes it and it is tombstoned.
        a = _amendmentFor(f, 1500, ENV_SCHEDULE);
        a.dayCountConvention = ClaimBridge.DayCountConvention.Thirty360;
        _refuseSupersedingSignature(id, keccak256("ATK-CB-env-30360"), a, standing);
        _revokeStandingAmendment(id, standing);

        // (b) 30/360 on a continuous cash-pay note, signed.
        standing = _refuseSignedAmendment(id, keccak256("ATK-CB-env-30360"), a, unsupported, f, "30/360");
        _revokeStandingAmendment(id, standing);

        // (c) a floating rate with an index, signed.
        a = _amendmentFor(f, 1500, ENV_SCHEDULE);
        a.rateType = ClaimBridge.RateType.Variable;
        a.rateIndexRef = keccak256("ATK-CB-SOFR");
        standing = _refuseSignedAmendment(id, keccak256("ATK-CB-env-float"), a, unsupported, f, "floating");
        _revokeStandingAmendment(id, standing);

        // (d) a due date that is exactly now, signed: the schedule may not start in the past.
        a = _amendmentFor(f, 1500, ENV_SCHEDULE);
        a.nextPaymentDue = uint64(block.timestamp);
        standing = _refuseSignedAmendment(id, keccak256("ATK-CB-env-stale-due"), a, badFacility, f, "stale due date");
        _revokeStandingAmendment(id, standing);

        // (e) a PIK note moved to Actual/365, signed.
        a = _amendmentFor(pf, pf.interestRateBps, keccak256("ATK-CB-env-pik-schedule"));
        a.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
        _refuseSignedAmendment(pid, keccak256("ATK-CB-env-pik-365"), a, badFacility, pf, "PIK Actual/365");

        // Control: the same signed shape as (b), (c) and (d) with the offending field restored
        // applies to the cash-pay note, so nothing above was refused for want of a signature.
        a = _amendmentFor(f, 1500, ENV_SCHEDULE);
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(ENV_OK_ID, id, a)));
        vm.prank(ops);
        bridge.amendTerms(id, ENV_OK_ID, a);
        assertEq(bridge.facility(id).interestRateBps, 1500, "control amendment applied");
        assertEq(bridge.facility(id).maturity, f.maturity, "control amendment moved maturity");
        assertEq(bridge.facility(id).nextPaymentDue, f.nextPaymentDue, "control amendment moved the due date");
        assertEq(bridge.facility(pid).interestRateBps, pf.interestRateBps, "the PIK note was re-priced");
    }

    bytes32 private constant ENV_SCHEDULE = keccak256("ATK-CB-env-schedule");
    bytes32 private constant ENV_OK_ID = keccak256("ATK-CB-env-ok");

    /// @dev A5b: attests amendment `a` for facility `id`, submits it as ops and asserts the exact
    ///      refusal, the whole record untouched and the signed fact still Recorded (not spent).
    ///      Returns the attested payload so the caller can name the standing fact.
    function _refuseSignedAmendment(
        uint256 id,
        bytes32 amendmentId,
        ClaimBridge.Amendment memory a,
        bytes memory err,
        ClaimBridge.Facility memory before,
        string memory ctx
    ) internal returns (bytes32 payload) {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.TermsAmended;
        payload = keccak256(abi.encode(amendmentId, id, a));
        _attest(id, kind, payload);
        (bytes32 latest,, bool ok) = oracle.latestPayload(id, kind);
        assertTrue(ok && latest == payload, string.concat("precondition: signed amendment is live: ", ctx));

        vm.prank(ops);
        vm.expectRevert(err);
        bridge.amendTerms(id, amendmentId, a);

        _assertFacilityEq(bridge.facility(id), before, string.concat("signed amendment applied: ", ctx));
        assertEq(
            uint256(oracle.factStatus(id, kind, payload)),
            uint256(IAttestationOracle.FactStatus.Recorded),
            string.concat("refused amendment spent its signature: ", ctx)
        );
    }

    /// @dev A5b: a fresh 2-of-n bundle for a DIFFERENT amendment on the same facility is refused
    ///      at the oracle while the refused fact `standing` is still satisfied.
    function _refuseSupersedingSignature(
        uint256 id,
        bytes32 amendmentId,
        ClaimBridge.Amendment memory a,
        bytes32 standing
    ) internal {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.TermsAmended;
        (IAttestationOracle.AttestationInput memory input, bytes[] memory sigs) =
            _signedBundle(id, kind, keccak256(abi.encode(amendmentId, id, a)));
        vm.expectRevert(abi.encodeWithSelector(IAttestationOracle.Oracle_UnconsumedFact.selector, id, kind, standing));
        oracle.attest(input, sigs);
        (bytes32 latest,, bool ok) = oracle.latestPayload(id, kind);
        assertTrue(ok && latest == standing, "the standing fact was superseded");
    }

    /// @dev A5b: governance (ops retains DEFAULT_ADMIN on the oracle here) revokes the standing
    ///      refused amendment; the exact fact is tombstoned and the slot is free for a new one.
    function _revokeStandingAmendment(uint256 id, bytes32 standing) internal {
        IAttestationOracle.AttestationKind kind = IAttestationOracle.AttestationKind.TermsAmended;
        vm.prank(ops);
        oracle.revoke(id, kind);
        assertEq(
            uint256(oracle.factStatus(id, kind, standing)),
            uint256(IAttestationOracle.FactStatus.Revoked),
            "refused amendment not tombstoned by revoke"
        );
        assertFalse(oracle.isSatisfied(id, kind), "slot still satisfied after revoke");
    }

    /// @dev A PIK twin of `_originateAndFund` on this suite's base terms (FILM is a receivable
    ///      class, so PIK is admitted), attested at the PIK hash and funded at par.
    function _originateAndFundPik() internal returns (uint256 id) {
        id = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory t = _baseTerms(uint64(block.timestamp + 365 days));
        t.pik = true;
        bytes32 hPik = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, hPik);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, hPik);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, hPik);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, t);
        require(minted == id, "ATK: tokenId drift");
        vm.prank(ops);
        waterfall.fund(id, PRINCIPAL / SCALE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6a: the lifecycle state machine driven out of order by ops
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the strict lifecycle machine with the operator's own roles used in the
    ///         wrong order or against the wrong state. A failure here means a repayment settles
    ///         on an unfunded facility, a default is declared on a facility with no capital out,
    ///         a paused register still mints, a class limit or an inactive class still admits or
    ///         funds a facility, or an ACTIVE facility with 1,000,000e18 deployed is cancelled
    ///         and its NFT burned while the capital stays out.
    function test_atk_stateMachineRefusesOutOfOrderLifecycle() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);

        // Bind a real class limit first: 2m floor, 50% class share, so the class admits 1m.
        registry.setConcentrationFloor(2_000_000e18);
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        p.concentrationLimitBps = 5000;
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);

        (uint256 id, ClaimBridge.OriginationTerms memory base) = _originatePendingFilm();
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), PRINCIPAL, "precondition: 1m booked");

        // distribute before fund
        IWaterfallEngine.Payment memory pay = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: keccak256("ATK-CB-early-payment"),
            payer: borrower,
            interest: 1e18,
            principal: 0,
            nextPaymentDue: base.nextPaymentDue + base.paymentInterval
        });
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_NotDistributable.selector, id));
        waterfall.distribute(pay);

        // declare default on Pending
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotDefaultable.selector, id));
        defaultManager.declareDefault(id, keccak256("ATK-CB-early-default"));

        // amend on Pending
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: 1500,
            maturity: base.maturity,
            paymentInterval: base.paymentInterval,
            nextPaymentDue: base.nextPaymentDue,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("ATK-CB-early-amend"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0)
        });
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector));
        bridge.amendTerms(id, keccak256("ATK-CB-early-amendment"), a);

        // A second, over-limit facility is attested at the next id: 1.5m against a 1m class room.
        uint256 id2 = id + 1;
        uint256 big = 1_500_000e18;
        ClaimBridge.OriginationTerms memory bigTerms =
            _forkTerms(keccak256("ATK-CB-borrower-2"), STATE_GA, big, LTV, base.maturity, keccak256("ATK-CB-ref-2"));
        _attestFilmGate(
            id2, keccak256("ATK-CB-borrower-2"), STATE_GA, big, LTV, base.maturity, keccak256("ATK-CB-ref-2")
        );

        // originate while paused (guardian pause is an emergency stop on minting)
        bridge.pause();
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        bridge.originate(ops, bigTerms);
        bridge.unpause();

        // re-bind the accrual source as the admin (ops retains DEFAULT_ADMIN on this fixture):
        // the binding is permanent, whether the target is hostile or the same reserve again.
        assertTrue(bridge.hasRole(bytes32(0), ops), "precondition: ops holds DEFAULT_ADMIN on the bridge");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualAlreadyBound.selector));
        bridge.setAccrualReserve(carol);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AccrualAlreadyBound.selector));
        bridge.setAccrualReserve(address(reserves));
        assertEq(bridge.accrualReserve(), address(reserves), "accrual source re-bound by the admin");

        // originate over the exhausted class limit: would-be 2.5m against 50% of a 2.5m book
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                PRINCIPAL + big,
                uint256(5000)
            )
        );
        bridge.originate(ops, bigTerms);

        // originate on an inactive class
        p.active = false;
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ClassInactive.selector, Config.CLASS_FILM_TAX_CREDITS)
        );
        bridge.originate(ops, bigTerms);

        // fund a Pending facility whose class went inactive after it minted (M-01 re-check)
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimBridge.Bridge_ClassInactive.selector, Config.CLASS_FILM_TAX_CREDITS)
        );
        waterfall.fund(id, PRINCIPAL / SCALE);
        assertEq(reserves.deployedTo(id), 0, "funded on an inactive class");

        // Nothing above minted or moved capital.
        assertEq(bridge.totalOriginated(), id, "an out-of-order path minted");
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), PRINCIPAL, "class exposure moved");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending), "state moved");

        // Restore the class and fund legitimately.
        p.active = true;
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, p);
        vm.prank(ops);
        waterfall.fund(id, PRINCIPAL / SCALE);
        assertEq(reserves.deployedTo(id), PRINCIPAL, "control fund");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active), "control Active");

        // cancel an ACTIVE facility: the NFT and the capital must stay put
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_NotPending.selector, id));
        bridge.cancelPending(id);
        assertEq(bridge.ownerOf(id), ops, "NFT burned while 1,000,000e18 is deployed");
        assertEq(reserves.deployedTo(id), PRINCIPAL, "deployed principal changed by a refused cancel");
        assertEq(
            registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), PRINCIPAL, "exposure released by a refused cancel"
        );
        assertEq(
            uint256(bridge.facility(id).state),
            uint256(ClaimBridge.LoanState.Active),
            "state changed by a refused cancel"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6b: every role-gated entry point, called by carol
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the whole privileged surface of the register and of the two modules that
    ///         drive its state from the roleless attacker. A failure here means a state
    ///         transition, a due date, a cancellation, a pause, the mint-gate mask, the accrual
    ///         binding, an upgrade, a custody transfer, a funding, a default or an attestation
    ///         consumption is reachable without the role that guards it.
    function test_atk_privilegedSurfaceRejectsCarol() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        (uint256 id, ClaimBridge.OriginationTerms memory base) = _originatePendingFilm();
        bytes32 attested = bridge.creditTermsHash(base);

        vm.startPrank(carol);

        vm.expectRevert(_unauthorized(carol, Roles.CREDIT_ROLE));
        bridge.transitionState(id, ClaimBridge.LoanState.Active);

        vm.expectRevert(_unauthorized(carol, Roles.CREDIT_ROLE));
        bridge.setNextPaymentDue(id, base.nextPaymentDue + 1);

        vm.expectRevert(_unauthorized(carol, Roles.ORIGINATOR_ROLE));
        bridge.cancelPending(id);

        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: 1,
            maturity: base.maturity,
            paymentInterval: base.paymentInterval,
            nextPaymentDue: base.nextPaymentDue,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("ATK-CB-carol-amend"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0)
        });
        vm.expectRevert(_unauthorized(carol, Roles.ORIGINATOR_ROLE));
        bridge.amendTerms(id, keccak256("ATK-CB-carol-amendment"), a);

        vm.expectRevert(_unauthorized(carol, Roles.GUARDIAN_ROLE));
        bridge.pause();
        vm.expectRevert(_unauthorized(carol, Roles.GUARDIAN_ROLE));
        bridge.unpause();

        // Widening or narrowing the gate is timelocked governance (DEFAULT_ADMIN_ROLE == 0x00).
        vm.expectRevert(_unauthorized(carol, bytes32(0)));
        bridge.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, 1 << 2);
        vm.expectRevert(_unauthorized(carol, bytes32(0)));
        bridge.setAccrualReserve(carol);

        vm.expectRevert(_unauthorized(carol, Roles.UPGRADER_ROLE));
        bridge.upgradeToAndCall(carol, "");

        // Custody: the holder is ops; carol is neither holder, approved, nor governance.
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TransferRestricted.selector));
        bridge.transferFrom(ops, carol, id);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TransferRestricted.selector));
        bridge.safeTransferFrom(ops, carol, id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, carol));
        bridge.approve(carol, id);

        // The modules that drive the bridge's state are gated the same way.
        vm.expectRevert(_unauthorized(carol, Roles.SERVICER_ROLE));
        waterfall.fund(id, PRINCIPAL / SCALE);
        vm.expectRevert(_unauthorized(carol, Roles.SERVICER_ROLE));
        defaultManager.declareDefault(id, keccak256("ATK-CB-carol-default"));

        // Carol cannot spend or kill the gate's facts to strand the facility before funding.
        vm.expectRevert(_unauthorized(carol, Roles.CREDIT_ROLE));
        oracle.consume(id, IAttestationOracle.AttestationKind.CreditIssued);
        vm.expectRevert(_unauthorized(carol, bytes32(0)));
        oracle.revoke(id, IAttestationOracle.AttestationKind.CreditIssued);

        vm.stopPrank();

        // Untouched: same holder, same state, same gate, no capital out, no approval granted.
        assertEq(bridge.ownerOf(id), ops, "holder changed");
        assertEq(bridge.getApproved(id), address(0), "approval granted");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending), "state changed");
        assertEq(bridge.facility(id).nextPaymentDue, base.nextPaymentDue, "due date changed");
        assertEq(bridge.totalOriginated(), id, "register advanced");
        assertEq(bridge.requiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS), 7, "mint-gate mask changed");
        assertEq(bridge.accrualReserve(), address(reserves), "accrual reserve re-bound by carol");
        assertFalse(bridge.paused(), "paused by carol");
        assertTrue(oracle.isSatisfied(id, IAttestationOracle.AttestationKind.CreditIssued), "gate fact spent by carol");
        assertEq(
            uint256(oracle.factStatus(id, IAttestationOracle.AttestationKind.CreditIssued, attested)),
            uint256(IAttestationOracle.FactStatus.Recorded),
            "gate fact status changed by carol"
        );
        assertEq(reserves.deployedTo(id), 0, "capital deployed by carol");

        // The facility is still fundable by the legitimate path, so nothing carol did stranded it.
        vm.prank(ops);
        waterfall.fund(id, PRINCIPAL / SCALE);
        assertEq(reserves.deployedTo(id), PRINCIPAL, "control fund after carol's attempts");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6c: escrow cannot release on a stale schedule
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the funding gate with TIME, the one input no signature covers. A Pending
    ///         facility carries a first due date and a maturity signed at origination; the
    ///         operator funds it late, out of order with the schedule. `checkFundable` has two
    ///         time limbs (`Bridge_FacilityMatured` before `Bridge_BadFacility`) and both are
    ///         probed to the second: one second before the first due date the facility is
    ///         fundable, AT the due date it is not, one second before maturity it is still the
    ///         schedule limb, AT maturity the matured limb takes precedence. A failure here
    ///         means 1,000,000 USDC leaves the treasury into a facility whose first payment is
    ///         already overdue or whose paper has already matured, with the accrual book then
    ///         opened on a schedule that starts in the past.
    function test_atk_escrowCannotReleaseOnAStaleSchedule() public onFork {
        _mintFromUSDC(alice, 2_000_000e6); // liquidity is never the reason a fund fails here
        (uint256 id, ClaimBridge.OriginationTerms memory base) = _originatePendingFilm();
        uint256 idleBefore = reserves.idleUSDC();
        uint256 deployedBefore = reserves.deployedPrincipal();
        uint256 borrowerBefore = IERC20(USDC).balanceOf(borrower);
        uint256 classBefore = registry.classExposure(Config.CLASS_FILM_TAX_CREDITS);
        uint256 units = PRINCIPAL / SCALE;
        assertEq(classBefore, PRINCIPAL, "precondition: the Pending facility books its exposure at origination");

        // Fundable now, and still fundable one second before the first due date: the same view
        // `fund` consults, so a later refusal is the clock and nothing else.
        bridge.checkFundable(id);
        _warp(uint256(base.nextPaymentDue) - block.timestamp - 1);
        assertEq(block.timestamp, uint256(base.nextPaymentDue) - 1, "clock: one second before the first due date");
        bridge.checkFundable(id);

        // AT the first due date: the schedule is stale and the facility does not fund.
        _warp(1);
        assertEq(block.timestamp, uint256(base.nextPaymentDue), "clock: at the first due date");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector));
        waterfall.fund(id, units);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector));
        bridge.checkFundable(id);

        // Long past it, one second before maturity: still the schedule limb.
        _warp(uint256(base.maturity) - block.timestamp - 1);
        assertEq(block.timestamp, uint256(base.maturity) - 1, "clock: one second before maturity");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector));
        waterfall.fund(id, units);

        // AT maturity: the matured limb takes precedence over the schedule limb.
        _warp(1);
        assertEq(block.timestamp, uint256(base.maturity), "clock: at maturity");
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_FacilityMatured.selector, id));
        waterfall.fund(id, units);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_FacilityMatured.selector, id));
        bridge.checkFundable(id);

        // carol on the matured id is stopped at the door, not by the clock.
        vm.prank(carol);
        vm.expectRevert(_unauthorized(carol, Roles.SERVICER_ROLE));
        waterfall.fund(id, units);

        // No capital left, no state moved, the NFT still stands Pending.
        assertEq(reserves.deployedTo(id), 0, "capital deployed on a stale schedule");
        assertEq(reserves.deployedPrincipal(), deployedBefore, "deployed principal moved on a stale schedule");
        assertEq(reserves.idleUSDC(), idleBefore, "idle USDC left the treasury on a stale schedule");
        assertEq(IERC20(USDC).balanceOf(borrower), borrowerBefore, "the recipient was paid on a stale schedule");
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Pending), "state moved");
        assertEq(bridge.ownerOf(id), ops, "holder changed");
        assertTrue(reserves.accrualSnapshot().enabled, "continuous accrual switched off by the clock");

        // The stranded position is not a dead weight on the book: the originator retires it
        // (AUDIT FIX M-02) and the exposure it reserved at origination is released in full.
        vm.prank(ops);
        bridge.cancelPending(id);
        assertEq(
            registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), classBefore - PRINCIPAL, "exposure not released"
        );
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        bridge.ownerOf(id);
        assertEq(reserves.deployedTo(id), 0, "cancel deployed capital");
        assertEq(reserves.idleUSDC(), idleBefore, "cancel moved idle USDC");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A7: the terms-hash preimage binds every field, pik included
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the commitment itself. `creditTermsHash` is the single function attester
    ///         tooling and the mint gate derive the commitment from; if any field falls out of
    ///         its preimage, a quorum signature for one facility authorizes every facility that
    ///         differs only in that field. `pik` is the field most recently added to the
    ///         preimage (2026-09-08); before that, any address could force PIK accounting onto a
    ///         cash-pay book. A failure here means two different deals share one signature.
    function test_atk_termsHashBindsEveryFieldIncludingPik() public onFork {
        uint64 maturity = uint64(block.timestamp + 365 days);
        ClaimBridge.OriginationTerms memory base = _baseTerms(maturity);
        bytes32 h = bridge.creditTermsHash(base);

        // The commitment is the plain ABI encoding of the whole struct, one word per field.
        assertEq(h, keccak256(abi.encode(base)), "commitment is not the ABI encoding of the struct");
        assertEq(abi.encode(base).length, TERMS_FIELD_COUNT * 32, "OriginationTerms field count changed");

        // Every single-field toggle yields a hash distinct from the base AND from every other
        // toggle. Whether the toggle reaches the on-chain gate is A1's concern, not this loop's.
        bytes32[] memory seen = new bytes32[](TERMS_FIELD_COUNT + 1);
        seen[0] = h;
        for (uint256 i = 0; i < TERMS_FIELD_COUNT; ++i) {
            (ClaimBridge.OriginationTerms memory t,, string memory name) = _diverge(base, i);
            bytes32 h2 = bridge.creditTermsHash(t);
            assertTrue(h2 != h, string.concat("preimage does not bind field: ", name));
            for (uint256 j = 1; j <= i; ++j) {
                assertTrue(h2 != seen[j], string.concat("two field toggles collide: ", name));
            }
            seen[i + 1] = h2;
        }

        // pik specifically: toggling it alone moves the hash, and the on-chain gate reads the
        // same bit. Attest the PIK hash; the cash-pay twin is refused; the PIK terms mint.
        uint256 id = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory pikTerms = _copy(base);
        pikTerms.pik = true;
        bytes32 hPik = bridge.creditTermsHash(pikTerms);
        assertTrue(hPik != h, "pik is not in the preimage");

        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, hPik);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, hPik);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, hPik);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, id, h, hPik));
        bridge.originate(ops, base);
        assertEq(bridge.totalOriginated(), id - 1, "cash-pay terms minted under a PIK signature");

        vm.expectEmit(true, true, true, true, address(bridge));
        emit ClaimBridge.Originated(id, Config.CLASS_FILM_TAX_CREDITS, BORROWER, hPik);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, pikTerms);
        assertEq(minted, id, "PIK terms mint under the PIK signature");
        assertTrue(bridge.facility(id).pik, "stored facility is PIK");

        // And the reverse: a cash-pay signature does not mint the PIK twin at the next id.
        uint256 id2 = id + 1;
        _attestFilmGate(id2, BORROWER, STATE_GA, PRINCIPAL, LTV, maturity, REF);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, id2, hPik, h));
        bridge.originate(ops, pikTerms);
        assertEq(bridge.totalOriginated(), id, "PIK terms minted under a cash-pay signature");
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev The suite's FILM terms: one obligor, one state, one lien, so every test attests and
    ///      originates the same shape and divergences are visible field by field.
    function _baseTerms(uint64 maturity) internal view returns (ClaimBridge.OriginationTerms memory) {
        return _forkTerms(BORROWER, STATE_GA, PRINCIPAL, LTV, maturity, REF);
    }

    /// @dev Attests the FILM gate for the base terms at the next id and mints, leaving the
    ///      facility PENDING so the funding path can be attacked independently.
    function _originatePendingFilm() internal returns (uint256 id, ClaimBridge.OriginationTerms memory base) {
        id = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        base = _baseTerms(maturity);
        _attestFilmGate(id, BORROWER, STATE_GA, PRINCIPAL, LTV, maturity, REF);
        vm.prank(ops);
        uint256 minted = bridge.originate(ops, base);
        require(minted == id, "ATK: tokenId drift");
    }

    /// @dev Explicit field-by-field copy. A memory-to-memory struct assignment in Solidity
    ///      aliases the same object, which would make every "single-field" divergence cumulative.
    function _copy(ClaimBridge.OriginationTerms memory s) internal pure returns (ClaimBridge.OriginationTerms memory) {
        return ClaimBridge.OriginationTerms({
            classId: s.classId,
            borrowerId: s.borrowerId,
            stateId: s.stateId,
            principal: s.principal,
            ltvBps: s.ltvBps,
            interestRateBps: s.interestRateBps,
            maturity: s.maturity,
            fundingRecipient: s.fundingRecipient,
            paymentInterval: s.paymentInterval,
            nextPaymentDue: s.nextPaymentDue,
            rateType: s.rateType,
            dayCountConvention: s.dayCountConvention,
            renewable: s.renewable,
            paymentScheduleHash: s.paymentScheduleHash,
            rateIndexRef: s.rateIndexRef,
            renewalTermsHash: s.renewalTermsHash,
            offchainRef: s.offchainRef,
            pik: s.pik
        });
    }

    /// @dev Field `i` of `OriginationTerms`, moved by the smallest meaningful step. `reachesGate`
    ///      says whether the single-field form survives the shape checks in `_originate` and is
    ///      refused BY THE ATTESTATION COMPARISON (true) or by `Bridge_BadFacility` first (false).
    function _diverge(ClaimBridge.OriginationTerms memory base, uint256 i)
        internal
        view
        returns (ClaimBridge.OriginationTerms memory t, bool reachesGate, string memory name)
    {
        t = _copy(base);
        reachesGate = _reachesGate(i);
        if (i == 0) {
            t.classId = Config.CLASS_RENEWABLE_ENERGY; // a non-film class with a state key is malformed
            name = "classId";
        } else if (i == 1) {
            t.borrowerId = keccak256("ATK-CB-other-borrower");
            name = "borrowerId";
        } else if (i == 2) {
            t.stateId = keccak256("US-NY");
            name = "stateId";
        } else if (i == 3) {
            t.principal = base.principal + 1; // one wei
            name = "principal";
        } else if (i == 4) {
            t.ltvBps = base.ltvBps + 1;
            name = "ltvBps";
        } else if (i == 5) {
            t.interestRateBps = base.interestRateBps + 1;
            name = "interestRateBps";
        } else if (i == 6) {
            t.maturity = base.maturity + 1; // one second
            name = "maturity";
        } else if (i == 7) {
            t.fundingRecipient = carol; // the attacker redirects the draw
            name = "fundingRecipient";
        } else if (i == 8) {
            t.paymentInterval = base.paymentInterval + 1;
            name = "paymentInterval";
        } else if (i == 9) {
            t.nextPaymentDue = base.nextPaymentDue + 1;
            name = "nextPaymentDue";
        } else if (i == 10) {
            t.rateType = ClaimBridge.RateType.Variable; // variable without an index is malformed
            name = "rateType";
        } else if (i == 11) {
            t.dayCountConvention = ClaimBridge.DayCountConvention.Actual365;
            name = "dayCountConvention";
        } else if (i == 12) {
            t.renewable = true; // renewable without a renewal hash is malformed
            name = "renewable";
        } else if (i == 13) {
            t.paymentScheduleHash = keccak256("ATK-CB-other-schedule");
            name = "paymentScheduleHash";
        } else if (i == 14) {
            t.rateIndexRef = keccak256("ATK-CB-SOFR"); // fixed with an index is malformed
            name = "rateIndexRef";
        } else if (i == 15) {
            t.renewalTermsHash = keccak256("ATK-CB-renewal"); // non-renewable with a hash is malformed
            name = "renewalTermsHash";
        } else if (i == 16) {
            t.offchainRef = keccak256("ATK-CB-other-ref");
            name = "offchainRef";
        } else if (i == 17) {
            t.pik = true;
            name = "pik";
        } else {
            revert("ATK: field index out of range");
        }
    }

    /// @dev Which single-field divergences pass `_originate`'s shape checks and are refused by the
    ///      attestation comparison. Fields 0, 10, 12, 14 and 15 are caught by `Bridge_BadFacility`
    ///      first because the single-field form is internally inconsistent; A1 covers those at
    ///      the gate in their consistent two-field forms.
    function _reachesGate(uint256 i) internal pure returns (bool) {
        return !(i == 0 || i == 10 || i == 12 || i == 14 || i == 15);
    }

    /// @dev One A1 iteration: originate the divergent terms and assert the exact refusal.
    function _attackDivergentField(uint256 id, ClaimBridge.OriginationTerms memory base, bytes32 attested, uint256 i)
        internal
    {
        (ClaimBridge.OriginationTerms memory t, bool reachesGate, string memory name) = _diverge(base, i);
        if (reachesGate) {
            _expectTermsNotAttested(id, t, attested, name);
        } else {
            vm.prank(ops);
            vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadFacility.selector));
            bridge.originate(ops, t);
            assertEq(bridge.totalOriginated(), id - 1, string.concat("minted on malformed divergent field: ", name));
        }
    }

    /// @dev Originates `t` at `id` where the gate is attested for `attested` and asserts the
    ///      exact `Bridge_TermsNotAttested(id, hash(t), attested)` refusal and no mint.
    function _expectTermsNotAttested(
        uint256 id,
        ClaimBridge.OriginationTerms memory t,
        bytes32 attested,
        string memory name
    ) internal {
        bytes32 h2 = bridge.creditTermsHash(t);
        assertTrue(h2 != attested, string.concat("preimage does not bind field: ", name));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_TermsNotAttested.selector, id, h2, attested));
        bridge.originate(ops, t);
        assertEq(bridge.totalOriginated(), id - 1, string.concat("minted on divergent field: ", name));
    }

    /// @dev The origination terms a facility would carry after amendment `a`, so the emitted
    ///      `TermsAmended.termsHash` can be checked against the public commitment function.
    function _amended(ClaimBridge.Facility memory f, ClaimBridge.Amendment memory a)
        internal
        pure
        returns (ClaimBridge.OriginationTerms memory)
    {
        return ClaimBridge.OriginationTerms({
            classId: f.classId,
            borrowerId: f.borrowerId,
            stateId: f.stateId,
            principal: f.principal,
            ltvBps: f.ltvBps,
            interestRateBps: a.interestRateBps,
            maturity: a.maturity,
            fundingRecipient: f.fundingRecipient,
            paymentInterval: a.paymentInterval,
            nextPaymentDue: a.nextPaymentDue,
            rateType: a.rateType,
            dayCountConvention: a.dayCountConvention,
            renewable: a.renewable,
            paymentScheduleHash: a.paymentScheduleHash,
            rateIndexRef: a.rateIndexRef,
            renewalTermsHash: a.renewalTermsHash,
            offchainRef: f.offchainRef,
            pik: f.pik
        });
    }

    /// @dev Whole-record equality, field by field, so a drift anywhere names the field.
    function _assertFacilityEq(ClaimBridge.Facility memory x, ClaimBridge.Facility memory y, string memory ctx)
        internal
        pure
    {
        assertEq(x.classId, y.classId, string.concat(ctx, ": classId"));
        assertEq(x.borrowerId, y.borrowerId, string.concat(ctx, ": borrowerId"));
        assertEq(x.stateId, y.stateId, string.concat(ctx, ": stateId"));
        assertEq(x.principal, y.principal, string.concat(ctx, ": principal"));
        assertEq(x.ltvBps, y.ltvBps, string.concat(ctx, ": ltvBps"));
        assertEq(x.interestRateBps, y.interestRateBps, string.concat(ctx, ": interestRateBps"));
        assertEq(x.maturity, y.maturity, string.concat(ctx, ": maturity"));
        assertEq(x.fundingRecipient, y.fundingRecipient, string.concat(ctx, ": fundingRecipient"));
        assertEq(x.paymentInterval, y.paymentInterval, string.concat(ctx, ": paymentInterval"));
        assertEq(x.nextPaymentDue, y.nextPaymentDue, string.concat(ctx, ": nextPaymentDue"));
        assertEq(uint256(x.rateType), uint256(y.rateType), string.concat(ctx, ": rateType"));
        assertEq(uint256(x.dayCountConvention), uint256(y.dayCountConvention), string.concat(ctx, ": dayCount"));
        assertEq(x.renewable, y.renewable, string.concat(ctx, ": renewable"));
        assertEq(x.paymentScheduleHash, y.paymentScheduleHash, string.concat(ctx, ": paymentScheduleHash"));
        assertEq(x.rateIndexRef, y.rateIndexRef, string.concat(ctx, ": rateIndexRef"));
        assertEq(x.renewalTermsHash, y.renewalTermsHash, string.concat(ctx, ": renewalTermsHash"));
        assertEq(x.offchainRef, y.offchainRef, string.concat(ctx, ": offchainRef"));
        assertEq(uint256(x.state), uint256(y.state), string.concat(ctx, ": state"));
        assertEq(x.pik, y.pik, string.concat(ctx, ": pik"));
    }

    /// @dev A real 2-of-n bundle that is BUILT but not relayed, so a test can bind
    ///      `vm.expectRevert` to `oracle.attest` itself (the fixture's `_attest` makes a view
    ///      call first, which would absorb the expectation).
    function _signedBundle(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload)
        internal
        returns (IAttestationOracle.AttestationInput memory a, bytes[] memory sigs)
    {
        a = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 1 hours),
            nonce: ++attestationNonce
        });
        bytes32 digest = oracle.attestationDigest(a);
        (uint256 lo, uint256 hi) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
        sigs = new bytes[](2);
        sigs[0] = _sig(lo, digest);
        sigs[1] = _sig(hi, digest);
    }

    function _sig(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }
}
