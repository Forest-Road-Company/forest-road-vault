/**
 * The RPC proxy route through Next.js's real request path, on the BUILT site under `next start`.
 *
 * route.test.ts calls the handlers directly with a `Request` it builds. A real request reaches them
 * through Next.js, which may answer some methods itself (it implements OPTIONS and HEAD when a route
 * does not), adds forwarding headers, and decides the host the origin check compares against. This
 * pins those behaviours on the build, so a Next.js upgrade that changes them fails here.
 *
 * Run after a production build, from frontend/ (CI runs it after the proxy-mode build):
 *   npm run build
 *   npm run test:server
 * With no build (.next/BUILD_ID absent) every case is skipped, except under CI, where that fails.
 * The server binds 127.0.0.1 on a free port and makes no network call: its upstream is a loopback
 * URL, which the route refuses on mainnet and Sepolia builds before any fetch, so forwarding fails
 * closed with 503 while every refusal ahead of it is exercised for real.
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
const LOOPBACK_UPSTREAM = "https://127.0.0.1:9/never-contacted-LOOPBACKMARKER";

type Answer = {status: number; headers: IncomingHttpHeaders; body: string};

function send(port: number, method: string, headers: Record<string, string>, body?: string): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      {host: "127.0.0.1", port, path: "/api/rpc", method, headers, agent: false, timeout: 15_000},
      (response) => {
        let text = "";
        response.setEncoding("utf8");
        response.on("data", (chunk: string) => (text += chunk));
        response.on("end", () => resolve({status: response.statusCode ?? 0, headers: response.headers, body: text}));
        response.on("error", reject);
      },
    );
    request.on("timeout", () => request.destroy(new Error(`${method} /api/rpc: no answer within 15 s`)));
    request.on("error", reject);
    if (body !== undefined) request.write(body);
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

const json = {"content-type": "application/json"};
const sameOrigin = () => ({...json, origin: `http://127.0.0.1:${port}`, "sec-fetch-site": "same-origin"});
const rpc = (method: string, params: unknown[] = [], id: number | string = 1) =>
  JSON.stringify({jsonrpc: "2.0", id, method, params});
const noCors = (answer: Answer) =>
  assert.deepEqual(Object.keys(answer.headers).filter((name) => name.startsWith("access-control-")), []);

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
        RPC_PROXY_UPSTREAM_URL: LOOPBACK_UPSTREAM,
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
      await send(port, "GET", {});
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
  test("a production build exists for the built RPC route test", () => {
    assert.fail("no production build at frontend/.next: run `npm run build` before `npm run test:server`");
  });
}

for (const method of ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "DELETE"]) {
  test(`/api/rpc: ${method} is refused with 405 by the route itself, not answered by Next.js`, {skip}, async () => {
    const answer = await send(port, method, {origin: "https://attacker.invalid"});
    assert.equal(answer.status, 405, `${method}: ${answer.status} ${answer.body}`);
    assert.equal(answer.headers.allow, "POST");
    noCors(answer);
  });
}

test("/api/rpc: a foreign Origin is refused with 403", {skip}, async () => {
  const answer = await send(port, "POST", {...json, origin: "https://attacker.invalid"}, rpc("eth_blockNumber"));
  assert.equal(answer.status, 403, answer.body);
  noCors(answer);
});

test("/api/rpc: Sec-Fetch-Site cross-site is refused with 403", {skip}, async () => {
  const answer = await send(port, "POST", {...json, "sec-fetch-site": "cross-site"}, rpc("eth_blockNumber"));
  assert.equal(answer.status, 403, answer.body);
});

test("/api/rpc: a same-origin browser request passes the origin check under Next's real host headers", {skip}, async () => {
  const answer = await send(port, "POST", sameOrigin(), rpc("eth_sendRawTransaction", ["0x00"], 9));
  assert.equal(answer.status, 200, answer.body);
  assert.deepEqual(JSON.parse(answer.body), {
    jsonrpc: "2.0",
    id: 9,
    error: {code: -32601, message: "Method not available through this proxy"},
  });
  assert.equal(answer.headers["cache-control"], "no-store");
  noCors(answer);
});

test("/api/rpc: an address-less eth_getLogs is refused per entry", {skip}, async () => {
  const answer = await send(port, "POST", sameOrigin(), rpc("eth_getLogs", [{fromBlock: "0x1"}], 4));
  assert.equal(answer.status, 200, answer.body);
  assert.equal(JSON.parse(answer.body).error.code, -32602);
});

test("/api/rpc: a loopback upstream is refused before any fetch, and the answer never names it", {skip}, async () => {
  const answer = await send(port, "POST", sameOrigin(), rpc("eth_blockNumber"));
  assert.equal(answer.status, 503, answer.body);
  assert.deepEqual(JSON.parse(answer.body), {
    jsonrpc: "2.0",
    id: 1,
    error: {code: -32603, message: "RPC proxy is not configured"},
  });
  assert.ok(!answer.body.includes("127.0.0.1") && !answer.body.includes("LOOPBACKMARKER"));
  assert.ok(!log.includes("LOOPBACKMARKER"), "the server log must not name the upstream");
});

test("/api/rpc: a body that is not JSON is refused with 415", {skip}, async () => {
  const answer = await send(port, "POST", {"content-type": "text/plain"}, rpc("eth_blockNumber"));
  assert.equal(answer.status, 415, answer.body);
});

test("/api/rpc: a body over 256 KiB is refused with 413", {skip}, async () => {
  const answer = await send(port, "POST", sameOrigin(), rpc("eth_call", [{data: `0x${"00".repeat(140_000)}`}]));
  assert.equal(answer.status, 413, answer.body);
});

test("/api/rpc: a batch of 21 is refused with 400", {skip}, async () => {
  const batch = JSON.stringify(Array.from({length: 21}, (_, i) => ({jsonrpc: "2.0", id: i, method: "eth_blockNumber"})));
  const answer = await send(port, "POST", sameOrigin(), batch);
  assert.equal(answer.status, 400, answer.body);
});
