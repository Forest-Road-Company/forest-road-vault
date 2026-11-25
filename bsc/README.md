# BNB Smart Chain contracts (Standalone Credit Protocol — Unlaunched)

> **Distinction from live Ethereum↔BSC token bridge (25 November 2026):** The contracts in this
> directory are the **standalone BNB Smart Chain credit protocol** (`ADR/0037`), which has **not**
> been deployed to BSC mainnet. Separately, a Phase 1 Ethereum↔BSC LayerZero `SUSDfrOFT` token
> bridge (`SUSDfrOFTAdapter` ↔ `SUSDfrOFT`, `ADR/0045`) launched in November 2026 so canonical
> Ethereum-backed `sUSDfr` can be represented on BNB Smart Chain without originating loans on BSC.

This directory contains the reviewed BNB Smart Chain credit-protocol contract source from commit
`448f5face2285fc620b62bae3e0458531fae14c5`. The standalone BSC credit instance has not been
deployed to mainnet. Its fresh-deployment configuration enables continuous cash and PIK accrual
from genesis.

`contracts/src/`, `foundry.toml`, `foundry.lock`, and the compiler pin are copied from that
commit. The public copy changes only dependency paths in `foundry.toml` and `remappings.txt`
so the BSC project reuses this repository's exact pinned OpenZeppelin, Solady, and Forge Std
submodules.

Build it from the repository root:

```sh
git submodule update --init --recursive
cd bsc/contracts
forge build --sizes
```

The build uses Foundry 1.3.2, Solidity 0.8.30, Cancun, optimizer runs 100, and no IR pipeline.
Deployment scripts, role addresses, signing material, operational runbooks, and internal
review records are intentionally outside this public source package.
