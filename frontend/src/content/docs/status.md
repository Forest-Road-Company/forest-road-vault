# Live Deployment Status

**Updated 24 November 2026.** Forest Road Vault V2 is live on Ethereum mainnet and lending to
real borrowers. Bootstrap administration has been surrendered to timelocked governance. Figures
below were read from Ethereum mainnet at finalized block 26,486,218 (16:29 UTC, 24 November 2026)
unless stated otherwise; the Stage 1 governance proposal was confirmed at block 26,486,243
(16:34 UTC, 24 November 2026). The [transparency dashboard](/transparency) shows protocol figures
live, and the [deployed-addresses page](/docs/addresses) lists every contract.

Minting USDfr and redeeming it directly for USDC require a KYC-verified address. Holding,
transferring and staking are open to any wallet that is not sanctions- or jurisdiction-blocked.

## The loan book

Fifteen active facilities hold USD 10.51 million (`10,511,311 USDfr`) of principal and accrued
interest (`10,333,442 USDfr` current principal). All are performing, every payment due so far has
been made (including the first quarterly Renewables payment date on 30 September), and past-due
exposure is zero.

| Sector | Facilities | Current principal (USDfr) | Outstanding with accrued interest | Rate | Loan-to-value | Next payment | Maturity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Renewables | 11: five USD 1m tranches to one borrower (each booked as a cash leg and a PIK leg, with 30 Sep PIK interest capitalized) plus one USD 176,577 PIK facility | 5,183,422 | 5,313,749 | 16.75% fixed | 55% | 31 Dec 2026 (30 Sep paid), then every 92 days | 29 May 2029 |
| Digital Assets (related party) | 4: USD 20, USD 2.4m, USD 2.0m and USD 0.75m cash-pay facilities | 5,150,020 | 5,197,563 | 12.5% fixed | 32.72%: collateral valued at USD 15.88m on 24 Nov (02:32 UTC) | 20 Dec 2026 (USD 20 facility); 24 Jan, 26 Jan and 2 Feb 2027 (USD 5.15m tranches), then every 90 days | 21 Sep to 4 Nov 2027 |

The per-borrower limit is 15%, measured against the larger of the book and a USD 100 million
bootstrap floor. While the book is small, that allows up to USD 15 million per borrower.

**Related party.** The digital-assets sector lends to Forest Road's own trading subsidiary, so
Forest Road is originator, servicer and an affiliate of the borrower. The facilities are for cash
management. Originations take time, and rather than leave depositor funds idle while they
complete, the protocol can lend them to the trading business against liquid digital-asset
collateral. Forest Road's digital-assets business has a strong record of deploying capital
profitably while staying liquid.

Its collateral is valued daily, each valuation is signed by two attesters, and each is checked
against the class's margin-call (65% loan-to-value) and liquidation (80%) thresholds in the same
transaction. New lending in the class may start at no more than 50% loan-to-value. On 24 November
(02:32 UTC), attested collateral across the four Digital Assets facilities stood at
USD 15,884,514 against USD 5,197,563 of principal and accrued interest (`32.72%` loan-to-value).
Any amount lent to these facilities is no longer idle cash, so until it is repaid it lowers the
daily exit capacity described under Exits.

## Where the yield comes from

The sUSDfr exchange rate rose from 1.040815 to 1.043965 USDfr in the seven days to 24 November
(blocks 26,435,966 to 26,486,218), a 0.30% gain (`0.3026%`). That is about 15.8% a year simple
(`15.78%`), or 17.1% compounded (`17.07%`). Both the Morpho sUSDfr/USDC market oracle and Pendle
SY track this same exchange rate (`1.043965`), and Pendle shows this realized rate as the
underlying APY. It is a past rate, not a forecast, and it excludes any value from the points
program.

Three things set it:

1. The loans earn a blended 14.6% a year (`16.75%` on USD 5.31 million of Renewables and `12.5%`
   on USD 5.20 million of Digital Assets), alongside USD 693,400 of idle USDC reserve (`USD 11.20`
   million total backing).
2. 70.9% (`70.88%`) of USDfr is staked (`7,925,355` of `11,182,044 USDfr`). Unstaked USDfr earns
   nothing, so sUSDfr holders receive the interest on the whole USD 10.51 million loan book, about
   1.3 times their own capital.
3. A 10% protocol fee on interest and a 10% performance fee on vault gains above the high-water
   mark come out first.

The rate moves with each of these. With all USDfr staked, the same book would produce about 11.2%
simple. The leverage works the same way on losses: a credit loss beyond the protection layers
below falls on sUSDfr holders alone.

