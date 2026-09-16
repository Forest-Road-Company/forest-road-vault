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
  WATERFALL_HISTORY_ABI,
} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";
import {nextUnreadBlockRange, readBlockRangeChunked} from "@/lib/logs";
import {formatBps, remainingDirectDepositBasis} from "@/lib/yield";
import {useBookEconomics} from "@/components/app/useBookEconomics";

type History = {
  recordedIncome: bigint;
  observedSeconds: bigint;
  directDepositAssets: bigint;
  directDepositShares: bigint;
  hasExternalShareTransfer: boolean;
};

type HistoryDelta = Omit<History, "observedSeconds">;

type HistoryCursor = HistoryDelta & {
  startTimestamp: bigint;
  lastTimestamp: bigint;
  lastScannedBlock: bigint;
};

type HistoryState =
  | {phase: "loading"}
  | {phase: "ready"; value: History}
  | {phase: "error"};

const POLL = {refetchInterval: 60_000} as const;

function cursorValue(cursor: HistoryCursor): History {
  return {
    recordedIncome: cursor.recordedIncome,
    observedSeconds:
      cursor.lastTimestamp > cursor.startTimestamp
        ? cursor.lastTimestamp - cursor.startTimestamp
        : 0n,
    directDepositAssets: cursor.directDepositAssets,
    directDepositShares: cursor.directDepositShares,
    hasExternalShareTransfer: cursor.hasExternalShareTransfer,
  };
}

