// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ReserveAccrualCreditLib} from "../../src/libraries/ReserveAccrualCreditLib.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_DefaultManagerFork — adversarial suite against `DefaultManager` on a pinned mainnet
///        fork, on the REAL deploy topology with REAL USDC and the REAL 2-of-n EIP-712 oracle.
///
/// @notice AUTHORISED assessment of the owner's own pre-audit code on a LOCAL fork. Nothing here
///         broadcasts or moves real value.
///
///         This is an ATTACK suite, not a documentation suite. Each test drives a hostile actor
///         (`carol` — no role, not even KYC'd) or an out-of-context privileged actor at a real
///         entry point and makes the outcome unambiguous: where the attack is BLOCKED, it asserts
///         the exact custom error; where an operation genuinely runs, it asserts the state the
///         attacker was trying to violate did NOT change.
///
///         Two invariants are the target (CLAUDE.md 1.3):
///           (I1) The loss cascade runs curator first-loss -> sGROVE backstop -> sUSDfr senior,
///                and can never be skipped, inverted, or reached by an unauthorised actor.
///           (I2) A single default/loss EVENT cannot double-consume junior coverage.
///
///         The permissionless surface (`markPastDue`, `marginCall`, `clearMarginCall`,
///         `liquidate`) is attacked hardest. `absorbReserveLoss` and `drawForSeniorExit` are
///         nominally external but caller-identity-gated; the tests reach them from hostile and
///         out-of-context callers and prove the gate holds while junior capital sits untouched.
contract ATK_DefaultManagerForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // class 1, receivable

    // ─────────────────────────────────────────────────────────────────────
    // (I1) The junior-capital draw is unreachable by anyone but the controller
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `drawForSeniorExit` burns curator first-loss AND the sGROVE reserve forward through
    ///         the cascade. If any address could call it, an adversary would drain both junior
    ///         layers on demand (the cascade run BACKWARDS). Prove the caller gate holds against a
    ///         hostile actor and against a privileged-but-wrong actor, and that the seeded junior
    ///         capital is EXACTLY untouched by the rejected calls.
    function test_attack_drawForSeniorExit_refusesEveryCallerButTheController() public onFork {
        _postFirstLossOps(500_000e18); // layer 1
        _fundCoverageOps(1_000_000e18); // layer 2
        assertEq(curator.poolBalance(FILM), 500_000e18, "precondition: layer 1 seeded");
        assertEq(sGrove.coverageReserve(), 1_000_000e18, "precondition: layer 2 seeded");

        // hostile actor: no role, not KYC'd.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, carol)
        );
        defaultManager.drawForSeniorExit(2_000_000e18);

        // even the deployer/servicer/admin is not the controller — caller identity, not a role.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ExitDrawCallerNotController.selector, ops)
        );
        defaultManager.drawForSeniorExit(2_000_000e18);

        // The cascade could not be inverted: both junior layers sit exactly where they were.
        assertEq(curator.poolBalance(FILM), 500_000e18, "layer 1 untouched by the rejected draws");
        assertEq(sGrove.coverageReserve(), 1_000_000e18, "layer 2 untouched by the rejected draws");
    }

    /// @notice `absorbReserveLoss` moves all three capital layers for a classless custody loss. It
    ///         is reserve-only; a hostile actor (or an out-of-context admin) calling it must be
    ///         rejected before any pool is touched.
    function test_attack_absorbReserveLoss_refusesEveryCallerButTheReserve() public onFork {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, carol)
        );
        defaultManager.absorbReserveLoss(0, 1_000e18);

        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector, ops)
        );
        defaultManager.absorbReserveLoss(0, 1_000e18);
    }

    /// @notice The cascade ENTRY itself is role-gated. Even holding a genuine attested loss, a
    ///         caller without SERVICER_ROLE cannot realize a loss — so the adversary can neither
    ///         reach the cascade permissionlessly nor trigger it out of turn.
    function test_attack_realizeLoss_isUnreachableByAnUnprivilegedCaller() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(1_000_000e18);
        _declareDefault(id, keccak256("atk-acl"));

        bytes32 e = keccak256("atk-acl-loss");
        _attestLoss(id, 100_000e18, e);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.SERVICER_ROLE)
        );
        defaultManager.realizeLoss(id, 100_000e18, e);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (I2) A single loss event cannot double-consume coverage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Attack: realize a loss, then REPLAY the identical (tokenId, loss, evidence) to draw
    ///         the sGROVE reserve a second time for one economic event. The oracle consumes the
    ///         `LossRealized` fact on the first pass, so the replay must revert and NOTHING may
    ///         move. A DISTINCT attested event is still honoured — the guard blocks replay, not all
    ///         further losses.
    function test_attack_realizeLoss_cannotDoubleConsumeTheSameLossAttestation() public onFork {
        _mintFromUSDC(alice, 3_000_000e6); // idle liquidity to fund the facility
        _fundCoverageOps(1_000_000e18); // layer-2 reserve to draw

        uint256 id = _originateAndFund(2_000_000e18);
        _declareDefault(id, keccak256("atk-default"));

        uint256 loss = 100_000e18;
        bytes32 e1 = keccak256("atk-loss-1");
        _attestLoss(id, loss, e1);
        vm.prank(ops);
        defaultManager.realizeLoss(id, loss, e1);

        uint256 consumedAfterFirst = defaultManager.liveDefaultCoverageConsumed();
        uint256 reserveAfterFirst = sGrove.coverageReserve();
        uint256 contributionAfterFirst = defaultManager.defaultedContribution(id);
        assertEq(consumedAfterFirst, loss, "the first realization drew layer 2 for the whole loss");

        // REPLAY the same attested event: the fact was consumed, so it must revert.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_DefaultNotAttested.selector, id));
        defaultManager.realizeLoss(id, loss, e1);

        // Blocked replay moved nothing: coverage cannot be consumed twice for one event.
        assertEq(defaultManager.liveDefaultCoverageConsumed(), consumedAfterFirst, "no extra coverage on replay");
        assertEq(sGrove.coverageReserve(), reserveAfterFirst, "layer-2 reserve unchanged on replay");
        assertEq(defaultManager.defaultedContribution(id), contributionAfterFirst, "contribution unchanged on replay");

        // A genuinely distinct attested loss event is still honoured.
        bytes32 e2 = keccak256("atk-loss-2");
        _attestLoss(id, loss, e2);
        vm.prank(ops);
        defaultManager.realizeLoss(id, loss, e2);
        assertEq(
            defaultManager.liveDefaultCoverageConsumed(),
            consumedAfterFirst + loss,
            "a fresh attested event consumes fresh coverage exactly once"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless `markPastDue`: attacked hardest
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE HEADLINE ATTACK (compose ops out of order). `markPastDue` is permissionless and
    ///         starts a G2W relief ramp that lightens the conservative senior mark for one payment
    ///         episode. If a bystander could rewind that ramp by clearing and RE-marking the same
    ///         still-delinquent facility, the cohort would sit at maximum relief forever: an
    ///         UNDER-mark, so seniors exiting inside the perpetual window would take value from
    ///         seniors who stay. The S3-F3 fix keys the clock to the payment episode, not to
    ///         whichever mark found the cohort empty. Prove the anchor reuses the ORIGINAL episode
    ///         start after a clear-and-re-mark and is not rewound to now.
    ///
    ///         The at-risk face this test pins is the ADR-0038 face, not the funded principal.
    ///         `ADR/0038-continuous-interest-accrual-to-susdfr.md`, decisions table Q1 ("Full face.
    ///         Backing grows with accrual at 100%") and Q2 (accrual stops "At default declaration.
    ///         Not at the past-due mark. Accrual continues through the entire pre-declaration
    ///         window"), and its heading "Loss-bearing cash and PIK without changing the contractual
    ///         basis" ("the lifecycle posts all earned interest before a default or loss"), together
    ///         with `docs/remediation/CONTINUOUS_ACCRUAL_DESIGN_PANEL_2026-09-10.md` lines 120 to 128
    ///         ("Past-due cohorts continue earning and need dynamic conservative-risk accounting
    ///         until declaration"), require the mark to post every wei the book has streamed into
    ///         the recorded face first and the pool to carry principal PLUS that interest. The
    ///         figures are derived in `_fixtureBookSlope` from the engine's own construction
    ///         (`ReserveAccrualLib.loanCeiling`, `AccrualSegments.plan`, `AccrualMath.periodAmount`,
    ///         `AccrualBook.open`), so the (I2) "counted exactly once" property is asserted against
    ///         an independently computed face: a defect that inflates the pool and `deployedTo`
    ///         together (refuter mutation M8, `_post` double-counting) still fails here. The posting
    ///         and the mark are pinned as ordered events, and posting is asserted backing-neutral
    ///         (a reclassification of earned backing, never a creation).
    function test_attack_markPastDue_reliefClockCannotBeRewoundByClearAndReMark() public onFork {
        _mintFromUSDC(alice, 3_000_000e6); // idle liquidity to fund
        uint64 fundedAt = uint64(block.timestamp);
        uint256 id = _originateAndFund(2_000_000e18);
        assertEq(reserves.deployedTo(id), 2_000_000e18, "precondition: full principal at risk, nothing streamed yet");
        (uint256 slope, uint64 nextDue) = _pinAdr0038Slope(id, fundedAt);

        // Run past the first payment plus the 21-day grace window.
        _warp(60 days);
        uint256 atRisk = _pinAdr0038FaceAt60Days(id, slope);
        uint256 backingBefore = reserves.totalBackingValue();
        assertEq(backingBefore, reserves.idleReserve() + atRisk, "backing = idle + the earning face");

        // STEP 1: a bystander flags it past due (the protocol's own self-healing act). The mark
        // posts the whole stream into the recorded face BEFORE recording the pool (ordered events).
        uint256 firstMarkTime = block.timestamp;
        _expectPostThenMark(id, slope * 60 days, atRisk, nextDue);
        vm.prank(carol);
        defaultManager.markPastDue(id);
        uint256 firstAnchor = defaultManager.pastDueReliefAnchor();
        assertEq(firstAnchor, firstMarkTime, "the relief clock anchors at the first mark");
        _assertPoolIsTheLiveFace(id, atRisk);
        assertEq(
            reserves.totalBackingValue(), backingBefore, "posting is backing-neutral: a reclassification, not a mint"
        );

        // Idempotence: a second mark cannot double-count the pool.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_AlreadyPastDue.selector, id));
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueExposure(), atRisk, "the refused replay left the pool exactly where it was");

        // The servicer cures the mark, emptying the cohort. Nothing streamed since the post.
        _clearPastDueOps(id, keccak256("atk-cure"));
        assertEq(defaultManager.pastDueExposure(), 0, "the cohort is empty after the cure");
        assertEq(reserves.deployedTo(id), atRisk, "the cure does not change the recorded face");

        // Time passes but the payment due date is NOT advanced (no repayment, no amendment). Under
        // ADR-0038 Q2 the facility keeps earning at the same slope after the mark and the cure.
        _warp(5 days);
        assertGt(block.timestamp, firstAnchor, "wall-clock has moved past the original anchor");
        uint256 atRiskRemark = atRisk + slope * 5 days;
        assertEq(slope * 5 days, 3_888_888_888_877_501_248_000, "five more days at the integer slope");
        assertEq(atRiskRemark, 2_050_555_555_555_407_516_224_000, "ADR-0038 at-risk face at the re-mark");
        assertEq(reserves.deployedTo(id), atRiskRemark, "the face kept streaming after the cure");
        assertEq(reserves.unpostedAccruedLoan(id), slope * 5 days, "exactly the five days is unposted");

        // STEP 2: re-mark the SAME delinquent episode. The rewind must be unreachable, and the
        // re-mark posts only the five days streamed since the cure (never the first 60 again).
        _expectPostThenMark(id, slope * 5 days, atRiskRemark, nextDue);
        vm.prank(carol);
        defaultManager.markPastDue(id);

        assertEq(
            defaultManager.pastDueReliefAnchor(),
            firstAnchor,
            "S3-F3: the anchor reuses the original episode start; the clear-and-re-mark rewind is blocked"
        );
        assertTrue(defaultManager.pastDueReliefAnchor() != block.timestamp, "the relief clock was NOT rewound to now");
        _assertPoolIsTheLiveFace(id, atRiskRemark);
    }

    /// @notice `markPastDue` on a performing, not-yet-past-due facility must be refused with the
    ///         exact grace-end boundary — an adversary cannot depress the conservative senior NAV
    ///         of a healthy facility.
    function test_attack_markPastDue_refusesAFacilityThatIsNotYetPastDue() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(1_000_000e18);

        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 graceEnd = f.nextPaymentDue + defaultManager.graceWindow(FILM);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DefaultManager_NotPastDue.selector, id, f.nextPaymentDue, graceEnd)
        );
        defaultManager.markPastDue(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless margin path cannot be turned against a receivable facility
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The permissionless margin triggers exist ONLY for marked-to-market collateral, where
    ///         the attested mark is the whole evidence. An adversary must not be able to point them
    ///         at a receivable facility (film/UCC classes) to freeze or liquidate it out of band.
    function test_attack_marginPathIsRefusedOnAReceivableFacility() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        uint256 id = _originateAndFund(1_000_000e18); // FILM = receivable

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.marginCall(id);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.liquidate(id);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.DefaultManager_NotMarkedToMarket.selector, id));
        defaultManager.clearMarginCall(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this file; the shared fixture is untouched)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Seed the sGROVE (layer-2) reserve from `ops`, minting the USDfr first through the real
    ///      KYC-gated path. Coverage funding is permissionless.
    function _fundCoverageOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / 1e12 + 50_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(sGrove), usdfrAmount);
        sGrove.fundCoverage(usdfrAmount);
        vm.stopPrank();
    }

    /// @dev Post curator first-loss (layer 1) for FILM as the anchor curator (`ops`).
    function _postFirstLossOps(uint256 usdfrAmount) internal {
        _mintFromUSDC(ops, usdfrAmount / 1e12 + 50_000e6);
        vm.startPrank(ops);
        usdfr.approve(address(curator), usdfrAmount);
        curator.postFirstLoss(FILM, usdfrAmount);
        vm.stopPrank();
    }

    /// @dev Servicer cure of a past-due mark: attest the exact `PastDueCured` fact, then clear it.
    function _clearPastDueOps(uint256 tokenId, bytes32 evidence) internal {
        _attest(tokenId, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(tokenId, evidence)));
        vm.prank(ops);
        defaultManager.clearPastDue(tokenId, evidence);
    }

    /// @dev Closed-form reconstruction of the accrual book's integer per-second slope for the
    ///      fixture note (cash, fixed `rateBps`, Actual/360, funded at t0 with maturity t0 + T),
    ///      following the engine's construction step by step so the figures the tests pin are
    ///      derived rather than pasted (ADR-0038; `AccrualBook.sol` NatSpec: "Segment slopes are
    ///      integer normalized wei per second"; `AccrualMath.sol` NatSpec: interpolating the grid
    ///      floored endpoint "differs by strictly less than one unit" from the instantaneous curve).
    ///        1. `ReserveAccrualLib.loanCeiling`: the cash ceiling is principal plus the full-term
    ///           simple interest floored to the 1e12 reserve grid, so cap = floor(P*r*T / (10_000 *
    ///           360 days * 1e12)) * 1e12.
    ///        2. `AccrualSegments.plan`: the cap is reachable exactly at capHit = ceil(cap * 10_000 *
    ///           360 days / (P*r)) seconds, which is T here; the planner ends the first technical
    ///           segment one second earlier, at T - 1.
    ///        3. `AccrualMath.periodAmount`: the segment amount is the simple interest at T - 1,
    ///           floored to the grid.
    ///        4. `AccrualBook.open`: the slope is the integer quotient amount / (T - 1).
    function _fixtureBookSlope(uint256 principal, uint256 rateBps, uint64 termSeconds)
        internal
        pure
        returns (uint256 slope, uint256 cap, uint64 segmentSeconds, uint256 segmentAmount)
    {
        uint256 denominator = 10_000 * 360 days; // bps and Actual/360 year, in seconds
        uint256 scale = 1e12; // Ethereum USDC reserve grid, in USDfr wei
        cap = (principal * rateBps * termSeconds / denominator) / scale * scale;
        uint64 capHit = uint64(Math.ceilDiv(cap * denominator, principal * rateBps));
        assertEq(capHit, termSeconds, "the cap is reachable exactly at maturity for this note");
        segmentSeconds = capHit - 1;
        segmentAmount = (principal * rateBps * segmentSeconds / denominator) / scale * scale;
        slope = segmentAmount / segmentSeconds;
    }

    /// @dev Derive the fixture note's ADR-0038 slope from the facility's own signed terms and pin
    ///      every intermediate figure to its literal, so neither side of any comparison is a magic
    ///      number. Returns the slope and the note's first payment date (the `PastDueMarked` field).
    function _pinAdr0038Slope(uint256 id, uint64 fundedAt) internal view returns (uint256 slope, uint64 nextDue) {
        ClaimBridge.Facility memory f = bridge.facility(id);
        assertEq(f.interestRateBps, 1400, "fixture note: fixed 1400 bps");
        assertEq(f.maturity, fundedAt + 365 days, "fixture note: one 365-day term");
        nextDue = f.nextPaymentDue;
        uint256 principal = f.principal;
        uint256 cap;
        uint64 segmentSeconds;
        uint256 segmentAmount;
        (slope, cap, segmentSeconds, segmentAmount) =
            _fixtureBookSlope(principal, f.interestRateBps, f.maturity - fundedAt);
        assertEq(
            reserves.accruedDebt(id).balanceCeiling, principal + cap, "the derived cap is the engine's reservation"
        );
        assertEq(cap, 283_888_888_888e12, "cap: full-term simple interest floored to the 1e12 reserve grid");
        assertEq(segmentSeconds, 365 days - 1, "the planner ends the first technical segment one second before the cap");
        assertEq(segmentAmount, 283_888_879_886e12, "segment amount: simple interest at T-1, floored to the grid");
        assertEq(slope, 9_002_057_613_142_364, "integer wei-per-second slope: segmentAmount / segmentSeconds");
        // The two floors the book applies, pinned exactly. Pro rata over 60 days they are
        // 136,648,067,921.7 wei and 3,622,744.9 wei: together the 136,651,690,666 wei shortfall
        // that `_pinAdr0038FaceAt60Days` asserts.
        assertEq(
            principal * f.interestRateBps * segmentSeconds / (10_000 * 360 days) - segmentAmount,
            831_275_720_164,
            "grid floor dropped at the segment endpoint"
        );
        assertEq(segmentAmount % segmentSeconds, 22_038_364, "integer-slope truncation across the segment");
    }

    /// @dev At 60 days the book has streamed `slope * 60 days`; pin that against the closed-form
    ///      Actual/360 figure (the book sits exactly 136,651,690,666 wei below it, conservative for
    ///      backing) and against what the reserve reports before the mark. Returns the ADR-0038
    ///      at-risk face, principal plus the streamed interest.
    function _pinAdr0038FaceAt60Days(uint256 id, uint256 slope) internal view returns (uint256 atRisk) {
        uint256 principal = bridge.facility(id).principal;
        uint256 streamed60 = slope * 60 days;
        uint256 closedForm60 = principal * bridge.facility(id).interestRateBps * 60 days / (10_000 * 360 days);
        assertEq(streamed60, 46_666_666_666_530_014_976_000, "60 days at the integer slope");
        assertEq(closedForm60, 46_666_666_666_666_666_666_666, "closed-form Actual/360 interest for 60 days");
        assertEq(
            closedForm60 - streamed60, 136_651_690_666, "the book streams below closed form by exactly the two floors"
        );
        atRisk = principal + streamed60;
        assertEq(
            atRisk, 2_046_666_666_666_530_014_976_000, "ADR-0038 Q1 at-risk face: principal plus streamed interest"
        );
        assertEq(reserves.deployedTo(id), atRisk, "deployedTo already carries the unposted stream before the mark");
        assertEq(reserves.unpostedAccruedLoan(id), streamed60, "and all of it is still unposted");
    }

    /// @dev The mark must first post exactly `posted` into the recorded face (`AccruedLoanPosted`
    ///      from the reserve, ADR-0038 "posts all earned interest before a default or loss") and
    ///      only then record `face` into the pool (`PastDueMarked`). Both events are pinned in
    ///      that order with full data.
    function _expectPostThenMark(uint256 id, uint256 posted, uint256 face, uint64 nextDue) internal {
        vm.expectEmit(true, true, true, true, address(reserves));
        emit ReserveAccrualCreditLib.AccruedLoanPosted(id, USDC, posted, face);
        vm.expectEmit(true, true, true, true, address(defaultManager));
        emit IDefaultManager.PastDueMarked(id, FILM, nextDue, face);
    }

    /// @dev After a mark every module must carry ONE face: nothing unposted remains, and the
    ///      facility contribution, the class pool, the global pool and the registry all equal the
    ///      reserve's recorded face, which is pinned by the caller to the derived figure.
    function _assertPoolIsTheLiveFace(uint256 id, uint256 face) internal view {
        assertEq(reserves.unpostedAccruedLoan(id), 0, "the mark posted every streamed wei");
        assertEq(reserves.deployedTo(id), face, "the recorded face is the ADR-0038 face");
        assertEq(
            defaultManager.pastDueExposure(), face, "the at-risk face entered the past-due pool, counted exactly once"
        );
        assertEq(defaultManager.pastDueContribution(id), face, "counted once for this facility");
        assertEq(defaultManager.pastDuePrincipal(FILM), face, "the class pool carries the same face");
        assertEq(registry.classExposure(FILM), face, "the registry carries the same face");
    }
}
