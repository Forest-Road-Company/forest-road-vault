# ADR 0030 — Clean mainnet-v1 contract surface

**Status:** Locked (Forest Road direction, 2026-07-24).

## Context

The existing Sepolia deployment accumulated upgrade-compatibility fields and testnet
features while the protocol design was still evolving. Mainnet has no legacy balances
or integrations to preserve. Carrying dormant multi-asset, DSRA, reserve-instrument,
manual identity, or recovery-distributor surfaces into a clean launch would add
authority and accounting states without adding launch functionality.

The credit layer also needed stronger binding between signed facts and the value-changing
action that consumes them. A generic “payment/default/loss happened” flag is inadequate
when the payer, destination, amount, schedule, or evidence hash can affect value.

## Decision

### 1. USDC-only reserve custody

`ReserveManager` has one immutable configured six-decimal USDC asset. There is no
stablecoin registry and no approve/list/remove path. `MintRedeemController.mint` accepts
only a USDC amount; `redeem` accepts only a USDfr amount and returns USDC. Conversion is
exact and redemption rounds down to whole USDC units, leaving USDfr dust with the user.

Idle backing is an internal, durable ledger. Direct token donations do not increase it.
Reconciliation is one-way downward and governance may write down verified custody loss.
Funding, fee capitalization, repayment receipt, principal return, and write-off update
the ledger atomically with the corresponding value movement.

### 2. No clean-deployment legacy accounting

Mainnet v1 contains no DSRA funding, balance, target, draw, refund, storage, function, or
event field. It contains no reserve-instrument setter, oracle synchronization, facility
zero convention, or valuation contribution. ADR-0028 remains transition history only.

`RecoveryTopUpDistributor` is not deployed or wired. Its independent source may remain
as optional future tooling under ADR-0029, but no launch address or promise exists.

### 3. Facility-complete signed terms and exact facts

Every facility carries its own signed `interestRateBps`, funding recipient, rate type,
day-count convention, payment cadence and next due date, maturity, renewable flag,
schedule hash, rate-index reference, renewal terms hash, and legal reference.
Class-level interest and DSRA parameters do not exist.

`CreditIssued` commits to the full origination terms. `TermsAmended` commits to the full
amendment. Funding can pay only the signed recipient. `PaymentReceived` commits to the
payment id, facility, USDC asset, payer, exact cash amount, interest, principal, and next
due date. `DefaultDeclared`, `LossRealized`, and `PastDueCured` commit to the exact facility,
evidence hash, and, where applicable, loss amount. Each consumed high-value fact is
single-use.

Only the nine launch kinds remain: AssignmentExecuted, UCCFiled, CreditIssued,
PaymentReceived, DefaultDeclared, Valuation, LossRealized, PastDueCured, and
TermsAmended.

### 4. Lifecycle and valuation safety

Scheduled past due is derived from `nextPaymentDue + graceWindow`. A full repayment or
full write-off reaches a terminal state; no zero-outstanding default can remain stranded.
All marked-to-market margin calls, cures, and liquidations require a fresh attested mark.
Revocation never lowers the valuation high-watermark.
Once configured, a collateral class cannot change between Receivable and
MarkedToMarket. Governance may update same-model risk parameters, but it cannot make
live facilities cross into a different valuation and remedy system.

`AssessedImpairmentSource` is part of the main deployment and can only provide a
time-limited, revision-bound professional recovery assessment under ADR-0027.

### 5. Emergency-pause behavior

New queue requests and settlement may be paused, but a user may always claim assets
already settled to their request. USDfr pause blocks user minting and user transfers,
while protocol-exempt module-to-module transfers and burns remain live so the
never-pausable loss cascade cannot be disabled by the token pause.

### 6. Minimal points/compliance surface

Points are per wallet. Deprecated compliance identity storage and the unused
`transferRestricted` flag are removed. Legacy points migration and one-argument
curator-loss hooks are removed. `BURNER_ROLE` is removed; the controller's tightly scoped
minting role already authorizes protocol burns.

### 7. Vault seed

