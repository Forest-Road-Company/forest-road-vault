// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ComplianceRegistry
/// @notice Compliance capability layer (ADR-0011, amended by the 2026-07-14 Forest Road
///         directive): a KYC allowlist consulted ONLY at the mint/redeem primary gate, and a
///         narrow SANCTIONS blocklist consulted on transfers. Transfers are otherwise
///         permissionless — the per-token transfer-allowlist capability was removed. Capability
///         lives here; eligibility/sanctions POLICY is governance/counsel's, expressed purely
///         as list contents. This is a regulatory-posture decision owned by Forest Road +
///         counsel (STATE.md); nothing here characterizes any instrument (brief Part 0.5).
/// @dev Trust note: list administration is role-gated (COMPLIANCE_ADMIN_ROLE for accounts,
///      DEFAULT_ADMIN_ROLE i.e. timelocked governance for per-token restriction flags).
///      Nothing in this contract asserts anything about the securities characterization
///      of any protocol instrument (brief Part 0.5).
contract ComplianceRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, IComplianceRegistry {
    /// @custom:storage-location erc7201:forestroad.storage.ComplianceRegistry
    /// @dev Fields are append-only (ERC-7201 namespaced struct) for upgrade safety.
    struct ComplianceStorage {
        mapping(address account => bool) allowed;
        mapping(address account => bool) blocked;
        // Protocol module addresses (vault, queue, reserves, curator, sGrove,
        // defaultManager, waterfall, controller, feeRecipient). A module is never treated as
        // a sanctioned party in canTransfer — else a COMPLIANCE_ADMIN block of a module
        // address would brick the "never-pausable" cascade/redemption. Sanctions still apply
        // to the NON-module counterparty (R2-H-01 fix). DEFAULT_ADMIN-managed (timelock),
        // toggle-able so a deprecated module can be de-listed on an upgrade.
        mapping(address module => bool) protocolExempt;
    }

    // keccak256(abi.encode(uint256(keccak256("forestroad.storage.ComplianceRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant COMPLIANCE_STORAGE_LOCATION =
        0x03801aefafc5a4dd742851861c13346935b02c9e4c08bfcf4aed3079668d5300;

    error ComplianceRegistry_ZeroAddress();
    error ComplianceRegistry_LengthMismatch();

    /// @notice Emitted when a protocol module's compliance exemption changes.
    event ProtocolExemptUpdated(address indexed module, bool exempt);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes roles. `admin` is the governance timelock (DEFAULT_ADMIN_ROLE).
    /// @param admin Governance admin (timelock).
    /// @param complianceAdmin Operational list manager (may equal admin initially).
    /// @param upgrader Upgrade authority (the timelock).
    /// @param initialProtocolExempt The initial fee recipient or protocol module that must
    ///        be unbrickable before dependent contracts are initialized.
    function initialize(address admin, address complianceAdmin, address upgrader, address initialProtocolExempt)
        external
        initializer
    {
        if (
            admin == address(0) || complianceAdmin == address(0) || upgrader == address(0)
                || initialProtocolExempt == address(0)
        ) {
            revert ComplianceRegistry_ZeroAddress();
        }
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.COMPLIANCE_ADMIN_ROLE, complianceAdmin);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        _storage().protocolExempt[initialProtocolExempt] = true;
        emit ProtocolExemptUpdated(initialProtocolExempt, true);
    }

    // ── List administration ──────────────────────────────────────────────

    /// @notice Sets KYC allowlist status for `account`.
    function setAllowed(address account, bool allowed_) external onlyRole(Roles.COMPLIANCE_ADMIN_ROLE) {
        if (account == address(0)) revert ComplianceRegistry_ZeroAddress();
        _storage().allowed[account] = allowed_;
        emit AllowlistUpdated(account, allowed_);
    }

    /// @notice Batch allowlist update (broad-access onboarding, ADR-0011).
    function setAllowedBatch(address[] calldata accounts, bool allowed_)
        external
        onlyRole(Roles.COMPLIANCE_ADMIN_ROLE)
    {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ++i) {
            if (accounts[i] == address(0)) revert ComplianceRegistry_ZeroAddress();
            _storage().allowed[accounts[i]] = allowed_;
            emit AllowlistUpdated(accounts[i], allowed_);
        }
    }

    /// @notice Sets jurisdiction-block status for `account`. Blocked accounts fail every
    ///         compliance check regardless of allowlist status.
    function setJurisdictionBlocked(address account, bool blocked_) external onlyRole(Roles.COMPLIANCE_ADMIN_ROLE) {
        if (account == address(0)) revert ComplianceRegistry_ZeroAddress();
        _storage().blocked[account] = blocked_;
        emit JurisdictionBlockUpdated(account, blocked_);
    }

    /// @notice Marks `module` as a protocol-exempt address whose transfers are never
    ///         blockable by list state (see the storage note). Timelocked governance
    ///         only — set once for every internal-value-moving protocol contract at
    ///         deploy so the compliance capability can never brick the cascade/queue.
    function setProtocolExempt(address module, bool exempt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) revert ComplianceRegistry_ZeroAddress();
        _storage().protocolExempt[module] = exempt;
        emit ProtocolExemptUpdated(module, exempt);
    }

    /// @notice True if `module` is exempt from all transfer blocking (a protocol module).
    function isProtocolExempt(address module) external view returns (bool) {
        return _storage().protocolExempt[module];
    }

    // ── Views (IComplianceRegistry) ──────────────────────────────────────

    /// @inheritdoc IComplianceRegistry
    function isAllowed(address account) public view returns (bool) {
        ComplianceStorage storage $ = _storage();
        return $.allowed[account] && !$.blocked[account];
    }

    /// @inheritdoc IComplianceRegistry
    function isJurisdictionBlocked(address account) external view returns (bool) {
        return _storage().blocked[account];
    }

    /// @inheritdoc IComplianceRegistry
    /// @dev DIRECTIVE 2026-07-14 (Forest Road): protocol tokens are NEVER KYC/allowlist-gated
    ///      on transfer — transfers are permissionless. The only on-chain transfer restriction
    ///      is a narrow SANCTIONS freeze (the `blocked` list). KYC is enforced solely at the
    ///      mint/redeem primary gate (`MintRedeemController`). This supersedes the ADR-0011
    ///      transfer-restriction capability (removed); a regulatory-posture change owned by
    ///      Forest Road + counsel (recorded in STATE.md). The `token` argument is retained for
    ///      interface stability but no longer affects the result.
    function canTransfer(address, address from, address to) external view returns (bool) {
        ComplianceStorage storage $ = _storage();
        // Burns (loss cascade, redemption settlement) are never blockable.
        if (to == address(0)) return true;
        // Sanctions freeze — the ONLY transfer restriction. A sanctioned party is denied even
        // when the counterparty is an exempt protocol module (AUDIT FIX R2-H-01: a blocked
        // wallet can no longer route value out through the exempt vault, because the sanctions
        // check now precedes the exemption). Protocol modules are never themselves treated as
        // "blocked", so a list error can't brick the never-pausable cascade.
        if ($.blocked[from] && !$.protocolExempt[from]) return false;
        if ($.blocked[to] && !$.protocolExempt[to]) return false;
        // Otherwise permissionless.
        return true;
    }

    // ── UUPS ─────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    function _storage() private pure returns (ComplianceStorage storage $) {
        assembly {
            $.slot := COMPLIANCE_STORAGE_LOCATION
        }
    }
}
