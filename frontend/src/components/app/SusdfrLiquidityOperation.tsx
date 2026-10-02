"use client";

import {useCallback, useEffect, useMemo, useState} from "react";
import {
  formatUnits,
  maxUint256,
  recoverTypedDataAddress,
  type Address,
  type Hash,
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
  PERMIT2_ABI,
  STATE_VIEW_ABI,
  USDC,
  V4_POSITION_MANAGER,
  V4_STATE_VIEW,
} from "@/lib/uniswapV4Liquidity";
import {
  PERMIT2,
  PERMIT2_DOMAIN,
  PERMIT2_TYPES,
  SEED_USDC_CAP,
  SUSDFR,
  SUSDFR_DECIMALS,
  SUSDFR_INITIAL_SQRT_PRICE_X96,
  SUSDFR_LIQUIDITY_TX_GAS,
  SUSDFR_POOL_ID,
  SUSDFR_POSITION_MANAGER_ABI,
  TOTAL_USDC_CAP,
  buildSusdfrPermitBatchMessage,
  buildSusdfrSeedPlan,
  buildSusdfrWallPlan,
  encodeSusdfrLiquidityTransaction,
  verifySusdfrMintReceipt,
  type SusdfrLiquidityPlan,
  type SusdfrMintEvidence,
  type SusdfrOperationKind,
  type SusdfrPermitAllowance,
  type SusdfrReceiptLog,
} from "@/lib/uniswapV4SusdfrLiquidity";

type Snapshot = {
  blockNumber: bigint;
  sqrtPriceX96: bigint;
  tick: number;
  usdcBalance: bigint;
  susdfrBalance: bigint;
  usdcTokenAllowance: bigint;
  susdfrTokenAllowance: bigint;
  usdcPermit: SusdfrPermitAllowance;
  susdfrPermit: SusdfrPermitAllowance;
};

type StoredMint = {
  version: 1;
  kind: SusdfrOperationKind;
  owner: Address;
  hash: Hash;
  liquidity: string;
  tokenId?: string;
  usdcSpent?: string;
  susdfrSpent?: string;
};

