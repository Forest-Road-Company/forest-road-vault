// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningStatefulFixture} from "../helpers/NativeOpeningStatefulFixture.sol";

abstract contract NativeOpeningInvariantChecks is NativeOpeningStatefulFixture {
    function setUp() public virtual override {
        super.setUp();
        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = this.actFund.selector;
        selectors[1] = this.actTime.selector;
        selectors[2] = this.actReceipt.selector;
        selectors[3] = this.actAmend.selector;
        selectors[4] = this.actMark.selector;
        selectors[5] = this.actCure.selector;
        selectors[6] = this.actDeclare.selector;
        selectors[7] = this.actLoss.selector;
        selectors[8] = this.actMaterialize.selector;
        selectors[9] = this.actPost.selector;
        selectors[10] = this.actCancel.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function invariant_migratedIncomeBackingAndOrderedLosses() public view {
        assertNativeStatefulAccounting();
        assertEq(vault.currentExchangeRate(), nativeLastRate, "migrated native rate changed outside an action");
    }
}

contract NativeOpeningCashInvariants is NativeOpeningInvariantChecks {}

contract NativeOpeningPikInvariants is NativeOpeningInvariantChecks {
    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }
}
