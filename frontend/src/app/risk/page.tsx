import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import {IS_MAINNET, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = { title: "Risk factors — Forest Road Vault" };

const risks = [
  {
    name: "Credit risk",
    detail:
      "Borrowers may fail to repay. First-loss capital and the backstop absorb losses in a fixed order, but losses beyond both layers impair depositor principal.",
  },
  {
    name: "Attestation trust",
    detail:
      "On-chain state reflects what authorized attesters assert about off-chain legal facts. A false attestation or compromised attester key means the protocol acts on false information. This is the protocol's primary trust assumption.",
  },
  {
    name: "Per-vertical asset risk",
    detail:
      "Film credits carry issuance-timing, audit/clawback, state-counterparty, and secondary-price risk. Renewables carry construction/completion risk. Life sciences carry clinical/milestone risk. Real estate carries valuation and foreclosure-timeline risk.",
  },
  {
    name: "Related-party exposure (digital assets class)",
    detail:
      `The digital-assets vertical lends to Forest Road's own trading subsidiary. Forest Road is simultaneously originator, servicer, and borrower-affiliate for that class — a structural conflict of interest. It is mitigated by arm's-length terms, on-chain concentration caps, conservative dynamic LTV with margin-call/liquidation mechanics, and plain disclosure. ${IS_MAINNET ? "Its launch approval does not eliminate the conflict; it remains subject to ongoing review." : "It must be expressly considered in the launch economic review."}`,
  },
  {
    name: "Crypto-collateral volatility (digital assets class)",
    detail:
      "Unlike the receivable classes, the digital-assets class is secured by liquid, price-volatile crypto positions that can gap through margin levels faster than remedies execute. Valuation freshness rules, conservative LTV, and rapid liquidation paths reduce — not eliminate — this risk.",
  },
  {
    name: "Liquidity timing",
    detail:
      "The underlying is illiquid, amortizing credit. sUSDfr redemptions queue by epoch and may take multiple epochs to fill. Do not stake capital you may need on demand.",
  },
  {
    name: "Smart-contract risk",
    detail:
      IS_MAINNET
        ? "Contracts can contain defects despite testing, invariant fuzzing, and independent audits. Audits and monitoring reduce, but do not eliminate, this risk."
        : "Contracts can contain defects despite testing and invariant fuzzing. Mainnet deployment is gated on independent audits — and audits reduce, not eliminate, this risk.",
  },
  {
    name: "Regulatory risk",
    detail:
      "The regulatory treatment of tokenized credit instruments is unsettled and varies by jurisdiction. Access is KYC-gated and jurisdiction-restricted; rules may change adversely after launch.",
  },
  {
    name: "Secondary-market risk",
    detail:
      "Default recovery for credit-backed classes depends on selling assigned receivables into secondary markets whose prices and depth vary.",
  },
  {
    name: "Assessed redemption value",
    detail:
      `The ${NETWORK_NAME} deployment routes queue pricing through the live assessment wrapper, which falls back to the conservative zero-recovery mark unless governance publishes a current, evidence-backed assessment. Any assessment can change or invalidate before settlement. No recovery top-up distributor is deployed or promised in clean v1; any future top-up would require separate approval and funding.`,
  },
] as const;

export default function RiskPage() {
  return (
    <PageShell
      eyebrow="Risk"
      title="Risk factors"
      lede="An honest protocol names its risks specifically. These are the material ones; the documentation covers each in depth."
    >
      <div className="mt-10 max-w-3xl space-y-6">
        {risks.map((r) => (
          <div key={r.name} className="border-l-2 border-moss/30 pl-5">
            <h2 className="font-grotesk text-[16px] font-semibold tracking-tight text-ink">
              {r.name}
            </h2>
            <p className="mt-1.5 text-[14px] leading-relaxed text-ink-muted">{r.detail}</p>
          </div>
        ))}
      </div>
    </PageShell>
  );
}
