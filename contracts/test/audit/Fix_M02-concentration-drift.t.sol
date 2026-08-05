// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CollateralFixture} from "../helpers/CollateralFixture.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {CollateralHandler} from "../invariant/handlers/CollateralHandler.sol";

/// @dev AUDIT FIX M-02 — concentration limits were admission-time only and drifted above
///      the advertised cap.
///
///      THE RULE THE CONTRACT NOW ENFORCES, in one sentence: no exposure increase may leave
///      the class, borrower or state it touches holding more than its `limitBps` share of
///      `max(post-trade book, concentrationFloor)`.
///
///      Round 2 replaced the round-1 rule. Round 1 keyed the bootstrap exemption on the
///      BUCKET (`post-trade dimension <= floor`) plus an in-breach clause gated on
///      `total > floor`. Two reviewers proved that:
///        - at the SHIPPED floor (25,000,000e18) the in-breach clause never fired, so on
///          any launch- or testnet-scale book the enforcement half did nothing at all;
///        - it closed "deepen an existing breach" but not "create a fresh breach": on a
///          mature book, an origination landing under the absolute floor bypassed the
///          relative check entirely;
///        - an ordinary repayment that shrank the book back under the floor, and the
///          `total == floor` boundary, both re-opened the hole.
///      Keying the exemption on the BOOK — by measuring against `max(book, floor)` instead
///      of exempting anything — closes all four at once and is not a soft parameter
///      setting: below the floor the rule degrades to an ABSOLUTE allowance of
///      `limitBps * floor / BPS` per dimension (8.75m per 3500bps class, 3.75m per
///      borrower, 6.25m per state at the launch floor), not to "no limit". It is
///      continuous at the floor, monotone in the amount added, and adds no storage, so an
///      upgraded proxy whose appended slots read zero still enforces it in full.
///
///      What still holds and is asserted here:
///        1. no increase may leave a dimension above its limit against
///           `max(post-trade book, floor)` — creating a breach and deepening one are both
///           blocked, at every book size and every floor setting;
///        2. a standing breach is never silent — class, borrower and state transitions are
///           all evented, and `overConcentratedClasses` RECOMPUTES from the book so it can
///           never report a clean book on a freshly upgraded proxy whose cache reads zero;
///        3. NO concentration check can ever block a decrease. Repayment, default
///           write-down and `ClaimBridge.cancelPending` all route through
///           `recordExposureDecrease`, which cannot revert on a concentration ground; a
///           redemption never touches the registry at all.
///      It is NOT a continuous cap, and it cannot be: a shrinking book mechanically raises
///      the share held by whatever did not shrink, and blocking that would let a risk
///      limit veto a loss being realized — inverting the three-layer loss cascade.
contract M02ConcentrationDriftTest is CollateralFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant RENEW = Config.CLASS_RENEWABLE_ENERGY;
    uint256 internal constant LIFE = Config.CLASS_LIFE_SCIENCES;
    uint256 internal constant RE = Config.CLASS_REAL_ESTATE;
    uint256 internal constant DA = Config.CLASS_DIGITAL_ASSETS;

    /// @dev The launch-default bootstrap floor set by `initialize`.
    uint256 internal constant LAUNCH_FLOOR = 25_000_000e18;
    uint256 internal constant MAX_SAFE_EXPOSURE = type(uint256).max / Config.BPS;

    bytes32 internal B3 = keccak256("borrower-3");
    bytes32 internal B4 = keccak256("borrower-4");
    bytes32 internal B5 = keccak256("borrower-5");
    bytes32 internal FRESH = keccak256("fresh-borrower");

    // ── 1. the finding itself: drift is now evented and observable ───────

    /// @dev The `PreMainnetFindings` reproduction, replayed: four decreases leave the
    ///      digital-assets class above its 20% cap on the remaining book. The breach is
    ///      unavoidable — but it is now announced at the exact transition and readable
    ///      afterwards, instead of being a silent divergence from the advertised cap.
    function test_driftIsEventedAtEveryTransitionAndReadableAfterwards() public {
        vm.startPrank(creditModule);
        registry.recordExposureIncrease(FILM, BORROWER_1, bytes32(0), 800e18);
        registry.recordExposureIncrease(RENEW, BORROWER_2, bytes32(0), 800e18);
        registry.recordExposureIncrease(LIFE, B3, bytes32(0), 800e18);
        registry.recordExposureIncrease(RE, B4, bytes32(0), 800e18);
        registry.recordExposureIncrease(DA, B5, bytes32(0), 800e18);
        vm.stopPrank();

        // 5 x 800 = 20% each: nothing is in breach yet
        assertEq(registry.overConcentratedClasses(), 0, "no breach on a balanced book");
        assertEq(registry.classConcentrationBps(DA), 2000, "digital assets at exactly its cap");

        // decrease 1: book 4000 -> 3200, every survivor to 25%; only DA (2000bps) breaks
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationDrift(DA, 800e18, 3200e18, 2000, false);
        vm.prank(creditModule);
        registry.recordExposureDecrease(FILM, BORROWER_1, bytes32(0), 800e18);
        assertEq(registry.overConcentratedClasses(), 1 << (DA - 1), "DA flagged");

        // decrease 2: book -> 2400, survivors to 3333bps; life sciences (3000) breaks too
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationDrift(LIFE, 800e18, 2400e18, 3000, false);
        vm.prank(creditModule);
        registry.recordExposureDecrease(RENEW, BORROWER_2, bytes32(0), 800e18);
        assertEq(registry.overConcentratedClasses(), (1 << (LIFE - 1)) | (1 << (DA - 1)), "LIFE + DA flagged");

        // decrease 3: LIFE itself is retired (heals) while real estate breaks at 50%
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationHealed(LIFE, 0, 1600e18, 3000, false);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationDrift(RE, 800e18, 1600e18, 3500, false);
        vm.prank(creditModule);
        registry.recordExposureDecrease(LIFE, B3, bytes32(0), 800e18);

        // decrease 4: 100% of the remaining book sits in digital assets
        vm.prank(creditModule);
        registry.recordExposureDecrease(RE, B4, bytes32(0), 800e18);

        assertEq(registry.classExposure(DA), 800e18);
        assertEq(registry.totalBookExposure(), 800e18);
        assertEq(registry.classConcentrationBps(DA), Config.BPS, "100% of the book");
        assertEq(registry.overConcentratedClasses(), 1 << (DA - 1), "only DA still in breach");
        (bool classOver, bool borrowerOver, bool stateOver) = registry.isOverConcentrated(DA, B5, bytes32(0));
        assertTrue(classOver, "class breach visible on-chain");
        assertTrue(borrowerOver, "borrower breach visible on-chain");
        assertFalse(stateOver, "no state tag on this class");
    }

    /// @dev The bitmap only fires on TRANSITIONS: a second decrease that leaves an
    ///      already-flagged class in breach must not re-announce it.
    function test_driftIsNotReAnnouncedWhileTheBreachStands() public {
        _seed(FILM, BORROWER_1, 800e18);
        _seed(DA, B5, 800e18);
        vm.prank(creditModule);
        registry.recordExposureDecrease(FILM, BORROWER_1, bytes32(0), 400e18);
        assertEq(registry.overConcentratedClasses(), (1 << (DA - 1)), "DA over 20% of 1200");

        vm.recordLogs();
        vm.prank(creditModule);
        registry.recordExposureDecrease(FILM, BORROWER_1, bytes32(0), 100e18);
        assertEq(_countTopic(ICollateralRegistry.ConcentrationDrift.selector), 0, "no repeat announcement");
    }

    /// @dev A class that comes back within its limit — because the book grew around it —
    ///      is announced healed, so an indexer can close the breach.
    function test_healedIsEventedWhenTheBookGrowsBackAroundTheClass() public {
        _seed(DA, B5, 800e18);
        _seed(FILM, BORROWER_1, 800e18);
        assertEq(
            registry.overConcentratedClasses(),
            (1 << (FILM - 1)) | (1 << (DA - 1)),
            "both classes hold 50% of a two-facility book"
        );

        // the book grows around digital assets: 800 / 4800 = 1667bps, back under its cap
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationHealed(DA, 800e18, 4_800e18, 2000, false);
        _seed(FILM, BORROWER_1, 3_200e18);
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1), "only the film class still in breach");
    }

    /// @dev Governance tightening a class limit can put a standing book in breach with no
    ///      exposure moving; that is announced at `setClass`, not at the next origination.
    function test_tighteningAClassLimitAnnouncesTheBreachImmediately() public {
        _seed(FILM, BORROWER_1, 1_000e18);
        _seed(RENEW, BORROWER_2, 1_000e18);
        _seed(LIFE, B3, 1_000e18);
        _seed(RE, B4, 1_000e18); // 25% each: a balanced, unbreached book
        assertEq(registry.overConcentratedClasses(), 0);

        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = 1000; // 25% held vs a new 10% cap
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationDrift(FILM, 1_000e18, 4_000e18, 1000, false);
        vm.prank(admin);
        registry.setClass(FILM, p);
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1));
    }

    // ── 2. enforcement AT THE SHIPPED CONFIGURATION (reviewer HIGH #2) ────

    /// @dev ROUND-2 REGRESSION, reviewer issue "enforcement is inert at the shipped
    ///      configuration". NOTHING is reconfigured here: the floor is whatever
    ///      `initialize` set (25,000,000e18) and the limits are the launch defaults. The
    ///      class allowance below the floor is 3500bps of 25m = 8.75m, and it BINDS.
    ///      Pre-round-2 this whole test was admissible: every dimension could grow to the
    ///      full 25m floor unchecked.
    function test_launchDefaults_classAllowanceBindsBelowTheFloor() public {
        (,, uint256 floor) = registry.limits();
        assertEq(floor, LAUNCH_FLOOR, "shipped floor, untouched");

        // build the film class to exactly its bootstrap allowance across 5 borrowers, so
        // the per-borrower cap (3.75m) is never the binding dimension
        _seed(FILM, BORROWER_1, 2_000_000e18);
        _seed(FILM, BORROWER_2, 2_000_000e18);
        _seed(FILM, B3, 2_000_000e18);
        _seed(FILM, B4, 2_000_000e18);
        _seed(FILM, B5, 750_000e18);
        assertEq(registry.classExposure(FILM), 8_750_000e18, "3500bps of the 25m floor, exactly");
        assertEq(registry.concentrationHeadroom(FILM, FRESH, bytes32(0)), 0, "allowance is exhausted");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector, FILM, 8_750_000e18 + 1, 3500
            )
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, FRESH, bytes32(0), 1);
        assertEq(registry.classExposure(FILM), 8_750_000e18, "nothing was recorded");
    }

    /// @dev The reviewer's own shipped-config counter-example, now impossible to even
    ///      construct: a 20,000,000e18 single-class book is rejected outright at the launch
    ///      floor, so there is no "100% of a $20m book" state to grow from.
    function test_launchDefaults_theReviewersTwentyMillionSingleClassBookIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_ConcentrationExceeded.selector, FILM, 20_000_000e18, 3500
            )
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, BORROWER_1, bytes32(0), 20_000_000e18);
        assertEq(registry.totalBookExposure(), 0);
    }

    /// @dev Same, on the per-borrower dimension: 1500bps of the 25m floor = 3.75m.
    function test_launchDefaults_borrowerAllowanceBindsBelowTheFloor() public {
        _seed(FILM, BORROWER_1, 2_000_000e18);
        _seed(RENEW, BORROWER_1, 1_750_000e18);
        assertEq(registry.borrowerExposure(BORROWER_1), 3_750_000e18, "1500bps of the 25m floor, exactly");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, BORROWER_1, 3_750_000e18 + 1, 1500
            )
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(LIFE, BORROWER_1, bytes32(0), 1);
    }

    /// @dev Same, on the per-state dimension: 2500bps of the 25m floor = 6.25m.
    function test_launchDefaults_stateAllowanceBindsBelowTheFloor() public {
        vm.startPrank(creditModule);
        registry.recordExposureIncrease(FILM, BORROWER_1, STATE_GA, 3_000_000e18);
        registry.recordExposureIncrease(FILM, BORROWER_2, STATE_GA, 3_250_000e18);
        vm.stopPrank();
        assertEq(registry.stateExposure(STATE_GA), 6_250_000e18, "2500bps of the 25m floor, exactly");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_StateConcentrationExceeded.selector, STATE_GA, 6_250_000e18 + 1, 2500
            )
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, B3, STATE_GA, 1);
    }

    /// @dev A genuinely young book still bootstraps: the first facility is 100% of the book
    ///      and must not be self-blocking. The absolute allowance is what caps it.
    function test_youngBookStillBootstrapsUpToTheAbsoluteAllowance() public {
        _seed(FILM, BORROWER_1, 1_000e18);
        assertEq(registry.classConcentrationBps(FILM), Config.BPS, "100% of a one-facility book");
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1), "reported honestly...");
        // ...and still admissible, because the book has not cleared the bootstrap floor
        //     ...bounded by the tightest dimension, which for a fresh borrower is the
        //     per-borrower allowance (1500bps of the 25m floor = 3.75m), not the class one
        assertEq(
            registry.concentrationHeadroom(FILM, FRESH, bytes32(0)), 3_750_000e18, "room up to the borrower allowance"
        );
        _seed(FILM, FRESH, 3_750_000e18);
        assertEq(registry.classExposure(FILM), 3_751_000e18);
        assertEq(registry.concentrationHeadroom(FILM, FRESH, bytes32(0)), 0, "and it is exact");
    }

    // ── 3. creating a breach on a mature book (reviewer HIGH #1) ─────────

    /// @dev ROUND-2 REGRESSION, reviewer issue "closes deepening but not creation". A
    ///      brand-new borrower with zero exposure originates on a MATURE book an amount at
    ///      or under the absolute floor. Round 1 admitted this (the in-breach clause needs
    ///      `cur != 0`, and the bucket was under the floor), leaving the borrower at
    ///      1836bps against a 1500bps cap. It is now rejected.
    function test_matureBook_aFreshBorrowerBreachCannotBeCreated() public {
        _matureBook(); // 4 x 1000e18 across four classes, then floor lowered to 1000e18

        // 900e18 <= floor, so round 1's bucket-keyed exemption skipped the relative check
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector, B5, 900e18, 1500
            )
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(LIFE, B5, bytes32(0), 900e18);

        (, bool borrowerOver,) = registry.isOverConcentrated(LIFE, B5, bytes32(0));
        assertFalse(borrowerOver, "no breach was created");
        assertEq(registry.totalBookExposure(), 4_000e18, "book unchanged");
    }

    /// @dev The same creation hole on the CLASS dimension: film would land at 3877bps
    ///      against its 3500bps cap on a mature book, from an add that sits under the floor.
    function test_matureBook_aFreshClassBreachCannotBeCreated() public {
        _matureBook();
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ConcentrationExceeded.selector, FILM, 1_900e18, 3500)
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, B5, bytes32(0), 900e18);
        assertEq(registry.classExposure(FILM), 1_000e18);
    }

    // ── 4. the floor-dependence holes (reviewer MEDIUMs) ─────────────────

    /// @dev ROUND-2 REGRESSION: an ordinary repayment that shrinks the book back UNDER the
    ///      bootstrap floor must not re-open the growth hole. Round 1's in-breach clause was
    ///      gated on `total > floor`, so it switched off here and `concentrationHeadroom`
    ///      itself reported the reopened room.
    function test_shrinkingBackUnderTheFloorDoesNotReopenTheHole() public {
        _seed(FILM, BORROWER_1, 900e18);
        _seed(RENEW, BORROWER_2, 900e18);
        vm.prank(admin);
        registry.setConcentrationFloor(1_000e18); // book 1800 is now "mature"

        assertEq(registry.concentrationHeadroom(FILM, FRESH, bytes32(0)), 0, "no room while above the floor");

        // renewables repays in full: book 900e18, back UNDER the floor, film at 100%
        vm.prank(creditModule);
        registry.recordExposureDecrease(RENEW, BORROWER_2, bytes32(0), 900e18);
        assertEq(registry.totalBookExposure(), 900e18, "book is under the floor again");
        assertEq(registry.classConcentrationBps(FILM), Config.BPS, "and film holds all of it");

        // the absolute allowance (3500bps of the 1000e18 floor = 350e18) is already blown,
        // so there is still nothing admissible
        assertEq(registry.concentrationHeadroom(FILM, FRESH, bytes32(0)), 0, "hole stays closed");
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ConcentrationExceeded.selector, FILM, 900e18 + 1, 3500)
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, FRESH, bytes32(0), 1);
    }

    /// @dev ROUND-2 REGRESSION, the `total == floor` boundary. Round 1 used a strict
    ///      `total > floor`, so at exactly the floor the in-breach clause was off and an
    ///      admitted origination raised a breached class's share (9000 -> 9090 bps).
    function test_atTheFloorExactlyTheBreachedClassStillCannotGrow() public {
        _seed(FILM, BORROWER_1, 900e18);
        _seed(RENEW, BORROWER_2, 100e18);
        vm.prank(admin);
        registry.setConcentrationFloor(1_000e18); // totalExp == floor, exactly
        assertEq(registry.totalBookExposure(), 1_000e18);
        assertEq(registry.classConcentrationBps(FILM), 9000);

        assertEq(registry.concentrationHeadroom(FILM, FRESH, bytes32(0)), 0, "no room at the boundary");
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ConcentrationExceeded.selector, FILM, 900e18 + 1, 3500)
        );
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, FRESH, bytes32(0), 1);
        assertEq(registry.classConcentrationBps(FILM), 9000, "share did not move");
    }

    /// @dev A zero principal moves nothing, so it can neither create nor deepen a breach and
    ///      must stay a pure no-op even in a fully breached book. One wei is not.
    function test_zeroPrincipalProbeIsAlwaysANoOp() public {
        _seed(FILM, BORROWER_1, 900e18);
        _seed(RENEW, BORROWER_2, 900e18);
        vm.prank(admin);
        registry.setConcentrationFloor(1_000e18);
        assertEq(registry.concentrationHeadroom(FILM, BORROWER_1, bytes32(0)), 0, "nothing admissible");
        registry.checkConcentration(FILM, BORROWER_1, bytes32(0), 0); // a no-op is still a no-op

        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegistry.Registry_ConcentrationExceeded.selector, FILM, 900e18 + 1, 3500)
        );
        registry.checkConcentration(FILM, BORROWER_1, bytes32(0), 1);
    }

    /// @dev The floor is bounded so the concentration arithmetic is provably overflow-free.
    ///      NOTE (accepted, disclosed): within that bound, raising the floor still raises
    ///      every dimension's absolute allowance. That is the same timelocked governance
    ///      power as raising `concentrationLimitBps` via `setClass`; what round 2 removes is
    ///      the ability of a floor change to switch the relative limits OFF entirely.
    function test_concentrationFloorIsBounded() public {
        vm.prank(admin);
        vm.expectRevert(ICollateralRegistry.Registry_BadParams.selector);
        registry.setConcentrationFloor(MAX_SAFE_EXPOSURE + 1);

        vm.prank(admin);
        registry.setConcentrationFloor(MAX_SAFE_EXPOSURE); // the bound itself is accepted
        (,, uint256 floor) = registry.limits();
        assertEq(floor, MAX_SAFE_EXPOSURE);
    }

    // ── 5. decreases can never be blocked ────────────────────────────────

    /// @dev CRITICAL: no concentration ground may ever revert a decrease. A write-down on
    ///      a book that is already 100% concentrated must still land, or a risk limit
    ///      could veto a loss being realized and invert the loss cascade.
    function testFuzz_decreaseIsNeverBlockedHoweverConcentratedTheBookIs(uint256 writedown) public {
        _seed(DA, B5, 1_000e18); // 100% of the book, against a 20% cap
        vm.prank(admin);
        registry.setConcentrationFloor(1); // and no bootstrap allowance left to hide behind
        assertEq(registry.overConcentratedClasses(), 1 << (DA - 1));

        writedown = bound(writedown, 1, 1_000e18);
        vm.prank(creditModule);
        registry.recordExposureDecrease(DA, B5, bytes32(0), writedown);
        assertEq(registry.classExposure(DA), 1_000e18 - writedown, "the loss was recorded in full");
    }

    /// @dev The decrease-path breach sweep must be arithmetic-proof, not merely
    ///      "unreachable in practice": `_breaches` uses a 512-bit intermediate, so even a
    ///      book at the maximum admissible exposure cannot make `recordExposureDecrease`
    ///      panic. Reviewers flagged this explicitly — a concentration check must never be
    ///      able to block `realizeLoss`.
    function test_decreaseCannotPanicEvenAtTheMaximumAdmissibleBook() public {
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = uint16(Config.BPS);
        vm.startPrank(admin);
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(uint16(Config.BPS));
        registry.setConcentrationFloor(MAX_SAFE_EXPOSURE);
        vm.stopPrank();

        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, BORROWER_1, bytes32(0), MAX_SAFE_EXPOSURE);
        assertEq(registry.totalBookExposure(), MAX_SAFE_EXPOSURE);

        // the sweep runs on this book and must not panic
        vm.prank(creditModule);
        registry.recordExposureDecrease(FILM, BORROWER_1, bytes32(0), MAX_SAFE_EXPOSURE);
        assertEq(registry.totalBookExposure(), 0);
    }

    // ── 6. disclosure survives an implementation upgrade ─────────────────

    /// @dev ROUND-2 REGRESSION, reviewer issue "the bitmap reads zero on the live proxy".
    ///      The Sepolia registry is a live UUPS proxy with a non-empty book; the appended
    ///      cache slot reads zero the moment a new implementation is cut in. Modelled here
    ///      by zeroing that slot on a breached book. `overConcentratedClasses` recomputes
    ///      from the book, so it agrees with `isOverConcentrated` immediately — no
    ///      reinitializer required, and a missing migration degrades to "the drift event is
    ///      announced on the next sync", never to "the view reports a clean book".
    function test_breachViewsAreCorrectOnAFreshlyUpgradedProxyWhoseCacheReadsZero() public {
        _seed(FILM, BORROWER_1, 800e18);
        _seed(RENEW, BORROWER_2, 200e18);
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1), "film holds 80% vs a 35% cap");

        // model the post-upgrade proxy: EVERY appended slot reads zero — the class bitmap
        // at namespace +8 and the borrower breach flag in the mapping at +9
        uint256 ns = 0xd1052ad481f6f823017e987ee43475f3a84883a50e791c5b4260ba144e440700;
        bytes32 slot = bytes32(ns + 8);
        vm.store(address(registry), slot, bytes32(0));
        vm.store(address(registry), keccak256(abi.encode(BORROWER_1, ns + 9)), bytes32(0));
        assertEq(uint256(vm.load(address(registry), slot)), 0, "cache really is zeroed");

        (bool classOver,,) = registry.isOverConcentrated(FILM, BORROWER_1, bytes32(0));
        assertTrue(classOver, "the book really is in breach");
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1), "and the bitmap agrees, uncached");

        // and anyone can announce the standing breach without waiting for an exposure event
        bytes32[] memory borrowers = new bytes32[](1);
        borrowers[0] = BORROWER_1;
        bytes32[] memory states = new bytes32[](0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationDrift(FILM, 800e18, 1_000e18, 3500, false);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.BorrowerConcentrationDrift(BORROWER_1, 800e18, 1_000e18, 1500, false);
        registry.syncConcentrationBreaches(borrowers, states); // permissionless
    }

    // ── 7. borrower and state drift are disclosed too ────────────────────

    /// @dev ROUND-2 REGRESSION, reviewer issue "only one of three dimensions is evented".
    ///      The borrower cap is the tightest (1500bps) and therefore the likeliest to drift.
    ///      The drift VICTIM is by construction a party the shrinking transaction does not
    ///      touch, and the borrower key set is not enumerable on-chain — so the guarantee
    ///      is: the batch view is always correct, and `syncConcentrationBreaches` announces
    ///      the transition for any id (recoverable from the `ExposureRecorded` stream).
    function test_borrowerDriftIsDisclosedAndAnnounceable() public {
        _seed(RENEW, BORROWER_2, 9_000e18);
        _seed(FILM, BORROWER_1, 900e18);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = BORROWER_1;
        assertFalse(registry.overConcentratedBorrowers(ids)[0], "909bps of the book, well inside the 15% cap");

        // borrower 2 repays in full: borrower 1 drifts to 100% without being touched
        vm.prank(creditModule);
        registry.recordExposureDecrease(RENEW, BORROWER_2, bytes32(0), 9_000e18);
        assertTrue(registry.overConcentratedBorrowers(ids)[0], "drifted into breach, at 100%");

        bytes32[] memory none = new bytes32[](0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.BorrowerConcentrationDrift(BORROWER_1, 900e18, 900e18, 1500, false);
        registry.syncConcentrationBreaches(ids, none);

        // and it is edge-detected: a second sync is silent
        vm.recordLogs();
        registry.syncConcentrationBreaches(ids, none);
        assertEq(_countTopic(ICollateralRegistry.BorrowerConcentrationDrift.selector), 0, "no repeat announcement");
    }

    /// @dev The borrower a write DOES touch is evented inline, with no keeper needed.
    function test_borrowerDriftIsEventedInlineWhenTheWriteTouchesThatBorrower() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.BorrowerConcentrationDrift(BORROWER_1, 900e18, 900e18, 1500, false);
        _seed(FILM, BORROWER_1, 900e18);

        // ...and heals inline on the write that touches it, here a full repayment
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.BorrowerConcentrationHealed(BORROWER_1, 0, 0, 1500, false);
        vm.prank(creditModule);
        registry.recordExposureDecrease(FILM, BORROWER_1, bytes32(0), 900e18);
    }

    /// @dev The converse, stated honestly: a borrower that drifts because SOMEONE ELSE
    ///      repaid is not touched by that write, so no inline event is possible. The batch
    ///      view is correct immediately and `syncConcentrationBreaches` publishes the heal.
    function test_borrowerHealCausedByAnotherPartyNeedsTheKeeperSync() public {
        _seed(FILM, BORROWER_1, 900e18);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = BORROWER_1;
        assertTrue(registry.overConcentratedBorrowers(ids)[0]);

        vm.recordLogs();
        vm.prank(creditModule);
        registry.recordExposureIncrease(RENEW, BORROWER_2, bytes32(0), 8_100e18);
        assertEq(
            _countTopic(ICollateralRegistry.BorrowerConcentrationHealed.selector),
            0,
            "no inline event for an untouched borrower - this is the disclosed limitation"
        );
        assertFalse(registry.overConcentratedBorrowers(ids)[0], "but the view is already correct");

        bytes32[] memory none = new bytes32[](0);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.BorrowerConcentrationHealed(BORROWER_1, 900e18, 9_000e18, 1500, false);
        registry.syncConcentrationBreaches(ids, none);
    }

    /// @dev The state dimension gets the same treatment.
    function test_stateDriftIsDisclosedAndAnnounceable() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.StateConcentrationDrift(STATE_GA, 900e18, 900e18, 2500, false);
        vm.prank(creditModule);
        registry.recordExposureIncrease(FILM, BORROWER_1, STATE_GA, 900e18);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = STATE_GA;
        assertTrue(registry.overConcentratedStates(ids)[0], "100% of the book in one state");
        ids[0] = bytes32(0);
        assertFalse(registry.overConcentratedStates(ids)[0], "an untagged facility is never a state breach");
    }

    // ── 8. headroom is exact (differential reference model) ──────────────

    /// @dev `concentrationHeadroom` is the authority on what is admissible: the reported
    ///      amount passes and one wei more reverts, with the specific error of whichever
    ///      dimension binds. Fuzzed across arbitrary exposure/floor combinations against an
    ///      independent reference model of the rule.
    function testFuzz_headroomIsExactAndTheBindingDimensionIsReported(
        uint256 filmExp,
        uint256 renewExp,
        uint256 borrowerShare,
        uint256 floor
    ) public {
        filmExp = bound(filmExp, 0, 1e27);
        renewExp = bound(renewExp, 0, 1e27);
        borrowerShare = bound(borrowerShare, 0, filmExp);

        // reach an arbitrary book with the limits lifted, then re-arm them
        vm.startPrank(admin);
        registry.setConcentrationFloor(type(uint128).max);
        registry.setBorrowerLimit(uint16(Config.BPS));
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        uint16 filmLimit = p.concentrationLimitBps;
        p.concentrationLimitBps = uint16(Config.BPS);
        registry.setClass(FILM, p);
        ICollateralRegistry.ClassParams memory q = registry.classParams(RENEW);
        q.concentrationLimitBps = uint16(Config.BPS);
        registry.setClass(RENEW, q);
        vm.stopPrank();

        vm.startPrank(creditModule);
        if (borrowerShare > 0) registry.recordExposureIncrease(FILM, BORROWER_1, bytes32(0), borrowerShare);
        if (filmExp - borrowerShare > 0) {
            registry.recordExposureIncrease(FILM, B3, bytes32(0), filmExp - borrowerShare);
        }
        if (renewExp > 0) registry.recordExposureIncrease(RENEW, B4, bytes32(0), renewExp);
        vm.stopPrank();

        // re-arm the real limits and pick an arbitrary floor
        floor = bound(floor, 0, 1e30);
        vm.startPrank(admin);
        p.concentrationLimitBps = filmLimit;
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(1500);
        registry.setConcentrationFloor(floor);
        vm.stopPrank();

        uint256 h = registry.concentrationHeadroom(FILM, BORROWER_1, bytes32(0));
        // zero means "nothing new is admissible here"; any positive amount it reports must
        // actually be admissible
        if (h > 0) registry.checkConcentration(FILM, BORROWER_1, bytes32(0), h);

        uint256 total = registry.totalBookExposure();
        uint256 classRoom = _room(registry.classExposure(FILM), 3500, total, floor);
        uint256 borrowerRoom = _room(registry.borrowerExposure(BORROWER_1), 1500, total, floor);
        assertEq(h, classRoom < borrowerRoom ? classRoom : borrowerRoom, "headroom == binding dimension");

        vm.expectRevert(
            classRoom <= borrowerRoom
                ? abi.encodeWithSelector(
                    ICollateralRegistry.Registry_ConcentrationExceeded.selector,
                    FILM,
                    registry.classExposure(FILM) + h + 1,
                    3500
                )
                : abi.encodeWithSelector(
                    ICollateralRegistry.Registry_BorrowerConcentrationExceeded.selector,
                    BORROWER_1,
                    registry.borrowerExposure(BORROWER_1) + h + 1,
                    1500
                )
        );
        registry.checkConcentration(FILM, BORROWER_1, bytes32(0), h + 1); // one wei more does not
    }

    /// @dev No principal at all is admissible into a class that does not exist or has been
    ///      deactivated, so the headroom view must say zero rather than a relative number.
    function test_headroomIsZeroForAnUnknownOrInactiveClass() public {
        assertEq(registry.concentrationHeadroom(99, BORROWER_1, bytes32(0)), 0, "unknown class");
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.active = false;
        vm.prank(admin);
        registry.setClass(FILM, p);
        assertEq(registry.concentrationHeadroom(FILM, BORROWER_1, bytes32(0)), 0, "inactive class");
    }

    /// @dev The state dimension binds the headroom like any other: a state already holding
    ///      25% of the book leaves no room for another facility tagged to it, even though
    ///      the class and the borrower would both still admit one.
    function test_headroomIsBoundByTheStateDimension() public {
        vm.startPrank(creditModule);
        registry.recordExposureIncrease(FILM, BORROWER_1, STATE_GA, 1_000e18);
        registry.recordExposureIncrease(RENEW, BORROWER_2, STATE_NV, 3_000e18);
        vm.stopPrank();
        vm.prank(admin);
        registry.setConcentrationFloor(0); // the relative limits now bind strictly

        // GA holds 1000/4000 = 2500bps, exactly its cap: no room left on that state
        assertEq(registry.concentrationHeadroom(FILM, B3, STATE_GA), 0, "state dimension binds");
        // untagged, the same class/borrower pair still has room (film cap 3500)
        assertGt(registry.concentrationHeadroom(FILM, B3, bytes32(0)), 0, "class dimension does not");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegistry.Registry_StateConcentrationExceeded.selector, STATE_GA, 1_000e18 + 1, 2500
            )
        );
        registry.checkConcentration(FILM, B3, STATE_GA, 1);
    }

    /// @dev A dimension capped at the full BPS can never bind (exposure never exceeds the
    ///      book), so it must not be reported as the binding constraint.
    function test_headroomIsUnboundedForAClassCappedAtFullBps() public {
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = uint16(Config.BPS);
        vm.prank(admin);
        registry.setClass(FILM, p);
        _seed(FILM, BORROWER_1, 1_000e18);
        vm.prank(admin);
        registry.setConcentrationFloor(0); // the relative limits now bind strictly

        (bool classOver,,) = registry.isOverConcentrated(FILM, B3, bytes32(0));
        assertFalse(classOver, "100% of the book, but capped at 100%");
        // the borrower cap (1500bps) is what binds now, not the class
        assertEq(
            registry.concentrationHeadroom(FILM, B3, bytes32(0)),
            uint256(1500) * 1_000e18 / (Config.BPS - 1500),
            "an uncapped class defers to the borrower dimension"
        );
    }

    /// @dev ROUND-2 REGRESSION, reviewer issue "the unbounded-dimension sentinel panics when
    ///      fed back". Round 1 returned `type(uint256).max - cur`, and feeding that into
    ///      `checkConcentration` aborted with an arithmetic panic (Panic 0x11) rather than a
    ///      decodable protocol error — a "max" button wired to this view would surface a raw
    ///      panic (CLAUDE.md §3.3). The value handed back is now always admissible, and one
    ///      wei more fails with a custom error, not a panic.
    function test_headroomSentinelIsItselfAdmissibleAndOverflowIsADecodableError() public {
        ICollateralRegistry.ClassParams memory p = registry.classParams(FILM);
        p.concentrationLimitBps = uint16(Config.BPS);
        vm.startPrank(admin);
        registry.setClass(FILM, p);
        registry.setBorrowerLimit(uint16(Config.BPS));
        registry.setStateLimit(uint16(Config.BPS));
        registry.setConcentrationFloor(0);
        vm.stopPrank();

        uint256 h = registry.concentrationHeadroom(FILM, BORROWER_1, STATE_GA);
        assertEq(h, MAX_SAFE_EXPOSURE, "the clamp, not type(uint256).max");
        registry.checkConcentration(FILM, BORROWER_1, STATE_GA, h); // passes, no panic

        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        registry.checkConcentration(FILM, BORROWER_1, STATE_GA, h + 1);

        // and the same at the true extreme, where round 1 panicked
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        registry.checkConcentration(FILM, BORROWER_1, STATE_GA, type(uint256).max);
    }

    /// @dev Share view: an empty book divides by nothing and reports zero.
    function test_classConcentrationBpsOnAnEmptyBook() public view {
        assertEq(registry.classConcentrationBps(FILM), 0);
        assertEq(registry.overConcentratedClasses(), 0);
        (bool classOver, bool borrowerOver, bool stateOver) = registry.isOverConcentrated(FILM, BORROWER_1, STATE_GA);
        assertFalse(classOver);
        assertFalse(borrowerOver);
        assertFalse(stateOver);
    }

    /// @dev The state dimension is only meaningful for a tagged facility; an untagged one
    ///      must not read as a state breach.
    function test_isOverConcentratedIgnoresTheStateDimensionWhenUntagged() public {
        _seed(FILM, BORROWER_1, 1_000e18);
        (,, bool stateOver) = registry.isOverConcentrated(FILM, BORROWER_1, bytes32(0));
        assertFalse(stateOver, "no state tag");
        vm.prank(creditModule);
        registry.recordExposureIncrease(RENEW, BORROWER_2, STATE_GA, 1_000e18);
        (,, bool taggedOver) = registry.isOverConcentrated(RENEW, BORROWER_2, STATE_GA);
        assertTrue(taggedOver, "50% of the book in one state against a 25% cap");
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _seed(uint256 classId, bytes32 borrowerId, uint256 principal) internal {
        vm.prank(creditModule);
        registry.recordExposureIncrease(classId, borrowerId, bytes32(0), principal);
    }

    /// @dev A book built at the launch floor and then declared mature by lowering the floor
    ///      under it — the state in which round 1's bucket-keyed exemption still leaked.
    function _matureBook() internal {
        _seed(FILM, BORROWER_1, 1_000e18);
        _seed(RENEW, BORROWER_2, 1_000e18);
        _seed(RE, B3, 1_000e18);
        _seed(DA, B4, 1_000e18);
        vm.prank(admin);
        registry.setConcentrationFloor(1_000e18);
        assertEq(registry.totalBookExposure(), 4_000e18);
    }

    /// @dev Independent model of one dimension's admissible amount (mirrors, but does not
    ///      call, `CollateralRegistry._dimHeadroom`): the largest `p` with
    ///      `cur + p <= limitBps * max(total + p, floor) / BPS`.
    function _room(uint256 cur, uint256 limitBps, uint256 total, uint256 floor) internal pure returns (uint256) {
        uint256 room;
        if (total <= floor) {
            uint256 allowance = limitBps * floor / Config.BPS;
            if (allowance > cur) {
                uint256 a = allowance - cur;
                uint256 b = floor - total;
                room = a < b ? a : b;
            }
        }
        uint256 lhs = limitBps * total;
        uint256 rhs = cur * Config.BPS;
        uint256 ratioRoom = lhs <= rhs ? 0 : (lhs - rhs) / (Config.BPS - limitBps);
        uint256 minForB = total > floor ? 0 : floor - total + 1;
        if (ratioRoom >= minForB && ratioRoom > room) room = ratioRoom;
        return room;
    }

    function _countTopic(bytes32 topic0) internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }
}

