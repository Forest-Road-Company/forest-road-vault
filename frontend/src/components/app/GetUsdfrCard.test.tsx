import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {act, cleanup, render, screen, waitFor, within} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  BaseError,
  RawContractError,
  decodeFunctionData,
  encodeErrorResult,
  encodeFunctionResult,
  maxUint256,
  type Hex,
} from "viem";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

import {GetUsdfrCard} from "@/components/app/GetUsdfrCard";
import {PERMIT2, USDC, USDFR} from "@/lib/uniswapV4Liquidity";
import {
  SWAP_ROUTE_ERRORS,
  UNIVERSAL_ROUTER,
  UNIVERSAL_ROUTER_ABI,
  V4_QUOTER_ABI,
  buildPermitSingle,
  decodePermit2PermitInput,
  decodeV4SwapInput,
  permit2ApprovalRequest,
  permitTypedData,
} from "@/lib/uniswapV4Swap";

/**
 * The Get USDfr card as a visitor meets it: which tab opens, what a testnet shows, how the tabs
 * work from the keyboard, what the Buy tab says about a quote, and what it hands the shared
 * write flow. The wallet, the chain reads and the write flow are stubbed; the encoding module is
 * real, so the arguments asserted below are the bytes the router would receive.
 */

const BUYER = "0x1111111111111111111111111111111111111111" as const;
const POOL_URL =
  "https://app.uniswap.org/explore/pools/ethereum/0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55";
const BLOCK_TIMESTAMP = 1_790_882_195n;
const USD = 10n ** 6n;
/** USDC's allowance to Permit2 after the one-time maximum approval and a first 1,000 USDC buy. */
const AFTER_FIRST_BUY = maxUint256 - 1_000n * USD;

const harness = vi.hoisted(() => ({
  testnet: false,
  address: "0x1111111111111111111111111111111111111111" as `0x${string}` | undefined,
  /** USDfr base units paid per USDC base unit, as numerator over 10^12 (999 is 0.999 USDfr/USDC). */
  rateMilli: 999n,
  quoteError: null as Error | null,
  usdcBalance: 5_000n * 10n ** 6n,
  permit2Allowance: 0n,
  routerAllowance: [0n, 0, 0] as readonly [bigint, number, number],
  freshRouterAllowance: null as readonly [bigint, number, number] | null,
  canReceive: true,
  status: {phase: "idle"} as {phase: string; hash?: `0x${string}`; delayed?: boolean; stopped?: boolean},
  run: vi.fn(),
  reset: vi.fn(),
  stopWaiting: vi.fn(),
  sign: vi.fn(),
  calls: [] as Hex[],
}));

vi.mock("@/config/contracts", async () => {
  const pool = await import("@/lib/uniswapV4Liquidity");
  return {
    CONTRACTS: {
      USDC: pool.USDC,
      USDfr: pool.USDFR,
      MintRedeemController: "0x3333333333333333333333333333333333333333",
      ComplianceRegistry: "0x4444444444444444444444444444444444444444",
    },
    EXPLORER_BASE_URL: null,
    get IS_TESTNET() {
      return harness.testnet;
    },
    get STABLE_SYMBOL() {
      return harness.testnet ? "tUSDC" : "USDC";
    },
  };
});

const publicClient = {
  async call({data}: {to: string; data: Hex}) {
    harness.calls.push(data);
    if (harness.quoteError) throw harness.quoteError;
    const {args} = decodeFunctionData({abi: V4_QUOTER_ABI, data});
    const amountOut = (args[0].exactAmount * harness.rateMilli * 10n ** 12n) / 1_000n;
    return {
      data: encodeFunctionResult({abi: V4_QUOTER_ABI, functionName: "quoteExactInputSingle", result: [amountOut, 50_000n]}),
    };
  },
  async getBlock() {
    return {timestamp: BLOCK_TIMESTAMP};
  },
  async readContract({functionName}: {functionName: string}) {
    if (functionName === "allowance") return harness.freshRouterAllowance ?? harness.routerAllowance;
    if (functionName === "canTransfer") return harness.canReceive;
    throw new Error(`unexpected read ${functionName}`);
  },
};

