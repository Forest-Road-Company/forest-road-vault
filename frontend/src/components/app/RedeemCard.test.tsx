import {render, screen, within} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {afterEach, describe, expect, it, vi} from "vitest";
import {RedeemCard} from "@/components/app/RedeemCard";

/**
 * AUDIT FIX (round-9 structural item). Every claim about this card's BEHAVIOUR was
 * previously asserted by searching its own source text — "the request button is disabled
 * until the cooldown loads" was a grep for `disabled={`. Reviewers independently sketched
 * edits that keep those literals while restoring the published defect.
 *
 * These tests mount the component and assert what a user can actually see and do. They pin
 * FRV-FS-02 (the 21-day hold must be disclosed before an irrevocable, non-cancellable
 * queue entry) and RC-05 (a control that resets an in-flight write must be unavailable
 * while that write is in flight).
 */

const DAY = 86_400;
const COOLDOWN = BigInt(21 * DAY);
const NOW = 1_800_000_000;

type FlowStub = {status: {phase: string}; run: ReturnType<typeof vi.fn>; reset: ReturnType<typeof vi.fn>; busy: boolean};

const flows: FlowStub[] = [];
let busyFlows = false;

function makeFlow(): FlowStub {
  return {status: {phase: "idle"}, run: vi.fn(), reset: vi.fn(), busy: busyFlows};
}

/** Values the card reads from chain, keyed by the contract function it calls. */
let reads: Record<string, unknown> = {};

vi.mock("wagmi", () => ({
  useAccount: () => ({address: "0x1111111111111111111111111111111111111111"}),
  useReadContract: ({functionName}: {functionName: string}) => ({
    data: reads[functionName],
    refetch: vi.fn(),
  }),
  useReadContracts: () => ({data: reads.__positions ?? [], refetch: vi.fn()}),
  useWatchContractEvent: () => undefined,
}));

vi.mock("@/components/app/useWriteFlow", () => ({
  useWriteFlow: () => {
    const f = makeFlow();
    flows.push(f);
    return f;
  },
}));

vi.mock("@/components/app/useNowSeconds", () => ({useNowSeconds: () => NOW}));

function baseReads(overrides: Record<string, unknown> = {}) {
  return {
    balanceOf: 1_000n * 10n ** 18n,
    allowance: 0n,
    epochEndsAt: BigInt(NOW + 3600), // ~1h — the misleadingly short signal
    isSettling: false,
    totalRequests: 0n,
    redeemCooldown: COOLDOWN,
    previewRedeem: 0n,
    convertToAssets: 0n,
    __positions: [],
    ...overrides,
  };
}

async function openQueueMode(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("button", {name: "sUSDfr"}));
}

afterEach(() => {
  flows.length = 0;
  busyFlows = false;
});

describe("RedeemCard — queue disclosure (FRV-FS-02)", () => {
  it("discloses the live minimum hold, not just the epoch countdown", async () => {
    reads = baseReads();
    const user = userEvent.setup();
    render(<RedeemCard writesEnabled chainOk />);
    await openQueueMode(user);

    // The hold must be stated in its own right. Before the fix the only time signal was
    // the sub-24h epoch countdown, which understates the commitment by weeks.
    expect(screen.getByText(/Minimum hold before eligibility/i)).toBeInTheDocument();
    expect(screen.getByText(/21d/)).toBeInTheDocument();
  });

  it("reads the hold from chain rather than hardcoding it", async () => {
    // A governance change to 7 days must be reflected; a literal would not move.
    reads = baseReads({redeemCooldown: BigInt(7 * DAY)});
    const user = userEvent.setup();
    render(<RedeemCard writesEnabled chainOk />);
    await openQueueMode(user);

    expect(screen.getByText(/7d/)).toBeInTheDocument();
    expect(screen.queryByText(/21d/)).not.toBeInTheDocument();
  });

  it("blocks the request until the on-chain hold has loaded", async () => {
    reads = baseReads({redeemCooldown: undefined});
    const user = userEvent.setup();
    render(<RedeemCard writesEnabled chainOk />);
    await openQueueMode(user);

    // Neither the acknowledgement nor the action may be reachable while the hold is
    // unknown — signing without the term displayed is the defect.
    expect(screen.getByRole("checkbox")).toBeDisabled();
    expect(screen.getByRole("button", {name: /Request redemption/i})).toBeDisabled();
  });

  it("requires the non-cancellable acknowledgement before the request is submittable", async () => {
    // Allowance must already cover the amount, otherwise the primary action is "Approve",
    // which the acknowledgement deliberately does NOT gate — approving is not the
    // irrevocable step. The gate applies to the request itself.
    reads = baseReads({allowance: 10n ** 30n});
    const user = userEvent.setup();
    render(<RedeemCard writesEnabled chainOk />);
    await openQueueMode(user);

    // Two text inputs exist (amount, and the request-ID lookup) — target the amount one.
    const amount = screen.getByPlaceholderText("0.00");
    await user.type(amount, "100");

    const submit = screen.getByRole("button", {name: /Request redemption/i});
    expect(submit).toBeDisabled();

    await user.click(screen.getByRole("checkbox"));
    expect(submit).toBeEnabled();
  });

  it("states that the entry cannot be cancelled or withdrawn", async () => {
    reads = baseReads();
    const user = userEvent.setup();
    render(<RedeemCard writesEnabled chainOk />);
    await openQueueMode(user);

    expect(
      screen.getByText(/cannot be cancelled or withdrawn/i),
    ).toBeInTheDocument();
  });
});

describe("RedeemCard — per-position eligibility (FRV-FS-02)", () => {
  it("renders each position's first eligibility from its own request timestamp", async () => {
    // Requested 20 days ago against a 21-day hold → one day left, per position.
    const requestedAt = BigInt(NOW - 20 * DAY);
    reads = baseReads({
      totalRequests: 1n,
      __positions: [
        {
          result: [
            "0x1111111111111111111111111111111111111111",
            5n * 10n ** 24n, // sharesRemaining
            0n, // assetsClaimable
            0n, // epochRequested
            requestedAt,
          ],
        },
      ],
    });
    const user = userEvent.setup();
    render(<RedeemCard writesEnabled chainOk />);
    await openQueueMode(user);

    const positions = screen.getByText(/Your queue positions/i).parentElement!;
    expect(within(positions).getByText(/First eligible in/i)).toBeInTheDocument();
    expect(within(positions).getByText(/1d/)).toBeInTheDocument();
  });
});

describe("RedeemCard — in-flight write protection (RC-05)", () => {
  it("disables the mode toggle while a write is in flight", async () => {
    reads = baseReads();
    busyFlows = true;
    render(<RedeemCard writesEnabled chainOk />);

    // Switching mode resets both flows; doing that mid-write orphaned the transaction so
    // its outcome never surfaced.
    expect(screen.getByRole("button", {name: "USDfr"})).toBeDisabled();
    expect(screen.getByRole("button", {name: "sUSDfr"})).toBeDisabled();
  });

  it("leaves the mode toggle usable when nothing is in flight", async () => {
    reads = baseReads();
    render(<RedeemCard writesEnabled chainOk />);

    expect(screen.getByRole("button", {name: "sUSDfr"})).toBeEnabled();
  });
});
