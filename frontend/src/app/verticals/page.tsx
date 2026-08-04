import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { VERTICALS } from "@/lib/verticals";
import {NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Verticals — Forest Road Vault",
};

export default function VerticalsPage() {
  return (
    <PageShell
      eyebrow="Verticals"
      title="The five collateral classes"
      lede={`Each vertical is a governance-parameterized collateral class with its own LTV cap, maturity profile, concentration limits, and default-remedy path. Interest rates are signed per facility, not set by class, and clean v1 has no DSRA reserve sizing. The remaining class parameters are enforced on-chain by the CollateralRegistry, live on ${NETWORK_NAME}.`}
    >
      <div className="mt-12 grid gap-5 md:grid-cols-2">
        {VERTICALS.map((v) => (
          <Link
            key={v.slug}
            href={`/verticals/${v.slug}`}
            className="panel panel-hover group flex h-full flex-col p-7"
          >
            <h2 className="font-grotesk text-xl font-semibold tracking-tight group-hover:text-moss-bright">
              {v.name}
            </h2>
            <p className="mt-2 text-[14px] leading-relaxed text-ink-muted">{v.financed}</p>
            <p className="mt-auto pt-4 font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint">
              {v.duration}
            </p>
            <p className="mt-2 inline-block self-start rounded-pill border border-line px-2.5 py-1 font-mono text-[9.5px] uppercase tracking-[0.14em] text-ink-muted">
              {v.collateralModel === "marked-to-market" ? "Marked-to-market · related party" : "Receivable-backed"}
            </p>
          </Link>
        ))}
      </div>
    </PageShell>
  );
}
