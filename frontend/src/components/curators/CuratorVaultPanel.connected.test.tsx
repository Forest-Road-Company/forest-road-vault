import {act, cleanup, fireEvent, render, screen, waitFor} from "@testing-library/react";
import {PublicKey} from "@solana/web3.js";
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {CuratorVaultPanel} from "@/components/curators/CuratorVaultPanel";

const USDC = 1_000_000n;
const DAY = 86_400n;

const harness = vi.hoisted(() => ({
  config: {} as Record<string, unknown>,
  position: {} as Record<string, unknown>,
  balance: 50n * 1_000_000n,
  sent: false,
  failRefreshAfterSend: false,
  configReads: 0,
  walletByte: 7,
  delayStatus: false,
  releaseStatus: null as null | (() => void),
  methodCalls: [] as Array<{name: string; args: unknown[]}>,
}));

vi.mock("@/config/curatorVault", () => ({
  CURATOR_VAULT: {
    configured: true,
    cluster: "devnet",
    isDevnet: true,
    programId: "HNWZdMnKZb4aVxjnF9tHvHNQobZ1fMvbF45Nx5bGsKZL",
    mint: "11111111111111111111111111111111",
    rpcUrl: "https://api.devnet.solana.com",
    decimals: 6,
    explorer: (address: string) => address,
    explorerTx: (signature: string) => signature,
  },
}));

vi.mock("@anchor-lang/core", async () => {
  const {Transaction} = await vi.importActual<typeof import("@solana/web3.js")>("@solana/web3.js");
  class BN {
    constructor(private readonly value: string) {}
    toString() { return this.value; }
  }
  class Program {
    account = {
      config: {
        fetch: vi.fn(async () => {
          harness.configReads += 1;
          if (harness.sent && harness.failRefreshAfterSend) throw new Error("RPC unavailable");
          return harness.config;
        }),
      },
      position: {fetchNullable: vi.fn(async () => harness.position)},
    };
    coder = {};
    methods = new Proxy({}, {
      get: (_target, property) => (...args: unknown[]) => {
        const name = String(property);
        harness.methodCalls.push({name, args});
        return {
          accountsPartial: () => ({transaction: async () => new Transaction()}),
        };
      },
    });
  }
  return {
    AnchorProvider: class AnchorProvider {},
    BN,
    EventParser: class EventParser { *parseLogs() {} },
    Program,
  };
});

vi.mock("@/lib/solanaToken", async () => {
  const {PublicKey, SystemProgram} = await vi.importActual<typeof import("@solana/web3.js")>("@solana/web3.js");
  return {
    getAssociatedTokenAddressSync: () => new PublicKey(new Uint8Array(32).fill(8)),
    createAssociatedTokenAccountIdempotentInstruction: () => ({
      keys: [],
      programId: SystemProgram.programId,
      data: Buffer.alloc(0),
    }),
  };
});

vi.mock("@solana/wallet-adapter-react", async () => {
  const {PublicKey} = await vi.importActual<typeof import("@solana/web3.js")>("@solana/web3.js");
  const publicKeys = new Map<number, PublicKey>();
  const publicKeyFor = (byte: number) => {
    const existing = publicKeys.get(byte);
    if (existing) return existing;
    const created = new PublicKey(new Uint8Array(32).fill(byte));
    publicKeys.set(byte, created);
    return created;
  };
  const connection = {
    getGenesisHash: vi.fn(async () => "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"),
    getTokenAccountBalance: vi.fn(async () => ({value: {amount: harness.balance.toString()}})),
    getSignaturesForAddress: vi.fn(async () => []),
    getTransactions: vi.fn(async () => []),
    getLatestBlockhash: vi.fn(async () => ({
      blockhash: "11111111111111111111111111111111",
      lastValidBlockHeight: 10_000,
    })),
    simulateTransaction: vi.fn(async () => ({value: {err: null, logs: []}})),
    getSignatureStatuses: vi.fn(async () => {
      if (harness.delayStatus) {
        await new Promise<void>((resolve) => {
          harness.releaseStatus = resolve;
        });
      }
      return {value: [{err: null, confirmationStatus: "confirmed"}]};
    }),
    getBlockHeight: vi.fn(async () => 1),
  };
  return {
    useConnection: () => ({connection}),
    useWallet: () => ({
      publicKey: publicKeyFor(harness.walletByte),
      wallet: {adapter: {name: "Fixture"}},
      wallets: [],
      select: vi.fn(),
      connect: vi.fn(),
      connected: true,
      connecting: false,
      disconnect: vi.fn(),
      sendTransaction: vi.fn(async () => {
        harness.sent = true;
        return "fixture-signature";
      }),
    }),
  };
});

function resetBook() {
  harness.config = {
    rateEpochs: [{startTs: 0n, bps: 800}],
    rateEpochCount: 1,
    totalPrincipal: 100n * USDC,
    drawn: 0n,
    paused: false,
    lockSeconds: 90n * DAY,
    noticeSeconds: 90n * DAY,
  };
  harness.position = {
    allowlisted: true,
    agreementHash: Array(32).fill(1),
    lockSeconds: 30n * DAY,
    noticeSeconds: 60n * DAY,
    principal: 100n * USDC,
    drawn: 0n,
    lockEnd: 1n,
    noticeRequestedAt: 0n,
    withdrawalEligibleAt: 1n,
    couponAccruedThrough: 0n,
    couponPaidThrough: 0n,
    couponOwed: 0n,
    couponPayable: 0n,
    couponRemainder: 0n,
    lossesRecorded: 0n,
    payoutHalted: false,
  };
  harness.balance = 50n * USDC;
  harness.sent = false;
  harness.failRefreshAfterSend = false;
  harness.configReads = 0;
  harness.walletByte = 7;
  harness.delayStatus = false;
  harness.releaseStatus = null;
  harness.methodCalls = [];
}

