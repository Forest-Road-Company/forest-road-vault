// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import {GroveToken} from "../../src/GroveToken.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @dev A UUPS-compatible successor used only to prove that upgrade AUTHORITY is what gates
///      `upgradeToAndCall`. It adds an observable marker and re-declares GroveToken's storage
///      by inheritance, so the layout is unchanged.
contract GroveTokenV2Mock is GroveToken {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Deliberately NOT UUPS (no `proxiableUUID`). Proves ERC-1967's implementation check
///      fires — i.e. that a successful upgrade is not merely "any address sticks".
contract NotUUPS {
    uint256 public x;
}

/// @title GroveToken (GROVE) — dedicated unit suite
/// @notice CLAUDE.md §5 bar for the governance token (ADR-0013): every function, every branch,
///         every revert path asserted on its SPECIFIC custom error, every access-control
///         modifier exercised with BOTH an authorized and an unauthorized caller, and every
///         event asserted on topics AND data.
///
/// @dev FIXTURE NOTE — read before trusting any assertion below.
///      GroveToken has ZERO external dependencies: no oracle, no registry, no compliance
///      module, no collateral. There is therefore NO mock in this suite whose constraint could
///      be looser than production's. The only collaborators are the real `ERC1967Proxy` and the
///      real `TimelockControllerUpgradeable` that `script/Deploy.s.sol` itself deploys.
///
///      Where this fixture differs from production it is STRICTLY TIGHTER. Production wires
///      `initialize(timelock, timelock, frTreasury)` (script/Deploy.s.sol:349), collapsing
///      `admin` and `upgrader` onto one address, so production CANNOT distinguish an
///      `_authorizeUpgrade` gated on DEFAULT_ADMIN_ROLE from one gated on UPGRADER_ROLE. This
///      fixture gives the two roles DISTINCT holders so that confusion is detectable, and then
///      re-proves the real production wiring against a real timelock in
///      `test_upgrade_productionWiring_onlyTheTimelockCanUpgradeAndOnlyAfterTheDelay`.
contract GroveTokenTest is Test {
    // ── the three initialize parameters, held by three DISTINCT addresses ──
    address internal admin = makeAddr("groveAdminTimelock"); // DEFAULT_ADMIN_ROLE
    address internal upgrader = makeAddr("groveUpgraderTimelock"); // UPGRADER_ROLE
    address internal treasury = makeAddr("forestRoadTreasury"); // genesis supply holder

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    GroveToken internal impl;
    GroveToken internal spareImpl; // for negative-path proxy deployments
    GroveToken internal grove;

    uint256 internal constant SUPPLY = Config.GROVE_INITIAL_SUPPLY;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @dev Initializable's ERC-7201 namespace slot; `_disableInitializers` writes uint64 max here.
    bytes32 internal constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function setUp() public virtual {
        vm.warp(1_800_000_000); // a realistic wall clock; the token is timestamp-checkpointed
        vm.roll(21_000_000);
        impl = new GroveToken();
        spareImpl = new GroveToken();
        grove = GroveToken(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(GroveToken.initialize, (admin, upgrader, treasury))))
        );
        // step off the genesis tick so past-vote lookups have somewhere to point
        vm.warp(block.timestamp + 1);
    }

    // ═════════════════════════════════════════════════════════════════════
    // initialize — parameters, ordering, and the full event trace
    // ═════════════════════════════════════════════════════════════════════

    function test_initialize_setsMetadataFromConfig() public view {
        assertEq(grove.name(), Config.GROVE_NAME, "name is Config-driven");
        assertEq(grove.symbol(), Config.GROVE_SYMBOL, "symbol is Config-driven");
        assertEq(grove.name(), "Forest Road Grove");
        assertEq(grove.symbol(), "GROVE");
        assertEq(grove.decimals(), 18, "GROVE is 18dp");
    }

    function test_initialize_mintsTheEntireFixedSupplyToTheTreasuryAndNobodyElse() public view {
        assertEq(grove.totalSupply(), SUPPLY, "ADR-0013 fixed supply");
        assertEq(SUPPLY, 1_000_000_000e18, "the fixed supply is one billion GROVE");
        assertEq(grove.balanceOf(treasury), SUPPLY, "the treasury holds all of it at genesis");
        assertEq(grove.balanceOf(admin), 0, "the governance admin holds none");
        assertEq(grove.balanceOf(upgrader), 0, "the upgrade authority holds none");
        assertEq(grove.balanceOf(address(this)), 0, "the deployer holds none");
        assertEq(grove.balanceOf(address(grove)), 0, "the token holds none of itself");
    }

    function test_initialize_selfDelegatesTheTreasurySoGenesisSupplyIsGovernanceLive() public view {
        assertEq(grove.delegates(treasury), treasury, "treasury self-delegated during initialize");
        assertEq(grove.getVotes(treasury), SUPPLY, "the full genesis balance carries voting power");
        // The comparison that makes this meaningful: an undelegated ERC20Votes balance has NO
        // voting power. Drop the `_delegate` line and getVotes(treasury) is 0 while
        // balanceOf(treasury) stays at SUPPLY — a governance-dead deployment (AUDIT L-04).
        assertEq(grove.getVotes(admin), 0, "an address that never delegated has zero votes");
        assertEq(grove.delegates(admin), address(0), "and no delegate recorded");
    }

    function test_initialize_grantsExactlyTheTwoIntendedRolesAndNoOthers() public view {
        assertTrue(grove.hasRole(grove.DEFAULT_ADMIN_ROLE(), admin), "admin holds DEFAULT_ADMIN_ROLE");
        assertTrue(grove.hasRole(Roles.UPGRADER_ROLE, upgrader), "upgrader holds UPGRADER_ROLE");

        assertFalse(grove.hasRole(grove.DEFAULT_ADMIN_ROLE(), upgrader), "upgrader is not admin");
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, admin), "admin is not upgrader");
        assertFalse(grove.hasRole(grove.DEFAULT_ADMIN_ROLE(), treasury), "treasury holds no admin role");
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, treasury), "treasury holds no upgrade role");
        assertFalse(grove.hasRole(grove.DEFAULT_ADMIN_ROLE(), address(this)), "no leftover deployer privilege");
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, address(this)), "no leftover deployer privilege");
        assertEq(grove.DEFAULT_ADMIN_ROLE(), bytes32(0), "OZ DEFAULT_ADMIN_ROLE is 0x00");
    }

    /// @dev Every event `initialize` emits, in order, with all topics and all data checked.
    function test_initialize_emitsTheFullGenesisEventTraceInOrder() public {
        // ERC1967Proxy's constructor delegatecalls initialize, so `_msgSender()` inside the
        // role grants is this test contract (the deployer), not the proxy.
        address expectedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(true, true, true, true, expectedProxy);
        emit IAccessControl.RoleGranted(bytes32(0), admin, address(this));
        vm.expectEmit(true, true, true, true, expectedProxy);
        emit IAccessControl.RoleGranted(Roles.UPGRADER_ROLE, upgrader, address(this));
        vm.expectEmit(true, true, true, true, expectedProxy);
        emit IERC20.Transfer(address(0), treasury, SUPPLY);
        vm.expectEmit(true, true, true, true, expectedProxy);
        emit IVotes.DelegateChanged(treasury, address(0), treasury);
        vm.expectEmit(true, true, true, true, expectedProxy);
        emit IVotes.DelegateVotesChanged(treasury, 0, SUPPLY);
        vm.expectEmit(true, true, true, true, expectedProxy);
        emit Initializable.Initialized(1);

        address deployed = address(
            new ERC1967Proxy(address(spareImpl), abi.encodeCall(GroveToken.initialize, (admin, upgrader, treasury)))
        );
        assertEq(deployed, expectedProxy, "CREATE address prediction held, so the emitter filter was real");
    }

    // ── the zero-address branch, one clause at a time ────────────────────
    // `initialize` guards three parameters in ONE `||` expression, which `forge coverage`
    // collapses into a single branch (BRF:1). 100% branch coverage there is therefore
    // compatible with two of the three clauses never executing. These cover them directly.

    function test_initialize_revertsOnZeroAdmin() public {
        vm.expectRevert(GroveToken.Grove_ZeroAddress.selector);
        new ERC1967Proxy(address(spareImpl), abi.encodeCall(GroveToken.initialize, (address(0), upgrader, treasury)));
    }

    function test_initialize_revertsOnZeroUpgrader() public {
        vm.expectRevert(GroveToken.Grove_ZeroAddress.selector);
        new ERC1967Proxy(address(spareImpl), abi.encodeCall(GroveToken.initialize, (admin, address(0), treasury)));
    }

    function test_initialize_revertsOnZeroTreasury() public {
        vm.expectRevert(GroveToken.Grove_ZeroAddress.selector);
        new ERC1967Proxy(address(spareImpl), abi.encodeCall(GroveToken.initialize, (admin, upgrader, address(0))));
    }

    /// @dev The positive complement of the three above: with all three non-zero it must NOT
    ///      revert. Without this, a guard that reverted unconditionally would still pass them.
    function testFuzz_initialize_revertsIffAnyParameterIsZero(address a, address u, address t) public {
        if (a == address(0) || u == address(0) || t == address(0)) {
            vm.expectRevert(GroveToken.Grove_ZeroAddress.selector);
            new ERC1967Proxy(address(spareImpl), abi.encodeCall(GroveToken.initialize, (a, u, t)));
        } else {
            GroveToken g = GroveToken(
                address(new ERC1967Proxy(address(spareImpl), abi.encodeCall(GroveToken.initialize, (a, u, t))))
            );
            assertEq(g.balanceOf(t), SUPPLY, "non-zero parameters must initialize cleanly");
            assertEq(g.delegates(t), t, "and still self-delegate");
            assertTrue(g.hasRole(bytes32(0), a));
            assertTrue(g.hasRole(Roles.UPGRADER_ROLE, u));
        }
    }

    function test_initialize_cannotRunTwiceOnTheProxy() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        grove.initialize(alice, alice, alice);
        assertEq(grove.balanceOf(treasury), SUPPLY, "the original wiring is untouched");
        assertFalse(grove.hasRole(bytes32(0), alice));
    }

    /// @dev The naked implementation must not be initializable by a passer-by. An initialized
    ///      UUPS implementation is directly seizable — the deployment-hygiene class that
    ///      finding A-01 records against the timelock implementation.
    function test_initialize_implementationIsDisabledByTheConstructor() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(alice);
        impl.initialize(alice, alice, alice);

        assertEq(impl.totalSupply(), 0, "the implementation never held supply");
        assertFalse(impl.hasRole(bytes32(0), alice), "and grants nobody admin");
        assertFalse(impl.hasRole(Roles.UPGRADER_ROLE, alice));
        assertEq(
            uint256(vm.load(address(impl), INITIALIZABLE_STORAGE)),
            uint256(type(uint64).max),
            "INITIALIZABLE_STORAGE holds the disabled sentinel"
        );
        // and the live proxy is NOT disabled that way — it is merely already at version 1
        assertEq(uint256(vm.load(address(grove), INITIALIZABLE_STORAGE)), 1, "the proxy is at initialized version 1");
    }

    // ═════════════════════════════════════════════════════════════════════
    // FIXED SUPPLY — there is no mint path and no burn path (ADR-0013)
    // ═════════════════════════════════════════════════════════════════════

    /// @dev The contract comment claims "fixed supply — no mint path exists". This asserts that
    ///      against the DEPLOYED BYTECODE rather than the source comment: each call must fail
    ///      with EMPTY returndata, which is what an unmatched selector produces. A role-gated
    ///      mint would revert WITH data (AccessControlUnauthorizedAccount), so this
    ///      distinguishes "no such function" from "function exists but is guarded".
    /// @dev ADVERSARY FINDING (2026-08-10): the behavioural sweep below is an ALLOWLIST of six
    ///      hand-chosen names, not the bytecode proof its old name claimed. A mutant adding
    ///      `function issue(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE)
    ///      { _mint(to, amount); }` kept the whole suite GREEN, because `issue` is not one of the
    ///      six. The sweep is retained — it is load-bearing, and both of its assertion arms are
    ///      mutation-killed — but the fixed-supply CLAIM is now backed by the test below, which
    ///      pins the COMPLETE external surface from the compiled artifact so that ANY added
    ///      entrypoint reds regardless of what it is called. `foundry.toml` already grants read
    ///      access to `./out` for exactly this class of check.
    function test_fixedSupply_theCompleteExternalSurfaceIsPinned() public view {
        string[34] memory expected = [
            "CLOCK_MODE()",
            "DEFAULT_ADMIN_ROLE()",
            "DOMAIN_SEPARATOR()",
            "UPGRADE_INTERFACE_VERSION()",
            "allowance(address,address)",
            "approve(address,uint256)",
            "balanceOf(address)",
            "checkpoints(address,uint32)",
            "clock()",
            "decimals()",
            "delegate(address)",
            "delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)",
            "delegates(address)",
            "eip712Domain()",
            "getPastTotalSupply(uint256)",
            "getPastVotes(address,uint256)",
            "getRoleAdmin(bytes32)",
            "getVotes(address)",
            "grantRole(bytes32,address)",
            "hasRole(bytes32,address)",
            "initialize(address,address,address)",
            "name()",
            "nonces(address)",
            "numCheckpoints(address)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "proxiableUUID()",
            "renounceRole(bytes32,address)",
            "revokeRole(bytes32,address)",
            "supportsInterface(bytes4)",
            "symbol()",
            "totalSupply()",
            "transfer(address,uint256)",
            "transferFrom(address,address,uint256)",
            "upgradeToAndCall(address,bytes)"
        ];

        string[] memory actual =
            vm.parseJsonKeys(vm.readFile("out/GroveToken.sol/GroveToken.json"), ".methodIdentifiers");

        assertEq(
            actual.length,
            expected.length,
            "GroveToken's external surface changed. A NEW entrypoint is a fixed-supply risk until "
            "proven otherwise: confirm it cannot mint, burn or re-authorise, then pin it here."
        );

        // Order-independent set equality: every compiled selector must be one we have vetted.
        for (uint256 i = 0; i < actual.length; ++i) {
            bool found;
            for (uint256 j = 0; j < expected.length; ++j) {
                if (keccak256(bytes(actual[i])) == keccak256(bytes(expected[j]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat("unvetted external entrypoint on GroveToken: ", actual[i]));
        }
    }

    function test_fixedSupply_noMintOrBurnSelectorExistsOnTheDeployedToken() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "setMinter(address)"
        ];
        // try as the MOST privileged caller in the system — if any authority could mint, admin can
        for (uint256 i = 0; i < sigs.length; ++i) {
            vm.prank(admin);
            (bool ok, bytes memory ret) = address(grove).call(abi.encodeWithSignature(sigs[i], admin, uint256(1e18)));
            assertFalse(ok, string.concat("no such entrypoint may succeed: ", sigs[i]));
            assertEq(ret.length, 0, string.concat("must be an unmatched selector, not a guarded one: ", sigs[i]));
        }
        assertEq(grove.totalSupply(), SUPPLY, "supply unchanged by the whole sweep");
    }

    /// @dev Total supply is conserved across every value path the token does expose.
    function testFuzz_fixedSupply_totalSupplyIsInvariantAcrossEveryValuePath(uint256 amount, uint256 spendPart)
        public
    {
        amount = bound(amount, 0, SUPPLY);
        spendPart = bound(spendPart, 0, amount);

        vm.prank(treasury);
        grove.transfer(alice, amount);
        assertEq(grove.totalSupply(), SUPPLY, "transfer conserves supply");

        vm.prank(alice);
        grove.approve(bob, spendPart);
        assertEq(grove.totalSupply(), SUPPLY, "approve conserves supply");

        vm.prank(bob);
        grove.transferFrom(alice, carol, spendPart);
        assertEq(grove.totalSupply(), SUPPLY, "transferFrom conserves supply");

        vm.prank(alice);
        grove.delegate(carol);
        assertEq(grove.totalSupply(), SUPPLY, "delegation conserves supply");

        assertEq(
            grove.balanceOf(treasury) + grove.balanceOf(alice) + grove.balanceOf(carol),
            SUPPLY,
            "and every wei is still accounted for across the holders"
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // ERC-20 value paths
    // ═════════════════════════════════════════════════════════════════════

    function test_transfer_movesBalanceAndEmitsTransfer() public {
        vm.expectEmit(true, true, true, true, address(grove));
        emit IERC20.Transfer(treasury, alice, 1_000e18);
        vm.prank(treasury);
        assertTrue(grove.transfer(alice, 1_000e18), "ERC20 transfer returns true");

        assertEq(grove.balanceOf(alice), 1_000e18);
        assertEq(grove.balanceOf(treasury), SUPPLY - 1_000e18);
        assertEq(grove.totalSupply(), SUPPLY);
    }

    function test_transfer_zeroAmountIsAllowedAndStillEmits() public {
        vm.expectEmit(true, true, true, true, address(grove));
        emit IERC20.Transfer(treasury, alice, 0);
        vm.prank(treasury);
        grove.transfer(alice, 0);
        assertEq(grove.balanceOf(alice), 0);
    }

    function test_transfer_toSelfIsBalanceNeutral() public {
        vm.prank(treasury);
        grove.transfer(treasury, 5_000e18);
        assertEq(grove.balanceOf(treasury), SUPPLY, "self-transfer leaves the balance intact");
        assertEq(grove.getVotes(treasury), SUPPLY, "and the votes intact");
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        grove.transfer(bob, 1);

        vm.prank(treasury);
        grove.transfer(alice, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100e18, 100e18 + 1)
        );
        vm.prank(alice);
        grove.transfer(bob, 100e18 + 1);
    }

    function test_transfer_revertsOnZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(treasury);
        grove.transfer(address(0), 1e18);
    }

    function test_approve_setsAllowanceAndEmitsApproval() public {
        vm.expectEmit(true, true, true, true, address(grove));
        emit IERC20.Approval(treasury, alice, 42e18);
        vm.prank(treasury);
        assertTrue(grove.approve(alice, 42e18), "ERC20 approve returns true");
        assertEq(grove.allowance(treasury, alice), 42e18);

        vm.prank(treasury);
        grove.approve(alice, 7e18);
        assertEq(grove.allowance(treasury, alice), 7e18, "approve overwrites, it does not increment");
    }

    function test_approve_revertsOnZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(treasury);
        grove.approve(address(0), 1e18);
    }

    function test_transferFrom_spendsAllowanceExactly() public {
        vm.prank(treasury);
        grove.transfer(alice, 100e18);
        vm.prank(alice);
        grove.approve(bob, 60e18);

        vm.prank(bob);
        assertTrue(grove.transferFrom(alice, carol, 25e18));
        assertEq(grove.allowance(alice, bob), 35e18, "allowance decremented by exactly the amount");
        assertEq(grove.balanceOf(carol), 25e18);
        assertEq(grove.balanceOf(alice), 75e18);
    }

    function test_transferFrom_revertsOnInsufficientAllowance() public {
        vm.prank(treasury);
        grove.transfer(alice, 100e18);
        vm.prank(alice);
        grove.approve(bob, 10e18);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10e18, 11e18));
        vm.prank(bob);
        grove.transferFrom(alice, carol, 11e18);
    }

    function test_transferFrom_infiniteAllowanceIsNotDecremented() public {
        vm.prank(treasury);
        grove.transfer(alice, 100e18);
        vm.prank(alice);
        grove.approve(bob, type(uint256).max);

        vm.prank(bob);
        grove.transferFrom(alice, carol, 40e18);
        assertEq(grove.allowance(alice, bob), type(uint256).max, "infinite allowance survives a spend");
    }

    // ═════════════════════════════════════════════════════════════════════
    // ERC20Votes — delegation, checkpoints, and the timestamp clock
    // ═════════════════════════════════════════════════════════════════════

    function test_votes_undelegatedBalanceCarriesNoVotingPower() public {
        vm.prank(treasury);
        grove.transfer(alice, 1_000e18);
        assertEq(grove.balanceOf(alice), 1_000e18);
        assertEq(grove.getVotes(alice), 0, "balance alone is not voting power");
        assertEq(grove.getVotes(treasury), SUPPLY - 1_000e18, "and the sender's votes fell by the same amount");
    }

    function test_delegate_emitsBothVoteEventsWithFullData() public {
        vm.prank(treasury);
        grove.transfer(alice, 1_000e18);

        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateChanged(alice, address(0), bob);
        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateVotesChanged(bob, 0, 1_000e18);
        vm.prank(alice);
        grove.delegate(bob);

        assertEq(grove.delegates(alice), bob);
        assertEq(grove.getVotes(bob), 1_000e18, "delegatee holds the votes");
        assertEq(grove.getVotes(alice), 0, "delegator holds none");
        assertEq(grove.balanceOf(bob), 0, "and no tokens moved");
    }

    function test_delegate_redelegationMovesVotesBetweenDelegatees() public {
        vm.prank(treasury);
        grove.transfer(alice, 1_000e18);
        vm.prank(alice);
        grove.delegate(bob);

        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateChanged(alice, bob, carol);
        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateVotesChanged(bob, 1_000e18, 0);
        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateVotesChanged(carol, 0, 1_000e18);
        vm.prank(alice);
        grove.delegate(carol);

        assertEq(grove.getVotes(bob), 0);
        assertEq(grove.getVotes(carol), 1_000e18);
    }

    function test_delegate_toZeroClearsVotingPowerWithoutMovingTokens() public {
        vm.prank(treasury);
        grove.transfer(alice, 1_000e18);
        vm.prank(alice);
        grove.delegate(alice);
        assertEq(grove.getVotes(alice), 1_000e18);

        vm.prank(alice);
        grove.delegate(address(0));
        assertEq(grove.getVotes(alice), 0, "votes retired");
        assertEq(grove.balanceOf(alice), 1_000e18, "tokens untouched");
        assertEq(grove.delegates(alice), address(0));
    }

    function test_votes_transferMovesVotingPowerBetweenDelegatees() public {
        vm.prank(treasury);
        grove.transfer(alice, 1_000e18);
        vm.prank(alice);
        grove.delegate(alice);
        vm.prank(bob);
        grove.delegate(bob);

        vm.prank(alice);
        grove.transfer(bob, 400e18);
        assertEq(grove.getVotes(alice), 600e18, "voting power follows balance out");
        assertEq(grove.getVotes(bob), 400e18, "and in");
    }

    function test_votes_pastVotesAreCheckpointedAtTheTimestampClock() public {
        uint256 t0 = block.timestamp;
        vm.prank(treasury);
        grove.transfer(alice, 1_000e18);
        vm.prank(alice);
        grove.delegate(alice);

        vm.warp(block.timestamp + 1 days);
        uint256 t1 = block.timestamp;
        vm.prank(alice);
        grove.transfer(bob, 250e18);

        vm.warp(block.timestamp + 1 days);

        assertEq(grove.getPastVotes(alice, t0 - 1), 0, "no votes before the delegation");
        assertEq(grove.getPastVotes(alice, t1 - 1), 1_000e18, "full votes between delegation and transfer");
        assertEq(grove.getPastVotes(alice, t1), 750e18, "reduced from the transfer timestamp onwards");
        assertEq(grove.getVotes(alice), 750e18);
    }

    function test_votes_pastTotalSupplyIsTheFixedSupplyAtEveryHistoricTimepoint() public {
        uint256 t0 = block.timestamp;
        vm.warp(block.timestamp + 30 days);
        vm.prank(treasury);
        grove.transfer(alice, 123e18);
        vm.warp(block.timestamp + 30 days);

        assertEq(grove.getPastTotalSupply(t0), SUPPLY, "fixed supply, historically too");
        assertEq(grove.getPastTotalSupply(block.timestamp - 1), SUPPLY);
    }

    function test_votes_futureLookupRevertsWithTheClockInTheError() public {
        uint256 notYetPast = block.timestamp; // clock() == block.timestamp
        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, notYetPast, uint48(block.timestamp))
        );
        grove.getPastVotes(treasury, notYetPast);

        vm.expectRevert(
            abi.encodeWithSelector(VotesUpgradeable.ERC5805FutureLookup.selector, notYetPast, uint48(block.timestamp))
        );
        grove.getPastTotalSupply(notYetPast);
    }

    function test_votes_checkpointsAreQueryable() public {
        assertEq(grove.numCheckpoints(treasury), 1, "the genesis self-delegation wrote one checkpoint");
        Checkpoints.Checkpoint208 memory c0 = grove.checkpoints(treasury, 0);
        assertEq(c0._value, SUPPLY);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(treasury);
        grove.transfer(alice, 10e18);
        assertEq(grove.numCheckpoints(treasury), 2);
        Checkpoints.Checkpoint208 memory c1 = grove.checkpoints(treasury, 1);
        assertEq(c1._value, SUPPLY - 10e18);
        assertEq(c1._key, uint48(block.timestamp), "checkpoints are keyed by TIMESTAMP, not block height");
    }

    // ── the clock (governance params are second-denominated) ─────────────

    function test_clock_isTheBlockTimestampAndTracksWarpsNotBlocks() public {
        assertEq(grove.clock(), uint48(block.timestamp));
        assertTrue(uint48(block.number) != uint48(block.timestamp), "the fixture separates the two clocks");
        assertTrue(grove.clock() != uint48(block.number), "not a block-number clock");

        vm.warp(1_900_000_000);
        assertEq(grove.clock(), uint48(1_900_000_000), "clock follows wall time");
        vm.roll(block.number + 5_000);
        assertEq(grove.clock(), uint48(1_900_000_000), "and is unmoved by block height");
    }

    function testFuzz_clock_equalsTimestampTruncatedToUint48(uint48 ts) public {
        ts = uint48(bound(ts, 1, type(uint48).max));
        vm.warp(ts);
        assertEq(grove.clock(), ts);
    }

    function test_clockMode_isMachineReadableTimestampMode() public view {
        assertEq(grove.CLOCK_MODE(), "mode=timestamp", "EIP-6372 descriptor");
        assertEq(
            keccak256(bytes(grove.CLOCK_MODE())), keccak256(bytes("mode=timestamp")), "byte-exact, not merely non-empty"
        );
    }

    // ── delegateBySig ────────────────────────────────────────────────────

    function test_delegateBySig_delegatesForTheSigner() public {
        (address owner, uint256 key) = makeAddrAndKey("delegatorEOA");
        vm.prank(treasury);
        grove.transfer(owner, 500e18);

        uint256 expiry = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(key, bob, 0, expiry);

        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateChanged(owner, address(0), bob);
        vm.expectEmit(true, true, true, true, address(grove));
        emit IVotes.DelegateVotesChanged(bob, 0, 500e18);
        grove.delegateBySig(bob, 0, expiry, v, r, s);

        assertEq(grove.delegates(owner), bob);
        assertEq(grove.getVotes(bob), 500e18);
        assertEq(grove.nonces(owner), 1, "nonce consumed");
    }

    function test_delegateBySig_revertsOnExpiry() public {
        (, uint256 key) = makeAddrAndKey("delegatorEOA");
        uint256 expiry = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(key, bob, 0, expiry);

        vm.expectRevert(abi.encodeWithSelector(IVotes.VotesExpiredSignature.selector, expiry));
        grove.delegateBySig(bob, 0, expiry, v, r, s);
    }

    function test_delegateBySig_revertsOnReplayWithTheConsumedNonce() public {
        (address owner, uint256 key) = makeAddrAndKey("delegatorEOA");
        uint256 expiry = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(key, bob, 0, expiry);
        grove.delegateBySig(bob, 0, expiry, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(NoncesUpgradeable.InvalidAccountNonce.selector, owner, 1));
        grove.delegateBySig(bob, 0, expiry, v, r, s);
    }

    // ═════════════════════════════════════════════════════════════════════
    // ERC-2612 permit — and the nonce shared with delegateBySig
    // ═════════════════════════════════════════════════════════════════════

    function test_permit_setsAllowanceBumpsNonceAndEmitsApproval() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        vm.prank(treasury);
        grove.transfer(owner, 5e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 5e18, 0, deadline);

        vm.expectEmit(true, true, true, true, address(grove));
        emit IERC20.Approval(owner, bob, 5e18);
        grove.permit(owner, bob, 5e18, deadline, v, r, s);

        assertEq(grove.allowance(owner, bob), 5e18);
        assertEq(grove.nonces(owner), 1, "the nonces() override forwards to NoncesUpgradeable");

        vm.prank(bob);
        grove.transferFrom(owner, carol, 5e18);
        assertEq(grove.balanceOf(carol), 5e18, "the granted allowance is really spendable");
    }

    function test_permit_revertsOnExpiredDeadline() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 1e18, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        grove.permit(owner, bob, 1e18, deadline, v, r, s);
    }

    function test_permit_revertsWhenSignedByTheWrongKey() public {
        (address owner,) = makeAddrAndKey("permitOwner");
        (address impostor, uint256 badKey) = makeAddrAndKey("impostor");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(badKey, owner, bob, 1e18, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, impostor, owner));
        grove.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(grove.allowance(owner, bob), 0, "and no allowance leaked");
    }

    function test_permit_replayIsRejectedByTheConsumedNonce() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 1e18, 0, deadline);
        grove.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(grove.nonces(owner), 1);

        // Replayed verbatim, the contract now hashes with nonce 1, so ECDSA recovers a
        // DIFFERENT address. Compute it here so the expected revert is exact, not a bare catch.
        bytes32 replayDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                grove.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, bob, uint256(1e18), uint256(1), deadline))
            )
        );
        address recovered = ecrecover(replayDigest, v, r, s);
        assertTrue(recovered != address(0) && recovered != owner, "the replay recovers somebody who is not the owner");

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, recovered, owner));
        grove.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(grove.nonces(owner), 1, "nonce did not advance twice");
    }

    function test_permit_domainSeparatorBindsTheConfigNameAndTheProxy() public view {
        (, string memory domainName, string memory version, uint256 chainId, address verifyingContract,,) =
            grove.eip712Domain();
        assertEq(domainName, Config.GROVE_NAME, "the EIP-712 name is the Config name");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(grove), "domain binds the PROXY, not the implementation");

        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(Config.GROVE_NAME)),
                keccak256(bytes("1")),
                block.chainid,
                address(grove)
            )
        );
        assertEq(grove.DOMAIN_SEPARATOR(), expected, "recomputed domain separator matches");
    }

    function test_nonces_areSharedBetweenPermitAndDelegation() public {
        (address owner, uint256 key) = makeAddrAndKey("sharedNonceOwner");
        assertEq(grove.nonces(owner), 0);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, bob, 1e18, 0, deadline);
        grove.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(grove.nonces(owner), 1);

        // the delegation signature must now use nonce 1 — proving ONE shared counter
        (uint8 v2, bytes32 r2, bytes32 s2) = _signDelegation(key, carol, 1, deadline);
        grove.delegateBySig(carol, 1, deadline, v2, r2, s2);
        assertEq(grove.nonces(owner), 2);
        assertEq(grove.delegates(owner), carol);
    }

    // ═════════════════════════════════════════════════════════════════════
    // AccessControl — both callers for every privileged path
    // ═════════════════════════════════════════════════════════════════════

    function test_accessControl_upgraderRoleIsAdministeredByDefaultAdmin() public view {
        assertEq(grove.getRoleAdmin(Roles.UPGRADER_ROLE), bytes32(0));
        assertEq(Roles.UPGRADER_ROLE, keccak256("UPGRADER_ROLE"), "role id is the documented string");
    }

    function test_grantRole_adminCanGrantAndEmits() public {
        vm.expectEmit(true, true, true, true, address(grove));
        emit IAccessControl.RoleGranted(Roles.UPGRADER_ROLE, alice, admin);
        vm.prank(admin);
        grove.grantRole(Roles.UPGRADER_ROLE, alice);
        assertTrue(grove.hasRole(Roles.UPGRADER_ROLE, alice));
    }

    function test_grantRole_revertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        grove.grantRole(Roles.UPGRADER_ROLE, alice);
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, alice), "and no role leaked");
    }

    /// @dev Holding UPGRADER_ROLE must not confer the ability to hand it out or to self-promote.
    function test_grantRole_upgraderCannotEscalate() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, upgrader, bytes32(0))
        );
        vm.prank(upgrader);
        grove.grantRole(Roles.UPGRADER_ROLE, alice);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, upgrader, bytes32(0))
        );
        vm.prank(upgrader);
        grove.grantRole(bytes32(0), upgrader);
        assertFalse(grove.hasRole(bytes32(0), upgrader), "no self-promotion to admin");
    }

    function test_revokeRole_adminCanRevokeAndEmits() public {
        vm.expectEmit(true, true, true, true, address(grove));
        emit IAccessControl.RoleRevoked(Roles.UPGRADER_ROLE, upgrader, admin);
        vm.prank(admin);
        grove.revokeRole(Roles.UPGRADER_ROLE, upgrader);
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, upgrader));
    }

    function test_revokeRole_revertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        grove.revokeRole(Roles.UPGRADER_ROLE, upgrader);
        assertTrue(grove.hasRole(Roles.UPGRADER_ROLE, upgrader), "the role survives the failed attempt");
    }

    function test_renounceRole_onlyForSelfAndEmits() public {
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        vm.prank(admin);
        grove.renounceRole(Roles.UPGRADER_ROLE, upgrader); // admin cannot renounce for another

        vm.expectEmit(true, true, true, true, address(grove));
        emit IAccessControl.RoleRevoked(Roles.UPGRADER_ROLE, upgrader, upgrader);
        vm.prank(upgrader);
        grove.renounceRole(Roles.UPGRADER_ROLE, upgrader);
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, upgrader));
    }

    function test_supportsInterface_accessControlAndErc165() public view {
        assertTrue(grove.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl");
        assertTrue(grove.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(grove.supportsInterface(0xffffffff), "the ERC-165 sentinel must be false");
        assertFalse(grove.supportsInterface(type(IERC20).interfaceId), "ERC20 is not registered via ERC165");
    }

    // ═════════════════════════════════════════════════════════════════════
    // UUPS — _authorizeUpgrade is gated on UPGRADER_ROLE, not on admin
    // ═════════════════════════════════════════════════════════════════════

    function test_upgrade_upgraderCanUpgradeAndAllStateSurvives() public {
        vm.prank(treasury);
        grove.transfer(alice, 7e18);
        vm.prank(alice);
        grove.delegate(alice);

        address newImpl = address(new GroveTokenV2Mock());
        vm.expectEmit(true, true, true, true, address(grove));
        emit IERC1967.Upgraded(newImpl);
        vm.prank(upgrader);
        grove.upgradeToAndCall(newImpl, "");

        assertEq(GroveTokenV2Mock(address(grove)).version(), 2, "the new implementation is live");
        assertEq(grove.balanceOf(alice), 7e18, "balances survived");
        assertEq(grove.getVotes(alice), 7e18, "checkpoints survived");
        assertEq(grove.totalSupply(), SUPPLY, "supply survived");
        assertTrue(grove.hasRole(bytes32(0), admin), "roles survived");
        assertEq(_implementationOf(address(grove)), newImpl, "ERC-1967 slot rewritten");
    }

    /// @dev THE role-separation test. Production wires admin == upgrader == the timelock, so
    ///      production alone can never show that `_authorizeUpgrade` is gated on UPGRADER_ROLE
    ///      rather than on DEFAULT_ADMIN_ROLE. Here they are distinct, so it can.
    function test_upgrade_defaultAdminAloneCannotUpgrade() public {
        address newImpl = address(new GroveTokenV2Mock());
        assertTrue(grove.hasRole(bytes32(0), admin), "admin really is DEFAULT_ADMIN");
        assertFalse(grove.hasRole(Roles.UPGRADER_ROLE, admin), "but holds no UPGRADER_ROLE");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, Roles.UPGRADER_ROLE)
        );
        vm.prank(admin);
        grove.upgradeToAndCall(newImpl, "");
        assertEq(_implementationOf(address(grove)), address(impl), "implementation slot untouched");
    }

    function test_upgrade_revertsForUnprivilegedCaller() public {
        address newImpl = address(new GroveTokenV2Mock());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.UPGRADER_ROLE)
        );
        vm.prank(alice);
        grove.upgradeToAndCall(newImpl, "");
        assertEq(_implementationOf(address(grove)), address(impl), "implementation slot untouched");
    }

    function test_upgrade_stopsWorkingOnceTheUpgraderRoleIsRevoked() public {
        vm.prank(admin);
        grove.revokeRole(Roles.UPGRADER_ROLE, upgrader);

        address newImpl = address(new GroveTokenV2Mock());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, upgrader, Roles.UPGRADER_ROLE
            )
        );
        vm.prank(upgrader);
        grove.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_rejectsANonUupsImplementation() public {
        address bad = address(new NotUUPS());
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, bad));
        vm.prank(upgrader);
        grove.upgradeToAndCall(bad, "");
        assertEq(_implementationOf(address(grove)), address(impl), "implementation slot untouched");
    }

    function test_upgrade_implementationCannotBeUpgradedDirectly() public {
        address newImpl = address(new GroveTokenV2Mock());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(upgrader);
        impl.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_proxiableUuidIsTheErc1967SlotAndIsNotDelegatable() public {
        assertEq(impl.proxiableUUID(), ERC1967Utils.IMPLEMENTATION_SLOT, "the implementation reports the slot");
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        grove.proxiableUUID(); // notDelegated: must fail through the proxy
    }

    /// @dev The PRODUCTION wiring, against the real TimelockController the deploy script uses:
    ///      `initialize(timelock, timelock, frTreasury)` (script/Deploy.s.sol:349). The upgrade
    ///      must be unreachable except through a scheduled operation that has served its delay.
    function test_upgrade_productionWiring_onlyTheTimelockCanUpgradeAndOnlyAfterTheDelay() public {
        TimelockControllerUpgradeable timelock = _deployTimelock();
        GroveToken prodGrove = GroveToken(
            address(
                new ERC1967Proxy(
                    address(spareImpl),
                    abi.encodeCall(GroveToken.initialize, (address(timelock), address(timelock), treasury))
                )
            )
        );
        assertTrue(prodGrove.hasRole(Roles.UPGRADER_ROLE, address(timelock)), "timelock is the sole upgrade authority");

        address newImpl = address(new GroveTokenV2Mock());
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        bytes32 opId = timelock.hashOperation(address(prodGrove), 0, payload, bytes32(0), bytes32(0));
        bytes32 readyBitmap = bytes32(uint256(1) << uint256(uint8(TimelockControllerUpgradeable.OperationState.Ready)));

        // 1. nobody outside the timelock — including the treasury that holds all the GROVE
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, treasury, Roles.UPGRADER_ROLE
            )
        );
        vm.prank(treasury);
        prodGrove.upgradeToAndCall(newImpl, "");

        // 2. scheduled but not yet ripe — the timelock itself refuses to execute
        vm.startPrank(admin); // `admin` is the timelock's proposer/executor here
        timelock.schedule(address(prodGrove), 0, payload, bytes32(0), bytes32(0), Config.TIMELOCK_MIN_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockControllerUpgradeable.TimelockUnexpectedOperationState.selector, opId, readyBitmap
            )
        );
        timelock.execute(address(prodGrove), 0, payload, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(_implementationOf(address(prodGrove)), address(spareImpl), "premature execution did not land");

        // 3. after the delay it lands
        vm.warp(block.timestamp + Config.TIMELOCK_MIN_DELAY + 1);
        vm.prank(admin);
        timelock.execute(address(prodGrove), 0, payload, bytes32(0), bytes32(0));
        assertEq(_implementationOf(address(prodGrove)), newImpl, "the timelocked upgrade landed");
        assertEq(GroveTokenV2Mock(address(prodGrove)).version(), 2);
        assertEq(prodGrove.balanceOf(treasury), SUPPLY, "and the supply is untouched by it");
    }

    // ═════════════════════════════════════════════════════════════════════
    // helpers
    // ═════════════════════════════════════════════════════════════════════

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _deployTimelock() internal returns (TimelockControllerUpgradeable timelock) {
        address[] memory who = new address[](1);
        who[0] = admin;
        timelock = TimelockControllerUpgradeable(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new TimelockControllerUpgradeable()),
                        abi.encodeCall(
                            TimelockControllerUpgradeable.initialize, (Config.TIMELOCK_MIN_DELAY, who, who, address(0))
                        )
                    )
                )
            )
        );
    }

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", grove.DOMAIN_SEPARATOR(), structHash)));
    }

    function _signDelegation(uint256 key, address delegatee, uint256 nonce, uint256 expiry)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", grove.DOMAIN_SEPARATOR(), structHash)));
    }
}
