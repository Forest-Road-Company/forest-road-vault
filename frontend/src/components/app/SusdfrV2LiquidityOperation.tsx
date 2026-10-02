"use client";

import {useCallback, useEffect, useMemo, useState} from "react";
import {formatUnits, type Address, type Hash} from "viem";
import {mainnet} from "viem/chains";
import {useAccount, usePublicClient, useWalletClient} from "wagmi";

import {ConnectControl} from "@/components/app/ConnectControl";
import {CHAIN_ID, CONTRACTS, EXPLORER_BASE_URL} from "@/config/contracts";
import {shortAddress} from "@/lib/format";
import {probeRpcAlignment, type RpcRequest} from "@/lib/rpcAlignment";
import {
  LIQUIDITY_OPERATOR,
  SUSDFR,
  SUSDFR_DECIMALS,
  USDC,
  V2_ADD_LIQUIDITY_GAS,
  V2_APPROVAL_GAS,
  V2_DEADLINE_SECONDS,
  V2_ERC20_ABI,
  V2_FACTORY,
  V2_FACTORY_ABI,
  V2_PAIR_ABI,
  V2_ROUTER,
  V2_ROUTER_ABI,
  V2_SUSDFR_ABI,
  V2_USDFR_VALUE,
  ZERO_ADDRESS,
  buildV2LiquidityPlan,
  encodeV2AddLiquidity,
  verifyV2MintReceipt,
  type V2LiquidityPlan,
  type V2MintEvidence,
  type V2ReceiptLog,
} from "@/lib/uniswapV2SusdfrLiquidity";

type Snapshot = {
  blockNumber: bigint;
  blockTimestamp: bigint;
  pair: Address;
  routerFactory: Address;
  usdcBalance: bigint;
  susdfrBalance: bigint;
  usdcAllowance: bigint;
  susdfrAllowance: bigint;
  plan: V2LiquidityPlan;
};

type StoredMint = {
  version: 1;
  owner: Address;
  hash: Hash;
  usdc: string;
  susdfr: string;
};

type ConfirmedMint = {
  hash: Hash;
  evidence: V2MintEvidence;
};

type OperationStatus =
  | {phase: "idle"}
  | {phase: "reading" | "simulating" | "submitting"; message: string}
  | {phase: "pending" | "success"; message: string; hash: Hash}
  | {phase: "error"; message: string; hash?: Hash};

const STORAGE_KEY_PREFIX = "frv:uniswap-v2-susdfr-liquidity:v1";
const RECEIPT_TIMEOUT = 5 * 60 * 1_000;

function storageKey(owner: Address): string {
  return `${STORAGE_KEY_PREFIX}:${owner.toLowerCase()}`;
}

function formatToken(value: bigint, decimals: number, precision = 6): string {
  const [whole, fraction = ""] = formatUnits(value, decimals).split(".");
  const clipped = fraction.slice(0, precision).replace(/0+$/, "");
  return Number(whole).toLocaleString("en-US") + (clipped ? `.${clipped}` : "");
}

function messageFromError(error: unknown): string {
  if (error instanceof Error) {
    const detailed = error as Error & {shortMessage?: string};
    return detailed.shortMessage || error.message;
  }
  return String(error);
}

function transactionUrl(hash: Hash): string | null {
  return EXPLORER_BASE_URL ? `${EXPLORER_BASE_URL}/tx/${hash}` : null;
}

function readStoredMint(owner: Address): StoredMint | null {
  const encoded = window.localStorage.getItem(storageKey(owner));
  if (!encoded) return null;
  try {
    const row = JSON.parse(encoded) as Partial<StoredMint>;
    if (
      row.version !== 1 ||
      row.owner?.toLowerCase() !== owner.toLowerCase() ||
      !row.hash?.match(/^0x[0-9a-f]{64}$/i) ||
      !row.usdc?.match(/^\d+$/) ||
      !row.susdfr?.match(/^\d+$/)
    ) {
      return null;
    }
    return row as StoredMint;
  } catch {
    return null;
  }
}

function writeStoredMint(row: StoredMint): void {
  window.localStorage.setItem(storageKey(row.owner), JSON.stringify(row));
}

