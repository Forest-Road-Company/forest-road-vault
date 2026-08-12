// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ConservativeImpairmentMath} from "../../src/ConservativeImpairmentMath.sol";
import {ImpairmentBookDouble} from "./ConservativeImpairmentMathEquivalence.t.sol";

/// @title SWEEP ROUND 1 — W7 encodes the former theorem precondition in event data
/// @notice The pre-W7 aggregate calculator admitted a synthetic state where the drawn cohort was
///         larger than the declared cohort. That could produce `pastDueSenior > residual` and make
///         the registry subtraction revert. W7 no longer derives either cohort from those
///         independently mutable aggregates: every declared default is one registered row, and a
///         row becomes drawn in place. This suite retains the old counterexample and proves it can
///         no longer contaminate the mark, while keeping the registry's loud invalid-input check.
contract SweepR1TheoremPrecondition is Test {
    ConservativeImpairmentMath internal math;
    ImpairmentBookDouble internal book;
    CollateralRegistry internal registry;

    function setUp() public {
        math = new ConservativeImpairmentMath();
        registry = new CollateralRegistry();
        book = new ImpairmentBookDouble(address(registry));
        vm.warp(365 days);
    }

    function test_R1_control_registeredDrawnEventPricesFine() public {
        book.setLayerTwo(60e18, 10_000, type(uint256).max);
        book.addEvent(1, 1, 50e18, true, 50e18);
        book.setPastDue(1, 100e18);
        // Past-due receives the 60e18 fresh cap first; the separate 50e18 drawn row then has no
        // reserve left. Gross 150 - junior 60 = 90, with no cross-cohort subtraction.
        assertEq(math.pendingSeniorImpairment(address(book)), 90e18, "registered cohorts price exactly");
    }

    function test_R1_legacyAggregateCounterexampleCannotOverrideEventRows() public {
        // This is the old impossible shape: declared 0, past-due 100, drawn 50. No event row
        // exists for that claimed drawn principal, so W7 prices only the executable past-due
        // cohort rather than subtracting an unencoded phantom cohort from it.
        book.setLegacyAggregates(1, 0, 100e18, 50e18);
        book.setLayerTwo(60e18, 10_000, type(uint256).max);
        assertEq(math.pendingSeniorImpairment(address(book)), 40e18, "legacy aggregates revived the underflow");
    }

    function test_R1_drawnRowsRemainInsideTheRegisteredDeclaredCohort() public {
        book.addEvent(1, 1, 50e18, true, 25e18);
        book.addEvent(2, 1, 75e18, false, 0);
        assertEq(book.declaredDefaultedPrincipal(1), 125e18);
        assertEq(book.drawnDefaultPrincipal(1), 50e18);
        assertLe(book.drawnDefaultPrincipal(1), book.declaredDefaultedPrincipal(1));
    }

    function test_R1_registryStillRejectsAnInvalidDirectPair() public {
        vm.expectRevert(stdError.arithmeticError);
        registry.conservativeSeniorMark(90e18, 40e18, address(book), block.timestamp);
        assertGt(registry.conservativeSeniorMark(40e18, 40e18, address(book), block.timestamp), 0, "well-formed");
    }
}
