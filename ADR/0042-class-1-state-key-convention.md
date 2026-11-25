# ADR-0042: The class 1 state key convention

**Status:** Accepted (4 November 2026, by the owner's direction in session, recorded by the agent). Put to Forest Road as
a Draft the same day; the generic origination tool refused every class 1 spec until it was accepted.

**Date:** 2026-11-04

## Context

Class 1 (film and TV tax credits) is the only class whose facilities carry a non-zero `stateId`. ClaimBridge requires
`stateId` to be non-zero for class 1 and zero for every other class, and CollateralRegistry admits each origination
against a per-state concentration limit keyed by that `stateId`, beside the class and borrower limits.

The contracts do not define what a state key is. No class 1 facility exists yet, so the first one fixes the convention:
every later class 1 facility for the same state must use the same key, or that state's exposure is split across two keys
and its concentration limit is silently doubled. The convention is therefore permanent once used.

The borrower key already has a convention on chain: `keccak256("FRV:borrower:pathway-power-development-i-llc")` for
Pathway's facilities 2 to 11.

## Decision

A class 1 facility's `stateId` is `keccak256(utf8("FRV:state:US-XX"))`, where `XX` is the USPS two-letter code of the
state that issued the tax-credit certificate, in upper case, from a fixed list: the fifty states, DC, and the five
inhabited territories (PR, GU, VI, AS, MP).

The generic origination tool's receivable profile (`tools/origination/lib/profiles/receivable-standalone-v1.mjs`)
enforces it. A class 1 spec states `state: {preimage, stateId}`, and the tool refuses one unless:

- the preimage matches `FRV:state:US-XX` with a code on the list;
- `stateId` is the keccak256 of the preimage;
- the state is present exactly for class 1 and null for classes 2 to 4.

The source of the code is the issuing state on the certificate, and the per-origination reviewer checks it against the
certificate.

## Alternatives considered

- **The two ASCII bytes, left-aligned in a bytes32.** Readable on chain, but a different shape from the borrower key, and
  nothing in the value says which namespace it belongs to.
- **keccak256 of the bare code (`"CA"`).** Shorter, but it collides with any other two-letter namespace a later change
  might hash.
- **ISO 3166-2 (`US-CA`) without the `FRV:state:` prefix.** Equivalent in content, but the prefix keeps the protocol's
  keys in one namespace, as the borrower keys are.

## Consequences

- A mistyped code would open a new key and split a state's limit for good. The fixed list and the reviewer's check
  against the certificate are the guard; the tool cannot see the certificate.
- A certificate issued by a jurisdiction outside the list needs this ADR amended before its spec can be written.
- The convention covers the key only. The state concentration limit itself is the registry's `stateLimitBps`, set by
  `setStateLimit` under `DEFAULT_ADMIN_ROLE` (the Timelock) and read through `limits()`; it was 2,500 bps at deployment
  (the deployment manifest records it as `stateConcentrationLimitBps`). This record does not change it.
- While this ADR was Draft, the generic origination tool refused every class 1 spec after its other checks, with a
  message naming it. The gate was a named constant in the receivable profile (`STATE_KEY_CONVENTION`), not a reading of
  this file, so the acceptance is also a reviewed tool change: the constant records it (`accepted: true`, 4 November
  2026), the refusal is removed, and the same change adds a class 1 end-to-end build test. The state key checks stay.
- It gives the repository one canonical state-key encoding. The two spellings used before, `script/QA.s.sol`'s
  `keccak256("GA")` and the fork tests' `keccak256("US-GA")`, were both test-only, and no class 1 facility exists on
  chain, so this convention is the first and only one any class 1 facility will carry.
