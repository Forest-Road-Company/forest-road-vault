// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title S3F1CuratorShareRatioRegression
/// @notice Deterministic promotion of the two shrunk Foundry invariant counterexamples that
///         exposed an unrepresentable CuratorModule share ratio after repeated near-total
///         pool losses and capital reposts.
/// @dev This test intentionally states the required behavior and is red until S3-F1 is fixed.
///      It must never be replaced by an expected-panic assertion: doing so would enshrine the
///      defect and recreate the cache-only evidence gap this regression removes.
contract S3F1CuratorShareRatioRegression is CreditLayerFixture {
    uint256 internal constant FILM = 1;
    uint256 internal constant POST = 100e18;

    function test_regression_S3F1_nearTotalLossRepostsNeverOverflowShareAccounting() public {
        _postFirstLoss(anchorCurator, FILM, POST);

        // Preserve one wei of live pool value. Reposting at that price grows the share ratio;
        // repeating the ordinary transition eventually made Math.mulDiv's quotient exceed
        // uint256 even though every token amount remained small and valid.
        _absorbToOneOrClose();
        _postFirstLoss(anchorCurator, FILM, POST);
        _absorbToOneOrClose();
        _postFirstLoss(anchorCurator, FILM, POST);
        _absorbToOneOrClose();

        // Current unfixed behavior panics here. The S3-F1 remediation must close the
        // economically-wiped round and account for this fresh capital without reverting.
        _postFirstLoss(anchorCurator, FILM, POST);

        // Both a bounded-ratio normalization and an economically-wiped round are admissible.
        // The regression pins liveness and fresh-capital accounting without prescribing which
        // separately reviewed residual-claim representation the production fix adopts.
        assertGe(curator.poolBalance(FILM), POST, "fresh capital was not fully accounted");
    }

    function _absorbToOneOrClose() internal {
        uint256 balance = curator.poolBalance(FILM);
        assertGt(balance, 1, "pool did not contain enough capital for the boundary transition");
        vm.prank(address(defaultManager));
        curator.absorbLoss(FILM, balance - 1);
        assertLe(curator.poolBalance(FILM), 1, "near-total loss left more than the intended residual");
    }
}
