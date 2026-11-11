// @vitest-environment node
import {inspect} from "node:util";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT} from "./route";
import {
  handleRpcProxyRequest,
  RPC_PROXY_ALLOWED_METHODS,
  RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS,
  RPC_PROXY_MAX_RESPONSE_BYTES,
  RPC_PROXY_UPSTREAM_TIMEOUT_MS,
  RPC_PROXY_MAX_UPSTREAM_BYTES,
  RPC_PROXY_RESPONSE_TOO_BIG,
  resetRpcProxyStateForTests,
} from "@/lib/rpcProxy.server";
import {RPC_PROXY_MAX_BATCH, RPC_PROXY_MAX_BODY_BYTES} from "@/lib/rpcProxyShared";

/**
 * The proxy route through its exported handlers, with a stub upstream in place of global fetch.
 * The vitest profile builds for Sepolia (11155111), so a healthy upstream answers 0xaa36a7.
 */

const KEY = "TESTKEYabcdefghijklmnop0123456789";
const UPSTREAM_HOST = "upstream-rpc.test.invalid";
const UPSTREAM = `https://${UPSTREAM_HOST}/v2/${KEY}`;
const SEPOLIA = "0xaa36a7";
const SITE = "https://forestroadvault.com";
const ADDRESS = "0x4761995f4f6daddf7886acd9d16e119ef2fb4132";
/** A log filter as the site sends it: one contract, numeric bounds 9,000 blocks apart. */
const LOGS = {address: ADDRESS, fromBlock: "0x18cd630", toBlock: "0x18cf937"};
/** An eth_call transaction as the site sends it. */
const TX = {to: ADDRESS, data: "0x"};

type Upstream = {
  /** The eth_chainId answer, or an error to throw from fetch. */
  chain: string | Error | ((init: RequestInit) => Response | Promise<Response>);
  /** Answers a forwarded payload; defaults to echoing a result per entry. */
  forward: (payload: unknown, init: RequestInit) => Response | Promise<Response>;
};

let upstream: Upstream;
let fetchMock: ReturnType<typeof vi.fn>;
let errorLog: ReturnType<typeof vi.spyOn>;
/** Every console method, so a leak through log, info, warn or debug is caught as well as error. */
const CONSOLE_METHODS = ["log", "info", "warn", "error", "debug"] as const;
let consoleSpies: ReturnType<typeof vi.spyOn>[] = [];

/** Everything any console method was given, every argument, with error messages, stacks and causes. */
function everythingLogged(): string {
  return consoleSpies
    .flatMap((spy) => spy.mock.calls)
    .flatMap((args) => args)
    .map((arg) => (typeof arg === "string" ? arg : inspect(arg, {depth: 10, showHidden: true})))
    .join("\n");
}

/** An upstream that never answers: it rejects as fetch does once its signal aborts, with URL text. */
function untilAborted(init: RequestInit): Promise<Response> {
  return new Promise((_resolve, reject) => {
    const signal = init.signal!;
    const fail = () => reject(Object.assign(new Error(`The operation was aborted: ${UPSTREAM}`, {cause: signal.reason}), {name: "AbortError"}));
    if (signal.aborted) fail();
    else signal.addEventListener("abort", fail, {once: true});
  });
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {status, headers: {"content-type": "application/json"}});
}

/** Default upstream: every forwarded entry answers `result: "0x<id>-<method>"`. */
function echo(payload: unknown): Response {
  const answer = (entry: {id: number; method: string}) => ({
    jsonrpc: "2.0",
    id: entry.id,
    result: `ok:${entry.method}:${entry.id}`,
  });
  return jsonResponse(Array.isArray(payload) ? payload.map(answer) : answer(payload as {id: number; method: string}));
}

function isChainProbe(payload: unknown): boolean {
  return !Array.isArray(payload) && (payload as {method?: string}).method === "eth_chainId";
}

function chainProbes(): number {
  return fetchMock.mock.calls.filter(([, init]) => isChainProbe(JSON.parse(String((init as RequestInit).body)))).length;
}

function forwardedPayloads(): unknown[] {
  return fetchMock.mock.calls
    .map(([, init]) => JSON.parse(String((init as RequestInit).body)) as unknown)
    .filter((payload) => !isChainProbe(payload));
}

function rpcRequest(
  body: unknown,
  headers: Record<string, string> = {},
  options: {raw?: string} = {},
): Request {
  return new Request(`${SITE}/api/rpc`, {
    method: "POST",
    headers: {"content-type": "application/json", "x-forwarded-host": "forestroadvault.com", ...headers},
    body: options.raw ?? JSON.stringify(body),
  });
}

const call = (method: string, params: unknown[] = [], id: string | number = 1) => ({jsonrpc: "2.0", id, method, params});

async function read(response: Response): Promise<{status: number; text: string; body: unknown}> {
  const text = await response.text();
  return {status: response.status, text, body: JSON.parse(text) as unknown};
}

/** Nothing the client or the logs see may carry the upstream URL or any part of its key. */
function expectNothingSecret(text: string, ...secrets: string[]) {
  const logged = everythingLogged();
  for (const secret of [KEY, UPSTREAM_HOST, ...secrets]) {
    expect(text).not.toContain(secret);
    expect(logged).not.toContain(secret);
  }
  expect(text).not.toContain("/v2/");
}

beforeEach(() => {
  resetRpcProxyStateForTests();
  vi.stubEnv("RPC_PROXY_UPSTREAM_URL", UPSTREAM);
  upstream = {chain: SEPOLIA, forward: echo};
  fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
    const payload = JSON.parse(String(init.body)) as unknown;
    if (isChainProbe(payload)) {
      if (upstream.chain instanceof Error) throw upstream.chain;
      if (typeof upstream.chain === "function") return upstream.chain(init);
      return jsonResponse({jsonrpc: "2.0", id: (payload as {id: number}).id, result: upstream.chain});
    }
    return upstream.forward(payload, init);
  });
  vi.stubGlobal("fetch", fetchMock);
  consoleSpies = CONSOLE_METHODS.map((method) => vi.spyOn(console, method).mockImplementation(() => undefined));
  errorLog = consoleSpies[CONSOLE_METHODS.indexOf("error")];
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  for (const spy of consoleSpies) spy.mockRestore();
});

