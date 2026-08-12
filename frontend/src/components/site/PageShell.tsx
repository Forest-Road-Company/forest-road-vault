import Link from "next/link";
import type { ReactNode } from "react";
import { NETWORK_NAME } from "@/config/contracts";

/**
 * The content-page opening: a real breadcrumb on a hairline rule, then the
 * title and lede.
 *
 * The previous version set an accent label directly above the h1 — a kicker,
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
}: {
  /** Where this page sits. Rendered as the current leaf of the trail. */
  section: string;
  title: string;
  lede?: string;
  children?: ReactNode;
  /** Let children run full-bleed so they can alternate tonal bands. Pages
   *  that keep a single-column measure leave this off. */
  bleed?: boolean;
}) {
  return (
    <>
      <div className="bg-bg">
        <div className="mx-auto max-w-6xl px-5 pb-14 pt-10">
          <nav aria-label="Breadcrumb">
            <ol className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <li>
                {/* inline-flex rather than padding so the 24px target does not
                    push the crumb off the row's baseline. */}
                <Link
                  href="/"
                  className="running-head inline-flex min-h-[24px] items-center transition-colors hover:text-ink"
                >
                  Forest Road Vault
                </Link>
              </li>
              <li aria-hidden className="running-head">
                /
              </li>
              <li>
                <span aria-current="page" className="running-head text-accent">
                  {section}
                </span>
              </li>
            </ol>
          </nav>
          <div className="rule-head mt-3" />

          {/* Title and lede sit side by side rather than stacked in the left
              column: stacked, they left the right third of the measure empty on
              every interior page, and the larger display size made that more
              conspicuous, not less. */}
          <div className="mt-10 grid gap-x-16 gap-y-6 lg:grid-cols-12">
            <h1 className="display text-[31px] leading-[1.1] md:text-[46px] lg:col-span-7">
              {title}
            </h1>
            {lede ? (
              <p className="max-w-[54ch] text-[17px] leading-relaxed text-ink-muted lg:col-span-5 lg:pt-2">
                {lede}
              </p>
            ) : null}
          </div>
        </div>
      </div>
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
    <div className={tone === "light" ? "bg-raised" : "bg-surface"}>
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
        The {surface} reads live on-chain state — and only live on-chain state.
        The protocol contracts will appear here once the configured deployment
        is present and verified on {NETWORK_NAME}. Nothing on this site is
        simulated.
      </p>
    </div>
  );
}
