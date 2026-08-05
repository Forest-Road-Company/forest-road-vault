"use client";

/**
 * Hero stat strip — LIVE Sepolia reads (replaces the 2026-07-09 illustrative
 * figures now that real state exists on-chain). Anything not honestly derivable
 * from chain state (e.g. trailing yield, which needs rate history) is not shown.
 * Values render "—" until the reads resolve; nothing is simulated.
 */

import {useReadContracts} from "wagmi";
import {CONTRACTS, IS_LOCAL_FORK, IS_TESTNET, NETWORK_NAME} from "@/config/contracts";
import {BRIDGE_ABI, ERC20_ABI, RESERVES_ABI} from "@/lib/abi";
import {fmtAmount} from "@/lib/format";

export function HeroLiveStats() {
  const {data} = useReadContracts({
    query: {refetchInterval: 60_000},
    contracts: [
      {address: CONTRACTS.USDfr!, abi: ERC20_ABI, functionName: "totalSupply"},
      {address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "totalBackingValue"},
      {address: CONTRACTS.ClaimBridge!, abi: BRIDGE_ABI, functionName: "totalOriginated"},
    ],
  });

  const [supply, backing, facilities] = [
    data?.[0]?.result as bigint | undefined,
    data?.[1]?.result as bigint | undefined,
    data?.[2]?.result as bigint | undefined,
  ];

  const stats = [
    {label: "USDfr supply", value: supply !== undefined ? fmtAmount(supply, 18, 0) : "—"},
    {label: "Total backing", value: backing !== undefined ? `$${fmtAmount(backing, 18, 0)}` : "—"},
    {label: "Facilities originated", value: facilities !== undefined ? facilities.toString() : "—"},
    {label: "Collateral classes", value: "5"},
  ];

  return (
    <div className="mt-12 flex flex-wrap items-center gap-x-8 gap-y-3 border-t border-cream/20 pt-5">
      {stats.map((s) => (
        <p key={s.label} className="font-mono text-[11px] uppercase tracking-[0.16em] text-cream/70">
          {s.label}: <span className="text-cream">{s.value}</span>
        </p>
      ))}
      <p className="font-mono text-[10px] tracking-[0.08em] text-cream/45">
        {IS_LOCAL_FORK ? "disposable" : "live"} {NETWORK_NAME} data
        {IS_TESTNET ? " — test tokens, no real value" : ""}
      </p>
    </div>
  );
}
