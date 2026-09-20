// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {VaultAccrualLib} from "../../src/libraries/VaultAccrualLib.sol";

/// @dev Same-transaction ABI and accounting checks. These do not measure cold gas.
///      FreshImpairmentBudget constructs its book in setUp and measures the first read.
abstract contract ImpairmentReadChecks is Test {
    uint256 internal constant CURRENT_READ_BUDGET = 1_000_000;
    uint256 internal constant RECOVERY_CALL_GAS = 2_300_000;

    /// @dev Calls the production linked probe without clearing a mark.
    function checkRecoveryRead(address source) external view returns (bytes32) {
        return VaultAccrualLib.impairmentRecoveryFailure(source);
    }

    function _assertImpairmentReadable(address source, string memory label) internal {
        _assertGetter(source, IImpairmentSource.pendingSeniorImpairment.selector, label);
        _assertGetter(source, IImpairmentSource.performanceFeeImpairment.selector, label);
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector, source));
        this.checkRecoveryRead{gas: RECOVERY_CALL_GAS}(source);
    }

    function _assertGetter(address source, bytes4 selector, string memory label) private view {
        bytes memory data = abi.encodeWithSelector(selector);
        (bool expectedOk, bytes memory expected) = source.staticcall(data);
        assertTrue(expectedOk, "reference view failed");
        assertEq(expected.length, 32, "reference view malformed");
        (bool ok, bytes memory actual) = source.staticcall{gas: CURRENT_READ_BUDGET}(data);
        assertTrue(ok, label);
        assertEq(actual, expected, "bounded view changed result");
    }
}
