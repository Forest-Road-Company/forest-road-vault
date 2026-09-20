// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualStatefulFixture} from "../helpers/NativeAccrualStatefulFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";

/// @dev Complements the cash admission model with real PIK coupons and independent debt accounting.
contract PikConcentrationInvariants is NativeAccrualStatefulFixture {
    uint256 public refusedOrigins;
    uint256 public growthBeyondLimit;
    uint256 private candidateSequence;

    function _pikFacilities() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        _floor(0);
        stepTime(90 days - 1);
        stepAdmission(1);
        stepReceipt(0);
        stepFund(100);
        stepTime(90 days - 1);
        stepPost(0);
        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = this.stepTime.selector;
        selectors[1] = this.stepAdmission.selector;
        selectors[2] = this.stepReceipt.selector;
        selectors[3] = this.stepFund.selector;
        selectors[4] = this.stepPost.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function _floor(uint256 value) private {
        vm.prank(admin);
        registry.setConcentrationFloor(value);
    }

    function stepTime(uint256 seed) public {
        uint256 beforeExposure = registry.classExposure(Config.CLASS_FILM_TAX_CREDITS);
        uint256 beforeCoupons = nativeCapitalizations;
        actTime(seed);
        if (
            nativeCapitalizations > beforeCoupons
                && registry.classExposure(Config.CLASS_FILM_TAX_CREDITS) > beforeExposure
        ) {
            ++growthBeyondLimit;
        }
        assertNativeStatefulAccounting();
    }

    function stepAdmission(uint256 seed) public {
        if (!_hasDebt()) return;
        uint256 principal = (seed % 100 + 1) * 1e18;
        uint64 maturity = uint64(block.timestamp + 365 days);
        uint256 nextId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = _facilityTerms(
            Config.CLASS_FILM_TAX_CREDITS,
            BORROWER_1,
            STATE_GA,
            principal,
            FILM_LTV_BPS,
            FILM_RATE_BPS,
            maturity,
            FILM_REF
        );
        terms.offchainRef = keccak256(abi.encode("concentration-candidate", ++candidateSequence));
        // A refused candidate does not consume its ID. Sign every document afresh without
        // populating the successful-origination helper's deal cache for that reusable ID.
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(nextId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash, uint64(block.timestamp));
        _attest(nextId, IAttestationOracle.AttestationKind.UCCFiled, termsHash, uint64(block.timestamp));
        _attest(nextId, IAttestationOracle.AttestationKind.CreditIssued, termsHash, uint64(block.timestamp));
        uint256 beforeExposure = registry.totalBookExposure();
        vm.prank(originator);
        vm.expectPartialRevert(ICollateralRegistry.Registry_ConcentrationExceeded.selector);
        bridge.originate(custodian, terms);
        assertEq(registry.totalBookExposure(), beforeExposure);
        assertEq(bridge.totalOriginated() + 1, nextId);
        ++refusedOrigins;
    }

    function stepReceipt(uint256 seed) public {
        actReceipt(seed);
    }

    function stepFund(uint256 seed) public {
        if (_hasDebt()) return;
        _floor(25_000_000e18);
        actFund(seed);
        _floor(0);
    }

    function stepPost(uint256 seed) public {
        actPost(seed);
    }

    function invariant_pikGrowthAndAdmissionRespectTheirDifferentRules() public view {
        assertNativeStatefulAccounting();
        if (registry.totalBookExposure() != 0) {
            assertEq(registry.concentrationHeadroom(Config.CLASS_FILM_TAX_CREDITS, BORROWER_1, STATE_GA), 0);
            assertTrue(registry.overConcentratedClasses() & 1 != 0, "PIK concentration was not disclosed");
        }
    }

    function afterInvariant() public view {
        assertGt(refusedOrigins, 0, "PIK breach never refused an origination");
        assertGt(growthBeyondLimit, 0, "contractual PIK never grew a standing breach");
        assertGt(nativeCapitalizations, 0, "PIK coupon path was never reached");
        assertGt(nativeActions[0], 1, "PIK facility lifecycle never restarted");
    }
}
