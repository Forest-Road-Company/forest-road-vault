// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {NativeAccrualFixture} from "../helpers/NativeAccrualFixture.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev Real credit transitions drive the reference episode. Expected validity never reads
///      the implementation's risk hash, revision, or stored assessment snapshot.
contract NativeAssessmentInvariants is NativeAccrualFixture {
    enum Risk {
        Performing,
        PastDue,
        Declared,
        Closed
    }

    Risk private risk;
    uint256 private episode;
    uint256 private publicationEpisode;
    uint256 private assessed;
    uint256 private feeMark;
    uint256 private exposureAtPublication;
    uint256 private expires;
    bool private present;
    uint256[9] public completed;
    uint256 public compatibleGrowth;
    uint256 public expiryCount;

    function setUp() public override {
        super.setUp();
        _nativeFund(400_000e18);
        stepMark();
        stepPublish(100_000e18);
        stepTime(1 hours);
        stepPost();
        stepRepay(1);
        stepPublish(1);
        stepCure();
        stepMark();
        stepPublish(1);
        stepDeclare();
        stepPublish(1);
        stepLoss(1);
        stepPublish(1);
        stepRepay(0);
        stepFund(1000);
        stepMark();
        stepPublish(1);
        for (uint256 i; i < 8; ++i) {
            stepTime(1 days);
        }
        stepClear();
        stepPublish(1);
        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = this.stepPublish.selector;
        selectors[1] = this.stepTime.selector;
        selectors[2] = this.stepPost.selector;
        selectors[3] = this.stepRepay.selector;
        selectors[4] = this.stepCure.selector;
        selectors[5] = this.stepMark.selector;
        selectors[6] = this.stepDeclare.selector;
        selectors[7] = this.stepLoss.selector;
        selectors[8] = this.stepFund.selector;
        selectors[9] = this.stepClear.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function _active() private view returns (bool) {
        return present && publicationEpisode == episode && block.timestamp <= expires;
    }

    function stepPublish(uint256 seed) public {
        uint256 conservative = defaultManager.pendingSeniorImpairment();
        assessed = conservative == 0 ? 0 : seed % (conservative + 1);
        feeMark = assessed + defaultManager.performanceFeeImpairment() - conservative;
        exposureAtPublication = defaultManager.pastDueExposure();
        publicationEpisode = episode;
        expires = block.timestamp + 7 days;
        present = true;
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(
            assessed, uint64(expires), keccak256(abi.encode("native-model-memo", ++completed[0]))
        );
        checkAssessment();
    }

    function stepTime(uint256 seed) public {
        uint256 dt = seed % (5 days) + 1;
        if (nativeReference.active && block.timestamp + dt >= nativeReference.maturity) {
            if (block.timestamp + 1 >= nativeReference.maturity) return;
            dt = nativeReference.maturity - block.timestamp - 1;
        }
        bool beforeActive = _active();
        uint256 beforeExposure = defaultManager.pastDueExposure();
        _nativeAdvance(uint64(block.timestamp + dt));
        if (beforeActive && !_active()) ++expiryCount;
        if (_active() && defaultManager.pastDueExposure() > beforeExposure) ++compatibleGrowth;
        ++completed[1];
        checkAssessment();
    }

    function stepPost() public {
        if (risk == Risk.Closed) return;
        reserves.postAccruedLoan(nativeId);
        ++completed[2];
        checkAssessment();
    }

    function stepRepay(uint256 seed) public {
        if (risk == Risk.Closed) return;
        bool affectsRisk = risk == Risk.PastDue || risk == Risk.Declared;
        uint256 poolBefore = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        uint256 capacityBefore = defaultManager.impairmentBackstopCapacity();
        if (seed % 3 == 0 || nativeReference.principal < 2 * _nativeScale()) {
            _nativePayAll();
            risk = Risk.Closed;
        } else {
            uint256 principal = nativeReference.principal / 2 / _nativeScale() * _nativeScale();
            _nativeReceipt(principal, 0);
        }
        // Aligning an asset-grid receipt can consume junior capital even on a performing
        // facility. Those real pool changes invalidate the old recovery assumptions.
        if (
            affectsRisk || curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS) != poolBefore
                || defaultManager.impairmentBackstopCapacity() < capacityBefore
        ) ++episode;
        ++completed[3];
        checkAssessment();
    }

    function stepCure() public {
        if (risk != Risk.PastDue) return;
        _clearPastDue(nativeId, keccak256(abi.encode("native-model-cure", episode)));
        risk = Risk.Performing;
        ++episode;
        ++completed[4];
        checkAssessment();
    }

    function stepMark() public {
        if (risk != Risk.Performing) return;
        uint256 eligible = uint256(bridge.facility(nativeId).nextPaymentDue)
            + defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1;
        if (block.timestamp < eligible) _nativeAdvance(uint64(eligible));
        defaultManager.markPastDue(nativeId);
        risk = Risk.PastDue;
        ++episode;
        ++completed[5];
        checkAssessment();
    }

    function stepDeclare() public {
        if (risk == Risk.Closed || risk == Risk.Declared) return;
        _nativeDeclare();
        risk = Risk.Declared;
        ++episode;
        ++completed[6];
        checkAssessment();
    }

    function stepLoss(uint256 seed) public {
        if (risk != Risk.Declared) return;
        uint256 face = nativeReference.principal + nativeReference.interest;
        uint256 amount = seed % 3 == 0 ? face : face / 2 / _nativeScale() * _nativeScale();
        if (amount == 0) amount = face;
        _nativeLoss(amount);
        if (amount == face) risk = Risk.Closed;
        ++episode;
        ++completed[7];
        checkAssessment();
    }

    function stepFund(uint256 seed) public {
        if (risk != Risk.Closed) return;
        uint256 principal = (seed % 1000 + 100) * 1e18;
        uint256 pool = curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS);
        if (pool < principal / 5) {
            uint256 scale = _nativeScale();
            uint256 topUp = (principal / 5 - pool + scale - 1) / scale * scale;
            _postFirstLoss(anchorCurator, Config.CLASS_FILM_TAX_CREDITS, topUp);
            ++episode; // A class-pool change affects the assessment; performing origination alone does not.
        }
        nativeStart = uint64(block.timestamp);
        nativeWrittenOff = 0;
        _nativeFund(principal);
        risk = Risk.Performing;
        ++completed[8];
        checkAssessment();
    }

    function stepClear() public {
        vm.prank(admin);
        assessedImpairmentSource.clearAssessment();
        present = false;
        checkAssessment();
    }

    function checkAssessment() public view {
        bool active = _active();
        (,,, bool actualActive,) = assessedImpairmentSource.currentAssessment();
        assertEq(actualActive, active, "real risk event did not match independent episode model");
        uint256 expectedSenior = defaultManager.pendingSeniorImpairment();
        uint256 expectedFee = defaultManager.performanceFeeImpairment();
        if (active) {
            uint256 growth = defaultManager.pastDueExposure() - exposureAtPublication;
            uint256 reserved = assessed + growth;
            if (reserved < expectedSenior) expectedSenior = reserved;
            expectedFee = feeMark + growth;
        }
        assertEq(assessedImpairmentSource.pendingSeniorImpairment(), expectedSenior, "senior ratchet drift");
        assertEq(assessedImpairmentSource.performanceFeeImpairment(), expectedFee, "fee ratchet drift");
        if (risk == Risk.PastDue) {
            assertGt(defaultManager.pastDueContribution(nativeId), 0, "model overdue branch absent");
        } else {
            assertEq(defaultManager.pastDueContribution(nativeId), 0, "model expected no overdue cohort");
        }
        if (_nativeBackstop() == address(0)) {
            assertEq(defaultManager.impairmentBackstopCapacity(), 0, "BSC invented layer-two capacity");
        }
        _assertNativeDebt();
        _assertNativeBacking();
    }

    function invariant_realCreditEventsMatchTheAssessmentModel() public view {
        checkAssessment();
    }

    function afterInvariant() public view {
        for (uint256 i; i < completed.length; ++i) {
            assertGt(completed[i], 0, "credit transition never completed");
        }
        assertGt(compatibleGrowth, 0, "active assessment never accrued");
        assertGt(expiryCount, 0, "assessment expiry never reached");
    }
}
