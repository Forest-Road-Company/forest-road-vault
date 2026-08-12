// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CuratorModule} from "../../../src/CuratorModule.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {Config} from "../../../src/libraries/Config.sol";
import {MockCascadeBackstop} from "../../helpers/MockCascadeBackstop.sol";

/// @title CascadeOrderedExitHandler — ADR-0034 decision Z, the DRAWN exit path
///
/// @notice WHAT THIS DRIVES, AND WHY NOTHING ELSE IN THE TREE DOES. ADR-0034 Z requires "a handler
///         action that drives the protocol under-backed and then redeems", and an invariant that
///         "no redemption sequence allows a senior or USDfr holder to absorb loss while unexhausted
///         junior capital remains". The ADR records why the existing campaigns cannot catch a
///         violation: the only handler modelling a custody shortfall has eight actions and none of
///         them mints yield or distributes, so the custody x credit seam is unexercised. R18's
///         `SubParExitHandler` closed the REACH but explicitly declined to encode Z's property,
///         on the correct ground that decision Y was not implemented and "an invariant written to
///         pass against it would be an invariant written to accept the defect".
///
///         Y-bis IS NOW IMPLEMENTED, SO THE PROPERTY IS ENCODED HERE RATHER THAN DEFERRED. This
///         handler stands on the FULL credit stack — real `CuratorModule` (layer 1), a real
///         uncapped shared-reserve backstop (layer 2), a real `DefaultManager` — because the ordering
///         property is a claim about those layers and cannot be asserted against a token-layer
///         double.
///
/// @dev `fail_on_revert = true`, so every action that can legitimately revert in this domain is
///      pre-guarded or wrapped in try/catch and CLASSIFIED. The classification counters are the
///      anti-vacuity evidence, and the campaign asserts them directly rather than hoping a seed
///      reached them.
contract CascadeOrderedExitHandler is Test {
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    CuratorModule internal curator;
    MockCascadeBackstop internal backstop;
    /// @dev AUDIT FIX (SWEEP-1 MRC-F1). The ADR-0034 X LAYER-3 HOLDER. Before this the entire Z
    ///      campaign had NO sUSDfr staker anywhere in its state space — `grep -c "vault"` over this
    ///      handler and its campaign returned ZERO — so clause 2 was encoded purely as the UNSTAKED
    ///      book's coverage ratio and could not see anything that happened to the senior vault. An
    ///      invariant that passes because its handler never reaches the region is worthless, and
    ///      ADR-0034 Z requires the property to cover "a senior OR USDfr holder".
    SUSDfr internal vault;

    address internal admin;
    address[2] public actors;
    uint256 internal facility;

    uint256 internal constant UNIT = 1e12;

    // ── reach telemetry ──────────────────────────────────────────────────
    uint256 public callCount;
    uint256 public gMarks;
    uint256 public gReleases;
    uint256 public gExits;
    uint256 public gDrawnExits;
    uint256 public gSubParExits;
    uint256 public gParExitsUnderDeficit;
    uint256 public gLayer2Draws;
    uint256 public gExitsWithJuniorExhausted;
    /// @dev SWEEP-1 MRC-F1 reach telemetry: exits measured with a LIVE sUSDfr staker present.
    uint256 public gExitsWithALiveStaker;
    /// @dev SWEEP-1 MRC-F1 reach telemetry: exits after which the senior vault's redemption NAV
    ///      was strictly LOWER than before. This is NOT a defect counter — see the OWNER-DECISION
    ///      note on `gVaultFallExceededDraw`. It is the witness that the region is reached.
    uint256 public gExitsThatLoweredTheVaultNav;

    // ── THE DEFECT COUNTERS. Every one must stay zero. ───────────────────
    /// @dev Z, clause 1: an exit absorbed loss while UNEXHAUSTED junior capital remained.
    uint256 public gAbsorbedWhileJuniorRemained;
    /// @dev Z, clause 2: an exit left a remaining holder worse off than a simultaneous exit
    ///      would have — measured as the stayers' coverage ratio falling across the call.
    uint256 public gStayersLeftWorseOff;
    /// @dev ADR-0034 requirement 3: a single draw exceeded the deficit standing before it.
    uint256 public gDrawExceededDeficit;
    /// @dev §1.3 ordering: layer 2 paid while layer 1 still held capital.
    uint256 public gLayer2PaidBeforeLayer1WasEmpty;
    /// @dev The solvency rule the contract enforces: no operation widens the deficit.
    uint256 public gDeficitWorsened;
    /// @dev AUDIT FIX (SWEEP-1 MRC-F1) — ADR-0034 requirement 3, ON THE SENIOR VAULT'S SIDE.
    ///      "The draw must not exceed what the cascade would have absorbed anyway; it brings
    ///      absorption FORWARD in time, it does not enlarge it." The exit draw burns curator
    ///      first-loss and sGROVE capital, which is the same capital `pendingSeniorImpairment()`
    ///      nets on the VAULT's behalf, so a drawn exit lowers `redemptionTotalAssets()`. That
    ///      fall is bounded, and must be: it may never exceed the junior capital actually drawn in
    ///      the same call, or the exit has ENLARGED absorption rather than advanced it.
    ///
    ///      WHAT THIS DELIBERATELY DOES *NOT* ASSERT, AND WHY — OWNER DECISION, NOT AN OVERSIGHT.
    ///      ADR-0034 Z's clause 2 ("no exit leaves a remaining holder worse off than a simultaneous
    ///      exit would have") is VIOLATED for an sUSDfr staker by the accepted Y-bis draw: an
    ///      unstaked holder is made whole at par out of layer 1/2 capital that also prices layer 3,
    ///      so the staker's exit price falls. MEASURED (SWEEP-1 MRC-F1): a 400,000.000000 par exit
    ///      burned 27,497.708e18 of curator first-loss and moved a staker's price from 200,000e18
    ///      to 192,502.291e18. Capping the draw to fix that is precisely the "CLAMPING" alternative
    ///      ADR-0034 Y-bis considered and REJECTED on 2026-08-08 ("degrades to the gross rate
    ///      precisely when junior capital matters most"). Reversing it is a Forest Road decision,
    ///      not a sweep-round one. It is carried in the SWEEP-1 open register as OWNER-BLOCKED.
    ///      This counter closes the BLINDNESS — the region is now in the state space and measured —
    ///      without silently re-deciding the economics in either direction.
    uint256 public gVaultFallExceededDraw;

    constructor(
        address usdfr_,
        address reserves_,
        address controller_,
        address curator_,
        address backstop_,
        address admin_,
        uint256 facility_,
        address[2] memory actors_,
        address vault_
    ) {
        usdfr = USDfr(usdfr_);
        reserves = ReserveManager(reserves_);
        controller = MintRedeemController(controller_);
        curator = CuratorModule(curator_);
        backstop = MockCascadeBackstop(backstop_);
        admin = admin_;
        facility = facility_;
        actors = actors_;
        vault = SUSDfr(vault_);
    }

    // ── measurement ──────────────────────────────────────────────────────

    function _supply() internal view returns (uint256) {
        return usdfr.totalSupply();
    }

    function _backing() internal view returns (uint256) {
        return reserves.totalBackingValue();
    }

    function _deficit() internal view returns (uint256) {
        uint256 s = _supply();
        uint256 b = _backing();
        return s > b ? s - b : 0;
    }

    /// @dev LAYER 1's live capacity: the sum of the five curator pools. This is the quantity
    ///      ADR-0034 Z means by "unexhausted junior capital" for the layer the finding was about.
    function curatorCapital() public view returns (uint256 total) {
        for (uint256 c = 1; c <= Config.NUM_CLASSES; ++c) {
            total += curator.poolBalance(c);
        }
    }

    /// @dev ADR-0035 layer-2 live capacity is exactly the physical shared reserve.
    function backstopCapital() public view returns (uint256) {
        return usdfr.balanceOf(address(backstop));
    }

    // ── actions ──────────────────────────────────────────────────────────

    /// @notice Governance recognises a CONSERVATIVE, REVERSIBLE mark. This is the action that
    ///         drives the protocol under-backed — the reach ADR-0034 Z requires and the tree did
    ///         not have.
    function recogniseMark(uint256 seed) external {
        ++callCount;
        uint256 face = reserves.deployedTo(facility);
        uint256 already = reserves.principalImpairmentOf(facility);
        if (face <= already) return;
        uint256 room = face - already;
        uint256 amount = bound(seed, 1, room);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(facility, amount, keccak256(abi.encode("Z-mark", seed)));
        ++gMarks;
    }

    /// @notice The mark reverses. ADR-0034 accepts explicitly that a draw already taken is NOT
    ///         clawed back; this action is what puts the resulting surplus in front of
    ///         `mintableHeadroom()`'s retention.
    function releaseMark(uint256 seed) external {
        ++callCount;
        uint256 recognized = reserves.principalImpairmentOf(facility);
        if (recognized == 0) return;
        uint256 amount = bound(seed, 1, recognized);
        vm.prank(admin);
        reserves.releasePrincipalImpairment(facility, amount, keccak256(abi.encode("Z-release", seed)));
        ++gReleases;
    }

    /// @notice Layer 2 is funded. Kept as a separate action so campaigns reach BOTH the
    ///         layer-1-only and the layer-1-then-layer-2 shapes of the draw.
    function fundBackstop(uint256 seed) external {
        ++callCount;
        address actor = actors[seed % 2];
        uint256 amount = bound(seed, 1e18, 20_000e18);
        if (usdfr.balanceOf(actor) < amount) return;
        vm.prank(actor);
        usdfr.transfer(address(backstop), amount);
    }

    /// @notice THE DRAWN EXIT. Everything this campaign asserts is measured across this call.
    function exit(uint256 seed) external {
        ++callCount;
        address actor = actors[seed % 2];
        uint256 balance = usdfr.balanceOf(actor);
        if (balance < UNIT) return;
        uint256 amount = bound(seed, UNIT, balance);

        uint256 supplyBefore = _supply();
        uint256 backingBefore = _backing();
        uint256 deficitBefore = _deficit();
        uint256 backstopBalanceBefore = usdfr.balanceOf(address(backstop));
        uint256 prepaidBefore = reserves.exitPrepaidAbsorption();
        uint256 vaultNavBefore = vault.totalSupply() == 0 ? 0 : vault.redemptionTotalAssets();

        vm.prank(actor);
        try controller.redeem(amount, 0, block.timestamp) returns (uint256 usdcOut) {
            ++gExits;
            uint256 usdfrIn = (amount / UNIT) * UNIT;
            uint256 drawn = reserves.exitPrepaidAbsorption() - prepaidBefore;
            if (drawn != 0) ++gDrawnExits;

            // ── ADR-0034 requirement 3: the draw brings absorption FORWARD, never enlarges it ──
            if (drawn > deficitBefore) ++gDrawExceededDeficit;

            // ── §1.3 ordering: layer 2 may pay ONLY once layer 1 is empty ────────────────────
            // MEASURED ON THE BALANCE, NOT ON CAPACITY (SWEEP-1 CSG-F1). "Capacity" is a derived
            // quantity that the standing-key ratchet can move UP across the same call; the
            // backstop's USDfr balance falls by exactly what it paid and can never rise inside a
            // redemption, so it is the honest measurement of "did layer 2 pay".
            uint256 fromLayer2 = backstopBalanceBefore - usdfr.balanceOf(address(backstop));
            if (fromLayer2 != 0) {
                ++gLayer2Draws;
                if (curatorCapital() != 0) ++gLayer2PaidBeforeLayer1WasEmpty;
            }

            // ── Z clause 1: no exit absorbs loss while unexhausted junior capital remains ─────
            uint256 valuePaid = usdcOut * UNIT;
            if (valuePaid < usdfrIn) {
                ++gSubParExits;
                // The exiter took a haircut. Layer 1 must be EXHAUSTED — a non-empty curator pool
                // here is the exact defect ADR-0034 exists to close: a senior absorbing a loss the
                // junior tranche contracted to take first.
                if (curatorCapital() != 0) ++gAbsorbedWhileJuniorRemained;
                else ++gExitsWithJuniorExhausted;
            } else if (deficitBefore != 0) {
                ++gParExitsUnderDeficit;
            }

            // ── Z clause 2: a stayer is never left worse off than a simultaneous exit ────────
            // A simultaneous exit pays everyone the same ratio, so "no worse off" is exactly
            // "the coverage ratio left behind did not fall". Cross-multiplied to avoid division.
            uint256 supplyAfter = _supply();
            uint256 backingAfter = _backing();
            if (supplyAfter != 0 && supplyBefore != 0) {
                if (backingAfter * supplyBefore < backingBefore * supplyAfter) ++gStayersLeftWorseOff;
            }

            // ── SWEEP-1 MRC-F1: the ADR-0034 X LAYER-3 HOLDER, measured ─────────────────────
            if (vaultNavBefore != 0) {
                ++gExitsWithALiveStaker;
                uint256 vaultNavAfter = vault.redemptionTotalAssets();
                if (vaultNavAfter < vaultNavBefore) {
                    ++gExitsThatLoweredTheVaultNav;
                    if (vaultNavBefore - vaultNavAfter > drawn) ++gVaultFallExceededDraw;
                }
            }

            uint256 deficitAfter = supplyAfter > backingAfter ? supplyAfter - backingAfter : 0;
            if (deficitAfter > deficitBefore) ++gDeficitWorsened;
        } catch {
            // Dust below the whole-USDC grid, an exhausted idle leg, or a zero-backing book. None
            // of these move value, and the campaign asserts that below.
            if (reserves.exitPrepaidAbsorption() != prepaidBefore) ++gDrawExceededDeficit;
        }
    }
}
