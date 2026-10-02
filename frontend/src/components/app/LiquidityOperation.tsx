"use client";

import {useCallback, useEffect, useMemo, useState} from "react";
import {
  formatUnits,
  maxUint256,
  recoverTypedDataAddress,
  type Address,
  type Hash,
  type TransactionReceipt,
} from "viem";
import {mainnet} from "viem/chains";
import {useAccount, usePublicClient, useWalletClient} from "wagmi";

import {ConnectControl} from "@/components/app/ConnectControl";
import {CHAIN_ID, CONTRACTS, EXPLORER_BASE_URL} from "@/config/contracts";
import {shortAddress} from "@/lib/format";
import {probeRpcAlignment, type RpcRequest} from "@/lib/rpcAlignment";
import {
  ERC20_ABI,
  LIQUIDITY_OPERATOR,
  LIQUIDITY_TX_GAS,
  PERMIT2,
  PERMIT2_ABI,
  PERMIT2_DOMAIN,
  PERMIT2_TYPES,
  PILOT_USDC_CAP,
  POOL_ID,
  POSITION_MANAGER_ABI,
  STATE_VIEW_ABI,
  TARGET_TOTAL_LIQUIDITY,
  TARGET_USDC_MAX,
  TARGET_USDFR_MAX,
  TICK_LOWER,
  TICK_UPPER,
  USDC,
  USDFR,
  V4_POSITION_MANAGER,
  V4_STATE_VIEW,
  buildPermitBatchMessage,
  buildPilotPlan,
  buildRemainderPlan,
  encodeLiquidityTransaction,
  verifyMintReceipt,
  type LiquidityPlan,
  type MintEvidence,
  type PermitAllowance,
  type ReceiptLog,
} from "@/lib/uniswapV4Liquidity";

type Snapshot = {
  blockNumber: bigint;
  sqrtPriceX96: bigint;
  tick: number;
  usdcBalance: bigint;
  usdfrBalance: bigint;
  usdcTokenAllowance: bigint;
  usdfrTokenAllowance: bigint;
  usdcPermit: PermitAllowance;
  usdfrPermit: PermitAllowance;
};

type StoredMint = {
  version: 1;
  kind: "pilot" | "remainder";
  owner: Address;
  hash: Hash;
  liquidity: string;
  tokenId?: string;
  usdcSpent?: string;
  usdfrSpent?: string;
};

type ConfirmedMint = {
  hash: Hash;
  liquidity: bigint;
  evidence: MintEvidence;
};

type OperationStatus =
  | {phase: "idle"}
  | {phase: "reading"; message: string}
  | {phase: "signing"; message: string}
  | {phase: "simulating"; message: string}
  | {phase: "submitting"; message: string}
  | {phase: "pending"; message: string; hash: Hash}
  | {phase: "success"; message: string; hash: Hash}
  | {phase: "error"; message: string; hash?: Hash};

const STORAGE_PREFIX = "frv:uniswap-v4-liquidity:v1";
const TOKEN_APPROVAL_GAS = 200_000n;
const RECEIPT_TIMEOUT = 5 * 60 * 1_000;

function storageKey(kind: StoredMint["kind"], owner: Address): string {
  return `${STORAGE_PREFIX}:${kind}:${owner.toLowerCase()}`;
}

function writeStoredMint(record: StoredMint): void {
  window.localStorage.setItem(storageKey(record.kind, record.owner), JSON.stringify(record));
}

function readStoredMint(kind: StoredMint["kind"], owner: Address): StoredMint | null {
  const encoded = window.localStorage.getItem(storageKey(kind, owner));
  if (!encoded) return null;
  try {
    const record = JSON.parse(encoded) as Partial<StoredMint>;
    if (
      record.version !== 1 ||
      record.kind !== kind ||
      record.owner?.toLowerCase() !== owner.toLowerCase() ||
      !record.hash?.match(/^0x[0-9a-f]{64}$/i) ||
      !record.liquidity?.match(/^\d+$/)
    ) {
      return null;
    }
    return record as StoredMint;
  } catch {
    return null;
  }
}

