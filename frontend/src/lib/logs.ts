const DEFAULT_BLOCK_CHUNK = 9_000n;

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
 */
export async function readBlockRangeChunked<T>(
  fromBlock: bigint,
  toBlock: bigint,
  readChunk: (chunkFrom: bigint, chunkTo: bigint) => Promise<readonly T[]>,
  chunkSize = DEFAULT_BLOCK_CHUNK,
): Promise<T[]> {
  if (chunkSize <= 0n) throw new Error("chunkSize must be positive");
  if (toBlock < fromBlock) return [];

  const results: T[] = [];
  let chunkFrom = fromBlock;
  while (chunkFrom <= toBlock) {
    const candidateEnd = chunkFrom + chunkSize - 1n;
    const chunkTo = candidateEnd < toBlock ? candidateEnd : toBlock;
    results.push(...(await readChunk(chunkFrom, chunkTo)));
    chunkFrom = chunkTo + 1n;
  }
  return results;
}
