// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {CuratorModule} from "../../src/CuratorModule.sol";
import {ICuratorModule} from "../../src/interfaces/ICuratorModule.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

contract CuratorModuleTest is CreditLayerFixture {
    uint256 internal constant FILM = 1; // Config.CLASS_FILM_TAX_CREDITS

    // ── initialize ───────────────────────────────────────────────────────

    function test_initialize_zeroAddressReverts() public {
        CuratorModule impl = new CuratorModule();
        vm.expectRevert(ICuratorModule.Curator_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CuratorModule.initialize,
                (address(0), guardian, admin, address(usdfr), address(registry), address(vault))
            )
        );
        vm.expectRevert(ICuratorModule.Curator_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CuratorModule.initialize, (admin, guardian, admin, address(0), address(registry), address(vault))
            )
        );
        vm.expectRevert(ICuratorModule.Curator_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CuratorModule.initialize, (admin, guardian, admin, address(usdfr), address(0), address(vault))
            )
        );
        vm.expectRevert(ICuratorModule.Curator_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                CuratorModule.initialize, (admin, guardian, admin, address(usdfr), address(registry), address(0))
            )
        );
    }

    function test_initialize_seedsDefaultTargetsForAllFiveClasses() public view {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            assertEq(curator.firstLossTarget(c), Config.DEFAULT_FIRST_LOSS_PER_CLASS, "ADR-0004 default target");
        }
    }

    function test_initialize_wiresModules() public view {
        (address usdfrAddr, address registryAddr, address feeVaultAddr) = curator.modules();
        assertEq(usdfrAddr, address(usdfr));
        assertEq(registryAddr, address(registry));
        assertEq(feeVaultAddr, address(vault));
    }

    // ── governance: curator approval + targets ───────────────────────────

    function test_setCuratorApproved_setsAndEmits() public {
        address newCurator = makeAddr("newCurator");
        assertFalse(curator.isApprovedCurator(FILM, newCurator));
        vm.expectEmit(true, true, false, true);
        emit ICuratorModule.CuratorApproved(FILM, newCurator, true);
        vm.prank(admin);
        curator.setCuratorApproved(FILM, newCurator, true);
        assertTrue(curator.isApprovedCurator(FILM, newCurator));

        vm.prank(admin);
        curator.setCuratorApproved(FILM, newCurator, false);
        assertFalse(curator.isApprovedCurator(FILM, newCurator));
    }

    function test_setCuratorApproved_zeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(ICuratorModule.Curator_ZeroAddress.selector);
        curator.setCuratorApproved(FILM, address(0), true);
    }

    function test_setCuratorApproved_unknownClassReverts() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_UnknownClass.selector, 0));
        curator.setCuratorApproved(0, anchorCurator, true);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_UnknownClass.selector, 6));
        curator.setCuratorApproved(6, anchorCurator, true);
        vm.stopPrank();
    }

    function test_setCuratorApproved_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, servicer, bytes32(0))
        );
        vm.prank(servicer);
        curator.setCuratorApproved(FILM, servicer, true);
    }

    function test_setFirstLossTarget_setsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit ICuratorModule.FirstLossTargetSet(FILM, 25_000_000e18);
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 25_000_000e18);
        assertEq(curator.firstLossTarget(FILM), 25_000_000e18);
    }

    function test_setFirstLossTarget_unknownClassReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_UnknownClass.selector, 6));
        curator.setFirstLossTarget(6, 1e18);
    }

    function test_setFirstLossTarget_onlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, anchorCurator, bytes32(0))
        );
        vm.prank(anchorCurator);
        curator.setFirstLossTarget(FILM, 1e18);
    }

    // ── postFirstLoss ────────────────────────────────────────────────────

    function test_postFirstLoss_movesUSDfrAndMintsShares() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        assertEq(curator.poolBalance(FILM), 1_000_000e18);
        assertEq(curator.postedOf(FILM, anchorCurator), 1_000_000e18);
        assertEq(usdfr.balanceOf(address(curator)), 1_000_000e18);
        assertEq(usdfr.balanceOf(anchorCurator), 0);
    }

    function test_postFirstLoss_emitsWithShares() public {
        _mintUSDfrTo(anchorCurator, 500e18);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), 500e18);
        vm.expectEmit(true, true, false, true);
        emit ICuratorModule.FirstLossPosted(FILM, anchorCurator, 500e18, 500e18, 0); // first post: 1:1 shares, round 0
        curator.postFirstLoss(FILM, 500e18);
        vm.stopPrank();
    }

    function test_postFirstLoss_notApprovedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_NotApprovedCurator.selector, FILM, alice));
        vm.prank(alice);
        curator.postFirstLoss(FILM, 1e18);
        // secondCurator is approved for film only — class 2 must reject them
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_NotApprovedCurator.selector, 2, secondCurator));
        vm.prank(secondCurator);
        curator.postFirstLoss(2, 1e18);
    }

    function test_postFirstLoss_zeroAmountReverts() public {
        vm.expectRevert(ICuratorModule.Curator_ZeroAmount.selector);
        vm.prank(anchorCurator);
        curator.postFirstLoss(FILM, 0);
    }

    function test_postFirstLoss_secondCuratorSharesProRata() public {
        _postFirstLoss(anchorCurator, FILM, 300e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        assertEq(curator.poolBalance(FILM), 400e18);
        assertEq(curator.poolShares(FILM), 400e18, "1:1 share price at start");
        assertEq(curator.postedOf(FILM, anchorCurator), 300e18);
        assertEq(curator.postedOf(FILM, secondCurator), 100e18);
        // share price never exceeds 1 (invariant-fuzzed too): shares >= balance
        assertGe(curator.poolShares(FILM), curator.poolBalance(FILM));
    }

    function test_postFirstLoss_afterPartialAbsorption_pricesSharesCorrectly() public {
        _postFirstLoss(anchorCurator, FILM, 400e18);
        // absorb half: share price 0.5
        vm.prank(address(defaultManager));
        curator.absorbLoss(FILM, 200e18);
        // a fresh 100e18 post must buy 200e18 shares (not dilute unfairly)
        _postFirstLoss(secondCurator, FILM, 100e18);
        assertEq(curator.poolBalance(FILM), 300e18);
        assertEq(curator.postedOf(FILM, anchorCurator), 200e18, "anchor keeps its diluted value");
        assertEq(curator.postedOf(FILM, secondCurator), 100e18, "fresh post keeps full value");
    }

    // ── withdrawFirstLoss ────────────────────────────────────────────────

    function test_withdrawFirstLoss_returnsCapital() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        vm.expectEmit(true, true, false, true);
        emit ICuratorModule.FirstLossWithdrawn(FILM, anchorCurator, 400e18, 400e18, 0);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 400e18);
        assertEq(curator.poolBalance(FILM), 600e18);
        assertEq(curator.postedOf(FILM, anchorCurator), 600e18);
        assertEq(usdfr.balanceOf(anchorCurator), 400e18);
    }

    function test_withdrawFirstLoss_zeroAmountReverts() public {
        vm.expectRevert(ICuratorModule.Curator_ZeroAmount.selector);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 0);
    }

    function test_withdrawFirstLoss_moreThanStakeReverts() public {
        _postFirstLoss(anchorCurator, FILM, 100e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        // pool headroom is 200e18 (no exposure), but anchor only owns 100e18 of it
        vm.expectRevert(
            abi.encodeWithSelector(
                ICuratorModule.Curator_InsufficientStake.selector, FILM, anchorCurator, 101e18, 100e18
            )
        );
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 101e18);
    }

    function test_withdrawFirstLoss_headroomBindsWithLiveExposure() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        uint256 id = _liveFilmFacility(600_000e18);
        assertEq(curator.requiredFirstLoss(FILM), 600_000e18, "required = min(target, exposure)");
        assertEq(curator.headroom(FILM), 400_000e18);

        // withdrawing beyond headroom reverts even though the stake is larger
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, 400_001e18, 400_000e18)
        );
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 400_001e18);

        // exactly the headroom passes
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 400_000e18);
        assertEq(curator.poolBalance(FILM), 600_000e18);

        // full repayment frees the rest
        _repay(id, 0, 600_000e18);
        assertEq(curator.requiredFirstLoss(FILM), 0);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 600_000e18);
        assertEq(curator.poolBalance(FILM), 0);
    }

    function test_requiredFirstLoss_cappedByTarget() public {
        // exposure above the $10M target: requirement caps at the target
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 500_000e18);
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        _liveFilmFacility(600_000e18);
        assertEq(curator.requiredFirstLoss(FILM), 500_000e18, "capped at target");
        assertEq(curator.headroom(FILM), 500_000e18);
    }

    function test_headroom_zeroWhenPoolBelowRequirement() public {
        _postFirstLoss(anchorCurator, FILM, 100_000e18);
        _liveFilmFacility(600_000e18);
        // pool (100k) < required (600k): nothing withdrawable
        assertEq(curator.headroom(FILM), 0);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_HeadroomExceeded.selector, FILM, 1, 0));
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1);
    }

    // ── absorbLoss (cascade layer 1) ─────────────────────────────────────

    function test_absorbLoss_partialPoolAbsorbsAll() public {
        _postFirstLoss(anchorCurator, FILM, 1_000e18);
        vm.expectEmit(true, false, false, true);
        emit ICuratorModule.LossAbsorbed(FILM, 600e18, 600e18, 0);
        vm.prank(address(defaultManager));
        (uint256 absorbed, uint256 residual) = curator.absorbLoss(FILM, 600e18);
        assertEq(absorbed, 600e18);
        assertEq(residual, 0);
        assertEq(curator.poolBalance(FILM), 400e18);
        // absorbed USDfr moved to the caller (DefaultManager burns it in real flows)
        assertEq(usdfr.balanceOf(address(defaultManager)), 600e18);
    }

    function test_absorbLoss_lossBeyondPoolReturnsResidual() public {
        _postFirstLoss(anchorCurator, FILM, 500e18);
        vm.prank(address(defaultManager));
        (uint256 absorbed, uint256 residual) = curator.absorbLoss(FILM, 800e18);
        assertEq(absorbed, 500e18);
        assertEq(residual, 300e18);
        assertEq(curator.poolBalance(FILM), 0);
    }

    function test_absorbLoss_emptyPoolAbsorbsNothing() public {
        vm.prank(address(defaultManager));
        (uint256 absorbed, uint256 residual) = curator.absorbLoss(FILM, 800e18);
        assertEq(absorbed, 0);
        assertEq(residual, 800e18);
    }

    function test_absorbLoss_zeroLossReverts() public {
        vm.prank(address(defaultManager));
        vm.expectRevert(ICuratorModule.Curator_ZeroAmount.selector);
        curator.absorbLoss(FILM, 0);
    }

    function test_absorbLoss_onlyCreditRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, anchorCurator, Roles.CREDIT_ROLE
            )
        );
        vm.prank(anchorCurator);
        curator.absorbLoss(FILM, 1e18);
    }

    function test_absorbLoss_dilutesAllCuratorsProRata() public {
        _postFirstLoss(anchorCurator, FILM, 300e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        vm.prank(address(defaultManager));
        curator.absorbLoss(FILM, 200e18); // half the pool
        assertEq(curator.postedOf(FILM, anchorCurator), 150e18, "anchor bears 3/4 of the loss");
        assertEq(curator.postedOf(FILM, secondCurator), 50e18, "second bears 1/4");
    }

    // ── default freeze (audit R4-EC2) ────────────────────────────────────

    function test_freezeOnDefault_blocksWithdrawAndCounts() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        assertEq(curator.unresolvedDefaults(FILM), 0);

        vm.expectEmit(true, false, false, true);
        emit ICuratorModule.ClassDefaultFrozen(FILM, 1);
        vm.prank(address(defaultManager));
        curator.freezeOnDefault(FILM);
        assertEq(curator.unresolvedDefaults(FILM), 1);

        // any withdrawal (even within headroom) is now frozen
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);

        // the freeze is class-scoped: other classes stay open
        assertEq(curator.unresolvedDefaults(2), 0, "freeze does not spill to other classes");
    }

    function test_freezeOnDefault_onlyCreditRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, anchorCurator, Roles.CREDIT_ROLE
            )
        );
        vm.prank(anchorCurator);
        curator.freezeOnDefault(FILM);
    }

    function test_freezeOnDefault_unknownClassReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_UnknownClass.selector, uint256(99)));
        vm.prank(address(defaultManager));
        curator.freezeOnDefault(99);
    }

    function test_liftDefaultFreeze_restoresWithdrawals() public {
        _postFirstLoss(anchorCurator, FILM, 1_000_000e18);
        // two concurrent defaults on the class → count 2
        vm.startPrank(address(defaultManager));
        curator.freezeOnDefault(FILM);
        curator.freezeOnDefault(FILM);
        vm.stopPrank();
        assertEq(curator.unresolvedDefaults(FILM), 2);

        // one lift is not enough — still frozen
        vm.expectEmit(true, false, false, true);
        emit ICuratorModule.ClassDefaultFreezeLifted(FILM, 1);
        vm.prank(admin);
        curator.liftDefaultFreeze(FILM);
        assertEq(curator.unresolvedDefaults(FILM), 1);
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_ClassDefaultFrozen.selector, FILM));
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18);

        // second lift clears it — withdrawals reopen
        vm.prank(admin);
        curator.liftDefaultFreeze(FILM);
        assertEq(curator.unresolvedDefaults(FILM), 0);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1e18); // succeeds
    }

    function test_liftDefaultFreeze_notFrozenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_NotFrozen.selector, FILM));
        vm.prank(admin);
        curator.liftDefaultFreeze(FILM);
    }

    function test_liftDefaultFreeze_onlyAdmin() public {
        vm.prank(address(defaultManager));
        curator.freezeOnDefault(FILM);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, anchorCurator, bytes32(0))
        );
        vm.prank(anchorCurator);
        curator.liftDefaultFreeze(FILM);
    }

    function test_liftDefaultFreeze_unknownClassReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICuratorModule.Curator_UnknownClass.selector, uint256(99)));
        vm.prank(admin);
        curator.liftDefaultFreeze(99);
    }

    // ── wipeout round semantics ──────────────────────────────────────────

    function test_wipeout_advancesRoundAndZeroesStaleStakes() public {
        _postFirstLoss(anchorCurator, FILM, 300e18);
        _postFirstLoss(secondCurator, FILM, 100e18);
        vm.prank(address(defaultManager));
        curator.absorbLoss(FILM, 400e18); // full wipe
        assertEq(curator.poolBalance(FILM), 0);
        assertEq(curator.postedOf(FILM, anchorCurator), 0, "wiped stake is worthless");
        assertEq(curator.postedOf(FILM, secondCurator), 0);
        assertEq(curator.poolRound(FILM), 0, "round advances lazily on next post");

        // fresh capital starts a new round and is NOT diluted by dead shares
        _mintUSDfrTo(secondCurator, 50e18);
        vm.startPrank(secondCurator);
        usdfr.approve(address(curator), 50e18);
        vm.expectEmit(true, false, false, true);
        emit ICuratorModule.PoolRoundAdvanced(FILM, 1);
        curator.postFirstLoss(FILM, 50e18);
        vm.stopPrank();
        assertEq(curator.poolRound(FILM), 1);
        assertEq(curator.postedOf(FILM, secondCurator), 50e18, "new round value intact");
        assertEq(curator.postedOf(FILM, anchorCurator), 0, "stale round stays worthless");

        // the wiped curator can rejoin cleanly
        _postFirstLoss(anchorCurator, FILM, 25e18);
        assertEq(curator.postedOf(FILM, anchorCurator), 25e18);
        assertEq(curator.poolBalance(FILM), 75e18);
    }

    function test_wipeout_staleStakeCannotWithdraw() public {
        _postFirstLoss(anchorCurator, FILM, 100e18);
        vm.prank(address(defaultManager));
        curator.absorbLoss(FILM, 100e18);
        _postFirstLoss(secondCurator, FILM, 50e18); // new round
        vm.expectRevert(
            abi.encodeWithSelector(ICuratorModule.Curator_InsufficientStake.selector, FILM, anchorCurator, 1, 0)
        );
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 1);
    }

    // ── pause semantics ──────────────────────────────────────────────────

    function test_pause_blocksPostAndWithdrawButNeverAbsorb() public {
        _postFirstLoss(anchorCurator, FILM, 100e18);
        vm.prank(guardian);
        curator.pause();

        _mintUSDfrTo(anchorCurator, 1e18);
        vm.startPrank(anchorCurator);
        usdfr.approve(address(curator), 1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        curator.postFirstLoss(FILM, 1e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        curator.withdrawFirstLoss(FILM, 1e18);
        vm.stopPrank();

        // the cascade is NEVER pausable (contract-level design note)
        vm.prank(address(defaultManager));
        (uint256 absorbed,) = curator.absorbLoss(FILM, 50e18);
        assertEq(absorbed, 50e18);

        vm.prank(guardian);
        curator.unpause();
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, 10e18);
    }

    function test_pause_onlyGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        curator.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        curator.unpause();
    }

    // ── upgrade authorization ────────────────────────────────────────────

    function test_upgrade_onlyUpgraderRole() public {
        address newImpl = address(new CuratorModule());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        curator.upgradeToAndCall(newImpl, "");
        // the timelock (admin) can upgrade
        vm.prank(admin);
        curator.upgradeToAndCall(newImpl, "");
    }

    // ── fuzz: share accounting exactness ─────────────────────────────────

    /// @dev Pro-rata absorption: for any two stakes and any partial loss, the two
    ///      curators' post-loss values sum to the pool and preserve their ratio
    ///      within rounding dust (1 wei per curator).
    function testFuzz_absorbLoss_proRataExact(uint256 a, uint256 b, uint256 loss) public {
        a = bound(a, 1e18, 4_000_000e18);
        b = bound(b, 1e18, 4_000_000e18);
        a -= a % 1e12; // whole USDC units for the mint path
        b -= b % 1e12;
        loss = bound(loss, 1, a + b - 1); // partial (full wipe covered in unit test)

        _postFirstLoss(anchorCurator, FILM, a);
        _postFirstLoss(secondCurator, FILM, b);
        vm.prank(address(defaultManager));
        curator.absorbLoss(FILM, loss);

        uint256 va = curator.postedOf(FILM, anchorCurator);
        uint256 vb = curator.postedOf(FILM, secondCurator);
        uint256 remaining = a + b - loss;
        assertLe(va + vb, remaining, "stakes never exceed pool");
        assertGe(va + vb + 2, remaining, "at most 1 wei dust per curator");
        // ratio preserved: va/vb == a/b within dust
        assertApproxEqAbs(va * b, vb * a, (a + b), "pro-rata ratio drifted");
    }

    /// @dev Withdraw rounding never favors the withdrawer: value out == amount asked,
    ///      and the remaining pool never underflows the remaining stakes.
    function testFuzz_withdraw_neverExtractsExcess(uint256 post, uint256 lossPct, uint256 wd) public {
        post = bound(post, 1e18, 4_000_000e18);
        post -= post % 1e12;
        lossPct = bound(lossPct, 0, 99);
        _postFirstLoss(anchorCurator, FILM, post);
        uint256 loss = post * lossPct / 100;
        if (loss != 0) {
            vm.prank(address(defaultManager));
            curator.absorbLoss(FILM, loss);
        }
        uint256 posted = curator.postedOf(FILM, anchorCurator);
        if (posted == 0) return;
        wd = bound(wd, 1, posted);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, wd);
        assertEq(usdfr.balanceOf(anchorCurator), wd, "exact amount out");
        assertLe(curator.postedOf(FILM, anchorCurator), curator.poolBalance(FILM), "stake never exceeds pool balance");
    }
}
