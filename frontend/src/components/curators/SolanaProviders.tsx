"use client";

import { WalletAdapterNetwork } from "@solana/wallet-adapter-base";
import { ConnectionProvider, WalletProvider } from "@solana/wallet-adapter-react";
import { WalletConnectWalletAdapter } from "@solana/wallet-adapter-walletconnect";
import type { ReactNode } from "react";
import { useMemo } from "react";
import { CURATOR_VAULT } from "@/config/curatorVault";
import { walletMetadata } from "@/lib/walletMetadata";

/**
 * Solana connection and wallet context for the curator surface only.
 *
 * Browser-extension wallets (Phantom, Solflare, Backpack, Ledger-backed) are discovered through
 * the Wallet Standard and need no adapter here. WalletConnect covers the other case, a wallet on
 * a phone reached by QR code from a desktop page; it is offered only when the Reown project id
 * the rest of the site already uses is present. Nothing auto-connects: a visitor reading the
 * programme page is never prompted by a wallet they did not ask for.
 */
const walletConnectProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim();
const WALLETCONNECT_READY = Boolean(walletConnectProjectId && /^[0-9a-f]{32}$/i.test(walletConnectProjectId));

export function SolanaProviders({ children }: { children: ReactNode }) {
  const wallets = useMemo(
    () =>
      WALLETCONNECT_READY
        ? [
            new WalletConnectWalletAdapter({
              network: CURATOR_VAULT.isDevnet ? WalletAdapterNetwork.Devnet : WalletAdapterNetwork.Mainnet,
              options: {
                projectId: walletConnectProjectId as string,
                metadata: walletMetadata(),
              },
            }),
          ]
        : [],
    [],
  );
  return (
    <ConnectionProvider endpoint={CURATOR_VAULT.rpcUrl} config={{ commitment: "confirmed" }}>
      <WalletProvider wallets={wallets} autoConnect={false}>
        {children}
      </WalletProvider>
    </ConnectionProvider>
  );
}
