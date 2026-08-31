# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Two primary audiences, served by one site with different needs:

- **Institutional allocators**: Forest Road-relationship LPs, family offices, and credit funds doing
  diligence on the speciality-finance book before a KYC-gated allocation. They arrive with credit
  underwriting habits: they want the collateral classes, the lien mechanics, the loss cascade, and the
  failure modes stated plainly. They read the risk and docs pages before they read the app.
- **Crypto-native yield allocators**: DeFi-fluent depositors evaluating `sUSDfr` against other
  yield-bearing synthetic dollars. They want backing, redemption mechanics, and where yield comes from
  legible fast, and they check the audit register and contract addresses themselves.

Secondary readers exist (auditors, security researchers, protocol integrators, counsel) and the
published documentation serves them, but they do not set the design priority.

## Product Purpose

Forest Road Vault is a real-world-credit protocol on Ethereum L1. It takes USDC, issues a
fully-backed synthetic dollar (`USDfr`) against it, lends that capital into identified,
lien-perfected off-chain credit facilities, and passes the interest through to a yield-bearing
ERC-4626 vault (`sUSDfr`), with a three-layer loss cascade underneath.

Success is an allocator who understands exactly what backs the dollar, where the yield originates,
and what can go wrong, before they deposit. The site exists to make an off-chain credit book
legible on-chain terms, not to generate excitement.

## Positioning

Yield is the actual performance of a named, underwritten speciality-finance book, film and TV tax
credits, renewable energy, life sciences, real estate, digital assets, sourced through Forest Road's
existing origination, with perfected security interests and a stated remedy per collateral class.
It is not farming, not rehypothecation, not a rate set by governance.

The protocol integrates no AMM, no price feed, and no external DeFi protocol; USDC is the only
external token. Off-chain facts enter only through an m-of-n attested oracle. That deliberately small
external surface, plus published-in-full review history, is the claim a neighboring protocol cannot
truthfully copy.

## Operating Context

- Public marketing and documentation site plus a wallet-connected app surface (`/app`) with mint,
  redeem, stake, yield-position, points, and transparency flows.
- Access to the app is KYC-gated; the published site is not.
- Diligence happens across the site and off it: allocators read `/risk`, `/how-it-works`,
  `/verticals/*`, `/docs/*`, the audit register at `/docs/audit`, and verify contract addresses
  against Etherscan.
- The audit register publishes every review round with severities and dispositions, including
  findings that were accepted rather than fixed. Reproduction recipes for open, exploitable
  findings are withheld under responsible disclosure.
- Live protocol parameters (LTV caps, rate tiers, concentration limits) are read from on-chain
  registries, never hardcoded in copy.

## Capabilities and Constraints

- **Deployed to Ethereum mainnet on 16 August 2026**, at block 25,768,251, from freeze `f1f1f47`.
  Bootstrap authority has been surrendered: the timelock holds `DEFAULT_ADMIN` and `UPGRADER` on
  every module and no authority role survives on any deployer EOA. The reserve token is canonical
  USDC. **Deployment is not launch**: capped-launch acceptance has not been performed, the stack
  holds only a nominal seed, and the KYC allowlist is closed to third parties.
- A **Sepolia build also exists** and is what the testnet surfaces read. That deployment retains
  bootstrap admin privileges, uses a mock stablecoin, and runs with concentration limits fully open.
  Nothing healthy on it is evidence about the production configuration. Copy that speaks about
  testnet must be conditional on the build target, never asserted absolutely.
- **External review has been conducted; do not shorten that to "audited".** Corrovera reviewed the
  4 August tree (AI-assisted, owner-dispositioned) and again against the live mainnet deployment on
  16 August; Cantina Managed reviewed the supply gateway, two files, on 27 August. Gates complete
  and independently audited are different claims, and the Corrovera report does not present itself
  as an unqualified independent audit. Several findings remain open and are published.
- Yield is variable and reflects book performance only. No target, projected, or implied APY.
- Terminology to keep exact: `USDfr` (synthetic dollar), `sUSDfr` (ERC-4626 yield vault), the
  three-layer loss cascade, perfected lien / receivable vs. marked-to-market collateral models,
  attested oracle.
- Existing implementation: Next.js App Router, Tailwind v4 design tokens in `globals.css`,
  wagmi/viem wallet layer, site and app component families under `src/components/{site,app}`.

## Brand Commitments

- **Palette and mark are binding.** FRAM navy (`#1a2744`) and its accent/on-navy ramp, the off-white
  ground, and the `fram-lockup` / `fram-mark` assets in `public/brand` carry over from Forest Road
  Asset Management's institutional identity and are not open to replacement.
- **Typefaces are binding, taken from the parent brand.** forestroad.com sets headings in
  **Merriweather** 600–700 (serif, normal tracking, near-1.0 leading at display size) and nav/UI in
  **Inter Tight** 500–600, with body copy in a neutral grotesque. The vault site follows: Merriweather
  for display, Inter Tight for UI and body, and a mono reserved strictly for on-chain strings
  (addresses, hashes, calldata). The parent's link blue `#1f8aff` is deliberately *not* adopted, a
  bright blue accent on navy is the generic on-chain look; `#9db0d4` remains the accent.
- **Expression is otherwise flexible.** Layout, section concepts, motion, and page structure may be
  redesigned when justified.
- Voice is institutional and plain: state the mechanism, state the risk, do not sell.
- **Standing direction preference (chosen 2026-08-05):** the category standard, executed straight, the arrangement an allocator already expects from an on-chain credit protocol, at full craft, with
  no ironic distance and no smuggled novelty. Craft bar is Ethena / Sky / Spark and
  Morpho / Maple / Centrifuge. Future design rounds inherit this preference unless the user revisits
  it; do not re-open it as a concept exercise.

## Evidence on Hand

- Real, verifiable: Sepolia contract addresses (`/docs/addresses`), the full audit register with
  round-by-round findings and dispositions, the protocol guarantee/invariant specification, live
  on-chain figures surfaced through the app and hero stats.
- Real, static copy: per-vertical collateral descriptions, claim types, durations, named risks, and
  remedies in `src/lib/verticals.ts`.
- Brand assets: FRAM lockups and marks, hero photography (`public/brand/hero-cover.jpg`,
  `public/hero-terrain.jpg`).
- **Absent, must never be fabricated:** customer or LP testimonials, AUM or track-record figures not
  already published, third-party partner or integration logos, benchmark comparisons, projected
  yields, mainnet launch dates, licensing or regulatory-approval claims.

## Product Principles

1. **Legibility over persuasion.** An allocator who leaves understanding the risk is a success even
   if they do not deposit.
2. **Only verifiable numbers.** Every figure shown is readable on-chain or in published
   documentation. No invented testimonials, benchmarks, AUM, or projected returns.
3. **Testnet status stays unminimized.** Sepolia-only deployment and the unchecked mainnet gates
   remain visible and plainly stated; design never softens or buries them.
4. **Counsel owns legal characterization.** Copy never characterizes the instruments as
   non-securities or implies any legal conclusion about them.
5. **Two literacies, one truth.** Credit-fund readers and DeFi-native readers get the same facts,
   sequenced for their entry point, never a different story.

## Accessibility & Inclusion

No product-specific standard was established. The codebase carries `eslint-plugin-jsx-a11y`, so
lint-level a11y correctness is an existing expectation.
