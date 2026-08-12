// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title SWEEP ROUND 3 — S3-F3, THE PAYMENT-EPISODE RELIEF CLOCK
/// @notice AUDIT FIX ACCEPTANCE SUITE. The G2W relief ramp (OWNER DECISION 2026-08-07) is a benefit
///         of the doubt extended to ONE delinquent payment episode, and its EXPIRY is the only
///         thing that bounds the D5-03 under-mark in TIME: "the loud stop returns on its own with
///         nobody having to act".
///
///         THE DEFECT. The expiry was measured from a single global cohort timestamp that re-armed
///         on any empty -> non-empty transition. `clearPastDue` (SERVICER_ROLE plus a
///         `PastDueCured` quorum — and finding A-02 records that the attester IS the servicer)
///         empties the cohort, and the very next PERMISSIONLESS `markPastDue` handed the whole
///         standing cohort its 50% relief back. The first remediation refused a fresh window to any
///         re-mark within one ramp of the emptying; that closed the immediate cycle and left the
///         SAME attack on a 42-day one, because a global timestamp cannot tell "this facility's
///         episode" from "the book happened to be quiet".
///
///         THE FIX UNDER TEST. The clock is keyed to the OBJECTIVE delinquent payment episode
///         `(tokenId, ClaimBridge.Facility.nextPaymentDue)`, recorded PERSISTENTLY per facility in
///         `DefaultManager.reliefEpisode` and surviving every clear, re-mark and partial
///         repayment. `pastDueReliefAnchor()` — the one scalar the pricing path reads, so the view
///         stays O(1) — is the MINIMUM over the live cohort's episode starts. Only an
///         authenticated servicing transition that ADVANCES `nextPaymentDue` opens a new episode.
///
///         WHY THE ASSERTIONS ARE ON `pendingSeniorImpairment()` AND `pastDueReliefAnchor()` AND
///         NOT ON A DEDICATED EPISODE GETTER: the getter was MEASURED at 159 runtime bytes and puts
///         `DefaultManager` three bytes over EIP-170, so it was not shipped (see the note in
///         `IDefaultManager`). `pastDueReliefAnchor()` IS the derived episode start the redemption
///         price is computed from, which is the number that has to be right.
contract SweepR3_ReliefEpisodeClock is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    /// @dev One `Config.DEFAULT_REDEEM_COOLDOWN`; the ramp length.
    uint256 internal constant RAMP = Config.DEFAULT_REDEEM_COOLDOWN;

    function _openLaunchRampLimitsForFilm() internal {
        vm.startPrank(admin);
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = Config.RAMP_CONCENTRATION_LIMIT_BPS;
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        registry.setStateLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Warps FORWARD to just past a facility's grace end. Never rewinds the clock: several of
    ///      these tests are already far past an earlier due date when they call it, and a `vm.warp`
    ///      backwards would silently invalidate every elapsed-time assertion after it.
    function _warpPastGraceForward(uint256 id) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint256 graceEnd = uint256(f.nextPaymentDue) + uint256(defaultManager.graceWindow(f.classId));
        if (block.timestamp <= graceEnd) vm.warp(graceEnd + 1);
    }

    function _mark(uint256 id) internal {
        vm.prank(carol); // a BYSTANDER: `markPastDue` is permissionless by design (H-5)
        defaultManager.markPastDue(id);
    }

    /// @dev Drives a facility's `nextPaymentDue` up to its `maturity` with ordinary attested
    ///      performing payments, so that a LATER partial repayment hits `WaterfallEngine`'s
    ///      `terminalDueNoOp` branch — the one reachable shape of "a real repayment arrived and the
    ///      due date did NOT advance". Bounded loop; asserts it actually arrived.
    function _driveDueToMaturity(uint256 id) internal {
        for (uint256 i = 0; i < 24; ++i) {
            ClaimBridge.Facility memory f = bridge.facility(id);
            if (f.nextPaymentDue == f.maturity) return;
            _repay(id, 1e18, 1e18);
        }
        revert("fixture: could not drive nextPaymentDue to maturity");
    }

    // ── ACCEPTANCE 1: same due date, clear and re-mark ────────────────────

    /// @notice THE HEADLINE PROPERTY. Clearing the mark and re-marking the SAME delinquent payment
    ///         episode must REUSE THE ORIGINAL RELIEF TIMESTAMP. The facility never cured, never
    ///         paid, and its `nextPaymentDue` never moved, so no new benefit of the doubt is owed.
    ///
    ///         MUTATION: make `markPastDue` write `block.timestamp` instead of `episode.startedAt`
    ///         into `$.pastDueReliefAnchor` -> RED here.
    function test_S5_episode_aClearAndReMarkOfTheSameDueDateReusesTheOriginalTimestamp() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGraceForward(id);

        _mark(id);
        uint256 firstMarkAt = block.timestamp;
        assertEq(defaultManager.pastDueReliefAnchor(), firstMarkAt, "episode one is anchored at its first mark");
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "and carries the governed half weight");

        // Ten days of the twenty-one elapse, then the servicer clears and a bystander re-marks.
        // NOTHING about the facility changed: same state, same principal, same nextPaymentDue.
        vm.warp(block.timestamp + 10 days);
        _clearPastDue(id, FILM_REF);
        assertEq(defaultManager.pastDueExposure(), 0, "cohort emptied");
        _mark(id);

        assertEq(
            defaultManager.pastDueReliefAnchor(),
            firstMarkAt,
            "S3-F3: the re-mark must REUSE the original episode timestamp, not restart it"
        );
        // w(10d/21d) = 5000 + 5000*10/21 = 7380 bps (integer floor); of 400,000 that is 295,200.
        // Written as a literal, NOT recomputed from the contract's own ramp view.
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            295_200e18,
            "the relief kept DECAYING across the clear; it did not reset to half weight"
        );

        // ...and the expiry still fires on the ORIGINAL schedule, eleven days later.
        vm.warp(firstMarkAt + RAMP);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "the loud stop returned on schedule");
    }

    /// @notice THE RESIDUAL THE FIRST REMEDIATION LEFT OPEN, AND THE TEST THAT DISCRIMINATES
    ///         BETWEEN THE TWO FIXES. A "must have stood clear for a full ramp" quarantine does not
    ///         fire here — the book stood clear for a full ramp — so under that design the SAME
    ///         never-cured facility is handed maximum relief again, for ever, on a 42-day cycle.
    ///         Under the episode clock the relief is spent and stays spent.
    function test_S5_episode_aFullRampOfQuietDoesNotBuyTheSameEpisodeAFreshWindow() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGraceForward(id);

        _mark(id);
        uint256 firstMarkAt = block.timestamp;

        for (uint256 i = 0; i < 4; ++i) {
            // Let the relief expire, clear the mark, and leave the book QUIET for a full ramp
            // before re-marking — the exact shape a "stood clear for one ramp" quarantine permits.
            vm.warp(block.timestamp + RAMP);
            _clearPastDue(id, keccak256(abi.encode("quiet-cycle", i)));
            assertEq(defaultManager.pastDueExposure(), 0, "cohort emptied");
            vm.warp(block.timestamp + RAMP);
            _mark(id);
            emit log_named_uint("cycle", i);
            emit log_named_uint("  days continuously past due", (block.timestamp - firstMarkAt) / 1 days);
            emit log_named_uint("  pendingSeniorImpairment", defaultManager.pendingSeniorImpairment());
            assertEq(defaultManager.pastDueReliefAnchor(), firstMarkAt, "the episode timestamp must never be rewound");
            assertEq(
                defaultManager.pendingSeniorImpairment(),
                400_000e18,
                "S3-F3: a quiet interval must not re-arm an episode whose relief is already spent"
            );
        }
    }

    // ── ACCEPTANCE 2: alternating facilities ──────────────────────────────

    /// @notice INDEPENDENT FACILITIES. A single resettable global timestamp cannot model two
    ///         facilities with different episodes; the per-facility record can. Alternating the
    ///         marks — including emptying the cohort entirely between them, and re-marking in the
    ///         opposite order — must never lift the cohort off the OLDEST live episode's clock.
    ///
    ///         MUTATION: drop the `|| uint256(episode.startedAt) < $.pastDueReliefAnchor` minimum
    ///         so a mark that joins a live cohort cannot ratchet the anchor back -> RED here.
    function test_S5_episode_alternatingTwoFacilitiesCannotRewindEitherClock() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 3_000_000e18);
        uint256 a = _liveFilmFacility(400_000e18);
        uint256 b = _liveFilmFacility(400_000e18);
        _warpPastGraceForward(a);

        _mark(a);
        uint256 episodeA = block.timestamp;

        // B's episode starts ten days later and joins a LIVE cohort: it inherits A's older clock.
        vm.warp(block.timestamp + 10 days);
        _mark(b);
        uint256 episodeB = block.timestamp;
        assertEq(defaultManager.pastDueReliefAnchor(), episodeA, "the younger episode joins at the older clock");
        assertEq(defaultManager.pastDueExposure(), 800_000e18, "both facilities are marked");

        // Empty the cohort completely, then re-mark in the OPPOSITE order. B goes first, so the
        // empty-cohort branch writes B's episode start; A's mark must then ratchet it back.
        _clearPastDue(a, keccak256("alt-a"));
        _clearPastDue(b, keccak256("alt-b"));
        assertEq(defaultManager.pastDueExposure(), 0, "cohort emptied");
        _mark(b);
        assertEq(defaultManager.pastDueReliefAnchor(), episodeB, "B alone stands on its own episode");
        _mark(a);
        assertEq(
            defaultManager.pastDueReliefAnchor(),
            episodeA,
            "S3-F3: A's older episode must ratchet the cohort clock BACK, whatever the mark order"
        );
        assertLt(episodeA, episodeB, "precondition: A's episode really is the older one");

        // Neither facility's relief outlives A's original ramp.
        vm.warp(episodeA + RAMP);
        assertEq(defaultManager.pendingSeniorImpairment(), 800_000e18, "full weight on the whole cohort");
    }

    // ── ACCEPTANCE 3: a partial repayment that does not advance the due date ──

    /// @notice A PARTIAL REPAYMENT IS NOT A NEW EPISODE unless it moves the due date. Money
    ///         arriving reduces the AMOUNT at risk (`onPerformingRepayment` re-anchors
    ///         `pastDueContribution` down) but says nothing about the missed payment that started
    ///         the clock, so it must not restart the relief.
    ///
    ///         THE SHAPE IS THE REACHABLE ONE, NOT A CONTRIVANCE: `WaterfallEngine.distribute`
    ///         skips `ClaimBridge.setNextPaymentDue` exactly on the terminal bullet leg
    ///         (`f.nextPaymentDue == f.maturity && payment.nextPaymentDue == f.maturity`), which is
    ///         precisely a delinquent facility dribbling principal at maturity.
    function test_S5_episode_aPartialRepaymentThatDoesNotAdvanceTheDueDateDoesNotRestartRelief() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _driveDueToMaturity(id);
        ClaimBridge.Facility memory f = bridge.facility(id);
        assertEq(f.nextPaymentDue, f.maturity, "precondition: the schedule is on its terminal leg");
        uint64 dueBefore = f.nextPaymentDue;

        _warpPastGraceForward(id);
        _mark(id);
        uint256 firstMarkAt = block.timestamp;
        uint256 atRiskBefore = defaultManager.pastDueContribution(id);

        vm.warp(block.timestamp + 10 days);
        _repay(id, 1e18, 100_000e18); // a real, attested, partial principal repayment

        assertEq(bridge.facility(id).nextPaymentDue, dueBefore, "precondition: the due date did NOT advance");
        assertLt(
            defaultManager.pastDueContribution(id), atRiskBefore, "the AMOUNT at risk was re-anchored down by the cash"
        );

        // Clear and re-mark: still the same episode, so still the same clock.
        _clearPastDue(id, keccak256("partial-repay"));
        _mark(id);
        assertEq(
            defaultManager.pastDueReliefAnchor(),
            firstMarkAt,
            "S3-F3: money that does not move the due date must not restart the relief clock"
        );
        vm.warp(firstMarkAt + RAMP);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            defaultManager.pastDueExposure(),
            "and the expiry fires on the ORIGINAL schedule, at full weight"
        );
    }

    // ── ACCEPTANCE 4: a genuine new payment episode ───────────────────────

    /// @notice RAMP-5, RE-KEYED TO THE SERVICING FACT. A repayment that ADVANCES `nextPaymentDue`
    ///         through the attested waterfall path is a genuinely new payment epoch: the facility
    ///         performed, and a LATER missed payment is a new delinquency owed its own benefit of
    ///         the doubt. This is the direction the fix must NOT break.
    ///
    ///         MUTATION: make the episode write-once (`if (episode.due == 0)`) -> RED here, and the
    ///         owner's RAMP-5 decision is silently deleted.
    function test_S5_episode_aGenuineNewPaymentEpisodeDoesRestartRelief() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGraceForward(id);

        _mark(id);
        uint256 firstMarkAt = block.timestamp;
        uint64 dueBefore = bridge.facility(id).nextPaymentDue;

        vm.warp(block.timestamp + RAMP);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "episode one's relief is spent");

        // The borrower performs: an attested payment arrives and the servicer advances the due
        // date. The mark is cleared by the ordinary cure path.
        _clearPastDue(id, keccak256("cured"));
        _repay(id, 1e18, 1e18);
        uint64 dueAfter = bridge.facility(id).nextPaymentDue;
        assertGt(dueAfter, dueBefore, "precondition: an authenticated servicing transition ADVANCED the due date");

        // ...and much later the facility misses THAT payment. New episode, new clock.
        vm.warp(uint256(dueAfter) + uint256(defaultManager.graceWindow(FILM)) + 400 days);
        _mark(id);
        assertEq(defaultManager.pastDueReliefAnchor(), block.timestamp, "a NEW episode is anchored at its own mark");
        assertGt(defaultManager.pastDueReliefAnchor(), firstMarkAt, "and it is not episode one's clock");
        // The repayment retired 1e18 of principal, so 399,999e18 remains at risk; 5,000 bps of
        // that is 199,999.5e18 exactly. Written as a literal, NOT recomputed from the contract's
        // own ramp view, so a mutation of the weight cannot slide the expectation with it.
        assertEq(defaultManager.pastDueExposure(), 399_999e18, "precondition: the at-risk principal net of the payment");
        assertEq(
            defaultManager.pendingSeniorImpairment(), 1_999_995e17, "the new episode gets the governed half weight back"
        );
    }

    // ── the monotonic watermark, pinned honestly ──────────────────────────

    /// @dev `DefaultManager.DefaultStorage.reliefEpisode`'s mapping base: the ERC-7201 root
    ///      `keccak256(abi.encode(uint256(keccak256("forestroad.storage.DefaultManager")) - 1)) &
    ///      ~bytes32(uint256(0xff))` plus the field's index in the struct. Both halves are pinned by
    ///      `contracts/storage-layout-compiled.json` (field `reliefEpisode`, slot 27) and by the two
    ///      storage gates, so a layout change breaks those gates before it can silently un-target
    ///      this test.
    uint256 private constant _DM_ROOT = 0x336a2060fa754acf2cdfdb8c351983bf3b455537ad219c0e1b705a95a2f8a200;
    uint256 private constant _RELIEF_EPISODE_SLOT = _DM_ROOT + 27;

    /// @notice THE WATERMARK IS MONOTONE: only an ADVANCE of `nextPaymentDue` opens a new episode.
    ///         The comparison is `>`, not `!=`, so a due date that moved BACKWARD reuses the older,
    ///         more-elapsed timestamp instead of buying a fresh relief window.
    ///
    ///         STATED HONESTLY: no production path reaches this today. `ClaimBridge` bounds
    ///         `setNextPaymentDue` by `nextDue > previous`, and `amendTerms` by
    ///         `a.nextPaymentDue > block.timestamp` — and a facility can only be MARKED (which is
    ///         the only thing that writes the watermark) while its due date is in the PAST, so an
    ///         amendment can only ever push it forward. This is therefore a DEFENCE-IN-DEPTH guard
    ///         against a future relaxation of that bound, and it is pinned by FABRICATING the state
    ///         with `vm.store` rather than by pretending a reachable path exists.
    ///
    ///         IT IS NOT VACUOUS. The fabricated record carries a SENTINEL `startedAt` that the
    ///         contract could not have written. If the slot arithmetic above ever stops addressing
    ///         the episode record, the anchor comes back as the real first-mark timestamp and this
    ///         test goes RED rather than silently passing on a write that landed nowhere.
    function test_S5_episode_aDueDateThatMovedBACKWARDCannotBuyAFreshWindow() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _warpPastGraceForward(id);

        _mark(id);
        uint64 due = bridge.facility(id).nextPaymentDue;
        _clearPastDue(id, keccak256("backward"));

        // Fabricate "the watermark already ratcheted to a LATER due date, and the facility's due
        // date has since moved back", with a sentinel start the contract never wrote.
        uint64 sentinelStart = uint64(block.timestamp - 5 days);
        uint64 raisedWatermark = due + 100 days;
        vm.store(
            address(defaultManager),
            keccak256(abi.encode(id, _RELIEF_EPISODE_SLOT)),
            bytes32((uint256(sentinelStart) << 64) | uint256(raisedWatermark))
        );

        _mark(id);
        assertEq(
            defaultManager.pastDueReliefAnchor(),
            uint256(sentinelStart),
            "S3-F3: a BACKWARD due date must reuse the older episode timestamp, never start a new one"
        );
    }
}
