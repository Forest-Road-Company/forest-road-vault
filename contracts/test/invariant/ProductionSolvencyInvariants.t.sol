// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {SolvencyHandler} from "./SolvencyHandler.sol";

/// @title INV_SolvencyConservation — Phase D invariant family: SOLVENCY AND CONSERVATION
///
/// @notice Encodes `audit/SYSTEM_MODEL.md` section 6 invariants **INV-1, INV-2, INV-3 and INV-4**
///         over the fully composed production stack, with every reference quantity maintained as
///         a GHOST IN THE HANDLER, derived from the amounts the handler passed in — never read
///         back from the contract being checked. Where an existing repo suite already asserts a
///         property, this suite deliberately asserts a DIFFERENT and stronger one; the overlaps
///         and the deltas are named per invariant below.
///
/// @dev    Run:
///           forge test --match-contract INV_SolvencyConservation
///           FOUNDRY_PROFILE=heavy forge test --match-contract INV_SolvencyConservation
///
///         Reserve-loss recoverability is covered separately by the atomic reserve-loss and
///         cascade suites. This family reconstructs ordinary backing and conservation flows.
contract INV_SolvencyConservation is CreditLayerFixture {
    SolvencyHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SolvencyHandler(
            SolvencyHandler.Wiring({
                usdc: address(usdc),
                usdfr: address(usdfr),
                compliance: address(compliance),
                reserves: address(reserves),
                controller: address(controller),
                vault: address(vault),
                registry: address(registry),
                bridge: address(bridge),
                oracle: address(oracle),
                waterfall: address(waterfall),
                queue: address(queue),
                servicer: servicer,
                originator: originator,
                custodian: custodian,
                feeRecipient: feeRecipient,
                borrower: borrower,
                complianceAdmin: complianceAdmin
            })
        );
        // D7-01: this handler models the dedicated keeper when it exercises queue settlement.
        vm.prank(admin);
        queue.grantRole(Roles.SETTLEMENT_KEEPER_ROLE, address(handler));
        targetContract(address(handler));

        // EVERY action is registered explicitly. An unregistered handler function is dead code
        // in a suite that declares a selector whitelist, and the campaign's call table is
        // checked after each run to confirm each of these actually fired.
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = SolvencyHandler.mintUSDfr.selector;
        selectors[1] = SolvencyHandler.redeemUSDfr.selector;
        selectors[2] = SolvencyHandler.depositToVault.selector;
        selectors[3] = SolvencyHandler.originateAndFund.selector;
        selectors[4] = SolvencyHandler.repayWithInterest.selector;
        selectors[5] = SolvencyHandler.requestQueueExit.selector;
        selectors[6] = SolvencyHandler.settleAndClaim.selector;
        selectors[7] = SolvencyHandler.queueRoundTrip.selector;
        selectors[8] = SolvencyHandler.donateAndReconcile.selector;
        selectors[9] = SolvencyHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INV-1 — BACKING
    // ═══════════════════════════════════════════════════════════════════

    /// @notice INV-1. `USDfr.totalSupply() <= ReserveManager.totalBackingValue()` at the end of
    ///         every transaction.
    /// @dev Overlaps `BackingFocusedInvariants` deliberately: it is the family's headline
    ///      property and must be asserted over THIS action set (which reaches the queue exit
    ///      path and the adversarial custody perturbations that suite never touches).
    function invariant_INV1_supplyNeverExceedsBacking() public view {
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue(), "INV-1 VIOLATED: supply exceeds backing");
    }

    /// @notice INV-1, restated over the INDEPENDENT model. Both sides are reconstructed in the
    ///         handler from the amounts it passed in, so this holds or fails without consulting
    ///         `ReserveManager` or `USDfr` at all.
    /// @dev This is the falsifying form. The assertion above compares two live contracts against
    ///      each other and would still pass if BOTH drifted together; this one cannot.
    function invariant_INV1_modelledSupplyNeverExceedsModelledBacking() public view {
        assertLe(handler.modelledSupply(), handler.modelledBacking(), "INV-1 VIOLATED IN THE INDEPENDENT MODEL");
    }

    /// @notice The USDfr supply equals mints minus burns, reconstructed entirely from handler
    ///         inputs. Any mint or burn the protocol performs that the handler did not authorise
    ///         breaks this, in either direction.
    function invariant_INV1_supplyReconstructsFromHandlerInputs() public view {
        assertEq(usdfr.totalSupply(), handler.modelledSupply(), "USDfr SUPPLY DIVERGED FROM THE INDEPENDENT MODEL");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INV-2 — RESERVE RECONCILIATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice INV-2, part 1: the ledger may never claim more USDC than is actually in custody.
    /// @dev `BackingFocusedInvariants` asserts this too, but only over deposit/deploy/repay.
    ///      Here it is asserted under ADVERSARIAL INTERLEAVING: unsolicited USDC donations
    ///      straight to the reserve address, the permissionless and unpausable
    ///      `reconcileIdleUSDC` fired between every other operation, the controller's release
    ///      path (redeem), the credit layer's deployment path (fund) and the repayment path,
    ///      all in arbitrary order.
    function invariant_INV2_idleLedgerNeverExceedsCustody() public view {
        assertLe(
            reserves.idleUSDC(), usdc.balanceOf(address(reserves)), "INV-2 VIOLATED: ledger claims USDC not in custody"
        );
    }

    /// @notice INV-2, part 2: the idle ledger equals the independently accumulated ghost.
    /// @dev THE DELTA versus every existing suite. `BackingFocusedInvariants` asserts
    ///      `totalBackingValue() == idleReserve() + deployedPrincipal()`, which is the
    ///      production expression re-derived from the production accessors and therefore cannot
    ///      falsify it. `TokenLayerInvariants` recomputes idle as `balanceOf * 1e12`, which is
    ///      only correct while nothing has ever been donated — this campaign donates
    ///      deliberately, so that recomputation would be wrong here. This ghost is accumulated
    ///      from the exact amounts the handler moved and is independent of both.
    function invariant_INV2_idleLedgerMatchesIndependentGhost() public view {
        assertEq(reserves.idleUSDC(), handler.gIdleUnits(), "INV-2 VIOLATED: idle ledger diverged from the model");
    }

    /// @notice INV-2, part 3: backing decomposes into idle plus deployed with NO DOUBLE COUNT,
    ///         where both components are the independent ghosts.
    /// @dev A double count would make `totalBackingValue()` exceed the sum of the independently
    ///      tracked parts while still satisfying the inequality of INV-1 — the failure mode that
    ///      an inequality-only backing test cannot see.
    function invariant_INV2_backingDecomposesWithoutDoubleCount() public view {
        assertEq(
            reserves.totalBackingValue(), handler.modelledBacking(), "INV-2 VIOLATED: backing is not idle + deployed"
        );
        assertEq(
            reserves.deployedPrincipal(),
            handler.gDeployedValue(),
            "INV-2 VIOLATED: deployed principal diverged from the model"
        );
    }

    /// @notice INV-2, part 4: per-facility deployed principal reconciles to the sum of its parts.
    function invariant_INV2_perFacilityDeployedReconciles() public view {
        uint256 n = handler.facilityCount();
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.facilityAt(i);
            assertEq(reserves.deployedTo(id), handler.gDeployedTo(id), "INV-2 VIOLATED: per-facility principal drift");
            sum += reserves.deployedTo(id);
        }
        assertEq(reserves.deployedPrincipal(), sum, "INV-2 VIOLATED: total deployed is not the sum of facilities");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INV-3 — WATERFALL CONSERVATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice INV-3, part 1: summed over the WHOLE campaign, distributed interest splits
    ///         exactly into protocol fee plus senior yield. Nothing created, nothing destroyed.
    /// @dev `CreditHandler` already asserts the split PER CALL. The addition here is the
    ///      campaign-level accumulation: a per-call assert cannot see a drift that only appears
    ///      across many calls (for example a fee that is correct each time but double-counted
    ///      into a running total, or a rounding residue that accumulates).
    function invariant_INV3_interestSplitsExactlyOverTheCampaign() public view {
        assertEq(
            handler.gInterestTotal(),
            handler.gFeeTotal() + handler.gToVaultTotal(),
            "INV-3 VIOLATED: interest != fee + toVault over the campaign"
        );
    }

    /// @notice INV-3, part 2: the MEASURED credits equal the MODELLED split, campaign-wide.
    /// @dev `gFeeCredited` / `gVaultCredited` are measured balance deltas around each
    ///      `distribute`; `gFeeTotal` / `gToVaultTotal` are computed from the spec constant
    ///      `DEFAULT_PROTOCOL_FEE_BPS` and the interest the handler passed in. The two are
    ///      derived by different routes, so equality is falsifiable.
    function invariant_INV3_measuredCreditsMatchTheModelledSplit() public view {
        assertEq(handler.gFeeCredited(), handler.gFeeTotal(), "INV-3 VIOLATED: measured protocol fee != model");
        assertEq(handler.gVaultCredited(), handler.gToVaultTotal(), "INV-3 VIOLATED: measured senior yield != model");
    }

    /// @notice INV-3, part 3: the protocol fee recipient's ENTIRE USDfr balance is reconstructed
    ///         from handler inputs — every distribution fee plus every origination fee, and
    ///         nothing else. The recipient never spends in this campaign, so this is an exact
    ///         independent reconstruction of a live balance.
    function invariant_INV3_feeRecipientBalanceReconstructs() public view {
        assertEq(
            usdfr.balanceOf(feeRecipient),
            handler.gFeeTotal() + handler.gOriginationFeeTotal(),
            "INV-3 VIOLATED: fee recipient balance is not the sum of its authorised credits"
        );
    }

    /// @notice INV-3, part 4: principal repayment decreases deployed exposure by exactly the
    ///         principal, cumulatively. Deployed = everything funded and capitalised, minus
    ///         everything repaid.
    function invariant_INV3_principalReturnsExactly() public view {
        assertEq(
            reserves.deployedPrincipal() + handler.gPrincipalRepaid(),
            handler.gOriginationFeeTotal() + handler.gDeployedGross(),
            "INV-3 VIOLATED: deployed exposure did not fall by exactly the principal repaid"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  INV-4 — NO VALUE CREATION
    // ═══════════════════════════════════════════════════════════════════

    /// @notice INV-4, part 1 (aggregate). No sequence of permissionless operations lets the set
    ///         of ordinary actors collectively end holding more than they paid in plus the
    ///         genuine attested yield the protocol actually distributed to the senior vault.
    /// @dev Holdings are valued OPTIMISTICALLY (realized NAV, not the conservative exit NAV) and
    ///      include wallet USDC, wallet USDfr, vault shares, unfilled queue positions and
    ///      unclaimed fills — so the left side is an over-statement and the bound is strictly
    ///      harder to satisfy than reality.
    function invariant_INV4_noAggregateValueCreation() public view {
        assertLe(
            handler.aggregateHeldValue(),
            handler.aggregateValueIn() + handler.gToVaultTotal() + handler.gRoundingSlack(),
            "INV-4 VIOLATED: actors collectively hold more than they paid in plus genuine yield"
        );
    }

    /// @notice INV-4, part 2 (per actor). No individual actor ends ahead of what it paid in plus
    ///         its INDEPENDENTLY MODELLED pro-rata share of each yield event, plus anything
    ///         anyone voluntarily donated into the vault.
    /// @dev The pro-rata model is snapshotted in the handler immediately BEFORE each
    ///      distribution, from the actor's effective share count (wallet plus queued) over total
    ///      supply, rounded UP. That is a strict over-estimate — the fee checkpoint inside
    ///      `distribute` mints performance shares that dilute the actor further — which is the
    ///      direction that keeps this a sound ceiling rather than a re-derivation of the payout.
    function invariant_INV4_noActorExceedsItsProRataEntitlement() public view {
        for (uint256 i = 0; i < 3; ++i) {
            address actor = handler.actorAt(i);
            assertLe(
                handler.heldValue(actor),
                handler.valueCeiling(actor),
                "INV-4 VIOLATED: an actor gained beyond its entitlement"
            );
        }
    }

    /// @notice INV-4, part 3. The queue can only ever hold USDfr it was actually filled with:
    ///         the claimable book never exceeds the USDfr physically in the queue's custody.
    ///         A double-credit would show here as a claim on value that is not there.
    function invariant_INV4_queueClaimBookIsFullyBacked() public view {
        uint256 n = queue.totalRequests();
        uint256 claimable;
        for (uint256 i = 0; i < n; ++i) {
            (,, uint256 amount,,) = queue.request(i);
            claimable += amount;
        }
        assertLe(claimable, usdfr.balanceOf(address(queue)), "INV-4 VIOLATED: queue owes more USDfr than it holds");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ANTI-VACUITY
    // ═══════════════════════════════════════════════════════════════════

    /// @notice A campaign that never reached the interesting states and reported green is worse
    ///         than no campaign. `afterInvariant` runs once per RUN and handler ghosts reset
    ///         between runs (verified empirically for this Foundry version), so every witness
    ///         below must be produced within a single sequence. Each one is produced by at least
    ///         TWO registered selectors, which is what makes the gate reliable rather than flaky.
    function afterInvariant() public {
        emit log_named_uint("REACH mints", handler.nMints());
        emit log_named_uint("REACH redeems", handler.nRedeems());
        emit log_named_uint("REACH vault deposits", handler.nDeposits());
        emit log_named_uint("REACH queue requests", handler.nRequests());
        emit log_named_uint("REACH settlement fills", handler.nFills());
        emit log_named_uint("REACH queue claims", handler.nClaims());
        emit log_named_uint("REACH facilities funded", handler.nFundings());
        emit log_named_uint("REACH distributions", handler.nDistributions());
        emit log_named_uint("REACH reconciles", handler.nReconciles());
        emit log_named_uint("REACH full round trips", handler.nRoundTrips());
        emit log_named_uint("REACH senior yield distributed", handler.gToVaultTotal());
        emit log_named_uint("REACH usdc donated to reserve", handler.gDonatedUSDC());

        assertGt(handler.gMinted(), 0, "VACUOUS: no USDfr was ever minted");
        assertGt(handler.nFundings(), 0, "VACUOUS: no facility was ever funded");
        assertGt(handler.gOriginationFeeTotal(), 0, "VACUOUS: no protocol fee share was ever actually minted");
        assertGt(handler.gToVaultTotal(), 0, "VACUOUS: no genuine attested yield ever reached the senior vault");
        assertGt(handler.nRequests(), 0, "VACUOUS: no redemption request ever entered the queue");
        assertGt(handler.nFills(), 0, "VACUOUS: no redemption request was ever filled at settlement");
        assertGt(handler.nClaims(), 0, "VACUOUS: no queue claim ever completed");
        assertGt(handler.nRedeems(), 0, "VACUOUS: no USDfr was ever redeemed back to USDC");
        assertGt(handler.gDonatedUSDC(), 0, "VACUOUS: the adversarial custody donation never fired");
        assertGt(handler.nReconciles(), 0, "VACUOUS: reconcileIdleUSDC was never exercised");
        // The custody inequality of INV-2 must have been NON-TRIVIAL at least once: a campaign
        // in which the ledger always equalled the balance never tested the strict direction.
        assertGt(
            usdc.balanceOf(address(reserves)),
            reserves.idleUSDC(),
            "VACUOUS: the idle-ledger custody bound was never strict"
        );
    }
}