function StatusLine({status}: {status: OperationStatus}) {
  if (status.phase === "idle") return null;
  const isError = status.phase === "error";
  const isSuccess = status.phase === "success";
  const url = "hash" in status && status.hash ? transactionUrl(status.hash) : null;
  return (
    <div
      role={isError ? "alert" : "status"}
      className={`mt-5 rounded-card border px-4 py-3 text-[13px] leading-relaxed ${
        isError
          ? "border-danger/30 bg-danger-faint text-danger"
          : isSuccess
            ? "border-ok/30 bg-ok-faint text-ok"
            : "border-line bg-app-toolbar text-ink-muted"
      }`}
    >
      <p>{status.message}</p>
      {url ? (
        <a className="mt-1 inline-block underline" href={url} target="_blank" rel="noreferrer">
          View transaction
        </a>
      ) : null}
    </div>
  );
}

export function SusdfrV2LiquidityOperation() {
  const {address, chainId, isConnected} = useAccount();
  const publicClient = usePublicClient();
  const {data: walletClient} = useWalletClient();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [confirmed, setConfirmed] = useState<ConfirmedMint | null>(null);
  const [status, setStatus] = useState<OperationStatus>({phase: "idle"});
  const [loading, setLoading] = useState(false);

  const deploymentMatches =
    CHAIN_ID === 1 &&
    CONTRACTS.USDC?.toLowerCase() === USDC.toLowerCase() &&
    CONTRACTS.sUSDfr?.toLowerCase() === SUSDFR.toLowerCase();
  const walletMatches = address?.toLowerCase() === LIQUIDITY_OPERATOR.toLowerCase();
  const connectedCorrectly = Boolean(
    isConnected && walletMatches && chainId === mainnet.id && deploymentMatches,
  );

  const loadSnapshot = useCallback(async (): Promise<Snapshot> => {
    if (!publicClient || !address) throw new Error("Connect the treasury wallet first.");
    const block = await publicClient.getBlock();
    const blockNumber = block.number;
    const [pair, routerFactory, usdcBalance, susdfrBalance, usdcAllowance, susdfrAllowance, shares] =
      await Promise.all([
        publicClient.readContract({
          address: V2_FACTORY,
          abi: V2_FACTORY_ABI,
          functionName: "getPair",
          args: [USDC, SUSDFR],
          blockNumber,
        }),
        publicClient.readContract({
          address: V2_ROUTER,
          abi: V2_ROUTER_ABI,
          functionName: "factory",
          blockNumber,
        }),
        publicClient.readContract({
          address: USDC,
          abi: V2_ERC20_ABI,
          functionName: "balanceOf",
          args: [address],
          blockNumber,
        }),
        publicClient.readContract({
          address: SUSDFR,
          abi: V2_ERC20_ABI,
          functionName: "balanceOf",
          args: [address],
          blockNumber,
        }),
        publicClient.readContract({
          address: USDC,
          abi: V2_ERC20_ABI,
          functionName: "allowance",
          args: [address, V2_ROUTER],
          blockNumber,
        }),
        publicClient.readContract({
          address: SUSDFR,
          abi: V2_ERC20_ABI,
          functionName: "allowance",
          args: [address, V2_ROUTER],
          blockNumber,
        }),
        publicClient.readContract({
          address: SUSDFR,
          abi: V2_SUSDFR_ABI,
          functionName: "convertToShares",
          args: [V2_USDFR_VALUE],
          blockNumber,
        }),
      ]);
    const assetsRepresented = await publicClient.readContract({
      address: SUSDFR,
      abi: V2_SUSDFR_ABI,
      functionName: "convertToAssets",
      args: [shares],
      blockNumber,
    });
    const next: Snapshot = {
      blockNumber,
      blockTimestamp: block.timestamp,
      pair,
      routerFactory,
      usdcBalance,
      susdfrBalance,
      usdcAllowance,
      susdfrAllowance,
      plan: buildV2LiquidityPlan({sharesForTargetAssets: shares, assetsRepresented}),
    };
    setSnapshot(next);
    return next;
  }, [address, publicClient]);

  const restoreProgress = useCallback(async () => {
    if (!address || !publicClient || !walletMatches) {
      setConfirmed(null);
      return;
    }
    const stored = readStoredMint(address);
    if (!stored) return;
    const receipt = await publicClient.getTransactionReceipt({hash: stored.hash});
    if (receipt.status !== "success") throw new Error("The stored V2 liquidity transaction reverted.");
    const plan: V2LiquidityPlan = {
      usdc: BigInt(stored.usdc),
      susdfr: BigInt(stored.susdfr),
      susdfrAssets: V2_USDFR_VALUE,
    };
    const evidence = verifyV2MintReceipt({
      logs: receipt.logs as readonly V2ReceiptLog[],
      owner: address,
      plan,
    });
    const [factoryPair, token0, token1, lpBalance] = await Promise.all([
      publicClient.readContract({
        address: V2_FACTORY,
        abi: V2_FACTORY_ABI,
        functionName: "getPair",
        args: [USDC, SUSDFR],
      }),
      publicClient.readContract({address: evidence.pair, abi: V2_PAIR_ABI, functionName: "token0"}),
      publicClient.readContract({address: evidence.pair, abi: V2_PAIR_ABI, functionName: "token1"}),
      publicClient.readContract({
        address: evidence.pair,
        abi: V2_PAIR_ABI,
        functionName: "balanceOf",
        args: [address],
      }),
    ]);
    if (
      factoryPair.toLowerCase() !== evidence.pair.toLowerCase() ||
      token0.toLowerCase() !== USDC.toLowerCase() ||
      token1.toLowerCase() !== SUSDFR.toLowerCase() ||
      lpBalance < evidence.lpTokens
    ) {
      throw new Error("The live pair or treasury LP balance no longer matches the receipt.");
    }
    setConfirmed({hash: stored.hash, evidence});
  }, [address, publicClient, walletMatches]);

  const refresh = useCallback(async () => {
    if (!address || !publicClient || !walletMatches) return;
    setLoading(true);
    try {
      await loadSnapshot();
      await restoreProgress();
    } catch (error) {
      setStatus({phase: "error", message: messageFromError(error)});
    } finally {
      setLoading(false);
    }
  }, [address, loadSnapshot, publicClient, restoreProgress, walletMatches]);

  useEffect(() => {
    const scheduled = window.setTimeout(() => void refresh(), 0);
    return () => window.clearTimeout(scheduled);
  }, [refresh]);

  const approveToken = useCallback(
    async (token: typeof USDC | typeof SUSDFR, symbol: "USDC" | "sUSDfr") => {
      if (!connectedCorrectly || !walletClient || !publicClient || !address) return;
      try {
        const live = await loadSnapshot();
        if (live.pair !== ZERO_ADDRESS) throw new Error("The V2 pair already exists; approvals are locked.");
        const amount = token.toLowerCase() === USDC.toLowerCase() ? live.plan.usdc : live.plan.susdfr;
        setStatus({phase: "simulating", message: `Checking the exact ${symbol} approval…`});
        await publicClient.simulateContract({
          account: address,
          address: token,
          abi: V2_ERC20_ABI,
          functionName: "approve",
          args: [V2_ROUTER, amount],
          gas: V2_APPROVAL_GAS,
        });
        setStatus({phase: "submitting", message: `Approve the exact ${symbol} ceiling in the wallet.`});
        const hash = await walletClient.writeContract({
          account: address,
          chain: mainnet,
          address: token,
          abi: V2_ERC20_ABI,
          functionName: "approve",
          args: [V2_ROUTER, amount],
          gas: V2_APPROVAL_GAS,
        });
        setStatus({phase: "pending", message: `${symbol} approval is pending.`, hash});
        const receipt = await publicClient.waitForTransactionReceipt({hash, timeout: RECEIPT_TIMEOUT});
        if (receipt.status !== "success") throw new Error(`${symbol} approval reverted.`);
        await loadSnapshot();
        setStatus({phase: "success", message: `${symbol} approval confirmed.`, hash});
      } catch (error) {
        setStatus({phase: "error", message: messageFromError(error)});
      }
    },
    [address, connectedCorrectly, loadSnapshot, publicClient, walletClient],
  );

  const execute = useCallback(async () => {
    if (!connectedCorrectly || !walletClient || !publicClient || !address) return;
    let pendingHash: Hash | undefined;
    try {
      setStatus({phase: "reading", message: "Refreshing the pair, exchange rate, balances and exact allowances…"});
      const live = await loadSnapshot();
      if (live.routerFactory.toLowerCase() !== V2_FACTORY.toLowerCase()) {
        throw new Error("The canonical router does not report the approved factory.");
      }
      if (live.pair !== ZERO_ADDRESS) {
        throw new Error("The USDC/sUSDfr V2 pair already exists; fresh-pair submission is locked.");
      }
      if (live.usdcBalance < live.plan.usdc || live.susdfrBalance < live.plan.susdfr) {
        throw new Error("The treasury does not hold both approved contributions.");
      }
      if (live.usdcAllowance < live.plan.usdc || live.susdfrAllowance < live.plan.susdfr) {
        throw new Error("Both exact router approvals must be confirmed first.");
      }
      const alignment = await probeRpcAlignment(
        publicClient.request as RpcRequest,
        walletClient.transport.request as RpcRequest,
        {expectedChainId: mainnet.id, requireExactTip: false},
      );
      if (!alignment.aligned) throw new Error(alignment.message);

      const deadline = live.blockTimestamp + V2_DEADLINE_SECONDS;
      const data = encodeV2AddLiquidity({plan: live.plan, recipient: address, deadline});
      setStatus({phase: "simulating", message: "Simulating exact pair creation and full-range liquidity…"});
      await publicClient.call({
        account: address,
        to: V2_ROUTER,
        data,
        gas: V2_ADD_LIQUIDITY_GAS,
      });
      const pairAfterSimulation = await publicClient.readContract({
        address: V2_FACTORY,
        abi: V2_FACTORY_ABI,
        functionName: "getPair",
        args: [USDC, SUSDFR],
      });
      if (pairAfterSimulation !== ZERO_ADDRESS) {
        throw new Error("The pair appeared while preparing the transaction; refresh before retrying.");
      }

      setStatus({phase: "submitting", message: "Create the pair and add the exact liquidity in the wallet."});
      const hash = await walletClient.sendTransaction({
        account: address,
        chain: mainnet,
        to: V2_ROUTER,
        data,
        gas: V2_ADD_LIQUIDITY_GAS,
        value: 0n,
      });
      pendingHash = hash;
      const stored: StoredMint = {
        version: 1,
        owner: address,
        hash,
        usdc: live.plan.usdc.toString(),
        susdfr: live.plan.susdfr.toString(),
      };
      writeStoredMint(stored);
      setStatus({phase: "pending", message: "Transaction submitted. Verifying the fresh pair and LP tokens…", hash});
      const receipt = await publicClient.waitForTransactionReceipt({hash, timeout: RECEIPT_TIMEOUT});
      if (receipt.status !== "success") throw new Error("The V2 liquidity transaction reverted.");
      const evidence = verifyV2MintReceipt({
        logs: receipt.logs as readonly V2ReceiptLog[],
        owner: address,
        plan: live.plan,
      });
      const [factoryPair, token0, token1, lpBalance] = await Promise.all([
        publicClient.readContract({
          address: V2_FACTORY,
          abi: V2_FACTORY_ABI,
          functionName: "getPair",
          args: [USDC, SUSDFR],
        }),
        publicClient.readContract({address: evidence.pair, abi: V2_PAIR_ABI, functionName: "token0"}),
        publicClient.readContract({address: evidence.pair, abi: V2_PAIR_ABI, functionName: "token1"}),
        publicClient.readContract({
          address: evidence.pair,
          abi: V2_PAIR_ABI,
          functionName: "balanceOf",
          args: [address],
        }),
      ]);
      if (
        factoryPair.toLowerCase() !== evidence.pair.toLowerCase() ||
        token0.toLowerCase() !== USDC.toLowerCase() ||
        token1.toLowerCase() !== SUSDFR.toLowerCase() ||
        lpBalance < evidence.lpTokens
      ) {
        throw new Error("The mined pair identity or treasury LP balance does not match the receipt.");
      }
      setConfirmed({hash, evidence});
      await loadSnapshot();
      setStatus({
        phase: "success",
        message: `Full-range position confirmed. The treasury received ${formatToken(evidence.lpTokens, 18)} UNI-V2 LP tokens.`,
        hash,
      });
    } catch (error) {
      setStatus({phase: "error", message: messageFromError(error), hash: pendingHash});
    }
  }, [address, connectedCorrectly, loadSnapshot, publicClient, walletClient]);

  const plan = snapshot?.plan ?? null;
  const pairAbsent = snapshot?.pair === ZERO_ADDRESS;
  const approvalsReady = Boolean(
    plan && snapshot && snapshot.usdcAllowance >= plan.usdc && snapshot.susdfrAllowance >= plan.susdfr,
  );
  const fundsReady = Boolean(
    plan && snapshot && snapshot.usdcBalance >= plan.usdc && snapshot.susdfrBalance >= plan.susdfr,
  );
  const routerMatches = snapshot?.routerFactory.toLowerCase() === V2_FACTORY.toLowerCase();
  const busy = loading || !["idle", "success", "error"].includes(status.phase);
  const impliedPrice = useMemo(() => {
    if (!plan || plan.susdfr === 0n) return null;
    return Number(plan.usdc) * 1e18 / Number(plan.susdfr);
  }, [plan]);

  return (
    <div className="mx-auto max-w-4xl">
      <div className="rounded-card border border-line bg-raised p-5 md:p-7">
        <div className="flex flex-wrap items-start justify-between gap-5">
          <div>
            <p className="running-head text-accent">Execution identity</p>
            <p className="mt-2 font-mono text-[12px] text-ink">{LIQUIDITY_OPERATOR}</p>
            <p className="mt-2 max-w-[68ch] text-[13px] leading-relaxed text-ink-muted">
              Mainnet only. This creates the canonical Uniswap V2 USDC/sUSDfr pair and deposits
              exactly 25,000 USDC plus the sUSDfr representing 25,000 USDfr. V2 liquidity is full range.
            </p>
          </div>
          <ConnectControl />
        </div>

        {!deploymentMatches ? (
          <p role="alert" className="mt-5 rounded-card bg-danger-faint p-4 text-[13px] text-danger">
            This build is not bound to the approved Ethereum deployment. Writes are disabled.
          </p>
        ) : null}
        {isConnected && !walletMatches ? (
          <p role="alert" className="mt-5 rounded-card bg-danger-faint p-4 text-[13px] text-danger">
            Wrong wallet connected. This operation only accepts {shortAddress(LIQUIDITY_OPERATOR)}.
          </p>
        ) : null}
        {isConnected && chainId !== mainnet.id ? (
          <p role="alert" className="mt-5 rounded-card bg-danger-faint p-4 text-[13px] text-danger">
            Switch the connected wallet to Ethereum mainnet.
          </p>
        ) : null}
        {snapshot && !routerMatches ? (
          <p role="alert" className="mt-5 rounded-card bg-danger-faint p-4 text-[13px] text-danger">
            Router/factory identity mismatch. Writes are disabled.
          </p>
        ) : null}
        {snapshot && !pairAbsent && !confirmed ? (
          <p role="alert" className="mt-5 rounded-card bg-danger-faint p-4 text-[13px] text-danger">
            A V2 pair already exists without this browser’s verified creation receipt. Fresh-pair submission is locked.
          </p>
        ) : null}

        <dl className="mt-6 grid gap-4 border-t border-line pt-5 sm:grid-cols-3">
          <div>
            <dt className="running-head">Pair state</dt>
            <dd className="mt-1 text-[14px] text-ink">
              {snapshot ? (pairAbsent ? "Not created" : shortAddress(snapshot.pair)) : "Not read"}
            </dd>
          </div>
          <div>
            <dt className="running-head">USDC balance</dt>
            <dd className="mt-1 text-[14px] text-ink">
              {snapshot ? formatToken(snapshot.usdcBalance, 6, 2) : "—"}
            </dd>
          </div>
          <div>
            <dt className="running-head">sUSDfr balance</dt>
            <dd className="mt-1 text-[14px] text-ink">
              {snapshot ? formatToken(snapshot.susdfrBalance, SUSDFR_DECIMALS, 6) : "—"}
            </dd>
          </div>
        </dl>
      </div>

      <section className="mt-6 rounded-card border border-line bg-raised p-5 md:p-7">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="running-head text-accent">Full-range position</p>
            <h2 className="mt-1 text-[22px] font-semibold text-ink">$50,000 total opening liquidity</h2>
          </div>
          <span className={`rounded-pill px-3 py-1 text-[12px] ${confirmed ? "bg-ok-faint text-ok" : "bg-app-toolbar text-ink-muted"}`}>
            {confirmed ? "Complete" : "Ready for approvals"}
          </span>
        </div>
        <p className="mt-3 max-w-[68ch] text-[13.5px] leading-relaxed text-ink-muted">
          The sUSDfr amount is refreshed from the vault’s live conversion immediately before submission.
          Desired amounts and minimum amounts are identical, so any pre-existing reserve or changed opening ratio makes the transaction revert in full.
        </p>

        <dl className="mt-5 grid gap-x-6 gap-y-4 border-t border-line pt-5 sm:grid-cols-2">
          <div>
            <dt className="running-head">USDC contribution</dt>
            <dd className="mt-1 text-[17px] font-medium text-ink">{plan ? formatToken(plan.usdc, 6, 2) : "—"}</dd>
          </div>
          <div>
            <dt className="running-head">sUSDfr contribution</dt>
            <dd className="mt-1 text-[17px] font-medium text-ink">
              {plan ? formatToken(plan.susdfr, SUSDFR_DECIMALS, 12) : "—"}
            </dd>
          </div>
          <div>
            <dt className="running-head">sUSDfr value represented</dt>
            <dd className="mt-1 tnum text-[14px] text-ink-value">
              {plan ? `${formatToken(plan.susdfrAssets, 18, 8)} USDfr` : "—"}
            </dd>
          </div>
          <div>
            <dt className="running-head">Opening price</dt>
            <dd className="mt-1 tnum text-[14px] text-ink-value">
              {impliedPrice ? `${impliedPrice.toFixed(8)} USDC / sUSDfr` : "—"}
            </dd>
          </div>
        </dl>

        {confirmed ? (
          <p className="mt-6 text-[13px] text-ok">
            Pair {shortAddress(confirmed.evidence.pair)} confirmed. The treasury owns the verified LP tokens.
          </p>
        ) : (
          <div className="mt-6 flex flex-wrap gap-3">
            <button
              type="button"
              onClick={() => void approveToken(USDC, "USDC")}
              disabled={!connectedCorrectly || !pairAbsent || !plan || busy || Boolean(snapshot && snapshot.usdcAllowance >= plan.usdc)}
              className="rounded-pill border border-line px-5 py-2 text-[13px] text-ink disabled:opacity-45"
            >
              Approve 25,000 USDC
            </button>
            <button
              type="button"
              onClick={() => void approveToken(SUSDFR, "sUSDfr")}
              disabled={!connectedCorrectly || !pairAbsent || !plan || busy || Boolean(snapshot && snapshot.susdfrAllowance >= plan.susdfr)}
              className="rounded-pill border border-line px-5 py-2 text-[13px] text-ink disabled:opacity-45"
            >
              Approve exact sUSDfr
            </button>
            <button
              type="button"
              onClick={() => void execute()}
              disabled={!connectedCorrectly || !pairAbsent || !routerMatches || !approvalsReady || !fundsReady || busy}
              className="rounded-pill bg-accent px-6 py-2 text-[13px] font-medium text-raised disabled:cursor-not-allowed disabled:opacity-45"
            >
              Create pair and add liquidity
            </button>
            <button
              type="button"
              onClick={() => void refresh()}
              disabled={!walletMatches || busy}
              className="rounded-pill border border-line px-5 py-2 text-[13px] text-ink disabled:opacity-45"
            >
              Refresh checks
            </button>
          </div>
        )}
      </section>

      <StatusLine status={status} />

      <div className="mt-6 rounded-card border border-line bg-card p-5 text-[12.5px] leading-relaxed text-ink-faint">
        <p>Factory {shortAddress(V2_FACTORY)} · Router {shortAddress(V2_ROUTER)} · transaction gas limit {V2_ADD_LIQUIDITY_GAS.toLocaleString()}.</p>
        <p className="mt-2">
          Approvals are exact rather than unlimited. The liquidity deadline is 30 minutes. Pair identity, token destinations, exact spends, opening reserves and LP ownership are checked from the mined receipt.
        </p>
      </div>
    </div>
  );
}
