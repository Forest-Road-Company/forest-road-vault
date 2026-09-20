# Forest Road Curator Subscription Vault (Solana)

This Anchor program is the settlement ledger for Forest Road's bilateral curator agreements.
Allowlisted wallets deposit classic SPL USDC, positions retain their contractual lock and notice
terms, the treasury draws and returns principal against individual positions, and a permissionless
crank pays completed-month coupons from a separate pool. Positions are non-transferable program
accounts; no receipt token exists.

The governing mechanics are in
`docs/curator-vault/CURATOR_SUBSCRIPTION_VAULT_SPEC_2026-09-18.md`. Counsel still controls the
agreement and public characterisation. No Solana mainnet deployment has occurred.

## Current implementation

- `Config` is a versioned singleton with 128 reserved bytes. It records the admin transfer,
  allowlist, treasury and one-way emergency authorities, the pinned mint and token accounts,
  rate epochs, aggregate principal/draw/coupon accounting and the launch policy.
- `Position` is versioned with 64 reserved bytes. It snapshots lock and notice terms when new
  principal opens, attributes each treasury draw to its owner, separates total coupon owed from
  coupon payable at the completed month boundary, and preserves notices through losses.
- Direct token transfers are treated as surplus. Treasury recovery instructions can remove only
  principal above the principal ledger or coupon tokens above the full accounted funding pool.
  Credited coupon funding remains locked while any position exists; after every position closes
  and aggregate coupon owed is zero, the treasury can return unused funding through a separate
  terminal wind-down instruction.
- `propose_admin` and `accept_admin` provide two-step admin rotation. `emergency_pause` can only
  pause deposits and draws; `emergency_halt` can only halt one position's coupon payout. The admin
  and allowlist authority respectively clear those states.
- Every curator payout uses the owner's derived associated token account. Every treasury draw and
  sweep rechecks the pinned destination's live mint and owner.

Account allocations, including Anchor's eight-byte discriminator, are 650 bytes for `Config` and
260 bytes for `Position`.

## Source layout

```
programs/forestroad-curator-vault/src/
  math.rs          Actual/360 arithmetic, carried remainder and UTC month boundaries
  state.rs         versioned Config and Position ledgers
  events.rs        complete transition records for operations and indexing
  error.rs         named refusal modes
  instructions/    admin, curator and treasury handlers
programs/forestroad-curator-vault/tests/
  lifecycle.rs     LiteSVM lifecycle, negative, stateful and invariant tests
  devnet_fork.rs   explicit deployed-devnet evidence; ignored unless selected with its keys
scripts/
  build-program.sh pinned SBF build
  build-release.mjs digest-pinned container build for the canonical release ELF
  build-provenance.mjs commit, program, ELF, IDL and release-builder receipt
  deploy-devnet.mjs devnet-only deployment with a durable pending receipt
  rehearse-devnet.ts devnet-only lifecycle rehearsal
  snapshot-devnet.ts finalized account snapshot for the deployed-evidence test
  verify-devnet.ts exact ELF/IDL, authority, state, signature and invariant verifier
  token-client.ts  minimal classic SPL instruction and account parser used by the rehearsal
```

## Build and test

The host build used for IDL generation and fast feedback pins Anchor CLI 1.2.0, Solana CLI 4.1.2,
Rust 1.98.1, SBF architecture v3 and platform-tools v1.57. `rust-toolchain.toml` and `Anchor.toml`
pin those host tools, and the build script refuses a mismatch. The deployable ELF comes from
`solana-verify` 0.5.0 in the digest-pinned Solana 4.0.3 release image, with SBF v3 and
platform-tools v1.57 passed explicitly. The exact ELF is committed under `deployments/artifacts/`;
deployment, snapshots, the frontend gate and the deployed-evidence test all consume that file.

```sh
cd solana/curator-vault
npm ci
npm run build:program
npm run build:release
cargo test -p forestroad-curator-vault --no-fail-fast
npm run lint:program
npm run typecheck
npm run test:ops
npm audit --omit=dev
node scripts/build-provenance.mjs --verify-generated
npm run verify:devnet
```

