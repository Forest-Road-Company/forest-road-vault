// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IDefaultManager} from "../../src/interfaces/IDefaultManager.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title OWNER DECISION 2026-08-07 — an unattested past-due mark is not an attested default
/// @notice Forest Road, verbatim: "An unattested, permissionless past-due mark should NOT carry the
///         same forward weight as an attested declared default."
///
///         THE DEFECT. `DefaultManager.pendingSeniorImpairment()` folded `pastDuePrincipal` into the
///         impairment on EXACTLY the same footing as `declaredDefaultedPrincipal`. But:
///           - `declareDefault` is SERVICER_ROLE plus a CONSUMED `DefaultDeclared` attestation
///             quorum, and it leads to `realizeLoss`;
///           - `markPastDue` is `external nonReentrant` with NO role modifier and NO attestation,
///             and it records the facility's WHOLE OUTSTANDING at ZERO recovery.
///         A merely past-due facility stays `Active`/`Amortizing`, and `realizeLoss` requires
///         `Defaulted`/`Accelerated`, so the past-due assertion is STRUCTURALLY UNEXECUTABLE
///         without the attested step. The mismatch is EXECUTABLE CHARGE versus ASSERTED CHARGE.
///
///         THE FIX, in three ordered steps (`DefaultManager.pendingSeniorImpairment` ->
///         `CollateralRegistry.conservativeSeniorMark`):
///           (1) EXECUTABLE BOUND. Clamp the past-due cohort's senior charge to what `realizeLoss`
///               could actually burn out of the vault today — `IsUSDfr(vault).totalAssets()`, the
///               exact quantity `realizeLoss` reverts above with
///               `DefaultManager_LossExceedsAbsorptionCapacity` — less the prior claim of the
///               ATTESTED cohort, which can execute this block while the past-due cohort cannot.
///           (2) WEIGHT. Discount what remains by the governed `pastDueWeightBps`, 5,000 bps at
///               launch, derived in `Config.DEFAULT_PAST_DUE_WEIGHT_BPS` from the protocol's own
///               governed evidence ladder (`marginCall` rung vs `liquidate` rung on class 5).
///           (3) EXPIRY. That weight is a BENEFIT OF THE DOUBT WITH AN EXPIRY, not a permanent
///               discount: it ramps linearly back to FULL over one `Config.DEFAULT_REDEEM_COOLDOWN`
///               measured from `DefaultManager.pastDueReliefAnchor`, the moment the unattested
///               cohort last went empty -> non-empty. The doubt being extended is "the servicer has
///               not yet had time to attest"; after a full redemption cooldown it is spent, and the
///               pre-fix loud stop returns with NOBODY having to send a transaction. The `_ramp_`
///               block at the end of this file is the regression suite for step (3).
///
///         WHAT MUST NOT BREAK, and is pinned here:
///           - H-5: `markPastDue` stays PERMISSIONLESS and still moves the NAV strictly. A weight of
///             zero re-opens H-5 and D5-03, so zero is unreachable by governance AND unreachable by
///             an un-migrated proxy reading a fresh zero slot.
///           - D5-03: under-marking is the dangerous direction. The attested cohort is neither
///             clamped nor weighted, so the loud stop still fires on a genuine near-total loss.
///           - No recursion: the bound reads `totalAssets()`, never `redemptionTotalAssets()`.
///           - The CLAMP does not expire with the WEIGHT. The clamp is a structural fact about
///             `realizeLoss`; only the weight is a benefit of the doubt.
///
///         EVERY GUARD BELOW HAS A NAMED TIER AND A DELETION MUTATION. See the mutation table in
///         the session report; each `test_g2w_*` name states which deletion it reds.
contract FixG2WUnattestedPastDueWeightTest is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

    event PastDueWeightSet(uint256 bps);

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev The launch-ramp concentration posture, so a single large film facility is admissible.
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

    function _warpPastGrace(uint256 id) internal {
        ClaimBridge.Facility memory f = bridge.facility(id);
        vm.warp(uint256(f.nextPaymentDue) + uint256(defaultManager.graceWindow(f.classId)) + 1);
    }

    /// @dev A funded film facility, flagged past due by `carol` — an UNPRIVILEGED, NON-KYC address.
    ///      That is the threat model the owner decision is about, so it is the caller used
    ///      throughout, never the servicer.
    function _markedByStranger(uint256 principal) internal returns (uint256 id) {
        id = _liveFilmFacility(principal);
        _warpPastGrace(id);
        vm.prank(carol);
        defaultManager.markPastDue(id);
    }

    // ── TIER 1: the measured consequence, before and after ────────────────

    /// @notice TIER 1 — THE HEADLINE SCENARIO. $200,000 staked inside a $3.4m float; one
    ///         `markPastDue` by an unprivileged, non-KYC address on an $800,000 facility.
    ///         BEFORE: `redemptionTotalAssets()` -> ZERO; the protocol's only senior exit halted
    ///         wholesale. AFTER: the exit stays open, priced at the governed weight of the
    ///         executable charge.
    ///
    ///         MUTATION: delete the `conservativeSeniorMark` call in
    ///         `DefaultManager.pendingSeniorImpairment` (return `residual`) -> RED here.
    function test_g2w_headlineScenarioNoLongerHaltsTheSeniorExit() public {
        _openLaunchRampLimitsForFilm();
        // $3.4m float, of which only $200k is staked in the senior vault.
        _mintUSDfrTo(bob, 3_200_000e18);
        _stake(alice, 200_000e18);
        assertEq(vault.totalAssets(), 200_000e18, "senior tranche is 200k");

        uint256 id = _markedByStranger(800_000e18);

        // The gross pool is untouched: the honest at-risk principal is still the whole facility.
        assertEq(defaultManager.pastDueContribution(id), 800_000e18, "gross past-due pool unchanged");
        assertEq(defaultManager.performanceFeeImpairment(), 800_000e18, "gross fee base unchanged");

        // Executable bound: the cascade could burn at most the vault's 200k. Weight: half of that.
        assertEq(defaultManager.pendingSeniorImpairment(), 100_000e18, "half of the executable 200k");
        assertEq(vault.redemptionTotalAssets(), 100_000e18, "THE SENIOR EXIT IS OPEN");
        assertGt(vault.redemptionTotalAssets(), 0, "pre-fix this was ZERO");
        assertGt(vault.previewRedeem(10 ** vault.decimals()), 0, "a senior can still exit");
    }

    /// @notice TIER 1 — and it is still a REAL mark, not a no-op. H-5 required the permissionless
    ///         trigger to actually protect seniors; a weight of zero would re-open it.
    ///
    ///         MUTATION, CORRECTED (SWEEP-1 VAC-F1, 2026-08-08). This line used to say "make
    ///         `CollateralRegistry.weightedPastDueImpairment` return 0 -> RED here". IT DOES NOT.
    ///         MEASURED: neutralising that helper's multiply (compiling, operands still
    ///         referenced) leaves THIS test and `test_g2w_headlineScenarioNoLongerHaltsTheSeniorExit`
    ///         GREEN and reds only the two tests that use the helper as their own oracle. The
    ///         helper is not on the value path: `pendingSeniorImpairment()` reaches
    ///         `CollateralRegistry.conservativeSeniorMark`, which carries its OWN weighting applied
    ///         after its clamp — as this file itself notes further down. THE MUTATION THAT REDS
    ///         THIS TEST is neutralising the weighting INSIDE `conservativeSeniorMark`.
    function test_g2w_theUnattestedMarkStillStrictlyDepressesTheExit() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 1_000_000e18);
        uint256 exitBefore = vault.previewRedeem(10 ** vault.decimals());

        _markedByStranger(400_000e18);

        assertLt(vault.previewRedeem(10 ** vault.decimals()), exitBefore, "a stranger's mark still bites");
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "weight zero would re-open H-5 / D5-03");
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "at the governed weight");
    }

    // ── TIER 2: attested versus unattested ────────────────────────────────

    /// @notice TIER 2 — THE DECISION ITSELF. The same facility, the same principal, the same block:
    ///         the ATTESTED declared default marks strictly heavier than the UNATTESTED past-due
    ///         mark. This is the owner decision expressed as a single inequality.
    ///
    ///         MUTATION: delete the `pastDueResidual` accumulation in the class loop (so the
    ///         past-due cohort is never split out and is charged at full weight) -> RED here.
    function test_g2w_attestedDefaultMarksStrictlyHeavierThanUnattestedPastDue() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 5_000_000e18);

        uint256 id = _markedByStranger(400_000e18);
        uint256 unattested = defaultManager.pendingSeniorImpairment();

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        uint256 attested = defaultManager.pendingSeniorImpairment();

        assertEq(attested, 400_000e18, "the ATTESTED path asserts the full outstanding");
        assertEq(unattested, 200_000e18, "the UNATTESTED path asserts the governed weight of it");
        assertLt(unattested, attested, "OWNER DECISION 2026-08-07: NOT the same forward weight");
        // ...and no double count: exactly one pool holds it at a time.
        assertEq(defaultManager.pastDueExposure(), 0, "converted out of the past-due pool");
        assertEq(defaultManager.defaultedContribution(id), 400_000e18, "counted once");
    }

    /// @notice TIER 2 — the ATTESTED cohort is neither weighted nor clamped. C-1 / the legitimate
    ///         loud stop must still fire: a genuine near-total senior loss on the attested path
    ///         still drives the conservative NAV to zero.
    ///
    ///         MUTATION: apply `conservativeSeniorMark` to `residual` rather than to
    ///         `pastDueSenior` (i.e. weight the whole impairment) -> RED here.
    function test_g2w_attestedNearTotalLossStillDrivesTheExitToZero() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 200_000e18);

        uint256 id = _liveFilmFacility(800_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertEq(defaultManager.pendingSeniorImpairment(), 800_000e18, "attested: full weight, no clamp");
        assertEq(vault.redemptionTotalAssets(), 0, "THE LOUD STOP STILL FIRES");
        assertEq(vault.previewRedeem(10 ** vault.decimals()), 0, "no senior exits above the floor");
    }

    // ── TIER 3: the executable bound (ANGLE C) ────────────────────────────

    /// @notice TIER 3 — THE EXECUTABLE BOUND IS THE CASCADE'S OWN BOUND. `realizeLoss` reverts with
    ///         `DefaultManager_LossExceedsAbsorptionCapacity` the moment the senior slice exceeds
    ///         `sUSDfr.totalAssets()`. This proves the number the clamp uses is exactly the number
    ///         the cascade enforces — the forward mark asserts nothing the cascade could not charge.
    ///
    ///         MUTATION: drop the `pastDueSenior > executable` clamp in
    ///         `CollateralRegistry.conservativeSeniorMark` -> RED here.
    function test_g2w_theClampIsExactlyWhatRealizeLossWouldRevertAbove() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 200_000e18);
        uint256 vaultAssets = vault.totalAssets();

        uint256 id = _markedByStranger(800_000e18);
        // Unclamped, the past-due cohort's post-junior residual is the whole 800k. The clamp cuts
        // it to the vault's 200k BEFORE the weight, so the reported mark is half of 200k.
        assertEq(defaultManager.pendingSeniorImpairment(), vaultAssets / 2, "clamped, then weighted");

        // Now prove the clamp's number: take the facility all the way down the attested path and
        // show `realizeLoss` refuses anything above `vaultAssets`.
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _attestLoss(id, 800_000e18, FILM_REF);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManager.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, 800_000e18, vaultAssets
            )
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 800_000e18, FILM_REF);
    }

    /// @notice TIER 3 — SUBORDINATION. The ATTESTED cohort has first claim on the vault's
    ///         absorption capacity, because it can call `realizeLoss` this block and the past-due
    ///         cohort structurally cannot. Once the attested cohort has consumed the capacity, an
    ///         additional unattested mark adds nothing executable.
    ///
    ///         MUTATION: in `conservativeSeniorMark`, use `vaultAssets` directly instead of
    ///         `vaultAssets - declaredSenior` -> RED here (the past-due cohort would double-count
    ///         capacity the attested cohort already claims).
    function test_g2w_attestedCohortHasFirstClaimOnTheExecutableCapacity() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 500_000e18);

        // Attested cohort alone already claims the entire senior tranche.
        uint256 declared = _liveFilmFacility(500_000e18);
        _attestDefault(declared);
        vm.prank(servicer);
        defaultManager.declareDefault(declared, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18, "attested cohort takes it all");

        // A stranger now marks a second facility past due. There is no executable capacity left.
        _markedByStranger(400_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18, "nothing executable remains to charge");
        assertEq(defaultManager.pastDueExposure(), 400_000e18, "the gross pool still records the mark");
    }

    /// @notice TIER 3 — ORDER IS LOAD-BEARING: CLAMP FIRST, WEIGHT SECOND. Weighting first and
    ///         clamping second collapses to the clamp whenever the mark is large
    ///         (`min(w*P, E) == E` for `w*P >= E`), which is exactly the case the owner decision is
    ///         about — the fix would silently do nothing. This pins the difference numerically.
    ///
    ///         MUTATION: swap the two lines in `conservativeSeniorMark` (weight then clamp) ->
    ///         RED here.
    function test_g2w_clampBeforeWeightIsNotTheSameAsWeightBeforeClamp() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 200_000e18);
        _markedByStranger(800_000e18);

        uint256 executable = vault.totalAssets(); // 200k, no attested cohort
        uint256 clampThenWeight = registry.weightedPastDueImpairment(executable); // 100k
        uint256 weightThenClamp = registry.weightedPastDueImpairment(800_000e18); // 400k
        if (weightThenClamp > executable) weightThenClamp = executable; // -> 200k, i.e. the clamp

        assertEq(defaultManager.pendingSeniorImpairment(), clampThenWeight, "the implemented order");
        assertEq(weightThenClamp, executable, "the wrong order degenerates to the bare clamp...");
        assertLt(clampThenWeight, weightThenClamp, "...and would have wiped the exit");
        assertEq(vault.redemptionTotalAssets(), 100_000e18, "exit open");
        assertEq(executable - weightThenClamp, 0, "the wrong order leaves ZERO redeemable");
    }

    /// @notice TIER 3 — NO CIRCULARITY. The clamp reads `sUSDfr.totalAssets()`, which is a token
    ///         balance minus the vesting schedule and touches no impairment source. Reading
    ///         `redemptionTotalAssets()` instead would recurse
    ///         (`redemptionTotalAssets -> AssessedImpairmentSource -> DefaultManager -> ...`).
    ///         This drives the whole read path with a live past-due mark and a live redemption,
    ///         under a bounded gas budget, so an accidental loop shows up as a failure rather than
    ///         as a slow test.
    function test_g2w_theExecutableReadPathTerminates() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 1_000_000e18);
        _markedByStranger(400_000e18);

        uint256 gasBefore = gasleft();
        uint256 a = vault.redemptionTotalAssets();
        uint256 b = vault.previewRedeem(10 ** vault.decimals());
        uint256 c = defaultManager.pendingSeniorImpairment();
        uint256 used = gasBefore - gasleft();

        assertGt(a, 0, "read completed");
        assertGt(b, 0, "read completed");
        assertEq(c, 200_000e18, "read completed");
        assertLt(used, 1_000_000, "the read path is bounded - no recursion through the impairment source");
    }

    /// @notice TIER 3 — THE READ MUST STILL FIT INSIDE sUSDfr's IMPAIRMENT PROBE BUDGET. The fix
    ///         adds two external staticcalls to `pendingSeniorImpairment` (`vault.totalAssets()`
    ///         and `registry.conservativeSeniorMark`). `sUSDfr` probes the impairment source
    ///         under a FIXED 200,000-gas limit in `_probeImpairmentSource`, used by both
    ///         `setImpairmentSource` validation and the emergency recovery path. A read that
    ///         outgrew that budget would make a HEALTHY source look unreadable and could brick the
    ///         wiring, so the budget is asserted here against the WORST case this suite can build:
    ///         every class carrying both an attested and an unattested cohort.
    function test_g2w_theImpairmentReadFitsInsideTheProbeGasBudget() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 20_000_000e18);
        _postFirstLoss(anchorCurator, FILM, 100_000e18);

        uint256 declared = _liveFilmFacility(500_000e18);
        _attestDefault(declared);
        vm.prank(servicer);
        defaultManager.declareDefault(declared, FILM_REF);
        _markedByStranger(400_000e18);
        _markedByStranger(300_000e18);

        uint256 before = gasleft();
        defaultManager.pendingSeniorImpairment();
        uint256 used = before - gasleft();
        // `IMPAIRMENT_SOURCE_PROBE_GAS` in sUSDfr. Kept as a literal here on purpose: it is
        // `private` there, and this test exists precisely to catch the two drifting apart.
        assertLt(used, 200_000, "pendingSeniorImpairment must stay inside sUSDfr's probe budget");
    }

    // ── TIER 4: the governed weight parameter ─────────────────────────────

    /// @notice TIER 4 — the launch weight is the DERIVED one, and it is derived from parameters the
    ///         protocol already governs. `markPastDue` is the receivable-side analogue of the
    ///         permissionless MARGIN-CALL rung; governance placed that rung exactly half way along
    ///         class 5's governed deterioration band, so the early rung's forward weight relative
    ///         to the terminal (`liquidate`) rung is one half.
    ///
    ///         MUTATION: change `Config.DEFAULT_PAST_DUE_WEIGHT_BPS` -> RED here.
    function test_g2w_theLaunchWeightIsDerivedFromTheGovernedEvidenceLadder() public view {
        ICollateralRegistry.ClassParams memory p = registry.classParams(Config.CLASS_DIGITAL_ASSETS);
        assertEq(uint256(p.model), uint256(ICollateralRegistry.CollateralModel.MarkedToMarket), "the ladder class");
        assertGt(p.liquidationLtvBps, p.marginCallLtvBps, "terminal rung above the warning rung");
        assertGt(p.marginCallLtvBps, p.maxLtvBps, "warning rung above the advance rung");

        uint256 derived =
            (uint256(p.marginCallLtvBps - p.maxLtvBps) * Config.BPS) / uint256(p.liquidationLtvBps - p.maxLtvBps);
        assertEq(derived, Config.DEFAULT_PAST_DUE_WEIGHT_BPS, "the constant IS the ladder ratio");
        assertEq(registry.pastDueWeightBps(), Config.DEFAULT_PAST_DUE_WEIGHT_BPS, "and it is in force");
    }

    /// @notice TIER 4 — ZERO MEANS UNSET, NOT "NO MARK". A slot appended to a namespaced storage
    ///         struct reads ZERO on every proxy upgraded from a pre-G2W implementation. Zero must
    ///         never mean "an unattested mark carries no weight" — that re-opens H-5 and D5-03.
    ///
    ///         MUTATION: delete `if (bps == 0) bps = Config.DEFAULT_PAST_DUE_WEIGHT_BPS;` in
    ///         `CollateralRegistry.pastDueWeightBps` -> RED here.
    function test_g2w_anUnsetSlotReadsTheSafeDefaultNotZero() public {
        // The slot has never been written on this fresh deployment.
        assertEq(registry.pastDueWeightBps(), Config.DEFAULT_PAST_DUE_WEIGHT_BPS, "unset -> safe default");
        assertGt(registry.pastDueWeightBps(), 0, "an un-migrated proxy must never read weight zero");

        _openLaunchRampLimitsForFilm();
        _stake(alice, 1_000_000e18);
        _markedByStranger(400_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "the default is actually applied");
    }

    /// @notice TIER 4 — governance may not zero the weight. A zero weight neuters the only
    ///         permissionless senior protection on receivables (H-5) and restores the D5-03
    ///         par-exit-while-underwater window.
    ///
    ///         MUTATION: delete the `bps == 0` half of the bound in
    ///         `CollateralRegistry.setPastDueWeight` -> RED here.
    function test_g2w_governanceCannotZeroTheWeight() public {
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_InvalidPastDueWeight.selector, 0));
        vm.prank(admin);
        registry.setPastDueWeight(0);
        assertEq(registry.pastDueWeightBps(), Config.DEFAULT_PAST_DUE_WEIGHT_BPS, "unchanged");
    }

    /// @notice TIER 4 — governance may not restore parity either. At or above `Config.BPS` the
    ///         unattested mark carries the same (or a greater) forward weight as an attested
    ///         declared default, which IS the defect.
    ///
    ///         MUTATION: delete the `bps >= Config.BPS` half of the bound -> RED here.
    function test_g2w_governanceCannotRestoreTheDefectByTransaction() public {
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_InvalidPastDueWeight.selector, Config.BPS));
        vm.prank(admin);
        registry.setPastDueWeight(Config.BPS);

        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_InvalidPastDueWeight.selector, Config.BPS + 1)
        );
        vm.prank(admin);
        registry.setPastDueWeight(Config.BPS + 1);

        assertLt(registry.pastDueWeightBps(), Config.BPS, "strictly lighter than the attested mark, always");
    }

    /// @notice TIER 4 — only timelocked governance sets it.
    ///
    ///         MUTATION: delete `onlyRole(DEFAULT_ADMIN_ROLE)` on
    ///         `CollateralRegistry.setPastDueWeight` -> RED here.
    function test_g2w_setPastDueWeightIsGovernanceOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        vm.prank(carol);
        registry.setPastDueWeight(2_000);
    }

    /// @notice TIER 4 — a governed re-tune actually moves the forward mark, in both directions, and
    ///         events it. Governance retains the lever the owner decision leaves it.
    function test_g2w_aGovernedRetuneMovesTheForwardMark() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 1_000_000e18);
        _markedByStranger(400_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "launch weight");

        vm.expectEmit(false, false, false, true, address(registry));
        emit PastDueWeightSet(2_500);
        vm.prank(admin);
        registry.setPastDueWeight(2_500);
        assertEq(defaultManager.pendingSeniorImpairment(), 100_000e18, "lighter weight, lighter mark");

        vm.prank(admin);
        registry.setPastDueWeight(9_999);
        assertEq(defaultManager.pendingSeniorImpairment(), 399_960e18, "heavier weight, heavier mark");
        assertLt(defaultManager.pendingSeniorImpairment(), 400_000e18, "but never the attested weight");
    }

    // ── TIER 5: direction and rounding ────────────────────────────────────

    /// @notice TIER 5 — D5-03 SAYS UNDER-MARKING IS THE DANGEROUS DIRECTION, so the rounding dust
    ///         lands against the exiting senior, never in their favour.
    ///
    ///         MUTATION: change `+ Config.BPS - 1` to `+ 0` in
    ///         `CollateralRegistry.weightedPastDueImpairment` -> RED here.
    function test_g2w_theWeightRoundsUpNotDown() public {
        vm.prank(admin);
        registry.setPastDueWeight(3_333);
        // 1 wei * 3333 / 10000 == 0 rounding down; the guard rounds it to 1.
        assertEq(registry.weightedPastDueImpairment(1), 1, "over-mark direction on the dust");
        assertEq(registry.weightedPastDueImpairment(3), 1, "3 * 3333 / 10000 = 0.99 -> 1");
        assertEq(registry.weightedPastDueImpairment(0), 0, "but nothing is invented from nothing");
    }

    /// @notice TIER 5 — the gross pool, the fee base and the per-facility contribution are all
    ///         UNCHANGED by this fix. Only the FORWARD WEIGHT into the conservative redemption NAV
    ///         moved. That keeps `AssessedImpairmentSource`'s
    ///         `performanceFeeImpairment >= pendingSeniorImpairment` precondition satisfied and
    ///         keeps the H-5/H-2 re-anchor and release accounting exactly as audited.
    function test_g2w_theGrossPastDueAccountingIsUntouched() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 1_000_000e18);
        uint256 id = _markedByStranger(400_000e18);

        assertEq(defaultManager.pastDueContribution(id), 400_000e18, "per-facility contribution: gross");
        assertEq(defaultManager.pastDueExposure(), 400_000e18, "global exposure: gross");
        assertEq(defaultManager.performanceFeeImpairment(), 400_000e18, "fee base: gross");
        assertGe(
            defaultManager.performanceFeeImpairment(),
            defaultManager.pendingSeniorImpairment(),
            "AssessedImpairmentSource precondition holds"
        );

        // The re-anchor still tracks live `deployedTo` on the gross pool.
        _repay(id, 0, 100_000e18);
        assertEq(defaultManager.pastDueContribution(id), 300_000e18, "re-anchored DOWN, gross");
        assertEq(defaultManager.pendingSeniorImpairment(), 150_000e18, "and the weighted mark follows");
    }

    /// @notice TIER 5 — junior capacity is offered to the DISCOUNTED cohort FIRST. With `w < 1`
    ///         that is the allocation that MAXIMISES the reported mark, so it is the conservative
    ///         split — the same convention the F-18-01 drawn/undrawn split already uses.
    ///
    ///         MUTATION: move the `pastDueResidual` accumulation after the curator netting (so the
    ///         attested cohort absorbs first) -> RED here.
    function test_g2w_juniorCapacityIsOfferedToTheDiscountedCohortFirst() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 5_000_000e18);
        _postFirstLoss(anchorCurator, FILM, 300_000e18);

        // 400k attested + 400k unattested against a 300k class first-loss pool.
        uint256 declared = _liveFilmFacility(400_000e18);
        _attestDefault(declared);
        vm.prank(servicer);
        defaultManager.declareDefault(declared, FILM_REF);
        _markedByStranger(400_000e18);

        // Curator to past-due first: past-due residual 100k -> weighted 50k; attested 400k intact.
        // The alternative (curator to the attested cohort first) would report
        // 100k + 0.5 * 400k = 300k, which is LOWER — i.e. less conservative.
        assertEq(defaultManager.pendingSeniorImpairment(), 450_000e18, "conservative split");
        assertGt(defaultManager.pendingSeniorImpairment(), 300_000e18, "strictly above the alternative split");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    //  STEP (3): THE RELIEF RAMP — a benefit of the doubt WITH AN EXPIRY
    // ═══════════════════════════════════════════════════════════════════════════════════════════
    //
    //  The adjudicated synthesis (2026-08-07) grafted a decay ramp onto the size-invariant
    //  executable clamp. Everything above pins the clamp and the launch weight; everything below
    //  pins the EXPIRY, which is the half the judge built but did not campaign.
    //
    //  EXPECTATIONS ARE PINNED TO LITERALS AND TO `Config` CONSTANTS, NEVER to
    //  `registry.pastDueRampWeightBps`. Deriving them from the contract's own ramp view would make
    //  a mutation of the ramp move the expectation in lockstep and the mutation would survive —
    //  the tautology trap. `pastDueRampWeightBps` is itself pinned, once, against literals.

    /// @dev One `Config.DEFAULT_REDEEM_COOLDOWN`; the ramp length. Named for readability only.
    uint256 internal constant RAMP = Config.DEFAULT_REDEEM_COOLDOWN;

    /// @notice RAMP-1 — THE ANCHOR IS WRITTEN. A fresh mark on an empty cohort gets the FULL
    ///         governed relief: exactly `pastDueWeightBps` of the executable charge, not a byte
    ///         more and not full weight.
    ///
    ///         MUTATION (anchor write): delete
    ///         `if ($.pastDueExposure == 0) $.pastDueReliefAnchor = block.timestamp;` from
    ///         `markPastDue`. The anchor then stays ZERO forever, `elapsed` becomes
    ///         `block.timestamp`, the ramp expires instantly and every unattested mark is charged
    ///         at FULL weight — the pre-G2W defect, silently restored. RED here.
    function test_g2w_ramp_theAnchorIsWrittenSoAFreshMarkGetsTheGovernedRelief() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 1_000_000e18);
        _markedByStranger(400_000e18);

        // 5,000 bps of 400,000 == 200,000. The clamp is not binding (the vault holds 1,000,000).
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "the fresh mark carries HALF weight");
        assertLt(defaultManager.pendingSeniorImpairment(), 400_000e18, "and is strictly lighter than an attestation");
    }

    /// @notice RAMP-2 — THE LOUD STOP RETURNS ON ITS OWN. The headline scenario, left alone for one
    ///         redemption cooldown with nobody attesting and nobody curing: the relief winds off
    ///         and `redemptionTotalAssets()` goes back to ZERO, with NO transaction from anyone.
    ///         This is what makes the fix a deferral rather than a permanent under-mark.
    ///
    ///         MUTATION (ramp bound): delete the `if (elapsed >= ramp) return declaredSenior +
    ///         amount;` early return in `conservativeSeniorMark` -> the linear term overshoots
    ///         `Config.BPS` and eventually overflows; RED here and in RAMP-6.
    function test_g2w_ramp_theLoudStopReturnsAfterOneCooldownIfNobodyAttests() public {
        _openLaunchRampLimitsForFilm();
        _mintUSDfrTo(bob, 3_200_000e18);
        _stake(alice, 200_000e18);
        _markedByStranger(800_000e18);

        assertEq(vault.redemptionTotalAssets(), 100_000e18, "at the mark: relieved to half the executable 200k");

        vm.warp(block.timestamp + RAMP);
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "at +21d: the FULL executable charge");
        assertEq(vault.redemptionTotalAssets(), 0, "THE LOUD STOP IS BACK, unattended");
    }

    /// @notice RAMP-3 — THE CLAMP DOES NOT EXPIRE WITH THE WEIGHT. Past the ramp the unattested
    ///         cohort is charged at full weight but STILL only up to what `realizeLoss` could
    ///         actually burn. The clamp is a structural fact about the cascade; only the weight was
    ///         ever a benefit of the doubt. Without this the size-invariance the panel adjudicated
    ///         for would evaporate 21 days after every mark.
    ///
    ///         MUTATION (clamp/weight order): move the clamp inside the `elapsed < ramp` branch, or
    ///         return `declaredSenior + pastDueSenior` on the expired path -> RED here.
    function test_g2w_ramp_pastTheRampTheClampStillBinds() public {
        _openLaunchRampLimitsForFilm();
        _mintUSDfrTo(bob, 9_000_000e18);
        _stake(alice, 200_000e18);
        _markedByStranger(5_000_000e18); // 25x the senior tranche

        vm.warp(block.timestamp + RAMP * 10); // long past any expiry
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            200_000e18,
            "full weight, but still clamped to the vault 200k, NOT the 5,000,000 asserted"
        );
        assertEq(defaultManager.performanceFeeImpairment(), 5_000_000e18, "the GROSS pool is still the whole 5m");
    }

    /// @notice RAMP-4 — A SECOND MARK CANNOT REWIND THE COHORT CLOCK. This is the attack the
    ///         EMPTY -> non-empty condition exists to close: if every `markPastDue` re-anchored,
    ///         anyone could mark a dust facility every twenty days and hold the whole standing
    ///         cohort at maximum relief indefinitely — the expiry would never fire.
    ///
    ///         MUTATION (empty-pool condition): make the anchor write unconditional
    ///         (`$.pastDueReliefAnchor = block.timestamp;`) -> RED here.
    function test_g2w_ramp_aSecondMarkCannotRewindTheCohortClock() public {
        _openLaunchRampLimitsForFilm();
        _mintUSDfrTo(bob, 3_000_000e18);
        _stake(alice, 2_000_000e18);
        // BOTH facilities are originated NOW, so the dust facility is already markable later
        // without warping the clock forward again (the `_warpPastGrace` helper would otherwise
        // move time itself and confound the measurement this test is making).
        uint256 big = _liveFilmFacility(400_000e18);
        uint256 dust = _liveFilmFacility(1_000e18);
        _warpPastGrace(big);
        vm.prank(carol);
        defaultManager.markPastDue(big);

        // 20 of the 21 days elapse: the relief is nearly spent.
        vm.warp(block.timestamp + RAMP - 1 days);
        // w(20d/21d) = 5000 + 5000*20/21 = 9761 bps (integer floor); of 400,000 that is 390,440.
        assertEq(defaultManager.pendingSeniorImpairment(), 390_440e18, "20 of 21 days elapsed: 9,761 bps of 400,000");

        // A stranger marks the SECOND, tiny facility. It joins a LIVE cohort, so it INHERITS the
        // cohort's older, nearly-spent clock rather than restarting it.
        vm.prank(carol);
        defaultManager.markPastDue(dust);
        assertEq(defaultManager.pastDueContribution(dust), 1_000e18, "the dust facility really is marked");
        // 401,000 at 9,761 bps == 391,416.1 exactly. Written as a literal, NOT recomputed from the
        // contract's own ramp view, so a mutation of the ramp cannot slide the expectation with it.
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            3_914_161e17,
            "the second mark joins at the COHORT's weight, it does not reset it"
        );

        // ...and one more day still expires the whole cohort, dust facility included.
        vm.warp(block.timestamp + 1 days);
        assertEq(defaultManager.pendingSeniorImpairment(), 401_000e18, "the expiry fired on schedule");
    }

    /// @notice RAMP-5 — ...AND THE CLOCK DOES RESTART once the cohort empties. The relief is per
    ///         EPISODE, not once per deployment: a facility that goes past due long after an
    ///         earlier mark was cured gets its own full benefit of the doubt.
    ///
    ///         MUTATION (empty-pool condition, the other direction): change the condition to
    ///         `if ($.pastDueReliefAnchor == 0)` — a write-once anchor — so no later episode ever
    ///         gets relief again and every subsequent unattested mark is charged at full weight.
    ///         RED here.
    function test_g2w_ramp_theCohortClockRestartsOnceThePoolEmpties() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 first = _markedByStranger(400_000e18);

        vm.warp(block.timestamp + RAMP); // episode one expires
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "episode one at full weight");

        // The servicer cures it. The cohort is now empty.
        _attestPastDueCure(first, FILM_REF);
        vm.prank(servicer);
        defaultManager.clearPastDue(first, FILM_REF);
        assertEq(defaultManager.pastDueExposure(), 0, "cohort empty");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "and the mark is gone");

        // A NEW facility goes past due much later: fresh episode, fresh relief.
        vm.warp(block.timestamp + 400 days);
        _markedByStranger(400_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "a NEW episode gets its own benefit of doubt");
    }

    /// @notice RAMP-6 — THE RAMP'S SHAPE, PINNED TO LITERALS. Linear from the governed launch
    ///         weight to exactly `Config.BPS`, capped there forever, and never above it. The
    ///         expected values are arithmetic written out by hand, NOT read back from the contract.
    ///
    ///         MUTATION (ramp bound / fail-safe): any change to the interpolation, to the `>=`, or
    ///         to the cap -> RED here.
    function test_g2w_ramp_theWeightShapeIsPinnedToLiterals() public view {
        assertEq(RAMP, 21 days, "precondition: the ramp is one redemption cooldown");
        assertEq(registry.pastDueWeightBps(), 5_000, "precondition: launch weight");

        assertEq(registry.pastDueRampWeightBps(0), 5_000, "t=0: the launch weight exactly");
        assertEq(registry.pastDueRampWeightBps(RAMP / 4), 6_250, "t=1/4: 5000 + 5000/4");
        assertEq(registry.pastDueRampWeightBps(RAMP / 2), 7_500, "t=1/2: 5000 + 5000/2");
        assertEq(registry.pastDueRampWeightBps((RAMP * 3) / 4), 8_750, "t=3/4: 5000 + 3*5000/4");
        assertEq(registry.pastDueRampWeightBps(RAMP - 1), 9_999, "one second short: NOT yet full");
        assertEq(registry.pastDueRampWeightBps(RAMP), 10_000, "t=ramp: exactly full");
        assertEq(registry.pastDueRampWeightBps(RAMP + 1), 10_000, "past the ramp: still exactly full");
        assertEq(registry.pastDueRampWeightBps(type(uint256).max), 10_000, "and NEVER above full, at any elapsed");
    }

    /// @notice RAMP-7 — AN UNSET ANCHOR FAILS SAFE TO FULL WEIGHT. The anchor is an appended
    ///         namespaced-storage slot, so it reads ZERO on every proxy upgraded from a pre-G2W
    ///         implementation. Zero must be read as "no relief", never as "freshly marked, maximum
    ///         relief" — the latter would hand every legacy proxy a silent 50% under-mark on the
    ///         senior exit price the moment it upgraded.
    ///
    ///         MUTATION (fail-safe): add `if (anchor == 0) anchor = block.timestamp;` to
    ///         `conservativeSeniorMark`, or flip the `elapsed >= ramp` sense -> RED here.
    function test_g2w_ramp_anUnsetAnchorFailsSafeToFullWeight() public {
        // The vault must hold more than the charge, or the EXECUTABLE CLAMP (not the ramp) is what
        // binds and the test would measure the wrong guard.
        _stake(alice, 1_000_000e18);
        assertGt(vault.totalAssets(), 400_000e18, "precondition: the clamp is not the binding constraint");

        // 400,000 of unattested senior residual, no attested cohort, a vault far above the clamp.
        uint256 marked = registry.conservativeSeniorMark(400_000e18, 400_000e18, address(vault), 0);
        assertEq(marked, 400_000e18, "an UNSET anchor is read as fully expired relief, i.e. FULL weight");
        // ...and a live anchor at `block.timestamp` is the relieved end of the same ramp.
        assertEq(
            registry.conservativeSeniorMark(400_000e18, 400_000e18, address(vault), block.timestamp),
            200_000e18,
            "control: a FRESH anchor is the relieved end"
        );
    }

    /// @notice RAMP-8 — MONOTONE NON-DECREASING IN ELAPSED. The reported mark must never FALL as
    ///         time passes with nothing else changing, or a redeemer could profit purely by
    ///         waiting and the queue would develop a timing game. Fuzzed over the whole ramp and
    ///         well past it.
    function testFuzz_g2w_ramp_theMarkNeverFallsAsTimePasses(uint256 a, uint256 b) public {
        _stake(alice, 1_000_000e18); // so the ramp, not the executable clamp, is what varies
        a = bound(a, 0, RAMP * 3);
        b = bound(b, 0, RAMP * 3);
        if (a > b) (a, b) = (b, a);
        assertLe(registry.pastDueRampWeightBps(a), registry.pastDueRampWeightBps(b), "weight is non-decreasing");
        assertLe(
            registry.conservativeSeniorMark(400_000e18, 400_000e18, address(vault), block.timestamp - a),
            registry.conservativeSeniorMark(400_000e18, 400_000e18, address(vault), block.timestamp - b),
            "and so is the mark it produces"
        );
        assertGe(registry.pastDueRampWeightBps(a), registry.pastDueWeightBps(), "never below the governed floor");
        assertLe(registry.pastDueRampWeightBps(b), Config.BPS, "never above full weight");
    }

    /// @notice RAMP-9 — A SENIOR WHO REQUESTS AT OR AFTER THE MARK CANNOT SETTLE BEFORE THE RELIEF
    ///         HAS FULLY EXPIRED. This is the bound that keeps the ramp from being a free exit: the
    ///         queue cooldown and the relief ramp are the SAME length, so anyone who reacts to a
    ///         mark by queueing is priced at FULL weight when they settle. Only a senior already
    ///         part-way through a cooldown when the mark lands settles part-way up the ramp — and
    ///         that residual is measured, not hidden, in
    ///         `test_h5_queuedSeniorCannotSettleAtParOncePastDue`.
    ///
    ///         MUTATION (ramp bound): lengthen the ramp beyond `DEFAULT_REDEEM_COOLDOWN` -> RED.
    function test_g2w_ramp_aSeniorWhoRequestsAtTheMarkCannotSettleBeforeFullWeight() public {
        _openLaunchRampLimitsForFilm();
        vm.prank(admin);
        queue.setEpochLiquidityBps(10_000); // isolate PRICE from throttle
        _mintUSDfrTo(bob, 2_000_000e18);
        _stake(alice, 1_000_000e18);
        uint256 shares = vault.balanceOf(alice);

        _markedByStranger(400_000e18);
        uint256 markedAt = block.timestamp;
        assertEq(vault.previewRedeem(shares), 800_000e18, "at the mark: relieved price");

        // Alice reacts to the mark and queues immediately.
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(shares);
        vm.stopPrank();

        uint256 settleAt = queue.eligibleToSettleAt(reqId);
        assertGe(settleAt - markedAt, RAMP, "the cooldown is at least as long as the relief ramp");

        vm.warp(settleAt);
        queue.closeEpoch(10);
        (, uint256 remaining, uint256 claimable,,) = queue.request(reqId);
        assertEq(remaining, 0, "fully served");
        assertEq(claimable, 600_000e18, "settles at FULL weight: 1,000,000 - 400,000, not at the relieved price");
    }

    /// @notice RAMP-10 — THE RAMP DOES NOT TOUCH THE ATTESTED COHORT. An attested declared default
    ///         is neither clamped nor weighted nor ramped: it is at full weight from the first
    ///         block and stays there. If the ramp ever reached it, a fresh attested default would
    ///         be under-marked by half — the exact D5-03 shape, on the path that HAS evidence.
    ///
    ///         MUTATION (clamp/weight order): apply the weight to `residual` instead of to the
    ///         past-due slice -> RED here.
    function test_g2w_ramp_theAttestedCohortIsNeverRamped() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _liveFilmFacility(400_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "attested: FULL weight in the same block");
        vm.warp(block.timestamp + RAMP * 5);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "and unmoved by any amount of elapsed time");
    }

    /// @notice RAMP-11 — CONVERTING AN UNATTESTED MARK TO AN ATTESTED DEFAULT SKIPS THE RAMP
    ///         ENTIRELY. `declareDefault` releases the past-due contribution and records a declared
    ///         one, so the facility jumps straight to full weight regardless of where its cohort's
    ///         relief clock stood. That is the incentive the whole design rests on: attesting is
    ///         the way to make the mark bite immediately.
    function test_g2w_ramp_attestingImmediatelySkipsTheRemainingRelief() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 2_000_000e18);
        uint256 id = _markedByStranger(400_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 200_000e18, "unattested, freshly marked: half weight");

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18, "attestation takes it to full weight NOW");
        assertEq(defaultManager.pastDueExposure(), 0, "and out of the unattested cohort entirely");
    }

    /// @notice RAMP-12 — A GOVERNED RE-TUNE MOVES THE RAMP'S FLOOR, NEVER ITS CEILING. Whatever
    ///         weight governance sets is where the ramp STARTS; it always finishes at full weight
    ///         after one cooldown. Governance can decide how much benefit of the doubt to extend,
    ///         not whether it expires.
    ///
    ///         MUTATION: make the ramp interpolate towards `pastDueWeightBps()` instead of towards
    ///         `Config.BPS` -> RED here.
    function test_g2w_ramp_aGovernedRetuneMovesTheFloorNotTheCeiling() public {
        vm.prank(admin);
        registry.setPastDueWeight(2_000);

        assertEq(registry.pastDueRampWeightBps(0), 2_000, "starts at the newly governed floor");
        assertEq(registry.pastDueRampWeightBps(RAMP / 2), 6_000, "2000 + 8000/2");
        assertEq(registry.pastDueRampWeightBps(RAMP), 10_000, "and still finishes at FULL weight");

        vm.prank(admin);
        registry.setPastDueWeight(9_999);
        assertEq(registry.pastDueRampWeightBps(0), 9_999, "a near-parity floor is still a floor");
        assertEq(registry.pastDueRampWeightBps(RAMP), 10_000, "ceiling unchanged");
    }

    // ── MUTATION-CAMPAIGN GAP CLOSURES ───────────────────────────────────
    //
    //  Both tests below exist because the 35-mutation campaign found the suite BLIND to them:
    //  M15 and M23 survived the whole deterministic tier AND the stateful credit campaign. Neither
    //  gap was in the contract; both were in the tests. They are recorded rather than quietly
    //  patched, because "the mutation campaign found nothing" is the claim that should make a
    //  reviewer suspicious, not the claim that it found two.

    /// @notice RAMP-13 — THE CLAMP NETS THE ATTESTED COHORT, NOT JUST THE VAULT.
    ///
    ///         GAP FOUND BY MUTATION M15. `test_g2w_attestedCohortHasFirstClaimOnTheExecutableCapacity`
    ///         was written with the attested cohort claiming the vault EXACTLY, so
    ///         `vaultAssets > declaredSenior` was false and BOTH the correct expression and the
    ///         mutant `vaultAssets > declaredSenior ? vaultAssets : 0` took the same `else` branch
    ///         and returned zero. The test proved the boundary and nothing on either side of it, so
    ///         a mutant that hands the unattested cohort capacity the attested cohort has already
    ///         spent survived the entire deterministic tier and the stateful campaign.
    ///
    ///         This drives the STRICTLY-GREATER branch, where the two expressions disagree.
    ///
    ///         MUTATION: `uint256 executable = vaultAssets > declaredSenior ? vaultAssets : 0;`
    ///         in `CollateralRegistry.conservativeSeniorMark` -> RED here.
    function test_g2w_ramp_theClampNetsTheAttestedCohortNotJustTheVault() public {
        _openLaunchRampLimitsForFilm();
        _stake(alice, 500_000e18);

        // Attested cohort takes 300,000 of the 500,000 senior tranche. 200,000 of executable
        // capacity is left — STRICTLY less than the vault, which is the whole point.
        uint256 declared = _liveFilmFacility(300_000e18);
        _attestDefault(declared);
        vm.prank(servicer);
        defaultManager.declareDefault(declared, FILM_REF);
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "attested cohort at full weight");

        // A stranger marks 400,000 past due. Only 200,000 of that is executable.
        _markedByStranger(400_000e18);
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            300_000e18 + 100_000e18, // 300k attested + 50% of the executable 200k
            "the unattested cohort reaches only what the ATTESTED cohort left, then is weighted"
        );
        // The mutant reports 300k + 50% of 400k = 500k, i.e. it lets the unattested cohort spend
        // layer-3 capacity the attested cohort can already burn this block.
        assertLt(
            defaultManager.pendingSeniorImpairment(), 500_000e18, "the attested cohort's claim is not double-spent"
        );
    }

    /// @notice RAMP-14 — THE RAMPED WEIGHT ROUNDS UP, AT EVERY POINT ON THE RAMP.
    ///
    ///         GAP FOUND BY MUTATION M23. `test_g2w_theWeightRoundsUpNotDown` pins the rounding of
    ///         `weightedPastDueImpairment`, which is a DIFFERENT function from the one on the value
    ///         path: `conservativeSeniorMark` carries its own `+ Config.BPS - 1`. Dropping that term
    ///         survived the whole deterministic tier and the stateful campaign, because every
    ///         fixture amount in the suite happened to divide exactly at 5,000 bps.
    ///
    ///         Over-marking is the safe direction (D5-03 records under-marking as the dangerous
    ///         one), so the rounding dust must always land against the exiting senior.
    ///
    ///         MUTATION: drop `+ Config.BPS - 1` from `conservativeSeniorMark` -> RED here.
    function test_g2w_ramp_theRampedWeightRoundsUpAtEveryPointOnTheRamp() public {
        _stake(alice, 1_000_000e18); // so the executable clamp is never the binding constraint
        vm.prank(admin);
        registry.setPastDueWeight(3_333); // a weight that does NOT divide evenly

        // t = 0, weight 3,333 bps. 3 wei * 3333 / 10000 = 0.9999 -> rounds UP to 1, not down to 0.
        assertEq(registry.conservativeSeniorMark(3, 3, address(vault), block.timestamp), 1, "t=0 rounds UP");
        // t = ramp/2, weight 3333 + (10000-3333)/2 = 6,666 bps. 3 * 6666 / 10000 = 1.9998 -> 2.
        assertEq(
            registry.conservativeSeniorMark(3, 3, address(vault), block.timestamp - RAMP / 2), 2, "mid-ramp rounds UP"
        );
        // ...and nothing is invented from nothing, at any elapsed.
        assertEq(registry.conservativeSeniorMark(0, 0, address(vault), block.timestamp), 0, "zero stays zero at t=0");
        assertEq(
            registry.conservativeSeniorMark(0, 0, address(vault), block.timestamp - RAMP), 0, "and past the expiry"
        );
        // The attested half is never touched by the rounding: it is added, not scaled.
        assertEq(
            registry.conservativeSeniorMark(3, 1_003, address(vault), block.timestamp),
            1_001,
            "1,000 attested at full weight, plus the rounded-up 1 wei of unattested charge"
        );
    }
}
