// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PointsModule} from "../../src/PointsModule.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev A points module that always reverts — proves the token hooks are fail-open.
contract RevertingPoints is IPointsModule {
    function onSharesTransfer(address, address, uint256) external pure override {
        revert("points boom");
    }

    function onUSDfrTransfer(address, address, uint256) external pure override {
        revert("points boom");
    }

    function onCuratorStakeChange(address, uint256, uint256) external pure override {
        revert("points boom");
    }

    function onCuratorLoss(uint256, uint256, uint256) external pure override {
        revert("points boom");
    }
}

/// @dev Minimal live-balance source for exercising permissionless curator reconciliation
///      independently of the CuratorModule hook.
contract MutableCuratorBalance {
    mapping(uint256 classId => mapping(address curator => uint256 amount)) internal posted;

    function setPosted(uint256 classId, address curator, uint256 amount) external {
        posted[classId][curator] = amount;
    }

    function postedOf(uint256 classId, address curator) external view returns (uint256) {
        return posted[classId][curator];
    }

    function notify(PointsModule points, address curator, uint256 classId, uint256 amount) external {
        points.onCuratorStakeChange(curator, classId, amount);
    }
}

/// @title PointsModuleTest — the redesigned per-wallet, flat, dual-token points ledger
///        (2026-07-14 directive): permissionless per-wallet accrual, no size penalty,
///        USDfr holders earn 3× the sUSDfr rate in lieu of yield, fail-open hooks.
contract PointsModuleTest is TokenLayerFixture {
    PointsModule internal points;

    bytes32 internal constant POINTS_STORAGE_LOCATION =
        0x2b0f9b300e42162fe5738c4f7cc02b34c204f066c1bd41ebe399ed932bb31b00;
    uint256 internal constant RAMP = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SHARE = 1e24; // one whole sUSDfr share
    uint256 internal constant UUNIT = 1e18; // one whole USDfr

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
        vm.warp(1_750_000_000);
    }

    function test_initialize_rejectsEveryZeroPrincipal() public {
        PointsModule impl = new PointsModule();
        address[5] memory args = [admin, admin, address(compliance), address(vault), address(usdfr)];
        for (uint256 i; i < args.length; ++i) {
            address saved = args[i];
            args[i] = address(0);
            vm.expectRevert(PointsModule.Points_ZeroAddress.selector);
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PointsModule.initialize, (args[0], args[1], args[2], args[3], args[4]))
            );
            args[i] = saved;
        }
    }

    function test_setCuratorModule_rejectsZeroAndSecondAssignment() public {
        MutableCuratorBalance source = new MutableCuratorBalance();
        vm.startPrank(admin);
        vm.expectRevert(PointsModule.Points_ZeroAddress.selector);
        points.setCuratorModule(address(0));
        points.setCuratorModule(address(source));
        vm.expectRevert(PointsModule.Points_CuratorModuleAlreadySet.selector);
        points.setCuratorModule(address(source));
        vm.stopPrank();
    }

    function test_reconcileRepairsDroppedCuratorDecreaseAndTotal() public {
        MutableCuratorBalance source = new MutableCuratorBalance();
        vm.prank(admin);
        points.setCuratorModule(address(source));

        source.setPosted(1, alice, 100e18);
        source.notify(points, alice, 1, 100e18);
        (,, uint256 beforeTotal) = points.totals();
        assertEq(beforeTotal, 100e18);

        // Simulate a fail-open/dropped withdrawal hook: live position fell, cached did not.
        source.setPosted(1, alice, 40e18);
        points.reconcile(alice);
        (,, uint256 afterTotal) = points.totals();
        assertEq(afterTotal, 40e18);
        assertEq(points.curatorTracked(alice, 1), 40e18);
    }

    function test_defensiveDilutionClampRejectsAGrowingLegacySurvivalFactor() public {
        MutableCuratorBalance source = new MutableCuratorBalance();
        vm.prank(admin);
        points.setCuratorModule(address(source));
        source.setPosted(1, alice, 100e18);
        source.notify(points, alice, 1, 100e18);

        bytes32 outer = keccak256(abi.encode(alice, uint256(POINTS_STORAGE_LOCATION) + 7));
        bytes32 position = keccak256(abi.encode(uint256(1), outer));
        vm.store(address(points), bytes32(uint256(position) + 3), bytes32(WAD / 2));

        points.checkpoint(alice);

        assertEq(points.curatorTracked(alice, 1), 100e18, "defensive clamp cannot inflate tracked capital");
        (,, uint256 trackedCurator) = points.totals();
        assertEq(trackedCurator, 100e18, "global tracked capital remains conserved");
    }

    function test_reconcileRepairsDroppedShareIncreaseAndExemptionDecrease() public {
        RevertingPoints bad = new RevertingPoints();
        vm.prank(admin);
        vault.setPointsModule(address(bad));

        uint256 minted = _mintUSDfr(alice, 100e6);
        vm.startPrank(alice);
        usdfr.approve(address(vault), minted);
        uint256 shares = vault.deposit(minted, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.setPointsModule(address(points));
        points.reconcile(alice);
        (uint256 tracked,) = points.trackedBalances(alice);
        assertEq(tracked, shares, "permissionless reconcile restores dropped share increase");

        vm.prank(admin);
        compliance.setProtocolExempt(alice, true);
        points.reconcile(alice);
        (tracked,) = points.trackedBalances(alice);
        assertEq(tracked, 0, "exemption reconcile removes the tracked share position");
    }

    // ── independent reference model (trapezoid — different route than the contract) ──

    function _mAt(uint256 age) internal pure returns (uint256) {
        return age >= RAMP ? 2 * WAD : WAD + (age * WAD) / RAMP;
    }

    function _refIntegral(uint256 age0, uint256 age1) internal pure returns (uint256) {
        if (age1 <= RAMP) return (age1 - age0) * (_mAt(age0) + _mAt(age1)) / 2;
        if (age0 >= RAMP) return (age1 - age0) * 2 * WAD;
        return (RAMP - age0) * (_mAt(age0) + 2 * WAD) / 2 + (age1 - RAMP) * 2 * WAD;
    }

    function _refPoints(uint256 balance, uint256 unit, uint256 rate, uint256 start, uint256 t0, uint256 t1)
        internal
        pure
        returns (uint256)
    {
        return balance * _refIntegral(t0 - start, t1 - start) / WAD * rate / (1 days * unit);
    }

    function _stake(address user, uint256 usdcAmount) internal returns (uint256 shares) {
        uint256 minted = _mintUSDfr(user, usdcAmount);
        vm.startPrank(user);
        usdfr.approve(address(vault), minted);
        shares = vault.deposit(minted, user);
        vm.stopPrank();
    }

    /// @dev Mint the underlying USDC, then USDfr (for balances above the pre-funded amount).
    function _getUsdfr(address user, uint256 usdcAmount) internal returns (uint256) {
        usdc.mint(user, usdcAmount);
        return _mintUSDfr(user, usdcAmount);
    }

    // ── USDfr accrues at 3× the sUSDfr rate (in lieu of yield) ───────────

    function test_usdfr_accruesAtTripleRate() public {
        _mintUSDfr(alice, 1_000e6); // 1000 USDfr held by alice
        uint256 start = block.timestamp;
        vm.warp(start + 30 days);

        (uint256 fromShares, uint256 fromUSDfr,) = points.pointsBreakdown(alice);
        assertEq(fromShares, 0, "no shares, no share points");
        uint256 baseRate = points.ratePerUnitDay();
        uint256 uRate = baseRate * points.usdfrMultiplierBps() / 10_000;
        assertEq(uint256(points.usdfrMultiplierBps()), 30_000, "default 3x");
        uint256 expected = _refPoints(1_000e18, UUNIT, uRate, start, start, start + 30 days);
        assertApproxEqRel(fromUSDfr, expected, 1e12, "USDfr points match reference");

        // 3x check: the same balance held as sUSDfr for the same window earns 1/3 the points
        uint256 refBase = _refPoints(1_000e18, UUNIT, baseRate, start, start, start + 30 days);
        assertApproxEqRel(fromUSDfr, refBase * 3, 1e12, "USDfr earns exactly 3x the base");
    }

    function test_susdfr_accruesAtBaseRate() public {
        uint256 shares = _stake(alice, 1_000e6);
        uint256 start = block.timestamp;
        vm.warp(start + 30 days);
        (uint256 fromShares,,) = points.pointsBreakdown(alice);
        uint256 expected = _refPoints(shares, SHARE, points.ratePerUnitDay(), start, start, start + 30 days);
        assertApproxEqRel(fromShares, expected, 1e12, "share points match reference at base rate");
    }

    // ── flat: no size penalty; sybil-neutral ─────────────────────────────

    function test_flat_noSizePenalty_andSybilNeutral() public {
        // alice holds 30M USDfr; bob holds 10M — bob should earn exactly 1/3 of alice
        _getUsdfr(alice, 30_000_000e6);
        _getUsdfr(bob, 10_000_000e6);
        uint256 start = block.timestamp;
        vm.warp(start + 10 days);
        (, uint256 aPts,) = points.pointsBreakdown(alice);
        (, uint256 bPts,) = points.pointsBreakdown(bob);
        assertApproxEqRel(aPts, bPts * 3, 1e12, "linear: 3x balance -> 3x points (no penalty)");

        // sybil-neutral: 10M in one fresh wallet vs 10M split across two fresh wallets, same
        // window -> identical total (flat linear accrual; splitting earns nothing extra).
        address whole = makeAddr("whole");
        address split1 = makeAddr("split1");
        address split2 = makeAddr("split2");
        _getUsdfr(alice, 20_000_000e6); // fund alice to distribute from
        vm.startPrank(alice);
        usdfr.transfer(whole, 10_000_000e18);
        usdfr.transfer(split1, 5_000_000e18);
        usdfr.transfer(split2, 5_000_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        (, uint256 wholePts,) = points.pointsBreakdown(whole);
        (, uint256 s1,) = points.pointsBreakdown(split1);
        (, uint256 s2,) = points.pointsBreakdown(split2);
        assertApproxEqRel(wholePts, s1 + s2, 1e12, "sybil-neutral: split earns the same total as whole");
    }

    // ── maturity ramp preserved (patience favored; churn penalty) ────────

    function test_maturityRamp_pastKnee_referenceModel() public {
        _mintUSDfr(alice, 1_000e6);
        uint256 start = block.timestamp;
        vm.warp(start + 400 days); // past the 365-day ramp knee
        (, uint256 pts,) = points.pointsBreakdown(alice);
        uint256 uRate = points.ratePerUnitDay() * points.usdfrMultiplierBps() / 10_000;
        uint256 expected = _refPoints(1_000e18, UUNIT, uRate, start, start, start + 400 days);
        assertApproxEqRel(pts, expected, 1e12, "ramp past knee matches reference");
    }

    function test_withdrawal_leavesMaturityStartUnchanged() public {
        _mintUSDfr(alice, 1_000e6);
        uint256 start = block.timestamp;
        vm.warp(start + 100 days);
        // send half away (a withdrawal from alice's position); her maturity must not reset
        vm.prank(alice);
        usdfr.transfer(bob, 500e18);
        vm.warp(block.timestamp + 100 days);
        (, uint256 pts,) = points.pointsBreakdown(alice);
        uint256 uRate = points.ratePerUnitDay() * points.usdfrMultiplierBps() / 10_000;
        // remaining 500 USDfr, maturity start still `start` (patience preserved)
        uint256 exp1 = _refPoints(1_000e18, UUNIT, uRate, start, start, start + 100 days);
        uint256 exp2 = _refPoints(500e18, UUNIT, uRate, start, start + 100 days, start + 200 days);
        assertApproxEqRel(pts, exp1 + exp2, 1e12, "withdrawal keeps maturity start");
    }

    // ── permissionless: a non-KYC'd wallet accrues ───────────────────────

    function test_permissionless_nonKYCWalletAccrues() public {
        _mintUSDfr(alice, 1_000e6);
        vm.prank(alice);
        usdfr.transfer(carol, 1_000e18); // carol is NOT KYC-allowed
        uint256 start = block.timestamp;
        vm.warp(start + 30 days);
        (, uint256 pts,) = points.pointsBreakdown(carol);
        assertGt(pts, 0, "non-KYC'd holder accrues points (permissionless)");
    }

    // ── fail-open: a reverting points module never blocks a transfer ─────

    function test_failOpen_revertingPointsDoesNotBlockTransfers() public {
        _mintUSDfr(alice, 1_000e6);
        RevertingPoints bad = new RevertingPoints();
        vm.startPrank(admin);
        usdfr.setPointsModule(address(bad));
        vault.setPointsModule(address(bad));
        vm.stopPrank();

        // USDfr transfer still succeeds despite the reverting hook
        vm.prank(alice);
        usdfr.transfer(bob, 100e18);
        assertEq(usdfr.balanceOf(bob), 100e18);

        // and a stake (sUSDfr mint) still succeeds
        uint256 shares = _stake(alice, 100e6);
        assertGt(shares, 0);
    }

    // ── protocol-exempt addresses do not accrue (AUDIT FIX) ──────────────

    function test_protocolExemptAddress_doesNotAccrue() public {
        address module = makeAddr("someProtocolModule");
        vm.prank(admin);
        compliance.setProtocolExempt(module, true);

        _getUsdfr(alice, 1_000e6);
        vm.prank(alice);
        usdfr.transfer(module, 1_000e18); // module custodies USDfr
        vm.warp(block.timestamp + 30 days);

        (uint256 s, uint256 u,) = points.pointsBreakdown(module);
        assertEq(s + u, 0, "protocol-exempt address accrues nothing");
        (uint256 shares, uint256 usdfrBal) = points.trackedBalances(module);
        assertEq(shares + usdfrBal, 0, "exempt address is not tracked");

        // and the totals exclude the exempt-held balance
        (, uint256 totalU,) = points.totals();
        assertEq(totalU, 0, "exempt-held USDfr not in totals");
    }

    // ── access control on the hooks ──────────────────────────────────────

    function test_onSharesTransfer_onlyVault() public {
        vm.expectRevert(PointsModule.Points_OnlyVault.selector);
        points.onSharesTransfer(alice, bob, 1e24);
    }

    function test_onUSDfrTransfer_onlyUSDfr() public {
        vm.expectRevert(PointsModule.Points_OnlyUSDfr.selector);
        points.onUSDfrTransfer(alice, bob, 1e18);
    }

    // ── governance ───────────────────────────────────────────────────────

    function test_setRate_onlyAdminAndBounded() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        points.setRate(1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadRate.selector, type(uint256).max));
        points.setRate(type(uint256).max);

        vm.prank(admin);
        points.setRate(2e18);
        assertEq(points.ratePerUnitDay(), 2e18);
    }

    function test_F10_rateEpochAppendedPinsIndexAndAllData() public {
        uint256 nextIndex = points.rateEpochCount();
        uint32 usdfrMultiplier = points.usdfrMultiplierBps();
        uint32 curatorMultiplier = points.curatorMultiplierBps();

        vm.expectEmit(true, false, false, true);
        emit PointsModule.RateEpochAppended(nextIndex, 2e18, usdfrMultiplier, curatorMultiplier);
        vm.prank(admin);
        points.setRate(2e18);

        assertEq(points.rateEpochCount(), nextIndex + 1, "rate setter appends exactly one epoch");
    }

    function test_setUSDfrMultiplier_onlyAdminAndBounded() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        points.setUSDfrMultiplier(20_000);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(0)));
        points.setUSDfrMultiplier(0);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(200_001)));
        points.setUSDfrMultiplier(200_001);
        points.setUSDfrMultiplier(50_000); // 5x
        vm.stopPrank();
        assertEq(uint256(points.usdfrMultiplierBps()), 50_000);
    }

    function test_setCuratorMultiplier_onlyAdminAndBounded() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        points.setCuratorMultiplier(20_000);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(0)));
        points.setCuratorMultiplier(0);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(200_001)));
        points.setCuratorMultiplier(200_001);
        points.setCuratorMultiplier(70_000);
        vm.stopPrank();
        assertEq(uint256(points.curatorMultiplierBps()), 70_000);
    }

    function test_F4_multiplierSettersAcceptExactMaxAndRejectOneAbove() public {
        vm.startPrank(admin);
        points.setUSDfrMultiplier(200_000);
        points.setCuratorMultiplier(200_000);
        assertEq(uint256(points.usdfrMultiplierBps()), 200_000);
        assertEq(uint256(points.curatorMultiplierBps()), 200_000);

        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(200_001)));
        points.setUSDfrMultiplier(200_001);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(200_001)));
        points.setCuratorMultiplier(200_001);
        vm.stopPrank();
    }

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new PointsModule());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        points.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        points.upgradeToAndCall(newImpl, "");
    }

    function test_checkpoint_isHarmless() public {
        _mintUSDfr(alice, 1_000e6);
        vm.warp(block.timestamp + 10 days);
        uint256 before = points.pointsOfWallet(alice);
        points.checkpoint(alice); // permissionless, no state break
        assertApproxEqRel(points.pointsOfWallet(alice), before, 1e12);
    }

    // ── P-03: rate/multiplier changes are NON-retroactive ────────────────

    function test_P03_rateChangeIsNotRetroactive() public {
        _mintUSDfr(alice, 1_000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 pastPoints = points.pointsOfWallet(alice);
        assertGt(pastPoints, 0);

        // double the USDfr multiple (3x -> 6x); already-elapsed time must NOT be repriced
        vm.prank(admin);
        points.setUSDfrMultiplier(60_000);
        assertApproxEqRel(points.pointsOfWallet(alice), pastPoints, 1e12, "past not repriced by a rate change");

        // the next window accrues at the new, higher rate
        vm.warp(block.timestamp + 30 days);
        uint256 delta = points.pointsOfWallet(alice) - pastPoints;
        assertGt(delta, pastPoints, "the 6x window earns more than the earlier 3x window");
    }

    // ── P-02: reconcile fixes an exemption toggle ────────────────────────

    function test_P02_reconcileAfterExemptionToggle() public {
        _mintUSDfr(alice, 1_000e6);
        vm.warp(block.timestamp + 10 days);
        (, uint256 uBal) = points.trackedBalances(alice);
        assertEq(uBal, 1_000e18, "tracked before toggle");

        // alice becomes protocol-exempt — she should no longer accrue; reconcile enforces it
        vm.prank(admin);
        compliance.setProtocolExempt(alice, true);
        points.reconcile(alice);
        (, uint256 uAfter) = points.trackedBalances(alice);
        assertEq(uAfter, 0, "reconcile zeroed the now-exempt position");
    }

    // ── P-04: reconcile recovers a dropped (fail-open) transition ────────

    function test_P04_reconcileRecoversDroppedTransition() public {
        // point USDfr at a reverting module so bob's incoming transfer is dropped fail-open
        RevertingPoints bad = new RevertingPoints();
        vm.prank(admin);
        usdfr.setPointsModule(address(bad));
        _mintUSDfr(alice, 1_000e6);
        vm.prank(alice);
        usdfr.transfer(bob, 1_000e18); // the real points module never saw this

        // wire the real module back and reconcile bob against his LIVE balance
        vm.prank(admin);
        usdfr.setPointsModule(address(points));
        points.reconcile(bob);
        (, uint256 uBal) = points.trackedBalances(bob);
        assertEq(uBal, 1_000e18, "reconcile set bob to his live USDfr balance");

        vm.warp(block.timestamp + 10 days);
        (, uint256 pts,) = points.pointsBreakdown(bob);
        assertGt(pts, 0, "bob accrues after reconcile");
    }
}
