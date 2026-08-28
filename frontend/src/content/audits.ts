/**
 * Registry of published security reviews.
 *
 * Each round is its own report page at /docs/audit/<slug>, with its own findings list and
 * its own remediation history. Narrative prose lives in ./docs/audits/*.md; the findings
 * themselves are typed data here so the register, the severity counts, and the per-report
 * pages all read from one source and cannot drift apart.
 *
 * Finding IDs are namespaced per round on purpose, `H-01` in Round 1 and `H-1` in the
 * pre-mainnet campaign are different findings, and the two are easy to confuse.
 *
 * Dispositions are stated only where a report or a later round states them. "Accepted" is
 * never a synonym for "fixed"; where a finding was accepted rather than remediated, the
 * note records the prerequisite that makes it tolerable.
 */

export type Severity = "High" | "Medium" | "Low" | "Informational";

export type Disposition =
  | "Remediated"
  | "Accepted"
  | "Deferred"
  | "By design"
  | "Open"
  | "Superseded";

/**
 * Forest Road's own severity for a finding as deployed, where it differs from the
 * auditor's.
 *
 * The auditor's `severity` is never overwritten. The published report says what it says,
 * and a register that quietly restates an external rating downward is worth less than one
 * that shows both and argues the difference. `why` must name the *measured deployed-state
 * fact* that lowers it, not a judgement that the finding is unlikely, and `until` must name
 * the change that puts it back. A downgrade whose `until` condition is unobservable is not
 * a downgrade: it is an opinion.
 */
export type AssessedSeverity = {
  severity: Severity;
  /** The measured on-chain fact that lowers it, with the measurement. */
  why: string;
  /** The observable change that restores the auditor's rating. */
  until: string;
};

export type AuditFinding = {
  id: string;
  severity: Severity;
  title: string;
  disposition: Disposition;
  /** What actually happened to it, and the evidence for that claim. */
  note: string;
  /** Forest Road's deployed-state rating, where it differs from the auditor's. */
  assessed?: AssessedSeverity;
};

export type AuditReport = {
  slug: string;
  /** Markdown narrative, relative to src/content/docs. */
  file: string;
  title: string;
  eyebrow: string;
  /** ISO date, used for ordering. */
  date: string;
  dateLabel: string;
  /**
   * True where the review was conducted by a party other than Forest Road. Controls the
   * provenance banner on the report page: every other round is an internal engineering
   * review and must say so, and labelling an external review "internal" is as much a
   * misstatement as the reverse. Scope limits belong in `method`, not here.
   */
  external?: boolean;
  scope: string;
  method: string;
  baseline?: string;
  /** Card summary on the register. */
  summary: string;
  findings: AuditFinding[];
  /**
   * Internal archive path, cited rather than linked, these reports are not published.
   * Superseded working documents: this register, not the archive, is the authoritative
   * record. Cite the path so a reviewer can request the document by name.
   */
  archive?: string;
};

