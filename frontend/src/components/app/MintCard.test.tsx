import {fireEvent, render, screen} from "@testing-library/react";
import {afterEach, describe, expect, it, vi} from "vitest";
import {MintCard, MintForm} from "@/components/app/MintCard";

/**
 * The mint form and its pointer for addresses that are not KYC-verified.
 *
 * On mainnet the form is the Get USDfr card's "Mint 1:1" tab, and it points to the Buy tab (the
 * route the mint gate's audience can use) whatever the KYC state. A testnet has no pool, so its
 * standalone mint card carries no pointer and no pool link. The AppSurface suite replaces the
 * card with a stub, so the form is mounted here.
 */

// Read through getters at render time, so one module mock serves both networks.
const network = vi.hoisted(() => ({testnet: false}));

vi.mock("@/config/contracts", () => ({
  CONTRACTS: {
    USDC: "0x2222222222222222222222222222222222222222",
    MintRedeemController: "0x3333333333333333333333333333333333333333",
  },
  EXPLORER_BASE_URL: null,
  get IS_TESTNET() {
    return network.testnet;
  },
  get STABLE_SYMBOL() {
    return network.testnet ? "tUSDC" : "USDC";
  },
}));

vi.mock("wagmi", () => ({
  useAccount: () => ({address: "0x1111111111111111111111111111111111111111"}),
  useReadContract: () => ({data: undefined, isLoading: false}),
}));

vi.mock("@/components/app/useWriteFlow", () => ({
  useWriteFlow: () => ({status: {phase: "idle"}, run: vi.fn(), reset: vi.fn(), busy: false}),
}));

afterEach(() => {
  network.testnet = false;
});

describe("MintForm, the Mint 1:1 tab, for addresses that are not KYC-verified", () => {
  it("points to the Buy tab on mainnet while minting is disabled, with no link off the site", () => {
    const onShowBuy = vi.fn();
    // Connected on the right chain but not KYC-verified: the audience for the pointer.
    render(<MintForm writesEnabled={false} chainOk onShowBuy={onShowBuy} />);

    // Reach: this is the mainnet render, not a testnet or empty one.
    expect(screen.getByText(/Mainnet uses canonical Ethereum USDC/)).toBeInTheDocument();
    expect(screen.getByText("Deposit USDC, mint USDfr 1:1. KYC-verified addresses only.")).toBeInTheDocument();

    const pointer = screen.getByRole("button", {name: "buy USDfr in the Buy tab"});
    expect(pointer.closest("p")).toHaveTextContent("Not KYC-verified? Any address can buy USDfr in the Buy tab, then stake it.");
    fireEvent.click(pointer);
    expect(onShowBuy).toHaveBeenCalledTimes(1);
    // The pool link now lives in the Buy tab, beside the swap it describes.
    expect(screen.queryByRole("link")).not.toBeInTheDocument();

    // The mint stays shut for this address; the pointer is not gated with it.
    expect(screen.getByRole("button", {name: "Mint USDfr"})).toBeDisabled();
  });

  it("shows no pointer on a testnet, where there is no pool", () => {
    network.testnet = true;
    render(<MintCard writesEnabled={false} chainOk />);

    // Reach: this is the testnet render (the standalone card and its faucet footer).
    expect(screen.getByRole("heading", {name: "Deposit & mint"})).toBeInTheDocument();
    expect(screen.getByText(/Need test funds\?/)).toBeInTheDocument();

    expect(screen.queryByText(/Not KYC-verified\?/)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", {name: /Buy tab/})).not.toBeInTheDocument();
    expect(screen.queryByText(/Uniswap/)).not.toBeInTheDocument();
  });
});