vi.mock("wagmi", () => ({
  useAccount: () => ({address: harness.address}),
  usePublicClient: () => publicClient,
  useSignTypedData: () => ({mutateAsync: harness.sign}),
  useReadContract: ({functionName, args}: {functionName: string; args?: readonly unknown[]}) => {
    if (functionName === "getSlot0") {
      return {data: [79208232901844569635516417337224292n, 276318, 409_700, 375], isLoading: false};
    }
    if (!harness.address) return {data: undefined, isLoading: false};
    if (functionName === "balanceOf") return {data: harness.usdcBalance, isLoading: false};
    if (functionName === "allowance" && args?.length === 3) return {data: harness.routerAllowance, isLoading: false};
    if (functionName === "allowance") {
      // The Buy tab asks about Permit2; the mint form about the controller.
      return {data: args?.[1] === PERMIT2 ? harness.permit2Allowance : 0n, isLoading: false};
    }
    return {data: undefined, isLoading: false};
  },
}));

vi.mock("@/components/app/useWriteFlow", () => ({
  useWriteFlow: () => ({
    status: harness.status,
    run: harness.run,
    reset: harness.reset,
    stopWaiting: harness.stopWaiting,
    busy: ["simulating", "signing", "pending"].includes(harness.status.phase),
  }),
}));

function renderCard(props: {writesEnabled?: boolean; chainOk?: boolean} = {}) {
  const queryClient = new QueryClient();
  const rendered = render(
    <QueryClientProvider client={queryClient}>
      <GetUsdfrCard writesEnabled={props.writesEnabled ?? false} chainOk={props.chainOk ?? true} />
    </QueryClientProvider>,
  );
  return {...rendered, queryClient};
}

function buyPanel() {
  return screen.getByRole("tabpanel", {name: "Buy"});
}

async function typeAmount(text: string) {
  const user = userEvent.setup();
  await user.type(within(buyPanel()).getByRole("textbox", {name: "Amount in USDC"}), text);
  return user;
}

beforeEach(() => {
  harness.testnet = false;
  harness.address = BUYER;
  harness.rateMilli = 999n;
  harness.quoteError = null;
  harness.usdcBalance = 5_000n * USD;
  harness.permit2Allowance = 0n;
  harness.routerAllowance = [0n, 0, 0];
  harness.freshRouterAllowance = null;
  harness.canReceive = true;
  harness.status = {phase: "idle"};
  harness.run.mockReset();
  harness.reset.mockReset();
  harness.stopWaiting.mockReset();
  harness.sign.mockReset();
  harness.calls = [];
});

afterEach(cleanup);

