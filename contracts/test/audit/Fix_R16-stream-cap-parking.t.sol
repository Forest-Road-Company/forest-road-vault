// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title AUDIT R16-01 / R16-02 — the stream cap must not park a HEALTHY vault on the entry guard
/// @notice R16-01 (HIGH). `sUSDfr._capStreamToBase` retained `K/(K+1)` of the vault's physical
///         USDfr, which lands the vault at EXACTLY `unvestedYield() == K * totalAssets()` whenever
///         the balance divides evenly — and `_isDegenerate`'s strict `>` leaves entry OPEN at that
///         point. That is the point of MAXIMUM tolerated skim: 75% of the vault's cash is excluded
///         from the entry price, so a fresh entrant buys shares against a base one quarter of real
///         backing and then captures a pro-rata slice of the excluded stream as it vests.
///
///         The state is not exotic. The FRV-FS-03 inflow leg CREATES it in a healthy vault: any
///         servicing payment that is large relative to the live staked base (loan servicing is
///         coupled to book principal, not to sUSDfr supply — that is the whole premise of
///         FRV-FS-03) drives the cap and parks the vault right there. The
///         `Config.SUSDFR_MAX_STRANDED_YIELD_RATIO` calibration NatSpec justified leaving the
///         `(0, K]` band open on the claim that its top is "only reachable while the withheld
///         stream is a MAJORITY of the vault, an already-catastrophic near-total-write-down state,
///         never a healthy one". That claim was FALSE, and this file is its counter-example.
///
///         R16-02 (HIGH, same contract). `_withdraw` ran the RC-03 re-cap AFTER `super._withdraw`,
///         i.e. after the vault's USDfr had already left, so every read taken between the outflow
///         and the re-cap — including anything an external transfer hook observes — saw the vault
///         outside its own boundary. `test_R1602_*` pins the recognition ahead of the transfer.
contract FixR16StreamCapParkingTest is CreditLayerFixture {
    uint64 internal constant OPTIONAL_STREAM_PERIOD = 7 days;
    uint256 internal constant K = Config.SUSDFR_MAX_STRANDED_YIELD_RATIO;

    /// @dev `sUSDfr.YieldInstantlyRecognized(uint256)`.
    bytes32 internal constant RECOGNIZED_TOPIC = keccak256("YieldInstantlyRecognized(uint256)");
    /// @dev ERC-20 `Transfer(address,address,uint256)`.
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

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

    function _distributeInterest(uint256 id, uint256 interest) internal returns (uint256 toVault) {
        uint256 heldBefore = usdfr.balanceOf(address(vault));
        _repay(id, interest, 0);
        toVault = usdfr.balanceOf(address(vault)) - heldBefore;
    }

    /// @dev The FRV-FS-03 shape, verbatim: a SMALL live staked base against a LARGE book, then one
    ///      healthy servicing payment sized off the book. This is the state the cap exists for, and
    ///      the state the old cap parked on the entry boundary.
    /// @return id The facility the payment came from.
    /// @return baseBefore The staked base the delivery landed against.
    function _oversizedHealthyDelivery() internal returns (uint256 id, uint256 baseBefore) {
        _stakeVault(alice, 1_000e18);
        id = _liveFilmFacility(500_000e18);
        baseBefore = vault.totalAssets();
        uint256 delivered = _distributeInterest(id, 400_000e18);
        assertGt(delivered, K * baseBefore, "PRECONDITION: the payment must be oversized for the live base");
        assertGt(vault.unvestedYield(), 0, "PRECONDITION: the cap must retain a stream, not kill vesting");
    }

    // ── R16-01: the parked point ─────────────────────────────────────────

    /// @dev THE FINDING, measured. After an oversized-but-healthy delivery the retained stream must
    ///      sit a factor of `K^2` INSIDE the entry guard (`stream <= base / K`), not ON it
    ///      (`stream == K * base`). Pre-fix this asserts `3*(3/4 held) <= (1/4 held)` and is RED.
    function test_R1601_cappedDeliveryParksStrictlyInsideTheEntryGuard() public {
        _oversizedHealthyDelivery();

        uint256 held = usdfr.balanceOf(address(vault));
        uint256 stream = vault.unvestedYield();
        uint256 base = vault.totalAssets();
        assertEq(stream + base, held, "recognized plus streamed reconciles to cash held");

        // the guard's own boundary, restated: entry closes at `stream >= K * base`
        assertLt(stream, K * base, "parked AT OR ABOVE the entry guard boundary");
        // and the fix's actual bound: the parked ratio is `1/K`, a factor of K^2 of headroom
        assertLe(stream * K, base, "PARKED ON THE MAX-SKIM BOUNDARY: stream is not <= base/K");
        // the excluded slice of the vault's cash is a MINORITY, which is what the (0,K] band's
        // acceptance argument always claimed and never delivered
        assertLt(stream * 2, held, "more than half the vault's cash is excluded from the entry price");

        assertGt(vault.maxDeposit(bob), 0, "a healthy payment must not close senior entry (FRV-FS-03)");
    }

    /// @dev THE ECONOMIC CONSEQUENCE. Entry now prices all physical USDfr, including the excluded
    ///      stream, so a newcomer cannot acquire value earned by incumbents as that stream vests.
    ///      This assertion is the surviving discriminator for the physical-balance repair: pricing
    ///      against realized `totalAssets()` again makes `bobValue > stake` and fails it.
    function test_R1601_entrantCannotSkimTheParkedStream() public {
        _oversizedHealthyDelivery();

        uint256 base = vault.totalAssets();
        uint256 aliceValueBefore = vault.convertToAssets(vault.balanceOf(alice));

        // A deposit equal to the realized base exercises the old transfer while remaining an
        // ordinary permissionless entry.
        uint256 stake = base - (base % 1e12); // whole USDC units for the KYC-gated mint helper
        _stakeVault(bob, stake);

        // let the retained stream vest in full, then value the entrant's position
        vm.warp(block.timestamp + uint256(OPTIONAL_STREAM_PERIOD) + 1);
        assertEq(vault.unvestedYield(), 0, "the stream has fully vested");

        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        assertLe(bobValue, stake, "ENTRANT ACQUIRED INCUMBENT STREAM VALUE");
        // The incumbent's value must not be the mirror-image funding source.
        uint256 aliceValueAfter = vault.convertToAssets(vault.balanceOf(alice));
        assertGt(aliceValueAfter, aliceValueBefore, "incumbent must still gain as their own stream vests");
    }

    /// @dev The `>` -> `>=` half. `_isDegenerate` must CLOSE entry at exactly
    ///      `unvestedYield() == K * totalAssets()` — the maximum skim the band tolerates. The state
    ///      is built by shrinking the vault's cash under a live stream (what a realized senior loss
    ///      does) until the ratio lands exactly on the boundary; the R15-01 rate band is asserted
    ///      NOT to fire, so the closure can only come from the stream band under test.
    function test_R1601_entryIsClosedExactlyOnTheGuardBoundary() public {
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(500_000e18);
        _distributeInterest(id, 50_000e18);

        // land the live stream on a multiple of K so the boundary is expressible in wei
        uint256 stream;
        for (uint256 i = 0; i < 256; ++i) {
            stream = vault.unvestedYield();
            if (stream != 0 && stream % K == 0) break;
            vm.warp(block.timestamp + 1);
        }
        assertTrue(stream != 0 && stream % K == 0, "could not land a K-divisible stream");

        // shrink the cash under the stream until `stream == K * base` EXACTLY
        uint256 target = stream + stream / K; // held such that held - stream == stream / K
        uint256 held = usdfr.balanceOf(address(vault));
        assertGt(held, target, "there is cash to remove");
        vm.prank(address(vault));
        usdfr.transfer(bob, held - target);

        uint256 base = vault.totalAssets();
        assertEq(vault.unvestedYield(), stream, "the stream itself must not have moved");
        assertEq(stream, K * base, "PRECONDITION: sitting on the boundary, exactly");

        // NOT vacuous: the R15-01 collapsed-rate band must not be what closes entry here
        uint256 realizedRate =
            (10 ** vault.decimals()) * (base + 1) / (vault.totalSupply() + 10 ** (vault.decimals() - usdfr.decimals()));
        assertGe(
            realizedRate * Config.SUSDFR_DEGENERATE_RATE_DIVISOR,
            10 ** usdfr.decimals(),
            "R15-01 rate band would close this state on its own: test would be vacuous"
        );
        assertGt(base, 0, "and the zero-base clause is not what closes it either");

        uint256 supply = vault.totalSupply();
        _mintUSDfrTo(bob, 1e18);
        vm.startPrank(bob);
        usdfr.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, base));
        vault.deposit(1e18, bob);
        vm.expectRevert(abi.encodeWithSelector(SUSDfr.SUSDfr_DegenerateSharePrice.selector, supply, base));
        vault.mint(1e18, bob);
        vm.stopPrank();

        assertEq(vault.maxDeposit(bob), 0, "ENTRY OPEN ON THE MAX-SKIM BOUNDARY");
        assertEq(vault.maxMint(bob), 0, "MINT OPEN ON THE MAX-SKIM BOUNDARY");
    }

    // ── R16-02: the outflow re-cap must precede the outflow ──────────────

    /// @dev The RC-03 re-cap ran AFTER `super._withdraw`, so the vault spent the whole burn-and-
    ///      transfer sequence outside the boundary its own NatSpec claimed held "at all times".
    ///      Pinned on the log ORDER: `YieldInstantlyRecognized` must precede the USDfr transfer
    ///      that carries the settlement out of the vault.
    function test_R1602_outflowRecapIsAppliedBeforeTheAssetsLeave() public {
        // Queue FIRST and serve the cooldown: the 21-day hold exceeds the 7-day vesting window, so
        // a stream started before the request would have fully vested by settlement and the test
        // would be vacuous. A delivery landing against an already-eligible request is the routine
        // case (deliveries are continuous, settlement runs on the heartbeat).
        _stakeVault(alice, 1_000e18);
        uint256 id = _liveFilmFacility(500_000e18);

        uint256 shares = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.approve(address(queue), shares);
        queue.requestRedeem(shares);
        vm.stopPrank();
        vm.warp(uint256(queue.eligibleToSettleAt(queue.head())) + 1);

        uint256 baseBefore = vault.totalAssets();
        uint256 delivered = _distributeInterest(id, 400_000e18);
        assertGt(delivered, K * baseBefore, "PRECONDITION: the payment must be oversized for the live base");
        assertGt(vault.unvestedYield(), 0, "PRECONDITION: a live stream at settlement time");

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);
        vm.recordLogs();
        queue.closeEpoch(10);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);

        int256 recognizedAt = -1;
        int256 outflowAt = -1;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == RECOGNIZED_TOPIC && recognizedAt < 0) {
                recognizedAt = int256(i);
            }
            if (
                logs[i].emitter == address(usdfr) && logs[i].topics[0] == TRANSFER_TOPIC && logs[i].topics.length == 3
                    && address(uint160(uint256(logs[i].topics[1]))) == address(vault) && outflowAt < 0
            ) {
                outflowAt = int256(i);
            }
        }
        assertGe(recognizedAt, 0, "PRECONDITION: the outflow re-cap must have fired at all");
        assertGe(outflowAt, 0, "PRECONDITION: the settlement must have moved USDfr out of the vault");
        assertLt(recognizedAt, outflowAt, "RE-CAP RAN AFTER THE ASSETS LEFT THE VAULT");

        // and the boundary the re-cap exists to hold, holds after the settlement
        assertLe(vault.unvestedYield() * K, vault.totalAssets(), "post-settlement stream is not inside base/K");
        assertGt(vault.maxDeposit(bob), 0, "an ordinary settlement must not close senior entry (RC-03)");

        // R16-02 SIDE-CONDITION. Moving the re-cap ahead of `super._withdraw` puts the recognized
        // yield inside the marked NAV that `_adjustHighWaterMarkForAssetFlow` reads immediately
        // afterwards. Its rate FLOOR would then ratchet the high-water mark over profit that has
        // never been fee-checkpointed, permanently waiving the 10% performance fee on it — a
        // revenue leak the old (post-outflow) ordering avoided only by accident of running last.
        // `_setHighWaterMarkForAssetHurdle` therefore excludes the recognition from that floor.
        // Pin the economic property directly rather than comparing a floor-rounded live rate to a
        // ceil-rounded hurdle (which may differ by two wei without waiving anything). Settlement
        // checkpoints the fee in the same transaction, so a later `accrueFees()` correctly returns
        // zero; the recipient's share delta is the non-vacuous proof.
        assertGt(feeSharesAfter, feeSharesBefore, "HIGH-WATER MARK ABSORBED THE OUTFLOW RECOGNITION: fee waived");
    }
}
