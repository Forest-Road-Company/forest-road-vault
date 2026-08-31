import {describe, expect, it} from "vitest";

import {probeRpcAlignment, type RpcRequest} from "./rpcAlignment";

const CHAIN = 1;
const HASH = `0x${"ab".repeat(32)}` as const;

/**
 * Builds a transport that answers the four calls `probeRpcAlignment` makes, with the chain ID
 * and block number encoded however the caller asks. Real wallets differ here: a compliant
 * endpoint returns a hex quantity, while Fireblocks over WalletConnect and several mobile
 * shims return a JS number or a bare decimal string.
 */
function transport(chainId: unknown, blockNumber: unknown): RpcRequest {
  return async ({method}) => {
    if (method === "eth_chainId") return chainId;
    if (method === "eth_blockNumber") return blockNumber;
    if (method === "eth_getBlockByNumber") return {hash: HASH};
    throw new Error(`unexpected method ${method}`);
  };
}

const OPTIONS = {expectedChainId: CHAIN, requireExactTip: false};

describe("probeRpcAlignment quantity parsing", () => {
  it("accepts the compliant hex form on both transports", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport("0x1", "0x64"),
      OPTIONS,
    );
    expect(result.aligned).toBe(true);
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
  // refusal surfaces as a NOT-aligned result rather than a thrown error escaping the probe.
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
    expect(result.aligned).toBe(false);
  });

  // Encoding leniency must not become chain leniency: a wallet on the wrong chain is still
  // blocked, whichever shape it reports in.
  it("still blocks a wallet on the wrong chain reported as a number", async () => {
    const result = await probeRpcAlignment(
      transport("0x1", "0x64"),
      transport(137, 100),
      OPTIONS,
    );
    expect(result.aligned).toBe(false);
  });
});
