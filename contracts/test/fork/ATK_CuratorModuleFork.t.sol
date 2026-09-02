// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @title ATK_CuratorModuleFork — adversarial assault on CuratorModule (cascade layer 1) on a
///        pinned mainnet fork against the REAL Deploy topology and REAL USDC.
///
/// @notice AUTHORISED assessment of the owner's own pre-audit code. Local fork only; nothing is
///         broadcast and no real value moves. Each test ATTEMPTS a concrete exploit and makes the
///         outcome unambiguous: where the module blocks the attack it asserts the exact custom
///         error; where an attack would succeed it asserts the violated state.
///
///         The three invariants under fire (CLAUDE.md 1.3):
///           I1  curator first-loss absorbs BEFORE the senior layer;
///           I2  a withdrawal cannot ESCAPE a loss that is already pending (declared default OR an
///               unattested past-due mark the conservative senior NAV already credits);
///           I3  a closed-round claim cannot DOUBLE-PAY (settling re-attributes, never mints).
///
///         Permissionless entry points attacked hardest: `postFirstLoss`, `withdrawFirstLoss`,
///         `claimClosedRound`. `ops == address(this)` is the approved anchor curator on every class
///         and holds DEFAULT_ADMIN (fork shape), so governance-gated levers are reachable to set up
///         hostile states; the ATTACK is always launched from the permissionless surface.
contract ATK_CuratorModuleForkTest is ForkLifecycleFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS; // class 1, receivable

    // ─────────────────────────────────────────────────────────────────────
    // I2 (+I1): a curator cannot pull first-loss out ahead of a realized loss
    // ─────────────────────────────────────────────────────────────────────

    /// @notice COMPOSE: post first-loss, create live exposure, then declare a default and try to
    ///         run the capital out the door before it is asked to absorb. The headroom rule locks
    ///         it while exposure is live, and the R4-EC2 default freeze locks it once a loss is
    ///         pending — even the slice that was genuinely withdrawable a block earlier. Finally the
    ///         realized loss must land on curator capital FIRST (I1), never on the senior layer.
    function test_fork_withdrawCannotEscapeADeclaredDefaultLoss() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18); // senior base — the layer that must stay untouched

        _postFL(ops, FILM, 500_000e18);
        assertEq(curator.poolBalance(FILM), 500_000e18, "layer-1 capital posted");

        // No exposure yet -> the whole pool is withdrawable (nothing to subordinate to).
        assertEq(curator.headroom(FILM), 500_000e18, "no exposure: full pool is free");

        // Create 300k of live exposure. Subordination now locks capital up to min(target, exposure).
        uint256 id = _originateAndFund(300_000e18);
        assertEq(curator.headroom(FILM), 200_000e18, "headroom == pool - min(target, exposure) = 500k - 300k");

        // CROSS-USER / access: a party that is not an approved curator cannot post into the pool.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_NotApprovedCurator.selector, FILM, carol));
        curator.postFirstLoss(FILM, 1);

        // A withdrawal of the OVER-headroom slice is refused while exposure stands, exact error.
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, 300_000e18, 200_000e18)
        );
        curator.withdrawFirstLoss(FILM, 300_000e18);

        // Now a loss becomes PENDING. The 200k that was free a moment ago must be frozen: a curator
        // must not front-run realizeLoss and duck the loss it is layer 1 for.
        _declareDefault(id, keccak256("atk-declared"));
        assertEq(curator.unresolvedDefaults(FILM), 1, "the default froze the class");

        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        curator.withdrawFirstLoss(FILM, 200_000e18);

        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        curator.withdrawFirstLoss(FILM, 1);

        // I1: the realized loss lands on curator capital FIRST; the senior layer is untouched.
        uint256 seniorAssetsBefore = vault.totalAssets();
        uint256 supplyBefore = usdfr.totalSupply();
        _realizeLoss(id, 100_000e18, bytes32(0));
        assertEq(curator.poolBalance(FILM), 400_000e18, "layer 1 absorbed the whole loss");
        assertEq(vault.totalAssets(), seniorAssetsBefore, "SENIOR IS NEVER SUBORDINATED TO JUNIOR CAPITAL");
        assertEq(supplyBefore - usdfr.totalSupply(), 100_000e18, "exactly the loss was burned against layer 1");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing invariant holds after realization");
    }

    // ─────────────────────────────────────────────────────────────────────
    // I2 on the ONE loss path with no freeze: the unattested past-due mark
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The SWEEP-2 CSG-F1 escape. `markPastDue` is permissionless and deliberately does NOT
    ///         freeze the class, and a lowered first-loss target manufactures headroom. Before the
    ///         marked floor, a curator could then withdraw capital the conservative senior NAV was
    ///         ALREADY crediting as layer 1. The attack: lower the target, watch the headroom open,
    ///         let anyone mark the facility past due, then try to walk the freed capital out — it
    ///         must now be locked by the marked floor, with no default freeze in play.
    function test_fork_withdrawCannotEscapeAnUnattestedPastDueMark() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);

        _postFL(ops, FILM, 500_000e18);
        uint256 id = _originateAndFund(800_000e18); // 800k live exposure

        // Governance lever (no lower bound): drop the target below the pool to open headroom.
        curator.setFirstLossTarget(FILM, 100_000e18);
        assertEq(curator.headroom(FILM), 400_000e18, "lowered target manufactures 400k of headroom");

        // Wait the facility past its payment-due + class grace window, then anyone marks it.
        uint256 due = uint256(bridge.facility(id).nextPaymentDue);
        uint256 grace = uint256(defaultManager.graceWindow(FILM));
        _warp(due + grace + 1 - block.timestamp);
        vm.prank(carol); // permissionless: no role, not even KYC'd
        defaultManager.markPastDue(id);

        // The mark freezes NOTHING and does not trip the custody freeze — it lands purely as a
        // marked floor on the credited capital.
        assertEq(curator.unresolvedDefaults(FILM), 0, "past-due does not arm the default freeze");
        assertFalse(curator.custodyFreezeActive(), "past-due does not arm the custody freeze");
        assertEq(curator.headroom(FILM), 0, "the marked floor swallowed all headroom the target opened");

        // The capital that was withdrawable a moment ago is now refused with the exact error.
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, 400_000e18, 0));
        curator.withdrawFirstLoss(FILM, 400_000e18);

        // Even one wei of the marked capital cannot leave.
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, 1, 0));
        curator.withdrawFirstLoss(FILM, 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // FIRST-DEPOSITOR / DONATION / share-inflation on the layer-1 accounting
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The classic ERC4626 inflation attack, adapted to layer 1: post a dust stake as the
    ///         first curator, DONATE a large USDfr balance straight to the module to try to inflate
    ///         the share price, then let a victim curator post. If accounting trusted `balanceOf`
    ///         the victim's shares would round to near-zero and the attacker would own the pool.
    ///         Because the pool tracks an INTERNAL balance, the donation is inert: the victim gets
    ///         fair shares, and the attacker can never skim the donated USDfr back out.
    function test_fork_donationCannotInflateOrStealCuratorShares() public onFork {
        _mintFromUSDC(alice, 3_000_000e6);
        _stake(alice, 1_000_000e18);

        curator.setCuratorApproved(FILM, bob, true); // the victim curator

        // Attacker (ops) needs USDfr both to seed a dust stake and to donate.
        _giveUSDfr(ops, 100_000e18);

        // 1) dust first-loss stake.
        _postHeld(ops, FILM, 1e18);
        // 2) donate a large USDfr balance directly to the module (the "inflation" step).
        vm.prank(ops);
        usdfr.transfer(address(curator), 50_000e18);

        // Internal accounting ignored the donation entirely.
        assertEq(curator.poolBalance(FILM), 1e18, "donation did NOT enter the internal pool balance");
        assertEq(
            usdfr.balanceOf(address(curator)),
            50_001e18,
            "the donated USDfr physically arrived but is unaccounted (owned by nobody)"
        );

        // 3) victim posts a normal amount and MUST receive fair, uninflated shares.
        _postFL(bob, FILM, 100_000e18);
        assertEq(curator.postedOf(FILM, bob), 100_000e18, "VICTIM WAS NOT DILUTED: fair 1:1 shares");
        assertEq(curator.postedOf(FILM, ops), 1e18, "attacker's stake did NOT absorb the donation");
        assertEq(curator.poolBalance(FILM), 100_000e18 + 1e18, "pool == the two real posts, donation excluded");

        // 4) the attacker cannot withdraw the donation: the stake caps the exit at its own value.
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_InsufficientStake.selector, FILM, ops, 1e18 + 1, 1e18)
        );
        curator.withdrawFirstLoss(FILM, 1e18 + 1);

        // The legitimate dust IS withdrawable (no exposure => full headroom), and only the dust.
        vm.prank(ops);
        curator.withdrawFirstLoss(FILM, 1e18);
        assertEq(curator.postedOf(FILM, ops), 0, "attacker recovered only its own dust, never the donation");
        assertEq(
            usdfr.balanceOf(address(curator)) - curator.poolBalance(FILM),
            50_000e18,
            "the donated 50k is stranded (unaccounted) in the module forever"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // I3: a closed-round residual claim cannot be double-paid
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The SWEEP-4 S4-R1 surface. Collapse the share price to near-zero with an almost-total
    ///         absorption, recapitalise to CLOSE the round (snapshotting a residual claim), then
    ///         hammer the permissionless `claimClosedRound` from a hostile caller against BOTH
    ///         curators' stale stakes. Settling must move NO value and the sum of every curator's
    ///         claim must never exceed the pool — i.e. the carried residual can be paid exactly once.
    function test_fork_closedRoundClaimCannotDoublePay() public onFork {
        _mintFromUSDC(alice, 5_000_000e6);
        _stake(alice, 2_000_000e18);
        curator.setCuratorApproved(FILM, bob, true);

        // Pre-mint ALL first-loss USDfr up front: minting is closed once the protocol is marked
        // under par by the declared default, so the recapitalisation post must spend held balance.
        _giveUSDfr(ops, 300_000e18);
        _giveUSDfr(bob, 200_000e18);

        _postHeld(ops, FILM, 100_000e18);
        _postHeld(bob, FILM, 100_000e18);
        assertEq(curator.poolBalance(FILM), 200_000e18, "two curators seed the round");
        assertEq(curator.poolShares(FILM), 200_000e18, "shares minted 1:1 into a fresh pool");

        // A near-total absorption: leave a 100000-wei residual so the pool is economically wiped
        // (share price <= 1e-18) yet a non-trivial residual is carried across the close.
        uint256 id = _originateAndFund(800_000e18);
        _declareDefault(id, keccak256("atk-s4-declared"));
        _realizeLoss(id, 200_000e18 - 100_000, bytes32(0));
        assertEq(curator.poolBalance(FILM), 100_000, "the pool collapsed to a dust residual");
        assertEq(curator.poolRound(FILM), 0, "the round only advances on the next POST");

        // Recapitalise from HELD USDfr -> closes the collapsed round, snapshotting the residual.
        _postHeld(ops, FILM, 100_000e18);
        assertEq(curator.poolRound(FILM), 1, "recapitalisation advanced the round (a close happened)");

        uint256 pool0 = curator.poolBalance(FILM);
        uint256 sumBefore = curator.postedOf(FILM, ops) + curator.postedOf(FILM, bob);
        assertLe(sumBefore, pool0, "no double-pay: summed claims never exceed the pool");

        // ATTACK: pound claimClosedRound from a hostile third party on both stale stakes. It must be
        // value-neutral and idempotent no matter how it is interleaved or repeated.
        address[2] memory targets = [ops, bob];
        for (uint256 k = 0; k < 8; ++k) {
            address t = targets[k % 2];
            vm.prank(carol); // permissionless settler, holds nothing to gain
            curator.claimClosedRound(FILM, t);

            assertEq(curator.poolBalance(FILM), pool0, "claimClosedRound MOVED VALUE (it must only re-attribute)");
            uint256 sum = curator.postedOf(FILM, ops) + curator.postedOf(FILM, bob);
            assertLe(sum, curator.poolBalance(FILM), "DOUBLE-PAY: summed claims exceeded the pool");
        }

        // Idempotency, stated sharply: a settled stake re-settled cannot grow.
        vm.prank(carol);
        curator.claimClosedRound(FILM, bob);
        uint256 bobPosted = curator.postedOf(FILM, bob);
        vm.prank(carol);
        curator.claimClosedRound(FILM, bob);
        assertEq(curator.postedOf(FILM, bob), bobPosted, "settling twice cannot double-credit the residual");

        // The carried residual is fully consumed: no snapshot capacity remains to be re-claimed.
        (, uint256 carriedLeft) = curator.closedRound(FILM, 0);
        assertEq(carriedLeft, 0, "the closed-round carry was distributed exactly once, then exhausted");
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "backing invariant holds throughout");
    }

    // ─────────────────────────────────────────────────────────────────────
    // REENTER: a hostile points hook cannot re-enter the value-moving paths
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The only attacker-influenceable external call `postFirstLoss` makes is the fail-open
    ///         points hook. Install a hostile module that re-enters `postFirstLoss` from inside the
    ///         hook and prove the `nonReentrant` guard rejects it — the outer post applies exactly
    ///         once, with no reentrant double-mint of shares or double-transfer.
    function test_fork_hostilePointsHookCannotReenterLayerOne() public onFork {
        _mintFromUSDC(alice, 2_000_000e6);
        _stake(alice, 500_000e18);

        HostileReenterer hostile = new HostileReenterer(address(curator));
        curator.setPointsModule(address(hostile)); // governance lever (test holds DEFAULT_ADMIN)

        _giveUSDfr(ops, 100_000e18);
        _postHeld(ops, FILM, 100_000e18);

        assertTrue(hostile.reentryAttempted(), "the hostile hook must have fired inside postFirstLoss");
        assertEq(
            hostile.lastRevertSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "a reentrant postFirstLoss was rejected by the nonReentrant guard"
        );
        assertEq(curator.poolBalance(FILM), 100_000e18, "exactly one post applied; no reentrant double-post");
        assertEq(curator.postedOf(FILM, ops), 100_000e18, "the caller's stake is exactly its single post");
    }

    // ─────────────────────────────────────────────────────────────────────
    // helpers (private to this file; the shared fixture is untouched)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Mints exactly `usdfrAmount` (18-dec) USDfr to `who` through the real KYC-gated mint
    ///      (1:1, no fee). Must be called while the protocol is at/above par (mint closes under par).
    function _giveUSDfr(address who, uint256 usdfrAmount) internal {
        _mintFromUSDC(who, usdfrAmount / 1e12);
    }

    /// @dev Posts `amount` first-loss from `who`'s already-held USDfr balance.
    function _postHeld(address who, uint256 classId, uint256 amount) internal {
        vm.startPrank(who);
        usdfr.approve(address(curator), amount);
        curator.postFirstLoss(classId, amount);
        vm.stopPrank();
    }

    /// @dev Mint-then-post: only safe before any default marks the protocol under par.
    function _postFL(address who, uint256 classId, uint256 amount) internal {
        _giveUSDfr(who, amount);
        _postHeld(who, classId, amount);
    }
}

/// @dev A hostile IPointsModule shim. `setPointsModule` requires code but never checks the
///      interface, so this only needs the two hooks the curator actually invokes. On the
///      stake-change hook it re-enters `postFirstLoss` and records the revert selector, proving the
///      `nonReentrant` guard fired rather than that the call merely failed for another reason.
contract HostileReenterer {
    ICuratorModule private immutable curatorModule;
    bool public reentryAttempted;
    bytes4 public lastRevertSelector;

    constructor(address curator_) {
        curatorModule = ICuratorModule(curator_);
    }

    function onCuratorStakeChange(address, uint256, uint256) external {
        reentryAttempted = true;
        try curatorModule.postFirstLoss(1, 1) {
            // Reentry unexpectedly SUCCEEDED. Leave `lastRevertSelector` at its zero default so the
            // test's selector assertion fails loudly rather than reading a stale guard match.
        } catch (bytes memory err) {
            lastRevertSelector = bytes4(err);
        }
    }

    function onCuratorLoss(uint256, uint256, uint256) external {}
}
