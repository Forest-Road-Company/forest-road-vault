import type { AuditFinding, Disposition, Severity } from "@/content/audits";

/**
 * Findings are rendered as structured cards rather than a markdown table.
 *
 * The docs pipeline runs `react-markdown` without `remark-gfm`, so pipe tables in
 * markdown are emitted as literal text, the `.doc-prose table` rules in globals.css
 * never match anything. Registers therefore live in typed data (`content/audits.ts`)
 * and render through this component, which also keeps severity and disposition
 * vocabulary consistent across every round.
 */

/**
 * Severity and disposition are encoded in the navy tint ladder, not in hue.
 * The house style is monochrome navy on client-facing surfaces, so weight
 * carries the ranking: solid navy demands attention, tints recede. The label
 * itself is always present, so the tint is reinforcement and never the only
 * signal.
 */
const SEVERITY_STYLE: Record<Severity, string> = {
  High: "border-navy bg-navy text-on-navy",
  Medium: "border-accent-strong bg-accent-strong/12 text-accent-strong",
  Low: "border-line-strong bg-surface text-ink-value",
  Informational: "border-line bg-surface text-ink-faint",
};

const DISPOSITION_STYLE: Record<Disposition, string> = {
  Remediated: "border-line-strong bg-surface text-ink-faint",
  Accepted: "border-accent-strong bg-accent-strong/12 text-accent-strong",
  Deferred: "border-accent-strong bg-accent-strong/12 text-accent-strong",
  "By design": "border-line-strong bg-surface text-ink-value",
  Open: "border-navy bg-navy text-on-navy",
  Superseded: "border-line bg-surface text-ink-faint",
};

const PILL =
  "inline-block rounded-pill border px-2 py-[3px] text-[11px] font-semibold uppercase tracking-[0.12em] whitespace-nowrap";

export function SeverityPill({ severity }: { severity: Severity }) {
  return <span className={`${PILL} ${SEVERITY_STYLE[severity]}`}>{severity}</span>;
}

/**
 * Forest Road's own rating, shown NEXT TO the auditor's rather than replacing it.
 * The prefix is not decoration: a reader who opens the published report must be able to
 * see instantly which number came from the auditor and which from us.
 */
function AssessedPill({ severity }: { severity: Severity }) {
  return (
    <span className={`${PILL} ${SEVERITY_STYLE[severity]}`}>
      Forest Road: {severity}
    </span>
  );
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
          <span className="tnum text-[12px] font-semibold text-ink">{n}</span>
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
            <span className="running-head">{f.id}</span>
            <SeverityPill severity={f.severity} />
            {f.assessed ? <AssessedPill severity={f.assessed.severity} /> : null}
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
          {f.assessed ? (
            <div className="mt-3 rounded-card border border-line bg-surface/60 p-3.5">
              <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-ink-faint">
                Forest Road assessment: {f.assessed.severity}
              </p>
              <p className="mt-1.5 text-[13px] leading-relaxed text-ink-muted">
                {f.assessed.why}
              </p>
              <p className="mt-1.5 text-[13px] leading-relaxed text-ink-muted">
                <span className="text-ink">Restores to {f.severity} when: </span>
                {f.assessed.until}
              </p>
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}
