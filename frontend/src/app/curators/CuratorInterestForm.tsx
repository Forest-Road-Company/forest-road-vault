"use client";

import { useState } from "react";

/**
 * Registration of interest for the curator programme. It records a contact and
 * a preference; it does not take capital, quote terms or open an account. The
 * route it posts to refuses when its store is not configured, so a visitor is
 * never thanked for a registration that went nowhere.
 */

const CHAINS = [
  { value: "solana", label: "Solana" },
  { value: "ethereum", label: "Ethereum" },
  { value: "canton", label: "Canton" },
  { value: "other", label: "Other or undecided" },
] as const;

const SIZES = [
  { value: "under-250k", label: "Under $250k" },
  { value: "250k-1m", label: "$250k to $1m" },
  { value: "1m-5m", label: "$1m to $5m" },
  { value: "over-5m", label: "Over $5m" },
  { value: "undisclosed", label: "Prefer not to say" },
] as const;

const field =
  "op-field mt-2 flex w-full items-center px-4 py-3 text-[14.5px] text-ink";
const control =
  "w-full bg-transparent outline-none placeholder:text-ink-faint";
const label = "block text-[12px] font-semibold uppercase tracking-[0.12em] text-ink-muted";

export function CuratorInterestForm() {
  const [email, setEmail] = useState("");
  const [organisation, setOrganisation] = useState("");
  const [chain, setChain] = useState<(typeof CHAINS)[number]["value"]>("solana");
  const [size, setSize] = useState<(typeof SIZES)[number]["value"]>("undisclosed");
  const [wallet, setWallet] = useState("");
  const [note, setNote] = useState("");
  const [faxExtension, setFaxExtension] = useState("");
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const res = await fetch("/api/curators/interest", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({email, organisation, chain, size, wallet, note, faxExtension}),
      });
      const json = (await res.json().catch(() => ({}))) as { ok?: boolean; error?: string };
      if (res.ok && json.ok) {
        setDone(true);
      } else {
        setError(json.error ?? "That did not work. Please try again.");
      }
    } catch {
      setError("We could not reach the server. Please try again.");
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <div className="op-field px-5 py-5 text-[14.5px] leading-relaxed text-ink-muted">
        <p className="font-semibold text-ink">Registered.</p>
        <p className="mt-1">
          Forest Road will be in touch about eligibility and the agreement. Nothing
          has been committed and no account has been opened.
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={submit} noValidate className="space-y-5">
      <div aria-hidden="true" className="absolute -left-[10000px] h-px w-px overflow-hidden">
        <label htmlFor="ci-fx-9">Leave this field empty</label>
        <input
          id="ci-fx-9"
          name="fx9"
          type="text"
          tabIndex={-1}
          autoComplete="off"
          value={faxExtension}
          onChange={(e) => setFaxExtension(e.target.value)}
        />
      </div>
      <div>
        <label htmlFor="ci-email" className={label}>
          Email
        </label>
        <div className={field}>
          <input
            id="ci-email"
            type="email"
            required
            autoComplete="email"
            placeholder="you@example.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className={control}
          />
        </div>
      </div>

      <div>
        <label htmlFor="ci-org" className={label}>
          Organisation <span className="font-normal normal-case tracking-normal text-ink-faint">(optional)</span>
        </label>
        <div className={field}>
          <input
            id="ci-org"
            type="text"
            maxLength={120}
            autoComplete="organization"
            value={organisation}
            onChange={(e) => setOrganisation(e.target.value)}
            className={control}
          />
        </div>
      </div>

      <div className="grid gap-5 sm:grid-cols-2">
        <div>
          <label htmlFor="ci-chain" className={label}>
            Where your capital sits
          </label>
          <div className={field}>
            <select
              id="ci-chain"
              value={chain}
              onChange={(e) => setChain(e.target.value as typeof chain)}
              className={control}
            >
              {CHAINS.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
          </div>
        </div>
        <div>
          <label htmlFor="ci-size" className={label}>
            Indicative size
          </label>
          <div className={field}>
            <select
              id="ci-size"
              value={size}
              onChange={(e) => setSize(e.target.value as typeof size)}
              className={control}
            >
              {SIZES.map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      <div>
        <label htmlFor="ci-wallet" className={label}>
          Wallet address <span className="font-normal normal-case tracking-normal text-ink-faint">(optional; the wallet you would fund from)</span>
        </label>
        <div className={field}>
          <input
            id="ci-wallet"
            type="text"
            maxLength={64}
            spellCheck={false}
            autoComplete="off"
            value={wallet}
            onChange={(e) => setWallet(e.target.value)}
            className={`${control} font-mono text-[13.5px]`}
          />
        </div>
      </div>

      <div>
        <label htmlFor="ci-note" className={label}>
          Anything we should know <span className="font-normal normal-case tracking-normal text-ink-faint">(optional)</span>
        </label>
        <div className={field}>
          <textarea
            id="ci-note"
            rows={3}
            maxLength={1000}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            className={`${control} resize-y`}
          />
        </div>
      </div>

      {error ? (
        <p role="alert" className="text-[13.5px] text-danger">
          {error}
        </p>
      ) : null}

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <button type="submit" disabled={busy} className="op-action whitespace-nowrap px-6 py-2.5 text-[13.5px]">
          {busy ? "Sending…" : "Register interest"}
        </button>
        <p className="text-[12.5px] leading-relaxed text-ink-faint">
          Registering commits nothing. Eligibility, terms and any agreement are
          settled with Forest Road directly.
        </p>
      </div>
    </form>
  );
}