/// @dev The paths that must NEVER be blocked by a concentration check, exercised through
///      the real credit layer rather than the registry in isolation.
contract M02DecreasePathsUnblockedTest is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant DA = Config.CLASS_DIGITAL_ASSETS;

    /// @dev A default write-down shrinks the book and can leave the surviving class above
    ///      its cap. `realizeLoss` must still complete — the breach is reported, never
    ///      prevented, or a risk limit would sit ahead of the loss cascade.
    function test_realizeLossIsNotBlockedAndAnnouncesTheResultingDrift() public {
        _mintUSDfrTo(alice, 3_000_000e18);
        _postFirstLoss(anchorCurator, FILM, 250_000e18);

        uint256 filmId = _liveFilmFacility(1_000_000e18);
        uint256 daId = _originateDigital(200_000e18, 1_000_000e18);
        _fundFacility(daId, 200_000e18);
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1), "film already holds 83% of the book");

        _attestDefault(filmId);
        vm.startPrank(servicer);
        defaultManager.declareDefault(filmId, FILM_REF);
        defaultManager.accelerate(filmId);
        vm.stopPrank();

        // 250k of the film facility is written off against curator first loss; the book
        // shrinks to 950k and digital assets crosses its 20% cap without moving at all
        _attestLoss(filmId, 250_000e18, FILM_REF);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICollateralRegistry.ConcentrationDrift(DA, 200_000e18, 950_000e18, 2000, false);
        vm.prank(servicer);
        defaultManager.realizeLoss(filmId, 250_000e18, FILM_REF);

        assertEq(registry.classExposure(FILM), 750_000e18, "the loss was written down in full");
        assertEq(registry.classConcentrationBps(DA), 2105, "DA drifted over its cap");
        assertEq(registry.overConcentratedClasses(), (1 << (FILM - 1)) | (1 << (DA - 1)), "and it is on the record");
    }

    /// @dev A performing repayment shrinks the book the same way and must not be blocked.
    function test_repaymentIsNotBlockedWhenItLeavesTheBookConcentrated() public {
        _mintUSDfrTo(alice, 3_000_000e18);
        uint256 filmId = _liveFilmFacility(1_000_000e18);
        uint256 daId = _originateDigital(200_000e18, 1_000_000e18);
        _fundFacility(daId, 200_000e18);

        _repay(filmId, 10_000e18, 1_000_000e18); // paid down to zero
        assertEq(registry.classExposure(FILM), 0);
        assertEq(registry.overConcentratedClasses(), 1 << (DA - 1), "surviving class flagged, payment landed");
    }

    /// @dev Retiring an unfunded facility (`ClaimBridge.cancelPending`) is the third
    ///      decrease path named in the finding; it too must complete in a breached book.
    function test_cancelPendingIsNotBlockedInABreachedBook() public {
        _mintUSDfrTo(alice, 3_000_000e18);
        uint256 filmId = _liveFilmFacility(1_000_000e18);
        uint256 pendingId = _originateFilm(BORROWER_2, STATE_GA, 100_000e18);
        assertEq(registry.classExposure(FILM), 1_100_000e18);

        vm.prank(originator);
        bridge.cancelPending(pendingId);
        assertEq(registry.classExposure(FILM), 1_000_000e18, "exposure released");
        assertEq(registry.overConcentratedClasses(), 1 << (FILM - 1), "100% of the book, on the record");
        assertEq(filmId, 1);
    }
}

