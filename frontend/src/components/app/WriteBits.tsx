"use client";

/** Shared presentational bits for the write cards: amount input, action button,
 *  and the pending/success/error status line with an explorer link. */

import type {WriteStatus} from "@/components/app/useWriteFlow";
import {EXPLORER_BASE_URL} from "@/config/contracts";

export const EXPLORER_TX = EXPLORER_BASE_URL
  ? `${EXPLORER_BASE_URL}/tx/`
  : null;

/** Phase-accurate busy label — the button must never say "Confirm in wallet…"
 *  while the status line says the tx is already pending. */
export function busyLabelFor(status: WriteStatus): string {
  if (status.phase === "simulating") return "Simulating…";
  if (status.phase === "signing") return "Confirm in wallet…";
  if (status.phase === "pending") return "Pending…";
  return "Working…";
}

export function AmountInput({
  value,
  onChange,
  symbol,
  maxDecimals,
  disabled,
  invalid,
  onMax,
}: {
  value: string;
  onChange: (v: string) => void;
  symbol: string;
  /** Token precision cap. viem's parseUnits ROUNDS UP fractions beyond the
   *  token's decimals — capping input here prevents that entirely. */
  maxDecimals: number;
  disabled?: boolean;
  /** Draws the field's error state. The message itself belongs to the caller,
   *  next to the field, so the reason is never left implicit in a red border. */
  invalid?: boolean;
  onMax?: () => void;
}) {
  return (
    <div
      className="op-field mt-4 flex items-center gap-2 px-4 py-3"
      data-invalid={invalid ? "true" : undefined}
      data-disabled={disabled ? "true" : undefined}
    >
      <input
        type="text"
        inputMode="decimal"
        placeholder="0.00"
        value={value}
        disabled={disabled}
        aria-invalid={invalid || undefined}
        onChange={(e) => {
          const v = e.target.value;
          // digits + one dot, fraction capped at token precision — reject pasted
          // garbage and over-precision early, not at simulate time
          if (new RegExp(`^\\d*\\.?\\d{0,${maxDecimals}}$`).test(v)) onChange(v);
        }}
        className="w-full bg-transparent font-mono text-[15px] text-ink outline-none placeholder:text-ink-faint disabled:cursor-not-allowed disabled:text-ink-faint"
      />
      {onMax ? (
        <button
          type="button"
          onClick={onMax}
          disabled={disabled}
          className="rounded-pill border border-line-strong px-2.5 py-0.5 text-[10px] font-semibold uppercase tracking-[0.12em] text-ink-muted transition-colors hover:border-accent hover:text-accent active:bg-accent-faint disabled:cursor-not-allowed disabled:border-line disabled:text-ink-faint"
        >
          max
        </button>
      ) : null}
      <span className="text-[12.5px] font-semibold text-ink-faint">
        {symbol}
      </span>
    </div>
  );
}

export function ActionButton({
  label,
  busyLabel,
  busy,
  disabled,
  onClick,
}: {
  label: string;
  busyLabel?: string;
  busy: boolean;
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    /* One action shape for the whole surface, with hover/active/disabled
       carried by `.op-action`. The previous version scaled on hover: a
       transform is decoration on a control whose only job is to report whether
       it can be pressed and whether it is working. */
    <button
      type="button"
      onClick={onClick}
      disabled={disabled || busy}
      aria-busy={busy || undefined}
      className="op-action mt-4 w-full px-5 py-2.5 text-[13.5px]"
    >
      {busy ? (
        <span className="inline-flex items-center gap-2">
          <span
            className="h-1.5 w-1.5 animate-pulse rounded-full bg-white/80"
            aria-hidden
          />
          {busyLabel ?? "Working…"}
        </span>
      ) : (
        label
      )}
    </button>
  );
}

export function StatusLine({status}: {status: WriteStatus}) {
  if (status.phase === "idle") return null;
  if (status.phase === "simulating")
    return <Line tone="muted">Simulating against live chain state…</Line>;
  if (status.phase === "signing") return <Line tone="muted">Confirm in your wallet…</Line>;
  if (status.phase === "pending")
    return (
      <Line tone="muted">
        Transaction pending…
        {EXPLORER_TX ? (
          <>
            {" "}
            <a className="u-link text-accent" href={`${EXPLORER_TX}${status.hash}`} target="_blank" rel="noreferrer">
              view on Etherscan
            </a>
          </>
        ) : null}
      </Line>
    );
  if (status.phase === "success")
    return (
      <Line tone="ok">
        <span className="font-medium">Confirmed.</span>
        {EXPLORER_TX ? (
          <>
            {" "}
            <a className="u-link" href={`${EXPLORER_TX}${status.hash}`} target="_blank" rel="noreferrer">
              view on Etherscan
            </a>
          </>
        ) : null}
      </Line>
    );
  return (
    <Line tone="err">
      {status.message}
      {status.errorName ? (
        <span className="ml-1.5 font-mono text-[10.5px] text-ink-faint">({status.errorName})</span>
      ) : null}
    </Line>
  );
}

/**
 * Status is announced, not just coloured: the write phases change asynchronously
 * after a click, so a screen reader has to hear the outcome. Confirmed uses the
 * Operate surface's success value — navy cannot distinguish "pending" from
 * "confirmed", and on a transaction surface that distinction is the whole point.
 */
function Line({tone, children}: {tone: "muted" | "ok" | "err"; children: React.ReactNode}) {
  const color =
    tone === "ok" ? "text-ok" : tone === "err" ? "text-danger" : "text-ink-muted";
  return (
    <p
      role="status"
      aria-live="polite"
      className={`mt-3 text-[12.5px] leading-relaxed ${color}`}
    >
      {children}
    </p>
  );
}
