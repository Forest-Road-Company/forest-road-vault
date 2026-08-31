/**
 * Fail-closed comparison between the application's read transport and the
 * wallet's submission transport. Local forks use their own chain ID and require
 * an exact tip match; canonical remote endpoints may be slightly out of sync,
 * but must share the same newest common block.
 */

export type RpcRequest = (args: {
  method: string;
  params?: readonly unknown[];
}) => Promise<unknown>;

export type RpcAlignmentResult =
  | {aligned: true; blockNumber: bigint; blockHash: `0x${string}`}
  | {aligned: false; message: string};

const LOCAL_RPC_RE = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::|\/|$)/i;
const RPC_BLOCK_DRIFT_LIMIT = 20n;
const BLOCK_HASH_RE = /^0x[0-9a-fA-F]{64}$/;

export type RpcAlignmentOptions = {
  expectedChainId: number;
  requireExactTip: boolean;
};

function blockGap(a: bigint, b: bigint): bigint {
  return a > b ? a - b : b - a;
}

export function isLocalRpcUrl(url: string): boolean {
  return LOCAL_RPC_RE.test(url);
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
function asRpcQuantity(value: unknown, label: string): bigint {
  if (typeof value === "bigint") {
    if (value < 0n) throw new Error(`RPC returned an invalid ${label}.`);
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`RPC returned an invalid ${label}.`);
    }
    return BigInt(value);
  }
  if (typeof value === "string") {
    if (/^0x[0-9a-fA-F]+$/.test(value)) return BigInt(value);
    if (/^[0-9]+$/.test(value)) return BigInt(value); // decimal shim
  }
  throw new Error(`RPC returned an invalid ${label}.`);
}

function asBlockHash(value: unknown): `0x${string}` {
  if (typeof value !== "object" || value === null || !("hash" in value)) {
    throw new Error("RPC returned an invalid block header.");
  }
  const hash = (value as {hash?: unknown}).hash;
  if (typeof hash !== "string" || !BLOCK_HASH_RE.test(hash)) {
    throw new Error("RPC block header did not contain a canonical hash.");
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
    const [appChainRaw, walletChainRaw, appBlockRaw, walletBlockRaw] =
      await Promise.all([
        appRequest({method: "eth_chainId"}),
        walletRequest({method: "eth_chainId"}),
        appRequest({method: "eth_blockNumber"}),
        walletRequest({method: "eth_blockNumber"}),
      ]);

    const appChain = asRpcQuantity(appChainRaw, "chain ID");
    const walletChain = asRpcQuantity(walletChainRaw, "chain ID");
    const expectedChain = BigInt(options.expectedChainId);
    if (appChain !== expectedChain || walletChain !== expectedChain) {
      return {
        aligned: false,
        message: `Expected chain ${expectedChain.toString()}, but the app RPC reports ${appChain.toString()} and the wallet RPC reports ${walletChain.toString()}. Writes are disabled.`,
      };
    }

    const appBlock = asRpcQuantity(appBlockRaw, "block number");
    const walletBlock = asRpcQuantity(walletBlockRaw, "block number");
    const gap = blockGap(appBlock, walletBlock);
    if (options.requireExactTip && gap !== 0n) {
      return {
        aligned: false,
        message: `The local app and wallet RPC tips differ by ${gap.toString()} block${gap === 1n ? "" : "s"}. They are not the same fork instance.`,
      };
    }
    if (gap > RPC_BLOCK_DRIFT_LIMIT) {
      return {
        aligned: false,
        message: `The wallet RPC and app RPC are ${gap.toString()} blocks apart. Writes are disabled.`,
      };
    }

    const commonBlock = appBlock < walletBlock ? appBlock : walletBlock;
    const blockTag = `0x${commonBlock.toString(16)}`;
    const [appHeader, walletHeader] = await Promise.all([
      appRequest({method: "eth_getBlockByNumber", params: [blockTag, false]}),
      walletRequest({method: "eth_getBlockByNumber", params: [blockTag, false]}),
    ]);
    const appHash = asBlockHash(appHeader);
    const walletHash = asBlockHash(walletHeader);

    if (appHash.toLowerCase() !== walletHash.toLowerCase()) {
      return {
        aligned: false,
        message:
          `The app and wallet disagree on block ${commonBlock.toString()}. They are connected to different fork or network state.`,
      };
    }

    return {aligned: true, blockNumber: commonBlock, blockHash: appHash};
  } catch (error) {
    return {
      aligned: false,
      message:
        error instanceof Error
          ? `The app could not prove RPC alignment: ${error.message}`
          : "The app could not prove RPC alignment.",
    };
  }
}
