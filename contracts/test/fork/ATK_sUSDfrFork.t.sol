// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title ATK_sUSDfrForkTest — adversarial assault on sUSDfr, distinct from EXP6_VaultFork
/// @notice AUTHORISED local-fork security assessment of the owner's own pre-audit code
///         (CLAUDE.md prime directive 1). Never broadcasts, never moves real value; the fork is
///         local and ephemeral. Goal (CLAUDE.md §1.3): make the fee-net exchange rate fall with
///         no credit loss, extract value through fee crystallisation or vesting recognition, or
///         inflate/steal via the ERC-4626 accounting.
///
///         This suite deliberately attacks the routes `EXP6_VaultForkTest` does NOT:
///           1. PERMISSIONLESS `accrueFees()` as a griefing lever — turn the management fee on and
///              try to make a hostile caller EXTRACT MORE from a holder by checkpointing 52x
///              instead of once (checkpoint-frequency neutrality; rounding/dust priority #3).
///           2. The QUEUE-ONLY `prepareRedemptionPricing()` checkpoint on ACCRUED, unreceived
///              senior income (ADR-0038). Vesting is structurally off on the bound vault (ADR-0038
///              Q5), so the stranded stream this route once attacked cannot exist; the same attack
///              now targets the performance fee crystallised on accrued income: try to manufacture
///              a SECOND NAV step through the queue checkpoint, and let a depositor interleaved
///              between checkpoints SKIM the incumbents' accrued income (compose-out-of-order,
///              priority #1).
///           3. REENTRANCY through the points-module `_update` hook back into `accrueFees()`
///              (priority #2).
///           4. The gated permissionless-reachable entry points (`prepareRedemptionPricing`,
///              `redeem`) reached from a hostile, non-queue actor (access control).
///
///         In the fork shape `ops == address(this)` holds DEFAULT_ADMIN and GUARDIAN on the vault
///         (the fixture runs `_deployAll/_wire/_seed`, never `_handover`), and `ops` is the fee
///         recipient — so every fee/vesting setter below passes access control and must be stopped
///         by an economic bound, never by a role check. Yield is delivered through the genuine
///         waterfall interest leg, not poked in by hand.
///
///         OUTCOME: the protocol BLOCKS every route. Each test asserts the defended state, so a
///         regression that reopened a route flips the corresponding assertion red.
contract ATK_sUSDfrForkTest is ForkLifecycleFixture {
    /// @dev Stake `stakeUsdc6` of freshly minted USDfr from alice, then originate+fund a facility
    ///      so a later interest repayment delivers genuine yield into the vault.
    function _stakedVaultWithFacility(uint256 stakeUsdc6, uint256 principal18) internal returns (uint256 tokenId) {
        uint256 minted = _mintFromUSDC(alice, stakeUsdc6);
        _stake(alice, minted);
        tokenId = _originateAndFund(principal18);
    }

    function _aliceRedeemable() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(alice));
    }

    // ─────────────────────────────────────────────────────────────────────
    // ROUTE 1 — permissionless `accrueFees()` cannot ACCELERATE the management-fee drain.
    //
    // `accrueFees()` is permissionless. With a management fee live, a hostile caller might try to
    // checkpoint frequently to compound more fee out of a holder than the disclosed annual rate.
    // The geometric (powWad) retention is meant to be checkpoint-frequency neutral, with all
    // rounding in the holder's favour. We isolate the frequency effect on IDENTICAL starting state
    // with a snapshot: one 364-day checkpoint vs 52 weekly checkpoints. A holder must not end up
    // with materially fewer assets under the frequent-checkpoint schedule.
    // ─────────────────────────────────────────────────────────────────────
    function test_permissionlessAccrueFees_cannotAccelerateManagementDrain() public onFork {
        // A large, clean stake so the fee is far from any rounding floor.
        uint256 minted = _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, minted);

        // Governance turns the 2%/yr management fee on (permanent v1 cap). `setManagementFee`
        // accrues the old (zero) rate first, so no elapsed time is retro-priced.
        vault.setManagementFee(200);
        assertEq(vault.managementFeeBps(), 200, "management fee not enabled");

        // Clean baseline: lastFeeAccrual == now, no pending fees.
        vault.accrueFees();
        uint256 aliceBaseline = _aliceRedeemable();
        assertGt(aliceBaseline, 0, "alice holds nothing (setup vacuous)");

        uint256 snap = vm.snapshotState();

        // Path ONE — a single 364-day checkpoint.
        _warp(364 days);
        vault.accrueFees();
        uint256 aliceOne = _aliceRedeemable();

        assertTrue(vm.revertToState(snap), "snapshot revert failed");

        // Path MANY — 52 weekly checkpoints over the same 364 days, hammered permissionlessly
        // by a hostile EOA (carol holds no role).
        for (uint256 i = 0; i < 52; ++i) {
            _warp(7 days);
            vm.prank(carol);
            vault.accrueFees();
        }
        uint256 aliceMany = _aliceRedeemable();

        // The management fee DID bite under both schedules (yield-free vault, so this is pure fee).
        assertLt(aliceOne, aliceBaseline, "single checkpoint charged no management fee (setup broken)");
        assertLt(aliceMany, aliceBaseline, "frequent checkpoint charged no management fee");

        // THE INVARIANT: frequent permissionless checkpointing cannot extract MORE from the holder
        // than a single annual checkpoint. Geometric retention makes the schedules equal up to
        // holder-favouring rounding; allow a 1e-6 relative slack for that dust. If a compounding
        // bug let the hostile caller accelerate the drain, `aliceMany` would fall well below this.
        assertGe(
            aliceMany + aliceOne / 1_000_000,
            aliceOne,
            "INVARIANT BROKEN: permissionless accrueFees() accelerated the management drain"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // ROUTE 2: the queue-only `prepareRedemptionPricing()` checkpoint on ACCRUED income
    // (ADR-0038; successor of the G4/M-2 stream-recognition route).
    //
    // ADR-0038 "Decisions received from Forest Road, 2026-09-10", row Q5: "Enable ADR-0023
    // vesting alongside? No, not on. `yieldVestingPeriod` stays zero." The setter-side guard is
    // specified in docs/remediation/accrual-panel/INTEGRATION_REVIEW.md:192-195 ("prevent
    // changing to a nonzero vesting mode while continuous accrual is active") and the fresh
    // deploy path binds the vault at the end of `_wire` (ACCRUAL_BUILD_LOG_2026-09-12.md, "Work
    // package 3e, fresh-deployment accrual wiring"). So on this topology no stranded stream can
    // form, and the economic attack moves one layer up: after 30 days the vault PRICES the senior
    // share of the accrued coupon it does not yet hold (ADR-0038 Q1), and the queue's checkpoint
    // crystallises the performance fee on that income (Q4). We (impersonating the queue) try to
    // (a) manufacture a SECOND NAV step through that crystallisation, (b) let a depositor
    // interleaved between checkpoints skim the accrued income, and (c)/(d) re-fire the
    // checkpoint. The earned coupon is then received and must be NAV-neutral.
    // ─────────────────────────────────────────────────────────────────────
    function test_queuePrepareRedemptionPricing_noSecondJump_noStreamSkim() public onFork {
        _atkPinVestingGuard();

        uint256 tokenId = _stakedVaultWithFacility(3_000_000e6, 1_000_000e18);
        vault.accrueFees();

        _warp(30 days);
        _atkAssertAccruedNotHeld(tokenId);

        _atkRouteA();
        _atkRouteB();
        _atkRouteCD();
        _atkReceiptNeutral(tokenId);
    }

    /// @dev ADR-0038 Q5 pin: the fixture binds the vault to the continuous reserve and the
    ///      guard refuses every non-zero vesting period, so a regression that silently
    ///      re-enabled ADR-0023 smoothing alongside accrual flips this red.
    function _atkPinVestingGuard() private {
        assertEq(vault.accrualReserve(), address(reserves), "fixture did not bind the vault (ADR-0038 WP3e)");
        assertEq(vault.yieldVestingPeriod(), 0, "vesting configured on a bound vault (ADR-0038 Q5)");
        vm.expectRevert(SUSDfr.SUSDfr_AccrualVestingConflict.selector);
        vault.setYieldVestingPeriod(7 days);
        assertEq(vault.yieldVestingPeriod(), 0, "guard did not hold vesting at zero");
    }

    /// @dev Non-vacuity: the senior share of one earned coupon is priced but not held.
    ///      Closed form for the fixture note (1,000,000e18, 1400 bps, Actual/360, 30 days):
    ///      gross = 11,666,666,666,666,666,666,666 wei; the engine books it on USDC's 1e12 grid
    ///      as 11,666,666,666,000,000,000,000; senior = gross less the 10% protocol interest
    ///      fee = 10,499,999,999,999,999,999,999 (10,500e18 less one wei of flooring). The
    ///      1e12 + 30 days bound is the cash journal's stated envelope for native settlement
    ///      rounding and integer-slope interpolation (FullLifecycleFork).
    function _atkAssertAccruedNotHeld(uint256 tokenId) private view {
        uint256 gross = uint256(1_000_000e18) * 1400 * 30 days / (10_000 * 360 days);
        assertEq(reserves.accruedDebt(tokenId).interest, gross / 1e12 * 1e12, "accrued interest off the signed note");
        uint256 seniorAccrued = gross * (Config.BPS - waterfall.protocolFeeBps()) / Config.BPS;
        uint256 held0 = usdfr.balanceOf(address(vault));
        uint256 ta0 = vault.totalAssets();
        assertGt(ta0, held0, "no accrued income priced (attack setup vacuous)");
        assertApproxEqAbs(ta0 - held0, seniorAccrued, 1e12 + 30 days, "accrued senior income off (ADR-0038 Q1)");
        assertEq(vault.unvestedYield(), 0, "a stream exists on a bound vault");
        assertEq(vault.vestingDeadline(), 0, "a vesting deadline exists on a bound vault");
    }

    /// @dev Closed-form performance fee due NOW (VaultFeeMath.calculate with no management fee):
    ///      hurdle = ceil(hwm * S / unit); profit = perfAssets + 1 - hurdle; feeAssets =
    ///      floor(profit * perfBps / BPS); feeShares = floor(feeAssets * S / (marked + 1 - feeAssets));
    ///      newHwm = ceil(unit * (perfAssets + 1) / (supply + feeShares + virtual)).
    function _atkExpectedPerformanceFee()
        private
        view
        returns (uint256 oldHwm, uint256 newHwm, uint256 profitAssets, uint256 feeAssets, uint256 feeShares)
    {
        assertEq(vault.managementFeeBps(), 0, "management fee configured (closed form assumes none)");
        IContinuousAccrual.PricingState memory p = vault.accrualPricingState();
        uint256 virtualShares = 10 ** (vault.decimals() - usdfr.decimals());
        uint256 effectiveSupply = vault.totalSupply() + virtualShares;
        oldHwm = vault.highWaterMark();
        uint256 hurdleAssets = Math.mulDiv(oldHwm, effectiveSupply, 10 ** vault.decimals(), Math.Rounding.Ceil);
        profitAssets = p.performanceAssets + 1 - hurdleAssets;
        feeAssets = Math.mulDiv(profitAssets, vault.performanceFeeBps(), Config.BPS, Math.Rounding.Floor);
        feeShares = Math.mulDiv(feeAssets, effectiveSupply, p.redemptionAssets + 1 - feeAssets, Math.Rounding.Floor);
        newHwm = Math.mulDiv(
            10 ** vault.decimals(),
            p.performanceAssets + 1,
            vault.totalSupply() + feeShares + virtualShares,
            Math.Rounding.Ceil
        );
    }

    // (a) A tiny settlement bound recognises NOTHING (no stream on a bound vault) but the
    //     checkpoint inside crystallises the performance fee due on accrued income (ADR-0038
    //     Q4). The fee-net rate already simulated those shares (`_feeAdjustedSupply`), so the
    //     mint must not step it: EXACT equality, not a tolerance.
    function _atkRouteA() private {
        uint256 held0 = usdfr.balanceOf(address(vault));
        uint256 ta0 = vault.totalAssets();
        uint256 supply0 = vault.totalSupply();
        uint256 r0 = vault.currentExchangeRate();
        uint256 feeRef0 = vault.feeExchangeRate();
        uint256 feeShares0 = vault.balanceOf(vault.feeRecipient());
        (uint256 oldHwm, uint256 newHwm, uint256 profitAssets, uint256 feeAssets, uint256 feeShares) =
            _atkExpectedPerformanceFee();
        assertGt(feeShares, 0, "no performance fee due on accrued income (attack setup vacuous)");
        uint256 simulatedSupply = vault.accrualPricingState().feeAdjustedShares;

        // Ordering pin: the fee event fires inside the checkpoint, before the pricing event.
        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.PerformanceFeeAccrued(oldHwm, newHwm, profitAssets, feeAssets, feeShares);
        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.RedemptionPricingPrepared(1, held0 - 1, 0);
        vm.prank(vault.redemptionQueue());
        uint256 recTiny = vault.prepareRedemptionPricing(1);
        assertEq(recTiny, 0, "tiny settlement chunk recognised a stream on a bound vault");

        // The fee was crystallised exactly as the closed form predicts, with no cash movement.
        assertEq(vault.balanceOf(vault.feeRecipient()) - feeShares0, feeShares, "fee shares off the closed form");
        assertEq(vault.totalSupply(), supply0 + feeShares, "supply moved by more than the fee shares");
        assertEq(usdfr.balanceOf(address(vault)), held0, "crystallisation moved USDfr");
        assertEq(vault.totalAssets(), ta0, "crystallisation moved totalAssets");
        assertEq(vault.highWaterMark(), newHwm, "HWM not ratcheted to the crystallised rate");

        // THE INVARIANT (CLAUDE.md 1.3): crystallisation is not a second price jump.
        assertEq(vault.currentExchangeRate(), r0, "SECOND JUMP: queue crystallisation stepped the fee-net rate");
        assertEq(simulatedSupply, supply0 + feeShares, "pre-mint simulation differs from the minted shares");
        // The gross reference steps DOWN onto the fee-net rate: nothing is pending any more and
        // this shape carries no junior-capital credit, so both views share supply and base.
        assertLt(vault.feeExchangeRate(), feeRef0, "feeExchangeRate reference did not step down");
        assertEq(vault.feeExchangeRate(), r0, "gross reference did not land on the fee-net rate");
    }

    // (b) A fresh entrant deposits against accrued, unreceived income. ADR-0038 Q1 prices entry
    //     on the accrued NAV (entry base == realized base on a bound vault), so the shares are
    //     worth no more at realized NAV than the assets paid, and at most one wei less.
    function _atkRouteB() private {
        uint256 depositAssets = 200_000e18;
        uint256 bobUsdfr = _mintFromUSDC(bob, 500_000e6);
        assertGe(bobUsdfr, depositAssets, "attacker underfunded");
        uint256 quoted = vault.previewDeposit(depositAssets);
        uint256 quotedValue = vault.convertToAssets(quoted);
        assertLe(quotedValue, depositAssets, "SKIM: entrant priced below realized NAV");
        assertGe(quotedValue + 1, depositAssets, "entrant charged above realized NAV (bases diverged)");

        uint256 rBeforeEntry = vault.currentExchangeRate();
        uint256 feeSharesBeforeEntry = vault.balanceOf(vault.feeRecipient());
        uint256 bobShares = _stake(bob, depositAssets);
        assertEq(bobShares, quoted, "execution minted a different share count than the quote");
        assertLe(
            vault.convertToAssets(bobShares),
            depositAssets,
            "INVARIANT BROKEN: entrant skimmed the incumbents' accrued income"
        );
        assertEq(vault.maxRedeem(bob), 0, "entrant obtained an instant, queue-bypassing exit");
        assertEq(vault.balanceOf(vault.feeRecipient()), feeSharesBeforeEntry, "entry crystallised a fee");
        uint256 rAfterEntry = vault.currentExchangeRate();
        assertGe(rAfterEntry, rBeforeEntry, "INVARIANT BROKEN: entry lowered the fee-net rate");
        assertLe(rAfterEntry, rBeforeEntry + 1, "entry stepped the fee-net rate beyond floor rounding");
    }

    // (c)/(d) NO SECOND JUMP: a settlement bound at the full physical balance, twice, recognises
    //     nothing, mints no further fee shares and leaves the fee-net rate EXACTLY unchanged;
    //     the permissionless checkpoint then has nothing left to mint.
    function _atkRouteCD() private {
        uint256 held = usdfr.balanceOf(address(vault));
        uint256 rBeforeBig = vault.currentExchangeRate();
        uint256 feeSharesBig = vault.balanceOf(vault.feeRecipient());
        uint256 hwmBig = vault.highWaterMark();
        address q = vault.redemptionQueue();

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.RedemptionPricingPrepared(held, 0, 0);
        vm.prank(q);
        uint256 recBig = vault.prepareRedemptionPricing(held);
        assertEq(recBig, 0, "full settlement recognised a stream on a bound vault");
        assertEq(
            vault.balanceOf(vault.feeRecipient()), feeSharesBig, "SECOND JUMP: fee re-crystallised on the same income"
        );
        assertEq(vault.highWaterMark(), hwmBig, "HWM moved on a no-op checkpoint");
        assertEq(vault.currentExchangeRate(), rBeforeBig, "SECOND JUMP: fee-net rate moved on a no-op recognition");

        vm.expectEmit(false, false, false, true, address(vault));
        emit IsUSDfr.RedemptionPricingPrepared(held, 0, 0);
        vm.prank(q);
        uint256 recAgain = vault.prepareRedemptionPricing(held);
        assertEq(recAgain, 0, "SECOND JUMP: recognition re-fired");
        assertEq(vault.balanceOf(vault.feeRecipient()), feeSharesBig, "SECOND JUMP: fee re-crystallised twice");
        assertEq(vault.currentExchangeRate(), rBeforeBig, "SECOND JUMP: fee-net rate moved again");

        (uint256 mgmt, uint256 perf) = vault.accrueFees();
        assertEq(mgmt, 0, "management fee minted with no fee configured");
        assertEq(perf, 0, "performance fee double-charged");
        assertEq(vault.currentExchangeRate(), rBeforeBig, "permissionless checkpoint moved the rate");
    }

    // Receipt neutrality (ADR-0038 Q1): the earned coupon arrives as cash against income
    // already priced, so totalAssets moves only inside the cash journal's rounding envelope and
    // no ADR-0023 stream forms.
    function _atkReceiptNeutral(uint256 tokenId) private {
        uint256 taBefore = vault.totalAssets();
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        uint256 coupon = reserves.accruedDebt(tokenId).interest;
        assertEq(
            coupon, uint256(1_000_000e18) * 1400 * 30 days / (10_000 * 360 days) / 1e12 * 1e12, "coupon off the note"
        );
        _repay(tokenId, coupon, 0);
        uint256 taAfter = vault.totalAssets();
        uint256 heldAfter = usdfr.balanceOf(address(vault));
        assertApproxEqAbs(taAfter, taBefore, 1e12 + 30 days, "receipt of accrued income stepped NAV");
        assertGt(heldAfter, heldBefore, "interest did not arrive at the vault");
        // The coupon discharges the whole interest receivable, so nothing accrued remains priced:
        // every priced asset is now physically held (exact, ADR-0038 Q1).
        assertEq(reserves.accruedDebt(tokenId).interest, 0, "coupon left unpaid interest on the note");
        assertEq(taAfter, heldAfter, "priced assets differ from held assets after the receipt");
        assertEq(vault.unvestedYield(), 0, "receipt created a stream on a bound vault");
        assertEq(vault.vestingDeadline(), 0, "receipt created a vesting deadline on a bound vault");
    }

    // ─────────────────────────────────────────────────────────────────────
    // ROUTE 3 — reentrancy through the fail-open points-module `_update` hook.
    //
    // Governance can wire a points module (a trusted, fail-open hook fired inside every share
    // mint/burn/transfer). We wire a HOSTILE one that reenters `accrueFees()` from inside a share
    // mint, when supply/assets are transiently inconsistent. The transient-state guard must reject
    // the reentrant checkpoint; because the hook is fail-open, the outer deposit still settles, and
    // the vault's accounting must remain intact and re-accruable afterwards.
    // ─────────────────────────────────────────────────────────────────────
    function test_reentrantPointsModule_isNeutralizedByTransientGuard() public onFork {
        ReentrantPointsModule evil = new ReentrantPointsModule(IsUSDfr(address(vault)));
        vault.setPointsModule(address(evil)); // ops holds DEFAULT_ADMIN in the fork shape

        uint256 minted = _mintFromUSDC(alice, 1_000_000e6);

        // The deposit fires the hook mid-`_update`; the hook reenters accrueFees().
        uint256 shares = _stake(alice, minted);

        assertTrue(evil.reentryAttempted(), "hostile hook never fired (attack setup vacuous)");
        assertTrue(evil.reentryReverted(), "INVARIANT BROKEN: reentrant accrueFees() was NOT rejected mid-share-update");

        // The fail-open deposit still settled and minted real shares to the depositor.
        assertGt(shares, 0, "fail-open deposit minted no shares");
        assertEq(vault.balanceOf(alice), shares, "depositor share balance corrupted by the reentrancy attempt");

        // And the vault is not wedged: a clean checkpoint from outside any share-update frame works.
        vault.accrueFees();
    }

    // ─────────────────────────────────────────────────────────────────────
    // ROUTE 4 — the gated permissionless-reachable entry points reject a hostile, non-queue actor.
    // `prepareRedemptionPricing` and the ERC-4626 exits are bound to the redemption-queue module
    // (ADR-0010). A random EOA reaching them must hit the specific queue-only guard.
    // ─────────────────────────────────────────────────────────────────────
    function test_nonQueueEntryPoints_revertQueueOnly() public onFork {
        // carol is neither the queue nor KYC'd. prepareRedemptionPricing gates on the queue first.
        vm.prank(carol);
        vm.expectRevert(IsUSDfr.SUSDfr_QueueOnly.selector);
        vault.prepareRedemptionPricing(1);

        // A zero-share redeem slips past the max-capacity check (0 <= 0) and lands on the
        // defence-in-depth queue-only guard in `_withdraw`, proving the exit is bound to the queue.
        vm.prank(carol);
        vm.expectRevert(IsUSDfr.SUSDfr_QueueOnly.selector);
        vault.redeem(0, carol, carol);
    }
}

/// @dev A hostile points module that tries to reenter `accrueFees()` from inside the sUSDfr
///      `_update` share-mint hook. It swallows the (expected) revert so the vault's fail-open hook
///      sees a clean return, and records that the reentrant checkpoint was rejected — the crisp,
///      unambiguous signal that the transient-state guard fired.
contract ReentrantPointsModule is IPointsModule {
    IsUSDfr private immutable VAULT;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(IsUSDfr vault_) {
        VAULT = vault_;
    }

    function onSharesTransfer(address, address, uint256) external override {
        reentryAttempted = true;
        try VAULT.accrueFees() returns (uint256, uint256) {
            reentryReverted = false; // the guard FAILED to stop the reentrant checkpoint
        } catch {
            reentryReverted = true; // the guard rejected it, as required
        }
    }

    function onUSDfrTransfer(address, address, uint256) external override {}
    function onCuratorStakeChange(address, uint256, uint256) external override {}
    function onCuratorLoss(uint256, uint256, uint256) external override {}
}
