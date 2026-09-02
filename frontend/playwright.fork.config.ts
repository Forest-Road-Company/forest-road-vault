import {defineConfig} from "@playwright/test";

// Mainnet-fork reconciliation. Deliberately has NO `webServer`: the app is served separately
// against a pinned anvil fork, so the run reads a real deployment rather than a fixture.
export default defineConfig({
  testDir: "./e2e",
  testMatch: /mainnet-fork-(reconciliation|writes)\.spec\.ts/,
  timeout: 300_000,
  expect: {timeout: 20_000},
  fullyParallel: false,
  reporter: "list",
  use: {baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:3210"},
});
