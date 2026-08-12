// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {GuardProbe} from "./handlers/GuardProbe.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @title CreditGateAuthorisationHandler
/// @notice Bounded, revert-free handler for the audit's INV-15..INV-21 family: the credit
///         mint gate, concentration admission, attestation single-use, authorisation, and
///         liveness. Every prediction is made from state THIS CONTRACT owns, computed from
///         the inputs it passed in; nothing in the reference model is read back out of
///         `ClaimBridge`, `CollateralRegistry` or `AttestationOracle`.
/// @dev WHY THIS EXISTS ALONGSIDE `CollateralHandler`. The repo's collateral campaign runs
///      the mint gate against `MockAttestationOracle` with the concentration floor pinned
///      once in the handler constructor. This handler runs the SAME gate against the REAL
///      `AttestationOracle` (genuine EIP-712 m-of-n bundles, real digest consumption, real
///      valuation watermark) and moves every concentration limit through governance DURING
///      the campaign, so the binding regime is entered and left repeatedly rather than fixed
///      at construction. It then adds the three families no invariant suite in the repo
///      touches at all: authorisation (`grep -rn "hasRole" test/invariant/` returns nothing),
///      upgrade/mint authority under role granting, and permissionless-only liveness.
/// @dev CONTRACT WITH `fail_on_revert = true`: this handler never reverts. Calls that are
///      EXPECTED to fail are made with a low-level `call` and classified; calls that are
///      expected to succeed are guarded by preconditions and skipped when unmet. A property
///      violation is recorded in a bug bucket and asserted by the suite, never thrown here.
/// @dev Reserve-loss writes are delegated to the atomic loss-absorption family. The unauthorised
///      reserve-write probe remains here because access-control rejection is this family's scope.
contract CreditGateAuthorisationHandler is GuardProbe {
    // ── wiring ───────────────────────────────────────────────────────────

    struct Wiring {
        ClaimBridge bridge;
        CollateralRegistry registry;
        AttestationOracle oracle;
        MintRedeemController controller;
        ReserveManager reserves;
        SUSDfr vault;
        RedemptionQueue queue;
        WaterfallEngine waterfall;
        DefaultManager defaultManager;
        CuratorModule curator;
        USDfr usdfr;
        ComplianceRegistry compliance;
        MockERC20 usdc;
    }

    struct Actors {
        address admin; // plays the governance timelock: DEFAULT_ADMIN + UPGRADER everywhere
        address guardian;
        address complianceAdmin;
        address originator;
        address servicer;
        address custodian;
        address curatorAddr; // an approved curator (first-loss poster)
        address user; // KYC-allowed
        address outsider; // NOT KYC-allowed, holds no role: the unauthorised actor
        address borrower; // facility funding recipient
        address backstop;
        uint256 pk1;
        uint256 pk2;
    }

    Wiring internal w;
    Actors internal a;

    /// @dev Every role granted by `grantRoleFromAdmin` lands here and NOWHERE else, so a
    ///      granted CREDIT_ROLE can never accidentally authorise the INV-18 probe actor.
    address internal roleSink;
    /// @dev A deployed implementation used only as the argument to `upgradeToAndCall`
    ///      probes; the role check fires before it is ever read.
    address internal dummyImpl;

    /// @notice Thrown when the live fixture no longer matches the reference parameters this
    ///         model hard-codes. Aborting `setUp` is correct: a silently drifting model is
    ///         worse than no model.
    /// @param what 0 = global limits, 1..5 = class params, 6 = required-attestation mask,
    ///        7 = terms-commitment preimage, 8 = role topology.
    error ModelDrift(uint256 what);

    // ── reference constants (mirrors of CreditLayerFixture, pinned at construction) ──

    uint256 internal constant CLASS_FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant CLASS_DIGITAL = Config.CLASS_DIGITAL_ASSETS;

    uint256 internal constant BIT_ASSIGNMENT = 1 << uint256(IAttestationOracle.AttestationKind.AssignmentExecuted);
    uint256 internal constant BIT_UCC = 1 << uint256(IAttestationOracle.AttestationKind.UCCFiled);
    uint256 internal constant BIT_CREDIT = 1 << uint256(IAttestationOracle.AttestationKind.CreditIssued);
    uint256 internal constant BIT_VALUATION = 1 << uint256(IAttestationOracle.AttestationKind.Valuation);

    uint256 internal constant FILM_MASK = BIT_ASSIGNMENT | BIT_UCC | BIT_CREDIT;
    uint256 internal constant DIGITAL_MASK = BIT_ASSIGNMENT | BIT_VALUATION | BIT_CREDIT;

    uint16 internal constant FILM_MAX_LTV_BPS = 8_000;
    uint64 internal constant FILM_MAX_MATURITY = 730 days;
    uint16 internal constant DIGITAL_MAX_LTV_BPS = 5_000;
    uint64 internal constant DIGITAL_MAX_MATURITY = 365 days;
    uint64 internal constant DIGITAL_MAX_MARK_AGE = 1 days;

    uint16 internal constant FILM_LTV_BPS = 7_000;
    uint16 internal constant DIGITAL_LTV_BPS = 4_000;
    uint16 internal constant RATE_BPS = 1_200;
    uint64 internal constant PAYMENT_INTERVAL = 30 days;
    bytes32 internal constant SCHEDULE_HASH = keccak256("audit-inv-authz-schedule");
    bytes32 internal constant OFFCHAIN_REF = keccak256("audit-inv-authz-ucc-ref");

    uint256 internal constant MAX_SAFE_EXPOSURE = type(uint256).max / Config.BPS;

    /// @dev The bootstrap floor the seed leaves behind: small enough that the relative
    ///      limits genuinely bind on a test-scale book.
    uint256 internal constant SEED_FLOOR = 2_000_000e18;

    bytes32 internal constant B1 = keccak256("inv-authz-borrower-1");
    bytes32 internal constant B2 = keccak256("inv-authz-borrower-2");
    bytes32 internal constant B3 = keccak256("inv-authz-borrower-3");
    bytes32 internal constant S1 = keccak256("inv-authz-US-GA");
    bytes32 internal constant S2 = keccak256("inv-authz-US-NV");

    uint256 internal constant PROBE_COUNT = 29;

    /// @dev `PausableUpgradeable.EnforcedPause()`. Modelled explicitly rather than skipping
    ///      paused originations, so `tryOriginate` ALWAYS reaches the contract and the
    ///      anti-vacuity delta cannot be quietly starved by the pause action.
    bytes4 internal constant ENFORCED_PAUSE = 0xd93c0665;

    // ── the plan: what `tryOriginate` will present, decided BEFORE it is attested ──

    struct Plan {
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 principal;
        uint16 ltvBps;
        uint64 maturity;
        uint64 nextPaymentDue;
        bool planned;
    }

    mapping(uint256 facilityId => Plan) internal plans;

    /// @dev The handler's OWN record of whether it left the bridge paused. Used by the
    ///      admission model; never read back from `PausableUpgradeable.paused()`.
    bool public gBridgePaused;

    // ── independent ghost state: attestation ─────────────────────────────

    mapping(uint256 facilityId => uint256) public gMask; // kinds THIS handler made satisfied
    mapping(uint256 facilityId => bytes32) public gTerms; // standing CreditIssued payload
    /// @dev P-32 documentary payload mirrors. AssignmentExecuted and UCCFiled are
    /// deal-identity facts now, so the model must distinguish a satisfied bit whose
    /// payload belongs to another deal from a genuinely bound fact.
    mapping(uint256 facilityId => bytes32) public gAssignmentPayload;
    mapping(uint256 facilityId => bytes32) public gUccPayload;
    mapping(uint256 facilityId => uint256) public gMarkValue;
    mapping(uint256 facilityId => uint64) public gMarkAsOf;
    mapping(uint256 facilityId => uint64) public gWatermark;

    /// @dev Every bundle this handler successfully submitted, kept verbatim so the replay
    ///      action can resubmit it byte-for-byte. This is the INV-17 adversary.
    IAttestationOracle.AttestationInput[] internal accepted;
    mapping(bytes32 digest => bool) public gDigestUsed;
    bytes32[] internal acceptedDigests;

    uint256 internal nonceCounter;

    // ── independent ghost state: exposure and limits ─────────────────────

    mapping(uint256 classId => uint256) public mClassExp;
    mapping(bytes32 borrowerId => uint256) public mBorrowerExp;
    mapping(bytes32 stateId => uint256) public mStateExp;
    uint256 public mTotalExp;

    uint16 public mBorrowerLimitBps;
    uint16 public mStateLimitBps;
    mapping(uint256 classId => uint16) public mClassLimitBps;
    uint256 public mFloor;
    mapping(bytes32 borrowerId => uint16) internal mBorrowerOverrideBps;
    mapping(bytes32 borrowerId => bool) internal mBorrowerOverridden;

    // ── facility bookkeeping ─────────────────────────────────────────────

    enum FacState {
        None,
        Pending,
        Active,
        Defaulted,
        Cancelled
    }

    struct FacRec {
        uint256 classId;
        bytes32 borrowerId;
        bytes32 stateId;
        uint256 principal;
        FacState state;
        bool gateSatisfiedAtMint;
        bool termsBoundAtMint;
        bool limitsRespectedAtMint;
    }

    mapping(uint256 tokenId => FacRec) internal facs;
    uint256[] internal mintedIds;
    uint256[] internal defaultedIds;

    // ── AUDIT G11/G12.3: the §1.3 "escrow cannot release without the NFT" guards ──
    bytes32 internal constant G_ESCROW_NO_NFT = "escrow: token never minted";
    bytes32 internal constant G_ESCROW_ZERO_ID = "escrow: token id zero";
    bytes32 internal constant G_ESCROW_BURNED_NFT = "escrow: NFT burned (cancelled)";
    bytes32 internal constant G_ESCROW_NOT_PENDING = "escrow: facility not Pending";
    uint256 public escrowProbeAttempts;
    /// @notice Refused fundings that nevertheless moved stablecoins out of reserve custody.
    ///         Must always be zero — asserted by `invariant_INV15_escrowNeverReleasesWithoutTheNFT`.
    uint256 public escrowLeaks;

    // ── ghost counters: INV-15 / INV-16 admission model ──────────────────

    uint256 public ghostOriginateAttempts;
    uint256 public ghostOriginateSuccesses;
    uint256 public ghostRejectBadFacility;
    uint256 public ghostRejectGate;
    uint256 public ghostRejectTerms;
    uint256 public ghostRejectStaleMark;
    uint256 public ghostRejectLtvValue;
    uint256 public ghostRejectClassConc;
    uint256 public ghostRejectBorrowerConc;
    uint256 public ghostRejectStateConc;
    uint256 public ghostRejectPaused;
    /// @dev Attempts made while `mFloor <= mTotalExp`, i.e. while the bootstrap exemption is
    ///      inactive and the PLAIN relative concentration rule of INV-16 is what binds.
    uint256 public ghostAttemptsInBindingRegime;
    uint256 public ghostRejectionsInBindingRegime;

    // bug buckets (asserted zero by the suite)
    uint256 public ghostGateBypasses; // INV-15
    uint256 public ghostLimitBypasses; // INV-16
    uint256 public ghostUnexpectedRejections;
    uint256 public ghostWrongReason;
    bytes4 public ghostLastExpectedSelector;
    bytes4 public ghostLastActualSelector;

    // ── ghost counters: INV-17 attestation single use ────────────────────

    uint256 public ghostAttestAccepted;
    uint256 public ghostReplayAttempts;
    uint256 public ghostReplayRejected;
    uint256 public ghostReplayAccepted; // bug bucket
    uint256 public ghostStaleValuationAttempts;
    uint256 public ghostStaleValuationRejected;
    uint256 public ghostStaleValuationAccepted; // bug bucket
    bytes4 public ghostLastReplaySelector;
    bytes4 public ghostLastStaleSelector;

    // ── ghost counters: INV-18 authorisation ─────────────────────────────

    uint256 public ghostProbeAttempts;
    uint256 public ghostProbeRejectedByRole;
    uint256 public ghostProbeRejectedOther;
    uint256 public ghostProbeSuccesses; // bug bucket
    uint256 public ghostLastBypassProbe;
    bytes4 public ghostLastProbeOtherSelector;
    /// @dev Which of the 29 probes has been attempted at least once (bit i).
    uint256 public ghostProbeCoverage;
    // state-shape coverage, so "in any state" is a measured claim and not a slogan
    uint256 public ghostProbesWhilePaused;
    uint256 public ghostProbesWhileUnpaused;
    uint256 public ghostProbesWithLiveDefault;
    uint256 public ghostProbesWhileSettling;
    uint256 public ghostProbesWithQueuedRequests;
    uint256 public ghostProbesWithFundedVault;
    /// @dev Positive control: the AUTHORISED caller doing the same class of action. Without
    ///      this the probe assertions have no teeth (everything reverting for an unrelated
    ///      reason would read identical to access control working).
    uint256 public ghostAuthorisedControlSuccesses;
    uint256 public ghostAuthorisedControlFailures; // bug bucket

    // ── ghost counters: INV-19 / INV-20 role authority ───────────────────

    uint256 public ghostRoleGrants;
    uint256 public ghostUpgraderGrants;
    uint256 public ghostMinterGrants;
    uint256 public ghostRoleRevokes;

    // ── ghost counters: INV-21 liveness ──────────────────────────────────

    uint256 public ghostPermissionlessActions;
    uint256 public ghostLivenessProbes;
    uint256 public ghostMintProbedOk;
    uint256 public ghostMintBlocked; // bug bucket
    uint256 public ghostRedeemProbedOk;
    uint256 public ghostRedeemBlocked; // bug bucket
    uint256 public ghostSettleProbedOk;
    uint256 public ghostSettleBlocked; // bug bucket
    uint256 public ghostCascadeProbedOk;
    uint256 public ghostCascadeBlocked; // bug bucket
    uint256 public ghostCascadeNotApplicable;
    bytes4 public ghostLastMintBlockSelector;
    bytes4 public ghostLastRedeemBlockSelector;
    bytes4 public ghostLastSettleBlockSelector;
    bytes4 public ghostLastCascadeBlockSelector;

    // ── seed floor bookkeeping (separates the deterministic floor from fuzz reach) ──

    struct Floors {
        uint64 originateAttempts;
        uint64 originateSuccesses;
        uint64 gateRejects;
        uint64 termsRejects;
        uint64 concRejects;
        uint64 replays;
        uint64 probes;
        uint64 liveness;
        uint64 bindingAttempts;
        uint64 bindingRejects;
    }

    Floors internal floors;

    uint256 public callCount;
    /// @dev `callCount` immediately after `seedShapes`. See `campaignObserved`.
    uint256 public seedCallCount;

    // ── construction ─────────────────────────────────────────────────────

    constructor(Wiring memory wiring, Actors memory actors) {
        w = wiring;
        a = actors;
        roleSink = makeAddr("inv-authz-role-sink");
        dummyImpl = address(new ClaimBridge());
        mBorrowerLimitBps = 1_500;
        mStateLimitBps = 2_500;
        mClassLimitBps[CLASS_FILM] = 3_500;
        mClassLimitBps[CLASS_DIGITAL] = 2_000;
        mFloor = SEED_FLOOR;
        vm.prank(a.admin);
        w.registry.setConcentrationFloor(SEED_FLOOR);

        // AUDIT G11/G12.3 — register the §1.3 "escrow cannot release without the NFT" guards, so
        // `reachReport()` can show whether the campaign actually entered each of them.
        _registerGuard(
            G_ESCROW_NO_NFT, ClaimBridge.Bridge_UnknownToken.selector, "WaterfallEngine.fund: token never minted"
        );
        _registerGuard(
            G_ESCROW_ZERO_ID, ClaimBridge.Bridge_UnknownToken.selector, "WaterfallEngine.fund: token id zero"
        );
        _registerGuard(
            G_ESCROW_BURNED_NFT,
            IWaterfallEngine.Waterfall_NotFundable.selector,
            "WaterfallEngine.fund: NFT burned (cancelled facility)"
        );
        _registerGuard(
            G_ESCROW_NOT_PENDING,
            IWaterfallEngine.Waterfall_NotFundable.selector,
            "WaterfallEngine.fund: facility already funded or defaulted"
        );

        _pinModel();
    }

    /// @dev The ONE place the model touches the contracts' accessors, and it is a pin rather
    ///      than a derivation: a fixture change aborts `setUp` instead of silently retuning
    ///      the reference model to whatever is there.
    function _pinModel() private view {
        (uint16 bLimit, uint16 sLimit, uint256 floor_) = w.registry.limits();
        if (bLimit != mBorrowerLimitBps || sLimit != mStateLimitBps || floor_ != mFloor) revert ModelDrift(0);

        ICollateralRegistry.ClassParams memory f = w.registry.classParams(CLASS_FILM);
        if (
            f.maxLtvBps != FILM_MAX_LTV_BPS || f.maxMaturity != FILM_MAX_MATURITY
                || f.concentrationLimitBps != mClassLimitBps[CLASS_FILM] || !f.active
                || f.model != ICollateralRegistry.CollateralModel.Receivable
        ) revert ModelDrift(CLASS_FILM);

        ICollateralRegistry.ClassParams memory d = w.registry.classParams(CLASS_DIGITAL);
        if (
            d.maxLtvBps != DIGITAL_MAX_LTV_BPS || d.maxMaturity != DIGITAL_MAX_MATURITY
                || d.concentrationLimitBps != mClassLimitBps[CLASS_DIGITAL] || !d.active
                || d.model != ICollateralRegistry.CollateralModel.MarkedToMarket || d.maxMarkAge != DIGITAL_MAX_MARK_AGE
        ) revert ModelDrift(CLASS_DIGITAL);

        if (w.bridge.requiredMintAttestations(CLASS_FILM) != FILM_MASK) revert ModelDrift(6);
        if (w.bridge.requiredMintAttestations(CLASS_DIGITAL) != DIGITAL_MASK) revert ModelDrift(6);

        // the terms commitment preimage: if `creditTermsHash` ever changes shape, surface it
        // here rather than as a storm of unexplained "valid origination rejected" failures.
        Plan memory p = Plan({
            classId: CLASS_FILM,
            borrowerId: B1,
            stateId: S1,
            principal: 1e18,
            ltvBps: FILM_LTV_BPS,
            maturity: uint64(block.timestamp + 100 days),
            nextPaymentDue: uint64(block.timestamp + 30 days),
            planned: true
        });
        if (w.bridge.creditTermsHash(_termsOf(p)) != keccak256(abi.encode(_termsOf(p)))) revert ModelDrift(7);

        // INV-19 / INV-20 baseline: at construction the timelock stand-in is the sole
        // UPGRADER and the controller the sole MINTER. If that is false at t=0 the whole
        // authority family is measuring the wrong thing.
        if (!w.bridge.hasRole(Roles.UPGRADER_ROLE, a.admin)) revert ModelDrift(8);
        if (w.usdfr.hasRole(Roles.MINTER_ROLE, a.admin)) revert ModelDrift(8);
        if (!w.usdfr.hasRole(Roles.MINTER_ROLE, address(w.controller))) revert ModelDrift(8);
    }

    // ── deterministic seed: every shape exists before the campaign starts ──

    /// @notice Drives one of every shape the `afterInvariant` floors assert on, so those
    ///         floors are guarantees about the state each run was evaluated against rather
    ///         than a bet on fuzzer luck. Called once from `setUp`.
    function seedShapes() external {
        // liquidity: the KYC'd user mints so idle reserves can fund a facility
        _giveAndMintUSDfr(a.user, 5_000_000e6);

        // vault + queue: a funded vault and a live queued request give the probe actions a
        // mid-epoch / queued state to run against from call one.
        uint256 dep = 1_000_000e18;
        vm.startPrank(a.user);
        w.usdfr.approve(address(w.vault), dep);
        w.vault.deposit(dep, a.user);
        uint256 sh = w.vault.balanceOf(a.user) / 4;
        w.vault.approve(address(w.queue), sh);
        w.queue.requestRedeem(sh);
        vm.stopPrank();

        // curator first-loss so the cascade has a layer-1 to consult
        _giveAndMintUSDfr(a.curatorAddr, 200_000e6);
        vm.startPrank(a.curatorAddr);
        w.usdfr.approve(address(w.curator), 200_000e18);
        w.curator.postFirstLoss(CLASS_FILM, 200_000e18);
        vm.stopPrank();

        // (1) a fully attested, admissible film origination -> success shape
        _plan(CLASS_FILM, B1, S1, 300_000e18);
        _satisfyFullGate(w.bridge.totalOriginated() + 1, true);
        _originateNow();

        // (2) an origination with the gate deliberately incomplete -> gate rejection shape
        _plan(CLASS_FILM, B1, S1, 100_000e18);
        _satisfyKind(w.bridge.totalOriginated() + 1, IAttestationOracle.AttestationKind.AssignmentExecuted);
        _originateNow();

        // (3) full gate but DIVERGENT terms payload -> terms rejection shape
        _plan(CLASS_FILM, B2, S2, 100_000e18);
        _satisfyFullGate(w.bridge.totalOriginated() + 1, false);
        _originateNow();

        // (4) a concentration rejection: same borrower, far above the borrower limit
        _plan(CLASS_FILM, B1, S1, 1_900_000e18);
        _satisfyFullGate(w.bridge.totalOriginated() + 1, true);
        _originateNow();

        // (5) a marked-to-market origination (fresh mark, value-bounded draw)
        _plan(CLASS_DIGITAL, B3, bytes32(0), 200_000e18);
        _satisfyFullGate(w.bridge.totalOriginated() + 1, true);
        _originateNow();

        // (6) THE BINDING REGIME. Drop the bootstrap floor below the book so the plain
        //     relative rule of INV-16 is what governs, attempt an origination there, then
        //     restore the floor. Without this the whole concentration property can pass
        //     while never leaving the bootstrap exemption -- which is exactly the shape the
        //     live testnet configuration (limits at 100%) has.
        vm.prank(a.admin);
        w.registry.setConcentrationFloor(0);
        mFloor = 0;
        _plan(CLASS_FILM, B2, S2, 50_000e18);
        _satisfyFullGate(w.bridge.totalOriginated() + 1, true);
        _originateNow();
        vm.prank(a.admin);
        w.registry.setConcentrationFloor(SEED_FLOOR);
        mFloor = SEED_FLOOR;

        // (7) fund and default facility #1 so the cascade probe and `markPastDue` have a
        //     live target from the first call of every run.
        _fundFacility(mintedIds[0]);
        _declareDefaultOn(mintedIds[0]);

        // (8) one replay of a used digest, and one stale-valuation replay
        replayUsedDigest(0);
        replayStaleValuation(0);

        // (9) one unauthorised probe against an UNPAUSED system, and one against a PAUSED
        //     one, so "in any state" is seed-backed on both sides. Plus one authorised
        //     control, which is what gives the refusals their teeth.
        unauthorisedProbe(0, 0);
        setPausedModule(0); // pause the bridge
        unauthorisedProbe(3, 1);
        setPausedModule(0); // unpause it again
        authorisedControl(0);

        // (10) grant and immediately revoke both authority roles, so the INV-19/INV-20
        //     machinery is proven live WITHOUT the seed itself leaving a violating state
        //     behind. The campaign's own grants are what can violate the properties.
        grantRoleFromAdmin(0); // UPGRADER on the bridge
        revokeGrantedRole(0);
        grantRoleFromAdmin(1); // MINTER on USDfr
        revokeGrantedRole(1);

        // (11) one liveness probe
        permissionlessAndProbeLiveness(0);

        floors = Floors({
            originateAttempts: uint64(ghostOriginateAttempts),
            originateSuccesses: uint64(ghostOriginateSuccesses),
            gateRejects: uint64(ghostRejectGate),
            termsRejects: uint64(ghostRejectTerms),
            concRejects: uint64(ghostRejectClassConc + ghostRejectBorrowerConc + ghostRejectStateConc),
            replays: uint64(ghostReplayAttempts),
            probes: uint64(ghostProbeAttempts),
            liveness: uint64(ghostLivenessProbes),
            bindingAttempts: uint64(ghostAttemptsInBindingRegime),
            bindingRejects: uint64(ghostRejectionsInBindingRegime)
        });
        seedCallCount = callCount;
    }

    /// @notice True when the reader is looking at a state the fuzz campaign produced rather
    ///         than the bare post-`setUp` state.
    /// @dev MEASURED FOUNDRY BEHAVIOUR (forge 1.3.2-stable), and why `fuzzOnlyCounts` is
    ///      REPORTED rather than asserted on: `afterInvariant` runs after EVERY run, not once
    ///      at the end, and each run restarts from the post-`setUp` state. So a fuzz-only
    ///      delta assertion is really an assertion about ONE 128-call run. `tryOriginate` is
    ///      one of 17 registered selectors, so a single run misses it with probability
    ///      `(16/17)^128 ~ 4e-4` -- but across 256 runs that is `~10%` per campaign, and it
    ///      was reproduced at `--fuzz-seed 22`, where the same campaign passes with the
    ///      assertion removed and reports 6 fuzz-only attempts on its final run. A ~10%
    ///      flake is not a CI gate. The seed-independent replacement is the suite's
    ///      `test_handler_everyRegisteredSelectorIsLiveAndRevertFree`, plus reading the call
    ///      table. The repo's existing `CollateralInvariants.afterInvariant` asserts the same
    ///      shape of delta and carries the same latent fragility (it survives on a wider
    ///      per-selector margin: 1 of 6 selectors rather than 1 of 17).
    function campaignObserved() external view returns (bool) {
        return callCount > seedCallCount;
    }

    /// @notice Reported, not asserted: how much of the concentration BINDING REGIME (the
    ///         bootstrap floor at or below the book, so the plain relative rule of INV-16 is
    ///         what governs) the fuzz campaign reached on its own, above the seed floor.
    function bindingRegimeCounts()
        external
        view
        returns (uint256 rawAttempts, uint256 rawRejections, uint256 fuzzAttempts, uint256 fuzzRejections)
    {
        rawAttempts = ghostAttemptsInBindingRegime;
        rawRejections = ghostRejectionsInBindingRegime;
        fuzzAttempts = rawAttempts - floors.bindingAttempts;
        fuzzRejections = rawRejections - floors.bindingRejects;
    }

    /// @notice Counters ABOVE the deterministic seed floor, i.e. what the fuzz campaign
    ///         itself reached. Read by `afterInvariant` as the anti-vacuity tooth.
    function fuzzOnlyCounts()
        external
        view
        returns (uint256 attempts, uint256 successes, uint256 gate, uint256 terms, uint256 conc, uint256 probes)
    {
        attempts = ghostOriginateAttempts - floors.originateAttempts;
        successes = ghostOriginateSuccesses - floors.originateSuccesses;
        gate = ghostRejectGate - floors.gateRejects;
        terms = ghostRejectTerms - floors.termsRejects;
        conc = (ghostRejectClassConc + ghostRejectBorrowerConc + ghostRejectStateConc) - floors.concRejects;
        probes = ghostProbeAttempts - floors.probes;
    }

    // =====================================================================
    //  ACTION 1..5 — the mint gate and concentration admission (INV-15, INV-16)
    // =====================================================================

    /// @notice Chooses the terms `tryOriginate` will present at the NEXT facility id.
    /// @dev Deliberately independent of the attestation actions: re-planning after a
    ///      `CreditIssued` bundle has already been signed is exactly the H-4 desync shape,
    ///      and the model predicts the resulting `Bridge_TermsNotAttested` rejection.
    function planFacility(uint256 seed) external {
        uint256 classId = seed % 2 == 0 ? CLASS_FILM : CLASS_DIGITAL;
        bytes32 b = _borrowerOf(seed >> 8);
        bytes32 s = classId == CLASS_DIGITAL ? bytes32(0) : _stateOf(seed >> 16);
        uint256 principal = bound(seed >> 24, 10_000e18, 2_000_000e18);
        _plan(classId, b, s, principal);
        callCount++;
    }

    /// @notice Submits ONE genuine m-of-n EIP-712 bundle for the next facility id.
    /// @dev `modeSeed` steers the CreditIssued payload between "commits to exactly the
    ///      planned terms" and "commits to different terms", which is the only way the gate's
    ///      both-directions property can be exercised.
    function attestGateFact(uint256 kindSeed, uint256 modeSeed) external {
        if (w.oracle.paused()) return;
        uint256 id = w.bridge.totalOriginated() + 1;
        _ensurePlan(id);
        uint256 pick = kindSeed % 4;
        if (pick == 0) {
            _satisfyKind(id, IAttestationOracle.AttestationKind.AssignmentExecuted);
        } else if (pick == 1) {
            _satisfyKind(id, IAttestationOracle.AttestationKind.UCCFiled);
        } else if (pick == 2) {
            _attestTerms(id, modeSeed % 2 == 0);
        } else {
            // a mark whose value either supports the planned draw or is far too small
            uint256 principal = plans[id].principal;
            uint256 ltv = plans[id].ltvBps;
            uint256 value = modeSeed % 3 == 0 ? (principal / 4) + 1 : (principal * Config.BPS / ltv) + 1e18;
            _attestValuation(id, value);
        }
        callCount++;
    }

    /// @notice Governance revokes one standing fact at the next facility id, driving the
    ///         partially-satisfied space the gate must reject from.
    function revokeGateFact(uint256 kindSeed) external {
        uint256 id = w.bridge.totalOriginated() + 1;
        uint256 pick = kindSeed % 4;
        IAttestationOracle.AttestationKind kind = pick == 0
            ? IAttestationOracle.AttestationKind.AssignmentExecuted
            : pick == 1
                ? IAttestationOracle.AttestationKind.UCCFiled
                : pick == 2 ? IAttestationOracle.AttestationKind.CreditIssued : IAttestationOracle.AttestationKind.Valuation;
        uint256 bit = 1 << uint256(uint8(kind));
        if (gMask[id] & bit == 0) return; // nothing standing: `revoke` would revert
        vm.prank(a.admin);
        w.oracle.revoke(id, kind);
        gMask[id] &= ~bit;
        if (kind == IAttestationOracle.AttestationKind.CreditIssued) gTerms[id] = bytes32(0);
        if (kind == IAttestationOracle.AttestationKind.Valuation) {
            if (gMarkAsOf[id] > gWatermark[id]) gWatermark[id] = gMarkAsOf[id];
            gMarkValue[id] = 0;
            gMarkAsOf[id] = 0;
        }
        callCount++;
    }

    /// @notice Attempts the planned origination and classifies the outcome against the
    ///         handler's own prediction. THIS is INV-15 and INV-16.
    function tryOriginate() external {
        _originateNow();
        callCount++;
    }

    /// @notice Retires a pending facility, so the book shrinks as well as grows and the
    ///         concentration model is exercised in both directions.
    // =====================================================================
    //  AUDIT G11/G12.3 — "ESCROW CANNOT RELEASE WITHOUT THE NFT"
    // =====================================================================

    /// @notice CLAUDE.md §1.3, MINT GATE, second clause: "escrow cannot release without the NFT."
    ///
    ///         The on-chain meaning of that clause is `WaterfallEngine.fund`: it is the one path
    ///         that moves stablecoins out of `ReserveManager` custody to a borrower/escrow
    ///         account, and it is gated on the facility NFT existing (`ClaimBridge.facility`
    ///         reverts `Bridge_UnknownToken` for a token that was never minted or has been
    ///         burned), being in `Pending`, and re-passing the full origination gate
    ///         (`checkFundable`).
    ///
    ///         BEFORE THIS ACTION none of those guards was ever executed by the invariant tier.
    ///         `fundOrDefault` only ever called `fund` on facilities its own ghost recorded as
    ///         `Pending` — a textbook `fail_on_revert = true` pre-filter — so the campaign proved
    ///         that funding a fundable facility works, and proved nothing at all about the
    ///         clause. `LoanState.Pending` is enum value ZERO, which is precisely why this matters:
    ///         a default-initialised `Facility` struct reads as `Pending`, so the NFT-existence
    ///         check is the only thing standing between an unminted token id and a reserve
    ///         release.
    ///
    /// @dev Every probe here is fired by the AUTHORISED servicer. That is deliberate: refusing an
    ///      unauthorised caller is INV-18's property, and using an outsider would let the role
    ///      check answer the call before the mint gate ever ran, leaving this clause untested
    ///      while looking green.
    ///
    /// @dev DO NOT pre-check `facility(tokenId)` before firing. The whole point is that the
    ///      handler presents ids it has NOT verified.
    function probeEscrowReleaseWithoutNft(uint256 seed) external {
        callCount++;
        if (w.waterfall.paused() || w.bridge.paused()) return; // pausing is not the property here
        uint256 idleBefore = w.reserves.idleUSDC();
        uint256 deployedBefore = w.reserves.deployedPrincipal();
        uint256 usdcAmount = 1 + (seed % 100_000e6);

        uint256 pick = seed % 4;
        if (pick == 0) {
            // (a) a token id that was NEVER minted — the id an attacker would reach for
            uint256 ghostId = w.bridge.totalOriginated() + 1 + (seed % 7);
            _fireAtGuard(
                G_ESCROW_NO_NFT,
                a.servicer,
                address(w.waterfall),
                abi.encodeCall(WaterfallEngine.fund, (ghostId, usdcAmount))
            );
        } else if (pick == 1) {
            // (b) token id 0. `_facility` rejects it explicitly; without that rejection a zero id
            //     would index a default struct whose state is `Pending` and whose principal is 0.
            _fireAtGuard(
                G_ESCROW_ZERO_ID,
                a.servicer,
                address(w.waterfall),
                abi.encodeCall(WaterfallEngine.fund, (0, usdcAmount))
            );
        } else {
            // (c) a real facility that is NOT fundable: already funded, defaulted, or CANCELLED
            //     (cancelled means the NFT was burned — the "no NFT" case with real history).
            uint256 n = mintedIds.length;
            if (n == 0) return;
            uint256 id = mintedIds[seed % n];
            FacState st = facs[id].state;
            if (st == FacState.Pending || st == FacState.None) return; // fundable: not this probe

            // THE AMOUNT IS THE FACILITY'S EXACT PRINCIPAL, and that is load-bearing. An arbitrary
            // amount is refused by `Waterfall_PrincipalMismatch` before the state gate is ever
            // consulted, so the probe would report a refusal it did not earn: measured directly —
            // deleting the `Waterfall_NotFundable` gate left this invariant GREEN while the
            // mismatch check did the refusing. Using the real principal makes the state gate the
            // LAST thing standing between the probe and a live reserve release, which is the only
            // configuration in which a missing gate shows up as an ADMISSION.
            // DO NOT replace this with a fuzzed amount.
            uint256 exactPrincipalUSDC = facs[id].principal / 1e12;
            if (w.reserves.idleUSDC() < exactPrincipalUSDC) return; // no budget: the refusal would be earned elsewhere
            _fireAtGuard(
                st == FacState.Cancelled ? G_ESCROW_BURNED_NFT : G_ESCROW_NOT_PENDING,
                a.servicer,
                address(w.waterfall),
                abi.encodeCall(WaterfallEngine.fund, (id, exactPrincipalUSDC))
            );
        }

        escrowProbeAttempts++;
        // THE PROPERTY. A refused funding must not have moved one unit of stablecoin out of
        // reserve custody, and must not have created deployed principal. Checked here rather than
        // only via `guardAdmissions` because a partial release — reserves moved, then a later
        // check reverts — would be the actual catastrophe, and the revert alone would hide it.
        if (w.reserves.idleUSDC() != idleBefore || w.reserves.deployedPrincipal() != deployedBefore) {
            escrowLeaks++;
        }
        assertEq(w.reserves.idleUSDC(), idleBefore, "ESCROW LEAKED: idle reserves moved on a refused funding");
        assertEq(
            w.reserves.deployedPrincipal(), deployedBefore, "ESCROW LEAKED: principal was deployed on a refused funding"
        );
    }

    function cancelPendingFacility(uint256 seed) external {
        uint256 n = mintedIds.length;
        if (n == 0) return;
        uint256 id = mintedIds[seed % n];
        FacRec storage f = facs[id];
        if (f.state != FacState.Pending) return;
        vm.prank(a.originator);
        w.bridge.cancelPending(id);
        f.state = FacState.Cancelled;
        mClassExp[f.classId] -= f.principal;
        mBorrowerExp[f.borrowerId] -= f.principal;
        if (f.stateId != bytes32(0)) mStateExp[f.stateId] -= f.principal;
        mTotalExp -= f.principal;
        callCount++;
    }

    /// @notice Governance moves the concentration limits DURING the campaign.
    /// @dev The live testnet configuration leaves several limits at 100%, which makes INV-16
    ///      trivially true. This action is what drives the campaign into the binding regime
    ///      and back out of it, repeatedly. Every move is mirrored into the handler's own
    ///      limit ghosts, so the admission prediction never reads the registry.
    function retuneLimits(uint256 seed) external {
        // modes 0..2 all move the bootstrap floor. It is weighted this heavily ON PURPOSE:
        // the floor is what decides whether the plain relative rule of INV-16 binds at all,
        // and a campaign that leaves it at the bootstrap value tests the exemption rather
        // than the limit. Measured with a 1-in-6 weighting the fuzz-only binding-regime
        // reach of a single run was zero.
        uint256 mode = seed % 8;
        if (mode < 4) {
            // three of the four are at or below a test-scale book, so the campaign spends
            // most of its time with the bootstrap exemption INACTIVE and the plain relative
            // concentration rule binding.
            uint256[4] memory choices = [uint256(0), 100_000e18, 400_000e18, SEED_FLOOR];
            uint256 f = choices[(seed >> 8) % 4];
            vm.prank(a.admin);
            w.registry.setConcentrationFloor(f);
            mFloor = f;
        } else if (mode == 3) {
            uint16 bps = uint16(bound(seed >> 8, 100, 10_000));
            vm.prank(a.admin);
            w.registry.setBorrowerLimit(bps);
            mBorrowerLimitBps = bps;
        } else if (mode == 4) {
            uint16 bps = uint16(bound(seed >> 8, 100, 10_000));
            vm.prank(a.admin);
            w.registry.setStateLimit(bps);
            mStateLimitBps = bps;
        } else if (mode == 5) {
            uint16 bps = uint16(bound(seed >> 8, 100, 10_000));
            vm.prank(a.admin);
            w.registry.setClass(CLASS_FILM, _filmParams(bps));
            mClassLimitBps[CLASS_FILM] = bps;
        } else if (mode == 6) {
            bytes32 b = _borrowerOf(seed >> 8);
            uint16 bps = uint16(bound(seed >> 16, 0, 10_000));
            vm.prank(a.admin);
            w.registry.setBorrowerLimitOverride(b, bps);
            mBorrowerOverrideBps[b] = bps;
            mBorrowerOverridden[b] = true;
        } else {
            bytes32 b = _borrowerOf(seed >> 8);
            if (!mBorrowerOverridden[b]) return;
            vm.prank(a.admin);
            w.registry.clearBorrowerLimitOverride(b);
            mBorrowerOverridden[b] = false;
            mBorrowerOverrideBps[b] = 0;
        }
        callCount++;
    }

    // =====================================================================
    //  ACTION 7..8 — attestation single use (INV-17)
    // =====================================================================

    /// @notice Adversarial replay: resubmits a previously ACCEPTED bundle byte-for-byte.
    /// @dev The oracle must refuse it on the consumed digest. `expiry` on every bundle this
    ///      handler signs is `type(uint64).max` precisely so the replay can never be refused
    ///      for the uninteresting reason (`Oracle_Expired`) and mask a working replay.
    function replayUsedDigest(uint256 seed) public {
        uint256 n = accepted.length;
        if (n == 0 || w.oracle.paused()) return;
        IAttestationOracle.AttestationInput memory inp = accepted[seed % n];
        bytes[] memory sigs = _sign(inp);
        ghostReplayAttempts++;
        (bool ok, bytes memory ret) = address(w.oracle).call(abi.encodeCall(AttestationOracle.attest, (inp, sigs)));
        if (ok) {
            ghostReplayAccepted++;
        } else {
            ghostReplayRejected++;
            ghostLastReplaySelector = _selectorOf(ret);
        }
        callCount++;
    }

    /// @notice Adversarial rollback: a FRESH digest (new nonce) carrying an `asOf` at or
    ///         below the per-facility high-watermark. The digest check cannot save the
    ///         oracle here, so this exercises the H-02 watermark itself.
    function replayStaleValuation(uint256 seed) public {
        if (w.oracle.paused()) return;
        uint256 id = _facilityWithWatermark(seed);
        if (id == 0) return;
        uint64 floorAsOf = gWatermark[id];
        if (gMarkAsOf[id] > floorAsOf) floorAsOf = gMarkAsOf[id];
        if (floorAsOf == 0) return;
        IAttestationOracle.AttestationInput memory inp = IAttestationOracle.AttestationInput({
            facilityId: id,
            kind: IAttestationOracle.AttestationKind.Valuation,
            payload: bytes32(uint256(1_000_000e18)),
            asOf: floorAsOf, // equal to the watermark: `attest` requires STRICTLY newer
            expiry: type(uint64).max,
            nonce: ++nonceCounter
        });
        bytes[] memory sigs = _sign(inp);
        ghostStaleValuationAttempts++;
        (bool ok, bytes memory ret) = address(w.oracle).call(abi.encodeCall(AttestationOracle.attest, (inp, sigs)));
        if (ok) {
            ghostStaleValuationAccepted++;
            gMarkValue[id] = 1_000_000e18;
            gMarkAsOf[id] = floorAsOf;
        } else {
            ghostStaleValuationRejected++;
            ghostLastStaleSelector = _selectorOf(ret);
        }
        callCount++;
    }

    // =====================================================================
    //  ACTION 9..10 — authorisation (INV-18)
    // =====================================================================

    /// @notice An actor holding NO role attempts one privileged call, in whatever state the
    ///         campaign has reached. Every outcome is classified; a success is a violation.
    function unauthorisedProbe(uint256 targetSeed, uint256 actorSeed) public {
        address actor = _unauthorisedActor(actorSeed);
        uint256 idx = targetSeed % PROBE_COUNT;
        (address target, bytes memory data) = _probe(idx, actor);
        _recordProbeState();
        ghostProbeCoverage |= 1 << idx;
        ghostProbeAttempts++;
        vm.prank(actor);
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) {
            ghostProbeSuccesses++;
            ghostLastBypassProbe = idx;
        } else {
            bytes4 sel = _selectorOf(ret);
            if (sel == IAccessControl.AccessControlUnauthorizedAccount.selector) {
                ghostProbeRejectedByRole++;
            } else {
                ghostProbeRejectedOther++;
                ghostLastProbeOtherSelector = sel;
            }
        }
        callCount++;
    }

    /// @notice POSITIVE CONTROL. The correctly-authorised caller performs the same class of
    ///         privileged action. Without this, "every unauthorised probe reverted" is
    ///         indistinguishable from "every one of those calls reverts for everybody".
    function authorisedControl(uint256 seed) public {
        uint256 mode = seed % 7;
        bool ok;
        if (mode == 0) {
            address t = address(w.bridge);
            bool was = gBridgePaused;
            bytes memory d = was ? abi.encodeCall(ClaimBridge.unpause, ()) : abi.encodeCall(ClaimBridge.pause, ());
            vm.prank(a.guardian);
            (ok,) = t.call(d);
            if (ok) gBridgePaused = !was;
        } else if (mode == 1) {
            vm.prank(a.admin);
            (ok,) = address(w.registry).call(abi.encodeCall(CollateralRegistry.setBorrowerLimit, (mBorrowerLimitBps)));
        } else if (mode == 2) {
            vm.prank(a.admin);
            (ok,) = address(w.oracle).call(
                abi.encodeCall(AttestationOracle.setThreshold, (IAttestationOracle.AttestationKind.CreditIssued, 2))
            );
        } else if (mode == 3) {
            vm.prank(a.admin);
            (ok,) =
                address(w.vault).call(abi.encodeCall(SUSDfr.setPerformanceFee, (Config.DEFAULT_PERFORMANCE_FEE_BPS)));
        } else if (mode == 4) {
            vm.prank(a.admin);
            (ok,) = address(w.curator).call(
                abi.encodeCall(CuratorModule.setCuratorApproved, (CLASS_FILM, a.curatorAddr, true))
            );
        } else if (mode == 5) {
            vm.prank(a.admin);
            (ok,) = address(w.defaultManager).call(abi.encodeCall(DefaultManager.setBackstop, (a.backstop)));
        } else {
            vm.prank(a.complianceAdmin);
            (ok,) = address(w.compliance).call(abi.encodeCall(ComplianceRegistry.setAllowed, (a.user, true)));
        }
        if (ok) ghostAuthorisedControlSuccesses++;
        else ghostAuthorisedControlFailures++;
        callCount++;
    }

    // =====================================================================
    //  ACTION 11..12 — role authority (INV-19, INV-20)
    // =====================================================================

    /// @notice Exercises a governance role rotation as one atomic handler action.
    /// @dev The governance timelock can deliberately grant these roles, so leaving a grant
    ///      outstanding and then asserting that governance never did so is not a protocol
    ///      invariant. The action instead proves the role-admin machinery is live while
    ///      restoring the production baseline before the invariant boundary. Unauthorized
    ///      grants remain covered by the low-level INV-18 probes.
    function grantRoleFromAdmin(uint256 seed) public {
        uint256 mode = seed % 6;
        if (mode == 0) {
            vm.prank(a.admin);
            w.bridge.grantRole(Roles.UPGRADER_ROLE, roleSink);
            vm.prank(a.admin);
            w.bridge.revokeRole(Roles.UPGRADER_ROLE, roleSink);
            ghostUpgraderGrants++;
        } else if (mode == 1) {
            vm.prank(a.admin);
            w.usdfr.grantRole(Roles.MINTER_ROLE, roleSink);
            vm.prank(a.admin);
            w.usdfr.revokeRole(Roles.MINTER_ROLE, roleSink);
            ghostMinterGrants++;
        } else if (mode == 2) {
            vm.prank(a.admin);
            w.vault.grantRole(Roles.UPGRADER_ROLE, roleSink);
            vm.prank(a.admin);
            w.vault.revokeRole(Roles.UPGRADER_ROLE, roleSink);
            ghostUpgraderGrants++;
        } else if (mode == 3) {
            vm.prank(a.admin);
            w.bridge.grantRole(Roles.ORIGINATOR_ROLE, roleSink);
            vm.prank(a.admin);
            w.bridge.revokeRole(Roles.ORIGINATOR_ROLE, roleSink);
        } else if (mode == 4) {
            vm.prank(a.admin);
            w.waterfall.grantRole(Roles.SERVICER_ROLE, roleSink);
            vm.prank(a.admin);
            w.waterfall.revokeRole(Roles.SERVICER_ROLE, roleSink);
        } else {
            vm.prank(a.admin);
            w.registry.grantRole(Roles.UPGRADER_ROLE, roleSink);
            vm.prank(a.admin);
            w.registry.revokeRole(Roles.UPGRADER_ROLE, roleSink);
            ghostUpgraderGrants++;
        }
        ghostRoleGrants++;
        ghostRoleRevokes++;
        callCount++;
    }

    /// @notice Governance takes the grant back, so the campaign visits both sides of the
    ///         role state and the authority invariants are not one-way.
    function revokeGrantedRole(uint256 seed) public {
        uint256 mode = seed % 6;
        if (mode == 0) {
            vm.prank(a.admin);
            w.bridge.revokeRole(Roles.UPGRADER_ROLE, roleSink);
        } else if (mode == 1) {
            vm.prank(a.admin);
            w.usdfr.revokeRole(Roles.MINTER_ROLE, roleSink);
        } else if (mode == 2) {
            vm.prank(a.admin);
            w.vault.revokeRole(Roles.UPGRADER_ROLE, roleSink);
        } else if (mode == 3) {
            vm.prank(a.admin);
            w.bridge.revokeRole(Roles.ORIGINATOR_ROLE, roleSink);
        } else if (mode == 4) {
            vm.prank(a.admin);
            w.waterfall.revokeRole(Roles.SERVICER_ROLE, roleSink);
        } else {
            vm.prank(a.admin);
            w.registry.revokeRole(Roles.UPGRADER_ROLE, roleSink);
        }
        ghostRoleRevokes++;
        callCount++;
    }

    // =====================================================================
    //  ACTION 13..14, 17 — state variation, so "in any state" has teeth
    // =====================================================================

    /// @notice Guardian pauses or unpauses one module.
    function setPausedModule(uint256 seed) public {
        uint256 mode = seed % 5;
        address t;
        bool isPaused;
        if (mode == 0) {
            t = address(w.bridge);
            isPaused = w.bridge.paused();
        } else if (mode == 1) {
            t = address(w.oracle);
            isPaused = w.oracle.paused();
        } else if (mode == 2) {
            t = address(w.queue);
            isPaused = w.queue.paused();
        } else if (mode == 3) {
            t = address(w.curator);
            isPaused = w.curator.paused();
        } else {
            t = address(w.waterfall);
            isPaused = w.waterfall.paused();
        }
        // Biased toward the UNPAUSED system (~25% paused steady state). A fair coin left the
        // bridge paused about half the campaign, which suppressed the origination attempts
        // the gate family depends on; the paused shape still has a deterministic seed floor.
        bool wantPaused = (seed >> 16) % 4 == 0;
        if (wantPaused == isPaused) {
            callCount++;
            return;
        }
        bytes memory d = isPaused ? abi.encodeWithSignature("unpause()") : abi.encodeWithSignature("pause()");
        vm.prank(a.guardian);
        (bool ok,) = t.call(d);
        if (ok && mode == 0) gBridgePaused = !isPaused;
        callCount++;
    }

    /// @notice Ordinary user activity: mint, vault deposit, queue request.
    function userFlow(uint256 seed) external {
        uint256 mode = seed % 3;
        if (mode == 0) {
            if (w.controller.paused()) return;
            uint256 amt = bound(seed >> 8, 1_000e6, 200_000e6);
            _giveAndMintUSDfr(a.user, amt);
        } else if (mode == 1) {
            if (w.vault.paused()) return;
            uint256 bal = w.usdfr.balanceOf(a.user);
            if (bal < 1e18) return;
            uint256 amt = bound(seed >> 8, 1e18, bal);
            vm.startPrank(a.user);
            w.usdfr.approve(address(w.vault), amt);
            (bool ok,) = address(w.vault).call(abi.encodeCall(SUSDfr.deposit, (amt, a.user)));
            vm.stopPrank();
            ok;
        } else {
            if (w.queue.paused()) return;
            uint256 sh = w.vault.balanceOf(a.user);
            if (sh == 0) return;
            uint256 use = bound(seed >> 8, 1, sh);
            vm.startPrank(a.user);
            w.vault.approve(address(w.queue), use);
            (bool ok,) = address(w.queue).call(abi.encodeCall(RedemptionQueue.requestRedeem, (use)));
            vm.stopPrank();
            ok;
        }
        callCount++;
    }

    /// @notice Servicer drives a pending facility into Active, or an active one into default,
    ///         so the probe actions see mid-lifecycle and impaired states.
    function fundOrDefault(uint256 seed) external {
        uint256 n = mintedIds.length;
        if (n == 0) return;
        uint256 id = mintedIds[seed % n];
        FacRec storage f = facs[id];
        if (f.state == FacState.Pending) {
            _fundFacility(id);
        } else if (f.state == FacState.Active && seed % 3 == 0) {
            _declareDefaultOn(id);
        }
        callCount++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 10 days));
        callCount++;
    }

    // =====================================================================
    //  ACTION 15 — liveness under permissionless-only pressure (INV-21)
    // =====================================================================

    /// @notice Performs ONE purely permissionless action by an external actor holding no
    ///         role, then probes whether all four core paths are still reachable.
    /// @dev The probe runs inside `vm.snapshotState()` / `vm.revertToState()`, so the
    ///      protocol state the campaign built is not disturbed by the probe itself. Results
    ///      are held on the stack across the revert and written to storage afterwards.
    ///      "Reachable" is deliberately generous: the probe is allowed to bring capital and
    ///      to let time pass, because INV-21 is about PERMANENT disablement, not about an
    ///      instantaneous liquidity or cooldown condition. Governance pausing is excluded by
    ///      the invariant's own wording, so a paused module skips its probe rather than
    ///      reporting a violation.
    function permissionlessAndProbeLiveness(uint256 seed) public {
        _permissionlessAction(seed);
        ghostPermissionlessActions++;

        uint256 savedTime = block.timestamp;
        uint256 snap = vm.snapshotState();
        uint8 mintRes = _probeMint();
        bytes4 mintSel = lastProbeSelector;
        uint8 redeemRes = _probeRedeem();
        bytes4 redeemSel = lastProbeSelector;
        uint8 settleRes = _probeSettle();
        bytes4 settleSel = lastProbeSelector;
        uint8 cascadeRes = _probeCascade();
        bytes4 cascadeSel = lastProbeSelector;
        vm.revertToState(snap);
        // belt and braces: the probe is allowed to warp, and the campaign must not inherit it
        vm.warp(savedTime);

        // storage writes happen AFTER the revert so they survive it
        ghostLivenessProbes++;
        if (mintRes == 1) {
            ghostMintProbedOk++;
        } else if (mintRes == 2) {
            ghostMintBlocked++;
            ghostLastMintBlockSelector = mintSel;
        }
        if (redeemRes == 1) {
            ghostRedeemProbedOk++;
        } else if (redeemRes == 2) {
            ghostRedeemBlocked++;
            ghostLastRedeemBlockSelector = redeemSel;
        }
        if (settleRes == 1) {
            ghostSettleProbedOk++;
        } else if (settleRes == 2) {
            ghostSettleBlocked++;
            ghostLastSettleBlockSelector = settleSel;
        }
        if (cascadeRes == 1) {
            ghostCascadeProbedOk++;
        } else if (cascadeRes == 2) {
            ghostCascadeBlocked++;
            ghostLastCascadeBlockSelector = cascadeSel;
        } else {
            ghostCascadeNotApplicable++;
        }
        callCount++;
    }

    /// @dev Scratch slot for the selector of the last probe failure. Written inside the
    ///      snapshot and therefore rolled back; the value is carried out on the stack.
    bytes4 internal lastProbeSelector;

    function _permissionlessAction(uint256 seed) private {
        uint256 mode = seed % 6;
        if (mode == 0) {
            vm.prank(a.outsider);
            w.reserves.reconcileIdleUSDC();
        } else if (mode == 1) {
            bytes32[] memory bs = new bytes32[](3);
            bs[0] = B1;
            bs[1] = B2;
            bs[2] = B3;
            bytes32[] memory ss = new bytes32[](2);
            ss[0] = S1;
            ss[1] = S2;
            vm.prank(a.outsider);
            w.registry.syncConcentrationBreaches(bs, ss);
        } else if (mode == 2) {
            vm.prank(a.outsider);
            (bool ok,) = address(w.vault).call(abi.encodeCall(SUSDfr.accrueFees, ()));
            ok;
        } else if (mode == 3) {
            // donation: the classic way to move a measured balance without a deposit
            uint256 amt = bound(seed >> 8, 1, 1_000e6);
            w.usdc.mint(a.outsider, amt);
            vm.prank(a.outsider);
            IERC20(address(w.usdc)).transfer(address(w.reserves), amt);
        } else if (mode == 4) {
            vm.prank(a.outsider);
            (bool ok,) = address(w.queue).call(abi.encodeCall(RedemptionQueue.closeEpoch, (1)));
            ok;
        } else {
            uint256 n = mintedIds.length;
            if (n == 0) return;
            vm.prank(a.outsider);
            (bool ok,) =
                address(w.defaultManager).call(abi.encodeCall(DefaultManager.markPastDue, (mintedIds[seed % n])));
            ok;
        }
    }

    /// @dev 0 = skipped (governance pause: out of scope), 1 = reachable, 2 = BLOCKED.
    function _probeMint() private returns (uint8) {
        if (w.controller.paused() || w.reserves.paused()) return 0;
        uint256 amt = 1_000e6;
        w.usdc.mint(a.user, amt);
        vm.startPrank(a.user);
        w.usdc.approve(address(w.controller), amt);
        (bool ok, bytes memory ret) = address(w.controller).call(abi.encodeCall(MintRedeemController.mint, (amt)));
        vm.stopPrank();
        if (ok) return 1;
        lastProbeSelector = _selectorOf(ret);
        return 2;
    }

    function _probeRedeem() private returns (uint8) {
        if (w.controller.paused() || w.reserves.paused()) return 0;
        uint256 idle = w.reserves.idleUSDC();
        if (idle == 0) {
            // no cash on hand is a liquidity condition, not a permanent freeze: bring some
            // in through the ordinary permissionless entry path first.
            if (_probeMint() != 1) return 2;
            idle = w.reserves.idleUSDC();
            if (idle == 0) return 2;
        }
        uint256 bal = w.usdfr.balanceOf(a.user);
        if (bal == 0) return 0;
        uint256 want = bal < idle * 1e12 ? bal : idle * 1e12;
        want = (want / 1e12) * 1e12;
        if (want == 0) return 0;
        vm.prank(a.user);
        (bool ok, bytes memory ret) = address(w.controller).call(abi.encodeWithSignature("redeem(uint256)", want));
        if (ok) return 1;
        lastProbeSelector = _selectorOf(ret);
        return 2;
    }

    function _probeSettle() private returns (uint8) {
        if (w.queue.paused() || w.vault.paused()) return 0;
        // legal transitions the probe is allowed to make: bring liquidity, let time pass.
        if (_probeMint() == 2) return 2;
        uint256 wait = uint256(w.queue.redeemCooldown()) + 2 days;
        uint64 endsAt = w.queue.epochEndsAt();
        if (endsAt > block.timestamp + wait) wait = uint256(endsAt) - block.timestamp + 1;
        vm.warp(block.timestamp + wait);
        (bool ok, bytes memory ret) = address(w.queue).call(abi.encodeCall(RedemptionQueue.closeEpoch, (5)));
        if (ok) return 1;
        lastProbeSelector = _selectorOf(ret);
        return 2;
    }

    function _probeCascade() private returns (uint8) {
        if (w.oracle.paused()) return 0;
        uint256 id = 0;
        for (uint256 i = 0; i < defaultedIds.length; ++i) {
            if (w.reserves.deployedTo(defaultedIds[i]) != 0) {
                id = defaultedIds[i];
                break;
            }
        }
        if (id == 0) return 0; // no live default to cascade: not applicable, not a failure
        uint256 loss = 1e18;
        uint256 outstanding = w.reserves.deployedTo(id);
        if (loss > outstanding) loss = outstanding;
        bytes32 evidence = keccak256("inv-authz-cascade-probe");
        _attestRaw(id, IAttestationOracle.AttestationKind.LossRealized, keccak256(abi.encode(id, loss, evidence)));
        vm.prank(a.servicer);
        (bool ok, bytes memory ret) =
            address(w.defaultManager).call(abi.encodeCall(DefaultManager.realizeLoss, (id, loss, evidence)));
        if (ok) return 1;
        lastProbeSelector = _selectorOf(ret);
        return 2;
    }

    // =====================================================================
    //  origination: attempt + independent prediction
    // =====================================================================

    function _originateNow() private {
        uint256 id = w.bridge.totalOriginated() + 1;
        _ensurePlan(id);
        Plan memory p = plans[id];

        bytes4 expected = _predict(id, p);
        bool inBinding = mFloor <= mTotalExp;
        ghostOriginateAttempts++;
        if (inBinding) ghostAttemptsInBindingRegime++;

        vm.prank(a.originator);
        (bool ok, bytes memory ret) =
            address(w.bridge).call(abi.encodeCall(ClaimBridge.originate, (a.custodian, _termsOf(p))));

        if (ok) {
            if (expected != bytes4(0)) {
                // the contract admitted something the model says must be refused
                if (
                    expected == ClaimBridge.Bridge_AttestationMissing.selector
                        || expected == ClaimBridge.Bridge_TermsNotAttested.selector
                        || expected == ClaimBridge.Bridge_ValuationStale.selector
                        || expected == ClaimBridge.Bridge_LtvExceedsValue.selector
                ) {
                    ghostGateBypasses++;
                } else if (
                    expected == ICollateralRegistry.Registry_ConcentrationExceeded.selector
                        || expected == ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector
                        || expected == ICollateralRegistry.Registry_StateConcentrationExceeded.selector
                ) {
                    ghostLimitBypasses++;
                } else {
                    ghostWrongReason++;
                }
                ghostLastExpectedSelector = expected;
            }
            _onMinted(id, p, expected == bytes4(0));
        } else {
            bytes4 actual = _selectorOf(ret);
            if (expected == bytes4(0)) {
                ghostUnexpectedRejections++;
                ghostLastActualSelector = actual;
            } else if (actual != expected) {
                ghostWrongReason++;
                ghostLastExpectedSelector = expected;
                ghostLastActualSelector = actual;
            }
            _countRejection(actual);
            if (inBinding) ghostRejectionsInBindingRegime++;
        }
    }

    function _onMinted(uint256 id, Plan memory p, bool predictedAdmissible) private {
        ghostOriginateSuccesses++;
        facs[id] = FacRec({
            classId: p.classId,
            borrowerId: p.borrowerId,
            stateId: p.stateId,
            principal: p.principal,
            state: FacState.Pending,
            gateSatisfiedAtMint: _gateOk(id, p.classId) && _termsOk(id, p) && _markOk(id, p),
            termsBoundAtMint: _termsOk(id, p),
            limitsRespectedAtMint: predictedAdmissible || _admissible(p)
        });
        mintedIds.push(id);
        mClassExp[p.classId] += p.principal;
        mBorrowerExp[p.borrowerId] += p.principal;
        if (p.stateId != bytes32(0)) mStateExp[p.stateId] += p.principal;
        mTotalExp += p.principal;
    }

    function _countRejection(bytes4 sel) private {
        if (sel == ClaimBridge.Bridge_AttestationMissing.selector) {
            ghostRejectGate++;
        } else if (sel == ClaimBridge.Bridge_TermsNotAttested.selector) {
            ghostRejectTerms++;
        } else if (sel == ClaimBridge.Bridge_ValuationStale.selector) {
            ghostRejectStaleMark++;
        } else if (sel == ClaimBridge.Bridge_LtvExceedsValue.selector) {
            ghostRejectLtvValue++;
        } else if (sel == ClaimBridge.Bridge_BadFacility.selector) {
            ghostRejectBadFacility++;
        } else if (sel == ICollateralRegistry.Registry_ConcentrationExceeded.selector) {
            ghostRejectClassConc++;
        } else if (sel == ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector) {
            ghostRejectBorrowerConc++;
        } else if (sel == ICollateralRegistry.Registry_StateConcentrationExceeded.selector) {
            ghostRejectStateConc++;
        } else if (sel == ENFORCED_PAUSE) {
            ghostRejectPaused++;
        }
    }

    /// @dev The reference model, evaluated ENTIRELY on handler-owned state, in the order the
    ///      contract evaluates its own gates. Returns `bytes4(0)` for "must be admitted".
    function _predict(uint256 id, Plan memory p) private view returns (bytes4) {
        // `originate` is `onlyRole(ORIGINATOR) whenNotPaused nonReentrant`: the role check
        // passes (the handler pranks the originator), so a paused bridge refuses here.
        if (gBridgePaused) return ENFORCED_PAUSE;
        // P-45: state concentration is meaningful for tax-credit facilities only. The
        // bridge rejects an untagged tax-credit origination (and a tagged non-tax one)
        // before it reaches the attestation gate.
        if ((p.classId == CLASS_FILM) == (p.stateId == bytes32(0))) {
            return ClaimBridge.Bridge_BadFacility.selector;
        }
        uint64 maxMaturity = p.classId == CLASS_FILM ? FILM_MAX_MATURITY : DIGITAL_MAX_MATURITY;
        if (p.maturity <= block.timestamp || p.maturity > block.timestamp + maxMaturity) {
            return ClaimBridge.Bridge_BadFacility.selector;
        }
        if (p.nextPaymentDue <= block.timestamp || p.nextPaymentDue > p.maturity) {
            return ClaimBridge.Bridge_BadFacility.selector;
        }
        if (!_gateOk(id, p.classId)) return ClaimBridge.Bridge_AttestationMissing.selector;
        if (!_termsOk(id, p)) return ClaimBridge.Bridge_TermsNotAttested.selector;
        bytes32 termsHash = keccak256(abi.encode(_termsOf(p)));
        if (gAssignmentPayload[id] != termsHash) {
            return ClaimBridge.Bridge_AttestationNotBoundToDeal.selector;
        }
        if (p.classId == CLASS_FILM && gUccPayload[id] != termsHash) {
            return ClaimBridge.Bridge_AttestationNotBoundToDeal.selector;
        }
        if (p.classId == CLASS_DIGITAL) {
            if (gMarkAsOf[id] == 0 || block.timestamp - gMarkAsOf[id] > DIGITAL_MAX_MARK_AGE) {
                return ClaimBridge.Bridge_ValuationStale.selector;
            }
            if (p.principal > gMarkValue[id] * p.ltvBps / Config.BPS) {
                return ClaimBridge.Bridge_LtvExceedsValue.selector;
            }
        }
        return _concentrationSelector(p);
    }

    /// @dev INV-16, encoded from the handler's OWN exposure and limit ghosts. The
    ///      `max(post-trade book, floor)` base is the documented admission rule (registry
    ///      contract note, AUDIT FIX M-02); when `mFloor <= mTotalExp` it collapses to the
    ///      plain relative rule the audit's INV-16 states, which is the regime
    ///      `ghostAttemptsInBindingRegime` counts.
    function _concentrationSelector(Plan memory p) private view returns (bytes4) {
        if (p.principal > MAX_SAFE_EXPOSURE - mTotalExp) return ICollateralRegistry.Registry_PrincipalTooLarge.selector;
        uint256 newTotal = mTotalExp + p.principal;
        uint256 base = newTotal > mFloor ? newTotal : mFloor;
        if (_over(mClassExp[p.classId] + p.principal, mClassLimitBps[p.classId], base)) {
            return ICollateralRegistry.Registry_ConcentrationExceeded.selector;
        }
        if (_over(mBorrowerExp[p.borrowerId] + p.principal, _borrowerLimit(p.borrowerId), base)) {
            return ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector;
        }
        if (p.stateId != bytes32(0) && _over(mStateExp[p.stateId] + p.principal, mStateLimitBps, base)) {
            return ICollateralRegistry.Registry_StateConcentrationExceeded.selector;
        }
        return bytes4(0);
    }

    function _admissible(Plan memory p) private view returns (bool) {
        return _concentrationSelector(p) == bytes4(0);
    }

    function _over(uint256 exp, uint16 limitBps, uint256 base) private pure returns (bool) {
        return exp > uint256(limitBps) * base / Config.BPS;
    }

    function _borrowerLimit(bytes32 b) private view returns (uint16) {
        return mBorrowerOverridden[b] ? mBorrowerOverrideBps[b] : mBorrowerLimitBps;
    }

    function _gateOk(uint256 id, uint256 classId) private view returns (bool) {
        uint256 mask = classId == CLASS_FILM ? FILM_MASK : DIGITAL_MASK;
        return gMask[id] & mask == mask;
    }

    function _termsOk(uint256 id, Plan memory p) private view returns (bool) {
        bytes32 standing = gTerms[id];
        return standing != bytes32(0) && standing == keccak256(abi.encode(_termsOf(p)));
    }

    function _markOk(uint256 id, Plan memory p) private view returns (bool) {
        if (p.classId != CLASS_DIGITAL) return true;
        if (gMarkAsOf[id] == 0 || block.timestamp - gMarkAsOf[id] > DIGITAL_MAX_MARK_AGE) return false;
        return p.principal <= gMarkValue[id] * p.ltvBps / Config.BPS;
    }

    // =====================================================================
    //  views the suite reads
    // =====================================================================

    function mintedCount() external view returns (uint256) {
        return mintedIds.length;
    }

    function mintedAt(uint256 i) external view returns (uint256) {
        return mintedIds[i];
    }

    function gateSatisfiedAtMint(uint256 tokenId) external view returns (bool) {
        return facs[tokenId].gateSatisfiedAtMint;
    }

    function termsBoundAtMint(uint256 tokenId) external view returns (bool) {
        return facs[tokenId].termsBoundAtMint;
    }

    function limitsRespectedAtMint(uint256 tokenId) external view returns (bool) {
        return facs[tokenId].limitsRespectedAtMint;
    }

    function acceptedDigestCount() external view returns (uint256) {
        return acceptedDigests.length;
    }

    function acceptedDigestAt(uint256 i) external view returns (bytes32) {
        return acceptedDigests[i];
    }

    function trackedFacilityCount() external view returns (uint256) {
        return mintedIds.length;
    }

    function roleSinkAddress() external view returns (address) {
        return roleSink;
    }

    /// @notice How many distinct privileged entry points the unauthorised probe table covers.
    function probeCount() external pure returns (uint256) {
        return PROBE_COUNT;
    }

    function borrowerAt(uint256 i) external pure returns (bytes32) {
        if (i % 3 == 0) return B1;
        if (i % 3 == 1) return B2;
        return B3;
    }

    function stateAt(uint256 i) external pure returns (bytes32) {
        return i % 2 == 0 ? S1 : S2;
    }

    // =====================================================================
    //  internals: attestation plumbing (REAL EIP-712 m-of-n)
    // =====================================================================

    function _sign(IAttestationOracle.AttestationInput memory inp) private view returns (bytes[] memory sigs) {
        uint8 m = w.oracle.threshold(inp.kind);
        bytes32 digest = w.oracle.attestationDigest(inp);
        (uint256 lo, uint256 hi) = vm.addr(a.pk1) < vm.addr(a.pk2) ? (a.pk1, a.pk2) : (a.pk2, a.pk1);
        sigs = new bytes[](m);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lo, digest);
        sigs[0] = abi.encodePacked(r, s, v);
        if (m > 1) {
            (v, r, s) = vm.sign(hi, digest);
            sigs[1] = abi.encodePacked(r, s, v);
        }
    }

    /// @dev Submits a bundle and records it for replay. Returns true when accepted.
    function _attestRaw(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload)
        private
        returns (bool)
    {
        IAttestationOracle.AttestationInput memory inp = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: type(uint64).max,
            nonce: ++nonceCounter
        });
        bytes32 digest = w.oracle.attestationDigest(inp);
        bytes[] memory sigs = _sign(inp);
        (bool ok,) = address(w.oracle).call(abi.encodeCall(AttestationOracle.attest, (inp, sigs)));
        if (!ok) return false;
        accepted.push(inp);
        acceptedDigests.push(digest);
        gDigestUsed[digest] = true;
        ghostAttestAccepted++;
        return true;
    }

    function _satisfyKind(uint256 id, IAttestationOracle.AttestationKind kind) private {
        bytes32 payload = keccak256(abi.encode("inv-authz-fact", id, uint8(kind), nonceCounter));
        if (_attestRaw(id, kind, payload)) {
            gMask[id] |= 1 << uint256(uint8(kind));
            if (kind == IAttestationOracle.AttestationKind.AssignmentExecuted) gAssignmentPayload[id] = payload;
            if (kind == IAttestationOracle.AttestationKind.UCCFiled) gUccPayload[id] = payload;
        }
    }

    /// @dev Positive-control documentary attestation. The ordinary `_satisfyKind` action
    /// intentionally carries arbitrary payloads so P-32's binding limb is reachable;
    /// full-gate seed shapes use this bound variant to remain admissible.
    function _satisfyBoundKind(uint256 id, IAttestationOracle.AttestationKind kind) private {
        bytes32 payload = keccak256(abi.encode(_termsOf(plans[id])));
        if (_attestRaw(id, kind, payload)) {
            gMask[id] |= 1 << uint256(uint8(kind));
            if (kind == IAttestationOracle.AttestationKind.AssignmentExecuted) gAssignmentPayload[id] = payload;
            if (kind == IAttestationOracle.AttestationKind.UCCFiled) gUccPayload[id] = payload;
        }
    }

    function _attestTerms(uint256 id, bool bindToPlan) private {
        _ensurePlan(id);
        bytes32 payload = bindToPlan
            ? keccak256(abi.encode(_termsOf(plans[id])))
            : keccak256(abi.encode("divergent", id, nonceCounter));
        if (_attestRaw(id, IAttestationOracle.AttestationKind.CreditIssued, payload)) {
            gMask[id] |= BIT_CREDIT;
            gTerms[id] = payload;
        }
    }

    function _attestValuation(uint256 id, uint256 value) private {
        if (value == 0) value = 1e18;
        uint64 floorAsOf = gWatermark[id];
        if (gMarkAsOf[id] > floorAsOf) floorAsOf = gMarkAsOf[id];
        if (uint64(block.timestamp) <= floorAsOf) return; // a strictly newer mark is impossible now
        if (_attestRaw(id, IAttestationOracle.AttestationKind.Valuation, bytes32(value))) {
            gMask[id] |= BIT_VALUATION;
            gMarkValue[id] = value;
            gMarkAsOf[id] = uint64(block.timestamp);
            gWatermark[id] = uint64(block.timestamp);
        }
    }

    function _satisfyFullGate(uint256 id, bool bindTerms) private {
        _ensurePlan(id);
        _satisfyBoundKind(id, IAttestationOracle.AttestationKind.AssignmentExecuted);
        if (plans[id].classId == CLASS_FILM) {
            _satisfyBoundKind(id, IAttestationOracle.AttestationKind.UCCFiled);
        } else {
            _attestValuation(id, plans[id].principal * Config.BPS / plans[id].ltvBps + 1e18);
        }
        _attestTerms(id, bindTerms);
    }

    function _facilityWithWatermark(uint256 seed) private view returns (uint256) {
        uint256 upper = w.bridge.totalOriginated() + 2;
        // reduce BEFORE adding: `seed` is a raw fuzz word and `seed + i` overflows at the
        // top of the range (this cost one campaign to a panic under fail_on_revert = true).
        uint256 start = seed % upper;
        for (uint256 i = 0; i < upper; ++i) {
            uint256 id = 1 + ((start + i) % upper);
            if (gWatermark[id] != 0 || gMarkAsOf[id] != 0) return id;
        }
        return 0;
    }

    // =====================================================================
    //  internals: planning and terms
    // =====================================================================

    function _plan(uint256 classId, bytes32 b, bytes32 s, uint256 principal) private {
        uint256 id = w.bridge.totalOriginated() + 1;
        uint64 maxMaturity = classId == CLASS_FILM ? FILM_MAX_MATURITY : DIGITAL_MAX_MATURITY;
        uint64 maturity = uint64(block.timestamp) + maxMaturity / 2;
        plans[id] = Plan({
            classId: classId,
            borrowerId: b,
            stateId: s,
            principal: principal,
            ltvBps: classId == CLASS_FILM ? FILM_LTV_BPS : DIGITAL_LTV_BPS,
            maturity: maturity,
            nextPaymentDue: uint64(block.timestamp) + PAYMENT_INTERVAL,
            planned: true
        });
    }

    function _ensurePlan(uint256 id) private {
        if (plans[id].planned) return;
        uint64 maturity = uint64(block.timestamp) + FILM_MAX_MATURITY / 2;
        plans[id] = Plan({
            classId: CLASS_FILM,
            borrowerId: B1,
            stateId: S1,
            principal: 100_000e18,
            ltvBps: FILM_LTV_BPS,
            maturity: maturity,
            nextPaymentDue: uint64(block.timestamp) + PAYMENT_INTERVAL,
            planned: true
        });
    }

    function _termsOf(Plan memory p) private view returns (ClaimBridge.OriginationTerms memory t) {
        t = ClaimBridge.OriginationTerms({
            classId: p.classId,
            borrowerId: p.borrowerId,
            stateId: p.stateId,
            principal: p.principal,
            ltvBps: p.ltvBps,
            interestRateBps: RATE_BPS,
            maturity: p.maturity,
            fundingRecipient: a.borrower,
            paymentInterval: PAYMENT_INTERVAL,
            nextPaymentDue: p.nextPaymentDue,
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: SCHEDULE_HASH,
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: OFFCHAIN_REF
        });
    }

    function _filmParams(uint16 concBps) private pure returns (ICollateralRegistry.ClassParams memory) {
        return ICollateralRegistry.ClassParams({
            name: "Film & TV Tax Credits",
            model: ICollateralRegistry.CollateralModel.Receivable,
            active: true,
            maxLtvBps: FILM_MAX_LTV_BPS,
            maxMaturity: FILM_MAX_MATURITY,
            concentrationLimitBps: concBps,
            marginCallLtvBps: 0,
            liquidationLtvBps: 0,
            maxMarkAge: 0
        });
    }

    // =====================================================================
    //  internals: lifecycle drivers
    // =====================================================================

    function _fundFacility(uint256 id) private {
        FacRec storage f = facs[id];
        if (f.state != FacState.Pending) return;
        uint256 need = f.principal / 1e12;
        if (w.reserves.idleUSDC() < need) return;
        if (w.waterfall.paused() || w.bridge.paused()) return;
        vm.prank(a.servicer);
        (bool ok,) = address(w.waterfall).call(abi.encodeCall(WaterfallEngine.fund, (id, need)));
        if (!ok) return;
        f.state = FacState.Active;

        // AUDIT G11/G12.3 — THE DOUBLE-RELEASE PROBE, fired in the same transaction as the
        // legitimate funding it follows: pay one facility's principal out of reserves TWICE.
        //
        // Why here and not in `probeEscrowReleaseWithoutNft`: the standalone probe is usually
        // answered by `checkFundable`'s FRESHNESS checks (`Bridge_FacilityMatured`, or
        // `Bridge_BadFacility` once `nextPaymentDue` has passed) long before the fundable-state
        // gate is consulted, so it exercises the wrong guard. Here every other condition is
        // provably still satisfied because the identical call succeeded microseconds ago: same
        // block, same marks, same attestations, same principal, budget re-checked above.
        //
        // MEASURED, and worth knowing: with `Waterfall_NotFundable` AND `Bridge_NotPending` both
        // deleted this call is still refused — by `ClaimBridge.transitionState`'s state machine
        // rejecting Active -> Active. But that rejection happens AFTER
        // `ReserveManager.recordDeployment` has already transferred the stablecoins, so only the
        // transaction-level revert puts them back. That is why this probe asserts RESERVE
        // CONSERVATION (`escrowLeaks`) as well as refusal: "it reverted" and "no money moved" are
        // not the same statement on this path.
        //
        // DO NOT move this probe out of `_fundFacility` or let time pass before it fires. Its
        // whole value is that it runs while nothing else can answer.
        if (w.reserves.idleUSDC() < need) return; // no budget left: a refusal here would be unearned
        uint256 idleBefore = w.reserves.idleUSDC();
        uint256 deployedBefore = w.reserves.deployedPrincipal();
        Verdict v = _fireAtGuard(
            G_ESCROW_NOT_PENDING, a.servicer, address(w.waterfall), abi.encodeCall(WaterfallEngine.fund, (id, need))
        );
        escrowProbeAttempts++;
        if (w.reserves.idleUSDC() != idleBefore || w.reserves.deployedPrincipal() != deployedBefore) escrowLeaks++;
        assertTrue(v != Verdict.Admitted, "ESCROW RELEASED TWICE FOR ONE FACILITY");
    }

    function _declareDefaultOn(uint256 id) private {
        FacRec storage f = facs[id];
        if (f.state != FacState.Active || w.oracle.paused()) return;
        bytes32 evidence = OFFCHAIN_REF;
        if (!_attestRaw(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, evidence)))) {
            return;
        }
        vm.prank(a.servicer);
        (bool ok,) = address(w.defaultManager).call(abi.encodeCall(DefaultManager.declareDefault, (id, evidence)));
        if (ok) {
            f.state = FacState.Defaulted;
            defaultedIds.push(id);
        }
    }

    function _giveAndMintUSDfr(address who, uint256 usdcUnits) private {
        w.usdc.mint(who, usdcUnits);
        vm.startPrank(who);
        w.usdc.approve(address(w.controller), usdcUnits);
        (bool ok,) = address(w.controller).call(abi.encodeCall(MintRedeemController.mint, (usdcUnits)));
        vm.stopPrank();
        ok;
    }

    // =====================================================================
    //  internals: the unauthorised probe table
    // =====================================================================

    function _unauthorisedActor(uint256 seed) private view returns (address) {
        uint256 pick = seed % 4;
        if (pick == 0) return a.outsider;
        if (pick == 1) return address(this);
        if (pick == 2) return a.borrower;
        return a.custodian;
    }

    function _recordProbeState() private {
        bool anyPaused = w.bridge.paused() || w.oracle.paused() || w.queue.paused() || w.curator.paused()
            || w.waterfall.paused() || w.controller.paused() || w.vault.paused();
        if (anyPaused) ghostProbesWhilePaused++;
        else ghostProbesWhileUnpaused++;
        if (defaultedIds.length != 0) ghostProbesWithLiveDefault++;
        if (w.queue.isSettling()) ghostProbesWhileSettling++;
        if (w.queue.totalQueuedShares() != 0) ghostProbesWithQueuedRequests++;
        if (w.vault.totalAssets() != 0) ghostProbesWithFundedVault++;
    }

    /// @dev The 29 privileged entry points, one per access-control edge that matters. Each
    ///      is chosen so that the SAME call from its authorised holder would succeed, which
    ///      is what `authorisedControl` demonstrates for a representative subset.
    function _probe(uint256 idx, address actor) private view returns (address target, bytes memory data) {
        if (idx == 0) return (address(w.bridge), abi.encodeCall(ClaimBridge.pause, ()));
        if (idx == 1) {
            return
                (address(w.bridge), abi.encodeCall(ClaimBridge.setRequiredMintAttestations, (CLASS_FILM, BIT_CREDIT)));
        }
        if (idx == 2) {
            Plan memory p = plans[1].planned ? plans[1] : _defaultPlan();
            return (address(w.bridge), abi.encodeCall(ClaimBridge.originate, (a.custodian, _termsOf(p))));
        }
        if (idx == 3) {
            return (address(w.bridge), abi.encodeCall(ClaimBridge.transitionState, (1, ClaimBridge.LoanState.Active)));
        }
        if (idx == 4) return (address(w.registry), abi.encodeCall(CollateralRegistry.setBorrowerLimit, (500)));
        if (idx == 5) {
            return (
                address(w.registry),
                abi.encodeCall(CollateralRegistry.recordExposureIncrease, (CLASS_FILM, B1, S1, 1e18))
            );
        }
        if (idx == 6) {
            return (
                address(w.oracle),
                abi.encodeCall(AttestationOracle.setThreshold, (IAttestationOracle.AttestationKind.CreditIssued, 2))
            );
        }
        if (idx == 7) {
            return (
                address(w.oracle),
                abi.encodeCall(AttestationOracle.consume, (1, IAttestationOracle.AttestationKind.CreditIssued))
            );
        }
        if (idx == 8) return (address(w.usdfr), abi.encodeCall(USDfr.mint, (actor, 1e18)));
        if (idx == 9) return (address(w.usdfr), abi.encodeCall(USDfr.burn, (a.user, 1)));
        if (idx == 10) return (address(w.controller), abi.encodeCall(MintRedeemController.mintYield, (actor, 1e18)));
        if (idx == 11) {
            return (address(w.controller), abi.encodeCall(MintRedeemController.burnLoss, (address(w.vault), 1)));
        }
        if (idx == 12) return (address(w.reserves), abi.encodeCall(ReserveManager.releaseUSDC, (actor, 1)));
        if (idx == 13) return (address(w.reserves), abi.encodeCall(ReserveManager.writeDownIdleUSDC, (1e18)));
        if (idx == 14) return (address(w.reserves), abi.encodeCall(ReserveManager.recordPrincipalWritedown, (1, 1)));
        if (idx == 15) return (address(w.vault), abi.encodeCall(SUSDfr.setRedemptionQueue, (actor)));
        if (idx == 16) return (address(w.vault), abi.encodeCall(SUSDfr.notifyYield, (1)));
        if (idx == 17) return (address(w.vault), abi.encodeCall(SUSDfr.setPerformanceFee, (0)));
        if (idx == 18) return (address(w.queue), abi.encodeCall(RedemptionQueue.setEpochLiquidityBps, (0)));
        if (idx == 19) return (address(w.waterfall), abi.encodeCall(WaterfallEngine.fund, (1, 1)));
        if (idx == 20) {
            return (address(w.defaultManager), abi.encodeCall(DefaultManager.realizeLoss, (1, 1, OFFCHAIN_REF)));
        }
        if (idx == 21) return (address(w.curator), abi.encodeCall(CuratorModule.absorbLoss, (CLASS_FILM, 1)));
        if (idx == 22) return (address(w.compliance), abi.encodeCall(ComplianceRegistry.setAllowed, (actor, true)));
        if (idx == 23) {
            return (address(w.bridge), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", dummyImpl, bytes("")));
        }
        if (idx == 24) {
            return (address(w.vault), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", dummyImpl, bytes("")));
        }
        if (idx == 25) {
            return (address(w.usdfr), abi.encodeWithSignature("grantRole(bytes32,address)", Roles.MINTER_ROLE, actor));
        }
        if (idx == 26) {
            return
                (address(w.bridge), abi.encodeWithSignature("grantRole(bytes32,address)", Roles.UPGRADER_ROLE, actor));
        }
        if (idx == 27) {
            return (address(w.curator), abi.encodeCall(CuratorModule.setCuratorApproved, (CLASS_FILM, actor, true)));
        }
        return (address(w.defaultManager), abi.encodeCall(DefaultManager.setBackstop, (actor)));
    }

    function _defaultPlan() private view returns (Plan memory) {
        return Plan({
            classId: CLASS_FILM,
            borrowerId: B1,
            stateId: S1,
            principal: 100_000e18,
            ltvBps: FILM_LTV_BPS,
            maturity: uint64(block.timestamp) + 100 days,
            nextPaymentDue: uint64(block.timestamp) + PAYMENT_INTERVAL,
            planned: true
        });
    }

    // =====================================================================
    //  internals: misc
    // =====================================================================

    function _borrowerOf(uint256 seed) private pure returns (bytes32) {
        uint256 pick = seed % 3;
        if (pick == 0) return B1;
        if (pick == 1) return B2;
        return B3;
    }

    function _stateOf(uint256 seed) private pure returns (bytes32) {
        uint256 pick = seed % 3;
        if (pick == 0) return S1;
        if (pick == 1) return S2;
        return bytes32(0);
    }

    // NOTE (AUDIT G11/G12.3): the local `_selectorOf` was removed when this handler was rebased
    // onto `GuardProbe`, which provides an identical `internal pure` one — same 0xffffffff
    // sentinel for an undecodable revert, so `bytes4(0)` ("must be admitted") cannot collide.
}
