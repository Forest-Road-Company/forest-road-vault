# Security & Testing

> The application identifies its active network and deployment receipt at build time.
> Production promotion is authorized only after the gates below are cleared. Token
> characterization is a matter for counsel; nothing here is a securities-law
> representation.

Forest Road Vault custodies capital against real legal claims, so correctness and test
rigor are treated as the deliverable, not an afterthought. This page summarizes the
posture; the full invariant specification and role model are published alongside it.

## Testing

- **Foundry** covers the contract set with targeted branch/revert tests, realistic
  end-to-end flows, stateful invariants, and fuzz campaigns.
- ADR-0031 changed the exact source after the July 27–28 internal audit snapshot.
  Those historical 855-test / 442-function / 2,427-line figures are superseded and
  are not presented as current assurance. Four successive external fee-accounting
  reviews then found and re-checked the impaired-flow, dual-NAV, and exit-carry
  defects. The latest found no High issue and no safety-invariant break. Forest Road
  accepted the remaining protocol-revenue-only global-HWM tradeoff; the follow-up
  zero-vesting and hardening delta still awaits exact-source independent review. Its
  local, fork, coverage, static-analysis, and symbolic evidence is recorded in
  `CURRENT_VERIFICATION.md`.
- A **differential model** cross-checks the attestation oracle, and reward accounting is
  reconciled against independent ghost accounting.
- **Halmos** checks five backing-transition properties (68 paths) and the cascade
  arithmetic property (9 paths). The published formal-methods note states the model and
  token trust boundaries; this is not a whole-protocol formal-verification claim.
- **Mainnet-fork tests** exercise the USDC-only launch surface against canonical Ethereum
  USDC at a pinned block, including the complete lifecycle, governance, compliance,
  oracle, points, queue, marked-to-market, deployment/handover, and loss-cascade paths.

## The safety spec

Nine system invariants are encoded as stateful properties and exercised across fuzzed
reachable states: the backing invariant (supply never exceeds backing), value
conservation in the waterfall, strict loss-cascade ordering, the synchronized mint gate,
FIFO redemption with no double-claim, concentration limits, exchange-rate monotonicity,
access control, and reserve reconciliation. See **Protocol guarantees** for the full list
and how each is enforced on-chain.

## Review

- A historical internal, multi-round **adversarial audit** was run against its then-current contract set.
  Independent reviewers rotated attack lenses each round (arithmetic, economic/MEV,
  upgrade & storage, external-token integration, access control), plus static analysis
  (Slither). No Critical finding was confirmed. Every High finding and its disposition is
  published: deployment authorization was remediated with regression tests; the remaining
  curator-capital settlement risk is explicitly accepted/deferred rather than described
  as fixed.
- All contracts use **audited, standard implementations** (OpenZeppelin) for tokens,
  ERC-4626, ERC-721, access control, proxies, reentrancy guards, and pausing. Nothing
  security-sensitive is hand-rolled. Checks-Effects-Interactions and reentrancy guards are
  used throughout the value-moving paths.

- **Two subsequent five-pass source-level audits** were then run across the production
  contracts and their deployment wiring, surfacing eighteen further findings at module
  boundaries the earlier tests had treated as trusted: backing/valuation and facility
  lifecycle in Round 1, and compliance, the vault, the redemption queue and the treasury in
  Round 2. We publish all of them, with per-finding remediation status, in the
  **Audit Register**, where every round keeps its own findings and its own remediation
  history. ADR-0030 subsequently removed the legacy multi-stable, DSRA,
  reserve-instrument, recovery-top-up deployment, and compatibility surfaces. The fresh
  clean-v1 stack formerly deployed at Sepolia block 11340997 is now explicitly archived
  because ADR-0031 and later liveness remediation changed the source. The current
  `7eef49b` suite was deployed across blocks 11386373–11386520, explorer-verified, and
  exercised through all 661 callable ABI entries on a finalized fork. That deployment
  evidence does not close the outstanding independent source-delta review.
  No historical completion label or hash applies to the current source. This is exactly
  why an internal review is not a substitute for an external one.

An internal review is **not** a substitute for an independent external audit.

## Production assurance gates (human-owned)

The internal engineering review does not itself authorize production. A first mainnet
promotion requires an **external security audit**, a **securities-law opinion**, an
**executed legal wrapper**, an **economic review**, and **acceptance of the
attestation-trust model**.

Current status of those gates:

- **Corrovera independent review: RECEIVED AND OWNER-DISPOSITIONED 4 AUGUST 2026.** Corrovera Security
  reviewed the whole protocol, all 37 files and 10,502 lines of contract source, at a
  commit byte-identical to the current `contracts/src` tree at `b5245398`, with our existing 36-entry findings
  register supplied as an exclusion list so that a rediscovery could not be reported as a
  discovery. It is the first review of this protocol by a party other than Forest Road, and
  it is published in full on the Audit Register. **Its limits belong with its findings, so
  we state them here rather than only in the report:** the engagement was Corrovera's
  AI-assisted tier; **no finding in it reached `confirmed`**, because fork reproduction was
  not part of the engagement; no property was formally proven; no fuzzing ran beyond our own
  suite; and adjudication was by one engineer rather than a consensus pipeline. The report's
  own words are that a clean section *"is not evidence of security."* It was not clean. It
  produced two new Medium findings outside the register: F-01, a curator being able to
  inflate the price its own queued redemption settles at, and F-02, ordinary forbearance
  suppressing the senior impairment mark with no misconduct required. **Forest Road analysed
  both and accepted them as low practical risk on 4 August 2026. Accepted is not fixed:**
  neither mechanism is refuted, neither is remediated in code, and Corrovera's Medium
  ratings stand as they wrote them. F-01 is near-unreachable only while Forest Road is the
  sole curator, and goes live at the first approval of a third-party curator, so that
  approval is itself gated on remediating it first. Forest Road confirmed that one external audit
  is the applicable launch requirement, so the received Corrovera engagement satisfies that gate.
  This policy disposition does not change the report's scope, AI-assisted method, Medium ratings or
  stated limitations. A reader who wants a stricter bar than this evidence supports should say so;
  the material to judge it is on the register.
