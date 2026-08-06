# Forest Road Vault

A real-world-credit protocol on Ethereum L1. It takes USDC, issues a fully-backed synthetic dollar
(`USDfr`) against it, lends that capital into identified, lien-perfected off-chain credit facilities,
and passes the interest through to a yield-bearing ERC-4626 vault (`sUSDfr`) — with a three-layer
loss cascade underneath.

Off-chain facts enter only through an m-of-n attested oracle. The protocol integrates no AMM, no
price feed and no external DeFi protocol; USDC is the only external token.

> **This public review repository contains the production contract source, the runnable public
> test suite, architecture decisions, security documentation and application.** Live mainnet
> deployment topology, custody material, operational manifests and private keeper/feed tooling are
> deliberately excluded. See *What is in this repository* and *What is deliberately withheld*.

---

## Status — read this before anything else

**This protocol is not in production.**

| | |
|---|---|
| Deployed | Ethereum **Sepolia** plus a restricted disposable Ethereum-mainnet test ceremony. Neither is production. |
| Mainnet | **Controlled test only.** No third-party capital, real facility, legal claim, public yield representation or production frontend is authorized. Production activation remains separately gated. |
| External security audit | **SATISFIED.** Corrovera Security's independent AI-assisted review was received and owner-dispositioned on 4 August 2026. |
| Open findings | Several; their mechanisms, impacts and dispositions are published. Runnable proofs for live unremediated mechanisms are withheld — see below. |

The current testnet deployment retains bootstrap admin privileges, uses a mock stablecoin, and runs
with concentration limits fully open. **Nothing green on that deployment is evidence about a
production configuration.**

Token characterization is a matter for counsel. Nothing in this repository is a securities-law
representation, and nothing here should be read as representing the instruments as non-securities.

## Security posture

Every finding and disposition is published, including what is still open and what was accepted
rather than fixed. Selected live reproduction material is withheld under the policy below:

- **Audit register** (`/docs/audit` on the project site) — every review round, each with its
  own findings, severities and remediation history. Fifteen published rounds, most recent
  numbered Round 16.
- **Protocol guarantees** (`/docs/guarantees`) — the invariant
  specification, mapped to the on-chain mechanism enforcing each property and the test suite
  proving it.
- **Security & testing** (`/docs/security`) — assurance posture and the
  current status of each production gate.

The engineering rounds are internal and do not substitute for external review. The Audit Register
publishes Corrovera Security's independent AI-assisted review scope, method, findings, limitations
and Forest Road's dispositions; the raw vendor report remains private under the reproduction policy
below. Forest Road accepted its two Medium findings with recorded conditions and revisit triggers.
That review satisfies Forest Road's one-external-audit launch requirement. Its stated scope and
methodological limits remain part of the evidence and are not upgraded by that policy decision.

### Reproduction proofs

Reproduction status is stated per finding and must not be inferred merely from inclusion in the
register. Corrovera explicitly did not generate fork reproductions, and neither of its two findings
reached its `confirmed` evidence tier. The public test suite includes the other proofs that compile
without the deliberately withheld live-mainnet ceremony files. Tests that import those files, and
raw reproduction material for live accepted mechanisms, remain in the private evidence archive and
are available to an engaged auditor through an appropriate disclosure channel.

For findings that are **open and exploitable against a live deployment**, the register states the
mechanism, the impact and the fix, but withholds the reproduction recipe until remediation. That is
ordinary responsible-disclosure practice, and it is a deliberate exception to our policy of
publishing in full. The independent Corrovera review is summarised in full on the Audit Register —
its scope, its stated methodological limits, both Medium findings and Forest Road's dispositions —
while the raw report is withheld, because its finding sections are working reproduction recipes for
mechanisms that are accepted but not remediated.

