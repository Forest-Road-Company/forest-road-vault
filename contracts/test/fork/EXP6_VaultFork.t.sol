// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";

/// @title EXP6_VaultForkTest — adversarial probes on sUSDfr fee-net exchange-rate integrity.
/// @notice AUTHORISED local-fork security assessment (owner's own pre-audit code). Never
///         broadcasts; `ForkLifecycleFixture` deploys the FULL protocol onto a pinned mainnet
///         fork via the real deploy phases.
///
///         GOAL (CLAUDE.md §1.3): make the fee-net exchange rate DECREASE absent a credit loss,
///         or extract value through fee crystallisation. Five distinct routes are attempted, all
///         composing legitimate operations at unexpected times:
///           1. DONATION — transfer USDfr straight into the vault to move the rate.
///           2. REAL YIELD + CRYSTALLISATION: accrue a real coupon through the live engine
///              (ADR-0038: recognition follows the accrual clock, cash converts accrued to
///              realised), receive it through the WaterfallEngine and look for a "second price
///              jump" (ADR-0031) or a double-charged performance fee.
///           3. VESTING RE-PRICING (audit H-3): try to enable ADR-0023 vesting on the bound
///              vault so the old lengthen-the-window re-pricing has a stream to act on. ADR-0038
///              Q5 keeps vesting off; the setter refuses every non-zero period.
///           4. FRONT-RUN CRYSTALLISATION — enable a management fee, warp, then race a permissionless
///              `accrueFees()` to see the investor rate step a second time at crystallisation.
///           5. YIELD SANDWICH: deposit before a 30-day accrual and its coupon receipt, then try
///              to exit right after.
///
///         No credit loss (no default is ever declared) is induced in any test, so the impairment
///         source reports zero throughout: every rate move observed here is "absent credit loss".
///
///         OUTCOME: every route is BLOCKED. Reverting routes assert the specific custom error;
///         non-reverting routes assert the monotonicity/continuity property the protocol must hold.
///         If any of these assertions ever fails when run, that failure IS the finding.
contract EXP6_VaultForkTest is ForkLifecycleFixture {
    /// @dev A rate is allowed to wobble by at most this RELATIVE amount from rounding. A genuine
    ///      monotonicity break (a resurrected stream, a double-charged fee) moves the rate by
    ///      whole percent, far outside this band, so a tolerance here cannot hide a real exploit.
    uint256 private constant RATE_ROUNDING_TOL = 1e15; // 0.1%

    /// @dev Asserts `rateAfter` did not fall below `rateBefore` by more than rounding tolerance.
    function _assertRateNotBelow(uint256 rateAfter, uint256 rateBefore, string memory ctx) private pure {
        uint256 floor = rateBefore - rateBefore / 1000; // allow 0.1% down for rounding only
        require(rateAfter >= floor, ctx);
    }

    // ── ROUTE 1: donation cannot lower the fee-net rate ────────────────────
    // Donating USDfr into the vault is the classic ERC-4626 rate-manipulation primitive. Here it
    // can only raise the rate (assets rise, no shares minted); crystallising the resulting profit
    // takes at most the performance fee, leaving the rate net-positive. It can never DECREASE it.
    function test_donationCannotLowerFeeNetRate() public onFork {
        _mintFromUSDC(alice, 700_000e6);
        _stake(alice, 500_000e18);

        uint256 rate0 = vault.currentExchangeRate();
        uint256 feeRate0 = vault.feeExchangeRate();

        // Donate 100k USDfr straight into the vault (unexpected, unaccounted inflow).
        vm.prank(alice);
        usdfr.transfer(address(vault), 100_000e18);

        // The rate can only have risen; the (pre-crystallisation) fee-net rate already simulates
        // the pending performance fee, and even net of it the donor gifted value to incumbents.
        assertGe(vault.currentExchangeRate(), rate0, "donation lowered currentExchangeRate");
        assertGe(vault.feeExchangeRate(), feeRate0, "donation lowered feeExchangeRate");

        // Crystallise the donation profit (permissionless). No "second jump" down below entry.
        vault.accrueFees();
        assertGe(vault.currentExchangeRate(), rate0, "crystallisation dropped rate below pre-donation");
    }

    // ── ROUTE 2: real yield raises the rate; crystallisation has no second jump ─────────────
    // Drive genuine yield through the live originate -> fund -> accrue -> repay(interest) path.
    // ADR-0038 ("Decision", items 1 and 4): senior income is recognised continuously as the note
    // accrues, so the fee-net rate rises BEFORE any cash arrives, and the cash receipt converts
    // the accrued claim to realised rather than recognising it a second time. The interest leg
    // of a receipt is bounded by the contractual accrued interest (AccrualLoans.sol:326,
    // `AccrualLoans_PaymentAboveDebt`; ADR-0038 "Loss-bearing cash and PIK without changing the
    // contractual basis"), so the receipt pays the earned 30-day coupon, pinned here to the
    // Actual/360 closed form on USDC's 1e12 grid. The WaterfallEngine crystallises fees INSIDE
    // distribute (ADR-0031). We assert the rate rose during accrual (before cash) and over the
    // whole route, that a performance fee was in fact crystallised, and that a subsequent
    // permissionless accrueFees() is a pure no-op: no double charge, no downward re-step.
    function test_realYieldRaisesRate_noSecondJumpOnCrystallisation() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        uint256 ratePre = vault.currentExchangeRate();
        uint256 feeSharesPre = vault.balanceOf(vault.feeRecipient());

        uint256 tokenId = _originateAndFund(1_000_000e18);

        // ADR-0038: recognition follows the accrual clock. One 30-day interval elapses and the
        // interest leg is sized to the contractual coupon the engine accepts:
        // 1,000,000e18 x 1400 bps x 30/360, floored to the 1e12 grid = 11,666,666,666e12.
        _warp(30 days);
        uint256 coupon = reserves.accruedDebt(tokenId).interest;
        assertEq(coupon, _coupon(1_000_000e18, 30 days), "engine coupon is not the Actual/360 closed form");
        assertEq(coupon, 11_666_666_666e12, "30-day coupon on 1,000,000e18 at 14% is 11,666.666666e18");

        // ACCRUAL BEFORE CASH (ADR-0038): the fee-net rate already rose on accrued, unreceived
        // income, with not one USDfr of interest yet held by the vault.
        uint256 rateAccrued = vault.currentExchangeRate();
        assertGt(rateAccrued, ratePre, "accrual did not raise the fee-net rate before the cash receipt");

        _repay(tokenId, coupon, 0); // interest-only: the earned coupon, ~90% to the senior vault

        uint256 ratePost = vault.currentExchangeRate();
        // (a) yield strictly RAISED the fee-net rate over the whole route, absent any loss
        assertGt(ratePost, ratePre, "real yield did not raise the fee-net rate");
        // (b) a performance fee was in fact crystallised to the recipient (value routed, bounded)
        assertGt(vault.balanceOf(vault.feeRecipient()), feeSharesPre, "no performance fee crystallised on yield");

        // (c) NO SECOND JUMP / NO DOUBLE CHARGE: distribute already crystallised, so another
        //     accrueFees() at the same timestamp must mint nothing and must not move the rate.
        (uint256 mgmt2, uint256 perf2) = vault.accrueFees();
        assertEq(mgmt2, 0, "second accrueFees double-charged a management fee");
        assertEq(perf2, 0, "second accrueFees double-charged a performance fee");
        assertEq(vault.currentExchangeRate(), ratePost, "crystallisation created a second price jump");
    }

    // ── ROUTE 3: vesting cannot be enabled on a bound vault (the audit H-3 surface) ─────────
    // The historical H-3 break: writing a longer vesting period against a stale (already-vesting)
    // stream re-priced it, dropping totalAssets() and the exchange rate in one transaction with
    // no loss and no cascade. ADR-0038 ("Decisions received from Forest Road, 2026-09-10", Q5:
    // "Enable ADR-0023 vesting alongside? No, not on. yieldVestingPeriod stays zero") removes
    // that surface on the deployed topology: `Deploy._wire` binds the vault to the continuous
    // accrual reserve, and `setYieldVestingPeriod` refuses every non-zero period on a bound
    // vault with `SUSDfr_AccrualVestingConflict` before touching state (sUSDfr.sol:864-867;
    // docs/remediation/accrual-panel/VAULT_ACCRUAL_VALIDATION_2026-09-11.md, "Continuous
    // binding also requires zero vesting period and zero unvested legacy yield"). This test
    // pins the guard for the two periods the old attack used (7 days to open a stream, 21 days
    // to lengthen it), drives a real coupon receipt through the engine and confirms no stream
    // or deadline forms, and pins that the only permitted write (zero, the current value) is a
    // complete no-op: rate unchanged to the wei, no deadline, no stream, and no event emitted.
    // The economic H-3 property itself is covered on unbound fixtures
    // (test/audit/Fix_H3-vesting-period-crystallization.t.sol), which is where the unbound
    // mainnet deployment at edf525c is exercised.
    function test_H3_vestingCannotBeEnabledOnABoundVault_zeroRewriteIsNeutral() public onFork {
        assertEq(vault.accrualReserve(), address(reserves), "fixture did not bind the vault");
        assertEq(vault.yieldVestingPeriod(), 0, "bound vault started with a vesting period");

        // The old attack's first act: open a 7-day stream. BLOCKED by the accrual guard.
        vm.expectRevert(SUSDfr.SUSDfr_AccrualVestingConflict.selector);
        vault.setYieldVestingPeriod(uint64(7 days));

        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        uint256 tokenId = _originateAndFund(1_000_000e18);
        // A real receipt the accrual engine accepts: the earned 30-day coupon (ADR-0038).
        _warp(30 days);
        uint256 coupon = reserves.accruedDebt(tokenId).interest;
        assertEq(coupon, _coupon(1_000_000e18, 30 days), "engine coupon is not the Actual/360 closed form");
        assertEq(coupon, 11_666_666_666e12, "30-day coupon on 1,000,000e18 at 14% is 11,666.666666e18");
        _repay(tokenId, coupon, 0);

        // Continuous recognition, not ADR-0023 smoothing: no stream and no deadline formed.
        assertEq(vault.unvestedYield(), 0, "a vesting stream formed on a bound vault");
        assertEq(vault.vestingDeadline(), 0, "a vesting deadline formed on a bound vault");

        _warp(3 days + 12 hours); // where the old attack half-vested its stream
        uint256 rateBefore = vault.currentExchangeRate();

        // The old attack's second act: lengthen to 21 days. BLOCKED by the same guard.
        vm.expectRevert(SUSDfr.SUSDfr_AccrualVestingConflict.selector);
        vault.setYieldVestingPeriod(uint64(21 days));

        // The only permitted write (zero, the current value) is a no-op: the setter returns
        // before crystallising or re-basing anything, so no state transitions and nothing is
        // emitted (sUSDfr.sol `setYieldVestingPeriod` NatSpec: "It emits nothing, because no
        // state transitioned").
        vm.recordLogs();
        vault.setYieldVestingPeriod(0);
        assertEq(vm.getRecordedLogs().length, 0, "zero re-write emitted an event: state transitioned");
        assertEq(vault.currentExchangeRate(), rateBefore, "zero re-write moved the fee-net rate");
        assertEq(vault.yieldVestingPeriod(), 0, "zero re-write changed the vesting period");
        assertEq(vault.vestingDeadline(), 0, "zero re-write created a deadline");
        assertEq(vault.unvestedYield(), 0, "zero re-write resurrected a stream");
    }

    // ── ROUTE 4: front-running crystallisation of a management fee gives no second jump ──────
    // Enable the maximum management fee and let it accrue. `currentExchangeRate()` already
    // simulates the pending fee shares, so an attacker who front-runs the permissionless
    // `accrueFees()` sees the SAME investor rate before and after crystallisation — there is no
    // exploitable step to trade against. `feeExchangeRate()` (the raw-supply HWM reference) does
    // step down, by design, confirming the two views intentionally differ.
    function test_frontRunManagementFeeCrystallisationHasNoSecondJump() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        vault.setManagementFee(Config.MAX_MANAGEMENT_FEE_BPS); // 2%/yr, a real economic fee
        _warp(180 days); // fee becomes economically due

        uint256 rateSim = vault.currentExchangeRate(); // simulates the pending management shares
        uint256 feeRefBefore = vault.feeExchangeRate(); // raw-supply reference (does NOT simulate)

        // Attacker races the checkpoint from an unrelated account.
        vm.prank(bob);
        (uint256 mgmtShares,) = vault.accrueFees();
        assertGt(mgmtShares, 0, "management fee did not accrue over 180 days");

        uint256 rateReal = vault.currentExchangeRate();
        // NO SECOND JUMP: the investor rate is continuous across crystallisation.
        assertApproxEqRel(rateReal, rateSim, RATE_ROUNDING_TOL, "management crystallisation created a second jump");
        // The HWM reference did step down (expected, documented distinction), proving the
        // continuity above is not a coincidence of the two views being identical.
        assertLt(vault.feeExchangeRate(), feeRefBefore, "feeExchangeRate reference failed to reflect the fee");

        // No double-charge: a same-block re-checkpoint mints nothing and does not move the rate.
        (uint256 mgmt2, uint256 perf2) = vault.accrueFees();
        assertEq(mgmt2, 0, "management fee double-charged in the same block");
        assertEq(perf2, 0, "performance fee charged with no profit");
        assertEq(vault.currentExchangeRate(), rateReal, "re-checkpoint moved the investor rate");
    }

    // ── ROUTE 5: deposit-before / withdraw-after yield sandwich is blocked by the cooldown ───
    // The JIT liquidity attack: stake immediately before a yield credit, then exit immediately
    // after to skim the yield risk-free. Under ADR-0038 the yield is recognised continuously
    // over the note's 30-day interval and the cash receipt discharges exactly the accrued
    // coupon (bounded by AccrualLoans.sol:326), so the attacker stakes before the accrual
    // window and the receipt, and the vault's only exit is the epoch queue with a forced 21-day
    // cooldown (ADR-0022). We stake, accrue and receive the coupon, confirm the attacker's
    // position did appreciate (so there is yield to sandwich), request redemption, warp past the
    // 1-day heartbeat but well inside the cooldown, and confirm settlement is refused.
    function test_yieldSandwichBlockedByRedeemCooldown() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        // Attacker deposits right before the yield accrues and is received.
        _mintFromUSDC(bob, 1_000_000e6);
        uint256 bobShares = _stake(bob, 1_000_000e18);

        uint256 tokenId = _originateAndFund(1_000_000e18);
        // ADR-0038: one 30-day interval accrues, then the earned coupon is received
        // (1,000,000e18 x 1400 bps x 30/360, floored to the 1e12 grid = 11,666,666,666e12).
        _warp(30 days);
        uint256 coupon = reserves.accruedDebt(tokenId).interest;
        assertEq(coupon, _coupon(1_000_000e18, 30 days), "engine coupon is not the Actual/360 closed form");
        assertEq(coupon, 11_666_666_666e12, "30-day coupon on 1,000,000e18 at 14% is 11,666.666666e18");
        _repay(tokenId, coupon, 0); // yield lands; bob's shares are now worth more than he paid
        assertGt(
            vault.convertToAssets(bobShares), 1_000_000e18, "nothing to sandwich: bob's position did not appreciate"
        );

        // Attacker tries to exit immediately after.
        vm.prank(bob);
        vault.approve(address(queue), bobShares);
        vm.prank(bob);
        uint256 requestId = queue.requestRedeem(bobShares);
        uint256 eligibleAt = queue.eligibleToSettleAt(requestId);

        _warp(5 days); // past the 1-day heartbeat, but far inside the 21-day cooldown

        // BLOCKED: the settlement refuses to fill a request still in its forced cooldown. The
        // sandwich cannot close in one epoch; the attacker must sit exposed for the full cooldown.
        vm.expectRevert(abi.encodeWithSelector(IRedemptionQueue.Queue_AllInCooldown.selector, eligibleAt));
        queue.closeEpoch(10);
    }

    /// @dev The contractual coupon on the fixture's note (fixed 1400 bps, Actual/360, see
    ///      `ForkLifecycleFixture._forkTerms`) for `elapsed` seconds on `principal`, floored to
    ///      USDC's 1e12 grid the way `AccrualMath.periodAmount` floors canonical interest:
    ///      principal x 1400 / 10,000 x elapsed / (360 days), then / 1e12 * 1e12.
    function _coupon(uint256 principal, uint256 elapsed) private pure returns (uint256) {
        return (principal * 1400 * elapsed / (10_000 * 360 days)) / 1e12 * 1e12;
    }
}
