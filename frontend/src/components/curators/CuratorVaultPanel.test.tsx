import {act, cleanup, fireEvent, render, screen, waitFor} from "@testing-library/react";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {CuratorVaultPanel} from "@/components/curators/CuratorVaultPanel";

const harness = vi.hoisted(() => ({
  connect: vi.fn<() => Promise<void>>(),
  select: vi.fn(),
}));

vi.mock("@/config/curatorVault", () => ({
  CURATOR_VAULT: {
    configured: true,
    cluster: "devnet",
    isDevnet: true,
    programId: "11111111111111111111111111111111",
    mint: "11111111111111111111111111111111",
    rpcUrl: "https://api.devnet.solana.com",
    decimals: 6,
    explorer: (address: string) => address,
    explorerTx: (signature: string) => signature,
  },
}));

vi.mock("@anchor-lang/core", () => ({
  AnchorProvider: class AnchorProvider {},
  BN: class BN {},
  EventParser: class EventParser {},
  Program: class Program {
    account = {
      config: {fetch: vi.fn()},
      position: {fetchNullable: vi.fn()},
    };
    coder = {};
    methods = {};
  },
}));

vi.mock("@solana/spl-token", () => ({
  createAssociatedTokenAccountIdempotentInstruction: vi.fn(),
  getAssociatedTokenAddressSync: vi.fn(),
}));

vi.mock("@solana/wallet-adapter-react", async () => {
  const React = await import("react");
  const adapter = {name: "WalletConnect"};
  const selected = {adapter};
  const connection = {getGenesisHash: vi.fn(async () => "wrong-cluster-for-disconnected-test")};
  const connectionResult = {connection};

  return {
    useConnection: () => connectionResult,
    useWallet: () => {
      const [wallet, setWallet] = React.useState<typeof selected | null>(null);
      const [connecting, setConnecting] = React.useState(false);
      const select = React.useCallback((name: string) => {
        harness.select(name);
        setWallet(selected);
      }, []);
      const connect = React.useCallback(async () => {
        setConnecting(true);
        try {
          await harness.connect();
        } finally {
          setConnecting(false);
        }
      }, []);
      return {
        publicKey: null,
        wallet,
        wallets: [selected],
        select,
        connect,
        connected: false,
        connecting,
        disconnect: vi.fn(),
        sendTransaction: vi.fn(),
      };
    },
  };
});

beforeEach(() => {
  harness.connect.mockReset();
  harness.select.mockReset();
});

afterEach(cleanup);

describe("Solana WalletConnect cancellation", () => {
  it("restores the connect control after the adapter rejects a cancelled QR session", async () => {
    let rejectFirst!: (reason: Error) => void;
    const firstAttempt = new Promise<void>((_resolve, reject) => {
      rejectFirst = reject;
    });
    harness.connect
      .mockImplementationOnce(() => firstAttempt)
      .mockImplementation(() => new Promise<void>(() => {}));

    render(<CuratorVaultPanel />);
    const button = await screen.findByRole("button", {name: "WalletConnect"});
    fireEvent.click(button);

    expect(harness.select).toHaveBeenCalledWith("WalletConnect");
    expect(await screen.findByRole("button", {name: "Connecting…"})).toBeDisabled();
    await waitFor(() => expect(harness.connect).toHaveBeenCalledOnce());

    await act(async () => rejectFirst(new Error("User closed the QR modal")));

    await waitFor(() => expect(screen.getByRole("button", {name: "WalletConnect"})).toBeEnabled());
    expect(harness.connect).toHaveBeenCalledOnce();
  });
});
