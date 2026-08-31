"use client";

/**
 * Hero figure strip.
 *
 * The headline figures are the ones that are structurally true at any scale —
 * how the book is divided and how many layers of capital sit ahead of a
 * depositor — derived from the same data the rest of the site renders, so they
 * cannot drift from it.
 *
 * The live Sepolia reads follow as a secondary line rather than leading. They
 * are deliberately still on the page: a testnet book holding ten dollars is not
 * something this site hides. What it should not do is open with that number as
 * the protocol's headline claim.
 *
 * Anything not honestly derivable from chain state (e.g. trailing yield, which
 * needs rate history) is not shown. Live values render "—" until the reads
 * resolve; nothing is simulated.
 */

import { useReadContracts } from "wagmi";
import {
  CONTRACTS,
  IS_LOCAL_FORK,
  IS_TESTNET,
  NETWORK_NAME,
} from "@/config/contracts";
import { BRIDGE_ABI, ERC20_ABI, RESERVES_ABI } from "@/lib/abi";
import { fmtAmount } from "@/lib/format";
import { SECTORS } from "@/lib/verticals";

/** Layers of capital that absorb a loss before depositor principal. */
const CASCADE_LAYERS = 2;

const receivable = SECTORS.filter(
  (v) => v.collateralModel === "receivable",
).length;
const markedToMarket = SECTORS.length - receivable;

const STRUCTURE = [
  { value: SECTORS.length, label: "Sectors" },
  { value: receivable, label: "Receivable-backed" },
  { value: markedToMarket, label: "Marked-to-market" },
  { value: CASCADE_LAYERS, label: "Layers ahead of depositors" },
];

export function HeroLiveStats() {
  const { data } = useReadContracts({
    query: { refetchInterval: 60_000 },
    contracts: [
      { address: CONTRACTS.USDfr!, abi: ERC20_ABI, functionName: "totalSupply" },
      {
        address: CONTRACTS.ReserveManager!,
        abi: RESERVES_ABI,
        functionName: "totalBackingValue",
      },
      {
        address: CONTRACTS.ClaimBridge!,
        abi: BRIDGE_ABI,
        functionName: "totalOriginated",
      },
    ],
  });

  const [supply, backing, facilities] = [
    data?.[0]?.result as bigint | undefined,
    data?.[1]?.result as bigint | undefined,
    data?.[2]?.result as bigint | undefined,
  ];

  const live = [
    {
      label: "supply",
      value: supply !== undefined ? `${fmtAmount(supply, 18, 0)} USDfr` : "—",
    },
    {
      label: "backing",
      value: backing !== undefined ? `$${fmtAmount(backing, 18, 0)}` : "—",
    },
    {
      label: "facilities",
      value: facilities !== undefined ? facilities.toString() : "—",
    },
  ];

  return (
    <div className="mt-14">
      <div className="rule-draw h-px w-full bg-on-navy-line" />
      <dl className="mt-6 flex flex-wrap gap-x-12 gap-y-7">
        {/* A div in a dl must hold its dt before its dd, so the term leads in
            the DOM and the figure is ordered above it visually. Emitting the
            value first would announce a figure with no term in front of it. */}
        {STRUCTURE.map((s) => (
          <div key={s.label} className="flex flex-col">
            <dt className="running-head order-2 mt-2.5">{s.label}</dt>
            <dd
              data-figure
              className="display order-1 text-[32px] leading-none text-on-navy md:text-[38px]"
            >
              {s.value}
            </dd>
          </div>
        ))}
      </dl>

      <p className="mt-7 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[13px] text-on-navy-faint">
        <span
          className="h-1.5 w-1.5 flex-none rounded-full bg-on-navy-accent"
          aria-hidden
        />
        <span>
          {IS_LOCAL_FORK ? "Disposable" : "Live"} {NETWORK_NAME}:
        </span>
        {live.map((l) => (
          <span key={l.label}>
            <span data-figure className="text-on-navy-muted">
              {l.value}
            </span>{" "}
            {l.label}
          </span>
        ))}
        <span>
          · refreshed every 60s
          {IS_TESTNET ? " · test tokens, no real value" : ""}
        </span>
      </p>
    </div>
  );
}