The rate reflects interest as it is earned, before cash arrives. On 30 September the Renewables
cash legs paid 7,948.59 USDC of interest for the period since funding, and the next coupons are
due on 20 December 2026 (USD 20 Digital Assets facility), 31 December 2026 (Renewables), and
24 January, 26 January and 2 February 2027 (the USD 5.15 million Digital Assets tranches). Of the
total current principal, 24% (`24.2%`, representing 48% of Renewables principal) sits in PIK legs,
whose interest is added to principal rather than paid in cash.

## Loss protection

Losses fall first on curator first-loss capital, then on the sGROVE coverage reserve, and only
then on sUSDfr holders.

| Layer | Capital on 24 November | How it works |
| --- | --- | --- |
| 1. Curator first-loss, posted by Forest Road | 500,000 USDfr in Renewables; 1 USDfr in Digital Assets | Absorbs losses in its own class only |
| 2. sGROVE coverage reserve | 10,000 USDfr | Shared by every class; a single loss can use all of it |
| 3. sUSDfr holders | 7,925,355 USDfr of vault assets | Bears every loss the first two layers do not cover |

In Renewables, Forest Road's own first-loss capital equals 9.6% of current principal (`500,000`
USDfr against `5,183,422` USDfr), at least an order of magnitude more than the default rate we
expect on these facilities. Digital Assets relies mainly on its daily-attested liquid collateral,
described above (`32.72%` current loan-to-value).

