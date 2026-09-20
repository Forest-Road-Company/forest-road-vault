# BNB Smart Chain contracts

This directory contains the reviewed BNB Smart Chain contract source from commit
`448f5face2285fc620b62bae3e0458531fae14c5`. The BSC instance has not been deployed to
mainnet. Its fresh-deployment configuration enables continuous cash and PIK accrual from
genesis.

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