describe("Get USDfr card: which tab a visitor sees", () => {
  it("shows a testnet the mint card alone: no tabs, no Buy, no pool", () => {
    harness.testnet = true;
    renderCard({writesEnabled: true});
    // Reach: the testnet mint card itself, faucet and all.
    expect(screen.getByRole("heading", {name: "Deposit & mint"})).toBeInTheDocument();
    expect(screen.getByText(/Need test funds\?/)).toBeInTheDocument();
    expect(screen.queryByRole("tablist")).not.toBeInTheDocument();
    expect(screen.queryByRole("tab", {name: "Buy"})).not.toBeInTheDocument();
    expect(screen.queryByText(/Uniswap/)).not.toBeInTheDocument();
  });

  it("opens on Buy on mainnet, with Mint 1:1 beside it", () => {
    renderCard();
    expect(screen.getByRole("tablist", {name: "Get USDfr"})).toBeInTheDocument();
    const tabs = screen.getAllByRole("tab");
    expect(tabs.map((tab) => tab.textContent)).toEqual(["Buy", "Mint 1:1"]);
    expect(screen.getByRole("tab", {name: "Buy"})).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tab", {name: "Mint 1:1"})).toHaveAttribute("aria-selected", "false");
    expect(buyPanel()).toBeVisible();
    expect(within(buyPanel()).getByRole("button", {name: "Buy USDfr"})).toBeInTheDocument();
    // The mint form is mounted but hidden, so an in-flight write there is never orphaned.
    expect(screen.queryByRole("tabpanel", {name: "Mint 1:1"})).not.toBeInTheDocument();
    const mintTab = screen.getByRole("tab", {name: "Mint 1:1"});
    const mintPanel = document.getElementById(mintTab.getAttribute("aria-controls")!);
    expect(mintPanel).toHaveAttribute("role", "tabpanel");
    expect(mintPanel).toHaveAttribute("aria-labelledby", mintTab.id);
    expect(mintPanel).toHaveAttribute("hidden");
    expect(mintPanel).not.toBeVisible();
    expect(mintPanel).toHaveTextContent("KYC-verified addresses only.");
    expect(buyPanel()).toHaveAttribute("aria-labelledby", screen.getByRole("tab", {name: "Buy"}).id);
  });

  it.each([
    ["a KYC-verified wallet", true],
    ["a wallet that is not KYC-verified", false],
  ])("opens on Buy for %s", (_label, writesEnabled) => {
    renderCard({writesEnabled});
    expect(screen.getByRole("tab", {name: "Buy"})).toHaveAttribute("aria-selected", "true");
    expect(buyPanel()).toBeVisible();
  });

  it("moves between tabs from the keyboard, as WAI-ARIA tabs do", async () => {
    renderCard({writesEnabled: true});
    const user = userEvent.setup();
    const buy = screen.getByRole("tab", {name: "Buy"});
    const mint = screen.getByRole("tab", {name: "Mint 1:1"});
    expect(buy).toHaveAttribute("tabindex", "0");
    expect(mint).toHaveAttribute("tabindex", "-1");
    await user.tab();
    expect(buy).toHaveFocus();
    await user.keyboard("{ArrowRight}");
    expect(mint).toHaveFocus();
    expect(mint).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tabpanel", {name: "Mint 1:1"})).toBeVisible();
    expect(screen.queryByRole("tabpanel", {name: "Buy"})).not.toBeInTheDocument();
    await user.keyboard("{ArrowRight}");
    expect(buy).toHaveFocus();
    await user.keyboard("{End}");
    expect(mint).toHaveFocus();
    await user.keyboard("{Home}");
    expect(buy).toHaveFocus();
    await user.keyboard("{ArrowLeft}");
    expect(mint).toHaveAttribute("aria-selected", "true");
    expect(buy).toHaveAttribute("tabindex", "-1");
  });

  it("keeps the mint form as it was, KYC-gated, and points unverified visitors back to Buy", async () => {
    renderCard({writesEnabled: false});
    const user = userEvent.setup();
    await user.click(screen.getByRole("tab", {name: "Mint 1:1"}));
    const mint = screen.getByRole("tabpanel", {name: "Mint 1:1"});
    expect(within(mint).getByText("Deposit USDC, mint USDfr 1:1. KYC-verified addresses only.")).toBeInTheDocument();
    expect(within(mint).getByRole("button", {name: "Mint USDfr"})).toBeDisabled();
    expect(within(mint).getByText(/Mainnet uses canonical Ethereum USDC/)).toBeInTheDocument();
    // The old "buy on the Uniswap pool" link is gone from the mint form; it points at the tab.
    expect(within(mint).queryByRole("link")).not.toBeInTheDocument();
    await user.click(within(mint).getByRole("button", {name: "buy USDfr in the Buy tab"}));
    expect(screen.getByRole("tab", {name: "Buy"})).toHaveAttribute("aria-selected", "true");
  });
});

