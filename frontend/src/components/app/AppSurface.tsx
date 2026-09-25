"use client";

/**
 * The app surface: connect state, network guard, KYC gate, and the three write
 * cards. Gate semantics (2026-07-14 compliance re-architecture): a non-KYC address
 * can connect, hold, view, transfer AND stake, only the primary-market mint and
 * instant-redeem writes are KYC-gated. The contracts enforce exactly this on-chain
 * (KYC at mint/redeem; sanctions-only on transfers; permissionless vault deposit);
 * the UI never pretends otherwise.
 */

import {useCallback, useEffect, useState} from "react";
import {useAccount, usePublicClient, useReadContract, useWalletClient} from "wagmi";
import {CONTRACTS, IS_LOCAL_FORK, IS_TESTNET, NETWORK_NAME} from "@/config/contracts";
import {COMPLIANCE_ABI} from "@/lib/abi";
import {EXPECTED_CHAIN} from "@/lib/wagmi";
import {probeRpcAlignment, type RpcAlignmentFailure, type RpcRequest} from "@/lib/rpcAlignment";
import {ConnectControl} from "@/components/app/ConnectControl";
import {NetworkBanner} from "@/components/app/NetworkBanner";
import {MintCard} from "@/components/app/MintCard";
import {StakeCard} from "@/components/app/StakeCard";
import {RedeemCard} from "@/components/app/RedeemCard";
import {YieldPositionPanel} from "@/components/app/YieldPositionPanel";

const POLL = {refetchInterval: 30_000} as const;
const RPC_ALIGNMENT_POLL_MS = 15_000;

/**
 * What to do when the wallet reports the right chain but its own RPC fails or disagrees. A
 * switch request cannot help, because the wallet already reports the right chain: this is
 * nearly always a wallet pointed at a custom RPC or a fork for that chain.
 */
const WALLET_RPC_GUIDANCE = IS_LOCAL_FORK
  ? "Point your wallet at the same local fork as the app, then check again."
  : `Your wallet reports ${NETWORK_NAME}, so switching from here cannot fix this. If it uses a custom RPC or a fork for ${NETWORK_NAME}, select the standard ${NETWORK_NAME} network in your wallet, then check again.`;

type RpcAlignment =
  | {phase: "idle"}
  | {phase: "checking"}
  | {phase: "aligned"}
  | {phase: "mismatch"; reason: RpcAlignmentFailure; message: string; walletChainId?: bigint};

