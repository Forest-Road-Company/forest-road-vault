/**
 * The three-layer loss cascade, drawn as a fine-line diagram: a loss line
 * flows downward and is absorbed layer by layer. Pure SVG + CSS animation
 * (reduced-motion safe via globals.css).
 *
 * This is a figure, so it is marked up as one: the label is its legend, not a
 * kicker. The 1/2/3 ordinals stay because the ordering IS the information: the
 * whole point of the diagram is which capital absorbs a loss first.
 */
const layers = [
  {
    label: "1 · First-loss capital",
    sub: "posted by Forest Road and partners",
    note: "absorbs first",
  },
  {
    label: "2 · Backstop reserve",
    sub: "a separately funded reserve that absorbs ahead of depositors",
    note: "absorbs second",
  },
  {
    label: "3 · sUSDfr principal",
    sub: "depositors, touched only beyond both layers",
    note: "last",
  },
] as const;

export function CascadeDiagram({ tone = "light" }: { tone?: "light" | "navy" }) {
  const dark = tone === "navy";
  return (
    <figure
      className={`relative overflow-hidden rounded-card p-8 md:p-10 ${
        dark ? "border border-navy-border bg-navy-deep" : "panel"
      }`}
    >
      <div className="pointer-events-none absolute left-1/2 top-0 hidden h-full -translate-x-1/2 md:block">
        <svg
          width="2"
          height="100%"
          viewBox="0 0 2 240"
          preserveAspectRatio="none"
          aria-hidden
        >
          <line
            x1="1"
            y1="0"
            x2="1"
            y2="240"
            stroke={
              dark ? "var(--color-on-navy-accent)" : "var(--color-accent)"
            }
            strokeWidth="1.5"
            className="cascade-line"
          />
        </svg>
      </div>

      <figcaption
        className={`running-head ${dark ? "text-on-navy-accent" : "text-accent"}`}
      >
        Loss cascade: enforced ordering
      </figcaption>

      <div className="mt-8 space-y-4">
        {layers.map((l, i) => (
          <div
            key={l.label}
            className={`relative rounded-card px-6 py-5 transition-colors ${
              dark
                ? "border border-navy-border bg-navy hover:border-on-navy-accent/50"
                : "border border-line bg-surface hover:border-accent/45"
            }`}
            style={{ marginLeft: `${i * 6}%`, marginRight: `${(2 - i) * 3}%` }}
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <p
                className={`display text-[15.5px] ${dark ? "text-on-navy" : "text-ink"}`}
              >
                {l.label}
              </p>
              <p
                className={`running-head ${dark ? "text-on-navy-faint" : "text-ink-faint"}`}
              >
                {l.note}
              </p>
            </div>
            <p
              className={`mt-1.5 text-[13.5px] leading-relaxed ${
                dark ? "text-on-navy-muted" : "text-ink-muted"
              }`}
            >
              {l.sub}
            </p>
          </div>
        ))}
      </div>

      <p
        className={`mt-8 max-w-[62ch] text-[13.5px] leading-relaxed ${
          dark ? "text-on-navy-faint" : "text-ink-faint"
        }`}
      >
        The order is written into the contract and tested: a loss cannot skip
        a layer. This is an ordering of losses, not a guarantee against them.
      </p>
    </figure>
  );
}
