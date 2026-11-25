// @vitest-environment node
import {beforeAll, describe, expect, it} from "vitest";
import {
  ERC1967_IMPLEMENTATION_SLOT,
  classifyExitFreeze,
  exitFreezeExposure,
  implementationFromSlot,
  isEmptyRevert,
  needsImplementationProbe,
  preExitFreezeImplementations,
} from "./exitFreeze";
import {queueSettlementStatus} from "./queue";
import {
  LEGACY_IMPLEMENTATION_SLOT,
  MAINNET_VAULT,
  RELEASED_IMPLEMENTATION_SLOT,
  readFailures,
} from "@/test/fixtures/contractReadErrors";

type Failures = Awaited<ReturnType<typeof readFailures>>;
let failures: Failures;
beforeAll(async () => {
  failures = await readFailures();
});

const OTHER_VAULT = "0x4761995f4f6daddf7886acd9d16e119ef2fb4132" as const;
const read = (overrides: Partial<Parameters<typeof classifyExitFreeze>[0]> = {}) =>
  classifyExitFreeze({
    chainId: 1,
    vault: MAINNET_VAULT,
    data: undefined,
    error: null,
    implementationSlot: undefined,
    ...overrides,
  });

describe("JO-04: which read failures are a missing selector", () => {
  it("accepts only an empty revert or empty return data, as viem reports each", () => {
    for (const name of ["multicallEmpty", "directEmptyCode3", "directEmptyGeth", "zeroData"] as const) {
      expect([name, isEmptyRevert(failures[name])]).toEqual([name, true]);
    }
  });

  it("refuses transport, proxy, rate-limit and timeout failures and every revert that carries data", () => {
    for (const name of [
      "multicallDecoded", "directDecoded", "directUndecodable", "gethWithReason",
      "proxyUpstreamUnavailable", "proxyRateLimited", "http", "timeout", "plainError",
    ] as const) {
      expect([name, isEmptyRevert(failures[name])]).toEqual([name, false]);
    }
    expect(isEmptyRevert(undefined)).toBe(false);
    expect(isEmptyRevert(null)).toBe(false);
    expect(isEmptyRevert({shortMessage: "execution reverted"})).toBe(false);
  });
});