export function YieldPositionPanel() {
  const {address} = useAccount();
  const publicClient = usePublicClient();
  const {data: blockNumber} = useBlockNumber({query: POLL});
  const [history, setHistory] = useState<HistoryState>({phase: "loading"});
  const historyCursor = useRef<HistoryCursor | null>(null);
  const historyGeneration = useRef(0);
  const pendingHistoryBlock = useRef<bigint | null>(null);
  const incrementalHistoryInFlight = useRef(false);
  const {projectedSeniorIncome, protocolFeeBps} = useBookEconomics();
  const vault = CONTRACTS.sUSDfr;
  const waterfall = CONTRACTS.WaterfallEngine;

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

  const readHistoryDelta = useCallback(
    async (fromBlock: bigint, toBlock: bigint): Promise<HistoryDelta> => {
      if (!publicClient || !vault || !waterfall) {
        throw new Error("History reader is unavailable.");
      }
      const vaultCommon = {
        address: vault,
        abi: VAULT_HISTORY_ABI,
      } as const;
      const [incomeLogs, depositLogs, incomingLogs] = await Promise.all([
        readBlockRangeChunked(fromBlock, toBlock, (chunkFrom, chunkTo) =>
          publicClient.getContractEvents({
            address: waterfall,
            abi: WATERFALL_HISTORY_ABI,
            eventName: "Distributed",
            fromBlock: chunkFrom,
            toBlock: chunkTo,
          }),
        ),
        address
          ? readBlockRangeChunked(fromBlock, toBlock, (chunkFrom, chunkTo) =>
              publicClient.getContractEvents({
                ...vaultCommon,
                eventName: "Deposit",
                args: {owner: address},
                fromBlock: chunkFrom,
                toBlock: chunkTo,
              }),
            )
          : Promise.resolve([]),
        address
          ? readBlockRangeChunked(fromBlock, toBlock, (chunkFrom, chunkTo) =>
              publicClient.getContractEvents({
                ...vaultCommon,
                eventName: "Transfer",
                args: {to: address},
                fromBlock: chunkFrom,
                toBlock: chunkTo,
              }),
            )
          : Promise.resolve([]),
      ]);

      return {
        recordedIncome: incomeLogs.reduce(
          (sum, log) => sum + (log.args.toVault ?? 0n),
          0n,
        ),
        directDepositAssets: depositLogs.reduce(
          (sum, log) => sum + (log.args.assets ?? 0n),
          0n,
        ),
        directDepositShares: depositLogs.reduce(
          (sum, log) => sum + (log.args.shares ?? 0n),
          0n,
        ),
        hasExternalShareTransfer: incomingLogs.some(
          (log) =>
            (log.args.from as Address | undefined)?.toLowerCase() !==
            zeroAddress.toLowerCase(),
        ),
      };
    },
    [address, publicClient, vault, waterfall],
  );

  // The expensive deployment-to-tip sweep runs only when the wallet/client context
  // changes. Minute polling below advances this cursor over unseen blocks only.
  useEffect(() => {
    const generation = ++historyGeneration.current;
    historyCursor.current = null;
    pendingHistoryBlock.current = null;
    incrementalHistoryInFlight.current = false;

    async function loadInitialHistory() {
      if (!publicClient || !vault || !waterfall) return;
      setHistory({phase: "loading"});
      try {
        const latestBlockNumber = await publicClient.getBlockNumber();
        if (latestBlockNumber < PROTOCOL_DEPLOYMENT_BLOCK) {
          if (generation === historyGeneration.current) {
            setHistory({phase: "error"});
          }
          return;
        }

        const [startBlock, endBlock, delta] = await Promise.all([
          publicClient.getBlock({blockNumber: PROTOCOL_DEPLOYMENT_BLOCK}),
          publicClient.getBlock({blockNumber: latestBlockNumber}),
          readHistoryDelta(PROTOCOL_DEPLOYMENT_BLOCK, latestBlockNumber),
        ]);
        if (generation !== historyGeneration.current) return;

        const cursor: HistoryCursor = {
          ...delta,
          startTimestamp: startBlock.timestamp,
          lastTimestamp: endBlock.timestamp,
          lastScannedBlock: latestBlockNumber,
        };
        historyCursor.current = cursor;
        pendingHistoryBlock.current = latestBlockNumber;
        setHistory({phase: "ready", value: cursorValue(cursor)});
      } catch {
        if (generation === historyGeneration.current) {
          setHistory({phase: "error"});
        }
      }
    }

    void loadInitialHistory();
    return () => {
      if (generation === historyGeneration.current) {
        historyGeneration.current += 1;
      }
    };
  }, [publicClient, readHistoryDelta, vault, waterfall]);

  useEffect(() => {
    if (!publicClient || !vault || !waterfall || blockNumber === undefined) return;
    if (
      pendingHistoryBlock.current === null ||
      blockNumber > pendingHistoryBlock.current
    ) {
      pendingHistoryBlock.current = blockNumber;
    }
    if (!historyCursor.current || incrementalHistoryInFlight.current) return;

    const client = publicClient;
    const generation = historyGeneration.current;
    incrementalHistoryInFlight.current = true;

    async function advanceHistory() {
      try {
        while (generation === historyGeneration.current) {
          const cursor = historyCursor.current;
          const latestBlock = pendingHistoryBlock.current;
          if (!cursor || latestBlock === null) return;
          const range = nextUnreadBlockRange(cursor.lastScannedBlock, latestBlock);
          if (!range) return;
          const [endBlock, delta] = await Promise.all([
            client.getBlock({blockNumber: range.toBlock}),
            readHistoryDelta(range.fromBlock, range.toBlock),
          ]);
          if (
            generation !== historyGeneration.current ||
            historyCursor.current !== cursor
          ) {
            return;
          }

          const next: HistoryCursor = {
            recordedIncome: cursor.recordedIncome + delta.recordedIncome,
            directDepositAssets:
              cursor.directDepositAssets + delta.directDepositAssets,
            directDepositShares:
              cursor.directDepositShares + delta.directDepositShares,
            hasExternalShareTransfer:
              cursor.hasExternalShareTransfer || delta.hasExternalShareTransfer,
            startTimestamp: cursor.startTimestamp,
            lastTimestamp: endBlock.timestamp,
            lastScannedBlock: range.toBlock,
          };
          historyCursor.current = next;
          setHistory({phase: "ready", value: cursorValue(next)});
        }
      } catch {
        if (generation === historyGeneration.current) {
          setHistory({phase: "error"});
        }
      } finally {
        if (generation === historyGeneration.current) {
          incrementalHistoryInFlight.current = false;
        }
      }
    }

    void advanceHistory();
  }, [blockNumber, publicClient, readHistoryDelta, vault, waterfall]);

  const metrics = useMemo(() => {
    const basis =
      history.phase !== "ready" ||
      history.value.hasExternalShareTransfer ||
      positionShares === undefined
        ? null
        : remainingDirectDepositBasis(
            history.value.directDepositAssets,
            history.value.directDepositShares,
            positionShares,
          );
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
    history,
    outstandingAssets,
    outstandingShares,
    positionShares,
    projectedSeniorIncome,
    walletExitAssets,
  ]);

  const observedDays =
    history.phase === "ready"
      ? Number(history.value.observedSeconds) / 86_400
      : null;

  return (
    <section className="mt-8 overflow-hidden rounded-card bg-navy-deepest text-on-navy shadow-[0_24px_55px_-28px_rgba(15,26,46,0.7)]">
      <div className="grid gap-px bg-white/10 lg:grid-cols-[1.05fr_1fr]">
        <div className="bg-navy-deepest p-7 sm:p-8">
          {/* The panel's heading, and the h2 that keeps /app from stepping
              h1 -> h3 at the first write card. Styling is unchanged. */}
          <h2 className="text-[10.5px] font-semibold uppercase tracking-[0.2em] text-on-navy/55">
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
              <p className="pb-1 text-[11px] font-semibold tracking-[0.03em] text-on-navy/50">
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
            <p className="mt-3 text-[11.5px] leading-relaxed text-warn">
              Short history: only {observedDays < 1 ? "<1" : Math.floor(observedDays)} day
              {observedDays >= 2 ? "s" : ""} observed, so historical income covers only a
              limited window.
            </p>
          ) : null}

          <div className="mt-7 grid gap-4 sm:grid-cols-3">
            <DarkMetric
              label="Historical income"
              value={
                history.phase === "ready"
                  ? `${fmtAmount(history.value.recordedIncome, 18, 4)} USDfr`
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

        <div className="bg-navy-deep p-7 sm:p-8">
          <h2 className="text-[11px] font-semibold tracking-[0.04em] text-on-navy/55">
            Your sUSDfr position
          </h2>
          {address ? (
            <>
              <div className="mt-5 grid grid-cols-2 gap-x-6 gap-y-5">
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
                    metrics?.positionPnl !== null &&
                    metrics?.positionPnl !== undefined
                      ? `${metrics.positionPnl < 0n ? "−" : "+"}${fmtAmount(
                          metrics.positionPnl < 0n
                            ? -metrics.positionPnl
                            : metrics.positionPnl,
                          18,
                          4,
                        )} USDfr`
                      : "Unavailable"
                  }
                  note={
                    history.phase === "ready" &&
                    history.value.hasExternalShareTransfer
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
              <p className="mt-6 border-t border-white/10 pt-4 text-[11.5px] leading-relaxed text-on-navy/45">
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
      {history.phase === "error" ? (
        <p className="border-t border-warn/30 bg-warn/10 px-7 py-3 text-[11.5px] text-on-navy/65">
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
    <div>
      <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-on-navy/40">
        {label}
      </p>
      {/* Carries words ("Immediate") as well as figures, so this is the body face with
          tabular numerals rather than mono. */}
      <p className="tnum mt-1 text-[15px] font-medium text-on-navy">{value}</p>
      <p className="mt-1 text-[10.5px] leading-snug text-on-navy/40">{note}</p>
    </div>
  );
}
