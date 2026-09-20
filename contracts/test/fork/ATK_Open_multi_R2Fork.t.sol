// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {AccrualBook} from "../../src/libraries/AccrualBook.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title OPEN_multi_R2: multi-facility and cross-class interactions on the pinned mainnet fork.
///
/// @notice Round 2 of the adversarial fork campaign, angle "two or more facilities sharing the
///         curator pool, the sGROVE reserve, the past-due cohort clock and the class exposure".
///         Three candidate attacks, deepest first:
///
///         M1. PAST-DUE PAIR, ONE CURES. Two FILM facilities are marked past due by carol at
///             different times. The second join must inherit the OLDER relief clock (never re-time
///             the standing member), the class cohort must equal the sum of the two recorded
///             contributions plus both facilities' unposted streams to the wei, the cure of one
///             (coupon then servicer clear) must leave the other's contribution, unposted stream and
///             clock untouched, and after the clear the cohort must stream at the survivor's rate
///             alone. The senior mark is checked against the registry's deliberately independent
///             ramp formula at every reading. Then the survivor is declared and the cured facility
///             re-marked on a NEW authenticated episode: only then does the clock reset.
///
///         M2. SAME-CLASS DISTRESSED PAIR ACROSS THE POOL BOUNDARY. One facility declared, the
///             other past due, in one class whose curator pool is smaller than the past-due mark and
///             whose shared sGROVE reserve is smaller than the residual. The conservative mark is
///             pinned to the closed form (past-due consumes the pool first, coverage next, the
///             declared cohort at full weight, the unattested cohort ramped) and then the cascade is
///             EXECUTED in the opposite order (the declared facility draws the pool first). The
///             executed senior burn across both events must equal the full-weight mark, and the
///             mark standing at the second declaration must equal that event's executed burn.
///
///         M3. THE 100-FACILITY ENVELOPE. One hundred facilities are funded in one block; the
///             101st originates (attestations consumed) but cannot be funded, with the exact book
///             error; cancelling it and fully repaying one facility frees the slot; then all one
///             hundred mature at the same second and the boundary sweep is measured: how many
///             permissionless checkpoints it takes, what each costs, what is refused in between,
///             and that the book recognises exactly one hundred grid-floored coupons.
contract OPEN_multi_R2Test is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant RATE_BPS = 1400;
    uint256 internal constant YEAR = 360 days;
    uint256 internal constant TERM = 365 days;
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant GRACE = 21 days; // DefaultInitLib seeds Config.DEFAULT_REDEEM_COOLDOWN
    uint256 internal constant RAMP = 21 days; // Config.DEFAULT_REDEEM_COOLDOWN

    struct Layers {
        uint256 absorbed;
        uint256 covered;
        uint256 senior;
    }

    // ─────────────────────────────────────────────────────────────────────
    // M1. past-due pair: the cure of one neither re-prices nor re-times the other
    // ─────────────────────────────────────────────────────────────────────

    function test_multi_pastDuePair_cureOfOneNeitherRepricesNorRetimesTheOther() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 2_000_000e18);
        uint256 t0 = block.timestamp;
        uint256 a = _fundIn(FILM, keccak256("BW-A"), 1_000_000e18);
        uint256 b = _fundIn(FILM, keccak256("BW-B"), 400_000e18);

        // ── A is marked first, at day 52 (due day 30 + 21-day grace, strictly after) ──
        _warpTo(t0 + 52 days);
        vm.prank(carol);
        defaultManager.markPastDue(a);
        uint256 anchorA = block.timestamp;
        uint256 cA = _recorded(a);
        assertEq(cA, reserves.deployedTo(a), "A: recorded contribution is the posted face at the mark");
        assertEq(reserves.unpostedAccruedLoan(a), 0, "A: nothing unposted at the mark");
        assertEq(defaultManager.pastDueReliefAnchor(), anchorA, "the empty cohort takes A's episode start");
        assertEq(defaultManager.pastDuePrincipal(FILM), cA, "cohort == A alone");
        assertEq(reserves.accruedPastDue(FILM), 0, "no streamed cohort interest yet");

        // ── B joins ten days later: it must INHERIT the older clock, not re-time A ──
        _warpTo(t0 + 62 days);
        uint256 unpostedA = reserves.unpostedAccruedLoan(a);
        assertGt(unpostedA, 0, "A has streamed since its mark");
        assertEq(reserves.accruedPastDue(FILM), unpostedA, "the cohort stream is exactly A's unposted");
        vm.prank(carol);
        defaultManager.markPastDue(b);
        uint256 cB = _recorded(b);
        assertEq(cB, reserves.deployedTo(b), "B: recorded contribution is the posted face at the mark");
        assertEq(defaultManager.pastDueReliefAnchor(), anchorA, "B's join did NOT re-time the standing cohort");
        assertEq(_recorded(a), cA, "B's join left A's recorded contribution untouched");
        assertEq(
            defaultManager.pastDueContribution(a),
            cA + reserves.unpostedAccruedLoan(a),
            "A's contribution view == recorded + A's own unposted stream"
        );
        assertEq(
            defaultManager.pastDuePrincipal(FILM),
            cA + cB + reserves.unpostedAccruedLoan(a),
            "cohort == A recorded + B recorded + A unposted (B just posted)"
        );

        // ── both stream for five days; every cohort view reconciles to its parts ──
        _warpTo(t0 + 67 days);
        unpostedA = reserves.unpostedAccruedLoan(a);
        uint256 unpostedB = reserves.unpostedAccruedLoan(b);
        assertGt(unpostedB, 0, "B has streamed since its mark");
        assertEq(reserves.accruedPastDue(FILM), unpostedA + unpostedB, "class stream == A + B unposted, to the wei");
        assertEq(defaultManager.pastDuePrincipal(FILM), cA + cB + unpostedA + unpostedB, "class cohort reconciles");
        assertEq(defaultManager.pastDueExposure(), cA + cB + unpostedA + unpostedB, "global cohort reconciles");
        _assertMarkIsTheClosedForm(anchorA, "two standing members");
        uint256 exitBefore = vault.previewRedeem(1e18);

        // ── B cures: the borrower pays B's whole accrued coupon through the real waterfall ──
        uint256 interestB = reserves.accruedDebt(b).interest;
        _repay(b, interestB, 0);
        assertEq(defaultManager.pastDueContribution(b), 400_000e18, "B re-anchored to its live face (principal)");
        assertEq(reserves.unpostedAccruedLoan(b), 0, "B's receipt posted everything");
        assertEq(_recorded(a), cA, "B's coupon left A's recorded contribution untouched");
        assertEq(reserves.unpostedAccruedLoan(a), unpostedA, "B's coupon left A's unposted stream untouched");
        assertEq(defaultManager.pastDueReliefAnchor(), anchorA, "B's coupon left the clock untouched");
        assertEq(reserves.accruedPastDue(FILM), unpostedA, "after B's posting the class stream is A's alone");
        assertEq(
            defaultManager.pastDuePrincipal(FILM), cA + 400_000e18 + unpostedA, "cohort after B's coupon reconciles"
        );
        _assertMarkIsTheClosedForm(anchorA, "after B's coupon");

        // ── the servicer clears B's mark ──
        bytes32 cure = keccak256("multi-r2-cure-b");
        _attest(b, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(b, cure)));
        vm.prank(ops);
        defaultManager.clearPastDue(b, cure);
        assertEq(defaultManager.pastDueContribution(b), 0, "B released");
        assertEq(_recorded(a), cA, "B's clear left A's recorded contribution untouched");
        assertEq(defaultManager.pastDueReliefAnchor(), anchorA, "B's clear left the clock untouched");
        assertEq(defaultManager.pastDuePrincipal(FILM), cA + unpostedA, "cohort == A alone again");
        assertEq(defaultManager.pastDueExposure(), cA + unpostedA, "global == A alone again");
        _assertMarkIsTheClosedForm(anchorA, "after B's clear");
        assertGt(vault.previewRedeem(1e18), exitBefore, "B's cure raised the senior exit price");

        // ── five more days: the cohort must now stream at A's rate ALONE ──
        _warpTo(t0 + 72 days);
        assertEq(
            reserves.accruedPastDue(FILM),
            reserves.unpostedAccruedLoan(a),
            "B's slope left the cohort: the class stream is exactly A's unposted"
        );
        assertEq(
            defaultManager.pastDuePrincipal(FILM),
            cA + reserves.unpostedAccruedLoan(a),
            "cohort five days after the clear == A recorded + A unposted"
        );
        _assertMarkIsTheClosedForm(anchorA, "five days after the clear");

        // carol cannot re-mark the cured facility: its due date advanced and grace has not run.
        ClaimBridge.Facility memory fb = bridge.facility(b);
        assertEq(fb.nextPaymentDue, uint64(t0 + 60 days), "B's due advanced by one interval at the coupon");
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_NotPastDue.selector, b, fb.nextPaymentDue, fb.nextPaymentDue + GRACE
            )
        );
        vm.prank(carol);
        defaultManager.markPastDue(b);

        // ── A is declared: it leaves the cohort; the clock is NOT cleared by a leave ──
        bytes32 ev = keccak256("multi-r2-declare-a");
        _attest(a, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(a, ev)));
        vm.prank(ops);
        defaultManager.declareDefault(a, ev);
        assertEq(defaultManager.pastDueExposure(), 0, "A converted to the declared pool");
        assertEq(reserves.accruedPastDue(FILM), 0, "no cohort stream with no members");
        assertEq(defaultManager.pastDueReliefAnchor(), anchorA, "a leave never rewinds or clears the clock");

        // ── B becomes past due on its NEW episode (due t0+60d, grace to t0+81d) ──
        _warpTo(t0 + 82 days);
        vm.prank(carol);
        defaultManager.markPastDue(b);
        assertEq(
            defaultManager.pastDueReliefAnchor(),
            block.timestamp,
            "an empty cohort plus a NEW authenticated episode is the only way the clock moves forward"
        );
        assertEq(defaultManager.pastDuePrincipal(FILM), _recorded(b), "cohort == B alone, freshly posted");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds throughout");
    }

    // ─────────────────────────────────────────────────────────────────────
    // M2. same-class distressed pair: view order vs executed order across the pool boundary
    // ─────────────────────────────────────────────────────────────────────

    struct Pair {
        uint256 a;
        uint256 b;
        uint256 dA;
        uint256 anchorB;
        uint256 cB;
        uint256 dB;
    }

    function test_multi_sameClassDistressedPair_markMatchesExecutedCascadeAcrossThePoolBoundary() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_500_000e18);
        _mintFromUSDC(ops, 1_000_000e6);
        _postFirstLoss(FILM, 150_000e18); // P: smaller than B's past-due mark
        _fundCoverage(ops, 100_000e18); // R: smaller than the residual
        uint256 t0 = block.timestamp;
        Pair memory p;
        p.a = _fundIn(FILM, keccak256("BW-A"), 800_000e18);
        p.b = _fundIn(FILM, keccak256("BW-B"), 400_000e18);

        _warpTo(t0 + 52 days);
        _declare(p.a);
        p.dA = defaultManager.declaredDefaultedPrincipal(FILM);
        assertEq(p.dA, reserves.deployedTo(p.a), "A's declared contribution is its stopped face");
        vm.prank(carol);
        defaultManager.markPastDue(p.b);
        p.anchorB = block.timestamp;
        p.cB = defaultManager.pastDueContribution(p.b);
        assertGt(p.cB, 150_000e18, "B's mark exceeds the whole class pool");

        _warpTo(t0 + 55 days);
        _m2ViewIsPastDueFirst(p);
        Layers memory sA = _m2RealizeA(p);
        _m2ViewAfterA(p);
        Layers memory sB = _m2DeclareAndRealizeB(p);

        // Conservation across the pair, and the shared layers were consumed exactly once.
        assertLt(150_000e18 - (sA.absorbed + sB.absorbed), SCALE, "layer 1 == the posted first-loss less dust, once");
        assertEq(sA.covered + sB.covered, 100_000e18, "layer 2 == the funded reserve, once");
        assertEq(
            sA.senior + sB.senior,
            p.dA + p.dB - sA.absorbed - 100_000e18,
            "layer 3 == the unfunded residual of both events"
        );
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds after both events");
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "exit base <= total base");
    }

    /// @dev Three days into the ramp: the mark must be the closed form with past-due FIRST.
    function _m2ViewIsPastDueFirst(Pair memory p) internal {
        uint256 mB = p.cB + reserves.unpostedAccruedLoan(p.b);
        assertEq(defaultManager.pastDuePrincipal(FILM), mB, "cohort == B recorded + B unposted");
        uint256 pool = curator.poolBalance(FILM);
        uint256 reserve = sGrove.coverageReserve();
        // A's declaration reconciled its streamed interpolation against the grid-floored canonical
        // amount and charged the sub-unit excess to the CLASS pool (the recorded C4 mechanism), so
        // the pool B is measured against is already short by less than one reserve unit.
        assertLt(150_000e18 - pool, SCALE, "A's declaration dust on the shared pool is sub-unit");
        emit log_named_uint("M2 A's declaration dust charged to the FILM pool (wei)", 150_000e18 - pool);
        assertEq(reserve, 100_000e18, "reserve intact before any realisation");
        // past-due consumes the pool first, then the shared reserve; the declared cohort gets neither.
        uint256 pds = mB - pool - reserve;
        uint256 executable = vault.totalAssets() - p.dA;
        uint256 amount = pds < executable ? pds : executable;
        uint256 w = registry.pastDueRampWeightBps(block.timestamp - p.anchorB);
        assertLt(w, Config.BPS, "still inside the ramp");
        uint256 want = p.dA + (amount * w + Config.BPS - 1) / Config.BPS;
        assertEq(defaultManager.pendingSeniorImpairment(), want, "the mark is the closed form, past-due first");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets() - want, "the exit base carries exactly the mark");
        // The order is observable: declared-first would charge P(1-w) less. Pin the gap.
        uint256 declaredFirst = (p.dA - pool) + ((mB - reserve) * w + Config.BPS - 1) / Config.BPS;
        assertGt(want, declaredFirst, "past-due-first is the conservative order and it is the one in force");
        emit log_named_uint("M2 mark (past-due first)", want);
        emit log_named_uint("M2 mark if declared-first", declaredFirst);
    }

    /// @dev EXECUTE in the opposite order: A (declared) draws the pool and the reserve first.
    function _m2RealizeA(Pair memory p) internal returns (Layers memory sA) {
        sA = _realize(p.a, FILM, p.dA);
        assertLt(150_000e18 - sA.absorbed, SCALE, "A took the whole (dust-reduced) class pool");
        assertEq(sA.covered, 100_000e18, "A took the whole shared reserve");
        assertEq(sA.senior, p.dA - sA.absorbed - 100_000e18, "A's remainder hit the senior vault");
        assertEq(curator.poolBalance(FILM), 0, "pool drained by A");
        assertEq(sGrove.coverageReserve(), 0, "reserve drained by A");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "A fully realised");
        assertEq(uint8(bridge.facility(p.a).state), uint8(ClaimBridge.LoanState.Resolved), "A resolved");
    }

    /// @dev B's mark now has no junior capital in front of it; the view must say so exactly.
    function _m2ViewAfterA(Pair memory p) internal view {
        uint256 mB2 = _recorded(p.b) + reserves.unpostedAccruedLoan(p.b);
        assertEq(defaultManager.pastDuePrincipal(FILM), mB2, "cohort after A's realisation reconciles");
        assertEq(_recorded(p.b), p.cB, "A's realisation left B's recorded contribution untouched");
        uint256 w = registry.pastDueRampWeightBps(block.timestamp - p.anchorB);
        uint256 executable = vault.totalAssets();
        uint256 amount = mB2 < executable ? mB2 : executable;
        uint256 want = (amount * w + Config.BPS - 1) / Config.BPS;
        assertEq(
            defaultManager.pendingSeniorImpairment(), want, "with no junior capital left, the ramped mark is B alone"
        );
    }

    /// @dev Declare B: the attested cohort is full weight; the mark equals the executed burn.
    function _m2DeclareAndRealizeB(Pair memory p) internal returns (Layers memory sB) {
        _declare(p.b);
        uint256 dB = defaultManager.declaredDefaultedPrincipal(FILM);
        p.dB = dB;
        assertEq(dB, reserves.deployedTo(p.b), "B's declared contribution is its stopped face");
        assertEq(defaultManager.pastDueExposure(), 0, "B left the cohort at declaration");
        assertEq(defaultManager.pendingSeniorImpairment(), dB, "declared with no junior capital: full weight, exactly");
        sB = _realize(p.b, FILM, dB);
        assertEq(sB.absorbed, 0, "no pool left for B");
        assertEq(sB.covered, 0, "no reserve left for B");
        assertEq(sB.senior, dB, "B's whole face hit the senior vault: the mark at declaration was the burn");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "nothing left unrealised");
        emit log_named_uint("M2 dB (declared, full weight, executed burn)", dB);
    }

    // ─────────────────────────────────────────────────────────────────────
    // M3. the 100-facility envelope
    // ─────────────────────────────────────────────────────────────────────

    function test_multi_hundredFacilityEnvelope_capacityRefusalRetirementAndMaturitySweep() public onFork {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 1_000_000e18);
        uint256 t0 = block.timestamp;
        uint256 principal = 20_000e18;
        for (uint256 i = 1; i <= 100; ++i) {
            uint256 id = _fundIn(FILM, keccak256(abi.encode("BW", i)), principal);
            assertEq(id, i, "sequential ids");
        }
        assertTrue(reserves.accruedDebt(100).known, "the hundredth facility is in the book");

        // ── the 101st: origination succeeds (attestations consumed), funding is refused ──
        uint256 extra = _originate(FILM, keccak256("BW-101"), principal);
        assertEq(extra, 101, "the 101st NFT exists in Pending");
        vm.expectRevert(AccrualBook.AccrualBook_Capacity.selector);
        vm.prank(ops);
        waterfall.fund(extra, principal / 1e12);
        assertEq(uint8(bridge.facility(extra).state), uint8(ClaimBridge.LoanState.Pending), "still Pending");
        assertFalse(reserves.accruedDebt(extra).known, "not admitted to the book");
        vm.prank(ops);
        bridge.cancelPending(extra);
        assertEq(uint8(bridge.facility(extra).state), uint8(ClaimBridge.LoanState.Cancelled), "cancelled");

        // ── one full repayment retires a slot; a fresh origination can then be funded ──
        _repay(1, 0, principal);
        assertEq(uint8(bridge.facility(1).state), uint8(ClaimBridge.LoanState.Repaid), "facility 1 repaid");
        uint256 fresh = _fundIn(FILM, keccak256("BW-102"), principal);
        assertEq(fresh, 102, "the freed slot admits a new facility");
        assertTrue(reserves.accruedDebt(fresh).known, "admitted");

        // ── all one hundred live facilities mature at the same second ──
        // The planner ends each cap-approach segment ONE SECOND before the cap instant
        // (`AccrualSegments.plan`: `--capBoundary`) and installs a one-second successor, so one
        // hundred facilities maturing together are TWO HUNDRED boundaries: one hundred at T-1
        // (caught up from the past) and one hundred at T.
        _warpTo(t0 + TERM);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                AccrualBook.AccrualBook_BoundaryPending.selector, uint64(block.timestamp - 1), uint64(block.timestamp)
            )
        );
        vault.deposit(1e18, alice);
        vm.stopPrank();

        uint256 calls;
        uint256 totalProcessed;
        uint256 totalGas;
        bool fresh_;
        while (!fresh_) {
            uint256 g = gasleft();
            vm.prank(carol);
            (uint256 n, bool f) = reserves.checkpointAccrual(32);
            uint256 used = g - gasleft();
            fresh_ = f;
            totalProcessed += n;
            totalGas += used;
            ++calls;
            emit log_named_uint("checkpointAccrual(32) processed", n);
            emit log_named_uint("checkpointAccrual(32) gas", used);
            require(calls <= 10, "sweep did not converge");
            if (!fresh_) {
                // in between, every priced action stays refused
                vm.startPrank(alice);
                vm.expectRevert();
                vault.deposit(1e18, alice);
                vm.stopPrank();
            }
        }
        assertEq(totalProcessed, 200, "two boundaries per facility, one hundred facilities");
        assertEq(calls, 7, "six full batches of 32 and one of 8");
        emit log_named_uint("sweep total gas", totalGas);
        // Every facility recognised exactly one grid-floored 365-day coupon at 14% Actual/360.
        uint256 coupon = Math.mulDiv(principal * RATE_BPS, TERM, YEAR * 10_000 * SCALE) * SCALE;
        assertEq(coupon, 2_838_888_888_000_000_000_000, "the closed-form coupon");
        assertEq(reserves.accrualSnapshot().gross, 100 * coupon, "the book holds exactly one hundred coupons");
        assertFalse(reserves.accruedDebt(2).active, "matured facilities stopped");
        assertFalse(reserves.accruedDebt(fresh).active, "the replacement matured in the same second");

        // Service is restored by the permissionless sweep alone.
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1e18);
        vault.deposit(1e18, alice);
        vm.stopPrank();
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing holds at the envelope");
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @dev The conservative mark with NO declared cohort, no first-loss and no coverage: the whole
    ///      past-due cohort is the senior residual, clamped to the vault and ramped from the anchor.
    ///      The weight comes from `pastDueRampWeightBps`, which `conservativeSeniorMark` deliberately
    ///      does not call, so this is an independent derivation rather than a read-back.
    function _assertMarkIsTheClosedForm(uint256 anchor, string memory label) internal view {
        uint256 pds = defaultManager.pastDueExposure();
        uint256 executable = vault.totalAssets();
        uint256 amount = pds < executable ? pds : executable;
        uint256 w = registry.pastDueRampWeightBps(block.timestamp - anchor);
        uint256 want = (amount * w + Config.BPS - 1) / Config.BPS;
        assertEq(defaultManager.pendingSeniorImpairment(), want, string.concat(label, ": mark == closed form"));
        assertEq(
            vault.redemptionTotalAssets(),
            vault.totalAssets() - want,
            string.concat(label, ": exit base == total base - mark")
        );
    }

    function _originate(uint256 classId, bytes32 borrowerId, uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + TERM);
        bytes32 ref = keccak256(abi.encode("multi-r2-ref", tokenId));
        bytes32 stateId = classId == FILM ? keccak256("US-GA") : bytes32(0);
        ClaimBridge.OriginationTerms memory terms =
            _forkTermsFor(classId, borrowerId, stateId, principal, 7500, uint16(RATE_BPS), maturity, ref);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 id = bridge.originate(ops, terms);
        require(id == tokenId, "OPEN_multi_R2: tokenId drift");
    }

    function _fundIn(uint256 classId, bytes32 borrowerId, uint256 principal) internal returns (uint256 tokenId) {
        tokenId = _originate(classId, borrowerId, principal);
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);
    }

    function _declare(uint256 tokenId) internal {
        bytes32 evidenceHash = keccak256(abi.encode("multi-r2-d", tokenId));
        _attest(
            tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(tokenId, evidenceHash))
        );
        vm.prank(ops);
        defaultManager.declareDefault(tokenId, evidenceHash);
    }

    function _fundCoverage(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _postFirstLoss(uint256 classId, uint256 amount) internal {
        vm.startPrank(ops);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    /// @dev Runs `realizeLoss` and returns the observed (curator, sGROVE, senior) split from balance
    ///      deltas, asserting conservation and that no layer is reached before the one above it is empty.
    function _realize(uint256 tokenId, uint256 classId, uint256 loss) internal returns (Layers memory got) {
        uint256 poolBefore = curator.poolBalance(classId);
        uint256 reserveBefore = sGrove.coverageReserve();
        uint256 vaultBefore = vault.totalAssets();
        _realizeLoss(tokenId, loss, bytes32(0));
        got.absorbed = poolBefore - curator.poolBalance(classId);
        got.covered = reserveBefore - sGrove.coverageReserve();
        got.senior = vaultBefore - vault.totalAssets();
        assertEq(got.absorbed + got.covered + got.senior, loss, "the cascade allocates the loss exactly");
        if (got.covered != 0) assertEq(curator.poolBalance(classId), 0, "layer 2 only after layer 1 is empty");
        if (got.senior != 0) assertEq(sGrove.coverageReserve(), 0, "layer 3 only after layer 2 is empty");
    }

    /// @dev The RECORDED past-due contribution: the `pastDueContribution` view adds the facility's
    ///      own unposted stream on top of the recorded face, so the recorded part is the difference.
    function _recorded(uint256 id) internal view returns (uint256) {
        return defaultManager.pastDueContribution(id) - reserves.unpostedAccruedLoan(id);
    }

    function _warpTo(uint256 ts) internal {
        require(ts > block.timestamp, "OPEN_multi_R2: warp must move forward");
        _warp(ts - block.timestamp);
    }
}
