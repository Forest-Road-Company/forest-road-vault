# ADR-0013 — Governance: Forest-Road-controlled at launch

**Status:** Resolved (Forest Road).

## Decision
Full `GROVE`/`sGROVE` governance machinery is built and wired — proposals, GROVE-weighted
voting, timelock queue/execute — but at launch Forest Road holds effective control of
parameters and upgrades (via token distribution and role assignment). Progressive
decentralization is a later roadmap item, not a launch commitment.

## Alternatives
- Decentralized from launch (irresponsible for a young protocol carrying real credit).
- No on-chain governance (blocks the decentralization path entirely).

## Rationale
A controlled operator during the protocol's proving period, with the machinery in place so
decentralization is a distribution change, not a redeploy.

## Consequences
- Docs and site state this honestly — no implied decentralization that doesn't exist.
- Parameter changes and upgrades still pass through the public timelock even while Forest
  Road controls them (users always get exit time and on-chain visibility).