/** Newest first. This is the order the register renders. */
export const AUDITS: AuditReport[] = [
  {
    slug: "2026-08-27-cantina-managed-review",
    file: "audits/2026-08-27-cantina-managed-review.md",
    title: "Cantina Managed review of the supply gateway",
    eyebrow: "External review",
    date: "2026-08-27",
    dateLabel: "27 August 2026",
    external: true,
    baseline: "71c285ec",
    scope:
      "DELIBERATELY NARROW, and the scope matters more than the result: TWO FILES ONLY, contracts/src/MintRedeemController.sol and contracts/src/libraries/Roles.sol. That is the USDfr supply gateway and the role constants. It is NOT a review of the vault, queue, waterfall, cascade, oracle, bridge, curator module or governance. A clean result across two files is not a clean result across the protocol, and anyone citing this report should cite its scope in the same sentence.",
    method:
      "Commercial engagement with Cantina Managed, conducted 17-20 August 2026 by Valerian Callens (Lead Security Researcher) and Jiri123 (Security Researcher). The first review of this protocol by a NAMED EXTERNAL SECURITY FIRM and the first by human researchers under a commercial engagement; every earlier round on this register was internal or AI-assisted. Cantina's own disclaimer records that the assessment is bound to the specific commit reviewed and is not a replacement for continuous security measures.",
    summary:
      "Five findings, ALL INFORMATIONAL. No Critical, High, Medium or Low. One fixed, four acknowledged. The Cantina Managed team statement reads: 'No significant issues were identified during the assessment, and the protocol is expected to operate as intended.' READ THE SCOPE FIRST: two files, not the protocol. The fixed finding is the missing deadline on the two-argument redeem, which ADR-0034 W required and which is a free option for a searcher who holds the transaction until the ratio decays to the caller's floor; the remedy was documentary, recording which form is canonical and pointing integrators at the three-argument form. The four open ones are an overflow panic on a max-sized redemption input reachable only when under-backed, immutable module wiring that would need an upgrade to correct and is already covered by post-deploy manifest validation, a previewRedeem that omits the ReserveManager pause and so can quote a price no redemption would settle, and direct redemption not consuming the ADR-0033 exit interlock. That last one is the substantive one: the state that leaves par reachable is an ACTIVE RESERVE-LOSS ARM BEFORE ANY PHYSICAL SHORTFALL, accepted as a known limitation of mainnet v1. The report's trust-assumption section is the more useful read and states plainly that attesters are the primary trust boundary for off-chain facts: that the protocol cannot independently verify an attested event once the oracle accepts the signatures, and that SENIOR CAPITAL IS IMPAIRABLE with prevention of every senior loss NOT a protocol invariant. This review does not supersede the mainnet-v1 full audit of 16 August, whose open DV findings remain the substantive picture. The full report is published at github.com/Forest-Road-Company/forest-road-vault under audit-reports/.",
    findings: [
      {
        id: "3.1.5",
        severity: "Informational",
        title: "redeem(uint256, uint256) has no deadline, contradicting ADR-0034 W",
        disposition: "Remediated",
        note:
          "ADR-0034 W requires the redeem functions to take both a minimum out and a deadline. The one-argument form supplies the par floor internally so it settles at par or reverts and delay cannot make it worse. The two-argument form bounds price but NOT TIME, which is the free option W describes: a caller who names a floor and is not included for an hour lets a searcher hold the transaction until the ratio decays to that floor. Cantina's recommendation was documentary rather than a code change - amend W to record which form is canonical and point integrators at the three-argument form - and that is what was done, in commit ab844dc.",
      },
      {
        id: "3.1.4",
        severity: "Informational",
        title: "Direct redemption does not consume the ADR-0033 exit interlock",
        disposition: "Accepted",
        note:
          "THE SUBSTANTIVE ONE OF THE FIVE. ADR-0033 section 5 states that junior and senior exits share one interlock so neither cohort can escape while the other stays exposed. CuratorModule.withdrawFirstLoss and RedemptionQueue.closeEpoch both read reserveLossExitsLocked; MintRedeemController._redeem does not, so direct redemption stays open while both other exits are shut. Most locked states are already covered elsewhere, since an under-backed book and a latched deficit both price sub par and a live shortfall reverts in _requireCustodiedReserve. THE STATE THAT LEAVES PAR REACHABLE IS AN ACTIVE RESERVE-LOSS ARM BEFORE ANY PHYSICAL SHORTFALL. Cantina also noted the RedemptionQueue comment calling the queue the sole senior exit, which is what section 5 was written against. Accepted as a known limitation of mainnet v1, not remediated in this release.",
      },
      {
        id: "3.1.3",
        severity: "Informational",
        title: "previewRedeem() can publish a redeem price that would not settle",
        disposition: "Accepted",
        note:
          "previewRedeem is meant to publish the executable redemption price but uses checks not aligned with redeem(). It verifies that USDfr and the controller are unpaused but NOT the ReserveManager, so it can return a full quote while releaseUSDC is blocked and every redemption reverts. It also passes a zero draw into _quoteRedeem, so below par it publishes the gross marked price while redeem() settles at the junior drawn price. A quoting defect rather than a settlement one, and no funds are at risk, but an integrator surfacing this number to users would show a price that cannot be obtained.",
      },
      {
        id: "3.1.1",
        severity: "Informational",
        title: "Oversized redemption input panics before balance validation",
        disposition: "Accepted",
        note:
          "_quoteRedeem calculates usdfrIn + drawn before checking the caller's USDfr balance, so a max-sized input with a nonzero draw overflows and reverts with a panic instead of returning the intended token or controller error. Reachable only on the under-backed path. No funds are at risk because no caller can hold or burn such an amount; the cost is a confusing failure mode rather than a loss.",
      },
      {
        id: "3.1.2",
        severity: "Informational",
        title: "Invalid immutable module wiring requires an upgrade to recover",
        disposition: "Accepted",
        note:
          "initialize() checks only that the usdfr, compliance and reserves addresses are nonzero. A wrong or codeless address would leave the controller unusable and the wiring could not be corrected without an upgrade. Limited to deployment misconfiguration, and the recommended validation is already in place: post-deploy checks assert controller.modules() against the hash-bound deployment manifest and confirm code through the ERC-1967 implementation slot. The wiring is kept immutable deliberately; the residual is a deployment-time risk already mitigated by process.",
      },
    ],
  },
  {
    slug: "2026-08-16-mainnet-v1-full-audit",
    file: "audits/2026-08-16-mainnet-v1-full-audit.md",
    title: "Full audit of the live mainnet deployment",
    eyebrow: "External review",
    date: "2026-08-16",
    dateLabel: "16 August 2026",
    external: true,
    baseline:
      "f1f1f47, freeze tag mainnet-v1-production-freeze-2026-08-16, deployed to Ethereum mainnet at block 25,768,251",
    scope:
      "contracts/src as deployed, 49 files, 18,244 lines, driven against the LIVE Ethereum mainnet addresses rather than against source or a testnet. solc 0.8.30 (runs 100), Slither 0.11.6. The first review of this protocol conducted against a live mainnet deployment.",
    method:
      "Fork-reproduced and adversarially cross-examined. A harness binds to the live mainnet addresses and drives the deployed contracts from genesis through mint, deposit, origination, funding, default and settlement, so every code finding is a passing Foundry test against PRODUCTION BYTECODE rather than a source argument. Four independent reviewers read all 23 contracts in full under four distinct adversarial lenses, economic sequencing, cross-contract invariants, accounting and state machines, and authority and voting. Every surviving candidate was re-examined by a skeptic instructed to refute it. The engagement lead independently traced every value-moving path. EXPLICITLY NOT RUN, per the report: coverage-guided fuzzing, symbolic execution or formal proof, model qualification benchmarking, and live-fire governance rehearsal beyond the fork. AI-assisted, and explicitly NOT a maximum-assurance audit.",
    summary:
      "Supersedes the same-day deployment audit, which declared two gaps, no fork reproduction, so no finding could reach confirmed, and no independent adversarial cross-examination, and closes both. Three Medium and five Low code findings, all reproduced or verified against deployed bytecode, plus the deployment-configuration and disclosure findings carried forward. One candidate was refuted outright and one de-escalated Medium to Low; register entry F-01 was corrected DOWNWARD after its stated exploit path was found no longer to reproduce. THE FINDINGS ARE NOT FUND-THEFT-BY-ANYONE: the three Mediums are two privileged-operator liveness traps and one launch-sequencing gap, and no user funds are at risk at the current seed state. Two matter most to anyone integrating. DV-03 records that both junior cascade layers are EMPTY ON CHAIN TODAY, so a declared default drives full principal onto seniors with nothing in front of it. DV-01 produces an UPWARD discontinuity in the exit price, which any consumer recording a high-water exchange rate must understand before integrating. The full report is published at github.com/Forest-Road-Company/forest-road-vault under audit-reports/.",
    findings: [
      {
        id: "DV-01",
        severity: "Medium",
        assessed: {
          severity: "Low",
          why:
            "Measured on mainnet 2026-08-28: the DefaultManager has emitted ZERO DefaultDeclared events since deployment at block 25768251, so the CommitmentLedger walk the probe must outrun is empty. Corrovera measured the 200,000-gas crossing at 46 declared defaults against WARM storage and noted the production cold-storage figure is strictly lower. Nothing is near it, and the whole mechanism needs a good-faith operator to then call clearUnreadableImpairmentSource on a source the diagnostic has mislabelled. The finding is correct and unfixed; it is simply out of reach at this book size.",
          until:
            "Re-measure the probe against live cold-storage cost BEFORE the live declared-default count reaches 20, and restore Medium at that point unless the measurement clears it. Twenty rather than forty-six because the project's own W7_PerEventLadder test already shows 32 events exceeding a 400,000-gas stipend under an active assessment, which is double the recovery probe's budget, so the real cliff is well below the warm figure.",
        },
        title:
          "A fixed-gas recovery probe misreads a healthy impairment source as broken, and the fix drops the senior mark to par",
        disposition: "Open",
        note:
          "Reproduced against live bytecode. The vault prices every senior exit at totalAssets minus pendingSeniorImpairment, read through a walk over every live default event that nothing bounds. The emergency recovery lever gates on a FIXED 200,000-gas probe and treats an out-of-gas result as proof the source is broken, while ordinary reads of the same source are uncapped. Past roughly 46 declared defaults the probe fails on a perfectly healthy source, so a good-faith operator diagnostic reports it broken, clearUnreadableImpairmentSource fires: the conservative mark leaves exit pricing entirely, and the high-water mark ratchets IRREVERSIBLY. In the reproduction a genuine $2.3M impairment vanishes and the exit price jumps from 17,700,100e18 to par at 20,000,100e18. NOT ATTACKER-REACHABLE, but reachable by ordinary operation plus a good-faith governance action, which is why it is not rated lower. The measurement is against warm storage; the production probe runs against cold storage and is strictly more expensive, so the real threshold is LOWER than 46. This falsifies the premise of the earlier FEE-09 acceptance, which rested on the true mark being unreadable at that moment. Recommendation: bound the ledger walk or restore an O(1) aggregate, and make the recovery probe scale with gasleft() the way the install gate already does, so 'unreadable' means actually unreadable rather than merely heavy. At minimum, never let the clear fire while an uncapped read of the same source succeeds in the same transaction. MATERIAL TO ANY INTEGRATOR RECORDING A HIGH-WATER EXCHANGE RATE: the discontinuity is upward, so a watermark can be set at a phantom level the true rate never returns to.",
      },
      {
        id: "DV-02",
        severity: "Medium",
        assessed: {
          severity: "Low",
          why:
            "Measured on mainnet 2026-08-28 over the full history from block 25768251: the ReserveManager has emitted ZERO ReserveLossIncidentOpened, ZERO ReserveLossIncidentClosed, ZERO ReserveLossArmed and ZERO ReserveLossArmCancelled events. Neither trigger has ever fired. Both require a privileged caller to use the DEPRECATED legacy incident pair, which production operation has no reason to touch because ratifyAndOpen is the live write-down path, and no outside party can reach either. The stranded state also remains recoverable through a UUPS upgrade under a functioning governor.",
          until:
            "Restore Medium if openReserveLossIncident or closeReserveLossIncident is ever called on mainnet, or if the deprecated pair is still present on the deployed surface after the next ReserveManager upgrade. This downgrade rests on an operational rule rather than on code, so it holds only while the rule does.",
        },
        title:
          "A shared, never-cleared incident-id namespace strands the reserve-loss arm and blocks custody-loss absorption",
        disposition: "Open",
        note:
          "Reproduced against live bytecode; finder and refuter agree. The modern arm/ratify/finalize path and the legacy open/close incident pair mint incident ids from the SAME function, and the used-marker is write-once and cleared nowhere in src. Two privileged-reachable consequences follow. Mis-closing an arm-bound incident orphans the arm, the close checks only id identity, carries no arm-awareness and, despite the interface declaring a deficit error and the NatSpec promising one, no deficit guard, after which finalize reverts NoActiveIncident and ratify reverts IncidentAlreadyUsed, so the arm can never be cancelled. And opening plus closing a small legacy nonce PROSPECTIVELY BURNS the id that a future arm will compute. Because ratifyAndOpen is the sole production write-down path and the arm machine is single-threaded: a genuine custody loss can then no longer be absorbed through the cascade at all: the reproduction prints 'the only on-chain custody-loss absorption path is stranded'. The refuter confirmed recapitalize cannot cure it. The only escapes are an out-of-band USDC donation, which shifts the loss onto the donor rather than the intended waterfall, or a UUPS upgrade. A DEFECT INTRODUCED BY THE C-01 REMEDIATION: the arm/incident state machine postdates the entire register and no existing entry touches it. Recommendation: separate the legacy nonce namespace from the arm namespace, add the documented deficit guard, and make the close refuse an arm-bound incident, or, since the path is deprecated, remove the legacy pair from the deployed surface entirely.",
      },
      {
        id: "DV-03",
        severity: "Medium",
        title:
          "Origination and funding require no first-loss capital, and both cascade layers are empty at launch",
        disposition: "Remediated",
        note:
          "Reproduced against live bytecode. The protocol advertises a three-layer loss cascade, curator first-loss, then the sGROVE backstop, then senior principal, but the first two layers are ENFORCED AT NEITHER ORIGINATION NOR FUNDING. The curator required-first-loss and headroom figures bound only a curator's own withdrawal and are referenced nowhere in the claim bridge or the waterfall's fund path; nothing in origination or funding reads curator capital at all. Live state confirms both layers are empty today: all five curator pool balances are zero, sGROVE coverage capacity is zero, and impairment backstop capacity is zero, while the anchor curator is approved on all five classes with nothing posted. In the reproduction a $2M class-2 facility originates and funds with the cascade empty, and a declared default drives the FULL principal onto seniors, pending senior impairment of 2,000,000e18 entirely unabsorbed, redemption assets falling from 10,000,100e18 to 8,000,100e18. THIS UNSETTLES AN ACCEPTED FINDING: register entry F-01 was accepted on the premise that the curator's first-loss capital is consumed before any senior loss. That capital does not exist in the deployed state and will not until the anchor curator posts. Recommendation: make first-loss and backstop funding a hard capped-launch acceptance gate before the first origination and before any user deposit path opens, or gate the fund path on posted balance meeting required first loss. THE SINGLE MOST IMPORTANT FINDING FOR ANY PARTY ROUTING CAPITAL INTO THE SENIOR TRANCHE. REMEDIATED 2026-08-28, layer one only: the curator first-loss layer is FUNDED ON CHAIN. poolBalance(2) reads 100000000000000000000 against a requiredFirstLoss(2) of the same, posted by the anchor curator Safe 0x02C76084…9066 and attributed to it, so the stake is withdrawable only under that Safe's 2-of-4 threshold rather than by any single key -- noting that the deployment-audit finding carried forward on this register, four Safes sharing one 2-of-4 owner set, applies to this Safe too, so the protection is only as strong as that owner set. FirstLossPosted at block 25853905, tx 0x7942c5fe4edde8c3f0e65aa4e760a56ad8b6807967e20841a03f0af291538415, amount and shares both 100e18, round 0. Supply and backing were unchanged at 502e18 across the operation and the backing invariant held throughout; the capital was transferred from an existing Forest Road holding rather than newly minted, which satisfies the requirement without adding new capital and is stated here so the record is not read as more than it is. Rehearsed against pinned mainnet state before broadcast (contracts/test/fork/DV03FirstLossRehearsal.t.sol). STILL OPEN, AND THE REASON THIS IS NOT FULLY CLOSED: the sGROVE backstop, cascade layer TWO, REMAINS EMPTY, coverageCapacity and impairmentBackstopCapacity are both zero. A loss larger than 100e18 on class 2 still reaches senior principal with only one layer in front of it, and origination and funding still consult NEITHER layer, so nothing prevents a future facility outgrowing the posted first loss. FOREST ROAD POSITION: this one was FIXED rather than re-rated, because the remedy was operational and needed no contract change, and because unlike DV-01 and DV-02 its precondition was not a remote state but the live one. It is deliberately given no lowered Forest Road severity for that reason.",
      },
      {
        id: "DV-04",
        severity: "Low",
        title:
          "The points-hook gas-floor hardening reached only two of five fail-open hooks",
        disposition: "Open",
        note:
          "Reproduced against live bytecode. The F-18-02 hardening put an enforceable absolute gas floor on the USDfr and sUSDfr transfer hooks, but the terminal curator-stake hook is still caller-gas-starvable and emits NO failure telemetry. A curator can therefore withdraw first-loss capital while the points ledger keeps accruing on capital that is no longer posted, and nothing observable records that the transition was dropped. Repairable through the points module's reconcile path once noticed; the defect is that nothing announces it needs noticing.",
      },
      {
        id: "DV-05",
        severity: "Low",
        title:
          "A precautionary reserve-loss arm freezes the senior redemption queue, and its cancel gate is global solvency rather than custody health",
        disposition: "Open",
        note:
          "Reproduced against live bytecode. A guardian's precautionary arm freezes senior exits, and the gate that would cancel the arm tests global solvency rather than the custody health the arm was raised about. DE-ESCALATED FROM THE REVIEWER'S MEDIUM: the refuter proved the wedge state coincides with states that freeze exits anyway, so the arm adds no incremental harm. Recorded rather than dismissed because the cancel gate testing the wrong quantity is real, and would matter if the coincidence ever stopped holding.",
      },
      {
        id: "DV-06",
        severity: "Low",
        title: "The cascade's order-conservatism guard is provably vacuous",
        disposition: "Open",
        note:
          "Verified from source. The min(forward, reverse) guard that is supposed to preserve order-conservatism in the loss cascade is provably vacuous, forward equals reverse for every book, yet an O(N) release shift and a redundant walk are paid to preserve it, and the NatSpec documents a margin that does not exist. No incorrect accounting results; the cost and the false documentation are the finding.",
      },
      {
        id: "DV-07",
        severity: "Low",
        title:
          "Queue settlement sizes yield recognition against the liquidity budget rather than the actual outflow",
        disposition: "Open",
        note:
          "Verified from source. Settlement recognises yield against the treasury liquidity budget rather than the settlement's actual outflow, transferring a sliver of unvested yield from holders who stay to holders who leave. INERT AT THE LAUNCH CONFIGURATION, where the yield vesting period is zero and there is no unvested stream to transfer; live only if governance enables vesting. Recorded so that enabling vesting is understood to activate it.",
      },
      {
        id: "DV-08",
        severity: "Low",
        title:
          "The RC-01 anti-latch guard documents an invariant that is false",
        disposition: "Open",
        note:
          "Verified from source. The guard's NatSpec states that distributed plus budget is pinned to the opening snapshot; the H-04 live-cap clamp breaks that. The code is safe only because it re-evaluates per chunk. The hazard is prospective and specific: a future reviewer who trusts the comment and hoists the check out of the loop reinstates the RC-01 dead-end. A false comment on a load-bearing guard, rather than a live defect.",
      },
    ],
  },
  {
    slug: "2026-08-04-corrovera-review",
    file: "audits/2026-08-04-corrovera-review.md",
    title: "External review by Corrovera Security",
    eyebrow: "External review",
    date: "2026-08-04",
    dateLabel: "4 August 2026",
    external: true,
    baseline: "d2ef15a5, contracts/src byte-identical at b5245398",
    scope:
      "The whole protocol as it stood on 4 August 2026: 37 Solidity files, 10,502 lines of contracts/src, byte-identical to the contracts/src tree at b5245398 ON THAT DATE. The source has since grown to 49 files and has NOT been re-reviewed by Corrovera; treat this review as scoped to the 4 August tree, not to current source. First review of this protocol conducted by a party other than Forest Road.",
    method:
      "Corrovera's AI-assisted security review tier: their deterministic Solidity analysis, Slither over the full compiled project, the project's own Foundry suite, and whole-protocol review by five independent model lineages under two specialist lenses, economic sequencing, and cross-contract invariant conservation, with the project's 36-entry findings register supplied as an exclusion list so a rediscovery could not be reported as a discovery. The surviving candidate was put to four further lineages instructed to refute it, and every load-bearing claim was validated against source by the reviewing engineer. Explicitly not run, per the report: model qualification benchmarking, generated fork reproduction, coverage-guided fuzzing, symbolic execution or formal verification, and a deterministic consensus pipeline, adjudication was by one engineer.",
    summary:
      "Two new Medium findings and one challenge to an existing risk acceptance, all outside the 36 register entries supplied as exclusions. One lineage produced three candidates and the other four produced none; the strongest survived refutation by three independent reviewers, all of whom rated it High, and was rated down to Medium by the reviewing engineer on reachability grounds after Forest Road raised the 21-day request-anchored redemption cooldown. F-01 gates third-party curator onboarding rather than describing present exposure. F-02 requires no misconduct at all, which raises its likelihood rather than lowering it. NO FINDING REACHED CONFIRMED, fork reproduction was not part of the engagement, no property was formally proven, and no fuzzing beyond the project's own suite was run. The report states plainly that a clean section is evidence these methods at this depth found nothing there, and is not evidence of security. Open C-01 was confirmed still open. All 38 in-scope Slither Mediums were individually adjudicated and dismissed with reasons; one outside candidate was self-refuted by the reporting model during its own verification.",
    archive: "audit-reports/corrovera-ai-assisted-review-20260804.md",
    findings: [
      {
        id: "F-01",
        severity: "Medium",
        title:
          "A curator can inflate the price its own queued redemption settles at, by posting and withdrawing first-loss capital around the settlement",
        disposition: "Accepted",
        note:
          "Pending senior impairment nets a class's at-risk principal against a LIVE, UN-SNAPSHOTTED read of the curator's first-loss pool, and that residual flows into the conservative asset figure that prices queued exits at settlement. Separately and deliberately: a past-due mark does not freeze curator withdrawals: that omission is what removed the permissionless-griefing surface in the H-5 redesign, and reversing it would reintroduce that surface. Each decision is individually sound; together they permit an approved curator who also holds senior tokens to raise the pool balance, settle their own eligible queued request against the improved price, and withdraw the capital again, with the impairment snapping back afterwards. Both the past-due trigger and the epoch settlement are permissionless, so the actor controls the timing of both. RATED MEDIUM on reachability, not on mechanism: three independent refuting reviewers all rated it High and all said the mechanism survives, and the reviewing engineer rated it down after Forest Road raised the 21-day request-anchored FIFO cooldown, which removes opportunistic execution but does not gate curator withdrawal, the curator module contains no timestamp logic at all. SCOPE IS THE MATERIAL POINT: near-unreachable while Forest Road is sole curator, because its first-loss capital is consumed before any senior loss and franchise value dwarfs a single exit gain, so the round trip would extract from seniors while its own junior capital stays exposed. It goes live from the first non-Forest-Road curator approval: a third-party curator has no franchise at stake and nothing in code bars a curator from holding senior tokens, curator approval being admin-gated only. Best read as a precondition on a planned capability rather than present exposure. Remediation is to snapshot the curator pool balance used for impairment netting at epoch open rather than reading it live at settlement, and it should land before any third-party curator is approved. ACCEPTED BY FOREST ROAD ON 4 AUGUST 2026 as low practical risk, after its own analysis. Accepted is used strictly and is not a synonym for fixed: the mechanism is unrefuted and Corrovera's Medium rating stands as recorded, and this entry does not restate it as Low. The acceptance rests on the actor-scope argument above, that the only currently approved curator is the party whose junior capital the round trip would leave exposed. IT MUST BE REVISITED BEFORE ANY NON-FOREST-ROAD CURATOR IS APPROVED, if a Forest Road curator wallet holds a material sUSDfr position or eligible queued redemption during delinquency or impairment, if curator incentives/first-loss/withdrawal/netting/settlement mechanics change, or if new evidence widens reachability or impact. Reproduction detail is withheld while the mechanism is unremediated, as with every live finding on this register.",
      },
      {
        id: "F-02",
        severity: "Medium",
        title:
          "Ordinary forbearance suppresses the senior impairment mark, with no misconduct required",
        disposition: "Accepted",
        note:
          "The permissionless past-due mark is gated entirely on a servicer-controlled payment date, movable both by an originator-role term amendment and by the waterfall advancing it on a payment classified as performing. While that date is rolled forward, past-due principal stays zero, pending senior impairment never reflects the delinquency, and queued seniors settle against an unimpaired mark. CORROVERA WITHDREW THEIR OWN FIRST FRAMING of this as a deliberate deferral, and the correction makes the finding worse rather than better: rolling a payment date for a borrower with a temporary liquidity problem is ordinary forbearance and standard credit practice, and an originator concealing delinquency would destroy their own book. The harm needs no intent, a well-intentioned servicer produces the same suppression, so likelihood rises because forbearance is routine, while the profit motive disappears and it is less likely to be noticed precisely because nobody is behaving badly. BOUNDED TWO WAYS. It only bites where a class's impairment exceeds its first-loss capacity; inside that capacity no senior is mispriced at all and the anchor curator absorbs it exactly as the cascade intends, but that is also, unavoidably, the tail where the capital providing that alignment has already been consumed. And both deferral routes require an attestation, so attestation discipline is the control, which is the control the register already records as concentrated at m == n == 2 with both attesters under one key and the attester being the servicer. The report is explicit that F-02 and that entry compound and that neither captures the interaction alone. Recorded as an observation rather than an allegation: management fees are AUM-linked and performance fees run against a high-water mark on the conservative rate, so the party deciding whether to grant forbearance is not financially indifferent to that decision. Distinct from the register's existing marks, it inverts the over-mark entry rather than restating it, and concerns a different input from the stale-valuation entry. ACCEPTED BY FOREST ROAD ON 4 AUGUST 2026 as low practical risk, after its own analysis. Accepted is used strictly: no code change was made: the mechanism is unrefuted, and Corrovera's Medium rating stands as recorded rather than being restated here as Low. The acceptance rests on the two bounds above: that the senior mark cannot move until a class's first-loss capital is exhausted, so no senior is mispriced for any delinquency the curator absorbs, and that both deferral routes require an attestation. IT MUST BE REVISITED if class losses approach or exceed first-loss capacity, if the attester quorum or its key custody changes, if the servicer ceases to be the attester or a further deferral route is added, or if forbearance ceases to be exceptional in practice. The compounding interaction with the concentrated-attestation entry is the part to watch: neither entry captures it alone, and the acceptance of each assumes the other holds.",
      },
      {
        id: "F-03",
        severity: "Informational",
        title:
          "Challenge to the D7-01 risk acceptance: a later redesign may have widened the trigger surface it was scoped against",
        disposition: "Open",
        note:
          "Advisory rather than a finding. The D7-01 acceptance of 3 August 2026 rests on the premise that the default declaration is atomic and private, so a post-declaration exit is already priced at the impaired conservative mark. One of ten independent opinions dissented with a specific and testable mechanism: the H-5 redesign introduced the past-due mark as a PERMISSIONLESS, PUBLIC trigger that also raises pending senior impairment, so an observer can see it in the mempool and act ahead of it, a channel the acceptance premise does not cover, because that premise was written about the default declaration. The other nine judged the acceptance sound. This does not overturn it; it records that a later redesign may have widened the surface the acceptance was scoped against, and Forest Road is treating it as a recorded revisit trigger. Consensus across all ten opinions was that the separate D-RATE-02 acceptance is sound.",
      },
    ],
  },
  {
    slug: "2026-08-04-mtm-executor",
    file: "audits/2026-08-04-mtm-executor.md",
    title: "First audit of the marked-to-market executor",
    eyebrow: "Round 17",
    date: "2026-08-04",
    dateLabel: "4 August 2026",
    baseline: "5e43dcf + working tree",
    scope:
      "MtmAtomicExecutor, a 95-line production contract that entered the protocol after the sixteenth review round and had never been reviewed by any of them, together with its off-chain keeper service. Deployed in the production path and wired to the attestation oracle and the default manager.",
    method:
      "Six independent lenses: the revert parser and action selection, liveness and state coverage, protocol integration, MEV and ordering, deployment and dependency risk, and the off-chain keeper. Each of the most severe findings per lens was then handed to a separate reviewer instructed to destroy it. Every claimed finding required a passing test; every dismissal required a test that tried the attack. 53 class dispositions.",
    summary:
      "Found because we were writing a document about where our own review method is blind: nothing in our process detects a production contract added between rounds. Six reviewers raised 44 candidate findings; two survived adversarial verification and both are Low. MTM-02 was then fixed: the keeper derives the digest, validates signatures and the available protective action locally, uses fixed reviewed gas and sends no pre-inclusion digest commitment, unsigned valuation or bearer calldata to either read RPC; the pinned-fork lifecycle enforces rpc-commitment-leak=0, rpc-valuation-leak=0 and rpc-bearer-leak=0 and rejects a deterministic no-action bundle before any relay call. Forest Road formally accepted the live, PROVEN MTM-01 risk on 4 August 2026; it is not fixed or refuted. The design's central claim: that an ordinary caller cannot choose a weaker protective action, otherwise holds, including against a timing-based downgrade attack that turns out not to exist. All 172 custom errors in the production source were enumerated for a collision with the fallback trigger: none collides. Two of the three hypotheses we seeded into the audit were refuted by it, one corrected by Forest Road against our own analysis.",
    archive: "audit/REPORT.md",
    findings: [
      {
        id: "MTM-01",
        severity: "Low",
        title:
          "The revert parser authenticates the shape of a failure but cannot authenticate where it came from",
        disposition: "Accepted",
        note:
          "The executor decides whether to liquidate by inspecting the shape of the error the default manager returns. Custom errors carry no proof of origin, and the liquidation path continues past its own threshold check into four further contracts whose errors pass straight back through. A contract on that path can imitate the default manager's own 'threshold not breached' verdict, and the executor believes it: a materially breached position is downgraded to a margin call while the transaction REPORTS SUCCESS. The keeper's receipt is internally consistent with that downgrade, so it also reads green. RATED LOW, and the reasoning matters: reaching it requires a privileged configuration change the production deployment does not permit, because the mainnet deployment script drops the relevant administrative role entirely rather than retaining it as the testnet does, and post-deployment validation independently asserts the wiring that would enable it. Anyone able to arrange it could block the liquidation outright in any case, which is strictly more power than the downgrade. ACCEPTED BY FOREST ROAD ON 4 AUGUST 2026: the mechanism remains live and PROVEN; no code remediation or refutation is claimed. The acceptance relies on timelock-only mainnet DEFAULT_ADMIN, exact impairment-source validation and the already-greater power required to install the forging module. It must be revisited if that role posture or wiring assertion weakens, the impairment source/access control/upgradeability changes, another attacker-influenceable post-threshold external call appears, or new evidence establishes non-governance reachability or greater impact. The governing decision record now states the provenance limitation explicitly. The durable code fix remains to remove the parser: read the current loan-to-value and class thresholds after recording the mark, decide the action in the executor, and call exactly that one function.",
      },
      {
        id: "MTM-02",
        severity: "Low",
        title:
          "The keeper discloses the complete signed valuation bundle before submitting it",
        disposition: "Remediated",
        note:
          "Before remediation, standalone attestation simulation, executor simulation and gas estimation all sent the complete signed bundle to READ_RPC_URL. Because recording a mark is permissionless: that bundle was a bearer credential: the endpoint operator could consume it outside the executor and split the intended atomic operation. RATED LOW because exploitation requires control or compromise of configured infrastructure: the obvious exit-ahead-of-loss impact fails against the queue's cooldown and settlement-time pricing, and the guardian path fails closed. FIXED 4 AUGUST 2026: the exact EIP-712 digest and quorum authorization are derived locally; peer recovery uses facility-filtered already-public executor events rather than a potentially dictionary-attackable pre-inclusion digest query; acceptance matches the oracle's canonical 65-byte low-s v=27/28 rule; approved fixed gas replaces dynamic estimation; and no digest commitment, unsigned valuation or signed attest/execute calldata reaches either RPC. The worker mirrors the executor action from a block-consistent signature-free snapshot and rejects paused, stale, non-live or no-action states before release. The compiled fork lifecycle retains rpc-commitment-leak=0, rpc-valuation-leak=0 and rpc-bearer-leak=0. Both selected live Flashbots configurations later passed bounded funded deterministic-revert suppression and Alchemy/Ankr no-public-observer tests without inclusion, nonce movement or spend. Flashbots' public status API nevertheless exposed limited FAILED-transaction metadata contrary to its current docs, and internal raw-payload handling remains unprovable. Forest Road formally accepted that separate hosted-relay residual as MTM-RELAY-01 on 5 August 2026, with exact-configuration conditions and four revisit triggers; this does not claim provider internals are proven and is not an acceptance of MTM-02.",
      },
      {
        id: "MTM-LIVENESS",
        severity: "Informational",
        title:
          "Mid-band marks during an open cure window, recorded rather than raised",
        disposition: "By design",
        note:
          "Six of the six lenses independently found the same gap: with a margin call open and before its deadline, a mark showing the position still in breach but not yet liquidatable has no legal action available, so the whole operation reverts and the mark is discarded. Every verifier refused to raise it as a finding, for two reasons that are worth publishing. First, its consequence, a mark going stale disables the permissionless protections, is already published on this register under an earlier finding, and the executor surfaces that gap rather than creating it. Second, Forest Road corrected our framing directly: marked-to-market valuations are taken at most daily, which bounds the exposure to a single missed cycle rather than the continuous blind window our analysis had described. What survives is operational rather than structural. The maximum mark age and the cure window are both exactly one day, and the liquidation check treats the deadline strictly, so a keeper firing seconds before a live deadline loses that mark and the position waits a cycle before liquidating. The remedy is to stagger the keeper schedule so it never fires immediately before a deadline, a change to when the job runs, not to the contract.",
      },
    ],
  },
  {
    slug: "2026-08-02-internal-adversarial-audit",
    file: "audits/2026-08-02-internal-adversarial-audit.md",
    title: "Internal adversarial audit of the whole protocol",
    eyebrow: "Round 16",
    date: "2026-08-02",
    dateLabel: "2 August 2026",
    baseline: "7eef49b",
    scope:
      "The entire protocol rather than a change: all 19 production contracts, the live Sepolia deployment reconciled against source, and fresh full deployments onto a pinned Ethereum-mainnet fork against canonical USDC. Deploy scripts, CI gates and the frontend contract config were in scope as attack surface.",
    method:
      "A five-phase engagement protocol fixed before any code was read: reconcile deployed bytecode against source, derive the threat model from the code, sweep a mandatory vulnerability-class table where silence is not a disposition, attack on two pinned forks, then report. Source was frozen through discovery. Every finding above Informational owes a passing exploit test and every dismissal owes a test that tries the attack. Thirteen exploitation workstreams, each claimed finding then put to two independent adversarial verifiers instructed to refute, then lead adjudication with independent re-runs. Five handler-based invariant families with ghost state tracked independently of the contracts.",
    summary:
      "The core value-custody mechanics held under direct attack: cascade ordering, conservation and subordination headroom across 163,840 stateful calls with the per-event backstop cap binding for the first time; queue solvency, FIFO and no-double-claim across another 163,840; the whole attestation signature layer; reentrancy closed by building and installing a hostile module rather than by argument; and flash-loan atomicity tested by genuinely borrowing at a pinned block. The failures cluster in exactly two places, economic controls derived from spot-read balances, and the role-admin topology, where one missing override produces three symptoms that had been filed as three findings. The round also corrected four of its own earlier conclusions. On 3 August 2026 Forest Road accepted the corrected residual risks for D7-01 at Medium and D4-01 at Low; both mechanisms remain proven and live, but neither is resolved or a release blocker. As measured on 2 August 2026 against the then-36-file contracts/src, production source reported 100% line and branch coverage and every defect found lay in covered code. Two caveats now attach and must be read with that figure: the source has since grown to 49 files, which this measurement does not cover; and finding P-28 subsequently established that forge scores a multi-clause guard as a single branch, so a reported 100% branch figure is compatible with individual clauses never executing. Treat the number as a floor on line coverage for the 2 August tree, not as a current claim of exhaustive branch coverage.",
    archive: "audit/REPORT.md",
    findings: [
      {
        id: "D7-01",
        severity: "Medium",
        title:
          "The redemption queue's per-epoch liquidity budget is read from a live balance and can be inflated with borrowed capital inside one transaction",
        disposition: "Accepted",
        note:
          "The queue's per-epoch budget is snapshotted from an attacker-movable live balance, so capital moved across the settlement can bypass the intended throughput cap. The mechanism was PROVEN on a pinned mainnet fork with genuinely borrowed capital. CORRECTION, 14 August 2026: this entry previously said the finding was 'not remediated', which overstated it. The flash-loan channel it describes IS closed in shipped source, closeEpoch is gated on SETTLEMENT_KEEPER_ROLE, documented at RedemptionQueue.sol:308 as 'AUDIT FIX (D7-01)', so an arbitrary caller can no longer drive settlement inside a borrowed-capital transaction. What remains open, per that same NatSpec, is narrower and harder: an attacker sandwiching the keeper's transaction with REAL capital held across a block (millions genuinely at risk rather than a zero-cost flash loan, further mitigated by submitting the keeper call through a private relay), and the Queue_HeadNotRedeemable clamp channel, which fires whoever calls. Impact was re-rated from High to Medium on 3 August 2026: declared defaults immediately feed pendingSeniorImpairment(), and runbook section 7.5 requires an atomic private default declaration, so an exit after declaration is already priced at the impaired conservative NAV. What remains is run-dynamics harm from bypassing the throughput cap rather than the previously published targeted loss-avoidance channel. Forest Road formally ACCEPTED this residual Medium risk on 3 August 2026, conditioned on that atomic-private procedure and conservative-pricing behavior remaining in force. Revisit the acceptance if either control changes, the queue design changes, or new evidence establishes targeted extraction.",
      },
      {
        id: "C-01",
        severity: "Medium",
        title:
          "A reserve write-down freezes minting, redemption AND all facility servicing, curable only by an unrehearsed emergency role grant",
        disposition: "Accepted",
        note:
          "The backing check is an absolute post-state gate: it asks whether the end state is solvent, never whether the operation improved matters. The one lever the protocol provides for recording a stablecoin custody loss lowers recognized backing with no paired burn, so using the feature exactly as designed produces a state in which minting and redemption both revert. RE-RATED DOWN FROM HIGH, and both halves of that re-rating are substantive. Worse than first reported: the repayment path is exactly NEUTRAL on the shortfall rather than narrowing it, because both interest legs are minted, so this round's earlier claim that repayments would gradually heal the gap is arithmetically wrong, and while the system is under water the credit book cannot be serviced at all. Less severe than first reported: the claim that no on-chain recovery exists short of a contract upgrade is false. Two governance cures exist, each demonstrated restoring minting, redemption and servicing, recapitalize by the amount lost, or route the loss through the cascade as a senior haircut, which is what the cascade's own third layer already does. Forest Road ACCEPTED the fail-closed design on 3 August 2026 rather than relaxing the backing gate and allowing exits to race an acknowledged deficit. The acceptance is conditional on the production incident procedure: keep user operations paused and execute one timelock batch that grants itself temporary reserve-deposit authority, pulls the exact six-decimal USDC recapitalization from the Recovery Safe, and revokes that authority, followed by independent custody/backing/role verification before unpause. A reserve loss beyond available recapitalization or the protocol's clean cascade absorption capacity remains an escalation case rather than an ordinary recovery.",
      },
      {
        id: "D4-01",
        severity: "Low",
        title:
          "The queue's anti-denial-of-service heartbeat guard is an absolute floor, so it is stepped over rather than overwhelmed",
        disposition: "Accepted",
        note:
          "A guard exists specifically to stop an actor resetting the settlement clock by starving the queue of liquidity, but it is an absolute economic floor rather than a proportion of capacity. The mechanism remains PROVEN and no configuration change closes it. Impact was re-rated from Medium to Low on 3 August 2026: sustained denial requires a KYC-gated, visible and stoppable capital variant; the anonymous zero-capital variant produces a bounded, non-compounding one-epoch delay per inflow, extracts no value and creates no permanent freeze. Forest Road formally ACCEPTED this residual Low risk on 3 August 2026. The rejected demand-anchored fix must not be revived; revisit the acceptance if queue or epoch dynamics change or new evidence shows compounding, targeted extraction or anonymously repeatable sustained denial.",
      },
      {
        id: "D5-03",
        severity: "Medium",
        title:
          "A stale valuation disables every permissionless senior protection on a marked-to-market facility",
        disposition: "Open",
        note:
          "The contract documentation states a deliberate asymmetry: protective triggers accept the latest mark at any age, while CURING a margin call demands a fresh one. The arithmetic does not implement that claim, the two protective paths gate on freshness identically to the curing path. Because the maturity-clock mechanism is additionally barred for marked-to-market classes: a mark that has simply gone stale leaves no permissionless senior protection at all. Measured: a facility sitting well above its margin threshold and materially underwater prices seniors at PAR, with the conservative exit valuation equal to the realized one, so a senior exiting through the queue in that window takes par and leaves the entire shortfall to those who stay. That is precisely the harm the mechanism was redesigned to prevent. Verification note, stated because it affects how much weight this carries: adversarial verification was capped at the two highest-severity findings per workstream and this one fell outside the cap, so it has no independent verdict. The cited lines were re-read against source by the engagement lead, but it is less hardened than the doubly-verified findings.",
      },
      {
        id: "D12-01",
        severity: "Medium",
        title:
          "An interest-only payment clears the on-chain clock but leaves the whole past-due impairment mark standing",
        disposition: "Open",
        note:
          "The repayment path notifies the default manager that a facility is performing only inside the branch taken when principal is repaid, while the next-payment clock advances regardless. So an interest-only payment makes a facility no longer past due by the clock, yet the full mark-time impairment snapshot keeps depressing the conservative senior valuation until a servicer obtains an attested cure. Every queue settlement in that window underprices the seniors it pays. The mechanism was confirmed by both adversarial verifiers, who then split on impact, one rating it correct at High and the other Low; adjudicated Medium, because the mispricing is real and the window can be opened at will by an unprivileged caller: the past-due marking is permissionless, but it is bounded by the cure path and no profit extraction was demonstrated.",
      },
      {
        id: "D9-01",
        severity: "Medium",
        title:
          "The default administrator role administers the upgrade role, so the timelock is bypassable in a single grant",
        disposition: "Open",
        note:
          "Reported as a CENTRALISATION RISK rather than folded into the severity ranking. Searching production source for a role-admin override returns nothing, so the default administrator role administers every role, including the upgrade role that the timelock is supposed to hold exclusively. Under the deployment posture that deliberately retains operator control, one grant converts operator control into upgrade authority with no timelock delay. THE MAIN PRODUCT OF THIS FINDING IS A CORRECTION TO THIS AUDIT'S OWN EARLIER PHASE, which examined live role assignments, found the upgrade role held only by the timelock on every module, and published the conclusion that no externally-owned account can upgrade anything. That conclusion is false as written: it described a configuration snapshot, not a control, and the safety specification's corresponding invariant does not hold as stated. An invariant campaign independently failed on this and shrank the counterexample to a single call. Both adversarial verifiers rated the RISK low on the ground that the posture is disclosed and deliberate, with a handover script that moves the roles to the timelock, a fair characterisation, and not a reason to leave a false published conclusion standing. Two further symptoms have the same single cause and should be remediated as one: the mint authority can be reconstituted the same way, which is separately documented by the team as a known consequence of the same posture. What is missing is not the mitigation but a named trigger for running it.",
      },
      {
        id: "D9-03",
        severity: "Medium",
        title:
          "The quorum denominator is total token supply while the numerator can only ever count delegated votes",
        disposition: "Open",
        note:
          "Quorum is measured against total supply, but voting power only exists for tokens that have been delegated, a holder who never self-delegates counts toward the bar and never toward clearing it. As the token distributes to ordinary holders, quorum becomes progressively unreachable, and a stalled governor freezes every module parameter and every upgrade. Currently masked because genesis supply sits with the treasury, which can self-delegate and meet the bar. THIS INTERACTS WITH THE FINDING ABOVE IN A WAY THAT DICTATES REMEDIATION ORDER, and the interaction is not visible from either finding alone: the timelock bypass is presently the de facto escape hatch from a quorum stall. Closing the centralisation finding first, handing the administrator role to the timelock while the quorum defect stands, would make a stall UNRECOVERABLE, because the state that requires a governance action to fix would be the state that prevents one. The quorum denominator must be fixed first. Like the stale-mark finding, this fell outside the two-per-workstream verification cap and carries no independent adversarial verdict.",
      },
      {
        id: "D-RATE-02",
        severity: "Medium",
        title:
          "Under severe declared impairment: an attested interest receipt can lower the senior exchange rate",
        disposition: "Accepted",
        note:
          "The fee share minted against an inflow is sized so its value at the CONSERVATIVE valuation equals the fee, but the shares themselves are ordinary vault shares worth the REALIZED rate, so the dilution actually imposed is amplified by the ratio between the two. Past a threshold the amplification exceeds the benefit of the inflow itself and a payment made TO senior holders leaves them worse off. The threshold is exact and was pinned by test: the rate falls once the conservative valuation drops below the fee rate times the realized one, more than 90% of senior value under declared-but-unrealized impairment at the shipped fee, more than 80% at the rate cap. A control test confirms the ordinary case is unaffected: with no impairment live, the same receipt raises the rate. ACCEPTED BY FOREST ROAD ON 2 AUGUST 2026 on likelihood, not on correctness: the mechanism is not disputed. The rationale is recorded precisely, because the load-bearing condition is NOT the 90% impairment, which is more reachable than it sounds while concentration limits remain fully open and the book is thin. What makes the state hard to reach is the requirement for a large unpriced gain sitting above the high-water mark at the moment of the inflow, and fee crystallisation is permissionless and happens on entry, exit and repayment. The acceptance carries explicit revisit triggers: anything that lengthens the interval between fee checkpoints, a widening of the window inside the repayment path: a book that stays concentrated at scale, or a fee-rate increase toward the cap, which moves the threshold from 90% to 80%. One reachability step is NOT closed by the acceptance and is recorded as open work: the impairment was injected through a test double rather than driven through a real declared default, so what is proven is the arithmetic, not that the triggering state is reachable end to end.",
      },
      {
        id: "A-02",
        severity: "Medium",
        title:
          "The live attestation quorum provides no signer independence, and the attester is also the servicer",
        disposition: "Open",
        note:
          "Reported as a CENTRALISATION RISK. The oracle proves signer distinctness by requiring recovered addresses to strictly ascend, a check on addresses, not on key custody, satisfied by two addresses derived from one seed and held by one party. The deployed configuration is exactly that degenerate case: the threshold equals the attester count: one attester is the deployer, and the project's own manifest records the second as derived from the deployer's key. The same key simultaneously produces the facts, acts on them as servicer, mints the position they gate, and administers the attester set. Two consequences were proven: the m-of-n control is satisfiable by one actor in one transaction, recording a valuation that feeds the solvency check; and because the threshold equals the set size there is zero fault tolerance, so losing a single key makes every high-value attestation kind unsatisfiable and halts the credit lifecycle. Rated against a mainnet launch carrying this configuration forward, which is the migration risk the deployment-reconciliation phase exists to catch; the posture is declared rather than concealed on the current testnet.",
      },
      {
        id: "C-03",
        severity: "Low",
        title:
          "A reversible impairment assessment crystallises irreversible performance-fee dilution of senior holders",
        disposition: "Open",
        note:
          "Publishing an assessment lifts the fee valuation against an unchanged high-water mark; the next fee crystallisation books that lift as performance, mints fee shares and ratchets the mark. The assessment is time-boxed and lapses on any change to the underlying risk state, at which point the valuation falls back, but the minted shares are not clawed back and the mark does not un-ratchet. So a reversible, explicitly time-limited estimate produces permanent dilution, and if the assessed recovery never arrives, seniors have paid a performance fee on cash that never existed. PROMOTED FROM HYPOTHESIS TO PROVEN in this round, and RE-RATED DOWN from Medium at the same time. The escalation path the finding itself named, whether an administrator can cycle assessments to ratchet the mark repeatedly, was run as an experiment and DISPROVED: the cycling is bounded. Reporting the disproof of one's own escalation is the discipline the engagement asks for and it is recorded as such. What survives is a genuine asymmetry between who bears estimate risk and who captures estimate upside, requiring an administrator key and producing no external-attacker path.",
      },
      {
        id: "C-02",
        severity: "Low",
        title:
          "The permissionless reserve reconciliation is an unguarded, unpausable reduction of recognized backing",
        disposition: "By design",
        note:
          "The reconciliation carries no role check or pause guard and ratchets recognized backing only downward. Forest Road classified that as BY DESIGN on 3 August 2026: the caller cannot move USDC, manufacture a shortfall or raise backing; any address may merely force the internal ledger to acknowledge a lower live canonical-USDC balance so a real custody loss cannot be hidden from depositors. Enumeration against canonical USDC at a pinned mainnet block found no issuer seize, clawback, burn-from or wipe primitive, so the external trigger is not reachable today. If USDC ever gains such a primitive, issuer action can expose a deficit and reconciliation will make the protocol fail closed, invoking the accepted C-01 recapitalization procedure. Direct transfers deliberately cannot reverse the ledger. The no-op event remains a low-cost indexer-spam nuisance and should be filtered by consumers; it does not change backing.",
      },
      {
        id: "A-01",
        severity: "Low",
        title:
          "The timelock implementation contract was left uninitialised and is permissionlessly seizable",
        disposition: "Remediated",
        note:
          "Seventeen of eighteen implementations lock their initialiser in the constructor; the timelock did not, because it is the only implementation taken from an upstream library rather than written in-repo and it never received the house convention. Anyone may initialise it directly and take administrative control of the implementation contract. Bounded honestly, and deliberately NOT rated higher: every protocol role is granted to the timelock PROXY, whose storage is initialised and untouched by this, so the attacker gains no authority over any module, and the contract is not upgradeable so the usual escalation to bricking the proxy is unavailable. What remains real is that value misdirected to the implementation address is seizable, a realistic operator error, since it is a verified contract labelled as the timelock, and that an attacker-controlled contract at that address can emit genuine-looking governance events that an explorer or indexer may attribute to the protocol. FIXED IN THE DEPLOYMENT SCRIPT: the timelock implementation is now deployed through a thin wrapper whose constructor calls _disableInitializers(), bringing it into line with the 18/18 house convention, so the initialiser is locked at construction and the seizure is unreachable on any deployment made from the current script. THE FIX IS PROSPECTIVE, AND THE DISTINCTION MATTERS: it governs future deployments only. The implementation already deployed to Sepolia was created before the fix and remained permissionlessly seizable, and Forest Road confirmed there would be no Sepolia redeploy before mainnet, so on 5 August 2026 that instance was neutralised directly instead, in transaction 0xec2e410b3931604daa3f18cf5b200ab87a626e245a5db91403aa8890dc3a6647. It was NEUTRALISED RATHER THAN SEIZED: the initialiser was spent with an empty proposer set, an empty executor set and a zero admin, so the only holder of the admin role is the contract itself, which can act only through a scheduled operation, which requires a proposer, which only the admin role can grant. Deadlocked by construction, nobody controls it, Forest Road included, and a further initialise call now reverts with InvalidInitialization. Verified on chain independently of the script's own assertions: the implementation's initialised version moved 0 to 1: the deployer holds no admin, proposer or executor role, execution is not open to the zero address, and the live proxy's initialised version and two-day minimum delay are unchanged. Taking it for ourselves was considered and rejected: it would have created a custody obligation over a verified contract the explorer labels 'timelock', and read on chain as a shadow governance contract. THE MECHANISM IS THEREFORE CLOSED ON BOTH NETWORKS, prospectively on mainnet by the wrapper, and by direct neutralisation on the existing testnet stack. A regression test now pins the fix rather than leaving it to inspection: it runs the real deployment sequence, reads the implementation out of the deployed proxy's ERC-1967 slot rather than constructing one locally, and asserts the initialiser is disabled, that an attacker's initialise call reverts with the specific InvalidInitialization error, and that no partial takeover of any role occurs. It also pins the boundary this finding was bounded by: the proxy stays initialised with its governance roles intact, and carries a control case proving the unwrapped upstream library IS seizable, so the guard cannot pass vacuously. It was verified by mutation in both directions: removing the constructor call and reverting the deployment to the raw library each make it fail.",
      },
      {
        id: "D-RATE-01",
        severity: "Low",
        title:
          "The performance-fee high-water mark re-anchors after the fee is taken, so denser checkpoints charge more on the same gain",
        disposition: "Open",
        note:
          "The mark is re-anchored to the rate AFTER fee shares are minted, so the next checkpoint measures profit from a mark below the rate the vault actually reached and charges a fee on the fee. Crystallisation is permissionless and takes no arguments, so its frequency is chosen by whoever wants to choose it, including the fee recipient. Measured on a fixed gain with management fees disabled: the effective rate rises from 999 basis points at a single checkpoint to 1083 at two hundred, against a mathematical limit of 1112, with the senior holder losing about 0.84% of the gain purely to checkpoint timing. Governance has no parameter that bounds this. The equivalent claim for the management fee was tested as a control and is CORRECT: that fee is genuinely frequency-neutral, and the decision record only ever claimed neutrality for it.",
      },
      {
        id: "D3-01",
        severity: "Low",
        title:
          "Two windows leave every vault conversion view readable at a transient wrong rate",
        disposition: "Open",
        note:
          "The transient lock that defends against reading a half-applied fee rate covers one window and CREATES a divergence in another: on a plain share transfer it suppresses the fee simulation and quotes the gross, pre-fee rate. A second and larger window exists because the underlying vault standard burns shares before transferring assets, so a callback firing between the two observes a supply that has already fallen against assets that have not yet moved. Measured, the conversion views read a rate inflated by roughly three orders of magnitude inside that window. No internal consumer reads inside it, and installing an observer requires an administrator key, which is why this is Low rather than higher, but any external protocol that prices this share as collateral off the public views is exposed, so it is published as an integrator warning as much as a defect.",
      },
      {
        id: "D5-01",
        severity: "Low",
        title:
          "The staking reward stream strands value when total stake reaches zero mid-stream",
        disposition: "Open",
        note:
          "Notifying rewards pulls value in and increments no accounting field; its only claim on that value is the streaming index. When total stake reaches zero the index stops advancing while the clock does not, so every second with nobody staked consumes stream time and credits it to nobody. The written-off value then sits outside the coverage reserve, so it can neither be claimed by stakers nor delivered by the loss cascade. Measured worst case, a full notification abandoned immediately strands 100% of it. The word PERMANENTLY was refuted by both verifiers and is not claimed here: the contract is upgradeable and the timelock holds the upgrade role, so a governance upgrade recovers it. Also note the notification entrypoint is permissionless.",
      },
      {
        id: "D11-01",
        severity: "Low",
        title:
          "The emergency valuation-source recovery cannot fire on the failure mode it exists for",
        disposition: "Open",
        note:
          "The install-time probe of an untrusted valuation source is gas-bounded and cannot be exhausted, but the PRODUCTION read of the same source calls it through the ordinary interface, which copies the whole return buffer into memory. Memory expansion is quadratic, so a source returning a large payload turns every exit-pricing read into a gas bomb, measured at more than five times the block gas limit, meaning not expensive but unexecutable, while the bounded probe that is supposed to detect an unreadable source still reports it healthy. The install gate and the recovery gate should use the same budget, so that a source which installs is a source the emergency clear will later agree is broken.",
      },
      {
        id: "D11-02",
        severity: "Low",
        title:
          "A repayment-path fee recipient is not checked for compliance exemption, unlike its vault sibling",
        disposition: "Open",
        note:
          "The vault enforces twice that its fee recipient is protocol-exempt before accepting it; the repayment engine's equivalent setter enforces it not at all. A fee recipient that is later sanctioned by the compliance registry therefore causes every repayment on every facility to revert, because the fee leg cannot be delivered. Small change, and the asymmetry between two siblings is the kind of gap that survives review precisely because each side looks reasonable alone.",
      },
      {
        id: "D11-03",
        severity: "Low",
        title:
          "Flooding the redemption queue imposes a measured gas amplification on the keeper of the sole exit",
        disposition: "Open",
        note:
          "Each settlement iteration recomputes conservative pricing per request, so clearing the queue costs the keeper more than filling it costs an attacker, measured at 1.82x across forty minimum-value requests. Strict first-in-first-out with no cancellation path and no reordering means the keeper cannot skip the flood. This is a cost asymmetry rather than a block-limit break, which is why it is Low: the queue still settles. Caching the per-settlement price rather than recomputing it, or a refundable deposit per entry, closes the instance; the general shape, cheap to enqueue, expensive to settle, needs an economic answer.",
      },
      {
        id: "D9-04",
        severity: "Low",
        title:
          "The timelock is an unfixable governance root whose only escape route runs through itself",
        disposition: "Open",
        note:
          "Reported as a governance-structure risk. The timelock sits behind a plain proxy over a non-upgradeable implementation, so the governance root cannot be upgraded. Repairing a defect in it therefore requires migrating every module's upgrade role, and that migration must itself be authorised by the timelock that is broken. Measured in the production posture: none of the sixteen modules can have its upgrade role re-pointed without a working timelock. This is very likely a deliberate design: an immutable root is arguably the safer choice, but it is nowhere documented as one, and there is no on-chain storage-layout guard on the upgrade such an escape would require. Note the interaction with the role-admin finding above: today the administrator bypass is the de facto escape hatch.",
      },
      {
        id: "D12-05",
        severity: "Low",
        title:
          "The loss-burn entrypoint accepts an arbitrary holder and the token burn performs no allowance check",
        disposition: "Open",
        note:
          "Reported as a CENTRALISATION RISK, not as an external-attacker path. The burn used by the loss cascade takes a caller-chosen address, and the token's burn checks only the minter role, no allowance, no ownership. The cascade itself only ever needs two targets, so the parameter is far wider than any real caller requires, and a single compromised credit-role key drains any holder to zero in one call. The backing check cannot object, because burning only improves it. Narrowing the parameter to the two known targets closes it.",
      },
      {
        id: "D13-01",
        severity: "Low",
        title:
          "The blocking static-analysis gate certifies green on an analysis that covered only part of the tree",
        disposition: "Remediated",
        note:
          "One of four ASSURANCE-CHAIN defects, and they share a property worth stating once: each was a CONTROL THAT FAILED OPEN, so every earlier green result was worth less than it appeared, including results this audit itself leaned on. The first remediation bound reports to the complete production source list and source digest and rejected compile failures. A second-pass review found one remaining bypass: Slither could still auto-load a repository configuration that filtered paths or detectors. REMEDIATED 3 AUGUST 2026: the runner now supplies its own empty configuration, records the exact fixed analysis profile and configuration digest, and the checker rejects any missing or changed attestation. A tracked CI regression drives the real runner through a hostile fake analyser that accepts only that private empty config, and separately proves metadata tampering is rejected.",
      },
      {
        id: "D13-02",
        severity: "Low",
        title:
          "The upgrade-safety storage gate covers 18 of 26 layout-critical structures",
        disposition: "Remediated",
        note:
          "Storage COLLISION is structurally impossible here, every module uses namespaced storage and there is no sequential layout to collide, which was proven rather than assumed. But reordering fields WITHIN a namespace still corrupts a live proxy, and this gate is the control for that. REMEDIATED 3 AUGUST 2026: balanced-brace parsing and recursive type-graph discovery now cover all 26 reachable namespaced, embedded, array-element and mapping-value structures; declaration comments no longer affect discovery; complete mapping types are retained instead of erasing unnamed key types; and a structure reused in multiple contexts inherits the strictest relation. Tracked CI regressions mutate a mapping key from address to bytes32 and reuse a namespaced structure as an array element, requiring both unsafe cases to be detected.",
      },
      {
        id: "D13-03",
        severity: "Low",
        title:
          "The broadcasting QA script lets an environment variable choose which deployment it drives, unbound to the connected chain",
        disposition: "Remediated",
        note:
          "The read-only validator gained a chain-versus-manifest assertion; the script that actually signs and broadcasts did not, though it has strictly more blast radius. A stale shell export while the endpoint points elsewhere could therefore target addresses from an unrelated deployment. REMEDIATED 3 AUGUST 2026: QA now resolves a canonical manifest for the connected chain, checks the manifest chain ID before any transaction, and asserts every configured address against that receipt. Six focused Foundry tests cover the canonical binding, wrong-chain and wrong-address rejection, and the permitted explicit local-fork override. This is an operator-safety remediation rather than a protocol change.",
      },
      {
        id: "D13-04",
        severity: "Low",
        title:
          "The frontend fee-ABI version guard is inverted and now fires only for the safe pairing",
        disposition: "Remediated",
        note:
          "The guard exists to stop a vault lacking the current fee interface being driven with current fee selectors. After a default was flipped, it fired only for the combination that was already safe, leaving the dangerous pairing unguarded. REMEDIATED 3 AUGUST 2026: an explicit vault can no longer inherit an unrelated fee-ABI default; known archived and current addresses are checked in both directions; and an unknown test deployment must state its ABI version explicitly. The deployment manifest remains the default source. Seven resolver regressions cover default, archived, current, case-normalized and invalid-version combinations, and the contract/UI synchronization suite exercises the resulting ABI.",
      },
      {
        id: "D6-01",
        severity: "Informational",
        title:
          "The vault prices and ratchets against a donated balance while total supply is zero, and the seed is not atomic with initialisation",
        disposition: "Open",
        note:
          "The degeneracy guard short-circuits whenever supply is zero, on the reasoning that there are no incumbents to harm, true when assets are also zero, but the branch does not require that, so it equally admits a vault that has been donated into. In that state the empty-supply branch of fee accrual ratchets the high-water mark to an arbitrary height permanently, and the per-deposit rounding floor degrades by many orders of magnitude. The deployment wraps its phases in one broadcast but emits one transaction per call, so the vault is live and empty for roughly sixty transactions before the anti-inflation seed lands. Informational rather than higher because the attack is unprofitable in every variant tested, the attacker loses the entire donation and, in the first-depositor variant, far more than the victim. The recommended fix is a deploy-time assertion rather than a contract change.",
      },
      {
        id: "D11-04",
        severity: "Informational",
        title:
          "Permissionless checkpointing permanently allocates storage for any never-participating address",
        disposition: "Open",
        note:
          "Confirmed AND CORRECTED against the carried claim. Checkpointing writes accrual state for two token positions and all five class positions of an arbitrary address regardless of balance, so calling it for a fresh address permanently allocates seven slots that nothing reclaims. But the measured cost is 0.87x the raw storage-write cost, so it is NOT a state-bloat amplifier, an attacker pays more than they impose, and it degrades no dependent path. Guarding the writes on a non-zero balance is a small improvement rather than a fix for a live risk. Recorded because the original claim overstated it and the correction is the useful part.",
      },
      {
        id: "D3-05",
        severity: "Informational",
        title:
          "Correction to this round's own record: the points hooks do make an outbound call",
        disposition: "Open",
        note:
          "An earlier phase of this same audit dismissed reentrancy through the transfer hooks partly on the ground that the hooks make no outbound calls at all, so there is nothing to re-enter through. That is wrong: both hooks call an exclusion check that reaches a separately deployed, administrator-configurable contract, up to twice per invocation, proven with an explicit call expectation. The dismissal still stands, but for a weaker and more fragile reason: the call is a read-only static call and cannot mutate. Published because an argument stated more strongly than the code supports will be relied on by the next reviewer and by whoever writes the next module.",
      },
      {
        id: "D3-02",
        severity: "Informational",
        title:
          "Two loss-path points hooks swallow failures with no telemetry, unlike their siblings | the larger claim around it was refuted",
        disposition: "Open",
        note:
          "Published as a REFUTED finding reduced to what survives, because a register that shows only successes is not a record. The original claim was that a silently dropped hook durably defeats an accrual freeze and produces a large points over-accrual; both adversarial verifiers refuted it on the same ground, that the test's module never actually reverts in the relevant hook, so the silent catch is never entered and the test demonstrates an administrator swapping in a no-op module rather than a swallowed failure. The confidence label was not earned for the stated mechanism. What survives and is worth fixing: two catches on the loss path genuinely lack the failure event that the two token-side catches both emit, so a dropped accrual there is unobservable off-chain.",
      },
    ],
  },
  {
    slug: "2026-07-30-adr-0031-full-delta",
    file: "audits/2026-07-30-adr-0031-full-delta.md",
    title: "Protocol fee stack, full-delta review",
    eyebrow: "Round 15",
    date: "2026-07-30",
    dateLabel: "30 July 2026",
    scope:
      "The entire ADR-0031 workstream reviewed at once rather than incrementally, 14 changed production contracts, +1,130/−99 lines of Solidity, from the commit before the work began to the current tree.",
    method:
      "Twelve lenses partitioning the whole delta so nothing fell between them, instructed to assume nothing any prior round concluded. Two adversarial refuters per candidate, an explicit unverified bucket so a failed refuter could not be scored as a refutation, then synthesis and a completeness critic. Eighteen candidates, thirteen survivors; five of the twelve lenses returned nothing.",
    summary:
      "The fee stack composes correctly: the impairment ordering that guards the never-suppressible loss path holds by construction: the fee arithmetic cannot degenerate in any reachable state, and every cross-module lock is atomic. The cross-slice defect is elsewhere, the launch decision to recognize yield instantly silently voided the band clause of a vault-entry guard in code this work never touched, reducing it to the point test its own rationale rejects. Reproduced executably; the recommended fix was implemented and measured at 116 bytes against 88 bytes of remaining contract size, so it cannot currently be applied.",
    findings: [
      {
        id: "R15-01",
        severity: "High",
        title:
          "Instant yield recognition voids the degenerate-entry band, leaving a point test that one unit of a permissionless transfer steps past",
        disposition: "Remediated",
        note:
          "`_isDegenerate()` closes vault entry on two clauses: a zero-base point and a stranded-stream band. Setting the launch vesting window to zero makes the quantity the band measures identically zero, so the band cannot fire and the predicate reduces to the point test its own sixty-line rationale argues is insufficient (\"the hazard is NOT the point: it is the whole neighbourhood\"). The wipe state is reached by ordinary operation: the loss-realization bound refuses anything above the vault's whole balance, so the servicer's only permitted maximal action lands exactly on the point with all shares outstanding. Entry is correctly closed there; one wei of a permissionless token transfer moves the vault off it and re-opens entry at a still-degenerate price. Nothing is taken at that instant and no rate guarantee breaks: the harm is the ownership split, after which every later inflow accrues to the entrant rather than the written-down holders. ATTRIBUTION, stated plainly: the guard is byte-identical to its pre-ADR-0031 form; this work did not create the bypass, it made it universal. Reproduced in contracts/test/audit/R15_01-DegenerateEntryAtLaunchConfig.t.sol with a control. The covering invariant cannot detect it, it re-implements the same predicate, and every existing band test runs with streaming switched on rather than at the shipped configuration. The recommended fix keys the band on the stored high-water mark; it was implemented and measured at 116 bytes against 88 bytes of remaining size, taking the vault 28 bytes over the deployment limit, so applying it requires freeing space first. Whether to do that or to accept and mitigate operationally is a Forest Road decision. REMEDIATED on 30 July 2026. Space was freed by lowering the optimizer run target from 1,000 to 500, measured at 1,816 bytes of headroom for a 0.29%-0.40% runtime gas increase on the fee-stack suite, with no code change and every gate re-run at the new setting per CLAUDE.md 1.4. A collapsed-price band now closes entry once the realized per-share rate falls below 1% of PAR. The stored high-water mark was tried as the reference first and REJECTED: `_accrueFees`'s empty-supply branch ratchets it to `(assets + 1) * 1e18` whenever any balance exists while supply is zero, so a pre-seed donation could inflate the hurdle and then permanently brick entry through the new band. The invariant suite caught that within one run, a handler revert at supply 1, assets 1, which is the argument for `fail_on_revert` on these campaigns. Par is derived from the token's own decimals, is scale-free, and no actor can move it. The three reproduction tests were INVERTED rather than deleted and now form the regression, including a case proving the band cannot be escaped by donating more and that it releases on genuine recapitalization rather than latching closed. The 1-in-100 multiple is recorded as an economic-review item alongside the existing K = 3.",
      },
      {
        id: "R15-02",
        severity: "Medium",
        title:
          "The corrected acceptance bound reached the decision record but not the register, the safety specification or the runbook",
        disposition: "Remediated",
        note:
          "The previous round corrected the recorded bound for the accepted fee-share denomination residual: the published condition described only the payment-driven family and was blind to mark release, which is unconditional and carries the larger effect. That correction landed in ADR-0031 alone. The published register still stated the superseded necessary condition, the safety specification still presented the rate-integrity invariant as enforcement, and the runbook still carried only the monitoring trigger the decision record now calls blind, while the repository's own passing round-trip test falsifies it at ten times the published threshold. All three corrected in this round, and the runbook gains explicit gates for mark-release alerting, for treating a performance-rate increase as re-opening the acceptance, and for quantifying any fee waived by an emergency valuation-source clear.",
      },
      {
        id: "R15-03",
        severity: "Medium",
        title:
          "The evidence artifacts describe an older tree than the code, and were regenerated partially",
        disposition: "Remediated",
        note:
          "The identity manifest is complete and fails honestly, the inventory matches exactly and only content hashes diverge, but partial regeneration is the harmful shape: the contract hashes verify while the evidence summary above them does not, so a reviewer confirms a source file clean against the manifest and then reads a coverage figure measured before that same file changed. Directly measured contradictions included the test count and a contract runtime margin. This is entirely understatement rather than overstatement and contains no code defect, but the documented onboarding path begins with the manifest check, so it is the first thing an external reviewer meets. Regenerated in this round with the reproducible figures corrected.",
      },
      {
        id: "R15-04",
        severity: "Low",
        title:
          "The queue-side rate invariant re-anchors its own reference point after every action, so it compares a value against itself",
        disposition: "Open",
        note:
          "The handler's floor-advancing helper assigns the post-action rate to its own reference unconditionally, and that assignment is the last state-touching statement on the terminating path of every registered action. At the launch configuration the reported rate carries no time term, so the top-level assertion reduces to a trivially true comparison and makes no cross-call statement at all. The substantive per-call checks inside the handler are real and do constrain behaviour; it is the invariant named in the safety specification that is vacuous. Recorded rather than fixed because a correct cumulative bound has to be derived per transition, which is the same open work the decision record already carries for its sibling invariant.",
      },
      {
        id: "R15-05",
        severity: "Low",
        title:
          "The role gating the cross-module fee lock is absent from the generic privilege scanners",
        disposition: "Remediated",
        note:
          "This work introduced a role that authorises the fee-neutral bracket around junior-capacity writes, and wired it correctly, granted to exactly three module contracts, asserted both positively and negatively in post-deploy validation. But it was missing from the generic privilege enumerator and from the handover script's role sets, whose own documentation states they mirror the roles library. The consequence was narrow and specific: targeted validation covered the role, so a misgrant would still have been caught, but the durable handover receipt could not name it, so the artifact retained as evidence of who held what at genesis was silently incomplete. FIXED: the role was added to both the privilege enumerator and the handover role sets, so the enumerator now covers all eleven roles the library declares and the genesis receipt is complete. This entry was left reading 'Open' for longer than it should have been: the code was corrected without the register following, which is the same drift in the opposite direction to the one this register exists to prevent, and it was caught only when the enumerator became a published file and visibly contradicted its own finding.",
      },
    ],
  },
  {
    slug: "2026-07-30-adr-0031-instant-recognition-recheck",
    file: "audits/2026-07-30-adr-0031-instant-recognition-recheck.md",
    title: "Protocol fee stack, instant-recognition re-check",
    eyebrow: "Round 14",
    date: "2026-07-30",
    dateLabel: "30 July 2026",
    scope:
      "Two deliberate changes of behaviour, realized senior yield recognized instantly rather than vested, and the performance fee crystallized inside every interest repayment, plus the remediation of the Round 13 findings.",
    method:
      "Eight lenses over the delta, with an explicit unverified bucket so that a failed refuter could not be silently scored as a refutation. Two adversarial refuters per candidate, then synthesis and a completeness critic. Twelve candidates, three survivors.",
    summary:
      "The first round in this sequence whose substantive findings are about the governance record rather than the arithmetic. Both behavioural changes are implemented correctly and there is no High finding. Instant recognition retracts one of the two original reasons for vesting honestly and correctly, but overrides the other, a red-team finding about pro-rata capture at the payment instant, without dispositioning it, and the pre-mainnet economic-review gate is carried against a parameter value it was not signed against. One accounting finding remains open on which valuation base the fee-share mint is denominated in; its arithmetic is confirmed and its reachability is argued rather than executed.",
    findings: [
      {
        id: "R14-01",
        severity: "Medium",
        title:
          "Fee shares are sized against the conservative redemption base but dilute the realized base, so a purely positive repayment can lower the reported exchange rate",
        disposition: "Accepted",
        note:
          "Profit is measured on the performance base: the settling share mint is sized on the higher redemption base, and the resulting shares dilute the realized base that the reported rate reads. CORRECTED BY PROOF OF CONCEPT: the defect reproduces, but two claims in the first filing were wrong. Writing a = realized+1 and r = redemption+1, the fall requires BOTH r < f*a (the conservative base under ~10% of realized at the launch rate) AND a payment below (f*a - r)/(1 - f), so it has a payment-size threshold and is not universal, and the 1-f figure is an asymptote as the base tends to zero rather than a practical magnitude. At a 5%-of-realized base the worst case over all payment sizes is a 0.92% fall; reaching 8% needs a vault marked down 99.9%, which is a governance event on its own terms. An executable reproduction with both controls lives at contracts/test/audit/R14_01-FeeShareMintBasis.t.sol. It pins the vault-level arithmetic given a source reporting those values; it does not prove the credit layer can reach that depth, which remains argued rather than executed. The existing rate-integrity property still cannot detect it: its tolerance is exactly the asymptote. Which base the fee-share MINT is denominated in, as distinct from the base profit is MEASURED on, remains a financial-mechanic decision rather than a patch. ACCEPTED by Forest Road on 30 July 2026 and recorded in ADR-0031 under \"Accepted fee-share denomination tradeoff\". CORRECTED AGAIN on 30 July 2026 after a full-delta review: the bound stated above describes only the PAYMENT-DRIVEN family. The general condition is `Delta_a * (r - f*d) < a * f * d`, where Delta_a is the realized-asset gain and d the deferred profit released. A mark RELEASE has Delta_a = 0, because the gross impairment is a principal pool that shrinks with no vault cash, so the inequality holds for EVERY r, including r = a, with no depth precondition at all. The repository\u2019s own passing `test_acceptedGlobalHwmRoundTripUndercollectsButCannotOverchargeHolders` instantiates a 5.00% fall at r/a = 100%, ten times above the originally published threshold. The magnitudes are also 1,000-bps artefacts, not fee-rate independent: at the 2,000-bps ceiling governance can set without an upgrade, 0.92% becomes 5.56% and 8.18% becomes 17.5%. MONITORING accordingly alerts on any release of `performanceFeeImpairment()`, cure, resolution, recovery or realized loss, and treats any `setPerformanceFee` increase as re-opening the acceptance; the redemption-base ratio trigger is necessary for the payment-driven family ONLY and is blind to mark release. Neither denomination is correct in both terminal branches, so this remains a policy choice rather than a defect left unfixed. Open assurance item: tightening the rate-integrity invariant was attempted and NOT shipped; the flat slack is TIGHT for a single checkpoint and what it absorbs is compounding across checkpoints in one ghost-floor epoch. External monitoring, not the test suite, is the operative control.",
      },
      {
        id: "R14-02",
        severity: "Medium",
        title:
          "Instant recognition re-enables the pro-rata capture that vesting existed to bound, and the acceptance is absent from the threat model and the closed economic-review gate",
        disposition: "Open",
        note:
          "Vesting rested on two reasons. The oracle-prerequisite reason is retracted honestly and in the places a reader will look, which is the right behaviour and should not be reversed. The second, a red-team finding that whoever holds shares when a payment lands captures a full pro-rata slice, was deleted rather than dispositioned, and the mitigation now relied on is the one the same record previously judged insufficient in terms. The cooldown binds only the direct queue exit; shares are freely transferable with no holding period, so the liquid secondary market the motivating integration creates restores an immediate round trip. Two checkable gaps in the record: the threat model carries the benefit with no risk row for the residual, and the pre-mainnet economic-review gate is recorded complete against the previous seven-day default while the parameter changed the following day, without being added to the project's own re-confirmation list. Nobody is over-charged and no safety-list invariant breaks: this is an economic-design choice that is Forest Road's to make, and the finding is that it is not written down.",
      },
      {
        id: "R14-03",
        severity: "Low",
        title:
          "The depositor deferral warning is keyed on the fee-free runway, so it falls silent exactly at maximum deferral",
        disposition: "Remediated",
        note:
          "The warning fires on the remaining gap between the hurdle and the performance base, the fee-free runway, whereas the fee that eventually crystallizes is largest precisely when that runway is exhausted and zero once it exceeds the mark. The predicate is inverse to the exposure it advertises, and per-repayment crystallization now pins the vault inside the silent region as the ordinary steady state rather than a transient boundary. Compounding it, the contract surface the front end consumes does not expose the relevant valuation at all, so the interface cannot compute the real exposure even if the predicate were corrected. This is the residual of the Round 13 dust fix, which correctly removed a false positive and in doing so created the blind spot. The predicate now keys on the gross mark rather than the fee-free runway, and `IMPAIRMENT_SOURCE_ABI` exposes `performanceFeeImpairment` so the interface can read the quantity at all. The two render regressions that asserted the superseded gap-based behaviour were rewritten rather than loosened; one now pins the maximal-deferral case that previously went silent.",
      },
      {
        id: "R14-04",
        severity: "Low",
        title:
          "The new interface-support check reclassifies the healthy incumbent backstop as unreadable, routing an ordinary rotation onto the incident path",
        disposition: "Remediated",
        note:
          "The readability predicate now requires an interface declaration before it will probe capacity at all. The incumbent backstop was compiled before that check existed and does not declare the identifier, so it evaluates as unreadable despite being fully functional. Rotation uses the same predicate to choose its ordering, so an ordinary replacement of a healthy backstop takes the effects-first path the governing record reserves for a broken one. The identifier itself was verified correct, recomputed independently to confirm that adding the inherited support interface did not change its value, since a mismatch there would silently reject the genuine backstop. Identity and readability are now separate concerns: `_validateBackstop` requires the ERC-165 declaration for an INCOMING candidate, while `_isBackstopReadable`, used only to choose the rotation's checkpoint ordering, asks solely whether the capacity read works. Pinned by `test_setBackstop_preIdentityIncumbentStillAccruesAgainstOutgoingNav`, verified as a mutation-killer: re-adding the identity gate to the readability probe fails it on the elapsed management-fee base.",
      },
      {
        id: "R14-05",
        severity: "Low",
        title:
          "The interface pre-check orphaned the malformed-return branch of the capacity probe, leaving it untested",
        disposition: "Remediated",
        note:
          "The capacity probe rejects on two independent grounds: the call reverts, or it succeeds while returning fewer than a full word. Inserting the interface check ahead of it means the suite's only short-return fixture now short-circuits before reaching the length comparison, and the remaining negative fixtures exercise the revert half only. A regression that inverted or dropped the length check would go undetected. The check itself is correct; only its coverage was lost. `DeclaredButMalformedBackstop` declares the interface correctly and returns a half word from `coverageCapacity()`, so it passes the identity pre-check and is the only fixture that reaches the `returndatasize() < 0x20` comparison the pre-check had orphaned.",
      },
    ],
  },
  {
    slug: "2026-07-30-adr-0031-composition-recheck",
    file: "audits/2026-07-30-adr-0031-composition-recheck.md",
    title: "Protocol fee stack, composition re-check",
    eyebrow: "Round 13",
    date: "2026-07-30",
    dateLabel: "30 July 2026",
    scope:
      "The remediation of the Round 12 findings, the exit hurdle law, the legacy high-water-mark seed, and the backstop rotation ordering, across the vault and the default manager.",
    method:
      "Eight lenses over the remediation delta, deliberately weighted toward attacking the exit fix rather than confirming it, because that fix was recommended by the previous round's auditor and therefore had an advocate. Two adversarial refuters per candidate, then synthesis and a completeness critic.",
    summary:
      "The first round in this sequence that does not continue it: no High finding, no safety-list invariant broken, and the surviving residual costs the protocol its own revenue rather than costing holders theirs. The exit fix delivers a real guarantee: the per-share high-water mark is now monotonically non-decreasing across every exit, which makes the earlier failure direction structurally impossible. The round's substantive result is an impossibility: basis-additive entry, pro-rata exit and round-trip neutrality cannot all hold with a single scalar hurdle, which is why three prior remediations each relocated the same defect. That trade-off is a financial-mechanic decision and is referred upward rather than patched.",
    findings: [
      {
        id: "R13-01",
        severity: "Medium",
        title:
          "Entry and exit hurdle laws are not composable: a value-neutral round trip permanently destroys the deferred performance fee",
        disposition: "Accepted",
        note:
          "Forest Road accepted the holder-protective pooled-HWM policy without an exit equalization charge. The hurdle is additive on entry and pro-rata on exit, so an exit/redeposit round trip can erase deferred protocol fees; it cannot lower a surviving holder's per-share hurdle or over-charge holders. ADR-0031 and the threat model record the revenue trade-off explicitly. A production dual-NAV integration regression now reproduces the complete queue exit, claim, and re-deposit composition, asserts that assets and supply return to their starting values, and pins the safe under-collection direction.",
      },
      {
        id: "R13-02",
        severity: "Medium",
        title:
          "The legacy high-water-mark seed anchors on the redemption base, leaving a residual equal to the live senior mark",
        disposition: "Remediated",
        note:
          "The zero-HWM migration seed now anchors to totalAssets(), the realized asset base, rather than either impairment-adjusted view. The regression carries non-zero pending and performance impairments, asserts the exact realized-asset seed, and proves that a later cure mints no fee on pre-upgrade value.",
      },
      {
        id: "R13-03",
        severity: "Medium",
        title:
          "The regression pinning the backstop rotation fix is vacuous and passes against the code it replaced",
        disposition: "Remediated",
        note:
          "The replacement regression now creates a live default whose senior impairment depends on the outgoing backstop, makes that backstop unreadable, proves the valuation view fails, rotates to a valid replacement, and asserts the restored impairment. Incoming replacements must also advertise the complete ICascadeBackstop interface through ERC-165 before their capacity is probed.",
      },
      {
        id: "R13-04",
        severity: "Medium",
        title:
          "A new cross-proxy valuation dependency has no executable upgrade-ordering constraint",
        disposition: "Remediated",
        note:
          "Both upgrade authorization hooks now probe the currently installed downstream dependency: the assessed wrapper refuses an upgrade unless its DefaultManager base exposes the revisioned dual-NAV interface, and sUSDfr refuses an upgrade unless its installed source exposes both impairment selectors. The runbook requires DefaultManager → AssessedImpairmentSource → sUSDfr upgrades in one atomic timelock batch; unit regressions prove the wrong order fails before an implementation change lands. Round 14 confirms the runbook requirement, which was this finding's stated minimum, is delivered, and that both guards fire on a real capability gap. It also records what they are not: they are liveness checks on the installed dependency, not ordering constraints, so they cannot by themselves force a correct sequence. The atomic batch remains the operative control.",
      },
      {
        id: "R13-05",
        severity: "Low",
        title:
          "The assurance artifacts re-derive the production expression and check one operation at a time, so no test can detect a composition defect",
        disposition: "Accepted",
        note:
          "The per-operation invariant remains useful but is no longer presented as composition-complete. A separate production-wired integration test now composes queue exit, claim, and re-deposit of the same economic position, independently checks restored assets/supply and monotone holder protection, and explicitly pins the accepted protocol-revenue under-collection. Recorded as accepted rather than remediated because the structural limitation is not the kind of thing a regression can close: an artifact that restates the production expression cannot falsify the law it encodes, whatever cases are added around it. Round 14 confirms it is now honestly described rather than fixed, which is the correct disposition.",
      },
      {
        id: "R13-06",
        severity: "Low",
        title:
          "The depositor deferral disclosure arms on one wei of rounding dust, so it renders in the healthy steady state",
        disposition: "Remediated",
        note:
          "The staking warning now requires the global HWM to exceed fee NAV by more than one rate wei. Render regressions assert that a one-wei floor/ceiling gap is silent and a two-wei deferred band is disclosed. The false positive this finding named is genuinely gone. Round 14 finds the tolerance boundary is also the maximal-deferral point, so the corrected predicate is silent exactly where the exposure is largest, carried forward as R14-03, and made the steady state rather than a transient boundary by per-repayment crystallization.",
      },
      {
        id: "R13-07",
        severity: "Low",
        title:
          "The vault implementation is within 1.5% of the contract size limit and the build pipeline has no size gate",
        disposition: "Remediated",
        note:
          "CI now parses forge build --sizes --json and fails if any of the 19 production contracts is missing or exceeds EIP-170. The current sUSDfr runtime is 24,488 bytes, leaving only 88 bytes; the gate makes that maintenance constraint explicit rather than relying on a compiler warning.",
      },
    ],
  },
  {
    slug: "2026-07-30-adr-0031-dual-nav-recheck",
    file: "audits/2026-07-30-adr-0031-dual-nav-recheck.md",
    title: "Protocol fee stack, dual-NAV re-check",
    eyebrow: "Round 12",
    date: "2026-07-30",
    dateLabel: "30 July 2026",
    scope:
      "The dual-NAV remediation of the Round 11 findings: performance-fee impairment, share-flow HWM accounting, backstop replacement, and the queue and invariant assurance surfaces.",
    method:
      "Sixty-four agents, 26 raw candidates, two-lens refutation, arithmetic re-derivation, production-path tracing, evidence reproduction, and a completeness critic.",
    summary:
      "All four prior code findings were closed, but the exit leg still adjusted a performance-NAV-denominated hurdle using assets priced on the higher redemption NAV. That let an exiting holder transfer deferred fee exposure to stayers. The working tree now uses the greater of asset carry and pro-rata carry, fixes the adjacent upgrade and backstop-ordering issues, adds divergent-NAV assurance, and discloses the global deferral risk; independent review of that delta remains pending.",
    findings: [
      {
        id: "R12-01",
        severity: "High",
        title:
          "A junior-supported exit carries the performance hurdle at the redemption price and transfers deferred fee exposure to stayers",
        disposition: "Remediated",
        note:
          "The pre-remediation exit preserved the absolute drawdown by subtracting the physical redemption payout from a hurdle denominated in the lower performance-fee NAV. A later cure therefore charged the same absolute profit after shares had left. The required rule is the greater of physical asset carry and the pre-flow hurdle's pro-rata carry. Round 13 confirms that rule independently: converting the pro-rata carry back into a per-share rate leaves it exactly unchanged, and the maximum is never below it, so the stored per-share high-water mark is monotonically non-decreasing across every exit in every reachable state. The failure direction is now structurally impossible rather than merely absent. Round 13 does find that the entry and exit laws are not composable, filed separately as R13-01, protocol-harming rather than holder-harming.",
      },
      {
        id: "R12-02",
        severity: "Medium",
        title:
          "The queue assurance tier cannot construct or independently judge the production dual-NAV state",
        disposition: "Remediated",
        note:
          "The mock used one slot for both impairment views, the real assessed-source fixture lacked an exit handler, and the legality witness consulted the HWM under test. Round 13 confirms all three are closed: the mock now carries an independently settable performance view: the queue handler can drive the two NAVs apart, and the new invariant derives its reference law without consulting the post-flow high-water mark. A residual remains, the reference law restates the production expression and is evaluated one operation at a time, so a composition defect stays outside its frame. Filed separately as R13-05.",
      },
      {
        id: "R12-03",
        severity: "Medium",
        title:
          "An entrant during a global deferral window can pay performance fees on pre-arrival gains without an exit-impairment signal",
        disposition: "Remediated",
        note:
          "The deposit arithmetic is internally consistent, but the HWM is global rather than per investor. When junior capital makes redemption NAV healthy while fee NAV remains below the hurdle: a new depositor can share a later crystallization. The disclosure now exists on the staking interface, which is the right remedy for a pooled high-water mark that cannot be made per-investor without lots or share classes. Round 13 finds its trigger fires on one wei of rounding dust, so it displays permanently on a healthy vault, filed separately as R13-06.",
      },
      {
        id: "R12-04",
        severity: "Medium",
        title:
          "A legacy proxy with a zero HWM seeds against the lower fee NAV during a junior-covered impairment",
        disposition: "Remediated",
        note:
          "The upgrade-only seed anchored rather than ratcheted, so rebasing performance accounting onto the lower view could turn pre-upgrade value into later profit. The seed now anchors to the higher redemption base, which closes the junior-covered portion of the mismatch, and the added regression pins it. Round 13 finds the senior-marked portion survives, the residual equals the live pending senior mark at seed time, and the anchor that is neutral in both terminal states is the realized asset base. Filed separately as R13-02.",
      },
      {
        id: "R12-05",
        severity: "Medium",
        title:
          "Management/performance sequencing has no discriminating divergent-NAV coverage",
        disposition: "Remediated",
        note:
          "Every prior management-fee test made the two NAV views equal, where the rewritten formula algebraically collapses to the old one. Round 13 confirms the gap is closed: a value-asserting case now runs the management fee at its cap against genuinely distinct views, computing its expectations independently rather than restating the implementation, and verifies management dilution before performance crystallization.",
      },
      {
        id: "R12-06",
        severity: "Low",
        title:
          "Backstop rotation prices elapsed management fees at replacement NAV even when the outgoing dependency is readable",
        disposition: "Remediated",
        note:
          "Always using effects-first ordering is necessary only for repair of an unreadable outgoing backstop. The rotation now probes the outgoing dependency, checkpoints before a healthy rotation, and falls back to effects-first only for one-transaction repair. Round 13 verified the checkpoint pairing by inspection, exactly one open on every path, always followed by the single close, with the no-op early exit skipping both, so the lock cannot strand. The regression added for it is vacuous, however: its fixture never reaches a state in which the outgoing backstop is read. Filed separately as R13-03.",
      },
    ],
  },
  {
    slug: "2026-07-29-adr-0031-remediation-recheck",
    file: "audits/2026-07-29-adr-0031-remediation-recheck.md",
    title: "Protocol fee stack, remediation re-check",
    eyebrow: "Round 11",
    date: "2026-07-29",
    dateLabel: "29 July 2026",
    scope:
      "The remediation of the Round 10 findings, seven production contracts, three changed initializer signatures, a new role, and the deployment and validation scripts, rather than the protocol as a whole.",
    method:
      "Ten lenses over the remediation diff, weighted toward the new bracket-lock and asset-hurdle machinery rather than the original findings. Two adversarial refuters per candidate, one attacking reachability and one redoing the arithmetic from source, then a synthesis pass and a completeness critic.",
    summary:
      "Three of the four Round 10 fixes were properly closed. The fourth reintroduced the same defect class on a different axis: the bracket added to make junior-capacity writes fee-neutral inferred its hurdle adjustment from an observed NAV movement rather than the capital that moved, making the high-water mark non-monotone and producing both an over-charge and a mirror under-charge. Round 12 independently confirmed that all four code findings from this report were closed, while identifying a separate dual-NAV exit defect.",
    findings: [
      {
        id: "R11-01",
        severity: "High",
        title:
          "A bracketed junior-capacity write invalidates a live valuation assessment inside its own window, and the whole assessed discount is written off the fee hurdle",
        disposition: "Remediated",
        note:
          "The risk fingerprint that keeps a governance assessment alive folded the curator pool balance for every class, so a bracketed capacity write killed the assessment inside its own accounting window. The remediation removed capacity-driven HWM mutation entirely and separated performance-fee impairment from live capacity. Round 12 independently confirmed this finding closed.",
      },
      {
        id: "R11-02",
        severity: "High",
        title:
          "The bracket folds a transient impairment-netting movement into a permanent hurdle, so the unbracketed cure is charged as performance",
        disposition: "Remediated",
        note:
          "Junior capacity affected conservative NAV only while exposure existed, but the old bracket wrote that transient movement permanently into the hurdle. The remediation moved temporary capital netting out of the performance-fee base and made the bracket a pure checkpoint/lock. Round 12 independently confirmed this finding closed.",
      },
      {
        id: "R11-03",
        severity: "Medium",
        title:
          "Mirror direction: a capacity top-up during a live impairment permanently over-raises the hurdle and forfeits protocol fees",
        disposition: "Remediated",
        note:
          "This was the mirror of R11-02: a capacity increase could permanently over-raise the hurdle and forfeit protocol fees. Removing all capacity-driven HWM mutation structurally removed both directions. Round 12 independently confirmed this finding closed.",
      },
      {
        id: "R11-04",
        severity: "Medium",
        title:
          "The backstop setter now reads through the backstop it exists to replace, and never probes the incoming address",
        disposition: "Remediated",
        note:
          "The old setter checkpointed through the dependency it needed to replace and did not probe the incoming candidate. The remediation validates the replacement and preserves an effects-first one-transaction repair path for an unreadable outgoing backstop. Round 12 confirmed the finding closed, while separately reporting the healthy-rotation management-fee ordering residual now tracked as R12-06.",
      },
      {
        id: "R11-05",
        severity: "Medium",
        title:
          "The fee-net rate-integrity invariant is blinded twice and cannot fail on any of the above",
        disposition: "Open",
        note:
          "Its handler re-bases its own rate floor whenever fee shares were minted, and does so immediately after the two bracketed capacity writes these findings abuse, so a mint produced by a supposedly fee-neutral operation silently resets the floor it would otherwise violate. Separately, the assertion decides whether a fee was legitimate by comparing against the vault's own high-water mark, interrogating the very variable these findings corrupt. Structurally, the credit-layer fixture also wires the vault directly to the default manager, bypassing the assessed impairment source that deployment installs and validation asserts as mandatory, so every assessment test runs against a zero-NAV vault. The missing property does not depend on the high-water mark at all: a full cure of any impairment must mint zero performance shares regardless of intervening capacity writes.",
      },
      {
        id: "R11-06",
        severity: "Low",
        title:
          "The fee-operation bracket is persistent storage with no expiry, no transaction binding and no governance reset",
        disposition: "Remediated",
        note:
          "While the lock is set: every fee-checkpointed path reverts, which is the entire protocol including the never-pausable loss path. No path in the repository can strand it, all six begin/end pairs are straight-line and atomic within one function, with no try/catch and no divergent branch, so this is hardening rather than a live defect. It is recorded because the failure mode is total and the recovery is an upgrade behind a timelock. Transient storage is available at the project's target EVM version and would make the stranded state unrepresentable. CLOSED by Round 14 verification: `clearStaleFeeOperation()` (sUSDfr) gives timelocked governance an explicit reset for a lock left behind by a faulty trusted module, which is the recovery lever this finding said did not exist. The stuck state itself remains unreachable: every bracket pair is straight-line and atomic within one transaction.",
      },
      {
        id: "R11-07",
        severity: "Low",
        title:
          "The vault is 912 bytes from the contract size limit, which is not enough room for the remediations these findings require",
        disposition: "Open",
        note:
          "Verified independently: 23,664 bytes of runtime bytecode at the optimizer settings the tests and the deployment share, a 3.7% margin, after this change added roughly 660 lines to the file. Every fix the findings above call for lands in this same contract, a separately tracked capacity credit applied at read time, a release path for it, a valuation-regime snapshot across the bracket window, and a clamp. This is a remediation-feasibility constraint, not a gas note. PARTLY OVERTAKEN. The missing-gate half is closed: `tools/check-contract-sizes.mjs` now enumerates all 19 production runtimes in CI and fails closed. The headroom half got WORSE, not better, 912 bytes at the time of this finding, 88 bytes after the Round 14 delta. It stays open on that basis: the constraint this finding identified is now binding rather than merely tight, and any further addition to the vault requires refactoring first.",
      },
      {
        id: "R11-08",
        severity: "Low",
        title:
          "Every fork suite skips while reporting a passing result, including the only production-wired coverage of the new machinery",
        disposition: "Remediated",
        note:
          "183 of 1,097 tests skip without an archive endpoint configured, and each affected suite still prints a passing result, which reads green in a scroll-back. That matters for this change specifically: the governance fork suite is the only place the new fee machinery meets the production wiring rather than a fixture that bypasses it. The 914 passing contract tests and the 912-byte size margin were both reproduced exactly; the fork and deployed-network runs could not be reproduced in the review environment. CLOSED as an environment issue rather than a code one: the fork tier executes 181/181 when an archive endpoint is configured. It skips only in review environments without one, which is what the original finding actually observed.",
      },
    ],
  },
  {
    slug: "2026-07-29-adr-0031-fee-stack",
    file: "audits/2026-07-29-adr-0031-fee-stack.md",
    title: "Protocol fee stack, ADR-0031",
    eyebrow: "Round 10",
    date: "2026-07-29",
    dateLabel: "29 July 2026",
    scope:
      "The introduction of protocol-level management and performance fees on the senior vault: the vault itself, the waterfall, the default manager, the redemption queue, the vault interface and the configuration library.",
    method:
      "Nine independent lenses over the diff, fee arithmetic and rounding, high-water-mark lifecycle, reentrancy and callbacks, liveness under the new universal checkpoint dependency, ERC-4626 conformance, checkpoint placement in each consumer, invariant regressions, upgrade and deployment wiring, and economic timing games. Two adversarial refuters per candidate, then synthesis and a completeness critic.",
    summary:
      "Twenty-nine candidates, fifteen survivors, consolidated to four code defects and six findings about the tests. The headline defect is that the fee-free hurdle ratchet was keyed on a per-share rate while the hurdle it protects is proportional to share supply, so it was not asset-preserving during a live impairment and the eventual cure was charged as profit. The more uncomfortable half of the round was the test suite: the entire exit half of the change had no value-asserting test, and the rate-integrity invariant had been weakened rather than the code fixed.",
    findings: [
      {
        id: "FEE-01",
        severity: "High",
        title:
          "The fee-free hurdle ratchet targeted a per-share rate, not an asset-preserving hurdle, so the cure of an unrealized impairment was charged as performance",
        disposition: "Remediated",
        note:
          "The hurdle the fee calculation consumes is proportional to share supply, but share flows move assets, and during a live impairment they move them at a basis that differs from the hurdle's, because entry prices on realized NAV and exit on conservative NAV. On exit the ratchet was a complete no-op while the hurdle shrank with supply; on deposit it fired but reset the hurdle to the conservative base plus principal, destroying the accumulated drawdown. Either way the fee-free cushion was consumed and the eventual cure booked as profit, roughly fifteen thousand units on a one-million vault carrying a three-hundred-thousand mark, with no yield earned and no loss realized. Fixed by maintaining the mark as an asset hurdle carried by exactly the principal that moves. Re-verified in Round 11.",
      },
      {
        id: "FEE-02",
        severity: "Medium",
        title:
          "Junior-capacity writers moved the fee base with no checkpoint and no fee-free ratchet",
        disposition: "Remediated",
        note:
          "The conservative NAV nets declared exposure against the live curator first-loss pool and backstop capacity, but neither of those contracts checkpointed the vault and the backstop setter had no checkpoint at all. Posting first-loss capital during a live mark raised the NAV with nothing earned, a permissionless checkpoint booked it as profit, and withdrawing the capital returned it in full, with the fee shares not clawed back. Fixed with a bracket around every junior-capacity write, gated by a new role granted to exactly three module contracts. The checkpoint half is correct; the hurdle re-anchoring the same fix added is the subject of Round 11 findings R11-01 through R11-03.",
      },
      {
        id: "FEE-03",
        severity: "Low",
        title:
          "Every fee setter crystallized before writing, so the recipient rotation could not escape a blocked recipient",
        disposition: "Remediated",
        note:
          "Because the fee checkpoint mints to the stored recipient: a recipient whose mint is denied by compliance state made the setter that exists to replace it unusable, along with every other fee-checkpointed path. Reaching the state required two privileged writes across two roles, one of which deliberately deletes the guard that keeps a list error from bricking the cascade, so it was rated Low. Fixed by writing the new recipient before crystallizing, and by enforcing the exemption invariant in the initializer rather than leaving it a deployment convention.",
      },
      {
        id: "FEE-04",
        severity: "Low",
        title:
          "The yield-delivery window was not closed by any vault-side lock, and the documentation claiming otherwise was false",
        disposition: "Remediated",
        note:
          "Between yield being minted into the vault and the vault being told to defer its recognition: the vault was transiently over-valued. The documentation credited a reentrancy guard belonging to a different contract entirely. Unreachable as wired, because the shipped points module makes no state-changing external call, so it was rated Low, but the unconditionally true defect was the false mitigation claim, which would cause a future reviewer to dismiss the window. Fixed with a real vault-side lock acquired under the same condition that later releases it, and the documentation corrected.",
      },
      {
        id: "FEE-05",
        severity: "High",
        title:
          "The entire exit half of the change had no value-asserting test",
        disposition: "Remediated",
        note:
          "Six exit-side code sites were modified. The fee unit suite, seven hundred lines, twenty-four tests, contained no redemption, withdrawal or queue request; it never burned a share. Of every test file exercising an exit, none referenced any fee state, and the queue's stateful campaign compared the rate against a constant captured at construction so it could not observe fee dilution at all. This is line coverage without assertions on the accounting core, and it is the direct reason FEE-01 shipped green. Fixed: exit-side fee tests now exist in the unit, integration and queue-invariant tiers.",
      },
      {
        id: "FEE-06",
        severity: "High",
        title:
          "The rate-integrity invariant was weakened rather than the code fixed, and the management fee was never exercised statefully",
        disposition: "Remediated",
        note:
          "The quantitative bound sat behind a condition that switched itself off whenever a management fee was due, so the invariant would have accepted an arbitrary collapse of the exchange rate, including to zero. No handler in any campaign ever enabled the management fee, so the branch was simultaneously dead and unbounded, the failure mode the standard names explicitly. Fixed: the management branch is bounded and a handler now fuzzes the rate. Round 11 finds the same invariant blind in a different way (R11-05).",
      },
      {
        id: "FEE-07",
        severity: "Medium",
        title:
          "The integration tier for the whole fee stack was a single thirty-eight-line happy path",
        disposition: "Remediated",
        note:
          "One test: one facility, one deposit, one repayment, one checkpoint, four assertions. No default, no past-due mark, no realized loss, no impairment source, no queue, no second depositor, and the management fee asserted to be zero and never enabled. Moving a checkpoint to the wrong side of a state change left it fully green. Fixed: the integration suite now covers the workout, queue-exit and capacity round-trip flows.",
      },
      {
        id: "FEE-08",
        severity: "Medium",
        title:
          "The malformed-return branch of the impairment-source probe had no mock able to reach it",
        disposition: "Remediated",
        note:
          "The probe distinguishes three non-readable shapes; only two were tested, because every mock in the tree returned a full word. The untested one is the branch deciding whether a source that answered can be discarded, the difference between rejecting a candidate at installation and successfully unwiring a live mark. Fixed: malformed-return mocks now exist and exercise both the installation rejection and the emergency-clear path.",
      },
      {
        id: "FEE-09",
        severity: "Low",
        title:
          "The emergency impairment-source clear ratchets to the un-impaired rate and permanently forgives fees on the live mark",
        disposition: "Accepted",
        note:
          "Clearing an unreadable source cannot checkpoint first, so the fee-free ratchet lifts the hurdle by whatever impairment the broken source was reporting; re-installing a working source that reports the same impairment leaves the vault unable to charge a fee it is owed. Opposite sign to the other findings, the protocol under-collects rather than over-collects, so it is not a user-funds risk. Accepted deliberately: the true mark is unreadable at that moment, and it is documented as an incident-only governance action requiring the waived amount to be quantified.",
      },
      {
        id: "FEE-10",
        severity: "Medium",
        title:
          "Every fork suite skips, including the only test routing the fee setters through the real governor and timelock",
        disposition: "Remediated",
        note:
          "The fork tier requires an archive endpoint and skips without one, while still reporting a passing result. The governance fork test is the only coverage of the fee setters through the real timelock and of the atomic exemption-then-rotation batch that mitigates FEE-03. Carried forward as R11-08. CLOSED alongside R11-08: the fork tier executes in full when an archive endpoint is configured, including the governance suite that routes the fee setters through the real governor and timelock.",
      },
    ],
  },
  {
    slug: "2026-07-29-full-system-round-9",
    file: "audits/2026-07-29-full-system-round-9.md",
    title: "Full-system audit, round nine",
    eyebrow: "Round 9",
    date: "2026-07-29",
    dateLabel: "29 July 2026",
    scope:
      "The entire codebase again, every production contract and all frontend functionality, plus the fixes from the two preceding rounds.",
    method:
      "Nine module surfaces reviewed twice by independent agents with opposing briefs, plus four new lenses that follow a single entity through its whole life rather than reviewing by module. Then two adversarial refuters per candidate and a completeness critic.",
    baseline: "48e1325",
    archive: "audit-reports/FULL_SYSTEM_AUDIT_2026-07-28.md (round 9 addendum)",
    summary:
      "Eighty-four candidates, consolidated to thirty, of which two were dropped outright by the critic: one would have recommended undoing an earlier fix. No Critical or High finding, and nothing that reaches a loss of funds, an unauthorized mint, a backing break, a cascade inversion or a compliance bypass. About half of what survived is documentation drift. The round's clearest new defect was a residual on the previous round's own remediation, and the honest conclusion is that source review has now plateaued.",
    findings: [
      {
        id: "C-11",
        severity: "Medium",
        title:
          "Raising the redemption floor during a live settlement could permanently freeze the queue | a residual on the previous round's fix",
        disposition: "Remediated",
        note:
          "The previous round stopped a settlement committing while it could never reach the economic floor. It did not stop the floor moving underneath a settlement that had already legitimately committed. Because the liquidity budget is captured once and can only shrink, raising the floor mid-settlement made both guards permanently unsatisfiable, the same dead end reached through a governance setter rather than a chunk boundary. The previous round's own regression test could not catch it, because it sets the floor before settling. Fixed by capturing the floor alongside the budget when a settlement opens, so a live settlement is judged against the parameters it opened under and a change takes effect on the next one. Proven reachable against the unfixed code before the fix was written.",
      },
      {
        id: "C-07",
        severity: "Medium",
        title:
          "A reserve-level write-down has no cascade absorber, and the backing assertion then blocks ordinary operation",
        disposition: "Open",
        note:
          "One reserve primitive lowers backing without a paired token burn and without asserting the backing invariant, the exception to the pairing rule the design documents state. Because the protocol operates at zero headroom, any resulting shortfall then blocks minting, redemption, yield recognition and servicing until governance acts, and the loss cascade has no path to absorb a loss that occurred at the reserve layer rather than in the loan book. The primitive currently has no callers. One part of the original filing was withdrawn: relaxing the backing assertion to permit delta-neutral redemption was already considered and rejected in an ADR, because it inverts the loss cascade.",
      },
      {
        id: "C-19",
        severity: "Medium",
        title:
          "CONTESTED: the yield cap leaves a healthy vault at the exact top of the accepted skim band",
        disposition: "Open",
        note:
          "Published as contested because it turns on the precise reading of an accepted trade-off rather than on disputed code. The entry guard closes only when the withheld stream is strictly greater than a set multiple of vault assets, and the cap introduced two rounds ago sets the stream to exactly that multiple, so entry stays open at the boundary rather than inside it, and a depositor arriving at that instant shares in yield already earned by incumbents. The band itself is an accepted residual from an earlier round; what is new is that a healthy vault now sits at its very top by construction rather than transiently. This is a calibration question for economic review, not a coding error.",
      },
      {
        id: "C-01",
        severity: "Low",
        title:
          "The storage-layout check the upgradeability ADR asserts did not exist, and the per-slot test added last round covered one namespace of sixteen",
        disposition: "Remediated",
        note:
          "Found independently by five reviewers, each arriving from a different contract. The previous round's response to a storage-layout risk pinned exactly one struct, leaving fifteen namespaces in the prior posture, and the verification command the contracts' own comments prescribe reports nothing for this storage pattern, because these contracts declare no ordinary state. Fixed by a check that compares the field order and types of every namespaced and array-element struct against a committed baseline, wired into the pipeline: inserts, reorders, retypes and deletions fail; extending a namespaced root at its tail passes; any growth of an array-element struct fails, because those are laid out contiguously. The ADR now describes the check that exists.",
      },
      {
        id: "C-02",
        severity: "Low",
        title:
          "Pausing the attestation oracle transitively halts the loss cascade while leaving both exits open at an unimpaired price",
        disposition: "Open",
        note:
          "Loss realization, payment recording and past-due curing each require a freshly minted attestation, and the submission path is pausable. A guardian pause therefore suspends loss recognition, which the design documents describe as never pausable, while redemption and the queue continue pricing against a book that cannot be marked down. The asymmetry is the finding: not that the pause exists, but that it stops the marking without stopping the exiting.",
      },
      {
        id: "C-03",
        severity: "Low",
        title:
          "The token pause halts every inflow but leaves the redemption path draining the reserve",
        disposition: "Open",
        note:
          "Burns deliberately bypass the pause so the loss cascade cannot be frozen, a fix from an earlier round. The consequence is that a token pause stops minting, staking and yield routing while the direct redemption path, which is a burn plus a transfer out of reserves, stays fully open. The compensating symmetry the governing documents rely on no longer holds, and neither contract consults the other's pause state.",
      },
      {
        id: "C-05",
        severity: "Low",
        title:
          "The outflow cap restarts the vesting clock on every qualifying settlement, deferring yield already earned",
        disposition: "Open",
        note:
          "A residual on the previous round's fix. The cap does not merely clamp the retained amount, it re-stretches it over a fresh full vesting window; and because the inflow cap leaves no slack at the boundary, an ordinary settlement re-triggers it. Permissionless settlement can therefore defer recognition of yield that has already been realized. The deferral is conservative in direction and the retained amount is non-increasing, but it does not converge as quickly as assumed when the fix was written.",
      },
      {
        id: "C-06",
        severity: "Low",
        title:
          "The outflow cap runs after assets leave, so equal-ranking exits in one settlement can be priced differently",
        disposition: "Open",
        note:
          "The same fix places its re-cap after the withdrawal completes, and the settlement loop re-reads the vault price on every fill. A later fill in the same settlement is therefore priced against a value the previous fill's own re-cap stepped up. The strict-FIFO head, the position that waited longest, is priced worst. Display-neutral and small in ordinary conditions, but it breaks the pari-passu expectation within a single settlement.",
      },
      {
        id: "C-09",
        severity: "Low",
        title:
          "Documentary mint-gate attestations are existence-only and can be satisfied in advance for facilities that do not exist yet",
        disposition: "Open",
        note:
          "The submission path accepts any facility identifier, never checks that the facility exists, and imposes no payload requirement on the documentary kinds. The mint gate then asks only whether an attestation of that kind exists at the identifier about to be minted. The binding that does hold is the separate terms attestation, which is unconditional, so the residual is that the documentary facts are proved to exist rather than proved to be about the facility in question.",
      },
      {
        id: "C-10",
        severity: "Low",
        title:
          "A non-renewable facility that outlives its maturity can never be amended again, and its full balance stays permanently markable",
        disposition: "Open",
        note:
          "Found by the facility-lifetime lens, and visible only if a facility is kept alive past its maturity. Only two functions can move a schedule forward: one cannot push past maturity, and the other rejects any amendment that would extend a non-renewable facility. Once maturity has passed, every admissible amendment necessarily exceeds it, so the workout has no on-chain path to reschedule, while the outstanding balance remains permissionlessly assertable into the senior impairment mark.",
      },
      {
        id: "C-13",
        severity: "Low",
        title:
          "The impairment-source setter accepts any address with no interface probe, on a read path that deliberately does not swallow failure",
        disposition: "Remediated",
        note:
          "The setter performs no code or interface check, and the read path deliberately refuses to catch failure, individually correct, since silently substituting zero impairment would be worse. Together they mean one governance mis-wire freezes every senior exit price until a second timelocked proposal lands. Same shape as an already-published finding about a sibling setter. CLOSED by the ADR-0031 work: `sUSDfr.setImpairmentSource` now runs `_validateImpairmentSource`, a bounded two-selector ABI-shape probe that also enforces the ordering invariant between the two impairment views, and `clearUnreadableImpairmentSource` provides the paired recovery. Verified in Round 14.",
      },
      {
        id: "C-14",
        severity: "Low",
        title:
          "Latent: re-pointing the vault at a new redemption queue would strand every position held by the old one",
        disposition: "Open",
        note:
          "Queued shares are held in the queue's own custody, and the vault admits only the currently configured queue as a caller. Pointing the vault at a replacement therefore leaves the old queue holding shares it can no longer redeem, with no cancel and no rescue path for the positions inside it. Unreachable today; reachable on an ordinary queue migration.",
      },
      {
        id: "C-16",
        severity: "Low",
        title:
          "Latent: a class activated without its attestation mask would originate and fund with the documentary checks skipped entirely",
        disposition: "Open",
        note:
          "The mint gate reads the required-attestation mask and iterates it without requiring it to be non-empty, so a class whose mask was never set reads zero and the loop body never runs, on both the origination and the funding gate. The unconditional terms attestation still applies, so the economic binding survives; the documentary requirements would not. Reachable through a routine governance sequencing mistake rather than an attack.",
      },
      {
        id: "C-17",
        severity: "Low",
        title:
          "The headline collateral ratio divides a numerator containing idle reserves by loan principal alone",
        disposition: "Open",
        note:
          "A frontend-to-contract reconciliation defect. The numerator mixes loan collateral with idle reserves, which back the portion of supply that is not on loan, while the denominator is deployed principal only, so the displayed coverage of the loan book rises without bound as the book shrinks. A correctly-based coverage figure is already computed nearby and discarded.",
      },
      {
        id: "C-18",
        severity: "Low",
        title:
          "A receipt-wait timeout discards the transaction hash and re-arms a one-click duplicate of a non-cancellable action",
        disposition: "Open",
        note:
          "The error state carries no transaction hash, unlike the pending and success states. On a receipt timeout, set well below the underlying library's own default, the transition destroys the only reference the user had to a transaction that may still land, and re-enables the button. For a queue request, which cannot be cancelled or withdrawn, that invites a duplicate irreversible entry.",
      },
      {
        id: "C-20",
        severity: "Low",
        title:
          "Origination events emit only a commitment hash, so maturity and the off-chain reference appear in no event",
        disposition: "Open",
        note:
          "The engineering rules require the on-chain register to be reconstructable purely from events. The origination and amendment events carry a 32-byte terms commitment rather than the terms themselves, so the maturity date and the off-chain document reference are not recoverable from the log, while the comment directly above the event, and an earlier published review, both state that the full terms are emitted.",
      },
      {
        id: "C-21",
        severity: "Low",
        title:
          "The origination fee is read from mutable governance storage at funding time and is not part of the attested terms",
        disposition: "Open",
        note:
          "The fee is applied from live governance storage when funds are disbursed, and the borrower receives principal less that fee while the facility is booked at full principal. The signed terms bundle, which an earlier round extended specifically so the economic terms are quorum-bound, does not include it. So the cash actually disbursed is the one parameter the binding does not cover.",
      },
      {
        id: "C-22",
        severity: "Low",
        title:
          "The funding gate re-checks only the time-sensitive class parameters, so tightening the draw ceiling or tenor cap does not bind an already-originated facility",
        disposition: "Open",
        note:
          "Origination enforces the class loan-to-value ceiling and maximum tenor; the funding gate reloads the same class parameters and re-checks activity, maturity, the payment date, attestations, the terms binding and mark freshness, but never re-reads those two. A facility originated under looser limits can therefore still be funded after governance tightens them.",
      },
      {
        id: "C-23",
        severity: "Low",
        title:
          "The directional assessment binding was applied to the backstop only, so a trivial curator top-up still voids a live recovery assessment",
        disposition: "Open",
        note:
          "An earlier remediation made global backstop capacity a directional comparison, an increase tolerated, a decrease failing closed, precisely so that a permissionless contribution could not void a depositor-favourable assessment. Per-class curator capacity was deliberately left on the exact-match side, so the same class of nuisance survives through a different pool.",
      },
      {
        id: "C-24",
        severity: "Low",
        title:
          "Curator first-loss is shown as one blended percentage although absorption is strictly per-class and non-fungible",
        disposition: "Open",
        note:
          "The dashboard reads each class pool individually, sums them, and divides by the whole book. On chain a loss draws only against its own class pool and cannot reach another. The blended figure therefore overstates subordination for any class whose pool is thin relative to its exposure.",
      },
      {
        id: "C-25",
        severity: "Low",
        title:
          "The transparency dashboard re-reads the entire event history on every poll, and blanks its panels while it does",
        disposition: "Open",
        note:
          "The same class of defect fixed on a sibling panel two rounds ago, still present here across five event streams: no cursor, a full re-read from the deployment block every minute, both panels reset to a loading state first, and no cancellation of a superseded sweep. Request volume grows linearly with chain age.",
      },
      {
        id: "C-26",
        severity: "Low",
        title:
          "The error-decoding drift guard never checks contracts against the interface, so a newly added custom error renders as raw hexadecimal",
        disposition: "Open",
        note:
          "The guard verifies that published copy matches the interface and that the interface matches the contracts, but not that the contracts are fully represented in the interface. One error added to the vault is already missing, and it is raised on the application's own staking path, where its own documentation says it exists precisely so the revert carries a specific, readable reason.",
      },
      {
        id: "C-27",
        severity: "Low",
        title:
          "Latent: the testnet address table is hand-maintained with no binding to the deployment manifest",
        disposition: "Open",
        note:
          "For production every address is bound to the manifest by several independent checks. For the testnet and local profiles the verification returns before the manifest is opened, and the address table is a hand-maintained duplicate that partial environment overrides can silently mix across two deployments. Reachable on the next redeploy rather than today.",
      },
      {
        id: "C-04",
        severity: "Informational",
        title:
          "A workout recovery on a defaulted facility can be booked entirely as interest, leaving the impaired principal fully marked",
        disposition: "Open",
        note:
          "Distribution admits defaulted facilities and routes the interest leg through the identical path a performing loan uses, while every piece of recovery bookkeeping sits behind a non-zero principal condition. Nothing requires a post-default receipt to be booked as principal. The discretion belongs to a trusted role and overlaps an already-accepted finding about servicer discretion; recorded because the direction of the error disadvantages the junior layers.",
      },
      {
        id: "C-12",
        severity: "Informational",
        title:
          "The timelock delay is shorter than the only available exit, so the promised exit window does not exist in practice",
        disposition: "Open",
        note:
          "Two ADRs and the access-control matrix state that the timelock gives holders time to exit before a change takes effect. The only senior exit is queue-gated at three weeks and the staked-token exit at three weeks, against a two-day minimum delay. The protection is real as visibility and unreal as an exit window; the documents should say which one they mean.",
      },
      {
        id: "C-28",
        severity: "Informational",
        title:
          "The compliance check exempts every burn before consulting the sender's sanctions status",
        disposition: "Open",
        note:
          "Burns return permitted without checking the sender, so that the loss cascade and settlement can never be blocked, a sound reason. The exemption is nonetheless unconditional on the sender rather than scoped to the cascade, so any future user-callable burn path would inherit it. Latent, and a property of the token rather than of the cascade.",
      },
      {
        id: "C-30",
        severity: "Informational",
        title:
          "The per-event backstop coverage cap is never exercised at a fractional value by any test",
        disposition: "Open",
        note:
          "The mock backstop's cap setter has no callers anywhere, so every campaign built on that mock runs with the cap effectively unlimited and the mock's capacity degenerates to its raw balance. The cap is a real production control; the suite has never exercised it at a binding value. A test-fidelity gap rather than a contract defect, and adjacent to a test-strength item already open from an earlier round.",
      },
    ],
  },
  {
    slug: "2026-07-28-remediation-recheck",
    file: "audits/2026-07-28-remediation-recheck.md",
    title: "Remediation re-check",
    eyebrow: "Round 8",
    date: "2026-07-28",
    dateLabel: "28 July 2026",
    scope:
      "The twelve Medium and Low remediations from Round 7, plus everything they touched, eight change clusters across the contracts, the frontend, the build gate and the test suite.",
    method:
      "Two independent lenses per cluster, one asking whether the fix closes its finding, one hunting for what the fix broke, neither seeing the other, then two adversarial refuters per candidate, then a completeness critic. The two most serious findings were then proven by executable proof-of-concept before being fixed.",
    baseline: "973664a, then fixed and re-verified at f2b1e77",
    archive: "audit-reports/FULL_SYSTEM_AUDIT_2026-07-28.md (§ re-check)",
    summary:
      "A dedicated re-audit of the previous round's fixes, on the principle that a remediation pass is itself a change that can introduce defects. It found exactly that: one of the twelve fixes had introduced a Medium liveness regression that could permanently freeze the only sUSDfr exit. That regression, and one further residual, were reproduced by executable proof before being fixed rather than argued from source. All five findings are now remediated, along with the three structural gaps the critic refused to sign off on.",
    findings: [
      {
        id: "RC-01",
        severity: "Medium",
        title:
          "A settlement that could never reach the economic floor was allowed to commit, permanently freezing the redemption queue",
        disposition: "Remediated",
        note:
          "Introduced by the Round 7 fix that stopped a dust-sized fill consuming the epoch heartbeat. The amount distributed accumulates across the chunks of one settlement, while the liquidity budget is captured once and can only shrink, so a chunk that stopped on its per-call request limit could commit a settlement whose maximum possible total was already below the floor. No later chunk could then satisfy the guard, and because the abandon path reverts, it undid its own release of the settlement lock. Proven by executable test before the fix: once latched, refilling the treasury and waiting a month still failed, and only a governance change to the floor recovered it. No funds were ever at risk and already-settled claims stayed claimable, but the sole senior exit could stall indefinitely. The guard now tests whether the floor is still REACHABLE and refuses to commit an unsatisfiable settlement, so the transaction rolls back and the next call starts fresh against live liquidity. A first attempt at the fix was rejected by the invariant suite for over-blocking legitimate partial settlements.",
      },
      {
        id: "RC-03",
        severity: "Low",
        title:
          "The yield cap left the vault exactly on the entry-guard boundary, so an ordinary settlement could close senior entry",
        disposition: "Remediated",
        note:
          "The Round 7 fix capped a yield stream at the largest share the guard tolerates, which left zero margin. Assets leaving through the queue then shrank the base beneath an unchanged stream and closed the only senior entry point, reintroducing the original defect through a different door. Reaching it requires a yield delivery landing against an already-eligible queued request, which is routine. The boundary rule is now a single shared routine applied on both sides, when yield arrives and when assets leave, so the guard's condition holds at all times. The first regression test written for this was vacuous and passed against the unfixed code; the corrected version fails against it, which is how it was caught.",
      },
      {
        id: "RC-04",
        severity: "Low",
        title:
          "The collateral panel's own footnote still described the valuation method the previous round removed",
        disposition: "Remediated",
        note:
          "The computation was corrected in Round 7 but the sentence beneath it was not, so the page explained itself using the superseded method. It now states that receivable collateral scales live outstanding principal by the signed loan-to-value, so the reference amortizes with the loan and falls on a write-down.",
      },
      {
        id: "RC-05",
        severity: "Low",
        title:
          "Resetting a card abandoned an in-flight transaction, so an on-chain failure could go unreported",
        disposition: "Remediated",
        note:
          "Switching redemption mode reset both write flows, and the reset invalidated any continuation still waiting on a submitted transaction. A revert could therefore be swallowed while the card sat idle and the transaction was live on-chain. Reset now refuses while a write is simulating, awaiting signature, or pending, and the control that triggers it is disabled for the duration.",
      },
      {
        id: "RC-06",
        severity: "Informational",
        title: "Namespaced storage layout was guarded by review alone, with no automated check",
        disposition: "Remediated",
        note:
          "The previous round grew an upgradeable contract's storage from five fields to seven, and nothing in the repository or the pipeline verified layout. Because this protocol's contracts use namespaced storage, standard layout inspection reports nothing, so the gap was invisible. A regression test now pins every field to its exact slot and fails on any insertion or reordering: the failure mode that would silently reinterpret live state on an upgrade, and the only change in that batch whose worst case is severe.",
      },
      {
        id: "RC-07",
        severity: "Informational",
        title:
          "Frontend remediations were pinned only by searching their own source text",
        disposition: "Remediated",
        note:
          "Several fixes were guarded by assertions that a file contained a particular string, which a later edit can satisfy while restoring the defect. The redemption hold's arithmetic has been moved into a small shared module and is now pinned by tests that check computed values against the contract's own rule, including the boundary second and the requirement that an unloaded value never silently defaults to zero. A related display defect was fixed in passing: a wait of under a minute rendered as zero minutes, which reads as no wait at all beside a lock-up. Component rendering itself remains untested: that would need a browser test harness the project does not have.",
      },
      {
        id: "RC-08",
        severity: "Informational",
        title:
          "The pipeline was narrower than the project's own engineering rules require",
        disposition: "Remediated",
        note:
          "Continuous integration ran the default test profile only. It now also enforces formatting, treats lint warnings as failures, checks dependency advisories, runs static analysis that fails on high-severity findings and always publishes its report, and runs the heavy stateful-fuzzing profile in a dedicated job, a profile the configuration already claimed was used here and was not. Three gaps are stated rather than closed: there is no static-analysis baseline to compare against, so a new low or medium finding does not fail the build; coverage still runs manually before a release; and the environment-gated fork suites, including the loss-cascade and deployment-validation tests, do not run in the pipeline.",
      },
    ],
  },
  {
    slug: "2026-07-28-full-system",
    file: "audits/2026-07-28-full-system.md",
    title: "Full-system multi-pass audit",
    eyebrow: "Round 7",
    date: "2026-07-28",
    dateLabel: "28 July 2026",
    scope:
      "Every production contract and all frontend functionality, 9,148 lines of Solidity across twenty implementation contracts, 7,303 lines of frontend, plus deployment, validation and configuration tooling.",
    method:
      "Nine surfaces, each reviewed twice by independent agents with different briefs and no sight of each other's work, then two adversarial refuters per candidate, one on mechanism accuracy, one on consequence and reachability, then a completeness critic.",
    baseline: "33713ec (clean working tree). Read-only: nothing was executed.",
    archive: "audit-reports/FULL_SYSTEM_AUDIT_2026-07-28.md",
    summary:
      "A full re-audit of the whole system after the Round 6 remediations, six rounds in. Eighteen independent reviewers raised 71 candidates; these merged to 30, and every one then faced two refutation attempts. All 30 mechanisms held, but 22 had their consequence corrected downward, four filed Mediums ended as Informational. No Critical or High finding. Nothing breaks the backing invariant, inverts or skips the loss cascade, bypasses the mint gate or compliance, over-distributes the queue, or reaches an unauthorized mint. Post-audit, all two Medium and ten Low findings were remediated and verified; the remaining 18 Informational findings retain their original dispositions.",
    findings: [
      {
        id: "FRV-FS-01",
        severity: "Medium",
        title:
          "Servicing dead end: once a facility's next payment date equals its maturity, any performing receipt that leaves residual principal reverts",
        disposition: "Remediated",
        note:
          "Remediated after the audit. WaterfallEngine now treats only the exact terminal schedule state, current due equals maturity and the attested next due also equals maturity, as a no-op. Every non-terminal receipt still passes through ClaimBridge's strict monotonic due-date guard. Regressions prove interest-only and partial-principal receipts remain serviceable at maturity, prove an unchanged pre-maturity due date still reverts atomically, and walk one facility through thirteen consecutive receipts to and through the maturity clamp. The complete post-remediation contract run passed 865 tests with zero failures; 182 environment-gated fork tests were skipped by the unconfigured run.",
      },
      {
        id: "FRV-FS-02",
        severity: "Medium",
        title:
          "The redeem card does not disclose the 21-day minimum hold before an irrevocable, non-cancellable queue entry",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The frontend ABI now exposes redeemCooldown, eligibleToSettleAt and RedeemCooldownSet. The card reads the live configured cooldown, labels the one-day epoch timer only as a settlement heartbeat, states that FIFO and liquidity can extend the wait, and will not submit a queue request until the live cooldown has loaded and the user explicitly acknowledges that the entry cannot be cancelled or withdrawn. Every queued position renders first eligibility from requestedAt plus the live cooldown. The stale hardcoded error copy was corrected. Frontend logic, 332 contract↔UI synchronization checks, lint, TypeScript and the production build all passed.",
      },
      {
        id: "FRV-FS-03",
        severity: "Low",
        title:
          "Vault entry closes when one yield distribution exceeds three times the staked base | a ratio the protocol does not couple to anything",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The vault now caps the amount that may remain in the vesting stream against the live staked base and recognizes any excess immediately as an upward-only NAV step, with a dedicated YieldInstantlyRecognized event. A healthy oversized receipt therefore cannot close entry, ordinary receipts remain smoothly vested, and the post-loss anti-skim guard remains effective. A deterministic low-staking/high-interest regression and the credit invariants passed.",
      },
      {
        id: "FRV-FS-04",
        severity: "Low",
        title:
          "An unprivileged dust contribution to backstop coverage can void a live recovery assessment",
        disposition: "Remediated",
        note:
          "Remediated after the audit. Assessment validity now separates risk state from global backstop capacity and snapshots both. A permissionless capacity increase leaves the assessment active, while a decrease below the snapshot, a curator-pool change, or any book/default revision still invalidates it conservatively. Storage additions are append-only. Unit, integration and a real SGrove dust-contribution regression passed.",
      },
      {
        id: "FRV-FS-05",
        severity: "Low",
        title:
          "The queue's anti-starvation heartbeat tests for exactly zero distribution, so a dust-sized fill still consumes the epoch",
        disposition: "Remediated",
        note:
          "Remediated after the audit. A pending queue now rolls back rather than advancing when aggregate settlement value is below the governed minimum economic value. A drained final tail may still complete, and the independent zero-distribution guard remains active when the entry floor is set to zero. Deterministic dust and zero-floor regressions plus 256×128-call queue invariants passed.",
      },
      {
        id: "FRV-FS-06",
        severity: "Low",
        title:
          "A wallet-side Cancel or Speed Up is reported as a confirmed transaction, linking to a hash that was never mined",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The shared write flow handles receipt replacement explicitly: cancellation or replacement by a different call is an error, while same-call repricing succeeds with the replacement transaction hash that actually mined. Contract-to-UI synchronization tests pin both branches.",
      },
      {
        id: "FRV-FS-07",
        severity: "Low",
        title:
          "The gross-collateral tile values receivables at origination principal against a live outstanding balance",
        disposition: "Remediated",
        note:
          "Remediated after the audit. A receivable facility's reference collateral is now derived from live outstanding principal divided by its LTV. The numerator and denominator therefore amortize together, and a principal write-down cannot make displayed coverage rise. Logic tests pin the invariant.",
      },
      {
        id: "FRV-FS-08",
        severity: "Low",
        title:
          "The position panel prices a holding at the deposit rate rather than the exit rate while an impairment is declared",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The position and gain tiles now read previewRedeem and explicitly label the value as current exit NAV, matching the impairment-netted value the queue would pay rather than the deposit conversion rate.",
      },
      {
        id: "FRV-FS-09",
        severity: "Low",
        title:
          "The production build verification gate lives in a lifecycle hook that routine build invocations skip",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The receipt-bound verifier runs from Next's own production-build phase as well as npm prebuild, so direct next build cannot bypass it. GitHub Actions now runs the contract suite and frontend tests, lint, TypeScript and production build. No production receipt was fabricated before deployment: a mainnet build remains blocked until the real ceremony supplies the approved manifest and receipt.",
      },
      {
        id: "FRV-FS-10",
        severity: "Low",
        title:
          "The build-profile selector falls through to the testnet profile when its chain variable is unset, and the verification is conditioned on that same variable",
        disposition: "Remediated",
        note:
          "Remediated after the audit. NEXT_PUBLIC_CHAIN_ID is mandatory in both frontend configuration and the build verifier. An unset profile fails immediately; an explicit negative probe and production build both passed.",
      },
      {
        id: "FRV-FS-11",
        severity: "Low",
        title:
          "An in-flight write is not cancelled when the account changes, so its result lands on the newly-selected account",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The shared write flow is bound to the submitting account and a generation counter. Account switches invalidate all pending continuations; current connector identity is rechecked after asynchronous boundaries, preventing stale status or success callbacks from landing on the new account.",
      },
      {
        id: "FRV-FS-12",
        severity: "Low",
        title:
          "The realized-annualized figure divides cumulative income since deployment by the vault's current asset base",
        disposition: "Remediated",
        note:
          "Remediated after the audit. The invalid cumulative-income/current-assets annualization was removed. The panel retains current expected yield, projected position income, realized income history and the observation period without presenting a rate whose denominator changes independently of its numerator.",
      },
      {
        id: "FRV-FS-13",
        severity: "Informational",
        title:
          "The per-state concentration dimension is optional at origination and silently unmeasured when omitted",
        disposition: "Open",
        note:
          "Origination requires a non-zero borrower identifier but not a non-zero state identifier, and every registry path that would measure, limit or disclose state exposure short-circuits on zero. A facility booked without one is therefore exempt from the per-state limit and contributes nothing to it, and because there is no key to query, no breach or drift event can ever fire. Inert on the current testnet ramp, where all limits are open; live on the production configuration, which sets a real state limit. Class and borrower limits continue to bind, so this is the loss of one of three diversification controls rather than of the control itself.",
      },
      {
        id: "FRV-FS-14",
        severity: "Informational",
        title:
          "The payment interval is stored and attested but never enforced by any state transition",
        disposition: "Open",
        note:
          "The facility's payment interval is required at origination and committed in the signed terms, but no transition checks a new due date against it, only that the date strictly increases and does not exceed maturity. The schedule a quorum signed is therefore not the schedule the contract enforces.",
      },
      {
        id: "FRV-FS-15",
        severity: "Informational",
        title:
          "Production genesis renounces every deployer authority in the same broadcast, at a point where governance voting power is zero",
        disposition: "Open",
        note:
          "The deployment hands over and renounces in one transaction, at a moment when no governance token has been distributed and voting power is provably zero. This is the intended fail-safe posture and the launch runbook covers the sequencing, but the deploy path itself carries no assertion that a governing party exists before authority is dropped.",
      },
      {
        id: "FRV-FS-16",
        severity: "Informational",
        title:
          "Latent | not reachable at launch: the governor is the timelock's only proposer and can be repaired only through itself",
        disposition: "Open",
        note:
          "Unreachable at v1, where governance is not yet distributed. Becomes reachable on the signposted token distribution: because the governor is the timelock's sole proposer: a governor that cannot reach quorum cannot be replaced except through a proposal it cannot pass.",
      },
      {
        id: "FRV-FS-17",
        severity: "Informational",
        title:
          "Nothing requires the attester set to be larger than the largest configured threshold",
        disposition: "Open",
        note:
          "Neither the contracts nor post-deployment validation asserts that the number of attesters exceeds the highest threshold in use, so a quorum can in principle be configured with no redundancy, every attester required for every signature, and any one unavailable key blocking the path. The production roster size is not published here; it is operational detail and no roster is fixed in source. The underlying parameter risk is already open under its original identifier.",
      },
      {
        id: "FRV-FS-18",
        severity: "Informational",
        title:
          "Latent | not reachable today: the vault's yield notification takes the delivered amount on trust",
        disposition: "Open",
        note:
          "The vault accepts the notified amount without reconciling it against an observed balance delta. Unreachable while a single trusted caller delivers yield, which is the case today; it becomes reachable the moment a second yield-delivering path exists, which is a routine extension.",
      },
      {
        id: "FRV-FS-19",
        severity: "Informational",
        title:
          "The queue can be blocked at its head when the conservative exit price clamps to zero",
        disposition: "Open",
        note:
          "When declared-but-unrealized impairment meets or exceeds vault assets, the conservative exit price clamps to zero and the head of the queue cannot be settled, which stalls the queue behind it. The clamping state is reachable by an unprivileged past-due flag and clears when the impairment is realized or cured, so this is a stall rather than a loss, but the stall is applied to holders who are not party to it.",
      },
      {
        id: "FRV-FS-20",
        severity: "Informational",
        title:
          "Two contract documentation blocks describe a superseded mark-freshness rule",
        disposition: "Open",
        note:
          "The contract notes state that protective margin-call and liquidation triggers accept a mark of any age, which was the earlier ADR-0017 rule. ADR-0030 deliberately reversed it, all marked-to-market calls, cures and liquidations now require a fresh attested mark, and the code correctly implements the current rule. The ADR carries a supersession banner; only the contract documentation was left behind. Recorded because four independent reviewers read the stale note and concluded the code was wrong; see the narrative for why that matters more than the typo does.",
      },
      {
        id: "FRV-FS-21",
        severity: "Informational",
        title:
          "Latent | not currently observable: the vault has no reentrancy guard, and its deposit leg has a transient rate window mirroring the published exit-leg one",
        disposition: "Remediated",
        note:
          "No value-moving vault function carries a reentrancy guard; the current asset set makes this unreachable. Separately: the deposit path has a window in which assets are credited before shares are minted, the entry-side mirror of the exit-side window already published as an Informational item, with the same comment-only remedy. Per unit of flow the exit-side distortion is the larger of the two. Neither is observable by any on-chain rate reader today. CLOSED by the ADR-0031 work: the vault inherits `ReentrancyGuardUpgradeable` and `deposit`/`mint`/`withdraw`/`redeem` plus every fee checkpoint are `nonReentrant`, with separate transient locks covering the points callback and the yield-delivery window. Verified in Round 14.",
      },
      {
        id: "FRV-FS-22",
        severity: "Informational",
        title:
          "The backstop address setter accepts any address with no zero-check or interface probe",
        disposition: "Accepted",
        note:
          "Setting the cascade's second layer to the zero address silently skips that layer while the backstop still holds coverage, with no revert and no distinguishing event. A timelocked governance action, so this is a fat-finger guard rather than an attack surface. CLOSED by the ADR-0031 work: `DefaultManager.setBackstop` now calls `_validateBackstop`, which requires an ERC-165 identity declaration and a bounded, well-formed capacity read before a candidate can be installed. Verified in Round 14. PARTIALLY CLOSED, corrected on re-review: the interface-probe half is genuinely fixed, but the zero-check half named in this finding's own title is deliberately PRESERVED, `_validateBackstop` opens with an explicit early return for `address(0)`, so a single timelocked `setBackstop(address(0))` still removes cascade layer 2. That is an intended capability (the backstop is legitimately unset before Phase H), not an oversight, but recording the finding as fully remediated overstated what was done.",
      },
      {
        id: "FRV-FS-23",
        severity: "Informational",
        title:
          "The protocol fee setter is bounded only at 100% while its sibling origination-fee setter is capped at 10%",
        disposition: "Open",
        note:
          "One timelocked governance call could route the entire interest stream to the fee recipient. The asymmetry with the adjacent setter, which carries a hard 10% cap, suggests the omission is an oversight rather than a decision.",
      },
      {
        id: "FRV-FS-24",
        severity: "Informational",
        title:
          "The cooldown and epoch-duration setters are unbounded above and apply retroactively to queued, non-cancellable requests",
        disposition: "Open",
        note:
          "Both parameters can be raised without limit and take effect on requests already committed to the queue, which cannot be withdrawn. This is the exit-lockout risk the bounded setters elsewhere in the system exist to prevent.",
      },
      {
        id: "FRV-FS-25",
        severity: "Informational",
        title:
          "The endpoint credential check does not cover keys embedded in a URL path or query",
        disposition: "Open",
        note:
          "The guard that stops a keyed endpoint reaching the client bundle inspects only the URL's userinfo and fragment. Provider keys are commonly carried in the path or query string, where they would pass the check and be compiled into the public bundle.",
      },
      {
        id: "FRV-FS-26",
        severity: "Informational",
        title:
          "Loopback detection uses raw string matching rather than URL normalisation",
        disposition: "Open",
        note:
          "The rule that a loopback endpoint must be paired with the local development chain is enforced by matching the URL as text, so equivalent forms of the same address are not recognised and the pairing can be evaded. Strictly a development-profile guard.",
      },
      {
        id: "FRV-FS-27",
        severity: "Informational",
        title:
          "The reserve deposit path accepts either of two roles, widening who can credit the backing denominator",
        disposition: "Open",
        note:
          "Crediting idle reserves, one half of the backing figure, is gated on either the controller or the credit role, rather than on the single role the access-control model describes for that path. Both are protocol-internal, so this is a least-privilege observation rather than an exposure.",
      },
      {
        id: "FRV-FS-28",
        severity: "Informational",
        title:
          "Latent | not reachable today: a rate-epoch struct lacks the layout-frozen annotation both sibling structs carry",
        disposition: "Open",
        note:
          "The points rate-epoch struct is an array element with no layout-frozen marker, unlike the two comparable structs beside it. Harmless as written; it becomes a storage hazard on the most natural extension of that module, which is exactly what the markers on its siblings exist to prevent.",
      },
      {
        id: "FRV-FS-29",
        severity: "Informational",
        title:
          "An interface comment understates the vault share unit by a factor of a million, and a calibration note cites a constant that no longer exists",
        disposition: "Open",
        note:
          "The exchange-rate interface documents the wrong share precision, and the configuration rationale beside it refers to a constant that has since been removed. Documentation only; no caller depends on either statement.",
      },
      {
        id: "FRV-FS-30",
        severity: "Informational",
        title:
          "The published access-control matrix has drifted from the source it describes",
        disposition: "Open",
        note:
          "The matrix documents a function that no longer exists, omits six role-gated functions, and omits three permissionless keeper entry points. This is a re-observation of an item already open under an earlier identifier; it is recorded again because the drift is still present and because the matrix is one of the audit-onboarding artefacts an external reviewer would work from.",
      },
    ],
  },
  {
    slug: "2026-07-28-release-branch",
    file: "audits/2026-07-28-release-branch.md",
    title: "Release-branch differential review",
    eyebrow: "Round 6",
    date: "2026-07-28",
    dateLabel: "28 July 2026",
    scope:
      "The complete pre-mainnet release branch measured against main, 252 files, contracts, deployment scripts, and the frontend.",
    method:
      "Ten independent review lenses over the branch diff, then per-finding adversarial re-verification against source, with each claimed consequence re-derived or refuted by execution.",
    baseline: "86af280 (branch premainnet-fixes-2026-07-20, merge-base 43f7fa4)",
    archive: "audit-reports/PREMAINNET_BRANCH_REVIEW_2026-07-28.md",
    summary:
      "A differential review of everything the release branch changed. Eleven candidate issues were raised and each was adversarially re-verified against source: one was refuted outright, one restated an earlier finding, and most had their consequences corrected downward. The live Medium, the attestation-boundary Low, and four frontend/documentation findings were remediated on 28 July; one grouped efficiency finding was partially remediated. No Critical or High finding, unauthorized-mint path, or permissionless theft path was confirmed.",
    findings: [
      {
        id: "FRV-BR-01",
        severity: "Medium",
        title:
          "The funding gate does not re-validate the next payment date, so a facility funded long after origination can be born already past due",
        disposition: "Remediated",
        note:
          "The funding gate now rejects a pending facility when its signed next payment date has passed, making the time-sensitive funding checks a true superset of origination without rewriting an attested economic term. A boundary regression proves funding remains available one second before the deadline and fails closed at the deadline; the stateful credit handler also models this precondition, and both default and heavy invariant profiles pass.",
      },
      {
        id: "FRV-BR-02",
        severity: "Low",
        title:
          "Attestation thresholds are seeded by a hardcoded loop bound, so a future attestation kind would fail open rather than closed",
        disposition: "Remediated",
        note:
          "The submission path now independently rejects a zero threshold before it evaluates the signature count. A newly added or unsafely upgraded kind whose initializer entry is omitted therefore fails closed, including for an empty signature array. The regression deploys an unset-threshold proxy, asserts the named error, and proves no record becomes satisfied.",
      },
      {
        id: "FRV-BR-03",
        severity: "Low",
        title:
          "Public copy states that concentration limits are enforced on-chain while the deployed configuration sets every dimension to 100%",
        disposition: "Open",
        note:
          "The 100% ramp posture itself is deliberate, owner-accepted with disclosure, confined to the testnet profile and code-gated out of production, the production validator refuses any limit that does not bind. The claim that it makes the concentration invariant vacuous is refuted: the invariant suite configures its own binding limits and fails the run if no dimension ever rejects an origination. What is new and unreported is a disclosure-accuracy gap: the marketing and vertical pages tell readers the position is capped by on-chain concentration limits, no page renders the configured value, and on the chain the site actually points at that value is 100%.",
      },
      {
        id: "FRV-BR-04",
        severity: "Low",
        title:
          "The historical-yield panel re-scans the entire event history on every poll instead of advancing a cursor",
        disposition: "Remediated",
        note:
          "The panel now performs one deployment-to-tip bootstrap per wallet/client context and stores a block cursor. Each minute it reads only the inclusive unseen tail from the prior cursor plus one, merges the deltas, and leaves the ready tiles visible instead of resetting them to loading. Range-boundary logic has direct regression coverage.",
      },
      {
        id: "FRV-BR-05",
        severity: "Informational",
        title:
          "Compliance storage fields were removed mid-struct while the struct still documents itself as append-only",
        disposition: "Open",
        note:
          "A follow-up to FRV-DSA-007 rather than an independent defect. The layout break is deliberate, authorized by ADR-0030, and the affected proxy was redeployed fresh in the same commit, so no live proxy carries the old layout and there is no exposure on the testnet stack or on a future mainnet deployment. Sanctions enforcement is unaffected: the blocklist field does not move. What remains is that the struct's own comment still asserts an append-only invariant this release deliberately broke, with no reserved gap and no fresh-proxy-only marker, while two sibling contracts in the same release did receive explicit legacy-slot fallbacks.",
      },
      {
        id: "FRV-BR-06",
        severity: "Informational",
        title: "Off-by-two index in the collateral panel's positional-decode fallback",
        disposition: "Remediated",
        note:
          "The shared decoder now reads maxMarkAge from ClassParams index eight. Logic tests cover both the named viem tuple and the positional fallback, so a future ABI-client shape change cannot silently reintroduce the blank collateral tile.",
      },
      {
        id: "FRV-BR-07",
        severity: "Informational",
        title: "Two stale documentation blocks contradict the code they document",
        disposition: "Remediated",
        note:
          "The queue pause documentation now states that new requests and settlement pause while already-settled claims remain available. The orphaned one-argument curator-loss documentation was removed, leaving only the three-argument hook's actual dilution and freeze semantics.",
      },
      {
        id: "FRV-BR-08",
        severity: "Informational",
        title:
          "Efficiency items: concentration bookkeeping on the repayment path, duplicated read sweeps, and a duplicated view call",
        disposition: "Open",
        note:
          "Partially remediated. The queue now computes the realized redemption value once and reuses it for the minimum-value comparison and error argument. The concentration breach-cache bookkeeping and overlapping frontend facility reads remain open quality items; neither affects funds, accounting, access control, or cascade ordering.",
      },
      {
        id: "FRV-BR-09",
        severity: "Informational",
        title:
          "The write flow returns silently when the wallet client is unresolved instead of surfacing an error state",
        disposition: "Remediated",
        note:
          "The write flow now distinguishes an unconnected wallet, an initializing wallet client, and an unavailable RPC, and writes an actionable error state for each instead of silently returning with the phase idle. The frontend logic test guards the initialization message and the removal of the silent combined return.",
      },
    ],
  },
  {
    slug: "2026-07-28-clean-v1",
    file: "audits/2026-07-28-clean-v1.md",
    title: "Clean mainnet-v1 defensive audit",
    eyebrow: "Round 5",
    date: "2026-07-27",
    dateLabel: "27–28 July 2026",
    scope:
      "The ADR-0030 clean mainnet-v1 source, deployment scripts, storage namespaces, accounting, attestations, pause paths, compliance exemptions, and economic interactions.",
    method:
      "Defensive source review of the whole release tree, followed by a remediation pass and full re-verification across offline, fork, and deployed-Sepolia adversarial suites.",
    archive: "audit-reports/PRE_MAINNET_SECURITY_REVIEW_2026-07-20.md (28 July addendum)",
    summary:
      "The controlling review for the current release. Eight findings, two High, six Medium. Four are now remediated with regression tests; four were explicitly accepted or deferred by the protocol owner for launch, including one High. Accepted is not fixed, and the prerequisite for each acceptance is recorded so it can be revisited.",
    findings: [
      {
        id: "FRV-DSA-001",
        severity: "High",
        title:
          "Mainnet deployment authorization approved parameters without binding principals or artifacts",
        disposition: "Remediated",
        note:
          "A broadcast now requires one full deployment hash committing to chain and profile, configuration, the compiled proxy, implementation and deployment-plan artifacts, every principal, canonical USDC, the deployer and its nonce. An earlier remediation statement was incomplete, it bound only the base deployment plan, and was corrected so the receipt binds the actual derived deployment runtime as well. Proven by a pinned mainnet-fork test that calls the real entrypoint, writes its manifest, and passes strict validation.",
      },
      {
        id: "FRV-DSA-004",
        severity: "High",
        title:
          "Temporarily posted excess curator capital can improve a queue settlement and later be withdrawn",
        disposition: "Accepted",
        note:
          "Accepted and deferred only for the initial Forest Road-controlled curator phase. An outside user cannot execute the sequence: it requires the controlled curator to post excess first-loss capital, coordinate settlement while that capital improves the conservative exit price, and then withdraw the excess. Mechanically: the temporary capital can only reduce the impairment deduction and raise a queued exit toward ordinary NAV; it cannot lift the exit above ordinary NAV or pay value to the curator. The direct advantage therefore accrues only to exiting depositors. This remains a redistribution risk within the depositor pool, because remaining depositors can inherit more of the impairment after the support is withdrawn. It is the one open High and must be revisited before any third-party curator or junior tranche; the durable options are to lock supporting capital, snapshot and reserve it through settlement, or exclude withdrawable excess from redemption pricing.",
      },
      {
        id: "FRV-DSA-002",
        severity: "Medium",
        title:
          "An older unused terms-amendment attestation can restore superseded facility terms",
        disposition: "Accepted",
        note:
          "Accepted and deferred. Exploitation requires a previously signed but unused quorum record plus a privileged submission, so it is bounded by the attester and originator trust model rather than reachable by an outside party.",
      },
      {
        id: "FRV-DSA-003",
        severity: "Medium",
        title:
          "An older unused past-due-cured attestation can clear a later past-due cycle",
        disposition: "Accepted",
        note:
          "Accepted and deferred, on the same basis as the terms-amendment case: it needs a stale signed quorum record and a privileged caller.",
      },
      {
        id: "FRV-DSA-005",
        severity: "Medium",
        title:
          "Pausing the reserve manager blocks the otherwise never-pausable loss-recognition path",
        disposition: "Remediated",
        note:
          "The role-gated principal write-down required by DefaultManager's loss cascade no longer inherits ReserveManager's guardian pause. A regression pauses ReserveManager, realizes the loss through the full cascade, verifies curator capital and deployed principal both decrease exactly, and proves the reserve manager remains paused for user and custody paths.",
      },
      {
        id: "FRV-DSA-006",
        severity: "Medium",
        title:
          "An external protocol-exempt fee recipient can bypass jurisdiction blocking",
        disposition: "Accepted",
        note:
          "Accepted under the controlled fee-recipient posture, where the exempt address is Forest Road's own. The exemption is liveness-critical on the inbound leg. Flagged for counsel before third-party capital.",
      },
      {
        id: "FRV-DSA-007",
        severity: "Medium",
        title:
          "Two namespaced-storage annotations did not match their hardcoded slots",
        disposition: "Remediated",
        note:
          "Fresh proxies now use the canonical derived slots, and explicit legacy-slot fallbacks preserve already-deployed testnet state. Storage tests prove fresh state lands at the exact computed slots while legacy proxy state stays readable after an upgrade.",
      },
      {
        id: "FRV-DSA-008",
        severity: "Medium",
        title:
          "Mainnet tooling allowed contract attesters even though verification is signature-recovery only",
        disposition: "Remediated",
        note:
          "Deployment and post-deployment validation now require two distinct externally-owned attester accounts, and reject zero and contract attesters. Covered by focused tests.",
      },
    ],
  },
  {
    slug: "2026-07-20-pre-mainnet",
    file: "audits/2026-07-20-pre-mainnet.md",
    title: "Pre-mainnet campaign",
    eyebrow: "Rounds 3–4",
    date: "2026-07-20",
    dateLabel: "20–25 July 2026",
    scope:
      "The whole codebase, contracts, deployment, validation and QA scripts, invariant harnesses, the frontend, and the governing documents, assessed against both a Sepolia redeploy and mainnet readiness.",
    method:
      "A manual pre-mainnet review merged with an adversarial red-team fleet whose findings were each put to a refuter panel, then a 24-lens full-codebase register with executable proof-of-concept reproduction, then two go/no-go re-audits of the resulting fix diff.",
    archive:
      "audit-reports/CONSOLIDATED_PRE_MAINNET_AUDIT_2026-07-20.md, PRE_MAINNET_SECURITY_REVIEW_2026-07-20.md, FULL_CODEBASE_AUDIT_2026-07-21.md, FINAL_FIX_AUDIT_2026-07-22.md, REAUDIT_H5_DELTA_2026-07-22.md",
    summary:
      "The largest campaign run against the protocol, and the one that found the most serious defects, including a Critical path that burned whole queued positions for zero assets. Findings below are the consolidated register with each item's current status. The register is the authoritative published record: it carries every finding, its severity and its current disposition. The underlying working documents are superseded by it, they describe contract addresses and evidence from deployments that have since been archived and replaced, and are retained internally rather than published, because publishing several undated reports that disagree with the current register would mislead rather than inform. They are available to a reviewer on request.",
    findings: [
      {
        id: "C-1",
        severity: "High",
        title:
          "Queue settlement could burn an entire queued position for exactly zero assets",
        disposition: "Remediated",
        note:
          "Filed Critical, reproduced seven times. Under a fully-marked unrealized impairment the conservative NAV clamp could price a queued position at zero, and settlement burned it anyway. This was the Round 2 sub-wei dust item escalated: the conservative-NAV change destroyed the premise that made it immaterial, and its original recommendation had never been implemented. Confirmed no longer reproducing in the 22 July re-audit.",
      },
      {
        id: "H-1",
        severity: "High",
        title:
          "Treasury-directed funding plus permissionless reconciliation inflated backing",
        disposition: "Remediated",
        note:
          "Reproduced with 1,500,000 units of unbacked supply measured. Deployment could name the treasury as its own funding recipient, and the then-bidirectional reserve reconciliation converted that into backing. Confirmed no longer reproducing; the reconciliation primitive is now monotone-downward only.",
      },
      {
        id: "H-2",
        severity: "High",
        title:
          "Partial recovery followed by write-off stranded the impairment pool permanently",
        disposition: "Remediated",
        note:
          "Reproduced three times, with no reachable terminal state. Confirmed no longer reproducing: all pools return to zero and stay there across a full-year warp.",
      },
      {
        id: "H-3",
        severity: "High",
        title:
          "Re-pricing the yield vesting period could claw back vested yield and open a dilution mint",
        disposition: "Remediated",
        note:
          "Reproduced three times. Fixed by crystallizing before re-pricing, then tightened again when the first entry guard was shown to still leave most of the stream skimmable. Confirmed dead in the 22 July re-audit.",
      },
      {
        id: "H-4",
        severity: "High",
        title:
          "The mint gate proved attestations existed but not that they attested to the facility's terms",
        disposition: "Remediated",
        note:
          "Receivable classes had no on-chain binding between the attested bundle and the facility's economic terms. A terms hash is now bound and re-checked on the funding path as well as at origination.",
      },
      {
        id: "H-5",
        severity: "High",
        title:
          "Nothing on-chain forced a receivable to be marked down between a missed payment and a servicer default",
        disposition: "Remediated",
        note:
          "Redesigned rather than patched, across two rounds. Past-due marking is now a permissionless but reversible accounting flag that cannot set the defaulted state, cannot freeze the curator, and cannot de-gate the loss cascade: the attested default declaration remains the only path to those. A residual in which a cured facility kept a stale mark was closed by a repayment hook wired into both performing branches of the waterfall.",
      },
      {
        id: "H-6",
        severity: "High",
        title:
          "Absorbed junior capital has no on-chain claim on later recoveries",
        disposition: "Deferred",
        note:
          "Accepted in principle and deferred on-chain by owner decision: handled off-chain while Forest Road is the curator, with the on-chain recovery leg a required build before a junior tranche or a third-party curator. The architecture document was corrected because it had promised an on-chain leg the code does not implement.",
      },
      {
        id: "PM-H-01",
        severity: "High",
        title: "Revoking a valuation permitted rollback to an older signed mark",
        disposition: "Remediated",
        note:
          "A monotonic high-watermark now survives revocation. The direct reset lever was subsequently removed entirely by owner decision, leaving recovery to a timelocked upgrade.",
      },
      {
        id: "PM-H-02",
        severity: "High",
        title: "The points loss-freeze was bypassable by a permissionless checkpoint",
        disposition: "Remediated",
        note: "Closed in source with regression coverage.",
      },
      {
        id: "PM-H-03",
        severity: "High",
        title: "The conservative redemption NAV was specified but not implemented",
        disposition: "Remediated",
        note:
          "Implemented across the engine, the resolve hook, the vault and the queue, with fifteen tests and two new stateful invariants.",
      },
      {
        id: "PM-H-04",
        severity: "High",
        title: "The production deployment path was not mainnet ready",
        disposition: "Remediated",
        note:
          "Resolved by the dedicated mainnet deployment, configuration and validation scripts. Preparing that path is not authorization to use it.",
      },
      {
        id: "PM-H-05",
        severity: "High",
        title: "The frontend was hardwired to testnet and mock-stable assumptions",
        disposition: "Remediated",
        note:
          "The build is now chain-pinned at build time and a production build fails closed unless it can verify its deployment receipt.",
      },
      {
        id: "PM-H-06",
        severity: "High",
        title: "A global recovery assessment survived a changed impairment book",
        disposition: "Remediated",
        note:
          "Assessments are now bound to an impairment revision that invalidates them when the book moves. Deployed and exercised on Sepolia.",
      },
      {
        id: "PM-R-11",
        severity: "High",
        title:
          "The conservative NAV under-marked impairment after partial backstop coverage",
        disposition: "Remediated",
        note:
          "Externally reported and reproduced with a 150,000-unit under-mark measured, because the NAV subtracted global backstop capacity while coverage is capped and consumed per event. Coverage consumption is now recorded per default and released per facility, deliberately aggregated so the result may over-mark but never under-mark.",
      },
      {
        id: "PM-M-01",
        severity: "Medium",
        title:
          "Concentration exposure could drift above the configured limit after a decrease",
        disposition: "Accepted",
        note:
          "Reclassified as a disclosed admission-control posture: drift is published on-chain and a breached dimension cannot be grown further. Remains an economic and governance item for sign-off.",
      },
      {
        id: "PM-M-02",
        severity: "Medium",
        title: "Frontend approval handling assumed standard-return stablecoins",
        disposition: "Superseded",
        note:
          "Scoped out rather than fixed: mainnet v1 is canonical USDC only. Any second stablecoin requires new testing and a new audit.",
      },
      {
        id: "PM-M-03",
        severity: "Medium",
        title: "The documentation route rendered repository markdown as raw HTML",
        disposition: "Remediated",
        note:
          "The renderer now discards raw HTML and applies a safe URL transform, with regression tests. This is the route these audit pages are served from.",
      },
      {
        id: "PM-M-04",
        severity: "Medium",
        title: "The production frontend had no content-security or framing protection",
        disposition: "Remediated",
        note:
          "Content security policy, frame-ancestors, strict transport, nosniff, referrer and permissions policies are now set and asserted by the frontend test suite.",
      },
      {
        id: "PM-M-05",
        severity: "Medium",
        title: "The queue interface hid older claimable positions",
        disposition: "Remediated",
        note:
          "Resolved by direct request-identifier lookup and claim, so a position outside the scan window is still reachable.",
      },
      {
        id: "PM-R-02",
        severity: "Medium",
        title: "The reserve pause did not cover the debt-service reserve primitives",
        disposition: "Remediated",
        note: "Pause scope widened to the outflow primitives it had omitted.",
      },
      {
        id: "PM-R-09",
        severity: "Medium",
        title:
          "Mint-gate attestation masks were not validated as exact known-bit masks",
        disposition: "Remediated",
        note:
          "Governance can no longer set a mask bit outside the known set, so a future attestation kind cannot be accepted by governance while remaining unread by the gate.",
      },
      {
        id: "R4-AC1",
        severity: "Medium",
        title:
          "The realized-loss magnitude is chosen by the servicer rather than bound to an attestation",
        disposition: "Accepted",
        note:
          "Confirmed real and pre-existing; accepted and folded into the documented attestation and servicer trust model. Constraining it is a counsel decision, not a code decision.",
      },
      {
        id: "PM-R-01",
        severity: "Medium",
        title:
          "The Sepolia deployment is deliberately testnet-shaped and must not be copied to production",
        disposition: "Open",
        note:
          "Open by design, and the reason a testnet result is not a production result: the testnet stack retains bootstrap administrative privileges, uses a mock stablecoin, and runs with concentration limits open for ramp testing. The production validator refuses each of those postures.",
      },
      {
        id: "PM-R-04",
        severity: "Medium",
        title: "No fresh coverage measurement existed for the current tree",
        disposition: "Remediated",
        note:
          "Declared a test-rigor blocker at the time. A source-only coverage gate now reports every source-defined contract function and line entered.",
      },
      {
        id: "PM-R-05",
        severity: "Low",
        title: "The redemption-queue request layout was fresh-deploy-only",
        disposition: "Remediated",
        note: "Resolved by the clean-v1 fresh-deployment-only path.",
      },
      {
        id: "PM-R-07",
        severity: "Low",
        title: "The backstop per-event coverage cap was enforced per call",
        disposition: "Remediated",
        note: "Coverage is now snapshotted and tracked per event rather than per call.",
      },
      {
        id: "PM-R-08",
        severity: "Low",
        title: "Streaming rewards with no stakers stranded them",
        disposition: "Remediated",
        note:
          "Notifying rewards with a zero staked supply now reverts rather than silently stranding the stream. This closes one leg of the Round 1 reward-dust finding.",
      },
      {
        id: "PM-R-10",
        severity: "Medium",
        title:
          "The deployed testnet queue was stale relative to the redesigned cooldown",
        disposition: "Remediated",
        note:
          "Resolved by redeploying. The validator correctly failed loudly on the stale manifest rather than passing it.",
      },
    ],
  },
  {
    slug: "2026-07-14-round-2",
    file: "audits/2026-07-14-round-2.md",
    title: "Five-pass source review, Round 2",
    eyebrow: "Round 2",
    date: "2026-07-14",
    dateLabel: "14 July 2026",
    scope:
      "All production contracts, deployment wiring and interfaces, deliberately excluding the nine Round 1 findings.",
    method:
      "A second five-pass review concentrating on the modules Round 1 touched least, compliance, the vault, the redemption queue, the points module, the governor, and the stablecoin side of the treasury.",
    archive: "audit-reports/SMART_CONTRACT_AUDIT_ROUND_2_2026-07-14.md",
    summary:
      "Nine further findings in the modules the first round treated as trusted. Most were resolved by later architectural decisions rather than point patches, and one Informational item was later escalated to Critical when a design change destroyed the premise that had made it immaterial.",
    findings: [
      {
        id: "R2-H-01",
        severity: "High",
        title:
          "A protocol exemption let a blocked holder move value out through a vault deposit",
        disposition: "Remediated",
        note:
          "Dissolved when transfer-level identity gating was removed: the transfer check is now sanctions-only, and the sanctions test precedes the module exemption, so a blocked wallet cannot route value through an exempt module.",
      },
      {
        id: "R2-H-02",
        severity: "High",
        title:
          "A disabled stablecoin's residual balance kept counting at face value as backing",
        disposition: "Superseded",
        note:
          "Fixed at the time by a governance write-off primitive with isolated per-token balance reads. The whole multi-stablecoin registry was subsequently removed: mainnet v1 is canonical USDC only.",
      },
      {
        id: "R2-M-01",
        severity: "Medium",
        title:
          "Redemption-queue budgets do not reserve the liquidity they measure",
        disposition: "Accepted",
        note:
          "Accepted as a labelling rather than a solvency issue: queue claimants hold fully-backed tokens, and the contention is one hop downstream. The documented semantics were corrected to an honest throughput cap. A hard liquidity reservation remains an economic-review item, deliberately not rushed.",
      },
      {
        id: "R2-M-02",
        severity: "Medium",
        title: "A failing points hook could halt every vault share movement",
        disposition: "Remediated",
        note:
          "The hooks are now fail-open. Points are a non-financial participation ledger and must never be able to block a redemption burn.",
      },
      {
        id: "R2-M-03",
        severity: "Medium",
        title:
          "A retired or reverting stablecoin entry could brick backing calculations",
        disposition: "Superseded",
        note:
          "Fixed together with the face-value finding, then made moot by the move to a single canonical stablecoin.",
      },
      {
        id: "R2-L-01",
        severity: "Low",
        title:
          "Points rate changes re-priced the whole un-checkpointed interval",
        disposition: "Open",
        note:
          "Materially mitigated by non-retroactive rate epochs, each change appends an epoch and prior intervals keep their old rate. The residual is the per-wallet lazy checkpoint on first touch after a change.",
      },
      {
        id: "R2-L-02",
        severity: "Low",
        title:
          "Rebinding an identity misattributed points until the next synchronization",
        disposition: "Superseded",
        note:
          "Moot: the points redesign made accrual per-wallet and removed the identity indirection entirely.",
      },
      {
        id: "R2-L-03",
        severity: "Low",
        title: "The governor initializer accepts zero module addresses",
        disposition: "Open",
        note:
          "The local zero-address checks its sibling modules all carry are still absent at this boundary. Tracked.",
      },
      {
        id: "R2-I-01",
        severity: "Informational",
        title:
          "A queued request could become sub-wei dust after a later loss and burn for zero assets",
        disposition: "Superseded",
        note:
          "Filed Informational on the reasoning that the amount was below one wei and therefore immaterial. That premise was falsified by the conservative-NAV clamp introduced a week later, and the recommendation had never been implemented: the same mechanism was re-filed as the Critical C-1 zero-asset burn and fixed there. The clearest lesson in this history about accepting a finding on a premise rather than on a bound.",
      },
    ],
  },
  {
    slug: "2026-07-14-round-1",
    file: "audits/2026-07-14-round-1.md",
    title: "Five-pass source review, Round 1",
    eyebrow: "Round 1",
    date: "2026-07-13",
    dateLabel: "14 July 2026",
    scope:
      "All production contracts and their deployment wiring, reviewed read-only with no code changes during the review.",
    method:
      "Five read-only passes, architecture and trust boundaries, access control and upgradeability, accounting and invariants, lifecycle and edge cases, then adversarial integration and economics, with full regression execution and static-analysis triage.",
    archive: "audit-reports/SMART_CONTRACT_AUDIT_2026-07-14.md",
    summary:
      "The first structured review. Nine findings, none of them elementary coding mistakes, they sat at the module boundaries the tests treated as trusted, principally backing valuation and the facility lifecycle.",
    findings: [
      {
        id: "H-01",
        severity: "High",
        title:
          "A revoked reserve valuation stayed cached and kept counting as backing",
        disposition: "Remediated",
        note:
          "Backing was changed to read the mark live and validity-aware, so a governance revocation drops it in the same block, and a mark older than a governance-set maximum age is excluded rather than trusted. Fixed together with the stale-mark finding below. The whole reserve-instrument subsystem was later removed from the launch surface.",
      },
      {
        id: "H-02",
        severity: "High",
        title:
          "Marked-to-market facilities were counted at par rather than at conservative attested marks",
        disposition: "By design",
        note:
          "Resolved as an explicit design decision rather than a patch: the marked-to-market class is protected by the fast margin-call, liquidation and loss-cascade remedy, not by a continuously-marked backing figure. A characterization test now pins that behaviour, so any future move to continuous haircut backing is a conscious economic choice rather than a drift.",
      },
      {
        id: "M-01",
        severity: "Medium",
        title:
          "A pending facility could be funded after maturity or on a stale valuation",
        disposition: "Remediated",
        note:
          "Funding now re-validates maturity, class activity, required attestations and mark freshness rather than trusting the checks made at origination. Note that the Round 6 review found a residual: when the past-due trigger was later re-anchored from maturity to the next payment date: the funding gate was not extended to match.",
      },
      {
        id: "M-02",
        severity: "Medium",
        title:
          "Pending facilities could not be cancelled and their exposure could not be released",
        disposition: "Remediated",
        note:
          "A controlled cancellation now retires the position and atomically reverses its recorded concentration exposure, so an abandoned deal no longer consumes headroom permanently.",
      },
      {
        id: "M-03",
        severity: "Medium",
        title: "A fully recovered defaulted facility could not reach a close-out state",
        disposition: "Remediated",
        note:
          "A resolved close-out state was added so a workout recovered in full can unfreeze and refund its reserve account. A later round noted this fix closed the recovery half but not the write-off half, which was addressed separately.",
      },
      {
        id: "M-04",
        severity: "Medium",
        title: "The reserve valuation never expired",
        disposition: "Remediated",
        note:
          "A governance-bounded maximum mark age is now enforced, with fail-safe exclusion rather than continued full value once a mark expires.",
      },
      {
        id: "L-01",
        severity: "Low",
        title: "Governance-only facility transfers still require owner approval",
        disposition: "Open",
        note:
          "A documentation-versus-code mismatch rather than a coding error: the documentation implies governance can move a custody position, and the code requires the holder's approval as well. Independently re-confirmed as still present and pre-existing on 21 July. The open question is whether governance should have migration authority at all.",
      },
      {
        id: "L-02",
        severity: "Low",
        title:
          "Reward-stream rounding and no-staker periods could strand dust",
        disposition: "Open",
        note:
          "The no-staker leg was later closed, streaming rewards with a zero staked supply now reverts. The integer-division dust leg remains tracked, with no recovery or rollover path for sub-rate residuals after a stream ends.",
      },
      {
        id: "I-01",
        severity: "Informational",
        title:
          "Solvency depends on strict approved-asset and operational-role assumptions",
        disposition: "By design",
        note:
          "Deliberate permissioned-protocol assumptions, recorded so they are treated as security controls rather than routine administration: approved assets must be reviewed implementations, and operational roles must be segregated and monitored.",
      },
    ],
  },
];

export function auditBySlug(slug: string): AuditReport | undefined {
  return AUDITS.find((a) => a.slug === slug);
}

export function totalFindings(): number {
  return AUDITS.reduce((n, a) => n + a.findings.length, 0);
}

/** Anything not remediated or superseded still carries a live disposition. */
export function openFindings(): AuditFinding[] {
  return AUDITS.flatMap((a) => a.findings).filter(
    (f) => f.disposition !== "Remediated" && f.disposition !== "Superseded",
  );
}
