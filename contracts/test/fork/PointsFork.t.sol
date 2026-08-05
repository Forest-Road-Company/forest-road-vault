// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {console2} from "forge-std/console2.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev A points module that reverts on EVERY call. Stands in for the realistic failure
///      mode: the PointsModule proxy is upgraded to a broken implementation, or its
///      compliance dependency starts reverting. The hooks in USDfr / sUSDfr / CuratorModule
///      are documented as FAIL-OPEN (R2-M-02, P-04) — this is what proves it.
contract RevertingPoints {
    error Boom();

    fallback() external {
        revert Boom();
    }
}

/// @dev A points module that burns every drop of gas forwarded to it. Try/catch cannot
///      protect against gas EXHAUSTION the way it protects against a revert (EIP-150 hands
///      the child 63/64 of the remaining gas), so fail-open has to be probed with this too,
///      not just with a cheap revert.
contract GasBurnerPoints {
    uint256 public burned;

    fallback() external {
        for (uint256 i = 1;; ++i) {
            burned = i;
        }
    }
}

/// @title PointsFork — the PointsModule over REAL elapsed time on a pinned mainnet fork
/// @notice The in-memory points suites drive a mock stable and short windows. This one runs
///         the ledger against the FULL deployed stack (real `Deploy.s.sol` topology, real
///         USDC) and over calendar-scale time, and pins every accrual number against a
///         figure computed OUTSIDE the contract from the ADR-0016 spec —
///
///           points = B · (F(b−S) − F(a−S)) / WAD · (rate·mult/BPS) / (1 day · unit)
///           F(x)   = x·WAD + x²·WAD/(2·RAMP)             for x <= RAMP (365 days)
///           F(x)   = 3·RAMP·WAD/2 + 2·(x−RAMP)·WAD       for x >  RAMP
///
///         — evaluated with the same integer floor semantics, by hand, off-chain. Every
///         literal below is such a figure. Nothing here asserts merely `> 0`.
///
///         WHY THE NUMBERS ARE CLEAN. The vault seed (`Deploy._seed`) deposits 10e18 for
///         exactly 1e27 shares (offset-6, first deposit). A subsequent first depositor of
///         1e24 USDfr therefore mints `mulDiv(1e24, 1e27 + 1e6, 1000e18 + 1)` = EXACTLY
///         1e30 shares — 1e6 whole shares, the same unit count as 1e24 USDfr is whole USDfr.
///         That is what makes the 1x-vs-3x comparison an exact equality rather than a
///         tolerance, and it is asserted, not assumed.
contract PointsForkTest is ForkLifecycleFixture {
    // ── independently computed expectations (see the header; floor semantics matched) ──
    // B = 1e24 USDfr, S = t0, unit 1e18, rate 1e18/unit/day, USDfr multiplier 3x.
    uint256 internal constant USDFR_1E24_1D = 3_004_109_589_041_095_890_410_937;
    uint256 internal constant USDFR_1E24_10D = 30_410_958_904_109_589_041_095_868;
    uint256 internal constant USDFR_1E24_10D_DAILY_CP = 30_410_958_904_109_589_041_095_863;
    uint256 internal constant USDFR_1E24_30D = 93_698_630_136_986_301_369_862_986;
    uint256 internal constant USDFR_1E24_100D = 341_095_890_410_958_904_109_589_027;
    uint256 internal constant USDFR_1E24_130D = 459_452_054_794_520_547_945_205_451;
    uint256 internal constant USDFR_1E24_400D = 1_852_500_000_000_000_000_000_000_000;
    uint256 internal constant USDFR_1E24_400D_TO_401D = 6_000_000_000_000_000_000_000_000;
    // B = 1e30 sUSDfr shares, S = t0, unit 1e24, rate 1e18/unit/day, shares multiplier 1x.
    uint256 internal constant SHARES_1E30_30D = 31_232_876_712_328_767_123_287_662;
    // B = 1e23 USDfr, S = t0, unit 1e18, USDfr 3x.
    uint256 internal constant USDFR_1E23_30D = 9_369_863_013_698_630_136_986_298;
    // B = 9e23 USDfr, S = t0, unit 1e18, USDfr 3x.
    uint256 internal constant USDFR_9E23_30D = 84_328_767_123_287_671_232_876_687;
    // B = 1e23 curator first-loss, S = t0, unit 1e18, curator multiplier 5x.
    uint256 internal constant CURATOR_1E23_30D = 15_616_438_356_164_383_561_643_831;
    // B = 5e22 curator first-loss over [30d, 60d), S still t0 (maturity is NOT reset by a
    // partial withdrawal — only `_track` on NEW capital blends it).
    uint256 internal constant CURATOR_5E22_30D_60D = 8_424_657_534_246_575_342_465_755;
    // B = 1e23 curator first-loss over [30d, 60d), S = t0, at a RAISED 10x multiplier.
    uint256 internal constant CURATOR_1E23_30D_60D_AT_10X = 33_698_630_136_986_301_369_863_020;
    // Non-retroactive rate change (P-03): 10 days at rate 1e18, then 10 days at rate 2e18.
    uint256 internal constant NONRETRO_EPOCH0 = 30_410_958_904_109_589_041_095_868;
    uint256 internal constant NONRETRO_EPOCH1 = 62_465_753_424_657_534_246_575_347;
    // What the same 20 days would have been had the new rate applied RETROACTIVELY.
    uint256 internal constant RETROACTIVE_WOULD_BE = 123_287_671_232_876_712_328_767_083;

    // NOTE: `SEED_SINK` (0x…dEaD, the anti-inflation seed sink) is inherited from `Deploy`.
    // It is NOT protocol-exempt, so it holds a real, permanently locked shares position.

    uint32 internal constant MAX_MULT_BPS = 200_000; // 20x
    uint256 internal constant MAX_RATE = 1e9 * 1e18;

    address internal dave = makeAddr("forkDave");
    address internal eve = makeAddr("forkEve");

    // Mirrors of the fail-open telemetry events so `vm.expectEmit` can match them.
    event PointsHookFailed(address indexed from, address indexed to, uint256 value);
    event PointsAccrued(address indexed wallet, uint8 indexed kind, uint256 amount);

    function setUp() public override {
        super.setUp();
        if (!forkReady) return;
        compliance.setAllowed(dave, true);
        compliance.setAllowed(eve, true);
        deal(USDC, dave, 5_000_000e6);
        deal(USDC, eve, 5_000_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 0. Anti-silent-skip guard.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Proves this suite really executed against the PINNED mainnet fork, rather
    ///         than reporting green off an unconfigured RPC. The predecessor suite
    ///         (`SepoliaForkPreMainnet`) returned early and passed while running nothing;
    ///         `onFork` uses `vm.skip`, and this test pins the chain identity as well.
    function test_fork_isActuallyRunningOnThePinnedMainnetFork() public onFork {
        assertEq(block.chainid, 1, "forked Ethereum mainnet");
        assertEq(block.number, FORK_BLOCK, "at the PINNED block (reproducible)");
        assertGt(USDC.code.length, 0, "real USDC bytecode is present");
        assertEq(IERC20Metadata(USDC).symbol(), "USDC", "and it really is USDC");
        assertEq(IERC20Metadata(USDC).decimals(), 6, "6-dec, as the fixture assumes");
        assertGt(IERC20Metadata(USDC).totalSupply(), 1e15, "with a real circulating supply, not a mock");
        assertGt(USDT.code.length, 0, "real USDT present");
        assertGt(DAI.code.length, 0, "real DAI present");
        assertEq(usdfr.pointsModule(), address(points), "USDfr is wired to the deployed points ledger");
        assertEq(vault.pointsModule(), address(points), "sUSDfr is wired to it too");
        assertEq(curator.pointsModule(), address(points), "and the CuratorModule (P-01)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Accrual is EXACTLY the spec integral, over calendar-scale time.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice USDfr accrual matches the off-chain integral to the wei at 1, 10 and 30 days,
    ///         and is strictly SUPERLINEAR because of the maturity ramp.
    function test_fork_usdfrAccrual_matchesIndependentIntegral() public onFork {
        // Self-check: the in-Solidity model agrees with the hand-computed literals, so the
        // two independent evaluations of the spec cross-validate each other.
        assertEq(_model(1e24, 0, 1 days, 30_000), USDFR_1E24_1D, "model self-check, 1 day");
        assertEq(_model(1e24, 0, 30 days, 30_000), USDFR_1E24_30D, "model self-check, 30 days");
        assertEq(_model(1e23, 0, 30 days, 50_000), CURATOR_1E23_30D, "model self-check, curator 5x");
        assertEq(_model(1e24, 0, 400 days, 30_000), USDFR_1E24_400D, "model self-check, past the ramp knee");

        uint256 minted = _mintFromUSDC(alice, 1_000_000e6);
        assertEq(minted, 1e24, "1e24 USDfr is the base of every literal below");
        (uint256 trackedShares, uint256 trackedUsdfr) = points.trackedBalances(alice);
        assertEq(trackedUsdfr, 1e24, "mint tracked the USDfr position");
        assertEq(trackedShares, 0, "no shares yet");
        assertEq(points.pointsOfWallet(alice), 0, "nothing accrues in the mint block");

        _warp(1 days);
        assertEq(points.pointsOfWallet(alice), USDFR_1E24_1D, "1 day == the spec integral");

        _warp(9 days);
        assertEq(points.pointsOfWallet(alice), USDFR_1E24_10D, "10 days == the spec integral");
        assertGt(
            points.pointsOfWallet(alice), USDFR_1E24_1D * 10, "SUPERLINEAR: the 1.0x->2.0x maturity ramp pays patience"
        );

        _warp(20 days);
        assertEq(points.pointsOfWallet(alice), USDFR_1E24_30D, "30 days == the spec integral");

        // The whole total is USDfr-sourced; the other two streams are untouched.
        (uint256 fromShares, uint256 fromUSDfr, uint256 fromCurator) = points.pointsBreakdown(alice);
        assertEq(fromUSDfr, USDFR_1E24_30D, "breakdown attributes it all to USDfr");
        assertEq(fromShares, 0, "no shares stream");
        assertEq(fromCurator, 0, "no curator stream");
    }

    /// @notice Accrual is ADDITIVE across checkpoints: ten daily checkpoints reach the same
    ///         figure as one ten-day integral, and never MORE (floor only ever loses dust).
    function test_fork_accrualIsAdditiveAcrossCheckpointIntervals() public onFork {
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "alice: checkpointed daily");
        assertEq(_mintFromUSDC(bob, 1_000_000e6), 1e24, "bob: never checkpointed");

        for (uint256 i = 0; i < 10; ++i) {
            _warp(1 days);
            points.checkpoint(alice);
        }

        uint256 chunked = points.pointsOfWallet(alice);
        uint256 oneShot = points.pointsOfWallet(bob);
        assertEq(oneShot, USDFR_1E24_10D, "one-shot == the spec integral");
        assertEq(chunked, USDFR_1E24_10D_DAILY_CP, "ten daily chunks == the spec integral, chunk by chunk");
        assertLe(chunked, oneShot, "checkpointing can never MINT points");
        assertEq(oneShot - chunked, 5, "the whole cost of 10 checkpoints is 5 wei of floor dust");
    }

    /// @notice The maturity ramp caps at exactly 2.0x after 365 days — the day-401 increment
    ///         is exactly twice the un-ramped base rate, to the wei.
    function test_fork_maturityRampCapsAtExactlyTwoX() public onFork {
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "base position");
        assertEq(points.MATURITY_RAMP(), 365 days, "the ramp length is one year");

        _warp(400 days);
        points.checkpoint(alice);
        uint256 at400 = points.pointsOfWallet(alice);
        assertEq(at400, USDFR_1E24_400D, "400 days == the spec integral past the ramp knee");

        _warp(1 days);
        uint256 dayIncrement = points.pointsOfWallet(alice) - at400;
        assertEq(dayIncrement, USDFR_1E24_400D_TO_401D, "day 401 accrues exactly 2x base");
        // 1e24 USDfr, 1e18 unit, rate 1e18/day, 3x -> 3e24/day un-ramped. 2x that is 6e24.
        assertEq(dayIncrement, 2 * 3e24, "the ramp multiplier m(tau) is pinned at 2.0, not still growing");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. The per-unit multipliers: shares 1x, USDfr 3x, curator 5x.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice points-v2: a USDfr holder earns EXACTLY 3x what an sUSDfr holder of the same
    ///         unit count earns — in lieu of the vault yield the staker also receives.
    function test_fork_usdfrEarnsExactlyThreeTimesTheSharesRate() public onFork {
        assertEq(points.usdfrMultiplierBps(), 30_000, "genesis USDfr multiplier is 3x");
        assertEq(points.curatorMultiplierBps(), 50_000, "genesis curator multiplier is 5x");
        assertEq(points.ratePerUnitDay(), 1e18, "genesis base rate is 1 point/unit/day");

        // alice: 1e24 USDfr == 1e6 whole USDfr, held.
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "alice holds USDfr");
        // dave: the same notional, staked. First non-seed depositor => exactly 1e30 shares.
        assertEq(_mintFromUSDC(dave, 1_000_000e6), 1e24, "dave mints the same notional");
        uint256 shares = _stake(dave, 1e24);
        assertEq(shares, 1e30, "offset-6 vault + the 1e27 seed makes this an EXACT 1e6 whole shares");

        (, uint256 daveUsdfrTracked) = points.trackedBalances(dave);
        assertEq(daveUsdfrTracked, 0, "staking moved dave's USDfr out of the USDfr stream");
        (uint256 daveShareTracked,) = points.trackedBalances(dave);
        assertEq(daveShareTracked, 1e30, "and into the shares stream");

        _warp(30 days);

        uint256 usdfrPoints = points.pointsOfWallet(alice);
        uint256 sharePoints = points.pointsOfWallet(dave);
        assertEq(usdfrPoints, USDFR_1E24_30D, "USDfr leg == the spec integral");
        assertEq(sharePoints, SHARES_1E30_30D, "shares leg == the spec integral");
        assertEq(usdfrPoints, 3 * sharePoints, "EXACTLY 3x per unit held, to the wei");

        // The vault custodies alice-and-dave's USDfr but is protocol-exempt: it must not
        // double-count the staked TVL as its own participation.
        assertEq(usdfr.balanceOf(address(vault)), 1e24 + 10e18, "the vault holds dave's stake plus the $10 seed");
        assertEq(points.pointsOfWallet(address(vault)), 0, "and accrues nothing on it (exempt)");
    }

    /// @notice Curator first-loss accrues at the curator multiplier (5x) — the most
    ///         subordinated capital earns the most (P-01) — and the CuratorModule itself,
    ///         which custodies that USDfr, accrues nothing.
    function test_fork_curatorFirstLossAccruesAtCuratorMultiplier() public onFork {
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, alice, true);
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "alice funds first-loss + a held balance");
        assertEq(_mintFromUSDC(bob, 100_000e6), 1e23, "bob holds the SAME notional as plain USDfr");

        vm.startPrank(alice);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1e23);
        vm.stopPrank();

        assertEq(curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, alice), 1e23, "posted first-loss");
        assertEq(points.curatorTracked(alice, Config.CLASS_FILM_TAX_CREDITS), 1e23, "the ledger tracked it");
        assertEq(usdfr.balanceOf(alice), 9e23, "the rest stays in her wallet");

        _warp(30 days);

        (uint256 fromShares, uint256 fromUSDfr, uint256 fromCurator) = points.pointsBreakdown(alice);
        assertEq(fromShares, 0, "alice staked nothing");
        assertEq(fromUSDfr, USDFR_9E23_30D, "the held 9e23 accrues at 3x, per the spec integral");
        assertEq(fromCurator, CURATOR_1E23_30D, "the posted 1e23 accrues at 5x, per the spec integral");
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            CURATOR_1E23_30D,
            "and it is attributed to the FILM class"
        );
        for (uint256 cid = 2; cid <= Config.NUM_CLASSES; ++cid) {
            assertEq(points.curatorPointsInClass(alice, cid), 0, "no other class earned anything");
        }

        // 5x vs 3x on identical notional held for an identical window (3 wei of floor dust).
        uint256 bobUsdfr = points.pointsOfWallet(bob);
        assertEq(bobUsdfr, USDFR_1E23_30D, "bob's 1e23 at 3x == the spec integral");
        assertApproxEqAbs(fromCurator * 3, bobUsdfr * 5, 3, "first-loss earns 5/3 of a plain USDfr holding");

        // The custodian must not accrue on capital it merely holds for others.
        assertEq(usdfr.balanceOf(address(curator)), 1e23, "the module holds the first-loss USDfr");
        assertEq(points.pointsOfWallet(address(curator)), 0, "and accrues nothing on it (exempt)");

        // A partial withdrawal reconciles the position DOWN, keeps what was already earned,
        // and does NOT reset the maturity anchor for the surviving capital.
        vm.prank(alice);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 5e22);
        assertEq(points.curatorTracked(alice, Config.CLASS_FILM_TAX_CREDITS), 5e22, "tracked down to the posted half");
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            CURATOR_1E23_30D,
            "the first 30 days were banked on withdrawal, not lost"
        );

        _warp(30 days);
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            CURATOR_1E23_30D + CURATOR_5E22_30D_60D,
            "the surviving half keeps its ORIGINAL maturity anchor into days 30-60"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Permissionless maintenance.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `checkpoint` and `reconcile` are permissionless and VALUE-NEUTRAL: a
    ///         stranger (here a NON-KYC'd one) can call them for anyone and cannot change
    ///         the total by a single wei in either direction.
    function test_fork_checkpointAndReconcileArePermissionlessAndValueNeutral() public onFork {
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "position");
        _warp(30 days);

        uint256 before = points.pointsOfWallet(alice);
        assertEq(before, USDFR_1E24_30D, "pending, uncheckpointed");

        // carol is NOT KYC'd and holds no role.
        assertFalse(compliance.isAllowed(carol), "carol is deliberately un-whitelisted");
        vm.expectEmit(true, true, false, true, address(points));
        emit PointsAccrued(alice, 1, USDFR_1E24_30D);
        vm.prank(carol);
        points.checkpoint(alice);

        assertEq(points.pointsOfWallet(alice), before, "checkpointing is exactly value-neutral");
        vm.prank(carol);
        points.checkpoint(alice); // idempotent in the same block
        assertEq(points.pointsOfWallet(alice), before, "a second checkpoint adds nothing");

        vm.prank(carol);
        points.reconcile(alice);
        assertEq(points.pointsOfWallet(alice), before, "reconcile is value-neutral when nothing desynced");
        (, uint256 trackedUsdfr) = points.trackedBalances(alice);
        assertEq(trackedUsdfr, usdfr.balanceOf(alice), "and leaves the tracked balance on the live balance");

        // Accrual continues normally afterwards, off the new checkpoint.
        _warp(1 days);
        assertEq(
            points.pointsOfWallet(alice) - before,
            _pointsForOneDayAt(30 days),
            "the next day accrues off the checkpoint, at the day-30 ramp"
        );
    }

    /// @dev The ADR-0016 ramp integral F(x) = x·WAD + x²·WAD/(2·RAMP), written out here
    ///      independently of the contract (this suite never reads the contract's own maths).
    function _F(uint256 x) private pure returns (uint256) {
        uint256 wad = 1e18;
        uint256 ramp = 365 days;
        if (x <= ramp) return x * wad + (x * x * wad) / (2 * ramp);
        return (3 * ramp * wad) / 2 + 2 * (x - ramp) * wad;
    }

    /// @dev Independently computed accrual for a position of `bal` raw units (18-dec stream)
    ///      whose maturity anchor is `age` old at `a`, over the window [a, b), at base rate
    ///      1e18/unit/day and multiplier `multBps`.
    function _model(uint256 bal, uint256 ageAtA, uint256 window, uint32 multBps) private pure returns (uint256) {
        return _modelUnit(bal, ageAtA, window, multBps, 1e18);
    }

    /// @dev As `_model`, with an explicit stream unit — 1e18 for USDfr / curator first-loss,
    ///      1e24 for sUSDfr shares (the offset-6 vault's whole-share unit).
    function _modelUnit(uint256 bal, uint256 ageAtA, uint256 window, uint32 multBps, uint256 unit)
        private
        pure
        returns (uint256)
    {
        uint256 wad = 1e18;
        uint256 day = 1 days;
        uint256 dF = _F(ageAtA + window) - _F(ageAtA);
        uint256 rate = (uint256(1e18) * uint256(multBps)) / 10_000;
        return ((bal * dF) / wad) * rate / (day * unit);
    }

    /// @dev One day of a 1e24 USDfr position whose maturity is `age` old (3x multiplier).
    function _pointsForOneDayAt(uint256 age) private pure returns (uint256) {
        return _model(1e24, age, 1 days, 30_000);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Exit intent ends participation; a fresh wallet restarts the ramp.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Accrual STOPS at redemption-request time. The queue holds the shares but is
    ///         protocol-exempt and identity-blind, so neither the requester nor the queue
    ///         accrues another point for the queued capital (ADR-0016 note in RedemptionQueue).
    function test_fork_accrualStopsAtRedemptionRequest_queueIsUnbound() public onFork {
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "mint");
        assertEq(_stake(alice, 1e24), 1e30, "stake everything: exactly 1e30 shares");

        _warp(30 days);
        assertEq(points.pointsOfWallet(alice), SHARES_1E30_30D, "30 days of shares accrual");

        vm.startPrank(alice);
        vault.approve(address(queue), 1e30);
        uint256 reqId = queue.requestRedeem(1e30);
        vm.stopPrank();

        uint256 atRequest = points.pointsOfWallet(alice);
        assertEq(atRequest, SHARES_1E30_30D, "the request banked exactly what was earned, no more");
        (uint256 aliceShares,) = points.trackedBalances(alice);
        assertEq(aliceShares, 0, "alice's tracked share position is emptied at request time");
        (uint256 queueShares, uint256 queueUsdfr) = points.trackedBalances(address(queue));
        assertEq(queueShares, 0, "the QUEUE never picks the position up");
        assertEq(queueUsdfr, 0, "nor any USDfr position");
        assertEq(vault.balanceOf(address(queue)), 1e30, "even though it genuinely custodies the shares");

        // Long dwell in the queue: not one further point, for anyone.
        _warp(60 days);
        assertEq(points.pointsOfWallet(alice), atRequest, "exit intent ENDED participation accrual");
        assertEq(points.pointsOfWallet(address(queue)), 0, "the queue accrues nothing, ever");

        // Settle and claim; the returned USDfr opens a FRESH position with a reset ramp.
        queue.closeEpoch(50);
        (,, uint256 claimable,,) = queue.request(reqId);
        assertGt(claimable, 0, "the request filled after the cooldown");
        vm.prank(alice);
        queue.claim(reqId);
        assertEq(usdfr.balanceOf(alice), claimable, "claimed USDfr in hand");
        (, uint256 aliceUsdfr) = points.trackedBalances(alice);
        assertEq(aliceUsdfr, claimable, "a NEW USDfr position opened at the claimed size");

        uint256 afterClaim = points.pointsOfWallet(alice);
        assertEq(afterClaim, atRequest, "claiming itself credits nothing");
        _warp(1 days);
        // Fresh maturity anchor: the first day pays the UN-ramped rate, not the day-90 rate.
        uint256 firstDay = points.pointsOfWallet(alice) - afterClaim;
        assertEq(
            firstDay, _model(claimable, 0, 1 days, 30_000), "the re-entered position starts the ramp again at 1.0x"
        );
        assertLt(
            firstDay * 1e24 / claimable,
            _model(1e24, 90 days, 1 days, 30_000),
            "and pays the UN-ramped day-zero rate, not the day-90 rate it would have had"
        );
    }

    /// @notice Sybil-safety / patience: a transfer to a FRESH wallet restarts that wallet's
    ///         maturity ramp at 1.0x, and freezes the sender's position at what it earned.
    function test_fork_freshWalletRestartsTheMaturityRamp() public onFork {
        assertEq(_mintFromUSDC(dave, 1_000_000e6), 1e24, "dave's aged position");
        _warp(100 days);
        assertEq(points.pointsOfWallet(dave), USDFR_1E24_100D, "100 days aged == the spec integral");

        vm.prank(dave);
        usdfr.transfer(eve, 1e24);

        assertEq(points.pointsOfWallet(dave), USDFR_1E24_100D, "dave banked exactly his 100 days");
        (, uint256 daveTracked) = points.trackedBalances(dave);
        assertEq(daveTracked, 0, "and holds nothing further");
        (, uint256 eveTracked) = points.trackedBalances(eve);
        assertEq(eveTracked, 1e24, "eve's position is live");
        assertEq(points.pointsOfWallet(eve), 0, "eve starts from zero, NOT from dave's ramp");

        _warp(30 days);
        assertEq(points.pointsOfWallet(dave), USDFR_1E24_100D, "dave still frozen");
        assertEq(
            points.pointsOfWallet(eve),
            USDFR_1E24_30D,
            "eve earns the DAY-ZERO 30-day integral: splitting to a fresh wallet is strictly worse"
        );
        // Days 100-130 on an UNBROKEN position would have paid strictly more: the split
        // forfeited the accumulated ramp. That is the sybil-resistance property.
        assertLt(
            points.pointsOfWallet(eve),
            USDFR_1E24_130D - USDFR_1E24_100D,
            "and strictly less than staying put would have paid over the same 30 days"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Protocol-exempt custody addresses never accrue.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Every custody module is protocol-exempt and accrues nothing, however much
    ///         value it holds. The permanently locked seed sink is exempt too, so the
    ///         anti-inflation seed never earns points.
    function test_fork_protocolExemptCustodyAddressesNeverAccrue() public onFork {
        (uint256 seedShares,) = points.trackedBalances(SEED_SINK);
        assertEq(seedShares, 0, "the $10 anti-inflation seed is excluded from points");
        (uint256 s0, uint256 u0, uint256 c0) = points.totals();
        assertEq(s0, 0, "no tracked shares at genesis");
        assertEq(u0, 0, "no tracked USDfr at genesis (the deployer is fee-recipient => exempt)");
        assertEq(c0, 0, "no tracked first-loss at genesis");

        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, alice, true);
        assertEq(_mintFromUSDC(alice, 2_000_000e6), 2e24, "alice mints");
        _stake(alice, 1e24);
        vm.startPrank(alice);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1e23);
        vm.stopPrank();

        _warp(30 days);

        address[6] memory exempts =
            [address(vault), address(queue), address(reserves), address(controller), address(curator), address(sGrove)];
        for (uint256 i = 0; i < exempts.length; ++i) {
            assertTrue(compliance.isProtocolExempt(exempts[i]), "expected a protocol-exempt module");
            assertEq(points.pointsOfWallet(exempts[i]), 0, "an exempt custody module accrued points");
            (uint256 es, uint256 eu) = points.trackedBalances(exempts[i]);
            assertEq(es, 0, "exempt module has no tracked shares");
            assertEq(eu, 0, "exempt module has no tracked USDfr");
        }

        // Totals reconcile to user positions only.
        (uint256 s1, uint256 u1, uint256 c1) = points.totals();
        (uint256 aliceShares, uint256 aliceUsdfr) = points.trackedBalances(alice);
        assertEq(s1, aliceShares, "tracked shares == alice; seed excluded");
        assertEq(u1, aliceUsdfr, "tracked USDfr == alice's held balance");
        assertEq(aliceUsdfr, usdfr.balanceOf(alice), "which is her live token balance");
        assertEq(c1, 1e23, "tracked first-loss == alice's posted capital");
        assertEq(c1, curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, alice), "== the live posted amount");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. FAIL-OPEN: a broken points module must never be able to DoS the protocol.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A points module that REVERTS on every call cannot block a USDfr transfer, an
    ///         sUSDfr deposit, or an sUSDfr transfer. The dropped transitions surface as
    ///         `PointsHookFailed` telemetry (P-04) and are fully repaired by `reconcile`.
    function test_fork_revertingPointsModuleCannotDoSUSDfrOrShares() public onFork {
        RevertingPoints broken = new RevertingPoints();
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "healthy position first");
        (, uint256 tracked0) = points.trackedBalances(alice);
        assertEq(tracked0, 1e24, "tracked while healthy");

        // ── USDfr leg ────────────────────────────────────────────────────
        usdfr.setPointsModule(address(broken));
        assertEq(usdfr.pointsModule(), address(broken), "USDfr now points at a reverting module");

        vm.expectEmit(true, true, false, true, address(usdfr));
        emit PointsHookFailed(alice, bob, 4e23);
        vm.prank(alice);
        usdfr.transfer(bob, 4e23);
        assertEq(usdfr.balanceOf(alice), 6e23, "TRANSFER SUCCEEDED despite the reverting hook");
        assertEq(usdfr.balanceOf(bob), 4e23, "and the value actually moved");

        // A mint and a burn (redeem) must survive it too — these are the value-critical paths.
        assertEq(_mintFromUSDC(bob, 100_000e6), 1e23, "MINT succeeded through the broken hook");
        vm.startPrank(bob);
        usdfr.approve(address(controller), 1e23);
        uint256 usdcOut = controller.redeem(1e23);
        vm.stopPrank();
        assertEq(usdcOut, 100_000e6, "REDEEM (burn) succeeded through the broken hook");

        // The ledger is now stale-high for alice and empty for bob — observable, repairable.
        (, uint256 staleAlice) = points.trackedBalances(alice);
        assertEq(staleAlice, 1e24, "the ledger kept the pre-failure balance (fail-OPEN, not fail-safe)");
        (, uint256 staleBob) = points.trackedBalances(bob);
        assertEq(staleBob, 0, "bob's inbound transfer was dropped");

        usdfr.setPointsModule(address(points));
        points.reconcile(alice);
        points.reconcile(bob);
        (, uint256 fixedAlice) = points.trackedBalances(alice);
        (, uint256 fixedBob) = points.trackedBalances(bob);
        assertEq(fixedAlice, usdfr.balanceOf(alice), "reconcile REPAIRED alice to her live balance");
        assertEq(fixedBob, usdfr.balanceOf(bob), "reconcile REPAIRED bob to his live balance");

        // ── sUSDfr leg ───────────────────────────────────────────────────
        vault.setPointsModule(address(broken));
        vm.startPrank(alice);
        usdfr.approve(address(vault), 6e23);
        uint256 shares = vault.deposit(6e23, alice);
        vm.stopPrank();
        // Exactly 6e29: the offset-6 vault plus the 1e27 seed makes 1e24 -> 1e30 exact (see the
        // contract header), and 6e23 is the same ratio — so this is an equality, not a bound.
        assertEq(shares, 6e29, "DEPOSIT SUCCEEDED despite the reverting share hook, for the exact share count");
        assertEq(vault.balanceOf(alice), shares, "shares really minted");
        (uint256 droppedShares,) = points.trackedBalances(alice);
        assertEq(droppedShares, 0, "the share transition was dropped");

        vm.expectEmit(true, true, false, true, address(vault));
        emit PointsHookFailed(alice, bob, shares / 2);
        vm.prank(alice);
        vault.transfer(bob, shares / 2);
        assertEq(vault.balanceOf(bob), shares / 2, "SHARE TRANSFER SUCCEEDED despite the reverting hook");

        vault.setPointsModule(address(points));
        points.reconcile(alice);
        points.reconcile(bob);
        (uint256 repairedShares,) = points.trackedBalances(alice);
        assertEq(repairedShares, vault.balanceOf(alice), "reconcile REPAIRED the share position");
        (uint256 repairedBobShares,) = points.trackedBalances(bob);
        assertEq(repairedBobShares, vault.balanceOf(bob), "and bob's");

        // And accrual resumes correctly off the repaired state — at the exact spec integral for
        // the repaired SHARE position (unit 1e24, 1x), on a maturity anchored at the repair.
        assertEq(points.pointsOfWallet(alice), 0, "nothing was earned before the repair (no time had elapsed)");
        _warp(1 days);
        assertEq(
            points.pointsOfWallet(alice),
            _modelUnit(vault.balanceOf(alice), 0, 1 days, 10_000, 1e24),
            "accrual resumed after repair, at the un-ramped day-zero shares rate"
        );
    }

    /// @notice The same, on the CuratorModule leg: a reverting points module must never
    ///         block posting or withdrawing first-loss capital (cascade-relevant movements).
    function test_fork_revertingPointsModuleCannotDoSFirstLoss() public onFork {
        RevertingPoints broken = new RevertingPoints();
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, alice, true);
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "funds");

        curator.setPointsModule(address(broken));
        vm.startPrank(alice);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1e23);
        vm.stopPrank();
        assertEq(curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, alice), 1e23, "POST SUCCEEDED through the broken hook");
        assertEq(points.curatorTracked(alice, Config.CLASS_FILM_TAX_CREDITS), 0, "the transition was dropped");

        vm.prank(alice);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 2e22);
        assertEq(
            curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, alice), 8e22, "WITHDRAW SUCCEEDED through the broken hook"
        );

        curator.setPointsModule(address(points));
        points.reconcile(alice);
        assertEq(
            points.curatorTracked(alice, Config.CLASS_FILM_TAX_CREDITS),
            8e22,
            "reconcile REPAIRED the first-loss position to the live posted amount"
        );

        _warp(30 days);
        // Repaired position, maturity anchored at the reconcile instant, 5x multiplier.
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            _model(8e22, 0, 30 days, 50_000),
            "and accrues at the curator multiple thereafter"
        );
    }

    /// @notice GAS GRIEFING probe: try/catch does not protect against a callee that BURNS
    ///         all forwarded gas (EIP-150 gives it 63/64 of what is left). With an ordinary
    ///         transaction gas budget the transfer must still complete — but the budget
    ///         REQUIRED rises, and this test quantifies by how much rather than asserting a
    ///         vague "it works".
    function test_fork_gasBurningPointsModuleCannotDoSTransfers() public onFork {
        GasBurnerPoints burner = new GasBurnerPoints();
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "position");

        // Baseline: what a transfer costs with the healthy ledger wired.
        uint256 g0 = gasleft();
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        uint256 healthyCost = g0 - gasleft();
        console2.log("healthy USDfr transfer gas", healthyCost);

        assertLt(healthyCost, 100_000, "baseline: a healthy transfer is well under 100k gas");

        usdfr.setPointsModule(address(burner));
        // The 63/64 rule bounds the grief: the callee cannot take the last 1/64, so the
        // requirement is roughly `64 x (post-hook epilogue)` of headroom, not unbounded.
        // Grid logged so the threshold is a measured number in the record, not folklore.
        for (uint256 cap = 100_000; cap <= 250_000; cap += 25_000) {
            console2.log("burner-module transfer, gas cap / succeeded:", cap, _probeTransfer(cap));
        }
        assertTrue(_probeTransfer(200_000), "an ordinary wallet gas budget still completes");

        vm.prank(alice);
        bool ok = usdfr.transfer{gas: 2_000_000}(bob, 1e23);
        assertTrue(ok, "a gas-burning points module must not be able to brick USDfr transfers");
        assertEq(usdfr.balanceOf(bob), 1e23 + 1e18, "value moved");

        // Restore and prove the ledger is repairable from the griefed state as well.
        usdfr.setPointsModule(address(points));
        points.reconcile(bob);
        (, uint256 trackedBob) = points.trackedBalances(bob);
        assertEq(trackedBob, 1e23 + 1e18, "reconcile repairs a gas-griefed drop too");
    }

    /// @dev Attempts a 1-wei USDfr transfer under a hard gas cap; returns whether it fit.
    ///      A low-level call so a failure is observed, not propagated. Sent to `dave` so the
    ///      probes never perturb the balances the test asserts on.
    function _probeTransfer(uint256 cap) private returns (bool ok) {
        vm.prank(alice);
        (ok,) = address(usdfr).call{gas: cap}(abi.encodeWithSignature("transfer(address,uint256)", dave, uint256(1)));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6b. H-03: impaired first-loss must not out-accrue live capital.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A REAL default -> cascade -> `absorbLoss` on the deployed stack freezes the
    ///         curator's points at the loss instant and writes the cached balance down by the
    ///         exact pro-rata dilution. A permissionless `checkpoint` must NOT be able to lift
    ///         the freeze (that was the original H-03 bypass); only `reconcile` may, and the
    ///         frozen window is forfeited rather than back-paid.
    function test_fork_curatorLossFreezesPointsAndOnlyReconcileThaws() public onFork {
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, alice, true);
        assertEq(_mintFromUSDC(alice, 3_000_000e6), 3e24, "funds");
        _stake(alice, 1e24);
        vm.startPrank(alice);
        usdfr.approve(address(curator), 2e23);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 2e23);
        vm.stopPrank();
        uint256 tokenId = _originateAndFund(4e23);

        _warp(30 days);
        uint256 earnedBeforeLoss = _model(2e23, 0, 30 days, 50_000);
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            earnedBeforeLoss,
            "30 clean days at 5x on 2e23 posted"
        );

        // A real, attested default; the loss is exactly half the first-loss pool.
        _declareDefault(tokenId, bytes32(0));
        _realizeLoss(tokenId, 1e23, bytes32(0));

        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 1e23, "layer 1 absorbed exactly the loss");
        assertEq(curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, alice), 1e23, "alice diluted pro-rata");
        assertEq(points.curatorLossEpochCount(Config.CLASS_FILM_TAX_CREDITS), 1, "one loss epoch logged");
        uint64 lossAt = points.curatorLossAt(Config.CLASS_FILM_TAX_CREDITS, 0);
        assertEq(lossAt, uint64(block.timestamp), "logged at the absorption instant");
        assertEq(points.lastCuratorLossAt(Config.CLASS_FILM_TAX_CREDITS), lossAt, "legacy observability field agrees");
        (uint64 lossRound, uint256 survivalWad) = points.curatorDilutionState(Config.CLASS_FILM_TAX_CREDITS);
        assertEq(lossRound, 0, "no wipe: the pro-rata ratio was usable, so no round bump");
        assertEq(survivalWad, 5e17, "exactly half the class survived (1e23 of 2e23)");

        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(alice, Config.CLASS_FILM_TAX_CREDITS);
        assertTrue(frozen, "the position is frozen by the un-reconciled loss");
        assertEq(frozenAt, lossAt, "and pinned at the loss instant");

        // Neither elapsed time nor a permissionless checkpoint may thaw it.
        _warp(30 days);
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            earnedBeforeLoss,
            "FROZEN: 30 further days accrue nothing"
        );
        vm.prank(carol);
        points.checkpoint(alice);
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            earnedBeforeLoss,
            "a permissionless checkpoint CANNOT lift the freeze (H-03)"
        );
        (frozen,) = points.curatorFreezeStatus(alice, Config.CLASS_FILM_TAX_CREDITS);
        assertTrue(frozen, "still frozen after the checkpoint");
        assertEq(
            points.curatorTracked(alice, Config.CLASS_FILM_TAX_CREDITS),
            1e23,
            "but the checkpoint DID write the cached balance down (monotone, downward only)"
        );

        // Only `reconcile` thaws — and only against the live posted amount.
        vm.prank(carol);
        points.reconcile(alice);
        (frozen, frozenAt) = points.curatorFreezeStatus(alice, Config.CLASS_FILM_TAX_CREDITS);
        assertFalse(frozen, "reconcile thawed the position");
        assertEq(frozenAt, 0, "no freeze instant remains");
        assertEq(
            points.curatorTracked(alice, Config.CLASS_FILM_TAX_CREDITS),
            curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, alice),
            "snapped to the LIVE posted amount"
        );
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            earnedBeforeLoss,
            "the frozen window is FORFEITED, never back-paid on thaw"
        );

        _warp(30 days);
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            earnedBeforeLoss + _model(1e23, 60 days, 30 days, 50_000),
            "accrual resumes on the SURVIVING half, keeping its original maturity anchor"
        );
    }

    /// @notice A class loss dilutes EVERY curator in the class pro-rata off a single
    ///         recorded ratio (no per-curator hook exists), and reconciling ONE curator must
    ///         not thaw another.
    function test_fork_curatorLossDilutesEveryCuratorInTheClassProRata() public onFork {
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        curator.setCuratorApproved(classId, alice, true);
        curator.setCuratorApproved(classId, bob, true);
        assertEq(_mintFromUSDC(alice, 3_000_000e6), 3e24, "alice funds");
        assertEq(_mintFromUSDC(bob, 1_000_000e6), 1e24, "bob funds");
        _stake(alice, 1e24);

        vm.startPrank(alice);
        usdfr.approve(address(curator), 2e23);
        curator.postFirstLoss(classId, 2e23);
        vm.stopPrank();
        vm.startPrank(bob);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(classId, 1e23);
        vm.stopPrank();
        assertEq(curator.poolBalance(classId), 3e23, "pool is 2:1 alice:bob");

        uint256 tokenId = _originateAndFund(6e23);
        _warp(30 days);
        uint256 aliceEarned = _model(2e23, 0, 30 days, 50_000);
        uint256 bobEarned = _model(1e23, 0, 30 days, 50_000);
        assertEq(points.curatorPointsInClass(alice, classId), aliceEarned, "alice's 30 clean days");
        assertEq(points.curatorPointsInClass(bob, classId), bobEarned, "bob's 30 clean days");
        assertEq(aliceEarned / 2, bobEarned, "and they are exactly 2:1, as the capital is");

        _declareDefault(tokenId, bytes32(0));
        _realizeLoss(tokenId, 15e22, bytes32(0)); // exactly half the pool

        (uint64 round, uint256 survival) = points.curatorDilutionState(classId);
        assertEq(round, 0, "usable ratio, so no distrust round");
        assertEq(survival, 5e17, "half the class survived");
        assertEq(curator.postedOf(classId, alice), 1e23, "alice diluted 2e23 -> 1e23");
        assertEq(curator.postedOf(classId, bob), 5e22, "bob diluted 1e23 -> 5e22");

        (bool aliceFrozen,) = points.curatorFreezeStatus(alice, classId);
        (bool bobFrozen,) = points.curatorFreezeStatus(bob, classId);
        assertTrue(aliceFrozen, "alice frozen");
        assertTrue(bobFrozen, "bob frozen");

        // Reconciling alice must NOT thaw bob.
        points.reconcile(alice);
        (aliceFrozen,) = points.curatorFreezeStatus(alice, classId);
        (bobFrozen,) = points.curatorFreezeStatus(bob, classId);
        assertFalse(aliceFrozen, "alice thawed");
        assertTrue(bobFrozen, "bob is UNAFFECTED by alice's reconcile");
        assertEq(points.curatorTracked(alice, classId), 1e23, "alice snapped to her diluted stake");
        assertEq(points.curatorTracked(bob, classId), 1e23, "bob's cache is still stale-high, but frozen");

        _warp(30 days);
        assertEq(
            points.curatorPointsInClass(alice, classId),
            // Reconciled at the loss instant (t0+30d), so this window is [30d, 60d) on the
            // surviving 1e23, still anchored to the ORIGINAL maturity start.
            aliceEarned + _model(1e23, 30 days, 30 days, 50_000),
            "alice accrues again, on the surviving half"
        );
        assertEq(points.curatorPointsInClass(bob, classId), bobEarned, "bob accrues NOTHING while frozen");

        points.reconcile(bob);
        assertEq(points.curatorTracked(bob, classId), 5e22, "bob's cache written down by the same ratio");
        assertEq(points.curatorPointsInClass(bob, classId), bobEarned, "his frozen window is forfeited, not back-paid");
    }

    /// @notice H-03, the REPEATED-loss axis. One loss cannot distinguish "freeze at the FIRST
    ///         un-reconciled loss" from "freeze at the LATEST loss", nor a COMPOUNDED survival
    ///         factor from a per-loss one. This drives THREE successive real defaults-and-
    ///         absorptions on the deployed stack, with a permissionless `checkpoint` between
    ///         each, and pins both:
    ///           - the accrual ceiling stays at loss #1 through losses #2 and #3, so a later
    ///             loss can never re-open the window an earlier one closed (that was the H-03
    ///             harm reached by the "single overwritable timestamp" implementation), and
    ///           - the cached balance is written down by the COMPOUNDED ratio
    ///             (0.75 x 2/3 x 1/2 = 0.25), landing exactly on the live `postedOf` at every
    ///             step rather than drifting high.
    ///         A fourth loss AFTER reconciliation then proves the ceiling does move once the
    ///         position is genuinely caught up — the freeze tracks the watermark, it is not
    ///         a one-way latch.
    function test_fork_repeatedCuratorLossesPinTheFreezeAtTheFirstUnseenLoss() public onFork {
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        curator.setCuratorApproved(classId, alice, true);
        assertEq(_mintFromUSDC(alice, 3_000_000e6), 3e24, "funds");
        vm.startPrank(alice);
        usdfr.approve(address(curator), 4e23);
        curator.postFirstLoss(classId, 4e23);
        vm.stopPrank();
        uint256 t0 = block.timestamp;
        uint256 tokenId = _originateAndFund(8e23);

        _warp(30 days);
        uint256 clean30 = _model(4e23, 0, 30 days, 50_000);
        assertEq(points.curatorPointsInClass(alice, classId), clean30, "30 clean days at 5x on 4e23 posted");

        _declareDefault(tokenId, bytes32(0));

        // ── loss #1 of 3: pool 4e23 -> 3e23 (survival 0.75) ──────────────
        _realizeLoss(tokenId, 1e23, bytes32(0));
        assertEq(block.timestamp, t0 + 30 days, "loss #1 lands at t0+30d");
        assertEq(curator.poolBalance(classId), 3e23, "layer 1 absorbed exactly the loss");
        assertEq(curator.postedOf(classId, alice), 3e23, "alice diluted pro-rata");
        assertEq(points.curatorLossEpochCount(classId), 1, "one loss epoch logged");
        assertEq(points.curatorLossAt(classId, 0), uint64(t0 + 30 days), "logged at the absorption instant");
        _assertDilution(classId, 0, 75e16, "loss #1: 0.75 of the class survived, no distrust round");
        _assertFreeze(alice, classId, true, uint64(t0 + 30 days), "frozen, pinned at loss #1");

        // A permissionless checkpoint mid-freeze: writes the cache DOWN, credits nothing,
        // and must not move the ceiling.
        _warp(10 days);
        vm.prank(carol);
        points.checkpoint(alice);
        assertEq(points.curatorTracked(alice, classId), 3e23, "checkpoint wrote the cache down to the diluted stake");
        assertEq(points.curatorTracked(alice, classId), curator.postedOf(classId, alice), "== the live posted amount");
        assertEq(points.curatorPointsInClass(alice, classId), clean30, "and credited nothing past loss #1");
        _assertFreeze(alice, classId, true, uint64(t0 + 30 days), "the ceiling is unmoved by a checkpoint");

        // ── loss #2 of 3: pool 3e23 -> 2e23 (cumulative survival 0.5) ────
        _warp(20 days);
        _realizeLoss(tokenId, 1e23, bytes32(0));
        assertEq(block.timestamp, t0 + 60 days, "loss #2 lands at t0+60d");
        assertEq(points.curatorLossEpochCount(classId), 2, "the log APPENDS, it does not overwrite");
        assertEq(points.curatorLossAt(classId, 0), uint64(t0 + 30 days), "loss #1 is still in the log, unmoved");
        assertEq(points.curatorLossAt(classId, 1), uint64(t0 + 60 days), "loss #2 appended after it");
        _assertDilution(classId, 0, 5e17, "0.75 x (2/3) COMPOUNDED -- not the latest ratio alone (2/3)");
        assertEq(curator.postedOf(classId, alice), 2e23, "alice diluted again");
        _assertFreeze(
            alice, classId, true, uint64(t0 + 30 days), "STILL loss #1: a LATER loss cannot move the ceiling (H-03)"
        );

        _warp(10 days);
        vm.prank(carol);
        points.checkpoint(alice);
        assertEq(points.curatorTracked(alice, classId), 2e23, "cache compounded down, in one step, to 0.5x");
        assertEq(points.curatorTracked(alice, classId), curator.postedOf(classId, alice), "== the live posted amount");
        assertEq(points.curatorPointsInClass(alice, classId), clean30, "and STILL nothing past loss #1");
        _assertFreeze(alice, classId, true, uint64(t0 + 30 days), "two losses deep, still pinned at the FIRST");

        // ── loss #3 of 3: pool 2e23 -> 1e23 (cumulative survival 0.25) ───
        _warp(20 days);
        _realizeLoss(tokenId, 1e23, bytes32(0));
        assertEq(block.timestamp, t0 + 90 days, "loss #3 lands at t0+90d");
        assertEq(points.curatorLossEpochCount(classId), 3, "three loss epochs");
        assertEq(points.curatorLossAt(classId, 2), uint64(t0 + 90 days), "the third is appended");
        _assertDilution(classId, 0, 25e16, "0.75 x (2/3) x (1/2) COMPOUNDED across all three losses");
        assertEq(curator.postedOf(classId, alice), 1e23, "a quarter of the original stake survives");
        _assertFreeze(alice, classId, true, uint64(t0 + 30 days), "STILL pinned at loss #1, 60 days earlier");

        _warp(30 days);
        vm.prank(carol);
        points.checkpoint(alice);
        assertEq(points.curatorTracked(alice, classId), 1e23, "cache down to a quarter, exactly");
        assertEq(points.curatorTracked(alice, classId), curator.postedOf(classId, alice), "== the live posted amount");
        assertEq(
            points.curatorPointsInClass(alice, classId),
            clean30,
            "90 days of freeze across THREE losses accrued exactly nothing"
        );

        // ── only `reconcile` thaws, and it thaws through ALL THREE at once ──
        vm.prank(carol);
        points.reconcile(alice);
        _assertFreeze(alice, classId, false, 0, "reconcile caught the position up through every recorded loss");
        assertEq(points.curatorLossEpochCount(classId), 3, "the log is untouched by the thaw");
        assertEq(points.curatorTracked(alice, classId), 1e23, "snapped to the live posted amount");
        assertEq(
            points.curatorPointsInClass(alice, classId),
            clean30,
            "all THREE frozen windows are FORFEITED, none back-paid on thaw"
        );

        // Accrual resumes on the surviving quarter, keeping the ORIGINAL maturity anchor.
        _warp(30 days);
        uint256 postThaw = _model(1e23, 120 days, 30 days, 50_000);
        assertEq(
            points.curatorPointsInClass(alice, classId),
            clean30 + postThaw,
            "days 120-150 accrue on the surviving quarter, at the day-120 ramp"
        );

        // ── loss #4, AFTER reconciliation: the ceiling moves to the NEW loss ──
        _realizeLoss(tokenId, 5e22, bytes32(0));
        assertEq(block.timestamp, t0 + 150 days, "loss #4 lands at t0+150d");
        assertEq(points.curatorLossEpochCount(classId), 4, "four loss epochs");
        _assertDilution(classId, 0, 125e15, "0.25 x 0.5 compounded onward, across the reconcile boundary");
        _assertFreeze(
            alice, classId, true, uint64(t0 + 150 days), "NOW pinned at loss #4 -- the freeze tracks the watermark"
        );
        _warp(30 days);
        assertEq(
            points.curatorPointsInClass(alice, classId),
            clean30 + postThaw,
            "and the new freeze halts accrual again, exactly at the loss #4 instant"
        );
    }

    /// @dev Asserts a class's recorded dilution state exactly (kept out of the caller's frame:
    ///      the multi-loss test is otherwise stack-too-deep).
    function _assertDilution(uint256 classId, uint64 wantRound, uint256 wantSurvival, string memory tag) private view {
        (uint64 round, uint256 survival) = points.curatorDilutionState(classId);
        assertEq(round, wantRound, string.concat(tag, " [loss round]"));
        assertEq(survival, wantSurvival, string.concat(tag, " [survival WAD]"));
    }

    /// @dev Asserts a curator position's freeze flag AND its pinned accrual ceiling exactly.
    function _assertFreeze(address w, uint256 classId, bool wantFrozen, uint64 wantAt, string memory tag)
        private
        view
    {
        (bool frozen, uint64 frozenAt) = points.curatorFreezeStatus(w, classId);
        assertEq(frozen, wantFrozen, string.concat(tag, " [frozen]"));
        assertEq(frozenAt, wantAt, string.concat(tag, " [frozen at]"));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6c. Every collateral class, not just class 1.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Curator accrual is a per-class ledger and every reader/writer of it loops over
    ///         ALL FIVE genesis classes: `pointsOfWallet`, `pointsBreakdown`, `checkpoint` and
    ///         `reconcile`. Exercising class 1 alone cannot tell a correct loop from one that
    ///         stops early, so this posts a DISTINCT first-loss position in each of the five
    ///         classes and pins each class's accrual, the breakdown sum, the per-class
    ///         `PointsAccrued` emission from a permissionless checkpoint, and `reconcile`'s
    ///         repair of a dropped transition in every class above the first.
    function test_fork_curatorAccrualAndMaintenanceCoverEveryCollateralClass() public onFork {
        assertEq(Config.NUM_CLASSES, 5, "five genesis classes -- every loop must span all of them");
        assertEq(Config.CLASS_DIGITAL_ASSETS, Config.NUM_CLASSES, "class 5 is the LAST index a loop must reach");
        assertEq(_mintFromUSDC(alice, 2_000_000e6), 2e24, "funds");

        uint256 posted;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            curator.setCuratorApproved(c, alice, true);
            uint256 amt = c * 1e23; // deliberately DISTINCT per class, so no two can be confused
            vm.startPrank(alice);
            usdfr.approve(address(curator), amt);
            curator.postFirstLoss(c, amt);
            vm.stopPrank();
            posted += amt;
            assertEq(curator.postedOf(c, alice), amt, "posted into this class");
            assertEq(points.curatorTracked(alice, c), amt, "and the ledger tracked it in THIS class");
        }
        assertEq(posted, 15e23, "1+2+3+4+5 hundred-thousand-scale positions");
        assertEq(usdfr.balanceOf(alice), 5e23, "the remainder stays held as plain USDfr");
        (,, uint256 totalCurator) = points.totals();
        assertEq(totalCurator, posted, "the curator total spans every class, not just the first");

        _warp(30 days);

        // ── every class accrues its own exact spec integral ──────────────
        uint256 expectedCurator;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 want = _model(c * 1e23, 0, 30 days, 50_000);
            assertEq(points.curatorPointsInClass(alice, c), want, "class accrual == the spec integral");
            expectedCurator += want;
        }
        uint256 expectedUsdfr = _model(5e23, 0, 30 days, 30_000);
        (uint256 fromShares, uint256 fromUSDfr, uint256 fromCurator) = points.pointsBreakdown(alice);
        assertEq(fromShares, 0, "alice staked nothing");
        assertEq(fromUSDfr, expectedUsdfr, "the held 5e23 at 3x == the spec integral");
        assertEq(fromCurator, expectedCurator, "the breakdown sums EVERY class");
        assertLt(
            points.curatorPointsInClass(alice, 1) * 10,
            fromCurator,
            "class 1 alone is under a TENTH of the total: a loop that stopped there would be visibly short"
        );
        assertEq(points.pointsOfWallet(alice), expectedUsdfr + expectedCurator, "and so does the wallet total");

        // ── a permissionless checkpoint must accrue every class ──────────
        // One PointsAccrued(kind = 2) per class, each for that class's exact figure. A loop
        // that stopped short would simply not emit the tail of this sequence.
        vm.expectEmit(true, true, false, true, address(points));
        emit PointsAccrued(alice, 1, expectedUsdfr);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            vm.expectEmit(true, true, false, true, address(points));
            emit PointsAccrued(alice, 2, _model(c * 1e23, 0, 30 days, 50_000));
        }
        vm.prank(carol);
        points.checkpoint(alice);

        // The checkpoint was value-neutral in every class, and accrual continues off it.
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(
                points.curatorPointsInClass(alice, c),
                _model(c * 1e23, 0, 30 days, 50_000),
                "checkpointing is value-neutral, in every class"
            );
        }
        _warp(30 days);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(
                points.curatorPointsInClass(alice, c),
                _model(c * 1e23, 0, 30 days, 50_000) + _model(c * 1e23, 30 days, 30 days, 50_000),
                "days 30-60 accrue off the checkpoint, in every class"
            );
        }

        // ── `reconcile` must sweep every class too (P-04 repair) ─────────
        // Break the CuratorModule's hook and top every class ABOVE the first up, so each of
        // classes 2..5 carries a dropped transition. Only a full-width reconcile repairs them.
        RevertingPoints brokenHook = new RevertingPoints();
        curator.setPointsModule(address(brokenHook));
        for (uint256 c = 2; c <= Config.NUM_CLASSES; ++c) {
            vm.startPrank(alice);
            usdfr.approve(address(curator), 2e22);
            curator.postFirstLoss(c, 2e22);
            vm.stopPrank();
            assertEq(curator.postedOf(c, alice), c * 1e23 + 2e22, "POST SUCCEEDED through the broken hook");
            assertEq(points.curatorTracked(alice, c), c * 1e23, "but the transition was DROPPED");
        }
        assertEq(points.curatorTracked(alice, 1), 1e23, "class 1 was never desynced");

        curator.setPointsModule(address(points));
        vm.prank(carol);
        points.reconcile(alice);
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(
                points.curatorTracked(alice, c),
                curator.postedOf(c, alice),
                "reconcile repaired EVERY class to its live posted amount"
            );
        }
        assertEq(points.curatorTracked(alice, Config.NUM_CLASSES), 5e23 + 2e22, "including the LAST class in the loop");
        (,, uint256 totalAfter) = points.totals();
        assertEq(totalAfter, posted + 4 * 2e22, "and the tracked curator total reconciles to the sum of the parts");
    }

    /// @notice P-02: `reconcile` repairs an exemption-toggle desync in both directions, and
    ///         never claws back points already earned.
    function test_fork_reconcileRepairsAnExemptionToggleDesync() public onFork {
        assertEq(_mintFromUSDC(bob, 1_000_000e6), 1e24, "position");
        _warp(30 days);
        assertEq(points.pointsOfWallet(bob), USDFR_1E24_30D, "30 days earned as a normal participant");

        compliance.setProtocolExempt(bob, true);
        (, uint256 stale) = points.trackedBalances(bob);
        assertEq(stale, 1e24, "the ledger does not notice the toggle on its own (that is the desync)");

        points.reconcile(bob);
        (, uint256 zeroed) = points.trackedBalances(bob);
        assertEq(zeroed, 0, "reconcile zeroes an exempt wallet's position");
        (, uint256 totalUsdfr,) = points.totals();
        assertEq(totalUsdfr, 0, "and removes it from the tracked total");
        assertEq(points.pointsOfWallet(bob), USDFR_1E24_30D, "already-earned points are NOT clawed back");

        _warp(30 days);
        assertEq(points.pointsOfWallet(bob), USDFR_1E24_30D, "no further accrual while exempt");

        compliance.setProtocolExempt(bob, false);
        points.reconcile(bob);
        (, uint256 restored) = points.trackedBalances(bob);
        assertEq(restored, usdfr.balanceOf(bob), "reconcile restores the live balance");
        (, uint256 totalAgain,) = points.totals();
        assertEq(totalAgain, 1e24, "and the tracked total with it");

        _warp(30 days);
        assertEq(
            points.pointsOfWallet(bob),
            USDFR_1E24_30D + USDFR_1E24_30D,
            "accrual resumes with a FRESH ramp (re-entry is not rewarded for the exempt gap)"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Hook access control.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The three hooks are callable ONLY by their bound module — otherwise anyone
    ///         could mint themselves an arbitrary points balance.
    function test_fork_hooksAreCallableOnlyByTheirBoundModule() public onFork {
        vm.prank(carol);
        vm.expectRevert(PointsModule.Points_OnlyVault.selector);
        points.onSharesTransfer(address(0), carol, 1e30);

        vm.prank(carol);
        vm.expectRevert(PointsModule.Points_OnlyUSDfr.selector);
        points.onUSDfrTransfer(address(0), carol, 1e24);

        vm.prank(carol);
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorStakeChange(carol, Config.CLASS_FILM_TAX_CREDITS, 1e24);

        vm.prank(carol);
        vm.expectRevert(PointsModule.Points_OnlyCurator.selector);
        points.onCuratorLoss(Config.CLASS_FILM_TAX_CREDITS, 1e24, 0);

        // Even the protocol admin cannot spoof a hook.
        vm.expectRevert(PointsModule.Points_OnlyVault.selector);
        points.onSharesTransfer(address(0), ops, 1e30);

        // Nothing accrued to anyone as a result.
        assertEq(points.pointsOfWallet(carol), 0, "carol minted herself nothing");

        // The curator binding is one-time and non-zero.
        assertEq(points.curatorModule(), address(curator), "bound to the deployed CuratorModule");
        vm.expectRevert(PointsModule.Points_ZeroAddress.selector);
        points.setCuratorModule(address(0));
        vm.expectRevert(PointsModule.Points_CuratorModuleAlreadySet.selector);
        points.setCuratorModule(address(this));
        assertEq(points.curatorModule(), address(curator), "still bound to the real module");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. Governance setters: bounded, role-gated, non-retroactive.
    // ─────────────────────────────────────────────────────────────────────

    /// @notice `setRate` / `setUSDfrMultiplier` / `setCuratorMultiplier` are bounded at both
    ///         ends and reachable only by DEFAULT_ADMIN. A rejected call appends no epoch.
    function test_fork_governanceSettersAreBoundedAndRoleGated() public onFork {
        uint256 epochs0 = points.rateEpochCount();
        assertEq(epochs0, 1, "genesis epoch only");

        // ── bounds: rate ────────────────────────────────────────────────
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadRate.selector, MAX_RATE + 1));
        points.setRate(MAX_RATE + 1);
        assertEq(points.rateEpochCount(), epochs0, "a rejected setRate appends no epoch");

        points.setRate(MAX_RATE);
        assertEq(points.ratePerUnitDay(), MAX_RATE, "the ceiling itself is accepted");
        assertEq(points.rateEpochCount(), epochs0 + 1, "one epoch appended");

        points.setRate(0); // zero is legal: it PAUSES accrual without rewriting history
        assertEq(points.ratePerUnitDay(), 0, "rate 0 is an accepted, accrual-halting setting");
        assertEq(points.rateEpochCount(), epochs0 + 2, "and still appends an epoch");

        // ── bounds: multipliers (0 and >20x both rejected) ──────────────
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(0)));
        points.setUSDfrMultiplier(0);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, MAX_MULT_BPS + 1));
        points.setUSDfrMultiplier(MAX_MULT_BPS + 1);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, uint32(0)));
        points.setCuratorMultiplier(0);
        vm.expectRevert(abi.encodeWithSelector(PointsModule.Points_BadMultiplier.selector, MAX_MULT_BPS + 1));
        points.setCuratorMultiplier(MAX_MULT_BPS + 1);
        assertEq(points.rateEpochCount(), epochs0 + 2, "four rejected calls appended nothing");

        points.setUSDfrMultiplier(MAX_MULT_BPS);
        assertEq(points.usdfrMultiplierBps(), MAX_MULT_BPS, "20x ceiling accepted");
        points.setCuratorMultiplier(MAX_MULT_BPS);
        assertEq(points.curatorMultiplierBps(), MAX_MULT_BPS, "20x ceiling accepted");
        assertEq(points.rateEpochCount(), epochs0 + 4, "two more epochs");

        // Each setter carries the others forward unchanged.
        points.setRate(2e18);
        assertEq(points.usdfrMultiplierBps(), MAX_MULT_BPS, "setRate preserved the USDfr multiplier");
        assertEq(points.curatorMultiplierBps(), MAX_MULT_BPS, "setRate preserved the curator multiplier");
        points.setUSDfrMultiplier(30_000);
        assertEq(points.ratePerUnitDay(), 2e18, "setUSDfrMultiplier preserved the rate");
        assertEq(points.curatorMultiplierBps(), MAX_MULT_BPS, "and the curator multiplier");

        // ── role gating ─────────────────────────────────────────────────
        uint256 epochsNow = points.rateEpochCount();
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0));
        vm.prank(carol);
        vm.expectRevert(denied);
        points.setRate(1);
        vm.prank(carol);
        vm.expectRevert(denied);
        points.setUSDfrMultiplier(10_000);
        vm.prank(carol);
        vm.expectRevert(denied);
        points.setCuratorMultiplier(10_000);
        vm.prank(carol);
        vm.expectRevert(denied);
        points.setCuratorModule(address(this));
        assertEq(points.rateEpochCount(), epochsNow, "an unauthorized caller appended nothing");

        // A KYC'd, funded participant is equally powerless.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        points.setRate(1);
    }

    /// @notice P-03: a rate change is NON-RETROACTIVE. Elapsed time keeps the rate that was
    ///         live while it elapsed, even though the holder never checkpointed.
    function test_fork_rateChangeIsNonRetroactive() public onFork {
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "position opened under the genesis epoch");

        _warp(10 days);
        assertEq(points.pointsOfWallet(alice), NONRETRO_EPOCH0, "10 days at the genesis rate");

        points.setRate(2e18); // deliberately WITHOUT checkpointing alice first
        assertEq(points.rateEpochCount(), 2, "a new epoch, not an in-place edit");
        assertEq(points.pointsOfWallet(alice), NONRETRO_EPOCH0, "the doubled rate did NOT reprice the elapsed 10 days");

        _warp(10 days);
        assertEq(
            points.pointsOfWallet(alice),
            NONRETRO_EPOCH0 + NONRETRO_EPOCH1,
            "days 0-10 priced at 1x, days 10-20 at 2x, integrated per epoch"
        );
        assertLt(points.pointsOfWallet(alice), RETROACTIVE_WOULD_BE, "and strictly less than a retroactive repricing");

        // A cut is equally non-retroactive: it cannot claw back what was already earned.
        uint256 banked = points.pointsOfWallet(alice);
        points.setRate(0);
        assertEq(points.pointsOfWallet(alice), banked, "a rate cut to zero claws nothing back");
        _warp(30 days);
        assertEq(points.pointsOfWallet(alice), banked, "and halts further accrual exactly");

        // Restoring the rate resumes accrual from the halt, without back-paying the gap.
        points.setRate(1e18);
        _warp(1 days);
        assertGt(points.pointsOfWallet(alice), banked, "accrual resumed");
        // Day 51 of a 1e24 position, ramp age 51 days, rate 1e18, 3x.
        uint256 resumed = points.pointsOfWallet(alice) - banked;
        assertEq(resumed, _pointsForOneDayAt(50 days), "exactly one day at the day-50 ramp, no back-pay");
    }

    /// @notice A multiplier change is likewise non-retroactive, per stream: raising the
    ///         curator multiple does not reprice first-loss time already served.
    function test_fork_curatorMultiplierChangeIsNonRetroactive() public onFork {
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, alice, true);
        assertEq(_mintFromUSDC(alice, 1_000_000e6), 1e24, "funds");
        vm.startPrank(alice);
        usdfr.approve(address(curator), 1e23);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1e23);
        vm.stopPrank();

        _warp(30 days);
        uint256 atThirty = points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS);
        assertEq(atThirty, CURATOR_1E23_30D, "30 days at 5x");

        points.setCuratorMultiplier(100_000); // 10x, going forward only
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            atThirty,
            "doubling the curator multiple did NOT reprice the served 30 days"
        );

        _warp(30 days);
        assertEq(
            points.curatorPointsInClass(alice, Config.CLASS_FILM_TAX_CREDITS),
            atThirty + CURATOR_1E23_30D_60D_AT_10X,
            "days 30-60 priced at the NEW 10x multiple, days 0-30 still at 5x"
        );
        // Sanity on the independent figures: the same window at 5x on half the balance,
        // scaled 2x for balance and 2x for the multiple, is the same number.
        assertEq(CURATOR_1E23_30D_60D_AT_10X, 4 * CURATOR_5E22_30D_60D, "linear in balance and in multiplier");
    }
}
