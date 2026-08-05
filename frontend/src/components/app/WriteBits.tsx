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
  onMax,
}: {
  value: string;
  onChange: (v: string) => void;
  symbol: string;
  /** Token precision cap. viem's parseUnits ROUNDS UP fractions beyond the
   *  token's decimals — capping input here prevents that entirely. */
  maxDecimals: number;
  disabled?: boolean;
  onMax?: () => void;
}) {
  return (
    <div className="mt-4 flex items-center gap-2 rounded-card border border-line bg-surface px-4 py-3 focus-within:border-moss/50">
      <input
        type="text"
        inputMode="decimal"
        placeholder="0.00"
        value={value}
        disabled={disabled}
        onChange={(e) => {
          const v = e.target.value;
          // digits + one dot, fraction capped at token precision — reject pasted
          // garbage and over-precision early, not at simulate time
          if (new RegExp(`^\\d*\\.?\\d{0,${maxDecimals}}$`).test(v)) onChange(v);
        }}
        className="w-full bg-transparent font-mono text-[15px] text-ink outline-none placeholder:text-ink-faint disabled:opacity-50"
      />
      {onMax ? (
        <button
          onClick={onMax}
          disabled={disabled}
          className="rounded-pill border border-line-strong px-2.5 py-0.5 font-mono text-[10px] uppercase tracking-[0.12em] text-ink-muted transition-colors hover:border-moss/60 hover:text-moss disabled:opacity-50"
        >
          max
        </button>
      ) : null}
      <span className="font-mono text-[12px] uppercase tracking-[0.1em] text-ink-faint">
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
    <button
      onClick={onClick}
      disabled={disabled || busy}
      className="mt-4 w-full rounded-pill bg-moss px-5 py-2.5 text-[13.5px] font-medium text-raised transition-transform hover:scale-[1.01] hover:bg-moss-bright disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:scale-100 disabled:hover:bg-moss"
    >
      {busy ? (busyLabel ?? "Working…") : label}
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
            <a className="u-link text-moss" href={`${EXPLORER_TX}${status.hash}`} target="_blank" rel="noreferrer">
              view on Etherscan
            </a>
          </>
        ) : null}
      </Line>
    );
  if (status.phase === "success")
    return (
      <Line tone="ok">
        Confirmed.
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

function Line({tone, children}: {tone: "muted" | "ok" | "err"; children: React.ReactNode}) {
  const color =
    tone === "ok" ? "text-moss" : tone === "err" ? "text-danger" : "text-ink-muted";
  return <p className={`mt-3 text-[12.5px] leading-relaxed ${color}`}>{children}</p>;
}
