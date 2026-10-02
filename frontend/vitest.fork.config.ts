import {fileURLToPath} from "node:url";
import {defineConfig} from "vitest/config";

/**
 * Mainnet-fork suites (run: `MAINNET_RPC_URL=<archive RPC> npm run test:fork`).
 *
 * Kept out of `npm test` on purpose: each suite starts its own anvil fork of Ethereum mainnet at a
 * pinned block and skips itself when MAINNET_RPC_URL is unset, so including it in the default run
 * would turn a missing endpoint into a silent pass. The suites never print the endpoint, and anvil
 * runs with its output discarded because its banner includes the fork URL.
 */
export default defineConfig({
  resolve: {
    alias: {"@": fileURLToPath(new URL("./src", import.meta.url))},
  },
  test: {
    environment: "node",
    include: ["scripts/**/*.fork.test.ts"],
    fileParallelism: false,
    testTimeout: 180_000,
    hookTimeout: 240_000,
  },
});
