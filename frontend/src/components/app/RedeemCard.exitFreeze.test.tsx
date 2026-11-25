import {render, screen, within} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {afterEach, beforeAll, describe, expect, it, vi} from "vitest";
import {RedeemCard} from "@/components/app/RedeemCard";
import {
  LEGACY_IMPLEMENTATION_SLOT,
  MAINNET_VAULT,
  RELEASED_IMPLEMENTATION_SLOT,
  readFailures,
} from "@/test/fixtures/contractReadErrors";

/**
 * Audit JO-04: the site deploys from main weeks before the release can execute, while the live
 * vault has no `unresolvedPastDueExposure()`. These tests mount the card as on Ethereum against the
 * live vault proxy and drive the exposure read and the ERC-1967 implementation probe with the
 * errors viem really builds.
 */

const DAY = 86_400;
const NOW = 1_800_000_000;

vi.mock("@/config/contracts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/config/contracts")>();
  return {...actual, CHAIN_ID: 1, CONTRACTS: {...actual.CONTRACTS, sUSDfr: "0xAF559d1D59B33ca4b950AB2091372Af8a773E234"}};
});

let reads: Record<string, unknown> = {};
let errors: Record<string, unknown> = {};
let implementationSlot: unknown;
let implementationError: unknown;
const probes: {enabled: unknown; address: unknown; slot: unknown}[] = [];

vi.mock("wagmi", () => ({
  useAccount: () => ({address: "0x1111111111111111111111111111111111111111"}),
  usePublicClient: () => ({
    getBlock: vi.fn(async () => ({timestamp: BigInt(NOW)})),
    getBlockNumber: vi.fn(async () => 100n),
    getContractEvents: vi.fn(async () => []),
  }),
  useReadContract: ({functionName}: {functionName: string}) => ({
    data: reads[functionName],
    error: errors[functionName] ?? null,
    refetch: vi.fn(),
  }),
  useReadContracts: () => ({data: reads.__positions ?? [], refetch: vi.fn()}),
  useWatchContractEvent: () => undefined,
  useStorageAt: ({address, slot, query}: {address: unknown; slot: unknown; query?: {enabled?: unknown}}) => {
    probes.push({enabled: query?.enabled, address, slot});
    return {data: query?.enabled ? implementationSlot : undefined, error: query?.enabled ? implementationError : undefined};
  },
}));

vi.mock("@/components/app/useWriteFlow", () => ({
  useWriteFlow: () => ({status: {phase: "idle"}, run: vi.fn(), reset: vi.fn(), busy: false}),
}));
vi.mock("@/components/app/useNowSeconds", () => ({useNowSeconds: () => NOW}));

type Failures = Awaited<ReturnType<typeof readFailures>>;
let failures: Failures;
beforeAll(async () => {
  failures = await readFailures();
});

/** An open heartbeat and one matured request, so both status lines render. */
function queueState(overrides: Record<string, unknown> = {}) {
  return {
    balanceOf: 1_000n * 10n ** 18n,
    allowance: 0n,
    epochEndsAt: BigInt(NOW - 1),
    isSettling: false,
    unresolvedPastDueExposure: undefined,
    totalRequests: 1n,
    redeemCooldown: BigInt(21 * DAY),
    previewRedeem: 0n,
    convertToAssets: 0n,
    __positions: [{result: ["0x1111111111111111111111111111111111111111", 5n * 10n ** 24n, 0n, 0n, BigInt(NOW - 22 * DAY)]}],
    ...overrides,
  };
}

async function mountQueue() {
  const user = userEvent.setup();
  render(<RedeemCard writesEnabled chainOk />);
  await user.click(screen.getByRole("button", {name: "sUSDfr"}));
  return screen.getByText(/Your queue positions/i).parentElement!;
}

afterEach(() => {
  reads = {};
  errors = {};
  implementationSlot = undefined;
  implementationError = undefined;
  probes.length = 0;
});