describe("HTTP methods", () => {
  it.each([
    ["GET", GET],
    ["HEAD", HEAD],
    ["OPTIONS", OPTIONS],
    ["PUT", PUT],
    ["PATCH", PATCH],
    ["DELETE", DELETE],
  ])("refuses %s with 405, Allow: POST and no CORS headers", async (_, handler) => {
    const response = handler();
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
    expect([...response.headers.keys()].filter((name) => name.startsWith("access-control-"))).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses a non-POST request even when it reaches the shared handler", async () => {
    const response = await handleRpcProxyRequest(new Request(`${SITE}/api/rpc`, {method: "GET"}));
    expect(response.status).toBe(405);
  });
});

describe("origin", () => {
  it("refuses a foreign Origin with 403 before reading the body or the upstream", async () => {
    const {status, body} = await read(await POST(rpcRequest(call("eth_blockNumber"), {origin: "https://attacker.invalid"})));
    expect(status).toBe(403);
    expect(body).toEqual({jsonrpc: "2.0", id: null, error: {code: -32600, message: "Cross-origin requests are refused"}});
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses Sec-Fetch-Site: cross-site even without an Origin", async () => {
    const response = await POST(rpcRequest(call("eth_blockNumber"), {"sec-fetch-site": "cross-site"}));
    expect(response.status).toBe(403);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each([
    ["the opaque origin null", "null"],
    ["a different port", "https://forestroadvault.com:8443"],
    ["a sibling subdomain", "https://points.forestroadvault.com"],
    ["a non-http scheme", "chrome-extension://abcdef"],
    ["garbage", "not a url"],
  ])("refuses %s", async (_, origin) => {
    const response = await POST(rpcRequest(call("eth_blockNumber"), {origin}));
    expect(response.status).toBe(403);
  });

  it("serves a same-origin browser request (Origin host equals the forwarded host)", async () => {
    const response = await POST(rpcRequest(call("eth_blockNumber"), {origin: SITE, "sec-fetch-site": "same-origin"}));
    expect(response.status).toBe(200);
  });

  it("serves a request with no Origin: scripts can forge it, so the per-IP limit bounds them", async () => {
    const response = await POST(rpcRequest(call("eth_blockNumber")));
    expect(response.status).toBe(200);
  });

  it("compares with the request's own host when no forwarded host is present", async () => {
    const request = new Request(`${SITE}/api/rpc`, {
      method: "POST",
      headers: {"content-type": "application/json", origin: SITE},
      body: JSON.stringify(call("eth_blockNumber")),
    });
    expect((await POST(request)).status).toBe(200);
    const foreign = new Request(`${SITE}/api/rpc`, {
      method: "POST",
      headers: {"content-type": "application/json", origin: "https://attacker.invalid"},
      body: JSON.stringify(call("eth_blockNumber")),
    });
    expect((await POST(foreign)).status).toBe(403);
  });
});

describe("the host the origin check compares with (review F7)", () => {
  /** As on Vercel: the function sees an internal URL and Host; the edge sets x-forwarded-host. */
  const behindTheEdge = (headers: Record<string, string>) =>
    new Request("http://internal-function.vercel.invalid/api/rpc", {
      method: "POST",
      headers: {"content-type": "application/json", host: "internal-function.vercel.invalid", ...headers},
      body: JSON.stringify(call("eth_blockNumber")),
    });

  it("uses x-forwarded-host, not the internal URL or Host", async () => {
    const site = await POST(behindTheEdge({"x-forwarded-host": "forestroadvault.com", origin: SITE}));
    expect(site.status).toBe(200);
    const internal = await POST(
      behindTheEdge({"x-forwarded-host": "forestroadvault.com", origin: "http://internal-function.vercel.invalid"}),
    );
    expect(internal.status).toBe(403);
  });

  it("uses the first x-forwarded-host entry, the one the edge set", async () => {
    const forwarded = {"x-forwarded-host": "forestroadvault.com, attacker.invalid"};
    expect((await POST(behindTheEdge({...forwarded, origin: SITE}))).status).toBe(200);
    expect((await POST(behindTheEdge({...forwarded, origin: "https://attacker.invalid"}))).status).toBe(403);
  });
});

describe("request shape", () => {
  it("refuses a body that is not declared JSON with 415", async () => {
    const response = await POST(rpcRequest(call("eth_blockNumber"), {"content-type": "text/plain"}));
    expect(response.status).toBe(415);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts a JSON content type with a charset", async () => {
    const response = await POST(rpcRequest(call("eth_blockNumber"), {"content-type": "application/json; charset=utf-8"}));
    expect(response.status).toBe(200);
  });

  it("refuses a declared body over 256 KiB with 413 without reading it", async () => {
    const response = await POST(
      rpcRequest(call("eth_blockNumber"), {"content-length": String(RPC_PROXY_MAX_BODY_BYTES + 1)}),
    );
    expect(response.status).toBe(413);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses an actual body over 256 KiB with 413 when no length is declared", async () => {
    const oversized = JSON.stringify(call("eth_call", [{to: ADDRESS, data: `0x${"00".repeat(RPC_PROXY_MAX_BODY_BYTES)}`}, "latest"]));
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(oversized));
        controller.close();
      },
    });
    const request = new Request(`${SITE}/api/rpc`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: stream,
      duplex: "half",
    } as RequestInit);
    expect(request.headers.get("content-length")).toBeNull();
    const response = await POST(request);
    expect(response.status).toBe(413);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("accepts a body of exactly 256 KiB and refuses one byte more", async () => {
    const base = JSON.stringify(call("eth_blockNumber"));
    const exact = base + " ".repeat(RPC_PROXY_MAX_BODY_BYTES - base.length);
    expect(new TextEncoder().encode(exact).byteLength).toBe(RPC_PROXY_MAX_BODY_BYTES);
    expect((await POST(rpcRequest(null, {}, {raw: exact}))).status).toBe(200);
    expect((await POST(rpcRequest(null, {}, {raw: `${exact} `}))).status).toBe(413);
  });

  it("answers invalid JSON with a -32700 parse error", async () => {
    const {status, body} = await read(await POST(rpcRequest(null, {}, {raw: "{\"jsonrpc\":"})));
    expect(status).toBe(400);
    expect(body).toEqual({jsonrpc: "2.0", id: null, error: {code: -32700, message: "Parse error"}});
  });

  it("refuses a batch of more than 20 entries and accepts exactly 20", async () => {
    const batch = (n: number) => Array.from({length: n}, (_, i) => call("eth_blockNumber", [], i + 1));
    const over = await read(await POST(rpcRequest(batch(RPC_PROXY_MAX_BATCH + 1))));
    expect(over.status).toBe(400);
    expect(over.body).toEqual({jsonrpc: "2.0", id: null, error: {code: -32600, message: "Batch too large"}});
    expect(fetchMock).not.toHaveBeenCalled();
    const exact = await read(await POST(rpcRequest(batch(RPC_PROXY_MAX_BATCH))));
    expect(exact.status).toBe(200);
    expect(exact.body).toHaveLength(RPC_PROXY_MAX_BATCH);
  });

  it.each([
    ["an empty batch", []],
    ["a bare string", "eth_blockNumber"],
    ["a number", 42],
    ["null", null],
    ["a missing jsonrpc", {id: 1, method: "eth_blockNumber"}],
    ["JSON-RPC 1.0", {jsonrpc: "1.0", id: 1, method: "eth_blockNumber"}],
    ["a missing id", {jsonrpc: "2.0", method: "eth_blockNumber"}],
    ["a null id (a notification)", {jsonrpc: "2.0", id: null, method: "eth_blockNumber"}],
    ["an object id", {jsonrpc: "2.0", id: {}, method: "eth_blockNumber"}],
    ["an over-long id", {jsonrpc: "2.0", id: "x".repeat(129), method: "eth_blockNumber"}],
    ["a numeric method", {jsonrpc: "2.0", id: 1, method: 7}],
    ["an empty method", {jsonrpc: "2.0", id: 1, method: ""}],
    ["named params", {jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: {block: "latest"}}],
    ["a malformed entry inside a batch", [call("eth_blockNumber"), {jsonrpc: "2.0", id: 2}]],
  ])("refuses %s with 400 -32600 and never contacts the upstream", async (_, body) => {
    const answer = await read(await POST(rpcRequest(body)));
    expect(answer.status).toBe(400);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: null, error: {code: -32600, message: "Invalid JSON-RPC request"}});
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("forwards only the four JSON-RPC fields, whatever else the client sent", async () => {
    await POST(rpcRequest({...call("eth_blockNumber"), extra: "dropped", __proto__x: 1}));
    expect(forwardedPayloads()).toEqual([{jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: []}]);
  });
});

