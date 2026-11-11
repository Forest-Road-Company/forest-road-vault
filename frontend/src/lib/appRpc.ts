/**
 * The application's read transport: the one place the browser's RPC endpoint is chosen.
 *
 * In proxy mode (NEXT_PUBLIC_RPC_URL is exactly `/api/rpc`, required on mainnet) every read goes
 * to the site's own route, which forwards to the server-only RPC_PROXY_UPSTREAM_URL. Two details
 * matter and are pinned by tests:
 *
 * 1. The browser resolves the path against `window.location.origin` and hands viem an ABSOLUTE
 *    URL. viem's http transport would accept the bare path (fetch resolves it against the
 *    document), but Wagmi passes the transport's URL to the WalletConnect provider as its read RPC,
 *    and that provider refuses anything that is not an http(s) URL.
 * 2. On the server (no `window`) there is no origin to resolve against, and guessing a host would
 *    send reads somewhere nobody chose. The server transport therefore refuses every request with
 *    a fixed, named error. Server rendering is not expected to read at all (Wagmi's `ssr: true`
 *    and React Query do not fetch during a render); if something ever does, it fails loudly here
 *    instead of silently reading from a guessed host.
 *
 * Proxy-mode reads are batched: concurrent calls share one HTTP request, up to the proxy's
 * 20-entry cap, which saves a round trip per call to the function region.
 */

import {custom, http, type Transport} from "viem";
import {RPC_PROXY_MODE, RPC_URL} from "@/config/contracts";
import {RPC_PROXY_BROWSER_TIMEOUT_MS, RPC_PROXY_MAX_BATCH, RPC_PROXY_PATH} from "@/lib/rpcProxyShared";

/** viem http batching for the proxy: never more entries than the route accepts, a short gather. */
export const RPC_PROXY_BATCH = {batchSize: RPC_PROXY_MAX_BATCH, wait: 10} as const;

export const SERVER_RENDER_RPC_MESSAGE =
  `The browser RPC proxy (${RPC_PROXY_PATH}) is browser-only, but server rendering attempted an RPC read. ` +
  "Server code must use its own server-side RPC; no host is guessed for the proxy.";

/** Thrown, never caught here, when anything reads through the proxy transport during a server render. */
export class ServerRenderRpcError extends Error {
  readonly method: string;

  constructor(method: string) {
    super(`${SERVER_RENDER_RPC_MESSAGE} Method: ${method}.`);
    this.name = "ServerRenderRpcError";
    this.method = method;
  }
}

/** The absolute proxy URL for a page served from `origin`. Refuses an opaque or invalid origin. */
export function resolveProxyUrl(origin: string): string {
  const base = new URL(origin);
  if (base.protocol !== "https:" && base.protocol !== "http:") {
    throw new Error(`The RPC proxy needs an http(s) page origin, not ${base.protocol}`);
  }
  return new URL(RPC_PROXY_PATH, base.origin).toString();
}

function serverRenderRefusal(): Transport {
  return custom(
    {
      async request({method}: {method: string}) {
        const error = new ServerRenderRpcError(method);
        console.error(error.message);
        throw error;
      },
    },
    {key: "rpc-proxy-server-refusal", name: "RPC proxy (server render refusal)", retryCount: 0},
  );
}

export type AppTransportInputs = {
  rpcUrl: string;
  proxyMode: boolean;
  /** `window.location.origin` in a browser, undefined on the server. */
  origin: string | undefined;
};

/** Pure form of {@link appTransport}, for tests. */
export function createAppTransport({rpcUrl, proxyMode, origin}: AppTransportInputs): Transport {
  if (!proxyMode) return http(rpcUrl || undefined);
  if (origin === undefined) return serverRenderRefusal();
  return http(resolveProxyUrl(origin), {batch: RPC_PROXY_BATCH, timeout: RPC_PROXY_BROWSER_TIMEOUT_MS});
}

/** The read transport for this build and this environment (browser or server). */
export function appTransport(): Transport {
  return createAppTransport({
    rpcUrl: RPC_URL,
    proxyMode: RPC_PROXY_MODE,
    origin: typeof window === "undefined" ? undefined : window.location.origin,
  });
}
