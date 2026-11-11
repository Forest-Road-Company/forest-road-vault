// @vitest-environment node
import {describe, expect, it} from "vitest";
import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeAbiParameters,
  encodeFunctionResult,
  multicall3Abi,
  parseAbi,
  parseAbiItem,
  type Hex,
} from "viem";
import {sepolia} from "viem/chains";
import {RPC_PROXY_ALLOWED_METHODS, rpcProxyEntryRefusal} from "@/lib/rpcProxy.server";
import {DEFAULT_BLOCK_CHUNK, readBlockRangeChunked} from "@/lib/logs";
import {TREASURY_HISTORY_CHUNK} from "@/lib/morphoTreasury";
import {probeRpcAlignment, type RpcRequest} from "@/lib/rpcAlignment";

/**
 * The method census behind the proxy's allowlist.
 *
 * Runs every viem action the site's browser code calls, the way it calls them, against a node stub
 * that refuses anything off the allowlist exactly as the proxy does (-32601). It then asserts:
 *   1. every action still succeeds through that refusal;
 *   2. the methods actually answered are EXACTLY the allowlist: a missing entry fails here, and so
 *      does an entry nothing uses;
 *   3. the only method ever refused is eth_newFilter, from the event watcher, which then falls back
 *      to eth_blockNumber and eth_getLogs.
 * A viem or Wagmi upgrade that starts sending something new fails this test before it fails a user.
 */

const VAULT = "0x4761995f4f6daddf7886acd9d16e119ef2fb4132";
const WALLET = "0x7fde000000000000000000000000000000008337";
const OTHER = "0x00000000000000000000000000000000000000aa";
const SENT: Hex = `0x${"11".repeat(32)}`;
const REPLACEMENT: Hex = `0x${"22".repeat(32)}`;
const MINED: Hex = `0x${"33".repeat(32)}`;
const BLOCK_HASH: Hex = `0x${"44".repeat(32)}`;

const abi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
]);

function stubNode() {
  const answered: string[] = [];
  const refused: string[] = [];
  let block = 0x100;

  const receipt = (hash: Hex) => ({
    transactionHash: hash,
    blockHash: BLOCK_HASH,
    blockNumber: "0x101",
    transactionIndex: "0x0",
    from: WALLET,
    to: VAULT,
    status: "0x1",
    gasUsed: "0x5208",
    cumulativeGasUsed: "0x5208",
    effectiveGasPrice: "0x1",
    logs: [],
    logsBloom: `0x${"00".repeat(256)}`,
    type: "0x2",
    contractAddress: null,
  });
  const transaction = (hash: Hex, input: Hex) => ({
    hash,
    from: WALLET,
    to: VAULT,
    nonce: "0x5",
    value: "0x0",
    input,
    gas: "0x5208",
    type: "0x2",
    maxFeePerGas: "0x2",
    maxPriorityFeePerGas: "0x1",
    chainId: "0xaa36a7",
    blockHash: null,
    blockNumber: null,
    transactionIndex: null,
  });

  async function request({method, params}: {method: string; params?: unknown}): Promise<unknown> {
    // The proxy's own per-entry rules: the method allowlist and the request shapes.
    const refusal = rpcProxyEntryRefusal({method, params: params as unknown[] | undefined});
    if (refusal) {
      refused.push(refusal.code === -32601 ? method : `${method} (shape)`);
      throw Object.assign(new Error(refusal.message), {code: refusal.code});
    }
    answered.push(method);
    const args = (params ?? []) as unknown[];
    switch (method) {
      case "eth_chainId":
        return "0xaa36a7";
      case "eth_blockNumber":
        block += 1;
        return `0x${block.toString(16)}`;
      case "eth_getBlockByNumber": {
        const withTransactions = args[1] === true;
        return {
          number: typeof args[0] === "string" && args[0].startsWith("0x") ? args[0] : `0x${block.toString(16)}`,
          hash: BLOCK_HASH,
          parentHash: BLOCK_HASH,
          timestamp: "0x6729f000",
          baseFeePerGas: "0x1",
          gasLimit: "0x1c9c380",
          gasUsed: "0x0",
          transactions: withTransactions ? [transaction(REPLACEMENT, "0x01")] : [],
        };
      }
      case "eth_call": {
        const call = args[0] as {to: string; data: Hex};
        if (call.to.toLowerCase() === sepolia.contracts.multicall3.address.toLowerCase()) {
          const {args: decoded} = decodeFunctionData({abi: multicall3Abi, data: call.data});
          const calls = decoded[0] as readonly unknown[];
          return encodeFunctionResult({
            abi: multicall3Abi,
            functionName: "aggregate3",
            result: calls.map(() => ({success: true, returnData: encodeAbiParameters([{type: "uint256"}], [7n])})),
          });
        }
        return encodeAbiParameters([{type: "uint256"}], [7n]);
      }
      case "eth_estimateGas":
        return "0x5208";
      case "eth_getCode":
        return "0x6000";
      case "eth_getLogs":
        return [];
      case "eth_getTransactionByHash":
        return transaction(SENT, "0x00");
      case "eth_getTransactionReceipt":
        // The sent transaction never mines: it was replaced by REPLACEMENT.
        return args[0] === SENT ? null : receipt(args[0] as Hex);
      default:
        throw new Error(`stub has no answer for ${method}`);
    }
  }

  return {answered, refused, request};
}

