// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {ICommitmentLedger} from "./interfaces/ICommitmentLedger.sol";
import {IConservativeImpairmentBook} from "./interfaces/IConservativeImpairmentBook.sol";

/// @title ConservativeImpairmentMath — the ADR-0022 conservative-redemption NAV arithmetic
/// @notice Routes the event-aware junior-cascade residual from `CommitmentLedger` through the
///         governed G2W unattested-past-due clamp and relief ramp. W7 deliberately changes the
///         pre-W7 aggregate arithmetic: exact undrawn-event re-snapshotting cannot be derived from
///         the old class aggregates.
/// @dev **STATELESS AND UNPRIVILEGED BY CONSTRUCTION.** No storage, no constructor arguments, no
///      roles, no upgrade hook, no value handling. Every external call it makes is `view`, hence a
///      `STATICCALL`: the book it is handed, that book's ledger and registry, and the vault read
///      performed by the registry. That is what makes it safe for the caller to be a bare forwarder: there is nothing
///      here for an attacker to own, and a caller that passes a hostile `book` can only lie to
///      itself about its own numbers — it cannot move state anywhere, because a `STATICCALL`
///      cannot.
///
///      **IT DOES NOT CHOOSE ITS COUNTERPARTIES.** The ledger, registry and vault are all read out
///      of the book's own `modules()` — i.e. whatever governance wired
///      into the `DefaultManager` being marked. This calculator has no addresses of its own and no
///      way to substitute any of them.
///
///      **WHY IT TAKES THE BOOK AS A PARAMETER RATHER THAN IMPLEMENTING `IImpairmentSource`.**
///      `DefaultManager` is a UUPS proxy: the numbers live in the PROXY's storage while the
///      constructor that could bind an immutable book runs at the IMPLEMENTATION's address. A
///      constructor-bound instance would therefore read the wrong account. Passing the book per
///      call is what lets a single deployed instance serve the proxy, every future
///      `DefaultManager` implementation, and the differential tests.
///
///      **EVENT-AWARE EQUIVALENCE IS THE WHOLE POINT.** This result is consumed by the production
///      `sUSDfr` redemption mark (`redemptionTotalAssets` -> `previewRedeem`), the
///      `RedemptionQueue` fill path, `WaterfallEngine._withholdFeeForSeniorImpairment`, and
///      `AssessedImpairmentSource`, the live `IImpairmentSource` wired into the vault. The
///      ADR-0034 Y atomic junior-exit draw is **not** a consumer of this view: its
///      `_exitDrawTarget` sizes from custody deficit (`supply - backing`) and only consumes
///      sGROVE reserve as a clamp operand. `ConservativeImpairmentMathEquivalence.t.sol` fuzzes
///      this implementation against an independently structured reconstruction over published
///      event rows; the live counterpart verifies declaration, draw, recovery and release wiring.
///
///      **HISTORICAL PRE-W7 EXTRACTION MEASUREMENTS FOLLOW.** W7 replaces the aggregate read path
///      with a ledger walk, so the figures below are context, not current certification evidence;
///      `W7_PerEventLadder.t.sol` is the current hard-probe measurement. The manager is behind an ERC-1967 proxy, so every value this calculator reads back
///      costs a proxy delegatecall hop. RE-MEASURED ON THE MERGED TREE, 2026-08-08, with ONE
///      harness run against BOTH trees (same fixture, same cooling) rather than two reports
///      compared across sessions — the figures below therefore price the WHOLE change (the
///      extraction AND the G2W registry/vault reads it now also makes), which is what a reader of
///      the shipped build needs:
///        path                                        Y-BUILD -> MERGED     delta
///        `DefaultManager.pendingSeniorImpairment()`    9,286 ->  37,312   +28,026
///        `AssessedImpairmentSource` warm              10,940 ->  38,966   +28,026
///        `sUSDfr.redemptionTotalAssets`               14,180 ->  42,206   +28,026
///        `sUSDfr.previewRedeem`                       16,835 ->  44,861   +28,026
///        assessed source, COLD (the probe path)       56,948 ->  98,974   +42,026
///      Of the +28,026 warm, ~+21,800 is the extraction's proxy hops and ~+6,200 is G2W's
///      `CollateralRegistry.conservativeSeniorMark` call and the `sUSDfr.totalAssets()` read
///      inside it. THE TWO FIXES' GAS COSTS COMPOSE ON THE SAME READ; neither parent tree could
///      see that.
///
///      THE COLD LINE IS THE ONE WITH A HARD LIMIT.
///      `sUSDfr` probes its impairment source under `IMPAIRMENT_SOURCE_PROBE_GAS` and a source that
///      misses the budget is declared UNREADABLE — the conservative mark then drops out of
///      redemption pricing entirely, which is a silent under-mark.
///
///      ── AUDIT FIX (SWEEP-2 F-S2-01) — THIS PARAGRAPH USED TO BE FALSE. READ IT ALL. ──
///
///      It said: "98,974 of 200,000 leaves 50% headroom and sits 34,026 under the 133,000 ceiling
///      pinned by `test_markStaysWellInsideTheImpairmentSourceProbeBudget`". Both figures were
///      measured on a fixture that posts curator capital on all five classes but declares exactly
///      ONE default, in ONE class. The loop below does `if (d == 0) continue;` BEFORE
///      `curator.poolBalance(classId)`, so four of the five per-class proxy hops never happened;
///      the fixture also has no past-due cohort (so the `elapsed >= ramp` early return skips the
///      registry's `pastDueWeightBps()` read), no drawn cohort (so the PM-R-11
///      `liveDefaultCoverageRemaining` read never fires), and no ADR-0027 assessment (so
///      `AssessedImpairmentSource` never calls `impairmentStateHash()`, which loops all five
///      classes through `curator.poolBalance` a SECOND time).
///
///      RE-MEASURED ON THE PRODUCTION SHAPE (SWEEP-2 F-S2-01, same machine, same `vm.cool`
///      methodology; the one-class control reproduced the 98,974 figure to within 65 gas, which is
///      what makes these comparable):
///        1 impaired class, no past-due, no drawn cohort  (the OLD fixture)      98,909
///        5 impaired classes + past-due ramp + drawn cohort                     142,465
///        ... + a LIVE ADR-0027 assessment                                      166,691
///        ... + a permissionless `sGrove.fundCoverage` top-up under it          187,651
///      The last line is not adversarial: ADR-0027 explicitly requires a permissionless top-up NOT
///      to invalidate a standing assessment, so `_assessmentStateMatches` falls to the directional
///      path and re-reads `impairmentRiskStateHash()` — a THIRD five-class pass. That is the state
///      a workout is SUPPOSED to be in. Real headroom under the enforced 200,000 probe budget is
///      12,349 gas (6.2%).
///
///      CURRENT SHIPPED LIMITS. `sUSDfr.IMPAIRMENT_SOURCE_PROBE_GAS` is 200,000. The regression
///      suites use a separate 250,000 affordability ceiling; that test ceiling is not the runtime
///      gas cap and must not be cited as one. Under-budgeting the runtime probe can turn the
///      incident-response lever into something usable against a healthy source, so additions to
///      this path must fit the enforced 200,000 budget or trigger an explicit design decision.
///
///      THE PRODUCTION-SHAPE MEASUREMENT IS
///      `test_FS201_theProductionShapeFitsTheProbeBudgetWithRealHeadroom` in
///      `test/audit/SweepR2_Remediation.t.sol`. The one-class equivalence suite also currently pins
///      250,000, but it is not the production-shaped measurement. Anything that adds cross-contract
///      reads here must re-measure first against the 200,000 runtime cap.
///
///      **THREE CHEAPER-LOOKING DESIGNS WERE MEASURED AND ARE ALL WORSE.** Every one of them adds
///      a function to `DefaultManager`, and an external function there costs ~200 bytes of
///      dispatch and ABI encoding — more than the arithmetic it lets you move out. Runtime margin
///      on `DefaultManager`, starting from the 215 bytes it had BEFORE either fix (these variants
///      were measured pre-G2W, so compare them to the 622 that this design reached pre-G2W, not to
///      the 545 the merged build ships with):
///        one batched `impairmentInputs()` struct getter (19 words)   ->  12 bytes (WORSE)
///        the same batched read as a flat `uint256[19]`               -> 169 bytes (WORSE)
///        a per-class triple getter plus a globals getter             -> 219 bytes (no gain)
///        extracting ONLY the layer-2 netting as a pure function      ->  64 bytes (WORSE)
///        THIS DESIGN (reuse the getters that already existed)        -> 622 bytes
///      So the cheap-gas variants do not exist: reducing the hop count means giving the manager
///      back the bytes this whole change was made to recover. If the gas above is judged too
///      expensive, the answer is to REVERT the extraction and find margin elsewhere, not to batch
///      the reads.
///
///      **WHAT THE EXTRACTION BOUGHT, MEASURED ON THE MERGED BUILD.** `DefaultManager` ships with
///      545 bytes of runtime margin. The G2W synthesis alone costs it 204 bytes and it had 215, so
///      without this extraction the two fixes could not both have shipped — the ~2.1 KB of
///      arithmetic living here is exactly what made room for the owner decision.
contract ConservativeImpairmentMath {
    /// @notice Senior (`sUSDfr`) principal that declared-but-unrealized defaults recorded in
    ///         `book` would impair AFTER the junior layers absorb, in strict cascade order:
    ///         curator first-loss per CLASS, then the global sGROVE backstop.
    /// @dev ADR-0022 conservative-redemption NAV. Bounded loop over the fixed class set.
    ///
    ///      W7 retires the drawn/undrawn aggregate closed form. It is impossible in general: two
    ///      books can expose byte-identical aggregates while containing different event sizes and
    ///      class allocations, so their class-specific curator delivery differs. `CommitmentLedger`
    ///      therefore registers every declared event and walks the actual cascade in forward and
    ///      reverse declaration order. Under ADR-0035 drawn and undrawn rows both consume the same
    ///      shared live reserve; no row owns a ceiling or snapshot. Each event consumes its class
    ///      curator pool first, then the reserve still live at its turn. The lower of the two
    ///      full-realization ladders is the
    ///      conservative credit: it is neither above what the worst enumerated order can fund nor
    ///      below what that order physically delivers. This also removes W6's unconditional
    ///      subtraction of curator capital from drawn room, which under-credited a funded cohort
    ///      whose principals dominated every room in both orders.
    ///
    ///      ─────────────────────────────────────────────────────────────────────────────────────
    ///      OWNER DECISION 2026-08-07 (G2W): AN UNATTESTED PAST-DUE MARK IS NOT AN ATTESTED DEFAULT
    ///      ─────────────────────────────────────────────────────────────────────────────────────
    ///      "An unattested, permissionless past-due mark must NOT carry the same forward weight as
    ///      an attested declared default." Before this change the past-due pool was folded into `d`
    ///      on EXACTLY the same footing as `declaredDefaultedPrincipal`, so a single `markPastDue` —
    ///      `external nonReentrant`, NO ROLE, NO ATTESTATION — asserted a 100%-LGD outcome on the
    ///      facility's whole outstanding. Measured: $200k staked inside a $3.4m float, one call by
    ///      an unprivileged non-KYC address on an $800k facility drove
    ///      `sUSDfr.redemptionTotalAssets()` to ZERO and halted the only senior exit wholesale.
    ///
    ///      THE MISMATCH IS EXECUTABLE CHARGE versus ASSERTED CHARGE.
    ///        - `declareDefault` is SERVICER_ROLE + a consumed `DefaultDeclared` attestation quorum,
    ///          and it leads to `realizeLoss`. Its assertion IS executable. Full weight, unchanged.
    ///        - `markPastDue` leaves the facility `Active`/`Amortizing`. `realizeLoss` requires
    ///          `Defaulted`/`Accelerated`, so a merely past-due facility can NEVER reach the
    ///          cascade — its charge is STRUCTURALLY UNEXECUTABLE without the attested step.
    ///
    ///      THREE CORRECTIONS, IN THIS ORDER (the order is load-bearing; proofs in
    ///      `test/audit/Fix_G2W-unattested-past-due-weight.t.sol`).
    ///
    ///      (1) EXECUTABLE BOUND. The mark may not assert more than the cascade could actually
    ///          charge seniors if the facility went all the way to `realizeLoss` today. That bound
    ///          is read straight off the real path: layers 1 and 2 are already netted below; layer 3
    ///          burns from the vault and `realizeLoss` REVERTS with
    ///          `DefaultManager_LossExceedsAbsorptionCapacity` once `depositorLoss` exceeds
    ///          `IsUSDfr(vault).totalAssets()`. Anything past that is not an automatic senior charge
    ///          at all — ADR-0017 §3 makes beyond-capacity insolvency a governance decision
    ///          (`ReserveManager.recognizePrincipalImpairment`), and ADR-0027 puts it on unstaked
    ///          USDfr backing, which does not take residual credit loss. The ATTESTED cohort has
    ///          first claim on that capacity (it can call `realizeLoss` this block), so the past-due
    ///          cohort is clamped to what the declared cohort leaves. THE CLAMP DOES NOT EXPIRE: it
    ///          is a structural fact about the cascade, not a benefit of the doubt.
    ///
    ///      (2) WEIGHT. Discounted by the governed `CollateralRegistry.pastDueWeightBps()` — 5,000
    ///          bps at launch, DERIVED (see `Config.DEFAULT_PAST_DUE_WEIGHT_BPS`) from the
    ///          protocol's only governed evidence ladder: `markPastDue` is the receivable-side
    ///          analogue of the permissionless MARGIN-CALL rung, and governance placed that rung
    ///          exactly half way between the advance rung and the terminal `liquidate` rung.
    ///
    ///      (3) THE RELIEF EXPIRES (the adjudicated synthesis, 2026-08-07). The weight is a BENEFIT
    ///          OF THE DOUBT WITH AN EXPIRY: it ramps linearly from the governed launch weight back
    ///          to FULL over one `Config.DEFAULT_REDEEM_COOLDOWN` measured from
    ///          `IConservativeImpairmentBook.pastDueReliefAnchor()`. The doubt being extended is
    ///          "the servicer has not yet had time to attest"; after a full redemption cooldown that
    ///          doubt is spent, so the loud stop returns on its own with nobody having to act. This
    ///          is what bounds the D5-03 under-mark to a window instead of leaving it permanent.
    ///
    ///      THE UNDER-MARK WINDOW, STATED PLAINLY RATHER THAN GLOSSED. Inside the ramp the reported
    ///      mark is genuinely BELOW the loss a zero-recovery outcome would inflict, so a senior
    ///      whose cooldown elapses mid-ramp exits above the eventual honest price and the seniors
    ///      who stay wear the difference. That is the cost Forest Road accepted in exchange for not
    ///      letting one permissionless, unattested call halt the only senior exit. It is bounded in
    ///      TIME by the ramp (a senior who requests AT or AFTER the mark cannot settle before
    ///      `requestedAt + DEFAULT_REDEEM_COOLDOWN`, by which point the weight is FULL) and in SIZE
    ///      by `(BPS - w0)/BPS` of the executable charge. It is not bounded for a senior already
    ///      part-way through a cooldown when the mark lands — see
    ///      `test_h5_queuedSeniorCannotSettleAtParOncePastDue`, which measures exactly that senior.
    ///
    ///      THE COHORT CLOCK IS ONE GLOBAL ANCHOR, REVIEWED AND KEPT. The ramp clock is a property
    ///      of the whole unattested COHORT, not of a class or a facility, and this is a decision
    ///      rather than an accident:
    ///        - PER-FACILITY IS UNREPRESENTABLE HERE. This loop is over the five CLASSES and reads
    ///          only class aggregates; there is no facility enumeration to ramp against.
    ///        - PER-CLASS IS INCOMPATIBLE WITH THE ADJUDICATED ORDER. A per-class weight has to be
    ///          applied to per-class amounts, i.e. BEFORE aggregation — and therefore before the
    ///          clamp, because the clamp is inherently global (ONE `vault.totalAssets()`, ONE shared
    ///          layer-2 reserve, neither class-attributable). Weight-then-clamp collapses to
    ///          `min(w*P, E) == E` exactly when the mark is large, which is the case the owner
    ///          decision is about, so the fix would silently do nothing. See
    ///          `test_g2w_clampBeforeWeightIsNotTheSameAsWeightBeforeClamp`.
    ///        - THE RESIDUAL RUNS THE SAFE WAY. A facility joining a cohort that is already live
    ///          inherits the cohort's OLDER anchor, hence MORE elapsed, hence a HIGHER weight and a
    ///          LARGER mark. Over-marking is the safe direction (D5-03 records under-marking as the
    ///          dangerous one).
    ///        - THE COST, NAMED. A fresh mark in one class can be charged at FULL weight because an
    ///          unrelated facility in another class has been past due for over a cooldown. The
    ///          protocol is then in a state where it has had a full cooldown to attest or cure an
    ///          unattested mark and has done neither, so full weight is the honest posture; the
    ///          relief is available again the moment the cohort empties (`clearPastDue`, a full
    ///          performing repayment, or conversion by `declareDefault`), because
    ///          `DefaultManager.markPastDue` re-anchors on EMPTY -> non-empty.
    ///
    ///      IT IS TIME-VARYING, AND THAT INTERACTS WITH ADR-0027 ASSESSMENTS.
    ///      `DefaultManager.impairmentRevision` and `_impairmentRiskStateHash` do NOT move as the
    ///      ramp advances (nothing in storage changes), so a professional assessment taken early in
    ///      the ramp keeps pricing redemptions at the lower base until it expires.
    ///      `AssessedImpairmentSource` caps an assessment at the LIVE base, so this can only ever
    ///      hold the mark DOWN, never up, and it is bounded by `MAX_ASSESSMENT_TTL` (30 days) and
    ///      clearable in one transaction by `clearAssessment()`. Deliberately not wired through the
    ///      revision counter: it would require a storage write on a `view` path, which is
    ///      impossible, and a per-block revision bump would invalidate every assessment every block.
    ///
    ///      NO CIRCULARITY — AND THE TRAP IS NAMED. `CollateralRegistry.conservativeSeniorMark`
    ///      reads `IsUSDfr(vault).totalAssets()`, which is `USDfr.balanceOf(vault) -
    ///      unvestedYield()`: two storage reads and a token balance, none of which touches an
    ///      impairment source. It MUST NEVER be changed to `redemptionTotalAssets()`, which calls
    ///      back into this function through `AssessedImpairmentSource` and would make every
    ///      redemption an unbounded recursion. The full read edge `redemptionTotalAssets ->
    ///      AssessedImpairmentSource -> DefaultManager -> ConservativeImpairmentMath ->
    ///      CollateralRegistry -> totalAssets` terminates; `realizeLoss` and the live
    ///      `ReserveManager._absorbRecognizedReserveLoss` custody cascade already depend on exactly
    ///      the same `totalAssets()` edge, so no new module coupling is introduced.
    ///
    ///      ALLOCATION ORDER IS THE CONSERVATIVE ONE. Junior capacity (curator, then sGROVE) is
    ///      offered to the PAST-DUE cohort FIRST. With a fixed junior pool `J` split as
    ///      `j_pastDue + j_declared`, the reported mark is `(D - j_declared) + w*(P - j_pastDue)`,
    ///      which is MAXIMISED by sending all of `J` to the discounted cohort because `w < 1`. Total
    ///      past-due priority is preserved as the fixed policy step before the declared-event
    ///      forward/reverse ladder. W7 does not reinterpret a merely past-due facility as a
    ///      declared event: it has no executable loss row until the attested declaration occurs.
    ///
    ///      `pastDueSenior <= residual` IS A THEOREM, NOT AN ASSUMPTION — and it must be, because
    ///      the registry subtracts them and an underflow there would revert every redemption. W7
    ///      makes it structural: `pastDueSenior = pastDueGross - pastDueJunior`, while
    ///      `residual = pastDueSenior + (declaredGross - declaredJunior)`. Every event's junior
    ///      delivery is individually clamped by its remaining principal, so the parenthesized
    ///      declared term cannot be negative.
    ///
    ///      THE LOUD STOP STILL FIRES. The declared cohort is NOT clamped and NOT weighted, so a
    ///      genuine near-total senior loss on the attested path still drives the conservative NAV to
    ///      zero exactly as before.
    /// @param book The `DefaultManager` (proxy) whose impairment pool is being marked.
    /// @return The impairment in USDfr (18 decimals); zero when the junior layers fully cover.
    function pendingSeniorImpairment(address book) external view returns (uint256) {
        IConservativeImpairmentBook b = IConservativeImpairmentBook(book);
        address registry;
        address vault;
        address ledger;
        {
            (, address registryAddress,,,,, address vaultAddress, address ledgerAddress) = b.modules();
            registry = registryAddress;
            vault = vaultAddress;
            ledger = ledgerAddress;
        }
        // The standalone ledger owns the per-event data and the only implementation of the W7
        // ladder. It also preserves G2W's policy attribution by offering each class's curator pool
        // and the shared live layer-2 reserve to the discounted past-due cohort before declared
        // events.
        (uint256 residual, uint256 pastDueSenior) = ICommitmentLedger(ledger).conservativeResiduals();
        if (residual == 0) return 0;

        // ── steps (1), (2) and (3): the EXECUTABLE bound, then the RAMPED governed weight ──
        // This contract MEASURES the cascade and the registry APPLIES the governed policy to what
        // it measures. Splitting it that way keeps the whole owner-decision weight in one governed,
        // timelocked module rather than in an unprivileged calculator that no role can retune.
        //
        // THE ELAPSED TERM IS FAIL-SAFE BY CONSTRUCTION: an unset (zero) anchor makes the registry
        // compute `elapsed == block.timestamp`, which is always past the ramp, hence FULL weight —
        // the pre-G2W behaviour. DO NOT "fix" it with a zero check that substitutes a small
        // elapsed, and DO NOT pass anything other than the raw slot.
        //
        // `registry` and `vault` are the book's OWN governance-configured modules, read from
        // `modules()` above — this calculator never chooses them.
        //
        // DO NOT DELETE THIS CALL and return `residual` instead: that restores the defect, because
        // the unattested cohort would again carry the same forward weight as the attested one AND
        // would again assert a charge the cascade would revert on. Falsified by
        // `test_g2w_headlineScenarioNoLongerHaltsTheSeniorExit`.
        return ICollateralRegistry(registry).conservativeSeniorMark(
            pastDueSenior, residual, vault, b.pastDueReliefAnchor()
        );
    }
}
