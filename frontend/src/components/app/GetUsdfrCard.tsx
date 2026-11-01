"use client";

/**
 * Get USDfr: the first write card on /app.
 *
 * It always has two tabs so the staging design and the production application share the same
 * information architecture. Buy is the default for every address. On Ethereum mainnet it swaps
 * USDC for USDfr through the third-party Uniswap pool on this page; on a testnet the same tab is
 * an explicit, non-transactional preview because no Sepolia pool exists. Mint 1:1 remains the
 * KYC-gated primary mint and is the usable route on testnet.
 *
 * Both panels stay mounted and the inactive one is hidden, so switching tabs never orphans a
 * write in flight or discards what was typed.
 */

import {useId, useRef, useState, type KeyboardEvent} from "react";
import {IS_TESTNET} from "@/config/contracts";
import {BuyUsdfrPanel} from "@/components/app/BuyUsdfrPanel";
import {MintForm} from "@/components/app/MintCard";

type GetUsdfrTab = "buy" | "mint";

const TABS: readonly {id: GetUsdfrTab; label: string}[] = [
  {id: "buy", label: "Buy"},
  {id: "mint", label: "Mint 1:1"},
];

export function GetUsdfrCard({writesEnabled, chainOk}: {writesEnabled: boolean; chainOk: boolean}) {
  return <GetUsdfrTabs writesEnabled={writesEnabled} chainOk={chainOk} />;
}

function TestnetBuyPreview({onShowMint}: {onShowMint: () => void}) {
  return (
    <>
      <p className="mt-3 text-[13px] leading-relaxed text-ink-muted">
        Buy USDfr with USDC through the USDfr/USDC Uniswap v4 pool. Open to any eligible address;
        KYC is not required for the secondary-market route.
      </p>

      <div
        className="action-card-route action-card-route--buy mt-5"
        aria-label="USDC routes through the Uniswap v4 pool and returns USDfr"
      >
        <span><b>USDC</b><small>you pay</small></span>
        <i aria-hidden><em /></i>
        <span className="action-card-route__core"><b>v4</b><small>Uniswap pool</small></span>
        <i aria-hidden><em /></i>
        <span><b>USDfr</b><small>you receive</small></span>
      </div>

      <div className="op-field mt-5 px-4 py-3" data-disabled="true">
        <div className="flex items-center justify-between gap-3">
          <span className="font-mono text-[15px] text-ink-faint">0.00</span>
          <span className="text-[12.5px] font-semibold text-ink-faint">USDC</span>
        </div>
      </div>
      <dl className="mt-3 space-y-2 border-y border-line py-3 text-[11.5px] text-ink-faint">
        <div className="flex items-center justify-between gap-4">
          <dt>Live pool quote</dt><dd className="font-mono text-ink-muted">Ethereum mainnet</dd>
        </div>
        <div className="flex items-center justify-between gap-4">
          <dt>Route</dt><dd className="font-mono text-ink-muted">USDC → USDfr</dd>
        </div>
        <div className="flex items-center justify-between gap-4">
          <dt>Execution</dt><dd className="font-mono text-ink-muted">Uniswap v4</dd>
        </div>
      </dl>

      <button type="button" disabled className="op-action mt-4 w-full px-5 py-2.5 text-[13.5px]">
        Buy available on Ethereum mainnet
      </button>
      <p className="mt-3 text-[11.5px] leading-relaxed text-ink-faint">
        This design-staging build reads Sepolia, where the production pool does not exist. It never
        redirects a testnet transaction to mainnet or presents an illustrative quote as live.
      </p>
      <button type="button" onClick={onShowMint} className="u-link mt-auto min-h-10 pt-4 text-left text-[12px] text-ink">
        Use the Sepolia Mint 1:1 flow instead →
      </button>
    </>
  );
}

function GetUsdfrTabs({writesEnabled, chainOk}: {writesEnabled: boolean; chainOk: boolean}) {
  // Buy is selected on load for everyone. Most visitors are not KYC-verified, and nothing about
  // the connected wallet changes the default.
  const [tab, setTab] = useState<GetUsdfrTab>("buy");
  const baseId = useId();
  const titleId = `${baseId}-title`;
  const tabId = (id: GetUsdfrTab) => `${baseId}-tab-${id}`;
  const panelId = (id: GetUsdfrTab) => `${baseId}-panel-${id}`;
  const tabButtons = useRef<Partial<Record<GetUsdfrTab, HTMLButtonElement | null>>>({});

  const select = (id: GetUsdfrTab, moveFocus = false) => {
    setTab(id);
    if (moveFocus) tabButtons.current[id]?.focus();
  };

  // WAI-ARIA tabs with automatic activation: arrows move between tabs and select them, Home
  // and End jump to the ends; Tab leaves the tab list for the open panel.
  const onTabKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    const index = TABS.findIndex((candidate) => candidate.id === tab);
    let next: number | null = null;
    if (event.key === "ArrowRight") next = (index + 1) % TABS.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + TABS.length) % TABS.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = TABS.length - 1;
    if (next === null) return;
    event.preventDefault();
    select(TABS[next].id, true);
  };

  return (
    <div className="panel app-action-card app-action-card--mint flex flex-col p-6" data-viewport-replay="">
      <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <h3 id={titleId} className="font-display text-[16px] font-semibold tracking-tight">
          Get USDfr
        </h3>
        <div role="tablist" aria-labelledby={titleId} className="flex gap-1 rounded-pill border border-line bg-surface p-0.5">
          {TABS.map((candidate) => {
            const selected = tab === candidate.id;
            return (
              <button
                key={candidate.id}
                ref={(node) => {
                  tabButtons.current[candidate.id] = node;
                }}
                id={tabId(candidate.id)}
                type="button"
                role="tab"
                aria-selected={selected}
                aria-controls={panelId(candidate.id)}
                tabIndex={selected ? 0 : -1}
                onClick={() => select(candidate.id)}
                onKeyDown={onTabKeyDown}
                className={`min-h-9 rounded-pill px-3.5 py-2 text-[12px] font-semibold tracking-[0.02em] transition-colors ${
                  selected ? "bg-accent text-raised" : "text-ink-faint hover:text-ink-muted"
                }`}
              >
                {candidate.label}
              </button>
            );
          })}
        </div>
      </div>

      <div
        role="tabpanel"
        id={panelId("buy")}
        aria-labelledby={tabId("buy")}
        hidden={tab !== "buy"}
        className={tab === "buy" ? "flex flex-1 flex-col" : undefined}
      >
        {IS_TESTNET ? (
          <TestnetBuyPreview onShowMint={() => select("mint")} />
        ) : (
          <BuyUsdfrPanel chainOk={chainOk} active={tab === "buy"} onShowMint={() => select("mint")} />
        )}
      </div>
      <div
        role="tabpanel"
        id={panelId("mint")}
        aria-labelledby={tabId("mint")}
        hidden={tab !== "mint"}
        className={tab === "mint" ? "flex flex-1 flex-col" : undefined}
      >
        <MintForm writesEnabled={writesEnabled} chainOk={chainOk} onShowBuy={() => select("buy")} />
      </div>
    </div>
  );
}