describe("method allowlist", () => {
  it("is exactly the nine methods the site sends", () => {
    expect([...RPC_PROXY_ALLOWED_METHODS].sort()).toEqual([
      "eth_blockNumber",
      "eth_call",
      "eth_chainId",
      "eth_estimateGas",
      "eth_getBlockByNumber",
      "eth_getCode",
      "eth_getLogs",
      "eth_getTransactionByHash",
      "eth_getTransactionReceipt",
    ]);
  });

  it.each([
    "eth_sendRawTransaction",
    "eth_sendTransaction",
    "eth_sign",
    "eth_signTransaction",
    "eth_signTypedData_v4",
    "personal_sign",
    "personal_unlockAccount",
    "wallet_sendTransaction",
    "debug_traceTransaction",
    "trace_block",
    "admin_peers",
    "alchemy_getTokenBalances",
    "eth_newFilter",
    "eth_newBlockFilter",
    "eth_getFilterChanges",
    "eth_uninstallFilter",
    "eth_subscribe",
    "eth_getStorageAt",
    "eth_getBalance",
    "eth_getBlockByHash",
    "eth_feeHistory",
    "net_version",
    "ETH_CALL",
  ])("answers %s with -32601 in a 200, without contacting the upstream", async (method) => {
    const answer = await read(await POST(rpcRequest(call(method, [], "req-7"))));
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({
      jsonrpc: "2.0",
      id: "req-7",
      error: {code: -32601, message: "Method not available through this proxy"},
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses a disallowed entry inside a batch without failing its neighbours", async () => {
    const answer = await read(
      await POST(
        rpcRequest([
          call("eth_blockNumber", [], 10),
          call("eth_sendRawTransaction", ["0x02"], 11),
          call("eth_call", [{to: ADDRESS, data: "0x"}, "latest"], 12),
        ]),
      ),
    );
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual([
      {jsonrpc: "2.0", id: 10, result: "ok:eth_blockNumber:1"},
      {jsonrpc: "2.0", id: 11, error: {code: -32601, message: "Method not available through this proxy"}},
      {jsonrpc: "2.0", id: 12, result: "ok:eth_call:2"},
    ]);
    // Only the two admitted entries went upstream, under the proxy's own ids.
    expect(forwardedPayloads()).toEqual([
      [
        {jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: []},
        {jsonrpc: "2.0", id: 2, method: "eth_call", params: [{to: ADDRESS, data: "0x"}, "latest"]},
      ],
    ]);
  });

  it("answers a batch of only refused entries without contacting the upstream", async () => {
    const answer = await read(await POST(rpcRequest([call("eth_sign", [], 1), call("debug_traceCall", [], 2)])));
    expect(answer.status).toBe(200);
    expect(answer.body).toHaveLength(2);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("eth_getLogs scope", () => {
  const refusal = {code: -32602, message: "eth_getLogs through this proxy must name a contract address"};

  it.each([
    ["no params", []],
    ["a non-object filter", ["latest"]],
    ["an address-less filter", [{fromBlock: "0x1", toBlock: "0x2"}]],
    ["a null address", [{address: null, fromBlock: "0x1"}]],
    ["an empty address list", [{address: [], fromBlock: "0x1"}]],
    ["a malformed address", [{address: "0x1234", fromBlock: "0x1"}]],
    ["a list with one malformed address", [{address: [ADDRESS, "0xzz"], fromBlock: "0x1"}]],
  ])("refuses %s with -32602", async (_, params) => {
    const answer = await read(await POST(rpcRequest(call("eth_getLogs", params, 3))));
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 3, error: refusal});
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each([
    ["one address", {address: ADDRESS, fromBlock: "0x1", toBlock: "0x2"}],
    ["an address list", {address: [ADDRESS, ADDRESS.toUpperCase().replace("0X", "0x")], fromBlock: "0x1", toBlock: "0x1"}],
    ["an address with a block hash", {address: ADDRESS, blockHash: `0x${"ab".repeat(32)}`}],
  ])("forwards a filter with %s", async (_, filter) => {
    const answer = await read(await POST(rpcRequest(call("eth_getLogs", [filter], 4))));
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 4, result: "ok:eth_getLogs:1"});
  });
});

describe("request shapes the site never sends (review F3)", () => {
  const callShape = {
    code: -32602,
    message: "eth_call and eth_estimateGas through this proxy take [transaction] or [transaction, block] with a contract address",
  };
  const logsRange = {
    code: -32602,
    message: "eth_getLogs through this proxy needs numeric fromBlock and toBlock at most 100,000 blocks apart, or a blockHash",
  };

  it.each(["eth_call", "eth_estimateGas"])("forwards %s as the site sends it", async (method) => {
    for (const params of [[TX], [TX, "latest"], [TX, "0x18cd630"], [{...TX, from: ADDRESS, value: "0x0"}, "pending"]]) {
      const answer = await read(await POST(rpcRequest(call(method, params, method))));
      expect(answer.body).toEqual({jsonrpc: "2.0", id: method, result: `ok:${method}:1`});
    }
  });

  it.each(["eth_call", "eth_estimateGas"])("refuses %s shapes that only a script sends, before the upstream", async (method) => {
    const stateOverride = {[ADDRESS]: {code: "0x62100000" + "6000f3"}};
    for (const params of [
      [],
      [TX, "latest", stateOverride],
      [TX, "latest", {}, {time: "0x1"}],
      [{data: "0x00"}],
      [{to: "0x1234", data: "0x"}],
      [{to: null, data: "0x"}],
      ["0xdeadbeef"],
      [TX, {blockHash: `0x${"ab".repeat(32)}`}],
      [TX, 1],
      [TX, "0x0001"],
      [TX, "newest"],
    ]) {
      const answer = await read(await POST(rpcRequest(call(method, params as unknown[], 3))));
      expect(answer.status).toBe(200);
      expect(answer.body).toEqual({jsonrpc: "2.0", id: 3, error: callShape});
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("forwards eth_getLogs with the site's ranges: one block, a 9,000-block chunk, exactly 100,000 blocks, a block hash", async () => {
    for (const filter of [
      {address: ADDRESS, fromBlock: "0x10", toBlock: "0x10"},
      LOGS,
      {address: ADDRESS, fromBlock: "0x1", toBlock: `0x${(100_000).toString(16)}`},
      {address: ADDRESS, blockHash: `0x${"ab".repeat(32)}`, topics: [null]},
      {address: [ADDRESS], topics: [`0x${"cd".repeat(32)}`], fromBlock: "0x0", toBlock: "0x0"},
    ]) {
      const answer = await read(await POST(rpcRequest(call("eth_getLogs", [filter], 4))));
      expect(answer.body).toEqual({jsonrpc: "2.0", id: 4, result: "ok:eth_getLogs:1"});
    }
  });

  it.each([
    ["earliest to latest", {fromBlock: "earliest", toBlock: "latest"}],
    ["a tag at either end", {fromBlock: "0x1", toBlock: "latest"}],
    ["no bounds (both default to latest)", {}],
    ["only a lower bound", {fromBlock: "0x1"}],
    ["only an upper bound", {toBlock: "0x1"}],
    ["bounds in the wrong order", {fromBlock: "0x10", toBlock: "0xf"}],
    ["100,001 blocks", {fromBlock: "0x1", toBlock: `0x${(100_001).toString(16)}`}],
    ["a decimal bound", {fromBlock: "1", toBlock: "2"}],
    ["a leading-zero quantity", {fromBlock: "0x01", toBlock: "0x02"}],
    ["a block hash with bounds", {blockHash: `0x${"ab".repeat(32)}`, fromBlock: "0x1", toBlock: "0x1"}],
    ["a malformed block hash", {blockHash: "0xabc"}],
    ["an unknown filter key", {fromBlock: "0x1", toBlock: "0x1", limit: 10}],
  ])("refuses an eth_getLogs range with %s, before the upstream", async (_, range) => {
    const answer = await read(await POST(rpcRequest(call("eth_getLogs", [{address: ADDRESS, ...range}], 5))));
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 5, error: logsRange});
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses a second eth_getLogs parameter", async () => {
    const answer = await read(await POST(rpcRequest(call("eth_getLogs", [LOGS, "extra"], 6))));
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 6, error: logsRange});
  });
});

describe("upstream configuration", () => {
  it("answers 503 with a fixed error when RPC_PROXY_UPSTREAM_URL is unset, and falls back to nothing", async () => {
    vi.stubEnv("RPC_PROXY_UPSTREAM_URL", "");
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", "https://other.test.invalid/v2/OTHERKEY");
    vi.stubEnv("ETHEREUM_ARCHIVE_RPC_URL", "https://archive.test.invalid/v2/ARCHIVEKEY");
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(503);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 1, error: {code: -32603, message: "RPC proxy is not configured"}});
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it.each([
    ["not a URL", "upstream rpc"],
    ["plain http", `http://${UPSTREAM_HOST}/v2/${KEY}`],
    ["URL credentials", `https://user:${KEY}@${UPSTREAM_HOST}/`],
    ["a fragment", `${UPSTREAM}#frag`],
    ["localhost", `https://localhost/v2/${KEY}`],
    ["a .localhost name", `https://rpc.localhost/v2/${KEY}`],
    ["127.0.0.1", `https://127.0.0.1:8545/${KEY}`],
    ["127.x in integer form", `https://2130706433/${KEY}`],
    ["IPv6 loopback", `https://[::1]/${KEY}`],
    ["IPv4-mapped IPv6 loopback", `https://[::ffff:127.0.0.1]/${KEY}`],
    ["0.0.0.0", `https://0.0.0.0/${KEY}`],
    ["a private 10/8 address", `https://10.1.2.3/${KEY}`],
    ["a private 192.168/16 address", `https://192.168.0.10/${KEY}`],
    ["a private 172.16/12 address", `https://172.20.0.1/${KEY}`],
    ["the link-local metadata address", `https://169.254.169.254/${KEY}`],
    ["an IPv6 unique-local address", `https://[fd00::1]/${KEY}`],
    ["the bottom of CGNAT 100.64/10", `https://100.64.0.1/${KEY}`],
    ["the top of CGNAT 100.64/10", `https://100.127.255.254/${KEY}`],
    ["IPv6 link-local fe80::/10", `https://[fe80::1]/${KEY}`],
    ["the top of IPv6 link-local", `https://[febf::1]/${KEY}`],
  ])("answers 503 for an upstream with %s, without echoing it", async (_, value) => {
    vi.stubEnv("RPC_PROXY_UPSTREAM_URL", value);
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
    expectNothingSecret(answer.text);
  });

  it.each([
    ["just below CGNAT", "https://100.63.255.255/rpc"],
    ["just above CGNAT", "https://100.128.0.1/rpc"],
    ["just above IPv6 link-local", "https://[fec0::1]/rpc"],
  ])("accepts a public address %s", async (_, value) => {
    vi.stubEnv("RPC_PROXY_UPSTREAM_URL", value);
    expect((await POST(rpcRequest(call("eth_blockNumber")))).status).toBe(200);
  });

  it("refuses loopback on mainnet too, where the chain check expects 0x1", async () => {
    const loopback = await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {
      chainId: 1,
      upstreamUrl: `https://127.0.0.1/${KEY}`,
    });
    expect(loopback.status).toBe(503);
    upstream.chain = "0x1";
    const remote = await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {chainId: 1, upstreamUrl: UPSTREAM});
    expect(remote.status).toBe(200);
  });
});

describe("the chain check", () => {
  it("checks eth_chainId once per instance, then forwards without re-checking", async () => {
    for (let i = 0; i < 3; i += 1) expect((await POST(rpcRequest(call("eth_blockNumber")))).status).toBe(200);
    expect(chainProbes()).toBe(1);
    expect(forwardedPayloads()).toHaveLength(3);
  });

  it("refuses everything with 503 when the upstream serves another chain, and remembers it", async () => {
    upstream.chain = "0x1";
    const first = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(first.status).toBe(503);
    expect(first.body).toEqual({
      jsonrpc: "2.0",
      id: 1,
      error: {code: -32603, message: "RPC proxy upstream serves another chain"},
    });
    // Even if the upstream later answered the right chain, this instance stays refused.
    upstream.chain = SEPOLIA;
    const second = await POST(rpcRequest(call("eth_blockNumber")));
    expect(second.status).toBe(503);
    expect(chainProbes()).toBe(1);
    expect(forwardedPayloads()).toEqual([]);
    expectNothingSecret(first.text);
  });

  it("does not remember a transient failure: the next request checks again and recovers", async () => {
    upstream.chain = new TypeError(`fetch failed: connect ECONNREFUSED ${UPSTREAM}`);
    const failed = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(failed.status).toBe(502);
    expect(forwardedPayloads()).toEqual([]);
    expectNothingSecret(failed.text);

    upstream.chain = () => new Response("<html>bad gateway</html>", {status: 200});
    expect((await POST(rpcRequest(call("eth_blockNumber")))).status).toBe(502);

    upstream.chain = () => jsonResponse({jsonrpc: "2.0", id: 1, error: {code: -32000, message: "busy"}});
    expect((await POST(rpcRequest(call("eth_blockNumber")))).status).toBe(502);

    upstream.chain = SEPOLIA;
    const recovered = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(recovered.status).toBe(200);
    expect(recovered.body).toEqual({jsonrpc: "2.0", id: 1, result: "ok:eth_blockNumber:1"});
    expect(chainProbes()).toBe(4);
  });

  it("shares one probe between concurrent first requests", async () => {
    const answers = await Promise.all(Array.from({length: 5}, () => POST(rpcRequest(call("eth_blockNumber")))));
    expect(answers.map((response) => response.status)).toEqual([200, 200, 200, 200, 200]);
    expect(chainProbes()).toBe(1);
  });
});

describe("upstream failures", () => {
  it("answers a network error with a fixed 502 that carries no URL, key or raw error text", async () => {
    upstream.forward = () => {
      throw new TypeError(`fetch failed`, {cause: new Error(`getaddrinfo ENOTFOUND ${UPSTREAM_HOST} ${UPSTREAM}`)});
    };
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(502);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 1, error: {code: -32603, message: "Upstream RPC unavailable"}});
    expect(answer.text).not.toContain("ENOTFOUND");
    expect(answer.text).not.toContain("fetch failed");
    expectNothingSecret(answer.text);
    expect(errorLog).toHaveBeenCalledWith("rpc.proxy upstream_network_error");
  });

  it("answers an upstream that is not JSON with a fixed 502", async () => {
    upstream.forward = () => new Response(`<html>error at ${UPSTREAM}</html>`, {status: 200});
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(502);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 1, error: {code: -32603, message: "Upstream RPC unavailable"}});
    expectNothingSecret(answer.text);
  });

  it.each([500, 401, 403, 404, 400])("answers upstream HTTP %i without a per-entry answer with a fixed 502", async (status) => {
    upstream.forward = () => jsonResponse({error: `bad key ${KEY}`}, status);
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(502);
    expectNothingSecret(answer.text);
  });

  it.each([500, 401, 403])(
    "never passes through an upstream HTTP %i answer, even a well-formed JSON-RPC one",
    async (status) => {
      upstream.forward = (payload) =>
        jsonResponse({jsonrpc: "2.0", id: (payload as {id: number}).id, error: {code: -32600, message: "Origin not on whitelist."}}, status);
      const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
      expect(answer.status).toBe(502);
      expect(answer.body).toEqual({jsonrpc: "2.0", id: 1, error: {code: -32603, message: "Upstream RPC unavailable"}});
      expect(answer.text).not.toContain("whitelist");
      expect(errorLog).toHaveBeenCalledWith(`rpc.proxy upstream_http_${status}`);
    },
  );

  it("passes through the per-entry JSON-RPC errors of an upstream 400, as the provider gave them", async () => {
    // Alchemy answers invalid params with HTTP 400 and a JSON-RPC error. The browser saw that error
    // when it called the provider directly; a fixed 502 instead would make viem retry it three times.
    const invalid = {code: -32602, message: "Log response size exceeded."};
    upstream.forward = (payload) => {
      const entries = payload as {id: number}[];
      return jsonResponse(entries.map((entry) => ({jsonrpc: "2.0", id: entry.id, error: invalid})), 400);
    };
    const answer = await read(
      await POST(rpcRequest([call("eth_getLogs", [LOGS], "a"), call("eth_getLogs", [LOGS], "b")])),
    );
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual([
      {jsonrpc: "2.0", id: "a", error: invalid},
      {jsonrpc: "2.0", id: "b", error: invalid},
    ]);
  });

  it("answers an upstream 400 that is not a per-entry JSON-RPC answer with a fixed 502", async () => {
    upstream.forward = () => jsonResponse({jsonrpc: "2.0", id: null, error: {code: -32600, message: "invalid batch"}}, 400);
    const answer = await read(await POST(rpcRequest([call("eth_blockNumber", [], 1), call("eth_chainId", [], 2)])));
    expect(answer.status).toBe(502);
  });

  it("answers upstream rate limiting with a fixed 429", async () => {
    upstream.forward = () => jsonResponse({jsonrpc: "2.0", id: 1, error: {code: 429, message: `capacity ${KEY}`}}, 429);
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(429);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 1, error: {code: -32005, message: "Upstream RPC rate limited"}});
    expectNothingSecret(answer.text);
  });

  it("answers an upstream that outlasts its timeout with a fixed 504", async () => {
    upstream.forward = (_payload, init) => untilAborted(init);
    const answer = await read(await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {upstreamTimeoutMs: 30}));
    expect(answer.status).toBe(504);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 1, error: {code: -32603, message: "Upstream RPC timed out"}});
    expect(errorLog).toHaveBeenCalledWith("rpc.proxy upstream_timeout");
    expectNothingSecret(answer.text);
  });

  it("replaces an answer that echoes the upstream URL or key with a fixed 502", async () => {
    upstream.forward = (payload) =>
      jsonResponse({jsonrpc: "2.0", id: (payload as {id: number}).id, error: {code: -32000, message: `invalid key ${KEY}`}});
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(502);
    expect(answer.body).toEqual({
      jsonrpc: "2.0",
      id: 1,
      error: {code: -32603, message: "Upstream RPC returned an invalid response"},
    });
    expectNothingSecret(answer.text);
  });

  it.each([
    ["a single object for a batch", () => jsonResponse({jsonrpc: "2.0", id: 1, result: "0x1"})],
    ["too few answers", () => jsonResponse([{jsonrpc: "2.0", id: 1, result: "0x1"}])],
    ["a duplicated id", () => jsonResponse([{jsonrpc: "2.0", id: 1, result: "0x1"}, {jsonrpc: "2.0", id: 1, result: "0x2"}])],
    ["an id it never sent", () => jsonResponse([{jsonrpc: "2.0", id: 1, result: "0x1"}, {jsonrpc: "2.0", id: 9, result: "0x2"}])],
    ["an entry with neither result nor error", () => jsonResponse([{jsonrpc: "2.0", id: 1, result: "0x1"}, {jsonrpc: "2.0", id: 2}])],
    ["a malformed error", () => jsonResponse([{jsonrpc: "2.0", id: 1, result: "0x1"}, {jsonrpc: "2.0", id: 2, error: "boom"}])],
  ])("answers an upstream batch with %s with a fixed 502", async (_, answerWith) => {
    upstream.forward = answerWith;
    const answer = await read(await POST(rpcRequest([call("eth_blockNumber", [], 1), call("eth_chainId", [], 2)])));
    expect(answer.status).toBe(502);
  });

  it("answers a failed batch per entry, keeping each entry's own id and any policy refusal", async () => {
    vi.stubEnv("RPC_PROXY_UPSTREAM_URL", "");
    const answer = await read(
      await POST(rpcRequest([call("eth_blockNumber", [], "x"), call("eth_sign", [], 8), call("eth_chainId", [], 9)])),
    );
    expect(answer.status).toBe(503);
    expect(answer.body).toEqual([
      {jsonrpc: "2.0", id: "x", error: {code: -32603, message: "RPC proxy is not configured"}},
      {jsonrpc: "2.0", id: 8, error: {code: -32601, message: "Method not available through this proxy"}},
      {jsonrpc: "2.0", id: 9, error: {code: -32603, message: "RPC proxy is not configured"}},
    ]);
  });
});

