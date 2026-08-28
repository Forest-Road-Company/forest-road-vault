import Link from "next/link";
import type { ReactNode } from "react";

/**
 * The site's compositional vocabulary, as page-level building blocks.
 *
 * Redesign notes, because each of these dropped something the old system had:
 * - No eyebrows. A label above a heading is decoration; the heading carries
 *   its own weight. Labels survive only as wayfinding or column headers.
 * - No entrance animation. The site has one authored moment, on the hero.
 *   Sections that each fade in on scroll read as an effect, not as a page.
 * - No automatic 01/02/03. Ordinals appear only where the sequence is
 *   information the reader needs, so `CardDeck` takes `ordered` explicitly.
 * - Callouts are tinted panels with a hairline, not a thick coloured edge.
 *
 * Tone drives the whole colour context, so callers pass `tone` once on the
 * Section and the blocks inside inherit the correct ink.
 */

export type Tone = "light" | "surface" | "navy" | "navy-deep";

const isDark = (t: Tone) => t === "navy" || t === "navy-deep";

/** Full-bleed band with the standard content measure inside it. */
export function Section({
  tone = "light",
  children,
  className = "",
  wide = false,
  id,
}: {
  tone?: Tone;
  children: ReactNode;
  className?: string;
  wide?: boolean;
  id?: string;
}) {
  const bg =
    tone === "navy"
      ? "navy-band"
      : tone === "navy-deep"
        ? "navy-band-deep"
        : tone === "surface"
          ? "bg-surface"
          : "bg-raised";
  return (
    <section id={id} className={`${bg} ${className}`}>
      <div
        className={`mx-auto ${wide ? "max-w-7xl" : "max-w-6xl"} px-5 py-20 md:py-28`}
      >
        {children}
      </div>
    </section>
  );
}

/**
 * Section opening: headline, then supporting copy. `note` carries a source or
 * qualifier where one is owed, this product's figures always name where they
 * came from.
 */
export function SectionHead({
  title,
  lede,
  note,
  tone = "light",
  align = "left",
}: {
  title: ReactNode;
  lede?: ReactNode;
  note?: ReactNode;
  tone?: Tone;
  align?: "left" | "center";
}) {
  const dark = isDark(tone);
  return (
    <div className={align === "center" ? "mx-auto max-w-3xl text-center" : ""}>
      <h2
        className={`display text-[31px] leading-[1.12] md:text-[46px] ${
          align === "center" ? "mx-auto max-w-2xl" : "max-w-3xl"
        }`}
      >
        {title}
      </h2>
      {lede ? (
        <p
          className={`mt-6 max-w-[62ch] text-[17px] leading-relaxed ${
            align === "center" ? "mx-auto" : ""
          } ${dark ? "text-on-navy-muted" : "text-ink-muted"}`}
        >
          {lede}
        </p>
      ) : null}
      {note ? (
        <p
          className={`mt-4 max-w-[62ch] text-[13px] leading-relaxed ${
            align === "center" ? "mx-auto" : ""
          } ${dark ? "text-on-navy-faint" : "text-ink-faint"}`}
        >
          {note}
        </p>
      ) : null}
    </div>
  );
}

/**
 * Figure band, hairline-divided cells carrying the numbers a reader should
 * leave with. Every value is a live read or a published figure; `note` is where
 * each cell says so.
 */
export function KpiBand({
  items,
  className = "",
  preserveLabelCase = false,
}: {
  items: { value: ReactNode; label: string; note?: ReactNode }[];
  className?: string;
  /** Set where a label carries a case-sensitive token (USDfr, sUSDfr, sGROVE):
   *  the uppercase label convention would otherwise rewrite the brand. */
  preserveLabelCase?: boolean;
}) {
  return (
    <div className={`kpi-band px-2 py-8 ${className}`}>
      {items.map((it) => (
        <div key={it.label} className="px-6 py-2">
          <div
            data-figure
            className="display text-[32px] leading-none text-on-navy md:text-[38px]"
          >
            {it.value}
          </div>
          <div
            className={`running-head mt-4 text-on-navy-accent ${
              preserveLabelCase ? "normal-case tracking-[0.04em]" : ""
            }`}
          >
            {it.label}
          </div>
          {it.note ? (
            <div className="mt-2.5 text-[12.5px] leading-relaxed text-on-navy-faint">
              {it.note}
            </div>
          ) : null}
        </div>
      ))}
    </div>
  );
}

/**
 * Card deck. `ordered` is opt-in: numbers appear only when the sequence itself
 * is information, a process, a priority, a cascade, never as decoration on an
 * unordered set.
 */
