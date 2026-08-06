// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AttestationOracle} from "../src/AttestationOracle.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice ONE-OFF: in-place UUPS upgrade of the deployed AttestationOracle to source parity,
///         removing `resetValuationWatermark` (owner decision 2026-07-22). The H-02 anti-rollback
///         watermark and all oracle STORAGE are unchanged, so no reinitializer is needed.
///
///         TESTNET ONLY. Hard-reverts chain-id 1 (CLAUDE.md prime directive 1). Uses the RETAINED
///         ops-admin path deliberately (the deployer holds the oracle's DEFAULT_ADMIN under
///         KEEP_OPS_ADMIN, so it self-grants UPGRADER, upgrades, then RENOUNCES UPGRADER to restore
///         the validated posture where only the timelock holds it). This is the exact retained-admin
///         bypass the pre-mainnet handover (owner decision #10) removes before real capital.
contract UpgradeOracle is Script {
    function run() external {
        require(block.chainid != 1, "NEVER MAINNET");
        require(block.chainid == 11155111, "Sepolia only");

        string memory manifest = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        address oracleProxy = vm.parseJsonAddress(manifest, ".oracle");
        uint256 pk = vm.envUint("TESTNET_DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);

        AttestationOracle oracle = AttestationOracle(oracleProxy);
        require(oracle.hasRole(0x00, me), "deployer lacks oracle DEFAULT_ADMIN"); // DEFAULT_ADMIN_ROLE == 0x00

        console2.log("oracle proxy:", oracleProxy);
        console2.log("caller (deployer):", me);

        vm.startBroadcast(pk);

        // 1) self-grant UPGRADER (deployer is DEFAULT_ADMIN, which administers UPGRADER)
        bool hadUpgrader = oracle.hasRole(Roles.UPGRADER_ROLE, me);
        if (!hadUpgrader) oracle.grantRole(Roles.UPGRADER_ROLE, me);

        // 2) deploy the new implementation (constructor calls _disableInitializers)
        AttestationOracle newImpl = new AttestationOracle();

        // 3) upgrade in place; empty call data (no new storage, no reinitializer)
        oracle.upgradeToAndCall(address(newImpl), "");

        // 4) restore the posture: only the timelock should hold UPGRADER (unless it already did here)
        if (!hadUpgrader) oracle.renounceRole(Roles.UPGRADER_ROLE, me);

        vm.stopBroadcast();

        console2.log("new implementation:", address(newImpl));
        console2.log("UPGRADER restored (deployer holds it):", oracle.hasRole(Roles.UPGRADER_ROLE, me));
        // AUDIT F-03: this one-off does NOT rewrite the manifest. After a broadcast the operator MUST
        // update `impl_oracle` in deployments/<chainid>.json to `address(newImpl)` above, else the
        // manifest's provenance (used for Etherscan verification and future upgrade tooling) goes
        // stale while the proxy is correct. (Done for the 2026-07-22 run.)
        console2.log("ACTION: set manifest impl_oracle to the new implementation above.");
    }
}
