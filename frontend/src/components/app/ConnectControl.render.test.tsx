import {act, fireEvent, render, screen, waitFor, within} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";

type Listener = (payload: {type: string; data?: unknown}) => void;
function emitter() {
  const listeners = new Set<Listener>();
  return {
    on: (_event: string, fn: Listener) => void listeners.add(fn),
    off: (_event: string, fn: Listener) => void listeners.delete(fn),
    emit: (payload: {type: string; data?: unknown}) => listeners.forEach((fn) => fn(payload)),
    count: () => listeners.size,
  };
}

const harness = vi.hoisted(() => ({
  connectors: [] as unknown[],
  connectAsync: vi.fn(),
  disconnect: vi.fn(),
  getProvider: vi.fn(async () => undefined as unknown),
}));

vi.mock("wagmi", () => ({
  useAccount: () => ({address: undefined, isConnected: false}),
  useConnect: () => ({connectAsync: harness.connectAsync}),
  useConnectors: () => harness.connectors,
  useDisconnect: () => ({disconnect: harness.disconnect}),
}));

/** A connection request the test settles by hand, as a slow wallet would. */
function deferred() {
  let resolve!: (value: unknown) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return {promise, resolve, reject};
}
const rejected = (name: string) => Object.assign(new Error("Request rejected"), {name});

import {ConnectControl} from "./ConnectControl";
import {getConnectLock, resetConnectLock} from "@/lib/connectLock";

const ICON = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=";
const injected = {id: "injected", name: "Injected", uid: "u-injected", emitter: emitter(), getProvider: harness.getProvider};
const walletConnect = {id: "walletConnect", name: "WalletConnect", uid: "u-wc", emitter: emitter(), getProvider: harness.getProvider};
const rabby = {id: "io.rabby", name: "Rabby Wallet", icon: ICON, uid: "u-rabby", emitter: emitter(), getProvider: harness.getProvider};
const alpha = {id: "com.alpha", name: "Alpha Wallet", icon: ICON, uid: "u-alpha", emitter: emitter(), getProvider: harness.getProvider};
const beta = {id: "com.beta", name: "Beta Wallet", icon: ICON, uid: "u-beta", emitter: emitter(), getProvider: harness.getProvider};

beforeEach(() => {
  resetConnectLock();
  harness.connectAsync.mockReset();
  harness.connectAsync.mockImplementation(() => new Promise(() => undefined));
  harness.disconnect.mockReset();
  harness.getProvider.mockReset();
  harness.getProvider.mockImplementation(async () => undefined);
});
afterEach(() => {
  delete (window as {ethereum?: unknown}).ethereum;
  resetConnectLock();
});

/** Renders after the post-mount check of window.ethereum has run. */
async function mount(ui = <ConnectControl />) {
  const view = render(ui);
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 5));
  });
  return view;
}

