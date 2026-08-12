// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title AUDIT FIX (SWEEP-1 RMDM-F1) — a permissionless recapitalisation may not release
///        cascade layer 1 while a recognised credit mark stands.
///
/// @notice ═══ THESE TESTS ASSERT THE CURE. THE ADVERSARIAL PROBES THEY REPLACE ASSERTED THE
///         DEFECT. DO NOT RE-INVERT THEM. ═══
///
///         The sweep-round-1 probes `test_S1_P2_permissionlessRecapBuysTheCuratorOutOfTheLayer1
///         Freeze` and `test_S1_P2b_theBuyOutMovesALayer1LossOntoTheSeniorVault` PASSED on the
///         pre-fix tree: they measured a 10,000 gift releasing a freeze that was holding a
///         200,000 loss, moving 180,000 of that loss off cascade layer 1 and onto the senior
///         vault. Everything below is the same scenario with the assertions turned the right way
///         up, so the file that used to certify the escape now certifies that it is closed.
///
/// @dev    THE MECHANISM, so nobody "simplifies" limb 5 away later. The CUSTODY loss path arms a
///         LATCH — `reserveDeficit`, `custodyLossUnabsorbed()` limb 2 — and
///         `test_F3_limb2LatchedDeficitSurvivesRecapitalisation` already pins that limb 2 survives
///         a recap. The G3 CREDIT-VALUATION path (`recognizePrincipalImpairment`) wrote no latch
///         at all: no incident, no `reserveDeficit`, and no `unresolvedDefaults` unless a default
///         is separately declared. It was therefore held by limb 4 alone — the live level check
///         `totalUSDfr() > backingValue()` — and `ReserveManager.recapitalize()` moves
///         `backingValue()` by construction from ANY address, with no role, no KYC and no pause
///         gate. Limb 5 (`totalPrincipalImpairment != 0`) is the missing latch.
contract SweepR1_RecapCannotReleaseLayer1 is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    bytes32 internal constant ADJ = keccak256("SWEEPR1-adjudication");

    address internal rescuer = makeAddr("sweepr1-rescuer");

    /// @notice LIMB 5 IN ISOLATION. A recognised mark, then a gift large enough to clear limb 4
    ///         outright — and layer 1 must still refuse to leave.
    /// @dev DELETION MUTATION FOR LIMB 5: remove
    ///      `if ($.totalPrincipalImpairment != 0) return true;` from
    ///      `ReserveManager.custodyLossUnabsorbed()`. This test goes RED on
    ///      "SWEEPR1: a permissionless gift cleared the layer-1 freeze while an evidenced,
    ///      unabsorbed credit mark stood".
    function test_SWEEPR1_aRecapitalisationCannotReleaseLayer1WhileAMarkStands() public {
        _postFirstLoss(anchorCurator, FILM, 2_000_000e18);
        uint256 id = _liveFilmFacility(200_000e18);

        // A recognised, UNABSORBED credit loss. No default is declared, so the R4-EC2 per-class
        // freeze (`unresolvedDefaults`) is NOT armed. Limbs 1, 2 and 3 are all quiet.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 50_000e18, ADJ);
        (uint256 openIncident,) = reserves.activeReserveLossIncident();
        assertEq(openIncident, 0, "VACUITY: limb 1 must be quiet for this to isolate limb 5");
        assertEq(reserves.reserveDeficit(), 0, "VACUITY: limb 2 must be quiet for this to isolate limb 5");
        assertEq(reserves.unrecordedUSDC(), 0, "VACUITY: limb 3 must be quiet for this to isolate limb 5");
        assertTrue(reserves.custodyLossUnabsorbed(), "the recognised mark must freeze layer 1");
        assertTrue(curator.custodyFreezeActive(), "the curator freeze must be live");

        uint256 free = curator.headroom(FILM);
        assertGt(free, 1_000_000e18, "the pool is far larger than the deficit that freezes it");

        vm.prank(anchorCurator);
        (bool ok,) = address(curator).call(abi.encodeWithSignature("withdrawFirstLoss(uint256,uint256)", FILM, free));
        assertFalse(ok, "layer 1 must be frozen while the recognised loss stands");

        // An arbitrary third party — no role, no KYC — gifts more than the whole deficit, so the
        // LEVEL check that is limb 4 is now genuinely satisfied.
        usdc.mint(rescuer, 60_000e6);
        vm.startPrank(rescuer);
        usdc.approve(address(reserves), 60_000e6);
        reserves.recapitalize(60_000e6);
        vm.stopPrank();

        assertLe(
            controller.totalUSDfr(),
            controller.backingValue(),
            "VACUITY: the gift must actually have cleared limb 4, or limb 5 is not what is holding"
        );
        assertEq(reserves.principalImpairmentOf(id), 50_000e18, "the mark is untouched by the gift");
        assertTrue(
            reserves.custodyLossUnabsorbed(),
            "SWEEPR1: a permissionless gift cleared the layer-1 freeze while an evidenced, unabsorbed credit mark stood"
        );
        assertTrue(curator.custodyFreezeActive(), "SWEEPR1: the curator freeze was bought out for the size of the gap");

        vm.prank(anchorCurator);
        (ok,) = address(curator).call(abi.encodeWithSignature("withdrawFirstLoss(uint256,uint256)", FILM, free));
        assertFalse(ok, "SWEEPR1: layer 1 escaped after the gift");
    }

    /// @notice LIMB 5 IS NOT A LOCK. Governance can always retire the mark on the merits —
    ///         by evidence (`releasePrincipalImpairment`) or by realising the loss — and layer 1
    ///         is free the moment the recognition-to-absorption window closes. Without this the
    ///         fix would trade a freeze bypass for a permanent freeze, which is not a fix.
    function test_SWEEPR1_limb5ClearsWhenTheMarkIsRetiredOnTheMerits() public {
        _postFirstLoss(anchorCurator, FILM, 2_000_000e18);
        uint256 id = _liveFilmFacility(200_000e18);

        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 50_000e18, ADJ);
        assertTrue(reserves.custodyLossUnabsorbed(), "setup: the mark freezes layer 1");

        // Governance reverses the mark with fresh evidence — the ADR-0012 workout path.
        vm.prank(admin);
        reserves.releasePrincipalImpairment(id, 50_000e18, keccak256("SWEEPR1-workout-recovered"));

        assertEq(reserves.totalPrincipalImpairment(), 0, "the mark is retired");
        assertFalse(
            reserves.custodyLossUnabsorbed(), "SWEEPR1: limb 5 latched permanently - that is a brick, not a fix"
        );
        assertFalse(curator.custodyFreezeActive(), "SWEEPR1: the curator freeze outlived the loss that justified it");

        uint256 free = curator.headroom(FILM);
        uint256 before = usdfr.balanceOf(anchorCurator);
        vm.prank(anchorCurator);
        curator.withdrawFirstLoss(FILM, free);
        assertEq(
            usdfr.balanceOf(anchorCurator) - before, free, "SWEEPR1: layer 1 could not leave after the mark cleared"
        );
    }

    /// @notice THE ECONOMIC CONSEQUENCE, MEASURED END TO END. `requiredFirstLoss` is
    ///         `min(exposure, target)`, so with a production-shaped subordination target the
    ///         headroom released by a buy-out is capital `realizeLoss` would otherwise have
    ///         consumed at layer 1. Both arms must now absorb the SAME amount at layer 1: the
    ///         gift may no longer move a loss down the cascade onto the senior vault.
    /// @dev Same deletion mutation as above: without limb 5 the "gift" arm absorbs 20,000e18 of a
    ///      200,000e18 loss at layer 1 instead of the full 200,000e18, and this test goes RED on
    ///      "SWEEPR1: the gift moved a layer-1 loss onto the senior vault".
    function test_SWEEPR1_aGiftCannotMoveALayer1LossOntoTheSeniorVault() public {
        uint256 absorbedWithGift = _runLossScenario(true);
        uint256 absorbedWithoutGift = _runLossScenario(false);

        emit log_named_uint("layer 1 absorbed, no gift", absorbedWithoutGift);
        emit log_named_uint("layer 1 absorbed, after a 10,000 gift", absorbedWithGift);
        assertEq(absorbedWithoutGift, 200_000e18, "control: layer 1 takes the whole loss");
        assertEq(absorbedWithGift, absorbedWithoutGift, "SWEEPR1: the gift moved a layer-1 loss onto the senior vault");
    }

    /// @dev Returns the layer-1 (curator) absorption reported by `LossRealized`.
    function _runLossScenario(bool gift) internal returns (uint256 absorbed) {
        uint256 snap = vm.snapshotState();

        // A production-shaped subordination requirement: 20k of first loss on a 200k book.
        vm.prank(admin);
        curator.setFirstLossTarget(FILM, 20_000e18);
        _postFirstLoss(anchorCurator, FILM, 2_000_000e18);
        _stakeVault(alice, 400_000e18);
        uint256 id = _liveFilmFacility(200_000e18);

        // Governance recognises a first, small tranche of the loss. Nothing is declared yet.
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id, 10_000e18, ADJ);
        assertTrue(curator.custodyFreezeActive(), "the recognised loss must freeze layer 1");

        if (gift) {
            usdc.mint(rescuer, 10_000e6);
            vm.startPrank(rescuer);
            usdc.approve(address(reserves), 10_000e6);
            reserves.recapitalize(10_000e6); // permissionless, 10,000 of real cash
            vm.stopPrank();
            assertTrue(curator.custodyFreezeActive(), "SWEEPR1: the gift released the freeze");
            vm.prank(anchorCurator);
            (bool ok,) = address(curator).call(
                abi.encodeWithSignature("withdrawFirstLoss(uint256,uint256)", FILM, curator.headroom(FILM))
            );
            assertFalse(ok, "SWEEPR1: layer 1 walked out through the gift");
        }

        // The workout then goes the whole way.
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        _attestLoss(id, 200_000e18, FILM_REF);

        vm.recordLogs();
        vm.prank(servicer);
        defaultManager.realizeLoss(id, 200_000e18, FILM_REF);
        absorbed = _layer1FromLogs();

        vm.revertToState(snap);
    }

    function _layer1FromLogs() internal view returns (uint256 absorbed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LossRealized(uint256,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (, uint256 a,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return a;
            }
        }
        revert("no LossRealized event");
    }

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }
}
