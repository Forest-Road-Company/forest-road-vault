// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CollateralFixture} from "../helpers/CollateralFixture.sol";
import {CollateralHandler} from "./handlers/CollateralHandler.sol";

/// @dev Stateful-fuzz invariants for the collateral layer (CLAUDE.md §1.3):
///      - MINT GATE:      no facility NFT exists whose required attestations were not
///                        all satisfied at mint time (synchronized-mint invariant)
///      - CONCENTRATION:  limits are an ADMISSION control (AUDIT FIX M-02): a dimension
///                        standing above its limit is always disclosed, and once the book
///                        clears the bootstrap floor it can never be grown further
///      - ADMISSION:      every origination attempt is admitted or rejected exactly as an
///                        INDEPENDENT reference model of the gate + the three concentration
///                        dimensions says it must be, and for the same reason
///      - RECONCILIATION: registry total == Σ class exposures == Σ live facility
///                        principals as tracked by the handler, and the registry's whole
///                        exposure book equals a model maintained outside it
///
///      REVIEW FIX (collateral false green): before this pass the handler swallowed every
///      failed origination in a bare `catch {}`, so a mutation killing the admission path
///      outright still produced `3 passed`. See `CollateralHandler` and `afterInvariant`.
contract CollateralInvariants is CollateralFixture {
    CollateralHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CollateralHandler(bridge, registry, oracle, originator, creditModule, custodian, admin);
        // Deterministic floor for the anti-vacuity assertions (see `afterInvariant`).
        handler.seedAdmissionShapes();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CollateralHandler.flipAttestations.selector;
        selectors[1] = CollateralHandler.tryOriginate.selector;
        selectors[2] = CollateralHandler.advanceLifecycle.selector;
        selectors[3] = CollateralHandler.repayAndClose.selector;
        selectors[4] = CollateralHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_mintGate_neverBypassed() public view {
        uint256 n = bridge.totalOriginated();
        for (uint256 id = 1; id <= n; ++id) {
            assertTrue(handler.gateSatisfiedAtMint(id), "NFT EXISTS WITHOUT SATISFIED GATE");
            // AUDIT FIX (H-4): existence of the attestations is not enough — the CreditIssued
            // payload must have committed to the very terms that minted.
            assertTrue(handler.termsBoundAtMint(id), "NFT EXISTS WITHOUT BOUND TERMS");
        }
    }

    /// @dev ANTI-VACUITY control for `invariant_mintGate_neverBypassed` (AUDIT FIX H-4).
    ///      The terms binding must keep BAD originations out WITHOUT blocking every
    ///      origination — if the handler could no longer mint at all, the gate invariant
    ///      above would pass by proving nothing. Deterministic (not an invariant) so it
    ///      cannot flake on a seed that happened to explore no successful mint.
    /// @dev MERGE NOTE: counted as a DELTA over the deterministic floor that
    ///      `seedAdmissionShapes` leaves behind, not against zero. `gateSeed = 0` deliberately
    ///      leaves the attestation bits exactly as `flipAttestations` set them, so this test
    ///      exercises the terms dimension in isolation from the gate-steering dimension.
    function test_handler_stillMintsWhenTermsAreBound() public {
        uint256 mintsBefore = handler.mintCount();
        uint256 nextId = bridge.totalOriginated() + 1;
        handler.flipAttestations(31); // all four kinds satisfied + a fresh mark
        handler.tryOriginate(0, 0, 0, 100_000e18, 0, 1); // film class, termsSeed 1 => bind
        assertEq(handler.mintCount(), mintsBefore + 1, "BINDING BLOCKS EVERY ORIGINATION");
        assertTrue(handler.termsBoundAtMint(nextId), "minted facility should carry bound terms");
        assertTrue(handler.gateSatisfiedAtMint(nextId), "minted facility should carry a satisfied gate");
        assertEq(handler.ghostUnexpectedRejections(), 0, "a valid origination was rejected");
    }

    /// @dev The same call with a DIVERGENT payload must mint nothing (the H-4 defect), and
    ///      must be refused ON THE TERMS BINDING — asserting only "nothing minted" would pass
    ///      if some unrelated gate happened to reject it.
    function test_handler_mintsNothingWhenTermsDiverge() public {
        uint256 mintsBefore = handler.mintCount();
        uint256 termsRejectsBefore = handler.ghostRejectTermsNotAttested();
        handler.flipAttestations(31);
        handler.tryOriginate(0, 0, 0, 100_000e18, 0, 0); // termsSeed 0 => divergent payload
        assertEq(handler.mintCount(), mintsBefore, "UNBOUND TERMS STILL MINTED");
        assertEq(
            handler.ghostRejectTermsNotAttested(),
            termsRejectsBefore + 1,
            "NOT REFUSED ON THE TERMS BINDING (something else rejected it)"
        );
        assertEq(handler.ghostWrongReason(), 0, "REFUSED FOR THE WRONG REASON");
    }

    /// @dev AUDIT FIX M-02 — restated to the property that ACTUALLY holds. The previous
    ///      formulation ("above the bootstrap floor, no dimension ever exceeds its limit")
    ///      is not a reachable-state property of any amortising book: a repayment, a
    ///      default write-down or a cancellation shrinks the book and mechanically raises
    ///      the share held by whatever did not shrink, and none of those may ever be
    ///      blocked — a concentration check able to revert `realizeLoss` would put a risk
    ///      limit ahead of the loss cascade. Limits are an ADMISSION control. What holds
    ///      in every reachable state is:
    ///        - DISCLOSURE: a dimension standing above its limit is reported as such; and
    ///        - NO DEEPENING: a dimension already above its limit measured against
    ///          `max(book, bootstrapFloor)` — the rule the contract actually enforces — has
    ///          zero admission headroom, at ANY book size and ANY floor setting. It can
    ///          stand in breach, it can never be moved further into one.
    ///      Round-2 note: the "no deepening" half is deliberately NOT gated on
    ///      `total > floor` any more. Gating it there made the assertion vacuous at the
    ///      shipped 25,000,000e18 floor, which is exactly where a reviewer proved the
    ///      enforcement was inert.
    function invariant_concentration_limitsHold() public view {
        uint256 total = registry.totalBookExposure();
        (uint16 bLimit, uint16 sLimit, uint256 floor) = registry.limits();
        uint256 base = total > floor ? total : floor; // the book size the limits measure against
        bytes32 probe = keccak256("probe-borrower-with-no-exposure");

        uint256 disclosed;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 exp = registry.classExposure(c);
            uint256 limit = registry.classParams(c).concentrationLimitBps;
            if (exp * Config.BPS > limit * total) disclosed |= 1 << (c - 1);
            if (exp > limit * base / Config.BPS) {
                assertEq(registry.concentrationHeadroom(c, probe, bytes32(0)), 0, "BREACHED CLASS CAN GROW");
            }
        }
        assertEq(registry.overConcentratedClasses(), disclosed, "UNDISCLOSED CLASS CONCENTRATION");

        for (uint256 i = 0; i < handler.borrowerCount(); ++i) {
            bytes32 b = handler.borrowerAt(i);
            uint256 exp = registry.borrowerExposure(b);
            bool over = exp * Config.BPS > uint256(bLimit) * total;
            (, bool reported,) = registry.isOverConcentrated(1, b, bytes32(0));
            assertEq(reported, over, "UNDISCLOSED BORROWER CONCENTRATION");
            bytes32[] memory ids = new bytes32[](1);
            ids[0] = b;
            assertEq(registry.overConcentratedBorrowers(ids)[0], over, "BORROWER BATCH VIEW DISAGREES");
            if (exp > uint256(bLimit) * base / Config.BPS) {
                for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
                    assertEq(registry.concentrationHeadroom(c, b, bytes32(0)), 0, "BREACHED BORROWER CAN GROW");
                }
            }
        }
        for (uint256 i = 0; i < handler.stateCount(); ++i) {
            bytes32 st = handler.stateAt(i);
            uint256 exp = registry.stateExposure(st);
            bool over = st != bytes32(0) && exp * Config.BPS > uint256(sLimit) * total;
            (,, bool reported) = registry.isOverConcentrated(1, handler.borrowerAt(0), st);
            assertEq(reported, over, "UNDISCLOSED STATE CONCENTRATION");
            bytes32[] memory ids = new bytes32[](1);
            ids[0] = st;
            assertEq(registry.overConcentratedStates(ids)[0], over, "STATE BATCH VIEW DISAGREES");
            if (st != bytes32(0) && exp > uint256(sLimit) * base / Config.BPS) {
                for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
                    assertEq(registry.concentrationHeadroom(c, handler.borrowerAt(0), st), 0, "BREACHED STATE CAN GROW");
                }
            }
        }
    }

    function invariant_exposure_reconciles() public view {
        uint256 sumClasses;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            sumClasses += registry.classExposure(c);
        }
        assertEq(sumClasses, registry.totalBookExposure(), "CLASS SUM != TOTAL");
        assertEq(registry.totalBookExposure(), handler.ghostLivePrincipal(), "REGISTRY != LIVE FACILITIES");
    }

    /// @notice CLAUDE.md 1.3 — MINT GATE and CONCENTRATION, as an ADMISSION property
    ///         checked against an independent reference model.
    /// @dev REVIEW FIX (collateral false green). This is the invariant the suite was
    ///      missing. For every origination attempt the handler predicts, from state it
    ///      owns, whether the attempt must be admitted and — if not — with which specific
    ///      error. Four ways the contract can disagree with that model, all fatal:
    ///        - it ADMITTED something the gate or a limit had to reject (bypass);
    ///        - it REJECTED something that satisfied every condition (unexpected rejection,
    ///          which is what a dead or over-tight admission path looks like);
    ///        - it rejected for the WRONG reason (e.g. the borrower check firing where the
    ///          class check should have, i.e. two dimensions swapped).
    ///      Because the model never reads the registry's or the bridge's own accounting,
    ///      a bug in that accounting cannot make the check agree with itself.
    function invariant_admission_matchesModel() public view {
        assertEq(
            handler.ghostGateBypasses(), 0, "MINT GATE BYPASSED: a facility minted without every required attestation"
        );
        assertEq(
            handler.ghostLimitBypasses(),
            0,
            "CONCENTRATION LIMIT BYPASSED: an origination admitted above a dimension's cap"
        );
        assertEq(
            handler.ghostUnexpectedRejections(),
            0,
            "ADMISSION REJECTED A VALID ORIGINATION (see ghostLastUnexpectedSelector)"
        );
        assertEq(
            handler.ghostWrongReason(),
            0,
            "ADMISSION REJECTED FOR THE WRONG REASON (see ghostLastExpected/UnexpectedSelector)"
        );
    }

    /// @notice The registry's exposure book equals an independently maintained model of it.
    /// @dev Deliberately NOT derived from `registry`: the handler adds and subtracts the
    ///      principals itself. `invariant_exposure_reconciles` only proves the registry is
    ///      self-consistent; this proves it is RIGHT.
    function invariant_exposure_matchesModel() public view {
        assertEq(registry.totalBookExposure(), handler.modelTotalExposure(), "TOTAL EXPOSURE != MODEL");
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(registry.classExposure(c), handler.modelClassExposure(c), "CLASS EXPOSURE != MODEL");
        }
        for (uint256 i = 0; i < handler.borrowerCount(); ++i) {
            bytes32 b = handler.borrowerAt(i);
            assertEq(registry.borrowerExposure(b), handler.modelBorrowerExposure(b), "BORROWER EXPOSURE != MODEL");
        }
        for (uint256 i = 0; i < handler.stateCount(); ++i) {
            bytes32 s = handler.stateAt(i);
            assertEq(registry.stateExposure(s), handler.modelStateExposure(s), "STATE EXPOSURE != MODEL");
        }
    }

    /// @notice ANTI-VACUITY, asserted. Same pattern as `GovernanceInvariants.afterInvariant`,
    ///         which this repo introduced for exactly this class of false green.
    /// @dev REVIEW FIX (collateral false green). Measured before this existed: a mutation
    ///      that killed `ClaimBridge.originate` outright still produced `3 passed; 0 failed`
    ///      over 256 runs x 32,768 calls, with ~6,400 dead `tryOriginate` calls per run
    ///      reported as `reverts: 0`. Every invariant above is trivially true on an empty
    ///      book, so "the book was never built" MUST be a failure, not a pass.
    ///
    ///      WHY THE RAW FLOOR IS VACUOUS, AND WHAT REPLACES IT. Forge restarts every run from
    ///      the post-`setUp` state and `afterInvariant` runs ONCE, against the counters of the
    ///      single run it terminates — measured: at runs=3 the raw attempt count is the seed
    ///      floor (11) plus exactly one run's contribution, never three runs' worth. Because
    ///      `seedAdmissionShapes` drives one of every shape in `setUp`, every RAW counter is
    ///      already non-zero at the start of that final run. So a raw `assertGt(counter, 0)`
    ///      cannot detect a campaign that contributed nothing: a reviewer proved that removing
    ///      `tryOriginate` from the target selectors entirely still left the suite green,
    ///      because the seed alone kept every raw floor above zero. The guard is in two bases:
    ///
    ///      (1) FUZZ-ONLY DELTA on ATTEMPTS (`fuzzOnlyCounts().attempts`, the terminating run's
    ///      origination attempts ABOVE the seed floor). This is the tooth the "selector wiring
    ///      broken" message always claimed to be and never was. `tryOriginate` is one of six
    ///      fuzzed selectors, so over a 128-call run the fuzz-only attempt count is large and
    ///      far from zero — measured 16..30 across 9 seeds, and a value of zero requires the
    ///      selector to fire zero times in 128 draws (~(5/6)^128 ~ 1e-10), i.e. a wiring break,
    ///      not luck. Remove `tryOriginate` from the campaign and this delta is exactly zero,
    ///      so `afterInvariant` FAILS — which is the property the reviewers asked for.
    ///
    ///      (2) SEED-BACKED RAW ABSOLUTES for every other dimension. These are DELIBERATELY not
    ///      on the fuzz-only delta, because `afterInvariant` sees only ONE run and a single
    ///      run's fuzz reach is not reliable enough to assert without flaking. MEASURED
    ///      fuzz-only reach of the terminating run across 9 seeds (attempts, successes, gate,
    ///      class, closures):
    ///        attempts   16 20 22 26 16 30 27 21 20   -> never 0 (the tooth above)
    ///        successes   1  0  2  3  1  4  3  2  2   -> 0 at seed 2        (would flake)
    ///        gate        4  8  4  3  3  2  2  4  4   -> low as 2           (would flake)
    ///        class       8  7  8 10  5 12 14  8 12   -> low as 5          (thin per run)
    ///        closures    0  0  0  2  0  2  2  2  2   -> 0 in 4/9 seeds     (badly flaky)
    ///      Asserting successes/gate/class/closures on the delta therefore WOULD flake — the
    ///      task's 39-40/40 reach figures were per single-run campaign and, sampled once by
    ///      `afterInvariant`, are not a safe floor. They stay backed by `seedAdmissionShapes`,
    ///      which drives one of each before every run, so what these assertions guarantee is
    ///      that every run was evaluated against a state where the mint gate, the terms
    ///      binding, all three concentration dimensions, a lifecycle transition and a closure
    ///      actually existed. The fuzz reach above that floor is a readout (`fuzzOnlyCounts`),
    ///      not a floor.
    ///
    ///      MERGE NOTE (AUDIT FIX H-4): the terms-binding rejection is seed-backed here, and is
    ///      the anti-vacuity control for the H-4 half of `invariant_mintGate_neverBypassed` in
    ///      the other direction: if the binding were removed from `ClaimBridge`,
    ///      `seedAdmissionShapes` would fail its `ghostRejectTermsNotAttested == 1` post-seed
    ///      assertion, so the seed floor cannot quietly mask a dead binding.
    function afterInvariant() public view {
        // (1) Fuzz-only delta on ATTEMPTS — the anti-vacuity tooth. A dead/unwired
        //     `tryOriginate` selector makes this exactly zero, so the guard FAILS even though
        //     the seed left every raw counter non-zero. Robust to seed (measured 16..30).
        (uint256 fuzzAttempts,,,,,,,) = handler.fuzzOnlyCounts();
        assertGt(fuzzAttempts, 0, "FUZZ CAMPAIGN NEVER ATTEMPTED AN ORIGINATION (selector wiring broken)");

        // (2) Seed-backed raw absolutes — one run's fuzz reach of these is too thin to assert
        //     without flaking (see the measured table above), so the deterministic seed
        //     guarantees every run was evaluated against a state where each shape existed.
        assertGt(handler.ghostOriginateSuccesses(), 0, "NOTHING WAS EVER ORIGINATED (suite is vacuous)");
        assertGt(handler.ghostRejectGate(), 0, "MINT GATE NEVER BLOCKED AN UNATTESTED ORIGINATION");
        assertGt(handler.ghostRejectTermsNotAttested(), 0, "TERMS BINDING NEVER BLOCKED AN UNBOUND ORIGINATION");
        assertGt(handler.ghostConcentrationRejections(), 0, "NO CONCENTRATION LIMIT EVER BOUND");
        assertGt(handler.ghostRejectBorrowerConcentration(), 0, "BORROWER LIMIT NEVER BOUND");
        assertGt(handler.ghostRejectClassConcentration(), 0, "CLASS LIMIT NEVER BOUND");
        assertGt(handler.ghostLifecycleTransitions(), 0, "NO FACILITY EVER LEFT PENDING");
        assertGt(handler.ghostRepayClosures(), 0, "NO FACILITY EVER CLOSED (the decrease path is untested)");
    }
}
