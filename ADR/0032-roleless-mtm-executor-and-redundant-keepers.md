# ADR 0032 — Roleless MTM executor and redundant private keepers

**Status:** Accepted (Forest Road direction, 2026-08-03). Production deployment,
independent-host evidence, end-to-end drills, and external audit remain gates.

## Context

Digital Assets valuations can immediately require a margin call, cure, or liquidation. Publishing
an action-triggering signed valuation before its protective action creates the D5-03 run-dynamics
window described in the launch runbook. A keeper cannot close that window with two ordinary
transactions: the attestation and action must either both land or both revert.

Giving the keeper an action parameter is also insufficient. At an 8,000-bps hard breach both
`marginCall` and `liquidate` can be callable, so a compromised or misconfigured keeper could choose
the weaker action even though it holds no formal role. The transaction boundary must select the
canonical protection itself.

## Decision

Deploy `MtmAtomicExecutor` as a plain non-upgradeable contract after the governor proxy in the
clean-v1 CREATE sequence. Its protocol dependencies are immutable: the existing
`AttestationOracle` and `DefaultManager` addresses. It has no owner, role, upgrade path,
arbitrary-call surface or payable path. Its only mutable storage is OpenZeppelin's reentrancy lock;
it carries no configurable protocol state.

`execute(attestation, signatures)` accepts only `Valuation`. It computes the signed digest, calls
`AttestationOracle.attest`, observes whether a margin call was already active, and attempts
`DefaultManager.liquidate` first. It may fall through only when liquidation returns the complete
canonical ABI encoding of `DefaultManager_ThresholdNotBreached` for the same facility, with a
non-zero threshold and `ltv < threshold`:

- without an active call, the fallback is `marginCall`;
- with an active call, the fallback is `clearMarginCall`.

Every other liquidation error is bubbled. The complete-shape check rejects malformed, accidental
and selector-colliding dependency failures, but custom-error bytes carry no provenance: a
deliberately forged canonical payload from a downstream dependency can still trigger the fallback.
Forest Road accepts that Low/PROVEN residual as `MTM-01`; the acceptance conditions and revisit
triggers are recorded in the operator-gate checklist. If the fallback is also not valid—including
at exactly `cureDeadline` while LTV remains at least 6,500 bps—the whole transaction reverts,
including digest consumption, the latest mark, and the valuation watermark. One second after the
deadline, a second fresh signed mark can take the liquidation branch.

`execute` is `nonReentrant`. This is defense in depth around the immutable proxy dependencies and
their downstream calls; it also ensures no nested execution can occur before the canonical
completion event is emitted.

Operate two instances of `mtm-keeper/` with distinct roleless ETH keys, private-feed credentials,
RPC providers, private relays, alert routes, hosts, and administrative control domains. A Railway
service may host one; another service in the same Railway account/project does not establish an
independent failure domain. Neither keeper gets any protocol or Safe role. The attester signatures
authorize the valuation and the existing on-chain state authorizes the action.

The feed is authenticated and must deliver each outstanding bundle independently to both keepers
until each acknowledges it. It honors the worker's bounded-capacity header and can return multiple
outstanding bundles in one response. Each worker stages a bounded set, validates every quorum
promptly and serializes ready executions by confirmation deadline, so a future-dated bundle cannot
head-of-line block ready work. The header advertises the total staging window; the worker filters
repeated staged IDs before applying its free-slot bound, so a non-consuming feed cannot recreate
head-of-line blocking by returning an unacknowledged item first. Missed-deadline items keep driving
the fail-closed pause path and are rejected/evicted at attestation expiry, preventing dead entries
from permanently consuming the bounded window. The worker uses `eth_sendPrivateTransaction` only;
there is no public submission fallback. A signed valuation is a one-use bearer authorization
because `AttestationOracle.attest` is permissionless. The worker therefore never sends signatures,
executable `attest`/`execute` calldata or a signed transaction to `READ_RPC_URL` or
`PUBLIC_WATCH_RPC_URL`, including by `eth_call` or `eth_estimateGas`. It derives the EIP-712 digest
in-process so the unsigned valuation payload also stays private, never sends that potentially
dictionary-attackable digest as a pre-inclusion query, and recovers peers by facility-filtered
already-public executor events with local digest comparison. It then validates recovered signer
order and authorization locally against signature-free canonical oracle reads. Immediately before
each attempt it takes a block-consistent signature-free snapshot and mirrors the executor's action
selection in-process, without sending the signed mark to the RPC, so deterministic paused, stale,
non-live and no-action cases fail closed before relay submission. It uses a fixed, fork-evidenced
`EXECUTION_GAS_LIMIT` whose accepted range starts at 2,000,000; the final deployed-threshold value
still requires operator approval. It releases the signed raw transaction first to the approved
confidential private relay, enforces configured fee caps and minimum balance, uses
bounded same-nonce replacement attempts, waits for canonical confirmations, checks for reorgs and
public-mempool visibility, verifies the required oracle/action/remedy events in one receipt, and
recognizes a peer keeper's canonical winner by the executor's digest-indexed event.

