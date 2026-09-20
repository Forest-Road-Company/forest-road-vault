// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ReserveAccrualLib} from "../../src/libraries/ReserveAccrualLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_AttestationOracleFork: adversarial attacks on the AttestationOracle, the trust root
///        of the NFT mint gate and of every value-bearing fact, against the FULL protocol on a
///        pinned mainnet fork with REAL USDC.
///
/// @notice This suite does not document the oracle, it tries to BREAK the invariants it
///         underwrites (CLAUDE.md 1.3):
///           I2. value conservation in the waterfall: one attested receipt authorizes exactly one
///               distribution, under any re-signing and any ordering of receipts;
///           I4. NFT mint gate: a Loan NFT cannot mint unless every required attestation is
///               satisfied, so no quorum means no fact and an unset threshold means no fact;
///           I8. access control: no privileged oracle action is reachable by an unauthorized
///               role in any state;
///         together with the two replay properties those rest on: a superseded valuation can never
///         come back (H-02) and a spent or superseded fact can never be re-realised (C4-01).
///
///         The attacker is carol: not KYC'd, holding no protocol role, funded with real USDC. She
///         relays bundles, because `attest` is a permissionless relay by design and the signatures
///         are the authority, so every attack below is what a hostile relayer holding previously
///         signed bundles, or a duplicate signing of the same event, can actually reach. `ops` is
///         used only to reach a legitimate state; the attack itself is always made by carol.
///
///         Attacks attempted (a blocked attack asserts the exact custom error AND the untouched
///         state; a successful one would assert the violated quantity in money):
///           A1. FRESH-NONCE REPLAY of a consumed PaymentReceived, both while the record slot
///               still holds it and after a later receipt has superseded it, then a second spend
///               through the real waterfall: I2.
///           A2. SUPERSEDED VALUATION: the pre-markdown mark re-signed under a fresh nonce at its
///               original, an intermediate and the equal observation time, the old signatures over
///               a struct with a newer asOf, and the byte-identical bundle, each followed by an
///               attempt to clear a live margin call off it: H-02.
///           A3. QUORUM BYPASS on a 2-of-n kind, eight malformed bundles, then a spend through
///               the waterfall: I2 / I4.
///           A4. THRESHOLD UNSET: a kind whose threshold slot is zero (the state an
///               implementation-only proxy upgrade leaves for a newly added kind), zero-, one- and
///               two-signature bundles, and the mint gate behind it: I4.
///           A5. PAUSE AND ROLE SURFACE: every privileged entry point from carol, and the
///               guardian pause halting relay but not consumption: I8.
///           A6. UNCONSUMED-FACT DISCIPLINE: a second receipt cannot overwrite a standing one
///               before it is spent, and becomes attestable exactly after: I2.
///           A7. ACCRUAL OPENING (kind 9): recordable only at 2-of-n, consumable only by the
///               migration path (admin-gated, and closed on an enabled book), un-re-recordable
///               under a fresh nonce while standing and after a governance revoke (C4-02), plus
///               the mainnet-mirror state where the kind's threshold slot is unset after an upgrade.
contract ATK_AttestationOracleForkTest is ForkLifecycleFixture {
    /// @dev A key that is deliberately NOT in the attester set.
    uint256 private constant PK_OUTSIDER = 0xDEADBEEF;
    /// @dev secp256k1 group order and its half, for the high-s malleation in A3.
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 private constant SECP256K1_HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    /// @dev `AttestationOracle.ORACLE_STORAGE_LOCATION`; `thresholds` is the second field of the
    ///      namespaced struct, so its mapping lives at base + 1.
    bytes32 private constant ORACLE_STORAGE_LOCATION =
        0xac9508c5303c175f6440d43a5e3eadcf5afa63ca3c359d94d58c5e5919cebf00;
    /// @dev `ReserveMigrationLib.OPENING_TYPEHASH`, so the A7 payload has the consumer's shape.
    bytes32 private constant OPENING_TYPEHASH = keccak256("AccrualOpening(bytes32 frozenRecord,bytes32 opening)");

    uint256 private _nonceCounter;

    /// @dev One attested repayment receipt: the exact `Payment` the servicer distributes, the
    ///      payload the quorum signs over it, and the USDC leg that must land in the treasury.
    struct AttestedReceipt {
        IWaterfallEngine.Payment payment;
        bytes32 payload;
        uint256 stableAmount;
    }

    /// @dev The four balances a replay would have to move to be worth anything.
    struct MoneySnapshot {
        uint256 treasuryUsdc;
        uint256 vaultUsdfr;
        uint256 supply;
        uint256 deployed;
    }

    // ─────────────────────────────────────────────────────────────────────
    // A1: I2. A spent receipt re-signed under a fresh nonce cannot be spent twice
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks I2 through the C4-01 fact ledger. The attacker holds the same real-world
    ///         receipt signed a second time by the quorum under a fresh nonce (a duplicate signing,
    ///         or a relayer who asked twice). If the oracle accepted it, `WaterfallEngine.distribute`
    ///         would route one coupon of interest to the senior vault twice: the second distribution
    ///         mints yield against cash that never arrived, and the backing invariant breaks by the
    ///         full interest leg. Driven in both reachable states: while the record slot still holds
    ///         the receipt (the legacy shadow guard also sees this) and after a later receipt has
    ///         superseded the slot (only the fact ledger sees this).
    function test_atk_freshNonceReplayOfASpentReceiptCannotBeSpentTwice() public onFork {
        uint256 tokenId = _fundedFilm(1_000_000e18);

        // Receipt 1: one earned coupon, relayed by carol (a genuine bundle relays from anyone).
        _warp(30 days);
        AttestedReceipt memory r1 =
            _receipt(tokenId, keccak256("atk-a1-receipt-1"), _couponDue(tokenId), 0, _nextDue(tokenId));
        assertGt(r1.stableAmount, 0, "precondition: a coupon has accrued");
        IAttestationOracle.AttestationInput memory a = _paymentInput(tokenId, r1.payload);
        _relay(a, _quorum(a));
        _distribute(r1);
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r1.payload,
            IAttestationOracle.FactStatus.Consumed,
            "receipt 1 spent once"
        );

        // ATTACK 1: the identical economic fact under a fresh nonce, record slot still holding it
        // (the legacy shadow guard also sees this state).
        _expectSpentReceiptReplayRefused(tokenId, r1.payload, oracle.attestationDigest(a));
        _assertSlot(tokenId, r1.payload, false, "receipt 1 still occupies the slot, spent");

        // Receipt 2 legitimately supersedes the record slot. From here receipt 1 exists ONLY in the
        // fact ledger; the slot holds receipt 2.
        _warp(30 days);
        AttestedReceipt memory r2 =
            _receipt(tokenId, keccak256("atk-a1-receipt-2"), _couponDue(tokenId), 0, _nextDue(tokenId));
        a = _paymentInput(tokenId, r2.payload);
        _relay(a, _quorum(a));
        _distribute(r2);
        _assertSlot(tokenId, r2.payload, false, "the record slot now holds receipt 2, spent");
        MoneySnapshot memory before = _snapshot(tokenId);

        // ATTACK 2: receipt 1 re-signed under a fresh nonce while SUPERSEDED. The shadow guard is
        // blind here (slot payload != receipt 1); only the primary ledger guard stands between the
        // attacker and a second coupon.
        _expectSpentReceiptReplayRefused(tokenId, r1.payload, bytes32(0));
        _assertSlot(tokenId, r2.payload, false, "the slot still holds receipt 2, spent");

        // The second spend of receipt 1 through the real consumer: refused for the servicer, and
        // not even reachable for the attacker.
        _fundBorrowerFor(r1);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId));
        waterfall.distribute(r1.payment);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        waterfall.distribute(r1.payment);

        // Not a wei moved: the coupon was routed exactly once.
        _assertUnmoved(tokenId, before);
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2: H-02. A superseded valuation cannot come back to clear a margin call
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the H-02 watermark from the position of a hostile relayer holding the
    ///         pre-markdown mark. After a legitimate markdown puts a 400,000e18 digital-asset
    ///         facility into margin call, carol tries every shape of the old 1,000,000e18 mark: the
    ///         byte-identical bundle, a fresh-nonce re-signing at its original observation time, at
    ///         an intermediate time, at the equal time, and the old signatures over a struct with a
    ///         newer asOf. A single acceptance lets `clearMarginCall`, which is permissionless, lift
    ///         the call off a disowned number: the cure window closes on a facility whose collateral
    ///         covers 60% of what the oracle would say, and the liquidation rung is never reached.
    function test_atk_supersededValuationCannotClearAMarginCall() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 id = bridge.totalOriginated() + 1;
        uint64 t1 = uint64(block.timestamp);
        (IAttestationOracle.AttestationInput memory m1, bytes[] memory s1) = _originateFundedDa(id, 1_000_000e18);

        // Legitimate markdown one hour later: 600,000e18 against ~400,000e18 outstanding.
        _warp(1 hours);
        uint64 t2 = uint64(block.timestamp);
        _attestAt(id, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(600_000e18)), t2);
        assertEq(oracle.valuationWatermark(id), t2, "watermark advanced to the markdown");
        (uint256 ltvAtCall,) = defaultManager.currentLtvBps(id);
        assertGe(ltvAtCall, 6500, "precondition: the markdown breaches the margin-call rung");
        defaultManager.marginCall(id);
        uint64 deadline = defaultManager.cureDeadline(id);
        assertGt(deadline, 0, "precondition: a margin call stands");

        // ATTACK (a): the byte-identical pre-markdown bundle.
        _expectRelayRevert(
            m1,
            s1,
            abi.encodeWithSelector(IAttestationOracle.Oracle_DigestAlreadyUsed.selector, oracle.attestationDigest(m1))
        );
        // ATTACK (b): re-signed under a fresh nonce at its original observation time.
        _expectStaleValuation(id, 1_000_000e18, t1, t2);
        // ATTACK (c): re-signed at an observation time between the two marks.
        _expectStaleValuation(id, 1_000_000e18, t2 - 1, t2);
        // ATTACK (d): re-signed at exactly the markdown's observation time (strictness).
        _expectStaleValuation(id, 1_000_000e18, t2, t2);
        // ATTACK (e): the OLD signatures over the same struct with a newer asOf. `asOf` is inside
        // the digest, so the signatures recover two strangers and the first is refused by name.
        _warp(1);
        _expectForgedAsOfRefused(m1, s1);

        // The consumer reads the markdown, never the replay, and the attacker cannot clear the call.
        (uint256 value, uint64 asOf) = oracle.latestValuation(id);
        assertEq(value, 600_000e18, "the live mark is the markdown");
        assertEq(asOf, t2, "at the markdown's observation time");
        assertEq(oracle.valuationWatermark(id), t2, "the watermark never moved");
        (uint256 ltvNow,) = defaultManager.currentLtvBps(id);
        assertGe(ltvNow, 6500, "still in breach off the markdown");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_ThresholdNotBreached.selector, id, ltvNow, uint256(6500)
            )
        );
        defaultManager.clearMarginCall(id);
        assertEq(defaultManager.cureDeadline(id), deadline, "the margin call still stands");

        // Design boundary (ADR-0007): the ONLY way the old value returns is a fresh quorum over a
        // strictly newer observation, which the attacker does not hold. That is a new mark, not a
        // replay, and it clears the call on its own merits.
        uint64 t3 = uint64(block.timestamp);
        assertGt(t3, t2, "a strictly newer observation time");
        IAttestationOracle.AttestationInput memory m3 = _valuationInput(id, 1_000_000e18, t3);
        _relay(m3, _quorum(m3));
        (value, asOf) = oracle.latestValuation(id);
        assertEq(value, 1_000_000e18, "a fresh quorum installs a new mark at the old value");
        assertEq(asOf, t3, "at the new observation time");
        assertEq(oracle.valuationWatermark(id), t3, "and the watermark follows it");
        vm.prank(carol);
        defaultManager.clearMarginCall(id);
        assertEq(defaultManager.cureDeadline(id), 0, "cleared on a genuine fresh mark, not on a replay");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3: I2 / I4. No malformed bundle reaches a 2-of-n fact
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the quorum on PaymentReceived (2-of-n) with a real, spendable coupon
    ///         payload so a bypass would be worth exactly one coupon of senior yield. Eight
    ///         shapes: one valid signature; two from the same key; two valid in descending order;
    ///         one valid plus one from a non-attester; a valid pair over an expired bundle; a
    ///         future asOf; signatures over another facility's digest; and a high-s malleated
    ///         signature. Each must revert with its exact error, record nothing, and burn nothing,
    ///         and the servicer must then be unable to distribute. Finally the true quorum must
    ///         still land, proving the refusals poisoned neither the digest nor the fact key.
    function test_atk_quorumBypassBundlesRecordNothingAndSpendNothing() public onFork {
        uint256 tokenId = _fundedFilm(1_000_000e18);
        _warp(30 days);
        AttestedReceipt memory r =
            _receipt(tokenId, keccak256("atk-a3-receipt"), _couponDue(tokenId), 0, _nextDue(tokenId));
        IAttestationOracle.AttestationInput memory a = _paymentInput(tokenId, r.payload);
        bytes32 d = oracle.attestationDigest(a);

        _bypassSignatureShapes(a, d);
        _bypassStructShapes(a, r.payload);

        // Nothing stands, so the servicer cannot spend the coupon.
        _assertUnrecorded(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, r.payload, d);
        _fundBorrowerFor(r);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId));
        waterfall.distribute(r.payment);

        // The genuine quorum still lands on the very same struct: no refusal burned the digest or
        // poisoned the fact key (the R17-01 correction: the revert is the protection).
        uint256 treasuryUsdc = IERC20(USDC).balanceOf(address(reserves));
        _relay(a, _quorum(a));
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r.payload,
            IAttestationOracle.FactStatus.Recorded,
            "true quorum recorded"
        );
        _distribute(r);
        assertEq(
            IERC20(USDC).balanceOf(address(reserves)) - treasuryUsdc,
            r.stableAmount,
            "exactly one coupon's cash reached the treasury"
        );
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r.payload,
            IAttestationOracle.FactStatus.Consumed,
            "spent exactly once"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // A4: I4. An unset threshold records nothing and closes the mint gate
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the mint gate through a kind whose threshold slot is zero. The admin path
    ///         refuses to produce that state (`setThreshold(kind, 0)` and the 2-of-n floor both
    ///         revert `Oracle_BadThreshold`), so it is reached the way it is reached in life: an
    ///         implementation-only proxy upgrade that adds a kind leaves its slot uninitialised.
    ///         With CreditIssued unset, zero-, one- and two-signature bundles must all be refused
    ///         (a fact recordable with zero signatures would let anyone mint a Loan NFT and draw
    ///         its principal), and `originate` must fail closed on the missing terms quorum. Facts
    ///         recorded BEFORE the slot was cleared still satisfy the gate: thresholds govern
    ///         submission, not standing truth, and that boundary is pinned here too.
    function test_atk_unsetThresholdRecordsNothingAndClosesTheMintGate() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        uint256 idA = bridge.totalOriginated() + 1;
        uint256 idB = idA + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        ClaimBridge.OriginationTerms memory termsA = _forkTerms(
            keccak256("ATK-A4-BORROWER-A"), keccak256("US-GA"), 500_000e18, 7500, maturity, keccak256("a4-a")
        );
        ClaimBridge.OriginationTerms memory termsB = _forkTerms(
            keccak256("ATK-A4-BORROWER-B"), keccak256("US-NY"), 500_000e18, 7500, maturity, keccak256("a4-b")
        );

        // Facility A's whole gate is attested while every threshold is still seated.
        _attestFilmGate(
            idA, keccak256("ATK-A4-BORROWER-A"), keccak256("US-GA"), 500_000e18, 7500, maturity, keccak256("a4-a")
        );

        // The admin path cannot create the unset state, from carol or from governance.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        oracle.setThreshold(IAttestationOracle.AttestationKind.CreditIssued, 0);
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.setThreshold(IAttestationOracle.AttestationKind.CreditIssued, 0);
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.setThreshold(IAttestationOracle.AttestationKind.CreditIssued, 1);
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.CreditIssued), 2, "seated at the floor");

        // Reach the unset state directly in the proxy's namespaced storage.
        _clearThresholdSlot(IAttestationOracle.AttestationKind.CreditIssued);
        assertEq(
            oracle.threshold(IAttestationOracle.AttestationKind.CreditIssued), 0, "CreditIssued threshold is unset"
        );

        // ATTACK: facility B's terms quorum with zero, one and two signatures.
        bytes32 termsHashB = bridge.creditTermsHash(termsB);
        IAttestationOracle.AttestationInput memory b =
            _input(idB, IAttestationOracle.AttestationKind.CreditIssued, termsHashB, uint64(block.timestamp), 1 hours);
        bytes32 dB = oracle.attestationDigest(b);
        _expectRelayRevert(b, new bytes[](0), abi.encodeWithSelector(IAttestationOracle.Oracle_BadThreshold.selector));
        _expectRelayRevert(b, _one(PK1, dB), abi.encodeWithSelector(IAttestationOracle.Oracle_BadThreshold.selector));
        _expectRelayRevert(b, _quorum(b), abi.encodeWithSelector(IAttestationOracle.Oracle_BadThreshold.selector));
        _assertUnrecorded(idB, IAttestationOracle.AttestationKind.CreditIssued, termsHashB, dB);

        // The gate behind it. Facility A (standing facts) mints; facility B, whose documentary
        // 1-of-n facts are unaffected, fails closed on the terms quorum it cannot obtain.
        vm.prank(ops);
        assertEq(
            bridge.originate(ops, termsA), idA, "facts recorded before the slot was cleared still satisfy the gate"
        );
        _attest(idB, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHashB);
        _attest(idB, IAttestationOracle.AttestationKind.UCCFiled, termsHashB);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.CreditIssued
            )
        );
        bridge.originate(ops, termsB);
        assertEq(bridge.totalOriginated(), idA, "no facility minted behind an unset threshold");
        assertEq(reserves.deployedTo(idB), 0, "and nothing was deployed to it");

        // Recovery is governance re-seating the floor; the identical never-burned bundle then lands.
        vm.expectEmit(true, false, false, true, address(oracle));
        emit IAttestationOracle.ThresholdSet(IAttestationOracle.AttestationKind.CreditIssued, 2);
        oracle.setThreshold(IAttestationOracle.AttestationKind.CreditIssued, 2);
        _relay(b, _quorum(b));
        _assertFactStatus(
            idB,
            IAttestationOracle.AttestationKind.CreditIssued,
            termsHashB,
            IAttestationOracle.FactStatus.Recorded,
            "terms quorum recorded after re-seating"
        );
        vm.prank(ops);
        assertEq(bridge.originate(ops, termsB), idB, "the gate opens on a real quorum");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5: I8. No privileged lever from carol; pause halts relay, not consumption
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks I8 across the whole privileged surface from the roleless attacker, and the
    ///         guardian pause semantics through the real consumer. If any lever answered carol,
    ///         she could spend a fact (consume), kill a genuine one (revoke), change who counts as
    ///         an attester (grantRole / revokeRole / setThreshold), freeze relay (pause) or replace
    ///         the code (upgrade). If the pause reached consumption, a paused oracle would strand
    ///         an attested coupon whose cash already needs routing. The permissionless relay is
    ///         pinned as design: carol delivers a genuine quorum and the record is attributed to
    ///         the signers, never to her.
    function test_atk_privilegedSurfaceRejectsCarolAndPauseHaltsRelayNotConsumption() public onFork {
        uint256 tokenId = _fundedFilm(1_000_000e18);
        _warp(30 days);
        AttestedReceipt memory r =
            _receipt(tokenId, keccak256("atk-a5-receipt"), _couponDue(tokenId), 0, _nextDue(tokenId));
        IAttestationOracle.AttestationInput memory a = _paymentInput(tokenId, r.payload);

        // Relay is permissionless by design: the signers are the authority, not the sender.
        (uint256 loPk, uint256 hiPk) = _lowHigh();
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IAttestationOracle.Attested(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, vm.addr(loPk), uint64(block.timestamp)
        );
        vm.expectEmit(true, true, true, true, address(oracle));
        emit IAttestationOracle.Attested(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, vm.addr(hiPk), uint64(block.timestamp)
        );
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IAttestationOracle.AttestationSatisfied(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, r.payload, uint64(block.timestamp)
        );
        _relay(a, _quorum(a));
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r.payload,
            IAttestationOracle.FactStatus.Recorded,
            "carol's relay recorded the quorum"
        );

        _assertCarolHoldsNoLever(tokenId);
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r.payload,
            IAttestationOracle.FactStatus.Recorded,
            "the sweep changed nothing"
        );

        // The guardian pauses (ops holds GUARDIAN_ROLE on this deploy shape).
        oracle.pause();
        assertTrue(oracle.paused(), "paused");

        // Relay is halted, and the halted bundle is not burned.
        IAttestationOracle.AttestationInput memory doc = _input(
            tokenId,
            IAttestationOracle.AttestationKind.UCCFiled,
            keccak256("atk-a5-doc"),
            uint64(block.timestamp),
            1 hours
        );
        bytes32 dDoc = oracle.attestationDigest(doc);
        _expectRelayRevert(doc, _one(PK1, dDoc), abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        _assertUnrecorded(tokenId, IAttestationOracle.AttestationKind.UCCFiled, keccak256("atk-a5-doc"), dDoc);

        // Reads are open, and the REAL consumer spends the standing fact while paused.
        assertTrue(oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.PaymentReceived), "read while paused");
        uint256 treasuryUsdc = IERC20(USDC).balanceOf(address(reserves));
        _fundBorrowerFor(r);
        vm.expectEmit(true, true, true, false, address(oracle));
        emit IAttestationOracle.AttestationConsumed(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, address(waterfall)
        );
        vm.prank(ops);
        waterfall.distribute(r.payment);
        assertEq(
            IERC20(USDC).balanceOf(address(reserves)) - treasuryUsdc,
            r.stableAmount,
            "the coupon's cash was routed while the oracle was paused"
        );
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r.payload,
            IAttestationOracle.FactStatus.Consumed,
            "consumed while paused"
        );

        // Unpause: the halted bundle relays unchanged.
        oracle.unpause();
        assertFalse(oracle.paused(), "unpaused");
        _relay(doc, _one(PK1, dDoc));
        assertTrue(oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.UCCFiled), "relay resumed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A6: I2. A second receipt cannot overwrite an unspent one
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks I2 through the record slot. Two half-coupon receipts are attested for one
    ///         facility; the second must be refused with `Oracle_UnconsumedFact` naming the first
    ///         while the first is unspent. If it were accepted, the slot would overwrite receipt 1
    ///         before its distribution ran: receipt 1's cash could never be routed (its fact is
    ///         gone, `Waterfall_PaymentNotAttested`), stranding the borrower's payment, while its
    ///         ledger entry would still read `Recorded`. After receipt 1 is spent the very same
    ///         receipt-2 bundle must land, and each coupon half must reach the treasury once.
    function test_atk_secondReceiptCannotOverwriteAnUnspentOne() public onFork {
        uint256 tokenId = _fundedFilm(1_000_000e18);
        _warp(30 days);
        (AttestedReceipt memory r1, AttestedReceipt memory r2) = _twoHalfCoupons(tokenId);

        IAttestationOracle.AttestationInput memory a1 = _paymentInput(tokenId, r1.payload);
        _relay(a1, _quorum(a1));
        _assertSlot(tokenId, r1.payload, true, "receipt 1 standing in the slot");

        // ATTACK: land receipt 2 on top of the unspent receipt 1.
        IAttestationOracle.AttestationInput memory a2 = _paymentInput(tokenId, r2.payload);
        bytes[] memory s2 = _quorum(a2);
        _expectRelayRevert(
            a2,
            s2,
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_UnconsumedFact.selector,
                tokenId,
                IAttestationOracle.AttestationKind.PaymentReceived,
                r1.payload
            )
        );
        _assertSlot(tokenId, r1.payload, true, "receipt 1 still occupies the slot, still spendable");
        _assertUnrecorded(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, r2.payload, oracle.attestationDigest(a2)
        );

        // Receipt 2 is not spendable yet: the attempt did not smuggle it in.
        _fundBorrowerFor(r2);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IWaterfallEngine.Waterfall_PaymentNotAttested.selector, tokenId));
        waterfall.distribute(r2.payment);

        // Spend receipt 1, then the identical receipt-2 bundle lands and is spent: each half once.
        uint256 treasuryUsdc = IERC20(USDC).balanceOf(address(reserves));
        _distribute(r1);
        assertEq(IERC20(USDC).balanceOf(address(reserves)) - treasuryUsdc, r1.stableAmount, "half 1 routed once");
        _assertSlot(tokenId, r1.payload, false, "receipt 1 spent");
        _relay(a2, s2);
        _assertSlot(tokenId, r2.payload, true, "receipt 2 attestable exactly after the spend");
        _distribute(r2);
        assertEq(
            IERC20(USDC).balanceOf(address(reserves)) - treasuryUsdc,
            r1.stableAmount + r2.stableAmount,
            "both halves routed, exactly once each"
        );
        _assertSlot(tokenId, r2.payload, false, "receipt 2 spent");
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r1.payload,
            IAttestationOracle.FactStatus.Consumed,
            "receipt 1 in the ledger as spent"
        );
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            r2.payload,
            IAttestationOracle.FactStatus.Consumed,
            "receipt 2 in the ledger as spent"
        );
        assertEq(reserves.accruedDebt(tokenId).interest, 0, "the whole coupon is discharged, nothing twice");
    }

    /// @dev The coupon due now, split into two receipts on USDC's grid with consecutive due dates.
    function _twoHalfCoupons(uint256 tokenId)
        private
        view
        returns (AttestedReceipt memory r1, AttestedReceipt memory r2)
    {
        uint256 coupon = _couponDue(tokenId);
        uint256 half = coupon / 2 / 1e12 * 1e12;
        require(half > 0, "ATK: no coupon accrued");
        uint64 due1 = _nextDue(tokenId);
        r1 = _receipt(tokenId, keccak256("atk-a6-receipt-1"), half, 0, due1);
        r2 = _receipt(
            tokenId, keccak256("atk-a6-receipt-2"), coupon - half, 0, due1 + bridge.facility(tokenId).paymentInterval
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // A7: kind 9 (AccrualOpening): quorum, consumer, and the mainnet-mirror threshold
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attacks the newest kind. An AccrualOpening fact authorises the import of a
    ///         facility's opening debt into the continuous-accrual book, so an under-quorum or
    ///         attacker-consumable opening would let deployed face be invented or spent. Pinned:
    ///         1-of-2 is refused; the floor cannot be lowered; a genuine quorum records it from
    ///         carol's relay; carol cannot consume it, nor reach `prepareContinuousAccrualMigration`;
    ///         the admin cannot reach it either on this fixture, because the book is enabled at
    ///         deploy and the migration path is closed on an enabled book; a fresh-nonce re-signing
    ///         is refused while it stands and, durably, after governance revokes it (C4-02); and,
    ///         mirroring the live proxy whose thresholds stop at kind 8, an unset kind-9 slot
    ///         refuses even a full quorum until governance seats it at the floor.
    function test_atk_accrualOpeningIsQuorumGatedAndItsConsumerIsClosed() public onFork {
        uint256 tokenId = _fundedFilm(1_000_000e18);
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), 2, "kind 9 seats at 2-of-n");
        bytes32 opening =
            keccak256(abi.encode(OPENING_TYPEHASH, keccak256("atk-frozen-record"), keccak256("atk-opening")));

        _a7QuorumAndFloor(tokenId, opening);
        _a7ConsumerClosed(tokenId, opening);
        _a7MainnetMirror(tokenId + 1);
    }

    /// @dev 1-of-2 refused, the floor immovable, a genuine quorum recorded verbatim from carol's relay.
    function _a7QuorumAndFloor(uint256 tokenId, bytes32 opening) private {
        IAttestationOracle.AttestationInput memory a = _input(
            tokenId, IAttestationOracle.AttestationKind.AccrualOpening, opening, uint64(block.timestamp), 1 hours
        );
        bytes32 d = oracle.attestationDigest(a);
        _expectRelayRevert(
            a,
            _one(PK1, d),
            abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, uint8(2), uint256(1))
        );
        _assertUnrecorded(tokenId, IAttestationOracle.AttestationKind.AccrualOpening, opening, d);
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AccrualOpening, 1);
        vm.expectRevert(IAttestationOracle.Oracle_BadThreshold.selector);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AccrualOpening, 0);

        _relay(a, _quorum(a));
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.AccrualOpening,
            opening,
            IAttestationOracle.FactStatus.Recorded,
            "opening recorded"
        );
        (bytes32 payload, uint64 asOf, bool satisfied) =
            oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertEq(payload, opening, "payload verbatim");
        assertEq(asOf, uint64(block.timestamp), "asOf verbatim");
        assertTrue(satisfied, "standing");
    }

    /// @dev Carol can neither consume the opening nor reach its consumer; the admin cannot reach
    ///      the consumer either on this fixture, so the fact stands unconsumed and unrepeatable,
    ///      and stays unrepeatable once governance revokes it.
    function _a7ConsumerClosed(uint256 tokenId, bytes32 opening) private {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        oracle.consume(tokenId, IAttestationOracle.AttestationKind.AccrualOpening);

        uint256[] memory roster = new uint256[](1);
        roster[0] = tokenId;
        bytes memory beginStep = abi.encode(uint8(0), abi.encode(roster));
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        reserves.prepareContinuousAccrualMigration(beginStep);
        // The fixture's book was enabled at deploy, and the migration path is closed on an enabled
        // book. The consumer of this kind is therefore unreachable here, even for the admin.
        vm.expectRevert(ReserveAccrualLib.ReserveAccrual_AlreadyConfigured.selector);
        reserves.prepareContinuousAccrualMigration(beginStep);
        _assertFactStatus(
            tokenId,
            IAttestationOracle.AttestationKind.AccrualOpening,
            opening,
            IAttestationOracle.FactStatus.Recorded,
            "unconsumed, and standing"
        );

        // Re-signing the same opening under a fresh nonce is refused while it stands.
        _expectOpeningResignRefused(tokenId, opening, IAttestationOracle.FactStatus.Recorded);

        // Governance revokes it (C4-02): the tombstone is durable, so the identical opening
        // re-signed under a fresh nonce can never be re-recorded and later imported.
        vm.expectEmit(true, true, false, false, address(oracle));
        emit IAttestationOracle.AttestationRevoked(tokenId, IAttestationOracle.AttestationKind.AccrualOpening);
        oracle.revoke(tokenId, IAttestationOracle.AttestationKind.AccrualOpening);
        assertFalse(oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.AccrualOpening), "revoked");
        _expectOpeningResignRefused(tokenId, opening, IAttestationOracle.FactStatus.Revoked);
    }

    /// @dev The same opening under a fresh nonce must be refused by the fact ledger in `expected`.
    function _expectOpeningResignRefused(uint256 tokenId, bytes32 opening, IAttestationOracle.FactStatus expected)
        private
    {
        _assertFactStatus(tokenId, IAttestationOracle.AttestationKind.AccrualOpening, opening, expected, "ledger state");
        IAttestationOracle.AttestationInput memory again = _input(
            tokenId, IAttestationOracle.AttestationKind.AccrualOpening, opening, uint64(block.timestamp), 1 hours
        );
        bytes32 d = oracle.attestationDigest(again);
        _expectRelayRevert(
            again,
            _quorum(again),
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(tokenId, IAttestationOracle.AttestationKind.AccrualOpening, opening),
                expected
            )
        );
        assertFalse(oracle.digestUsed(d), "the refused re-signing burned nothing");
    }

    /// @dev MAINNET MIRROR: the live oracle proxy carries thresholds for kinds 0..8 only, so an
    ///      implementation-only upgrade leaves kind 9's slot at zero. A full quorum is then refused
    ///      until governance seats the floor; the identical bundle lands afterwards.
    function _a7MainnetMirror(uint256 facilityId) private {
        _clearThresholdSlot(IAttestationOracle.AttestationKind.AccrualOpening);
        assertEq(
            oracle.threshold(IAttestationOracle.AttestationKind.AccrualOpening), 0, "kind 9 unset, as on the live proxy"
        );
        bytes32 opening = keccak256("atk-opening-2");
        IAttestationOracle.AttestationInput memory a = _input(
            facilityId, IAttestationOracle.AttestationKind.AccrualOpening, opening, uint64(block.timestamp), 1 hours
        );
        bytes32 d = oracle.attestationDigest(a);
        _expectRelayRevert(a, _quorum(a), abi.encodeWithSelector(IAttestationOracle.Oracle_BadThreshold.selector));
        _assertUnrecorded(facilityId, IAttestationOracle.AttestationKind.AccrualOpening, opening, d);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit IAttestationOracle.ThresholdSet(IAttestationOracle.AttestationKind.AccrualOpening, 2);
        oracle.setThreshold(IAttestationOracle.AttestationKind.AccrualOpening, 2);
        _relay(a, _quorum(a));
        _assertFactStatus(
            facilityId,
            IAttestationOracle.AttestationKind.AccrualOpening,
            opening,
            IAttestationOracle.FactStatus.Recorded,
            "recorded once seated"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // A3 sub-cases (small frames: the shipped build has no via-ir)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Shapes (i) to (iv) and (viii): the struct is genuine, the signature set is not.
    function _bypassSignatureShapes(IAttestationOracle.AttestationInput memory a, bytes32 d) private {
        (uint256 loPk, uint256 hiPk) = _lowHigh();

        // (i) one valid signature on a 2-of-n kind.
        _expectRelayRevert(
            a,
            _one(PK1, d),
            abi.encodeWithSelector(IAttestationOracle.Oracle_ThresholdNotMet.selector, uint8(2), uint256(1))
        );
        _assertUnrecorded(a.facilityId, a.kind, a.payload, d);

        // (ii) the same key twice: `signer <= prev` names the duplicate.
        bytes[] memory dup = new bytes[](2);
        dup[0] = _sig(loPk, d);
        dup[1] = _sig(loPk, d);
        _expectRelayRevert(
            a,
            dup,
            abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, vm.addr(loPk), vm.addr(loPk))
        );
        _assertUnrecorded(a.facilityId, a.kind, a.payload, d);

        // (iii) two valid signatures in descending signer order.
        bytes[] memory desc = new bytes[](2);
        desc[0] = _sig(hiPk, d);
        desc[1] = _sig(loPk, d);
        _expectRelayRevert(
            a,
            desc,
            abi.encodeWithSelector(IAttestationOracle.Oracle_UnorderedSigners.selector, vm.addr(hiPk), vm.addr(loPk))
        );
        _assertUnrecorded(a.facilityId, a.kind, a.payload, d);

        // (iv) one valid plus one from a key outside the attester set, correctly sorted.
        address outsider = vm.addr(PK_OUTSIDER);
        assertFalse(oracle.hasRole(Roles.ATTESTER_ROLE, outsider), "precondition: outsider holds no role");
        _expectRelayRevert(
            a,
            _sorted(PK1, PK_OUTSIDER, d),
            abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, outsider)
        );
        _assertUnrecorded(a.facilityId, a.kind, a.payload, d);

        // (viii) high-s malleation of a valid signature: refused by ECDSA before any quorum logic.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(loPk, d);
        assertLe(uint256(s), SECP256K1_HALF_N, "precondition: the honest signature is low-s");
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        bytes[] memory malleated = new bytes[](2);
        malleated[0] = abi.encodePacked(r, sHigh, v == 27 ? uint8(28) : uint8(27));
        malleated[1] = _sig(hiPk, d);
        _expectRelayRevert(a, malleated, abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        _assertUnrecorded(a.facilityId, a.kind, a.payload, d);
    }

    /// @dev Shapes (v) to (vii): the signature set is a genuine quorum, the struct is not.
    function _bypassStructShapes(IAttestationOracle.AttestationInput memory a, bytes32 payload) private {
        uint64 nowTs = uint64(block.timestamp);

        // (v) a genuine quorum over an expired bundle.
        IAttestationOracle.AttestationInput memory expired = _copy(a);
        expired.expiry = nowTs - 1;
        expired.nonce = _nextNonce();
        bytes32 dExp = oracle.attestationDigest(expired);
        _expectRelayRevert(
            expired, _quorum(expired), abi.encodeWithSelector(IAttestationOracle.Oracle_Expired.selector, nowTs - 1)
        );
        _assertUnrecorded(a.facilityId, a.kind, payload, dExp);

        // (vi) a genuine quorum over a future observation time.
        IAttestationOracle.AttestationInput memory future = _copy(a);
        future.asOf = nowTs + 1;
        future.nonce = _nextNonce();
        bytes32 dFut = oracle.attestationDigest(future);
        _expectRelayRevert(
            future, _quorum(future), abi.encodeWithSelector(IAttestationOracle.Oracle_BadAsOf.selector, nowTs + 1)
        );
        _assertUnrecorded(a.facilityId, a.kind, payload, dFut);

        // (vii) a genuine quorum over ANOTHER facility's digest, submitted for this facility: the
        // domain-bound digest recovers two strangers and the first is refused by name.
        IAttestationOracle.AttestationInput memory other = _copy(a);
        other.facilityId = a.facilityId + 1000;
        bytes[] memory overOther = _quorum(other);
        bytes32 dMine = oracle.attestationDigest(a);
        _expectStrangersRefused(a, overOther, dMine);
        _assertUnrecorded(a.facilityId, a.kind, payload, dMine);
        _assertUnrecorded(other.facilityId, a.kind, payload, oracle.attestationDigest(other));
    }

    // ─────────────────────────────────────────────────────────────────────
    // A5 sub-case
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Every privileged oracle entry point from the roleless attacker, each with its exact
    ///      AccessControl (or initializer) revert, and the role topology asserted untouched after.
    function _assertCarolHoldsNoLever(uint256 tokenId) private {
        bytes memory adminErr =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0));

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.CREDIT_ROLE)
        );
        oracle.consume(tokenId, IAttestationOracle.AttestationKind.PaymentReceived);

        vm.prank(carol);
        vm.expectRevert(adminErr);
        oracle.revoke(tokenId, IAttestationOracle.AttestationKind.PaymentReceived);

        vm.prank(carol);
        vm.expectRevert(adminErr);
        oracle.setThreshold(IAttestationOracle.AttestationKind.PaymentReceived, 3);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        oracle.pause();

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        oracle.unpause();

        vm.prank(carol);
        vm.expectRevert(adminErr);
        oracle.grantRole(Roles.ATTESTER_ROLE, carol);

        vm.prank(carol);
        vm.expectRevert(adminErr);
        oracle.grantRole(Roles.CREDIT_ROLE, carol);

        vm.prank(carol);
        vm.expectRevert(adminErr);
        oracle.revokeRole(Roles.ATTESTER_ROLE, attesterA);

        vm.prank(carol);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        oracle.renounceRole(Roles.ATTESTER_ROLE, attesterA);

        address newImpl = address(new AttestationOracle());
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.UPGRADER_ROLE)
        );
        oracle.upgradeToAndCall(newImpl, "");

        vm.prank(carol);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(carol, carol, carol);

        assertTrue(oracle.hasRole(Roles.ATTESTER_ROLE, attesterA), "attester 1 still seated");
        assertTrue(oracle.hasRole(Roles.ATTESTER_ROLE, attester2Addr), "attester 2 still seated");
        assertFalse(oracle.hasRole(Roles.ATTESTER_ROLE, carol), "carol is not an attester");
        assertFalse(oracle.hasRole(Roles.CREDIT_ROLE, carol), "carol cannot consume");
        assertFalse(oracle.hasRole(bytes32(0), carol), "carol is not admin");
        assertFalse(oracle.paused(), "not paused by carol");
        assertEq(oracle.threshold(IAttestationOracle.AttestationKind.PaymentReceived), 2, "threshold untouched");
    }

    // ─────────────────────────────────────────────────────────────────────
    // A2 sub-cases
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Originates and funds a 400,000e18 digital-asset facility at `id` behind a real mint
    ///      gate, with the first mark relayed by carol. Returns that mark's bundle so the test can
    ///      replay it byte-for-byte later.
    function _originateFundedDa(uint256 id, uint256 firstMark)
        private
        returns (IAttestationOracle.AttestationInput memory m1, bytes[] memory s1)
    {
        uint64 maturity = uint64(block.timestamp + 300 days);
        ClaimBridge.OriginationTerms memory terms =
            _daTerms(keccak256("ATK-DA-BORROWER"), 400_000e18, maturity, keccak256("atk-da"));
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        m1 = _valuationInput(id, firstMark, uint64(block.timestamp));
        s1 = _quorum(m1);
        _relay(m1, s1);
        vm.prank(ops);
        require(bridge.originate(ops, terms) == id, "ATK: tokenId drift");
        vm.prank(ops);
        waterfall.fund(id, 400_000e6);
        assertEq(reserves.deployedTo(id), 400_000e18, "funded at exactly its principal");
    }

    function _daTerms(bytes32 borrowerId, uint256 principal, uint64 maturity, bytes32 ref)
        private
        view
        returns (ClaimBridge.OriginationTerms memory)
    {
        return _forkTermsFor(Config.CLASS_DIGITAL_ASSETS, borrowerId, bytes32(0), principal, 5000, 1000, maturity, ref);
    }

    /// @dev A never-submitted, freshly-signed valuation bundle at `attemptedAsOf` must be refused
    ///      as stale against `watermark`, leaving the watermark where it was.
    function _expectStaleValuation(uint256 id, uint256 value, uint64 attemptedAsOf, uint64 watermark) private {
        IAttestationOracle.AttestationInput memory m = _valuationInput(id, value, attemptedAsOf);
        bytes32 d = oracle.attestationDigest(m);
        assertFalse(oracle.digestUsed(d), "a genuinely new bundle, not a byte replay");
        _expectRelayRevert(
            m,
            _quorum(m),
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, attemptedAsOf, watermark)
        );
        assertFalse(oracle.digestUsed(d), "the refusal burned nothing");
        assertEq(oracle.valuationWatermark(id), watermark, "the watermark did not move");
    }

    /// @dev The old bundle's signatures over the same struct with `asOf` moved to now.
    function _expectForgedAsOfRefused(IAttestationOracle.AttestationInput memory m1, bytes[] memory s1) private {
        IAttestationOracle.AttestationInput memory forged = _copy(m1);
        forged.asOf = uint64(block.timestamp);
        _expectStrangersRefused(forged, s1, oracle.attestationDigest(forged));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Shared helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev A spent PaymentReceived fact re-signed under a fresh nonce must be refused by the fact
    ///      ledger as `Consumed`, burn nothing, and leave nothing satisfied. `originalDigest`, when
    ///      given, proves the new bundle is not a byte replay of the one that was spent.
    function _expectSpentReceiptReplayRefused(uint256 tokenId, bytes32 payload, bytes32 originalDigest) private {
        IAttestationOracle.AttestationInput memory again = _paymentInput(tokenId, payload);
        bytes32 d = oracle.attestationDigest(again);
        if (originalDigest != bytes32(0)) assertTrue(d != originalDigest, "a genuinely new digest, not a byte replay");
        _expectRelayRevert(
            again,
            _quorum(again),
            abi.encodeWithSelector(
                IAttestationOracle.Oracle_FactAlreadyRealised.selector,
                oracle.factKey(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload),
                IAttestationOracle.FactStatus.Consumed
            )
        );
        assertFalse(oracle.digestUsed(d), "the refused bundle did not burn its digest");
        assertFalse(
            oracle.isSatisfied(tokenId, IAttestationOracle.AttestationKind.PaymentReceived), "nothing satisfied"
        );
    }

    /// @dev The PaymentReceived record slot holds exactly `payload` with the given satisfied flag.
    function _assertSlot(uint256 tokenId, bytes32 payload, bool satisfied, string memory ctx) private view {
        (bytes32 slotPayload,, bool slotSatisfied) =
            oracle.latestPayload(tokenId, IAttestationOracle.AttestationKind.PaymentReceived);
        assertEq(slotPayload, payload, ctx);
        assertEq(slotSatisfied, satisfied, ctx);
    }

    function _snapshot(uint256 tokenId) private view returns (MoneySnapshot memory m) {
        m.treasuryUsdc = IERC20(USDC).balanceOf(address(reserves));
        m.vaultUsdfr = usdfr.balanceOf(address(vault));
        m.supply = usdfr.totalSupply();
        m.deployed = reserves.deployedTo(tokenId);
    }

    function _assertUnmoved(uint256 tokenId, MoneySnapshot memory m) private view {
        assertEq(IERC20(USDC).balanceOf(address(reserves)), m.treasuryUsdc, "no second cash leg reached the treasury");
        assertEq(usdfr.balanceOf(address(vault)), m.vaultUsdfr, "no second yield reached the senior vault");
        assertEq(usdfr.totalSupply(), m.supply, "no USDfr was minted by the replay");
        assertEq(reserves.deployedTo(tokenId), m.deployed, "the facility's outstanding is untouched");
    }

    /// @dev Two signatures that were made over some other digest, submitted for struct `a` whose
    ///      digest is `d`: each recovers a stranger. Sorted by recovered address so the ordering
    ///      check passes and the first stranger is refused BY NAME.
    function _expectStrangersRefused(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs, bytes32 d)
        private
    {
        address g0 = ECDSA.recover(d, sigs[0]);
        address g1 = ECDSA.recover(d, sigs[1]);
        bytes[] memory ordered = new bytes[](2);
        (ordered[0], ordered[1]) = g0 < g1 ? (sigs[0], sigs[1]) : (sigs[1], sigs[0]);
        address first = g0 < g1 ? g0 : g1;
        assertFalse(oracle.hasRole(Roles.ATTESTER_ROLE, first), "precondition: the recovered address is a stranger");
        _expectRelayRevert(a, ordered, abi.encodeWithSelector(IAttestationOracle.Oracle_NotAttester.selector, first));
    }

    /// @dev Reserve liquidity, a non-empty senior vault, and one funded 1,000,000e18 FILM facility.
    function _fundedFilm(uint256 principal) private returns (uint256 tokenId) {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 4_000_000e18);
        tokenId = _originateAndFund(principal);
    }

    /// @dev The coupon the engine says is due now, on USDC's 1e12 grid.
    function _couponDue(uint256 tokenId) private view returns (uint256) {
        return reserves.accruedDebt(tokenId).interest / 1e12 * 1e12;
    }

    function _nextDue(uint256 tokenId) private view returns (uint64) {
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        return f.nextPaymentDue + f.paymentInterval;
    }

    /// @dev Mirrors `ForkLifecycleFixture._repay`'s payload commitment exactly.
    function _receipt(uint256 tokenId, bytes32 paymentId, uint256 interest, uint256 principalRepaid, uint64 nextDue)
        private
        view
        returns (AttestedReceipt memory r)
    {
        r.stableAmount = (interest + principalRepaid) / 1e12;
        r.payload = keccak256(
            abi.encode(paymentId, tokenId, USDC, borrower, r.stableAmount, interest, principalRepaid, nextDue)
        );
        r.payment = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: borrower,
            interest: interest,
            principal: principalRepaid,
            nextPaymentDue: nextDue
        });
    }

    function _fundBorrowerFor(AttestedReceipt memory r) private {
        deal(USDC, borrower, IERC20(USDC).balanceOf(borrower) + r.stableAmount);
        vm.prank(borrower);
        IERC20(USDC).approve(address(reserves), r.stableAmount);
    }

    function _distribute(AttestedReceipt memory r) private {
        _fundBorrowerFor(r);
        vm.prank(ops);
        waterfall.distribute(r.payment);
    }

    function _paymentInput(uint256 tokenId, bytes32 payload)
        private
        returns (IAttestationOracle.AttestationInput memory)
    {
        return _input(
            tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload, uint64(block.timestamp), 1 hours
        );
    }

    /// @dev Valuation bundles carry a 30-day expiry so a pre-markdown bundle is still inside its
    ///      signed window when the attacker replays it; otherwise `Oracle_Expired` would mask the
    ///      replay guard under test.
    function _valuationInput(uint256 id, uint256 value, uint64 asOf)
        private
        returns (IAttestationOracle.AttestationInput memory)
    {
        return _input(id, IAttestationOracle.AttestationKind.Valuation, bytes32(value), asOf, 30 days);
    }

    /// @dev An explicit field-by-field copy: memory struct assignment aliases, and the attacks mutate.
    function _copy(IAttestationOracle.AttestationInput memory a)
        private
        pure
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: a.facilityId,
            kind: a.kind,
            payload: a.payload,
            asOf: a.asOf,
            expiry: a.expiry,
            nonce: a.nonce
        });
    }

    function _nextNonce() private returns (uint256) {
        return uint256(keccak256(abi.encode("atk-oracle-nonce", ++_nonceCounter)));
    }

    function _input(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        uint64 asOf,
        uint64 ttl
    ) private returns (IAttestationOracle.AttestationInput memory) {
        return IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp) + ttl,
            nonce: _nextNonce()
        });
    }

    function _sig(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _one(uint256 pk, bytes32 digest) private pure returns (bytes[] memory sigs) {
        sigs = new bytes[](1);
        sigs[0] = _sig(pk, digest);
    }

    /// @dev Two signatures sorted ascending by recovered signer address, as the oracle demands.
    function _sorted(uint256 pkA, uint256 pkB, bytes32 digest) private pure returns (bytes[] memory sigs) {
        (uint256 lo, uint256 hi) = vm.addr(pkA) < vm.addr(pkB) ? (pkA, pkB) : (pkB, pkA);
        sigs = new bytes[](2);
        sigs[0] = _sig(lo, digest);
        sigs[1] = _sig(hi, digest);
    }

    /// @dev The two attester keys ordered by address (low first).
    function _lowHigh() private pure returns (uint256 loPk, uint256 hiPk) {
        (loPk, hiPk) = vm.addr(PK1) < vm.addr(PK2) ? (PK1, PK2) : (PK2, PK1);
    }

    /// @dev The genuine 2-of-n quorum over `a`.
    function _quorum(IAttestationOracle.AttestationInput memory a) private view returns (bytes[] memory) {
        return _sorted(PK1, PK2, oracle.attestationDigest(a));
    }

    /// @dev Carol relays a bundle. Relay is permissionless by design; only the signatures count.
    function _relay(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs) private {
        vm.prank(carol);
        oracle.attest(a, sigs);
    }

    /// @dev Carol relays a bundle that must revert with exactly `err`.
    function _expectRelayRevert(IAttestationOracle.AttestationInput memory a, bytes[] memory sigs, bytes memory err)
        private
    {
        vm.prank(carol);
        vm.expectRevert(err);
        oracle.attest(a, sigs);
    }

    function _assertFactStatus(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        IAttestationOracle.FactStatus expected,
        string memory ctx
    ) private view {
        assertEq(uint8(oracle.factStatus(facilityId, kind, payload)), uint8(expected), ctx);
    }

    /// @dev Nothing recorded, nothing in the ledger, nothing burned.
    function _assertUnrecorded(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        bytes32 digest
    ) private view {
        (bytes32 slotPayload,, bool satisfied) = oracle.latestPayload(facilityId, kind);
        assertFalse(satisfied && slotPayload == payload, "the attempted fact is not standing");
        assertEq(
            uint8(oracle.factStatus(facilityId, kind, payload)),
            uint8(IAttestationOracle.FactStatus.None),
            "not in the ledger"
        );
        assertFalse(oracle.digestUsed(digest), "digest not burned");
    }

    /// @dev Writes zero into `thresholds[kind]` inside the proxy's namespaced storage: the state a
    ///      newly added kind is in after an implementation-only upgrade. Asserted through the
    ///      public view so a layout drift fails loudly rather than testing the wrong slot.
    function _clearThresholdSlot(IAttestationOracle.AttestationKind kind) private {
        bytes32 slot = keccak256(abi.encode(uint256(uint8(kind)), uint256(ORACLE_STORAGE_LOCATION) + 1));
        vm.store(address(oracle), slot, bytes32(0));
        require(oracle.threshold(kind) == 0, "ATK: threshold slot layout drifted");
    }
}
