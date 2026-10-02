import {render, screen, waitFor} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {type Address, zeroAddress} from "viem";

import {SusdfrV2LiquidityOperation} from "./SusdfrV2LiquidityOperation";
import {
  LIQUIDITY_OPERATOR,
  SUSDFR,
  USDC,
  V2_FACTORY,
  V2_ROUTER,
  V2_USDC_AMOUNT,
} from "@/lib/uniswapV2SusdfrLiquidity";

const WRONG_WALLET = "0x1111111111111111111111111111111111111111" as Address;
const EXISTING_PAIR = "0x2222222222222222222222222222222222222222" as Address;
const SHARES = 24_831_725_419_194_553_652_032_816_501n;

const mockState = vi.hoisted(() => ({
  connectedAddress: "0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337",
  pair: "0x0000000000000000000000000000000000000000",
  usdcAllowance: 0n,
  susdfrAllowance: 0n,
  publicClient: {
    getBlock: vi.fn(async () => ({number: 26_056_536n, timestamp: 1_790_360_000n})),
    getTransactionReceipt: vi.fn(),
    readContract: vi.fn(),
  },
}));

vi.mock("@/config/contracts", () => ({
  CHAIN_ID: 1,
  CONTRACTS: {
    USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    sUSDfr: "0xAF559d1D59B33ca4b950AB2091372Af8a773E234",
  },
  EXPLORER_BASE_URL: "https://etherscan.io",
}));

vi.mock("@/components/app/ConnectControl", () => ({
  ConnectControl: () => <div>Connected wallet control</div>,
}));

vi.mock("wagmi", () => ({
  useAccount: () => ({address: mockState.connectedAddress, chainId: 1, isConnected: true}),
  usePublicClient: () => mockState.publicClient,
  useWalletClient: () => ({data: undefined}),
}));

beforeEach(() => {
  mockState.connectedAddress = LIQUIDITY_OPERATOR;
  mockState.pair = zeroAddress;
  mockState.usdcAllowance = 0n;
  mockState.susdfrAllowance = 0n;
  mockState.publicClient.getTransactionReceipt.mockReset();
  mockState.publicClient.readContract.mockReset();
  mockState.publicClient.readContract.mockImplementation(
    async ({address, functionName}: {address: string; functionName: string}): Promise<unknown> => {
      if (functionName === "getPair") return mockState.pair;
      if (functionName === "factory") return V2_FACTORY;
      if (functionName === "convertToShares") return SHARES;
      if (functionName === "convertToAssets") return 24_999_999_999_999_999_999_999n;
      if (functionName === "balanceOf") {
        return address.toLowerCase() === USDC.toLowerCase()
          ? 391_012n * 10n ** 6n
          : 437_011n * 10n ** 24n;
      }
      if (functionName === "allowance") {
        return address.toLowerCase() === USDC.toLowerCase()
          ? mockState.usdcAllowance
          : mockState.susdfrAllowance;
      }
      throw new Error(`Unexpected ${address}.${functionName}`);
    },
  );
  const values = new Map<string, string>();
  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: {
      clear: () => values.clear(),
      getItem: (key: string) => values.get(key) ?? null,
      key: (index: number) => [...values.keys()][index] ?? null,
      get length() {
        return values.size;
      },
      removeItem: (key: string) => values.delete(key),
      setItem: (key: string, value: string) => values.set(key, value),
    },
  });
  window.localStorage.clear();
});

afterEach(() => vi.clearAllMocks());

describe("the guarded V2 full-range operation", () => {
  it("shows the exact 25,000 plus 25,000 plan and requires both approvals", async () => {
    render(<SusdfrV2LiquidityOperation />);
    expect(await screen.findByText("$50,000 total opening liquidity")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByText("24,831.725419194553")).toBeInTheDocument());
    expect(screen.getByRole("button", {name: "Approve 25,000 USDC"})).toBeEnabled();
    expect(screen.getByRole("button", {name: "Approve exact sUSDfr"})).toBeEnabled();
    expect(screen.getByRole("button", {name: "Create pair and add liquidity"})).toBeDisabled();
  });

  it("unlocks creation only after both exact allowances cover the live plan", async () => {
    mockState.usdcAllowance = V2_USDC_AMOUNT;
    mockState.susdfrAllowance = SHARES;
    render(<SusdfrV2LiquidityOperation />);
    await waitFor(() =>
      expect(screen.getByRole("button", {name: "Create pair and add liquidity"})).toBeEnabled(),
    );
  });

  it("refuses a connected wallet other than the approved treasury", async () => {
    mockState.connectedAddress = WRONG_WALLET;
    render(<SusdfrV2LiquidityOperation />);
    expect(await screen.findByText(/Wrong wallet connected/i)).toBeInTheDocument();
    expect(screen.getByRole("button", {name: "Create pair and add liquidity"})).toBeDisabled();
  });

  it("locks fresh-pair creation when the canonical factory already has a pair", async () => {
    mockState.pair = EXISTING_PAIR;
    render(<SusdfrV2LiquidityOperation />);
    expect(await screen.findByText(/pair already exists without this browser/i)).toBeInTheDocument();
    expect(screen.getByRole("button", {name: "Approve 25,000 USDC"})).toBeDisabled();
    expect(screen.getByRole("button", {name: "Create pair and add liquidity"})).toBeDisabled();
  });

  it("binds the exact canonical router in the rendered operation", async () => {
    render(<SusdfrV2LiquidityOperation />);
    expect(await screen.findByText(new RegExp(V2_ROUTER.slice(0, 6), "i"))).toBeInTheDocument();
    expect(SUSDFR).toBe("0xAF559d1D59B33ca4b950AB2091372Af8a773E234");
  });
});
