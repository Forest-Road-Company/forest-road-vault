import {cleanup, render} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {custom, parseAbi} from "viem";
import {sepolia} from "viem/chains";
import {createConfig, WagmiProvider} from "wagmi";
import {RestartingEventWatcher} from "@/components/app/RestartingEventWatcher";
import {rpcProxyEntryRefusal} from "@/lib/rpcProxy.server";

/**
 * viem's real contract-event watcher, through Wagmi, against a stub node that applies the RPC proxy's
 * own per-entry rules. The node's tip jumps 200,000 blocks, as after a laptop slept for weeks, so the
 * watcher's catch-up eth_getLogs is wider than the proxy's 100,000-block limit and is refused.
 */

const QUEUE = "0x00000000000000000000000000000000000000a1";
const abi = parseAbi(["event RequestFilled(uint256 indexed id)"]);

type Node = {calls: {method: string; refused: boolean; span?: bigint}[]; request: (args: {method: string; params?: unknown}) => Promise<unknown>};

/** "refusal": the tip jumps 200,000 blocks after the first read. "outage": no jump; every eth_getLogs fails. */
function stubNode(failure: "refusal" | "outage"): Node {
  let tip = 1_000n;
  let jumped = false;
  const calls: Node["calls"] = [];
  async function request({method, params}: {method: string; params?: unknown}): Promise<unknown> {
    const list = (params ?? []) as unknown[];
    const refusal = rpcProxyEntryRefusal({method, params: list});
    const filter = list[0] as {fromBlock?: string; toBlock?: string} | undefined;
    const span = method === "eth_getLogs" && filter?.fromBlock && filter.toBlock ? BigInt(filter.toBlock) - BigInt(filter.fromBlock) + 1n : undefined;
    if (refusal) {
      calls.push({method, refused: true, span});
      throw Object.assign(new Error(refusal.message), {code: refusal.code});
    }
    if (failure === "outage" && method === "eth_getLogs") {
      calls.push({method, refused: true, span});
      throw Object.assign(new Error("Upstream RPC unavailable"), {code: -32603});
    }
    calls.push({method, refused: false, span});
    if (method === "eth_chainId") return "0xaa36a7";
    if (method === "eth_blockNumber") {
      // The first answer is before the sleep; every later one is after it, and the chain moves on.
      if (failure === "refusal" && !jumped && calls.filter((call) => call.method === "eth_blockNumber").length > 1) {
        jumped = true;
        tip += 200_000n;
      } else if (jumped || failure === "outage") {
        tip += 1n;
      }
      return `0x${tip.toString(16)}`;
    }
    if (method === "eth_getLogs") return [];
    throw new Error(`stub has no answer for ${method}`);
  }
  return {calls, request};
}

function mount(node: Node, onLogs = vi.fn()) {
  const config = createConfig({
    chains: [sepolia],
    connectors: [],
    transports: {[sepolia.id]: custom({request: node.request}, {retryCount: 0})},
    // The site's watcher polls once a minute, well past viem's block-number cache; so must this one.
    cacheTime: 0,
  });
  render(
    <WagmiProvider config={config}>
      <RestartingEventWatcher
        label="test.queue_watcher"
        address={QUEUE}
        abi={abi}
        pollingInterval={10}
        restartDelayMs={40}
        onLogs={onLogs}
      />
    </WagmiProvider>,
  );
}

let warn: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
});
afterEach(() => {
  cleanup();
  warn.mockRestore();
});

const logReads = (node: Node) => node.calls.filter((call) => call.method === "eth_getLogs");
const warnings = (): string[] => warn.mock.calls.map((args: unknown[]) => String(args[0]));

describe("the queue watcher after a long sleep (review N1)", () => {
  it("restarts from the current block once its catch-up read is refused, and reads logs again", async () => {
    const node = stubNode("refusal");
    mount(node);
    // The catch-up after the jump is refused: wider than 100,000 blocks.
    await vi.waitFor(() => expect(logReads(node).some((call) => call.refused && call.span! > 100_000n)).toBe(true), {timeout: 3_000});
    // After the restart, the watcher reads narrow ranges from the new tip, and they are answered.
    await vi.waitFor(() => expect(logReads(node).some((call) => !call.refused)).toBe(true), {timeout: 3_000});
    const restarts = warnings().filter((line) => line.startsWith("test.queue_watcher_restart"));
    expect(restarts[0]).toBe("test.queue_watcher_restart InvalidParamsRpcError");
    // The expected eth_newFilter refusal is not an error and restarts nothing.
    expect(node.calls.some((call) => call.method === "eth_newFilter" && call.refused)).toBe(true);
  });

  it("does not hide a non-refusal error, and restarts at most once per delay, never in a tight loop", async () => {
    const node = stubNode("outage");
    mount(node);
    await new Promise((resolve) => setTimeout(resolve, 400));
    const restarts = warnings().filter((line) => line.startsWith("test.queue_watcher_restart"));
    expect(restarts.length).toBeGreaterThanOrEqual(1);
    expect(restarts, JSON.stringify(restarts)).toEqual(restarts.map(() => "test.queue_watcher_restart InternalRpcError"));
    // Polls every 10 ms and fails every log read, yet restarts no more than once per 40 ms.
    expect(logReads(node).length).toBeGreaterThan(restarts.length * 2);
    expect(restarts.length).toBeLessThanOrEqual(400 / 40 + 1);
  });
});
