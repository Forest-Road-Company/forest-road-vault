// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeOpeningFixture} from "../helpers/NativeOpeningFixture.sol";
import {AccrualDebtReference} from "../helpers/AccrualDebtReference.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

contract FullPikOpeningTest is NativeOpeningFixture {
    using AccrualDebtReference for AccrualDebtReference.Note;

    function _issue(uint16 rate, uint64 duration) private returns (uint256 id) {
        ClaimBridge.OriginationTerms memory t = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS,
            BORROWER_1,
            STATE_GA,
            100_000e18,
            FILM_LTV_BPS,
            rate,
            uint64(block.timestamp) + duration,
            FILM_REF
        );
        t.pik = true;
        bytes32 h = bridge.creditTermsHash(t);
        _attest(1, IAttestationOracle.AttestationKind.CreditIssued, h, uint64(block.timestamp));
        _attest(1, IAttestationOracle.AttestationKind.AssignmentExecuted, h, uint64(block.timestamp));
        _attest(1, IAttestationOracle.AttestationKind.UCCFiled, h, uint64(block.timestamp));
        vm.prank(originator);
        id = bridge.originate(custodian, t);
        _fundFacility(id, t.principal);
    }

    function test_openingAboveFormerCapContinuesToFullFaceAndRepayment() public {
        nativeId = _issue(6000, uint64(730 days));
        AccrualDebtReference.Note memory n;
        n.principal = 100_000e18;
        n.ceiling = type(uint256).max / 10_000;
        n.scale = _nativeScale();
        n.year = 360 days;
        n.rate = 6000;
        n.interval = 90 days;
        n.due = nativeStart + n.interval;
        n.maturity = nativeStart + 730 days;
        n.pik = true;
        n.open(nativeStart);
        nativeReference = n;
        _prepareOne(nativeStart + 725 days);
        assertGt(reserves.deployedTo(nativeId), 300_000e18);
        _enableOpening();
        _nativeAdvance(nativeStart + 730 days);
        n = nativeReference;
        assertGt(n.principal + n.interest, 311_000e18);
        _nativePayAll();
        assertEq(reserves.deployedTo(nativeId), 0);
        assertEq(registry.totalBookExposure(), 0);
        assertEq(reserves.accrualSnapshot().gross, n.earned);
    }
}
