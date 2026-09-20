# Curator Subscription Vault on Solana

Status: implementation candidate, updated 20 September 2026 after the owner-provided review.
Counsel and a specialist Solana reviewer must approve the final design and deployment before any
mainnet use. Solana mainnet deployment remains human-owned.

This program is a settlement ledger and escrow for bilateral curator agreements. It does not
change the Ethereum or BSC credit systems. A curator position is a non-transferable program
account. There is no receipt token and no secondary-market path.

## Purpose and boundaries

The program:

- accepts classic SPL USDC from allowlisted wallets;
- records the hash of the wallet's executed agreement;
- snapshots lock and notice terms when principal opens;
- attributes every treasury draw, return and recorded loss to one position;
- accrues the agreement's fixed coupon continuously on Actual/360;
- permits payment only for coupon earned through a completed UTC month;
- pays coupons from a separate funded pool through a permissionless crank; and
- records complete transition events for operations and an off-chain indexer.

It does not bridge curator funds, post Ethereum first-loss capital itself, issue a token, promise
pool liquidity, guarantee that coupons are funded, or compute points on chain. Forest Road's
treasury operates the cross-chain leg under the bilateral agreement.

## Authorities

| authority | powers |
|---|---|
| Admin | Initialize while it is the program upgrade authority, set future rates and terms, rotate operational authorities and the treasury account, pause or unpause deposits and draws, record a supported loss, and propose a new admin. |
| Pending admin | Accept a proposed two-step admin transfer. |
| Allowlist authority | Allowlist or revoke wallets and set or clear a position payout halt. |
| Treasury authority | Draw and return a position's principal, fund coupons, recover measured token surplus, and return unused accounted coupon funding only after complete vault wind-down. |
| Emergency authority | Add restrictions only: pause deposits and draws or halt one position's coupon payout. It cannot clear either restriction. |
| Curator | Deposit, request or cancel notice, withdraw eligible and liquid principal, and close an empty position. |
| Anyone | Call `pay_coupon` for a position once completed-month coupon is payable and funded. |

Production administration is intended for a reviewed 2-of-4 Squads with a time lock. The
emergency signer is separate and has no transfer power. `propose_admin` and `accept_admin` prevent
a mistyped address from immediately orphaning administration. A pending proposal has no expiry;
the current admin cancels it by proposing itself, and remains fully in control until acceptance.
`set_authorities` rejects zero
addresses and rotates the allowlist, treasury and emergency authorities together with a live
treasury token account owned by the new treasury authority.

Pause is deliberately narrow. It blocks deposits and treasury draws. It does not block principal
returns, notices, withdrawals, coupon funding or accrual. A payout halt blocks only the coupon
transfer for one position; earned coupon remains owed. Only the admin may clear a global pause,
and only the allowlist authority may clear a payout halt. Neither flag freezes a curator's
eligible principal exit. A halted position with unpaid coupon also cannot close until the
allowlist authority clears the halt and the coupon is paid.

The global pause alone does not stop a coupon transfer. A completed-month coupon whose earning
period straddles a screening hit can still be paid by any cranker unless the emergency authority
halts that position before the payment transaction lands. A later halt cannot claw back a payment.
This timing and the fact that screening cannot freeze principal exit belong in the agreement and
counsel review.

The program assumes these operational authorities follow their mandates. In combination, the
allowlist and treasury authorities can create and fund a position whose owner cooperates with
them, and the admin can record supported losses when the launch policy permits it. On-chain
accounting cannot distinguish a collusive position from a real bilateral agreement. Production
key separation, Squads policy, signed agreements and operating controls are therefore part of the
trust boundary.

### Decision and custody record

The following implementation facts were recorded on 20 September 2026. They are not a substitute
for the listed production approvals.

