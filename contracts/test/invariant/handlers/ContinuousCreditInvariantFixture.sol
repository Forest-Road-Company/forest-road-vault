// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualStatefulFixture} from "../../helpers/NativeAccrualStatefulFixture.sol";

/// @dev Accrual-enabled companion to the legacy credit campaign. Only the eleven
///      explicitly registered actions are eligible; the assertion helpers are reads.
abstract contract ContinuousCreditInvariantFixture is NativeAccrualStatefulFixture {
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

    function invariant_continuousIncomeBackingAndOrderedLosses() public view {
        assertNativeStatefulAccounting();
        assertEq(vault.currentExchangeRate(), nativeLastRate, "native rate moved outside its recorded action");
    }
}