The local suite currently contains nine arithmetic tests and 24 LiteSVM lifecycle tests. The
lifecycle suite includes three positions, every instruction and authority, every event type and
field, named must-revert cases, partial withdrawal behavior, direct-donation recovery and 32
independent 96-step stateful books (3,072 checked steps). The campaign asserts every transaction
outcome and completes real post-notice withdrawals. The deployed-devnet test is explicitly
ignored in ordinary runs and hard fails on missing keys, a mismatched snapshot or a mismatched ELF
when run with `--ignored`.

`npm run test:mutations` rebuilds and tests eight program mutations: early payment of post-boundary
coupon, global rather than per-position loss attribution, removal of the coupon-liability reserve,
removal of both emergency-authority constraints, use of mutable global notice terms for an
existing position, removal of the live treasury-owner checks from both sweep paths, premature
return of accounted coupon funding and a new treasury draw after withdrawal notice. It asserts
that each mutation changed the ELF and made its directed test fail, then restores the source and
the pristine host artifact byte for byte. `npm run test:surface` keeps the 25-instruction,
38-error and 23-event test census from silently drifting.

## Accounting properties

- Physical principal plus deployed principal is at least recorded principal. Equality holds
  absent unsolicited token transfers; only the measured surplus can be swept.
- Global drawn principal equals the sum of position draws, and every position draw is at most its
  principal.
- Cumulative coupon paid never exceeds cumulative coupon funded. Physical coupon tokens cover the
  accounted unpaid funding (`coupon_funded - coupon_paid`), and no sweep may reduce that balance.
- `coupon_payable <= coupon_owed`; coupon checkpointed after the latest completed UTC month stays
  owed for the next boundary.
- Withdrawal eligibility requires a live notice and cannot precede the position's snapshotted
  lock end. A partial withdrawal retains the notice; a pending notice blocks new treasury draws,
  while principal already drawn can still be returned. An explicit cancellation gives up the
  remaining eligibility.
- Accrual is path independent with the carried `u128` remainder and rate epochs are strictly
  forward.
- Pause never blocks withdrawals, coupon payments, principal returns or coupon funding. A payout
  halt affects one position's coupon transfer while accrual and withdrawal rights continue.

## Deployment state

The devnet programs identified as `Bzz7…KNL3` and `HNWZ…sKZL` are retired rehearsal artifacts
with older account layouts. Their manifests remain historical records and must not configure a
new frontend build. The replacement program is
`3ZPRvNDUDRZuZ8Hug873JtSDJueA8D7PEVE21uLLAvwh`. Its manifest binds the source commit, committed
canonical ELF, IDL hash, digest-pinned release builder, deployment and rehearsal signatures,
finalized snapshot and canonical IDL metadata. The verifier matched the complete deployed
ProgramData prefix to the committed canonical ELF,
required zero trailing bytes, decompressed the published IDL and matched its exact SHA-256, and
checked the recorded authority, account, balance and conservation state. The explicitly selected
deployed-devnet test passed after fast-forwarding the snapshot through four coupon payments and a
full exit, the partial-month tail payment and position closure. The canonical 475,640-byte ELF has
SHA-256 `4cf28ebf3b911a59d7807a852fb81a03fe6680af5ddc94bad74a981efdf3a605`; it was activated at
finalized devnet slot 501,488,463. The activation changed no Config, Position, mint or token-account
bytes, as recorded in `deployments/devnet-upgrade-comparison-2026-09-20.json`.

Keys remain outside the repository. The rehearsal refuses any genesis other than devnet. It uses
documented untracked devnet key paths by default, accepts explicit environment overrides and
refuses a missing file rather than creating a signer. Solana mainnet deployment, Squads creation
and role assignment remain human-owned release gates. The mainnet program must use canonical USDC, a
reviewed 2-of-4 Squads with its time lock, a separately chosen emergency signer, a dedicated RPC,
an uploaded/verifiable program artifact and a post-deployment specialist review.

The owner-provided Corrovera review of 20 September and the remediation status are recorded in
`docs/remediation/CURATOR_VAULT_AUDIT_TRIAGE_2026-09-20.md`. The earlier internal review is a
historical checkpoint only.
