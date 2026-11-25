# ADR-0044: Solana curator subscription vault (devnet preview)

**Status:** Implemented on Solana devnet (`3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`;
Corrovera external review and two re-verifications completed 20 September 2026); **not deployed on
Solana mainnet** pending specialist Solana review, counsel sign-off, 2-of-4 Squads multisig and
emergency-signer setup.

**Date:** 2026-09-20 (recorded 2026-11-25)

## Context

First-loss curator participation on Ethereum runs natively through `CuratorModule`. To allow
Solana-native bilateral curators to record principal commitments, lock periods and withdrawal
notice on chain under bilateral agreements with Forest Road, a dedicated Anchor program was
designed and built alongside Ethereum V2.

## Decision

1. **Dedicated Anchor vault program.** The Solana curator vault records curator subscriptions,
   minimum commitment windows, withdrawal notice timers and draw accounting on chain without
   altering Ethereum's three-layer loss cascade (`curator first-loss → sGROVE → sUSDfr`).
2. **Reproducible build & artifact pinning.** Release artifacts are built inside a digest-pinned
   `solana-verify` container (explicit SBF v3 / platform-tools v1.57) and pinned by ELF SHA-256
   (`c3f365f888cda2daf06bbf8339c7e8ea89cd090b2dac030367f346e78f3b450e`) and IDL hash against the
   on-chain devnet ProgramData account.
3. **Strict mainnet launch gates.** Corrovera's 20 September 2026 review closed all program-source
   and test-assurance findings (25 instructions, 38 errors, 23 events, 9 compiled program mutation
   controls). Solana mainnet launch remains separately gated on specialist Solana review, legal
   counsel approval, and multisig/emergency-halt ceremony completion.

## Consequences

- Solana curator subscriptions are previewed transparently on `/curators` with devnet status and
  mainnet gates disclosed explicitly; no mainnet deposits are accepted on Solana until all gates
  clear.
