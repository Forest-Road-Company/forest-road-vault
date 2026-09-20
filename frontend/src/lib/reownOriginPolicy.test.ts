import {describe, expect, it, vi} from "vitest";
import {
  REQUIRED_REOWN_ORIGINS,
  missingReownOrigins,
  reownRuleAllowsOrigin,
  verifyReownOriginPolicy,
} from "./reownOriginPolicy.mjs";

const PROJECT_ID = "a".repeat(32);
const CUSTOM_DOMAINS_ONLY = [
  "https://forestroadvault.com",
  "https://www.forestroadvault.com",
];

function response(allowedOrigins: readonly string[]) {
  return new Response(JSON.stringify({allowedOrigins}), {
    status: 200,
    headers: {"content-type": "application/json"},
  });
}

describe("Reown release origin policy", () => {
  it("reproduces the live custom-domain-only configuration gap", () => {
    expect(missingReownOrigins(CUSTOM_DOMAINS_ONLY)).toEqual([
      "https://forest-road-vault.vercel.app",
    ]);
  });

  it("accepts exact coverage for every stable public entry point", () => {
    expect(missingReownOrigins(REQUIRED_REOWN_ORIGINS)).toEqual([]);
  });

  it("implements Reown's exact-host and full-label wildcard behavior", () => {
    expect(reownRuleAllowsOrigin("forestroadvault.com", "https://forestroadvault.com")).toBe(true);
    expect(reownRuleAllowsOrigin("https://forestroadvault.com", "https://www.forestroadvault.com")).toBe(false);
    expect(reownRuleAllowsOrigin("https://*.vercel.app", "https://forest-road-vault.vercel.app")).toBe(true);
    expect(reownRuleAllowsOrigin("https://www-*.vercel.app", "https://www-preview.vercel.app")).toBe(false);
  });

  it("refuses a release when the deployed Vercel origin is absent", async () => {
    const fetchImpl = vi.fn<typeof fetch>(async () => response(CUSTOM_DOMAINS_ONLY));
    await expect(verifyReownOriginPolicy({
      env: {NODE_ENV: "test", NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID: PROJECT_ID},
      fetchImpl,
      write: vi.fn(),
    })).rejects.toThrow("https://forest-road-vault.vercel.app");
    expect(fetchImpl).toHaveBeenCalledOnce();
  });

  it("passes without exposing the project ID when every origin is covered", async () => {
    const write = vi.fn();
    const result = await verifyReownOriginPolicy({
      env: {NODE_ENV: "test", NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID: PROJECT_ID},
      fetchImpl: vi.fn<typeof fetch>(async () => response(REQUIRED_REOWN_ORIGINS)),
      write,
    });
    expect(result.checked).toBe(true);
    expect(write).toHaveBeenCalledWith(expect.stringContaining("3 public origins"));
    expect(JSON.stringify(result)).not.toContain(PROJECT_ID);
  });

  it("skips the remote check when WalletConnect is intentionally disabled", async () => {
    const fetchImpl = vi.fn<typeof fetch>();
    const result = await verifyReownOriginPolicy({
      env: {NODE_ENV: "test"},
      fetchImpl,
      write: vi.fn(),
    });
    expect(result.checked).toBe(false);
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
