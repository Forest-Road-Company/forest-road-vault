import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { IS_MAINNET } from "@/config/contracts";

export const metadata: Metadata = { title: "Terms — Forest Road Vault" };

export default function TermsPage() {
  return (
    <PageShell
      section="Legal"
      title="Terms of use"
      lede={
        IS_MAINNET
          ? "Use of the Ethereum mainnet application involves real assets and is limited to eligible, verified participants under the definitive agreements accepted during onboarding."
          : "Placeholder terms for the testnet preview. Definitive terms of use require counsel approval before any production launch."
      }
    >
      <div className="mt-10 max-w-3xl space-y-6 text-[14.5px] leading-relaxed text-ink-muted">
        <p>
          {IS_MAINNET
            ? "Access is KYC-gated. Your use remains subject to the definitive legal agreements, eligibility restrictions, risk disclosures, and any jurisdictional limits presented during onboarding. This page summarizes the application posture and does not replace those agreements."
            : "This site and the associated testnet deployment are provided for demonstration and development review only, as-is, without warranty of any kind. No feature of this site constitutes an offer, solicitation, or financial service."}
        </p>
        <p>
          {IS_MAINNET
            ? "Transactions are real and irreversible. Yield is variable, capital is at risk, queued redemptions are not instant, and no displayed estimate is a guarantee of settlement value or future return."
            : "Test tokens have no value. Any wallet interactions target test networks exclusively."}
        </p>
        {IS_MAINNET ? (
          <p>
            Nothing on this site is legal, tax, accounting, or investment advice.
          </p>
        ) : null}
      </div>
    </PageShell>
  );
}
