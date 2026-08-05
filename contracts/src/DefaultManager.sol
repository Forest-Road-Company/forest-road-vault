// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ClaimBridge} from "./ClaimBridge.sol";
import {IAttestationOracle} from "./interfaces/IAttestationOracle.sol";
import {ICascadeBackstop} from "./interfaces/ICascadeBackstop.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {IDefaultManager} from "./interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title DefaultManager — remedies and the three-layer loss cascade
/// @notice RECEIVABLE classes: `declareDefault` freezes the position (the on-chain half
///         of the dual-record freeze) and emits `RemedyInitiated` with the class's
///         legal-wrapper remedy reference — the trigger for off-chain UCC enforcement.
///         MARKED-TO-MARKET class (ADR-0015): a fast, PERMISSIONLESS margin path —
///         anyone may `marginCall`/`liquidate` because the attested mark is the whole
///         evidence; the protocol just checks thresholds. Freshness asymmetry is
///         deliberate and protocol-protective: protective triggers accept the latest
///         mark at any age, while CURING a margin call demands a fresh mark within the
///         class's `maxMarkAge`.
///
///         THE CASCADE (CLAUDE.md §1.3 ordering, ADR-0014): `realizeLoss` burns, in one
///         transaction and in strict order — curator first-loss → sGROVE backstop →
///         sUSDfr vault principal — and pairs the burns with the principal write-down
///         so supply and backing fall together (ADR-0012). No layer is skippable: the
///         curator pool is always drained to its balance before the backstop is asked,
///         and the backstop before any depositor impairment.
/// @dev Pause policy: only the PERMISSIONLESS triggers (marginCall/clearMarginCall/
///      liquidate) are pausable — the guardian's lever if the oracle misbehaves. The
///      role-gated paths (declareDefault/accelerate/realizeLoss) are deliberately NOT
///      pausable: suppressing loss recognition is never an emergency remedy.
contract DefaultManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IDefaultManager
{
    /// @custom:storage-location erc7201:forestroad.storage.DefaultManager
    struct DefaultStorage {
        ClaimBridge bridge;
        ICollateralRegistry registry;
        IReserveManager reserves;
        IMintRedeemController controller;
        ICuratorModule curator;
        IAttestationOracle oracle;
        IERC20 usdfr;
        address vault; // sUSDfr — cascade layer 3
        ICascadeBackstop backstop; // sGROVE — cascade layer 2 (zero until Phase H)
        mapping(uint256 tokenId => uint64) cureDeadlines; // 0 = no active margin call
        mapping(uint256 classId => bytes32) remedyRefs;
        mapping(uint256 classId => uint64) cureWindows;
        // ── ADR-0022 conservative-redemption-NAV impairment tracking (append-only tail) ──
        // Per-class outstanding principal of loans in Defaulted/Accelerated state whose loss
        // is NOT yet realized. `pendingSeniorImpairment()` nets this against junior capacity
        // (curator pool per class, then sGROVE) to mark redemptions. It moves on exactly four
        // paths, and this list is exhaustive:
        //   += deployedTo                     at declare/liquidate (`_recordDefaulted`);
        //   -= the realized loss              at `realizeLoss` (`_reduceDefaulted`);
        //   -= the whole remainder            at a clean resolve (`onDefaultResolved`);
        //   -= principal RECOVERED IN CASH    at a partial recovery (`onDefaultRecovery`), and
        //                                     again as a backstop clamp inside
        //                                     `_reduceDefaulted` (AUDIT FIX H-2).
        // The last path is the H-2 fix: a recovery on a still-defaulted facility lowers
        // `deployedTo` in the ReserveManager, and without it the contribution stayed pinned at
        // the pre-recovery snapshot — an over-mark that nothing on-chain could ever clear.
        // Every decrement is mirrored one-for-one into `defaultedContribution[tokenId]` below,
        // so the class pool is always exactly the sum of its live per-token contributions.
        mapping(uint256 classId => uint256) declaredDefaultedPrincipal;
        mapping(uint256 tokenId => uint256) defaultedContribution;
        // ── PM-R-11: sGROVE coverage already consumed by STILL-LIVE declared defaults ──
        // (append-only TAIL; must stay last). PM-R-07 made the sGROVE cap cumulative PER
        // EVENT and snapshotted at that event's first draw, so once an event has drawn, the
        // coverage still reachable BY THAT EVENT is `snapshot - drawn` — which can be far
        // less than the global `coverageCapacity()` the NAV was netting against. Tracking
        // what live defaults have already consumed lets `pendingSeniorImpairment` deduct it
        // and stay conservative. Per-token so it can be released when a default closes out.
        mapping(uint256 tokenId => uint256) coverageConsumedByDefault;
        uint256 liveDefaultCoverageConsumed;
        // The smallest backstop capacity observed at any draw by a still-live default. Netting
        // against the LIVE capacity is unsafe on its own: `fundCoverage` is permissionless and
        // `setPerEventCap` is governance-tunable, so either can raise `coverageCapacity()` AFTER
        // an event has drawn -- and that increase cannot retroactively give an already-drawn
        // event more room, because its cap was snapshotted at its first draw. Pinning the floor
        // at draw time neutralises the inflation. Reset once no live default holds consumption.
        uint256 liveDefaultCapacityFloor;
        // ── AUDIT FIX H-5: permissionless past-due accounting trigger (append-only TAIL) ──
        // (REDESIGNED 2026-07-22 — final-audit findings #1/#2.) Receivable classes store `maturity`
        // but never read it after funding, so between a missed payment and a servicer's discretionary
        // `declareDefault` a past-due facility was priced at PAR and seniors exited at par.
        //
        // The FIRST H-5 fix drove `markPastDue` into `LoanState.Defaulted` — the SAME slot
        // `declareDefault` uses — which (a) permanently foreclosed a later `declareDefault`/
        // `RemedyInitiated` (no ClaimBridge edge back from Defaulted), (b) de-gated `realizeLoss`
        // from the `DefaultDeclared` attestation, and (c) let anyone freeze a curing facility.
        //
        // THE REDESIGN. `markPastDue` no longer touches `LoanState` or the curator: it sets a
        // REVERSIBLE per-facility `pastDueMarked` flag and records the facility's at-risk principal
        // into a SEPARATE past-due pool (`pastDueContribution` per token, `pastDuePrincipal` per
        // class, `pastDueExposure` the global aggregate). `pendingSeniorImpairment` adds
        // `pastDuePrincipal[classId]` alongside `declaredDefaultedPrincipal[classId]` when it nets
        // against junior capacity, so a past-due facility depresses the conservative senior NAV — the
        // honest mark — WITHOUT foreclosing the legal path or being able to trigger a loss (a merely
        // past-due facility stays `Active`/`Amortizing`, and `realizeLoss` requires
        // `Defaulted`/`Accelerated`, reachable only via the attested `declareDefault`). The mark is
        // removed/reduced by four paths: `clearPastDue` (servicer cure); `declareDefault` (converts
        // to the declared pool, releasing before recording so the facility counts exactly once,
        // never both); and `onPerformingRepayment` (called by the waterfall on the ordinary
        // performing repayment path — re-anchors the mark DOWN to live `deployedTo` as the facility
        // amortizes, and fully clears it on a full repayment, so a facility that cures through the
        // normal path stops depressing the NAV without a manual clear — the H-2 re-anchor, applied
        // to the past-due pool). Any residual over-mark is the safe direction (NAV lower, exits
        // cheaper, seniors protected) and is always clearable on-chain, so unlike H-2 it can never
        // strand.
        mapping(uint256 classId => uint64) graceWindows;
        mapping(uint256 tokenId => bool) pastDueMarked;
        uint256 pastDueExposure;
        mapping(uint256 tokenId => uint256) pastDueContribution;
        mapping(uint256 classId => uint256) pastDuePrincipal;
        // ── ADR-0027: assessment invalidation (append-only TAIL) ─────────────
        // Monotonic even when aggregate risk amounts later return to their previous values, so an
        // assessment made before an intervening default/past-due/recovery event cannot resurrect.
        uint256 impairmentRevision;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.DefaultManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DEFAULT_STORAGE_LOCATION =
        0x336a2060fa754acf2cdfdb8c351983bf3b455537ad219c0e1b705a95a2f8a200;
    uint256 private constant BACKSTOP_PROBE_GAS = 200_000;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Wiring bundle for `initialize` (11 flat addresses exceed stack depth).
    struct InitModules {
        address bridge; // facility register (freeze transitions)
        address registry; // collateral registry (class model + exposure release)
        address reserves; // treasury (outstanding principal + write-downs)
        address controller; // mint controller (cascade burns; asserts backing)
        address curator; // curator first-loss module (cascade layer 1)
        address oracle; // attestation oracle (margin-path marks; ADR-0007 trust)
        address usdfr; // the USDfr token
        address vault; // the sUSDfr vault (cascade layer 3)
    }

    /// @notice Initializes the manager; every class starts with the default cure window.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser (permissionless triggers only).
    /// @param upgrader Upgrade authority (timelock).
    /// @param m The wired protocol modules (see `InitModules` field docs).
    function initialize(address admin, address guardian, address upgrader, InitModules calldata m)
        external
        initializer
    {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || m.bridge == address(0)
                || m.registry == address(0) || m.reserves == address(0) || m.controller == address(0)
                || m.curator == address(0) || m.oracle == address(0) || m.usdfr == address(0) || m.vault == address(0)
        ) revert DefaultManager_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        DefaultStorage storage $ = _storage();
        $.bridge = ClaimBridge(m.bridge);
        $.registry = ICollateralRegistry(m.registry);
        $.reserves = IReserveManager(m.reserves);
        $.controller = IMintRedeemController(m.controller);
        $.curator = ICuratorModule(m.curator);
        $.oracle = IAttestationOracle(m.oracle);
        $.usdfr = IERC20(m.usdfr);
        $.vault = m.vault;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.cureWindows[classId] = Config.DEFAULT_MARGIN_CURE_WINDOW;
            emit CureWindowSet(classId, Config.DEFAULT_MARGIN_CURE_WINDOW);
            // AUDIT FIX (H-5): the past-due grace window defaults to (and is capped at) the
            // redemption cooldown. Governance may only ever lower it (see `setGraceWindow`'s cap).
            // The cap bounds the maturity-anchored marking lag; it does NOT fully cover the
            // request-anchored redemption cooldown (a partial par-exit window survives — documented).
            $.graceWindows[classId] = Config.DEFAULT_REDEEM_COOLDOWN;
            emit GraceWindowSet(classId, Config.DEFAULT_REDEEM_COOLDOWN);
        }
    }

    // ── Receivable remedy path (SERVICER_ROLE; never pausable) ───────────

    /// @inheritdoc IDefaultManager
    /// @dev Phase G (ADR-0020): declaring default requires the attested off-chain fact
    ///      — SERVICER_ROLE gates who may execute it, the DefaultDeclared attestation
    ///      gates whether it is true. The attestation stays standing (not consumed):
    ///      it remains the on-chain record backing the remedy process.
    function declareDefault(uint256 tokenId, bytes32 evidenceHash)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
    {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
        _consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.DefaultDeclared,
            keccak256(abi.encode(tokenId, evidenceHash)),
            false
        );
        // Pin all pre-default management/performance economics before the conservative
        // marked NAV changes. The new impairment then lowers NAV against the old HWM.
        IsUSDfr($.vault).accrueFees();
        delete $.cureDeadlines[tokenId]; // a margin path in flight is superseded
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Defaulted);
        // AUDIT FIX (R4-EC2): freeze curator withdrawals for the class until governance
        // resolves the workout, so a curator cannot front-run the coming realizeLoss.
        $.curator.freezeOnDefault(f.classId);
        // AUDIT FIX (H-5, REDESIGN): if the facility was flagged past due, RELEASE that reversible
        // past-due contribution IMMEDIATELY BEFORE recording the declared-default contribution —
        // adjacent internal writes, no external call between them — so the facility is counted
        // EXACTLY ONCE and there is never a window where both the past-due and the declared marks
        // apply. A no-op when the facility was not flagged.
        _releasePastDue($, tokenId, f.classId);
        _recordDefaulted($, tokenId, f.classId); // ADR-0022: enter the impairment pool
        _advanceImpairmentRevision($);
        bytes32 ref = $.remedyRefs[f.classId];
        emit DefaultDeclared(tokenId, f.classId, ref);
        emit RemedyInitiated(tokenId, f.classId, ref);
    }

    /// @inheritdoc IDefaultManager
    function accelerate(uint256 tokenId) external onlyRole(Roles.SERVICER_ROLE) nonReentrant {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Defaulted) revert DefaultManager_NotInDefault(tokenId);
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Accelerated);
        emit Accelerated(tokenId);
    }

    /// @inheritdoc IDefaultManager
    /// @dev Order matters for ADR-0012: all burns execute BEFORE the write-down, so the
    ///      backing invariant asserted inside each `burnLoss` sees supply falling while
    ///      backing is still whole; the write-down then drops backing by exactly the
    ///      amount supply already fell. Nothing in between can observe a violation.
    function realizeLoss(uint256 tokenId, uint256 loss, bytes32 evidenceHash)
        external
        onlyRole(Roles.SERVICER_ROLE)
        nonReentrant
    {
        if (loss == 0) revert DefaultManager_ZeroAmount();
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Defaulted && f.state != ClaimBridge.LoanState.Accelerated) {
            revert DefaultManager_NotInDefault(tokenId);
        }
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        if (loss > outstanding) revert DefaultManager_LossExceedsOutstanding(tokenId, loss, outstanding);
        _consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.LossRealized,
            keccak256(abi.encode(tokenId, loss, evidenceHash)),
            true
        );

        // Crystallize all pre-loss fees before any cascade leg moves value. The HWM then
        // remains at the pre-loss post-fee peak, so recovery from this loss is never charged
        // again as performance. A later revert rolls this checkpoint back atomically.
        IsUSDfr($.vault).accrueFees();

        // ── layer 1: curator first-loss (always consulted first) ──────────
        (uint256 absorbed, uint256 residual) = $.curator.absorbLoss(f.classId, loss);

        // ── layer 2: sGROVE backstop (only for the residual) ──────────────
        uint256 covered = 0;
        if (residual != 0 && address($.backstop) != address(0)) {
            uint256 balBefore = $.usdfr.balanceOf(address(this));
            covered = $.backstop.coverShortfall(tokenId, residual); // PM-R-07: cap is per EVENT (facility)
            uint256 received = $.usdfr.balanceOf(address(this)) - balBefore;
            // the ICascadeBackstop contract: covered <= residual, and EXACTLY `covered`
            // USDfr delivered. AUDIT FIX (L): strict equality — over-delivery
            // (received > covered) would strand USDfr here AND make depositors
            // over-absorb (depositorLoss is computed from `covered`), so reject it too.
            if (covered > residual || received != covered) {
                revert DefaultManager_BackstopContractViolated(residual, covered, received);
            }
        }

        // PM-R-11: remember what this EVENT has drawn, so the conservative NAV stops
        // netting coverage that this default can no longer reach (PM-R-07's cap is
        // per-event and cumulative). Released in `_releaseCoverageConsumption` when the
        // facility's impairment contribution reaches zero.
        if (covered != 0) {
            $.coverageConsumedByDefault[tokenId] += covered;
            $.liveDefaultCoverageConsumed += covered;
            uint256 capNow = $.backstop.coverageCapacity();
            uint256 floorNow = $.liveDefaultCapacityFloor;
            // AUDIT FIX (PM-R-11, round 3). Do NOT treat `floorNow == 0` as "unset": zero is a
            // LEGITIMATE floor. `coverShortfall` clamps `covered` to the reserve, so a draw can
            // leave the reserve -- and therefore the capacity -- at exactly zero. Reading that as
            // "unset" made the next draw (after a permissionless `fundCoverage` refill) re-seed
            // the floor at the new, larger capacity, handing the live defaults coverage no event
            // can reach and re-opening the under-mark with NO governance action at all.
            // `liveDefaultCoverageConsumed` was incremented immediately above, so it equals
            // `covered` if and only if no other live default held consumption -- which is exactly
            // "this is the first live draw, establish the floor". Otherwise only ratchet DOWN.
            bool firstLiveDraw = $.liveDefaultCoverageConsumed == covered;
            $.liveDefaultCapacityFloor = (firstLiveDraw || capNow < floorNow) ? capNow : floorNow;
        }

        // ── burn junior layers' absorption from this contract ─────────────
        uint256 selfBurn = absorbed + covered;
        if (selfBurn != 0) $.controller.burnLoss(address(this), selfBurn);

        // ── layer 3: depositor principal (only past BOTH junior layers) ───
        uint256 depositorLoss = loss - selfBurn;
        if (depositorLoss != 0) {
            // ADR-0023: bound by the vault's VESTED assets, not its raw USDfr balance. The
            // balance also contains realized yield still streaming in, which is not yet
            // credited to any share. Burning into it would leave `unvestedYield()` above the
            // balance, collapsing `totalAssets()` to zero for the rest of the stream — a
            // §1.3 exchange-rate monotonicity break far larger than the loss itself, and
            // fatal to the TWAP rate oracle. Bounding here keeps `balance >= unvested` true
            // by construction; the vault's own clamp is then unreachable defence-in-depth.
            // Strictly the CONSERVATIVE direction: it can only make `realizeLoss` revert
            // earlier into the existing governance-intervention path, never absorb more.
            uint256 vaultAssets = IsUSDfr($.vault).totalAssets();
            if (vaultAssets < depositorLoss) {
                // beyond total absorption capacity: unstaked USDfr would be impaired —
                // fail loudly; governance must intervene (CLAUDE.md prime directive 4)
                revert DefaultManager_LossExceedsAbsorptionCapacity(tokenId, depositorLoss, vaultAssets);
            }
            $.controller.burnLoss($.vault, depositorLoss);
        }

        // ── pair the write-down with the burns, atomically (ADR-0012) ─────
        $.reserves.recordPrincipalWritedown(tokenId, loss);
        $.registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, loss);
        // ADR-0022: the realized portion leaves the at-risk (unrealized-impairment) pool —
        // it is now reflected in the vault's balance via the layer-3 burn above.
        _reduceDefaulted($, tokenId, f.classId, loss);
        // A write-down can be the final act of a workout (including a zero-recovery
        // resolution, or cash recovered before the residual is written off). Previously
        // only WaterfallEngine's final cash repayment could enter `Resolved`, so a full
        // write-off left a zero-outstanding NFT permanently `Defaulted`/`Accelerated`.
        // Transition here once the atomic write-down has exhausted the outstanding.
        if ($.reserves.deployedTo(tokenId) == 0) {
            $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Resolved);
        }
        _advanceImpairmentRevision($);

        emit LossRealized(tokenId, f.classId, loss, absorbed, covered, depositorLoss);
    }

    // ── Past-due accounting trigger (permissionless; NOT pausable) ───────

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-5, REDESIGNED 2026-07-22 — final-audit findings #1/#2). Receivable classes
    ///      (1-4) store `maturity` but never read it after funding, so a facility that had defaulted
    ///      on payment was priced at PAR — and seniors exited at par — for the whole window between
    ///      the missed payment and a SERVICER's discretionary `declareDefault`. This closes that gap
    ///      by giving the maturity clock an on-chain, permissionless, REVERSIBLE consequence.
    ///
    ///      REVERSIBLE MARK, NOT A DEFAULT. The first H-5 fix drove the facility to
    ///      `LoanState.Defaulted` — the same slot `declareDefault` uses — which foreclosed a later
    ///      `declareDefault`/`RemedyInitiated` (the on-chain legal-remedy trigger) forever and
    ///      de-gated `realizeLoss` from the `DefaultDeclared` attestation. This redesign instead sets
    ///      a REVERSIBLE per-facility flag and records the facility's at-risk principal into a
    ///      SEPARATE past-due pool that `pendingSeniorImpairment` nets against junior capacity
    ///      exactly like the declared pool. The facility stays `Active`/`Amortizing`, so:
    ///        - `declareDefault`/`RemedyInitiated` stay reachable (it only reverts on
    ///          non-Active/Amortizing), and it CONVERTS the mark (releases past-due, records
    ///          declared) — no double count; and
    ///        - `realizeLoss` (state ∈ {Defaulted, Accelerated}) is UNREACHABLE from a merely
    ///          past-due facility, so the `DefaultDeclared` gate on loss realization is preserved by
    ///          construction — the cascade cannot run without the attested `declareDefault`.
    ///
    ///      NO CURATOR FREEZE. Unlike `declareDefault`/`liquidate`, this does NOT
    ///      `curator.freezeOnDefault`: a reversible past-due mark must not freeze first-loss (that
    ///      was the permissionless-griefing sting). The curator freeze stays on the attested
    ///      `declareDefault` only, where a `realizeLoss` it could front-run actually exists.
    ///
    ///      PERMISSIONLESS IS SAFE HERE. With the redesign a bystander call can only depress the
    ///      conservative NAV reversibly — it can neither foreclose the legal path nor trigger a loss
    ///      — so anyone may assert the maturity clock elapsed (senior-protective) with no griefing
    ///      surface: a curing workout is not blocked (state and curator untouched) and the mark
    ///      clears (`clearPastDue`) or converts (`declareDefault`).
    ///
    ///      NO UNDER-MARK. `outstanding` is `reserves.deployedTo` at mark time — the full at-risk
    ///      principal and the largest loss the facility can produce (`realizeLoss` reverts above it,
    ///      and `deployedTo` never rises for a facility past funding) — so the mark is an upper
    ///      bound: over-mark direction only. A partial repayment after the mark (facility still
    ///      Active) lets the snapshot exceed live `deployedTo` — a safe OVER-mark that the servicer
    ///      clears via `clearPastDue`, and that `declareDefault` re-anchors to fresh `deployedTo` on
    ///      conversion. It can never STRAND: `clearPastDue` is callable in any state.
    ///
    ///      ACCOUNTING, NOT LEGAL (ADR-0007 legal-sync; CLAUDE.md prime directive 6). It starts the
    ///      accounting clock ONLY: no `DefaultDeclared` attestation is required and no
    ///      `RemedyInitiated` is emitted. The servicer's legal declaration remains separate.
    ///
    ///      NOT PAUSABLE. It reads no oracle mark — only `maturity` (immutable) and `block.timestamp`
    ///      — so there is no oracle-misbehaviour vector to suppress.
    function markPastDue(uint256 tokenId) external nonReentrant {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        // Receivable classes only: marked-to-market facilities are priced by their attested mark
        // and handled by the permissionless margin path, not the maturity clock.
        if ($.registry.classParams(f.classId).model != ICollateralRegistry.CollateralModel.Receivable) {
            revert DefaultManager_NotReceivable(tokenId);
        }
        // Only a live, performing facility can be marked.
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
        // Idempotent: the facility stays Active/Amortizing, so the state check no longer bars a
        // second call — guard on the flag so the past-due pool cannot double-count.
        if ($.pastDueMarked[tokenId]) revert DefaultManager_AlreadyPastDue(tokenId);
        uint64 graceEnd = f.nextPaymentDue + $.graceWindows[f.classId];
        if (block.timestamp <= graceEnd) revert DefaultManager_NotPastDue(tokenId, f.nextPaymentDue, graceEnd);

        // Marking is permissionless, so checkpoint deterministically inside the transition:
        // transaction ordering cannot choose whether elapsed pre-mark economics are charged.
        IsUSDfr($.vault).accrueFees();
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        $.pastDueMarked[tokenId] = true;
        $.pastDueContribution[tokenId] = outstanding;
        $.pastDuePrincipal[f.classId] += outstanding;
        $.pastDueExposure += outstanding;
        _advanceImpairmentRevision($);
        emit PastDueMarked(tokenId, f.classId, f.nextPaymentDue, outstanding);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-5, REDESIGN). The reversibility half of `markPastDue`. SERVICER_ROLE-gated
    ///      because the servicer processes payments and is the party that knows a facility has cured.
    ///      State-agnostic on purpose: a facility that reached `Repaid`/`Resolved` while still
    ///      flagged (e.g. a bystander marked it, then it cured through the ordinary performing
    ///      repayment path) can always be cleaned up here, so a past-due over-mark can never strand —
    ///      the H-2 lesson. Removes the facility's at-risk principal from the past-due pool and the
    ///      `pastDueExposure` aggregate, restoring the conservative senior NAV.
    function clearPastDue(uint256 tokenId, bytes32 evidenceHash) external onlyRole(Roles.SERVICER_ROLE) nonReentrant {
        DefaultStorage storage $ = _storage();
        if (!$.pastDueMarked[tokenId]) revert DefaultManager_NotPastDueMarked(tokenId);
        _consumeExact(
            $,
            tokenId,
            IAttestationOracle.AttestationKind.PastDueCured,
            keccak256(abi.encode(tokenId, evidenceHash)),
            true
        );
        IsUSDfr($.vault).accrueFees();
        uint256 classId = $.bridge.facility(tokenId).classId;
        _releasePastDue($, tokenId, classId);
        _advanceImpairmentRevision($);
    }

    // ── Marked-to-market fast path (permissionless; pausable) ────────────

    /// @inheritdoc IDefaultManager
    function marginCall(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
        if ($.cureDeadlines[tokenId] != 0) revert DefaultManager_AlreadyMarginCalled(tokenId);

        (uint256 ltv, uint64 asOf) = _ltv($, tokenId);
        if (asOf == 0 || block.timestamp - asOf > p.maxMarkAge) {
            revert DefaultManager_ValuationStale(tokenId, asOf, p.maxMarkAge);
        }
        if (ltv < p.marginCallLtvBps) {
            revert DefaultManager_ThresholdNotBreached(tokenId, ltv, p.marginCallLtvBps);
        }
        uint64 deadline = uint64(block.timestamp) + $.cureWindows[f.classId];
        $.cureDeadlines[tokenId] = deadline;
        emit MarginCalled(tokenId, ltv, deadline);
    }

    /// @inheritdoc IDefaultManager
    /// @dev Curing demands FRESH evidence: the mark must be within the class's
    ///      `maxMarkAge`. (Protective triggers accept any-age marks; see contract note.)
    function clearMarginCall(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);
        if ($.cureDeadlines[tokenId] == 0) revert DefaultManager_NoMarginCall(tokenId);

        (uint256 ltv, uint64 asOf) = _ltv($, tokenId);
        if (block.timestamp - asOf > p.maxMarkAge) {
            revert DefaultManager_ValuationStale(tokenId, asOf, p.maxMarkAge);
        }
        if (ltv >= p.marginCallLtvBps) {
            revert DefaultManager_ThresholdNotBreached(tokenId, ltv, p.marginCallLtvBps);
        }
        delete $.cureDeadlines[tokenId];
        emit MarginCallCleared(tokenId, ltv);
    }

    /// @inheritdoc IDefaultManager
    function liquidate(uint256 tokenId) external nonReentrant whenNotPaused {
        DefaultStorage storage $ = _storage();
        (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p) = _mtmFacility($, tokenId);

        (uint256 ltv, uint64 asOf) = _ltv($, tokenId);
        if (asOf == 0 || block.timestamp - asOf > p.maxMarkAge) {
            revert DefaultManager_ValuationStale(tokenId, asOf, p.maxMarkAge);
        }
        uint64 deadline = $.cureDeadlines[tokenId];
        // liquidation triggers: hard threshold breach, OR an expired margin call that
        // is still in margin-call breach (a recovered LTV survives cure expiry)
        bool hardBreach = ltv >= p.liquidationLtvBps;
        bool cureExpired = deadline != 0 && block.timestamp > deadline && ltv >= p.marginCallLtvBps;
        if (!hardBreach && !cureExpired) {
            revert DefaultManager_ThresholdNotBreached(tokenId, ltv, p.liquidationLtvBps);
        }

        IsUSDfr($.vault).accrueFees();
        delete $.cureDeadlines[tokenId];
        $.bridge.transitionState(tokenId, ClaimBridge.LoanState.Defaulted);
        // AUDIT FIX (R4-EC2): freeze curator withdrawals for the class (see declareDefault).
        $.curator.freezeOnDefault(f.classId);
        _recordDefaulted($, tokenId, f.classId); // ADR-0022: enter the impairment pool
        _advanceImpairmentRevision($);
        bytes32 ref = $.remedyRefs[f.classId];
        emit LiquidationInitiated(tokenId, ltv);
        emit RemedyInitiated(tokenId, f.classId, ref);
    }

    // ── Credit-layer hook (ADR-0022 impairment lifecycle) ────────────────

    /// @inheritdoc IDefaultManager
    /// @dev Called by the WaterfallEngine when a defaulted facility recovers its full
    ///      outstanding and closes to `Resolved` WITHOUT a realized loss — the remaining
    ///      unrealized-impairment contribution must leave the pool, else the conservative
    ///      redemption NAV would stay depressed forever after a clean recovery. Gated by
    ///      CREDIT_ROLE AND a defensive check that the loan really is Resolved, so a
    ///      CREDIT_ROLE caller cannot prematurely zero a still-defaulted loan's contribution
    ///      (which would UNDER-mark impairment — the unsafe direction).
    function onDefaultResolved(uint256 tokenId) external onlyRole(Roles.CREDIT_ROLE) {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        if (f.state != ClaimBridge.LoanState.Resolved) revert DefaultManager_NotResolved(tokenId);
        uint256 c = $.defaultedContribution[tokenId];
        if (c != 0) {
            $.defaultedContribution[tokenId] = 0;
            $.declaredDefaultedPrincipal[f.classId] -= c;
            emit DefaultImpairmentCleared(tokenId, f.classId, c);
        }
        _releaseCoverageConsumption($, tokenId); // PM-R-11: no longer a live default
        _advanceImpairmentRevision($);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-2), the recovery half. `onDefaultResolved` only fires when a workout
    ///      recovers the outstanding IN FULL. A PARTIAL recovery — the ordinary shape of a
    ///      workout — lowered `reserves.deployedTo(tokenId)` while `defaultedContribution`
    ///      stayed pinned at its declare-time snapshot, and nothing on-chain could ever clear
    ///      the difference: `realizeLoss` is the only other decrement and a servicer must not
    ///      write off principal that is still being collected. Measured before this hook: a
    ///      2,000,000e18 facility returning 1,900,000e18 in cash kept `pendingSeniorImpairment()`
    ///      at 2,000,000e18 indefinitely against 100,000e18 of genuinely at-risk principal — a
    ///      permanent, un-clearable haircut on every senior exit. Four such ordinary workouts
    ///      drove `redemptionTotalAssets()` to zero against a solvent vault.
    ///
    ///      IT CANNOT UNDER-MARK. The new mark is exactly `reserves.deployedTo(tokenId)`, which
    ///      is the largest senior loss this facility can still produce: `realizeLoss` reverts
    ///      with `DefaultManager_LossExceedsOutstanding` when `loss > deployedTo`. And
    ///      `deployedTo` never rises again for a defaulted facility — it only grows in
    ///      `ReserveManager.recordDeployment`/`recordFeeCapitalization`, whose sole callers sit
    ///      inside `WaterfallEngine.fund`, which reverts unless the facility is `Pending`, a
    ///      state the ClaimBridge machine cannot re-enter. So the mark is an upper bound at the
    ///      moment it is written and stays one for the rest of the facility's life.
    ///
    ///      IT CANNOT RATCHET. The re-anchor is one-directional (`stillAtRisk < c` only), so
    ///      repeat calls, calls with nothing recovered, and calls interleaved with `realizeLoss`
    ///      in either order all converge on the same fixed point and never raise the mark.
    ///
    ///      THREAT MODEL. Both this hook and the `_reduceDefaulted` clamp trust `deployedTo` to
    ///      fall only against real cash or a real write-down. That holds only while CREDIT_ROLE
    ///      is held by protocol modules alone: a CREDIT_ROLE grant to an EOA could call
    ///      `ReserveManager.recordPrincipalReturn`/`recordPrincipalWritedown` directly, lowering
    ///      `deployedTo` without cash arriving or the cascade running, after which this
    ///      de-recognises a genuine loss. CREDIT_ROLE must never leave the module set.
    function onDefaultRecovery(uint256 tokenId) external onlyRole(Roles.CREDIT_ROLE) {
        DefaultStorage storage $ = _storage();
        ClaimBridge.Facility memory f = $.bridge.facility(tokenId);
        // Defensive, mirroring `onDefaultResolved`: a CREDIT_ROLE caller must not be able to
        // re-anchor a facility that is not actually in default (its contribution is zero in
        // every other state anyway, so this is belt-and-braces, not load-bearing arithmetic).
        if (f.state != ClaimBridge.LoanState.Defaulted && f.state != ClaimBridge.LoanState.Accelerated) {
            revert DefaultManager_NotInDefault(tokenId);
        }
        uint256 c = $.defaultedContribution[tokenId];
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        if (stillAtRisk >= c) return; // idempotent: nothing recovered since the last anchor
        uint256 derecognized = c - stillAtRisk;
        $.defaultedContribution[tokenId] = stillAtRisk;
        $.declaredDefaultedPrincipal[f.classId] -= derecognized;
        emit DefaultImpairmentCleared(tokenId, f.classId, derecognized);
        // PM-R-11: if the recovery emptied the mark, the coverage this default consumed stops
        // depressing the backstop capacity every LATER default nets against. Unreachable from
        // `WaterfallEngine.distribute` (a zero outstanding routes to `onDefaultResolved`
        // instead), kept so the two hooks cannot diverge.
        if (stillAtRisk == 0) _releaseCoverageConsumption($, tokenId);
        _advanceImpairmentRevision($);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (re-audit MEDIUM, 2026-07-22). The PAST-DUE counterpart of
    ///      `onDefaultRecovery`. A past-due facility stays Active/Amortizing (`markPastDue` never
    ///      transitions state), so it cures through the ORDINARY performing repayment path in
    ///      `WaterfallEngine.distribute` — which had no past-due hook. Left unwired, the past-due
    ///      pool kept its mark-time `pastDueContribution` snapshot while `deployedTo` fell, so the
    ///      conservative redemption NAV stayed depressed by the full snapshot until a manual
    ///      `clearPastDue`: a partial paydown over-marked by the un-amortized remainder, and a full
    ///      repayment left the whole snapshot standing. That is the H-2 stuck-over-mark shape, on
    ///      the past-due pool. This re-anchors the contribution DOWN to live `deployedTo` on every
    ///      performing repayment and fully clears the flag when the facility is repaid in full.
    ///
    ///      ONE-DIRECTIONAL AND IDEMPOTENT, exactly like `onDefaultRecovery`: it only shrinks the
    ///      mark (`stillAtRisk < c`), so repeat calls and calls with nothing paid down converge and
    ///      never raise it. A no-op for a facility that is not flagged, so it is safe to call on
    ///      EVERY performing repayment. Same threat model: it trusts `deployedTo` to fall only
    ///      against real cash or a real write-down, which holds only while CREDIT_ROLE stays inside
    ///      the module set.
    function onPerformingRepayment(uint256 tokenId) external onlyRole(Roles.CREDIT_ROLE) {
        DefaultStorage storage $ = _storage();
        if (!$.pastDueMarked[tokenId]) return; // no-op: the facility was never past-due
        uint256 classId = $.bridge.facility(tokenId).classId;
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        if (stillAtRisk == 0) {
            _releasePastDue($, tokenId, classId); // repaid in full: clear the mark entirely
            _advanceImpairmentRevision($);
            return;
        }
        uint256 c = $.pastDueContribution[tokenId];
        if (stillAtRisk >= c) return; // idempotent: nothing paid down since the last anchor
        uint256 derecognized = c - stillAtRisk;
        $.pastDueContribution[tokenId] = stillAtRisk;
        $.pastDuePrincipal[classId] -= derecognized;
        $.pastDueExposure -= derecognized;
        _advanceImpairmentRevision($);
        emit PastDueReanchored(tokenId, classId, derecognized);
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @inheritdoc IDefaultManager
    function setRemedyRef(uint256 classId, bytes32 remedyRef_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        _storage().remedyRefs[classId] = remedyRef_;
        emit RemedyRefSet(classId, remedyRef_);
    }

    /// @inheritdoc IDefaultManager
    function setCureWindow(uint256 classId, uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        if (window == 0) revert DefaultManager_ZeroAmount();
        _storage().cureWindows[classId] = window;
        emit CureWindowSet(classId, window);
    }

    /// @inheritdoc IDefaultManager
    /// @dev AUDIT FIX (H-5). Capped at `Config.DEFAULT_REDEEM_COOLDOWN` — the grace window can only
    ///      ever be LOWERED from its default, never raised past the redemption cooldown. Zero is
    ///      permitted (mark the instant past maturity — maximally conservative). Governance-gated and
    ///      evented; a purely accounting parameter. NB (final-audit #2): this cap bounds the
    ///      maturity-anchored marking lag, but the redemption cooldown is REQUEST-anchored
    ///      (`requestedAt + redeemCooldown`) and `RedemptionQueue.setRedeemCooldown` is separately
    ///      governed and unbounded, so the cap does NOT guarantee the cooldown fully covers the lag —
    ///      a partial par-exit window (a redeemer who queued before maturity) survives. Closing it
    ///      fully is a deeper economic-design item, deliberately NOT done here; the residual is
    ///      documented rather than hidden.
    function setGraceWindow(uint256 classId, uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        if (window > Config.DEFAULT_REDEEM_COOLDOWN) {
            revert DefaultManager_GraceWindowTooLong(window, Config.DEFAULT_REDEEM_COOLDOWN);
        }
        _storage().graceWindows[classId] = window;
        emit GraceWindowSet(classId, window);
    }

    /// @inheritdoc IDefaultManager
    function setBackstop(address backstop_) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _validateBackstop(backstop_);
        DefaultStorage storage $ = _storage();
        address oldBackstop = address($.backstop);
        if (oldBackstop != backstop_) {
            // Bill elapsed management fees against the outgoing NAV whenever it remains
            // readable. If it is broken, install the already-validated replacement first so
            // governance retains a one-transaction repair path.
            bool oldReadable = _isBackstopReadable(oldBackstop);
            if (oldReadable) IsUSDfr($.vault).beginFeeNeutralMarkedNavChange();
            $.backstop = ICascadeBackstop(backstop_);
            _advanceImpairmentRevision($);
            if (!oldReadable) IsUSDfr($.vault).beginFeeNeutralMarkedNavChange();
            IsUSDfr($.vault).endFeeNeutralMarkedNavChange();
        }
        emit BackstopSet(backstop_);
    }

    // ── Guardian (permissionless triggers only) ──────────────────────────

    /// @notice Pauses the permissionless margin-path triggers. Emergency use only
    ///         (e.g. suspect marks); role-gated remedy paths are never pausable.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the permissionless triggers.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IDefaultManager
    function currentLtvBps(uint256 tokenId) external view returns (uint256 ltvBps, uint64 asOf) {
        return _ltv(_storage(), tokenId);
    }

    /// @inheritdoc IDefaultManager
    function cureDeadline(uint256 tokenId) external view returns (uint64) {
        return _storage().cureDeadlines[tokenId];
    }

    /// @inheritdoc IDefaultManager
    function remedyRef(uint256 classId) external view returns (bytes32) {
        return _storage().remedyRefs[classId];
    }

    /// @inheritdoc IDefaultManager
    function cureWindow(uint256 classId) external view returns (uint64) {
        return _storage().cureWindows[classId];
    }

    /// @inheritdoc IDefaultManager
    function graceWindow(uint256 classId) external view returns (uint64) {
        return _storage().graceWindows[classId];
    }

    /// @inheritdoc IDefaultManager
    function pastDueExposure() external view returns (uint256) {
        return _storage().pastDueExposure;
    }

    /// @inheritdoc IDefaultManager
    function pastDueContribution(uint256 tokenId) external view returns (uint256) {
        return _storage().pastDueContribution[tokenId];
    }

    /// @inheritdoc IDefaultManager
    function backstop() external view returns (address) {
        return address(_storage().backstop);
    }

    /// @inheritdoc IDefaultManager
    function declaredDefaultedPrincipal(uint256 classId) external view returns (uint256) {
        return _storage().declaredDefaultedPrincipal[classId];
    }

    /// @inheritdoc IDefaultManager
    function impairmentRevision() external view returns (uint256) {
        return _storage().impairmentRevision;
    }

    /// @inheritdoc IDefaultManager
    /// @dev Exact operational fingerprint, including live backstop capacity.
    function impairmentStateHash() external view returns (bytes32 stateHash) {
        DefaultStorage storage $ = _storage();
        return keccak256(abi.encode(_impairmentRiskStateHash($), _impairmentBackstopCapacity($)));
    }

    /// @inheritdoc IDefaultManager
    /// @dev Includes every risk identity/input and exact per-class curator capacity, but
    ///      deliberately excludes the global backstop's live capacity. The assessed wrapper
    ///      snapshots that capacity separately so an increase (which can only protect seniors)
    ///      remains valid while any decrease fails conservatively.
    function impairmentRiskStateHash() external view returns (bytes32 stateHash) {
        return _impairmentRiskStateHash(_storage());
    }

    /// @inheritdoc IDefaultManager
    function impairmentBackstopCapacity() external view returns (uint256) {
        return _impairmentBackstopCapacity(_storage());
    }

    function _impairmentRiskStateHash(DefaultStorage storage $) private view returns (bytes32 stateHash) {
        stateHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.impairmentRevision,
                address($.curator),
                address($.backstop),
                $.liveDefaultCoverageConsumed,
                $.liveDefaultCapacityFloor,
                $.pastDueExposure
            )
        );
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            stateHash = keccak256(
                abi.encode(
                    stateHash,
                    classId,
                    $.declaredDefaultedPrincipal[classId],
                    $.pastDuePrincipal[classId],
                    $.curator.poolBalance(classId)
                )
            );
        }
    }

    function _impairmentBackstopCapacity(DefaultStorage storage $) private view returns (uint256) {
        return address($.backstop) == address(0) ? 0 : $.backstop.coverageCapacity();
    }

    /// @inheritdoc IDefaultManager
    /// @dev ADR-0022 conservative-redemption NAV. The senior (sUSDfr) principal that
    ///      declared-but-unrealized defaults would impair AFTER the junior layers absorb, in
    ///      strict cascade order: curator first-loss per CLASS, then the global sGROVE backstop.
    ///      Bounded loop over the fixed class set.
    ///
    ///      AUDIT FIX (PM-R-11). This used to net the residual against the raw
    ///      `coverageCapacity()` and claim it "never under-marks". That was FALSE once PM-R-07
    ///      made the sGROVE cap cumulative PER EVENT: `coverageCapacity()` reports what a
    ///      *fresh* event could draw, but an event that has already drawn can only reach
    ///      `snapshot - drawn`. After a partial `realizeLoss` the two diverge, the NAV netted
    ///      more coverage than the loss could actually reach, `redemptionTotalAssets()` read
    ///      HIGH, and a queued senior exited above the true conservative floor — pushing the
    ///      difference onto the seniors who stayed. Proven in
    ///      `test/audit/ExternalFinding2_NavVsEventCap.t.sol` (150,000 USDfr on a 1M reserve).
    ///
    ///      The fix deducts what still-live defaults have ALREADY consumed. There is no
    ///      enumerable set of declared facilities, so this is an aggregate rather than a
    ///      per-facility netting — deliberately. It cannot UNDER-mark (the PM-R-11 argument below).
    ///      It MAY over-mark, but only TRANSIENTLY: over-marking is the safe direction ONLY while
    ///      the excess is clearable, never when it strands. The H-2/C-1 finding falsified the old
    ///      "over-marking is always safe" framing — a STUCK over-mark drives
    ///      `redemptionTotalAssets()` to zero against a solvent vault, destroying the redeemer's
    ///      exit base. What keeps every over-mark here transient is that each term nets against a
    ///      live default whose contribution is re-anchored to `deployedTo` (AUDIT FIX H-2) and
    ///      released on resolve/realize/recover, so the excess always clears rather than pinning.
    ///
    ///      Why it is genuinely conservative, since an earlier revision of this fix was NOT and a
    ///      later audit round caught it. Deducting consumption from a LIVE capacity is not enough:
    ///      `coverageCapacity()` is recomputed from the CURRENT reserve, so a permissionless
    ///      `fundCoverage` top-up or a `setPerEventCap` raise after an event's first draw would
    ///      hand it coverage it can no longer reach and re-open the under-mark. So the netting is
    ///      ALSO capped at `liveDefaultCapacityFloor` — the capacity standing at the draw. For one
    ///      event that drew `d` against reserve `R` with cap `b`: floor = `(R-d)*b`, so
    ///      netted <= `(R-d)*b - d`, while its true remaining reach is
    ///      `min(R*b - d, R - d)`. Since `b <= 1`, `(R-d)*b - d` is below both. Extra events only
    ///      add to `consumed` and can only lower the floor, so the bound holds a fortiori.
    ///      Net effect: it cannot under-mark. It may over-mark (NAV lower, exits cheaper, remaining
    ///      seniors protected) but only TRANSIENTLY — every term it nets belongs to a live default
    ///      that reaches a terminal state (resolve/realize/recover) and releases, so the over-mark
    ///      clears rather than stranding. A STUCK over-mark is NOT the safe direction (H-2/C-1: it
    ///      zeroes `redemptionTotalAssets()` against a solvent vault); the H-2 re-anchor and the
    ///      release paths are precisely what hold the over-marks here transient and clearable.
    function pendingSeniorImpairment() external view returns (uint256) {
        DefaultStorage storage $ = _storage();
        uint256 residual = 0;
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            // AUDIT FIX (H-5, REDESIGN): a merely-past-due facility depresses the conservative NAV
            // just as a declared default does — the honest mark once a payment is overdue. It is a
            // SEPARATE pool (it never sets `Defaulted` and never consumes sGROVE coverage), but it
            // absorbs against the SAME per-class curator first-loss, so it is added to `d` before the
            // curator netting. It cannot under-mark: it only ever ADDS to the impairment.
            uint256 d = $.declaredDefaultedPrincipal[classId] + $.pastDuePrincipal[classId];
            if (d == 0) continue;
            uint256 curatorCap = $.curator.poolBalance(classId); // layer 1 (per class)
            if (d > curatorCap) residual += d - curatorCap;
        }
        if (residual == 0) return 0;
        // layer 2 (global sGROVE), zero until wired
        uint256 backstopCap = address($.backstop) != address(0) ? $.backstop.coverageCapacity() : 0;
        uint256 consumed = $.liveDefaultCoverageConsumed;
        if (consumed != 0) {
            // A live default has already drawn. Its ceiling was fixed by the snapshot taken at
            // that draw, so cap the netting at the capacity standing then -- otherwise a
            // permissionless `fundCoverage` or a `setPerEventCap` rise would hand it coverage
            // it can no longer reach, and the mark would silently go back to under-marking.
            uint256 floorNow = $.liveDefaultCapacityFloor;
            if (floorNow < backstopCap) backstopCap = floorNow;
            // ...and coverage already spent is not available to be spent again.
            backstopCap = backstopCap > consumed ? backstopCap - consumed : 0;
        }
        return residual > backstopCap ? residual - backstopCap : 0;
    }

    /// @notice Gross live impairment used for protocol-level performance-fee accounting.
    /// @dev Performance fees use the gross live impairment before curator or backstop
    ///      capacity. Junior capital improves the redemption mark but is contributed capital,
    ///      not senior investment performance. The gross amount automatically returns to zero
    ///      when the underlying declared/past-due impairment cures, so no permanent HWM credit
    ///      or explicit release path is required.
    /// @return impairment Gross declared/past-due principal, in 18-decimal USDfr units.
    function performanceFeeImpairment() external view returns (uint256 impairment) {
        DefaultStorage storage $ = _storage();
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            impairment += $.declaredDefaultedPrincipal[classId] + $.pastDuePrincipal[classId];
        }
    }

    /// @notice A facility's remaining declared-but-unrealized contribution to the impairment pool.
    /// @dev Exposed so an independent model can recompute `pendingSeniorImpairment` from first
    ///      principles rather than trusting it — see `invariant_pendingImpairmentNeverUnderMarks`.
    ///      The impairment path has now produced three distinct under-marking bugs, so the
    ///      per-facility inputs are made observable rather than inferred.
    /// @param tokenId The facility.
    /// @return contribution Remaining at-risk principal this facility contributes.
    function defaultedContribution(uint256 tokenId) external view returns (uint256 contribution) {
        return _storage().defaultedContribution[tokenId];
    }

    /// @notice sGROVE coverage already drawn by defaults that are still declared-but-unrealized.
    /// @dev PM-R-11. Deducted from the backstop capacity in `pendingSeniorImpairment` so the
    ///      conservative NAV cannot net coverage a live default has already consumed. Released
    ///      per facility when its impairment contribution reaches zero — a clean resolve, a full
    ///      realization, a full cash recovery re-anchored by `onDefaultRecovery`, or (AUDIT FIX
    ///      H-2) a realization that writes off everything still outstanding after a partial cash
    ///      recovery. Before H-2 that last path did NOT release:
    ///      the contribution stayed pinned at the recovered principal with no way back to
    ///      `Resolved`, so the deduction stranded permanently and under-netted the backstop for
    ///      every later, unrelated default. It is monotone per facility (only ever released,
    ///      never re-consumed after release without a fresh draw), so it does not ratchet upward
    ///      across a deployment's lifetime.
    /// @return consumed The aggregate consumed coverage, in USDfr.
    function liveDefaultCoverageConsumed() external view returns (uint256 consumed) {
        return _storage().liveDefaultCoverageConsumed;
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules()
        external
        view
        returns (
            address bridge,
            address registry,
            address reserves,
            address controller,
            address curator,
            address oracle,
            address vault
        )
    {
        DefaultStorage storage $ = _storage();
        return (
            address($.bridge),
            address($.registry),
            address($.reserves),
            address($.controller),
            address($.curator),
            address($.oracle),
            $.vault
        );
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _consumeExact(
        DefaultStorage storage $,
        uint256 tokenId,
        IAttestationOracle.AttestationKind kind,
        bytes32 expected,
        bool consume
    ) private {
        (bytes32 payload,, bool ok) = $.oracle.latestPayload(tokenId, kind);
        if (!ok || payload != expected) revert DefaultManager_DefaultNotAttested(tokenId);
        if (consume) $.oracle.consume(tokenId, kind);
    }

    /// @dev Attested LTV in bps: outstanding principal over the latest mark. A facility
    ///      with no mark at all cannot use the margin path (reverts NoValuation).
    function _ltv(DefaultStorage storage $, uint256 tokenId) private view returns (uint256 ltvBps, uint64 asOf) {
        uint256 value;
        (value, asOf) = $.oracle.latestValuation(tokenId);
        if (value == 0) revert DefaultManager_NoValuation(tokenId);
        ltvBps = $.reserves.deployedTo(tokenId) * Config.BPS / value;
    }

    /// @dev The margin path exists only for live marked-to-market facilities.
    function _mtmFacility(DefaultStorage storage $, uint256 tokenId)
        private
        view
        returns (ClaimBridge.Facility memory f, ICollateralRegistry.ClassParams memory p)
    {
        f = $.bridge.facility(tokenId);
        p = $.registry.classParams(f.classId);
        if (p.model != ICollateralRegistry.CollateralModel.MarkedToMarket) {
            revert DefaultManager_NotMarkedToMarket(tokenId);
        }
        if (f.state != ClaimBridge.LoanState.Active && f.state != ClaimBridge.LoanState.Amortizing) {
            revert DefaultManager_NotDefaultable(tokenId);
        }
    }

    function _requireKnownClass(uint256 classId) private pure {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert DefaultManager_UnknownClass(classId);
    }

    /// @dev ADR-0022: capture the loan's current outstanding as its at-risk contribution to the
    ///      class's unrealized-impairment pool. Called once, when the loan enters default.
    function _recordDefaulted(DefaultStorage storage $, uint256 tokenId, uint256 classId) private {
        uint256 outstanding = $.reserves.deployedTo(tokenId);
        $.defaultedContribution[tokenId] = outstanding;
        $.declaredDefaultedPrincipal[classId] += outstanding;
    }

    /// @dev ADR-0022: reduce a loan's impairment contribution (and its class pool) by up to
    ///      `amount` (clamped so a partial/over realizeLoss can never underflow the pool), then
    ///      re-anchor what is left to the principal that is actually still at risk.
    ///
    ///      AUDIT FIX (H-2). The contribution was snapshotted from `deployedTo` at declare and
    ///      only ever decremented by realized loss, but a principal RECOVERY on a defaulted
    ///      facility (`WaterfallEngine.distribute` on a Defaulted/Accelerated loan) reduces
    ///      `deployedTo` without telling this contract. Recover part, write off the rest, and the
    ///      loan lands at `deployedTo == 0` with a contribution equal to the CASH RECOVERED —
    ///      stranded forever, because `Resolved` is only reachable through `distribute`'s
    ///      `outstanding == 0` branch and `distribute` reverts once outstanding is zero. The
    ///      stranded mark also pinned `liveDefaultCoverageConsumed` and its capacity floor, which
    ///      then under-netted the backstop for every FUTURE default too.
    ///
    ///      The re-anchor is `min(remaining, deployedTo(tokenId))`, taken AFTER
    ///      `recordPrincipalWritedown` so `deployedTo` is already net of this loss. It cannot
    ///      UNDER-mark: `realizeLoss` reverts when `loss > deployedTo(tokenId)`, so the largest
    ///      senior loss this facility can ever still produce is exactly its current
    ///      `deployedTo`, and `deployedTo` never rises for a defaulted loan (it only grows in
    ///      `recordDeployment`/`recordFeeCapitalization`, both reachable only from a Pending
    ///      facility). Everything the clamp removes is principal that is provably no longer
    ///      losable — either repaid in cash or already written down.
    ///
    ///      BELT AND BRACES ONLY, since the H-2 remediation. `onDefaultRecovery` now re-anchors
    ///      at RECOVERY time, so on the wired path this clamp finds `derecognized == 0` and is a
    ///      no-op. It still fires — and must be kept — when the engine's `defaultManager` wiring
    ///      is zero (the optional-wiring configuration `WaterfallEngine.distribute` explicitly
    ///      supports), which is the only remaining way `deployedTo` can fall behind the mark.
    ///
    ///      THREAT MODEL: the no-under-mark argument depends on CREDIT_ROLE being held by
    ///      protocol modules only. A CREDIT_ROLE grant to an EOA could call
    ///      `ReserveManager.recordPrincipalReturn`/`recordPrincipalWritedown` directly, dropping
    ///      `deployedTo` with no cash arriving and no cascade run, after which this clamp would
    ///      de-recognise a genuine loss.
    function _reduceDefaulted(DefaultStorage storage $, uint256 tokenId, uint256 classId, uint256 amount) private {
        uint256 c = $.defaultedContribution[tokenId];
        uint256 dec = amount < c ? amount : c;
        uint256 remaining = c - dec;
        // H-2: principal recovered in cash since the declare is no longer at risk.
        uint256 stillAtRisk = $.reserves.deployedTo(tokenId);
        uint256 derecognized = stillAtRisk < remaining ? remaining - stillAtRisk : 0;
        dec += derecognized;
        if (dec != 0) {
            $.defaultedContribution[tokenId] = c - dec;
            $.declaredDefaultedPrincipal[classId] -= dec;
        }
        // The realized part is already reported by `LossRealized`; the clamped part is
        // impairment de-recognised WITHOUT a loss, so it emits the same event the clean-resolve
        // path uses — the impairment pool stays reconstructable from events alone.
        if (derecognized != 0) emit DefaultImpairmentCleared(tokenId, classId, derecognized);
        // PM-R-11: once nothing of this default is left unrealized it stops depressing the
        // NAV, so the coverage it consumed must stop being deducted too -- otherwise a
        // long-lived deployment would ratchet the deduction up forever and permanently
        // over-mark impairment.
        if ($.defaultedContribution[tokenId] == 0) _releaseCoverageConsumption($, tokenId);
    }

    /// @dev PM-R-11: drop `tokenId`'s recorded sGROVE consumption from the live aggregate.
    ///      Idempotent -- a second call is a no-op, so the two callers cannot double-release.
    function _releaseCoverageConsumption(DefaultStorage storage $, uint256 tokenId) private {
        uint256 consumed = $.coverageConsumedByDefault[tokenId];
        if (consumed != 0) {
            $.coverageConsumedByDefault[tokenId] = 0;
            $.liveDefaultCoverageConsumed -= consumed;
        }
        // Once nothing live holds consumption, the pinned floor has no subject: drop it so a
        // later, unrelated default nets against the capacity actually standing at its own draw.
        if ($.liveDefaultCoverageConsumed == 0) $.liveDefaultCapacityFloor = 0;
    }

    /// @dev AUDIT FIX (H-5, REDESIGN): remove a facility's reversible past-due mark from the
    ///      per-facility, per-class and global aggregates and clear its flag. Idempotent — a no-op
    ///      for a facility that is not flagged — so its callers cannot double-release. Callers:
    ///      `declareDefault` (calls it unconditionally to CONVERT a past-due facility to the
    ///      declared pool), `clearPastDue` (servicer cure, guards on the flag first), and
    ///      `onPerformingRepayment` (full-repayment branch). Together with the partial-repayment
    ///      re-anchor in `onPerformingRepayment` (which shrinks `pastDuePrincipal`/`pastDueExposure`
    ///      directly), these are the ONLY ways the past-due pool shrinks, so it always equals the
    ///      sum of the live per-facility contributions.
    function _releasePastDue(DefaultStorage storage $, uint256 tokenId, uint256 classId) private {
        if (!$.pastDueMarked[tokenId]) return;
        uint256 c = $.pastDueContribution[tokenId];
        $.pastDueMarked[tokenId] = false;
        $.pastDueContribution[tokenId] = 0;
        $.pastDuePrincipal[classId] -= c;
        $.pastDueExposure -= c;
        emit PastDueCleared(tokenId, classId, c);
    }

    /// @dev One bump per externally observable risk transition. Checked arithmetic deliberately
    ///      fails loudly at the theoretical uint256 limit rather than wrapping and reviving a
    ///      centuries-old assessment.
    function _advanceImpairmentRevision(DefaultStorage storage $) private {
        $.impairmentRevision += 1;
        emit ImpairmentRevisionAdvanced($.impairmentRevision);
    }

    /// @dev INCOMING candidate: must declare the full backstop interface AND be readable.
    ///      Identity is required here — a replacement that merely mimics `coverageCapacity()`
    ///      but lacks the loss-delivery surface must never be installed.
    function _validateBackstop(address backstop_) private view {
        if (backstop_ == address(0)) return; // unsetting the backstop stays permitted
        if (!_declaresBackstopInterface(backstop_)) revert DefaultManager_InvalidBackstop(backstop_);
        if (!_isBackstopReadable(backstop_)) revert DefaultManager_InvalidBackstop(backstop_);
    }

    /// @dev ERC-165 identity probe, bounded so a hostile candidate cannot burn the caller's
    ///      gas. Deliberately SEPARATE from `_isBackstopReadable`: identity is an
    ///      installation question, readability is a valuation question, and conflating them
    ///      made a healthy incumbent that predates this check look broken (audit R14-04).
    function _declaresBackstopInterface(address backstop_) private view returns (bool declares) {
        bytes memory interfaceCall = abi.encodeCall(IERC165.supportsInterface, (type(ICascadeBackstop).interfaceId));
        assembly ("memory-safe") {
            mstore(0x00, 0)
            let success :=
                staticcall(BACKSTOP_PROBE_GAS, backstop_, add(interfaceCall, 0x20), mload(interfaceCall), 0x00, 0x20)
            declares := and(and(success, iszero(lt(returndatasize(), 0x20))), eq(mload(0x00), 1))
        }
    }

    /// @dev OUTGOING dependency: can the conservative NAV be read through it RIGHT NOW?
    ///      This asks only about the capacity read, deliberately NOT about ERC-165 identity.
    ///      `setBackstop` uses it to choose its checkpoint ordering, and an incumbent that
    ///      predates the identity check is functionally perfect for that purpose — gating on
    ///      identity here routed an ordinary rotation onto the broken-backstop incident path
    ///      (audit R14-04). Installation identity is enforced by `_validateBackstop`.
    function _isBackstopReadable(address backstop_) private view returns (bool readable) {
        if (backstop_ == address(0)) return true;
        if (backstop_.code.length == 0) return false;
        bytes memory callData = abi.encodeCall(ICascadeBackstop.coverageCapacity, ());
        assembly ("memory-safe") {
            // Copy at most one word so a malicious return-data payload cannot make
            // validation allocate unbounded memory. Bound gas so a broken outgoing
            // backstop cannot consume the replacement transaction's repair reserve.
            let success := staticcall(BACKSTOP_PROBE_GAS, backstop_, add(callData, 0x20), mload(callData), 0x00, 0x20)
            readable := and(success, iszero(lt(returndatasize(), 0x20)))
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (DefaultStorage storage $) {
        assembly {
            $.slot := DEFAULT_STORAGE_LOCATION
        }
    }
}
