import {readFileSync} from "node:fs";
import {mkdir, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {
  createPublicClient,
  encodeFunctionData,
  formatUnits,
  http,
  parseUnits,
  type Address,
  type Hash,
} from "viem";
import {
  expect,
  test,
  type Browser,
  type BrowserContext,
  type Locator,
  type Page,
  type TestInfo,
} from "@playwright/test";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const manifest = JSON.parse(
  readFileSync(path.join(root, "contracts/deployments/11155111.json"), "utf8"),
) as Record<string, unknown>;

const RPC_URL = process.env.SEPOLIA_FORK_RPC_URL ?? "http://127.0.0.1:8548";
const PINNED_BLOCK = 11_386_576n;
const PINNED_BLOCK_HASH =
  "0x02a1a7a0d42f3f289c3ff2936accb98c49b0caddbf1ce357092298828f65905c";
const SOURCE_COMMIT = "7eef49b61514414aab634408d32f6d354263a192";
const LOCAL_CHAIN_ID = 31_337;
const DEPLOYER = manifest.deployer as Address;
const KYC_ACCOUNT = "0x2000000000000000000000000000000000000002" as Address;
const NON_KYC_ACCOUNT = "0x1000000000000000000000000000000000000001" as Address;
const CONTRACTS = {
  stable: manifest.stable as Address,
  usdfr: manifest.usdfr as Address,
  vault: manifest.vault as Address,
  compliance: manifest.compliance as Address,
  controller: manifest.controller as Address,
  reserves: manifest.reserves as Address,
  queue: manifest.queue as Address,
  points: manifest.points as Address,
};
const evidencePath = path.join(
  root,
  "docs/deployments/sepolia-frontend-browser-e2e-block-11386576.json",
);

const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{name: "account", type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
] as const;

const complianceAbi = [
  {
    type: "function",
    name: "isAllowed",
    stateMutability: "view",
    inputs: [{name: "account", type: "address"}],
    outputs: [{type: "bool"}],
  },
  {
    type: "function",
    name: "setAllowed",
    stateMutability: "nonpayable",
    inputs: [{name: "account", type: "address"}, {name: "allowed", type: "bool"}],
    outputs: [],
  },
] as const;

const queueAbi = [
  {
    type: "function",
    name: "totalRequests",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "request",
    stateMutability: "view",
    inputs: [{name: "requestId", type: "uint256"}],
    outputs: [
      {name: "owner", type: "address"},
      {name: "sharesRemaining", type: "uint256"},
      {name: "assetsClaimable", type: "uint256"},
      {name: "epochRequested", type: "uint256"},
      {name: "requestedAt", type: "uint256"},
    ],
  },
  {
    type: "function",
    name: "redeemCooldown",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint64"}],
  },
  {
    type: "function",
    name: "epochEndsAt",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint64"}],
  },
  {
    type: "function",
    name: "currentEpoch",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "totalQueuedShares",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "closeEpoch",
    stateMutability: "nonpayable",
    inputs: [{name: "maxRequests", type: "uint256"}],
    outputs: [],
  },
] as const;

const reserveAbi = [
  {
    type: "function",
    name: "totalBackingValue",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
] as const;

const vaultAbi = [
  {
    type: "function",
    name: "totalAssets",
    stateMutability: "view",
    inputs: [],
    outputs: [{type: "uint256"}],
  },
] as const;

const pointsAbi = [
  {
    type: "function",
    name: "pointsOfWallet",
    stateMutability: "view",
    inputs: [{name: "wallet", type: "address"}],
    outputs: [{type: "uint256"}],
  },
  {
    type: "function",
    name: "trackedBalances",
    stateMutability: "view",
    inputs: [{name: "wallet", type: "address"}],
    outputs: [{name: "sUsdfrBalance", type: "uint256"}, {name: "usdfrBalance", type: "uint256"}],
  },
] as const;

const publicClient = createPublicClient({
  transport: http(RPC_URL),
  pollingInterval: 100,
});

type RpcBlock = {number: `0x${string}`; hash: Hash; timestamp: `0x${string}`};
type WalletTransaction = {
  hash: Hash;
  request: Record<string, unknown>;
  submittedAt: string;
};
type Diagnostics = {
  pageErrors: string[];
  consoleErrors: string[];
  failedRequests: string[];
};

let rpcId = 0;
async function rpc<T>(method: string, params: readonly unknown[] = []): Promise<T> {
  const response = await fetch(RPC_URL, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({jsonrpc: "2.0", id: ++rpcId, method, params}),
  });
  if (!response.ok) throw new Error(`${method} returned HTTP ${response.status}`);
  const payload = (await response.json()) as {
    result?: T;
    error?: {code: number; message: string; data?: unknown};
  };
  if (payload.error) {
    throw new Error(`${method} failed (${payload.error.code}): ${payload.error.message}`);
  }
  if (!("result" in payload)) throw new Error(`${method} omitted its JSON-RPC result`);
  return payload.result as T;
}

function fmtAmount(value: bigint, decimals: number, dp = 2): string {
  const [integer, fraction = ""] = formatUnits(value, decimals).split(".");
  const integerFormatted = BigInt(integer).toLocaleString("en-US");
  if (dp === 0) return integerFormatted;
  const fractionCut = fraction.slice(0, dp).replace(/0+$/, "");
  return fractionCut ? `${integerFormatted}.${fractionCut}` : integerFormatted;
}

function shortAddress(address: Address): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

async function balanceOf(token: Address, account: Address): Promise<bigint> {
  return publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account],
  });
}

