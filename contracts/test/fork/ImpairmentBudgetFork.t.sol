// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ImpairmentReadChecks} from "../helpers/ImpairmentReadChecks.sol";
import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {Config} from "../../src/libraries/Config.sol";

contract ImpairmentBudgetForkTest is ForkLifecycleFixture, ImpairmentReadChecks {
    function test_accruingAssessmentFitsTheProbeOnFork() public onFork {
        _mintFromUSDC(alice, 1_000_000e6);
        _stake(alice, 1_000_000e18);
        _mintFromUSDC(ops, 10_000e6);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, ops, true);
        usdfr.approve(address(curator), 10_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 10_000e18);
        uint256 id = _originateAndFund(400_000e18);
        vm.warp(block.timestamp + 65 days);
        (, bool fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh);
        reserves.serviceAccruedLoan(id);
        defaultManager.markPastDue(id);
        AssessedImpairmentSource source = AssessedImpairmentSource(vault.impairmentSource());
        uint256 base = defaultManager.pendingSeniorImpairment();
        source.setAssessment(base / 2, uint64(block.timestamp + 7 days), keccak256("fork-read-budget"));
        _assertImpairmentReadable(address(source), "fork / exact assessment");
        vm.warp(block.timestamp + 1);
        _assertImpairmentReadable(address(source), "fork / growing cohort");
        vm.warp(block.timestamp + 8 days);
        _assertImpairmentReadable(address(source), "fork / expired assessment");
    }
}
