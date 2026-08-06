# Protocol Overview

Forest Road Vault is an on-chain credit protocol for speciality-finance receivables. It
brings four verticals of real-world credit on-chain under a single reserve: film & TV tax
credits, renewable-energy receivables, life-sciences royalties, and commercial real-estate
bridge loans. A fifth, marked-to-market digital-assets class sits alongside them.

> The application identifies its active network and deployment receipt. Yield is variable.
> It is the book's actual performance, nothing more. Token characterization and eligibility
> are matters for the definitive legal materials and counsel.

## The two tokens

- **USDfr**: minted 1:1 by depositing canonical USDC. It is fully backed at all
  times by the backing invariant: total supply can never exceed the reserve's value.
- **sUSDfr**: the yield-bearing ERC-4626 vault share. Deposit USDfr, receive sUSDfr at
  the current exchange rate. Realized facility/reserve income raises NAV; explicit credit
  losses and evented protocol fee-share mints can lower the per-share rate. Exit is
  through an epoch-based FIFO redemption queue.

The reserve ledger is deliberately conservative. An unsolicited USDC transfer cannot
inflate backing, while anyone may reconcile the ledger downward if live custody is ever
lower than the amount recorded. That permissionless check cannot move funds or create the
shortfall; it prevents an operator from hiding one. The protocol then fails closed until an
exact, timelocked recapitalization restores backing and its temporary authority is revoked.

## Identified-per-asset collateral

Every facility is a specific, identified receivable, assigned, lien-perfected (UCC-1),
and escrowed off-chain, represented on-chain by a **Loan NFT** that mints only when every
required off-chain fact has been attested by authorized attesters **and** every on-chain
condition holds. Escrow cannot release before the NFT exists. This is not a blind pool.

## The three-layer loss cascade

Credit losses are absorbed in a strict, non-invertible order:

1. **Curator first-loss**: subordinated capital posted per collateral class.
2. **sGROVE backstop**: a staked-GROVE coverage reserve.
3. **sUSDfr depositor principal**: only after both junior layers are exhausted.

Senior depositors are never subordinated to junior capital, and the cascade can never be
paused.

## How value moves

Deposit → mint USDfr → stake to sUSDfr → yield accrues as the book performs → request
redemption through the queue. On the credit side: originate a facility through the
attestation gate → fund (an origination fee applies) → the borrower services it →
repayments flow through the waterfall (protocol fee, then every remaining unit to senior
yield; ADR-0028 retired self-funded DSRA), then the vault crystallizes any global-HWM
performance and time-based management fees through transparent share dilution. On default,
the remedy process runs and any realized loss cascades through the three layers.

At launch, the Waterfall fee is 10% of realized gross interest, the vault performance
fee is 10% of profit above one conservative protocol-wide high-water mark, and the
management fee is 0%. Timelocked governance may vary the performance fee prospectively
up to a hard 20% cap and the management fee prospectively up to 2% per 365-day year.
Each change crystallizes the old rate first. The HWM is global, not personal: someone
entering during a drawdown shares fee-free recovery to the protocol's old peak and can
share a later fee on pre-entry gains that were deferred by performance impairment.
That exposure can exist while queued-exit impairment is zero. Performance-fee NAV
excludes temporary curator and sGROVE capital, even when that capital improves the
current redemption mark; the Stake panel compares it with the live global hurdle.

Queued exits are marked before final loss realization. The zero-recovery case applies curator and
sGROVE protection before calculating any sUSDfr impairment. Governance may replace that result
temporarily with a lower, professionally assessed senior impairment backed by a published evidence
hash. The assessment is bound to the revisioned risk snapshot and falls back to zero-recovery
pricing immediately after any default, past-due, recovery, realization, curator-capacity change,
backstop decrease, or expiry. A backstop increase is tolerated because it only adds junior
protection. The displayed queue value is therefore an estimate at the current block, not a
guaranteed settlement quote. For performance fees, the assessment separately snapshots the
junior-capital credit standing at publication so a later capacity write cannot be treated as yield.

The professional-assessment wrapper remains in the clean v1 candidate. Unless governance
publishes a current revision-bound assessment, it returns the zero-recovery result. The
recovery top-up distributor is not deployed or wired in mainnet v1; no top-up or airdrop
is promised, automatic, or included in the redemption preview.

See **How it works** for the full depositor and borrower flows, **Protocol guarantees**
for the safety spec, **Roles & governance** for the trust model, and **Security &
testing** for the review posture.
