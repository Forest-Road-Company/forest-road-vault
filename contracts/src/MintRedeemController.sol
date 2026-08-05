// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IMintRedeemController} from "./interfaces/IMintRedeemController.sol";
import {IReserveManager} from "./interfaces/IReserveManager.sol";
import {IUSDfr} from "./interfaces/IUSDfr.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title MintRedeemController
/// @notice The only mint/burn path for USDfr, and the enforcement point of the backing
///         invariant (ADR-0012): after EVERY supply-affecting operation this contract
///         asserts `USDfr.totalSupply() <= ReserveManager.totalBackingValue()` and
///         reverts the whole transaction on violation. Mint/redeem is KYC-gated
///         (ADR-0011); yield-mint and loss-burn are credit-layer paths (Phase E/G).
contract MintRedeemController is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IMintRedeemController
{
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:forestroad.storage.MintRedeemController
    struct ControllerStorage {
        IUSDfr usdfr;
        IComplianceRegistry compliance;
        IReserveManager reserves;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.MintRedeemController")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONTROLLER_STORAGE_LOCATION =
        0x78d32d002402115460f3fdc161605476f91264ca4d3e131f8b3d65ead1f69100;

    error Controller_ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the controller.
    /// @param admin Governance timelock.
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (timelock).
    /// @param usdfr The USDfr token (this contract must hold its MINTER_ROLE).
    /// @param compliance The compliance registry (KYC gate).
    /// @param reserves The ReserveManager (this contract must hold its CONTROLLER_ROLE).
    function initialize(
        address admin,
        address guardian,
        address upgrader,
        address usdfr,
        address compliance,
        address reserves
    ) external initializer {
        if (
            admin == address(0) || guardian == address(0) || upgrader == address(0) || usdfr == address(0)
                || compliance == address(0) || reserves == address(0)
        ) revert Controller_ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        ControllerStorage storage $ = _storage();
        $.usdfr = IUSDfr(usdfr);
        $.compliance = IComplianceRegistry(compliance);
        $.reserves = IReserveManager(reserves);
    }

    // ── User paths (KYC-gated) ───────────────────────────────────────────

    /// @inheritdoc IMintRedeemController
    function mint(uint256 usdcAmount) external nonReentrant whenNotPaused returns (uint256 usdfrOut) {
        ControllerStorage storage $ = _storage();
        _requireKYC($, msg.sender);
        if (usdcAmount == 0) revert Controller_ZeroAmount();
        IERC20 usdcToken = IERC20($.reserves.usdc());
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdcToken.forceApprove(address($.reserves), usdcAmount);
        usdfrOut = $.reserves.depositUSDC(address(this), usdcAmount);
        $.usdfr.mint(msg.sender, usdfrOut);
        _assertBacking($);
        emit Minted(msg.sender, usdcAmount, usdfrOut);
    }

    /// @inheritdoc IMintRedeemController
    function redeem(uint256 usdfrAmount) external nonReentrant whenNotPaused returns (uint256 usdcOut) {
        ControllerStorage storage $ = _storage();
        _requireKYC($, msg.sender);
        if (usdfrAmount == 0) revert Controller_ZeroAmount();

        // USDC has six decimals while USDfr has eighteen. Redeem the largest
        // whole-USDC amount and leave sub-USDC dust in the user's wallet.
        usdcOut = usdfrAmount / 1e12;
        if (usdcOut == 0) revert Controller_AmountTooSmall(usdfrAmount);
        uint256 usdfrIn = usdcOut * 1e12;

        // Burn (supply down) before releasing backing; invariant asserted after.
        $.usdfr.burn(msg.sender, usdfrIn);
        $.reserves.releaseUSDC(msg.sender, usdcOut);
        _assertBacking($);
        emit Redeemed(msg.sender, usdfrIn, usdcOut);
    }

    // ── Credit-layer paths (wired in Phases E/G) ─────────────────────────

    /// @inheritdoc IMintRedeemController
    function mintYield(address to, uint256 amount) external onlyRole(Roles.CREDIT_ROLE) nonReentrant {
        if (to == address(0)) revert Controller_ZeroAddress();
        if (amount == 0) revert Controller_ZeroAmount();
        ControllerStorage storage $ = _storage();
        // Backing must ALREADY reflect the attested receipts that justify this mint;
        // the post-mint assertion makes an unbacked yield mint revert.
        $.usdfr.mint(to, amount);
        _assertBacking($);
        emit YieldMinted(to, amount);
    }

    /// @inheritdoc IMintRedeemController
    function burnLoss(address from, uint256 amount) external onlyRole(Roles.CREDIT_ROLE) nonReentrant {
        if (from == address(0)) revert Controller_ZeroAddress();
        if (amount == 0) revert Controller_ZeroAmount();
        ControllerStorage storage $ = _storage();
        $.usdfr.burn(from, amount);
        _assertBacking($);
        emit LossBurned(from, amount);
    }

    // ── Guardian ─────────────────────────────────────────────────────────

    /// @notice Pauses mint/redeem. Emergency use only.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses mint/redeem.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Views ────────────────────────────────────────────────────────────

    /// @inheritdoc IMintRedeemController
    function backingValue() public view returns (uint256) {
        return _storage().reserves.totalBackingValue();
    }

    /// @inheritdoc IMintRedeemController
    function totalUSDfr() public view returns (uint256) {
        return _storage().usdfr.totalSupply();
    }

    /// @inheritdoc IMintRedeemController
    function backingInvariantHolds() external view returns (bool) {
        return totalUSDfr() <= backingValue();
    }

    /// @notice Wired module addresses (for post-deploy validation and the dashboard).
    function modules() external view returns (address usdfr, address compliance, address reserves) {
        ControllerStorage storage $ = _storage();
        return (address($.usdfr), address($.compliance), address($.reserves));
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _requireKYC(ControllerStorage storage $, address account) private view {
        if (!$.compliance.isAllowed(account)) revert Controller_NotKYCAllowed(account);
    }

    /// @dev ADR-0012: the hard invariant. Reverts the whole transaction on violation.
    function _assertBacking(ControllerStorage storage $) private view {
        uint256 supply = $.usdfr.totalSupply();
        uint256 backing = $.reserves.totalBackingValue();
        if (supply > backing) revert Controller_BackingInvariantViolated(supply, backing);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (ControllerStorage storage $) {
        assembly {
            $.slot := CONTROLLER_STORAGE_LOCATION
        }
    }
}
