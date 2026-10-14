# Live Deployment Status

**Updated 14 October 2026.** Forest Road Vault V2 is live on Ethereum mainnet and lending to
real borrowers. Bootstrap administration has been surrendered to timelocked governance. Figures
below were read from Ethereum mainnet at block 26,190,598 (12:00 UTC, 14 October 2026) unless
stated otherwise. The [transparency dashboard](/transparency) shows them live, and the
[deployed-addresses page](/docs/addresses) lists every contract.

Minting USDfr and redeeming it directly for USDC require a KYC-verified address. Holding,
transferring and staking are open to any wallet that is not sanctions- or jurisdiction-blocked.

## The loan book

Eleven facilities hold USD 5.04 million of principal and accrued interest. All are performing, and
every payment due so far has been made: the first quarterly payment date, 30 September, was met
the same day.

| Sector | Facilities | Principal (USDfr) | Outstanding with accrued interest | Rate | Loan-to-value | Next payment | Maturity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Renewable energy | 10: five USD 1m tranches to one borrower, each booked as a cash leg and a PIK leg | 5,000,000 | 5,040,624 | 16.75% fixed | 55% | 31 Dec 2026 (30 Sep paid), then every 92 days | 29 May 2029 |
| Digital assets (related party) | 1 | 20 | 20.16 | 12.5% fixed | Under 0.01%: collateral valued at USD 18.61m on 14 Oct | 20 Dec 2026 (its first), then every 90 days | 21 Sep 2027 |

The per-borrower limit is 15%, measured against the larger of the book and a USD 100 million
bootstrap floor. While the book is small, that allows up to USD 15 million per borrower.

**Related party.** The digital-assets sector lends to Forest Road's own trading subsidiary, so
Forest Road is originator, servicer and an affiliate of the borrower. The facility is for cash
management. Originations take time, and rather than leave depositor funds idle while they
complete, the facility can lend them to the trading business against liquid digital-asset
collateral. Forest Road's digital-assets business has a strong record of deploying capital
profitably while staying liquid.

Its collateral is valued daily, each valuation is signed by two attesters, and each is checked
against the class's margin-call (65% loan-to-value) and liquidation (80%) thresholds in the same
transaction. New lending in the class may start at no more than 50% loan-to-value. Any amount lent
to the facility is no longer idle cash, so until it is repaid it lowers the daily exit capacity
described under Exits.

## Where the yield comes from

The sUSDfr exchange rate rose from 1.016691 to 1.022563 USDfr in the seven days to 14 October, a
0.58% gain. That is about 30% a year simple, or 35% compounded. Pendle, where sUSDfr and USDfr
markets opened on 7 October, shows this realized rate as the underlying APY. It is a past rate,
not a forecast, and it excludes any value from the points program.

Three things set it:

1. The loans pay 16.75% a year.
2. Only 43% of USDfr is staked. Unstaked USDfr earns nothing, so sUSDfr holders receive the
   interest on the whole USD 5.0 million book, about 2.1 times their own capital.
3. A 10% protocol fee on interest and a 10% performance fee on vault gains above the high-water
   mark come out first.

The rate moves with each of these. With all USDfr staked, the same book would produce about 12%.
The leverage works the same way on losses: a credit loss beyond the protection layers below falls
on sUSDfr holders alone.

The rate reflects interest as it is earned, before cash arrives. On 30 September the cash legs
paid 7,948.59 USDC of interest for the period since funding, and the next coupons are due on 31
December 2026. Of the principal, 46% sits in PIK legs, whose interest is added to principal rather
than paid in cash.

## Loss protection

Losses fall first on curator first-loss capital, then on the sGROVE coverage reserve, and only then
on sUSDfr holders.

| Layer | Capital on 14 October | How it works |
| --- | --- | --- |
| 1. Curator first-loss, posted by Forest Road | 500,000 USDfr in Renewable Energy; 1 USDfr in Digital Assets | Absorbs losses in its own class only |
| 2. sGROVE coverage reserve | 10,000 USDfr, deposited by Forest Road at 12:37 UTC | Shared by every class; a single loss can use all of it |
| 3. sUSDfr holders | 2,375,217 USDfr of vault assets | Bears every loss the first two layers do not cover |

In Renewable Energy, Forest Road's own first-loss capital equals 10% of principal, at least an
order of magnitude more than the default rate we expect on these facilities. We believe depositors
can be very confident in that protection. Digital Assets relies mainly on its collateral,
described above.

