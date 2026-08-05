import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { PageShell } from "@/components/site/PageShell";
import { VERTICALS } from "@/lib/verticals";

export function generateStaticParams() {
  return VERTICALS.map((v) => ({ slug: v.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const v = VERTICALS.find((x) => x.slug === slug);
  return { title: v ? `${v.name} — Forest Road Vault` : "Verticals" };
}

export default async function VerticalPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const v = VERTICALS.find((x) => x.slug === slug);
  if (!v) notFound();

  return (
    <PageShell eyebrow="Collateral class" title={v.name} lede={v.financed}>
      <div className="mt-12 grid gap-5 lg:grid-cols-2">
        <div className="panel p-7">
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
            The claim
          </p>
          <p className="mt-3 text-[14px] leading-relaxed text-ink-muted">{v.claimType}</p>
          <p className="mt-5 font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
            Duration
          </p>
          <p className="mt-3 text-[14px] leading-relaxed text-ink-muted">{v.duration}</p>
          <p className="mt-5 font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
            Default remedy
          </p>
          <p className="mt-3 text-[14px] leading-relaxed text-ink-muted">{v.remedy}</p>
        </div>

        <div className="panel p-7">
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-gold">
            Risk stack
          </p>
          <ul className="mt-4 space-y-4">
            {v.risks.map((r) => (
              <li key={r.name}>
                <p className="text-[14px] font-medium text-ink">{r.name}</p>
                <p className="mt-1 text-[13.5px] leading-relaxed text-ink-muted">{r.detail}</p>
              </li>
            ))}
          </ul>
        </div>
      </div>

      <div className="mt-8 rounded-card border border-dashed border-line-strong bg-surface/60 p-6">
        <p className="font-mono text-[11px] tracking-wide text-ink-faint">
          Live class parameters (LTV cap, maturity and concentration headroom) are
          enforced on-chain by the CollateralRegistry. Interest rates and payment
          terms are signed per facility; clean v1 has no DSRA reserve sizing.
        </p>
      </div>
    </PageShell>
  );
}