| item | implementation candidate | decider and status |
|---|---|---|
| Principal loss policy | `principal_at_risk` is immutable after initialization; the devnet rehearsal enables it. | Forest Road owner with counsel: **production choice pending**. |
| Coupon convention | Actual/360, completed UTC months, forward-only rate epochs. | Forest Road owner with counsel: **agreement confirmation pending**. |
| Opening terms | Devnet uses 90-day lock, 90-day notice and a 1,250 bps rehearsal rate. The rate is rehearsal data, not a production decision. | Forest Road owner with counsel: **production values pending**. |
| Admin and treasury custody | Reviewed 2-of-4 Squads with a time lock; treasury authority stays in that Squads. | Forest Road owner: **production Squads and owners pending**. |
| Allowlist authority | May halt and is the only authority that may clear a payout halt. | Forest Road owner: **placement inside the time-locked Squads or a separate reviewed authority pending**. |
| Emergency authority | Separate one-way signer that may only add a pause or payout halt. | Forest Road owner: **signer selection pending**. |
| Upgrade authority | Full program custody while retained. Transfer, time-lock and any later freeze require an explicit ceremony and recovery plan. | Forest Road owner: **custody and freeze decision pending before mainnet**. |

No mainnet manifest may mark these gates complete without a dated owner record and the required
counsel decision. Operational addresses and approval evidence belong in that manifest rather than
in this design document.

## Accounts and allocation

`Config`, at PDA seed `config`, is version 1 and is allocated 650 bytes including Anchor's
eight-byte discriminator. It stores:

- admin, pending admin, allowlist, treasury and emergency authorities;
- the pinned USDC mint, program principal account, program coupon account and treasury account;
- terms, Actual/360 day count, at-risk policy, pause state and up to 16 forward-only rate epochs;
- total principal, total drawn, coupons funded and paid, aggregate coupon owed and position count;
- PDA bump and 128 bytes reserved for a future compatible layout.

`Position`, at PDA seeds `position, owner`, is version 1 and is allocated 260 bytes including the
discriminator. It stores:

- immutable owner, current agreement hash and allowlist state;
- snapshotted lock and notice terms;
- principal and the part of that position's principal currently drawn;
- opening, lock, notice and eligibility timestamps;
- coupon checkpoint, payment boundary, total owed, currently payable and carried remainder;
- cumulative recorded loss, payout-halt state, PDA bump and 64 reserved bytes.

Every instruction checks the account version. The reserved regions leave room for a later layout,
but they do not migrate it automatically. Any version bump must ship a separately reviewed,
admin-gated migration that preserves every balance and keeps withdrawals available; until that
instruction executes, the new program will refuse an older account version.

## Coupon accounting

Rates are basis points on Actual/360. The first epoch begins at initialization. Later epochs must
start in the future, strictly after the previous epoch, at most two years ahead, and use a rate
from 1 to 10,000 basis points. Sixteen epochs fit in this account version.

Accrual uses checked integer arithmetic and carries a `u128` fractional remainder. Principal
changes checkpoint earned coupon before changing the basis, so accrued value is path independent
apart from its exact carried remainder.

`coupon_owed` is all earned but unpaid whole USDC base units. `coupon_payable` is the subset earned
through the latest completed UTC month. A deposit, withdrawal or loss after a month boundary
first makes the completed-month amount payable, then accrues the later interval without making it
payable early. `pay_coupon` transfers only `coupon_payable` to the owner's canonical associated
token account. Arrears remain payable across later boundaries.

When a fully withdrawn position opens again with no old coupon obligation, it snapshots current
terms, starts accrual at the new opening time, sets the paid boundary to the current month start
and resets an otherwise unrepresentable sub-base-unit remainder. If an old coupon remains, the
obligation and schedule are preserved.

The coupon pool is shared. The program enforces aggregate solvency and first-successful-payment
ordering; it does not reserve physical tokens for named positions. The bilateral agreement and
operations determine funding and payment priority when the pool is short.

## Principal, liquidity and loss

Principal is accounted per position and globally. A treasury draw names one position and cannot
make its drawn amount exceed that position's principal. Once that position has requested
withdrawal, no new draw may be created; the treasury can only return an existing draw. A return
names the same position. A loss
can be recorded only when the immutable launch policy says principal is at risk, only by the
admin, only with a non-zero evidence hash, and only up to that position's drawn amount. A loss
does not erase a curator's pending withdrawal notice. Notice eligibility does not make drawn
first-loss capital immune from a supported loss: until principal actually exits, the admin may
recognize a loss against the position's outstanding draw. New draws are refused after notice, so
the treasury cannot create that exposure during the exit window.

