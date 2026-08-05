// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CollateralFixture} from "../helpers/CollateralFixture.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

contract AuditOracleRevocationRollbackProofTest is Test {
    AttestationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    uint256 internal pk1 = 0xA11CE;
    uint256 internal pk2 = 0xB0B;
    uint256 internal constant FACILITY = 1;

    function setUp() public {
        vm.warp(1_750_000_000);
        oracle = AttestationOracle(
            address(
                new ERC1967Proxy(
                    address(new AttestationOracle()),
                    abi.encodeCall(AttestationOracle.initialize, (admin, guardian, admin))
                )
            )
        );
        vm.startPrank(admin);
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pk1));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(pk2));
        vm.stopPrank();
    }

    /// @notice H-02 FIXED: revoking a valuation does NOT open a rollback window.
    /// @dev This test previously PINNED the vulnerability, asserting that the older mark
    ///      became live. That was deliberate — it recorded the defect while the fix was an
    ///      open owner decision. Forest Road resolved it on 2026-07-21 (keep the anti-rollback
    ///      watermark, with a constrained recovery lever), so the test now asserts the
    ///      opposite: the replay is REJECTED, and the facility is left with no live mark
    ///      rather than a stale one steering `ReserveManager.totalBackingValue()`.
    function test_h02_revokeDoesNotOpenARollbackWindow() public {
        IAttestationOracle.AttestationInput memory oldMark = _input(
            IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(600_000e18)), uint64(block.timestamp - 120), 1
        );
        IAttestationOracle.AttestationInput memory newerMark = _input(
            IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(900_000e18)), uint64(block.timestamp - 60), 2
        );

        oracle.attest(newerMark, _sigs2(newerMark));
        (uint256 valueBefore, uint64 asOfBefore) = oracle.latestValuation(FACILITY);
        assertEq(valueBefore, 900_000e18);
        assertEq(asOfBefore, newerMark.asOf);
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "watermark tracks the accepted mark");

        vm.prank(admin);
        oracle.revoke(FACILITY, IAttestationOracle.AttestationKind.Valuation);

        // The live mark is gone (the emergency stop worked) but the clock did NOT rewind.
        (uint256 revokedValue, uint64 revokedAsOf) = oracle.latestValuation(FACILITY);
        assertEq(revokedValue, 0, "revoke zeroes the live mark");
        assertEq(revokedAsOf, 0, "revoke zeroes the live asOf");
        assertEq(oracle.valuationWatermark(FACILITY), newerMark.asOf, "watermark SURVIVES revocation");

        // The older, validly-signed bundle can no longer be replayed. NB: the signatures are
        // built FIRST — `_sigs2` calls `oracle.attestationDigest`, and an external call in the
        // argument list would consume the `vm.expectRevert` before `attest` is even reached.
        bytes[] memory staleSigs = _sigs2(oldMark);
        vm.expectRevert(
            abi.encodeWithSelector(IAttestationOracle.Oracle_StaleValuation.selector, oldMark.asOf, newerMark.asOf)
        );
        oracle.attest(oldMark, staleSigs);

        (uint256 valueAfter,) = oracle.latestValuation(FACILITY);
        assertEq(valueAfter, 0, "no stale mark became live; backing reads zero until a fresh appraisal");
    }

    function _input(IAttestationOracle.AttestationKind kind, bytes32 payload, uint64 asOf, uint256 nonce)
        internal
        view
        returns (IAttestationOracle.AttestationInput memory)
    {
        return IAttestationOracle.AttestationInput({
            facilityId: FACILITY,
            kind: kind,
            payload: payload,
            asOf: asOf,
            expiry: uint64(block.timestamp + 1 hours),
            nonce: nonce
        });
    }

    function _sign(uint256 pk, IAttestationOracle.AttestationInput memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, oracle.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _sigs2(IAttestationOracle.AttestationInput memory a) internal view returns (bytes[] memory sigs) {
        (uint256 lo, uint256 hi) = vm.addr(pk1) < vm.addr(pk2) ? (pk1, pk2) : (pk2, pk1);
        sigs = new bytes[](2);
        sigs[0] = _sign(lo, a);
        sigs[1] = _sign(hi, a);
    }
}

