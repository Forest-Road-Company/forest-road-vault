// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {DefaultManager} from "../src/DefaultManager.sol";

/// @notice Shared implementation-runtime reconstruction used by the validator and its worker.
/// @dev The reference manager is created locally, outside any broadcast. It identifies the
///      manager's three immutable groups without relying on compiler AST identifiers or masking
///      any bytes of the implementation being checked.
abstract contract ImplementationRuntimeHashCore is Script {
    struct CodeReference {
        uint256 length;
        uint256 start;
    }

    DefaultManager private immutable referenceManager = new DefaultManager();

    /// @notice Computes one expected implementation runtime.
    /// @dev All ordinary UUPS implementations have only their inherited `__self` immutable.
    ///      DefaultManager additionally constructs its calculator and factory at nonces 1 and 2.
    ///      Unknown immutable layouts fail closed. Library links and metadata remain unchanged.
    function implementationRuntimeHash(string memory artifact, address implementation, bool isManager)
        public
        view
        returns (bytes32)
    {
        bytes memory runtime = vm.getDeployedCode(artifact);
        string memory json = vm.readFile(vm.getArtifactPathByCode(vm.getCode(artifact)));
        string memory root = ".deployedBytecode.immutableReferences";
        string[] memory groups = vm.parseJsonKeys(json, root);
        require(groups.length == (isManager ? 3 : 1), "ValidateMainnet: unsupported immutable layout");
        uint256 seen;
        for (uint256 i; i < groups.length; ++i) {
            CodeReference[] memory refs =
                abi.decode(vm.parseJson(json, string.concat(root, ".", groups[i])), (CodeReference[]));
            require(refs.length != 0, "ValidateMainnet: empty immutable group");
            uint256 kind = isManager ? _managerImmutableKind(refs) : 1;
            require(seen & kind == 0, "ValidateMainnet: duplicate immutable group");
            seen |= kind;
            address value = kind == 1 ? implementation : vm.computeCreateAddress(implementation, kind == 2 ? 1 : 2);
            for (uint256 j; j < refs.length; ++j) {
                uint256 start = refs[j].start;
                require(
                    refs[j].length == 32 && start + 32 <= runtime.length, "ValidateMainnet: invalid immutable range"
                );
                bytes32 original;
                assembly ("memory-safe") {
                    original := mload(add(add(runtime, 32), start))
                }
                require(original == bytes32(0), "ValidateMainnet: nonzero immutable template");
                assembly ("memory-safe") {
                    mstore(add(add(runtime, 32), start), value)
                }
            }
        }
        require(seen == (isManager ? 7 : 1), "ValidateMainnet: incomplete immutable layout");
        return keccak256(runtime);
    }

    function _managerImmutableKind(CodeReference[] memory refs) private view returns (uint256 kind) {
        address referenceAddress = address(referenceManager);
        bytes memory runtime = referenceAddress.code;
        bytes32 first;
        for (uint256 i; i < refs.length; ++i) {
            uint256 start = refs[i].start;
            require(refs[i].length == 32 && start + 32 <= runtime.length, "ValidateMainnet: invalid reference range");
            bytes32 value;
            assembly ("memory-safe") {
                value := mload(add(add(runtime, 32), start))
            }
            if (i == 0) first = value;
            else require(value == first, "ValidateMainnet: inconsistent reference immutable");
        }
        if (first == bytes32(uint256(uint160(referenceAddress)))) return 1;
        if (first == bytes32(uint256(uint160(vm.computeCreateAddress(referenceAddress, 1))))) return 2;
        if (first == bytes32(uint256(uint160(vm.computeCreateAddress(referenceAddress, 2))))) return 4;
        revert("ValidateMainnet: unknown reference immutable");
    }
}

/// @dev Gives each artifact reconstruction its own call frame. The worker is a local validation
///      helper and is never part of a deployment broadcast.
contract ImplementationRuntimeHashWorker is ImplementationRuntimeHashCore {}

/// @notice Binds implementation runtime templates to their constructor-assigned addresses.
/// @dev Calling a separate worker both releases each artifact's JSON/parser memory before the
///      next implementation and avoids calling `this`, whose address is ephemeral under
///      `forge script` and is therefore rejected by Foundry's script safety check.
abstract contract ImplementationRuntimeHash is ImplementationRuntimeHashCore {
    ImplementationRuntimeHashWorker private immutable runtimeHashWorker = new ImplementationRuntimeHashWorker();

    function _implementationRuntimeHash(string memory artifact, address implementation, bool isManager)
        internal
        view
        returns (bytes32)
    {
        return runtimeHashWorker.implementationRuntimeHash(artifact, implementation, isManager);
    }
}
