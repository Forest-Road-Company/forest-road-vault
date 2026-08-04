"use client";

/**
 * Transparency dashboard — every number is a direct contract read against the live
 * configured deployment, and every panel links the contract it reads so any figure can
 * be reconciled on Etherscan (CLAUDE.md §2.2: frontend↔contract reconciliation).
 * No aggregation happens off-chain beyond formatting.
 */

import {useEffect, useState} from "react";
import {useBlockNumber, usePublicClient, useReadContracts} from "wagmi";
import {
  CONTRACTS,
  EXPLORER_BASE_URL,
  IS_TESTNET,
  NETWORK_NAME,
  PROTOCOL_DEPLOYMENT_BLOCK,
  SUPPORTS_VAULT_FEE_ACCOUNTING,
} from "@/config/contracts";
import {
  BRIDGE_HISTORY_ABI,
  BRIDGE_ABI,
  CURATOR_ABI,
  DEFAULT_HISTORY_ABI,
  ERC20_ABI,
  QUEUE_ABI,
  REGISTRY_ABI,
  RESERVES_ABI,
  SGROVE_ABI,
  SHARE_DECIMALS,
  VAULT_ABI,
  VAULT_HISTORY_ABI,
  WATERFALL_ABI,
  WATERFALL_HISTORY_ABI,
} from "@/lib/abi";
import {
  calculateHistoricalNetDefaultMetrics,
  type HistoricalNetDefaultMetrics,
} from "@/lib/book";
import {fmtAmount, fmtCountdown, shortAddress} from "@/lib/format";
import {formatBps} from "@/lib/yield";
import {readBlockRangeChunked} from "@/lib/logs";
import {VERTICALS} from "@/lib/verticals";
import {useNowSeconds} from "@/components/app/useNowSeconds";
import {useBookEconomics} from "@/components/app/useBookEconomics";
import {useCollateralValue} from "@/components/app/useCollateralValue";

const EXPLORER = EXPLORER_BASE_URL
  ? `${EXPLORER_BASE_URL}/address/`
  : null;

type RevenueState =
  | {phase: "loading"}
  | {
      phase: "ready";
      originationFees: bigint;
      interestFees: bigint;
      performanceFees: bigint;
      managementFees: bigint;
    }
  | {phase: "error"};

type CreditPerformanceState =
  | {phase: "loading"}
  | {phase: "ready"; metrics: HistoricalNetDefaultMetrics}
  | {phase: "error"};

