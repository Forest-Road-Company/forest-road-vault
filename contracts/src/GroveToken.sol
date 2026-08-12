// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import {Config} from "./libraries/Config.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title GROVE — the governance token (ADR-0013)
/// @notice Plain ERC20 + Votes + Permit. FIXED SUPPLY, minted in full to the Forest
///         Road treasury at genesis: governance is Forest-Road-controlled at launch
///         with progressive decentralization as a later roadmap item, not a launch
///         commitment (ADR-0013 — stated honestly everywhere). GROVE confers
///         governance rights and backstop-staking eligibility (SGrove); it carries NO
///         automatic right to protocol revenue (ADR-0019 routing note) and nothing
///         here characterizes it under securities law (brief Part 0.5 — counsel's
///         question, pre-mainnet gate).
contract GroveToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    error Grove_ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes GROVE, mints the fixed supply to the treasury, and activates its
    ///         genesis voting power by self-delegating the treasury's balance.
    /// @param admin Governance timelock.
    /// @param upgrader Upgrade authority (timelock).
    /// @param treasury Forest Road treasury (receives the full genesis supply).
    function initialize(address admin, address upgrader, address treasury) external initializer {
        if (admin == address(0) || upgrader == address(0) || treasury == address(0)) revert Grove_ZeroAddress();
        __ERC20_init(Config.GROVE_NAME, Config.GROVE_SYMBOL);
        __ERC20Permit_init(Config.GROVE_NAME);
        __ERC20Votes_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, upgrader);
        _mint(treasury, Config.GROVE_INITIAL_SUPPLY); // fixed supply — no mint path exists
        // ERC20Votes does not count an undelegated balance. Delegating here is the only way a
        // deployment can make a distinct treasury governance-live without asking that Safe to
        // race a separate transaction before the bootstrap administrator renounces. The
        // treasury remains free to change or clear its delegation after deployment.
        _delegate(treasury, treasury);
    }

    // ── timestamp clock (governance params are second-denominated) ───────

    /// @dev Timestamp-based checkpoints: Config's voting delay/period are seconds.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev EIP-6372 machine-readable clock description.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ── required overrides (OZ multiple inheritance) ─────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