Forest Road deposited the 10,000 USDfr in the coverage reserve on 14 October
([transaction](https://etherscan.io/tx/0xb04a7d0c16a1b677834cf783fe0e6e8bd554562e380e5c7b2e3dcc7ec5d2ad76)).
The reserve earns nothing and can only be drawn to cover a loss.

## Exits

sUSDfr exits run only through the redemption queue:

- Each request waits out a 21-day minimum hold and cannot be cancelled.
- After the hold, requests fill strictly first in, first out.
- Settlement can pay out at most 1.67% of idle USDC in each one-day window: 11,580 USDC on 24
  November, from 693,400 USDC idle.
- Each request is paid at the share value when it settles, not when it is made.

On 24 November, 3,079.55 sUSDfr was queued across four open requests (`14` earlier requests have
already completed).

The cap is a share of idle cash, so it shrinks as cash goes out. With no new deposits or
repayments, about 441,000 USDC could be paid out in the first 60 days. Beyond that, exits wait
for new cash: deposits, coupons (starting 20 and 31 December 2026 and late January / early
February 2027) and principal, with final Renewables maturity in May 2029. Direct USDfr-to-USDC
redemption by verified holders is instant but draws on the same idle reserve.

In a large exit, waits would run to months. The queue exists so that no holder can force a fire
sale or overtake another.

USDfr holders, including those who have left sUSDfr, can also sell USDfr for USDC in the
[USDfr/USDC Uniswap pool](https://app.uniswap.org/explore/pools/ethereum/0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55)
at the market price, which can differ from par. Forest Road intends to keep USDfr as liquid as is
feasible while still earning a high rate for sUSDfr holders.

## Security findings in the deployed contracts

The currently active Ethereum mainnet proxies have not yet been upgraded for the LMV remediation
release, so the deployed contracts still carry open findings from Corrovera Security's reviews and
from our continuous testing on mainnet forks. None has caused a loss. The two most relevant to
depositors, LMV-09 and LMV-18, could only cause one if a borrower stopped paying:

- LMV-09 needs a borrower to miss a payment and the loan to be marked past due, which the
  contracts allow only 21 days after the missed date. The resulting mark must also exceed the
  first-loss capital and coverage reserve in front of depositors; until it does, it does not lower
  exit prices at all. On top of that, LMV-09 needs about USD 6 million of capital, aged queue
  positions, a particular keeper ordering, and a KYC-approved address.
- LMV-18 needs a facility to default and a loss to be realized.

Every payment due so far has been made, and no payment falls due before 20 December 2026 (for the
USD 20 digital-assets facility), 31 December 2026 (for Renewables), or 24 January 2027 (for the
USD 5.15 million digital-assets tranches). So no borrower can miss a payment before then, and no
loan can be marked past due before 10 January 2027 (for the USD 20 facility) or 21 January 2027
(for Renewables). A default for any other reason, such as insolvency, would need Forest Road's
servicer and both attesters to declare it.

**Upgrade status (24 November 2026).** Both LMV-09 and LMV-18, together with the contract
findings from Corrovera Security's November reviews, are fixed in audited commit `ee9b228a`
(`ee9b228ad05e5a5888c1aa496ea53318036d37a3`), which passed Corrovera's independent re-audit
(`PASS` on the delta remediation, 24 November 2026) and full hosted CI security gates (`66/66`).
All 15 Stage 1 release-monitor components (deployed 20 November) and all 38 newly compiled
Stage 2 contracts and libraries from `ee9b228a` (deployed 24 November, alongside 4 reused audited
components) are finalized on Ethereum mainnet and verified `exact_match` on Sourcify.

The upgrade runs in two timelocked governance stages:

1. **Stage 1 (Preliminary release monitor) — LIVE.** Submitted on 24 November 2026 at 16:34 UTC
   ([transaction](https://etherscan.io/tx/0x83a86e829acec35568c6a1040f57dc4ebcb0dbe99f49d524232fc4044948f698),
   proposal ID `0xd14e120817bfd084d717dd230118014889c4909d51eb01ec3694a4255c102ce1`). Voting
   opens **25 November 2026 (16:34 UTC)**, closes **27 November 2026 (16:34 UTC)**, can queue on
   **27 November**, and can execute from **29 November 2026 (16:34 UTC)**.
2. **Stage 2 (Core LMV proxy upgrades) — Pending Stage 1 completion.** Follows immediately after
   Stage 1 executes and installs the audited `ee9b228a` implementations across the core protocol
   proxies before **21 January 2027**. **Until Stage 2 executes, the live proxies remain on their
   pre-LMV implementations and LMV-09 / LMV-18 remain Open on chain.**

Separately, an off-chain operational update (`FRV-NEW-02` in the [audit register](/docs/audit))
remains open pending rollout and verification of the updated liquidation-bot image (cold-block gas
override and per-marked-leg gas scaling) alongside Stage 2 readiness.

| Finding | Relevant only if | Earliest on today's book | Status and plan |
| --- | --- | --- | --- |
| LMV-09 | A borrower misses a payment and the loan is marked past due | 21 January 2027 (10 January for the USD 20 facility; 14 February+ for the USD 5.15m Digital Assets tranches) | Open on live proxies. Fixed and Corrovera re-audited (`ee9b228a`); Stage 2 components deployed & Sourcify-verified; Stage 1 proposal `0xd14e…2ce1` live (submission tx [`0x83a8...f698`](https://etherscan.io/tx/0x83a86e829acec35568c6a1040f57dc4ebcb0dbe99f49d524232fc4044948f698)); Stage 2 upgrade follows before 21 January 2027 |
| LMV-18 | A facility defaults and a loss is realized | No payment can be missed before 20 December 2026 (31 December for Renewables), and no facility has defaulted or taken a loss | Open on live proxies. Same fix, verification and Stage 1 to Stage 2 rollout plan |

A governance upgrade takes at least five days from proposal: a one-day delay, a two-day vote and a
two-day Timelock. We will link the Stage 2 proposal here when it is submitted. Other open,
accepted and deferred findings, with their exact conditions, are in the
[audit register](/docs/audit).

## Changes since 14 October

| Date | Change |
| --- | --- |
| 24 Nov | Stage 1 governance proposal submitted on Ethereum mainnet ([`0x83a8...f698`](https://etherscan.io/tx/0x83a86e829acec35568c6a1040f57dc4ebcb0dbe99f49d524232fc4044948f698)); voting opens 25 Nov, earliest execution 29 Nov. All 38 new Stage 2 contracts and libraries from audited commit `ee9b228a` deployed and Sourcify-verified (`exact_match`). Live proxies remain unchanged until governance executes. |
| 24 Nov | Corrovera Security completed independent delta re-audit of commit `ee9b228a` (`PASS` on delta remediation), and exact-commit hosted CI security gates completed `66/66` green. |
| 20 Nov | All 15 Stage 1 preliminary release-monitor components deployed and verified on Ethereum mainnet. |
| 17 Nov | Renewables facility 15 originated and funded (`176,577 USDfr` PIK leg at 16.75% fixed, maturing 29 May 2029). |
| 4 Nov | Digital Assets facility 14 originated and funded (`750,000 USDfr` at 12.5% fixed, maturing 4 November 2027). |
| 28 Oct | Digital Assets facility 13 originated and funded (`2,000,000 USDfr` at 12.5% fixed, maturing 28 October 2027). |
| 26 Oct | Digital Assets facility 12 originated and funded (`2,400,000 USDfr` at 12.5% fixed, maturing 26 October 2027). |
| 21 Oct | Morpho sUSDfr/USDC borrowing and lending page (`/markets`) deployed to production (entry switches subsequently enabled separately by governance/owner). |

## Limits and operating assumptions

- The USD 100 million value is a bootstrap concentration floor, not a deposit cap. It does not
  authorize minting USDfr without USDC and waives no concentration check.
- Two attesters must both sign each credit fact. If either is unavailable, attested servicing
  waits until governance replaces it.
- An extreme loss that exhausts every layer can leave a sub-USDC-unit rounding remainder.
  Value-sensitive operations then fail closed until a funded, rate-limited worker supplies the
  exact correction.
- The module-wide Guardian pause has been rehearsed on a fork but not yet run as a live drill.

Reviews reduce risk; they do not prove that software, custody, governance, keepers, signers or
real-world loan facts cannot fail.