beforeEach(resetBook);
beforeEach(() => {
  vi.spyOn(PublicKey, "findProgramAddressSync").mockReturnValue([
    new PublicKey(new Uint8Array(32).fill(9)),
    255,
  ]);
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

async function waitForBook() {
  await screen.findByText("30 days");
}

describe("connected Solana curator controls", () => {
  it("reads the book once when the cluster check resolves", async () => {
    render(<CuratorVaultPanel />);
    await waitForBook();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(harness.configReads).toBe(1);
  });

  it("ignores wallet A's late confirmation refresh after switching to wallet B", async () => {
    harness.delayStatus = true;
    const view = render(<CuratorVaultPanel />);
    await waitForBook();
    fireEvent.change(screen.getByLabelText("Amount (USDC)"), {target: {value: "1"}});
    fireEvent.click(screen.getByRole("button", {name: "Deposit"}));
    await waitFor(() => expect(harness.releaseStatus).not.toBeNull());

    harness.walletByte = 6;
    harness.delayStatus = false;
    view.rerender(<CuratorVaultPanel />);
    await waitFor(() => expect(screen.queryByText("Reading the vault…")).not.toBeInTheDocument());

    await act(async () => harness.releaseStatus?.());
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(screen.queryByText("Reading the vault…")).not.toBeInTheDocument();
  });

  it("shows snapshotted terms and agreement evidence and bounds token amounts", async () => {
    harness.position = {
      ...harness.position,
      drawn: 25n * USDC,
      couponOwed: 10n * USDC,
    };
    render(<CuratorVaultPanel />);
    await waitForBook();

    expect(screen.getByText("60 days")).toBeInTheDocument();
    expect(screen.getByText("Principal deployed for this position")).toBeInTheDocument();
    expect(screen.getByText("25.00 USDC")).toBeInTheDocument();
    expect(screen.getByText("Coupon earned and unpaid")).toBeInTheDocument();
    expect(screen.getByText("Coupon payable now")).toBeInTheDocument();
    expect(screen.getByText(`0x${"01".repeat(32)}`)).toBeInTheDocument();
    const input = screen.getByLabelText("Amount (USDC)");
    fireEvent.change(input, {target: {value: "51"}});
    expect(screen.getByRole("button", {name: "Deposit"})).toBeDisabled();
    expect(screen.getByText(/deposit cannot exceed/i)).toBeInTheDocument();

    fireEvent.change(input, {target: {value: "101"}});
    expect(screen.getByRole("button", {name: "Withdraw"})).toBeDisabled();
    expect(screen.getByText(/withdrawal cannot exceed 75.00 USDC/i)).toBeInTheDocument();
  });

  it("disables coupon claims while the position payout halt is set", async () => {
    const now = BigInt(Math.floor(Date.now() / 1000));
    harness.position = {
      ...harness.position,
      couponAccruedThrough: now,
      couponOwed: 10n * USDC,
      couponPayable: 10n * USDC,
      payoutHalted: true,
    };
    render(<CuratorVaultPanel />);
    await waitForBook();

    expect(screen.getByRole("button", {name: "Claim 10.00 USDC"})).toBeDisabled();
  });

  it("exposes close-position only for an empty ledger row", async () => {
    harness.config = {...harness.config, totalPrincipal: 0n};
    harness.position = {
      ...harness.position,
      allowlisted: false,
      principal: 0n,
      lockSeconds: 0n,
      noticeSeconds: 0n,
      withdrawalEligibleAt: 0n,
    };
    render(<CuratorVaultPanel />);
    const close = await screen.findByRole("button", {name: "Close empty position"});
    fireEvent.click(close);

    await waitFor(() => expect(harness.methodCalls.some(({name}) => name === "closePosition")).toBe(true));
  });

  it("does not offer to close a freshly allowlisted empty position", async () => {
    harness.config = {...harness.config, totalPrincipal: 0n};
    harness.position = {
      ...harness.position,
      principal: 0n,
      lockSeconds: 0n,
      noticeSeconds: 0n,
      withdrawalEligibleAt: 0n,
    };
    render(<CuratorVaultPanel />);
    await screen.findByText("Lock term for a new deposit");
    expect(screen.queryByRole("button", {name: "Close empty position"})).not.toBeInTheDocument();
  });

  it("reports a confirmed write as stale when the mandatory post-write read fails", async () => {
    harness.failRefreshAfterSend = true;
    render(<CuratorVaultPanel />);
    await waitForBook();
    fireEvent.change(screen.getByLabelText("Amount (USDC)"), {target: {value: "1"}});
    fireEvent.click(screen.getByRole("button", {name: "Deposit"}));

    expect(await screen.findByText(/Deposit confirmed, but the updated position could not be read/i)).toBeInTheDocument();
    expect(screen.queryByText(/^Deposit confirmed\.$/)).not.toBeInTheDocument();
    expect(screen.getByText(/vault could not be read/i)).toBeInTheDocument();
  });
});
