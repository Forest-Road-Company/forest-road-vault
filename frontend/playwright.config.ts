import {defineConfig} from "@playwright/test";

const host = process.env.E2E_FRONTEND_HOST ?? "127.0.0.1";
const port = process.env.E2E_FRONTEND_PORT ?? "3002";
const baseURL = process.env.E2E_BASE_URL ?? `http://${host}:${port}`;
const chromePath =
  process.env.PLAYWRIGHT_CHROME_PATH ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

export default defineConfig({
  testDir: "./e2e",
  outputDir: "./test-results/artifacts",
  timeout: 240_000,
  expect: {timeout: 30_000},
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [
    ["line"],
    ["json", {outputFile: "test-results/results.json"}],
    ["html", {outputFolder: "playwright-report", open: "never"}],
  ],
  use: {
    baseURL,
    viewport: {width: 1440, height: 1100},
    launchOptions: {executablePath: chromePath},
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  webServer: {
    command: `npm run start -- --hostname ${host} --port ${port}`,
    url: `${baseURL}/app`,
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
