"use client";

/**
 * Get USDfr: the first write card on /app.
 *
 * On Ethereum mainnet it has two tabs. Buy (the default for every address, KYC-verified or not)
 * swaps USDC for USDfr through the third-party Uniswap pool on this page; Mint 1:1 is the
 * KYC-gated primary mint, unchanged. A testnet has no pool, so it keeps the mint card alone.
 *
 * Both panels stay mounted and the inactive one is hidden, so switching tabs never orphans a
 * write in flight or discards what was typed.
 */

import {useId, useRef, useState, type KeyboardEvent} from "react";
import {IS_TESTNET} from "@/config/contracts";
import {BuyUsdfrPanel} from "@/components/app/BuyUsdfrPanel";
import {MintCard, MintForm} from "@/components/app/MintCard";

type GetUsdfrTab = "buy" | "mint";

const TABS: readonly {id: GetUsdfrTab; label: string}[] = [
  {id: "buy", label: "Buy"},
  {id: "mint", label: "Mint 1:1"},
];

export function GetUsdfrCard({writesEnabled, chainOk}: {writesEnabled: boolean; chainOk: boolean}) {
  if (IS_TESTNET) return <MintCard writesEnabled={writesEnabled} chainOk={chainOk} />;
  return <GetUsdfrTabs writesEnabled={writesEnabled} chainOk={chainOk} />;
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
    <div className="panel flex h-full flex-col p-6">
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
                className={`rounded-pill px-3 py-1 text-[11px] font-semibold tracking-[0.02em] transition-colors ${
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
        <BuyUsdfrPanel chainOk={chainOk} active={tab === "buy"} onShowMint={() => select("mint")} />
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
