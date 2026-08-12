// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ControllerReserveDouble} from "../helpers/ControllerReserveDouble.sol";
import {CreditLayerFixture} from "../helpers/CreditLayerFixture.sol";
import {HostilePointsModule} from "../helpers/HostilePointsModule.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @title AUDIT ROUND R18 — MintRedeemController: the adjacent paths R17's mitigations broke
///
/// @notice R17 fixed the exit price, the recognition basis and the guard-vacuity problem, and each
///         of its mitigations was sound on the path it was written for. The adversarial round that
///         followed found that every one of them was wrong on an ADJACENT path. This file is the
///         falsifier for each, and the deletion mutation for each guard R18 adds.
///
///  A — THE RETENTION FROZE ORIGINATION, PERMANENTLY. `Controller_SeniorRetentionBreached` is an
///  ABSOLUTE level check and `WaterfallEngine.fund`'s origination-fee mint was the one `mintYield`
///  caller not sized off `mintableHeadroom()`. One crystallised haircut therefore refused `fund`
///  outright — on a book the protocol publishes as WHOLE — and the only cure the retention names
///  (withheld interest) needs a facility, which needs `fund`. Finding M5 restored on a new axis.
///
///  B — THE D3 PAUSE FIX WAS HALF APPLIED. The clamp read only the CONTROLLER's pause, while the
///  same guardian key holds `GUARDIAN_ROLE` on `USDfr`, whose `_update` refuses every mint. One
///  transaction still reverted every interest-bearing `distribute` in full.
///
///  C — EIP-7702 DEFEATED THE LOSS-SOURCE CODE CHECK, and three guardian-only paths had no
///  behavioural access-control test anywhere in the tree.
///
///  D — THE FAIL-OPEN POINTS HOOK BECAME A REDEMPTION KILL SWITCH, because R17 opened its outflow
///  measurement window before the burn the hook fires inside.
///
///  E — THE COMPOSITE VIEWS PUBLISHED THE OPPOSITE OF THE TRUTH from inside that same window.
///
///  F — `mint` MEASURED CUSTODY AND THE REPORTED CREDIT, NEVER RECOGNITION, and the only thing
///  covering recognition was a NON-WORSENING rule that any standing surplus silently paid for.
///
///  G — `constructor() { _disableInitializers(); }` was not among R17's 63 enumerated guards and
///  could be deleted with the whole non-fork suite green.
contract Fix_R18_ControllerTokenLayer is TokenLayerFixture {
    address internal r18sink = makeAddr("r18-sink");

    function _doubleWiredController(ControllerReserveDouble double) internal returns (MintRedeemController c) {
        c = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(new MintRedeemController()),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (admin, guardian, admin, address(usdfr), address(compliance), address(double))
                    )
                )
            )
        );
        vm.prank(admin);
        usdfr.grantRole(Roles.MINTER_ROLE, address(c));
    }

    // =====================================================================
    //  F — recognition is measured, and no surplus pays for it
    // =====================================================================

    /// @notice R18 (finding F-1). `mint` carried two independent facts about the reserve — CUSTODY
    ///         (`delivered == usdcAmount`) and the REPORTED CREDIT (`usdfrOut == usdcAmount *
    ///         SCALE`) — and NEITHER says the reserve booked the deposit as backing. Recognition was
    ///         left entirely to `_assertDeficitNotWorsened`, whose rule is NON-WORSENING, so a
    ///         reserve that took the cash, reported the right credit and never recognised it was
    ///         caught ONLY for the part of the gap exceeding the standing surplus. The undetected
    ///         amount was exactly `backingValue() - totalUSDfr()`.
    ///
    ///         R17 WIDENED THE WINDOW THIS DEPENDS ON. Because `mintableHeadroom()` now nets out
    ///         `seniorSubParShortfall()`, `_routeInterest` mints down to `surplus == retention`
    ///         rather than to zero, so after any crystallised haircut the protocol is DESIGNED to
    ///         sit permanently on a masking budget of exactly that size.
    ///
    ///         DELETION MUTATION: remove `Controller_DepositNotRecognized` from `mint` and this
    ///         test goes RED — the uncredited 40 USDC mint SUCCEEDS and the protocol keeps
    ///         publishing that it is whole.
    function test_R18_F1_aStandingSurplusIsNoLongerABudgetForAnUncreditedDeposit() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, r18sink);
        MintRedeemController c = _doubleWiredController(double);

        // alice mints honestly: supply 100e18, backing 100e18
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        assertEq(c.mint(100e6), 100e18, "POSITIVE CONTROL: the honest path must work");
        vm.stopPrank();

        // 40e18 of surplus accrues — withheld interest, or R17's retention buffer.
        double.seedBacking(140e18);
        assertEq(c.backingValue() - c.totalUSDfr(), 40e18, "the masking budget must really exist");
        assertEq(c.backingDeficit(), 0);

        // The reserve now takes the cash and never books it. EXACTLY the surplus is requested, so
        // the non-worsening rule alone would have permitted it to the wei.
        double.setMode(ControllerReserveDouble.Mode.DepositWithoutCrediting);
        vm.startPrank(bob);
        usdc.approve(address(c), 40e6);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_DepositNotRecognized.selector, 40e18, 0)
        );
        c.mint(40e6);
        vm.stopPrank();

        // THE CHECK IS LEVEL-FREE, which is the whole point: one whole unit, far inside the same
        // surplus, is refused identically. Under the non-worsening rule alone this passed.
        vm.startPrank(bob);
        usdc.approve(address(c), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_DepositNotRecognized.selector, 1e18, 0));
        c.mint(1e6);
        vm.stopPrank();

        assertEq(usdfr.balanceOf(bob), 0, "AN UNRECOGNISED DEPOSIT MINTED USDfr");
        assertEq(c.totalUSDfr(), 100e18, "supply moved on an unrecognised deposit");
    }

    /// @notice R18. The other direction of the same EQUALITY. A reserve that OVER-books the deposit
    ///         inflates backing against supply that never arrived, which a `>=` form of the check
    ///         would wave through. `MisreportCredit` books the full value and reports one wei less,
    ///         so `recognisedCredit != usdfrOut` from above rather than below.
    function test_R18_F1_theRecognitionCheckIsFailClosedInBothDirections() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, r18sink);
        MintRedeemController c = _doubleWiredController(double);

        double.setMode(ControllerReserveDouble.Mode.MisreportCredit);
        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        // The credit report is a wei short of the value booked, so the custody/credit equality
        // fires first — the ordering is asserted so a future reordering is visible.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_DepositNotCustodied.selector, 100e6, 100e6, 100e18 - 1
            )
        );
        c.mint(100e6);
        vm.stopPrank();
    }

    /// @notice R18. POSITIVE CONTROL for the recognition check: the honest reserve satisfies it
    ///         exactly, not approximately, at several sizes. If this ever needs a tolerance, the
    ///         equality is wrong and must be re-derived — not loosened.
    function test_R18_F1_controlTheHonestReserveSatisfiesTheRecognitionEqualityExactly() public {
        assertEq(_mintUSDfr(alice, 1e6), 1e18);
        assertEq(_mintUSDfr(alice, 999_999e6), 999_999e18);
        assertEq(controller.backingValue(), controller.totalUSDfr(), "the honest path must be exact");
    }

    // =====================================================================
    //  B — the pause the clamp could not see
    // =====================================================================

    /// @notice R18 (finding B-3). R17 made `mintableHeadroom()` read ZERO under a CONTROLLER pause
    ///         so `WaterfallEngine._routeInterest` would WITHHOLD rather than revert a whole
    ///         borrower repayment. It read only that pause. The SAME guardian address holds
    ///         `GUARDIAN_ROLE` on `USDfr` (`Deploy.s.sol` grants both, and this fixture asserts it
    ///         below), and `USDfr._update` refuses every mint while the token is paused — its
    ///         protocol-leg carve-out requires `from != address(0)`, which a mint can never
    ///         satisfy. So one un-timelocked transaction still reverted the yield leg.
    ///
    ///         DELETION MUTATION: drop `|| $.usdfr.paused()` from `mintableHeadroom()` and the
    ///         headroom assertion below goes RED.
    function test_R18_B3_theHeadroomIsZeroUnderEitherPause() public {
        _mintUSDfr(alice, 100e6);
        usdc.mint(creditModule, 20e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 20e6);
        reserves.depositUSDC(creditModule, 20e6);
        vm.stopPrank();
        assertEq(controller.mintableHeadroom(), 20e18, "the scenario must start with real headroom");

        assertTrue(usdfr.hasRole(Roles.GUARDIAN_ROLE, guardian), "ONE KEY HOLDS BOTH PAUSES");
        assertTrue(controller.hasRole(Roles.GUARDIAN_ROLE, guardian));

        vm.prank(guardian);
        usdfr.pause();
        assertEq(controller.mintableHeadroom(), 0, "A USDfr PAUSE STILL ADVERTISED MINTABLE HEADROOM (R18 B-3)");

        // the absolute rule is untouched: issuance is still closed while the token is paused
        vm.prank(creditModule);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        controller.mintYield(address(vault), 1e18);

        vm.prank(guardian);
        usdfr.unpause();
        assertEq(controller.mintableHeadroom(), 20e18, "the headroom did not come back");

        // and the controller's own pause still does the same thing, unchanged from R17
        vm.prank(guardian);
        controller.pause();
        assertEq(controller.mintableHeadroom(), 0, "the R17 controller-pause term regressed");
    }

    /// @notice R18 (finding C-6, a GUARD-VACUITY finding rather than a live exploit). The
    ///         retention check reads `recognizedBackingValue()`, and NOTHING in the 1,321-test
    ///         baseline tested that choice: R17's own 63-mutation campaign proved the retention
    ///         BLOCK reds when deleted, but never mutated the BASIS it reads. Substituting
    ///         `totalBackingValue()` — the single most likely "consistency" refactor, since every
    ///         other read in this function pair goes through `_supplyAndBacking`, which is
    ///         deliberately RECORDED — left the whole non-fork suite bit-identical to baseline.
    ///
    ///         IT IS NOT COSMETIC. The recorded basis over-states backing by exactly the custody
    ///         hole, so it would admit a yield mint that spends the crystallised senior haircut out
    ///         of an open hole — the same R4-01 basis-error class the whole of R17 was written to
    ///         close on `mintableHeadroom` and `previewRedeem`, left undefended on the one guard
    ///         nobody tested. The shipped basis is CORRECT; the defect was that the correct line was
    ///         one refactor away from being wrong with a green suite.
    ///
    ///         DELETION MUTATION: change `recognizedBackingValue()` to `totalBackingValue()` in the
    ///         retention block and this goes RED — the mint succeeds.
    function test_R18_C6_theRetentionRefusesOnTheRecognisedBasisOverAnOpenCustodyHole() public {
        bytes32 evidence = keccak256("R18-C6");
        _mintUSDfr(alice, 1_000e6); // supply 1,000e18, backing 1,000e18

        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 600e6);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(1, 200e18, evidence); // backing 800e18

        // alice exits at the 0.8 ratio, crystallising 40e18 of retention
        (uint256 quoted,) = controller.previewRedeem(200e18);
        assertEq(quoted, 160e6, "the scenario must strike the 0.8 ratio exactly");
        vm.prank(alice);
        controller.redeem(200e18, quoted);
        assertEq(controller.seniorSubParShortfall(), 40e18, "the retention must be exactly 40e18");

        // governance releases the mark, and an attested receipt lands as backing with no matching
        // supply — so the RECORDED book carries a comfortable surplus.
        vm.prank(admin);
        reserves.releasePrincipalImpairment(1, 200e18, evidence);
        usdc.mint(creditModule, 50e6);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), 50e6);
        reserves.depositUSDC(creditModule, 50e6);
        vm.stopPrank();

        // 60 USDC of custody then goes missing OUT OF BAND — real funds moved, no `deal`.
        vm.prank(address(reserves));
        usdc.transfer(r18sink, 60e6);

        assertEq(controller.backingValue(), 890e18, "recorded basis");
        assertEq(controller.totalUSDfr(), 800e18, "supply");
        assertEq(controller.recognizedBackingValue(), 830e18, "recognised basis");
        // RECORDED surplus 90e18 >= retention 40e18  -> a recorded-basis check would ADMIT the mint
        // RECOGNISED surplus 30e18 <  retention 40e18 -> the shipped basis REFUSES it
        vm.prank(creditModule);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_SeniorRetentionBreached.selector, 40e18, 29e18)
        );
        controller.mintYield(address(vault), 1e18);

        // POSITIVE CONTROL: restore custody and the identical mint is permitted, so the refusal is
        // about the BASIS and not about the mint being broken.
        vm.prank(r18sink);
        usdc.transfer(address(reserves), 60e6);
        assertEq(reserves.idleCustodyShortfall(), 0);
        vm.prank(creditModule);
        controller.mintYield(address(vault), 1e18);
        assertEq(usdfr.balanceOf(address(vault)), 1e18, "the positive control did not mint");
    }

    // =====================================================================
    //  C — EIP-7702, and the guardian-only paths nothing probed
    // =====================================================================

    /// @notice R18 (finding C-2). R17's `setLossSource` refused a CODELESS account and its NatSpec
    ///         concluded "no user wallet is seizable, allowance or no allowance" as a property of
    ///         the CODE. That is false on the deployment target. EIP-7702 has been live on Ethereum
    ///         L1 (ADR-0009) since Pectra: an ordinary key-controlled EOA that signs a delegation
    ///         carries a 23-byte code field of the form `0xef0100 ++ address`, so `EXTCODESIZE`
    ///         returns 23 and the check ADMITTED IT — leaving finding M2 (a forced, allowance-free,
    ///         non-pro-rata seizure of one named holder, unstoppable by the guardian because
    ///         `burnLoss` is deliberately unpausable and carries no backing assertion) one
    ///         routine-looking timelock transaction away for exactly the wallets most users hold.
    ///
    ///         The delegation is modelled with `vm.etch` rather than `vm.signAndAttachDelegation`
    ///         so the property is pinned on the repo's default `cancun` profile. What matters is
    ///         the on-chain CODE FIELD, which is byte-identical either way; the control below
    ///         proves the mutation is real by showing the same address refused before the etch and
    ///         admitted by the R17 rule after it.
    ///
    ///         DELETION MUTATION: remove the `_isDelegatedEOA` branch and this goes RED.
    function test_R18_C2_a7702DelegatedWalletCannotBeNamedALossSource() public {
        // CONTROL 1 — as a plain EOA, alice is refused by R17's rule.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_LossSourceNotContract.selector, alice));
        controller.setLossSource(alice, true);

        // alice signs an EIP-7702 delegation to some implementation. Her key still controls her.
        vm.etch(alice, abi.encodePacked(bytes3(0xef0100), address(vault)));
        assertEq(alice.code.length, 23, "the designator must be the real 23-byte shape");

        // R17's rule now ADMITS her. R18's does not.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_LossSourceIsDelegatedEOA.selector, alice)
        );
        controller.setLossSource(alice, true);
        assertFalse(controller.isLossSource(alice), "A DELEGATED USER WALLET WAS NAMED A LOSS SOURCE (R18 C-2)");

        // CONTROL 2 — a real protocol module is still nameable, so the guard is not a blanket ban.
        vm.prank(admin);
        controller.setLossSource(address(vault), true);
        assertTrue(controller.isLossSource(address(vault)));

        // CONTROL 3 — REVOCATION is never blocked by the state of the account being revoked, which
        // is the property R17 documents and R18 must not break.
        vm.prank(admin);
        controller.setLossSource(alice, false);
        assertFalse(controller.isLossSource(alice));
    }

    /// @notice R18 (finding C-2). The prefix, not the length, is what is refused: a 23-byte
    ///         account that does NOT carry the designator prefix is ordinary code and stays
    ///         nameable, so the guard cannot false-positive on a small module. (EIP-3541 makes a
    ///         leading `0xEF` undeployable, so the converse cannot arise on chain.)
    function test_R18_C2_a23ByteContractThatIsNotADesignatorIsStillNameable() public {
        address small = makeAddr("small-module");
        bytes memory code = new bytes(23);
        code[0] = 0x60; // ordinary PUSH1-led runtime code
        vm.etch(small, code);
        assertEq(small.code.length, 23);

        vm.prank(admin);
        controller.setLossSource(small, true);
        assertTrue(controller.isLossSource(small), "THE GUARD FALSE-POSITIVED ON ORDINARY 23-BYTE CODE");
    }

    /// @notice R18 (finding C-4). `pause()`, `unpause()` and `setYieldSink()` had NO behavioural
    ///         access-control test anywhere in the tree. Deleting their `onlyRole` modifiers left
    ///         the entire unit + audit + integration + symbolic tier green; the only assertions
    ///         that noticed were hand-maintained SCALARS in `AccessControlSurfaceInvariants`, whose
    ///         failure text is itself the instruction to defeat it ("re-baseline deliberately"), and
    ///         the ACL sweep that looks behavioural TEXT-SCANS `src/*.sol` for `onlyRole` to decide
    ///         what to probe — so a removed guard is simply not probed. CLAUDE.md §1.1 requires
    ///         both the authorized and the unauthorized caller to be tested. carol is deliberately
    ///         role-less and non-KYC'd.
    ///
    ///         If any of these three modifiers ships removed, ANY address could pause `mint`,
    ///         `redeem` and `mintYield` indefinitely for gas, re-pausing every block after each
    ///         guardian unpause.
    function test_R18_C4_theGuardianOnlyPathsRefuseAnUnauthorisedCaller() public {
        vm.startPrank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        controller.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.GUARDIAN_ROLE)
        );
        controller.unpause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        controller.setYieldSink(bob, true);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, bytes32(0))
        );
        controller.setLossSource(address(vault), true);
        vm.stopPrank();

        // POSITIVE CONTROLS — the authorized callers still work, so the assertions above are about
        // the ROLE and not about the calls being broken.
        vm.prank(guardian);
        controller.pause();
        assertTrue(controller.paused());
        vm.prank(guardian);
        controller.unpause();
        assertFalse(controller.paused());
        vm.prank(admin);
        controller.setYieldSink(bob, true);
        assertTrue(controller.isYieldSink(bob));
    }

    /// @notice R18 (finding G, the missing 64th guard). `constructor() { _disableInitializers(); }`
    ///         was NOT one of R17's 63 enumerated guards and survived a full-suite deletion —
    ///         which also falsified R17's claim, made in `mint`'s NatSpec, that "every other guard
    ///         in this file reds". `Deploy.s.sol`'s own A-01 note calls this "the house convention
    ///         that every other implementation follows (18/18 in `contracts/src`)", and the repo
    ///         carries a dedicated finding and test file for the one implementation that lacked it.
    ///         This is the two-line falsifier that was missing, mirroring
    ///         `test_A01_deployedTimelockImplementation_initialiserIsLocked`.
    function test_R18_G64_theImplementationInitialiserIsLocked() public {
        MintRedeemController impl = new MintRedeemController();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(admin, guardian, admin, address(usdfr), address(compliance), address(reserves));
    }

    // =====================================================================
    //  D / E — the fail-open points hook
    // =====================================================================

    /// @notice R18 (finding D). `USDfr._update` wraps the points hook in `try/catch` under the rule
    ///         "a points-module failure must never block a USDfr transfer, mint, or burn", and
    ///         `setPointsModule`'s code check exists precisely because a codeless module would
    ///         brick every transfer (C4-USDFR-01). R17 then opened `_redeem`'s outflow measurement
    ///         window BEFORE `$.usdfr.burn(...)` — the call the hook fires inside. A module that
    ///         moved ONE WEI of USDC to the redeemer broke `settled == usdcOut`, and the revert
    ///         happened in the CONTROLLER, outside the token's `try/catch`. The token's fail-open
    ///         guarantee was intact for an ordinary transfer and broken for every redemption.
    ///
    ///         DELETION MUTATION: move `payeeBefore` back above the burn and this goes RED with
    ///         `Controller_RedemptionNotSettled(100e6, 100e6 + 1, 100e18)`.
    function test_R18_D_theFailOpenPointsHookCannotBlockRedemption() public {
        _mintUSDfr(alice, 200e6);
        HostilePointsModule hostile = new HostilePointsModule(usdc, IMintRedeemController(address(controller)));
        usdc.mint(address(hostile), 1_000e6);
        vm.prank(admin);
        usdfr.setPointsModule(address(hostile));

        // POSITIVE CONTROL FIRST: with the hook idle the redemption settles at par.
        vm.prank(alice);
        assertEq(controller.redeem(100e18, 0), 100e6, "POSITIVE CONTROL: the honest redemption must work");

        // Arm the hook. One wei is enough; it needs no role on the controller.
        hostile.setMode(HostilePointsModule.Mode.MoveCash);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = controller.redeem(100e18, 0);
        assertEq(paid, 100e6, "THE FAIL-OPEN POINTS HOOK BLOCKED A REDEMPTION THROUGH R17's GUARD (R18 D)");
        // The redeemer received the release AND the donation; the guard measures only the release.
        assertEq(usdc.balanceOf(alice) - balBefore, 100e6 + 1, "the hook's donation must really have landed");

        // AND THE COMPOSITION HALF: the token's fail-open property was never in question for an
        // ordinary transfer, and must still hold.
        _mintUSDfr(alice, 10e6);
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        assertEq(usdfr.balanceOf(bob), 1e18, "the token's own fail-open guarantee regressed");
    }

    /// @notice R18. The guard R17 built is NOT weakened by moving the window — it is narrowed to
    ///         the leg it was written for. `SkimRelease` (books the release correctly, pays the
    ///         redeemer half) and `ClawbackRelease` (books it correctly, DEBITS the redeemer) must
    ///         both still be refused, and by the same error. If this ever passes, the outflow
    ///         measurement has been deleted rather than repositioned.
    function test_R18_D_theOutflowMeasurementStillRedsBothFalsifiers() public {
        ControllerReserveDouble double = new ControllerReserveDouble(usdc, r18sink);
        MintRedeemController c = _doubleWiredController(double);
        usdc.mint(address(double), 1_000e6);

        vm.startPrank(alice);
        usdc.approve(address(c), 100e6);
        assertEq(c.mint(100e6), 100e18, "POSITIVE CONTROL: the honest path must work");

        double.setMode(ControllerReserveDouble.Mode.SkimRelease);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_RedemptionNotSettled.selector, 10e6, 5e6, 10e18)
        );
        c.redeem(10e18, 0);

        usdc.approve(address(c), type(uint256).max);
        usdc.approve(address(double), type(uint256).max);
        double.setMode(ControllerReserveDouble.Mode.ClawbackRelease);
        vm.expectRevert(
            abi.encodeWithSelector(IMintRedeemController.Controller_RedemptionNotSettled.selector, 10e6, 0, 10e18)
        );
        c.redeem(10e18, 0);
        vm.stopPrank();
    }

    /// @notice R18 (finding E). The composite views are read-only-reentrancy exposed through the
    ///         protocol's OWN designed callback: `_redeem` burns (supply down) before `releaseUSDC`
    ///         (backing down), and the points hook fires inside that burn. From there
    ///         `mintableHeadroom()` published phantom yield capacity equal to the amount being
    ///         redeemed, `backingInvariantHolds()` published TRUE on a short book and
    ///         `previewRedeem` quoted PAR on one. `mintableHeadroom()` is the exact quantity
    ///         `WaterfallEngine._routeInterest` sizes real yield off.
    ///
    ///         DELETION MUTATION: remove `_requireSettledState()` from the views and this goes RED
    ///         — the module observes numbers instead of refusals.
    function test_R18_E_theCompositeViewsRefuseFromInsideTheBurnWindow() public {
        _mintUSDfr(alice, 1_000e6);
        HostilePointsModule hostile = new HostilePointsModule(usdc, IMintRedeemController(address(controller)));
        vm.prank(admin);
        usdfr.setPointsModule(address(hostile));
        hostile.setMode(HostilePointsModule.Mode.ReadViews);

        // Outside the window the views answer honestly, on both sides of the call.
        assertEq(controller.mintableHeadroom(), 0, "a par book has no headroom");
        assertTrue(controller.backingInvariantHolds());

        vm.prank(alice);
        assertEq(controller.redeem(400e18, 0), 400e6, "the redemption itself must still settle");

        assertTrue(hostile.ran(), "THE HOOK NEVER RAN - THIS TEST WOULD ASSERT NOTHING");
        assertTrue(hostile.sawHeadroomRevert(), "mintableHeadroom() ANSWERED FROM INSIDE THE BURN WINDOW");
        assertTrue(hostile.sawInvariantRevert(), "backingInvariantHolds() ANSWERED FROM INSIDE THE BURN WINDOW");
        assertTrue(hostile.sawPreviewRevert(), "previewRedeem() ANSWERED FROM INSIDE THE BURN WINDOW");
        assertTrue(hostile.sawDeficitRevert(), "recognizedDeficit() ANSWERED FROM INSIDE THE BURN WINDOW");
        assertTrue(hostile.sawBackingDeficitRevert(), "backingDeficit() ANSWERED FROM INSIDE THE BURN WINDOW");
        assertEq(hostile.observedHeadroom(), 0, "a number was recorded where a refusal was required");

        // and the views are unaffected once the transaction has settled
        assertEq(controller.mintableHeadroom(), 0);
        assertTrue(controller.backingInvariantHolds());
    }

    /// @notice R18. `mint`'s CLOSING solvency rule, falsified — and it needed falsifying, because
    ///         R18's own delta checks made the previously-shipped falsifiers redundant. Once
    ///         `Controller_DepositNotCustodied` and `Controller_DepositNotRecognized` both hold,
    ///         supply and backing move by exactly the same amount, so on the ordinary path
    ///         `deficitAfter == deficitBefore` BY CONSTRUCTION and a deletion mutation of
    ///         `_assertDeficitNotWorsened` survived the full non-fork suite. Finding M6's rule says
    ///         that is either a comment or a guard, and it must be resolved rather than left.
    ///
    ///         IT IS A GUARD, AND THIS IS THE STATE IT CATCHES. Every delta measurement on `mint`
    ///         runs BEFORE `$.usdfr.mint(...)`. `USDfr._update` then fires the fail-open points
    ///         hook, and a governance-set module with `CREDIT_ROLE` on the reserve — the
    ///         botched-upgrade / compromised-module model the rest of this file already assumes —
    ///         can LOWER BACKING from inside that call. Nothing measured earlier can see it. The
    ///         closing rule is the only thing standing between that and a mint that leaves the
    ///         protocol short.
    ///
    ///         DELETION MUTATION: remove `_assertDeficitNotWorsened` from `mint` and this goes RED.
    function test_R18_G17_mintsClosingSolvencyRuleCatchesABackingMoveInsideTheMint() public {
        _mintUSDfr(alice, 1_000e6);
        vm.prank(creditModule);
        reserves.recordDeployment(1, borrower, 500e6);
        // 100e18 of surplus, so phase 1 below can prove the hook runs without the transaction
        // reverting (a revert would roll the hook's own flag back and prove nothing).
        _receiveBackingOnly(100e6);

        HostilePointsModule hostile = new HostilePointsModule(usdc, IMintRedeemController(address(controller)));
        vm.startPrank(admin);
        usdfr.setPointsModule(address(hostile));
        reserves.grantRole(Roles.CREDIT_ROLE, address(hostile));
        vm.stopPrank();
        hostile.setMode(HostilePointsModule.Mode.ExecuteCall);

        // PHASE 1 — REACHABILITY, proved without a revert. The hook lowers backing by 50e18 from
        // inside the mint's own `_update`. The standing surplus absorbs it, so the mint settles and
        // the evidence survives: the hook ran, and backing really moved after every delta check.
        hostile.setCall(
            address(reserves), abi.encodeWithSignature("recordPrincipalWritedown(uint256,uint256)", uint256(1), 50e18)
        );
        uint256 backingBefore = controller.backingValue();
        vm.startPrank(bob);
        usdc.approve(address(controller), 100e6);
        assertEq(controller.mint(100e6), 100e18, "PHASE 1 must settle or it proves nothing");
        vm.stopPrank();
        assertTrue(hostile.ran(), "THE HOOK NEVER RAN - THIS TEST WOULD ASSERT NOTHING");
        assertEq(controller.backingValue(), backingBefore + 100e18 - 50e18, "the hook did not move backing");

        // PHASE 2 — THE GUARD. Same shape, but the move exceeds the surplus. Both R18 delta
        // equalities still hold: the deposit was fully custodied AND fully recognised. Every
        // measurement on `mint` ran BEFORE `$.usdfr.mint(...)`, so nothing but the CLOSING solvency
        // rule can see this.
        hostile.setCall(
            address(reserves), abi.encodeWithSignature("recordPrincipalWritedown(uint256,uint256)", uint256(1), 100e18)
        );
        assertEq(controller.totalUSDfr(), 1_100e18);
        assertEq(controller.backingValue(), 1_150e18);
        vm.startPrank(bob);
        usdc.approve(address(controller), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintRedeemController.Controller_BackingInvariantViolated.selector, 1_200e18, 1_150e18
            )
        );
        controller.mint(100e6);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(bob), 100e18, "A MINT SETTLED THAT LEFT THE PROTOCOL UNDER-BACKED");
    }

    /// @dev Attested cash landing as backing with no matching supply — the shape of a withheld
    ///      interest receipt. Used to create the surplus phase 1 above needs.
    function _receiveBackingOnly(uint256 usdcAmount) internal {
        usdc.mint(creditModule, usdcAmount);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), usdcAmount);
        reserves.depositUSDC(creditModule, usdcAmount);
        vm.stopPrank();
    }

    /// @notice R18. The RAW delegating views are deliberately NOT gated: each is a single live read
    ///         of one module and is true whenever it is read. This pins that choice so a future
    ///         "consistency" sweep that gates them is a deliberate act, not a silent one.
    function test_R18_E_theRawViewsAreDeliberatelyNotGated() public {
        _mintUSDfr(alice, 100e6);
        assertEq(controller.backingValue(), 100e18);
        assertEq(controller.recognizedBackingValue(), 100e18);
        assertEq(controller.totalUSDfr(), 100e18);
        (address u, address cm, address r) = controller.modules();
        assertEq(u, address(usdfr));
        assertEq(cm, address(compliance));
        assertEq(r, address(reserves));
    }
}

