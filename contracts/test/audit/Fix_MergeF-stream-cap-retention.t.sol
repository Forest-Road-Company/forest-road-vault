// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SUSDfr} from "../../src/sUSDfr.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title MERGE CAUSE F — the surviving `_capStreamToBase` retention must stay `1/(K+1)`
/// @notice WHAT THE MERGE DID. The merged `sUSDfr` carried BOTH stream-capping implementations
///         side by side, hidden by Solidity overloading: input-1's `_capStreamToBase(uint256)`
///         retaining `held/(K+1)`, and input-2's `_capStreamToHeld(uint256)` retaining
///         `mulDiv(held, K, K+1)`. `notifyYield` (inflow), `prepareRedemptionPricing` (queue
///         pricing) and `_withdraw` (outflow) all routed through input-2's. The repair
///         (`fix(merge): restore custody guard and stream cap`) deleted the duplicate and left one
///         function retaining `held/(K+1)`. NOTHING IN EITHER TIER TESTED THE RESULT: the suite is
///         green with the retention reverted to `mulDiv(held, K, K+1)`, which is exactly the
///         deletable-guard pattern this file exists to close.
///
///         WHY THE RETENTION IS THE WHOLE FIX. `_isDegenerate()` closes senior entry on the
///         stranded-stream band `unvestedYield() > K * totalAssets()`, and `totalAssets()` is the
///         vault's physical USDfr less the unvested stream. Writing `H` for the physical balance:
///
///           retention `held/(K+1)`      ->  stream = H/(K+1),   base = K*H/(K+1)
///                                           stream / base = 1/K^2 of the band  -> 9x of headroom
///           retention `K*held/(K+1)`    ->  stream = K*H/(K+1), base = H/(K+1)
///                                           stream / base = K   -> EXACTLY ON the band, zero slack
///
///         The reverted form parks a HEALTHY vault precisely on the boundary every time the
///         balance divides evenly. The merge tree's predicate is a strict `>`, so entry is not shut
///         at that instant — it is shut by the NEXT wei to leave the vault. `realizeLoss`'s layer-3
///         senior burn (`MintRedeemController.burnLoss(vault, ...)`) is exactly that: it reduces
///         the physical balance with no re-cap, so ANY realized senior loss, of any size, tips the
///         parked vault into the fail-closed band and bricks the sole senior entry point. Under the
///         shipped retention the same state absorbs a loss of ~89% of the deposit base first.
///
///         These tests therefore assert the PROPERTY (`stream` is a minority of the vault's cash,
///         `base` is the majority) and then drive the consequence through the REAL deposit and
///         REAL queue-settlement paths, never through the internal helper.
contract FixMergeFStreamCapRetentionTest is CreditLayerFixture {
    uint64 internal constant OPTIONAL_STREAM_PERIOD = 7 days;
    uint256 internal constant K = Config.SUSDFR_MAX_STRANDED_YIELD_RATIO;

    function setUp() public override {
        super.setUp();
        // The stream — and therefore this whole boundary — exists only under the optional
        // governance setting; the launch policy is instant recognition.
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

    /// @dev The FRV-FS-03 shape: a SMALL live staked base against a LARGE book, then ONE healthy
    ///      servicing payment sized off the book. Loan servicing is coupled to book principal, not
    ///      to sUSDfr supply, so an oversized delivery is the ordinary case, not a distressed one.
    ///      This is the state that drives the cap; nothing here is a loss or an attack.
    function _cappedHealthyDelivery() internal returns (uint256 id) {
        _stakeVault(alice, 1_000e18);
        id = _liveFilmFacility(500_000e18);
        uint256 baseBefore = vault.totalAssets();
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        _repay(id, 400_000e18, 0);
        assertGt(
            usdfr.balanceOf(address(vault)) - heldBefore,
            K * baseBefore,
            "PRECONDITION: the delivery must be oversized for the live base, or the cap never binds"
        );
        assertGt(vault.unvestedYield(), 0, "PRECONDITION: the cap must retain a stream, not kill vesting");
    }

    /// @dev A real senior entry through the real ERC-4626 path. Returns the shares minted.
    function _enterVault(address who, uint256 amount) internal returns (uint256 shares) {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    // ── the retained stream is a MINORITY of the vault's cash ────────────

    /// @notice THE PROPERTY, stated as the contract's own NatSpec states it: after the cap fires,
    ///         `unvestedYield() <= held/(K+1)` while `totalAssets() >= K*held/(K+1)`. Reverting the
    ///         retention to `mulDiv(held, K, K+1)` inverts both sides at once.
    ///
    ///         Asserted as ratios against the vault's own cash, so it holds at any scale and pins
    ///         no magic number.
    function test_causeF_cappedDeliveryRetainsAMinorityStreamAndAMajorityBase() public {
        _cappedHealthyDelivery();

        uint256 held = usdfr.balanceOf(address(vault));
        uint256 stream = vault.unvestedYield();
        uint256 base = vault.totalAssets();
        assertEq(stream + base, held, "recognized plus streamed must reconcile to the cash held");

        // the retention target itself: the withheld stream is at most 1/(K+1) of the cash
        assertLe(stream * (K + 1), held, "RETENTION REVERTED: the stream is not a minority of the vault's cash");
        // and its mirror: the deposit base the entry and exit prices are set on is the majority
        assertGe(base * (K + 1), K * held, "the entry base is no longer K/(K+1) of the vault's cash");
        // the distance to the fail-closed band, which is what the retention buys: a factor of K^2,
        // not zero. `_isDegenerate()` closes entry at `stream > K * base`.
        assertLe(stream * K, base, "PARKED ON THE FAIL-CLOSED BAND: the vault has no slack at all");

        // and entry is genuinely open, through the real path
        assertGt(vault.maxDeposit(bob), 0, "a healthy servicing payment must not close senior entry");
        assertGt(_enterVault(bob, 1_000e18), 0, "a depositor cannot enter after a capped yield delivery");
    }

    // ── THE USER-VISIBLE HARM: entry survives a realized senior loss ─────

    /// @notice THE CONSEQUENCE, driven end to end. A vault parked on the band by an ordinary yield
    ///         delivery is bricked by the very next wei to leave it. The realistic vector is the
    ///         loss cascade's layer-3 senior burn, which reduces the physical balance and never
    ///         re-caps, so the parked stream is left standing over a smaller base.
    ///
    ///         The loss used here is DELIBERATELY SMALL — 1,000e18 against a deposit base of
    ///         hundreds of thousands — and is absorbed comfortably under the shipped retention.
    ///         Under the reverted retention ANY non-zero loss closes entry, because the vault was
    ///         already sitting exactly on the boundary.
    function test_causeF_seniorEntrySurvivesARealizedLossAfterACappedDelivery() public {
        uint256 id = _cappedHealthyDelivery();

        // a small, ordinary realized senior loss through the real cascade
        uint256 loss = 1_000e18;
        assertLt(loss, vault.totalAssets() / 10, "the loss must be small relative to the base to be a fair test");
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _realizeLoss(id, loss, bytes32(0));

        // NOT VACUOUS: the loss really did burn senior principal out of the vault
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Defaulted), "facility defaulted");

        // the band the retention exists to stay clear of
        assertLe(
            vault.unvestedYield(),
            K * vault.totalAssets(),
            "SENIOR ENTRY IS IN THE FAIL-CLOSED BAND after an ordinary loss"
        );

        // THE HARM, through the real path: a depositor must still be able to enter
        assertGt(vault.maxDeposit(bob), 0, "VAULT ENTRY BRICKED by a small realized loss");
        assertGt(vault.maxMint(bob), 0, "VAULT MINT BRICKED by a small realized loss");
        uint256 shares = _enterVault(bob, 1_000e18);
        assertGt(shares, 0, "VAULT ENTRY BRICKED: the depositor received no shares");
        assertEq(vault.balanceOf(bob), shares, "the entrant holds the shares the deposit minted");
    }

    /// @notice THE SAME HARM, stated as the margin rather than as one loss size, so it cannot be
    ///         satisfied by a lucky choice of `loss`. The vault must tolerate a realized senior
    ///         loss of a MATERIAL fraction of its deposit base before entry closes. The shipped
    ///         retention tolerates ~89%; the reverted one tolerates zero.
    function test_causeF_lossToleranceBeforeEntryClosesIsAMaterialFractionOfTheBase() public {
        uint256 id = _cappedHealthyDelivery();
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 baseBefore = vault.totalAssets();
        // a quarter of the deposit base: catastrophic, but far from the ~89% the retention buys
        uint256 loss = baseBefore / 4;
        _realizeLoss(id, loss, bytes32(0));

        assertGt(vault.maxDeposit(bob), 0, "ENTRY CLOSED BY A 25% SENIOR LOSS: the stream cap has no tolerance left");
        assertGt(_enterVault(bob, 1_000e18), 0, "a depositor cannot enter after a 25% realized loss");
    }

    // ── the queue-pricing leg used the same wrong retention ──────────────

    /// @notice QUEUE PRICING. `prepareRedemptionPricing` runs the same cap against the balance that
    ///         remains after the settlement's whole outflow budget. The retention therefore sets
    ///         the EXIT price too, so a fix that repaired only the inflow leg would leave the queue
    ///         mispriced. Pinned on what a redeemer actually receives: the exit NAV must be struck
    ///         on the majority of the vault's cash, not on `1/(K+1)` of it.
    function test_causeF_queueSettlementPricesTheExitOnAMajorityBase() public {
        // Queue FIRST and serve the cooldown: the redeem cooldown exceeds the vesting window, so a
        // stream started before the request would have fully vested by settlement and this test
        // would be vacuous. A delivery landing against an already-eligible request is the routine
        // case — deliveries are continuous, settlement runs on the heartbeat.
        _stakeVault(alice, 1_000e18);
        uint256 id = _liveFilmFacility(500_000e18);

        uint256 shares = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        uint256 reqId = queue.requestRedeem(shares);
        vm.stopPrank();
        vm.warp(uint256(queue.eligibleToSettleAt(queue.head())) + 1);

        uint256 baseBefore = vault.totalAssets();
        uint256 heldPreDelivery = usdfr.balanceOf(address(vault));
        _repay(id, 400_000e18, 0);
        assertGt(
            usdfr.balanceOf(address(vault)) - heldPreDelivery,
            K * baseBefore,
            "PRECONDITION: the delivery must be oversized for the live base"
        );
        assertGt(vault.unvestedYield(), 0, "PRECONDITION: a live stream at settlement time");
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        uint256 supplyBefore = vault.totalSupply();

        queue.closeEpoch(10);
        vm.prank(alice);
        uint256 paid = queue.claim(reqId);
        assertGt(paid, 0, "PRECONDITION: the settlement must have paid the redeemer");

        // The REALIZED exit price per share. The epoch's fill is bounded by available liquidity, so
        // the absolute payout is not the signal — the price the filled shares were struck at is.
        // An exit priced on a base of `K/(K+1)` of the vault's cash pays `K/(K+1)` of the cash
        // backing each share; one priced on `1/(K+1)` pays a THIRD as much. Asserted with a 1%
        // tolerance for fee and rounding dust, so this pins the property, not a number.
        uint256 burned = supplyBefore - vault.totalSupply();
        assertGt(burned, 0, "PRECONDITION: the settlement must have burned shares");
        uint256 exitPricePerShare = paid * 1e18 / burned;
        uint256 cashPerShare = heldBefore * 1e18 / supplyBefore;
        assertGe(
            exitPricePerShare * (K + 1) * 100,
            K * cashPerShare * 99,
            "EXIT PRICED ON THE MINORITY BASE: the redeemer was paid off 1/(K+1) of the vault's cash"
        );

        // and the post-settlement state must still hold the boundary with the same K^2 margin,
        // so the NEXT redeemer and the next entrant are priced correctly too
        assertLe(
            vault.unvestedYield() * K,
            vault.totalAssets(),
            "POST-SETTLEMENT: the queue leg left the vault parked on the fail-closed band"
        );
        assertLe(
            vault.unvestedYield() * (K + 1),
            usdfr.balanceOf(address(vault)),
            "POST-SETTLEMENT: the retained stream is not a minority of the vault's cash"
        );
        assertGt(vault.maxDeposit(bob), 0, "an ordinary settlement must not close senior entry");
    }

    // ── the cascade's own capacity is set by the same base ───────────────

    /// @notice THIRD CONSEQUENCE, on the loss cascade rather than on entry. `realizeLoss` bounds
    ///         layer-3 absorption by `vault.totalAssets()`, so shrinking the base to `1/(K+1)` of
    ///         the vault's cash cuts the senior layer's absorption capacity by a factor of K —
    ///         a solvent vault fails loudly with `LossExceedsAbsorptionCapacity` on a loss it is
    ///         physically able to absorb.
    function test_causeF_seniorAbsorptionCapacityIsNotThrottledByTheRetainedStream() public {
        uint256 id = _cappedHealthyDelivery();
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        uint256 held = usdfr.balanceOf(address(vault));
        // half the vault's PHYSICAL cash: the senior layer holds it and must be able to absorb it
        uint256 loss = held / 2;
        assertLe(loss, vault.totalAssets(), "CAPACITY THROTTLED: the base cannot absorb half the vault's cash");
        _realizeLoss(id, loss, bytes32(0));
        assertGt(usdfr.balanceOf(address(vault)), 0, "the vault absorbed the loss and still holds cash");
    }
}
