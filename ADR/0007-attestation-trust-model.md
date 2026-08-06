# ADR-0007 — Attestation trust model: authorized attesters, EIP-712, optional m-of-n

**Status:** Resolved — buildable, no gate. Forest Road's *conscious acceptance* of the
trust assumption is a pre-mainnet ownership item (brief Part 11 gate 6), not a build gate.

## Decision
Off-chain legal facts cannot be trustlessly proven, so `AttestationOracle` uses an
**authorized-attester model**:

- **Attester set:** role-gated allowlist (`ATTESTER_ROLE`), initially Forest Road
  operational keys plus designated third-party servicers/verifiers per class. Managed via
  AccessControl behind the timelock; every change emits an event.
- **Signature scheme:** EIP-712 typed-data signatures over
  `(kind, tokenId, payloadHash, nonce, expiry)`, verified on-chain in `attest`. Nonces
  prevent replay; expiries bound staleness.
- **Threshold:** per-kind configurable m-of-n. High-value kinds (`CreditIssued`,
  `Valuation`, `DefaultDeclared`) should require ≥2 attesters; routine kinds may be 1.
- **Kinds:** `AssignmentExecuted`, `UCCFiled`, `CreditIssued`, `AuditCleared`,
  `MilestoneHit`, `PaymentReceived`, `DefaultDeclared`, `Valuation`.

## Trust boundary (state prominently everywhere)
The protocol executes faithfully on whatever authorized attesters assert. If an
attestation is false or an attester key is compromised, the protocol acts on false
information. This is the protocol's primary trust assumption. It appears in NatSpec, the
GitBook risk section, and the site's risk page.

## Reduced-trust roadmap
Single-attester → threshold multi-attester → independent verifier/oracle diversification →
cryptographic proofs where feasible (e.g., proof of a filed UCC record).

## Alternatives
Single oracle key (weaker); fully trustless (infeasible for off-chain legal facts).
