// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ReserveAccrualStorageLib} from "../../src/libraries/ReserveAccrualStorageLib.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";

/// @dev Single-field reads let tests discover compiler-assigned slots and packing through
///      vm.record/accesses. Tests preserve unrelated bytes and check every seeded value.
contract NativeOpeningStorageProbe {
    function read(uint8 field, uint256 id) external view returns (uint256) {
        ReserveAccrualStorageLib.State storage s = ReserveAccrualStorageLib.state();
        if (field == 0) return s.migration.nonce;
        if (field == 1) return s.busy ? 1 : 0;
        if (field == 2) return s.delivery.active ? 1 : 0;
        if (field == 3) return s.reservedCeilings;
        if (field == 4) return s.recordedFace;
        if (field == 5) return s.migration.expected;
        if (field == 6) return s.migration.importedOriginalFace;
        DefaultManager.DefaultStorage storage d;
        assembly {
            d.slot := 0x336a2060fa754acf2cdfdb8c351983bf3b455537ad219c0e1b705a95a2f8a200
        }
        if (field == 7) return uint256(uint160(address(d.reserves)));
        if (field == 8) return d.pastDueMarked[id] ? 1 : 0;
        if (field == 9) return d.defaultedContribution[id];
        if (field == 10) return d.coverageConsumedByDefault[id];
        if (field == 11) return d.drawnDefaultPrincipal[id];
        if (field == 12) return s.identities[id].known ? 1 : 0;
        revert("unknown test field");
    }
}
