# ADR-0037: A second protocol instance on BNB Smart Chain, and how a reserve asset is admitted

**Status:** Draft, decided in principle by Forest Road on 2026-09-07 (see "Decisions received"
below); D1 remains open pending a liquidity measurement and counsel. Written 2026-09-07; revised
the same day after an independent five-lens review. Not yet accepted as a record. Binds nothing.
Nothing in this document authorises a broadcast on any chain, extends any owner direction, or
changes the live Ethereum deployment.

**Decisions received from Forest Road, 2026-09-07** (the options are defined in §1):

| # | Answer | Consequence recorded |
|---|---|---|
| D0 | Answered. The requesting counterparty is commercially confidential and is recorded in the internal record only. The goal includes holding more than one reserve asset. | D5(a) is ruled out; §4.4's residual applies. Counsel item 2 gains a fact: the counterparty's relationship to the candidate reserve assets is recorded internally. |
| D1 | **Decided 2026-09-07, subject to the per-asset review and counsel:** the genesis pair is **Binance-Peg USDC and USD1**; USDG follows when it has an on-chain form on BSC. Chosen on the liquidity measurement below. Forest Road holds a Binance account and is a BitGo customer, so a conversion rail exists for each. | Both are 18-decimal. The ADR-0029 §3 review and counsel's view are owed per asset before listing; the reserve's bridge operator for one asset is a commercial counterparty, recorded internally for counsel. |

**On-chain liquidity on BSC, measured 2026-09-07** (DEX pool reserves verified on chain; swap cost
from the PancakeSwap v3 quoter and the KyberSwap and ParaSwap aggregators; supply from DefiLlama).
Figures are lower bounds for DEX depth and exclude centralised order books.

| Asset | BSC supply | DEX liquidity in stable pairs | Cost to swap 1M into the other stable | Cost to swap 10M | Issuer rail |
|---|---|---|---|---|---|
| USDT (BSC-USD, Binance-bridged) | 9.18bn | at least 72m of at least 650m total | 0.01% | 0.03% | Binance account, then Tether (100k minimum, 0.1% fee) |
| Binance-Peg USDC | 1.59bn | about 81m of about 108m total | 0.01% to 0.06% | 0.01% to 0.07% via aggregator; 0.3% in the single deepest pool | Binance account, then Circle Mint |
| USD1 (BitGo-issued, native on BSC) | 1.40bn | about 6.4m of about 63m total | 0.37% to 0.91% | not executable on chain (about 60% shortfall) | BitGo, eligible customers, par, may be deferred |
| FDUSD (native) | 58m | under 0.4m | not executable (over 80% loss) | not executable | First Digital, institutional |
| USDG | none on BSC | none | n/a | n/a | Paxos, verified customers |

