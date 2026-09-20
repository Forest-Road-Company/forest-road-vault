# Forest Road Vault

Forest Road Vault is a real-world-credit protocol built around identified credit facilities,
continuous recognition of earned cash and PIK interest, and a three-layer loss cascade: curator
capital, the protocol backstop, then senior principal.

This public repository contains the current Ethereum v2 source, the pre-deployment BNB Smart Chain
source, the Solana curator-vault program, their reviewable tests and build inputs, and the Next.js
application. It is a curated source release from private engineering repositories. Operational
runbooks, signing material, mainnet role topology, keeper infrastructure, and raw working evidence
remain outside the public tree.

## Deployment status

| System | Status |
|---|---|
| Ethereum v2 | Deployed on Ethereum mainnet at block `26,006,832` as a qualification deployment. Continuous cash and PIK accrual was enabled at genesis. The source under `contracts/src/` is byte-identical to the source used for the verified deployment. Deployment alone is not production acceptance. |
| BNB Smart Chain | Source complete and reviewed; no BSC mainnet deployment has occurred. A fresh deployment enables continuous accrual at genesis. See `bsc/README.md`. |
| Solana curator vault | Current canonical program is on devnet at `3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`; no Solana mainnet deployment has occurred. The committed ELF hash is `4cf28ebf3b911a59d7807a852fb81a03fe6680af5ddc94bad74a981efdf3a605`. |
| Frontend | Source is under `frontend/`. Production releases expose `/api/revision`, which binds the served build to its Git commit. |

Token characterization is a matter for counsel. Nothing in this repository is a securities-law
representation or represents any instrument as a non-security.

## Repository layout

```text
contracts/              Ethereum v2 contracts, tests, generic scripts and pinned dependencies
bsc/contracts/          BNB Smart Chain production contract source and pinned build configuration
solana/curator-vault/   Solana program, tests, deterministic build inputs and public devnet evidence
frontend/               Next.js application, contract interfaces and published review register
ADR/                    Architecture decisions suitable for public review
docs/                   Threat model, access-control matrix, invariants and public specifications
```

The BSC package reuses the exact dependency revisions pinned as root contract submodules. Its
public `foundry.toml` and `remappings.txt` only redirect dependency paths to those shared pins; its
Solidity source is unchanged from the reviewed BSC commit recorded in `bsc/README.md`.

## Security posture

The repository publishes the threat model, access-control matrix, invariant specification,
architecture decisions, source, and the tests that do not depend on withheld operational scripts.
The application also renders the public review register under `/docs/audit`.

This source release is not a statement that any network is ready to receive customer funds.
Production acceptance, counsel review, per-asset admission review, authority setup, and any
chain-specific external review remain separate release decisions. For Solana, production Squads,
the emergency signer, counsel review, and a specialist Solana review remain pre-mainnet gates.

Report suspected defects privately to **jevans@forestroad.com**. Test against your own deployment,
a testnet, or a fork. Do not test against live assets or degrade public services.

## What is deliberately withheld

| Withheld | Reason |
|---|---|
| Mainnet deployment, validation, handover, and legacy-upgrade transaction scripts | They expose live role topology, CREATE ordering, and operational sequencing. Generic build and local-validation helpers required by the published tests are included. |
| Tests that import withheld scripts | Solidity compilation is all-or-nothing. The publisher derives this exclusion from imports so the remaining public suite compiles. |
| Mainnet control-wallet probes, deployment manifests, and ceremony receipts | These are operational records. Deployed Ethereum source remains verified on Etherscan. |
| Keeper services, private bundle feeds, and launch/incident runbooks | They disclose relay, credential-boundary, and response details unrelated to reviewing contract logic. |
| Raw working reports and remediation archives | They contain reproduction and operational detail beyond the curated public review register. |
| Solana signing and deployment entrypoints | The public package includes program source, deterministic build tooling, tests, canonical artifact, and read-only devnet evidence. |

No `.env` file, private key, mnemonic, KMS credential, or signing payload is part of this release.

## Build and test

Initialize the pinned dependencies first:

```sh
git submodule update --init --recursive
```

Ethereum v2:

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
npm test
./node_modules/.bin/tsc --noEmit
npm run lint
```

Production frontend builds require the documented public `NEXT_PUBLIC_*` configuration. Browser
configuration is public by construction; secrets do not belong in those variables.

## License

[Business Source License 1.1](LICENSE). Non-production use is permitted; production use is subject
to the Additional Use Grant. The license converts to Apache 2.0 on the Change Date.

Copyright in the Licensed Work is held by Road Runner Capital, LLC, a Forest Road entity.
