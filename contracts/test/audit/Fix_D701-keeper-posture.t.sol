// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployMainnet} from "../../script/DeployMainnet.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @dev Exposes the internal mainnet context and validator so the posture can be asserted against
///      the REAL functions rather than a re-implementation of them.
contract MainnetProbe is DeployMainnet {
    function ctx(address deployer) external view returns (Deploy.Ctx memory) {
        return _mainnetContext(deployer);
    }

    function validate(Deploy.Ctx memory c) external view {
        _validatePrincipals(c);
    }

    function principalHash(Deploy.Ctx memory c) external pure returns (bytes32) {
        return _principalSetHash(c);
    }
}

/// @title Fix_D701 — the settlement keeper is a real, distinct, validated second holder
/// @notice AUDIT FIX (D7-01 round 5, BLOCKING). `DeployMainnet._mainnetContext` populated nine
///         fields and never `queueKeeper`, so it stayed `address(0)` and `Deploy._wire` executed
///         `grantRole(SETTLEMENT_KEEPER_ROLE, address(0))` — which OpenZeppelin accepts silently.
///
///         Consequences, all real: the documented two-holder posture shipped as ONE usable holder
///         on the protocol's ONLY senior exit; a monitor counting `RoleGranted` events saw two; and
///         `keepOpsAdmin = false` means a regrant after handover costs a Governor proposal plus the
///         timelock delay with redemptions frozen throughout. Nothing in the deploy or validation
///         chain detected it, and the `MAINNET_APPROVED_DEPLOYMENT_HASH` gate was blind to it
///         because `_principalSetHash` did not commit to the keeper either.
///
///         Three of four round-5 adversaries plus the adjudicator found this independently.
contract Fix_D701KeeperPosture is Test {
    MainnetProbe internal probe;
    address internal constant DEPLOYER = address(0xD3);
    address internal constant OPS = address(0x055);
    address internal constant PROPOSAL_GUARDIAN = address(0x056);
    address internal constant KEEPER = address(0xCEE);

    function setUp() public {
        probe = new MainnetProbe();
        vm.etch(OPS, hex"600160005260206000f3"); // ops must be a deployed contract
        vm.etch(PROPOSAL_GUARDIAN, hex"600160005260206000f3");
        vm.etch(address(0xCA5), hex"600160005260206000f3"); // anchor curator likewise
    }

    function _setMainnetEnv() internal {
        vm.setEnv("MAINNET_OPS_MULTISIG", vm.toString(OPS));
        vm.setEnv("MAINNET_PROPOSAL_GUARDIAN", vm.toString(PROPOSAL_GUARDIAN));
        vm.setEnv("MAINNET_FR_TREASURY", vm.toString(address(0xF12)));
        vm.setEnv("MAINNET_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("MAINNET_ANCHOR_CURATOR", vm.toString(address(0xCA5)));
        vm.setEnv("MAINNET_QUEUE_KEEPER", vm.toString(KEEPER));
        vm.setEnv("MAINNET_ATTESTER_1", vm.toString(address(0xA771)));
        vm.setEnv("MAINNET_ATTESTER_2", vm.toString(address(0xA772)));
    }

    function _ctx() internal pure returns (Deploy.Ctx memory c) {
        c.deployer = DEPLOYER;
        c.opsAdmin = OPS;
        c.proposalGuardian = PROPOSAL_GUARDIAN;
        c.frTreasury = address(0xF12);
        c.feeRecipient = address(0xFEE);
        c.anchorCurator = address(0xCA5);
        c.queueKeeper = KEEPER;
        c.attester1 = address(0xA771);
        c.attester2 = address(0xA772);
    }

    /// @notice THE REGRESSION. `_mainnetContext` must populate `queueKeeper`. Before the fix this
    ///         returned `address(0)` and every downstream guard was blind to it.
    function test_d701_mainnetContextPopulatesTheSettlementKeeper() public {
        // This is the only test that mutates MAINNET_QUEUE_KEEPER. Keeping the valid and invalid
        // reads in one test avoids races through Foundry's process-global environment when test
        // functions execute in parallel.
        _setMainnetEnv();
        Deploy.Ctx memory c = probe.ctx(DEPLOYER);
        assertEq(c.queueKeeper, KEEPER, "_mainnetContext must populate queueKeeper");
        assertTrue(c.queueKeeper != address(0), "the keeper must never default to the zero address");

        // An unset keeper must ABORT the deploy. Foundry has no `removeEnv` cheatcode, so an
        // unresolved expansion is the closest process-local representation of an absent value and
        // cannot parse as an address. This proves there is no zero/default-principal fallback.
        vm.setEnv("MAINNET_QUEUE_KEEPER", "$D701_INTENTIONALLY_MISSING_QUEUE_KEEPER");
        (bool ok,) = address(probe).call(abi.encodeCall(probe.ctx, (DEPLOYER)));
        // `vm.setEnv` is process-global, so restore it before asserting the captured failure.
        vm.setEnv("MAINNET_QUEUE_KEEPER", vm.toString(KEEPER));
        assertFalse(ok, "an unset MAINNET_QUEUE_KEEPER must abort context construction");
    }

    /// @notice The validator must refuse a zero keeper.
    function test_d701_validatorRefusesAZeroKeeper() public {
        Deploy.Ctx memory c = _ctx();
        c.queueKeeper = address(0);
        vm.expectRevert(bytes("DeployMainnet: zero settlement keeper"));
        probe.validate(c);
    }

    /// @notice ...and must refuse a keeper collapsed onto the backstop, which reproduces the
    ///         single-holder posture this fix exists to prevent.
    function test_d701_validatorRefusesTheKeeperCollapsedOntoOps() public {
        Deploy.Ctx memory c = _ctx();
        c.queueKeeper = c.opsAdmin;
        vm.expectRevert(bytes("DeployMainnet: settlement keeper must be a second holder"));
        probe.validate(c);
    }

    /// @notice ...and must refuse the deployer, which the handover strips — leaving zero holders.
    function test_d701_validatorRefusesTheDeployerAsKeeper() public {
        Deploy.Ctx memory c = _ctx();
        c.queueKeeper = c.deployer;
        vm.expectRevert(bytes("DeployMainnet: settlement keeper must not be the deployer"));
        probe.validate(c);
    }

    /// @notice The ceremony hash must COMMIT to the keeper. Without this the broadcast
    ///         authorization gate cannot pin who controls the sole senior exit, and a keeper swap
    ///         would not rotate `MAINNET_APPROVED_DEPLOYMENT_HASH`.
    function test_d701_principalSetHashCommitsToTheKeeper() public view {
        Deploy.Ctx memory c = _ctx();

        // A memory-to-memory struct assignment aliases the same allocation, so obtain an
        // independent context before changing the keeper.
        Deploy.Ctx memory other = _ctx();
        other.queueKeeper = address(0xBEE);

        assertTrue(c.queueKeeper != other.queueKeeper, "precondition: two different keepers");
        // Every other principal is identical, so any hash difference is attributable to the keeper.
        assertEq(c.opsAdmin, other.opsAdmin, "control: ops unchanged");
        assertEq(c.frTreasury, other.frTreasury, "control: treasury unchanged");
        assertNotEq(
            probe.principalHash(c),
            probe.principalHash(other),
            "changing only the settlement keeper must rotate the principal-set hash"
        );
    }

    function test_d701_validatorRefusesAContractAsTheHotKeeper() public {
        Deploy.Ctx memory c = _ctx();
        vm.etch(c.queueKeeper, hex"600160005260206000f3");
        vm.expectRevert(bytes("DeployMainnet: settlement keeper must be an EOA"));
        probe.validate(c);
    }

    function test_d701_validatorRefusesAnAttesterKeeperCollision() public {
        Deploy.Ctx memory c = _ctx();
        c.queueKeeper = c.attester1;
        vm.expectRevert(bytes("DeployMainnet: settlement keeper must be an isolated key"));
        probe.validate(c);
    }
}