export function TransparencyDashboard() {
  // A "live" dashboard that freezes at page-load is dishonest — poll once a
  // minute (a single multicall + one blockNumber call).
  const POLL = {refetchInterval: 60_000} as const;
  const {data: blockNumber} = useBlockNumber({query: POLL});
  const publicClient = usePublicClient();
  const [revenue, setRevenue] = useState<RevenueState>({phase: "loading"});
  const [creditPerformance, setCreditPerformance] =
    useState<CreditPerformanceState>({phase: "loading"});
  const {data} = useReadContracts({
    query: POLL,
    contracts: [
      {address: CONTRACTS.USDfr!, abi: ERC20_ABI, functionName: "totalSupply"},
      {address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "totalBackingValue"},
      {address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "idleReserve"},
      {address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "deployedPrincipal"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "totalAssets"},
      {address: CONTRACTS.sUSDfr!, abi: ERC20_ABI, functionName: "totalSupply"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "currentExchangeRate"},
      {address: CONTRACTS.CollateralRegistry!, abi: REGISTRY_ABI, functionName: "totalBookExposure"},
      {address: CONTRACTS.ClaimBridge!, abi: BRIDGE_ABI, functionName: "totalOriginated"},
      {address: CONTRACTS.sGROVE!, abi: SGROVE_ABI, functionName: "coverageCapacity"},
      {address: CONTRACTS.sGROVE!, abi: SGROVE_ABI, functionName: "coverageReserve"},
      {address: CONTRACTS.RedemptionQueue!, abi: QUEUE_ABI, functionName: "currentEpoch"},
      {address: CONTRACTS.RedemptionQueue!, abi: QUEUE_ABI, functionName: "epochEndsAt"},
      {address: CONTRACTS.RedemptionQueue!, abi: QUEUE_ABI, functionName: "totalQueuedShares"},
      {address: CONTRACTS.RedemptionQueue!, abi: QUEUE_ABI, functionName: "availableLiquidity"},
      {address: CONTRACTS.WaterfallEngine!, abi: WATERFALL_ABI, functionName: "protocolFeeBps"},
      {address: CONTRACTS.WaterfallEngine!, abi: WATERFALL_ABI, functionName: "feeRecipient"},
      {address: CONTRACTS.CuratorModule!, abi: CURATOR_ABI, functionName: "poolBalance", args: [1n]},
      {address: CONTRACTS.CuratorModule!, abi: CURATOR_ABI, functionName: "poolBalance", args: [2n]},
      {address: CONTRACTS.CuratorModule!, abi: CURATOR_ABI, functionName: "poolBalance", args: [3n]},
      {address: CONTRACTS.CuratorModule!, abi: CURATOR_ABI, functionName: "poolBalance", args: [4n]},
      {address: CONTRACTS.CuratorModule!, abi: CURATOR_ABI, functionName: "poolBalance", args: [5n]},
    ],
  });
  const {data: feeData} = useReadContracts({
    query: {enabled: SUPPORTS_VAULT_FEE_ACCOUNTING, ...POLL},
    contracts: [
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "performanceFeeBps"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "managementFeeBps"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "maxManagementFeeBps"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "feeRecipient"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "highWaterMark"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "feeExchangeRate"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "lastFeeAccrual"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "managementFeeYear"},
      {address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "maxPerformanceFeeBps"},
    ],
  });

  const v = (i: number) => data?.[i]?.result as bigint | undefined;
  const supply = v(0);
  const backing = v(1);
  const idle = v(2);
  const deployed = v(3);
  const vaultAssets = v(4);
  const vaultShares = v(5);
  const rate = v(6);
  const bookExposure = v(7);
  const facilities = v(8);
  const coverageCapacity = v(9);
  const coverageReserve = v(10);
  const epoch = v(11);
  const epochEndsAt = v(12);
  const queuedShares = v(13);
  const queueLiquidity = v(14);
  const protocolFeeBps = data?.[15]?.result as number | undefined;
  const waterfallFeeRecipient = data?.[16]?.result as string | undefined;
  const curatorPools = [v(17), v(18), v(19), v(20), v(21)];
  const fv = (i: number) => feeData?.[i]?.result as bigint | undefined;
  const performanceFeeBps = feeData?.[0]?.result as number | undefined;
  const managementFeeBps = feeData?.[1]?.result as number | undefined;
  const maxManagementFeeBps = feeData?.[2]?.result as number | undefined;
  const vaultFeeRecipient = feeData?.[3]?.result as string | undefined;
  const highWaterMark = fv(4);
  const feeExchangeRate = fv(5);
  const lastFeeAccrual = fv(6);
  const managementFeeYear = fv(7);
  const maxPerformanceFeeBps = feeData?.[8]?.result as number | undefined;
  const feeRecipientsMatch =
    waterfallFeeRecipient !== undefined && vaultFeeRecipient !== undefined
      ? waterfallFeeRecipient.toLowerCase() === vaultFeeRecipient.toLowerCase()
      : undefined;
  const curatorCapital = curatorPools.every(
    (balance): balance is bigint => balance !== undefined,
  )
    ? curatorPools.reduce((total, balance) => total + balance, 0n)
    : undefined;
  const {metrics: bookYield} = useBookEconomics(facilities);
  const {metrics: collateralValue} = useCollateralValue(facilities);
  const grossCollateralAndReserves =
    idle !== undefined && collateralValue?.complete
      ? idle + collateralValue.referenceValue
      : undefined;
  const grossCollateralAndReservesBps =
    grossCollateralAndReserves !== undefined && deployed !== undefined && deployed > 0n
      ? (grossCollateralAndReserves * 10_000n) / deployed
      : null;
  const curatorCapitalBps =
    curatorCapital !== undefined && deployed !== undefined && deployed > 0n
      ? (curatorCapital * 10_000n) / deployed
      : null;
  const backstopReserveBps =
    coverageReserve !== undefined && deployed !== undefined && deployed > 0n
      ? (coverageReserve * 10_000n) / deployed
      : null;

  useEffect(() => {
    let cancelled = false;

    async function loadRevenue() {
      if (
        !publicClient ||
        blockNumber === undefined ||
        !CONTRACTS.WaterfallEngine ||
        !CONTRACTS.sUSDfr ||
        blockNumber < PROTOCOL_DEPLOYMENT_BLOCK
      ) {
        return;
      }
      setRevenue({phase: "loading"});
      try {
        const common = {
          address: CONTRACTS.WaterfallEngine,
          abi: WATERFALL_HISTORY_ABI,
        } as const;
        const vaultCommon = {
          address: CONTRACTS.sUSDfr,
          abi: VAULT_HISTORY_ABI,
        } as const;
        const [originations, distributions, performanceFees, managementFees] = await Promise.all([
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                ...common,
                eventName: "OriginationFeeCharged",
                fromBlock,
                toBlock,
              }),
          ),
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                ...common,
                eventName: "Distributed",
                fromBlock,
                toBlock,
              }),
          ),
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                ...vaultCommon,
                eventName: "PerformanceFeeAccrued",
                fromBlock,
                toBlock,
              }),
          ),
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                ...vaultCommon,
                eventName: "ManagementFeeAccrued",
                fromBlock,
                toBlock,
              }),
          ),
        ]);
        if (cancelled) return;
        setRevenue({
          phase: "ready",
          originationFees: originations.reduce(
            (sum, event) => sum + (event.args.fee ?? 0n),
            0n,
          ),
          interestFees: distributions.reduce(
            (sum, event) => sum + (event.args.fee ?? 0n),
            0n,
          ),
          performanceFees: performanceFees.reduce(
            (sum, event) => sum + (event.args.feeAssets ?? 0n),
            0n,
          ),
          managementFees: managementFees.reduce(
            (sum, event) => sum + (event.args.feeAssets ?? 0n),
            0n,
          ),
        });
      } catch {
        if (!cancelled) setRevenue({phase: "error"});
      }
    }

    void loadRevenue();
    return () => {
      cancelled = true;
    };
  }, [blockNumber, publicClient]);

  useEffect(() => {
    let cancelled = false;

    async function loadCreditPerformance() {
      if (
        !publicClient ||
        blockNumber === undefined ||
        !CONTRACTS.ClaimBridge ||
        !CONTRACTS.WaterfallEngine ||
        !CONTRACTS.DefaultManager ||
        blockNumber < PROTOCOL_DEPLOYMENT_BLOCK
      ) {
        return;
      }
      setCreditPerformance({phase: "loading"});
      try {
        const [originations, fundings, losses] = await Promise.all([
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                address: CONTRACTS.ClaimBridge!,
                abi: BRIDGE_HISTORY_ABI,
                eventName: "Originated",
                fromBlock,
                toBlock,
              }),
          ),
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                address: CONTRACTS.WaterfallEngine!,
                abi: WATERFALL_HISTORY_ABI,
                eventName: "Funded",
                fromBlock,
                toBlock,
              }),
          ),
          readBlockRangeChunked(
            PROTOCOL_DEPLOYMENT_BLOCK,
            blockNumber,
            (fromBlock, toBlock) =>
              publicClient.getContractEvents({
                address: CONTRACTS.DefaultManager!,
                abi: DEFAULT_HISTORY_ABI,
                eventName: "LossRealized",
                fromBlock,
                toBlock,
              }),
          ),
        ]);
        if (cancelled) return;

        const classByToken = new Map<bigint, number>();
        for (const event of originations) {
          const tokenId = event.args.tokenId;
          const classId = event.args.classId;
          if (tokenId === undefined || classId === undefined) {
            throw new Error("incomplete Originated event");
          }
          classByToken.set(tokenId, Number(classId));
        }

        const funded = fundings.map((event) => {
          const tokenId = event.args.tokenId;
          const principal = event.args.principal;
          if (tokenId === undefined || principal === undefined) {
            throw new Error("incomplete Funded event");
          }
          const classId = classByToken.get(tokenId);
          if (classId === undefined) {
            throw new Error(`missing origination for funded facility ${tokenId}`);
          }
          return {classId, principal};
        });
        const realizedLosses = losses.map((event) => {
          const classId = event.args.classId;
          const loss = event.args.loss;
          if (classId === undefined || loss === undefined) {
            throw new Error("incomplete LossRealized event");
          }
          return {classId: Number(classId), loss};
        });

        setCreditPerformance({
          phase: "ready",
          metrics: calculateHistoricalNetDefaultMetrics(
            funded,
            realizedLosses,
            VERTICALS.map((_, index) => index + 1),
          ),
        });
      } catch {
        if (!cancelled) setCreditPerformance({phase: "error"});
      }
    }

    void loadCreditPerformance();
    return () => {
      cancelled = true;
    };
  }, [blockNumber, publicClient]);

  const totalRevenue =
    revenue.phase === "ready"
      ? revenue.originationFees +
        revenue.interestFees +
        revenue.performanceFees +
        revenue.managementFees
      : undefined;

  const backingOk =
    supply !== undefined && backing !== undefined ? supply <= backing : undefined;
  const now = useNowSeconds();

  const fmt = (x: bigint | undefined, dp = 2) => (x !== undefined ? fmtAmount(x, 18, dp) : "—");

  return (
    <div className="mt-12">
      {/* ── Backing invariant ─────────────────────────────────────────── */}
      <div className="panel p-7">
        <div className="flex flex-wrap items-baseline justify-between gap-3">
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
            The backing invariant — supply ≤ backing, enforced in-contract
          </p>
          {backingOk === undefined ? null : backingOk ? (
            <span className="rounded-pill border border-moss/30 bg-moss-faint px-3 py-1 font-mono text-[10.5px] uppercase tracking-[0.14em] text-moss">
              holding
            </span>
          ) : (
            <span className="rounded-pill border border-danger/40 bg-danger/10 px-3 py-1 font-mono text-[10.5px] uppercase tracking-[0.14em] text-danger">
              violated — this should be impossible
            </span>
          )}
        </div>
        <div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
          <div>
            <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-ink-faint">USDfr supply</p>
            <p className="serif-display mt-1 text-[34px] text-ink">{fmt(supply)}</p>
            <Reconcile addr={CONTRACTS.USDfr!} fn="totalSupply" />
          </div>
          <div>
            <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-ink-faint">Backing value</p>
            <p className="serif-display mt-1 text-[34px] text-ink">${fmt(backing)}</p>
            <Reconcile addr={CONTRACTS.ReserveManager!} fn="totalBackingValue" />
          </div>
          <div>
            <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-ink-faint">
              Gross collateral &amp; reserves
            </p>
            <p className="serif-display mt-1 text-[34px] text-ink">
              {grossCollateralAndReserves !== undefined
                ? `$${fmt(grossCollateralAndReserves)}`
                : "—"}
            </p>
            <p className="mt-1 font-mono text-[10px] text-ink-faint">
              {collateralValue && !collateralValue.complete
                ? "fresh collateral mark unavailable"
                : grossCollateralAndReservesBps !== null
                  ? `${formatBps(grossCollateralAndReservesBps)} of funds on loan`
                  : deployed === 0n
                    ? "no funds currently on loan"
                    : "idle reserve + gross loan collateral"}
            </p>
          </div>
          <div>
            <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-ink-faint">
              Curator first-loss capital
            </p>
            <p className="serif-display mt-1 text-[34px] text-ink">
              {curatorCapital !== undefined ? `$${fmt(curatorCapital)}` : "—"}
            </p>
            <p className="mt-1 font-mono text-[10px] text-ink-faint">
              {curatorCapitalBps !== null
                ? `${formatBps(curatorCapitalBps)} of outstanding loans`
                : "sum of all five class pools"}
            </p>
          </div>
          <div>
            <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-ink-faint">
              sGROVE total backstop
            </p>
            <p className="serif-display mt-1 text-[34px] text-ink">
              {coverageReserve !== undefined ? `$${fmt(coverageReserve)}` : "—"}
            </p>
            <p className="mt-1 font-mono text-[10px] text-ink-faint">
              {backstopReserveBps !== null
                ? `${formatBps(backstopReserveBps)} of loans · $${fmt(coverageCapacity)} per event`
                : `$${fmt(coverageCapacity)} per-event capacity`}
            </p>
          </div>
        </div>
        <p className="mt-5 max-w-4xl text-[11.5px] leading-relaxed text-ink-faint">
          Backing is the protocol&apos;s accounting claim: idle reserves plus
          outstanding loan principal. Gross collateral &amp; reserves replaces loan
          principal with the broader collateral reference: receivables scale their
          live outstanding principal by the signed LTV, so the reference amortizes
          with the loan and falls on a write-down, and digital-asset loans use the
          latest fresh m-of-n attested mark; closed facilities are excluded. Curator
          capital is
          shown separately because it is subordinated USDfr already backed by this
          same asset pool—not an additional external asset to add a second time.
          The sGROVE figure is its total funded USDfr coverage reserve; the
          separately shown per-event capacity is the maximum callable for one
          loss event.
        </p>
      </div>

      {/* ── Panels ────────────────────────────────────────────────────── */}
      <div className="mt-5 grid gap-5 md:grid-cols-2 lg:grid-cols-3">
        <Panel title="Reserves" addr={CONTRACTS.ReserveManager!}>
          <Row k="Idle stablecoin reserve" val={`$${fmt(idle)}`} />
          <Row k="Deployed principal" val={`$${fmt(deployed)}`} />
        </Panel>

        <Panel title="sUSDfr vault" addr={CONTRACTS.sUSDfr!}>
          <Row k="Staked assets" val={`${fmt(vaultAssets)} USDfr`} />
          <Row k="Shares outstanding" val={vaultShares !== undefined ? fmtAmount(vaultShares, SHARE_DECIMALS) : "—"} />
          <Row
            k={SUPPORTS_VAULT_FEE_ACCOUNTING ? "Fee-net exchange rate" : "Legacy exchange rate"}
            val={rate !== undefined ? `${fmtAmount(rate, 18, 6)} USDfr/share` : "—"}
          />
          <Row
            k="Performance-fee NAV rate"
            val={
              feeExchangeRate !== undefined
                ? `${fmtAmount(feeExchangeRate, 18, 6)} USDfr/share`
                : SUPPORTS_VAULT_FEE_ACCOUNTING
                  ? "—"
                  : "Not deployed"
            }
          />
          <Row
            k="Global high-water mark"
            val={
              highWaterMark !== undefined
                ? `${fmtAmount(highWaterMark, 18, 6)} USDfr/share`
                : SUPPORTS_VAULT_FEE_ACCOUNTING
                  ? "—"
                  : "Not deployed"
            }
          />
          <Row
            k="Last fee checkpoint"
            val={
              lastFeeAccrual !== undefined
                ? new Date(Number(lastFeeAccrual) * 1_000).toISOString()
                : SUPPORTS_VAULT_FEE_ACCOUNTING
                  ? "—"
                  : "Not deployed"
            }
          />
          <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
            {SUPPORTS_VAULT_FEE_ACCOUNTING
              ? "The displayed exchange rate simulates fees due now. Gross marked fee NAV is the conservative impairment-netted rate tested against the global HWM before fee shares are minted."
              : "The configured legacy testnet vault predates ADR-0031. Fee selectors are disabled and no performance, management, HWM, or fee-checkpoint values are inferred."}
          </p>
        </Panel>

        <Panel title="The book" addr={CONTRACTS.CollateralRegistry!}>
          <Row k="Facilities originated" val={facilities?.toString() ?? "—"} />
          <Row k="Book exposure" val={`$${fmt(bookExposure)}`} />
          <Row
            k="Performing weighted yield"
            val={
              bookYield?.performingWeightedAverageBps !== null &&
              bookYield?.performingWeightedAverageBps !== undefined
                ? formatBps(bookYield.performingWeightedAverageBps)
                : "—"
            }
          />
          <Row
            k="All-outstanding contractual yield"
            val={
              bookYield?.weightedAverageBps !== null &&
              bookYield?.weightedAverageBps !== undefined
                ? formatBps(bookYield.weightedAverageBps)
                : "—"
            }
          />
          <Row
            k="Performing principal"
            val={bookYield ? `$${fmt(bookYield.performingPrincipal)}` : "—"}
          />
          <Row
            k="Gross performing income run-rate"
            val={
              bookYield
                ? `${fmt(bookYield.performingGrossAnnualInterest, 2)} USDfr/yr`
                : "—"
            }
          />
          <Row
            k="Non-performing principal"
            val={bookYield ? `$${fmt(bookYield.nonPerformingPrincipal)}` : "—"}
          />
          <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
            Gross contractual tiers, weighted by live outstanding principal. The
            performing rate includes only Active and Amortizing loans; it is not
            realized cash yield or an sUSDfr return.
          </p>
        </Panel>

        <Panel title="Historical credit performance" addr={CONTRACTS.DefaultManager!}>
          <Row
            k="Overall net default rate"
            val={
              creditPerformance.phase === "ready" &&
              creditPerformance.metrics.rateBps !== null
                ? formatBps(creditPerformance.metrics.rateBps)
                : "—"
            }
          />
          <Row
            k="Net principal written off"
            val={
              creditPerformance.phase === "ready"
                ? `$${fmt(creditPerformance.metrics.netLoss)}`
                : "—"
            }
          />
          <Row
            k="Cumulative funded principal"
            val={
              creditPerformance.phase === "ready"
                ? `$${fmt(creditPerformance.metrics.fundedPrincipal)}`
                : "—"
            }
          />
          {VERTICALS.map((vertical, index) => {
            const slice =
              creditPerformance.phase === "ready"
                ? creditPerformance.metrics.byClass.get(index + 1)
                : undefined;
            return (
              <Row
                key={vertical.slug}
                k={vertical.name}
                val={
                  slice?.rateBps !== null && slice?.rateBps !== undefined
                    ? formatBps(slice.rateBps)
                    : "—"
                }
              />
            );
          })}
          <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
            Cumulative principal written off after cash recoveries, divided by
            cumulative principal actually funded. Full recoveries contribute zero.
            Unresolved defaults remain in live risk metrics and are not counted as
            historical loss until realized.
          </p>
          {creditPerformance.phase === "error" ? (
            <p className="mt-2 text-[11.5px] text-warn">
              Historical default logs are unavailable from this RPC.
            </p>
          ) : null}
        </Panel>

        <Panel title="Protocol revenue" addr={CONTRACTS.WaterfallEngine!}>
          <Row k="Revenue since deployment" val={`${fmt(totalRevenue, 4)} USDfr-equiv.`} />
          <Row
            k="Origination fees"
            val={
              revenue.phase === "ready"
                ? `${fmt(revenue.originationFees, 4)} USDfr`
                : "—"
            }
          />
          <Row
            k="Interest fees"
            val={
              revenue.phase === "ready"
                ? `${fmt(revenue.interestFees, 4)} USDfr`
                : "—"
            }
          />
          <Row
            k="Performance fees"
            val={
              !SUPPORTS_VAULT_FEE_ACCOUNTING
                ? "Not deployed"
                : revenue.phase === "ready"
                ? `${fmt(revenue.performanceFees, 4)} USDfr-equiv.`
                : "—"
            }
          />
          <Row
            k="Management fees"
            val={
              !SUPPORTS_VAULT_FEE_ACCOUNTING
                ? "Not deployed"
                : revenue.phase === "ready"
                ? `${fmt(revenue.managementFees, 4)} USDfr-equiv.`
                : "—"
            }
          />
          <Row
            k="Current interest fee"
            val={protocolFeeBps !== undefined ? formatBps(BigInt(protocolFeeBps)) : "—"}
          />
          <Row
            k="Current performance fee"
            val={
              performanceFeeBps !== undefined && maxPerformanceFeeBps !== undefined
                ? `${formatBps(BigInt(performanceFeeBps))} · global HWM · ${formatBps(
                    BigInt(maxPerformanceFeeBps),
                  )} cap`
                : SUPPORTS_VAULT_FEE_ACCOUNTING
                  ? "—"
                  : "Not deployed"
            }
          />
          <Row
            k="Current management fee"
            val={
              managementFeeBps !== undefined && maxManagementFeeBps !== undefined
                ? `${formatBps(BigInt(managementFeeBps))} · ${
                    managementFeeYear !== undefined
                      ? `${Number(managementFeeYear) / 86_400}d basis · `
                      : ""
                  }${formatBps(BigInt(maxManagementFeeBps))} cap`
                : SUPPORTS_VAULT_FEE_ACCOUNTING
                  ? "—"
                  : "Not deployed"
            }
          />
          <Row
            k="Waterfall recipient"
            val={
              waterfallFeeRecipient
                ? shortAddress(waterfallFeeRecipient)
                : "—"
            }
          />
          <Row
            k="Vault recipient"
            val={vaultFeeRecipient ? shortAddress(vaultFeeRecipient) : "—"}
          />
          <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
            {SUPPORTS_VAULT_FEE_ACCOUNTING
              ? "Event-summed fees at receipt or crystallization. Performance and management amounts are denominated in USDfr at the checkpoint but paid as sUSDfr shares, whose later value can change. Recipient wallet balances are not used because fee assets/shares can be transferred. Principal repayments and depositor income are excluded. The HWM is protocol-wide, not personal cost-basis accounting."
              : "The configured legacy testnet vault has only the Waterfall fee model. Switch to an ADR-0031-compatible vault and ABI version 1 before vault fee reads or claims are shown."}
          </p>
          {feeRecipientsMatch === false ? (
            <p className="mt-2 text-[11.5px] font-medium text-danger">
              Alert: Waterfall and vault fee recipients do not match.
            </p>
          ) : null}
          {revenue.phase === "error" ? (
            <p className="mt-2 text-[11.5px] text-warn">
              Historical revenue logs are unavailable from this RPC.
            </p>
          ) : null}
        </Panel>

        <Panel title="sGROVE backstop" addr={CONTRACTS.sGROVE!}>
          <Row k="Coverage capacity (per event)" val={`$${fmt(coverageCapacity)}`} />
          <Row k="Coverage reserve" val={`$${fmt(coverageReserve)}`} />
          <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
            Capacity is the USDfr coverage reserve × per-event cap — never the market
            value of staked GROVE.
          </p>
        </Panel>

        <Panel title="Redemption queue" addr={CONTRACTS.RedemptionQueue!}>
          <Row k="Current epoch" val={epoch?.toString() ?? "—"} />
          <Row
            k="Epoch ends"
            val={
              epochEndsAt !== undefined && now !== null
                ? Number(epochEndsAt) <= now
                  ? "over — awaiting close"
                  : `in ${fmtCountdown(Number(epochEndsAt) - now)}`
                : "—"
            }
          />
          <Row
            k="Queued shares"
            val={queuedShares !== undefined ? `${fmtAmount(queuedShares, SHARE_DECIMALS, 4)} sUSDfr` : "—"}
          />
          <Row k="Settlement liquidity" val={`$${fmt(queueLiquidity)}`} />
        </Panel>

        <Panel title="Provenance" addr={CONTRACTS.MintRedeemController!}>
          <Row k="Network" val={NETWORK_NAME} />
          <Row k="As of block" val={blockNumber?.toString() ?? "—"} />
          <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
            Every figure on this page is a direct contract read
            {EXPLORER
              ? " — click any panel's address to reconcile it on Etherscan. "
              : ". This local fork has no block explorer. "}
            {IS_TESTNET ? "Test tokens; no real value." : "Live Ethereum mainnet state."}
          </p>
        </Panel>
      </div>
    </div>
  );
}

