import type { CSSProperties, ReactNode } from "react";

export type ProtocolSceneName =
  | "capital"
  | "lifecycle"
  | "transparency"
  | "markets"
  | "sectors"
  | "risk"
  | "docs";

const style = (values: Record<string, string | number>) => values as CSSProperties;

function FlowDot({ path, delay = 0 }: { path: string; delay?: number }) {
  return (
    <span
      className="protocol-flow-dot"
      style={style({ "--flow-path": `path('${path}')`, "--flow-delay": `${delay}s` })}
      aria-hidden
    />
  );
}

function Node({ label, note, tone = "mid" }: { label: string; note?: string; tone?: "light" | "mid" | "deep" }) {
  return (
    <span className={`protocol-node protocol-node--${tone}`}>
      <strong>{label}</strong>
      {note ? <small>{note}</small> : null}
    </span>
  );
}

function Frame({ label, children, compact }: { label: string; children: ReactNode; compact: boolean }) {
  return (
    <figure
      className={`protocol-scene protocol-scene--${compact ? "compact" : "hero"}`}
      aria-label={label}
      data-viewport-replay=""
      data-viewport-reveal={compact ? undefined : ""}
    >
      <span className="protocol-scene__grid" aria-hidden />
      <span className="protocol-scene__scan" aria-hidden />
      {children}
    </figure>
  );
}

function CapitalScene({ compact }: { compact: boolean }) {
  const path = compact ? "M 24 104 C 92 24, 222 24, 292 104 S 492 184, 556 96" : "M 32 170 C 128 54, 276 54, 364 168 S 612 282, 718 148";
  return (
    <Frame label="Capital moves from reserve through USDfr and sUSDfr into identified loans, then repayments return to the vault" compact={compact}>
      <div className="protocol-capital">
        <svg viewBox={compact ? "0 0 580 220" : "0 0 750 340"} preserveAspectRatio="none" aria-hidden>
          <path className="protocol-trace protocol-trace--ghost" d={path} />
          <path className="protocol-trace" d={path} />
        </svg>
        <FlowDot path={path} />
        <FlowDot path={path} delay={-2.4} />
        <FlowDot path={path} delay={-4.8} />
        <div className="protocol-capital__nodes">
          <Node label="USDC" note="reserve" tone="light" />
          <Node label="USDfr" note="credit-backed" tone="mid" />
          <Node label="sUSDfr" note="vault shares" tone="deep" />
          <Node label="Credit book" note="identified loans" tone="mid" />
          <Node label="Repayment" note="principal + interest" tone="light" />
        </div>
      </div>
      <figcaption className="protocol-scene__caption">
        <span>Capital path</span>
        <span className="protocol-scene__live"><i /> synchronized records</span>
      </figcaption>
    </Frame>
  );
}

function LifecycleScene({ compact }: { compact: boolean }) {
  const steps = [
    ["01", "Deposit", "USDC enters reserve"],
    ["02", "Mint", "USDfr issued 1:1"],
    ["03", "Stake", "sUSDfr reflects net book performance"],
    ["04", "Exit", "queue settles from cash"],
  ] as const;
  return (
    <Frame label="The depositor lifecycle from USDC deposit to USDfr, sUSDfr and the redemption queue" compact={compact}>
      <div className="protocol-lifecycle">
        <span className="protocol-lifecycle__rail" aria-hidden><i /><i /><i /></span>
        {steps.map(([index, title, note]) => (
          <div className="protocol-lifecycle__step" key={title}>
            <span>{index}</span>
            <strong>{title}</strong>
            <small>{note}</small>
          </div>
        ))}
      </div>
      <div className="protocol-records">
        <span><i /> On-chain state</span>
        <span><i /> Legal record</span>
        <b>kept in step</b>
      </div>
    </Frame>
  );
}

function TransparencyScene({ compact }: { compact: boolean }) {
  return (
    <Frame label="Conceptual reconciliation: USDfr supply cannot exceed recognized backing, which includes reserves and deployed principal; see the dashboard for live values" compact={compact}>
      <div className="protocol-reconcile">
        <div className="protocol-reconcile__metric">
          <span>USDfr supply</span><strong>On-chain</strong>
          <i><b style={style({ "--meter": "74%" })} /></i>
        </div>
        <div className="protocol-reconcile__mark" aria-hidden>
          <span /><em>≤</em><span />
        </div>
        <div className="protocol-reconcile__metric">
          <span>Backing value</span><strong>On-chain</strong>
          <i><b style={style({ "--meter": "74%" })} /></i>
        </div>
      </div>
      <div className="protocol-backing-mix">
        <b><i /> contract invariant holding</b>
        <div className="protocol-backing-mix__bar">
          <span style={style({ "--mix": "64%" })}>Idle reserve</span>
          <span style={style({ "--mix": "36%" })}>Deployed principal</span>
        </div>
      </div>
    </Frame>
  );
}

