# ADR-0004 — Anchor curator + pluggable curators; $10M/class first-loss

**Status:** Resolved (Forest Road).

## Decision
Forest Road is the privileged anchor curator, posting first-loss capital per class —
default **$10,000,000 per class** (≈$50M across the five classes at full deployment;
amended from four when ADR-0015 added the digital-assets class), configurable by
governance. `CuratorModule` supports onboarding additional third-party
curators per class later. First-loss capital is strictly subordinate to `sUSDfr` in the
waterfall; curators earn only when their book performs.

## Alternatives
- Open curator market from launch (weaker trust story, unproven originators).
- Single hardcoded curator (no optionality).

## Rationale
Forest Road already originates, underwrites, and services in-house — vertical integration
is the structural advantage over USD.AI's external-curator model. Pluggability preserves
the roadmap.

## Consequences
- Subordination headroom per class is computed against posted first-loss and exposed for
  the dashboard.
- First-loss withdrawal is constrained by headroom rules (cannot pull junior capital out
  from under an active book).
- **Owner decision 2026-07-22 (audit M-19):** the `$10M/class` first-loss is a **disclosed
  target, not an enforced funding precondition** — a facility may be funded while its class
  pool is below target, and the mitigation is the on-chain subordination-headroom disclosure
  above, not a hard gate at `fund`. See `audit-reports/OWNER_DECISIONS_2026-07-22.md` #8.
- Loss absorption order per ADR-0014.