describe("Buy tab", () => {
  it("discloses the third-party pool in one line and links to it in a new tab", () => {
    renderCard();
    const disclosure = within(buyPanel()).getByText(/Third-party pool:/);
    expect(disclosure).toHaveTextContent(
      "Third-party pool: Uniswap's USDfr/USDC market is not Forest Road's, and its price is set by the market. View the pool on Uniswap",
    );
    const link = within(buyPanel()).getByRole("link", {name: "View the pool on Uniswap"});
    expect(link).toHaveAttribute("href", POOL_URL);
    expect(link).toHaveAttribute("target", "_blank");
    expect(link).toHaveAttribute("rel", "noopener noreferrer");
  });

  it("shows the balance, a debounced live quote, the price against 1:1, the fee and the minimum received", async () => {
    renderCard();
    expect(within(buyPanel()).getByText("5,000 USDC")).toBeInTheDocument();
    await typeAmount("1000");
    expect(await within(buyPanel()).findByText("999 USDfr")).toBeInTheDocument();
    // One quote for the settled amount, not one per keystroke.
    expect(harness.calls).toHaveLength(1);
    const row = (term: string) => within(buyPanel()).getByText(term, {selector: "dt"}).parentElement;
    expect(row("You receive about")).toHaveTextContent("You receive about999 USDfr");
    expect(row("Minimum received")).toHaveTextContent("Minimum received998.5005 USDfr");
    expect(row("Price")).toHaveTextContent("Price0.999 USDfr per USDC");
    expect(row("Difference")).toHaveTextContent("Difference0.1% below 1:1");
    // The live slot0 carries Uniswap's protocol fee, so the total is more than the pool's 0.0375%.
    expect(row("Fees")).toHaveTextContent("Fees0.0475%");
    expect(
      within(buyPanel()).getByText("0.0375% pool fee plus a 0.01% Uniswap protocol fee, already in the quote."),
    ).toBeInTheDocument();
    expect(within(buyPanel()).queryByText(/below 0.99 USDfr per USDC/)).not.toBeInTheDocument();
  });

  it("recomputes the minimum received from the slippage limit and refuses one out of bounds", async () => {
    harness.permit2Allowance = 10_000n * USD;
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    const slippage = within(buyPanel()).getByRole("textbox", {name: "Max slippage"});
    expect(slippage).toHaveValue("0.05");
    await user.clear(slippage);
    await user.type(slippage, "3");
    expect(within(buyPanel()).getByText("Minimum received", {selector: "dt"}).parentElement).toHaveTextContent(
      "Minimum received969.03 USDfr",
    );
    await user.clear(slippage);
    await user.type(slippage, "0.04");
    expect(within(buyPanel()).getByText("Slippage must be between 0.05% and 3%.")).toBeInTheDocument();
    expect(within(buyPanel()).getByRole("button", {name: "Buy USDfr"})).toBeDisabled();
  });

  it("warns below 0.99 USDfr per USDC and names the 1:1 mint for KYC-verified addresses", async () => {
    harness.rateMilli = 989n;
    renderCard();
    const user = await typeAmount("1000");
    const warning = await within(buyPanel()).findByText("This quote is below 0.99 USDfr per USDC.");
    expect(warning.closest("p")).toHaveTextContent("KYC-verified addresses can mint USDfr 1:1 with USDC in the Mint 1:1 tab instead.");
    await user.click(within(buyPanel()).getByRole("button", {name: "Mint 1:1 tab"}));
    expect(screen.getByRole("tab", {name: "Mint 1:1"})).toHaveAttribute("aria-selected", "true");
  });

  it("does not warn at exactly 0.99", async () => {
    harness.rateMilli = 990n;
    renderCard();
    await typeAmount("1000");
    await within(buyPanel()).findByText("990 USDfr");
    expect(within(buyPanel()).queryByText(/below 0.99 USDfr per USDC/)).not.toBeInTheDocument();
  });

  it("refuses an amount above the balance before any wallet prompt", async () => {
    renderCard();
    harness.permit2Allowance = 10_000n * USD;
    await typeAmount("5000.000001");
    expect(within(buyPanel()).getByText("This is more than the wallet's USDC balance.")).toBeInTheDocument();
    // The quote arrives, so only the balance can be what keeps the button shut.
    await within(buyPanel()).findByText("4,995 USDfr");
    expect(within(buyPanel()).getByRole("button", {name: "Buy USDfr"})).toBeDisabled();
  });

  it("explains a quote the pool cannot fill", async () => {
    harness.quoteError = new BaseError("eth_call reverted", {
      cause: new RawContractError({
        data: encodeErrorResult({
          abi: SWAP_ROUTE_ERRORS,
          errorName: "UnexpectedRevertBytes",
          args: [
            encodeErrorResult({
              abi: SWAP_ROUTE_ERRORS,
              errorName: "NotEnoughLiquidity",
              args: ["0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55"],
            }),
          ],
        }),
      }),
    });
    harness.permit2Allowance = 10_000n * USD;
    renderCard();
    await typeAmount("4000");
    expect(
      await within(buyPanel()).findByText("The pool does not hold enough USDfr to fill this amount. Try a smaller amount.", {}, {timeout: 4_000}),
    ).toBeInTheDocument();
    expect(within(buyPanel()).getByText("no quote")).toBeInTheDocument();
    expect(within(buyPanel()).getByRole("button", {name: "Buy USDfr"})).toBeDisabled();
  });

  it("first approves Permit2 once, for the maximum, when USDC's allowance is short", async () => {
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    const approve = within(buyPanel()).getByRole("button", {name: "Approve USDC for Uniswap (once)"});
    expect(within(buyPanel()).getByText(/unlimited USDC approval with no expiry/)).toBeInTheDocument();
    expect(within(buyPanel()).getByText(/authorizations you give to other sites/)).toBeInTheDocument();
    await user.click(approve);
    expect(harness.run).toHaveBeenCalledTimes(1);
    const request = harness.run.mock.calls[0][0];
    expect(request).toEqual(permit2ApprovalRequest());
    expect(request.address).toBe(USDC);
    expect(request.functionName).toBe("approve");
    // The maximum, not the amount typed: 2^256 - 1, granted once.
    expect(request.args).toEqual([PERMIT2, maxUint256]);
    expect(request.args[1]).toBe((1n << 256n) - 1n);
    expect(harness.sign).not.toHaveBeenCalled();
  });

  it("asks a repeat buyer for no approval: after the first, a buy is a signature and the swap", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    harness.sign.mockResolvedValue(`0x${"cd".repeat(65)}`);
    renderCard();
    const user = await typeAmount("4000");
    await within(buyPanel()).findByText("3,996 USDfr");
    expect(within(buyPanel()).queryByRole("button", {name: "Approve USDC for Uniswap (once)"})).not.toBeInTheDocument();
    expect(within(buyPanel()).queryByText(/A one-time approval/)).not.toBeInTheDocument();
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    // One signature for this buy's amount, then the swap: no approve call anywhere.
    expect(harness.sign).toHaveBeenCalledTimes(1);
    expect(harness.sign.mock.calls[0][0].message.details.amount).toBe(4_000n * USD);
    const request = harness.run.mock.calls[0][0];
    expect(request.functionName).toBe("execute");
    expect(request.args[0]).toBe("0x8a10");
  });

  it("signs a permit for exactly the amount, then hands the write flow the router call it reviewed", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    const signature = `0x${"cd".repeat(65)}` as Hex;
    harness.sign.mockResolvedValue(signature);
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));

    const deadline = BLOCK_TIMESTAMP + 1_200n;
    const permit = buildPermitSingle({amount: 1_000n * USD, nonce: 0, deadline});
    expect(harness.sign).toHaveBeenCalledWith({account: BUYER, ...permitTypedData(permit)});

    const request = harness.run.mock.calls[0][0];
    expect(request.address).toBe(UNIVERSAL_ROUTER);
    expect(request.abi).toBe(UNIVERSAL_ROUTER_ABI);
    expect(request.functionName).toBe("execute");
    expect(typeof request.decodeError).toBe("function");
    expect(request.keepPendingUntilReceipt).toBe(true);
    const [commands, inputs, sentDeadline] = request.args;
    expect(commands).toBe("0x8a10");
    expect(sentDeadline).toBe(deadline);
    expect(decodePermit2PermitInput(inputs[0])).toEqual({permit, signature});
    const swap = decodeV4SwapInput(inputs[1]);
    expect(swap.swap.zeroForOne).toBe(true);
    expect(swap.swap.amountIn).toBe(1_000n * USD);
    // 999 USDfr quoted, the default 0.05% slippage: 998.5005 USDfr.
    expect(swap.swap.amountOutMinimum).toBe(9_985_005n * 10n ** 14n);
    expect(swap.take).toEqual({currency: USDFR, amount: 9_985_005n * 10n ** 14n});
  });

  it("does not submit an old wallet's buy if the account switches during permit signing", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    let finishSignature!: (signature: Hex) => void;
    harness.sign.mockImplementation(() => new Promise<Hex>((resolve) => { finishSignature = resolve; }));
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await waitFor(() => expect(harness.sign).toHaveBeenCalledTimes(1));
    harness.address = "0x2222222222222222222222222222222222222222";
    await user.click(screen.getByRole("tab", {name: "Mint 1:1"}));
    await act(async () => { finishSignature(`0x${"cd".repeat(65)}` as Hex); });
    expect(harness.run).not.toHaveBeenCalled();
  });

  it("keeps the quoted minimum on screen while signing even if the live quote refreshes", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    let finishSign!: (signature: Hex) => void;
    harness.sign.mockImplementation(() => new Promise<Hex>((resolve) => { finishSign = resolve; }));
    const {queryClient} = renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await within(buyPanel()).findByText(/Sign the Permit2 allowance in your wallet/);
    harness.rateMilli = 1_010n;
    await act(async () => { await queryClient.invalidateQueries({queryKey: ["usdfr-buy-quote"]}); });
    expect(within(buyPanel()).getByText("Minimum received", {selector: "dt"}).parentElement).toHaveTextContent(
      "Minimum received998.5005 USDfr",
    );
    expect(within(buyPanel()).getByText(/This buy reverts below 998.5005 USDfr/)).toBeInTheDocument();
    await act(async () => { finishSign(`0x${"cd".repeat(65)}`); });
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    expect(decodeV4SwapInput(harness.run.mock.calls[0][0].args[1][1]).take.amount).toBe(9_985_005n * 10n ** 14n);
  });

  it("keeps the calldata minimum visible while the write flow asks for confirmation and waits for the receipt", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    harness.sign.mockResolvedValue(`0x${"cd".repeat(65)}`);
    const rendered = renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    harness.status = {phase: "signing"};
    rendered.rerender(<QueryClientProvider client={rendered.queryClient}>
      <GetUsdfrCard writesEnabled={false} chainOk={true} />
    </QueryClientProvider>);
    harness.rateMilli = 1_010n;
    await act(async () => { await rendered.queryClient.invalidateQueries({queryKey: ["usdfr-buy-quote"]}); });
    expect(within(buyPanel()).getByText("Minimum received", {selector: "dt"}).parentElement).toHaveTextContent(
      "Minimum received998.5005 USDfr",
    );
    harness.status = {phase: "pending", hash: `0x${"ef".repeat(32)}`};
    rendered.rerender(<QueryClientProvider client={rendered.queryClient}>
      <GetUsdfrCard writesEnabled={false} chainOk={true} />
    </QueryClientProvider>);
    expect(within(buyPanel()).getByText("Minimum received", {selector: "dt"}).parentElement).toHaveTextContent(
      "Minimum received998.5005 USDfr",
    );
    expect(decodeV4SwapInput(harness.run.mock.calls[0][0].args[1][1]).take.amount).toBe(9_985_005n * 10n ** 14n);
  });

  it("does not submit a Buy if the card unmounts while its permit signature is pending", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    let finishSign!: (signature: Hex) => void;
    harness.sign.mockImplementation(() => new Promise<Hex>((resolve) => { finishSign = resolve; }));
    const {unmount} = renderCard();
    const user = await typeAmount("300");
    await within(buyPanel()).findByText("299.7 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await waitFor(() => expect(harness.sign).toHaveBeenCalledTimes(1));
    unmount();
    await act(async () => { finishSign(`0x${"cd".repeat(65)}`); });
    expect(harness.run).not.toHaveBeenCalled();
  });

  it("needs only the swap when the Permit2 approval and a live router allowance both stand", async () => {
    harness.permit2Allowance = maxUint256;
    harness.routerAllowance = [10_000n * USD, Number(BLOCK_TIMESTAMP + 100_000_000n), 3];
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    expect(await within(buyPanel()).findByText(/This buy can reuse that allowance without a new signature/)).toBeInTheDocument();
    expect(within(buyPanel()).getByText(/10,000 USDC through Permit2/)).toBeInTheDocument();
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    expect(await within(buyPanel()).findByText(/Select Continue to acknowledge this allowance before the wallet opens/)).toBeInTheDocument();
    expect(harness.run).not.toHaveBeenCalled();
    await user.click(within(buyPanel()).getByRole("button", {name: "Continue with existing allowance"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    expect(harness.sign).not.toHaveBeenCalled();
    const [commands, inputs] = harness.run.mock.calls[0][0].args;
    expect(commands).toBe("0x10");
    expect(inputs).toHaveLength(1);
  });

  it("names an unlimited allowance from the fresh Buy read even when the displayed poll was stale", async () => {
    harness.permit2Allowance = maxUint256;
    harness.routerAllowance = [0n, 0, 0];
    harness.freshRouterAllowance = [(1n << 160n) - 1n, Number(BLOCK_TIMESTAMP + 100_000n), 7];
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    expect(within(buyPanel()).queryByText(/This buy can reuse that allowance/)).not.toBeInTheDocument();
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    expect(await within(buyPanel()).findByText(/Select Continue to acknowledge this allowance before the wallet opens/)).toBeInTheDocument();
    expect(harness.run).not.toHaveBeenCalled();
    await user.click(within(buyPanel()).getByRole("button", {name: "Continue with existing allowance"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    expect(harness.run.mock.calls[0][0].args[0]).toBe("0x10");
    expect(within(buyPanel()).getByText(/an unlimited amount of USDC through Permit2/)).toBeInTheDocument();
    expect(within(buyPanel()).getByText(/This buy can reuse that allowance without a new signature/)).toBeInTheDocument();
  });

  it("repeats the allowance review if the second live read changes before the wallet opens", async () => {
    harness.permit2Allowance = maxUint256;
    harness.routerAllowance = [0n, 0, 0];
    harness.freshRouterAllowance = [1_000n * USD, Number(BLOCK_TIMESTAMP + 100_000n), 7];
    renderCard();
    const user = await typeAmount("300");
    await within(buyPanel()).findByText("299.7 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    expect(await within(buyPanel()).findByText(/fresh chain read found up to 1,000 USDC/)).toBeInTheDocument();
    expect(harness.run).not.toHaveBeenCalled();

    harness.freshRouterAllowance = [2_000n * USD, Number(BLOCK_TIMESTAMP + 100_000n), 8];
    await user.click(within(buyPanel()).getByRole("button", {name: "Continue with existing allowance"}));
    expect(await within(buyPanel()).findByText(/fresh chain read found up to 2,000 USDC/)).toBeInTheDocument();
    expect(harness.run).not.toHaveBeenCalled();

    await user.click(within(buyPanel()).getByRole("button", {name: "Continue with existing allowance"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
  });

  it("warns before Buy that an old allowance may pay if a new permit is not applied", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    // It covers this amount now, but not the full 20-minute swap deadline, so Buy signs.
    harness.freshRouterAllowance = [3_000n * USD, Number(BLOCK_TIMESTAMP + 600n), 7];
    let finishSign!: (signature: Hex) => void;
    harness.sign.mockImplementation(() => new Promise<Hex>((resolve) => { finishSign = resolve; }));
    renderCard();
    const user = await typeAmount("300");
    await within(buyPanel()).findByText("299.7 USDfr");
    expect(within(buyPanel()).getByText(/If a new Permit2 signature is not applied/)).toBeInTheDocument();
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    expect(await within(buyPanel()).findByText(/existing allowance of up to 3,000 USDC/)).toBeInTheDocument();
    expect(within(buyPanel()).getByText(/Select Continue to acknowledge this allowance before the wallet opens/)).toBeInTheDocument();
    expect(harness.sign).not.toHaveBeenCalled();
    await user.click(within(buyPanel()).getByRole("button", {name: "Continue with existing allowance"}));
    await waitFor(() => expect(harness.sign).toHaveBeenCalledTimes(1));
    await act(async () => { finishSign(`0x${"cd".repeat(65)}`); });
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    expect(harness.run.mock.calls[0][0].args[0]).toBe("0x8a10");
  });

  it("tells a jurisdiction-blocked address in words, before any signature or transaction", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    harness.canReceive = false;
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    expect(
      await within(buyPanel()).findByText(
        "This address cannot receive USDfr: it is jurisdiction-blocked, so USDfr would refuse the pool's payment and the swap would revert. Nothing was signed or sent.",
      ),
    ).toBeInTheDocument();
    expect(harness.sign).not.toHaveBeenCalled();
    expect(harness.run).not.toHaveBeenCalled();
  });

  it("does not ask a blocked first-time buyer for an unlimited Permit2 approval", async () => {
    harness.permit2Allowance = 0n;
    harness.canReceive = false;
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Approve USDC for Uniswap (once)"}));
    expect(await within(buyPanel()).findByText(
      "This address cannot receive USDfr: it is jurisdiction-blocked, so USDfr would refuse the pool's payment and the swap would revert. Nothing was signed or sent.",
    )).toBeInTheDocument();
    expect(harness.run).not.toHaveBeenCalled();
    expect(harness.sign).not.toHaveBeenCalled();
  });

  it("keeps Buy disabled after a receipt timeout and offers a way to stop checking without enabling another buy", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    const rendered = renderCard();
    await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    harness.status = {phase: "pending", hash: `0x${"ef".repeat(32)}`, delayed: true};
    rendered.rerender(<QueryClientProvider client={rendered.queryClient}>
      <GetUsdfrCard writesEnabled={false} chainOk={true} />
    </QueryClientProvider>);
    expect(within(buyPanel()).getByRole("button", {name: "Pending…"})).toBeDisabled();
    const stop = within(buyPanel()).getByRole("button", {name: "Stop checking this transaction"});
    await userEvent.setup().click(stop);
    expect(harness.stopWaiting).toHaveBeenCalledTimes(1);
    expect(harness.run).not.toHaveBeenCalled();
    harness.status = {phase: "pending", hash: `0x${"ef".repeat(32)}`, delayed: true, stopped: true};
    rendered.rerender(<QueryClientProvider client={rendered.queryClient}>
      <GetUsdfrCard writesEnabled={false} chainOk={true} />
    </QueryClientProvider>);
    expect(within(buyPanel()).getByRole("button", {name: "Buy locked—outcome unknown"})).toBeDisabled();
    expect(within(buyPanel()).getByRole("status")).toHaveTextContent(
      "Check its hash in your wallet or an explorer; reload only after its outcome is clear.",
    );
  });

  it("points to the Stake card after a successful buy", async () => {
    harness.permit2Allowance = AFTER_FIRST_BUY;
    harness.sign.mockResolvedValue(`0x${"cd".repeat(65)}`);
    renderCard();
    const user = await typeAmount("1000");
    await within(buyPanel()).findByText("999 USDfr");
    await user.click(within(buyPanel()).getByRole("button", {name: "Buy USDfr"}));
    await waitFor(() => expect(harness.run).toHaveBeenCalledTimes(1));
    expect(within(buyPanel()).queryByRole("link", {name: "Stake it to earn the sUSDfr rate"})).not.toBeInTheDocument();
    harness.status = {phase: "success", hash: `0x${"ef".repeat(32)}`};
    act(() => harness.run.mock.calls[0][0].onSuccess());
    const pointer = await within(buyPanel()).findByRole("link", {name: "Stake it to earn the sUSDfr rate"});
    expect(pointer).toHaveAttribute("href", "#stake-card");
    expect(within(buyPanel()).getByRole("textbox", {name: "Amount in USDC"})).toHaveValue("");
  });

  it("offers nothing to submit without a connected wallet, yet still quotes", async () => {
    harness.address = undefined;
    renderCard({chainOk: false});
    expect(within(buyPanel()).getByText("wallet not connected")).toBeInTheDocument();
    await typeAmount("10");
    expect(await within(buyPanel()).findByText("9.99 USDfr")).toBeInTheDocument();
    expect(within(buyPanel()).getByRole("button", {name: "Buy USDfr"})).toBeDisabled();
  });
});
