import {fileURLToPath} from "node:url";
import react from "@vitejs/plugin-react";
import {defineConfig} from "vitest/config";

/**
 * Component render harness.
 *
 * AUDIT FIX (round-9 structural item). Before this, every statement about component
 * BEHAVIOUR was asserted by searching the component's own source text — e.g. "the redeem
 * button is disabled until the cooldown loads" was verified by grepping for `disabled={`.
 * Three reviewers independently sketched edits that keep those string literals while
 * restoring the published defect, which a grep cannot distinguish from a real fix.
 *
 * These tests mount the component and assert what a user would actually see and be able
 * to do. They complement, and do not replace, the pure-logic and contract↔ABI suites.
 */
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {"@": fileURLToPath(new URL("./src", import.meta.url))},
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.tsx", "src/**/*.test.ts"],
    // contracts.ts fails closed on an unset chain id (FRV-FS-10); tests pick the testnet profile.
    env: {NEXT_PUBLIC_CHAIN_ID: "11155111"},
  },
});
