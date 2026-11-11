import {afterEach, describe, expect, it, vi} from "vitest";
import {EthereumProvider} from "@walletconnect/ethereum-provider";
import {UniversalProvider} from "@walletconnect/universal-provider";
import {walletConnect} from "wagmi/connectors/walletConnect";
import {RPC_PROXY_PATH} from "@/lib/rpcProxyShared";

/**
 * WalletConnect sessions are restored with the read RPC URL saved when they were made. The RPC proxy
 * cutover changes that URL, so the site moves its WalletConnect storage to a new namespace: sessions
 * from before the cutover are never restored (their saved URL is the provider's keyed one), and an
 * older deployment never restores a session made on this one. These tests pin the option and that
 * the installed Wagmi and WalletConnect versions carry it all the way to WalletConnect's storage.
 */

const PROJECT_ID = "0123456789abcdef0123456789abcdef";
const PREVIOUS_PREFIX = "forest-road-vault";

/** Stands in for a provider so no test opens a WalletConnect relay connection. */
const fakeProvider = () =>
  ({
    events: {setMaxListeners: () => undefined},
    on: () => undefined,
    off: () => undefined,
    removeListener: () => undefined,
    accounts: [],
    session: undefined,
  }) as unknown as Awaited<ReturnType<typeof EthereumProvider.init>>;

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  vi.resetModules();
  vi.doUnmock("wagmi/connectors/walletConnect");
});

describe("the site's WalletConnect connector", () => {
  it("uses a storage namespace other than the one sessions were saved under before the cutover", async () => {
    vi.stubEnv("NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID", PROJECT_ID);
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", RPC_PROXY_PATH);
    vi.resetModules();
    vi.spyOn(EthereumProvider, "init").mockImplementation(async () => fakeProvider());
    const captured: Record<string, unknown>[] = [];
    vi.doMock("wagmi/connectors/walletConnect", async (importOriginal) => {
      const original = await importOriginal<typeof import("wagmi/connectors/walletConnect")>();
      return {
        walletConnect: (parameters: Parameters<typeof original.walletConnect>[0]) => {
          captured.push(parameters as unknown as Record<string, unknown>);
          return original.walletConnect(parameters);
        },
      };
    });
    const {WALLETCONNECT_STORAGE_PREFIX} = await import("@/lib/wagmi");
    expect(captured).toHaveLength(1);
    expect(captured[0].customStoragePrefix).toBe(WALLETCONNECT_STORAGE_PREFIX);
    expect(WALLETCONNECT_STORAGE_PREFIX).toBe("forest-road-vault-rpc-proxy-2026-11");
    expect(WALLETCONNECT_STORAGE_PREFIX).not.toBe(PREVIOUS_PREFIX);
    expect(captured[0].projectId).toBe(PROJECT_ID);
  });

  it("hands WalletConnect the prefix and the absolute same-origin proxy as its read RPC", async () => {
    vi.stubEnv("NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID", PROJECT_ID);
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", RPC_PROXY_PATH);
    vi.resetModules();
    const init = vi.spyOn(EthereumProvider, "init").mockImplementation(async () => fakeProvider());
    const {wagmiConfig, WALLETCONNECT_STORAGE_PREFIX} = await import("@/lib/wagmi");
    const connector = wagmiConfig.connectors.find((candidate) => candidate.id === "walletConnect");
    expect(connector).toBeDefined();
    await connector!.getProvider();
    expect(init).toHaveBeenCalled();
    const options = init.mock.calls[0][0] as {customStoragePrefix?: string; rpcMap?: Record<number, string>};
    expect(options.customStoragePrefix).toBe(WALLETCONNECT_STORAGE_PREFIX);
    expect(options.rpcMap?.[11155111]).toBe(`${window.location.origin}${RPC_PROXY_PATH}`);
  });
});

describe("the installed WalletConnect providers", () => {
  it("Wagmi's connector passes customStoragePrefix through to EthereumProvider.init", async () => {
    const init = vi.spyOn(EthereumProvider, "init").mockImplementation(async () => fakeProvider());
    const create = walletConnect({projectId: PROJECT_ID, customStoragePrefix: "pinned-prefix", showQrModal: false});
    const connector = create({
      chains: [{id: 1, name: "Ethereum", nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18}, rpcUrls: {default: {http: ["https://example.invalid/rpc"]}}}],
      emitter: {emit: () => undefined, on: () => undefined, off: () => undefined, once: () => undefined, listenerCount: () => 0},
      storage: null,
      transports: undefined,
    } as never);
    await connector.getProvider();
    expect((init.mock.calls[0][0] as {customStoragePrefix?: string}).customStoragePrefix).toBe("pinned-prefix");
  });

  it("EthereumProvider passes customStoragePrefix through to the UniversalProvider that keeps the sessions", async () => {
    const signer = {
      on: () => undefined,
      session: undefined,
      namespaces: {},
      client: {core: {storage: {getItem: async () => undefined}}},
    };
    const init = vi.spyOn(UniversalProvider, "init").mockResolvedValue(signer as unknown as Awaited<ReturnType<typeof UniversalProvider.init>>);
    await EthereumProvider.init({
      projectId: PROJECT_ID,
      optionalChains: [1],
      showQrModal: false,
      customStoragePrefix: "pinned-prefix",
      rpcMap: {1: "https://example.invalid/api/rpc"},
    });
    expect(init).toHaveBeenCalledTimes(1);
    expect((init.mock.calls[0][0] as {customStoragePrefix?: string}).customStoragePrefix).toBe("pinned-prefix");
  });
});
