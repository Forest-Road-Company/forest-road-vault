/**
 * The points route's canonical-wallet redirect through Next.js's real request path (Corrovera
 * MORPHO-17 and M1001B-n3-01).
 *
 * route.test.ts calls the handler directly with a `Request` it builds, so it sees the query exactly
 * as written. A real request does not reach the handler that way: Next.js re-serializes the query
 * first (RouteModule.prepare's normalizeCdnUrl), decoding percent-encoding, dropping empty
 * separators and stripping its own keys. So only the case of the wallet still reaches the redirect,
 * and the other spellings are answered with a cacheable 200 under their own URLs. This test pins
 * that behaviour on the BUILT site under `next start`, so a Next.js upgrade that changes the
 * normalization fails here and the route's comment is revisited.
 *
 * Run after a production build, from frontend/:
 *   NEXT_PUBLIC_CHAIN_ID=11155111 npm run build
 *   npm run test:server
 * With no build (.next/BUILD_ID absent) every case is skipped, except under CI, where that fails.
 * The server binds 127.0.0.1 on a free port and makes no network call: the three market variables
 * are passed present but empty, which no .env file can override (Next.js reads process.env first
 * and stops once a variable is found), so the loader answers {ok: true, enabled: false} on any
 * chain profile without an RPC.
 */
import assert from "node:assert/strict";
import {spawn, type ChildProcess} from "node:child_process";
import {existsSync} from "node:fs";
import {request as httpRequest, type IncomingHttpHeaders} from "node:http";
import {createServer} from "node:net";
import {join} from "node:path";
import {after, before, test} from "node:test";
import {fileURLToPath} from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
const built = existsSync(join(root, ".next", "BUILD_ID"));
const skip = built ? false : "no production build at .next/BUILD_ID: run `npm run build`, then `npm run test:server`";

/** The EIP-55 test vector: its canonical spelling mixes case, so a lowercase spelling differs. */
const CANONICAL = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
/** The same hex with every letter's case flipped: a mixed-case spelling whose checksum is wrong. */
const WRONG_CHECKSUM = "0x5AaEB6053f3e94c9B9a09F33669435e7eF1bEaED";
/** Both wallet routes follow the same canonical-URL rules (MORPHO-17), so both are pinned here. */
const ROUTES = ["/api/points/morpho", "/api/points/pendle"] as const;
const canonicalPath = (route: string) => `${route}?wallet=${CANONICAL}`;
const CANONICAL_PATH = canonicalPath(ROUTES[0]);
const DISABLED = {ok: true, enabled: false};
const percentEncoded = (text: string) =>
  [...text].map((c) => `%${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`).join("");

type Answer = {status: number; headers: IncomingHttpHeaders; body: string};

/** A GET whose path is sent byte for byte: no client-side URL normalization. */
function get(port: number, path: string): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      {host: "127.0.0.1", port, path, method: "GET", agent: false, timeout: 15_000},
      (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk: string) => (body += chunk));
        response.on("end", () => resolve({status: response.statusCode ?? 0, headers: response.headers, body}));
        response.on("error", reject);
      },
    );
    request.on("timeout", () => request.destroy(new Error(`GET ${path}: no answer within 15 s`)));
    request.on("error", reject);
    request.end();
  });
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      const port = typeof address === "object" && address !== null ? address.port : 0;
      probe.close(() => (port > 0 ? resolve(port) : reject(new Error("no free port"))));
    });
  });
}

let server: ChildProcess | undefined;
let port = 0;
let log = "";

async function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  child.kill("SIGTERM");
  const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
  await exited;
  clearTimeout(timer);
}

