import {test, expect} from "@playwright/test";
import {readFileSync} from "node:fs";
import path from "node:path";

/**
 * WRITE-PATH QA THROUGH THE REAL UI, against the live mainnet deployment on a pinned fork.
 *
 * The reads are covered by `mainnet-fork-reconciliation.spec.ts`. This drives the actual buttons:
 * a wallet is injected, the user connects, and mint/stake are executed as real transactions
 * against the deployed contracts. Success is asserted from CHAIN STATE read independently over
 * JSON-RPC, never from what the UI says happened. A UI that lies about success is precisely the
 * failure this is meant to catch.
 *
 * Funding is the mainnet-specific problem: canonical Circle USDC has no faucet, so the account is
 * funded by impersonating a whale via anvil rather than by minting a mock.
 */

const root = path.resolve(process.cwd(), "..");
const manifest = JSON.parse(
  readFileSync(path.join(root, "contracts/deployments/1-production-v1.json"), "utf8"),
);
const RPC = process.env.MAINNET_FORK_RPC_URL ?? "http://127.0.0.1:8549";
const USER = (process.env.E2E_USER ?? "0x000000000000000000000000000000000000BEEF").toLowerCase();
const CHAIN_ID = 31337;

let id = 0;
async function rpc(method: string, params: unknown[] = []): Promise<unknown> {
  const res = await fetch(RPC, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({jsonrpc: "2.0", id: ++id, method, params}),
  });
  const json = (await res.json()) as {result?: unknown; error?: {message: string}};
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

const pad = (hex: string) => hex.replace(/^0x/, "").padStart(64, "0");
async function balanceOf(token: string, who: string): Promise<bigint> {
  return BigInt(
    (await rpc("eth_call", [{to: token, data: `0x70a08231${pad(who)}`}, "latest"])) as string,
  );
}

