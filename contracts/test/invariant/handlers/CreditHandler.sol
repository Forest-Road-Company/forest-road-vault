// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ClaimBridge} from "../../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../../../src/ComplianceRegistry.sol";
import {CuratorModule} from "../../../src/CuratorModule.sol";
import {DefaultManager} from "../../../src/DefaultManager.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {WaterfallEngine} from "../../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../../src/interfaces/IAttestationOracle.sol";
import {IWaterfallEngine} from "../../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MockAttestationOracle} from "../../helpers/MockAttestationOracle.sol";
import {MockCascadeBackstop} from "../../helpers/MockCascadeBackstop.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

/// @dev Bounded handler for CREDIT-LAYER stateful fuzzing over the FULL protocol stack
///      (production role topology; no test-era EOA credit grants). `fail_on_revert =
///      true`: every path is bounded so it can never revert — a revert IS a finding.
///
///      Two verification styles combine here:
///      - PER-CALL DIFFERENTIAL ASSERTS: repay/realizeLoss recompute the
///        expected split from an independent model and assert the contract matched it
///        exactly (cascade ordering, waterfall conservation) at every single call.
///      - GHOST ACCUMULATORS read by the invariant functions between calls.
///
///      Facilities are film-class (receivable). The MTM margin path's state machine is
///      exhaustively unit/integration-tested; cascade and waterfall accounting are
///      class-agnostic (realizeLoss/ distribute run the same code for every class).
contract CreditHandler is Test {
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ComplianceRegistry internal compliance;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    CollateralRegistry internal registry;
    ClaimBridge internal bridge;
    MockAttestationOracle internal oracle;
    CuratorModule internal curator;
    WaterfallEngine internal waterfall;
    DefaultManager internal defaultManager;
    MockCascadeBackstop internal backstop;

    address internal servicer;
    address internal anchorCurator;
    address internal originator;
    address internal custodian;
    address internal feeRecipient;
    address internal borrower;

    /// @dev The vault's timelocked DEFAULT_ADMIN_ROLE holder, for the H-3 re-tune action.
    address internal vaultAdmin;

    address[3] public actors;
    uint256[] public facilities;
    uint256 internal constant MAX_FACILITIES = 6;
    uint256 internal constant UNIT = 1e12; // whole-USDC alignment

    // ── ghost state ──────────────────────────────────────────────────────
    uint256 public rateFloor; // resets on explicit depositor loss or evented vault-fee dilution
    uint256 public ghostPendingPrincipal; // originated, not yet funded
    uint256 public ghostInterestDistributed;
    uint256 public ghostFees;
    uint256 public ghostVaultYield;
    uint256 public ghostDepositorLosses;
    /// @dev PM-R-11 reach telemetry: how many times `stressCoverageFloor` actually reached the
    ///      drained-then-refilled coverage state (not merely how often it was called).
    uint256 public ghostFloorDrains;
    /// @dev H-2 model input: principal RECOVERED IN CASH on a still-defaulted facility since the
    ///      last point at which `DefaultManager` re-anchored its contribution to `deployedTo`
    ///      (declare, or any `realizeLoss`). Tracked here, from the handler's own calls, so
    ///      `invariant_pendingImpairmentNeverOverMarks` never reads the contract's own
    ///      `defaultedContribution` — the blindness that let H-2 survive five audit rounds.
    mapping(uint256 tokenId => uint256) public ghostUnsyncedRecovery;
    // ── AUDIT FIX H-5 past-due ghost state (mirrors the contract's `pastDueMarked` flag, which
    //    has NO external accessor). The contract's past-due pool is a value-moving INPUT to
    //    `pendingSeniorImpairment` (the conservative-NAV / backing path, CLAUDE.md §1.3), so the
    //    invariants must recompute it INDEPENDENTLY. The membership set lives here; the values the
    //    invariants read come from ReserveManager (`deployedTo`) and this handler's OWN mark-time
    //    snapshot — never `DefaultManager.pastDueContribution`/`pastDuePrincipal`.
    //
    //    The flag is kept in EXACT lockstep with the contract: the contract sets it ONLY in
    //    `markPastDue` and clears/lowers it ONLY through `_releasePastDue` and `onPerformingRepayment`
    //    -- reached from `clearPastDue`, from `declareDefault` when it CONVERTS a past-due facility,
    //    and (re-audit MEDIUM) from `WaterfallEngine.distribute` on a PERFORMING repayment (a full
    //    repayment auto-releases the flag; a partial paydown re-anchors the contribution DOWN). Every
    //    one of those contract paths is driven from this handler, and each mirrors the flag/snapshot
    //    here (see `_syncPastDueGhostOnDeclare` / `_syncPastDueGhostOnRepay`), so `_pastDueFlag` never
    //    diverges from `pastDueMarked` on the clean build. (A mutation that breaks `_releasePastDue` or
    //    `onPerformingRepayment` makes the contract diverge from this ghost on purpose - which is
    //    exactly what the over-marks invariant then catches.)
    mapping(uint256 tokenId => bool) internal _pastDueFlag;
    // Per-facility at-risk principal, the OVER-marks ceiling term. Seeded at MARK TIME from
    // ReserveManager (== the contract's `pastDueContribution` then), and re-anchored DOWN by
    // `_syncPastDueGhostOnRepay` on every performing paydown (re-audit MEDIUM), mirroring the
    // contract's `onPerformingRepayment`. Read from ReserveManager / this ghost, NEVER from
    // `DefaultManager.pastDueContribution`, so it stays an INDEPENDENT recomputation that tracks the
    // contract's honest contribution term-for-term while the facility is flagged.
    mapping(uint256 tokenId => uint256) internal _pastDueSnapshot;
    /// @dev Past-due reach telemetry (reported in the invariant MEASURED REACH block).
    uint256 public ghostPastDueMarks; // successful `markPastDue` calls
    uint256 public ghostPastDueClears; // successful servicer `clearPastDue` calls
    uint256 public ghostPastDueConversions; // past-due facilities converted by `declareDefault`
    // Re-audit MEDIUM: a performing repayment now cures the past-due mark via `onPerformingRepayment`.
    uint256 public ghostPastDueAutoReleases; // full performing repayment auto-cleared the flag
    uint256 public ghostPastDueReanchors; // partial performing paydown re-anchored the mark DOWN
    uint256 public callCount;

    constructor(
        address[6] memory tokenLayer, // usdc, usdfr, compliance, reserves, controller, vault
        address[6] memory creditLayer, // registry, bridge, oracle, curator, waterfall, defaultManager
        address backstop_,
        address[6] memory roles_, // servicer, anchorCurator, originator, custodian, feeRecipient, borrower
        address complianceAdmin_
    ) {
        usdc = MockERC20(tokenLayer[0]);
        usdfr = USDfr(tokenLayer[1]);
        compliance = ComplianceRegistry(tokenLayer[2]);
        reserves = ReserveManager(tokenLayer[3]);
        controller = MintRedeemController(tokenLayer[4]);
        vault = SUSDfr(tokenLayer[5]);
        registry = CollateralRegistry(creditLayer[0]);
        bridge = ClaimBridge(creditLayer[1]);
        oracle = MockAttestationOracle(creditLayer[2]);
        curator = CuratorModule(creditLayer[3]);
        waterfall = WaterfallEngine(creditLayer[4]);
        defaultManager = DefaultManager(creditLayer[5]);
        backstop = MockCascadeBackstop(backstop_);
        servicer = roles_[0];
        anchorCurator = roles_[1];
        originator = roles_[2];
        custodian = roles_[3];
        feeRecipient = roles_[4];
        borrower = roles_[5];

        actors[0] = makeAddr("creditActor0");
        actors[1] = makeAddr("creditActor1");
        actors[2] = makeAddr("creditActor2");
        vm.startPrank(complianceAdmin_);
        for (uint256 i = 0; i < 3; ++i) {
            compliance.setAllowed(actors[i], true);
        }
        vm.stopPrank();
        rateFloor = vault.currentExchangeRate();
    }

    // ── internal helpers ─────────────────────────────────────────────────

    function _mintTo(address who, uint256 amount18) internal {
        usdc.mint(who, amount18 / UNIT);
        vm.startPrank(who);
        usdc.approve(address(controller), amount18 / UNIT);
        controller.mint(amount18 / UNIT);
        vm.stopPrank();
    }

    /// @dev A checkpointed protocol fee is the second documented way the fee-net rate
    ///      can decline. Only an actual increase in the configured recipient's sUSDfr
    ///      balance can reset the floor here; arbitrary share dilution cannot.
    function _acceptAccruedFeeDilution(uint256 feeSharesBefore) internal {
        if (vault.balanceOf(vault.feeRecipient()) > feeSharesBefore) {
            rateFloor = vault.currentExchangeRate();
        }
    }

    /// @dev Crystallize every legitimately pending fee before an operation whose junior-capital
    ///      write must itself be performance-fee neutral. The returned balance is an independent
    ///      no-mint witness: the operation cannot hide a phantom mint by rebasing `rateFloor`.
    function _checkpointBeforeFeeNeutralWrite() internal returns (uint256 feeSharesAfterCheckpoint) {
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vault.accrueFees();
        _acceptAccruedFeeDilution(feeSharesBefore);
        return vault.balanceOf(vault.feeRecipient());
    }

    function _state(uint256 tokenId) internal view returns (ClaimBridge.LoanState) {
        return bridge.facility(tokenId).state;
    }

    function _isLive(ClaimBridge.LoanState s) internal pure returns (bool) {
        return s == ClaimBridge.LoanState.Active || s == ClaimBridge.LoanState.Amortizing;
    }

    function _isDefaulted(ClaimBridge.LoanState s) internal pure returns (bool) {
        return s == ClaimBridge.LoanState.Defaulted || s == ClaimBridge.LoanState.Accelerated;
    }

    // ── bounded operations ───────────────────────────────────────────────

    function depositAndStake(uint256 actorSeed, uint256 amount) external {
        // AUDIT H-3 (remediation + residual): the vault CLOSES to new capital in the DEGENERATE
        // state — the deposit base collapsed to zero, or dwarfed by the stranded unvested-yield
        // stream (reachable from this very handler via a maximal `realizeLoss`, which is how the
        // fuzzer first found it). Entry there would mint against a base about to grow under the
        // entrant; the vault reverts `SUSDfr_DegenerateSharePrice` and the state is asserted by
        // `invariant_degenerateVaultIsClosedToNewCapital`. Skip rather than revert, per
        // `fail_on_revert = true`.
        if (vault.maxDeposit(address(this)) == 0) return;
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1, 5_000_000e6);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(controller), amount);
        controller.mint(amount);
        usdfr.approve(address(vault), amount * UNIT);
        vault.deposit(amount * UNIT, actor);
        vm.stopPrank();
        _acceptAccruedFeeDilution(feeSharesBefore);
        callCount++;
    }

    function originate(uint256 borrowerSeed, uint256 stateSeed, uint256 principal) external {
        if (facilities.length >= MAX_FACILITIES) return;
        principal = bound(principal, 1e18, 2_000_000e18);
        principal -= principal % UNIT;
        bytes32 borrowerId = borrowerSeed % 2 == 0 ? keccak256("fuzz-borrower-A") : keccak256("fuzz-borrower-B");
        bytes32 stateId = stateSeed % 2 == 0 ? keccak256("US-GA") : keccak256("US-NV");

        // AUDIT FIX M-02 (round 2): concentration limits are a real admission control at
        // every book size now — a two-borrower fuzz book genuinely hits the 1500bps
        // per-borrower cap. Bound the input to what the registry will admit rather than
        // letting a legitimate rejection revert the handler (fail_on_revert = true).
        uint256 room = registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, borrowerId, stateId);
        if (principal > room) principal = room - (room % UNIT);
        if (principal == 0) return;

        uint256 nextId = bridge.totalOriginated() + 1;
        uint64 maturity = uint64(block.timestamp + 365 days);
        ClaimBridge.OriginationTerms memory terms = ClaimBridge.OriginationTerms({
            classId: Config.CLASS_FILM_TAX_CREDITS,
            borrowerId: borrowerId,
            stateId: stateId,
            principal: principal,
            ltvBps: 7500,
            interestRateBps: 1400,
            maturity: maturity,
            fundingRecipient: borrower,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("fuzz-schedule"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("fuzz-ucc-ref")
        });
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
        oracle.setSatisfied(nextId, IAttestationOracle.AttestationKind.UCCFiled, true);
        // AUDIT FIX (H-4): the CreditIssued payload must commit to these exact terms.
        oracle.setPayload(
            nextId,
            IAttestationOracle.AttestationKind.CreditIssued,
            bridge.creditTermsHash(terms),
            uint64(block.timestamp),
            true
        );
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        facilities.push(id);
        ghostPendingPrincipal += principal;
        callCount++;
    }

    function fund(uint256 facSeed) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        if (_state(id) != ClaimBridge.LoanState.Pending) return;
        // Funding revalidates every time-sensitive origination term. A pending facility can
        // become unfundable while the fuzzer advances time either because it matured or because
        // its first payment date passed. Respect both production preconditions rather than
        // turning a correct fail-closed rejection into a `fail_on_revert` invariant failure.
        ClaimBridge.Facility memory facility = bridge.facility(id);
        if (block.timestamp >= facility.maturity || block.timestamp >= facility.nextPaymentDue) return;
        uint256 principal = facility.principal;
        // seed exactly the idle liquidity the deployment needs
        _mintTo(actors[0], principal);
        uint256 feeBefore = usdfr.balanceOf(feeRecipient);
        vm.prank(servicer);
        waterfall.fund(id, principal / UNIT);
        // DIFF (ADR-0019): OID fee minted exactly; the claim stays the full principal
        uint256 expFee = (principal * waterfall.originationFeeBps(Config.CLASS_FILM_TAX_CREDITS) / 10_000) / UNIT * UNIT;
        assertEq(usdfr.balanceOf(feeRecipient) - feeBefore, expFee, "DIFF: origination fee");
        assertEq(reserves.deployedTo(id), principal, "DIFF: claim == full principal");
        ghostPendingPrincipal -= principal;
        callCount++;
    }

    struct RepayModel {
        uint256 outstanding;
        uint256 expFee;
        uint256 expToVault;
        uint256 feeBefore;
        uint256 vaultBefore;
        uint256 supplyBefore;
    }

    /// @dev Repayment with PER-CALL DIFFERENTIAL CHECK of the waterfall split.
    function repay(uint256 facSeed, uint256 interest, uint256 principal) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        ClaimBridge.LoanState st = _state(id);
        if (!_isLive(st) && !_isDefaulted(st)) return;

        RepayModel memory m;
        m.outstanding = reserves.deployedTo(id);
        interest = bound(interest, 0, 300_000e18);
        interest -= interest % UNIT;
        principal = bound(principal, 0, m.outstanding);
        principal -= principal % UNIT;
        if (interest == 0 && principal == 0) return;

        // independent expectation model (mirrors the spec, not the code path)
        m.expFee = interest * waterfall.protocolFeeBps() / 10_000;
        m.expToVault = interest - m.expFee;

        m.feeBefore = usdfr.balanceOf(feeRecipient);
        m.vaultBefore = usdfr.balanceOf(address(vault));
        m.supplyBefore = usdfr.totalSupply();
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());

        _executeRepayment(id, interest, principal, m.outstanding);
        _acceptAccruedFeeDilution(feeSharesBefore);

        assertEq(usdfr.balanceOf(feeRecipient) - m.feeBefore, m.expFee, "DIFF: fee split");
        assertEq(usdfr.balanceOf(address(vault)) - m.vaultBefore, m.expToVault, "DIFF: senior yield");
        assertEq(usdfr.totalSupply() - m.supplyBefore, interest, "DIFF: conservation in == out");
        assertEq(reserves.deployedTo(id), m.outstanding - principal, "DIFF: principal return");

        // H-2: cash principal returned on a DEFAULTED facility that `DefaultManager` has not been
        // told about (the WaterfallEngine has no hook on a partial recovery).
        if (_isDefaulted(st) && principal != 0) ghostUnsyncedRecovery[id] += principal;

        // H-5 (re-audit MEDIUM): `distribute` now calls `onPerformingRepayment` on BOTH performing
        // branches, re-anchoring a past-due facility's mark DOWN to live deployedTo (partial paydown)
        // or clearing it entirely (full repayment). Mirror that into the ghost past-due set so it
        // never goes STALE against the contract - the ceiling/floor impairment invariants read it.
        // `st` is the pre-call state, and distribute keys `performing` off exactly that, so
        // `_isLive(st) && principal != 0` matches precisely when `onPerformingRepayment` fires.
        if (_isLive(st) && principal != 0) _syncPastDueGhostOnRepay(id);

        ghostInterestDistributed += interest;
        ghostFees += m.expFee;
        ghostVaultYield += m.expToVault;
        callCount++;
    }

    function _executeRepayment(uint256 id, uint256 interest, uint256 principal, uint256 outstanding) internal {
        uint256 usdcAmount = (interest + principal) / UNIT;
        usdc.mint(borrower, usdcAmount);
        vm.prank(borrower);
        usdc.approve(address(reserves), usdcAmount);
        bytes32 paymentId = keccak256(abi.encode("fuzz-payment", id, callCount, interest, principal));
        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 nextDue = principal == outstanding ? 0 : f.nextPaymentDue + f.paymentInterval;
        if (nextDue > f.maturity) nextDue = f.maturity;
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256(abi.encode(paymentId, id, address(usdc), borrower, usdcAmount, interest, principal, nextDue)),
            uint64(block.timestamp),
            true
        );
        vm.prank(servicer);
        waterfall.distribute(
            IWaterfallEngine.Payment({
                tokenId: id,
                paymentId: paymentId,
                payer: borrower,
                interest: interest,
                principal: principal,
                nextPaymentDue: nextDue
            })
        );
    }

    function postFirstLoss(uint256 classSeed, uint256 amount) external {
        uint256 classId = classSeed % 2 == 0 ? Config.CLASS_FILM_TAX_CREDITS : Config.CLASS_RENEWABLE_ENERGY;
        amount = bound(amount, 1e12, 2_000_000e18);
        amount -= amount % UNIT;
        _mintTo(anchorCurator, amount);
        uint256 feeSharesAfterCheckpoint = _checkpointBeforeFeeNeutralWrite();
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
        assertEq(
            vault.balanceOf(vault.feeRecipient()),
            feeSharesAfterCheckpoint,
            "FEE-NEUTRAL CURATOR POST MINTED PROTOCOL SHARES"
        );
        callCount++;
    }

    /// @dev SUBORDINATION per-call check: a successful withdrawal never leaves the
    ///      pool below its requirement.
    function withdrawFirstLoss(uint256 classSeed, uint256 amount) external {
        uint256 classId = classSeed % 2 == 0 ? Config.CLASS_FILM_TAX_CREDITS : Config.CLASS_RENEWABLE_ENERGY;
        // AUDIT FIX (R4-EC2): a class with an unresolved default freezes withdrawals —
        // a legitimate precondition, so skip rather than revert under fail_on_revert.
        if (curator.unresolvedDefaults(classId) != 0) return;
        uint256 posted = curator.postedOf(classId, anchorCurator);
        uint256 free = curator.headroom(classId);
        uint256 max = posted < free ? posted : free;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        uint256 feeSharesAfterCheckpoint = _checkpointBeforeFeeNeutralWrite();
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(classId, amount);
        assertEq(
            vault.balanceOf(vault.feeRecipient()),
            feeSharesAfterCheckpoint,
            "FEE-NEUTRAL CURATOR WITHDRAWAL MINTED PROTOCOL SHARES"
        );
        // headroom capped the withdrawal, so the requirement MUST still be met:
        // capital protecting live exposure never leaves (senior never subordinated)
        assertGe(
            curator.poolBalance(classId),
            curator.requiredFirstLoss(classId),
            "SUBORDINATION: withdrawal broke the requirement"
        );
        callCount++;
    }

    function fundBackstop(uint256 amount) external {
        amount = bound(amount, 1e12, 1_000_000e18);
        _fundBackstop(amount);
        callCount++;
    }

    /// @dev PM-R-11 REACH BIAS. A deliberately SMALL coverage reserve, so an ordinary fuzzed
    ///      `realizeLoss` can plausibly exhaust it: the under-marking variants this suite hunts
    ///      only become observable once the reserve has been drawn to exactly zero while live
    ///      defaults still hold consumption, and a uniform draw over [1e-6, 1e6] USDfr
    ///      practically never leaves a balance a single loss event can clear.
    function fundBackstopSmall(uint256 amount) external {
        amount = bound(amount, UNIT, 2_000e18);
        _fundBackstop(amount);
        callCount++;
    }

    /// @dev AUDIT FIX (C-30). `MockCascadeBackstop.setCoverageCap` had ZERO callers anywhere in
    ///      the tree, so every mock-based campaign ran with the per-event cap at
    ///      `type(uint256).max` and `coverageCapacity()` degenerated to the raw balance. The
    ///      production per-event cap (PM-R-07 — cumulative per event, snapshotted at that
    ///      event's first draw) was therefore never exercised at a value that actually BINDS,
    ///      and the cascade invariants could not distinguish "layer 2 limited by capital" from
    ///      "layer 2 limited by the governed cap".
    ///
    ///      The bound deliberately spans both regimes: most draws land below the balance (the
    ///      cap binds, which is the untested case) while the upper end exceeds it (the cap is
    ///      slack, the previously-only regime). Changing the cap cannot corrupt an in-flight
    ///      event — the mock snapshots at first draw, mirroring `SGrove` — and
    ///      `_backstopRoomFor` already reads the cap, so the differential model stays exact.
    function setBackstopEventCap(uint256 seed) external {
        uint256 bal = usdfr.balanceOf(address(backstop));
        backstop.setCoverageCap(bound(seed, 1, bal == 0 ? UNIT : bal * 2));
        callCount++;
    }

    function declareDefault(uint256 facSeed) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        if (!_isLive(_state(id))) return;
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(id, bytes32(0))),
            uint64(block.timestamp),
            true
        );
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vm.prank(servicer);
        defaultManager.declareDefault(id, bytes32(0));
        _acceptAccruedFeeDilution(feeSharesBefore);
        ghostUnsyncedRecovery[id] = 0; // declare re-snapshots from `deployedTo`
        // H-5: `declareDefault` CONVERTS a past-due facility -- the contract's `_releasePastDue`
        // fires immediately before `_recordDefaulted`, so the facility leaves the past-due pool and
        // enters the declared pool, counted exactly once. Mirror the release here so the ghost set
        // never double-counts a converted facility across the two pools.
        _syncPastDueGhostOnDeclare(id);
        callCount++;
    }

    // ── Past-due accounting trigger (permissionless; H-5) ────────────────

    /// @dev H-5 REACH ACTION: flag a live receivable facility past due. `markPastDue` gates on
    ///      `block.timestamp > maturity + graceWindow` (maturity is ~365 days out, the grace window
    ///      is 21 days), and no ordinary action jumps time that far, so this action WARPS FORWARD to
    ///      the facility's grace end when needed -- the only reliable way to reach the past-due state
    ///      (the `warp` action tops out at 30 days). Time only ever moves forward, so this cannot
    ///      lower gross value (`invariant_exchangeRate_neverFallsWithoutLossOrFee`); it can, however,
    ///      strand OTHER not-yet-funded facilities past their maturity (`fund` skips a matured
    ///      facility), which is a deliberate, reported reach shift into the post-maturity regime.
    ///      Every precondition early-returns so the action is a clean no-op when it cannot fire
    ///      (`fail_on_revert = true`); with all preconditions met `markPastDue` cannot revert.
    /// @param facSeed Selects the facility to attempt to mark.
    function markPastDue(uint256 facSeed) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        // Receivable + live (Active/Amortizing) only. The handler originates class 1 (film), which is
        // Receivable, so `NotReceivable` cannot bite; `_isLive` guards `NotDefaultable`.
        if (!_isLive(_state(id))) return;
        // `_pastDueFlag` is in lockstep with the contract flag, so this guards `AlreadyPastDue`.
        if (_pastDueFlag[id]) return;
        // Nothing at risk to mark (fully repaid live facility): skip, keeps the pool meaningful.
        if (reserves.deployedTo(id) == 0) return;

        ClaimBridge.Facility memory f = bridge.facility(id);
        uint64 graceEnd = f.maturity + defaultManager.graceWindow(f.classId);
        if (block.timestamp <= graceEnd) {
            // forward-only warp to just past the grace end so the mark's time gate is satisfied
            vm.warp(uint256(graceEnd) + 1);
        }

        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        defaultManager.markPastDue(id);
        _acceptAccruedFeeDilution(feeSharesBefore);
        // record the ghost flag AND the mark-time snapshot (read from ReserveManager, independent of
        // the contract's `pastDueContribution`); `markPastDue` does not move `deployedTo`, so reading
        // it after the call still equals the contract's recorded snapshot.
        _pastDueFlag[id] = true;
        _pastDueSnapshot[id] = reserves.deployedTo(id);
        ghostPastDueMarks++;
        callCount++;
    }

    /// @dev H-5 REACH ACTION: the servicer clears a currently-flagged facility's past-due mark. Guard
    ///      on the ghost flag (== contract flag on the clean build) so `clearPastDue` never reverts
    ///      `NotPastDueMarked`. State-agnostic like the contract.
    /// @param facSeed Selects the facility to attempt to clear.
    function clearPastDue(uint256 facSeed) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        if (!_pastDueFlag[id]) return; // nothing flagged: clean no-op
        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(id, bytes32(0))),
            uint64(block.timestamp),
            true
        );
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vm.prank(servicer);
        defaultManager.clearPastDue(id, bytes32(0));
        _acceptAccruedFeeDilution(feeSharesBefore);
        _pastDueFlag[id] = false;
        _pastDueSnapshot[id] = 0;
        ghostPastDueClears++;
        callCount++;
    }

    /// @dev Mirror the contract's `_releasePastDue` when `declareDefault` converts a past-due
    ///      facility. Idempotent: a no-op for a facility that was not flagged, exactly like the
    ///      contract's guard. Called from every handler path that calls `declareDefault`.
    function _syncPastDueGhostOnDeclare(uint256 id) internal {
        if (_pastDueFlag[id]) {
            _pastDueFlag[id] = false;
            _pastDueSnapshot[id] = 0;
            ghostPastDueConversions++;
        }
    }

    /// @dev H-5 (re-audit MEDIUM). Mirror the contract's `onPerformingRepayment`, which
    ///      `WaterfallEngine.distribute` now calls on BOTH performing branches: it re-anchors a
    ///      past-due facility's contribution DOWN to live `reserves.deployedTo` on a partial paydown,
    ///      and fully clears the flag when the facility is repaid in full. Called from `repay` after a
    ///      performing distribution so this handler's ghost past-due set stays in lockstep with the
    ///      contract - exactly as `_syncPastDueGhostOnDeclare` mirrors the conversion in
    ///      `declareDefault`. It is INDEPENDENT of the contract's past-due state: it reads only
    ///      `reserves.deployedTo` (a different contract) and this handler's OWN ghost, so it models
    ///      the INTENDED behaviour. A mutation that neuters `onPerformingRepayment` therefore makes the
    ///      contract diverge from this ghost on purpose - which `invariant_pendingImpairmentNeverOver
    ///      Marks` then catches. A no-op when the facility is not flagged.
    function _syncPastDueGhostOnRepay(uint256 id) internal {
        if (!_pastDueFlag[id]) return;
        uint256 stillAtRisk = reserves.deployedTo(id);
        if (stillAtRisk == 0) {
            // repaid in full: the contract's full-repayment branch clears the flag entirely
            _pastDueFlag[id] = false;
            _pastDueSnapshot[id] = 0;
            ghostPastDueAutoReleases++;
        } else if (stillAtRisk < _pastDueSnapshot[id]) {
            // partial paydown: re-anchor the ghost snapshot DOWN to live at-risk, one-directional
            _pastDueSnapshot[id] = stillAtRisk;
            ghostPastDueReanchors++;
        }
    }

    function accelerate(uint256 facSeed) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        if (_state(id) != ClaimBridge.LoanState.Defaulted) return;
        vm.prank(servicer);
        defaultManager.accelerate(id);
        callCount++;
    }

    struct LossModel {
        uint256 poolBefore;
        uint256 backstopBefore;
        uint256 vaultBefore;
        uint256 supplyBefore;
        uint256 room;
        uint256 expAbsorbed;
        uint256 expCovered;
        uint256 expDepositor;
    }

    /// @dev THE CASCADE-ORDERING CHECK (CLAUDE.md §1.3), differential form: expected
    ///      layer splits are computed from pre-call balances with the spec's min-chain
    ///      and asserted exactly after the call — for every fuzzed loss event.
    function realizeLoss(uint256 facSeed, uint256 loss) external {
        if (facilities.length == 0) return;
        uint256 id = facilities[facSeed % facilities.length];
        if (!_isDefaulted(_state(id))) return;
        uint256 outstanding = reserves.deployedTo(id);
        if (outstanding == 0) return;

        {
            // scoped so the bounding locals leave the stack before `_realizeLossChecked`
            // is encoded -- without this the function is "stack too deep" under the
            // as-deployed optimizer settings.
            //
            // ADR-0023: layer 3 is bounded by the vault's VESTED assets, not its raw USDfr
            // balance — the balance also holds realized yield still streaming in, which is not
            // yet credited to any share and which `realizeLoss` deliberately refuses to burn.
            // Bounding the fuzzed loss the same way keeps the handler revert-free
            // (`fail_on_revert = true`) while still driving layer 3 to its true capacity.
            //
            // AUDIT FIX (PM-R-11 follow-up): layer 2's capacity is NOT the backstop's balance.
            // PM-R-07 made the cap cumulative PER EVENT and snapshotted at that event's first
            // draw, so what THIS facility can still draw is `snapshot - alreadyDrawn`. The
            // reference model used the raw balance, which was only ever right because the mock
            // still implemented the OLD per-call rule; once the mock was corrected to mirror the
            // real `SGrove`, this differential model was the thing that had gone stale, and the
            // cascade-ordering invariant went red. Bounding `capacity` by the room (not the
            // balance) also keeps the handler revert-free: an over-bound loss would push layer 3
            // past the vault's vested assets and revert `LossExceedsAbsorptionCapacity`.
            uint256 capacity = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS)
                + _backstopRoomFor(id, usdfr.balanceOf(address(backstop))) + vault.totalAssets();
            uint256 max = outstanding < capacity ? outstanding : capacity;
            if (max == 0) return;
            loss = bound(loss, 1, max);
        }
        _realizeLossChecked(id, loss);
        callCount++;
    }

    /// @dev The per-call cascade differential model, shared by every path in this handler that
    ///      realizes a loss. Expected layer splits are computed from pre-call balances with the
    ///      spec's min-chain and asserted exactly after the call. Callers MUST have bounded
    ///      `loss` so layer 3 stays within the vault's vested assets (`fail_on_revert = true`).
    /// @param id The defaulted facility.
    /// @param loss The loss to realize, in USDfr.
    function _realizeLossChecked(uint256 id, uint256 loss) internal {
        LossModel memory m;
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        m.poolBefore = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        m.backstopBefore = usdfr.balanceOf(address(backstop));
        m.vaultBefore = usdfr.balanceOf(address(vault));
        m.supplyBefore = usdfr.totalSupply();
        m.room = _backstopRoomFor(id, m.backstopBefore);

        // independent cascade model: strict layer ordering
        m.expAbsorbed = loss < m.poolBefore ? loss : m.poolBefore;
        m.expCovered = (loss - m.expAbsorbed) < m.room ? (loss - m.expAbsorbed) : m.room;
        m.expDepositor = loss - m.expAbsorbed - m.expCovered;

        oracle.setPayload(
            id,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(id, loss, bytes32(0))),
            uint64(block.timestamp),
            true
        );
        vm.prank(servicer);
        defaultManager.realizeLoss(id, loss, bytes32(0));
        // H-2: `_reduceDefaulted` re-anchors the contribution to `deployedTo` on every
        // realization, so nothing recovered before this point is unsynced any more.
        ghostUnsyncedRecovery[id] = 0;

        assertEq(
            m.poolBefore - curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS),
            m.expAbsorbed,
            "CASCADE: layer 1 (curator) not exact"
        );
        assertEq(
            m.backstopBefore - usdfr.balanceOf(address(backstop)), m.expCovered, "CASCADE: layer 2 (backstop) not exact"
        );
        assertEq(
            m.vaultBefore - usdfr.balanceOf(address(vault)), m.expDepositor, "CASCADE: layer 3 (depositors) not exact"
        );
        assertEq(m.supplyBefore - usdfr.totalSupply(), loss, "CASCADE: burns != loss");
        // ordering corollary: depositors lose ONLY when both junior layers are dry
        if (m.expDepositor > 0) {
            assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0, "CASCADE: skipped layer 1");
            // PM-R-11 follow-up: with a per-EVENT cap, "layer 2 is dry" means this EVENT's
            // room is exhausted — the reserve may still hold USDfr earmarked for other
            // events. Asserting a zero BALANCE here would be wrong, not merely stricter.
            assertEq(_backstopRoomFor(id, usdfr.balanceOf(address(backstop))), 0, "CASCADE: skipped layer 2");
            ghostDepositorLosses += m.expDepositor;
            rateFloor = vault.currentExchangeRate(); // explicit loss resets the fee-aware floor
        }
        _acceptAccruedFeeDilution(feeSharesBefore);
    }

    // ── PM-R-11 REACH: the drained-coverage-reserve state ────────────────
    //
    // `invariant_pendingImpairmentNeverUnderMarks` was mutation-tested against the three known
    // under-marking variants and originally caught two. Variant 3 — reading a ZERO capacity floor
    // as "unset", so the next draw after a refill re-seeds it at the new, larger capacity —
    // escaped because the campaign never reached a coverage reserve drawn to EXACTLY zero while
    // live defaults still held consumption. That state is not something random action sequencing
    // stumbles into. It needs, IN ORDER: every at-risk default snapshotted against the standing
    // reserve (an event that never drew can reach the whole refilled reserve, which would make
    // the invariant's honest floor as generous as a broken mark and hide the bug); the reserve
    // then spent to the LAST WEI, with one default deliberately holding a sliver of its per-event
    // room back; a refill larger than everything the live defaults have consumed plus everything
    // they can still reach; and finally that held-back sliver drawn — the draw a broken floor
    // mis-reads. `stressCoverageFloor` drives exactly that shape, through the real contracts,
    // under the same per-call cascade differential model as every other loss here. It scripts the
    // ORDER, never the accounting: every sub-step is a real `realizeLoss` by the real role, and
    // every expected split is still asserted exactly.
    //
    // Measured: 26 of 256 default-profile runs reach the state (`ghostFloorDrains`), and with it
    // all three variants die at the default profile. See the invariant's MEASURED REACH block.

    struct FloorStress {
        uint256 idA; // holds a sliver of per-event room back across the drain, and spends it after
        uint256 slice; // working reserve size when the campaign left the reserve empty
        uint256 balance;
        uint256 keepBack;
        uint256 reach; // coverage the live defaults can still reach once the reserve refills
        uint256 refill;
    }

    /// @notice PM-R-11 REACH ACTION: drive the coverage reserve to EXACTLY zero while live
    ///         defaults still hold consumption, refill it, then draw again.
    /// @dev Every sub-step is a real `realizeLoss` through the real role, checked by the same
    ///      differential cascade model as the fuzzed path. Every precondition early-returns —
    ///      nothing here may revert (`fail_on_revert = true`). A partial run leaves a perfectly
    ///      legitimate state; it simply does not reach the target shape that turn.
    /// @param aSeed Selects which live default holds room back across the drain.
    /// @param sliceSeed Sizes the working reserve when the campaign left the reserve empty.
    /// @param refillSeed Sizes the refill (bounded BELOW so the refilled capacity genuinely
    ///        exceeds consumption plus everything the live defaults can still reach — otherwise
    ///        the under-mark a broken floor produces is arithmetically invisible).
    function stressCoverageFloor(uint256 aSeed, uint256 sliceSeed, uint256 refillSeed) external {
        // The shape needs two live defaults. Declaring one is an ordinary fuzz action here, so
        // top up rather than waste the turn waiting for the sequencer to order it for us.
        _declareUntilTwoDefaults();
        (uint256[] memory ids, bool neutralisable) = _drawableDefaults();
        // A default that is still at risk but cannot take a loss can never spend its per-event
        // room down, and that untouchable room would make the invariant's independently
        // recomputed floor as generous as a broken one — skip rather than churn state for nothing.
        if (!neutralisable || ids.length < 2) return;
        // Layer 1 is consulted before layer 2 on every loss, so the class pool must be empty
        // for a loss to reach the backstop at all.
        if (!_drainCuratorPool(ids)) return;

        FloorStress memory s;
        s.slice = _sliceFor(ids, sliceSeed);
        if (s.slice == 0) return;

        // (1) Every live default takes a per-event snapshot against the standing reserve, so none
        //     is left able to reach the WHOLE refilled reserve later (an event that never drew
        //     reaches all of it, which would make the true floor as generous as a broken one).
        //     One that already drew is already snapshotted — leave its room alone.
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_snapshotCap(ids[i]) != 0) continue;
            if (usdfr.balanceOf(address(backstop)) == 0) _fundBackstop(s.slice);
            if (_drawUpTo(ids[i], UNIT) == 0) return;
        }
        // A holds a sliver of its per-event room back through the drain and spends it after the
        // refill — that post-refill draw is the one a broken floor mis-reads. Pick one that
        // still has room to hold back.
        s.idA = _pickHolder(ids, aSeed);
        if (s.idA == 0) return;
        // Guarantee the drain below is a real zeroing draw rather than a no-op on an already
        // empty reserve: only a draw that clamps to the last wei pins the capacity floor at zero.
        if (usdfr.balanceOf(address(backstop)) == 0) _fundBackstop(s.slice);

        // (2) Spend the reserve to EXACTLY zero: everyone but A first, then A for whatever is
        //     left — holding a sliver of A's snapshot back so it still has reach afterwards.
        //     `coverShortfall` clamps delivery to what the reserve holds, so the capacity
        //     standing after that last draw is exactly zero: the state variant 3 mis-reads as
        //     "no floor recorded yet" even though zero is a perfectly legitimate floor.
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == s.idA) continue;
            s.balance = usdfr.balanceOf(address(backstop));
            if (s.balance == 0) break;
            _drawUpTo(ids[i], s.balance);
        }
        s.balance = usdfr.balanceOf(address(backstop));
        if (s.balance != 0) {
            s.keepBack = _snapshotRoom(s.idA);
            if (s.keepBack <= UNIT) return;
            s.keepBack -= UNIT; // the sliver A must NOT spend yet
            if (_drawUpTo(s.idA, s.balance < s.keepBack ? s.balance : s.keepBack) == 0) return;
        }
        if (usdfr.balanceOf(address(backstop)) != 0) return;

        // (3) Refill. Sized above consumption plus everything EVERY at-risk default can still
        //     reach, so a re-seeded floor nets coverage no event can reach — i.e. an under-mark
        //     that the invariant's independent recomputation can actually see.
        {
            bool bounded;
            (s.reach, bounded) = _atRiskReach();
            if (!bounded) return; // some at-risk default could still reach the whole refill
            if (s.reach == 0) return; // nothing left to draw: a broken floor never gets to re-seed
            uint256 lo = defaultManager.liveDefaultCoverageConsumed() + 2 * s.reach + s.slice;
            if (lo > 50_000_000e18) return; // beyond what this handler will mint in one turn
            s.refill = bound(refillSeed, lo, lo + 1_000_000e18);
            _fundBackstop(s.refill);
        }

        // (4) The draw variant 3 mis-reads: the capacity floor is a legitimate ZERO, so a correct
        //     implementation keeps netting nothing, while the variant reads it as unset and
        //     re-seeds the floor at the refilled capacity — handing the live defaults coverage
        //     none of them can reach, and marking senior impairment below its true floor.
        for (uint256 i = 0; i < ids.length; ++i) {
            _drawUpTo(ids[i], type(uint256).max);
        }
        ghostFloorDrains++;
        callCount++;
    }

    /// @dev Declare defaults on live facilities until two are drawable, so the reach action is
    ///      not gated on the sequencer happening to order two `declareDefault`s before it.
    function _declareUntilTwoDefaults() internal {
        (uint256[] memory ids,) = _drawableDefaults();
        uint256 have = ids.length;
        for (uint256 i = 0; i < facilities.length && have < 2; ++i) {
            uint256 id = facilities[i];
            if (!_isLive(_state(id))) continue;
            if (reserves.deployedTo(id) <= UNIT) continue;
            oracle.setPayload(
                id,
                IAttestationOracle.AttestationKind.DefaultDeclared,
                keccak256(abi.encode(id, bytes32(0))),
                uint64(block.timestamp),
                true
            );
            uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
            vm.prank(servicer);
            defaultManager.declareDefault(id, bytes32(0));
            _acceptAccruedFeeDilution(feeSharesBefore);
            _syncPastDueGhostOnDeclare(id); // H-5: this declare may convert a past-due facility
            ++have;
        }
    }

    /// @dev Pick the default that holds per-event room back through the drain: it must have more
    ///      than the sliver it keeps, or there is nothing left for it to draw after the refill.
    /// @return holder The chosen facility, or 0 when none qualifies.
    function _pickHolder(uint256[] memory ids, uint256 seed) internal view returns (uint256 holder) {
        uint256 start = seed % ids.length;
        for (uint256 k = 0; k < ids.length; ++k) {
            uint256 id = ids[(start + k) % ids.length];
            if (_snapshotRoom(id) > UNIT) return id;
        }
        return 0;
    }

    /// @dev Coverage that EVERY still-at-risk default can reach once the reserve is refilled —
    ///      the same population the invariant's independent floor sums over, so the refill can be
    ///      sized above it.
    /// @return reach Total reachable coverage, unclamped by the (currently empty) reserve.
    /// @return bounded False when some at-risk default has never drawn: it would reach the whole
    ///         refilled reserve, which makes the true floor as generous as a broken mark.
    function _atRiskReach() internal view returns (uint256 reach, bool bounded) {
        bounded = true;
        for (uint256 i = 0; i < facilities.length; ++i) {
            uint256 id = facilities[i];
            if (!_isDefaulted(_state(id))) continue;
            if (defaultManager.defaultedContribution(id) == 0) continue;
            if (_snapshotCap(id) == 0) {
                bounded = false;
                continue;
            }
            reach += _snapshotRoom(id);
        }
    }

    /// @dev `eventId`'s per-event cap as snapshotted at its first draw; zero means it has never
    ///      drawn, so a fresh draw would snapshot against the whole reserve.
    function _snapshotCap(uint256 eventId) internal view returns (uint256 cap) {
        (, cap) = backstop.eventCoverage(eventId);
    }

    /// @dev What `eventId` could still draw against an unlimited reserve — its snapshotted cap
    ///      less what it has already drawn. Unlike `_backstopRoomFor` this is NOT clamped to the
    ///      reserve's current balance, which is what makes it the right measure of "reach" while
    ///      the reserve sits at zero.
    function _snapshotRoom(uint256 eventId) internal view returns (uint256 room) {
        (uint256 drawn, uint256 cap) = backstop.eventCoverage(eventId);
        room = cap > drawn ? cap - drawn : 0;
    }

    /// @dev Live defaults a loss can actually be realized against.
    /// @return ids Facilities in default that still contribute to the unrealized-impairment pool
    ///         AND still have outstanding principal.
    /// @return neutralisable False when some at-risk default can take no further loss (no
    ///         outstanding principal, or too little contribution left to stay at risk) AND has
    ///         never drawn: nothing can give it a per-event snapshot, so it would reach the whole
    ///         refilled reserve and make the invariant's independently recomputed floor as
    ///         generous as a broken mark. One that HAS drawn is already bounded by its snapshot,
    ///         so it is harmless — `_atRiskReach` prices it in.
    function _drawableDefaults() internal view returns (uint256[] memory ids, bool neutralisable) {
        uint256[] memory buf = new uint256[](facilities.length);
        uint256 n;
        neutralisable = true;
        for (uint256 i = 0; i < facilities.length; ++i) {
            uint256 id = facilities[i];
            if (!_isDefaulted(_state(id))) continue;
            if (defaultManager.defaultedContribution(id) == 0) continue;
            if (_lossCap(id) == 0) {
                if (_snapshotCap(id) == 0) neutralisable = false;
                continue;
            }
            buf[n] = id;
            ++n;
        }
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = buf[i];
        }
    }

    /// @dev The largest loss `id` can take while STAYING at risk (contribution > 0, so it keeps
    ///      holding its coverage consumption) and without exceeding its outstanding principal.
    function _lossCap(uint256 id) internal view returns (uint256 cap) {
        uint256 outstanding = reserves.deployedTo(id);
        uint256 contribution = defaultManager.defaultedContribution(id);
        uint256 keep = contribution > UNIT ? contribution - UNIT : 0;
        cap = outstanding < keep ? outstanding : keep;
        cap -= cap % UNIT;
    }

    /// @dev A working reserve size the live defaults can, between them, spend back to zero.
    function _sliceFor(uint256[] memory ids, uint256 seed) internal view returns (uint256 slice) {
        uint256 sumCap;
        for (uint256 i = 0; i < ids.length; ++i) {
            sumCap += _lossCap(ids[i]);
        }
        if (sumCap < 4 * UNIT) return 0;
        uint256 hi = sumCap < 100_000e18 ? sumCap : 100_000e18;
        slice = _bound(seed, 4 * UNIT, hi);
        slice -= slice % UNIT;
    }

    /// @dev Empty the film class's first-loss pool through real losses, so a subsequent loss
    ///      reaches layer 2 at all. Each loss here is fully absorbed by layer 1, so it never
    ///      touches the backstop or the depositors.
    /// @return drained True when the pool is empty (or already was).
    function _drainCuratorPool(uint256[] memory ids) internal returns (bool drained) {
        uint256 pool = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        for (uint256 i = 0; i < ids.length && pool != 0; ++i) {
            uint256 cap = _lossCap(ids[i]);
            uint256 loss = pool < cap ? pool : cap;
            if (loss == 0) continue;
            _realizeLossChecked(ids[i], loss);
            pool = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        }
        drained = pool == 0;
    }

    /// @dev Realize the loss that makes `id` draw as close to `want` from the backstop as its
    ///      per-event room, its outstanding principal and its remaining at-risk contribution
    ///      allow. Layer 1's standing balance is added on top so the requested amount is what
    ///      actually reaches layer 2, and layer 3 is never touched (covered == residual).
    /// @return drawn The coverage actually pulled from the backstop.
    function _drawUpTo(uint256 id, uint256 want) internal returns (uint256 drawn) {
        uint256 target;
        {
            uint256 room = _backstopRoomFor(id, usdfr.balanceOf(address(backstop)));
            target = want < room ? want : room;
            target -= target % UNIT;
            if (target == 0) return 0;
        }
        uint256 pool = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        uint256 cap = _lossCap(id);
        if (pool + target > cap) {
            if (cap <= pool) return 0;
            target = cap - pool;
            target -= target % UNIT;
            if (target == 0) return 0;
        }
        _realizeLossChecked(id, pool + target);
        return target;
    }

    /// @dev Mint USDfr against fresh stable and park it in the coverage reserve.
    function _fundBackstop(uint256 amount) internal {
        amount -= amount % UNIT;
        if (amount == 0) return;
        _mintTo(actors[1], amount);
        vm.prank(actors[1]);
        usdfr.transfer(address(backstop), amount);
    }

    /// @notice Number of originated facilities (so an invariant can enumerate them).
    function facilitiesLength() external view returns (uint256) {
        return facilities.length;
    }

    /// @notice The coverage `eventId` can still draw, per the PM-R-07 per-event rule. Public so
    ///         `invariant_pendingImpairmentNeverUnderMarks` can recompute the true floor.
    function backstopRoomFor(uint256 eventId) external view returns (uint256) {
        return _backstopRoomFor(eventId, usdfr.balanceOf(address(backstop)));
    }

    /// @notice True when the facility is Defaulted or Accelerated.
    function isDefaultedFacility(uint256 id) external view returns (bool) {
        return _isDefaulted(_state(id));
    }

    /// @notice True when the facility is currently flagged past due (H-5), per this handler's ghost
    ///         set (kept in lockstep with the contract's `pastDueMarked`). Mirrors the
    ///         `isDefaultedFacility` pattern so the impairment invariants can iterate.
    function isPastDueFacility(uint256 id) external view returns (bool) {
        return _pastDueFlag[id];
    }

    /// @notice A past-due facility's at-risk principal, the OVER-marks ceiling term (H-5). This is the
    ///         handler's OWN reading of `reserves.deployedTo` -- NEVER read from
    ///         `DefaultManager.pastDueContribution`. It starts at the mark-time snapshot and is
    ///         re-anchored DOWN by `_syncPastDueGhostOnRepay` on every performing paydown (re-audit
    ///         MEDIUM), mirroring the contract's `onPerformingRepayment`, so it tracks the contract's
    ///         honest contribution while the facility stays flagged - a tight, valid upper bound
    ///         computed independently of the contract. Zero if not flagged.
    function pastDueSnapshotOf(uint256 id) external view returns (uint256) {
        return _pastDueSnapshot[id];
    }

    /// @notice Independent per-class past-due principal (H-5): the sum of CURRENT
    ///         `reserves.deployedTo` over this handler's ghost set of past-due-flagged facilities in
    ///         `classId`. Read by `invariant_pendingImpairmentNeverUnderMarks` to build the floor's
    ///         past-due term from ReserveManager -- never from `DefaultManager.pastDuePrincipal`.
    ///         Using CURRENT `deployedTo` (a lower bound on the contract's mark-time snapshot, since
    ///         `deployedTo` only ever falls after a mark) keeps the recomputed floor a valid LOWER
    ///         bound on the contract's honest value.
    function pastDuePrincipalByClass(uint256 classId) external view returns (uint256 total) {
        for (uint256 i = 0; i < facilities.length; ++i) {
            uint256 id = facilities[i];
            if (!_pastDueFlag[id]) continue;
            if (bridge.facility(id).classId != classId) continue;
            total += reserves.deployedTo(id);
        }
    }

    /// @notice Number of facilities currently flagged past due (H-5 reach telemetry).
    function pastDueFlaggedCount() external view returns (uint256 n) {
        for (uint256 i = 0; i < facilities.length; ++i) {
            if (_pastDueFlag[facilities[i]]) ++n;
        }
    }

    /// @dev The coverage `eventId` can still draw, mirroring the real `SGrove` per-EVENT rule
    ///      (PM-R-07): the cap is snapshotted at the event's first draw and consumed
    ///      cumulatively, and is never more than the reserve actually holds.
    /// @param eventId The defaulted facility's tokenId (what DefaultManager passes through).
    /// @param bal The backstop's current USDfr balance.
    /// @return room The coverage still reachable by this event.
    function _backstopRoomFor(uint256 eventId, uint256 bal) internal view returns (uint256 room) {
        (uint256 drawn, uint256 snapshot) = backstop.eventCoverage(eventId);
        uint256 cap = snapshot;
        if (cap == 0) {
            uint256 perEvent = backstop.coverageCap();
            cap = bal < perEvent ? bal : perEvent;
        }
        room = cap > drawn ? cap - drawn : 0;
        if (room > bal) room = bal;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 30 days);
        vm.warp(block.timestamp + secs);
        callCount++;
    }

    /// @notice Wires the vault's timelocked admin so governance re-tunes can be fuzzed.
    /// @dev Called once from the invariant `setUp`; deliberately NOT in the fuzz selector set.
    /// @param who The DEFAULT_ADMIN_ROLE holder on the vault.
    function setVaultAdmin(address who) external {
        vaultAdmin = who;
    }

    /// @notice AUDIT H-3: a fuzzed timelocked yield-vesting re-tune.
    /// @dev The finding that produced this action: the predecessor to
    ///      `invariant_exchangeRate_neverFallsWithoutLossOrFee`
    ///      ran 32,768 calls clean while a governance re-tune dropped the rate 471 bps, because
    ///      NO handler action ever called a timelocked setter — the whole class of "governance
    ///      parameter writes are invisible to the invariant suite" was unmodelled. A re-tune is
    ///      continuity-preserving in both directions, and `period == 0` (the instant-credit
    ///      hatch) steps the rate UP, so the §1.3 monotonicity floor must survive every one.
    /// @param seed Fuzzed window, bounded to [0, MAX_YIELD_VESTING_PERIOD].
    function retuneYieldVesting(uint256 seed) external {
        uint64 period = uint64(bound(seed, 0, Config.MAX_YIELD_VESTING_PERIOD));
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vm.prank(vaultAdmin);
        vault.setYieldVestingPeriod(period);
        // per-call differential: a re-tune moves no value and may never lower the rate
        assertGe(vault.currentExchangeRate(), rateBefore, "H-3: A RE-TUNE LOWERED THE EXCHANGE RATE");
        assertEq(usdfr.balanceOf(address(vault)), heldBefore, "H-3: a re-tune moved USDfr");
        assertGe(usdfr.balanceOf(address(vault)), vault.unvestedYield(), "H-3: stream exceeds the balance");
        _acceptAccruedFeeDilution(feeSharesBefore);
        callCount++;
    }

    /// @notice Fuzzes the new prospective performance-fee governance parameter.
    /// @dev The setter must crystallize the old rate before installing the new one,
    ///      so the fee-net preview is continuous apart from integer-share rounding.
    function retunePerformanceFee(uint256 seed) external {
        uint16 feeBps = uint16(bound(seed, 0, Config.MAX_PERFORMANCE_FEE_BPS));
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vm.prank(vaultAdmin);
        vault.setPerformanceFee(feeBps);
        assertApproxEqAbs(
            vault.currentExchangeRate(), rateBefore, 1, "PERFORMANCE-FEE CHANGE REPRICED PAST PERFORMANCE"
        );
        assertEq(usdfr.balanceOf(address(vault)), heldBefore, "PERFORMANCE-FEE CHANGE MOVED USDfr");
        _acceptAccruedFeeDilution(feeSharesBefore);
        callCount++;
    }

    /// @notice Fuzzes the prospective annual management-fee parameter.
    /// @dev The setter checkpoints the old rate before installing the new rate. Warps
    ///      elsewhere in this handler then exercise the geometric `powWad` retention
    ///      path under a stateful, variable-rate sequence.
    function retuneManagementFee(uint256 seed) external {
        uint16 feeBps = uint16(bound(seed, 0, Config.MAX_MANAGEMENT_FEE_BPS));
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vm.prank(vaultAdmin);
        vault.setManagementFee(feeBps);
        assertApproxEqAbs(vault.currentExchangeRate(), rateBefore, 1, "MANAGEMENT-FEE CHANGE REPRICED ELAPSED TIME");
        assertEq(usdfr.balanceOf(address(vault)), heldBefore, "MANAGEMENT-FEE CHANGE MOVED USDfr");
        _acceptAccruedFeeDilution(feeSharesBefore);
        callCount++;
    }

    // ── reconciliation views ─────────────────────────────────────────────

    function facilityCount() external view returns (uint256) {
        return facilities.length;
    }

    function sumDeployed() external view returns (uint256 total) {
        for (uint256 i = 0; i < facilities.length; ++i) {
            total += reserves.deployedTo(facilities[i]);
        }
    }

    function sumCuratorPools() external view returns (uint256 total) {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            total += curator.poolBalance(c);
        }
    }

    function sumActorBalances() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += usdfr.balanceOf(actors[i]);
        }
        total += usdfr.balanceOf(anchorCurator);
        total += usdfr.balanceOf(borrower);
    }

    function sharePriceCapped() external view returns (bool ok) {
        ok = true;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            if (curator.poolShares(c) < curator.poolBalance(c)) ok = false;
        }
    }
}