type ConfirmedMint = {
  hash: Hash;
  plan: SusdfrLiquidityPlan;
  evidence: SusdfrMintEvidence;
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

const STORAGE_PREFIX = "frv:uniswap-v4-susdfr-liquidity:v1";
const TOKEN_APPROVAL_GAS = 200_000n;
const RECEIPT_TIMEOUT = 5 * 60 * 1_000;

function storageKey(kind: SusdfrOperationKind, owner: Address): string {
  return `${STORAGE_PREFIX}:${kind}:${owner.toLowerCase()}`;
}

function writeStoredMint(record: StoredMint): void {
  window.localStorage.setItem(
    storageKey(record.kind, record.owner),
    JSON.stringify(record),
  );
}

function readStoredMint(kind: SusdfrOperationKind, owner: Address): StoredMint | null {
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

function planForStoredMint(
  kind: SusdfrOperationKind,
  seed: ConfirmedMint | null,
): SusdfrLiquidityPlan {
  if (kind === "seed") return buildSusdfrSeedPlan(0n);
  if (!seed) throw new Error("A verified seed is required before restoring the wall.");
  return buildSusdfrWallPlan(SUSDFR_INITIAL_SQRT_PRICE_X96, seed.evidence);
}

async function verifyConfirmedMint(args: {
  publicClient: NonNullable<ReturnType<typeof usePublicClient>>;
  record: StoredMint;
  seed: ConfirmedMint | null;
}): Promise<ConfirmedMint> {
  const plan = planForStoredMint(args.record.kind, args.seed);
  if (BigInt(args.record.liquidity) !== plan.liquidity) {
    throw new Error("Stored progress names liquidity outside the approved plan.");
  }
  const receipt = await args.publicClient.getTransactionReceipt({
    hash: args.record.hash,
  });
  if (receipt.status !== "success") {
    throw new Error(`${args.record.kind} transaction reverted on-chain.`);
  }
  const evidence = verifySusdfrMintReceipt({
    logs: receipt.logs as readonly SusdfrReceiptLog[],
    owner: args.record.owner,
    plan,
  });
  const [positionLiquidity, positionOwner] = await Promise.all([
    args.publicClient.readContract({
      address: V4_POSITION_MANAGER,
      abi: SUSDFR_POSITION_MANAGER_ABI,
      functionName: "getPositionLiquidity",
      args: [evidence.tokenId],
    }),
    args.publicClient.readContract({
      address: V4_POSITION_MANAGER,
      abi: SUSDFR_POSITION_MANAGER_ABI,
      functionName: "ownerOf",
      args: [evidence.tokenId],
    }),
  ]);
  if (positionLiquidity !== plan.liquidity) {
    throw new Error(`Position ${evidence.tokenId} no longer holds the minted liquidity.`);
  }
  if (positionOwner.toLowerCase() !== args.record.owner.toLowerCase()) {
    throw new Error(`Position ${evidence.tokenId} is no longer owned by the treasury.`);
  }
  writeStoredMint({
    ...args.record,
    tokenId: evidence.tokenId.toString(),
    usdcSpent: evidence.usdcSpent.toString(),
    susdfrSpent: evidence.susdfrSpent.toString(),
  });
  return {hash: args.record.hash, plan, evidence};
}

function PlanTable({plan}: {plan: SusdfrLiquidityPlan}) {
  return (
    <dl className="mt-5 grid gap-x-6 gap-y-4 border-t border-line pt-5 sm:grid-cols-2">
      <div>
        <dt className="running-head">Expected USDC</dt>
        <dd className="mt-1 text-[17px] font-medium text-ink">
          {formatToken(plan.expectedUsdc, 6)}
        </dd>
      </div>
      <div>
        <dt className="running-head">Expected sUSDfr</dt>
        <dd className="mt-1 text-[17px] font-medium text-ink">
          {formatToken(plan.expectedSusdfr, SUSDFR_DECIMALS)}
        </dd>
      </div>
      <div>
        <dt className="running-head">Hard USDC cap</dt>
        <dd className="mt-1 tnum text-[14px] text-ink-value">
          {formatToken(plan.maxUsdc, 6)}
        </dd>
      </div>
      <div>
        <dt className="running-head">Hard sUSDfr cap</dt>
        <dd className="mt-1 tnum text-[14px] text-ink-value">
          {formatToken(plan.maxSusdfr, SUSDFR_DECIMALS)}
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

export function SusdfrLiquidityOperation() {
  const {address, chainId, isConnected} = useAccount();
  const publicClient = usePublicClient();
  const {data: walletClient} = useWalletClient();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [seed, setSeed] = useState<ConfirmedMint | null>(null);
  const [wall, setWall] = useState<ConfirmedMint | null>(null);
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

  const seedPlan = useMemo(() => buildSusdfrSeedPlan(0n), []);
  const wallPlan = useMemo(() => {
    if (!snapshot || !seed) return null;
    try {
      return buildSusdfrWallPlan(snapshot.sqrtPriceX96, seed.evidence);
    } catch {
      return null;
    }
  }, [seed, snapshot]);

  const loadSnapshot = useCallback(async (): Promise<Snapshot> => {
    if (!publicClient || !address) throw new Error("Connect the treasury wallet first.");
    const [
      block,
      slot0,
      usdcBalance,
      susdfrBalance,
      usdcTokenAllowance,
      susdfrTokenAllowance,
      usdcPermit,
      susdfrPermit,
    ] = await Promise.all([
      publicClient.getBlock(),
      publicClient.readContract({
        address: V4_STATE_VIEW,
        abi: STATE_VIEW_ABI,
        functionName: "getSlot0",
        args: [SUSDFR_POOL_ID],
      }),
      publicClient.readContract({
        address: USDC,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [address],
      }),
      publicClient.readContract({
        address: SUSDFR,
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
        address: SUSDFR,
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
        args: [address, SUSDFR, V4_POSITION_MANAGER],
      }),
    ]);
    const next: Snapshot = {
      blockNumber: block.number,
      sqrtPriceX96: slot0[0],
      tick: slot0[1],
      usdcBalance,
      susdfrBalance,
      usdcTokenAllowance,
      susdfrTokenAllowance,
      usdcPermit: {amount: usdcPermit[0], expiration: usdcPermit[1], nonce: usdcPermit[2]},
      susdfrPermit: {
        amount: susdfrPermit[0],
        expiration: susdfrPermit[1],
        nonce: susdfrPermit[2],
      },
    };
    setSnapshot(next);
    return next;
  }, [address, publicClient]);

  const restoreProgress = useCallback(async () => {
    if (!address || !publicClient || !walletMatches) {
      setSeed(null);
      setWall(null);
      return;
    }
    let confirmedSeed: ConfirmedMint | null = null;
    const storedSeed = readStoredMint("seed", address);
    if (storedSeed) {
      try {
        confirmedSeed = await verifyConfirmedMint({
          publicClient,
          record: storedSeed,
          seed: null,
        });
        setSeed(confirmedSeed);
      } catch (error) {
        if (!messageFromError(error).toLowerCase().includes("not found")) throw error;
      }
    }
    const storedWall = readStoredMint("wall", address);
    if (storedWall && confirmedSeed) {
      try {
        setWall(
          await verifyConfirmedMint({
            publicClient,
            record: storedWall,
            seed: confirmedSeed,
          }),
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
    },
    [address, connectedCorrectly, loadSnapshot, publicClient, walletClient],
  );

  const executePlan = useCallback(
    async (kind: SusdfrOperationKind) => {
      if (!connectedCorrectly || !walletClient || !publicClient || !address) return;
      let pendingHash: Hash | undefined;
      try {
        setStatus({phase: "reading", message: "Refreshing pool state, balances, allowances, and nonces…"});
        const live = await loadSnapshot();
        const plan =
          kind === "seed"
            ? buildSusdfrSeedPlan(live.sqrtPriceX96)
            : seed
              ? buildSusdfrWallPlan(live.sqrtPriceX96, seed.evidence)
              : null;
        if (!plan) throw new Error("A verified seed is required before the USDC wall.");
        if (live.usdcTokenAllowance < plan.maxUsdc) {
          throw new Error("USDC has not approved Permit2 for this operation.");
        }
        if (live.susdfrTokenAllowance < plan.maxSusdfr) {
          throw new Error("sUSDfr has not approved Permit2 for this operation.");
        }
        if (live.usdcBalance < plan.expectedUsdc) {
          throw new Error("The treasury does not hold the expected USDC contribution.");
        }
        if (live.susdfrBalance < plan.expectedSusdfr) {
          throw new Error("The treasury does not hold the expected sUSDfr contribution.");
        }
        const block = await publicClient.getBlock({blockNumber: live.blockNumber});
        const permit = buildSusdfrPermitBatchMessage({
          plan,
          usdcNonce: live.usdcPermit.nonce,
          susdfrNonce: live.susdfrPermit.nonce,
          timestamp: Number(block.timestamp),
        });
        const alignment = await probeRpcAlignment(
          publicClient.request as RpcRequest,
          walletClient.transport.request as RpcRequest,
          {expectedChainId: mainnet.id, requireExactTip: false},
        );
        if (!alignment.aligned) throw new Error(alignment.message);

        setStatus({phase: "signing", message: "Sign the exact, 30-minute Permit2 allowance in the wallet."});
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
        const data = encodeSusdfrLiquidityTransaction({owner: address, plan, permit, signature});

        setStatus({phase: "simulating", message: "Simulating the exact signed transaction…"});
        await publicClient.call({
          account: address,
          to: V4_POSITION_MANAGER,
          data,
          gas: SUSDFR_LIQUIDITY_TX_GAS,
        });
        const [freshUsdcPermit, freshSusdfrPermit] = await Promise.all([
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
            args: [address, SUSDFR, V4_POSITION_MANAGER],
          }),
        ]);
        if (
          freshUsdcPermit[2] !== live.usdcPermit.nonce ||
          freshSusdfrPermit[2] !== live.susdfrPermit.nonce
        ) {
          throw new Error("A Permit2 nonce changed while preparing the transaction; refresh and sign again.");
        }

        setStatus({
          phase: "submitting",
          message: `${kind === "seed" ? "Initialize the pool and submit the seed" : "Submit the USDC-only wall"} in the wallet.`,
        });
        const hash = await walletClient.sendTransaction({
          account: address,
          chain: mainnet,
          to: V4_POSITION_MANAGER,
          data,
          gas: SUSDFR_LIQUIDITY_TX_GAS,
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
          message: "Transaction submitted. Waiting for receipt and exact position checks…",
          hash,
        });
        const receipt = await publicClient.waitForTransactionReceipt({
          hash,
          timeout: RECEIPT_TIMEOUT,
        });
        if (receipt.status !== "success") throw new Error("Transaction reverted on-chain.");
        const evidence = verifySusdfrMintReceipt({
          logs: receipt.logs as readonly SusdfrReceiptLog[],
          owner: address,
          plan,
        });
        const [positionLiquidity, positionOwner] = await Promise.all([
          publicClient.readContract({
            address: V4_POSITION_MANAGER,
            abi: SUSDFR_POSITION_MANAGER_ABI,
            functionName: "getPositionLiquidity",
            args: [evidence.tokenId],
          }),
          publicClient.readContract({
            address: V4_POSITION_MANAGER,
            abi: SUSDFR_POSITION_MANAGER_ABI,
            functionName: "ownerOf",
            args: [evidence.tokenId],
          }),
        ]);
        if (positionLiquidity !== plan.liquidity || positionOwner.toLowerCase() !== address.toLowerCase()) {
          throw new Error("The mined Uniswap position does not match the approved owner and liquidity.");
        }
        const confirmed = {hash, plan, evidence};
        writeStoredMint({
          ...stored,
          tokenId: evidence.tokenId.toString(),
          usdcSpent: evidence.usdcSpent.toString(),
          susdfrSpent: evidence.susdfrSpent.toString(),
        });
        if (kind === "seed") setSeed(confirmed);
        else setWall(confirmed);
        await loadSnapshot();
        setStatus({
          phase: "success",
          message:
            kind === "seed"
              ? `Pool and seed confirmed as position ${evidence.tokenId}. The USDC-only wall is unlocked.`
              : `USDC-only wall confirmed as position ${evidence.tokenId}. The operation is complete.`,
          hash,
        });
      } catch (error) {
        setStatus({phase: "error", message: messageFromError(error), hash: pendingHash});
      }
    },
    [address, connectedCorrectly, loadSnapshot, publicClient, seed, walletClient],
  );

  const busy = !["idle", "success", "error"].includes(status.phase) || loading;
  const currentPlan = seed ? wallPlan : seedPlan;
  const tokenApprovalsReady = Boolean(
    snapshot &&
      currentPlan &&
      snapshot.usdcTokenAllowance >= currentPlan.maxUsdc &&
      snapshot.susdfrTokenAllowance >= currentPlan.maxSusdfr,
  );
  const currentFundsReady = Boolean(
    snapshot &&
      currentPlan &&
      snapshot.usdcBalance >= currentPlan.expectedUsdc &&
      snapshot.susdfrBalance >= currentPlan.expectedSusdfr,
  );
  const poolUnexpectedlyInitialized = Boolean(snapshot?.sqrtPriceX96 && !seed);

  return (
    <div className="mx-auto max-w-4xl">
      <div className="rounded-card border border-line bg-raised p-5 md:p-7">
        <div className="flex flex-wrap items-start justify-between gap-5">
          <div>
            <p className="running-head text-accent">Execution identity</p>
            <p className="mt-2 font-mono text-[12px] text-ink">{LIQUIDITY_OPERATOR}</p>
            <p className="mt-2 max-w-[68ch] text-[13px] leading-relaxed text-ink-muted">
              Mainnet only. This initializes one fixed USDC/sUSDfr v4 pool at 1.0061,
              then creates a USDC-only wall from 0.84994 to 0.94990. The aggregate
              USDC cap across both positions is 250,000.
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
        {poolUnexpectedlyInitialized ? (
          <p role="alert" className="mt-5 rounded-card bg-danger-faint p-4 text-[13px] text-danger">
            The fixed pool is already initialized but this browser has no verified seed receipt.
            The guarded initializer is locked; do not create another pool or submit the wall.
          </p>
        ) : null}

        <dl className="mt-6 grid gap-4 border-t border-line pt-5 sm:grid-cols-3">
          <div>
            <dt className="running-head">Pool state</dt>
            <dd className="mt-1 text-[14px] text-ink">
              {snapshot ? (snapshot.sqrtPriceX96 === 0n ? "Uninitialized" : `Tick ${snapshot.tick.toLocaleString()}`) : "Not read"}
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

        <div className="mt-5 flex flex-wrap gap-3">
          <button
            type="button"
            onClick={() => void approveToken(USDC, "USDC")}
            disabled={!connectedCorrectly || busy || Boolean(snapshot && currentPlan && snapshot.usdcTokenAllowance >= currentPlan.maxUsdc)}
            className="rounded-pill border border-line px-5 py-2 text-[13px] text-ink disabled:opacity-45"
          >
            Approve USDC
          </button>
          <button
            type="button"
            onClick={() => void approveToken(SUSDFR, "sUSDfr")}
            disabled={!connectedCorrectly || busy || Boolean(snapshot && currentPlan && snapshot.susdfrTokenAllowance >= currentPlan.maxSusdfr)}
            className="rounded-pill border border-line px-5 py-2 text-[13px] text-ink disabled:opacity-45"
          >
            Approve sUSDfr
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
      </div>

      <section className="mt-6 rounded-card border border-line bg-raised p-5 md:p-7">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="running-head text-accent">Step 1</p>
            <h2 className="mt-1 text-[22px] font-semibold text-ink">Initialize + 50 USDC seed</h2>
          </div>
          <span className={`rounded-pill px-3 py-1 text-[12px] ${seed ? "bg-ok-faint text-ok" : "bg-app-toolbar text-ink-muted"}`}>
            {seed ? "Complete" : "Required"}
          </span>
        </div>
        <p className="mt-3 max-w-[68ch] text-[13.5px] leading-relaxed text-ink-muted">
          One atomic transaction initializes the exact pool at 1.0061 USDC per sUSDfr
          and mints an in-range test position. It can spend at most 50 USDC and
          154.280696 sUSDfr; the expected sUSDfr contribution is 104.307831.
        </p>
        <PlanTable plan={seedPlan} />
        {seed ? (
          <p className="mt-5 text-[13px] text-ok">
            Position {seed.evidence.tokenId.toString()} confirmed. It spent {formatToken(seed.evidence.usdcSpent, 6)} USDC and {formatToken(seed.evidence.susdfrSpent, SUSDFR_DECIMALS)} sUSDfr.
          </p>
        ) : (
          <button
            type="button"
            onClick={() => void executePlan("seed")}
            disabled={!connectedCorrectly || !tokenApprovalsReady || !currentFundsReady || poolUnexpectedlyInitialized || busy}
            className="mt-6 rounded-pill bg-accent px-6 py-2.5 text-[14px] font-medium text-raised transition-colors hover:bg-accent-strong disabled:cursor-not-allowed disabled:opacity-45"
          >
            Review and initialize seed
          </button>
        )}
      </section>

      <section className={`mt-6 rounded-card border p-5 md:p-7 ${seed ? "border-line bg-raised" : "border-dashed border-line-strong bg-card"}`}>
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="running-head text-accent">Step 2</p>
            <h2 className="mt-1 text-[22px] font-semibold text-ink">USDC-only 0.85–0.95 wall</h2>
          </div>
          <span className={`rounded-pill px-3 py-1 text-[12px] ${wall ? "bg-ok-faint text-ok" : "bg-app-toolbar text-ink-muted"}`}>
            {wall ? "Complete" : seed ? "Unlocked" : "Locked"}
          </span>
        </div>
        <p className="mt-3 max-w-[68ch] text-[13.5px] leading-relaxed text-ink-muted">
          This position uses only USDC while the live price remains above the wall.
          Its cap is the 250,000 USDC aggregate budget less the seed’s confirmed USDC spend.
          Any move into the wall range locks submission instead of asking for sUSDfr.
        </p>
        {wallPlan ? <PlanTable plan={wallPlan} /> : null}
        {!seed ? (
          <p className="mt-5 text-[13px] text-ink-faint">Complete and verify step 1 first.</p>
        ) : wall ? (
          <p className="mt-5 text-[13px] text-ok">
            Position {wall.evidence.tokenId.toString()} confirmed. Aggregate USDC spend is {formatToken(seed.evidence.usdcSpent + wall.evidence.usdcSpent, 6)}.
          </p>
        ) : wallPlan ? (
          <button
            type="button"
            onClick={() => void executePlan("wall")}
            disabled={!connectedCorrectly || !tokenApprovalsReady || !currentFundsReady || busy}
            className="mt-6 rounded-pill bg-accent px-6 py-2.5 text-[14px] font-medium text-raised transition-colors hover:bg-accent-strong disabled:cursor-not-allowed disabled:opacity-45"
          >
            Review and submit USDC wall
          </button>
        ) : (
          <p role="alert" className="mt-5 text-[13px] text-danger">
            The current pool price is not safely above the approved wall. Submission is locked.
          </p>
        )}
      </section>

      <StatusLine status={status} />

      <div className="mt-6 rounded-card border border-line bg-card p-5 text-[12.5px] leading-relaxed text-ink-faint">
        <p>
          Pool {SUSDFR_POOL_ID.slice(0, 12)}… · Position Manager {shortAddress(V4_POSITION_MANAGER)} · transaction gas limit {SUSDFR_LIQUIDITY_TX_GAS.toLocaleString()}.
        </p>
        <p className="mt-2">
          Aggregate USDC cap: {formatToken(TOTAL_USDC_CAP, 6)}. Seed cap: {formatToken(SEED_USDC_CAP, 6)}. Permit2 allowances expire after one hour; signatures can be submitted for 30 minutes.
        </p>
        <p className="mt-2">
          Each step refreshes pool state and nonces, signs exact token ceilings, simulates the final calldata, and verifies the mined pool, range, liquidity, owner, and token spends.
        </p>
      </div>
    </div>
  );
}
