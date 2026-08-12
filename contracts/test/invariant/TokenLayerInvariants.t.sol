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
        // AUDIT C4-USDFR-02/03: wire the campaign the way `Deploy.s.sol` wires mainnet — the
        // registry installed on the token, and the value-custodying modules listed as
        // protocol-exempt. Without this the emergency-pause carve-out has no directory to
        // consult and the paused-state invariants below would test a configuration the
        // protocol never ships.
        vm.startPrank(admin);
        usdfr.setComplianceModule(address(compliance));
        compliance.setProtocolExempt(address(vault), true);
        compliance.setProtocolExempt(address(reserves), true);
        compliance.setProtocolExempt(address(controller), true);
        vm.stopPrank();

        handler = new TokenLayerHandler(
            usdc, usdfr, compliance, reserves, controller, vault, complianceAdmin, creditModule, guardian, admin
        );
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

    /// @notice INVARIANT (AUDIT C4-USDFR-02, emergency pause): a paused USDfr settles NO user
    ///         outflow. The burn is the outflow leg — `MintRedeemController.redeem` burns a
    ///         holder's USDfr and releases the USDC behind it — and the old carve-out let it
    ///         through unconditionally, so pausing closed the inflow and left the reserve
    ///         draining at par. `TokenLayerHandler.pausedUserRedeem` drives exactly this region
    ///         on every call, funding the position itself so it can never be filtered away.
    function invariant_pause_settlesNoUserOutflow() public view {
        assertEq(handler.pausedUserOutflows(), 0, "PAUSED USDfr SETTLED A USER REDEMPTION");
        assertEq(handler.pausedUserSupplyDrops(), 0, "USDfr SUPPLY FELL ON A USER LEG WHILE PAUSED");
    }

    /// @notice INVARIANT (AUDIT C4-USDFR-02, cascade liveness): the same pause must never
    ///         freeze the loss cascade. `DefaultManager` burns from itself or from the vault,
    ///         both governance-listed, and that leg stays executable while paused. This is the
    ///         counterweight to the invariant above: tightening the pause must not buy safety
    ///         by deadlocking loss absorption.
    function invariant_pause_neverFreezesTheLossCascade() public view {
        assertEq(handler.pausedCascadeBurnsBlocked(), 0, "PAUSE FROZE THE LOSS CASCADE BURN LEG");
    }

    /// @notice INVARIANT (AUDIT C4-USDFR-01, points brick): governance can never configure the
    ///         token into a state where an ordinary transfer reverts. `onUSDfrTransfer` returns
    ///         no data, so solc's `extcodesize` guard fires outside the fail-open `try`; a
    ///         codeless module therefore bricked every transfer, mint and burn.
    function invariant_pointsModule_canNeverBrickTheToken() public view {
        assertEq(handler.codelessPointsInstalls(), 0, "A CODELESS POINTS MODULE WAS INSTALLED");
        assertEq(handler.tokenBrickedByPointsModule(), 0, "THE POINTS MODULE BRICKED USDfr TRANSFERS");
    }

    /// @notice REACHABILITY, asserted deterministically rather than left to the fuzzer's draw:
    ///         both illegal regions really are entered by the handler, and neither action is a
    ///         no-op that returns before it reaches the guard.
    function test_reachability_handlerEntersBothIllegalRegions() public {
        handler.pausedUserRedeem(0, 5_000e6);
        handler.pausedCascadeBurn(0, 1_000e6);
        handler.installCodelessPointsModule(uint256(uint160(makeAddr("someWallet"))), 1, 10e6);

        assertGt(handler.pausedUserProbes(), 0, "VACUOUS: the paused-redemption region was never entered");
        assertGt(handler.pausedCascadeProbes(), 0, "VACUOUS: the paused-cascade region was never entered");
        assertGt(handler.codelessPointsProbes(), 0, "VACUOUS: the codeless-points region was never entered");

        assertEq(handler.pausedUserOutflows(), 0, "PAUSED USDfr SETTLED A USER REDEMPTION");
        assertEq(handler.pausedUserSupplyDrops(), 0, "USDfr SUPPLY FELL ON A USER LEG WHILE PAUSED");
        assertEq(handler.pausedCascadeBurnsBlocked(), 0, "PAUSE FROZE THE LOSS CASCADE BURN LEG");
        assertEq(handler.codelessPointsInstalls(), 0, "A CODELESS POINTS MODULE WAS INSTALLED");
        assertEq(handler.tokenBrickedByPointsModule(), 0, "THE POINTS MODULE BRICKED USDfr TRANSFERS");
    }

    function afterInvariant() public view {
        assertGt(handler.callCount(), 0, "VACUOUS: token handler executed no successful action");
    }
}