export function AppSurface() {
  const {address, isConnected, chainId} = useAccount();
  const publicClient = usePublicClient();
  const {data: walletClient} = useWalletClient();
  const rightNetwork = chainId === EXPECTED_CHAIN.id;
  const [rpcAlignment, setRpcAlignment] = useState<RpcAlignment>({phase: "idle"});
  // Bumped to re-run the probe now rather than at the next poll: after a switch the wallet
  // accepted, or when the person has fixed their wallet and presses "Check again".
  const [recheckRequest, setRecheckRequest] = useState(0);
  const recheckRpc = useCallback(() => setRecheckRequest((n) => n + 1), []);

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
          : result.reason === "wallet-chain"
            ? {
                phase: "mismatch",
                reason: result.reason,
                message: result.message,
                walletChainId: result.walletChainId,
              }
            : {phase: "mismatch", reason: result.reason, message: result.message},
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
  }, [isConnected, publicClient, rightNetwork, walletClient, recheckRequest]);

  const rpcReady = rpcAlignment.phase === "aligned";

  const {data: kycAllowed, isLoading: kycLoading, isError: kycError} = useReadContract({
    address: CONTRACTS.ComplianceRegistry!,
    abi: COMPLIANCE_ABI,
    functionName: "isAllowed",
    args: address ? [address] : undefined,
    query: {enabled: Boolean(address) && rightNetwork && rpcReady, ...POLL},
  });

  /** Connected on the configured chain, enough for actions the contracts leave un-gated
   *  (faucet, queue request/claim). */
  const chainOk = isConnected && rightNetwork && rpcReady;
  /** KYC-gated actions (mint, instant redeem only), mirrors the on-chain primary gate.
   *  Staking (vault deposit) is permissionless on-chain, so it uses chainOk, not this. */
  const writesEnabled = chainOk && kycAllowed === true;

  return (
    /* `operate` puts this subtree in product-UI mode: one type family (no serif
       display in labels, buttons or figures), fixed scale, full control states,
       and motion that reports state rather than decorating. Declared in
       globals.css so the rules are not re-argued per component. */
    <div className="operate mt-10">
      {/* ── Connect row: the surface's toolbar, on the second neutral layer so
             chrome reads as chrome against the white content panels. ────── */}
      <div className="op-toolbar flex flex-wrap items-center justify-between gap-4 px-5 py-4">
        <ConnectControl />
        {isConnected ? (
          rightNetwork && !rpcReady ? (
            <span className="rounded-pill border border-line-strong px-3.5 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
              {rpcAlignment.phase === "checking" ? "checking RPC…" : "RPC check required"}
            </span>
          ) : (
          kycLoading ? (
            <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
              checking KYC…
            </span>
          ) : kycAllowed === true ? (
            <span className="rounded-pill border border-accent/30 bg-accent-faint px-3.5 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.14em] text-accent">
              KYC verified
            </span>
          ) : kycAllowed === false ? (
            <span className="rounded-pill border border-warn/40 bg-warn/10 px-3.5 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.14em] text-warn">
              not KYC-verified
            </span>
          ) : kycError ? (
            // A failed read is NOT a verdict, never assert non-verification we
            // haven't determined.
            <span className="rounded-pill border border-line-strong px-3.5 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
              KYC check unavailable
            </span>
          ) : null
          )
        ) : (
          <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-ink-faint">
            {NETWORK_NAME}
          </span>
        )}
      </div>

      {/* A wallet proved to be on another chain gets the switch banner, not a mismatch: it
          is the one cause the page can repair. */}
      <NetworkBanner
        walletChainId={rpcAlignment.phase === "mismatch" ? rpcAlignment.walletChainId : undefined}
        onSwitched={recheckRpc}
      />

      {rpcAlignment.phase === "mismatch" && rpcAlignment.reason !== "wallet-chain" ? (
        <div className="mt-6 rounded-card border border-warn/40 bg-warn/10 px-5 py-3.5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="min-w-0 flex-1 text-[13.5px] leading-relaxed text-ink">
              <span className="font-medium">RPC mismatch.</span>{" "}
              <span className="text-ink-muted">{rpcAlignment.message}</span>
            </p>
            <button
              type="button"
              onClick={recheckRpc}
              className="rounded-pill border border-warn/60 px-4 py-1.5 text-[12.5px] font-medium text-ink transition-transform hover:scale-[1.02]"
            >
              Check again
            </button>
          </div>
          {rpcAlignment.reason === "wallet" || rpcAlignment.reason === "state" ? (
            <p className="mt-2 text-[12px] leading-relaxed text-ink-muted">{WALLET_RPC_GUIDANCE}</p>
          ) : null}
        </div>
      ) : null}

      {isConnected && !kycLoading && kycAllowed === false ? (
        <div className="mt-6 rounded-card border border-warn/40 bg-warn/10 px-5 py-3.5">
          <p className="text-[13.5px] leading-relaxed text-ink">
            <span className="font-medium">This address is not KYC-verified.</span>{" "}
            <span className="text-ink-muted">
              You can hold, view, transfer, and even stake freely. Existing sUSDfr
              can exit through the redemption queue. Only mint and instant redeem are
              disabled, and the contracts enforce that on-chain, not just here. To
              begin onboarding for this address, email{" "}
              <a href="mailto:jevans@forestroad.com" className="u-link text-ink">
                jevans@forestroad.com
              </a>
              .
            </span>
          </p>
        </div>
      ) : null}

      {/* Empty state that teaches the surface rather than announcing absence:
          it says what is already usable, what a wallet unlocks, and what the
          KYC gate does and does not cover, the three things a first-time
          visitor otherwise has to discover by clicking a disabled button. */}
      {!isConnected ? (
        <div className="mt-6 rounded-card border border-line bg-surface px-5 py-4">
          <p className="text-[13.5px] font-medium text-ink">
            No wallet connected. Everything below is still readable.
          </p>
          <ul className="mt-3 space-y-1.5 text-[13px] leading-relaxed text-ink-muted">
            <li>
              Reads are public: supply, backing, the vault rate, the queue and
              the book all render without a wallet.
            </li>
            <li>
              Connect on {NETWORK_NAME} to stake, request a redemption, or claim
              one. None of these requires KYC.
            </li>
            <li>
              Minting and instant redemption are KYC-gated on-chain at the
              primary market; the contracts enforce that, not this interface.
            </li>
          </ul>
        </div>
      ) : null}

      <YieldPositionPanel />

      {/* ── Write cards ──────────────────────────────────────────────── */}
      <div className="mt-8 grid gap-5 lg:grid-cols-3">
        <MintCard writesEnabled={writesEnabled} chainOk={chainOk} />
        {/* Staking is permissionless on-chain (2026-07-14), gate on network only, not KYC. */}
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