function Panel({title, addr, children}: {title: string; addr: string; children: React.ReactNode}) {
  return (
    <div className="panel flex h-full flex-col p-6">
      <div className="flex items-baseline justify-between gap-3">
        <h3 className="font-grotesk text-[15px] font-semibold tracking-tight">{title}</h3>
        {EXPLORER ? (
          <a
            href={`${EXPLORER}${addr}`}
            target="_blank"
            rel="noreferrer"
            className="u-link font-mono text-[10px] text-ink-faint hover:text-moss"
          >
            {addr.slice(0, 6)}…{addr.slice(-4)}
          </a>
        ) : (
          <span className="font-mono text-[10px] text-ink-faint">
            {addr.slice(0, 6)}…{addr.slice(-4)}
          </span>
        )}
      </div>
      <div className="mt-4">{children}</div>
    </div>
  );
}

function Row({k, val}: {k: string; val: string}) {
  return (
    <div className="flex items-baseline justify-between gap-3 border-t border-line py-2 first:border-t-0">
      <p className="text-[12.5px] text-ink-muted">{k}</p>
      <p className="font-mono text-[12.5px] text-ink">{val}</p>
    </div>
  );
}

function Reconcile({addr, fn}: {addr: string; fn: string}) {
  return (
    <a
      href={`${EXPLORER}${addr}#readProxyContract`}
      target="_blank"
      rel="noreferrer"
      className="u-link mt-1 inline-block font-mono text-[10px] text-ink-faint hover:text-moss"
    >
      {fn}() on Etherscan →
    </a>
  );
}
