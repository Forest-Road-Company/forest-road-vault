// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {FRGovernor} from "../../src/FRGovernor.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {GroveVotesAggregator} from "../../src/GroveVotesAggregator.sol";
import {SGrove} from "../../src/SGrove.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {CreditLayerFixture} from "./CreditLayerFixture.sol";

/// @dev Phase H on top of the full stack: GROVE (genesis supply to the Forest Road
///      treasury per ADR-0013), the REAL SGrove backstop replacing the Phase E mock as
///      cascade layer 2, and the Governor + Timelock machinery. The timelock receives
///      DEFAULT_ADMIN on the WaterfallEngine so governance flows are exercised against
///      a real protocol parameter, exactly as the deploy script will wire everything.
abstract contract GovernanceFixture is CreditLayerFixture {
    address internal frTreasury = makeAddr("forestRoadTreasury");

    GroveToken internal grove;
    SGrove internal sGrove;
    GroveVotesAggregator internal votesAggregator;
    TimelockControllerUpgradeable internal timelock;
    FRGovernor internal governor;

    function setUp() public virtual override {
        super.setUp();

        grove = GroveToken(
            address(
                new ERC1967Proxy(
                    address(new GroveToken()), abi.encodeCall(GroveToken.initialize, (admin, admin, frTreasury))
                )
            )
        );
        sGrove = SGrove(
            address(
                new ERC1967Proxy(
                    address(new SGrove()),
                    abi.encodeCall(
                        SGrove.initialize, (admin, guardian, admin, address(grove), address(usdfr), address(vault))
                    )
                )
            )
        );

        // timelock: this fixture is temp admin to wire roles, then renounces
        address[] memory empty = new address[](0);
        timelock = TimelockControllerUpgradeable(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new TimelockControllerUpgradeable()),
                        abi.encodeCall(
                            TimelockControllerUpgradeable.initialize,
                            (Config.TIMELOCK_MIN_DELAY, empty, empty, address(this))
                        )
                    )
                )
            )
        );
        // ADR-0026 (L-02): the Governor's vote source is the AGGREGATOR, never GROVE
        // directly — staked GROVE keeps voting. The aggregator must exist before the
        // Governor, whose token is fixed at `initialize` with no setter.
        votesAggregator = new GroveVotesAggregator(address(grove), address(sGrove));
        governor = FRGovernor(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new FRGovernor()),
                        abi.encodeCall(FRGovernor.initialize, (IVotes(address(votesAggregator)), timelock))
                    )
                )
            )
        );
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // open executor (standard)
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)); // no leftover privileges

        // the REAL backstop replaces the Phase E mock as cascade layer 2
        vm.startPrank(admin);
        sGrove.grantRole(Roles.CREDIT_ROLE, address(defaultManager));
        vault.grantRole(Roles.FEE_ACCOUNTING_ROLE, address(sGrove));
        defaultManager.setBackstop(address(sGrove));
        // governance-executed parameter changes need the timelock as module admin
        waterfall.grantRole(bytes32(0), address(timelock));
        vm.stopPrank();

        // GroveToken self-delegates the treasury during initialization. Advance one tick so
        // that genesis checkpoint is visible at Governor proposal snapshots (clock - 1).
        vm.warp(block.timestamp + 1);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Gives `who` GROVE from the treasury and stakes it into the backstop.
    function _stakeGrove(address who, uint256 amount) internal {
        vm.prank(frTreasury);
        grove.transfer(who, amount);
        vm.startPrank(who);
        grove.approve(address(sGrove), amount);
        sGrove.stake(amount);
        vm.stopPrank();
    }

    /// @dev Funds the backstop's USDfr coverage reserve (via bob's minted USDfr).
    function _fundCoverage(uint256 amount) internal {
        _mintUSDfrTo(bob, amount);
        vm.startPrank(bob);
        usdfr.approve(address(sGrove), amount);
        sGrove.fundCoverage(amount);
        vm.stopPrank();
    }
}
