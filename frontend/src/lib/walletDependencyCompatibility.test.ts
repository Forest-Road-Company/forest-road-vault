import {CreatePolicyBodySchema} from "@coinbase/cdp-sdk";
import {W3mFrameSchema} from "@reown/appkit-wallet";
import {describe, expect, it} from "vitest";

/**
 * The wallet dependency tree is deliberately pinned to patched Zod 4. These checks exercise the
 * actual Reown and Coinbase schemas so a future package update cannot silently make that security
 * override module-load-only compatible while breaking validation at runtime.
 */
describe("patched wallet-schema dependencies", () => {
  it("keeps Reown frame validation operational", () => {
    expect(W3mFrameSchema.appEvent.safeParse({
      type: "@w3m-app/CONNECT_EMAIL",
      payload: {email: "wallet@example.com"},
    }).success).toBe(true);
    expect(W3mFrameSchema.appEvent.safeParse({
      type: "@w3m-app/CONNECT_EMAIL",
      payload: {email: "not-an-email"},
    }).success).toBe(false);
  });

  it("keeps Coinbase policy validation operational", () => {
    expect(CreatePolicyBodySchema.safeParse({scope: "project", rules: []}).success).toBe(false);
    expect(CreatePolicyBodySchema.safeParse({scope: "unknown", rules: []}).success).toBe(false);
  });
});