describe("timeouts and cancellation (review F5)", () => {
  it("gives the chain check its own short timeout, then checks again on the next request", async () => {
    upstream.chain = (init) => untilAborted(init);
    const started = Date.now();
    const answer = await read(await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {probeTimeoutMs: 30}));
    expect(answer.status).toBe(502);
    expect(Date.now() - started).toBeLessThan(5_000);
    expect(errorLog).toHaveBeenCalledWith("rpc.proxy upstream_timeout");
    upstream.chain = SEPOLIA;
    expect((await POST(rpcRequest(call("eth_blockNumber")))).status).toBe(200);
    expect(chainProbes()).toBe(2);
  });

  it("waits on the probe's own timeout for the chain check, not the forward's", async () => {
    let probeSignal: AbortSignal | undefined;
    upstream.chain = (init) => {
      probeSignal = init.signal ?? undefined;
      return untilAborted(init);
    };
    const started = Date.now();
    const answer = await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {probeTimeoutMs: 30, upstreamTimeoutMs: 60_000});
    expect(answer.status).toBe(502);
    expect(probeSignal?.aborted).toBe(true);
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("waits on the forward's own timeout for the forward, not the probe's", async () => {
    upstream.forward = (_payload, init) => untilAborted(init);
    const started = Date.now();
    const answer = await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {probeTimeoutMs: 20, upstreamTimeoutMs: 300});
    const elapsed = Date.now() - started;
    expect(answer.status).toBe(504);
    expect(elapsed).toBeGreaterThanOrEqual(250);
    expect(elapsed).toBeLessThan(3_000);
  });

  it("uses a 5 s chain check and a 20 s forward by default, and the browser waits longer than both", async () => {
    const {RPC_PROXY_BROWSER_TIMEOUT_MS} = await import("@/lib/rpcProxyShared");
    expect(RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS).toBe(5_000);
    expect(RPC_PROXY_UPSTREAM_TIMEOUT_MS).toBe(20_000);
    expect(RPC_PROXY_BROWSER_TIMEOUT_MS).toBeGreaterThan(RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS + RPC_PROXY_UPSTREAM_TIMEOUT_MS);
  });

  it("cancels the upstream call when the browser goes away, and logs only a label", async () => {
    let upstreamSignal: AbortSignal | undefined;
    upstream.forward = (_payload, init) => {
      upstreamSignal = init.signal ?? undefined;
      return untilAborted(init);
    };
    const client = new AbortController();
    const request = new Request(`${SITE}/api/rpc`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(call("eth_blockNumber")),
      signal: client.signal,
    });
    const pending = POST(request);
    await vi.waitFor(() => expect(upstreamSignal).toBeDefined());
    expect(upstreamSignal!.aborted).toBe(false);
    client.abort();
    const answer = await read(await pending);
    expect(upstreamSignal!.aborted).toBe(true);
    expect(answer.status).toBe(499);
    expect(errorLog).toHaveBeenCalledWith("rpc.proxy upstream_cancelled_client_gone");
    expectNothingSecret(answer.text);
  });

  it("does not cancel the shared chain check when one waiting browser goes away", async () => {
    let probeSignal: AbortSignal | undefined;
    let answerProbe!: () => void;
    upstream.chain = (init) => {
      probeSignal = init.signal ?? undefined;
      return new Promise((resolve) => {
        answerProbe = () => resolve(jsonResponse({jsonrpc: "2.0", id: 1, result: SEPOLIA}));
      });
    };
    const client = new AbortController();
    const first = POST(
      new Request(`${SITE}/api/rpc`, {
        method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify(call("eth_blockNumber")),
        signal: client.signal,
      }),
    );
    const second = POST(rpcRequest(call("eth_blockNumber")));
    await vi.waitFor(() => expect(probeSignal).toBeDefined());
    client.abort();
    expect(probeSignal!.aborted).toBe(false);
    answerProbe();
    expect((await second).status).toBe(200);
    expect([200, 499]).toContain((await first).status);
    expect(chainProbes()).toBe(1);
  });
});

