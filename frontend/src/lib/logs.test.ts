// @vitest-environment node
import {describe, expect, it} from "vitest";
import {
  BROWSER_HISTORY_CONCURRENCY,
  DEFAULT_BLOCK_CHUNK,
  readBlockRangeChunked,
} from "@/lib/logs";
import {RPC_PROXY_MAX_BATCH} from "@/lib/rpcProxyShared";

/**
 * readBlockRangeChunked with bounded concurrency: block order, the in-flight bound, fail-fast with no
 * partial result, and the range edges. Chunks are driven by hand-resolved promises, so every
 * interleaving here is deterministic.
 */

type Pending = {from: bigint; to: bigint; resolve: (value: readonly string[]) => void; reject: (error: Error) => void};

/** A readChunk whose calls wait until the test settles them, recording what started and when. */
function controlledReader() {
  const pending: Pending[] = [];
  const started: string[] = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const readChunk = (from: bigint, to: bigint) => {
    started.push(`${from}-${to}`);
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    return new Promise<readonly string[]>((resolve, reject) => {
      pending.push({
        from,
        to,
        resolve: (value) => {
          inFlight -= 1;
          resolve(value);
        },
        reject: (error) => {
          inFlight -= 1;
          reject(error);
        },
      });
    });
  };
  return {pending, started, readChunk, maxInFlight: () => maxInFlight, inFlight: () => inFlight};
}

