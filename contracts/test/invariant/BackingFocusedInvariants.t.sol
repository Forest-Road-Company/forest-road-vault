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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = CreditHandler.depositAndStake.selector;
        selectors[1] = CreditHandler.originate.selector;
        selectors[2] = CreditHandler.fund.selector;
        selectors[3] = CreditHandler.repay.selector;
        selectors[4] = CreditHandler.realizeLoss.selector;
        selectors[5] = CreditHandler.fundBackstop.selector;
        selectors[6] = CreditHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice INVARIANT (§1.3, ADR-0012): USDfr supply never exceeds backing value.
    /// @dev The symbolic artifact proves selected transition lemmas for all inputs. This
    ///      campaign checks their composition over the concrete sequences it reaches, which
    ///      is a different and still sampling-based assurance layer.
    function invariant_backing_holdsUnderDeepSupplySequences() public view {
        assertLe(controller.totalUSDfr(), controller.backingValue(), "BACKING VIOLATED");
    }

    /// @notice The backing figure must stay decomposable into its parts, not merely be large
    ///         enough. A backing number that happened to exceed supply while its components
    ///         had drifted would satisfy the inequality above and still be wrong.
    function invariant_backing_reconcilesToItsComponents() public view {
        assertEq(
            reserves.totalBackingValue(),
            reserves.idleReserve() + reserves.deployedPrincipal(),
            "BACKING COMPONENTS DRIFTED"
        );
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
