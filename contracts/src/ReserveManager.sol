// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ICascadeBackstop} from "./interfaces/ICascadeBackstop.sol";
import {ICuratorModule} from "./interfaces/ICuratorModule.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IReserveLossAbsorber} from "./interfaces/IReserveLossAbsorber.sol";
import {IReserveLossGovernor, IReserveLossTimelock} from "./interfaces/IReserveLossGovernance.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IsUSDfr} from "./interfaces/IsUSDfr.sol";
import {LossEventIds} from "./libraries/LossEventIds.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ReserveManager — mainnet-v1 USDC treasury
/// @notice Custodies canonical USDC and records conservatively marked deployed principal.
/// @dev Mainnet v1 intentionally has no generic stable registry, reserve instrument, or DSRA.
///      Unexpected direct USDC transfers are donations and do not increase reported backing,
///      except when governance attributes physical surplus to a previously written-down custody
///      incident under that arm's immutable recovery ceiling.
contract ReserveManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IReserveManager
{
    using SafeERC20 for IERC20;

    uint256 private constant USDC_SCALE = 1e12;

    /// @custom:storage-location erc7201:forestroad.storage.ReserveManager
    struct ReserveStorage {
        IERC20 usdcToken;
        uint256 idleUSDCUnits;
        uint256 totalDeployedPrincipal;
        mapping(uint256 facilityId => uint256) deployed;
        // Deprecated C-01 v1 hook. Reserved forever for upgrade-layout compatibility.
        IReserveLossAbsorber lossAbsorber;
        // C-01 remediation tail: the independent supply/backing source and the governance-opened
        // custody-incident state. Facility ids occupy the lower uint256 half; incident ids the upper.
        IMintRedeemController lossController;
        uint256 activeReserveLossIncidentId;
        bytes32 activeReserveLossEvidenceHash;
        uint256 reserveDeficit;
        mapping(uint256 incidentId => bool) reserveLossIncidentUsed;
        // C-01 ADR-0033 append-only orchestration tail.
        ICuratorModule lossCurator;
        ICascadeBackstop lossBackstop;
        IsUSDfr lossVault;
        IERC20 lossUSDfr;
        address lossGovernor;
        address lossTimelock;
        uint256 recognizedBackingReduction;
        uint256 recognizedSurplusAbsorbed;
        uint256 recognizedSupplyReduction;
        uint256 reserveLossPreArmExpiry;
        bytes32 reserveLossPreArmEvidenceHash;
        bytes32 reserveLossPreArmTimingHash;
        bool reserveLossPreArmDegraded;
        bool guardianReserveLossArmsEnabled;
        // Deprecated pre-arm fields above remain reserved forever. The persistent state machine
        // is append-only so an upgrade cannot reinterpret an expiry/timing latch as an arm id.
        uint256 nextReserveLossArmId;
        uint256 activeReserveLossArmId;
        bytes32 activeReserveLossArmEvidenceHash;
        mapping(uint256 armId => uint256 nativeUnits) reserveLossRecoveryCapacityUnits;
        // G3: append-only conservative marks on deployed facility principal.
        // Each facility mark is bounded by its live face, so the aggregate can never exceed
        // totalDeployedPrincipal and the checked subtraction in `_backingValue` cannot underflow.
        uint256 totalPrincipalImpairment;
        mapping(uint256 facilityId => uint256) principalImpairment;
        // ADR-0034 Y-bis compatibility tail. This ledger is independent of the custody-loss
        // arm state machine and is consumed only by the wired loss absorber.
        uint256 exitPrepaidAbsorption;
    }

    bytes32 private constant RESERVE_STORAGE_LOCATION =
        0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the reserve roles and canonical six-decimal USDC custody token.
    function initialize(address admin, address reserveAdmin, address guardian, address upgrader, address usdc_)
        external
        initializer
    {
        if (
            admin == address(0) || reserveAdmin == address(0) || guardian == address(0) || upgrader == address(0)
                || usdc_ == address(0)
        ) revert ReserveManager_ZeroAddress();
        uint8 decimals = IERC20Metadata(usdc_).decimals();
        if (decimals != 6) revert ReserveManager_InvalidUSDCDecimals(decimals);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.RESERVE_ADMIN_ROLE, reserveAdmin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        ReserveStorage storage $ = _storage();
        $.usdcToken = IERC20(usdc_);
        $.guardianReserveLossArmsEnabled = true;
    }

    /// @inheritdoc IReserveManager
    function depositUSDC(address from, uint256 amount) external nonReentrant whenNotPaused returns (uint256 credited) {
        if (!hasRole(Roles.CONTROLLER_ROLE, msg.sender) && !hasRole(Roles.CREDIT_ROLE, msg.sender)) {
            revert ReserveManager_NotDepositor(msg.sender);
        }
        if (from == address(0)) revert ReserveManager_ZeroAddress();
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 beforeBalance = $.usdcToken.balanceOf(address(this));
        $.usdcToken.safeTransferFrom(from, address(this), amount);
        uint256 received = $.usdcToken.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ReserveManager_NoValueReceived();
        if (received != amount) revert ReserveManager_UnexpectedUSDCReceipt(amount, received);
        $.idleUSDCUnits += received;
        credited = _normalize(received);
        emit USDCDeposited(from, amount, credited);
    }

    /// @inheritdoc IReserveManager
    function releaseUSDC(address to, uint256 amount)
        external
        onlyRole(Roles.CONTROLLER_ROLE)
        nonReentrant
        whenNotPaused
    {
        _release(to, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev The lock is derived directly from the same canonical balance, so observation is
    ///      reversible and permissionless without giving the caller authority to create state.
    function reconcileIdleUSDC() external nonReentrant returns (uint256 shortfall) {
        ReserveStorage storage $ = _storage();
        uint256 live = $.usdcToken.balanceOf(address(this));
        uint256 recorded = $.idleUSDCUnits;
        shortfall = recorded > live ? recorded - live : 0;
        emit IdleUSDCObserved(recorded, live, shortfall);
    }

    /// @notice Permanently disabled tombstone for the archived arbitrary idle-write-down path.
    /// @dev Archived arbitrary-loss entry point is intentionally disabled. New loss accounting
    ///      binds an arm, rederives the canonical shortfall and enforces the voted ceiling.
    function writeDownIdleUSDC(uint256) external pure {
        revert ReserveManager_LegacyPathDisabled();
    }

    /// @dev ABI tombstone for archived tests and pre-remediation operator tooling. The arbitrary
    ///      amount path is intentionally uncallable: all new loss accounting must bind an arm,
    ///      rederive the canonical shortfall and enforce the voted ceiling in `ratifyAndOpen`.
    /// @inheritdoc IReserveManager
    function observeIdleUSDC() external view returns (uint256 recorded, uint256 live, uint256 shortfall) {
        ReserveStorage storage $ = _storage();
        recorded = $.idleUSDCUnits;
        live = $.usdcToken.balanceOf(address(this));
        shortfall = recorded > live ? recorded - live : 0;
    }

    /// @notice Compatibility alias for the live custody limb retained by the merged cascade.
    function idleCustodyShortfall() public view returns (uint256) {
        uint256 shortfall = _liveShortfallUnits(_storage());
        return _normalize(shortfall);
    }

    /// @notice Conservative backing after subtracting the physically observed custody gap.
    function recognizedBackingValue() external view returns (uint256) {
        uint256 backing = _backingValue(_storage());
        uint256 shortfall = idleCustodyShortfall();
        return backing > shortfall ? backing - shortfall : 0;
    }

    /// @notice Compatibility binding retained for the ADR-0034 loss absorber. It is not a
    /// credit path; custody recovery remains exclusively arm-bound `creditRecoveredIdleUSDC`.
    function setLossAbsorber(address absorber) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool readable, address source) = _readStaticAddress(absorber, IReserveLossAbsorber.reserveLossSource.selector);
        if (!readable || source != address(this)) {
            revert ReserveManager_InvalidLossAbsorber(absorber);
        }
        ReserveStorage storage $ = _storage();
        address previous = address($.lossAbsorber);
        $.lossAbsorber = IReserveLossAbsorber(absorber);
        emit LossAbsorberSet(previous, absorber);
    }

    /// @notice Legacy incident opener retained for pre-arm audit harnesses. It does not move
    /// backing or credit custody; new production loss accounting must use armReserveLossFreeze
    /// followed by ratifyAndOpen.
    function openReserveLossIncident(uint256 incidentNonce, bytes32 evidenceHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 incidentId)
    {
        if (incidentNonce >= LossEventIds.CUSTODY_EVENT_NAMESPACE_START) {
            revert ReserveManager_InvalidIncidentNonce(incidentNonce);
        }
        ReserveStorage storage $ = _storage();
        if ($.activeReserveLossIncidentId != 0) {
            revert ReserveManager_IncidentAlreadyActive($.activeReserveLossIncidentId);
        }
        incidentId = LossEventIds.custodyEventId(incidentNonce);
        if ($.reserveLossIncidentUsed[incidentId]) revert ReserveManager_IncidentAlreadyUsed(incidentId);
        $.reserveLossIncidentUsed[incidentId] = true;
        $.activeReserveLossIncidentId = incidentId;
        $.activeReserveLossEvidenceHash = evidenceHash;
        emit ReserveLossIncidentOpened(incidentId, incidentNonce, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function closeReserveLossIncident(uint256 incidentId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) revert ReserveManager_NoActiveIncident();
        if (incidentId != active) revert ReserveManager_IncidentMismatch(active, incidentId);
        $.activeReserveLossIncidentId = 0;
        $.activeReserveLossEvidenceHash = bytes32(0);
        emit ReserveLossIncidentClosed(incidentId);
    }

    /// @inheritdoc IReserveManager
    function resolveReserveDeficit(bytes32 evidenceHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        uint256 recordedDeficit = $.reserveDeficit;
        if (recordedDeficit == 0) revert ReserveManager_NoReserveDeficit();
        if ($.activeReserveLossIncidentId != 0) {
            revert ReserveManager_IncidentAlreadyActive($.activeReserveLossIncidentId);
        }
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) revert ReserveManager_InvalidLossController(address(0));
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 observedDeficit = supply > backing ? supply - backing : 0;
        if (observedDeficit != 0) revert ReserveManager_DeficitStillExists(recordedDeficit, observedDeficit);
        $.reserveDeficit = 0;
        emit ReserveDeficitResolved(recordedDeficit, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function unrecordedUSDC() external view returns (uint256) {
        ReserveStorage storage $ = _storage();
        uint256 live = $.usdcToken.balanceOf(address(this));
        return live > $.idleUSDCUnits ? live - $.idleUSDCUnits : 0;
    }

    /// @dev ABI tombstone for the superseded pre-existing-surplus credit route. The merged
    ///      production path is exclusively `creditRecoveredIdleUSDC(armId,evidenceHash)`.
    /// @inheritdoc IReserveManager
    function setLossController(address controller_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        _requireModuleRebindAllowed($);
        if (controller_ == address(0) || controller_.code.length == 0) {
            revert ReserveManager_InvalidLossController(controller_);
        }
        address boundReserves;
        address usdfr_;
        try IMintRedeemController(controller_).modules() returns (address usdfr__, address, address reserves_) {
            usdfr_ = usdfr__;
            boundReserves = reserves_;
        } catch {
            revert ReserveManager_InvalidLossController(controller_);
        }
        if (boundReserves != address(this) || usdfr_ == address(0) || usdfr_.code.length == 0) {
            revert ReserveManager_InvalidLossController(controller_);
        }
        address previous = address($.lossController);
        $.lossController = IMintRedeemController(controller_);
        $.lossUSDfr = IERC20(usdfr_);
        emit LossControllerSet(previous, controller_);
    }

    /// @inheritdoc IReserveManager
    function setReserveLossModules(address curator, address backstop, address vault, address governor, address timelock)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveStorage storage $ = _storage();
        _requireModuleRebindAllowed($);
        if (address($.lossController) == address(0)) revert ReserveManager_InvalidLossController(address(0));
        if (curator == address(0) || curator.code.length == 0) revert ReserveManager_InvalidLossAbsorber(curator);
        if (backstop == address(0) || backstop.code.length == 0) revert ReserveManager_InvalidLossAbsorber(backstop);
        if (vault == address(0) || vault.code.length == 0) revert ReserveManager_InvalidLossAbsorber(vault);

        {
            address curatorUSDfr;
            address curatorVault;
            try ICuratorModule(curator).modules() returns (address usdfr_, address, address vault_) {
                curatorUSDfr = usdfr_;
                curatorVault = vault_;
            } catch {
                revert ReserveManager_InvalidLossAbsorber(curator);
            }
            (bool curatorReserveReadable, address curatorReserve) =
                _readStaticAddress(curator, ICuratorModule.reserveManager.selector);
            if (!curatorReserveReadable) revert ReserveManager_InvalidLossAbsorber(curator);
            (bool vaultAssetReadable, address vaultAsset) = _readStaticAddress(vault, IERC4626.asset.selector);
            if (!vaultAssetReadable) revert ReserveManager_InvalidLossAbsorber(vault);
            if (
                curatorUSDfr != address($.lossUSDfr) || curatorVault != vault || curatorReserve != address(this)
                    || vaultAsset != address($.lossUSDfr)
            ) revert ReserveManager_InvalidLossAbsorber(curator);
        }
        {
            bool supported;
            try IERC165(backstop).supportsInterface(type(ICascadeBackstop).interfaceId) returns (bool ok) {
                supported = ok;
            } catch {
                supported = false;
            }
            if (!supported) revert ReserveManager_InvalidLossAbsorber(backstop);
        }

        if (!_governanceTimingValid(governor, timelock)) {
            revert ReserveManager_InvalidGovernanceTiming(governor, timelock);
        }
        $.lossCurator = ICuratorModule(curator);
        $.lossBackstop = ICascadeBackstop(backstop);
        $.lossVault = IsUSDfr(vault);
        $.lossGovernor = governor;
        $.lossTimelock = timelock;
        emit ReserveLossModulesSet(curator, backstop, vault, governor, timelock);
    }

    /// @inheritdoc IReserveManager
    function armReserveLossFreeze(bytes32 evidenceHash)
        external
        onlyRole(Roles.GUARDIAN_ROLE)
        returns (uint256 armId, uint256 incidentId)
    {
        ReserveStorage storage $ = _storage();
        if (!$.guardianReserveLossArmsEnabled) revert ReserveManager_GuardianArmsDisabled();
        if ($.activeReserveLossArmId != 0) {
            revert ReserveManager_ArmAlreadyActive($.activeReserveLossArmId);
        }
        if ($.activeReserveLossIncidentId != 0) {
            revert ReserveManager_IncidentAlreadyActive($.activeReserveLossIncidentId);
        }
        armId = $.nextReserveLossArmId + 1;
        if (armId == 0 || armId >= LossEventIds.CUSTODY_EVENT_NAMESPACE_START) {
            revert ReserveManager_ArmIdExhausted();
        }
        incidentId = LossEventIds.custodyEventId(armId);
        assert(LossEventIds.isCustodyEvent(incidentId));
        $.nextReserveLossArmId = armId;
        $.activeReserveLossArmId = armId;
        $.activeReserveLossArmEvidenceHash = evidenceHash;
        emit ReserveLossArmed(armId, incidentId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function cancelAndDisable(uint256 expectedArmId, bytes32 evidenceHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        uint256 armId = _requireActiveArm($, expectedArmId);
        _requireInterlockReleasable($);
        _consumeArmAndDisable($);
        emit ReserveLossArmCancelled(armId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function setGuardianReserveLossArmsEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        $.guardianReserveLossArmsEnabled = enabled;
        emit GuardianReserveLossArmsEnabled(enabled);
    }

    /// @inheritdoc IReserveManager
    function ratifyAndOpen(uint256 expectedArmId, bytes32 evidenceHash, uint256 approvedMaxLoss)
        external
        nonReentrant
        returns (uint256 incidentId, uint256 actualLoss)
    {
        _requireReserveLossAdmin();
        ReserveStorage storage $ = _storage();
        uint256 armId = _requireActiveArm($, expectedArmId);
        bytes32 armedEvidenceHash = $.activeReserveLossArmEvidenceHash;
        if (evidenceHash != armedEvidenceHash) {
            revert ReserveManager_ArmEvidenceMismatch(armedEvidenceHash, evidenceHash);
        }
        uint256 shortfallUnits = _liveShortfallUnits($);
        if (shortfallUnits == 0) revert ReserveManager_ShortfallCured();
        actualLoss = _normalize(shortfallUnits);
        if (actualLoss > approvedMaxLoss) {
            revert ReserveManager_LossExceedsApproval(actualLoss, approvedMaxLoss);
        }

        incidentId = LossEventIds.custodyEventId(armId);
        assert(LossEventIds.isCustodyEvent(incidentId));
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) {
            if ($.reserveLossIncidentUsed[incidentId]) revert ReserveManager_IncidentAlreadyUsed(incidentId);
            $.reserveLossIncidentUsed[incidentId] = true;
            $.activeReserveLossIncidentId = incidentId;
            emit ReserveLossIncidentOpened(incidentId, armId, evidenceHash);
        } else if (active != incidentId) {
            revert ReserveManager_IncidentMismatch(active, incidentId);
        }
        $.activeReserveLossEvidenceHash = evidenceHash;
        $.reserveLossRecoveryCapacityUnits[armId] += shortfallUnits;

        _recognizeReserveLoss($, shortfallUnits, actualLoss);
        if ($.recognizedSupplyReduction != 0) _absorbRecognizedReserveLoss($, incidentId);
        emit IdleUSDCWrittenDown(actualLoss, _normalize($.idleUSDCUnits));
        emit ReserveLossRatified(armId, incidentId, approvedMaxLoss, actualLoss, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function creditRecoveredIdleUSDC(uint256 armId, bytes32 evidenceHash)
        external
        nonReentrant
        returns (uint256 credited)
    {
        _requireReserveLossAdmin();
        ReserveStorage storage $ = _storage();
        uint256 capacity = $.reserveLossRecoveryCapacityUnits[armId];
        uint256 units = _availableRecoveredUSDC($, armId);
        if (units == 0) revert ReserveManager_NoRecoveredUSDC(armId);
        $.idleUSDCUnits += units;
        $.reserveLossRecoveryCapacityUnits[armId] = capacity - units;
        credited = _normalize(units);
        emit RecoveredIdleUSDCCredited(armId, units, credited, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function finalizeAndDisable(uint256 expectedArmId, bytes32 evidenceHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        uint256 armId = _requireActiveArm($, expectedArmId);
        uint256 incidentId = LossEventIds.custodyEventId(armId);
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) revert ReserveManager_NoActiveIncident();
        if (incidentId != active) revert ReserveManager_IncidentMismatch(active, incidentId);
        if ($.recognizedSupplyReduction != 0) {
            revert ReserveManager_RecognizedLossOutstanding($.recognizedSupplyReduction);
        }
        uint256 liveShortfall = _liveShortfallUnits($);
        if (liveShortfall != 0) revert ReserveManager_LiveShortfallExists(liveShortfall);
        uint256 availableRecovery = _availableRecoveredUSDC($, armId);
        if (availableRecovery != 0) {
            revert ReserveManager_RecoveredUSDCNotCredited(armId, availableRecovery);
        }
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) revert ReserveManager_InvalidLossController(address(0));
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        uint256 observedDeficit = supply > backing ? supply - backing : 0;
        uint256 recordedDeficit = $.reserveDeficit;
        if (observedDeficit != 0) {
            revert ReserveManager_DeficitStillExists(recordedDeficit, observedDeficit);
        }
        if (recordedDeficit != 0) {
            $.reserveDeficit = 0;
            emit ReserveDeficitResolved(recordedDeficit, evidenceHash);
        }
        $.activeReserveLossIncidentId = 0;
        $.activeReserveLossEvidenceHash = bytes32(0);
        emit ReserveLossIncidentClosed(incidentId);
        _consumeArmAndDisable($);
        emit ReserveLossArmFinalized(armId, incidentId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function recordDeployment(uint256 facilityId, address to, uint256 usdcAmount)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert ReserveManager_ZeroAddress();
        if (to == address(this)) revert ReserveManager_SelfDeployment();
        if (usdcAmount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        // MA-1/R4-01: a live custody shortfall freezes the facility-funding USDC out-door.
        _requireIdleFullyCustodied($);
        uint256 value = _normalize(usdcAmount);
        uint256 idleValue = _normalize($.idleUSDCUnits);
        if (value > idleValue) revert ReserveManager_InsufficientIdleValue(value, idleValue);
        $.idleUSDCUnits -= usdcAmount;
        $.deployed[facilityId] += value;
        $.totalDeployedPrincipal += value;
        $.usdcToken.safeTransfer(to, usdcAmount);
        emit PrincipalDeployed(facilityId, value);
    }

    /// @inheritdoc IReserveManager
    function recordFeeCapitalization(uint256 facilityId, uint256 amount)
        external
        onlyRole(Roles.CREDIT_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        uint256 units = _denormalize(amount);
        if (_normalize(units) != amount) revert ReserveManager_ValueNotUSDCExact(amount);
        ReserveStorage storage $ = _storage();
        uint256 idleValue = _normalize($.idleUSDCUnits);
        if (amount > idleValue) revert ReserveManager_InsufficientIdleValue(amount, idleValue);
        // The borrower owes the full face amount while the OID cash stays in the treasury.
        // Both are distinct assets after closing: retained USDC and additional receivable.
        // Keeping the fee in idle is what backs the matching protocol-fee USDfr mint.
        $.deployed[facilityId] += amount;
        $.totalDeployedPrincipal += amount;
        emit FeeCapitalized(facilityId, amount);
    }

    /// @inheritdoc IReserveManager
    function recordPayment(uint256 facilityId, address payer, uint256 usdcAmount, uint256 principal)
        external
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 receivedValue)
    {
        if (payer == address(0)) revert ReserveManager_ZeroAddress();
        if (usdcAmount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 beforeBalance = $.usdcToken.balanceOf(address(this));
        $.usdcToken.safeTransferFrom(payer, address(this), usdcAmount);
        uint256 received = $.usdcToken.balanceOf(address(this)) - beforeBalance;
        if (received != usdcAmount) revert ReserveManager_UnexpectedUSDCReceipt(usdcAmount, received);
        receivedValue = _normalize(received);
        if (principal > receivedValue) revert ReserveManager_PrincipalExceedsPayment(principal, receivedValue);
        uint256 deployed = $.deployed[facilityId];
        if (principal > deployed) {
            revert ReserveManager_InsufficientDeployedPrincipal(facilityId, principal, deployed);
        }
        $.idleUSDCUnits += received;
        if (principal != 0) {
            uint256 remainingFace = deployed - principal;
            $.deployed[facilityId] = remainingFace;
            $.totalDeployedPrincipal -= principal;
            // H-1: cash collection does not prove that a governance-adjudicated impairment
            // was recovered. Preserve the mark unless the smaller remaining face can no longer
            // support it; only that arithmetically unavoidable excess is released. Treating
            // every repayment dollar as recovery made backing depend on repayment/write-down
            // ordering and could silently reopen par exits against the still-impaired claim.
            _clampImpairmentToRemainingFace($, facilityId, remainingFace);
        }
        emit PaymentReceived(facilityId, payer, usdcAmount, principal);
    }

    /// @inheritdoc IReserveManager
    function recordPrincipalWritedown(uint256 facilityId, uint256 amount) external onlyRole(Roles.CREDIT_ROLE) {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 deployed = $.deployed[facilityId];
        if (amount > deployed) {
            revert ReserveManager_InsufficientDeployedPrincipal(facilityId, amount, deployed);
        }
        $.deployed[facilityId] = deployed - amount;
        $.totalDeployedPrincipal -= amount;
        // A write-down is the realization of loss, so the mark already carried against that
        // loss must be consumed to avoid counting the same dollar twice.
        _realizeImpairmentOnWriteDown($, facilityId, amount);
        emit PrincipalWrittenDown(facilityId, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev This is a valuation transition, not a cascade transition: it moves no value and
    ///      burns no claims. Keeping it separate ensures an honest conservative mark is never
    ///      conditional on the three loss layers having enough immediately burnable capital.
    function recognizePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        if (evidenceHash == bytes32(0)) revert ReserveManager_ZeroEvidenceHash();
        ReserveStorage storage $ = _storage();
        uint256 recognized = $.principalImpairment[facilityId];
        uint256 face = $.deployed[facilityId];
        if (amount > face - recognized) {
            revert ReserveManager_ImpairmentExceedsFace(facilityId, amount, face - recognized);
        }
        uint256 facilityImpairment = recognized + amount;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment + amount;
        $.totalPrincipalImpairment = total;
        emit PrincipalImpairmentRecognized(
            facilityId, amount, facilityImpairment, total, _backingValue($), evidenceHash
        );
    }

    /// @inheritdoc IReserveManager
    function releasePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        if (evidenceHash == bytes32(0)) revert ReserveManager_ZeroEvidenceHash();
        ReserveStorage storage $ = _storage();
        uint256 recognized = $.principalImpairment[facilityId];
        if (amount > recognized) {
            revert ReserveManager_ImpairmentReleaseExceedsRecognized(facilityId, amount, recognized);
        }
        uint256 facilityImpairment = recognized - amount;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment - amount;
        $.totalPrincipalImpairment = total;
        emit PrincipalImpairmentReleased(facilityId, amount, facilityImpairment, total, evidenceHash);
    }

    /// @notice Pauses routine reserve deposits, releases, deployments, and payments.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Resumes routine reserve deposits, releases, deployments, and payments.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IReserveManager
    function idleReserve() external view returns (uint256) {
        return _normalize(_storage().idleUSDCUnits);
    }

    /// @inheritdoc IReserveManager
    function idleUSDC() external view returns (uint256) {
        return _storage().idleUSDCUnits;
    }

    /// @inheritdoc IReserveManager
    function deployedPrincipal() external view returns (uint256) {
        return _storage().totalDeployedPrincipal;
    }

    /// @inheritdoc IReserveManager
    function totalBackingValue() external view returns (uint256) {
        return _backingValue(_storage());
    }

    /// @inheritdoc IReserveManager
    function totalPrincipalImpairment() external view returns (uint256) {
        return _storage().totalPrincipalImpairment;
    }

    /// @inheritdoc IReserveManager
    function principalImpairmentOf(uint256 facilityId) external view returns (uint256) {
        return _storage().principalImpairment[facilityId];
    }

    /// @inheritdoc IReserveManager
    function deployedTo(uint256 facilityId) external view returns (uint256) {
        return _storage().deployed[facilityId];
    }

    /// @notice Pulls exact USDC from a recapitalizing funder and records only what arrived.
    ///         This cannot credit pre-existing surplus; that remains arm-bound recovery.
    function recapitalize(uint256 amount) external nonReentrant returns (uint256 credited) {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 beforeBalance = $.usdcToken.balanceOf(address(this));
        $.usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = $.usdcToken.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ReserveManager_NoValueReceived();
        if (received != amount) revert ReserveManager_UnexpectedUSDCReceipt(amount, received);
        $.idleUSDCUnits += received;
        credited = _normalize(received);
        emit Recapitalized(msg.sender, received, credited, _backingValue($), $.reserveDeficit);
    }

    /// @notice Compatibility view for the historical exit-prepayment cascade ledger.
    function exitPrepaidAbsorption() external view returns (uint256) {
        return _storage().exitPrepaidAbsorption;
    }

    /// @inheritdoc IReserveManager
    function recordExitPrepayment(uint256 amount) external {
        ReserveStorage storage $ = _storage();
        if (msg.sender != address($.lossAbsorber)) revert ReserveManager_NotLossAbsorber(msg.sender);
        if (amount == 0) revert ReserveManager_ZeroAmount();
        uint256 outstanding = $.exitPrepaidAbsorption + amount;
        $.exitPrepaidAbsorption = outstanding;
        emit ExitPrepaymentRecorded(amount, outstanding);
    }

    /// @inheritdoc IReserveManager
    function consumeExitPrepayment(uint256 facilityId, uint256 loss) external returns (uint256 used) {
        ReserveStorage storage $ = _storage();
        if (msg.sender != address($.lossAbsorber)) revert ReserveManager_NotLossAbsorber(msg.sender);
        uint256 prepaid = $.exitPrepaidAbsorption;
        if (prepaid == 0) return 0;
        uint256 releasable = $.principalImpairment[facilityId];
        if (releasable > loss) releasable = loss;
        used = prepaid < releasable ? prepaid : releasable;
        if (used == 0) return 0;
        uint256 outstanding = prepaid - used;
        $.exitPrepaidAbsorption = outstanding;
        emit ExitPrepaymentConsumed(facilityId, used, outstanding);
    }

    /// @inheritdoc IReserveManager
    function usdc() external view returns (address) {
        return address(_storage().usdcToken);
    }

    /// @inheritdoc IReserveManager
    function lossAbsorber() external view returns (address) {
        return address(_storage().lossAbsorber);
    }

    /// @inheritdoc IReserveManager
    function lossController() external view returns (address) {
        return address(_storage().lossController);
    }

    /// @inheritdoc IReserveManager
    function reserveLossModules()
        external
        view
        returns (address curator, address backstop, address vault, address governor, address timelock)
    {
        ReserveStorage storage $ = _storage();
        return (address($.lossCurator), address($.lossBackstop), address($.lossVault), $.lossGovernor, $.lossTimelock);
    }

    /// @inheritdoc IReserveManager
    function activeReserveLossIncident() external view returns (uint256 incidentId, bytes32 evidenceHash) {
        ReserveStorage storage $ = _storage();
        return ($.activeReserveLossIncidentId, $.activeReserveLossEvidenceHash);
    }

    /// @inheritdoc IReserveManager
    function reserveLossIncidentUsed(uint256 incidentId) external view returns (bool) {
        return _storage().reserveLossIncidentUsed[incidentId];
    }

    /// @inheritdoc IReserveManager
    function reserveDeficit() external view returns (uint256) {
        return _storage().reserveDeficit;
    }

    /// @inheritdoc IReserveManager
    function recognizedReserveLoss()
        external
        view
        returns (uint256 backingReduction, uint256 surplusAbsorbed, uint256 supplyReductionRequired)
    {
        ReserveStorage storage $ = _storage();
        return ($.recognizedBackingReduction, $.recognizedSurplusAbsorbed, $.recognizedSupplyReduction);
    }

    /// @inheritdoc IReserveManager
    function reserveLossArm()
        external
        view
        returns (uint256 armId, uint256 incidentId, bytes32 evidenceHash, bool armsEnabled)
    {
        ReserveStorage storage $ = _storage();
        armId = $.activeReserveLossArmId;
        incidentId = armId == 0 ? 0 : LossEventIds.custodyEventId(armId);
        return (armId, incidentId, $.activeReserveLossArmEvidenceHash, $.guardianReserveLossArmsEnabled);
    }

    /// @inheritdoc IReserveManager
    function reserveLossRecoveryCapacity(uint256 armId) external view returns (uint256 nativeUnits) {
        return _storage().reserveLossRecoveryCapacityUnits[armId];
    }

    /// @inheritdoc IReserveManager
    function reserveLossExitsLocked() external view returns (bool) {
        return _reserveLossExitsLocked(_storage());
    }

    /// @inheritdoc IReserveManager
    function curatorWithdrawalsLocked() external view returns (bool) {
        return _reserveLossExitsLocked(_storage());
    }

    /// @notice Historical aggregate latch retained as a read-only compatibility surface.
    function custodyLossUnabsorbed() external view returns (bool) {
        ReserveStorage storage $ = _storage();
        if ($.activeReserveLossArmId != 0 || $.activeReserveLossIncidentId != 0) return true;
        if ($.reserveDeficit != 0 || $.recognizedSupplyReduction != 0 || $.totalPrincipalImpairment != 0) {
            return true;
        }
        if (_liveShortfallUnits($) != 0) return true;
        IMintRedeemController controller = $.lossController;
        // Preserve W7's independently mutation-pinned fail-closed compatibility limb. The
        // arm-bound custody workflow does not make a missing ADR-0034 absorber safe.
        if (address(controller) == address(0) || address($.lossAbsorber) == address(0)) return true;
        return controller.totalUSDfr() > controller.backingValue();
    }

    function _reserveLossExitsLocked(ReserveStorage storage $) private view returns (bool) {
        if (
            $.activeReserveLossArmId != 0 || $.activeReserveLossIncidentId != 0 || $.recognizedSupplyReduction != 0
                || $.reserveDeficit != 0 || _liveShortfallUnits($) != 0
        ) return true;
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0) || address($.lossAbsorber) == address(0)) return true;
        uint256 supply;
        uint256 backing;
        try controller.totalUSDfr() returns (uint256 supply_) {
            supply = supply_;
        } catch {
            return true;
        }
        try controller.backingValue() returns (uint256 backing_) {
            backing = backing_;
        } catch {
            return true;
        }
        return supply > backing;
    }

    /// @inheritdoc IReserveManager
    function normalizeUSDC(uint256 amount) external pure returns (uint256) {
        return _normalize(amount);
    }

    /// @inheritdoc IReserveManager
    function denormalizeUSDC(uint256 value) external pure returns (uint256) {
        uint256 amount = _denormalize(value);
        if (_normalize(amount) != value) revert ReserveManager_ValueNotUSDCExact(value);
        return amount;
    }

    function _release(address to, uint256 amount) private {
        if (to == address(0)) revert ReserveManager_ZeroAddress();
        if (to == address(this)) revert ReserveManager_SelfDeployment();
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        // R4-01: never pay an exit from a reserve whose recorded idle ledger is observably short.
        _requireIdleFullyCustodied($);
        uint256 value = _normalize(amount);
        uint256 idleValue = _normalize($.idleUSDCUnits);
        if (value > idleValue) revert ReserveManager_InsufficientIdleValue(value, idleValue);
        $.idleUSDCUnits -= amount;
        $.usdcToken.safeTransfer(to, amount);
        emit USDCReleased(to, amount);
    }

    function _recognizeReserveLoss(ReserveStorage storage $, uint256 nativeUnits, uint256 backingReduction) private {
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0)) revert ReserveManager_InvalidLossController(address(0));
        uint256 supplyBefore = controller.totalUSDfr();
        uint256 backingBefore = controller.backingValue();
        if (backingReduction > backingBefore) {
            revert ReserveManager_LossAllocationMismatch(0, 0, backingReduction, backingBefore);
        }

        uint256 surplusBefore = backingBefore > supplyBefore ? backingBefore - supplyBefore : 0;
        uint256 surplusAbsorbed = backingReduction < surplusBefore ? backingReduction : surplusBefore;
        uint256 supplyReductionRequired = backingReduction - surplusAbsorbed;

        // Recognition lowers backing first. Every subsequent burn is checked as a precise,
        // non-worsening reduction of the now-visible deficit by MintRedeemController.
        $.idleUSDCUnits -= nativeUnits;
        emit ReserveLossRecognized(
            $.activeReserveLossIncidentId, backingReduction, surplusAbsorbed, supplyReductionRequired
        );

        if (supplyReductionRequired == 0) {
            IReserveLossAbsorber.ReserveLossAllocation memory allocation;
            allocation.surplusAbsorbed = surplusAbsorbed;
            _emitReserveLossAllocated($.activeReserveLossIncidentId, backingReduction, allocation);
            return;
        }
        $.recognizedBackingReduction += backingReduction;
        $.recognizedSurplusAbsorbed += surplusAbsorbed;
        $.recognizedSupplyReduction += supplyReductionRequired;
    }

    function _absorbRecognizedReserveLoss(ReserveStorage storage $, uint256 incidentId) private {
        if (!LossEventIds.isCustodyEvent(incidentId)) {
            revert ReserveManager_InvalidReserveLossIncident(incidentId);
        }
        uint256 active = $.activeReserveLossIncidentId;
        if (active == 0) revert ReserveManager_NoActiveIncident();
        if (incidentId != active) revert ReserveManager_IncidentMismatch(active, incidentId);

        uint256 requiredSupplyReduction = $.recognizedSupplyReduction;
        if (requiredSupplyReduction == 0) revert ReserveManager_NoRecognizedReserveLoss();
        IMintRedeemController controller = $.lossController;
        if (
            address($.lossCurator) == address(0) || address($.lossBackstop) == address(0)
                || address($.lossVault) == address(0) || address($.lossUSDfr) == address(0)
        ) revert ReserveManager_InvalidLossAbsorber(address(0));
        if (address(controller) == address(0)) revert ReserveManager_InvalidLossController(address(0));

        $.lossVault.accrueFees();
        uint256 supplyBefore = controller.totalUSDfr();
        // Recognition has already lowered backing by `recognizedBackingReduction`. Reconstruct
        // the pre-loss level so the standing valuation hole and any previously latched cascade
        // residual are carried through the new delta rather than charged or latched twice.
        uint256 backingAfterRecognition = controller.backingValue();
        uint256 backingBeforeLoss = backingAfterRecognition + $.recognizedBackingReduction;
        uint256 deficitBefore = supplyBefore > backingBeforeLoss ? supplyBefore - backingBeforeLoss : 0;
        IReserveLossAbsorber.ReserveLossAllocation memory allocation;
        uint256 residual;
        (allocation.curatorAbsorbed, allocation.backstopCovered, residual) =
            _drawJuniorReserveLoss($.lossCurator, $.lossBackstop, $.lossUSDfr, incidentId, requiredSupplyReduction);

        uint256 juniorBurn = allocation.curatorAbsorbed + allocation.backstopCovered;
        if (juniorBurn != 0) controller.burnLoss(address(this), juniorBurn);

        if (residual != 0) {
            uint256 vaultAssets = $.lossVault.totalAssets();
            allocation.seniorBurned = residual < vaultAssets ? residual : vaultAssets;
            if (allocation.seniorBurned != 0) {
                controller.burnLoss(address($.lossVault), allocation.seniorBurned);
                residual -= allocation.seniorBurned;
            }
        }
        allocation.residualDeficit = residual;
        allocation.surplusAbsorbed = $.recognizedSurplusAbsorbed;

        _finalizeReserveLoss($, incidentId, requiredSupplyReduction, supplyBefore, deficitBefore, allocation);
    }

    function _finalizeReserveLoss(
        ReserveStorage storage $,
        uint256 incidentId,
        uint256 requiredSupplyReduction,
        uint256 supplyBefore,
        uint256 deficitBefore,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private {
        uint256 observedDeficit =
            _verifyReserveLoss($, requiredSupplyReduction, supplyBefore, deficitBefore, allocation);
        uint256 backingReduction = $.recognizedBackingReduction;
        $.recognizedBackingReduction = 0;
        $.recognizedSurplusAbsorbed = 0;
        $.recognizedSupplyReduction = 0;

        // Only the portion of the pre-loss hole that was already a cascade residual is carried
        // into the latch. A standing valuation mark is an output/price constraint, not a new
        // custody shortfall; the current loss has already been offered unconditionally above.
        uint256 previousDeficit = $.reserveDeficit;
        uint256 carriedValuationDeficit = deficitBefore > previousDeficit ? deficitBefore - previousDeficit : 0;
        uint256 nextDeficit = observedDeficit - carriedValuationDeficit;
        if (nextDeficit != previousDeficit) {
            $.reserveDeficit = nextDeficit;
            emit ReserveDeficitUpdated(incidentId, previousDeficit, nextDeficit);
        }
        _emitReserveLossAllocated(incidentId, backingReduction, allocation);
    }

    function _verifyReserveLoss(
        ReserveStorage storage $,
        uint256 requiredSupplyReduction,
        uint256 supplyBefore,
        uint256 deficitBefore,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private view returns (uint256 observedDeficit) {
        IMintRedeemController controller = $.lossController;
        uint256 supplyAfter = controller.totalUSDfr();
        uint256 reportedBurn = allocation.curatorAbsorbed + allocation.backstopCovered + allocation.seniorBurned;
        uint256 observedBurn = supplyAfter > supplyBefore ? 0 : supplyBefore - supplyAfter;
        if (reportedBurn > requiredSupplyReduction || observedBurn != reportedBurn) {
            revert ReserveManager_LossAbsorberContractViolated(reportedBurn, observedBurn);
        }
        uint256 expectedAccounted = $.recognizedBackingReduction - $.recognizedSurplusAbsorbed;
        uint256 reportedAccounted = reportedBurn + allocation.residualDeficit;
        if (expectedAccounted != requiredSupplyReduction || reportedAccounted != expectedAccounted) {
            revert ReserveManager_LossAllocationMismatch(
                $.recognizedSurplusAbsorbed, allocation.surplusAbsorbed, expectedAccounted, reportedAccounted
            );
        }
        uint256 backingAfter = controller.backingValue();
        observedDeficit = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
        uint256 expectedDeficit = deficitBefore + requiredSupplyReduction;
        expectedDeficit = expectedDeficit > reportedBurn ? expectedDeficit - reportedBurn : 0;
        if (observedDeficit != expectedDeficit) {
            revert ReserveManager_PostLossDeficitMismatch(expectedDeficit, observedDeficit);
        }
    }

    function _drawJuniorReserveLoss(
        ICuratorModule curator,
        ICascadeBackstop backstop,
        IERC20 usdfr,
        uint256 incidentId,
        uint256 requiredSupplyReduction
    ) private returns (uint256 curatorAbsorbed, uint256 backstopCovered, uint256 residual) {
        uint256 balanceBefore = usdfr.balanceOf(address(this));
        (curatorAbsorbed, residual) = curator.absorbGlobalLoss(requiredSupplyReduction);
        if (curatorAbsorbed > requiredSupplyReduction || residual != requiredSupplyReduction - curatorAbsorbed) {
            revert ReserveManager_LossAllocationMismatch(0, 0, requiredSupplyReduction, curatorAbsorbed + residual);
        }
        uint256 balanceAfter = usdfr.balanceOf(address(this));
        uint256 received = balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore;
        if (received != curatorAbsorbed) {
            revert ReserveManager_LossAbsorberContractViolated(curatorAbsorbed, received);
        }

        if (residual != 0) {
            balanceBefore = balanceAfter;
            backstopCovered = backstop.coverShortfall(incidentId, residual);
            balanceAfter = usdfr.balanceOf(address(this));
            received = balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore;
            if (backstopCovered > residual || received != backstopCovered) {
                revert ReserveManager_LossAbsorberContractViolated(backstopCovered, received);
            }
            residual -= backstopCovered;
        }
    }

    function _requireReserveLossAdmin() private view {
        if (!hasRole(Roles.RESERVE_ADMIN_ROLE, msg.sender)) {
            revert ReserveManager_ReserveLossCallerNotAdmin(msg.sender);
        }
    }

    function _requireInterlockReleasable(ReserveStorage storage $) private view {
        if (
            $.activeReserveLossIncidentId != 0 || $.recognizedSupplyReduction != 0 || $.reserveDeficit != 0
                || _liveShortfallUnits($) != 0
        ) revert ReserveManager_InterlockReleaseForbidden();
        IMintRedeemController controller = $.lossController;
        if (address(controller) == address(0) || controller.totalUSDfr() > controller.backingValue()) {
            revert ReserveManager_InterlockReleaseForbidden();
        }
    }

    function _requireModuleRebindAllowed(ReserveStorage storage $) private view {
        if (
            $.activeReserveLossArmId != 0 || $.activeReserveLossIncidentId != 0 || $.recognizedSupplyReduction != 0
                || $.reserveDeficit != 0 || _liveShortfallUnits($) != 0
        ) revert ReserveManager_ModuleRebindForbidden();
        IMintRedeemController controller = $.lossController;
        if (address(controller) != address(0) && controller.totalUSDfr() > controller.backingValue()) {
            revert ReserveManager_ModuleRebindForbidden();
        }
    }

    function _requireActiveArm(ReserveStorage storage $, uint256 expectedArmId) private view returns (uint256 armId) {
        armId = $.activeReserveLossArmId;
        if (armId == 0) revert ReserveManager_NoActiveArm();
        if (expectedArmId != armId) revert ReserveManager_ArmMismatch(armId, expectedArmId);
    }

    function _consumeArmAndDisable(ReserveStorage storage $) private {
        $.activeReserveLossArmId = 0;
        $.activeReserveLossArmEvidenceHash = bytes32(0);
        if ($.guardianReserveLossArmsEnabled) {
            $.guardianReserveLossArmsEnabled = false;
            emit GuardianReserveLossArmsEnabled(false);
        }
    }

    function _availableRecoveredUSDC(ReserveStorage storage $, uint256 armId) private view returns (uint256 units) {
        uint256 capacity = $.reserveLossRecoveryCapacityUnits[armId];
        uint256 live = $.usdcToken.balanceOf(address(this));
        uint256 recorded = $.idleUSDCUnits;
        if (capacity == 0 || live <= recorded) return 0;
        uint256 surplus = live - recorded;
        return surplus < capacity ? surplus : capacity;
    }

    /// @dev A realized write-down consumes the corresponding conservative mark so the same loss
    ///      is not counted once in face and again in the valuation adjustment.
    function _realizeImpairmentOnWriteDown(ReserveStorage storage $, uint256 facilityId, uint256 writeDown) private {
        uint256 recognized = $.principalImpairment[facilityId];
        if (recognized == 0) return;
        uint256 consumed = writeDown < recognized ? writeDown : recognized;
        _consumeImpairment($, facilityId, recognized, consumed);
    }

    /// @dev Cash repayment is not evidence that a particular impairment recovered. It may only
    ///      release the portion that would otherwise exceed the facility's remaining face.
    function _clampImpairmentToRemainingFace(ReserveStorage storage $, uint256 facilityId, uint256 remainingFace)
        private
    {
        uint256 recognized = $.principalImpairment[facilityId];
        if (recognized <= remainingFace) return;
        _consumeImpairment($, facilityId, recognized, recognized - remainingFace);
    }

    function _consumeImpairment(ReserveStorage storage $, uint256 facilityId, uint256 recognized, uint256 consumed)
        private
    {
        uint256 facilityImpairment = recognized - consumed;
        $.principalImpairment[facilityId] = facilityImpairment;
        uint256 total = $.totalPrincipalImpairment - consumed;
        $.totalPrincipalImpairment = total;
        emit PrincipalImpairmentRealized(facilityId, consumed, facilityImpairment, total);
    }

    function _backingValue(ReserveStorage storage $) private view returns (uint256) {
        return _normalize($.idleUSDCUnits) + ($.totalDeployedPrincipal - $.totalPrincipalImpairment);
    }

    function _liveShortfallUnits(ReserveStorage storage $) private view returns (uint256) {
        uint256 live = $.usdcToken.balanceOf(address(this));
        return $.idleUSDCUnits > live ? $.idleUSDCUnits - live : 0;
    }

    /// @dev Shared fail-closed predicate for every USDC out-door. Restoring custody or completing
    ///      the arm-bound write-down clears the objective condition without a separate latch.
    function _requireIdleFullyCustodied(ReserveStorage storage $) private view {
        uint256 recorded = $.idleUSDCUnits;
        uint256 live = $.usdcToken.balanceOf(address(this));
        if (recorded > live) revert ReserveManager_IdleCustodyShortfall(recorded, live);
    }

    /// @dev The caller needs only a validity bit. The earlier merge returned four additional
    ///      values which no caller consumed, duplicating ABI decoders for every getter inside an
    ///      EIP-170-constrained implementation. Keep the same six live checks through one strict
    ///      word reader; compare CLOCK_MODE's complete canonical ABI encoding so a permissive
    ///      fallback cannot satisfy the string call with a zero word.
    function _governanceTimingValid(address governor, address timelock) private view returns (bool) {
        (bool ok, uint256 word) = _readStaticWord(governor, IReserveLossGovernor.timelock.selector);
        if (!ok || address(uint160(word)) != timelock) return false;
        (ok, word) = _readStaticWord(governor, IReserveLossGovernor.clock.selector);
        if (!ok || word != block.timestamp) return false;

        (bool modeOk, bytes memory modeData) =
            governor.staticcall(abi.encodeWithSelector(IReserveLossGovernor.CLOCK_MODE.selector));
        if (!modeOk || keccak256(modeData) != keccak256(abi.encode("mode=timestamp"))) return false;

        (ok,) = _readStaticWord(governor, IReserveLossGovernor.votingDelay.selector);
        if (!ok) return false;
        (ok,) = _readStaticWord(governor, IReserveLossGovernor.votingPeriod.selector);
        if (!ok) return false;
        (ok,) = _readStaticWord(timelock, IReserveLossTimelock.getMinDelay.selector);
        return ok;
    }

    function _readStaticWord(address target, bytes4 selector) private view returns (bool ok, uint256 word) {
        if (target == address(0) || target.code.length == 0) return (false, 0);
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }

    function _readStaticAddress(address target, bytes4 selector) private view returns (bool ok, address value) {
        uint256 word;
        (ok, word) = _readStaticWord(target, selector);
        if (!ok || word > type(uint160).max) return (false, address(0));
        value = address(uint160(word));
    }

    function _emitReserveLossAllocated(
        uint256 incidentId,
        uint256 backingReduction,
        IReserveLossAbsorber.ReserveLossAllocation memory allocation
    ) private {
        emit ReserveLossAllocated(
            incidentId,
            backingReduction,
            allocation.surplusAbsorbed,
            allocation.curatorAbsorbed,
            allocation.backstopCovered,
            allocation.seniorBurned,
            allocation.residualDeficit
        );
    }

    function _normalize(uint256 amount) private pure returns (uint256) {
        return amount * USDC_SCALE;
    }

    function _denormalize(uint256 value) private pure returns (uint256) {
        return value / USDC_SCALE;
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (ReserveStorage storage $) {
        assembly {
            $.slot := RESERVE_STORAGE_LOCATION
        }
    }
}
