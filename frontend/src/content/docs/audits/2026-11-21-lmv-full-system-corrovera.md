# Corrovera full-system pre-upgrade audit of the LMV release candidate (1a26a72b)

## Result

Corrovera Security conducted a 22-workstream dual-prong review of the `1a26a72b` LMV release
candidate (including all 98 production Ethereum V2 Solidity files, the Stage 1 preliminary
release-monitor bundle, BSC bridge contracts, off-chain keepers, a captured snapshot of the live
Railway liquidation-bot image, and frontend logic/sync suites) and issued
**CONDITIONAL_GO_WITH_OPERATIONAL_AND_LOW_MEDIUM_FIXES**.

Zero Critical and zero High security blockers were found across all 22 workstreams. The engagement
verified 11 targeted remediation items in the LMV candidate (including the contract fixes for
`LMV-09` and `LMV-18`), challenged 24 reachability hypotheses, and confirmed seven new/residual
findings:

- **Two Medium findings:** `FRV-NEW-01` (double points-hook token paths failing closed under the
  16.78M transaction gas cap if governance replaced `PointsModule` with a gas-burning contract)
  and `FRV-NEW-02` (the deployed 5 November Railway liquidation-bot image lacking `HV-01`
  `coldReliefGasOverride()` and `JO-08` per-marked-leg gas scaling).
- **Five Low contract findings (`FRV-NEW-03` through `FRV-NEW-07`):** `SettlementWithheld`
  requestId attribution when the next head quotes zero, a chunk-2 `Queue_NoLiquidity` wedge after
  liquidity drops below the floor, dormant PIK repayment not syncing `ClaimBridge.nextPaymentDue`,
  EIP-150 63/64 forwarding precision in `PointsHookGas.requireSafeFailure`, and affordable
  full-head rejection when nominal remaining share budget rounds to zero assets.

Nine carried-forward prior or accepted items across bridges, servicing order, shared 2-of-4 Safe
signer sets, external market boundaries, and audit-register lag (`LG-01`) were also re-confirmed
and retained in the record.

## Remediation status

All six smart-contract findings (`FRV-NEW-01` and `FRV-NEW-03` through `FRV-NEW-07`) were
remediated in candidate commits `74ac92a7` and `ee9b228a`, verified across Corrovera's 23–24
November delta audits (`PASS`), and passed exact-commit hosted CI (`66/66`). Those fixes are
staged on Ethereum mainnet and activate when Stage 2 governance executes.

`FRV-NEW-02` remains **Open**: deploying the reviewed `liquidation-bot` image with `HV-01` and
`JO-08` and verifying live runtime identity remain required operational release gates prior to
Stage 2 clearance.

## Scope and evidence limits

The review retained explicit caveats that bound its claims: the automated 7-pass engine pilot was
labelled incomplete (one degraded pass slot on Bedrock and an offline Slither pipeline duplicate-ID
crash), six offline frontend render test files failed due to unbundled optional packages, and live
Railway environment variables were not read. Five independent Foundry fork suites (26 passing
tests), 42 supplied regressions, 3 mutation controls, 160 Python tooling checks, and disposable
Postgres 16 integration suites formed the independent verification prong.
