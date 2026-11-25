# Forest Road Vault

Forest Road Vault is a real-world-credit protocol built around identified credit facilities,
continuous recognition of earned cash and PIK interest, and a three-layer loss cascade: curator
capital, the protocol backstop (`sGROVE`), then senior principal (`sUSDfr`).

This public repository contains the verified Ethereum V2 genesis source (`contracts/src/`), the
pre-deployment BNB Smart Chain credit-protocol source (`bsc/contracts/`), the Solana curator-vault
program (`solana/curator-vault/`), their reviewable tests and build inputs, public architecture
and security specifications (`ADR/`, `docs/`, `SECURITY.md`, `PHASE_A_ARCHITECTURE.md`), and the
current Next.js application (`frontend/`). It is a curated source release assembled by explicit
allowlist from private engineering repositories. Operational runbooks, signing material, mainnet
role topology scripts, keeper/bot infrastructure, and raw working evidence remain outside the
public tree.

## Deployment status (updated 25 November 2026)

| System | Status |
|---|---|
| **Ethereum V2** | Live on Ethereum mainnet (deployed September 2026, block `26,006,832`) with continuous cash and PIK accrual active from genesis and 15 active performing facilities (`11,207,889 USDfr` supply, `$26.5mm` Gross Collateral & Reserves / `252.43%` of loans at block `26,491,784`). Live venues include Morpho Blue USDC/sUSDfr (`/markets`), Uniswap v4 (`USDfr/USDC` and `sUSDfr/USDC`) and Pendle SY wrappers. **Provenance note:** `contracts/src/` in this repository preserves the verified compiling 20 September 2026 V2 genesis snapshot (`8bb9a658`); subsequent governance upgrades (`FRV-005`–`FRV-009`, `ADR-0040`, `SUSDfrExitValueOracle`) and the staged November 2026 LMV Stage 2 runtimes (`ee9b228a`) are verified on Etherscan and Sourcify (`exact_match`). **Open findings:** `LMV-09` and `LMV-18` remain **Open** on live proxies pending Stage 1 → Stage 2 governance execution; off-chain `FRV-NEW-02` (`ee9b228a` liquidation bot) was rolled out and live-verified on 25 November 2026 and is retained **Open** in the register pending independent Corrovera confirmation. See [Live Deployment Status](https://forestroadvault.com/docs/status) and the [Audit Register](https://forestroadvault.com/docs/audit). |
| **BNB Smart Chain** | **Two distinct surfaces:** (1) The Phase 1 Ethereum↔BSC LayerZero `SUSDfrOFT` token bridge (`SUSDfrOFTAdapter` ↔ `SUSDfrOFT`, `ADR/0045`) launched in November 2026; (2) the separate standalone BSC credit protocol under `bsc/contracts/` (`ADR/0037`) has **not** been deployed to BSC mainnet. See `bsc/README.md`. |
| **Solana curator vault** | Canonical reviewed program active on Solana devnet at `3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`; **no Solana mainnet deployment** has occurred. The committed 475,824-byte ELF SHA-256 is `c3f365f888cda2daf06bbf8339c7e8ea89cd090b2dac030367f346e78f3b450e` (IDL SHA-256 `0f3c9bab4669da0f45a804bf97419c7957c836b9d384fe585a4ad0d61b9661e5`). Corrovera completed an external audit and two re-verifications on 20 September 2026; specialist Solana review, counsel, 2-of-4 Squads and emergency-signer gates remain pre-mainnet requirements. |
| **Frontend** | Current production source under `frontend/` (synced 25 November 2026 from commit `53f7f4ea`). Production builds on `https://forestroadvault.com` expose `/api/revision` binding the served site to its Git commit, route browser JSON-RPC through `/api/rpc`, and persist history/points caches in private Vercel Blob. |

Token characterization is a matter for counsel. Nothing in this repository is a securities-law
representation or represents any instrument as a non-security.

## Repository layout

```text
contracts/              Ethereum V2 genesis contracts (`8bb9a658`), tests, generic scripts & pinned submodules
bsc/contracts/          Standalone BNB Smart Chain credit-protocol source (unlaunched) & pinned build config
solana/curator-vault/   Solana program, tests, deterministic build inputs & public devnet evidence
frontend/               Next.js application, /api/rpc proxy, contract interfaces & public docs/audit register
ADR/                    Architecture Decision Records (0001–0048) suitable for public review
docs/                   Threat model, access-control matrix, invariants, formal-methods & recovery specs
audit-reports/          Published historical August 2026 V1 external audit PDFs (see audit-reports/README.md)
```

The BSC package reuses the exact dependency revisions pinned as root contract submodules. Its
public `foundry.toml` and `remappings.txt` only redirect dependency paths to those shared pins; its
Solidity source is unchanged from the reviewed BSC commit recorded in `bsc/README.md`.

## Security posture

The repository publishes the threat model (`docs/threat-model.md`), access-control matrix
(`docs/access-control-matrix.md`), invariant specification (`docs/invariants.md`), formal-methods
scope (`docs/formal-methods-amenability.md`), architecture decisions (`ADR/`), source, and tests
that do not depend on withheld operational scripts. The web application renders the complete dated
review register at `https://forestroadvault.com/docs/audit` and live status at
`https://forestroadvault.com/docs/status`.

This source release is not an unqualified production clearance for any network. Open findings
(`LMV-09`, `LMV-18`, `FRV-NEW-02`), counsel review, per-asset admission review, authority setup,
and chain-specific external reviews remain explicit release controls. For Solana, production
Squads, the emergency signer, counsel review, and a specialist Solana review remain pre-mainnet
gates.

See [SECURITY.md](SECURITY.md) or email **jevans@forestroad.com** to report suspected defects
privately. Test against your own deployment, a testnet, or a local fork. Do not test against live
assets or degrade public services.

## What is deliberately withheld

| Withheld | Reason |
|---|---|
| Mainnet deployment, validation, handover, and upgrade transaction scripts | They expose live role topology, CREATE ordering, and operational sequencing. Generic build and local-validation helpers required by the published tests are included. |
| Tests that import withheld scripts | Solidity compilation is all-or-nothing. The publisher excludes tests whose imports depend on withheld scripts so the published suite compiles cleanly. |
| Mainnet control-wallet probes, deployment manifests, and ceremony receipts | These are operational records. Deployed Ethereum bytecode and upgrades remain verified on Etherscan and Sourcify. |
| Keeper services, liquidation bot, private bundle feeds, and launch/incident runbooks | They disclose relay, credential-boundary, and response details unrelated to reviewing contract logic. |
| Raw working reports and remediation archives | They contain reproduction and operational detail beyond the curated public review register (`audit-reports/` retains only the two owner-carved-out August 2026 V1 PDFs). |
| Solana signing and deployment entrypoints | The public package includes program source, deterministic build tooling, tests, canonical artifact, and read-only devnet evidence. |

No `.env` file, private key, mnemonic, KMS credential, or signing payload is part of this release.

## Build and test

Initialize the pinned dependencies first:

```sh
git submodule update --init --recursive
```

Ethereum V2 (genesis source closure):

```sh
cd contracts
forge build
forge test --offline
```

Some fork suites additionally require explicitly configured RPC endpoints. The published tree omits
tests whose only path to compilation imports a withheld operational script.

BNB Smart Chain source:

```sh
cd bsc/contracts
forge build --sizes
```

Solana curator vault:

```sh
cd solana/curator-vault
npm ci
npm run build:program
npm run test:program
npm run test:surface
npm run test:ops
npm run typecheck
```

Frontend:

```sh
cd frontend
npm ci
npx tsc --noEmit
npm run lint
npm test
npm run test:mutations
npm run test:server
```

See `frontend/README.md` for production environment variables (`NEXT_PUBLIC_RPC_URL=/api/rpc`,
`RPC_PROXY_UPSTREAM_URL`, `BLOB_READ_WRITE_TOKEN`, `VERCEL_GIT_COMMIT_SHA`). Browser configuration
is public by construction; secrets do not belong in `NEXT_PUBLIC_*` variables.

## License

[Business Source License 1.1](LICENSE). Non-production use is permitted; production use is subject
to the Additional Use Grant. The license converts to Apache 2.0 on the Change Date.

Copyright in the Licensed Work is held by Road Runner Capital, LLC, a Forest Road entity.
