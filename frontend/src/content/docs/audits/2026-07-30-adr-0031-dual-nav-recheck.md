# Protocol fee stack, dual-NAV remediation re-check

## Why this round exists

The preceding remediation separated redemption NAV from performance-fee NAV so
temporary junior protection could support exits without being mistaken for investment
performance. That removed the bracket-driven high-water-mark mutations reported in
the prior round.

This round reviewed that dual-NAV change. It confirmed all four prior code findings
were closed, but found that the same unit mismatch survived on the exit leg: the
performance hurdle was denominated in performance NAV while the amount carried out
was measured at the higher redemption price.

## How it was run

The review used 64 agents, produced 26 raw candidates, retained 16 after two-lens
refutation, and consolidated the surviving issues into code and completeness
findings. The review re-derived the arithmetic from source, traced the permissionless
past-due and queue paths, reproduced the stated local test and bytecode-size figures,
and inspected whether the invariant harness could construct the production
dual-NAV state.

## What the preceding remediation got right

The assessment-invalidating bracket defect is structurally gone:
`endFeeNeutralMarkedNavChange` only releases the lock, and junior-capacity changes do
not write the HWM. Performance-fee impairment no longer contains live curator or
backstop capacity, so temporary netting cannot permanently raise or lower the fee
hurdle.

The replacement-backstop probe is also genuine and restores the one-transaction
self-repair path. The assessment snapshot's presence bit and the ordering between
redemption and performance impairment were independently checked and found sound.

## High finding: an exit carried the hurdle at the wrong price

Let:

- `R` be redemption NAV, after temporary junior-capital netting;
- `P` be performance-fee NAV, before that temporary credit; and
- `H` be the asset-denominated performance hurdle.

During a junior-covered workout, `R` can be greater than `P`. An exit pays its share
of `R`, but the pre-remediation helper subtracted that physical payout directly from
`H`. That preserved the absolute `H - P` drawdown rather than its per-share value.
The exiting holder could therefore leave their deferred fee exposure with the
remaining holders. A later cure charged the same absolute profit even though only a
fraction of the original shares remained.

This creates a permissionless run incentive: request and settle an exit while junior
capital supports redemption NAV, then let stayers absorb the deferred performance
fee when the impairment cures.

The required carry is the greater of two independently meaningful quantities:

1. the asset carry, `max(H - assetsPaid, 0)`, which protects stayers in a genuine
   drawdown; and
2. the pro-rata carry,
   `ceil(H × postFlowVirtualSupply / preFlowVirtualSupply)`, which keeps the
   leaver's share of deferred fee exposure with the shares that leave.

Neither term can replace the other safely. The maximum selects the protective rule
for the valuation regime actually in force.

## Remaining findings

The review also reported:

- the queue assurance tier could not construct divergent redemption and performance
  NAVs, and its fee-legality witness depended on the HWM being tested;
- an entrant during a global fee-deferral window could later pay a share of
  pre-arrival performance without any ERC-4626 redemption impairment signalling it;
- the legacy-proxy zero-HWM upgrade seed anchored to the new lower performance base;
- management/performance sequencing had no test that could distinguish the new
  formula because every existing case used equal NAV views; and
- `setBackstop` always used effects-first ordering, billing elapsed management fees
  at the replacement NAV even when the outgoing dependency was healthy.

## Subsequent remediation in the working tree

The working tree now implements the two-term maximum on exits. The regression first
reproduced the reported cure overcharge, then verifies that a half exit carries
exactly the correct remaining hurdle and cannot transfer deferred performance-fee
exposure to stayers.

The queue handler can now drive redemption and performance impairment independently.
Its named HWM property derives the expected post-flow hurdle from pre-flow assets and
supply rather than treating the HWM itself as proof that a fee was legitimate. A
separate integration uses the production `AssessedImpairmentSource` wiring with a
live queue exit.

The legacy zero-HWM path anchors to the higher redemption base. A distinct-NAV test
now discriminates management-fee sequencing from performance-fee sequencing.
`setBackstop` checkpoints before rotation when the outgoing dependency is readable,
while retaining effects-first recovery when it is not. The staking interface warns
when performance-fee NAV is below the global HWM and explicitly says the mark is not
personal to the depositor.

## Local verification of the remediation

The current candidate reports:

- 936 passing, 0 failing, and 183 RPC-dependent skipped tests in both optimized and
  coverage profiles;
- 2,809/2,811 production lines, 438/443 branches, and 492/492 source-defined
  functions covered;
- 60/60 heavy invariant properties at 512 runs by 256 depth, with zero handler
  reverts;
- 181/181 pinned Ethereum-mainnet fork tests and 3/3 tests against the existing
  Sepolia deployment;
- 18/18 storage-layout structures matched;
- 98 Slither results matched by 92 reviewed fingerprints;
- zero-counterexample backing and cascade symbolic checks; and
- frontend logic, 395/395 contract-sync checks, 10/10 mounted render tests, lint,
  TypeScript, dependency audit, and an explicit-Sepolia build passing.

The changed `sUSDfr` runtime is 24,221 bytes, leaving 355 bytes below the EIP-170
limit. That margin is a maintenance constraint, not a security claim.

## Status

The findings in this historical review remain **open** until the external reviewer
confirms the remediation delta. The evidence above is local engineering evidence,
not an external closure opinion. No deployment or broadcast occurred, and prior
mainnet deployment or artifact receipts do not identify this changed source.
