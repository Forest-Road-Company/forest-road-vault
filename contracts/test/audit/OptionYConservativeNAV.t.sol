// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title Option Y — conservative-redemption NAV (ADR-0022 §Y)
/// @notice Proves the EXIT-PRICING half of ADR-0022: a senior cannot exit at pre-loss NAV in the
///         `declareDefault` -> `realizeLoss` window, because redemptions price on
///         `totalAssets - pendingSeniorImpairment` while deposits keep pricing at the realized
///         NAV. Option X (the 21-day cooldown) closes the same attack from the TIME side; these
///         tests cover the PRICE side, and the two are independent defenses.
///
///         Invariant owed by ADR-0022 §Y.2 and encoded here: redemption NAV <= deposit NAV,
///         always. See also `test/invariant/` for the stateful version.
contract OptionYConservativeNAVTest is CreditLayerFixture {
    uint256 internal constant FILM = 1;

    event ImpairmentSourceUpdated(address indexed source);
    event DefaultManagerSet(address indexed manager);

    // ── helpers ──────────────────────────────────────────────────────────

    function _fundBackstop(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), amount);
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _defaulted(uint256 principal) internal returns (uint256 id) {
        id = _liveFilmFacility(principal);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
    }

    /// @dev One whole share unit, accounting for the ERC-4626 virtual-share decimals offset.
    function _oneShare() internal view returns (uint256) {
        return 10 ** vault.decimals();
    }

    // ── wiring ───────────────────────────────────────────────────────────

    function test_fixtureWiresImpairmentSourceAndResolveHook() public view {
        assertEq(
            vault.impairmentSource(),
            address(assessedImpairmentSource),
            "vault reads impairment through the governed assessment wrapper"
        );
        assertEq(
            assessedImpairmentSource.baseSource(),
            address(defaultManager),
            "assessment wrapper reads its conservative base from the manager"
        );
        assertEq(waterfall.defaultManager(), address(defaultManager), "engine can clear on a clean resolve");
        assertTrue(
            defaultManager.hasRole(Roles.CREDIT_ROLE, address(waterfall)),
            "engine holds CREDIT_ROLE so onDefaultResolved succeeds"
        );
    }

    function test_setImpairmentSource_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vault.setImpairmentSource(address(defaultManager));
    }

    function test_setImpairmentSource_emitsAndClears() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ImpairmentSourceUpdated(address(0));
        vm.prank(admin);
        vault.setImpairmentSource(address(0));
        assertEq(vault.impairmentSource(), address(0), "cleared");
        // unwired == pre-ADR-0022 behaviour: exits price at the realized NAV
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "realized NAV while unwired");
    }

    function test_setDefaultManager_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        waterfall.setDefaultManager(address(defaultManager));
    }

    function test_setDefaultManager_emits() public {
        vm.expectEmit(true, false, false, true, address(waterfall));
        emit DefaultManagerSet(address(0));
        vm.prank(admin);
        waterfall.setDefaultManager(address(0));
        assertEq(waterfall.defaultManager(), address(0), "cleared");
    }

    // ── the core property: exit price marks a declared default, entry price does not ──

    function test_declaredDefault_marksExitPriceButNotEntryPrice() public {
        _stakeVault(alice, 400_000e18);

        uint256 assetsBefore = vault.totalAssets();
        uint256 rateBefore = vault.currentExchangeRate();
        uint256 exitBefore = vault.previewRedeem(_oneShare());
        uint256 entryBefore = vault.previewDeposit(1e18);

        // 300k declared defaulted with NO junior capacity posted -> all 300k reaches senior
        _defaulted(300_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "full amount reaches senior");

        // ENTRY side is untouched: realized NAV, the ADR-0002 variable-yield posture
        assertEq(vault.totalAssets(), assetsBefore, "totalAssets is realized, unchanged by a declaration");
        assertEq(vault.currentExchangeRate(), rateBefore, "the S1.3 monotonicity subject does not move");
        assertEq(vault.previewDeposit(1e18), entryBefore, "deposits still price at realized NAV");

        // EXIT side is marked down
        uint256 exitAfter = vault.previewRedeem(_oneShare());
        assertLt(exitAfter, exitBefore, "exit price falls on a DECLARED (not yet realized) default");
        assertLt(vault.redemptionTotalAssets(), vault.totalAssets(), "conservative base is strictly lower");
    }

    /// @dev THE ATTACK (ADR-0022 context, finding A1 / H-01): a senior who sees a default coming
    ///      exits between `declareDefault` and `realizeLoss`, locking pre-loss NAV and dumping the
    ///      loss on whoever stayed. Option X blocks the timing; this proves the PRICE also blocks it.
    function test_lossDodge_exitDuringWorkoutIsPricedAtTheImpairedRate() public {
        _stakeVault(alice, 400_000e18);
        uint256 aliceShares = vault.balanceOf(alice);

        uint256 preDeclarePrice = vault.previewRedeem(aliceShares);
        _defaulted(300_000e18);
        uint256 postDeclarePrice = vault.previewRedeem(aliceShares);

        assertLt(postDeclarePrice, preDeclarePrice, "the leaver cannot lock the pre-loss price");
        // the whole declared impairment is borne on exit, not socialised onto stayers
        assertApproxEqAbs(
            preDeclarePrice - postDeclarePrice,
            300_000e18 * aliceShares / vault.totalSupply(),
            1e12,
            "leaver eats their pro-rata share of the declared impairment"
        );
    }

    function test_juniorCapacityAbsorbsFirst_noSeniorMarkWhileCovered() public {
        _postFirstLoss(anchorCurator, FILM, 200_000e18); // layer 1
        _fundBackstop(150_000e18); // layer 2
        _stakeVault(alice, 400_000e18);

        uint256 exitBefore = vault.previewRedeem(_oneShare());
        _defaulted(300_000e18); // fully covered: 200k curator + 150k sGROVE > 300k

        assertEq(defaultManager.pendingSeniorImpairment(), 0, "juniors cover it entirely");
        assertEq(vault.previewRedeem(_oneShare()), exitBefore, "senior exit price is untouched");
        assertEq(vault.redemptionTotalAssets(), vault.totalAssets(), "no mark while juniors cover");
    }

    function test_impairmentExceedingVaultAssets_clampsToZeroRatherThanUnderflowing() public {
        _stakeVault(alice, 50_000e18);
        _defaulted(300_000e18); // impairment far exceeds the 50k in the vault

        assertGt(defaultManager.pendingSeniorImpairment(), vault.totalAssets(), "over-marked by construction");
        assertEq(vault.redemptionTotalAssets(), 0, "clamps at zero, does not revert or underflow");
        // the vault still functions: entry side is unaffected and reads do not revert
        assertGt(vault.totalAssets(), 0, "realized assets still there");
        assertGt(vault.previewDeposit(1e18), 0, "deposits unaffected");
    }

    // ── the clean-recovery path (the resolve hook) ───────────────────────

    function test_cleanRecovery_clearsTheMarkAndRestoresTheExitPrice() public {
        _stakeVault(alice, 400_000e18);
        uint256 exitBefore = vault.previewRedeem(_oneShare());

        uint256 id = _defaulted(300_000e18);
        assertEq(defaultManager.pendingSeniorImpairment(), 300_000e18, "marked on declare");
        assertLt(vault.previewRedeem(_oneShare()), exitBefore, "exit marked down during the workout");

        // the borrower repays the full outstanding: Defaulted -> Resolved, no realized loss
        _repay(id, 0, 300_000e18);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "closed out clean");
        assertEq(defaultManager.pendingSeniorImpairment(), 0, "the resolve hook cleared the mark");
        assertEq(defaultManager.declaredDefaultedPrincipal(FILM), 0, "class pool drained");
        assertGe(vault.previewRedeem(_oneShare()), exitBefore, "exit price restored after a clean workout");
    }

    /// @dev Without the resolve hook the mark would persist forever after a clean recovery,
    ///      permanently depressing every future redemption. Proves the hook is load-bearing.
    function test_withoutResolveHook_theMarkWouldPersistForever() public {
        vm.prank(admin);
        waterfall.setDefaultManager(address(0)); // simulate the unwired engine

        _stakeVault(alice, 400_000e18);
        uint256 id = _defaulted(300_000e18);

        _repay(id, 0, 300_000e18);

        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved), "recovered");
        assertEq(
            defaultManager.pendingSeniorImpairment(),
            300_000e18,
            "UNWIRED: a fully recovered facility still depresses the NAV - this is what the hook fixes"
        );
    }

    // ── the ADR-0022 S.Y.2 invariant, unit + fuzz ────────────────────────

    function test_redemptionNavNeverExceedsDepositNav() public {
        _stakeVault(alice, 400_000e18);
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "no impairment: equal");
        _defaulted(300_000e18);
        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "with impairment: strictly lower");
        assertLe(vault.previewRedeem(_oneShare()), vault.convertToAssets(_oneShare()), "exit <= realized");
    }

    /// @dev Fuzzed over stake size, junior capacity and default size. The property must hold for
    ///      every reachable combination, including the fully-covered and fully-wiped extremes.
    function testFuzz_redemptionNavNeverExceedsDepositNav(uint256 stake, uint256 curatorPool, uint256 defaulted)
        public
    {
        // whole USDC units: the fixture mints 6-dec stables through the controller
        stake = bound(stake, 1e18, 1_000_000e18) / 1e12 * 1e12;
        curatorPool = bound(curatorPool, 0, 500_000e18) / 1e12 * 1e12;
        defaulted = bound(defaulted, 1e18, 500_000e18) / 1e12 * 1e12;

        if (curatorPool != 0) _postFirstLoss(anchorCurator, FILM, curatorPool);
        _stakeVault(alice, stake);
        _defaulted(defaulted);

        assertLe(vault.redemptionTotalAssets(), vault.totalAssets(), "redemption NAV <= deposit NAV");
        uint256 shares = vault.balanceOf(alice);
        assertLe(vault.previewRedeem(shares), vault.convertToAssets(shares), "exit price <= realized price");
        // previewWithdraw rounds UP, so it must never ask for FEWER shares than the realized rate
        if (vault.redemptionTotalAssets() != 0) {
            assertGe(vault.previewWithdraw(1e18), vault.convertToShares(1e18), "impaired exit costs more shares");
        }
    }

    /// @dev The queue's budget cap must never let a settlement pay out more than the budget.
    ///      `convertToSharesAtRedemption` rounds DOWN so this holds by construction; fuzz it.
    function testFuzz_convertToSharesAtRedemption_neverOvershootsTheBudget(uint256 stake, uint256 budget, uint256 def)
        public
    {
        stake = bound(stake, 1e18, 1_000_000e18) / 1e12 * 1e12;
        budget = bound(budget, 0, 1_000_000e18);
        def = bound(def, 0, 500_000e18) / 1e12 * 1e12;

        _stakeVault(alice, stake);
        if (def != 0) _defaulted(def);

        uint256 shares = vault.convertToSharesAtRedemption(budget);
        assertLe(vault.previewRedeem(shares), budget, "a budget-capped fill never exceeds the budget");
    }

    function test_maxWithdrawUsesTheConservativeRate() public {
        _stakeVault(alice, 400_000e18);
        // move shares to the queue so maxWithdraw is non-zero (only the queue may exit)
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(address(queue), aliceShares);

        uint256 before = vault.maxWithdraw(address(queue));
        _defaulted(300_000e18);
        uint256 afterMark = vault.maxWithdraw(address(queue));

        assertLt(afterMark, before, "advertised exit capacity falls with the conservative rate");
        assertEq(afterMark, vault.previewRedeem(vault.balanceOf(address(queue))), "consistent with previewRedeem");
    }
}
