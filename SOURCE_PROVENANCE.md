# Public source provenance

This public repository is assembled from committed private trees strictly by allowlist
(`tools/publish-public-repo.mjs`). Private repository history is never merged into this public
repository.

## 25 November 2026 Documentation & Frontend Refresh

| Surface | Private Source Commit | Scope & Transformation |
|---|---|---|
| `frontend/` | `c6062178f81847dd408342b0279534c8eb88b8ab` | Exact allowlisted export (`--scope frontend`, parked KYC routes excluded, `UNDECIDED: 0`, `Secret scan: clean`). Includes Rounds 1–7 desktop/API/source convergence, Mobile Audit Passes 1–2 (`0C/0H/0M`), and 25 Nov documentation updates. |
| `SECURITY.md`, `PHASE_A_ARCHITECTURE.md`, `ADR/` (`0001`–`0048`), `docs/{access-control-matrix,threat-model,invariants,formal-methods-amenability,recovery-assessments-and-redemption-topups}.md` | `c6062178f81847dd408342b0279534c8eb88b8ab` | Allowlisted public security, architecture and ADR specifications refreshed to reflect live Ethereum V2, Morpho `/markets`, Phase 1 BSC OFT bridge (`ADR/0045`), AWS KMS signers (`ADR/0046`), staged Plan B `ee9b228a` (`ADR/0047`), and frontend `/api/rpc` + Blob CAS (`ADR/0048`). |
| `contracts/` | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` *(unchanged genesis closure)* | Preserved untouched at the verified compiling 20 September 2026 Ethereum V2 genesis snapshot so `contracts/test/` continues to compile cleanly offline. Post-genesis Ethereum V2 upgrades (`FRV-005`–`FRV-009`, `ADR-0040`, `SUSDfrExitValueOracle`) and staged November 2026 LMV Stage 2 components (`ee9b228a`, 38 runtimes) are verified directly on Etherscan and Sourcify (`exact_match`). |
| `bsc/contracts/` | `448f5face2285fc620b62bae3e0458531fae14c5` *(unchanged)* | Unlaunched standalone BSC credit-protocol source (`ADR/0037`). Distinct from the live Phase 1 Ethereum↔BSC LayerZero `SUSDfrOFT` token bridge (`ADR/0045`). |
| `solana/curator-vault/` | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` *(docs link corrected 25 Nov)* | Unchanged Rust/Anchor program and canonical devnet ELF artifact; corrected the ELF SHA-256 checksum recorded below and in `README.md` to match the committed `.so` binary (`c3f365f8...`). |

## Baseline Release Provenance — 20 September 2026

| Surface | Source commit | Git tree | Files | Public transformation |
|---|---|---:|---:|---|
| Ethereum v2 genesis contracts | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` | `3095b3b8acac7a511b86681036f80709225d6353` | 81 | None under `contracts/src/`. Matches the fresh Ethereum V2 genesis deployment (`block 26,006,832`). |
| Frontend (genesis baseline; refreshed above) | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` | `28df71b9de5c6f809a5d920e6e5b5ebd4cf7e614` | 151 | Superseded by the 25 November 2026 `frontend/` refresh above (`c6062178`). |
| Solana program package | `8bb9a658c0bb8b6ed5a6cadb0d10380004f98fd7` | `914a43321127389ce05a433594032e3b02ff9092` | 14 | None under `programs/`. Signed devnet deployment and rehearsal entrypoints are excluded from the public package. |
| Solana deployed program source | `7c4b9589f80fcaf88a9a0393ecc096dfe1f46bd8` | `dfcb94b6b04a5f874a7c837fd18af74d14d68471` | 8 | The production Rust source tree is unchanged at the later release commit; only its deployed-evidence test changed afterwards. |
| BNB Smart Chain production contracts | `448f5face2285fc620b62bae3e0458531fae14c5` | `e071d97c2e4b2ee86141e9cf72c2c6e54d0ed61c` | 77 | None under `bsc/contracts/src/`. Public remappings reuse the root dependency pins. |

Canonical Solana release artifacts (verified directly against `solana/curator-vault/deployments/artifacts/forestroad_curator_vault.so`):

- ELF (475,824 bytes, SHA-256): `c3f365f888cda2daf06bbf8339c7e8ea89cd090b2dac030367f346e78f3b450e` *(corrected 25 November 2026 from an earlier pre-remediation hash `4cf28ebf...` that had drifted behind the committed canonical artifact)*
- IDL (SHA-256): `0f3c9bab4669da0f45a804bf97419c7957c836b9d384fe585a4ad0d61b9661e5`
- Devnet program: `3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`
- Final pinned amd64 release workflow receipt: run `35527334986`; its artifact bytes are committed here.

At the 20 September baseline, Ethereum's published genesis source/test closure and the BSC source
package both compiled with Solidity 0.8.30, the published Ethereum unit campaign passed 1,810/1,810
tests across 161 suites, and the Solana package passed 9 arithmetic tests, 24 lifecycle tests, its
keyless deployed-evidence test, 7 operational tests, 9 compiled program mutation controls, the
complete instruction/error/event census, and TypeScript checking. At the 25 November 2026 refresh
(`c6062178`), the published `frontend/` passed `tsc`, `eslint`, `audit-logic-test`,
`contract-ui-sync`, Vitest (82/82 files, 1,176/1,176 tests), 76/76 mutation controls, production
webpack build (`62/62` static pages) + RPC secret scan (`0` matches), and 42/42 server route tests.
