// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {FRGovernor} from "../../src/FRGovernor.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

contract GovernanceTest is GovernanceFixture {
    // ── GROVE token ──────────────────────────────────────────────────────

    function test_grove_genesisSupplyToTreasuryFixed() public view {
        assertEq(grove.totalSupply(), Config.GROVE_INITIAL_SUPPLY, "fixed supply");
        // treasury holds everything not yet distributed by fixtures/tests
        assertGt(grove.balanceOf(frTreasury), 0);
        assertEq(grove.delegates(frTreasury), frTreasury, "treasury self-delegated at genesis");
        assertEq(grove.getVotes(frTreasury), grove.balanceOf(frTreasury), "genesis balance has voting power");
        assertEq(grove.name(), Config.GROVE_NAME);
        assertEq(grove.symbol(), Config.GROVE_SYMBOL);
        assertEq(grove.CLOCK_MODE(), "mode=timestamp");
        assertEq(grove.clock(), uint48(block.timestamp));
    }

    function test_grove_initialize_zeroAddressReverts() public {
        GroveToken impl = new GroveToken();
        vm.expectRevert(GroveToken.Grove_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(GroveToken.initialize, (address(0), admin, frTreasury)));
        vm.expectRevert(GroveToken.Grove_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(GroveToken.initialize, (admin, admin, address(0))));
    }

    function test_grove_votesDelegationTracksTransfers() public {
        vm.prank(frTreasury);
        grove.transfer(alice, 1_000e18);
        assertEq(grove.getVotes(alice), 0, "votes need delegation");
        vm.prank(alice);
        grove.delegate(alice);
        assertEq(grove.getVotes(alice), 1_000e18);
        vm.prank(alice);
        grove.transfer(bob, 400e18);
        assertEq(grove.getVotes(alice), 600e18, "voting power follows balance");
        assertEq(grove.nonces(alice), 0, "permit nonces start at zero");
    }

    function test_grove_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new GroveToken());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        grove.upgradeToAndCall(newImpl, "");
        vm.prank(admin);
        grove.upgradeToAndCall(newImpl, "");
    }

    // ── the full machinery: propose → vote → queue → execute ─────────────

    function test_governance_endToEnd_parameterChangeThroughTimelock() public {
        assertEq(waterfall.protocolFeeBps(), 1_000, "launch default");

        address[] memory targets = new address[](1);
        targets[0] = address(waterfall);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (1_500));
        string memory description = "raise protocol fee to 15%";

        // FR treasury (genesis votes, ADR-0013 control) proposes
        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // voting opens after the delay; FR votes it through
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
        vm.prank(frTreasury);
        governor.castVote(proposalId, 1); // For

        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // queue into the timelock; execution blocked until the delay elapses
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        vm.expectRevert(); // TimelockUnexpectedOperationState: not ready
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(waterfall.protocolFeeBps(), 1_500, "the timelocked change landed");
    }

    function test_governance_belowThresholdCannotPropose() public {
        // alice holds fewer votes than the proposal threshold
        vm.prank(frTreasury);
        grove.transfer(alice, Config.GOV_PROPOSAL_THRESHOLD - 1);
        vm.startPrank(alice);
        grove.delegate(alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 1); // checkpoint the delegation

        address[] memory targets = new address[](1);
        targets[0] = address(waterfall);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (0));
        vm.expectRevert(); // GovernorInsufficientProposerVotes
        vm.prank(alice);
        governor.propose(targets, values, calldatas, "underpowered");
    }

    function test_governance_defeatedProposalCannotQueue() public {
        address[] memory targets = new address[](1);
        targets[0] = address(waterfall);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (0));

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, "nobody votes");
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + Config.GOV_VOTING_PERIOD + 2);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated), "no quorum");
        vm.expectRevert(); // GovernorUnexpectedProposalState
        governor.queue(targets, values, calldatas, keccak256(bytes("nobody votes")));
    }

    function test_governance_proposerCanCancelPending() public {
        address[] memory targets = new address[](1);
        targets[0] = address(waterfall);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (0));

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, "second thoughts");
        assertTrue(governor.proposalNeedsQueuing(proposalId), "timelock-controlled proposals queue");

        vm.prank(frTreasury);
        governor.cancel(targets, values, calldatas, keccak256(bytes("second thoughts")));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    /// @notice G1c: queueing is the final governance decision. The two-day delay is a public
    ///         warning period, not a veto period: no proposer, protocol guardian, or operator can
    ///         cancel after queueing, and execution remains permissionless once the delay elapses.
    function test_governance_queuedProposalHasNoCancellationPath() public {
        address[] memory targets = new address[](1);
        targets[0] = address(waterfall);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (1_500));
        string memory description = "queued governance finality";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        vm.prank(frTreasury);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        assertTrue(timelock.hasRole(cancellerRole, address(governor)), "only Governor holds the cancellation role");
        assertFalse(timelock.hasRole(cancellerRole, frTreasury), "proposer cannot cancel at Timelock level");
        assertFalse(timelock.hasRole(cancellerRole, guardian), "protocol guardian has no governance veto");

        bytes32 salt = bytes20(address(governor)) ^ descriptionHash;
        bytes32 operationId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(operationId), "the queued Timelock operation exists");

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, cancellerRole)
        );
        timelock.cancel(operationId);

        vm.prank(frTreasury);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, frTreasury));
        governor.cancel(targets, values, calldatas, descriptionHash);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, guardian));
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        vm.prank(alice);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertTrue(timelock.isOperationDone(operationId));
        assertEq(waterfall.protocolFeeBps(), 1_500, "the final queued action lands through an open executor");
    }

    function test_governance_governorUpgradesOnlyThroughGovernance() public {
        address newImpl = address(new FRGovernor());
        // direct upgrade attempts are rejected — only the timelock executor may
        vm.expectRevert();
        vm.prank(frTreasury);
        governor.upgradeToAndCall(newImpl, "");

        // the governance path works end-to-end
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.upgradeToAndCall, (newImpl, ""));
        string memory description = "upgrade the governor";

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        vm.prank(frTreasury);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    function test_governance_timelockPointerMigrationIsDisabledInV1() public {
        TimelockControllerUpgradeable replacement = TimelockControllerUpgradeable(payable(makeAddr("replacement")));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, alice));
        vm.prank(alice);
        governor.updateTimelock(replacement);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.updateTimelock, (replacement));
        string memory description = "attempt pointer-only timelock migration";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        vm.prank(frTreasury);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);

        vm.expectRevert(FRGovernor.Governor_TimelockMigrationDisabled.selector);
        governor.execute(targets, values, calldatas, descriptionHash);

        assertEq(governor.timelock(), address(timelock), "the original executor pointer remains bound");
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        bytes32 salt = bytes20(address(governor)) ^ descriptionHash;
        bytes32 operationId = timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);
        assertTrue(timelock.isOperationReady(operationId), "the reverted operation remains queued");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    function test_governance_timelockIsTheExecutorAndModuleAdmin() public view {
        assertEq(governor.timelock(), address(timelock));
        assertEq(address(governor.token()), address(votesAggregator), "Governor retains the votes aggregator");
        assertTrue(waterfall.hasRole(bytes32(0), address(timelock)), "timelock is module admin");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "Timelock execution remains open");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "no leftover fixture privileges");
        assertEq(governor.votingDelay(), Config.GOV_VOTING_DELAY);
        assertEq(governor.votingPeriod(), Config.GOV_VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), Config.GOV_PROPOSAL_THRESHOLD);
    }
}
