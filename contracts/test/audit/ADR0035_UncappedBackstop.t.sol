// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {GovernanceFixture} from "../helpers/GovernanceFixture.sol";

/// @notice Owner-decision discriminator for ADR-0035's uncapped, live-reserve backstop.
/// @dev These assertions RED on the frozen capped implementation. They pin both sides of the
///      decision: the first reported shortfall can drain layer two, and later shortfalls get no
///      fictional protection until real USDfr replenishes the shared reserve.
contract ADR0035UncappedBackstopTest is GovernanceFixture {
    uint256 internal constant FIRST_EVENT = 101;
    uint256 internal constant SECOND_EVENT = 202;

    function test_coverageCapacityIsTheWholeLiveReserve() public {
        _fundCoverage(100_000e18);
        assertEq(sGrove.coverageCapacity(), 100_000e18, "capacity must equal live reserve");
    }

    function test_oneEventCanDrainLayerTwoAndTheNextWaitsForReplenishment() public {
        _fundCoverage(100_000e18);

        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(FIRST_EVENT, 150_000e18), 100_000e18, "first event drains reserve");
        assertEq(sGrove.coverageReserve(), 0, "layer two exhausted");

        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(SECOND_EVENT, 50_000e18), 0, "later event reaches no empty reserve");

        _fundCoverage(40_000e18);
        vm.prank(address(defaultManager));
        assertEq(sGrove.coverShortfall(SECOND_EVENT, 50_000e18), 40_000e18, "replenishment restores live cover");
        assertEq(sGrove.coverageReserve(), 0, "replenished reserve can also be exhausted");
    }

    function test_chunkingCannotPreserveOrMultiplyAnEventAllowance() public {
        _fundCoverage(100_000e18);
        uint256 drawn;
        for (uint256 i = 0; i < 10; ++i) {
            vm.prank(address(defaultManager));
            drawn += sGrove.coverShortfall(FIRST_EVENT, 10_000e18);
        }
        assertEq(drawn, 100_000e18, "chunks consume exactly the shared live reserve");
        assertEq(sGrove.coverageReserve(), 0, "no hidden event allowance remains");
    }
}
