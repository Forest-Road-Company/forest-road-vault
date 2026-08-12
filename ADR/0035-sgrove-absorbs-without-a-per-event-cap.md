# ADR-0035 — sGROVE absorbs without a per-event cap

**Status:** Accepted — Forest Road decision, 2026-08-11.

**Supersedes:** the **per-event coverage cap** element of [ADR-0014](0014-sgrove-backstop-parameters.md)
and the carry-over restatement of it in [ADR-0021](0021-sgrove-backstop-implementation.md). Everything else in
both ADRs stands.

**Does NOT change the locked loss order.** `curator first-loss → sGROVE backstop → sUSDfr principal`
is a locked decision (CLAUDE.md §0.7) and is untouched. This ADR governs only *how much* layer two
absorbs per event, not *where* it sits.

---

## Decision

**`sGROVE` absorbs as much of a shortfall as it can, as soon as it can.** There is no per-event
ceiling and no snapshot. A single shortfall event may draw the entire coverage reserve.

ADR-0014 capped each event at `perEventCapBps` (50%) of the reserve, and explicitly rejected
"unbounded slashing (one event drains everything)". **That rejection is reversed.**

## Context — why the cap was reconsidered

**Finding P-15** (`POST_MERGE_FINDINGS_LOG.md`) established that the shipped implementation does not
apply the cap as specified: the ceiling is frozen at an event's *first* draw and never re-bounded
against the live reserve, so a 1-wei first draw pins a ceiling against the *full* reserve and a
returning event can take essentially everything. Executed on ROOT, a 100,000e18 reserve was reduced to
**1 wei** where ADR-0014 required 25,000e18 residual, and a third event received **zero** coverage.

The obvious remedy was to make the code honour the cap. It was not adopted, for a reason that emerged
while scoping it:

> **The cap does not deliver the property it was written for.** ADR-0014 and ADR-0021 justify it as
> *"preserving residual backstop for subsequent events."* But a per-event fraction produces
> **geometric decay, not fairness**: event A takes 50%, B takes 50% of the remainder (25% of the
> original), C takes 12.5%. Ordering still determines who is protected. The cap changes the rate of
> exhaustion, not the fact of it — and *any* chosen fraction has the same shape.

Given that, a cap adds a snapshot, a stored ceiling, an ordering artifact and four documentation
sites, in exchange for slowing a decay it cannot prevent. The simpler mechanism was preferred.

**Note that this is simpler than what ships today.** The current code is not absorb-as-you-can; it is
absorb-with-a-frozen-ceiling, which is what produces the 1-wei artifact. This decision *removes* the
cap and the snapshot rather than adding anything.

## Consequences — both weighed and accepted by Forest Road

### 1. Report ordering allocates protection — ACCEPTED

With identified-per-asset collateral, which default is processed first is partly a servicer's
operational choice. Under this ADR the first shortfall reported may consume cover that a later, larger
shortfall would have used.

**Forest Road accepts this**, on the rationale that capital in the coverage reserve exists to absorb
loss *now*, and that withholding available protection from a realised loss in order to reserve it for
a hypothetical future one is not a defensible use of a backstop.

If order-fairness is ever required, the correct instrument is **per-epoch or per-batch allocation
across known-simultaneous events**, not a per-event fraction — which, per the Context above, does not
achieve it.

### 2. The backstop is drainable, and this MUST be disclosed explicitly — REQUIRED

**Forest Road direction: make this explicit in the documentation.** A drainable backstop behaves
differently from a capped one in precisely the scenario that matters to a senior holder, and the
difference must not be left to inference.

Specifically, the following must state plainly that **a single shortfall event can exhaust layer two
entirely, after which senior principal absorbs 100% of any subsequent loss until the reserve is
replenished**:

- the sGROVE staking surface and any sUSDfr risk disclosure that mentions a backstop;
- `SGrove.sol` header NatSpec and `coverShortfall`'s `@dev`;
- `ICascadeBackstop.coverageCapacity()`'s documented meaning;
- the public documentation set describing the three-layer cascade.

**Do not describe layer two as "preserving a residual backstop."** That language is now false and is
the exact wording P-15 found contradicted by the code.

### 3. Consequent changes

| target | change |
|---|---|
| `contracts/src/SGrove.sol:279-295` | remove the per-event ceiling and its first-draw snapshot; bound draws by the live reserve only |
| `contracts/src/SGrove.sol:31-33`, `:254-256` | NatSpec — remove the cap formula; state drainability (Consequence 2). `:254-256` currently claims "at most `perEventCapBps` of the **current** reserve", which was already false |
| `contracts/src/interfaces/ICascadeBackstop.sol:31-34` | `coverageCapacity()` no longer means "what a single event could draw" as a *smaller* conservative choice — it becomes the live reserve |
| `Config.SGROVE_PER_EVENT_COVERAGE_CAP_BPS` | becomes dead; remove, and remove any governance setter |
| tests | ~25 shipped tests encode the capped semantics. Most **simplify**; each must be re-pointed deliberately, not deleted to go green |
| `ADR/0014`, `ADR/0021` | mark the cap element superseded by this ADR |
| `ADR/README.md` | index entry |

### 4. Sequencing

**This is landing/pre-audit work, not merge work.** `SGrove` is byte-identical across ROOT and the
four-input merge tree and is in neither's scope, so nothing here touches the frozen grading artifact
`279cad0`.

**It is in scope for the Part 11 gate 5 economic review.** ADR-0014's own status line records that its
numbers were to be confirmed in that review; removing the cap is a change to loss-absorption mechanics
and must be presented there rather than shipped quietly. Nothing in this ADR authorises any mainnet
action — Part 11 gate 1 remains outstanding.