A withdrawal requires its position's snapshotted lock and notice periods to have elapsed. It
cannot leave the position's outstanding draw above remaining principal and requires enough
physical vault liquidity. A partial withdrawal keeps the notice and continuing eligibility. An
explicit `cancel_withdrawal` gives up the remaining notice. A zero-principal withdrawal clears
the timers. Any top-up extends the lock deadline for the position's entire principal under the
same snapshotted term.

Revocation prevents new deposits. It does not remove existing principal, coupon or withdrawal
rights. Re-allowlisting may keep the same agreement hash while obligations remain; replacing the
hash is refused until principal, coupon and notice obligations are all zero.

Closing an empty position deletes its stored `losses_recorded` and `payout_halted` fields. A later
re-allowlist creates a fresh position with both values zero; lifetime history remains in the
`LossRecorded`, `PayoutHaltChanged` and `PositionClosed` events and must be retained off chain.

The vault does not earmark idle tokens by position. When liquid funds are insufficient, an
otherwise eligible withdrawal waits for a treasury return. Successful withdrawals therefore use
the shared liquid pool in transaction order. The agreement, disclosure and operations must match
that liquidity model.

## Donation and surplus handling

Classic SPL token accounts accept direct transfers. The accounting therefore uses inequalities:

- physical principal plus globally drawn principal is at least recorded principal;
- physical coupon tokens are at least accounted funding less payments; and
- a coupon sweep may remove only tokens above that accounted unpaid funding balance.

Extra tokens are surplus, not curator principal or coupon funding. `sweep_principal_surplus`
recovers only physical principal above `total_principal - drawn`. `sweep_coupons` recovers only
physical coupon tokens above the full accounted funded balance. Credited funding cannot be
withdrawn while any position account exists, including before an untouched position checkpoints
earned coupon. Once every position is closed and `coupon_owed_total` is zero,
`withdraw_unused_coupon_funding` may return up to `coupon_funded - coupon_paid` to the pinned
treasury account and reduces `coupon_funded` by the same amount. A
permissionless coupon payment may recognize only
the amount of donated coupon tokens needed for that payment so `coupon_paid <= coupon_funded`
continues to hold. A physical deficit fails loudly.

## Instructions

| instruction | caller | principal effect |
|---|---|---|
| `initialize` | upgrade authority/admin | Creates versioned config and token PDAs and the initial rate epoch. |
| `set_rate` | admin | Appends a bounded, forward-only rate epoch. |
| `set_terms` | admin | Changes terms for the next zero-principal opening. Existing positions retain their snapshots. |
| `set_authorities` | admin | Rotates three operational authorities and the validated treasury account. |
| `propose_admin`, `accept_admin` | admin, pending admin | Completes two-step administration transfer. |
| `set_paused`, `emergency_pause` | admin, emergency | Sets the deposit/draw pause; only admin can clear it. |
| `allowlist`, `revoke_allowlist` | allowlist | Creates/reenables a position or blocks new deposits. |
| `set_payout_halt`, `emergency_halt` | allowlist, emergency | Sets per-position coupon screening state; only allowlist can clear it. |
| `deposit` | curator | Checkpoints coupon, transfers USDC and extends the snapshotted lock. |
| `request_withdrawal`, `cancel_withdrawal` | curator | Starts or abandons notice. |
| `withdraw` | curator | Checkpoints coupon and pays eligible, liquid, undrawn principal to the owner's ATA. |
| `draw_to_treasury`, `return_principal` | treasury | Moves and attributes deployed principal for one position. |
| `fund_coupons` | treasury | Adds accounted coupon funding. |
| `withdraw_unused_coupon_funding` | treasury | Returns accounted but unused funding only after all positions close and no coupon remains owed. |
| `sweep_coupons`, `sweep_principal_surplus` | treasury | Recovers only unaccounted token surplus to the pinned treasury account. |
| `pay_coupon` | anyone | Pays completed-month coupon to the owner's ATA. |
| `record_loss` | admin | Reduces one position's principal and draw under the at-risk policy. |
| `close_position` | curator | Closes only after principal, draw, coupon and notice obligations are zero. |

