# Security Policy

## Reporting a vulnerability

Email **jevans@forestroad.com**. Please do not open a public issue for anything that affects the
safety of deployed contracts or user funds.

Include the affected contract and function, the conditions required to reach it, and the impact you
believe it has. A proof-of-concept test is the most useful thing you can send. If you would rather
establish a channel before sending details, say so and we will.

## What happens next

We will acknowledge receipt, tell you plainly whether we consider it a finding and at what severity,
and agree disclosure timing with you.

Findings that survive validation are published on the
[audit register](https://github.com/jevansfr/forest-road-vault) with their severity and
disposition — **including the ones we accept rather than fix**. Reproduction detail is withheld
while a mechanism is live and unremediated, which is a deliberate exception to publishing in full.
Reporters are credited unless they ask not to be.

There is no bug bounty at this stage.

## Scope

| | |
|---|---|
| In scope | `contracts/src` — the production contract set, at the commit published here. |
| In scope | `frontend/` where a defect would mislead a user about on-chain state or cause a harmful transaction. |
| Test deployment only | A restricted disposable Ethereum-mainnet test ceremony and the Sepolia deployment are not production and accept no third-party capital. |
| Not in this repository | Live-mainnet deployment, validation and handover scripts; custody material; the off-chain keeper/private feed; manifests; and operational tooling are withheld. Generic test/development scripts are included. If you believe you found something in a component you cannot see, please still report it. |

The Sepolia deployment retains bootstrap admin privileges, uses a mock stablecoin, and runs with
concentration limits fully open. Findings that depend only on that configuration are expected and
are not vulnerabilities — but if you are unsure whether something is configuration or a defect,
report it and let us make that call rather than discarding it.

## Good-faith research

We have no interest in pursuing good-faith research, and nothing in this policy waives any right.
Please test against your own deployment or a local fork rather than any deployed Forest Road
address, do not access or modify data that is not yours, and do not degrade the service for other
users.

## Known and published

Before reporting, it is worth checking the audit register: the protocol's open and accepted findings
are already published there with their mechanisms and severities. Several live mechanisms are
knowingly accepted rather than fixed, each with the conditions that make it tolerable and the
triggers that would force a revisit. Independent confirmation of a published finding is still
welcome — particularly evidence that one is reachable in a way we have not recorded, or has greater
impact than we assessed.
