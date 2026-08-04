import type { AuditFinding, Disposition, Severity } from "@/content/audits";

/**
 * Findings are rendered as structured cards rather than a markdown table.
 *
 * The docs pipeline runs `react-markdown` without `remark-gfm`, so pipe tables in
 * markdown are emitted as literal text — the `.doc-prose table` rules in globals.css
 * never match anything. Registers therefore live in typed data (`content/audits.ts`)
 * and render through this component, which also keeps severity and disposition
 * vocabulary consistent across every round.
 */

const SEVERITY_STYLE: Record<Severity, string> = {
  High: "border-danger/30 bg-danger/10 text-danger",
  Medium: "border-warn/30 bg-warn/10 text-warn",
  Low: "border-line-strong bg-surface text-ink-muted",
  Informational: "border-line-strong bg-surface text-ink-faint",
};

const DISPOSITION_STYLE: Record<Disposition, string> = {
  Remediated: "border-moss/30 bg-moss-faint text-moss",
  Accepted: "border-gold/30 bg-gold-faint text-gold",
  Deferred: "border-gold/30 bg-gold-faint text-gold",
  "By design": "border-line-strong bg-surface text-ink-muted",
  Open: "border-warn/30 bg-warn/10 text-warn",
  Superseded: "border-line-strong bg-surface text-ink-faint",
};

const PILL =
  "inline-block rounded-pill border px-2 py-[3px] font-mono text-[10px] uppercase tracking-[0.12em] whitespace-nowrap";

export function SeverityPill({ severity }: { severity: Severity }) {
  return <span className={`${PILL} ${SEVERITY_STYLE[severity]}`}>{severity}</span>;
}

export function DispositionPill({ disposition }: { disposition: Disposition }) {
  return (
    <span className={`${PILL} ${DISPOSITION_STYLE[disposition]}`}>{disposition}</span>
  );
}

/** Compact severity counts, e.g. "2 High · 4 Medium · 3 Low". */
export function SeverityMix({ findings }: { findings: AuditFinding[] }) {
  const order: Severity[] = ["High", "Medium", "Low", "Informational"];
  const parts = order
    .map((s) => ({ s, n: findings.filter((f) => f.severity === s).length }))
    .filter((p) => p.n > 0);

  if (parts.length === 0) {
    return <span className="text-ink-faint">No findings</span>;
  }

  return (
    <span className="inline-flex flex-wrap items-center gap-1.5">
      {parts.map(({ s, n }) => (
        <span key={s} className="inline-flex items-center gap-1">
          <span className="font-mono text-[12px] text-ink">{n}</span>
          <SeverityPill severity={s} />
        </span>
      ))}
    </span>
  );
}

export function AuditFindingsList({ findings }: { findings: AuditFinding[] }) {
  return (
    <ul className="mt-6 space-y-3">
      {findings.map((f) => (
        <li
          key={f.id}
          className="rounded-card border border-line bg-raised/70 p-5"
        >
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-ink-faint">
              {f.id}
            </span>
            <SeverityPill severity={f.severity} />
            <span className="ml-auto">
              <DispositionPill disposition={f.disposition} />
            </span>
          </div>
          <p className="mt-2.5 text-[15px] font-medium leading-snug text-ink">
            {f.title}
          </p>
          <p className="mt-1.5 text-[13.5px] leading-relaxed text-ink-muted">
            {f.note}
          </p>
        </li>
      ))}
    </ul>
  );
}
