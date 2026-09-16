// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IRedemptionQueue} from "../../src/interfaces/IRedemptionQueue.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title EXP6_VaultForkTest — adversarial probes on sUSDfr fee-net exchange-rate integrity.
/// @notice AUTHORISED local-fork security assessment (owner's own pre-audit code). Never
///         broadcasts; `ForkLifecycleFixture` deploys the FULL protocol onto a pinned mainnet
///         fork via the real deploy phases.
///
///         GOAL (CLAUDE.md §1.3): make the fee-net exchange rate DECREASE absent a credit loss,
///         or extract value through fee crystallisation. Five distinct routes are attempted, all
///         composing legitimate operations at unexpected times:
///           1. DONATION — transfer USDfr straight into the vault to move the rate.
///           2. REAL YIELD + CRYSTALLISATION — deliver yield through the live WaterfallEngine and
///              look for a "second price jump" (ADR-0031) or a double-charged performance fee.
///           3. VESTING RE-PRICING (audit H-3) — deliver vesting yield, half-vest it, then LENGTHEN
///              the vesting window to try to resurrect already-vested yield and drop the rate.
///           4. FRONT-RUN CRYSTALLISATION — enable a management fee, warp, then race a permissionless
///              `accrueFees()` to see the investor rate step a second time at crystallisation.
///           5. YIELD SANDWICH — deposit right before a yield credit and try to exit right after.
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
    // Drive genuine yield through the live originate -> fund -> repay(interest) path. The
    // WaterfallEngine crystallises fees INSIDE distribute (ADR-0031). We assert the rate strictly
    // rose (yield credited, net of the <=10% performance fee) and that a subsequent permissionless
    // accrueFees() is a pure no-op: no double charge, no downward re-step.
    function test_realYieldRaisesRate_noSecondJumpOnCrystallisation() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        uint256 ratePre = vault.currentExchangeRate();
        uint256 feeSharesPre = vault.balanceOf(vault.feeRecipient());

        uint256 tokenId = _originateAndFund(1_000_000e18);
        _repay(tokenId, 100_000e18, 0); // interest-only: 100k yield, ~90k to the senior vault

        uint256 ratePost = vault.currentExchangeRate();
        // (a) yield strictly RAISED the fee-net rate, absent any loss
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

    // ── ROUTE 3: lengthening the vesting window cannot resurrect vested yield (audit H-3) ────
    // The historical H-3 break: writing a longer vesting period against a stale (already-vesting)
    // stream re-prices it, dropping totalAssets() and the exchange rate in one transaction with no
    // loss and no cascade. The fix crystallises the pending remainder against the OLD schedule and
    // forbids the absolute deadline moving later. We half-vest a real stream, then LENGTHEN and
    // assert the rate does not fall and the deadline does not extend.
    function test_H3_lengthenVestingCannotDropRateOrExtendDeadline() public onFork {
        // Enable optional linear vesting (governance retains admin in the fork fixture).
        vault.setYieldVestingPeriod(uint64(7 days));

        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        uint256 tokenId = _originateAndFund(1_000_000e18);
        _repay(tokenId, 100_000e18, 0); // yield now enters as a 7-day vesting stream

        assertGt(vault.unvestedYield(), 0, "vesting stream was not created");
        uint64 deadlineBefore = vault.vestingDeadline();

        _warp(3 days + 12 hours); // ~half the stream vests into the rate
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 unvestedBefore = vault.unvestedYield();

        // ATTACK: lengthen 7d -> 21d against the partially-vested stream.
        vault.setYieldVestingPeriod(uint64(21 days));

        // BLOCKED: crystallised against the old schedule — the rate did not drop, and the absolute
        // deadline was clamped to the original (never pushed later), so the vested portion cannot be
        // clawed back into "unvested".
        _assertRateNotBelow(vault.currentExchangeRate(), rateBefore, "lengthening vesting dropped the fee-net rate");
        assertLe(vault.vestingDeadline(), deadlineBefore, "lengthening vesting pushed the stream deadline later");
        // The still-unvested amount was not inflated by the re-pricing.
        assertLe(vault.unvestedYield(), unvestedBefore + unvestedBefore / 1000, "lengthening resurrected vested yield");
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
    // after to skim the yield risk-free. The vault's only exit is the epoch queue with a forced
    // 21-day cooldown (ADR-0022). We stake, deliver yield, request redemption, warp past the
    // 1-day heartbeat but well inside the cooldown, and confirm settlement is refused.
    function test_yieldSandwichBlockedByRedeemCooldown() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 1_000_000e18);

        // Attacker deposits right before the yield credit.
        _mintFromUSDC(bob, 1_000_000e6);
        uint256 bobShares = _stake(bob, 1_000_000e18);

        uint256 tokenId = _originateAndFund(1_000_000e18);
        _repay(tokenId, 100_000e18, 0); // yield lands; bob's shares are now worth more

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
}