async function setUpImpersonatedAccount(account: Address): Promise<void> {
  await rpc("anvil_impersonateAccount", [account]);
  await rpc("anvil_setBalance", [account, "0x56bc75e2d63100000"]); // 100 ETH, local only
}

function captureDiagnostics(page: Page): Diagnostics {
  const diagnostics: Diagnostics = {pageErrors: [], consoleErrors: [], failedRequests: []};
  page.on("pageerror", (error) => diagnostics.pageErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") diagnostics.consoleErrors.push(message.text());
  });
  page.on("requestfailed", (request) => {
    diagnostics.failedRequests.push(
      `${request.method()} ${request.url()}: ${request.failure()?.errorText ?? "unknown error"}`,
    );
  });
  return diagnostics;
}

function expectNoBrowserErrors(diagnostics: Diagnostics): void {
  expect(diagnostics.pageErrors, "uncaught browser errors").toEqual([]);
  expect(diagnostics.consoleErrors, "browser console errors").toEqual([]);
}

async function createWalletPage(
  browser: Browser,
  account: Address,
  initialChainId = LOCAL_CHAIN_ID,
): Promise<{context: BrowserContext; page: Page; diagnostics: Diagnostics}> {
  const context = await browser.newContext({viewport: {width: 1440, height: 1100}});
  await context.addInitScript(
    ({account: injectedAccount, rpcUrl, initialChain, expectedChain}) => {
      type Listener = (...args: unknown[]) => void;
      const listeners = new Map<string, Set<Listener>>();
      const transactions: WalletTransaction[] = [];
      let chainId = initialChain;
      let requestId = 0;

      const emit = (event: string, ...args: unknown[]) => {
        for (const listener of listeners.get(event) ?? []) listener(...args);
      };

      const provider = {
        isMetaMask: true,
        isConnected: () => true,
        get selectedAddress() {
          return injectedAccount;
        },
        get chainId() {
          return `0x${chainId.toString(16)}`;
        },
        get networkVersion() {
          return String(chainId);
        },
        _metamask: {isUnlocked: async () => true},
        on(event: string, listener: Listener) {
          const existing = listeners.get(event) ?? new Set<Listener>();
          existing.add(listener);
          listeners.set(event, existing);
          return provider;
        },
        removeListener(event: string, listener: Listener) {
          listeners.get(event)?.delete(listener);
          return provider;
        },
        async request(args: {method: string; params?: readonly unknown[]}) {
          const params = args.params ?? [];
          if (args.method === "eth_requestAccounts" || args.method === "eth_accounts") {
            return [injectedAccount];
          }
          if (args.method === "eth_coinbase") return injectedAccount;
          if (args.method === "eth_chainId") return `0x${chainId.toString(16)}`;
          if (args.method === "net_version") return String(chainId);
          if (args.method === "wallet_getPermissions") {
            return [{parentCapability: "eth_accounts", caveats: []}];
          }
          if (args.method === "wallet_requestPermissions") {
            return [{parentCapability: "eth_accounts", caveats: []}];
          }
          if (args.method === "wallet_getCapabilities") return {};
          if (args.method === "wallet_switchEthereumChain") {
            const requested = (params[0] as {chainId?: string} | undefined)?.chainId;
            if (!requested) throw Object.assign(new Error("chainId is required"), {code: -32602});
            chainId = Number(BigInt(requested));
            emit("chainChanged", requested);
            return null;
          }
          if (args.method === "wallet_addEthereumChain") {
            chainId = expectedChain;
            emit("chainChanged", `0x${expectedChain.toString(16)}`);
            return null;
          }

          const response = await fetch(rpcUrl, {
            method: "POST",
            headers: {"content-type": "application/json"},
            body: JSON.stringify({jsonrpc: "2.0", id: ++requestId, method: args.method, params}),
          });
          if (!response.ok) {
            throw Object.assign(new Error(`${args.method} returned HTTP ${response.status}`), {
              code: -32000,
            });
          }
          const payload = (await response.json()) as {
            result?: unknown;
            error?: {code: number; message: string; data?: unknown};
          };
          if (payload.error) {
            throw Object.assign(new Error(payload.error.message), payload.error);
          }
          if (args.method === "eth_sendTransaction") {
            transactions.push({
              hash: payload.result as Hash,
              request: (params[0] ?? {}) as Record<string, unknown>,
              submittedAt: new Date().toISOString(),
            });
          }
          return payload.result;
        },
      };

      Object.defineProperty(window, "ethereum", {
        value: provider,
        configurable: true,
      });
      Object.defineProperty(window, "__FRV_E2E_WALLET__", {
        value: {provider, transactions},
        configurable: false,
      });

      const info = {
        uuid: "4f0d8b68-8821-4b35-8212-8f93d5f6c324",
        name: "Forest Road E2E Wallet",
        icon: "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' width='96' height='96'><rect width='96' height='96' fill='%2328644b'/><text x='48' y='58' text-anchor='middle' font-size='30' fill='white'>FR</text></svg>",
        rdns: "io.forestroad.e2e",
      };
      const announce = () =>
        window.dispatchEvent(
          new CustomEvent("eip6963:announceProvider", {detail: {info, provider}}),
        );
      window.addEventListener("eip6963:requestProvider", announce);
      window.setTimeout(announce, 0);
    },
    {
      account,
      rpcUrl: RPC_URL,
      initialChain: initialChainId,
      expectedChain: LOCAL_CHAIN_ID,
    },
  );
  const page = await context.newPage();
  return {context, page, diagnostics: captureDiagnostics(page)};
}

