/**
 * Real viem read failures for the exit-freeze tests (audit JO-04): each is the error viem itself
 * builds when a node answers `unresolvedPastDueExposure()` in the given way, through the same
 * readContract path Wagmi uses (Multicall3 batching on, as Wagmi's default, or a direct eth_call).
 */
import {
  HttpRequestError,
  TimeoutError,
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeErrorResult,
  encodeFunctionResult,
  multicall3Abi,
  parseAbi,
  type Hex,
} from "viem";
import {mainnet} from "viem/chains";

export const MAINNET_VAULT = "0xAF559d1D59B33ca4b950AB2091372Af8a773E234" as const;
/** The live pre-release implementation, as a 32-byte ERC-1967 slot word. */
export const LEGACY_IMPLEMENTATION_SLOT: Hex =
  "0x0000000000000000000000000b78342501d67ec03af1d8e0a60c900bb227d38b";
/** Any other implementation, for example the released vault. */
export const RELEASED_IMPLEMENTATION_SLOT: Hex =
  "0x0000000000000000000000001111111111111111111111111111111111111111";

const abi = parseAbi([
  "function unresolvedPastDueExposure() view returns (uint256)",
  "error SUSDfr_UnresolvedPastDue(uint256 exposure)",
]);

type Answer =
  | {kind: "multicall"; success: boolean; returnData: Hex}
  | {kind: "result"; result: Hex}
  | {kind: "throw"; error: unknown};

async function failureOf(answer: Answer): Promise<unknown> {
  const client = createPublicClient({
    chain: mainnet,
    batch: answer.kind === "multicall" ? {multicall: true} : undefined,
    transport: custom({
      async request({method, params}: {method: string; params?: unknown}) {
        if (method !== "eth_call") throw new Error(`unexpected ${method}`);
        if (answer.kind === "throw") throw answer.error;
        if (answer.kind === "result") return answer.result;
        const call = (params as [{data: Hex}])[0];
        const {args} = decodeFunctionData({abi: multicall3Abi, data: call.data});
        return encodeFunctionResult({
          abi: multicall3Abi,
          functionName: "aggregate3",
          result: (args[0] as readonly unknown[]).map(() => ({success: answer.success, returnData: answer.returnData})),
        });
      },
    }, {retryCount: 0}),
  });
  try {
    await client.readContract({address: MAINNET_VAULT, abi, functionName: "unresolvedPastDueExposure"});
  } catch (error) {
    return error;
  }
  throw new Error("the read unexpectedly succeeded");
}

const rpc = (code: number, message: string, data?: Hex) =>
  Object.assign(new Error(message), data === undefined ? {code} : {code, data});

const decodedRevert = encodeErrorResult({abi, errorName: "SUSDfr_UnresolvedPastDue", args: [5n]});

/** Each failure shape, built by viem. */
export async function readFailures() {
  return {
    // A missing selector: what the pre-release vault gives.
    multicallEmpty: await failureOf({kind: "multicall", success: false, returnData: "0x"}),
    directEmptyCode3: await failureOf({kind: "throw", error: rpc(3, "execution reverted", "0x")}),
    directEmptyGeth: await failureOf({kind: "throw", error: rpc(-32000, "execution reverted")}),
    zeroData: await failureOf({kind: "result", result: "0x"}),
    // Not a missing selector.
    multicallDecoded: await failureOf({kind: "multicall", success: false, returnData: decodedRevert}),
    directDecoded: await failureOf({kind: "throw", error: rpc(3, "execution reverted", decodedRevert)}),
    directUndecodable: await failureOf({kind: "throw", error: rpc(3, "execution reverted", "0xdeadbeef")}),
    gethWithReason: await failureOf({kind: "throw", error: rpc(-32000, "execution reverted: paused")}),
    proxyUpstreamUnavailable: await failureOf({kind: "throw", error: rpc(-32603, "Upstream RPC unavailable")}),
    proxyRateLimited: await failureOf({kind: "throw", error: rpc(-32005, "Upstream RPC rate limited")}),
    http: await failureOf({
      kind: "throw",
      error: new HttpRequestError({url: "https://site.invalid/api/rpc", status: 502, body: {method: "eth_call"}}),
    }),
    timeout: await failureOf({kind: "throw", error: new TimeoutError({body: {method: "eth_call"}, url: "https://site.invalid/api/rpc"})}),
    plainError: new Error("execution reverted"),
  };
}
