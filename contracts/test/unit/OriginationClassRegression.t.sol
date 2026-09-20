// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @notice Admission uses the production registry and real signed attestations on both chains.
contract OriginationClassRegression is ProductionCreditFixture {
    function testFuzz_inactiveClassCannotOriginateAndReactivationPreservesTheSameId(uint96 seed) public {
        uint256 principal = bound(uint256(seed), 1e18, 1_000_000e18);
        uint64 maturity = uint64(block.timestamp + 365 days);
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            classId, BORROWER_1, STATE_GA, principal, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF
        );
        _attestFilmGate(1, BORROWER_1, STATE_GA, principal, FILM_LTV_BPS, FILM_RATE_BPS, maturity, FILM_REF);
        ICollateralRegistry.ClassParams memory params = registry.classParams(classId);
        params.active = false;
        vm.prank(admin);
        registry.setClass(classId, params);

        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.Registry_ClassInactive.selector, classId));
        bridge.originate(custodian, terms);
        assertEq(bridge.totalOriginated(), 0);
        assertEq(registry.classExposure(classId), 0);
        assertEq(registry.borrowerExposure(BORROWER_1), 0);
        assertEq(registry.stateExposure(STATE_GA), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.deployedTo(1), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(1)));
        bridge.ownerOf(1);
        bytes32 commitment = bridge.creditTermsHash(terms);
        assertEq(uint256(realOracle.factStatus(1, IAttestationOracle.AttestationKind.CreditIssued, commitment)),
            uint256(IAttestationOracle.FactStatus.Recorded));

        params.active = true;
        vm.prank(admin);
        registry.setClass(classId, params);
        vm.prank(originator);
        uint256 id = bridge.originate(custodian, terms);
        assertEq(id, 1);
        assertEq(bridge.ownerOf(id), custodian);
        assertEq(bridge.totalOriginated(), 1);
        assertEq(registry.classExposure(classId), principal);
        assertEq(registry.borrowerExposure(BORROWER_1), principal);
        assertEq(registry.stateExposure(STATE_GA), principal);
        assertEq(registry.totalBookExposure(), principal);
        assertEq(reserves.deployedTo(id), 0, "origination alone does not move reserve principal");
    }
}
