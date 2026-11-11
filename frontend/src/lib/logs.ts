export const DEFAULT_BLOCK_CHUNK = 9_000n;

/**
 * Chunks each browser history stream keeps in flight (YieldPositionPanel).
 *
 * The panel runs three streams at once. Through the same-origin RPC proxy every round trip pays the
 * hop to the function region (measured from London: 139 ms, against 46 ms to Alchemy directly), so
 * reading 9,000-block chunks one at a time made the first sweep about three times slower. With
 * several chunks in flight, the browser transport folds the streams' concurrent eth_getLogs into
 * one batched request (3 x 3 = 9, under the proxy's 20-entry cap).
 *
 * Why three. The upstream provider's throughput is finite, so the sweep should not burst harder
 * than the direct sequential sweep it replaces. Its call rate scales as concurrency x (direct round
 * trip / proxied round trip), about concurrency x 46 / 139, so three holds it at today's rate while
 * returning the London sweep to today's duration. Measured on a local model of those round trips:
 * direct sequential 1.85 s at 63 calls/s; proxied sequential 5.87 s at 20/s; three in flight
 * 1.96 s at 60/s; four in flight 1.51 s at 78/s (a burst about a quarter above today's).
 */
export const BROWSER_HISTORY_CONCURRENCY = 3;

/** Returns only the inclusive range not covered by an existing history cursor. */
export function nextUnreadBlockRange(
  lastScannedBlock: bigint,
  latestBlock: bigint,
): {fromBlock: bigint; toBlock: bigint} | null {
  if (latestBlock <= lastScannedBlock) return null;
  return {fromBlock: lastScannedBlock + 1n, toBlock: latestBlock};
}

/**
 * Reads an inclusive block range in bounded chunks. Public RPCs commonly reject
 * large eth_getLogs ranges; callers provide the typed event read for one chunk.
 *
 * Up to `concurrency` chunks are read at once (default 1, one after another, which the server-side
 * history reads keep). Results always come back in block order, whatever order the chunks finish
 * in. The first chunk that fails fails the whole read: no chunk starts after it, the chunks already
 * in flight are allowed to settle, and that first error is thrown. There is never a partial result.
 */
export async function readBlockRangeChunked<T>(
  fromBlock: bigint,
  toBlock: bigint,
  readChunk: (chunkFrom: bigint, chunkTo: bigint) => Promise<readonly T[]>,
  chunkSize = DEFAULT_BLOCK_CHUNK,
  concurrency = 1,
): Promise<T[]> {
  if (chunkSize <= 0n) throw new Error("chunkSize must be positive");
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
    throw new Error("concurrency must be a positive integer");
  }
  if (toBlock < fromBlock) return [];

  const chunks: (readonly T[])[] = [];
  let nextFrom = fromBlock;
  let nextIndex = 0;
  let failed = false;
  let failure: unknown;

  async function worker(): Promise<void> {
    while (!failed && nextFrom <= toBlock) {
      const index = nextIndex++;
      const chunkFrom = nextFrom;
      const candidateEnd = chunkFrom + chunkSize - 1n;
      const chunkTo = candidateEnd < toBlock ? candidateEnd : toBlock;
      nextFrom = chunkTo + 1n;
      try {
        chunks[index] = await readChunk(chunkFrom, chunkTo);
      } catch (error) {
        if (!failed) {
          failed = true;
          failure = error;
        }
        return;
      }
    }
  }

  const chunkCount = (toBlock - fromBlock) / chunkSize + 1n;
  const workers = chunkCount < BigInt(concurrency) ? Number(chunkCount) : concurrency;
  await Promise.all(Array.from({length: workers}, () => worker()));
  if (failed) throw failure;

  const results: T[] = [];
  for (const chunk of chunks) results.push(...chunk);
  return results;
}
