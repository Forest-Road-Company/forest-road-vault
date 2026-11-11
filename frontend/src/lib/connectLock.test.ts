import {afterEach, describe, expect, it, vi} from "vitest";
import {getConnectLock, getServerConnectLock, resetConnectLock, startLockedConnect, subscribeConnectLock} from "@/lib/connectLock";

function deferred() {
  let resolve!: (value?: unknown) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return {promise, resolve, reject};
}

afterEach(() => resetConnectLock());

describe("the page-wide connect lock", () => {
  it("allows one open request, and releases it when the request is approved", async () => {
    const changes = vi.fn();
    const unsubscribe = subscribeConnectLock(changes);
    const request = deferred();
    const first = startLockedConnect("alpha", () => request.promise);
    expect(first).not.toBeNull();
    expect(getConnectLock()).toEqual({id: first!.id, connector: "alpha"});
    // A second wallet is never asked while the first request is open.
    const connectBeta = vi.fn(async () => undefined);
    expect(startLockedConnect("beta", connectBeta)).toBeNull();
    expect(connectBeta).not.toHaveBeenCalled();
    request.resolve();
    expect(await first!.settled).toEqual({ok: true});
    expect(getConnectLock()).toBeNull();
    expect(changes).toHaveBeenCalledTimes(2);
    unsubscribe();
  });

  it("releases the lock when the request is refused, and reports why", async () => {
    const error = new Error("User rejected the request.");
    const started = startLockedConnect("alpha", () => Promise.reject(error));
    expect(await started!.settled).toEqual({ok: false, error});
    expect(getConnectLock()).toBeNull();
  });

  it("releases the lock when connect throws before returning a promise", async () => {
    const started = startLockedConnect("alpha", () => {
      throw new Error("no provider");
    });
    expect((await started!.settled).ok).toBe(false);
    expect(getConnectLock()).toBeNull();
  });

  it("is released only by the request that took it", async () => {
    const stale = deferred();
    const first = startLockedConnect("alpha", () => stale.promise);
    resetConnectLock(); // as if the first request's lock had been cleared some other way
    const second = startLockedConnect("beta", () => new Promise(() => undefined));
    stale.resolve();
    await first!.settled;
    expect(getConnectLock()).toEqual({id: second!.id, connector: "beta"});
  });

  it("reports no open request on the server, and cannot be taken there", async () => {
    expect(getServerConnectLock()).toBeNull();
    const {renderToString} = await import("react-dom/server");
    const {createElement, useSyncExternalStore} = await import("react");
    function Probe() {
      const lock = useSyncExternalStore(subscribeConnectLock, getConnectLock, getServerConnectLock);
      return createElement("span", null, lock ? "locked" : "unlocked");
    }
    const started = startLockedConnect("alpha", () => new Promise(() => undefined));
    expect(started).not.toBeNull();
    // Even with a request open in this browser, the server snapshot is "unlocked".
    expect(renderToString(createElement(Probe))).toContain("unlocked");
    resetConnectLock();
    const window = globalThis.window;
    vi.stubGlobal("window", undefined);
    try {
      expect(startLockedConnect("alpha", () => new Promise(() => undefined))).toBeNull();
      expect(getConnectLock()).toBeNull();
    } finally {
      vi.stubGlobal("window", window);
      vi.unstubAllGlobals();
    }
  });
});
