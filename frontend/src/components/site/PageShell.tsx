import Image from "next/image";
import Link from "next/link";
import type { ReactNode } from "react";
import { NETWORK_NAME } from "@/config/contracts";

/**
 * The content-page opening: a real breadcrumb on a hairline rule, then the
 * title and lede.
 *
 * The previous version set an accent label directly above the h1, a kicker,
 * which this design system does not use. The label survives only where it does
 * work the heading cannot: telling the reader where in the site they are, as a
 * navigable trail.
 */
export function PageShell({
  section,
  title,
  lede,
  children,
  bleed = false,
  visual,
  heroTone = "technical",
}: {
  /** Where this page sits. Rendered as the current leaf of the trail. */
  section: string;
  title: ReactNode;
  lede?: string;
  children?: ReactNode;
  /** Let children run full-bleed so they can alternate tonal bands. Pages
   *  that keep a single-column measure leave this off. */
  bleed?: boolean;
  /** Shoji's liquid-glass ledger for the routes whose share concepts define one. */
  visual?: ReactNode;
  /** Risk is the deliberate photographic exception to the technical field. */
  heroTone?: "technical" | "forest";
}) {
  const breadcrumb = (dark = false) => (
    <nav aria-label="Breadcrumb">
      <ol className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <li>
          <Link
            href="/"
            className={`running-head inline-flex min-h-[24px] items-center transition-colors ${
              dark ? "text-on-navy-faint hover:text-white" : "hover:text-ink"
            }`}
          >
            Forest Road Vault
          </Link>
        </li>
        <li aria-hidden className={`running-head ${dark ? "text-on-navy-faint" : ""}`}>
          /
        </li>
        <li>
          <span
            aria-current="page"
            className={`running-head ${dark ? "text-on-navy-accent" : "text-accent"}`}
          >
            {section}
          </span>
        </li>
      </ol>
    </nav>
  );

  if (heroTone === "forest") {
    return (
      <>
        <section className="page-hero page-hero--forest grain">
          <Image
            src="/brand/hero-cover.jpg"
            alt=""
            fill
            priority
            sizes="100vw"
            className="page-hero__forest-image"
            aria-hidden
          />
          <div className="page-hero__forest-grade" aria-hidden />
          <div className="relative z-10 mx-auto flex min-h-[min(72svh,780px)] max-w-6xl flex-col px-5 pb-16 pt-10 md:pb-20">
            {breadcrumb(true)}
            <div className={`mt-auto grid items-end gap-6 ${visual ? "lg:grid-cols-[.78fr_1.22fr]" : ""}`}>
              <div className="page-hero__glass max-w-3xl p-7 sm:p-10">
                <h1 className="display text-[clamp(2.7rem,7vw,5.4rem)] leading-[1.02] text-white">
                  {title}
                </h1>
                {lede ? (
                  <p className="mt-6 max-w-[58ch] text-[17px] leading-relaxed text-on-navy-muted">
                    {lede}
                  </p>
                ) : null}
              </div>
              {visual ? <div className="page-hero__forest-visual">{visual}</div> : null}
            </div>
          </div>
        </section>
        {bleed ? children : <PageBody>{children}</PageBody>}
      </>
    );
  }

  return (
    <>
      <section className={`page-hero page-hero--technical ${visual ? "page-hero--visual" : ""}`}>
        <div className="mx-auto max-w-6xl px-5 pb-14 pt-10 md:pb-20">
          {breadcrumb()}
          <div className="rule-head mt-3" />

          <div className={`mt-10 grid gap-x-14 gap-y-10 ${visual ? "items-center lg:grid-cols-[.88fr_1.12fr]" : "lg:grid-cols-12"}`}>
            <div className={visual ? "max-w-2xl" : "lg:col-span-7"}>
              <h1 className="display text-[clamp(2.35rem,5.4vw,4.9rem)] leading-[1.04]">
                {title}
              </h1>
              {lede ? (
                <p className={`max-w-[58ch] text-[17px] leading-relaxed text-ink-muted ${visual ? "mt-6" : "mt-6 lg:hidden"}`}>
                  {lede}
                </p>
              ) : null}
            </div>
            {visual ? (
              <div className="page-hero__visual">{visual}</div>
            ) : lede ? (
              <p className="hidden max-w-[54ch] text-[17px] leading-relaxed text-ink-muted lg:col-span-5 lg:block lg:pt-2">
                {lede}
              </p>
            ) : null}
          </div>
        </div>
      </section>
      {bleed ? children : <PageBody>{children}</PageBody>}
    </>
  );
}

/** Constrained wrapper for pages that keep a single-column measure. */
export function PageBody({
  children,
  tone = "surface",
}: {
  children: ReactNode;
  tone?: "light" | "surface";
}) {
  return (
    <div className={`section-motion ${tone === "light" ? "section-light" : "section-surface"}`}>
      <div className="mx-auto max-w-6xl px-5 pb-20 pt-14">{children}</div>
    </div>
  );
}

/** Designed empty state for surfaces that need live contracts to be honest. */
export function AwaitingContracts({ surface }: { surface: string }) {
  return (
    <div className="mt-12 rounded-card border border-dashed border-line-strong bg-raised/60 p-10 text-center">
      <p className="running-head text-accent">
        Awaiting {NETWORK_NAME} deployment
      </p>
      <p className="mx-auto mt-4 max-w-[52ch] text-[14.5px] leading-relaxed text-ink-muted">
        The {surface} reads live on-chain state, and only live on-chain state.
        The protocol contracts will appear here once the configured deployment
        is present and verified on {NETWORK_NAME}. Nothing on this site is
        simulated.
      </p>
    </div>
  );
}
