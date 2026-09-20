"use client";

import { AnchorProvider, BN, EventParser, Program, type Idl } from "@anchor-lang/core";
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { type Connection, PublicKey, Transaction } from "@solana/web3.js";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import idlJson from "@/config/curator-vault.idl.json";
import type { ForestroadCuratorVault } from "@/config/curator-vault.types";
import { CURATOR_VAULT } from "@/config/curatorVault";
import { accrue, couponView, currentRateBps, formatUnits, type RateEpoch } from "@/lib/curatorVaultMath";
import { createAssociatedTokenAccountIdempotentInstruction, getAssociatedTokenAddressSync } from "@/lib/solanaToken";

/**
 * The curator's own surface on /curators (spec section 10, revised 18 September 2026).
 *
 * WHO SEES WHAT. A visitor who has not connected a wallet sees only a connect control. A connected
 * wallet with no allowlisted position sees a plain statement that it is not yet approved and is
 * pointed at the register-interest form; no deposit control exists for it, rather than a disabled
 * one. An allowlisted wallet sees its position, the rate that applies to it, its coupon history,
 * what is claimable now, and the five writes: deposit, request or cancel withdrawal, withdraw,
 * claim (the permissionless coupon crank for itself).
 *
 * EVERY WRITE IS SIMULATED FIRST and a program refusal is shown in the program's own words. Nothing
 * here promises a rate to anyone who has not signed: the rate shown is the epoch recorded on chain
 * for the agreement this wallet has already executed (Forest Road decision 3, 18 September).
 */

const idl = idlJson as ForestroadCuratorVault;
const DECIMALS = CURATOR_VAULT.decimals;
const HISTORY_LIMIT = 40;
/** Genesis hashes pin the cluster independently of what the RPC URL looks like. */
const EXPECTED_GENESIS: Record<string, string> = {
  devnet: "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG",
  "mainnet-beta": "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d",
};

type ConfigAccount = Awaited<ReturnType<Program<ForestroadCuratorVault>["account"]["config"]["fetch"]>>;
type PositionAccount = Awaited<ReturnType<Program<ForestroadCuratorVault>["account"]["position"]["fetch"]>>;
type CouponRow = { signature: string; periodEnd: number; amount: bigint; when: number | null };

