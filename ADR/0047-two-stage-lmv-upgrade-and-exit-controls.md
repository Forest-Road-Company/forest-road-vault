# ADR-0047: Two-stage LMV upgrade governance (`ee9b228a`) and exit-integrity controls

**Status:** Audited candidate deployed (`ee9b228a`, Corrovera delta re-audit `PASS` & 66/66 CI
green on 24 November 2026); Stage 1 proposal `0xd14e...2ce1` live on Ethereum mainnet; Stage 2
pending governance execution (`LMV-09` and `LMV-18` remain **Open** on live proxies until Stage 2
executes).

**Date:** 2026-11-24 (recorded 2026-11-25)

## Context

External Corrovera reviews and continuous fork testing identified edge cases in past-due
impairment interaction with queue exits (`LMV-09`), realized-loss accounting (`LMV-18`),
points-hook gas forwarding under the 16.78M transaction gas cap (`FRV-NEW-01`, `FRV-NEW-06`,
`CORR-DELTA-02`), and `RedemptionQueue` cooldown lookahead (`CORR-DELTA-03`). Because the core
protocol uses timelocked UUPS governance (1-day voting delay, 2-day vote, 2-day Timelock — 5 days
minimum per proposal) and no post-queue veto (ADR-0036), deploying a single monolithic upgrade
without prior monitoring and verification increases operational blast radius.

## Decision

1. **Two-stage governance rollout (Plan B).**
   - **Stage 1 (Preliminary release monitor):** Deploys and activates a non-invasive monitoring and
     readiness layer first via Timelock governance (`proposal 0xd14e...2ce1`).
   - **Stage 2 (Core LMV proxy upgrades):** Installs the audited `ee9b228a` implementations across
     the core protocol proxies after Stage 1 completes and well ahead of the earliest possible
     past-due boundary (21 January 2027 for Renewables).
2. **INV-21 & gas-forwarding invariants.** All dual-hook paths (`SUSDfr.deposit`,
   `RedemptionQueue.closeEpoch`, `CuratorModule` stake-change hooks) enforce conservative EIP-150
   63/64 forwarded-gas bounds via `PointsHookGas` while keeping `onCuratorLoss` unconditionally
   fail-open so loss cascades can never be blocked by an external hook.
3. **Frozen re-audited artifact policy.** Once Corrovera issues a delta re-audit `PASS` on a
   exact commit (`ee9b228a`) with all 38 runtimes verified `exact_match` on Sourcify, pre-existing
   non-blocking Low/Medium items (`CORR-REAUDIT-01`–`03`, `CORR-DELTA-06`–`07`) are deferred to
   the next scheduled upgrade cycle rather than mutating the audited bytecode mid-ceremony.
4. **Honest open-finding posture.** Until Stage 2 executes on chain, `LMV-09` and `LMV-18` remain
   explicitly marked **Open** across every public status and audit surface (and off-chain
   `FRV-NEW-02`, though rolled out and live-verified on 25 November 2026, is retained Open pending
   independent Corrovera confirmation).

## Consequences

- Preserves full audit provenance and Sourcify verification across every deployed runtime.
- Coordinated operational readiness (`queue-keeper` batch limits, `liquidation-bot` `ee9b228a`
  rollout, and 142-contract `activity-keeper` catalog) was completed and live-verified on 25
  November 2026 ahead of Stage 1 and Stage 2 governance execution.
