"use client";

/**
 * The app surface: connect state, network guard, KYC gate, and the three write
 * cards. Gate semantics (2026-07-14 compliance re-architecture): a non-KYC address
 * can connect, hold, view, transfer AND stake — only the primary-market mint and
 * instant-redeem writes are KYC-gated. The contracts enforce exactly this on-chain
 * (KYC at mint/redeem; sanctions-only on transfers; permissionless vault deposit);
 * the UI never pretends otherwise.
 */

import {useEffect, useState} from "react";
import {useAccount, usePublicClient, useReadContract, useWalletClient} from "wagmi";
import {CONTRACTS, IS_LOCAL_FORK, IS_TESTNET, NETWORK_NAME} from "@/config/contracts";
import {COMPLIANCE_ABI} from "@/lib/abi";
import {EXPECTED_CHAIN} from "@/lib/wagmi";
import {probeRpcAlignment, type RpcRequest} from "@/lib/rpcAlignment";
import {ConnectControl} from "@/components/app/ConnectControl";
import {NetworkBanner} from "@/components/app/NetworkBanner";
import {MintCard} from "@/components/app/MintCard";
import {StakeCard} from "@/components/app/StakeCard";
import {RedeemCard} from "@/components/app/RedeemCard";
import {YieldPositionPanel} from "@/components/app/YieldPositionPanel";

const POLL = {refetchInterval: 30_000} as const;
const RPC_ALIGNMENT_POLL_MS = 15_000;

type RpcAlignment =
  | {phase: "idle"}
  | {phase: "checking"}
  | {phase: "aligned"}
  | {phase: "mismatch"; message: string};

