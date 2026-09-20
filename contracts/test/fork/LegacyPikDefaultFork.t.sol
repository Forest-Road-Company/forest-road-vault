// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";
import {DefaultAccrualLib} from "../../src/libraries/DefaultAccrualLib.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @notice Legacy default preparation against pinned reserve tokens and the real signature quorum.
contract LegacyPikDefaultForkTest is ForkLifecycleFixture {
    uint256 private constant P = 1_000_000e18;
    uint256 private constant GRID = 1e12;
    bytes32 private constant EVIDENCE = keccak256("legacy-pik-default-evidence");

    function _wireContinuousAccrual(D memory) internal override {}

    function _open(uint64 interval) private returns (uint256 id, uint64 due) {
        _mintFromUSDC(alice, 4_000_000e6);
        _stake(alice, 2_000_000e18);
        uint64 start = uint64(block.timestamp);
        ClaimBridge.OriginationTerms memory t = _forkTermsFor(
            Config.CLASS_FILM_TAX_CREDITS,
            keccak256("legacy-default-borrower"),
            keccak256("US-GA"),
            P,
            7500,
            1400,
            start + 360 days,
            keccak256("legacy-default-note")
        );
        t.pik = true;
        t.paymentInterval = interval;
        t.nextPaymentDue = start + interval;
        id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(t);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        assertEq(bridge.originate(ops, t), id);
        waterfall.fund(id, 1_000_000e6);
        due = t.nextPaymentDue;
        assertFalse(reserves.accrualSnapshot().enabled, "fixture must exercise legacy mode");
    }

    function _model(uint256 periods, uint64 interval) private pure returns (uint256 face) {
        face = P;
        for (uint256 i; i < periods; ++i) {
            face += face * 1400 * interval / (10_000 * 360 days) / GRID * GRID;
        }
    }

    function _defaultEvidence(uint256 id) private {
        _attest(id, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(id, EVIDENCE)));
    }

    function test_fork_quarterlyCouponsRecordedBeforeDefaultAndRecovery() public onFork {
        (uint256 id,) = _open(90 days);
        _warp(180 days);
        uint256 supply = usdfr.totalSupply();
        uint256 backing = reserves.totalBackingValue();
        uint256 expected = _model(2, 90 days);
        _declareDefault(id, EVIDENCE);
        assertEq(reserves.deployedTo(id), expected);
        assertEq(defaultManager.defaultedContribution(id), expected);
        assertEq(registry.classExposure(Config.CLASS_FILM_TAX_CREDITS), expected);
        assertEq(usdfr.totalSupply() - supply, expected - P);
        assertEq(reserves.totalBackingValue() - backing, expected - P);
        _warp(90 days);
        assertEq(reserves.deployedTo(id), expected, "default restarted interest");
        _repay(id, 0, expected);
        assertEq(reserves.deployedTo(id), 0);
        assertEq(defaultManager.defaultedContribution(id), 0);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Resolved));
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue());
    }

    function test_fork_pausedPostingRefusesAndThenResumes() public onFork {
        (uint256 id,) = _open(90 days);
        _warp(90 days);
        _defaultEvidence(id);
        waterfall.pause();
        uint256 supply = usdfr.totalSupply();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        defaultManager.declareDefault(id, EVIDENCE);
        assertEq(usdfr.totalSupply(), supply);
        assertEq(reserves.deployedTo(id), P);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
        waterfall.unpause();
        defaultManager.declareDefault(id, EVIDENCE);
        assertEq(defaultManager.defaultedContribution(id), _model(1, 90 days));
    }

    function test_fork_pastDueRiskSurvivesPreparationWithoutCure() public onFork {
        (uint256 id, uint64 due) = _open(90 days);
        waterfall.pause();
        _warp(uint256(due) + 2 * defaultManager.graceWindow(Config.CLASS_FILM_TAX_CREDITS) + 1 - block.timestamp);
        defaultManager.markPastDue(id);
        assertEq(defaultManager.pastDueContribution(id), P);
        uint256 anchor = defaultManager.pastDueReliefAnchor();
        waterfall.unpause();
        _defaultEvidence(id);
        (uint256 processed, uint64 remaining) = defaultManager.settleLegacyPikForDefault(id, EVIDENCE, 1);
        assertEq(processed, 1);
        assertEq(remaining, 0);
        uint256 expected = _model(1, 90 days);
        assertEq(defaultManager.pastDueContribution(id), expected);
        assertEq(defaultManager.pastDueExposure(), expected);
        assertEq(defaultManager.pastDueReliefAnchor(), anchor);
        assertEq(uint256(bridge.facility(id).state), uint256(ClaimBridge.LoanState.Active));
        defaultManager.declareDefault(id, EVIDENCE);
        assertEq(defaultManager.defaultedContribution(id), expected);
        assertEq(defaultManager.pastDueExposure(), 0);
    }

    function test_fork_longBacklogRequiresSuccessfulBoundedPreparation() public onFork {
        queue.pause();
        assertTrue(queue.paused());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.closeEpoch(1);
        (uint256 id, uint64 due) = _open(7 days);
        _warp(280 days);
        _defaultEvidence(id);
        vm.expectRevert(
            abi.encodeWithSelector(DefaultAccrualLib.DefaultAccrual_LegacyPikPending.selector, id, due + 16 * 7 days)
        );
        defaultManager.declareDefault(id, EVIDENCE);
        assertEq(reserves.deployedTo(id), P, "failed declaration retained a partial posting");
        (uint256 processed, uint64 remaining) = defaultManager.settleLegacyPikForDefault(id, EVIDENCE, 16);
        assertEq(processed, 16);
        assertEq(remaining, due + 16 * 7 days);
        assertEq(reserves.deployedTo(id), _model(16, 7 days));
        (processed, remaining) = defaultManager.settleLegacyPikForDefault(id, EVIDENCE, 16);
        assertEq(processed, 16);
        assertEq(remaining, due + 32 * 7 days);
        assertEq(reserves.deployedTo(id), _model(32, 7 days));
        defaultManager.declareDefault(id, EVIDENCE);
        assertEq(defaultManager.defaultedContribution(id), _model(40, 7 days));
        assertTrue(queue.paused(), "preparation or declaration resumed settlement");
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.closeEpoch(1);
        queue.unpause();
        assertFalse(queue.paused());
    }
}
