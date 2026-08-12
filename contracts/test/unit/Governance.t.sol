// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

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

    /// @dev G1c regression: this test replaces the former premise that a queued operation was
    ///      deliberately unstoppable. The approved proposal guardian reaches the Governor's
    ///      Timelock cancellation role without receiving that role directly.
    function test_governance_proposalGuardianCanCancelQueued() public {
        address[] memory targets = new address[](1);
        targets[0] = address(waterfall);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(waterfall.setProtocolFee, (1_500));
        string memory description = "guardian veto regression";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        vm.prank(frTreasury);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        assertEq(governor.proposalGuardian(), guardian, "approved veto principal");
        assertFalse(
            timelock.hasRole(timelock.CANCELLER_ROLE(), guardian), "guardian must route cancellation through Governor"
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, proposalId, alice));
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.prank(guardian);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(waterfall.protocolFeeBps(), 1_000, "vetoed action must never land");
    }

    /// @notice H-2: the veto principal cannot entrench itself by cancelling the one standalone
    ///         proposal whose only effect is to rotate that principal.
    function test_governance_guardianCannotVetoItsOwnStandaloneRotation() public {
        address replacement = makeAddr("replacementProposalGuardian");
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(governor.setProposalGuardian, (replacement));
        string memory description = "rotate compromised proposal guardian";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(block.timestamp + Config.GOV_VOTING_DELAY + 1);
        vm.prank(frTreasury);
        governor.castVote(proposalId, 1);
        vm.warp(block.timestamp + Config.GOV_VOTING_PERIOD + 1);
        governor.queue(targets, values, calldatas, descriptionHash);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(FRGovernor.Governor_GuardianCannotCancelOwnRotation.selector, proposalId, guardian)
        );
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.proposalGuardian(), replacement, "governance could not remove the veto principal");
    }

    /// @notice P-41: non-canonical ABI padding must not disguise an unexecutable call as the
    ///         standalone guardian rotation that is exempt from the guardian's veto.
    function test_governance_guardianCanVetoDirtyPaddedPseudoRotation() public {
        address replacement = makeAddr("dirtyPaddedReplacementGuardian");
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        uint256 dirtyAddressWord = (uint256(1) << 160) | uint256(uint160(replacement));
        calldatas[0] = abi.encodePacked(governor.setProposalGuardian.selector, bytes32(dirtyAddressWord));
        assertEq(calldatas[0].length, 36, "the malformed call retains the rotation-shaped length");

        string memory description = "dirty-padded pseudo-rotation";
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(frTreasury);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.prank(guardian);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_governance_zeroProposalGuardianRevertsAtGenesis() public {
        address implementation = address(new FRGovernor());
        IVotes votesSource = governor.token();
        vm.expectRevert(FRGovernor.Governor_ZeroProposalGuardian.selector);
        new ERC1967Proxy(implementation, abi.encodeCall(FRGovernor.initialize, (votesSource, timelock, address(0))));
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

    function test_governance_timelockIsTheExecutorAndModuleAdmin() public view {
        assertEq(governor.timelock(), address(timelock));
        assertTrue(waterfall.hasRole(bytes32(0), address(timelock)), "timelock is module admin");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "no leftover fixture privileges");
        assertEq(governor.votingDelay(), Config.GOV_VOTING_DELAY);
        assertEq(governor.votingPeriod(), Config.GOV_VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), Config.GOV_PROPOSAL_THRESHOLD);
        assertEq(governor.proposalGuardian(), guardian);
    }
}
