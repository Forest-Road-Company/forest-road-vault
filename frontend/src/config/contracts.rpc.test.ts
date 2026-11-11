// @vitest-environment node
import {afterEach, describe, expect, it, vi} from "vitest";

/**
 * Which browser RPC setting each build profile accepts (contracts.ts evaluates at import).
 *
 * Mainnet accepts only the proxy literal `/api/rpc`, so a keyed provider URL can never return to the
 * bundle. Sepolia and the local fork keep their earlier rules.
 */

const MAINNET_ADDRESS_ENV = [
  "NEXT_PUBLIC_USDFR_ADDRESS",
  "NEXT_PUBLIC_SUSDFR_ADDRESS",
  "NEXT_PUBLIC_COMPLIANCE_REGISTRY_ADDRESS",
  "NEXT_PUBLIC_MINT_REDEEM_CONTROLLER_ADDRESS",
  "NEXT_PUBLIC_RESERVE_MANAGER_ADDRESS",
  "NEXT_PUBLIC_REDEMPTION_QUEUE_ADDRESS",
  "NEXT_PUBLIC_CLAIM_BRIDGE_ADDRESS",
  "NEXT_PUBLIC_COLLATERAL_REGISTRY_ADDRESS",
  "NEXT_PUBLIC_CURATOR_MODULE_ADDRESS",
  "NEXT_PUBLIC_WATERFALL_ENGINE_ADDRESS",
  "NEXT_PUBLIC_DEFAULT_MANAGER_ADDRESS",
  "NEXT_PUBLIC_ASSESSED_IMPAIRMENT_SOURCE_ADDRESS",
  "NEXT_PUBLIC_ATTESTATION_ORACLE_ADDRESS",
  "NEXT_PUBLIC_POINTS_MODULE_ADDRESS",
  "NEXT_PUBLIC_GROVE_ADDRESS",
  "NEXT_PUBLIC_SGROVE_ADDRESS",
  "NEXT_PUBLIC_GROVE_VOTES_AGGREGATOR_ADDRESS",
  "NEXT_PUBLIC_GOVERNOR_ADDRESS",
  "NEXT_PUBLIC_TIMELOCK_ADDRESS",
  "NEXT_PUBLIC_MTM_EXECUTOR_ADDRESS",
];

const PROXY_REQUIRED = "A mainnet build requires NEXT_PUBLIC_RPC_URL to be exactly /api/rpc";

function stubMainnet(rpcUrl: string | undefined) {
  vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "1");
  vi.stubEnv("NEXT_PUBLIC_PROTOCOL_DEPLOYMENT_BLOCK", "25768251");
  vi.stubEnv("NEXT_PUBLIC_MAINNET_DEPLOYMENT_HASH", `0x${"ab".repeat(32)}`);
  vi.stubEnv("NEXT_PUBLIC_MAINNET_MANIFEST_SHA256", "cd".repeat(32));
  vi.stubEnv("NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION", "1");
  MAINNET_ADDRESS_ENV.forEach((name, index) => vi.stubEnv(name, `0x${(index + 0x100).toString(16).padStart(40, "0")}`));
  vi.stubEnv("NEXT_PUBLIC_RPC_URL", rpcUrl ?? "");
}

async function loadContracts() {
  vi.resetModules();
  return import("@/config/contracts");
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("mainnet: the browser RPC must be the same-origin proxy", () => {
  it("accepts exactly /api/rpc and reports proxy mode", async () => {
    stubMainnet("/api/rpc");
    const config = await loadContracts();
    expect(config.IS_MAINNET).toBe(true);
    expect(config.RPC_PROXY_MODE).toBe(true);
    expect(config.RPC_URL).toBe("/api/rpc");
  });

  it.each([
    ["a keyed provider URL", "https://eth-mainnet.g.alchemy.com/v2/SOMEKEY"],
    ["a public keyless URL", "https://ethereum-rpc.publicnode.com"],
    ["an absolute URL to the proxy", "https://forestroadvault.com/api/rpc"],
    ["a trailing slash", "/api/rpc/"],
    ["surrounding space", " /api/rpc"],
    ["a different case", "/API/RPC"],
    ["nothing", undefined],
  ])("refuses %s", async (_, rpcUrl) => {
    stubMainnet(rpcUrl);
    await expect(loadContracts()).rejects.toThrow(PROXY_REQUIRED);
  });

  it("still refuses a loopback URL with the local-fork message first", async () => {
    stubMainnet("http://127.0.0.1:8545");
    await expect(loadContracts()).rejects.toThrow("A loopback RPC must use the dedicated local-fork chain ID 31337");
  });
});

describe("Sepolia: unchanged, and proxy mode is optional", () => {
  it.each([
    ["a direct URL", "https://sepolia-rpc.test.invalid/v1", false],
    ["no URL (viem's chain default)", undefined, false],
    ["the proxy", "/api/rpc", true],
  ])("accepts %s", async (_, rpcUrl, proxy) => {
    vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "11155111");
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", rpcUrl ?? "");
    const config = await loadContracts();
    expect(config.RPC_PROXY_MODE).toBe(proxy);
  });

  it("still refuses a loopback URL", async () => {
    vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "11155111");
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", "http://localhost:8545");
    await expect(loadContracts()).rejects.toThrow("A loopback RPC must use the dedicated local-fork chain ID 31337");
  });
});

describe("local fork: unchanged, loopback only", () => {
  it("accepts a loopback URL", async () => {
    vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "31337");
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", "http://127.0.0.1:8545");
    const config = await loadContracts();
    expect(config.IS_LOCAL_FORK).toBe(true);
    expect(config.RPC_PROXY_MODE).toBe(false);
  });

  it.each([["the proxy", "/api/rpc"], ["a remote URL", "https://sepolia-rpc.test.invalid/v1"], ["nothing", ""]])(
    "refuses %s",
    async (_, rpcUrl) => {
      vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "31337");
      vi.stubEnv("NEXT_PUBLIC_RPC_URL", rpcUrl);
      await expect(loadContracts()).rejects.toThrow(
        "A local-fork build requires NEXT_PUBLIC_RPC_URL to be localhost or a loopback address.",
      );
    },
  );
});

describe("server-side archive reads never borrow the proxy path", () => {
  async function archive(rpcUrl: string, archiveUrl = "") {
    vi.stubEnv("NEXT_PUBLIC_CHAIN_ID", "11155111");
    vi.stubEnv("NEXT_PUBLIC_RPC_URL", rpcUrl);
    vi.stubEnv("ETHEREUM_ARCHIVE_RPC_URL", archiveUrl);
    vi.resetModules();
    const {archiveRpcUrl} = await import("@/lib/transparencyHistory.server");
    return archiveRpcUrl;
  }

  it("a Sepolia proxy-mode build needs its own archive RPC, and says so by name", async () => {
    const archiveRpcUrl = await archive("/api/rpc");
    expect(() => archiveRpcUrl()).toThrow(
      "ETHEREUM_ARCHIVE_RPC_URL is required when the browser RPC is the same-origin proxy",
    );
  });

  it("a Sepolia direct-URL build still falls back to the browser RPC, as before", async () => {
    const archiveRpcUrl = await archive("https://sepolia-rpc.test.invalid/v1");
    expect(archiveRpcUrl()).toBe("https://sepolia-rpc.test.invalid/v1");
  });

  it("a configured archive RPC is used in proxy mode", async () => {
    const archiveRpcUrl = await archive("/api/rpc", "https://archive.test.invalid/v1");
    expect(archiveRpcUrl()).toBe("https://archive.test.invalid/v1");
  });
});
