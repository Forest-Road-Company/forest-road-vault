// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TokenLayerFixture} from "../helpers/TokenLayerFixture.sol";

/// @notice Local defensive proof for protocol-exemption scope on value sinks.
contract DeepSecurityComplianceExemptionTest is TokenLayerFixture {
    function test_exemptExternalFeeRecipientBypassesJurisdictionBlock() public {
        address externalFeeRecipient = makeAddr("externalFeeRecipient");

        vm.prank(address(controller));
        usdfr.mint(externalFeeRecipient, 10e18);

        vm.startPrank(admin);
        usdfr.setComplianceModule(address(compliance));
        compliance.setProtocolExempt(externalFeeRecipient, true);
        vm.stopPrank();

        vm.prank(complianceAdmin);
        compliance.setJurisdictionBlocked(externalFeeRecipient, true);

        assertTrue(compliance.isProtocolExempt(externalFeeRecipient));
        assertTrue(compliance.isJurisdictionBlocked(externalFeeRecipient));
        assertTrue(compliance.canTransfer(address(usdfr), externalFeeRecipient, bob));

        vm.prank(externalFeeRecipient);
        usdfr.transfer(bob, 1e18);
        assertEq(usdfr.balanceOf(bob), 1e18);
    }
}