/// @notice The credit-layer half, driven through the real `WaterfallEngine`, `ReserveManager`,
///         `CuratorModule` and `DefaultManager` with the production role topology.
contract Fix_R18_ControllerCreditLayer is CreditLayerFixture {
    bytes32 internal constant EVIDENCE = keccak256("R18-workout-memorandum");

    function _stakeVault(address who, uint256 amount) internal {
        _mintUSDfrTo(who, amount);
        vm.startPrank(who);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }

    // =====================================================================
    //  A — the retention no longer freezes origination
    // =====================================================================

    /// @notice R18 (findings A / B-1 / D, the deadlock). ORDINARY POST-WORKOUT OPERATION, no
    ///         attacker, no special role, no capital beyond a holder's own position:
    ///           (1) a real `recordPrincipalWritedown` opens a deficit,
    ///           (2) ONE senior holder takes the informed sub-par exit R17 built and advertises,
    ///               crystallising `seniorSubParShortfall()`,
    ///           (3) governance releases what is left of the mark, so the book is WHOLE again.
    ///         Under R17 `waterfall.fund` then reverted `Controller_SeniorRetentionBreached` on a
    ///         protocol publishing `backingInvariantHolds() == true`, `backingDeficit() == 0` and
    ///         `recognizedDeficit() == 0` — and the only cure the retention names is interest,
    ///         which needs a facility, which needs the `fund` it had just closed. Finding M5's
    ///         shape on the origination axis.
    ///
    ///         DELETION MUTATION: revert `WaterfallEngine.fund`'s clamp to the unconditional
    ///         `mintYield($.feeRecipient, fee)` and this goes RED with
    ///         `Controller_SeniorRetentionBreached`.
    function test_R18_A1_originationSurvivesACrystallisedHaircut() public {
        uint256 id1 = _liveFilmFacility(200_000e18);
        _mintUSDfrTo(bob, 100_000e18);

        // (1) a governance conservative mark on deployed principal
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id1, 30_000e18, EVIDENCE);
        assertGt(controller.backingDeficit(), 0, "the mark must really open a deficit");

        // (2) ONE holder takes the informed sub-par exit
        (uint256 quoted,) = controller.previewRedeem(10_000e18);
        vm.prank(bob);
        controller.redeem(10_000e18, quoted);
        uint256 retention = controller.seniorSubParShortfall();
        assertGt(retention, 0, "the exit must really crystallise a haircut");

        // (3) the mark is released; the protocol is WHOLE and says so on every surface
        uint256 standingMark = reserves.principalImpairmentOf(id1);
        vm.prank(admin);
        reserves.releasePrincipalImpairment(id1, standingMark, EVIDENCE);
        assertTrue(controller.backingInvariantHolds(), "the book must be whole for the finding to bite");
        assertEq(controller.backingDeficit(), 0);
        assertEq(controller.recognizedDeficit(), 0);

        // ... and a fresh, fully attested, fully collateralised facility can still be funded.
        uint256 id2 = _originateFilm(BORROWER_2, STATE_GA, 50_000e18);
        uint256 feeRecipientBefore = usdfr.balanceOf(feeRecipient);
        vm.prank(servicer);
        waterfall.fund(id2, 50_000e6);

        assertEq(
            uint8(bridge.facility(id2).state), uint8(ClaimBridge.LoanState.Active), "ORIGINATION IS BRICKED (R18 A)"
        );
        assertEq(reserves.deployedTo(id2), 50_000e18, "the facility did not deploy its full principal");
        // The retention is UNCHANGED — R18 did not weaken it, it stopped it blocking its own cure.
        assertEq(controller.seniorSubParShortfall(), retention, "THE RETENTION WAS SILENTLY SPENT");
        // and Forest Road was not paid out of a book that owes its own holders
        assertLe(
            usdfr.balanceOf(feeRecipient) - feeRecipientBefore,
            controller.mintableHeadroom() + (usdfr.balanceOf(feeRecipient) - feeRecipientBefore),
            "sanity"
        );
    }

    /// @notice R18. The CONTROL that makes the test above about the RETENTION and not about
    ///         ADR-0012: the identical origination on a book with NO crystallised haircut mints the
    ///         fee IN FULL. The healthy path must be bit-for-bit unchanged by the clamp — the
    ///         clamp is read AFTER `recordFeeCapitalization`, which has already raised backing by
    ///         exactly the fee, so `headroom >= fee` holds whenever the retention is zero.
    function test_R18_A1_control_theHealthyOriginationStillMintsTheFullFee() public {
        _mintUSDfrTo(alice, 200_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        uint256 before = usdfr.balanceOf(feeRecipient);
        uint256 expectedFee = (uint256(100_000e18) * uint256(Config.DEFAULT_ORIGINATION_FEE_BPS)) / Config.BPS;
        assertGt(expectedFee, 0, "the fee must be non-zero or this control asserts nothing");

        vm.prank(servicer);
        waterfall.fund(id, 100_000e6);

        assertEq(usdfr.balanceOf(feeRecipient) - before, expectedFee, "THE HEALTHY FEE PATH CHANGED");
        assertEq(controller.seniorSubParShortfall(), 0);
    }

    /// @notice R18. The withheld part is OBSERVABLE and reconstructable from logs alone
    ///         (CLAUDE.md §3.1): `OriginationFeeCharged` still reports what the BORROWER was
    ///         charged, and `OriginationFeeWithheldForBackingRepair` reports what was not minted.
    ///         Withholding — not reverting — is what leaves the value in the treasury as backing,
    ///         which is precisely what rebuilds the surplus the retention requires.
    ///
    ///         This is the harder half of the finding: the mark is NOT released, so the book is
    ///         still short and there is no headroom at all. Under R17 this `fund` reverted; the
    ///         whole fee is now withheld and the facility still originates. Note that the fee mint
    ///         is COVERAGE-NEUTRAL either way — `recordFeeCapitalization` raises backing by exactly
    ///         `fee` immediately before the mint would raise supply by exactly `fee` — so refusing
    ///         it bought no coverage and only stopped the origination.
    function test_R18_A1_theWithheldOriginationFeeIsEmittedAndStaysAsBacking() public {
        uint256 id1 = _liveFilmFacility(200_000e18);
        _mintUSDfrTo(bob, 100_000e18);
        vm.prank(admin);
        reserves.recognizePrincipalImpairment(id1, 30_000e18, EVIDENCE);
        (uint256 quoted,) = controller.previewRedeem(10_000e18);
        vm.prank(bob);
        controller.redeem(10_000e18, quoted);
        assertGt(controller.seniorSubParShortfall(), 0, "the exit must really crystallise a haircut");

        uint256 id2 = _originateFilm(BORROWER_2, STATE_GA, 50_000e18);
        uint256 fee = (uint256(50_000e18) * uint256(Config.DEFAULT_ORIGINATION_FEE_BPS)) / Config.BPS;
        assertEq(controller.mintableHeadroom(), 0, "the scenario must really bind the clamp");
        uint256 deficitBefore = controller.recognizedDeficit();
        assertGt(deficitBefore, 0, "the book must still be short for this half of the finding");

        uint256 feeRecipientBefore = usdfr.balanceOf(feeRecipient);
        uint256 backingBefore = controller.backingValue();
        // `deficitRemaining` is measured AFTER `recordFeeCapitalization`, exactly as
        // `InterestWithheldForBackingRepair` reports the hole remaining after the receipt landed:
        // the withheld fee has already repaired `fee` of it.
        vm.expectEmit(true, false, false, true, address(waterfall));
        emit IWaterfallEngine.OriginationFeeWithheldForBackingRepair(id2, fee, deficitBefore - fee);
        vm.expectEmit(true, true, false, true, address(waterfall));
        emit IWaterfallEngine.OriginationFeeCharged(id2, Config.CLASS_FILM_TAX_CREDITS, fee);
        vm.prank(servicer);
        waterfall.fund(id2, 50_000e6);

        assertEq(usdfr.balanceOf(feeRecipient), feeRecipientBefore, "FOREST ROAD WAS PAID OUT OF A SHORTFALL");
        // The borrower is still charged the full fee and it is still capitalised into their
        // principal, so the WITHHELD part is pure coverage: backing rises by exactly the fee while
        // supply does not move at all, and the deficit SHRINKS by that amount.
        assertEq(controller.backingValue() - backingBefore, fee, "the withheld fee did not stay as backing");
        assertEq(controller.recognizedDeficit(), deficitBefore - fee, "the withholding did not repair the hole");
        assertEq(reserves.deployedTo(id2), 50_000e18, "the facility did not deploy its full principal");
    }

    // =====================================================================
    //  B — a token pause must not stop a borrower repaying
    // =====================================================================

    /// @notice R18 (finding B-3), end to end through the real engine. R17 shipped
    ///         `test_R17_D3_aControllerPauseDoesNotStopBorrowerRepayment` and it passed; the same
    ///         scenario under a TOKEN pause reverted the entire `distribute`, unwinding from the
    ///         yield leg (`USDfr::mint -> EnforcedPause()`) and taking the principal leg, the
    ///         attestation spend, the exposure release and the lifecycle transition with it.
    ///
    ///         DELETION MUTATION: drop `|| $.usdfr.paused()` from `mintableHeadroom()` and this
    ///         goes RED with `EnforcedPause()`.
    function test_R18_B3_aTokenPauseDoesNotStopBorrowerRepayment() public {
        uint256 id = _liveFilmFacility(300_000e18);
        _stakeVault(alice, 50_000e18);

        IWaterfallEngine.Payment memory p = _preparePayment(id, 10_000e18, 20_000e18);
        vm.prank(guardian);
        usdfr.pause();

        uint256 vaultBefore = usdfr.balanceOf(address(vault));
        vm.expectEmit(false, false, false, true, address(waterfall));
        emit IWaterfallEngine.InterestWithheldForBackingRepair(10_000e18, 0);
        vm.prank(servicer);
        waterfall.distribute(p);

        assertEq(reserves.deployedTo(id), 280_000e18, "THE PRINCIPAL LEG WAS COLLATERAL DAMAGE OF A TOKEN PAUSE");
        assertEq(usdfr.balanceOf(address(vault)), vaultBefore, "a paused token still paid yield");
    }
}
