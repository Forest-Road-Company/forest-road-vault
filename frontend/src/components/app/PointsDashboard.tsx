"use client";

import {useAccount, useReadContracts} from "wagmi";
import {CONTRACTS, NETWORK_NAME} from "@/config/contracts";
import {POINTS_ABI, SHARE_DECIMALS} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";
import {VERTICALS} from "@/lib/verticals";
import {EXPECTED_CHAIN} from "@/lib/wagmi";
import {ConnectControl} from "@/components/app/ConnectControl";
import {NetworkBanner} from "@/components/app/NetworkBanner";

const BPS = 10_000n;
const CLASS_IDS = [1n, 2n, 3n, 4n, 5n] as const;
const POLL = {refetchInterval: 30_000} as const;

type Breakdown = readonly [bigint, bigint, bigint];
type TrackedBalances = readonly [bigint, bigint];
type FreezeStatus = readonly [boolean, bigint];

function multipleLabel(bps: number | undefined): string {
  if (bps === undefined) return "—";
  const value = BigInt(bps);
  return `${value / BPS}.${((value % BPS) / 100n).toString().padStart(2, "0")}×`;
}

function maturityRangeLabel(bps: number | undefined): string {
  if (bps === undefined) return "—";
  return `${multipleLabel(bps)} → ${multipleLabel(bps * 2)}`;
}

function SourceCard({
  title,
  balance,
  balanceDecimals,
  balanceSymbol,
  points,
  multiplierBps,
  baseRate,
  note,
}: {
  title: string;
  balance: bigint | undefined;
  balanceDecimals: number;
  balanceSymbol: string;
  points: bigint | undefined;
  multiplierBps: number | undefined;
  baseRate: bigint | undefined;
  note: string;
}) {
  const dailyBase =
    baseRate !== undefined && multiplierBps !== undefined
      ? (baseRate * BigInt(multiplierBps)) / BPS
      : undefined;

  return (
    <div className="panel h-full p-6">
      <div className="flex items-baseline justify-between gap-3">
        <h3 className="font-display text-[15px] font-semibold tracking-tight text-ink">
          {title}
        </h3>
        <span className="font-mono text-[11px] text-accent">
          {maturityRangeLabel(multiplierBps)}
        </span>
      </div>
      <p className="display mt-4 text-[32px] leading-none text-ink">
        {points !== undefined ? fmtAmount(points, 18, 4) : "—"}
      </p>
      <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
        points accrued
      </p>
      <div className="mt-4 border-t border-line pt-3 font-mono text-[10.5px] leading-relaxed text-ink-faint">
        <p>
          Tracked:{" "}
          <span className="text-ink-muted">
            {balance !== undefined ? fmtAmount(balance, balanceDecimals, 4) : "—"} {balanceSymbol}
          </span>
        </p>
        <p>
          Base rate:{" "}
          <span className="text-ink-muted">
            {dailyBase !== undefined ? fmtAmount(dailyBase, 18, 4) : "—"} points/unit/day
          </span>
        </p>
      </div>
      <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">{note}</p>
    </div>
  );
}

