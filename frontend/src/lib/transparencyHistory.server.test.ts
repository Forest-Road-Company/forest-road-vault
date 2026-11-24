import {beforeEach, describe, expect, it, vi} from "vitest";
import {
  loadTransparencyHistory,
  resetTransparencyHistoryCacheForTests,
  type TransparencyEventsBatch,
  type TransparencyHistoryDeps,
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
});
