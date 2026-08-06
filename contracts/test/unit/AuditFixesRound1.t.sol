// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";

/// @title AuditFixesRound1 — regression tests for the first source-level audit's findings.
/// @notice One section per finding. These are the tests the audit called out as missing —
///         the invariant suite passed because it modeled marks as trusted/fresh and never
///         exercised revoked/stale marks, decayed pending facilities, cancellation, or
///         defaulted-facility close-out.
contract AuditFixesRound1Test is CreditLayerFixture {
    // ─────────────────────────────────────────────────────────────────────
    // M-01 — funding revalidates maturity / attestations / MtM freshness
    // ─────────────────────────────────────────────────────────────────────

    function test_M01_fundRevertsAfterMaturity() public {
        _mintUSDfrTo(alice, 500_000e18); // seed idle liquidity
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.warp(block.timestamp + 366 days); // past the 365-day maturity

        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_FacilityMatured.selector, id));
        vm.prank(servicer);
        waterfall.fund(id, 500_000e6);
    }

    function test_M01_fundRevertsIfRequiredAttestationRevoked() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        // a required mint attestation is withdrawn between origination and funding
        _setSatisfied(id, IAttestationOracle.AttestationKind.CreditIssued, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimBridge.Bridge_AttestationMissing.selector,
                Config.CLASS_FILM_TAX_CREDITS,
                IAttestationOracle.AttestationKind.CreditIssued
            )
        );
        vm.prank(servicer);
        waterfall.fund(id, 500_000e6);
    }

    function test_M01_fundRevertsIfMtMMarkStale() public {
        _mintUSDfrTo(alice, 400_000e18);
        uint64 markAt = uint64(block.timestamp);
        uint256 id = _originateDigital(400_000e18, 1_000_000e18); // ltv 50% → 400k ≤ 500k ok
        vm.warp(block.timestamp + 1 days + 1); // past the class maxMarkAge (1 day)

        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_ValuationStale.selector, id, markAt, uint64(1 days)));
        vm.prank(servicer);
        waterfall.fund(id, 400_000e6);
    }

    function test_M01_fundRevertsIfMtMValueDropped() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateDigital(500_000e18, 1_000_000e18); // 500k == 50% of 1M (at bound)
        // mark falls; draw now exceeds value bound (fresh asOf, so not stale)
        _setValuation(id, 900_000e18, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LtvExceedsValue.selector, 500_000e18, 450_000e18));
        vm.prank(servicer);
        waterfall.fund(id, 500_000e6);
    }

    function test_M01_fundSucceedsWhenStillValid() public {
        _mintUSDfrTo(alice, 500_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        _fundFacility(id, 500_000e18); // checkFundable passes
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Active));
    }

    // ─────────────────────────────────────────────────────────────────────
    // M-02 — a pending facility can be cancelled, releasing its exposure
    // ─────────────────────────────────────────────────────────────────────

    function test_M02_cancelPending_releasesExposureAndBurns() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), 500_000e18);
        assertEq(registry.borrowerExposure(BORROWER_1), 500_000e18);
        assertEq(registry.stateExposure(STATE_GA), 500_000e18);
        assertEq(registry.totalBookExposure(), 500_000e18);

        vm.prank(originator);
        bridge.cancelPending(id);

        // exposure fully reversed, NFT burned, state recorded Cancelled
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), 0, "class exposure released");
        assertEq(registry.borrowerExposure(BORROWER_1), 0, "borrower exposure released");
        assertEq(registry.stateExposure(STATE_GA), 0, "state exposure released");
        assertEq(registry.totalBookExposure(), 0, "book exposure released");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Cancelled));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        bridge.ownerOf(id);
    }

    function test_M02_cancelPending_restoresHeadroom() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.prank(originator);
        bridge.cancelPending(id);
        // headroom is back: the same borrower/state can be originated again
        uint256 id2 = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        assertEq(registry.totalBookExposure(), 500_000e18);
        assertEq(uint8(bridge.facility(id2).state), uint8(ClaimBridge.LoanState.Pending));
    }

    function test_M02_cancelPending_onlyOriginator() public {
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 500_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.ORIGINATOR_ROLE
            )
        );
        vm.prank(alice);
        bridge.cancelPending(id);
    }

    function test_M02_cancelPending_revertsIfNotPending() public {
        uint256 id = _liveFilmFacility(500_000e18); // Active
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_NotPending.selector, id));
        vm.prank(originator);
        bridge.cancelPending(id);
    }

    // ─────────────────────────────────────────────────────────────────────
    // M-03 — a defaulted facility recovered in full closes out to Resolved
    // ─────────────────────────────────────────────────────────────────────

    function test_M03_fullRecoveryDefaulted_resolves() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted));

        // full outstanding principal recovered
        _repay(id, 0, 1_000_000e18);
        assertEq(reserves.deployedTo(id), 0, "outstanding fully recovered");
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved), "closes to Resolved");
    }

    function test_M03_fullRecoveryAccelerated_resolves() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _attestDefault(id);
        vm.startPrank(servicer);
        defaultManager.declareDefault(id, FILM_REF);
        defaultManager.accelerate(id);
        vm.stopPrank();
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Accelerated));

        _repay(id, 0, 1_000_000e18);
        assertEq(uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Resolved));
    }

    function test_M03_partialRecoveryStaysDefaulted() public {
        uint256 id = _liveFilmFacility(1_000_000e18);
        _attestDefault(id);
        vm.prank(servicer);
        defaultManager.declareDefault(id, FILM_REF);

        _repay(id, 0, 200_000e18); // partial
        assertEq(reserves.deployedTo(id), 800_000e18);
        assertEq(
            uint8(bridge.facility(id).state), uint8(ClaimBridge.LoanState.Defaulted), "partial recovery stays Defaulted"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // H-02 — marked-to-market backing is amortized-cost BY DESIGN (documented)
    // ─────────────────────────────────────────────────────────────────────
    // The audit flagged that a marked-to-market facility contributes its deployed principal
    // to backing at par, not at the attested mark. Per the 2026-07-14 decision this is the
    // intended design, NOT a bug: the fast margin-call / liquidation / loss-cascade remedy is
    // the depositor protection, not a continuously-marked backing figure. This test pins that
    // behavior so any future change to continuous MtM-haircut backing is a conscious one.

    function test_H02_backingUnaffectedByMtMMarkDecline_byDesign() public {
        _mintUSDfrTo(alice, 400_000e18);
        uint256 id = _originateDigital(400_000e18, 1_000_000e18); // 40% LTV vs a 1M mark
        _fundFacility(id, 400_000e18);
        uint256 backingBefore = reserves.totalBackingValue();
        assertEq(reserves.deployedTo(id), 400_000e18, "deployed at principal (par)");

        // the collateral mark collapses far below the draw (past margin-call and liquidation)
        _setValuation(id, 100_000e18, uint64(block.timestamp));

        // BY DESIGN: backing is unchanged by the mark decline. The mark drives the
        // margin/liquidation/cascade remedy (the real protection); it does not continuously
        // re-mark backing. Backing only falls when a loss is realized through the cascade.
        assertEq(reserves.totalBackingValue(), backingBefore, "backing unchanged by mark decline (H-02 design)");
        assertEq(reserves.deployedTo(id), 400_000e18, "facility held at par until a realized loss");
    }
}