Every token destination is either a PDA, the pinned live treasury token account or the owner's
derived associated token account. Draw and sweep paths re-check the treasury account's current
mint and owner rather than relying only on initialization.

Clients and keepers must decode named Anchor errors from the IDL rather than pinning numeric 60xx
codes. Appending or removing a variant can renumber later numeric codes without changing the
program's named refusal contract.

## Program properties

The program and stateful reference tests assert:

1. `vault_balance + drawn >= total_principal`, with equality when no direct donation exists.
2. Global drawn equals the sum of position draws; every position draw is at most its principal.
3. `coupon_paid <= coupon_funded`; physical coupon tokens cover `coupon_funded - coupon_paid`, and
   sweeps cannot remove that accounted unpaid funding. Coupon funding is not required to cover all
   accrued obligations in advance. Accounted funding can decrease only through the terminal
   withdrawal after all positions close.
4. `coupon_payable <= coupon_owed`, and post-boundary coupon cannot be paid early.
5. No withdrawal occurs before the position's snapshotted lock and notice deadline.
6. Accrual is path independent with the carried remainder and rate epochs are strictly forward.
7. Pause never blocks withdrawals, returns or funding, and emergency actions can only restrict.
8. Token transfers, authorities, PDAs, versions and arithmetic fail with named errors on mismatch.

The release test bar is executable and may not be lowered by editing this document:

- the checked surface census must report every one of the 25 instructions, 38 declared errors and
  23 event types represented in the lifecycle suite;
- every event type's complete fields must be decoded from successful `Program data:` logs and
  compared with the committed state transition;
- arithmetic property tests cover split-point path independence, monotonic bounds, civil-date
  round trips and month boundaries;
- 32 independent stateful books execute 96 randomized steps each across three positions, retain
  and assert every transaction result, reach withdrawal eligibility, complete withdrawals and
  check the accounting predicates after each step;
- the committed mutation runner must rebuild eight deliberately defective program variants, prove
  the named regression fails for each, restore every source file and reproduce the pristine host
  artifact hash; and
- the exact canonical ELF and finalized devnet snapshot must pass the selected deployed-evidence
  test; missing keys or evidence are failures rather than skips.

At the latest 20 September 2026 verification checkpoint, the measured local corpus has nine
arithmetic tests and 24 LiteSVM lifecycle tests. The stateful run checks 3,072 steps and reaches
real withdrawals in every independent book. Eight committed program mutations all turn their
directed tests red. CI reruns the tests and census whenever this surface changes.

## Operations and frontend

The monthly operator reads every position, computes due coupon using the same boundary rules,
alerts on a short pool, and calls the permissionless payment path only after screening. Funding,
draws, returns, losses, authority changes and pause clearing remain human/multisig actions.

The frontend must bind its program ID, IDL and mint to the committed deployment manifest. It
shows principal, position draw, coupon owed and coupon payable separately, the agreement hash,
lock and notice terms, pause state and payout halt. It must hide stale post-write figures and may
not report a successful refresh when the mandatory account read failed.

Points remain an off-chain calculation from program events. Any cross-chain reconciliation or
credit into an Ethereum points contract requires a separate reviewed decision.

## Deployment state and release gates

The earlier devnet programs `Bzz7…KNL3` and `HNWZ…sKZL` use retired layouts. Their records are
historical and must not configure a frontend release. The replacement devnet program is
`3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`. Its committed manifest binds the clean source
commit, digest-pinned release builder, committed canonical ELF, IDL hash, deployment and lifecycle
signatures, canonical IDL metadata and a finalized account snapshot. The selected deployed-evidence
test passed against that snapshot and fails on a missing key, wrong program, wrong snapshot or byte
mismatch. This devnet rehearsal is evidence only; it is not a production release approval.

Before mainnet:

- counsel approves agreement wording, at-risk attribution, screening, coupon and exit terms;
- the owner creates and rehearses the production Squads and selects the emergency signer;
- a specialist Solana review covers the final committed source and dependency closure;
- a reproducible/verifiable program build and on-chain verification are recorded;
- canonical Solana USDC and every role/token address are independently checked; and
- the frontend release is built from the matching deployment manifest.

Keys and RPC credentials remain outside the repository. No automation may deploy or upgrade the
Solana mainnet program.
