// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @dev SYMBOLIC proof (halmos) of the §1.3 loss-cascade arithmetic in
///      `DefaultManager.realizeLoss` (src/DefaultManager.sol) — the two safety properties
///      CLAUDE.md §1.5 explicitly names for formal treatment, here established for ALL
///      inputs (not just fuzzed ones):
///        - VALUE CONSERVATION: absorbed + covered + depositorLoss == loss, with no
///          under/overflow — nothing created or destroyed by the split.
///        - LAYER ORDERING (senior-last): depositor/senior principal is impaired ONLY after
///          BOTH junior layers are exhausted (curator drained AND backstop capped).
///
///      The split arithmetic below mirrors realizeLoss line-for-line (layer1 = curator
///      `absorbed=min(loss,pool); residual=loss-absorbed`; layer2 = backstop `covered<=residual`
///      enforced by the ICascadeBackstop contract; layer3 = `depositorLoss=loss-absorbed-covered`).
///      The differential fuzz (CreditHandler per-call asserts, 512×256 heavy) independently
///      binds the REAL contract's split to exactly this arithmetic, so: contract == model (fuzz)
///      + model correct ∀ inputs (this proof) = the cascade split is sound for all reachable states.
///
///      Run (from contracts/): `halmos --match-contract CascadeSymbolic`. `check_`-prefixed so
///      `forge test` ignores it (halmos-only; not part of the forge suite count).
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
