// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IImpairmentSource} from "./interfaces/IImpairmentSource.sol";
import {IPointsModule} from "./interfaces/IPointsModule.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {PointsHookGas} from "./libraries/PointsHookGas.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title sUSDfr — the yield-bearing vault (ADR-0005)
/// @notice ERC-4626 vault over USDfr. `totalAssets()` is the vault's realized USDfr
///         balance (physical holdings less any optional unvested stream): yield arrives as USDfr minted into the vault against attested
///         receipts (WaterfallEngine, Phase E), and value leaves only via the loss
///         cascade's final layer (controller burn on the vault balance) or queue-served
///         redemptions. The fee-net exchange-rate views rise with yield, fall with an
///         explicit loss, and deterministically simulate management/performance shares
///         already due; crystallization is evented and cannot impose the dilution twice
///         (CLAUDE.md §1.3).
///         Realized yield is recognized immediately at launch. ADR-0023 retains an optional
///         governance-set linear vesting schedule as a market-smoothing control; Pendle does
///         not require streaming. When enabled, vesting only ever DELAYS a rise. Changing a
///         live non-zero schedule is continuity-preserving, while setting it to zero releases
///         the remaining realized yield and steps the rate UP — never down.
///
///         ASYMMETRIC EXIT PRICING (ADR-0022 Option Y): entry prices include USDfr already
///         held in an optional unvested-yield stream, so a new entrant cannot buy value earned
///         by incumbents merely because recognition was deferred. Position views remain at
///         realized NAV. Exit prices at `redemptionTotalAssets()` = realized assets LESS the
///         declared-but-unrealized senior impairment. So a senior cannot exit at pre-loss NAV
///         in the `declareDefault` → `realizeLoss` window; the impairment is borne by the
///         leaver rather than dumped on the stayers. Redemption NAV <= deposit NAV, always.
///         Deposits are deliberately NOT priced optimistically (ADR-0022 rejects that half).
///
///         Exits are epoch-queued (ADR-0010): `withdraw`/`redeem` are callable only by
///         the RedemptionQueue module. Deposit is KYC-gated on the receiver (ADR-0011).
///         Yield is VARIABLE — the book's actual performance; no fixed rate exists
///         anywhere in this contract (ADR-0002). Securities characterization of this
///         instrument is a matter for counsel (brief Part 0.5).
contract SUSDfr is
    Initializable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IsUSDfr
{
    /// @custom:storage-location erc7201:forestroad.storage.SUSDfr
    /// @dev Fields are append-only for upgrade safety.
    struct SUSDfrStorage {
        IComplianceRegistry compliance;
        address redemptionQueue;
        IPointsModule pointsModule; // optional participation-points hook (ADR-0016)
        // ── append-only (upgrade safety) ──────────────────────────────────
        IImpairmentSource impairmentSource; // ADR-0022 Option Y (optional; zero = realized NAV)
        // ADR-0023 senior-yield vesting. `vestingAmount` is the size of the CURRENT stream
        // and `lastYieldAt` when it started; together they linearly release realized yield
        // into `totalAssets()` over `yieldVestingPeriod`.
        uint256 vestingAmount;
        uint64 lastYieldAt;
        uint64 yieldVestingPeriod;
        // ── append-only: protocol-level fee accounting (ADR-0031) ─────────
        // Packed into one slot: 160 + 16 + 64 + 8 + 8 = 256 bits.
        address feeRecipient;
        uint16 managementFeeBps;
        uint64 lastFeeAccrual;
        bool feeAccrualInProgress;
        bool shareUpdateInProgress;
        // Conservative marked-NAV assets per one whole sUSDfr token, post fee.
        uint256 highWaterMark;
        // Appended after the HWM so deployed namespaced layouts remain append-only.
        uint16 performanceFeeBps;
        // ── append-only: cross-module fee-accounting operation lock ──────
        // A trusted module brackets either a junior-capacity write or the
        // WaterfallEngine's mintYield -> notifyYield sequence. The persistent lock
        // blocks permissionless checkpoints throughout the external-call window.
        address feeOperationCaller;
        uint8 feeOperationKind;
        // Legacy round-1 snapshot fields remain append-only but are deliberately unused:
        // free-running NAV deltas are not capital-flow evidence (ADR-0031 round 2).
        uint256 feeOperationMarkedAssets;
        uint256 feeOperationHurdleAssets;
        uint256 feeOperationSupply;
        // M-3: absolute deadline for the active stream. Governance may shorten it but no
        // sequence of non-zero period changes or yield notifications may move it later.
        uint64 vestingEndsAt;
    }

    struct FeeCalculation {
        uint256 elapsed;
        uint256 managementAssets;
        uint256 managementShares;
        uint256 profitAssets;
        uint256 performanceAssets;
        uint256 performanceShares;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.SUSDfr")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SUSDFR_STORAGE_LOCATION =
        0x916ccd28d6453e4642f179fb55de273623b632994ad01fe3a90e7b8b8a7e8900;
    // Recovery uses a fixed probe budget so governance cannot make a healthy source appear
    // unreadable merely by submitting the transaction with too little gas. The separate
    // reserve guarantees enough gas remains to clear storage, ratchet the HWM, and emit.
    uint256 private constant IMPAIRMENT_SOURCE_PROBE_GAS = 200_000;
    uint256 private constant IMPAIRMENT_SOURCE_RECOVERY_GAS_RESERVE = 150_000;
    uint8 private constant FEE_OPERATION_NONE = 0;
    uint8 private constant FEE_OPERATION_MARKED_NAV = 1;
    uint8 private constant FEE_OPERATION_YIELD = 2;

    /// @notice A constructor or initializer argument that must be non-zero was zero.
    error SUSDfr_ZeroAddress();
    /// @notice The proposed points module has no code. Rejected for the same reason
    ///         `USDfr.setPointsModule` rejects it (C4-USDFR-01): `onSharesTransfer`
    ///         returns no data, so solc emits an `extcodesize` guard that reverts
    ///         OUTSIDE the fail-open `try` in `_update` — bricking every share
    ///         transfer, deposit and redeem in one governance transaction.
    /// @param module The codeless address that was refused.
    error SUSDfr_PointsModuleNotAContract(address module);
    /// @notice The requested vesting window exceeds `Config.MAX_YIELD_VESTING_PERIOD`.
    error SUSDfr_VestingPeriodTooLong(uint64 period);
    /// @notice Entry is closed because share pricing is DEGENERATE: shares are outstanding while
    ///         the deposit base (`totalAssets()`) has either collapsed to zero OR is dwarfed by the
    ///         stranded, realized-but-unvested yield stream the vault physically holds. In both
    ///         cases a deposit would mint shares against a base that is about to grow under the
    ///         entrant's feet, letting them skim value from incumbents. This is a STRANDED-STREAM
    ///         guard, not a zero-point one (audit H-3 residual) — it fires across the whole
    ///         profitable band, not only at the exact `totalAssets() == 0` point. See
    ///         `_isDegenerate()`.
    /// @param shares The outstanding share supply.
    /// @param assets The collapsed deposit base (`totalAssets()`) those shares are priced against.
    error SUSDfr_DegenerateSharePrice(uint256 shares, uint256 assets);

    /// @notice Emitted when the points module is set or cleared.
    event PointsModuleUpdated(address indexed module);

    /// @notice Emitted when the conservative-redemption-NAV impairment source is set or cleared.
    /// @param source The impairment source, or zero when exits price at the realized NAV.
    event ImpairmentSourceUpdated(address indexed source);

    /// @notice Emitted when realized yield begins vesting into the exchange rate (ADR-0023),
    ///         and when `setYieldVestingPeriod` crystallizes and re-bases the live stream.
    /// @param added The newly delivered yield; zero on a `setYieldVestingPeriod` re-base.
    /// @param streamTotal `added` plus any unvested remainder rolled over from the prior stream.
    /// @param period The vesting window applied to this stream, in seconds.
    event YieldStreamStarted(uint256 added, uint256 streamTotal, uint64 period);

    /// @notice Absolute terminal timestamp for the active stream (zero when no stream exists).
    event YieldStreamDeadlineSet(uint64 endsAt);

    /// @notice Emitted when an oversized realized-yield delivery is credited immediately
    ///         because withholding the whole amount would close healthy vault entry.
    /// @param amount The already-delivered USDfr recognized in NAV immediately.
    event YieldInstantlyRecognized(uint256 amount);

    /// @notice Emitted when governance changes the yield vesting window (ADR-0023).
    /// @param period The new window in seconds; zero credits yield instantly.
    event YieldVestingPeriodSet(uint64 period);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param usdfr Underlying asset (USDfr).
    /// @param compliance KYC registry gating vault entry.
    /// @param feeRecipient_ Recipient of protocol management/performance fee shares.
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address usdfr,
        address compliance,
        address feeRecipient_
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr == address(0)
                || compliance == address(0) || feeRecipient_ == address(0)
        ) revert SUSDfr_ZeroAddress();
        __ERC20_init(Config.SUSDFR_NAME, Config.SUSDFR_SYMBOL);
        __ERC4626_init(IERC20(usdfr));
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        SUSDfrStorage storage $ = _storage();
        $.compliance = IComplianceRegistry(compliance);
        if (!$.compliance.isProtocolExempt(feeRecipient_)) {
            revert SUSDfr_FeeRecipientNotExempt(feeRecipient_);
        }
        $.feeRecipient = feeRecipient_;
        $.performanceFeeBps = Config.DEFAULT_PERFORMANCE_FEE_BPS;
        $.managementFeeBps = Config.DEFAULT_MANAGEMENT_FEE_BPS;
        $.lastFeeAccrual = uint64(block.timestamp);
        // ADR-0023: launch uses instant recognition. Governance may prospectively enable
        // optional smoothing without changing the storage or integration surface.
        $.yieldVestingPeriod = Config.DEFAULT_YIELD_VESTING_PERIOD;
        // With zero supply and assets, OZ's virtual shares/assets establish the canonical
        // 1 USDfr initial marked-NAV rate. The first real deposit is therefore not "profit".
        $.highWaterMark = _feeExchangeRate(Math.Rounding.Ceil);
        emit YieldVestingPeriodSet(Config.DEFAULT_YIELD_VESTING_PERIOD);
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @notice Realized senior yield not yet released into the exchange rate (ADR-0023).
    /// @dev Decays linearly from `vestingAmount` to zero by the stream's fixed deadline. A zero
    ///      period disables vesting entirely (instant credit), which is the pre-ADR-0023
    ///      behaviour and the governance escape hatch.
    /// @return The USDfr sitting in the vault that has not yet vested.
    function unvestedYield() public view returns (uint256) {
        SUSDfrStorage storage $ = _storage();
        uint256 amount = $.vestingAmount;
        if ($.yieldVestingPeriod == 0 || amount == 0) return 0;
        uint256 end = _vestingEnd($);
        uint256 start = $.lastYieldAt;
        if (block.timestamp >= end || end <= start) return 0;
        uint256 period = end - start;
        uint256 remaining = end - block.timestamp;
        // rounds DOWN, so vesting errs slightly FAST — never withholds more than it should
        return Math.mulDiv(amount, remaining, period, Math.Rounding.Floor);
    }

    /// @notice Vault assets backing the share price: USDfr held, LESS yield still vesting.
    /// @dev ADR-0023. Yield arrives as a lump (`WaterfallEngine` mints it in against an
    ///      attested receipt) and is then released linearly, so the exchange rate climbs
    ///      smoothly instead of stepping. This is a TIMING change on ALREADY-REALIZED yield
    ///      only — nothing expected or forward-looking is ever credited, so ADR-0002
    ///      variable-yield pass-through is untouched (contrast the optimistic-deposit NAV
    ///      that ADR-0022 explicitly rejected).
    ///
    ///      `balance >= unvestedYield()` is maintained inductively by every writer, so the
    ///      subtraction does not underflow in practice: `notifyYield` only ever adds yield
    ///      already delivered into the balance; `setYieldVestingPeriod` crystallizes the
    ///      pending remainder before re-pricing, so it cannot raise `unvestedYield()`
    ///      (audit H-3 — before that fix the bound below did NOT survive a later period
    ///      increase, and this clamp was reachable); exits are priced at or below
    ///      `totalAssets()`; and `DefaultManager.realizeLoss` bounds the layer-3 senior burn
    ///      by this VESTED figure, the only path that burns vault USDfr. The clamp is
    ///      defence-in-depth against a FUTURE caller that burns without that bound —
    ///      reverting here would brick every redemption, which is strictly worse than
    ///      reporting zero. `test_lossCannotBurnIntoTheUnvestedStream` and
    ///      `testFuzz_balanceAlwaysCoversTheUnvestedStream` pin the bound.
    ///
    ///      DO NOT READ THE CLAMP'S UNREACHABILITY AS A SAFETY GUARANTEE (audit H-3
    ///      remediation; the earlier revision of this comment did, and was wrong). `balance >=
    ///      unvested` is true and is NOT sufficient: this function returns 0 whenever `held ==
    ///      unvested`, i.e. at EQUALITY, not only below it — and equality is reachable through
    ///      an entirely in-bounds `DefaultManager.realizeLoss(id, totalAssets())`, which burns
    ///      the vested layer to exactly nothing and leaves the unvested stream standing. A
    ///      zero-asset vault with shares outstanding is the first-depositor/inflation hazard — as
    ///      is ANY state where the stranded unvested stream still dwarfs the deposit base (the zero
    ///      point is merely its limit): one block after a maximal write-down the base is a sliver
    ///      but the stream is intact, and a depositor still skims it. What actually closes both is
    ///      the `_isDegenerate()` entry guard on `deposit`/`mint`, keyed on
    ///      `unvestedYield()` vs `totalAssets()`, not the bound;
    ///      `test_maximalLossWipesTheVaultAndClosesEntry` pins the zero point and
    ///      `test_strandedStreamBandClosesEntry_*` pin the continuous band.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        uint256 unvested = unvestedYield();
        return held > unvested ? held - unvested : 0;
    }

    /// @notice The current yield vesting window, in seconds (zero = instant credit).
    function yieldVestingPeriod() external view returns (uint64) {
        return _storage().yieldVestingPeriod;
    }

    /// @notice The size of the stream currently vesting, and when it started.
    /// @return amount The full size of the active stream.
    /// @return startedAt The timestamp the active stream began vesting from.
    function vestingSchedule() external view returns (uint256 amount, uint64 startedAt) {
        SUSDfrStorage storage $ = _storage();
        return ($.vestingAmount, $.lastYieldAt);
    }

    /// @notice The immutable-or-shortening deadline of the current stream.
    function vestingDeadline() external view returns (uint64) {
        SUSDfrStorage storage $ = _storage();
        return $.vestingAmount == 0 ? 0 : _vestingEnd($);
    }

    /// @inheritdoc IsUSDfr
    /// @dev Assets (18-dec USDfr) per ONE WHOLE sUSDfr share token (10**decimals()
    ///      share units, accounting for the virtual-share decimals offset).
    function currentExchangeRate() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /// @inheritdoc IsUSDfr
    function feeExchangeRate() public view returns (uint256) {
        return _feeExchangeRate();
    }

    /// @inheritdoc IsUSDfr
    function performanceFeeBps() external view returns (uint16) {
        return _storage().performanceFeeBps;
    }

    /// @inheritdoc IsUSDfr
    function maxPerformanceFeeBps() external pure returns (uint16) {
        return Config.MAX_PERFORMANCE_FEE_BPS;
    }

    /// @inheritdoc IsUSDfr
    function managementFeeBps() external view returns (uint16) {
        return _storage().managementFeeBps;
    }

    /// @inheritdoc IsUSDfr
    function maxManagementFeeBps() external pure returns (uint16) {
        return Config.MAX_MANAGEMENT_FEE_BPS;
    }

    /// @inheritdoc IsUSDfr
    function managementFeeYear() external pure returns (uint64) {
        return Config.MANAGEMENT_FEE_YEAR;
    }

    /// @inheritdoc IsUSDfr
    function highWaterMark() external view returns (uint256) {
        return _storage().highWaterMark;
    }

    /// @inheritdoc IsUSDfr
    function feeRecipient() external view returns (address) {
        return _storage().feeRecipient;
    }

    /// @inheritdoc IsUSDfr
    function lastFeeAccrual() external view returns (uint64) {
        return _storage().lastFeeAccrual;
    }

    /// @inheritdoc IsUSDfr
    function accrueFees()
        external
        feeCheckpointEntry
        nonReentrant
        returns (uint256 managementShares, uint256 performanceShares)
    {
        return _accrueFees();
    }

    /// @inheritdoc IsUSDfr
    function prepareRedemptionPricing(uint256 maxAssets) external nonReentrant returns (uint256 instantlyRecognized) {
        SUSDfrStorage storage $ = _storage();
        if (msg.sender != $.redemptionQueue) revert SUSDfr_QueueOnly();

        // G4/M-2: recognize once against the settlement-wide remaining outflow ceiling, not
        // against the caller-selected request count. For an unchanged stream, H - B remains
        // constant as each chunk pays A and reduces both held assets and remaining budget by A,
        // so later chunks cannot manufacture another NAV step.
        instantlyRecognized = _capStreamToBase(maxAssets);
        // Checkpoint AFTER recognition so selection and execution observe the same fee-adjusted
        // supply. The recognized gain is not ratcheted into the HWM and therefore cannot escape
        // its configured performance fee.
        _accrueFees();
        uint256 held = IERC20(asset()).balanceOf(address(this));
        uint256 projectedHeld = maxAssets < held ? held - maxAssets : 0;
        emit RedemptionPricingPrepared(maxAssets, projectedHeld, instantlyRecognized);
    }

    /// @inheritdoc IsUSDfr
    function beginFeeNeutralMarkedNavChange()
        external
        onlyRole(Roles.FEE_ACCOUNTING_ROLE)
        feeCheckpointEntry
        nonReentrant
    {
        _accrueFees();
        SUSDfrStorage storage $ = _storage();
        uint256 supply = totalSupply();
        $.feeOperationCaller = msg.sender;
        $.feeOperationKind = FEE_OPERATION_MARKED_NAV;
        $.feeOperationSupply = supply;
        emit FeeNeutralMarkedNavChangeStarted(msg.sender, supply);
    }

    /// @inheritdoc IsUSDfr
    function endFeeNeutralMarkedNavChange() external onlyRole(Roles.FEE_ACCOUNTING_ROLE) nonReentrant {
        SUSDfrStorage storage $ = _storage();
        _requireFeeOperation($, FEE_OPERATION_MARKED_NAV);
        uint256 supply = totalSupply();
        if (supply != $.feeOperationSupply) {
            revert SUSDfr_FeeOperationSupplyChanged($.feeOperationSupply, supply);
        }

        _clearFeeOperation($);
        emit FeeNeutralMarkedNavChangeCompleted(msg.sender, supply);
    }

    /// @inheritdoc IsUSDfr
    function beginYieldNotification() external onlyRole(Roles.CREDIT_ROLE) feeCheckpointEntry nonReentrant {
        _accrueFees();
        SUSDfrStorage storage $ = _storage();
        $.feeOperationCaller = msg.sender;
        $.feeOperationKind = FEE_OPERATION_YIELD;
        emit YieldNotificationStarted(msg.sender);
    }

    /// @inheritdoc IsUSDfr
    function clearStaleFeeOperation() external onlyRole(DEFAULT_ADMIN_ROLE) {
        SUSDfrStorage storage $ = _storage();
        address caller = $.feeOperationCaller;
        uint8 kind = $.feeOperationKind;
        if (kind == FEE_OPERATION_NONE) {
            revert SUSDfr_InvalidFeeOperation(msg.sender, FEE_OPERATION_MARKED_NAV, kind);
        }
        _clearFeeOperation($);
        emit FeeOperationEmergencyCleared(caller, kind);
    }

    /// @inheritdoc IsUSDfr
    function redemptionQueue() public view returns (address) {
        return _storage().redemptionQueue;
    }

    /// @notice The asset base redemptions price against: realized assets LESS the
    ///         declared-but-unrealized senior impairment (ADR-0022 Option Y).
    /// @dev `totalAssets()`, `convertToAssets`, `convertToShares`, and
    ///      `currentExchangeRate()` remain REALIZED-NAV views. `previewDeposit` and
    ///      `previewMint` are intentionally more conservative: they also include USDfr already
    ///      held in the unvested stream, which is realised cash earned by incumbents rather than
    ///      a forward mark. This closes the stream-entry transfer without adopting the rejected
    ///      optimistic-deposit treatment of unrealised credit.
    ///      - `currentExchangeRate()` is the §1.3 monotonicity subject and must keep tracking
    ///        realized value, so a *declared* default does not read as a silent rate fall.
    ///      Because the impairment is subtracted, `redemptionTotalAssets() <= totalAssets()`
    ///      always, hence redemption NAV <= deposit NAV always — the invariant ADR-0022 §Y.2 owes.
    ///      Clamped at zero: an impairment exceeding the vault balance marks the senior layer
    ///      fully impaired rather than underflowing.
    /// @return The conservative asset base, in USDfr.
    function redemptionTotalAssets() public view returns (uint256) {
        uint256 assets = totalAssets();
        IImpairmentSource source = _storage().impairmentSource;
        if (address(source) == address(0)) return assets;
        // NOT try/catch: a failure to read impairment must fail LOUDLY (CLAUDE.md prime
        // directive 4). Swallowing it would silently restore the optimistic exit price — which
        // is precisely the loss-dodge ADR-0022 exists to close. Governance can clear the wiring
        // if the source ever misbehaves; that is an explicit, evented decision, not a silent catch.
        uint256 impairment = source.pendingSeniorImpairment();
        return impairment >= assets ? 0 : assets - impairment;
    }

    /// @notice Assets returned for `shares` on exit, at the CONSERVATIVE redemption NAV.
    /// @dev Overrides the ERC-4626 default so `redeem()` — which routes through this — prices
    ///      the exit on `redemptionTotalAssets()`. Mirrors OZ `_convertToAssets(.., Floor)` with
    ///      the conservative base. Rounds DOWN, in the vault's favour.
    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return Math.mulDiv(
            shares, redemptionTotalAssets() + 1, _feeAdjustedSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor
        );
    }

    /// @notice Shares burned to withdraw `assets` on exit, at the CONSERVATIVE redemption NAV.
    /// @dev Mirrors OZ `_convertToShares(.., Ceil)` with the conservative base. Rounds UP, in
    ///      the vault's favour — an impaired exit costs MORE shares per asset, never fewer.
    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return Math.mulDiv(
            assets, _feeAdjustedSupply() + 10 ** _decimalsOffset(), redemptionTotalAssets() + 1, Math.Rounding.Ceil
        );
    }

    /// @notice Shares that `assets` buys at the conservative redemption NAV, rounded DOWN.
    /// @dev For the RedemptionQueue's settlement-budget cap. `previewWithdraw` rounds UP (correct
    ///      for "what must I burn"), which would let a budget cap overshoot by a wei; this is the
    ///      floor-rounded counterpart, so `previewRedeem(convertToSharesAtRedemption(b)) <= b`
    ///      holds by construction and the queue can never distribute above its budget (§1.3).
    /// @param assets The budget, in USDfr.
    /// @return The largest share count whose conservative redemption value does not exceed `assets`.
    function convertToSharesAtRedemption(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(
            assets, _feeAdjustedSupply() + 10 ** _decimalsOffset(), redemptionTotalAssets() + 1, Math.Rounding.Floor
        );
    }

    /// @notice Instant exit is disabled for everyone except the queue (ADR-0010); 0 while
    ///         paused (audit R5-T2: `_withdraw` is `whenNotPaused`, so advertise 0 capacity
    ///         to match, mirroring `maxDeposit`/`maxMint`).
    /// @dev Priced at the conservative redemption NAV so it stays consistent with
    ///      `previewWithdraw`; otherwise `withdraw()`'s `assets <= maxWithdraw` bound would
    ///      admit an amount the conservative price cannot actually fill.
    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        return owner == redemptionQueue() ? previewRedeem(balanceOf(owner)) : 0;
    }

    /// @notice Instant exit is disabled for everyone except the queue (ADR-0010); 0 while paused.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        return owner == redemptionQueue() ? super.maxRedeem(owner) : 0;
    }

    /// @notice ERC-4626 conformance (audit fix): advertise 0 capacity while paused, so
    ///         routers/aggregators don't build deposits that would revert in `_deposit`.
    /// @dev Also 0 in the DEGENERATE-pricing state (`_isDegenerate()`), which `deposit` rejects
    ///      outright — so the capacity view never advertises unbounded room into a vault whose
    ///      deposit base is dwarfed by a stranded yield stream (audit H-3 residual: the prior
    ///      `type(uint256).max` there was itself misleading and is closed by routing the same
    ///      predicate through here).
    function maxDeposit(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return (paused() || _isDegenerate()) ? 0 : super.maxDeposit(receiver);
    }

    /// @notice ERC-4626 conformance (audit fix): 0 mintable while paused (or degenerate).
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return (paused() || _isDegenerate()) ? 0 : super.maxMint(receiver);
    }

    /// @notice Exact-share quote for a deposit, priced on all USDfr already held by the vault.
    /// @dev C4 stream-entry remediation: `totalAssets()` deliberately excludes unvested yield,
    ///      but that cash belongs to incumbent shares. Pricing a newcomer only on realized NAV
    ///      let it acquire part of the old stream as it vested. The physical pre-deposit balance
    ///      is the conservative entry NAV and makes that transfer non-positive. Fee shares due
    ///      now are still simulated exactly as they are for every other conversion.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return Math.mulDiv(
            assets,
            _feeAdjustedSupply() + 10 ** _decimalsOffset(),
            IERC20(asset()).balanceOf(address(this)) + 1,
            Math.Rounding.Floor
        );
    }

    /// @notice Asset quote for minting shares at the same physical-balance entry NAV.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return Math.mulDiv(
            shares,
            IERC20(asset()).balanceOf(address(this)) + 1,
            _feeAdjustedSupply() + 10 ** _decimalsOffset(),
            Math.Rounding.Ceil
        );
    }

    /// @notice True when entry remains administratively closed around an abnormal collapsed-NAV
    ///         or stranded-stream state.
    /// @dev Deposit and mint pricing now include the physical unvested balance, so the historical
    ///      stream skim is closed independently of this predicate. The existing fail-closed band
    ///      remains as defence in depth and as an operational signal: normal yield delivery and
    ///      queue outflow are kept inside it by `_capStreamToBase`, while a realized loss that
    ///      strands most of a stream still requires explicit recovery rather than fresh capital
    ///      entering a distressed vault. `totalSupply() == 0` remains a valid first-deposit path.
    ///
    ///      The collapsed-rate test deliberately uses realized NAV and par, not the fee HWM. It
    ///      protects entrants when little or no physical value remains; the physical-balance quote
    ///      separately prevents a newcomer from acquiring incumbent unvested cash.
    /// @return True when `totalSupply() != 0` and either `totalAssets() == 0` or
    ///         `unvestedYield() >= Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * totalAssets()`.
    function _isDegenerate() internal view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return false; // no incumbents: first-deposit / anti-inflation-seed path
        uint256 assets = totalAssets();
        // zero base: inflation-mint point (former `_isWiped`), the limit of the band below and the
        // one case the ratio test cannot see (a wipe with no active stream leaves `0 > K * 0` false)
        if (assets == 0) return true;
        // AUDIT R15-01 (collapsed-price band). The stream band below is inert whenever
        // `yieldVestingPeriod == 0`, which is the LAUNCH policy — leaving only the point above,
        // and one wei of a permissionless USDfr transfer steps off a point. This band restores the
        // neighbourhood the guard's own rationale demands, at every vesting setting.
        //
        // The reference is PAR, not the stored high-water mark. Keying on the HWM was tried and
        // rejected: `_accrueFees`'s empty-supply branch ratchets it to `(assets + 1) * 1e18`
        // whenever any balance exists while `totalSupply() == 0`, so a pre-seed donation could
        // inflate the hurdle arbitrarily and then permanently brick entry through this band. Par
        // is derived from the token's own decimals, is scale-free, and nothing can move it.
        if (
            Math.mulDiv(10 ** decimals(), assets + 1, supply + 10 ** _decimalsOffset(), Math.Rounding.Floor)
                * Config.SUSDFR_DEGENERATE_RATE_DIVISOR < 10 ** (decimals() - _decimalsOffset())
        ) return true;
        // AUDIT R16-01 / merge P-19: retain the fail-closed equality boundary. Physical-balance
        // entry pricing independently closes the value transfer and the held/(K+1) stream cap
        // parks healthy operation a factor of K^2 away, but `>=` preserves the pinned abnormal
        // boundary and prevents a future entry-basis refactor from silently reopening it.
        return unvestedYield() >= Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * assets;
    }

    /// @notice Deposits `assets`, minting shares to `receiver` at the physical-balance entry NAV.
    /// @dev Adds the DEGENERATE-pricing guard in front of the ERC-4626 flow so the revert carries a
    ///      SPECIFIC error rather than the generic max-capacity one (`maxDeposit` reports 0 in
    ///      the same state, so without this override OZ would mask the cause). See `_isDegenerate()`.
    /// @param assets USDfr to deposit.
    /// @param receiver Recipient of the minted shares.
    /// @return The shares minted.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (_isDegenerate()) revert SUSDfr_DegenerateSharePrice(totalSupply(), totalAssets());
        // Crystallize the incumbent period before pricing a new entrant. Otherwise the
        // entrant would share old fee liabilities despite not having earned the old gain.
        _accrueFees();
        return super.deposit(assets, receiver);
    }

    /// @notice Mints exactly `shares` to `receiver`, pulling the required USDfr.
    /// @dev Same DEGENERATE-pricing guard as `deposit`; see `_isDegenerate()`.
    /// @param shares Shares to mint.
    /// @param receiver Recipient of the minted shares.
    /// @return The assets pulled.
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        if (_isDegenerate()) revert SUSDfr_DegenerateSharePrice(totalSupply(), totalAssets());
        _accrueFees();
        return super.mint(shares, receiver);
    }

    /// @notice Queue-only exact-asset exit, with fees crystallized before exit pricing.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        _accrueFees();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Queue-only exact-share exit, with fees crystallized before exit pricing.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        _accrueFees();
        return super.redeem(shares, receiver, owner);
    }

    // ── Admin ────────────────────────────────────────────────────────────

    /// @inheritdoc IsUSDfr
    /// @dev Accrues all profit under the old rate first, so the replacement rate
    ///      applies only to subsequent marked-NAV gains.
    function setPerformanceFee(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (feeBps > Config.MAX_PERFORMANCE_FEE_BPS) revert SUSDfr_PerformanceFeeTooHigh(feeBps);
        SUSDfrStorage storage $ = _storage();
        _accrueFees();
        uint16 oldFeeBps = $.performanceFeeBps;
        $.performanceFeeBps = feeBps;
        emit PerformanceFeeSet(oldFeeBps, feeBps);
    }

    /// @inheritdoc IsUSDfr
    /// @dev Accrues the old rate first, so a change can never re-price elapsed time.
    function setManagementFee(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (feeBps > Config.MAX_MANAGEMENT_FEE_BPS) revert SUSDfr_ManagementFeeTooHigh(feeBps);
        SUSDfrStorage storage $ = _storage();
        _accrueFees();
        uint16 oldFeeBps = $.managementFeeBps;
        $.managementFeeBps = feeBps;
        emit ManagementFeeSet(oldFeeBps, feeBps);
    }

    /// @inheritdoc IsUSDfr
    /// @dev Rotates before accruing, so governance can recover even if the old recipient
    ///      was accidentally made non-exempt or blocked. Governance must mark the replacement
    ///      protocol-exempt in the compliance registry before this call, preventing a
    ///      sanctions-list mistake from bricking future fee checkpoints.
    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert SUSDfr_ZeroAddress();
        SUSDfrStorage storage $ = _storage();
        if (!$.compliance.isProtocolExempt(recipient)) revert SUSDfr_FeeRecipientNotExempt(recipient);
        address oldRecipient = $.feeRecipient;
        $.feeRecipient = recipient;
        _accrueFees();
        emit VaultFeeRecipientSet(oldRecipient, recipient);
    }

    /// @notice Sets (or clears, with zero) the participation-points module. The hook
    ///         observes share balance changes; it never affects transfer validity.
    /// @dev P-48: a CODELESS module is refused, identically to `USDfr.setPointsModule`
    ///      (src/USDfr.sol:143) and for the identical reason. `onSharesTransfer` returns no
    ///      data, so solc emits an `extcodesize` guard BEFORE the call and therefore OUTSIDE
    ///      the fail-open `try` in `_update` — a codeless module makes the fail-open hook fail
    ///      CLOSED and bricks every share transfer, deposit and REDEEM (the senior exit) in a
    ///      single governance transaction. `P48_VaultCodelessPointsModule.t.sol` pins both the
    ///      guard and the bricked state it prevents.
    /// @param module The points ledger, or zero to disable the hook entirely.
    function setPointsModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module != address(0) && module.code.length == 0) revert SUSDfr_PointsModuleNotAContract(module);
        _storage().pointsModule = IPointsModule(module);
        emit PointsModuleUpdated(module);
    }

    /// @notice The participation-points module (zero = disabled).
    function pointsModule() external view returns (address) {
        return address(_storage().pointsModule);
    }

    /// @notice Wires (or clears, with zero) the conservative-redemption-NAV impairment source
    ///         — the `DefaultManager` in production (ADR-0022 Option Y).
    /// @dev An admin SETTER rather than an init arg: the DefaultManager is constructed after the
    ///      vault in both the deploy script and the fixtures. While unwired, exits price at the
    ///      realized NAV — i.e. exactly the pre-ADR-0022 behaviour — so this is fail-safe to
    ///      deploy but MUST be wired before mainnet; `Validate.s.sol` asserts it.
    /// @param source The impairment source, or zero to price exits at the realized NAV.
    function setImpairmentSource(address source) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _validateImpairmentSource(source);
        // Close the old valuation period before changing the marked-NAV source. Any upward
        // discontinuity caused by rewiring is then ratcheted fee-free below; only subsequent
        // economic performance can earn a performance fee.
        _accrueFees();
        _storage().impairmentSource = IImpairmentSource(source);
        _ratchetHighWaterMark();
        emit ImpairmentSourceUpdated(source);
    }

    /// @inheritdoc IsUSDfr
    /// @dev Recovery is deliberately narrower than `setImpairmentSource`: it can only clear
    ///      the current source, and only after a bounded static read fails, returns malformed
    ///      data, or violates the required impairment ordering. A valid source must follow the
    ///      normal checkpointed setter. A fixed probe
    ///      budget plus a required recovery reserve prevents an under-gassed transaction from
    ///      manufacturing a failed read and leaves enough gas for the write and events.
    ///      Clearing can lift marked NAV, so the HWM is ratcheted fee-free before any
    ///      later checkpoint can treat that operational recovery as investment profit.
    ///      This permanently waives any performance fee embedded in the lift; governance
    ///      must treat the call as an incident response, not a normal valuation update.
    function clearUnreadableImpairmentSource() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        SUSDfrStorage storage $ = _storage();
        address source = address($.impairmentSource);
        if (source == address(0)) revert SUSDfr_NoImpairmentSource();

        uint256 availableGas = gasleft();
        uint256 requiredGas = 2 * IMPAIRMENT_SOURCE_PROBE_GAS + IMPAIRMENT_SOURCE_RECOVERY_GAS_RESERVE;
        if (availableGas < requiredGas) {
            revert SUSDfr_InsufficientImpairmentRecoveryGas(availableGas, requiredGas);
        }

        (bool readable, bytes32 failureHash) = _probeImpairmentSource(source, IMPAIRMENT_SOURCE_PROBE_GAS);
        if (readable) revert SUSDfr_ImpairmentSourceStillReadable(source);

        $.impairmentSource = IImpairmentSource(address(0));
        _ratchetHighWaterMark();
        emit ImpairmentSourceEmergencyCleared(source, failureHash);
        emit ImpairmentSourceUpdated(address(0));
    }

    /// @notice The wired impairment source (zero = exits price at the realized NAV).
    function impairmentSource() external view returns (address) {
        return address(_storage().impairmentSource);
    }

    /// @notice Recognizes realized senior yield immediately or starts optional vesting (ADR-0023).
    /// @dev Called by the `WaterfallEngine` immediately AFTER it has delivered `amount`
    ///      USDfr into this vault via `mintYield` on the interest leg. It moves no value;
    ///      it only defers recognition.
    ///
    ///      ZERO-PERIOD LAUNCH PATH: the assets are already in the balance, so they enter NAV
    ///      immediately. After this function releases the delivery lock, WaterfallEngine
    ///      checkpoints the resulting performance fee in the same repayment transaction.
    ///
    ///      OPTIONAL-STREAM CONTINUITY: with a non-zero governance setting, `unvestedYield()`
    ///      rises by the delivered amount, so `totalAssets()` is unchanged. Any still-unvested
    ///      remainder is rolled into the new stream.
    ///
    ///      OVERSIZED-DELIVERY SAFETY (FRV-FS-03): entry pricing includes the physical unvested
    ///      balance, so it independently prevents a newcomer from acquiring incumbent yield.
    ///      With very little live stake, however, withholding an entire large payment could make
    ///      `unvestedYield() >= K * totalAssets()` and trip the defence-in-depth entry closure in
    ///      an otherwise healthy vault. The new stream is therefore capped at `1/(K+1)` of the
    ///      post-delivery physical USDfr; any excess is recognized immediately. This is an
    ///      explicit UPWARD rate step on cash already received, never forward income or a
    ///      downward repricing. The cap mathematically guarantees the delivery itself cannot trip
    ///      the operational guard. A later realized loss may still strand the stream and close
    ///      entry, as intended.
    ///
    ///      Between the delivery and this call the vault is transiently over-valued. The
    ///      WaterfallEngine first calls `beginYieldNotification`, which leaves this vault's
    ///      persistent operation lock set across `mintYield`; permissionless fee checkpoints
    ///      therefore revert until this function consumes the lock in the same transaction.
    /// @param amount The realized yield just delivered into this vault.
    function notifyYield(uint256 amount) external onlyRole(Roles.CREDIT_ROLE) nonReentrant {
        SUSDfrStorage storage $ = _storage();
        _requireFeeOperation($, FEE_OPERATION_YIELD);
        if (amount != 0 && $.yieldVestingPeriod != 0) {
            uint256 pending = unvestedYield(); // MUST be read before the fields are overwritten
            uint64 oldEnd = _vestingEnd($);
            uint64 proposedEnd = uint64(block.timestamp + $.yieldVestingPeriod);
            uint64 end = pending != 0 && oldEnd > block.timestamp && oldEnd < proposedEnd ? oldEnd : proposedEnd;
            $.vestingAmount = pending + amount;
            $.lastYieldAt = uint64(block.timestamp);
            $.vestingEndsAt = end;
            // One shared boundary rule for inflow and outflow (see `_capStreamToBase`): it caps
            // the stream against the post-delivery balance and recognizes any excess at once,
            // emitting `YieldInstantlyRecognized`. `YieldStreamStarted` therefore reports the
            // stream actually retained.
            _capStreamToBase(0);
            emit YieldStreamStarted(amount, $.vestingAmount, $.yieldVestingPeriod);
            emit YieldStreamDeadlineSet($.vestingEndsAt);
        }
        _clearFeeOperation($);
    }

    /// @notice Sets the yield vesting window (ADR-0023). Zero credits yield instantly.
    /// @dev Timelocked governance. The window applies to the release schedule from HERE ON;
    ///      it is NOT applied retroactively to what has already vested.
    ///
    ///      CRYSTALLIZATION (audit H-3, and the property that makes this safe): `unvestedYield()`
    ///      reads the live period against the stored `vestingAmount`/`lastYieldAt`, so writing a
    ///      new period against a stale pair would RE-PRICE the stream. Lengthening resurrected
    ///      yield that had already vested — including from a stream that had run to completion,
    ///      since `vestingAmount` is only ever overwritten, never zeroed — dropping
    ///      `totalAssets()` and the exchange rate in a single transaction with no loss and no
    ///      cascade (a §1.3 monotonicity break), short-changing any queued senior settling next
    ///      block and handing a fresh depositor a permissionless dilution mint that re-lowering
    ///      the period cannot un-mint. Shortening was the mirror: it stepped the rate UP and let
    ///      a depositor capture the unvested stream.
    ///
    ///      So the pending remainder is crystallized against the OLD schedule before the new
    ///      policy is written. The stream's absolute deadline may move earlier but never later:
    ///      alternating two different non-zero periods therefore cannot perpetually restart an
    ///      already-realized stream. Continuity is preserved at the setter timestamp and a
    ///      completed stream is retired rather than resurrected.
    ///
    ///      THE ONE DISCONTINUITY, deliberate: `period == 0` is the documented instant-credit
    ///      escape hatch, so it releases the crystallized remainder immediately. That is a step
    ///      UP on already-realized yield the vault already holds (never down), i.e. the
    ///      pre-ADR-0023 behaviour restored on purpose; it is not a silent rate fall.
    ///
    ///      A SAME-VALUE WRITE IS A NO-OP, deliberately (audit H-3 remediation). Crystallizing
    ///      restarts `lastYieldAt`, so re-applying the CURRENT period would re-stretch the
    ///      remaining stream over a fresh full window — instantaneously neutral, never a
    ///      claw-back, but it defers recognition of yield the vault already holds, and repeated
    ///      calls defer it geometrically (measured pre-guard: a 27,500e18 stream on the 7-day
    ///      default, re-written daily, still withheld 1,260e18 after 20 writes). A re-run
    ///      parameter-assertion script (CLAUDE.md §2.1) would trip exactly that. The early
    ///      return keeps the natural schedule intact and is safe by definition — `unvestedYield()`
    ///      cannot change when neither the period nor the stored pair changes. It emits nothing,
    ///      because no state transitioned.
    /// @param period The vesting window in seconds; must not exceed `MAX_YIELD_VESTING_PERIOD`.
    function setYieldVestingPeriod(uint64 period) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (period > Config.MAX_YIELD_VESTING_PERIOD) revert SUSDfr_VestingPeriodTooLong(period);
        SUSDfrStorage storage $ = _storage();
        if (period == $.yieldVestingPeriod) return;
        // Crystallize all marked NAV released under the OLD schedule before its future pace
        // changes. This also makes management-fee rate-time accounting independent of an
        // administrative vesting transaction.
        _accrueFees();
        // MUST be read against the OLD period, before the write below
        uint256 pending = unvestedYield();
        uint64 oldEnd = _vestingEnd($);
        $.lastYieldAt = uint64(block.timestamp);
        $.yieldVestingPeriod = period;
        if (period == 0 || pending == 0) {
            $.vestingAmount = 0;
            $.vestingEndsAt = 0;
        } else {
            uint64 proposedEnd = uint64(block.timestamp + period);
            $.vestingAmount = pending;
            $.vestingEndsAt = oldEnd > block.timestamp && oldEnd < proposedEnd ? oldEnd : proposedEnd;
        }
        // the crystallized stream is a state transition in its own right (CLAUDE.md §3.1):
        // nothing newly delivered, `pending` re-based to start now under the new window
        emit YieldStreamStarted(0, pending, period);
        emit YieldVestingPeriodSet(period);
        emit YieldStreamDeadlineSet($.vestingEndsAt);
        // `period == 0` deliberately recognizes the pending stream immediately. Charge the
        // resulting realized performance in this same, explicit governance transaction.
        if (period == 0) _accrueFees();
    }

    /// @inheritdoc IsUSDfr
    function setRedemptionQueue(address queue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (queue == address(0)) revert SUSDfr_ZeroAddress();
        _storage().redemptionQueue = queue;
        emit RedemptionQueueUpdated(queue);
    }

    /// @notice Pauses deposits and exits. Emergency use only.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Internals ────────────────────────────────────────────────────────

    /// @dev Preserves the protocol-specific transient-state error for a points callback
    ///      that tries to enter the public checkpoint. The general `nonReentrant` guard
    ///      then covers callbacks from the underlying USDfr transfer itself.
    modifier feeCheckpointEntry() {
        SUSDfrStorage storage $ = _storage();
        if ($.feeAccrualInProgress || $.shareUpdateInProgress || $.feeOperationKind != FEE_OPERATION_NONE) {
            revert SUSDfr_FeeAccrualReentrant();
        }
        _;
    }

    /// @dev Vault entry: permissionless (2026-07-14 directive) — staking is not the KYC
    ///      primary gate; that lives at USDfr mint/redeem. Sanctions are enforced in
    ///      `_update` (the share mint) and on the incoming USDfr transfer. Pause still applies.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        SUSDfrStorage storage $ = _storage();
        uint256 supplyBefore = totalSupply();
        uint256 hurdleBefore = _highWaterMarkAssets($, supplyBefore);
        super._deposit(caller, receiver, assets, shares);
        // Preserve the pre-flow ASSET hurdle and add exactly the principal delivered.
        // A per-share ratchet alone forgets live drawdown when realized entry NAV differs
        // from conservative marked NAV.
        _adjustHighWaterMarkForAssetFlow($, hurdleBefore, supplyBefore, assets, true, 0);
    }

    /// @dev Vault exit: only the redemption queue may withdraw/redeem (ADR-0010).
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        SUSDfrStorage storage $ = _storage();
        if (caller != $.redemptionQueue) revert SUSDfr_QueueOnly();
        uint256 supplyBefore = totalSupply();
        uint256 hurdleBefore = _highWaterMarkAssets($, supplyBefore);
        // R16-02: cap against the post-outflow physical balance before the ERC-4626 burn and
        // transfer. This keeps the stream boundary true throughout the transfer's hooks.
        uint256 recognized = _capStreamToBase(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
        // Preserve both sides of the dual-NAV exit law. The asset carry protects stayers
        // during a genuine drawdown; the pro-rata carry prevents a leaver priced on
        // junior-supported redemption NAV from shedding deferred performance-fee exposure.
        _adjustHighWaterMarkForAssetFlow($, hurdleBefore, supplyBefore, assets, false, recognized);
        // AUDIT FIX (RC-03): `notifyYield` caps the stream at exactly `K/(K+1)` of the
        // balance, which leaves the vault sitting ON the `_isDegenerate` boundary — zero
        // slack when the balance divides exactly. Assets leaving here shrink `totalAssets()`
        // while the stream is unchanged, so ANY outflow would otherwise push the ratio into
        // the closed region and shut the sole senior entry point during ordinary settlement.
        // Re-capping against the post-outflow balance holds `unvestedYield() <= K *
        // totalAssets()` at all times. It only ever moves NAV up, never down.
    }

    /// @dev Crystallizes both vault-level fees by minting shares to the protocol recipient.
    ///      No USDfr leaves the vault, so backing is unchanged. Management is calculated
    ///      first; performance is then measured on the post-management marked-NAV rate.
    function _accrueFees() private returns (uint256 managementShares, uint256 performanceShares) {
        SUSDfrStorage storage $ = _storage();
        // The points hook runs inside ERC-20 share updates. It is fail-open and trusted,
        // but must not be able to crystallize fees against the transient supply/NAV window
        // observed during mint, burn, or transfer.
        if ($.feeAccrualInProgress || $.shareUpdateInProgress || $.feeOperationKind != FEE_OPERATION_NONE) {
            revert SUSDfr_FeeAccrualReentrant();
        }
        $.feeAccrualInProgress = true;

        FeeCalculation memory calc = _calculateFees($);
        $.lastFeeAccrual = uint64(block.timestamp);

        // No investor-owned shares means there is nobody to charge. Ratchet the baseline
        // fee-free (including any pre-seed donation) and begin time accounting from now.
        if (totalSupply() == 0) {
            uint256 emptyRate = _feeExchangeRate(Math.Rounding.Ceil);
            if (emptyRate > $.highWaterMark) {
                emit HighWaterMarkAdjusted($.highWaterMark, emptyRate);
                $.highWaterMark = emptyRate;
            }
            $.feeAccrualInProgress = false;
            return (0, 0);
        }

        managementShares = calc.managementShares;
        performanceShares = calc.performanceShares;
        uint256 totalFeeShares = managementShares + performanceShares;
        if (totalFeeShares != 0) {
            // A zero recipient is possible only on an improperly migrated pre-fee proxy;
            // fail loudly rather than silently waive or burn a protocol fee.
            if ($.feeRecipient == address(0)) revert SUSDfr_ZeroAddress();
        }

        uint256 oldHighWaterMark = $.highWaterMark;
        uint256 newHighWaterMark = oldHighWaterMark;
        if (oldHighWaterMark == 0) {
            // Safe upgrade posture for a legacy proxy: do not treat any pre-upgrade AUM as
            // profit. Anchor to realized assets, which is fee-neutral whether a live mark
            // later cures or becomes a realized loss. Redemption NAV still excludes the
            // senior-marked portion and therefore is not a complete migration baseline.
            // Fresh deployments initialize this field and never take this branch.
            newHighWaterMark = Math.mulDiv(
                10 ** decimals(),
                totalAssets() + 1,
                totalSupply() + totalFeeShares + 10 ** _decimalsOffset(),
                Math.Rounding.Ceil
            );
            $.highWaterMark = newHighWaterMark;
        } else if (calc.profitAssets != 0) {
            // Round the stored hurdle UP. A floor-rounded reset leaves a one-wei residual
            // that can mint microscopic fee shares on an immediate second checkpoint.
            newHighWaterMark = _feeExchangeRateAtSupply(totalSupply() + totalFeeShares, Math.Rounding.Ceil);
            $.highWaterMark = newHighWaterMark;
        }

        // All fee-accounting effects are committed before `_mint` reaches the optional
        // points callback. The outer nonReentrant frame and the transient-state locks remain
        // defence in depth; if minting fails, the whole transaction (including these writes)
        // rolls back.
        if (totalFeeShares != 0) {
            _mint($.feeRecipient, totalFeeShares);
        }

        if (calc.managementAssets != 0) {
            emit ManagementFeeAccrued(calc.elapsed, calc.managementAssets, managementShares);
        }

        if (oldHighWaterMark != 0 && calc.profitAssets != 0) {
            emit PerformanceFeeAccrued(
                oldHighWaterMark, newHighWaterMark, calc.profitAssets, calc.performanceAssets, performanceShares
            );
        }

        $.feeAccrualInProgress = false;
    }

    /// @dev Previews a sequential management-then-performance checkpoint without writes.
    function _calculateFees(SUSDfrStorage storage $) private view returns (FeeCalculation memory calc) {
        uint64 last = $.lastFeeAccrual;
        calc.elapsed = last == 0 ? 0 : block.timestamp - uint256(last);

        uint256 supply = totalSupply();
        if (supply == 0) return calc;

        // Management remains an AUM fee on the conservative redemption base. Performance
        // starts from the same mark but removes the source-reported junior-capital credit:
        // contributed curator/backstop protection is not investment profit. The separate
        // source view also releases automatically with the underlying impairment.
        uint256 markedAssets = redemptionTotalAssets();
        uint256 performanceMarkedAssets = _performanceFeeTotalAssets();
        uint256 baseEffectiveSupply = supply + 10 ** _decimalsOffset();
        if ($.managementFeeBps != 0 && calc.elapsed != 0 && markedAssets != 0) {
            calc.managementAssets = _managementFeeAssets(markedAssets, $.managementFeeBps, calc.elapsed);
            calc.managementShares = _feeSharesForAssets(calc.managementAssets, markedAssets, baseEffectiveSupply);
        }

        uint256 hwm = $.highWaterMark;
        if (hwm == 0) return calc; // legacy-proxy baseline is initialized fee-free in `_accrueFees`

        uint256 shareUnit = 10 ** decimals();
        // Management is charged first. Its shares are valued on redemption NAV, so translate
        // their dilution into the potentially lower performance-fee NAV by retaining the
        // original investors' pro-rata portion after the management mint. Comparing that
        // retained base with the ORIGINAL-supply hurdle is the exact sequential model and
        // cannot charge performance on management.
        uint256 supplyAfterManagement = baseEffectiveSupply + calc.managementShares;
        uint256 netPerformanceAssets =
            Math.mulDiv(performanceMarkedAssets + 1, baseEffectiveSupply, supplyAfterManagement, Math.Rounding.Floor);
        uint256 hurdleAssets = Math.mulDiv(hwm, baseEffectiveSupply, shareUnit, Math.Rounding.Ceil);
        if (netPerformanceAssets <= hurdleAssets) return calc;

        calc.profitAssets = netPerformanceAssets - hurdleAssets;
        calc.performanceAssets = Math.mulDiv(calc.profitAssets, $.performanceFeeBps, Config.BPS, Math.Rounding.Floor);
        // Both fees go to the same recipient. Recompute the COMBINED share mint from the
        // original supply so neither fee dilutes the other. `managementShares` remains the
        // stand-alone attribution; the difference is the incremental performance attribution
        // returned and emitted by the checkpoint.
        uint256 totalFeeShares =
            _feeSharesForAssets(calc.managementAssets + calc.performanceAssets, markedAssets, baseEffectiveSupply);
        calc.performanceShares = totalFeeShares - calc.managementShares;
    }

    /// @dev Asset-denominated management fee for `elapsed`, with a 365-day basis.
    ///      Annual retention is raised to the fractional-year exponent, making the result
    ///      checkpoint-frequency neutral: two half-year checkpoints and one annual
    ///      checkpoint apply the same retention apart from fixed-point approximation.
    function _managementFeeAssets(uint256 assets, uint16 feeBps, uint256 elapsed) private pure returns (uint256) {
        uint256 wad = 1e18;
        uint256 annualFeeWad = Math.mulDiv(feeBps, wad, Config.BPS, Math.Rounding.Floor);
        uint256 annualRetentionWad = wad - annualFeeWad;
        uint256 elapsedYearsWad = Math.mulDiv(elapsed, wad, Config.MANAGEMENT_FEE_YEAR, Math.Rounding.Floor);
        uint256 retentionWad = uint256(FixedPointMathLib.powWad(int256(annualRetentionWad), int256(elapsedYearsWad)));
        return Math.mulDiv(assets, wad - retentionWad, wad, Math.Rounding.Floor);
    }

    /// @dev Shares whose post-mint marked-NAV value is no more than `feeAssets`.
    ///      Mirrors ERC-4626's virtual asset/share terms and rounds DOWN so the protocol
    ///      never collects more than the configured asset-denominated fee.
    function _feeSharesForAssets(uint256 feeAssets, uint256 markedAssets, uint256 effectiveSupply)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(feeAssets, effectiveSupply, markedAssets + 1 - feeAssets, Math.Rounding.Floor);
    }

    /// @dev ERC-4626 conversions preview the supply as though all fees due now had
    ///      crystallized. Without this, a read immediately before `deposit`/`redeem` would
    ///      quote the gross pre-fee rate even though the transaction checkpoints first.
    ///      During an actual share update or fee mint, use the concrete supply: exposing a
    ///      recursively simulated supply to a callback would describe a transient state.
    function _feeAdjustedSupply() private view returns (uint256 supply) {
        supply = totalSupply();
        SUSDfrStorage storage $ = _storage();
        if ($.feeAccrualInProgress || $.shareUpdateInProgress || $.feeOperationKind != FEE_OPERATION_NONE) {
            return supply;
        }
        FeeCalculation memory calc = _calculateFees($);
        return supply + calc.managementShares + calc.performanceShares;
    }

    /// @dev Generic realized-NAV conversion, net of all fee shares due at this timestamp.
    ///      Deposit/mint quotes deliberately override this with the physical-balance entry NAV;
    ///      see `previewDeposit` and `previewMint`.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, _feeAdjustedSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @dev Realized-NAV value conversion, net of all fee shares due at this timestamp.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, _feeAdjustedSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev Performance-fee NAV assets per one whole sUSDfr token, after removing
    ///      fee-neutral junior-capital credit.
    function _feeExchangeRate() private view returns (uint256) {
        return _feeExchangeRate(Math.Rounding.Floor);
    }

    function _feeExchangeRate(Math.Rounding rounding) private view returns (uint256) {
        return _feeExchangeRateAtSupply(totalSupply(), rounding);
    }

    function _feeExchangeRateAtSupply(uint256 supply, Math.Rounding rounding) private view returns (uint256) {
        return
            Math.mulDiv(10 ** decimals(), _performanceFeeTotalAssets() + 1, supply + 10 ** _decimalsOffset(), rounding);
    }

    function _performanceFeeTotalAssets() private view returns (uint256) {
        uint256 assets = totalAssets();
        IImpairmentSource source = _storage().impairmentSource;
        if (address(source) == address(0)) return assets;

        uint256 pendingImpairment = source.pendingSeniorImpairment();
        uint256 performanceImpairment = source.performanceFeeImpairment();
        if (performanceImpairment < pendingImpairment) {
            revert SUSDfr_InvalidPerformanceFeeImpairment(pendingImpairment, performanceImpairment);
        }
        return performanceImpairment >= assets ? 0 : assets - performanceImpairment;
    }

    /// @dev Converts the stored per-share HWM into the exact asset hurdle consumed by
    ///      `_calculateFees` at `supply`.
    function _highWaterMarkAssets(SUSDfrStorage storage $, uint256 supply) private view returns (uint256) {
        return Math.mulDiv($.highWaterMark, supply + 10 ** _decimalsOffset(), 10 ** decimals(), Math.Rounding.Ceil);
    }

    /// @dev Preserves an asset-denominated hurdle across principal entering or leaving.
    function _adjustHighWaterMarkForAssetFlow(
        SUSDfrStorage storage $,
        uint256 hurdleBefore,
        uint256 supplyBefore,
        uint256 assets,
        bool increase,
        uint256 uncheckpointedGain
    ) private {
        uint256 hurdleAfter;
        if (increase) {
            hurdleAfter = hurdleBefore + assets;
        } else {
            uint256 assetCarry = assets >= hurdleBefore ? 0 : hurdleBefore - assets;
            uint256 proRataCarry = Math.mulDiv(
                hurdleBefore,
                totalSupply() + 10 ** _decimalsOffset(),
                supplyBefore + 10 ** _decimalsOffset(),
                Math.Rounding.Ceil
            );
            hurdleAfter = Math.max(assetCarry, proRataCarry);
        }
        _setHighWaterMarkForAssetHurdle($, hurdleAfter, totalSupply(), uncheckpointedGain);
    }

    /// @dev Re-anchors the per-share HWM to an ASSET hurdle at `supply`. The current
    ///      conservative rate remains a lower bound only for rounding dust; after a
    ///      checkpoint an honest fee-neutral flow cannot put marked assets above the
    ///      preserved hurdle.
    function _setHighWaterMarkForAssetHurdle(
        SUSDfrStorage storage $,
        uint256 hurdleAssets,
        uint256 supply,
        uint256 uncheckpointedGain
    ) private {
        uint256 adjusted =
            Math.mulDiv(hurdleAssets, 10 ** decimals(), supply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
        uint256 markedAssets = _performanceFeeTotalAssets();
        markedAssets = markedAssets > uncheckpointedGain ? markedAssets - uncheckpointedGain : 0;
        uint256 currentRate =
            Math.mulDiv(10 ** decimals(), markedAssets + 1, supply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
        if (currentRate > adjusted) adjusted = currentRate;
        if (adjusted != $.highWaterMark) {
            emit HighWaterMarkAdjusted($.highWaterMark, adjusted);
            $.highWaterMark = adjusted;
        }
    }

    /// @dev Raises (never lowers) the HWM without charging a fee. Used after
    ///      valuation-source changes whose mechanical NAV effect is not investment profit.
    function _ratchetHighWaterMark() private {
        SUSDfrStorage storage $ = _storage();
        uint256 rate = _feeExchangeRate(Math.Rounding.Ceil);
        if (rate > $.highWaterMark) {
            emit HighWaterMarkAdjusted($.highWaterMark, rate);
            $.highWaterMark = rate;
        }
    }

    function _requireFeeOperation(SUSDfrStorage storage $, uint8 expectedKind) private view {
        if ($.feeOperationCaller != msg.sender || $.feeOperationKind != expectedKind) {
            revert SUSDfr_InvalidFeeOperation(msg.sender, expectedKind, $.feeOperationKind);
        }
    }

    function _clearFeeOperation(SUSDfrStorage storage $) private {
        $.feeOperationCaller = address(0);
        $.feeOperationKind = FEE_OPERATION_NONE;
        $.feeOperationMarkedAssets = 0;
        $.feeOperationHurdleAssets = 0;
        $.feeOperationSupply = 0;
    }

    /// @dev Rejects an EOA, reverting implementation, or malformed ABI response before it can
    ///      become the source that all fee and redemption views depend on.
    function _validateImpairmentSource(address source) private view {
        if (source == address(0)) return;
        (bool readable,) = _probeImpairmentSource(source, gasleft());
        if (!readable) revert SUSDfr_InvalidImpairmentSource(source);
    }

    /// @dev A bounded ABI-shape probe used by both installation validation and emergency
    ///      recovery. Both redemption and performance-fee impairment reads must return at
    ///      least one full ABI word. Only the first word is copied, preventing a return-data
    ///      bomb from consuming the recovery reserve. The failure hash also identifies which
    ///      selector failed.
    function _probeImpairmentSource(address source, uint256 gasLimit)
        private
        view
        returns (bool readable, bytes32 failureHash)
    {
        if (source.code.length == 0) {
            return (false, keccak256(abi.encode(uint256(0), bytes32(0))));
        }

        bytes4 pendingSelector = IImpairmentSource.pendingSeniorImpairment.selector;
        uint256 pendingImpairment;
        (readable, failureHash, pendingImpairment) = _probeUint256(source, pendingSelector, gasLimit);
        if (!readable) return (false, keccak256(abi.encode(pendingSelector, failureHash)));

        bytes4 performanceSelector = IImpairmentSource.performanceFeeImpairment.selector;
        uint256 performanceImpairment;
        (readable, failureHash, performanceImpairment) = _probeUint256(source, performanceSelector, gasLimit);
        if (!readable) return (false, keccak256(abi.encode(performanceSelector, failureHash)));
        if (performanceImpairment < pendingImpairment) {
            return (
                false,
                keccak256(
                    abi.encode(
                        SUSDfr_InvalidPerformanceFeeImpairment.selector, pendingImpairment, performanceImpairment
                    )
                )
            );
        }
    }

    function _probeUint256(address source, bytes4 selector, uint256 gasLimit)
        private
        view
        returns (bool readable, bytes32 failureHash, uint256 value)
    {
        bytes memory callData = abi.encodeWithSelector(selector);
        assembly ("memory-safe") {
            // The scratch word is both the fixed-size output buffer and the first-word
            // failure sample. `staticcall` copies at most 32 bytes regardless of how much
            // return data the source advertises.
            mstore(0x00, 0)
            let success := staticcall(gasLimit, source, add(callData, 0x20), mload(callData), 0x00, 0x20)
            let returnSize := returndatasize()
            readable := and(success, iszero(lt(returnSize, 0x20)))
            value := mload(0x00)

            if iszero(readable) {
                mstore(0x00, returnSize)
                mstore(0x20, value)
                failureHash := keccak256(0x00, 0x40)
            }
        }
    }

    /// @dev Caps the live vesting stream to `1/(K+1)` of the physical balance that remains
    ///      after the pending outflow, recognizing any excess immediately. This is the single
    ///      boundary rule used by `notifyYield` (zero outflow), queue pricing, and `_withdraw`.
    ///
    ///      SECURITY BOUNDARY: this cap is no longer used to claim a bound on an entrant's
    ///      economic skim. The old bound was false because return-on-deposit increases as the
    ///      deposit shrinks. `previewDeposit`/`previewMint` now price all physical USDfr already
    ///      held by the vault, making the transfer from incumbents non-positive at every deposit
    ///      size. This cap remains only to keep healthy operations out of the fail-closed
    ///      stranded-stream band.
    ///
    ///      Retaining the smaller `held/(K+1)` side of the boundary leaves a genuine minority
    ///      stream and avoids parking a healthy vault exactly on `_isDegenerate()`'s strict
    ///      inequality. The cap guarantees entry cannot close from the operation that triggered
    ///      it: `unvestedYield() <= held/(K+1)` while `totalAssets() >= K*held/(K+1)`.
    ///
    ///      Recognizing the excess is an explicit UPWARD rate step on cash already held; it
    ///      never creates value, never re-prices downward, and never touches forward income.
    ///      Like the `notifyYield` rollover, it restarts the clock for the retained stream,
    ///      which only slows recognition — the conservative direction. The retained amount is
    ///      non-increasing across successive calls, so the stream cannot be perpetuated.
    /// @param pendingOutflow USDfr committed to leave this vault in this transaction but not
    ///        transferred yet. Zero on the inflow leg.
    function _capStreamToBase(uint256 pendingOutflow) private returns (uint256 instantlyRecognized) {
        SUSDfrStorage storage $ = _storage();
        uint256 pending = unvestedYield();
        if (pending == 0) return 0;
        uint64 end = _vestingEnd($);

        uint256 retained;
        if ($.yieldVestingPeriod != 0 && totalSupply() != 0) {
            uint256 held = IERC20(asset()).balanceOf(address(this));
            held = held > pendingOutflow ? held - pendingOutflow : 0;
            uint256 k = Config.SUSDFR_MAX_STRANDED_YIELD_RATIO;
            retained = held / (k + 1);
            if (pending <= retained) return 0; // already inside the boundary — nothing to do
        }

        $.vestingAmount = retained;
        $.lastYieldAt = uint64(block.timestamp);
        $.vestingEndsAt = retained == 0 ? 0 : end;
        instantlyRecognized = pending - retained;
        emit YieldInstantlyRecognized(instantlyRecognized);
    }

    /// @dev Upgrade-safe fallback: deployments predating M-3 have a zero appended deadline, so
    ///      their active stream keeps its original `lastYieldAt + yieldVestingPeriod` end.
    function _vestingEnd(SUSDfrStorage storage $) private view returns (uint64) {
        uint64 end = $.vestingEndsAt;
        if (end != 0) return end;
        if ($.vestingAmount == 0 || $.yieldVestingPeriod == 0) return 0;
        return uint64(uint256($.lastYieldAt) + uint256($.yieldVestingPeriod));
    }

    /// @dev Observes every share balance change for the points ledger (ADR-0016).
    ///      The hook is a trusted protocol module; a zero address disables it.
    /// @dev AUDIT NOTE (R6-I2): OZ `_withdraw` burns shares before transferring assets, so
    ///      inside this hook `totalSupply` is transiently reduced while assets are still held
    ///      → `convertToAssets`/`currentExchangeRate` read an INFLATED rate mid-transaction.
    ///      This is safe ONLY because the points hook never reads the exchange rate and no
    ///      other on-chain consumer reads it outside a nonReentrant frame. If a future hook
    ///      observer (or a second `_update` consumer) reads the rate, that read is inside this
    ///      inflated window — do NOT add rate-dependent logic here without closing the window.
    function _update(address from, address to, uint256 value) internal override {
        SUSDfrStorage storage $ = _storage();
        // Block a trusted points callback from entering `accrueFees()` while ERC-20 supply
        // and vault assets can be in a transiently inconsistent state.
        if ($.shareUpdateInProgress) revert SUSDfr_FeeAccrualReentrant();
        $.shareUpdateInProgress = true;

        // Sanctions freeze on sUSDfr shares (transfers otherwise permissionless, 2026-07-14
        // directive). canTransfer permits mints/burns and protocol-module legs; it denies
        // only a sanctioned non-module party.
        if (!$.compliance.canTransfer(address(this), from, to)) {
            revert SUSDfr_TransferBlocked(from, to);
        }
        super._update(from, to, value);
        // AUDIT FIX (R2-M-02): the points hook is FAIL-OPEN. Points are a non-financial
        // participation ledger; a points-module failure must never block a deposit,
        // transfer, or redemption burn. A revert here degrades points accrual, nothing more.
        IPointsModule points = $.pointsModule;
        if (address(points) != address(0)) {
            // F-18-02: use the same enforceable floor and retained epilogue reserve as USDfr.
            // Caller-controlled underfunding reverts the whole share move; a sufficiently
            // funded hook failure remains fail-open and repairable through reconcile.
            uint256 hookGas = PointsHookGas.hookGasLimit();
            // FAIL-OPEN, with telemetry (P-04) so a dropped transition is observable and
            // repairable via PointsModule.reconcile.
            try points.onSharesTransfer{gas: hookGas}(from, to, value) {}
            catch {
                emit PointsHookFailed(from, to, value);
            }
        }
        $.shareUpdateInProgress = false;
    }

    /// @dev Virtual-share offset: raises the cost of donation/inflation attacks
    ///      (ADR-0005; deployment additionally seeds an initial deposit).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        // Executable ordering constraint for the dual-NAV dependency: the installed
        // impairment-source proxy must expose both selectors before the vault can move
        // to another implementation. Upgrade DefaultManager, then its assessed wrapper,
        // then this vault in one timelock batch.
        _validateImpairmentSource(address(_storage().impairmentSource));
    }

    function _storage() private pure returns (SUSDfrStorage storage $) {
        assembly {
            $.slot := SUSDFR_STORAGE_LOCATION
        }
    }
}
