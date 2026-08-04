import type { ReactNode } from "react";
import { NETWORK_NAME } from "@/config/contracts";

export function PageShell({
  eyebrow,
  title,
  lede,
  children,
}: {
  eyebrow: string;
  title: string;
  lede?: string;
  children?: ReactNode;
}) {
  return (
    <div className="mx-auto max-w-6xl px-5 py-20">
      <p className="font-mono text-[11px] uppercase tracking-[0.22em] text-moss">
        {eyebrow}
      </p>
      <div className="keyline mt-2 w-14" />
      <h1 className="serif-display mt-5 max-w-2xl text-[40px] leading-[1.08] text-ink md:text-[54px]">
        {title}
      </h1>
      {lede ? (
        <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-ink-muted">
          {lede}
        </p>
      ) : null}
      {children}
    </div>
  );
}

/** Designed empty state for surfaces that need live contracts to be honest. */
export function AwaitingContracts({ surface }: { surface: string }) {
  return (
    <div className="mt-12 rounded-card border border-dashed border-line-strong bg-raised/60 p-10 text-center">
      <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
        Awaiting {NETWORK_NAME} deployment
      </p>
      <p className="mx-auto mt-3 max-w-md text-[14px] leading-relaxed text-ink-muted">
        The {surface} reads live on-chain state — and only live on-chain state.
        The protocol contracts will appear here once the configured deployment
        is present and verified on {NETWORK_NAME}. Nothing on this site is
        simulated.
      </p>
    </div>
  );
}