USD1's depth sits in Binance's order books (one report puts about 93% of USD1 supply on Binance)
and in Lista lending (about 138m), not on DEXs. Circle's asset on BSC, USYC, is a tokenized
money-market fund share with a rising price (about 1.14 dollars), permissioned to KYC'd non-US
holders through an entitlements contract, redeemable into USDC with fees and capacity limits; it
is not a 1:1 stablecoin and is not a reserve candidate for a 1:1 mint. No native USDT has been
issued on BSC (Tether's transparency data shows zero). Twelve-month peg lows: Binance-Peg USDC
0.9907 (2026-08-10, noisy series), USD1 0.9982 (with a brief wobble to about 0.994 on 2026-02-23),
BSC-USD 0.9971, FDUSD 0.9939 in the window and 0.87 on 2025-04-02 outside it.
| D2 | Yes. | As tabled. |
| D3 | (b): Timelock with a Safe as sole proposer, no Governor. | Topology change under ADR-0013 as amended by ADR-0036; disclosure rewritten for BSC. |
| D3a | (ii): no layer two at genesis. | Two-layer cascade on BSC; ADR-0014's target reopened for the instance; every ADR-0035 disclosure surface must say so. |
| D4 | (a): a loss the ledger never sees, bounded by caps. | Amends ADR-0034 X by scoping the cascade-ordering rule to recognised losses (§4.2). |
| D5 | (d): pro-rata basket redemption, **with single-asset payout on election** (added 2026-09-07: "depositors need to be able to withdraw in their deposit currency"). | The protocol itself pays the current reserve mix in kind, so the redemption side stays closed. A redeemer who wants one asset elects it and a periphery router, in the redeemer's own transaction, swaps the other legs at market with a slippage bound the redeemer sets, falling back to in-kind delivery for any remainder the market cannot fill; the protocol never calls a market and its solvency path is untouched (ADR-0025). "Deposit currency" cannot be tracked on a fungible token, so the election is the redeemer's choice, which the frontend can default to that wallet's last deposit. The swap cost, including a depegged leg's discount, is the redeemer's, which is exactly what keeps the free option closed. On BSC the router's transaction should use a private relay because the chain's block builders extract MEV. The mint side still needs per-asset cap, fee and freeze (§4.4); the credit layer funds and collects in one asset per facility, which skews the basket, so the funding asset is a per-origination parameter; the sUSDfr queue is unaffected (it settles in USDfr). USD1's on-chain depth (about 6m in stable pairs on 2026-09-07) bounds what the router can convert in one transaction; beyond it the redeemer receives USD1 in kind. |
| D6 | (b): a branch for the BSC instance; the Ethereum deployment is not touched. | Two code lines to maintain; no Ethereum audit delta. The precondition (Ethereum acceptance signed, DV-03 layer two funded or accepted) stands as engineering's recommendation and is Forest Road's to keep or waive. |
| D7 | (b): a human operator under a new BSC owner direction and runbook, and the 2026-08-27 origination amendment extended to BSC under the same conditions. | Requires a dated owner direction naming BSC before any broadcast; the operating rules to be amended accordingly. |
| D8 | Three classes at genesis: film tax credits, renewable energy and digital assets. | Reopens ADR-0003 for the instance. Digital assets at genesis requires the private-submission decision in §3 before the MTM keepers can run (see §6). |
| D9 | Yes. | Counsel re-review of ADR-0016's framing for a second instance. |
| D10 | Reuse the Ethereum deployer and attester keys. | Same addresses at fresh nonces; the coupled blast radius is accepted; role grants on BSC are made to the same addresses. |
| D11 | Delegated to engineering: reuse what is safe. | Enumerated in the internal record: economic and timing parameters copied; the seed, anti-inflation floor and rounding rule re-derived for 18 decimals; per-asset caps and fees new. |
| Q7 | Funding both cascade layers is **not** a hard genesis gate. | Origination on BSC may proceed with an empty curator pool; with D3a(ii) there is no layer two at all, so until first-loss is posted every credit loss on BSC reaches senior principal directly. A disclosure item, per instance. |
| Disclosures | Yes: build the per-instance disclosures into the frontend docs. | The BSC build carries a disclosure surface stating: no layer two at genesis; first-loss not a gate; a reserve-asset depeg is a loss the ledger never sees, borne by last-out holders outside the cascade; basket redemption and the elected-asset swap; governance rests on the Safe, not a vote; which assets back the instance and who stands behind each; that the Ethereum audits do not cover the instance. Counsel review of the wording is owed before it goes live. |

**Supersedes in part, if accepted:** [ADR-0009](0009-ethereum-l1.md) (Ethereum L1,
single-chain) and [ADR-0030](0030-clean-mainnet-v1-contract-surface.md) §1 (no reserve-asset
registry), each for the second instance only unless D6 says otherwise. **Consumes:**
[ADR-0029](0029-mainnet-v1-feature-scope.md) §3, whose per-asset admission review is exercised,
not reopened, by every listing. **Amends, if D4 is accepted as recommended:**
[ADR-0034](0034-exit-pricing-in-cascade-order.md) decision X and the cascade-ordering invariant
of the operating rules, by scoping them to losses the ledger recognises (§4.2).
**Amends:** [ADR-0012](0012-backing-invariant.md) (the backing invariant becomes per-instance and,
under D5, per-asset). **Does not change:** identified-per-asset collateral
([ADR-0001](0001-identified-per-asset-collateral.md)), variable-yield pass-through
([ADR-0002](0002-variable-yield-pass-through.md)), the three cascade layers
([ADR-0004](0004-anchor-curator-first-loss.md), [ADR-0014](0014-sgrove-backstop-parameters.md),
[ADR-0021](0021-sgrove-backstop-implementation.md), [ADR-0035](0035-sgrove-absorbs-without-a-per-event-cap.md)),
or the solvency-path rules of [ADR-0025](0025-internal-idle-stable-accounting.md), except as row A
of §4.3 would require if it were chosen.

On status: the ADR index and the Phase A architecture record rate ADR-0009 as Resolved, while the
binding operating rules list Ethereum L1 among the locked decisions. The operating rules govern, so
this ADR treats it as locked and reopens it only on Forest Road's acceptance; on acceptance the
index row and the Phase A summary are corrected to Locked (§6).

> **Why this record exists.** On 2026-09-03 Forest Road asked for "a BSC deployment supporting
> USDC and later USDG". The repository records no business rationale, counterparty or owner
> direction for it; the request reopens a locked decision; and its premise needs correcting before
> anything is designed (§0). The single reserve token is structural in the live contracts, not a
> parameter, and the difficult question is economic rather than mechanical. This ADR puts the
> decisions to Forest Road in a form that can be decided, records what each choice costs, and names
> what only Forest Road or counsel can answer. It characterises no instrument; token
> characterisation remains a matter for counsel.

---

## 0. The premise, corrected

Three facts established on 2026-09-07 change what the request means. Each is dated and should be
re-verified before acceptance (§8).

1. **Circle issues no USDC on BNB Smart Chain.** Circle's contract-address list (37 chains on
   2026-09-07) does not include BNB Chain, and Circle's CCTP documentation states that USDC is
   supported on every CCTP domain except BNB Smart Chain. BNB Smart Chain is nonetheless a CCTP
   V2 domain for Circle's USYC, which Circle issues natively there and settles in USDC, so Circle
   infrastructure is present on the chain; a native USDC issuance has not been announced. The
   token called "USDC" on BSC is **Binance-Peg USDC** (`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`):
   an **18-decimal** BEP-20 behind a Binance-controlled upgradeable proxy. On 2026-09-07 the
   proxy admin and the token owner were both single externally owned accounts and minting was
   enabled, so there is no on-chain multisig or timelock between a Binance key and either an
   upgrade or a mint. Its backing is native USDC held in Binance custody; it is redeemable only
   by depositing to a Binance account under Binance's terms, with no issuer-level redemption right
   comparable to Circle's or Paxos's. For the record and with sources in §8: in January 2023
   Bloomberg reported, and Binance acknowledged, that Binance-Peg BUSD had at times in 2020 and
   2021 been under-collateralised by more than a billion dollars, and that collateral for many
   B-Tokens had been held in a wallet mixed with customer funds; in February 2023 Forbes reported,
   from on-chain analysis, that about 1.8 billion dollars of Binance-Peg USDC collateral left the
   peg wallet between August and December 2022, which Binance described as internal wallet
   management and denied had affected backing. NYDFS stated in February 2023 that it had not
   authorised Binance-Peg BUSD on any blockchain.
2. **USDG is not issued on BNB Smart Chain, and USDG0 has not been deployed there either.**
   USDG is issued by Paxos Digital Singapore Pte. Ltd. under MAS supervision (and by Paxos
   Issuance Europe under MiCA). Paxos lists native issuance on Ethereum, Solana, Ink, X Layer,
   Robinhood Chain and Mantle. On Ethereum it is 6 decimals, a UUPS proxy with pause and
   asset-protection (freeze and wipe) roles held by Paxos multisigs; redemption at par is available
   to verified Paxos customers, subject to Paxos's right to refuse a suspended account. The route
   by which USDG reaches chains without native issuance is **USDG0**, a LayerZero OFT
   representation (Hyperliquid, Plume, Aptos), which is a bridged token with LayerZero's trust
   assumptions rather than a Paxos liability. As of 2026-09-07 "later USDG" on BSC has no
   on-chain form at all.
