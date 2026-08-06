// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title CollateralRegistry
/// @notice Governance-set parameters for the five collateral classes (ADR-0003 as
///         amended; ADR-0015 for the marked-to-market class) and the book's
///         concentration accounting: per-class, per-borrower, and per-state limits are
///         enforced here at every exposure increase — the on-chain diversification
///         guarantee (CLAUDE.md §1.3 concentration invariant).
/// @dev CONCENTRATION SEMANTICS (AUDIT FIX M-02 — read this before quoting the limits as
///      a continuous cap).
///
///      THE ADMISSION RULE, in one sentence: no exposure increase may leave the class,
///      borrower or state it touches holding more than its `limitBps` share of
///      `max(post-trade book, concentrationFloor)`.
///
///      The bootstrap floor is a FLOOR ON THE ASSUMED BOOK SIZE, not an exemption from the
///      limits. A young book is inherently concentrated (the first facility is 100% of it),
///      so measuring against `max(book, floor)` lets the book be built while still capping
///      every dimension in absolute terms at `limitBps * floor / BPS` — at the launch
///      defaults that is 8.75m per class (3500bps), 3.75m per borrower (1500bps) and 6.25m
///      per state (2500bps) against a 25m floor. The rule is continuous at the floor
///      (`book == floor` gives the same number both ways) and monotone in the amount added,
///      so `concentrationHeadroom` is its exact inverse. It is never inert at any
///      configuration, and it does not depend on any new storage slot — an upgraded proxy
///      whose new slots read zero still enforces it.
///
///      Limits are an ADMISSION control, not a standing property, and they cannot be
///      anything else: exposure falls through repayment, default write-down and the
///      retirement of an unfunded facility, and none of those may ever be blocked — a
///      concentration check able to revert `realizeLoss` would let a risk limit veto a loss
///      being realized, inverting the three-layer cascade. A shrinking book therefore
///      mechanically raises the SHARE held by whatever did not shrink. What this contract
///      guarantees is:
///        1. no increase may leave a dimension above its limit measured against
///           `max(post-trade book, floor)` — including an increase that would CREATE a
///           fresh breach on a mature book, and an increase that would DEEPEN a standing
///           one on a book of any size;
///        2. a resulting breach is never silent: every transition is evented
///           (`ConcentrationDrift`/`ConcentrationHealed` for classes,
///           `BorrowerConcentrationDrift`/`Healed` and `StateConcentrationDrift`/`Healed`
///           for the other two dimensions) and readable (`isOverConcentrated`,
///           `overConcentratedClasses`, `overConcentratedBorrowers`,
///           `overConcentratedStates`, `classConcentrationBps`, `concentrationHeadroom`).
///           `overConcentratedClasses` is recomputed from the book on every read, so it can
///           never disagree with `isOverConcentrated` — in particular not in the window
///           after an implementation upgrade, before any cached bit has been written.
///      Consequence, and the honest wording for docs and public copy: the book can stand
///      above a limit; it can never be MOVED further above one.
/// @dev DISCLOSURE vs ADMISSION. The breach views and events report the RAW share of the
///      real book (floor-independent), because that is the fact a risk desk needs. The
///      admission rule uses `max(book, floor)`. On a book above the floor the two coincide;
///      below it a young book can read "over limit" and still admit exposure —
///      `concentrationHeadroom` is the sole authority on what is admissible, and the drift
///      events carry `bookAboveFloor` so an alerting pipeline can separate a genuine
///      incident from ordinary bootstrap.
/// @dev Class parameters are launch defaults pending the pre-mainnet economic review
///      (brief Part 11 gate 5). Nothing here characterizes any instrument under
///      securities law (brief Part 0.5).
contract CollateralRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ICollateralRegistry {
    /// @custom:storage-location erc7201:forestroad.storage.CollateralRegistry
    struct RegistryStorage {
        mapping(uint256 classId => ClassParams) classes;
        mapping(uint256 classId => bool) known;
        mapping(uint256 classId => uint256) classExp;
        mapping(bytes32 borrowerId => uint256) borrowerExp;
        mapping(bytes32 stateId => uint256) stateExp;
        uint256 totalExp;
        uint16 borrowerLimitBps; // max share of total book per borrower
        uint16 stateLimitBps; // max share of total book per US state (tax-credit classes)
        // Bootstrap floor: the book size ASSUMED by the relative limits when the real book
        // is smaller, so a young book is not self-blocking while every dimension is still
        // capped at `limitBps * floor / BPS` in absolute terms. Governance-adjustable.
        uint256 concentrationFloor;
        // ── appended after the fields above (namespaced storage: appending is
        //    upgrade-safe). These are EVENT EDGE-DETECTION CACHES ONLY. Every breach view
        //    recomputes from the book, so a slot reading zero on a freshly upgraded proxy
        //    degrades to "announce the standing breach on the next sync", never to
        //    "silently report a clean book". `syncConcentrationBreaches` lets anyone
        //    perform that announcement immediately after an upgrade.
        uint256 overLimitBits; // bit classId-1 set while that class was last seen in breach
        mapping(bytes32 borrowerId => bool) borrowerOverLimit;
        mapping(bytes32 stateId => bool) stateOverLimit;
        // ── PER-BORROWER LIMIT OVERRIDE (append-only TAIL; must stay last) ──────────────
        // The global `borrowerLimitBps` assumes a vertical has many borrowers. That is false
        // for Digital Assets (ADR-0015), which is a SINGLE borrower by construction -- Forest
        // Road's own trading subsidiary. With one borrower the class and borrower dimensions
        // measure the SAME exposure, so the tighter one binds and the class's own limit
        // becomes unreachable configuration. `overridden` is a separate flag rather than
        // treating 0 as "unset", so an override of 0 bps (admit no new exposure -- a
        // wind-down borrower) stays expressible and cannot be confused with "use the global".
        mapping(bytes32 borrowerId => uint16) borrowerLimitOverrideBps;
        mapping(bytes32 borrowerId => bool) borrowerLimitOverridden;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.CollateralRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REGISTRY_STORAGE_LOCATION =
        0xd1052ad481f6f823017e987ee43475f3a84883a50e791c5b4260ba144e440700;

    /// @dev Largest exposure/floor for which `x * Config.BPS` cannot overflow. Every
    ///      admission keeps `totalExp` at or under this, so the concentration arithmetic
    ///      can never panic — least of all on the decrease path, which carries loss
    ///      realization and must never revert.
    uint256 private constant MAX_SAFE_EXPOSURE = type(uint256).max / Config.BPS;

    error Registry_ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes with launch-default limits; classes are seeded by the deploy
    ///         script via `setClass` so genesis parameters are explicit and evented.
    /// @param admin Governance timelock (sets classes and limits).
    /// @param upgrader Upgrade authority (timelock).
    function initialize(address admin, address upgrader) external initializer {
        if (admin == address(0) || upgrader == address(0)) revert Registry_ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        RegistryStorage storage $ = _storage();
        $.borrowerLimitBps = 1_500; // 15% of book per borrower (launch default)
        $.stateLimitBps = 2_500; // 25% of book per state (launch default)
        $.concentrationFloor = 25_000_000e18; // launch default; economic review pending
    }

    // ── governance ───────────────────────────────────────────────────────

    /// @inheritdoc ICollateralRegistry
    function setClass(uint256 classId, ClassParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert Registry_UnknownClass(classId);
        if (bytes(p.name).length == 0 || p.maxLtvBps == 0 || p.maxLtvBps > Config.BPS) revert Registry_BadParams();
        if (p.concentrationLimitBps == 0 || p.concentrationLimitBps > Config.BPS) revert Registry_BadParams();
        if (p.model == CollateralModel.MarkedToMarket) {
            // margin machinery must be coherent: draw < margin-call < liquidation,
            // and marks must have a freshness bound (ADR-0015)
            if (
                p.marginCallLtvBps <= p.maxLtvBps || p.liquidationLtvBps <= p.marginCallLtvBps
                    || p.liquidationLtvBps > Config.BPS || p.maxMarkAge == 0
            ) revert Registry_BadParams();
        } else {
            if (p.marginCallLtvBps != 0 || p.liquidationLtvBps != 0 || p.maxMarkAge != 0) {
                revert Registry_BadParams(); // receivable classes carry no margin params
            }
        }
        RegistryStorage storage $ = _storage();
        // The model selects different valuation, default and liquidation paths. Allowing
        // governance to flip it on a live class could make an existing facility appear in
        // both the receivable past-due pool and the marked-to-market default pool. Launch
        // classes therefore keep their genesis model for their entire lifetime.
        if ($.known[classId] && $.classes[classId].model != p.model) {
            revert Registry_ModelImmutable(classId);
        }
        $.classes[classId] = p;
        $.known[classId] = true;
        emit ClassSet(classId);
        // A tightened limit can put a standing book in breach with no exposure moving;
        // report it here rather than waiting for the next origination or repayment.
        _syncClassBreaches($);
    }

    /// @notice Sets the per-borrower concentration limit (bps of total book).
    function setBorrowerLimit(uint16 limitBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (limitBps == 0 || limitBps > Config.BPS) revert Registry_BadParams();
        _storage().borrowerLimitBps = limitBps;
        emit BorrowerLimitSet(limitBps);
    }

    /// @notice Sets a per-borrower concentration limit that overrides the global one.
    /// @dev Exists for the SINGLE-BORROWER VERTICAL case. `borrowerLimitBps` assumes a class
    ///      has many borrowers; Digital Assets (ADR-0015) has exactly one by construction, so
    ///      the class and borrower dimensions measure the same exposure and the tighter one
    ///      binds -- leaving that class's own `concentrationLimitBps` unreachable. Rather than
    ///      relax the global limit for every borrower in the book, governance names the
    ///      borrower and the number, on the record.
    ///
    ///      Deliberately NOT bounded by the class limit: borrower exposure is tracked GLOBALLY
    ///      across classes (`borrowerExp`), so there is no single class limit to bound it by.
    ///      The class dimension still applies independently, so the effective cap on a
    ///      single-borrower vertical is `min(classLimit, thisOverride)` and raising this
    ///      above the class limit simply makes the class limit binding again.
    ///
    ///      RELATED-PARTY DISCLOSURE: the intended first user of this is Forest Road's own
    ///      digital-assets subsidiary. Raising a related party's concentration allowance is a
    ///      governance act that must be visible, so it is timelocked, evented, and readable
    ///      via `effectiveBorrowerLimitBps`.
    /// @param borrowerId The borrower key.
    /// @param limitBps Max share of the book for this borrower (0 = admit no new exposure).
    function setBorrowerLimitOverride(bytes32 borrowerId, uint16 limitBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (limitBps > Config.BPS) revert Registry_BadParams();
        RegistryStorage storage $ = _storage();
        $.borrowerLimitOverrideBps[borrowerId] = limitBps;
        $.borrowerLimitOverridden[borrowerId] = true;
        emit BorrowerLimitOverrideSet(borrowerId, limitBps);
        _syncBorrowerBreach($, borrowerId); // the breach state may have just changed
    }

    /// @notice Removes a per-borrower override, returning that borrower to the global limit.
    /// @param borrowerId The borrower key.
    function clearBorrowerLimitOverride(bytes32 borrowerId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RegistryStorage storage $ = _storage();
        if (!$.borrowerLimitOverridden[borrowerId]) revert Registry_BadParams();
        delete $.borrowerLimitOverrideBps[borrowerId];
        delete $.borrowerLimitOverridden[borrowerId];
        emit BorrowerLimitOverrideCleared(borrowerId);
        _syncBorrowerBreach($, borrowerId);
    }

    /// @notice Sets the per-state concentration limit (bps of total book).
    function setStateLimit(uint16 limitBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (limitBps == 0 || limitBps > Config.BPS) revert Registry_BadParams();
        _storage().stateLimitBps = limitBps;
        emit StateLimitSet(limitBps);
    }

    /// @notice Sets the bootstrap concentration floor — the book size the relative limits
    ///         assume when the real book is smaller (see the contract-level note).
    /// @dev Bounded so the concentration arithmetic can never overflow. Raising the floor
    ///      raises every dimension's absolute allowance (`limitBps * floor / BPS`) on a book
    ///      below it; it can never disable the relative limits on a book above it. This is
    ///      the same class of governance power as `setClass`'s `concentrationLimitBps` and
    ///      is timelocked identically.
    function setConcentrationFloor(uint256 floor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (floor > MAX_SAFE_EXPOSURE) revert Registry_BadParams();
        _storage().concentrationFloor = floor;
        emit ConcentrationFloorSet(floor);
    }

    // ── exposure accounting (credit layer) ───────────────────────────────

    /// @inheritdoc ICollateralRegistry
    function recordExposureIncrease(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal)
        external
        onlyRole(Roles.CREDIT_ROLE)
    {
        _checkConcentration(classId, borrowerId, stateId, principal);
        RegistryStorage storage $ = _storage();
        $.classExp[classId] += principal;
        $.borrowerExp[borrowerId] += principal;
        if (stateId != bytes32(0)) $.stateExp[stateId] += principal;
        $.totalExp += principal;
        emit ExposureRecorded(classId, borrowerId, stateId, int256(principal));
        _syncClassBreaches($);
        _syncBorrowerBreach($, borrowerId);
        if (stateId != bytes32(0)) _syncStateBreach($, stateId);
    }

    /// @inheritdoc ICollateralRegistry
    function recordExposureDecrease(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal)
        external
        onlyRole(Roles.CREDIT_ROLE)
    {
        RegistryStorage storage $ = _storage();
        if (
            $.classExp[classId] < principal || $.borrowerExp[borrowerId] < principal
                || (stateId != bytes32(0) && $.stateExp[stateId] < principal) || $.totalExp < principal
        ) revert Registry_ExposureUnderflow();
        $.classExp[classId] -= principal;
        $.borrowerExp[borrowerId] -= principal;
        if (stateId != bytes32(0)) $.stateExp[stateId] -= principal;
        $.totalExp -= principal;
        emit ExposureRecorded(classId, borrowerId, stateId, -int256(principal));
        // Reporting only — never a revert path. A repayment, a default write-down and
        // `ClaimBridge.cancelPending` all land here, and none of them may be blocked. The
        // sweep is bounded, division-free and overflow-free (see `_breaches`), so it cannot
        // revert on any state reachable through this contract.
        _syncClassBreaches($);
        _syncBorrowerBreach($, borrowerId);
        if (stateId != bytes32(0)) _syncStateBreach($, stateId);
    }

    /// @inheritdoc ICollateralRegistry
    function syncConcentrationBreaches(bytes32[] calldata borrowerIds, bytes32[] calldata stateIds) external {
        RegistryStorage storage $ = _storage();
        _syncClassBreaches($);
        for (uint256 i = 0; i < borrowerIds.length; ++i) {
            _syncBorrowerBreach($, borrowerIds[i]);
        }
        for (uint256 i = 0; i < stateIds.length; ++i) {
            _syncStateBreach($, stateIds[i]);
        }
    }

    // ── views ────────────────────────────────────────────────────────────

    /// @inheritdoc ICollateralRegistry
    function classParams(uint256 classId) external view returns (ClassParams memory) {
        RegistryStorage storage $ = _storage();
        if (!$.known[classId]) revert Registry_UnknownClass(classId);
        return $.classes[classId];
    }

    /// @inheritdoc ICollateralRegistry
    function checkConcentration(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal)
        external
        view
    {
        _checkConcentration(classId, borrowerId, stateId, principal);
    }

    /// @inheritdoc ICollateralRegistry
    function classExposure(uint256 classId) external view returns (uint256) {
        return _storage().classExp[classId];
    }

    /// @inheritdoc ICollateralRegistry
    function borrowerExposure(bytes32 borrowerId) external view returns (uint256) {
        return _storage().borrowerExp[borrowerId];
    }

    /// @inheritdoc ICollateralRegistry
    function stateExposure(bytes32 stateId) external view returns (uint256) {
        return _storage().stateExp[stateId];
    }

    /// @inheritdoc ICollateralRegistry
    function totalBookExposure() external view returns (uint256) {
        return _storage().totalExp;
    }

    /// @notice Current borrower/state limits (bps of total book) and bootstrap floor.
    function limits() external view returns (uint16 borrowerLimitBps, uint16 stateLimitBps, uint256 floor) {
        RegistryStorage storage $ = _storage();
        return ($.borrowerLimitBps, $.stateLimitBps, $.concentrationFloor);
    }

    /// @inheritdoc ICollateralRegistry
    function classConcentrationBps(uint256 classId) external view returns (uint256) {
        RegistryStorage storage $ = _storage();
        uint256 total = $.totalExp;
        if (total == 0) return 0;
        return Math.mulDiv($.classExp[classId], Config.BPS, total);
    }

    /// @inheritdoc ICollateralRegistry
    /// @dev Floor-independent on purpose: this is the DISCLOSURE fact ("is the book
    ///      actually above the cap right now"), not the admission test. A young book
    ///      below the bootstrap floor can read over-concentrated here and still admit
    ///      exposure — `concentrationHeadroom` is the authority on what is admissible.
    ///      `stateOver` is false when `stateId` is zero (classes carrying no state tag).
    function isOverConcentrated(uint256 classId, bytes32 borrowerId, bytes32 stateId)
        external
        view
        returns (bool classOver, bool borrowerOver, bool stateOver)
    {
        RegistryStorage storage $ = _storage();
        uint256 total = $.totalExp;
        classOver = _breaches($.classExp[classId], $.classes[classId].concentrationLimitBps, total);
        borrowerOver = _breaches($.borrowerExp[borrowerId], _borrowerLimit($, borrowerId), total);
        stateOver = stateId != bytes32(0) && _breaches($.stateExp[stateId], $.stateLimitBps, total);
    }

    /// @inheritdoc ICollateralRegistry
    /// @dev RECOMPUTED, never read from the cache. The cached bitmap exists only so the
    ///      drift/heal events fire once per transition; if it were served here it would
    ///      report a clean book in the window after an implementation upgrade, when the
    ///      appended slot still reads zero. That is the exact silent-breach condition this
    ///      fix exists to remove, so the view does the 5-class sweep itself.
    function overConcentratedClasses() external view returns (uint256 bitmap) {
        RegistryStorage storage $ = _storage();
        uint256 total = $.totalExp;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            if (_breaches($.classExp[c], $.classes[c].concentrationLimitBps, total)) bitmap |= 1 << (c - 1);
        }
    }

    /// @inheritdoc ICollateralRegistry
    function effectiveBorrowerLimitBps(bytes32 borrowerId) external view returns (uint16 limitBps, bool overridden) {
        RegistryStorage storage $ = _storage();
        return (_borrowerLimit($, borrowerId), $.borrowerLimitOverridden[borrowerId]);
    }

    /// @inheritdoc ICollateralRegistry
    function overConcentratedBorrowers(bytes32[] calldata borrowerIds) external view returns (bool[] memory over) {
        RegistryStorage storage $ = _storage();
        uint256 total = $.totalExp;
        over = new bool[](borrowerIds.length);
        for (uint256 i = 0; i < borrowerIds.length; ++i) {
            // per-borrower: the limit is resolved INSIDE the loop, because an override
            // applies to one id and hoisting a single limit would misreport the others.
            over[i] = _breaches($.borrowerExp[borrowerIds[i]], _borrowerLimit($, borrowerIds[i]), total);
        }
    }

    /// @inheritdoc ICollateralRegistry
    function overConcentratedStates(bytes32[] calldata stateIds) external view returns (bool[] memory over) {
        RegistryStorage storage $ = _storage();
        uint256 total = $.totalExp;
        uint16 limitBps = $.stateLimitBps;
        over = new bool[](stateIds.length);
        for (uint256 i = 0; i < stateIds.length; ++i) {
            over[i] = stateIds[i] != bytes32(0) && _breaches($.stateExp[stateIds[i]], limitBps, total);
        }
    }

    /// @inheritdoc ICollateralRegistry
    /// @dev Exact: `checkConcentration(classId, borrowerId, stateId, headroom)` passes and
    ///      `headroom + 1` reverts (fuzzed in the M-02 regression suite). Returns 0 for an
    ///      unknown or inactive class, for which no principal at all is admissible. The
    ///      result is always clamped to a value the admission path can actually accept, so
    ///      a "max" button wired to this view can never produce an undecodable panic — a
    ///      dimension that can never bind reports that clamp rather than `type(uint256).max`.
    function concentrationHeadroom(uint256 classId, bytes32 borrowerId, bytes32 stateId)
        external
        view
        returns (uint256)
    {
        RegistryStorage storage $ = _storage();
        if (!$.known[classId] || !$.classes[classId].active) return 0;
        uint256 total = $.totalExp;
        uint256 floor = $.concentrationFloor;

        uint256 room = _dimHeadroom($.classExp[classId], $.classes[classId].concentrationLimitBps, total, floor);
        uint256 bRoom = _dimHeadroom($.borrowerExp[borrowerId], _borrowerLimit($, borrowerId), total, floor);
        if (bRoom < room) room = bRoom;
        if (stateId != bytes32(0)) {
            uint256 sRoom = _dimHeadroom($.stateExp[stateId], $.stateLimitBps, total, floor);
            if (sRoom < room) room = sRoom;
        }
        return room;
    }

    // ── internals ────────────────────────────────────────────────────────

    /// @dev AUDIT FIX M-02. Every dimension is measured against `max(newTotal, floor)`:
    ///      above the floor that is the plain relative limit, below it an absolute
    ///      allowance of `limitBps * floor / BPS`. Keying the exemption on the BOOK rather
    ///      than on the bucket is what closes both halves of the finding — an origination
    ///      can neither CREATE a fresh breach on a mature book by staying under an absolute
    ///      floor, nor DEEPEN a standing one on a book of any size, at any floor setting.
    ///      A zero principal is always admitted: it moves nothing, so it can neither create
    ///      nor deepen a breach, and `checkConcentration(..., 0)` must stay a pure no-op.
    /// @dev The borrower limit actually in force: the per-borrower override when governance
    ///      has set one, else the global limit. EVERY read site -- admission, breach sync,
    ///      headroom and the disclosure views -- routes through here, so admission and
    ///      disclosure can never disagree about which number applies.
    /// @param $ Registry storage.
    /// @param borrowerId The borrower key.
    /// @return limitBps The effective limit in bps.
    function _borrowerLimit(RegistryStorage storage $, bytes32 borrowerId) private view returns (uint16 limitBps) {
        return $.borrowerLimitOverridden[borrowerId] ? $.borrowerLimitOverrideBps[borrowerId] : $.borrowerLimitBps;
    }

    function _checkConcentration(uint256 classId, bytes32 borrowerId, bytes32 stateId, uint256 principal)
        private
        view
    {
        RegistryStorage storage $ = _storage();
        if (!$.known[classId]) revert Registry_UnknownClass(classId);
        ClassParams storage p = $.classes[classId];
        if (!p.active) revert Registry_ClassInactive(classId);
        if (principal == 0) return;

        uint256 total = $.totalExp;
        // Keeps the book (and therefore every dimension) inside the range where the
        // concentration arithmetic cannot overflow, and fails with a decodable error rather
        // than a panic if a caller ever feeds an absurd principal.
        if (principal > MAX_SAFE_EXPOSURE - total) revert Registry_PrincipalTooLarge();
        uint256 floor = $.concentrationFloor;
        uint256 newTotal = total + principal;
        uint256 base = newTotal > floor ? newTotal : floor;

        uint256 wouldBe = $.classExp[classId] + principal;
        if (_breaches(wouldBe, p.concentrationLimitBps, base)) {
            revert Registry_ConcentrationExceeded(classId, wouldBe, p.concentrationLimitBps);
        }

        wouldBe = $.borrowerExp[borrowerId] + principal;
        uint16 bLimit = _borrowerLimit($, borrowerId);
        if (_breaches(wouldBe, bLimit, base)) {
            revert Registry_BorrowerConcentrationExceeded(borrowerId, wouldBe, bLimit);
        }

        if (stateId != bytes32(0)) {
            wouldBe = $.stateExp[stateId] + principal;
            if (_breaches(wouldBe, $.stateLimitBps, base)) {
                revert Registry_StateConcentrationExceeded(stateId, wouldBe, $.stateLimitBps);
            }
        }
    }

    /// @dev Raw share test: does `exp` exceed `limitBps` of a book of `base`? Uses
    ///      `Math.mulDiv` (512-bit intermediate) so it CANNOT overflow for any inputs —
    ///      the decrease path calls this and must never be able to revert. Exact for
    ///      integers: `exp * BPS > limitBps * base` iff `exp > floor(limitBps * base / BPS)`.
    ///      An empty book reads false rather than dividing by zero.
    function _breaches(uint256 exp, uint16 limitBps, uint256 base) private pure returns (bool) {
        return exp > Math.mulDiv(uint256(limitBps), base, Config.BPS);
    }

    /// @dev Largest principal admissible on one dimension — the exact inverse of the
    ///      `_checkConcentration` rule, which is monotone in the amount added (the added
    ///      amount enters the left side with coefficient 1 and the right side with
    ///      coefficient `limitBps/BPS < 1`, or 0 below the floor), so the admissible set is
    ///      downward closed and the maximum is well defined.
    ///
    ///      Two regimes, whose union is taken:
    ///        A. `total + p <= floor` — measured against the floor, so `p <= limitBps *
    ///           floor / BPS - cur`, capped at `floor - total`;
    ///        B. `total + p > floor` — measured against the post-trade book, so
    ///           `p * (BPS - limitBps) <= limitBps * total - cur * BPS`.
    ///      The result is clamped to `MAX_SAFE_EXPOSURE - total` so the number handed back
    ///      is always one `checkConcentration` will accept rather than panic on.
    function _dimHeadroom(uint256 cur, uint16 limitBps, uint256 total, uint256 floor) private pure returns (uint256) {
        if (total >= MAX_SAFE_EXPOSURE) return 0;
        uint256 clamp = MAX_SAFE_EXPOSURE - total;
        if (floor > MAX_SAFE_EXPOSURE) floor = MAX_SAFE_EXPOSURE; // defensive: pre-bound state
        uint256 room = 0; // explicit: "nothing admissible" is the default answer

        // regime A — the bootstrap allowance, an ABSOLUTE cap of limitBps of the floor
        if (total <= floor) {
            uint256 allowance = Math.mulDiv(uint256(limitBps), floor, Config.BPS);
            if (allowance > cur) {
                uint256 a = allowance - cur;
                uint256 b = floor - total;
                room = a < b ? a : b;
            }
        }

        // regime B — the relative limit on the post-trade book
        uint256 ratioRoom;
        if (limitBps >= Config.BPS) {
            ratioRoom = clamp; // a dimension capped at the whole book can never bind
        } else {
            uint256 lhs = uint256(limitBps) * total;
            uint256 rhs = cur * Config.BPS;
            ratioRoom = lhs <= rhs ? 0 : (lhs - rhs) / (Config.BPS - uint256(limitBps));
        }
        // regime B only exists for amounts that actually push the book past the floor
        uint256 minForB = total > floor ? 0 : floor - total + 1;
        if (ratioRoom >= minForB && ratioRoom > room) room = ratioRoom;

        return room > clamp ? clamp : room;
    }

    /// @dev Recomputes which classes stand above their limit and events every transition
    ///      (AUDIT FIX M-02). Bounded to `Config.NUM_CLASSES`, read-only on exposure, and
    ///      incapable of reverting — it is called from the decrease path, which carries
    ///      repayments, default write-downs and cancellations and must never be blocked.
    function _syncClassBreaches(RegistryStorage storage $) private {
        uint256 total = $.totalExp;
        uint256 prev = $.overLimitBits;
        bool aboveFloor = total > $.concentrationFloor;
        uint256 next = 0; // explicit: the recomputed breach set, bit classId-1
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint16 limitBps = $.classes[c].concentrationLimitBps;
            uint256 exp = $.classExp[c];
            uint256 bit = 1 << (c - 1);
            if (_breaches(exp, limitBps, total)) {
                next |= bit;
                if (prev & bit == 0) emit ConcentrationDrift(c, exp, total, limitBps, aboveFloor);
            } else if (prev & bit != 0) {
                emit ConcentrationHealed(c, exp, total, limitBps, aboveFloor);
            }
        }
        if (next != prev) $.overLimitBits = next;
    }

    /// @dev Per-borrower edge-detected disclosure. The borrower key set is unbounded and
    ///      not enumerable on-chain, so this fires for the borrower a write touches;
    ///      `syncConcentrationBreaches` covers any other id, and the full key set is
    ///      recoverable from the `ExposureRecorded` event stream. Cannot revert.
    function _syncBorrowerBreach(RegistryStorage storage $, bytes32 borrowerId) private {
        uint256 total = $.totalExp;
        uint16 limitBps = _borrowerLimit($, borrowerId);
        uint256 exp = $.borrowerExp[borrowerId];
        bool over = _breaches(exp, limitBps, total);
        if (over == $.borrowerOverLimit[borrowerId]) return;
        $.borrowerOverLimit[borrowerId] = over;
        bool aboveFloor = total > $.concentrationFloor;
        if (over) emit BorrowerConcentrationDrift(borrowerId, exp, total, limitBps, aboveFloor);
        else emit BorrowerConcentrationHealed(borrowerId, exp, total, limitBps, aboveFloor);
    }

    /// @dev Per-state counterpart of `_syncBorrowerBreach`. Cannot revert.
    function _syncStateBreach(RegistryStorage storage $, bytes32 stateId) private {
        if (stateId == bytes32(0)) return;
        uint256 total = $.totalExp;
        uint16 limitBps = $.stateLimitBps;
        uint256 exp = $.stateExp[stateId];
        bool over = _breaches(exp, limitBps, total);
        if (over == $.stateOverLimit[stateId]) return;
        $.stateOverLimit[stateId] = over;
        bool aboveFloor = total > $.concentrationFloor;
        if (over) emit StateConcentrationDrift(stateId, exp, total, limitBps, aboveFloor);
        else emit StateConcentrationHealed(stateId, exp, total, limitBps, aboveFloor);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := REGISTRY_STORAGE_LOCATION
        }
    }
}
