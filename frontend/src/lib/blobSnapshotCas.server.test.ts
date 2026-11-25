import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {BlobPreconditionFailedError} from "@vercel/blob";

const {getBlobMock, putBlobMock, delBlobMock} = vi.hoisted(() => ({
  getBlobMock: vi.fn(),
  putBlobMock: vi.fn(),
  delBlobMock: vi.fn(),
}));

vi.mock("@vercel/blob", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@vercel/blob")>();
  return {
    ...actual,
    get: getBlobMock,
    put: putBlobMock,
    del: delBlobMock,
  };
});

import {blobMorphoHistoryStore, resetMorphoPointsCache} from "./morphoPoints.server";
import {blobDiscoverySnapshotStore, resetPointsLeaderboardCache} from "./pointsLeaderboard.server";
import {blobTransparencySnapshotStore, resetTransparencyHistoryCacheForTests} from "./transparencyHistory.server";

function blobResponse(payload: unknown, etag: string) {
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(bytes);
      controller.close();
    },
  });
  return {
    statusCode: 200,
    stream,
    blob: {etag},
  };
}

describe("Vercel Blob CAS conflict recovery across all three snapshot stores", () => {
  const originalToken = process.env.BLOB_READ_WRITE_TOKEN;

  beforeEach(() => {
    process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_test_token";
    getBlobMock.mockReset();
    putBlobMock.mockReset();
    delBlobMock.mockReset();
    resetMorphoPointsCache();
    resetPointsLeaderboardCache();
    resetTransparencyHistoryCacheForTests();
  });

  afterEach(() => {
    if (originalToken === undefined) delete process.env.BLOB_READ_WRITE_TOKEN;
    else process.env.BLOB_READ_WRITE_TOKEN = originalToken;
  });

  it("morphoPoints: refreshes ETag on 412 CAS conflict and retries when local cursor is ahead", async () => {
    const store = blobMorphoHistoryStore()!;
    expect(store).toBeDefined();
    const key = "market:100:oracle:pts:100";

    // Cold load observes E1 at block 200.
    getBlobMock.mockResolvedValueOnce(
      blobResponse(
        {
          version: 1,
          key,
          epochsScannedTo: "200",
          epochs: [],
          scannedTo: "200",
          events: [],
          owners: [],
          balances: [],
        },
        "E1",
      ),
    );
    await store.load(key);

    // Another lambda advanced the blob to E2 at block 210. First put with stale E1 hits 412.
    putBlobMock
      .mockRejectedValueOnce(new BlobPreconditionFailedError())
      .mockResolvedValueOnce({etag: "E3"});
    getBlobMock.mockResolvedValueOnce(
      blobResponse(
        {
          version: 1,
          key,
          epochsScannedTo: "210",
          epochs: [],
          scannedTo: "210",
          events: [],
          owners: [],
          balances: [],
        },
        "E2",
      ),
    );

    const saved = await store.save(key, {
      epochsScannedTo: 220n,
      epochs: [],
      scannedTo: 220n,
      events: [],
      owners: [],
      balances: [],
    });
    expect(saved).toBe(true);
    expect(putBlobMock).toHaveBeenCalledTimes(2);
    expect(putBlobMock.mock.calls[0]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E1"});
    expect(putBlobMock.mock.calls[1]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E2"});

    // Subsequent save uses freshly refreshed E3 without wedging.
    putBlobMock.mockResolvedValueOnce({etag: "E4"});
    const savedNext = await store.save(key, {
      epochsScannedTo: 230n,
      epochs: [],
      scannedTo: 230n,
      events: [],
      owners: [],
      balances: [],
    });
    expect(savedNext).toBe(true);
    expect(putBlobMock.mock.calls[2]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E3"});
  });

  it("morphoPoints: adopts remote ETag without overwriting when another lambda is already ahead", async () => {
    const store = blobMorphoHistoryStore()!;
    const key = "market:100:oracle:pts:100";

    // Cold load failed (timeout) leaving observedBlobEtag = null.
    getBlobMock.mockRejectedValueOnce(new Error("timeout"));
    expect(await store.load(key)).toBeNull();

    // Save attempts allowOverwrite: false, hits "already exists", reads remote at block 300 (E2).
    putBlobMock.mockRejectedValueOnce(new Error("This blob already exists"));
    getBlobMock.mockResolvedValueOnce(
      blobResponse(
        {
          version: 1,
          key,
          epochsScannedTo: "300",
          epochs: [],
          scannedTo: "300",
          events: [],
          owners: [],
          balances: [],
        },
        "E2",
      ),
    );

    const saved = await store.save(key, {
      epochsScannedTo: 250n,
      epochs: [],
      scannedTo: 250n,
      events: [],
      owners: [],
      balances: [],
    });
    expect(saved).toBe(true);
    expect(putBlobMock).toHaveBeenCalledTimes(1);
    expect(putBlobMock.mock.calls[0]?.[2]).toMatchObject({allowOverwrite: false});

    // Once local catches up past 300, it uses refreshed E2 with ifMatch cleanly.
    putBlobMock.mockResolvedValueOnce({etag: "E3"});
    const savedLater = await store.save(key, {
      epochsScannedTo: 310n,
      epochs: [],
      scannedTo: 310n,
      events: [],
      owners: [],
      balances: [],
    });
    expect(savedLater).toBe(true);
    expect(putBlobMock.mock.calls[1]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E2"});
  });

  it("pointsLeaderboard: recovers from both cold-load failure and post-delete conflict without wedging", async () => {
    const store = blobDiscoverySnapshotStore()!;
    const key = "u:s:p:c:100";

    // Empty-string etag from getBlob must normalize to null (allowOverwrite: false), never unguarded overwrite.
    getBlobMock.mockResolvedValueOnce(
      blobResponse({version: 1, key, scannedTo: "150", wallets: [], curators: []}, ""),
    );
    await store.load(key);

    // Put with allowOverwrite: false conflicts because blob exists; conflict read refreshes real etag E5 and retries.
    putBlobMock
      .mockRejectedValueOnce(new Error("This blob already exists"))
      .mockResolvedValueOnce({etag: "E6"});
    getBlobMock.mockResolvedValueOnce(
      blobResponse({version: 1, key, scannedTo: "150", wallets: [], curators: []}, "E5"),
    );

    const saved = await store.save({version: 1, key, scannedTo: "200", wallets: [], curators: []});
    expect(saved).toBe(true);
    expect(putBlobMock.mock.calls[0]?.[2]).toMatchObject({allowOverwrite: false});
    expect(putBlobMock.mock.calls[1]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E5"});

    // Another lambda deleted the blob (clear): our stale E6 hits 412, remote returns null, retries allowOverwrite: false.
    putBlobMock
      .mockRejectedValueOnce(new BlobPreconditionFailedError())
      .mockResolvedValueOnce({etag: "E7"});
    getBlobMock.mockResolvedValueOnce(null);

    const savedAfterDelete = await store.save({version: 1, key, scannedTo: "210", wallets: [], curators: []});
    expect(savedAfterDelete).toBe(true);
    expect(putBlobMock.mock.calls[2]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E6"});
    expect(putBlobMock.mock.calls[3]?.[2]).toMatchObject({allowOverwrite: false});
  });

  it("transparencyHistory: recovers from 412 CAS conflict and refuses to downgrade a newer remote finalizedBlock", async () => {
    const store = blobTransparencySnapshotStore();
    if (!store) return; // local fork intentionally disables Blob persistence
    const key = "chain-1:v:r:c:f:w";
    const emptyEvents = {
      originated: [],
      funded: [],
      losses: [],
      originationFees: [],
      distributions: [],
      performanceFees: [],
      managementFees: [],
    };

    // Cold load sees E1 at finalizedBlock 1000.
    getBlobMock.mockResolvedValueOnce(
      blobResponse({version: 1, key, finalizedBlock: "1000", events: emptyEvents}, "E1"),
    );
    await store.load(key);

    // Concurrent instance advanced to 1050 (E2). Local trying to save 1020 hits 412, reads remote 1050, does NOT overwrite.
    putBlobMock.mockRejectedValueOnce(new BlobPreconditionFailedError());
    getBlobMock.mockResolvedValueOnce(
      blobResponse({version: 1, key, finalizedBlock: "1050", events: emptyEvents}, "E2"),
    );
    const adopted = await store.save(key, {finalizedBlock: 1020n, events: emptyEvents});
    expect(adopted).toBe(true);
    expect(putBlobMock).toHaveBeenCalledTimes(1);

    // Later local advances to 1080 and succeeds cleanly using refreshed E2.
    putBlobMock.mockResolvedValueOnce({etag: "E3"});
    const advanced = await store.save(key, {finalizedBlock: 1080n, events: emptyEvents});
    expect(advanced).toBe(true);
    expect(putBlobMock.mock.calls[1]?.[2]).toMatchObject({allowOverwrite: true, ifMatch: "E2"});
  });
});
