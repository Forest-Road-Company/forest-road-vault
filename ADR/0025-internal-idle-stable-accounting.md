# ADR 0025 — Internal idle-stable accounting, and asymmetric emergency levers

**Status:** Accepted (Forest Road direction, 2026-07-20). Closes finding **M-04** (red-team #12/#14,
PM-R-03). Supersedes the round-1 and round-2 agent patches for M-04, both of which were rejected.
Also closes the fee-on-transfer residual (**R4-XT1 / PM-R-03**) at source.

## Context

`ReserveManager.idleReserve()` computed the cash half of backing by looping the approved-stable list
and calling `balanceOf` on each entry. That number gates **mint, redeem, yield minting, loss burns,
and the redemption queue's liquidity budget** — so any listed token that misbehaved took the whole
protocol down with it. The red-team proved it on live Sepolia: *any address bricks all backing.*

A `try/catch` (R2-M-03) already handled a **reverting** token, and Solidity's `extcodesize` check
handles a **codeless** one. Two live bricks remained, and both were verified in the source:

```solidity
try IERC20(stable).balanceOf(address(this)) returns (uint256 bal) {
    total += _normalize($.stables[stable].decimals, bal);   // <-- inside the try BODY
} catch {}
```

- **Overflow.** `_normalize` multiplies by up to `1e12`. `try/catch` does **not** catch a panic
  raised in the success block — only a failure of the external call itself. A garbage balance
  therefore propagated and bricked the loop.
- **Gas bomb.** EIP-150's 63/64 rule leaves a sliver that cannot finish the loop.

Adjudicated *Low* because listing requires `RESERVE_ADMIN` (the timelock in production), so it is
governance misconfiguration rather than an attacker path. Retained for a hard look anyway.

## Rejected: relaxing the backing invariant

The round-2 agent patch changed `redeem` from the absolute `supply <= backing` to "the absolute
deficit must not widen". **Rejected.** When backing genuinely reads short, that becomes
first-come-first-served: early redeemers exit whole and the loss concentrates on whoever remains.
That **inverts the loss cascade** — losses must run curator first-loss → sGROVE → seniors *pro
rata* (CLAUDE.md §1.3) — and it is a bank run with the invariant nominally satisfied. The absolute
invariant stays exactly as it is.

## Decision

**`idleReserve()` reads storage. It makes no external call.**

1. `ReserveStorage` gains `mapping(address stable => uint256) idleStable`, in **normalized 18-dec
   value**, so the aggregate is pure addition of figures this contract credited itself and can
   never panic on foreign data. Revert, codeless, overflow and gas-bomb are removed as a **class**,
   not mitigated.
2. **`depositStable(stable, from, amount)`** is the only credited inbound path. It credits the
   **measured balance delta**, not the requested amount. This is the one place a stablecoin's code
   runs on the deposit path — and a failure there is contained to that single deposit, never
   reaching `idleReserve()`, redemptions, the queue or the cascade. The governing principle:
   **external reads at the edges where a failure is local; storage reads in the solvency path where
   a failure is systemic.**
3. `releaseStable` and `recordDeployment` check and debit the tally, removing two more external
   reads from hot paths. `removeStable` reports the residual from storage, so the recovery path no
   longer depends on the very call that was broken.
4. `MintRedeemController.mint` deposits through the treasury and mints against the **measured**
   figure, so a lossy token mints less USDfr rather than over-minting against value that never
   arrived — the fee-on-transfer residual, closed at source instead of by policy exclusion.

### Emergency levers — the binding asymmetry

> **Backing may move DOWN on authority. It may move UP only on proof.**

| Lever | Who | Direction |
|---|---|---|
| `reconcileIdleStable(stable)` | **permissionless** | either — sets the tally *equal to the live balance* |
| `writeDownIdleStable(stable, amount)` | guardian, instant | **down only**, no external read |
| `removeStable(stable)` | governance | delists, zeroes the tally, always succeeds |

`reconcileIdleStable` is safe to leave open precisely because it can only make the tally equal what
the chain says. It credits value that arrived outside `depositStable` and writes down a genuine
shortfall. Nobody — governance included — can use it to assert backing that is not there.

**There is deliberately no upward assertion.** An admin able to raise the tally could mint backing
from nothing and thus unbacked USDfr — the same breach as a deployer retaining `MINTER` (C-01) and
as the re-approval double-count (R1-HIGH), through a third door. This matters more than usual
because Forest Road deliberately retains `DEFAULT_ADMIN` through a prod-test window: a hot key plus
an upward override would be a direct unbacked-mint path.

## The trade-off, stated plainly

This **changes the answer to R2-M-03**, and not entirely in the conservative direction.

- **Before:** a broken `balanceOf` made that token contribute zero, so backing *dropped*.
  Conservative about backing — but it froze every redemption (`supply > backing`), and the
  aggregate could still be bricked outright by overflow or a gas bomb.
- **After:** backing holds at the last **proven** figure and the protocol keeps operating.

The cost: **the protocol keeps counting value it can no longer verify.** That is optimistic in
exactly the case where the value may genuinely be gone.

It is deliberate. On-chain, *unreadable* and *gone* are indistinguishable, and freezing every
redemption on an unprovable suspicion is the worse failure — especially since the freeze would
otherwise persist for a 2-day timelock. So the design keeps the protocol live and requires a
**human to adjudicate**, which is what the guardian write-down exists for. `Validate.s.sol` and
monitoring should treat a failing `reconcileIdleStable` as an alert.

**This is flagged for the pre-mainnet audit as a known, accepted trade-off — not a solved problem.**
A reviewer who says "backing is now optimistic in the failure case" is correct, and should be
answered with this section rather than a patch. A staleness bound (à la `reserveMarkMaxAge`) was
considered and rejected: it reintroduces the automatic freeze this ADR exists to remove.

## Consequences

- `ReserveManager_InsufficientIdleStable` is **renamed** to `ReserveManager_InsufficientIdleValue`
  and its arguments are now normalized 18-dec, not raw token units. A rename rather than a silent
  change of meaning, so no off-chain decoder keeps reading the old selector as token units.
- New `Controller_StableNotApproved`, declared on the **interface** so it lands in the shared
  protocol error ABI the frontend decodes against.
- Stables delivered out of band (a direct transfer, or the servicer returning principal) are
  credited by `reconcileIdleStable`. The credit layer's funds precondition stays enforced by the
  existing `Waterfall_BackingWouldBreak` check: if nobody delivered and reconciled, backing reads
  low and `distribute` reverts loudly. This converts a previously *trusted* comment
  ("caller MUST have moved the returning stables … or backing drops") into an enforced property.
- Storage is tail-extended on the erc7201 namespaced struct — layout-safe — but the tally reads
  **zero** on an in-place upgrade of the live Sepolia proxy, which would read backing as zero.
  **`reconcileIdleStable` must be called for every listed stable immediately after any upgrade**, or
  the deployment must be fresh. This is a hard runbook item, not a nice-to-have.

## Verification

- Full suite **527 passed / 0 failed**.
- `invariant_backing_supplyNeverExceedsBacking` and `invariant_idleReserve_independentRecompute`
  (an independent recompute of the backing figure) both pass at 32,768 calls, **zero handler
  reverts** — as do all 11 credit invariants and all 6 token-layer invariants.
- The halmos cascade proof (`CascadeSymbolic`) still passes at 9 paths.
- `test_R2M03_revertingBalanceOf_doesNotBrickIdleReserve` was rewritten to assert the new model
  end to end: a broken token cannot move or brick backing, reconcile is the only thing that fails,
  the guardian write-down is the sole path down, and removal needs no external read.
