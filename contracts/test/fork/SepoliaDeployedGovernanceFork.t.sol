// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {FRGovernor} from "../../src/FRGovernor.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {Config} from "../../src/libraries/Config.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @notice Direct governance tests against the addresses produced by the Sepolia deployment,
///         isolated on the pinned chain-31337 fork. No call in this file can reach live Sepolia.
contract SepoliaDeployedGovernanceForkTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bool internal forkReady;
    uint256 internal forkBlock;
    address internal ops;
    address internal beneficiary = makeAddr("sepoliaForkGovernanceBeneficiary");
    address internal outsider = makeAddr("sepoliaForkGovernanceOutsider");

    FRGovernor internal governor;
    TimelockControllerUpgradeable internal timelock;
    GroveToken internal grove;
    MockERC20 internal stable;

    modifier onPinnedFork() {
        vm.skip(!forkReady);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_FORK_RPC_URL", string(""));
        forkBlock = vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0));
        string memory manifestPath = vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/11155111.json"));
        if (bytes(rpc).length == 0 || forkBlock == 0 || !vm.exists(manifestPath)) return;

        vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 31337, "local fork must use chain ID 31337");
        forkReady = true;

        string memory manifest = vm.readFile(manifestPath);
        uint256 manifestChainId = vm.parseJsonUint(manifest, ".chainId");
        bool localDeploymentRehearsal = vm.envOr("LOCAL_DEPLOYMENT_REHEARSAL", false);
        require(
            manifestChainId == 11155111 || (localDeploymentRehearsal && manifestChainId == 31337),
            "manifest must be Sepolia"
        );
        require(forkBlock > vm.parseJsonUint(manifest, ".deployedAtBlock"), "fork must be post-deployment");

        ops = vm.parseJsonAddress(manifest, ".frTreasury");
        governor = FRGovernor(payable(vm.parseJsonAddress(manifest, ".governor")));
        timelock = TimelockControllerUpgradeable(payable(vm.parseJsonAddress(manifest, ".timelock")));
        grove = GroveToken(vm.parseJsonAddress(manifest, ".grove"));
        stable = MockERC20(vm.parseJsonAddress(manifest, ".stable"));

        // A distinct treasury must self-delegate after deployment; the deployer cannot do it on
        // the treasury's behalf. Model that required external configuration step only in the
        // explicitly enabled local deployment rehearsal. A real Sepolia fork remains read-only
        // here and will fail loudly if the live treasury has not delegated.
        if (localDeploymentRehearsal && grove.balanceOf(ops) != 0 && grove.delegates(ops) == address(0)) {
            vm.prank(ops);
            grove.delegate(ops);
            vm.warp(block.timestamp + 1);
        }

        assertGt(address(governor).code.length, 0);
        assertGt(address(timelock).code.length, 0);
        assertGt(address(grove).code.length, 0);
        assertGt(address(stable).code.length, 0);
    }

    function test_sepoliaDeployedFork_governanceExecutesEveryPrivilegedGovernorSetterAndUpgrade() public onPinnedFork {
        address newImplementation = address(new FRGovernor());
        address oldImplementation = _implementation(address(governor));
        assertNotEq(newImplementation, oldImplementation);

        _assertGovernorPrivilegedCallsReject(outsider, newImplementation);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockControllerUpgradeable.TimelockUnauthorizedCaller.selector, outsider)
        );
        vm.prank(outsider);
        timelock.updateDelay(Config.TIMELOCK_MIN_DELAY);

        uint256 stableBefore = stable.balanceOf(beneficiary);
        // `updateTimelock` is DELIBERATELY ABSENT from this batch. Mainnet-v1 disables OZ's
        // pointer-only timelock replacement with a terminal revert (`FRGovernor.sol:80`), and its
        // own NatSpec warns "Do not schedule this selector: a valid proposal will remain queued
        // because execution rolls back atomically". Including it here did exactly that — one
        // deliberately-disabled action reverted all eight, so the suite read as a governance
        // regression when it was the design working. The disable is proved on its own below,
        // through the real governance path, which is stronger than asserting it as a setter.
        address[] memory targets = new address[](7);
        uint256[] memory values = new uint256[](7);
        bytes[] memory calldatas = new bytes[](7);
        for (uint256 i = 0; i < 5; ++i) {
            targets[i] = address(governor);
        }
        targets[5] = address(timelock);
        targets[6] = address(governor);
        calldatas[0] =
            abi.encodeCall(governor.relay, (address(stable), 0, abi.encodeCall(stable.mint, (beneficiary, 1))));
        calldatas[1] = abi.encodeCall(governor.setProposalThreshold, (governor.proposalThreshold()));
        calldatas[2] = abi.encodeCall(governor.setVotingDelay, (uint48(governor.votingDelay())));
        calldatas[3] = abi.encodeCall(governor.setVotingPeriod, (uint32(governor.votingPeriod())));
        calldatas[4] = abi.encodeCall(governor.updateQuorumNumerator, (governor.quorumNumerator()));
        calldatas[5] = abi.encodeCall(timelock.updateDelay, (timelock.getMinDelay()));
        calldatas[6] = abi.encodeCall(governor.upgradeToAndCall, (newImplementation, bytes("")));

        string memory description = "Sepolia fork: exercise all governance-only entry points";
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(ops);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(proposalId, governor.hashProposal(targets, values, calldatas, descriptionHash));
        assertEq(proposalId, governor.getProposalId(targets, values, calldatas, descriptionHash));
        assertEq(governor.proposalProposer(proposalId), ops);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.prank(ops);
        uint256 weight = governor.castVote(proposalId, 1);
        assertGt(weight, 0);
        assertTrue(governor.hasVoted(proposalId, ops));

        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        assertGt(governor.proposalEta(proposalId), 0);

        vm.warp(block.timestamp + timelock.getMinDelay());
        vm.recordLogs();
        governor.execute(targets, values, calldatas, descriptionHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(stable.balanceOf(beneficiary) - stableBefore, 1, "relay called the intended target");
        assertEq(_implementation(address(governor)), newImplementation, "governor implementation changed");
        assertEq(governor.name(), "Forest Road Governor", "proxy state survived");
        assertEq(address(governor.token()), vm.parseJsonAddress(vm.readFile(_manifestPath()), ".votesAggregator"));
        assertEq(governor.timelock(), address(timelock));
        assertEq(governor.votingDelay(), Config.GOV_VOTING_DELAY);
        assertEq(governor.votingPeriod(), Config.GOV_VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), Config.GOV_PROPOSAL_THRESHOLD);
        assertEq(governor.quorumNumerator(), Config.GOV_QUORUM_FRACTION);
        assertEq(timelock.getMinDelay(), Config.TIMELOCK_MIN_DELAY);
        assertTrue(_sawTopic(logs, keccak256("Upgraded(address)")), "upgrade event absent");
        assertTrue(_sawTopic(logs, keccak256("ProposalExecuted(uint256)")), "execution event absent");

        // The disabled timelock migration, proved on the DEPLOYED governor through the only path
        // that can reach it: a fully authorized governance proposal. `onlyGovernance` is retained
        // ahead of the terminal revert, so this cannot be shown by a direct prank — the executor
        // deque check would reject first, which is a different failure and would prove nothing.
        address[] memory migrateTargets = new address[](1);
        uint256[] memory migrateValues = new uint256[](1);
        bytes[] memory migrateCalldatas = new bytes[](1);
        migrateTargets[0] = address(governor);
        migrateCalldatas[0] = abi.encodeCall(governor.updateTimelock, (timelock));
        string memory migrateDescription = "Sepolia fork: timelock migration must remain disabled";
        bytes32 migrateHash = keccak256(bytes(migrateDescription));

        vm.prank(ops);
        uint256 migrateId = governor.propose(migrateTargets, migrateValues, migrateCalldatas, migrateDescription);
        vm.warp(block.timestamp + governor.votingDelay() + 1);
        vm.prank(ops);
        governor.castVote(migrateId, 1);
        vm.warp(block.timestamp + governor.votingPeriod() + 1);
        governor.queue(migrateTargets, migrateValues, migrateCalldatas, migrateHash);
        vm.warp(block.timestamp + timelock.getMinDelay());

        vm.expectRevert(FRGovernor.Governor_TimelockMigrationDisabled.selector);
        governor.execute(migrateTargets, migrateValues, migrateCalldatas, migrateHash);

        // And the documented consequence: the proposal is not consumed, it stays Queued forever.
        assertEq(
            uint8(governor.state(migrateId)),
            uint8(IGovernor.ProposalState.Queued),
            "a scheduled timelock migration must remain queued, never executed"
        );
        assertEq(governor.timelock(), address(timelock), "timelock pointer must be unmoved");
    }

    function test_sepoliaDeployedFork_allVoteEntryPointsSignaturesAndCancellation() public onPinnedFork {
        (address sigVoter, uint256 sigPk) = makeAddrAndKey("sepoliaForkSigVoter");
        (address extVoter, uint256 extPk) = makeAddrAndKey("sepoliaForkExtendedSigVoter");
        uint256 voterFunding = 2_000_000e18;
        vm.startPrank(ops);
        grove.transfer(sigVoter, voterFunding);
        grove.transfer(extVoter, voterFunding);
        vm.stopPrank();
        vm.prank(sigVoter);
        grove.delegate(sigVoter);
        vm.prank(extVoter);
        grove.delegate(extVoter);
        vm.warp(block.timestamp + 1);

        uint256[5] memory ids;
        for (uint256 i = 0; i < ids.length; ++i) {
            (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
                _oneAction(beneficiary, i + 10);
            vm.prank(ops);
            ids[i] = governor.propose(
                targets, values, calldatas, string.concat("Sepolia fork vote surface ", vm.toString(i))
            );
        }
        vm.warp(block.timestamp + governor.votingDelay() + 1);

        vm.prank(ops);
        assertGt(governor.castVote(ids[0], 1), 0);
        vm.prank(ops);
        assertGt(governor.castVoteWithReason(ids[1], 1, "direct reason"), 0);
        vm.prank(ops);
        assertGt(governor.castVoteWithReasonAndParams(ids[2], 1, "direct params", hex"1234"), 0);

        bytes memory ballot = _signBallot(sigPk, sigVoter, ids[3], 1);
        vm.prank(outsider);
        assertEq(governor.castVoteBySig(ids[3], 1, sigVoter, ballot), voterFunding);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, sigVoter));
        vm.prank(outsider);
        governor.castVoteBySig(ids[3], 1, sigVoter, ballot);

        string memory reason = "extended signed reason";
        bytes memory params = hex"beef";
        bytes memory extended = _signExtendedBallot(extPk, extVoter, ids[4], 1, reason, params);
        vm.prank(outsider);
        assertEq(governor.castVoteWithReasonAndParamsBySig(ids[4], 1, extVoter, reason, params, extended), voterFunding);

        (address[] memory cancelTargets, uint256[] memory cancelValues, bytes[] memory cancelCalldatas) =
            _oneAction(beneficiary, 99);
        string memory cancelDescription = "Sepolia fork pending cancellation";
        vm.prank(ops);
        uint256 cancelId = governor.propose(cancelTargets, cancelValues, cancelCalldatas, cancelDescription);
        vm.prank(ops);
        assertEq(
            governor.cancel(cancelTargets, cancelValues, cancelCalldatas, keccak256(bytes(cancelDescription))), cancelId
        );
        assertEq(uint8(governor.state(cancelId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_sepoliaDeployedFork_timelockSingleScheduleExecuteCancelAndGovernorDepositGuards()
        public
        onPinnedFork
    {
        bytes memory mintCall = abi.encodeCall(stable.mint, (beneficiary, 7));
        bytes32 salt = keccak256("sepolia fork single timelock operation");
        uint256 delay = timelock.getMinDelay();
        vm.prank(address(governor));
        timelock.schedule(address(stable), 0, mintCall, bytes32(0), salt, delay);
        bytes32 operation = timelock.hashOperation(address(stable), 0, mintCall, bytes32(0), salt);
        assertTrue(timelock.isOperation(operation));
        assertTrue(timelock.isOperationPending(operation));
        assertFalse(timelock.isOperationReady(operation));

        vm.warp(block.timestamp + delay);
        assertTrue(timelock.isOperationReady(operation));
        uint256 before = stable.balanceOf(beneficiary);
        vm.prank(outsider); // EXECUTOR_ROLE is deliberately open.
        timelock.execute(address(stable), 0, mintCall, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(operation));
        assertEq(stable.balanceOf(beneficiary) - before, 7);

        bytes32 cancelSalt = keccak256("sepolia fork cancelled timelock operation");
        vm.prank(address(governor));
        timelock.schedule(address(stable), 0, mintCall, bytes32(0), cancelSalt, delay);
        bytes32 cancelled = timelock.hashOperation(address(stable), 0, mintCall, bytes32(0), cancelSalt);
        vm.prank(address(governor));
        timelock.cancel(cancelled);
        assertFalse(timelock.isOperation(cancelled));

        address[] memory batchTargets = new address[](2);
        uint256[] memory batchValues = new uint256[](2);
        bytes[] memory batchCalldatas = new bytes[](2);
        batchTargets[0] = address(stable);
        batchTargets[1] = address(stable);
        batchCalldatas[0] = abi.encodeCall(stable.mint, (beneficiary, 11));
        batchCalldatas[1] = abi.encodeCall(stable.mint, (outsider, 13));
        bytes32 batchSalt = keccak256("sepolia fork timelock batch operation");
        vm.prank(address(governor));
        timelock.scheduleBatch(batchTargets, batchValues, batchCalldatas, bytes32(0), batchSalt, delay);
        bytes32 batchOperation =
            timelock.hashOperationBatch(batchTargets, batchValues, batchCalldatas, bytes32(0), batchSalt);
        assertTrue(timelock.isOperationPending(batchOperation));
        vm.warp(block.timestamp + delay);
        uint256 beneficiaryBeforeBatch = stable.balanceOf(beneficiary);
        uint256 outsiderBeforeBatch = stable.balanceOf(outsider);
        vm.prank(outsider);
        timelock.executeBatch(batchTargets, batchValues, batchCalldatas, bytes32(0), batchSalt);
        assertTrue(timelock.isOperationDone(batchOperation));
        assertEq(stable.balanceOf(beneficiary) - beneficiaryBeforeBatch, 11);
        assertEq(stable.balanceOf(outsider) - outsiderBeforeBatch, 13);

        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        (bool ok, bytes memory returndata) = address(governor).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(returndata), IGovernor.GovernorDisabledDeposit.selector);
        vm.expectRevert(IGovernor.GovernorDisabledDeposit.selector);
        governor.onERC721Received(outsider, outsider, 1, "");
        vm.expectRevert(IGovernor.GovernorDisabledDeposit.selector);
        governor.onERC1155Received(outsider, outsider, 1, 1, "");
        vm.expectRevert(IGovernor.GovernorDisabledDeposit.selector);
        governor.onERC1155BatchReceived(outsider, outsider, new uint256[](0), new uint256[](0), "");
    }

    function _assertGovernorPrivilegedCallsReject(address caller, address newImplementation) internal {
        bytes memory expected = abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, caller);
        uint256 proposalThreshold = governor.proposalThreshold();
        uint48 votingDelay = uint48(governor.votingDelay());
        uint32 votingPeriod = uint32(governor.votingPeriod());
        uint256 quorumNumerator = governor.quorumNumerator();
        vm.startPrank(caller);
        vm.expectRevert(expected);
        governor.relay(address(stable), 0, "");
        vm.expectRevert(expected);
        governor.setProposalThreshold(proposalThreshold);
        vm.expectRevert(expected);
        governor.setVotingDelay(votingDelay);
        vm.expectRevert(expected);
        governor.setVotingPeriod(votingPeriod);
        vm.expectRevert(expected);
        governor.updateQuorumNumerator(quorumNumerator);
        vm.expectRevert(expected);
        governor.updateTimelock(timelock);
        vm.expectRevert(expected);
        governor.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function _oneAction(address recipient, uint256 amount)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(stable);
        calldatas[0] = abi.encodeCall(stable.mint, (recipient, amount));
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _signBallot(uint256 pk, address voter, uint256 proposalId, uint8 support)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, governor.nonces(voter)));
        return _sign(pk, keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash)));
    }

    function _signExtendedBallot(
        uint256 pk,
        address voter,
        uint256 proposalId,
        uint8 support,
        string memory reason,
        bytes memory params
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                governor.EXTENDED_BALLOT_TYPEHASH(),
                proposalId,
                support,
                voter,
                governor.nonces(voter),
                keccak256(bytes(reason)),
                keccak256(params)
            )
        );
        return _sign(pk, keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash)));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _sawTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/11155111.json"));
    }
}
