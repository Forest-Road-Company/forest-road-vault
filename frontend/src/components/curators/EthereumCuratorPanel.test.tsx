import {cleanup, fireEvent, render, screen, waitFor, within} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {EthereumCuratorPanel} from "@/components/curators/EthereumCuratorPanel";

const UNIT = 10n ** 18n;
const ADDRESS = "0x1111111111111111111111111111111111111111";
const harness = vi.hoisted(() => ({
  run: vi.fn(),
  paused: false,
  custodyFrozen: false,
  failedReads: new Set<string>(),
  classes: Array.from({length: 5}, () => ({
    approved: false,
    posted: 0n,
    pool: 1_000n * 10n ** 18n,
    required: 0n,
    headroom: 1_000n * 10n ** 18n,
    unresolvedDefaults: 0n,
  })),
}));

vi.mock("@/config/contracts", () => ({
  CONTRACTS: {
    CuratorModule: "0x2222222222222222222222222222222222222222",
    USDfr: "0x3333333333333333333333333333333333333333",
    CollateralRegistry: "0x4444444444444444444444444444444444444444",
  },
  EXPLORER_BASE_URL: null,
  IS_TESTNET: false,
  NETWORK_NAME: "Local fixture",
}));

vi.mock("@/lib/wagmi", () => ({EXPECTED_CHAIN: {id: 11155111}}));
vi.mock("@/components/app/ConnectControl", () => ({ConnectControl: () => <span>Test curator</span>}));
vi.mock("@/components/app/NetworkBanner", () => ({NetworkBanner: () => <span>Wrong network</span>}));
vi.mock("@/components/app/useWriteFlow", () => ({
  useWriteFlow: () => ({
    status: {phase: "idle"},
    run: harness.run,
    reset: vi.fn(),
    busy: false,
  }),
}));

vi.mock("wagmi", () => ({
  useAccount: () => ({address: ADDRESS, isConnected: true, chainId: 11155111}),
  useReadContracts: ({contracts}: {contracts: Array<{functionName: string; args?: readonly unknown[]}>}) => ({
    data: contracts.map(({functionName, args}) => {
      if (harness.failedReads.has(functionName)) return {status: "failure", error: new Error("read failed")};
      const classIndex = typeof args?.[0] === "bigint" ? Number(args[0]) - 1 : 0;
      const row = harness.classes[classIndex];
      let result: unknown = 0n;
      if (functionName === "paused") result = harness.paused;
      else if (functionName === "custodyFreezeActive") result = harness.custodyFrozen;
      else if (functionName === "balanceOf") result = 1_000n * UNIT;
      else if (functionName === "allowance") result = 1_000n * UNIT;
      else if (functionName === "isApprovedCurator") result = row.approved;
      else if (functionName === "postedOf") result = row.posted;
      else if (functionName === "poolBalance") result = row.pool;
      else if (functionName === "requiredFirstLoss") result = row.required;
      else if (functionName === "headroom") result = row.headroom;
      else if (functionName === "unresolvedDefaults") result = row.unresolvedDefaults;
      else if (functionName === "classParams") result = {name: `Class ${classIndex + 1}`};
      return {status: "success", result};
    }),
    isError: harness.failedReads.size > 0,
    refetch: vi.fn(),
  }),
}));

function setClass(classId: number, values: Partial<(typeof harness.classes)[number]>) {
  Object.assign(harness.classes[classId - 1], values);
}

beforeEach(() => {
  harness.run.mockReset();
  harness.paused = false;
  harness.custodyFrozen = false;
  harness.failedReads.clear();
  harness.classes.forEach((row) => Object.assign(row, {
    approved: false,
    posted: 0n,
    pool: 1_000n * UNIT,
    required: 0n,
    headroom: 1_000n * UNIT,
    unresolvedDefaults: 0n,
  }));
});

afterEach(cleanup);

