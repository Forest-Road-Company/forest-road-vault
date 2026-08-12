// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ComplianceRegistry} from "../../../src/ComplianceRegistry.sol";
import {MintRedeemController} from "../../../src/MintRedeemController.sol";
import {ReserveManager} from "../../../src/ReserveManager.sol";
import {SUSDfr} from "../../../src/sUSDfr.sol";
import {USDfr} from "../../../src/USDfr.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";

/// @dev Bounded handler for token-layer stateful fuzzing. `fail_on_revert = true`
///      (foundry.toml): every path below is bounded so it can NEVER revert — a revert
///      here is itself a finding.
contract TokenLayerHandler is Test {
    MockERC20 internal usdc;
    USDfr internal usdfr;
    ComplianceRegistry internal compliance;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    address internal creditModule;
    address internal guardian;
    address internal governance;

    address[3] public actors;
    uint256[4] public facilities = [uint256(1), 2, 3, 4];

    // ── ghost state ──────────────────────────────────────────────────────
    uint256 public rateFloor; // reset on explicit loss or evented vault-fee dilution
    uint256 public callCount;

    // AUDIT C4-USDFR-02 ghosts. `pausedUserOutflows` and `pausedUserSupplyDrops` MUST stay at
    // zero; `pausedUserProbes` proves the illegal region was actually entered rather than
    // filtered away at the top of the action (the campaign-5 lesson).
    uint256 public pausedUserProbes;
    uint256 public pausedUserOutflows;
    uint256 public pausedUserSupplyDrops;
    // Liveness counterweight: the loss cascade must remain executable UNDER the pause.
    uint256 public pausedCascadeProbes;
    uint256 public pausedCascadeBurnsBlocked;

    // AUDIT C4-USDFR-01 ghosts. `codelessPointsInstalls` and `tokenBrickedByPointsModule` MUST
    // stay at zero; `codelessPointsProbes` proves the region was entered.
    uint256 public codelessPointsProbes;
    uint256 public codelessPointsInstalls;
    uint256 public tokenBrickedByPointsModule;

    constructor(
        MockERC20 usdc_,
        USDfr usdfr_,
        ComplianceRegistry compliance_,
        ReserveManager reserves_,
        MintRedeemController controller_,
        SUSDfr vault_,
        address complianceAdmin_,
        address creditModule_,
        address guardian_,
        address governance_
    ) {
        guardian = guardian_;
        governance = governance_;
        usdc = usdc_;
        usdfr = usdfr_;
        compliance = compliance_;
        reserves = reserves_;
        controller = controller_;
        vault = vault_;
        creditModule = creditModule_;

        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        vm.startPrank(complianceAdmin_);
        for (uint256 i = 0; i < 3; ++i) {
            compliance.setAllowed(actors[i], true);
        }
        vm.stopPrank();
        rateFloor = vault.currentExchangeRate();
    }

    // ── bounded operations ───────────────────────────────────────────────

    function mint(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        amount = bound(amount, 1, 10_000_000e6);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(controller), amount);
        controller.mint(amount);
        vm.stopPrank();
        callCount++;
    }

    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        uint256 idleUSDC = usdc.balanceOf(address(reserves));
        uint256 max = bal < idleUSDC * 1e12 ? bal : idleUSDC * 1e12;
        if (max < 1e12) return; // nothing redeemable without reverting
        amount = bound(amount, 1e12, max);
        vm.prank(actor);
        controller.redeem(amount);
        callCount++;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        // AUDIT H-3 (remediation + residual): the vault CLOSES to new capital in the DEGENERATE
        // state (deposit base collapsed to zero, or dwarfed by the stranded unvested-yield stream).
        // This handler reaches it via a maximal `realizeLoss`, and the vault then reverts
        // `SUSDfr_DegenerateSharePrice`. Skip rather than revert, per `fail_on_revert = true`.
        if (vault.maxDeposit(address(this)) == 0) return;
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 feeSharesBefore = vault.balanceOf(vault.feeRecipient());
        vm.startPrank(actor);
        usdfr.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();
        // A deposit checkpoints any pending protocol fee before it prices the
        // entrant. Accept exactly that evented dilution as the new rate floor.
        if (vault.balanceOf(vault.feeRecipient()) > feeSharesBefore) {
            rateFloor = vault.currentExchangeRate();
        }
        callCount++;
    }

    function deployPrincipal(uint256 facilitySeed, uint256 amount) external {
        uint256 facilityId = facilities[facilitySeed % 4];
        uint256 idle = usdc.balanceOf(address(reserves));
        if (idle == 0) return;
        amount = bound(amount, 1, idle);
        vm.prank(creditModule);
        reserves.recordDeployment(facilityId, makeAddr("escrow"), amount);
        callCount++;
    }

    function returnPrincipal(uint256 facilitySeed, uint256 amount) external {
        uint256 facilityId = facilities[facilitySeed % 4];
        uint256 deployed = reserves.deployedTo(facilityId);
        if (deployed < 1e12) return;
        amount = bound(amount, 1e12, deployed);
        amount -= amount % 1e12; // whole USDC units so the stable inflow matches exactly
        if (amount == 0) return;
        address payer = actors[0];
        usdc.mint(payer, amount / 1e12);
        vm.prank(payer);
        usdc.approve(address(reserves), amount / 1e12);
        vm.prank(creditModule);
        reserves.recordPayment(facilityId, payer, amount / 1e12, amount);
        callCount++;
    }

    function receiveInterest(uint256 amount) external {
        amount = bound(amount, 1, 100_000e6);
        usdc.mint(creditModule, amount);
        vm.startPrank(creditModule);
        usdc.approve(address(reserves), amount);
        reserves.depositUSDC(creditModule, amount);
        vm.stopPrank();
        vm.prank(creditModule);
        controller.mintYield(address(vault), amount * 1e12);
        callCount++;
    }

    function realizeLoss(uint256 facilitySeed, uint256 amount) external {
        uint256 facilityId = facilities[facilitySeed % 4];
        uint256 deployed = reserves.deployedTo(facilityId);
        uint256 vaultBal = usdfr.balanceOf(address(vault));
        uint256 max = deployed < vaultBal ? deployed : vaultBal;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        // atomic: write down backing AND burn the absorbing layer (vault stands in
        // for the cascade until Phase E)
        vm.startPrank(creditModule);
        reserves.recordPrincipalWritedown(facilityId, amount);
        controller.burnLoss(address(vault), amount);
        vm.stopPrank();
        // An explicit loss resets the fee-aware floor.
        rateFloor = vault.currentExchangeRate();
        callCount++;
    }

    function donateToVault(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 bal = usdfr.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        usdfr.transfer(address(vault), amount);
        callCount++;
    }

    function transferBetweenActors(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 bal = usdfr.balanceOf(from);
        if (bal == 0 || from == to) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        usdfr.transfer(to, amount);
        callCount++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 90 days);
        vm.warp(block.timestamp + secs);
        callCount++;
    }

    // ── AUDIT C4-USDFR-02: drive the ILLEGAL region (a paused user outflow) ──

    /// @dev Pauses USDfr and then tries to settle an ordinary holder's redemption. There is NO
    ///      pre-filter: the action FUNDS a redeemable position itself, so every single call
    ///      reaches the region the guard is supposed to close. A handler that returned early
    ///      whenever the fuzzer had not happened to produce a position would make
    ///      `invariant_pause_settlesNoUserOutflow` decoration.
    ///      Ghost contract: `pausedUserOutflows` / `pausedUserSupplyDrops` must remain zero.
    function pausedUserRedeem(uint256 actorSeed, uint256 seed) external {
        address actor = actors[actorSeed % 3];
        uint256 usdcIn = bound(seed, 1e6, 1_000_000e6);
        usdc.mint(actor, usdcIn);
        vm.startPrank(actor);
        usdc.approve(address(controller), usdcIn);
        controller.mint(usdcIn);
        vm.stopPrank();

        uint256 bal = usdfr.balanceOf(actor);
        uint256 idle = usdc.balanceOf(address(reserves)) * 1e12;
        uint256 redeemable = bal < idle ? bal : idle;
        redeemable -= redeemable % 1e12; // whole USDC units; >= 1e18 by construction

        if (!usdfr.paused()) {
            vm.prank(guardian);
            usdfr.pause();
        }
        pausedUserProbes++;

        uint256 supplyBefore = usdfr.totalSupply();
        vm.prank(actor);
        try controller.redeem(redeemable) returns (uint256) {
            pausedUserOutflows++;
        } catch {}
        if (usdfr.totalSupply() < supplyBefore) pausedUserSupplyDrops++;

        vm.prank(guardian);
        usdfr.unpause();
        callCount++;
    }

    /// @dev LIVENESS COUNTERWEIGHT to `pausedUserRedeem`: the same pause must NOT freeze the
    ///      loss cascade. The vault is a governance-listed protocol module, so
    ///      `burnLoss(vault, x)` — the shape `DefaultManager` uses — must still execute. Ghost
    ///      contract: `pausedCascadeBurnsBlocked` must remain zero.
    function pausedCascadeBurn(uint256 facilitySeed, uint256 seed) external {
        uint256 facilityId = facilities[facilitySeed % 4];

        // Manufacture a genuinely absorbable loss rather than filtering the action away when
        // the fuzzer has not produced one: fund the vault with USDfr and deploy matching
        // principal, so `max` is always non-zero and the region is always entered.
        uint256 usdcIn = bound(seed, 1e6, 100_000e6);
        address funder = actors[0];
        usdc.mint(funder, usdcIn);
        vm.startPrank(funder);
        usdc.approve(address(controller), usdcIn);
        controller.mint(usdcIn);
        usdfr.transfer(address(vault), usdcIn * 1e12);
        vm.stopPrank();
        vm.prank(creditModule);
        reserves.recordDeployment(facilityId, makeAddr("cascadeEscrow"), usdcIn);

        uint256 deployed = reserves.deployedTo(facilityId);
        uint256 vaultBal = usdfr.balanceOf(address(vault));
        uint256 amount = deployed < vaultBal ? deployed : vaultBal;
        amount = bound(seed, 1, amount);

        if (!usdfr.paused()) {
            vm.prank(guardian);
            usdfr.pause();
        }
        pausedCascadeProbes++;

        // Burn first, then write the backing down: a burn without a matching write-down only
        // ever moves supply DOWN relative to backing, so `_assertBacking` cannot trip on the
        // intermediate state, and a blocked burn leaves backing untouched.
        bool burned;
        vm.startPrank(creditModule);
        try controller.burnLoss(address(vault), amount) {
            burned = true;
        } catch {
            pausedCascadeBurnsBlocked++;
        }
        if (burned) reserves.recordPrincipalWritedown(facilityId, amount);
        vm.stopPrank();

        vm.prank(guardian);
        usdfr.unpause();
        if (burned) rateFloor = vault.currentExchangeRate(); // an explicit loss resets the floor
        callCount++;
    }

    // ── AUDIT C4-USDFR-01: drive the ILLEGAL region (a codeless points module) ──

    /// @dev Asks governance to install a fuzz-derived address as the points module and then
    ///      probes a transfer that MUST succeed. No pre-filter: the funding happens BEFORE the
    ///      install (a bricked token cannot mint), and the probe runs unconditionally. Ghost
    ///      contract: `codelessPointsInstalls` and `tokenBrickedByPointsModule` must stay zero.
    function installCodelessPointsModule(uint256 addrSeed, uint256 actorSeed, uint256 seed) external {
        uint256 idx = actorSeed % 3;
        address actor = actors[idx];
        // reduce BEFORE adding: `actorSeed + 1` panics on `type(uint256).max`, and the fuzzer
        // reaches that boundary — `fail_on_revert = true` makes a handler panic a suite failure
        address counterparty = actors[(idx + 1) % 3];
        uint256 usdcIn = bound(seed, 1e6, 1_000e6);
        usdc.mint(actor, usdcIn);
        vm.startPrank(actor);
        usdc.approve(address(controller), usdcIn);
        controller.mint(usdcIn);
        vm.stopPrank();

        address candidate = address(uint160(bound(addrSeed, 1, type(uint160).max)));
        codelessPointsProbes++;
        vm.prank(governance);
        try usdfr.setPointsModule(candidate) {
            if (candidate.code.length == 0) codelessPointsInstalls++;
        } catch {}

        vm.prank(actor);
        try usdfr.transfer(counterparty, 1) {}
        catch {
            tokenBrickedByPointsModule++;
        }

        // Restore, so a brick cannot cascade into unrelated actions and mask itself as a
        // generic `fail_on_revert` failure instead of the named ghost above.
        vm.prank(governance);
        usdfr.setPointsModule(address(0));
        callCount++;
    }

    // ── reconciliation views for the invariants ──────────────────────────

    function sumDeployed() external view returns (uint256 total) {
        for (uint256 i = 0; i < 4; ++i) {
            total += reserves.deployedTo(facilities[i]);
        }
    }

    function sumActorBalances() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += usdfr.balanceOf(actors[i]);
        }
    }
}
