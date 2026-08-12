// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Config} from "../../src/libraries/Config.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @dev SWEEP-3 S3-F1 (MEDIUM), INVERTED. ONE `absorbGlobalLoss` — the ADR-0034 Y-bis exit draw's
///      own layer-1 call — can leave EVERY class pool at dust simultaneously, because the pro-rata
///      allocation floors and the dust sweep tops up only the first pools with remaining capacity.
///
///      ═════════════════════ WHAT CHANGED, AND WHY IT IS AN INVERSION, NOT A WEAKENING ══════════
///      The adversary's probe asserted two things about the state IMMEDIATELY after the draw:
///          (i)  `assertEq(curator.poolRound(c), 0, "no round advance anywhere")`   — the MECHANISM
///          (ii) `assertLe(worstRatio, 1e6, "...collapsed the share ratio...")`     — a PROXY
///      (i) is a statement of the defect and is inverted below. (ii) measures the raw storage
///      ratio, which is a PROXY for the harm rather than the harm itself; the harms the adversary
///      actually MEASURED were `postFirstLoss` reverting on `Math.mulDiv` overflow for every
///      curator, and `postedOf` flooring to zero so nobody could withdraw the surviving wei.
///
///      THE FIX IS DELIBERATELY LAZY (it normalises at the next `postFirstLoss`, not inside the
///      cascade) BECAUSE EAGER NORMALISATION BREAKS A REAL VALUE PROPERTY: advancing the round
///      inside `absorbLoss` zeroes stale stakes, so a curator's legitimate claim on the residual is
///      forfeited AT THE LOSS, and `testFuzz_absorbLoss_proRataExact` reds with
///      "at most 1 wei dust per curator: 2 < 4". MEASURED, not assumed. Attribution is exact while
///      the ratio merely sits collapsed, so (ii) is asserted at the point the ratio can do harm —
///      the next mint — and the intermediate value is LOGGED rather than dropped.
///      See the "WHY THE NORMALISATION IS LAZY" paragraph in `CuratorModule.postFirstLoss`.
contract SweepR3_MultiClass is CreditLayerFixture {
    /// @dev MUTATION: in `CuratorModule._advanceRoundIfWiped`, replace the predicate with
    ///      `if (shares == 0 || pool.balance > shares / (MAX_SHARE_INFLATION * MAX_SHARE_INFLATION))`
    ///      (compiles; both operands still read; the divisor 1e36 is unreachable for any real pool,
    ///      so this reduces to the pre-fix `balance == 0`) -> RED here.
    function test_S3_F1_oneExitDrawCanCollapseTheShareRatioInEveryClassAtOnce() public {
        uint256 total;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            _postFirstLoss(anchorCurator, c, 1_000e18);
            total += 1_000e18;
            assertEq(curator.poolRound(c), 0, "fixture: every class starts on round 0");
        }
        // The redeemer picks `usdfrIn`, and `_exitDrawTarget` is ceil(usdfrIn * deficit / backing),
        // which takes every integer value in range — so `total - NUM_CLASSES` is reachable.
        vm.prank(address(defaultManager));
        curator.absorbGlobalLoss(total - Config.NUM_CLASSES);

        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            uint256 b = curator.poolBalance(c);
            emit log_named_uint("class", c);
            emit log_named_uint("  balance", b);
            emit log_named_uint("  shares (pre-normalisation, inert)", curator.poolShares(c));
            assertGt(b, 0, "fixture: the draw deliberately leaves a residual, it is not an exact wipe");
            // INVERTED (SWEEP-3 S3-F1): this asserted `poolRound(c) == 0` — "no round advance
            // anywhere". Attribution is still exact in this state, which is why the normalisation
            // is not done here; what must be true is that the collapse cannot survive a re-funding.
            assertEq(curator.postedOf(c, anchorCurator), b, "attribution stays exact while the ratio sits collapsed");
        }

        // THE PROPERTY, ASSERTED WHERE THE RATIO CAN DO HARM. Every class must be re-fundable, and
        // once re-funded the ratio must be back inside a range a reader can interpret. Pre-fix this
        // loop reverted on `Math.mulDiv` overflow after three cycles and the ratio stood at 1e21.
        uint256 worstRatio;
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            _postFirstLoss(anchorCurator, c, 1_000e18);
            assertEq(curator.poolRound(c), 1, "S3-F1: an effectively-wiped pool must advance its round");
            uint256 ratio = curator.poolShares(c) / curator.poolBalance(c);
            if (ratio > worstRatio) worstRatio = ratio;
        }
        emit log_named_uint("worst share/balance ratio after re-funding", worstRatio);
        assertLe(worstRatio, 1e6, "S3-F1: one exit draw collapsed the share ratio in every class at once");
    }
}
