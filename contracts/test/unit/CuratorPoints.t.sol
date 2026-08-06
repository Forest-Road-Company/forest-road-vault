// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title CuratorPoints — P-01: curator first-loss capital accrues points at the 5× multiple.
contract CuratorPointsTest is CreditLayerFixture {
    PointsModule internal points;
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;

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
        // wire ONLY the curator hook (isolate curator points from USDfr points)
        vm.startPrank(admin);
        points.setCuratorModule(address(curator));
        curator.setPointsModule(address(points));
        vm.stopPrank();
    }

    function test_P01_firstLossAccruesCuratorPoints() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        assertEq(points.curatorTracked(anchorCurator, FILM), 1_000_000e18, "first-loss tracked immediately");
        (,, uint256 curBefore) = points.pointsBreakdown(anchorCurator);
        assertEq(curBefore, 0, "no time elapsed yet");
        assertEq(uint256(points.curatorMultiplierBps()), 50_000, "default curator multiple is 5x");

        vm.warp(block.timestamp + 30 days);
        (uint256 s, uint256 u, uint256 cur) = points.pointsBreakdown(anchorCurator);
        assertEq(s, 0);
        assertEq(u, 0, "no USDfr points hook wired here");
        assertGt(cur, 0, "first-loss capital accrues points (P-01)");
        assertEq(points.pointsOfWallet(anchorCurator), cur, "total == curator points");
    }

    function test_P01_curatorEarnsFiveTimesTheBaseRate() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        (,, uint256 cur) = points.pointsBreakdown(anchorCurator);

        // an equal balance at the base rate (1x) for the same window, from a fresh position
        _postFirstLoss(secondCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        // secondCurator posted 30 days later, so compare the FIRST curator's first 30 days at 5x
        // against the base-rate reference for the same balance/window.
        uint256 baseRef = _refBase(1_000_000e18, 30 days);
        assertApproxEqRel(cur, baseRef * 5, 2e15, "curator earns ~5x the base rate");
    }

    function test_P01_withdrawReducesCuratorPosition() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 400_000e18); // no exposure -> full headroom
        assertEq(points.curatorTracked(anchorCurator, FILM), 600_000e18, "position reconciled to remaining posted");
    }

    // ── loss cap: impaired first-loss can't out-accrue live capital (audit follow-up) ──

    function test_P01_lossFreezesCuratorAccrualUntilReconcile() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);

        // a loss absorbs half the pool (drive absorbLoss directly as the credit layer would)
        vm.prank(admin);
        curator.grantRole(Roles.CREDIT_ROLE, address(this));
        curator.absorbLoss(FILM, 500_000e18);
        (,, uint256 pAtLoss) = points.pointsBreakdown(anchorCurator);

        // accrual is FROZEN at the loss instant — no more points on the destroyed capital
        vm.warp(block.timestamp + 60 days);
        (,, uint256 pFrozen) = points.pointsBreakdown(anchorCurator);
        assertEq(pFrozen, pAtLoss, "curator accrual frozen after loss until reconcile");

        // reconcile refreshes to the diluted postedOf and resumes accrual
        points.reconcile(anchorCurator);
        assertEq(points.curatorTracked(anchorCurator, FILM), 500_000e18, "reconciled to diluted postedOf");
        vm.warp(block.timestamp + 30 days);
        (,, uint256 pResumed) = points.pointsBreakdown(anchorCurator);
        assertGt(pResumed, pFrozen, "accrual resumes at the diluted balance after reconcile");
    }

    // fresh-position base-rate reference (ramp from 0 over `dur` at rate 1x)
    function _refBase(uint256 balance, uint256 dur) internal view returns (uint256) {
        uint256 f = dur * 1e18 + (dur * dur * 1e18) / (2 * 365 days); // ∫ ramp over [0,dur], dur<ramp
        return balance * f / 1e18 * points.ratePerUnitDay() / (1 days * 1e18);
    }
}
