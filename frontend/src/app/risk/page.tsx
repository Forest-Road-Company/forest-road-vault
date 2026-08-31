import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import {
  Section,
  SectionHead,
  NumberedRows,
  CardDeck,
  HighlightBox,
} from "@/components/site/Blocks";
import {IS_MAINNET, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = { title: "Risk factors — Forest Road Vault" };

/**
 * Risk copy is disclosure material and is reproduced verbatim. The grouping
 * below is presentational only: the attestation assumption is pulled out
 * because the text itself calls it the primary one, class-specific risks are
 * separated from protocol-level ones, and nothing is reworded or dropped.
 */

const ATTESTATION = {
  name: "Attestation trust",
  detail:
    "On-chain state reflects what authorized attesters assert about off-chain legal facts. A false attestation or compromised attester key means the protocol acts on false information. This is the protocol's primary trust assumption.",
};

const protocolRisks = [
  {
    label: "Credit risk",
    body: "Borrowers may fail to repay. First-loss capital and the backstop absorb losses in a fixed order, but losses beyond both layers impair depositor principal.",
  },
  {
    label: "Liquidity timing",
    body: "The underlying is illiquid, amortizing credit. sUSDfr redemptions queue in fixed redemption windows (epochs) and may take multiple windows to fill. Do not stake capital you may need on demand.",
  },
  {
    label: "Smart-contract risk",
    body: IS_MAINNET
      ? "Contracts can contain defects despite testing, invariant fuzzing, and independent audits. Audits and monitoring reduce, but do not eliminate, this risk."
      : "Contracts can contain defects despite testing and invariant fuzzing. Mainnet deployment is gated on independent audits, and audits reduce, not eliminate, this risk.",
  },
  {
    label: "Regulatory risk",
    body: "The regulatory treatment of tokenized credit instruments is unsettled and varies by jurisdiction. Access is KYC-gated and jurisdiction-restricted; rules may change adversely after launch.",
  },
  {
    label: "Secondary-market risk",
    body: "Default recovery for credit-backed classes depends on selling assigned receivables into secondary markets whose prices and depth vary.",
  },
  {
    label: "Assessed redemption value",
    body: `The ${NETWORK_NAME} deployment routes queue pricing through the live assessment wrapper, which falls back to the conservative zero-recovery mark unless governance publishes a current, evidence-backed assessment. Any assessment can change or invalidate before settlement. No recovery top-up distributor is deployed or promised in v1; any future top-up would require separate approval and funding.`,
  },
];

const classRisks = [
  {
    title: "Per-sector asset risk",
    body: "Media & entertainment receivables carry payment-timing, audit/clawback, obligor-counterparty, and secondary-price risk. Renewables carry construction/completion risk. Each sector's risks are set out on its own page.",
  },
  {
    title: "Related-party exposure (digital assets sector)",
    body: `The digital-assets sector lends to Forest Road's own trading subsidiary. Forest Road is simultaneously originator, servicer, and borrower-affiliate for that sector, a structural conflict of interest. It is mitigated by arm's-length terms, on-chain concentration caps, conservative dynamic LTV with margin-call/liquidation mechanics, and plain disclosure. ${IS_MAINNET ? "Its launch approval does not eliminate the conflict; it remains subject to ongoing review." : "It must be expressly considered in the launch economic review."}`,
  },
  {
    title: "Crypto-collateral volatility (digital assets sector)",
    body: "Unlike the receivable-backed sectors, the digital-assets sector is secured by liquid, price-volatile crypto positions that can gap through margin levels faster than remedies execute. Valuation freshness rules, conservative LTV, and rapid liquidation paths reduce, but do not eliminate, this risk.",
  },
];

export default function RiskPage() {
  return (
    <PageShell
      bleed
      section="Risk"
      title="Risk factors"
      lede="These are the material risks. The documentation covers each one in depth."
    >
      {/* ── The primary trust assumption, given its own band. ───────────── */}
      {/* The callout sits under the headline in the left column rather than
          below the detail on the right: a two-word headline at display scale
          left the left half of this band empty. */}
      <Section tone="navy">
        <div className="flex flex-col gap-10 lg:flex-row lg:gap-20">
          <div className="lg:w-[36%] lg:flex-none">
            <SectionHead tone="navy" title={ATTESTATION.name} />
            <div className="mt-9">
              <HighlightBox tone="navy">
                Every other risk on this page sits downstream of this one. If
                the attested facts are wrong, the on-chain record is wrong, and
                the remedies below execute against a position that does not
                exist as described.
              </HighlightBox>
            </div>
          </div>
          <div className="flex-1">
            <p className="max-w-[62ch] text-[19px] leading-relaxed text-on-navy-muted">
              {ATTESTATION.detail}
            </p>
          </div>
        </div>
      </Section>

      {/* ── Protocol-level risks: numbered register. ────────────────────── */}
      <Section tone="surface">
        <SectionHead
          title="Risks that apply across the whole book."
        />
        <NumberedRows
          heading="Six that affect every depositor."
          aside={
            <>
              These are structural to the design rather than to any one
              collateral class. None of them is eliminated by the loss
              cascade. The cascade governs the order in which losses land,
              not whether they occur.
            </>
          }
          rows={protocolRisks}
        />
      </Section>

      {/* ── Class-specific risks: three cards, three columns, no orphan. ── */}
      <Section tone="light">
        <SectionHead
          title="Risks that attach to particular collateral."
          lede="Each sector carries its own risks, set out in full on its own page. The related-party exposure is disclosed plainly."
        />
        <CardDeck columns={3} items={classRisks} />
      </Section>
    </PageShell>
  );
}
