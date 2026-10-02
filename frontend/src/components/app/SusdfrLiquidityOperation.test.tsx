import {render, screen, waitFor} from "@testing-library/react";
import {
  encodeAbiParameters,
  encodeEventTopics,
  keccak256,
  maxUint256,
  pad,
  parseAbi,
  parseAbiParameters,
  toHex,
  type Address,
  type Hex,
} from "viem";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

import {SusdfrLiquidityOperation} from "./SusdfrLiquidityOperation";
import {
  LIQUIDITY_OPERATOR,
  PERMIT2,
  USDC,
  V4_POOL_MANAGER,
  V4_POSITION_MANAGER,
} from "@/lib/uniswapV4Liquidity";
import {
  SUSDFR,
  SUSDFR_INITIAL_SQRT_PRICE_X96,
  SUSDFR_INITIAL_TICK,
  SUSDFR_POOL_ID,
  buildSusdfrSeedPlan,
  type SusdfrReceiptLog,
} from "@/lib/uniswapV4SusdfrLiquidity";

const WRONG_WALLET = "0x1111111111111111111111111111111111111111" as Address;
const SEED_HASH = `0x${"34".repeat(32)}` as Hex;
const mockState = vi.hoisted(() => ({
  connectedAddress: "0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337",
  poolSqrtPriceX96: 0n,
  poolTick: 0,
  publicClient: {
    getBlock: vi.fn(async () => ({number: 26_055_708n, timestamp: 1_790_352_500n})),
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
  useAccount: () => ({
    address: mockState.connectedAddress,
    chainId: 1,
    isConnected: true,
  }),
  usePublicClient: () => mockState.publicClient,
  useWalletClient: () => ({data: undefined}),
}));

const TRANSFER_ABI = parseAbi([
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);
const POOL_EVENTS = parseAbi([
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
]);
const ZERO = "0x0000000000000000000000000000000000000000" as Address;

function seedReceiptLogs(): SusdfrReceiptLog[] {
  const plan = buildSusdfrSeedPlan(0n);
  const transfer = (token: Address, amount: bigint): SusdfrReceiptLog => ({
    address: token,
    topics: encodeEventTopics({
      abi: TRANSFER_ABI,
      eventName: "Transfer",
      args: {from: LIQUIDITY_OPERATOR, to: V4_POOL_MANAGER},
    }) as unknown as readonly [Hex, ...Hex[]],
    data: encodeAbiParameters(parseAbiParameters("uint256"), [amount]),
  });
  return [
    {
      address: V4_POOL_MANAGER,
      topics: encodeEventTopics({
        abi: POOL_EVENTS,
        eventName: "Initialize",
        args: {id: SUSDFR_POOL_ID, currency0: USDC, currency1: SUSDFR},
      }) as unknown as readonly [Hex, ...Hex[]],
      data: encodeAbiParameters(
        parseAbiParameters(
          "uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick",
        ),
        [375, 4, ZERO, SUSDFR_INITIAL_SQRT_PRICE_X96, SUSDFR_INITIAL_TICK],
      ),
    },
    {
      address: V4_POSITION_MANAGER,
      topics: [
        keccak256(toHex("Transfer(address,address,uint256)")),
        pad(ZERO, {size: 32}),
        pad(LIQUIDITY_OPERATOR, {size: 32}),
        pad(toHex(991n), {size: 32}),
      ],
      data: "0x",
    },
    {
      address: V4_POOL_MANAGER,
      topics: encodeEventTopics({
        abi: POOL_EVENTS,
        eventName: "ModifyLiquidity",
        args: {id: SUSDFR_POOL_ID, sender: V4_POSITION_MANAGER},
      }) as unknown as readonly [Hex, ...Hex[]],
      data: encodeAbiParameters(
        parseAbiParameters(
          "int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt",
        ),
        [plan.tickLower, plan.tickUpper, plan.liquidity, pad(toHex(1n), {size: 32})],
      ),
    },
    transfer(USDC, plan.expectedUsdc),
    transfer(SUSDFR, plan.expectedSusdfr),
  ];
}

beforeEach(() => {
  mockState.connectedAddress = LIQUIDITY_OPERATOR;
  mockState.poolSqrtPriceX96 = 0n;
  mockState.poolTick = 0;
  mockState.publicClient.getTransactionReceipt.mockReset();
  mockState.publicClient.readContract.mockReset();
  mockState.publicClient.readContract.mockImplementation(
    async ({address, functionName}: {address: string; functionName: string}): Promise<unknown> => {
      if (functionName === "getSlot0") {
        return [mockState.poolSqrtPriceX96, mockState.poolTick, 0, 375] as const;
      }
      if (functionName === "balanceOf") {
        return address.toLowerCase() === USDC.toLowerCase()
          ? 641_012n * 10n ** 6n
          : 437_116n * 10n ** 24n;
      }
      if (functionName === "allowance") {
        return address.toLowerCase() === PERMIT2.toLowerCase()
          ? ([0n, 0, 0] as const)
          : maxUint256;
      }
      if (functionName === "getPositionLiquidity") return buildSusdfrSeedPlan(0n).liquidity;
      if (functionName === "ownerOf") return LIQUIDITY_OPERATOR;
      throw new Error(`Unexpected read ${functionName}`);
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

describe("the USDC/sUSDfr treasury operation", () => {
  it("shows the deterministic seed and keeps the wall locked", async () => {
    render(<SusdfrLiquidityOperation />);
    expect(await screen.findByText("Initialize + 50 USDC seed")).toBeInTheDocument();
    expect(screen.getByText("104.307831")).toBeInTheDocument();
    // The heading is static; the button enables once the balances and allowances have loaded.
    const seed = screen.getByRole("button", {name: /review and initialize seed/i});
    await waitFor(() => expect(seed).toBeEnabled());
    expect(screen.getByText("Complete and verify step 1 first.")).toBeInTheDocument();
  });

  it("refuses every write from a wallet other than the approved treasury", async () => {
    mockState.connectedAddress = WRONG_WALLET;
    render(<SusdfrLiquidityOperation />);
    expect(await screen.findByText(/Wrong wallet connected/i)).toBeInTheDocument();
    expect(screen.getByRole("button", {name: /review and initialize seed/i})).toBeDisabled();
  });

  it("locks an initialized pool when no verified local seed exists", async () => {
    mockState.poolSqrtPriceX96 = SUSDFR_INITIAL_SQRT_PRICE_X96;
    mockState.poolTick = SUSDFR_INITIAL_TICK;
    render(<SusdfrLiquidityOperation />);
    expect(await screen.findByText(/already initialized but this browser has no verified seed receipt/i)).toBeInTheDocument();
    expect(screen.getByRole("button", {name: /review and initialize seed/i})).toBeDisabled();
  });

  it("unlocks the 249,950 USDC wall only after re-verifying the seed receipt", async () => {
    const plan = buildSusdfrSeedPlan(0n);
    mockState.poolSqrtPriceX96 = SUSDFR_INITIAL_SQRT_PRICE_X96;
    mockState.poolTick = SUSDFR_INITIAL_TICK;
    window.localStorage.setItem(
      `frv:uniswap-v4-susdfr-liquidity:v1:seed:${LIQUIDITY_OPERATOR.toLowerCase()}`,
      JSON.stringify({
        version: 1,
        kind: "seed",
        owner: LIQUIDITY_OPERATOR,
        hash: SEED_HASH,
        liquidity: plan.liquidity.toString(),
      }),
    );
    mockState.publicClient.getTransactionReceipt.mockResolvedValue({
      status: "success",
      logs: seedReceiptLogs(),
    });
    render(<SusdfrLiquidityOperation />);

    expect(await screen.findByText(/Position 991 confirmed/i)).toBeInTheDocument();
    await waitFor(() => expect(screen.getAllByText("249,950")).toHaveLength(2));
    expect(screen.getByText("Unlocked")).toBeInTheDocument();
    expect(screen.getByRole("button", {name: /review and submit USDC wall/i})).toBeEnabled();
  });
});