describe("ConnectControl chooser", () => {
  it("on a phone with no injected provider, WalletConnect is the only choice and opens at once", async () => {
    harness.connectors = [injected, walletConnect];
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    await waitFor(() => expect(harness.connectAsync).toHaveBeenCalledWith({connector: walletConnect}));
    expect(screen.queryByText(/Injected/)).not.toBeInTheDocument();
    expect(await screen.findByRole("status")).toHaveTextContent("Opening WalletConnect…");
  });

  it("offers the page's own provider as 'Browser wallet' beside WalletConnect, and never says 'Injected'", async () => {
    (window as {ethereum?: unknown}).ethereum = {request: vi.fn()};
    harness.connectors = [injected, walletConnect];
    await mount();
    const trigger = screen.getByRole("button", {name: "Connect wallet"});
    expect(trigger).toHaveAttribute("aria-haspopup", "dialog");
    fireEvent.click(trigger);
    const dialog = screen.getByRole("dialog", {name: "Choose a wallet"});
    expect(dialog).toHaveTextContent("Browser wallet");
    expect(dialog).toHaveTextContent("WalletConnect");
    expect(dialog).toHaveTextContent("Mobile wallet or QR code");
    expect(dialog).not.toHaveTextContent(/injected/i);
    // Focus moves into the chooser, and opening it starts the WalletConnect provider.
    await waitFor(() => expect(screen.getByRole("button", {name: /Browser wallet/})).toHaveFocus());
    expect(harness.getProvider).toHaveBeenCalled();
  });

  it("lists discovered wallets by name with their own icon", async () => {
    harness.connectors = [injected, rabby, walletConnect];
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    const option = screen.getByRole("button", {name: /Rabby Wallet/});
    expect(option.querySelector("img")).toHaveAttribute("src", ICON);
    expect(screen.queryByText("Browser wallet")).not.toBeInTheDocument();
  });

  it("closes with the close button, Cancel or Escape, returning focus to the trigger", async () => {
    (window as {ethereum?: unknown}).ethereum = {};
    harness.connectors = [injected, walletConnect];
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    fireEvent.click(screen.getByRole("button", {name: "Close the wallet chooser"}));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("button", {name: "Connect wallet"})).toHaveFocus());

    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    fireEvent.click(screen.getByRole("button", {name: "Cancel"}));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    fireEvent.keyDown(document, {key: "Escape"});
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("button", {name: "Connect wallet"})).toHaveFocus());
    expect(harness.connectAsync).not.toHaveBeenCalled();
  });

  it("starts WalletConnect only when the chooser opens, not when the button is pointed at or focused", async () => {
    (window as {ethereum?: unknown}).ethereum = {};
    harness.connectors = [injected, walletConnect];
    await mount();
    const trigger = screen.getByRole("button", {name: "Connect wallet"});
    fireEvent.pointerEnter(trigger);
    fireEvent.focus(trigger);
    expect(harness.getProvider).not.toHaveBeenCalled();
    fireEvent.click(trigger);
    expect(harness.getProvider).toHaveBeenCalledTimes(1);
  });
});

