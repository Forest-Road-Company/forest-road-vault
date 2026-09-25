# Security and Testing

Forest Road Vault V2 is live on Ethereum mainnet. Its permanent proxy entry points were deployed
at block 26,006,832 from the manifest identified on the
[deployed-addresses page](/docs/addresses). Bootstrap authority has been removed from the deployer;
administration and upgrades are held by timelocked governance.

Security reviews and tests reduce risk. They do not prove that the contracts, governance,
custodians, keepers, signers or real-world loan facts cannot fail. Each review on the
[audit register](/docs/audit) states its own source baseline and scope because a clean result
outside that boundary is not evidence about the rest of the system.

## Current release evidence

The deployment qualification and the later deployed-contract review resolved the live proxies,
implementations, linked libraries, roles, negative roles, module wiring, fee settings, risk
parameters and continuous-accrual bindings against the production manifest. Etherscan recorded
source verification for all 60 deployment inventory addresses and implementation association for
all 18 proxies. On-chain code hashes and ERC-1967 implementation slots are the authoritative
identity checks.

The exact deployed source tree completed:

- a clean production build with Solidity 0.8.30, optimizer runs 100, Cancun and no IR;
- 3,108 non-fork release checks, comprising 3,105 passing tests and three separately executed
  endpoint checks;
- 208 heavy invariant tests at 512 runs and depth 256;
- eight Halmos symbolic properties;
- executable reachability for 1,074 of 1,074 deployed-scope functions;
- 99.40% line and 94.95% branch coverage over `contracts/src`; and
- a later clean mainnet-fork population of 69 suites and 537 passing tests with zero failures or
  skips.

The deployed-address scenarios cover cash and PIK origination, continuous accrual, scheduled PIK
capitalization, both fee layers, repayment, delinquency and cure, assessed impairment, the
curator-to-sGROVE-to-senior loss order, recovery, queue FIFO and settlement, direct redemption,
sGROVE rewards and unbonding, voting and timelock execution, custody controls, signature quorum and
replay, stale accrual, donations, late entry, pausing, and split sub-par exits.

The important new tests were checked with deliberate incorrect changes. The review asserted that
each change actually applied, observed the intended failures, restored the source byte for byte,
and reran the passing cases. This matters because a test that stays green after the behavior it is
supposed to protect is removed provides no useful evidence.

## Live acceptance

A funded mainnet canary completed USDfr minting and transfer, sUSDfr deposit and transfer, direct
USDfr redemption and sUSDfr queue entry. Supply equalled recognized backing, and physical USDC in
ReserveManager equalled its idle ledger.

The operations Safe then blocked the canary by jurisdiction. USDfr and sUSDfr transfers, minting
and redemption refused the blocked wallet; one signed transfer was mined with failed status and no
value movement. Unrelated wallets and protocol burn legs remained available. The Safe cleared the
block, the wallet's retained allowlist status became effective again, and the temporary drill
balance redeemed for exactly 1 USDC.

The queue request remains in its contractually required 21-day cooldown until 12 October 2026.
The full settlement and claim sequence has passed on a fork, while its live settlement remains a
scheduled observation rather than a completed claim.

## Recent review history

The Audit Register now includes the September review sequence:

- the 13 September Corrovera dual-chain ensemble, which read 125 source files individually and
  explicitly did not establish dependency closure or review deployment scripts;
- the 17 September Corrovera diff review and its follow-up probes over the accrual, impairment,
  custody and legacy-default changes;
- the 18 September internal Solana and curator correctness review;
- the 20 September Corrovera curator-vault review and its remediation verification; and
- the 20 September internal review of the exact Ethereum V2 deployment on forked mainnet state.

The 13 September headline claim count is not presented as 317 confirmed defects. It was a claim
corpus: reviewers agreed on some claims, disagreed on others, and many depended on context that a
one-file review could not see. Later dependency-aware checks refuted the two proposed Highs,
confirmed and corrected the supported Mediums, and retained the scope limitation in the public
record.

The Solana curator vault is a separate product surface. Its canonical artifact is active and
verified on devnet; no Solana mainnet deployment has occurred. Its audit history must not be read
as assurance for the Ethereum contracts, or vice versa.

## Accepted and operational residuals

No new Critical, High or Medium contract defect was confirmed by the deployed Ethereum review.
The following limits remain relevant:

- If curator capital, sGROVE coverage and senior assets are all exhausted, a close can leave a
  remainder smaller than one USDC base unit. Value-sensitive operations fail closed. A funded
  worker may supply the exact correction under per-payment, daily and count limits.
- Repeated protocol-fee withholding during a standing senior impairment can reduce protocol
  revenue by more than the initial impairment. It favors senior backing and cannot extract senior
  assets.
- Live acceptance ran with an empty credit book; no synthetic loan was created to produce a launch
  receipt. Real facilities have been originated since 21 September 2026, each through the same
  attestation gate with its own documents, attester quorum and capital. See
  [Live deployment status](/docs/status).
- Module-wide Guardian pause/unpause has fork evidence but no recorded live Safe drill. The
  wallet-specific jurisdiction drill is complete and is a different control.
- Both marked-to-market keepers currently share Railway under an owner-accepted temporary hosting
  decision. This is a common administrative and hosting failure domain.

## Trust boundaries

Two valid attester signatures can establish any off-chain fact the accounting consumes. Credit
terms, payments, defaults, cures, losses, valuations and amendments each need two; the assignment
and lien-filing facts need one. The contracts enforce signer ordering, quorum, payload binding,
expiry and replay protection, but cannot inspect a legal document or independently prove that an
off-chain payment occurred.

The operations Safe controls KYC, operational servicing and emergency user-path pauses. It cannot
upgrade contracts or satisfy the attester quorum by itself. Timelocked governance can change
implementations and governed parameters after the voting and delay process. Canonical USDC,
Ethereum execution, RPC availability and keeper funding remain external dependencies.

Continuous accrual recognizes earned cash and PIK interest before receipt. It uses frozen facility
bases and constant-time aggregates. Lifecycle transactions checkpoint before changing a basis,
rate or earning status; differential and stateful tests compare those aggregates with independent
reference models over long event sequences.

## Reporting a vulnerability

Email **jevans@forestroad.com** and report privately rather than opening a public issue for a
problem that may affect deployed contracts or user funds. Include the affected contract and
function, the conditions needed to reach the behavior, its likely impact and, where possible, a
minimal test on a local deployment or fork.

Please do not test by moving another person's assets, accessing data that is not yours, or
degrading the live service. Findings that survive validation are added to the Audit Register with
their severity and disposition, including accepted findings.
