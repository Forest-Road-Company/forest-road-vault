# Public source provenance — 20 September 2026

This release was assembled from committed trees through an explicit allowlist. Private repository
history was not merged into this public repository.

| Surface | Source commit | Git tree | Files | Public transformation |
|---|---|---:|---:|---|
| Ethereum v2 production contracts | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` | `3095b3b8acac7a511b86681036f80709225d6353` | 81 | None under `contracts/src/`. This tree is unchanged from the fresh v2 deployment source. |
| Frontend | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` | `28df71b9de5c6f809a5d920e6e5b5ebd4cf7e614` | 151 | None under `frontend/`. |
| Solana program package | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` | `914a43321127389ce05a433594032e3b02ff9092` | 14 | None under `programs/`. Signed devnet deployment and rehearsal entrypoints are excluded from the public package. |
| Solana deployed program source | `7c4b9589f80fcaf88a9a0393ecc096dfe1f46bd8` | `dfcb94b6b04a5f874a7c837fd18af74d14d68471` | 8 | The production Rust source tree is unchanged at the later release commit; only its deployed-evidence test changed afterwards. |
| BNB Smart Chain production contracts | `448f5face2285fc620b62bae3e0458531fae14c5` | `e071d97c2e4b2ee86141e9cf72c2c6e54d0ed61c` | 77 | None under `bsc/contracts/src/`. Public remappings reuse the root dependency pins. |

Canonical Solana release artifacts:

- ELF: `4cf28ebf3b911a59d7807a852fb81a03fe6680af5ddc94bad74a981efdf3a605`
- IDL: `0f3c9bab4669da0f45a804bf97419c7957c836b9d384fe585a4ad0d61b9661e5`
- Devnet program: `3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`
- Final pinned amd64 release workflow receipt: run `35527334986`; its artifact bytes are committed here.

The public packaging scan examined 830 paths and found no blocking credential pattern. Ethereum's
published source/test closure and the BSC source package both compiled with Solidity 0.8.30, and
the published Ethereum unit campaign passed 1,810/1,810 tests across 161 suites. The frontend
passed 103 render tests and 463 contract-interface synchronization checks. The Solana package
passed 9 arithmetic tests, 24 lifecycle tests, its keyless deployed-evidence test, 7 operational
tests, the complete instruction/error/event census, and TypeScript checking.
