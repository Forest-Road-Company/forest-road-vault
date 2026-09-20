import {test, expect} from "@playwright/test";
import {readFileSync} from "node:fs";
import path from "node:path";
import {keccak_256} from "@noble/hashes/sha3";

/**
 * THE ETHEREUM CURATOR SURFACE ON /curators, against the live mainnet deployment on a pinned fork.
 *
 * The UI account is the manifest's anchor curator, which governance approved in every collateral
 * class on mainnet, so the page's approval read is the real one. It is funded with USDfr by
 * impersonating the sUSDfr vault on anvil (impersonation cannot touch the real chain). The drive
 * then approves, posts into class 1 and withdraws part of it through the real buttons. Success is
 * asserted from CHAIN STATE read independently over JSON-RPC, never from what the UI says happened.
 *
 * Serve the app separately with the local-fork profile (chain 31337, RPC 127.0.0.1:8549, addresses
 * from contracts/deployments/1-production-v1.json) and run with playwright.fork.config.ts.
 */

const root = path.resolve(process.cwd(), "..");
const manifest = JSON.parse(
  readFileSync(path.join(root, "contracts/deployments/1-production-v1.json"), "utf8"),
);
const RPC = process.env.MAINNET_FORK_RPC_URL ?? "http://127.0.0.1:8549";
const USER = (manifest.anchorCurator as string).toLowerCase();
const CHAIN_ID = 31337;
const CLASS = 1n;
const POST = 50n * 10n ** 18n;
const WITHDRAW = 20n * 10n ** 18n;

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
async function call(to: string, data: string): Promise<bigint> {
  return BigInt((await rpc("eth_call", [{to, data}, "latest"])) as string);
}
// Selectors are computed from the signatures so a typo cannot pass silently.
const selector = (sig: string) => "0x" + Buffer.from(keccak_256(new TextEncoder().encode(sig))).toString("hex").slice(0, 8);
const SEL = {
  balanceOf: selector("balanceOf(address)"),
  postedOf: selector("postedOf(uint256,address)"),
  poolBalance: selector("poolBalance(uint256)"),
  isApproved: selector("isApprovedCurator(uint256,address)"),
  transfer: selector("transfer(address,uint256)"),
};
const balanceOf = (token: string, who: string) => call(token, `${SEL.balanceOf}${pad(who)}`);
const postedOf = (classId: bigint, who: string) =>
  call(manifest.curator, `${SEL.postedOf}${pad(classId.toString(16))}${pad(who)}`);
const poolBalance = (classId: bigint) => call(manifest.curator, `${SEL.poolBalance}${pad(classId.toString(16))}`);