describe("JO-04: the implementation decides the legacy fallback", () => {
  it("lists exactly the live Ethereum vault's pre-release implementation and nothing elsewhere", () => {
    expect(ERC1967_IMPLEMENTATION_SLOT).toBe("0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");
    expect(preExitFreezeImplementations(1, MAINNET_VAULT)).toEqual(["0x0b78342501d67ec03af1d8e0a60c900bb227d38b"]);
    expect(preExitFreezeImplementations(1, OTHER_VAULT)).toEqual([]);
    expect(preExitFreezeImplementations(11155111, MAINNET_VAULT)).toEqual([]);
    expect(implementationFromSlot(LEGACY_IMPLEMENTATION_SLOT)).toBe("0x0b78342501d67ec03af1d8e0a60c900bb227d38b");
    expect(implementationFromSlot(`0x01${LEGACY_IMPLEMENTATION_SLOT.slice(4)}`)).toBeNull();
    expect(implementationFromSlot("0x1234")).toBeNull();
    expect(implementationFromSlot(undefined)).toBeNull();
  });

  it("a legacy vault's missing selector is the legacy status, and reads as zero exposure", () => {
    for (const name of ["multicallEmpty", "directEmptyCode3", "directEmptyGeth", "zeroData"] as const) {
      expect(needsImplementationProbe(1, MAINNET_VAULT, undefined, failures[name])).toBe(true);
      const state = read({error: failures[name], implementationSlot: LEGACY_IMPLEMENTATION_SLOT});
      expect(state).toEqual({kind: "legacy-vault"});
      expect(exitFreezeExposure(state)).toBe(0n);
    }
  });

  it("the same empty revert on any other implementation (the released vault) stays unavailable", () => {
    const state = read({error: failures.multicallEmpty, implementationSlot: RELEASED_IMPLEMENTATION_SLOT});
    expect(state).toEqual({kind: "unavailable"});
    expect(exitFreezeExposure(state)).toBeUndefined();
    expect(read({error: failures.multicallEmpty, implementationSlot: `0x01${LEGACY_IMPLEMENTATION_SLOT.slice(4)}`}))
      .toEqual({kind: "unavailable"});
  });

  it("waits for the implementation probe instead of guessing", () => {
    expect(read({error: failures.multicallEmpty})).toEqual({kind: "loading"});
  });

  it("a transport or decoded failure never probes and never becomes the legacy status", () => {
    for (const name of ["http", "timeout", "proxyUpstreamUnavailable", "proxyRateLimited", "directDecoded", "multicallDecoded"] as const) {
      expect(needsImplementationProbe(1, MAINNET_VAULT, undefined, failures[name])).toBe(false);
      expect(read({error: failures[name], implementationSlot: LEGACY_IMPLEMENTATION_SLOT})).toEqual({kind: "unavailable"});
    }
  });

  it("another chain or vault keeps the strict behaviour", () => {
    expect(needsImplementationProbe(11155111, MAINNET_VAULT, undefined, failures.multicallEmpty)).toBe(false);
    expect(read({chainId: 11155111, error: failures.multicallEmpty, implementationSlot: LEGACY_IMPLEMENTATION_SLOT}))
      .toEqual({kind: "unavailable"});
    expect(read({vault: OTHER_VAULT, error: failures.multicallEmpty, implementationSlot: LEGACY_IMPLEMENTATION_SLOT}))
      .toEqual({kind: "unavailable"});
  });

  it("uses the vault's successful answer while the latest read has no error", () => {
    expect(read({data: 0n})).toEqual({kind: "vault", exposure: 0n});
    expect(read({data: 7n, implementationSlot: LEGACY_IMPLEMENTATION_SLOT}))
      .toEqual({kind: "vault", exposure: 7n});
    expect(needsImplementationProbe(1, MAINNET_VAULT, 0n, failures.multicallEmpty)).toBe(false);
    expect(read()).toEqual({kind: "loading"});
  });

  it("LC-03: a failed latest refetch makes cached zero and nonzero exposures unavailable", () => {
    for (const data of [0n, 7n]) {
      for (const error of [failures.http, failures.timeout, failures.multicallEmpty]) {
        const state = read({data, error, implementationSlot: LEGACY_IMPLEMENTATION_SLOT});
        expect(state).toEqual({kind: "unavailable"});
        expect(exitFreezeExposure(state)).toBeUndefined();
      }
    }
  });

  it("LC-03: a failed implementation refetch cannot reuse a cached legacy address", () => {
    expect(read({
      error: failures.multicallEmpty,
      implementationSlot: LEGACY_IMPLEMENTATION_SLOT,
      implementationError: failures.http,
    })).toEqual({kind: "unavailable"});
    expect(read({data: 0n, implementationError: failures.http})).toEqual({kind: "vault", exposure: 0n});
  });
});

describe("JO-04: queue settlement status for each exit-freeze state", () => {
  const status = (state: ReturnType<typeof classifyExitFreeze>) =>
    queueSettlementStatus(900n, 10n, 1_000n, 1_000, exitFreezeExposure(state));

  it("legacy vault: the ordinary settlement status, never stuck loading", () => {
    expect(status(read({error: failures.multicallEmpty, implementationSlot: LEGACY_IMPLEMENTATION_SLOT})))
      .toEqual({kind: "settlement-due"});
    expect(queueSettlementStatus(1_500n, 10n, 1_000n, 1_000, exitFreezeExposure(
      read({error: failures.directEmptyCode3, implementationSlot: LEGACY_IMPLEMENTATION_SLOT}),
    ))).toEqual({kind: "epoch-open", secondsRemaining: 500});
  });

  it("released vault, frozen and not frozen", () => {
    expect(status(read({data: 1n}))).toEqual({kind: "exit-frozen"});
    expect(status(read({data: 0n}))).toEqual({kind: "settlement-due"});
  });

  it("a transport failure and a post-release empty revert stay loading, never settlement due", () => {
    expect(status(read({error: failures.http, implementationSlot: LEGACY_IMPLEMENTATION_SLOT}))).toEqual({kind: "loading"});
    expect(status(read({error: failures.timeout}))).toEqual({kind: "loading"});
    expect(status(read({error: failures.multicallEmpty, implementationSlot: RELEASED_IMPLEMENTATION_SLOT})))
      .toEqual({kind: "loading"});
  });
});