contract AuditConcentrationDecreaseDriftProofTest is CollateralFixture {
    /// @dev AUDIT FIX M-02 — this was the proof of the vulnerability; it is now the
    ///      REGRESSION GUARD. The drift itself is irreducible (a decrease may never be
    ///      blocked, or a risk limit would sit ahead of the loss cascade), so what is
    ///      asserted is the pair of properties the fix actually adds:
    ///        - the standing breach is DISCLOSED (bitmap + `ConcentrationDrift`), and
    ///        - the breached class can no longer be GROWN, at the shipped floor or any
    ///          other, whether the book stands above the floor or has shrunk back below it.
    ///      Note the floor is now set AFTER the book is built: at `floor = 800e18` an
    ///      800e18 facility in a class capped at 3500bps is itself inadmissible, because a
    ///      dimension is capped at `limitBps` of `max(book, floor)` rather than exempted up
    ///      to the floor.
    function test_fixedBehavior_driftIsDisclosedAndTheBreachedClassCannotBeGrown() public {
        bytes32 b3 = keccak256("borrower-3");
        bytes32 b4 = keccak256("borrower-4");
        bytes32 b5 = keccak256("borrower-5");

        vm.startPrank(creditModule);
        registry.recordExposureIncrease(Config.CLASS_FILM_TAX_CREDITS, BORROWER_1, bytes32(0), 800e18);
        registry.recordExposureIncrease(Config.CLASS_RENEWABLE_ENERGY, BORROWER_2, bytes32(0), 800e18);
        registry.recordExposureIncrease(Config.CLASS_LIFE_SCIENCES, b3, bytes32(0), 800e18);
        registry.recordExposureIncrease(Config.CLASS_REAL_ESTATE, b4, bytes32(0), 800e18);
        registry.recordExposureIncrease(Config.CLASS_DIGITAL_ASSETS, b5, bytes32(0), 800e18);
        vm.stopPrank();

        vm.prank(admin);
        registry.setConcentrationFloor(800e18);
        assertEq(registry.classExposure(Config.CLASS_DIGITAL_ASSETS), 800e18);
        assertEq(registry.totalBookExposure(), 4_000e18);
        assertEq(registry.overConcentratedClasses(), 0, "balanced book, nothing disclosed yet");

        vm.startPrank(creditModule);
        registry.recordExposureDecrease(Config.CLASS_FILM_TAX_CREDITS, BORROWER_1, bytes32(0), 800e18);
        registry.recordExposureDecrease(Config.CLASS_RENEWABLE_ENERGY, BORROWER_2, bytes32(0), 800e18);
        registry.recordExposureDecrease(Config.CLASS_LIFE_SCIENCES, b3, bytes32(0), 800e18);
        registry.recordExposureDecrease(Config.CLASS_REAL_ESTATE, b4, bytes32(0), 800e18);
        vm.stopPrank();

        assertEq(registry.classExposure(Config.CLASS_DIGITAL_ASSETS), 800e18);
        assertEq(registry.totalBookExposure(), 800e18);
        assertGt(
            registry.classExposure(Config.CLASS_DIGITAL_ASSETS) * Config.BPS / registry.totalBookExposure(),
            registry.classParams(Config.CLASS_DIGITAL_ASSETS).concentrationLimitBps,
            "digital-assets class remains above the configured limit"
        );

        // ── the regression guard: the drift is no longer SILENT... ────────
        assertEq(
            registry.overConcentratedClasses(),
            1 << (Config.CLASS_DIGITAL_ASSETS - 1),
            "M-02: the standing breach is now disclosed on-chain"
        );
        (bool classOver,,) = registry.isOverConcentrated(Config.CLASS_DIGITAL_ASSETS, b5, bytes32(0));
        assertTrue(classOver, "M-02: and readable per dimension");

        // ── ...and the breached class can no longer be GROWN ──────────────
        // the book (800e18) now sits exactly at the floor, the state in which round 1 still
        // leaked; the class allowance is 3500bps of 800e18 = 280e18 and is already blown
        assertEq(
            registry.concentrationHeadroom(Config.CLASS_DIGITAL_ASSETS, keccak256("fresh"), bytes32(0)),
            0,
            "M-02: no headroom in a breached class"
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector,
                Config.CLASS_DIGITAL_ASSETS,
                800e18 + 1,
                2000
            )
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(Config.CLASS_DIGITAL_ASSETS, keccak256("fresh"), bytes32(0), 1);
        assertEq(registry.classExposure(Config.CLASS_DIGITAL_ASSETS), 800e18, "M-02: nothing was added");
    }
}