function formatToken(value: bigint, decimals: number, precision = 6): string {
  const [whole, fraction = ""] = formatUnits(value, decimals).split(".");
  const clipped = fraction.slice(0, precision).replace(/0+$/, "");
  return Number(whole).toLocaleString("en-US") + (clipped ? `.${clipped}` : "");
}

function messageFromError(error: unknown): string {
  if (error instanceof Error) {
    const withShortMessage = error as Error & {shortMessage?: string};
    return withShortMessage.shortMessage || error.message;
  }
  if (typeof error === "object" && error && "message" in error) {
    return String((error as {message: unknown}).message);
  }
  return String(error);
}

function transactionUrl(hash: Hash): string | null {
  return EXPLORER_BASE_URL ? `${EXPLORER_BASE_URL}/tx/${hash}` : null;
}

async function verifyConfirmedMint(args: {
  publicClient: NonNullable<ReturnType<typeof usePublicClient>>;
  record: StoredMint;
}): Promise<ConfirmedMint> {
  const receipt = await args.publicClient.getTransactionReceipt({
    hash: args.record.hash,
  });
  if (receipt.status !== "success") {
    throw new Error(`${args.record.kind} transaction reverted on-chain.`);
  }
  const liquidity = BigInt(args.record.liquidity);
  const evidence = verifyMintReceipt({
    logs: receipt.logs as readonly ReceiptLog[],
    owner: args.record.owner,
    expectedLiquidity: liquidity,
  });
  const [positionLiquidity, positionOwner] = await Promise.all([
    args.publicClient.readContract({
      address: V4_POSITION_MANAGER,
      abi: POSITION_MANAGER_ABI,
      functionName: "getPositionLiquidity",
      args: [evidence.tokenId],
    }),
    args.publicClient.readContract({
      address: V4_POSITION_MANAGER,
      abi: POSITION_MANAGER_ABI,
      functionName: "ownerOf",
      args: [evidence.tokenId],
    }),
  ]);
  if (positionLiquidity !== liquidity) {
    throw new Error(
      `Position ${evidence.tokenId} no longer holds the liquidity minted by this step.`,
    );
  }
  if (positionOwner.toLowerCase() !== args.record.owner.toLowerCase()) {
    throw new Error(`Position ${evidence.tokenId} is no longer owned by the treasury.`);
  }
  const completed: StoredMint = {
    ...args.record,
    tokenId: evidence.tokenId.toString(),
    usdcSpent: evidence.usdcSpent.toString(),
    usdfrSpent: evidence.usdfrSpent.toString(),
  };
  writeStoredMint(completed);
  return {hash: args.record.hash, liquidity, evidence};
}

