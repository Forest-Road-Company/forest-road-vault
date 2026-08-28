import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { IS_MAINNET } from "@/config/contracts";

export const metadata: Metadata = { title: "Disclosures | Forest Road Vault" };

export default function LegalPage() {
  return (
    <PageShell
      section="Legal"
      title="Disclosures"
      lede="Stated plainly, because getting this wrong helps nobody."
    >
      <div className="mt-10 max-w-3xl space-y-6 text-[14.5px] leading-relaxed text-ink-muted">
        <p>
          Forest Road Vault is a KYC-gated, legally-wrapped real-world-asset
          credit protocol.{" "}
          {IS_MAINNET ? (
            <>
              The application connects to <span className="text-ink">Ethereum mainnet</span>.
              Transactions involve real assets and are available only to eligible,
              verified participants under the definitive onboarding agreements.
            </>
          ) : (
            <>
              Everything on this site describes a system running on{" "}
              <span className="text-ink">test networks only</span>, with no real capital,
              no live instruments, and no offer of any kind.
            </>
          )}
        </p>
        <p>
          <span className="text-ink">Token characterization is a matter for counsel.</span>{" "}
          The protocol&apos;s instruments (USDfr, sUSDfr, GROVE, and sGROVE) have
          the characterization set out in the definitive legal materials; nothing
          on this site independently claims they are or are not securities.{" "}
          {IS_MAINNET
            ? "Production operation remains subject to the applicable legal wrapper, counsel-approved controls, external security review, and approved economic parameters."
            : "A written securities-counsel opinion is a hard, blocking gate before any mainnet deployment, alongside external smart-contract audits, an executed off-chain legal wrapper, and an economic review of protocol parameters."}
        </p>
        <p>
          <span className="text-ink">Yield is variable.</span> sUSDfr passes
          through the net performance of the loan book and reserves via its
          exchange rate. At launch, 10% of realized gross interest goes to the
          protocol; sUSDfr then charges 10% of conservative protocol-wide
          high-water-mark profit. Timelocked governance may vary performance
          prospectively up to 20%. Management starts at 0% and may vary
          prospectively up to 2% annually in v1. Each change crystallizes the
          old rate first.
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
          <span className="text-ink">One vertical is a related-party facility.</span>{" "}
          The digital-assets collateral class finances Forest Road&apos;s own
          trading subsidiary. That conflict of interest is disclosed plainly
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