describe("redaction on every failure path (review F7)", () => {
  // Built at run time: a key-shaped query value, as some providers use instead of a path key.
  const QUERY_SECRET = `QUERYSECRET${"z".repeat(16)}`;
  const QUERY_UPSTREAM = `https://${UPSTREAM_HOST}/rpc?apikey=${QUERY_SECRET}`;

  it("logs no URL, key or error text on a network error, through any console method", async () => {
    upstream.forward = () => {
      throw new TypeError(`fetch failed for ${UPSTREAM}`, {cause: new Error(`connect ECONNREFUSED ${UPSTREAM}`)});
    };
    const answer = await read(await POST(rpcRequest(call("eth_blockNumber"))));
    expect(answer.status).toBe(502);
    expectNothingSecret(answer.text);
    expect(everythingLogged()).toBe("rpc.proxy upstream_network_error");
  });

  it("logs no URL, key or error text on a timeout, through any console method", async () => {
    upstream.forward = (_payload, init) => untilAborted(init);
    const answer = await read(await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {upstreamTimeoutMs: 20}));
    expect(answer.status).toBe(504);
    expectNothingSecret(answer.text);
    expect(everythingLogged()).toBe("rpc.proxy upstream_timeout");
  });

  it("treats a key in the upstream's query string as secret: never echoed, never logged", async () => {
    upstream.forward = (payload) =>
      jsonResponse({jsonrpc: "2.0", id: (payload as {id: number}).id, error: {code: -32000, message: `bad key ${QUERY_SECRET}`}});
    const echoed = await read(await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {upstreamUrl: QUERY_UPSTREAM}));
    expect(echoed.status).toBe(502);
    expectNothingSecret(echoed.text, QUERY_SECRET);
    upstream.forward = () => {
      throw new TypeError(`fetch failed for ${QUERY_UPSTREAM}`);
    };
    const failed = await read(await handleRpcProxyRequest(rpcRequest(call("eth_blockNumber")), {upstreamUrl: QUERY_UPSTREAM}));
    expectNothingSecret(failed.text, QUERY_SECRET);
  });
});

