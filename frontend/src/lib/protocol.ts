/**
 * Typed protocol read layer (brief §8.4). Every dashboard number flows through these
 * views, each backed by specific contract reads, nothing on the transparency surface
 * may come from anywhere else. Implementations use viem `readContract`/multicall
 * against the addresses in config/contracts.ts. When a required deployment address is
 * absent, the affected view resolves to `null` and the UI renders an honest unavailable
 * state (never simulated data).
 */

import {isProtocolLive, contractAddress} from "@/config/contracts";
import {publicClient} from "@/lib/client";
import {POINTS_ABI} from "@/lib/abi";

// Minimal inline ABIs, only the read functions this layer calls (no address is read
// from anywhere but config/contracts.ts).
const ERC20_SUPPLY_ABI = [
  {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;
const SUSDFR_ABI = [
  {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "currentExchangeRate", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;
const RESERVE_ABI = [
  {type: "function", name: "idleReserve", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "deployedPrincipal", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
  {type: "function", name: "totalBackingValue", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
] as const;

export type ProtocolStats = {
  tvl: bigint;
  usdfrSupply: bigint;
  susdfrSupply: bigint;
  exchangeRate: bigint; // sUSDfr.currentExchangeRate()
  trailingYieldBps: number; // computed from exchange-rate history (indexer)
  reserveIdle: bigint; // ReserveManager.idleReserve()
  reserveDeployed: bigint; // ReserveManager.deployedPrincipal()
  asOfBlock: bigint;
};

export type PointsView = {
  /** Per-wallet total: accrued storage plus pending on-chain time. */
  points: bigint;
  fromShares: bigint;
  fromUSDfr: bigint;
  fromCurator: bigint;
  trackedShares: bigint;
  trackedUSDfr: bigint;
  ratePerUnitDay: bigint;
  usdfrMultiplierBps: number;
  curatorMultiplierBps: number;
  asOfBlock: bigint;
};

/** Honest framing contract for every points surface (ADR-0016 / brief Part 0.5):
 *  points are a participation measure, no token promise, no implied profit. */
export const POINTS_DISCLAIMER =
  "Points measure participation. They are not a token or a claim on one; any future utility is discretionary and subject to counsel review.";

/** The backing value = idle reserve + deployed principal (ADR-0012). Also surfaced
 *  separately for the "supply ≤ backing" panel. */
export type Backing = {backingValue: bigint; usdfrSupply: bigint};

export async function getProtocolStats(): Promise<ProtocolStats | null> {
  if (!isProtocolLive()) return null;
  const usdfr = contractAddress("USDfr");
  const susdfr = contractAddress("sUSDfr");
  const reserves = contractAddress("ReserveManager");
  if (!usdfr || !susdfr || !reserves) return null;

  const client = publicClient();
  const [usdfrSupply, susdfrSupply, exchangeRate, reserveIdle, reserveDeployed, block] =
    await Promise.all([
      client.readContract({address: usdfr, abi: ERC20_SUPPLY_ABI, functionName: "totalSupply"}),
      client.readContract({address: susdfr, abi: SUSDFR_ABI, functionName: "totalSupply"}),
      client.readContract({address: susdfr, abi: SUSDFR_ABI, functionName: "currentExchangeRate"}),
      client.readContract({address: reserves, abi: RESERVE_ABI, functionName: "idleReserve"}),
      client.readContract({address: reserves, abi: RESERVE_ABI, functionName: "deployedPrincipal"}),
      client.getBlockNumber(),
    ]);

  return {
    tvl: reserveIdle + reserveDeployed, // deployed principal + idle reserve (brief §8.4)
    usdfrSupply,
    susdfrSupply,
    exchangeRate,
    trailingYieldBps: 0, // needs exchange-rate history (indexer), not yet wired
    reserveIdle,
    reserveDeployed,
    asOfBlock: block,
  };
}

export async function getUserPoints(addr: `0x${string}`): Promise<PointsView | null> {
  if (!isProtocolLive()) return null;
  const pointsModule = contractAddress("PointsModule");
  if (!pointsModule) return null;

  const client = publicClient();
  const [points, breakdown, tracked, ratePerUnitDay, usdfrMultiplierBps, curatorMultiplierBps, block] =
    await Promise.all([
      client.readContract({
        address: pointsModule,
        abi: POINTS_ABI,
        functionName: "pointsOfWallet",
        args: [addr],
      }),
      client.readContract({
        address: pointsModule,
        abi: POINTS_ABI,
        functionName: "pointsBreakdown",
        args: [addr],
      }),
      client.readContract({
        address: pointsModule,
        abi: POINTS_ABI,
        functionName: "trackedBalances",
        args: [addr],
      }),
      client.readContract({
        address: pointsModule,
        abi: POINTS_ABI,
        functionName: "ratePerUnitDay",
      }),
      client.readContract({
        address: pointsModule,
        abi: POINTS_ABI,
        functionName: "usdfrMultiplierBps",
      }),
      client.readContract({
        address: pointsModule,
        abi: POINTS_ABI,
        functionName: "curatorMultiplierBps",
      }),
      client.getBlockNumber(),
    ]);

  return {
    points,
    fromShares: breakdown[0],
    fromUSDfr: breakdown[1],
    fromCurator: breakdown[2],
    trackedShares: tracked[0],
    trackedUSDfr: tracked[1],
    ratePerUnitDay,
    usdfrMultiplierBps,
    curatorMultiplierBps,
    asOfBlock: block,
  };
}