3. **So "USDC then USDG on BSC" means two bridged assets from two different bridge operators**,
   on a chain whose ADR-0009 rationale, "no bridge risk", a bridged reserve asset gives up.
   ADR-0009 rejected multi-chain as a cross-chain messaging surface and named multi-chain "a
   possible later expansion"; the lock is the operating rules'. The first question in §1 is
   whether Forest Road knew this.

Other facts that shape the design: BSC has run 0.45-second blocks since the Fermi fork of
2026-01-14 with finality near 1.1 seconds; `block.timestamp` stays second-granular and
**consecutive blocks may share a timestamp**; block production runs through whitelisted builders,
two of which (48Club and Blockrazor) produced over 87% of blocks between April 2025 and February
2026; there is no Flashbots, and private submission is offered by several builder-operated RPCs
with different guarantees. Safe v1.4.1 contracts and a Safe transaction service exist on BSC.
Explorer verification for chain 56 runs through the paid-only Etherscan v2 API (BscScan's own API
was deprecated in December 2025), so a paid plan or an alternative verifier is a prerequisite.
Pegged-dollar supply on BSC is about a tenth of Ethereum's (roughly 13 billion against 147 billion
dollars on 2026-09-07), led by Binance-issued USDT, Circle's natively issued USYC, Binance-Peg
USDC and USD1. FDUSD, natively issued there, traded to 0.87 dollars in April 2025.

---

## 1. Decisions requested from Forest Road

Each row can be answered by picking an option. The engineering recommendation is given; the
decision is Forest Road's.

| # | Decision | Options and consequences | Recommendation |
|---|---|---|---|
| **D0** | **Why BSC, and for whom.** | Who is asking (a distribution partner, a borrower, a Global Dollar Network arrangement, a Binance or USD1 relationship) and what must be delivered: (i) *entry* for BSC-resident capital, (ii) *holding* USDG in reserve, (iii) something else. The repository records nothing. Note that Global Dollar Network revenue share is paid to partners in proportion to USDG held or used on their platform, not to holders. | Answer first. D5 and D6 turn on it. |
| **D1** | **The BSC reserve asset at genesis**, given §0. | (a) Binance-Peg USDC: 18 decimals, single-key admin and mint, bridge custody, no issuer-level redemption right. (b) A natively issued BSC dollar (USD1, BitGo-custodied, or FDUSD; both 18-decimal): issuers counsel has not reviewed. (c) Wait for a native USDC or USDG issuance on BSC (no announced date, though Circle already runs USYC and CCTP there). (d) Do not deploy on BSC. | Engineering cannot pick. (a) and (b) each give up ADR-0009's "no bridge risk" and need the ADR-0029 §3 asset review and counsel's view on the reserve counterparty. (c) and (d) cost nothing beyond the first two items of §8. |
| **D2** | **Independence.** | The BSC instance is a second, separately backed protocol: its own USDfr and sUSDfr, ClaimBridge book, curator first-loss, layer-two reserve (per D3a), compliance allowlist, attester domain, keepers, governance root, and its own pre-mainnet and acceptance gates. No bridge of USDfr, GROVE, attestations or governance in either direction. | **Yes**, if BSC at all. Forced by ADR-0001 and ADR-0009 (§2), and it keeps the one property ADR-0009 valued that a bridged reserve asset has already given up. |
| **D3** | **Governance root on BSC.** GROVE lives on Ethereum. | (a) A Governor fed by bridged GROVE: a cross-chain surface, excluded by D2. (b) A Timelock with a Safe as sole proposer and no Governor: a topology change under ADR-0013 as amended by ADR-0036, whose "governance security rests on the vote" disclosure becomes "rests on the Safe". (c) A BSC-native vote token: see D3a. | **(b).** Forest Road holds every vote on Ethereum today, so no control is lost; the disclosure changes and must be written for the BSC surface. |
| **D3a** | **Cascade layer two on BSC.** `SGrove` stakes GROVE, and D2 forbids bridging it. | (i) A BSC-native GROVE issuance staked into a BSC sGROVE: a new token, a counsel item, and ADR-0026's voting rights have nothing to vote in under D3(b), so ADR-0026 is reopened for BSC. (ii) No sGROVE layer on BSC at genesis: a two-layer cascade, ADR-0014's target reopened, and every ADR-0035 disclosure surface must say so. (iii) Do not deploy. | Engineering cannot pick. (ii) is honest about what BSC would be; (i) is a token decision for Forest Road and counsel. |
| **D4** | **Decision zero on depeg.** Is a reserve-asset loss of value a loss the cascade absorbs, or a loss the ledger never sees? | (a) Keep a price loss off the ledger (par-valued tally, no haircut), bounded by caps; any part that *is* recognised (a per-asset custody arm, a cap cut below the standing tally, conversion slippage) enters the cascade at the next exit through the ADR-0034 Y-bis draw. This scopes the cascade-ordering rule to recognised losses (§4.2). (b) A timelocked governance haircut per asset, so a depeg cascades: draws curator and sGROVE capital contracted for credit losses against a mark that may reverse in days, and lands two days after the event. | **(a)**, accepted explicitly as an amendment of ADR-0034 X, because X is Forest Road's own verbatim direction. State the §4.2 consequence on every disclosure surface. |
| **D5** | **The reserve-asset admission model**, which is what "later USDG" requires. | (a) Single asset per instance; a second asset enters only through an external swap: zero contract change, no free option, "later USDG" is not held. (b) A governed registry with per-asset cap, mint fee and freeze; USDG held up to its cap and payable only if governance later designates it: the mint-side option stays open up to the cap per conversion cycle (§4.4). (c) As (b) plus treasury conversion of the secondary asset to the payout asset within a bounded window: only where a conversion rail exists, which for the §0 assets means a Binance account or a bridge hop plus Paxos redemption, and off-chain custody during the window. (d) Pro-rata basket redemption: closes the redemption side entirely, in-kind two-token payouts, the credit layer skews the basket. (e) An isolated instance per asset: two USDfr tickers on BSC. | **(a) if D0 is entry; (b) if D0 is holding, with the §4.4 residual accepted and disclosed; (c) only with a rail.** D0(ii) rules out (a) and (c). |
| **D6** | **Sequencing.** | (a) Design the registry once and upgrade Ethereum first: the first upgrade of the live Ethereum proxies, a new audit delta on the two most-reviewed contracts, three register findings reopened on Ethereum (§3), and the source-identity freeze broken. (b) Design once on a branch and deploy BSC only, leaving Ethereum frozen: two code lines to maintain, no Ethereum audit delta, Ethereum gains nothing. (c) BSC with today's single-asset code and upgrade later: ships the in-place-upgrade hazard ADR-0025 records to a live proxy and needs a second audit. | **(b)** if BSC proceeds at all. None of (a), (b) or (c) starts before Ethereum's capped-launch acceptance is signed and DV-03's layer two is funded or formally accepted; this ADR does not reorder that queue. |
| **D7** | **Authority.** | (a) A human operator under a new, dated BSC owner direction and a BSC runbook, agents rehearsing on a fork only. (b) As (a), plus an extension of the 2026-08-27 origination amendment to BSC under the same per-act, human-verified, fork-first conditions. (c) No BSC authority of any kind until Ethereum's acceptance is signed. The signers are the two Gate 6 authorizers or new ones; agents cannot close any of these. | **(c) now, (a) if BSC proceeds.** The existing directions are read as Ethereum only: the 2026-08-27 amendment names three contracts of the live Ethereum deployment and is exercised under the Ethereum runbook, and directive 1's prohibition is chain-neutral. If BSC proceeds, the operating rules should say "Ethereum mainnet" explicitly. |
| **D8** | **Collateral classes at BSC genesis.** | Five (ADR-0003, locked); four without the digital-assets class, whose MTM keepers need an accepted private-submission boundary BSC does not yet have (reopens ADR-0003); fewer. | Cannot be five until the private-submission question in §3 is answered. |
| **D9** | **Points on BSC.** | Yes, with counsel re-review of ADR-0016's framing for a second instance; no. | Counsel item. |
| **D10** | **Key topology.** | Reuse the Ethereum deployer and attester keys (same addresses at fresh nonces; coupled blast radius; any off-chain authorisation keyed on address applies on both chains); fresh keys. | Fresh keys. |
| **D11** | **Parameter carry-over.** | Which Ethereum genesis constants are copied, which are re-derived for the asset's decimals (the vault seed and anti-inflation floor, the whole-unit rounding rule), and which are new (per-asset cap and fee). | Enumerate in the BSC genesis config before any review. |

