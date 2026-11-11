// @vitest-environment node
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {describe, expect, it} from "vitest";
import {RPC_PROXY_ALLOWED_METHODS} from "@/lib/rpcProxy.server";

/**
 * The static half of the method census (review F8).
 *
 * rpcProxy.census.test.ts runs the viem actions the site is known to call. This test finds what the
 * browser source actually calls: every Wagmi import, every method called on a client, and every raw
 * JSON-RPC method literal, in every file that can reach the browser. Each must be in the maps below,
 * and every JSON-RPC method they map to must be on the proxy's allowlist. So a future `useBalance`,
 * `client.getBalance(...)` or `{method: "eth_feeHistory"}` fails here, with its file, before it fails
 * a user through the proxy's -32601.
 */

const SRC = fileURLToPath(new URL("..", import.meta.url));

/** Refused by the proxy on purpose; viem falls back (see the dynamic census). */
const REFUSED_WITH_FALLBACK = new Set(["eth_newFilter"]);
/** Handled by the wallet (injected provider or WalletConnect session), never by this RPC. */
const WALLET = "wallet";

/** Wagmi exports used in browser code, and the JSON-RPC methods each sends through the app transport. */
const WAGMI: Record<string, readonly string[] | typeof WALLET | "none"> = {
  useReadContract: ["eth_call"],
  useReadContracts: ["eth_call"],
  useBlockNumber: ["eth_blockNumber"],
  useBlock: ["eth_getBlockByNumber"],
  useWatchContractEvent: ["eth_newFilter", "eth_blockNumber", "eth_getLogs"],
  usePublicClient: "none",
  useWalletClient: WALLET,
  useAccount: "none",
  useConfig: "none",
  useConnect: WALLET,
  useConnectors: "none",
  useDisconnect: WALLET,
  useSwitchChain: WALLET,
  useSignTypedData: WALLET,
  useWriteContract: WALLET,
  getConnection: "none",
  WagmiProvider: "none",
  createConfig: "none",
  http: "none",
  custom: "none",
  fallback: "none",
  mainnet: "none",
  sepolia: "none",
  Config: "none",
};

/** Methods called on a client in browser code, and the JSON-RPC methods each sends. */
const CLIENT_CALLS: Record<string, readonly string[] | typeof WALLET | "none"> = {
  readContract: ["eth_call"],
  multicall: ["eth_call"],
  call: ["eth_call"],
  simulateContract: ["eth_call"],
  estimateContractGas: ["eth_estimateGas"],
  getBlock: ["eth_getBlockByNumber"],
  getBlockNumber: ["eth_blockNumber"],
  getChainId: ["eth_chainId"],
  getCode: ["eth_getCode"],
  getContractEvents: ["eth_getLogs"],
  getLogs: ["eth_getLogs"],
  getTransactionReceipt: ["eth_getTransactionReceipt"],
  waitForTransactionReceipt: ["eth_getTransactionReceipt", "eth_blockNumber", "eth_getTransactionByHash", "eth_getBlockByNumber"],
  writeContract: WALLET,
  sendTransaction: WALLET,
  signTypedData: WALLET,
  invalidateQueries: "none", // React Query's queryClient, not an RPC client
};

type Finding = {file: string; name: string};
type StaticCensus = {
  unknownWagmi: Finding[];
  unknownClientCalls: Finding[];
  rawMethods: Finding[];
  methods: Set<string>;
  seenWagmi: Set<string>;
  seenClientCalls: Set<string>;
};

function addMethods(methods: Set<string>, mapped: readonly string[] | string) {
  if (Array.isArray(mapped)) for (const method of mapped) methods.add(method);
}

