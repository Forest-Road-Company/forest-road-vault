// @vitest-environment node
import {spawnSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {afterEach, describe, expect, it} from "vitest";

/**
 * scripts/check-bundle-rpc-secrets.mjs, the scan that ends every `npm run build`, against small
 * synthetic build directories. It must fail on any part of the build's own upstream URL anywhere in
 * the output, and on any keyed provider URL the browser could fetch, and never print the value.
 */

const SCRIPT = fileURLToPath(new URL("../../scripts/check-bundle-rpc-secrets.mjs", import.meta.url));
const KEY = `BUILDKEY${"b".repeat(20)}`;
const QUERY_KEY = `QUERYSECRET${"q".repeat(12)}`;
const UPSTREAM = `https://upstream.build.invalid/v2/${KEY}?apikey=${QUERY_KEY}`;
const PROXY_CONSTANT = 'let E="/api/rpc";';
const PROXY_INLINED = 'const T="/api/rpc",I=T===E;';

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) fs.rmSync(directory, {recursive: true, force: true});
});

function build(files: Record<string, string>): string {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "bundle-scan-"));
  directories.push(directory);
  for (const [name, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(directory, name)), {recursive: true});
    fs.writeFileSync(path.join(directory, name), content);
  }
  return directory;
}

function scan(directory: string, env: Record<string, string> = {}) {
  const result = spawnSync(process.execPath, [SCRIPT], {
    encoding: "utf8",
    env: {PATH: process.env.PATH ?? "", CHECK_BUNDLE_NEXT_DIR: directory, ...env} as unknown as NodeJS.ProcessEnv,
  });
  return {status: result.status, output: `${result.stdout}${result.stderr}`};
}

const clean = () => ({
  "static/chunks/app.js": `${PROXY_CONSTANT}${PROXY_INLINED}`,
  "server/app/page.js": "module.exports = {};",
});

describe("the build's own bundle scan", () => {
  it("passes a clean mainnet proxy-mode build", () => {
    const result = scan(build(clean()), {RPC_PROXY_UPSTREAM_URL: UPSTREAM, NEXT_PUBLIC_CHAIN_ID: "1"});
    expect(result.output).toContain("check-bundle-rpc-secrets: PASS");
    expect(result.status).toBe(0);
  });

  it("fails a mainnet build that is not in proxy mode", () => {
    const result = scan(build({"static/chunks/app.js": PROXY_CONSTANT}), {NEXT_PUBLIC_CHAIN_ID: "1"});
    expect(result.status).toBe(1);
    expect(result.output).toContain("this build was not in proxy mode");
  });

  it.each([
    ["the whole upstream URL in a browser script", "static/chunks/leak.js", UPSTREAM],
    ["its key path segment in a server bundle", "server/chunks/leak.js", `fetch("x/${KEY}")`],
    ["its query-string key in a server bundle", "server/chunks/leak.js", `"${QUERY_KEY}"`],
    ["its key in prerendered HTML", "server/app/index.html", `<script>${KEY}</script>`],
  ])("fails on %s, without printing the value", (_, file, content) => {
    const result = scan(build({...clean(), [file]: content}), {RPC_PROXY_UPSTREAM_URL: UPSTREAM});
    expect(result.status).toBe(1);
    expect(result.output).toContain("FOUND");
    expect(result.output).not.toContain(KEY);
    expect(result.output).not.toContain(QUERY_KEY);
    expect(result.output).not.toContain("upstream.build.invalid");
  });

  it.each([
    // Built at run time, so no key-shaped literal sits in the source for secret scanners to flag.
    ["an Alchemy key", `https://eth-mainnet.g.alchemy.com/v2/${"k".repeat(20)}`],
    ["an Infura key", `https://mainnet.infura.io/v3/${"a1".repeat(16)}`],
    ["a Helius Solana key", `https://mainnet.helius-rpc.com/?api-key=${"0f".repeat(18)}`],
    ["a QuickNode token", `https://solana-mainnet.quiknode.pro/${"ab".repeat(20)}/`],
    ["a Triton token", `https://example.rpcpool.com/${"ab".repeat(11)}`],
  ])("fails on %s in a browser script", (_, url) => {
    const result = scan(build({...clean(), "static/chunks/solana.js": `const rpc="${url}";`}));
    expect(result.status).toBe(1);
    expect(result.output).toContain("FOUND");
  });

  it("does not fail a keyless upstream that viem already ships in the bundle, but still fails a keyed one", () => {
    const keyless = "https://11155111.rpc.thirdweb.com";
    const bundle = {...clean(), "static/chunks/viem-chains.js": `rpcUrls:{default:{http:["${keyless}"]}}`};
    expect(scan(build(bundle), {RPC_PROXY_UPSTREAM_URL: keyless}).status).toBe(0);
    const keyed = `https://sepolia.example-provider.invalid/v2/${KEY}`;
    const leaked = scan(build({...clean(), "static/chunks/leak.js": `"${keyed}"`}), {RPC_PROXY_UPSTREAM_URL: keyed});
    expect(leaked.status).toBe(1);
    expect(leaked.output).toContain("this build's RPC_PROXY_UPSTREAM_URL (value not printed)");
  });

  it("does not flag a keyless public endpoint", () => {
    const result = scan(build({...clean(), "static/chunks/solana.js": 'const rpc="https://api.mainnet-beta.solana.com";'}));
    expect(result.status).toBe(0);
  });

  it("refuses an empty scan", () => {
    const result = scan(build({"server/app/page.js": "module.exports = {};"}));
    expect(result.status).toBe(1);
  });
});
