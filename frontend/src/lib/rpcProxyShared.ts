/**
 * Constants shared by the browser transport and the server-side RPC proxy route.
 *
 * Browser safe: nothing here is secret. The provider URL the proxy forwards to lives only in the
 * server-only `RPC_PROXY_UPSTREAM_URL` and is read by `rpcProxy.server.ts` at request time.
 */

/** The exact value of NEXT_PUBLIC_RPC_URL that selects proxy mode, and the route's path. */
export const RPC_PROXY_PATH = "/api/rpc";

/** The most JSON-RPC entries one proxied request may carry. The browser batches to this size. */
export const RPC_PROXY_MAX_BATCH = 20;

/** The largest request body, declared or actual, that the proxy reads: 256 KiB. */
export const RPC_PROXY_MAX_BODY_BYTES = 256 * 1024;

/** How long the proxy waits for the upstream to answer a forwarded request. */
export const RPC_PROXY_UPSTREAM_TIMEOUT_MS = 20_000;

/** How long the proxy waits for its one-time eth_chainId check. */
export const RPC_PROXY_CHAIN_PROBE_TIMEOUT_MS = 5_000;

/**
 * The browser transport's timeout in proxy mode. Longer than the proxy's worst case (a cold chain
 * check, then the forward: 25 s), so the browser sees the proxy's own answer, 504 included, instead
 * of timing out first and retrying while the first upstream call is still running.
 */
export const RPC_PROXY_BROWSER_TIMEOUT_MS = 30_000;