Forest Road deposited the 10,000 USDfr in the coverage reserve on 14 October
([transaction](https://etherscan.io/tx/0xb04a7d0c16a1b677834cf783fe0e6e8bd554562e380e5c7b2e3dcc7ec5d2ad76)).
The reserve earns nothing and can only be drawn to cover a loss.

## Exits

sUSDfr exits run only through the redemption queue:

- Each request waits out a 21-day minimum hold and cannot be cancelled.
- After the hold, requests fill strictly first in, first out.
- Settlement can pay out at most 1.67% of idle USDC in each one-day window: 8,164 USDC on 14
  October, from 488,874 USDC idle.
- Each request is paid at the share value when it settles, not when it is made.

On 14 October, 1,888.52 sUSDfr was queued in five requests. The two requests that had completed
their hold were each filled within 30 seconds of becoming eligible.

The cap is a share of idle cash, so it shrinks as cash goes out. With no new deposits or
repayments, about 311,000 USDC could be paid out in the first 60 days. Beyond that, exits wait for
new cash: deposits, coupons (the next on 31 December 2026) and principal, with final maturity in
May 2029. Direct USDfr-to-USDC redemption by verified holders is instant but draws on the same
idle reserve.

In a large exit, waits would run to months. The queue exists so that no holder can force a fire
sale or overtake another.

USDfr holders, including those who have left sUSDfr, can also sell USDfr for USDC in the
[USDfr/USDC Uniswap pool](https://app.uniswap.org/explore/pools/ethereum/0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55)
at the market price, which can differ from par. Forest Road intends to keep USDfr as liquid as is
feasible while still earning a high rate for sUSDfr holders.

## Security findings in the deployed contracts

The deployed contracts carry open findings from Corrovera Security's reviews and from our
continuous testing on mainnet forks. None has caused a loss. The two most relevant to depositors,
LMV-09 and LMV-18, could only cause one if a borrower stopped paying:

- LMV-09 needs a borrower to miss a payment and the loan to be marked past due, which the
  contracts allow only 21 days after the missed date. The resulting mark must also exceed the
  first-loss capital and coverage reserve in front of depositors; until it does, it does not lower
  exit prices at all. On top of that, LMV-09 needs about USD 6 million of capital, aged queue
  positions and a particular keeper ordering, and the participant must be KYC-approved. Today
  every KYC-approved address belongs to Forest Road, so no outside party could carry it out.
- LMV-18 needs a facility to default and a loss to be realized.

Every payment due so far has been made, and no payment falls due before 31 December 2026 (20
December for the USD 20 digital-assets facility). So no borrower can miss a payment before then,
and no loan can be marked past due before 21 January 2027 (10 January for that facility). A
default for any other reason, such as insolvency, would need Forest Road's servicer and both
attesters to declare it. We will have both findings fixed, retested by Corrovera Security and
executed through governance before 21 January 2027.

| Finding | Relevant only if | Earliest on today's book | Status and plan |
| --- | --- | --- | --- |
| LMV-09 | A borrower misses a payment and the loan is marked past due | 21 January 2027 (10 January for the USD 20 facility) | Open. Fixed, retested and executed before 21 January 2027 |
| LMV-18 | A facility defaults and a loss is realized | No payment can be missed before 31 December 2026, and no facility has defaulted or taken a loss | Open. Same plan |

A governance upgrade takes at least five days from proposal: a one-day delay, a two-day vote and a
two-day Timelock. We will link the proposal here when it is made. Other open findings, with their
conditions, are in the [audit register](/docs/audit).

## Changes since 27 September

| Date | Change |
| --- | --- |
| 14 Oct | Forest Road deposited 10,000 USDfr into the sGROVE coverage reserve, the second loss layer. |
| 12 Oct | FRV-008 executed: Digital Assets valuations may now be up to 36 hours old (was 24), and a margin call's cure window is 36 hours (was 24). |
| 7 Oct | Pendle markets for sUSDfr and USDfr opened. |
| 4 Oct | FRV-006 executed: a single facility can now carry both cash and PIK interest. |
| 30 Sep | FRV-007 executed: removed the fixed gas floor on USDfr and sUSDfr balance changes. The same day, the first quarterly payment date was met: the cash legs paid 7,948.59 USDC of interest. |
| 29 Sep | FRV-005 executed: upgraded five core contracts for mixed cash and PIK interest and approved a borrower payout destination. |

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
