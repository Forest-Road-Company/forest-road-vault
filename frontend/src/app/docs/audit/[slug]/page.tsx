import fs from "node:fs";
import path from "node:path";
import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import ReactMarkdown from "react-markdown";
import { AuditFindingsList } from "@/components/site/AuditFindings";
import { AUDITS, auditBySlug } from "@/content/audits";

export function generateStaticParams() {
  return AUDITS.map((a) => ({ slug: a.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const audit = auditBySlug(slug);
  if (!audit) return { title: "Audit — Forest Road Vault" };
  return {
    title: `${audit.title} — Forest Road Vault`,
    description: audit.summary,
  };
}

function readAudit(file: string): string {
  const full = path.join(process.cwd(), "src/content/docs", file);
  const md = fs.readFileSync(full, "utf8");
  // Drop the leading H1 (the page header renders the title itself).
  return md.replace(/^#\s+.*(\r?\n)+/, "");
}

export default async function AuditReportPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const audit = auditBySlug(slug);
  if (!audit) notFound();

  const markdown = readAudit(audit.file);
  const idx = AUDITS.findIndex((a) => a.slug === slug);
  // AUDITS is newest-first, so the "next" link walks backwards in time.
  const older = AUDITS[idx + 1];

  return (
    <div className="mx-auto max-w-3xl px-5 py-20">
      {/* Round and date do wayfinding work in a dated register, so they live
          in the trail rather than sitting as a kicker above the heading. */}
      <nav aria-label="Breadcrumb">
        <ol className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <li>
            <Link
              href="/docs/audit"
              className="running-head transition-colors hover:text-ink"
            >
              Audit register
            </Link>
          </li>
          <li aria-hidden className="running-head">
            /
          </li>
          <li>
            <span aria-current="page" className="running-head text-accent">
              {audit.eyebrow} · {audit.dateLabel}
            </span>
          </li>
        </ol>
      </nav>
      <div className="rule-head mt-3" />
      <h1 className="display mt-10 text-[31px] leading-[1.1] text-ink md:text-[46px]">
        {audit.title}
      </h1>

      <div className="mt-8 rounded-card border border-line bg-accent-faint/60 p-5">
        <p className="text-[13.5px] leading-relaxed text-ink-muted">
          {audit.external ? (
            <>
              <strong className="text-ink">External review.</strong> This review was
              conducted by a party other than Forest Road. What the engagement did and did
              not cover is set out under Method and in the report itself — the limits of a
              review bear on what its findings are worth, and should be read alongside them.
              It does not by itself authorize a production launch.
            </>
          ) : (
            <>
              <strong className="text-ink">Internal review.</strong> This is an internal
              engineering review of source, not an independent external audit, and it does
              not by itself authorize a production launch.
            </>
          )}{" "}
          It reviews the source at the baseline below, which is not necessarily identical to
          the code deployed on any network. A tightly restricted disposable mainnet test is
          authorized under the runbook, but no mainnet broadcast has been attempted and no
          public production launch is authorized. Nothing here is a securities-law
          representation; token characterization is a matter for counsel.
        </p>
      </div>

      <dl className="mt-8 grid gap-x-8 gap-y-4 sm:grid-cols-2">
        <Meta term="Scope" value={audit.scope} />
        <Meta term="Method" value={audit.method} />
        {audit.baseline ? <Meta term="Reviewed baseline" value={audit.baseline} mono /> : null}
        {audit.archive ? <Meta term="Internal report" value={audit.archive} mono /> : null}
      </dl>

      <h2 className="display mt-12 border-t border-line pt-6 text-[25px] leading-tight text-ink">
        Findings and remediation history
      </h2>
      <AuditFindingsList findings={audit.findings} />

      <article className="doc-prose mt-12">
        {/* Raw HTML is explicitly discarded. react-markdown also applies a safe URL transform,
            so repository prose cannot inject script URLs or executable markup into the site. */}
        <ReactMarkdown skipHtml>{markdown}</ReactMarkdown>
      </article>

      {older ? (
        <Link
          href={`/docs/audit/${older.slug}`}
          className="mt-16 flex items-center justify-between rounded-card border border-line bg-raised/70 p-5 transition-colors hover:border-accent/50 hover:bg-raised"
        >
          <span>
            <span className="text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint">
              Earlier round
            </span>
            <span className="mt-1 block text-[15px] font-medium text-ink">
              {older.title}
            </span>
          </span>
          <span className="text-accent">→</span>
        </Link>
      ) : null}
    </div>
  );
}

function Meta({
  term,
  value,
  mono,
}: {
  term: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div>
      <dt className="text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint">
        {term}
      </dt>
      <dd
        className={
          mono
            ? "mt-1 break-all font-mono text-[12px] leading-relaxed text-ink-muted"
            : "mt-1 text-[13.5px] leading-relaxed text-ink-muted"
        }
      >
        {value}
      </dd>
    </div>
  );
}
