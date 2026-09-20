// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title KnownTestnets
/// @notice The single allowlist of chain-ids the TESTNET tooling (`Deploy.s.sol`,
///         `Handover.s.sol`) may run against. Every other chain-id is refused.
/// @dev CLAUDE.md prime directive 1 says coding agents never broadcast to mainnet. Until
///      2026-09-07 the testnet scripts implemented that as `block.chainid != 1`, which refused
///      Ethereum mainnet and nothing else: BNB Smart Chain (56), Base (8453), Polygon (137) or
///      any other chain carrying real value would have passed the guard and reached the
///      mock-stablecoin, retained-admin deployment path. Scoping the second-chain work in
///      ADR-0037 surfaced that, so the guard is now an allowlist. Adding a chain-id here is a
///      deliberate, reviewed act, never a side effect of pointing an RPC somewhere new.
///
///      BNB Smart Chain testnet (97) is NOT listed. It joins only if ADR-0037 is accepted, so
///      that no BSC broadcast of any kind is possible from this tooling before that decision.
library KnownTestnets {
    /// @notice Whether `chainId` is a chain this repository treats as a testnet.
    /// @param chainId The chain-id to classify.
    /// @return isTestnet True only for the allowlisted testnets and the local anvil chain-id.
    function isKnownTestnet(uint256 chainId) internal pure returns (bool isTestnet) {
        return chainId == 11155111 // Ethereum Sepolia (the live testnet for this repo)
            || chainId == 31337 // anvil / forge
            || chainId == 17000 // Holesky
            || chainId == 84532 // Base Sepolia
            || chainId == 11155420 // OP Sepolia
            || chainId == 421614; // Arbitrum Sepolia
    }
}
