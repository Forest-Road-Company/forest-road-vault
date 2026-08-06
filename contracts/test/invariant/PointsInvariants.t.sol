// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";
import {PointsHandler} from "./handlers/PointsHandler.sol";

/// @dev Stateful-fuzz invariants for the redesigned points system (2026-07-14 directive):
///      - RECONCILIATION: totalTracked{Shares,USDfr} == Σ tracked balances of the (non-exempt)
///        participant wallets; and never exceeds real token supply
///      - EXEMPT EXCLUSION: protocol modules (vault holding staked USDfr, the queue holding
///        queued shares) accrue ZERO and are never tracked (the AUDIT FIX)
///      - MONOTONIC: per-wallet points never decrease
///      - NO FREE POINTS: a wallet that never held anything accrues zero
contract PointsInvariants is TokenLayerFixture {
    PointsModule internal points;
    PointsHandler internal handler;

    function setUp() public override {
        super.setUp();
        points = PointsModule(
            address(
                new ERC1967Proxy(
                    address(new PointsModule()),
                    abi.encodeCall(
                        PointsModule.initialize, (admin, admin, address(compliance), address(vault), address(usdfr))
                    )
                )
            )
        );
        vm.startPrank(admin);
        vault.setPointsModule(address(points));
        usdfr.setPointsModule(address(points));
        vm.stopPrank();

        handler = new PointsHandler(usdc, usdfr, compliance, controller, vault, points, complianceAdmin, admin);
        // the vault custodies staked USDfr and the handler stands in for the queue (holds
        // queued shares + claimable USDfr) — both are protocol custodians, so they are
        // protocol-exempt and must NOT accrue.
        vm.startPrank(admin);
        compliance.setProtocolExempt(address(vault), true);
        compliance.setProtocolExempt(address(handler), true);
        vm.stopPrank();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PointsHandler.stakeShares.selector;
        selectors[1] = PointsHandler.transferShares.selector;
        selectors[2] = PointsHandler.exitShares.selector;
        selectors[3] = PointsHandler.holdUsdfr.selector;
        selectors[4] = PointsHandler.transferUsdfr.selector;
        selectors[5] = PointsHandler.redeemUsdfr.selector;
        selectors[6] = PointsHandler.pokeCheckpoint.selector;
        selectors[7] = PointsHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_tracking_reconcilesToParticipantBalances() public view {
        (uint256 totalShares, uint256 totalUsdfr,) = points.totals();
        uint256 sumShares;
        uint256 sumUsdfr;
        for (uint256 i = 0; i < handler.walletCount(); ++i) {
            (uint256 s, uint256 u) = points.trackedBalances(handler.walletAt(i));
            sumShares += s;
            sumUsdfr += u;
        }
        // the 4 participant wallets are the only non-exempt holders
        assertEq(totalShares, sumShares, "TRACKED SHARES != SUM OF PARTICIPANTS");
        assertEq(totalUsdfr, sumUsdfr, "TRACKED USDfr != SUM OF PARTICIPANTS");
        assertLe(totalShares, vault.totalSupply(), "TRACKED SHARES > SUPPLY");
        assertLe(totalUsdfr, usdfr.totalSupply(), "TRACKED USDfr > SUPPLY");
    }

    function invariant_exemptModulesNeverAccrue() public view {
        (uint256 vs, uint256 vu) = points.trackedBalances(address(vault));
        assertEq(vs + vu, 0, "VAULT TRACKED");
        assertEq(points.pointsOfWallet(address(vault)), 0, "VAULT ACCRUED");
        (uint256 qs, uint256 qu) = points.trackedBalances(address(handler));
        assertEq(qs + qu, 0, "QUEUE TRACKED");
        assertEq(points.pointsOfWallet(address(handler)), 0, "QUEUE ACCRUED");
    }

    function invariant_points_monotonicPerWallet() public {
        for (uint256 i = 0; i < handler.walletCount(); ++i) {
            address w = handler.walletAt(i);
            uint256 current = points.pointsOfWallet(w);
            assertGe(current, handler.lastSeenPoints(w), "POINTS DECREASED");
            handler.recordSeenPoints(w, current);
        }
    }

    function invariant_noFreePoints_idleWallet() public view {
        assertEq(points.pointsOfWallet(handler.IDLE_WALLET()), 0, "IDLE WALLET ACCRUED");
    }
}