describe("pass-through", () => {
  it("returns a single call's upstream answer under the client's own id, uncached", async () => {
    upstream.forward = () => jsonResponse({jsonrpc: "2.0", id: 1, result: "0x18c1a3f"});
    const response = await POST(rpcRequest(call("eth_blockNumber", [], "client-id-7"), {origin: SITE}));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("content-type")).toBe("application/json");
    expect([...response.headers.keys()].filter((name) => name.startsWith("access-control-"))).toEqual([]);
    expect(await response.json()).toEqual({jsonrpc: "2.0", id: "client-id-7", result: "0x18c1a3f"});
  });

  it("sends the upstream nothing from the browser: no Origin, cookies or client headers, and no redirects", async () => {
    await POST(rpcRequest(call("eth_blockNumber"), {origin: SITE, cookie: "session=1", "user-agent": "browser"}));
    for (const [url, init] of fetchMock.mock.calls as [string, RequestInit][]) {
      expect(url).toBe(UPSTREAM);
      expect(init.headers).toEqual({"content-type": "application/json", accept: "application/json"});
      expect(init.redirect).toBe("error");
      expect(init.method).toBe("POST");
    }
  });

  it("passes upstream JSON-RPC errors through, revert data included", async () => {
    const revert = {code: 3, message: "execution reverted", data: "0x08c379a0"};
    upstream.forward = () => jsonResponse({jsonrpc: "2.0", id: 1, error: revert});
    const answer = await read(await POST(rpcRequest(call("eth_call", [{to: ADDRESS, data: "0x"}, "latest"], 5))));
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: 5, error: revert});
  });

  it("returns a batch in the client's order and ids, whatever order the upstream answers in", async () => {
    upstream.forward = (payload) => {
      const entries = payload as {id: number; method: string}[];
      return jsonResponse(entries.map((entry) => ({jsonrpc: "2.0", id: entry.id, result: `r${entry.id}`})).reverse());
    };
    const answer = await read(
      await POST(
        rpcRequest([
          call("eth_blockNumber", [], "a"),
          call("eth_chainId", [], 7),
          // A duplicated client id still gets its own answer: matching uses the proxy's ids.
          call("eth_getCode", [ADDRESS, "latest"], 7),
        ]),
      ),
    );
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual([
      {jsonrpc: "2.0", id: "a", result: "r1"},
      {jsonrpc: "2.0", id: 7, result: "r2"},
      {jsonrpc: "2.0", id: 7, result: "r3"},
    ]);
  });

  it("answers each of the nine allowed methods", async () => {
    for (const method of RPC_PROXY_ALLOWED_METHODS) {
      const params =
        method === "eth_getLogs" ? [LOGS] : method === "eth_call" || method === "eth_estimateGas" ? [TX, "latest"] : [];
      const answer = await read(await POST(rpcRequest(call(method, params, method))));
      expect(answer.status).toBe(200);
      // The stub answers every single eth_chainId as it answers the proxy's own chain probe.
      const result = method === "eth_chainId" ? SEPOLIA : `ok:${method}:1`;
      expect(answer.body).toEqual({jsonrpc: "2.0", id: method, result});
    }
  });
});

