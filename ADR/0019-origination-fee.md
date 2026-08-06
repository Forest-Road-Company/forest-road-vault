# ADR-0019 — Origination fee surface (OID mechanics at funding)

**Status:** Accepted (2026-07-10, user direction: "add the origination fee to the
plan"). Rates are launch defaults pending the pre-mainnet economic review.

## Decision

A per-class **origination fee**, charged at facility funding, using standard OID
(original-issue-discount) mechanics: the borrower nets `principal − fee`; the claim —
the facility NFT, registry exposure, and treasury `deployedTo` — remains the FULL
principal. Default **200 bps** (`Config.DEFAULT_ORIGINATION_FEE_BPS`), per-class
governance-set (`WaterfallEngine.setOriginationFee`), hard-capped at **10%**
(`MAX_ORIGINATION_FEE_BPS`), zero allowed (a class can be free).

Market grounding (2026 research): mid-market speciality finance ~1–3 pts (compressed to
~1 pt equivalents in 2025); hard-money/RE bridge 1–4 pts; venture debt ~1–2% plus
warrants; film pre-sale/tax-credit loans ~2%; Goldfinch 10% of interest; Maple ~70–90
bps all-in. The 2% launch default sits inside the target verticals' observed range
(governance decision). This restores one of Forest Road's brief-Part-2 revenue
surfaces (origination/underwriting) on-chain; USD.AI likewise carries an origination
fee surface (governance-set).

## On-chain mechanics (why capitalization)

In `WaterfallEngine.fund`:
1. Fee is floored to a whole stable unit (dust favors the borrower).
2. `recordDeployment` transfers `principal − fee` of stables to the borrower
   (deployed += P − fee).
3. `ReserveManager.recordFeeCapitalization(tokenId, fee)` raises deployed by the fee
   WITHOUT token movement — the fee's stables never left the treasury, so backing
   rises by exactly the fee and `deployedTo == P` (all Phase C–F reconciliation
   invariants hold unchanged).
4. `controller.mintYield(feeRecipient, fee)` tokenizes the fee against that raised
   backing; the mint's ADR-0012 assertion keeps the accounting tight.

Rejected alternatives: net-funding with `deployedTo = P − fee` (breaks the
exposure == pending + outstanding invariant and understates the claim); charging the
fee out of the first repayment (origination fees are earned at closing, and deferral
mixes fee accrual with interest routing); a separate borrower fee payment (off-chain
complexity with no accounting benefit).

Consequence to note honestly: on an immediate default, the write-down covers the full
principal P even though only P − fee of cash was at risk — the fee was recognized as
income at close, which is exactly how OID works; the cascade's exposure to it is
bounded by the 10% cap. `recordFeeCapitalization` is CREDIT_ROLE-gated and, like
`recordPrincipalReturn`, trusts the credit layer's same-transaction discipline (the
WaterfallEngine only calls it with fee stables demonstrably retained in the same call).

No fee flows to GROVE holders automatically — routing stays a governance parameter
(`feeRecipient`), mirroring USD.AI's policy-dependent value accrual and the safer
Part 0.5 posture.
