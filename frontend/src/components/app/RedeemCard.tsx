"use client";

/**
 * Redeem, two honest paths (ADR-0010/0018):
 *  - USDfr → tUSDC: instant, burns against idle reserves via MintRedeemController.redeem
 *    (floors to a whole stable unit, no dust taken).
 *  - sUSDfr → queue: epoch FIFO. Requesting locks shares into the queue; fills happen
 *    at epoch settlement within the liquidity budget; claims are anytime after fill.
 *    Never presented as instant.
 * Below the form: this wallet's queue positions with live fill/claim state.
 */

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {parseUnits, zeroAddress, type Address} from "viem";
import {useAccount, usePublicClient, useReadContract, useReadContracts} from "wagmi";
import {CONTRACTS, IS_TESTNET, STABLE_SYMBOL} from "@/config/contracts";
import {CONTROLLER_ABI, ERC20_ABI, IMPAIRMENT_SOURCE_ABI, QUEUE_ABI, RESERVES_ABI, SHARE_DECIMALS, VAULT_ABI, VAULT_STAGE2_ABI} from "@/lib/abi";
import {fmtAmount, fmtCountdown} from "@/lib/format";
import {secondsUntilEligible} from "@/lib/queue";
import {useWriteFlow} from "@/components/app/useWriteFlow";
import {useNowSeconds} from "@/components/app/useNowSeconds";
import {ActionButton, AmountInput, StatusLine, busyLabelFor} from "@/components/app/WriteBits";
import {RedeemRouteVisual} from "@/components/app/ActionRouteVisuals";
import {RestartingEventWatcher} from "@/components/app/RestartingEventWatcher";
import {ACCOUNT_POLL, EVENT_WATCH_POLL_MS, QUEUE_POLL} from "@/lib/polling";

/** How many trailing queue requests to scan for this wallet's positions. One
 *  multicall regardless of size; on this testnet totalRequests stays far below
 *  this. If it's ever exceeded, the UI says so instead of silently hiding
 *  older (possibly claimable) positions. */
const REQUEST_SCAN_WINDOW = 500n;
const POLL = ACCOUNT_POLL;

/** Read only from the instant-redeem click handler: a clock is never consulted during render. */
function instantRedeemDeadline(): bigint {
  return BigInt(Math.floor(Date.now() / 1_000) + 1_200);
}

type Mode = "instant" | "queue";
type QueuePosition = {
  id: bigint;
  sharesRemaining: bigint;
  assetsClaimable: bigint;
  epochRequested: bigint;
  requestedAt: bigint;
};

