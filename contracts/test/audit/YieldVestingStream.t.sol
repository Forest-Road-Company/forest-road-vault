// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {SUSDfr} from "../../src/sUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title ADR-0023 — optional streamed senior-yield vesting
/// @notice Launch recognizes realized senior yield immediately. These tests explicitly
///         enable a seven-day window and retain assurance for the governance option to
///         smooth already-realized yield later. Nothing forward-looking is credited, so
///         ADR-0002 variable-yield pass-through is untouched.
///
///         Streaming can smooth asset-denominated rate jumps and reduce payment-timing
///         games in liquid secondary markets. It is not a Pendle protocol prerequisite.
contract YieldVestingStreamTest is CreditLayerFixture {
    uint64 internal constant OPTIONAL_STREAM_PERIOD = 7 days;

    uint64 internal launchPeriod;

    event YieldVestingPeriodSet(uint64 period);

    function setUp() public override {
        super.setUp();
        launchPeriod = vault.yieldVestingPeriod();
        vm.prank(admin);
        vault.setYieldVestingPeriod(OPTIONAL_STREAM_PERIOD);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Distributes `interest` on a live facility, with the stables actually arriving in
    ///      the treasury (else the backing guard rejects the yield mint). Returns the amount
    ///      that reached the senior vault.
    function _distributeInterest(uint256 id, uint256 interest) internal returns (uint256 toVault) {
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        _repay(id, interest, 0);
        toVault = usdfr.balanceOf(address(vault)) - heldBefore;
    }

    // ── configuration ────────────────────────────────────────────────────

    function test_launchUsesInstantRecognitionAndOptionalStreamCanBeEnabled() public view {
        assertEq(launchPeriod, Config.DEFAULT_YIELD_VESTING_PERIOD);
        assertEq(launchPeriod, 0, "launch recognizes yield immediately");
        assertEq(vault.yieldVestingPeriod(), OPTIONAL_STREAM_PERIOD, "test explicitly enabled optional streaming");
        assertEq(vault.unvestedYield(), 0, "nothing vesting before any distribution");
    }

    function test_setYieldVestingPeriod_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vault.setYieldVestingPeriod(1 days);
    }

    function test_setYieldVestingPeriod_rejectsAboveCap() public {
        uint64 tooLong = Config.MAX_YIELD_VESTING_PERIOD + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_VestingPeriodTooLong.selector, tooLong));
        vault.setYieldVestingPeriod(tooLong);
    }

    function test_setYieldVestingPeriod_acceptsCapAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldVestingPeriodSet(Config.MAX_YIELD_VESTING_PERIOD);
        vm.prank(admin);
        vault.setYieldVestingPeriod(Config.MAX_YIELD_VESTING_PERIOD);
        assertEq(vault.yieldVestingPeriod(), Config.MAX_YIELD_VESTING_PERIOD, "boundary accepted");
    }

    function test_notifyYield_onlyCreditRole() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.CREDIT_ROLE)
        );
        vault.notifyYield(1e18);
    }

    // ── the core property: no step, then linear release ──────────────────

    function test_yieldDoesNotStepTheRateAtDistribution() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);

        uint256 rateBefore = vault.currentExchangeRate();
        uint256 assetsBefore = vault.totalAssets();

        uint256 toVault = _distributeInterest(id, 50_000e18);
        assertGt(toVault, 0, "yield reached the vault");

        // the USDfr is physically there, but not yet credited to the rate
        assertEq(vault.unvestedYield(), toVault, "the whole distribution is vesting");
        assertEq(vault.totalAssets(), assetsBefore, "NO STEP: totalAssets unchanged at the instant");
        assertEq(vault.currentExchangeRate(), rateBefore, "NO STEP: the rate does not jump");
    }

    function test_yieldVestsLinearlyAndCompletes() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 assetsBefore = vault.totalAssets();
        uint256 toVault = _distributeInterest(id, 50_000e18);
        uint64 period = vault.yieldVestingPeriod();

        vm.warp(block.timestamp + period / 2);
        assertApproxEqAbs(vault.unvestedYield(), toVault / 2, 1e6, "half vested at the midpoint");
        assertApproxEqAbs(vault.totalAssets(), assetsBefore + toVault / 2, 1e6, "rate has climbed halfway");

        vm.warp(block.timestamp + period / 2);
        assertEq(vault.unvestedYield(), 0, "fully vested at the end of the window");
        assertEq(vault.totalAssets(), assetsBefore + toVault, "all realized yield is credited");
    }

    function test_rolloverKeepsUnvestedRemainderOfThePriorStream() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 assetsAtStart = vault.totalAssets();
        uint256 first = _distributeInterest(id, 50_000e18);
        uint64 period = vault.yieldVestingPeriod();

        vm.warp(block.timestamp + period / 2);
        uint256 pending = vault.unvestedYield();
        assertGt(pending, 0, "mid-stream");

        uint256 assetsBefore = vault.totalAssets();
        uint256 second = _distributeInterest(id, 30_000e18);

        // continuity across the second distribution, and the remainder is not dropped
        assertEq(vault.totalAssets(), assetsBefore, "NO STEP on the second distribution either");
        assertEq(vault.unvestedYield(), pending + second, "prior remainder rolled into the new stream");
        (uint256 streamTotal,) = vault.vestingSchedule();
        assertEq(streamTotal, pending + second, "stream total is remainder plus the new amount");

        // and it all still lands eventually — no realized yield is ever stranded
        vm.warp(block.timestamp + period);
        assertEq(vault.unvestedYield(), 0, "fully vested");
        assertEq(vault.totalAssets(), assetsBefore + pending + second, "every unit of yield credited");
        // CONSERVATION across the whole episode. (The previous line here compared
        // `first + second` with `(first - pending) + pending + second` — an algebraic identity
        // that asserted nothing; replaced during the H-3 remediation pass.)
        assertEq(vault.totalAssets(), assetsAtStart + first + second, "both streams, in full, and no more");
        assertEq(usdfr.balanceOf(address(vault)), assetsAtStart + first + second, "no USDfr left uncredited");
    }

    function test_zeroPeriodCreditsInstantly() public {
        vm.prank(admin);
        vault.setYieldVestingPeriod(0);
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 toVault = _distributeInterest(id, 50_000e18);

        assertEq(vault.unvestedYield(), 0, "no vesting");
        assertEq(vault.totalAssets(), assetsBefore + toVault, "zero period recognizes the receipt immediately");
    }

    // ── the safety bound that makes streaming compatible with the cascade ──

    /// @dev THE LOAD-BEARING TEST. `realizeLoss`'s layer-3 burn is bounded by the vault's
    ///      VESTED assets, not its raw balance. Without that bound a loss could burn into
    ///      the unvested stream, leaving `unvestedYield() > balance` and pinning
    ///      `totalAssets()` at zero for the rest of the window — a §1.3 monotonicity break
    ///      far larger than the loss itself and invalid for any downstream rate consumer.
    function test_lossCannotBurnIntoTheUnvestedStream() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        _distributeInterest(id, 50_000e18);

        uint256 held = usdfr.balanceOf(address(vault));
        uint256 vested = vault.totalAssets();
        uint256 unvested = vault.unvestedYield();
        assertGt(unvested, 0, "there is a live stream to protect");
        assertEq(held, vested + unvested, "balance splits exactly into vested plus unvested");

        // a loss larger than VESTED assets but smaller than the raw balance must be refused
        uint256 tooBig = vested + 1;
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _attestLoss(id, tooBig, FILM_REF);
        vm.prank(servicer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDefaultManagerErrors.DefaultManager_LossExceedsAbsorptionCapacity.selector, id, tooBig, vested
            )
        );
        defaultManager.realizeLoss(id, tooBig, FILM_REF);

        // the stream is intact and totalAssets never collapsed
        assertEq(vault.unvestedYield(), unvested, "stream untouched");
        assertGt(vault.totalAssets(), 0, "totalAssets did not collapse to zero");
    }

    function test_lossUpToVestedAssetsStillWorksAndLeavesTheStreamIntact() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        _distributeInterest(id, 50_000e18);

        uint256 vested = vault.totalAssets();
        uint256 unvested = vault.unvestedYield();
        uint256 loss = vested / 4;

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(id, loss, FILM_REF);

        assertEq(vault.unvestedYield(), unvested, "the unvested stream is not consumed by the loss");
        assertEq(vault.totalAssets(), vested - loss, "the loss lands entirely on credited principal");
        assertGe(usdfr.balanceOf(address(vault)), vault.unvestedYield(), "balance still covers the stream");
    }

    // ── fuzz ─────────────────────────────────────────────────────────────

    /// @dev The clamp in `totalAssets()` must be unreachable: the vault balance must always
    ///      cover the unvested stream, at every point in a stream's life.
    ///
    ///      H-3 REMEDIATION: `newPeriod` is now fuzzed and applied MID-STREAM. Without that
    ///      parameter this test stayed green straight through H-3 — a governance re-tune was
    ///      exactly the input that pushed `unvestedYield()` back above the balance — so it was
    ///      backstopping the "clamp is unreachable" claim without ever exercising the writer
    ///      that broke it. The strict `totalAssets() > 0` is the inflation-mint guard's
    ///      precondition: a vault holding USDfr must never report zero assets from vesting alone.
    function testFuzz_balanceAlwaysCoversTheUnvestedStream(uint256 interest, uint256 elapsed, uint64 newPeriod)
        public
    {
        interest = bound(interest, 1e18, 200_000e18) / 1e12 * 1e12;
        elapsed = bound(elapsed, 0, 60 days);
        newPeriod = uint64(bound(newPeriod, 0, Config.MAX_YIELD_VESTING_PERIOD));

        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        _distributeInterest(id, interest);

        // re-tune part-way through, then run out the rest of the clock
        vm.warp(block.timestamp + elapsed / 2);
        vm.prank(admin);
        vault.setYieldVestingPeriod(newPeriod);
        vm.warp(block.timestamp + elapsed - elapsed / 2);

        assertGe(usdfr.balanceOf(address(vault)), vault.unvestedYield(), "balance covers the stream");
        assertEq(
            vault.totalAssets(),
            usdfr.balanceOf(address(vault)) - vault.unvestedYield(),
            "totalAssets is exactly the vested portion - the clamp never fires"
        );
        assertGt(vault.totalAssets(), 0, "a vault holding USDfr must never report zero assets");
    }

    /// @dev While optional streaming is enabled, the rate must climb monotonically through
    ///      a stream — never dip or jump downward.
    ///
    ///      H-3 REMEDIATION: a fuzzed governance re-tune now lands MID-STREAM. This is the fuzz
    ///      that actually catches H-3 — the pre-fix setter re-priced the live stream against a
    ///      stale `vestingAmount`/`lastYieldAt`, so lengthening the window dropped the rate in a
    ///      single transaction with no loss and no cascade. Nothing in the suite fuzzed a
    ///      timelocked setter, which is why the finding survived. (Note: fuzzing the period into
    ///      `testFuzz_balanceAlwaysCoversTheUnvestedStream` does NOT catch it — the stake there
    ///      dwarfs the stream, so `held > unvested` survives any re-pricing. The rate, not the
    ///      clamp, is where H-3 shows.)
    function testFuzz_exchangeRateIsMonotonicThroughAStream(uint256 interest, uint256 step, uint64 newPeriod) public {
        interest = bound(interest, 1e18, 200_000e18) / 1e12 * 1e12;
        step = bound(step, 1 hours, 2 days);
        newPeriod = uint64(bound(newPeriod, 0, Config.MAX_YIELD_VESTING_PERIOD));

        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 rate = vault.currentExchangeRate();
        _distributeInterest(id, interest);
        assertEq(vault.currentExchangeRate(), rate, "no jump at the distribution instant");

        for (uint256 i = 0; i < 8; ++i) {
            vm.warp(block.timestamp + step);
            if (i == 3) {
                // the governance re-tune, mid-stream, in its own block
                vm.prank(admin);
                vault.setYieldVestingPeriod(newPeriod);
                assertGe(vault.currentExchangeRate(), rate, "RATE FELL ACROSS A GOVERNANCE RE-TUNE");
            }
            uint256 next = vault.currentExchangeRate();
            assertGe(next, rate, "RATE FELL DURING A STREAM");
            rate = next;
        }
    }
}

/// @dev Local re-declaration so the test can reference the manager's custom error selector
///      without importing the whole module surface.
interface IDefaultManagerErrors {
    error DefaultManager_LossExceedsAbsorptionCapacity(uint256 tokenId, uint256 loss, uint256 capacity);
}
