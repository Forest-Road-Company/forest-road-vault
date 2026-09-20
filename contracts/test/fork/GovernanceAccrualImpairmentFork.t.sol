// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkLifecycleFixture} from "./ForkLifecycleFixture.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {ContinuousAccrualDeployment} from "../../script/ContinuousAccrualDeployment.sol";
import {IContinuousAccrual} from "../../src/interfaces/IContinuousAccrual.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {Config} from "../../src/libraries/Config.sol";

contract GovernanceAccrualImpairmentForkTest is ForkLifecycleFixture {
    function test_forkCashMarkIncludesUnreceivedIncome() public onFork {
        _check(false);
    }

    function test_forkPikMarkIncludesUnreceivedIncome() public onFork {
        _check(true);
    }

    function _check(bool pik) private {
        ContinuousAccrualDeployment.validate(
            address(reserves),
            IContinuousAccrual.Modules({
                token: address(usdfr),
                controller: address(controller),
                vault: address(vault),
                waterfall: address(waterfall),
                bridge: address(bridge),
                registry: address(registry),
                defaultManager: address(defaultManager)
            })
        );
        _mintFromUSDC(alice, 1_000_000e6);
        _mintFromUSDC(ops, 10_000e6);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, ops, true);
        usdfr.approve(address(curator), 10_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 10_000e18);
        ClaimBridge.OriginationTerms memory terms = _forkTerms(
            keccak256("valuation borrower"),
            keccak256("US-GA"),
            50_000e18,
            7500,
            uint64(block.timestamp + 365 days),
            keccak256("valuation facility")
        );
        terms.pik = pik;
        uint256 id = bridge.totalOriginated() + 1;
        bytes32 termsHash = bridge.creditTermsHash(terms);
        _attest(id, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(id, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        assertEq(bridge.originate(ops, terms), id);
        waterfall.fund(id, 50_000e6);
        vm.warp(block.timestamp + 15 days);
        (, bool fresh) = reserves.checkpointAccrual(32);
        assertTrue(fresh);
        uint256 earned = reserves.accrualSnapshot().unposted;
        uint256 face = reserves.deployedTo(id);
        assertGt(earned, 0);
        assertEq(face, 50_000e18 + earned);
        uint256 backing = controller.backingValue();
        uint256 supply = controller.totalUSDfr();
        uint256 cash = IERC20(USDC).balanceOf(address(reserves));
        reserves.recognizePrincipalImpairment(id, face, keccak256("full receivable valuation"));
        assertEq(reserves.principalImpairmentOf(id), face);
        assertEq(reserves.accrualSnapshot().unposted, 0);
        assertEq(controller.backingValue(), backing - face);
        assertEq(controller.totalUSDfr(), supply);
        assertEq(IERC20(USDC).balanceOf(address(reserves)), cash);
    }
}
