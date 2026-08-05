import {render, screen} from "@testing-library/react";
import {afterEach, describe, expect, it, vi} from "vitest";
import {StakeCard} from "@/components/app/StakeCard";

/**
 * ADR-0031 dual-NAV disclosure harness.
 *
 * A junior-covered workout can leave queued-exit NAV unimpaired while performance
 * NAV remains below the protocol-wide hurdle. That state is not visible through
 * the ordinary ERC-4626 exit preview, so this test mounts the depositor surface and
 * verifies the separate fee-base warning itself.
 */

const ADDRESS = "0x1111111111111111111111111111111111111111";
let reads: Record<string, unknown> = {};

vi.mock("@/config/contracts", () => ({
  CONTRACTS: {
    USDfr: "0x2222222222222222222222222222222222222222",
    sUSDfr: "0x3333333333333333333333333333333333333333",
  },
  EXPLORER_BASE_URL: null,
  IS_TESTNET: false,
  SUPPORTS_VAULT_FEE_ACCOUNTING: true,
}));

vi.mock("wagmi", () => ({
  useAccount: () => ({address: ADDRESS}),
  useReadContract: ({functionName}: {functionName: string}) => ({
    data: reads[functionName],
    refetch: vi.fn(),
  }),
  useReadContracts: ({
    contracts,
  }: {
    contracts: Array<{functionName: string}>;
  }) => ({
    data: contracts.map(({functionName}) => ({result: reads[functionName]})),
    refetch: vi.fn(),
  }),
}));

vi.mock("@/components/app/useWriteFlow", () => ({
  useWriteFlow: () => ({
    status: {phase: "idle"},
    run: vi.fn(),
    reset: vi.fn(),
    busy: false,
  }),
}));

function baseReads(overrides: Record<string, unknown> = {}) {
  return {
    balanceOf: 1_000n * 10n ** 18n,
    allowance: 0n,
    currentExchangeRate: 10n ** 18n,
    performanceFeeBps: 1_000,
    maxPerformanceFeeBps: 2_000,
    managementFeeBps: 0,
    maxManagementFeeBps: 500,
    highWaterMark: 10n ** 18n,
    feeExchangeRate: 8n * 10n ** 17n,
    impairmentSource: "0x4444444444444444444444444444444444444444",
    pendingSeniorImpairment: 0n,
    // The GROSS mark. Junior capital takes the netted figure above to zero while this — the
    // quantity that actually sizes the deferred fee — stays large. That divergence is the
    // whole point of the disclosure (audit R14-03).
    performanceFeeImpairment: 400_000n * 10n ** 18n,
    // AUDIT R15-01. The hurdle is asset-denominated: ceil(hwm * (totalSupply + 1e6) / 1e24).
    // With hwm = 1e18 and supply = 1e30 that is 1_000_000e18, so realized assets of
    // 1_200_000e18 leave 200_000e18 above the hurdle and a real deferred exposure.
    totalAssets: 1_200_000n * 10n ** 18n,
    totalSupply: 10n ** 30n,
    previewDeposit: undefined,
    previewRedeem: undefined,
    ...overrides,
  };
}

afterEach(() => {
  reads = {};
});

describe("StakeCard — deferred global performance fee", () => {
  it("warns an entrant even when queued-exit impairment is zero", () => {
    reads = baseReads();
    render(<StakeCard writesEnabled />);

    expect(
      screen.getByText(/Global performance-fee exposure is deferred/i),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/exposure can exist even when queued-exit impairment is currently zero/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/Queued exit NAV is currently impaired/i),
    ).not.toBeInTheDocument();
  });

  it("does not warn once the gross mark has cured", () => {
    reads = baseReads({performanceFeeImpairment: 0n});
    render(<StakeCard writesEnabled />);

    expect(
      screen.queryByText(/Global performance-fee exposure is deferred/i),
    ).not.toBeInTheDocument();
  });

  it("AUDIT R15-01: does not warn when the hurdle still sits above realized assets", () => {
    // A large gross mark but NO deferred exposure, because nothing is above the hurdle. This
    // is the state immediately after `markPastDue`, which checkpoints before recording the
    // mark. The superseded gross-mark-only predicate fired here at full strength.
    reads = baseReads({totalAssets: 900_000n * 10n ** 18n});
    render(<StakeCard writesEnabled />);

    expect(
      screen.queryByText(/Global performance-fee exposure is deferred/i),
    ).not.toBeInTheDocument();
  });

  it("AUDIT R15-01: does not assert the rates are ordered when they are equal", () => {
    // The steady state after every profitable checkpoint: the stored hurdle is the Ceil and
    // the reported rate the Floor of the identical rational, so they are equal or one wei
    // apart. The banner must still fire (exposure is real) but must NOT print
    // "below the high-water mark (1 vs 1 USDfr per share)".
    reads = baseReads({feeExchangeRate: 10n ** 18n});
    render(<StakeCard writesEnabled />);

    expect(
      screen.getByText(/Global performance-fee exposure is deferred/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/Performance NAV is currently below the protocol-wide high-water mark/i),
    ).not.toBeInTheDocument();
  });

  it("AUDIT R15-01: ignores the one-wei Floor/Ceil dust gap in the comparison clause", () => {
    reads = baseReads({feeExchangeRate: 10n ** 18n - 1n});
    render(<StakeCard writesEnabled />);

    expect(
      screen.queryByText(/Performance NAV is currently below the protocol-wide high-water mark/i),
    ).not.toBeInTheDocument();
  });

  it("states the ordering only when performance NAV is genuinely below the hurdle", () => {
    reads = baseReads({feeExchangeRate: 8n * 10n ** 17n});
    render(<StakeCard writesEnabled />);

    expect(
      screen.getByText(/Performance NAV is currently below the protocol-wide high-water mark/i),
    ).toBeInTheDocument();
  });

  it("AUDIT R14-03: warns at maximal deferral, where the fee-free runway is exhausted", () => {
    // Runway zero with a live gross mark and assets above the hurdle: the deferred fee is
    // LARGEST here, and per-repayment crystallization makes it the steady state. The
    // superseded gap-based predicate went silent in exactly this state.
    reads = baseReads({feeExchangeRate: 10n ** 18n, performanceFeeImpairment: 400_000n * 10n ** 18n});
    render(<StakeCard writesEnabled />);

    expect(
      screen.getByText(/Global performance-fee exposure is deferred/i),
    ).toBeInTheDocument();
  });
});