export function CardDeck({
  items,
  tone = "light",
  columns = 4,
  ordered = false,
}: {
  items: {
    title: string;
    body: ReactNode;
    meta?: ReactNode;
    tag?: ReactNode;
    href?: string;
  }[];
  tone?: Tone;
  columns?: 2 | 3 | 4 | 5;
  ordered?: boolean;
}) {
  const dark = isDark(tone);
  const cols: Record<number, string> = {
    2: "sm:grid-cols-2",
    3: "sm:grid-cols-2 lg:grid-cols-3",
    4: "sm:grid-cols-2 lg:grid-cols-4",
    5: "sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5",
  };

  return (
    <div className={`mt-14 grid gap-x-8 gap-y-11 ${cols[columns]}`}>
      {items.map((it, i) => {
        const inner = (
          <>
            {ordered ? (
              <div className="running-head tabular-nums text-accent">
                {String(i + 1).padStart(2, "0")}
              </div>
            ) : null}
            <h3
              className={`display ${ordered ? "mt-2.5" : ""} text-[19px] leading-snug ${
                it.href
                  ? `transition-colors ${dark ? "group-hover:text-on-navy-accent" : "group-hover:text-accent"}`
                  : ""
              }`}
            >
              {it.title}
            </h3>
            <p
              className={`mt-3.5 text-[15px] leading-relaxed ${
                dark ? "text-on-navy-muted" : "text-ink-muted"
              }`}
            >
              {it.body}
            </p>
            {it.meta ? (
              <p className="running-head mt-5 leading-relaxed">{it.meta}</p>
            ) : null}
            {it.tag ? <div className="mt-3">{it.tag}</div> : null}
          </>
        );

        return it.href ? (
          <Link key={it.title} href={it.href} className="group block h-full">
            {inner}
          </Link>
        ) : (
          <div key={it.title} className="h-full">
            {inner}
          </div>
        );
      })}
    </div>
  );
}

/**
 * Numbered rows, subhead on the left, hairline-separated rows on the right.
 * The numbers stay here: these rows are always an ordered sequence a reader
 * has to follow in order.
 */
export function NumberedRows({
  heading,
  aside,
  rows,
  tone = "light",
}: {
  heading?: ReactNode;
  /** Supporting copy under the heading. The left column is tall next to a
   *  five-row list, and empty space there reads as unfinished rather than
   *  composed: this is where the section's detail belongs. */
  aside?: ReactNode;
  rows: { label: string; body: ReactNode }[];
  tone?: Tone;
}) {
  const dark = isDark(tone);
  return (
    <div className="mt-14 flex flex-col gap-10 lg:flex-row lg:gap-16">
      {heading ? (
        <div className="lg:w-[3.2in] lg:flex-none">
          <p className="display text-[25px] leading-tight">{heading}</p>
          {aside ? (
            <div
              className={`mt-5 border-t pt-5 text-[13.5px] leading-relaxed ${
                dark
                  ? "border-on-navy-line text-on-navy-faint"
                  : "border-line text-ink-faint"
              }`}
            >
              {aside}
            </div>
          ) : null}
        </div>
      ) : null}
      <div className="flex-1">
        {rows.map((r, i) => (
          <div
            key={r.label}
            className={`flex flex-col gap-2 py-6 sm:flex-row sm:gap-6 ${
              i === 0
                ? ""
                : dark
                  ? "border-t border-on-navy-line"
                  : "border-t border-row"
            }`}
          >
            <span className="w-6 flex-none pt-0.5 text-[11px] font-semibold tabular-nums text-accent">
              {String(i + 1).padStart(2, "0")}
            </span>
            <span className="display flex-none text-[15.5px] leading-snug sm:w-[2.5in]">
              {r.label}
            </span>
            <span
              className={`flex-1 text-[15px] leading-relaxed ${
                dark ? "text-on-navy-muted" : "text-ink-muted"
              }`}
            >
              {r.body}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Callout, a tinted panel with a hairline, on either field. */
export function HighlightBox({
  title,
  children,
  tone = "light",
  className = "",
}: {
  title?: string;
  children: ReactNode;
  tone?: Tone;
  className?: string;
}) {
  const dark = isDark(tone);
  return (
    <div
      className={`rounded-card px-7 py-6 ${
        dark
          ? "border border-on-navy-line bg-white/[0.06]"
          : "highlight-box"
      } ${className}`}
    >
      {title ? (
        <p className={`display text-[16px] ${dark ? "text-on-navy" : ""}`}>
          {title}
        </p>
      ) : null}
      <div
        className={`${title ? "mt-3" : ""} text-[15px] leading-relaxed ${
          dark ? "text-on-navy-muted" : "text-ink-muted"
        }`}
      >
        {children}
      </div>
    </div>
  );
}

/** Data table with a tinted header row. */
export function FramTable({
  caption,
  rows,
}: {
  caption: string;
  rows: { label: string; value: ReactNode }[];
}) {
  return (
    <div className="fram-table mt-12">
      <div className="fram-table-head px-5 py-3 text-center text-[13px]">
        {caption}
      </div>
      <div>
        {rows.map((r, i) => (
          <div
            key={r.label}
            className={`flex flex-col gap-1 px-5 py-3.5 sm:flex-row sm:gap-4 ${
              i === 0 ? "" : "border-t border-row"
            }`}
          >
            <span className="display flex-none text-[15px] sm:w-[30%]">
              {r.label}
            </span>
            <span className="flex-1 text-[15px] leading-relaxed text-ink-value">
              {r.value}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
