import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { Section, SectionHead, KpiBand, HighlightBox } from "@/components/site/Blocks";
import { SeverityMix } from "@/components/site/AuditFindings";
import { AUDITS, openFindings, totalFindings } from "@/content/audits";

export const metadata: Metadata = {
  title: "Audit Register | Forest Road Vault",
  description:
    "Dated reviews of Forest Road Vault, with scope, material findings, remediation history, and review limits.",
};

/** Reviews run by a party other than Forest Road are labelled external. */
const isExternal = (eyebrow: string) => eyebrow.toLowerCase().includes("external");

/**
 * Snapshot of the canonical attack ledger after fork round 130, the
 * LMV-17 control refutation, and the LMV-09 outcome-independent technical-
 * impact adjudication and owner-adjusted Medium/Open disposition.
 *
 * The 196 novel scenarios are the four live-fork follow-up attacks, five
 * retained scenarios in each of rounds 2-6 and round 13, and six scenarios
 * in each of rounds 7-12, plus two retained scenarios in round 14 and one in
 * each of rounds 15-28, three retained scenarios in round 29, and one in
 * each of rounds 30-38, two in round 39, two in round 40, two in round 41,
 * one in round 42, two in round 43, one in each of rounds 44-57, and two in
 * round 58, one in each of rounds 59-94, two in round 95, and one in each of
 * rounds 96-130.
 * Harness-assurance entries and the round-six deployed-facade regression are
 * deliberately excluded.
 */
const ADVERSARIAL_PROGRAM = {
  asOf: "29 September 2026",
  campaigns: 302,
  liveForkRounds: 130,
  novelLiveScenarios: 196,
  recordedAttempts: 10_307,
} as const;

