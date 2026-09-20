#!/usr/bin/env node

const args = process.argv.slice(2);
const value = (flag) => {
  const index = args.indexOf(flag);
  return index === -1 ? undefined : args[index + 1];
};
const rawUrl = value("--url");
const expected = value("--commit")?.toLowerCase();
if (!rawUrl || !expected || !/^[0-9a-f]{40}$/.test(expected)) {
  throw new Error("usage: verify-frontend-revision.mjs --url <https-url> --commit <40-hex-sha>");
}
const base = new URL(rawUrl);
if (base.protocol !== "https:") throw new Error("the served-revision check requires HTTPS");
const endpoint = new URL("/api/revision", base);
const response = await fetch(endpoint, {
  headers: {accept: "application/json"},
  redirect: "error",
  signal: AbortSignal.timeout(15_000),
});
if (!response.ok) throw new Error(`${endpoint} returned HTTP ${response.status}`);
const body = await response.json();
const header = response.headers.get("x-frv-source-revision")?.toLowerCase();
if (body?.ok !== true || body.commit !== expected || header !== expected) {
  throw new Error(
    `served revision mismatch: expected ${expected}, body=${String(body?.commit)}, header=${String(header)}`,
  );
}
if (body.environment !== "production") {
  throw new Error(`served deployment is ${String(body.environment)}, not production`);
}
process.stdout.write(
  `Verified ${base.origin} serves ${expected} from deployment ${String(body.deploymentId)}.\n`,
);
