// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {ISeniorExitDrawSource} from "../../src/interfaces/ISeniorExitDrawSource.sol";
import {Config} from "../../src/libraries/Config.sol";
import {CascadeOrderedExitHandler} from "./handlers/CascadeOrderedExitHandler.sol";

/// @dev THE FALSIFIER. A draw source that answers "nothing drawn" in every state — which is
///      EXACTLY the protocol as it stood before ADR-0034 Y-bis, where `redeem` priced off the
///      gross book mark and junior capital was never consulted. Wiring this in must make the Z
///      invariants go RED. It is the evidence that the properties below have teeth rather than
///      passing because the campaign never reaches the region.
contract NullExitDrawSource is ISeniorExitDrawSource {
    address internal immutable RESERVES;

    constructor(address reserves_) {
        RESERVES = reserves_;
    }

    function reserveLossSource() external view returns (address) {
        return RESERVES;
    }

    /// @dev Reads its operand and returns a value derived from it, so this is a BEHAVIOURAL
    ///      falsifier and not a compile-time one.
    function drawForSeniorExit(uint256 required) external pure returns (uint256) {
        return required * 0;
    }
}

/// @title ADR-0034 decision Z — cascade ORDERING as a stateful invariant on the DRAWN exit path
///
/// @notice WHAT ADR-0034 Z REQUIRES, VERBATIM: "an invariant asserting no redemption sequence
///         allows a senior or USDfr holder to absorb loss while unexhausted junior capital
///         remains — equivalently, that no exit leaves a remaining holder worse off than a
///         simultaneous exit would have", encoded "as a stateful fuzz property rather than a unit
///         assertion", together with "a handler action that drives the protocol under-backed and
///         then redeems".
///
///         THIS CORRECTS `SubParExitInvariants`, WHICH RECORDED THE PROPERTY AS UNASSERTABLE.
///         That file states — correctly, at the time — that Z "cannot be asserted against this
///         code because decision Y ... is not implemented: the property is FALSE of the shipped
///         contract by construction, and an invariant written to pass against it would be an
///         invariant written to accept the defect". Y-bis is now implemented, so the property is
///         ENCODED rather than deferred, and that NatSpec has been corrected in the same change.
///         It was never weakened — it is inverted.
///
/// @dev ANTI-VACUITY IS PROVED TWICE, AND NEITHER PROOF DEPENDS ON A SEED.
///        1. `test_Z_antiVacuity_theDrawnDomainIsDeterministicallyReachable` drives the handler's
///           OWN actions in a fixed order and asserts each witness directly — a drawn exit, a
///           SUB-PAR exit with junior exhausted, and a layer-2 draw.
///        2. `test_Z_theInvariantRedsAgainstADeliberatelyBrokenDraw` re-runs the SAME property
///           against a draw source that draws nothing — the pre-ADR protocol — and asserts the
///           violation counter goes NON-ZERO. An invariant that cannot be broken is not an
///           invariant, and this is the check the tree was missing.
contract CascadeOrderedExitInvariants is CreditLayerFixture {
    uint256 internal constant FILM = Config.CLASS_FILM_TAX_CREDITS;
    uint256 internal constant FIRST_LOSS = 40_000e18;
    uint256 internal constant PRINCIPAL = 400_000e18;

    CascadeOrderedExitHandler internal handler;
    uint256 internal facilityId;

    function setUp() public virtual override {
        super.setUp();
        vm.prank(admin);
        curator.setCuratorApproved(FILM, anchorCurator, true);

        _mintUSDfrTo(alice, 800_000e18);
        _mintUSDfrTo(bob, 800_000e18);
        _postFirstLoss(anchorCurator, FILM, FIRST_LOSS);

        // AUDIT FIX (SWEEP-1 MRC-F1) — THE ADR-0034 X LAYER-3 HOLDER, WHICH THIS CAMPAIGN DID NOT
        // HAVE. Before this line there was NO sUSDfr staker anywhere in the Z campaign's state
        // space: `grep -c "vault"` over the handler returned ZERO, and clause 2 was encoded purely
        // as the UNSTAKED book's coverage ratio. That is lesson 2 verbatim — an invariant that
        // passes because its handler never reaches the region — and ADR-0034 Z requires the
        // property to cover "a senior OR USDfr holder". DO NOT REMOVE THIS STAKE.
        address seniorStaker = makeAddr("Z-senior-staker");
        vm.prank(complianceAdmin);
        compliance.setAllowed(seniorStaker, true);
        _mintUSDfrTo(seniorStaker, 200_000e18);
        vm.startPrank(seniorStaker);
        usdfr.approve(address(vault), 200_000e18);
        vault.deposit(200_000e18, seniorStaker);
        vm.stopPrank();

        facilityId = _originateFilm(BORROWER_1, STATE_GA, PRINCIPAL);
        _fundFacility(facilityId, PRINCIPAL);

        handler = new CascadeOrderedExitHandler(
            address(usdfr),
            address(reserves),
            address(controller),
            address(curator),
            address(backstopMock),
            admin,
            facilityId,
            [alice, bob],
            address(vault)
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CascadeOrderedExitHandler.recogniseMark.selector;
        selectors[1] = CascadeOrderedExitHandler.releaseMark.selector;
        selectors[2] = CascadeOrderedExitHandler.fundBackstop.selector;
        selectors[3] = CascadeOrderedExitHandler.exit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  THE INVARIANTS (ADR-0034 Z, CLAUDE.md §1.3 "loss cascade ordering")
    // ─────────────────────────────────────────────────────────────────────

    /// @notice INVARIANT — Z, CLAUSE 1. No exit absorbs loss while UNEXHAUSTED junior capital
    ///         remains. Operationally: if the settlement was SUB-PAR, curator first-loss capital
    ///         must be empty afterwards. This is the exact defect ADR-0034 was written to close —
    ///         a holder haircut at the gross mark while the tranche contracted to take first loss
    ///         sat intact — and it is FALSE of the pre-Y-bis contract by construction, which is
    ///         what `test_Z_theInvariantRedsAgainstADeliberatelyBrokenDraw` demonstrates.
    function invariant_Z_noExitAbsorbsLossWhileJuniorCapitalRemains() public view {
        assertEq(
            handler.gAbsorbedWhileJuniorRemained(),
            0,
            "AN EXIT ABSORBED LOSS WHILE UNEXHAUSTED CURATOR FIRST-LOSS CAPITAL REMAINED"
        );
    }

    /// @notice INVARIANT — Z, CLAUSE 2. No exit leaves a remaining holder worse off than a
    ///         simultaneous exit would have. A simultaneous exit pays every holder the same
    ///         coverage ratio, so the property is exactly "the ratio left behind never falls".
    ///         Measured cross-multiplied, so no division rounding can mask a violation.
    function invariant_Z_noExitLeavesAStayerWorseOffThanASimultaneousExit() public view {
        assertEq(handler.gStayersLeftWorseOff(), 0, "AN EXIT LOWERED THE COVERAGE RATIO FOR THE HOLDERS WHO STAYED");
    }

    /// @notice ANTI-VACUITY FOR THE LAYER-3 CLAUSE (AUDIT FIX, SWEEP-1 MRC-F1). The bound
    ///         asserted by `invariant_Z_theVaultFallNeverExceedsTheJuniorCapitalDrawn` is vacuous
    ///         unless an exit can actually LOWER the senior vault's redemption NAV. It can, and
    ///         this drives it deterministically rather than hoping a seed reaches it: a mark
    ///         LARGER than the standing junior capacity puts the vault below par, and an exit then
    ///         burns more of that capacity out from under it. NO ASSERTION HERE DEPENDS ON A SEED.
    function test_Z_antiVacuity_theLayer3HolderIsInTheStateSpaceAndMoves() public {
        assertGt(vault.totalSupply(), 0, "VACUOUS: the campaign has no sUSDfr staker at all");

        // WHAT PRICES THE VAULT is `pendingSeniorImpairment()`, and that is fed by the DECLARED
        // and PAST-DUE cohorts — NOT by a G3 `recognizePrincipalImpairment` mark, which moves
        // `totalBackingValue()` instead. The handler's four actions cannot reach the declared
        // cohort, so the default is declared here, in the deterministic test, on a SECOND
        // facility. See this campaign's OWED note: giving the stateful handler its own
        // declare-default action is the remaining half of SWEEP-1 MRC-F1's test-side work.
        uint256 declared = _originateFilm(BORROWER_2, STATE_GA, 200_000e18);
        _fundFacility(declared, 200_000e18);
        _attestDefault(declared);
        vm.prank(servicer);
        defaultManager.declareDefault(declared, FILM_REF);

        // A mark larger than layer 1's 40,000 puts the senior vault below par to begin with.
        handler.recogniseMark(80_000e18);
        assertGt(defaultManager.pendingSeniorImpairment(), 0, "the declared cohort must exceed junior capacity");
        uint256 navBefore = vault.redemptionTotalAssets();
        assertGt(navBefore, 0, "VACUOUS: the vault is already at its floor, so nothing can fall");
        assertGt(handler.curatorCapital(), 0, "VACUOUS: there is no junior capital left for an exit to burn");

        handler.exit(300_000e18);

        assertGt(handler.gExitsWithALiveStaker(), 0, "VACUOUS: the exit was not measured against the staker");
        assertGt(
            handler.gExitsThatLoweredTheVaultNav(),
            0,
            "VACUOUS: no exit ever moved the senior vault's redemption NAV - the region is unreached"
        );
        assertLt(vault.redemptionTotalAssets(), navBefore, "the layer-3 holder's price did not move");
        // ...and the BOUND held while it moved. That is the point: the fall is real, it is
        // measured, and it never exceeds the junior capital the exit actually drew.
        assertEq(handler.gVaultFallExceededDraw(), 0, "requirement 3, vault side");
    }

    /// @notice INVARIANT — ADR-0034's THIRD BINDING REQUIREMENT, ON THE SENIOR VAULT'S SIDE
    ///         (AUDIT FIX, SWEEP-1 MRC-F1). The exit draw burns curator first-loss and sGROVE
    ///         capital, which is the same capital `pendingSeniorImpairment()` nets on the sUSDfr
    ///         vault's behalf — so a drawn exit lowers `redemptionTotalAssets()` in the same
    ///         transaction. That fall must be BOUNDED BY THE CAPITAL ACTUALLY DRAWN, or the exit
    ///         has ENLARGED absorption rather than advanced it, which ADR-0034 forbids outright.
    ///
    ///         READ `CascadeOrderedExitHandler.gVaultFallExceededDraw`'s NatSpec BEFORE
    ///         STRENGTHENING THIS. The stronger property — Z clause 2 for a STAKER, i.e. the vault
    ///         price never falls at all on someone else's exit — is FALSE of the accepted Y-bis
    ///         contract, and fixing it means clamping the draw, which is the alternative Forest
    ///         Road considered and rejected on 2026-08-08. It is carried as OWNER-BLOCKED, not
    ///         asserted away.
    ///
    /// @dev    REACH, STATED HONESTLY AND NOT OVERCLAIMED. `pendingSeniorImpairment()` — the thing
    ///         that prices the vault — is fed by the DECLARED and PAST-DUE cohorts, not by the
    ///         handler's G3 `recogniseMark` action (which moves `totalBackingValue()` instead).
    ///         This handler has four actions and NONE of them declares a default, so the STATEFUL
    ///         campaign currently visits this region with the vault at par and the counter
    ///         necessarily zero. The bound is proved non-vacuously by
    ///         `test_Z_antiVacuity_theLayer3HolderIsInTheStateSpaceAndMoves`, which declares a
    ///         default deterministically and asserts the vault's NAV actually falls while the
    ///         bound holds. GIVING THE HANDLER ITS OWN DECLARE-DEFAULT ACTION IS OWED and is
    ///         carried in the SWEEP-1 open register; do not read this invariant as covering the
    ///         declared cohort statefully until that action exists.
    function invariant_Z_theVaultFallNeverExceedsTheJuniorCapitalDrawn() public view {
        assertEq(
            handler.gVaultFallExceededDraw(),
            0,
            "AN EXIT LOWERED THE SENIOR VAULT'S NAV BY MORE THAN THE JUNIOR CAPITAL IT DREW"
        );
    }

    /// @notice INVARIANT — ADR-0034's THIRD BINDING REQUIREMENT. The draw brings absorption
    ///         FORWARD in time; it does not enlarge it. No single draw may exceed the deficit
    ///         standing before it, which is what makes cumulative draws telescope.
    function invariant_Z_noDrawExceedsTheStandingDeficit() public view {
        assertEq(
            handler.gDrawExceededDeficit(),
            0,
            "A DRAW EXCEEDED THE STANDING DEFICIT -- absorption was ENLARGED, not advanced"
        );
        assertLe(
            reserves.exitPrepaidAbsorption(),
            _initialDeficitCeiling(),
            "THE CUMULATIVE PREPAYMENT EXCEEDED EVERY DEFICIT THE BOOK COULD CARRY"
        );
    }

    /// @notice INVARIANT — CLAUDE.md §1.3 ORDERING. Layer 2 (sGROVE) never pays while layer 1
    ///         (curator first-loss) still holds capital. Never skipping, never inverting.
    function invariant_Z_layer2NeverPaysBeforeLayer1IsExhausted() public view {
        assertEq(
            handler.gLayer2PaidBeforeLayer1WasEmpty(),
            0,
            "THE sGROVE BACKSTOP PAID WHILE CURATOR FIRST-LOSS CAPITAL WAS STILL STANDING"
        );
    }

    /// @notice INVARIANT — the solvency rule the contract enforces. No exit, drawn or undrawn,
    ///         widens `deficit = max(0, totalSupply - backingValue)`.
    function invariant_Z_noExitWidensTheDeficit() public view {
        assertEq(handler.gDeficitWorsened(), 0, "AN EXIT WIDENED THE BACKING DEFICIT");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  ANTI-VACUITY — deterministic, seed-independent
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The campaign's region is REACHED, and reached by the handler's own actions rather
    ///         than by a bespoke path that only this test can walk. Every witness the invariants
    ///         above depend on is asserted directly.
    function test_Z_antiVacuity_theDrawnDomainIsDeterministicallyReachable() public {
        // 1. A drawn exit at par, funded entirely by layer 1.
        handler.recogniseMark(20_000e18);
        handler.exit(60_000e18);
        assertGt(handler.gDrawnExits(), 0, "VACUOUS: no exit ever drew junior capital");
        assertGt(handler.gParExitsUnderDeficit(), 0, "VACUOUS: no exit was made whole under a deficit");

        // 2. Layer 1 exhausted -> a SUB-PAR exit with junior genuinely empty. This is the state
        //    clause 1 is about, and reaching it is what makes the invariant non-trivial.
        handler.recogniseMark(type(uint256).max);
        for (uint256 i = 0; i < 8; ++i) {
            handler.exit(100_000e18 + i);
        }
        assertEq(handler.curatorCapital(), 0, "VACUOUS: layer 1 was never exhausted");
        assertGt(handler.gSubParExits(), 0, "VACUOUS: no sub-par exit ever settled");
        assertGt(handler.gExitsWithJuniorExhausted(), 0, "VACUOUS: the clause-1 witness was never observed");

        // 3. Layer 2 actually pays once layer 1 is empty.
        handler.fundBackstop(30_000e18);
        handler.exit(50_000e18);
        assertGt(handler.gLayer2Draws(), 0, "VACUOUS: the sGROVE backstop leg was never exercised");

        // 4. SWEEP-1 MRC-F1: the LAYER-3 HOLDER was actually present for every exit measured.
        //    Without this witness `invariant_Z_theVaultFallNeverExceedsTheJuniorCapitalDrawn`
        //    would be satisfiable by a campaign in which no staker ever existed — which is exactly
        //    the state this file was in before the sweep. That the vault's NAV actually MOVES is
        //    driven separately and deterministically by
        //    `test_Z_antiVacuity_theLayer3HolderIsInTheStateSpaceAndMoves`.
        assertGt(handler.gExitsWithALiveStaker(), 0, "VACUOUS: no exit was ever measured with a live sUSDfr staker");

        // and the properties still hold across all of it
        assertEq(handler.gAbsorbedWhileJuniorRemained(), 0, "clause 1");
        assertEq(handler.gVaultFallExceededDraw(), 0, "requirement 3, vault side");
        assertEq(handler.gStayersLeftWorseOff(), 0, "clause 2");
        assertEq(handler.gLayer2PaidBeforeLayer1WasEmpty(), 0, "ordering");
        assertEq(handler.gDrawExceededDeficit(), 0, "requirement 3");
    }

    /// @notice THE TEETH. The SAME property, the SAME handler, the SAME action sequence — against
    ///         a draw source that draws NOTHING, which is precisely the protocol as it stood
    ///         before ADR-0034 Y-bis. Clause 1 must go non-zero.
    ///
    ///         The falsifier is BEHAVIOURAL, not a compile break: `NullExitDrawSource` implements
    ///         the interface, reads its operand and returns a value derived from it. Nothing here
    ///         is deleted, so nothing can pass for the wrong reason.
    function test_Z_theInvariantRedsAgainstADeliberatelyBrokenDraw() public {
        NullExitDrawSource nullSource = new NullExitDrawSource(address(reserves));
        vm.startPrank(admin);
        reserves.setLossAbsorber(address(nullSource));
        controller.setLossSource(address(nullSource), true);
        vm.stopPrank();

        handler.recogniseMark(20_000e18);
        handler.exit(60_000e18);

        assertEq(handler.gDrawnExits(), 0, "the broken source must draw nothing -- that is the point");
        assertGt(handler.gSubParExits(), 0, "the broken source must produce a sub-par exit");
        assertGt(
            handler.curatorCapital(),
            0,
            "the falsification requires junior capital to be STANDING while the senior is haircut"
        );
        assertGt(
            handler.gAbsorbedWhileJuniorRemained(),
            0,
            "THE Z INVARIANT HAS NO TEETH: it passed against a draw that never draws"
        );
    }

    /// @dev The largest deficit this book can carry: every dollar of deployed principal marked to
    ///      zero. Cumulative prepayment can never exceed it, whatever the mark sequence.
    function _initialDeficitCeiling() internal pure returns (uint256) {
        return PRINCIPAL;
    }
}