before(async () => {
  if (!built) return;
  port = await freePort();
  server = spawn(
    process.execPath,
    [join(root, "node_modules", "next", "dist", "bin", "next"), "start", "-H", "127.0.0.1", "-p", String(port)],
    {
      cwd: root,
      env: {
        PATH: process.env.PATH ?? "",
        HOME: process.env.HOME ?? "",
        NODE_ENV: "production",
        NEXT_TELEMETRY_DISABLED: "1",
        // Present but empty, so the loader stays off whatever a local .env file says.
        MORPHO_SUSDFR_MARKET_ID: "",
        MORPHO_SUSDFR_MARKET_FROM_BLOCK: "",
        MORPHO_SUSDFR_ORACLE: "",
        // next.config.ts refuses VERCEL=1 without a commit SHA; a pulled .env file must not set it.
        VERCEL: "",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  server.stdout?.on("data", (chunk: Buffer) => (log += chunk.toString()));
  server.stderr?.on("data", (chunk: Buffer) => (log += chunk.toString()));
  const deadline = Date.now() + 60_000;
  for (;;) {
    try {
      await get(port, CANONICAL_PATH);
      return;
    } catch {
      const failure =
        server.exitCode !== null
          ? `next start exited with ${server.exitCode}`
          : Date.now() > deadline
            ? "next start did not answer within 60 s"
            : null;
      if (failure) {
        await stop(server);
        throw new Error(`${failure}:\n${log}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
}, {timeout: 90_000});

after(async () => {
  if (server) await stop(server);
});

if (!built && process.env.CI) {
  test("a production build exists for the built-server test", () => {
    assert.fail("no production build at frontend/.next: run `npm run build` before `npm run test:server`");
  });
}

for (const ROUTE of ROUTES) {
  test(`${ROUTE}: the canonical URL is answered by the loader with a short CDN cache`, {skip}, async () => {
    const answer = await get(port, canonicalPath(ROUTE));
    assert.equal(answer.status, 200, `canonical: ${answer.status} ${answer.body}\n${log}`);
    assert.deepEqual(JSON.parse(answer.body), DISABLED, "the loader must be off for this test (see the header)");
    assert.equal(answer.headers["cache-control"], "public, s-maxage=60, stale-while-revalidate=300");
  });

  // Each of these is the canonical query in another spelling. The handler would send every one of
  // them to the canonical URL if it saw it as written (route.test.ts), but Next.js normalizes it
  // first, so it is answered under its own URL: a distinct CDN cache key (M1001B-n3-01). If a Next.js
  // upgrade makes one of these a 308 instead, the redirect covers more than case again: update the
  // route's comment, the MORPHO-17 records in docs/ and this list.
  const NORMALIZED_BY_NEXT: [string, string][] = [
    ["a percent-encoded first character", `?wallet=%30x${CANONICAL.slice(2)}`],
    ["a fully percent-encoded value", `?wallet=${percentEncoded(CANONICAL)}`],
    ["a percent-encoded key", `?%77allet=${CANONICAL}`],
    ["a leading separator", `?&wallet=${CANONICAL}`],
    ["a trailing separator", `?wallet=${CANONICAL}&`],
    ["a Next-internal nxtP key", `?wallet=${CANONICAL}&nxtPaudit=1`],
    ["a Next-internal nxtI key", `?wallet=${CANONICAL}&nxtIaudit=1`],
    ["Next's nextInternalLocale key", `?wallet=${CANONICAL}&nextInternalLocale=en`],
  ];

  for (const [name, query] of NORMALIZED_BY_NEXT) {
    test(`${ROUTE}: ${name} is normalized by Next.js and answered with a cacheable 200, not redirected`, {skip}, async () => {
      const answer = await get(port, `${ROUTE}${query}`);
      assert.equal(answer.status, 200, `${query}: ${answer.status} ${answer.headers.location ?? ""} ${answer.body}`);
      assert.equal(answer.headers.location, undefined);
      assert.deepEqual(JSON.parse(answer.body), DISABLED);
      assert.equal(answer.headers["cache-control"], "public, s-maxage=60, stale-while-revalidate=300");
    });
  }

  test(`${ROUTE}: a lowercase spelling still gets one cacheable 308 to the EIP-55 URL, which the loader answers`, {skip}, async () => {
    const answer = await get(port, `${ROUTE}?wallet=${CANONICAL.toLowerCase()}`);
    assert.equal(answer.status, 308, `lowercase: ${answer.status} ${answer.body}`);
    assert.equal(answer.headers["cache-control"], "public, max-age=86400, s-maxage=86400");
    const location = new URL(answer.headers.location ?? "", `http://127.0.0.1:${port}`);
    assert.equal(`${location.pathname}${location.search}`, canonicalPath(ROUTE));
    const followed = await get(port, `${location.pathname}${location.search}`);
    assert.equal(followed.status, 200);
    assert.deepEqual(JSON.parse(followed.body), DISABLED);
  });

  test(`${ROUTE}: a lowercase spelling with an encoded key and separators is normalized, then redirected`, {skip}, async () => {
    const answer = await get(port, `${ROUTE}?&%77allet=${CANONICAL.toLowerCase()}&`);
    assert.equal(answer.status, 308, `${answer.status} ${answer.body}`);
    const location = new URL(answer.headers.location ?? "", `http://127.0.0.1:${port}`);
    assert.equal(`${location.pathname}${location.search}`, canonicalPath(ROUTE));
  });

  const REFUSED: [string, string][] = [
    ["a wrong EIP-55 checksum", `?wallet=${WRONG_CHECKSUM}`],
    ["a wrong checksum behind a percent-encoded first character", `?wallet=%30x${WRONG_CHECKSUM.slice(2)}`],
    ["an extra ordinary key, which Next.js keeps", `?wallet=${CANONICAL}&utm=1`],
  ];

  for (const [name, query] of REFUSED) {
    test(`${ROUTE}: ${name} is refused with a 400 that is never cached and never reaches the loader`, {skip}, async () => {
      const answer = await get(port, `${ROUTE}${query}`);
      assert.equal(answer.status, 400, `${query}: ${answer.status} ${answer.body}`);
      assert.equal(answer.headers["cache-control"], "no-store");
      assert.deepEqual(JSON.parse(answer.body), {ok: false, error: "Exactly one wallet address is required."});
    });
  }
}
