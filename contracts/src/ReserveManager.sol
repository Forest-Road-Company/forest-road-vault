// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ReserveManager — mainnet-v1 USDC treasury
/// @notice Custodies canonical USDC and records conservatively marked deployed principal.
/// @dev Mainnet v1 intentionally has no generic stable registry, reserve instrument, or DSRA.
///      Unexpected direct USDC transfers are donations and do not increase reported backing.
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
    }

    bytes32 private constant RESERVE_STORAGE_LOCATION =
        0xc49ad79e2b58679c441432bede06c67f7802343349e70ccf00d8d1ce92bb1b00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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
        _storage().usdcToken = IERC20(usdc_);
    }

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

    function releaseUSDC(address to, uint256 amount)
        external
        onlyRole(Roles.CONTROLLER_ROLE)
        nonReentrant
        whenNotPaused
    {
        _release(to, amount);
    }

    /// @dev This can only reduce accounting to a lower live balance. It can never reverse
    ///      a write-down or recognize an unsolicited transfer as backing.
    function reconcileIdleUSDC() external returns (uint256 current) {
        ReserveStorage storage $ = _storage();
        uint256 live = $.usdcToken.balanceOf(address(this));
        uint256 previous = $.idleUSDCUnits;
        current = live < previous ? live : previous;
        if (current != previous) $.idleUSDCUnits = current;
        emit IdleUSDCReconciled(previous, current);
    }

    function writeDownIdleUSDC(uint256 amount) external onlyRole(Roles.RESERVE_ADMIN_ROLE) {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 value = _normalize($.idleUSDCUnits);
        if (amount > value) revert ReserveManager_WriteDownExceedsIdle(amount, value);
        uint256 units = _denormalize(amount);
        if (_normalize(units) != amount) revert ReserveManager_ValueNotUSDCExact(amount);
        $.idleUSDCUnits -= units;
        emit IdleUSDCWrittenDown(amount, _normalize($.idleUSDCUnits));
    }

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
        uint256 value = _normalize(usdcAmount);
        uint256 idleValue = _normalize($.idleUSDCUnits);
        if (value > idleValue) revert ReserveManager_InsufficientIdleValue(value, idleValue);
        $.idleUSDCUnits -= usdcAmount;
        $.deployed[facilityId] += value;
        $.totalDeployedPrincipal += value;
        $.usdcToken.safeTransfer(to, usdcAmount);
        emit PrincipalDeployed(facilityId, value);
    }

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
            $.deployed[facilityId] = deployed - principal;
            $.totalDeployedPrincipal -= principal;
        }
        emit PaymentReceived(facilityId, payer, usdcAmount, principal);
    }

    function recordPrincipalWritedown(uint256 facilityId, uint256 amount) external onlyRole(Roles.CREDIT_ROLE) {
        if (amount == 0) revert ReserveManager_ZeroAmount();
        ReserveStorage storage $ = _storage();
        uint256 deployed = $.deployed[facilityId];
        if (amount > deployed) {
            revert ReserveManager_InsufficientDeployedPrincipal(facilityId, amount, deployed);
        }
        $.deployed[facilityId] = deployed - amount;
        $.totalDeployedPrincipal -= amount;
        emit PrincipalWrittenDown(facilityId, amount);
    }

    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    function idleReserve() external view returns (uint256) {
        return _normalize(_storage().idleUSDCUnits);
    }

    function idleUSDC() external view returns (uint256) {
        return _storage().idleUSDCUnits;
    }

    function deployedPrincipal() external view returns (uint256) {
        return _storage().totalDeployedPrincipal;
    }

    function totalBackingValue() external view returns (uint256) {
        ReserveStorage storage $ = _storage();
        return _normalize($.idleUSDCUnits) + $.totalDeployedPrincipal;
    }

    function deployedTo(uint256 facilityId) external view returns (uint256) {
        return _storage().deployed[facilityId];
    }

    function usdc() external view returns (address) {
        return address(_storage().usdcToken);
    }

    function normalizeUSDC(uint256 amount) external pure returns (uint256) {
        return _normalize(amount);
    }

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
        uint256 value = _normalize(amount);
        uint256 idleValue = _normalize($.idleUSDCUnits);
        if (value > idleValue) revert ReserveManager_InsufficientIdleValue(value, idleValue);
        $.idleUSDCUnits -= amount;
        $.usdcToken.safeTransfer(to, amount);
        emit USDCReleased(to, amount);
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
