// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";

contract ClaimBridgeMediumRegression is ProductionCreditFixture {
    function _pikFacilities() internal pure override returns (bool) { return true; }
    function _fixturePaymentInterval() internal pure override returns (uint64) { return 90 days; }

    function test_medium_legacyPikDateChangeRefusesWithoutConsumingApproval() public {
        _mintUSDfrTo(alice, 200_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        _fundFacility(id, 100_000e18);
        ClaimBridge.Facility memory f = bridge.facility(id);
        ClaimBridge.Amendment memory a = _earlierPikAmendment(f);
        bytes32 amendment = keccak256("legacy-coupon-date-change");
        _attest(id, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendment, id, a)), uint64(block.timestamp));
        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_LegacyPikScheduleRequiresMigration.selector, id));
        bridge.amendTerms(id, amendment, a);
        assertEq(bridge.facility(id).nextPaymentDue, f.nextPaymentDue);
        assertEq(reserves.deployedTo(id), 100_000e18);
        (,, bool satisfied) = realOracle.latestPayload(id, IAttestationOracle.AttestationKind.TermsAmended);
        assertTrue(satisfied, "rejected amendment consumed approval");
        vm.warp(f.nextPaymentDue);
        assertGt(waterfall.capitalizePik(id), 0, "original agreed schedule remains serviceable");
    }

    function _earlierPikAmendment(ClaimBridge.Facility memory f) private view returns (ClaimBridge.Amendment memory) {
        return ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps, maturity: f.maturity,
            paymentInterval: 1 days, nextPaymentDue: uint64(block.timestamp + 1 days),
            rateType: f.rateType, dayCountConvention: f.dayCountConvention, renewable: f.renewable,
            paymentScheduleHash: keccak256("one-day-coupon"), rateIndexRef: f.rateIndexRef, renewalTermsHash: f.renewalTermsHash
        });
    }
    function test_medium_unconfiguredClassRefusesOriginationUntilAttested() public {
        ClaimBridge fresh = ClaimBridge(address(new ERC1967Proxy(address(new ClaimBridge()),
            abi.encodeCall(ClaimBridge.initialize, (admin, guardian, admin, address(registry), address(oracle))))));
        vm.startPrank(admin);
        fresh.grantRole(Roles.ORIGINATOR_ROLE, originator);
        registry.grantRole(Roles.CREDIT_ROLE, address(fresh));
        vm.stopPrank();
        ClaimBridge.OriginationTerms memory t = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS, BORROWER_1, STATE_GA, 100_000e18,
            FILM_LTV_BPS, FILM_RATE_BPS, uint64(block.timestamp + 365 days), FILM_REF
        );
        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadAttestationMask.selector, uint256(0)));
        fresh.originate(custodian, t);
        assertEq(registry.classExposure(t.classId), 0);
        vm.prank(admin);
        fresh.setRequiredMintAttestations(t.classId, uint256(1) << uint8(IAttestationOracle.AttestationKind.CreditIssued));
        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_AttestationMissing.selector, t.classId, IAttestationOracle.AttestationKind.CreditIssued));
        fresh.originate(custodian, t);
        _attest(1, IAttestationOracle.AttestationKind.CreditIssued, fresh.creditTermsHash(t), uint64(block.timestamp));
        vm.prank(originator);
        uint256 id = fresh.originate(custodian, t);
        fresh.checkFundable(id);
        assertEq(fresh.ownerOf(id), custodian);
        assertEq(registry.classExposure(t.classId), t.principal);
    }

    function test_medium_fundingRechecksMissingLegacyMaskWithoutMovingValue() public {
        _mintUSDfrTo(alice, 200_000e18);
        uint256 id = _originateFilm(BORROWER_1, STATE_GA, 100_000e18);
        uint256 classId = Config.CLASS_FILM_TAX_CREDITS;
        uint256 mask = bridge.requiredMintAttestations(classId);
        assertGt(mask, 0);
        vm.record();
        bridge.requiredMintAttestations(classId);
        (bytes32[] memory reads,) = vm.accesses(address(bridge));
        bytes32 slot;
        uint256 matches;
        for (uint256 i; i < reads.length; ++i) {
            if (vm.load(address(bridge), reads[i]) == bytes32(mask)) { slot = reads[i]; ++matches; }
        }
        assertEq(matches, 1, "verified legacy mask slot");
        vm.store(address(bridge), slot, bytes32(0));
        assertEq(bridge.requiredMintAttestations(classId), 0, "legacy state seed applied");
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadAttestationMask.selector, uint256(0)));
        bridge.checkFundable(id);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(ClaimBridge.Bridge_BadAttestationMask.selector, uint256(0)));
        waterfall.fund(id, 100_000e6);
        assertEq(reserves.deployedTo(id), 0);
        vm.store(address(bridge), slot, bytes32(mask));
        _fundFacility(id, 100_000e18);
        assertEq(reserves.deployedTo(id), 100_000e18);
    }
}

contract NativePikScheduleMediumRegression is NativeAccrualFixture {
    function _pikFacilities() internal pure override returns (bool) { return true; }

    function test_medium_nativePikDateChangeUsesAmendedSchedule() public {
        _nativeFund(100_000e18);
        ClaimBridge.Facility memory f = bridge.facility(nativeId);
        ClaimBridge.Amendment memory a = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps, maturity: f.maturity,
            paymentInterval: 1 days, nextPaymentDue: uint64(block.timestamp + 1 days),
            rateType: f.rateType, dayCountConvention: f.dayCountConvention, renewable: f.renewable,
            paymentScheduleHash: keccak256("one-day-native-coupon"), rateIndexRef: f.rateIndexRef, renewalTermsHash: f.renewalTermsHash
        });
        bytes32 amendment = keccak256("native-coupon-date-change");
        _attest(nativeId, IAttestationOracle.AttestationKind.TermsAmended, keccak256(abi.encode(amendment, nativeId, a)), uint64(block.timestamp));
        vm.prank(originator);
        bridge.amendTerms(nativeId, amendment, a);
        vm.warp(a.nextPaymentDue);
        assertGt(waterfall.capitalizePik(nativeId), 0);
        assertEq(bridge.facility(nativeId).nextPaymentDue, a.nextPaymentDue + a.paymentInterval);
        assertGt(reserves.deployedTo(nativeId), 100_000e18);
        _assertNativeBacking();
    }
}
