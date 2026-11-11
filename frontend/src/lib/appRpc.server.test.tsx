// @vitest-environment node
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {createElement, type ReactNode} from "react";
import {renderToString} from "react-dom/server";
import {createPublicClient, http, type Abi} from "viem";
import {sepolia} from "viem/chains";
import {createAppTransport, RPC_PROXY_BATCH, SERVER_RENDER_RPC_MESSAGE, ServerRenderRpcError} from "@/lib/appRpc";
import {resetRpcProxyStateForTests} from "@/lib/rpcProxy.server";
import {BROWSER_HISTORY_CONCURRENCY, DEFAULT_BLOCK_CHUNK, readBlockRangeChunked} from "@/lib/logs";
import {RPC_PROXY_BROWSER_TIMEOUT_MS, RPC_PROXY_MAX_BATCH, RPC_PROXY_PATH} from "@/lib/rpcProxyShared";
import {POST} from "@/app/api/rpc/route";

/**
 * The proxy transport on the server, and through the real route.
 *
 * Proves rather than assumes three things the design depends on:
 *   - on the server the proxy transport refuses every read loudly and fetches nothing;
 *   - viem's http transport given the bare path cannot read on the server at all (Node's fetch has
 *     no document to resolve against), so no host is ever guessed;
 *   - Wagmi with `ssr: true` issues no RPC request while rendering on the server.
 * Then drives the browser transport's batching through the actual route handler.
 */

const SITE = "https://forestroadvault.com";
const UPSTREAM = "https://upstream-rpc.test.invalid/v2/TESTKEYabcdefghijklmnop0123456789";

let errorLog: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  errorLog = vi.spyOn(console, "error").mockImplementation(() => undefined);
});

afterEach(() => {
  errorLog.mockRestore();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("the proxy transport during server rendering", () => {
  it("refuses every read with a named error, logs it, and calls fetch never", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const client = createPublicClient({
      chain: sepolia,
      transport: createAppTransport({rpcUrl: RPC_PROXY_PATH, proxyMode: true, origin: undefined}),
    });
    const failure = await client.getBlockNumber().catch((error: unknown) => error as Error);
    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message).toContain(SERVER_RENDER_RPC_MESSAGE);
    expect((failure as {cause?: unknown}).cause).toBeInstanceOf(ServerRenderRpcError);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(errorLog).toHaveBeenCalledTimes(1);
    expect(String(errorLog.mock.calls[0][0])).toContain("Method: eth_blockNumber.");
  });

  it("is what appTransport() selects in a proxy-mode build with no window", async () => {
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", RPC_PROXY_PATH);
    vi.resetModules();
    const {appTransport} = await import("@/lib/appRpc");
    const transport = appTransport()({chain: sepolia});
    expect(transport.config.key).toBe("rpc-proxy-server-refusal");
    await expect(transport.request({method: "eth_chainId"})).rejects.toThrow(SERVER_RENDER_RPC_MESSAGE);
  });

  it("viem's http transport cannot read a bare path on the server, and contacts no host", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const client = createPublicClient({chain: sepolia, transport: http(RPC_PROXY_PATH, {retryCount: 0})});
    const failure = (await client.getBlockNumber().catch((error: unknown) => error)) as {
      name?: string;
      details?: string;
    };
    // viem builds a Request from the URL first, which Node refuses for a relative path, so fetch
    // is never reached with any host at all.
    expect(failure.name).toBe("HttpRequestError");
    expect(failure.details).toBe(`Failed to parse URL from ${RPC_PROXY_PATH}`);
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it("Wagmi (ssr: true) issues no RPC request while rendering the site's read hooks on the server", async () => {
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", RPC_PROXY_PATH);
    vi.resetModules();
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const {wagmiConfig} = await import("@/lib/wagmi");
    const wagmi = await import("wagmi");
    const {QueryClient, QueryClientProvider} = await import("@tanstack/react-query");
    const abi = [
      {type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{type: "uint256"}]},
    ] as const satisfies Abi;
    const address = "0x4761995f4f6daddf7886acd9d16e119ef2fb4132";

    function Reads(): ReactNode {
      const block = wagmi.useBlockNumber({query: {refetchInterval: 120_000}});
      const latest = wagmi.useBlock({query: {refetchInterval: 300_000}});
      const single = wagmi.useReadContract({address, abi, functionName: "totalAssets"});
      const many = wagmi.useReadContracts({contracts: [{address, abi, functionName: "totalAssets"}]});
      const client = wagmi.usePublicClient();
      wagmi.useWatchContractEvent({address, abi, onLogs: () => undefined});
      return createElement(
        "p",
        null,
        `${String(block.status)} ${String(latest.status)} ${String(single.status)} ${String(many.status)} ${client ? "client" : "none"}`,
      );
    }

    const html = renderToString(
      createElement(
        wagmi.WagmiProvider,
        {config: wagmiConfig},
        createElement(QueryClientProvider, {client: new QueryClient()}, createElement(Reads)),
      ),
    );
    // Give any stray promise a chance to reach the transport before asserting it never did.
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(html).toContain("pending pending pending pending client");
    expect(fetchSpy).not.toHaveBeenCalled();
    const logged = errorLog.mock.calls.map((args: unknown[]) => String(args[0]));
    expect(logged.filter((line: string) => line.includes(SERVER_RENDER_RPC_MESSAGE))).toEqual([]);
  });
});