The keeper continuously scans live Digital Assets facilities for the first stale second and strict
cure-expiry boundary using the registry's live `maxMarkAge`. It immediately validates every staged
quorum locally using the oracle digest, threshold, attester roles, pause state, timestamp and
valuation watermark, but no scheduled or submitted bundle suppresses a finding: only canonical
on-chain state proves that protection landed by the safety cutoff. Startup discovers
the canonical queue through the validated manager/vault path before evaluating the supplied queue,
then reciprocally binds queue, vault, vault asset and reserves. On
a missing/invalid bundle, low
balance, unavailable private path, public leak, unmatched receipt, missed cutoff, stale heartbeat
or monitor failure it sends an authenticated request containing the exact
`RedemptionQueue.pause()` calldata to a separately controlled guardian workflow and retries a
successfully delivered request at a bounded interval because HTTP delivery is not pause proof. The worker never
receives a guardian or Safe-owner key. The independent heartbeat receiver, not the keeper itself,
detects a dead instance and both-keeper failure.

## Rejected alternatives

- **Generic Safe/multicall executor:** unnecessary arbitrary-call authority and a larger review
  surface.
- **Caller-selected action enum:** permits a hard-breach liquidation to be downgraded to a margin
  call.
- **Catch every liquidation failure and fall back:** masks pauses and downstream failures; only the
  exact threshold miss may fall through.
- **Standalone attestation followed by a keeper action:** recreates the public run-dynamics window.
- **Privileged keeper/automatic guardian key:** turns a low-value gas key or hosted service into a
  protocol-control principal.
- **Two services under one hosting account:** redundant processes, but not independent hosting or
  control.
- **Public-RPC fallback during relay failure:** leaks the valuation and signatures precisely when
  the fail-closed queue pause is required.
- **Signature-bearing pre-submission RPC simulation:** an RPC operator can extract the signatures
  from `eth_call` or `eth_estimateGas` and consume the permissionless oracle digest separately.
  Local quorum/action validation plus a reviewed fixed gas ceiling keeps executable calldata inside
  the already-required confidential relay boundary. Because local state can race and downstream
  calls can still fail, the selected relay must itself simulate privately and suppress reverting
  transactions rather than publish or include them.

## Consequences

- The production contract inventory increases from 19 to 20. Mainnet artifact, deployment-script,
  authorization, and gas-policy receipts must be regenerated; no prior deployment hash remains
  approvable.
- Appending the executor after the governor preserves every existing core module CREATE address.
- Healthy, non-actioning marks are outside this narrow executor and remain a separate attestation
  delivery responsibility. The risk scanner still pages and invokes the queue-pause workflow if a
  live facility approaches staleness without a fresh bundle.
- Bounded multi-bundle staging closes the repository limitation `KPA-L1`. The selected production
  feed must support the batch contract and still needs a simultaneous-facility load test with an
  approved latency/capacity receipt before production sign-off.
- The private relay is an explicit bearer-secret recipient. Provider/operator identity,
  authentication, access, request logging/retention, private inclusion, deterministic-revert
  suppression and no-public-rebroadcast controls are approval evidence; HTTPS and a provider label
  alone do not close that boundary.
- A queue-pause webhook is a request, not proof of an on-chain pause. Production evidence must show
  the guardian's private Safe path executed it before the safety boundary and that settled claims
  remained available.
- Source, unit tests, and fork deployment validation do not close Task D. Closure requires external
  executor audit, two independently funded live instances, private-relay and heartbeat evidence,
  failover/reorg/leak/low-gas drills, guardian pause and continued-claim rehearsal, and archived
  approval.

---

## Implementation note — 2026-08-28: the guardian and heartbeat receivers now exist

This ADR specifies "a separately controlled guardian workflow" and an "independent heartbeat
receiver". Both are now implemented, and the worker enforces their presence: it refuses to boot
without `ALERT_WEBHOOK_URL`, `HEARTBEAT_WEBHOOK_URL` and `PAUSE_REQUEST_WEBHOOK_URL`, so a keeper
cannot run with its escalation path unconfigured.

`keeper-receivers/` implements all three. It **holds no key**, as this ADR requires: the pause
endpoint records the request durably, pages, and holds it open until a human acknowledges, and the
Ops Safe executes the actual `pause()`. It independently re-checks the two things the keeper cannot
check for itself, refusing any request whose queue is not the configured one or whose calldata is
not exactly `pause()` (`0x8456cb59`).

Two points bearing directly on the decision recorded above.

**The heartbeat receiver cannot be the only detector, and this ADR's wording slightly understates
why.** "The independent heartbeat receiver, not the keeper itself, detects a dead instance" is
right, but the receiver cannot detect *its own* death, and when it dies the keeper's entire
escalation path dies with it: `#heartbeatTick` notices within 60s, sets `pauseRequired`, then
attempts a critical alert and a pause request that both go to the dead receiver. The implementation
therefore adds an **external dead-man's-switch**, withheld whenever a keeper is stale/unseen/
unhealthy or a pause request is open and unacknowledged. That external monitor, not this repository,
is what covers a total platform outage.

**"A queue-pause webhook is a request, not proof of an on-chain pause" is now enforced in code.**
An open request stays open until explicitly acknowledged through the ops endpoint, and while it is
open the dead-man ping is withheld. The bullet under Consequences stands unchanged: production
evidence must still show the Safe path executed the pause before the safety boundary.

Task D remains open. Two funded live instances now exist and heartbeat evidence is being produced,
but external executor audit, the drills, guardian pause rehearsal and archived approval are not
closed by this work.