export default function AuditRegisterPage() {
  const rounds = AUDITS.length;
  const findings = totalFindings();
  const open = openFindings().length;

  const external = AUDITS.filter((a) => isExternal(a.eyebrow));
  const internal = AUDITS.filter((a) => !isExternal(a.eyebrow));

  return (
    <PageShell
      bleed
      section="Assurance"
      title="Audit register"
      lede="Dated reviews, newest first. Each record states what was reviewed, how it was checked, its material findings and their current disposition. Large claim corpora remain available in the named full reports."
    >
      {/* ── The register in numbers, on navy. ───────────────────────────── */}
      <Section tone="navy">
        <KpiBand
          items={[
            {
              value: rounds,
              label: "Review rounds",
              note: "Each with its own findings list and remediation history.",
            },
            {
              value: findings,
              label: "Material findings listed",
              note: "Including accepted findings; each large report retains its complete claim corpus.",
            },
            {
              value: open,
              label: "Still open or accepted",
              note: "Counted as open unless remediated or superseded.",
            },
          ]}
        />
        <div className="mt-8">
          <HighlightBox tone="navy" title="Scope and unresolved findings stay visible">
            Because a protocol that custodies capital against legal claims
            should be reviewable before it is trusted. Most of these are
            internal engineering reviews, which are <em>not</em> a substitute
            for external audit. Reviews conducted by a party other than Forest
            Road are labelled external on their own page, and the limits of any
            engagement should be read alongside its findings. No review here by
            itself authorizes a mainnet launch. Nothing on this page is a
            securities-law representation; token characterization is a matter
            for counsel.
          </HighlightBox>
        </div>
      </Section>

      {/* ── Security after deployment. These figures come from the canonical
             attack ledger, not from test counts or a marketing estimate. ── */}
      <Section tone="light" id="ongoing-adversarial-testing">
        <SectionHead
          title={
            <>
              Security is an operating discipline,{" "}
              <span className="display-accent">not a launch event.</span>
            </>
          }
          lede="Forest Road maintains an ongoing adversarial-testing programme. We fork the deployed Ethereum contracts and current pre-deployment integrations together with real mainnet state, then deliberately try to break accounting, authorization, loan lifecycles, liquidity and redemption boundaries—without touching live assets."
          note={
            "Attack-ledger snapshot through " +
            ADVERSARIAL_PROGRAM.asOf +
            ". A scenario is classified as novel only after its mechanism, target, trigger, state transition, consequence and cross-contract composition are screened against the ledger; regression-only and harness-validation entries are excluded."
          }
        />

        <KpiBand
          className="mt-12"
          items={[
            {
              value: ADVERSARIAL_PROGRAM.liveForkRounds,
              label: "Fork attack rounds",
              note:
                "One hundred twenty-nine completed rounds against pinned Ethereum state.",
            },
            {
              value: ADVERSARIAL_PROGRAM.novelLiveScenarios,
              label: "Novel attack scenarios",
              note: "Each screened against the prior ledger before it was counted as novel.",
            },
            {
              value: ADVERSARIAL_PROGRAM.recordedAttempts.toLocaleString("en-US"),
              label: "Adversarial attempts recorded",
              note:
                "Positive and negative results retained across " +
                ADVERSARIAL_PROGRAM.campaigns +
                " campaigns.",
            },
          ]}
        />

        <div className="mt-8 grid gap-6 lg:grid-cols-2">
          <HighlightBox title="Why this matters to depositors">
            Testing the exact deployed system can expose timing, ordering and
            cross-contract failures that source review alone can miss. Failed
            attack attempts remain evidence in the ledger; confirmed weaknesses
            are tracked to remediation or explicit risk acceptance, then
            challenged again. That continuing scrutiny gives depositors stronger
            grounds for confidence in the controls protecting the platform.
          </HighlightBox>
          <HighlightBox title="What the evidence does—and does not—say">
            No audit or attack campaign can prove that a protocol is risk-free.
            Round 59 initially appeared to confirm High/Open LMV-17, but
            control review showed that the comparison skipped the remaining
            sUSDfr loss layer and the mandatory frozen G3 remedy. Forest Road
            withdrew the classification: the measured difference was not an
            attacker-reachable contract defect. The failed analysis and its
            correction remain in the ledger rather than being erased. No
            attacker-reachable High or Critical is currently confirmed.
            LMV-09 remains
            Medium/Open with High technical
            impact but very-low practical likelihood. Its
            fork proof requires roughly USD 6m of real capital across
            transactions, pre-aged and precisely aligned queue positions, an
            existing recovery-bearing stake, a marked-credit window and two
            keeper batches. The parties cannot know which loans will cure, and
            the attacker is an identifiable KYC participant exposed to
            monitoring and blacklisting. The proof nevertheless caused a
            material permanent loss to an unrelated queued depositor and stayed
            gross-positive across the tested credit outcomes, so the finding
            remains open. Round 34 also confirmed Medium/Open LMV-11: under a
            conditional multi-class loss sequence, a global prepayment ledger
            can shift a realized credit loss between curator classes. The fork
            moved about 261,069 USDfr of curator value but left depositor value,
            aggregate junior capital, supply and backing unchanged. It requires
            an approved curator, substantial compliant liquidity and legitimate
            governance and signed-loss events. Round 35 then attacked priority
            between a settled queue claim and finite junior protection. A deliberately
            loose sub-par floor exposed a first-mover transfer, but the default
            route used by the frontend reverted at its par floor without burning
            claimant tokens or moving cash. Round 36 combined a real Aave loan,
            public execution of a ready governance impairment and uncapped
            sGROVE coverage. The optimized maneuver made a 4m-USDfr exit whole,
            but cost the actor about 547,939 USDC more than the same no-flash
            exit; the difference stayed as protocol backing plus Aave’s fee.
            Round 37 then executed the exact ready FRV-005 installation from
            inside an untrusted ERC-721 receiver callback while the old bridge
            implementation remained on-stack. The unusual ordering was
            reachable, but every implementation, facility, queue, supply,
            backing and accrual field matched orderly upgrade-before-transfer
            execution, and no value moved.
            Round 38 then tried to reuse one 21m-GROVE position across
            three identities and both voting sources without advancing the
            timestamp. The two fresh identities had zero weight at the frozen
            snapshot, the tally stayed below the live 40m quorum and the
            proposal was defeated.
            Round 39 confirmed Medium/Open LMV-12. A compliant contract used
            a real Aave loan to enter immediately before public execution of a
            ready impairment and exit immediately afterward. A 7.646263-USDC
            premium forced about 500,001 USDfr of irreversible junior burn.
            The cross-class extension paid a 119.911678-USDC premium and
            preserved about 300,000.08 USDfr of the attacking curator&apos;s
            claim at unrelated curator pools&apos; expense. Depositor value and
            aggregate accounting matched control. The current Medium rating
            reflects that the immediate route is non-profitable junior-layer
            sabotage, while the profitable extension needs an approved
            curator and genuine future loss events; its preserved claim is
            default-frozen and can be jurisdiction-blocked before withdrawal.
            Round 40 then executed the exact queued FRV-005 installation
            during two unresolved loss states: an armed custody shortfall and
            a declared facility default awaiting realization. Both roleless
            executor branches preserved the pending state and matched
            old-code-first controls exactly after resolution, with no value
            gained and no backing or depositor loss.
            Round 41 then recorded genuine live-facility payment and amendment
            facts under the old implementations and let a roleless account
            install FRV-005 before their authorized consumers acted. The
            964.968171-USDfr receipt and 1-bps prospective rate amendment each
            retained identical meaning and one-shot state; every measured
            debt, cash, fee, yield, supply, backing and vault field matched the
            old-code-first control, with no executor or depositor gain.
            Round 42 then carried the one-second PIK-entry timing edge
            through the live sUSDfr/USDC Uniswap pool. Across 50, 500 and
            5,000 USDfr trades, entering before the five public PIK services
            added at most $0.000034 of sale proceeds, while the largest trade
            lost about $855.90 versus primary redemption. The route was
            reachable but economically negative; no depositor loss or new
            finding resulted.
            Round 43 then opened a genuine signed margin call on the live MTM
            facility and moved exact FRV-005 across both cure and expiry-only
            liquidation. Upgrade-first and old-code-action-first branches
            produced identical complete terminal states; the standing deadline
            and every measured oracle, debt, impairment, supply and backing
            field were preserved, with no executor gain or depositor loss.
            Round 44 then challenged the blacklist against the live secondary
            market. Removing only primary-market KYC still allowed an existing
            holder to sell by design; the separate jurisdiction block stopped
            direct transfer, direct pair transfer and Router02 cash-out before
            any value or pool reserve moved. That validates the on-chain
            blacklist once applied, but does not assume operators can always
            detect and block a participant before a transaction.
            Round 45 then confirmed Medium/Open LMV-13 at the boundary of
            that control. A holder that had already put value into the public
            pool could redeem the separate bearer LP token after being blocked
            and direct about 1,998.68 USDfr-equivalent to an unblocked
            recipient. No depositor value or protocol accounting moved, but
            address blocking cannot freeze external wrappers created before
            enforcement; monitoring and disclosures now treat that limitation
            explicitly.
            Round 46 then tested secondary-market pricing after a publicly
            confirmed signed MTM liquidation. The deployed pair paid the same
            4,151.682544 USDC before and after the fork-only 2m-USDfr default,
            even though conservative value of the sold shares had fallen to
            about 2,642.52 USDfr. That shifted marked exposure to LP holders,
            but did not create profit: the seller remained 848.317456 USDfr
            below acquisition basis, and remaining depositor value and every
            measured protocol accounting field were unchanged. The result is
            expected external-market price discovery, not a protocol finding;
            pool spot price is not a synchronous NAV oracle.
            Round 47 then executed the exact live-approved FRV-007 token
            upgrade inside the deployed pair&apos;s flash-swap callback. The pair
            delivered 100 sUSDfr under old code, a roleless borrower installed
            both reviewed implementations through the open Timelock executor,
            and repayment used new code. The borrower paid the normal
            0.300902708124373119358075-share fee, while pair reserves,
            invariant, points, supply, backing and complete terminal wealth
            matched upgrade-before-swap control exactly. The split-version
            ordering was reachable but produced no finding.
            Round 48 then used a real 6m-USDC Aave loan to bracket all five
            first-legally-callable live cash-facility past-due marks inside one
            callback. The public marks recorded about 2.721m USDfr of raw
            exposure and 1.110m USDfr of conservative senior impairment, but
            did not change custody backing. The controller burned zero junior
            capital, created zero exit prepayment and matched the mark-only
            terminal state exactly; the actor retained no USDfr and paid the
            3,000-USDC premium. The attempted public-trigger extension of
            LMV-12 therefore held and produced no finding.
            Round 49 then used real Aave liquidity to enter the vault while
            about 11,063.58 USDfr of live continuous income remained virtual,
            forced complete physical delivery inside the callback, sold every
            temporary share through the deployed pair and repaid Aave. Across
            50, 500 and 5,000 USDC, attack and delivery-first control minted
            identical shares and received identical cash. The timing advantage
            was zero, while the actor lost about $0.38, $12.53 and $853.73.
            Complete protocol accounting matched and no finding opened.
            Round 50 then let a genuine borrower enter sUSDfr immediately
            before its own two-attester 5,833.333333-USDC interest receipt and
            sell every temporary share through the deployed pair. Across 50,
            500 and 5,000-USDC entries, receipt-first and entry-first controls
            received identical cash. The timing advantage was zero, the
            pre-receipt entrant received slightly fewer shares, incumbents were
            not diluted and the largest trade lost about $924.48 excluding the
            genuine payment. No finding opened.
            Round 51 then placed a public points reconciliation between two
            distinct authenticated curator losses at the exact same block
            timestamp. The 200,000- and 300,000-USDfr losses were both retained
            as separate epochs; the attacked and losses-first branches ended
            with identical 500,000-USDfr live and tracked curator capital,
            identical points and identical complete economic state. The
            outsider preserved no points on destroyed capital, so no finding
            opened.
            Round 52 then confirmed Medium/Open LMV-14 in the
            origination-to-funding lifecycle. Seven fully attested Pending
            facilities temporarily added 94m USDfr to the concentration
            denominator, allowing a 16m-USDfr target that failed directly to
            pass. After every filler was cancelled, the target represented
            76.1754% of the remaining book and had zero concentration
            headroom, but the funding gate still activated it and sent 15.68m
            USDC. This is a future-growth and authorized-operations risk, not
            an external exploit: the fork had to model 16m USDC of additional
            deposits, and the sequence requires the Operations Safe, valid
            attestation packages for all eight facilities, and departure from
            the mandatory atomic origination/funding procedure. It can expose
            depositor capital to excess borrower concentration if those
            controls fail, so it remains open despite being below High.
            Round 53 then tested whether an ordinary holder could front-run a
            real facility funding and capture its 2,000-USDfr origination fee.
            Genuine two-signer facility facts, the approved 98,000-USDC net
            borrower payout, the configured fee Safe and the deployed
            sUSDfr/USDC market all participated. Across 50, 500 and 5,000-USDC
            entries, entry-first and funding-first controls minted exactly the
            same shares and received exactly the same cash. The timing
            advantage and incumbent-value difference were zero, while the
            largest round trip lost about 848.32 USDC. Every measured protocol
            and market ledger converged, so no finding opened.
            Round 54 then tested whether the deployed pool could finance its
            own repricing after a realized credit loss. Healthy and
            confirmed-but-unrealized-default routes could not repay the flash
            swap. After the authorized 2m-USDfr loss was realized, an ordinary
            allowlisted contract starting with no assets borrowed USDC from
            the treasury-owned pair, minted and deposited at the lower primary
            NAV, repaid the pair in shares and sold the surplus. The
            near-optimal 4,947-USDC branch earned 1,846.270364 USDC, exactly
            matching the treasury LP position&apos;s fair-value loss. Existing
            depositor value changed by zero and supply remained backed. This
            is Low/Open LMV-15: standard AMM adverse selection and a current
            treasury-liquidity operating risk, not a depositor or insolvency
            failure. Treasury liquidity should be removed or repriced before
            a material loss is realized.
            Round 55 then placed the exact already-approved FRV-005 upgrade
            between legacy origination and first funding. A roleless executor
            installed the queued batch while a fully attested 100,000-USDfr
            cash facility was Pending; the control funded under old code and
            upgraded afterwards. Both paths paid the approved recipient 98,000
            USDC, minted the same 2,000-USDfr fee and ended at the exact same
            complete protocol-state hash. The executor gained no asset or
            role, so the old-origin/new-fund boundary held and no finding
            opened.
            Round 56 then tested a strictly novel external-integration
            boundary and confirmed a distinct extension of Medium/Open
            LMV-13. The scenario required the actor to pre-position its own
            value before enforcement. Depositor value, token supplies, vault
            assets, backing and protocol accounting remained unchanged. Exact
            operational mechanics remain in the private attack ledger while
            the affected integration is live.
            Round 57 then challenged a second deployed external-market
            architecture and confirmed another strictly novel extension of
            Medium/Open LMV-13. The actor again had to pre-position its own
            value before enforcement, the external claim remained fully
            backed, and depositor value, supply, backing, reserve cash and
            vault assets remained unchanged. Exact mechanics and controls stay
            in the private attack ledger while the integration is live.
            Round 58 then tested a new external-liquidity boundary around a
            severe, authorized credit-state change and confirmed Medium/Open
            LMV-16. Two strictly novel cross-contract scenarios showed a
            material value transfer from a Forest Road-operated external
            position, including an economically interested existing-holder
            differential. Depositor value was not harmed, reserve cash and
            backing reconciled, and the holder still bore a large absolute
            credit loss. Exact mechanics, amounts and controls remain private
            while the affected integration is live.
            Round 59 then tested a strictly novel stressed-loss settlement
            boundary. Its initial High/Open LMV-17 classification was
            withdrawn after review showed that the mark-first control bypassed
            the remaining sUSDfr loss layer and the mandatory frozen G3
            remedy. The six-figure differential was therefore an artifact of
            an invalid control, not an attacker-reachable finding. The attempt
            still counts as a novel scenario and its refutation is retained in
            the canonical ledger.
            Round 60 then tested whether a governance-approved smart-contract
            recipient could redirect a live facility during its ERC-721 receipt
            callback. The callback was reached after ownership changed, but the
            unauthorized nested custody hop was rejected. The approved outer
            transfer completed and every measured facility and economic ledger
            remained exact, so no finding opened.
            Round 61 then reversed two independently approved live upgrades
            after both timelock delays had elapsed. Both execution orders
            installed the same seven reviewed implementations and converged
            exactly across governance state, roles, bindings, accounting,
            exposure, supply, backing, the live queue and participation points
            after ordinary user operations. The caller gained nothing and no
            finding opened.
            Round 62 then tested the persistent intermediate state made by
            processing only part of simultaneous mixed-interest accounting
            work. Fourteen price- or value-bearing paths refused the
            incomplete frontier atomically. Public maintenance completed the
            remainder, ordinary operations resumed, and the result matched
            uninterrupted maintenance exactly with zero caller gain. No
            finding opened.
            Round 63 then crossed that deliberately incomplete accounting
            frontier into a deployed secondary market. An ordinary holder&apos;s
            material sale returned exactly the same proceeds whether public
            maintenance completed before or after it. Market reserves,
            balances, participation points, facilities, supply, backing,
            vault value and accrual state all converged; no incremental value
            or depositor loss arose and no finding opened.
            Round 64 then combined external atomic liquidity, both deployed
            Forest Road markets and primary vault entry into one circular-
            arbitrage attempt. Every tested size lost value after lender and
            market costs, with losses increasing as trades grew. The actor
            retained no protocol token, USDfr supply and reserve backing stayed
            fixed, and existing vault shares were not diluted. No finding
            opened.
            Round 65 then removed external lending and starting capital from a
            different market composition. Transaction-local settlement in the
            deployed USDfr market could finance the exact primary conversion
            owed back to that market, but captured only its tiny pre-existing
            price difference—about three cents at the best tested size—and
            larger sizes eliminated it. The reserve received full value for
            every USDfr issued, supply and backing moved together, and sUSDfr
            depositor value was unchanged. No finding opened.
            Round 66 then attacked the reverse direction: acquire USDfr through
            the deployed market before paying for it, redeem against the primary
            reserve and try to settle the market entirely from that redemption.
            None of 24 tested sizes could complete without the participant
            adding value; the shortfall increased with size. Complete diagnostic
            settlements retired the matching liability, kept supply and backing
            aligned and left sUSDfr depositor value unchanged. No finding opened.
            Round 67 then timed an already-approved token implementation change
            during the real five-request redemption process. Splitting the
            requests across old and new reviewed implementations produced the
            same request credits, queue custody, supply, vault value, reserve
            backing and participation-points state as completing settlement
            before the change. Every request settled, the unrelated executor
            gained no asset and no finding opened.
            Round 68 moved that reviewed change to a separate custody
            boundary: after all five real redemptions had been credited but
            before their owners withdrew. Every claim paid identically, all
            requests cleared, and queue custody, owner balances, token supply,
            vault value, reserve backing and participation points converged.
            The unrelated executor gained no asset and no finding opened.
            Round 69 then moved a separate approved credit-system change onto
            a real scheduled-accounting boundary. Five live loan schedules
            produced exactly the same debt and claim accounting whether due
            work was processed immediately before or after the change. Both
            paths settled and paid six redemption requests identically and
            returned the same USDC through primary redemption. Facility,
            registry, risk, token, vault, queue, reserve, backing and
            participation records converged; the unrelated executor gained no
            asset and no finding opened.
            Round 70 then crossed a pending user authorization with the
            approved token implementation change. A genuine USDfr permit
            signed under old code remained valid exactly once after the
            change, only for its signed spender and amount. Its nonce advanced
            once, replay failed without state change, and delegated vault
            shares, balances, participation points, supply and reserve backing
            matched authorization-before-change control. The unrelated
            executor gained no asset and no finding opened.
            Round 71 then crossed a partially completed mixed-loan accounting
            boundary with a separately authenticated full loan loss and the
            depositor exit path. The loss refused the incomplete global
            frontier atomically and retained its authorization. After
            maintenance completed, both paths recognized the same loss,
            applied the same intended junior-then-sUSDfr waterfall, credited
            the same queue claim, returned the same USDC and converged across
            facility, reserve, backing, risk, token, vault and queue state. The
            unrelated caller gained no asset and no finding opened.
            Round 72 then crossed the exact approved token implementation
            change with a genuine authenticated three-layer loss and depositor
            exit. Executing the change immediately before rather than after
            realization consumed the same curator capital, protocol backstop
            and sUSDfr assets in the intended order and conserved the exact
            loss. Both paths credited the same queue claim, returned the same
            USDC and converged across facility, commitment, reserve, backing,
            token, vault, queue and participation state. The unrelated
            executor gained no asset and no finding opened.
            Round 73 then compared one large marked-book redemption with 1,024
            smaller redemptions through global curator capital, the protocol
            backstop and an independent depositor&apos;s later queue payout. The
            holder received the same 512,000 USDC, the extra backstop draw was
            only 771 wei of USDfr, and the depositor&apos;s claim, queued remainder
            and cash payout were unchanged.
            Round 74 then placed a genuine three-layer facility loss inside a
            nonzero-supply handoff between two streamed-reward holders. Each
            holder received exactly its earned half of the 604,800-USDfr
            stream, the loss consumed only the intended curator, protocol-
            backstop and sUSDfr layers, and an independent depositor&apos;s
            19,345.168176-USDC payout was identical in both orderings.
            Round 75 then confirmed Medium/Open LMV-18. After genuine curator
            and protocol-backstop capital absorbed 250,000 USDfr of a loan
            loss, the vault treated that contributed protection as performance
            and issued fee shares worth almost exactly 25,000 USDfr at the
            current 10% rate. The independent queued position lost about
            153.26 USDfr of immediate value. The public caller received
            nothing, could not create the authenticated loss, and supply and
            backing remained protected; those constraints keep the finding
            below High, but the depositor dilution is material and remains
            open pending remediation and independent retesting.
            Round 76 then tested whether the same fee behavior was a general
            consequence of junior protection absorbing losses. A separate
            one-million-USDfr native custody loss consumed 600,001 USDfr of
            global curator capital, 150,000 USDfr of protocol backstop and
            249,999 USDfr of senior vault assets. The post-loss checkpoint
            issued no performance-fee shares, the independent depositor was
            unchanged and both orderings converged. This confines the observed
            LMV-18 behavior to the facility-loss accounting path rather than
            junior loss absorption generally.
            Round 77 then split that same total custody loss into 128
            separately measured incidents. The repeated path created 231
            participation-loss records versus three in the one-shot control,
            but reconciled to identical fee, class, protection-layer and
            backing state. The independent depositor received the same
            22,352.732427-USDC payout in both paths, so no cumulative-rounding
            or repeated-transition finding opened.
            Round 78 then executed the exact approved USDfr/sUSDfr update and
            searched the lowest caller-selected gas at which each upgraded
            token transfer could commit. Each one-gas-lower attempt failed
            atomically; every successful transfer updated both participation
            positions exactly. Low-gas and normal-gas paths then accrued the
            same 30-day points, credited the same 18,777.907495511719781884-
            USDfr queue claim, paid the same 18,777.907495 USDC and converged
            across token, vault, reserve, queue, points and governance state.
            Round 79 then challenged an authenticated prospective mixed
            cash/PIK term change during a live multi-transaction redemption.
            Two equal 50,000-USDfr positions received exactly 50,906.994626
            USDC in both orderings; debt, supply and backing stayed exact, and
            the largest raw claim movement was far below one USDC atom.
            Round 80 then compared one authenticated 400,000-USDfr facility
            loss with the same loss split across two facilities and a mandatory
            fee checkpoint between them. Fragmentation reduced the measured
            LMV-18 fee by about 26.44 USDfr, improved the independent
            depositor&apos;s payout by 0.162067 USDC and preserved the same
            three-layer loss allocation with supply no greater than backing.
            Round 81 then challenged the interaction between compliant
            redemption, protection attribution, authenticated facility-loss
            completion and vault fee accounting. Protection was consumed only
            once, accounting remained coherent and the independent queued
            depositor was not harmed. The result reconfirmed an existing
            Medium/Open LMV-11/LMV-18 interaction, not a new root or High.
            Round 82 then challenged an authorized facility-custody operation
            whose recipient callback completed scheduled loan accounting before
            the outer custody call returned. Against an identical same-timestamp
            control, all affected accounting converged exactly and the callback
            recipient gained no value, so no finding opened.
            Round 83 then held one authenticated risk observation constant while
            varying its permitted submission time across ordinary loan accrual.
            The later submission changed the protective action only after current
            debt genuinely satisfied the configured condition. The loss followed
            the intended sUSDfr-before-USDfr ordering, the submitting account
            gained no value and the stablecoin remained covered, so no finding
            opened.
            Round 84 then rehearsed the complete emergency procedure for a loan
            loss larger than immediately available absorption capacity. The
            failed attempt left no partial accounting; independent controller,
            vault and queue freezes stopped every prepared primary holder path
            while an already-settled claim remained payable. An authorized
            protection-layer top-up completed the full loss through sGROVE and
            then sUSDfr, with zero unstaked USDfr-holder burn and exact supply,
            backing and exposure reconciliation. No finding opened.
            Round 85 then tested partial loan recovery after sGROVE had
            already absorbed an authenticated loss. Reversing the later cash
            recovery and remaining loss cleared every loan, commitment and
            protection record, allocated the same loss and paid the same
            independent queued depositor in canonical USDC. No finding opened.
            Round 86 combined public overdue-loan accounting with later income
            and adversarial fee timing across eight independently underwritten
            facilities. Even at the most severe conservative valuation, the
            public checkpoint produced no timing gain, changed the independent
            fee-net quote by zero and converged with automatic checkpointing
            through cure and canonical-USDC exit. No finding opened.
            Round 87 then challenged duplicate loan-recovery and resolution
            callbacks after a genuine loss had consumed protection capital.
            Ordinary callers were rejected, repeated recovery callbacks at an
            unchanged balance were exact no-ops, and a new authenticated
            receipt after resolution moved no cash. Both branches paid the
            same independent depositor 19,654.114161 USDC. A separate trusted-
            module boundary probe reconfirmed an existing Low revision-only
            hardening item with no economic effect or external trigger.
            Round 88 then tested whether splitting the same genuine loan
            recovery across 64 independently authenticated receipts could
            distort repeated accounting after protection capital had already
            been used. Fragmented and aggregate paths produced identical
            commitments, loss allocation and terminal economics. sGROVE bore
            250,000 USDfr before sUSDfr bore 94,000 USDfr, and both paths paid
            the independent depositor 19,691.187679 USDC. No finding opened.
            Round 89 then compared pricing the same 64 eligible FIFO
            withdrawals together with pricing them one at a time under a real
            authenticated impairment, substantial earned income and a live fee
            checkpoint. Chunking created no additional fee shares or fee-
            recipient value, and both schedules paid depositors 43,266.576552
            USDC. The only differences were 43 wei of claim flooring and 63
            wei of fee-hurdle rounding, both conservatively retained and far
            below one USDC base unit. No finding opened.
            Round 90 then combined an in-progress multi-request settlement
            with a deliberately partial scheduled-loan update. The protocol
            refused to price the next withdrawal against the half-updated
            state, changed no request or settlement value, and retained the
            live settlement. After the remaining updates, both schedules paid
            exactly 122.444322 USDC and 122.444325 USDC, reached the same final
            state and gave the ordinary caller no asset. No finding opened.
            Round 91 then tested whether explicitly issuing the pending fee
            shares implicated by Medium/Open LMV-18 could create a second price
            jump against deployed external liquidity. Fee-adjusted vault
            pricing had already included those shares: the sUSDfr rate and an
            independent depositor claim were exact across issuance, all seven
            transaction-local routes failed before and after it, and the caller
            gained no asset. No new finding opened; the underlying LMV-18
            accounting overcharge remains Medium/Open.
            Round 92 then tested public execution of an approved prospective
            fee change immediately before versus between two chunks of the
            same in-progress withdrawal settlement. Both schedules produced
            exact individual claims, fee components, fee-recipient value and
            10,123.594786 USDC aggregate cash, then converged across vault,
            queue, supply, backing, fee-hurdle and governance state. The
            unrelated executor gained no asset. No finding opened.
            Round 93 then tested whether an unrelated relayer could
            crystallize already-due performance fees immediately before
            submitting a genuine adverse signed valuation and atomic
            liquidation. The public call changed only same-block checkpoint
            attribution. Both schedules recorded the same 512,499 USDfr
            senior impairment and paid the depositor 8,995.464662 USDC.
            Residual fee and claim differences were below cash precision, and
            the relayer gained no asset. No finding opened.
            Round 94 then tested public execution of an already-approved
            recovery assessment between two transactions of one FIFO
            settlement. Pricing the unrelated head request before execution
            lowered its complete wealth by about 6,293.88 USDfr, while the
            second requester and large stayer gained about 5,023.58 USDfr.
            The actor had committed 9m USDfr before default and could not
            create the default, assessment, governance approval or keeper
            split. This reproduced the already accepted Medium G4 pricing-
            session risk through a new path; it did not open a new root or
            meet the High/Critical stopping threshold.
            Round 95 then executed the exact approved FRV-005 upgrade from
            inside an old-code facility-origination receiver callback. Both
            upgraded continuations held: funding paid the approved recipient
            and fee exactly, while cancellation burned the NFT and released
            its full concentration. Each matched its orderly upgrade-first
            control across every measured ledger, and the roleless callback
            and executor gained no asset. No finding opened.
            Round 96 then compared six public physical deliveries over 90 days
            of mixed-loan accrual with one aggregate delivery and continued
            through the same authenticated 618,000-USDfr full loss. Senior
            income, protocol fee, loss allocation and the independent
            depositor&apos;s 9,440.214108-USDC payout matched exactly; the
            roleless caller gained nothing and no finding opened.
            Round 97 then tested whether a normal sub-USDC loan-payment
            rounding draw against loss protection could leave a more
            optimistic recovery assessment usable when the ordinary
            impairment version did not change. The independent capacity
            check invalidated it immediately: automatic conservative fallback
            and an explicit governance clear both paid the depositor
            9,191.400311 USDC and converged across every measured ledger. No
            finding opened.
            Round 98 then tested whether an unrelated public executor could
            redirect historical continuous-accrual fees or depositor value by
            landing an already-approved fee-recipient rotation inside a live
            settlement. The outgoing recipient received its complete prior
            entitlement, the approved replacement received only later fees,
            and both schedules paid depositors an identical aggregate
            10,123.847026 USDC. The executor gained nothing and no finding
            opened.
            Round 99 then tested whether public execution of an already-
            approved one-day withdrawal-cooldown increase could corrupt a
            settlement after its first depositor was paid but while its next
            FIFO request remained latched. The request was neither skipped nor
            stranded: the old budget released, the request settled normally at
            its governed deadline, aggregate value and backing stayed conserved,
            and the delayed holder received the intervening return. The executor
            gained nothing and no finding opened.
            Round 100 then tested whether an approved borrower-limit reduction
            could stop a facility admitted under the earlier policy but not yet
            funded. The tightened policy rejected an identical fresh facility
            and reported the Pending one over limit with zero headroom, yet the
            funding gate still deployed it. This is a new Medium/Open LMV-14
            consequence path, not a new root: governance, authorized operations
            and valid facility attestations are required, backing stayed intact,
            and any depositor loss remains conditional on later borrower
            underperformance.
            Round 101 then tested whether an approved extension of a class&apos;s
            valuation-freshness window could reactivate a previously expired
            signed valuation. It did, because the new policy expressly accepted
            that age, but a fresh same-value quorum control produced identical
            impairment, depositor cash and terminal economics. Backing held, the
            public executor gained nothing and no finding opened. The result adds
            an operational safeguard to refresh affected live valuations whenever
            governance widens their freshness window.
            Round 102 then composed a governance-approved past-due risk-
            weight increase with a separately approved assessment clear. A
            KYC holder who publicly executed only the weight before settlement
            and the clear afterward gained about 20,064.46 USDfr-equivalent,
            exactly reducing aggregate remaining redemption value. This is a
            new consequence of the accepted Medium G4 pricing-session risk,
            not a new root or High: every state change required governance,
            settlement had to land inside a publicly closable execution gap,
            and batching the weight and clear atomically removes that gap.
            Round 103 then tested whether a later governance decision to
            lower a marked-to-market class&apos;s maximum draw ratio reaches a
            facility that is approved but still unfunded. The new ceiling
            rejected identical fresh terms, but the Pending facility still
            passed the funding gate, paid the approved recipient and became
            Active at five times the current ceiling. This extends the existing
            Medium funding-time policy gap rather than establishing a High:
            governance, authorized operations and genuine signed facility and
            valuation facts are required, backing remained intact, and loss
            would depend on later underperformance.
            Round 104 then exercised the planned, not-yet-deployed Morpho
            lending integration. A newly valid public overdue mark invalidated
            a professional assessment, repriced an unrelated borrower&apos;s
            sUSDfr collateral, enabled full liquidation and left residual debt
            with the fork-only lender. This confirms a new external-market
            consequence of the already disclosed Medium assessment-
            invalidation risk, not a new root or live High. The integration
            remains behind launch controls, and no current Forest Road
            depositor funds were exposed.
            Round 105 then attacked the exact first five-facility cash-
            payment package by publicly submitting all five signed facts
            before its reviewed Operations Safe transaction. That made the
            original package fail, validating the existing confidentiality
            and private-relay controls, but it did not consume the Safe nonce
            or payment authority. A newly approved package reused the recorded
            facts without new attester signatures, settled exactly 7,948.590854
            USDC and matched normal terminal economics. The outsider gained
            nothing, so this is a novel held recovery rehearsal rather than a
            contract finding or High.
            Round 106 then attacked the narrowest reachable mixed-interest
            receipt boundary: genuine cash and partial principal one second
            before PIK capitalization versus one aggregate receipt immediately
            afterward. Both orderings capitalized exactly 12,000 USDfr, reached
            and lost the same 512,000-USDfr face, cleared exposure and preserved
            backing. The earlier payment saved only the correct $0.000129 of
            cash interest; sub-micro-dollar allocation dust changed the
            independent depositor&apos;s final USDC payout by one native unit.
            The roleless caller gained nothing, so the full credit-to-loss-to-
            cash composition held and no finding opened.
            Round 107 then tried to monetize temporary first-loss support
            through the planned Morpho integration. Freely withdrawable capital
            did not move the collateral oracle. Capital that did move it gave
            only 86.270546 USDC of extra borrowing power while locking
            44,611.737234 USDfr in the marked class; the withdrawal needed to
            remove that support failed with zero headroom, and the lending
            position remained healthy. This is a held external-market bypass
            test, not a new temporary-capital root, live exposure or High: the
            oracle and market are not deployed, and execution requires an
            approved curator.
            Round 108 then drove the planned exit-value oracle to exactly zero
            through authenticated defaults and tested both canonical Morpho
            liquidation forms. One form cleared all worthless collateral and
            exactly the pre-existing bad debt; the other reverted atomically,
            but did not strand the market because the clearing route remained
            available. No new loss, live exposure or High was created.
            Round 109 then flash-funded a direct vault donation and tried to
            borrow the planned-oracle uplift through Morpho. Donating 10,000
            USDfr created only 34.889224 USDC of new borrowing power. The
            capital-free route reverted atomically; forcing it to complete
            consumed 9,970.110776 USDC of participant cash and left the gift
            in the vault. The integration remains undeployed.
            Round 110 returned to deployed-value paths. A normal compliant
            participant donated backed USDfr, bought unchanged-price sUSDfr
            from the deployed external pool and served the complete queue
            cooldown before redeeming. In the best branch, a 1,000-USDfr gift
            increased exit proceeds by only 0.385516 USDC and reduced complete
            participant wealth by 999.614484 USDC. The full pool held only
            about 1.11% of vault supply, supply and backing stayed aligned, and
            existing depositors gained rather than lost value. No finding
            opened.
            Round 111 then bought sUSDfr from that deployed market before a
            roleless caller moved already-earned loan interest from virtual
            accounting into recorded facility face and physical token
            balances. About 14,167.75 USDfr changed representation, but the
            buyer&apos;s exchange rate, queue claim, canonical USDC payout and
            complete terminal state were exactly identical to deferred
            controls at all three trade sizes. Effective supply and backing
            were conserved, so no finding opened.
            Round 112 then put a fork-only Morpho borrower at the exact limit
            allowed by the planned exit-value oracle before an unrelated
            caller crystallized about 868.25 sUSDfr of pending performance-fee
            shares. The oracle price, redemption quote and fee-adjusted
            exchange rate remained exactly unchanged, and immediate
            liquidation was rejected because the borrower stayed healthy.
            The integration is not deployed and no finding opened.
            Round 113 then placed an exact-limit fork-only Morpho borrower at
            the five live PIK facilities&apos; shared due boundary. A roleless
            caller processed the boundary and tried liquidation after every
            facility call. The oracle increased by one wei, debt capacity
            never fell and all five attempts were rejected as healthy. No
            borrower, lender or depositor value moved, so no finding opened.
            Round 114 then placed the same zero-buffer borrower in front of a
            ready production Timelock action raising the performance fee from
            10% to its 20% cap. An unrelated public executor landed the change
            and tried immediate liquidation. About 743.62 sUSDfr of pending
            shares were correctly crystallized under the old rate, while the
            oracle, redemption quote and net exchange rate stayed exactly
            unchanged. The borrower remained healthy and the executor gained
            nothing, so no finding opened.
            Round 115 then kept the five live pending redemptions, added a
            sixth request and put the zero-buffer borrower in front of the
            resulting multi-user queue close. The keeper completed the five
            live heads and partially filled the new tail, which claimed and
            redeemed about 2,079.20 USDfr. The planned oracle stayed exactly
            unchanged after settlement, claim and canonical USDC redemption;
            all three liquidation attempts failed as healthy. No finding
            opened.
            Round 116 then used a 538,710.932836-USDC Aave flash loan
            to fund a marked facility&apos;s exact full recovery and tried to
            repay it from the resulting Morpho collateral uplift. The cure
            restored the planned oracle, but created only 150.043764 USDC of
            new borrowing power. The capital-free branch reverted atomically;
            forcing completion consumed 538,830.244539 USDC of participant
            cash while the protocol retained the recovery. No finding opened.
            Round 117 then split sUSDfr among a normal wallet, the production
            redemption queue and canonical Morpho collateral before two live
            facility losses were declared and realized. The
            1,002,600.902777-USDfr write-off used about 500,000 USDfr of
            curator first-loss before burning the complete
            502,600.902777-USDfr residual from sUSDfr; the live sGROVE reserve
            was empty and unstaked USDfr remained untouched. Wallet, queue and
            external-market custody all received the same impaired value,
            Morpho could liquidate and the queue settled at the post-loss rate.
            No finding opened.
            Round 118 then modeled a severe reserve-custody incident while an
            exact-limit Morpho position was open. The planned oracle failed
            closed for valuation-dependent actions, but the borrower could
            still repay every debt share and recover all collateral.
            Authorized ratification consumed 500,001 USDfr of curator capital
            before 500,000 USDfr of sUSDfr, left unstaked USDfr untouched,
            restored the oracle and re-enabled liquidation without an
            additional lender loss. The external custody compromise was a
            prerequisite rather than a roleless contract action, so no
            finding opened.
            Round 119 then attacked the 24-decimal sUSDfr/6-decimal USDC
            precision boundary after a permissionless live past-due mark made
            an exact-limit Morpho position liquidatable. Splitting either
            liquidation form into 64 calls was strictly worse for the
            liquidator: it paid slightly more and, in the debt-specified form,
            received slightly less collateral. Lender assets remained exact,
            so no finding opened.
            Round 120 then held a fork-only Morpho borrower healthy through a
            professional assessment&apos;s inclusive deadline. One second later,
            with no new Forest Road transaction or risk-revision change, the
            assessment expired and the conservative fallback made the position
            liquidatable. A public liquidator earned about $3,405.48 and the
            disposable lender absorbed about $1,125.08. The oracle and market
            are not deployed, no current depositor funds were exposed, and the
            Medium/accepted result is now a launch control against carrying
            near-limit debt across an assessment deadline.
            Round 121 then removed the liquidator&apos;s prefunding assumption.
            A callback contract started with no USDC or sUSDfr, received the
            seized collateral before Morpho collected repayment, sold it
            through deployed liquidity and paid Morpho from the proceeds. It
            retained about $3,405.48 while the same disposable lender absorbed
            about $1,125.08. The integration remains undeployed, but launch
            controls must assume the expiry liquidation is self-financing.
            Round 122 then attacked the exact first multi-loan cash-payment
            package with every relevant permissionless accrual transition. A
            roleless outsider checkpointed all due boundaries, posted all five
            cash receivables and materialized both issuance legs before the
            threshold-approved Safe transaction. The exact $7,948.59 payment
            still completed, and economic supply, backing, vault assets, fee
            ownership, cash and all ten loan states matched payment-first
            control exactly. The caller received nothing, so no finding opened.
            Round 123 then challenged a planned external-lending recovery
            boundary. A zero-asset callback began liquidation under the
            conservative sUSDfr value, publicly executed an already-approved
            recovery, reposted the delivered collateral into the same market
            at the restored value and borrowed the repayment. It retained about
            $2,333.76 while the disposable lender booked about $1,290.48 of bad
            debt. This is a Medium/accepted pre-deployment launch risk, not a
            live High: the oracle and market are not deployed and current
            Forest Road depositors do not fund them.
            Round 124 then tested a genuine interest payment at the past-due
            boundary. A public mark immediately before the payment left the
            known D12-01 contribution standing and moved a deliberately
            near-limit future Morpho borrower from healthy to liquidatable.
            The strongest economic route did not work: a zero-capital callback
            could not cover repayment, while a prefunded 1,000-sUSDfr partial
            liquidation lost about $25.17 on its immediate deployed-market
            exit and caused no lender bad debt. This is a Medium/Open D12-01
            integration extension, not a new finding or live High; the planned
            market remains undeployed and the atomic cure control is already
            required before launch.
            Round 125 then attacked a different planned-market boundary: a
            compliant $1m direct USDfr exit during a roughly $463,709
            provisional impairment. The controller moved about $81,727 from
            live curator first-loss into equal prepaid-loss protection. The
            sUSDfr oracle stayed exactly unchanged, the exact-limit Morpho
            borrower remained healthy, public liquidation reverted, and both
            searcher profit and lender loss were zero. No finding opened.
            Round 126 then exhausted the complementary impaired-exit branch.
            About $2.468m of provisional marks overwhelmed the full $500,001
            curator layer, so a consenting $1m USDfr exit received about
            $896,761.48 and retained a $103,238.52 haircut. The planned oracle
            increased microscopically from conservative rounding; the
            exact-limit Morpho borrower stayed healthy, liquidation reverted,
            and searcher profit and lender loss were again zero. No finding
            opened.
            Round 127 carried that paid-forward junior protection through the
            loan&apos;s declaration and final loss realization. Declaration lowered
            one internal conservative view, but the planned oracle stayed at
            the backing floor that had already priced the provisional mark, so
            the loss was not counted twice. Public liquidation failed both
            before and after realization; the prepayment and temporary
            impairment cleared, and searcher profit and lender loss remained
            zero. No finding opened.
            Round 128 then removed both the capital and pre-existing-victim
            assumptions from the planned-market risk. An assetless contract
            flash-bought collateral, opened debt while a valid recovery
            assessment controlled the oracle, permissionlessly introduced a
            genuine new overdue mark, and self-liquidated after the oracle
            failed conservative. It repaid Aave and retained about $39.23
            while the disposable Morpho lender lost about $39.39. Mark-first
            control reverted healthy with state unchanged. This is a
            Medium/accepted pre-deployment launch blocker, not a live High:
            the oracle and market are undeployed and current Forest Road
            depositors did not fund the loss.
            Round 129 then challenged the distinct pre-expiry time path. A
            zero-interest test market isolated 29 days of active-assessment
            and live-vault accrual from external debt growth. Although the
            assessment reserved about 29,000 USDfr of new overdue exposure,
            the planned oracle rose from about 1.0282 to 1.0425 USDC per
            sUSDfr, increasing at the first second and every daily checkpoint.
            Full public liquidation reverted healthy, with no searcher profit
            or lender loss. No finding opened.
            Round 130 then moved permissionless accrual maintenance inside
            Morpho&apos;s collateral-first liquidation callback. Posting virtual
            interest and materializing both USDfr issuance legs left the
            planned oracle exactly unchanged. Reposting 1,000 sUSDfr supported
            a $559.94 recursive borrow against a $623.75 outer repayment, so
            the zero-capital route reverted atomically and still needed $63.81
            of outside capital. The partial liquidation caused no lender loss.
            No finding opened, and the campaign is paused at this reproducible
            checkpoint.
            Open findings and accepted
            risks elsewhere in the register still matter, and their assumptions
            are continuously challenged as the deployed state changes.
            These figures demonstrate a repeatable security process, not a
            guarantee against loss. Smart-contract, credit, liquidity, oracle,
            governance and operational risks remain, which is why findings and
            their current dispositions stay visible below.
          </HighlightBox>
        </div>
      </Section>

      {/* ── External review, separated. The distinction between an outside
             engagement and an internal round is the one a reader most needs
             to see, so it does not sit in the same list. ────────────────── */}
      {external.length > 0 ? (
        <Section tone="light">
          <SectionHead
            title={
              external.length === 1
                ? "One review conducted by a party other than Forest Road."
                : "Reviews conducted by a party other than Forest Road."
            }
            lede="An outside engagement carries weight an internal round cannot. Its stated scope and methodological limits remain part of the evidence and are published alongside the findings."
          />
          {/* A single outside engagement fills the row and splits internally,
              rather than sitting as one narrow card beside dead space. */}
          <div
            className={`mt-12 grid gap-6 ${
              external.length > 1 ? "lg:grid-cols-2" : ""
            }`}
          >
            {external.map((a) => {
              const solo = external.length === 1;
              return (
                <Link
                  key={a.slug}
                  href={`/docs/audit/${a.slug}`}
                  className={`panel panel-hover group flex h-full p-8 ${
                    solo ? "flex-col gap-8 lg:flex-row lg:gap-16" : "flex-col"
                  }`}
                >
                  <div className={solo ? "lg:w-[3.4in] lg:flex-none" : ""}>
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-2">
                      <span className="running-head text-accent">
                        {a.dateLabel}
                      </span>
                      <span className="running-head rounded-pill bg-navy px-2.5 py-[3px] text-on-navy">
                        {a.eyebrow}
                      </span>
                    </div>
                    <h2 className="display mt-5 text-[25px] leading-tight transition-colors group-hover:text-accent">
                      {a.title}
                    </h2>
                    <div
                      className={`flex flex-wrap items-center gap-x-4 gap-y-2 ${
                        solo ? "mt-7" : "hidden"
                      }`}
                    >
                      <SeverityMix findings={a.findings} />
                    </div>
                    <span
                      className={`text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5 ${
                        solo ? "mt-5 inline-block" : "hidden"
                      }`}
                    >
                      Read the report →
                    </span>
                  </div>

                  <div className="flex-1">
                    <p className="max-w-[64ch] text-[14px] leading-relaxed text-ink-muted">
                      {a.summary}
                    </p>
                    {solo ? null : (
                      <div className="mt-auto flex flex-wrap items-center gap-x-4 gap-y-2 pt-7">
                        <SeverityMix findings={a.findings} />
                        <span className="text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5">
                          Read the report →
                        </span>
                      </div>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        </Section>
      ) : null}

      {/* ── The internal programme, as a dated register. ────────────────── */}
      <Section tone="surface">
        <SectionHead
          title={
            <>
              {internal.length} internal rounds,{" "}
              <span className="display-accent">newest first.</span>
            </>
          }
          lede="Internal engineering reviews do not substitute for external audit. They are published on the same terms, every finding, every severity, every disposition."
        />

        <div className="mt-14">
          {internal.map((a, i) => (
            <Link
              key={a.slug}
              href={`/docs/audit/${a.slug}`}
              className={`group flex flex-col gap-4 py-7 transition-colors hover:bg-raised lg:flex-row lg:gap-12 ${
                i === 0 ? "border-t border-line-strong" : "border-t border-row"
              }`}
            >
              <div className="flex-none lg:w-[2.6in]">
                <span className="running-head block text-accent">
                  {a.eyebrow}
                </span>
                <span className="running-head mt-1.5 block">
                  {a.dateLabel}
                </span>
                <div className="mt-3.5">
                  <SeverityMix findings={a.findings} />
                </div>
              </div>

              <div className="flex-1">
                <h2 className="display text-[19px] leading-tight transition-colors group-hover:text-accent">
                  {a.title}
                </h2>
                <p className="mt-2.5 text-[14px] leading-relaxed text-ink-muted">
                  {a.summary}
                </p>
              </div>

              <span className="flex-none text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5">
                Read →
              </span>
            </Link>
          ))}
        </div>
      </Section>
    </PageShell>
  );
}