async function connectWallet(page: Page, account: Address): Promise<void> {
  await expect(page.getByRole("heading", {name: "Deposit, stake, redeem"})).toBeVisible();
  const connected = page.getByText(shortAddress(account), {exact: true});
  if (await connected.isVisible()) return;

  await page.getByRole("button", {name: "Connect wallet", exact: true}).click();
  const walletChoice = page.getByRole("button", {name: "Forest Road E2E Wallet", exact: true});
  await expect
    .poll(async () => (await connected.isVisible()) || (await walletChoice.isVisible()))
    .toBe(true);
  if (await walletChoice.isVisible()) await walletChoice.click();
  await expect(connected).toBeVisible();
}

async function walletTransactionCount(page: Page): Promise<number> {
  return page.evaluate(
    () =>
      (
        window as typeof window & {
          __FRV_E2E_WALLET__: {transactions: WalletTransaction[]};
        }
      ).__FRV_E2E_WALLET__.transactions.length,
  );
}

async function walletTransactionAt(page: Page, index: number): Promise<WalletTransaction> {
  return page.evaluate(
    (transactionIndex) =>
      (
        window as typeof window & {
          __FRV_E2E_WALLET__: {transactions: WalletTransaction[]};
        }
      ).__FRV_E2E_WALLET__.transactions[transactionIndex],
    index,
  );
}

async function runUiTransaction(
  page: Page,
  action: Locator,
  status: Locator,
  step: string,
  transactionEvidence: Array<Record<string, unknown>>,
): Promise<Hash> {
  const before = await walletTransactionCount(page);
  await expect(action, `${step} action should be enabled`).toBeEnabled();
  await action.click();
  await expect
    .poll(() => walletTransactionCount(page), {message: `${step} should submit one wallet tx`})
    .toBe(before + 1);

  const submitted = await walletTransactionAt(page, before);
  expect(submitted.hash).toMatch(/^0x[0-9a-f]{64}$/i);
  const receipt = await publicClient.waitForTransactionReceipt({hash: submitted.hash});
  expect(receipt.status, `${step} receipt`).toBe("success");
  await expect(status, `${step} UI status`).toContainText("Confirmed.");

  transactionEvidence.push({
    step,
    hash: submitted.hash,
    blockNumber: receipt.blockNumber.toString(),
    gasUsed: receipt.gasUsed.toString(),
    to: receipt.to,
    status: receipt.status,
  });
  return submitted.hash;
}

async function attachViewport(page: Page, testInfo: TestInfo, name: string): Promise<void> {
  await testInfo.attach(name, {
    body: await page.screenshot({type: "png"}),
    contentType: "image/png",
  });
}