test.describe("mainnet-v1 write paths through the UI (pinned fork)", () => {
  test.beforeAll(async () => {
    // Fund and KYC the UI account. Impersonation is anvil-only and cannot touch the real chain.
    await rpc("anvil_impersonateAccount", [USER]);
    await rpc("anvil_setBalance", [USER, "0x56BC75E2D63100000"]);
    const whale = "0x55FE002aefF02F77364de339a1292923A15844B8";
    const ops = manifest.opsAdmin as string;
    for (const account of [whale, ops]) {
      await rpc("anvil_impersonateAccount", [account]);
      await rpc("anvil_setBalance", [account, "0x56BC75E2D63100000"]);
    }
    // 2,000 USDC to the UI account.
    await rpc("eth_sendTransaction", [
      {
        from: whale,
        to: manifest.stable,
        data: `0xa9059cbb${pad(USER)}${pad((2_000_000_000n).toString(16))}`,
      },
    ]);
    // KYC it via the compliance admin.
    await rpc("eth_sendTransaction", [
      {
        from: ops,
        to: manifest.compliance,
        data: `0x4697f05d${pad(USER)}${pad("1")}`,
      },
    ]);
    expect(await balanceOf(manifest.stable, USER)).toBeGreaterThanOrEqual(2_000_000_000n);
  });

  test("connect, mint USDfr, and stake into sUSDfr, verified on chain", async ({page, context}) => {
    await context.addInitScript(
      ({account, rpcUrl, chainId}) => {
        type Listener = (...a: unknown[]) => void;
        const listeners = new Map<string, Set<Listener>>();
        let rid = 0;
        const provider = {
          isMetaMask: true,
          isConnected: () => true,
          get selectedAddress() {
            return account;
          },
          get chainId() {
            return `0x${chainId.toString(16)}`;
          },
          get networkVersion() {
            return String(chainId);
          },
          _metamask: {isUnlocked: async () => true},
          on(event: string, listener: Listener) {
            const set = listeners.get(event) ?? new Set<Listener>();
            set.add(listener);
            listeners.set(event, set);
            return provider;
          },
          removeListener(event: string, listener: Listener) {
            listeners.get(event)?.delete(listener);
            return provider;
          },
          async request(args: {method: string; params?: readonly unknown[]}) {
            const {method} = args;
            const params = args.params ?? [];
            if (method === "eth_requestAccounts" || method === "eth_accounts") return [account];
            if (method === "eth_chainId") return `0x${chainId.toString(16)}`;
            if (method === "net_version") return String(chainId);
            if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return null;
            if (method === "wallet_requestPermissions") return [{parentCapability: "eth_accounts"}];
            // Everything else, including eth_sendTransaction, goes straight to the fork. anvil
            // signs for the impersonated account, so these are real transactions.
            const res = await fetch(rpcUrl, {
              method: "POST",
              headers: {"content-type": "application/json"},
              body: JSON.stringify({jsonrpc: "2.0", id: ++rid, method, params}),
            });
            const json = await res.json();
            if (json.error) throw Object.assign(new Error(json.error.message), {code: json.error.code ?? -32000});
            return json.result;
          },
        };
        Object.defineProperty(window, "ethereum", {value: provider, configurable: true});
        const info = {uuid: "frv-e2e", name: "E2E Wallet", icon: "data:image/svg+xml;base64,PHN2Zy8+", rdns: "dev.frv.e2e"};
        const announce = () =>
          window.dispatchEvent(new CustomEvent("eip6963:announceProvider", {detail: {info, provider}}));
        window.addEventListener("eip6963:requestProvider", announce);
        announce();
      },
      {account: USER, rpcUrl: RPC, chainId: CHAIN_ID},
    );

    const usdfrBefore = await balanceOf(manifest.usdfr, USER);
    const sharesBefore = await balanceOf(manifest.vault, USER);

    await page.goto("/app", {waitUntil: "networkidle"});

    // Connect. NOTE the anchored regex: /connect/i also matches "Disconnect", and an earlier
    // draft of this test clicked exactly that, disconnecting the wallet it had just injected and
    // then failing on the account not rendering.
    await page.waitForTimeout(2000);
    const alreadyConnected = await page
      .getByRole("button", {name: /^\s*disconnect\s*$/i})
      .first()
      .isVisible()
      .catch(() => false);
    if (!alreadyConnected) {
      const connect = page.getByRole("button", {name: /^\s*connect/i}).first();
      if (await connect.isVisible().catch(() => false)) {
        await connect.click();
        const wallet = page.getByRole("button", {name: /E2E Wallet|injected|browser wallet/i}).first();
        if (await wallet.isVisible().catch(() => false)) await wallet.click();
      }
    }
    await page.waitForTimeout(3000);

    // The address (or its truncation) should now be on screen.
    const body = (await page.locator("body").innerText()).toLowerCase();
    expect(body.includes("beef"), `connected account should render; body head: ${body.slice(0, 200)}`).toBe(true);

    // MINT: fill the first numeric input in the mint card and submit.
    const mintAmount = "500";
    const amountInput = page.locator('input[type="text"], input[type="number"]').first();
    await amountInput.fill(mintAmount);
    const mintButton = page.getByRole("button", {name: /^\s*(mint|approve)/i}).first();
    await mintButton.click();
    // Approval then mint may be two steps; click through whatever appears.
    for (let step = 0; step < 3; ++step) {
      await page.waitForTimeout(3500);
      const next = page.getByRole("button", {name: /^\s*(mint|approve|confirm)/i}).first();
      if (await next.isEnabled().catch(() => false)) await next.click().catch(() => {});
    }
    await page.waitForTimeout(3500);

    const usdfrAfter = await balanceOf(manifest.usdfr, USER);
    expect(
      usdfrAfter,
      `USDfr balance must increase on chain after minting (before ${usdfrBefore}, after ${usdfrAfter})`,
    ).toBeGreaterThan(usdfrBefore);

    // STAKE: the stake card is a separate control group. Target its input by position rather
    // than by walking the DOM for an ancestor: `filter({has: ...})` over `div` evaluated across
    // the whole tree and hung the run past its timeout twice.
    const inputs = page.locator('input[type="text"], input[type="number"]');
    await inputs.nth(1).fill("200").catch(() => {});
    for (let step = 0; step < 4; ++step) {
      const next = page.getByRole("button", {name: /^\s*(stake|approve)/i}).first();
      if (!(await next.isEnabled().catch(() => false))) break;
      await next.click().catch(() => {});
      await page.waitForTimeout(4000);
    }

    const sharesAfter = await balanceOf(manifest.vault, USER);
    console.log(
      `[evidence] USDfr ${usdfrBefore} -> ${usdfrAfter}; vault shares ${sharesBefore} -> ${sharesAfter}`,
    );
    expect(
      sharesAfter,
      `vault shares must increase on chain after staking (before ${sharesBefore}, after ${sharesAfter})`,
    ).toBeGreaterThan(sharesBefore);
  });
});
