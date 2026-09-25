import {describe, expect, it} from "vitest";
import {queueSettlementStatus} from "./queue";

describe("queue settlement status", () => {
  it("reports the independent head cooldown after the epoch has ended", () => {
    expect(queueSettlementStatus(900n, 10n, 1_500n, 1_000)).toEqual({
      kind: "head-cooldown",
      secondsRemaining: 500,
    });
  });

  it("reports settlement due only when both clocks have elapsed", () => {
    expect(queueSettlementStatus(900n, 10n, 1_000n, 1_000)).toEqual({kind: "settlement-due"});
  });

  it("does not suggest a keeper transaction for an empty expired epoch", () => {
    expect(queueSettlementStatus(900n, 0n, undefined, 1_000)).toEqual({kind: "queue-empty"});
  });
});
