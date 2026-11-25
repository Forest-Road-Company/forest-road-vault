# ADR 0041 Morpho quote issuance and expiry

**Status:** Accepted and deployed in production (`https://forestroadvault.com/markets`; lending,
borrowing and Treasury supply entry switches live on Ethereum mainnet).

**Date:** 2026-10-21

## Context

S1021MF-01 showed that projecting 300 seconds from an accepted Ethereum head can leave only
210 seconds of protection when that head is already 90 seconds old. RPC latency further reduces
the interval. Repayment then reverts atomically, wasting gas and delaying an urgent exit.

## Decision

Keep one canonical, block-pinned market snapshot and the reviewed exact future AdaptiveCurveIrm
view on its original stored state. Validate the pinned hash and a fresh latest head before the
forward view and again after it. Bound the complete read to 15 seconds, using a deadline timer,
wall-clock progression and monotonic elapsed time. Reject late results and backward clocks.

Choose the projection timestamp after prerequisite reads and the first head validation. Round
that wall-clock anchor up to a second and add 300 seconds, the full 15-second read budget,
the already-permitted 30-second future-head skew and a 12-second execution margin. Subtract
the pinned block timestamp to obtain the actual projection duration. The forward IRM view
shifts the stored lastUpdate back by that duration; new-debt Max interest uses the same duration.
No stored timestamp subtraction may underflow.

Issue the quote only after final canonical/latest-head validation. Record issuedAt and an
exclusive expiresAt exactly 300,000 milliseconds later. The projection covers expiry plus at
least the permitted 30-second skew and one slot because all remaining reads fit within the
reserved budget. This is conservative interest headroom, not a prediction of price or other
market participants' transactions. The separate 30-second display freshness rule remains.

Reject an expired quote after all EOA simulation, RPC alignment and gas estimation, immediately
before wallet handoff. Check Safe expiry after simulation, identity and nonce reads, and again
after any browser proposal reservation, immediately before SDK handoff. Keep a pending flow's
displayed expiry pinned to the quote used for its actual calls, not a background refresh.

## Alternatives

A fixed block-relative 390-second horizon still loses protection to read latency. A fixed
larger duration can work with a strict budget, but an issuance-based timestamp makes the
validity interval explicit and avoids coupling it invisibly to the oldest accepted head.
Continuously raising allowances alone does not correct repayment cash checks or Max calculations.
Introducing an on-chain expiry wrapper would change the reviewed transaction surface and is
outside this frontend repair.

## Limits and verification

The browser clock and RPC remain trust inputs. The deadline bounds accepted reads, not the
lifetime of an underlying provider request. A frontend expiry cannot cancel an already-open
wallet request or an existing Safe proposal, and the Morpho call ABI has no deadline. Refresh
and review before signing after expiry; execution beyond the horizon has no interest guarantee.
Price changes, intervening market transactions and liquidation risk still require fresh review.
If proposal reservation consumes the quote lifetime, do not send it or silently clear its
uncertain local intent; reconcile that record through the existing recovery process.

Regression tests cover heads aged 0, 89 and 90 seconds, nonzero read latency, final-head changes,
timeout and clock faults, exact expiry and expiry plus one millisecond, wallet and Safe guards,
repay-all, and both Max calculations. Real pinned-fork checks exercise the actual IRM at its
800% APR ceiling. Treasury call bytes, the 50,000 USDC amount and the reviewed generator pin
are unchanged. All entry switches remain off pending the existing release gates.
