# Solana and curator correctness review

## Result at the checkpoint

The internal review found one Medium website defect that hid an existing Ethereum curator position
after approval revocation, and one Medium external-configuration defect that made WalletConnect
reject the live origin. It also recorded seven Low program, accounting and interface issues.

The revoked-position defect was fixed without changing the contract's withdrawal rights. The
owner replaced the Reown project and configured the intended origins, while the release gate now
checks the provider's public origin policy.

## Later status

The 20 September Corrovera curator-vault review and its remediation packages supersede this
checkpoint. They corrected the remaining accounting and interface items, expanded program and
frontend tests, produced a reproducible release artifact and activated the exact artifact on
devnet.

No Solana mainnet deployment occurred. The review used local builds, LiteSVM, independent integer
models, randomized state sequences, frontend checks and focused EVM curator tests.
