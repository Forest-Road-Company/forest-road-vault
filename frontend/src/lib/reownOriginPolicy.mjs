const REOWN_ORIGINS_ENDPOINT = "https://api.web3modal.org/projects/v1/origins";

// These are the stable public entry points recorded in PREVIEW.md. Reown matches hostnames
// exactly: allowing forestroadvault.com does not allow www or the Vercel production hostname.
export const REQUIRED_REOWN_ORIGINS = Object.freeze([
  "https://forestroadvault.com",
  "https://www.forestroadvault.com",
  "https://forest-road-vault.vercel.app",
]);

function originUrl(value, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${label} must be an absolute HTTP(S) origin: ${value}`);
  }
  if (
    (parsed.protocol !== "https:" && parsed.protocol !== "http:")
    || parsed.username
    || parsed.password
    || parsed.pathname !== "/"
    || parsed.search
    || parsed.hash
  ) {
    throw new Error(`${label} must be an absolute HTTP(S) origin: ${value}`);
  }
  return parsed;
}

function hostnameMatches(pattern, hostname) {
  const patternLabels = pattern.toLowerCase().split(".");
  const hostnameLabels = hostname.toLowerCase().split(".");
  return patternLabels.length === hostnameLabels.length
    && patternLabels.every((label, index) => label === "*" || label === hostnameLabels[index]);
}

/** Implements Reown's documented exact-origin and full-label wildcard rules. */
export function reownRuleAllowsOrigin(rule, requiredOrigin) {
  if (typeof rule !== "string" || rule.trim() === "") return false;
  const candidate = rule.trim();
  const includesScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(candidate);
  const parsedRule = originUrl(includesScheme ? candidate : `https://${candidate}`, "Reown allowlist entry");
  const parsedRequired = originUrl(requiredOrigin, "Required WalletConnect origin");
  if (includesScheme && parsedRule.protocol !== parsedRequired.protocol) return false;
  if (parsedRule.port && parsedRule.port !== parsedRequired.port) return false;
  return hostnameMatches(parsedRule.hostname, parsedRequired.hostname);
}

export function missingReownOrigins(allowedOrigins, requiredOrigins = REQUIRED_REOWN_ORIGINS) {
  if (!Array.isArray(allowedOrigins) || allowedOrigins.length === 0) {
    return [...requiredOrigins];
  }
  return requiredOrigins.filter(
    (required) => !allowedOrigins.some((rule) => reownRuleAllowsOrigin(rule, required)),
  );
}

function extraRequiredOrigins(env) {
  const configured = env.NEXT_PUBLIC_WALLETCONNECT_REQUIRED_ORIGINS?.trim();
  if (!configured) return [];
  return configured
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => originUrl(value, "NEXT_PUBLIC_WALLETCONNECT_REQUIRED_ORIGINS entry").origin);
}

export async function verifyReownOriginPolicy({
  env = process.env,
  fetchImpl = fetch,
  write = (message) => process.stdout.write(message),
  endpoint = REOWN_ORIGINS_ENDPOINT,
} = {}) {
  const projectId = env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim();
  if (!projectId) {
    write("WalletConnect origin gate: WalletConnect disabled; no Reown allowlist required.\n");
    return {checked: false, requiredOrigins: [], allowedOrigins: []};
  }
  if (!/^[0-9a-f]{32}$/i.test(projectId)) {
    throw new Error(
      "NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID must be a 32-character hexadecimal Reown project ID",
    );
  }

  const requiredOrigins = [...new Set([
    ...REQUIRED_REOWN_ORIGINS,
    ...extraRequiredOrigins(env),
  ])];
  const url = new URL(endpoint);
  url.searchParams.set("projectId", projectId);
  url.searchParams.set("st", "appkit");
  url.searchParams.set("sv", "forest-road-vault-build-origin-check");

  let response;
  try {
    response = await fetchImpl(url, {signal: AbortSignal.timeout(10_000)});
  } catch (error) {
    throw new Error(
      `Reown origin allowlist check failed: ${error instanceof Error ? error.message : "network error"}`,
    );
  }
  if (!response.ok) {
    throw new Error(`Reown origin allowlist check returned HTTP ${response.status}`);
  }
  const payload = await response.json();
  if (
    typeof payload !== "object"
    || payload === null
    || !Array.isArray(payload.allowedOrigins)
    || !payload.allowedOrigins.every((value) => typeof value === "string")
  ) {
    throw new Error("Reown origin allowlist check returned an invalid response");
  }

  const missing = missingReownOrigins(payload.allowedOrigins, requiredOrigins);
  if (missing.length !== 0) {
    throw new Error(
      `Reown project origin allowlist does not cover: ${missing.join(", ")}. Add the exact origins at https://dashboard.reown.com before releasing this build`,
    );
  }
  write(`WalletConnect origin gate: ${requiredOrigins.length} public origins are allowed by Reown.\n`);
  return {checked: true, requiredOrigins, allowedOrigins: payload.allowedOrigins};
}
