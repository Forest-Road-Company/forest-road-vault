// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IContinuousAccrual
/// @notice Reserve-owned accounting and exact delivery of previously accrued interest.
/// @dev Separate from the legacy reserve interface so activation is explicit. Amounts are
///      normalized to 18 decimals. Delivery changes physical balances, never economic ownership.
interface IContinuousAccrual {
    /// @notice Modules bound to one independently backed chain instance.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Modules {
        address token;
        address controller;
        address vault;
        address waterfall;
        address bridge;
        address registry;
        address defaultManager;
    }

    /// @notice Constant-time accounting, capped at the first unprocessed schedule boundary.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Snapshot {
        uint256 gross;
        uint256 unposted;
        uint256 unissued;
        uint256 seniorUnissued;
        uint256 feeUnissued;
        address feeRecipient;
        uint64 accruedThrough;
        bool enabled;
        bool fresh;
    }

    /// @notice Vault-computed prices and permission for a neutral physical delivery.
    /// @dev entryAssets includes any unvested assets; assets is the ordinary share-price base.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct PricingState {
        uint256 assets;
        uint256 entryAssets;
        uint256 redemptionAssets;
        uint256 performanceAssets;
        uint256 feeAdjustedShares;
        bool materializationAllowed;
    }

    /// @notice One immutable, same-transaction permit and coherent public price snapshot.
    /// @dev Unselected amounts are zero. A zero/default inactive record grants no authority.
    /// @dev LAYOUT-FROZEN: embedded or array storage; changing its width shifts later live fields.
    struct Delivery {
        uint256 nonce;
        uint256 senior;
        uint256 fee;
        uint256 effectiveSupply;
        uint256 backing;
        uint256 recognizedBacking;
        PricingState pricing;
        address controller;
        address vault;
        address feeRecipient;
        uint64 accruedThrough;
        uint8 legs;
        bool active;
    }

    /// @notice Reads the configured module identities, including before activation.
    function accrualModules() external view returns (Modules memory);

    /// @notice Reads recognized income and its outstanding physical posting/issuance.
    function accrualSnapshot() external view returns (Snapshot memory);

    /// @notice Reads the current delivery permit, or an inactive default record.
    function accrualDelivery() external view returns (Delivery memory);

    /// @notice Refuses a price-sensitive write at an unresolved accrual boundary or operation.
    function requireAccrualFresh() external view;

    /// @notice Delivers selected existing claims: senior=1, fee=2, both=3.
    /// @dev No amount, destination, timestamp or fee rate is supplied by the caller.
    function materializeAccrued(uint8 legs) external returns (uint256 senior, uint256 fee);
}

/// @notice Token continuation accepting only the bound reserve's current exact permit.
interface IAccrualToken {
    /// @notice The immutable-once-configured accounting reserve, or zero before binding.
    function accrualReserve() external view returns (address);

    /// @notice Mints the selected legs of one unused, active delivery permit.
    function mintAccrued(uint256 nonce) external;
}

/// @notice Controller continuation, callable only by its configured reserve.
interface IAccrualController {
    /// @notice Relays one exact reserve-owned delivery permit to the token.
    function mintAccrued(uint256 nonce) external;
}

/// @notice Vault views needed to admit a neutral delivery without a guarded write callback.
interface IAccrualVault {
    /// @notice The immutable-once-configured accounting reserve, or zero before binding.
    function accrualReserve() external view returns (address);

    /// @notice Supplies a coherent price snapshot and current delivery admission state.
    function accrualPricingState() external view returns (IContinuousAccrual.PricingState memory);
}
