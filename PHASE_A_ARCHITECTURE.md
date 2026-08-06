# Phase A — Restatement & Architecture (DRAFT for review)

> **CHANGE RECORD — 2026-07-09 (Forest Road direction):** a fifth collateral class,
> **Digital Assets**, was added mid-build (see `ADR/0015` and the change record atop
> `FABLE_BUILD_BRIEF.md`). Where this document enumerates four classes, read five;
> ADR-0003 is amended accordingly; `CollateralRegistry` gains a `collateralModel`
> discriminator (Receivable | MarkedToMarket) plus margin parameters for the new class.

**Status:** Architecture prepared for Forest Road, with all launch and technical decisions **resolved** (see §3 ADRs and §5). Fable proceeds directly from this document into implementation — no human sign-off is required before or during the build. Fable may still challenge or improve any technical detail here (it is engineering guidance, not scripture), but the decisions marked *Resolved*/*Locked* reflect Forest Road's direction and should not be reopened without Forest Road input.

**Companion document:** `FABLE_BUILD_BRIEF.md` (the full brief). Read Part 0.5 (regulatory reality) and the Part 4 locked decisions before relying on anything here.

---

## 1. RESTATEMENT (proving the mapping is understood)

### 1.1 What USD.AI does (mechanically)
USD.AI channels stablecoin liquidity into loans that finance AI hardware (GPUs), with the hardware and its cashflows as collateral.
- **`USDai`** — fully-backed synthetic dollar; mint 1:1 from stablecoins; idle reserves in T-bills; does not itself yield; redeemable.
- **`sUSDai`** — yield-bearing; stake `USDai` to get it; captures loan interest + reserve yield via a **rising exchange rate** (not claim-and-distribute); the depositor bears book performance.
- **CALIBER** — each physical GPU is stored/insured, documented under UCC, and tokenized as an **NFT = legally enforceable claim** to that asset; loans issue against it.
- **FiLo curators** — originate/manage loans and post **first-loss capital** beneath depositors.
- **Dual record system** — off-chain (SPV, perfected liens, escrow, insurance) and on-chain (Loan NFTs, authoritative lender register, automated waterfall), **synchronized at every material event**; the NFT mints only when off-chain + on-chain conditions both hold; in default both layers act at once.
- **Terms** — 70–80% LTV, non-recourse with springing recourse on fraud. ADR-0028 retired the self-funded DSRA; any future borrower-funded reserve requires separate review.
- **QEV** — redemptions of the yield token run on an epoch FIFO queue (illiquid underlying).
- **CHIP / sCHIP** — governance; sCHIP is a shortfall backstop.

### 1.2 What Forest Road does
A vertically-integrated speciality-finance merchant bank. Originates, underwrites, and services credit **in-house** across: **film/TV tax-credit lending** (lends against transferable US state tax credits), **renewable energy** (CenterNode — tax-credit + project-cashflow financing for small/mid-market projects), **life sciences** (venture debt / royalty / milestone credit), and **real estate** (property-backed debt). Also runs asset-management and advisory platforms and an existing **digital-assets/blockchain arm** — meaning Forest Road already has internal capacity to steward an on-chain protocol.

### 1.3 The mapping
Replace single-asset GPU financing with Forest Road's **multi-vertical speciality-finance receivables and project loans**, keeping USD.AI's technical spine (dual-token, per-asset tokenized collateral, curator first-loss, dual record, epoch redemption, governance).

### 1.4 The critical differences (these drive the architecture)
1. **Collateral is a receivable/claim, not a physical depreciating asset.** Tokenize the *loan + perfected security interest in the receivable* (UCC-1 on the credit + assignment), not a claim to a machine. No ITAD/physical repossession for credit-backed classes — default remedy is foreclosing the assigned receivable and **selling the credit into the secondary market**. Depreciation risk → **issuance-timing, audit/clawback, state-counterparty, and secondary-price risk**. "Hardware monitoring" → **milestone/attestation monitoring** (spend verification, audit status, issuance confirmation).
2. **Multi-vertical → multi-collateral.** Each vertical is a collateral class with its own governance-set LTV, rate tier, reserve sizing, eligibility, maturity, and default path. Diversified backing across uncorrelated classes is *stronger* than single-sector concentration.
3. **Forest Road is the originator/underwriter.** It can be the **anchor curator** posting first-loss from its own capital, with pluggable additional curators later. Stronger trust story than third-party origination.
4. **Duration/liquidity vary by vertical** (film short; renewables/biotech long) → blended, multi-maturity book; redemption-queue and reserves must account for it.
5. **Regulatory surface** — yield token is very likely a security (see brief Part 0.5); tax-credit assignability varies by state; KYC/AML on mint/redeem. Build the compliance *hooks*; counsel sets the *policy*; securities opinion is a blocking gate.

**Locked decisions (from the brief, restated so they are not re-litigated):**
- Identified-per-asset collateral, **not** a discretionary blind pool.
- Variable-yield pass-through, **not** a fixed-rate obligation.
- Do not represent the instruments as non-securities anywhere.

---

## 2. SYSTEM ARCHITECTURE

### 2.1 Layers
```
                          ┌─────────────────────────────────────────────┐
                          │        FRONTEND (Next.js + wagmi/viem)       │
                          │  landing · how-it-works · verticals ·        │
                          │  transparency dashboard · app · legal        │
                          └───────────────┬─────────────────────────────┘
                                          │ reads (multicall + indexer) / writes (simulated)
┌─────────────────────────────────────────┴─────────────────────────────────────────────┐
│                                    ON-CHAIN PROTOCOL                                     │
│                                                                                         │
│  TOKEN LAYER            COLLATERAL LAYER          CREDIT LAYER         LIQUIDITY LAYER   │
│  ┌──────────┐           ┌──────────────┐          ┌────────────┐       ┌──────────────┐  │
│  │  USDfr   │           │ ClaimBridge  │          │ Curator    │       │ Redemption   │  │
│  │ MintRedeem│◄────────►│ (Loan NFTs)  │◄────────►│ Module     │◄─────►│ Queue        │  │
│  │ Controller│           │ Collateral   │          │ Waterfall  │       └──────────────┘  │
│  │  sUSDfr   │           │ Registry     │          │ Engine     │                         │
│  │ Reserve   │           └──────┬───────┘          │ Default    │       GOVERNANCE        │
│  │ Manager   │                  │                  │ Manager    │       ┌──────────────┐  │
│  └──────────┘                   │                  └─────┬──────┘       │ GROVE/sGROVE │  │
│                                 │                        │              │ Timelock     │  │
│                          ┌──────▼────────────────────────▼──────┐       │ Guardian     │  │
│                          │        AttestationOracle             │       └──────────────┘  │
│                          │ (off-chain state → on-chain sync)    │                         │
│                          └──────────────────┬───────────────────┘                         │
└─────────────────────────────────────────────┼─────────────────────────────────────────────┘
                                              │ signed attestations at each material event
┌─────────────────────────────────────────────┴─────────────────────────────────────────────┐
│                              OFF-CHAIN LEGAL WRAPPER                                        │
│  SPV / Delaware Series LLC (per-vertical series) · UCC-1 liens · credit assignments ·       │
│  escrow · custody / bank accounts · insurance / value-wrap · UCC default remedies          │
│  (Forest Road counsel executes; the agent scopes only)                                     │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Core value flow (depositor)
1. Depositor mints `USDfr` 1:1 from stablecoin via `MintRedeemController` (KYC-gated). Backing invariant enforced: `USDfr` supply ≤ backing value at all times.
2. Depositor stakes `USDfr` → `sUSDfr` (ERC-4626 vault). Exchange rate = total assets / total shares.
3. As active loans pay interest and idle reserves earn T-bill yield, `ReserveManager`/`WaterfallEngine` credit the vault; the exchange rate rises. Depositor value accrues passively.
4. To exit, depositor requests redemption → enters the epoch FIFO queue → claims `USDfr` when the epoch fills → redeems `USDfr` → stablecoin.

### 2.3 Core value flow (borrower / origination)
1. Forest Road underwrites a facility in a vertical. Off-chain: execute assignment of the receivable, file UCC-1, fund escrow, verify credit-application/milestone status.
2. `AttestationOracle` records each material off-chain event on-chain.
3. When all off-chain + on-chain conditions hold, `ClaimBridge` mints the Loan NFT (position). Escrow releases *only* after the NFT exists.
4. Capital deploys from reserves to the facility; the NFT tracks principal, LTV, tier, maturity, and lifecycle state.
5. Repayments flow through `WaterfallEngine`: protocol fee, then every remaining interest unit to senior (`sUSDfr`). A curator first-loss *recovery* leg (returning a post-write-off recovery to the parties that absorbed the loss) is **deferred, not implemented on-chain** — see the ADR-0017 owner decision (2026-07-22): while Forest Road is the sole curator/SPV and holds the paper, recoveries to absorbed first-loss are handled OFF-CHAIN per the loan/SPV documents; the on-chain leg is a required build before a junior tranche or a third-party curator is added. On default, `DefaultManager` freezes the NFT, shifts to acceleration, and emits events triggering off-chain UCC remedies (assigned-receivable foreclosure / secondary-market credit sale / project foreclosure).

### 2.4 The synchronization contract (most important invariant)
On-chain and off-chain state must never silently diverge. Every material event (assignment executed, UCC-1 filed, credit issued, audit cleared, milestone hit, payment received, default declared) has: (a) an off-chain fact, (b) an authorized attestation on-chain, (c) a resulting state transition. The Loan NFT cannot mint, and escrow cannot release, without the required attestations. This is where RWA protocols carry their real risk — the trust model of the attestation layer must be explicit (ADR-0007).

---

## 3. ARCHITECTURE DECISION RECORDS (initial set)

Each ADR: decision · alternatives · rationale · status. Confirm/override before implementation.

**ADR-0001 — Identified-per-asset collateral (not blind pool).**
Decision: each deployed dollar maps to an identified, tokenized, lien-perfected position via `ClaimBridge`. Alternatives: discretionary blind pool; hybrid. Rationale: faithful to USD.AI; verifiable backing; cleaner transparency and regulatory posture; deployment control retained at underwriting level. Status: **Locked** (brief Part 4).

**ADR-0002 — Variable-yield pass-through (not fixed-rate).**
Decision: `sUSDfr` accrues actual book + reserve performance via ERC-4626 exchange rate. Alternatives: fixed-rate note; hybrid tranches. Rationale: depositor bears performance (less debt-obligation/issuer-credit characterization); faithful to USD.AI. Status: **Locked** (brief Part 4).

**ADR-0003 — Multi-collateral, all four classes at launch.**
Decision: `CollateralRegistry` parameterizes per-vertical classes; concentration limits across vertical/state/borrower. **All four classes (film tax credits, renewable energy, life sciences, real estate) go live at genesis** — none is a stub; per-class origination, attestation, and default-remedy paths are all built and tested before mainnet. Alternatives: single-class (film) v1 then add classes. Rationale: diversification across all four is the intended differentiator; Forest Road confirmed a full multi-vertical launch. Implication: heavier launch scope — budget for four complete class implementations. Status: **Resolved (Forest Road) — all four at launch.**

**ADR-0004 — Anchor curator + pluggable curators; $10M/class first-loss.**
Decision: Forest Road is the privileged anchor curator posting **$10,000,000 first-loss per class** (up to ~$40M across four classes at full deployment); module supports adding curators per class later. First-loss is a configurable per-class amount defaulting to $10M. Alternatives: open curator market from launch; single hardcoded curator. Rationale: vertical integration; strongest trust story; optionality preserved. Status: **Resolved (Forest Road) — $10M/class.**

**ADR-0005 — ERC-4626 for `sUSDfr`.**
Decision: implement `sUSDfr` as an ERC-4626 vault over `USDfr`; yield via exchange rate. Alternatives: bespoke rebasing token; reward-index token. Rationale: standard, composable, well-audited patterns, clean `convertToAssets` for the dashboard. Status: Proposed.

**ADR-0006 — Loan positions as ERC-721 NFTs.**
Decision: each facility is an ERC-721 with rich metadata + lifecycle state machine. Alternatives: ERC-1155; pure struct registry without NFTs. Rationale: faithful to CALIBER; per-position transferability/enforcement; clean on-chain register. Status: Proposed.

**ADR-0007 — Attestation trust model (resolved, buildable spec).**
Decision (build-ready, no gate): **authorized-attester model.** Off-chain legal facts cannot be trustlessly proven, so the protocol uses a defined set of authorized attesters posting signed attestations, with an explicit, documented trust boundary and a roadmap toward reduced trust. Specifics to build:
- **Attester set:** a role-gated allowlist (`ATTESTER` role) held initially by Forest Road operational keys and any designated third-party servicers/verifiers per class. Managed via `AccessControl` + timelock; changes emit events.
- **Signature scheme:** EIP-712 typed-data signatures over each attestation (kind, tokenId, payload, nonce, expiry); verified on-chain in `AttestationOracle.attest`. Support multiple authorized signers; optional **m-of-n threshold** per attestation kind (configurable — e.g., require 2 attesters for high-value events like `CreditIssued`/`Valuation`).
- **Attestation kinds:** `AssignmentExecuted`, `UCCFiled`, `CreditIssued`, `AuditCleared`, `MilestoneHit`, `PaymentReceived`, `DefaultDeclared`, `Valuation` (as in §4.9).
- **Trust boundary (document prominently in code, docs, and the risk page):** the protocol executes faithfully on whatever authorized attesters assert; if an attestation is false or an attester key is compromised, the on-chain protocol acts on false information. This is the protocol's primary trust assumption.
- **Reduced-trust roadmap:** move from single-attester → threshold multi-attester → independent verifier/oracle diversification → cryptographic proofs where feasible (e.g., proof of a filed UCC record) over time.
Alternatives: single oracle (weaker); fully trustless (infeasible for off-chain legal facts). Status: **Resolved (buildable) — no build gate.** Note: Forest Road's *conscious acceptance of this trust assumption* is a pre-mainnet ownership item (brief Part 11), not a build blocker — the build proceeds on testnet regardless.

**ADR-0008 — Upgradeability: UUPS proxies + timelock (resolved).**
Decision: **UUPS proxies**; upgrade authority behind a **timelock** controlled by governance (Forest-Road-controlled initially per ADR-0013); guardian pause on value-moving paths. Alternatives: transparent proxy (heavier storage/admin split); immutable (no fix path for a young protocol); diamond (over-complex for this scope). Rationale: UUPS is the lean current standard with well-audited OpenZeppelin support; timelock gives users exit time before any upgrade; guardian handles emergencies. Status: **Resolved — no build gate.**

**ADR-0009 — Chain: Ethereum L1.**
Decision: **Ethereum L1, single-chain at launch.** Alternatives: L2 (Arbitrum/Base); multi-chain. Rationale: deepest RWA/institutional-custody support and liquidity; no cross-chain messaging surface to secure in v1; matches an institutional credit product. Multi-chain/L2 is possible later expansion, not v1. Status: **Resolved (Forest Road).**

**ADR-0010 — Epoch FIFO redemption queue (QEV analog).**
Decision: `RedemptionQueue` with epoch cadence + FIFO; per-class parameters given mixed durations. Alternatives: instant redemption (impossible for illiquid book); auction/market-clearing (USD.AI's fuller QEV). Rationale: matches illiquid amortizing underlying; FIFO is simplest honest v1; can evolve toward market-clearing later. Status: Proposed.

**ADR-0011 — KYC/compliance gating; broad access at launch.**
Decision: whitelist-gated mint/redeem via a compliance module; transfer-restriction + jurisdiction-block *capability* on gated instruments. **Policy set to broad (not institutional-only) KYC-verified access** at launch; build hooks to support a broad allowlist. Permissionless holding/transfer where legally cleared. Alternatives: fully permissionless (regulatory risk); institutions-only. Rationale: Forest Road chose broader access; keep the compliance capability, set an inclusive policy. Exact eligibility rules confirmed with counsel. Status: **Resolved (Forest Road) — broad access; policy is counsel's.**

**ADR-0012 — Backing invariant enforcement.**
Decision: `MintRedeemController` enforces `USDfr` supply ≤ backing (stablecoin + reserve + deployed principal at conservative marks) as a hard invariant, fuzz-tested. Alternatives: soft/off-chain accounting. Rationale: the peg's integrity is foundational. Status: Proposed.

**ADR-0013 — Governance: Forest-Road-controlled at launch.**
Decision: full `GROVE`/`sGROVE` governance machinery is built and wired (proposals, voting, timelock), but **Forest Road holds effective control of parameters and upgrades at launch**; progressive decentralization is a later roadmap item, not a launch commitment. Alternatives: decentralized from launch; no on-chain governance. Rationale: young protocol carrying real credit benefits from a controlled operator initially; machinery exists so decentralization can follow. Docs must state this honestly (no implied decentralization that doesn't exist). Status: **Resolved (Forest Road) — controlled initially.**

**ADR-0014 — `sGROVE` backstop parameters.**
Decision: `sGROVE` is the second loss-absorption layer. **Loss order: curator first-loss ($10M/class) → `sGROVE` backstop → `sUSDfr` (depositor) principal.** Launch calibration (all governance-adjustable):
- **Target backstop size:** 10% of total deployed principal, protocol-wide (a target/floor governance steers toward, not a hard cap).
- **Initial seed:** ~$5M Forest Road contribution at launch, growing toward the 10% target as principal scales.
- **Unbonding:** 21 days for `sGROVE` → `GROVE` (prevents front-running a known loss).
- **Per-event coverage cap:** ≤ 50% of staked `sGROVE` drawn per shortfall event (preserves residual backstop across multiple events).
- **Rewards:** `sGROVE` stakers earn a governance-set share of protocol fees for bearing backstop risk (modest initial rate).
Alternatives: no backstop; unbounded slashing; different sizes. Rationale: conservative, standard-range values for a young protocol carrying real credit — a real but bounded backstop that protects depositors without over-promising, with cooldowns/caps that prevent gaming. Confirm against Forest Road per-vertical loss history in the economic review (brief Part 11 gate 5). Status: **Resolved (proposed calibration) — confirm numbers in economic review.**

---

## 4. CONTRACT INTERFACE SPECS (proposed — implement after review)

Illustrative signatures; names/params to be finalized in implementation. All external/public functions get NatSpec. All privileged functions gated by `AccessControl` roles. All state transitions emit events (register must be event-reconstructable).

### 4.1 `USDfr` (ERC-20)
```solidity
interface IUSDfr is IERC20 {
    function mint(address to, uint256 amount) external;      // onlyMintController
    function burn(address from, uint256 amount) external;    // onlyMintController
    // compliance hooks (policy set by governance/counsel)
    function isTransferAllowed(address from, address to, uint256 amount) external view returns (bool);
    event ComplianceModuleUpdated(address indexed module);
}
```

### 4.2 `MintRedeemController`
```solidity
interface IMintRedeemController {
    function mint(uint256 stableAmount) external returns (uint256 usdfrOut);   // KYC-gated; 1:1
    function redeem(uint256 usdfrAmount) external returns (uint256 stableOut);
    function backingValue() external view returns (uint256);                   // for invariant + dashboard
    function totalUSDfr() external view returns (uint256);
    // INVARIANT (enforced + fuzzed): totalUSDfr() <= backingValue()
    event Minted(address indexed user, uint256 stableIn, uint256 usdfrOut);
    event Redeemed(address indexed user, uint256 usdfrIn, uint256 stableOut);
}
```

### 4.3 `sUSDfr` (ERC-4626 vault over `USDfr`)
```solidity
interface IsUSDfr is IERC4626 {
    // deposit()/mint()/convertToAssets()/totalAssets() from ERC-4626
    // redemption routed through the queue rather than instant:
    function requestRedeem(uint256 shares) external returns (uint256 requestId);
    function claim(uint256 requestId) external returns (uint256 assetsOut);    // when epoch fills
    function currentExchangeRate() external view returns (uint256);            // convertToAssets(1e18)
    event RedemptionRequested(address indexed user, uint256 requestId, uint256 shares, uint256 epoch);
    event RedemptionClaimed(address indexed user, uint256 requestId, uint256 assetsOut);
}
```

### 4.4 `ClaimBridge` (ERC-721 Loan/Receivable NFTs)
```solidity
enum LoanState { Pending, Active, Amortizing, Repaid, Defaulted, Accelerated }

struct Facility {
    uint256 classId;            // collateral class / vertical
    uint256 principal;
    uint16  ltvBps;
    uint16  interestTierBps;    // contractual annual rate supplied and signed per facility
    uint64  maturity;
    uint256 dsraBalance;        // legacy field only; ADR-0028 retired new DSRA funding
    bytes32 offchainRef;        // UCC filing / SPV-series / escrow reference (hash or id)
    LoanState state;
    bytes32 attestationRoot;    // required attestations satisfied
}

interface IClaimBridge is IERC721 {
    // mints ONLY if all required attestations present AND on-chain conditions met
    function originate(Facility calldata f, uint256[] calldata requiredAttestationIds)
        external returns (uint256 tokenId);                 // onlyOriginator; escrow release gated on this
    function facility(uint256 tokenId) external view returns (Facility memory);
    function transitionState(uint256 tokenId, LoanState to) external;   // guarded state machine
    function recordRepayment(uint256 tokenId, uint256 amount) external; // -> WaterfallEngine
    event Originated(uint256 indexed tokenId, uint256 indexed classId, uint256 principal);
    event StateChanged(uint256 indexed tokenId, LoanState from, LoanState to);
    event RepaymentRecorded(uint256 indexed tokenId, uint256 amount);
}
```

### 4.5 `CollateralRegistry`
```solidity
struct ClassParams {
    string  name;               // e.g. "Film Tax Credit"
    uint16  maxLtvBps;
    uint16  interestTierBps;    // legacy storage/config field; not pricing authority
    uint16  dsraMonths;         // retained layout field; zero for every launch class
    uint64  maxMaturity;
    uint256 concentrationLimitBps;   // max % of book in this class
    bool    active;
}
interface ICollateralRegistry {
    function setClass(uint256 classId, ClassParams calldata p) external;   // onlyGovernance (timelocked)
    function classParams(uint256 classId) external view returns (ClassParams memory);
    function checkConcentration(uint256 classId, uint256 addPrincipal) external view returns (bool);
    event ClassUpdated(uint256 indexed classId);
}
```

### 4.6 `CuratorModule`
```solidity
interface ICuratorModule {
    function postFirstLoss(uint256 classId, uint256 amount) external;         // curator stakes junior capital
    function withdrawFirstLoss(uint256 classId, uint256 amount) external;     // subject to headroom
    function firstLossOf(uint256 classId) external view returns (uint256 posted, uint256 headroom);
    function absorbLoss(uint256 classId, uint256 loss) external returns (uint256 absorbed, uint256 residual);
    // LOSS CASCADE (three layers): curator first-loss ($10M/class) absorbs first; any `residual`
    // escalates to the sGROVE backstop (Governance.coverShortfall); only loss beyond BOTH
    // impairs sUSDfr (depositor) principal. Enforce and fuzz this ordering.
    event FirstLossPosted(address indexed curator, uint256 indexed classId, uint256 amount);
    event LossAbsorbed(uint256 indexed classId, uint256 absorbed, uint256 residual);
}
```

### 4.7 `WaterfallEngine`
```solidity
interface IWaterfallEngine {
    // routes a repayment: senior (sUSDfr) first, then curator first-loss recovery
    function distribute(uint256 tokenId, uint256 amount) external;
    // INVARIANT (fuzzed): sum(distributed) == amount; senior never subordinated to junior
    event Distributed(uint256 indexed tokenId, uint256 toSenior, uint256 toCurator);
}
```

### 4.8 `ReserveManager`
```solidity
interface IReserveManager {
    function idleReserve() external view returns (uint256);        // T-bill / short-term
    function deployedPrincipal() external view returns (uint256);
    function dsraOf(uint256 tokenId) external view returns (uint256); // legacy migration only
    function fundDSRA(uint256 tokenId, uint256 amount) external;      // retained ABI; not in new waterfall
    event ReserveDeployed(uint256 indexed tokenId, uint256 amount);
    event DSRAFunded(uint256 indexed tokenId, uint256 amount);
}
```

### 4.9 `AttestationOracle`
```solidity
enum AttestationKind { AssignmentExecuted, UCCFiled, CreditIssued, AuditCleared, MilestoneHit, PaymentReceived, DefaultDeclared, Valuation }

interface IAttestationOracle {
    function attest(uint256 tokenId, AttestationKind kind, bytes calldata data, bytes calldata sig) external; // onlyAttester
    function isSatisfied(uint256 tokenId, uint256 requiredId) external view returns (bool);
    function latestValuation(uint256 tokenId) external view returns (uint256 value, uint64 asOf);
    event Attested(uint256 indexed tokenId, AttestationKind kind, address indexed attester, uint64 at);
    // TRUST NOTE: this is the protocol's primary trust assumption. Document the attester set,
    // signature scheme, and reduced-trust roadmap prominently (ADR-0007).
}
```

### 4.10 `DefaultManager`
```solidity
interface IDefaultManager {
    function declareDefault(uint256 tokenId) external;   // freezes NFT, shifts waterfall to acceleration
    function remedyPath(uint256 tokenId) external view returns (bytes32);  // per-class off-chain remedy ref
    event DefaultDeclared(uint256 indexed tokenId, uint256 indexed classId);
    event RemedyInitiated(uint256 indexed tokenId, bytes32 remedyRef);  // triggers off-chain UCC action
}
```

### 4.11 `Governance` (`GROVE` / `sGROVE`)
```solidity
interface IGovernance {
    function propose(bytes calldata action) external returns (uint256 proposalId);
    function vote(uint256 proposalId, bool support) external;             // GROVE-weighted
    function queue(uint256 proposalId) external;                          // into timelock
    function execute(uint256 proposalId) external;                        // after timelock
    function stakeForBackstop(uint256 amount) external;                   // GROVE -> sGROVE
    function coverShortfall(uint256 amount) external returns (uint256 covered);  // sGROVE backstop
    event ProposalCreated(uint256 indexed id);
    event ShortfallCovered(uint256 amount, uint256 covered);
}
```

### 4.12 Cross-cutting
- `AccessControl` roles: `MINT_CONTROLLER`, `ORIGINATOR`, `ATTESTER`, `CURATOR`, `GOVERNANCE`, `GUARDIAN`, `UPGRADER`.
- `Guardian`: `pause()`/`unpause()` on value-moving paths.
- Reentrancy guards on all value-moving functions; checks-effects-interactions throughout.
- System invariants to encode + fuzz: backing ≥ supply; waterfall conserves value; first-loss subordination never inverts; NFT cannot mint without required attestations; queue never over-distributes; concentration limits hold.

---

## 5. BUILD PROCEEDS GATE-FREE; PRE-MAINNET OWNERSHIP ITEMS ONLY

All launch and technical decisions are resolved. **There are no human sign-offs required before or during the build** — Fable proceeds directly from this document into implementation (module by module, per `FABLE_BUILD_BRIEF.md` Part 7, each with unit → integration → invariant tests). Resolved: chain (Ethereum L1); all four verticals at launch; $10M/class first-loss; broad KYC-gated access; Forest-Road-controlled governance; `sGROVE` backstop (ADR-0014); UUPS proxies (ADR-0008); attestation model (ADR-0007, buildable spec); interface economics (Section 4, settled — three-layer loss cascade, waterfall subordination, per-class first-loss).

The following are **pre-mainnet ownership items, not build blockers** — they do not touch Fable's path (the build runs on testnet) and sit in `FABLE_BUILD_BRIEF.md` Part 11 alongside audit and legal. They are the checks that must clear before real capital and real legal claims go live, regardless of code quality:
- **Forest Road consciously accepts the attestation trust assumption** (ADR-0007) before mainnet — a business/risk decision, not an engineering one.
- **Securities counsel opinion**, **external smart-contract audit(s)**, **executed off-chain legal wrapper** (SPV/liens/escrow live), and **economic review** of parameters (including the ADR-0014 backstop numbers) against Forest Road's per-vertical loss history.

Implementation begins immediately, module by module, with the review discipline (tests + invariants per module) built into the process rather than gated on external sign-off.

---

*End of Phase A draft. This document, the brief, and the eventual ADR/ directory are the governing artifacts. If any later instruction conflicts with the locked decisions or the regulatory posture (brief Part 0.5), STOP and flag rather than proceed.*
