// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {IPointsModule} from "./interfaces/IPointsModule.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title CuratorModule — per-class curator first-loss vaults (ADR-0004)
/// @notice Cascade LAYER 1 (CLAUDE.md §1.3 ordering): curator capital absorbs realized
///         losses before the sGROVE backstop and before any depositor impairment.
///         Each collateral class has its own USDfr pool; multiple curators in a class
///         hold internal shares so partial absorptions dilute all of them exactly
///         pro-rata. A fully wiped pool advances to a new share round: stale-round
///         shares are worth zero and are cleared lazily on the holder's next post.
///
///         SUBORDINATION HEADROOM: capital protecting live exposure cannot leave —
///         withdrawals are capped at `poolBalance - min(firstLossTarget, classExposure)`.
///         Curators earn nothing here; their return comes from origination economics.
///         Senior (`sUSDfr`) is therefore never subordinated to this junior capital.
/// @dev `absorbLoss` is deliberately NOT pausable: the guardian can halt curator
///      post/withdraw traffic, but never the loss cascade — a paused cascade during a
///      credit event would block honest loss recognition (CLAUDE.md fail-loudly).
contract CuratorModule is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ICuratorModule
{
    using SafeERC20 for IERC20;

    struct ClassPool {
        uint256 balance; // USDfr actually held for this class
        uint256 totalShares; // internal pro-rata shares over `balance`
        uint256 round; // advances when a pool is wiped to zero with shares outstanding
    }

    struct CuratorStake {
        uint256 shares;
        uint256 round; // shares are valid only while round == pool.round
    }

    /// @custom:storage-location erc7201:forestroad.storage.CuratorModule
    struct CuratorStorage {
        IERC20 usdfr;
        ICollateralRegistry registry;
        mapping(uint256 classId => ClassPool) pools;
        mapping(uint256 classId => mapping(address curator => CuratorStake)) stakes;
        mapping(uint256 classId => mapping(address curator => bool)) approved;
        mapping(uint256 classId => uint256) targets; // first-loss target (ADR-0004)
        // AUDIT FIX (R4-EC2): per-class count of unresolved defaults. Non-zero freezes
        // curator withdrawals so a curator cannot front-run realizeLoss to pull excess
        // first-loss ahead of a loss it should absorb. Incremented by the DefaultManager
        // on default entry (declareDefault / liquidate), decremented by governance on
        // workout resolution. (Append-only: added at the tail for upgrade safety.)
        mapping(uint256 classId => uint256) unresolvedDefaults;
        // AUDIT FIX (P-01): participation-points hook. First-loss capital accrues points at
        // the curator multiple (in lieu of only earning origination economics). Optional;
        // fail-open so a points failure can never block first-loss post/withdraw.
        IPointsModule pointsModule;
        // Vault fee-accounting coordinator. Brackets capacity writes so a curator
        // top-up/withdrawal cannot be mistaken for senior investment performance.
        IsUSDfr feeVault;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.CuratorModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CURATOR_STORAGE_LOCATION =
        0x3ed45dc5309d95eb5c32609ee7ca79f82c5062e7efdb606949190d8a38c9b400;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the module and seeds the five genesis classes with the
    ///         ADR-0004 default first-loss target ($10M/class).
    /// @param admin Governance timelock (approves curators, sets targets).
    /// @param guardian Emergency pauser (post/withdraw only — never the cascade).
    /// @param upgrader Upgrade authority (timelock).
    /// @param usdfr First-loss denomination asset.
    /// @param registry Collateral registry (class exposure for the headroom rule).
    /// @param feeVault sUSDfr vault whose conservative NAV nets this capacity.
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address usdfr,
        address registry,
        address feeVault
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr == address(0)
                || registry == address(0) || feeVault == address(0)
        ) revert Curator_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        CuratorStorage storage $ = _storage();
        $.usdfr = IERC20(usdfr);
        $.registry = ICollateralRegistry(registry);
        $.feeVault = IsUSDfr(feeVault);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.targets[classId] = Config.DEFAULT_FIRST_LOSS_PER_CLASS;
            emit FirstLossTargetSet(classId, Config.DEFAULT_FIRST_LOSS_PER_CLASS);
        }
    }

    // ── Governance ───────────────────────────────────────────────────────

    /// @notice Approves or revokes `curator` for `classId` (anchor curator = Forest
    ///         Road, additional curators pluggable per ADR-0004). Revocation blocks
    ///         new posts only; the existing stake keeps absorbing and stays
    ///         withdrawable within headroom.
    function setCuratorApproved(uint256 classId, address curator, bool approved)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (curator == address(0)) revert Curator_ZeroAddress();
        _requireKnownClass(classId);
        _storage().approved[classId][curator] = approved;
        emit CuratorApproved(classId, curator, approved);
    }

    /// @notice Sets a class's first-loss target (the subordination requirement while
    ///         exposure is at or above it). Governance-adjustable per ADR-0004.
    function setFirstLossTarget(uint256 classId, uint256 target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        _storage().targets[classId] = target;
        emit FirstLossTargetSet(classId, target);
    }

    /// @notice Emitted when the participation-points hook changes.
    event PointsModuleUpdated(address indexed module);

    /// @notice Wires the participation-points hook so first-loss capital accrues points
    ///         (P-01). Timelocked governance only.
    function setPointsModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _storage().pointsModule = IPointsModule(module);
        emit PointsModuleUpdated(module);
    }

    /// @notice The wired participation-points hook (zero disables it).
    function pointsModule() external view returns (address) {
        return address(_storage().pointsModule);
    }

    // ── Curator paths ────────────────────────────────────────────────────

    /// @inheritdoc ICuratorModule
    function postFirstLoss(uint256 classId, uint256 amount) external nonReentrant whenNotPaused {
        CuratorStorage storage $ = _storage();
        if (!$.approved[classId][msg.sender]) revert Curator_NotApprovedCurator(classId, msg.sender);
        if (amount == 0) revert Curator_ZeroAmount();
        $.feeVault.beginFeeNeutralMarkedNavChange();

        ClassPool storage pool = $.pools[classId];
        // A wiped pool (balance zero, shares outstanding) starts a new round: the old
        // shares are worthless and must not dilute fresh capital.
        if (pool.balance == 0 && pool.totalShares != 0) {
            pool.round += 1;
            pool.totalShares = 0;
            emit PoolRoundAdvanced(classId, pool.round);
        }

        CuratorStake storage stake = $.stakes[classId][msg.sender];
        if (stake.round != pool.round) {
            // lazily clear a stale-round (wiped) stake
            stake.shares = 0;
            stake.round = pool.round;
        }

        // SHARE-PRICE <= 1 INVARIANT (fuzzed in CreditInvariants): only absorption
        // changes the balance/share ratio, and only downward; withdrawals burn
        // ceil-rounded shares, which cannot push the price above 1. Therefore
        // totalShares >= balance always, and shares >= amount >= 1 here — no zero-share
        // mint is reachable.
        uint256 shares = pool.totalShares == 0 ? amount : Math.mulDiv(amount, pool.totalShares, pool.balance);

        stake.shares += shares;
        pool.totalShares += shares;
        pool.balance += amount;
        $.usdfr.safeTransferFrom(msg.sender, address(this), amount);
        $.feeVault.endFeeNeutralMarkedNavChange();
        emit FirstLossPosted(classId, msg.sender, amount, shares, pool.round);
        _notifyPoints($, classId, msg.sender); // P-01: accrue points on the new posted first-loss
    }

    /// @inheritdoc ICuratorModule
    function withdrawFirstLoss(uint256 classId, uint256 amount) external nonReentrant whenNotPaused {
        CuratorStorage storage $ = _storage();
        if (amount == 0) revert Curator_ZeroAmount();
        // AUDIT FIX (R4-EC2): once a facility in this class has defaulted, the curator
        // cannot withdraw until governance resolves the workout — otherwise a curator
        // could front-run realizeLoss and pull excess first-loss ahead of the loss.
        if ($.unresolvedDefaults[classId] != 0) revert Curator_ClassDefaultFrozen(classId);

        ClassPool storage pool = $.pools[classId];
        CuratorStake storage stake = $.stakes[classId][msg.sender];

        uint256 posted = _postedOf(pool, stake);
        if (amount > posted) revert Curator_InsufficientStake(classId, msg.sender, amount, posted);

        uint256 free = _headroom($, classId, pool);
        if (amount > free) revert Curator_HeadroomExceeded(classId, amount, free);
        $.feeVault.beginFeeNeutralMarkedNavChange();

        // Shares burn rounds UP so a withdrawal can never take more value than the
        // caller's stake is worth (rounding dust favors the pool, i.e. the senior
        // side). Because amount <= posted = floor(shares·balance/totalShares), the
        // ceil here never exceeds the caller's shares (ceil(x) <= n iff x <= n).
        uint256 shares = Math.mulDiv(amount, pool.totalShares, pool.balance, Math.Rounding.Ceil);

        stake.shares -= shares;
        pool.totalShares -= shares;
        pool.balance -= amount;
        $.usdfr.safeTransfer(msg.sender, amount);
        $.feeVault.endFeeNeutralMarkedNavChange();
        emit FirstLossWithdrawn(classId, msg.sender, amount, shares, pool.round);
        _notifyPoints($, classId, msg.sender); // P-01: reconcile points to the reduced posted first-loss
    }

    // ── Cascade layer 1 (credit layer only; never pausable) ──────────────

    /// @inheritdoc ICuratorModule
    function absorbLoss(uint256 classId, uint256 loss)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        returns (uint256 absorbed, uint256 residual)
    {
        if (loss == 0) revert Curator_ZeroAmount();
        CuratorStorage storage $ = _storage();
        ClassPool storage pool = $.pools[classId];

        uint256 balanceBefore = pool.balance;
        absorbed = loss < pool.balance ? loss : pool.balance;
        residual = loss - absorbed;
        if (absorbed != 0) {
            // Shares are untouched: every staker in the class dilutes pro-rata.
            pool.balance -= absorbed;
            $.usdfr.safeTransfer(msg.sender, absorbed);
        }
        emit LossAbsorbed(classId, loss, absorbed, residual);
        // AUDIT FIX (P-01 follow-up / H-03): a loss dilutes every curator's postedOf without a
        // per-curator hook, so freeze curator point accrual in this class at the loss instant
        // until each curator reconciles. The bracketing pool balances are passed through so the
        // ledger can write each curator's stale cached balance down by the EXACT pro-rata
        // dilution (shares are untouched here, only `pool.balance` moves) — otherwise a curator
        // who tops back up to their pre-loss notional keeps the destroyed capital's maturity
        // ramp. FAIL-OPEN — never block the never-pausable cascade.
        if (absorbed != 0) {
            IPointsModule pm = $.pointsModule;
            if (address(pm) != address(0)) {
                try pm.onCuratorLoss(classId, balanceBefore, pool.balance) {} catch {}
            }
        }
    }

    // ── Default freeze (audit R4-EC2) ────────────────────────────────────

    /// @inheritdoc ICuratorModule
    /// @dev CREDIT_ROLE (the DefaultManager) records a default entering the class. Not
    ///      pausable — a default must always be recordable, mirroring the cascade. The
    ///      counter lets concurrent defaults on one class each require their own lift.
    function freezeOnDefault(uint256 classId) external onlyRole(Roles.CREDIT_ROLE) {
        _requireKnownClass(classId);
        CuratorStorage storage $ = _storage();
        uint256 count = $.unresolvedDefaults[classId] + 1;
        $.unresolvedDefaults[classId] = count;
        emit ClassDefaultFrozen(classId, count);
    }

    /// @inheritdoc ICuratorModule
    /// @dev Governance timelock lifts one freeze once a workout resolves. Reverts if the
    ///      class is not frozen, so lifts can never drive the counter below zero.
    function liftDefaultFreeze(uint256 classId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireKnownClass(classId);
        CuratorStorage storage $ = _storage();
        uint256 count = $.unresolvedDefaults[classId];
        if (count == 0) revert Curator_NotFrozen(classId);
        count -= 1;
        $.unresolvedDefaults[classId] = count;
        emit ClassDefaultFreezeLifted(classId, count);
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses curator post/withdraw. The cascade (`absorbLoss`) is NEVER
    ///         pausable — see the contract-level note.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses curator post/withdraw.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc ICuratorModule
    function poolBalance(uint256 classId) external view returns (uint256) {
        return _storage().pools[classId].balance;
    }

    /// @inheritdoc ICuratorModule
    function unresolvedDefaults(uint256 classId) external view returns (uint256) {
        return _storage().unresolvedDefaults[classId];
    }

    /// @inheritdoc ICuratorModule
    function postedOf(uint256 classId, address curator) external view returns (uint256) {
        CuratorStorage storage $ = _storage();
        return _postedOf($.pools[classId], $.stakes[classId][curator]);
    }

    /// @inheritdoc ICuratorModule
    function requiredFirstLoss(uint256 classId) public view returns (uint256) {
        CuratorStorage storage $ = _storage();
        return _requiredFirstLoss($, classId);
    }

    /// @inheritdoc ICuratorModule
    function headroom(uint256 classId) external view returns (uint256) {
        CuratorStorage storage $ = _storage();
        return _headroom($, classId, $.pools[classId]);
    }

    /// @inheritdoc ICuratorModule
    function firstLossTarget(uint256 classId) external view returns (uint256) {
        return _storage().targets[classId];
    }

    /// @inheritdoc ICuratorModule
    function isApprovedCurator(uint256 classId, address curator) external view returns (bool) {
        return _storage().approved[classId][curator];
    }

    /// @notice Wired module addresses (post-deploy validation aid).
    function modules() external view returns (address usdfr, address registry, address feeVault) {
        CuratorStorage storage $ = _storage();
        return (address($.usdfr), address($.registry), address($.feeVault));
    }

    /// @notice Current share round for a class pool (advances on full wipe-out).
    function poolRound(uint256 classId) external view returns (uint256) {
        return _storage().pools[classId].round;
    }

    /// @notice Total internal shares for a class pool. Always >= `poolBalance` (the
    ///         share price never exceeds 1 — see the note in `postFirstLoss`).
    function poolShares(uint256 classId) external view returns (uint256) {
        return _storage().pools[classId].totalShares;
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _postedOf(ClassPool storage pool, CuratorStake storage stake) private view returns (uint256) {
        if (stake.round != pool.round || pool.totalShares == 0) return 0;
        return Math.mulDiv(stake.shares, pool.balance, pool.totalShares);
    }

    /// @dev Subordination requirement: live exposure must stay protected up to the
    ///      class target. Below the target, all posted capital protecting exposure is
    ///      locked; a fully repaid class (zero exposure) frees everything.
    function _requiredFirstLoss(CuratorStorage storage $, uint256 classId) private view returns (uint256) {
        uint256 exposure = $.registry.classExposure(classId);
        uint256 target = $.targets[classId];
        return exposure < target ? exposure : target;
    }

    function _headroom(CuratorStorage storage $, uint256 classId, ClassPool storage pool)
        private
        view
        returns (uint256)
    {
        uint256 required = _requiredFirstLoss($, classId);
        return pool.balance > required ? pool.balance - required : 0;
    }

    /// @dev Notifies the points module of the curator's new posted first-loss (P-01),
    ///      FAIL-OPEN — a points failure must never block first-loss post/withdraw (which are
    ///      cascade-relevant capital movements).
    function _notifyPoints(CuratorStorage storage $, uint256 classId, address curator) private {
        IPointsModule pm = $.pointsModule;
        if (address(pm) != address(0)) {
            uint256 posted = _postedOf($.pools[classId], $.stakes[classId][curator]);
            try pm.onCuratorStakeChange(curator, classId, posted) {} catch {}
        }
    }

    function _requireKnownClass(uint256 classId) private pure {
        if (classId == 0 || classId > Config.NUM_CLASSES) revert Curator_UnknownClass(classId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (CuratorStorage storage $) {
        assembly {
            $.slot := CURATOR_STORAGE_LOCATION
        }
    }
}