export function AppSurface() {
  const {address, isConnected, chainId} = useAccount();
  const publicClient = usePublicClient();
  const {data: walletClient} = useWalletClient();
  const rightNetwork = chainId === EXPECTED_CHAIN.id;
  const [rpcAlignment, setRpcAlignment] = useState<RpcAlignment>({phase: "idle"});

  useEffect(() => {
    let cancelled = false;

    async function checkRpcAlignment(showChecking: boolean) {
      if (!isConnected || !rightNetwork || !publicClient || !walletClient) {
        setRpcAlignment({phase: "idle"});
        return;
      }

      if (showChecking) setRpcAlignment({phase: "checking"});

      const result = await probeRpcAlignment(
        publicClient.request as RpcRequest,
        walletClient.transport.request as RpcRequest,
        {
          expectedChainId: EXPECTED_CHAIN.id,
          requireExactTip: IS_LOCAL_FORK,
        },
      );
      if (cancelled) return;
      setRpcAlignment(
        result.aligned
          ? {phase: "aligned"}
          : {phase: "mismatch", message: result.message},
      );
    }

    void checkRpcAlignment(true);
    const interval = window.setInterval(() => {
      void checkRpcAlignment(false);
    }, RPC_ALIGNMENT_POLL_MS);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [isConnected, publicClient, rightNetwork, walletClient]);

  const rpcReady = rpcAlignment.phase === "aligned";

  const {data: kycAllowed, isLoading: kycLoading, isError: kycError} = useReadContract({
    address: CONTRACTS.ComplianceRegistry!,
    abi: COMPLIANCE_ABI,
    functionName: "isAllowed",
    args: address ? [address] : undefined,
    query: {enabled: Boolean(address) && rightNetwork && rpcReady, ...POLL},
  });

  /** Connected on the configured chain — enough for actions the contracts leave un-gated
   *  (faucet, queue request/claim). */
  const chainOk = isConnected && rightNetwork && rpcReady;
  /** KYC-gated actions (mint, instant redeem only) — mirrors the on-chain primary gate.
   *  Staking (vault deposit) is permissionless on-chain, so it uses chainOk, not this. */
  const writesEnabled = chainOk && kycAllowed === true;

  return (
    <div className="mt-10">
      {/* ── Connect row ──────────────────────────────────────────────── */}
      <div className="flex flex-wrap items-center justify-between gap-4 rounded-card border border-line bg-raised/70 px-5 py-4">
        <ConnectControl />
        {isConnected ? (
          rightNetwork && !rpcReady ? (
            <span className="rounded-pill border border-line-strong px-3.5 py-1.5 font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-faint">
              {rpcAlignment.phase === "checking" ? "checking RPC…" : "RPC check required"}
            </span>
          ) : (
          kycLoading ? (
            <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-ink-faint">
              checking KYC…
            </span>
          ) : kycAllowed === true ? (
            <span className="rounded-pill border border-moss/30 bg-moss-faint px-3.5 py-1.5 font-mono text-[10.5px] uppercase tracking-[0.14em] text-moss">
              KYC verified
            </span>
          ) : kycAllowed === false ? (
            <span className="rounded-pill border border-warn/40 bg-warn/10 px-3.5 py-1.5 font-mono text-[10.5px] uppercase tracking-[0.14em] text-warn">
              not KYC-verified
            </span>
          ) : kycError ? (
            // A failed read is NOT a verdict — never assert non-verification we
            // haven't determined.
            <span className="rounded-pill border border-line-strong px-3.5 py-1.5 font-mono text-[10.5px] uppercase tracking-[0.14em] text-ink-faint">
              KYC check unavailable
            </span>
          ) : null
          )
        ) : (
          <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-ink-faint">
            {NETWORK_NAME}
          </span>
        )}
      </div>

      <NetworkBanner />

      {rpcAlignment.phase === "mismatch" ? (
        <div className="mt-6 rounded-card border border-warn/40 bg-warn/10 px-5 py-3.5">
          <p className="text-[13.5px] leading-relaxed text-ink">
            <span className="font-medium">RPC mismatch.</span>{" "}
            <span className="text-ink-muted">{rpcAlignment.message}</span>
          </p>
        </div>
      ) : null}

      {isConnected && !kycLoading && kycAllowed === false ? (
        <div className="mt-6 rounded-card border border-warn/40 bg-warn/10 px-5 py-3.5">
          <p className="text-[13.5px] leading-relaxed text-ink">
            <span className="font-medium">This address is not KYC-verified.</span>{" "}
            <span className="text-ink-muted">
              You can hold, view, transfer, and even stake freely — and existing sUSDfr
              can exit through the redemption queue. Only mint and instant redeem are
              disabled, and the contracts enforce that on-chain, not just here. Contact
              Forest Road to complete the applicable onboarding process for this address.
            </span>
          </p>
        </div>
      ) : null}

      {!isConnected ? (
        <p className="mt-6 text-[13.5px] leading-relaxed text-ink-muted">
          Connect a wallet on {NETWORK_NAME} to use the write paths. Everything below stays
          visible without one — reads are public.
        </p>
      ) : null}

      <YieldPositionPanel />

      {/* ── Write cards ──────────────────────────────────────────────── */}
      <div className="mt-8 grid gap-5 lg:grid-cols-3">
        <MintCard writesEnabled={writesEnabled} chainOk={chainOk} />
        {/* Staking is permissionless on-chain (2026-07-14) — gate on network only, not KYC. */}
        <StakeCard writesEnabled={chainOk} />
        <RedeemCard writesEnabled={writesEnabled} chainOk={chainOk} />
      </div>

      <p className="mt-8 text-[12px] leading-relaxed text-ink-faint">
        Every action simulates against live chain state before your wallet opens; failures
        surface the contract&apos;s own error, decoded.{" "}
        {IS_TESTNET
          ? "Sepolia testnet tokens carry no value."
          : "Transactions use real assets on Ethereum mainnet; verify every wallet prompt carefully."}{" "}
        Nothing here is legal, tax, or investment advice or an offer of securities.
      </p>
    </div>
  );
}