test.describe("Ethereum curator surface on /curators (pinned mainnet fork)", () => {
  test.beforeAll(async () => {
    await rpc("anvil_impersonateAccount", [USER]);
    await rpc("anvil_setBalance", [USER, "0x56BC75E2D63100000"]);
    // The anchor curator is approved on the real chain; assert it rather than assume it.
    expect(await call(manifest.curator, `${SEL.isApproved}${pad(CLASS.toString(16))}${pad(USER)}`)).toBe(1n);
    // Top the UI account up to 60 USDfr from the vault (a re-run against the same fork already
    // moved some). Vault impersonation is anvil-only.
    const target = 60n * 10n ** 18n;
    const have = await balanceOf(manifest.usdfr, USER);
    if (have < target) {
      const vault = manifest.vault as string;
      expect(await balanceOf(manifest.usdfr, vault)).toBeGreaterThanOrEqual(target - have);
      await rpc("anvil_impersonateAccount", [vault]);
      await rpc("anvil_setBalance", [vault, "0x56BC75E2D63100000"]);
      await rpc("eth_sendTransaction", [
        {from: vault, to: manifest.usdfr, data: `${SEL.transfer}${pad(USER)}${pad((target - have).toString(16))}`},
      ]);
    }
    expect(await balanceOf(manifest.usdfr, USER)).toBeGreaterThanOrEqual(target);
  });

  test("connect, post first-loss into class 1, withdraw part of it, verified on chain", async ({page, context}) => {
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

    const postedBefore = await postedOf(CLASS, USER);
    const poolBefore = await poolBalance(CLASS);
    const class2Before = await postedOf(2n, USER);

    await page.goto("/curators", {waitUntil: "networkidle"});
    const eth = page.locator("#ethereum-position");
    await eth.scrollIntoViewIfNeeded();

    // Connect through the panel's own control unless wagmi already reconnected the injected
    // wallet (anchored regex: /connect/i also matches Disconnect).
    const disconnect = eth.getByRole("button", {name: /^\s*disconnect\s*$/i});
    if (!(await disconnect.isVisible().catch(() => false))) {
      await eth.getByRole("button", {name: /^\s*connect/i}).first().click();
      const wallet = eth.getByRole("button", {name: /E2E Wallet/i}).first();
      if (await wallet.isVisible().catch(() => false)) await wallet.click();
    }
    await expect(disconnect).toBeVisible();

    // The approval table is the real mainnet state: five classes, class 2 carrying the live posting.
    const table = eth.locator("table");
    await expect(table).toBeVisible();
    await expect(table.locator("tbody tr")).toHaveCount(5);
    const class2Text = await table.locator("tbody tr").nth(1).innerText();
    expect(class2Text).toContain(`${Number(class2Before / 10n ** 18n).toLocaleString("en-US")}`);

    // Class 1 is the first option and selected by default. Enter 50, approve, then post.
    await eth.getByRole("combobox").selectOption({index: 0});
    await eth.getByLabel(/amount in usdfr/i).fill("50");
    const approve = eth.getByRole("button", {name: /^\s*approve usdfr/i});
    await expect(approve).toBeEnabled();
    await approve.click();
    const postButton = eth.getByRole("button", {name: /^\s*post first-loss capital/i});
    await expect(postButton).toBeEnabled({timeout: 120_000});
    await postButton.click();
    // Chain state first, polled: the UI's own "Confirmed." is checked after, never relied on.
    await expect.poll(() => postedOf(CLASS, USER), {timeout: 120_000}).toBe(postedBefore + POST);
    expect(await poolBalance(CLASS)).toBe(poolBefore + POST);
    await expect(eth.getByText(/^confirmed\./i).first()).toBeVisible({timeout: 60_000});
    // The table re-read shows the posting; the withdrawable figure equals it (no live facilities in class 1).
    const whole = (v: bigint) => Number(v / 10n ** 18n).toLocaleString("en-US");
    await expect(table.locator("tbody tr").nth(0)).toContainText(`${whole(postedBefore + POST)} USDfr`, {timeout: 60_000});

    // Withdraw 20 of it.
    await eth.getByLabel(/amount in usdfr/i).fill("20");
    const withdraw = eth.getByRole("button", {name: /^\s*withdraw\s*$/i});
    await expect(withdraw).toBeEnabled();
    await withdraw.click();
    await expect.poll(() => postedOf(CLASS, USER), {timeout: 120_000}).toBe(postedBefore + POST - WITHDRAW);
    expect(await poolBalance(CLASS)).toBe(poolBefore + POST - WITHDRAW);
    await expect(table.locator("tbody tr").nth(0)).toContainText(`${whole(postedBefore + POST - WITHDRAW)} USDfr`, {timeout: 60_000});

    // Class 2 is fully required by the live facility: the page must refuse a withdrawal there.
    await eth.getByRole("combobox").selectOption({index: 1});
    await eth.getByLabel(/amount in usdfr/i).fill("1");
    await expect(eth.getByRole("button", {name: /^\s*withdraw\s*$/i})).toBeDisabled();
    await expect(eth.getByText(/limited to 0 USDfr/i)).toBeVisible();
    expect(await postedOf(2n, USER)).toBe(class2Before);
  });
});