contract AuditPointsCheckpointBypassProofTest is CreditLayerFixture {
    PointsModule internal points;

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
        points.setCuratorModule(address(curator));
        curator.setPointsModule(address(points));
        vm.stopPrank();
    }

    /// @dev H-03 REGRESSION GUARD (was `test_currentBehavior_checkpointLetsStaleCuratorBalance
    ///      ResumeAfterLoss`, the proof-of-vulnerability). The permissionless `checkpoint()` used
    ///      to advance `lastAccrual` past the loss instant, which stopped the freeze guard
    ///      matching and resumed accrual on wiped first-loss capital at the 5x curator multiple.
    ///      The freeze is now a state watermark (`seenLossEpoch` vs the class's append-only
    ///      loss log) that a checkpoint cannot move, and the checkpoint additionally writes the
    ///      stale-high cached balance DOWN by the exact pro-rata dilution the loss applied.
    ///      Same exploit steps, inverted assertions: it must now be neutralised.
    function test_regression_checkpointCannotResumeStaleCuratorBalanceAfterLoss() public {
        _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, 1_000_000e18);
        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        curator.grantRole(Roles.CREDIT_ROLE, address(this));
        curator.absorbLoss(Config.CLASS_FILM_TAX_CREDITS, 500_000e18);
        (,, uint256 pointsAtLoss) = points.pointsBreakdown(anchorCurator);

        points.checkpoint(anchorCurator);
        vm.warp(block.timestamp + 60 days);
        (,, uint256 pointsAfterCheckpoint) = points.pointsBreakdown(anchorCurator);

        assertEq(
            pointsAfterCheckpoint,
            pointsAtLoss,
            "a permissionless checkpoint must NOT resume accrual on impaired curator capital"
        );
        // the checkpoint may only move the position DOWN: onto the live, diluted posted amount
        assertEq(points.curatorTracked(anchorCurator, Config.CLASS_FILM_TAX_CREDITS), 500_000e18);
        assertEq(curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, anchorCurator), 500_000e18);
        (bool frozen,) = points.curatorFreezeStatus(anchorCurator, Config.CLASS_FILM_TAX_CREDITS);
        assertTrue(frozen, "the freeze survives the checkpoint; only reconcile clears it");
    }
}

