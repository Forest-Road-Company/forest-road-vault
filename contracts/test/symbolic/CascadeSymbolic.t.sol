// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @notice Arithmetic reference for cascade conservation and ordering (curator, shared backstop, then senior).
/// @dev Halmos can establish the properties of this isolated arithmetic model. It does not
///      execute DefaultManager or prove every reachable production state. Production equivalence
///      is separately sampled by the real native lifecycle and stateful differential tests;
///      finite fuzzing does not turn a model proof into a universal implementation proof.
///      Run `halmos --match-contract CascadeSymbolic` from contracts for the symbolic model.
///      Only testFuzz-prefixed wrappers, where present, run under ordinary forge test.
contract CascadeSymbolic is Test {
    function check_cascadeConservationAndOrdering(uint256 loss, uint256 poolBalance, uint256 covered) public pure {
        // realizeLoss precondition: loss != 0 (reverts on zero).
        vm.assume(loss > 0);

        // ── layer 1: curator first-loss — CuratorModule.absorbLoss ──
        uint256 absorbed = loss < poolBalance ? loss : poolBalance; // = min(loss, poolBalance)
        uint256 residual = loss - absorbed;

        // ── layer 2: sGROVE backstop — realizeLoss enforces covered <= residual ──
        vm.assume(covered <= residual);

        // ── layer 3: senior/depositor principal ──
        uint256 selfBurn = absorbed + covered;
        uint256 depositorLoss = loss - selfBurn;

        // PROPERTY 1 — conservation & no underflow when computing depositorLoss.
        assert(selfBurn <= loss);
        assert(absorbed + covered + depositorLoss == loss);

        // PROPERTY 2 — no junior layer absorbs beyond its capacity.
        assert(absorbed <= poolBalance);
        assert(covered <= residual);

        // PROPERTY 3 — layer ordering / senior-last: if depositors are impaired at all,
        // BOTH junior layers were exhausted first (curator fully drained, backstop capped
        // below the residual). Senior is never subordinated to a junior layer.
        if (depositorLoss > 0) {
            assert(absorbed == poolBalance); // curator pool fully consumed
            assert(covered < residual); // backstop could not fully cover — it capped
        }
    }
}
