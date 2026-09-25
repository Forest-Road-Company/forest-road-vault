/**
 * Fail-closed comparison between the application's read transport and the
 * wallet's submission transport. Local forks use their own chain ID and require
 * an exact tip match; canonical remote endpoints may be slightly out of sync,
 * but must share the same newest common block.
 *
 * Every refusal names its cause, because the cause decides what the person can
 * do about it. Only a wallet on another chain can be repaired from the page, by
 * asking the wallet to switch. A wallet that reports the right chain but cannot
 * answer, or answers from different state, is usually pointed at a custom RPC or
 * a fork for that chain, and no switch request changes that.
 */

export type RpcRequest = (args: {
  method: string;
  params?: readonly unknown[];
}) => Promise<unknown>;

/**
 * Why alignment was not proved.
 *   wallet-chain  the wallet reports another chain; the one cause a switch request repairs.
 *   wallet        the wallet transport failed a read or answered with something malformed.
 *   app           the app transport did, or it reports a chain this build is not for.
 *   state         both answered, but they are too far apart or disagree on a block.
 */
export type RpcAlignmentFailure = "wallet-chain" | "wallet" | "app" | "state";

export type RpcAlignmentResult =
  | {aligned: true; blockNumber: bigint; blockHash: `0x${string}`}
  | {aligned: false; reason: "wallet-chain"; walletChainId: bigint; message: string}
  | {aligned: false; reason: Exclude<RpcAlignmentFailure, "wallet-chain">; message: string};

const LOCAL_RPC_RE = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::|\/|$)/i;
const RPC_BLOCK_DRIFT_LIMIT = 20n;
const BLOCK_HASH_RE = /^0x[0-9a-fA-F]{64}$/;
const MAX_ERROR_TEXT = 240;

export type RpcAlignmentOptions = {
  expectedChainId: number;
  requireExactTip: boolean;
};

type RpcSide = "app" | "wallet";

/** A failed or malformed answer, attributed to the transport that gave it. */
class RpcSideError extends Error {
  side: RpcSide;

  constructor(side: RpcSide, message: string) {
    super(message);
    this.name = "RpcSideError";
    this.side = side;
  }
}

function blockGap(a: bigint, b: bigint): bigint {
  return a > b ? a - b : b - a;
}

export function isLocalRpcUrl(url: string): boolean {
  return LOCAL_RPC_RE.test(url);
}

function oneLine(value: unknown): string {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
}

function clip(text: string): string {
  return text.length > MAX_ERROR_TEXT ? `${text.slice(0, MAX_ERROR_TEXT - 1)}…` : text;
}

/** Ends `text` as a sentence, so a wallet's unpunctuated message still reads before ours. */
function sentence(text: string): string {
  return /[.!?]$/.test(text) ? text : `${text}.`;
}

/**
 * One line describing whatever a transport rejected with.
 *
 * The wallet side is the provider's own EIP-1193 `request`
 * (`walletClient.transport.request` is not viem's wrapped `client.request`), and
 * most wallets reject with a plain `{code, message}` object rather than an
 * `Error`. Reading only `Error#message` threw away the one explanation the wallet
 * gave, and the banner said "could not prove RPC alignment" with nothing to act
 * on. viem's own errors carry a `shortMessage`, `details` and, for HTTP
 * failures, a `status`.
 */
export function describeRpcError(error: unknown): string {
  if (typeof error === "string") return clip(oneLine(error) || "an empty error message");
  if (error === null || error === undefined) return "no error details";
  if (typeof error !== "object") return clip(String(error));

  const {shortMessage, message, details, code, status} = error as Record<string, unknown>;
  const summary = oneLine(shortMessage) || oneLine(message) || "no message";
  const parts = [summary];
  const detail = oneLine(details);
  if (detail && detail !== summary) parts.push(detail);
  if (typeof code === "number" || (typeof code === "string" && code.trim() !== "")) {
    parts.push(`(code ${String(code).trim()})`);
  }
  if (typeof status === "number") parts.push(`(HTTP ${status})`);
  return clip(parts.join(" "));
}

/** Makes one call and attributes any failure, synchronous throw included, to its side. */
async function call(
  side: RpcSide,
  request: RpcRequest,
  args: {method: string; params?: readonly unknown[]},
): Promise<unknown> {
  try {
    return await request(args);
  } catch (error) {
    throw new RpcSideError(
      side,
      `The ${side} RPC did not answer ${args.method}: ${describeRpcError(error)}`,
    );
  }
}

/**
 * JSON-RPC specifies a 0x-prefixed hex quantity, and a compliant endpoint returns one.
 * Wallet transports are not uniformly compliant: Fireblocks over WalletConnect, and several
 * other custody and mobile shims, return `eth_chainId` and `eth_blockNumber` as a JS number
 * or a bare decimal string. The original strict form rejected those with "RPC returned an
 * invalid chain ID" while the wallet was in fact on the correct chain, wagmi had already
 * confirmed the network before this probe ran, so the user was told their RPC was broken
 * when nothing was.
 *
 * WIDENED DELIBERATELY, AND THE DIRECTION IS SAFE. This guard exists to COMPARE two chain
 * IDs and two block heights, not to police their encoding: `1`, `"1"` and `"0x1"` are the
 * same claim. Anything that is not an exact non-negative integer is still refused, and a
 * bare decimal string is genuinely ambiguous with hex (`"11"` is 11 or 17). That ambiguity
 * is tolerable only because every consumer of this value FAILS CLOSED: a misparse makes the
 * chain comparison unequal or the block gap large, both of which block writes. It must never
 * be relaxed into a form that returns a default on unparseable input.
 */
