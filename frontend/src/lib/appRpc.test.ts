import {afterEach, describe, expect, it, vi} from "vitest";
import {HttpConnection} from "@walletconnect/jsonrpc-http-connection";
import {sepolia} from "viem/chains";
import {RPC_PROXY_PATH} from "@/lib/rpcProxyShared";

/**
 * The read transport in a browser (jsdom): which URL each build mode hands viem and Wagmi.
 * Wagmi gives the WalletConnect provider `transport.value.url` as its read RPC (extractRpcUrls),
 * so that value is what is asserted.
 */

async function freshAppRpc(rpcUrl: string | undefined) {
  if (rpcUrl === undefined) vi.stubEnv("NEXT_PUBLIC_RPC_URL", "");
  else vi.stubEnv("NEXT_PUBLIC_RPC_URL", rpcUrl);
  vi.resetModules();
  return import("@/lib/appRpc");
}

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe("the browser read transport", () => {
  it("proxy mode resolves /api/rpc against the page's own origin and batches", async () => {
    const {appTransport} = await freshAppRpc(RPC_PROXY_PATH);
    const transport = appTransport()({chain: sepolia});
    expect(window.location.origin).toMatch(/^https?:\/\//);
    expect(transport.value?.url).toBe(`${window.location.origin}${RPC_PROXY_PATH}`);
    expect(transport.config.type).toBe("http");
  });

  it("a direct Sepolia URL is used unchanged and unbatched", async () => {
    const direct = "https://sepolia-rpc.test.invalid/v1";
    const {appTransport} = await freshAppRpc(direct);
    const transport = appTransport()({chain: sepolia});
    expect(transport.value?.url).toBe(direct);
  });

  it("an unset Sepolia RPC still falls back to the chain's default, as before", async () => {
    const {appTransport} = await freshAppRpc(undefined);
    expect(appTransport()({chain: sepolia}).value?.url).toBe(sepolia.rpcUrls.default.http[0]);
  });

  it("only the exact literal selects proxy mode", async () => {
    for (const nearMiss of ["/api/rpc/", "/api/rpc?x=1", "/API/RPC"]) {
      const {appTransport} = await freshAppRpc(nearMiss);
      expect(appTransport()({chain: sepolia}).value?.url).toBe(nearMiss);
    }
  });

  it("WalletConnect's read connection accepts the resolved URL and refuses the bare path", async () => {
    const {resolveProxyUrl} = await freshAppRpc(RPC_PROXY_PATH);
    expect(() => new HttpConnection(resolveProxyUrl(window.location.origin))).not.toThrow();
    expect(() => new HttpConnection(RPC_PROXY_PATH)).toThrow("not compatible with HTTP connection");
  });

  it("refuses an opaque or non-web page origin rather than guessing", async () => {
    const {resolveProxyUrl} = await freshAppRpc(RPC_PROXY_PATH);
    expect(() => resolveProxyUrl("null")).toThrow();
    expect(() => resolveProxyUrl("file:///tmp/index.html")).toThrow("http(s) page origin");
    expect(resolveProxyUrl("https://www.forestroadvault.com")).toBe("https://www.forestroadvault.com/api/rpc");
  });
});
