/**
 * The three-layer loss cascade, drawn as a fine-line diagram: a loss line
 * flows downward and is absorbed layer by layer. Pure SVG + CSS animation
 * (reduced-motion safe via globals.css).
 */
const layers = [
  {
    label: "1 · Curator first-loss",
    sub: "$10M per class, posted by Forest Road",
    note: "absorbs first",
  },
  {
    label: "2 · sGROVE backstop",
    sub: "staked backstop capital, 21-day unbond",
    note: "absorbs second",
  },
  {
    label: "3 · sUSDfr principal",
    sub: "depositors — touched only beyond both layers",
    note: "last, by construction",
  },
] as const;

export function CascadeDiagram() {
  return (
    <div className="panel relative overflow-hidden p-8 md:p-10">
      <div className="pointer-events-none absolute left-1/2 top-0 hidden h-full -translate-x-1/2 md:block">
        <svg width="2" height="100%" viewBox="0 0 2 240" preserveAspectRatio="none" aria-hidden>
          <line
            x1="1"
            y1="0"
            x2="1"
            y2="240"
            stroke="var(--color-danger)"
            strokeWidth="1.5"
            className="cascade-line"
          />
        </svg>
      </div>
      <p className="eyebrow">Loss cascade — enforced ordering</p>
      <div className="mt-8 space-y-4">
        {layers.map((l, i) => (
          <div
            key={l.label}
            className="relative rounded-[12px] border border-line bg-raised/70 px-6 py-5 backdrop-blur-sm transition-colors hover:border-moss/35"
            style={{ marginLeft: `${i * 6}%`, marginRight: `${(2 - i) * 3}%` }}
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <p className="font-grotesk text-[15px] font-semibold tracking-tight text-ink">
                {l.label}
              </p>
              <p className="font-mono text-[10.5px] uppercase tracking-[0.18em] text-ink-faint">
                {l.note}
              </p>
            </div>
            <p className="mt-1 text-[13px] text-ink-muted">{l.sub}</p>
          </div>
        ))}
      </div>
      <p className="mt-7 max-w-2xl text-[13px] leading-relaxed text-ink-faint">
        The ordering is a contract invariant, fuzz-tested across states: losses
        can never skip or invert a layer, and the exchange rate can never fall
        silently. Structural ordering of losses — not a guarantee against them.
      </p>
    </div>
  );
}
