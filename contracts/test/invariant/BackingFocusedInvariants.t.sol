// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {CreditHandler} from "./handlers/CreditHandler.sol";

/// @title Backing invariant — narrow, deep campaign
/// @notice CLAUDE.md §1.5 names TWO properties for formal treatment: the loss cascade and the
///         backing invariant. `test/symbolic/BackingSymbolic.t.sol` now proves five induction
///         properties: four execute the real controller/reserve implementations through proxies,
///         and one proves the full-domain equal-delta lemma used by user mint/redeem. The exact
///         scope and token-model trust boundary are recorded in
///         `docs/formal-methods-amenability.md`; it is not a claim that the whole composed
///         protocol is formally verified.
///
///         This suite remains the complementary NARROW, DEEP search over the fully composed
///         production contracts: the general credit
///         campaign spreads its call budget across seventeen selectors and many entities, so
///         any individual sequence that stresses backing is shallow. Here the selector set is
///         cut to those that can actually move `totalUSDfr()` or `totalBackingValue()`, and the
///         depth is raised well past the default, so the campaign walks long sequences of
///         supply- and backing-moving operations rather than sampling them thinly.
///
///         The motivating evidence is concrete: a round-9 audit finding was a servicing dead
///         end reachable only after a facility had been amortised through many sequential
///         receipts, and the reviewer noted the invariant campaign provably could not reach it
///         because its depth budget was spread across too many actions and entities.
///
///         Run the deep configuration with:
///           FOUNDRY_PROFILE=heavy forge test --match-path "test/invariant/BackingFocusedInvariants.t.sol"
contract BackingFocusedInvariants is CreditLayerFixture {
    CreditHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CreditHandler(
            [address(usdc), address(usdfr), address(compliance), address(reserves), address(controller), address(vault)],
            [
                address(registry),
                address(bridge),
                address(oracle),
                address(curator),
                address(waterfall),
                address(defaultManager)
            ],
            address(backstopMock),
            [servicer, anchorCurator, originator, custodian, feeRecipient, borrower],
            complianceAdmin
        );
        handler.setVaultAdmin(admin);
        // AUDIT FIX (G3): wire the ReserveManager's timelocked admin so this campaign — and only
        // this campaign — can drive the conservative-mark path. Every other campaign leaves the
        // G3 actions inert by simply never calling this.
        handler.setReserveGovernor(admin);
        targetContract(address(handler));

        // ONLY the selectors that can move supply or backing. Everything else — past-due
        // marking, curator posts, points, governance re-tunes — is deliberately excluded so
        // the whole call budget is spent on the accounting identity itself.
        //
        //   depositAndStake  supply in, vault share math
        //   originate/fund   backing moves from idle USDC to deployed principal
        //   repay            deployed principal back to idle, interest minted as yield
        //   realizeLoss      the only path that burns senior principal
        //   fundBackstop     changes how much of a loss reaches layer 3
        //   warp             lets vesting actually elapse between operations
        //
        // AUDIT FIX (G3) — THREE SELECTORS ADDED, DELIBERATELY. The set above could not reach
        // the region finding G3 is about, and could not even reach the cascade:
        //   declareDefault   nothing here declared a default, so `realizeLoss` early-returned on
        //                    EVERY call and this campaign never burned a single dollar of senior
        //                    principal despite listing `realizeLoss` as its reason for existing;
        //   markUnabsorbableLoss  walks INTO the over-capacity region on purpose (see the reach
        //                    note on the handler action) — `realizeLoss` bounds its fuzzed loss BY
        //                    capacity to stay revert-free, which is exactly what kept the campaign
        //                    out of the defective state;
        //   releaseImpairmentMark  lets the campaign leave the closed state again, so one mark
        //                    does not latch the rest of the sequence into no-ops;
        //   recoverAgainstStandingMark  collects cash on the marked facility, which is the only
        //                    way this campaign exercises the automatic consumption of a mark when
        //                    FACE falls (`repay` skips while the protocol is closed, and a mark
        //                    is what closes it).
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = CreditHandler.depositAndStake.selector;
        selectors[1] = CreditHandler.originate.selector;
        selectors[2] = CreditHandler.fund.selector;
        selectors[3] = CreditHandler.repay.selector;
        selectors[4] = CreditHandler.realizeLoss.selector;
        selectors[5] = CreditHandler.fundBackstop.selector;
        selectors[6] = CreditHandler.warp.selector;
        selectors[7] = CreditHandler.declareDefault.selector;
        selectors[8] = CreditHandler.markUnabsorbableLoss.selector;
        selectors[9] = CreditHandler.releaseImpairmentMark.selector;
        selectors[10] = CreditHandler.recoverAgainstStandingMark.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (§1.3, ADR-0012): USDfr supply never exceeds backing value — while
    ///         nothing has been marked down. UNCHANGED AND UNWEAKENED in that domain.
    /// @dev The symbolic artifact proves selected transition lemmas for all inputs. This
    ///      campaign checks their composition over the concrete sequences it reaches, which
    ///      is a different and still sampling-based assurance layer.
    ///
    ///      AUDIT FIX (G3) — WHY THIS IS NOW CONDITIONAL, and why that is not a weakening. Before
    ///      G3, `totalBackingValue()` was pure FACE value, so this assertion held unconditionally
    ///      for a reason that had nothing to do with solvency: the right-hand side simply could
    ///      not fall when a claim became worthless. Once backing is reported at conservative
    ///      marks, a loss beyond total cascade capacity makes supply GENUINELY exceed backing —
    ///      the protocol is under-backed, and no implementation can hold the unconditional form
    ///      except by refusing to mark. The property that actually protects holders is the pair
    ///      below: strict par while nothing is marked, and — always — no unexplained gap.
    function invariant_backing_holdsWhileNothingIsMarkedDown() public view {
        if (reserves.totalPrincipalImpairment() != 0) return;
        assertLe(controller.totalUSDfr(), controller.backingValue(), "BACKING VIOLATED");
    }

    /// @notice INVARIANT (§1.3, AUDIT FIX G3): every dollar by which supply exceeds backing is a
    ///         dollar of EXPLICITLY RECOGNISED, evented impairment. Nothing may ever open a gap
    ///         silently — that is the property the face-value implementation could not offer,
    ///         because it could not open a gap at all and therefore could not report one either.
    function invariant_backing_noUnexplainedUnbacking() public view {
        uint256 supply = controller.totalUSDfr();
        uint256 backing = controller.backingValue();
        if (supply <= backing) return;
        assertLe(supply - backing, reserves.totalPrincipalImpairment(), "UNEXPLAINED UNBACKING");
    }

    /// @notice The backing figure must stay decomposable into its parts, not merely be large
    ///         enough. A backing number that happened to exceed supply while its components
    ///         had drifted would satisfy the inequality above and still be wrong.
    /// @dev AUDIT FIX (G3): the identity gains its third term. It previously read
    ///      `totalBackingValue() == idleReserve() + deployedPrincipal()` — the FACE identity —
    ///      and that is precisely the defect stated as a required invariant, so it goes red
    ///      against any correct fix. Updated deliberately: face is still the first two terms,
    ///      and the conservative mark is subtracted from them.
    function invariant_backing_reconcilesToItsComponents() public view {
        assertEq(
            reserves.totalBackingValue(),
            reserves.idleReserve() + reserves.deployedPrincipal() - reserves.totalPrincipalImpairment(),
            "BACKING COMPONENTS DRIFTED"
        );
    }

    /// @notice INVARIANT (AUDIT FIX G3): the recognised mark never exceeds the face it qualifies,
    ///         and the ledger reconciles to an independent recomputation of every mark this
    ///         campaign asked for, net of every face decrease that should have consumed one.
    /// @dev The ceiling is what keeps the subtraction inside `totalBackingValue()` from
    ///      underflowing — an underflow there would revert every mint, redeem and backing read.
    ///      The reconciliation is what catches a dropped release: delete the
    ///      `_consumeImpairmentOnFaceDecrease` call in `recordPrincipalWritedown` or
    ///      `recordPayment` and the contract's ledger stays high while this ghost falls.
    function invariant_backing_impairmentLedgerReconciles() public view {
        assertLe(
            reserves.totalPrincipalImpairment(), reserves.deployedPrincipal(), "MARK EXCEEDS THE FACE IT QUALIFIES"
        );
        assertEq(reserves.totalPrincipalImpairment(), handler.ghostTotalMark(), "IMPAIRMENT LEDGER DIVERGED");
    }

    /// @notice G3 REACH TELEMETRY, read so the numbers surface in traces rather than being
    ///         assumed. `ghostOverCapacityMarks` counts how often the campaign actually reached a
    ///         defaulted facility whose outstanding EXCEEDED total cascade capacity — the region
    ///         `realizeLoss`'s own capacity bound kept this suite out of. It is NOT asserted
    ///         non-zero per run: reaching it needs a large funded facility declared in default
    ///         while the vault stays small, which no single 128-call sequence is guaranteed to
    ///         order. The deterministic proof that the region is reachable and handled lives in
    ///         `test/audit/Fix_G3-conservative-backing-marks.t.sol`; this measures how often the
    ///         stateful campaign gets there too.
    function invariant_backing_g3ReachTelemetry() public view {
        handler.ghostOverCapacityMarks();
        handler.ghostMarkReleases();
        handler.ghostImpairedRecoveries();
    }

    /// @notice The idle ledger may never claim more USDC than is actually in custody. This is
    ///         the property the monotone-down reconciliation primitive rests on, and it was
    ///         previously implied only by per-function unit tests — an earlier audit round
    ///         explicitly recommended asserting it at the invariant layer.
    function invariant_backing_idleLedgerNeverExceedsCustody() public view {
        assertLe(reserves.idleUSDC(), usdc.balanceOf(address(reserves)), "IDLE LEDGER EXCEEDS ACTUAL USDC CUSTODY");
    }

    /// @dev Anti-vacuity. A campaign that never mints, never deploys and never realises a loss
    ///      would pass every assertion above while proving nothing at all. Fail the run rather
    ///      than report a green result for a search that did not happen.
    function afterInvariant() public view {
        assertGt(controller.totalUSDfr(), 0, "VACUOUS: no supply was ever minted");
        assertGt(handler.callCount(), 0, "VACUOUS: the handler was never called");
    }
}
