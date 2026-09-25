import {HttpRequestError} from "viem";
import {describe, expect, it} from "vitest";

import {describeRpcError, probeRpcAlignment, type RpcRequest} from "./rpcAlignment";

const CHAIN = 1;
const HASH = `0x${"ab".repeat(32)}` as const;
const OTHER_HASH = `0x${"cd".repeat(32)}` as const;

/**
 * Builds a transport that answers the four calls `probeRpcAlignment` makes, with the chain ID
 * and block number encoded however the caller asks. Real wallets differ here: a compliant
 * endpoint returns a hex quantity, while Fireblocks over WalletConnect and several mobile
 * shims return a JS number or a bare decimal string.
 */
function transport(chainId: unknown, blockNumber: unknown, blockHash: string = HASH): RpcRequest {
  return async ({method}) => {
    if (method === "eth_chainId") return chainId;
    if (method === "eth_blockNumber") return blockNumber;
    if (method === "eth_getBlockByNumber") return {hash: blockHash};
    throw new Error(`unexpected method ${method}`);
  };
}

/** A transport that answers like `base` but rejects one method with `rejection`. */
function rejecting(base: RpcRequest, failing: string, rejection: unknown): RpcRequest {
  return async (args) => {
    if (args.method === failing) throw rejection;
    return base(args);
  };
}

/** What MetaMask and most injected wallets reject with: a plain object, not an Error. */
const EIP1193_INTERNAL_ERROR = {code: -32603, message: "Internal JSON-RPC error."};

const OPTIONS = {expectedChainId: CHAIN, requireExactTip: false};

describe("probeRpcAlignment quantity parsing", () => {
  it("accepts the compliant hex form on both transports", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport("0x1", "0x64"),
      OPTIONS,
    );
    expect(result).toEqual({aligned: true, blockNumber: 100n, blockHash: HASH});
  });

  // THE REGRESSION. A Fireblocks WalletConnect session reported chain 1 as the number 1, and
  // the strict parser rejected it as "an invalid chain ID" while the wallet was on mainnet.
  it("accepts a wallet that returns the chain ID as a number", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport(1, 100),
      OPTIONS,
    );
    expect(result.aligned).toBe(true);
  });

  it("accepts a wallet that returns the chain ID as a decimal string", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport("1", "100"),
      OPTIONS,
    );
    expect(result.aligned).toBe(true);
  });

  it("accepts a bigint, which some viem transports hand back directly", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport(1n, 100n),
      OPTIONS,
    );
    expect(result.aligned).toBe(true);
  });

  // The widening must not become "accept anything". Each of these is still refused, and the
  // refusal surfaces as a NOT-aligned result, blamed on the wallet, rather than a thrown error
  // escaping the probe.
  it.each([
    ["null", null],
    ["undefined", undefined],
    ["an object", {chainId: 1}],
    ["a non-integer", 1.5],
    ["a negative number", -1],
    ["an empty string", ""],
    ["a non-numeric string", "mainnet"],
    ["a 0x prefix with no digits", "0x"],
  ])("refuses %s", async (_label, bad) => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport(bad, "0x64"),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "wallet",
      message: "The wallet RPC returned an invalid chain ID. Writes are disabled.",
    });
  });

  // Encoding leniency must not become chain leniency: a wallet on the wrong chain is still
  // blocked, whichever shape it reports in, and it is reported as the switchable case.
  it("still blocks a wallet on the wrong chain reported as a number", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport(137, 100),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "wallet-chain",
      walletChainId: 137n,
      message: "Expected chain 1, but the wallet reports chain 137. Writes are disabled.",
    });
  });
});

