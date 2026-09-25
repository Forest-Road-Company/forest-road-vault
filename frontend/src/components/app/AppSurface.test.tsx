import {cleanup, fireEvent, render, screen, waitFor} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

import {AppSurface} from "@/components/app/AppSurface";
import type {RpcAlignmentResult} from "@/lib/rpcAlignment";

const ADDRESS = "0x1111111111111111111111111111111111111111";

const harness = vi.hoisted(() => {
  // Stable identities: the alignment effect depends on these clients, so fresh objects on every
  // render would re-probe forever.
  const appRequest = async () => null;
  const walletRequest = async () => null;
  return {
    appRequest,
    walletRequest,
    publicClient: {request: appRequest},
    walletClient: {transport: {request: walletRequest}},
    probe: vi.fn(),
    switchChain: vi.fn(),
  };
});

vi.mock("@/config/contracts", () => ({
  CONTRACTS: {ComplianceRegistry: "0x2222222222222222222222222222222222222222"},
  IS_LOCAL_FORK: false,
  IS_TESTNET: false,
  NETWORK_NAME: "Ethereum mainnet",
}));
vi.mock("@/lib/abi", () => ({COMPLIANCE_ABI: []}));
vi.mock("@/lib/wagmi", () => ({EXPECTED_CHAIN: {id: 1}}));
vi.mock("@/lib/rpcAlignment", () => ({probeRpcAlignment: harness.probe}));
vi.mock("@/components/app/ConnectControl", () => ({ConnectControl: () => <span>wallet</span>}));
vi.mock("@/components/app/MintCard", () => ({MintCard: () => null}));
vi.mock("@/components/app/StakeCard", () => ({StakeCard: () => null}));
vi.mock("@/components/app/RedeemCard", () => ({RedeemCard: () => null}));
vi.mock("@/components/app/YieldPositionPanel", () => ({YieldPositionPanel: () => null}));
vi.mock("wagmi", () => ({
  useAccount: () => ({address: ADDRESS, isConnected: true, chainId: 1}),
  usePublicClient: () => harness.publicClient,
  useWalletClient: () => ({data: harness.walletClient}),
  useReadContract: () => ({data: true, isLoading: false, isError: false}),
  useSwitchChain: () => ({switchChain: harness.switchChain, isPending: false, error: null}),
}));

const WALLET_FAILURE_MESSAGE =
  "The wallet RPC did not answer eth_blockNumber: Internal JSON-RPC error. (code -32603). Writes are disabled.";
const WALLET_FAILURE: RpcAlignmentResult = {
  aligned: false,
  reason: "wallet",
  message: WALLET_FAILURE_MESSAGE,
};
const ALIGNED: RpcAlignmentResult = {aligned: true, blockNumber: 100n, blockHash: `0x${"ab".repeat(32)}`};

beforeEach(() => {
  harness.probe.mockReset();
  harness.switchChain.mockReset();
});

afterEach(cleanup);

describe("AppSurface RPC alignment states", () => {
  it("probes the app client against the wallet's own transport", async () => {
    harness.probe.mockResolvedValue(ALIGNED);
    render(<AppSurface />);
    await waitFor(() => expect(harness.probe).toHaveBeenCalledTimes(1));
    expect(harness.probe).toHaveBeenCalledWith(harness.appRequest, harness.walletRequest, {
      expectedChainId: 1,
      requireExactTip: false,
    });
    expect(await screen.findByText("KYC verified")).toBeVisible();
  });

  // The happy switching path: a wallet proved to be on another chain gets the switch banner,
  // even though wagmi still says chain 1, and never the mismatch box.
  it("turns a proven wrong chain into the switch banner, not a mismatch", async () => {
    harness.probe.mockResolvedValue({
      aligned: false,
      reason: "wallet-chain",
      walletChainId: 137n,
      message: "Expected chain 1, but the wallet reports chain 137. Writes are disabled.",
    } satisfies RpcAlignmentResult);
    render(<AppSurface />);
    expect(await screen.findByText("Wrong network.")).toBeVisible();
    expect(screen.getByText(/Your wallet is on chain 137\./)).toBeVisible();
    expect(screen.queryByText("RPC mismatch.")).toBeNull();
  });

  it("re-checks as soon as the wallet accepts the switch, not at the next poll", async () => {
    harness.probe
      .mockResolvedValueOnce({
        aligned: false,
        reason: "wallet-chain",
        walletChainId: 137n,
        message: "Expected chain 1, but the wallet reports chain 137. Writes are disabled.",
      } satisfies RpcAlignmentResult)
      .mockResolvedValue(ALIGNED);
    harness.switchChain.mockImplementation((_variables, options) => options.onSuccess());
    render(<AppSurface />);

    fireEvent.click(await screen.findByRole("button", {name: "Switch to Ethereum mainnet"}));
    await waitFor(() => expect(harness.probe).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(screen.queryByText("Wrong network.")).toBeNull());
    expect(await screen.findByText("KYC verified")).toBeVisible();
  });

  // The reported case: right chain ID, failing wallet RPC. Nothing can be switched from here,
  // so the box says what failed and what to change in the wallet.
  it("explains a failing wallet RPC, tells the person what to change, and re-checks on demand", async () => {
    harness.probe.mockResolvedValueOnce(WALLET_FAILURE).mockResolvedValue(ALIGNED);
    render(<AppSurface />);

    expect(await screen.findByText("RPC mismatch.")).toBeVisible();
    expect(screen.getByText(WALLET_FAILURE_MESSAGE)).toBeVisible();
    expect(screen.getByText(/switching from here cannot fix this/)).toBeVisible();
    expect(screen.queryByText("Wrong network.")).toBeNull();

    fireEvent.click(screen.getByRole("button", {name: "Check again"}));
    await waitFor(() => expect(harness.probe).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(screen.queryByText("RPC mismatch.")).toBeNull());
  });

  it("does not blame the wallet when the app's own transport failed", async () => {
    harness.probe.mockResolvedValue({
      aligned: false,
      reason: "app",
      message:
        "The app RPC did not answer eth_chainId: HTTP request failed. (HTTP 403). Writes are disabled.",
    } satisfies RpcAlignmentResult);
    render(<AppSurface />);

    expect(await screen.findByText("RPC mismatch.")).toBeVisible();
    expect(screen.queryByText(/switching from here cannot fix this/)).toBeNull();
    expect(screen.getByRole("button", {name: "Check again"})).toBeVisible();
  });
});
