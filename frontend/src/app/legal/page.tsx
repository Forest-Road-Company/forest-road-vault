import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { IS_MAINNET } from "@/config/contracts";
import { ProtocolScene } from "@/components/site/ProtocolScene";

export const metadata: Metadata = {
  title: "Disclosures | Forest Road Vault",
  description:
    "Deployment status, eligibility, fees, governance, conflicts, risks, and legal disclosures for Forest Road Vault.",
};

export default function LegalPage() {
  return (
    <PageShell
      section="Legal"
      title="Disclosures"
      lede="The disclosures, stated plainly."
      visual={<ProtocolScene scene="docs" />}
    >
      <div className="mt-10 max-w-3xl space-y-6 text-[14.5px] leading-relaxed text-ink-muted">
        <p>
          Forest Road Vault is a credit protocol. References to Forest Road in
          marketing copy mean The Forest Road Company, LLC.{" "}
          {IS_MAINNET ? (
            <>
              The application reads contracts deployed on{" "}
              <span className="text-ink">Ethereum mainnet</span>. A contract
              deployment is not, by itself, a public product launch or an offer.
              Enabled transactions can involve real assets and remain subject to
              the applicable eligibility controls and definitive agreements.
            </>
          ) : (
            <>
              This preview connects only to <span className="text-ink">Sepolia</span>;
              its balances, addresses, and transactions use valueless test assets.
              A separate Ethereum mainnet contract deployment exists. This preview
              is not that application and does not evidence that a legal,
              operational, or product-entry gate has closed.
            </>
          )}
        </p>
        <p>
          <span className="text-ink">Token characterization is a matter for counsel.</span>{" "}
          The protocol&apos;s instruments (USDfr, sUSDfr, GROVE, and sGROVE) have
          the characterization set out in the definitive legal materials; nothing
          on this site independently claims they are or are not securities.{" "}
          Securities-counsel review, definitive legal and onboarding documents,
          external security review, and economic and operational approvals remain
          gates for each relevant product or entry path until they are documented
          as closed. Deploying contracts does not close those gates.
        </p>
        <p>
          <span className="text-ink">Yield is variable.</span> sUSDfr passes
          through the net performance of the loan book and reserves via its
          exchange rate. The presently published configuration includes a 2%
          origination fee, a 10% protocol share of recognized facility interest,
          a 10% performance fee above one protocol-wide high-water mark, and a
          0% management fee. Their timelocked caps are 10%, 20%, 20%, and 2%
          annually, respectively. On-chain settings and definitive documents
          govern and may change prospectively.
          Vault-level fees are paid through share dilution. The high-water mark
          is global, not personal to a participant&apos;s entry price, and
          crystallized fees are not clawed back after a later loss. No fixed
          return is promised, and depositors bear underlying credit performance,
          subject to the documented loss cascade: a structural ordering of
          losses, not a guarantee against them.
        </p>
        <p>
          <span className="text-ink">Governance is Forest-Road-controlled at launch.</span>{" "}
          The full governance machinery exists on-chain, but Forest Road holds
          effective control of parameters and upgrades initially. Progressive
          decentralization is a roadmap item, not a present fact.
        </p>
        <p>
          <span className="text-ink">One sector is a related-party facility.</span>{" "}
          The digital-assets sector finances Forest Road&apos;s own
          trading subsidiary. That conflict of interest is disclosed
          here and on the risk page, is subject to on-chain concentration
          limits and arm&apos;s-length-terms review, and is an explicit item in
          {IS_MAINNET ? " ongoing economic and governance review." : " the launch economic review."}
        </p>
        <p>
          Nothing on this site is legal, tax, accounting, or investment advice.
        </p>
      </div>
    </PageShell>
  );
}
