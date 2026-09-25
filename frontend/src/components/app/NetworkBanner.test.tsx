import {cleanup, fireEvent, render, screen} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

import {NetworkBanner} from "@/components/app/NetworkBanner";

const harness = vi.hoisted(() => ({
  isConnected: true,
  chainId: 1 as number | undefined,
  switchChain: vi.fn(),
}));

vi.mock("@/config/contracts", () => ({NETWORK_NAME: "Ethereum mainnet"}));
vi.mock("@/lib/wagmi", () => ({EXPECTED_CHAIN: {id: 1}}));
vi.mock("wagmi", () => ({
  useAccount: () => ({isConnected: harness.isConnected, chainId: harness.chainId}),
  useSwitchChain: () => ({switchChain: harness.switchChain, isPending: false, error: null}),
}));

beforeEach(() => {
  harness.isConnected = true;
  harness.chainId = 1;
  harness.switchChain.mockReset();
});

afterEach(cleanup);

describe("NetworkBanner", () => {
  it("stays hidden when wagmi and the probe both have the wallet on the right chain", () => {
    const {container} = render(<NetworkBanner />);
    expect(container).toBeEmptyDOMElement();
  });

  it("offers the switch when wagmi reports another chain", () => {
    harness.chainId = 11155111;
    render(<NetworkBanner />);
    expect(screen.getByText("Wrong network.")).toBeVisible();
    expect(screen.getByText(/Your wallet is on chain 11155111\./)).toBeVisible();
  });

  // The gap behind the 2026-09-24 report: wagmi still said chain 1, so the banner hid, while
  // the wallet itself answered from another chain.
  it("offers the switch when the probe proves a wrong chain that wagmi has not seen", () => {
    render(<NetworkBanner walletChainId={137n} />);
    expect(screen.getByText("Wrong network.")).toBeVisible();
    expect(screen.getByText(/Your wallet is on chain 137\./)).toBeVisible();
  });

  it("asks the wallet to switch and re-checks only once the wallet accepts", () => {
    const onSwitched = vi.fn();
    render(<NetworkBanner walletChainId={137n} onSwitched={onSwitched} />);
    fireEvent.click(screen.getByRole("button", {name: "Switch to Ethereum mainnet"}));

    expect(harness.switchChain).toHaveBeenCalledTimes(1);
    const [variables, options] = harness.switchChain.mock.calls[0];
    expect(variables).toEqual({chainId: 1});
    expect(onSwitched).not.toHaveBeenCalled();
    options.onSuccess();
    expect(onSwitched).toHaveBeenCalledTimes(1);
  });

  it("stays hidden while disconnected, whatever the probe last said", () => {
    harness.isConnected = false;
    const {container} = render(<NetworkBanner walletChainId={137n} />);
    expect(container).toBeEmptyDOMElement();
  });
});
