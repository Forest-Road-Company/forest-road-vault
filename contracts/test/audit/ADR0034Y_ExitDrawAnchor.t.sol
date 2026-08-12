// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {ISeniorExitDrawSource} from "../../src/interfaces/ISeniorExitDrawSource.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ControllerReserveDouble} from "../helpers/ControllerReserveDouble.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @dev A junior-draw stand-in that really moves USDfr: on `drawForSeniorExit` it pulls up to
///      `required` from a pre-approved treasury into ITSELF, which is exactly the observable
///      behaviour `CuratorModule.absorbGlobalLoss` and `SGrove.coverShortfall` produce for the
///      real `DefaultManager`. It exists so the controller's own guards can be falsified without
///      standing up the whole credit stack.
contract FundedExitDrawSource is ISeniorExitDrawSource {
    IERC20 public immutable USDFR;
    address public immutable TREASURY;

    constructor(IERC20 usdfr, address treasury) {
        USDFR = usdfr;
        TREASURY = treasury;
    }

    function drawForSeniorExit(uint256 required) external returns (uint256 drawn) {
        uint256 available = USDFR.balanceOf(TREASURY);
        drawn = required < available ? required : available;
        if (drawn != 0) USDFR.transferFrom(TREASURY, address(this), drawn);
    }
}

/// @title ADR-0034 Y-bis — the POST-DRAW DEFICIT ANCHOR, falsified
///
/// @notice WHY THIS FILE IS SEPARATE. `_assertDeficitNotWorsened`'s re-anchor is the one guard in
///         this change whose falsifier needs a reserve that MISBOOKS its own release. The credit
///         stack cannot produce that state — `ReserveManager` is honest by construction — so the
///         proof runs against `ControllerReserveDouble`, the double R16/R17 built for exactly this
///         class of guard, wired to a junior-draw stand-in that really moves USDfr.
///
///         THE ARITHMETIC THE PROOF TURNS ON. Anchoring on `supplyBefore - drawn` permits a
///         post-state deficit of `(S - d) - B`; anchoring on `supplyBefore` permits `d` MORE than
///         that. So a reserve that over-releases RECORDED backing by a delta strictly between
///         `usdfrIn - valuePaid` and `usdfrIn - valuePaid + d` is refused by the correct anchor and
///         waved through by the loose one. At a PAR settlement `usdfrIn == valuePaid`, so any
///         delta in `(0, d]` separates them — and that is what this test injects.
contract ADR0034Y_ExitDrawAnchor is TokenLayerFixture {
    address internal sink = makeAddr("double-sink");
    address internal juniorTreasury = makeAddr("junior-treasury");

    /// @notice G07. The closing deficit assertion is re-anchored on the POST-DRAW supply.
    ///         MUTATION: change `_assertDeficitNotWorsened($, supplyBefore - drawn, backingBefore)`
    ///         to `_assertDeficitNotWorsened($, supplyBefore - drawn * 0, backingBefore)` -- still
    ///         compiling, still reading `drawn` -- and this test goes GREEN where it must go RED,
    ///         i.e. the redemption succeeds while the reserve quietly destroyed backing the draw
    ///         had just paid for.
    function test_Y_G07_theDeficitAnchorIsRebasedOnThePostDrawSupply() public {
        vm.prank(admin);
        usdfr.grantRole(Roles.MINTER_ROLE, address(this));
        vm.prank(complianceAdmin);
        compliance.setAllowed(juniorTreasury, true);

        ControllerReserveDouble double = new ControllerReserveDouble(IERC20(address(usdc)), sink);
        MintRedeemController c = _doubleWiredController(double);

        // 100 USDfr of supply against 90 of recorded backing: a 10 deficit.
        usdfr.mint(alice, 100e18);
        double.seedBacking(90e18);
        usdc.mint(address(double), 100e6);

        // Junior capital that the draw can really move.
        FundedExitDrawSource source = new FundedExitDrawSource(IERC20(address(usdfr)), juniorTreasury);
        usdfr.mint(juniorTreasury, 50e18);
        vm.prank(juniorTreasury);
        usdfr.approve(address(source), type(uint256).max);
        double.setLossAbsorber(address(source));
        vm.prank(admin);
        c.setLossSource(address(source), true);

        // THE POSITIVE CONTROL. An honest reserve settles this exit at PAR out of junior capital.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 out = c.redeem(10e18, 10e6, block.timestamp);
        assertEq(out, 10e6, "positive control: the exit must settle at par out of the junior draw");
        uint256 drawn = 50e18 - usdfr.balanceOf(juniorTreasury);
        assertGt(drawn, 0, "positive control: the draw must really have moved junior capital");
        vm.revertToState(snap);

        // THE FALSIFIER. The reserve pays the right cash but writes RECORDED backing down by one
        // wei more than it should. The settlement is par, so `usdfrIn == valuePaid` and the whole
        // of `drawn` is the slack the loose anchor would have granted.
        double.setOverReleaseDelta(1);
        vm.prank(alice);
        vm.expectPartialRevert(IMintRedeemController.Controller_DeficitWorsened.selector);
        c.redeem(10e18, 10e6, block.timestamp);

        // And the guard is not merely firing on everything: with the delta cleared it passes again.
        double.setOverReleaseDelta(0);
        vm.prank(alice);
        assertEq(c.redeem(10e18, 10e6, block.timestamp), 10e6, "the guard must not refuse an honest reserve");
    }

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
}
