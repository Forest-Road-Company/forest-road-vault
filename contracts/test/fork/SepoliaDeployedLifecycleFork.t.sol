// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

import {AssessedImpairmentSource} from "../../src/AssessedImpairmentSource.sol";
import {AttestationOracle} from "../../src/AttestationOracle.sol";
import {ClaimBridge} from "../../src/ClaimBridge.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {CuratorModule} from "../../src/CuratorModule.sol";
import {DefaultManager} from "../../src/DefaultManager.sol";
import {GroveToken} from "../../src/GroveToken.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {PointsModule} from "../../src/PointsModule.sol";
import {RedemptionQueue} from "../../src/RedemptionQueue.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SGrove} from "../../src/SGrove.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {WaterfallEngine} from "../../src/WaterfallEngine.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IReserveManager} from "../../src/interfaces/IReserveManager.sol";
import {IWaterfallEngine} from "../../src/interfaces/IWaterfallEngine.sol";
import {Config} from "../../src/libraries/Config.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "../helpers/MockERC20.sol";

/// @notice Curated, stateful lifecycle tests against the exact addresses produced by the
///         Sepolia deployment. The RPC safety boundary is a pinned, chain-31337 local fork.
///         These tests complement the generated direct-call matrix: they prove economically
///         meaningful positive paths, balance/accounting deltas, events, signatures and
///         multi-contract state transitions that cannot be established by one isolated call.
contract SepoliaDeployedLifecycleForkTest is Test {
    uint256 internal constant ATTESTER_PK_1 = 0xA11CE;
    uint256 internal constant ATTESTER_PK_2 = 0xB0B;

    bool internal forkReady;
    uint256 internal forkBlock;
    uint256 internal actorPk;
    uint256 internal attestationNonce;

    address internal actor;
    address internal secondary = makeAddr("sepoliaForkLifecycleSecondary");
    address internal outsider = makeAddr("sepoliaForkLifecycleOutsider");
    address internal ops;
    address internal queueKeeper;
    address internal treasury;
    address internal timelock;

    MockERC20 internal stable;
    USDfr internal usdfr;
    SUSDfr internal vault;
    MintRedeemController internal controller;
    ReserveManager internal reserves;
    RedemptionQueue internal queue;
    ComplianceRegistry internal compliance;
    PointsModule internal points;
    GroveToken internal grove;
    SGrove internal sGrove;
    AttestationOracle internal oracle;
    ClaimBridge internal bridge;
    CollateralRegistry internal registry;
    CuratorModule internal curator;
    WaterfallEngine internal waterfall;
    DefaultManager internal defaults;
    AssessedImpairmentSource internal assessedImpairment;

    modifier onPinnedFork() {
        vm.skip(!forkReady);
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_FORK_RPC_URL", string(""));
        forkBlock = vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0));
        string memory manifestPath = _manifestPath();
        if (bytes(rpc).length == 0 || forkBlock == 0 || !vm.exists(manifestPath)) return;

        vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 31337, "local fork must use chain ID 31337");

        string memory manifest = vm.readFile(manifestPath);
        uint256 manifestChainId = vm.parseJsonUint(manifest, ".chainId");
        bool localDeploymentRehearsal = vm.envOr("LOCAL_DEPLOYMENT_REHEARSAL", false);
        require(
            manifestChainId == 11155111 || (localDeploymentRehearsal && manifestChainId == 31337),
            "manifest must be Sepolia"
        );
        require(forkBlock > vm.parseJsonUint(manifest, ".deployedAtBlock"), "fork must be post-deployment");
        bool keepOpsAdmin = vm.keyExistsJson(manifest, ".keepOpsAdmin")
            ? vm.parseJsonBool(manifest, ".keepOpsAdmin")
            : vm.parseJsonBool(manifest, ".TESTNET_keepOpsAdmin");
        require(keepOpsAdmin, "curated test requires the manifest-declared testnet ops posture");

        ops = vm.parseJsonAddress(manifest, ".opsAdmin");
        queueKeeper = vm.parseJsonAddress(manifest, ".queueKeeper");
        treasury = vm.parseJsonAddress(manifest, ".frTreasury");
        timelock = vm.parseJsonAddress(manifest, ".timelock");
        stable = MockERC20(vm.parseJsonAddress(manifest, ".stable"));
        usdfr = USDfr(vm.parseJsonAddress(manifest, ".usdfr"));
        vault = SUSDfr(vm.parseJsonAddress(manifest, ".vault"));
        controller = MintRedeemController(vm.parseJsonAddress(manifest, ".controller"));
        reserves = ReserveManager(vm.parseJsonAddress(manifest, ".reserves"));
        queue = RedemptionQueue(vm.parseJsonAddress(manifest, ".queue"));
        compliance = ComplianceRegistry(vm.parseJsonAddress(manifest, ".compliance"));
        points = PointsModule(vm.parseJsonAddress(manifest, ".points"));
        grove = GroveToken(vm.parseJsonAddress(manifest, ".grove"));
        sGrove = SGrove(vm.parseJsonAddress(manifest, ".sGrove"));
        oracle = AttestationOracle(vm.parseJsonAddress(manifest, ".oracle"));
        bridge = ClaimBridge(vm.parseJsonAddress(manifest, ".bridge"));
        registry = CollateralRegistry(vm.parseJsonAddress(manifest, ".registry"));
        curator = CuratorModule(vm.parseJsonAddress(manifest, ".curator"));
        waterfall = WaterfallEngine(vm.parseJsonAddress(manifest, ".waterfall"));
        defaults = DefaultManager(vm.parseJsonAddress(manifest, ".defaultManager"));
        assessedImpairment = AssessedImpairmentSource(vm.parseJsonAddress(manifest, ".assessedImpairmentSource"));

        actorPk = uint256(keccak256("sepolia deployed lifecycle actor"));
        actor = vm.addr(actorPk);
        forkReady = true;

        _assertCode();
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ADMIN_ROLE, ops));
        assertTrue(bridge.hasRole(Roles.ORIGINATOR_ROLE, ops));
        assertTrue(waterfall.hasRole(Roles.SERVICER_ROLE, ops));
        assertTrue(defaults.hasRole(Roles.SERVICER_ROLE, ops));
        assertTrue(queue.hasRole(Roles.SETTLEMENT_KEEPER_ROLE, queueKeeper));
    }

    function test_sepoliaDeployedFork_mintVaultQueueSettlementClaimAndAccounting() public onPinnedFork {
        _allow(actor);
        _allow(secondary);

        uint256 supplyBefore = usdfr.totalSupply();
        uint256 backingBefore = reserves.totalBackingValue();
        uint256 stableReserveBefore = stable.balanceOf(address(reserves));
        stable.mint(actor, 80_000e6);
        vm.prank(actor);
        stable.transfer(secondary, 1e6);
        vm.prank(secondary);
        stable.approve(outsider, 1e6);
        vm.prank(outsider);
        stable.transferFrom(secondary, actor, 1e6);

        vm.startPrank(actor);
        stable.approve(address(controller), 60_000e6);
        vm.recordLogs();
        uint256 minted = controller.mint(60_000e6);
        Vm.Log[] memory mintLogs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(minted, 60_000e18, "USDC/USDfr normalization");
        assertEq(usdfr.balanceOf(actor), minted);
        assertEq(usdfr.totalSupply() - supplyBefore, minted);
        assertEq(reserves.totalBackingValue() - backingBefore, minted);
        assertEq(stable.balanceOf(address(reserves)) - stableReserveBefore, 60_000e6);
        assertTrue(_sawTopic(mintLogs, keccak256("Minted(address,uint256,uint256)")));
        assertTrue(controller.backingInvariantHolds());

        uint256 actorStableBefore = stable.balanceOf(actor);
        uint256 idleBefore = reserves.idleReserve();
        vm.prank(actor);
        uint256 stableOut = controller.redeem(2_500e18);
        assertEq(stableOut, 2_500e6);
        assertEq(stable.balanceOf(actor) - actorStableBefore, stableOut);
        assertEq(idleBefore - reserves.idleReserve(), 2_500e18);
        assertTrue(controller.backingInvariantHolds());

        vm.prank(ops);
        compliance.setJurisdictionBlocked(secondary, true);
        vm.expectRevert();
        vm.prank(actor);
        usdfr.transfer(secondary, 1e18);
        vm.prank(ops);
        compliance.setJurisdictionBlocked(secondary, false);
        vm.prank(actor);
        usdfr.transfer(secondary, 1e18);
        vm.prank(secondary);
        usdfr.approve(outsider, 1e18);
        vm.prank(outsider);
        usdfr.transferFrom(secondary, actor, 1e18);

        uint256 depositAssets = 20_000e18;
        _permit(IERC20Permit(address(usdfr)), actorPk, actor, address(vault), depositAssets);
        vm.recordLogs();
        vm.prank(actor);
        uint256 depositShares = vault.deposit(depositAssets, actor);
        Vm.Log[] memory depositLogs = vm.getRecordedLogs();
        assertGt(depositShares, 0);
        assertEq(vault.balanceOf(actor), depositShares);
        assertTrue(_sawTopic(depositLogs, keccak256("Deposit(address,address,uint256,uint256)")));

        vm.startPrank(actor);
        usdfr.approve(address(vault), type(uint256).max);
        uint256 exactMintAssets = vault.mint(10e18, actor);
        vm.stopPrank();
        assertGt(exactMintAssets, 0, "exact-share ERC4626 mint");

        address impairmentSource = vault.impairmentSource();
        vm.prank(timelock);
        vault.setImpairmentSource(impairmentSource);
        assertEq(vault.impairmentSource(), impairmentSource, "valid impairment source revalidated");

        (uint256 trackedShares, uint256 trackedUsdfr) = points.trackedBalances(actor);
        assertEq(trackedShares, vault.balanceOf(actor), "share points hook");
        assertEq(trackedUsdfr, usdfr.balanceOf(actor), "USDfr points hook");
        uint256 pointsBefore = points.pointsOfWallet(actor);
        vm.warp(block.timestamp + 1 days);
        assertGt(points.pointsOfWallet(actor), pointsBefore, "participation points accrue");

        vm.prank(actor);
        vault.transfer(secondary, 100e18);
        vm.prank(secondary);
        vault.approve(outsider, 50e18);
        vm.prank(outsider);
        vault.transferFrom(secondary, actor, 50e18);
        assertEq(vault.balanceOf(secondary), 50e18);

        vm.prank(actor);
        vault.transfer(address(queue), 3e18);
        uint256 actorAssetsBeforeDirectExit = usdfr.balanceOf(actor);
        vm.prank(address(queue));
        uint256 directRedeemAssets = vault.redeem(1e18, actor, address(queue));
        assertGt(directRedeemAssets, 0, "queue-authorized exact-share redeem");
        uint256 directWithdrawAssets = vault.maxWithdraw(address(queue));
        assertGt(directWithdrawAssets, 0);
        vm.prank(address(queue));
        uint256 directWithdrawShares = vault.withdraw(directWithdrawAssets, actor, address(queue));
        assertGt(directWithdrawShares, 0, "queue-authorized exact-asset withdraw");
        assertEq(
            usdfr.balanceOf(actor) - actorAssetsBeforeDirectExit,
            directRedeemAssets + directWithdrawAssets,
            "direct queue exits delivered the requested assets"
        );

        vm.expectRevert();
        vm.prank(actor);
        vault.redeem(1e18, actor, actor);

        uint256 sharesToQueue = vault.previewWithdraw(1_000e18);
        vm.startPrank(actor);
        vault.approve(address(queue), sharesToQueue);
        vm.recordLogs();
        uint256 requestId = queue.requestRedeem(sharesToQueue);
        Vm.Log[] memory requestLogs = vm.getRecordedLogs();
        vm.stopPrank();
        assertTrue(_sawTopic(requestLogs, keccak256("RedemptionRequested(uint256,address,uint256,uint256)")));
        assertEq(queue.totalQueuedShares(), sharesToQueue);

        (address requestOwner, uint256 sharesRemaining, uint256 claimableBefore,,) = queue.request(requestId);
        assertEq(requestOwner, actor);
        assertEq(sharesRemaining, sharesToQueue);
        assertEq(claimableBefore, 0);

        uint256 claimableAfter;
        uint256 settlementRounds;
        while (sharesRemaining != 0 && settlementRounds < 8) {
            uint256 settleAt = queue.epochEndsAt();
            uint256 eligibleAt = queue.eligibleToSettleAt(requestId);
            if (eligibleAt > settleAt) settleAt = eligibleAt;
            vm.warp(settleAt + 1);

            vm.recordLogs();
            vm.prank(queueKeeper);
            queue.closeEpoch(10);
            Vm.Log[] memory settlementLogs = vm.getRecordedLogs();
            assertTrue(_sawTopic(settlementLogs, keccak256("RequestFilled(uint256,uint256,uint256,uint256)")));
            assertTrue(_sawTopic(settlementLogs, keccak256("EpochClosed(uint256,uint256,uint256,uint64)")));
            (, sharesRemaining, claimableAfter,,) = queue.request(requestId);
            ++settlementRounds;
        }
        assertEq(sharesRemaining, 0);
        assertGt(claimableAfter, 0);
        assertGt(settlementRounds, 0);
        assertEq(queue.totalQueuedShares(), 0);

        uint256 usdfrBeforeClaim = usdfr.balanceOf(actor);
        vm.recordLogs();
        vm.prank(actor);
        uint256 claimed = queue.claim(requestId);
        Vm.Log[] memory claimLogs = vm.getRecordedLogs();
        assertEq(claimed, claimableAfter);
        assertEq(usdfr.balanceOf(actor) - usdfrBeforeClaim, claimed);
        assertTrue(_sawTopic(claimLogs, keccak256("Claimed(uint256,address,uint256)")));
        vm.expectRevert();
        vm.prank(actor);
        queue.claim(requestId);

        assertTrue(controller.backingInvariantHolds());
        assertLe(usdfr.totalSupply(), reserves.totalBackingValue());
    }

    function test_sepoliaDeployedFork_grovePermitDelegationStakeRewardsCoverageAndUnbond() public onPinnedFork {
        _allow(actor);
        _mintUsdfr(actor, 15_000e6);

        uint256 groveAmount = 20_000e18;
        vm.prank(treasury);
        grove.transfer(actor, groveAmount);
        assertEq(grove.balanceOf(actor), groveAmount);
        vm.prank(actor);
        grove.approve(outsider, 1e18);
        vm.prank(outsider);
        grove.transferFrom(actor, secondary, 1e18);
        vm.prank(secondary);
        grove.transfer(actor, 1e18);
        assertEq(grove.balanceOf(actor), groveAmount);

        uint256 groveDelegationExpiry = block.timestamp + 1 days;
        uint256 groveDelegationNonce = grove.nonces(actor);
        bytes32 groveDelegationStructHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                actor,
                groveDelegationNonce,
                groveDelegationExpiry
            )
        );
        bytes32 groveDelegationDigest =
            keccak256(abi.encodePacked(hex"1901", _groveDomainSeparator(), groveDelegationStructHash));
        (uint8 groveV, bytes32 groveR, bytes32 groveS) = vm.sign(actorPk, groveDelegationDigest);
        vm.prank(outsider);
        grove.delegateBySig(actor, groveDelegationNonce, groveDelegationExpiry, groveV, groveR, groveS);
        assertEq(grove.delegates(actor), actor);
        assertEq(grove.getVotes(actor), groveAmount);
        assertGt(grove.numCheckpoints(actor), 0);
        Checkpoints.Checkpoint208 memory checkpoint = grove.checkpoints(actor, 0);
        assertLe(checkpoint._key, grove.clock());
        assertEq(uint256(checkpoint._value), groveAmount);

        _permit(IERC20Permit(address(grove)), actorPk, actor, address(sGrove), 10_000e18);
        vm.recordLogs();
        vm.prank(actor);
        sGrove.stake(10_000e18);
        Vm.Log[] memory stakeLogs = vm.getRecordedLogs();
        assertEq(sGrove.stakedOf(actor), 10_000e18);
        assertEq(sGrove.totalVotingUnits(), sGrove.totalStaked());
        assertEq(sGrove.delegates(actor), actor, "first stake self-delegates");
        assertTrue(_sawTopic(stakeLogs, keccak256("Staked(address,uint256)")));

        uint256 expiry = block.timestamp + 1 days;
        uint256 delegationNonce = sGrove.nonces(actor);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                secondary,
                delegationNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _sGroveDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorPk, digest);
        vm.prank(outsider);
        sGrove.delegateBySig(secondary, delegationNonce, expiry, v, r, s);
        assertEq(sGrove.delegates(actor), secondary);
        assertEq(sGrove.getVotes(secondary), sGrove.stakedOf(actor));
        vm.expectRevert();
        sGrove.delegateBySig(secondary, delegationNonce, expiry, v, r, s);

        vm.startPrank(actor);
        usdfr.approve(address(sGrove), type(uint256).max);
        vm.recordLogs();
        sGrove.fundCoverage(3_000e18);
        sGrove.notifyRewards(7_000e18);
        Vm.Log[] memory fundingLogs = vm.getRecordedLogs();
        vm.stopPrank();
        assertEq(sGrove.coverageReserve(), 3_000e18);
        assertEq(sGrove.coverageCapacity(), 3_000e18, "ADR-0035 uncapped reserve");
        (uint16 proportionalCapBps, uint256 absoluteCap) = sGrove.coverageCapParameters();
        assertEq(uint256(proportionalCapBps), Config.BPS, "ADR-0035 100% proportional cap");
        assertEq(absoluteCap, type(uint256).max, "ADR-0035 no absolute cap");
        assertTrue(_sawTopic(fundingLogs, keccak256("CoverageFunded(address,uint256)")));
        assertTrue(_sawTopic(fundingLogs, keccak256("RewardsNotified(address,uint256,uint256,uint64)")));

        vm.warp(block.timestamp + 1 days);
        uint256 pending = sGrove.pendingRewards(actor);
        assertGt(pending, 0);
        assertEq(sGrove.earned(actor), pending);
        uint256 rewardsBefore = usdfr.balanceOf(actor);
        vm.prank(actor);
        uint256 claimed = sGrove.claimRewards();
        assertEq(usdfr.balanceOf(actor) - rewardsBefore, claimed);
        assertApproxEqAbs(claimed, pending, 2, "streaming reward rounding");

        uint256 activeBefore = sGrove.stakedOf(actor);
        vm.recordLogs();
        vm.prank(actor);
        uint256 unbondId = sGrove.requestUnstake(1_000e18);
        Vm.Log[] memory requestLogs = vm.getRecordedLogs();
        assertEq(sGrove.stakedOf(actor), activeBefore - 1_000e18);
        assertTrue(_sawTopic(requestLogs, keccak256("UnstakeRequested(address,uint256,uint256,uint64)")));

        SGrove.Unbond[] memory unbonds = sGrove.unbondsOf(actor);
        assertEq(unbonds[unbondId].amount, 1_000e18);
        vm.expectRevert();
        vm.prank(actor);
        sGrove.claimUnstake(unbondId);

        uint256 groveBeforeClaim = grove.balanceOf(actor);
        vm.warp(unbonds[unbondId].releaseAt);
        vm.prank(actor);
        sGrove.claimUnstake(unbondId);
        assertEq(grove.balanceOf(actor) - groveBeforeClaim, 1_000e18);
        unbonds = sGrove.unbondsOf(actor);
        assertEq(unbonds[unbondId].amount, 0);
    }

    function test_sepoliaDeployedFork_originationRepaymentDefaultCascadeAndRecovery() public onPinnedFork {
        _allow(actor);
        _prepareAttesters();
        _mintUsdfr(actor, 50_000e6);

        vm.startPrank(actor);
        usdfr.approve(address(vault), 20_000e18);
        vault.deposit(20_000e18, actor);
        vm.stopPrank();

        vm.prank(ops);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, actor, true);
        vm.startPrank(actor);
        usdfr.approve(address(curator), 5_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 5_000e18);
        usdfr.approve(address(sGrove), 3_000e18);
        sGrove.fundCoverage(3_000e18);
        vm.stopPrank();

        uint256 tokenId = _originate(10_000e18);
        ClaimBridge.Facility memory facility = bridge.facility(tokenId);
        assertEq(uint8(facility.state), uint8(ClaimBridge.LoanState.Pending));
        assertEq(bridge.ownerOf(tokenId), actor);

        vm.prank(actor);
        bridge.approve(outsider, tokenId);
        vm.expectRevert();
        vm.prank(outsider);
        bridge.transferFrom(actor, secondary, tokenId);

        uint256 stableBeforeFunding = stable.balanceOf(actor);
        vm.recordLogs();
        vm.prank(ops);
        waterfall.fund(tokenId, 10_000e6);
        Vm.Log[] memory fundingLogs = vm.getRecordedLogs();
        assertEq(stable.balanceOf(actor) - stableBeforeFunding, 9_800e6, "2% OID net");
        assertEq(reserves.deployedTo(tokenId), 10_000e18);
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Active));
        assertTrue(_sawTopic(fundingLogs, keccak256("Funded(uint256,address,uint256)")));
        assertTrue(_sawTopic(fundingLogs, keccak256("OriginationFeeCharged(uint256,uint256,uint256)")));

        vm.prank(actor);
        stable.approve(address(reserves), type(uint256).max);
        _repay(tokenId, 1_000e18, 2_000e18, _nextDue(tokenId, 2_000e18));
        assertEq(reserves.deployedTo(tokenId), 8_000e18);
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Amortizing));
        assertTrue(controller.backingInvariantHolds());

        bytes32 evidence = keccak256(abi.encode("DEPLOYED_FORK_DEFAULT", tokenId));
        _attest(tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(tokenId, evidence)));
        vm.recordLogs();
        vm.prank(ops);
        defaults.declareDefault(tokenId, evidence);
        Vm.Log[] memory defaultLogs = vm.getRecordedLogs();
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Defaulted));
        assertEq(curator.unresolvedDefaults(Config.CLASS_FILM_TAX_CREDITS), 1);
        assertEq(defaults.defaultedContribution(tokenId), 8_000e18);
        assertTrue(_sawTopic(defaultLogs, keccak256("DefaultDeclared(uint256,uint256,bytes32)")));
        assertTrue(_sawTopic(defaultLogs, keccak256("RemedyInitiated(uint256,uint256,bytes32)")));

        uint256 loss = 7_000e18;
        _attest(
            tokenId, IAttestationOracle.AttestationKind.LossRealized, keccak256(abi.encode(tokenId, loss, evidence))
        );
        uint256 vaultBeforeLoss = usdfr.balanceOf(address(vault));
        vm.recordLogs();
        vm.prank(ops);
        defaults.realizeLoss(tokenId, loss, evidence);
        Vm.Log[] memory lossLogs = vm.getRecordedLogs();

        assertEq(reserves.deployedTo(tokenId), 1_000e18);
        assertEq(curator.poolBalance(Config.CLASS_FILM_TAX_CREDITS), 0);
        // ADR-0035: the event may use the whole shared reserve, so the 2,000 remainder after
        // curator capital is delivered by layer 2 and no senior share is burned.
        assertEq(sGrove.coverageReserve(), 1_000e18);
        assertEq(vaultBeforeLoss - usdfr.balanceOf(address(vault)), 0);
        assertEq(defaults.defaultedContribution(tokenId), 1_000e18);
        (uint256 coverageDrawn, uint256 coverageCap) = sGrove.eventCoverage(tokenId);
        assertEq(coverageDrawn, 2_000e18);
        assertEq(coverageCap, 3_000e18);
        assertEq(points.curatorLossEpochCount(Config.CLASS_FILM_TAX_CREDITS), 1);
        assertEq(points.curatorLossAt(Config.CLASS_FILM_TAX_CREDITS, 0), uint64(block.timestamp));
        assertTrue(_sawTopic(lossLogs, keccak256("LossRealized(uint256,uint256,uint256,uint256,uint256,uint256)")));
        assertTrue(_sawTopic(lossLogs, keccak256("ShortfallCovered(address,uint256,uint256)")));
        assertTrue(controller.backingInvariantHolds());

        _repay(tokenId, 0, 1_000e18, 0);
        assertEq(reserves.deployedTo(tokenId), 0);
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Resolved));
        assertEq(defaults.defaultedContribution(tokenId), 0);
        assertTrue(controller.backingInvariantHolds());

        vm.prank(ops);
        curator.liftDefaultFreeze(Config.CLASS_FILM_TAX_CREDITS);
        assertEq(curator.unresolvedDefaults(Config.CLASS_FILM_TAX_CREDITS), 0);
    }

    function test_sepoliaDeployedFork_claimBridgeCompletePositiveSurface() public onPinnedFork {
        _allow(actor);
        _allow(secondary);
        _prepareAttesters();

        uint256 mintGate = bridge.requiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS);
        vm.prank(timelock);
        bridge.setRequiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS, mintGate);
        assertEq(bridge.requiredMintAttestations(Config.CLASS_FILM_TAX_CREDITS), mintGate);

        uint256 tokenId = _originate(5_000e18);
        bridge.checkFundable(tokenId);
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        assertEq(f.principal, 5_000e18);
        assertEq(bridge.ownerOf(tokenId), actor);
        assertEq(bytes(bridge.tokenURI(tokenId)).length, 0);

        vm.prank(actor);
        bridge.approve(timelock, tokenId);
        assertEq(bridge.getApproved(tokenId), timelock);
        vm.prank(timelock);
        bridge.transferFrom(actor, secondary, tokenId);
        assertEq(bridge.ownerOf(tokenId), secondary);

        vm.prank(secondary);
        bridge.approve(timelock, tokenId);
        vm.prank(timelock);
        bridge.safeTransferFrom(secondary, actor, tokenId);
        assertEq(bridge.ownerOf(tokenId), actor);

        vm.prank(actor);
        bridge.approve(timelock, tokenId);
        vm.prank(timelock);
        bridge.safeTransferFrom(actor, secondary, tokenId, hex"1234");
        assertEq(bridge.ownerOf(tokenId), secondary);

        vm.prank(address(waterfall));
        bridge.transitionState(tokenId, ClaimBridge.LoanState.Active);
        f = bridge.facility(tokenId);
        uint64 directNextDue = f.nextPaymentDue + f.paymentInterval;
        vm.prank(address(waterfall));
        bridge.setNextPaymentDue(tokenId, directNextDue);
        assertEq(bridge.facility(tokenId).nextPaymentDue, directNextDue);

        bytes32 amendmentId = keccak256(abi.encode("DEPLOYED_FORK_AMENDMENT", tokenId));
        ClaimBridge.Amendment memory amendment = ClaimBridge.Amendment({
            interestRateBps: f.interestRateBps + 1,
            maturity: f.maturity,
            paymentInterval: f.paymentInterval,
            nextPaymentDue: directNextDue + f.paymentInterval,
            rateType: f.rateType,
            dayCountConvention: f.dayCountConvention,
            renewable: f.renewable,
            paymentScheduleHash: keccak256("DEPLOYED_FORK_AMENDED_SCHEDULE"),
            rateIndexRef: f.rateIndexRef,
            renewalTermsHash: f.renewalTermsHash
        });
        _attest(
            tokenId,
            IAttestationOracle.AttestationKind.TermsAmended,
            keccak256(abi.encode(amendmentId, tokenId, amendment))
        );
        vm.prank(ops);
        bridge.amendTerms(tokenId, amendmentId, amendment);
        f = bridge.facility(tokenId);
        assertEq(f.interestRateBps, amendment.interestRateBps);
        assertEq(f.nextPaymentDue, amendment.nextPaymentDue);
        assertEq(f.paymentScheduleHash, amendment.paymentScheduleHash);

        uint256 cancelledId = _originate(1_000e18);
        vm.prank(ops);
        bridge.cancelPending(cancelledId);
        assertEq(uint8(bridge.facility(cancelledId).state), uint8(ClaimBridge.LoanState.Cancelled));
        vm.expectRevert();
        bridge.ownerOf(cancelledId);

        uint256 consumedFactId = cancelledId + 1_000;
        _attest(
            consumedFactId,
            IAttestationOracle.AttestationKind.PaymentReceived,
            keccak256("DEPLOYED_FORK_DIRECT_CONSUME")
        );
        vm.prank(address(waterfall));
        oracle.consume(consumedFactId, IAttestationOracle.AttestationKind.PaymentReceived);
        assertFalse(oracle.isSatisfied(consumedFactId, IAttestationOracle.AttestationKind.PaymentReceived));

        uint256 revokedFactId = consumedFactId + 1;
        _attest(
            revokedFactId,
            IAttestationOracle.AttestationKind.AssignmentExecuted,
            keccak256("DEPLOYED_FORK_DIRECT_REVOKE")
        );
        vm.prank(timelock);
        oracle.revoke(revokedFactId, IAttestationOracle.AttestationKind.AssignmentExecuted);
        assertFalse(oracle.isSatisfied(revokedFactId, IAttestationOracle.AttestationKind.AssignmentExecuted));
    }

    function test_sepoliaDeployedFork_directReserveControllerAndTokenAccountingHooks() public onPinnedFork {
        _allow(actor);
        stable.mint(actor, 10e6);
        vm.prank(actor);
        stable.approve(address(reserves), 10e6);

        uint256 backingBefore = reserves.totalBackingValue();
        vm.recordLogs();
        vm.prank(address(controller));
        uint256 credited = reserves.depositUSDC(actor, 10e6);
        Vm.Log[] memory depositLogs = vm.getRecordedLogs();
        assertEq(credited, 10e18);
        assertEq(reserves.totalBackingValue() - backingBefore, credited);
        assertTrue(_sawTopic(depositLogs, keccak256("USDCDeposited(address,uint256,uint256)")));

        uint256 supplyBefore = usdfr.totalSupply();
        uint256 vaultBalanceBefore = usdfr.balanceOf(address(vault));
        vm.recordLogs();
        vm.prank(address(waterfall));
        controller.mintYield(address(vault), 4e18);
        Vm.Log[] memory yieldLogs = vm.getRecordedLogs();
        assertEq(usdfr.balanceOf(address(vault)) - vaultBalanceBefore, 4e18);
        assertEq(usdfr.totalSupply() - supplyBefore, 4e18);
        assertTrue(_sawTopic(yieldLogs, keccak256("YieldMinted(address,uint256)")));

        vm.prank(address(controller));
        usdfr.burn(address(vault), 1e18);
        assertEq(usdfr.balanceOf(address(vault)) - vaultBalanceBefore, 3e18);

        vm.recordLogs();
        vm.prank(address(defaults));
        controller.burnLoss(address(vault), 1e18);
        Vm.Log[] memory burnLogs = vm.getRecordedLogs();
        assertEq(usdfr.balanceOf(address(vault)) - vaultBalanceBefore, 2e18);
        assertTrue(_sawTopic(burnLogs, keccak256("LossBurned(address,uint256)")));

        assertEq(reserves.denormalizeUSDC(1e18), 1e6);
        uint256 idleBeforeWriteDown = reserves.idleReserve();
        vm.expectRevert(IReserveManager.ReserveManager_LegacyPathDisabled.selector);
        vm.prank(ops);
        reserves.writeDownIdleUSDC(1e18);
        assertEq(reserves.idleReserve(), idleBeforeWriteDown, "disabled legacy path moved recorded backing");

        _mintUsdfr(actor, 6_000e6);
        vm.prank(ops);
        curator.setCuratorApproved(Config.CLASS_FILM_TAX_CREDITS, actor, true);
        vm.startPrank(actor);
        usdfr.approve(address(curator), 5_000e18);
        curator.postFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 5_000e18);
        curator.withdrawFirstLoss(Config.CLASS_FILM_TAX_CREDITS, 1_000e18);
        vm.stopPrank();
        assertEq(curator.postedOf(Config.CLASS_FILM_TAX_CREDITS, actor), 4_000e18);
        assertTrue(controller.backingInvariantHolds());
    }

    function test_sepoliaDeployedFork_pastDueAccelerationAndDirectRecoveryHooks() public onPinnedFork {
        _allow(actor);
        _prepareAttesters();
        _mintUsdfr(actor, 20_000e6);

        uint256 tokenId = _originate(10_000e18);
        vm.prank(ops);
        waterfall.fund(tokenId, 10_000e6);
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        assertEq(uint8(f.state), uint8(ClaimBridge.LoanState.Active));
        uint256 deployedBeforeDirectAccounting = reserves.deployedTo(tokenId);
        vm.prank(address(waterfall));
        reserves.recordFeeCapitalization(tokenId, 1e18);
        assertEq(reserves.deployedTo(tokenId), deployedBeforeDirectAccounting + 1e18);
        vm.prank(address(waterfall));
        reserves.recordPrincipalWritedown(tokenId, 1e18);
        assertEq(reserves.deployedTo(tokenId), deployedBeforeDirectAccounting);

        vm.warp(uint256(f.nextPaymentDue) + defaults.graceWindow(f.classId) + 1);
        vm.prank(outsider);
        defaults.markPastDue(tokenId);
        assertEq(defaults.pastDueContribution(tokenId), 10_000e18);

        bytes32 cureEvidence = keccak256(abi.encode("DEPLOYED_FORK_PAST_DUE_CURE", tokenId));
        _attest(tokenId, IAttestationOracle.AttestationKind.PastDueCured, keccak256(abi.encode(tokenId, cureEvidence)));
        vm.prank(ops);
        defaults.clearPastDue(tokenId, cureEvidence);
        assertEq(defaults.pastDueContribution(tokenId), 0);

        bytes32 defaultEvidence = keccak256(abi.encode("DEPLOYED_FORK_ACCELERATION", tokenId));
        _attest(
            tokenId, IAttestationOracle.AttestationKind.DefaultDeclared, keccak256(abi.encode(tokenId, defaultEvidence))
        );
        vm.prank(ops);
        defaults.declareDefault(tokenId, defaultEvidence);
        vm.prank(ops);
        defaults.accelerate(tokenId);
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Accelerated));

        stable.mint(actor, 200e6);
        vm.prank(actor);
        stable.approve(address(reserves), type(uint256).max);

        vm.prank(address(waterfall));
        uint256 partialReceived = reserves.recordPayment(tokenId, actor, 1_000e6, 1_000e18);
        assertEq(partialReceived, 1_000e18);
        vm.prank(address(waterfall));
        registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, 1_000e18);
        vm.prank(address(waterfall));
        defaults.onDefaultRecovery(tokenId);
        assertEq(reserves.deployedTo(tokenId), 9_000e18);
        assertEq(defaults.defaultedContribution(tokenId), 9_000e18);

        vm.prank(address(waterfall));
        uint256 finalReceived = reserves.recordPayment(tokenId, actor, 9_000e6, 9_000e18);
        assertEq(finalReceived, 9_000e18);
        vm.prank(address(waterfall));
        registry.recordExposureDecrease(f.classId, f.borrowerId, f.stateId, 9_000e18);
        vm.prank(address(waterfall));
        bridge.transitionState(tokenId, ClaimBridge.LoanState.Resolved);
        vm.prank(address(waterfall));
        defaults.onDefaultResolved(tokenId);

        assertEq(reserves.deployedTo(tokenId), 0);
        assertEq(defaults.defaultedContribution(tokenId), 0);
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Resolved));
        assertTrue(controller.backingInvariantHolds());
    }

    function test_sepoliaDeployedFork_mtmCurrentLtvMarginCureAndLiquidation() public onPinnedFork {
        _allow(actor);
        _prepareAttesters();
        _mintUsdfr(actor, 400_000e6);

        uint256 principal = 260_000e18;
        uint256 tokenId = _originateDigital(principal, 1_000_000e18);
        vm.prank(ops);
        waterfall.fund(tokenId, principal / 1e12);

        (uint256 initialLtv, uint64 initialAsOf) = defaults.currentLtvBps(tokenId);
        assertEq(initialLtv, 2_600);
        assertGt(initialAsOf, 0);

        vm.warp(block.timestamp + 1);
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(400_000e18)));
        vm.prank(outsider);
        defaults.marginCall(tokenId);
        assertGt(defaults.cureDeadline(tokenId), block.timestamp);

        vm.warp(block.timestamp + 1);
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(500_000e18)));
        vm.prank(outsider);
        defaults.clearMarginCall(tokenId);
        assertEq(defaults.cureDeadline(tokenId), 0);

        vm.warp(block.timestamp + 1);
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(uint256(325_000e18)));
        vm.prank(outsider);
        defaults.liquidate(tokenId);
        assertEq(uint8(bridge.facility(tokenId).state), uint8(ClaimBridge.LoanState.Defaulted));
        assertEq(defaults.defaultedContribution(tokenId), principal);
    }

    function test_sepoliaDeployedFork_governedConfigurationAndImpairmentRecoverySurface() public onPinnedFork {
        bytes32 assessmentEvidence = keccak256("DEPLOYED_FORK_ASSESSMENT");
        vm.prank(timelock);
        assessedImpairment.setAssessment(0, uint64(block.timestamp + 1 days), assessmentEvidence);
        (uint256 assessed, uint64 validUntil, bytes32 evidenceHash, bool active, uint256 conservative) =
            assessedImpairment.currentAssessment();
        assertEq(assessed, 0);
        assertEq(validUntil, uint64(block.timestamp + 1 days));
        assertEq(evidenceHash, assessmentEvidence);
        assertTrue(active);
        assertEq(conservative, 0);

        ICollateralRegistry.ClassParams memory film = registry.classParams(Config.CLASS_FILM_TAX_CREDITS);
        vm.prank(timelock);
        registry.setClass(Config.CLASS_FILM_TAX_CREDITS, film);
        assertEq(registry.classParams(Config.CLASS_FILM_TAX_CREDITS).name, film.name);

        bytes32 overrideBorrower = keccak256("DEPLOYED_FORK_OVERRIDE_BORROWER");
        vm.prank(timelock);
        registry.setBorrowerLimitOverride(overrideBorrower, 1_234);
        (uint16 overrideLimit, bool overridden) = registry.effectiveBorrowerLimitBps(overrideBorrower);
        assertEq(uint256(overrideLimit), 1_234);
        assertTrue(overridden);
        vm.prank(timelock);
        registry.clearBorrowerLimitOverride(overrideBorrower);
        (uint16 globalBorrowerLimit,,) = registry.limits();
        (uint16 restoredLimit, bool stillOverridden) = registry.effectiveBorrowerLimitBps(overrideBorrower);
        assertEq(uint256(restoredLimit), uint256(globalBorrowerLimit));
        assertFalse(stillOverridden);

        address feeRecipient = vault.feeRecipient();
        vm.prank(timelock);
        vault.setFeeRecipient(feeRecipient);
        assertEq(vault.feeRecipient(), feeRecipient);

        ToggleImpairmentSource localSource = new ToggleImpairmentSource();
        vm.prank(timelock);
        vault.setImpairmentSource(address(localSource));
        assertEq(vault.impairmentSource(), address(localSource));
        localSource.setBroken(true);
        vm.prank(timelock);
        vault.clearUnreadableImpairmentSource();
        assertEq(vault.impairmentSource(), address(0));
    }

    function _originateDigital(uint256 principal, uint256 valuation) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = _digitalTerms(principal);
        bytes32 termsHash = bridge.creditTermsHash(terms);
        // P-32: every selected deal-identity fact commits to the exact facility terms.
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.Valuation, bytes32(valuation));
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);
        vm.prank(ops);
        uint256 originated = bridge.originate(actor, terms);
        assertEq(originated, tokenId);
    }

    function _digitalTerms(uint256 principal) internal view returns (ClaimBridge.OriginationTerms memory) {
        return ClaimBridge.OriginationTerms({
            classId: Config.CLASS_DIGITAL_ASSETS,
            borrowerId: keccak256("DEPLOYED_FORK_DIGITAL_BORROWER"),
            stateId: bytes32(0),
            principal: principal,
            ltvBps: 5_000,
            interestRateBps: 1_000,
            maturity: uint64(block.timestamp + 180 days),
            fundingRecipient: actor,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("DEPLOYED_FORK_DIGITAL_SCHEDULE"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("DEPLOYED_FORK_DIGITAL_CREDIT_FILE")
        });
    }

    function _originate(uint256 principal) internal returns (uint256 tokenId) {
        tokenId = bridge.totalOriginated() + 1;
        ClaimBridge.OriginationTerms memory terms = ClaimBridge.OriginationTerms({
            classId: Config.CLASS_FILM_TAX_CREDITS,
            borrowerId: keccak256("DEPLOYED_FORK_BORROWER"),
            stateId: keccak256("GA"),
            principal: principal,
            ltvBps: 7500,
            interestRateBps: 1400,
            maturity: uint64(block.timestamp + 365 days),
            fundingRecipient: actor,
            paymentInterval: 30 days,
            nextPaymentDue: uint64(block.timestamp + 30 days),
            rateType: ClaimBridge.RateType.Fixed,
            dayCountConvention: ClaimBridge.DayCountConvention.Actual360,
            renewable: false,
            paymentScheduleHash: keccak256("DEPLOYED_FORK_AMORTIZATION"),
            rateIndexRef: bytes32(0),
            renewalTermsHash: bytes32(0),
            offchainRef: keccak256("DEPLOYED_FORK_CREDIT_FILE")
        });
        bytes32 termsHash = bridge.creditTermsHash(terms);
        // P-32: documentary admission facts are commitments to this deal, not generic paperwork.
        _attest(tokenId, IAttestationOracle.AttestationKind.AssignmentExecuted, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.UCCFiled, termsHash);
        _attest(tokenId, IAttestationOracle.AttestationKind.CreditIssued, termsHash);

        vm.recordLogs();
        vm.prank(ops);
        uint256 originated = bridge.originate(actor, terms);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(originated, tokenId);
        assertTrue(_sawTopic(logs, keccak256("Originated(uint256,uint256,bytes32,bytes32)")));
    }

    function _repay(uint256 tokenId, uint256 interest, uint256 principal, uint64 nextDue) internal {
        bytes32 paymentId =
            keccak256(abi.encode("DEPLOYED_FORK_PAYMENT", tokenId, interest, principal, ++attestationNonce));
        uint256 usdcAmount = (interest + principal) / 1e12;
        bytes32 payload =
            keccak256(abi.encode(paymentId, tokenId, address(stable), actor, usdcAmount, interest, principal, nextDue));
        _attest(tokenId, IAttestationOracle.AttestationKind.PaymentReceived, payload);

        IWaterfallEngine.Payment memory payment = IWaterfallEngine.Payment({
            tokenId: tokenId,
            paymentId: paymentId,
            payer: actor,
            interest: interest,
            principal: principal,
            nextPaymentDue: nextDue
        });
        vm.recordLogs();
        vm.prank(ops);
        waterfall.distribute(payment);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_sawTopic(logs, keccak256("Distributed(uint256,bytes32,address,uint256,uint256,uint256,uint256)")));
        assertTrue(_sawTopic(logs, keccak256("PaymentReceived(uint256,address,uint256,uint256)")));
    }

    function _nextDue(uint256 tokenId, uint256 principal) internal view returns (uint64) {
        ClaimBridge.Facility memory f = bridge.facility(tokenId);
        if (principal == reserves.deployedTo(tokenId)) return 0;
        uint64 next = f.nextPaymentDue + f.paymentInterval;
        return next > f.maturity ? f.maturity : next;
    }

    function _attest(uint256 facilityId, IAttestationOracle.AttestationKind kind, bytes32 payload) internal {
        IAttestationOracle.AttestationInput memory input = IAttestationOracle.AttestationInput({
            facilityId: facilityId,
            kind: kind,
            payload: payload,
            asOf: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 2 hours),
            nonce: uint256(keccak256(abi.encode(facilityId, kind, payload, ++attestationNonce)))
        });
        bytes32 digest = oracle.attestationDigest(input);
        (uint256 low, uint256 high) = vm.addr(ATTESTER_PK_1) < vm.addr(ATTESTER_PK_2)
            ? (ATTESTER_PK_1, ATTESTER_PK_2)
            : (ATTESTER_PK_2, ATTESTER_PK_1);
        uint8 threshold = oracle.threshold(kind);
        bytes[] memory signatures = new bytes[](threshold);
        signatures[0] = _sign(low, digest);
        if (threshold > 1) signatures[1] = _sign(high, digest);
        oracle.attest(input, signatures);
        assertTrue(oracle.isSatisfied(facilityId, kind));
    }

    function _prepareAttesters() internal {
        vm.startPrank(ops);
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(ATTESTER_PK_1));
        oracle.grantRole(Roles.ATTESTER_ROLE, vm.addr(ATTESTER_PK_2));
        vm.stopPrank();
    }

    function _permit(IERC20Permit token, uint256 ownerPk, address owner, address spender, uint256 value) internal {
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(IERC20(address(token)).allowance(owner, spender), value);
        vm.expectRevert();
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function _sGroveDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            sGrove.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _groveDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            grove.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _mintUsdfr(address recipient, uint256 usdcAmount) internal returns (uint256 amount) {
        stable.mint(recipient, usdcAmount);
        vm.startPrank(recipient);
        stable.approve(address(controller), usdcAmount);
        amount = controller.mint(usdcAmount);
        vm.stopPrank();
    }

    function _allow(address account) internal {
        vm.prank(ops);
        compliance.setAllowed(account, true);
        assertTrue(compliance.isAllowed(account));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertCode() internal view {
        assertGt(address(stable).code.length, 0);
        assertGt(address(usdfr).code.length, 0);
        assertGt(address(vault).code.length, 0);
        assertGt(address(controller).code.length, 0);
        assertGt(address(reserves).code.length, 0);
        assertGt(address(queue).code.length, 0);
        assertGt(address(compliance).code.length, 0);
        assertGt(address(points).code.length, 0);
        assertGt(address(grove).code.length, 0);
        assertGt(address(sGrove).code.length, 0);
        assertGt(address(oracle).code.length, 0);
        assertGt(address(bridge).code.length, 0);
        assertGt(address(registry).code.length, 0);
        assertGt(address(curator).code.length, 0);
        assertGt(address(waterfall).code.length, 0);
        assertGt(address(defaults).code.length, 0);
        assertGt(address(assessedImpairment).code.length, 0);
    }

    function _sawTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENT_MANIFEST", string("deployments/11155111.json"));
    }
}

contract ToggleImpairmentSource {
    bool internal broken;

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function pendingSeniorImpairment() external view returns (uint256) {
        require(!broken, "toggle impairment source broken");
        return 0;
    }

    function performanceFeeImpairment() external view returns (uint256) {
        require(!broken, "toggle impairment source broken");
        return 0;
    }
}
