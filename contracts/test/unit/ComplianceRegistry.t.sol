// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

contract ComplianceRegistryTest is TokenLayerFixture {
    address internal token = makeAddr("someToken");

    // ── initialize ───────────────────────────────────────────────────────

    function test_initialize_roles() public view {
        assertTrue(compliance.hasRole(compliance.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, complianceAdmin));
        assertTrue(compliance.hasRole(Roles.UPGRADER_ROLE, admin));
        assertTrue(compliance.isProtocolExempt(feeRecipient));
    }

    function test_initialize_revertsOnZeroAddress() public {
        ComplianceRegistry impl = new ComplianceRegistry();
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(ComplianceRegistry.initialize, (address(0), admin, admin, feeRecipient))
        );
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(ComplianceRegistry.initialize, (admin, address(0), admin, feeRecipient))
        );
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(ComplianceRegistry.initialize, (admin, admin, address(0), feeRecipient))
        );
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(ComplianceRegistry.initialize, (admin, admin, admin, address(0)))
        );
    }

    function test_initialize_cannotRunTwice() public {
        vm.expectRevert();
        compliance.initialize(admin, complianceAdmin, admin, feeRecipient);
    }

    // ── setAllowed ───────────────────────────────────────────────────────

    function test_setAllowed_setsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.AllowlistUpdated(carol, true);
        vm.prank(complianceAdmin);
        compliance.setAllowed(carol, true);
        assertTrue(compliance.isAllowed(carol));

        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.AllowlistUpdated(carol, false);
        vm.prank(complianceAdmin);
        compliance.setAllowed(carol, false);
        assertFalse(compliance.isAllowed(carol));
    }

    function test_setAllowed_revertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        compliance.setAllowed(carol, true);
    }

    function test_setAllowed_revertsOnZeroAddress() public {
        vm.prank(complianceAdmin);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setAllowed(address(0), true);
    }

    // ── setAllowedBatch ──────────────────────────────────────────────────

    function test_setAllowedBatch_setsAll() public {
        address[] memory accounts = new address[](2);
        accounts[0] = carol;
        accounts[1] = borrower;
        vm.prank(complianceAdmin);
        compliance.setAllowedBatch(accounts, true);
        assertTrue(compliance.isAllowed(carol));
        assertTrue(compliance.isAllowed(borrower));
    }

    function test_setAllowedBatch_revertsForNonAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = carol;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        compliance.setAllowedBatch(accounts, true);
    }

    function test_setAllowedBatch_revertsOnZeroAddressEntry() public {
        address[] memory accounts = new address[](2);
        accounts[0] = carol;
        accounts[1] = address(0);
        vm.prank(complianceAdmin);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setAllowedBatch(accounts, true);
    }

    // ── setJurisdictionBlocked ───────────────────────────────────────────

    function test_setJurisdictionBlocked_blocksAndEmits() public {
        vm.expectEmit(true, false, false, true, address(compliance));
        emit IComplianceRegistry.JurisdictionBlockUpdated(alice, true);
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(alice, true);
        assertTrue(compliance.isJurisdictionBlocked(alice));
        // blocked overrides allowlisted
        assertFalse(compliance.isAllowed(alice));
    }

    function test_setJurisdictionBlocked_revertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.COMPLIANCE_ADMIN_ROLE
            )
        );
        vm.prank(alice);
        compliance.setJurisdictionBlocked(bob, true);
    }

    function test_setJurisdictionBlocked_revertsOnZeroAddress() public {
        vm.prank(complianceAdmin);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setJurisdictionBlocked(address(0), true);
    }

    // ── canTransfer matrix (permissionless transfers + sanctions freeze) ──

    function test_canTransfer_burnAlwaysAllowed() public {
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(alice, true);
        // even a blocked account can be burned from (protocol enforcement)
        assertTrue(compliance.canTransfer(token, alice, address(0)));
    }

    function test_canTransfer_mintBlockedRecipientDenied() public {
        assertTrue(compliance.canTransfer(token, address(0), carol));
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(carol, true);
        assertFalse(compliance.canTransfer(token, address(0), carol));
    }

    function test_canTransfer_permissionlessForNonBlocked() public view {
        // no allowlist gate on transfer (2026-07-14 directive): carol is not allowlisted
        // but not sanctioned — transfers are free in both directions.
        assertTrue(compliance.canTransfer(token, alice, carol));
        assertTrue(compliance.canTransfer(token, carol, alice));
    }

    function test_canTransfer_sanctionedPartyDenied() public {
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(carol, true);
        assertFalse(compliance.canTransfer(token, alice, carol));
        assertFalse(compliance.canTransfer(token, carol, alice));
    }

    /// @dev A protocol-exempt module is never itself treated as sanctioned, so a stray block
    ///      of a module address can't brick the never-pausable cascade/redemption. Sanctions
    ///      still apply to the non-module counterparty (see the R2-H-01 test below).
    function test_canTransfer_exemptModuleNotBrickable() public {
        address module = makeAddr("defaultManager");
        vm.prank(admin);
        compliance.setProtocolExempt(module, true);
        assertTrue(compliance.isProtocolExempt(module));

        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(module, true); // block the module itself
        assertTrue(compliance.canTransfer(token, module, alice), "exempt sender not treated as blocked");
        assertTrue(compliance.canTransfer(token, alice, module), "exempt receiver not treated as blocked");

        // exemption is DEFAULT_ADMIN-gated + zero-guarded
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        compliance.setProtocolExempt(module, false);
        vm.prank(admin);
        compliance.setProtocolExempt(module, false);
        assertFalse(compliance.isProtocolExempt(module));
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry_ZeroAddress.selector);
        compliance.setProtocolExempt(address(0), true);
    }

    /// @dev AUDIT REGRESSION (R2-H-01): a sanctioned wallet cannot route value out through an
    ///      exempt protocol module (e.g. depositing into the exempt sUSDfr vault). The
    ///      sanctions check precedes the exemption for the non-module party.
    function test_canTransfer_R2H01_sanctionedBlockedEvenViaExemptModule() public {
        address vaultModule = makeAddr("sUSDfrVault");
        vm.prank(admin);
        compliance.setProtocolExempt(vaultModule, true);
        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(alice, true); // alice sanctioned

        assertFalse(compliance.canTransfer(token, alice, vaultModule), "sanctioned sender denied via exempt module");
        assertFalse(compliance.canTransfer(token, vaultModule, alice), "sanctioned receiver denied via exempt module");
    }

    // ── upgrade authorization ────────────────────────────────────────────

    function test_upgrade_revertsForNonUpgrader() public {
        address newImpl = address(new ComplianceRegistry());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        compliance.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_succeedsForUpgrader() public {
        address newImpl = address(new ComplianceRegistry());
        vm.prank(admin);
        compliance.upgradeToAndCall(newImpl, "");
        // state survives the upgrade
        assertTrue(compliance.isAllowed(alice));
    }
}
