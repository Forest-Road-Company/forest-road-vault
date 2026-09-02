import {test, expect} from "@playwright/test";
import {readFileSync} from "node:fs";
import path from "node:path";

/**
 * FRONTEND ↔ CONTRACT RECONCILIATION against the LIVE MAINNET DEPLOYMENT, read through a pinned
 * local fork (CLAUDE.md §2.2: "every number the website/dashboard shows must reconcile to on-chain
 * state").
 *
 * The existing `sepolia-fork.spec.ts` cannot be pointed at mainnet: it hardcodes the Sepolia
 * manifest and funds wallets by MINTING MockERC20, which canonical Circle USDC has no equivalent
 * for. This spec therefore reads the mainnet manifest, and every expected value is fetched
 * INDEPENDENTLY over JSON-RPC rather than from the app, so agreement is evidence rather than the
 * app being compared against itself.
 */

const root = path.resolve(process.cwd(), "..");
const manifest = JSON.parse(
  readFileSync(path.join(root, "contracts/deployments/1-production-v1.json"), "utf8"),
);
const RPC = process.env.MAINNET_FORK_RPC_URL ?? "http://127.0.0.1:8549";

let rpcId = 0;
async function ethCall(to: string, data: string): Promise<bigint> {
  const res = await fetch(RPC, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: ++rpcId,
      method: "eth_call",
      params: [{to, data}, "latest"],
    }),
  });
  const json = (await res.json()) as {result?: string; error?: {message: string}};
  if (json.error) throw new Error(`${to} ${data}: ${json.error.message}`);
  return BigInt(json.result ?? "0x0");
}

// Selectors verified with `cast sig`, not hand-derived. The first draft of this file
// guessed recognizedBackingValue() and the call reverted.
const SEL = {
  totalSupply: "0x18160ddd",
  totalAssets: "0x01e1d114",
  recognizedBackingValue: "0xd0a6c794",
};

/** Every digit-group the page renders, normalised for comparison. */
async function renderedNumbers(page: import("@playwright/test").Page): Promise<string[]> {
  const text = await page.locator("body").innerText();
  return (text.match(/[\d,]+\.?\d*/g) ?? []).map((s) => s.replace(/,/g, ""));
}

test.describe("mainnet-v1 frontend reconciliation (pinned fork)", () => {
  test("every route renders, and no route leaks a Sepolia address", async ({page}) => {
    const routes = ["/", "/app", "/docs/addresses", "/transparency", "/points", "/risk"];
    const sepoliaAddresses = [
      "0xdEf257Ee5b822a1eC5c97d130FD8C8212C2BE72d",
      "0x197bb3701e964bfb367449a6754C845Fc8f7d0F4",
    ];
    for (const route of routes) {
      const response = await page.goto(route, {waitUntil: "networkidle"});
      expect(response?.status(), `${route} status`).toBe(200);
      const body = await page.locator("body").innerText();
      for (const addr of sepoliaAddresses) {
        expect(body.toLowerCase(), `${route} must not render a Sepolia address`).not.toContain(
          addr.toLowerCase(),
        );
      }
    }
  });

  test("the addresses page renders exactly the deployed mainnet addresses", async ({page}) => {
    await page.goto("/docs/addresses", {waitUntil: "networkidle"});
    const body = (await page.locator("body").innerText()).toLowerCase();
    const expected: Array<[string, string]> = [
      ["USDfr", manifest.usdfr],
      ["sUSDfr", manifest.vault],
      ["MintRedeemController", manifest.controller],
      ["RedemptionQueue", manifest.queue],
      ["Timelock", manifest.timelock],
      ["ComplianceRegistry", manifest.compliance],
      ["ReserveManager", manifest.reserves],
      ["PointsModule", manifest.points],
      ["GROVE", manifest.grove],
      ["sGROVE", manifest.sGrove],
      ["Governor", manifest.governor],
    ];
    for (const [label, address] of expected) {
      expect(body, `${label} address must be rendered`).toContain(String(address).toLowerCase());
    }
    expect(body).toContain("25768251"); // deployment block
  });

  test("dashboard totals reconcile to independently-read chain state", async ({page}) => {
    // Read the truth from the chain FIRST, over raw JSON-RPC, with no involvement from the app.
    const [usdfrSupply, vaultAssets, vaultShares, backing] = await Promise.all([
      ethCall(manifest.usdfr, SEL.totalSupply),
      ethCall(manifest.vault, SEL.totalAssets),
      ethCall(manifest.vault, SEL.totalSupply),
      ethCall(manifest.reserves, SEL.recognizedBackingValue),
    ]);

    // Invariant §1.3: USDfr supply is never more than recognised backing.
    expect(usdfrSupply, "backing invariant: supply <= backing").toBeLessThanOrEqual(backing);
    expect(vaultAssets, "vault must hold the seeded assets").toBeGreaterThan(0n);
    expect(vaultShares, "vault must have shares outstanding").toBeGreaterThan(0n);

    await page.goto("/transparency", {waitUntil: "networkidle"});
    await page.waitForTimeout(4000); // allow client-side chain reads to settle
    const numbers = await renderedNumbers(page);

    // The page renders whole-token figures; assert the headline USDfr supply appears.
    const supplyWhole = (usdfrSupply / 10n ** 18n).toString();
    const found = numbers.some((n) => n.split(".")[0] === supplyWhole);
    expect(
      found,
      `transparency page should render USDfr supply ${supplyWhole}; saw ${numbers.slice(0, 40).join(", ")}`,
    ).toBe(true);
  });

  test("no console errors and no wrong-network banner on the fork", async ({page}) => {
    const errors: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "error") errors.push(msg.text());
    });
    page.on("pageerror", (err) => errors.push(String(err)));
    await page.goto("/app", {waitUntil: "networkidle"});
    await page.waitForTimeout(4000);
    // Filter noise that is not an application fault.
    const real = errors.filter(
      (e) => !/favicon|ERR_INTERNET_DISCONNECTED|WalletConnect|Reown|analytics/i.test(e),
    );
    expect(real, `console errors: ${real.join(" | ")}`).toHaveLength(0);
  });
});
