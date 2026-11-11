// @vitest-environment node
import {describe, expect, it} from "vitest";
import {createPublicClient, custom, type Hex} from "viem";
import {sepolia} from "viem/chains";
import {
  RECEIPT_STATUS_UNKNOWN_MESSAGE,
  RECEIPT_WAIT_RESTARTS,
  ReceiptStatusUnknownError,
  waitForReceiptRobustly,
} from "@/lib/receiptWait";

/**
 * viem's real waitForTransactionReceipt against a stub node. While the sent transaction is pending,
 * viem reads each new block with its full transactions (the replacement check); the stub answers
 * that read with the RPC proxy's -32008 "too big" error, as the proxy does for an oversized block.
 */

const SENT: Hex = `0x${"11".repeat(32)}`;
const WALLET = "0x7fde000000000000000000000000000000008337";
const VAULT = "0x4761995f4f6daddf7886acd9d16e119ef2fb4132";
const BLOCK_HASH: Hex = `0x${"44".repeat(32)}`;
const noSleep = async () => undefined;

type NodeScript = {
  /** Which full-block reads fail with the proxy's -32008 (by call order, 1-based); true for all. */
  oversizedBlockReads: Set<number> | true;
  /** The receipt appears once this many full-block reads have happened. */
  minedAfterBlockReads: number;
  receiptStatus?: "0x1" | "0x0";
};

function stubNode(script: NodeScript) {
  let block = 0x100;
  let blockReads = 0;
  const receipt = () => ({
    transactionHash: SENT,
    blockHash: BLOCK_HASH,
    blockNumber: `0x${block.toString(16)}`,
    transactionIndex: "0x0",
    from: WALLET,
    to: VAULT,
    status: script.receiptStatus ?? "0x1",
    gasUsed: "0x5208",
    cumulativeGasUsed: "0x5208",
    effectiveGasPrice: "0x1",
    logs: [],
    logsBloom: `0x${"00".repeat(256)}`,
    type: "0x2",
    contractAddress: null,
  });
  async function request({method, params}: {method: string; params?: unknown}): Promise<unknown> {
    const args = (params ?? []) as unknown[];
    switch (method) {
      case "eth_blockNumber":
        block += 1;
        return `0x${block.toString(16)}`;
      case "eth_getTransactionByHash":
        return {hash: SENT, from: WALLET, to: VAULT, nonce: "0x5", value: "0x0", input: "0x", gas: "0x5208", type: "0x2",
          maxFeePerGas: "0x2", maxPriorityFeePerGas: "0x1", chainId: "0xaa36a7", blockHash: null, blockNumber: null, transactionIndex: null};
      case "eth_getTransactionReceipt":
        return blockReads >= script.minedAfterBlockReads ? receipt() : null;
      case "eth_getBlockByNumber": {
        if (args[1] === true) {
          blockReads += 1;
          if (script.oversizedBlockReads === true || script.oversizedBlockReads.has(blockReads)) {
            throw Object.assign(new Error("Response is too big for the RPC proxy: narrow the request"), {code: -32008});
          }
        }
        return {number: args[0], hash: BLOCK_HASH, parentHash: BLOCK_HASH, timestamp: "0x6729f000", transactions: []};
      }
      default:
        throw new Error(`stub has no answer for ${method}`);
    }
  }
  const client = createPublicClient({
    chain: sepolia,
    transport: custom({request}, {retryCount: 0}),
    pollingInterval: 5,
    cacheTime: 0,
  });
  return {client, blockReads: () => blockReads};
}

describe("waitForReceiptRobustly", () => {
  it("shows the problem it fixes: viem's own wait rejects when the pending check's block is too big", async () => {
    const node = stubNode({oversizedBlockReads: new Set([1]), minedAfterBlockReads: 2});
    await expect(node.client.waitForTransactionReceipt({hash: SENT, timeout: 5_000})).rejects.toThrow(/too big for the RPC proxy/);
  });

  it("restarts after the oversized block and returns the receipt once it is mined", async () => {
    const node = stubNode({oversizedBlockReads: new Set([1]), minedAfterBlockReads: 1});
    const receipt = await waitForReceiptRobustly(node.client, {hash: SENT, timeout: 5_000}, {sleep: noSleep});
    expect(receipt.transactionHash).toBe(SENT);
    expect(receipt.status).toBe("success");
  });

  it("returns a reverted receipt as reverted, never as success", async () => {
    const node = stubNode({oversizedBlockReads: new Set([1]), minedAfterBlockReads: 1, receiptStatus: "0x0"});
    const receipt = await waitForReceiptRobustly(node.client, {hash: SENT, timeout: 5_000}, {sleep: noSleep});
    expect(receipt.status).toBe("reverted");
  });

  it("gives up after its restarts with status unknown, naming the hash, never a success", async () => {
    const node = stubNode({oversizedBlockReads: true, minedAfterBlockReads: Number.POSITIVE_INFINITY});
    const pauses: number[] = [];
    const failure = await waitForReceiptRobustly(node.client, {hash: SENT, timeout: 5_000}, {
      sleep: async (ms) => {
        pauses.push(ms);
      },
    }).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(ReceiptStatusUnknownError);
    expect((failure as ReceiptStatusUnknownError).hash).toBe(SENT);
    expect((failure as Error).message).toBe(RECEIPT_STATUS_UNKNOWN_MESSAGE);
    expect(String(((failure as Error).cause as Error).message)).toMatch(/too big for the RPC proxy/);
    expect(node.blockReads()).toBe(RECEIPT_WAIT_RESTARTS + 1);
    // One slot apart, so each restart reads a newer block.
    expect(pauses).toEqual(Array(RECEIPT_WAIT_RESTARTS).fill(12_000));
  });

  it("passes the overall wait timeout through unchanged, without restarting", async () => {
    const node = stubNode({oversizedBlockReads: new Set(), minedAfterBlockReads: Number.POSITIVE_INFINITY});
    let restarts = 0;
    const failure = await waitForReceiptRobustly(node.client, {hash: SENT, timeout: 60}, {
      sleep: async () => {
        restarts += 1;
      },
    }).catch((error: unknown) => error);
    expect((failure as Error).name).toBe("WaitForTransactionReceiptTimeoutError");
    expect(restarts).toBe(0);
  });
});