function bi(v: BN | number | bigint): bigint {
  return typeof v === "bigint" ? v : BigInt(v.toString());
}
function epochsOf(c: ConfigAccount): RateEpoch[] {
  return c.rateEpochs.slice(0, c.rateEpochCount).map((e) => ({ startTs: bi(e.startTs), bps: e.bps }));
}
function utc(ts: bigint | number): string {
  const n = Number(ts);
  if (!n) return "never";
  return new Date(n * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
}
function short(k: string) {
  return `${k.slice(0, 4)}…${k.slice(-4)}`;
}
function duration(seconds: bigint): string {
  const days = seconds / 86_400n;
  return `${days.toLocaleString("en-US")} day${days === 1n ? "" : "s"}`;
}
function bytes32(value: readonly number[] | Uint8Array): string {
  return `0x${Array.from(value, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/** Turns a simulation or send failure into the program's own message, or a plain sentence. */
function describeFailure(e: unknown, logs?: string[] | null): string {
  const text = [String((e as Error)?.message ?? e), ...(logs ?? [])].join("\n");
  const m = text.match(/Error Code: (\w+)\. Error Number: \d+\. Error Message: ([^.]+)\./);
  if (m) return `${m[2]}.`;
  if (/insufficient funds/i.test(text)) return "The wallet does not hold enough for this transaction (tokens, or SOL for fees and account rent).";
  if (/User rejected|rejected the request/i.test(text)) return "You declined the wallet prompt.";
  if (/blockhash/i.test(text)) return "The network moved on before the transaction landed. Try again.";
  return "The transaction could not be completed. Nothing was changed.";
}

function isRateLimited(e: unknown): boolean {
  return /429|Too many requests|rate limit/i.test(String((e as Error)?.message ?? e));
}

/**
 * Public RPC endpoints cap getTransaction per second, and one refused call inside a batch fails
 * the whole batch. Fetch a few at a time and back off on a refusal; a permanent refusal is
 * reported to the caller rather than swallowed.
 */
async function fetchTransactionsGently(connection: Connection, signatures: string[]) {
  const CHUNK = 4;
  const out: Awaited<ReturnType<Connection["getTransactions"]>> = [];
  for (let i = 0; i < signatures.length; i += CHUNK) {
    const chunk = signatures.slice(i, i + CHUNK);
    if (i > 0) await new Promise((r) => setTimeout(r, 400));
    for (let attempt = 0; ; attempt++) {
      try {
        out.push(...(await connection.getTransactions(chunk, { maxSupportedTransactionVersion: 0 })));
        break;
      } catch (e) {
        if (!isRateLimited(e) || attempt >= 3) throw e;
        await new Promise((r) => setTimeout(r, 1500 * 2 ** attempt));
      }
    }
  }
  return out;
}

/** Polls until the signature is confirmed, fails, or its blockhash can no longer be included. */
async function awaitSignature(
  connection: Connection,
  signature: string,
  lastValidBlockHeight: number,
): Promise<"confirmed" | "failed" | "expired"> {
  // A throttled status poll is not an unknown outcome: keep polling through it. Only a
  // sustained refusal (nothing readable for two minutes) gives up, and the caller then says
  // the status could not be read and re-reads the position from chain.
  let lastReadable = Date.now();
  for (;;) {
    try {
      const { value } = await connection.getSignatureStatuses([signature]);
      const status = value[0];
      if (status?.err) return "failed";
      if (status && (status.confirmationStatus === "confirmed" || status.confirmationStatus === "finalized")) return "confirmed";
      if ((await connection.getBlockHeight()) > lastValidBlockHeight) return "expired";
      lastReadable = Date.now();
    } catch (e) {
      if (!isRateLimited(e) || Date.now() - lastReadable > 120_000) throw e;
    }
    await new Promise((r) => setTimeout(r, 2_000));
  }
}

export function CuratorVaultPanel() {
  const { connection } = useConnection();
  const { publicKey, wallet, wallets, select, connect, connected, connecting, disconnect, sendTransaction } = useWallet();
  const walletAddress = publicKey?.toBase58() ?? null;
  const walletAddressRef = useRef(walletAddress);
  // Wallets register through the Wallet Standard on the client only, so the server renders no
  // wallet list; the list appears after mount to keep hydration exact.
  const [mounted, setMounted] = useState(false);
  // `select` takes effect on the next render; connecting in the same handler would race it.
  const [pendingConnect, setPendingConnect] = useState<string | null>(null);

  const programId = useMemo(() => new PublicKey(CURATOR_VAULT.programId), []);
  const mint = useMemo(() => new PublicKey(CURATOR_VAULT.mint), []);
  const program = useMemo(() => {
    // Reads need no wallet; writes are built here and signed by the wallet adapter.
    const provider = { connection, publicKey: publicKey ?? undefined } as unknown as AnchorProvider;
    return new Program<ForestroadCuratorVault>({ ...(idl as Idl), address: CURATOR_VAULT.programId } as ForestroadCuratorVault, provider);
  }, [connection, publicKey]);

  const [config, setConfig] = useState<ConfigAccount | null>(null);
  const [position, setPosition] = useState<PositionAccount | null | "none">(null);
  const [history, setHistory] = useState<CouponRow[]>([]);
  const [historyTruncated, setHistoryTruncated] = useState(false);
  const [historyState, setHistoryState] = useState<"loading" | "ok" | "failed">("loading");
  const [readFailureState, setReadFailureState] = useState<{wallet: string | null; text: string | null}>({
    wallet: walletAddress,
    text: null,
  });
  const readFailure = readFailureState.wallet === walletAddress ? readFailureState.text : null;
  const setReadFailure = useCallback(
    (text: string | null) => setReadFailureState({wallet: walletAddress, text}),
    [walletAddress],
  );
  const [usdcBalance, setUsdcBalance] = useState<bigint | null>(null);
  const [now, setNow] = useState<bigint>(() => BigInt(Math.floor(Date.now() / 1000)));
  const [amountState, setAmountState] = useState<{wallet: string | null; value: string}>({
    wallet: walletAddress,
    value: "",
  });
  const amount = amountState.wallet === walletAddress ? amountState.value : "";
  const setAmount = useCallback(
    (value: string) => setAmountState({wallet: walletAddress, value}),
    [walletAddress],
  );
  const [busy, setBusy] = useState<string | null>(null);
  const [noticeState, setNoticeState] = useState<{
    wallet: string | null;
    notice: {tone: "ok" | "bad"; text: string} | null;
  }>({wallet: walletAddress, notice: null});
  const notice = noticeState.wallet === walletAddress ? noticeState.notice : null;
  const setNotice = useCallback(
    (value: {tone: "ok" | "bad"; text: string} | null) => {
      setNoticeState({wallet: walletAddress, notice: value});
    },
    [walletAddress],
  );

  const positionKey = useMemo(
    () => (publicKey ? PublicKey.findProgramAddressSync([Buffer.from("position"), publicKey.toBuffer()], programId)[0] : null),
    [publicKey, programId],
  );

  // Reads are ordered: a late reply from a previous wallet or an earlier refresh is dropped.
  const readSeq = useRef(0);
  const [clusterOk, setClusterOk] = useState<boolean | null>(null);
  const clusterOkRef = useRef<boolean | null>(null);
  // Everything read is tagged with the wallet it was read for; a switch shows "reading" until
  // the new wallet's own read lands, so the previous wallet's figures never linger.
  const [shownFor, setShownFor] = useState<string | null>(null);
  const stale = shownFor !== (publicKey?.toBase58() ?? null);

  /**
   * The coupon history is one transaction fetch per signature, the read public endpoints
   * throttle first. It runs after the position is on the page and reports its own failure
   * beneath the table, so balances, rate and the claimable figure never wait on it.
   */
  const loadHistory = useCallback(
    async (live: () => boolean) => {
      if (!publicKey || !positionKey) return;
      setHistoryState("loading");
      try {
        // Failed transactions carry no state change and are skipped, and only this wallet's own
        // coupon events count.
        const sigs = (await connection.getSignaturesForAddress(positionKey, { limit: HISTORY_LIMIT })).filter((x) => !x.err);
        const txs = await fetchTransactionsGently(connection, sigs.map((x) => x.signature));
        if (!live()) return;
        const parser = new EventParser(programId, program.coder);
        const rows: CouponRow[] = [];
        txs.forEach((tx, i) => {
          if (!tx || tx.meta?.err) return;
          for (const ev of parser.parseLogs(tx.meta?.logMessages ?? [])) {
            if (ev.name !== "couponPaid") continue;
            const d = ev.data as { owner: PublicKey; periodEnd: BN; amount: BN };
            if (!d.owner.equals(publicKey)) continue;
            rows.push({ signature: sigs[i].signature, periodEnd: d.periodEnd.toNumber(), amount: bi(d.amount), when: tx.blockTime ?? null });
          }
        });
        setHistory(rows);
        setHistoryTruncated(sigs.length >= HISTORY_LIMIT);
        setHistoryState("ok");
      } catch {
        if (!live()) return;
        setHistoryState("failed");
      }
    },
    [connection, program, programId, publicKey, positionKey],
  );

  const refresh = useCallback(async (): Promise<boolean> => {
    const seq = ++readSeq.current;
    const live = () => seq === readSeq.current;
    try {
      // The build says which cluster this is; the endpoint must agree, or a wallet would be
      // asked to sign for the wrong network with the right-looking addresses.
      if (clusterOkRef.current === null) {
        const genesis = await connection.getGenesisHash();
        const ok = genesis === EXPECTED_GENESIS[CURATOR_VAULT.cluster];
        if (!live()) return false;
        clusterOkRef.current = ok;
        setClusterOk(ok);
        if (!ok) return false;
      }
      const [configKey] = PublicKey.findProgramAddressSync([Buffer.from("config")], programId);
      const c = await program.account.config.fetch(configKey);
      if (!live()) return false;
      setConfig(c);
      if (!publicKey || !positionKey) {
        setPosition(null);
        setReadFailure(null);
        return true;
      }
      const p = await program.account.position.fetchNullable(positionKey);
      if (!live()) return false;
      setPosition(p ?? "none");
      const ata = getAssociatedTokenAddressSync(mint, publicKey, true);
      // null means the wallet has no token account for the mint at all, which is not a zero
      // balance. Only the node saying so counts; a throttled or failed read is a failed read,
      // never "no account", or a curator would be told to fund a wallet that is already funded.
      const bal = await connection.getTokenAccountBalance(ata).catch((e: unknown) => {
        if (/could not find account|Invalid param: could not find/i.test(String((e as Error)?.message ?? e))) return null;
        throw e;
      });
      if (!live()) return false;
      setUsdcBalance(bal ? BigInt(bal.value.amount) : null);
      // The position is shown as soon as it is read. The coupon history below it is a separate,
      // heavier read (one transaction fetch per signature) that public endpoints throttle; it
      // must never keep the balances, the rate and the claimable figure off the page.
      setNow(BigInt(Math.floor(Date.now() / 1000)));
      setReadFailure(null);
      setShownFor(publicKey.toBase58());
      if (p) {
        // Not awaited: a write's confirmation must not wait on a read the endpoint may throttle.
        void loadHistory(live);
      } else {
        setHistory([]);
        setHistoryState("ok");
      }
      return true;
    } catch (e) {
      if (!live()) return false;
      const why = isRateLimited(e) ? "the RPC endpoint is rate-limiting this page. Wait a moment and retry." : describeFailure(e);
      setReadFailure(`The vault could not be read: ${why}`);
      setShownFor(null);
      return false;
    }
  }, [connection, mint, program, programId, publicKey, positionKey, loadHistory, setReadFailure]);

  useEffect(() => {
    const t = setTimeout(() => setMounted(true), 0);
    return () => clearTimeout(t);
  }, []);

  useEffect(() => {
    walletAddressRef.current = walletAddress;
  }, [walletAddress]);

  useEffect(() => {
    if (!pendingConnect || wallet?.adapter.name !== pendingConnect || connected) return;
    const requestedWallet = pendingConnect;
    connect()
      .catch(() => {
        // the adapter reports its own reason; the connect control simply stays
      })
      .finally(() => {
        // `connecting` changes while this promise is in flight. Clearing unconditionally through
        // an identity check keeps a rejected/cancelled QR session from stranding the button at
        // "Connecting…", while a later wallet selection remains untouched.
        setPendingConnect((current) => current === requestedWallet ? null : current);
      });
  }, [pendingConnect, wallet, connected, connect]);

  useEffect(() => {
    // The read is a subscription to chain state, kicked off asynchronously; the clock tick keeps
    // the claimable figure honest across a month boundary while the tab stays open.
    const timer = setTimeout(() => void refresh(), 0);
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 30_000);
    return () => {
      clearTimeout(timer);
      clearInterval(id);
    };
  }, [refresh]);

  /**
   * Simulate, then send, then confirm by polling signature statuses over HTTP until the
   * blockhash expires. A refusal before sending changes nothing and says so; once a signature
   * exists the outcome is whatever the chain says, never a guess.
   */
  const run = useCallback(
    async (label: string, build: () => Promise<Transaction>) => {
      if (!publicKey) return;
      const actionWallet = publicKey.toBase58();
      const actionWalletIsCurrent = () => walletAddressRef.current === actionWallet;
      setBusy(label);
      setNotice(null);
      let sig: string | null = null;
      try {
        const tx = await build();
        tx.feePayer = publicKey;
        const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();
        tx.recentBlockhash = blockhash;
        const sim = await connection.simulateTransaction(tx);
        if (sim.value.err) throw Object.assign(new Error("simulation failed"), { logs: sim.value.logs });
        sig = await sendTransaction(tx, connection);
        const outcome = await awaitSignature(connection, sig, lastValidBlockHeight);
        // A confirmation for wallet A must never start a refresh tagged to A after the user has
        // switched to wallet B. The wallet-B render owns its own refresh sequence.
        if (!actionWalletIsCurrent()) return;
        // The outcome is announced together with the re-read figures, never ahead of them.
        const refreshed = await refresh();
        if (outcome === "confirmed") {
          if (refreshed) {
            setNotice({ tone: "ok", text: `${label} confirmed.` });
            setAmount("");
          } else {
            setNotice({
              tone: "bad",
              text: `${label} confirmed, but the updated position could not be read. Retry the read before relying on these figures.`,
            });
          }
        } else if (outcome === "failed") {
          setNotice({ tone: "bad", text: `${label} was sent but the program refused it on chain. Nothing was changed.` });
        } else {
          setNotice({ tone: "bad", text: `${label} was sent but not seen confirmed before the transaction expired. Check the position below; if it did not change, try again.` });
        }
      } catch (e) {
        if (sig) {
          setNotice({ tone: "bad", text: `${label} was sent (${short(sig)}) but its status could not be read. The position below is re-read from chain.` });
          if (actionWalletIsCurrent()) await refresh();
        } else {
          setNotice({ tone: "bad", text: describeFailure(e, (e as { logs?: string[] }).logs) });
        }
      } finally {
        setBusy(null);
      }
    },
    [connection, publicKey, refresh, sendTransaction, setAmount, setNotice],
  );

  const parsedAmount = useMemo(() => {
    if (!/^\d+(\.\d{0,6})?$/.test(amount) || amount === "") return null;
    const [w, f = ""] = amount.split(".");
    return BigInt(w) * 10n ** BigInt(DECIMALS) + BigInt((f + "000000").slice(0, DECIMALS));
  }, [amount]);

  const ownerAta = publicKey ? getAssociatedTokenAddressSync(mint, publicKey, true) : null;
  const ensureAta = () =>
    publicKey && ownerAta
      ? createAssociatedTokenAccountIdempotentInstruction(publicKey, ownerAta, publicKey, mint)
      : null;

  // ── render ────────────────────────────────────────────────────────────

  const banner = CURATOR_VAULT.isDevnet ? (
    <p className="mb-5 rounded-md border border-line bg-surface px-4 py-2.5 text-[12.5px] text-ink-muted">
      <span className="font-semibold text-ink">Devnet rehearsal.</span> This surface is wired to the
      Solana devnet program and a test mint. Nothing here has value. The mainnet program is wired
      only after the audit and the deployment ceremony.
    </p>
  ) : null;

  if (!connected || !publicKey) {
    return (
      <div>
        {banner}
        <p className="text-[14.5px] leading-relaxed text-ink-muted">
          Connect a Solana wallet to see whether it is approved and, if it is, your position.
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          {!mounted ? (
            <p className="text-[13px] text-ink-faint">Looking for wallets…</p>
          ) : wallets.length === 0 ? (
            <p className="text-[13px] text-ink-faint">No Solana wallet was detected in this browser.</p>
          ) : (
            wallets.map((w) => (
              <button
                key={w.adapter.name}
                type="button"
                disabled={connecting || pendingConnect !== null}
                onClick={() => {
                  select(w.adapter.name);
                  setPendingConnect(w.adapter.name);
                }}
                className="rounded-pill border border-line-strong px-4 py-2 text-[13px] font-semibold text-ink transition-colors hover:border-accent hover:text-accent disabled:opacity-50"
              >
                {pendingConnect === w.adapter.name ? "Connecting…" : w.adapter.name}
              </button>
            ))
          )}
        </div>
      </div>
    );
  }

  const header = (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <p className="text-[13px] text-ink-muted">
        Connected <span className="font-mono text-ink">{short(publicKey.toBase58())}</span>
      </p>
      <button type="button" onClick={() => void disconnect()} className="text-[12.5px] text-ink-faint underline-offset-4 hover:underline">
        Disconnect
      </button>
    </div>
  );

  if (clusterOk === false) {
    return (
      <div>
        {banner}
        {header}
        <p role="alert" className="mt-4 text-[14px] text-danger">
          The RPC endpoint this build talks to is not the {CURATOR_VAULT.cluster} cluster it was built
          for. Nothing will be signed until that is corrected.
        </p>
      </div>
    );
  }

  if (position === null || !config || stale) {
    return (
      <div>
        {banner}
        {header}
        {notice ? (
          <p role={notice.tone === "bad" ? "alert" : "status"} className={`mt-4 text-[13.5px] ${notice.tone === "bad" ? "text-danger" : "text-ink"}`}>
            {notice.text}
          </p>
        ) : null}
        {readFailure ? (
          <div className="mt-4">
            <p role="alert" className="text-[14px] text-danger">{readFailure}</p>
            <button type="button" onClick={() => void refresh()} className="op-action mt-3 px-5 py-2.5 text-[13px]">
              Retry
            </button>
          </div>
        ) : (
          <p className="mt-4 text-[14px] text-ink-faint">Reading the vault…</p>
        )}
      </div>
    );
  }

  if (position === "none") {
    return (
      <div>
        {banner}
        {header}
        <p className="mt-4 text-[14.5px] leading-relaxed text-ink-muted">
          This wallet is not approved for the programme. Approval follows eligibility checks and
          a signed agreement; register interest below and Forest Road will be in touch. There is
          nothing to deposit from this page until then.
        </p>
      </div>
    );
  }

  const epochs = epochsOf(config);
  const revoked = !position.allowlisted;
  const p = {
    principal: bi(position.principal),
    drawn: bi(position.drawn),
    couponOwed: bi(position.couponOwed),
    couponPayable: bi(position.couponPayable),
    couponRemainder: bi(position.couponRemainder),
    couponAccruedThrough: bi(position.couponAccruedThrough),
    couponPaidThrough: bi(position.couponPaidThrough),
  };
  const view = couponView(p, epochs, now);
  const earnedSinceCheckpoint = accrue(
    p.principal,
    epochs,
    p.couponAccruedThrough,
    now,
    p.couponRemainder,
  ).whole;
  const earnedUnpaid = p.couponOwed + earnedSinceCheckpoint;
  const rate = currentRateBps(epochs, now);
  const total = bi(config.totalPrincipal);
  const drawn = bi(config.drawn);
  const drawnPct = total > 0n ? Number((drawn * 10_000n) / total) / 100 : 0;
  const noticePending = bi(position.noticeRequestedAt) !== 0n;
  const eligibleAt = bi(position.withdrawalEligibleAt);
  const withdrawablePrincipal = p.principal >= p.drawn ? p.principal - p.drawn : 0n;
  const canWithdraw = eligibleAt !== 0n && now >= eligibleAt;
  const paused = config.paused;
  const positionTermsActive = p.principal !== 0n;
  const lockSeconds = positionTermsActive ? bi(position.lockSeconds) : bi(config.lockSeconds);
  const noticeSeconds = positionTermsActive ? bi(position.noticeSeconds) : bi(config.noticeSeconds);
  const canClose =
    revoked
    && p.principal === 0n
    && p.drawn === 0n
    && p.couponOwed === 0n
    && !noticePending;
  const depositAmountValid =
    parsedAmount !== null
    && parsedAmount > 0n
    && usdcBalance !== null
    && parsedAmount <= usdcBalance;
  const withdrawAmountValid =
    parsedAmount !== null
    && parsedAmount > 0n
    && parsedAmount <= withdrawablePrincipal;
  const accrual30d = accrue(p.principal, epochs, now, now + 30n * 86_400n, 0n).whole;

  const row = (label: string, value: string) => (
    <div className="flex items-baseline justify-between gap-4 border-b border-line py-2 text-[13.5px]">
      <span className="text-ink-muted">{label}</span>
      <span className="font-mono text-ink">{value}</span>
    </div>
  );

  return (
    <div>
      {banner}
      {header}

      <div className="mt-5 grid gap-x-10 gap-y-2 sm:grid-cols-2">
        {row("Principal", `${formatUnits(p.principal, DECIMALS)} USDC`)}
        {row("Principal deployed for this position", `${formatUnits(p.drawn, DECIMALS)} USDC`)}
        {row("Your rate", `${(rate / 100).toFixed(2)}% Actual/360`)}
        {row("Committed until", utc(bi(position.lockEnd)))}
        {row(positionTermsActive ? "Your lock term" : "Lock term for a new deposit", duration(lockSeconds))}
        {row("Withdrawal notice term", duration(noticeSeconds))}
        {row("Withdrawal", noticePending ? `eligible ${utc(eligibleAt)}` : "no notice given")}
        {row("Coupon earned and unpaid", `${formatUnits(earnedUnpaid, DECIMALS)} USDC`)}
        {row("Coupon payable now", `${formatUnits(view.claimable, DECIMALS)} USDC`)}
        {row("Accrued since the last boundary", `${formatUnits(view.pendingThisMonth, DECIMALS)} USDC`)}
        {row("Next coupon boundary", utc(view.nextBoundary))}
        {row("Vault capital deployed", `${drawnPct.toFixed(1)}% of ${formatUnits(total, DECIMALS)}`)}
        {row("Losses recorded on this position", `${formatUnits(bi(position.lossesRecorded), DECIMALS)} USDC`)}
        {row("Agreement hash", bytes32(position.agreementHash))}
        {row("Next 30 days on the rate schedule in force", `${formatUnits(accrual30d, DECIMALS)} USDC`)}
      </div>

      {notice ? (
        <p role={notice.tone === "bad" ? "alert" : "status"} className={`mt-4 text-[13.5px] ${notice.tone === "bad" ? "text-danger" : "text-ink"}`}>
          {notice.text}
        </p>
      ) : null}
      {paused ? (
        <p className="mt-4 text-[13.5px] text-ink-muted">Deposits are paused by Forest Road. Withdrawals and coupons are not affected.</p>
      ) : null}
      {revoked ? (
        <p className="mt-4 text-[13.5px] text-ink-muted">
          Forest Road has withdrawn approval for new deposits from this wallet. Your principal,
          accrued coupons, notice and withdrawal rights are unaffected.
        </p>
      ) : null}
      {position.payoutHalted ? (
        <p role="alert" className="mt-4 text-[13.5px] text-ink-muted">
          Coupon payouts to this wallet are on hold pending a review by Forest Road. Accrual
          continues and the amount stays owed; withdrawals are unaffected.
        </p>
      ) : null}

      {/* ── writes ─────────────────────────────────────────────────────── */}
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <div>
          <label htmlFor="cv-amount" className="block text-[12px] font-semibold uppercase tracking-[0.12em] text-ink-muted">
            Amount (USDC)
          </label>
          <div className="op-field mt-2 flex items-center gap-2 px-4 py-3">
            <input
              id="cv-amount"
              inputMode="decimal"
              placeholder="0.00"
              value={amount}
              onChange={(e) => {
                if (/^\d*\.?\d{0,6}$/.test(e.target.value)) setAmount(e.target.value);
              }}
              className="w-full bg-transparent font-mono text-[15px] text-ink outline-none placeholder:text-ink-faint"
            />
            <span className="text-[12.5px] font-semibold text-ink-faint">USDC</span>
          </div>
          <p className="mt-1.5 text-[12px] text-ink-faint">
            {usdcBalance === null
              ? "This wallet has no token account for the vault's mint yet; receive some first to deposit."
              : `Wallet balance ${formatUnits(usdcBalance, DECIMALS)} USDC`}
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            {revoked ? null : (
            <button
              type="button"
              disabled={busy !== null || paused || noticePending || !depositAmountValid}
              title={noticePending ? "Cancel the withdrawal notice to deposit" : undefined}
              onClick={() =>
                void run("Deposit", async () =>
                  program.methods.deposit(new BN(parsedAmount!.toString())).accountsPartial({ owner: publicKey, ownerAta: ownerAta! }).transaction(),
                )
              }
              className="op-action px-5 py-2.5 text-[13px]"
            >
              {busy === "Deposit" ? "Confirm in wallet…" : "Deposit"}
            </button>
            )}
            <button
              type="button"
              disabled={busy !== null || !canWithdraw || !withdrawAmountValid}
              title={!canWithdraw ? "Withdrawals open once the notice and commitment have elapsed" : undefined}
              onClick={() =>
                void run("Withdrawal", async () => {
                  const tx = await program.methods.withdraw(new BN(parsedAmount!.toString())).accountsPartial({ owner: publicKey, ownerAta: ownerAta! }).transaction();
                  const pre = ensureAta();
                  return pre ? new Transaction().add(pre, ...tx.instructions) : tx;
                })
              }
              className="rounded-pill border border-line-strong px-5 py-2.5 text-[13px] font-semibold text-ink transition-colors hover:border-accent hover:text-accent disabled:cursor-not-allowed disabled:opacity-50"
            >
              {busy === "Withdrawal" ? "Confirm in wallet…" : "Withdraw"}
            </button>
          </div>
          {parsedAmount !== null && usdcBalance !== null && parsedAmount > usdcBalance && !revoked ? (
            <p className="mt-2 text-[12px] text-ink-faint">Deposit cannot exceed this wallet&apos;s USDC balance.</p>
          ) : null}
          {parsedAmount !== null && parsedAmount > withdrawablePrincipal ? (
            <p className="mt-2 text-[12px] text-ink-faint">
              Withdrawal cannot exceed {formatUnits(withdrawablePrincipal, DECIMALS)} USDC of principal currently held in the vault.
            </p>
          ) : null}
        </div>

        <div className="flex flex-col gap-2">
          {noticePending ? (
            <button
              type="button"
              disabled={busy !== null}
              onClick={() => void run("Notice cancelled", async () => program.methods.cancelWithdrawal().accountsPartial({ owner: publicKey }).transaction())}
              className="rounded-pill border border-line-strong px-5 py-2.5 text-[13px] font-semibold text-ink transition-colors hover:border-accent hover:text-accent disabled:opacity-50"
            >
              {busy === "Notice cancelled" ? "Confirm in wallet…" : "Cancel withdrawal notice"}
            </button>
          ) : (
            <button
              type="button"
              disabled={busy !== null || p.principal === 0n}
              onClick={() => void run("Withdrawal notice", async () => program.methods.requestWithdrawal().accountsPartial({ owner: publicKey }).transaction())}
              className="rounded-pill border border-line-strong px-5 py-2.5 text-[13px] font-semibold text-ink transition-colors hover:border-accent hover:text-accent disabled:opacity-50"
            >
              {busy === "Withdrawal notice" ? "Confirm in wallet…" : "Give withdrawal notice"}
            </button>
          )}
          <button
            type="button"
            disabled={busy !== null || view.claimable === 0n || position.payoutHalted}
            title={position.payoutHalted
              ? "Coupon payouts to this position are halted"
              : view.claimable === 0n
                ? "Nothing is claimable before the next month boundary"
                : undefined}
            onClick={() =>
              void run("Coupon claim", async () => {
                const tx = await program.methods.payCoupon().accountsPartial({ cranker: publicKey, position: positionKey!, ownerAta: ownerAta! }).transaction();
                const pre = ensureAta();
                return pre ? new Transaction().add(pre, ...tx.instructions) : tx;
              })
            }
            className="op-action px-5 py-2.5 text-[13px]"
          >
            {busy === "Coupon claim" ? "Confirm in wallet…" : `Claim ${formatUnits(view.claimable, DECIMALS)} USDC`}
          </button>
          <p className="text-[12px] leading-relaxed text-ink-faint">
            Coupons are payable once per calendar month for accrual through the last UTC month
            boundary, from a pool Forest Road funds. If the pool is short, the claim is refused
            and the amount stays owed.
          </p>
          {canClose ? (
            <button
              type="button"
              disabled={busy !== null}
              onClick={() => void run("Position closure", async () => program.methods.closePosition().accountsPartial({ owner: publicKey }).transaction())}
              className="rounded-pill border border-line-strong px-5 py-2.5 text-[13px] font-semibold text-ink transition-colors hover:border-accent hover:text-accent disabled:opacity-50"
            >
              {busy === "Position closure" ? "Confirm in wallet…" : "Close empty position"}
            </button>
          ) : null}
        </div>
      </div>

      {/* ── coupon history ─────────────────────────────────────────────── */}
      <div className="mt-8">
        <p className="text-[12px] font-semibold uppercase tracking-[0.12em] text-ink-muted">Coupons paid</p>
        {historyState === "loading" ? (
          <p className="mt-2 text-[13.5px] text-ink-faint">Reading the coupon history…</p>
        ) : historyState === "failed" ? (
          <div className="mt-2">
            <p className="text-[13.5px] text-ink-faint">
              The coupon history could not be read (the RPC endpoint is rate-limiting this page). Your position above is current.
            </p>
            <button type="button" onClick={() => void refresh()} disabled={busy !== null} className="op-action mt-2 px-4 py-2 text-[13px]">
              Retry
            </button>
          </div>
        ) : history.length === 0 ? (
          <p className="mt-2 text-[13.5px] text-ink-faint">None yet.</p>
        ) : (
          <div className="mt-2 overflow-x-auto">
            <table className="w-full text-[13px]">
              <thead>
                <tr className="text-left text-ink-faint">
                  <th className="py-1.5 font-medium">Period through</th>
                  <th className="py-1.5 font-medium">Amount</th>
                  <th className="py-1.5 font-medium">Paid</th>
                  <th className="py-1.5 font-medium">Transaction</th>
                </tr>
              </thead>
              <tbody>
                {history.map((h) => (
                  <tr key={h.signature} className="border-t border-line">
                    <td className="py-1.5 font-mono">{utc(h.periodEnd)}</td>
                    <td className="py-1.5 font-mono">{formatUnits(h.amount, DECIMALS)} USDC</td>
                    <td className="py-1.5 font-mono">{h.when ? utc(h.when) : "…"}</td>
                    <td className="py-1.5 font-mono">
                      <a href={CURATOR_VAULT.explorerTx(h.signature)} target="_blank" rel="noreferrer" className="text-accent underline-offset-4 hover:underline">
                        {short(h.signature)}
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {historyTruncated ? (
              <p className="mt-2 text-[12px] text-ink-faint">Showing the coupons in the {HISTORY_LIMIT} most recent transactions on this position.</p>
            ) : null}
          </div>
        )}
      </div>
      <p className="mt-6 text-[12px] leading-relaxed text-ink-faint">
        Program{" "}
        <a href={CURATOR_VAULT.explorer(CURATOR_VAULT.programId)} target="_blank" rel="noreferrer" className="text-accent underline-offset-4 hover:underline">
          {short(CURATOR_VAULT.programId)}
        </a>
        . Your position account{" "}
        <a href={CURATOR_VAULT.explorer(positionKey!.toBase58())} target="_blank" rel="noreferrer" className="text-accent underline-offset-4 hover:underline">
          {short(positionKey!.toBase58())}
        </a>
        . The agreement you signed governs; this page shows the ledger it settles on.
      </p>
    </div>
  );
}