describe("Ethereum curator approval revocation", () => {
  it("keeps an existing revoked position visible and withdrawable while blocking new postings", async () => {
    setClass(1, {approved: false, posted: 100n * UNIT});
    render(<EthereumCuratorPanel />);

    expect(await screen.findByText(/approval for new postings in this class has been withdrawn/i)).toBeInTheDocument();
    expect(screen.getByText("Posting unavailable").closest("button")).toBeDisabled();

    fireEvent.change(screen.getByLabelText("Amount in USDfr"), {target: {value: "1"}});
    const withdraw = screen.getByRole("button", {name: "Withdraw"});
    expect(withdraw).toBeEnabled();
    fireEvent.click(withdraw);

    expect(harness.run).toHaveBeenCalledOnce();
    expect(harness.run).toHaveBeenCalledWith(expect.objectContaining({
      functionName: "withdrawFirstLoss",
      args: [1n, UNIT],
    }));
  });

  it("shows revoked and approved classes together and gates posting per selected class", async () => {
    setClass(1, {approved: false, posted: 100n * UNIT});
    setClass(2, {approved: true, posted: 50n * UNIT});
    render(<EthereumCuratorPanel />);

    const classes = await screen.findByRole("combobox", {name: "Class"});
    expect(classes).toHaveValue("2");
    expect(screen.getByRole("button", {name: "Post first-loss capital"})).toBeDisabled();

    fireEvent.change(screen.getByLabelText("Amount in USDfr"), {target: {value: "1"}});
    expect(screen.getByRole("button", {name: "Post first-loss capital"})).toBeEnabled();

    fireEvent.change(classes, {target: {value: "1"}});
    expect(screen.getByRole("button", {name: "Posting unavailable"})).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Amount in USDfr"), {target: {value: "1"}});
    expect(screen.getByRole("button", {name: "Withdraw"})).toBeEnabled();
  });

  it("restores posting controls when governance re-approves the class", async () => {
    setClass(1, {approved: true, posted: 100n * UNIT});
    render(<EthereumCuratorPanel />);

    fireEvent.change(await screen.findByLabelText("Amount in USDfr"), {target: {value: "1"}});
    expect(screen.getByRole("button", {name: "Post first-loss capital"})).toBeEnabled();
    expect(screen.queryByText(/approval for new postings in this class has been withdrawn/i)).not.toBeInTheDocument();
  });

  it("keeps a settlement path for an old revoked position whose conservative quote is zero", async () => {
    render(<EthereumCuratorPanel />);

    const classes = await screen.findByRole("combobox", {name: "Prior position class"});
    fireEvent.change(classes, {target: {value: "3"}});
    fireEvent.click(screen.getByRole("button", {name: "Settle prior position"}));

    expect(harness.run).toHaveBeenCalledOnce();
    expect(harness.run).toHaveBeenCalledWith(expect.objectContaining({
      functionName: "claimClosedRound",
      args: [3n, ADDRESS],
    }));
  });

  it("does not expose posting or withdrawal controls to a never-approved wallet with no stake", async () => {
    render(<EthereumCuratorPanel />);

    expect(await screen.findByText(/not approved as a curator in any collateral class/i)).toBeInTheDocument();
    expect(screen.queryByRole("button", {name: "Withdraw"})).not.toBeInTheDocument();
    expect(screen.queryByRole("button", {name: "Post first-loss capital"})).not.toBeInTheDocument();
  });

  it("does not retarget a write when the selected class disappears", async () => {
    setClass(1, {approved: true, posted: 100n * UNIT});
    setClass(2, {approved: true, posted: 100n * UNIT});
    const {rerender} = render(<EthereumCuratorPanel />);

    const classes = await screen.findByRole("combobox", {name: "Class"});
    await waitFor(() => expect(classes).toHaveValue("1"));
    fireEvent.change(classes, {target: {value: "2"}});
    fireEvent.change(screen.getByLabelText("Amount in USDfr"), {target: {value: "1"}});

    setClass(2, {approved: false, posted: 0n});
    rerender(<EthereumCuratorPanel />);

    expect(await screen.findByRole("alert", {name: ""})).toHaveTextContent(/selected class is no longer available/i);
    expect(screen.getByRole("combobox", {name: "Class"})).toHaveValue("");
    expect(screen.getByRole("button", {name: "Posting unavailable"})).toBeDisabled();
    expect(screen.getByRole("button", {name: "Withdraw"})).toBeDisabled();
    expect(harness.run).not.toHaveBeenCalled();
  });

  it("binds the initial default so its disappearance cannot retarget a write", async () => {
    setClass(1, {approved: true, posted: 100n * UNIT});
    setClass(2, {approved: true, posted: 100n * UNIT});
    const {rerender} = render(<EthereumCuratorPanel />);

    const classes = await screen.findByRole("combobox", {name: "Class"});
    await waitFor(() => expect(classes).toHaveValue("1"));
    fireEvent.change(screen.getByLabelText("Amount in USDfr"), {target: {value: "1"}});

    // No manual class selection occurred. The first rendered default still became the wallet's
    // explicit selection, so removing it must not fall through to class 2.
    setClass(1, {approved: false, posted: 0n});
    rerender(<EthereumCuratorPanel />);

    expect(await screen.findByRole("alert", {name: ""})).toHaveTextContent(/selected class is no longer available/i);
    expect(screen.getByRole("combobox", {name: "Class"})).toHaveValue("");
    expect(screen.getByRole("button", {name: "Posting unavailable"})).toBeDisabled();
    expect(screen.getByRole("button", {name: "Withdraw"})).toBeDisabled();
    expect(harness.run).not.toHaveBeenCalled();
  });

  it("fails closed when any financial class read fails", async () => {
    setClass(1, {approved: true, posted: 100n * UNIT});
    harness.failedReads.add("headroom");
    render(<EthereumCuratorPanel />);

    expect(await screen.findByRole("alert")).toHaveTextContent(/module could not be read/i);
    expect(screen.queryByRole("button", {name: "Withdraw"})).not.toBeInTheDocument();
  });

  it("quotes zero withdrawable while either global exit interlock is active", async () => {
    setClass(1, {approved: true, posted: 100n * UNIT, headroom: 100n * UNIT});
    harness.custodyFrozen = true;
    const {rerender} = render(<EthereumCuratorPanel />);
    let row = await screen.findByRole("row", {name: /Class 1/});
    expect(within(row).getAllByRole("cell").at(-1)).toHaveTextContent("0 USDfr");

    harness.custodyFrozen = false;
    harness.paused = true;
    rerender(<EthereumCuratorPanel />);
    row = await screen.findByRole("row", {name: /Class 1/});
    expect(within(row).getAllByRole("cell").at(-1)).toHaveTextContent("0 USDfr");
    expect(screen.getByRole("button", {name: "Withdraw"})).toBeDisabled();
  });
});
