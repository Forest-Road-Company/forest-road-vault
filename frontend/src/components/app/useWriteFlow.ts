"use client";

/**
 * The single write-path state machine (CLAUDE.md §2.2/3.3): every on-chain write in
 * the app goes simulate → sign → wait-for-receipt through this hook, so no write can
 * skip simulation, and every failure surfaces a decoded, human-readable revert.
 */

import {useCallback, useEffect, useRef, useState} from "react";
import {
  useAccount,
  useConfig,
  usePublicClient,
  useWalletClient,
  useWriteContract,
} from "wagmi";
import {getConnection} from "wagmi/actions";
import {useQueryClient} from "@tanstack/react-query";
import {createPublicClient, custom, type Abi, type Address} from "viem";
import {IS_LOCAL_FORK} from "@/config/contracts";
import {decodeWriteError} from "@/lib/errors";
import {probeRpcAlignment, type RpcRequest} from "@/lib/rpcAlignment";
import {EXPECTED_CHAIN} from "@/lib/wagmi";

const RECEIPT_TIMEOUT_MS = 90_000;

export type WriteStatus =
  | {phase: "idle"}
  | {phase: "simulating"}
  | {phase: "signing"}
  | {phase: "pending"; hash: `0x${string}`}
  | {phase: "success"; hash: `0x${string}`}
  | {phase: "error"; message: string; errorName: string | null};

