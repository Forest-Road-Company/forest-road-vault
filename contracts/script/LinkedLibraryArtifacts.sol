// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {VmSafe} from "forge-std/Vm.sol";
import {BridgeAccrualLib} from "../src/libraries/BridgeAccrualLib.sol";
import {ControllerAccrualLib} from "../src/libraries/ControllerAccrualLib.sol";
import {DefaultAccrualLib} from "../src/libraries/DefaultAccrualLib.sol";
import {DefaultBackstopLib} from "../src/libraries/DefaultBackstopLib.sol";
import {DefaultInitLib} from "../src/libraries/DefaultInitLib.sol";
import {DefaultLossLib} from "../src/libraries/DefaultLossLib.sol";
import {ReserveAccrualCreditLib} from "../src/libraries/ReserveAccrualCreditLib.sol";
import {ReserveAccrualLib} from "../src/libraries/ReserveAccrualLib.sol";
import {ReserveAccrualServiceLib} from "../src/libraries/ReserveAccrualServiceLib.sol";
import {ReserveAccrualViewsLib} from "../src/libraries/ReserveAccrualViewsLib.sol";
import {ReserveCascadeLib} from "../src/libraries/ReserveCascadeLib.sol";
import {ReserveCreditLib} from "../src/libraries/ReserveCreditLib.sol";
import {ReserveIncidentLib} from "../src/libraries/ReserveIncidentLib.sol";
import {ReserveMigrationLib} from "../src/libraries/ReserveMigrationLib.sol";
import {ReserveRoundingLib} from "../src/libraries/ReserveRoundingLib.sol";
import {ReserveWiringLib} from "../src/libraries/ReserveWiringLib.sol";
import {VaultAccrualLib} from "../src/libraries/VaultAccrualLib.sol";
import {VaultFeeMath} from "../src/libraries/VaultFeeMath.sol";
import {WaterfallAccrualLib} from "../src/libraries/WaterfallAccrualLib.sol";

/// @notice Records and checks the linked libraries used by the deployment artifacts.
/// @dev This helper runs in local deployment/validation tooling. It performs no library calls.
library LinkedLibraryArtifacts {
    struct Entry {
        string name;
        address implementation;
    }

    /// @notice A linked address does not contain the compiled library runtime.
    error LibraryRuntimeMismatch(string name, address implementation, bytes32 expectedHash, bytes32 actualHash);
    /// @notice The compiler emitted an unsupported library address guard.
    error LibraryTemplateInvalid(string name);

    VmSafe private constant VM = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The manifest test discovers links from compiler artifacts, including links within
    ///      these libraries. A new or missing entry must therefore fail that independent test.
    function entries() internal pure returns (Entry[] memory a) {
        a = new Entry[](19);
        a[0] = Entry("BridgeAccrualLib", address(BridgeAccrualLib));
        a[1] = Entry("ControllerAccrualLib", address(ControllerAccrualLib));
        a[2] = Entry("DefaultAccrualLib", address(DefaultAccrualLib));
        a[3] = Entry("DefaultBackstopLib", address(DefaultBackstopLib));
        a[4] = Entry("DefaultInitLib", address(DefaultInitLib));
        a[5] = Entry("DefaultLossLib", address(DefaultLossLib));
        a[6] = Entry("ReserveAccrualCreditLib", address(ReserveAccrualCreditLib));
        a[7] = Entry("ReserveAccrualLib", address(ReserveAccrualLib));
        a[8] = Entry("ReserveAccrualServiceLib", address(ReserveAccrualServiceLib));
        a[9] = Entry("ReserveAccrualViewsLib", address(ReserveAccrualViewsLib));
        a[10] = Entry("ReserveCascadeLib", address(ReserveCascadeLib));
        a[11] = Entry("ReserveCreditLib", address(ReserveCreditLib));
        a[12] = Entry("ReserveIncidentLib", address(ReserveIncidentLib));
        a[13] = Entry("ReserveRoundingLib", address(ReserveRoundingLib));
        a[14] = Entry("ReserveWiringLib", address(ReserveWiringLib));
        a[15] = Entry("VaultAccrualLib", address(VaultAccrualLib));
        a[16] = Entry("VaultFeeMath", address(VaultFeeMath));
        a[17] = Entry("WaterfallAccrualLib", address(WaterfallAccrualLib));
        a[18] = Entry("ReserveMigrationLib", address(ReserveMigrationLib));
    }

    /// @notice Add each linked address and its checked runtime hash to the manifest serializer.
    function record(string memory objectKey) internal {
        Entry[] memory libraries = entries();
        for (uint256 i; i < libraries.length; ++i) {
            Entry memory entry = libraries[i];
            bytes32 codeHash = _validate(entry);
            VM.serializeAddress(objectKey, string.concat("lib_", entry.name), entry.implementation);
            VM.serializeBytes32(objectKey, string.concat("libRuntimeHash_", entry.name), codeHash);
        }
    }

    /// @notice Refuse any missing or changed library even when an implementation's link is correct.
    function validate() internal view {
        Entry[] memory libraries = entries();
        for (uint256 i; i < libraries.length; ++i) {
            _validate(libraries[i]);
        }
    }

    function _validate(Entry memory entry) private view returns (bytes32 expectedHash) {
        bytes memory runtime = VM.getDeployedCode(string.concat(entry.name, ".sol:", entry.name));
        // Solidity libraries start with PUSH20 of their own address as the direct-call guard.
        if (runtime.length < 21 || runtime[0] != bytes1(0x73)) revert LibraryTemplateInvalid(entry.name);
        bytes20 implementation = bytes20(entry.implementation);
        for (uint256 i; i < 20; ++i) {
            if (runtime[i + 1] != bytes1(0)) revert LibraryTemplateInvalid(entry.name);
            runtime[i + 1] = implementation[i];
        }
        expectedHash = keccak256(runtime);
        bytes32 actualHash = entry.implementation.codehash;
        if (actualHash != expectedHash) {
            revert LibraryRuntimeMismatch(entry.name, entry.implementation, expectedHash, actualHash);
        }
    }
}
