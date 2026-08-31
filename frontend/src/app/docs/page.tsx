import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { Section, SectionHead } from "@/components/site/Blocks";
import { ADDRESSES_SECTION, AUDIT_SECTION, DOCS } from "@/content/docs";
import {IS_TESTNET, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Docs — Forest Road Vault",
  description:
    "Protocol documentation: overview, the safety-spec guarantees, the governance role model, and the security posture.",
};

const evidence = [AUDIT_SECTION, ADDRESSES_SECTION];
const EVIDENCE_CTA = ["Browse the rounds", "View the table"];

export default function DocsIndex() {
  return (
    <PageShell
      bleed
      section="Docs"
      title="Documentation"
      lede={`Written for reviewers and integrators. This build reads the ${NETWORK_NAME} deployment.${IS_TESTNET ? " Test tokens have no value." : ""}`}
    >
      {/* ── The written record: a contents register, which is what it is.
             An odd number of documents never divides into a card grid. ─── */}
      <Section tone="surface">
        <SectionHead
          title="The five documents."
          lede="Start with the overview. The other four cover the protocol's guarantees, who can change what, how defaults are priced at exit, and how the system is tested."
        />

        <div className="mt-14">
          {DOCS.map((d, i) => (
            <Link
              key={d.slug}
              href={`/docs/${d.slug}`}
              className={`group flex flex-col gap-4 py-7 transition-all hover:translate-x-1 hover:border-t-accent lg:flex-row lg:items-baseline lg:gap-12 ${
                i === 0 ? "border-t border-line-strong" : "border-t border-row"
              }`}
            >
              <span className="flex flex-none items-baseline gap-5 lg:w-[3.2in]">
                <span className="text-[11px] font-semibold tabular-nums tracking-[0.1em] text-accent">
                  {String(i + 1).padStart(2, "0")}
                </span>
                <span>
                  <span className="running-head block">{d.eyebrow}</span>
                  <span className="display mt-2 block text-[19px] leading-tight transition-colors group-hover:text-accent">
                    {d.title}
                  </span>
                </span>
              </span>
              <p className="flex-1 text-[14.5px] leading-relaxed text-ink-muted">
                {d.summary}
              </p>
              <span className="flex-none text-[12.5px] font-medium text-accent transition-transform group-hover:translate-x-0.5">
                Read →
              </span>
            </Link>
          ))}
        </div>
      </Section>

      {/* ── The verifiable record. Two destinations, so a two-up card row
             lands clean, and navy separates evidence from prose. ───────── */}
      <Section tone="navy-deep">
        <SectionHead
          tone="navy-deep"
          title="Verification"
          lede="Documentation states what the protocol intends. These two pages are where that intent can be reconciled against findings and against on-chain state."
        />
        <div className="mt-12 grid gap-6 md:grid-cols-2">
          {evidence.map((e, i) => (
            <Link
              key={e.href}
              href={e.href}
              className="group flex h-full flex-col rounded-card border border-navy-border bg-navy-deep p-8 transition-colors hover:border-on-navy-accent"
            >
              <p className="running-head text-on-navy-accent">{e.eyebrow}</p>
              <h2 className="display mt-4 text-[25px] leading-tight text-on-navy">
                {e.title}
              </h2>
              <p className="mt-4 text-[14px] leading-relaxed text-on-navy-muted">
                {e.summary}
              </p>
              <span className="mt-auto inline-block pt-7 text-[12.5px] font-medium text-on-navy-accent transition-transform group-hover:translate-x-0.5">
                {EVIDENCE_CTA[i]} →
              </span>
            </Link>
          ))}
        </div>
      </Section>
    </PageShell>
  );
}
