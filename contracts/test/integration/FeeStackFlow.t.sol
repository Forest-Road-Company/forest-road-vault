// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

contract YieldWindowCheckpointProbe is IPointsModule {
    IsUSDfr internal immutable VAULT;

    uint256 public attempts;
    bytes4 public lastRevertSelector;
    bool public unexpectedSuccess;

    constructor(IsUSDfr vault_) {
        VAULT = vault_;
    }

    function onUSDfrTransfer(address, address, uint256) external {
        attempts++;
        try VAULT.accrueFees() returns (uint256, uint256) {
            unexpectedSuccess = true;
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            lastRevertSelector = selector;
        }
    }

    function onSharesTransfer(address, address, uint256) external {}
    function onCuratorStakeChange(address, uint256, uint256) external {}
    function onCuratorLoss(uint256, uint256, uint256) external {}
}

/// @notice End-to-end example for the agreed 10% interest deduction plus 10% global
///         performance fee. A 20% gross facility return leaves depositors 16.2%.
contract FeeStackFlowTest is CreditLayerFixture {
    function _hurdleAssets() internal view returns (uint256) {
        return Math.mulDiv(vault.highWaterMark(), vault.totalSupply() + 1e6, 10 ** vault.decimals(), Math.Rounding.Ceil);
    }

    function test_twentyPercentGrossReturnNetsSixteenPointTwoPercentToDepositor() public {
        uint256 id = _liveFilmFacility(1_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000e18);
        uint256 aliceShares = vault.deposit(1_000e18, alice);
        vm.stopPrank();

        uint256 feeUsdfrBefore = usdfr.balanceOf(feeRecipient);
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        _repay(id, 200e18, 0);

        assertEq(usdfr.balanceOf(feeRecipient) - feeUsdfrBefore, 20e18, "existing 10% interest deduction remains first");
        assertEq(vault.unvestedYield(), 0, "launch recognizes the remaining senior yield immediately");
        assertEq(vault.managementFeeBps(), Config.DEFAULT_MANAGEMENT_FEE_BPS);

        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(feeRecipient) - feeSharesBefore),
            18e18,
            2,
            "the repayment transaction takes 10% of the post-interest-fee 180 profit"
        );
        assertApproxEqAbs(
            vault.convertToAssets(aliceShares), 1_162e18, 2, "depositor receives principal plus 16.2% net return"
        );
        (, uint256 duplicatePerformanceShares) = vault.accrueFees();
        assertEq(duplicatePerformanceShares, 0, "the repayment checkpoint cannot be charged twice");
    }

    function test_liveQueueExitDuringPastDueCarriesHurdleAndCureMintsNoFee() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 700_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000_000e18);
        uint256 aliceShares = vault.deposit(1_000_000e18, alice);
        vm.stopPrank();
        // Supply a full settlement budget without changing vault assets.
        _mintUSDfrTo(bob, 1_000_000e18);
        vm.prank(admin);
        queue.setEpochLiquidityBps(uint16(Config.BPS));

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18);

        uint256 sharesToExit = aliceShares / 2;
        vm.startPrank(alice);
        vault.approve(address(queue), sharesToExit);
        uint256 requestId = queue.requestRedeem(sharesToExit);
        vm.stopPrank();

        uint256 hurdleBefore = _hurdleAssets();
        uint256 settleAt = block.timestamp + queue.redeemCooldown();
        uint256 epochEnd = queue.epochEndsAt();
        if (settleAt < epochEnd) settleAt = epochEnd;
        vm.warp(settleAt);
        queue.closeEpoch(10);
        (, uint256 remaining, uint256 claimable,,) = queue.request(requestId);
        assertEq(remaining, 0, "the live queue burned the requested shares");
        assertApproxEqAbs(claimable, 350_000e18, 1, "exit used the conservative marked NAV");
        assertApproxEqAbs(
            _hurdleAssets(),
            hurdleBefore - claimable,
            1,
            "the live queue exit carried out the same asset hurdle as payout"
        );

        _clearPastDue(id, keccak256("queue-cure"));
        (, uint256 performanceShares) = vault.accrueFees();
        assertEq(performanceShares, 0, "a cure after a live queue exit cannot mint phantom fee shares");
    }

    function test_liveQueueExitWithProductionDualNavCarriesProRataDeferredFee() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000_000e18);
        uint256 aliceShares = vault.deposit(1_000_000e18, alice);
        vm.stopPrank();

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "junior capital fully protects redemption NAV");
        assertEq(defaultManager.performanceFeeImpairment(), 1_000_000e18, "fee NAV retains gross impairment");

        // Real yield restores performance NAV only to the old hurdle while junior
        // capital makes redemption NAV twice as high. This is the production-wired
        // divergent state the old queue campaign could not express.
        _mintUSDfrTo(bob, 1_000_000e18);
        vm.prank(bob);
        usdfr.transfer(address(vault), 1_000_000e18);
        vault.accrueFees();
        assertApproxEqAbs(vault.feeExchangeRate(), vault.highWaterMark(), 1);
        assertGt(vault.currentExchangeRate(), vault.feeExchangeRate());

        vm.prank(admin);
        queue.setEpochLiquidityBps(uint16(Config.BPS));
        uint256 sharesToExit = aliceShares / 2;
        vm.startPrank(alice);
        vault.approve(address(queue), sharesToExit);
        uint256 requestId = queue.requestRedeem(sharesToExit);
        vm.stopPrank();

        uint256 hurdleBefore = _hurdleAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 settleAt = block.timestamp + queue.redeemCooldown();
        uint256 epochEnd = queue.epochEndsAt();
        if (settleAt < epochEnd) settleAt = epochEnd;
        vm.warp(settleAt);
        queue.closeEpoch(1);

        (, uint256 remaining, uint256 claimable,,) = queue.request(requestId);
        assertEq(remaining, 0);
        uint256 assetCarry = claimable >= hurdleBefore ? 0 : hurdleBefore - claimable;
        uint256 proRataCarry =
            Math.mulDiv(hurdleBefore, vault.totalSupply() + 1e6, supplyBefore + 1e6, Math.Rounding.Ceil);
        uint256 expectedHurdle = Math.max(assetCarry, proRataCarry);
        uint256 roundingDust = Math.ceilDiv(vault.totalSupply() + 1e6, 10 ** vault.decimals());
        assertApproxEqAbs(
            _hurdleAssets(),
            expectedHurdle,
            roundingDust,
            "production queue exit retains the stayers' pro-rata deferred-fee hurdle"
        );

        _clearPastDue(id, keccak256("dual-nav-queue-cure"));
        (, uint256 performanceShares) = vault.accrueFees();
        assertApproxEqAbs(
            vault.convertToAssets(performanceShares),
            50_000e18,
            10,
            "only the remaining half of deferred profit is charged on cure"
        );
    }

    // PUBLIC-SNAPSHOT NOTE: the executable characterization of the accepted, still-live
    // global-HWM round-trip residual is retained in the private audit evidence archive. Its
    // mechanism, impact, disposition and revisit conditions remain disclosed in ADR-0031 and
    // the audit register; this public package deliberately omits the runnable reproduction.

    function test_curatorCapacityRoundTripIsFeeNeutralDuringPastDueWorkout() public {
        uint256 id = _liveFilmFacility(2_000_000e18);
        vm.prank(admin);
        curator.setFirstLossTarget(Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 2_000_000e18);
        vault.deposit(2_000_000e18, alice);
        vm.stopPrank();

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18);
        uint256 hurdleBefore = _hurdleAssets();
        uint256 feeRateBefore = vault.feeExchangeRate();

        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 500_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 500_000e18);
        assertEq(_hurdleAssets(), hurdleBefore, "junior capital cannot mutate the permanent HWM hurdle");
        assertEq(vault.feeExchangeRate(), feeRateBefore, "junior capital cannot move performance-fee NAV");
        (, uint256 postFeeShares) = vault.accrueFees();
        assertEq(postFeeShares, 0, "junior capital is not senior investment performance");

        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 500_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18);
        assertEq(_hurdleAssets(), hurdleBefore, "capacity round trip leaves the permanent hurdle untouched");
        assertEq(vault.feeExchangeRate(), feeRateBefore, "capacity round trip is path independent");

        _clearPastDue(id, keccak256("curator-round-trip-cure"));
        (, uint256 cureFeeShares) = vault.accrueFees();
        assertEq(cureFeeShares, 0);
    }

    function test_capacityWithdrawalAndCureArePathIndependent() public {
        uint256 id = _liveFilmFacility(2_000_000e18);
        vm.prank(admin);
        curator.setFirstLossTarget(Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 1_500_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 2_000_000e18);
        vault.deposit(2_000_000e18, alice);
        vm.stopPrank();

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        uint256 snapshot = vm.snapshotState();

        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 500_000e18);
        _clearPastDue(id, keccak256("withdraw-then-cure"));
        (, uint256 pathAFeeShares) = vault.accrueFees();
        uint256 pathAHwm = vault.highWaterMark();
        uint256 pathARate = vault.feeExchangeRate();
        assertEq(pathAFeeShares, 0, "withdraw-then-cure cannot manufacture performance");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore);

        assertTrue(vm.revertToState(snapshot));
        _clearPastDue(id, keccak256("cure-then-withdraw"));
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 500_000e18);
        (, uint256 pathBFeeShares) = vault.accrueFees();

        assertEq(pathBFeeShares, 0, "cure-then-withdraw cannot manufacture performance");
        assertEq(vault.balanceOf(feeRecipient), feeSharesBefore);
        assertEq(vault.highWaterMark(), pathAHwm, "identical end states need identical HWM");
        assertEq(vault.feeExchangeRate(), pathARate, "identical end states need identical fee rate");
    }

    function test_capacityIncreaseCannotForfeitRealYieldAfterCure() public {
        uint256 id = _liveFilmFacility(2_000_000e18);
        vm.prank(admin);
        curator.setFirstLossTarget(Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 2_000_000e18);
        vault.deposit(2_000_000e18, alice);
        vm.stopPrank();

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);
        uint256 hwmBefore = vault.highWaterMark();

        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 500_000e18);
        assertEq(vault.highWaterMark(), hwmBefore, "capacity increase cannot over-raise the permanent HWM");

        _mintUSDfrTo(bob, 200_000e18);
        vm.prank(bob);
        usdfr.transfer(address(vault), 200_000e18);
        _clearPastDue(id, keccak256("capacity-increase-yield-cure"));

        (, uint256 performanceShares) = vault.accrueFees();
        assertApproxEqAbs(
            vault.convertToAssets(performanceShares),
            20_000e18,
            10,
            "cure charges exactly 10% of real yield, not junior capital"
        );
    }

    function testFuzz_fullCureMintsNoPerformanceSharesAcrossJuniorCapacityWrites(
        uint96 postedSeed,
        uint96 withdrawnSeed
    ) public {
        uint256 id = _liveFilmFacility(2_000_000e18);
        vm.prank(admin);
        curator.setFirstLossTarget(Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 2_000_000e18);
        vault.deposit(2_000_000e18, alice);
        vm.stopPrank();

        uint64 nextDue = bridge.facility(id).nextPaymentDue;
        vm.warp(uint256(nextDue) + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1);
        defaultManager.markPastDue(id);

        uint256 posted = bound(uint256(postedSeed), 1e12, 500_000e18);
        posted -= posted % 1e12;
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, posted);

        uint256 withdrawn = bound(uint256(withdrawnSeed), 0, posted);
        if (withdrawn != 0) {
            vm.prank(anchorCurator);
            curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, withdrawn);
        }

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        _clearPastDue(id, keccak256(abi.encode("fuzz-full-cure", posted, withdrawn)));
        (, uint256 performanceShares) = vault.accrueFees();

        assertEq(performanceShares, 0, "full cure with no yield cannot create performance");
        assertEq(
            vault.balanceOf(feeRecipient),
            feeSharesBefore,
            "full cure property is independent of HWM as a legality witness"
        );
    }

    function test_yieldDeliveryVaultLockRejectsMidWindowCheckpoint() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 1_000_000e18);
        vault.deposit(1_000_000e18, alice);
        vm.stopPrank();

        YieldWindowCheckpointProbe probe = new YieldWindowCheckpointProbe(vault);
        vm.prank(admin);
        usdfr.setPointsModule(address(probe));

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        _repay(id, 200_000e18, 0);

        assertEq(probe.attempts(), 2, "both protocol-fee and vault yield mints reached the probe");
        assertEq(probe.lastRevertSelector(), IsUSDfr.SUSDfr_FeeAccrualReentrant.selector);
        assertFalse(probe.unexpectedSuccess(), "no callback checkpoint entered the delivery window");
        assertEq(vault.unvestedYield(), 0, "launch recognizes the delivery immediately");
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(feeRecipient) - feeSharesBefore),
            18_000e18,
            2,
            "performance fee crystallizes only after the protected delivery window closes"
        );
        (, uint256 duplicatePerformanceShares) = vault.accrueFees();
        assertEq(duplicatePerformanceShares, 0);
    }

    function test_defaultCheckpointsFeesBeforeImpairmentThenRunsRecoveryAndDepositorLoss() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _mintUSDfrTo(alice, 500_000e18);
        _mintUSDfrTo(bob, 500_000e18);

        vm.startPrank(alice);
        usdfr.approve(address(vault), 500_000e18);
        uint256 aliceShares = vault.deposit(500_000e18, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        usdfr.approve(address(vault), 500_000e18);
        uint256 bobShares = vault.deposit(500_000e18, bob);
        vm.stopPrank();

        vm.prank(admin);
        vault.setManagementFee(100); // exercise the live 1% annual geometric path
        _repay(id, 200_000e18, 0);
        vm.warp(block.timestamp + 30 days);

        // The repayment already crystallized the performance fee. A prospective
        // management fee then becomes economically due before the declaration, which
        // must record it against the performing mark before installing the impairment.
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        uint256 feeNetRateBeforeDefault = vault.currentExchangeRate();
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        assertGt(vault.balanceOf(feeRecipient), feeSharesBefore, "default crystallized pre-impairment fees");
        assertApproxEqAbs(
            vault.currentExchangeRate(),
            feeNetRateBeforeDefault,
            1,
            "crystallization records, rather than repeats, fee dilution"
        );
        assertEq(defaultManager.pendingSeniorImpairment(), 1_000_000e18);

        vm.prank(servicer);
        defaultManager.accelerate(id);
        _repay(id, 0, 600_000e18); // remedy proceeds reduce the claim to 400k
        assertEq(reserves.deployedTo(id), 400_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 400_000e18);

        uint256 rateBeforeLoss = vault.currentExchangeRate();
        uint256 hwmBeforeLoss = vault.highWaterMark();
        _realizeLoss(id, 400_000e18, FILM_REF);

        assertLt(vault.currentExchangeRate(), rateBeforeLoss, "only the explicit depositor loss lowers realized NAV");
        assertEq(vault.highWaterMark(), hwmBeforeLoss, "loss cannot lower the charged performance hurdle");
        assertApproxEqAbs(
            vault.convertToAssets(aliceShares),
            vault.convertToAssets(bobShares),
            1,
            "the two equal depositors bear fee dilution and loss pro rata"
        );
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved));
        assertEq(reserves.deployedTo(id), 0);
        assertTrue(controller.backingInvariantHolds());
    }
}
