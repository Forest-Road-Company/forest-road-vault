# ADR-0039: One facility with concurrent cash-pay and PIK interest

**Status:** Implemented and deployed on Ethereum V2 (`BridgeMixedInterestLib` and reserve/waterfall/default
mixed-interest support live; Timelock-gated activation).

**Date:** 2026-09-21

## Context

The deployed Ethereum design records one annual rate and one `pik` designation on each facility.
That shape supports a cash-pay note or a PIK note, but not one legal participation whose economics
contain both legs. Splitting the participation into two NFTs works operationally for the initial
Pathway tranche, but it duplicates legal identity, exposure, servicing and default state. Future
originations need one NFT and one lifecycle while retaining separate cash and PIK obligations.

The owner has confirmed that the participation may use Actual/360 and that acquired participation
interests can be legally separated. The target feature is nevertheless one facility because that is
the faithful long-term representation. The first release remains fixed-rate. Variable benchmark
resets and 30/360 are outside this change.

Continuous recognition from ADR-0038 remains controlling:

- cash and PIK income are recognized as earned;
- both configured interest and performance fees apply as income is recognized;
- cash interest remains an unpaid interest receivable and never compounds;
- PIK compounds only at its signed capitalization boundaries;
- earning stops at default declaration; and
- reversal uses curator capital, then the shared sGROVE backstop, then senior principal.

## Architecture review

Three designs were evaluated against accounting correctness, upgrade compatibility and bounded
runtime work.

### A. Keep two protocol facilities and link them off-chain

Each leg would keep the existing code unchanged. This is simple in the contracts, but a partial
repayment, amendment, cure, default or recovery can reach one NFT without the other. Every operator,
attester and reporting system would have to preserve that cross-NFT atomicity forever. A failure
would create two on-chain states for one legal obligation. This remains an acceptable temporary
origination method, but it is rejected as the protocol model.

### B. Store one aggregate rate and divide interest only when it is paid

The reserve would stream the sum of both rates and later infer which part was cash or PIK. This is
incorrect after a principal payment during a PIK period: future cash interest must use the reduced
principal, while the current PIK coupon remains on its frozen basis. One aggregate curve cannot
represent both facts. It also lets servicing order decide how much compounds. This design is
rejected.

### C. One facility with two authenticated curves and one aggregate Book entry

The bridge stores the two rates and the two schedules under one facility ID. The reserve maintains
separate cash and PIK arithmetic, but opens one aggregate segment in the existing O(1) portfolio
Book. Aggregate recognition is the sum of the two contractual curves. At a signed capitalization
boundary only the PIK portion moves into principal; unpaid cash remains interest. This design is
selected.

The selected design adds no per-facility loop to a price-sensitive read. A mixed facility still has
one heap entry, one Book entry and one constant-time contribution to NAV.

## Decision

### 1. Signed terms and legacy compatibility

The existing `originate` and `amendTerms` selectors and hashes remain unchanged for existing
single-leg facilities. New `originateMixed` and `amendMixedTerms` entry points commit to:

- the existing common facility terms;
- a positive cash rate and a positive PIK rate;
- the cash payment interval and next cash due date; and
- the PIK capitalization interval and next PIK capitalization date.

The common annual rate equals the checked sum of the two rates and cannot exceed the existing
10,000 bps ceiling. The common due date equals the earlier unresolved leg date. Mixed facilities
are fixed-rate, Actual/360 receivables and retain `Facility.pik == true` for existing lifecycle and
default classification. A separate view discloses the split.

The mixed commitment is domain-separated from the legacy commitment. Every documentary
attestation selected by the class gate binds the mixed commitment at origination and again at the
funding recheck. Existing single-leg commitments remain byte-for-byte compatible.

### 2. Two monotone servicing clocks

The bridge retains separate cash and PIK dates. `Facility.nextPaymentDue` is always the minimum of
the two unresolved obligations, using maturity when a leg has no earlier date. Advancing one leg
cannot hide an overdue other leg. The aggregate date is monotone while ordinary servicing runs.

Cash receipts advance only the cash clock. Reserve capitalization advances only the PIK clock.
Each leg emits its own reconstructable event, and a change in the aggregate date keeps the existing
`NextPaymentDueSet` event.

### 3. Frozen PIK basis and prospective cash basis

