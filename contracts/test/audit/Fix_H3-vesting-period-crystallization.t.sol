// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SUSDfr} from "../../src/sUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title AUDIT H-3 — `setYieldVestingPeriod` must not re-price already-vested yield
/// @notice `unvestedYield()` reads the LIVE `yieldVestingPeriod` against the STORED
///         `vestingAmount`/`lastYieldAt`. Writing a new period without first crystallizing the
///         pending remainder therefore RE-PRICES the stream:
///         - lengthening resurrects yield that has already vested (a completed stream is the
///           maximal case, since `vestingAmount` is never zeroed on completion, only overwritten),
///           dropping `totalAssets()` and the exchange rate in one transaction with no realized
///           loss and no cascade — a CLAUDE.md §1.3 monotonicity break — short-changing any
///           queued senior settling next block and handing a fresh depositor a permissionless
///           dilution mint that re-lowering the period cannot un-mint;
///         - shortening is the mirror: it steps the rate UP and lets a depositor who is already
///           in capture the instant release of a stream funded before they arrived.
///
///         The fix crystallizes `unvestedYield()` (computed against the OLD period) into
///         `vestingAmount` and restarts `lastYieldAt` BEFORE writing the new period, so the
///         instantaneous rate is unchanged across the setter in BOTH directions, mid-stream and
///         after completion. These tests pin all four combinations plus both extraction legs.
///
///         REMEDIATION PASS (three-reviewer NEEDS-WORK): the dilution assertion in
///         `test_depositorCannotExtractValueByEnteringAfterAPeriodChange` was written BACKWARDS
///         and passed under the very bug it named; it now asserts the incumbent is not diluted.
///         The shortening leg was vacuous (pre-fix `unvestedYield()` had already collapsed to
///         zero before the depositor arrived, so there was nothing to capture) and is rebuilt as
///         the real front-run. The emissions the fix adds are now asserted. And the reachable
///         `totalAssets() == 0` inflation-mint state — which the wave-1 report wrongly declared
///         closed — is pinned and closed here.
contract FixH3VestingPeriodCrystallizationTest is CreditLayerFixture {
    uint64 internal constant SHORT_PERIOD = 1 days;
    uint64 internal constant OPTIONAL_STREAM_PERIOD = 7 days;
    uint64 internal constant LONG_PERIOD = 30 days;

    event YieldStreamStarted(uint256 added, uint256 streamTotal, uint64 period);
    event YieldVestingPeriodSet(uint64 period);

    function setUp() public override {
        super.setUp();
        assertEq(vault.yieldVestingPeriod(), 0, "launch policy is instant recognition");
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

    /// @dev Distributes `interest` on a live facility with the stables actually arriving
    ///      (ADR-0025 reconcile), so the backing guard admits the yield mint. Returns the
    ///      amount that physically reached the vault — the true stream size, delta-measured.
    function _distributeInterest(uint256 id, uint256 interest) internal returns (uint256 toVault) {
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        _repay(id, interest, 0);
        toVault = usdfr.balanceOf(address(vault)) - heldBefore;
    }

    /// @dev Stakes, opens a facility and starts the explicitly enabled 7-day stream.
    /// @return id The facility id.
    /// @return stream The stream size that reached the vault.
    function _startStream() internal returns (uint256 id, uint256 stream) {
        _stakeVault(alice, 400_000e18);
        id = _liveFilmFacility(500_000e18);
        stream = _distributeInterest(id, 50_000e18);
        assertGt(vault.unvestedYield(), 0, "a stream is live");
        assertEq(vault.unvestedYield(), stream, "the whole distribution is vesting at t0");
    }

    /// @dev The core assertion: the setter is continuity-preserving. Nothing about the vault's
    ///      instantaneous valuation may move across a governance re-tune — AND the state
    ///      transition must be fully reconstructable from events (CLAUDE.md §1.1, §3.1), which
    ///      is the fix's own justification for emitting the re-base.
    function _assertRateUnchangedAcross(uint64 newPeriod, string memory label) internal {
        uint256 assetsBefore = vault.totalAssets();
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 unvestedBefore = vault.unvestedYield();
        uint256 redemptionBefore = vault.redemptionTotalAssets();

        // the crystallized stream is re-based to `unvestedBefore`, starting now, under `newPeriod`
        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldStreamStarted(0, unvestedBefore, newPeriod);
        vm.expectEmit(false, false, false, true, address(vault));
        emit YieldVestingPeriodSet(newPeriod);
        vm.prank(admin);
        vault.setYieldVestingPeriod(newPeriod);

        assertEq(vault.unvestedYield(), unvestedBefore, string.concat(label, ": unvested re-priced"));
        assertEq(vault.totalAssets(), assetsBefore, string.concat(label, ": totalAssets moved"));
        assertEq(vault.currentExchangeRate(), rateBefore, string.concat(label, ": EXCHANGE RATE MOVED"));
        assertEq(vault.redemptionTotalAssets(), redemptionBefore, string.concat(label, ": queued senior re-priced"));
        assertEq(vault.yieldVestingPeriod(), newPeriod, string.concat(label, ": period not applied"));
        // the re-based stream is exactly the crystallized remainder, starting from now
        (uint256 amount, uint64 startedAt) = vault.vestingSchedule();
        assertEq(amount, unvestedBefore, string.concat(label, ": stream not crystallized to the remainder"));
        assertEq(startedAt, uint64(block.timestamp), string.concat(label, ": clock not restarted"));
    }

    // ── the four combinations ────────────────────────────────────────────

    function test_lengthenMidStreamDoesNotMoveTheRate() public {
        (, uint256 stream) = _startStream();
        vm.warp(block.timestamp + 3 days); // mid-stream on the optional 7-day test window

        // ABSOLUTE magnitude, not merely before/after equality: 3 of 7 days elapsed, so 4/7 left
        assertEq(vault.unvestedYield(), stream * 4 / 7, "4/7 of the stream is still unvested");

        _assertRateUnchangedAcross(LONG_PERIOD, "lengthen/mid-stream");

        // CONSERVATION past the NEW window: everything vests, nothing is stranded or created
        uint256 heldNow = usdfr.balanceOf(address(vault));
        vm.warp(block.timestamp + uint256(LONG_PERIOD) + 1);
        assertEq(vault.unvestedYield(), 0, "the re-based stream fully vests under the new window");
        assertEq(vault.totalAssets(), heldNow, "every unit of held USDfr is credited, and no more");
    }

    function test_shortenMidStreamDoesNotMoveTheRate() public {
        (, uint256 stream) = _startStream();
        vm.warp(block.timestamp + 3 days);
        assertEq(vault.unvestedYield(), stream * 4 / 7, "4/7 of the stream is still unvested");

        _assertRateUnchangedAcross(SHORT_PERIOD, "shorten/mid-stream");

        uint256 heldNow = usdfr.balanceOf(address(vault));
        vm.warp(block.timestamp + uint256(SHORT_PERIOD) + 1);
        assertEq(vault.unvestedYield(), 0, "the re-based stream fully vests under the new window");
        assertEq(vault.totalAssets(), heldNow, "every unit of held USDfr is credited, and no more");
    }

    /// @dev THE MAXIMAL CASE. The stream has run to completion, so `unvestedYield()` is 0 — but
    ///      `vestingAmount` still holds the full stream size, so a longer window resurrects it.
    function test_lengthenAfterCompletionDoesNotMoveTheRate() public {
        _startStream();
        vm.warp(block.timestamp + uint256(vault.yieldVestingPeriod()) + 1 days);
        assertEq(vault.unvestedYield(), 0, "stream completed");

        _assertRateUnchangedAcross(LONG_PERIOD, "lengthen/completed");

        // and the completed stream is RETIRED, not merely re-based
        (uint256 amount,) = vault.vestingSchedule();
        assertEq(amount, 0, "a completed stream must be retired, not carried forward");
        assertEq(vault.unvestedYield(), 0, "nothing can be resurrected later either");
        vm.warp(block.timestamp + 15 days);
        assertEq(vault.unvestedYield(), 0, "still nothing mid-way through the new window");
    }

    function test_shortenAfterCompletionDoesNotMoveTheRate() public {
        _startStream();
        vm.warp(block.timestamp + uint256(vault.yieldVestingPeriod()) + 1 days);
        _assertRateUnchangedAcross(SHORT_PERIOD, "shorten/completed");
    }

    // ── the extraction leg ───────────────────────────────────────────────

    /// @dev The harm is not the rate wobble itself but that the mint at the depressed rate is
    ///      PERMISSIONLESS: anyone watching the public timelock queue deposits in the next block
    ///      and takes value straight from the existing staker, irreversibly.
    ///
    ///      REMEDIATION: the incumbent-dilution assertion below previously read
    ///      `assertGe(aliceValueBefore, aliceAfter * 999/1000)` — an UPPER bound on the
    ///      incumbent, which is satisfied precisely WHEN alice is diluted. It passed under the
    ///      bug (measured pre-fix: alice 427,499.99e18 -> 420,858.94e18, a 1.55% transfer to
    ///      bob) and so proved nothing. It is now the lower bound the message always claimed.
    function test_depositorCannotExtractValueByEnteringAfterAPeriodChange() public {
        _startStream();
        vm.warp(block.timestamp + uint256(vault.yieldVestingPeriod()) + 1 days);

        uint256 aliceValueBefore = vault.convertToAssets(vault.balanceOf(alice));

        vm.prank(admin);
        vault.setYieldVestingPeriod(LONG_PERIOD);

        uint256 stake = 200_000e18;
        _stakeVault(bob, stake);

        // Sanity only: ERC-4626 deposit rounding puts a fresh depositor at or a wei below par at
        // the instant of entry for ANY implementation, buggy or not. The extraction this test
        // exists for materializes as the re-priced stream vests, asserted after the warp below.
        assertLe(vault.convertToAssets(vault.balanceOf(bob)), stake, "entry rounding favours the vault");

        vm.warp(block.timestamp + 60 days); // everything vested

        // THE FINDING: the incumbent must not have been diluted by the re-tune.
        assertGe(
            vault.convertToAssets(vault.balanceOf(alice)),
            aliceValueBefore * 999 / 1000,
            "the incumbent staker was diluted"
        );
        // and the mirror: the entrant must not have captured stream value that pre-dates him
        assertLe(
            vault.convertToAssets(vault.balanceOf(bob)),
            stake * 1001 / 1000,
            "depositor captured stream value that accrued before entry"
        );
    }

    /// @dev The mirror direction, rebuilt (the previous version was VACUOUS: pre-fix the
    ///      shortening had already collapsed `unvestedYield()` to zero before the depositor
    ///      arrived, so `unvestedAtEntry == 0` and the bound degenerated to `stake + 1` — it
    ///      could not fail in the direction of the bug at any stream size).
    ///
    ///      The real shortening exploit is on the other side of the trade: be IN before the
    ///      publicly queued timelock execution lands, and be handed the accelerated release.
    ///      Pre-fix, shortening mid-stream re-prices `unvestedYield()` downward instantly, so a
    ///      holder's `convertToAssets` jumps within the very same block. It must not move.
    function test_holderCannotBeHandedTheStreamByFrontRunningAShortening() public {
        _startStream();
        vm.warp(block.timestamp + 1 days);

        // bob front-runs the queued re-tune: he is already in when it executes
        uint256 stake = 200_000e18;
        _stakeVault(bob, stake);
        uint256 bobBefore = vault.convertToAssets(vault.balanceOf(bob));
        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));
        uint256 unvestedAtEntry = vault.unvestedYield();
        assertGt(unvestedAtEntry, 0, "there is a live stream for the shortening to accelerate");

        vm.prank(admin);
        vault.setYieldVestingPeriod(SHORT_PERIOD);

        // the acceleration must not be handed to him in the same block
        assertEq(vault.convertToAssets(vault.balanceOf(bob)), bobBefore, "front-runner was handed the stream");
        assertEq(vault.convertToAssets(vault.balanceOf(alice)), aliceBefore, "incumbent was re-priced");

        // over the shortened window he earns his pro-rata slice of the remainder and no more.
        // The bound uses alice's ACTUAL entry value rather than her nominal 400,000e18 stake, so
        // the slack is one wei rather than the ~51e18 the nominal denominator allowed.
        vm.warp(block.timestamp + uint256(SHORT_PERIOD) + 1);
        assertEq(vault.unvestedYield(), 0, "the shortened window has elapsed");
        assertLe(
            vault.convertToAssets(vault.balanceOf(bob)),
            bobBefore + unvestedAtEntry * bobBefore / (bobBefore + aliceBefore) + 1,
            "captured more than his pro-rata slice of the remainder"
        );
        // and he really did earn that slice — the bound above is not passing by starvation
        assertGt(vault.convertToAssets(vault.balanceOf(bob)), bobBefore, "no slice of the stream at all");
    }

    // ── the reachable `totalAssets() == 0` inflation-mint state ──────────

    /// @dev AUDIT H-3 REMEDIATION, and the item the wave-1 report wrongly reported closed.
    ///      `DefaultManager.realizeLoss` bounds the layer-3 senior burn with a STRICT `<`, so a
    ///      maximal but entirely legal `depositorLoss == totalAssets()` writes the vested layer
    ///      down to exactly nothing. `totalAssets()` reports zero at EQUALITY of held and
    ///      unvested, not only below it — so the vault ends with shares outstanding, zero
    ///      reported assets, and the whole unvested stream still physically held.
    ///
    ///      In that state `previewDeposit(1e18)` mints on the order of 10^18x the entire share
    ///      supply, and a 1-USDfr depositor takes the stranded stream. The virtual-share offset
    ///      does not help: it scales the share side, not the asset side. Entry must FAIL LOUDLY.
    function test_maximalLossWipesTheVaultAndClosesEntry() public {
        (uint256 id,) = _startStream();

        uint256 vested = vault.totalAssets();
        uint256 unvested = vault.unvestedYield();
        assertGt(unvested, 0, "there is a live stream to strand");

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        // the exact boundary: `depositorLoss == vaultAssets` is PERMITTED (strict `<` check)
        vm.prank(servicer);
        _realizeLoss(id, vested, FILM_REF);

        // the wiped state, measured
        assertEq(vault.totalAssets(), 0, "the senior layer is written down to nothing");
        assertGt(vault.totalSupply(), 0, "but shares are still outstanding");
        assertEq(usdfr.balanceOf(address(vault)), unvested, "and real USDfr is still held");
        assertEq(vault.unvestedYield(), unvested, "the stream survived the burn, as the bound intends");

        // THE HAZARD THIS CLOSES: pricing is degenerate here. Pinned so the magnitude is on the
        // record and a future change that "fixes" the price silently is caught.
        assertGt(vault.previewDeposit(1e18), vault.totalSupply(), "a 1-USDfr deposit out-mints the vault");

        // ENTRY IS CLOSED, LOUDLY (prime directive 4) — governance must resolve the wipe. This is
        // the ZERO-base point, the LIMIT of the stranded-stream band, so the `_isDegenerate`
        // `assets == 0` clause fires and the error reports a zero deposit base.
        uint256 supply = vault.totalSupply();
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, uint256(0)));
        vault.deposit(1e18, bob);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, uint256(0)));
        vault.mint(1e18, bob);
        vm.stopPrank();

        // and the ERC-4626 capacity views agree, so routers do not build a doomed deposit
        assertEq(vault.maxDeposit(bob), 0, "wiped vault must advertise zero deposit capacity");
        assertEq(vault.maxMint(bob), 0, "wiped vault must advertise zero mint capacity");

        // exits are deliberately NOT blocked: a wiped vault must still be able to settle its
        // queue, and at zero assets those exits correctly pay zero
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), 0, "exit stays open and pays zero");
    }

    function _depositReturningShares(address who, uint256 amount) internal returns (uint256) {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, who);
        vm.stopPrank();
        return shares;
    }

    /// @dev BYPASS (b): `realizeLoss(id, vested - 1)` leaves `totalAssets() == 1 wei` against the
    ///      full share supply. NOT zero, so a shares-per-asset guard reopens once its ratio falls,
    ///      yet the whole unvested stream is still stranded, so `previewDeposit(1e18)` mints
    ///      ~10^18x the supply. Entry must be REFUSED with the specific error and the incumbent must
    ///      not be diluted. (Base pinned this state as OPEN, which was the wave-2 bypass.)
    function test_strandedStreamBandClosesEntry_oneWeiSurvives() public {
        (uint256 id,) = _startStream();
        uint256 vested = vault.totalAssets();

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(id, vested - 1, FILM_REF);

        assertEq(vault.totalAssets(), 1, "one wei of vested principal survives (non-zero)");
        assertGt(
            vault.unvestedYield(),
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * vault.totalAssets(),
            "stranded stream past the guard multiple of the deposit base"
        );
        assertGt(vault.previewDeposit(1e18), vault.totalSupply(), "a 1-USDfr deposit out-mints the vault");

        uint256 supply = vault.totalSupply();
        uint256 aliceValueBefore = vault.convertToAssets(vault.balanceOf(alice));

        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, uint256(1)));
        vault.deposit(1e18, bob);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, uint256(1)));
        vault.mint(1e18, bob);
        vm.stopPrank();

        assertEq(vault.maxDeposit(bob), 0, "degenerate vault must advertise zero deposit capacity");
        assertEq(vault.maxMint(bob), 0, "degenerate vault must advertise zero mint capacity");
        assertEq(vault.balanceOf(bob), 0, "no shares minted to the entrant");
        assertEq(
            vault.convertToAssets(vault.balanceOf(alice)), aliceValueBefore, "incumbent diluted by a refused entry"
        );
    }

    /// @dev BYPASS (a): one block AFTER a maximal write-down, a sliver of the stream has vested, so
    ///      `totalAssets()` is a few hundred milli-USDfr. Non-zero, past a zero-point guard, while
    ///      the stranded stream still dominates. Entry must stay REFUSED.
    function test_strandedStreamBandClosesEntry_oneBlockAfterMaximalWriteDown() public {
        (uint256 id,) = _startStream();
        uint256 vested = vault.totalAssets();
        assertGt(vault.unvestedYield(), 0, "there is a live stream that will vest a sliver next block");

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(id, vested, FILM_REF); // maximal: vested base -> 0

        assertEq(vault.totalAssets(), 0, "vested base written to nothing at the instant of the burn");

        vm.warp(block.timestamp + 12); // one block later a sliver has vested
        uint256 tinyBase = vault.totalAssets();
        assertGt(tinyBase, 0, "a sliver of the stream has vested (non-zero base)");
        assertGt(
            vault.unvestedYield(),
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * tinyBase,
            "the stranded stream still exceeds the guard multiple of the base"
        );
        assertGt(vault.previewDeposit(1e18), vault.totalSupply(), "a 1-USDfr deposit still out-mints the vault");

        uint256 supply = vault.totalSupply();
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, tinyBase));
        vault.deposit(1e18, bob);
        vm.stopPrank();
        assertEq(vault.maxDeposit(bob), 0, "still closed one block past the zero point");
    }

    /// @dev THE BAND A SHARES-PER-ASSET GUARD LEAVES OPEN. After a maximal write-down, warp until
    ///      enough stream has vested that shares-per-asset falls BELOW the wave-3 `1e5 * seed`
    ///      collapse threshold (so a reconstruction of that guard REOPENS entry) while the stranded
    ///      stream STILL dwarfs the base (so `_isDegenerate` keeps it CLOSED). Both sides asserted.
    function test_strandedStreamBandClosesEntry_waveThreeGuardWouldReopen() public {
        (uint256 id,) = _startStream();
        uint256 vested = vault.totalAssets();

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(id, vested, FILM_REF); // maximal: base -> 0, whole stream survives
        assertEq(vault.totalAssets(), 0, "base written to nothing");

        vm.warp(block.timestamp + 1 hours); // a modest fraction of the 7-day stream vests
        uint256 base = vault.totalAssets();
        uint256 stranded = vault.unvestedYield();
        assertGt(base, 0, "base has recovered a chunk as the stream vests");

        // (1) reconstruct the wave-3 shares-per-asset guard and SHOW it would REOPEN entry here.
        //     wave-3 closed iff `totalSupply() + offset > 1e5 * offset * (totalAssets() + 1)`
        //     (offset = 10**_decimalsOffset() = 1e6). Here it is false -> wave-3 reopens.
        uint256 supply = vault.totalSupply();
        uint256 offset = 1e6;
        uint256 waveThreeCollapseFloor = 1e5; // wave-3 SUSDFR_MAX_SHARE_PRICE_COLLAPSE
        bool waveThreeClosed = supply + offset > waveThreeCollapseFloor * offset * (base + 1);
        assertFalse(waveThreeClosed, "wave-3 shares-per-asset guard REOPENS this band (the bug we close)");

        // (2) but the stranded stream still dwarfs the base, so `_isDegenerate` keeps entry CLOSED
        assertGt(stranded, Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * base, "stream still >> base: mine closes");

        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, base));
        vault.deposit(1e18, bob);
        vm.stopPrank();
        assertEq(vault.maxDeposit(bob), 0, "band vault must advertise zero deposit capacity");
        assertEq(vault.maxMint(bob), 0, "band vault must advertise zero mint capacity");
    }

    /// @dev AUDIT FINDING #3 (K 10 -> 3) REGRESSION. The precise band the OLD `K = 10` left OPEN and
    ///      the new `K = 3` shuts. After a maximal write-down strands the whole stream, warp until the
    ///      stranded stream is exactly 5x the recovered base (`unvestedYield()/totalAssets() == 5`, so
    ///      ~83% of the vault balance is still an unvested skim). At that ratio the OLD predicate
    ///      `unvestedYield() > 10 * totalAssets()` is FALSE — the vault would REOPEN entry and admit a
    ///      whale to skim ~83% of the balance as the stream vests — while the shipped `K = 3` predicate
    ///      `unvestedYield() > 3 * totalAssets()` is TRUE, so entry stays REFUSED with the specific
    ///      error and the incumbent is not diluted. The OLD-K reconstruction is asserted inline (same
    ///      pattern as the wave-3 test) and the whole test is SEEN to fail if `K` is reset to 10.
    function test_strandedStreamBandClosesEntry_midBandOldKTenWouldReopen() public {
        (uint256 id,) = _startStream();
        uint256 vested = vault.totalAssets();

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(id, vested, FILM_REF); // maximal: base -> 0, the whole stream survives

        // vest exactly 1/6 of the window: base recovers to U/6, stranded stream is U*5/6, ratio == 5
        uint64 period = vault.yieldVestingPeriod();
        vm.warp(block.timestamp + uint256(period) / 6);

        uint256 base = vault.totalAssets();
        uint256 stranded = vault.unvestedYield();
        assertGt(base, 0, "base has recovered a sixth of the stream (non-zero)");
        // ratio == 5 up to wei-level vesting rounding: firmly inside the (3, 10] band both guards see
        assertGt(stranded, 4 * base, "stranded stream is ~5x the base (above 4x)");
        assertLt(stranded, 6 * base, "stranded stream is ~5x the base (below 6x)");

        // (1) the OLD `K = 10` guard: `unvested > 10 * base` is FALSE at ratio 5 -> it REOPENS entry.
        uint256 oldK = 10;
        assertFalse(stranded > oldK * base, "OLD K=10 REOPENS this band (the skim the fix closes)");

        // (2) the shipped `K = 3` guard closes it: `unvested > 3 * base` is TRUE.
        assertGt(stranded, Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * base, "K=3 closes this band");

        // entry is REFUSED, loudly, with the base carried in the error
        uint256 supply = vault.totalSupply();
        uint256 aliceValueBefore = vault.convertToAssets(vault.balanceOf(alice));
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, base));
        vault.deposit(1e18, bob);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, base));
        vault.mint(1e18, bob);
        vm.stopPrank();

        assertEq(vault.maxDeposit(bob), 0, "mid-band vault must advertise zero deposit capacity");
        assertEq(vault.maxMint(bob), 0, "mid-band vault must advertise zero mint capacity");
        assertEq(vault.balanceOf(bob), 0, "no shares minted to the refused entrant");
        assertEq(
            vault.convertToAssets(vault.balanceOf(alice)), aliceValueBefore, "incumbent diluted by a refused entry"
        );
    }

    // ── positive controls: the guard must NOT strangle normal operation ──

    /// @dev A SURVIVABLE 50% write-down must leave the vault fully OPEN. The haircut halves the base
    ///      but the stranded stream is a small fraction of it (`stream/base` well under K), so entry
    ///      stays open and a fresh depositor enters at the reduced rate. The guard must not turn a
    ///      recoverable loss into a bricked vault.
    function test_survivableLossLeavesEntryOpen() public {
        (uint256 id,) = _startStream();
        uint256 vested = vault.totalAssets();

        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        vm.prank(servicer);
        _realizeLoss(id, vested / 2, FILM_REF); // a 50% senior haircut - recoverable

        assertApproxEqAbs(vault.totalAssets(), vested / 2, 1, "half the vested base survives");
        assertLe(
            vault.unvestedYield(),
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * vault.totalAssets(),
            "stream is a small fraction of the base"
        );
        assertGt(vault.maxDeposit(bob), 0, "a survivable write-down must leave entry open");
        uint256 bobBefore = vault.balanceOf(bob);
        _stakeVault(bob, 1e18);
        assertGt(vault.balanceOf(bob), bobBefore, "deposit still works at the reduced rate");
    }

    /// @dev POSITIVE CONTROL: a realistic `notifyYield` distribution must NOT trip the guard. Even a
    ///      LARGE single distribution (100% of the staked base - far above any realistic yield) keeps
    ///      `unvestedYield()/totalAssets()` near 1, an order of magnitude below K, so entry stays open
    ///      at the seed, mid-vest, and fully-vested peak. Proves K sits comfortably above the largest
    ///      legitimate single-distribution ratio.
    function test_largeYieldDistributionLeavesEntryOpen() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);

        // (1) at the seed price
        assertGt(vault.maxDeposit(bob), 0, "seed vault open");
        _stakeVault(bob, 10_000e18);
        assertGt(vault.balanceOf(bob), 0, "deposit at seed works");

        // a LARGE yield stream (100% of alice's stake), far larger than any realistic distribution
        uint256 stream = _distributeInterest(id, 400_000e18);
        assertGt(stream, 0, "a large stream is live");
        assertLt(
            vault.unvestedYield(),
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * vault.totalAssets(),
            "even a 100% distribution is well under K"
        );

        // (2) mid-vest: part of the stream has vested, rate up but not fully
        vm.warp(block.timestamp + 3 days);
        assertGt(vault.currentExchangeRate(), 1e18, "rate has risen above the 1:1 seed");
        assertGt(vault.maxDeposit(bob), 0, "open mid-vest at an elevated rate");
        assertGt(_depositReturningShares(bob, 25_000e18), 0, "deposit mid-vest works");

        // (3) fully vested: rate at its peak
        vm.warp(block.timestamp + 10 days);
        assertEq(vault.unvestedYield(), 0, "stream fully vested");
        assertGt(vault.currentExchangeRate(), 1e18, "peak rate well above seed");
        assertGt(vault.maxDeposit(bob), 0, "open at the peak rate");
        uint256 bobBefore = vault.balanceOf(bob);
        _stakeVault(bob, 50_000e18);
        assertGt(vault.balanceOf(bob), bobBefore, "deposit at the peak rate works");
    }

    /// @dev AUDIT REGRESSION (FRV-FS-03): the old guard assumed distributions were
    ///      small relative to the staked base even though loan servicing is coupled to
    ///      book principal, not live sUSDfr supply. One healthy payment could therefore
    ///      create a stream above K×base and close all entry. Oversized cash is now
    ///      partially recognized immediately so the remaining stream lands exactly at
    ///      or below the guard boundary.
    function test_oversizedHealthyDistributionCannotCloseVaultEntry() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        uint256 assetsBefore = vault.totalAssets();

        uint256 delivered = _distributeInterest(id, 2_000_000e18);
        assertGt(delivered, Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * assetsBefore, "payment stresses the old guard");

        uint256 held = usdfr.balanceOf(address(vault));
        uint256 unvested = vault.unvestedYield();
        uint256 assets = vault.totalAssets();
        assertEq(assets + unvested, held, "recognized plus streamed yield reconciles to cash held");
        assertLe(
            unvested,
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * assets,
            "post-delivery stream respects the live staked-base boundary"
        );
        assertGt(assets, assetsBefore, "oversized excess is recognized as an explicit upward step");
        assertGt(vault.maxDeposit(bob), 0, "healthy payment cannot close senior entry");
        assertGt(_depositReturningShares(bob, 1e18), 0, "a fresh deposit remains executable");
    }

    // ── the same-value re-tune is a no-op ────────────────────────────────

    /// @dev AUDIT H-3 REMEDIATION. Crystallization restarts `lastYieldAt`, so re-applying the
    ///      CURRENT period would re-stretch the remaining stream over a fresh full window —
    ///      instantaneously rate-neutral (so the continuity helper is blind to it) but it defers
    ///      recognition of yield the vault already holds, and repeated calls defer it
    ///      geometrically. Measured before the guard: a 7-day stream re-written at T+6d still had
    ///      3,367.35e18 unvested at T+7d where the natural schedule had reached 0. A post-deploy
    ///      parameter-reassertion script (CLAUDE.md §2.1) re-writes configured values by design.
    function test_sameValueRetuneIsANoOpAndDoesNotRestartTheClock() public {
        (, uint256 stream) = _startStream();
        uint64 period = vault.yieldVestingPeriod();
        (, uint64 startedAt) = vault.vestingSchedule();

        vm.warp(block.timestamp + 6 days);
        uint256 unvestedBefore = vault.unvestedYield();
        assertEq(unvestedBefore, stream * 1 / 7, "1/7 of the 7-day stream is left");

        vm.prank(admin);
        vault.setYieldVestingPeriod(period);

        // nothing moved, and — the point — the clock did NOT restart
        assertEq(vault.unvestedYield(), unvestedBefore, "a same-value write must not re-price");
        (uint256 amountAfter, uint64 startedAfter) = vault.vestingSchedule();
        assertEq(amountAfter, stream, "the stream must not be re-based to its remainder");
        assertEq(startedAfter, startedAt, "THE VESTING CLOCK WAS RESTARTED BY A NO-OP WRITE");

        // so the original schedule still completes on time
        vm.warp(block.timestamp + 1 days);
        assertEq(vault.unvestedYield(), 0, "the stream completes on its original schedule");
        assertEq(vault.totalAssets(), usdfr.balanceOf(address(vault)), "everything credited");
    }

    /// @dev Repeated same-value writes cannot defer recognition at all.
    function test_repeatedSameValueRetunesCannotDeferRecognition() public {
        (, uint256 stream) = _startStream();
        uint64 period = vault.yieldVestingPeriod();
        for (uint256 i = 0; i < 7; ++i) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(admin);
            vault.setYieldVestingPeriod(period);
        }
        assertEq(vault.unvestedYield(), 0, "seven daily re-writes must not withhold a 7-day stream");
        assertEq(vault.totalAssets(), usdfr.balanceOf(address(vault)), "all of it credited");
        assertGt(stream, 0, "there was a stream to withhold");
    }

    // ── the zero-period escape hatch stays a step UP, never down ─────────

    /// @dev `period == 0` is the documented instant-credit hatch, so it is the one deliberate
    ///      discontinuity — it releases the crystallized remainder. Pin the DIRECTION: up only.
    function test_zeroPeriodReleasesUpwardOnly() public {
        _startStream();
        vm.warp(block.timestamp + 2 days);
        uint256 assetsBefore = vault.totalAssets();
        uint256 pending = vault.unvestedYield();
        assertGt(pending, 0, "there is a remainder to release");

        vm.prank(admin);
        vault.setYieldVestingPeriod(0);

        assertEq(vault.unvestedYield(), 0, "instant credit");
        assertEq(vault.totalAssets(), assetsBefore + pending, "the hatch credits, it never claws back");
    }

    /// @dev And re-enabling vesting from the zero (instant-credit) state must not retroactively
    ///      withhold yield already credited — the stale-`vestingAmount` bug in reverse.
    function test_reenablingVestingFromZeroDoesNotWithholdCreditedYield() public {
        _startStream();
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        vault.setYieldVestingPeriod(0);

        _assertRateUnchangedAcross(OPTIONAL_STREAM_PERIOD, "zero->vesting");
        assertEq(vault.unvestedYield(), 0, "nothing may be withheld again once credited");
    }

    /// @dev AUDIT FIX (RC-03). The FRV-FS-03 cap retains exactly `K/(K+1)` of the balance,
    ///      which leaves the vault sitting ON the `_isDegenerate` boundary with ZERO slack
    ///      when the balance divides exactly. Assets leaving through the queue shrink
    ///      `totalAssets()` while the stream is unchanged, so before the outflow re-cap ANY
    ///      ordinary settlement pushed the ratio into the closed region and shut the sole
    ///      senior entry point — reintroducing FRV-FS-03 through a different door.
    ///      `_withdraw` now re-caps against the post-outflow balance.
    function test_RC03_ordinaryQueueSettlementCannotCloseSeniorEntry() public {
        // A small staked base against a large book, so a delivery is large relative to live
        // deposits and `notifyYield` caps the stream onto the boundary.
        _stakeVault(alice, 1_000e18);
        uint256 id = _liveFilmFacility(500_000e18);

        // Queue FIRST and serve the cooldown. Ordering matters: the 21-day hold exceeds the
        // 7-day vesting window, so a stream started before the request would have fully
        // vested by settlement and the test would be vacuous. The reachable state is a
        // delivery landing against an ALREADY-ELIGIBLE request — routine, since deliveries
        // are continuous and settlement runs on the heartbeat.
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        queue.requestRedeem(shares);
        vm.stopPrank();
        vm.warp(uint256(queue.eligibleToSettleAt(queue.head())) + 1);

        _distributeInterest(id, 400_000e18);

        assertGt(vault.maxDeposit(bob), 0, "precondition: entry open right after the capped delivery");
        assertGt(vault.unvestedYield(), 0, "precondition: the stream is live at settlement time");
        assertLe(
            vault.unvestedYield(),
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * vault.totalAssets(),
            "precondition: the cap parked the vault at or inside the boundary"
        );

        queue.closeEpoch(10);

        assertGt(vault.maxDeposit(bob), 0, "an ordinary settlement must not close senior entry");
        assertLe(
            vault.unvestedYield(),
            Config.SUSDFR_MAX_STRANDED_YIELD_RATIO * vault.totalAssets(),
            "the boundary invariant must hold after an outflow, not only after a delivery"
        );
        assertGt(_depositReturningShares(bob, 100e18), 0, "a real deposit still succeeds post-settlement");
    }
}