The permanent anti-inflation seed is $10, not $1,000. It is deposited to the irreversible
dead sink and that sink is protocol-exempt, so it earns no points. The ERC-4626
six-decimal virtual-share offset remains the primary inflation defense. The seed is
small enough that inaccessible shares do not materially capture live users' yield.

## Consequences

- This is a breaking clean deployment, not a storage-compatible upgrade of the current
  Sepolia proxies. The current Sepolia addresses and frontend ABI must not be mixed with
  this source.
- The candidate must be deployed fresh on a fork, then fresh on Sepolia, with one manifest
  and frontend configuration updated atomically.
- Production validation must pin canonical Ethereum USDC, the exact nine attestation
  kinds, all five active collateral classes, the assessment wrapper, the $10 excluded
  seed, role topology, and the absence of deferred/legacy modules.
- Adding another reserve asset, reserve instrument, recovery distributor, attestation
  kind, or compatibility path requires a new decision and audit.

## Verification

The candidate has been executed on a pinned Ethereum-mainnet fork against canonical USDC:
180/180 fork lifecycle, governance, compliance, oracle, points, queue, marked-to-market,
deployment/handover, and loss-cascade tests pass. That total includes 4/4 exact clean
deployment, $10 seed, handover, treasury-delegation, strict-validation, manifest, and
broadcast-guard tests. The complete non-fork suite passes with 855 tests and no failures;
the production frontend passes lint, 321/321 contract↔UI checks, logic/security checks,
TypeScript compilation, Sepolia production build, strict mainnet-mode production build,
and `npm audit --omit=dev` with zero vulnerabilities. The final heavy profile passes all
839 tests, with stateful invariants at 512 runs × 256 calls and fuzz tests at 10,000 runs.
Combined source-only Foundry coverage is 100.00% functions (442/442), 100.00% lines
(2,430/2,430), and 99.24% branches (390/393). The only missed deployed-source branches
are two defensive states made unreachable by bounded setters/configuration; the third is
an exact-token-receipt guard in the expressly undeployed RecoveryTopUpDistributor. Slither's 90 raw
results (3 High, 15 Medium, 45 Low, 27 Informational) have been manually triaged without
a new confirmed exploit. Every deployable runtime is below EIP-170. The clean stack was
then freshly deployed and exercised on Sepolia at block 11,340,997. External audits,
production principals/multisigs, economic/legal approval, monitoring, explorer
verification, and live frontend acceptance remain release gates rather than assumptions.

## Mainnet packaging addendum (2026-07-24)

The repository now has a separate fail-closed Ethereum entrypoint
(`script/DeployMainnet.s.sol`), compiled production parameters
(`script/MainnetConfig.sol`), and a strict production validator
(`script/ValidateMainnet.s.sol`). The testnet deployer still rejects chain id 1. The
mainnet entrypoint rejects non-canonical USDC, retained admin authority, a codeless
operations controller, a codeless curator controller, overlapping deployer/value-sink
addresses, and non-independent attester addresses. It cannot overwrite a mainnet
manifest and requires both the exact full deployment authorization hash and an explicit
broadcast phrase for a real broadcast. That authorization binds the actual derived
`DeployMainnet` runtime, the complete artifact set, all principals, canonical USDC, the
deployer, and its nonce; the configuration-only hash is not sufficient.

The exact clean deployment, handover, treasury delegation, production concentration
tuple, and strict validation now execute on a chain-id-1 fork against canonical Ethereum
USDC at pinned block 25,500,000 in `test/fork/MainnetDeploymentFork.t.sol`, including the
literal external `DeployMainnet.run()` entrypoint and strict independent receipt
validation. The frontend is build-time chain-pinned: a mainnet build has no Sepolia
address fallback, requires every deployed module, deployment block, approved deployment
receipt and manifest checksum, rejects zero/duplicate addresses, pins canonical USDC,
removes the faucet, and uses mainnet explorer, legal, and network copy.

This packaging does not satisfy the independent-audit, counsel, economic, key-generation,
multisig-review, monitoring, explorer-verification, or live acceptance gates. Their
controlling sequence is `docs/MAINNET_LAUNCH_RUNBOOK.md`; any incomplete gate is a no-go.