describe("browser batching through the route", () => {
  type Seen = {route: unknown[]; upstream: unknown[]};

  /** fetch as a browser on SITE would see it: the route in-process, the upstream stubbed. */
  function wire(): Seen {
    const seen: Seen = {route: [], upstream: []};
    vi.stubEnv("RPC_PROXY_UPSTREAM_URL", UPSTREAM);
    resetRpcProxyStateForTests();
    vi.stubGlobal("fetch", async (url: string | URL | Request, init?: RequestInit) => {
      const target = String(url);
      const body = JSON.parse(String(init?.body)) as unknown;
      if (target === `${SITE}${RPC_PROXY_PATH}`) {
        seen.route.push(body);
        return POST(
          new Request(target, {
            method: "POST",
            headers: {"content-type": "application/json", origin: SITE, "sec-fetch-site": "same-origin"},
            body: JSON.stringify(body),
          }),
        );
      }
      if (target !== UPSTREAM) throw new Error(`unexpected fetch target ${target}`);
      seen.upstream.push(body);
      const answer = (entry: {id: number; method: string; params?: unknown[]}) => ({
        jsonrpc: "2.0",
        id: entry.id,
        result:
          entry.method === "eth_chainId"
            ? "0xaa36a7"
            : entry.method === "eth_getLogs"
              ? []
              : `0x6${String(entry.params?.[0]).slice(-4)}`,
      });
      return new Response(JSON.stringify(Array.isArray(body) ? body.map(answer) : answer(body as never)), {
        headers: {"content-type": "application/json"},
      });
    });
    return seen;
  }

  const addressFor = (i: number) => `0x${i.toString(16).padStart(40, "0")}` as const;

  it("uses an absolute same-origin URL and viem batching capped at the route's 20 entries", () => {
    const transport = createAppTransport({rpcUrl: RPC_PROXY_PATH, proxyMode: true, origin: SITE})({chain: sepolia});
    expect(transport.value?.url).toBe(`${SITE}${RPC_PROXY_PATH}`);
    // Longer than the proxy's worst case, so the browser sees the proxy's answer instead of retrying.
    expect(transport.config.timeout).toBe(RPC_PROXY_BROWSER_TIMEOUT_MS);
    expect(transport.config.timeout).toBeGreaterThan(5_000 + 20_000);
    expect(RPC_PROXY_BATCH.batchSize).toBe(RPC_PROXY_MAX_BATCH);
    expect(RPC_PROXY_BATCH.wait).toBeGreaterThan(0);
    expect(RPC_PROXY_BATCH.wait).toBeLessThanOrEqual(20);
  });

  it("splits a burst of 45 concurrent calls into batches of at most 20, and every call answers", async () => {
    const seen = wire();
    const client = createPublicClient({
      chain: sepolia,
      transport: createAppTransport({rpcUrl: RPC_PROXY_PATH, proxyMode: true, origin: SITE}),
    });
    const codes = await Promise.all(Array.from({length: 45}, (_, i) => client.getCode({address: addressFor(i + 1)})));
    expect(codes).toEqual(Array.from({length: 45}, (_, i) => `0x6${addressFor(i + 1).slice(-4)}`));
    const sizes = seen.route.map((body) => (Array.isArray(body) ? body.length : 1));
    expect(sizes.reduce((sum, size) => sum + size, 0)).toBe(45);
    expect(Math.max(...sizes)).toBeLessThanOrEqual(RPC_PROXY_MAX_BATCH);
    expect(sizes.length).toBe(3);
  });

  it("runs the yield panel's three history streams, three chunks each, as batched requests of nine", async () => {
    const seen = wire();
    const client = createPublicClient({
      chain: sepolia,
      transport: createAppTransport({rpcUrl: RPC_PROXY_PATH, proxyMode: true, origin: SITE}),
    });
    // 39 chunks per stream, today's height above the mainnet deployment block.
    const from = 26_006_832n;
    const to = from + 39n * DEFAULT_BLOCK_CHUNK - 1n;
    const stream = (address: `0x${string}`) =>
      readBlockRangeChunked(
        from,
        to,
        (fromBlock, toBlock) => client.getLogs({address, fromBlock, toBlock}),
        DEFAULT_BLOCK_CHUNK,
        BROWSER_HISTORY_CONCURRENCY,
      );
    await Promise.all([stream(addressFor(1)), stream(addressFor(2)), stream(addressFor(3))]);
    const logRequests = seen.route.filter((body) => Array.isArray(body) && body.every((entry) => entry.method === "eth_getLogs"));
    const sizes = logRequests.map((body) => (body as unknown[]).length);
    expect(sizes.reduce((sum, size) => sum + size, 0)).toBe(117);
    expect(Math.max(...sizes)).toBe(3 * BROWSER_HISTORY_CONCURRENCY);
    // Sequential chunks needed 39 round trips; three in flight need thirteen.
    expect(logRequests.length).toBe(Math.ceil(39 / BROWSER_HISTORY_CONCURRENCY));
  });

  it("fails only the refused entry of a batch; its neighbours answer", async () => {
    const seen = wire();
    const client = createPublicClient({
      chain: sepolia,
      transport: createAppTransport({rpcUrl: RPC_PROXY_PATH, proxyMode: true, origin: SITE}),
    });
    const results = await Promise.allSettled([
      client.getCode({address: addressFor(1)}),
      client.request({method: "eth_sendRawTransaction", params: ["0x02"]} as never),
      client.getCode({address: addressFor(2)}),
      client.getCode({address: addressFor(3)}),
    ]);
    expect(seen.route).toHaveLength(1);
    expect(seen.route[0]).toHaveLength(4);
    expect(results.map((result) => result.status)).toEqual(["fulfilled", "rejected", "fulfilled", "fulfilled"]);
    const refusal = (results[1] as PromiseRejectedResult).reason as {code?: number; name?: string};
    expect(refusal.code).toBe(-32601);
    expect(refusal.name).toBe("MethodNotFoundRpcError");
  });

  it("surfaces an upstream outage on a batch as an HTTP error for every call, not a TypeError", async () => {
    const seen = wire();
    vi.stubEnv("RPC_PROXY_UPSTREAM_URL", "");
    const client = createPublicClient({
      chain: sepolia,
      transport: createAppTransport({rpcUrl: RPC_PROXY_PATH, proxyMode: true, origin: SITE}),
    });
    const results = await Promise.allSettled([
      client.getCode({address: addressFor(1)}),
      client.getCode({address: addressFor(2)}),
    ]);
    expect(seen.route.length).toBeGreaterThanOrEqual(1);
    for (const result of results) {
      expect(result.status).toBe("rejected");
      const reason = (result as PromiseRejectedResult).reason as {name?: string; status?: number; message?: string};
      expect(reason.name).not.toBe("TypeError");
      expect(String(reason.message)).toContain("503");
      expect(String(reason.message)).not.toContain("TESTKEY");
    }
  });
});
