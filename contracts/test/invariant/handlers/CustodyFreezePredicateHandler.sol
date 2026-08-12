// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {GuardProbe} from "./GuardProbe.sol";

import {CuratorModule} from "../../../src/CuratorModule.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {ICuratorModule} from "../../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

/// @title CustodyFreezePredicateHandler — drives EVERY limb of the R6-CF1 freeze predicate INTO its
///        illegal region, one limb at a time, from every state the campaign reaches
///
/// @notice AUDIT FIX (F3-FREEZE-01). THE FINDING THIS EXISTS FOR, stated exactly:
///
///           "Two limbs of the freeze predicate are deletable with every test in the repository
///            green. The merged invariant tier is structurally blind to THREE of the four limbs of
///            the R6-CF1 freeze predicate and to the guardian pre-arm entirely."
///
///         WHY THE EXISTING CAMPAIGN WAS BLIND, precisely. `INV_CascadeSeniority` models the freeze
///         as `mCustodyIncidentOpen` — limb 1 alone — and its own handler comment says so: the
///         campaign "never latches a reserve deficit, never leaves a live USDC shortfall at rest,
///         and asserts `totalUSDfr() == backingValue()` at every custody loss". Those three
///         statements are exactly the statement that limbs 2, 3 and 4 are NEVER TRUE there. A
///         campaign that never enters a branch cannot falsify its deletion, however green it runs,
///         and `invariant_INV5_custodyFreezeMatchesIndependentModel` would happily agree with a
///         three-limb predicate forever. The guardian pre-arm had no stateful caller at all.
///
///         THE TECHNIQUE, and it is the one that has worked in this engagement (see `GuardProbe`):
///         register every guard UP FRONT, then drive inputs DELIBERATELY INTO the illegal region
///         rather than bounding them out of it, and let the REFUSAL be the asserted property. What
///         is added here on top of `GuardProbe` is ISOLATION:
///
///           every probe (1) asserts the system is at REST — all four reserve limbs provably off,
///           the reserve wired, no pre-arm standing; (2) moves EXACTLY ONE limb into its illegal
///           region; (3) records the guard's verdict; (4) moves that limb back out; (5) asserts
///           rest again.
///
///         Isolation is what makes a red ATTRIBUTABLE. A four-limb disjunction exercised in states
///         where several limbs are true at once is "covered" everywhere and deletable anywhere —
///         that is precisely how limb 2 survived: its only test also had limb 4 on, so limb 4 held
///         the assertion up by itself. Under isolation, deleting limb N makes the predicate FALSE
///         in probe N and the withdrawal SUCCEEDS, which lands in `guardAdmissions` and fails
///         `invariant_freezePredicateAdmitsNoBypass` on the very next evaluation.
///
/// @dev THE EXIT PROBE MUST BE ABLE TO SUCCEED. `_ensureStake` keeps a real, fully-withdrawable
///      curator stake standing in a zero-exposure class before every probe. This is load-bearing
///      and is NOT convenience: `withdrawFirstLoss` evaluates the freeze BEFORE stake and headroom,
///      so a stake-less probe would revert `Curator_InsufficientStake` when a limb was DELETED —
///      `RefusedOtherwise`, not `Admitted` — and the bypass would not be recorded as a bypass. A
///      probe that cannot succeed when the guard is gone is not a probe.
///
/// @dev DO NOT PRE-FILTER, and do not "fix" a probe by checking first whether the call would
///      revert. That check is the pre-filter that made six earlier suites vacuous in this
///      engagement (`GuardProbe`'s header lists them).
///
/// @dev `fail_on_revert = true` (repo default) is load-bearing here and is NOT relaxed. Every state
///      move below is precondition-guarded; a revert is a finding.
contract CustodyFreezePredicateHandler is GuardProbe {
    // ── wiring ───────────────────────────────────────────────────────────

    struct Wiring {
        address usdc;
        address usdfr;
        address reserves;
        address controller;
        address vault;
        address curator;
        address backstop;
        address admin;
        address guardian;
        address curatorActor;
        address minter;
        address recapAgent;
        address custodySink;
        /// @dev Dedicated Curator bound to a reserve with ABSORBER wired and CONTROLLER unset.
        address curatorNoController;
        /// @dev Dedicated Curator bound to a reserve with CONTROLLER wired and ABSORBER unset.
        address curatorNoAbsorber;
        /// @dev A funded facility whose face principal limb 4 is driven against.
        uint256 impairFacilityId;
    }

    MockERC20 internal usdc;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    CuratorModule internal curator;
    address internal backstop;

    address internal admin;
    address internal guardian;
    address internal curatorActor;
    address internal minter;
    address internal recapAgent;
    address internal custodySink;
    address internal curatorNoController;
    address internal curatorNoAbsorber;
    uint256 internal impairFacilityId;

    // ── shape constants ──────────────────────────────────────────────────

    /// @dev Whole-USDC alignment for anything crossing the 6dp<->18dp boundary, so a write-down or
    ///      a recapitalisation can never fail `ReserveManager_ValueNotUSDCExact`.
    uint256 internal constant UNIT = 1e12;
    /// @dev Keep retained legacy incident probes disjoint from the production arm sequence; both
    ///      APIs map their lower-namespace id through `custodyEventId` and ids are single-use.
    uint256 internal constant LEGACY_INCIDENT_NONCE_BASE = 1 << 128;
    /// @dev Class 5 is marked-to-market and is never originated against here, so its class exposure
    ///      is permanently zero, `min(target, exposure)` is zero, and the WHOLE pool sits inside
    ///      subordination headroom. That is what makes the FREEZE the only thing that can refuse
    ///      the exit probe — `assertGt(headroom)` below pins it rather than assuming it.
    uint256 internal constant PROBE_CLASS = Config.CLASS_DIGITAL_ASSETS;
    uint256 internal constant STAKE_FLOOR = 10_000e18;
    uint256 internal constant PROBE_AMOUNT = 1_000e18;

    // ── registered guards ────────────────────────────────────────────────

    bytes32 internal constant G_CLEAR = keccak256("custodyFreeze:clear");
    bytes32 internal constant G_L1_VIEW = keccak256("custodyLossUnabsorbed:limb1:view");
    bytes32 internal constant G_L1_EXIT = keccak256("custodyLossUnabsorbed:limb1:exit");
    bytes32 internal constant G_L2_VIEW = keccak256("custodyLossUnabsorbed:limb2:view");
    bytes32 internal constant G_L2_EXIT = keccak256("custodyLossUnabsorbed:limb2:exit");
    bytes32 internal constant G_L3_VIEW = keccak256("custodyLossUnabsorbed:limb3:view");
    bytes32 internal constant G_L3_EXIT = keccak256("custodyLossUnabsorbed:limb3:exit");
    bytes32 internal constant G_L4_VIEW = keccak256("custodyLossUnabsorbed:limb4:view");
    bytes32 internal constant G_L4_EXIT = keccak256("custodyLossUnabsorbed:limb4:exit");
    bytes32 internal constant G_NOCTRL_VIEW = keccak256("custodyLossUnabsorbed:noController:view");
    bytes32 internal constant G_NOCTRL_EXIT = keccak256("custodyLossUnabsorbed:noController:exit");
    bytes32 internal constant G_NOABS_VIEW = keccak256("custodyLossUnabsorbed:noAbsorber:view");
    bytes32 internal constant G_NOABS_EXIT = keccak256("custodyLossUnabsorbed:noAbsorber:exit");
    bytes32 internal constant G_UNWIRED_VIEW = keccak256("custodyFreezeActive:unwired:view");
    bytes32 internal constant G_UNWIRED_EXIT = keccak256("custodyFreezeActive:unwired:exit");
    bytes32 internal constant G_PREARM_VIEW = keccak256("custodyFreezeActive:preArm:view");
    bytes32 internal constant G_PREARM_EXIT = keccak256("custodyFreezeActive:preArm:exit");
    bytes32 internal constant G_PREARM_BUDGET = keccak256("preArmCustodyFreeze:budget");
    bytes32 internal constant G_PREARM_EXPIRY = keccak256("custodyFreezeActive:preArm:expiry");

    // ── ghost counters ───────────────────────────────────────────────────

    /// @dev Incremented at the TOP of every registered selector, before any guard. The deterministic
    ///      seed never touches it, so a non-zero value proves the `targetSelector` wiring fired
    ///      rather than that the seed ran.
    uint256 public fuzzEntries;
    uint256 public callCount;
    /// @notice A probe found the system NOT at rest when it started. MUST stay zero: every probe
    ///         restores the state it moved, and a non-zero value means an earlier probe leaked.
    uint256 public ghostNotAtRest;
    /// @notice Probes that had to step aside because their illegal region was unreachable from the
    ///         current state (e.g. not enough idle cash to latch a deficit). Reported, not asserted
    ///         — the deterministic seed is what guarantees every guard is entered on every run.
    uint256 public ghostSkipped;
    /// @notice Custody incidents opened by this handler; each takes a fresh nonce because
    ///         `openReserveLossIncident` permanently refuses a reused id.
    uint256 public incidentNonce;
    uint256 public ghostDeficitsLatched;
    uint256 public ghostShortfallsInduced;
    uint256 public ghostImpairmentsRecognised;
    uint256 public ghostPreArms;
    uint256 public ghostExitsAtRest;

    constructor(Wiring memory w) {
        usdc = MockERC20(w.usdc);
        usdfr = USDfr(w.usdfr);
        reserves = ReserveManager(w.reserves);
        controller = MintRedeemController(w.controller);
        vault = SUSDfr(w.vault);
        curator = CuratorModule(w.curator);
        backstop = w.backstop;
        admin = w.admin;
        guardian = w.guardian;
        curatorActor = w.curatorActor;
        minter = w.minter;
        recapAgent = w.recapAgent;
        custodySink = w.custodySink;
        curatorNoController = w.curatorNoController;
        curatorNoAbsorber = w.curatorNoAbsorber;
        impairFacilityId = w.impairFacilityId;

        // Registered BEFORE any probe fires, so `reachReport()` can show a guard that was NEVER
        // reached. A guard that only appears the first time it is hit could never be reported as
        // not-reached, which is the exact vacuity this ledger exists to expose.
        bytes4 frozen = ICuratorModule.Curator_CustodyLossFrozen.selector;
        _registerGuard(G_CLEAR, bytes4(0), "AT REST: predicate false AND a legal exit completes");
        _registerGuard(G_L1_VIEW, bytes4(0), "limb 1 open incident -> custodyFreezeActive()");
        _registerGuard(G_L1_EXIT, frozen, "limb 1 open incident -> withdrawFirstLoss refused");
        _registerGuard(G_L2_VIEW, bytes4(0), "limb 2 latched deficit (recapitalised) -> custodyFreezeActive()");
        _registerGuard(G_L2_EXIT, frozen, "limb 2 latched deficit (recapitalised) -> withdrawFirstLoss refused");
        _registerGuard(G_L3_VIEW, bytes4(0), "limb 3 live custody shortfall -> custodyFreezeActive()");
        _registerGuard(G_L3_EXIT, frozen, "limb 3 live custody shortfall -> withdrawFirstLoss refused");
        _registerGuard(G_L4_VIEW, bytes4(0), "limb 4 under-backing -> custodyFreezeActive()");
        _registerGuard(G_L4_EXIT, frozen, "limb 4 under-backing -> withdrawFirstLoss refused");
        _registerGuard(G_NOCTRL_VIEW, bytes4(0), "miswired: no lossController -> custodyFreezeActive()");
        _registerGuard(G_NOCTRL_EXIT, frozen, "miswired: no lossController -> withdrawFirstLoss refused");
        _registerGuard(G_NOABS_VIEW, bytes4(0), "miswired: no lossAbsorber -> custodyFreezeActive()");
        _registerGuard(G_NOABS_EXIT, frozen, "miswired: no lossAbsorber -> withdrawFirstLoss refused");
        _registerGuard(G_UNWIRED_VIEW, bytes4(0), "unwired reserve -> custodyFreezeActive()");
        _registerGuard(
            G_UNWIRED_EXIT, ICuratorModule.Curator_ReserveNotWired.selector, "unwired reserve -> exit refused"
        );
        _registerGuard(G_PREARM_VIEW, bytes4(0), "guardian pre-arm -> custodyFreezeActive()");
        _registerGuard(G_PREARM_EXIT, frozen, "guardian pre-arm -> withdrawFirstLoss refused");
        _registerGuard(
            G_PREARM_BUDGET,
            ICuratorModule.Curator_PreArmBudgetExhausted.selector,
            "guardian pre-arm budget -> re-arm refused past the cap"
        );
        _registerGuard(G_PREARM_EXPIRY, bytes4(0), "guardian pre-arm EXPIRES on its own (not a permanent lock)");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  FUZZ ACTIONS (every one must appear in the `targetSelector` list)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice THE POSITIVE CONTROL, driven statefully. At rest the predicate must be FALSE and a
    ///         legal exit must COMPLETE.
    /// @dev Without this, every negative probe below is satisfied by a predicate that simply
    ///      returns `true` — and an always-frozen protocol is a bricked one. This is the guard that
    ///      makes the other eighteen mean something.
    function probeClearState() external {
        fuzzEntries++;
        if (_driveClear()) callCount++;
    }

    /// @notice LIMB 1 — an OPEN custody incident, in isolation.
    function probeLimb1OpenIncident() external {
        fuzzEntries++;
        if (_driveLimb1()) callCount++;
    }

    /// @notice LIMB 2 — a genuine residual produced by an arm-bound custody adjudication and then
    ///         recapitalised so no live shortfall or observable under-backing remains.
    /// @dev In the selected workflow the canonical arm deliberately remains live until atomic
    ///      finalization, so a residual-only boolean state is no longer reachable. The campaign
    ///      pins the residual data and the absence of the other economic limbs while the arm holds
    ///      the exit, then proves finalization restores rest.
    function probeLimb2LatchedDeficit(uint256 seed) external {
        fuzzEntries++;
        if (_driveLimb2(seed)) callCount++;
    }

    /// @notice LIMB 3 — custodied USDC physically gone while the idle ledger still counts it.
    /// @dev The transfer deliberately clears any accumulated live SURPLUS first, because a surplus
    ///      would absorb a small outflow and the probe would then run with NO limb live at all —
    ///      a silently vacuous probe rather than a failing one.
    function probeLimb3LiveShortfall(uint256 seed) external {
        fuzzEntries++;
        if (_driveLimb3(seed)) callCount++;
    }

    /// @notice LIMB 4 — under-backing produced by a G3 conservative mark, in isolation.
    function probeLimb4UnderBacking(uint256 seed) external {
        fuzzEntries++;
        if (_driveLimb4(seed)) callCount++;
    }

    /// @notice The MISWIRED fail-closed branch, CONTROLLER leg: a reserve whose absorber is wired
    ///         and whose loss controller is not.
    /// @dev The other leg is wired on purpose. With both unset either leg alone still answers
    ///      `true`, so a probe that leaves both unset stays green when one is deleted — the same
    ///      shadowing that made limb 2 deletable.
    function probeMiswiredController() external {
        fuzzEntries++;
        if (_driveMiswired(curatorNoController, G_NOCTRL_VIEW, G_NOCTRL_EXIT)) callCount++;
    }

    /// @notice The MISWIRED fail-closed branch, ABSORBER leg: a reserve whose loss controller is
    ///         wired (and reports a fully backed protocol, so limb 4 is provably off) and whose
    ///         absorber is not.
    function probeMiswiredAbsorber() external {
        fuzzEntries++;
        if (_driveMiswired(curatorNoAbsorber, G_NOABS_VIEW, G_NOABS_EXIT)) callCount++;
    }

    /// @notice `CuratorModule`'s own fail-closed branch: no reserve wired at all.
    function probeUnwiredReserve() external {
        fuzzEntries++;
        if (_driveUnwired()) callCount++;
    }

    /// @notice The GUARDIAN PRE-ARM, with every reserve limb provably off — so nothing but the
    ///         pre-arm branch can be producing the freeze.
    function probePreArm() external {
        fuzzEntries++;
        if (_drivePreArm()) callCount++;
    }

    /// @notice The pre-arm's TWO BOUNDS, which are what keep the guardian's unilateral reach
    ///         finite: the consecutive-arm BUDGET and the EXPIRY.
    /// @dev Both directions matter. Deleting the budget check hands a guardian an indefinite lock
    ///      on curator capital; deleting the expiry (or letting it never lapse) does the same. The
    ///      expiry half is recorded as a guard whose held-condition is that the freeze CLEARS.
    function probePreArmBudgetAndExpiry() external {
        fuzzEntries++;
        if (_drivePreArmBounds()) callCount++;
    }

    /// @notice Noise: fresh layer-1 capital across the classes, so the cascade capacity limb 2 must
    ///         exceed keeps moving instead of sitting at one value.
    function postFirstLossNoise(uint256 classSeed, uint256 amountSeed) external {
        fuzzEntries++;
        uint256 classId = 1 + (classSeed % Config.NUM_CLASSES);
        uint256 amount = _align(bound(amountSeed, UNIT, 50_000e18));
        if (amount == 0) return;
        _post(classId, amount);
        callCount++;
    }

    /// @notice Noise: supply and backing rise together, moving the numbers limb 4 is measured
    ///         against.
    function mintSupply(uint256 amountSeed) external {
        fuzzEntries++;
        uint256 amount = _align(bound(amountSeed, UNIT, 250_000e18));
        if (amount == 0) return;
        _mint(minter, amount);
        callCount++;
    }

    /// @notice Time passes.
    function warp(uint256 dtSeed) external {
        fuzzEntries++;
        vm.warp(block.timestamp + bound(dtSeed, 1 hours, 7 days));
        callCount++;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  DETERMINISTIC SEED (called once from the suite's setUp; NOT a selector)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Drives EVERY registered guard once, deterministically, before every run.
    /// @dev House pattern (`CollateralInvariants`, `INV_CascadeSeniority`): forge restarts every run
    ///      from the post-`setUp` state and `afterInvariant` samples ONE run, so a per-guard "was
    ///      reached" floor cannot rest on fuzz luck — with thirteen selectors the chance a specific
    ///      one is never drawn in a depth-`d` run is `(12/13)^d`, about 8% at lite's depth 32.
    ///      The seed makes the floor deterministic; `fuzzEntries` stays the wiring tooth, and
    ///      everything above the seed is the campaign's own reach (printed by `reachReport`).
    ///
    ///      IT IS ALSO THE MUTATION FLOOR. Because the seed enters every limb's illegal region,
    ///      deleting any limb makes this campaign RED at `--invariant-runs 1 --invariant-depth 1`
    ///      — no fuzz luck involved, which is the reachability proof the round asks for.
    function seedEveryLimb() external {
        _driveLimb1();
        _driveLimb2(37);
        _driveLimb3(11);
        _driveLimb4(23);
        _driveMiswired(curatorNoController, G_NOCTRL_VIEW, G_NOCTRL_EXIT);
        _driveMiswired(curatorNoAbsorber, G_NOABS_VIEW, G_NOABS_EXIT);
        _driveUnwired();
        _drivePreArm();
        _drivePreArmBounds();
        // The positive control last, so it also proves the state is CLEAN after every negative
        // probe above has run and restored itself.
        _driveClear();
    }

    // ─────────────────────────────────────────────────────────────────────
    //  LIMB DRIVERS — shared by the fuzzed actions and the seed, so the seed
    //  exercises the identical code path rather than an imitation of it
    // ─────────────────────────────────────────────────────────────────────

    function _driveClear() private returns (bool) {
        if (!_enterProbe()) return false;
        (bool ok, bool active) = _freezeView();
        uint256 before = usdfr.balanceOf(curatorActor);
        bool exited;
        vm.prank(curatorActor);
        try curator.withdrawFirstLoss(PROBE_CLASS, PROBE_AMOUNT) {
            exited = usdfr.balanceOf(curatorActor) - before == PROBE_AMOUNT;
        } catch {}
        if (exited) ghostExitsAtRest++;
        _recordBehaviouralGuard(G_CLEAR, ok && !active && exited);
        return true;
    }

    function _driveLimb1() private returns (bool) {
        if (!_enterProbe()) return false;
        uint256 incidentId = _openIncident();
        _assertOnlyLimb(1);
        _recordFrozen(G_L1_VIEW, G_L1_EXIT);
        vm.prank(admin);
        reserves.closeReserveLossIncident(incidentId);
        _assertRest();
        return true;
    }

    function _driveLimb2(uint256 seed) private returns (bool) {
        if (!_enterProbe()) return false;
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 slack = backing - supply; // `_enterProbe` proved backing >= supply
        // The write-down must exceed the slack AND the whole cascade capacity, or no residual
        // latches. Reading those capacities is a PRECONDITION, not a prediction: nothing asserted
        // below is derived from them.
        uint256 floor_ = slack + _cascadeCapacity();
        uint256 room = reserves.idleReserve();
        if (room <= floor_ + UNIT) {
            ghostSkipped++;
            return false;
        }
        uint256 loss = _align(bound(seed, floor_ + UNIT, room));
        if (loss <= floor_) {
            ghostSkipped++;
            return false;
        }

        (uint256 armId,, bytes32 evidenceHash, bool armsEnabled) = reserves.reserveLossArm();
        assertEq(armId, 0, "F3: limb-2 probe started with an active arm");
        if (!armsEnabled) {
            vm.prank(admin);
            reserves.setGuardianReserveLossArmsEnabled(true);
        }
        evidenceHash = keccak256(abi.encode("f3-arm-bound-limb2", seed, block.timestamp));
        vm.prank(guardian);
        (armId,) = reserves.armReserveLossFreeze(evidenceHash);

        uint256 nativeUnits = loss / UNIT;
        vm.prank(address(reserves));
        usdc.transfer(custodySink, nativeUnits);
        vm.prank(admin);
        (uint256 incidentId, uint256 actualLoss) = reserves.ratifyAndOpen(armId, evidenceHash, loss);
        assertEq(actualLoss, loss, "F3: ratification did not rederive the physical loss");
        uint256 deficit = reserves.reserveDeficit();
        if (deficit == 0) {
            // Unreachable by construction (loss > slack + capacity), but a silent no-op here would
            // be a vacuous probe, so it is counted rather than assumed away.
            ghostSkipped++;
            vm.prank(admin);
            reserves.finalizeAndDisable(armId, evidenceHash);
            _assertRest();
            return false;
        }
        ghostDeficitsLatched++;

        // THE RECAPITALISATION: cash in with NO matching mint, so backing rises to meet supply and
        // the observable under-backing limb goes quiet while the genuine residual stays recorded.
        _recapitalise();
        // Fresh layer-1 capital, because the write-down consumed the pool and the exit probe must
        // be refused by the FREEZE rather than by an empty stake.
        _ensureStake();

        _assertArmBoundResidual(armId, incidentId, deficit);
        _recordFrozen(G_L2_VIEW, G_L2_EXIT);

        vm.prank(admin);
        reserves.finalizeAndDisable(armId, evidenceHash);
        _assertRest();
        return true;
    }

    function _driveLimb3(uint256 seed) private returns (bool) {
        if (!_enterProbe()) return false;
        uint256 recorded = reserves.idleUSDC();
        uint256 live = usdc.balanceOf(address(reserves));
        if (recorded == 0) {
            ghostSkipped++;
            return false;
        }
        // Clear any accumulated live surplus first, then take a real bite out of the ledger.
        uint256 surplus = live > recorded ? live - recorded : 0;
        uint256 bite = bound(seed, 1, recorded);
        uint256 move = surplus + bite;
        if (move > live) {
            ghostSkipped++;
            return false;
        }

        vm.prank(address(reserves));
        usdc.transfer(custodySink, move);
        ghostShortfallsInduced++;

        _assertOnlyLimb(3);
        _recordFrozen(G_L3_VIEW, G_L3_EXIT);

        vm.prank(custodySink);
        usdc.transfer(address(reserves), move);
        _assertRest();
        return true;
    }

    function _driveLimb4(uint256 seed) private returns (bool) {
        if (!_enterProbe()) return false;
        uint256 face = reserves.deployedTo(impairFacilityId);
        uint256 recognised = reserves.principalImpairmentOf(impairFacilityId);
        uint256 headroomFace = face - recognised;
        uint256 slack = controller.backingValue() - controller.totalUSDfr();
        if (headroomFace <= slack + 1) {
            ghostSkipped++;
            return false;
        }
        uint256 mark = bound(seed, slack + 1, headroomFace);

        bytes32 evidence = keccak256(abi.encode("f3-limb4-adjudication", mark, block.timestamp));
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(impairFacilityId, mark, evidence);
        ghostImpairmentsRecognised++;

        _assertOnlyLimb(4);
        _recordFrozen(G_L4_VIEW, G_L4_EXIT);

        vm.prank(admin);
        reserves.releasePrincipalImpairment(impairFacilityId, mark, evidence);
        _assertRest();
        return true;
    }

    function _driveMiswired(address probeCurator, bytes32 viewGuard, bytes32 exitGuard) private returns (bool) {
        if (!_enterProbe()) return false;
        CuratorModule target = CuratorModule(probeCurator);
        (bool ok, bool active) = _freezeView(target);
        _recordBehaviouralGuard(viewGuard, ok && active);
        assertGe(target.headroom(PROBE_CLASS), PROBE_AMOUNT, "F3: miswire probe has no headroom");
        assertGe(target.postedOf(PROBE_CLASS, curatorActor), PROBE_AMOUNT, "F3: miswire probe has no stake");
        _fireAtGuard(exitGuard, curatorActor, address(target), _exitCalldata());
        _assertRest();
        return true;
    }

    function _driveUnwired() private returns (bool) {
        if (!_enterProbe()) return false;
        vm.prank(admin);
        curator.setReserveManager(address(0));
        (bool ok, bool active) = _freezeView();
        _recordBehaviouralGuard(G_UNWIRED_VIEW, ok && active);
        _fireAtGuard(G_UNWIRED_EXIT, curatorActor, address(curator), _exitCalldata());
        vm.prank(admin);
        curator.setReserveManager(address(reserves));
        _assertRest();
        return true;
    }

    function _drivePreArm() private returns (bool) {
        if (!_enterProbe()) return false;
        vm.prank(guardian);
        curator.preArmCustodyFreeze();
        ghostPreArms++;
        // ISOLATION: every reserve limb is off, so only the pre-arm branch can answer here.
        assertFalse(reserves.custodyLossUnabsorbed(), "F3: pre-arm probe is not isolated");
        _recordFrozen(G_PREARM_VIEW, G_PREARM_EXIT);
        vm.prank(admin);
        curator.cancelCustodyPreArm();
        _assertRest();
        return true;
    }

    function _drivePreArmBounds() private returns (bool) {
        if (!_enterProbe()) return false;
        uint32 max = curator.CUSTODY_PRE_ARM_MAX_CONSECUTIVE();
        for (uint32 i = 0; i < max; ++i) {
            vm.prank(guardian);
            curator.preArmCustodyFreeze();
            ghostPreArms++;
        }
        // BUDGET: the next arm must be refused, with its own error.
        _fireAtGuard(
            G_PREARM_BUDGET, guardian, address(curator), abi.encodeCall(ICuratorModule.preArmCustodyFreeze, ())
        );
        // EXPIRY: everything the guardian can buy, spent at once, still lapses on its own.
        vm.warp(block.timestamp + uint256(curator.custodyPreArmDuration()) + 1);
        (bool ok, bool active) = _freezeView();
        _recordBehaviouralGuard(G_PREARM_EXPIRY, ok && !active);
        // Only governance replenishes the budget, which is also what restores rest.
        vm.prank(admin);
        curator.cancelCustodyPreArm();
        _assertRest();
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  PROBE MACHINERY
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Establishes the two preconditions every probe depends on: the system is at REST (so
    ///      exactly one limb will be live once the probe moves one), and a fully withdrawable
    ///      curator stake exists (so a DELETED limb produces a SUCCESSFUL withdrawal — an
    ///      `Admitted` verdict — rather than an unrelated `InsufficientStake` refusal).
    function _enterProbe() private returns (bool) {
        if (!_atRest()) {
            ghostNotAtRest++;
            return false;
        }
        _ensureStake();
        return true;
    }

    /// @dev Records BOTH halves of a limb's specified behaviour: the published view says frozen,
    ///      and the surface that consumes it actually refuses the exit. Two guards rather than one
    ///      because they fail differently — deleting a limb makes the exit succeed (`Admitted`),
    ///      while breaking the plumbing between them makes the view revert (`held == false`).
    function _recordFrozen(bytes32 viewGuard, bytes32 exitGuard) private {
        (bool ok, bool active) = _freezeView();
        _recordBehaviouralGuard(viewGuard, ok && active);
        // The exit must be refused by the FREEZE, not by headroom or an empty stake.
        assertGe(curator.headroom(PROBE_CLASS), PROBE_AMOUNT, "F3: probe would be refused by headroom, not the freeze");
        assertGe(
            curator.postedOf(PROBE_CLASS, curatorActor), PROBE_AMOUNT, "F3: probe would be refused by an empty stake"
        );
        _fireAtGuard(exitGuard, curatorActor, address(curator), _exitCalldata());
    }

    function _exitCalldata() private pure returns (bytes memory) {
        return abi.encodeCall(ICuratorModule.withdrawFirstLoss, (PROBE_CLASS, PROBE_AMOUNT));
    }

    /// @dev `custodyFreezeActive()` read through a raw staticcall so a mutation that makes it REVERT
    ///      (deleting a fail-closed branch leaves a call to `address(0)`) is recorded as a guard
    ///      bypass instead of crashing the handler with an undecodable error.
    function _freezeView() private view returns (bool ok, bool active) {
        return _freezeView(curator);
    }

    function _freezeView(CuratorModule target) private view returns (bool ok, bool active) {
        (bool success, bytes memory ret) =
            address(target).staticcall(abi.encodeCall(ICuratorModule.custodyFreezeActive, ()));
        if (!success || ret.length != 32) return (false, false);
        return (true, abi.decode(ret, (bool)));
    }

    /// @notice Every limb of the reserve predicate is off, the reserve is wired, and no pre-arm
    ///         stands. Deliberately does NOT consult `custodyFreezeActive()` — that is the thing
    ///         under test, and reading it here would make the isolation claim circular.
    function atRest() external view returns (bool) {
        return _atRest();
    }

    /// @notice Human-readable label of the guard that was last BYPASSED, so a failing campaign
    ///         names the limb instead of printing a hash.
    /// @dev A bypass usually surfaces during `setUp`'s deterministic seed, where `afterInvariant`
    ///      (and therefore `reachReport`) never runs — so without this the operator would be told
    ///      only that "a curator exit escaped the freeze", and would have to bisect to find which
    ///      limb. Attribution is the whole value of the isolation discipline; do not drop it.
    function lastAdmittedGuardLabel() external view returns (string memory) {
        return guardLabel(lastAdmittedGuard);
    }

    function _atRest() private view returns (bool) {
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        if (incidentId != 0) return false;
        (uint256 armId,,,) = reserves.reserveLossArm();
        if (armId != 0) return false;
        if (reserves.reserveDeficit() != 0) return false;
        if (reserves.idleCustodyShortfall() != 0) return false;
        if (controller.totalUSDfr() > controller.backingValue()) return false;
        if (reserves.lossController() == address(0) || reserves.lossAbsorber() == address(0)) return false;
        if (curator.reserveManager() != address(reserves)) return false;
        (uint64 expiry, uint32 count) = curator.custodyPreArm();
        if (expiry > block.timestamp || count != 0) return false;
        return true;
    }

    function _assertRest() private {
        if (_atRest()) return;
        ghostNotAtRest++;
        assertTrue(false, "F3: a probe failed to restore the resting state");
    }

    /// @dev Asserts that EXACTLY `live` (1..4) of the four reserve limbs is true. This is what makes
    ///      a campaign red ATTRIBUTABLE to one limb; without it a disjunction can be exercised
    ///      everywhere and deleted anywhere.
    function _assertOnlyLimb(uint256 live) private view {
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        assertEq(incidentId != 0, live == 1, "F3 isolation: limb 1 (open incident) is in the wrong state");
        assertEq(
            reserves.reserveDeficit() != 0, live == 2, "F3 isolation: limb 2 (latched deficit) is in the wrong state"
        );
        assertEq(
            reserves.idleCustodyShortfall() != 0,
            live == 3,
            "F3 isolation: limb 3 (live shortfall) is in the wrong state"
        );
        assertEq(
            controller.totalUSDfr() > controller.backingValue(),
            live == 4,
            "F3 isolation: limb 4 (under-backing) is in the wrong state"
        );
        assertTrue(reserves.lossController() != address(0), "F3 isolation: the loss controller must stay wired");
        assertTrue(reserves.lossAbsorber() != address(0), "F3 isolation: the loss absorber must stay wired");
    }

    function _assertArmBoundResidual(uint256 expectedArmId, uint256 expectedIncidentId, uint256 expectedDeficit)
        private
        view
    {
        (uint256 armId,,,) = reserves.reserveLossArm();
        (uint256 incidentId,) = reserves.activeReserveLossIncident();
        assertEq(armId, expectedArmId, "F3: canonical arm changed during residual probe");
        assertEq(incidentId, expectedIncidentId, "F3: arm-bound incident changed during residual probe");
        assertEq(reserves.reserveDeficit(), expectedDeficit, "F3: genuine residual latch changed");
        assertEq(reserves.idleCustodyShortfall(), 0, "F3: recognized loss left a live physical shortfall");
        assertLe(controller.totalUSDfr(), controller.backingValue(), "F3: recapitalisation did not close under-backing");
        assertTrue(reserves.lossController() != address(0), "F3: loss controller became unwired");
        assertTrue(reserves.lossAbsorber() != address(0), "F3: loss absorber became unwired");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  STATE MOVERS
    // ─────────────────────────────────────────────────────────────────────

    function _openIncident() private returns (uint256 incidentId) {
        incidentNonce += 1;
        vm.prank(admin);
        incidentId = reserves.openReserveLossIncident(
            LEGACY_INCIDENT_NONCE_BASE + incidentNonce,
            keccak256(abi.encode("f3-custody-freeze-campaign", incidentNonce))
        );
    }

    /// @dev A third-party recapitalisation: USDC into the treasury with NO matching USDfr mint, so
    ///      backing rises while supply does not. Rounds UP to a whole USDC unit so backing can only
    ///      meet or exceed supply, never land just short and leave limb 4 quietly on.
    function _recapitalise() private {
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        if (backing >= supply) return;
        uint256 units = (supply - backing + UNIT - 1) / UNIT;
        usdc.mint(recapAgent, units);
        vm.startPrank(recapAgent);
        usdc.approve(address(reserves), units);
        reserves.depositUSDC(recapAgent, units);
        vm.stopPrank();
    }

    function _ensureStake() private {
        uint256 posted = curator.postedOf(PROBE_CLASS, curatorActor);
        if (posted >= STAKE_FLOOR) return;
        _post(PROBE_CLASS, STAKE_FLOOR - posted);
    }

    function _post(uint256 classId, uint256 amount) private {
        _mint(curatorActor, amount);
        vm.startPrank(curatorActor);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    function _mint(address to, uint256 amount) private {
        uint256 units = amount / UNIT;
        if (units == 0) return;
        usdc.mint(to, units);
        vm.startPrank(to);
        usdc.approve(address(controller), units);
        controller.mint(units);
        vm.stopPrank();
    }

    /// @dev Everything the cascade could absorb right now. A PRECONDITION for sizing limb 2's
    ///      write-down; no asserted quantity is derived from it.
    function _cascadeCapacity() private view returns (uint256 capacity) {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            capacity += curator.poolBalance(c);
        }
        capacity += usdfr.balanceOf(backstop);
        capacity += vault.totalAssets();
    }

    function _align(uint256 amount) private pure returns (uint256) {
        return (amount / UNIT) * UNIT;
    }
}
