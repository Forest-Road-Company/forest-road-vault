"use client";

/**
 * Wallet connect/disconnect. Browser wallets are discovered through EIP-6963;
 * production/testnet builds also offer WalletConnect when a public Reown project
 * ID is configured. When several options exist, a small chooser opens.
 */

import {useState} from "react";
import {useAccount, useConnect, useConnectors, useDisconnect} from "wagmi";
import {shortAddress} from "@/lib/format";

export function visibleWalletChoices<T extends {id: string}>(
  connectors: readonly T[],
): T[] {
  const walletConnectChoices = connectors.filter(
    (connector) => connector.id === "walletConnect",
  );
  const browserChoices = connectors.filter(
    (connector) => connector.id !== "walletConnect",
  );
  const discoveredBrowserChoices = browserChoices.filter(
    (connector) => connector.id !== "injected",
  );

  // EIP-6963 usually re-surfaces the configured generic injected connector. Hide
  // only that duplicate; WalletConnect must remain available alongside browsers.
  return [
    ...(discoveredBrowserChoices.length > 0
      ? discoveredBrowserChoices
      : browserChoices),
    ...walletConnectChoices,
  ];
}

export function ConnectControl() {
  const {address, isConnected} = useAccount();
  const {connect, isPending, error} = useConnect();
  const {disconnect} = useDisconnect();
  const connectors = useConnectors();
  const [chooserOpen, setChooserOpen] = useState(false);

  // useConnect reports failures via mutation state, not a throw — a click that
  // silently does nothing (e.g. no wallet installed) would violate fail-loudly.
  const connectError = !isPending && error ? (
    <p className="mt-2 w-full text-[12px] leading-snug text-danger">
      {(error as {name?: string}).name === "ProviderNotFoundError"
        ? "No browser wallet found — install one (e.g. MetaMask or Rabby) and reload."
        : ("shortMessage" in error ? (error.shortMessage as string) : error.message)}
    </p>
  ) : null;

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-2.5">
        <span className="rounded-pill border border-line bg-raised px-3.5 py-1.5 font-mono text-[12px] text-ink">
          {shortAddress(address)}
        </span>
        <button
          onClick={() => disconnect()}
          className="rounded-pill border border-line-strong px-3.5 py-1.5 text-[12.5px] text-ink-muted transition-colors hover:border-danger/50 hover:text-danger"
        >
          Disconnect
        </button>
      </div>
    );
  }

  const choices = visibleWalletChoices(connectors);

  if (choices.length === 0) {
    return (
      <p className="text-[13px] text-ink-muted">
        No wallet option is configured. Install a browser wallet or ask Forest Road to enable
        WalletConnect.
      </p>
    );
  }

  if (choices.length === 1 || !chooserOpen) {
    return (
      <div className="flex flex-wrap items-center">
        <button
          onClick={() =>
            choices.length === 1 ? connect({connector: choices[0]}) : setChooserOpen(true)
          }
          disabled={isPending}
          className="rounded-pill bg-moss px-5 py-2 text-[13.5px] font-medium text-raised transition-transform hover:scale-[1.02] hover:bg-moss-bright disabled:opacity-60"
        >
          {isPending ? "Connecting…" : "Connect wallet"}
        </button>
        {connectError}
      </div>
    );
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      {choices.map((c) => (
        <button
          key={c.uid}
          onClick={() => {
            connect({connector: c});
            setChooserOpen(false);
          }}
          disabled={isPending}
          className="rounded-pill border border-line-strong bg-raised px-4 py-1.5 text-[13px] text-ink transition-colors hover:border-moss/60 disabled:opacity-60"
        >
          {c.name}
        </button>
      ))}
      <button
        onClick={() => setChooserOpen(false)}
        className="px-2 text-[12px] text-ink-faint hover:text-ink-muted"
      >
        cancel
      </button>
      {connectError}
    </div>
  );
}
