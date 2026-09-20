// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ClaimBridge} from "../ClaimBridge.sol";
import {Config} from "./Config.sol";
import {DefaultManager} from "../DefaultManager.sol";
import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {ICommitmentLedger} from "../interfaces/ICommitmentLedger.sol";
import {ICuratorModule} from "../interfaces/ICuratorModule.sol";
import {IDefaultManager} from "../interfaces/IDefaultManager.sol";
import {IMintRedeemController} from "../interfaces/IMintRedeemController.sol";
import {IReserveManager} from "../interfaces/IReserveManager.sol";

/// @title DefaultInitLib - the DefaultManager's one-shot wiring body
///
/// @notice EXTRACTED 2026-09-10 FOR EIP-170, following the `ReserveCreditLib` precedent set on
///         2026-09-09. The Ethereum `DefaultManager` was measured at 24,848 bytes after the PIK
///         crank-liveness guard landed, 272 over the 24,576 limit. Working backwards from the last
///         green `check-contract-sizes` run, it had roughly 76 bytes of margin BEFORE that change,
///         so it was already frozen against any new function and nothing in the repository said so.
///         The BSC twin measured 22,830 (margin 1,746) and is not affected.
///
/// @dev WHY `initialize` AND NOT A CASCADE FUNCTION. The obvious candidates by size are
///      `realizeLoss` and `absorbReserveLoss`, and both were rejected for this pass: they are the
///      loss cascade, they are the most heavily audited paths in the contract, and moving them
///      behind a delegatecall is a change that deserves review rather than a late-night commit.
///      `initialize` is the opposite kind of code. It runs exactly once, at deployment, and EVERY
///      test fixture in the repository calls it in `setUp`, so a mistake here does not hide: it
///      fails the entire suite immediately and loudly.
///
/// @dev EVERY FUNCTION HERE IS `public` AND THAT IS THE WHOLE POINT. A `public` library function is
///      deployed as its own contract and reached by delegatecall, so its bytecode leaves the
///      caller's runtime; an `internal` one is inlined and saves nothing. This library therefore
///      needs LINKING at deploy time, exactly as `ReserveCreditLib` does.
///
/// @dev WHAT STAYED BEHIND, and why. The `initializer` modifier, `__AccessControl_init` and its
///      siblings, and `_grantRole` are all internal members of the inherited OpenZeppelin
///      contracts, which a library cannot reach. They remain in `DefaultManager.initialize`, which
///      keeps the initialisation guard and the role grants exactly where an auditor expects them.
///      `commitmentLedgerFactory` is an `immutable` on the implementation and a delegatecall
///      library cannot read the caller's immutables, so the freshly created ledger address is
///      passed in as an argument rather than created here.
library DefaultInitLib {
    /// @notice Validates the module set and writes it into namespaced storage, then seeds every
    ///         class with its default cure and grace windows.
    ///
    /// @param $ The manager's ERC-7201 storage struct, reached by delegatecall in the proxy.
    /// @param m The wired protocol modules.
    /// @param ledger The commitment ledger the caller created from its immutable factory.
    ///
    /// @dev The zero-address check covers the module set only. `admin`, `guardian` and `upgrader`
    ///      are checked by the caller, because it is the caller that grants them roles and the
    ///      check belongs next to the use.
    function wire(DefaultManager.DefaultStorage storage $, DefaultManager.InitModules calldata m, address ledger)
        public
    {
        if (
            m.bridge == address(0) || m.registry == address(0) || m.reserves == address(0) || m.controller == address(0)
                || m.curator == address(0) || m.oracle == address(0) || m.usdfr == address(0) || m.vault == address(0)
        ) revert IDefaultManager.DefaultManager_ZeroAddress();

        $.bridge = ClaimBridge(m.bridge);
        $.registry = ICollateralRegistry(m.registry);
        $.reserves = IReserveManager(m.reserves);
        $.controller = IMintRedeemController(m.controller);
        $.curator = ICuratorModule(m.curator);
        $.oracle = IAttestationOracle(m.oracle);
        $.usdfr = IERC20(m.usdfr);
        $.vault = m.vault;
        $.commitmentLedger = ICommitmentLedger(ledger);

        for (uint256 classId = 1; classId <= Config.NUM_CLASSES; ++classId) {
            $.cureWindows[classId] = Config.DEFAULT_MARGIN_CURE_WINDOW;
            emit IDefaultManager.CureWindowSet(classId, Config.DEFAULT_MARGIN_CURE_WINDOW);
            // AUDIT FIX (H-5), moved here with the loop on 2026-09-10: the past-due grace window
            // defaults to (and is capped at) the redemption cooldown. Governance may only ever
            // lower it (see `DefaultManager.setGraceWindow`'s cap). The cap bounds the
            // maturity-anchored marking lag; it does NOT fully cover the request-anchored
            // redemption cooldown (a partial par-exit window survives, and is documented).
            $.graceWindows[classId] = Config.DEFAULT_REDEEM_COOLDOWN;
            emit IDefaultManager.GraceWindowSet(classId, Config.DEFAULT_REDEEM_COOLDOWN);
        }
    }
}
