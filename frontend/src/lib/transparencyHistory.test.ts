import {describe, expect, it} from "vitest";
import {
  parseTransparencyHistoryResponse,
  serializeTransparencyHistory,
  summarizeTransparencyHistory,
} from "./transparencyHistory";

describe("transparency history", () => {
  it("joins funded facilities to their class and totals each fee source", () => {
    const history = summarizeTransparencyHistory({
      asOfBlock: 123n,
      classIds: [1, 2],
      originated: [{tokenId: 8n, classId: 2n}],
      funded: [{tokenId: 8n, principal: 1_000n}],
      losses: [{classId: 2n, loss: 125n}],
      originationFees: [{fee: 20n}],
      distributions: [{fee: 4n}, {fee: 6n}],
      performanceFees: [{feeAssets: 3n}],
      managementFees: [{feeAssets: 2n}],
    });

    expect(history.revenue).toEqual({
      originationFees: 20n,
      interestFees: 10n,
      performanceFees: 3n,
      managementFees: 2n,
    });
    expect(history.credit.fundedPrincipal).toBe(1_000n);
    expect(history.credit.netLoss).toBe(125n);
    expect(history.credit.rateBps).toBe(1_250n);
    expect(history.credit.byClass.get(2)?.rateBps).toBe(1_250n);
  });

  it("refuses a funding event whose origination history is missing", () => {
    expect(() => summarizeTransparencyHistory({
      asOfBlock: 123n,
      classIds: [1],
      originated: [],
      funded: [{tokenId: 9n, principal: 1n}],
      losses: [],
      originationFees: [],
      distributions: [],
      performanceFees: [],
      managementFees: [],
    })).toThrow("missing origination for funded facility 9");
  });

  it("round-trips the JSON response without losing bigint precision", () => {
    const history = summarizeTransparencyHistory({
      asOfBlock: 26_024_999n,
      classIds: [1, 2, 3, 4, 5],
      originated: [],
      funded: [],
      losses: [],
      originationFees: [{fee: 10n ** 30n}],
      distributions: [],
      performanceFees: [],
      managementFees: [],
    });
    expect(parseTransparencyHistoryResponse(serializeTransparencyHistory(history))).toEqual(history);
  });
});
