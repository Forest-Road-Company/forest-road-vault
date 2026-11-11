#!/usr/bin/env node
/**
 * Proves a production build ships no RPC provider key to the browser.
 *
 * Runs at the end of every `npm run build` (the package "build" script, which is what Vercel runs
 * for this project), so the real production build checks its own output, and again in CI after a
 * proxy-mode build whose server-only RPC_PROXY_UPSTREAM_URL is a sentinel:
 *
 *   NEXT_PUBLIC_RPC_URL=/api/rpc \
 *   RPC_PROXY_UPSTREAM_URL=https://sentinel-upstream.invalid/v2/SENTINELKEY0123456789 npm run build
 *   node scripts/check-bundle-rpc-secrets.mjs --expect-proxy
 *
 * It fails on:
 *   - anywhere in the build output (the build cache excluded): the build's own
 *     RPC_PROXY_UPSTREAM_URL, its long path segments and its long query values (where providers put
 *     keys), and the CI sentinel's key and host. A server-only value is read at request time, so it
 *     must not be inlined in the server bundles either;
 *   - in .next/static, the only output a browser can fetch: any keyed URL of a common RPC provider
 *     (Alchemy, Infura, QuickNode, Helius, Ankr, Chainstack, GetBlock, Blast, NodeReal, dRPC,
 *     Triton, or any `api-key=` query), which also covers NEXT_PUBLIC_SOLANA_RPC_URL;
 *   - nothing to scan;
 *   - with --expect-proxy, or on any mainnet build (NEXT_PUBLIC_CHAIN_ID=1), a build that is not in
 *     proxy mode. Every build carries the quoted "/api/rpc" once, as the shared constant; a
 *     proxy-mode build carries it a second time, where Next inlines NEXT_PUBLIC_RPC_URL.
 * It never prints a configured value, only labels and file names.
 *
 * Positive control (6 November 2026): a Sepolia build with NEXT_PUBLIC_RPC_URL set to the sentinel
 * URL (direct mode, still allowed on Sepolia) fails this scan on the sentinel in .next/static and on
 * the proxy-mode count.
 *
 * CHECK_BUNDLE_NEXT_DIR points it at another build directory (tests only).
 */
import fs from "node:fs";
import {createRequire} from "node:module";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
// The same .env* files the build read, so a value set only there is compared too (never printed).
createRequire(path.join(root, "package.json"))("@next/env").loadEnvConfig(root, false, {info: () => undefined, error: () => undefined});
const nextDir = process.env.CHECK_BUNDLE_NEXT_DIR ? path.resolve(process.env.CHECK_BUNDLE_NEXT_DIR) : path.join(root, ".next");
const staticDir = path.join(nextDir, "static");
const expectProxy = process.argv.includes("--expect-proxy") || process.env.NEXT_PUBLIC_CHAIN_ID === "1";

/** Literal needles, searched in the whole build output. Labels only are ever printed. */
const literals = [
  {label: "sentinel key text", needle: "SENTINELKEY"},
  {label: "sentinel host", needle: "sentinel-upstream.invalid"},
  {label: "an Alchemy keyed path", needle: "alchemy.com/v2/"},
];
const configured = process.env.RPC_PROXY_UPSTREAM_URL?.trim();
if (configured) {
  const whole = {label: "this build's RPC_PROXY_UPSTREAM_URL (value not printed)", needle: configured};
  try {
    const parsed = new URL(configured);
    const secrets = [];
    for (const segment of parsed.pathname.split("/")) {
      if (segment.length >= 12) {
        secrets.push({label: "a key-length path segment of RPC_PROXY_UPSTREAM_URL (value not printed)", needle: segment});
      }
    }
    for (const value of parsed.searchParams.values()) {
      if (value.length >= 12) {
        secrets.push({label: "a key-length query value of RPC_PROXY_UPSTREAM_URL (value not printed)", needle: value});
      }
    }
    if (parsed.password.length >= 8) {
      secrets.push({label: "the URL password of RPC_PROXY_UPSTREAM_URL (value not printed)", needle: parsed.password});
    }
    // A URL with nothing key-shaped in it (a keyless public endpoint) carries no secret, and may well
    // already be in the bundle: viem ships its chains' public RPC URLs. Only a URL that could hold a
    // key is searched for whole; its key-shaped parts are always searched.
    if (secrets.length > 0) literals.push(whole, ...secrets);
  } catch {
    // Not a URL: search for the whole value.
    literals.push(whole);
  }
}