- **Prior internal rounds, for context.** Four independent
  ADR-0031 review rounds are complete; the latest confirmed the holder-protective
  exit/backstop fixes and reported no High issue. It preceded the current
  zero-vesting, legacy-seed, upgrade-order, liveness, deployment-receipt, UI, and CI
  follow-up. An internal adversarial audit of the whole
  protocol (Round 16, 2 August 2026) reviewed the current source directly and reported
  several live findings. Forest Road formally accepted two corrected residual risks on
  3 August 2026: D7-01 at Medium and D4-01 at Low. Neither mechanism is resolved or
  refuted, but neither is a release blocker after acceptance. D7-01's loss-avoidance
  channel is closed by the existing atomic-private default procedure; its surviving risk
  is a throughput-cap bypass. D4-01's anonymous path is a bounded, non-compounding
  one-epoch delay. The round's four Low assurance-chain findings
  (D13-01 through D13-04) were subsequently remediated with tracked regressions, but the
  open protocol findings remain, so the delta this gate refers to has grown rather than
  closed. That round
  also corrected four of its own earlier conclusions, including one previously published
  here: the upgrade role is held only by the timelock **in the current configuration**, but
  the default administrator role administers it, so that is a configuration state and not a
  control. It remains an internal review and does not move this gate.
- **Securities-law opinion: OWNER-REPORTED COMPLETE.** The repository does not
  independently attest the underlying letter. Nothing on this site is a
  securities-law representation.
- **Executed legal wrapper: OWNER-REPORTED COMPLETE.**
- **Economic review: OWNER-REPORTED COMPLETE.**
- **Attestation-trust model acceptance: OWNER-REPORTED COMPLETE.**
- **Mainnet operator ceremony: BLOCKED.** Tracked default/heavy tests and Solidity formatting
  pass, and the pinned-fork recovery rehearsal now exercises the real Treasury Safe proxy. The
  Safe shared-owner common mode is formally accepted as `SAFE-CD-01` and remains disclosed rather
  than described as independent control. The validated KMS deployer is now funded with ETH and
  canonical USDC. Forest Road approved its four gas-policy values, and the strict read-only
  renewed-session preflight passed at mainnet block 25,681,334 without a signing request; it must be repeated after
  source freeze and immediately before the ceremony. The roleless atomic MTM executor and private
  keeper worker now exist. A follow-up internal audit fixed four additional Medium findings and the
  Low `KPA-L1` repository limitation. Round 17 then found two Low items: Forest Road accepted the
  live, PROVEN `MTM-01` risk on 4 August 2026 without claiming a fix or refutation, and
  `MTM-02` is fixed by local digest/quorum/action validation, event-based peer recovery and a required fixed gas limit, so neither read RPC
  receives a pre-inclusion digest commitment, unsigned valuation or signed bearer bundle. The hardened unit suite passes 52/52, the executor suite passes
  12/12, and the complete compiled-worker lifecycle passes on a disposable fork pinned to mainnet
  block 25,500,000, including near-cap repeated-ID multi-bundle scheduling, both code-bearing and
  no-code bad-queue rejection, fail-closed expired-entry eviction, no-action rejection with zero
  relay calls, `rpc-commitment-leak=0`, `rpc-valuation-leak=0` and `rpc-bearer-leak=0`. The
  local relay and guardian adapters prove worker behavior, not a production provider or actual
  Safe. The executor remains undeployed but is within Corrovera's reviewed `contracts/src`; the
  one-external-audit requirement is satisfied. The selected bounded-batch feed now has a repository
  implementation and local load/recovery harness, but still lacks its exact selected-host
  PostgreSQL production receipt; and two independently controlled
  funded hosts, selected confidential-relay confidentiality/revert-suppression and independent-heartbeat evidence and the actual
  human Guardian-Safe drill are absent. The feed test can use synthetic bundles and a disposable
  fork; the Safe drill requires real owners but may use the tightly capped pre-audit test deployment,
  so neither item requires a public production launch. Human
  recovery timing and capital-policy records also remain open. A local test cannot mark those
  controls complete.

Once launched, those controls and the documented monitoring,
incident-response, and governance processes remain ongoing obligations.

## Reporting a vulnerability

Email **jevans@forestroad.com**. Please report privately rather than opening a public issue for
anything affecting the safety of deployed contracts or user funds.

Include the affected contract and function, the conditions required to reach it, and the impact you
believe it has; a proof-of-concept test is the most useful thing you can send. We will acknowledge
receipt, say plainly whether we consider it a finding and at what severity, and agree disclosure
timing with you.

Findings that survive validation are published on the audit register with their severity and
disposition, **including the ones accepted rather than fixed**. Reproduction detail is withheld
while a mechanism is live and unremediated, which is a deliberate exception to publishing in full.
Reporters are credited unless they ask not to be. There is no bug bounty at this stage.

The Sepolia deployment retains bootstrap admin privileges, uses a mock stablecoin, and runs with
concentration limits fully open, so findings that depend only on that configuration are expected.
If you are unsure whether something is configuration or a defect, report it and let us make that
call rather than discarding it.

We have no interest in pursuing good-faith research, and nothing here waives any right. Please test
against your own deployment or a local fork rather than the live testnet, do not access or modify
data that is not yours, and do not degrade the service for others.
