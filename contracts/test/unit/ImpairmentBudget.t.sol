// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ProductionCreditFixture} from "../helpers/ProductionCreditFixture.sol";
import {ImpairmentReadChecks} from "../helpers/ImpairmentReadChecks.sol";
import {ContinuousAccrualDeployment} from "../../script/ContinuousAccrualDeployment.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {Config} from "../../src/libraries/Config.sol";
import {IsUSDfr} from "../../src/interfaces/IsUSDfr.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";

abstract contract ImpairmentBudgetFixture is ProductionCreditFixture, ImpairmentReadChecks {
    function _recognitionMode() internal pure virtual returns (uint8);

    function setUp() public virtual override {
        super.setUp();
        if (_recognitionMode() != 0) {
            IContinuousAccrual.Modules memory modules = IContinuousAccrual.Modules(
                address(usdfr), address(controller), address(vault), address(waterfall),
                address(bridge), address(registry), address(defaultManager)
            );
            vm.startPrank(admin);
            if (_recognitionMode() == 2) ContinuousAccrualDeployment.configure(address(reserves), modules);
            else ContinuousAccrualDeployment.bind(address(reserves), modules);
            vm.stopPrank();
        }
        _mintUSDfrTo(alice, 2_000_000e18);
        vm.startPrank(alice);
        usdfr.approve(address(vault), 2_000_000e18);
        vault.deposit(2_000_000e18, alice);
        vm.stopPrank();
    }

    function _coverage(uint256 amount) internal virtual {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }

    function _loan(uint256 classId, uint256 sequence) private returns (uint256 id) {
        if (classId == Config.CLASS_DIGITAL_ASSETS) {
            id = _originateDigital(100_000e18, 1_000_000e18);
        } else {
            id = bridge.totalOriginated() + 1;
            ClaimBridge.OriginationTerms memory terms = _facilityTerms(
                classId, keccak256(abi.encode("gas-matrix-borrower", sequence, classId)),
                classId == Config.CLASS_FILM_TAX_CREDITS ? STATE_GA : bytes32(0),
                100_000e18, 5000, FILM_RATE_BPS, uint64(block.timestamp + 300 days), FILM_REF
            );
            _setSatisfied(id, IAttestationOracle.AttestationKind.AssignmentExecuted, true);
            _setSatisfied(id, IAttestationOracle.AttestationKind.UCCFiled, true);
            _attestCreditTerms(id, bridge.creditTermsHash(terms));
            vm.prank(originator);
            assertEq(bridge.originate(custodian, terms), id);
        }
        _fundFacility(id, 100_000e18);
    }

    function _maintain() internal {
        if (_recognitionMode() != 2) return;
        for (uint256 i; i < 32; ++i) {
            (, bool fresh) = reserves.checkpointAccrual(32);
            if (fresh) return;
        }
        fail("maintenance did not converge");
    }

    function _book(uint256 capitalMode) internal {
        uint256 capital = capitalMode == 0 ? 0 : capitalMode == 1 ? 10_000e18 : 300_000e18;
        if (capitalMode != 0) _coverage(capitalMode == 1 ? 200_000e18 : 1_000_000e18);
        uint256[] memory overdue = new uint256[](Config.NUM_CLASSES);
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            // Origination always has its required curator buffer. Mode zero consumes it below.
            _postFirstLoss(anchorCurator, classId, capital == 0 ? 10_000e18 : capital);
            uint256 id = _loan(classId, 0);
            overdue[classId - 1] = _loan(classId, 1);
            _attestDefault(id);
            vm.prank(servicer);
            defaultManager.declareDefault(id, FILM_REF);
            if (capitalMode == 0 || classId == 1) _realizeLoss(id, 20_000e18, keccak256(abi.encode("gas-matrix-loss", classId)));
        }
        vm.warp(block.timestamp + 65 days);
        _maintain();
        for (uint256 i; i < overdue.length; ++i) {
            if (registry.classParams(i + 1).model == ICollateralRegistry.CollateralModel.Receivable) {
                defaultManager.markPastDue(overdue[i]);
                assertGt(defaultManager.pastDuePrincipal(i + 1), 0, "class overdue branch absent");
            }
            assertGt(defaultManager.declaredDefaultedPrincipal(i + 1), 0, "class declared branch absent");
        }
        vm.warp(block.timestamp + 3 days);
        _maintain();
    }

}

abstract contract ImpairmentBudgetScenarios is ImpairmentBudgetFixture {
    function _variants() private {
        _assertImpairmentReadable(address(defaultManager), "base / all configured classes");
        _assertImpairmentReadable(address(assessedImpairmentSource), "no assessment");
        uint256 conservative = defaultManager.pendingSeniorImpairment();
        vm.prank(admin);
        assessedImpairmentSource.setAssessment(
            conservative / 2,
            uint64(block.timestamp + 7 days), keccak256("gas-matrix-memorandum")
        );
        _assertImpairmentReadable(address(assessedImpairmentSource), "active exact assessment");
        _coverage(100e18);
        _assertImpairmentReadable(address(assessedImpairmentSource), "capacity top-up");
        vm.warp(block.timestamp + 1);
        _maintain();
        _assertImpairmentReadable(address(assessedImpairmentSource), "elapsed cohort / compatibility path");
        vm.warp(block.timestamp + 8 days);
        _maintain();
        _assertImpairmentReadable(address(assessedImpairmentSource), "expired assessment / ramp still active");
        vm.warp(block.timestamp + 30 days);
        _maintain();
        _assertImpairmentReadable(address(assessedImpairmentSource), "expired assessment / full ramp");
    }

    function test_emptyBookAndInsufficientOuterGas() public {
        _assertImpairmentReadable(address(defaultManager), "empty base");
        _assertImpairmentReadable(address(assessedImpairmentSource), "empty wrapper");
        vm.expectPartialRevert(IsUSDfr.SUSDfr_InsufficientImpairmentRecoveryGas.selector);
        this.checkRecoveryRead{gas: 540_000}(address(assessedImpairmentSource));
    }

    function test_exhaustedJuniorPools() public { _book(0); _variants(); }
    function test_partialJuniorPools() public { _book(1); _variants(); }
    function test_fullJuniorPools() public { _book(2); _variants(); }
}

contract LegacyImpairmentBudgetTest is ImpairmentBudgetScenarios {
    function _recognitionMode() internal pure override returns (uint8) { return 0; }
}

contract BoundImpairmentBudgetTest is ImpairmentBudgetScenarios {
    function _recognitionMode() internal pure override returns (uint8) { return 1; }
}

contract NativeImpairmentBudgetTest is ImpairmentBudgetScenarios {
    function _recognitionMode() internal pure override returns (uint8) { return 2; }
}

contract LegacyNoBackstopImpairmentBudgetTest is LegacyImpairmentBudgetTest {
    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        defaultManager.setBackstop(address(0));
    }

    function _coverage(uint256) internal pure override {}
}
