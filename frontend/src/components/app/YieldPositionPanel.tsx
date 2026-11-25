"use client";

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {zeroAddress, type Address} from "viem";
import {useAccount, useBlockNumber, usePublicClient, useReadContracts} from "wagmi";
import {
  CONTRACTS,
  PROTOCOL_DEPLOYMENT_BLOCK,
  SUPPORTS_VAULT_FEE_ACCOUNTING,
} from "@/config/contracts";
import {
  ERC20_ABI,
  SHARE_DECIMALS,
  VAULT_ABI,
  VAULT_HISTORY_ABI,
} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";
import {
  BROWSER_HISTORY_CONCURRENCY,
  DEFAULT_BLOCK_CHUNK,
  nextUnreadBlockRange,
  readBlockRangeChunked,
} from "@/lib/logs";
import {parseTransparencyHistoryResponse} from "@/lib/transparencyHistory";
import {
  applyShareBasisEvents,
  formatBps,
  INITIAL_SHARE_BASIS_STATE,
  walletDirectDepositBasis,
  type ShareBasisEvent,
  type ShareBasisState,
} from "@/lib/yield";
import {useBookEconomics} from "@/components/app/useBookEconomics";
import {ACCOUNT_POLL} from "@/lib/polling";

type ProtocolHistoryState =
  | {phase: "loading"}
  | {phase: "ready"; recordedIncome: bigint; observedSeconds: bigint}
  | {phase: "error"};

type WalletHistoryCursor = {
  /** Confirmed state up to `finalizedBlock` (never re-scanned). */
  finalizedState: ShareBasisState;
  finalizedBlock: bigint | null;
  basisState: ShareBasisState;
  lastScannedBlock: bigint;
};

type WalletHistoryState =
  | {phase: "idle"}
  | {phase: "loading"}
  | {phase: "ready"; value: ShareBasisState; lastScannedBlock: bigint}
  | {phase: "error"};

const POLL = ACCOUNT_POLL;
/** Keep a 12-block unfinalized tail re-readable across polls so a 1-block tip reorg cannot
 *  permanently double-apply or drop a wallet's deposit/transfer in the lot-based basis tracker. */
const REORG_TAIL_BLOCKS = 12n;

