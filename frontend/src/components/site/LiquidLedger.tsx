import type { CSSProperties } from "react";

export type LiquidScene =
  | "overview"
  | "transparency"
  | "how-to"
  | "markets"
  | "sectors";

type Vessel = {
  label: string;
  level: number;
  tone: "deep" | "mid" | "light";
  tag?: string;
};

const SCENES: Record<LiquidScene, { label: string; vessels: Vessel[] }> = {
  overview: {
    label: "The three-layer loss cascade",
    vessels: [
      { label: "Curator first-loss", level: 42, tone: "deep", tag: "Absorbs first" },
      { label: "sGROVE USDfr reserve", level: 84, tone: "mid", tag: "Second layer" },
      { label: "sUSDfr principal", level: 84, tone: "light", tag: "Last" },
    ],
  },
  transparency: {
    label: "USDfr supply compared with backing",
    vessels: [
      { label: "USDfr supply", level: 78, tone: "deep", tag: "Supply" },
      { label: "Backing", level: 78, tone: "mid", tag: "Supply ≤ backing" },
    ],
  },
  "how-to": {
    label: "USDC becomes USDfr, then a staked sUSDfr position",
    vessels: [
      { label: "USDC", level: 70, tone: "light", tag: "Connect" },
      { label: "USDfr", level: 70, tone: "mid", tag: "Mint" },
      { label: "sUSDfr", level: 88, tone: "deep", tag: "Stake + accrue" },
    ],
  },
  markets: {
    label: "Lend USDC or borrow against sUSDfr",
    vessels: [
      { label: "USDC lent", level: 80, tone: "light", tag: "Lend" },
      { label: "USDC borrowed", level: 49, tone: "mid" },
      { label: "sUSDfr collateral", level: 80, tone: "deep", tag: "Borrow against" },
    ],
  },
  sectors: {
    label: "Forest Road's three lending sectors",
    vessels: [
      { label: "Media", level: 80, tone: "deep", tag: "Receivable-backed" },
      { label: "Renewables", level: 80, tone: "mid", tag: "Receivable-backed" },
      { label: "Digital Assets", level: 80, tone: "light", tag: "Marked to market" },
    ],
  },
};

export function LiquidLedger({
  scene,
  compact = false,
}: {
  scene: LiquidScene;
  compact?: boolean;
}) {
  const config = SCENES[scene];
  return (
    <figure
      className={`liquid-ledger ${compact ? "liquid-ledger--compact" : ""}`}
      aria-label={config.label}
      data-viewport-replay=""
      data-viewport-reveal={compact ? undefined : ""}
    >
      <div className="liquid-ledger__vessels">
        {config.vessels.map((vessel, index) => (
          <div
            key={vessel.label}
            className="liquid-ledger__item"
            style={{ "--vessel-delay": `${index * 160}ms` } as CSSProperties}
          >
            {vessel.tag ? <span className="liquid-ledger__tag">{vessel.tag}</span> : null}
            <span
              className={`liquid-vessel liquid-vessel--${vessel.tone}`}
              style={{ "--liquid-level": `${vessel.level}%` } as CSSProperties}
              aria-hidden
            >
              <span className="liquid-vessel__fill" />
              <span className="liquid-vessel__shine" />
            </span>
            <figcaption>{vessel.label}</figcaption>
          </div>
        ))}
      </div>
      <span className="liquid-ledger__axis" aria-hidden />
    </figure>
  );
}
