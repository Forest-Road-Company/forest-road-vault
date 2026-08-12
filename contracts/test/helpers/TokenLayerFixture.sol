// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockCascadeBackstop} from "./MockCascadeBackstop.sol";
import {MockReserveLossAbsorber} from "./MockReserveLossAbsorber.sol";
import {MockReserveLossCurator, MockReserveLossGovernor, MockReserveLossTimelock} from "./MockReserveLossModules.sol";

/// @dev Deploys the full token layer behind ERC1967 proxies with a realistic role
///      topology, mirroring what the deployment script will do:
///      - `admin` plays the governance timelock (DEFAULT_ADMIN + UPGRADER everywhere)
///      - `guardian` holds pause powers
///      - `complianceAdmin` manages KYC lists
///      - `creditModule` stands in for the Phase D/E credit layer (CREDIT_ROLE)
///      - the controller holds MINTER on USDfr and CONTROLLER on the reserves.
abstract contract TokenLayerFixture is Test {
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    /// @dev Holder of `SETTLEMENT_KEEPER_ROLE` (AUDIT FIX D7-01): the only party that may drive
    ///      `RedemptionQueue.closeEpoch`. Distinct from `admin` on purpose, so a test cannot pass
    ///      by accidentally holding admin.
    address internal settlementKeeper = makeAddr("settlementKeeper");
    address internal complianceAdmin = makeAddr("complianceAdmin");
    address internal creditModule = makeAddr("creditModule");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol"); // NOT KYC-allowed
    address internal borrower = makeAddr("borrower");

    ComplianceRegistry internal compliance;
    USDfr internal usdfr;
    ReserveManager internal reserves;
    MintRedeemController internal controller;
    SUSDfr internal vault;
    MockReserveLossCurator internal reserveLossCurator;
    MockCascadeBackstop internal reserveLossBackstop;
    MockReserveLossGovernor internal reserveLossGovernor;
    MockReserveLossTimelock internal reserveLossTimelock;
    MockReserveLossAbsorber internal reserveLossAbsorber;

    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal dai; // 18 decimals

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        // ── implementations + proxies ────────────────────────────────────
        compliance = ComplianceRegistry(
            address(
                new ERC1967Proxy(
                    address(new ComplianceRegistry()),
                    abi.encodeCall(ComplianceRegistry.initialize, (admin, complianceAdmin, admin, feeRecipient))
                )
            )
        );

        // USDfr needs the controller address; deploy proxies in dependency order by
        // pre-computing nothing — instead: deploy USDfr with a placeholder minter is
        // NOT acceptable (roles must be exact), so deploy reserves+controller first
        // with CREATE-address forecasting avoided by wiring roles after: USDfr grants
        // MINTER to the controller once known, via admin. Simplest faithful order:
        usdfr = USDfr(
            address(
                new ERC1967Proxy(
                    address(new USDfr()),
                    // minter placeholder = admin; replaced by controller grant below,
                    // and admin renounces the placeholder MINTER_ROLE.
                    abi.encodeCall(USDfr.initialize, (admin, admin, guardian, admin))
                )
            )
        );

        reserves = ReserveManager(
            address(
                new ERC1967Proxy(
                    address(new ReserveManager()),
                    abi.encodeCall(ReserveManager.initialize, (admin, admin, guardian, admin, address(usdc)))
                )
            )
        );

        controller = MintRedeemController(
            address(
                new ERC1967Proxy(
                    address(new MintRedeemController()),
                    abi.encodeCall(
                        MintRedeemController.initialize,
                        (admin, guardian, admin, address(usdfr), address(compliance), address(reserves))
                    )
                )
            )
        );

        vault = SUSDfr(
            address(
                new ERC1967Proxy(
                    address(new SUSDfr()),
                    abi.encodeCall(
                        SUSDfr.initialize, (admin, guardian, admin, address(usdfr), address(compliance), feeRecipient)
                    )
                )
            )
        );

        reserveLossCurator = new MockReserveLossCurator(IERC20(address(usdfr)), address(vault), address(reserves));
        reserveLossBackstop = new MockCascadeBackstop(IERC20(address(usdfr)));
        reserveLossTimelock = new MockReserveLossTimelock();
        reserveLossGovernor = new MockReserveLossGovernor(address(reserveLossTimelock));
        reserveLossAbsorber = new MockReserveLossAbsorber(controller, address(vault), address(reserves));

        // ── role wiring (as the deploy script will do; validated post-deploy) ─
        vm.startPrank(admin);
        usdfr.grantRole(Roles.MINTER_ROLE, address(controller));
        usdfr.renounceRole(Roles.MINTER_ROLE, admin); // no leftover deployer privileges
        reserves.grantRole(Roles.CONTROLLER_ROLE, address(controller));
        reserves.grantRole(Roles.CREDIT_ROLE, creditModule);
        // AUDIT FIX (R16-M1): `burnLoss` moved off CREDIT_ROLE onto LOSS_BURNER_ROLE, and both
        // endpoints are now governance-named. This mirrors `Deploy.s.sol`: `creditModule` stands
        // in for DefaultManager (mints yield AND burns loss from itself / the vault), and the
        // absorber stands in for its reserve-loss hook (burns the vault only).
        controller.grantRole(Roles.CREDIT_ROLE, creditModule);
        controller.grantRole(Roles.LOSS_BURNER_ROLE, creditModule);
        controller.grantRole(Roles.LOSS_BURNER_ROLE, address(reserveLossAbsorber));
        controller.grantRole(Roles.LOSS_BURNER_ROLE, address(reserves));
        controller.setYieldSink(address(vault), true);
        controller.setYieldSink(feeRecipient, true);
        controller.setLossSource(address(vault), true);
        // AUDIT FIX (R17): `creditModule` is an EOA and is no longer listable as a loss source —
        // `setLossSource` refuses a codeless account, because listing a wallet would restore
        // finding M2 (a forced, non-pro-rata seizure of one named holder) in one routine-looking
        // timelock transaction. No test in the tree burns FROM `creditModule`; it burns from the
        // vault, exactly as `DefaultManager` does. `reserveLossAbsorber` below is the contract
        // stand-in for the cascade's reserve-loss hook.
        controller.setLossSource(address(reserveLossAbsorber), true);
        controller.setLossSource(address(reserves), true);
        reserves.setLossController(address(controller));
        reserves.setLossAbsorber(address(reserveLossAbsorber));
        reserves.setReserveLossModules(
            address(reserveLossCurator),
            address(reserveLossBackstop),
            address(vault),
            address(reserveLossGovernor),
            address(reserveLossTimelock)
        );
        vm.stopPrank();

        // ── stables ──────────────────────────────────────────────────────
        dai = new MockERC20("Dai", "DAI", 18);

        // ── KYC ──────────────────────────────────────────────────────────
        vm.startPrank(complianceAdmin);
        compliance.setAllowed(alice, true);
        compliance.setAllowed(bob, true);
        // carol deliberately NOT allowed
        vm.stopPrank();

        // ── balances ─────────────────────────────────────────────────────
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);
        dai.mint(alice, 1_000_000e18);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev Alice mints `usdfrAmount` (18-dec) of USDfr via USDC.
    function _mintUSDfr(address user, uint256 usdcAmount) internal returns (uint256 out) {
        vm.startPrank(user);
        usdc.approve(address(controller), usdcAmount);
        out = controller.mint(usdcAmount);
        vm.stopPrank();
    }

    /// @dev Simulates an attested interest receipt: stables arrive in the treasury
    ///      (backing up), then the credit layer mints the matching yield to `to`.
    function _receiveYield(address to, uint256 usdcAmount) internal {
        usdc.mint(creditModule, usdcAmount);
        vm.prank(creditModule);
        usdc.approve(address(reserves), usdcAmount);
        vm.prank(creditModule);
        reserves.depositUSDC(creditModule, usdcAmount);
        vm.prank(creditModule);
        controller.mintYield(to, usdcAmount * 1e12);
    }

    /// @dev AUDIT FIX (R16-M1). Names an extra `mintYield` destination, for the handful of suites
    ///      that deliberately deliver yield somewhere other than the vault or the fee recipient.
    function _authorizeYieldSink(address account) internal {
        vm.prank(admin);
        controller.setYieldSink(account, true);
    }

    /// @dev AUDIT FIX (R16-M1/M2). Names an extra `burnLoss` source.
    function _authorizeLossSource(address account) internal {
        vm.prank(admin);
        controller.setLossSource(account, true);
    }

    function _armReserveLoss(uint256 context) internal returns (uint256 armId, uint256 incidentId) {
        vm.prank(guardian);
        (armId, incidentId) = reserves.armReserveLossFreeze(keccak256(abi.encode("custody-loss-arm", context)));
    }

    function _createReserveShortfall(uint256 value) internal {
        uint256 units = reserves.denormalizeUSDC(value);
        vm.prank(address(reserves));
        usdc.transfer(borrower, units);
    }

    function _ratifyCurrentReserveLoss(uint256 approvedMaxLoss)
        internal
        returns (uint256 incidentId, uint256 actualLoss)
    {
        (uint256 armId,, bytes32 evidenceHash,) = reserves.reserveLossArm();
        vm.prank(admin);
        (incidentId, actualLoss) = reserves.ratifyAndOpen(armId, evidenceHash, approvedMaxLoss);
    }

    function _openReserveLossIncident(uint256 incidentNonce) internal returns (uint256 incidentId) {
        vm.prank(admin);
        incidentId =
            reserves.openReserveLossIncident(incidentNonce, keccak256(abi.encode("custody-loss", incidentNonce)));
    }
}
