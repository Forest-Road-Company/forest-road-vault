"use client";

/** Wrong-network banner for the chain selected at build time. */

import {useAccount, useSwitchChain} from "wagmi";
import {NETWORK_NAME} from "@/config/contracts";
import {EXPECTED_CHAIN} from "@/lib/wagmi";

export function NetworkBanner() {
  const {isConnected, chainId} = useAccount();
  const {switchChain, isPending, error} = useSwitchChain();

  if (!isConnected || chainId === EXPECTED_CHAIN.id) return null;

  return (
    <div className="mt-6 rounded-card border border-warn/40 bg-warn/10 px-5 py-3.5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-[13.5px] text-ink">
          <span className="font-medium">Wrong network.</span>{" "}
          <span className="text-ink-muted">
            This build runs on {NETWORK_NAME} — your wallet is on chain {chainId}.
          </span>
        </p>
        <button
          onClick={() => switchChain({chainId: EXPECTED_CHAIN.id})}
          disabled={isPending}
          className="rounded-pill bg-warn px-4 py-1.5 text-[12.5px] font-medium text-raised transition-transform hover:scale-[1.02] disabled:opacity-60"
        >
          {isPending ? "Switching…" : `Switch to ${NETWORK_NAME}`}
        </button>
      </div>
      {!isPending && error ? (
        <p className="mt-2 text-[12px] text-danger">
          Switch failed: {error.message.split("\n")[0]} — switch to {NETWORK_NAME} manually in your wallet.
        </p>
      ) : null}
    </div>
  );
}