/** Lets every queued promise continuation run. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("readBlockRangeChunked: order and the in-flight bound", () => {
  it("returns results in block order when chunks resolve in reverse order", async () => {
    const reader = controlledReader();
    const read = readBlockRangeChunked(0n, 99n, reader.readChunk, 10n, 4);
    await settle();
    // Resolve whatever is in flight, newest first, until all ten chunks are done.
    while (reader.pending.length > 0) {
      const open = reader.pending.splice(0);
      for (const p of open.reverse()) p.resolve([`${p.from}`, `${p.to}`]);
      await settle();
    }
    expect(reader.started).toHaveLength(10);
    const values = await read;
    expect(values).toEqual(Array.from({length: 10}, (_, i) => [`${i * 10}`, `${i * 10 + 9}`]).flat());
  });

  it.each([1, 2, 3, 4, 7])("never has more than %i chunks in flight, and reaches that bound", async (bound) => {
    const reader = controlledReader();
    const read = readBlockRangeChunked(1n, 200n, reader.readChunk, 10n, bound);
    await settle();
    let resolved = 0;
    while (reader.pending.length > 0) {
      expect(reader.inFlight()).toBeLessThanOrEqual(bound);
      // Finish one chunk at a time, from the middle of the window, to vary the completion order.
      const p = reader.pending.splice(Math.floor(reader.pending.length / 2), 1)[0];
      p.resolve([`${p.from}`]);
      resolved += 1;
      await settle();
    }
    expect(resolved).toBe(20);
    expect(reader.maxInFlight()).toBe(bound);
    expect(await read).toEqual(Array.from({length: 20}, (_, i) => `${i * 10 + 1}`));
  });

  it("is sequential by default, so existing callers keep their behaviour", async () => {
    const reader = controlledReader();
    const read = readBlockRangeChunked(1n, 30n, reader.readChunk, 10n);
    await settle();
    expect(reader.started).toEqual(["1-10"]);
    reader.pending.shift()!.resolve(["a"]);
    await settle();
    expect(reader.started).toEqual(["1-10", "11-20"]);
    reader.pending.shift()!.resolve(["b"]);
    await settle();
    reader.pending.shift()!.resolve(["c"]);
    expect(await read).toEqual(["a", "b", "c"]);
    expect(reader.maxInFlight()).toBe(1);
  });

  it("keeps the browser's three streams within one batched proxy request", () => {
    // YieldPositionPanel runs three streams; their concurrent chunks share one viem batch.
    expect(3 * BROWSER_HISTORY_CONCURRENCY).toBeLessThanOrEqual(RPC_PROXY_MAX_BATCH);
    expect(BROWSER_HISTORY_CONCURRENCY).toBe(3);
    expect(DEFAULT_BLOCK_CHUNK).toBe(9_000n);
  });
});

describe("readBlockRangeChunked: failure", () => {
  it("fails the whole read on the first error, starts no chunk after it, and returns nothing partial", async () => {
    const reader = controlledReader();
    const read = readBlockRangeChunked(0n, 199n, reader.readChunk, 10n, 4);
    let settled = false;
    const outcome = read.then(
      (value) => ((settled = true), {ok: true as const, value}),
      (error: unknown) => ((settled = true), {ok: false as const, error}),
    );
    await settle();
    expect(reader.started).toEqual(["0-9", "10-19", "20-29", "30-39"]);
    // The first chunk succeeds, so a fifth starts; then the second chunk fails.
    reader.pending.shift()!.resolve(["first"]);
    await settle();
    expect(reader.started).toHaveLength(5);
    const boom = new Error("chunk 10-19 failed");
    reader.pending.shift()!.reject(boom);
    await settle();
    const startedAtFailure = reader.started.length;
    // It does not throw while chunks are still in flight: they settle first, nothing dangles.
    expect(reader.inFlight()).toBe(3);
    expect(settled).toBe(false);
    // The chunks still in flight settle, one of them with a later error; nothing new starts.
    reader.pending.shift()!.resolve(["third"]);
    await settle();
    reader.pending.shift()!.reject(new Error("a later failure"));
    await settle();
    reader.pending.shift()!.resolve(["fifth"]);
    const result = await outcome;
    expect(reader.started).toHaveLength(startedAtFailure);
    expect(result).toEqual({ok: false, error: boom});
  });

  it("treats a synchronous throw from the chunk reader as the read's failure", async () => {
    const boom = new Error("synchronous");
    let calls = 0;
    await expect(
      readBlockRangeChunked(
        0n,
        99n,
        () => {
          calls += 1;
          throw boom;
        },
        10n,
        4,
      ),
    ).rejects.toBe(boom);
    // Every worker stops at its first call; nothing starts after the failure.
    expect(calls).toBeLessThanOrEqual(4);
  });
});

describe("readBlockRangeChunked: range edges", () => {
  it("reads nothing for an empty (reversed) range", async () => {
    let calls = 0;
    expect(await readBlockRangeChunked(5n, 4n, async () => [String(++calls)], 10n, 4)).toEqual([]);
    expect(calls).toBe(0);
  });

  it("reads a range shorter than one chunk as a single exact chunk", async () => {
    const ranges: string[] = [];
    const values = await readBlockRangeChunked(
      100n,
      104n,
      async (from, to) => {
        ranges.push(`${from}-${to}`);
        return [from];
      },
      10n,
      4,
    );
    expect(ranges).toEqual(["100-104"]);
    expect(values).toEqual([100n]);
  });

  it("reads a single block", async () => {
    const ranges: string[] = [];
    await readBlockRangeChunked(7n, 7n, async (from, to) => (ranges.push(`${from}-${to}`), []), 10n, 4);
    expect(ranges).toEqual(["7-7"]);
  });

  it("splits an exact multiple of the chunk size into full chunks with no empty tail", async () => {
    const ranges: string[] = [];
    await readBlockRangeChunked(0n, 29n, async (from, to) => (ranges.push(`${from}-${to}`), []), 10n, 4);
    expect(ranges.sort()).toEqual(["0-9", "10-19", "20-29"]);
  });

  it("covers the range contiguously, inclusively and exactly once at any concurrency", async () => {
    for (const concurrency of [1, 3, 4, 50]) {
      const ranges: [bigint, bigint][] = [];
      await readBlockRangeChunked(
        13n,
        1_013n,
        async (from, to) => {
          ranges.push([from, to]);
          await new Promise((resolve) => setTimeout(resolve, Number(to % 3n)));
          return [];
        },
        97n,
        concurrency,
      );
      ranges.sort((a, b) => (a[0] < b[0] ? -1 : 1));
      expect(ranges[0][0]).toBe(13n);
      expect(ranges.at(-1)![1]).toBe(1_013n);
      for (let i = 1; i < ranges.length; i += 1) expect(ranges[i][0]).toBe(ranges[i - 1][1] + 1n);
      expect(ranges.every(([from, to]) => to - from + 1n <= 97n)).toBe(true);
    }
  });

  it.each([0n, -1n])("refuses a chunk size of %s", async (size) => {
    await expect(readBlockRangeChunked(1n, 2n, async () => [], size, 4)).rejects.toThrow("chunkSize must be positive");
  });

  it.each([0, -1, 1.5, Number.NaN])("refuses a concurrency of %s", async (concurrency) => {
    await expect(readBlockRangeChunked(1n, 2n, async () => [], 10n, concurrency)).rejects.toThrow(
      "concurrency must be a positive integer",
    );
  });
});
