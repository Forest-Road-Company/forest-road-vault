// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ComplianceRegistry} from "./ComplianceRegistry.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title PointsModule — participation points (ADR-0016, as amended 2026-07-14)
/// @notice A non-transferable participation ledger with THREE per-wallet position types,
///         each accruing `B × ∫ m(τ−S) dτ × rate(τ) × mult / (1 day × unit)`:
///         - sUSDfr shares (mult 1×, also earns the vault yield),
///         - USDfr holdings (mult = usdfrMultiplier, in lieu of yield),
///         - curator first-loss capital per class (mult = curatorMultiplier — the most
///           subordinated capital earns the most points; P-01).
///         `m` is the 1.0×→2.0× maturity ramp (patience favored). Accrual is permissionless
///         per wallet and sybil-safe (linear in balance; a fresh wallet resets the ramp).
///
///         ECONOMIC-INTEGRITY HARDENING (points may inform a future GROVE allocation):
///         - Protocol-exempt addresses (vault/queue/reserves/…) never accrue — they custody
///           balances, they are not participants (skips the vault accruing on staked TVL).
///         - Curator first-loss capital DOES accrue, via a dedicated CuratorModule hook,
///           even though the CuratorModule stays compliance-exempt (P-01).
///         - Rate/multiplier changes are NON-RETROACTIVE: they append a rate EPOCH and each
///           position integrates the rate active in each interval since its last checkpoint
///           (P-03), so a change never reprices already-elapsed time.
///         - `reconcile(wallet)` resets a wallet's positions to its LIVE token / curator
///           balances — the fix for exemption-toggle desync (P-02) and for a fail-open hook
///           silently dropping a transition (P-04).
///
///         HONEST FRAMING (binding, brief Part 0.5): points measure contribution. They are
///         NOT a claim on any token; any future utility is discretionary and counsel-gated.
/// @dev Clean-deployment implementation: curator loss hooks always include the post-loss
///      class balance and survival ratio; no legacy migration or one-argument hook exists.
contract PointsModule is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    uint256 public constant MATURITY_RAMP = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SHARE_UNIT = 1e24; // one whole sUSDfr (offset-6 vault)
    uint256 internal constant USDFR_UNIT = 1e18; // one whole USDfr (and curator USDfr)
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_RATE_PER_UNIT_DAY = 1e9 * 1e18;
    uint32 internal constant MAX_MULTIPLIER_BPS = 200_000; // 20× ceiling (bounds accrual product)

    uint8 internal constant KIND_SHARES = 0; // mult 1×
    uint8 internal constant KIND_USDFR = 1; // mult = usdfrMultiplier
    uint8 internal constant KIND_CURATOR = 2; // mult = curatorMultiplier

    /// @dev A wallet's position in one token stream. Safe-to-extend (mapping-value struct);
    ///      new members are TAIL-APPENDED only (H-03 added `seenLossEpoch`, which packs into
    ///      the previously-unused high 64 bits of the third slot — no reorder, no insert).
    struct Position {
        uint256 balance;
        uint256 accrued;
        uint64 maturityStart;
        uint64 lastAccrual;
        uint32 lastEpochIdx; // rate epoch active at the last checkpoint (P-03)
        uint32 classId; // 0 for shares/USDfr; the class for a curator position (loss-cap key)
        // H-03 (TIME axis): how many of the class's loss events this position has been
        // RECONCILED through. `seenLossEpoch < curatorLossTimes[classId].length` ⇒ the position
        // is FROZEN, durably: it accrues nothing past the first un-reconciled loss instant.
        uint64 seenLossEpoch;
        // ── H-03 (BALANCE/MATURITY axis) — trailing slots, mapping-value struct only ──
        // The cumulative class survival factor this position's cached `balance` has already
        // been diluted by, and the class loss-round it belongs to. `absorbLoss` dilutes every
        // curator in a class EXACTLY pro-rata (shares untouched, pool balance reduced), so the
        // cached balance can be corrected without a per-curator hook. Without this, a curator
        // who topped back up to their PRE-LOSS notional saw `newPosted == cachedBalance`, no
        // `_track` ran, and the replacement capital silently inherited the destroyed capital's
        // maturity ramp — the H-03 harm reached by a second path.
        uint256 seenSurvivalWad; // 0 == WAD (unset)
        uint64 seenLossRound;
    }

    /// @dev A rate epoch: the rate/multipliers active from `start` until the next epoch.
    ///
    ///      AUDIT FIX (G1b): LAYOUT-FROZEN: this is an ARRAY element (`rateEpochs` below) and it
    ///      was the one fixed-stride struct in the protocol carrying no such warning, while
    ///      `SGrove.Unbond` and `RedemptionQueue.Request` both did. Array elements are laid out
    ///      contiguously, so adding, reordering or retyping ANY field changes the stride and
    ///      shifts every epoch after index 0 on the deployed proxy — silently repricing every
    ///      historical accrual interval. NEVER extend this struct on an upgrade; tail-extend the
    ///      namespaced `PointsStorage` root (or a mapping-value struct) instead. Do not delete
    ///      this warning: `tools/check-storage-layout.mjs` now REQUIRES that marker on every
    ///      fixed-stride struct it reaches, and deleting it fails the gate.
    struct RateEpoch {
        uint64 start;
        uint32 usdfrMultBps;
        uint32 curatorMultBps;
        uint256 ratePerUnitDay;
    }

    /// @custom:storage-location erc7201:forestroad.storage.PointsModule
    struct PointsStorage {
        ComplianceRegistry compliance; // protocol-exempt set
        address vault; // sUSDfr — sole caller of onSharesTransfer
        address usdfrToken; // USDfr — sole caller of onUSDfrTransfer
        address curatorModule; // CuratorModule — sole caller of onCuratorStakeChange
        RateEpoch[] rateEpochs; // append-only; index 0 is genesis (P-03)
        mapping(address => Position) sPos; // sUSDfr shares
        mapping(address => Position) uPos; // USDfr
        mapping(address => mapping(uint256 => Position)) cPos; // curator first-loss per class
        uint256 totalTrackedShares;
        uint256 totalTrackedUsdfr;
        uint256 totalTrackedCurator;
        // AUDIT FIX: last time a class absorbed a loss. Retained for observability only — the
        // freeze is driven by the per-loss epoch log below (H-03), because a single overwritable
        // timestamp re-opened the accrual window for positions frozen by an EARLIER loss.
        mapping(uint256 classId => uint64) lastCuratorLossAt;
        // ── H-03 tail extension (append-only; never reorder or insert above this line) ──
        // Append-only, non-decreasing log of the instants at which `classId` absorbed a loss.
        // A curator position is frozen at `curatorLossTimes[classId][p.seenLossEpoch]` — the
        // FIRST loss it has not been reconciled through — so a later loss can never move the
        // freeze instant forward, and a permissionless `checkpoint()` can never step over it.
        mapping(uint256 classId => uint64[]) curatorLossTimes;
        // Class loss ROUND — bumped whenever a loss wipes the class pool to zero, or whenever a
        // loss arrives WITHOUT a usable dilution ratio (a legacy one-argument `onCuratorLoss`,
        // or a migrated pre-upgrade loss). A position whose `seenLossRound` is behind has its
        // cached balance zeroed: nothing about it can be trusted, and `reconcile()` restores it
        // from the live `postedOf`.
        mapping(uint256 classId => uint64) curatorLossRound;
        // Cumulative survival factor within the current loss round, WAD-scaled and monotonically
        // non-increasing (0 == WAD, i.e. no dilution yet this round).
        mapping(uint256 classId => uint256) curatorSurvivalWad;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.PointsModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POINTS_STORAGE_LOCATION =
        0x2b0f9b300e42162fe5738c4f7cc02b34c204f066c1bd41ebe399ed932bb31b00;

    event PointsAccrued(address indexed wallet, uint8 indexed kind, uint256 amount);
    event RateEpochAppended(uint256 indexed index, uint256 ratePerUnitDay, uint32 usdfrMultBps, uint32 curatorMultBps);
    event CuratorModuleSet(address indexed curatorModule);
    event Reconciled(address indexed wallet);
    /// @notice A class absorbed a loss; every un-reconciled curator position in it freezes at `at`.
    /// @param classId The collateral class that absorbed the loss.
    /// @param lossEpoch The zero-based index of this loss in the class's append-only loss log.
    /// @param at The instant of the loss — the accrual ceiling for positions frozen by it.
    /// @param poolBalanceBefore The class first-loss pool balance before absorption.
    /// @param poolBalanceAfter The class first-loss pool balance after absorption. `before` and
    ///        `after` both zero means the ratio was NOT supplied (legacy/migrated loss), in
    ///        which case every cached balance in the class is distrusted outright.
    event CuratorLossRecorded(
        uint256 indexed classId,
        uint256 indexed lossEpoch,
        uint64 at,
        uint256 poolBalanceBefore,
        uint256 poolBalanceAfter
    );
    /// @notice A curator position was reconciled through every recorded loss and resumed accruing.
    /// @param wallet The curator.
    /// @param classId The collateral class of the thawed position.
    /// @param seenLossEpoch The loss-log length the position is now reconciled through.
    event CuratorPositionThawed(address indexed wallet, uint256 indexed classId, uint64 seenLossEpoch);
    /// @notice A curator position's cached first-loss balance was written down to reflect the
    ///         class losses it had not yet absorbed (the pro-rata dilution `absorbLoss` applied).
    /// @param wallet The curator.
    /// @param classId The collateral class.
    /// @param oldBalance The stale-high cached balance.
    /// @param newBalance The diluted balance (0 when the class pool was wiped, or when the
    ///        dilution ratio was unavailable and the balance therefore cannot be trusted).
    event CuratorBalanceDiluted(
        address indexed wallet, uint256 indexed classId, uint256 oldBalance, uint256 newBalance
    );

    error Points_OnlyVault();
    error Points_OnlyUSDfr();
    error Points_OnlyCurator();
    error Points_ZeroAddress();
    error Points_BadRate(uint256 rate);
    error Points_BadMultiplier(uint32 bps);
    error Points_CuratorModuleAlreadySet();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes with the genesis rate epoch (1 point/unit/day, USDfr 3×, curator 5×).
    function initialize(address admin, address upgrader, address compliance, address vault, address usdfrToken)
        external
        initializer
    {
        if (
            admin == address(0) || upgrader == address(0) || compliance == address(0) || vault == address(0)
                || usdfrToken == address(0)
        ) revert Points_ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        PointsStorage storage $ = _storage();
        $.compliance = ComplianceRegistry(compliance);
        $.vault = vault;
        $.usdfrToken = usdfrToken;
        $.rateEpochs.push(
            RateEpoch({
                start: uint64(block.timestamp),
                usdfrMultBps: 30_000,
                curatorMultBps: 50_000,
                ratePerUnitDay: 1e18
            })
        );
        emit RateEpochAppended(0, 1e18, 30_000, 50_000);
    }

    /// @notice Wires the CuratorModule (one-time) so first-loss capital accrues points.
    function setCuratorModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) revert Points_ZeroAddress();
        PointsStorage storage $ = _storage();
        if ($.curatorModule != address(0)) revert Points_CuratorModuleAlreadySet();
        $.curatorModule = module;
        emit CuratorModuleSet(module);
    }

    // ── token / curator hooks (fail-open at the caller) ──────────────────

    /// @notice Called by the sUSDfr vault on every share balance change.
    function onSharesTransfer(address from, address to, uint256 amount) external {
        PointsStorage storage $ = _storage();
        if (msg.sender != $.vault) revert Points_OnlyVault();
        if (amount == 0) return;
        if (from != address(0) && !_excluded($, from)) {
            $.totalTrackedShares -= _untrack($, $.sPos[from], amount, SHARE_UNIT, KIND_SHARES, from);
        }
        if (to != address(0) && !_excluded($, to)) {
            _track($, $.sPos[to], amount, SHARE_UNIT, KIND_SHARES, to);
            $.totalTrackedShares += amount;
        }
    }

    /// @notice Called by USDfr on every balance change (mints, transfers, burns).
    function onUSDfrTransfer(address from, address to, uint256 amount) external {
        PointsStorage storage $ = _storage();
        if (msg.sender != $.usdfrToken) revert Points_OnlyUSDfr();
        if (amount == 0) return;
        if (from != address(0) && !_excluded($, from)) {
            $.totalTrackedUsdfr -= _untrack($, $.uPos[from], amount, USDFR_UNIT, KIND_USDFR, from);
        }
        if (to != address(0) && !_excluded($, to)) {
            _track($, $.uPos[to], amount, USDFR_UNIT, KIND_USDFR, to);
            $.totalTrackedUsdfr += amount;
        }
    }

    /// @notice Called by the CuratorModule when a curator's posted first-loss changes (P-01).
    ///         `newPosted` is the curator's live `postedOf(classId, curator)` after the change;
    ///         the position is reconciled to it (so withdrawals reduce it correctly).
    /// @dev Curators are the beneficiaries (not exempt); first-loss earns at the curator
    ///      multiple even though the CuratorModule itself is compliance-exempt.
    function onCuratorStakeChange(address curator, uint256 classId, uint256 newPosted) external {
        PointsStorage storage $ = _storage();
        if (msg.sender != $.curatorModule) revert Points_OnlyCurator();
        Position storage p = $.cPos[curator][classId];
        p.classId = uint32(classId); // tag the position so _pending applies the loss cap
        // H-03 (BALANCE/MATURITY axis): write the cached balance down by every class loss this
        // position has not yet absorbed BEFORE comparing it to `newPosted`. Otherwise a curator
        // topping back up to their pre-loss notional produced `newPosted == old`, neither
        // `_track` nor `_untrack` ran, and the fresh capital inherited the destroyed capital's
        // maturity ramp — i.e. taking a loss and replacing it out-accrued never taking one.
        _applyCuratorDilution($, p, classId, curator);
        uint256 old = p.balance;
        // H-03: a position with NO cached balance has nothing stale to freeze, so a curator
        // opening (or re-opening) a position from zero starts reconciled through every recorded
        // loss. This is the SECOND path that clears a freeze (see `reconcile`); it is safe
        // because there is no stale capital left to credit, and it emits the thaw so the freeze
        // lifecycle stays reconstructable from events alone.
        if (old == 0 && newPosted != 0) _syncLossWatermark($, p, classId, curator);
        if (newPosted > old) {
            _track($, p, newPosted - old, USDFR_UNIT, KIND_CURATOR, curator);
            $.totalTrackedCurator += newPosted - old;
        } else if (newPosted < old) {
            $.totalTrackedCurator -= _untrack($, p, old - newPosted, USDFR_UNIT, KIND_CURATOR, curator);
        }
    }

    /// @notice Records that `classId` absorbed a loss, WITH the pool balances that bracket the
    ///         absorption (CuratorModule-only). Equal balances are a balance-neutral accounting
    ///         operation, not a loss, and are ignored so representation changes cannot freeze a
    ///         whole class (M-4). For an economic loss, the supplied ratio writes cached balances
    ///         down without a per-curator hook and preserves correct maturity blending on a later
    ///         top-up (H-03).
    /// @param classId The collateral class that absorbed the loss.
    /// @param poolBalanceBefore The class first-loss pool balance immediately before absorption.
    /// @param poolBalanceAfter The class first-loss pool balance immediately after absorption.
    function onCuratorLoss(uint256 classId, uint256 poolBalanceBefore, uint256 poolBalanceAfter) external {
        PointsStorage storage $ = _storage();
        if (msg.sender != $.curatorModule) revert Points_OnlyCurator();
        if (poolBalanceBefore == poolBalanceAfter) return;
        _recordCuratorLoss($, classId, poolBalanceBefore, poolBalanceAfter);
    }

    /// @notice Resets a wallet's positions to its LIVE token/curator balances (P-02/P-04).
    ///         Permissionless and self-correcting: fixes a desync from an exemption toggle or
    ///         a fail-open hook that dropped a transition, and refreshes stale curator
    ///         positions after a loss dilution.
    /// @dev This is the primary path that clears a curator freeze (H-03), and it thaws EVERY
    ///      class at once against the live `postedOf`, so a curator holding several positions
    ///      across several loss events can never end up partially thawed. Accrual over the
    ///      frozen window is forfeited by construction: the cached balance was unverifiable
    ///      there. The only OTHER clear is `onCuratorStakeChange` re-opening a position from a
    ///      zero cached balance, which has no stale capital to credit.
    /// @param wallet The wallet to reconcile (permissionless — anyone may call it for anyone).
    function reconcile(address wallet) external {
        PointsStorage storage $ = _storage();
        bool exempt = _excluded($, wallet);
        _reconcile(
            $, $.sPos[wallet], exempt ? 0 : IERC20($.vault).balanceOf(wallet), SHARE_UNIT, KIND_SHARES, wallet, 0
        );
        _reconcile(
            $, $.uPos[wallet], exempt ? 0 : IERC20($.usdfrToken).balanceOf(wallet), USDFR_UNIT, KIND_USDFR, wallet, 1
        );
        if ($.curatorModule != address(0)) {
            for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
                Position storage cp = $.cPos[wallet][c];
                cp.classId = uint32(c); // tag for the loss cap
                // Write the cached balance down by any un-absorbed class dilution first, so the
                // snap below is an honest delta and `_track` blends maturity on genuinely new
                // capital only.
                _applyCuratorDilution($, cp, c, wallet);
                uint256 target = ICuratorModule($.curatorModule).postedOf(c, wallet);
                // Accrue under the freeze cap FIRST (so the frozen window earns nothing), snap
                // the balance to the live posted amount, and only then clear the freeze.
                _reconcile($, cp, target, USDFR_UNIT, KIND_CURATOR, wallet, 2);
                _thawCurator($, cp, c, wallet);
            }
        }
        emit Reconciled(wallet);
    }

    /// @notice Checkpoints a wallet's positions (harmless anytime; keeps reads warm).
    /// @dev A checkpoint can only ever move a curator position DOWN: it applies any outstanding
    ///      pro-rata loss dilution to the cached balance, and it can NEVER clear a freeze
    ///      (H-03 — the original bypass was exactly a permissionless checkpoint resuming
    ///      accrual on wiped capital).
    function checkpoint(address wallet) external {
        PointsStorage storage $ = _storage();
        _accrue($, $.sPos[wallet], SHARE_UNIT, KIND_SHARES, wallet);
        _accrue($, $.uPos[wallet], USDFR_UNIT, KIND_USDFR, wallet);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            Position storage cp = $.cPos[wallet][c];
            // Only touch the dilution watermark of a position that actually holds first-loss —
            // otherwise every checkpoint of every wallet would write 2 slots per lossy class.
            if (cp.balance != 0) _applyCuratorDilution($, cp, c, wallet);
            _accrue($, cp, USDFR_UNIT, KIND_CURATOR, wallet);
        }
    }

    // ── governance (rate epochs — non-retroactive, P-03) ─────────────────

    /// @notice Sets the base accrual rate; appends a rate epoch (applies going forward only).
    function setRate(uint256 ratePerUnitDay_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ratePerUnitDay_ > MAX_RATE_PER_UNIT_DAY) revert Points_BadRate(ratePerUnitDay_);
        RateEpoch storage cur = _current();
        _appendEpoch(ratePerUnitDay_, cur.usdfrMultBps, cur.curatorMultBps);
    }

    /// @notice Sets the USDfr multiple of the base rate (bps); appends a rate epoch.
    function setUSDfrMultiplier(uint32 multiplierBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (multiplierBps == 0 || multiplierBps > MAX_MULTIPLIER_BPS) revert Points_BadMultiplier(multiplierBps);
        RateEpoch storage cur = _current();
        _appendEpoch(cur.ratePerUnitDay, multiplierBps, cur.curatorMultBps);
    }

    /// @notice Sets the curator first-loss multiple (bps); appends a rate epoch.
    function setCuratorMultiplier(uint32 multiplierBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (multiplierBps == 0 || multiplierBps > MAX_MULTIPLIER_BPS) revert Points_BadMultiplier(multiplierBps);
        RateEpoch storage cur = _current();
        _appendEpoch(cur.ratePerUnitDay, cur.usdfrMultBps, multiplierBps);
    }

    // ── views ────────────────────────────────────────────────────────────

    /// @notice Total points of `wallet` across all three position types.
    function pointsOfWallet(address wallet) public view returns (uint256 total) {
        PointsStorage storage $ = _storage();
        Position storage s = $.sPos[wallet];
        Position storage u = $.uPos[wallet];
        total = s.accrued + _pending($, s, SHARE_UNIT, KIND_SHARES) + u.accrued + _pending($, u, USDFR_UNIT, KIND_USDFR);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            Position storage cp = $.cPos[wallet][c];
            total += cp.accrued + _pending($, cp, USDFR_UNIT, KIND_CURATOR);
        }
    }

    /// @notice Point subtotals by source (dashboard split).
    function pointsBreakdown(address wallet)
        external
        view
        returns (uint256 fromShares, uint256 fromUSDfr, uint256 fromCurator)
    {
        PointsStorage storage $ = _storage();
        Position storage s = $.sPos[wallet];
        Position storage u = $.uPos[wallet];
        fromShares = s.accrued + _pending($, s, SHARE_UNIT, KIND_SHARES);
        fromUSDfr = u.accrued + _pending($, u, USDFR_UNIT, KIND_USDFR);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            Position storage cp = $.cPos[wallet][c];
            fromCurator += cp.accrued + _pending($, cp, USDFR_UNIT, KIND_CURATOR);
        }
    }

    function trackedBalances(address wallet) external view returns (uint256 shares, uint256 usdfr) {
        PointsStorage storage $ = _storage();
        return ($.sPos[wallet].balance, $.uPos[wallet].balance);
    }

    function curatorTracked(address wallet, uint256 classId) external view returns (uint256) {
        return _storage().cPos[wallet][classId].balance;
    }

    function totals() external view returns (uint256 shares, uint256 usdfr, uint256 curator) {
        PointsStorage storage $ = _storage();
        return ($.totalTrackedShares, $.totalTrackedUsdfr, $.totalTrackedCurator);
    }

    function ratePerUnitDay() external view returns (uint256) {
        return _current().ratePerUnitDay;
    }

    function usdfrMultiplierBps() external view returns (uint32) {
        return _current().usdfrMultBps;
    }

    function curatorMultiplierBps() external view returns (uint32) {
        return _current().curatorMultBps;
    }

    function rateEpochCount() external view returns (uint256) {
        return _storage().rateEpochs.length;
    }

    function curatorModule() external view returns (address) {
        return _storage().curatorModule;
    }

    /// @notice Number of loss events recorded for `classId` (the class's loss-epoch count).
    /// @param classId The collateral class.
    /// @return The length of the class's append-only loss log.
    function curatorLossEpochCount(uint256 classId) external view returns (uint256) {
        return _storage().curatorLossTimes[classId].length;
    }

    /// @notice The instant of loss `lossEpoch` in `classId` (reverts if out of range).
    /// @param classId The collateral class.
    /// @param lossEpoch Zero-based index into the class's loss log.
    /// @return The block timestamp at which that loss was recorded.
    function curatorLossAt(uint256 classId, uint256 lossEpoch) external view returns (uint64) {
        return _storage().curatorLossTimes[classId][lossEpoch];
    }

    /// @notice The last recorded loss instant for `classId` (0 if none) — observability only.
    /// @param classId The collateral class.
    /// @return The timestamp of the most recent loss.
    function lastCuratorLossAt(uint256 classId) external view returns (uint64) {
        return _storage().lastCuratorLossAt[classId];
    }

    /// @notice Whether `wallet`'s first-loss position in `classId` is frozen by an
    ///         un-reconciled loss, and the instant its accrual is pinned at.
    /// @param wallet The curator.
    /// @param classId The collateral class.
    /// @return frozen True while the position has not been reconciled through every class loss.
    ///         A wallet that has never held first-loss in the class is never reported frozen,
    ///         however many losses the class has taken — it has nothing stale to freeze.
    /// @return frozenAt The accrual ceiling (the first un-reconciled loss instant); 0 if not frozen.
    function curatorFreezeStatus(address wallet, uint256 classId)
        external
        view
        returns (bool frozen, uint64 frozenAt)
    {
        PointsStorage storage $ = _storage();
        Position storage p = $.cPos[wallet][classId];
        if (!_isRealCuratorPosition(p)) return (false, 0);
        uint256 seen = p.seenLossEpoch;
        uint64[] storage times = $.curatorLossTimes[classId];
        if (seen >= times.length) return (false, 0);
        return (true, times[seen]);
    }

    /// @notice Points earned by `wallet`'s first-loss position in ONE class (accrued + pending).
    ///         Zero while the position is frozen beyond the loss instant.
    /// @param wallet The curator.
    /// @param classId The collateral class.
    /// @return The class's contribution to the wallet's curator points.
    function curatorPointsInClass(address wallet, uint256 classId) external view returns (uint256) {
        PointsStorage storage $ = _storage();
        Position storage p = $.cPos[wallet][classId];
        return p.accrued + _pending($, p, USDFR_UNIT, KIND_CURATOR);
    }

    /// @notice The class's dilution state: the loss round and the cumulative survival factor
    ///         (WAD) applied to cached curator balances within that round.
    /// @param classId The collateral class.
    /// @return lossRound Bumped on a pool wipe or on a loss recorded without a usable ratio.
    /// @return survivalWad Cumulative surviving fraction of the round, WAD-scaled.
    function curatorDilutionState(uint256 classId) external view returns (uint64 lossRound, uint256 survivalWad) {
        PointsStorage storage $ = _storage();
        return ($.curatorLossRound[classId], _survival($.curatorSurvivalWad[classId]));
    }

    // ── internals ──────────────────────────────────────────────────────────

    function _excluded(PointsStorage storage $, address wallet) private view returns (bool) {
        return $.compliance.isProtocolExempt(wallet);
    }

    function _multForKind(RateEpoch storage e, uint8 kind) private view returns (uint256) {
        if (kind == KIND_USDFR) return e.usdfrMultBps;
        if (kind == KIND_CURATOR) return e.curatorMultBps;
        return BPS; // shares: 1×
    }

    function _current() private view returns (RateEpoch storage) {
        RateEpoch[] storage epochs = _storage().rateEpochs;
        return epochs[epochs.length - 1];
    }

    function _appendEpoch(uint256 rate, uint32 usdfrMult, uint32 curatorMult) private {
        PointsStorage storage $ = _storage();
        $.rateEpochs.push(
            RateEpoch({
                start: uint64(block.timestamp),
                usdfrMultBps: usdfrMult,
                curatorMultBps: curatorMult,
                ratePerUnitDay: rate
            })
        );
        emit RateEpochAppended($.rateEpochs.length - 1, rate, usdfrMult, curatorMult);
    }

    function _track(PointsStorage storage $, Position storage p, uint256 amount, uint256 unit, uint8 kind, address w)
        private
    {
        _accrue($, p, unit, kind, w);
        uint256 bal = p.balance;
        uint64 nowTs = uint64(block.timestamp);
        if (bal == 0) {
            p.maturityStart = nowTs;
        } else {
            p.maturityStart = uint64((bal * p.maturityStart + amount * nowTs) / (bal + amount));
        }
        p.balance = bal + amount;
    }

    function _untrack(PointsStorage storage $, Position storage p, uint256 amount, uint256 unit, uint8 kind, address w)
        private
        returns (uint256 dec)
    {
        _accrue($, p, unit, kind, w);
        uint256 bal = p.balance;
        dec = amount < bal ? amount : bal; // clamp so a re-hooked module can't underflow
        p.balance = bal - dec;
    }

    /// @dev Sets a position's balance to `target`, updating the matching total (P-02/P-04).
    ///      `totalKind` selects which total to adjust: 0 shares, 1 usdfr, 2 curator.
    function _reconcile(
        PointsStorage storage $,
        Position storage p,
        uint256 target,
        uint256 unit,
        uint8 kind,
        address w,
        uint8 totalKind
    ) private {
        uint256 bal = p.balance;
        if (target == bal) {
            _accrue($, p, unit, kind, w); // still checkpoint (locks the current epoch)
            return;
        }
        if (target > bal) {
            _track($, p, target - bal, unit, kind, w);
            if (totalKind == 0) $.totalTrackedShares += target - bal;
            else if (totalKind == 1) $.totalTrackedUsdfr += target - bal;
            else $.totalTrackedCurator += target - bal;
        } else {
            uint256 dec = _untrack($, p, bal - target, unit, kind, w);
            if (totalKind == 0) $.totalTrackedShares -= dec;
            else if (totalKind == 1) $.totalTrackedUsdfr -= dec;
            else $.totalTrackedCurator -= dec;
        }
    }

    function _accrue(PointsStorage storage $, Position storage p, uint256 unit, uint8 kind, address w) private {
        uint256 pending = _pending($, p, unit, kind);
        // The checkpoint always advances, INCLUDING for a frozen curator position. The freeze is
        // enforced entirely by the state predicate in `_accrualUpper` (`seenLossEpoch <` the
        // class loss count), which does not compare against `lastAccrual` — so advancing here
        // cannot lift it, while pinning `lastEpochIdx` at the loss (as an earlier revision of
        // this fix did) would have made `_pending` an unbounded rate-epoch traversal for every
        // frozen position, on every read AND on `reconcile` — the escape hatch itself.
        p.lastAccrual = uint64(block.timestamp);
        p.lastEpochIdx = uint32($.rateEpochs.length - 1);
        if (pending != 0) {
            p.accrued += pending;
            emit PointsAccrued(w, kind, pending);
        }
    }

    /// @dev Accrual integrated over the rate epochs since the position's last checkpoint —
    ///      each epoch contributes `B × (F(b−S) − F(a−S)) × rate_epoch / (1 day × unit)`,
    ///      so a rate change never reprices already-elapsed time (P-03). The epoch loop is
    ///      bounded by the number of (governance-rare, timelocked) rate changes since the
    ///      last checkpoint; a wallet's own transfers checkpoint it continuously.
    function _pending(PointsStorage storage $, Position storage p, uint256 unit, uint8 kind)
        private
        view
        returns (uint256 total)
    {
        if (p.balance == 0 || p.lastAccrual == 0 || block.timestamp <= p.lastAccrual) return 0;
        // AUDIT FIX: a curator position stops accruing at a class loss until reconciled (its
        // cached balance is stale-high after `absorbLoss`, which fires no per-curator hook).
        uint256 upper = _accrualUpper($, p);
        RateEpoch[] storage epochs = $.rateEpochs;
        for (uint256 i = p.lastEpochIdx; i < epochs.length; ++i) {
            uint256 a = epochs[i].start > p.lastAccrual ? epochs[i].start : p.lastAccrual;
            uint256 b = (i + 1 < epochs.length) ? epochs[i + 1].start : upper;
            if (b > upper) b = upper;
            if (b > a) total += _epochPoints(p.balance, p.maturityStart, a, b, unit, epochs[i], kind);
        }
    }

    /// @dev The upper time bound for accrual: now, unless the position is a curator position
    ///      frozen by an un-reconciled class loss, in which case it is the instant of the FIRST
    ///      loss the position has not been reconciled through (H-03). Anchoring on the first
    ///      unseen loss — not on a single overwritable "latest loss" timestamp — is what stops
    ///      a later same-class loss from re-opening an earlier freeze window.
    function _accrualUpper(PointsStorage storage $, Position storage p) private view returns (uint256 upper) {
        upper = block.timestamp;
        uint32 cid = p.classId;
        if (cid == 0) return upper;
        uint64[] storage times = $.curatorLossTimes[cid];
        uint256 seen = p.seenLossEpoch;
        if (seen >= times.length) return upper; // reconciled through every recorded loss
        uint64 frozenAt = times[seen];
        if (frozenAt < upper) upper = frozenAt;
    }

    /// @dev Appends a loss epoch for `classId` and folds its dilution ratio into the class's
    ///      cumulative survival factor. `before == 0 || after == 0 || after > before` means the
    ///      ratio is unusable (a wipe, or a legacy/migrated loss that carried no ratio): the
    ///      loss ROUND is bumped instead, which distrusts every cached balance in the class.
    function _recordCuratorLoss(PointsStorage storage $, uint256 classId, uint256 balBefore, uint256 balAfter)
        private
    {
        uint64 at = uint64(block.timestamp);
        $.lastCuratorLossAt[classId] = at; // legacy field, retained for observability + migration
        uint64[] storage times = $.curatorLossTimes[classId];
        times.push(at);
        if (balBefore == 0 || balAfter == 0 || balAfter > balBefore) {
            $.curatorLossRound[classId] += 1;
            $.curatorSurvivalWad[classId] = WAD;
        } else {
            uint256 next = _survival($.curatorSurvivalWad[classId]) * balAfter / balBefore;
            if (next == 0) {
                // Precision exhausted by successive dilutions: distrust rather than under-state.
                $.curatorLossRound[classId] += 1;
                $.curatorSurvivalWad[classId] = WAD;
            } else {
                $.curatorSurvivalWad[classId] = next;
            }
        }
        emit CuratorLossRecorded(classId, times.length - 1, at, balBefore, balAfter);
    }

    /// @dev 0 encodes "unset" for both the class factor and a position's snapshot of it, so a
    ///      never-written slot (including on an upgraded proxy) reads as "no dilution".
    function _survival(uint256 v) private pure returns (uint256) {
        return v == 0 ? WAD : v;
    }

    /// @dev A position that has never held first-loss in the class (no balance, no accrual, no
    ///      maturity anchor). Such a position is never "frozen": there is nothing stale in it,
    ///      and thawing it would write storage and emit events for every wallet reconciled.
    function _isRealCuratorPosition(Position storage p) private view returns (bool) {
        return p.balance != 0 || p.accrued != 0 || p.maturityStart != 0;
    }

    /// @dev Writes `p`'s cached first-loss balance down by every class loss it has not yet
    ///      absorbed (H-03, BALANCE/MATURITY axis). `absorbLoss` dilutes every curator in the
    ///      class EXACTLY pro-rata, so the ratio is enough — no per-curator hook is needed.
    ///      Accrual up to the freeze ceiling is credited at the pre-loss balance FIRST, then the
    ///      balance drops; `maturityStart` is untouched, which is correct — the SURVIVING
    ///      capital has genuinely been posted since then, and any later top-up is blended
    ///      against it by `_track`. Monotone: the balance can only move down here.
    function _applyCuratorDilution(PointsStorage storage $, Position storage p, uint256 classId, address wallet)
        private
    {
        uint64 round = $.curatorLossRound[classId];
        uint256 cur = _survival($.curatorSurvivalWad[classId]);
        uint256 seen = _survival(p.seenSurvivalWad);
        if (p.seenLossRound == round && seen == cur) return; // nothing new to absorb
        uint256 bal = p.balance;
        if (bal != 0) {
            _accrue($, p, USDFR_UNIT, KIND_CURATOR, wallet);
            // A round change means a wipe or an unusable ratio: nothing cached is trustworthy.
            uint256 newBal = p.seenLossRound != round ? 0 : bal * cur / seen;
            if (newBal > bal) newBal = bal; // defensive: the factor never grows within a round
            if (newBal != bal) {
                p.balance = newBal;
                $.totalTrackedCurator -= bal - newBal;
                emit CuratorBalanceDiluted(wallet, classId, bal, newBal);
            }
        }
        p.seenLossRound = round;
        p.seenSurvivalWad = cur;
    }

    /// @dev Marks `p` reconciled through every recorded loss of `classId`, emitting the thaw.
    ///      Returns true when the watermark actually moved (i.e. the position WAS frozen).
    function _syncLossWatermark(PointsStorage storage $, Position storage p, uint256 classId, address wallet)
        private
        returns (bool)
    {
        uint256 count = $.curatorLossTimes[classId].length;
        if (p.seenLossEpoch >= count) return false; // not frozen — nothing to clear
        p.seenLossEpoch = uint64(count);
        emit CuratorPositionThawed(wallet, classId, uint64(count));
        return true;
    }

    /// @dev Clears a curator position's freeze from `reconcile()`, i.e. only after the balance
    ///      has been snapped to the live `postedOf`. Positions that never held first-loss in the
    ///      class are skipped, so reconciling an arbitrary wallet writes nothing and emits
    ///      nothing for the classes it never participated in.
    function _thawCurator(PointsStorage storage $, Position storage p, uint256 classId, address wallet) private {
        if (!_isRealCuratorPosition(p)) return;
        if (!_syncLossWatermark($, p, classId, wallet)) return;
        p.lastAccrual = uint64(block.timestamp);
        p.lastEpochIdx = uint32($.rateEpochs.length - 1);
    }

    /// @dev One rate epoch's contribution — in its own frame to keep `_pending` off the
    ///      stack-too-deep cliff without via-ir.
    function _epochPoints(
        uint256 bal,
        uint256 start,
        uint256 a,
        uint256 b,
        uint256 unit,
        RateEpoch storage e,
        uint8 kind
    ) private view returns (uint256) {
        uint256 dF = _rampIntegral(b >= start ? b - start : 0) - _rampIntegral(a >= start ? a - start : 0);
        uint256 rate = e.ratePerUnitDay * _multForKind(e, kind) / BPS;
        return bal * dF / WAD * rate / (1 days * unit);
    }

    /// @dev F(x) = ∫₀ˣ m(τ)dτ, m(τ) = 1 + min(τ, RAMP)/RAMP, WAD-scaled.
    function _rampIntegral(uint256 x) internal pure returns (uint256) {
        if (x <= MATURITY_RAMP) {
            return x * WAD + (x * x * WAD) / (2 * MATURITY_RAMP);
        }
        return (3 * MATURITY_RAMP * WAD) / 2 + 2 * (x - MATURITY_RAMP) * WAD;
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (PointsStorage storage $) {
        assembly {
            $.slot := POINTS_STORAGE_LOCATION
        }
    }
}
