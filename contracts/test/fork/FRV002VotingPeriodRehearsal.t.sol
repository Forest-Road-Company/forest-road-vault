// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

interface IGovernor {
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256);
    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        external
        returns (uint256);
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256);
    function castVote(uint256 proposalId, uint8 support) external returns (uint256);
    function state(uint256 proposalId) external view returns (uint8);
    function proposalSnapshot(uint256 proposalId) external view returns (uint256);
    function proposalDeadline(uint256 proposalId) external view returns (uint256);
    function votingDelay() external view returns (uint256);
    function votingPeriod() external view returns (uint256);
    function proposalThreshold() external view returns (uint256);
    function setVotingPeriod(uint32 newVotingPeriod) external;
}

interface ITimelock {
    function getMinDelay() external view returns (uint256);
}

interface ICuratorPreArm {
    function custodyPreArmDuration() external view returns (uint64);
    function custodyPreArmGovernancePath() external view returns (uint64);
    function custodyPreArmCoversLiveGovernancePath() external view returns (bool);
}

/// @notice Rehearsal for FRV-002: shorten `votingPeriod` from 7 days to 2 days.
///
///         WHY A FULL-FLOW REHEARSAL AND NOT A SPOT SIMULATION. `setVotingPeriod` is
///         `onlyGovernance`. OZ's `_checkGovernance` pops the expected call hash from a deque that
///         only `Governor.execute` fills, so calling it directly, even AS the timelock, reverts
///         with `panic 0x31` (`.pop()` on an empty array). Measured against live mainnet before
///         this test was written. The only way to prove the change lands is to run the whole
///         propose, vote, queue, execute path.
///
///         WHAT THIS PROVES BEYOND "IT EXECUTES". The same parameter feeds
///         `CuratorModule._governancePath()`, which guards curator capital via the guardian
///         custody pre-arm. That function takes `max(Config floor, live reading)`, and the Config
///         floor is the LAUNCH path of 1 + 7 + 2 = 10 days. So shortening the live period must NOT
///         shorten the pre-arm. This test asserts that explicitly, because if it ever stopped
///         holding, the proposal would be quietly weakening the lock on curator first-loss
///         capital, which is the layer DV-03 was raised about.
contract FRV002VotingPeriodRehearsal is Test {
    address constant GOVERNOR = 0x0A1c2A0deD7541c5C6ffdB0A0E70F151d88422aF;
    address constant TIMELOCK = 0x263289d62352f9326456d1430466337484c806Dc;
    address constant TREASURY = 0x0687a13c490B2573d4666fb3a7c21826a621215E;
    address constant CURATOR = 0x30652De57A40448E22ee62C36F327656eAEE94FE;

    uint32 constant NEW_VOTING_PERIOD = 2 days;
    uint256 constant FORK_BLOCK = 25_855_700;

    /// @dev The `contracts` CI job carries no fork RPC secret; skip there rather than fail.
    bool internal forkReady;

    modifier onFork() {
        vm.skip(!forkReady);
        _;
    }

    function setUp() public {
        string memory forkUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) return;
        vm.createSelectFork(forkUrl, FORK_BLOCK);
        forkReady = true;
    }

    function _proposal()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = GOVERNOR;
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint32)", NEW_VOTING_PERIOD);
    }

    /// @dev Everything that must already be true before a human signs anything.
    function test_preconditions_hold_on_live_state() public onFork {
        assertEq(IGovernor(GOVERNOR).votingPeriod(), 7 days, "live voting period is not the launch value");
        assertEq(IGovernor(GOVERNOR).votingDelay(), 1 days, "live voting delay is not the launch value");
        assertEq(ITimelock(TIMELOCK).getMinDelay(), 2 days, "timelock min delay is not 2 days");

        // The pre-arm is derived from max(Config floor, live path). Both are 10 days today.
        assertEq(ICuratorPreArm(CURATOR).custodyPreArmGovernancePath(), 10 days, "path is not the launch 10 days");
        assertEq(ICuratorPreArm(CURATOR).custodyPreArmDuration(), 15 days, "pre-arm is not 15 days");
        assertTrue(ICuratorPreArm(CURATOR).custodyPreArmCoversLiveGovernancePath(), "pre-arm must outlast the path");
    }

    /// @dev `setVotingPeriod` is unreachable outside a governance execution, even AS the timelock:
    ///      OZ's `_checkGovernance` pops from a deque only `execute` fills. This pins the reason a
    ///      spot simulation is not evidence, so nobody later "simplifies" this test into one.
    function test_setVotingPeriod_is_unreachable_outside_governance() public onFork {
        vm.prank(TIMELOCK);
        vm.expectRevert();
        IGovernor(GOVERNOR).setVotingPeriod(NEW_VOTING_PERIOD);

        // and an unrelated caller is rejected as a non-executor
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IGovernor(GOVERNOR).setVotingPeriod(NEW_VOTING_PERIOD);

        assertEq(IGovernor(GOVERNOR).votingPeriod(), 7 days, "period must be untouched by either attempt");
    }

    function test_rehearsal_the_full_governance_path() public onFork {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposal();
        string memory description = "FRV-002: shorten votingPeriod to 2 days";
        bytes32 descriptionHash = keccak256(bytes(description));

        assertGe(IGovernor(GOVERNOR).proposalThreshold(), 0, "threshold read failed");

        vm.prank(TREASURY);
        uint256 id = IGovernor(GOVERNOR).propose(targets, values, calldatas, description);

        // Pending until the voting delay elapses.
        assertEq(IGovernor(GOVERNOR).state(id), 0, "proposal should be Pending");
        vm.warp(IGovernor(GOVERNOR).proposalSnapshot(id) + 1);
        assertEq(IGovernor(GOVERNOR).state(id), 1, "proposal should be Active");

        vm.prank(TREASURY);
        IGovernor(GOVERNOR).castVote(id, 1);

        vm.warp(IGovernor(GOVERNOR).proposalDeadline(id) + 1);
        assertEq(IGovernor(GOVERNOR).state(id), 4, "proposal should be Succeeded");

        // queue and execute are permissionless; prove that by calling from an unrelated address.
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        IGovernor(GOVERNOR).queue(targets, values, calldatas, descriptionHash);
        assertEq(IGovernor(GOVERNOR).state(id), 5, "proposal should be Queued");

        vm.warp(block.timestamp + ITimelock(TIMELOCK).getMinDelay() + 1);
        vm.prank(anyone);
        IGovernor(GOVERNOR).execute(targets, values, calldatas, descriptionHash);
        assertEq(IGovernor(GOVERNOR).state(id), 7, "proposal should be Executed");

        assertEq(IGovernor(GOVERNOR).votingPeriod(), NEW_VOTING_PERIOD, "voting period did not change");
    }

    /// @dev THE SAFETY PROPERTY. Shortening the live period must not shorten the curator pre-arm,
    ///      because `_governancePath()` floors on `Config`'s launch path of 10 days. If this ever
    ///      fails, FRV-002 is weakening the lock on curator first-loss capital.
    function test_curatorPreArm_is_unchanged_by_the_shorter_period() public onFork {
        uint64 durationBefore = ICuratorPreArm(CURATOR).custodyPreArmDuration();
        uint64 pathBefore = ICuratorPreArm(CURATOR).custodyPreArmGovernancePath();

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposal();
        string memory description = "FRV-002: shorten votingPeriod to 2 days";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(TREASURY);
        uint256 id = IGovernor(GOVERNOR).propose(targets, values, calldatas, description);
        vm.warp(IGovernor(GOVERNOR).proposalSnapshot(id) + 1);
        vm.prank(TREASURY);
        IGovernor(GOVERNOR).castVote(id, 1);
        vm.warp(IGovernor(GOVERNOR).proposalDeadline(id) + 1);
        IGovernor(GOVERNOR).queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + ITimelock(TIMELOCK).getMinDelay() + 1);
        IGovernor(GOVERNOR).execute(targets, values, calldatas, descriptionHash);

        assertEq(IGovernor(GOVERNOR).votingPeriod(), NEW_VOTING_PERIOD, "precondition: period changed");

        assertEq(
            ICuratorPreArm(CURATOR).custodyPreArmGovernancePath(),
            pathBefore,
            "governance path moved: the Config floor no longer dominates"
        );
        assertEq(
            ICuratorPreArm(CURATOR).custodyPreArmDuration(),
            durationBefore,
            "curator pre-arm shortened: FRV-002 would weaken the curator capital lock"
        );
        assertTrue(
            ICuratorPreArm(CURATOR).custodyPreArmCoversLiveGovernancePath(), "pre-arm must still outlast the live path"
        );
    }
}
