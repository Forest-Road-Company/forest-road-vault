# Protocol Overview

Forest Road Vault is an on-chain credit protocol for specialty finance receivables. It
brings three sectors of Forest Road's credit book on-chain under a single reserve:
media & entertainment (tax credits and contracted receivables), renewable energy, and a
marked-to-market digital-assets sector. The on-chain CollateralRegistry also carries
life-sciences and real-estate collateral classes that are not currently marketed as
sectors.

> The application shows which network and deployment it reads. Yield is variable.
> It is the book's actual performance, nothing more. Token characterization and eligibility
> are matters for the definitive legal materials and counsel.

## The two tokens

- **USDfr**: minted 1:1 by depositing canonical USDC. Every mint checks the backing
  invariant. An extreme loss that exhausts all three loss-bearing layers can leave a
  sub-USDC-unit rounding remainder; value-sensitive operations then fail closed until an
  exact, rate-limited recapitalization restores the inequality.
- **sUSDfr**: the yield-bearing ERC-4626 vault share. Deposit USDfr, receive sUSDfr at
  the current exchange rate. Earned cash and PIK interest stream into NAV before receipt;
  explicit credit losses and evented fee-share mints can lower the per-share rate. Holder
  redemption of sUSDfr uses an epoch-based FIFO queue.

The reserve ledger is deliberately conservative. An unsolicited USDC transfer cannot
inflate backing, while anyone may reconcile the ledger downward if live custody is ever
lower than the amount recorded. That permissionless check cannot move funds or create the
shortfall; it prevents an operator from hiding one. The protocol then fails closed until an
exact, timelocked recapitalization restores backing and its temporary authority is revoked.

## Identified-per-asset collateral

Every facility is a specific, identified asset, represented on-chain by a **Loan NFT** that
mints only when every required off-chain fact has been attested by authorized attesters **and**
every on-chain condition holds. Receivable facilities are assigned, lien-perfected (UCC-1) and
escrowed off-chain; digital-asset facilities are secured by collateral that is marked to market.
Escrow cannot release before the NFT exists. This is not a blind pool.

## The three-layer loss cascade

Credit losses are absorbed in a strict, non-invertible order:

1. **Curator first-loss**: subordinated capital posted per collateral class.
2. **sGROVE backstop**: a USDfr coverage reserve held by the sGROVE contract and funded
   through `fundCoverage()`. It is not staked GROVE. Staking moves GROVE and never touches
   the coverage reserve; the two pools are held apart by the
   `invariant_sgrove_usdfrCustodyExact` invariant.
3. **sUSDfr depositor principal**: only after both junior layers are exhausted.

Senior depositors are never subordinated to junior capital, and the cascade can never be
paused.

## How value moves

Deposit USDC → mint USDfr → stake to sUSDfr → earned interest streams into the exchange
rate → request sUSDfr redemption through the queue. A USDfr holder may also redeem USDfr
directly through the controller, subject to its current price, KYC and safety gates. On the credit side: originate a facility through the
attestation gate → fund (an origination fee applies) → the borrower services it →
earned cash and PIK interest is allocated continuously (protocol interest fee first, then
the senior leg), while actual repayments flow through the waterfall without recognizing the
same income twice. The vault crystallizes any global-HWM performance and time-based management
fees through transparent share dilution. On default, earning stops, the remedy process runs and
any realized loss cascades through the three layers.

Accrual uses a frozen facility basis. PIK can be earned continuously without changing contractual
principal every block; it capitalizes into principal only at the facility's scheduled compounding
boundary. Keeper checkpoints make those boundaries and other lifecycle changes explicit, while
the read path remains constant-time.

At launch, the Waterfall fee is 10% of earned gross interest, the vault performance
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

The professional-assessment wrapper is deployed in Ethereum V2. Unless governance
publishes a current revision-bound assessment, it returns the zero-recovery result. The
recovery top-up distributor is not deployed or wired in V2; no top-up or airdrop
is promised, automatic, or included in the redemption preview.

Ethereum V2 is live and lending. See [Live deployment status](/docs/status) for the current
loan book, what has run on mainnet, and the operating limits that apply, and the
[how-to guide](/docs/how-to) to use the app.

See [How it works](/how-it-works) for the full depositor and borrower flows,
[Protocol guarantees](/docs/guarantees) for the safety spec,
[Roles & governance](/docs/roles-and-governance) for the trust model, and
[Security & testing](/docs/security) for the review posture.