One published finding names a proof that is withheld for a different reason, and we would rather
say so than let the register imply otherwise. **FRV-DSA-001** (High, Remediated — "Mainnet
deployment authorization approved parameters without binding principals or artifacts") records that
the remediation is "proven by a pinned mainnet-fork test". The relevant tests import the withheld
mainnet deployment scripts. A reader of this public repository therefore cannot run that proof or
read the ceremony script it exercises, and should treat that disposition as asserted here unless
Forest Road supplies the private evidence archive directly.

Reviewers, auditors and integrators can request the full evidence archive.

### Reporting a vulnerability

Please report privately rather than opening a public issue: **jevans@forestroad.com**.

Include enough detail to reproduce — the affected contract and function, the conditions required,
and the impact you believe it has. If you have a proof-of-concept test, send it; if you would rather
establish a channel before sending details, say so and we will.

We will acknowledge receipt, tell you plainly whether we consider it a finding and at what severity,
and agree a disclosure timing with you. Findings that survive validation are published on the audit
register with their severity and disposition — including those we accept rather than fix — and
reproduction detail is withheld until the mechanism is remediated. Reporters are credited unless
they ask not to be.

There is no bug bounty at this stage. Nothing here waives any right, but we have no interest in
pursuing good-faith research: test against your own deployment or a local fork rather than any
deployed Forest Road address, do not access or modify data that is not yours, and do not degrade
the service for others.

## What is in this repository

```
contracts/src        production Solidity contracts
contracts/test       public unit, integration, invariant, symbolic, audit and fork tests
contracts/script     generic test/development deployment, validation and QA scripts
ADR                  architecture decision records
docs                 threat model, access-control matrix, invariants and review guidance
frontend             Next.js application and published audit register
```

The public snapshot is derived from frozen source commit
`fa28d0ecccd4b99176da0bc6b4d2fbac88849246`. Public dependency submodules are pinned to the exact
commits used by that source.

### What is deliberately withheld

This is a curated snapshot of a private working repository, not a mirror. The exclusions below
protect operational controls and live reproduction material; they are not claims that review of
the published surface alone is sufficient to approve production.

| Withheld | Why |
|---|---|
| The mainnet deployment, validation and handover scripts | `DeployMainnet`, `ValidateMainnet`, `MainnetConfig`, `MainnetConfigReceipt` and `Handover`. They publish the mainnet role topology and the handover sequence. To be revisited after launch. The generic `Deploy`, `Validate`, `QA`, `UpgradeOracle` and `PrivilegeAudit` scripts **are** published — they take every address from configuration, and the test suite does not compile without them. |
| Five test files that import those scripts | `MainnetDeploymentFork`, `DeployValidateHandoverFork`, `Fix_C01-deploy-tooling`, `DeepSecurityDeploymentAuthorization` and `Fix_A01-timelock-impl-initialiser`. They cannot compile without the withheld scripts, and one unresolved import stops the entire public suite compiling. See *Reproduction proofs*. |
| The mainnet control-Safe fork test | `MainnetControlSafesFork` pins the exact pre-launch control-wallet topology. It is withheld with the operational address records and will be revisited after launch. |
| Two live-finding characterization proofs | The `R14_01-FeeShareMintBasis` file and the accepted global-HWM round-trip case in `FeeStackFlow` are executable proofs of unremediated accepted mechanisms. The audit register publishes their mechanisms, impacts, dispositions and revisit conditions; the runnable proofs remain in the private evidence archive. The rest of `FeeStackFlow` remains public. |
| The off-chain keeper and private bundle feed | Operational infrastructure carrying private-relay, encrypted-bundle delivery and credential-boundary detail. Not required to review the on-chain protocol. |
| Deployment manifests and reports | Operational records. Live addresses are published on the project site instead, where they can be reconciled against on-chain state. |
| The launch runbook | Operational and incident procedure. Publishing it carries no benefit to a reader and real downside. |
| Raw audit reports and evidence | They carry reproduction detail for findings that are still live. See *Reproduction proofs* below. |
| Internal working state and process notes | No evaluative value; discloses operational infrastructure. |

Credentials and ceremony records have never been committed to any repository.

## Building and testing

```bash
git submodule update --init --recursive
cd contracts
forge build
forge test --offline

cd ../frontend
npm ci
npm test
NEXT_PUBLIC_CHAIN_ID=11155111 npm run build
```

The build refuses to select a network implicitly — `NEXT_PUBLIC_CHAIN_ID` is required. Copy
`frontend/.env.example` for the full variable list; it contains placeholders only. Every
`NEXT_PUBLIC_*` value is compiled into the browser bundle and is public by construction, so nothing
secret belongs there. Set the optional
`NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` to a dedicated Reown project ID to enable WalletConnect QR
and mobile deep-link sessions. That ID is intentionally browser-visible, is not a signing secret,
and must be protected with Reown's production/preview origin allowlist.

## Design decisions

The locked decisions are identified-per-asset collateral rather than a blind pool; variable-yield
pass-through rather than a fixed rate; Ethereum L1; four credit verticals plus a marked-to-market
digital-assets class at launch; and the three-layer loss cascade.

The protocol overview and invariant specification are published under
`frontend/src/content/docs/` and rendered on the project site. The complete public architecture
decision set is in `ADR/`.

## License

[Business Source License 1.1](LICENSE). Non-production use is permitted; production use is subject
to the Additional Use Grant. The license converts to Apache 2.0 on the Change Date.

Copyright in the Licensed Work is held by Road Runner Capital, LLC, a Forest Road entity.