export function RedeemCard({writesEnabled, chainOk}: {writesEnabled: boolean; chainOk: boolean}) {
  const {address} = useAccount();
  const publicClient = usePublicClient();
  const [mode, setMode] = useState<Mode>("instant");
  const [amount, setAmount] = useState("");
  const [lookupIdText, setLookupIdText] = useState("");
  const [acknowledgedCooldown, setAcknowledgedCooldown] = useState<bigint | null>(null);
  const [acknowledgedSubParQuote, setAcknowledgedSubParQuote] = useState<string | null>(null);
  const [preparingInstant, setPreparingInstant] = useState(false);
  const [prepOwner, setPrepOwner] = useState(address);
  if (prepOwner !== address) {
    setPrepOwner(address);
    if (preparingInstant) setPreparingInstant(false);
  }
  const preparingInstantRef = useRef(false);
  const mountedRef = useRef(true);
  const instantPrepGenRef = useRef(0);
  const flow = useWriteFlow();
  const claimFlow = useWriteFlow();

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      instantPrepGenRef.current += 1;
    };
  }, []);

  useEffect(() => {
    instantPrepGenRef.current += 1;
    preparingInstantRef.current = false;
  }, [address]);

  const usdfr = CONTRACTS.USDfr!;
  const vault = CONTRACTS.sUSDfr!;
  const controller = CONTRACTS.MintRedeemController!;
  const queue = CONTRACTS.RedemptionQueue!;
  // ── Reads ────────────────────────────────────────────────────────────
  const {data: usdfrBalance, isLoading: usdfrBalanceLoading} = useReadContract({
    address: usdfr, abi: ERC20_ABI, functionName: "balanceOf",
    args: address ? [address] : undefined, query: {enabled: Boolean(address), ...POLL},
  });
  const {data: shareBalance, isLoading: shareBalanceLoading} = useReadContract({
    address: vault, abi: ERC20_ABI, functionName: "balanceOf",
    args: address ? [address] : undefined, query: {enabled: Boolean(address), ...POLL},
  });
  const {data: shareAllowance} = useReadContract({
    address: vault, abi: ERC20_ABI, functionName: "allowance",
    args: address ? [address, queue] : undefined, query: {enabled: Boolean(address), ...POLL},
  });
  // Queue state changes without user action (epoch boundary, keeper closes), // poll it so the countdown and settle badge don't freeze at page-load.
  const {data: epochEndsAt, refetch: refetchEpochEndsAt} = useReadContract({
    address: queue, abi: QUEUE_ABI, functionName: "epochEndsAt", query: QUEUE_POLL,
  });
  const {data: isSettling, refetch: refetchIsSettling} = useReadContract({
    address: queue, abi: QUEUE_ABI, functionName: "isSettling", query: QUEUE_POLL,
  });
  const {data: totalRequests, refetch: refetchTotalRequests} = useReadContract({
    address: queue, abi: QUEUE_ABI, functionName: "totalRequests", query: QUEUE_POLL,
  });
  const {data: redeemCooldown, refetch: refetchRedeemCooldown} = useReadContract({
    address: queue, abi: QUEUE_ABI, functionName: "redeemCooldown", query: QUEUE_POLL,
  });
  const {data: impairmentSourceAddress} = useReadContract({
    address: vault, abi: VAULT_ABI, functionName: "impairmentSource", query: QUEUE_POLL,
  });
  const hasImpairmentSource = Boolean(
    impairmentSourceAddress && impairmentSourceAddress !== zeroAddress,
  );
  const {data: pendingSeniorImpairment} = useReadContract({
    address: (impairmentSourceAddress ?? zeroAddress) as Address,
    abi: IMPAIRMENT_SOURCE_ABI,
    functionName: "pendingSeniorImpairment",
    query: {enabled: hasImpairmentSource, ...QUEUE_POLL},
  });
  // Stage 2 (ee9b228a) settlement freeze views: read with allowFailure: true so pre-Stage-2
  // deployments without unresolvedPastDueExposure() degrade cleanly.
  const {data: freezeReads} = useReadContracts({
    allowFailure: true,
    query: QUEUE_POLL,
    contracts: [
      {address: vault, abi: VAULT_STAGE2_ABI, functionName: "unresolvedPastDueExposure"},
      {address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "reserveLossExitsLocked"},
    ],
  });
  const unresolvedPastDue =
    freezeReads?.[0]?.status === "success" ? (freezeReads[0].result as bigint) : undefined;
  const reserveLossExitsLocked =
    freezeReads?.[1]?.status === "success" ? (freezeReads[1].result as boolean) : undefined;
  const queueSettlementFrozen =
    (unresolvedPastDue !== undefined && unresolvedPastDue > 0n) || reserveLossExitsLocked === true;
  const exitImpaired = (pendingSeniorImpairment ?? 0n) > 0n;

  // USDfr is 18-dec; sUSDfr shares are 24-dec (ERC-4626 decimals offset).
  const decimals = mode === "instant" ? 18 : SHARE_DECIMALS;
  let parsed: bigint | null = null;
  try {
    parsed = amount ? parseUnits(amount, decimals) : null;
  } catch {
    parsed = null;
  }

  // Direct USDfr -> USDC preview: captures both par and sub-par pro-rata settlements.
  const {
    data: instantPreviewRaw,
    isLoading: instantPreviewLoading,
    isError: instantPreviewError,
  } = useReadContract({
    address: controller,
    abi: CONTROLLER_ABI,
    functionName: "previewRedeem",
    args: parsed !== null && parsed > 0n ? [parsed] : undefined,
    query: {enabled: mode === "instant" && parsed !== null && parsed > 0n, ...POLL},
  });
  const instantQuote =
    Array.isArray(instantPreviewRaw) &&
    typeof instantPreviewRaw[0] === "bigint" &&
    typeof instantPreviewRaw[1] === "bigint"
      ? {usdcOut: instantPreviewRaw[0], usdfrIn: instantPreviewRaw[1]}
      : null;
  const instantRedeemable =
    instantQuote !== null && instantQuote.usdcOut > 0n && instantQuote.usdfrIn > 0n;
  const parUsdcOut = parsed !== null ? parsed / 10n ** 12n : 0n;
  const instantSubPar =
    mode === "instant" &&
    instantRedeemable &&
    parUsdcOut > 0n &&
    instantQuote.usdcOut < parUsdcOut;
  const subParQuoteKey =
    instantSubPar && parsed !== null && instantQuote !== null
      ? `${parsed.toString()}:${instantQuote.usdcOut.toString()}`
      : null;
  const subParAcknowledged =
    subParQuoteKey !== null && acknowledgedSubParQuote === subParQuoteKey;

  // ADR-0022 Option Y: a queued exit settles at the CONSERVATIVE redemption NAV
  // (`totalAssets - pendingSeniorImpairment`), not the deposit NAV. Previewing with
  // `convertToAssets` overstated what the user would receive during exactly the window the
  // conservative mark exists for, a declared-but-unrealized default. `previewRedeem` is the
  // number the contract will actually use.
  const {data: previewAssets} = useReadContract({
    address: vault, abi: VAULT_ABI, functionName: "previewRedeem",
    args: parsed !== null && parsed > 0n ? [parsed] : undefined,
    query: {enabled: mode === "queue" && parsed !== null && parsed > 0n, ...POLL},
  });

  // The deposit-price figure, read only so the UI can DISCLOSE a gap rather than hide it.
  const {data: depositPriceAssets} = useReadContract({
    address: vault, abi: VAULT_ABI, functionName: "convertToAssets",
    args: parsed !== null && parsed > 0n ? [parsed] : undefined,
    query: {enabled: mode === "queue" && parsed !== null && parsed > 0n, ...POLL},
  });

  // ── This wallet's queue positions (bounded trailing scan) ────────────
  const scanIds = useMemo(() => {
    if (totalRequests === undefined || totalRequests === 0n) return [] as bigint[];
    const from = totalRequests > REQUEST_SCAN_WINDOW ? totalRequests - REQUEST_SCAN_WINDOW : 0n;
    const ids: bigint[] = [];
    for (let i = from; i < totalRequests; i++) ids.push(i);
    return ids;
  }, [totalRequests]);

  const {data: scanned, refetch: refetchScanned} = useReadContracts({
    contracts: scanIds.map((id) => ({
      address: queue, abi: QUEUE_ABI, functionName: "request", args: [id] as const,
    })),
    query: {
      enabled: scanIds.length > 0 && Boolean(address),
      // Fallback for transports that cannot maintain an event watcher.
      ...QUEUE_POLL,
    },
  });

  const lookupId = useMemo(() => {
    if (!/^\d+$/.test(lookupIdText)) return undefined;
    if (totalRequests === undefined) return undefined;
    const id = BigInt(lookupIdText);
    if (id >= totalRequests) return undefined;
    return id;
  }, [lookupIdText, totalRequests]);
  const {data: lookedUpRequest, refetch: refetchLookedUpRequest} = useReadContract({
    address: queue,
    abi: QUEUE_ABI,
    functionName: "request",
    args: lookupId !== undefined ? [lookupId] : undefined,
    query: {enabled: lookupId !== undefined && Boolean(address), ...POLL},
  });

  // Keeper settlement happens outside this browser, so the app's write-flow
  // invalidation cannot see it. Refresh on any queue event: RequestFilled makes
  // the Claim button appear, Claimed removes it, and the request/epoch events
  // keep the bounded scan and countdown current. HTTP transports poll logs, so
  // this works for the local Anvil fork as well as public Sepolia RPCs. The
  // watcher restarts from the current block after a failed read (see
  // RestartingEventWatcher), so a long sleep cannot stop it for good.
  const queueLogRefetchRef = useRef<() => void>(() => undefined);
  useEffect(() => {
    queueLogRefetchRef.current = () => {
      void refetchEpochEndsAt();
      void refetchIsSettling();
      void refetchTotalRequests();
      void refetchRedeemCooldown();
      void refetchScanned();
      if (lookupId !== undefined) void refetchLookedUpRequest();
    };
  }, [
    lookupId,
    refetchEpochEndsAt,
    refetchIsSettling,
    refetchLookedUpRequest,
    refetchRedeemCooldown,
    refetchScanned,
    refetchTotalRequests,
  ]);
  const onQueueLogs = useCallback(() => {
    queueLogRefetchRef.current();
  }, []);

  const myRequests = useMemo(() => {
    if (!address) return [] as QueuePosition[];
    const positions = (scanned ?? [])
      .map((r, i) => ({id: scanIds[i], result: r.result as
        readonly [string, bigint, bigint, bigint, bigint] | undefined}))
      .filter((r) => r.result && r.result[0].toLowerCase() === address.toLowerCase())
      .map((r) => ({
        id: r.id,
        sharesRemaining: r.result![1],
        assetsClaimable: r.result![2],
        epochRequested: r.result![3],
        requestedAt: r.result![4],
      }));
    const direct = lookedUpRequest as
      readonly [string, bigint, bigint, bigint, bigint] | undefined;
    if (
      lookupId !== undefined &&
      direct &&
      direct[0].toLowerCase() === address.toLowerCase() &&
      !positions.some((position) => position.id === lookupId)
    ) {
      positions.push({
        id: lookupId,
        sharesRemaining: direct[1],
        assetsClaimable: direct[2],
        epochRequested: direct[3],
        requestedAt: direct[4],
      });
    }
    return positions;
  }, [scanned, scanIds, address, lookupId, lookedUpRequest]);

  const lookupOwner = (
    lookedUpRequest as readonly [string, bigint, bigint, bigint, bigint] | undefined
  )?.[0];
  const lookupIsOutOfRange =
    /^\d+$/.test(lookupIdText) &&
    totalRequests !== undefined &&
    BigInt(lookupIdText) >= totalRequests;
  const lookupBelongsToAnotherWallet =
    lookupId !== undefined &&
    lookupOwner !== undefined &&
    address !== undefined &&
    lookupOwner.toLowerCase() !== address.toLowerCase();

  // ── Actions ──────────────────────────────────────────────────────────
  const needsApproval =
    mode === "queue" && parsed !== null && parsed > 0n &&
    shareAllowance !== undefined && shareAllowance < parsed;
  // Bind the acknowledgement to the value the user actually saw. A governance
  // change to the live cooldown invalidates an earlier acknowledgement.
  const queueAcknowledged =
    redeemCooldown !== undefined && acknowledgedCooldown === redeemCooldown;
  // Instant redeem is KYC-gated on-chain; the queue paths are not, the UI
  // mirrors the contracts exactly (never stricter, never looser).
  const actionAllowed = mode === "instant" ? writesEnabled : chainOk;
  // Queue mode needs the share allowance LOADED for an honest Approve/Request label.
  // Instant mode fails closed until previewRedeem returns a positive quote (never submitting
  // minUsdcOut = 0 or slipping back to 1-arg redeem), and requires explicit acknowledgement when sub-par.
  const writeBusy = flow.busy || preparingInstant;
  const canSubmit =
    actionAllowed && parsed !== null && parsed > 0n && !writeBusy &&
    (mode === "instant"
      ? instantRedeemable && (!instantSubPar || subParAcknowledged)
      : shareAllowance !== undefined &&
        (needsApproval || (redeemCooldown !== undefined && queueAcknowledged)));

  const act = () => {
    if (parsed === null || writeBusy) return;
    if (mode === "instant") {
      if (!instantRedeemable || instantQuote === null || preparingInstantRef.current) return;
      const runInstant = (deadline: bigint) => {
        flow.run({
          address: controller,
          abi: CONTROLLER_ABI,
          functionName: "redeem",
          args: [parsed, instantQuote.usdcOut, deadline],
          onSuccess: () => {
            setAmount("");
            setAcknowledgedSubParQuote(null);
          },
        });
      };
      if (!publicClient) {
        runInstant(instantRedeemDeadline());
        return;
      }
      const prepGen = ++instantPrepGenRef.current;
      preparingInstantRef.current = true;
      setPreparingInstant(true);
      void publicClient
        .getBlock()
        .then((block) => block.timestamp + 1_200n)
        .catch(() => instantRedeemDeadline())
        .then((deadline) => {
          if (!mountedRef.current || instantPrepGenRef.current !== prepGen) return;
          runInstant(deadline);
        })
        .finally(() => {
          if (instantPrepGenRef.current === prepGen) {
            preparingInstantRef.current = false;
            if (mountedRef.current) setPreparingInstant(false);
          }
        });
    } else if (needsApproval) {
      flow.run({address: vault, abi: ERC20_ABI, functionName: "approve", args: [queue, parsed]});
    } else if (queueAcknowledged) {
      flow.run({
        address: queue, abi: QUEUE_ABI, functionName: "requestRedeem",
        args: [parsed],
        onSuccess: () => {
          setAmount("");
          setAcknowledgedCooldown(null);
        },
      });
    }
  };

  const now = useNowSeconds();
  // A lapsed heartbeat is left in the past on purpose: when nothing is eligible the keeper's
  // close abandons without advancing it, so the next request settles as soon as its hold ends.
  // Counting down to a time already gone would read "ends in now" for as long as that lasts.
  const epochOpen = epochEndsAt !== undefined && now !== null && Number(epochEndsAt) <= now;
  const epochCountdown =
    epochEndsAt !== undefined && now !== null ? fmtCountdown(Number(epochEndsAt) - now) : null;
  const cooldownDuration =
    redeemCooldown !== undefined ? fmtCountdown(Number(redeemCooldown)) : null;

  const balanceShown = mode === "instant" ? usdfrBalance : shareBalance;
  const balanceLoading = mode === "instant" ? usdfrBalanceLoading : shareBalanceLoading;
  const symbol = mode === "instant" ? "USDfr" : "sUSDfr";
  const activeRequests = myRequests.filter((r) => r.sharesRemaining > 0n || r.assetsClaimable > 0n);
  const completedRequests = myRequests.filter((r) => r.sharesRemaining === 0n && r.assetsClaimable === 0n);

  return (
    <div id="redeem-card" className="panel app-action-card app-action-card--redeem flex scroll-mt-24 flex-col p-6" data-viewport-replay="">
      <RestartingEventWatcher
        label="redeem.queue_watcher"
        address={queue}
        abi={QUEUE_ABI}
        pollingInterval={EVENT_WATCH_POLL_MS}
        onLogs={onQueueLogs}
      />
      <div className="flex items-baseline justify-between">
        <h3 className="font-display text-[16px] font-semibold tracking-tight">Redeem</h3>
        <div
          className="flex gap-1 rounded-pill border border-line bg-surface p-0.5"
          role="group"
          aria-label="Redemption route"
        >
          {(["instant", "queue"] as const).map((m) => (
            <button
              key={m}
              type="button"
              aria-pressed={mode === m}
              // AUDIT FIX (RC-05): switching mode resets both flows, so it must be
              // unavailable while either has a write in flight, otherwise the
              // in-flight transaction is orphaned and its outcome never surfaces.
              disabled={writeBusy || claimFlow.busy}
              onClick={() => {
                instantPrepGenRef.current += 1;
                preparingInstantRef.current = false;
                setPreparingInstant(false);
                setMode(m);
                setAmount("");
                setAcknowledgedCooldown(null);
                setAcknowledgedSubParQuote(null);
                flow.reset();
                claimFlow.reset();
              }}
              className={`min-h-9 rounded-pill px-3.5 py-2 text-[12px] font-semibold tracking-[0.02em] transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${ mode === m ?"bg-accent text-raised" : "text-ink-faint hover:text-ink-muted"
              }`}
            >
              {m === "instant" ? "USDfr" : "sUSDfr"}
            </button>
          ))}
        </div>
      </div>

      <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
        {mode === "instant"
          ? `Redeem USDfr for ${STABLE_SYMBOL} against idle reserves (1:1 at par while backing holds, or sub-par if impaired): instant, floored to a whole ${STABLE_SYMBOL} base unit (0.000001 ${STABLE_SYMBOL}).`
          : "Unstake through the non-cancellable redemption queue. A request first completes its minimum hold, then fills FIFO as liquidity allows. Actual settlement can take longer."}
      </p>

      <RedeemRouteVisual key={mode} mode={mode} stableSymbol={STABLE_SYMBOL} />

      {mode === "queue" ? (
        <div className="mt-3 space-y-1 font-mono text-[11px] text-ink-faint">
          <p>
            Minimum hold before eligibility:{" "}
            <span className="text-warn">{cooldownDuration ?? "loading…"}</span>
          </p>
          <p>
            {epochOpen ? (
              <>
                Settlement heartbeat: <span className="text-ink-muted">open</span>, eligible
                requests settle as their hold ends
              </>
            ) : (
              <>
                Settlement heartbeat ends in{" "}
                <span className="text-ink-muted">{epochCountdown ?? "–"}</span>
              </>
            )}
            {isSettling ? <span className="ml-2 text-warn">settling now</span> : null}
          </p>
          <p>
            The heartbeat is not your exit date. FIFO order and available liquidity may extend
            the wait after your cooldown completes.
          </p>
        </div>
      ) : null}

      {/* Same balance vocabulary as the other two write cards. */}
      <p className="mt-4 font-mono text-[11px] text-ink-faint">
        Balance:{" "}
        {balanceLoading ? (
          <span>loading…</span>
        ) : balanceShown !== undefined ? (
          <span className="text-ink-muted">
            {fmtAmount(balanceShown, decimals)} {symbol}
          </span>
        ) : address ? (
          <span>unavailable</span>
        ) : (
          <span>wallet not connected</span>
        )}
      </p>

      <AmountInput
        value={amount}
        onChange={(value) => {
          instantPrepGenRef.current += 1;
          setAmount(value);
          setAcknowledgedSubParQuote(null);
        }}
        symbol={symbol}
        maxDecimals={decimals}
        disabled={!actionAllowed || writeBusy}
        onMax={
          balanceShown !== undefined && balanceShown > 0n
            ? () => {
                instantPrepGenRef.current += 1;
                setAmount(fmtAmount(balanceShown, decimals, decimals).replace(/,/g, ""));
                setAcknowledgedSubParQuote(null);
              }
            : undefined
        }
      />

      {mode === "instant" && reserveLossExitsLocked ? (
        <div role="alert" className="mt-3 rounded-card border border-warn/50 bg-warn/10 p-3 text-[11.5px] leading-relaxed text-ink">
          <strong className="font-semibold text-warn">Direct redemptions are currently frozen on-chain.</strong>{" "}
          A reserve custody loss or reserve-loss arm is active until reconciliation completes.
        </div>
      ) : null}

      {mode === "instant" && parsed !== null && parsed > 0n ? (
        instantRedeemable && instantQuote !== null ? (
          <p className="mt-2 font-mono text-[11px] text-ink-faint">
            Quoted output:{" "}
            <span className="text-ink-muted">
              {fmtAmount(instantQuote.usdcOut, 6, 6)} {STABLE_SYMBOL}
            </span>{" "}
            for {fmtAmount(instantQuote.usdfrIn, 18, 6)} USDfr
            {instantSubPar ? " (pro-rata below 1:1 par)" : " (1:1 par)"}
          </p>
        ) : instantQuote !== null ? (
          <p role="status" className="mt-2 font-mono text-[11px] text-warn">
            {parUsdcOut === 0n
              ? `Amount is below the 0.000001 USDfr (1 ${STABLE_SYMBOL} base unit) dust floor.`
              : `Direct redemption currently quotes 0 ${STABLE_SYMBOL} (paused, frozen, accrual pending, or below the minimum redeemable unit).`}
          </p>
        ) : instantPreviewError ? (
          <p role="status" className="mt-2 font-mono text-[11px] text-warn">
            Redemption quote unavailable on-chain. Check the amount or retry in a moment.
          </p>
        ) : instantPreviewLoading ? (
          <p className="mt-2 font-mono text-[11px] text-ink-faint">Quoting redemption…</p>
        ) : null
      ) : null}

      {mode === "instant" && instantSubPar && instantRedeemable && instantQuote !== null ? (
        <label className="mt-3 flex cursor-pointer items-start gap-2.5 rounded-card border border-warn/50 bg-warn/10 p-3 text-[11px] leading-relaxed text-ink">
          <input
            type="checkbox"
            checked={subParAcknowledged}
            onChange={(event) =>
              setAcknowledgedSubParQuote(event.target.checked ? subParQuoteKey : null)
            }
            disabled={!writesEnabled || writeBusy}
            className="mt-0.5 h-4 w-4 shrink-0 accent-[var(--color-accent)]"
          />
          <span>
            <strong className="font-semibold text-warn">Sub-par redemption quote.</strong>{" "}
            Recognized backing is below 1:1, so this redemption settles pro-rata at{" "}
            {fmtAmount(instantQuote.usdcOut, 6, 6)} {STABLE_SYMBOL} (slippage-protected minimum). I
            understand and want to submit at this quoted output.
          </span>
        </label>
      ) : null}

      {mode === "queue" && queueSettlementFrozen ? (
        <div role="alert" className="mt-3 rounded-card border border-warn/50 bg-warn/10 p-3 text-[11.5px] leading-relaxed text-ink">
          <strong className="font-semibold text-warn">Queue settlement is currently frozen on-chain.</strong>{" "}
          {reserveLossExitsLocked
            ? "A reserve custody loss or reserve-loss arm is active."
            : "Unresolved past-due loan exposure is active."}{" "}
          New queue requests remain non-cancellable and cannot settle until this condition clears.
        </div>
      ) : null}

      {mode === "queue" && previewAssets !== undefined && parsed !== null && parsed > 0n ? (
        <p className="mt-2 font-mono text-[11px] text-ink-faint">
          Worth today ≈ <span className="text-ink-muted">{fmtAmount(previewAssets, 18, 4)} USDfr</span>{" "}
          (fills at settlement rate)
          {exitImpaired && depositPriceAssets !== undefined && depositPriceAssets > previewAssets ? (
            <>
              <span className="text-ink-muted">
               , marked down from {fmtAmount(depositPriceAssets, 18, 4)} using the current
                conservative default mark. The mark and settlement price can change before
                this request fills.
              </span>
            </>
          ) : null}
        </p>
      ) : null}

      {mode === "queue" && exitImpaired && depositPriceAssets !== undefined && previewAssets !== undefined &&
      depositPriceAssets > previewAssets ? (
        <p className="mt-2 text-[11px] leading-relaxed text-ink-faint">
          Actual recovery may be higher or lower.{" "}
          {IS_TESTNET
            ? "A separately funded testnet top-up tool may be exercised, but any payment is discretionary and not included above."
            : "Mainnet has no recovery top-up distributor; no additional payment or airdrop is promised or included above."}
        </p>
      ) : null}

      {mode === "queue" ? (
        <label className="mt-4 flex cursor-pointer items-start gap-2.5 rounded-card border border-warn/40 bg-warn/5 p-3 text-[11px] leading-relaxed text-ink-muted">
          <input
            type="checkbox"
            checked={queueAcknowledged}
            onChange={(event) =>
              setAcknowledgedCooldown(
                event.target.checked && redeemCooldown !== undefined ? redeemCooldown : null,
              )
            }
            disabled={!chainOk || writeBusy || redeemCooldown === undefined}
            className="mt-0.5 h-4 w-4 shrink-0 accent-[var(--color-accent)]"
          />
          <span>
            I understand this request cannot be cancelled or withdrawn, cannot settle before
            the live minimum hold shown above, and may wait longer for FIFO order and liquidity.
          </span>
        </label>
      ) : null}

      <ActionButton
        label={
          mode === "instant"
            ? `Redeem to ${STABLE_SYMBOL}`
            : needsApproval
              ? "Approve sUSDfr"
              : "Request redemption"
        }
        busyLabel={preparingInstant ? "Preparing…" : busyLabelFor(flow.status)}
        busy={writeBusy}
        disabled={!canSubmit}
        onClick={act}
      />
      <StatusLine status={flow.status} />

      <div className="mt-auto border-t border-line pt-4">
        <p className="text-[11px] font-semibold uppercase tracking-[0.16em] text-ink-faint">
          Your queue positions
        </p>
        {totalRequests !== undefined && totalRequests > REQUEST_SCAN_WINDOW ? (
          <p className="mt-1 text-[11px] text-warn">
            Showing the latest {REQUEST_SCAN_WINDOW.toString()} of {totalRequests.toString()} queue
            requests. Enter an older request ID below to recover and claim it.
          </p>
        ) : null}
        <label className="mt-3 block">
          <span className="text-[11px] font-semibold uppercase tracking-[0.12em] text-ink-faint">
            Find any request by ID
          </span>
          <input
            value={lookupIdText}
            onChange={(event) => setLookupIdText(event.target.value.trim())}
            inputMode="numeric"
            pattern="[0-9]*"
            placeholder="e.g. 42"
            className="op-field mt-1.5 w-full px-3 py-2 font-mono text-[16px] text-ink placeholder:text-ink-faint"
          />
        </label>
        {lookupIsOutOfRange ? (
          <p className="mt-1 text-[11px] text-warn">That request ID does not exist yet.</p>
        ) : lookupBelongsToAnotherWallet ? (
          <p className="mt-1 text-[11px] text-warn">
            That request belongs to a different wallet and cannot be claimed here.
          </p>
        ) : null}
        {myRequests.length === 0 ? (
          <p className="mt-2 text-[13px] text-ink-faint">
            No positions found in the latest scan or by request ID.
          </p>
        ) : (
          <>
            {activeRequests.length > 0 ? (
              <ul className="mt-2 space-y-2">
                {activeRequests.map((r) => {
                  // Eligibility arithmetic lives in lib/queue.ts so it is pinned by value
                  // tests rather than by a substring match over this component.
                  const untilEligible = secondsUntilEligible(r.requestedAt, redeemCooldown, now);
                  const eligibilityCountdown =
                    untilEligible !== null ? fmtCountdown(untilEligible) : null;
                  return (
                    <li
                      key={r.id.toString()}
                      className="flex items-center justify-between gap-3 rounded-card border border-line bg-surface px-3.5 py-2.5"
                    >
                      <div className="font-mono text-[11px] leading-relaxed text-ink-muted">
                        <span className="text-ink-faint">#{r.id.toString()}</span>{" "}
                        {r.sharesRemaining > 0n ? (
                          <>
                            queued {fmtAmount(r.sharesRemaining, SHARE_DECIMALS, 4)} sUSDfr
                            {" "}(epoch {r.epochRequested.toString()})
                          </>
                        ) : (
                          <>filled</>
                        )}
                        {r.sharesRemaining > 0n ? (
                          <span className="block text-ink-faint">
                            {eligibilityCountdown === null
                              ? "Loading cooldown eligibility…"
                              : eligibilityCountdown === "now"
                                ? "Cooldown complete · awaiting FIFO settlement and liquidity"
                                : `First eligible in ${eligibilityCountdown} · settlement may be later`}
                          </span>
                        ) : null}
                        {r.assetsClaimable > 0n ? (
                          <span className="ml-1 text-accent">
                            · {fmtAmount(r.assetsClaimable, 18)} USDfr claimable
                          </span>
                        ) : null}
                      </div>
                      {r.assetsClaimable > 0n ? (
                        <button
                          type="button"
                          onClick={() =>
                            claimFlow.run({
                              address: queue, abi: QUEUE_ABI, functionName: "claim", args: [r.id],
                            })
                          }
                          disabled={!chainOk || claimFlow.busy}
                          className="min-h-9 shrink-0 rounded-pill bg-accent px-3.5 py-2 text-[12px] font-medium text-raised transition-transform hover:scale-[1.02] disabled:opacity-50"
                        >
                          Claim
                        </button>
                      ) : null}
                    </li>
                  );
                })}
              </ul>
            ) : (
              <p className="mt-2 text-[13px] text-ink-faint">
                No active or claimable positions in the latest scan.
              </p>
            )}
            {completedRequests.length > 0 ? (
              <details className="mt-3 rounded-card border border-line bg-surface px-3.5 py-2">
                <summary className="cursor-pointer font-mono text-[11px] text-ink-faint hover:text-ink-muted">
                  Completed requests ({completedRequests.length})
                </summary>
                <ul className="mt-2 space-y-1.5 border-t border-line pt-2">
                  {completedRequests.map((r) => (
                    <li key={r.id.toString()} className="font-mono text-[11px] text-ink-faint">
                      #{r.id.toString()} · filled &amp; claimed (epoch {r.epochRequested.toString()})
                    </li>
                  ))}
                </ul>
              </details>
            ) : null}
          </>
        )}
        <StatusLine status={claimFlow.status} />
      </div>
    </div>
  );
}