function PlanTable({plan}: {plan: LiquidityPlan}) {
  return (
    <dl className="mt-5 grid gap-x-6 gap-y-4 border-t border-line pt-5 sm:grid-cols-2">
      <div>
        <dt className="running-head">Expected USDC</dt>
        <dd className="mt-1 text-[17px] font-medium text-ink">
          {formatToken(plan.expectedUsdc, 6)}
        </dd>
      </div>
      <div>
        <dt className="running-head">Expected USDfr</dt>
        <dd className="mt-1 text-[17px] font-medium text-ink">
          {formatToken(plan.expectedUsdfr, 18)}
        </dd>
      </div>
      <div>
        <dt className="running-head">Hard USDC cap</dt>
        <dd className="mt-1 tnum text-[14px] text-ink-value">
          {formatToken(plan.maxUsdc, 6)}
        </dd>
      </div>
      <div>
        <dt className="running-head">Hard USDfr cap</dt>
        <dd className="mt-1 tnum text-[14px] text-ink-value">
          {formatToken(plan.maxUsdfr, 18)}
        </dd>
      </div>
    </dl>
  );
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

export function LiquidityOperation() {
  const {address, chainId, isConnected} = useAccount();
  const publicClient = usePublicClient();
  const {data: walletClient} = useWalletClient();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [pilot, setPilot] = useState<ConfirmedMint | null>(null);
  const [remainder, setRemainder] = useState<ConfirmedMint | null>(null);
  const [status, setStatus] = useState<OperationStatus>({phase: "idle"});
  const [loading, setLoading] = useState(false);

  const deploymentMatches =
    CHAIN_ID === 1 &&
    CONTRACTS.USDC?.toLowerCase() === USDC.toLowerCase() &&
    CONTRACTS.USDfr?.toLowerCase() === USDFR.toLowerCase();
  const walletMatches =
    address?.toLowerCase() === LIQUIDITY_OPERATOR.toLowerCase();
  const connectedCorrectly =
    Boolean(isConnected && walletMatches && chainId === mainnet.id && deploymentMatches);

  const pilotPlan = useMemo(() => {
    if (!snapshot) return null;
    try {
      return buildPilotPlan(snapshot.sqrtPriceX96);
    } catch {
      return null;
    }
  }, [snapshot]);

  const remainderPlan = useMemo(() => {
    if (!snapshot || !pilot) return null;
    try {
      return buildRemainderPlan(snapshot.sqrtPriceX96, {
        liquidity: pilot.liquidity,
        usdcSpent: pilot.evidence.usdcSpent,
        usdfrSpent: pilot.evidence.usdfrSpent,
      });
    } catch {
      return null;
    }
  }, [snapshot, pilot]);

  const loadSnapshot = useCallback(async (): Promise<Snapshot> => {
    if (!publicClient || !address) throw new Error("Connect the treasury wallet first.");
    const [block, slot0, usdcBalance, usdfrBalance, usdcTokenAllowance, usdfrTokenAllowance, usdcPermit, usdfrPermit] =
      await Promise.all([
        publicClient.getBlock(),
        publicClient.readContract({
          address: V4_STATE_VIEW,
          abi: STATE_VIEW_ABI,
          functionName: "getSlot0",
          args: [POOL_ID],
        }),
        publicClient.readContract({
          address: USDC,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [address],
        }),
        publicClient.readContract({
          address: USDFR,
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [address],
        }),
        publicClient.readContract({
          address: USDC,
          abi: ERC20_ABI,
          functionName: "allowance",
          args: [address, PERMIT2],
        }),
        publicClient.readContract({
          address: USDFR,
          abi: ERC20_ABI,
          functionName: "allowance",
          args: [address, PERMIT2],
        }),
        publicClient.readContract({
          address: PERMIT2,
          abi: PERMIT2_ABI,
          functionName: "allowance",
          args: [address, USDC, V4_POSITION_MANAGER],
        }),
        publicClient.readContract({
          address: PERMIT2,
          abi: PERMIT2_ABI,
          functionName: "allowance",
          args: [address, USDFR, V4_POSITION_MANAGER],
        }),
      ]);
    const next: Snapshot = {
      blockNumber: block.number,
      sqrtPriceX96: slot0[0],
      tick: slot0[1],
      usdcBalance,
      usdfrBalance,
      usdcTokenAllowance,
      usdfrTokenAllowance,
      usdcPermit: {
        amount: usdcPermit[0],
        expiration: usdcPermit[1],
        nonce: usdcPermit[2],
      },
      usdfrPermit: {
        amount: usdfrPermit[0],
        expiration: usdfrPermit[1],
        nonce: usdfrPermit[2],
      },
    };
    setSnapshot(next);
    return next;
  }, [address, publicClient]);

  const restoreProgress = useCallback(async () => {
    if (!address || !publicClient || !walletMatches) {
      setPilot(null);
      setRemainder(null);
      return;
    }
    const storedPilot = readStoredMint("pilot", address);
    if (storedPilot) {
      try {
        setPilot(await verifyConfirmedMint({publicClient, record: storedPilot}));
      } catch (error) {
        if (!messageFromError(error).toLowerCase().includes("not found")) throw error;
      }
    }
    const storedRemainder = readStoredMint("remainder", address);
    if (storedRemainder) {
      try {
        setRemainder(
          await verifyConfirmedMint({publicClient, record: storedRemainder}),
        );
      } catch (error) {
        if (!messageFromError(error).toLowerCase().includes("not found")) throw error;
      }
    }
  }, [address, publicClient, walletMatches]);

  const refresh = useCallback(async () => {
    if (!address || !publicClient || !walletMatches) return;
    setLoading(true);
    try {
      await Promise.all([loadSnapshot(), restoreProgress()]);
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
    async (token: typeof USDC | typeof USDFR, symbol: "USDC" | "USDfr") => {
      if (!connectedCorrectly || !walletClient || !publicClient || !address) return;
      try {
        setStatus({phase: "simulating", message: `Checking ${symbol} approval…`});
        await publicClient.simulateContract({
          account: address,
          address: token,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [PERMIT2, maxUint256],
          gas: TOKEN_APPROVAL_GAS,
        });
        setStatus({phase: "submitting", message: `Approve ${symbol} in the wallet.`});
        const hash = await walletClient.writeContract({
          account: address,
          chain: mainnet,
          address: token,
          abi: ERC20_ABI,
          functionName: "approve",
          args: [PERMIT2, maxUint256],
          gas: TOKEN_APPROVAL_GAS,
        });
        setStatus({phase: "pending", message: `${symbol} approval is pending.`, hash});
        const receipt = await publicClient.waitForTransactionReceipt({
          hash,
          timeout: RECEIPT_TIMEOUT,
        });
        if (receipt.status !== "success") throw new Error(`${symbol} approval reverted.`);
        await loadSnapshot();
        setStatus({phase: "success", message: `${symbol} approval confirmed.`, hash});
      } catch (error) {
        setStatus({phase: "error", message: messageFromError(error)});
      }
    }, [address, connectedCorrectly, loadSnapshot, publicClient, walletClient],
  );

  const executePlan = useCallback(
    async (kind: StoredMint["kind"]) => {
      if (!connectedCorrectly || !walletClient || !publicClient || !address) return;
      let pendingHash: Hash | undefined;
      try {
        setStatus({phase: "reading", message: "Refreshing price, balances, allowances, and nonces…"});
        const live = await loadSnapshot();
        const livePilot = pilot;
        const plan =
          kind === "pilot"
            ? buildPilotPlan(live.sqrtPriceX96)
            : livePilot
              ? buildRemainderPlan(live.sqrtPriceX96, {
                  liquidity: livePilot.liquidity,
                  usdcSpent: livePilot.evidence.usdcSpent,
                  usdfrSpent: livePilot.evidence.usdfrSpent,
                })
              : null;
        if (!plan) throw new Error("A verified pilot is required before the remainder.");
        if (live.usdcTokenAllowance < plan.maxUsdc) {
          throw new Error("USDC has not approved Permit2 for this operation.");
        }
        if (live.usdfrTokenAllowance < plan.maxUsdfr) {
          throw new Error("USDfr has not approved Permit2 for this operation.");
        }
        if (live.usdcBalance < plan.expectedUsdc) {
          throw new Error("The treasury does not hold the expected USDC contribution.");
        }
        if (live.usdfrBalance < plan.expectedUsdfr) {
          throw new Error("The treasury does not hold the expected USDfr contribution.");
        }
        const block = await publicClient.getBlock({blockNumber: live.blockNumber});
        const permit = buildPermitBatchMessage({
          plan,
          usdcNonce: live.usdcPermit.nonce,
          usdfrNonce: live.usdfrPermit.nonce,
          timestamp: Number(block.timestamp),
        });

        const alignment = await probeRpcAlignment(
          publicClient.request as RpcRequest,
          walletClient.transport.request as RpcRequest,
          {expectedChainId: mainnet.id, requireExactTip: false},
        );
        if (!alignment.aligned) throw new Error(alignment.message);

        setStatus({
          phase: "signing",
          message: "Sign the exact, 30-minute Permit2 allowance in the wallet.",
        });
        const signature = await walletClient.signTypedData({
          account: address,
          domain: PERMIT2_DOMAIN,
          types: PERMIT2_TYPES,
          primaryType: "PermitBatch",
          message: permit,
        });
        const recovered = await recoverTypedDataAddress({
          domain: PERMIT2_DOMAIN,
          types: PERMIT2_TYPES,
          primaryType: "PermitBatch",
          message: permit,
          signature,
        });
        if (recovered.toLowerCase() !== address.toLowerCase()) {
          throw new Error("The Permit2 signature does not belong to the connected treasury.");
        }
        const data = encodeLiquidityTransaction({owner: address, plan, permit, signature});

        setStatus({phase: "simulating", message: "Simulating the exact signed transaction…"});
        await publicClient.call({
          account: address,
          to: V4_POSITION_MANAGER,
          data,
          gas: LIQUIDITY_TX_GAS,
        });
        const [freshUsdcPermit, freshUsdfrPermit] = await Promise.all([
          publicClient.readContract({
            address: PERMIT2,
            abi: PERMIT2_ABI,
            functionName: "allowance",
            args: [address, USDC, V4_POSITION_MANAGER],
          }),
          publicClient.readContract({
            address: PERMIT2,
            abi: PERMIT2_ABI,
            functionName: "allowance",
            args: [address, USDFR, V4_POSITION_MANAGER],
          }),
        ]);
        if (
          freshUsdcPermit[2] !== live.usdcPermit.nonce ||
          freshUsdfrPermit[2] !== live.usdfrPermit.nonce
        ) {
          throw new Error("A Permit2 nonce changed while preparing the transaction; refresh and sign again.");
        }

        setStatus({
          phase: "submitting",
          message: `${kind === "pilot" ? "Submit the 50 USDC pilot" : "Submit the remaining position"} in the wallet.`,
        });
        const hash = await walletClient.sendTransaction({
          account: address,
          chain: mainnet,
          to: V4_POSITION_MANAGER,
          data,
          gas: LIQUIDITY_TX_GAS,
          value: 0n,
        });
        pendingHash = hash;
        const stored: StoredMint = {
          version: 1,
          kind,
          owner: address,
          hash,
          liquidity: plan.liquidity.toString(),
        };
        writeStoredMint(stored);
        setStatus({
          phase: "pending",
          message: "Transaction submitted. Waiting for the on-chain receipt and position checks…",
          hash,
        });
        const receipt: TransactionReceipt =
          await publicClient.waitForTransactionReceipt({
            hash,
            timeout: RECEIPT_TIMEOUT,
          });
        if (receipt.status !== "success") throw new Error("Transaction reverted on-chain.");
        const confirmed = await verifyConfirmedMint({publicClient, record: stored});
        if (kind === "pilot") setPilot(confirmed);
        else setRemainder(confirmed);
        await loadSnapshot();
        setStatus({
          phase: "success",
          message:
            kind === "pilot"
              ? `Pilot confirmed as Uniswap position ${confirmed.evidence.tokenId}. The remainder is now unlocked.`
              : `Remaining position confirmed as token ${confirmed.evidence.tokenId}. The staged operation is complete.`,
          hash,
        });
      } catch (error) {
        setStatus({phase: "error", message: messageFromError(error), hash: pendingHash});
      }
    }, [address, connectedCorrectly, loadSnapshot, pilot, publicClient, walletClient],
  );

  const busy = !["idle", "success", "error"].includes(status.phase) || loading;
  const usdfrPrice = snapshot
    ? 1 / (Math.pow(1.0001, snapshot.tick) * 1e-12)
    : null;
  const tokenApprovalsReady = Boolean(
    snapshot &&
      pilotPlan &&
      snapshot.usdcTokenAllowance >= pilotPlan.maxUsdc &&
      snapshot.usdfrTokenAllowance >= pilotPlan.maxUsdfr,
  );
  const pilotFundsReady = Boolean(
    snapshot &&
      pilotPlan &&
      snapshot.usdcBalance >= pilotPlan.expectedUsdc &&
      snapshot.usdfrBalance >= pilotPlan.expectedUsdfr,
  );
  const remainderFundsReady = Boolean(
    snapshot &&
      remainderPlan &&
      snapshot.usdcBalance >= remainderPlan.expectedUsdc &&
      snapshot.usdfrBalance >= remainderPlan.expectedUsdfr,
  );

  return (
    <div className="mx-auto max-w-4xl">
      <div className="rounded-card border border-line bg-raised p-5 md:p-7">
        <div className="flex flex-wrap items-start justify-between gap-5">
          <div>
            <p className="running-head text-accent">Execution identity</p>
            <p className="mt-2 font-mono text-[12px] text-ink">
              {LIQUIDITY_OPERATOR}
            </p>
            <p className="mt-2 max-w-[66ch] text-[13px] leading-relaxed text-ink-muted">
              Mainnet only. The recipient, tokens, pool, 0.9956–1.0300 price range,
              original liquidity target, and spending caps are fixed in code.
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
            Switch the wallet to Ethereum mainnet before continuing.
          </p>
        ) : null}

        {snapshot ? (
          <dl className="mt-6 grid gap-4 border-t border-line pt-5 sm:grid-cols-2 lg:grid-cols-4">
            <div>
              <dt className="running-head">Pool price</dt>
              <dd className="mt-1 tnum text-[15px] text-ink">
                ${usdfrPrice?.toFixed(6)} per USDfr
              </dd>
            </div>
            <div>
              <dt className="running-head">USDC balance</dt>
              <dd className="mt-1 tnum text-[15px] text-ink">
                {formatToken(snapshot.usdcBalance, 6, 2)}
              </dd>
            </div>
            <div>
              <dt className="running-head">USDfr balance</dt>
              <dd className="mt-1 tnum text-[15px] text-ink">
                {formatToken(snapshot.usdfrBalance, 18, 2)}
              </dd>
            </div>
            <div>
              <dt className="running-head">Read at block</dt>
              <dd className="mt-1 tnum text-[15px] text-ink">
                {snapshot.blockNumber.toLocaleString("en-US")}
              </dd>
            </div>
          </dl>
        ) : null}

        <button
          type="button"
          onClick={() => void refresh()}
          disabled={!walletMatches || loading || busy}
          className="mt-5 rounded-pill border border-line-strong px-4 py-1.5 text-[12.5px] text-ink-muted disabled:opacity-50"
        >
          {loading ? "Refreshing…" : "Refresh live checks"}
        </button>
      </div>

      {snapshot && pilotPlan && !tokenApprovalsReady ? (
        <section className="mt-6 rounded-card border border-warn/30 bg-warn-faint p-5 md:p-7">
          <h2 className="text-[20px] font-semibold text-ink">Permit2 token approvals</h2>
          <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
            A token-level Permit2 approval is missing. Each button submits a separate,
            reviewable approval; the liquidity transaction still needs its own short-lived
            signed allowance.
          </p>
          <div className="mt-4 flex flex-wrap gap-3">
            {snapshot.usdcTokenAllowance < pilotPlan.maxUsdc ? (
              <button
                type="button"
                onClick={() => void approveToken(USDC, "USDC")}
                disabled={!connectedCorrectly || busy}
                className="rounded-pill bg-accent px-5 py-2 text-[13px] font-medium text-raised disabled:opacity-50"
              >
                Approve USDC
              </button>
            ) : null}
            {snapshot.usdfrTokenAllowance < pilotPlan.maxUsdfr ? (
              <button
                type="button"
                onClick={() => void approveToken(USDFR, "USDfr")}
                disabled={!connectedCorrectly || busy}
                className="rounded-pill bg-accent px-5 py-2 text-[13px] font-medium text-raised disabled:opacity-50"
              >
                Approve USDfr
              </button>
            ) : null}
          </div>
        </section>
      ) : null}

      <section className="mt-6 rounded-card border border-line bg-raised p-5 md:p-7">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="running-head text-accent">Step 1</p>
            <h2 className="mt-1 text-[22px] font-semibold text-ink">50 USDC pilot</h2>
          </div>
          <span className={`rounded-pill px-3 py-1 text-[12px] ${pilot ? "bg-ok-faint text-ok" : "bg-app-toolbar text-ink-muted"}`}>
            {pilot ? "Confirmed" : "Required"}
          </span>
        </div>
        <p className="mt-3 max-w-[68ch] text-[13.5px] leading-relaxed text-ink-muted">
          The contract takes no more than 50 USDC and the displayed hard USDfr cap.
          At the current price the corresponding USDfr contribution is shown below.
          Receipt verification must pass before step 2 unlocks.
        </p>
        {pilotPlan ? <PlanTable plan={pilotPlan} /> : null}
        {pilot ? (
          <p className="mt-5 text-[13px] text-ok">
            Position {pilot.evidence.tokenId.toString()} spent {formatToken(pilot.evidence.usdcSpent, 6)} USDC and {formatToken(pilot.evidence.usdfrSpent, 18)} USDfr.
          </p>
        ) : (
          <button
            type="button"
            onClick={() => void executePlan("pilot")}
            disabled={
              !connectedCorrectly ||
              !pilotPlan ||
              !tokenApprovalsReady ||
              !pilotFundsReady ||
              busy
            }
            className="mt-6 rounded-pill bg-accent px-6 py-2.5 text-[14px] font-medium text-raised transition-colors hover:bg-accent-strong disabled:cursor-not-allowed disabled:opacity-45"
          >
            Review and submit pilot
          </button>
        )}
      </section>

      <section className={`mt-6 rounded-card border p-5 md:p-7 ${pilot ? "border-line bg-raised" : "border-dashed border-line-strong bg-card"}`}>
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="running-head text-accent">Step 2</p>
            <h2 className="mt-1 text-[22px] font-semibold text-ink">Original target remainder</h2>
          </div>
          <span className={`rounded-pill px-3 py-1 text-[12px] ${remainder ? "bg-ok-faint text-ok" : "bg-app-toolbar text-ink-muted"}`}>
            {remainder ? "Complete" : pilot ? "Unlocked" : "Locked"}
          </span>
        </div>
        <p className="mt-3 max-w-[68ch] text-[13.5px] leading-relaxed text-ink-muted">
          This mints only the liquidity left after the confirmed pilot, so both
          positions together equal the original reviewed target. The pilot’s actual
          token spends are also removed from the original aggregate caps.
        </p>
        {remainderPlan ? <PlanTable plan={remainderPlan} /> : null}
        {!pilot ? (
          <p className="mt-5 text-[13px] text-ink-faint">
            Complete and verify step 1 to prepare this transaction.
          </p>
        ) : remainder ? (
          <p className="mt-5 text-[13px] text-ok">
            Position {remainder.evidence.tokenId.toString()} confirmed. Aggregate target liquidity: {TARGET_TOTAL_LIQUIDITY.toString()}.
          </p>
        ) : (
          <button
            type="button"
            onClick={() => void executePlan("remainder")}
            disabled={
              !connectedCorrectly ||
              !remainderPlan ||
              !tokenApprovalsReady ||
              !remainderFundsReady ||
              busy
            }
            className="mt-6 rounded-pill bg-accent px-6 py-2.5 text-[14px] font-medium text-raised transition-colors hover:bg-accent-strong disabled:cursor-not-allowed disabled:opacity-45"
          >
            Review and submit remainder
          </button>
        )}
      </section>

      <StatusLine status={status} />

      <div className="mt-6 rounded-card border border-line bg-card p-5 text-[12.5px] leading-relaxed text-ink-faint">
        <p>
          Position Manager {shortAddress(V4_POSITION_MANAGER)} · pool {POOL_ID.slice(0, 10)}… · ticks {TICK_LOWER.toLocaleString()} to {TICK_UPPER.toLocaleString()} · transaction gas limit {LIQUIDITY_TX_GAS.toLocaleString()}.
        </p>
        <p className="mt-2">
          Original aggregate caps: {formatToken(TARGET_USDC_MAX, 6)} USDC and {formatToken(TARGET_USDFR_MAX, 18)} USDfr. Permit2 allowances expire after one hour; each signature can be submitted for 30 minutes.
        </p>
        <p className="mt-2">
          The failed transaction is never replayed. Every step reads current nonces and price, creates a fresh signature, simulates the exact calldata, and verifies the mined result.
        </p>
        <p className="mt-2">
          Pilot cap: {formatToken(PILOT_USDC_CAP, 6)} USDC. Full target liquidity: {TARGET_TOTAL_LIQUIDITY.toString()}.
        </p>
      </div>
    </div>
  );
}
