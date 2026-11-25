# ADR-0046: AWS KMS policy-restricted signers for off-chain keepers and bots

**Status:** Accepted and deployed in production (liquidation bot migrated 22 October 2026;
queue keeper rotated 30 October 2026 via FRV-009; withdrawal signer path added 5 November 2026).

**Date:** 2026-10-30 (recorded 2026-11-25)

## Context

Early off-chain keepers (`queue-keeper`, `liquidation-bot`) and attester helpers relied on raw
secp256k1 private keys supplied via environment variables. A runtime environment compromise or
accidental secret log could exfiltrate the underlying private key permanently.

## Decision

1. **Hardware-backed AWS KMS signing.** Production automated signers (`queue-keeper`,
   `liquidation-bot`, attesters) sign transactions and EIP-712 payloads through dedicated AWS KMS
   keys with scoped IAM policies rather than raw private keys.
2. **Fail-closed startup guard.** Production keeper and bot services refuse to start if legacy
   raw `*PRIVATE_KEY*` environment variables are present, preventing accidental fallback to a raw
   hot key.
3. **On-chain role revocation.** Upon migration, legacy EOA signers (such as the original
   `SETTLEMENT_KEEPER_ROLE` EOA `0x1Df7Adb9911e59d78c023B09E68711F97e05f4Cc`) are revoked on chain
   through Timelock governance and replaced with the KMS-backed address (`0xd355EFFB157c59Ccd0Adf2B4BeB78d83bed3cEad`).
4. **Role separation for Treasury sweeps.** Liquidated collateral sweeps and residual USDC
   withdrawals use distinct authorization paths and target only the Governance/Treasury Safe.

## Consequences

- Compromising a service container cannot extract raw signing keys; revoking IAM credentials
  immediately cuts off signing access without requiring an emergency key-sweep race.
- Key management adds an operational dependency on AWS KMS availability; the Operations Safe
  remains a backup holder of `SETTLEMENT_KEEPER_ROLE` for liveness.
