# Formal methods — proved properties and limits

**Status:** current engineering assessment and release-gate specification.

CLAUDE.md §1.5 names the loss cascade and backing invariant as candidates for symbolic
or SMT-based checking. Both now have Halmos artifacts and both run in CI. This document
states exactly what those artifacts prove and, equally importantly, what they do not.

Nothing in this repository should be described as “the whole protocol is formally
verified.”

---

## 1. CI gate

The `symbolic` CI job pins Halmos 0.3.3 and runs:

```text
halmos --match-contract BackingSymbolic
halmos --match-contract CascadeSymbolic
```

The functions are `check_`-prefixed, so ordinary `forge test` intentionally ignores
them. A failure, timeout, or counterexample in either Halmos command fails the symbolic
job.

Current local result on 2026-07-30:

- `BackingSymbolic`: 5 properties, 68 paths, zero counterexamples;
- `CascadeSymbolic`: 1 property, 9 paths, zero counterexamples.

## 2. Backing transition proof

Artifact: `contracts/test/symbolic/BackingSymbolic.t.sol`.

The invariant is:

```text
USDfr.totalSupply() <= ReserveManager.totalBackingValue()
```

### What executes real production code

Four properties deploy the shipped `MintRedeemController` and `ReserveManager`
implementations through ERC-1967 proxies. Halmos quantifies over every argument satisfying
the stated preconditions and executes the real role checks, ERC-7201 storage, decimal
normalization, reserve writes, controller postcondition, and cross-contract calls.

Those properties cover:

1. idle-to-deployed funding plus fee capitalization;
2. an aggregate USDfr loss burn;
3. principal repayment, interest recognition, and the matching yield mint;
4. principal write-down paired with the cascade’s equal aggregate USDfr burn.

Every property also asserts:

- supply does not exceed backing;
- the controller’s public backing view agrees;
- the idle ledger does not exceed modeled USDC custody; and
- total backing equals idle reserve plus deployed principal.

### User mint/redeem lemma

SafeERC20’s symbolic allowance and transfer plumbing makes a full-domain execution of the
user transfer paths impractical in this toolchain. The fifth property therefore proves
the exact induction lemma those paths use:

```text
supply <= backing
  => supply + x <= backing + x
  => supply + x - y <= backing + x - y
```

with overflow and subtraction preconditions, over the full 256-bit domain. Unit, fork,
and differential stateful tests bind the real controller behavior to the lemma: a user
mint increases both sides by the exact normalized USDC receipt, and redeem burns the exact
normalized USDfr value before releasing the same backing value.

This split is intentional and disclosed. The lemma is a proof of arithmetic; the binding
to SafeERC20 execution remains tested evidence rather than a formal equivalence proof.

### Token trust boundary

Canonical USDC and USDfr are represented by minimal exact token models. They supply
standard balance, allowance, mint, and burn semantics while the real accounting contracts
execute around them. Separate production tests and deployment validation establish that:

- canonical USDC has six decimals and exact-transfer behavior;
- the controller is the sole USDfr minter/burner;
- every controller mint runs its backing assertion; and
- deployed role topology matches the intended trust boundary.

The proof would not remain sound for a fee-on-transfer or adversarial replacement stable;
production configuration forbids that replacement.

## 3. Loss-cascade arithmetic proof

Artifact: `contracts/test/symbolic/CascadeSymbolic.t.sol`.

For all `(loss, poolBalance, covered)` in the full 256-bit domain satisfying the
production preconditions, it proves:

- `absorbed + covered + depositorLoss == loss`;
- no layer absorbs beyond its capacity; and
- senior loss is nonzero only after curator capacity is exhausted and backstop coverage
  is below the residual.

Under ADR-0035 the backstop capacity in this model is the whole live USDfr reserve. A single event
may therefore exhaust layer two; later loss reaches senior principal until replenishment.

This artifact is a pure arithmetic model mirroring the split in
`DefaultManager.realizeLoss`; it does not execute `realizeLoss` itself. Differential
stateful assertions bind the production split to the model, but that binding is sampled.
Contract/model drift is therefore a residual risk and must be reviewed whenever either
side changes.

## 4. Why this is not whole-protocol formal verification

The backing proof is a collection of inductive transition lemmas, not a theorem over
arbitrary composed protocol state. Its explicit limits are:

- token contracts are exact models at the trust boundary;
- user SafeERC20 paths are bound to a full-domain arithmetic lemma by tests, not symbolic
  equivalence;
- mappings are exercised through selected transitions rather than universally quantified
  across an unbounded set of facility keys;
- exogenous canonical-USDC custody loss is outside the preservation theorem—a
  `reconcileIdleUSDC` call can reveal real under-backing and must trigger incident response
  and loss recognition; and
- attestation truth, legal enforceability, governance key compromise, and upgrade safety
  are not mathematical consequences of the accounting proof.

These are reasons to retain the heavy stateful, fork, static-analysis, deployment, and
external-audit gates, not reasons to weaken the symbolic checks.

## 5. Complementary stateful evidence

`test/invariant/BackingFocusedInvariants.t.sol` remains the narrow, deep search over the
real composed credit system. It drives only supply/backing-changing selectors at the heavy
profile and checks backing, reserve reconciliation, and custody bounds after long
sequences. The wider credit, token-layer, and queue invariant suites exercise additional
composition.

The global-HWM per-operation carry property is deliberately not presented as a
composition theorem. A separate production-wired integration regression exits through
the real queue, claims, re-deposits the same economic position, and then cures the
impairment. It independently checks restored asset/supply state, monotone
holder-protective per-share hurdle behavior, and the explicitly accepted
protocol-revenue under-collection. That is deterministic regression evidence for the
known sequence, not a symbolic proof over arbitrary flow compositions.

The correct assurance statement is therefore:

> The core backing transitions have five symbolic preservation properties against the
> real controller/reserve accounting code plus an exact user-flow arithmetic lemma; the
> cascade split has a symbolic arithmetic proof; the composed protocol is additionally
> tested with stateful and fork campaigns and is not claimed to be fully formally verified.