function asRpcQuantity(value: unknown, side: RpcSide, label: string): bigint {
  const invalid = () => new RpcSideError(side, `The ${side} RPC returned an invalid ${label}.`);
  if (typeof value === "bigint") {
    if (value < 0n) throw invalid();
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) throw invalid();
    return BigInt(value);
  }
  if (typeof value === "string") {
    if (/^0x[0-9a-fA-F]+$/.test(value)) return BigInt(value);
    if (/^[0-9]+$/.test(value)) return BigInt(value); // decimal shim
  }
  throw invalid();
}

function asBlockHash(value: unknown, side: RpcSide, blockNumber: bigint): `0x${string}` {
  if (typeof value !== "object" || value === null || !("hash" in value)) {
    throw new RpcSideError(
      side,
      `The ${side} RPC did not return a header for block ${blockNumber.toString()}.`,
    );
  }
  const hash = (value as {hash?: unknown}).hash;
  if (typeof hash !== "string" || !BLOCK_HASH_RE.test(hash)) {
    throw new RpcSideError(side, `The ${side} RPC block header did not contain a canonical hash.`);
  }
  return hash as `0x${string}`;
}

/**
 * Checks the explicit chain ID and exact block hash visible through both
 * transports. A local fork is deliberately stricter: independent local nodes do
 * not share transaction propagation, so even a one-block tip difference is a
 * hard mismatch. The local Wagmi transport routes connected reads through the
 * active wallet provider, and the write flow independently uses that same
 * provider for simulation and receipt tracking.
 */
export async function probeRpcAlignment(
  appRequest: RpcRequest,
  walletRequest: RpcRequest,
  options: RpcAlignmentOptions,
): Promise<RpcAlignmentResult> {
  try {
    const expectedChain = BigInt(options.expectedChainId);

    // Chain IDs first, and settled rather than raced. A wallet on another chain is the one
    // cause the page can repair, so it has to win: when these ran in one Promise.all with the
    // block reads, that chain's RPC failing a read, or the app transport failing beside it,
    // turned a switchable wrong network into an unexplained failure.
    const [appChainAnswer, walletChainAnswer] = await Promise.allSettled([
      call("app", appRequest, {method: "eth_chainId"}),
      call("wallet", walletRequest, {method: "eth_chainId"}),
    ]);
    if (walletChainAnswer.status === "rejected") throw walletChainAnswer.reason;
    const walletChain = asRpcQuantity(walletChainAnswer.value, "wallet", "chain ID");
    if (walletChain !== expectedChain) {
      return {
        aligned: false,
        reason: "wallet-chain",
        walletChainId: walletChain,
        message: `Expected chain ${expectedChain.toString()}, but the wallet reports chain ${walletChain.toString()}. Writes are disabled.`,
      };
    }
    if (appChainAnswer.status === "rejected") throw appChainAnswer.reason;
    const appChain = asRpcQuantity(appChainAnswer.value, "app", "chain ID");
    if (appChain !== expectedChain) {
      return {
        aligned: false,
        reason: "app",
        message: `Expected chain ${expectedChain.toString()}, but the app RPC reports chain ${appChain.toString()}. Writes are disabled.`,
      };
    }

    const [appBlockRaw, walletBlockRaw] = await Promise.all([
      call("app", appRequest, {method: "eth_blockNumber"}),
      call("wallet", walletRequest, {method: "eth_blockNumber"}),
    ]);
    const appBlock = asRpcQuantity(appBlockRaw, "app", "block number");
    const walletBlock = asRpcQuantity(walletBlockRaw, "wallet", "block number");
    const gap = blockGap(appBlock, walletBlock);
    if (options.requireExactTip && gap !== 0n) {
      return {
        aligned: false,
        reason: "state",
        message: `The local app and wallet RPC tips differ by ${gap.toString()} block${gap === 1n ? "" : "s"}. They are not the same fork instance.`,
      };
    }
    if (gap > RPC_BLOCK_DRIFT_LIMIT) {
      return {
        aligned: false,
        reason: "state",
        message: `The wallet RPC and app RPC are ${gap.toString()} blocks apart. Writes are disabled.`,
      };
    }

    const commonBlock = appBlock < walletBlock ? appBlock : walletBlock;
    const blockTag = `0x${commonBlock.toString(16)}`;
    const [appHeader, walletHeader] = await Promise.all([
      call("app", appRequest, {method: "eth_getBlockByNumber", params: [blockTag, false]}),
      call("wallet", walletRequest, {method: "eth_getBlockByNumber", params: [blockTag, false]}),
    ]);
    const appHash = asBlockHash(appHeader, "app", commonBlock);
    const walletHash = asBlockHash(walletHeader, "wallet", commonBlock);

    if (appHash.toLowerCase() !== walletHash.toLowerCase()) {
      return {
        aligned: false,
        reason: "state",
        message:
          `The app and wallet disagree on block ${commonBlock.toString()}. They are connected to different fork or network state.`,
      };
    }

    return {aligned: true, blockNumber: commonBlock, blockHash: appHash};
  } catch (error) {
    if (error instanceof RpcSideError) {
      return {
        aligned: false,
        reason: error.side,
        message: `${sentence(error.message)} Writes are disabled.`,
      };
    }
    // Not a transport answer: a defect here, or configuration this probe cannot read. Still a
    // refusal, and still explained.
    return {
      aligned: false,
      reason: "app",
      message: `${sentence(`The app could not prove RPC alignment: ${describeRpcError(error)}`)} Writes are disabled.`,
    };
  }
}
