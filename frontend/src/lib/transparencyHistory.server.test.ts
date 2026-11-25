import {beforeEach, describe, expect, it, vi} from "vitest";
import {
  loadTransparencyHistory,
  resetTransparencyHistoryCacheForTests,
  serveTransparencyHistory,
  type TransparencyEventsBatch,
  type TransparencyHistoryDeps,
  type TransparencyHistorySnapshotStore,
} from "./transparencyHistory.server";
import {EXPECTED_CHAIN} from "./chain";
import {PROTOCOL_DEPLOYMENT_BLOCK} from "@/config/contracts";

function emptyEvents(): TransparencyEventsBatch {
  return {
    originated: [],
    funded: [],
    losses: [],
    originationFees: [],
    distributions: [],
    performanceFees: [],
    managementFees: [],
  };
}

describe("transparencyHistory.server", () => {
  beforeEach(() => {
    resetTransparencyHistoryCacheForTests();
  });

  it("caches finalized history incrementally, coalesces cold requests, and reuses the 60s answer", async () => {
    let clock = 1_000;
    let latest = PROTOCOL_DEPLOYMENT_BLOCK + 120n;
    let finalized = PROTOCOL_DEPLOYMENT_BLOCK + 100n;
    const readRange = vi.fn(async (from: bigint, to: bigint): Promise<TransparencyEventsBatch> => {
      if (from === PROTOCOL_DEPLOYMENT_BLOCK && to === PROTOCOL_DEPLOYMENT_BLOCK + 100n) {
        return {
          ...emptyEvents(),
          originated: [{tokenId: 1n, classId: 2n}],
          funded: [{tokenId: 1n, principal: 5_000n}],
          distributions: [{fee: 10n, toVault: 90n}],
        };
      }
      if (from === PROTOCOL_DEPLOYMENT_BLOCK + 101n && to === PROTOCOL_DEPLOYMENT_BLOCK + 120n) {
        return {
          ...emptyEvents(),
          distributions: [{fee: 2n, toVault: 18n}],
        };
      }
      if (from === PROTOCOL_DEPLOYMENT_BLOCK + 101n && to === PROTOCOL_DEPLOYMENT_BLOCK + 130n) {
        return {
          ...emptyEvents(),
          distributions: [{fee: 3n, toVault: 27n}],
        };
      }
      if (from === PROTOCOL_DEPLOYMENT_BLOCK + 131n && to === PROTOCOL_DEPLOYMENT_BLOCK + 140n) {
        return {
          ...emptyEvents(),
          distributions: [{fee: 1n, toVault: 9n}],
        };
      }
      return emptyEvents();
    });

    const getChainId = vi.fn(async () => EXPECTED_CHAIN.id);
    const deps: TransparencyHistoryDeps = {
      now: () => clock,
      getChainId,
      getLatestAndFinalizedBlocks: async () => ({latest, finalized}),
      readRange,
    };

    // Two concurrent cold callers share one flight.
    const [first, second] = await Promise.all([
      loadTransparencyHistory(deps),
      loadTransparencyHistory(deps),
    ]);
    expect(first).toEqual(second);
    expect(first.asOfBlock).toBe((PROTOCOL_DEPLOYMENT_BLOCK + 120n).toString());
    expect(first.revenue.interestFees).toBe("12");
    expect(first.seniorIncome).toBe("108");
    expect(readRange).toHaveBeenCalledTimes(2);
    expect(readRange).toHaveBeenNthCalledWith(1, PROTOCOL_DEPLOYMENT_BLOCK, PROTOCOL_DEPLOYMENT_BLOCK + 100n);
    expect(readRange).toHaveBeenNthCalledWith(2, PROTOCOL_DEPLOYMENT_BLOCK + 101n, PROTOCOL_DEPLOYMENT_BLOCK + 120n);
    expect(getChainId).toHaveBeenCalledTimes(1);

    // Within 60s, returns cached answer without RPC calls.
    clock += 30_000;
    const cached = await loadTransparencyHistory(deps);
    expect(cached).toEqual(first);
    expect(readRange).toHaveBeenCalledTimes(2);

    // After 60s, advances finalized cursor incrementally without rescanning deployment..100.
    clock += 35_000;
    finalized = PROTOCOL_DEPLOYMENT_BLOCK + 130n;
    latest = PROTOCOL_DEPLOYMENT_BLOCK + 140n;
    const refreshed = await loadTransparencyHistory(deps);
    expect(refreshed.asOfBlock).toBe((PROTOCOL_DEPLOYMENT_BLOCK + 140n).toString());
    expect(refreshed.revenue.interestFees).toBe("14");
    expect(refreshed.seniorIncome).toBe("126");
    expect(readRange).toHaveBeenCalledTimes(4);
    expect(readRange).toHaveBeenNthCalledWith(3, PROTOCOL_DEPLOYMENT_BLOCK + 101n, PROTOCOL_DEPLOYMENT_BLOCK + 130n);
    expect(readRange).toHaveBeenNthCalledWith(4, PROTOCOL_DEPLOYMENT_BLOCK + 131n, PROTOCOL_DEPLOYMENT_BLOCK + 140n);
  });

  it("refuses a mismatched archive RPC chain ID", async () => {
    const deps: TransparencyHistoryDeps = {
      now: () => 1_000,
      getChainId: async () => EXPECTED_CHAIN.id + 1,
      getLatestAndFinalizedBlocks: async () => ({
        latest: PROTOCOL_DEPLOYMENT_BLOCK + 10n,
        finalized: PROTOCOL_DEPLOYMENT_BLOCK + 5n,
      }),
      readRange: vi.fn(async () => emptyEvents()),
    };
    await expect(loadTransparencyHistory(deps)).rejects.toThrow(/chain mismatch/i);
  });

  it("hydrates finalized history from the snapshot store on cold start and persists new finalized blocks", async () => {
    let saved: {key: string; cursor: {finalizedBlock: bigint; events: TransparencyEventsBatch}} | null = null;
    const store: TransparencyHistorySnapshotStore = {
      load: vi.fn(async () => ({
        finalizedBlock: PROTOCOL_DEPLOYMENT_BLOCK + 100n,
        events: {
          ...emptyEvents(),
          distributions: [{fee: 10n, toVault: 90n}],
        },
      })),
      save: vi.fn(async (key, cursor) => {
        saved = {key, cursor};
      }),
    };
    const readRange = vi.fn(async (from: bigint, to: bigint) => {
      if (from === PROTOCOL_DEPLOYMENT_BLOCK + 101n && to === PROTOCOL_DEPLOYMENT_BLOCK + 130n) {
        return {...emptyEvents(), distributions: [{fee: 5n, toVault: 45n}]};
      }
      return emptyEvents();
    });
    const deps: TransparencyHistoryDeps = {
      now: () => 10_000,
      getChainId: async () => EXPECTED_CHAIN.id,
      getLatestAndFinalizedBlocks: async () => ({
        latest: PROTOCOL_DEPLOYMENT_BLOCK + 140n,
        finalized: PROTOCOL_DEPLOYMENT_BLOCK + 130n,
      }),
      readRange,
      snapshotStore: store,
      snapshotKey: "test-key",
    };

    const result = await loadTransparencyHistory(deps);
    expect(store.load).toHaveBeenCalledTimes(1);
    // Never rescans deployment..100 because the cold snapshot already covered it.
    expect(readRange).toHaveBeenCalledTimes(2);
    expect(readRange).toHaveBeenNthCalledWith(1, PROTOCOL_DEPLOYMENT_BLOCK + 101n, PROTOCOL_DEPLOYMENT_BLOCK + 130n);
    expect(readRange).toHaveBeenNthCalledWith(2, PROTOCOL_DEPLOYMENT_BLOCK + 131n, PROTOCOL_DEPLOYMENT_BLOCK + 140n);
    expect(result.revenue.interestFees).toBe("15");
    expect(result.seniorIncome).toBe("135");
    expect(store.save).toHaveBeenCalledTimes(1);
    expect(saved).not.toBeNull();
  });

  it("serveTransparencyHistory flags stale fallback with its error when refresh fails inside the 10m window", async () => {
    let clock = 10_000;
    let shouldFail = false;
    const deps: TransparencyHistoryDeps = {
      now: () => clock,
      getChainId: async () => EXPECTED_CHAIN.id,
      getLatestAndFinalizedBlocks: async () => {
        if (shouldFail) throw new Error("archive offline");
        return {
          latest: PROTOCOL_DEPLOYMENT_BLOCK + 20n,
          finalized: PROTOCOL_DEPLOYMENT_BLOCK + 10n,
        };
      },
      readRange: async () => emptyEvents(),
    };

    const fresh = await serveTransparencyHistory(deps);
    expect(fresh.stale).toBe(false);

    clock += 90_000;
    shouldFail = true;
    const stale = await serveTransparencyHistory(deps);
    expect(stale.stale).toBe(true);
    expect(stale.answer).toEqual(fresh.answer);
    if (stale.stale) {
      expect(stale.error).toBeInstanceOf(Error);
    }
  });

  it("does not overwrite a newer Blob snapshot when a lagging RPC replica reports an older finalized block", async () => {
    const store: TransparencyHistorySnapshotStore = {
      load: vi.fn(async () => ({
        finalizedBlock: PROTOCOL_DEPLOYMENT_BLOCK + 500n,
        events: emptyEvents(),
      })),
      save: vi.fn(async () => undefined),
    };
    const deps: TransparencyHistoryDeps = {
      now: () => 10_000,
      getChainId: async () => EXPECTED_CHAIN.id,
      getLatestAndFinalizedBlocks: async () => ({
        latest: PROTOCOL_DEPLOYMENT_BLOCK + 200n,
        finalized: PROTOCOL_DEPLOYMENT_BLOCK + 100n,
      }),
      readRange: async () => emptyEvents(),
      snapshotStore: store,
      snapshotKey: "test-key",
    };
    await loadTransparencyHistory(deps);
    expect(store.load).toHaveBeenCalledTimes(1);
    expect(store.save).not.toHaveBeenCalled();
  });

  it("clears a malformed snapshot on summarization failure instead of wedging the instance", async () => {
    const clear = vi.fn(async () => undefined);
    const store: TransparencyHistorySnapshotStore = {
      load: vi.fn(async () => ({
        finalizedBlock: PROTOCOL_DEPLOYMENT_BLOCK + 100n,
        // Funded tokenId 999 without an Originated event triggers summarizeTransparencyHistory failure.
        events: {...emptyEvents(), funded: [{tokenId: 999n, principal: 1_000n}]},
      })),
      save: vi.fn(async () => undefined),
      clear,
    };
    const deps: TransparencyHistoryDeps = {
      now: () => 10_000,
      getChainId: async () => EXPECTED_CHAIN.id,
      getLatestAndFinalizedBlocks: async () => ({
        latest: PROTOCOL_DEPLOYMENT_BLOCK + 120n,
        finalized: PROTOCOL_DEPLOYMENT_BLOCK + 100n,
      }),
      readRange: async () => emptyEvents(),
      snapshotStore: store,
      snapshotKey: "test-key",
    };

    await expect(loadTransparencyHistory(deps)).rejects.toThrow();
    expect(clear).toHaveBeenCalledTimes(1);

    // Subsequent call rebuilds cleanly from RPC without re-hydrating the poisoned snapshot.
    const recovered = await loadTransparencyHistory(deps);
    expect(recovered.asOfBlock).toBe((PROTOCOL_DEPLOYMENT_BLOCK + 120n).toString());
    expect(store.load).toHaveBeenCalledTimes(1);
  });
});
