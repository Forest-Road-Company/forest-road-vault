import {render, screen} from "@testing-library/react";
import {afterEach, beforeAll, describe, expect, it, vi} from "vitest";
import {TransparencyDashboard} from "@/components/app/TransparencyDashboard";
import {
  LEGACY_IMPLEMENTATION_SLOT,
  RELEASED_IMPLEMENTATION_SLOT,
  readFailures,
} from "@/test/fixtures/contractReadErrors";

/** Audit JO-04: the dashboard's redemption-queue status on the pre-release and released vault. */

const NOW = 1_800_000_000;

vi.mock("@/config/contracts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/config/contracts")>();
  return {...actual, CHAIN_ID: 1, CONTRACTS: {...actual.CONTRACTS, sUSDfr: "0xAF559d1D59B33ca4b950AB2091372Af8a773E234"}};
});

let exposure: bigint | undefined;
let exposureError: unknown = null;
let implementationSlot: unknown;

/** The headline multicall: an open epoch (ends in one hour) with one queued request at the head. */
function headline() {
  const rows: unknown[] = Array.from({length: 32}, () => ({status: "success", result: undefined}));
  rows[11] = {status: "success", result: 3n};
  rows[12] = {status: "success", result: BigInt(NOW + 3_600)};
  rows[13] = {status: "success", result: 10n ** 24n};
  rows[15] = {status: "success", result: 1n};
  rows[16] = {status: "success", result: 0n};
  rows[31] = {status: "success", result: false};
  return rows;
}

vi.mock("wagmi", () => ({
  useBlockNumber: () => ({data: undefined}),
  useReadContracts: ({contracts}: {contracts: unknown[]}) => ({data: contracts.length === 32 ? headline() : undefined}),
  useReadContract: ({functionName}: {functionName: string}) =>
    functionName === "unresolvedPastDueExposure"
      ? {data: exposure, error: exposureError}
      : {data: undefined, error: null},
  useStorageAt: ({query}: {query?: {enabled?: unknown}}) => ({data: query?.enabled ? implementationSlot : undefined}),
}));
vi.mock("@/components/app/useBookEconomics", () => ({useBookEconomics: () => ({metrics: undefined})}));
vi.mock("@/components/app/useCollateralValue", () => ({useCollateralValue: () => ({metrics: undefined})}));
vi.mock("@/components/app/useNowSeconds", () => ({useNowSeconds: () => NOW}));

type Failures = Awaited<ReturnType<typeof readFailures>>;
let failures: Failures;
beforeAll(async () => {
  failures = await readFailures();
});

afterEach(() => {
  exposure = undefined;
  exposureError = null;
  implementationSlot = undefined;
});

const status = () => screen.getByText("Settlement status").nextElementSibling?.textContent;

describe("TransparencyDashboard settlement status (JO-04)", () => {
  it("LC-03: cached zero exposure does not show an open epoch after the latest read failed", () => {
    exposure = 0n;
    exposureError = failures.http;
    render(<TransparencyDashboard />);
    expect(status()).toBe("–");
  });
  it("the pre-release vault shows the epoch countdown, not a permanent dash", () => {
    exposureError = failures.multicallEmpty;
    implementationSlot = LEGACY_IMPLEMENTATION_SLOT;
    render(<TransparencyDashboard />);
    expect(status()).toBe("ends in 1h 0m");
  });

  it("an empty revert from any other implementation, or a transport failure, shows no status", () => {
    exposureError = failures.multicallEmpty;
    implementationSlot = RELEASED_IMPLEMENTATION_SLOT;
    const {unmount} = render(<TransparencyDashboard />);
    expect(status()).toBe("–");
    unmount();
    exposureError = failures.timeout;
    implementationSlot = LEGACY_IMPLEMENTATION_SLOT;
    render(<TransparencyDashboard />);
    expect(status()).toBe("–");
  });

  it("the released vault's freeze is shown", () => {
    exposure = 2n;
    render(<TransparencyDashboard />);
    expect(status()).toBe("settlement paused · awaiting verified loan resolution");
  });
});
