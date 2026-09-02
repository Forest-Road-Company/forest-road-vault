// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @notice F-9: the live senior-exit cascade must distribute multi-wei rounding dust without
///         charging any class above the capital it actually posted.
contract F09UnequalPoolDustRedistributionTest is CreditLayerFixture {
    function test_F09_liveSeniorExitRedistributesDustWithinEachUnequalPoolHeadroom() public {
        uint256[5] memory starting = [uint256(1_000e18), 2_000e18, 3_000e18, 4_000e18, 5_000e18];
        uint256 total;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            _postFirstLoss(anchorCurator, i + 1, starting[i]);
            total += starting[i];
        }

        // One wei below a complete drain makes every independently floored class allocation
        // leave one wei behind. Four wei of dust must therefore cross four separate one-wei
        // headrooms; this is the shape that the old `allocation + dust` implementation could
        // over-debit.
        uint256 requested = total - 1;
        (uint256[5] memory expected, uint256 initialDust) = _referenceAllocation(starting, requested);
        assertGe(initialDust, 2, "setup: exercise multi-wei dust");

        bool hasHeadroomBelowDust;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 floored = requested * starting[i] / total;
            if (starting[i] - floored < initialDust) hasHeadroomBelowDust = true;
        }
        assertTrue(hasHeadroomBelowDust, "setup: at least one pool headroom must be below dust");

        uint256 receiverBefore = usdfr.balanceOf(address(defaultManager));
        vm.prank(address(controller));
        uint256 drawn = defaultManager.drawForSeniorExit(requested);

        assertEq(drawn, requested, "the live route must deliver the requested partial loss");
        assertEq(
            usdfr.balanceOf(address(defaultManager)) - receiverBefore,
            requested,
            "the live route must transfer exactly what the pools lost"
        );

        uint256 totalDebit;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            uint256 ending = curator.poolBalance(i + 1);
            uint256 debit = starting[i] - ending;
            assertLe(debit, starting[i], "no class may be debited above its starting balance");
            assertEq(debit, expected[i], "class debit must match independent pro-rata plus dust reference");
            totalDebit += debit;
        }
        assertEq(totalDebit, requested, "aggregate pool debit must equal the absorbed amount exactly");
    }

    function _referenceAllocation(uint256[5] memory balances, uint256 absorbed)
        internal
        pure
        returns (uint256[5] memory allocation, uint256 initialDust)
    {
        uint256 total;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            total += balances[i];
        }

        uint256 allocated;
        for (uint256 i = 0; i < Config.NUM_CLASSES; ++i) {
            // Deliberately independent from CuratorModule's Math.mulDiv implementation. The
            // bounded fixture values make ordinary Solidity multiplication exact and safe.
            allocation[i] = absorbed * balances[i] / total;
            allocated += allocation[i];
        }

        uint256 dust = absorbed - allocated;
        initialDust = dust;
        for (uint256 i = 0; i < Config.NUM_CLASSES && dust != 0; ++i) {
            uint256 headroom = balances[i] - allocation[i];
            uint256 extra = dust < headroom ? dust : headroom;
            allocation[i] += extra;
            dust -= extra;
        }
        assert(dust == 0);
    }
}
