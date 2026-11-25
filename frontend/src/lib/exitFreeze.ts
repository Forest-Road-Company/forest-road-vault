/**
 * The LMV-09 exit-freeze read, with a narrow fallback for the vault implementation that predates it
 * (audit JO-04).
 *
 * The release's sUSDfr adds `unresolvedPastDueExposure()`; while it is non-zero, direct and queued
 * exits refuse. The deployed vault implementation has neither the view nor the freeze, so the read
 * reverts with empty data there, and the site (which deploys from main) would show settlement as
 * "being checked" for every visitor until the release executes.
 *
 * The fallback is keyed to the implementation, never to the error alone. A failed read selects the
 * legacy status only when BOTH hold:
 *   1. the read failed with an empty revert (a missing selector, through Multicall3 or directly), not
 *      a transport, proxy, timeout or decoded contract error; and
 *   2. the vault proxy's ERC-1967 implementation slot, read at the latest block, holds a reviewed
 *      implementation that has no exit freeze.
 * The release replaces that implementation, so after it executes condition 2 can never hold: any
 * failure of the read then stays "unavailable" instead of becoming "not frozen". The implementation
 * view `unresolvedPastDueExposure` itself bubbles an empty revert when its impairment source lacks
 * the function, exactly when exits also revert, which is why an error-only rule would be unsafe.
 * Cached answers are unavailable after a failed refetch. Neither an old zero exposure nor a
 * cached implementation address proves the latest state during an RPC outage (LC-03).
 */

import {
  BaseError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  ExecutionRevertedError,
  RawContractError,
  type Address,
  type Hex,
} from "viem";

/** keccak256("eip1967.proxy.implementation") - 1. */
export const ERC1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" as const;

/**
 * Reviewed sUSDfr implementations without the LMV-09 exit freeze, per chain and vault proxy
 * (lower-case). Ethereum: the live vault proxy ran 0x0b78…d38b at block 26,421,603 (eth_getStorageAt
 * of the slot above), and `unresolvedPastDueExposure()` reverted there with data "0x". Its runtime is
 * the deployed 493963b7 build. No other chain is listed, so a testnet keeps the strict behaviour.
 */
const PRE_EXIT_FREEZE_IMPLEMENTATIONS: Readonly<Record<number, Readonly<Record<string, readonly string[]>>>> = {
  1: {
    "0xaf559d1d59b33ca4b950ab2091372af8a773e234": ["0x0b78342501d67ec03af1d8e0a60c900bb227d38b"],
  },
};

/** The reviewed pre-freeze implementations of this vault proxy on this chain (lower-case). */
export function preExitFreezeImplementations(chainId: number, vault: Address): readonly string[] {
  return PRE_EXIT_FREEZE_IMPLEMENTATIONS[chainId]?.[vault.toLowerCase()] ?? [];
}

const EMPTY_REVERT_MESSAGE = /^execution reverted\.?$/i;

/**
 * True only for a contract call that reverted with no revert data (or returned no data at all): what a
 * call to a function the implementation does not have produces. Everything else is false: HTTP,
 * timeout and proxy failures (which carry no revert data at all, not empty data), rate limits, and any
 * revert with data, decodable or not.
 */
export function isEmptyRevert(error: unknown): boolean {
  if (!(error instanceof BaseError)) return false;
  // A success with no return data: the selector fell through to an empty fallback.
  if (error.walk((cause) => cause instanceof ContractFunctionZeroDataError)) return true;
  // Through Multicall3 (Wagmi's default batching): the failed sub-call's exact return data.
  const raw = error.walk((cause) => cause instanceof RawContractError);
  if (raw instanceof RawContractError) return raw.data === "0x";
  // A direct eth_call answered with an execution-reverted code and explicit empty data.
  const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError);
  if (reverted instanceof ContractFunctionRevertedError) {
    return reverted.raw === "0x" && reverted.data === undefined && reverted.signature === undefined;
  }
  // A node that reports an empty revert as a bare "execution reverted" message without data.
  const node = error.walk((cause) => cause instanceof ExecutionRevertedError);
  if (node instanceof ExecutionRevertedError) {
    const details = (node.details ?? "").trim();
    const withData = error.walk((cause) => "data" in (cause as object) && (cause as {data?: unknown}).data !== undefined);
    return EMPTY_REVERT_MESSAGE.test(details) && withData === null;
  }
  return false;
}

/** The implementation address held by an ERC-1967 slot word, or null for a malformed word. */
export function implementationFromSlot(word: Hex | undefined): string | null {
  if (word === undefined || !/^0x[0-9a-fA-F]{64}$/.test(word)) return null;
  if (!/^0{24}$/.test(word.slice(2, 26))) return null;
  return `0x${word.slice(26).toLowerCase()}`;
}

export type ExitFreezeRead =
  /** No answer yet, or the implementation probe is still pending. */
  | {kind: "loading"}
  /** The read failed and nothing proves the vault predates the freeze. */
  | {kind: "unavailable"}
  /** A reviewed pre-freeze implementation: this vault has no exit freeze to report. */
  | {kind: "legacy-vault"}
  /** The vault's own answer. */
  | {kind: "vault"; exposure: bigint};

/** Whether the implementation slot must be read to resolve a failed exposure read. */
export function needsImplementationProbe(
  chainId: number,
  vault: Address,
  data: bigint | undefined,
  error: unknown,
): boolean {
  return data === undefined && error != null && isEmptyRevert(error) &&
    preExitFreezeImplementations(chainId, vault).length > 0;
}

/** Classifies the exposure read; see the module comment for why the implementation decides. */
export function classifyExitFreeze({
  chainId,
  vault,
  data,
  error,
  implementationSlot,
  implementationError,
}: {
  chainId: number;
  vault: Address;
  data: bigint | undefined;
  error: unknown;
  implementationSlot: Hex | undefined;
  implementationError?: unknown;
}): ExitFreezeRead {
  if (data !== undefined) return error == null ? {kind: "vault", exposure: data} : {kind: "unavailable"};
  if (error == null) return {kind: "loading"};
  if (!needsImplementationProbe(chainId, vault, data, error)) return {kind: "unavailable"};
  if (implementationError != null) return {kind: "unavailable"};
  if (implementationSlot === undefined) return {kind: "loading"};
  const implementation = implementationFromSlot(implementationSlot);
  return implementation !== null && preExitFreezeImplementations(chainId, vault).includes(implementation)
    ? {kind: "legacy-vault"}
    : {kind: "unavailable"};
}

/**
 * The exposure the queue status and copy use: the vault's answer, zero for a reviewed pre-freeze
 * implementation (it has no freeze), and undefined (loading/unavailable) otherwise.
 */
export function exitFreezeExposure(read: ExitFreezeRead): bigint | undefined {
  if (read.kind === "vault") return read.exposure;
  if (read.kind === "legacy-vault") return 0n;
  return undefined;
}
