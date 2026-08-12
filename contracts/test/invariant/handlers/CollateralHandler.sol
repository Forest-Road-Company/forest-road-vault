// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ClaimBridge} from "../../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../../src/CollateralRegistry.sol";
import {IAttestationOracle} from "../../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MockAttestationOracle} from "../../helpers/MockAttestationOracle.sol";

/// @title CollateralHandler
/// @notice Bounded handler for collateral-layer stateful fuzzing, built around an
///         INDEPENDENT REFERENCE MODEL of the admission rule.
/// @dev REVIEW FIX (collateral false green). The original version wrapped `originate` in a
///      bare `try/catch {}`. That made the whole suite vacuous: a mutation that killed the
///      admission path outright still produced `3 passed`, because every one of the ~6,400
///      `tryOriginate` calls per run simply fell into the empty catch (and, because the
///      handler itself did not revert, was reported by the call summary as `reverts: 0`).
///
///      The fix is a differential model, not a bigger catch block. Before every attempt the
///      handler PREDICTS the outcome — success, or rejection with one specific selector —
///      from state it maintains ITSELF:
///        - its own mirror of the attestation bits it asked the oracle to set,
///        - its own mirror of the `CreditIssued` TERMS payload it asked the oracle to carry,
///        - its own mirror of class/borrower/state/total exposure, and
///        - a hard-coded copy of the class parameters and required-attestation masks that
///          `CollateralFixture` configures (pinned against the live config once, in the
///          constructor, so a fixture change fails loudly instead of drifting silently).
///      Nothing in the prediction is read back out of `CollateralRegistry` or `ClaimBridge`,
///      so the model cannot be corrupted by the same bug it is meant to catch.
///
///      Every attempt then lands in exactly one of four buckets, all counted:
///        - agreed success                        -> `ghostOriginateSuccesses`
///        - agreed rejection, matching selector   -> the per-reason `ghostReject*` counters
///        - EXPECTED to succeed but reverted      -> `ghostUnexpectedRejections` (a bug)
///        - EXPECTED to be rejected but succeeded -> `ghostGateBypasses` / `ghostLimitBypasses`
///          (a bug), or the right rejection for the wrong reason -> `ghostWrongReason`
///      The bug buckets are asserted to be zero by `invariant_admission_matchesModel`, and
///      the anti-vacuity floors are asserted by `afterInvariant`. `fail_on_revert = true`
///      still holds: the handler never reverts, it records and lets the invariant fail.
///
///      MERGE NOTE — this file resolves two parallel rewrites of the same handler. The
///      reference model above is the "false green" fix; the TERMS COMMITMENT below is AUDIT
///      FIX H-4. They compose: the mint gate has two independent off-chain conditions now,
///      so the handler steers two independent dimensions and predicts both.
///        - `gateSeed`  — are the required attestation BITS set at the facility id? (This is
///          the existence question the gate always asked.)
///        - `termsSeed` — does the standing `CreditIssued` payload COMMIT TO THE TERMS being
///          originated? (This is the question the gate never asked before H-4 — a borrower
///          with zero attestations of his own drew 4.9M against another obligor's bundle.)
///      They are kept as separate parameters because they are genuinely orthogonal: bits set
///      + terms divergent is the H-4 attack, bits unset + terms bound is an ordinary
///      unattested facility, and collapsing them into one seed would make one of the two
///      rejection reasons unreachable. Both are exercised on every run, both have a
///      deterministic floor from `seedAdmissionShapes`, and `afterInvariant` asserts each
///      side actually bit.
contract CollateralHandler is Test {
    // ── wiring ───────────────────────────────────────────────────────────

    ClaimBridge internal bridge;
    CollateralRegistry internal registry;
    MockAttestationOracle internal oracle;
    address internal originator;
    address internal creditModule;
    address internal custodian;

    bytes32[3] internal borrowers = [keccak256("hb1"), keccak256("hb2"), keccak256("hb3")];
    bytes32[3] internal states = [keccak256("hs-GA"), keccak256("hs-NV"), bytes32(0)];

    /// @notice Thrown from the constructor when the hard-coded reference parameters no
    ///         longer match what `CollateralFixture` actually configured. The model would
    ///         otherwise be quietly wrong, so this aborts `setUp` instead.
    /// @param classId The class whose parameters drifted (0 = a global limit drifted,
    ///        `type(uint256).max` = the terms-commitment preimage drifted).
    error HandlerFixtureDrift(uint256 classId);

    // ── reference constants (mirrors of CollateralFixture / the registry defaults) ──

    /// @dev Test-scale bootstrap floor, set by this handler so the limits genuinely bind.
    uint256 internal constant CONC_FLOOR = 2_000_000e18;
    uint16 internal constant BORROWER_LIMIT_BPS = 1_500;
    uint16 internal constant STATE_LIMIT_BPS = 2_500;
    uint16 internal constant MAX_INTEREST_RATE_BPS = 10_000;
    uint256 internal constant MAX_SAFE_EXPOSURE = type(uint256).max / Config.BPS;
    /// @dev Sentinel `classId` for a drift in the terms-commitment preimage itself.
    uint256 internal constant DRIFT_TERMS_PREIMAGE = type(uint256).max;

    uint256 internal constant BIT_ASSIGNMENT = 1 << uint256(IAttestationOracle.AttestationKind.AssignmentExecuted);
    uint256 internal constant BIT_UCC = 1 << uint256(IAttestationOracle.AttestationKind.UCCFiled);
    uint256 internal constant BIT_CREDIT = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
    uint256 internal constant BIT_VALUATION = 1 << uint256(IAttestationOracle.AttestationKind.Valuation);

    /// @dev The handler's own copy of the per-class origination parameters.
    struct ClassRef {
        uint16 maxLtvBps;
        uint64 maxMaturity;
        uint16 concentrationLimitBps;
        bool markedToMarket;
        uint64 maxMarkAge;
        uint256 requiredMask;
    }

    /// @dev The candidate facility, held in memory so the origination path stays under the
    ///      stack limit now that the terms commitment is part of the flow (AUDIT FIX H-4).
    struct Candidate {
        uint256 nextId;
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 principal;
        uint16 ltvBps;
        uint16 interestRateBps;
        uint64 maturity;
        bytes32 offchainRef;
        /// @dev Does the presented `CreditIssued` payload commit to THESE terms?
        bool bindTerms;
        /// @dev Which flavour of divergence to present when `bindTerms` is false.
        bool divergeOnAmount;
    }

    // ── reference model state (maintained by this handler, never read back) ──

    mapping(uint256 facilityId => uint256) public modelAttestationMask;
    /// @dev AUDIT FIX (H-4): the handler's mirror of the standing `CreditIssued` payload.
    mapping(uint256 facilityId => bytes32) public modelTermsPayload;
    mapping(uint256 facilityId => uint256) internal modelMarkValue;
    mapping(uint256 facilityId => uint64) internal modelMarkAsOf;

    mapping(uint256 classId => uint256) public modelClassExposure;
    mapping(bytes32 borrowerId => uint256) public modelBorrowerExposure;
    mapping(bytes32 stateId => uint256) public modelStateExposure;
    uint256 public modelTotalExposure;

    /// @dev Handler-side record of every facility it believes exists, so the lifecycle
    ///      actions never have to ask the bridge what it thinks it minted.
    struct FacilityRef {
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 principal;
        bool live;
    }

    mapping(uint256 tokenId => FacilityRef) internal facilities;
    mapping(uint256 tokenId => bool) public gateSatisfiedAtMint;
    /// @dev AUDIT FIX (H-4): was the `CreditIssued` payload bound to THESE terms at mint?
    mapping(uint256 tokenId => bool) public termsBoundAtMint;
    mapping(uint256 tokenId => bool) public live; // Pending/Active/Amortizing (counted in registry)
    uint256 public ghostLivePrincipal;

    // ── ghost counters (the whole point: a dead admission path is now visible) ──

    uint256 public ghostOriginateAttempts;
    uint256 public ghostOriginateSuccesses;
    /// @dev Mints that actually happened. Tracks `ghostOriginateSuccesses` exactly; kept
    ///      under the name the H-4 anti-vacuity tests read.
    uint256 public mintCount;
    uint256 public ghostRejectGate;
    /// @dev AUDIT FIX (H-4): rejections where the attestations EXISTED but did not attest to
    ///      the terms being originated. Zero here would mean the binding is never exercised.
    uint256 public ghostRejectTermsNotAttested;
    uint256 public ghostRejectMarkStale;
    uint256 public ghostRejectLtvValue;
    uint256 public ghostRejectClassConcentration;
    uint256 public ghostRejectBorrowerConcentration;
    uint256 public ghostRejectStateConcentration;
    uint256 public ghostRepayClosures;
    uint256 public ghostLifecycleTransitions;

    // bug buckets — asserted zero
    uint256 public ghostUnexpectedRejections;
    uint256 public ghostGateBypasses;
    uint256 public ghostLimitBypasses;
    uint256 public ghostWrongReason;
    bytes4 public ghostLastUnexpectedSelector;
    bytes4 public ghostLastExpectedSelector;

    /// @dev Values of the counters immediately after `seedAdmissionShapes`, so a reviewer
    ///      (and `fuzzOnlyCounts`) can separate the DETERMINISTIC floor from what the fuzz
    ///      campaign actually reached on its own. Reported, never asserted on — asserting
    ///      raw fuzzer luck is flaky.
    struct Floors {
        uint64 attempts;
        uint64 successes;
        uint64 gate;
        uint64 terms;
        uint64 classConc;
        uint64 borrowerConc;
        uint64 stateConc;
        uint64 closures;
    }

    Floors internal floors;

    constructor(
        ClaimBridge bridge_,
        CollateralRegistry registry_,
        MockAttestationOracle oracle_,
        address originator_,
        address creditModule_,
        address custodian_,
        address admin_
    ) {
        bridge = bridge_;
        registry = registry_;
        oracle = oracle_;
        originator = originator_;
        creditModule = creditModule_;
        custodian = custodian_;
        // test-scale floor so limits genuinely bind during fuzzing
        vm.prank(admin_);
        registry.setConcentrationFloor(CONC_FLOOR);
        _pinFixture();
    }

    /// @dev Asserts once, at construction, that the hard-coded reference parameters match
    ///      the live configuration. This is the ONE place the model touches the contracts'
    ///      accessors, and it is a pin, not a derivation: if the fixture changes, the model
    ///      must be updated deliberately rather than silently tracking whatever is there.
    ///      AUDIT FIX (H-4) adds the terms-commitment preimage to the pin, so a change to
    ///      `ClaimBridge.creditTermsHash` surfaces here rather than as a storm of
    ///      unexplained "valid origination was rejected" failures.
    function _pinFixture() private view {
        (uint16 bLimit, uint16 sLimit, uint256 floor) = registry.limits();
        if (bLimit != BORROWER_LIMIT_BPS || sLimit != STATE_LIMIT_BPS || floor != CONC_FLOOR) {
            revert HandlerFixtureDrift(0);
        }
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            ClassRef memory r = _classRef(c);
            ICollateralRegistry.ClassParams memory p = registry.classParams(c);
            bool mtm = p.model == ICollateralRegistry.CollateralModel.MarkedToMarket;
            if (
                !p.active || p.maxLtvBps != r.maxLtvBps || p.maxMaturity != r.maxMaturity
                    || p.concentrationLimitBps != r.concentrationLimitBps || mtm != r.markedToMarket
                    || (mtm && p.maxMarkAge != r.maxMarkAge) || bridge.requiredMintAttestations(c) != r.requiredMask
            ) revert HandlerFixtureDrift(c);
        }
        _pinTermsPreimage();
    }

    /// @dev Second half of the pin: the handler's independent copy of the terms-commitment
    ///      preimage must agree with the contract's, on a tuple with every field distinct.
    function _pinTermsPreimage() private view {
        Candidate memory probe;
        probe.classId = Config.CLASS_FILM_TAX_CREDITS;
        probe.borrowerId = borrowers[0];
        probe.stateId = states[0];
        probe.principal = 123_456e18;
        probe.ltvBps = 7500;
        probe.interestRateBps = 1234;
        probe.maturity = uint64(block.timestamp + 365 days);
        probe.offchainRef = keccak256("pin");
        bytes32 mine = _termsHash(probe);
        bytes32 theirs = bridge.creditTermsHash(_asTerms(probe));
        if (mine != theirs) revert HandlerFixtureDrift(DRIFT_TERMS_PREIMAGE);
    }

    /// @dev The reference class table. Mirrors `CollateralFixture.setUp` by hand.
    ///      AUDIT FIX (H-4): every class's gate now carries the `CreditIssued` bit — it is
    ///      the terms quorum, and `ClaimBridge.setRequiredMintAttestations` rejects a mask
    ///      without it.
    function _classRef(uint256 classId) internal pure returns (ClassRef memory) {
        if (classId == Config.CLASS_FILM_TAX_CREDITS) {
            return ClassRef(8000, 730 days, 3500, false, 0, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        }
        if (classId == Config.CLASS_RENEWABLE_ENERGY) {
            return ClassRef(7500, 1825 days, 3500, false, 0, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        }
        if (classId == Config.CLASS_LIFE_SCIENCES) {
            return ClassRef(6000, 2555 days, 3000, false, 0, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        }
        if (classId == Config.CLASS_REAL_ESTATE) {
            return ClassRef(7000, 3650 days, 3500, false, 0, BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT);
        }
        return ClassRef(5000, 365 days, 2000, true, 1 days, BIT_ASSIGNMENT | BIT_VALUATION | BIT_CREDIT);
    }

    // ── ops ──────────────────────────────────────────────────────────────

    /// @notice Randomizes the attestation state of the NEXT facility id, mirroring every
    ///         change into the reference model.
    /// @dev The valuation payload is keyed off the Valuation bit rather than the
    ///      CreditIssued bit (the original coupling meant a marked-to-market origination
    ///      could only ever be attempted when an attestation it does not require happened
    ///      to be set). Both a fresh and a deliberately stale `asOf` are still explored.
    ///      Deliberately does NOT touch the `CreditIssued` PAYLOAD: this action models
    ///      attesters flipping facts on and off, and "a bundle of satisfied attestations
    ///      that says nothing about the terms" is precisely the state H-4 must reject.
    function flipAttestations(uint256 seed) external {
        uint256 nextId = bridge.totalOriginated() + 1;
        uint256 mask;
        bool assignment = seed & 1 != 0;
        bool ucc = seed & 2 != 0;
        bool valuation = seed & 4 != 0;
        bool credit = seed & 8 != 0;
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, assignment);
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.UCCFiled, ucc);
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.Valuation, valuation);
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.CreditIssued, credit);
        if (assignment) mask |= BIT_ASSIGNMENT;
        if (ucc) mask |= BIT_UCC;
        if (valuation) mask |= BIT_VALUATION;
        if (credit) mask |= BIT_CREDIT;
        modelAttestationMask[nextId] = mask;

        if (valuation) {
            // sometimes fresh, sometimes stale mark
            uint64 asOf = seed & 16 != 0
                ? uint64(block.timestamp)
                : uint64(block.timestamp > 3 days ? block.timestamp - 3 days : 0);
            uint256 value = bound(seed >> 8, 1e18, 5_000_000e18);
            oracle.setValuation(nextId, value, asOf);
            modelMarkValue[nextId] = value;
            modelMarkAsOf[nextId] = asOf;
        }
    }

    /// @notice Attempts an origination and reconciles the outcome against the reference
    ///         model. Neither a success nor a rejection is ever swallowed.
    /// @dev TWO INDEPENDENT STEERING SEEDS, one per off-chain gate condition:
    ///
    ///      `gateSeed` steers HOW OFTEN the required attestation BITS are even set. Left
    ///      purely to `flipAttestations` the full required mask happened to be set for the
    ///      right facility id only ~1 attempt in 8, so most runs never admitted anything and
    ///      the concentration dimensions were essentially never reached. Three attempts in
    ///      four now pre-satisfy the bits, which puts the book under the caps; the remaining
    ///      quarter — plus `flipAttestations` churn — keeps the REJECTION side exercised.
    ///
    ///      `termsSeed` steers whether the standing `CreditIssued` payload COMMITS TO THE
    ///      TERMS being originated (AUDIT FIX H-4). Three attempts in four commit; the
    ///      remaining quarter presents a payload for a different amount or a different
    ///      obligor — the exact shape of the defect H-4 closes. Without this dimension every
    ///      mint would revert and the mint-gate invariant would go vacuous again; without its
    ///      false branch the binding would never be observed to bite.
    ///
    ///      Both are predicted and checked either way, so neither seed can hide a bug: a
    ///      steering choice only changes WHICH outcome the model demands.
    function tryOriginate(
        uint256 classSeed,
        uint256 borrowerSeed,
        uint256 stateSeed,
        uint256 principal,
        uint256 gateSeed,
        uint256 termsSeed
    ) external {
        Candidate memory c;
        c.nextId = bridge.totalOriginated() + 1;
        c.classId = (classSeed % Config.NUM_CLASSES) + 1;
        c.borrowerId = borrowers[borrowerSeed % 3];
        c.stateId = c.classId == Config.CLASS_FILM_TAX_CREDITS ? states[stateSeed % 3] : bytes32(0);
        c.principal = bound(principal, 1e18, 1_500_000e18);
        c.offchainRef = keccak256(abi.encode(c.nextId));
        c.bindTerms = termsSeed % 4 != 0;
        c.divergeOnAmount = termsSeed % 2 == 0;
        {
            ClassRef memory r = _classRef(c.classId);
            c.ltvBps = r.maxLtvBps;
            c.interestRateBps = uint16(bound(termsSeed >> 16, 1, MAX_INTEREST_RATE_BPS));
            c.maturity = uint64(block.timestamp + r.maxMaturity / 2);
            if (gateSeed % 4 != 0) {
                _setMask(c.nextId, r.requiredMask);
                if (r.markedToMarket && gateSeed % 8 != 0) {
                    _setMark(c.nextId, bound(gateSeed >> 8, 1e18, 5_000_000e18), uint64(block.timestamp));
                }
            }
        }
        _attempt(c);
    }

    /// @dev The single origination path: present the terms commitment, predict, attempt,
    ///      reconcile. Returns the outcome the reference model predicted, so the seeded
    ///      shapes can assert on it.
    function _attempt(Candidate memory c) private returns (bytes4 expected) {
        _presentTerms(c);
        expected = _predict(c, _classRef(c.classId));
        ghostOriginateAttempts++;

        vm.prank(originator);
        try bridge.originate(custodian, _asTerms(c)) returns (uint256 tokenId) {
            _onOriginated(tokenId, c, expected);
        } catch (bytes memory err) {
            _onRejected(expected, err);
        }
    }

    /// @dev AUDIT FIX (H-4). Writes the `CreditIssued` payload the attester quorum is
    ///      pretending to have signed for this attempt, mirroring it into the model.
    ///      Critically it preserves the SATISFIED bit exactly as `gateSeed`/`flipAttestations`
    ///      left it, so presenting a terms payload can never accidentally satisfy the gate —
    ///      that is what keeps the two seeds independent.
    function _presentTerms(Candidate memory c) private {
        // P-32: documentary gate facts are deal identities too. Keep the handler's
        // deliberate CreditIssued divergence as the H-4 negative control, but make the
        // assignment/UCC facts valid for the candidate terms so a positive seeded shape is
        // rejected (or admitted) for the reason the independent model selected.
        bytes32 termsHash = _termsHash(c);
        if (modelAttestationMask[c.nextId] & BIT_ASSIGNMENT != 0) {
            oracle.setPayload(
                c.nextId,
                IAttestationOracle.AttestationKind.AssignmentExecuted,
                termsHash,
                uint64(block.timestamp),
                true
            );
        }
        if (modelAttestationMask[c.nextId] & BIT_UCC != 0) {
            oracle.setPayload(
                c.nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash, uint64(block.timestamp), true
            );
        }
        bytes32 payload = c.bindTerms ? _termsHash(c) : _divergentTermsHash(c);
        oracle.setPayload(
            c.nextId,
            IAttestationOracle.AttestationKind.CreditIssued,
            payload,
            uint64(block.timestamp),
            modelAttestationMask[c.nextId] & BIT_CREDIT != 0
        );
        modelTermsPayload[c.nextId] = payload;
    }

    /// @dev Sets the attestation bits of `facilityId` to exactly `mask`, mirroring the
    ///      change into the model.
    function _setMask(uint256 facilityId, uint256 mask) private {
        oracle.setSatisfied(
            facilityId, IAttestationOracle.AttestationKind.AssignmentExecuted, mask & BIT_ASSIGNMENT != 0
        );
        oracle.setSatisfied(facilityId, IAttestationOracle.AttestationKind.UCCFiled, mask & BIT_UCC != 0);
        oracle.setSatisfied(facilityId, IAttestationOracle.AttestationKind.CreditIssued, mask & BIT_CREDIT != 0);
        oracle.setSatisfied(facilityId, IAttestationOracle.AttestationKind.Valuation, mask & BIT_VALUATION != 0);
        modelAttestationMask[facilityId] = mask;
    }

    /// @dev Sets the marked-to-market payload of `facilityId`, mirroring it into the model.
    function _setMark(uint256 facilityId, uint256 value, uint64 asOf) private {
        oracle.setValuation(facilityId, value, asOf);
        modelMarkValue[facilityId] = value;
        modelMarkAsOf[facilityId] = asOf;
    }

    /// @dev Books a successful mint into the model, and flags it if the model said the
    ///      admission rule should have blocked it.
    function _onOriginated(uint256 tokenId, Candidate memory c, bytes4 expected) private {
        if (expected != bytes4(0)) {
            ghostLastExpectedSelector = expected;
            if (
                expected == ICollateralRegistry.Registry_ConcentrationExceeded.selector
                    || expected == ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector
                    || expected == ICollateralRegistry.Registry_StateConcentrationExceeded.selector
            ) {
                ghostLimitBypasses++;
            } else {
                // missing attestation / UNBOUND TERMS / stale mark / LTV-vs-value are all
                // mint-gate conditions
                ghostGateBypasses++;
            }
        }
        assertEq(tokenId, c.nextId, "TOKEN ID DID NOT FOLLOW THE ORIGINATION SEQUENCE");
        gateSatisfiedAtMint[tokenId] = _gateOk(c.classId, tokenId);
        // AUDIT FIX (H-4): decided from the handler's OWN mirror of the payload, never from
        // the bridge — the invariant must not be able to agree with the bug.
        termsBoundAtMint[tokenId] = _termsOk(c);
        live[tokenId] = true;
        facilities[tokenId] = FacilityRef({
            classId: c.classId,
            borrowerId: c.borrowerId,
            stateId: c.stateId,
            principal: c.principal,
            live: true
        });
        ghostLivePrincipal += c.principal;
        modelClassExposure[c.classId] += c.principal;
        modelBorrowerExposure[c.borrowerId] += c.principal;
        if (c.stateId != bytes32(0)) modelStateExposure[c.stateId] += c.principal;
        modelTotalExposure += c.principal;
        ghostOriginateSuccesses++;
        mintCount++;
    }

    /// @dev Books a rejection. An EXPECTED rejection is counted by reason; an UNEXPECTED
    ///      one (or the right family of failure for the wrong reason) is recorded for the
    ///      invariant to fail on. Nothing is swallowed.
    function _onRejected(bytes4 expected, bytes memory err) private {
        bytes4 got = _selectorOf(err);
        if (expected == bytes4(0) || got != expected) {
            ghostLastUnexpectedSelector = got;
            ghostLastExpectedSelector = expected;
            if (expected == bytes4(0)) ghostUnexpectedRejections++;
            else ghostWrongReason++;
            return;
        }
        if (got == ClaimBridge.Bridge_AttestationMissing.selector) {
            ghostRejectGate++;
        } else if (got == ClaimBridge.Bridge_TermsNotAttested.selector) {
            ghostRejectTermsNotAttested++;
        } else if (got == ClaimBridge.Bridge_ValuationStale.selector) {
            ghostRejectMarkStale++;
        } else if (got == ClaimBridge.Bridge_LtvExceedsValue.selector) {
            ghostRejectLtvValue++;
        } else if (got == ICollateralRegistry.Registry_ConcentrationExceeded.selector) {
            ghostRejectClassConcentration++;
        } else if (got == ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector) {
            ghostRejectBorrowerConcentration++;
        } else if (got == ICollateralRegistry.Registry_StateConcentrationExceeded.selector) {
            ghostRejectStateConcentration++;
        }
    }

    /// @notice Drives a facility through its state machine. Recorded so a campaign that
    ///         never left `Pending` is visible.
    function advanceLifecycle(uint256 idSeed, uint256 pathSeed) external {
        uint256 n = bridge.totalOriginated();
        if (n == 0) return;
        uint256 id = (idSeed % n) + 1;
        ClaimBridge.LoanState st = bridge.facility(id).state;
        vm.startPrank(creditModule);
        if (st == ClaimBridge.LoanState.Pending) {
            bridge.transitionState(id, ClaimBridge.LoanState.Active);
            ghostLifecycleTransitions++;
        } else if (st == ClaimBridge.LoanState.Active) {
            bridge.transitionState(
                id, pathSeed & 1 != 0 ? ClaimBridge.LoanState.Amortizing : ClaimBridge.LoanState.Defaulted
            );
            ghostLifecycleTransitions++;
        } else if (st == ClaimBridge.LoanState.Defaulted) {
            bridge.transitionState(id, ClaimBridge.LoanState.Accelerated);
            ghostLifecycleTransitions++;
        }
        vm.stopPrank();
    }

    /// @notice Repays and closes a facility, releasing its exposure. Uses the HANDLER's
    ///         own record of the facility and cross-checks the bridge against it, rather
    ///         than trusting the bridge to describe what it minted.
    function repayAndClose(uint256 idSeed) external {
        uint256 n = bridge.totalOriginated();
        if (n == 0) return;
        uint256 id = (idSeed % n) + 1;
        ClaimBridge.Facility memory f = bridge.facility(id);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) return;

        FacilityRef memory ref = facilities[id];
        assertEq(f.classId, ref.classId, "BRIDGE FACILITY CLASS DIVERGED FROM THE MODEL");
        assertEq(f.borrowerId, ref.borrowerId, "BRIDGE FACILITY BORROWER DIVERGED FROM THE MODEL");
        assertEq(f.stateId, ref.stateId, "BRIDGE FACILITY STATE DIVERGED FROM THE MODEL");
        assertEq(f.principal, ref.principal, "BRIDGE FACILITY PRINCIPAL DIVERGED FROM THE MODEL");

        _close(id, ref);
    }

    /// @dev Repays a live facility and releases its exposure, in both the contracts and the
    ///      model.
    function _close(uint256 id, FacilityRef memory ref) private {
        vm.startPrank(creditModule);
        bridge.transitionState(id, ClaimBridge.LoanState.Repaid);
        // credit layer releases the exposure on close (Phase E automates this)
        registry.recordExposureDecrease(ref.classId, ref.borrowerId, ref.stateId, ref.principal);
        vm.stopPrank();

        live[id] = false;
        facilities[id].live = false;
        ghostLivePrincipal -= ref.principal;
        modelClassExposure[ref.classId] -= ref.principal;
        modelBorrowerExposure[ref.borrowerId] -= ref.principal;
        if (ref.stateId != bytes32(0)) modelStateExposure[ref.stateId] -= ref.principal;
        modelTotalExposure -= ref.principal;
        ghostRepayClosures++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 30 days);
        vm.warp(block.timestamp + secs);
    }

    // ── deterministic shape seeding (called once from setUp, never fuzzed) ──

    /// @notice Drives one instance of every admission shape the suite must have reached,
    ///         then unwinds the book so the fuzz campaign starts with full headroom.
    /// @dev REVIEW FIX (collateral false green), and the same reasoning as
    ///      `GovernanceInvariants.seedGovernanceShapes`. Forge restarts every invariant run
    ///      from the post-`setUp` state, so anything asserted by `afterInvariant` about
    ///      "was this shape ever reached" is otherwise a bet on fuzzer luck within a single
    ///      128-call run — measured at well under 100% of runs for the concentration
    ///      dimensions. Seeding gives those assertions a DETERMINISTIC floor, so
    ///      `afterInvariant` tests the property ("this campaign was evaluated against a
    ///      state where the gate, the terms binding and every limit actually bit") rather
    ///      than the weather.
    ///
    ///      THE `setUp` CALL TO THIS FUNCTION IS LOAD-BEARING. Drop it — as a merge once did
    ///      — and the `afterInvariant` floors go back to being a bet on the seed, which is
    ///      exactly the intermittent red a reviewer reported ("NOTHING WAS EVER ORIGINATED",
    ///      "BORROWER LIMIT NEVER BOUND", "NO FACILITY EVER CLOSED", all reading `0 <= 0`).
    ///
    ///      The numbers below are hand-computed against a 2,000,000e18 floor: caps are
    ///      300,000e18 per borrower (1500bps), 500,000e18 per state (2500bps),
    ///      700,000e18 for classes 1/2/4 (3500bps), 600,000e18 for class 3 and
    ///      400,000e18 for class 5. Each shape asserts the model predicted what was
    ///      intended, so a mis-computed shape fails here instead of silently degrading
    ///      into "attempted something, got something".
    function seedAdmissionShapes() external {
        _seedConcentrationShapes();
        _seedMarkedToMarketShapes();

        // no shape may have produced a disagreement with the model
        assertEq(ghostUnexpectedRejections, 0, "SEEDING HIT AN UNEXPECTED REJECTION");
        assertEq(ghostWrongReason, 0, "SEEDING HIT A REJECTION FOR THE WRONG REASON");
        assertEq(ghostGateBypasses + ghostLimitBypasses, 0, "SEEDING HIT AN ADMISSION BYPASS");
        assertEq(ghostOriginateSuccesses, 3, "SEEDING DID NOT ADMIT THE THREE INTENDED FACILITIES");
        assertEq(ghostRejectTermsNotAttested, 1, "SEEDING DID NOT EXERCISE THE TERMS BINDING");

        // unwind, so the fuzz campaign inherits the counters but not the exposure
        uint256 n = bridge.totalOriginated();
        for (uint256 id = 1; id <= n; ++id) {
            FacilityRef memory ref = facilities[id];
            if (!ref.live) continue;
            vm.prank(creditModule);
            bridge.transitionState(id, ClaimBridge.LoanState.Active);
            ghostLifecycleTransitions++;
            _close(id, ref);
        }
        assertEq(modelTotalExposure, 0, "SEED UNWIND LEFT EXPOSURE BEHIND");
        assertEq(registry.totalBookExposure(), 0, "SEED UNWIND LEFT REGISTRY EXPOSURE BEHIND");

        floors = Floors({
            attempts: uint64(ghostOriginateAttempts),
            successes: uint64(ghostOriginateSuccesses),
            gate: uint64(ghostRejectGate),
            terms: uint64(ghostRejectTermsNotAttested),
            classConc: uint64(ghostRejectClassConcentration),
            borrowerConc: uint64(ghostRejectBorrowerConcentration),
            stateConc: uint64(ghostRejectStateConcentration),
            closures: uint64(ghostRepayClosures)
        });
    }

    /// @dev Split out of `seedAdmissionShapes` so `forge coverage --ir-minimum` can instrument
    ///      this high-arity deterministic seeder without exhausting the Yul stack.
    function _seedConcentrationShapes() private {
        // admitted: two borrowers, 250k each, same class and state -> class1 500k, GA 500k
        _shape(Config.CLASS_FILM_TAX_CREDITS, borrowers[0], states[0], 250_000e18, 0, 0, true, true, bytes4(0));
        _shape(Config.CLASS_FILM_TAX_CREDITS, borrowers[1], states[0], 250_000e18, 0, 0, true, true, bytes4(0));
        // TERMS BINDING (AUDIT FIX H-4): every required attestation satisfied, payload
        // committing to a DIFFERENT amount. Under the pre-H-4 gate this minted. It must now
        // be refused, and refused for the TERMS reason — this principal is admissible on
        // every concentration dimension, so nothing else can be doing the work.
        _shape(
            Config.CLASS_FILM_TAX_CREDITS,
            borrowers[2],
            states[1],
            100_000e18,
            0,
            0,
            true,
            false,
            ClaimBridge.Bridge_TermsNotAttested.selector
        );
        // STATE limit: GA would reach 550k > 500k (class 550k and borrower 50k both fine)
        _shape(
            Config.CLASS_FILM_TAX_CREDITS,
            borrowers[2],
            states[0],
            50_000e18,
            0,
            0,
            true,
            true,
            ICollateralRegistry.Registry_StateConcentrationExceeded.selector
        );
        // CLASS limit: class1 would reach 750k > 700k (b2 250k fine, no state dimension).
        // NB 200k would be admitted: the cap is `>`, and 700k is exactly at it.
        _shape(
            Config.CLASS_FILM_TAX_CREDITS,
            borrowers[2],
            states[1],
            250_000e18,
            0,
            0,
            true,
            true,
            ICollateralRegistry.Registry_ConcentrationExceeded.selector
        );
        // BORROWER limit: b0 would reach 350k > 300k (class1 600k and GA 600k not reached first)
        _shape(
            Config.CLASS_FILM_TAX_CREDITS,
            borrowers[0],
            states[0],
            100_000e18,
            0,
            0,
            true,
            true,
            ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector
        );
        // MINT GATE: nothing attested at all
        _shape(
            Config.CLASS_RENEWABLE_ENERGY,
            borrowers[2],
            bytes32(0),
            100_000e18,
            0,
            0,
            false,
            true,
            ClaimBridge.Bridge_AttestationMissing.selector
        );
    }

    /// @dev The valuation cases are isolated from the concentration cases for the same coverage
    ///      instrumentation stack limit. They intentionally execute second against the seeded book.
    function _seedMarkedToMarketShapes() private {
        // marked-to-market: no mark, stale mark, mark too small, then an admissible one
        _shape(
            Config.CLASS_DIGITAL_ASSETS,
            borrowers[2],
            bytes32(0),
            100_000e18,
            0,
            0,
            true,
            true,
            ClaimBridge.Bridge_ValuationStale.selector
        );
        _shape(
            Config.CLASS_DIGITAL_ASSETS,
            borrowers[2],
            bytes32(0),
            100_000e18,
            1_000_000e18,
            uint64(block.timestamp - 3 days),
            true,
            true,
            ClaimBridge.Bridge_ValuationStale.selector
        );
        _shape(
            Config.CLASS_DIGITAL_ASSETS,
            borrowers[2],
            bytes32(0),
            100_000e18,
            10_000e18,
            uint64(block.timestamp),
            true,
            true,
            ClaimBridge.Bridge_LtvExceedsValue.selector
        );
        _shape(
            Config.CLASS_DIGITAL_ASSETS,
            borrowers[2],
            bytes32(0),
            100_000e18,
            5_000_000e18,
            uint64(block.timestamp),
            true,
            true,
            bytes4(0)
        );
    }

    /// @notice What THIS RUN's fuzz campaign reached on its own, above the seeded floor.
    /// @dev The ASSERTION surface for the anti-vacuity ATTEMPTS floor, and the reporting
    ///      surface for every other dimension. Forge restarts each run from the post-`setUp`
    ///      state, so these are per-run figures: `afterInvariant` reads the deltas of the run
    ///      it terminates. `attempts` leads the tuple because it is the field the "selector
    ///      wiring broken" floor actually needs — with `tryOriginate` one of six fuzzed
    ///      selectors over a depth-128 run, a fuzz-only attempt count of zero is a wiring
    ///      break, not fuzzer luck (it is astronomically unlikely otherwise), so it is the one
    ///      the anti-vacuity guard asserts rather than the seed-loaded absolute. The remaining
    ///      per-run deltas are too thin to assert without flaking (`afterInvariant` samples a
    ///      single run), so they stay a readout while their seed-backed absolutes are asserted.
    function fuzzOnlyCounts()
        external
        view
        returns (
            uint256 attempts,
            uint256 successes,
            uint256 gate,
            uint256 terms,
            uint256 classConc,
            uint256 borrowerConc,
            uint256 stateConc,
            uint256 closures
        )
    {
        return (
            ghostOriginateAttempts - floors.attempts,
            ghostOriginateSuccesses - floors.successes,
            ghostRejectGate - floors.gate,
            ghostRejectTermsNotAttested - floors.terms,
            ghostRejectClassConcentration - floors.classConc,
            ghostRejectBorrowerConcentration - floors.borrowerConc,
            ghostRejectStateConcentration - floors.stateConc,
            ghostRepayClosures - floors.closures
        );
    }

    /// @dev One seeded shape: force the attestation/mark/terms state, attempt, and assert the
    ///      reference model predicted exactly the outcome the shape was written to produce.
    function _shape(
        uint256 classId,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint256 markValue,
        uint64 markAsOf,
        bool attested,
        bool bindTerms,
        bytes4 want
    ) private {
        Candidate memory c;
        c.nextId = bridge.totalOriginated() + 1;
        c.classId = classId;
        c.borrowerId = borrowerId;
        c.stateId = stateId;
        c.principal = principal;
        c.offchainRef = keccak256(abi.encode(c.nextId));
        c.bindTerms = bindTerms;
        c.divergeOnAmount = true;
        {
            ClassRef memory r = _classRef(classId);
            c.ltvBps = r.maxLtvBps;
            c.interestRateBps = 1000;
            c.maturity = uint64(block.timestamp + r.maxMaturity / 2);
            _setMask(c.nextId, attested ? r.requiredMask : 0);
        }
        _setMark(c.nextId, markValue, markAsOf);
        bytes4 got = _attempt(c);
        // The disagreement checks come FIRST: if the contract just disagreed with the model,
        // that is the finding, and reporting a downstream "shape mismatch" instead would
        // bury it (the shapes are sequential, so one wrong outcome shifts every later one).
        assertEq(ghostUnexpectedRejections, 0, "SEEDED SHAPE: VALID ORIGINATION WAS REJECTED");
        assertEq(ghostWrongReason, 0, "SEEDED SHAPE: REJECTED FOR THE WRONG REASON");
        assertEq(ghostGateBypasses + ghostLimitBypasses, 0, "SEEDED SHAPE: ADMISSION BYPASSED");
        assertEq(bytes32(got), bytes32(want), "SEEDED ADMISSION SHAPE DID NOT MATCH ITS INTENDED OUTCOME");
    }

    // ── the reference model ──────────────────────────────────────────────

    /// @dev Predicts the outcome of an origination attempt from handler-owned state only.
    /// @return bytes4(0) if the attempt MUST succeed, otherwise the selector the attempt
    ///         MUST revert with. The order mirrors `ClaimBridge.originate` and then
    ///         `CollateralRegistry._checkConcentration`, so the reason is checked too, not
    ///         merely the fact of failure.
    function _predict(Candidate memory c, ClassRef memory r) internal view returns (bytes4) {
        // P-45: the bridge validates the state tag before it reaches the mint gate.
        // Tax-credit facilities require a concrete state key; every other class must
        // carry the zero sentinel. Keep the independent model in the same order so an
        // invalid tag cannot be misreported as an attestation or concentration failure.
        if ((c.classId == Config.CLASS_FILM_TAX_CREDITS) == (c.stateId == bytes32(0))) {
            return ClaimBridge.Bridge_BadFacility.selector;
        }
        if (!_gateOk(c.classId, c.nextId)) return ClaimBridge.Bridge_AttestationMissing.selector;
        // AUDIT FIX (H-4): existence is not enough — the standing payload must commit to
        // these exact terms. Checked in the contract's order: after the bits, before the mark.
        if (!_termsOk(c)) return ClaimBridge.Bridge_TermsNotAttested.selector;

        if (r.markedToMarket) {
            uint64 asOf = modelMarkAsOf[c.nextId];
            if (asOf == 0 || block.timestamp - asOf > r.maxMarkAge) return ClaimBridge.Bridge_ValuationStale.selector;
            if (c.principal > modelMarkValue[c.nextId] * r.maxLtvBps / Config.BPS) {
                return ClaimBridge.Bridge_LtvExceedsValue.selector;
            }
        }

        uint256 total = modelTotalExposure;
        if (c.principal > MAX_SAFE_EXPOSURE - total) return ICollateralRegistry.Registry_PrincipalTooLarge.selector;
        uint256 newTotal = total + c.principal;
        uint256 base = newTotal > CONC_FLOOR ? newTotal : CONC_FLOOR;

        if (modelClassExposure[c.classId] + c.principal > uint256(r.concentrationLimitBps) * base / Config.BPS) {
            return ICollateralRegistry.Registry_ConcentrationExceeded.selector;
        }
        if (modelBorrowerExposure[c.borrowerId] + c.principal > uint256(BORROWER_LIMIT_BPS) * base / Config.BPS) {
            return ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector;
        }
        if (
            c.stateId != bytes32(0)
                && modelStateExposure[c.stateId] + c.principal > uint256(STATE_LIMIT_BPS) * base / Config.BPS
        ) return ICollateralRegistry.Registry_StateConcentrationExceeded.selector;

        return bytes4(0);
    }

    /// @dev Mint gate, evaluated against the handler's OWN mirror of the attestation bits.
    function _gateOk(uint256 classId, uint256 facilityId) internal view returns (bool) {
        uint256 required = _classRef(classId).requiredMask;
        return required & ~modelAttestationMask[facilityId] == 0;
    }

    /// @dev Terms binding (AUDIT FIX H-4), evaluated against the handler's OWN mirror of the
    ///      standing `CreditIssued` record: the fact must be satisfied AND its payload must
    ///      equal the commitment over the terms being originated.
    function _termsOk(Candidate memory c) internal view returns (bool) {
        if (modelAttestationMask[c.nextId] & BIT_CREDIT == 0) return false;
        return modelTermsPayload[c.nextId] == _termsHash(c);
    }

    /// @dev The handler's INDEPENDENT copy of the terms-commitment preimage. Deliberately not
    ///      `bridge.creditTermsHash` — a model that asked the contract what the terms hash is
    ///      could not detect the contract binding the wrong terms. Pinned once against the
    ///      contract in `_pinTermsPreimage`, so a deliberate preimage change fails loudly
    ///      there rather than as a storm of unexplained rejections.
    function _termsHash(Candidate memory c) private pure returns (bytes32) {
        return keccak256(abi.encode(_asTerms(c)));
    }

    /// @dev The one definition of the preimage, by field, so the divergent variants below
    ///      cannot drift from the bound one.
    function _termsHashOf(
        uint256 classId,
        bytes32 borrowerId,
        bytes32 stateId,
        uint256 principal,
        uint16 ltvBps,
        uint16 interestRateBps,
        uint64 maturity,
        bytes32 offchainRef
    ) private pure returns (bytes32) {
        Candidate memory c;
        c.classId = classId;
        c.borrowerId = borrowerId;
        c.stateId = stateId;
        c.principal = principal;
        c.ltvBps = ltvBps;
        c.interestRateBps = interestRateBps;
        c.maturity = maturity;
        c.offchainRef = offchainRef;
        return keccak256(abi.encode(_asTerms(c)));
    }

    function _asTerms(Candidate memory c) private pure returns (ClaimBridge.OriginationTerms memory) {
        return ClaimBridge.OriginationTerms({
            classId: c.classId,
            borrowerId: c.borrowerId,
            stateId: c.stateId,
            principal: c.principal,
            ltvBps: c.ltvBps,
            interestRateBps: c.interestRateBps,
            maturity: c.maturity,
            fundingRecipient: address(0xB0B),
            paymentInterval: 30 days,
            nextPaymentDue: c.maturity > 30 days ? c.maturity - 30 days : c.maturity,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("invariant-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: c.offchainRef
        });
    }

    /// @dev A commitment to terms that are NOT the ones being originated — the H-4 attack
    ///      shape. Two flavours, because they model different halves of the defect: a quorum
    ///      that authorized a different AMOUNT for the same obligor (the unbounded-principal
    ///      half), and one that authorized a different OBLIGOR entirely (the sequence-desync
    ///      half, where an unattested borrower rides another's bundle).
    /// @dev Written field-by-field ON PURPOSE. `Candidate memory other = c;` ALIASES rather
    ///      than copies, so the obvious "copy and tweak one field" version silently mutated
    ///      the candidate being originated — which made the divergence vanish and every
    ///      terms rejection turn into a success. `seedAdmissionShapes` caught exactly that;
    ///      do not "simplify" this back into a struct copy.
    function _divergentTermsHash(Candidate memory c) private pure returns (bytes32) {
        if (c.divergeOnAmount) {
            return _termsHashOf(
                c.classId,
                c.borrowerId,
                c.stateId,
                c.principal + 1,
                c.ltvBps,
                c.interestRateBps,
                c.maturity,
                c.offchainRef
            );
        }
        return _termsHashOf(
            c.classId,
            keccak256(abi.encode("another-obligor", c.borrowerId)),
            c.stateId,
            c.principal,
            c.ltvBps,
            c.interestRateBps,
            c.maturity,
            c.offchainRef
        );
    }

    function _selectorOf(bytes memory err) private pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0xffffffff); // no decodable selector: never "expected"
        assembly {
            sel := mload(add(err, 0x20))
        }
    }

    // ── views for invariants ─────────────────────────────────────────────

    function borrowerCount() external pure returns (uint256) {
        return 3;
    }

    function borrowerAt(uint256 i) external view returns (bytes32) {
        return borrowers[i];
    }

    function stateCount() external pure returns (uint256) {
        return 2; // exclude the zero sentinel
    }

    function stateAt(uint256 i) external view returns (bytes32) {
        return states[i];
    }

    /// @notice Total rejections attributable to a concentration dimension.
    function ghostConcentrationRejections() external view returns (uint256) {
        return ghostRejectClassConcentration + ghostRejectBorrowerConcentration + ghostRejectStateConcentration;
    }
}