export function PointsDashboard() {
  const {address, isConnected, chainId} = useAccount();
  const points = CONTRACTS.PointsModule;
  const rightNetwork = chainId === EXPECTED_CHAIN.id;

  const contracts =
    address && points
      ? [
          {address: points, abi: POINTS_ABI, functionName: "pointsOfWallet", args: [address]},
          {address: points, abi: POINTS_ABI, functionName: "pointsBreakdown", args: [address]},
          {address: points, abi: POINTS_ABI, functionName: "trackedBalances", args: [address]},
          {address: points, abi: POINTS_ABI, functionName: "ratePerUnitDay"},
          {address: points, abi: POINTS_ABI, functionName: "usdfrMultiplierBps"},
          {address: points, abi: POINTS_ABI, functionName: "curatorMultiplierBps"},
          {address: points, abi: POINTS_ABI, functionName: "rateEpochCount"},
          ...CLASS_IDS.flatMap((classId) => [
            {address: points, abi: POINTS_ABI, functionName: "curatorTracked", args: [address, classId]},
            {address: points, abi: POINTS_ABI, functionName: "curatorPointsInClass", args: [address, classId]},
            {address: points, abi: POINTS_ABI, functionName: "curatorFreezeStatus", args: [address, classId]},
          ]),
        ]
      : [];

  const {data, isLoading, isError} = useReadContracts({
    contracts,
    allowFailure: true,
    query: {
      enabled: Boolean(address && points && rightNetwork),
      ...POLL,
    },
  });

  const result = (index: number) =>
    data?.[index]?.status === "success" ? data[index].result : undefined;

  const totalPoints = result(0) as bigint | undefined;
  const breakdown = result(1) as Breakdown | undefined;
  const tracked = result(2) as TrackedBalances | undefined;
  const baseRate = result(3) as bigint | undefined;
  const usdfrMultiplier = result(4) as number | undefined;
  const curatorMultiplier = result(5) as number | undefined;
  const rateEpochCount = result(6) as bigint | undefined;

  const classRows = CLASS_IDS.map((classId, index) => {
    const offset = 7 + index * 3;
    const freeze = result(offset + 2) as FreezeStatus | undefined;
    return {
      classId,
      name: VERTICALS[index]?.name ?? `Class ${classId.toString()}`,
      balance: result(offset) as bigint | undefined,
      points: result(offset + 1) as bigint | undefined,
      frozen: freeze?.[0] ?? false,
      frozenAt: freeze?.[1],
    };
  });

  const curatorBalance =
    classRows.every((row) => row.balance !== undefined)
      ? classRows.reduce((sum, row) => sum + (row.balance ?? 0n), 0n)
      : undefined;

  return (
    <div className="mt-12">
      <div className="flex flex-wrap items-center justify-between gap-4 rounded-card border border-line bg-raised/70 px-5 py-4">
        <ConnectControl />
        <span className="text-[10.5px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
          live on-chain ledger · refreshes every 30 seconds
        </span>
      </div>
      <NetworkBanner />

      {!isConnected ? (
        <div className="mt-5 rounded-card border border-dashed border-line-strong bg-raised/60 p-10 text-center">
          <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint">
            Connect a wallet
          </p>
          <p className="mx-auto mt-3 max-w-md text-[13.5px] leading-relaxed text-ink-muted">
            Connect the wallet whose participation you want to inspect. The dashboard reads
            its existing on-chain history; connecting does not start, reset, or checkpoint accrual.
          </p>
        </div>
      ) : !rightNetwork ? (
        <div className="mt-5 rounded-card border border-warn/40 bg-warn/10 p-6 text-[13px] text-ink-muted">
          Switch the wallet to {NETWORK_NAME} to read the deployed points ledger.
        </div>
      ) : isError ? (
        <div className="mt-5 rounded-card border border-danger/40 bg-danger/10 p-6 text-[13px] text-ink-muted">
          Points reads are unavailable from the configured RPC. No zero balance has been assumed.
        </div>
      ) : (
        <>
          <div className="mt-5 grid gap-5 lg:grid-cols-3">
            <div className="panel p-7 lg:col-span-2">
              <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint">
                Your points
              </p>
              <p className="display mt-4 break-all text-[clamp(2rem,4vw,3.375rem)] leading-none text-ink">
                {totalPoints !== undefined ? fmtAmount(totalPoints, 18, 4) : isLoading ? "…" : "—"}
              </p>
              <p className="mt-4 max-w-2xl text-[13px] leading-relaxed text-ink-muted">
                Accrued and pending points from this wallet&apos;s complete on-chain position
                history. The view is lazy: it calculates pending time since the last checkpoint
                without requiring a transaction.
              </p>
            </div>
            <div className="panel p-7">
              <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-accent">
                Live parameters
              </p>
              <dl className="mt-4 space-y-3 font-mono text-[11px]">
                <div className="flex justify-between gap-4">
                  <dt className="text-ink-faint">Base rate</dt>
                  <dd className="text-ink">
                    {baseRate !== undefined ? `${fmtAmount(baseRate, 18, 4)}/unit/day` : "—"}
                  </dd>
                </div>
                <div className="flex justify-between gap-4">
                  <dt className="text-ink-faint">USDfr</dt>
                  <dd className="text-ink">{multipleLabel(usdfrMultiplier)}</dd>
                </div>
                <div className="flex justify-between gap-4">
                  <dt className="text-ink-faint">Curator</dt>
                  <dd className="text-ink">{multipleLabel(curatorMultiplier)}</dd>
                </div>
                <div className="flex justify-between gap-4">
                  <dt className="text-ink-faint">Rate epochs</dt>
                  <dd className="text-ink">{rateEpochCount?.toString() ?? "—"}</dd>
                </div>
              </dl>
              <p className="mt-4 text-[11px] leading-relaxed text-ink-faint">
                Every source has the same 1×→2× maturity factor over 365 days:
                currently sUSDfr 1×→2×, USDfr 3×→6×, and curator
                first-loss 5×→10×. Governance changes append forward-only rate epochs.
              </p>
            </div>
          </div>

          <div className="mt-5 grid gap-5 md:grid-cols-3">
            <SourceCard
              title="sUSDfr staked"
              balance={tracked?.[0]}
              balanceDecimals={SHARE_DECIMALS}
              balanceSymbol="sUSDfr"
              points={breakdown?.[0]}
              multiplierBps={10_000}
              baseRate={baseRate}
              note="The base source. sUSDfr already receives the vault’s variable income."
            />
            <SourceCard
              title="USDfr held"
              balance={tracked?.[1]}
              balanceDecimals={18}
              balanceSymbol="USDfr"
              points={breakdown?.[1]}
              multiplierBps={usdfrMultiplier}
              baseRate={baseRate}
              note="Higher participation weighting for holding USDfr without staking it for vault income."
            />
            <SourceCard
              title="Curator first-loss"
              balance={curatorBalance}
              balanceDecimals={18}
              balanceSymbol="USDfr"
              points={breakdown?.[2]}
              multiplierBps={curatorMultiplier}
              baseRate={baseRate}
              note="The highest weighting reflects capital that absorbs realized class losses first."
            />
          </div>

          <div className="panel mt-5 overflow-hidden">
            <div className="border-b border-line px-6 py-4">
              <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-ink-faint">
                Curator positions by class
              </p>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[680px] text-left">
                <thead className="text-[11px] font-semibold uppercase tracking-[0.12em] text-ink-faint">
                  <tr>
                    <th className="px-6 py-3 font-normal">Class</th>
                    <th className="px-6 py-3 text-right font-normal">Tracked capital</th>
                    <th className="px-6 py-3 text-right font-normal">Points</th>
                    <th className="px-6 py-3 text-right font-normal">Accrual status</th>
                  </tr>
                </thead>
                <tbody className="font-mono text-[11px] text-ink-muted">
                  {classRows.map((row) => (
                    <tr key={row.classId.toString()} className="border-t border-line">
                      <td className="px-6 py-3.5 text-ink">{row.name}</td>
                      <td className="px-6 py-3.5 text-right">
                        {row.balance !== undefined ? `${fmtAmount(row.balance, 18, 2)} USDfr` : "—"}
                      </td>
                      <td className="px-6 py-3.5 text-right">
                        {row.points !== undefined ? fmtAmount(row.points, 18, 2) : "—"}
                      </td>
                      <td className={`px-6 py-3.5 text-right ${row.frozen ? "text-warn" : "text-accent"}`}>
                        {row.frozen
                          ? `frozen since ${row.frozenAt ?? "unknown"}`
                          : "active"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
