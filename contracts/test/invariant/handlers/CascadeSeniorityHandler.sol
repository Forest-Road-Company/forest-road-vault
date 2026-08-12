// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GuardProbe} from "./GuardProbe.sol";
import {IDefaultManager} from "../../../src/interfaces/IDefaultManager.sol";
import {LossEventIds} from "../../../src/libraries/LossEventIds.sol";

import {ClaimBridge} from "../../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../../src/CollateralRegistry.sol";
import {CuratorModule} from "../../../src/CuratorModule.sol";
import {DefaultManager} from "../../../src/DefaultManager.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SGrove} from "../../../src/SGrove.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {WaterfallEngine} from "../../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../../src/interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "../../../src/interfaces/ICuratorModule.sol";
import {IWaterfallEngine} from "../../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

interface IInvariantOracleDriver {
    function setSatisfied(uint256 facilityId, IAttestationOracle.AttestationKind kind, bool ok) external;
    function setPayload(
        uint256 facilityId,
        IAttestationOracle.AttestationKind kind,
        bytes32 payload,
        uint64 asOf,
        bool ok
    ) external;
}

/// @title CascadeSeniorityHandler — bounded stateful-fuzz driver for INV-5 / INV-6 / INV-7
/// @notice Phase D audit deliverable (audit/SYSTEM_MODEL.md section 6). Drives the loss cascade,
///         the repayment waterfall and the curator subordination lever through the REAL
///         contracts, while maintaining a COMPLETELY INDEPENDENT model of every capacity the
///         cascade consults.
///
/// @dev INDEPENDENCE IS THE POINT (AUDIT_PROTOCOL Phase D: "ghost variables tracking expected
///      state independently of the contracts"). The repo's existing `CreditHandler` already
///      checks the cascade min-chain, but it computes the expected split from the CONTRACTS'
///      OWN pre-call balances (`curator.poolBalance`, `usdfr.balanceOf(backstop)`,
///      `backstop.eventCoverage`). That falsifies a wrong min-chain; it cannot falsify a wrong
///      CAPACITY, because a mis-accounted pool balance would be inherited by the reference model
///      and the two would still agree.
///
///      Here every capacity is reconstructed from the amounts THIS handler passed in:
///        - `mPool[c]` / `mShares[c]` / `mRound[c]` from its own posts, withdrawals and the
///          absorption its own model predicted;
///        - `mCoverageReserve` from its own `fundCoverage` calls minus its own predicted draws;
///        - `mCoverageReserve` from its own funding/draw accounting, and `mEventCap` /
///          `mEventDrawn` from ADR-0035's dynamic event view;
///        - `mExposure[c]` from its own originations, principal repayments and realized losses;
///        - `mTarget[c]` from its own `setFirstLossTarget` calls.
///      Nothing in the prediction path reads the accounting it is predicting. The
///      model-versus-contract equalities are then themselves invariants.
///
///      LAYER 2 IS THE REAL `SGrove`, not `MockCascadeBackstop`: this handler runs on
///      `GovernanceFixture`, which wires the production backstop. Layer two is therefore the one
///      shared live reserve, driven through both reserve-binding and reserve-slack values.
///
///      `fail_on_revert = true`: every path is precondition-guarded and bounded so it can never
///      revert. A revert here is a finding, never a reason to relax the switch.
contract CascadeSeniorityHandler is GuardProbe {
    // ── wiring ───────────────────────────────────────────────────────────

    struct Wiring {
        address usdc;
        address usdfr;
        address reserves;
        address controller;
        address vault;
        address registry;
        address bridge;
        address oracle;
        address curator;
        address waterfall;
        address defaultManager;
        address sGrove;
        address admin;
        address guardian;
        address servicer;
        address originator;
        address custodian;
        address borrower;
        address feeRecipient;
        address curatorA;
        address curatorB;
        address senior;
        address coverageFunder;
    }

    MockERC20 internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    CollateralRegistry internal registry;
    ClaimBridge internal bridge;
    IInvariantOracleDriver internal oracle;
    CuratorModule internal curator;
    WaterfallEngine internal waterfall;
    DefaultManager internal defaultManager;
    SGrove internal sGrove;

    address internal admin;
    address internal guardian;
    address internal servicer;
    address internal originator;
    address internal custodian;
    address internal borrower;
    address internal feeRecipient;
    address internal curatorA;
    address internal curatorB;
    address internal senior;
    address internal coverageFunder;

    // ── shape constants ──────────────────────────────────────────────────

    /// @dev Whole-USDC alignment for anything that crosses the 6dp<->18dp boundary, so a receipt
    ///      never truncates and `recordPayment` can never see `received != total`.
    uint256 internal constant UNIT = 1e12;
    /// @dev Mirrors `CuratorModule.MAX_SHARE_INFLATION` (SWEEP-3 S3-F1). If that constant moves,
    ///      this must move with it or `invariant_INV5_layer1CapacityMatchesIndependentModel` will
    ///      red — which is the correct, loud outcome for two enumerations of one rule.
    uint256 internal constant CURATOR_MAX_SHARE_INFLATION = 1e18;
    /// @dev Receivable classes only (1..4). Class 5 is marked-to-market and needs a live
    ///      valuation; it deliberately keeps zero exposure so the INV-7 headroom formula is also
    ///      exercised at `classExposure == 0` (the `min()` boundary).
    uint256 internal constant NUM_LOAN_CLASSES = 4;
    uint256 internal constant MAX_FACILITIES = 8;
    // NOTE (audit R6-CF1): the campaign no longer pins ONE incident nonce for the whole run.
    // Every partial write-down inside an OPEN incident still reuses that incident's id — the
    // anti-cap-multiplication property is unchanged and still asserted. What changed is that
    // governance may now CLOSE an adjudicated incident (`closeCustodyIncident`), because holding
    // one open forever would leave the R6-CF1 curator freeze armed for the rest of every run and
    // silently starve INV-7's positive withdrawal branch. A closed incident is succeeded by a new
    // one on a fresh nonce (`custodyIncidentNonce`), which is what `openReserveLossIncident`
    // requires.
    /// @dev MERGE NOTE (2026-08-07). Nonce used by `_probeReserveLossEntryGuards` ONLY, and only
    ///      before the campaign has opened its first incident. It is NOT a campaign incident and is
    ///      never passed to `openReserveLossIncident` — the caller-guard probe just needs some id
    ///      inside the custody namespace so that the namespace check cannot be what refuses it.
    uint256 internal constant PROBE_CUSTODY_NONCE = 1;
    /// @dev Book ceiling. `CollateralRegistry.concentrationFloor` is 25,000,000e18 at launch, so
    ///      every concentration dimension is measured against that floor while the book stays
    ///      below it. Holding the book here keeps concentration from ever binding, which would
    ///      otherwise revert `originate` under `fail_on_revert = true` for a reason unrelated to
    ///      this invariant family. INV-16 (concentration) is a different family's job.
    uint256 internal constant MAX_BOOK = 4_000_000e18;

    // ── INDEPENDENT MODEL STATE (never read back from the contracts) ─────

    /// @notice Modeled curator first-loss pool balance per class.
    mapping(uint256 classId => uint256) public mPool;
    /// @notice Modeled curator pro-rata share supply per class.
    mapping(uint256 classId => uint256) public mShares;
    /// @notice Modeled curator share round per class (advances on a post into a wiped pool).
    mapping(uint256 classId => uint256) public mRound;
    /// @notice Modeled first-loss target per class.
    mapping(uint256 classId => uint256) public mTarget;
    /// @notice Modeled class exposure (origination +, principal repayment -, realized loss -).
    mapping(uint256 classId => uint256) public mExposure;
    /// @notice Modeled unresolved-default freeze counter per class.
    mapping(uint256 classId => uint256) public mFrozen;
    /// @notice AUDIT R6-CF1. Modeled state of the reserve-CUSTODY loss window: true from the block
    ///         governance opens an incident until it closes it.
    /// @dev This campaign never latches a reserve deficit (`_reserveCustodyLossChecked` asserts it
    ///      stays zero), never leaves a live USDC shortfall at rest, and asserts
    ///      `totalUSDfr() == backingValue()` at every custody loss — so the OPEN INCIDENT is the
    ///      only limb of `CuratorModule.custodyFreezeActive()` this model needs to carry.
    ///      `invariant_INV5_custodyFreezeMatchesIndependentModel` asserts the contract agrees at
    ///      every reachable state, so a different limb firing surfaces as a LOUD failure rather
    ///      than as a silently wrong model.
    bool public mCustodyIncidentOpen;
    /// @notice Modeled sGROVE USDfr coverage reserve.
    uint256 public mCoverageReserve;
    /// @notice Modeled cumulative coverage drawn per event.
    mapping(uint256 tokenId => uint256) public mEventDrawn;

    /// @notice ADR-0035 counterpart to `SGrove.eventCoverage`'s second word.
    /// @dev It is computed, never snapshotted: cumulative draw plus the one shared live reserve.
    function mEventCap(uint256 tokenId) external view returns (uint256) {
        return mEventDrawn[tokenId] + mCoverageReserve;
    }

    /// @notice Modeled protocol fee on interest. No handler action changes it, so it is a
    ///         constant of this campaign, taken from `Config` rather than from `WaterfallEngine`.
    uint256 public immutable M_PROTOCOL_FEE_BPS;
    /// @notice Modeled origination fee (ADR-0019), same provenance as `M_PROTOCOL_FEE_BPS`.
    uint256 public immutable M_ORIGINATION_FEE_BPS;
    /// @notice Modeled total book exposure.
    uint256 public mTotalExposure;

    // ── ghost accumulators ───────────────────────────────────────────────

    uint256 public callCount;
    /// @dev Incremented at the TOP of every registered fuzz selector, before any guard. The seed
    ///      uses internal helpers and never touches it, so a non-zero value proves the
    ///      `targetSelector` wiring actually fired rather than that the seed ran.
    uint256 public fuzzActionEntries;
    /// @dev Same, for `realizeLoss` alone — the anti-vacuity tooth for the cascade family.
    uint256 public fuzzRealizeEntries;
    /// @dev Registered custody-loss action entries, reported separately from facility losses.
    uint256 public fuzzReserveLossEntries;

    // INV-5
    /// @dev AUDIT FIX (C4-01): salt making each realization's evidence hash unique, so the handler
    ///      models DISTINCT real-world loss events rather than re-presenting one fact repeatedly.
    uint256 internal lossEventNonce;
    /// @dev AUDIT FIX (C4-01), SECOND SITE — see `_distribute`. The same salt for PAYMENT events:
    ///      without it two same-block, same-size repays on one facility collide onto a single
    ///      `PaymentReceived` fact and the second is refused by the fact ledger.
    uint256 internal paymentEventNonce;
    uint256 public ghostLossEvents;
    uint256 public ghostLossRealized;
    uint256 public ghostAbsorbedL1;
    uint256 public ghostCoveredL2;
    uint256 public ghostBurnedL3;
    /// @notice Layer 2 drew while layer 1 still had capacity. MUST stay zero (INV-5).
    uint256 public ghostL2DrewWithL1Capacity;
    /// @notice Layer 3 burned while a junior layer still had capacity. MUST stay zero (INV-5).
    uint256 public ghostL3BurnedWithJuniorCapacity;
    /// @notice ADR-0035 reserve-bound draws. Historical getter name retained in reports.
    uint256 public ghostCapBindingDraws;
    /// @notice ADR-0035 draws where the live reserve had enough slack for the residual.
    uint256 public ghostCapSlackDraws;
    /// @notice Loss events that took a non-empty curator pool to exactly zero.
    uint256 public ghostPoolWipes;
    /// @notice Pool wipes that happened in the same event as a reserve-bound layer-2 draw.
    uint256 public ghostWipeWithBindingCap;
    /// @notice Posts into a wiped pool that advanced the share round.
    uint256 public ghostRoundAdvances;
    /// @notice Loss events realized against a class whose round had already advanced.
    uint256 public ghostLossesAfterRoundAdvance;
    /// @notice Custody-loss events executed through ReserveManager's authenticated incident path.
    uint256 public ghostReserveLossEvents;
    uint256 public ghostReserveWriteDownEvents;
    uint256 public ghostReserveReconcileEvents;
    /// @notice Custody-loss calls after which all four F-18-01 facility-accounting families were
    ///         proved unchanged. Must match `ghostReserveLossEvents`.
    uint256 public ghostCustodyF18IsolationChecks;
    /// @notice The upper-namespace SGrove event id of the OPEN custody incident (0 when none).
    uint256 public custodyIncidentId;
    /// @notice Every custody incident id ever opened. The per-event coverage ledger persists in
    ///         SGrove after an incident closes, so it must stay checkable — same reason
    ///         `allFacIds` never shrinks.
    uint256[] internal custodyIncidentIds;
    /// @notice Nonce of the last incident opened. Each new incident takes a FRESH nonce:
    ///         `openReserveLossIncident` refuses a reused id, which is the anti-cap-multiplication
    ///         rule. Partial write-downs INSIDE one incident still reuse its id.
    uint256 public custodyIncidentNonce;
    /// @notice Governance closings of a custody incident — the only legitimate release of the
    ///         R6-CF1 curator freeze, and what keeps INV-7's positive branch reachable afterwards.
    uint256 public ghostCustodyIncidentCloses;

    // ── AUDIT FINDING (campaign 5): reserve-loss ENTRY guards ────────────
    //
    // `DefaultManager.absorbReserveLoss` is a retained compatibility entry with no production
    // caller in this tree. Live custody losses run through ReserveManager's
    // `_absorbRecognizedReserveLoss -> _drawJuniorReserveLoss` cascade. The compatibility entry's
    // two guards are hand-rolled `if (...) revert` checks rather than `onlyRole(...)` modifiers, so
    // `AccessControlSurfaceInvariants` — which enumerates the privileged surface by scanning
    // `src/` for the literal `onlyRole(` — cannot see either of them, and no campaign in the
    // repository had ever driven an input into their illegal region.
    //
    // DO NOT PRE-FILTER THESE PROBES. `_fireAtGuard` fires the raw call and turns the REFUSAL into
    // the asserted property (see `GuardProbe`'s header); checking first that the call would fail
    // is exactly the vacuity this finding is about.
    bytes32 internal constant GUARD_RESERVE_LOSS_CALLER = keccak256("DefaultManager.absorbReserveLoss:caller");
    bytes32 internal constant GUARD_RESERVE_LOSS_NAMESPACE = keccak256("DefaultManager.absorbReserveLoss:namespace");
    /// @notice Probes fired at the caller guard from an address that is NOT the ReserveManager.
    uint256 public ghostReserveLossOutsiderProbes;
    /// @notice Probes fired at the namespace guard, AS the ReserveManager, with a facility id.
    uint256 public ghostReserveLossNamespaceProbes;

    /// @dev Four addresses that hold no role on any module and are never the ReserveManager.
    ///      DO NOT replace with `address(this)` or a fixture actor: the point is that an admitted
    ///      call is unambiguously a bypass rather than a mis-set-up probe.
    address[4] internal reserveLossOutsiders;

    // INV-6
    uint256 public ghostInterestPaid;
    uint256 public ghostFeeToRecipient;
    uint256 public ghostYieldToVault;
    /// @dev AUDIT FIX (ADV-1). Gross protocol fee that was never minted because an unabsorbed
    ///      senior residual stood. INV-6's interest-split identity is now the THREE-way
    ///      `interest == fee + toVault + withheld`; keeping this separate from
    ///      `ghostFeeToRecipient` is what keeps
    ///      `invariant_INV6_protocolFeeTookExactlyItsRate` reconciling against the fee
    ///      recipient's REAL balance.
    uint256 public ghostFeeWithheldForImpairment;
    uint256 public ghostPrincipalRepaid;
    uint256 public ghostDistributions;
    /// @notice A repayment moved value INTO curator capital. MUST stay zero (INV-6).
    uint256 public ghostCuratorPaidFromRepayment;

    // INV-7
    uint256 public ghostCuratorPosts;
    uint256 public ghostCuratorWithdrawals;
    uint256 public ghostCuratorWithdrawn;
    /// @notice A completed withdrawal left the pool below its subordination requirement.
    ///         MUST stay zero (INV-7).
    uint256 public ghostWithdrawBreaches;
    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). A completed withdrawal REDUCED the layer-1 credit the
    ///         conservative senior NAV is extending (`min(declared + pastDue, poolBalance)`).
    ///         MUST stay zero — this is the measured HIGH expressed as a counter.
    uint256 public ghostCreditReductions;
    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). Past-due marks placed by this campaign. An anti-vacuity
    ///         floor: if this is zero, the one unfrozen loss path was never visited and
    ///         `ghostCreditReductions` proves nothing.
    uint256 public ghostPastDueMarks;
    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). Past-due marks cured, so the campaign leaves the region
    ///         as well as entering it.
    uint256 public ghostPastDueClears;
    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). Withdrawals refused with EXACTLY
    ///         `Curator_HeadroomExceeded` while a past-due mark credited the capital and NO freeze
    ///         was armed. The anti-vacuity floor for the marked-floor guard.
    uint256 public ghostCreditedWithdrawRejections;
    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). A withdrawal SUCCEEDED against credited layer-1 capital.
    ///         MUST stay zero — this is the measured HIGH itself, expressed as a counter.
    uint256 public ghostCreditedWithdrawAccepted;
    /// @notice Withdrawals correctly refused while the class carried an unresolved default.
    uint256 public ghostFrozenWithdrawRejections;
    /// @notice A withdrawal SUCCEEDED while the class was frozen. MUST stay zero.
    uint256 public ghostFrozenWithdrawAccepted;
    /// @notice AUDIT R6-CF1. Withdrawals refused with EXACTLY `Curator_CustodyLossFrozen` while a
    ///         reserve-custody loss was recognised and unabsorbed. Counted only on that selector:
    ///         a refusal for any other reason (no stake, no headroom, a facility freeze) would
    ///         mean the probe never reached the guard, and counting it would make this floor
    ///         vacuous — the exact failure mode campaign 5 caught in pre-filtered handlers.
    uint256 public ghostCustodyFrozenWithdrawRejections;
    /// @notice AUDIT R6-CF1. A withdrawal SUCCEEDED while the custody freeze was armed. MUST stay
    ///         zero — this is the finding itself, expressed as a counter.
    uint256 public ghostCustodyFrozenWithdrawAccepted;
    /// @notice Adversarial "pull first-loss immediately before declaring the default" attempts.
    uint256 public ghostRaceAttempts;
    uint256 public ghostRaceValuePulled;
    uint256 public ghostTargetChanges;
    /// @notice Observations where the TARGET was the binding leg of `min(target, exposure)`.
    uint256 public ghostTargetBindingObs;
    /// @notice Observations where the EXPOSURE was the binding leg of `min(target, exposure)`.
    uint256 public ghostExposureBindingObs;
    uint256 public ghostCapChanges;
    uint256 public ghostExposureIncreases;
    uint256 public ghostExposureDecreases;
    uint256 public ghostDefaultsDeclared;
    uint256 public ghostFreezeLifts;
    uint256 public ghostSeniorDeposits;

    // Senior-side reconstruction (INV-6). Every USDfr movement into or out of the vault in this
    // campaign is one of exactly three things, all recorded here from the handler's own inputs.
    uint256 public ghostSeniorDeposited;
    /// @notice Origination fees minted to the fee recipient, modeled from `M_ORIGINATION_FEE_BPS`.
    uint256 public ghostOriginationFees;

    // ── facility book ────────────────────────────────────────────────────

    uint256[] internal facIds;
    /// @dev Never shrinks — cumulative `eventCovered` observability must remain checkable after a
    ///      facility resolves. ADR-0035 leaves `eventCapSnapshot` as an unwritten storage tombstone.
    uint256[] internal allFacIds;
    mapping(uint256 tokenId => uint256) public facClass;
    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). Handler-side mirror of `DefaultManager.pastDueMarked`.
    ///         This handler is the ONLY caller of `markPastDue`/`clearPastDue` in the campaign, so
    ///         the mirror is exact except for the auto-release on a full principal repayment, which
    ///         `clearPastDueMark` re-syncs.
    mapping(uint256 tokenId => bool) public mPastDue;

    constructor(Wiring memory w) {
        usdc = MockERC20(w.usdc);
        usdfr = USDfr(w.usdfr);
        reserves = ReserveManager(w.reserves);
        controller = MintRedeemController(w.controller);
        vault = SUSDfr(w.vault);
        registry = CollateralRegistry(w.registry);
        bridge = ClaimBridge(w.bridge);
        oracle = IInvariantOracleDriver(w.oracle);
        curator = CuratorModule(w.curator);
        waterfall = WaterfallEngine(w.waterfall);
        defaultManager = DefaultManager(w.defaultManager);
        sGrove = SGrove(w.sGrove);
        admin = w.admin;
        guardian = w.guardian;
        servicer = w.servicer;
        originator = w.originator;
        custodian = w.custodian;
        borrower = w.borrower;
        feeRecipient = w.feeRecipient;
        curatorA = w.curatorA;
        curatorB = w.curatorB;
        senior = w.senior;
        coverageFunder = w.coverageFunder;

        M_PROTOCOL_FEE_BPS = Config.DEFAULT_PROTOCOL_FEE_BPS;
        M_ORIGINATION_FEE_BPS = Config.DEFAULT_ORIGINATION_FEE_BPS;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            mTarget[c] = Config.DEFAULT_FIRST_LOSS_PER_CLASS;
        }

        // AUDIT FINDING (campaign 5). Register BEFORE any probe fires, so `reachReport()` can show
        // a guard that was NEVER reached. A guard that only appears the first time it is hit could
        // never be reported as not-reached, which is the exact vacuity the ledger exists to expose.
        reserveLossOutsiders[0] = makeAddr("reserveLossOutsiderAlpha");
        reserveLossOutsiders[1] = makeAddr("reserveLossOutsiderBravo");
        reserveLossOutsiders[2] = makeAddr("reserveLossOutsiderCharlie");
        reserveLossOutsiders[3] = makeAddr("reserveLossOutsiderDelta");
        _registerGuard(
            GUARD_RESERVE_LOSS_CALLER,
            IDefaultManager.DefaultManager_ReserveLossCallerNotReserve.selector,
            "DefaultManager.absorbReserveLoss <- non-ReserveManager caller"
        );
        _registerGuard(
            GUARD_RESERVE_LOSS_NAMESPACE,
            IDefaultManager.DefaultManager_InvalidReserveLossIncident.selector,
            "DefaultManager.absorbReserveLoss <- facility-namespace incident id"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    //  FUZZ ACTIONS (every one must appear in the `targetSelector` list)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Senior capital enters the vault — cascade LAYER 3's capacity.
    function depositSenior(uint256 amountSeed) external {
        fuzzActionEntries++;
        // The R15-01 degenerate-price band and the pause guard both surface as `maxDeposit == 0`.
        // Reading the contract's own precondition here is a GUARD, not a prediction: no asserted
        // quantity is derived from it.
        if (vault.maxDeposit(senior) == 0) return;
        uint256 amount = _align(bound(amountSeed, 10 * UNIT, 500_000e18));
        if (amount == 0) return;
        _depositSenior(amount);
        callCount++;
    }

    /// @notice Curator posts first-loss — cascade LAYER 1's capacity.
    /// @param classSeed Selects the class (1..5; class 5 keeps zero exposure by construction).
    /// @param amountSeed Bounded post size.
    /// @param useSecondCurator Routes the post through the second approved curator on class 1, so
    ///        a class can hold two stakes and pro-rata dilution is genuinely exercised.
    function postFirstLoss(uint256 classSeed, uint256 amountSeed, bool useSecondCurator) external {
        fuzzActionEntries++;
        uint256 classId = 1 + (classSeed % Config.NUM_CLASSES);
        address who = (useSecondCurator && classId == Config.CLASS_FILM_TAX_CREDITS) ? curatorB : curatorA;
        uint256 amount = _align(bound(amountSeed, UNIT, 500_000e18));
        if (amount == 0) return;
        _postFirstLossAs(who, classId, amount);
        callCount++;
    }

    /// @notice Curator withdraws within subordination headroom — the INV-7 lever.
    /// @dev When the class carries an unresolved default, OR a reserve-custody loss is unabsorbed,
    ///      the withdrawal MUST be refused. NEITHER branch is skipped: each becomes a negative
    ///      probe that DRIVES the call into the illegal region, counts the rejection, and records
    ///      acceptance as a violation the invariant asserts on. Pre-filtering here — returning
    ///      early instead of calling — would make both guards invisible to the campaign.
    function withdrawFirstLoss(uint256 classSeed, uint256 amountSeed, bool useSecondCurator) external {
        fuzzActionEntries++;
        uint256 classId = 1 + (classSeed % Config.NUM_CLASSES);
        address who = (useSecondCurator && classId == Config.CLASS_FILM_TAX_CREDITS) ? curatorB : curatorA;

        // AUDIT R6-CF1. Probed FIRST, and deliberately WITHOUT a stake precondition. Two reasons,
        // both about not making the probe weaker than the guard:
        //   - `withdrawFirstLoss` evaluates the custody freeze BEFORE the caller's stake and
        //     before headroom, so a zero-stake caller still proves the guard fired. Requiring a
        //     stake here would have made the frozen regime reachable only on the handful of
        //     classes that still hold capital late in a run — measured: ONE probe per campaign,
        //     entirely from the deterministic seed, with the fuzz body never reaching it.
        //   - it is routed away only when the class ALSO carries an R4-EC2 freeze, because the
        //     contract raises the class error first and this counter must stay attributable.
        // `_probeCustodyFrozenWithdraw` counts ONLY `Curator_CustodyLossFrozen`, so a probe that
        // landed on any other refusal cannot inflate the anti-vacuity floor.
        if (mCustodyFrozen() && mFrozen[classId] == 0) {
            _probeCustodyFrozenWithdraw(who, classId, UNIT);
            callCount++;
            return;
        }

        uint256 posted = curator.postedOf(classId, who);
        if (posted == 0) return;

        if (mFrozen[classId] != 0) {
            _probeFrozenWithdraw(who, classId, posted < UNIT ? posted : UNIT);
            callCount++;
            return;
        }

        uint256 free = _modelHeadroom(classId);
        uint256 max = posted < free ? posted : free;
        if (max == 0) return;
        _withdrawFirstLossAs(who, classId, bound(amountSeed, 1, max));
        callCount++;
    }

    /// @notice ADVERSARIAL TIMING (SYSTEM_MODEL section 2: "an adversarial curator's main lever is
    ///         withdrawal timing around a known-imminent loss") — pull the maximum legal
    ///         first-loss, then declare the default on the very next instruction.
    /// @dev The properties under test are unchanged: INV-7 must hold at the withdrawal and INV-5
    ///      at the loss that follows. This action exists so the campaign actually visits the
    ///      adversarial ordering rather than relying on the fuzzer to interleave it.
    function curatorRaceWithdrawThenDefault(uint256 facSeed) external {
        fuzzActionEntries++;
        uint256 id = _pickPerforming(facSeed);
        if (id == 0) return;
        if (mFrozen[facClass[id]] != 0) return;
        // AUDIT R6-CF1. This action needs a SUCCESSFUL withdrawal to set the race up, so it steps
        // aside while the custody freeze is armed. That is not a pre-filter hiding the guard: the
        // guard's own negative probe lives in `withdrawFirstLoss` above and runs on every class.
        if (mCustodyFrozen()) return;
        _raceWithdrawThenDefault(id);
        callCount++;
    }

    /// @notice Funds the sGROVE USDfr coverage reserve — cascade LAYER 2's capacity.
    function fundCoverage(uint256 amountSeed) external {
        fuzzActionEntries++;
        uint256 amount = _align(bound(amountSeed, UNIT, 400_000e18));
        if (amount == 0) return;
        _fundCoverageWith(amount);
        callCount++;
    }

    /// @notice Repeatedly asserts ADR-0035's public capacity identity on arbitrary reserves.
    function checkUncappedCapacity(uint256 reserveSeed) external {
        fuzzActionEntries++;
        _assertUncappedCapacityIdentity(reserveSeed);
        callCount++;
    }

    function _assertUncappedCapacityIdentity(uint256 reserveSeed) private {
        assertEq(sGrove.coverageCapacity(), sGrove.coverageReserve(), "ADR-0035 live capacity mismatch");
        assertEq(sGrove.coverageCapacityAt(reserveSeed), reserveSeed, "ADR-0035 counterfactual not identity");
        (uint16 bps, uint256 absoluteCap) = sGrove.coverageCapParameters();
        assertEq(bps, Config.BPS, "ADR-0035 compatibility bps");
        assertEq(absoluteCap, type(uint256).max, "ADR-0035 compatibility absolute cap");
        ghostCapChanges++; // historical getter: now counts uncapped-capacity identity checks
    }

    /// @notice Governance moves the first-loss target — an INV-7 input, moved WHILE the formula is
    ///         under test rather than held static.
    /// @dev TWO BANDS, deliberately. A single uniform draw over [0, 3,000,000e18] leaves
    ///      `min(target, exposure)` above the pool almost always, so `headroom` is zero almost
    ///      always and no withdrawal is ever admissible — measured: 4 successful withdrawals and
    ///      zero value pulled by the adversarial race across a default-profile run. The low band
    ///      makes the target the binding leg often enough that the withdrawal lever, and the
    ///      timing race around it, are genuinely exercised. The high band keeps the launch
    ///      configuration (exposure binding) equally reachable; both are counted by
    ///      `ghostTargetBindingObs` / `ghostExposureBindingObs`.
    function setFirstLossTarget(uint256 classSeed, uint256 targetSeed) external {
        fuzzActionEntries++;
        uint256 classId = 1 + (classSeed % Config.NUM_CLASSES);
        uint256 hi = (targetSeed & 1 == 0) ? 250_000e18 : 3_000_000e18;
        _setFirstLossTarget(classId, bound(targetSeed, 0, hi));
        callCount++;
    }

    /// @notice Originates and funds a receivable facility — the INV-7 exposure input, and the
    ///         principal a loss can later be realized against.
    function originateAndFund(uint256 classSeed, uint256 principalSeed) external {
        fuzzActionEntries++;
        if (facIds.length >= MAX_FACILITIES) return;
        uint256 classId = 1 + (classSeed % NUM_LOAN_CLASSES);
        uint256 principal = _align(bound(principalSeed, 20_000e18, 400_000e18));
        if (principal == 0 || mTotalExposure + principal > MAX_BOOK) return;
        _originateAndFund(classId, principal);
        callCount++;
    }

    /// @notice An attested repayment. INV-6's positive statement: interest splits into exactly
    ///         protocol fee + senior vault, and NOTHING lands in curator capital.
    /// @dev Both distributable regimes are driven: an ordinary performing receipt, and a WORKOUT
    ///      recovery on a defaulted facility. Restricting this to performing facilities starved
    ///      INV-6 — measured: with two of fourteen selectors declaring defaults against one
    ///      originating, the fuzz campaign produced ZERO distributions beyond the deterministic
    ///      seed, because no performing facility survived long enough to be paid.
    function repay(uint256 facSeed, uint256 interestSeed, uint256 principalSeed) external {
        fuzzActionEntries++;
        uint256 id = _pickDistributable(facSeed);
        if (id == 0) return;
        uint256 outstanding = reserves.deployedTo(id);
        uint256 interest = _align(bound(interestSeed, 0, 40_000e18));
        uint256 principal = _align(bound(principalSeed, 0, outstanding));
        if (interest + principal == 0) return;
        _distribute(id, interest, principal, outstanding);
        callCount++;
    }

    /// @notice AUDIT FIX (SWEEP-2 CSG-F1) — THE REGION THIS CAMPAIGN COULD NOT REACH.
    ///         `markPastDue` is the ONE loss path with no freeze at all: it does not arm R4-EC2
    ///         (`unresolvedDefaults` stays 0, deliberately — "a reversible past-due mark must not
    ///         freeze first-loss") and it does not move `totalBackingValue()`, so R6-CF1 limb 4 is
    ///         false too. It is therefore the exact state in which layer-1 capital the conservative
    ///         senior NAV is crediting could walk out — and this handler had ZERO `markPastDue`
    ///         occurrences, so the campaign never visited it and INV-7 stayed green through the
    ///         measured HIGH. Registering the action is the whole point: adding the model term
    ///         without a caller would have left the sharpest region unreached.
    /// @dev Permissionless in production and permissionless here — no `vm.prank`. The facility must
    ///      genuinely be past `nextPaymentDue + graceWindow`, which is why this warps first.
    function markPastDue(uint256 facSeed) external {
        fuzzActionEntries++;
        uint256 id = _pickPerforming(facSeed);
        if (id == 0 || mPastDue[id]) return;
        ClaimBridge.Facility memory f = bridge.facility(id);
        if (registry.classParams(f.classId).model != ICollateralRegistry.CollateralModel.Receivable) return;
        uint256 due = uint256(f.nextPaymentDue) + uint256(defaultManager.graceWindow(f.classId)) + 1;
        if (due > block.timestamp) vm.warp(due);
        defaultManager.markPastDue(id);
        mPastDue[id] = true;
        ghostPastDueMarks++;
        callCount++;
    }

    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). The SERVICER cure that releases a past-due mark. Without
    ///         it the first mark would lock every curator pool for the rest of the run and INV-7's
    ///         POSITIVE branch — a completed withdrawal that must respect the headroom — would be
    ///         starved, which is the same silent loss of coverage `closeCustodyIncident` exists to
    ///         prevent on the custody arm.
    function clearPastDueMark(uint256 facSeed) external {
        fuzzActionEntries++;
        uint256 n = facIds.length;
        if (n == 0) return;
        uint256 start = facSeed % n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = facIds[(start + i) % n];
            if (!mPastDue[id]) continue;
            // A full principal repayment auto-releases the mark (`_releasePastDue`), leaving the
            // contribution at zero and the flag off in the contract. Re-sync rather than call:
            // calling would revert `DefaultManager_NotPastDueMarked` under `fail_on_revert`.
            if (defaultManager.pastDueContribution(id) == 0) {
                mPastDue[id] = false;
                return;
            }
            // A FRESH evidence hash per cure: the oracle realises each fact key exactly once
            // (Oracle_FactAlreadyRealised), so a constant hash bricks the second cure of any run.
            bytes32 evidence = keccak256(abi.encode("cure", id, ghostPastDueClears));
            oracle.setPayload(
                id,
                IAttestationOracle.AttestationKind.PastDueCured,
                keccak256(abi.encode(id, evidence)),
                uint64(block.timestamp),
                true
            );
            vm.prank(servicer);
            defaultManager.clearPastDue(id, evidence);
            mPastDue[id] = false;
            ghostPastDueClears++;
            callCount++;
            return;
        }
    }

    /// @notice Declares an attested default — arms the curator freeze and unlocks `realizeLoss`.
    function declareDefault(uint256 facSeed) external {
        fuzzActionEntries++;
        uint256 id = _pickPerforming(facSeed);
        if (id == 0) return;
        _declareDefault(id);
        callCount++;
    }

    /// @notice Governance resolves a workout and lifts one freeze, re-opening the INV-7 withdrawal
    ///         lever so the timing race stays reachable for the rest of the run.
    function liftDefaultFreeze(uint256 classSeed) external {
        fuzzActionEntries++;
        uint256 classId = 1 + (classSeed % Config.NUM_CLASSES);
        if (mFrozen[classId] == 0) return;
        vm.prank(admin);
        curator.liftDefaultFreeze(classId);
        mFrozen[classId] -= 1;
        ghostFreezeLifts++;
        callCount++;
    }

    /// @notice THE CASCADE. Realizes an attested loss and checks the layer split against the
    ///         independent model, per call.
    function realizeLoss(uint256 facSeed, uint256 lossSeed) external {
        fuzzActionEntries++;
        fuzzRealizeEntries++;
        uint256 id = _pickDefaulted(facSeed);
        if (id == 0) return;
        uint256 max = _maxRealizableLoss(id);
        if (max == 0) return;
        _realizeLossChecked(id, bound(lossSeed, 1, max));
        callCount++;
    }

    /// @notice An authenticated idle-reserve custody loss through the same real three-layer
    ///         cascade, modeled independently across all five curator pools.
    /// @dev Every call reuses one governance-opened incident id. The amount is bounded to the
    ///      fully absorbable, USDC-exact range so this invariant family remains in the solvent
    ///      regime; explicit deficit latching is covered by deterministic ReserveManager tests.
    function writeDownReserveCustodyLoss(uint256 lossSeed, bool throughReconcile) external {
        fuzzActionEntries++;
        fuzzReserveLossEntries++;
        uint256 max = _maxCustodyLoss();
        if (max < UNIT) return;
        _reserveCustodyLossChecked(_align(bound(lossSeed, UNIT, max)), throughReconcile);
        callCount++;
    }

    /// @notice AUDIT R6-CF1. Governance closes an adjudicated custody incident once absorption is
    ///         finished — the ONLY legitimate release of the curator custody freeze.
    /// @dev Registering this is load-bearing in BOTH directions. Without it the campaign's first
    ///      custody loss would leave the incident open forever, every later `withdrawFirstLoss`
    ///      would be a negative probe, and INV-7's POSITIVE branch (a completed withdrawal that
    ///      must respect subordination headroom) would be starved for the rest of every run — a
    ///      silent loss of coverage dressed up as a green campaign. With it, both the frozen and
    ///      the free regimes are reached, and `ghostCustodyIncidentCloses` proves it.
    function closeCustodyIncident() external {
        fuzzActionEntries++;
        if (!mCustodyIncidentOpen) return;
        _closeCustodyIncident();
        callCount++;
    }

    /// @notice Scripted reach for a fully wiped curator round and a reserve-bound layer-2 draw.
    /// @dev Random sequencing reaches each shape, but their conjunction — plus the round advance
    ///      and a further loss inside the new round — is thin. Every
    ///      sub-step is a real call through the real role under the same per-call differential
    ///      model as the fuzzed path; this action scripts the ORDER only, never the accounting.
    ///      Every precondition early-returns, so a partial run simply leaves a legitimate state.
    function stressWipedRoundWithReserveBound(uint256 facSeed, uint256 lossSeed) external {
        fuzzActionEntries++;
        uint256 id = _pickDefaulted(facSeed);
        if (id == 0) return;
        uint256 classId = facClass[id];
        uint256 pool = mPool[classId];
        if (pool == 0) return; // nothing to wipe
        if (mCoverageReserve == 0) return; // layer 2 could not engage at all

        uint256 max = _maxRealizableLoss(id);
        uint256 minimum = pool + mCoverageReserve + 1;
        if (max < minimum) return; // cannot wipe layer 1 and exhaust layer 2 in one event
        _realizeLossChecked(id, bound(lossSeed, minimum, max));

        // Re-post into the now-wiped pool: the ROUND ADVANCE, where stale shares are cleared and
        // fresh capital must not be diluted by the wiped round's shares.
        uint256 topUp = _align(bound(uint256(keccak256(abi.encode(lossSeed))), UNIT, 50_000e18));
        if (topUp != 0) _postFirstLossAs(curatorA, classId, topUp);
        callCount++;
    }

    /// @notice AUDIT FINDING (campaign 5) — UNFILTERED probes at the two entry guards on the
    ///         retained `DefaultManager.absorbReserveLoss` compatibility surface.
    /// @dev WHY THIS ACTION EXISTS. The live custody cascade is
    ///      `ReserveManager._absorbRecognizedReserveLoss -> _drawJuniorReserveLoss`; it does not
    ///      call this entry. The retained entry is not `onlyRole`-gated — it compares `msg.sender`
    ///      to the bound ReserveManager — so the runtime
    ///      `onlyRole(` enumeration behind `AccessControlSurfaceInvariants` cannot see it, and
    ///      before this action NOTHING in the repository ever called it from a wrong caller or
    ///      with a facility-namespace incident id. Both guards were entirely un-executed.
    ///
    ///      THE INPUTS ARE DRIVEN INTO THE ILLEGAL REGION ON PURPOSE, in EVERY protocol state the
    ///      campaign reaches — pools funded and pools wiped, cap slack and cap bound, senior
    ///      staked and senior empty. `bound()` here selects WHICH illegal input is used; it never
    ///      moves an input back into the admissible band. If a guard is removed, the call is
    ///      ADMITTED and really executes the cascade, `guardAdmissions` records it and
    ///      `invariant_reserveLossEntryGuardsAdmitNoOutsider` fails on the very next evaluation.
    ///
    /// @dev DO NOT DELETE, and do not "fix" this by checking whether the call would revert first.
    ///      That check is the pre-filter that made six earlier suites vacuous.
    function probeReserveLossEntryGuards(uint256 callerSeed, uint256 amountSeed, uint256 idSeed) external {
        fuzzActionEntries++;
        _probeReserveLossEntryGuards(
            bound(callerSeed, 0, reserveLossOutsiders.length - 1),
            // Small enough that a live cascade would comfortably execute it if a guard were gone,
            // so an ADMITTED verdict cannot be masked by some unrelated capacity revert.
            bound(amountSeed, 1, 1_000e18),
            bound(idSeed, 0, LossEventIds.CUSTODY_EVENT_NAMESPACE_START - 1)
        );
        callCount++;
    }

    /// @dev Shared by the fuzzed action and the deterministic seed, so the seed exercises the
    ///      identical code path rather than a convenient imitation of it.
    function _probeReserveLossEntryGuards(uint256 outsiderIndex, uint256 amount, uint256 facilityId) private {
        // (a) CALLER guard: a valid, in-namespace custody id, from an address that is not the
        //     ReserveManager. The id is valid so the ONLY thing standing between the caller and
        //     the senior book is the caller check itself.
        //
        //     MERGE NOTE (2026-08-07). This probe used to read the campaign-wide
        //     `CUSTODY_INCIDENT_NONCE` constant, which R6-CF1 removed when incidents stopped being
        //     a single pinned one (governance may now CLOSE one and open a successor on a fresh
        //     nonce). The probe never needed THE campaign's incident — only an id inside the
        //     custody namespace, so that `isCustodyEvent` cannot be what refuses the call and the
        //     caller check is the sole obstacle. It therefore uses the live nonce when one exists
        //     and falls back to `PROBE_CUSTODY_NONCE` before the first incident is opened.
        //     `custodyEventId` maps EVERY nonce into the upper namespace, so both are valid.
        uint256 probeIncidentId =
            LossEventIds.custodyEventId(custodyIncidentNonce == 0 ? PROBE_CUSTODY_NONCE : custodyIncidentNonce);
        _fireAtGuard(
            GUARD_RESERVE_LOSS_CALLER,
            reserveLossOutsiders[outsiderIndex],
            address(defaultManager),
            abi.encodeCall(DefaultManager.absorbReserveLoss, (probeIncidentId, amount))
        );
        ghostReserveLossOutsiderProbes++;

        // (b) NAMESPACE guard: the AUTHORIZED caller with a FACILITY-namespace id. Admitting one
        //     would collapse custody and facility accounting onto the same event identity and
        //     corrupt the cascade's loss provenance.
        _fireAtGuard(
            GUARD_RESERVE_LOSS_NAMESPACE,
            address(reserves),
            address(defaultManager),
            abi.encodeCall(DefaultManager.absorbReserveLoss, (facilityId, amount))
        );
        ghostReserveLossNamespaceProbes++;
    }

    /// @notice Time passes. Fee accrual — the dilution that runs alongside every cascade leg — is
    ///         time-dependent, so a static clock would hide it.
    function warp(uint256 dtSeed) external {
        fuzzActionEntries++;
        vm.warp(block.timestamp + bound(dtSeed, 1 hours, 7 days));
        callCount++;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  DETERMINISTIC SEED (called once from the test's setUp; NOT a selector)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Drives one of every shape the anti-vacuity floors assert, deterministically.
    /// @dev House pattern (see `CollateralInvariants.afterInvariant`): forge restarts every run
    ///      from the post-`setUp` state and `afterInvariant` samples ONE run, so a single run's
    ///      fuzz reach is not a safe floor for narrow shapes. The seed guarantees every run is
    ///      evaluated against a state where each shape exists; `fuzzActionEntries` and
    ///      `fuzzRealizeEntries` remain the wiring tooth, and everything above the seed floor is
    ///      the fuzz campaign's own reach (reported by `invariant_callSummary`).
    function seedCascadeShapes() external {
        // (1) layer 3 capacity
        _depositSenior(400_000e18);
        // (2) layer 1 capacity; two curators in one class so dilution is pro-rata over two stakes
        _postFirstLossAs(curatorA, Config.CLASS_FILM_TAX_CREDITS, 100_000e18);
        _postFirstLossAs(curatorB, Config.CLASS_FILM_TAX_CREDITS, 50_000e18);
        _postFirstLossAs(curatorA, Config.CLASS_RENEWABLE_ENERGY, 20_000e18);
        _postFirstLossAs(curatorA, Config.CLASS_LIFE_SCIENCES, 60_000e18);
        _postFirstLossAs(curatorA, Config.CLASS_REAL_ESTATE, 80_000e18);
        // (3) layer 2 capacity
        _fundCoverageWith(200_000e18);
        // (4) ADR-0035: the whole 200,000 reserve is live and may be exhausted by one event.
        // Seed the identity check because `afterInvariant` samples one run and a 19-way selector
        // can legitimately miss this action in a short profile even though it is wired.
        _assertUncappedCapacityIdentity(137_000e18);
        // (5) the book
        // (0) AUDIT FIX (SWEEP-2 CSG-F1) — DETERMINISTIC FLOOR FOR THE ONE UNFROZEN LOSS PATH.
        //     A past-due mark arms NO freeze at all (R4-EC2 stays at zero, and it does not move
        //     `totalBackingValue()` so R6-CF1 limb 4 is false too), so it is the only state in
        //     which layer-1 capital the conservative senior NAV is crediting could walk out — the
        //     measured HIGH. Left to the fuzzer this region is reached only on luck; seeded,
        //     `afterInvariant` can assert it was ENTERED, that a credited withdrawal was REFUSED
        //     inside it, and that the campaign can LEAVE it again.
        //     IT RUNS FIRST, DELIBERATELY: no class is frozen and no declared principal stands
        //     yet, so the refusal is attributable to the past-due mark ALONE. Placed after the
        //     defaults below it would be indistinguishable from the declared-principal floor.
        _seedPastDueRegion();
        uint256 f1 = _originateAndFund(Config.CLASS_FILM_TAX_CREDITS, 400_000e18);
        uint256 f2 = _originateAndFund(Config.CLASS_RENEWABLE_ENERGY, 300_000e18);
        uint256 f3 = _originateAndFund(Config.CLASS_LIFE_SCIENCES, 200_000e18);
        uint256 f4 = _originateAndFund(Config.CLASS_REAL_ESTATE, 250_000e18);
        // (5b) THE ADVERSARIAL ORDERING, deterministically: lower the class-4 target so real
        //      headroom exists, then pull the maximum legal first-loss and declare the default in
        //      the very next instruction. Seeded because the fuzz campaign reaches this ordering
        //      only when a performing facility happens to sit in an unfrozen class with a pool
        //      above its subordination requirement — measured 0 to 4 times per run, so it is not
        //      a safe floor on fuzz luck alone.
        // (5c) INV-6: an attested repayment carrying both legs.
        //
        // AUDIT FIX (ADV-1) — THIS STEP MOVED UP, DELIBERATELY, AND MUST STAY AHEAD OF (5d). It
        // used to sit AFTER `_raceWithdrawThenDefault(f4)`. Once ADV-1 withholds the protocol fee
        // while an unabsorbed senior residual stands, a distribution ordered after the FIRST
        // declared default pays a fee of ZERO — and because every later seeded step declares
        // further defaults, `ghostFeeToRecipient` stayed zero for the whole campaign and
        // `afterInvariant`'s "THE PROTOCOL FEE LEG NEVER CARRIED VALUE" reach assert fired. The
        // campaign must visit BOTH regimes: fee PAID on a clean book (here) and fee WITHHELD under
        // a standing residual (every later distribution, plus the fuzzed `repay` action).
        //
        // NOTHING ELSE ABOUT THE SEEDED SHAPES MOVES. The senior leg is identical in both orderings
        // — ADV-1 withholds only the fee and sizes `toVault` off the GROSS fee — so `vault
        // .totalAssets()`, and therefore every layer-3 capacity computed from it, is unchanged.
        // f3's outstanding reaches the same 150,000e18 before step (13) either way, and f4's
        // race-withdraw depends on class-4 exposure, which an f3 repayment does not touch.
        _distribute(f3, 10_000e18, 50_000e18, reserves.deployedTo(f3));
        // (5d) THE ADVERSARIAL ORDERING, deterministically (see the (5b) comment above).
        _setFirstLossTarget(Config.CLASS_REAL_ESTATE, 30_000e18);
        _raceWithdrawThenDefault(f4);
        // (7) INV-7: both legs of min(target, exposure), and a real withdrawal
        _setFirstLossTarget(Config.CLASS_LIFE_SCIENCES, 10_000e18); // target binds
        _setFirstLossTarget(Config.CLASS_FILM_TAX_CREDITS, 3_000_000e18); // exposure binds
        _withdrawFirstLossAs(curatorA, Config.CLASS_LIFE_SCIENCES, 20_000e18);
        // (8) the freeze, and the negative probe that it really does refuse a withdrawal
        _declareDefault(f1);
        _probeFrozenWithdraw(curatorA, Config.CLASS_FILM_TAX_CREDITS, UNIT);
        // (8b) AUDIT FIX (ADV-1) — THE WITHHOLDING REGIME, REACHED DETERMINISTICALLY. The paired
        // half of (5c). f1's 400,000e18 is now declared against a 150,000e18 class-1 curator pool
        // and the live sGROVE reserve, so an unabsorbed senior residual stands and ADV-1 must
        // withhold the whole protocol fee on this receipt while
        // paying the senior leg in full. Seeded rather than left to the fuzzer: the campaign's
        // facilities are declared and realized quickly, and `repay` measured ZERO distributions
        // under a standing residual across 32768 calls — the third leg of INV-6's identity would
        // have been permanently vacuous, which is a green campaign proving nothing about the fix.
        // `afterInvariant` asserts BOTH regimes were visited.
        _distribute(f3, 10_000e18, 0, reserves.deployedTo(f3));
        // (9) THE INTERACTION: wipe layer 1, exhaust the 200,000 reserve and spill 40,000 into
        //     layer 3 in one event.
        _realizeLossChecked(f1, 390_000e18);
        // (10) the round advance on a wiped pool
        _postFirstLossAs(curatorA, Config.CLASS_FILM_TAX_CREDITS, 30_000e18);
        // (11) a further loss inside the NEW round
        _realizeLossChecked(f1, 10_000e18);
        // (12) Replenish, then exercise the live-reserve slack regime.
        _fundCoverageWith(120_000e18);
        _declareDefault(f2);
        _realizeLossChecked(f2, 60_000e18);
        // (13) the RESERVE-BOUND regime on layer 2 — the third and last way a draw can be
        //      limited. A different event drains the shared reserve before f2's next draw.
        _declareDefault(f3);
        _realizeLossChecked(f3, 140_000e18); // drains the coverage reserve 120,000 -> 20,000
        _realizeLossChecked(f2, 30_000e18); // room 120,000 > reserve 20,000: reserve-bound, spills to layer 3
        // (14) governance resolves one workout, re-opening the withdrawal lever on class 1
        vm.prank(admin);
        curator.liftDefaultFreeze(Config.CLASS_FILM_TAX_CREDITS);
        mFrozen[Config.CLASS_FILM_TAX_CREDITS] -= 1;
        ghostFreezeLifts++;
        // (15) custody loss: use the authenticated upper-namespace incident path at least once
        //      in every run, while preserving the facility-default accounting F-18-01 repaired.
        _ensureCustodyIncident();
        _reserveCustodyLossChecked(UNIT, false);
        _reserveCustodyLossChecked(UNIT, true);
        // (15b) AUDIT R6-CF1: the custody freeze must REFUSE a withdrawal for as long as the
        //       incident is open. Probed on class 5, which is marked-to-market with deliberately
        //       zero exposure and has never defaulted — so `min(target, exposure) == 0`, the whole
        //       pool is inside headroom, and the class carries no R4-EC2 freeze. The custody guard
        //       is therefore the ONLY thing that can refuse this call, which is what makes the
        //       floor non-vacuous (the probe counts only `Curator_CustodyLossFrozen`).
        _postFirstLossAs(curatorA, Config.CLASS_DIGITAL_ASSETS, 10_000e18);
        _probeCustodyFrozenWithdraw(curatorA, Config.CLASS_DIGITAL_ASSETS, UNIT);
        // (16) governance closes the adjudicated incident once absorption is finished, restoring
        //      withdrawal liveness so every run starts from a state where INV-7's POSITIVE branch
        //      is reachable and the fuzz campaign can visit both regimes.
        _closeCustodyIncident();
        // (17) AUDIT FINDING (campaign 5) — deterministic FLOOR for the two `absorbReserveLoss`
        //      entry guards, so `afterInvariant` can assert they were entered without depending on
        //      fuzz luck (with 17 selectors, the chance a specific one is never drawn is
        //      (16/17)^depth — about 14% at lite's depth 32, which is not an acceptable flake in a
        //      permanently shipped suite). Everything above this floor is the campaign's own
        //      reach: `probeReserveLossEntryGuards` fires the same two probes from EVERY state the
        //      fuzzer walks through, and its counters are reported separately.
        //
        //      MERGE NOTE (2026-08-07): placed AFTER R6-CF1's `_closeCustodyIncident()` on purpose,
        //      and it is safe there. `absorbReserveLoss` never requires an incident to be OPEN — it
        //      only requires the id to be in the custody namespace — so a closed incident cannot
        //      mask an ADMITTED verdict behind an unrelated revert. See `_probeReserveLossEntryGuards`.
        _probeReserveLossEntryGuards(0, UNIT, 1);
    }

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). Mark -> refuse a credited withdrawal -> cure -> withdraw,
    ///      on a fresh class-2 facility, before any default is declared anywhere. `markPastDue` is
    ///      Receivable-only, so class 5 cannot be used.
    function _seedPastDueRegion() internal {
        uint256 id = _originateAndFund(Config.CLASS_RENEWABLE_ENERGY, 100_000e18);
        _postFirstLossAs(curatorA, Config.CLASS_RENEWABLE_ENERGY, 40_000e18);
        _setFirstLossTarget(Config.CLASS_RENEWABLE_ENERGY, 10_000e18);

        ClaimBridge.Facility memory f = bridge.facility(id);
        uint256 due = uint256(f.nextPaymentDue) + uint256(defaultManager.graceWindow(f.classId)) + 1;
        if (due > block.timestamp) vm.warp(due);
        defaultManager.markPastDue(id);
        mPastDue[id] = true;
        ghostPastDueMarks++;

        // THE REFUSAL. Pre-fix, `min(target, exposure)` == 10,000e18 left 30,000e18 withdrawable
        // while the mark credited the whole 40,000e18 pool. It must now be refused on HEADROOM —
        // not on a freeze, which is the H-5 property this fix preserves.
        _probeCreditedWithdraw(curatorA, Config.CLASS_RENEWABLE_ENERGY, 30_000e18);

        // ...and the campaign must be able to LEAVE the region, or INV-7's positive branch starves.
        bytes32 evidence = keccak256(abi.encode("seed-cure", id));
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(id, evidence)),
            uint64(block.timestamp),
            true
        );
        vm.prank(servicer);
        defaultManager.clearPastDue(id, evidence);
        mPastDue[id] = false;
        ghostPastDueClears++;

        // LEAVE NO RESIDUE. The facility is repaid in full and every dollar of the pool is taken
        // back, so class 2 re-enters the seeded shapes below at exactly the state it would have
        // been in without this block. That is not tidiness: an extra 10,000e18 standing in the
        // class-2 pool shifts f2's layer-1/layer-2 split and the RESERVE-BOUND layer-2 regime — one
        // of the three the campaign must visit — stops being reached (MEASURED: "LAYER 2 WAS NEVER
        // LIMITED BY ITS OWN CAPITAL"). A seed that perturbs the shapes it sits beside is a seed
        // that silently deletes coverage.
        _distribute(id, 0, 100_000e18, reserves.deployedTo(id));
        // Sized off what is ACTUALLY still posted, not off the 40,000e18 that was put in. If the
        // marked floor is ever removed, the probe above SUCCEEDS instead of being refused and this
        // line would revert `Curator_InsufficientStake` inside `setUp` — a red, but an unattributable
        // one. Sizing it here makes the mutation surface where it belongs: on
        // `ghostCreditedWithdrawAccepted`, the counter named for the finding.
        _withdrawFirstLossAs(
            curatorA, Config.CLASS_RENEWABLE_ENERGY, curator.postedOf(Config.CLASS_RENEWABLE_ENERGY, curatorA)
        );
        _setFirstLossTarget(Config.CLASS_RENEWABLE_ENERGY, Config.DEFAULT_FIRST_LOSS_PER_CLASS);
    }

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1) NEGATIVE probe. Counts ONLY `Curator_HeadroomExceeded`: a
    ///      refusal for any other reason (a freeze, no stake) would mean the probe never reached
    ///      the marked floor, and counting it would make the anti-vacuity floor vacuous — the
    ///      failure mode `_probeCustodyFrozenWithdraw` documents for its own counter.
    function _probeCreditedWithdraw(address who, uint256 classId, uint256 amount) internal {
        require(mFrozen[classId] == 0 && !mCustodyFrozen(), "seed: the marked floor must be the ONLY refusal");
        vm.prank(who);
        try curator.withdrawFirstLoss(classId, amount) {
            ghostCreditedWithdrawAccepted++;
            uint256 burned = Math.mulDiv(amount, mShares[classId], mPool[classId], Math.Rounding.Ceil);
            mShares[classId] -= burned;
            mPool[classId] -= amount;
        } catch (bytes memory err) {
            bytes4 sel;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                sel := mload(add(err, 0x20))
            }
            if (sel == ICuratorModule.Curator_HeadroomExceeded.selector) ghostCreditedWithdrawRejections++;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INTERNAL ACTIONS — every model update happens here, exactly once
    // ─────────────────────────────────────────────────────────────────────

    function _depositSenior(uint256 amount) internal {
        _mintUSDfr(senior, amount);
        vm.startPrank(senior);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, senior);
        vm.stopPrank();
        ghostSeniorDeposits++;
        ghostSeniorDeposited += amount;
    }

    function _postFirstLossAs(address who, uint256 classId, uint256 amount) internal {
        _mintUSDfr(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();

        // model: a post into a wiped pool with stale shares outstanding starts a new round
        //
        // ═══ INVERTED LOUDLY (SWEEP-3 S3-F1, MEDIUM) — see `_modelAdvanceRoundIfWiped` ═══
        // THIS "INDEPENDENT MODEL" WAS A LINE-BY-LINE COPY OF THE DEFECT IT WAS ORACLING.
        // `invariant_INV5_layer1CapacityMatchesIndependentModel` transcribed `postFirstLoss`'s
        // exact-wipe condition, so when a near-total absorption left one wei standing the model
        // inflated its own share supply in lockstep with the contract and BLESSED THE RESULT.
        // MEASURED: the campaign genuinely reaches the region — a 1.6e47 model share supply over
        // 190 runs / 24,320 calls / 0 reverts — and asserted the inflated number as correct. No
        // invariant anywhere bounded the share/balance ratio; `Fix_H03CuratorFreezeInvariants`
        // explicitly STEERS AROUND it (`MAX_POOL_SHARES = 1e48`, "escalated to a FULL wipe").
        // The model now mirrors the FIXED rule. See the SWEEP-3 S3-F1 block in
        // `CuratorModule.postFirstLoss` for the constant and its bound.
        _modelAdvanceRoundIfWiped(classId);
        _modelNormalizePoolShares(classId);
        uint256 minted = mShares[classId] == 0 ? amount : Math.mulDiv(amount, mShares[classId], mPool[classId]);
        mShares[classId] += minted;
        mPool[classId] += amount;
        ghostCuratorPosts++;
        _observeHeadroomRegime(classId);
    }

    /// @dev Mirrors `CuratorModule._advanceRoundIfWiped` (AUDIT FIX SWEEP-3 S3-F1). Called ONLY
    ///      from the model's post, exactly where production calls it — deliberately NOT from the
    ///      absorption or withdrawal sites. See "WHY THE NORMALISATION IS LAZY" in
    ///      `CuratorModule.postFirstLoss`: normalising inside the cascade forfeits a curator's
    ///      claim on the residual at the loss and reds `testFuzz_absorbLoss_proRataExact`.
    function _modelAdvanceRoundIfWiped(uint256 classId) internal {
        uint256 shares = mShares[classId];
        if (shares == 0 || mPool[classId] > shares / CURATOR_MAX_SHARE_INFLATION) return;
        mRound[classId] += 1;
        mShares[classId] = mPool[classId];
        ghostRoundAdvances++;
    }

    /// @dev Independent aggregate mirror of CuratorModule's lazy power-of-two share rebase. The
    ///      W7 model predated W2's share-scale implementation and otherwise retains the stale raw
    ///      scalar after production normalizes it at the next post.
    function _modelNormalizePoolShares(uint256 classId) internal {
        uint256 balance = mPool[classId];
        uint256 shares = mShares[classId];
        if (balance == 0 || shares == 0) return;
        uint256 ratio = shares / balance;
        if (ratio < 2) return;
        uint256 shift = Math.log2(ratio);
        if (shift == 0) return;
        mShares[classId] = Math.ceilDiv(shares, uint256(1) << shift);
    }

    function _withdrawFirstLossAs(address who, uint256 classId, uint256 amount) internal {
        uint256 creditBefore = _creditedLayerOne(classId);
        vm.prank(who);
        curator.withdrawFirstLoss(classId, amount);

        uint256 burned = Math.mulDiv(amount, mShares[classId], mPool[classId], Math.Rounding.Ceil);
        mShares[classId] -= burned;
        mPool[classId] -= amount;
        ghostCuratorWithdrawals++;
        ghostCuratorWithdrawn += amount;

        // INV-7 enforced AT the withdrawal, not merely between calls: a completed withdrawal must
        // never leave the pool below its subordination requirement.
        uint256 required = _modelRequired(classId);
        if (mPool[classId] < required) ghostWithdrawBreaches++;
        assertGe(mPool[classId], required, "INV-7: a withdrawal left the pool below the subordination requirement");
        // AUDIT FIX (SWEEP-2 CSG-F1) — THE FOURTH INV-7 GHOST. The level check above is a bound on
        // the POOL; this is a bound on the CREDIT, and they are not the same statement. No
        // withdrawal may reduce `min(declared + pastDue, poolBalance)` — the exact quantity the
        // conservative senior NAV counts as cascade layer 1. That is the property the measured HIGH
        // broke while every level check stayed green.
        if (_creditedLayerOne(classId) < creditBefore) ghostCreditReductions++;
        _observeHeadroomRegime(classId);
    }

    /// @dev NEGATIVE probe. The R4-EC2 freeze must refuse the withdrawal outright. Run through
    ///      try/catch rather than `vm.expectRevert` so `fail_on_revert = true` sees a clean
    ///      handler call either way, and so ACCEPTANCE is recorded as a counter the invariant can
    ///      assert on instead of being silently swallowed.
    function _probeFrozenWithdraw(address who, uint256 classId, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(who);
        try curator.withdrawFirstLoss(classId, amount) {
            ghostFrozenWithdrawAccepted++;
            // keep the model faithful to reality even in the violating branch, so the failure
            // surfaces as the dedicated counter rather than as model-drift noise
            uint256 burned = Math.mulDiv(amount, mShares[classId], mPool[classId], Math.Rounding.Ceil);
            mShares[classId] -= burned;
            mPool[classId] -= amount;
        } catch {
            ghostFrozenWithdrawRejections++;
        }
    }

    /// @dev AUDIT R6-CF1 NEGATIVE probe, the custody twin of `_probeFrozenWithdraw`. Run through
    ///      try/catch rather than `vm.expectRevert` so `fail_on_revert = true` sees a clean handler
    ///      call either way, and so ACCEPTANCE becomes a counter the invariant asserts on instead
    ///      of being silently swallowed.
    ///
    ///      THE SELECTOR CHECK IS THE ANTI-VACUITY GUARANTEE. Counting any revert would let a probe
    ///      that never reached the guard — no stake, no headroom, a class-level R4-EC2 freeze —
    ///      satisfy the `afterInvariant` floor and report the custody guard as exercised when it
    ///      was not. Only `Curator_CustodyLossFrozen` counts.
    function _probeCustodyFrozenWithdraw(address who, uint256 classId, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(who);
        try curator.withdrawFirstLoss(classId, amount) {
            ghostCustodyFrozenWithdrawAccepted++;
            // Keep the model faithful to reality even in the violating branch, so the failure
            // surfaces as the dedicated counter rather than as model-drift noise. Guarded because
            // this probe deliberately runs without a stake precondition: a zero pool would make
            // the mulDiv panic and bury the finding under an arithmetic error.
            if (mPool[classId] != 0 && amount <= mPool[classId]) {
                uint256 burned = Math.mulDiv(amount, mShares[classId], mPool[classId], Math.Rounding.Ceil);
                mShares[classId] -= burned;
                mPool[classId] -= amount;
            }
        } catch (bytes memory reason) {
            if (reason.length >= 4 && bytes4(reason) == ICuratorModule.Curator_CustodyLossFrozen.selector) {
                ghostCustodyFrozenWithdrawRejections++;
            }
        }
    }

    function _closeCustodyIncident() internal {
        uint256 id = custodyIncidentId;
        (uint256 armId, uint256 derivedIncidentId,,) = reserves.reserveLossArm();
        assertEq(derivedIncidentId, id, "the active arm no longer names the modeled custody incident");
        vm.prank(admin);
        reserves.finalizeAndDisable(armId, keccak256(abi.encode("cascade-invariant-finalize", armId)));
        // `finalizeAndDisable` deliberately consumes the one-shot enablement. Re-enable only after
        // the prior incident is fully closed so the campaign can exercise both frozen and free
        // regimes, and any later incident receives a fresh arm-derived upper-namespace id.
        vm.prank(admin);
        reserves.setGuardianReserveLossArmsEnabled(true);
        mCustodyIncidentOpen = false;
        custodyIncidentId = 0;
        ghostCustodyIncidentCloses++;
    }

    function _fundCoverageWith(uint256 amount) internal {
        _mintUSDfr(coverageFunder, amount);
        vm.startPrank(coverageFunder);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
        mCoverageReserve += amount;
    }

    function _setFirstLossTarget(uint256 classId, uint256 target) internal {
        vm.prank(admin);
        curator.setFirstLossTarget(classId, target);
        mTarget[classId] = target;
        ghostTargetChanges++;
        _observeHeadroomRegime(classId);
    }

    function _originateAndFund(uint256 classId, uint256 principal) internal returns (uint256 id) {
        // seed the idle reserve with exactly the stables this deployment consumes
        _mintUSDfr(senior, principal);

        uint256 nextId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory t = _terms(classId, principal);
        bytes32 termsHash = bridge.creditTermsHash(t);
        oracle.setPayload(
            nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, uint64(block.timestamp), true
        );
        oracle.setPayload(nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash, uint64(block.timestamp), true);
        oracle.setPayload(
            nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, uint64(block.timestamp), true
        );

        vm.prank(originator);
        id = bridge.originate(custodian, t);
        vm.prank(servicer);
        waterfall.fund(id, principal / UNIT);

        facIds.push(id);
        allFacIds.push(id);
        facClass[id] = classId;
        mExposure[classId] += principal;
        mTotalExposure += principal;
        // ADR-0019: the fee's stables never leave the treasury; it is capitalized into deployed
        // principal and minted to the fee recipient. Modeled from `Config`, not from the engine.
        ghostOriginationFees += Math.mulDiv(principal / UNIT, M_ORIGINATION_FEE_BPS, Config.BPS) * UNIT;
        ghostExposureIncreases++;
        _observeHeadroomRegime(classId);
    }

    /// @dev AUDIT FIX (ADV-1). The model's OWN computation of the senior-impairment fee ceiling
    ///      from the credit-layer stock. Deliberately NOT a call into `WaterfallEngine`: an
    ///      expectation model that asked the contract what it intended to do would assert nothing.
    ///      `pendingSeniorImpairment()` is a cumulative STOCK and is used ONLY as a CEILING on the
    ///      per-transaction fee FLOW — never subtracted from the flow's basis. See
    ///      `WaterfallEngine._withholdFeeForSeniorImpairment`.
    /// @param feeGross The gross protocol fee this model expects on the receipt.
    /// @return The part of `feeGross` the spec says must be withheld and never minted.
    function _seniorImpairmentCeiling(uint256 feeGross) internal view returns (uint256) {
        uint256 residual = defaultManager.pendingSeniorImpairment();
        return feeGross < residual ? feeGross : residual;
    }

    struct DistributionCheck {
        uint256 expFee;
        uint256 expToVault;
        uint256 expWithheld;
        uint256 feeBefore;
        uint256 vaultBefore;
        uint256 curatorBefore;
        uint64 nextDue;
        uint256 usdcAmount;
        bytes32 paymentId;
    }

    /// @dev INV-6, per call and INDEPENDENTLY: the split is computed from the interest THIS
    ///      handler passed in and its OWN modeled fee rate, then compared against MEASURED
    ///      balance deltas. `WaterfallEngine.protocolFeeBps()` is never read.
    function _distribute(uint256 id, uint256 interest, uint256 principal, uint256 outstanding) internal {
        DistributionCheck memory d;
        d.expFee = Math.mulDiv(interest, M_PROTOCOL_FEE_BPS, Config.BPS);
        d.expToVault = interest - d.expFee;
        // AUDIT FIX (ADV-1). Forest Road may not take a performance fee out of a senior shortfall
        // that junior capital has already declined to absorb. THE MODEL IS EXTENDED, NOT RELAXED:
        // the ceiling is computed here, from this handler's OWN read of the credit-layer stock
        // taken BEFORE the call (which is where the contract reads it — the interest leg precedes
        // `distribute`'s lifecycle hooks), and the assertions below remain EXACT equalities.
        // `M_PROTOCOL_FEE_BPS` still comes from `Config`, never from the engine.
        //
        // `expToVault` is deliberately left on the GROSS fee: the withheld amount is NEVER MINTED,
        // not redirected, so the senior leg is unchanged. Asserting that unchanged leg is what
        // catches a reordering inside `WaterfallEngine._routeInterest`.
        d.expWithheld = _seniorImpairmentCeiling(d.expFee);
        d.expFee -= d.expWithheld;
        d.usdcAmount = (interest + principal) / UNIT;
        d.nextDue = _nextDueFor(id, principal, outstanding);
        // MERGE NOTE (2026-08-07) — AUDIT FIX C4-01, SECOND SITE. `++paymentEventNonce` is
        // LOAD-BEARING; do not remove it and do not fall back to the timestamp alone.
        //
        // This preimage used to be (facility, interest, principal, block.timestamp). Two repays of
        // the SAME size on the SAME facility inside ONE block therefore produced the IDENTICAL
        // `paymentId`, hence the identical `PaymentReceived` payload, hence — under the C4-01
        // fact-level consume-once ledger — the SAME ATTESTED FACT TWICE. The second one is
        // correctly refused with `Oracle_FactAlreadyRealised(key, Consumed)`, which under
        // `fail_on_revert = true` reds the whole campaign.
        //
        // It is a SEED-DEPENDENT flake, not a deterministic red: it needs two same-block, same-size
        // repays on one facility in the drawn sequence. It was observed once in ~3 full-suite runs
        // of this tree (`invariant_INV7_noWithdrawalEverBreachedSubordination`, runs: 85, shrunk to
        // 6 calls ending in two back-to-back `repay`s). It is NOT introduced by the merge — the
        // same latent collision exists in FIX2-ORACLE alone, which patched only the `realizeLoss`
        // evidence hash and left this site on the old preimage.
        //
        // The repair is ORACLE's own, applied to the second site: an on-chain payment id
        // identifies a real-world PAYMENT EVENT, so two distinct payments must carry distinct ids.
        // A monotone per-event nonce makes the handler model distinct events instead of
        // re-presenting one fact, which is what production requires. Nothing about the waterfall
        // assertions below changes; only the identity the handler signs over.
        d.paymentId = keccak256(
            abi.encode("audit-cascade-payment", id, interest, principal, block.timestamp, ++paymentEventNonce)
        );

        usdc.mint(borrower, d.usdcAmount);
        vm.prank(borrower);
        usdc.approve(address(reserves), d.usdcAmount);

        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(
                abi.encode(d.paymentId, id, address(usdc), borrower, d.usdcAmount, interest, principal, d.nextDue)
            ),
            uint64(block.timestamp),
            true
        );

        d.feeBefore = usdfr.balanceOf(feeRecipient);
        d.vaultBefore = usdfr.balanceOf(address(vault));
        d.curatorBefore = usdfr.balanceOf(address(curator));

        IWaterfallEngine.Payment memory p = IWaterfallEngine.Payment({
            tokenId: id,
            paymentId: d.paymentId,
            payer: borrower,
            interest: interest,
            principal: principal,
            nextPaymentDue: d.nextDue
        });
        vm.prank(servicer);
        waterfall.distribute(p);

        assertEq(usdfr.balanceOf(feeRecipient) - d.feeBefore, d.expFee, "INV-6: protocol fee leg not exact");
        assertEq(usdfr.balanceOf(address(vault)) - d.vaultBefore, d.expToVault, "INV-6: senior interest leg not exact");
        // INV-6, the subordination half: curator capital is NEVER paid from repayments.
        if (usdfr.balanceOf(address(curator)) != d.curatorBefore) ghostCuratorPaidFromRepayment++;
        assertEq(
            usdfr.balanceOf(address(curator)), d.curatorBefore, "INV-6: a repayment moved value into curator capital"
        );

        ghostInterestPaid += interest;
        ghostFeeToRecipient += d.expFee;
        ghostYieldToVault += d.expToVault;
        // AUDIT FIX (ADV-1): the third leg of INV-6's interest-split identity. See
        // `ProductionCascadeInvariants::invariant_INV6_interestSplitsIntoFeeAndSeniorExactly`.
        ghostFeeWithheldForImpairment += d.expWithheld;
        ghostDistributions++;
        if (principal != 0) {
            uint256 classId = facClass[id];
            mExposure[classId] -= principal;
            mTotalExposure -= principal;
            ghostPrincipalRepaid += principal;
            ghostExposureDecreases++;
            _observeHeadroomRegime(classId);
        }
        if (principal == outstanding) _retire(id);
    }

    /// @dev The adversarial ordering itself: pull the maximum legal first-loss out of the class,
    ///      then declare the default in the very next instruction. The caller has already
    ///      established that the class is not frozen.
    function _raceWithdrawThenDefault(uint256 id) internal {
        uint256 classId = facClass[id];
        uint256 free = _modelHeadroom(classId);
        uint256 postedA = curator.postedOf(classId, curatorA);
        uint256 pull = postedA < free ? postedA : free;
        if (pull != 0) {
            _withdrawFirstLossAs(curatorA, classId, pull);
            ghostRaceValuePulled += pull;
        }
        _declareDefault(id);
        ghostRaceAttempts++;
    }

    function _declareDefault(uint256 id) internal {
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(id, bytes32(0))),
            uint64(block.timestamp),
            true
        );
        vm.prank(servicer);
        defaultManager.declareDefault(id, bytes32(0));
        mFrozen[facClass[id]] += 1;
        ghostDefaultsDeclared++;
    }

    struct CascadeModel {
        uint256 classId;
        uint256 poolBefore; // MODEL
        uint256 reserveBefore; // MODEL
        uint256 roomBefore; // MODEL
        uint256 expAbsorbed;
        uint256 residual;
        uint256 expCovered;
        uint256 expDepositor;
        uint256 capSnapshot;
        bool capBound;
        bool capSlack;
        uint256 curatorUsdfrBefore;
        uint256 sGroveUsdfrBefore;
        uint256 vaultUsdfrBefore;
        uint256 supplyBefore;
    }

    struct CustodyModel {
        uint256 incidentId;
        /// @dev AUDIT FIX (ADV-1). The standing over-collateralisation buffer at entry — cash in
        ///      the reserve with no USDfr minted against it, produced by the senior-impairment fee
        ///      withholding. `ReserveManager` absorbs it BEFORE curator first-loss, so the handler
        ///      grosses the write-down up by exactly this amount to keep the modeled cascade split
        ///      on `loss`. See `_reserveCustodyLossChecked`.
        uint256 expSurplus;
        uint256 poolTotal;
        uint256 expCurator;
        uint256 reserveBefore;
        uint256 capSnapshot;
        uint256 roomBefore;
        uint256 expCovered;
        uint256 expSenior;
        uint256 curatorUsdfrBefore;
        uint256 sGroveUsdfrBefore;
        uint256 vaultUsdfrBefore;
        uint256 supplyBefore;
        uint256 idleBefore;
        uint256 liveConsumedBefore;
        uint256 capacityFloorBefore;
        bool capBound;
        bool capSlack;
        uint256[] poolBefore;
        uint256[] poolAbsorptions;
        uint256[] facilityConsumedBefore;
        uint256[] drawnPrincipalBefore;
    }

    /// @dev INV-5, per call. The expected split is computed ENTIRELY from model state — model
    ///      pool, shared reserve and per-event draw observability — and then compared against
    ///      MEASURED token movements. No contract view participates in the prediction.
    function _realizeLossChecked(uint256 id, uint256 loss) internal {
        CascadeModel memory m;
        m.classId = facClass[id];
        m.poolBefore = mPool[m.classId];
        m.reserveBefore = mCoverageReserve;

        // ── layer 1: curator first-loss ─────────────────────────────────
        m.expAbsorbed = loss < m.poolBefore ? loss : m.poolBefore;
        m.residual = loss - m.expAbsorbed;

        // ── layer 2: ADR-0035's one shared live reserve ──────────────────
        m.capSnapshot = mEventDrawn[id] + m.reserveBefore; // compatibility event-view word
        m.roomBefore = m.reserveBefore;
        if (m.residual != 0) {
            m.expCovered = m.residual < m.reserveBefore ? m.residual : m.reserveBefore;
            m.capSlack = m.reserveBefore >= m.residual;
            m.capBound = m.reserveBefore < m.residual;
        }
        // ── layer 3: senior principal ───────────────────────────────────
        m.expDepositor = m.residual - m.expCovered;

        m.curatorUsdfrBefore = usdfr.balanceOf(address(curator));
        m.sGroveUsdfrBefore = usdfr.balanceOf(address(sGrove));
        m.vaultUsdfrBefore = usdfr.balanceOf(address(vault));
        m.supplyBefore = usdfr.totalSupply();

        // AUDIT FIX (C4-01) — the evidence hash is now PER LOSS EVENT, not a constant.
        // This handler previously passed `bytes32(0)` as the evidence for EVERY realization, so two
        // equal-sized write-downs on one facility produced the IDENTICAL attested fact
        // (`keccak256(id, loss, evidence)`). Under the fact-level consume-once ledger that is one
        // fact, not two, and the second submission is correctly rejected — which is exactly the
        // production rule: an evidence hash identifies a real-world loss event, so distinct events
        // must carry distinct evidence. Modelling two distinct events with one evidence hash was
        // describing a scenario production now refuses. No cascade assertion below changes; only
        // the evidence the handler signs over.
        bytes32 evidence = keccak256(abi.encode("cascade-loss-event", id, ++lossEventNonce));
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(id, loss, evidence)),
            uint64(block.timestamp),
            true
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, loss, evidence);

        // ── measured versus modeled, layer by layer ─────────────────────
        assertEq(
            m.curatorUsdfrBefore - usdfr.balanceOf(address(curator)),
            m.expAbsorbed,
            "INV-5: layer 1 (curator first-loss) did not absorb the modeled amount"
        );
        assertEq(
            m.sGroveUsdfrBefore - usdfr.balanceOf(address(sGrove)),
            m.expCovered,
            "INV-5: layer 2 (sGROVE coverage) did not deliver the modeled amount"
        );
        assertEq(
            m.vaultUsdfrBefore - usdfr.balanceOf(address(vault)),
            m.expDepositor,
            "INV-5: layer 3 (senior principal) did not absorb the modeled amount"
        );
        assertEq(m.supplyBefore - usdfr.totalSupply(), loss, "INV-5: burns across the three layers != the loss");

        // ── ordering: never touch layer N+1 while layer N has capacity ──
        //
        // DELIBERATELY COMPUTED FROM MEASURED MOVEMENTS, NOT FROM THE MODEL'S OWN SPLIT. Stating
        // it as `expCovered != 0 && poolBefore > expAbsorbed` is a TAUTOLOGY: with
        // `expAbsorbed = min(loss, poolBefore)` those two conditions are `loss > poolBefore` and
        // `loss < poolBefore`, so the conjunction is unsatisfiable by construction and the
        // assertion can never fire whatever the contracts do. The version below pairs what the
        // CONTRACTS actually moved with the capacities the MODEL says were available, which is
        // falsifiable: a cascade that drew layer 2 while leaving curator capital behind produces
        // `actualAbsorbed < poolBefore` together with `actualCovered != 0`, and fails here.
        _assertOrdering(m);

        // ── model advance ───────────────────────────────────────────────
        mPool[m.classId] -= m.expAbsorbed;
        mEventDrawn[id] += m.expCovered;
        mCoverageReserve -= m.expCovered;
        mExposure[m.classId] -= loss;
        mTotalExposure -= loss;

        ghostLossEvents++;
        ghostLossRealized += loss;
        ghostAbsorbedL1 += m.expAbsorbed;
        ghostCoveredL2 += m.expCovered;
        ghostBurnedL3 += m.expDepositor;
        ghostExposureDecreases++;
        if (m.capBound) ghostCapBindingDraws++;
        if (m.capSlack) ghostCapSlackDraws++;
        if (mRound[m.classId] != 0) ghostLossesAfterRoundAdvance++;
        if (m.poolBefore != 0 && mPool[m.classId] == 0) {
            ghostPoolWipes++;
            if (m.capBound) ghostWipeWithBindingCap++;
        }
        _observeHeadroomRegime(m.classId);

        if (reserves.deployedTo(id) == 0) _retire(id);
    }

    /// @dev Custody-loss counterpart to `_realizeLossChecked`. Prediction uses only handler
    ///      model state. Contract reads are limited to precondition ceilings and measured deltas.
    function _reserveCustodyLossChecked(uint256 loss, bool throughReconcile) internal {
        CustodyModel memory m;
        m.incidentId = _ensureCustodyIncident();
        // AUDIT FIX (ADV-1) — THE BUFFER IS COMPENSATED FOR, NOT ASSERTED AWAY, AND THE ASSERTION
        // IS NOT WEAKENED. This line read
        // `assertEq(controller.totalUSDfr(), controller.backingValue(), ...)`. Its MESSAGE says
        // "entered with a backing DEFICIT", but `assertEq` also rejects a SURPLUS, and after the
        // ADV-1 senior-impairment fee withholding a standing surplus is the normal state: a
        // withheld protocol fee is cash that landed in the reserve with no USDfr minted against
        // it, i.e. over-collateralisation.
        //
        // WHY IT CANNOT SIMPLY BECOME `assertLe`. `ReserveManager._allocateReserveLoss` computes
        // `requiredBurn = supplyBefore - (backingBefore - backingReduction)`, so a surplus `S` is
        // absorbed FIRST (the contract calls it `surplusAbsorbed`) and only `loss - S` ever
        // reaches curator first-loss. Every prediction below is written for `requiredBurn == loss`
        // and would silently mis-model the split — worse, a small seed loss inside a larger buffer
        // would reach NO cascade layer at all, and the whole custody family would go vacuous while
        // staying green.
        //
        // SO THE HANDLER GROSSES THE WRITE-DOWN UP BY THE BUFFER. The scenario the model means to
        // construct — a custody loss of exactly `loss` charged through the real three-layer
        // cascade — is the scenario that is constructed, and the surplus leg is asserted
        // explicitly below rather than being allowed to absorb silently.
        m.supplyBefore = controller.totalUSDfr();
        uint256 backingAtEntry = controller.backingValue();
        assertLe(m.supplyBefore, backingAtEntry, "custody seed entered with a backing deficit");
        m.expSurplus = backingAtEntry - m.supplyBefore;
        // The buffer carries sub-USDC DUST: a withheld protocol fee is `interest * bps / BPS`, which
        // need not be a whole USDC unit. The reconcile leg can only move whole units, so the ISSUED
        // write-down must be UNIT-aligned. `loss` is UNIT-aligned on entry (`_align`) and
        // `loss >= UNIT > dust`, so shaving the dust off the MODELED cascade loss makes
        // `loss + surplus` exactly aligned while keeping every prediction below exact. Shaving the
        // SURPLUS instead would leave the dust standing after the write-down and put the modeled
        // burn `dust` below the real one.
        uint256 surplusDust = m.expSurplus % UNIT;
        loss -= surplusDust;
        assertEq(reserves.reserveDeficit(), 0, "custody seed entered with a latched reserve deficit");

        m.poolBefore = new uint256[](Config.NUM_CLASSES);
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            m.poolBefore[i] = mPool[i + 1];
            m.poolTotal += m.poolBefore[i];
        }
        m.expCurator = loss < m.poolTotal ? loss : m.poolTotal;
        m.poolAbsorptions = _modelCustodyPoolAbsorptions(m.poolBefore, m.poolTotal, m.expCurator);

        uint256 residual = loss - m.expCurator;
        m.reserveBefore = mCoverageReserve;
        m.capSnapshot = mEventDrawn[m.incidentId] + m.reserveBefore;
        m.roomBefore = m.reserveBefore;
        if (residual != 0) {
            m.expCovered = residual < m.reserveBefore ? residual : m.reserveBefore;
            m.capSlack = m.reserveBefore >= residual;
            m.capBound = m.reserveBefore < residual;
        }
        m.expSenior = residual - m.expCovered;
        assertLe(m.expSenior, vault.totalAssets(), "custody loss exceeds vested senior capacity");

        m.curatorUsdfrBefore = usdfr.balanceOf(address(curator));
        m.sGroveUsdfrBefore = usdfr.balanceOf(address(sGrove));
        m.vaultUsdfrBefore = usdfr.balanceOf(address(vault));
        m.supplyBefore = usdfr.totalSupply();
        m.idleBefore = reserves.idleReserve();
        m.liveConsumedBefore = defaultManager.liveDefaultCoverageConsumed();
        m.capacityFloorBefore = defaultManager.liveDefaultCoverageRemaining();
        m.facilityConsumedBefore = new uint256[](allFacIds.length);
        for (uint256 i = 0; i < allFacIds.length; ++i) {
            m.facilityConsumedBefore[i] = defaultManager.coverageConsumedByDefault(allFacIds[i]);
        }
        m.drawnPrincipalBefore = new uint256[](Config.NUM_CLASSES);
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            m.drawnPrincipalBefore[i] = defaultManager.drawnDefaultPrincipal(i + 1);
        }

        // AUDIT FIX (ADV-1): the ISSUED write-down is `loss + surplus`; the CASCADE still sees
        // exactly `loss`, because the buffer is consumed first by `_allocateReserveLoss`.
        uint256 issuedLoss = loss + m.expSurplus;
        // The reconcile leg issues the write-down in whole USDC units, so a buffer that is not
        // USDC-aligned could not be issued exactly and every equality below would be off by the
        // remainder. Fail LOUDLY here rather than mis-model it (CLAUDE.md prime directive 4).
        assertEq(issuedLoss % UNIT, 0, "ADV-1: the standing over-collateralisation buffer is not USDC-aligned");
        _executeCustodyReserveLoss(throughReconcile, issuedLoss, m.incidentId);

        uint256 actualCurator = m.curatorUsdfrBefore - usdfr.balanceOf(address(curator));
        uint256 actualCovered = m.sGroveUsdfrBefore - usdfr.balanceOf(address(sGrove));
        uint256 actualSenior = m.vaultUsdfrBefore - usdfr.balanceOf(address(vault));
        assertEq(actualCurator, m.expCurator, "INV-5: custody layer 1 != pool-balance model");
        assertEq(actualCovered, m.expCovered, "INV-5: custody layer 2 != incident-cap model");
        assertEq(actualSenior, m.expSenior, "INV-5: custody layer 3 != residual model");
        assertEq(m.supplyBefore - usdfr.totalSupply(), loss, "INV-5: custody cascade burns != reserve loss");
        assertEq(m.idleBefore - reserves.idleReserve(), issuedLoss, "custody write-down did not reduce backing exactly");
        // AUDIT FIX (ADV-1). THE SURPLUS LEG, ASSERTED RATHER THAN ALLOWED TO ABSORB SILENTLY.
        // Over-collateralisation stands AHEAD of curator first-loss, so the buffer must be exactly
        // consumed and the book must come out square. Without this the gross-up above would be an
        // unchecked fudge factor; with it, a contract that failed to spend the buffer first (or
        // spent junior capital while it stood) breaks this line AND the layer asserts above.
        assertEq(
            controller.backingValue(),
            controller.totalUSDfr(),
            "ADV-1: the over-collateralisation buffer was not absorbed ahead of curator first-loss"
        );
        assertEq(reserves.reserveDeficit(), 0, "fully absorbable custody loss latched a deficit");

        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 classId = i + 1;
            assertEq(
                m.poolBefore[i] - curator.poolBalance(classId),
                m.poolAbsorptions[i],
                "INV-5: custody curator class allocation != model"
            );
            mPool[classId] -= m.poolAbsorptions[i];
            if (m.poolBefore[i] != 0 && mPool[classId] == 0) ghostPoolWipes++;
            _observeHeadroomRegime(classId);
        }

        // Custody SGrove draws share the coverage mechanism but never the facility-default
        // impairment mappings. This is the explicit side-door regression for F-18-01.
        for (uint256 i = 0; i < allFacIds.length; ++i) {
            assertEq(
                defaultManager.coverageConsumedByDefault(allFacIds[i]),
                m.facilityConsumedBefore[i],
                "custody loss mutated facility coverage consumption"
            );
        }
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            assertEq(
                defaultManager.drawnDefaultPrincipal(i + 1),
                m.drawnPrincipalBefore[i],
                "custody loss mutated drawn default principal"
            );
        }
        assertEq(
            defaultManager.liveDefaultCoverageConsumed(),
            m.liveConsumedBefore,
            "custody loss mutated live default coverage consumption"
        );
        assertEq(
            defaultManager.liveDefaultCoverageRemaining(),
            m.capacityFloorBefore,
            "custody loss mutated the live default reachable-coverage ledger"
        );
        assertEq(defaultManager.coverageConsumedByDefault(m.incidentId), 0, "custody id entered facility accounting");

        _assertCustodyOrdering(m, actualCurator, actualCovered, actualSenior);

        mEventDrawn[m.incidentId] += m.expCovered;
        mCoverageReserve -= m.expCovered;
        ghostLossEvents++;
        ghostReserveLossEvents++;
        ghostCustodyF18IsolationChecks++;
        ghostLossRealized += loss;
        ghostAbsorbedL1 += m.expCurator;
        ghostCoveredL2 += m.expCovered;
        ghostBurnedL3 += m.expSenior;
        if (m.capBound) ghostCapBindingDraws++;
        if (m.capSlack) ghostCapSlackDraws++;
    }

    /// @dev Port of W7's custody action onto the selected arm-bound ReserveManager path. The
    ///      permissionless reconcile limb observes only; the ratification call re-derives the
    ///      physical shortfall and is the single accounting/absorption door in both cases.
    function _executeCustodyReserveLoss(bool throughReconcile, uint256 issuedLoss, uint256 incidentId) private {
        (uint256 recorded, uint256 live,) = reserves.observeIdleUSDC();
        uint256 rawLoss = issuedLoss / UNIT;
        uint256 transferOut = live - recorded + rawLoss;
        vm.prank(address(reserves));
        usdc.transfer(borrower, transferOut);
        if (throughReconcile) {
            vm.prank(admin);
            uint256 observed = reserves.reconcileIdleUSDC();
            assertEq(observed, rawLoss, "reconcile did not observe the modeled shortfall");
            assertEq(reserves.idleUSDC(), recorded, "observation changed reserve accounting");
            ghostReserveReconcileEvents++;
        } else {
            ghostReserveWriteDownEvents++;
        }
        (uint256 armId, uint256 expectedIncidentId, bytes32 evidenceHash,) = reserves.reserveLossArm();
        assertEq(expectedIncidentId, incidentId, "custody incident is not arm-bound");
        vm.prank(admin);
        (uint256 ratifiedIncidentId, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidenceHash, issuedLoss);
        assertEq(ratifiedIncidentId, incidentId, "ratification changed custody incident id");
        assertEq(actualLoss, issuedLoss, "ratification did not absorb the exact live shortfall");
    }

    function _assertCustodyOrdering(
        CustodyModel memory m,
        uint256 actualCurator,
        uint256 actualCovered,
        uint256 actualSenior
    ) private {
        uint256 l1Left = m.poolTotal > actualCurator ? m.poolTotal - actualCurator : 0;
        uint256 roomLeft = m.roomBefore > actualCovered ? m.roomBefore - actualCovered : 0;
        uint256 reserveLeft = m.reserveBefore > actualCovered ? m.reserveBefore - actualCovered : 0;
        uint256 l2Left = roomLeft < reserveLeft ? roomLeft : reserveLeft;
        if (actualCovered != 0 && l1Left != 0) ghostL2DrewWithL1Capacity++;
        assertFalse(actualCovered != 0 && l1Left != 0, "INV-5: custody layer 2 skipped curator capital");
        if (actualSenior != 0) {
            if (l1Left != 0 || l2Left != 0) ghostL3BurnedWithJuniorCapacity++;
            assertFalse(l1Left != 0 || l2Left != 0, "INV-5: custody senior burn skipped junior capital");
        }
    }

    function _modelCustodyPoolAbsorptions(uint256[] memory balances, uint256 totalPoolBalance, uint256 target)
        private
        pure
        returns (uint256[] memory shares)
    {
        shares = new uint256[](Config.NUM_CLASSES);
        if (target == 0) return shares;
        uint256 allocated;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            shares[i] = Math.mulDiv(target, balances[i], totalPoolBalance);
            allocated += shares[i];
        }
        uint256 dust = target - allocated;
        for (uint256 i = 0; i < Config.NUM_CLASSES && dust != 0; ++i) {
            uint256 headroom = balances[i] - shares[i];
            if (headroom == 0) continue;
            uint256 add = dust < headroom ? dust : headroom;
            shares[i] += add;
            dust -= add;
        }
        assertEq(dust, 0, "custody model failed to allocate rounding dust");
    }

    /// @dev Arms a custody incident when none is open and returns its derived event id. Partial
    ///      losses reuse the same arm; after explicit finalization, the next arm supplies a fresh
    ///      upper-namespace event id.
    function _ensureCustodyIncident() private returns (uint256 incidentId) {
        incidentId = custodyIncidentId;
        if (incidentId != 0) return incidentId;
        vm.prank(guardian);
        (uint256 armId, uint256 derivedIncidentId) =
            reserves.armReserveLossFreeze(keccak256("production-cascade-invariant-custody-arm"));
        custodyIncidentNonce = armId;
        incidentId = derivedIncidentId;
        custodyIncidentId = incidentId;
        custodyIncidentIds.push(incidentId);
        mCustodyIncidentOpen = true;
        assertGt(incidentId, type(uint256).max / 2, "custody event id is not in the upper namespace");
    }

    /// @dev INV-5's ordering claim, stated over MEASURED layer movements against MODEL capacities.
    ///      Split out of `_realizeLossChecked` purely for stack depth under the as-deployed
    ///      optimizer settings.
    /// @param m The pre-call model snapshot for this loss event.
    function _assertOrdering(CascadeModel memory m) private {
        uint256 actualAbsorbed = m.curatorUsdfrBefore - usdfr.balanceOf(address(curator));
        uint256 actualCovered = m.sGroveUsdfrBefore - usdfr.balanceOf(address(sGrove));
        uint256 actualSenior = m.vaultUsdfrBefore - usdfr.balanceOf(address(vault));

        // Layer 1 capacity the cascade LEFT BEHIND, measured.
        uint256 l1Left = m.poolBefore > actualAbsorbed ? m.poolBefore - actualAbsorbed : 0;
        // ADR-0035: the only layer-2 capacity left is the physical shared reserve.
        uint256 l2Left = m.reserveBefore > actualCovered ? m.reserveBefore - actualCovered : 0;

        if (actualCovered != 0 && l1Left != 0) ghostL2DrewWithL1Capacity++;
        assertFalse(
            actualCovered != 0 && l1Left != 0, "INV-5: layer 2 drew while layer 1 still had first-loss capacity"
        );
        if (actualSenior != 0) {
            if (l1Left != 0 || l2Left != 0) ghostL3BurnedWithJuniorCapacity++;
            assertFalse(
                l1Left != 0 || l2Left != 0,
                "INV-5: layer 3 burned senior principal while a junior layer still had capacity"
            );
        }
        assertLe(actualCovered, m.reserveBefore, "INV-5: layer 2 drew past the physical reserve");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  MODEL VIEWS (used by the invariant contract; contract-free by design)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). Exactly the layer-1 credit
    ///      `ConservativeImpairmentMath.pendingSeniorImpairment` extends for this class:
    ///      `min(declaredDefaulted + pastDue, poolBalance)`. Mirroring the NAV's own clamp is the
    ///      point — see `CuratorModule._markedFirstLoss`.
    function _creditedLayerOne(uint256 classId) internal view returns (uint256) {
        uint256 d = _markedCredit(classId);
        uint256 pool = curator.poolBalance(classId);
        return d < pool ? d : pool;
    }

    /// @notice AUDIT FIX (SWEEP-2 CSG-F1). Published so the invariant contract can assert on it.
    function creditedLayerOne(uint256 classId) external view returns (uint256) {
        return _creditedLayerOne(classId);
    }

    /// @notice `max(min(firstLossTarget, classExposure), declaredDefaulted + pastDue)`.
    function modelRequiredFirstLoss(uint256 classId) external view returns (uint256) {
        return _modelRequired(classId);
    }

    /// @notice `poolBalance - min(firstLossTarget, classExposure)` from MODEL state only.
    function modelHeadroom(uint256 classId) external view returns (uint256) {
        return _modelHeadroom(classId);
    }

    /// @notice Sum of the modeled curator pools — what the module's USDfr balance must equal.
    function modelCuratorTotal() external view returns (uint256 total) {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            total += mPool[c];
        }
    }

    function facilityCount() external view returns (uint256) {
        return facIds.length;
    }

    function facilityAt(uint256 i) external view returns (uint256) {
        return facIds[i];
    }

    /// @notice Every facility ever originated, including resolved ones (their per-event coverage
    ///         ledger persists in `SGrove`, so it must stay checkable).
    function allFacilityCount() external view returns (uint256) {
        return allFacIds.length;
    }

    function allFacilityAt(uint256 i) external view returns (uint256) {
        return allFacIds[i];
    }

    /// @notice AUDIT R6-CF1. MODEL view of the custody freeze — handler state only, never read
    ///         back from the contracts. `invariant_INV5_custodyFreezeMatchesIndependentModel`
    ///         makes the contract's agreement with it a property in its own right.
    function mCustodyFrozen() public view returns (bool) {
        return mCustodyIncidentOpen;
    }

    /// @notice Every custody incident ever opened. Their per-event coverage ledgers persist in
    ///         SGrove after closing, so they stay checkable for the whole campaign.
    function custodyIncidentCount() external view returns (uint256) {
        return custodyIncidentIds.length;
    }

    function custodyIncidentAt(uint256 i) external view returns (uint256) {
        return custodyIncidentIds[i];
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────

    function _modelRequired(uint256 classId) internal view returns (uint256) {
        uint256 exposure = mExposure[classId];
        uint256 target = mTarget[classId];
        uint256 targetLeg = exposure < target ? exposure : target;
        // AUDIT FIX (SWEEP-2 CSG-F1) — THE MARKED FLOOR. LOAD-BEARING, DO NOT DELETE.
        // Until SWEEP-2 this function was `min(target, exposure)` alone and INV-7 asserted the
        // contract EQUALLED it — i.e. THE ORACLE WAS THE DEFECT. What may leave was
        // `poolBalance - min(target, exposure)`, while the conservative senior NAV credits layer 1
        // at `min(declaredDefaulted + pastDue, poolBalance)`; on any class whose exposure exceeds
        // its target the second is larger, so capital the senior redemption price was ALREADY
        // extending credit for was withdrawable, and this invariant certified that as correct.
        // MEASURED: a curator withdrew 800,000e18 of layer-1 capital and the senior redemption
        // price fell 1,000,000e18 -> 650,000e18, with `invariant_INV7_subordinationHeadroomHolds`
        // green throughout.
        uint256 marked = _markedCredit(classId);
        return marked > targetLeg ? marked : targetLeg;
    }

    /// @dev AUDIT FIX (SWEEP-2 CSG-F1). The layer-1 credit the conservative senior NAV is
    ///      extending for this class, read from `DefaultManager` — a DIFFERENT contract from the
    ///      one under test, and the same source `ConservativeImpairmentMath` reads. This is
    ///      deliberately NOT modelled from handler inputs: mirroring `declaredDefaultedPrincipal`'s
    ///      full lifecycle (declare, realize, recover, resolve, de-recognise on cash recovery)
    ///      inside the handler would be a second implementation of `_reduceDefaulted`, and a wrong
    ///      model here is a FALSE ORACLE — strictly worse than a cross-contract read. The
    ///      target/exposure leg above stays purely modelled, so the equality this feeds still
    ///      catches a silently loosened formula on the leg the model owns.
    function _markedCredit(uint256 classId) internal view returns (uint256) {
        return defaultManager.declaredDefaultedPrincipal(classId) + defaultManager.pastDuePrincipal(classId);
    }

    function _modelHeadroom(uint256 classId) internal view returns (uint256) {
        uint256 required = _modelRequired(classId);
        uint256 pool = mPool[classId];
        return pool > required ? pool - required : 0;
    }

    /// @dev Records which leg of `min(target, exposure)` is currently binding, so the INV-7
    ///      anti-vacuity floor can prove BOTH regimes were visited rather than only the launch
    ///      configuration (target 10,000,000e18, which no reachable exposure here approaches).
    function _observeHeadroomRegime(uint256 classId) internal {
        uint256 exposure = mExposure[classId];
        uint256 target = mTarget[classId];
        if (exposure == 0 && target == 0) return;
        if (target < exposure) ghostTargetBindingObs++;
        else if (exposure < target) ghostExposureBindingObs++;
    }

    /// @dev The largest loss this facility can take without `realizeLoss` reverting. Bounding is a
    ///      PRECONDITION, not a prediction: layers 1 and 2 come from the model, layer 3's ceiling
    ///      is the vault's own `totalAssets()` because that is literally the bound
    ///      `DefaultManager` enforces (`LossExceedsAbsorptionCapacity`), and `outstanding` is the
    ///      reserve's own record because that is what `recordPrincipalWritedown` checks.
    function _maxRealizableLoss(uint256 id) internal view returns (uint256) {
        uint256 outstanding = reserves.deployedTo(id);
        if (outstanding == 0) return 0;

        uint256 capacity = mPool[facClass[id]] + mCoverageReserve + vault.totalAssets();
        return outstanding < capacity ? outstanding : capacity;
    }

    /// @dev AUDIT FIX (ADV-1) — DO NOT "RESTORE" THE `!=` EQUALITY GATE. It read
    ///      `totalUSDfr() != backingValue()`, i.e. it refused to act unless the book was EXACTLY
    ///      square. That is no longer a reachable steady state: the ADV-1 senior-impairment fee
    ///      withholding leaves a standing OVER-COLLATERALISATION buffer (backing above supply),
    ///      so the equality gate silently returned 0 forever and this whole action became dead
    ///      code — a green campaign with the custody cascade never exercised, which is the exact
    ///      "an invariant that passes because its handler never reaches the region is worthless"
    ///      failure this suite exists to avoid. The REAL precondition is that there is no
    ///      DEFICIT, which is what the assertion inside `_reserveCustodyLossChecked` says in
    ///      words. `_reserveCustodyLossChecked` grosses the write-down up by the buffer, so the
    ///      buffer is subtracted from the headroom here.
    function _maxCustodyLoss() internal view returns (uint256) {
        uint256 supplyNow = controller.totalUSDfr();
        uint256 backingNow = controller.backingValue();
        if (supplyNow > backingNow || reserves.reserveDeficit() != 0) return 0;
        uint256 surplus = backingNow - supplyNow;
        uint256 id = custodyIncidentId;
        if (id == 0) return 0;
        uint256 totalPool;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            totalPool += mPool[c];
        }
        uint256 capacity = totalPool + mCoverageReserve + vault.totalAssets();
        uint256 idle = reserves.idleReserve();
        // The write-down actually issued is `loss + surplus`, so the idle reserve must hold both.
        idle = idle > surplus ? idle - surplus : 0;
        if (idle < capacity) capacity = idle;
        return _align(capacity);
    }

    function _mintUSDfr(address to, uint256 amount) internal {
        uint256 usdcAmount = amount / UNIT;
        if (usdcAmount == 0) return;
        usdc.mint(to, usdcAmount);
        vm.startPrank(to);
        usdc.approve(address(controller), usdcAmount);
        controller.mint(usdcAmount);
        vm.stopPrank();
    }

    function _align(uint256 amount) internal pure returns (uint256) {
        return (amount / UNIT) * UNIT;
    }

    function _terms(uint256 classId, uint256 principal) internal view returns (ClaimBridge.OriginationTerms memory t) {
        t = ClaimBridge.OriginationTerms({
            classId: classId,
            borrowerId: keccak256(abi.encode("audit-cascade-borrower", classId)),
            // P-45: tax-credit facilities must carry a state concentration key; the
            // non-tax classes intentionally remain outside that dimension.
            stateId: classId == Config.CLASS_FILM_TAX_CREDITS
                ? keccak256(abi.encode("audit-cascade-state", classId))
                : bytes32(0),
            principal: principal,
            ltvBps: 5_000,
            interestRateBps: 1_000,
            maturity: uint64(block.timestamp + 300 days),
            fundingRecipient: borrower,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("audit-cascade-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("audit-cascade-ref")
        });
    }

    function _nextDueFor(uint256 id, uint256 principal, uint256 outstanding) internal view returns (uint64) {
        ClaimBridge.Facility memory f = bridge.facility(id);
        if (principal == outstanding) return 0;
        uint64 next = f.nextPaymentDue + f.paymentInterval;
        return next > f.maturity ? f.maturity : next;
    }

    function _pickPerforming(uint256 seed) internal view returns (uint256) {
        uint256 n = facIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = facIds[(start + i) % n];
            ClaimBridge.LoanState s = bridge.facility(id).state;
            if (s == ClaimBridge.LoanState.Active || s == ClaimBridge.LoanState.Amortizing) return id;
        }
        return 0;
    }

    /// @dev Any facility `WaterfallEngine.distribute` will accept: performing (Active/Amortizing)
    ///      or in recovery (Defaulted/Accelerated). Outstanding must be non-zero so the principal
    ///      leg has room; the interest-only case is still reachable because `principal` is bounded
    ///      from zero.
    function _pickDistributable(uint256 seed) internal view returns (uint256) {
        uint256 n = facIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = facIds[(start + i) % n];
            ClaimBridge.LoanState s = bridge.facility(id).state;
            bool ok = s == ClaimBridge.LoanState.Active || s == ClaimBridge.LoanState.Amortizing
                || s == ClaimBridge.LoanState.Defaulted || s == ClaimBridge.LoanState.Accelerated;
            if (ok && reserves.deployedTo(id) != 0) return id;
        }
        return 0;
    }

    function _pickDefaulted(uint256 seed) internal view returns (uint256) {
        uint256 n = facIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = facIds[(start + i) % n];
            ClaimBridge.LoanState s = bridge.facility(id).state;
            if (s == ClaimBridge.LoanState.Defaulted || s == ClaimBridge.LoanState.Accelerated) {
                if (reserves.deployedTo(id) != 0) return id;
            }
        }
        return 0;
    }

    /// @dev Drops a closed-out facility from the working set. Its model exposure has already been
    ///      driven to zero by the repayment or write-down that closed it.
    function _retire(uint256 id) internal {
        uint256 n = facIds.length;
        for (uint256 i = 0; i < n; ++i) {
            if (facIds[i] == id) {
                facIds[i] = facIds[n - 1];
                facIds.pop();
                return;
            }
        }
    }
}
