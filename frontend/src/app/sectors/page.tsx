import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { Section, SectionHead, KpiBand, HighlightBox } from "@/components/site/Blocks";
import { SECTORS } from "@/lib/verticals";
import {NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Sectors — Forest Road Vault",
};

const receivableCount = SECTORS.filter(
  (v) => v.collateralModel === "receivable",
).length;
const mtmCount = SECTORS.length - receivableCount;

/* One authored line-icon per sector, drawn to the same stroke and weight
   rather than pulled from an icon font — each names the mechanism, not a
   decorative stand-in. currentColor so the tile controls the tint. */
function SectorIcon({ slug }: { slug: string }) {
  const common = {
    viewBox: "0 0 20 20",
    fill: "none" as const,
    stroke: "currentColor",
    strokeWidth: 1.4,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true as const,
  };
  switch (slug) {
    case "media":
      return (
        <svg {...common}>
          <rect x="2.5" y="7" width="15" height="10.5" rx="1.2" />
          <path d="M3 7l2.5-4.2h3L6 7M9.5 7l2.5-4.2h3L12.5 7" />
        </svg>
      );
    case "renewable-energy":
      return (
        <svg {...common}>
          <circle cx="10" cy="10" r="3.6" />
          <path d="M10 2.2v2.3M10 15.5v2.3M2.2 10h2.3M15.5 10h2.3M4.8 4.8l1.6 1.6M13.6 13.6l1.6 1.6M4.8 15.2l1.6-1.6M13.6 6.4l1.6-1.6" />
        </svg>
      );
    case "digital-assets":
      return (
        <svg {...common}>
          <circle cx="10" cy="10" r="7.2" />
          <path d="M10 5.8v8.4M7.6 8.3c0-1.1 1-1.7 2.4-1.7s2.4.6 2.4 1.4-1 1.2-2.4 1.4-2.4.6-2.4 1.7 1 1.4 2.4 1.4 2.4-.6 2.4-1.7" />
        </svg>
      );
    default:
      return null;
  }
}

export default function SectorsPage() {
  return (
    <PageShell
      bleed
      section="Sectors"
      title="The three sectors"
      lede={`Each sector is a governance-parameterized collateral class with its own LTV cap, maturity profile, concentration limits, and default-remedy path. Interest rates are signed per facility, not set by sector. The remaining sector parameters are enforced on-chain by the CollateralRegistry, live on ${NETWORK_NAME}.`}
    >
      {/* ── The sectors: an icon-led, colour-committed grid rather than a
             register — accent tint for receivable-backed lending, warn tint
             for marked-to-market, so the collateral model reads before the
             copy does. ─────────────────────────────────────────────────── */}
      <Section tone="surface">
        <SectionHead
          title={
            <>
              Three sectors,{" "}
              <span className="display-accent">one loan book.</span>
            </>
          }
          lede="The receivable-backed sectors lend against assigned claims: tax credits and contracted receivables. The digital-assets sector is marked to market against liquid collateral. Different profiles, disclosed as such."
        />

        <div className="mt-14 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {SECTORS.map((v) => {
            const mtm = v.collateralModel === "marked-to-market";
            return (
              <Link
                key={v.slug}
                href={`/sectors/${v.slug}`}
                className={`group flex h-full flex-col p-7 transition-opacity hover:opacity-90 ${
                  mtm ? "bg-warn-faint" : "bg-accent-faint"
                }`}
              >
                <div className="flex items-center gap-4">
                  <div
                    className={`flex h-11 w-11 flex-none items-center justify-center rounded-full ${
                      mtm ? "bg-warn text-on-navy" : "bg-accent text-on-navy"
                    }`}
                  >
                    <SectorIcon slug={v.slug} />
                  </div>
                  <h3 className="display text-[19px] leading-tight">
                    {v.name}
                  </h3>
                </div>
                <p
                  className={`running-head mt-4 inline-block self-start rounded-pill px-2.5 py-[3px] ${
                    mtm ? "bg-warn text-on-navy" : "bg-accent text-on-navy"
                  }`}
                >
                  {mtm ? "Marked-to-market · related party" : "Receivable-backed"}
                </p>
                <p className="mt-4 text-[14.5px] leading-relaxed text-ink-muted">
                  {v.financed}
                </p>
                <div
                  className={`mt-5 h-px w-full ${mtm ? "bg-warn/25" : "bg-accent/20"}`}
                />
                <p
                  className={`running-head mt-4 leading-relaxed ${
                    mtm ? "text-warn" : "text-accent"
                  }`}
                >
                  {v.duration}
                </p>
              </Link>
            );
          })}
        </div>
      </Section>

      {/* ── Navy moment: the shape of the book in numbers. Deep navy, so the
             closing band steps away from the footer rather than merging with
             it into one dark mass. ──────────────────────────────────────── */}
      <Section tone="navy-deep">
        <SectionHead
          tone="navy-deep"
          title="Different assets, different profiles."
          lede="Duration, remedy path and valuation basis differ by sector. Concentration limits are enforced on-chain so no single sector can quietly dominate the book."
        />
        <div className="mt-12">
          <KpiBand
            items={[
              {
                value: SECTORS.length,
                label: "Sectors",
                note: "Each with its own LTV cap and remedy path.",
              },
              {
                value: receivableCount,
                label: "Receivable-backed",
                note: "Lending against assigned claims and contracted receivables.",
              },
              {
                value: mtmCount,
                label: "Marked-to-market",
                note: "Secured by liquid collateral, monitored continuously.",
              },
            ]}
            className="border border-navy-border"
          />
        </div>
        <div className="mt-8">
          <HighlightBox tone="navy-deep" title="Concentration is a parameter, not a promise">
            Sector limits live in the CollateralRegistry and are readable
            on-chain. The current testnet deployment runs with those limits
            fully open, so nothing about the present sector mix is evidence
            about a production configuration.
          </HighlightBox>
        </div>
      </Section>
    </PageShell>
  );
}