---

## 2. Why a BSC instance is a separate protocol and not a mirror

Identified-per-asset collateral (ADR-0001, locked) binds every deployed dollar to a facility NFT
on the same chain: `ReserveManager.recordDeployment` is keyed by facility id, gated by the credit
role and, in the deployed call graph, reached only from `WaterfallEngine.fund`; the legal wrapper
maps each NFT one-to-one to a series-held asset. A claim held on Ethereum therefore cannot back
USDfr on BSC without either a cross-chain message (rejected by ADR-0009 as a surface to secure) or
a manager-asserted figure, which ADR-0025 forbids as an upward move on authority. The same
receivable represented by NFTs on two chains raises a double-pledge question for counsel. So a
BSC USDfr is backed only by BSC idle reserve and BSC facilities; its cascade layers are BSC
contracts holding BSC USDfr; its attestations are bound to chain 56 by the oracle's EIP-712
domain; its compliance allowlist is a separate registry under the same counsel-set policy; its
concentration limits are per instance with no aggregate view; and its sGROVE target ("10% of
total deployed principal, protocol-wide" in ADR-0014) needs a per-instance reading. Points, fees
and the high-water mark are likewise per instance.

What follows automatically: the BSC instance re-enters every pre-mainnet gate and the capped-launch
acceptance; the Corrovera and Cantina scopes do not cover it; the public README, threat model,
invariant statements and audit register must say so. What follows as new decisions: the four
control Safes, the attester set, the keeper fleet and the deployer identity (D10, §6).

---

## 3. What is structural in the live code

The claims below are verified against `contracts/src` at the current commit; the ones that decide
the design carry their file references.

- `ReserveManager` stores a single `IERC20 usdcToken` and a single `uint256 idleUSDCUnits` at the
  head of its ERC-7201 struct (`ReserveManager.sol:45-46`), set once in `initialize` behind a
  `decimals() == 6` revert (`:106-107`, `:117`), with no setter. The 6-to-18 shift is a private
  constant `1e12` in `ReserveManager` (`:41`), in `MintRedeemController` (`:231`), as a
  scale-derived residue margin in `RedemptionQueue` (`MIN_RESIDUE_VALUE`, `:189`), and in the
  symbolic harness. An 18-decimal asset cannot initialise the contract at all.
- Backing is `normalize(idleUSDCUnits) + (deployedPrincipal - impairment)` (`:1095-1097`): one
  scalar, par by construction, read from storage with no price input. A depeg is invisible to it.
  The only loss-recognition path is a unit shortfall against `balanceOf`; the arbitrary
  write-down is a tombstone that always reverts (`:163`). ADR-0029 §3 accepts this as a residual
  on the ground that the reserve is a buffer rather than the book, and notes separately that the
  single-asset surface carries none of the round-two levers; a second asset reopens both halves.
- Mint is exactly 1:1 with no fee and reverts unless `usdfrOut == amount * 1e12`
  (`MintRedeemController.sol:396`). Direct redemption pays the single token at par while backing
  covers supply, and otherwise at the coverage ratio with an atomic junior draw (ADR-0034 Y-bis);
  it rounds down to whole units, has no fee or cooldown, and is available in the same block as a
  mint. Because a depeg never moves backing, the price stays at par through a depeg, which is
  what §4.1 exploits. The sUSDfr queue never holds or transfers the stablecoin (it settles in
  USDfr), but its residue margin and epoch budget are scale-derived and must be re-derived per
  asset. `closeEpoch` is the only *queued* senior exit; direct redemption is a second senior exit
  and stays open (ADR-0033 §5).
- The custody-loss arms of ADR-0033 are denominated in native units of the one token; the
  `PaymentReceived` attestation payload binds the reserve token address and a six-decimal amount,
  so a second token changes what attesters sign.
- The pre-ADR-0030 code carried a multi-stable registry. The round-two audit of 2026-07-14 found
  a disabled asset still counted at face value (R2-H-02) and that a retired or reverting entry
  could brick backing (R2-M-03, proven live by the red team and closed by ADR-0025); ADR-0030
  then removed the registry. A third finding, PM-M-02, scoped the frontend's approval flow to
  standard-return USDC on the same basis. All three are dispositioned as superseded by the
  USDC-only decision; a registry reopens the first two on the contracts and the third on the
  frontend, which for an 18-decimal BEP-20 proxy is not academic.
- Deployment and validation are chain-1-bound by construction: the mainnet deploy and validate
  scripts require chain id 1 and the authorization receipt is bound to the chain id and profile,
  so it cannot be reused across chains. None of it can be loosened; a BSC ceremony needs a
  parallel, equally fail-closed set. Until 2026-09-07 the *testnet* tooling refused only chain
  id 1, so the mock-stable, retained-admin path would not have refused BSC mainnet; scoping this
  ADR surfaced that and the guard is now a shared `KnownTestnets` allowlist, which deliberately
  omits BSC testnet (chain 97) until this ADR is accepted.
- The settlement keeper of ADR-0018 and the MTM keepers of ADR-0032 are Ethereum-only and depend
  on a private relay of the kind ADR-0032 requires. BSC has no Flashbots, so the private-submission
  trust boundary is a design dependency, not a configuration value: without one, the D5-03
  run-dynamics rule recorded in ADR-0032 cannot be satisfied for the digital-assets class (D8),
  and automated senior settlement cannot run under its current operating rules.
- The contracts are otherwise chain-agnostic in time: every schedule is in seconds via
  `block.timestamp`, `block.number` is unused, and the governor clocks are timestamp mode. The
  one thing to prove on a BSC fork rather than argue is that strict comparisons behave when
  consecutive blocks share a timestamp.
- The frontend is build-time pinned to chain 1 and its testnets, one stable symbol, six decimals,
  Etherscan links and Ethereum-mainnet legal copy that counsel reviewed.

---

## 4. The reserve-asset admission model

### 4.1 The problem in this protocol's terms

With two assets both accepted 1:1 and both payable at par, a KYC'd holder mints with whichever
trades below a dollar and redeems whichever trades above, in one block, with no fee, no cooldown
and nothing to price against. The payoff is the spread times the size, bounded by the idle balance
of the dearer asset. Because idle reserve is a liquidity buffer rather than the book, the drain
empties the sound liquidity first and leaves every remaining holder redeeming into the impaired
asset. That is the first-come-first-served inversion ADR-0025 rejected in its own words ("a bank
run with the invariant nominally satisfied"). The mirror image, everyone redeeming the sound asset
during a depeg with no arbitrage at all, is the same harm. A design must close both sides: the
**mint side** (accepting an impaired asset at par) and the **redemption side** (choosing the sound
asset).

### 4.2 What no design can avoid, and must disclose

Under par-valued backing a reserve-asset price loss never reaches the ledger. "Outside the
cascade" is not a property this code base can grant to a loss source: the ADR-0034 Y-bis draw fires
on any `backing < supply` regardless of cause, so the instant any part of such a loss is recognised
the next direct exit draws curator and sGROVE capital. What D4(a) chooses is therefore a loss the
ledger never sees, which is the ADR-0025 optimistic-backing trade-off applied to a second asset.
It is borne by whoever has not exited when the impaired units are all that remain: under D5(b) as
a sub-par exit, under D5(c) as a frozen one. Curator first-loss and sGROVE are untouched. That is
an inversion of the cascade order for this one loss source, and it is true of the live Ethereum
deployment today (ADR-0029 §3). D4 makes the scoping explicit; either way the disclosure surfaces
must say it plainly.

### 4.3 The design space

A live price feed inside the backing aggregate is excluded by ADR-0025 (storage-only solvency
path; backing moves down on authority and up only on proof). The obvious first option, a per-token
price feed, can therefore only mean a **timelocked, governance-written haircut per asset**, and
the fastest it can land is the two-day timelock, against a March-2023-shaped USDC depeg that
resolved in about three days. Maker cut its own 48-hour delay to 16 hours during that event and
then added a delay-bypassing breaker; the two-day timelock here is the same problem.

| | Mint side | Redemption side | Depeg lands on | ADR-0025 | Add asset later | Audit delta | Precedent |
|---|---|---|---|---|---|---|---|
| **A** Governance haircut per asset, mint and redeem at the haircut | closed once written | closed once written | cascade, via the coverage ratio and the atomic junior draw (a reversible mark draws junior capital) | down leg compatible; the lift is an upward move on authority with no on-chain proof, which ADR-0025 forbids on the idle tally; feasible only as a separate per-asset impairment component mirroring the timelocked, evidence-hashed principal-impairment release, which amends ADR-0025 for that component | yes | large: reverses a Cantina trust assumption, rewrites the controller's equality guards, extends the halmos cascade proof and the ADR-0034 Z invariant | none for a stored governance haircut; Angle Transmuter is oracle-priced, which ADR-0025 excludes |
| **B** Pro-rata basket redemption | **open**: needs cap, fee or freeze | closed entirely | holders, in kind, pro rata; no FCFS | compatible | yes (zero weight until funded) | moderate: new arithmetic, per-leg rounding, two-token payouts, basket skewed by the credit layer funding in one asset | Angle Transmuter (oracle-priced mint and burn, pro-rata redeem with a collateral-ratio penalty), Reserve Protocol (pro-rata basket redemption with staked RSR as a pro-rata backstop) |
| **C** Per-asset cap, fee, designated payout asset | bounded by cap, priced by fee | **open** up to the cap (FCFS on the sound asset) | last-out holders, bounded by cap times depeg per conversion cycle | compatible | yes (cap starts at zero) | moderate: a PSM; fee routing decides whether fees become layer zero of the cascade via reserve surplus | Maker PSM (two-sided tin and tout fees and ceilings, never a mark; in March 2023 tin 0 to 1 percent, ceiling gap cut, governance delay cut 48h to 16h, then a delay-bypassing debt-ceiling breaker), Aave GSM (exposure cap, 0.2 percent fee each way, oracle-bounded freeze and unfreeze, last-resort liquidation) |
| **D** Isolated instance per asset | closed (no fungibility) | closed | that instance's holders only | untouched | deploy another stack | smallest on contracts, largest on operations; two USDfr tickers per chain; a shared backstop is a new cross-contract dependency | isolated-market lending |
| **E** Single asset per instance; the other asset enters through an external swap | closed | closed | as today | untouched | frontend routing only | zero on contracts | common |
| **F4** Accept-and-convert: secondary asset accepted at mint only, tallied separately, never payable, converted to the payout asset by treasury operations within a bounded window | bounded by cap and fee; a depegged secondary still buys USDfr at par up to the cap | closed on the secondary; the payout asset remains FCFS up to the transit balance | holders, as a frozen exit, bounded by the transit balance | compatible for the tallies; the conversion window is off-chain custody, a new trust boundary | yes | small to moderate on contracts; new privileged withdrawal path | how exchanges and PSM operators run second-asset inventory |
| **F5** Guardian freeze per asset (mint or redeem, one asset), as an overlay | closes once someone acts | closes once someone acts | unchanged | compatible (down-only, authority; the lift is timelocked) | n/a | small on mint; on redeem it adds a third state to the controller exit predicate ADR-0033 §5 left unresolved and reopens the 59-test measurement recorded there | Aave GSM OracleSwapFreezer, without the oracle and without its automatic unfreeze |

Not credible: "redeem in the asset you deposited" (the link is lost on transfer of a fungible
token; it degenerates into D); per-asset FIFO or LIFO (gameable); an external PSM that mints
USDfr against the secondary asset (its holdings must count as backing, which is C inside a second
contract).

No row that admits a second asset into one payable set closes both sides without a governance
act: A closes both only once a timelocked mark lands, two days after the depeg it answers; D and E
close both by refusing fungibility, which is the same as not admitting the asset. A design that
lets a depeg reach the cascade (A) must extend the halmos cascade proof and the ADR-0034 ordering
invariant to the new loss source, or those proofs are vacuous for that path.

### 4.4 Recommendation, and the residual it carries

Among the designs that do admit a second asset, the minimum on the mint side is the same for all
of them: a **per-asset cap**, a **per-asset mint fee**, and a **down-only guardian freeze per
asset** with a timelocked lift. What each of those actually does must be stated exactly, because
the owner will be accepting the residual:

- **The cap bounds the exposure per conversion cycle**, not in total: each time the secondary
  tally is converted and the cap headroom reopens, the exposure renews.
- **The fee sets the strike of the free option; it does not remove it.** With a secondary asset at
  price p, cap K and fee f, a KYC'd minter earns (1 - f - p) times the smaller of K and the
  payout asset's idle balance, per cycle, whenever p < 1 - f. The remaining holders bear
  (1 - p) times K in full, because the fee is routed to a fee recipient and not to reserve
  surplus. The fee is protocol revenue and a deterrent, not loss absorption. A fee wide enough to
  close a March-2023-sized depeg taxes every honest secondary mint; a commercial fee leaves that
  depeg exploitable up to the cap. Maker and Aave charge both legs; a redeem-side fee on the
  payout asset belongs in the option list.
- **The freeze is the binding control, and it is reactive.** On a 0.45-second chain whose blocks
  come from two builders and whose private submission is builder-operated, the guardian's freeze
  races the attacker's mint.
- **Designating one payout asset removes the cross-asset arbitrage on the redemption side; it
  does not close the run.** The sUSDfr queue settles in USDfr, so a queued exit reaches the payout
  asset only through the same direct-redemption door, which is first-come-first-served. During a
  secondary depeg every holder can redeem the payout asset at par until its idle balance is
  exhausted, after which the remaining holders hold USDfr backed by units the protocol will not
  pay out, with no sub-par pricing and no junior draw because backing still reads par.
  `ReserveManager.idleReserve()`, and therefore the queue's settlement budget, must count only the
  payout-asset tally.

Given that, the recommendation follows D0:

- **If the goal is entry for USDG holders, choose D5(a).** An external swap on the way in delivers
  entry with zero contract change, no registry, no reopened findings and no residual. Forest Road
  never holds USDG.
- **If the goal is to hold USDG, choose D5(b)** and accept the residual above explicitly: a
  registry present at genesis with storage reserved at the tail of the reserve struct and one
  asset listed; listing a further asset is a timelocked act that consumes an ADR-0029 §3 review
  and records the asset's decimals, scale, cap and fee in storage at listing; the solvency path
  never calls `decimals()` or `balanceOf` on any listed asset; custody predicates and the
  ADR-0033 arms become per asset, so a secondary asset whose token reverts or is paused cannot
  freeze exits in the payout asset (this is the reverting-`balanceOf` brick class, R2-M-03, that
  ADR-0025 removed, and it is the sharpest thing the registry must not reintroduce); the mint
  fee is a USDfr amount carved from the minter's credit and sent to a controller-level recipient
  set by governance, not an ADR-0031 fee-share mint, and not reserve surplus, which would make it
  layer zero of the cascade.
- **Choose D5(c) only where a conversion rail exists.** For the §0 assets it does not in issuer
  form: Binance-Peg USDC converts only through a Binance account, and a BSC USDG0 only by bridging
  to Ethereum and redeeming as a Paxos customer. During the window Forest Road custodies protocol
  reserve off-chain, which is a new trust boundary for the threat model and counsel. On the
  ledger the secondary tally is debited when units are withdrawn for conversion and the payout
  tally is credited by measured delta when they return; backing is lower by the transit amount
  for the length of the window, mint is closed for that amount and direct exits price against it.
  No in-transit receivable is ever counted on authority. A treasury withdrawal path is a new
  privileged function and a new row in the access-control matrix.

The per-asset backing invariant under D5(b) or (c) is: supply ≤ Σ min(tally, cap) + deployed
principal - impairment. A tally exceeds its cap only when governance lowers the cap or conversion
returns fewer payout units than the secondary units withdrawn; in either case backing falls by the
excess at once, mint closes, and the next direct exit prices sub-par and draws junior capital
under Y-bis. A cap reduction below the standing tally is therefore a governance-written mark that
reaches the cascade, and must be proposed as one. Units above the cap re-enter backing only when
conversion delivers payout units (proof), never by raising the cap back on authority.

What D5(b) costs: the registry is exactly the surface ADR-0030 deleted, so R2-H-02 and R2-M-03
reopen on the contracts and PM-M-02 on the frontend, and must be re-closed with the separation
the round-two audit asked for (separate "accepted for mint/redeem" from "recognized backing
value"); the controller's most heavily audited equalities change from `amount * SCALE` to
per-asset forms; Cantina's review of the controller no longer applies, and its findings 3.1.3 and
3.1.4 must be re-dispositioned against a per-asset pause and a per-asset exit interlock; the
invariant campaigns gain a per-asset backing reconciliation, the free-option property as a named
negative test, and a fee-mint reachability witness.

---

## 5. What is reopened, and what is not

| Decision | Status after acceptance |
|---|---|
| ADR-0009 single-chain | Superseded for the BSC instance. "No cross-chain messaging surface" is **kept** (D2). "No bridge risk" is **given up** for the reserve asset if D1 is (a) or (b) or a USDG0 route, and the ADR must say so in those words. |
| ADR-0030 §1 no registry | Superseded for the BSC instance under D5(b) or (c). For Ethereum, only under D6(a), and then by a separately audited upgrade under ADR-0030's "new decision and audit" rule. |
| ADR-0029 §3 admission review | Consumed by each listing; not reopened. |
| ADR-0025 solvency-path rules | Unchanged and binding on the registry: storage-only aggregate, measured-delta deposits, down on authority and up only on proof, per-asset reconcile after any upgrade. Row A would amend it for a per-asset impairment component. |
| ADR-0034 X and the cascade-ordering rule | Scoped to losses the ledger recognises, if D4(a) is accepted (§4.2). |
| ADR-0001, 0002, the cascade layers | Unchanged. |
| ADR-0003 all five classes at genesis | Reopened under D8 if BSC launches with fewer. |
| ADR-0013, 0026, 0036 governance | D3(b) is a topology change with its own disclosure; D3a(i) reopens ADR-0026 for BSC. |
| ADR-0014 layer-two target | Reopened under D3a(ii). |
| The 2026-07-29 and 2026-08-27 owner directions | Read as Ethereum only (D7). Not extended by this ADR. |

---

## 6. Consequences if accepted

**Contracts.** A chain-parameterised reserve with the registry of §4.4, per-asset scale and units,
per-asset custody predicates and arms, per-asset events and errors so the register stays
reconstructable from events; a controller whose mint and redeem name the asset; a `PaymentReceived`
payload that names the asset; deploy-time rather than compile-time decimals. Under D6(a) this is
a storage-layout change on the live Ethereum proxy, tail-append only, with the legacy scalars
migrated in the same upgrade transaction because a new tally reads zero until reconciled
(ADR-0025). **If D1 is (a) or (b), an 18-decimal asset specifically:** the whole-unit rounding in
`redeem` becomes a no-op at scale 1 and the dust and ceil-to-whole-unit reasoning in the controller
and its invariants must be re-derived, with a decision on whether ADR-0030 §1's "redemption rounds
down to whole units" survives; the BSC validator asserts the listed asset's recorded decimals
against `decimals()`; Cantina 3.1.1's overflow bound is re-derived at scale 1; the token's
single-key upgrade and mint powers get either an on-chain monitor or an explicit acceptance
mirroring ADR-0029 §3; and someone is named to perform the ADR-0029 §3 review and deliver it.

**Tests.** Per-asset backing invariant with an independent model; the cascade-ordering invariant
re-run with the new loss source scoped out (D4(a)) or in (row A); custody-predicate isolation per
asset; the free-option property as a named negative test (deposit asset X at par, redeem asset Y
must be impossible above the cap and fee); the queue's residue margin and budget re-derived per
asset; a BSC fork family with a pinned BSC block including a timestamp-tie test; the `1e12`
census (58 tracked test files across unit, integration, fork, invariant and symbolic suites)
rewritten to per-asset scale.

**Deployment and operations.** A BSC config, deploy, validate, approved-receipt and manifest
profile parallel to the mainnet set, each fail-closed on chain id 56 and the BSC asset; a BSC
testnet campaign on chain 97, which first requires adding 97 to `KnownTestnets` deliberately; a
second, independently operated set of the ADR-0018 and ADR-0032 services, with a BSC
private-submission channel accepted as a trust boundary or an explicit D8 decision that the
digital-assets class and automated settlement do not run on BSC at launch; four control Safes
re-created on BSC with owners and thresholds re-attested; keys per D10; BNB-denominated funding
and a re-derived fee policy; a paid explorer-verification plan or an alternative verifier; block
windows re-derived from wall-clock targets rather than copied. The BSC runbook is never-publish
like its Ethereum sibling, and the operational detail behind this section lives there.

**Documents.** The ADR index (a row for this record; the ADR-0009 row corrected to Locked, and
the 0009, 0029 and 0030 rows annotated with the supersession) and the Phase A record's §3
summary of ADR-0009; the public README's "Ethereum L1" and "USDC" statements; the threat model's
trust boundary 2; the invariant statements in `docs/` and the public docs; the three audit
register entries above; the frontend legal and terms copy, counsel-reviewed; every ADR-0035
disclosure surface, per instance; the operating rules' directive 1, to say "Ethereum mainnet"
explicitly.

---

## 7. Questions only Forest Road or counsel can answer

Engineering must route these, not answer them.

**Forest Road**
1. D0: the business reason and the counterparty.
2. D1: whether the request assumed Circle USDC on BSC; whether a Binance-issued wrapper, or a
   natively issued BSC dollar whose issuer counsel has not reviewed, is acceptable reserve
   custody; whether to wait.
3. Whether USDG must be *held* or only *accepted* (D0, D5).
4. Conversion rails: whether Forest Road holds, or can obtain, a Binance account for converting
   Binance-Peg USDC and Paxos customer status for USDG; the borrower off-ramp for a facility
   funded in a BSC asset, and whether the facility agreements permit it.
5. Whether the custodians, the Safe owners' signing setup, and the KYC provider support BNB
   Chain; ADR-0009's rationale was institutional-custody depth and it was not checked.
6. D3, D3a, D4, D5, D6, D7, D8, D10, D11 as tabled.
7. Whether both cascade layers are funded on BSC as a hard genesis gate, given layer two is still
   empty on Ethereum (DV-03) and origination consults neither layer.

**Counsel**
1. Whether the pending securities opinion, the offering framework counsel has adopted, and the
   ADR-0011 KYC policy extend to a BSC-facing instance and to each reserve issuer or bridge
   operator. The executed legal wrapper was scoped to the Ethereum deployment; counsel should
   confirm which of its assumptions are chain-bound.
2. Whether the regulatory status of each candidate reserve issuer or bridge operator, under
   whichever stablecoin regime counsel determines applies to the protocol and its holders,
   permits holding that token in reserve. Two dated facts counsel will want: the US Treasury
   published a proposed rule under the federal stablecoin statute on 2026-08-17, and MAS opened
   consultation on its implementing legislation on 2026-09-01.
3. Whether the same receivable may be represented on a second chain at all, and the series
   structure for BSC facilities.
4. Whether a second GROVE token may be issued on BSC and how it is characterised (D3a).
5. Points on BSC (D9).
6. Review of every BSC-facing disclosure surface, including the §4.2 statement.

---

## 8. Verification owed

**Under any answer to D1:**
- Re-confirm with Circle that no native USDC exists on BNB Chain, and with Paxos whether native
  USDG or USDG0 on BNB Chain is planned. Both facts are dated 2026-09-07.
- Confirm whether Tether has begun native USDT issuance on BSC.
- Confirm the Safe version of the four Ethereum control Safes, since address parity on BSC
  depends on it.

**Only if D1 is (a) or (b):**
- Establish BSC's fee-market semantics and whether the current BSC hard fork supports every
  opcode the pinned `cancun` EVM version can emit; if not, BSC bytecode differs from the audited
  artifacts.
- A pinned-BSC-fork test that consecutive blocks sharing a `block.timestamp` do not disturb any
  strict comparison (cure expiry, attestation expiry, unbonding, epoch close).
- Re-derive Cantina finding 3.1.1 at scale 1 for an 18-decimal asset.
- Recover the pre-ADR-0030 registry and the 2026-07-14 round-two findings from history and check
  whether that design carried caps or only a list, before re-deriving §4.4.

Sources for §0: Circle's USDC contract-address and CCTP pages; Circle's USYC-on-BNB-Chain
announcement of 2025-11-19; Sourcify's verified source for the Binance-Peg USDC proxy and
implementation, with the admin and owner slots read on 2026-09-07; CoinDesk's reports of
2023-01-10 and 2023-01-24 on the Bloomberg findings; The Block's report on the Forbes analysis and
Binance's response, 2023-02-27; the NYDFS consumer alert of 2023-02-13; Paxos's USDG
documentation and terms; the USDG0 announcements of 2025-11-18; BNB Chain's Fermi announcement
and BEP-520; arXiv 2602.15395; the Safe deployments registry; BNB Chain's BscScan-API migration
notice of 2025-12-09; DefiLlama's chain and asset supply endpoints.

---

## 9. Sizing, from this repository's own record

No money figures exist in the repository; the owner should supply audit fees from invoices. The
calendar figures below are what the record shows and are floors, since the one comparable ceremony
has not yet reached acceptance.

| | D1(d) do not deploy | D1(c) wait | Recommended path if BSC proceeds |
|---|---|---|---|
| Contracts | none | none | The registry rework touches the two most-audited contracts and 58 tracked test files. The comparable change in the other direction (removing the registry: ADR-0025 accepted 2026-07-20, ADR-0030 finalised 2026-07-24) took four days of build and two audit rounds published on 2026-07-28. Re-adding it with caps, fees, a freeze, per-asset arms and per-asset custody predicates is at least that. |
| Deployment | the chain-guard allowlist, landed 2026-09-07 | as (d), plus §8's first three items | The Ethereum path ran 18 days from owner authorization (2026-07-29) to deployment (2026-08-16), 12 more to a live keeper fleet (2026-08-28), and acceptance has not closed 22 days after deployment. A BSC ceremony repeats that with a new runbook, four Safes, a new signing domain and a second service fleet, and adds a BSC testnet stage. |
| Audit | none | none | Ethereum needed two external engagements (Corrovera, report dated 2026-08-16; Cantina, 2026-08-27, two files). The registry is new scope for both, plus a BSC deployment review. |
| Governance and counsel | this record | this record | D0 to D11, the counsel items in §7, and a new owner direction under D7. |

---

## Alternatives considered and rejected

- **A bridged or shared USDfr across chains.** Reintroduces the cross-chain surface ADR-0009
  rejected, requires a cross-chain backing view ADR-0025 forbids, and turns one audited protocol
  into a different product. Not proposed.
- **A live depeg oracle in the solvency path.** Excluded by ADR-0025; a stored mark is the
  nearest lawful form (row A) and is not recommended for D4's reason.
- **Loosening the mainnet deploy and validation scripts to accept chain 56.** Would defeat the
  fail-closed authorization chain (FRV-DSA-001). A parallel set is the only acceptable shape.
- **Deploying BSC now with single-asset code and adding USDG later by upgrade (D6(c)).** Ships the
  in-place-upgrade hazard ADR-0025 records to a live proxy and needs a second audit; rejected
  unless Forest Road accepts that cost knowingly.