export function YieldPositionPanel() {
  const {address} = useAccount();
  const publicClient = usePublicClient();
  const {data: blockNumber} = useBlockNumber({query: POLL});
  const [protocolHistory, setProtocolHistory] = useState<ProtocolHistoryState>({phase: "loading"});
  const [walletHistory, setWalletHistory] = useState<WalletHistoryState>({phase: "idle"});
  const historyCursor = useRef<WalletHistoryCursor | null>(null);
  const historyGeneration = useRef(0);
  const pendingHistoryBlock = useRef<bigint | null>(null);
  const incrementalHistoryInFlight = useRef(false);
  const deploymentTimestampCache = useRef<bigint | null>(null);
  const {projectedSeniorIncome, protocolFeeBps} = useBookEconomics();
  const vault = CONTRACTS.sUSDfr;

  const {data} = useReadContracts({
    query: POLL,
    contracts: [
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "totalAssets"},
      {address: CONTRACTS.sUSDfr!, abi: ERC20_ABI, functionName: "totalSupply"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "unvestedYield"},
      // AUDIT R15-03. The WINDOW, not the stream balance, `unvestedYield()` is zero for
      // three distinct reasons and cannot state whether streaming is configured.
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "yieldVestingPeriod"},
      {
        address: CONTRACTS.sUSDfr!,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: address ? [address] : [zeroAddress],
      },
    ],
  });

  const {data: feeData} = useReadContracts({
    query: {enabled: SUPPORTS_VAULT_FEE_ACCOUNTING, ...POLL},
    contracts: [
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "performanceFeeBps"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "managementFeeBps"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "maxManagementFeeBps"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "maxPerformanceFeeBps"},
    ],
  });

  const outstandingAssets = data?.[0]?.result as bigint | undefined;
  const outstandingShares = data?.[1]?.result as bigint | undefined;
  const unvestedIncome = data?.[2]?.result as bigint | undefined;
  const positionShares = data?.[4]?.result as bigint | undefined;
  const yieldVestingPeriod = data?.[3]?.result as bigint | undefined;
  const performanceFeeBps = feeData?.[0]?.result as number | undefined;
  const managementFeeBps = feeData?.[1]?.result as number | undefined;
  const maxManagementFeeBps = feeData?.[2]?.result as number | undefined;
  const maxPerformanceFeeBps = feeData?.[3]?.result as number | undefined;

  const {data: positionAssets} = useReadContracts({
    query: POLL,
    contracts: [
      {
        address: CONTRACTS.sUSDfr!,
        abi: VAULT_ABI,
        functionName: "previewRedeem",
        args: [positionShares ?? 0n],
      },
    ],
  });
  const walletExitAssets = positionAssets?.[0]?.result as bigint | undefined;

  // Protocol-wide cumulative senior income comes from the CDN/server-cached
  // `/api/transparency/history` route instead of scanning deployment-to-tip WaterfallEngine
  // logs in every visitor's browser.
  useEffect(() => {
    if (!publicClient || blockNumber === undefined) return;
    const client = publicClient;
    const controller = new AbortController();

    async function loadProtocolHistory() {
      try {
        const response = await fetch("/api/transparency/history", {
          headers: {accept: "application/json"},
          signal: controller.signal,
        });
        if (!response.ok) throw new Error(`history endpoint returned ${response.status}`);
        const parsed = parseTransparencyHistoryResponse(await response.json());
        if (controller.signal.aborted) return;
        const [startTimestamp, endBlock] = await Promise.all([
          deploymentTimestampCache.current !== null
            ? Promise.resolve(deploymentTimestampCache.current)
            : client.getBlock({blockNumber: PROTOCOL_DEPLOYMENT_BLOCK}).then((b) => {
                deploymentTimestampCache.current = b.timestamp;
                return b.timestamp;
              }),
          client
            .getBlock({blockNumber: parsed.asOfBlock})
            .catch(() => client.getBlock({blockTag: "latest"})),
        ]);
        if (controller.signal.aborted) return;
        const observedSeconds =
          endBlock.timestamp > startTimestamp ? endBlock.timestamp - startTimestamp : 0n;
        setProtocolHistory({
          phase: "ready",
          recordedIncome: parsed.seniorIncome ?? 0n,
          observedSeconds,
        });
      } catch {
        if (controller.signal.aborted) return;
        setProtocolHistory((prev) => (prev.phase === "ready" ? prev : {phase: "error"}));
      }
    }

    void loadProtocolHistory();
    return () => {
      controller.abort();
    };
  }, [blockNumber, publicClient]);

  const readWalletBasisEvents = useCallback(
    async (fromBlock: bigint, toBlock: bigint): Promise<ShareBasisEvent[]> => {
      if (!publicClient || !vault || !address) {
        throw new Error("Wallet history reader is unavailable.");
      }
      const vaultCommon = {
        address: vault,
        abi: VAULT_HISTORY_ABI,
      } as const;
      const [depositLogs, incomingLogs, outgoingLogs] = await Promise.all([
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            publicClient.getContractEvents({
              ...vaultCommon,
              eventName: "Deposit",
              args: {owner: address},
              fromBlock: chunkFrom,
              toBlock: chunkTo,
            }),
          DEFAULT_BLOCK_CHUNK,
          BROWSER_HISTORY_CONCURRENCY,
        ),
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            publicClient.getContractEvents({
              ...vaultCommon,
              eventName: "Transfer",
              args: {to: address},
              fromBlock: chunkFrom,
              toBlock: chunkTo,
            }),
          DEFAULT_BLOCK_CHUNK,
          BROWSER_HISTORY_CONCURRENCY,
        ),
        readBlockRangeChunked(
          fromBlock,
          toBlock,
          (chunkFrom, chunkTo) =>
            publicClient.getContractEvents({
              ...vaultCommon,
              eventName: "Transfer",
              args: {from: address},
              fromBlock: chunkFrom,
              toBlock: chunkTo,
            }),
          DEFAULT_BLOCK_CHUNK,
          BROWSER_HISTORY_CONCURRENCY,
        ),
      ]);

      const events: ShareBasisEvent[] = [];
      // Count minted shares paired with a Deposit in each transaction so unmatched zero-address
      // mints (e.g. fee shares minted directly without Deposit) are treated as external transfers.
      const depositMintCounts = new Map<string, number>();
      for (const log of depositLogs) {
        if (log.removed || log.blockNumber === null || log.logIndex === null) continue;
        const assets = log.args.assets ?? 0n;
        const shares = log.args.shares ?? 0n;
        events.push({
          kind: "deposit",
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          assets,
          shares,
        });
        const key = `${log.transactionHash ?? ""}:${shares.toString()}`;
        depositMintCounts.set(key, (depositMintCounts.get(key) ?? 0) + 1);
      }

      const ownerLower = address.toLowerCase();
      const zeroLower = zeroAddress.toLowerCase();
      for (const log of incomingLogs) {
        if (log.removed || log.blockNumber === null || log.logIndex === null) continue;
        const from = (log.args.from as Address | undefined)?.toLowerCase();
        const to = (log.args.to as Address | undefined)?.toLowerCase();
        const shares = log.args.value ?? 0n;
        if (!from || from === to) continue; // ignore self-transfers
        if (from === zeroLower) {
          const key = `${log.transactionHash ?? ""}:${shares.toString()}`;
          const remaining = depositMintCounts.get(key) ?? 0;
          if (remaining > 0) {
            depositMintCounts.set(key, remaining - 1);
            continue;
          }
        }
        events.push({
          kind: "transfer_in",
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          shares,
        });
      }

      for (const log of outgoingLogs) {
        if (log.removed || log.blockNumber === null || log.logIndex === null) continue;
        const to = (log.args.to as Address | undefined)?.toLowerCase();
        const shares = log.args.value ?? 0n;
        if (to === ownerLower) continue; // ignore self-transfers
        events.push({
          kind: "transfer_out",
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          shares,
        });
      }

      return events;
    },
    [address, publicClient, vault],
  );

  const runInitialHistory = useCallback(
    async (generation: number) => {
      if (!address) {
        setWalletHistory({phase: "idle"});
        return;
      }
      if (!publicClient || !vault) return;
      incrementalHistoryInFlight.current = true;
      setWalletHistory({phase: "loading"});
      try {
        const latestBlockNumber = await publicClient.getBlockNumber();
        if (latestBlockNumber < PROTOCOL_DEPLOYMENT_BLOCK) {
          if (generation === historyGeneration.current) {
            setWalletHistory({phase: "error"});
          }
          return;
        }

        const events = await readWalletBasisEvents(PROTOCOL_DEPLOYMENT_BLOCK, latestBlockNumber);
        if (generation !== historyGeneration.current) return;

        const safeCutoff =
          latestBlockNumber > PROTOCOL_DEPLOYMENT_BLOCK + REORG_TAIL_BLOCKS
            ? latestBlockNumber - REORG_TAIL_BLOCKS
            : null;
        const finalizedEvents =
          safeCutoff !== null ? events.filter((e) => e.blockNumber <= safeCutoff) : [];
        const tailEvents =
          safeCutoff !== null ? events.filter((e) => e.blockNumber > safeCutoff) : events;
        const finalizedState = applyShareBasisEvents(INITIAL_SHARE_BASIS_STATE, finalizedEvents);
        const basisState = applyShareBasisEvents(finalizedState, tailEvents);
        const cursor: WalletHistoryCursor = {
          finalizedState,
          finalizedBlock: safeCutoff,
          basisState,
          lastScannedBlock: latestBlockNumber,
        };
        historyCursor.current = cursor;
        if (
          pendingHistoryBlock.current === null ||
          latestBlockNumber > pendingHistoryBlock.current
        ) {
          pendingHistoryBlock.current = latestBlockNumber;
        }
        setWalletHistory({phase: "ready", value: basisState, lastScannedBlock: latestBlockNumber});
      } catch {
        if (generation === historyGeneration.current) {
          setWalletHistory({phase: "error"});
        }
      } finally {
        if (generation === historyGeneration.current) {
          incrementalHistoryInFlight.current = false;
        }
      }
    },
    [address, publicClient, readWalletBasisEvents, vault],
  );

  // The deployment-to-tip sweep runs only for a connected wallet when the wallet/client context
  // changes. Polling below advances this cursor over unseen blocks only (re-reading only the
  // bounded unfinalized tail so 1-block tip reorgs cannot permanently desync lot-based basis).
  useEffect(() => {
    const generation = ++historyGeneration.current;
    historyCursor.current = null;
    pendingHistoryBlock.current = null;
    incrementalHistoryInFlight.current = false;

    void runInitialHistory(generation);
    return () => {
      if (generation === historyGeneration.current) {
        historyGeneration.current += 1;
      }
    };
  }, [address, publicClient, runInitialHistory, vault]);

  useEffect(() => {
    if (!publicClient || !vault || !address || blockNumber === undefined) return;
    if (
      pendingHistoryBlock.current === null ||
      blockNumber > pendingHistoryBlock.current
    ) {
      pendingHistoryBlock.current = blockNumber;
    }
    if (incrementalHistoryInFlight.current) return;

    const generation = historyGeneration.current;
    if (!historyCursor.current) {
      // Retry initial load after a transient failure on mount.
      void runInitialHistory(generation);
      return;
    }

    incrementalHistoryInFlight.current = true;

    async function advanceHistory() {
      try {
        while (generation === historyGeneration.current) {
          const cursor = historyCursor.current;
          const latestBlock = pendingHistoryBlock.current;
          if (!cursor || latestBlock === null) return;
          const range = nextUnreadBlockRange(cursor.lastScannedBlock, latestBlock);
          if (!range) return;
          const tailFrom =
            cursor.finalizedBlock !== null ? cursor.finalizedBlock + 1n : PROTOCOL_DEPLOYMENT_BLOCK;
          const events = await readWalletBasisEvents(tailFrom, range.toBlock);
          if (
            generation !== historyGeneration.current ||
            historyCursor.current !== cursor
          ) {
            return;
          }

          const safeCutoff =
            range.toBlock > PROTOCOL_DEPLOYMENT_BLOCK + REORG_TAIL_BLOCKS
              ? range.toBlock - REORG_TAIL_BLOCKS
              : cursor.finalizedBlock;
          const nextFinalizedBlock =
            safeCutoff !== null &&
            (cursor.finalizedBlock === null || safeCutoff > cursor.finalizedBlock)
              ? safeCutoff
              : cursor.finalizedBlock;
          const newlyFinalized =
            nextFinalizedBlock !== null
              ? events.filter((e) => e.blockNumber <= nextFinalizedBlock)
              : [];
          const tailEvents =
            nextFinalizedBlock !== null
              ? events.filter((e) => e.blockNumber > nextFinalizedBlock)
              : events;
          const nextFinalizedState = applyShareBasisEvents(cursor.finalizedState, newlyFinalized);
          const nextState = applyShareBasisEvents(nextFinalizedState, tailEvents);
          const next: WalletHistoryCursor = {
            finalizedState: nextFinalizedState,
            finalizedBlock: nextFinalizedBlock,
            basisState: nextState,
            lastScannedBlock: range.toBlock,
          };
          historyCursor.current = next;
          setWalletHistory({phase: "ready", value: nextState, lastScannedBlock: range.toBlock});
        }
      } catch {
        // Keep last-good wallet basis state across transient incremental poll failures.
      } finally {
        if (generation === historyGeneration.current) {
          incrementalHistoryInFlight.current = false;
        }
      }
    }

    void advanceHistory();
  }, [address, blockNumber, publicClient, readWalletBasisEvents, runInitialHistory, vault]);

  const metrics = useMemo(() => {
    const basis =
      walletHistory.phase !== "ready" || positionShares === undefined
        ? null
        : walletDirectDepositBasis(walletHistory.value, positionShares);
    return {
      basis,
      positionPnl:
        basis !== null && walletExitAssets !== undefined ? walletExitAssets - basis : null,
      projectedPositionIncome:
        address !== undefined &&
        projectedSeniorIncome !== null &&
        positionShares !== undefined &&
        outstandingShares !== undefined &&
        outstandingShares > 0n
          ? (projectedSeniorIncome * positionShares) / outstandingShares
          : null,
      projectedYieldBps:
        projectedSeniorIncome !== null &&
        outstandingAssets !== undefined &&
        outstandingAssets > 0n
          ? (projectedSeniorIncome * 10_000n) / outstandingAssets
          : null,
    };
  }, [
    address,
    outstandingAssets,
    outstandingShares,
    positionShares,
    projectedSeniorIncome,
    walletExitAssets,
    walletHistory,
  ]);

  const observedDays =
    protocolHistory.phase === "ready"
      ? Number(protocolHistory.observedSeconds) / 86_400
      : null;

  return (
    <section className="yield-position-instrument mt-8 overflow-hidden rounded-card bg-navy-deepest text-on-navy shadow-[0_24px_55px_-28px_rgba(15,26,46,0.7)]" data-viewport-replay="" data-viewport-reveal="">
      <div className="grid gap-px bg-white/10 lg:grid-cols-[1.05fr_1fr]">
        <div className="yield-position-card yield-position-card--income bg-navy-deepest p-7 sm:p-8">
          {/* The panel's heading, and the h2 that keeps /app from stepping
              h1 -> h3 at the first write card. Styling is unchanged. */}
          <h2 className="text-[12px] font-semibold uppercase tracking-[0.18em] text-on-navy/65">
            Projected position income
          </h2>
          {/* A bare em dash at display scale reads as a redaction bar, not as
              an absent value. When there is no figure yet, the slot says why
              in words instead of standing there as a mark. */}
          {metrics.projectedPositionIncome !== null ? (
            <div className="mt-3 flex flex-wrap items-end gap-x-4 gap-y-2">
              <p
                data-figure
                className="display text-[clamp(2rem,4vw,3.375rem)] leading-none text-on-navy"
              >
                {fmtAmount(metrics.projectedPositionIncome, 18, 4)}
              </p>
              <p className="pb-1 text-[11px] font-semibold tracking-[0.03em] text-on-navy/70">
                USDfr / year
              </p>
            </div>
          ) : (
            <p className="mt-4 max-w-md text-[14px] leading-relaxed text-on-navy/70">
              Connect a wallet holding sUSDfr to see your projected share of the
              book&apos;s annual interest, in USDfr per year.
            </p>
          )}
          <p className="mt-4 max-w-xl text-[13px] leading-relaxed text-on-navy/65">
            Your pro-rata share of the current performing book&apos;s contractual annual
            interest after the Waterfall interest fee but before the global-HWM
            performance fee and time-based management fee. It changes with your
            position, repayments, delinquencies, defaults, recoveries, and the
            composition of the book; it is indicative, not guaranteed.
          </p>
          {observedDays !== null && observedDays < 30 ? (
            <p className="mt-3 text-[13px] leading-relaxed text-warn">
              Short history: only {observedDays < 1 ? "<1" : Math.floor(observedDays)} day
              {observedDays >= 2 ? "s" : ""} observed, so historical income covers only a
              limited window.
            </p>
          ) : null}

          <div className="mt-7 grid gap-4 sm:grid-cols-3">
            <DarkMetric
              label="Historical income"
              value={
                protocolHistory.phase === "ready"
                  ? `${fmtAmount(protocolHistory.recordedIncome, 18, 4)} USDfr`
                  : "–"
              }
              note="after interest fee; before vault fees"
            />
            <DarkMetric
              label="History observed"
              value={
                observedDays !== null
                  ? `${observedDays < 1 ? "<1" : Math.floor(observedDays)} day${observedDays >= 2 ? "s" : ""}`
                  : "–"
              }
              note="income measurement window"
            />
            {/* AUDIT R15-03. Decide on the WINDOW, not the stream balance: `unvestedYield()`
                returns zero when no window is set, when no stream is live, AND when a stream
                has run to completion, so it cannot state whether streaming is configured.
                ADR-0023 streaming is off at launch (zero window). */}
            {yieldVestingPeriod === undefined ? (
              <DarkMetric label="Yield recognition" value="–" note="reading vesting window" />
            ) : yieldVestingPeriod === 0n ? (
              <DarkMetric label="Yield recognition" value="Immediate" note="no vesting window set" />
            ) : (
              <DarkMetric
                label="Vesting now"
                value={
                  unvestedIncome !== undefined ? `${fmtAmount(unvestedIncome, 18, 4)} USDfr` : "–"
                }
                note="realized, not yet in NAV"
              />
            )}
          </div>
        </div>

        <div className="yield-position-card yield-position-card--wallet bg-navy-deep p-7 sm:p-8">
          <h2 className="text-[12.5px] font-semibold tracking-[0.035em] text-on-navy/65">
            Your sUSDfr position
          </h2>
          {address ? (
            <>
              <div className="mt-5 grid grid-cols-1 gap-x-6 gap-y-5 min-[420px]:grid-cols-2">
                <DarkMetric
                  label="Position"
                  value={
                    positionShares !== undefined
                      ? `${fmtAmount(positionShares, SHARE_DECIMALS, 4)} sUSDfr`
                      : "–"
                  }
                  note={
                    walletExitAssets !== undefined
                      ? `${fmtAmount(walletExitAssets, 18, 4)} USDfr at current exit NAV`
                      : "wallet balance"
                  }
                />
                <DarkMetric
                  label="Current expected yield"
                  value={
                    metrics.projectedYieldBps !== null
                      ? formatBps(metrics.projectedYieldBps)
                      : "–"
                  }
                  note={
                    SUPPORTS_VAULT_FEE_ACCOUNTING
                      ? "after interest fee; before vault fees"
                      : "after interest fee; legacy vault has no ADR-0031 fees"
                  }
                />
                <DarkMetric
                  label="Projected position income"
                  value={
                    metrics.projectedPositionIncome !== null
                      ? `${fmtAmount(metrics.projectedPositionIncome, 18, 4)} USDfr/yr`
                      : "–"
                  }
                  note={
                    protocolFeeBps !== undefined
                      ? SUPPORTS_VAULT_FEE_ACCOUNTING
                        ? `after ${formatBps(protocolFeeBps)} interest fee; before vault fees`
                        : `after ${formatBps(protocolFeeBps)} interest fee; legacy vault has no ADR-0031 fees`
                      : SUPPORTS_VAULT_FEE_ACCOUNTING
                        ? "after interest fee; before vault fees"
                        : "after interest fee; legacy vault has no ADR-0031 fees"
                  }
                />
                <DarkMetric
                  label="Historical position gain"
                  value={
                    walletHistory.phase === "loading"
                      ? "Loading…"
                      : metrics?.positionPnl !== null &&
                          metrics?.positionPnl !== undefined
                        ? `${metrics.positionPnl < 0n ? "−" : "+"}${fmtAmount(
                            metrics.positionPnl < 0n
                              ? -metrics.positionPnl
                              : metrics.positionPnl,
                            18,
                            4,
                          )} USDfr`
                        : walletHistory.phase === "ready" &&
                            blockNumber !== undefined &&
                            walletHistory.lastScannedBlock < blockNumber
                          ? "Updating…"
                          : "Unavailable"
                  }
                  note={
                    walletHistory.phase === "loading"
                      ? "reading direct-deposit history"
                      : walletHistory.phase === "ready" &&
                          metrics?.positionPnl === null &&
                          blockNumber !== undefined &&
                          walletHistory.lastScannedBlock < blockNumber
                        ? "syncing latest block"
                        : walletHistory.phase === "ready" &&
                            walletHistory.value.hasExternalShareTransfer
                          ? "incoming shares have no on-chain cost basis"
                          : SUPPORTS_VAULT_FEE_ACCOUNTING
                            ? "fee-net exit value vs direct-deposit basis"
                            : "legacy exit value vs direct-deposit basis"
                  }
                />
                <DarkMetric
                  label="Performance fee"
                  value={
                    !SUPPORTS_VAULT_FEE_ACCOUNTING
                      ? "Not deployed"
                      : performanceFeeBps !== undefined
                      ? formatBps(BigInt(performanceFeeBps))
                      : "–"
                  }
                  note={
                    !SUPPORTS_VAULT_FEE_ACCOUNTING
                      ? "legacy Sepolia deployment"
                      : maxPerformanceFeeBps !== undefined
                      ? `prospective · conservative global HWM · ${formatBps(
                          BigInt(maxPerformanceFeeBps),
                        )} cap`
                      : "prospective · conservative global HWM"
                  }
                />
                <DarkMetric
                  label="Management fee"
                  value={
                    !SUPPORTS_VAULT_FEE_ACCOUNTING
                      ? "Not deployed"
                      : managementFeeBps !== undefined
                      ? formatBps(BigInt(managementFeeBps))
                      : "–"
                  }
                  note={
                    !SUPPORTS_VAULT_FEE_ACCOUNTING
                      ? "legacy Sepolia deployment"
                      : maxManagementFeeBps !== undefined
                      ? `prospective annual · ${formatBps(BigInt(maxManagementFeeBps))} cap`
                      : "prospective · capped"
                  }
                />
              </div>
              <p className="mt-6 border-t border-white/10 pt-4 text-[13px] leading-relaxed text-on-navy/70">
                Position gain is not lifetime tax P&amp;L: it covers shares still in this
                wallet and uses proportional direct-deposit cost basis. Queue positions,
                exited shares, and externally transferred-in shares are excluded.
                {SUPPORTS_VAULT_FEE_ACCOUNTING
                  ? " Current exit value simulates fees due now. Projected book income is contractual after the Waterfall interest fee but before the global-HWM performance fee, annual management fee, payment timing, delinquencies, defaults, recoveries, and book changes; it is not guaranteed. The HWM is global, not your personal entry basis."
                  : " This legacy Sepolia deployment predates the global-HWM performance and management fee implementation; those selectors and fee claims are disabled in this build."}
                {" "}No income is withheld for DSRA funding.
              </p>
            </>
          ) : (
            <p className="mt-5 text-[13px] leading-relaxed text-on-navy/60">
              Connect a wallet to see sUSDfr held, current USDfr value, indicative annual
              income, and gain on the wallet&apos;s directly deposited position.
            </p>
          )}
        </div>
      </div>
      {protocolHistory.phase === "error" || walletHistory.phase === "error" ? (
        <p className="border-t border-warn/30 bg-warn/10 px-7 py-3 text-[13px] text-on-navy/65">
          Historical event reads are unavailable from the configured RPC. Historical income,
          realized yield, and direct-deposit gain are unavailable; projected position income
          and live balances remain direct contract reads.
        </p>
      ) : null}
    </section>
  );
}

function DarkMetric({label, value, note}: {label: string; value: string; note: string}) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-on-navy/65">
        {label}
      </p>
      {/* Carries words ("Immediate") as well as figures, so this is the body face with
          tabular numerals rather than mono. */}
      <p className="tnum mt-1 [overflow-wrap:anywhere] text-[15px] font-medium text-on-navy">{value}</p>
      <p className="mt-1 text-[11px] leading-snug text-on-navy/65">{note}</p>
    </div>
  );
}
