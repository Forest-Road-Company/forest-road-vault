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
import {ReserveCreditLib} from "./libraries/ReserveCreditLib.sol";
import {ReserveCascadeLib} from "./libraries/ReserveCascadeLib.sol";
import {ReserveIncidentLib} from "./libraries/ReserveIncidentLib.sol";
import {ReserveStorageLib} from "./libraries/ReserveStorageLib.sol";
import {ReserveWiringLib} from "./libraries/ReserveWiringLib.sol";
import {ReserveAccrualStorageLib} from "./libraries/ReserveAccrualStorageLib.sol";
import {ReserveMigrationLib} from "./libraries/ReserveMigrationLib.sol";
import {IAccrualMigration} from "./interfaces/IAccrualMigration.sol";
import {ReserveAccrualLib} from "./libraries/ReserveAccrualLib.sol";
import {ReserveAccrualCreditLib} from "./libraries/ReserveAccrualCreditLib.sol";
import {ReserveAccrualServiceLib} from "./libraries/ReserveAccrualServiceLib.sol";
import {ReserveAccrualViewsLib} from "./libraries/ReserveAccrualViewsLib.sol";
import {ReserveRoundingLib} from "./libraries/ReserveRoundingLib.sol";
import {IContinuousAccrual} from "./interfaces/IContinuousAccrual.sol";
import {IAccrualLifecycle} from "./interfaces/IAccrualLifecycle.sol";
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

    /// @dev Native mutations cannot overlap an accrual transition or a guarded host callback.
    modifier accrualIdle() {
        _requireNativeIdle();
        _;
    }

    /// @dev THE STORAGE STRUCT STAYS DECLARED HERE, DELIBERATELY, even though the EIP-170
    ///      extraction moved every credit-path BODY into `ReserveCreditLib`. Moving the struct
    ///      into a library would be layout-identical, but the storage-layout gates key on the
    ///      declaring file, so they would read it as a REMOVAL and demand `--allow-removals`, a
    ///      flag whose documented meaning is "this proxy is being freshly redeployed". It is not:
    ///      this is a live mainnet proxy. Leaving the declaration in place keeps the change
    ///      layout-neutral BY CONSTRUCTION rather than by argument, and keeps both baselines and
    ///      the compiler-backed probe pointing at the same key they have always pointed at. The
    ///      libraries take `ReserveManager.ReserveStorage storage` and the resulting circular
    ///      import is a type-only reference, which solc resolves without embedding any code.
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

    /// @dev The ERC-7201 root of the LIVE implementation. Changing this bricks the proxy.
    bytes32 internal constant RESERVE_STORAGE_LOCATION =
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
    function depositUSDC(address from, uint256 amount)
        external
        accrualIdle
        nonReentrant
        whenNotPaused
        returns (uint256 credited)
    {
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
        credited = ReserveStorageLib.normalize(received);
        emit USDCDeposited(from, amount, credited);
    }

    /// @inheritdoc IReserveManager
    function releaseUSDC(address to, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CONTROLLER_ROLE)
        nonReentrant
        whenNotPaused
    {
        _release(to, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev The lock is derived directly from the same canonical balance, so observation is
    ///      reversible and permissionless without giving the caller authority to create state.
    function reconcileIdleUSDC() external accrualIdle nonReentrant returns (uint256 shortfall) {
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
        return ReserveStorageLib.normalize(shortfall);
    }

    /// @notice Conservative backing after subtracting the physically observed custody gap.
    function recognizedBackingValue() external view returns (uint256) {
        return ReserveAccrualViewsLib.backing(_storage(), true);
    }

    /// @notice Compatibility binding retained for the ADR-0034 loss absorber. It is not a
    /// credit path; custody recovery remains exclusively arm-bound `creditRecoveredIdleUSDC`.
    function setLossAbsorber(address absorber) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveWiringLib.bindAbsorber(_storage(), absorber);
    }

    /// @notice Legacy incident opener retained for pre-arm audit harnesses. It does not move
    /// backing or credit custody; new production loss accounting must use armReserveLossFreeze
    /// followed by ratifyAndOpen.
    function openReserveLossIncident(uint256 incidentNonce, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 incidentId)
    {
        return ReserveIncidentLib.openIncident(_storage(), incidentNonce, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function closeReserveLossIncident(uint256 incidentId) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveIncidentLib.closeIncident(_storage(), incidentId);
    }

    /// @inheritdoc IReserveManager
    function resolveReserveDeficit(bytes32 evidenceHash) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveIncidentLib.resolveDeficit(_storage(), evidenceHash);
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
    function setLossController(address controller_) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveWiringLib.bindController(_storage(), controller_);
    }

    /// @inheritdoc IReserveManager
    function setReserveLossModules(address curator, address backstop, address vault, address governor, address timelock)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveWiringLib.bindModules(_storage(), curator, backstop, vault, governor, timelock);
    }

    /// @inheritdoc IReserveManager
    function armReserveLossFreeze(bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(Roles.GUARDIAN_ROLE)
        returns (uint256 armId, uint256 incidentId)
    {
        return ReserveIncidentLib.arm(_storage(), evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function cancelAndDisable(uint256 expectedArmId, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveIncidentLib.cancel(_storage(), expectedArmId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function cancelUnratifiedArm(uint256 expectedArmId, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveIncidentLib.cancelUnratified(_storage(), expectedArmId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function setGuardianReserveLossArmsEnabled(bool enabled) external accrualIdle onlyRole(DEFAULT_ADMIN_ROLE) {
        ReserveStorage storage $ = _storage();
        $.guardianReserveLossArmsEnabled = enabled;
        emit GuardianReserveLossArmsEnabled(enabled);
    }

    /// @inheritdoc IReserveManager
    function ratifyAndOpen(uint256 expectedArmId, bytes32 evidenceHash, uint256 approvedMaxLoss)
        external
        accrualIdle
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
        actualLoss = ReserveStorageLib.normalize(shortfallUnits);
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

        ReserveAccrualLib.prepareNativeLoss($);
        ReserveCascadeLib.recognize($, shortfallUnits, actualLoss);
        if ($.recognizedSupplyReduction != 0) ReserveCascadeLib.absorb($, incidentId);
        emit IdleUSDCWrittenDown(actualLoss, ReserveStorageLib.normalize($.idleUSDCUnits));
        emit ReserveLossRatified(armId, incidentId, approvedMaxLoss, actualLoss, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function creditRecoveredIdleUSDC(uint256 armId, bytes32 evidenceHash)
        external
        accrualIdle
        nonReentrant
        returns (uint256 credited)
    {
        _requireReserveLossAdmin();
        return ReserveIncidentLib.creditRecovery(_storage(), armId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function finalizeAndDisable(uint256 expectedArmId, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ReserveIncidentLib.finalize(_storage(), expectedArmId, evidenceHash);
    }

    /// @inheritdoc IReserveManager
    function recordDeployment(uint256 facilityId, address to, uint256 usdcAmount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
    {
        ReserveAccrualCreditLib.requireUnregisteredFunding(facilityId);
        ReserveCreditLib.deploy(_storage(), facilityId, to, usdcAmount);
    }

    /// @inheritdoc IReserveManager
    function recordFeeCapitalization(uint256 facilityId, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        whenNotPaused
    {
        ReserveAccrualCreditLib.requireUnregisteredFunding(facilityId);
        ReserveCreditLib.capitalize(_storage(), facilityId, amount, true);
    }

    /// @inheritdoc IReserveManager
    /// @dev THE TWIN OF `recordFeeCapitalization`, sharing its body, and the ONLY difference is the
    ///      idle-value check. The fee twin is sound because the fee's cash NEVER LEFT: `fund`
    ///      deploys `principal - fee`, so backing rises against RETAINED CASH and bounding it by
    ///      idle is meaningful. There is no retained cash behind a PIK capitalisation; what stands
    ///      behind it is the borrower's obligation to repay a larger balance and, beneath that, the
    ///      curator first-loss layer. Bounding a receivable by idle cash would refuse a legitimate
    ///      capitalisation on a drawn-down book and admit one on a flush book.
    ///
    ///      EVERY OTHER BOUND LIVES IN `WaterfallEngine.capitalizePik`. Do not call this from
    ///      anywhere that does not carry them.
    function recordPikCapitalization(uint256 facilityId, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        whenNotPaused
    {
        ReserveAccrualCreditLib.requireLegacy(facilityId);
        ReserveCreditLib.capitalize(_storage(), facilityId, amount, false);
    }

    /// @inheritdoc IReserveManager
    function recordPayment(uint256 facilityId, address payer, uint256 usdcAmount, uint256 principal)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 receivedValue)
    {
        ReserveAccrualCreditLib.requireLegacy(facilityId);
        receivedValue = ReserveCreditLib.pay(_storage(), facilityId, payer, usdcAmount, principal);
    }

    /// @inheritdoc IReserveManager
    function recordPrincipalWritedown(uint256 facilityId, uint256 amount)
        external
        accrualIdle
        onlyRole(Roles.CREDIT_ROLE)
    {
        if (ReserveAccrualStorageLib.state().enabled) ReserveAccrualCreditLib.writeDown(facilityId, amount);
        ReserveCreditLib.writeDown(_storage(), facilityId, amount);
    }

    /// @inheritdoc IReserveManager
    /// @dev This is a valuation transition, not a cascade transition: it moves no value and
    ///      burns no claims. Keeping it separate ensures an honest conservative mark is never
    ///      conditional on the three loss layers having enough immediately burnable capital.
    function recognizePrincipalImpairment(uint256 facilityId, uint256 amount, bytes32 evidenceHash)
        external
        accrualIdle
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        if (evidenceHash == bytes32(0)) revert ReserveManager_ZeroEvidenceHash();
        ReserveStorage storage $ = _storage();
        // A valuation must cover earned receivables as well as previously recorded face.
        if (ReserveAccrualStorageLib.state().enabled) ReserveAccrualCreditLib.post($, facilityId);
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
        accrualIdle
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
    function pause() external accrualIdle onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Resumes routine reserve deposits, releases, deployments, and payments.
    function unpause() external accrualIdle onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IReserveManager
    function idleReserve() external view returns (uint256) {
        return ReserveStorageLib.normalize(_storage().idleUSDCUnits);
    }

    /// @inheritdoc IReserveManager
    function idleUSDC() external view returns (uint256) {
        return _storage().idleUSDCUnits;
    }

    /// @inheritdoc IReserveManager
    function deployedPrincipal() external view returns (uint256) {
        return ReserveAccrualViewsLib.deployed(_storage(), 0, true);
    }

    /// @inheritdoc IReserveManager
    function totalBackingValue() external view returns (uint256) {
        return ReserveAccrualViewsLib.backing(_storage(), false);
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
        return ReserveAccrualViewsLib.deployed(_storage(), facilityId, false);
    }

    /// @notice Pulls exact USDC from a recapitalizing funder and records only what arrived.
    ///         This cannot credit pre-existing surplus; that remains arm-bound recovery.
    function recapitalize(uint256 amount) external accrualIdle nonReentrant returns (uint256 credited) {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 beforeBalance = $.usdcToken.balanceOf(address(this));
        $.usdcToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = $.usdcToken.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ReserveManager_NoValueReceived();
        if (received != amount) revert ReserveManager_UnexpectedUSDCReceipt(amount, received);
        $.idleUSDCUnits += received;
        credited = ReserveStorageLib.normalize(received);
        emit Recapitalized(msg.sender, received, credited, _backingValue($), $.reserveDeficit);
    }

    /// @notice Compatibility view for the historical exit-prepayment cascade ledger.
    function exitPrepaidAbsorption() external view returns (uint256) {
        return _storage().exitPrepaidAbsorption;
    }

    /// @inheritdoc IReserveManager
    function recordExitPrepayment(uint256 amount) external accrualIdle {
        ReserveStorage storage $ = _storage();
        if (msg.sender != address($.lossAbsorber)) revert ReserveManager_NotLossAbsorber(msg.sender);
        if (amount == 0) revert ReserveManager_ZeroAmount();
        uint256 outstanding = $.exitPrepaidAbsorption + amount;
        $.exitPrepaidAbsorption = outstanding;
        emit ExitPrepaymentRecorded(amount, outstanding);
    }

    /// @inheritdoc IReserveManager
    function consumeExitPrepayment(uint256 facilityId, uint256 loss) external accrualIdle returns (uint256 used) {
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

    /// @notice Configures immutable counterparties before all modules bind and recognition starts.
    function configureContinuousAccrual(IContinuousAccrual.Modules calldata modules_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        ReserveAccrualLib.configure(_storage(), modules_);
    }

    /// @inheritdoc IReserveManager
    function requireLegacyRollbackSafe() external view accrualIdle {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (s.enabled || s.migration.active || s.recordedFace != 0 || s.roundingUnabsorbed != 0) {
            revert ReserveManager_LegacyRollbackUnsafe();
        }
    }

    /// @notice Starts prospective recognition after compatible consumer bindings are verified.
    function enableContinuousAccrual() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        ReserveAccrualLib.enable(_storage());
    }

    /// @notice Executes one governed opening-import preparation step.
    /// @dev The complete step encoding is defined by IAccrualMigration.
    function prepareContinuousAccrualMigration(bytes calldata step)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        ReserveMigrationLib.prepare(_storage(), step);
    }

    /// @notice Constant-time status for the frozen roster; a partial book is never quoted here.
    function accrualMigration() external view returns (IAccrualMigration.Progress memory) {
        _returnEncodedView(ReserveMigrationLib.progressData());
    }

    /// @notice The bound waterfall synchronizes its fee rate and destination prospectively.
    function setAccrualFee(uint16 feeBps, address recipient) external nonReentrant {
        ReserveAccrualLib.setFee(_storage(), feeBps, recipient);
    }

    /// @notice The cumulative part of proved sub-unit losses for which native capital was unavailable.
    function roundingLossUnabsorbed() external view returns (uint256) {
        return ReserveAccrualStorageLib.state().roundingUnabsorbed;
    }

    /// @notice Consumes only the controller's exact current rounding-burn continuation.
    /// @dev Deliberately inside the outer reserve guard; the library authenticates its single caller.
    function consumeAccrualLossBurn(address caller, address from, uint256 amount) external returns (bool) {
        return ReserveRoundingLib.consumeBurn(caller, from, amount);
    }

    /// @notice Module identities for this independently backed reserve instance.
    function accrualModules() external view returns (IContinuousAccrual.Modules memory) {
        _returnEncodedView(ReserveAccrualLib.modulesData());
    }

    /// @notice Constant-time effective recognition and outstanding posting/issuance claims.
    function accrualSnapshot() external view returns (IContinuousAccrual.Snapshot memory) {
        _returnEncodedView(ReserveAccrualLib.snapshotData());
    }

    /// @notice Current exact delivery permit and coherent accounting prices, or inactive zeros.
    function accrualDelivery() external view returns (IContinuousAccrual.Delivery memory) {
        _returnEncodedView(ReserveAccrualLib.deliveryData());
    }

    /// @notice Authoritative admission gate for every price-sensitive consumer.
    function requireAccrualFresh() external view {
        ReserveAccrualLib.requireFresh();
    }

    /// @notice Converts selected accrued senior/fee claims into physical USDfr, including while paused.
    function materializeAccrued(uint8 legs) external nonReentrant returns (uint256 senior, uint256 fee) {
        return ReserveAccrualLib.materialize(_storage(), legs);
    }

    /// @notice Clock-independent callback admission used by bound accounting consumers.
    function requireAccrualIdle() external view {
        ReserveAccrualLib.requireIdle();
    }

    /// @notice Unposted earned exposure by total, class, borrower or state; reads no facility list.
    function accrualExposure(uint8 kind, bytes32 identity) external view returns (uint256) {
        return ReserveAccrualCreditLib.exposure(kind, identity);
    }

    /// @notice Additional maximum future face already reserved by funded contractual schedules.
    function accrualReservedExposure() external view returns (uint256) {
        return ReserveAccrualCreditLib.reservedExposure();
    }

    /// @notice The bound waterfall registers its authenticated just-funded facility.
    function registerAccruingLoan(uint256 facilityId) external nonReentrant {
        ReserveAccrualCreditLib.register(_storage(), facilityId);
    }

    /// @notice Permissionless chronological maintenance; at most 32 due events per transaction.
    function checkpointAccrual(uint256 maximum) external nonReentrant returns (uint256 processed, bool fresh) {
        return ReserveAccrualCreditLib.checkpoint(_storage(), maximum);
    }

    /// @notice Advances only zero-work contractual PIK dates in constant time.
    function serviceAccruedLoan(uint256 facilityId) external nonReentrant returns (uint256 capitalized) {
        return ReserveAccrualServiceLib.service(_storage(), facilityId);
    }

    /// @notice Discloses whether a known facility has a positive queued accrual segment.
    function accrualLoanScheduled(uint256 facilityId) external view returns (bool) {
        return ReserveAccrualServiceLib.scheduled(facilityId);
    }

    /// @notice Posts a single existing virtual receivable before a native impairment or lifecycle act.
    function postAccruedLoan(uint256 facilityId) external nonReentrant returns (uint256 amount) {
        return ReserveAccrualCreditLib.post(_storage(), facilityId);
    }

    /// @notice The bound waterfall delivers an exact attested repayment of an existing streamed claim.
    function repayAccruingLoan(uint256 facilityId, address payer, uint256 principal, uint256 interest)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 outstanding)
    {
        return ReserveAccrualCreditLib.repay(_storage(), facilityId, payer, principal, interest);
    }

    /// @notice Releases the finite active-book slot after full repayment/loss and all native risk hooks.
    function retireAccruedLoan(uint256 facilityId) external nonReentrant {
        ReserveAccrualCreditLib.retire(_storage(), facilityId);
    }

    /// @notice The bridge forwards a consumed signed amendment, effective only from this block.
    function amendAccruingLoan(uint256 facilityId, IAccrualLifecycle.Terms calldata terms) external nonReentrant {
        ReserveAccrualCreditLib.amend(_storage(), facilityId, terms);
    }

    /// @notice The bound default manager closes the full earned claim before declaring default.
    function stopAccruingLoan(uint256 facilityId) external nonReentrant {
        ReserveAccrualCreditLib.stop(_storage(), facilityId);
    }

    /// @notice The default manager controls growing past-due cohort membership.
    function setAccrualPastDue(uint256 facilityId, bool marked) external nonReentrant {
        ReserveAccrualCreditLib.setPastDue(facilityId, marked);
    }

    /// @notice Canonical debt disclosure; reserve backing continues to use its streamed carrier.
    function accruedDebt(uint256 facilityId) external view returns (IAccrualLifecycle.Debt memory) {
        _returnEncodedView(ReserveAccrualViewsLib.debt(facilityId));
    }

    /// @notice Unposted growth in the default manager's marked cohort of one class.
    function accruedPastDue(uint256 classId) external view returns (uint256 amount) {
        return ReserveAccrualCreditLib.pastDue(classId);
    }

    /// @notice Facility contribution to the reserve's virtual receivable carrier.
    function unpostedAccruedLoan(uint256 facilityId) external view returns (uint256 amount) {
        return ReserveAccrualViewsLib.unpostedLoan(facilityId);
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
        return ReserveStorageLib.normalize(amount);
    }

    /// @inheritdoc IReserveManager
    function denormalizeUSDC(uint256 value) external pure returns (uint256) {
        uint256 amount = ReserveStorageLib.denormalize(value);
        if (ReserveStorageLib.normalize(amount) != value) revert ReserveManager_ValueNotUSDCExact(value);
        return amount;
    }

    function _release(address to, uint256 amount) private {
        if (to == address(0)) revert ReserveManager_ZeroAddress();
        if (to == address(this)) revert ReserveManager_SelfDeployment();
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        // R4-01: never pay an exit from a reserve whose recorded idle ledger is observably short.
        ReserveStorageLib.requireIdleFullyCustodied($);
        uint256 value = ReserveStorageLib.normalize(amount);
        uint256 idleValue = ReserveStorageLib.normalize($.idleUSDCUnits);
        if (value > idleValue) revert ReserveManager_InsufficientIdleValue(value, idleValue);
        $.idleUSDCUnits -= amount;
        $.usdcToken.safeTransfer(to, amount);
        emit USDCReleased(to, amount);
    }

    function _requireReserveLossAdmin() private view {
        if (!hasRole(Roles.RESERVE_ADMIN_ROLE, msg.sender)) {
            revert ReserveManager_ReserveLossCallerNotAdmin(msg.sender);
        }
    }

    function _requireActiveArm(ReserveStorage storage $, uint256 expectedArmId) private view returns (uint256 armId) {
        armId = $.activeReserveLossArmId;
        if (armId == 0) revert ReserveManager_NoActiveArm();
        if (expectedArmId != armId) revert ReserveManager_ArmMismatch(armId, expectedArmId);
    }

    /// @dev A realized write-down consumes the corresponding conservative mark so the same loss
    ///      is not counted once in face and again in the valuation adjustment.
    function _backingValue(ReserveStorage storage $) private view returns (uint256) {
        return ReserveAccrualViewsLib.backing($, false);
    }

    function _liveShortfallUnits(ReserveStorage storage $) private view returns (uint256) {
        uint256 live = $.usdcToken.balanceOf(address(this));
        return $.idleUSDCUnits > live ? $.idleUSDCUnits - live : 0;
    }

    /// @dev The caller needs only a validity bit. The earlier merge returned four additional
    ///      values which no caller consumed, duplicating ABI decoders for every getter inside an
    ///      EIP-170-constrained implementation. Keep the same six live checks through one strict
    ///      word reader; compare CLOCK_MODE's complete canonical ABI encoding so a permissive
    ///      fallback cannot satisfy the string call with a zero word.

    function _requireNativeIdle() private view {
        ReserveAccrualLib.requireIdle();
        if (ReserveAccrualStorageLib.state().modules.token != address(0) && _reentrancyGuardEntered()) {
            revert ReserveAccrualLib.ReserveAccrual_OperationInProgress();
        }
    }

    /// @dev Return only a compiler-encoded typed view; no caller-controlled target or calldata.
    function _returnEncodedView(bytes memory data) private pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        _requireNativeIdle();
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        _requireNativeIdle();
        return super._revokeRole(role, account);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(Roles.UPGRADER_ROLE) {
        _requireNativeIdle();
    }

    /// @dev THE ONE NAMESPACED SLOT ASSIGNMENT, AND IT STAYS IN THIS FILE. `check-storage-layout`
    ///      requires exactly one `$.slot` assignment in the file that declares the namespaced
    ///      struct, which is how it binds a declaration to an ERC-7201 root. The libraries are
    ///      handed the pointer rather than deriving it, so there is exactly one place in the
    ///      repository that knows where this proxy's storage lives.
    function _storage() private pure returns (ReserveStorage storage $) {
        assembly {
            $.slot := RESERVE_STORAGE_LOCATION
        }
    }
}
