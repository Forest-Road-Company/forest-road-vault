import {describe, expect, it} from "vitest";
import {
  applyShareBasisEvents,
  INITIAL_SHARE_BASIS_STATE,
  walletDirectDepositBasis,
} from "@/lib/yield";

const E18 = 10n ** 18n;
const E24 = 10n ** 24n;

describe("lot-based share basis tracking (H10)", () => {
  it("tracks deposit -> full exit -> fresh deposit at higher NAV without phantom P&L", () => {
    const state = applyShareBasisEvents(INITIAL_SHARE_BASIS_STATE, [
      {kind: "deposit", blockNumber: 10n, logIndex: 0, assets: 100n * E18, shares: 100n * E24},
      {kind: "transfer_out", blockNumber: 20n, logIndex: 0, shares: 100n * E24},
      {kind: "deposit", blockNumber: 30n, logIndex: 0, assets: 105n * E18, shares: 100n * E24},
    ]);
    expect(state.hasExternalShareTransfer).toBe(false);
    expect(walletDirectDepositBasis(state, 100n * E24)).toBe(105n * E18);
  });

  it("reduces basis proportionally on partial exit before a second deposit", () => {
    const state = applyShareBasisEvents(INITIAL_SHARE_BASIS_STATE, [
      {kind: "deposit", blockNumber: 10n, logIndex: 0, assets: 100n * E18, shares: 100n * E24},
      {kind: "transfer_out", blockNumber: 20n, logIndex: 0, shares: 50n * E24},
      {kind: "deposit", blockNumber: 30n, logIndex: 0, assets: 60n * E18, shares: 50n * E24},
    ]);
    expect(walletDirectDepositBasis(state, 100n * E24)).toBe(110n * E18);
  });

  it("withholds basis while externally transferred shares are held and recovers cleanly after full exit", () => {
    const holdingExternal = applyShareBasisEvents(INITIAL_SHARE_BASIS_STATE, [
      {kind: "transfer_in", blockNumber: 10n, logIndex: 0, shares: 10n * E24},
      {kind: "deposit", blockNumber: 20n, logIndex: 0, assets: 50n * E18, shares: 50n * E24},
    ]);
    expect(holdingExternal.hasExternalShareTransfer).toBe(true);
    expect(walletDirectDepositBasis(holdingExternal, 60n * E24)).toBeNull();

    const afterReset = applyShareBasisEvents(holdingExternal, [
      {kind: "transfer_out", blockNumber: 30n, logIndex: 0, shares: 60n * E24},
      {kind: "deposit", blockNumber: 40n, logIndex: 0, assets: 25n * E18, shares: 24n * E24},
    ]);
    expect(afterReset.hasExternalShareTransfer).toBe(false);
    expect(walletDirectDepositBasis(afterReset, 24n * E24)).toBe(25n * E18);
  });

  it("fails closed when tracked shares disagree with live wallet balance", () => {
    const state = applyShareBasisEvents(INITIAL_SHARE_BASIS_STATE, [
      {kind: "deposit", blockNumber: 10n, logIndex: 0, assets: 100n * E18, shares: 100n * E24},
    ]);
    expect(walletDirectDepositBasis(state, 99n * E24)).toBeNull();
  });
});
