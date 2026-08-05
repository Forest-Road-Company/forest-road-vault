// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {GovernorCountingSimpleUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {GovernorSettingsUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {GovernorTimelockControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {GovernorVotesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {GovernorVotesQuorumFractionUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {Config} from "./libraries/Config.sol";

/// @title FRGovernor — GROVE-weighted governance over a timelock (ADR-0013, ADR-0026)
/// @notice The full machinery (propose → vote → queue → execute through the timelock)
///         exists from day one, but Forest Road HOLDS EFFECTIVE CONTROL at launch:
///         the genesis GROVE supply sits with the Forest Road treasury, so quorum and
///         outcomes are theirs until distribution happens. Progressive
///         decentralization is a later roadmap item, not a launch commitment —
///         state this honestly everywhere (ADR-0013; docs must not imply
///         decentralization that does not exist).
/// @dev Standard audited OZ stack (CLAUDE.md §3.1 — no hand-rolled governance):
///      Settings + CountingSimple + Votes + QuorumFraction + TimelockControl. The
///      timelock is the executor and holds every module's DEFAULT_ADMIN/UPGRADER
///      (wired by the deploy script, validated post-deploy). Upgrades to the governor
///      itself go through governance (`onlyGovernance` ⇒ via the timelock).
contract FRGovernor is
    Initializable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the governor with the ADR-0013/0021 launch parameters.
    /// @param votesSource The `IVotes` source voting power and the quorum denominator are read
    ///        from. Post ADR-0026 this is the **`GroveVotesAggregator`**, NOT GROVE directly: it
    ///        sums wallet-GROVE and staked-GROVE votes so staking the backstop does not
    ///        disenfranchise the staker, while sourcing `getPastTotalSupply` from GROVE alone so
    ///        staking cannot move the quorum bar. Fixed here with no setter (`GovernorVotes`), so
    ///        changing it later requires a full UUPS upgrade of this contract through the timelock.
    /// @param timelock The timelock controller (executor; admin of all modules).
    function initialize(IVotes votesSource, TimelockControllerUpgradeable timelock) external initializer {
        __Governor_init("Forest Road Governor");
        __GovernorSettings_init(Config.GOV_VOTING_DELAY, Config.GOV_VOTING_PERIOD, Config.GOV_PROPOSAL_THRESHOLD);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(votesSource);
        __GovernorVotesQuorumFraction_init(Config.GOV_QUORUM_FRACTION);
        __GovernorTimelockControl_init(timelock);
        __UUPSUpgradeable_init();
    }

    // ── required overrides (OZ multiple inheritance) ─────────────────────

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
