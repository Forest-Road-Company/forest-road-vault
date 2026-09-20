// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ImpairmentBudgetFixture} from "./ImpairmentBudget.t.sol";
import {IImpairmentSource} from "../../src/interfaces/IImpairmentSource.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";

/// @dev All financial setup is in setUp. Foundry starts each test in a new transaction;
///      neither recording accesses nor vm.cool is used as a substitute for that boundary.
abstract contract FreshImpairmentBudgetFixture is ImpairmentBudgetFixture {
    uint256 private expectedSenior;
    uint256 private expectedFee;
    function _capitalMode() internal pure virtual returns (uint256) { return 0; }
    // 0: exact assessment; 1: no assessment; 2: accrued cohort; 3: expired assessment.
    function _assessmentMode() internal pure virtual returns (uint256) { return 0; }

    function setUp() public virtual override {
        super.setUp();
        _book(_capitalMode());
        if (_assessmentMode() != 1) {
            uint256 conservative = defaultManager.pendingSeniorImpairment();
            vm.prank(admin);
            assessedImpairmentSource.setAssessment(conservative / 2,
                uint64(block.timestamp + 7 days), keccak256("fresh-budget-memorandum"));
        }
        vm.prank(admin);
        registry.setPastDueWeight(4_000);
        if (_assessmentMode() >= 2) {
            vm.warp(block.timestamp + (_assessmentMode() == 2 ? 1 : 8 days));
            _maintain();
        }
        expectedSenior = assessedImpairmentSource.pendingSeniorImpairment();
        expectedFee = assessedImpairmentSource.performanceFeeImpairment();
    }

    function _freshGetter(bytes4 selector, uint256 expected) private {
        address source = address(assessedImpairmentSource);
        bytes memory data = abi.encodeWithSelector(selector);
        // FIRST_READ_START: the next call must be the first financial read in this test.
        uint256 beforeRead = gasleft();
        (bool ok, bytes memory result) = source.staticcall{gas: CURRENT_READ_BUDGET}(data);
        uint256 used = beforeRead - gasleft();
        assertTrue(ok, "healthy fresh read exceeded recovery allowance");
        assertEq(result.length, 32);
        assertEq(abi.decode(result, (uint256)), expected);
        beforeRead = gasleft();
        (ok, data) = source.staticcall(data);
        uint256 warm = beforeRead - gasleft();
        assertTrue(ok);
        assertEq(data, result);
        assertGt(used, warm + 20_000, "measurement was prewarmed");
        assertLt(used, 750_000, "less than 250k gas margin remains");
        emit log_named_uint("fresh getter gas", used);
        emit log_named_uint("repeat getter gas", warm);
    }

    function test_freshSeniorReadFitsBudget() public {
        _freshGetter(IImpairmentSource.pendingSeniorImpairment.selector, expectedSenior);
    }
    function test_freshFeeReadFitsBudget() public {
        _freshGetter(IImpairmentSource.performanceFeeImpairment.selector, expectedFee);
    }
    function test_freshProbeRetainsHealthySource() public {
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector,
            address(assessedImpairmentSource)));
        this.checkRecoveryRead{gas: RECOVERY_CALL_GAS}(address(assessedImpairmentSource));
    }
    function test_freshVaultRetainsHealthySource() public {
        vm.expectRevert(abi.encodeWithSelector(IsUSDfr.SUSDfr_ImpairmentSourceStillReadable.selector,
            address(assessedImpairmentSource)));
        vm.prank(admin);
        vault.clearUnreadableImpairmentSource{gas: 2_500_000}();
        assertEq(vault.impairmentSource(), address(assessedImpairmentSource));
        assertEq(assessedImpairmentSource.pendingSeniorImpairment(), expectedSenior);
        assertEq(assessedImpairmentSource.performanceFeeImpairment(), expectedFee);
    }
}

contract FreshLegacyCapital0Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
    function _capitalMode() internal pure override returns (uint256) { return 0; }
}

contract FreshLegacyCapital1Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
    function _capitalMode() internal pure override returns (uint256) { return 1; }
}

contract FreshLegacyCapital2Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
    function _capitalMode() internal pure override returns (uint256) { return 2; }
}

contract FreshLegacyAssessment1Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
    function _assessmentMode() internal pure override returns (uint256) { return 1; }
}

contract FreshLegacyAssessment2Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
    function _assessmentMode() internal pure override returns (uint256) { return 2; }
}

contract FreshLegacyAssessment3Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
    function _assessmentMode() internal pure override returns (uint256) { return 3; }
}

contract FreshBoundCapital0Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
    function _capitalMode() internal pure override returns (uint256) { return 0; }
}

contract FreshBoundCapital1Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
    function _capitalMode() internal pure override returns (uint256) { return 1; }
}

contract FreshBoundCapital2Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
    function _capitalMode() internal pure override returns (uint256) { return 2; }
}

contract FreshBoundAssessment1Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
    function _assessmentMode() internal pure override returns (uint256) { return 1; }
}

contract FreshBoundAssessment2Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
    function _assessmentMode() internal pure override returns (uint256) { return 2; }
}

contract FreshBoundAssessment3Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
    function _assessmentMode() internal pure override returns (uint256) { return 3; }
}

contract FreshNativeCapital0Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
    function _capitalMode() internal pure override returns (uint256) { return 0; }
}

contract FreshNativeCapital1Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
    function _capitalMode() internal pure override returns (uint256) { return 1; }
}

contract FreshNativeCapital2Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
    function _capitalMode() internal pure override returns (uint256) { return 2; }
}

contract FreshNativeAssessment1Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
    function _assessmentMode() internal pure override returns (uint256) { return 1; }
}

contract FreshNativeAssessment2Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
    function _assessmentMode() internal pure override returns (uint256) { return 2; }
}

contract FreshNativeAssessment3Test is FreshImpairmentBudgetFixture {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
    function _assessmentMode() internal pure override returns (uint256) { return 3; }
}