function staticCensus(files: {file: string; text: string}[]): StaticCensus {
  const census: StaticCensus = {
    unknownWagmi: [],
    unknownClientCalls: [],
    rawMethods: [],
    methods: new Set(),
    seenWagmi: new Set(),
    seenClientCalls: new Set(),
  };
  for (const {file, text} of files) {
    for (const match of text.matchAll(/import\s+(?:type\s+)?\{([^}]*)\}\s*from\s*"(wagmi(?:\/[a-z]+)?|@wagmi\/core|viem\/actions)"/g)) {
      const names = match[1].split(",").map((part) => part.replace(/\btype\b/, "").split(/\s+as\s+/)[0].trim()).filter(Boolean);
      for (const name of names) {
        // Connector factories (wagmi/connectors/*) only set up wallets.
        if (match[2].startsWith("wagmi/connectors")) continue;
        if (match[2] === "wagmi/chains") continue;
        census.seenWagmi.add(name);
        if (!(name in WAGMI)) census.unknownWagmi.push({file, name});
        else addMethods(census.methods, WAGMI[name]);
      }
    }
    for (const match of text.matchAll(/\b([A-Za-z_$][\w$]*)!?\.([A-Za-z_$][\w$]*)\s*\(/g)) {
      const [, receiver, name] = match;
      if (!/[cC]lient$/.test(receiver)) continue;
      census.seenClientCalls.add(name);
      if (!(name in CLIENT_CALLS)) census.unknownClientCalls.push({file, name});
      else addMethods(census.methods, CLIENT_CALLS[name]);
    }
    for (const match of text.matchAll(/method:\s*"((?:eth|net|web3|wallet|personal|debug|trace|admin|alchemy|txpool|engine)_\w+)"/g)) {
      census.rawMethods.push({file, name: match[1]});
      census.methods.add(match[1]);
    }
  }
  return census;
}

/** Every source file that can reach the browser: not tests, not *.server.ts, not API routes. */
function browserSources(): {file: string; text: string}[] {
  const out: {file: string; text: string}[] = [];
  const walk = (directory: string) => {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const full = path.join(directory, entry.name);
      const relative = path.relative(SRC, full);
      if (entry.isDirectory()) {
        if (relative === path.join("app", "api") || relative === "test") continue;
        walk(full);
      } else if (/\.(ts|tsx)$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name) && !entry.name.endsWith(".server.ts")) {
        out.push({file: relative, text: fs.readFileSync(full, "utf8")});
      }
    }
  };
  walk(SRC);
  return out;
}

describe("the static method census of browser code", () => {
  const files = browserSources();
  const census = staticCensus(files);

  it("reads the whole browser tree", () => {
    expect(files.length).toBeGreaterThan(80);
    expect(files.some((entry) => entry.file === path.join("components", "app", "YieldPositionPanel.tsx"))).toBe(true);
    expect(files.some((entry) => entry.file.endsWith(".server.ts"))).toBe(false);
  });

  it("finds only Wagmi exports and client calls it knows, so a new read cannot slip past", () => {
    expect(census.unknownWagmi).toEqual([]);
    expect(census.unknownClientCalls).toEqual([]);
    // Not vacuous: the site's actual read paths are found.
    for (const hook of ["useReadContract", "useReadContracts", "useBlockNumber", "useBlock", "useWatchContractEvent"]) {
      expect(census.seenWagmi.has(hook), hook).toBe(true);
    }
    for (const call of ["readContract", "getBlock", "getContractEvents", "getLogs", "simulateContract", "waitForTransactionReceipt"]) {
      expect(census.seenClientCalls.has(call), call).toBe(true);
    }
  });

  it("maps every method the browser can send to the proxy's allowlist", () => {
    const outside = [...census.methods].filter(
      (method) => !RPC_PROXY_ALLOWED_METHODS.has(method) && !REFUSED_WITH_FALLBACK.has(method),
    );
    expect(outside).toEqual([]);
    // And the allowlist carries nothing the browser cannot send.
    expect([...RPC_PROXY_ALLOWED_METHODS].filter((method) => !census.methods.has(method))).toEqual([]);
  });

  it("raw JSON-RPC literals in browser code are rpcAlignment's three reads", () => {
    expect([...new Set(census.rawMethods.map((entry) => entry.name))].sort()).toEqual([
      "eth_blockNumber",
      "eth_chainId",
      "eth_getBlockByNumber",
    ]);
  });

  it("fails on a read it does not know: useBalance, client.getBalance, a raw eth_feeHistory", () => {
    const probe = staticCensus([
      {file: "a.tsx", text: 'import {useAccount, useBalance} from "wagmi";'},
      {file: "b.ts", text: "await publicClient.getBalance({address});"},
      {file: "c.ts", text: 'await client.request({method: "eth_feeHistory", params: []});'},
      {file: "d.ts", text: 'import {getBalance as read} from "viem/actions";'},
    ]);
    expect(probe.unknownWagmi).toEqual([
      {file: "a.tsx", name: "useBalance"},
      {file: "d.ts", name: "getBalance"},
    ]);
    // A raw client.request is unknown too: every raw request must be reviewed and listed.
    expect(probe.unknownClientCalls).toEqual([
      {file: "b.ts", name: "getBalance"},
      {file: "c.ts", name: "request"},
    ]);
    expect(RPC_PROXY_ALLOWED_METHODS.has(probe.rawMethods[0].name)).toBe(false);
  });
});
