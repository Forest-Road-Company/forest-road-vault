/**
 * One open wallet connection request per page.
 *
 * A wallet request cannot be withdrawn: its prompt stays open and can still be approved later, and
 * wagmi then makes that wallet the active connection, whatever the page has shown since. So instead
 * of offering a Cancel the page cannot honour, a second request is never started while one is open.
 * Every connect button, on every screen, reads this one store and shows the pending state while a
 * request is open, and a late approval is then simply the connection the visitor asked for.
 *
 * The lock is taken when a request starts and released when that request settles, approved or
 * refused, by the promise itself rather than by the button that started it: a button that unmounts
 * on a client-side navigation cannot strand it, and only the request that took it can release it.
 *
 * The buttons are client components but are also rendered on the server, where this module is
 * shared by every request. The store is therefore written only from click handlers in the browser,
 * never during render, and the server snapshot is always "no request open".
 */

export type ConnectLock<C> = {id: number; connector: C};

/** Releases an abandoned connect prompt (e.g. closed mobile QR / swallowed wallet reject) after 60s. */
export const CONNECT_LOCK_STALE_MS = 60_000;

let current: ConnectLock<unknown> | null = null;
let staleTimer: ReturnType<typeof setTimeout> | null = null;
let seq = 0;
const listeners = new Set<() => void>();

function changed(): void {
  for (const listener of listeners) listener();
}

function clearTimer(): void {
  if (staleTimer !== null) {
    clearTimeout(staleTimer);
    staleTimer = null;
  }
}

/** For useSyncExternalStore. */
export function subscribeConnectLock(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** The open request, if any. */
export function getConnectLock<C>(): ConnectLock<C> | null {
  return current as ConnectLock<C> | null;
}

/** The server render never has an open request. */
export function getServerConnectLock(): null {
  return null;
}

export type LockedOutcome = {ok: true} | {ok: false; error: unknown};

/**
 * Starts `connect` for `connector` if no request is open, holding the lock until it settles or
 * becomes stale (`timeoutMs`, default 60s). Returns null, and starts nothing, while another
 * request is open.
 */
export function startLockedConnect<C>(
  connector: C,
  connect: () => Promise<unknown>,
  timeoutMs: number = CONNECT_LOCK_STALE_MS,
): {id: number; settled: Promise<LockedOutcome>} | null {
  // Called from click handlers only. A server render shares this module across requests and must
  // never hold a visitor's lock, so it cannot take one.
  if (typeof window === "undefined") return null;
  if (current) return null;
  const id = ++seq;
  current = {id, connector};
  clearTimer();
  if (timeoutMs > 0 && Number.isFinite(timeoutMs)) {
    staleTimer = setTimeout(() => {
      if (current?.id === id) {
        current = null;
        staleTimer = null;
        changed();
      }
    }, timeoutMs);
  }
  changed();
  const settled = Promise.resolve()
    .then(connect)
    .then(
      (): LockedOutcome => ({ok: true}),
      (error: unknown): LockedOutcome => ({ok: false, error}),
    )
    .finally(() => {
      // Only the request that took the lock releases it.
      if (current?.id === id) {
        clearTimer();
        current = null;
        changed();
      }
    });
  return {id, settled};
}

/** Clears the lock. Tests only. */
export function resetConnectLock(): void {
  clearTimer();
  current = null;
  changed();
}
