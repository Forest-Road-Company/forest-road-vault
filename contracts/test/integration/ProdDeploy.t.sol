// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {Config} from "../../src/libraries/Config.sol";

/// @dev PRODUCTION-SHAPED deploy regression test (audit R6). There was NO test that ran
///      the deploy with `opsAdmin != deployer` + `keepOpsAdmin=false`, which is why TWO
///      bootstrap-role bugs of the same class slipped through: R5-H1 (`_seed`'s
///      COMPLIANCE_ADMIN) and R6-H1 (`_wire`'s RESERVE_ADMIN). This test drives the real
///      internal sequence with the test contract acting as the deployer and asserts (a) the
///      whole path executes without reverting on the prod shape, and (b) the final role
///      topology is governance-clean. It fails loudly if any bootstrap call needs a role the
///      deployer lacks, or if any privileged role is left on an EOA.
///
///      Deploy's internal steps are broadcast-free and take `Ctx`, so we call them directly
///      with `address(this)` as the deployer (init grants DEFAULT_ADMIN to `c.deployer`, and
///      this contract is the caller, so the two coincide — the same coincidence the live
///      testnet deploy relied on via `opsAdmin==deployer`, but here ops is SEPARATE).
contract ProdDeployTest is Test, Deploy {
    address internal ops = makeAddr("prodOps");
    address internal proposalGuardian = makeAddr("prodProposalGuardian");
    address internal queueKeeper = makeAddr("prodQueueKeeper");
    address internal treasury = makeAddr("prodTreasury");
    address internal fees = makeAddr("prodFees");
    address internal attester2Addr = makeAddr("prodAttester2");

    function _prodCtx() internal view returns (Ctx memory c) {
        c.deployer = address(this); // the caller of the internal steps IS the deployer
        c.opsAdmin = ops;
        c.proposalGuardian = proposalGuardian;
        c.queueKeeper = queueKeeper;
        c.frTreasury = treasury;
        c.feeRecipient = fees;
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = false; // PROD: timelock is sole admin
    }

    /// @notice The prod-shaped deploy must run end-to-end without reverting. Before the R6
    ///         fix this reverted in `_wire` at `setStableApproved` (RESERVE_ADMIN); before
    ///         R5 it reverted in `_seed` at `setAllowed` (COMPLIANCE_ADMIN).
    function test_prodShapedDeploy_runsEndToEnd() public {
        Ctx memory c = _prodCtx();
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        this.exposedHandover(d, c);

        // seed landed at the permanently-locked sink
        assertGt(SUSDfr(d.vault).balanceOf(SEED_SINK), 0, "seed at sink");
        assertEq(SUSDfr(d.vault).totalSupply(), SUSDfr(d.vault).balanceOf(SEED_SINK), "only the seed exists");
        assertEq(GroveToken(d.grove).delegates(treasury), treasury, "treasury self-delegated at genesis");
        assertEq(
            GroveToken(d.grove).getVotes(treasury), Config.GROVE_INITIAL_SUPPLY, "full genesis voting power active"
        );
    }

    /// @notice Handover must fail before its first role change if governance voting power has
    ///         been cleared, even though the token initializer normally makes genesis live.
    function test_prodShapedDeploy_refusesGovernanceDeadHandoverAtomically() public {
        Ctx memory c = _prodCtx();
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);

        vm.prank(treasury);
        GroveToken(d.grove).delegate(address(0));

        uint256 requiredVotingPower = Config.GROVE_INITIAL_SUPPLY * Config.GOV_QUORUM_FRACTION / 100;
        vm.expectRevert(
            abi.encodeWithSelector(
                Deploy.DeployGovernanceDeadOnArrival.selector, d.grove, treasury, uint256(0), requiredVotingPower
            )
        );
        this.exposedHandover(d, c);

        assertTrue(IAccessControl(d.usdfr).hasRole(bytes32(0), address(this)), "deployer admin preserved");
        assertTrue(
            IAccessControl(d.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, address(this)), "reserve authority preserved"
        );

        vm.prank(treasury);
        GroveToken(d.grove).delegate(treasury);
        this.exposedHandover(d, c);
        assertFalse(IAccessControl(d.usdfr).hasRole(bytes32(0), address(this)), "handover succeeds once live");
    }

    function exposedHandover(D memory d, Ctx memory c) external {
        _handover(d, c);
    }

    /// @notice After a prod handover the timelock is sole DEFAULT_ADMIN/UPGRADER, RESERVE_ADMIN
    ///         is governance-held (audit R6 M-1), and the deployer holds no privileged EOA role
    ///         (except the documented ATTESTER testnet concession).
    function test_prodShapedDeploy_topologyIsGovernanceClean() public {
        Ctx memory c = _prodCtx();
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);

        address[14] memory mods = [
            d.compliance,
            d.usdfr,
            d.reserves,
            d.controller,
            d.vault,
            d.points,
            d.registry,
            d.oracle,
            d.bridge,
            d.curator,
            d.waterfall,
            d.defaultManager,
            d.queue,
            d.sGrove
        ];
        for (uint256 i = 0; i < mods.length; ++i) {
            assertTrue(IAccessControl(mods[i]).hasRole(bytes32(0), d.timelock), "timelock admin");
            assertFalse(IAccessControl(mods[i]).hasRole(bytes32(0), address(this)), "deployer NOT admin");
            assertFalse(IAccessControl(mods[i]).hasRole(bytes32(0), ops), "ops NOT admin (prod)");
            assertFalse(IAccessControl(mods[i]).hasRole(bytes32(0), queueKeeper), "keeper NOT admin (prod)");
            assertTrue(IAccessControl(mods[i]).hasRole(Roles.UPGRADER_ROLE, d.timelock), "timelock upgrader");
            assertFalse(IAccessControl(mods[i]).hasRole(Roles.UPGRADER_ROLE, address(this)), "deployer NOT upgrader");
            assertFalse(IAccessControl(mods[i]).hasRole(Roles.UPGRADER_ROLE, queueKeeper), "keeper NOT upgrader");
        }

        // MINTER only on the controller; deployer placeholder renounced.
        assertFalse(IAccessControl(d.usdfr).hasRole(Roles.MINTER_ROLE, address(this)), "deployer NOT minter");
        assertTrue(IAccessControl(d.usdfr).hasRole(Roles.MINTER_ROLE, d.controller), "controller mints");

        // RESERVE_ADMIN → governance, off both EOAs (audit R6 M-1).
        assertTrue(IAccessControl(d.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, d.timelock), "timelock reserve-admin");
        assertFalse(
            IAccessControl(d.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, address(this)), "deployer NOT reserve-admin"
        );
        assertFalse(IAccessControl(d.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, ops), "ops NOT reserve-admin (prod)");

        // COMPLIANCE_ADMIN: deployer's temporary self-grant renounced; ops retains it (operational).
        assertFalse(
            IAccessControl(d.compliance).hasRole(Roles.COMPLIANCE_ADMIN_ROLE, address(this)),
            "deployer NOT compliance-admin"
        );
        assertTrue(IAccessControl(d.compliance).hasRole(Roles.COMPLIANCE_ADMIN_ROLE, ops), "ops compliance-admin");
        assertFalse(ComplianceRegistry(d.compliance).isAllowed(address(this)), "deployer KYC revoked");

        // CREDIT never on an EOA anywhere.
        assertFalse(IAccessControl(d.reserves).hasRole(Roles.CREDIT_ROLE, ops), "ops NOT credit");
        assertFalse(IAccessControl(d.reserves).hasRole(Roles.CREDIT_ROLE, address(this)), "deployer NOT credit");

        // The production keeper is a second holder, distinct from the manual ops backstop,
        // and receives only the queue's operational settlement role.
        assertTrue(IAccessControl(d.queue).hasRole(Roles.SETTLEMENT_KEEPER_ROLE, queueKeeper), "dedicated keeper role");
        assertTrue(IAccessControl(d.queue).hasRole(Roles.SETTLEMENT_KEEPER_ROLE, ops), "ops keeper backstop");
        assertFalse(IAccessControl(d.queue).hasRole(Roles.GUARDIAN_ROLE, queueKeeper), "keeper NOT guardian");

        // Timelock wiring: deployer relinquished its bootstrap timelock admin.
        TimelockControllerUpgradeable tl = TimelockControllerUpgradeable(payable(d.timelock));
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(this)), "deployer NOT timelock admin");
    }

    /// @notice The TESTNET shape (opsAdmin == deployer, keepOpsAdmin=true) — what actually
    ///         deploys to Sepolia — also runs end-to-end, and here the timelock is admin
    ///         alongside the retained ops EOA (the documented testnet convenience). Guards
    ///         against a future change breaking the shape the live deploy uses.
    /// @notice RAMP POSTURE (Forest Road, 2026-07-21): the deploy seeds EVERY concentration
    ///         dimension wide open, so idle deposit capital can be deployed into originations
    ///         before the book has any diversity to measure.
    /// @dev Asserts the posture is real, not merely that the numbers match a pinned tuple: a
    ///      single facility taking 100% of the book must be ADMITTED on all three dimensions.
    ///      This is the check that would catch a future edit quietly re-tightening a limit.
    function test_rampPosture_everyConcentrationDimensionIsOpen() public {
        Ctx memory c;
        c.deployer = address(this);
        c.opsAdmin = address(this);
        c.proposalGuardian = proposalGuardian;
        c.queueKeeper = address(this); // retained testnet holder and ops backstop are the same key
        c.frTreasury = address(this);
        c.feeRecipient = address(this);
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true;
        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        CollateralRegistry reg = CollateralRegistry(d.registry);

        (uint16 borrowerBps, uint16 stateBps,) = reg.limits();
        assertEq(borrowerBps, Config.RAMP_CONCENTRATION_LIMIT_BPS, "borrower dimension open");
        assertEq(stateBps, Config.RAMP_CONCENTRATION_LIMIT_BPS, "state dimension open");
        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            assertEq(
                reg.classParams(classId).concentrationLimitBps,
                Config.RAMP_CONCENTRATION_LIMIT_BPS,
                "class dimension open"
            );
        }

        // The property that matters: an origination equal to the WHOLE book is admissible on
        // every dimension at once, including the related-party digital-assets class.
        reg.checkConcentration(Config.CLASS_DIGITAL_ASSETS, keccak256("da-sub"), bytes32(0), 500_000_000e18);
        // ...and headroom agrees (it is the exact inverse of the admission rule).
        assertGt(
            reg.concentrationHeadroom(Config.CLASS_DIGITAL_ASSETS, keccak256("da-sub"), bytes32(0)),
            500_000_000e18,
            "headroom is unbounded while the posture is open"
        );
    }

    /// @notice AUDIT FIX (M-6) REGRESSION. The production-shaped REHEARSAL that the runbook
    ///         actually prescribes is `KEEP_OPS_ADMIN=false` with `OPS_ADMIN` left UNSET — and
    ///         `Deploy.run()` defaults `opsAdmin` to the deployer. In that shape
    ///         `initialize`'s COMPLIANCE_ADMIN grant to `opsAdmin` and `_seed`'s temporary
    ///         self-grant to `deployer` are one and the same grant, so `_handover`'s
    ///         unconditional renounce left the ComplianceRegistry with ZERO COMPLIANCE_ADMIN
    ///         holders: `setAllowed` unreachable, so no address could ever be KYC'd and the
    ///         stack could not mint, stake or redeem. Nothing detected it — `Validate` printed
    ///         PASSED. This asserts the capability, not the code path: KYC must still WORK.
    function test_prodShapedDeploy_opsEqualsDeployer_leavesComplianceRegistryAlive() public {
        Ctx memory c;
        c.deployer = address(this);
        c.opsAdmin = address(this);
        c.proposalGuardian = proposalGuardian;
        c.queueKeeper = address(this); // OPS_ADMIN unset: keeper and ops intentionally coincide
        c.frTreasury = address(this);
        c.feeRecipient = address(this);
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = false; // PRODUCTION-SHAPED rehearsal

        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);

        ComplianceRegistry cr = ComplianceRegistry(d.compliance);
        assertTrue(
            IAccessControl(d.compliance).hasRole(Roles.COMPLIANCE_ADMIN_ROLE, c.opsAdmin),
            "a COMPLIANCE_ADMIN holder must survive the handover (M-6)"
        );
        // The capability itself: someone can still be KYC'd on the live registry.
        address newUser = makeAddr("postHandoverUser");
        cr.setAllowed(newUser, true);
        assertTrue(cr.isAllowed(newUser), "KYC must still be grantable after handover (M-6)");
        // ...and the deployer's own bootstrap KYC is still revoked (DS-6 unchanged).
        assertFalse(cr.isAllowed(c.deployer), "deployer bootstrap KYC revoked");
    }

    function test_testnetShapedDeploy_runsAndKeepsOpsAdmin() public {
        Ctx memory c;
        c.deployer = address(this);
        c.opsAdmin = address(this);
        c.proposalGuardian = proposalGuardian;
        c.queueKeeper = address(this); // testnet: keeper == ops == deployer
        c.frTreasury = address(this);
        c.feeRecipient = address(this);
        c.attester2 = attester2Addr;
        c.keepOpsAdmin = true; // TESTNET: ops retains DEFAULT_ADMIN

        D memory d = _deployAll(c);
        _wire(d, c);
        _seed(d, c);
        _handover(d, c);

        assertGt(SUSDfr(d.vault).balanceOf(SEED_SINK), 0, "seed at sink");
        // audit R7: genesis GROVE votes are active — the treasury (=deployer here)
        // self-delegated in _seed, so governance can reach quorum without a manual step.
        assertGt(GroveToken(d.grove).getVotes(address(this)), 0, "genesis GROVE votes active");
        assertTrue(IAccessControl(d.reserves).hasRole(bytes32(0), d.timelock), "timelock admin");
        assertTrue(IAccessControl(d.reserves).hasRole(bytes32(0), address(this)), "ops retains admin (testnet)");
        // RESERVE_ADMIN went to the timelock either way (audit R6 M-1)
        assertTrue(IAccessControl(d.reserves).hasRole(Roles.RESERVE_ADMIN_ROLE, d.timelock), "timelock reserve-admin");
        // and the value-critical negatives still hold: no EOA mints or credits
        assertFalse(IAccessControl(d.usdfr).hasRole(Roles.MINTER_ROLE, address(this)), "deployer NOT minter");
        assertFalse(IAccessControl(d.reserves).hasRole(Roles.CREDIT_ROLE, address(this)), "deployer NOT credit");
    }
}