describe("RedeemCard on the pre-release vault (JO-04)", () => {
  it("LC-03: an open status becomes unavailable on refetch failure, then frozen after recovery", async () => {
    reads = queueState({unresolvedPastDueExposure: 0n});
    const user = userEvent.setup();
    const view = render(<RedeemCard writesEnabled chainOk />);
    await user.click(screen.getByRole("button", {name: "sUSDfr"}));
    expect(screen.getByText(/eligible requests settle as their hold ends/)).toBeInTheDocument();
    errors = {unresolvedPastDueExposure: failures.http};
    view.rerender(<RedeemCard writesEnabled chainOk />);
    expect(screen.queryByText(/eligible requests settle as their hold ends/)).not.toBeInTheDocument();
    expect(screen.getByText("Cooldown complete · settlement availability unavailable")).toBeInTheDocument();
    errors = {};
    reads.unresolvedPastDueExposure = 7n;
    view.rerender(<RedeemCard writesEnabled chainOk />);
    expect(screen.getByText("Waiting for verified loan resolution · settlement paused")).toBeInTheDocument();
  });

  it("LC-03: a cached legacy implementation is unavailable when its probe refetch fails", async () => {
    reads = queueState();
    errors = {unresolvedPastDueExposure: failures.multicallEmpty};
    implementationSlot = LEGACY_IMPLEMENTATION_SLOT;
    implementationError = failures.http;
    await mountQueue();
    expect(screen.queryByText(/eligible requests settle as their hold ends/)).not.toBeInTheDocument();
    expect(screen.getByText("Cooldown complete · settlement availability unavailable")).toBeInTheDocument();
  });

  it("shows the ordinary heartbeat on the reviewed pre-freeze implementation instead of loading forever", async () => {
    reads = queueState();
    errors = {unresolvedPastDueExposure: failures.multicallEmpty};
    implementationSlot = LEGACY_IMPLEMENTATION_SLOT;
    const positions = await mountQueue();
    expect(screen.queryByText(/Settlement availability is being checked/)).not.toBeInTheDocument();
    expect(screen.queryByText(/Settlement paused until a verified cure/)).not.toBeInTheDocument();
    expect(screen.getByText(/eligible requests settle as their hold ends/)).toBeInTheDocument();
    expect(within(positions).getByText("Cooldown complete · awaiting FIFO settlement and liquidity")).toBeInTheDocument();
    expect(probes.some((probe) => probe.enabled === true && probe.address === MAINNET_VAULT &&
      probe.slot === "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")).toBe(true);
  });

  it("stays unavailable when the same empty revert comes from any other implementation", async () => {
    reads = queueState();
    errors = {unresolvedPastDueExposure: failures.multicallEmpty};
    implementationSlot = RELEASED_IMPLEMENTATION_SLOT;
    const positions = await mountQueue();
    expect(screen.getByText(/Settlement availability is being checked/)).toBeInTheDocument();
    expect(screen.queryByText(/eligible requests settle as their hold ends/)).not.toBeInTheDocument();
    expect(within(positions).getByText("Cooldown complete · settlement availability unavailable")).toBeInTheDocument();
  });

  it("a transport failure stays unavailable and never probes the implementation", async () => {
    reads = queueState();
    errors = {unresolvedPastDueExposure: failures.http};
    implementationSlot = LEGACY_IMPLEMENTATION_SLOT;
    const positions = await mountQueue();
    expect(screen.getByText(/Settlement availability is being checked/)).toBeInTheDocument();
    expect(within(positions).getByText("Cooldown complete · settlement availability unavailable")).toBeInTheDocument();
    expect(probes.length).toBeGreaterThan(0);
    expect(probes.every((probe) => probe.enabled === false)).toBe(true);
  });

  it("the released vault's own answer is used and costs no probe", async () => {
    reads = queueState({unresolvedPastDueExposure: 5n});
    implementationSlot = LEGACY_IMPLEMENTATION_SLOT;
    const positions = await mountQueue();
    expect(screen.getByText(/Settlement paused until a verified cure/)).toBeInTheDocument();
    expect(within(positions).getByText("Waiting for verified loan resolution · settlement paused")).toBeInTheDocument();
    expect(probes.every((probe) => probe.enabled === false)).toBe(true);
  });
});
