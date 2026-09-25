import {createPublicClient, http} from "viem";
import {
  BRIDGE_HISTORY_ABI,
  DEFAULT_HISTORY_ABI,
  VAULT_HISTORY_ABI,
  WATERFALL_HISTORY_ABI,
} from "@/lib/abi";
import {
  CONTRACTS,
  IS_MAINNET,
  PROTOCOL_DEPLOYMENT_BLOCK,
  RPC_URL,
} from "@/config/contracts";
import {EXPECTED_CHAIN} from "@/lib/chain";
import {readBlockRangeChunked} from "@/lib/logs";
import {VERTICALS} from "@/lib/verticals";
import {
  serializeTransparencyHistory,
  summarizeTransparencyHistory,
  type TransparencyHistoryWire,
} from "@/lib/transparencyHistory";

function archiveRpcUrl(): string {
  const configured = process.env.ETHEREUM_ARCHIVE_RPC_URL?.trim();
  const value = configured || (IS_MAINNET ? "" : RPC_URL);
  if (!value) throw new Error("ETHEREUM_ARCHIVE_RPC_URL is required on mainnet");
  const url = new URL(value);
  if (url.protocol !== "https:" && !(url.hostname === "127.0.0.1" || url.hostname === "localhost")) {
    throw new Error("archive RPC must use HTTPS or loopback HTTP");
  }
  if (url.username || url.password) throw new Error("archive RPC must not contain URL credentials");
  return url.toString();
}

/** Reads all cumulative history at one archive-RPC block and returns JSON-safe totals. */
export async function loadTransparencyHistory(): Promise<TransparencyHistoryWire> {
  const client = createPublicClient({
    chain: EXPECTED_CHAIN,
    transport: http(archiveRpcUrl(), {timeout: 15_000, retryCount: 2}),
  });
  const asOfBlock = await client.getBlockNumber();
  if (asOfBlock < PROTOCOL_DEPLOYMENT_BLOCK) throw new Error("archive RPC is behind deployment");

  const waterfall = {address: CONTRACTS.WaterfallEngine!, abi: WATERFALL_HISTORY_ABI} as const;
  const vault = {address: CONTRACTS.sUSDfr!, abi: VAULT_HISTORY_ABI} as const;
  const [originated, funded, losses, originationFees, distributions, performanceFees, managementFees] =
    await Promise.all([
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({
          address: CONTRACTS.ClaimBridge!,
          abi: BRIDGE_HISTORY_ABI,
          eventName: "Originated",
          fromBlock,
          toBlock,
        })),
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({...waterfall, eventName: "Funded", fromBlock, toBlock})),
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({
          address: CONTRACTS.DefaultManager!,
          abi: DEFAULT_HISTORY_ABI,
          eventName: "LossRealized",
          fromBlock,
          toBlock,
        })),
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({...waterfall, eventName: "OriginationFeeCharged", fromBlock, toBlock})),
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({...waterfall, eventName: "Distributed", fromBlock, toBlock})),
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({...vault, eventName: "PerformanceFeeAccrued", fromBlock, toBlock})),
      readBlockRangeChunked(PROTOCOL_DEPLOYMENT_BLOCK, asOfBlock, (fromBlock, toBlock) =>
        client.getContractEvents({...vault, eventName: "ManagementFeeAccrued", fromBlock, toBlock})),
    ]);

  return serializeTransparencyHistory(summarizeTransparencyHistory({
    asOfBlock,
    classIds: VERTICALS.map((_, index) => index + 1),
    originated: originated.map((event) => event.args),
    funded: funded.map((event) => event.args),
    losses: losses.map((event) => event.args),
    originationFees: originationFees.map((event) => event.args),
    distributions: distributions.map((event) => event.args),
    performanceFees: performanceFees.map((event) => event.args),
    managementFees: managementFees.map((event) => event.args),
  }));
}