describe("the response size budget (a Vercel Function body is capped at 4.5 MB)", () => {
  const tooBig = {code: -32008, message: "Response is too big for the RPC proxy: narrow the request"};

  /** Upstream answering each forwarded entry with a result of the given size, by the proxy's id. */
  function sized(bytesById: Record<number, number>) {
    return (payload: unknown) => {
      const entries = (Array.isArray(payload) ? payload : [payload]) as {id: number}[];
      const answers = entries.map((entry) => ({
        jsonrpc: "2.0",
        id: entry.id,
        result: bytesById[entry.id] ? `0x${"ab".repeat(bytesById[entry.id] / 2)}` : "0x1",
      }));
      return jsonResponse(Array.isArray(payload) ? answers : answers[0]);
    };
  }

  it("keeps the budget under Vercel's 4.5 MB body limit, with the named error viem does not retry", () => {
    expect(RPC_PROXY_MAX_RESPONSE_BYTES).toBe(4_000_000);
    expect(RPC_PROXY_MAX_RESPONSE_BYTES).toBeLessThan(4.5 * 1000 * 1000);
    expect(RPC_PROXY_RESPONSE_TOO_BIG).toEqual(tooBig);
  });

  it("answers an entry over the budget with the named error, and its neighbours still answer", async () => {
    upstream.forward = sized({1: 5_000_000});
    const response = await POST(
      rpcRequest([
        call("eth_getBlockByNumber", ["0x1", true], "block"),
        call("eth_blockNumber", [], "tip"),
        call("eth_sign", [], "refused"),
      ]),
    );
    const text = await response.text();
    expect(response.status).toBe(200);
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(RPC_PROXY_MAX_RESPONSE_BYTES);
    expect(JSON.parse(text)).toEqual([
      {jsonrpc: "2.0", id: "block", error: tooBig},
      {jsonrpc: "2.0", id: "tip", result: "0x1"},
      {jsonrpc: "2.0", id: "refused", error: {code: -32601, message: "Method not available through this proxy"}},
    ]);
    expect(errorLog).toHaveBeenCalledWith("rpc.proxy response_over_budget entries_replaced=1");
  });

  it("replaces only as many entries as it must, largest first", async () => {
    upstream.forward = sized({1: 2_200_000, 2: 2_500_000});
    const response = await POST(rpcRequest([call("eth_getBlockByNumber", ["0x1", true], 1), call("eth_getBlockByNumber", ["0x2", true], 2), call("eth_blockNumber", [], 3)]));
    const text = await response.text();
    const body = JSON.parse(text) as {id: number; result?: string; error?: unknown}[];
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(RPC_PROXY_MAX_RESPONSE_BYTES);
    expect(body[0].result).toHaveLength(2 + 2_200_000);
    expect(body[1]).toEqual({jsonrpc: "2.0", id: 2, error: tooBig});
    expect(body[2]).toEqual({jsonrpc: "2.0", id: 3, result: "0x1"});
  });

  it("answers a single oversized call with the named error under its own id", async () => {
    upstream.forward = sized({1: 4_200_000});
    const answer = await read(await POST(rpcRequest(call("eth_getLogs", [LOGS], "logs"))));
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual({jsonrpc: "2.0", id: "logs", error: tooBig});
  });

  it("passes an answer just under the budget untouched", async () => {
    upstream.forward = sized({1: 3_900_000});
    const answer = await read(await POST(rpcRequest(call("eth_getBlockByNumber", ["0x1", true], 1))));
    expect((answer.body as {result: string}).result).toHaveLength(2 + 3_900_000);
  });

  it("stops reading an upstream answer past 16 MiB and answers every forwarded entry too big", async () => {
    const MiB = 1024 * 1024;
    let pulled = 0;
    upstream.forward = () =>
      new Response(
        new ReadableStream<Uint8Array>({
          pull(controller) {
            pulled += 1;
            if (pulled > 40) return controller.close();
            controller.enqueue(new Uint8Array(MiB).fill(0x61));
          },
        }),
        {status: 200, headers: {"content-type": "application/json"}},
      );
    const answer = await read(
      await POST(rpcRequest([call("eth_getLogs", [LOGS], 1), call("eth_sign", [], 2), call("eth_blockNumber", [], 3)])),
    );
    expect(answer.status).toBe(200);
    expect(answer.body).toEqual([
      {jsonrpc: "2.0", id: 1, error: tooBig},
      {jsonrpc: "2.0", id: 2, error: {code: -32601, message: "Method not available through this proxy"}},
      {jsonrpc: "2.0", id: 3, error: tooBig},
    ]);
    expect(RPC_PROXY_MAX_UPSTREAM_BYTES).toBe(16 * MiB);
    // It read just past the cap and stopped; it never drained the 40 MiB on offer.
    expect(pulled).toBeLessThanOrEqual(18);
    expect(errorLog).toHaveBeenCalledWith("rpc.proxy upstream_answer_over_read_cap");
  });

  /** A batch whose upstream answers entry i with result "a" repeated lengths[i]. */
  function lengths(sizes: number[]) {
    upstream.forward = (payload) =>
      jsonResponse((payload as {id: number}[]).map((entry, index) => ({jsonrpc: "2.0", id: entry.id, result: "a".repeat(sizes[index])})));
    return rpcRequest(sizes.map((_, index) => call("eth_getBlockByNumber", ["0x1", true], index + 1)));
  }
  /** The bytes of one answer entry with client id `id` and a result of `length` ASCII characters. */
  const entryBytes = (id: number, length: number) => Buffer.byteLength(JSON.stringify({jsonrpc: "2.0", id, result: "a".repeat(length)}));

  it("passes an answer of exactly the budget, brackets and commas included, untouched", async () => {
    const first = 1_000_000;
    const fixed = entryBytes(1, first) + entryBytes(2, 0) + 3; // "[", ",", "]"
    const response = await POST(lengths([first, RPC_PROXY_MAX_RESPONSE_BYTES - fixed]));
    const text = await response.text();
    expect(Buffer.byteLength(text)).toBe(RPC_PROXY_MAX_RESPONSE_BYTES);
    expect(text).not.toContain("too big");
    // Nor is it reported as over the budget: an operator alarm must not fire on an answer that fits.
    expect(everythingLogged()).not.toContain("response_over_budget");
  });

  it("counts the brackets and commas: entries that fit alone but not with 21 bytes of overhead are trimmed", async () => {
    const sizes = Array.from({length: 20}, () => 199_000);
    const entries = sizes.reduce((sum, length, index) => sum + entryBytes(index + 1, length), 0);
    sizes[19] += RPC_PROXY_MAX_RESPONSE_BYTES - 10 - entries; // entries alone: 10 bytes under the budget
    const response = await POST(lengths(sizes));
    const text = await response.text();
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(RPC_PROXY_MAX_RESPONSE_BYTES);
    expect(text).toContain("too big");
  });

  it("measures UTF-8 bytes, not string length", async () => {
    // 1,400,000 euro signs: 1.4 million UTF-16 units, 4.2 million UTF-8 bytes.
    upstream.forward = (payload) => jsonResponse({jsonrpc: "2.0", id: (payload as {id: number}).id, result: "€".repeat(1_400_000)});
    const response = await POST(rpcRequest(call("eth_getBlockByNumber", ["0x1", true], 1)));
    const text = await response.text();
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(RPC_PROXY_MAX_RESPONSE_BYTES);
    expect(JSON.parse(text)).toEqual({jsonrpc: "2.0", id: 1, error: tooBig});
  });
});
