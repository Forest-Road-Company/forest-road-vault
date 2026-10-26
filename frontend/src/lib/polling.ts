/**
 * How often the site re-reads chain state. Every open tab reads through the site's one public RPC key, and that
 * provider budget is shared with the protocol's own services, so polling is kept slow and set here in one place:
 * - a user's own transaction refreshes every query at once (useWriteFlow invalidates them all);
 * - returning to a tab refetches anything older than READ_STALE_MS;
 * - a tab in the background does not poll (TanStack Query's refetchIntervalInBackground defaults to false).
 * The Morpho market (whose snapshot must be under 30 s old to act on) and the buy quote keep their own faster timers.
 */

/** Queries younger than this are served from cache on mount and on window focus. */
export const READ_STALE_MS = 60_000;

/** A connected user's own balances, allowances, positions and points. */
export const ACCOUNT_POLL = {refetchInterval: 120_000} as const;

/** Redemption-queue state that moves without the user (epoch boundaries, keeper settlements). */
export const QUEUE_POLL = {refetchInterval: 120_000} as const;

/** Protocol-wide figures: supply, reserves, book economics, collateral value, the transparency dashboard. */
export const PROTOCOL_POLL = {refetchInterval: 300_000} as const;

/** Points served by the site's own API routes, which read the chain on the server. */
export const POINTS_API_POLL = {refetchInterval: 300_000} as const;

/** How often an event watcher over HTTP polls for new logs (wagmi's default is 4 s). */
export const EVENT_WATCH_POLL_MS = 60_000;

/** How often a connected wallet's RPC is re-checked against the site's. */
export const RPC_ALIGNMENT_POLL_MS = 60_000;
