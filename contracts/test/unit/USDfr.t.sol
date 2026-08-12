// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {USDfr} from "../../src/USDfr.sol";
import {IUSDfr} from "../../src/interfaces/IUSDfr.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract USDfrTest is TokenLayerFixture {
    // ── metadata / init ──────────────────────────────────────────────────

    function test_metadata_fromConfig() public view {
        assertEq(usdfr.name(), Config.USDFR_NAME);
        assertEq(usdfr.symbol(), Config.USDFR_SYMBOL);
        assertEq(usdfr.decimals(), 18);
    }

    function test_initialize_revertsOnZeroAddress() public {
        USDfr impl = new USDfr();
        vm.expectRevert(USDfr.USDfr_ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(USDfr.initialize, (address(0), admin, guardian, admin)));
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert();
        usdfr.initialize(admin, admin, guardian, admin);
    }

    function test_roles_controllerIsSoleMinter() public view {
        assertTrue(usdfr.hasRole(Roles.MINTER_ROLE, address(controller)));
        assertFalse(usdfr.hasRole(Roles.MINTER_ROLE, admin)); // placeholder renounced
    }

    // ── mint / burn ──────────────────────────────────────────────────────

    function test_mint_onlyMinter() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 100e18);
        assertEq(usdfr.balanceOf(alice), 100e18);
        assertEq(usdfr.totalSupply(), 100e18);
    }

    function test_mint_revertsForNonMinter() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.MINTER_ROLE)
        );
        vm.prank(alice);
        usdfr.mint(alice, 1e18);
    }

    function test_burn_minterCanBurn() public {
        vm.startPrank(address(controller));
        usdfr.mint(alice, 100e18);
        usdfr.burn(alice, 40e18);
        vm.stopPrank();
        assertEq(usdfr.balanceOf(alice), 60e18);
    }

    function test_burn_revertsForUnauthorized() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.MINTER_ROLE)
        );
        vm.prank(alice);
        usdfr.burn(alice, 1e18);
    }

    // ── pause ────────────────────────────────────────────────────────────

    /// @notice INVERTED BY AUDIT FIX C4-USDFR-02 — READ THIS BEFORE "RESTORING" IT.
    ///
    ///         This test previously asserted, under the name `..._ButAllowsProtocolBurns` and
    ///         the message "loss and redemption burns survive emergency pause", that a paused
    ///         USDfr still burned ALICE's balance. Alice is an ordinary KYC'd holder, not a
    ///         protocol module: the test name claimed a protocol carve-out while the body
    ///         exercised the USER redemption leg, and it was the only coverage the paused burn
    ///         path had. That is the defect, not the specification.
    ///
    ///         The burn is the protocol's OUTFLOW: `MintRedeemController.redeem` burns a
    ///         holder's USDfr and releases the USDC behind it. Permitting it under a pause meant
    ///         the guardian closed the inflow while the reserve kept draining at par. The
    ///         assertion is therefore inverted, NOT weakened — the burn must now revert. The
    ///         genuine protocol carve-out (a burn FROM a governance-listed module) is asserted
    ///         in `test_pause_keepsTheProtocolModuleBurnLive`
    ///         (`test/audit/Fix_C4USDfr_PointsBrickAndPauseOutflow.t.sol`), which is where the
    ///         name of this test always belonged.
    function test_pause_blocksUserTransfersMintsAndTheRedemptionBurn() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 100e18);

        vm.prank(guardian);
        usdfr.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(controller));
        usdfr.mint(alice, 1e18);

        // WAS: `usdfr.burn(alice, 1e18)` succeeding. A user's balance is not a protocol leg.
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(controller));
        usdfr.burn(alice, 1e18);
        assertEq(usdfr.balanceOf(alice), 100e18, "a pause must stop the outflow, not only the inflow");

        vm.prank(guardian);
        usdfr.unpause();
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
        assertEq(usdfr.balanceOf(bob), 1e18);
        vm.prank(address(controller));
        usdfr.burn(alice, 1e18); // and the redemption burn returns the moment the pause lifts
        assertEq(usdfr.balanceOf(alice), 98e18);
    }

    function test_pause_allowsTransfersBetweenProtocolExemptModules() public {
        address moduleA = makeAddr("moduleA");
        address moduleB = makeAddr("moduleB");
        vm.startPrank(admin);
        compliance.setProtocolExempt(moduleA, true);
        compliance.setProtocolExempt(moduleB, true);
        usdfr.setComplianceModule(address(compliance));
        vm.stopPrank();
        vm.prank(address(controller));
        usdfr.mint(moduleA, 10e18);
        vm.prank(guardian);
        usdfr.pause();

        vm.prank(moduleA);
        usdfr.transfer(moduleB, 4e18);
        assertEq(usdfr.balanceOf(moduleB), 4e18);
    }

    function test_pause_onlyGuardian() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.GUARDIAN_ROLE)
        );
        vm.prank(alice);
        usdfr.pause();
    }

    // ── compliance module ────────────────────────────────────────────────

    function test_transfers_freeWhenNoModuleSet() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 10e18);
        vm.prank(alice);
        usdfr.transfer(carol, 5e18); // carol isn't KYC'd; holding/transfer is open
        assertEq(usdfr.balanceOf(carol), 5e18);
    }

    function test_setComplianceModule_adminOnlyAndEmits() public {
        vm.expectEmit(true, false, false, true, address(usdfr));
        emit IUSDfr.ComplianceModuleUpdated(address(compliance));
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));
        assertEq(usdfr.complianceModule(), address(compliance));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        usdfr.setComplianceModule(address(0));
    }

    function test_transfer_blockedByModuleForBlockedParty() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 10e18);
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(bob, true);

        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, bob));
        vm.prank(alice);
        usdfr.transfer(bob, 1e18);
    }

    function test_transfer_permissionlessButSanctionedBlocked() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 10e18);
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));

        // 2026-07-14 directive: transfers are permissionless. carol is NOT allowlisted but
        // the transfer to her succeeds — no KYC gate on transfer.
        vm.prank(alice);
        usdfr.transfer(carol, 1e18);
        assertEq(usdfr.balanceOf(carol), 1e18);

        // sanctions freeze still applies: once carol is blocked, transfers to her are denied.
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(carol, true);
        vm.expectRevert(abi.encodeWithSelector(IUSDfr.USDfr_TransferNotAllowed.selector, alice, carol));
        vm.prank(alice);
        usdfr.transfer(carol, 1e18);
    }

    function test_burn_worksEvenWhenPartyBlocked() public {
        vm.prank(address(controller));
        usdfr.mint(alice, 10e18);
        vm.prank(admin);
        usdfr.setComplianceModule(address(compliance));
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(alice, true);
        // enforcement burn still possible
        vm.prank(address(controller));
        usdfr.burn(alice, 10e18);
        assertEq(usdfr.balanceOf(alice), 0);
    }

    // ── permit ───────────────────────────────────────────────────────────

    function test_permit_setsAllowance() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        vm.prank(address(controller));
        usdfr.mint(owner, 5e18);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                5e18,
                usdfr.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdfr.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        usdfr.permit(owner, bob, 5e18, deadline, v, r, s);
        assertEq(usdfr.allowance(owner, bob), 5e18);
    }

    // ── zero-balance edge ────────────────────────────────────────────────

    function test_transfer_insufficientBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        usdfr.transfer(bob, 1);
    }

    // ── upgrade ──────────────────────────────────────────────────────────

    function test_upgrade_authorizedOnly() public {
        address newImpl = address(new USDfr());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        usdfr.upgradeToAndCall(newImpl, "");

        vm.prank(address(controller));
        usdfr.mint(alice, 7e18);
        vm.prank(admin);
        usdfr.upgradeToAndCall(newImpl, "");
        assertEq(usdfr.balanceOf(alice), 7e18); // state survives
    }
}
