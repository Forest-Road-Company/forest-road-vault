// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {ICommitmentLedger} from "../../src/interfaces/ICommitmentLedger.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";

/// @title UNDRAWN_LIMB_FALSIFIER — two-sided cascade/NAV grading across event partitions
///
/// @notice ADR-0035 DISPOSITION. This suite originally distinguished capped drawn and undrawn
///         cohorts. The owner decision removes the hidden snapshot state that made identical
///         aggregate books deliver different amounts. Its active tests are deliberately retained
///         and re-pointed: they execute both realization orders on the real SGrove and require the
///         production credit to remain within that measured band. Under one uncapped shared
///         reserve the band collapses to a point, and event count, draw status, principal
///         partition, and declaration order cannot change aggregate layer-two delivery.
///
/// @dev The executed oracle (`_deliverable`) remains independent of the impairment calculator.
///      `_ladder` reconstructs only physical cascade steps from remaining principal and reserve;
///      `_requireLedgerSeesEveryEvent` separately proves the production ledger did not omit or
///      reorder an event. The historical PREV/W6 formulas and their capped-tree measurements
///      remain reviewable in Git history and the dated remediation evidence; they are not current
///      ADR-0035 expectations.
///
///         RUN IT:
///           cp UNDRAWN_LIMB_FALSIFIER.t.sol <tree>/contracts/test/audit/
///           cd <tree>/contracts && set -a && . ../.env && set +a
///           forge test --match-path 'test/audit/UNDRAWN_LIMB_FALSIFIER.t.sol' -vv
///
///         It is STANDALONE — it does not inherit `F1BlastRadiusBase`. That is deliberate: the
///         reference model in a modified copy of `F1_BlastRadius.t.sol` cannot change this
///         file's verdict.
abstract contract UndrawnLimbBase is ProductionCreditFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    /// @dev A DISTINCT evidence hash for the executed oracle. The attested `LossRealized` fact is
    ///      `keccak256(abi.encode(tokenId, loss, evidenceHash))` and is single-use, so re-using
    ///      `FILM_REF` would collide with `Oracle_FactAlreadyRealised` and silently truncate the
    ///      cascade to a smaller "deliverable" — an artefact that would look like a defect.
    bytes32 internal constant ORACLE_REF = keccak256("undrawn-limb-falsifier-exhaustion");

    /// @dev Tolerance applied to BOTH band edges. Eleven orders of magnitude below the ~1e23
    ///      discrepancies this file exists to detect, so it cannot mask one; it exists only for
    ///      integer-division dust in the surrounding cascade.
    uint256 internal constant BAND_DUST = 1e12;

    /// @dev Live default token ids for the current scenario, in DECLARATION order.
    uint256[] internal evIds;

    // ══════════════════════════════════════════════════════════════════════
    //  SCENARIO PRIMITIVES
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Registry ORIGINATION gates only. Nothing in `ConservativeImpairmentMath` or
    ///      `CollateralRegistry.conservativeSeniorMark` reads them, so opening them cannot move a
    ///      graded number; it only lets a scenario express the cohort SHAPE it needs.
    function _openLimits() internal {
        vm.startPrank(admin);
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = Config.RAMP_CONCENTRATION_LIMIT_BPS;
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        registry.setStateLimit(Config.RAMP_CONCENTRATION_LIMIT_BPS);
        vm.stopPrank();
    }

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.approve(address(sGrove), amount);
        vm.prank(bob);
        sGrove.fundCoverage(amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Originates, funds and DECLARES a film default through ordinary `SERVICER_ROLE` with a
    ///      genuine 2-of-n EIP-712 attestation. No privilege abuse anywhere in this file.
    function _defaulted(bytes32 borrower, uint256 principal) internal returns (uint256 id) {
        _mintUSDfrTo(alice, principal);
        id = _originateFilm(borrower, STATE_GA, principal);
        _fundFacility(id, principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        evIds.push(id);
    }

    /// @dev A realization marks the ledger row drawn and consumes the one shared reserve after
    ///      curator first-loss.
    function _realize(uint256 tokenId, uint256 loss) internal {
        _attestLoss(tokenId, loss, FILM_REF);
        vm.prank(servicer);
        defaultManager.realizeLoss(tokenId, loss, FILM_REF);
    }

    /// @dev ADR-0035 compatibility reconstruction: `cap - drawn` is the current shared reserve
    ///      for every event, whether or not that event has drawn.
    function _roomAt(uint256 eventId) internal view returns (uint256) {
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(eventId);
        return cap > drawn ? cap - drawn : 0;
    }

    function _hasDrawn(uint256 eventId) internal view returns (bool) {
        (uint256 drawn,) = sGrove.eventCoverage(eventId);
        return drawn != 0;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE EXECUTED ORACLE — ground truth, obtained by running the cascade
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Runs every live event to exhaustion inside a snapshot and measures what physically
    ///      LEAVES the backstop. Computed by EXECUTION, so it cannot be wrong in the same
    ///      direction as the code under test. `forward` = declaration order; `reverse` = its
    ///      mirror, which is what makes the order effect observable.
    function _deliverable(bool forward) internal returns (uint256 delivered) {
        uint256 snap = vm.snapshotState();
        uint256 before = usdfr.balanceOf(address(sGrove));
        uint256 n = evIds.length;
        for (uint256 k = 0; k < n; ++k) {
            uint256 id = forward ? evIds[k] : evIds[n - 1 - k];
            if (defaultManager.defaultedContribution(id) == 0) continue;
            uint256 amount = reserves.deployedTo(id);
            if (amount == 0) continue;
            _attestLoss(id, amount, ORACLE_REF);
            vm.prank(servicer);
            try defaultManager.realizeLoss(id, amount, ORACLE_REF) {}
            catch {
                // NEVER SILENT (CLAUDE.md prime directive 4). A refused realization would clip the
                // oracle low and manufacture a false OVER-credit verdict, so it is shouted.
                console2.log(string.concat("UNDRAWN-ORACLE-NOTE realizeLoss reverted for id ", Strings.toString(id)));
            }
        }
        uint256 after_ = usdfr.balanceOf(address(sGrove));
        delivered = before >= after_ ? before - after_ : 0;
        vm.revertToState(snap);
    }

    function _bandLo() internal returns (uint256) {
        uint256 f = _deliverable(true);
        uint256 r = _deliverable(false);
        return f < r ? f : r;
    }

    function _bandHi() internal returns (uint256) {
        uint256 f = _deliverable(true);
        uint256 r = _deliverable(false);
        return f > r ? f : r;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE ARITHMETIC LADDER — a computable model of the same cascade
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The cascade, SIMULATED rather than executed, from each event's residual principal and
    ///      the live shared reserve. `test_satisfiable_*` asserts that this reproduces
    ///      `_deliverable` exactly in both orders, making the band a reachable physical target.
    function _ladder(bool forward) internal view returns (uint256 delivered) {
        uint256 reserve = sGrove.coverageReserve();
        uint256 n = evIds.length;
        for (uint256 k = 0; k < n; ++k) {
            uint256 id = forward ? evIds[k] : evIds[n - 1 - k];
            uint256 principal = defaultManager.defaultedContribution(id);
            if (principal == 0) continue;
            uint256 room = reserve;
            uint256 take = principal < room ? principal : room;
            if (take > reserve) take = reserve;
            delivered += take;
            reserve -= take;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PRECONDITIONS — what makes a red ATTRIBUTABLE
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Common to every scenario. Layer 1 empty and no past-due cohort, so
    ///      `performanceFeeImpairment - pendingSeniorImpairment` is exactly the LAYER-2 credit;
    ///      and the REAL `SGrove` is the backstop, not `MockCascadeBackstop`; this keeps the
    ///      physical reserve movement and production event view inside the measured arm.
    function _requireCleanMeasure(string memory s) internal view {
        assertEq(
            curator.poolBalance(FILM), 0, string.concat(s, ": layer 1 must be empty for the measure to be layer 2")
        );
        assertEq(defaultManager.pastDuePrincipal(FILM), 0, string.concat(s, ": no unattested past-due cohort"));
        assertEq(
            address(defaultManager.backstop()), address(sGrove), string.concat(s, ": the REAL SGrove must be wired")
        );
    }

    /// @dev GROUP A. No event has ever drawn, so the drawn limb contributes nothing and cannot be
    ///      blamed for a red.
    function _requireUndrawnLimbIsolated(string memory s) internal view {
        assertEq(defaultManager.drawnDefaultPrincipal(FILM), 0, string.concat(s, ": drawn cohort must be empty"));
        assertEq(defaultManager.liveDefaultCoverageRemaining(), 0, string.concat(s, ": no committed drawn room"));
    }

    /// @dev ADR-0035/W7 composition precondition: every live event, drawn or undrawn, is present
    ///      in declaration order with the principal and draw flag the calculator must consume.
    function _requireLedgerSeesEveryEvent(string memory s) internal view {
        (,,,,,,, address ledgerAddress) = defaultManager.modules();
        ICommitmentLedger ledger = ICommitmentLedger(ledgerAddress);
        assertEq(ledger.eventCount(), evIds.length, string.concat(s, ": ledger row count drift"));
        for (uint256 i = 0; i < evIds.length; ++i) {
            uint256 id = evIds[i];
            assertEq(ledger.eventAt(i), id, string.concat(s, ": declaration order drift"));
            (uint256 classId, bool drawn,, uint256 remainingPrincipal) = ledger.eventInfo(id);
            assertEq(classId, FILM, string.concat(s, ": class metadata drift"));
            assertEq(drawn, _hasDrawn(id), string.concat(s, ": drawn metadata drift"));
            assertEq(
                remainingPrincipal,
                defaultManager.defaultedContribution(id),
                string.concat(s, ": remaining principal drift")
            );
        }
        assertEq(sGrove.coverageCapacity(), sGrove.coverageReserve(), string.concat(s, ": capacity is not reserve"));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  THE GRADE
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The layer-2 credit the conservative NAV hands the senior tranche.
    ///      `performanceFeeImpairment()` is the GROSS declared + past-due principal: it reads no
    ///      backstop and no clamp, so the subtraction is exactly the junior credit.
    function _credited() internal view returns (uint256) {
        return defaultManager.performanceFeeImpairment() - defaultManager.pendingSeniorImpairment();
    }

    /// @dev THE TWO-SIDED ASSERTION. Both edges, always. A gate that checks one edge is the gate
    ///      that certified an over-correction the first time.
    function _assertInBand(string memory s) internal {
        uint256 credited = _credited();
        uint256 lo = _bandLo();
        uint256 hi = _bandHi();
        console2.log(
            string.concat(
                "UNDRAWN ",
                s,
                " credited=",
                Strings.toString(credited),
                " band=[",
                Strings.toString(lo),
                ",",
                Strings.toString(hi),
                "]"
            )
        );
        assertGe(
            credited,
            lo > BAND_DUST ? lo - BAND_DUST : 0,
            string.concat(
                "D1 MIRROR / UNDER-CREDIT: ",
                s,
                " - the NAV credits layer 2 LESS than the cascade delivers in its WORST realization"
                " order. That OVER-marks the impairment and underprices the senior exit, paying the"
                " stayers out of the exiting holder."
            )
        );
        assertLe(
            credited,
            hi + BAND_DUST,
            string.concat(
                "F1 / OVER-CREDIT: ",
                s,
                " - the NAV credits layer 2 MORE than the cascade delivers in its BEST realization"
                " order. That UNDER-marks the impairment and overprices the senior exit, paying the"
                " exiting holder out of the stayers."
            )
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SCENARIOS
    // ══════════════════════════════════════════════════════════════════════
    //
    //  GROUP A — PURE UNDRAWN. `drawnResidual == 0`, `liveDefaultCoverageRemaining == 0`.
    //  Every scenario presents the same aggregate reads and must deliver the same 400,000e18
    //  shared reserve regardless of event count or principal partition.

    /// @dev ONE undrawn event. Executed band: [400,000e18, 400,000e18].
    function _aOneUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        _defaulted(keccak256("u1"), 600_000e18);
    }

    /// @dev TWO undrawn events, same aggregates. Executed band remains
    ///      [400,000e18, 400,000e18].
    function _aTwoUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        _defaulted(keccak256("u1"), 300_000e18);
        _defaulted(keccak256("u2"), 300_000e18);
    }

    /// @dev THREE undrawn events, same aggregates. Executed band remains
    ///      [400,000e18, 400,000e18].
    function _aThreeUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        _defaulted(keccak256("u1"), 200_000e18);
        _defaulted(keccak256("u2"), 200_000e18);
        _defaulted(keccak256("u3"), 200_000e18);
    }

    /// @dev TWO undrawn events, same aggregates, LUMPY split (590,000 + 10,000). Executed band
    ///      remains [400,000e18, 400,000e18], pinning partition and order independence.
    function _aTwoUndrawnLumpy() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        _defaulted(keccak256("u1"), 590_000e18);
        _defaulted(keccak256("u2"), 10_000e18);
    }

    //  GROUP B — MIXED. One drawn event plus undrawn events. Every row must be present in the
    //  ledger while draw status remains irrelevant to access to the shared reserve.

    /// @dev One drawn + ONE undrawn. The point band equals the 390,000e18 live reserve.
    function _bOneDrawnOneUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        _defaulted(keccak256("u1"), 300_000e18);
    }

    /// @dev One drawn + TWO undrawn. The point band remains 390,000e18.
    function _bOneDrawnTwoUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        _defaulted(keccak256("u1"), 200_000e18);
        _defaulted(keccak256("u2"), 200_000e18);
    }

    /// @dev One drawn + THREE undrawn. The point band remains 390,000e18.
    function _bOneDrawnThreeUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 1_400_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        _defaulted(keccak256("u1"), 200_000e18);
        _defaulted(keccak256("u2"), 200_000e18);
        _defaulted(keccak256("u3"), 200_000e18);
    }

    /// @dev One drawn + one small undrawn principal. Aggregate principal still exceeds the live
    ///      reserve, so the point band is 390,000e18.
    function _bSmallUndrawnPrincipal() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        _defaulted(keccak256("u1"), 30_000e18);
    }

    /// @dev COHORT MIGRATION. `u1` is declared undrawn and then takes a 1,000e18 realization while
    ///      `u2` stays undrawn. Both statuses still reach the same remaining 389,000e18 reserve.
    function _bPartiallyRealizedUndrawn() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        uint256 u1 = _defaulted(keccak256("u1"), 200_000e18);
        _defaulted(keccak256("u2"), 200_000e18);
        _realize(u1, 1_000e18);
    }

    //  GROUP C — ADR-0035 CAPACITY IDENTITY AT TWO RESERVE SCALES.

    /// @dev A 400,000e18 shared reserve is fully live under ADR-0035.
    function _cLargeReserveIdentity() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(400_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        _defaulted(keccak256("u1"), 200_000e18);
        _defaulted(keccak256("u2"), 200_000e18);
    }

    /// @dev The same cohort against a smaller 80,000e18 reserve pins that the identity is not a
    ///      fixture-specific constant and that no retired ratio remains in the calculation.
    function _cSmallReserveIdentity() internal {
        _openLimits();
        _stakeVault(alice, 900_000e18);
        _fundBackstop(80_000e18);
        uint256 a = _defaulted(BORROWER_1, 400_000e18);
        _realize(a, 10_000e18);
        _defaulted(keccak256("u1"), 200_000e18);
        _defaulted(keccak256("u2"), 200_000e18);
    }

    //  GROUP D — the f1801 shape, rebuilt so the acceptance is a PROPERTY.

    /// @dev The fixture of `ExternalFinding2_NavVsEventCap.test_f1801_fundCoverageTopUpLowersOnly
    ///      TheUndrawnDefaultMark`, up to the point just BEFORE the 5,000,000e18 top-up.
    function _dF1801(uint256[2] memory ids) internal returns (uint256[2] memory) {
        _openLimits();
        _stakeVault(alice, 3_200_000e18);
        _fundBackstop(1_000_000e18);
        ids[0] = _defaulted(BORROWER_1, 2_000_000e18);
        _realize(ids[0], sGrove.coverageCapacity() * 3 / 5);
        ids[1] = _defaulted(keccak256("u1"), 1_000_000e18);
        return ids;
    }

    // ── the whole scenario set, addressable by index ──────────────────────

    /// @dev EVERY scenario in this file, so the satisfiability sweeps cannot silently cover a
    ///      subset. Adding a scenario above without adding it here leaves it ungraded by the
    ///      sweeps, so keep the two in step.
    uint256 internal constant SCENARIO_COUNT = 12;

    function _buildScenario(uint256 i) internal {
        if (i == 0) {
            _aOneUndrawn();
        } else if (i == 1) {
            _aTwoUndrawn();
        } else if (i == 2) {
            _aThreeUndrawn();
        } else if (i == 3) {
            _aTwoUndrawnLumpy();
        } else if (i == 4) {
            _bOneDrawnOneUndrawn();
        } else if (i == 5) {
            _bOneDrawnTwoUndrawn();
        } else if (i == 6) {
            _bOneDrawnThreeUndrawn();
        } else if (i == 7) {
            _bSmallUndrawnPrincipal();
        } else if (i == 8) {
            _bPartiallyRealizedUndrawn();
        } else if (i == 9) {
            _cLargeReserveIdentity();
        } else if (i == 10) {
            _cSmallReserveIdentity();
        } else {
            uint256[2] memory ids;
            _dF1801(ids);
        }
    }
}