function MarketsScene({ compact }: { compact: boolean }) {
  return (
    <Frame label="Morpho market flow: lenders supply USDC while borrowers post sUSDfr collateral and borrow USDC" compact={compact}>
      <div className="protocol-market">
        <div className="protocol-market__lane protocol-market__lane--lend">
          <span className="protocol-market__person">Lender</span>
          <span className="protocol-market__flow"><i /><i /></span>
          <strong>USDC</strong>
        </div>
        <div className="protocol-market__hub">
          <span className="protocol-market__ring"><i /></span>
          <span className="protocol-market__label">
            <strong>Morpho</strong>
            <small>USDC / sUSDfr</small>
          </span>
        </div>
        <div className="protocol-market__lane protocol-market__lane--borrow">
          <strong>sUSDfr</strong>
          <span className="protocol-market__flow"><i /><i /></span>
          <span className="protocol-market__person">Borrower</span>
        </div>
      </div>
      <div className="protocol-market__legend"><span>Lend USDC</span><span>Variable utilization</span><span>Borrow against collateral</span></div>
    </Frame>
  );
}

function SectorGlyph({ kind }: { kind: "media" | "energy" | "digital" }) {
  if (kind === "media") {
    return <svg viewBox="0 0 64 64" aria-hidden><rect x="10" y="24" width="44" height="29" rx="3"/><path d="M11 24 19 11h10l-8 13m12 0 8-13h10l-8 13M18 34h28M18 42h21"/></svg>;
  }
  if (kind === "energy") {
    return <svg viewBox="0 0 64 64" aria-hidden><circle cx="32" cy="26" r="10"/><path d="M32 6v7m0 26v7M12 26h7m26 0h7M18 12l5 5m18 18 5 5m0-28-5 5M23 35l-5 5M16 54h32M22 54l4-13h12l4 13"/></svg>;
  }
  return <svg viewBox="0 0 64 64" aria-hidden><path d="M32 7 52 18v28L32 57 12 46V18Z"/><path d="M32 17v30m-8-23c0-4 4-6 8-6s8 2 8 5-4 4-8 5-8 2-8 6 4 6 8 6 8-2 8-6"/></svg>;
}

function SectorsScene({ compact }: { compact: boolean }) {
  const sectors = [
    ["media", "Media", "assigned receivables"],
    ["energy", "Renewables", "tax-credit claims"],
    ["digital", "Digital Assets", "marked to market"],
  ] as const;
  return (
    <Frame label="Three collateral sectors feed one identified loan book" compact={compact}>
      <div className="protocol-sectors">
        {sectors.map(([kind, label, note], index) => (
          <div key={kind} className={`protocol-sector protocol-sector--${kind}`} style={style({ "--sector-delay": `${index * -1.8}s` })}>
            <SectorGlyph kind={kind} />
            <strong>{label}</strong><small>{note}</small><span><i /></span>
          </div>
        ))}
      </div>
      <div className="protocol-sectors__book"><span /><strong>One loan book</strong><small>class limits enforced on-chain</small></div>
    </Frame>
  );
}

function RiskScene({ compact }: { compact: boolean }) {
  return (
    <Frame label="Losses move through curator first-loss, then the separate USDfr coverage reserve held by the sGROVE contract, and only then sUSDfr principal" compact={compact}>
      <div className="protocol-risk">
        <div className="protocol-risk__signal"><span>realised loss</span><i /></div>
        {[
          ["01", "Curator first-loss", "absorbs first"],
          ["02", "sGROVE USDfr reserve", "absorbs second"],
          ["03", "sUSDfr principal", "last"],
        ].map(([n, label, note], index) => (
          <div key={n} className={`protocol-risk__layer protocol-risk__layer--${index + 1}`}>
            <span>{n}</span><strong>{label}</strong><small>{note}</small><i />
          </div>
        ))}
      </div>
    </Frame>
  );
}

function DocsScene({ compact }: { compact: boolean }) {
  return (
    <Frame label="Documentation connects protocol claims to verified contracts, audit findings and live state" compact={compact}>
      <div className="protocol-docs">
        <div className="protocol-docs__paper"><span /><span /><span /><span /></div>
        <div className="protocol-docs__link"><i /><i /><i /></div>
        <div className="protocol-docs__proof">
          <span><i /> Contracts</span><span><i /> Audits</span><span><i /> Live state</span>
        </div>
      </div>
      <figcaption className="protocol-scene__caption"><span>Claims</span><b>reconcile to evidence</b><span>Proof</span></figcaption>
    </Frame>
  );
}

export function ProtocolScene({ scene, compact = false }: { scene: ProtocolSceneName; compact?: boolean }) {
  if (scene === "capital") return <CapitalScene compact={compact} />;
  if (scene === "lifecycle") return <LifecycleScene compact={compact} />;
  if (scene === "transparency") return <TransparencyScene compact={compact} />;
  if (scene === "markets") return <MarketsScene compact={compact} />;
  if (scene === "sectors") return <SectorsScene compact={compact} />;
  if (scene === "risk") return <RiskScene compact={compact} />;
  return <DocsScene compact={compact} />;
}
