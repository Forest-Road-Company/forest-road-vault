import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { ADDRESSES_SECTION, AUDIT_SECTION, DOCS } from "@/content/docs";
import {IS_TESTNET, NETWORK_NAME} from "@/config/contracts";

export const metadata: Metadata = {
  title: "Docs — Forest Road Vault",
  description:
    "Protocol documentation: overview, the safety-spec guarantees, the governance role model, and the security posture.",
};

export default function DocsIndex() {
  return (
    <PageShell
      eyebrow="Documentation"
      title="How the protocol is built, guaranteed, and governed."
      lede={`Written for reviewers and integrators. This build reads the ${NETWORK_NAME} deployment.${IS_TESTNET ? " Test tokens have no value." : ""}`}
    >
      <div className="mt-12 grid gap-4 sm:grid-cols-2">
        {DOCS.map((d) => (
          <Link
            key={d.slug}
            href={`/docs/${d.slug}`}
            className="group rounded-card border border-line bg-raised/70 p-6 transition-colors hover:border-moss/50 hover:bg-raised"
          >
            <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
              {d.eyebrow}
            </p>
            <h2 className="serif-display mt-2 text-[22px] leading-tight text-ink">
              {d.title}
            </h2>
            <p className="mt-2 text-[13.5px] leading-relaxed text-ink-muted">
              {d.summary}
            </p>
            <span className="mt-4 inline-block text-[12.5px] font-medium text-moss transition-transform group-hover:translate-x-0.5">
              Read →
            </span>
          </Link>
        ))}

        <Link
          href={AUDIT_SECTION.href}
          className="group rounded-card border border-line bg-raised/70 p-6 transition-colors hover:border-moss/50 hover:bg-raised"
        >
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
            {AUDIT_SECTION.eyebrow}
          </p>
          <h2 className="serif-display mt-2 text-[22px] leading-tight text-ink">
            {AUDIT_SECTION.title}
          </h2>
          <p className="mt-2 text-[13.5px] leading-relaxed text-ink-muted">
            {AUDIT_SECTION.summary}
          </p>
          <span className="mt-4 inline-block text-[12.5px] font-medium text-moss transition-transform group-hover:translate-x-0.5">
            Browse the rounds →
          </span>
        </Link>

        <Link
          href={ADDRESSES_SECTION.href}
          className="group rounded-card border border-line bg-raised/70 p-6 transition-colors hover:border-moss/50 hover:bg-raised"
        >
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
            {ADDRESSES_SECTION.eyebrow}
          </p>
          <h2 className="serif-display mt-2 text-[22px] leading-tight text-ink">
            {ADDRESSES_SECTION.title}
          </h2>
          <p className="mt-2 text-[13.5px] leading-relaxed text-ink-muted">
            {ADDRESSES_SECTION.summary}
          </p>
          <span className="mt-4 inline-block text-[12.5px] font-medium text-moss transition-transform group-hover:translate-x-0.5">
            View the table →
          </span>
        </Link>
      </div>
    </PageShell>
  );
}
