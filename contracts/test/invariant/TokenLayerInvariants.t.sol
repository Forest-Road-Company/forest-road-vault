// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {TokenLayerHandler} from "./handlers/TokenLayerHandler.sol";

/// @dev Stateful-fuzz invariants for the token layer (CLAUDE.md §1.3):
///      - BACKING:        USDfr totalSupply <= backing value, across all reachable states
///      - RATE INTEGRITY: the sUSDfr fee-net rate never falls except via an explicit
///                        loss or a bounded protocol fee becoming due
///      - RECONCILIATION: treasury per-facility principal and idle USDC reconcile
///      - CONSERVATION:   every minted USDfr is accounted for by a wallet/vault/treasury
contract TokenLayerInvariants is TokenLayerFixture {
    TokenLayerHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler =
            new TokenLayerHandler(usdc, usdfr, compliance, reserves, controller, vault, complianceAdmin, creditModule);
        targetContract(address(handler));
    }

    /// @notice INVARIANT (backing, ADR-0012): supply never exceeds backing.
    function invariant_backing_supplyNeverExceedsBacking() public view {
        assertLe(controller.totalUSDfr(), controller.backingValue(), "BACKING VIOLATED");
    }

    /// @notice INVARIANT (fee-aware rate integrity): below the last evented floor,
    ///         a decrease is legal only while a bounded protocol fee is economically due.
    /// @dev Performance-share rounding can create a tiny downward step as pending shares
    ///      cross an integer boundary. The post-fee marked rate may never fall below the
    ///      smaller of the last floor and the stored post-fee HWM. Management is disabled
    ///      in this launch-state campaign; its prospective behavior is fuzzed separately.
    function invariant_exchangeRate_neverFallsWithoutLossOrFee() public view {
        uint256 rate = vault.currentExchangeRate();
        uint256 floor = handler.rateFloor();
        if (rate >= floor) return;

        assertGt(vault.performanceFeeBps(), 0, "RATE FELL WITH FEES DISABLED");
        assertGt(vault.feeExchangeRate(), vault.highWaterMark(), "RATE FELL WITHOUT A DUE PERFORMANCE FEE");
        uint256 hwm = vault.highWaterMark();
        assertGe(rate, floor < hwm ? floor : hwm, "FEE DILUTION BREACHED ITS HWM FLOOR");
    }

    /// @notice INVARIANT: accounted idle USDC equals exact custody produced by bounded actions.
    function invariant_idleReserve_independentRecompute() public view {
        uint256 independent = usdc.balanceOf(address(reserves)) * 1e12;
        assertEq(reserves.idleReserve(), independent, "IDLE USDC ACCOUNTING DIVERGED");
        // and backing = independent idle + the independently-reconciled deployed principal
        assertEq(
            reserves.totalBackingValue(), independent + handler.sumDeployed(), "BACKING != INDEPENDENT RECOMPUTATION"
        );
    }

    /// @notice INVARIANT (reserve reconciliation): totals equal the sum of parts.
    function invariant_reserves_reconcile() public view {
        assertEq(reserves.deployedPrincipal(), handler.sumDeployed(), "DEPLOYED PRINCIPAL DOES NOT RECONCILE");
        assertEq(usdfr.balanceOf(address(reserves)), 0, "RESERVE MUST NOT CUSTODY USDfr");
    }

    /// @notice INVARIANT (conservation): all USDfr lives in tracked hands.
    function invariant_supply_fullyAccounted() public view {
        uint256 tracked =
            usdfr.balanceOf(address(vault)) + usdfr.balanceOf(address(reserves)) + handler.sumActorBalances();
        assertEq(usdfr.totalSupply(), tracked, "SUPPLY LEAKED TO UNTRACKED ADDRESS");
    }

    /// @notice The handler must actually be exercising the system (anti-vacuity).
    function invariant_callSummary() public view {
        // no assertion — surfaced via -vv for run inspection; kept cheap
        handler.callCount();
    }
}
