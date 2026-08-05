// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IPointsModule} from "./interfaces/IPointsModule.sol";
import {IUSDfr} from "./interfaces/IUSDfr.sol";
import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title USDfr — the Forest Road synthetic dollar
/// @notice Fully-backed ERC-20 (brief Part 4). It does not itself yield. Supply may only
///         change through the MintRedeemController (MINTER_ROLE), which enforces the
///         backing invariant `totalSupply <= backingValue` (ADR-0012); the loss cascade
///         burns are also performed by that controller. Transfers consult an optional
///         compliance module (capability per ADR-0011 — policy is set by governance/
///         counsel; holding/transfer is permissionless unless governance restricts).
/// @dev Nothing in this contract or its documentation characterizes USDfr under
///      securities law; that determination is counsel's (brief Part 0.5).
contract USDfr is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IUSDfr
{
    /// @custom:storage-location erc7201:forestroad.storage.USDfr
    struct USDfrStorage {
        IComplianceRegistry complianceModule;
        // ── append-only (upgrade safety) ──────────────────────────────────
        // Participation-points hook (ADR-0016 / 2026-07-14 directive): USDfr holders accrue
        // points at a governance multiple of the sUSDfr rate, in lieu of yield. Optional;
        // fail-open so a points failure can never block a USDfr transfer.
        IPointsModule pointsModule;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.USDfr")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant USDFR_STORAGE_LOCATION = 0xc3fcf06498ffe1eac01a14cc645fb1e6aacc447c7b2a7d46a005df569b521500;

    error USDfr_ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the token.
    /// @param admin Governance timelock (DEFAULT_ADMIN_ROLE).
    /// @param minter The MintRedeemController (sole MINTER_ROLE holder).
    /// @param guardian Emergency pauser.
    /// @param upgrader Upgrade authority (the timelock).
    function initialize(address admin, address minter, address guardian, address upgrader) external initializer {
        if (admin == address(0) || minter == address(0) || guardian == address(0) || upgrader == address(0)) {
            revert USDfr_ZeroAddress();
        }
        __ERC20_init(Config.USDFR_NAME, Config.USDFR_SYMBOL);
        __ERC20Permit_init(Config.USDFR_NAME);
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.MINTER_ROLE, minter);
        _grantRole(Roles.GUARDIAN_ROLE, guardian);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
    }

    // ── Supply (controller / cascade only) ───────────────────────────────

    /// @inheritdoc IUSDfr
    function mint(address to, uint256 amount) external onlyRole(Roles.MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IUSDfr
    function burn(address from, uint256 amount) external {
        _checkRole(Roles.MINTER_ROLE, msg.sender);
        _burn(from, amount);
    }

    // ── Compliance ───────────────────────────────────────────────────────

    /// @inheritdoc IUSDfr
    function complianceModule() external view returns (address) {
        return address(_storage().complianceModule);
    }

    /// @inheritdoc IUSDfr
    function setComplianceModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _storage().complianceModule = IComplianceRegistry(module);
        emit ComplianceModuleUpdated(module);
    }

    // ── Points (ADR-0016 / 2026-07-14 directive) ─────────────────────────

    /// @notice The participation-points hook (zero disables it).
    function pointsModule() external view returns (address) {
        return address(_storage().pointsModule);
    }

    /// @notice Sets the participation-points hook. Timelocked governance only.
    function setPointsModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _storage().pointsModule = IPointsModule(module);
        emit PointsModuleUpdated(module);
    }

    // ── Guardian pause ───────────────────────────────────────────────────

    /// @notice Pauses user transfers and mints. Protocol-internal transfers and burns remain live.
    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpauses transfers.
    function unpause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _unpause();
    }

    // ── Internals ────────────────────────────────────────────────────────

    /// @dev During an emergency pause, burns and transfers wholly between governance-listed
    ///      protocol modules remain live so the loss cascade cannot be frozen by the token.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        USDfrStorage storage $ = _storage();
        IComplianceRegistry module = $.complianceModule;
        if (paused() && to != address(0)) {
            bool internalTransfer = from != address(0) && address(module) != address(0) && module.isProtocolExempt(from)
                && module.isProtocolExempt(to);
            if (!internalTransfer) revert EnforcedPause();
        }
        if (address(module) != address(0) && !module.canTransfer(address(this), from, to)) {
            revert USDfr_TransferNotAllowed(from, to);
        }
        super._update(from, to, value);
        // Participation-points hook (ADR-0016 / 2026-07-14 directive), FAIL-OPEN: USDfr
        // holders accrue points in lieu of yield, but a points-module failure must never
        // block a USDfr transfer, mint, or burn.
        IPointsModule points = $.pointsModule;
        if (address(points) != address(0)) {
            // FAIL-OPEN, but emit telemetry (P-04) so a dropped transition is observable and
            // can be repaired via PointsModule.reconcile.
            try points.onUSDfrTransfer(from, to, value) {}
            catch {
                emit PointsHookFailed(from, to, value);
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (USDfrStorage storage $) {
        assembly {
            $.slot := USDFR_STORAGE_LOCATION
        }
    }
}