describe("ConnectControl while a request is open", () => {
  it("says what it waits for, offers no Cancel, and moves focus to that status", async () => {
    harness.connectors = [injected, rabby, walletConnect];
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    fireEvent.click(screen.getByRole("button", {name: /Rabby Wallet/}));
    const status = await screen.findByRole("status");
    expect(status).toHaveTextContent("Waiting for Rabby Wallet. Approve or reject the request in your wallet.");
    expect(status).toHaveAttribute("tabindex", "-1");
    await waitFor(() => expect(status).toHaveFocus());
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("suggests where to look when a browser wallet stays quiet", async () => {
    vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout"]});
    try {
      harness.connectors = [injected, rabby, walletConnect];
      render(<ConnectControl />);
      act(() => vi.advanceTimersByTime(5));
      fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
      fireEvent.click(screen.getByRole("button", {name: /Rabby Wallet/}));
      await act(async () => vi.advanceTimersByTime(8_000));
      expect(screen.getByRole("status")).toHaveTextContent(
        "Waiting for Rabby Wallet. Approve or reject the request in your wallet. Nothing showing? Open your wallet and reject the request there, then choose again.",
      );
    } finally {
      vi.useRealTimers();
    }
  });

  it("says when WalletConnect's QR code is up, and when its relay is slow", async () => {
    vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout"]});
    try {
      harness.connectors = [injected, walletConnect];
      render(<ConnectControl />);
      act(() => vi.advanceTimersByTime(5));
      fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
      await act(async () => undefined);
      expect(screen.getByRole("status")).toHaveTextContent("Opening WalletConnect…");
      act(() => vi.advanceTimersByTime(5_000));
      expect(screen.getByRole("status")).toHaveTextContent(/^Still reaching the WalletConnect relay/);
      act(() => walletConnect.emitter.emit({type: "display_uri", data: "wc:abc"}));
      expect(screen.getByRole("status")).toHaveTextContent(/^Scan the QR code with your phone's wallet/);
    } finally {
      vi.useRealTimers();
    }
  });

  it("shows the open request on every button, so a second wallet cannot be chosen, even after the first button unmounts", async () => {
    harness.connectors = [injected, alpha, beta, walletConnect];
    const request = deferred();
    harness.connectAsync.mockImplementationOnce(() => request.promise);
    const first = await mount(
      <div data-testid="first">
        <ConnectControl />
      </div>,
    );
    await mount(
      <div data-testid="second">
        <ConnectControl />
      </div>,
    );
    const inFirst = within(screen.getByTestId("first"));
    const inSecond = within(screen.getByTestId("second"));
    fireEvent.click(inFirst.getByRole("button", {name: "Connect wallet"}));
    fireEvent.click(inFirst.getByRole("button", {name: /Alpha Wallet/}));
    expect(await inSecond.findByRole("status")).toHaveTextContent("Waiting for Alpha Wallet.");
    expect(inSecond.queryByRole("button")).not.toBeInTheDocument();

    // A client-side navigation unmounts the button that started the request; the lock stays.
    first.unmount();
    expect(getConnectLock()).not.toBeNull();
    expect(inSecond.getByRole("status")).toHaveTextContent("Waiting for Alpha Wallet.");
    expect(harness.connectAsync).toHaveBeenCalledTimes(1);

    // The request settles after its button is gone: the lock clears and the page offers wallets again.
    await act(async () => request.resolve({accounts: ["0xa1"], chainId: 11155111}));
    expect(getConnectLock()).toBeNull();
    expect(inSecond.getByRole("button", {name: "Connect wallet"})).toBeInTheDocument();
    expect(harness.disconnect).not.toHaveBeenCalled();
  });

  it("follows the review's ordering: with A open, B cannot be chosen, and A's approval stands", async () => {
    harness.connectors = [injected, alpha, beta, walletConnect];
    const requestA = deferred();
    harness.connectAsync.mockImplementationOnce(() => requestA.promise);
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    fireEvent.click(screen.getByRole("button", {name: /Alpha Wallet/}));
    expect(await screen.findByRole("status")).toBeInTheDocument();
    expect(screen.queryByRole("button", {name: /Beta Wallet/})).not.toBeInTheDocument();
    expect(screen.queryByRole("button", {name: "Connect wallet"})).not.toBeInTheDocument();
    await act(async () => requestA.resolve({accounts: ["0xa1"], chainId: 11155111}));
    expect(harness.connectAsync).toHaveBeenCalledTimes(1);
    expect(harness.connectAsync).toHaveBeenCalledWith({connector: alpha});
    expect(harness.disconnect).not.toHaveBeenCalled();
  });

  it("clears on a refusal and says so", async () => {
    harness.connectors = [injected, rabby, walletConnect];
    const request = deferred();
    harness.connectAsync.mockImplementationOnce(() => request.promise);
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    fireEvent.click(screen.getByRole("button", {name: /Rabby Wallet/}));
    await act(async () => request.reject(rejected("UserRejectedRequestError")));
    expect(getConnectLock()).toBeNull();
    expect(screen.queryByRole("status")).not.toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("The connection was not approved.");
    expect(screen.getByRole("button", {name: "Connect wallet"})).toBeInTheDocument();
  });

  it("clears when WalletConnect's own modal is closed, without calling that a failure", async () => {
    harness.connectors = [injected, walletConnect];
    const request = deferred();
    harness.connectAsync.mockImplementationOnce(() => request.promise);
    await mount();
    fireEvent.click(screen.getByRole("button", {name: "Connect wallet"}));
    expect(await screen.findByRole("status")).toHaveTextContent("Opening WalletConnect…");
    // wagmi rejects with UserRejectedRequestError when the provider's modal is closed.
    await act(async () => request.reject(rejected("UserRejectedRequestError")));
    expect(getConnectLock()).toBeNull();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByRole("button", {name: "Connect wallet"})).toBeInTheDocument();
  });
});
