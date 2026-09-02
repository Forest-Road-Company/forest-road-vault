// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {IMintRedeemController} from "../../src/interfaces/IMintRedeemController.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @title ATK_USDfrForkTest — adversarial attacks on USDfr (src/USDfr.sol) on a pinned mainnet fork.
/// @notice Every function here ATTEMPTS a real exploit against USDfr's value surface and makes each
///         outcome unambiguous: an attack that lands asserts the violated state; an attack the token
///         correctly blocks asserts the SPECIFIC custom error the token must throw.
///
///         The named permissionless entry point is `burn`. It LOOKS permissionless (no modifier in
///         the signature) but the body does `_checkRole(MINTER_ROLE, msg.sender)`, so the interesting
///         question is whether an adversary can reach it, or reach any other supply/balance mutation,
///         from a hostile actor. The three invariants under attack (CLAUDE.md 1.3):
///           I1. burn cannot reduce ANOTHER holder's balance (and no permissionless supply cut at all).
///           I2. the supply/backing relationship is preserved (no non-minter supply inflation).
///           I3. the compliance gate — sanctions on transfer, KYC at the primary mint gate — blocks
///               the party it must while leaving holding open.
contract ATK_USDfrForkTest is ForkLifecycleFixture {
    // ─────────────────────────────────────────────────────────────────────────
    // I1 — burn cannot reduce another holder's balance
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: an adversary with no role tries to burn a VICTIM's USDfr out from under them
    ///         (`burn(from, amount)` takes an arbitrary `from`). If the role check is missing or
    ///         wrong this seizes bob's balance and cuts supply. It must revert on MINTER_ROLE, and
    ///         bob's balance and total supply must be untouched.
    function test_ATK_burn_byNonMinter_cannotReduceAnotherHolder() public onFork {
        uint256 minted = _mintFromUSDC(bob, 1_000e6); // bob holds 1_000e18 USDfr
        uint256 bobBalBefore = usdfr.balanceOf(bob);
        uint256 supplyBefore = usdfr.totalSupply();
        assertEq(bobBalBefore, minted, "setup: bob mint amount");

        // carol reaches the permissionless-looking entry point with no role whatsoever.
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.MINTER_ROLE)
        );
        usdfr.burn(bob, bobBalBefore);

        assertEq(usdfr.balanceOf(bob), bobBalBefore, "INVARIANT VIOLATED: victim balance seized by unprivileged burn");
        assertEq(usdfr.totalSupply(), supplyBefore, "INVARIANT VIOLATED: supply cut by unprivileged burn");
    }

    /// @notice ATTACK: a holder tries to burn their OWN tokens directly. Even self-burn is not a
    ///         permissionless path — supply may only contract through the controller. Confirms there
    ///         is no permissionless supply-reduction lever at all.
    function test_ATK_burn_ownTokens_isStillRoleGated() public onFork {
        _mintFromUSDC(alice, 500e6);
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 aliceBal = usdfr.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.MINTER_ROLE)
        );
        usdfr.burn(alice, aliceBal);

        assertEq(usdfr.totalSupply(), supplyBefore, "INVARIANT VIOLATED: a holder cut supply without MINTER_ROLE");
    }

    /// @notice ATTACK: `transfer` is genuinely permissionless — can it be used as a back-door burn to
    ///         the zero address, bypassing the MINTER_ROLE gate on `burn`? OZ ERC20 refuses a zero
    ///         recipient before `_update`, so the burn address is unreachable from `transfer`.
    function test_ATK_transferToZero_isNotABackDoorBurn() public onFork {
        _mintFromUSDC(alice, 100e6);
        uint256 supplyBefore = usdfr.totalSupply();
        uint256 amt = usdfr.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        usdfr.transfer(address(0), amt);

        assertEq(usdfr.totalSupply(), supplyBefore, "INVARIANT VIOLATED: supply cut via transfer-to-zero");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I2 — supply/backing relationship preserved
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK: an adversary tries to mint unbacked USDfr straight from the token, which would
    ///         drive totalSupply above backingValue and break ADR-0012. Only the controller holds
    ///         MINTER_ROLE, so this must revert and supply must not move.
    function test_ATK_mint_byNonMinter_cannotInflateSupplyPastBacking() public onFork {
        uint256 supplyBefore = usdfr.totalSupply();

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, Roles.MINTER_ROLE)
        );
        usdfr.mint(carol, 1_000_000e18);

        assertEq(usdfr.totalSupply(), supplyBefore, "INVARIANT VIOLATED: supply inflated by a non-minter");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I3 — compliance gate: sanctions freeze on transfer, KYC at the mint gate, holding open
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK on the sanctions freeze. A sanctioned wallet must be frozen in BOTH directions
    ///         (cannot receive value, cannot move value out), yet its existing holding must remain
    ///         its own — a sanctions block is a freeze, not a confiscation. Lifting the block must
    ///         restore transferability, proving the sanctions list (not some unrelated gate) was the
    ///         cause.
    function test_ATK_sanctionedHolder_frozenBothWays_holdingIntact() public onFork {
        uint256 aliceMint = _mintFromUSDC(alice, 1_000e6);
        uint256 bobMint = _mintFromUSDC(bob, 1_000e6);

        // The harness holds COMPLIANCE_ADMIN_ROLE (c.opsAdmin == address(this)). Sanction bob.
        compliance.setJurisdictionBlocked(bob, true);
        uint256 bobBalBefore = usdfr.balanceOf(bob);

        // (a) value cannot be routed INTO a sanctioned party.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, bob));
        usdfr.transfer(bob, 1e18);

        // (b) the sanctioned party cannot move value OUT.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, bob, alice));
        usdfr.transfer(alice, 1e18);

        // HOLDING STAYS OPEN: the freeze never seized bob's balance.
        assertEq(usdfr.balanceOf(bob), bobBalBefore, "INVARIANT VIOLATED: sanctions freeze altered the held balance");
        assertEq(bobBalBefore, bobMint, "setup: bob mint amount");

        // Lifting the sanction restores transfer => it truly was the sanctions gate that bit.
        compliance.setJurisdictionBlocked(bob, false);
        vm.prank(bob);
        usdfr.transfer(alice, 1e18);
        assertEq(usdfr.balanceOf(alice), aliceMint + 1e18, "un-sanctioned transfer failed to settle");
    }

    /// @notice ATTACK / probe on the KYC posture. The literal invariant text says "KYC gate blocks a
    ///         non-whitelisted TRANSFER". USDfr's actual (documented, 2026-07-14 directive) posture is
    ///         narrower: transfers are permissionless (sanctions-only); KYC is enforced at the PRIMARY
    ///         mint/redeem gate, not on transfer. This test pins that behaviour unambiguously:
    ///           - a non-KYC, non-sanctioned wallet CAN receive and CAN transfer USDfr (holding open),
    ///           - the same wallet CANNOT mint through the controller (the KYC gate that actually bites).
    ///         If a future change were to move KYC onto transfers, the two succeeding legs below flip
    ///         to reverts and this fails loudly.
    function test_ATK_nonKYC_transferAndHoldOpen_butPrimaryMintGated() public onFork {
        assertFalse(compliance.isAllowed(carol), "setup: carol must be non-KYC");

        _mintFromUSDC(alice, 1_000e6);

        // Holding is permissionless: a non-KYC wallet receives USDfr.
        vm.prank(alice);
        usdfr.transfer(carol, 250e18);
        assertEq(usdfr.balanceOf(carol), 250e18, "non-KYC wallet could not hold USDfr");

        // Transfer is permissionless: the non-KYC wallet moves USDfr out. KYC does NOT gate transfer.
        vm.prank(carol);
        usdfr.transfer(bob, 100e18);
        assertEq(usdfr.balanceOf(bob), 100e18, "non-KYC wallet could not transfer USDfr");
        assertEq(usdfr.balanceOf(carol), 150e18, "sender balance wrong after non-KYC transfer");

        // The KYC gate bites at the PRIMARY path only: the non-KYC wallet cannot mint.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IMintRedeemController.Controller_NotKYCAllowed.selector, carol));
        controller.mint(100e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Emergency-pause carve-out (AUDIT FIX C4-USDFR-02) — burns only out of a listed module
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ATTACK on the pause outflow rule. C4-USDFR-02 fixed a version whose pause let ANY burn
    ///         through, so first movers kept draining the reserve at par via redemption burns while the
    ///         inflow was closed. Under a token pause:
    ///           - an ordinary user transfer must be closed (EnforcedPause),
    ///           - a redemption burn OUT OF A USER (non-exempt `from`) must be closed too, even though
    ///             it is a burn and even when driven by the real MINTER (the controller),
    ///           - but a burn out of a protocol-exempt module (the vault) must still work, so the loss
    ///             cascade is not frozen.
    ///         A regression to the old "to == address(0) short-circuits" rule flips the middle leg from
    ///         a revert to a supply cut and this fails loudly.
    function test_ATK_pausedToken_closesUserBurnLeg_keepsCascadeBurn() public onFork {
        _mintFromUSDC(alice, 2_000e6);
        _stake(alice, 500e18); // the (protocol-exempt) vault now holds USDfr

        // The harness holds GUARDIAN_ROLE on USDfr (c.opsAdmin == address(this)).
        usdfr.pause();
        assertTrue(usdfr.paused(), "setup: token not paused");

        // (a) ordinary user transfer is closed.
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.transfer(bob, 1e18);

        // (b) SECURITY-CRITICAL: a redemption-style burn out of a NON-exempt user is closed even
        //     when reached through the real MINTER, so only the pause rule can be the cause.
        uint256 supplyBeforeUserBurn = usdfr.totalSupply();
        vm.prank(address(controller));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        usdfr.burn(alice, 1e18);
        assertEq(
            usdfr.totalSupply(), supplyBeforeUserBurn, "INVARIANT VIOLATED: user redemption burn leaked under pause"
        );

        // (c) the cascade still runs: a burn out of the protocol-exempt vault is permitted.
        uint256 vaultBal = usdfr.balanceOf(address(vault));
        assertGt(vaultBal, 0, "setup: vault holds no USDfr");
        vm.prank(address(controller));
        usdfr.burn(address(vault), 1e18);
        assertEq(
            usdfr.balanceOf(address(vault)), vaultBal - 1e18, "cascade burn from exempt module wrongly blocked by pause"
        );

        usdfr.unpause();
    }
}