export function useWriteFlow() {
  const [status, setStatus] = useState<WriteStatus>({phase: "idle"});
  const publicClient = usePublicClient();
  const {data: walletClient} = useWalletClient();
  const {address} = useAccount();
  const {writeContractAsync} = useWriteContract();
  const queryClient = useQueryClient();
  const config = useConfig();
  const flowGeneration = useRef(0);

  // A status belongs to the account that produced it — clear it on switch
  // (derived-state reset during render, per React's adjust-state-on-prop-change
  // pattern; an effect would lag one paint and trip set-state-in-effect).
  const [statusOwner, setStatusOwner] = useState(address);
  if (statusOwner !== address) {
    setStatusOwner(address);
    setStatus({phase: "idle"});
  }
  useEffect(() => {
    // Invalidate every async continuation from the prior wallet session. The
    // render-time owner reset above keeps stale status out of the new account's UI;
    // this generation gate also suppresses its eventual callback/onSuccess.
    flowGeneration.current += 1;
  }, [address]);

  const run = useCallback(
    async (params: {
      address: Address;
      abi: Abi;
      functionName: string;
      args: readonly unknown[];
      onSuccess?: () => void;
    }) => {
      if (!address) {
        setStatus({
          phase: "error",
          message: "Connect a wallet before submitting a transaction.",
          errorName: "WalletNotConnected",
        });
        return;
      }
      if (!walletClient) {
        setStatus({
          phase: "error",
          message: "Your wallet connection is still initializing. Please retry.",
          errorName: "WalletInitializing",
        });
        return;
      }
      if (!publicClient) {
        setStatus({
          phase: "error",
          message: "The configured chain connection is unavailable. Please retry.",
          errorName: "RpcUnavailable",
        });
        return;
      }
      const owner = address;
      const generation = ++flowGeneration.current;
      const isCurrentFlow = () =>
        flowGeneration.current === generation &&
        getConnection(config).address?.toLowerCase() === owner.toLowerCase();
      const setCurrentStatus = (next: WriteStatus) => {
        if (isCurrentFlow()) setStatus(next);
      };
      try {
        setCurrentStatus({phase: "simulating"});
        const beforeSimulation = await probeRpcAlignment(
          publicClient.request as RpcRequest,
          walletClient.transport.request as RpcRequest,
          {
            expectedChainId: EXPECTED_CHAIN.id,
            requireExactTip: IS_LOCAL_FORK,
          },
        );
        if (!beforeSimulation.aligned) {
          throw new Error(`RPC mismatch: ${beforeSimulation.message}`);
        }
        if (!isCurrentFlow()) return;
        // Independent local nodes never propagate transactions to one another. In
        // local-fork mode the wallet provider is therefore authoritative for the
        // simulation and receipt as well as submission. The configured public RPC
        // remains available for disconnected/server reads only.
        const executionClient = IS_LOCAL_FORK
          ? createPublicClient({
              chain: EXPECTED_CHAIN,
              transport: custom(walletClient),
            })
          : publicClient;
        const {request} = await executionClient.simulateContract({
          account: address,
          address: params.address,
          abi: params.abi,
          functionName: params.functionName,
          args: params.args as unknown[],
        });
        const beforeSubmission = await probeRpcAlignment(
          publicClient.request as RpcRequest,
          walletClient.transport.request as RpcRequest,
          {
            expectedChainId: EXPECTED_CHAIN.id,
            requireExactTip: IS_LOCAL_FORK,
          },
        );
        if (!beforeSubmission.aligned) {
          throw new Error(`RPC mismatch: ${beforeSubmission.message}`);
        }
        if (!isCurrentFlow()) return;
        setCurrentStatus({phase: "signing"});
        // chainId makes wagmi assert the wallet is on the build-selected chain at submission time
        // (ChainMismatchError instead of a real tx on the wrong chain). Without it,
        // simulation can run against one network while the tx goes to another.
        const hash = await writeContractAsync({...request, chainId: EXPECTED_CHAIN.id});
        setCurrentStatus({phase: "pending", hash});
        const replacement: {reason?: "cancelled" | "replaced" | "repriced"} = {};
        const receipt = await executionClient.waitForTransactionReceipt({
          hash,
          timeout: RECEIPT_TIMEOUT_MS,
          onReplaced: ({reason}) => {
            replacement.reason = reason;
          },
        });
        const minedHash = receipt.transactionHash;
        if (receipt.status !== "success") {
          // A tx that simulated fine but reverted on-chain — report it, never mask it.
          setCurrentStatus({
            phase: "error",
            message: "Transaction reverted on-chain.",
            errorName: null,
          });
          return;
        }
        // Refresh every on-chain read (balances, allowances, queue state) BEFORE
        // reporting success, so buttons/labels never show a pre-write state next
        // to a "Confirmed." line.
        await queryClient.invalidateQueries();
        if (!isCurrentFlow()) return;
        if (replacement.reason === "cancelled" || replacement.reason === "replaced") {
          setCurrentStatus({
            phase: "error",
            message:
              replacement.reason === "cancelled"
                ? "Transaction cancelled in the wallet."
                : "Transaction replaced by a different wallet transaction; the requested action was not confirmed.",
            errorName:
              replacement.reason === "cancelled"
                ? "TransactionCancelled"
                : "TransactionReplaced",
          });
          return;
        }
        // A repriced/speed-up transaction is the same call at the same nonce. Report
        // the hash that actually mined; the superseded hash has no receipt.
        setCurrentStatus({phase: "success", hash: minedHash});
        if (isCurrentFlow()) params.onSuccess?.();
      } catch (err) {
        const decoded = decodeWriteError(err);
        setCurrentStatus({
          phase: "error",
          message: decoded.message,
          errorName: decoded.errorName,
        });
        // A timed-out wait can still land on-chain later — refresh reads anyway.
        void queryClient.invalidateQueries();
      }
    },
    [publicClient, walletClient, address, writeContractAsync, queryClient, config],
  );

  // AUDIT FIX (RC-05): `reset` must never orphan an in-flight write. Bumping the
  // generation while a transaction is simulating, awaiting signature, or already
  // submitted would leave that transaction unable to report its own outcome — every
  // continuation is gated on `isCurrentFlow()`, so an on-chain revert would be
  // swallowed and the card would sit at "idle" while the transaction is live.
  // Callers that switch context should also disable their control while `busy`.
  const statusRef = useRef<WriteStatus>(status);
  useEffect(() => {
    statusRef.current = status;
  }, [status]);

  const reset = useCallback(() => {
    const phase = statusRef.current.phase;
    if (phase === "simulating" || phase === "signing" || phase === "pending") return;
    flowGeneration.current += 1;
    setStatus({phase: "idle"});
  }, []);

  const busy =
    status.phase === "simulating" || status.phase === "signing" || status.phase === "pending";

  return {status, run, reset, busy};
}
