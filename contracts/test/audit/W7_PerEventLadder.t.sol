// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {UndrawnLimbBase} from "./UNDRAWN_LIMB_FALSIFIER.t.sol";

/// @notice W7 structural checks that are intentionally separate from the published grading files.
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

    function test_w7_thirtyTwoLiveUndrawnEventsExposeTheHardProbeBoundary() public {
        // `setUp` and the test body are distinct runner calls, so this first read starts with a
        // fresh transaction access list instead of relying on address-only `vm.cool` calls that
        // leave every storage slot warmed by fixture construction.
        uint256 before = gasleft();
        (bool readable, bytes memory result) = address(assessedImpairmentSource).staticcall{gas: 400_000}(
            abi.encodeWithSignature("pendingSeniorImpairment()")
        );
        uint256 used = before - gasleft();
        emit log_named_uint("W7 32-live-event assessed impairment gas", used);
        assertFalse(readable, "control changed: the 32-event cold ladder unexpectedly fits the 400,000 stipend");
        assertEq(result.length, 0, "the exhausted stipend should return no fabricated mark");
        assertLt(used, 400_000, "the caller failed to retain its EIP-150 gas reserve");
    }

    function test_w7_diagnosticColdThirtyTwoEventCost() public {
        uint256 before = gasleft();
        assessedImpairmentSource.pendingSeniorImpairment();
        uint256 used = before - gasleft();
        emit log_named_uint("W7 32-live-event cold diagnostic gas", used);
        assertLt(used, 600_000, "diagnostic ceiling exceeded");
    }
}
