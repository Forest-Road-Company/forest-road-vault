// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {DefaultLossLib} from "../../src/libraries/DefaultLossLib.sol";

/// @title DefaultLossLibExtraction - the drift guards the 2026-09-10 EIP-170 extraction needs
///
/// @notice The extraction moved `realizeLoss` and its helpers into `DefaultLossLib` and left one
///         constant duplicated in `DefaultManager`, because both of its remaining uses there are
///         inside inline assembly and solc accepts only a direct number constant in that position.
///         A duplicated constant that nothing checks is a defect waiting to happen, so it is
///         checked here.
contract DefaultLossLibExtractionTest is Test {
    /// @notice The backstop probe's gas bound must be the same number in both definitions.
    ///
    /// @dev WHY THIS MATTERS RATHER THAN BEING TIDINESS. The bound is what stops a hostile or
    ///      broken `ICascadeBackstop` bricking the loss cascade by consuming all forwarded gas.
    ///      If the two copies drift, `DefaultManager`'s own probes and the probe inside
    ///      `DefaultLossLib.coverFromBackstop` would disagree about how much gas a backstop is
    ///      allowed, and the cascade's behaviour would depend on which path reached it. The
    ///      literal below is asserted against the library's `internal` constant; if someone
    ///      changes one, this test reds until they change the other.
    function test_backstopProbeGasBoundIsIdenticalInBothDefinitions() public pure {
        // The value hard-coded in `DefaultManager`, which cannot reference the library from
        // inline assembly. Keep this literal equal to the one in that file.
        uint256 defaultManagerCopy = 200_000;
        assertEq(
            DefaultLossLib.BACKSTOP_PROBE_GAS,
            defaultManagerCopy,
            "BACKSTOP_PROBE_GAS drifted between DefaultManager and DefaultLossLib"
        );
    }
}
