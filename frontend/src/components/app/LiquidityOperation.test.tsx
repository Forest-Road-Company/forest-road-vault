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

import {LiquidityOperation} from "./LiquidityOperation";
import {
  LIQUIDITY_OPERATOR,
  POOL_ID,
  TICK_LOWER,
  TICK_UPPER,
  USDC,
  USDFR,
  V4_POOL_MANAGER,
  V4_POSITION_MANAGER,
  buildPilotPlan,
  type ReceiptLog,
} from "@/lib/uniswapV4Liquidity";

const LIVE_SQRT_PRICE = 79_208_251_071_293_499_848_715_422_927_884_420n;
const WRONG_WALLET = "0x1111111111111111111111111111111111111111" as Address;
const PILOT_HASH = `0x${"12".repeat(32)}` as Hex;
const mockState = vi.hoisted(() => {
  const operator = "0x7FDe637d685A5486CCb1B0a8eF658Ad1a08e8337";
  const usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const permit2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
  return {
    connectedAddress: operator,
    publicClient: {
      getBlock: vi.fn(async () => ({
        number: 26_054_266n,
        timestamp: 1_790_337_800n,
      })),
      getTransactionReceipt: vi.fn(),
      readContract: vi.fn(
        async ({address, functionName}: {address: string; functionName: string}): Promise<unknown> => {
          if (functionName === "getSlot0") {
            return [
              79_208_251_071_293_499_848_715_422_927_884_420n,
              276_318,
              409_700,
              375,
            ] as const;
          }
          if (functionName === "balanceOf") {
            return address.toLowerCase() === usdc.toLowerCase()
              ? 980_000n * 10n ** 6n
              : 3_420_651n * 10n ** 18n;
          }
          if (functionName === "allowance") {
            return address.toLowerCase() === permit2.toLowerCase()
              ? ([0n, 0, 0] as const)
              : (1n << 256n) - 1n;
          }
          throw new Error(`Unexpected read ${functionName}`);
        },
      ),
    },
  };
});

vi.mock("@/config/contracts", () => ({
  CHAIN_ID: 1,
  CONTRACTS: {
    USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    USDfr: "0xcC07e7c4E5E35AFFD47b351E420A22C667D7f83d",
  },
  EXPLORER_BASE_URL: "https://etherscan.io",
}));

vi.mock("@/components/app/ConnectControl", () => ({
  ConnectControl: () => <div>Connected wallet control</div>,
}));

const publicClient = mockState.publicClient;

vi.mock("wagmi", () => ({
  useAccount: () => ({
    address: mockState.connectedAddress,
    chainId: 1,
    isConnected: true,
  }),
  usePublicClient: () => publicClient,
  useWalletClient: () => ({data: undefined}),
}));

const TRANSFER_ABI = parseAbi([
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);
const MODIFY_ABI = parseAbi([
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
]);

function receiptLogs(liquidity: bigint): ReceiptLog[] {
  const tokenId = 416_718n;
  const transferTopic = keccak256(toHex("Transfer(address,address,uint256)"));
  const tokenTransfer = (
    token: Address,
    amount: bigint,
  ): ReceiptLog => ({
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
      address: V4_POSITION_MANAGER,
      topics: [
        transferTopic,
        pad("0x0000000000000000000000000000000000000000", {size: 32}),
        pad(LIQUIDITY_OPERATOR, {size: 32}),
        pad(toHex(tokenId), {size: 32}),
      ],
      data: "0x",
    },
    {
      address: V4_POOL_MANAGER,
      topics: encodeEventTopics({
        abi: MODIFY_ABI,
        eventName: "ModifyLiquidity",
        args: {id: POOL_ID, sender: V4_POSITION_MANAGER},
      }) as unknown as readonly [Hex, ...Hex[]],
      data: encodeAbiParameters(
        parseAbiParameters(
          "int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt",
        ),
        [TICK_LOWER, TICK_UPPER, liquidity, pad(toHex(tokenId), {size: 32})],
      ),
    },
    tokenTransfer(USDC, 50_000_000n),
    tokenTransfer(USDFR, 294_996_399_953_492_718_152n),
  ];
}

beforeEach(() => {
  mockState.connectedAddress = LIQUIDITY_OPERATOR;
  publicClient.getTransactionReceipt.mockReset();
  publicClient.readContract.mockClear();
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

afterEach(() => {
  vi.clearAllMocks();
});

describe("the staged liquidity operation", () => {
  it("shows the live 50 USDC pilot and keeps the remainder locked", async () => {
    render(<LiquidityOperation />);

    expect(await screen.findByText("50 USDC pilot")).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByText("294.996399")).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", {name: /review and submit pilot/i})).toBeEnabled();
    expect(screen.getByText("Complete and verify step 1 to prepare this transaction.")).toBeInTheDocument();
    expect(screen.queryByRole("button", {name: /submit remainder/i})).not.toBeInTheDocument();
  });

  it("refuses every write for a wallet other than the approved treasury", async () => {
    mockState.connectedAddress = WRONG_WALLET;
    render(<LiquidityOperation />);

    expect(await screen.findByText(/Wrong wallet connected/i)).toBeInTheDocument();
    expect(screen.getByRole("button", {name: /review and submit pilot/i})).toBeDisabled();
  });

  it("unlocks the remainder only after re-verifying a stored pilot receipt", async () => {
    const plan = buildPilotPlan(LIVE_SQRT_PRICE);
    window.localStorage.setItem(
      `frv:uniswap-v4-liquidity:v1:pilot:${LIQUIDITY_OPERATOR.toLowerCase()}`,
      JSON.stringify({
        version: 1,
        kind: "pilot",
        owner: LIQUIDITY_OPERATOR,
        hash: PILOT_HASH,
        liquidity: plan.liquidity.toString(),
      }),
    );
    publicClient.getTransactionReceipt.mockResolvedValue({
      status: "success",
      logs: receiptLogs(plan.liquidity),
    });
    publicClient.readContract.mockImplementation(
      async ({address, functionName}: {address: string; functionName: string}): Promise<unknown> => {
        if (functionName === "getPositionLiquidity") return plan.liquidity;
        if (functionName === "ownerOf") return LIQUIDITY_OPERATOR;
        if (functionName === "getSlot0") {
          return [LIVE_SQRT_PRICE, 276_318, 409_700, 375] as const;
        }
        if (functionName === "balanceOf") {
          return address.toLowerCase() === USDC.toLowerCase()
            ? 980_000n * 10n ** 6n
            : 3_420_651n * 10n ** 18n;
        }
        if (functionName === "allowance") {
          return address.toLowerCase() ===
            "0x000000000022d473030f116ddee9f6b43ac78ba3"
            ? ([0n, 0, 0] as const)
            : maxUint256;
        }
        throw new Error(`Unexpected read ${functionName}`);
      },
    );

    render(<LiquidityOperation />);

    expect(await screen.findByText(/Position 416718 spent/i)).toBeInTheDocument();
    expect(screen.getByText("Unlocked")).toBeInTheDocument();
    expect(screen.getByRole("button", {name: /review and submit remainder/i})).toBeEnabled();
  });
});
