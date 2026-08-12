// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title SWEEP ROUND 1 — guard-vacuity closures
/// @notice Written by the adversarial sweep because the guards below were deletable with the whole
///         non-fork suite (1,377 non-invariant tests plus `CreditInvariants` and
///         `ProductionCascadeInvariants`) still green. Each test here is the missing witness.
contract SweepR1GuardVacuity is CreditLayerFixture {
    /// @notice `WaterfallEngine._withholdFeeForSeniorImpairment`'s `if (residual == 0) return
    ///         feeGross;` early return is NOT redundant with `min(feeGross, residual)`.
    ///
    ///         WHY IT MATTERS. CLAUDE.md §3.1 requires the on-chain register to be reconstructable
    ///         from events alone. Without the early return the engine emits
    ///         `ProtocolFeeWithheldForSeniorImpairment(0, 0)` on EVERY performing interest
    ///         distribution — an indexer would record a withholding on every repayment of a book
    ///         with nothing impaired, and the ADV-1 event stops distinguishing "a fee was withheld"
    ///         from "a fee was paid in full".
    ///
    ///         MUTATION: delete `if (residual == 0) return feeGross;` -> RED here.
    function test_R1_noWithholdingEventWhenNothingIsImpaired() public {
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "precondition: nothing impaired");

        vm.recordLogs();
        _repay(b, 10_000e18, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment.selector) ++seen;
        }
        assertEq(seen, 0, "a clean book must not log a zero withholding on every repayment");
    }

    /// @notice The same guard's sibling: `feeGross == 0` must short-circuit BEFORE the external
    ///         `pendingSeniorImpairment()` read. With a zero protocol fee there is nothing to
    ///         withhold, so neither the cross-contract read nor the event has any subject.
    ///
    ///         MUTATION: drop `feeGross == 0 ||` from the guard -> RED here.
    function test_R1_zeroProtocolFeeEmitsNoWithholdingEvenWhileImpaired() public {
        // Standing senior impairment, so `residual != 0` and only the `feeGross == 0` leg can stop
        // the emit.
        uint256 a = _liveFilmFacility(300_000e18);
        _mintUSDfrTo(alice, 400_000e18);
        uint256 b = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(b, 200_000e18);
        _attestDefault(a);
        vm.prank(servicer);
        defaultManager.declareDefault(a, FILM_REF);
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "precondition: a standing residual");

        vm.prank(admin);
        waterfall.setProtocolFee(0);

        vm.recordLogs();
        _repay(b, 10_000e18, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IWaterfallEngine.ProtocolFeeWithheldForSeniorImpairment.selector) ++seen;
        }
        assertEq(seen, 0, "a zero fee cannot be withheld, so nothing may be logged");
    }
}
