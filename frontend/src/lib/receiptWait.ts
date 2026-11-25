/**
 * Waiting for a sent transaction's receipt without mistaking a read failure for a failed transaction.
 *
 * viem's waitForTransactionReceipt reads each new block with its full transactions while a sent
 * transaction is pending (to detect a speed-up or cancellation), and rejects on any error from that
 * read except "block not found". Through the RPC proxy one such error is expected: a block whose
 * full-transaction answer is over the proxy's size budget comes back as the named -32008 error, and
 * since EIP-7623 a block like that is cheap to produce with zero-byte calldata. Any other transient
 * RPC failure does the same. Reporting that as "failed" would invite a second, duplicate submission
 * of a transaction that may still be mined.
 *
 * So the wait restarts after such a rejection, a bounded number of times, one block apart (the
 * oversized block is then behind it). If it still cannot tell, it throws
 * {@link ReceiptStatusUnknownError}, which callers show as "status unknown", never as failed. It
 * never reports success without a receipt, and a receipt with a revert status is returned as it is.
 * The overall wait timeout is also converted to {@link ReceiptStatusUnknownError} without
 * restarting, so a slow pending transaction is never reported as failed.
 */

import {TransactionReceiptNotFoundError, type Hash, type PublicClient, type TransactionReceipt} from "viem";

/** How many times the wait is restarted after a read failure before the status is called unknown. */
export const RECEIPT_WAIT_RESTARTS = 3;
/** One slot: by the next attempt a new block has arrived, so the failed block read is behind it. */
export const RECEIPT_WAIT_RESTART_DELAY_MS = 12_000;

export const RECEIPT_STATUS_UNKNOWN_MESSAGE =
  "This transaction was sent, but its status could not be confirmed. It may still be mined: check it in your wallet or on the explorer, and do not send it again.";

export class ReceiptStatusUnknownError extends Error {
  readonly hash: Hash;

  constructor(hash: Hash, cause: unknown) {
    super(RECEIPT_STATUS_UNKNOWN_MESSAGE, {cause});
    this.name = "ReceiptStatusUnknownError";
    this.hash = hash;
  }
}

type WaitArgs = Parameters<PublicClient["waitForTransactionReceipt"]>[0];
type ReceiptWaiter = {waitForTransactionReceipt: (args: WaitArgs) => Promise<TransactionReceipt>};

export type ReceiptWaitOptions = {
  restarts?: number;
  restartDelayMs?: number;
  /** Cumulative ceiling across restarts; defaults to `args.timeout` (when set) or unlimited. */
  maxTotalMs?: number;
  /** Test seam for the pause between attempts. */
  sleep?: (ms: number) => Promise<void>;
  /** Test seam for the clock. */
  now?: () => number;
};

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function isWaitTimeout(error: unknown): boolean {
  return error instanceof Error && error.name === "WaitForTransactionReceiptTimeoutError";
}

/**
 * Matches viem's `TransactionReceiptNotFoundError` (whose message reads `"could not be found"`,
 * not `"not found"`) as well as plain provider receipt/transaction `"not found"` errors when
 * polling a pending tx. Unrelated RPC errors (e.g. `"Block not found"`, `"Method not found"`)
 * return false.
 */
export function isReceiptNotFoundError(error: unknown): boolean {
  for (
    let e: unknown = error, depth = 0;
    e !== null && e !== undefined && typeof e === "object" && depth < 5;
    e = (e as {cause?: unknown}).cause, depth += 1
  ) {
    if (e instanceof TransactionReceiptNotFoundError) return true;
    const node = e as {name?: unknown; shortMessage?: unknown; message?: unknown};
    if (node.name === "TransactionReceiptNotFoundError") return true;
    const text = [node.shortMessage, node.message]
      .filter((part): part is string => typeof part === "string")
      .join(" ");
    if (/(?:transaction\s+)?receipt\b.*\bnot (?:be )?found|\btransaction\b.*\bnot (?:be )?found/i.test(text)) {
      return true;
    }
  }
  return false;
}

export async function waitForReceiptRobustly(
  client: ReceiptWaiter,
  args: WaitArgs,
  {
    restarts = RECEIPT_WAIT_RESTARTS,
    restartDelayMs = RECEIPT_WAIT_RESTART_DELAY_MS,
    maxTotalMs,
    sleep = defaultSleep,
    now = Date.now,
  }: ReceiptWaitOptions = {},
): Promise<TransactionReceipt> {
  const effectiveMaxTotalMs = maxTotalMs ?? args.timeout;
  const startedAt = now();
  for (let attempt = 0; ; attempt += 1) {
    const attemptArgs =
      effectiveMaxTotalMs !== undefined
        ? {
            ...args,
            timeout: Math.max(
              1,
              Math.min(
                args.timeout ?? effectiveMaxTotalMs,
                effectiveMaxTotalMs - (now() - startedAt),
              ),
            ),
          }
        : args;
    try {
      return await client.waitForTransactionReceipt(attemptArgs);
    } catch (error) {
      // A receipt timeout means the tx was broadcast and may still confirm on-chain. Never report
      // it as a failure (which invites a duplicate submission) and do not restart after a timeout.
      if (isWaitTimeout(error)) throw new ReceiptStatusUnknownError(args.hash, error);
      if (attempt >= restarts) throw new ReceiptStatusUnknownError(args.hash, error);
      if (effectiveMaxTotalMs !== undefined) {
        const remainingBeforeSleep = effectiveMaxTotalMs - (now() - startedAt);
        if (remainingBeforeSleep <= restartDelayMs) {
          throw new ReceiptStatusUnknownError(args.hash, error);
        }
      }
      await sleep(restartDelayMs);
      if (effectiveMaxTotalMs !== undefined && now() - startedAt >= effectiveMaxTotalMs) {
        throw new ReceiptStatusUnknownError(args.hash, error);
      }
    }
  }
}