describe("the proxy allowlist is exactly what the site's browser actions send", () => {
  it("runs every browser action through a proxy-shaped node", async () => {
    const node = stubNode();
    // As Wagmi builds its clients: Multicall3 batching on, fast polling for the test.
    const client = createPublicClient({
      chain: sepolia,
      transport: custom({request: node.request}, {retryCount: 0}),
      batch: {multicall: true},
      pollingInterval: 5,
      cacheTime: 0,
    });

    // Reads: useReadContract(s) and readContract (batched into Multicall3), multicall, call.
    expect(await client.readContract({address: VAULT, abi, functionName: "totalAssets"})).toBe(7n);
    const [batched] = await client.multicall({contracts: [{address: VAULT, abi, functionName: "totalAssets"}]});
    expect(batched).toEqual({status: "success", result: 7n});
    expect((await client.call({to: OTHER, data: "0x"})).data).toMatch(/^0x/);

    // The write flow: simulate, size gas, then wait for the receipt (here, through a replacement).
    const {result} = await client.simulateContract({
      account: WALLET,
      address: VAULT,
      abi,
      functionName: "deposit",
      args: [1n, WALLET],
    });
    expect(result).toBe(7n);
    expect(
      await client.estimateContractGas({account: WALLET, address: VAULT, abi, functionName: "deposit", args: [1n, WALLET]}),
    ).toBe(21_000n);
    let replaced: string | undefined;
    const viaReplacement = await client.waitForTransactionReceipt({
      hash: SENT,
      timeout: 5_000,
      onReplaced: ({reason}) => {
        replaced = reason;
      },
    });
    expect(viaReplacement.transactionHash).toBe(REPLACEMENT);
    expect(replaced).toBe("replaced");
    expect((await client.getTransactionReceipt({hash: MINED})).status).toBe("success");

    // Blocks, chain and code: getBlock, getBlockNumber, getChainId, getCode.
    expect((await client.getBlock()).hash).toBe(BLOCK_HASH);
    expect((await client.getBlock({blockNumber: 0x100n})).number).toBe(0x100n);
    expect(await client.getBlockNumber()).toBeGreaterThan(0n);
    expect(await client.getChainId()).toBe(11155111);
    expect(await client.getCode({address: VAULT})).toBe("0x6000");

    // History: getContractEvents and getLogs, always with an address.
    expect(await client.getContractEvents({address: VAULT, abi, eventName: "Deposit", fromBlock: 1n, toBlock: 2n})).toEqual([]);
    expect(
      await client.getLogs({
        address: VAULT,
        event: parseAbiItem("event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)"),
        fromBlock: 1n,
        toBlock: 2n,
      }),
    ).toEqual([]);

    // The widest ranges the site reads: 9,000-block history chunks (YieldPositionPanel) and the
    // Morpho treasury's 1,000-block chunks, read the way those callers read them.
    const deployment = 26_006_832n;
    await readBlockRangeChunked(
      deployment,
      deployment + 2n * DEFAULT_BLOCK_CHUNK - 1n,
      (fromBlock, toBlock) => client.getContractEvents({address: VAULT, abi, eventName: "Deposit", fromBlock, toBlock}),
      DEFAULT_BLOCK_CHUNK,
      3,
    );
    await client.getLogs({address: VAULT, fromBlock: deployment, toBlock: deployment + TREASURY_HISTORY_CHUNK - 1n, strict: true,
      event: parseAbiItem("event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)")});

    // useWatchContractEvent over HTTP: the filter is refused, the watcher falls back to getLogs.
    const errors: Error[] = [];
    const logsBefore = node.answered.filter((method) => method === "eth_getLogs").length;
    const unwatch = client.watchContractEvent({
      address: VAULT,
      abi,
      pollingInterval: 5,
      onLogs: () => undefined,
      onError: (error) => errors.push(error),
    });
    await new Promise((resolve) => setTimeout(resolve, 120));
    unwatch();
    expect(errors).toEqual([]);
    expect(node.answered.filter((method) => method === "eth_getLogs").length).toBeGreaterThan(logsBefore);

    // rpcAlignment's raw probe (both sides on this transport, as under WalletConnect).
    const alignment = await probeRpcAlignment(client.request as RpcRequest, client.request as RpcRequest, {
      expectedChainId: 11155111,
      requireExactTip: false,
    });
    expect(alignment.aligned).toBe(true);

    expect([...new Set(node.answered)].sort()).toEqual([...RPC_PROXY_ALLOWED_METHODS].sort());
    expect([...new Set(node.refused)]).toEqual(["eth_newFilter"]);
  });
});
