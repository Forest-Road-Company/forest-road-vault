# ADR-0020 — AttestationOracle implementation and the attested-fact re-wiring

**Status:** Accepted (2026-07-10, Phase G). Implements the resolved ADR-0007 spec;
attester-set composition and per-kind thresholds are launch defaults for the
pre-mainnet reviews (economic + Forest Road's conscious acceptance of the trust
boundary, brief Part 11 gate 6).

> **UPDATED BY ADR-0030 FOR CLEAN MAINNET V1.** Facility-zero reserve valuation and
> DSRA references below are historical. The v1 oracle exposes only the nine kinds
> required by the final legal/operational matrix, with exact payloads for
> value-destructive actions.

## The oracle

**Submission model — relayed bundles:** one `attest(input, signatures[])` call carries
m-of-n EIP-712 signatures over the IDENTICAL struct
`Attestation(uint256 facilityId, uint8 kind, bytes32 payload, uint64 asOf,
uint64 expiry, uint256 nonce)`. Anyone may relay — the signatures are the authority.
Chosen over per-attester submission trickle: cheaper, atomically threshold-checked,
and m-of-n over the *same payload hash* means signers co-sign identical facts, not
merely the same topic. Signatures must be sorted by ascending recovered address (the
cheapest distinctness proof).

**Replay and rollback safety:** every accepted digest is consumed forever
(`digestUsed`); `expiry` bounds submission windows; `asOf` must be a PAST attested
observation time (`0 < asOf <= block.timestamp`) — it lives inside the signed struct,
so freshness rules (ADR-0015/0017 margin path, `maxMarkAge` draws) measure attested
time, never submission time. `Valuation` additionally requires strictly increasing
`asOf` per facility: a stale-but-genuinely-signed mark can never roll back a newer one.
Zero-value marks are rejected (0 = "no mark" everywhere downstream).

**Thresholds:** per-kind, governance-set, default 1 except `CreditIssued` and
`Valuation` at 2 (ADR-0007's high-value kinds). Extra signatures beyond threshold are
accepted.

**Lifecycle of a fact:** `attest` → satisfied; `consume` (CREDIT_ROLE — the
WaterfallEngine spends `PaymentReceived`) clears satisfied but retains payload/asOf as
the audit trail; `revoke` (governance) clears satisfied and, for `Valuation`, zeroes
the mark so a fraudulent mark cannot keep steering the margin path (and its asOf reset
lets an honest fresh mark land).

**Pause policy:** guardian pause blocks SUBMISSIONS only (the lever against suspect
attesters); reads and consumption never pause — freezing consumption would strand
already-attested value flows.

**Facility id 0** is reserved for the treasury reserve instrument.

## The re-wiring (what stopped trusting roles)

1. **Reserve-instrument mark:** `ReserveManager.setAttestationOracle` permanently
   retires the RESERVE_ADMIN setter (reverts `OracleWired` forever after);
   `syncReserveInstrument()` is permissionless and relays the attested 2-of-n
   `Valuation` of facility 0 into the treasury. The Phase C wiring caveat is closed.
2. **Payment gate:** `WaterfallEngine.distribute(tokenId, interest, principal)`
   requires a currently-satisfied `PaymentReceived` whose payload is
   `keccak256(abi.encode(tokenId, interest, principal))` and CONSUMES it — one
   attested receipt authorizes exactly one distribution, amounts bound by signature.
   SERVICER_ROLE now gates who may execute, not what is true.
3. **Default gate:** `declareDefault` requires a satisfied `DefaultDeclared` (kept
   standing, not consumed — it is the record behind the remedy process). `realizeLoss`
   remains bounded by state + outstanding (a facility only reaches
   Defaulted/Accelerated through an attested declaration or a signed-mark
   liquidation).
4. Left role-trusted deliberately: `fund` (escrow release is contractually contingent
   on the already-gated NFT), `serviceFromDSRA`/`refundDSRA` (bounded by the
   borrower's own escrow), `accelerate` (requires attested-Defaulted state),
   `realizeLoss` amount (servicing judgment over recovery outcomes, cascade-bounded).

## Test strategy

The mock oracle's VIEW semantics are kept byte-identical to the real oracle (that
equivalence is what the real oracle's 27-test unit suite proves), so all mock-based
consumer suites remain valid. `RealOracleFixture` swaps genuine EIP-712 signing into
the full-stack fixture via virtual hooks; `AttestationFlow` runs the brief's
lifecycles with no mock anywhere (mint gate, single-use payment gate, signed-mark
margin path, treasury sync). `OracleInvariants` fuzzes the real oracle against an
independent ghost state model (differential parity of the entire visible state) with
per-call no-replay and monotonicity asserts.