Within a PIK period, the PIK rate uses the basis frozen at that period's opening. A principal
repayment does not rewrite that completed or partly completed contractual coupon. The cash rate
uses current principal and therefore rebases prospectively after a principal repayment.

The reserve carries fractional arithmetic through those prospective cash rebases so repeated
servicing cannot discard sub-unit entitlement. Aggregate interest is rounded once to the reserve
grid. The cash portion is identified separately; any final cross-leg grid remainder belongs to the
PIK portion so the two stored legs always sum exactly to the Book claim.

### 4. Capitalization and repayment ordering

At a PIK boundary:

1. both legs are recognized through the boundary;
2. only unpaid PIK is added to principal;
3. unpaid cash remains interest; and
4. the next cash and PIK curves both use the resulting principal prospectively.

For a mixed receipt, the signed cash-interest field can discharge only unpaid cash. The signed
principal field discharges capitalized principal first and may then discharge uncapitalized PIK.
It cannot silently discharge cash interest. Full repayment requires all three balances to be zero.

### 5. Fees, exposure and default

The existing aggregate Book remains the fee carrier. The protocol interest fee and sUSDfr
performance fee therefore apply continuously to the sum of both legs, with no second fee or price
jump when cash arrives or PIK capitalizes.

Posting raises the existing reserve `deployed` face and registry exposure by the exact aggregate
earned amount. Default stops both curves at the same block and posts their full face before the
existing curator-to-sGROVE-to-senior cascade. The default manager uses the bridge's minimum
unresolved due date; it never substitutes the PIK date over an earlier cash date.

### 6. Capacity

Admission uses a conservative ceiling that treats the combined cash-plus-PIK rate as if the whole
rate compounded at every PIK boundary. Real accounting compounds only PIK, so the reservation is
an upper bound. It cannot make the contractual balance larger; it only reserves arithmetic and
concentration capacity. This avoids a new under-reservation proof obligation at the cost of modest
unused headroom.

### 7. Upgrade activation and rollback

Mixed origination is disabled after implementation upgrades. A one-way activation call succeeds
only when the bound ReserveManager and WaterfallEngine expose the exact mixed-interest feature
version and the continuous Book is enabled, fresh and idle. The installation proposal also
upgrades ComplianceRegistry for ADR-0040, upgrades ClaimBridge, ReserveManager, WaterfallEngine and
DefaultManager, and atomically binds the borrower-payout policy. It leaves mixed-interest admission
disabled. A separate governance proposal activates the feature after the installed-but-disabled
system has passed its checks.

Before activation, each implementation can be rolled back through the ordinary governed path.
After activation, every affected proxy rejects an implementation that does not expose the feature
version. This prevents an old implementation from interpreting a mixed facility as an ordinary PIK
facility. There is no silent downgrade path.

Existing cash and PIK facilities need no migration. They retain zero mixed metadata and execute the
legacy branches. Facilities 2 and 3 from the initial Pathway tranche remain separate positions.

## Required evidence

The change is not complete until all of the following are recorded with real results:

- storage-layout compatibility and exact runtime-size margins;
- legacy differential tests proving unchanged cash and PIK behavior;
- an independent reference model for mixed accrual, capitalization, cash payment, principal
  payment, amendment, maturity and default sequences;
- long randomized sequences whose aggregate Book claim equals principal plus the two unpaid legs;
- invariants for backing, fee conservation, exposure, due-date monotonicity and cascade order;
- negative tests for malformed signatures, schedule mismatch, partial upgrades, old-code rollback,
  callbacks, reentrancy, stale accounting, pauses and role misuse;
- mutation controls for term binding, leg separation, frozen basis, due-date minimum, fee charging,
  default stop and rollback refusal;
- exact upgrade and rollback rehearsals on a pinned Ethereum fork and a current Ethereum fork; and
- generated calldata and a human-readable handover. No rehearsal may broadcast.

## Consequences

The bridge, reserve, waterfall and the DefaultManager's linked accrual logic participate in the
upgrade. The token, vault, controller, registry, curator and backstop accounting do not change.
Existing deposits, staked balances, first-loss positions and queue requests remain in their current
contracts and storage.

Mixed facilities require the new attester payload and keeper ABI. Operational tooling must refuse
to originate a mixed facility until the on-chain feature reports enabled. Funding-recipient policy
is enforced on-chain under ADR-0040. The initial approved recipient is
`0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337`; adding another address requires explicit owner
approval through governance.