/// @dev CLAUDE.md §1.3 CONCENTRATION invariant, restated to the property that actually
///      holds (see the header of this file). The old formulation — "class/borrower/state
///      exposures never exceed their limits above the bootstrap floor" — is not a
///      reachable-state property of any amortising book and must not be asserted as one.
contract M02ConcentrationInvariants is CollateralFixture {
    CollateralHandler internal handler;
    uint256 internal constant MAX_SAFE_EXPOSURE = type(uint256).max / Config.BPS;

    function setUp() public override {
        super.setUp();
        handler = new CollateralHandler(bridge, registry, oracle, originator, creditModule, custodian, admin);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CollateralHandler.flipAttestations.selector;
        selectors[1] = CollateralHandler.tryOriginate.selector;
        selectors[2] = CollateralHandler.advanceLifecycle.selector;
        selectors[3] = CollateralHandler.repayAndClose.selector;
        selectors[4] = CollateralHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev DISCLOSURE: the published breach bitmap always equals the book's real state,
    ///      so an over-concentrated book can never be silently over-concentrated.
    function invariant_m02_breachBitmapMatchesTheBook() public view {
        uint256 total = registry.totalBookExposure();
        uint256 expected;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 exp = registry.classExposure(c);
            uint256 limit = registry.classParams(c).concentrationLimitBps;
            if (exp * Config.BPS > limit * total) expected |= 1 << (c - 1);
        }
        assertEq(registry.overConcentratedClasses(), expected, "UNDISCLOSED CONCENTRATION BREACH");
    }

    /// @dev ADMISSION: a dimension above its limit measured against `max(book, floor)` —
    ///      the rule the contract enforces — has zero headroom. Round 2: this is no longer
    ///      gated on `total > floor`, which is what made it vacuous at the shipped floor.
    function invariant_m02_overLimitDimensionCannotBeGrown() public view {
        uint256 total = registry.totalBookExposure();
        (uint16 bLimit,, uint256 floor) = registry.limits();
        uint256 base = total > floor ? total : floor;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 exp = registry.classExposure(c);
            uint256 limit = registry.classParams(c).concentrationLimitBps;
            if (exp > limit * base / Config.BPS) {
                assertEq(
                    registry.concentrationHeadroom(c, keccak256("fresh-borrower"), bytes32(0)),
                    0,
                    "BREACHED CLASS STILL ADMITS EXPOSURE"
                );
            }
        }
        for (uint256 i = 0; i < handler.borrowerCount(); ++i) {
            bytes32 b = handler.borrowerAt(i);
            if (registry.borrowerExposure(b) > uint256(bLimit) * base / Config.BPS) {
                for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
                    assertEq(
                        registry.concentrationHeadroom(c, b, bytes32(0)), 0, "BREACHED BORROWER STILL ADMITS EXPOSURE"
                    );
                }
            }
        }
    }

    /// @dev The headroom view is the authority on admissibility in every reachable state,
    ///      and the number it hands back is always one the admission path accepts — never a
    ///      sentinel that panics when fed back (round-2 reviewer LOW).
    function invariant_m02_headroomIsAdmissible() public view {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            for (uint256 i = 0; i < handler.borrowerCount(); ++i) {
                bytes32 b = handler.borrowerAt(i);
                uint256 h = registry.concentrationHeadroom(c, b, bytes32(0));
                assertLe(h, MAX_SAFE_EXPOSURE - registry.totalBookExposure(), "HEADROOM ABOVE THE SAFE CLAMP");
                if (h > 0) registry.checkConcentration(c, b, bytes32(0), h);
            }
        }
    }
}

/// @dev Belt-and-braces: the concentration arithmetic must be panic-proof, because the
///      breach sweep runs on the decrease path that carries loss realization.
contract M02ArithmeticSafetyTest is CollateralFixture {
    /// @dev `stdError` is imported so the intent is explicit: NONE of these paths may ever
    ///      produce a bare arithmetic panic.
    function test_absurdPrincipalIsADecodableErrorNotAPanic() public {
        vm.prank(admin);
        registry.setConcentrationFloor(0);
        vm.expectRevert(ICollateralRegistry.Registry_PrincipalTooLarge.selector);
        registry.checkConcentration(Config.CLASS_FILM_TAX_CREDITS, BORROWER_1, bytes32(0), type(uint256).max);

        // sanity: the assertion above would be `stdError.arithmeticError` pre-fix
        assertTrue(stdError.arithmeticError.length > 0);
    }
}
