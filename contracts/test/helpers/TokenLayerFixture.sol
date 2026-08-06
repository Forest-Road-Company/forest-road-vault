// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MintRedeemController} from "../../src/MintRedeemController.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SUSDfr} from "../../src/sUSDfr.sol";
import {USDfr} from "../../src/USDfr.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockERC20} from "./MockERC20.sol";

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

        // ── role wiring (as the deploy script will do; validated post-deploy) ─
        vm.startPrank(admin);
        usdfr.grantRole(Roles.MINTER_ROLE, address(controller));
        usdfr.renounceRole(Roles.MINTER_ROLE, admin); // no leftover deployer privileges
        reserves.grantRole(Roles.CONTROLLER_ROLE, address(controller));
        reserves.grantRole(Roles.CREDIT_ROLE, creditModule);
        controller.grantRole(Roles.CREDIT_ROLE, creditModule);
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
}
