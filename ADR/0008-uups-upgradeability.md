# ADR-0008 — Upgradeability: UUPS proxies + timelock + guardian

**Status:** Resolved.

## Decision
UUPS proxies (OpenZeppelin `UUPSUpgradeable`) for stateful protocol modules.
`_authorizeUpgrade` is gated to an `UPGRADER_ROLE` held only by the governance timelock
(Forest-Road-controlled initially, ADR-0013). A `Guardian` role can pause value-moving
paths in emergencies but cannot upgrade.

## Alternatives
- Transparent proxies (heavier, admin/storage split adds surface).
- Immutable contracts (no fix path for a young protocol custodying credit).
- Diamond (over-complex for this scope).

## Rationale
Lean current standard with audited OZ support; the timelock gives users exit time before
any upgrade takes effect; pause and upgrade powers deliberately separated.

## Consequences
- Upgradeable-safe patterns throughout: namespaced (ERC-7201) storage, `initializer` /
  `reinitializer` discipline, no constructors for state, storage-layout checks in CI.
- **Storage-layout check (added for audit finding C-01, which found this bullet asserted a
  gate that did not exist).** `tools/check-storage-layout.mjs` compares every namespaced and
  array-element struct against the committed `contracts/storage-layout.json` and runs in CI.
  Note that `forge inspect <contract> storage-layout` is **inert** here: these contracts hold
  no top-level state, so it reports an empty layout. The check therefore compares the field
  ORDER and TYPES of each storage struct. A namespaced root may be tail-extended; an
  ARRAY-ELEMENT struct may not change at all, because elements are contiguous and any growth
  shifts every later element on a live proxy. Inserts, reorders, retypes and deletions fail
  for both. Regenerate the baseline only when the change is deliberate and every affected
  proxy is being redeployed fresh.
- Post-deploy validation asserts proxy → implementation wiring and that no deployer
  privileges remain (CLAUDE.md §2.1).
- Negative QA must prove an upgrade without the timelock reverts (CLAUDE.md §2.2).
