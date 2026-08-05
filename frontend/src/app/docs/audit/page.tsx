import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import { SeverityMix } from "@/components/site/AuditFindings";
import { AUDITS, openFindings, totalFindings } from "@/content/audits";

export const metadata: Metadata = {
  title: "Audit Register — Forest Road Vault",
  description:
    "Every source-level security review run against the protocol, newest first, each with its own findings and remediation history.",
};

export default function AuditRegisterPage() {
  const rounds = AUDITS.length;
  const findings = totalFindings();
  const open = openFindings().length;

  return (
    <PageShell
      eyebrow="Assurance"
      title="Audit register"
      lede="Every source-level review run against this protocol, newest first. Each round keeps its own findings list and its own remediation history, including the findings that were accepted rather than fixed."
    >
      <div className="mt-10 grid gap-4 sm:grid-cols-3">
        <Stat label="Review rounds" value={String(rounds)} />
        <Stat label="Findings published" value={String(findings)} />
        <Stat
          label="Still open or accepted"
          value={String(open)}
          hint="Counted as open unless remediated or superseded."
        />
      </div>

      <div className="mt-6 rounded-card border border-line bg-moss-faint/60 p-5">
        <p className="text-[13.5px] leading-relaxed text-ink-muted">
          <strong className="text-ink">Published in full, open findings included</strong> —
          because a protocol that custodies capital against legal claims should be reviewable
          before it is trusted. Most of these are internal engineering reviews, which are{" "}
          <em>not</em> a substitute for external audit. Reviews conducted by a party other
          than Forest Road are labelled external on their own page, and the limits of any
          engagement should be read alongside its findings. No review here by itself
          authorizes a mainnet launch. Nothing on this page is a securities-law
          representation; token characterization is a matter for counsel.
        </p>
      </div>

      <ol className="mt-10 space-y-4">
        {AUDITS.map((a) => (
          <li key={a.slug}>
            <Link
              href={`/docs/audit/${a.slug}`}
              className="group block rounded-card border border-line bg-raised/70 p-6 transition-colors hover:border-moss/50 hover:bg-raised"
            >
              <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                <span className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
                  {a.dateLabel}
                </span>
                <span className="font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
                  {a.eyebrow}
                </span>
              </div>
              <h2 className="serif-display mt-2 text-[23px] leading-tight text-ink">
                {a.title}
              </h2>
              <p className="mt-2 text-[13.5px] leading-relaxed text-ink-muted">
                {a.summary}
              </p>
              <div className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2">
                <SeverityMix findings={a.findings} />
                <span className="text-[12.5px] font-medium text-moss transition-transform group-hover:translate-x-0.5">
                  Read the report →
                </span>
              </div>
            </Link>
          </li>
        ))}
      </ol>
    </PageShell>
  );
}

function Stat({
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint?: string;
}) {
  return (
    <div className="rounded-card border border-line bg-raised/70 p-5">
      <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
        {label}
      </p>
      <p className="serif-display mt-1.5 text-[32px] leading-none text-ink">{value}</p>
      {hint ? (
        <p className="mt-2 text-[12px] leading-relaxed text-ink-faint">{hint}</p>
      ) : null}
    </div>
  );
}
