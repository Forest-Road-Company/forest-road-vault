// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {LossEventIds} from "../../src/libraries/LossEventIds.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @title ADR-0035 re-point of SWEEP-1 CSG-F1
/// @notice Event ids retain cumulative observability but own no ceiling. A dust draw cannot poison
///         later protection; replenishment is immediately available to standing and facility keys.
contract SweepR1_ExitKeyCapRatchetUnit is GovernanceFixture {
    uint256 internal constant EXIT_KEY = LossEventIds.CUSTODY_EVENT_NAMESPACE_START;
    uint256 internal constant FACILITY_EVENT = 7;
    /// @dev One whole USDC unit at 18dp: the smallest reserve the fixture's mint helper can seed.
    uint256 internal constant DUST = 1e12;

    function _fund(uint256 amount) internal {
        _fundCoverage(amount);
    }

    /// @notice A dust first draw cannot bind a later draw against a replenished live reserve.
    function test_SWEEPR1_theStandingExitKeyUsesTheReplenishedReserve() public {
        _fund(DUST); // one USDC unit of coverage - the launch state, before anyone seeds it

        vm.prank(address(defaultManager));
        uint256 dust = sGrove.coverShortfall(EXIT_KEY, DUST);
        assertGt(dust, 0, "VACUITY: the dust draw must execute");
        (uint256 drawn, uint256 cap) = sGrove.eventCoverage(EXIT_KEY);
        assertEq(drawn, dust, "cumulative ledger");
        assertEq(cap - drawn, 0, "dust draw exhausted the then-live reserve");

        // Forest Road funds the backstop properly afterwards.
        _fund(400_000e18);

        vm.prank(address(defaultManager));
        uint256 real = sGrove.coverShortfall(EXIT_KEY, 200_000e18);
        assertGt(real, 0, "SWEEPR1: the standing senior-exit key's cap was frozen by a dust draw");
        assertEq(real, 200_000e18, "standing key did not reach the live replenished reserve");
        (uint256 drawn2,) = sGrove.eventCoverage(EXIT_KEY);
        assertEq(drawn2, dust + real, "SWEEPR1: cumulative consumption on the standing key was reset");
    }

    /// @notice Repeated draws cannot exceed the one physical shared reserve.
    function test_SWEEPR1_chunkingTheStandingKeyCannotExceedTheReserve() public {
        _fund(100_000e18);
        uint256 drawn;
        for (uint256 i = 0; i < 10; ++i) {
            vm.prank(address(defaultManager));
            drawn += sGrove.coverShortfall(EXIT_KEY, 80_000e18);
        }
        assertEq(drawn, 100_000e18, "chunking must consume exactly the physical reserve");
        assertEq(sGrove.coverageReserve(), 0, "one event may exhaust layer two");
    }

    /// @notice Facility events, like the standing exit key, reach later replenishment immediately.
    function test_SWEEPR1_aFacilityEventUsesTheReplenishedReserve() public {
        _fund(100_000e18);
        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(FACILITY_EVENT, 80_000e18), 80_000e18, "live reserve covers request");

        _fund(400_000e18); // the reserve grows a great deal afterwards

        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(FACILITY_EVENT, 80_000e18), 80_000e18, "refill re-arms same event");
        (, uint256 cap) = sGrove.eventCoverage(FACILITY_EVENT);
        assertEq(cap - 160_000e18, sGrove.coverageReserve(), "event view reports live reach");
    }
}

/// @dev THE SAME PROPERTY DRIVEN END TO END THROUGH `MintRedeemController.redeem` and the
///      `MockCascadeBackstop` every `CreditLayerFixture` suite uses. The mock carries the same
///      ratchet, and it must: its own PM-R-11 header records that a mock whose observable
///      behaviour differs from the contract it stands in for is a false green by construction.
contract SweepR1_ExitKeyCapRatchetE2E is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant EXIT_KEY = LossEventIds.CUSTODY_EVENT_NAMESPACE_START;
    uint256 internal facility;
    uint256 internal constant DUST = 1e12;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);
        _mintUSDfrTo(alice, 5_000_000e18);
        // The backstop's float is minted BEFORE the mark closes issuance; `_fundBackstop` only
        // moves it afterwards, so nothing below depends on minting while the protocol is short.
        _mintUSDfrTo(bob, 1_000_000e18);
        facility = _liveFilmFacility(1_000_000e18);
    }

    function _fundBackstop(uint256 amount) internal {
        vm.prank(bob);
        usdfr.transfer(address(backstopMock), amount);
    }

    /// @notice A dust exit taken while the backstop is empty must not stop layer 2 paying on a
    ///         later, real exit.
    /// @dev DELETION MUTATION: drop the standing-key disjunct from `MockCascadeBackstop`
    ///      (mirroring the `SGrove` mutation). This test goes RED on
    ///      "SWEEPR1: layer 2 contributed nothing — the dust exit poisoned the standing key".
    function test_SWEEPR1_e2e_aDustExitDoesNotPoisonLayer2ForLaterExits() public {
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(facility, 100_000e18, keccak256("mark"));

        // The backstop holds a token amount when the FIRST under-backed redemption lands.
        _fundBackstop(DUST);
        vm.prank(alice);
        controller.redeem(1_000e18, 0, block.timestamp);
        (uint256 dustDrawn, uint256 dustCap) = backstopMock.eventCoverage(EXIT_KEY);
        assertGt(dustCap, 0, "VACUITY: the dust redemption must execute on the standing key");

        // Forest Road funds the backstop properly afterwards.
        _fundBackstop(400_000e18);

        uint256 backstopBefore = usdfr.balanceOf(address(backstopMock));
        vm.prank(alice);
        controller.redeem(200_000e18, 0, block.timestamp);
        assertLt(
            usdfr.balanceOf(address(backstopMock)),
            backstopBefore,
            "SWEEPR1: layer 2 contributed nothing - the dust exit poisoned the standing key"
        );
        emit log_named_uint("layer 2 paid on the later exit", backstopBefore - usdfr.balanceOf(address(backstopMock)));
        assertGt(reserves.exitPrepaidAbsorption(), dustDrawn, "junior capital moved on the real exit");
    }
}
