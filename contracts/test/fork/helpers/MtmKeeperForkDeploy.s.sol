// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Deploy} from "../../../script/Deploy.s.sol";

/// @notice Disposable full-stack deployment used only by the TypeScript keeper fork E2E.
/// @dev The `anvil_nodeInfo` RPC assertion is deliberate: even though this harness uses chain ID
///      1 so the production keeper follows its real mainnet path, it cannot run against an
///      ordinary Ethereum RPC. No private key is embedded; the E2E generates an ephemeral key and
///      supplies it through the child process environment.
contract MtmKeeperForkDeploy is Deploy {
    bytes32 private constant FORK_CONFIRMATION = keccak256("FOREST_ROAD_DISPOSABLE_ANVIL_KEEPER_FORK");

    function run() external override {
        require(block.chainid == 1, "MtmKeeperForkDeploy: chain 1 fork required");
        require(vm.rpc("anvil_nodeInfo", "[]").length != 0, "MtmKeeperForkDeploy: Anvil RPC required");
        require(
            keccak256(bytes(vm.envString("MTM_KEEPER_FORK_CONFIRMATION"))) == FORK_CONFIRMATION,
            "MtmKeeperForkDeploy: confirmation missing"
        );
        require(_isBroadcasting(), "MtmKeeperForkDeploy: --broadcast required");

        uint256 deployerKey = vm.envUint("MTM_KEEPER_FORK_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address attester2 = vm.envAddress("MTM_KEEPER_FORK_ATTESTER_2");
        require(attester2 != address(0) && attester2 != deployer, "MtmKeeperForkDeploy: attester separation");

        Ctx memory c = Ctx({
            deployer: deployer,
            opsAdmin: deployer,
            queueKeeper: deployer,
            frTreasury: deployer,
            feeRecipient: deployer,
            anchorCurator: deployer,
            attester1: deployer,
            attester2: attester2,
            keepOpsAdmin: true,
            attester2Derived: false
        });

        vm.startBroadcast(deployerKey);
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);
        vm.stopBroadcast();

        _writeManifest(d, c);
    }

    function _manifestPath() internal pure override returns (string memory) {
        return "deployments/mtm-keeper-fork.json";
    }
}
