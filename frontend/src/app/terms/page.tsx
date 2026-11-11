import type { Metadata } from "next";
import { pageMetadata } from "@/lib/shareCards";
import { PageShell } from "@/components/site/PageShell";
import { IS_MAINNET } from "@/config/contracts";
import { ProtocolScene } from "@/components/site/ProtocolScene";

export const metadata: Metadata = pageMetadata({
  title: "Terms | Forest Road Vault",
  description:
    "Terms of use for the Forest Road Vault website and application, and how they relate to the definitive agreements, eligibility controls and risk disclosures for each path.",
  socialTitle: "Terms of use | Forest Road Vault",
});

export default function TermsPage() {
  return (
    <PageShell
      section="Legal"
      title="Terms of use"
      lede={
        IS_MAINNET
          ? "The Ethereum mainnet application reads deployed contracts and may involve real assets. Any available interaction remains subject to its applicable eligibility controls and definitive agreements."
          : "Terms for the Sepolia preview. A separate Ethereum mainnet contract deployment exists and is governed by its own definitive terms, eligibility controls, and launch status."
      }
      visual={<ProtocolScene scene="docs" />}
    >
      <div className="mt-10 max-w-3xl space-y-6 text-[14.5px] leading-relaxed text-ink-muted">
        <p>
          {IS_MAINNET
            ? "Primary-market minting and instant redemption are KYC-gated on-chain. Other interactions may have different controls. Your use remains subject to the definitive legal agreements, eligibility restrictions, risk disclosures, and jurisdictional limits presented for the relevant path. This page does not replace those agreements."
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
