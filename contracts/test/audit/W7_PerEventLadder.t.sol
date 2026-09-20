// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {UndrawnLimbBase} from "./UNDRAWN_LIMB_FALSIFIER.t.sol";

/// @notice Impairment read budgets with thirty-two declared loans and the shared reserve.
contract W7PerEventLadderTest is UndrawnLimbBase {
    function setUp() public override {
        super.setUp();
        _openLimits();
        _stakeVault(alice, 1_000_000e18);
        _fundBackstop(400_000e18);
        for (uint256 i = 0; i < 32; ++i) {
            _defaulted(keccak256(abi.encode("w7-event", i)), 20_000e18);
        }
    }

    function test_thirtyTwoDeclaredLoansFitTheImpairmentReadBudget() public {
        // `setUp` and the test body are distinct runner calls, so this first read starts with a
        // fresh transaction access list instead of relying on address-only `vm.cool` calls that
        // leave every storage slot warmed by fixture construction.
        uint256 before = gasleft();
        (bool readable, bytes memory result) = address(assessedImpairmentSource).staticcall{gas: 400_000}(
            abi.encodeWithSignature("pendingSeniorImpairment()")
        );
        uint256 used = before - gasleft();
        emit log_named_uint("32-row bounded impairment read gas", used);
        assertTrue(readable, "constant-cost residuals must fit the production read budget");
        assertEq(result.length, 32, "the impairment read must return one complete word");
        assertEq(abi.decode(result, (uint256)), _expectedMark(), "the budgeted read changed the senior mark");
        assertLt(used, 250_000, "the residual path regained a cost per declared row");
    }

    function test_coldImpairmentReadPreservesTheResidualValue() public {
        uint256 before = gasleft();
        uint256 mark = assessedImpairmentSource.pendingSeniorImpairment();
        uint256 used = before - gasleft();
        emit log_named_uint("32-row cold impairment read gas", used);
        assertLt(used, 250_000, "constant-cost cold read budget exceeded");
        assertEq(mark, _expectedMark(), "the cold read changed the senior mark");
    }

    function _expectedMark() private view returns (uint256 residual) {
        assertEq(evIds.length, 32);
        residual = 32 * 20_000e18;
        uint256 firstLoss = curator.poolBalance(FILM);
        residual -= firstLoss < residual ? firstLoss : residual;
        uint256 reserve = sGrove.coverageReserve();
        residual -= reserve < residual ? reserve : residual;
    }

}
