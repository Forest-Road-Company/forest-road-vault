import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { PageShell } from "@/components/site/PageShell";
import { Section } from "@/components/site/Blocks";
import { SECTORS } from "@/lib/verticals";

export function generateStaticParams() {
  return SECTORS.map((v) => ({ slug: v.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const v = SECTORS.find((x) => x.slug === slug);
  return { title: v ? `${v.name} | Forest Road Vault` : "Sectors" };
}

export default async function SectorPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const v = SECTORS.find((x) => x.slug === slug);
  if (!v) notFound();

  const mtm = v.collateralModel === "marked-to-market";
  const others = SECTORS.filter((x) => x.slug !== v.slug);

  /* The sector's own terms, as a definition list rather than four hand-rolled
     labels stacked in a panel. */
  const terms = [
    { term: "The claim", detail: v.claimType },
    { term: "Duration", detail: v.duration },
    { term: "Default remedy", detail: v.remedy },
  ];

  return (
    <PageShell
      bleed
      section="Sector"
      title={v.name}
      lede={v.financed}
    >
      <Section tone="surface">
        <p
          className={`running-head inline-block rounded-pill border px-3 py-1 ${
            mtm
              ? "border-warn/40 bg-warn-faint text-warn"
              : "border-line-strong text-ink-value"
          }`}
        >
          {mtm
            ? "Marked-to-market · related party"
            : "Receivable-backed · lending against assigned claims"}
        </p>

        <div className="mt-12 grid gap-x-20 gap-y-14 lg:grid-cols-2">
          <div>
            <h2 className="display text-[25px] leading-tight">
              How the claim is held
            </h2>
            <dl className="mt-7">
              {terms.map((t, i) => (
                <div
                  key={t.term}
                  className={`py-5 ${
                    i === 0
                      ? "border-t border-line-strong"
                      : "border-t border-row"
                  }`}
                >
                  <dt className="running-head text-accent">{t.term}</dt>
                  <dd className="mt-2.5 max-w-[56ch] text-[15px] leading-relaxed text-ink-muted">
                    {t.detail}
                  </dd>
                </div>
              ))}
            </dl>
          </div>

          <div>
            <h2 className="display text-[25px] leading-tight">
              What can go wrong
            </h2>
            <ul className="mt-7">
              {v.risks.map((r, i) => (
                <li
                  key={r.name}
                  className={`py-5 ${
                    i === 0
                      ? "border-t border-line-strong"
                      : "border-t border-row"
                  }`}
                >
                  <p className="display text-[16px] leading-snug">{r.name}</p>
                  <p className="mt-2 max-w-[56ch] text-[15px] leading-relaxed text-ink-muted">
                    {r.detail}
                  </p>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <div className="highlight-box mt-14 px-7 py-6">
          <p className="max-w-[76ch] text-[14px] leading-relaxed text-ink-muted">
            Live sector parameters (LTV cap, maturity and concentration headroom)
            are enforced on-chain by the CollateralRegistry and are not
            restated here, so this page cannot drift from them. Interest rates
            and payment terms are signed per facility. The current testnet
            deployment runs its concentration limits fully open, so the present
            sector mix is not evidence of a production configuration.{" "}
            <Link href="/transparency" className="u-link font-medium text-accent">
              Read current state →
            </Link>
          </p>
        </div>
      </Section>

      {/* ── Sibling rail. A sector page that dead-ends sends the reader back to
             the index to reach the next one. ──────────────────────────────── */}
      <Section tone="light">
        <div className="flex flex-wrap items-baseline justify-between gap-4">
          <h2 className="display text-[25px] leading-tight">
            The other sectors
          </h2>
          <Link
            href="/sectors"
            className="u-link inline-flex min-h-[24px] items-center text-[13px] font-semibold uppercase tracking-[0.14em] text-accent"
          >
            All three, compared →
          </Link>
        </div>

        <div className="mt-10">
          {others.map((o, i) => (
            <Link
              key={o.slug}
              href={`/sectors/${o.slug}`}
              className={`group flex flex-col gap-3 py-6 transition-colors hover:bg-surface sm:flex-row sm:items-baseline sm:gap-10 ${
                i === 0 ? "border-t border-line-strong" : "border-t border-row"
              }`}
            >
              <span className="display flex-none text-[19px] leading-snug transition-colors group-hover:text-accent sm:w-[3in]">
                {o.name}
              </span>
              <span className="flex-1 text-[15px] leading-relaxed text-ink-muted">
                {o.claimType}
              </span>
              <span className="running-head flex-none sm:w-[1.6in]">
                {o.collateralModel === "marked-to-market"
                  ? "Marked-to-market"
                  : "Receivable-backed"}
              </span>
            </Link>
          ))}
        </div>
      </Section>
    </PageShell>
  );
}