/// @notice THE GRADE. Every test here is red on a formulation outside the executed band and green
///         only on one inside it. Verdicts on the two shipped trees are in `UNDRAWN_LIMB.md`.
contract UndrawnLimbFalsifierTest is UndrawnLimbBase {
    // ── GROUP A: the drawn limb is INERT; a red is the undrawn limb's ──

    function test_A1_oneUndrawnEventUsesTheSharedReserve() public {
        _aOneUndrawn();
        _requireCleanMeasure("A1");
        _requireUndrawnLimbIsolated("A1");
        _assertInBand("A1-oneUndrawn");
    }

    function test_A2_twoUndrawnEventsDoNotMultiplyTheSharedReserve() public {
        _aTwoUndrawn();
        _requireCleanMeasure("A2");
        _requireUndrawnLimbIsolated("A2");
        _assertInBand("A2-twoUndrawn");
    }

    function test_A3_threeUndrawnEventsStillUseOneSharedReserve() public {
        _aThreeUndrawn();
        _requireCleanMeasure("A3");
        _requireUndrawnLimbIsolated("A3");
        _assertInBand("A3-threeUndrawn");
    }

    function test_A4_lumpyUndrawnPrincipalsDoNotChangeSharedDelivery() public {
        _aTwoUndrawnLumpy();
        _requireCleanMeasure("A4");
        _requireUndrawnLimbIsolated("A4");
        _assertInBand("A4-twoUndrawnLumpy");
    }

    // ── GROUP B: mixed cohorts, drawn limb pinned exact ──

    function test_B1_mixedOneDrawnOneUndrawn() public {
        _bOneDrawnOneUndrawn();
        _requireCleanMeasure("B1");
        _requireLedgerSeesEveryEvent("B1");
        _assertInBand("B1-oneDrawnOneUndrawn");
    }

    function test_B2_mixedOneDrawnTwoUndrawn() public {
        _bOneDrawnTwoUndrawn();
        _requireCleanMeasure("B2");
        _requireLedgerSeesEveryEvent("B2");
        _assertInBand("B2-oneDrawnTwoUndrawn");
    }

    function test_B3_mixedOneDrawnThreeUndrawn() public {
        _bOneDrawnThreeUndrawn();
        _requireCleanMeasure("B3");
        _requireLedgerSeesEveryEvent("B3");
        _assertInBand("B3-oneDrawnThreeUndrawn");
    }

    function test_B4_smallUndrawnPrincipalSharesTheLiveReserve() public {
        _bSmallUndrawnPrincipal();
        _requireCleanMeasure("B4");
        _requireLedgerSeesEveryEvent("B4");
        _assertInBand("B4-smallUndrawnPrincipal");
    }

    function test_B5_anUndrawnEventThatMigratesIntoTheDrawnCohort() public {
        _bPartiallyRealizedUndrawn();
        _requireCleanMeasure("B5");
        _requireLedgerSeesEveryEvent("B5");
        _assertInBand("B5-partiallyRealizedUndrawn");
    }

    // ── GROUP C: the cap/reserve ratio ──

    function test_C1_capacityEqualsReserveAtLargeScale() public {
        _cLargeReserveIdentity();
        _requireCleanMeasure("C1");
        _requireLedgerSeesEveryEvent("C1");
        _assertInBand("C1-largeReserveIdentity");
    }

    function test_C2_capacityEqualsReserveAtSmallScale() public {
        _cSmallReserveIdentity();
        _requireCleanMeasure("C2");
        _requireLedgerSeesEveryEvent("C2");
        _assertInBand("C2-smallReserveIdentity");
    }

    // ── GROUP D: f1801 AS A PROPERTY, not as a magic number ──

    /// @notice The f1801 case, re-expressed so no literal from the old acceptance suite is pinned.
    /// @dev ═══ WHY THE 850,000e18 LITERAL IS NOT AN INVARIANT ═══════════════════════════════════
    ///      `test_f1801_fundCoverageTopUpLowersOnlyTheUndrawnDefaultMark` closes on three
    ///      assertions. Its NatSpec warns "DO NOT REVERT THE NUMBERS", and that warning is about
    ///      its ORIGINAL pair (700,000e18 / 1,650,000e18), which pinned the `consumed`
    ///      double-subtraction as expected behaviour. It is NOT a claim that the round-4
    ///      replacements are eternal. Sorting the three:
    ///
    ///        (1) the drawn event's own room is unchanged across the top-up
    ///            — a STRUCTURAL property. Invariant. Asserted below.
    ///        (3) `markAfter == 1,500,000e18`
    ///            — ALSO a structural property, and this test proves it: after the top-up the
    ///              executed band collapses to the single point 1,200,000e18, so the mark is
    ///              forced to `gross - drawnOwnRoom - undrawnPrincipal`. The literal and the
    ///              property agree. Invariant. Asserted below, derived, never typed.
    ///        (2) `markBefore - markAfter == 850,000e18`
    ///            — NOT a property. It is `creditAfter - creditBefore`, and `creditBefore` is
    ///              precisely the pre-refill undrawn allowance under repair. The executed band
    ///              pre-refill is [450,000e18, 550,000e18], so the DEFENSIBLE delta is the
    ///              interval [650,000e18, 750,000e18]. 850,000e18 sits OUTSIDE it: that literal
    ///              encodes a 100,000e18 under-credit, i.e. the D1 mirror, and pinning it would
    ///              force any correct fix to red.
    ///
    ///      So this test asserts (1) and (3) as properties, and replaces (2) with the band. A fix
    ///      cannot regress f1801 silently, and cannot be forced to reproduce its under-credit.
    function test_D1_f1801IsAPropertyNotALiteral() public {
        uint256[2] memory ids;
        ids = _dF1801(ids);
        uint256 drawnId = ids[0];
        uint256 undrawnId = ids[1];

        _requireCleanMeasure("D1");
        _requireLedgerSeesEveryEvent("D1");

        uint256 gross = defaultManager.performanceFeeImpairment();
        uint256 markBefore = defaultManager.pendingSeniorImpairment();
        uint256 reserveBefore = _roomAt(drawnId);

        // The pre-refill credit must sit inside the pre-refill band. This is the assertion the
        // 850,000e18 literal was silently contradicting.
        _assertInBand("D1-f1801-preRefill");
        uint256 creditBefore = _credited();

        _fundBackstop(5_000_000e18);

        uint256 markAfter = defaultManager.pendingSeniorImpairment();

        // ADR-0035 deliberately reverses F-18-01's frozen-room property: replenishment is one
        // shared reserve and is immediately reachable by every still-live event.
        assertEq(_roomAt(drawnId), reserveBefore + 5_000_000e18, "f1801: refill did not re-arm shared reserve");
        assertEq(_roomAt(undrawnId), _roomAt(drawnId), "f1801: event ids see different shared reserves");

        // The post-refill band is a POINT — both realization orders deliver the same total — so
        // this half of the test is exact without any literal.
        {
            uint256 lo = _bandLo();
            uint256 hi = _bandHi();
            assertEq(lo, hi, "f1801: post-refill the band must collapse; a spread means the fixture drifted");
        }
        _assertInBand("D1-f1801-postRefill");

        // The replenished reserve exceeds the whole gross cohort, so layer two can fund every
        // remaining wei in either order and the conservative mark is exactly zero.
        assertGt(sGrove.coverageReserve(), gross, "f1801: refill must dominate the gross cohort");
        assertEq(markAfter, 0, "f1801: fully funded shared reserve left a senior mark");

        // (2) THE DELTA, AS AN INTERVAL. `markBefore - markAfter == creditAfter - creditBefore`,
        //     and `creditBefore` is graded by the band above rather than by a literal.
        assertEq(
            markBefore - markAfter,
            _credited() - creditBefore,
            "f1801: the fall in the mark must be exactly the rise in the layer-2 credit"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ADR-0035 PARTITION EQUIVALENCE
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Every read `ConservativeImpairmentMath.pendingSeniorImpairment` performs on the undrawn
    ///      path, packed so two scenarios can be compared field by field.
    struct Reads {
        uint256 declared;
        uint256 drawn;
        uint256 pastDue;
        uint256 curatorPool;
        uint256 reserve;
        uint256 capacity;
        uint256 liveRemaining;
        uint256 liveConsumed;
    }

    function _reads() internal view returns (Reads memory r) {
        r.declared = defaultManager.declaredDefaultedPrincipal(FILM);
        r.drawn = defaultManager.drawnDefaultPrincipal(FILM);
        r.pastDue = defaultManager.pastDuePrincipal(FILM);
        r.curatorPool = curator.poolBalance(FILM);
        r.reserve = sGrove.coverageReserve();
        r.capacity = sGrove.coverageCapacity();
        r.liveRemaining = defaultManager.liveDefaultCoverageRemaining();
        r.liveConsumed = defaultManager.liveDefaultCoverageConsumed();
    }

    function _assertSameReads(Reads memory a, Reads memory b, string memory what) internal pure {
        assertEq(a.declared, b.declared, string.concat(what, ": declaredDefaultedPrincipal differs"));
        assertEq(a.drawn, b.drawn, string.concat(what, ": drawnDefaultPrincipal differs"));
        assertEq(a.pastDue, b.pastDue, string.concat(what, ": pastDuePrincipal differs"));
        assertEq(a.curatorPool, b.curatorPool, string.concat(what, ": curator poolBalance differs"));
        assertEq(a.reserve, b.reserve, string.concat(what, ": coverageReserve differs"));
        assertEq(a.capacity, b.capacity, string.concat(what, ": coverageCapacity differs"));
        assertEq(a.liveRemaining, b.liveRemaining, string.concat(what, ": liveDefaultCoverageRemaining differs"));
        assertEq(a.liveConsumed, b.liveConsumed, string.concat(what, ": liveDefaultCoverageConsumed differs"));
    }

    /// @notice Byte-identical aggregate reads must now produce byte-identical executed delivery.
    /// @dev A1 and A2 vary only event partition. Both realization orders must deliver the same
    ///      shared reserve, proving that ADR-0035 removed the predecessor's hidden snapshot state.
    function test_ADR0035_identicalReadsNowHaveIdenticalExecutedTruths() public {
        uint256 snap = vm.snapshotState();

        _aOneUndrawn();
        _requireCleanMeasure("impossibility/A1");
        _requireUndrawnLimbIsolated("impossibility/A1");
        Reads memory r1 = _reads();
        uint256 lo1 = _bandLo();
        uint256 hi1 = _bandHi();

        vm.revertToState(snap);
        delete evIds;

        _aTwoUndrawn();
        _requireCleanMeasure("impossibility/A2");
        _requireUndrawnLimbIsolated("impossibility/A2");
        Reads memory r2 = _reads();
        uint256 lo2 = _bandLo();
        uint256 hi2 = _bandHi();

        _assertSameReads(r1, r2, "A1 vs A2");

        assertEq(lo1, hi1, "ADR-0035 A1 must be order independent");
        assertEq(lo2, hi2, "ADR-0035 A2 must be order independent");
        assertEq(lo1, lo2, "ADR-0035 event partition changed shared-reserve delivery");
        console2.log(
            string.concat(
                "ADR0035 identical-reads bands: A1=[",
                Strings.toString(lo1),
                ",",
                Strings.toString(hi1),
                "] A2=[",
                Strings.toString(lo2),
                ",",
                Strings.toString(hi2),
                "]"
            )
        );
    }

    /// @notice The same equivalence at a third and fourth partition, so it is a pattern and not a
    ///         pair. Equal aggregate principal and reserve must remain order independent even for
    ///         three events or a lumpy two-event split.
    function test_ADR0035_eventPartitionCannotChangeSharedReserveDelivery() public {
        uint256 snap = vm.snapshotState();

        _aOneUndrawn();
        Reads memory r1 = _reads();
        uint256 a1 = _bandLo();

        vm.revertToState(snap);
        delete evIds;
        _aThreeUndrawn();
        _requireUndrawnLimbIsolated("impossibility/A3");
        Reads memory r3 = _reads();
        uint256 a3 = _bandLo();
        assertEq(a3, _bandHi(), "A3 band must be a point");

        vm.revertToState(snap);
        delete evIds;
        _aTwoUndrawnLumpy();
        _requireUndrawnLimbIsolated("impossibility/A4");
        Reads memory r4 = _reads();
        uint256 a4lo = _bandLo();
        uint256 a4hi = _bandHi();

        _assertSameReads(r1, r3, "A1 vs A3");
        _assertSameReads(r1, r4, "A1 vs A4");

        assertEq(a1, a3, "event count changed shared-reserve delivery");
        assertEq(a4lo, a4hi, "lumpy principals made uncapped shared reserve order-dependent");
        assertEq(a1, a4lo, "principal partition changed shared-reserve delivery");
        console2.log(
            string.concat(
                "ADR0035 partition-invariant truths: A1=",
                Strings.toString(a1),
                " A3=",
                Strings.toString(a3),
                " A4=[",
                Strings.toString(a4lo),
                ",",
                Strings.toString(a4hi),
                "]"
            )
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  SATISFIABILITY — the band is a reachable target, not an impossible one
    // ══════════════════════════════════════════════════════════════════════

    /// @dev `_ladder` walks remaining event principals against the one live reserve. Matching the
    ///      EXECUTED cascade in both orders proves that the point-valued band is physically
    ///      reachable rather than copied from the impairment implementation.
    function _assertLadderReproducesExecution(string memory s) internal {
        assertEq(_ladder(true), _deliverable(true), string.concat(s, ": ladder != executed cascade, forward order"));
        assertEq(_ladder(false), _deliverable(false), string.concat(s, ": ladder != executed cascade, reverse order"));
    }

    /// @notice The conservative canonical choice inside the band, stated once.
    /// @dev `min(ladderForward, ladderReverse)` is computable in a `view` and is BY CONSTRUCTION
    ///      the bottom of the band — the credit the cascade delivers in its WORST realization
    ///      order. It is the value this stream recommends as the target: it never over-credits an
    ///      exiting holder (F1) and never under-credits below what the cascade must deliver in
    ///      every order (the D1 mirror). This test pins that the recommendation is in fact
    ///      admissible under the very assertion the fix will be graded by.
    function test_satisfiable_worstOrderLadderIsAdmissibleEverywhere() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < SCENARIO_COUNT; ++i) {
            vm.revertToState(snap);
            delete evIds;
            _buildScenario(i);
            uint256 f = _ladder(true);
            uint256 r = _ladder(false);
            uint256 worst = f < r ? f : r;
            string memory tag = string.concat("scenario#", Strings.toString(i));
            assertGe(
                worst,
                _bandLo() > BAND_DUST ? _bandLo() - BAND_DUST : 0,
                string.concat(tag, ": worst-order ladder fell BELOW the executed band")
            );
            assertLe(
                worst, _bandHi() + BAND_DUST, string.concat(tag, ": worst-order ladder rose ABOVE the executed band")
            );
        }
    }

    /// @dev The ladder is checked against EXECUTION on every scenario, in both orders. If this is
    ///      green then the arithmetic a `view` would have to perform is faithful to the cascade.
    function test_satisfiable_theLadderReproducesExecutionOnEveryScenario() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < SCENARIO_COUNT; ++i) {
            vm.revertToState(snap);
            delete evIds;
            _buildScenario(i);
            _assertLadderReproducesExecution(string.concat("scenario#", Strings.toString(i)));
        }
    }
}
