# ADR-0011 — KYC/compliance gating; broad-access policy at launch

**Status:** Resolved (Forest Road). Policy details are counsel's to set.

## Decision
Mint/redeem of `USDfr` (and vault entry) are whitelist-gated through a compliance module.
The *capability* set includes: allowlist management, transfer restriction on gated
instruments, and jurisdiction blocking. The launch *policy* is broad, KYC-verified access
(not institutions-only). Holding/transfer/trade remain permissionless where legally
cleared, mirroring USD.AI's split.

## Alternatives
- Fully permissionless (untenable regulatory risk for an RWA credit protocol).
- Institutions-only (Forest Road chose broader access).

## Rationale
Compliance hooks are engineering; eligibility policy is legal. Build the rails so counsel
can set policy without redeploying.

## Consequences
- The KYC gate must actually block non-whitelisted mint/redeem in negative QA while
  leaving reads/holding open (CLAUDE.md §2.2).
- The frontend shows a clear "verification required" state rather than a dead button.
- No representation anywhere that gating changes the instruments' securities
  characterization (brief Part 0.5).
