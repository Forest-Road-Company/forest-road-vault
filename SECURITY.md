# Security Policy

> **Live Ethereum mainnet deployment (V2, chain 1, deployed block 26,006,832, September 2026).**
> Forest Road Vault V2 is live on Ethereum mainnet and holds real capital across active borrower
> facilities, a live Morpho Blue USDC/sUSDfr market, Uniswap v4 liquidity pools, and an
> Ethereum↔BNB Smart Chain LayerZero `SUSDfrOFT` token bridge. Primary USDfr minting and direct
> USDC redemption are KYC-gated; holding, transferring, staking (`sUSDfr`), swaps and Morpho
> lending/borrowing are open to non-blocked addresses. Treat every defect affecting deployed
> contracts, bridges, keepers or the web interface as live.
>
> **Known open findings & staged upgrade (25 November 2026):** Live Ethereum V2 proxies have not
> yet executed the Stage 2 LMV upgrade, so **`LMV-09`** and **`LMV-18`** remain **Open** on live
> proxies (fixed and Corrovera re-audited in commit `ee9b228a`; Stage 1 preliminary release-monitor
> proposal `0xd14e...2ce1` is live, with Stage 2 following after Stage 1). Separately, off-chain
> liquidation-bot rollout item **`FRV-NEW-02`** remains **Open** pending deployment and
> verification. See [Live Deployment Status](https://forestroadvault.com/docs/status) and the
> [Audit Register](https://forestroadvault.com/docs/audit) before reporting.

## Reporting a vulnerability

Email **jevans@forestroad.com**. Please do not open a public issue for anything that affects the
safety of deployed contracts, off-chain infrastructure or user funds.

Include the affected contract, endpoint or component, the exact preconditions required to reach
it, and the impact you believe it has. A reproducible proof-of-concept test (for example, a
Foundry fork test) is the most useful thing you can send. If you would rather establish a private
channel before sending details, say so and we will.

## What happens next

We will acknowledge receipt, tell you plainly whether we consider it a finding and at what
severity, and agree disclosure timing with you.

Findings that survive validation are published on the
[audit register](https://forestroadvault.com/docs/audit) with their severity and disposition —
**including findings we accept or defer rather than fix**. Reproduction detail is withheld while
a mechanism is live and unremediated, which is a deliberate exception to publishing in full.
Reporters are credited unless they ask not to be.

There is no bug bounty at this stage.

## Scope

| Category | Scope |
|---|---|
| **In scope (Live Ethereum V2)** | Core protocol contracts (`USDfr`, `sUSDfr`, `MintRedeemController`, `ReserveManager`, `RedemptionQueue`, `ClaimBridge`, `WaterfallEngine`, `DefaultManager`, `CollateralRegistry`, `AttestationOracle`, `ComplianceRegistry`, `CuratorModule`, `GROVE`, `sGROVE`, `FRGovernor`, `Timelock`, `PointsModule`, `AssessedImpairmentSource`, `MtmAtomicExecutor`, `SUSDfrExitValueOracle`) verified on Etherscan/Sourcify and published at [Deployed Addresses](https://forestroadvault.com/docs/addresses). |
| **In scope (Cross-chain & preview)** | Live Ethereum↔BSC LayerZero `SUSDfrOFTAdapter` / `SUSDfrOFT` token bridge; Solana curator subscription vault program (devnet preview `3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh` — not yet on Solana mainnet). |
| **In scope (Web interface & APIs)** | `frontend/` (`https://forestroadvault.com`) where a defect could mislead a user about on-chain state, leak credentials, bypass RPC/rate protections or construct a harmful transaction. |
| **In scope (Withheld off-chain services)** | Deployment scripts, settlement/MTM/valuation/activity keepers, Morpho liquidation bot and operational tooling are withheld from the public repository. If you believe you have found a defect affecting them, please still report it. |
| **Not live on mainnet** | The separate BNB Smart Chain credit protocol (`bsc/`), the Solana curator vault mainnet deployment, and any parked/disabled routes are not live on mainnet. |

Historical Sepolia testnet deployments retain bootstrap admin privileges, use a mock stablecoin
and run with open concentration limits; findings that depend solely on testnet configuration are
expected rather than production vulnerabilities. If you are unsure whether something is
configuration or a defect, report it and let us make that call.

## Good-faith research

We have no interest in pursuing good-faith security research, and nothing in this policy waives
any right. Please test against your own local deployment or a local mainnet fork rather than live
mainnet or production infrastructure, do not access or modify data that is not yours, and do not
degrade the service for other users.

## Known and published

Before reporting, check the [audit register](https://forestroadvault.com/docs/audit) and
[live status page](https://forestroadvault.com/docs/status): open, accepted and deferred findings
(including `LMV-09`, `LMV-18`, `FRV-NEW-02` and accepted economic/governance tradeoffs) are
published there with their exact conditions and triggers. Independent confirmation of a published
finding is still welcome — particularly evidence that one is reachable under weaker conditions or
has greater impact than recorded.
