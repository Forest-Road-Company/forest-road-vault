// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CommitmentLedger} from "./CommitmentLedger.sol";

/// @title CommitmentLedgerFactory
/// @notice Keeps the per-manager ledger deployment out of the UUPS implementation's runtime
///         bytecode. The factory is deployed by `DefaultManager`'s implementation constructor;
///         each proxy initialization then creates a ledger owned by that proxy.
/// @dev Anyone may request a ledger for an address. A ledger has no funds and accepts state writes
///      only from its immutable manager, so permissionless factory use cannot affect a protocol
///      instance.
contract CommitmentLedgerFactory {
    function create(address manager) external returns (CommitmentLedger ledger) {
        ledger = new CommitmentLedger(manager);
    }
}