contract AuditRedemptionQueueCooldownAndPricingProofTest is CreditLayerFixture {
    function test_currentBehavior_cooldownBlocksSettlementBeforeConfiguredHold() public {
        uint256 shares = _stakeUsdfr(alice, 100_000e6);

        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 requestId = queue.requestRedeem(shares);
        vm.stopPrank();
        uint256 requestedAt = block.timestamp;

        vm.warp(requestedAt + Config.DEFAULT_EPOCH_DURATION + 1);
        assertLt(
            block.timestamp,
            requestedAt + Config.DEFAULT_REDEEM_COOLDOWN,
            "this is still inside the configured 21-day cooldown"
        );

        uint256 eligibleAt = queue.eligibleToSettleAt(requestId);
        assertEq(eligibleAt, requestedAt + Config.DEFAULT_REDEEM_COOLDOWN);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, eligibleAt));
        queue.closeEpoch(1);

        (, uint256 remaining, uint256 claimable,,) = queue.request(requestId);
        assertEq(remaining, shares, "request did not settle before cooldown elapsed");
        assertEq(claimable, 0, "nothing became claimable before cooldown elapsed");

        vm.warp(eligibleAt);
        queue.closeEpoch(1);
        (, remaining, claimable,,) = queue.request(requestId);
        assertLt(remaining, shares, "request starts settling once cooldown elapses");
        assertGt(claimable, 0, "assets become claimable after cooldown elapses");
    }

    function test_currentBehavior_jitStakeCannotExitSameBlockAfterEpochLapsed() public {
        _stakeUsdfr(alice, 1_000_000e6);
        vm.warp(uint256(queue.epochEndsAt()) + 1);

        uint256 attackerPrincipal = 1_000e18;
        uint256 attackerShares = _stakeUsdfr(bob, 1_000e6);

        vm.prank(admin);
        reserves.grantRole(Roles.CREDIT_ROLE, address(this));
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(reserves), 100_000e6);
        reserves.depositUSDC(address(this), 100_000e6);
        vm.prank(admin);
        controller.grantRole(Roles.CREDIT_ROLE, address(this));
        controller.mintYield(address(vault), 100_000e18);

        uint256 req = _queueRedeem(bob, attackerShares);
        uint256 eligibleAt = queue.eligibleToSettleAt(req);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, eligibleAt));
        queue.closeEpoch(1);

        (, uint256 remaining, uint256 claimable,,) = queue.request(req);
        assertEq(remaining, attackerShares, "JIT request did not exit in the lapsed epoch");
        assertEq(claimable, 0, "JIT request could not claim same-block yield");

        vm.warp(eligibleAt);
        queue.closeEpoch(1);
        (, remaining, claimable,,) = queue.request(req);
        assertEq(remaining, 0, "small request exits after the configured hold");
        assertGt(claimable, attackerPrincipal, "yield is only claimable after the holding period");

        vm.prank(bob);
        uint256 claimed = queue.claim(req);
        assertEq(claimed, claimable);
    }

    function test_currentBehavior_exitBetweenDeclareDefaultAndRealizeLossCannotLockPreLossNav() public {
        _stakeUsdfr(alice, 1_000_000e6);
        uint256 bobShares = _stakeUsdfr(bob, 1_000e6);

        uint256 facilityId = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        _fundFacility(facilityId, 500_000e18);

        vm.warp(uint256(queue.epochEndsAt()) + 1);
        _attestDefault(facilityId);
        vm.prank(servicer);
        defaultManager.declareDefault(facilityId, FILM_REF);

        uint256 preLossAssets = vault.convertToAssets(bobShares);
        uint256 req = _queueRedeem(bob, bobShares);
        uint256 eligibleAt = queue.eligibleToSettleAt(req);
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, eligibleAt));
        queue.closeEpoch(1);

        (, uint256 remaining, uint256 claimable,,) = queue.request(req);
        assertEq(remaining, bobShares, "redeemer did not exit before the loss was realized");
        assertEq(claimable, 0, "pre-loss claim was not locked");

        vm.prank(servicer);
        _realizeLoss(facilityId, 500_000e18, FILM_REF);

        uint256 sameSharesAfterLoss = vault.convertToAssets(bobShares);
        assertLt(sameSharesAfterLoss, preLossAssets, "loss reduced queued share value before settlement");

        vm.warp(eligibleAt);
        queue.closeEpoch(1);

        (, remaining, claimable,,) = queue.request(req);
        assertEq(remaining, 0, "small request exits after cooldown");
        assertEq(claimable, sameSharesAfterLoss, "claim is filled at post-loss NAV");

        vm.prank(bob);
        uint256 claimed = queue.claim(req);
        assertEq(claimed, claimable);
    }

    function _stakeUsdfr(address user, uint256 usdcAmount) internal returns (uint256 shares) {
        uint256 minted = _mintUSDfr(user, usdcAmount);
        vm.startPrank(user);
        usdfr.approve(address(vault), minted);
        shares = vault.deposit(minted, user);
        vm.stopPrank();
    }

    function _queueRedeem(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.startPrank(user);
        vault.approve(address(queue), shares);
        requestId = queue.requestRedeem(shares);
        vm.stopPrank();
    }
}
