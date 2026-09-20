// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualSequenceChecks} from "./NativeAccrualSequences.t.sol";
import {NativeAccrualStatefulFixture} from "../helpers/NativeAccrualStatefulFixture.sol";
import {NativeOpeningStatefulFixture} from "../helpers/NativeOpeningStatefulFixture.sol";

abstract contract NativeOpeningHistoryChecks is NativeAccrualSequenceChecks, NativeOpeningStatefulFixture {
    function setUp() public virtual override(NativeAccrualStatefulFixture, NativeOpeningStatefulFixture) {
        NativeOpeningStatefulFixture.setUp();
    }
}

contract NativeOpeningCashHistoryTest is NativeOpeningHistoryChecks {}

contract NativeOpeningPikHistoryTest is NativeOpeningHistoryChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
