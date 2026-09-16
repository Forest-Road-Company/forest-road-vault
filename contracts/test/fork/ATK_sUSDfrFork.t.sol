// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {IPointsModule} from "../../src/interfaces/IPointsModule.sol";

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
///           2. The QUEUE-ONLY `prepareRedemptionPricing()` recognition loop under ADR-0023
///              vesting — try to manufacture a SECOND NAV step by chunking the recognition, and to
///              let a depositor interleaved between recognition calls SKIM the stranded stream
///              (compose-out-of-order, priority #1).
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
    // ROUTE 2 — the queue-only `prepareRedemptionPricing()` recognition loop (G4/M-2).
    //
    // Under ADR-0023 vesting a real payment strands an unvested stream. `prepareRedemptionPricing`
    // recognises the stream against the settlement's REMAINING outflow bound. We (impersonating the
    // queue) try to (a) manufacture a SECOND NAV step by re-recognising, and (b) let a depositor
    // interleaved between recognition calls skim the stranded stream. Entry prices on the PHYSICAL
    // balance (which includes the unvested stream), so the skim must be non-positive, and a stream
    // already inside its cap cannot be recognised a second time.
    // ─────────────────────────────────────────────────────────────────────
    function test_queuePrepareRedemptionPricing_noSecondJump_noStreamSkim() public onFork {
        vault.setYieldVestingPeriod(7 days); // governance enables optional smoothing

        uint256 tokenId = _stakedVaultWithFacility(3_000_000e6, 1_000_000e18);
        vault.accrueFees();

        _warp(30 days);
        _repay(tokenId, 100_000e18, 0);
        uint256 unv0 = vault.unvestedYield();
        assertGt(unv0, 0, "no stranded stream formed (attack setup vacuous)");

        address q = vault.redemptionQueue();
        uint256 r0 = vault.currentExchangeRate();

        // (a) A tiny settlement bound must recognise NOTHING: the stream is already inside its
        //     held/(K+1) cap, so a small chunk cannot manufacture a NAV step.
        vm.prank(q);
        uint256 recTiny = vault.prepareRedemptionPricing(1);
        assertEq(recTiny, 0, "tiny settlement chunk manufactured a recognition step");
        assertEq(vault.unvestedYield(), unv0, "tiny chunk moved the stranded stream");
        assertGe(vault.currentExchangeRate(), r0, "INVARIANT BROKEN: rate fell on a no-op recognition");
        // A real recognition step of the whole stream is ~3% of the rate (~3e16); this 1e6-wei
        // window is ~10 orders of magnitude tighter, so it flags a manufactured step yet tolerates
        // fee-crystallisation dust.
        assertApproxEqAbs(vault.currentExchangeRate(), r0, 1e6, "tiny chunk stepped the fee-net rate");

        // (b) A fresh entrant deposits WHILE the stream is stranded. Entry prices on the physical
        //     balance, so the shares are worth no more at realized NAV than the assets deposited —
        //     the skim of the incumbent stream is non-positive at the entry instant.
        uint256 depositAssets = 200_000e18;
        uint256 bobUsdfr = _mintFromUSDC(bob, 500_000e6);
        assertGe(bobUsdfr, depositAssets, "attacker underfunded");
        uint256 quoted = vault.previewDeposit(depositAssets);
        assertLe(vault.convertToAssets(quoted), depositAssets, "SKIM: entrant priced below realized NAV");
        uint256 bobShares = _stake(bob, depositAssets);
        assertLe(
            vault.convertToAssets(bobShares),
            depositAssets,
            "INVARIANT BROKEN: entrant skimmed the incumbent unvested stream"
        );
        assertEq(vault.maxRedeem(bob), 0, "entrant obtained an instant, queue-bypassing exit");

        // (c) A settlement bound at least the physical balance recognises the WHOLE remaining
        //     stream exactly once — an explicit UPWARD step on cash already held.
        uint256 held = usdfr.balanceOf(address(vault));
        uint256 rBeforeBig = vault.currentExchangeRate();
        vm.prank(q);
        uint256 recBig = vault.prepareRedemptionPricing(held);
        assertGt(recBig, 0, "full settlement recognised nothing (setup broken)");
        assertEq(vault.unvestedYield(), 0, "stream not fully recognised at the full settlement bound");
        uint256 rAfterBig = vault.currentExchangeRate();
        assertGe(rAfterBig, rBeforeBig, "recognition lowered the fee-net rate");

        // (d) NO SECOND JUMP (ADR-0031 / G4/M-2): re-running recognition after the stream is gone
        //     recognises nothing and moves the fee-net rate no further.
        vm.prank(q);
        uint256 recAgain = vault.prepareRedemptionPricing(held);
        assertEq(recAgain, 0, "SECOND JUMP: recognition re-fired on an already-recognised stream");
        assertApproxEqAbs(
            vault.currentExchangeRate(), rAfterBig, 1e6, "SECOND JUMP: fee-net rate moved on a no-op recognition"
        );
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
