import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { Section, SectionHead, KpiBand, HighlightBox } from "@/components/site/Blocks";
import { VERTICALS } from "@/lib/verticals";
import {NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Verticals | Forest Road Vault",
};

const receivableCount = VERTICALS.filter(
  (v) => v.collateralModel === "receivable",
).length;
const mtmCount = VERTICALS.length - receivableCount;

/* One authored line-icon per class, drawn to the same stroke and weight
   rather than pulled from an icon font: each names the mechanism, not a
   decorative stand-in. currentColor so the tile controls the tint. */
function VerticalIcon({ slug }: { slug: string }) {
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
    case "film-tax-credits":
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
    case "life-sciences":
      return (
        <svg {...common}>
          <path d="M8 2.5h4M8.7 2.5v5.8l-4 8.1a1.9 1.9 0 0 0 1.7 2.7h7.2a1.9 1.9 0 0 0 1.7-2.7l-4-8.1V2.5" />
          <path d="M6.2 13.5h7.6" />
        </svg>
      );
    case "real-estate":
      return (
        <svg {...common}>
          <rect x="4" y="3.2" width="12" height="14.3" rx="0.8" />
          <path d="M4 9.6h12M8.3 3.2v14.3" />
          <rect x="9.9" y="12.4" width="2.6" height="5.1" />
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

export default function VerticalsPage() {
  return (
    <PageShell
      bleed
      section="Verticals"
      title="The five collateral classes"
      lede={`Each vertical is a governance-parameterized collateral class with its own LTV cap, maturity profile, concentration limits, and default-remedy path. Interest rates are signed per facility, not set by class, and clean v1 has no DSRA reserve sizing. The remaining class parameters are enforced on-chain by the CollateralRegistry, live on ${NETWORK_NAME}.`}
    >
      {/* ── The classes: an icon-led, colour-committed grid rather than a
             register, accent tint for legal foreclosure, warn tint for
             margin and liquidation, so the enforcement model reads before
             the copy does. ─────────────────────────────────────────────── */}
      <Section tone="surface">
        <SectionHead
          title={
            <>
              Five classes,{" "}
              <span className="display-accent">one enforcement model.</span>
            </>
          }
          lede="Four receivable-backed classes enforce through legal foreclosure on an assigned claim. The digital-assets class is marked to market and enforces through margin and liquidation instead. That's a different mechanism, disclosed as such."
        />

        <div className="mt-14 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {VERTICALS.map((v) => {
            const mtm = v.collateralModel === "marked-to-market";
            return (
              <Link
                key={v.slug}
                href={`/verticals/${v.slug}`}
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
                    <VerticalIcon slug={v.slug} />
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
                  {mtm ? "Margin & liquidation: " : "Legal foreclosure: "}
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
          title="Different assets, different clocks."
          lede="Duration, remedy path and valuation basis differ by class. Concentration limits are enforced on-chain so no single class can quietly dominate the book."
        />
        <div className="mt-12">
          <KpiBand
            items={[
              {
                value: VERTICALS.length,
                label: "Collateral classes",
                note: "Each with its own LTV cap and remedy path.",
              },
              {
                value: receivableCount,
                label: "Receivable-backed",
                note: "Enforced by legal foreclosure on an assigned claim.",
              },
              {
                value: mtmCount,
                label: "Marked-to-market",
                note: "Margin and liquidation mechanics, on a faster clock.",
              },
            ]}
            className="border border-navy-border"
          />
        </div>
        <div className="mt-8">
          <HighlightBox tone="navy-deep" title="Concentration is a parameter, not a promise">
            Class limits live in the CollateralRegistry and are readable
            on-chain. The current testnet deployment runs with those limits
            fully open, so nothing about the present class mix is evidence
            about a production configuration.
          </HighlightBox>
        </div>
      </Section>
    </PageShell>
  );
}