describe("probeRpcAlignment failure attribution", () => {
  // THE REPORTED CASE (2026-09-24). The wallet reported chain 1, so wagmi showed no wrong-network
  // banner, but its own RPC rejected with a plain EIP-1193 object. The probe read only
  // `Error#message`, so the banner said "The app could not prove RPC alignment." and nothing
  // else: not which side failed, not the call, not the wallet's own words.
  it("names the wallet, the call and the wallet's own error when its RPC rejects a read", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      rejecting(transport("0x1", "0x64"), "eth_blockNumber", EIP1193_INTERNAL_ERROR),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "wallet",
      message:
        "The wallet RPC did not answer eth_blockNumber: Internal JSON-RPC error. (code -32603). Writes are disabled.",
    });
  });

  // THE MASKING REGRESSION. Chain IDs and block numbers used to share one Promise.all, so a
  // wallet on another chain whose RPC failed a block read came back as an unexplained failure,
  // hiding the one cause a switch request can repair.
  it("still reports a switchable wrong chain when that chain's RPC fails every later read", async () => {
    const deadChain = rejecting(
      rejecting(transport("0x89", "0x64"), "eth_blockNumber", EIP1193_INTERNAL_ERROR),
      "eth_getBlockByNumber",
      EIP1193_INTERNAL_ERROR,
    );
    const result = await probeRpcAlignment(transport("0x1", "0x64"), deadChain, OPTIONS);
    expect(result).toEqual({
      aligned: false,
      reason: "wallet-chain",
      walletChainId: 137n,
      message: "Expected chain 1, but the wallet reports chain 137. Writes are disabled.",
    });
  });

  it("still reports a switchable wrong chain when the app transport fails at the same time", async () => {
    const appDown = rejecting(
      transport("0x1", "0x64"),
      "eth_chainId",
      new HttpRequestError({url: "https://rpc.invalid", status: 503}),
    );
    const result = await probeRpcAlignment(appDown, transport("0x89", "0x64"), OPTIONS);
    expect(result).toEqual({
      aligned: false,
      reason: "wallet-chain",
      walletChainId: 137n,
      message: "Expected chain 1, but the wallet reports chain 137. Writes are disabled.",
    });
  });

  it("names the app and renders viem's HTTP failure when the app transport fails", async () => {
    const appDown = rejecting(
      transport("0x1", "0x64"),
      "eth_chainId",
      new HttpRequestError({
        url: "https://rpc.invalid",
        status: 403,
        details: "Unspecified origin not on whitelist.",
      }),
    );
    const result = await probeRpcAlignment(appDown, transport("0x1", "0x64"), OPTIONS);
    expect(result).toEqual({
      aligned: false,
      reason: "app",
      message:
        "The app RPC did not answer eth_chainId: HTTP request failed. Unspecified origin not on whitelist. (HTTP 403). Writes are disabled.",
    });
  });

  it("names the header call when the wallet rejects it with a bare string", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      rejecting(transport("0x1", "0x64"), "eth_getBlockByNumber", "Method not supported"),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "wallet",
      message:
        "The wallet RPC did not answer eth_getBlockByNumber: Method not supported. Writes are disabled.",
    });
  });

  it("attributes a provider that throws synchronously instead of rejecting", async () => {
    const base = transport("0x1", "0x64");
    const synchronousThrow = ((args: {method: string; params?: readonly unknown[]}) => {
      if (args.method === "eth_blockNumber") {
        throw {code: 4100, message: "The requested method has not been authorized by the user."};
      }
      return base(args);
    }) as RpcRequest;
    const result = await probeRpcAlignment(transport("0x1", "0x64"), synchronousThrow, OPTIONS);
    expect(result).toEqual({
      aligned: false,
      reason: "wallet",
      message:
        "The wallet RPC did not answer eth_blockNumber: The requested method has not been authorized by the user. (code 4100). Writes are disabled.",
    });
  });

  it("still explains a rejection that carries no information at all", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      rejecting(transport("0x1", "0x64"), "eth_chainId", undefined),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "wallet",
      message: "The wallet RPC did not answer eth_chainId: no error details. Writes are disabled.",
    });
  });

  it("names a wallet whose node has no header yet for the common block", async () => {
    const lagging: RpcRequest = async (args) =>
      args.method === "eth_getBlockByNumber" ? null : transport("0x1", "0x64")(args);
    const result = await probeRpcAlignment(transport("0x1", "0x64"), lagging, OPTIONS);
    expect(result).toEqual({
      aligned: false,
      reason: "wallet",
      message: "The wallet RPC did not return a header for block 100. Writes are disabled.",
    });
  });

  it("blames the app when the app RPC reports a chain this build is not for", async () => {
    const result = await probeRpcAlignment(
      transport("0xaa36a7", "0x64"),
      transport("0x1", "0x64"),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "app",
      message: "Expected chain 1, but the app RPC reports chain 11155111. Writes are disabled.",
    });
  });

  it("reports drift beyond the limit as a state disagreement", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport("0x1", "0x79"),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "state",
      message: "The wallet RPC and app RPC are 21 blocks apart. Writes are disabled.",
    });
  });

  it("reports different hashes at the common block as a state disagreement", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport("0x1", "0x64", OTHER_HASH),
      OPTIONS,
    );
    expect(result).toEqual({
      aligned: false,
      reason: "state",
      message:
        "The app and wallet disagree on block 100. They are connected to different fork or network state.",
    });
  });
});

describe("describeRpcError", () => {
  it.each<[string, unknown, string]>([
    ["an EIP-1193 object", EIP1193_INTERNAL_ERROR, "Internal JSON-RPC error. (code -32603)"],
    ["a string code", {code: "ACTION_REJECTED", message: "user rejected"}, "user rejected (code ACTION_REJECTED)"],
    ["an object with only a code", {code: 4200}, "no message (code 4200)"],
    ["a multi-line Error", new Error("line one\n\n  line two"), "line one line two"],
    ["a bare string", "  Method not supported ", "Method not supported"],
    ["an empty string", "", "an empty error message"],
    ["undefined", undefined, "no error details"],
    ["null", null, "no error details"],
    ["a number", 42, "42"],
  ])("renders %s", (_label, error, expected) => {
    expect(describeRpcError(error)).toBe(expected);
  });

  it("prefers viem's short message and adds its details and HTTP status", () => {
    const error = new HttpRequestError({url: "https://rpc.invalid", status: 429, details: "Too many requests"});
    expect(error.message).toContain("\n");
    expect(describeRpcError(error)).toBe("HTTP request failed. Too many requests (HTTP 429)");
  });

  it("clips a runaway message to one banner line", () => {
    const text = describeRpcError({message: "x".repeat(1000)});
    expect(text).toHaveLength(240);
    expect(text.endsWith("…")).toBe(true);
  });
});