/** Keyed URLs of common RPC providers, searched in what the browser can fetch. */
export const KEYED_PROVIDER_URLS = [
  {label: "an Alchemy key", pattern: /alchemy\.com\/v2\/[A-Za-z0-9_-]{16,}/},
  {label: "an Infura key", pattern: /infura\.io\/v3\/[0-9a-fA-F]{32}/},
  {label: "a QuickNode token", pattern: /quiknode\.pro\/[0-9a-fA-F]{20,}/},
  {label: "a Helius or other api-key query", pattern: /[?&]api[-_]?key=[A-Za-z0-9_-]{16,}/i},
  {label: "an Ankr key", pattern: /rpc\.ankr\.com\/[a-z0-9_]+\/[0-9a-fA-F]{32,}/},
  {label: "a Chainstack key", pattern: /p2pify\.com\/[0-9a-fA-F]{32}/},
  {label: "a GetBlock key", pattern: /getblock\.io\/[0-9a-fA-F-]{20,}/},
  {label: "a Blast key", pattern: /blastapi\.io\/[0-9a-fA-F-]{36}/},
  {label: "a NodeReal key", pattern: /nodereal\.io\/v1\/[0-9a-fA-F]{32}/},
  {label: "a dRPC key", pattern: /[?&]dkey=[A-Za-z0-9_-]{16,}/},
  {label: "a Triton token", pattern: /rpcpool\.com\/[A-Za-z0-9-]{16,}/},
];

function walk(directory, skip = () => false) {
  const files = [];
  for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
    const full = path.join(directory, entry.name);
    if (skip(full)) continue;
    if (entry.isDirectory()) files.push(...walk(full, skip));
    else if (entry.isFile()) files.push(full);
  }
  return files;
}

function scan(files, {keyedUrls}) {
  const hits = [];
  let bytes = 0;
  let proxyMentions = 0;
  for (const file of files) {
    const content = fs.readFileSync(file);
    bytes += content.length;
    const text = content.toString("latin1");
    for (const {label, needle} of literals) {
      if (text.includes(needle)) hits.push({file: path.relative(nextDir, file), label});
    }
    if (keyedUrls) {
      for (const {label, pattern} of KEYED_PROVIDER_URLS) {
        if (pattern.test(text)) hits.push({file: path.relative(nextDir, file), label});
      }
    }
    if (/\.m?js$/.test(file)) proxyMentions += text.split('"/api/rpc"').length - 1;
  }
  return {hits, bytes, proxyMentions};
}

if (!fs.existsSync(staticDir)) {
  console.error("check-bundle-rpc-secrets: .next/static does not exist; run a production build first.");
  process.exit(1);
}
const staticFiles = walk(staticDir);
const staticScripts = staticFiles.filter((file) => /\.m?js$/.test(file));
if (staticScripts.length === 0) {
  console.error("check-bundle-rpc-secrets: .next/static holds no scripts; refusing to pass an empty scan.");
  process.exit(1);
}
const browser = scan(staticFiles, {keyedUrls: true});
const server = scan(walk(nextDir, (full) => full === staticDir || full === path.join(nextDir, "cache")), {keyedUrls: false});

console.log(
  `check-bundle-rpc-secrets: .next/static: ${staticFiles.length} files (${staticScripts.length} scripts), ` +
    `${browser.bytes} bytes; needles: ${literals.map((needle) => needle.label).join("; ")}; ` +
    `${KEYED_PROVIDER_URLS.length} keyed-provider URL patterns.`,
);
console.log(`check-bundle-rpc-secrets: .next/static matches: ${browser.hits.length}.`);
console.log(`check-bundle-rpc-secrets: rest of .next (cache excluded): ${server.bytes} bytes, matches: ${server.hits.length}.`);
console.log(
  `check-bundle-rpc-secrets: quoted "/api/rpc" in browser scripts: ${browser.proxyMentions} ` +
    "(1 is the shared constant; 2 or more means NEXT_PUBLIC_RPC_URL is the proxy).",
);

let failed = false;
for (const hit of [...browser.hits, ...server.hits]) {
  console.error(`check-bundle-rpc-secrets: FOUND ${hit.label} in ${hit.file}`);
  failed = true;
}
if (expectProxy && browser.proxyMentions < 2) {
  console.error("check-bundle-rpc-secrets: NEXT_PUBLIC_RPC_URL was not inlined as /api/rpc; this build was not in proxy mode.");
  failed = true;
}
if (failed) process.exit(1);
console.log("check-bundle-rpc-secrets: PASS");