test("pinned Sepolia fork: injected-wallet browser lifecycle and read reconciliation", async ({browser}, testInfo) => {
  const transactionEvidence: Array<Record<string, unknown>> = [];
  const journeys: Array<Record<string, unknown>> = [];
  const allDiagnostics: Array<{journey: string; diagnostics: Diagnostics}> = [];

  const initialChainId = await rpc<string>("eth_chainId");
  const initialHead = await rpc<RpcBlock>("eth_getBlockByNumber", ["latest", false]);
  expect(BigInt(initialChainId)).toBe(BigInt(LOCAL_CHAIN_ID));
  expect(BigInt(initialHead.number)).toBe(PINNED_BLOCK);
  expect(initialHead.hash.toLowerCase()).toBe(PINNED_BLOCK_HASH);

  for (const address of Object.values(CONTRACTS)) {
    const code = await rpc<string>("eth_getCode", [address, "latest"]);
    expect(code, `deployed bytecode at ${address}`).not.toMatch(/^0x0*$/i);
  }
  await setUpImpersonatedAccount(DEPLOYER);
  await setUpImpersonatedAccount(KYC_ACCOUNT);
  await setUpImpersonatedAccount(NON_KYC_ACCOUNT);

  const deployerAllowed = await publicClient.readContract({
    address: CONTRACTS.compliance,
    abi: complianceAbi,
    functionName: "isAllowed",
    args: [DEPLOYER],
  });
  const nonKycAllowed = await publicClient.readContract({
    address: CONTRACTS.compliance,
    abi: complianceAbi,
    functionName: "isAllowed",
    args: [NON_KYC_ACCOUNT],
  });
  expect(deployerAllowed).toBe(true);
  expect(nonKycAllowed).toBe(false);

  // The deployer is the configured fee recipient and therefore protocol-exempt from points.
  // Use a separate, normal test user for the positive points journey, allowlisted through the
  // real testnet compliance-admin path on this disposable fork.
  const kycUserInitiallyAllowed = await publicClient.readContract({
    address: CONTRACTS.compliance,
    abi: complianceAbi,
    functionName: "isAllowed",
    args: [KYC_ACCOUNT],
  });
  expect(kycUserInitiallyAllowed).toBe(false);
  const allowlistData = encodeFunctionData({
    abi: complianceAbi,
    functionName: "setAllowed",
    args: [KYC_ACCOUNT, true],
  });
  const allowlistHash = await rpc<Hash>("eth_sendTransaction", [
    {from: DEPLOYER, to: CONTRACTS.compliance, data: allowlistData},
  ]);
  const allowlistReceipt = await publicClient.waitForTransactionReceipt({hash: allowlistHash});
  expect(allowlistReceipt.status).toBe("success");
  transactionEvidence.push({
    step: "fork-only setup: allowlist normal KYC browser user",
    origin: "testnet compliance admin, not the browser UI",
    hash: allowlistHash,
    blockNumber: allowlistReceipt.blockNumber.toString(),
    gasUsed: allowlistReceipt.gasUsed.toString(),
    to: allowlistReceipt.to,
    status: allowlistReceipt.status,
  });
  const kycUserAllowed = await publicClient.readContract({
    address: CONTRACTS.compliance,
    abi: complianceAbi,
    functionName: "isAllowed",
    args: [KYC_ACCOUNT],
  });
  expect(kycUserAllowed).toBe(true);

  // Wrong-network protection and recovery through the wallet's EIP-3326 switch path.
  {
    const {context, page, diagnostics} = await createWalletPage(browser, KYC_ACCOUNT, 1);
    await page.goto("/app");
    await connectWallet(page, KYC_ACCOUNT);
    await expect(page.getByText("Wrong network.", {exact: true})).toBeVisible();
    await expect(page.getByRole("button", {name: "Mint USDfr", exact: true})).toBeDisabled();
    await page.getByRole("button", {name: "Switch to local Sepolia fork", exact: true}).click();
    await expect(page.getByText("KYC verified", {exact: true})).toBeVisible();
    await expect(page.getByText("RPC mismatch.", {exact: true})).toHaveCount(0);
    journeys.push({
      name: "wrong-network guard and wallet switch",
      result: "passed",
      assertions: [
        "writes disabled on chain 1",
        "wallet_switchEthereumChain moved the injected wallet to 31337",
        "exact wallet/app RPC alignment restored",
      ],
    });
    allDiagnostics.push({journey: "wrong-network guard", diagnostics});
    expectNoBrowserErrors(diagnostics);
    await context.close();
  }

  // The UI must mirror the contract's primary-market-only KYC gate.
  {
    const stableBefore = await balanceOf(CONTRACTS.stable, NON_KYC_ACCOUNT);
    const {context, page, diagnostics} = await createWalletPage(browser, NON_KYC_ACCOUNT);
    await page.goto("/app");
    await connectWallet(page, NON_KYC_ACCOUNT);
    await expect(page.getByText("not KYC-verified", {exact: true})).toBeVisible();

    const mintPanel = page.locator("div.panel").filter({hasText: "Deposit & mint"});
    const stakePanel = page.locator("div.panel").filter({hasText: "USDfr → sUSDfr"});
    const redeemPanel = page.locator("div.panel").filter({hasText: "Your queue positions"});
    await expect(mintPanel.getByPlaceholder("0.00")).toBeDisabled();
    await expect(mintPanel.getByRole("button", {name: "Mint USDfr", exact: true})).toBeDisabled();
    await expect(redeemPanel.getByPlaceholder("0.00")).toBeDisabled();
    await expect(stakePanel.getByPlaceholder("0.00")).toBeEnabled();

    const faucet = mintPanel.getByRole("button", {name: "Get 10,000 tUSDC", exact: true});
    const faucetStatus = mintPanel
      .locator("div.border-t")
      .getByText("Confirmed.", {exact: true});
    await runUiTransaction(
      page,
      faucet,
      faucetStatus,
      "non-KYC testnet faucet",
      transactionEvidence,
    );
    const stableAfter = await balanceOf(CONTRACTS.stable, NON_KYC_ACCOUNT);
    expect(stableAfter - stableBefore).toBe(parseUnits("10000", 6));

    await redeemPanel.getByRole("button", {name: "sUSDfr", exact: true}).click();
    await expect(redeemPanel.getByPlaceholder("0.00")).toBeEnabled();
    await attachViewport(page, testInfo, "non-kyc-gating-and-permissionless-paths");
    journeys.push({
      name: "non-KYC contract/UI parity",
      result: "passed",
      assertions: [
        "mint disabled",
        "instant redeem disabled",
        "stake input enabled",
        "queue input enabled",
        "testnet faucet submitted and increased tUSDC by exactly 10,000",
      ],
    });
    allDiagnostics.push({journey: "non-KYC parity", diagnostics});
    expectNoBrowserErrors(diagnostics);
    await context.close();
  }

  // Full KYC user lifecycle, signed through the injected provider and reconciled independently.
  const stableAtStart = await balanceOf(CONTRACTS.stable, KYC_ACCOUNT);
  const usdfrAtStart = await balanceOf(CONTRACTS.usdfr, KYC_ACCOUNT);
  const sharesAtStart = await balanceOf(CONTRACTS.vault, KYC_ACCOUNT);
  const totalRequestsAtStart = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "totalRequests",
  });

  const {context, page, diagnostics} = await createWalletPage(browser, KYC_ACCOUNT);
  await page.goto("/app");
  await connectWallet(page, KYC_ACCOUNT);
  await expect(page.getByText("KYC verified", {exact: true})).toBeVisible();
  await expect(page.getByText("RPC mismatch.", {exact: true})).toHaveCount(0);

  const mintPanel = page.locator("div.panel").filter({hasText: "Deposit & mint"});
  const stakePanel = page.locator("div.panel").filter({hasText: "USDfr → sUSDfr"});
  const redeemPanel = page.locator("div.panel").filter({hasText: "Your queue positions"});

  const faucet = mintPanel.getByRole("button", {name: "Get 10,000 tUSDC", exact: true});
  await runUiTransaction(
    page,
    faucet,
    mintPanel.locator("div.border-t").getByText("Confirmed.", {exact: true}),
    "KYC testnet faucet",
    transactionEvidence,
  );
  const stableAfterFaucet = await balanceOf(CONTRACTS.stable, KYC_ACCOUNT);
  expect(stableAfterFaucet - stableAtStart).toBe(parseUnits("10000", 6));

  await mintPanel.getByPlaceholder("0.00").fill("100");
  const mintAction = mintPanel.getByRole("button", {
    name: /^(Approve tUSDC|Mint USDfr)$/,
  });
  await expect(mintAction).toBeEnabled();
  if ((await mintAction.textContent())?.trim() === "Approve tUSDC") {
    await runUiTransaction(
      page,
      mintAction,
      mintAction.locator("xpath=following-sibling::p[1]"),
      "approve tUSDC for mint",
      transactionEvidence,
    );
  }
  await expect(mintAction).toHaveText("Mint USDfr");
  await runUiTransaction(
    page,
    mintAction,
    mintAction.locator("xpath=following-sibling::p[1]"),
    "mint 100 USDfr",
    transactionEvidence,
  );
  const stableAfterMint = await balanceOf(CONTRACTS.stable, KYC_ACCOUNT);
  const usdfrAfterMint = await balanceOf(CONTRACTS.usdfr, KYC_ACCOUNT);
  expect(stableAfterFaucet - stableAfterMint).toBe(parseUnits("100", 6));
  expect(usdfrAfterMint - usdfrAtStart).toBe(parseUnits("100", 18));

  await stakePanel.getByPlaceholder("0.00").fill("50");
  const stakeAction = stakePanel.getByRole("button", {name: /^(Approve USDfr|Stake)$/});
  await expect(stakeAction).toBeEnabled();
  if ((await stakeAction.textContent())?.trim() === "Approve USDfr") {
    await runUiTransaction(
      page,
      stakeAction,
      stakeAction.locator("xpath=following-sibling::p[1]"),
      "approve USDfr for stake",
      transactionEvidence,
    );
  }
  await expect(stakeAction).toHaveText("Stake");
  await runUiTransaction(
    page,
    stakeAction,
    stakeAction.locator("xpath=following-sibling::p[1]"),
    "stake 50 USDfr",
    transactionEvidence,
  );
  const usdfrAfterStake = await balanceOf(CONTRACTS.usdfr, KYC_ACCOUNT);
  const sharesAfterStake = await balanceOf(CONTRACTS.vault, KYC_ACCOUNT);
  expect(usdfrAfterMint - usdfrAfterStake).toBe(parseUnits("50", 18));
  expect(sharesAfterStake).toBeGreaterThan(sharesAtStart);

  await redeemPanel.getByPlaceholder("0.00").fill("10");
  const instantRedeem = redeemPanel.getByRole("button", {name: "Redeem to tUSDC", exact: true});
  await runUiTransaction(
    page,
    instantRedeem,
    instantRedeem.locator("xpath=following-sibling::p[1]"),
    "instant redeem 10 USDfr",
    transactionEvidence,
  );
  const stableAfterInstantRedeem = await balanceOf(CONTRACTS.stable, KYC_ACCOUNT);
  const usdfrAfterInstantRedeem = await balanceOf(CONTRACTS.usdfr, KYC_ACCOUNT);
  expect(stableAfterInstantRedeem - stableAfterMint).toBe(parseUnits("10", 6));
  expect(usdfrAfterStake - usdfrAfterInstantRedeem).toBe(parseUnits("10", 18));

  await redeemPanel.getByRole("button", {name: "sUSDfr", exact: true}).click();
  await redeemPanel.getByPlaceholder("0.00").fill("1");
  await redeemPanel.getByRole("checkbox").check();
  const queueAction = redeemPanel.getByRole("button", {
    name: /^(Approve sUSDfr|Request redemption)$/,
  });
  await expect(queueAction).toBeEnabled();
  if ((await queueAction.textContent())?.trim() === "Approve sUSDfr") {
    await runUiTransaction(
      page,
      queueAction,
      queueAction.locator("xpath=following-sibling::p[1]"),
      "approve sUSDfr for queue",
      transactionEvidence,
    );
  }
  await expect(queueAction).toHaveText("Request redemption");
  await runUiTransaction(
    page,
    queueAction,
    queueAction.locator("xpath=following-sibling::p[1]"),
    "request queued redemption of 1 sUSDfr",
    transactionEvidence,
  );

  const requestId = totalRequestsAtStart;
  const totalRequestsAfter = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "totalRequests",
  });
  expect(totalRequestsAfter).toBe(totalRequestsAtStart + 1n);
  const requestAfterSubmission = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "request",
    args: [requestId],
  });
  expect(requestAfterSubmission[0].toLowerCase()).toBe(KYC_ACCOUNT.toLowerCase());
  expect(requestAfterSubmission[1]).toBe(parseUnits("1", 24));
  expect(requestAfterSubmission[2]).toBe(0n);
  expect(sharesAfterStake - (await balanceOf(CONTRACTS.vault, KYC_ACCOUNT))).toBe(
    parseUnits("1", 24),
  );
  await expect(redeemPanel.getByText(`#${requestId.toString()}`, {exact: true})).toBeVisible();

  const cooldown = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "redeemCooldown",
  });
  const epochEndsAt = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "epochEndsAt",
  });
  const eligibleAt = requestAfterSubmission[4] + cooldown;
  const settlementTimestamp = (eligibleAt > epochEndsAt ? eligibleAt : epochEndsAt) + 1n;
  await rpc("evm_setNextBlockTimestamp", [Number(settlementTimestamp)]);
  await rpc("evm_mine");

  const closeData = encodeFunctionData({
    abi: queueAbi,
    functionName: "closeEpoch",
    args: [100n],
  });
  const closeHash = await rpc<Hash>("eth_sendTransaction", [
    {from: DEPLOYER, to: CONTRACTS.queue, data: closeData},
  ]);
  const closeReceipt = await publicClient.waitForTransactionReceipt({hash: closeHash});
  expect(closeReceipt.status).toBe("success");
  transactionEvidence.push({
    step: "permissionless keeper closeEpoch(100)",
    origin: "external local-fork keeper, not the browser UI",
    hash: closeHash,
    blockNumber: closeReceipt.blockNumber.toString(),
    gasUsed: closeReceipt.gasUsed.toString(),
    to: closeReceipt.to,
    status: closeReceipt.status,
  });

  const requestAfterSettlement = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "request",
    args: [requestId],
  });
  expect(requestAfterSettlement[1]).toBe(0n);
  expect(requestAfterSettlement[2]).toBeGreaterThan(0n);

  // Do not reload: the Claim button must appear because the UI observed the external queue event.
  const claim = redeemPanel.getByRole("button", {name: "Claim", exact: true});
  await expect(claim).toBeVisible({timeout: 45_000});
  const usdfrBeforeClaim = await balanceOf(CONTRACTS.usdfr, KYC_ACCOUNT);
  await runUiTransaction(
    page,
    claim,
    redeemPanel.locator("div.border-t").getByText("Confirmed.", {exact: true}).last(),
    `claim queue request ${requestId.toString()}`,
    transactionEvidence,
  );
  const usdfrAfterClaim = await balanceOf(CONTRACTS.usdfr, KYC_ACCOUNT);
  const requestAfterClaim = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "request",
    args: [requestId],
  });
  expect(usdfrAfterClaim - usdfrBeforeClaim).toBe(requestAfterSettlement[2]);
  expect(requestAfterClaim[2]).toBe(0n);
  await redeemPanel.scrollIntoViewIfNeeded();
  await attachViewport(page, testInfo, "kyc-lifecycle-after-queue-claim");

  const sharesAfterClaim = await balanceOf(CONTRACTS.vault, KYC_ACCOUNT);
  await page
    .getByRole("navigation")
    .getByRole("link", {name: "Points", exact: true})
    .click();
  await expect(page.getByRole("heading", {name: "Participation, measured honestly"})).toBeVisible();
  await expect(page.getByText("Your points", {exact: true})).toBeVisible();
  const points = await publicClient.readContract({
    address: CONTRACTS.points,
    abi: pointsAbi,
    functionName: "pointsOfWallet",
    args: [KYC_ACCOUNT],
  });
  const tracked = await publicClient.readContract({
    address: CONTRACTS.points,
    abi: pointsAbi,
    functionName: "trackedBalances",
    args: [KYC_ACCOUNT],
  });
  expect(points).toBeGreaterThan(0n);
  expect(tracked[0]).toBe(sharesAfterClaim);
  expect(tracked[1]).toBe(usdfrAfterClaim);
  const pointsSummary = page.locator("div.panel").filter({hasText: "Your points"});
  await expect(pointsSummary).toContainText(fmtAmount(points, 18, 4));
  const stakedPointsCard = page.locator("div.panel").filter({
    has: page.getByRole("heading", {name: "sUSDfr staked", exact: true}),
  });
  const heldPointsCard = page.locator("div.panel").filter({
    has: page.getByRole("heading", {name: "USDfr held", exact: true}),
  });
  await expect(stakedPointsCard).toContainText(
    `Tracked: ${fmtAmount(tracked[0], 24, 4)} sUSDfr`,
  );
  await expect(heldPointsCard).toContainText(
    `Tracked: ${fmtAmount(tracked[1], 18, 4)} USDfr`,
  );
  await attachViewport(page, testInfo, "points-reconciled-to-onchain-ledger");

  await page
    .getByRole("navigation")
    .getByRole("link", {name: "Transparency", exact: true})
    .click();
  await expect(
    page.getByRole("heading", {name: "The forked book, verifiable on-chain"}),
  ).toBeVisible();
  const supply = await publicClient.readContract({
    address: CONTRACTS.usdfr,
    abi: erc20Abi,
    functionName: "totalSupply",
  });
  const backing = await publicClient.readContract({
    address: CONTRACTS.reserves,
    abi: reserveAbi,
    functionName: "totalBackingValue",
  });
  const vaultAssets = await publicClient.readContract({
    address: CONTRACTS.vault,
    abi: vaultAbi,
    functionName: "totalAssets",
  });
  const currentEpoch = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "currentEpoch",
  });
  const queuedShares = await publicClient.readContract({
    address: CONTRACTS.queue,
    abi: queueAbi,
    functionName: "totalQueuedShares",
  });
  expect(supply).toBeLessThanOrEqual(backing);
  await expect(page.getByText("holding", {exact: true})).toBeVisible();
  const backingPanel = page.locator("div.panel").filter({hasText: "The backing invariant"});
  await expect(backingPanel).toContainText(fmtAmount(supply, 18));
  await expect(backingPanel).toContainText(`$${fmtAmount(backing, 18)}`);
  const vaultPanel = page.locator("div.panel").filter({hasText: "sUSDfr vault"});
  await expect(vaultPanel).toContainText(`${fmtAmount(vaultAssets, 18)} USDfr`);
  const queuePanel = page.locator("div.panel").filter({hasText: "Redemption queue"});
  await expect(queuePanel).toContainText(`Current epoch${currentEpoch.toString()}`);
  await expect(queuePanel).toContainText(
    `Queued shares${fmtAmount(queuedShares, 24, 4)} sUSDfr`,
  );
  await expect(page.getByText("local Sepolia fork", {exact: true})).toBeVisible();
  await attachViewport(page, testInfo, "transparency-reconciled-to-fork-state");

  journeys.push({
    name: "KYC browser wallet lifecycle",
    result: "passed",
    assertions: [
      "faucet +10,000 tUSDC",
      "approve and mint 100 USDfr",
      "approve and stake 50 USDfr",
      "instant redeem 10 USDfr",
      "approve and queue 1 sUSDfr",
      "external keeper settlement observed without reload",
      "claim paid exact assetsClaimable",
      "points display matched PointsModule",
      "transparency supply/backing/vault/queue displays matched direct reads",
    ],
  });
  allDiagnostics.push({journey: "KYC lifecycle and dashboards", diagnostics});
  expectNoBrowserErrors(diagnostics);

  const finalHead = await rpc<RpcBlock>("eth_getBlockByNumber", ["latest", false]);
  const evidence = {
    schemaVersion: 1,
    status: "passed",
    generatedAt: new Date().toISOString(),
    scope: "Browser + injected EIP-1193 wallet E2E on a disposable local fork; no live write",
    sourceCommit: SOURCE_COMMIT,
    deploymentManifest: "contracts/deployments/11155111.json",
    fork: {
      upstreamNetwork: "Ethereum Sepolia",
      upstreamChainId: 11_155_111,
      localChainId: LOCAL_CHAIN_ID,
      rpcUrl: RPC_URL,
      pinnedBlock: PINNED_BLOCK.toString(),
      pinnedBlockHash: PINNED_BLOCK_HASH,
      initialHead: {number: BigInt(initialHead.number).toString(), hash: initialHead.hash},
      finalDisposableHead: {number: BigInt(finalHead.number).toString(), hash: finalHead.hash},
    },
    browser: {
      engine: "Chromium",
      executable: process.env.PLAYWRIGHT_CHROME_PATH ?? "system Google Chrome",
      version: browser.version(),
      playwright: "1.62.1",
    },
    walletHarness: {
      transport: "injected EIP-1193 + EIP-6963 provider",
      signing: "Anvil impersonation on chain 31337; no private key loaded into the browser",
      appAndWalletRpc: RPC_URL,
      deploymentOperatorAndProtocolExemptFeeRecipient: DEPLOYER,
      kycAccount: KYC_ACCOUNT,
      nonKycAccount: NON_KYC_ACCOUNT,
    },
    journeys,
    transactions: transactionEvidence,
    reconciliations: {
      kyc: {
        deployer: deployerAllowed,
        normalUserBeforeForkSetup: kycUserInitiallyAllowed,
        normalUserAfterForkSetup: kycUserAllowed,
        nonKycAccount: nonKycAllowed,
      },
      kycLifecycle: {
        stableAtStart: stableAtStart.toString(),
        stableAfterFaucet: stableAfterFaucet.toString(),
        stableAfterMint: stableAfterMint.toString(),
        stableAfterInstantRedeem: stableAfterInstantRedeem.toString(),
        usdfrAtStart: usdfrAtStart.toString(),
        usdfrAfterMint: usdfrAfterMint.toString(),
        usdfrAfterStake: usdfrAfterStake.toString(),
        usdfrAfterInstantRedeem: usdfrAfterInstantRedeem.toString(),
        usdfrAfterClaim: usdfrAfterClaim.toString(),
        sharesAtStart: sharesAtStart.toString(),
        sharesAfterStake: sharesAfterStake.toString(),
        sharesAfterClaim: sharesAfterClaim.toString(),
        queueRequestId: requestId.toString(),
        queueClaimAssets: requestAfterSettlement[2].toString(),
      },
      points: {
        pointsOfWallet: points.toString(),
        trackedShares: tracked[0].toString(),
        trackedUsdfr: tracked[1].toString(),
      },
      transparency: {
        supply: supply.toString(),
        backing: backing.toString(),
        invariantHolding: supply <= backing,
        vaultAssets: vaultAssets.toString(),
        currentEpoch: currentEpoch.toString(),
        queuedShares: queuedShares.toString(),
      },
    },
    browserDiagnostics: allDiagnostics,
    attachments: [
      "non-kyc-gating-and-permissionless-paths",
      "kyc-lifecycle-after-queue-claim",
      "points-reconciled-to-onchain-ledger",
      "transparency-reconciled-to-fork-state",
    ],
    qualification: {
      userFacingFrontendPathsCovered: true,
      everyContractAbiFunctionCoveredThroughFrontend: false,
      note: "The frontend intentionally exposes user journeys, not all 661 deployed ABI entries; direct and curated fork evidence cover the full contract surface.",
    },
  };
  await mkdir(path.dirname(evidencePath), {recursive: true});
  await writeFile(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`);
  await context.close();
});
