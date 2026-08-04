/**
 * Pure-logic test harness (run: npm run test:logic — Node 24 type-stripping).
 * Exercises fmtAmount/fmtCountdown roundtrips and documents viem parseUnits
 * edge behavior the write cards depend on (notably: parseUnits ROUNDS excess
 * fraction digits — which is why AmountInput caps input at token precision).
 * Excluded from the app's tsconfig; not shipped.
 */
import {existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {spawnSync} from "node:child_process";
import {createHash} from "node:crypto";
import {
  encodeAbiParameters,
  getContractAddress,
  keccak256,
  parseUnits,
  stringToHex,
} from "viem";
import {
  CURATOR_ABI,
  IMPAIRMENT_SOURCE_ABI,
  POINTS_ABI,
  PROTOCOL_ERRORS,
  QUEUE_ABI,
  VAULT_ABI,
} from "./src/lib/abi.ts";
import {ERROR_MESSAGES} from "./src/lib/errors.ts";
import {fmtAmount, fmtCountdown, shortAddress} from "./src/lib/format.ts";
import {eligibleAtSeconds, isEligible, secondsUntilEligible} from "./src/lib/queue.ts";
import {
  formatBps,
  indicativeAnnualIncome,
  remainingDirectDepositBasis,
} from "./src/lib/yield.ts";
import {
  calculateBookYield,
  calculateCollateralValueMetrics,
  calculateHistoricalNetDefaultMetrics,
  calculateProjectedSeniorIncome,
  decodeClassMaxMarkAge,
  decodeFacilityCollateral,
  decodeFacilityEconomics,
} from "./src/lib/book.ts";
import {nextUnreadBlockRange, readBlockRangeChunked} from "./src/lib/logs.ts";
import {probeRpcAlignment} from "./src/lib/rpcAlignment.ts";

let failures = 0;
function check(name: string, cond: boolean, detail?: string) {
  if (!cond) {
    failures++;
    console.log(`FAIL ${name}${detail ? " — " + detail : ""}`);
  } else {
    console.log(`ok   ${name}`);
  }
}

/**
 * Record an assertion that could not run because the file it inspects is not part of this
 * checkout — the curated public repository ships frontend/ without the CI workflow or the
 * operational tooling. Reported distinctly from `ok` and counted, so a run that skipped
 * assertions can never be read as one that passed them.
 */
let skipped = 0;
function skip(name: string) {
  skipped++;
  console.log(`SKIP ${name} — not present in this checkout`);
}

// ── fmtAmount basics ─────────────────────────────────────────────────
check("zero", fmtAmount(0n, 18) === "0", fmtAmount(0n, 18));
check("dust truncates down (never up)", fmtAmount(1n, 18, 2) === "0", fmtAmount(1n, 18, 2));
check("whole thousands separator", fmtAmount(60150n * 10n ** 18n, 18, 0) === "60,150");
check("6-dec tUSDC", fmtAmount(10_000_000_000n, 6) === "10,000");
check("truncate not round", fmtAmount(1_999_999n, 6, 2) === "1.99", fmtAmount(1_999_999n, 6, 2));
check("24-dec shares", fmtAmount(21n * 10n ** 27n, 24, 2) === "21,000", fmtAmount(21n * 10n ** 27n, 24, 2));
check("huge value", fmtAmount(10n ** 30n, 18, 0) === "1,000,000,000,000");

// ── max-button roundtrip: fmtAmount(x, d, d).replace(/,/g,"") must parse back EXACTLY ──
const cases: Array<[bigint, number]> = [
  [123_456_789_012_345_678_901n, 18],
  [1n, 18],
  [999_999n, 6],
  [10n ** 24n + 1n, 24],
  [60_150_000_000_000_000_000_000n, 18],
  [123n, 24],
  [0n, 6],
];
for (const [x, d] of cases) {
  const s = fmtAmount(x, d, d).replace(/,/g, "");
  const back = parseUnits(s, d);
  check(`roundtrip ${x} @${d}dec`, back === x, `${s} -> ${back}`);
}

// ── parseUnits edge inputs the AmountInput regex lets through ────────
for (const bad of ["", "."]) {
  let threw = false;
  try {
    parseUnits(bad, 6);
  } catch {
    threw = true;
  }
  console.log(`info parseUnits(${JSON.stringify(bad)}, 6) ${threw ? "throws (caught by card try/catch)" : "= " + parseUnits(bad, 6)}`);
}
// trailing dot
console.log(`info parseUnits("1.", 6) = ${(() => { try { return parseUnits("1.", 6).toString(); } catch { return "throws"; } })()}`);
// too many decimals — does viem round UP? (matters for max-button + typed input)
console.log(`info parseUnits("1.1234567", 6) = ${(() => { try { return parseUnits("1.1234567", 6).toString(); } catch { return "throws"; } })()}`);
console.log(`info parseUnits("0.9999999", 6) = ${(() => { try { return parseUnits("0.9999999", 6).toString(); } catch { return "throws"; } })()}`);

// ── fmtCountdown ─────────────────────────────────────────────────────
check("countdown negative", fmtCountdown(-5) === "now");
check("countdown 0", fmtCountdown(0) === "now");
// A sub-minute remainder must never read as "0m": beside a hard lock-up that reads as
// "no wait" when the wait is simply under a minute (re-check residual on FRV-FS-02).
check("countdown 59s", fmtCountdown(59) === "<1m", fmtCountdown(59));
check("countdown 1s", fmtCountdown(1) === "<1m", fmtCountdown(1));
check("countdown 60s is a real minute", fmtCountdown(60) === "1m", fmtCountdown(60));
check("countdown 2d5h", fmtCountdown(2 * 86400 + 5 * 3600 + 60) === "2d 5h");
check("countdown 1h10m", fmtCountdown(3600 + 600) === "1h 10m");

// ── queue eligibility (FRV-FS-02 pinned by VALUE, not by a source-string grep) ──
// Mirrors RedemptionQueue.eligibleToSettleAt and the settlement gate exactly.
const DAY = 86_400;
const COOLDOWN = BigInt(21 * DAY);
check(
  "eligibility: first settle is requestedAt + redeemCooldown",
  eligibleAtSeconds(1_000n, COOLDOWN) === 1_000n + COOLDOWN,
);
check(
  "eligibility: the hold is the cooldown, not the epoch heartbeat",
  secondsUntilEligible(1_000n, COOLDOWN, 1_000) === 21 * DAY,
);
check(
  "eligibility: one second before is still not eligible",
  secondsUntilEligible(1_000n, COOLDOWN, 1_000 + 21 * DAY - 1) === 1
    && isEligible(1_000n, COOLDOWN, 1_000 + 21 * DAY - 1) === false,
);
check(
  "eligibility: eligible exactly at requestedAt + cooldown",
  isEligible(1_000n, COOLDOWN, 1_000 + 21 * DAY) === true,
);
check(
  "eligibility: never reports a negative wait once past",
  secondsUntilEligible(1_000n, COOLDOWN, 1_000 + 99 * DAY) === 0,
);
// The cooldown must never be defaulted while it is still loading — understating the
// hold is exactly the defect FRV-FS-02 was raised for.
check(
  "eligibility: unloaded cooldown yields null, never zero",
  secondsUntilEligible(1_000n, undefined, 1_000) === null
    && isEligible(1_000n, undefined, 1_000) === false,
);
check(
  "eligibility: unknown clock yields null, never zero",
  secondsUntilEligible(1_000n, COOLDOWN, null) === null,
);

check("shortAddress", shortAddress("0x6a44e984aD7E0FF33D50E4670e4716bE3f79Eb0f") === "0x6a44…Eb0f");

// ── yield/accounting display math ─────────────────────────────────────
check("yield: expected annual income", indicativeAnnualIncome(12_345n, 500n) === 617n);
check(
  "yield: remaining direct-deposit basis is proportional",
  remainingDirectDepositBasis(1_000n, 100n, 25n) === 250n,
);
check(
  "yield: basis unavailable when current shares exceed direct deposits",
  remainingDirectDepositBasis(1_000n, 100n, 101n) === null,
);
check("yield: basis is zero for an empty position", remainingDirectDepositBasis(0n, 0n, 0n) === 0n);
check("yield: bps formatting", formatBps(512n) === "5.12%");

// ── book yield math ───────────────────────────────────────────────────
{
  const book = calculateBookYield([
    {outstandingPrincipal: 6_000n, interestRateBps: 1_400n, state: 4},
    {outstandingPrincipal: 10_000n, interestRateBps: 1_000n, state: 1},
    // Repaid facilities have zero deployedTo in reachable protocol state.
    {outstandingPrincipal: 0n, interestRateBps: 1_200n, state: 3},
  ]);
  check("book: all-outstanding WAC includes defaulted claims", book.weightedAverageBps === 1_150n);
  check("book: performing WAC excludes defaulted and repaid", book.performingWeightedAverageBps === 1_000n);
  check("book: performing principal", book.performingPrincipal === 10_000n);
  check("book: non-performing principal", book.nonPerformingPrincipal === 6_000n);
  check("book: performing gross annual interest", book.performingGrossAnnualInterest === 1_000n);
  check("book: all-outstanding gross annual interest", book.grossAnnualInterest === 1_840n);
}
{
  const empty = calculateBookYield([]);
  check("book: empty book has no invented yield", empty.weightedAverageBps === null);
  check("book: empty book has no performing yield", empty.performingWeightedAverageBps === null);
}
check(
  "book: viem named facility tuple decodes",
  decodeFacilityEconomics({interestRateBps: 1_000, state: 1})?.interestRateBps ===
    1_000n,
);
check(
  "book: positional facility tuple fallback decodes",
  decodeFacilityEconomics([
    5n, "borrower", "state", 10_000n, 5_000, 1_000, 0n, "recipient",
    0n, 0n, 0, 0, false, "schedule", "index", "renewal", "ref", 2,
  ])
    ?.state === 2,
);
check("book: partial facility response fails closed", decodeFacilityEconomics({state: 1}) === null);
check(
  "collateral: named facility tuple decodes without positional assumptions",
  decodeFacilityCollateral({classId: 5n, principal: 10_000n, ltvBps: 5_000})
    ?.ltvBps === 5_000n,
);
check(
  "collateral: partial facility tuple fails closed",
  decodeFacilityCollateral({classId: 5n, principal: 10_000n}) === null,
);
check(
  "collateral: named class tuple decodes maxMarkAge",
  decodeClassMaxMarkAge({maxMarkAge: 86_400}) === 86_400n,
);
check(
  "collateral: positional class tuple decodes maxMarkAge at index eight",
  decodeClassMaxMarkAge([
    "Digital Assets",
    1,
    true,
    5_000,
    365n * 86_400n,
    2_000,
    6_500,
    8_000,
    86_400,
  ]) === 86_400n,
);
check(
  "book: projected senior income is performing contractual interest after fee",
  calculateProjectedSeniorIncome(
    [
      {
        outstandingPrincipal: 10_000n,
        interestRateBps: 1_000n,
        state: 1,
      },
      {outstandingPrincipal: 6_000n, interestRateBps: 1_400n, state: 4},
    ],
    1_000n,
  ) === 900n,
);

// ── historical net default math ──────────────────────────────────────
{
  const defaults = calculateHistoricalNetDefaultMetrics(
    [
      {classId: 1, principal: 10_000n},
      {classId: 1, principal: 5_000n},
      {classId: 5, principal: 10_000n},
    ],
    [
      // A 2,000 write-off after recovery on class 1. The fully recovered
      // class-5 facility emits no LossRealized event and therefore adds zero.
      {classId: 1, loss: 2_000n},
    ],
    [1, 2, 3, 4, 5],
  );
  check("defaults: overall uses funded denominator", defaults.fundedPrincipal === 25_000n);
  check("defaults: overall sums net write-offs", defaults.netLoss === 2_000n);
  check("defaults: overall rate", defaults.rateBps === 800n);
  check("defaults: class rate", defaults.byClass.get(1)?.rateBps === 1_333n);
  check("defaults: fully recovered class is zero", defaults.byClass.get(5)?.rateBps === 0n);
  check("defaults: unfunded class is unavailable", defaults.byClass.get(2)?.rateBps === null);
}
{
  const emptyDefaults = calculateHistoricalNetDefaultMetrics([], [], [1, 2, 3, 4, 5]);
  check("defaults: empty overall is unavailable", emptyDefaults.rateBps === null);
  check("defaults: empty loss is zero", emptyDefaults.netLoss === 0n);
}
check(
  "book: projected senior income is not reduced by a removed reserve mechanism",
  calculateProjectedSeniorIncome(
    [
      {
        outstandingPrincipal: 100n,
        interestRateBps: 10_000n,
        state: 1,
      },
      {
        outstandingPrincipal: 100n,
        interestRateBps: 10_000n,
        state: 1,
      },
    ],
    0n,
  ) === 200n,
);

// ── collateral value vs protocol backing ───────────────────────────────
{
  const collateral = calculateCollateralValueMetrics(
    [
      {
        classId: 2,
        originalPrincipal: 40_000n,
        ltvBps: 7_500n,
        outstandingPrincipal: 30_000n,
        valuation: 0n,
        valuationAsOf: 0n,
      },
      {
        classId: 5,
        originalPrincipal: 10_000n,
        ltvBps: 5_000n,
        outstandingPrincipal: 10_000n,
        valuation: 20_000n,
        valuationAsOf: 950n,
      },
      {
        // Oracle history survives resolution, but collateral for a closed
        // facility must not remain in the live aggregate.
        classId: 5,
        originalPrincipal: 10_000n,
        ltvBps: 5_000n,
        outstandingPrincipal: 0n,
        valuation: 50_000n,
        valuationAsOf: 999n,
      },
    ],
    1_000n,
    100n,
  );
  check(
    "collateral: receivables scale their underwriting value with live principal/LTV",
    collateral.receivableReferenceValue === 40_000n,
  );
  check(
    "collateral: live MTM loan uses fresh attested mark",
    collateral.markedToMarketValue === 20_000n,
  );
  check(
    "collateral: closed facility is excluded",
    collateral.referenceValue === 60_000n,
  );
  check("collateral: aggregate is complete", collateral.complete);
  check(
    "collateral: coverage is separate from backing",
    collateral.coverageBps === 15_000n,
  );
}
{
  const position = {
    classId: 2,
    originalPrincipal: 40_000n,
    ltvBps: 5_000n,
    valuation: 0n,
    valuationAsOf: 0n,
  };
  const before = calculateCollateralValueMetrics(
    [{...position, outstandingPrincipal: 40_000n}],
    1_000n,
    100n,
  );
  const after = calculateCollateralValueMetrics(
    [{...position, outstandingPrincipal: 20_000n}],
    1_000n,
    100n,
  );
  check(
    "collateral: amortization cannot make receivable coverage rise",
    before.coverageBps === after.coverageBps &&
      before.referenceValue === 80_000n &&
      after.referenceValue === 40_000n,
  );
}
{
  const staleCollateral = calculateCollateralValueMetrics(
    [
      {
        classId: 5,
        originalPrincipal: 10_000n,
        ltvBps: 5_000n,
        outstandingPrincipal: 10_000n,
        valuation: 20_000n,
        valuationAsOf: 899n,
      },
    ],
    1_000n,
    100n,
  );
  check(
    "collateral: stale MTM mark fails aggregate closed",
    !staleCollateral.complete,
  );
  check(
    "collateral: stale aggregate does not publish coverage",
    staleCollateral.coverageBps === null,
  );
}

// ── bounded event history reads ───────────────────────────────────────
{
  const ranges: Array<[bigint, bigint]> = [];
  const values = await readBlockRangeChunked(
    10n,
    31n,
    async (from, to) => {
      ranges.push([from, to]);
      return [from, to];
    },
    10n,
  );
  check(
    "logs: inclusive ranges are contiguous and bounded",
    ranges.map(([from, to]) => `${from}-${to}`).join(",") ===
      "10-19,20-29,30-31",
  );
  check("logs: all chunk results are retained", values.length === 6);
}
check(
  "logs: reversed range is empty",
  (await readBlockRangeChunked(2n, 1n, async () => [1])).length === 0,
);
check(
  "logs: history cursor reads only unseen blocks",
  JSON.stringify(nextUnreadBlockRange(100n, 105n), (_, value) =>
    typeof value === "bigint" ? value.toString() : value,
  ) === '{"fromBlock":"101","toBlock":"105"}',
);
check(
  "logs: unchanged history cursor schedules no read",
  nextUnreadBlockRange(105n, 105n) === null,
);
let rejectedBadChunk = false;
try {
  await readBlockRangeChunked(1n, 2n, async () => [], 0n);
} catch {
  rejectedBadChunk = true;
}
check("logs: zero chunk size is rejected", rejectedBadChunk);

// ── wallet/app RPC alignment ──────────────────────────────────────────
{
  const hashA = `0x${"a".repeat(64)}`;
  const hashB = `0x${"b".repeat(64)}`;
  const rpc =
    ({
      block,
      chainId = 1,
      blockHash,
    }: {
      block: bigint;
      chainId?: number;
      blockHash: string;
    }) =>
    async ({method}: {method: string; params?: readonly unknown[]}) => {
      if (method === "eth_chainId") return `0x${chainId.toString(16)}`;
      if (method === "eth_blockNumber") return `0x${block.toString(16)}`;
      if (method === "eth_getBlockByNumber") return {hash: blockHash};
      throw new Error(`unexpected method ${method}`);
    };

  const aligned = await probeRpcAlignment(
    rpc({block: 100n, blockHash: hashA}),
    rpc({block: 101n, blockHash: hashA}),
    {expectedChainId: 1, requireExactTip: false},
  );
  check("RPC alignment: exact common remote state is accepted", aligned.aligned);

  const differentState = await probeRpcAlignment(
    rpc({block: 100n, chainId: 31337, blockHash: hashA}),
    rpc({block: 100n, chainId: 31337, blockHash: hashB}),
    {expectedChainId: 31337, requireExactTip: true},
  );
  check(
    "RPC alignment: equal-height forks with different hashes are rejected",
    !differentState.aligned,
  );

  const exactLocalState = await probeRpcAlignment(
    rpc({block: 100n, chainId: 31337, blockHash: hashA}),
    rpc({block: 100n, chainId: 31337, blockHash: hashA}),
    {expectedChainId: 31337, requireExactTip: true},
  );
  check(
    "RPC alignment: the exact same local tip is accepted",
    exactLocalState.aligned,
  );

  const divergentLocalTips = await probeRpcAlignment(
    rpc({block: 101n, chainId: 31337, blockHash: hashA}),
    rpc({block: 100n, chainId: 31337, blockHash: hashA}),
    {expectedChainId: 31337, requireExactTip: true},
  );
  check(
    "RPC alignment: local forks sharing an ancestor but not a tip are rejected",
    !divergentLocalTips.aligned,
  );

  const wrongChain = await probeRpcAlignment(
    rpc({block: 100n, chainId: 1, blockHash: hashA}),
    rpc({block: 100n, chainId: 31337, blockHash: hashA}),
    {expectedChainId: 31337, requireExactTip: true},
  );
  check(
    "RPC alignment: an endpoint on the wrong chain is rejected",
    !wrongChain.aligned,
  );

  const staleEndpoint = await probeRpcAlignment(
    rpc({block: 100n, blockHash: hashA}),
    rpc({block: 121n, blockHash: hashA}),
    {expectedChainId: 1, requireExactTip: false},
  );
  check("RPC alignment: excessive block drift is rejected", !staleEndpoint.aligned);
}

// ── production hardening drift guards ─────────────────────────────────
{
  const nextConfig = readFileSync(new URL("./next.config.ts", import.meta.url), "utf8");
  const docsPage = readFileSync(new URL("./src/app/docs/[slug]/page.tsx", import.meta.url), "utf8");
  const contractConfig = readFileSync(
    new URL("./src/config/contracts.ts", import.meta.url),
    "utf8",
  );
  const vaultFeeAbiConfig = readFileSync(
    new URL("./src/config/vaultFeeAbi.ts", import.meta.url),
    "utf8",
  );
  const packageJson = readFileSync(new URL("./package.json", import.meta.url), "utf8");
  /**
   * These three live OUTSIDE frontend/ and assert repo-wide assurance properties: that CI
   * actually runs the release gates, that the manifest exporter verifies the approved
   * receipt, and that bytecode reconciliation covers the immutable modules.
   *
   * The curated public repository ships frontend/ without the CI workflow or the
   * operational tooling, so these files are legitimately absent there. Read them
   * defensively and SKIP rather than pass when missing — the same discipline the fork
   * suites use for an absent RPC endpoint, so an incomplete run can never be mistaken for
   * a complete one. In the private repository all three are present and every assertion
   * below runs exactly as before.
   */
  const readOptional = (relative: string): string | null => {
    try {
      return readFileSync(new URL(relative, import.meta.url), "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
  };
  const ciWorkflow = readOptional("../.github/workflows/ci.yml");
  const manifestExporter = readOptional("../tools/frontend-env-from-manifest.mjs");
  const bytecodeReconciler = readOptional("../tools/compare-sepolia-implementations.mjs");
  const landingPage = readFileSync(new URL("./src/app/page.tsx", import.meta.url), "utf8");
  const termsPage = readFileSync(new URL("./src/app/terms/page.tsx", import.meta.url), "utf8");
  const legalPage = readFileSync(new URL("./src/app/legal/page.tsx", import.meta.url), "utf8");
  const riskPage = readFileSync(new URL("./src/app/risk/page.tsx", import.meta.url), "utf8");
  const securityDoc = readFileSync(
    new URL("./src/content/docs/security.md", import.meta.url),
    "utf8",
  );
  const wagmiConfig = readFileSync(new URL("./src/lib/wagmi.ts", import.meta.url), "utf8");
  const writeFlow = readFileSync(
    new URL("./src/components/app/useWriteFlow.ts", import.meta.url),
    "utf8",
  );
  const yieldPositionPanel = readFileSync(
    new URL("./src/components/app/YieldPositionPanel.tsx", import.meta.url),
    "utf8",
  );

  for (const header of [
    "Content-Security-Policy",
    "Referrer-Policy",
    "X-Content-Type-Options",
    "X-Frame-Options",
    "Permissions-Policy",
    "Strict-Transport-Security",
  ]) {
    check(`hardening: ${header} is configured`, nextConfig.includes(header));
  }
  check("hardening: Next removes its powered-by header", nextConfig.includes("poweredByHeader: false"));
  const inspectProductionCsp = (chainId: string) =>
    spawnSync(
      process.execPath,
      [
        "--experimental-strip-types",
        "--input-type=module",
        "-e",
        'const {default: createConfig} = await import("./next.config.ts"); const config = createConfig("phase-production-server"); const entries = await config.headers(); console.log(entries[0].headers.find((header) => header.key === "Content-Security-Policy").value);',
      ],
      {
        cwd: new URL(".", import.meta.url),
        encoding: "utf8",
        env: {...process.env, NODE_ENV: "production", NEXT_PUBLIC_CHAIN_ID: chainId},
      },
    );
  const localProductionCsp = inspectProductionCsp("31337");
  check(
    "hardening: production local-fork CSP permits loopback RPC without HTTPS upgrade",
    localProductionCsp.status === 0 &&
      localProductionCsp.stdout.includes("http://127.0.0.1:*") &&
      !localProductionCsp.stdout.includes("upgrade-insecure-requests"),
    localProductionCsp.stderr,
  );
  const mainnetProductionCsp = inspectProductionCsp("1");
  check(
    "hardening: production mainnet CSP retains HTTPS upgrade and excludes loopback",
    mainnetProductionCsp.status === 0 &&
      mainnetProductionCsp.stdout.includes("upgrade-insecure-requests") &&
      !mainnetProductionCsp.stdout.includes("http://127.0.0.1:*"),
    mainnetProductionCsp.stderr,
  );
  check("markdown: raw HTML is discarded", docsPage.includes("<ReactMarkdown skipHtml>"));
  check("markdown: no raw HTML injection remains", !docsPage.includes("dangerouslySetInnerHTML"));
  check(
    "mainnet config: zero addresses and duplicate module addresses are rejected",
    contractConfig.includes("must not be the zero address") &&
      contractConfig.includes("Mainnet contract configuration reuses"),
  );
  check(
    "mainnet config: approved deployment and manifest receipts are mandatory",
    contractConfig.includes("NEXT_PUBLIC_MAINNET_DEPLOYMENT_HASH") &&
      contractConfig.includes("NEXT_PUBLIC_MAINNET_MANIFEST_SHA256"),
  );
  check(
    "fork config: local RPCs require the dedicated non-canonical chain ID",
    contractConfig.includes("CHAIN_ID === 31337") &&
      contractConfig.includes("A loopback RPC must use the dedicated local-fork chain ID 31337"),
  );
  check(
    "vault ABI config: explicit addresses cannot inherit or contradict an ABI version",
    contractConfig.includes("NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION") &&
      contractConfig.includes("SUPPORTS_VAULT_FEE_ACCOUNTING") &&
      vaultFeeAbiConfig.includes("required whenever NEXT_PUBLIC_SUSDFR_ADDRESS is set") &&
      vaultFeeAbiConfig.includes("known legacy sUSDfr address") &&
      vaultFeeAbiConfig.includes("known ADR-0031 sUSDfr address"),
  );
  check(
    "fork config: connected reads and local write receipts use the active wallet provider",
    wagmiConfig.includes("configRef.current?.state.current") &&
      wagmiConfig.includes("shouldThrow") &&
      writeFlow.includes("transport: custom(walletClient)") &&
      writeFlow.includes("executionClient.waitForTransactionReceipt"),
  );
  check(
    "wallet config: Reown enables WalletConnect only when a valid public project ID is present",
    wagmiConfig.includes("NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID") &&
      wagmiConfig.includes("/^[0-9a-f]{32}$/i") &&
      wagmiConfig.includes("walletConnect({") &&
      wagmiConfig.includes("showQrModal: true") &&
      wagmiConfig.includes("function productionConnectors()") &&
      wagmiConfig.includes("connectors: [injected()]") &&
      nextConfig.includes("https://api.web3modal.org") &&
      nextConfig.includes("https://fonts.reown.com") &&
      nextConfig.includes("https://verify.walletconnect.org"),
  );
  check(
    "writes: wallet initialization races surface an actionable status",
    writeFlow.includes("Your wallet connection is still initializing. Please retry.") &&
      !writeFlow.includes("if (!publicClient || !walletClient || !address) return;"),
  );
  check(
    "history: polling advances from a cached cursor instead of rescanning deployment history",
    yieldPositionPanel.includes("nextUnreadBlockRange") &&
      yieldPositionPanel.includes("cursor.lastScannedBlock") &&
      yieldPositionPanel.includes("incrementalHistoryInFlight"),
  );
  check(
    "mainnet build: npm and direct Next builds invoke the receipt-bound verifier",
    packageJson.includes(
      '"prebuild": "node ../tools/frontend-env-from-manifest.mjs --verify-build-env"',
    ) &&
      nextConfig.includes("PHASE_PRODUCTION_BUILD") &&
      nextConfig.includes("--verify-build-env") &&
      nextConfig.includes("execFileSync"),
  );
  if (ciWorkflow === null) {
    skip("CI: every push and pull request runs contract and frontend release gates");
    skip("CI: frontend builds its own Foundry artifacts before contract-sync tests");
  } else {
    check(
      "CI: every push and pull request runs contract and frontend release gates",
      ciWorkflow.includes("pull_request:") &&
        ciWorkflow.includes("push:") &&
        ciWorkflow.includes("run: forge test") &&
        ciWorkflow.includes("run: npm test") &&
        ciWorkflow.includes("run: npm run lint") &&
        ciWorkflow.includes("run: npx tsc --noEmit") &&
        ciWorkflow.includes("run: npm run build"),
    );
    const frontendCiJob = ciWorkflow.slice(ciWorkflow.indexOf("\n  frontend:"));
    const frontendFoundrySetup = frontendCiJob.indexOf(
      "uses: foundry-rs/foundry-toolchain@v1",
    );
    const frontendForgeBuild = frontendCiJob.indexOf("run: forge build");
    const frontendNpmTest = frontendCiJob.indexOf("run: npm test");
    check(
      "CI: frontend builds its own Foundry artifacts before contract-sync tests",
      frontendFoundrySetup >= 0 &&
        frontendForgeBuild > frontendFoundrySetup &&
        frontendNpmTest > frontendForgeBuild,
    );
  }
  if (manifestExporter === null) {
    skip("manifest export: final receipt and independently archived manifest are verified");
  } else {
    check(
      "manifest export: final receipt and independently archived manifest are verified",
      manifestExporter.includes("MAINNET_APPROVED_DEPLOYMENT_HASH") &&
        manifestExporter.includes("MAINNET_APPROVED_MANIFEST_SHA256") &&
        manifestExporter.includes("loadEnvConfig(frontendDir)") &&
        manifestExporter.includes("principal-set receipt does not match") &&
        manifestExporter.includes("deployment receipt does not recompute") &&
        manifestExporter.includes('"eth_chainId"') &&
        manifestExporter.includes('"eth_getCode"'),
    );
  }
  if (bytecodeReconciler === null) {
    skip("bytecode reconciliation: immutable votes aggregator is in release scope");
  } else {
    check(
      "bytecode reconciliation: immutable votes aggregator is in release scope",
      bytecodeReconciler.includes('["votesAggregator", "GroveVotesAggregator.sol"') &&
        bytecodeReconciler.includes('kind: "immutable"'),
    );
  }
  check(
    "mainnet copy: landing, terms, disclosures and risk language are build-profile aware",
    landingPage.includes("IS_MAINNET") &&
      termsPage.includes("IS_MAINNET") &&
      legalPage.includes("IS_MAINNET") &&
      riskPage.includes("IS_MAINNET"),
  );
  check(
    "public assurance copy separates historical evidence from the current unaudited tree",
    securityDoc.includes("historical 855-test / 442-function / 2,427-line figures are superseded") &&
      securityDoc.includes("CURRENT_VERIFICATION.md") &&
      securityDoc.includes("No historical completion label or hash") &&
      securityDoc.includes("curator-capital settlement risk is explicitly accepted/deferred") &&
      !securityDoc.includes("Every Critical and High finding was fixed"),
  );

  const tempDir = mkdtempSync(join(tmpdir(), "frv-frontend-manifest-"));
  const tempManifest = join(tempDir, "1.json");
  const mockRpcModule = join(tempDir, "mock-mainnet-rpc.mjs");
  const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
  const bytes32 = (byte: string) => `0x${byte.repeat(64)}`;
  const canonicalUSDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const principalKeys = [
    "deployer",
    "opsAdmin",
    "frTreasury",
    "feeRecipient",
    "anchorCurator",
    "attester1",
    "attester2",
    "canonicalUSDC",
  ] as const;
  const manifest: Record<string, unknown> = {
    chainId: 1,
    deployedAtBlock: 25_500_000,
    production: true,
    profile: "mainnet-v1",
    keepOpsAdmin: false,
    stable: canonicalUSDC,
    canonicalUSDC,
    deployer: addr(101),
    opsAdmin: addr(102),
    frTreasury: addr(103),
    feeRecipient: addr(104),
    anchorCurator: addr(105),
    attester1: addr(106),
    attester2: addr(107),
    mainnetConfigHash: bytes32("1"),
    mainnetDeploymentScriptRuntimeHash: bytes32("2"),
    mainnetArtifactSetHash: bytes32("3"),
    mainnetApprovedTotalGasLimit: "100000000",
    mainnetMaxFeePerGasWei: "10000000000",
    mainnetPriorityFeePerGasWei: "10000000",
    mainnetMinDeployerEthWei: "1100000000000000000",
    mainnetExpectedDeployerNonce: 17,
  };
  const proxyCreateKeys = [
    "timelock",
    "grove",
    "compliance",
    "usdfr",
    "reserves",
    "controller",
    "vault",
    "points",
    "registry",
    "oracle",
    "bridge",
    "curator",
    "waterfall",
    "defaultManager",
    "assessedImpairmentSource",
    "queue",
    "sGrove",
  ] as const;
  let createNonce = 17n;
  for (const key of proxyCreateKeys) {
    manifest[`impl_${key}`] = getContractAddress({
      from: manifest.deployer as `0x${string}`,
      nonce: createNonce,
    });
    createNonce += 1n;
    manifest[key] = getContractAddress({
      from: manifest.deployer as `0x${string}`,
      nonce: createNonce,
    });
    createNonce += 1n;
  }
  manifest.votesAggregator = getContractAddress({
    from: manifest.deployer as `0x${string}`,
    nonce: createNonce,
  });
  createNonce += 1n;
  manifest.impl_governor = getContractAddress({
    from: manifest.deployer as `0x${string}`,
    nonce: createNonce,
  });
  createNonce += 1n;
  manifest.governor = getContractAddress({
    from: manifest.deployer as `0x${string}`,
    nonce: createNonce,
  });
  createNonce += 1n;
  manifest.mtmExecutor = getContractAddress({
    from: manifest.deployer as `0x${string}`,
    nonce: createNonce,
  });
  const principalSetHash = keccak256(
    encodeAbiParameters(
      [{type: "string"}, ...principalKeys.map(() => ({type: "address"}))],
      [
        "FOREST_ROAD_MAINNET_V1_PRINCIPAL_SET",
        ...principalKeys.map((key) => manifest[key] as `0x${string}`),
      ],
    ),
  );
  manifest.mainnetPrincipalSetHash = principalSetHash;
  const gasPolicyHash = keccak256(
    encodeAbiParameters(
      [
        {type: "string"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
      ],
      [
        "FOREST_ROAD_MAINNET_V1_GAS_POLICY",
        BigInt(manifest.mainnetApprovedTotalGasLimit as string),
        BigInt(manifest.mainnetMaxFeePerGasWei as string),
        BigInt(manifest.mainnetPriorityFeePerGasWei as string),
        BigInt(manifest.mainnetMinDeployerEthWei as string),
      ],
    ),
  );
  manifest.mainnetGasPolicyHash = gasPolicyHash;
  const deploymentHash = keccak256(
    encodeAbiParameters(
      [
        {type: "string"},
        {type: "uint256"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "bytes32"},
        {type: "uint256"},
      ],
      [
        "FOREST_ROAD_MAINNET_V1_DEPLOYMENT",
        1n,
        keccak256(stringToHex("mainnet-v1")),
        manifest.mainnetConfigHash as `0x${string}`,
        manifest.mainnetArtifactSetHash as `0x${string}`,
        principalSetHash,
        gasPolicyHash,
        17n,
      ],
    ),
  );
  manifest.mainnetDeploymentHash = deploymentHash;
  manifest.mainnetApprovedDeploymentHash = deploymentHash;
  writeFileSync(
    mockRpcModule,
    `globalThis.fetch = async (_url, init) => {
  const request = JSON.parse(String(init.body));
  let result;
  if (request.method === "eth_chainId") {
    result = process.env.FRV_TEST_RPC_CHAIN_ID ?? "0x1";
  } else if (request.method === "eth_blockNumber") {
    result = "0x${BigInt(manifest.deployedAtBlock as number).toString(16)}";
  } else if (request.method === "eth_getCode") {
    const empty = process.env.FRV_TEST_RPC_EMPTY_CODE_ADDRESS?.toLowerCase();
    result = String(request.params[0]).toLowerCase() === empty ? "0x" : "0x6000";
  } else {
    throw new Error("Unexpected mock RPC method " + request.method);
  }
  return {
    ok: true,
    status: 200,
    json: async () => ({
      jsonrpc: "2.0",
      id: process.env.FRV_TEST_RPC_BAD_ID ? request.id + 1 : request.id,
      result,
    }),
  };
};
`,
  );

  const runExporter = (candidate: Record<string, unknown>) => {
    const serialized = `${JSON.stringify(candidate, null, 2)}\n`;
    writeFileSync(tempManifest, serialized);
    return spawnSync(
      process.execPath,
      ["../tools/frontend-env-from-manifest.mjs", tempManifest],
      {
        cwd: new URL(".", import.meta.url),
        encoding: "utf8",
        env: {
          ...process.env,
          MAINNET_APPROVED_DEPLOYMENT_HASH: deploymentHash,
          MAINNET_APPROVED_MANIFEST_SHA256: createHash("sha256")
            .update(serialized)
            .digest("hex"),
        },
      },
    );
  };

  try {
    const validExport = runExporter({...manifest});
    check(
      "manifest export: a receipt-bound production fixture is accepted",
      validExport.status === 0 &&
        validExport.stdout.includes(`NEXT_PUBLIC_MAINNET_DEPLOYMENT_HASH=${deploymentHash}`) &&
        validExport.stdout.includes("NEXT_PUBLIC_SUSDFR_FEE_ABI_VERSION=1") &&
        validExport.stdout.includes("NEXT_PUBLIC_MAINNET_MANIFEST_SHA256="),
      validExport.stderr,
    );

    const exportedEnv = Object.fromEntries(
      validExport.stdout
        .trim()
        .split("\n")
        .map((line) => {
          const separator = line.indexOf("=");
          return [line.slice(0, separator), line.slice(separator + 1)];
        }),
    );
    const validSerialized = `${JSON.stringify(manifest, null, 2)}\n`;
    const runBuildGuard = (overrides: Record<string, string> = {}) =>
      spawnSync(
        process.execPath,
        [
          "--import",
          mockRpcModule,
          "../tools/frontend-env-from-manifest.mjs",
          "--verify-build-env",
          tempManifest,
        ],
        {
          cwd: new URL(".", import.meta.url),
          encoding: "utf8",
          env: {
            ...process.env,
            ...exportedEnv,
            NEXT_PUBLIC_RPC_URL: "https://rpc.ankr.com/eth",
            MAINNET_APPROVED_DEPLOYMENT_HASH: deploymentHash,
            MAINNET_APPROVED_MANIFEST_SHA256: createHash("sha256")
              .update(validSerialized)
              .digest("hex"),
            ...overrides,
          },
        },
      );
    const validBuildGuard = runBuildGuard();
    check(
      "mainnet build: every manifest-derived environment value is bound to the approved manifest",
      validBuildGuard.status === 0 &&
        validBuildGuard.stdout.includes("matches its independent approvals"),
      validBuildGuard.stderr,
    );
    const substitutedBuildAddress = runBuildGuard({
      NEXT_PUBLIC_USDFR_ADDRESS: addr(999),
    });
    check(
      "mainnet build: a field-by-field address substitution is rejected",
      substitutedBuildAddress.status !== 0 &&
        substitutedBuildAddress.stderr.includes(
          "NEXT_PUBLIC_USDFR_ADDRESS does not match",
        ),
      substitutedBuildAddress.stderr,
    );
    const wrongRpcChain = runBuildGuard({
      FRV_TEST_RPC_CHAIN_ID: "0xaa36a7",
    });
    check(
      "mainnet build: an RPC serving Sepolia is rejected",
      wrongRpcChain.status !== 0 &&
        wrongRpcChain.stderr.includes("does not report Ethereum mainnet chain ID 1"),
      wrongRpcChain.stderr,
    );
    const emptyRpcCode = runBuildGuard({
      FRV_TEST_RPC_EMPTY_CODE_ADDRESS: String(manifest.usdfr),
    });
    check(
      "mainnet build: an RPC without manifest contract code is rejected",
      emptyRpcCode.status !== 0 &&
        emptyRpcCode.stderr.includes("no deployed code at manifest .usdfr"),
      emptyRpcCode.stderr,
    );
    const emptyExecutorCode = runBuildGuard({
      FRV_TEST_RPC_EMPTY_CODE_ADDRESS: String(manifest.mtmExecutor),
    });
    check(
      "mainnet build: an RPC without the MTM executor is rejected",
      emptyExecutorCode.status !== 0 &&
        emptyExecutorCode.stderr.includes("no deployed code at manifest .mtmExecutor"),
      emptyExecutorCode.stderr,
    );
    const mismatchedRpcResponse = runBuildGuard({
      FRV_TEST_RPC_BAD_ID: "1",
    });
    check(
      "mainnet build: a mismatched JSON-RPC response ID is rejected",
      mismatchedRpcResponse.status !== 0 &&
        mismatchedRpcResponse.stderr.includes("invalid JSON-RPC response"),
      mismatchedRpcResponse.stderr,
    );
    const insecureRpc = runBuildGuard({
      NEXT_PUBLIC_RPC_URL: "http://rpc.example.net/eth",
    });
    check(
      "mainnet build: an insecure HTTP RPC is rejected",
      insecureRpc.status !== 0 &&
        insecureRpc.stderr.includes("must use HTTPS"),
      insecureRpc.stderr,
    );
    const invalidBuildChain = runBuildGuard({
      NEXT_PUBLIC_CHAIN_ID: "not-a-chain",
    });
    check(
      "mainnet build: an invalid chain profile cannot bypass the manifest gate",
      invalidBuildChain.status !== 0 &&
        invalidBuildChain.stderr.includes("NEXT_PUBLIC_CHAIN_ID must be"),
      invalidBuildChain.stderr,
    );
    const unsetBuildChain = runBuildGuard({
      NEXT_PUBLIC_CHAIN_ID: "",
    });
    check(
      "mainnet build: an unset chain profile fails closed",
      unsetBuildChain.status !== 0 &&
        unsetBuildChain.stderr.includes("NEXT_PUBLIC_CHAIN_ID is required"),
      unsetBuildChain.stderr,
    );
    const loopbackRpc = runBuildGuard({
      NEXT_PUBLIC_RPC_URL: "https://[::1]/eth",
    });
    check(
      "mainnet build: an HTTPS loopback RPC is rejected",
      loopbackRpc.status !== 0 &&
        loopbackRpc.stderr.includes("real remote mainnet endpoint"),
      loopbackRpc.stderr,
    );

    const zeroAddress = {...manifest, usdfr: addr(0)};
    const rejectedZero = runExporter(zeroAddress);
    check(
      "manifest export: a zero module address is rejected",
      rejectedZero.status !== 0 &&
        rejectedZero.stderr.includes(".usdfr does not match the approved CREATE sequence"),
      rejectedZero.stderr,
    );

    const duplicateAddress = {...manifest, vault: manifest.usdfr};
    const rejectedDuplicate = runExporter(duplicateAddress);
    check(
      "manifest export: duplicate module addresses are rejected",
      rejectedDuplicate.status !== 0 &&
        rejectedDuplicate.stderr.includes(".vault does not match the approved CREATE sequence"),
      rejectedDuplicate.stderr,
    );

    const substitutedExecutor = {...manifest, mtmExecutor: manifest.defaultManager};
    const rejectedExecutor = runExporter(substitutedExecutor);
    check(
      "manifest export: a substituted MTM executor is rejected",
      rejectedExecutor.status !== 0 &&
        rejectedExecutor.stderr.includes(".mtmExecutor does not match the approved CREATE sequence"),
      rejectedExecutor.stderr,
    );

    const substitutedPrincipal = {...manifest, opsAdmin: addr(108)};
    const rejectedPrincipal = runExporter(substitutedPrincipal);
    check(
      "manifest export: a substituted principal is rejected",
      rejectedPrincipal.status !== 0 &&
        rejectedPrincipal.stderr.includes("principal-set receipt does not match"),
      rejectedPrincipal.stderr,
    );

    const substitutedGasPolicy = {...manifest, mainnetMaxFeePerGasWei: "9000000000"};
    const rejectedGasPolicy = runExporter(substitutedGasPolicy);
    check(
      "manifest export: a substituted gas policy is rejected",
      rejectedGasPolicy.status !== 0 &&
        rejectedGasPolicy.stderr.includes("gas-policy receipt does not match"),
      rejectedGasPolicy.stderr,
    );
  } finally {
    rmSync(tempDir, {recursive: true, force: true});
  }
}


// ── function-SHAPE drift guard (added 2026-07-21) ────────────────────
// The error guard above only ever compared error NAMES, so it could not see a function
// whose RETURN SHAPE had changed. `RedemptionQueue.request()` gained a fifth field
// (`requestedAt`, the ADR-0022 cooldown anchor) and the frontend ABI kept declaring four —
// viem decodes positionally, so this does not throw, it silently drops the field and the
// UI cannot show a cooldown countdown. Same failure class as the error drift: a hand-kept
// ABI diverging from source with nothing comparing them. This compares the declared output
// arity of the view functions we depend on against the Solidity interface signatures.
if (!existsSync(new URL("../contracts/src/interfaces/", import.meta.url))) {
  skip("interface arity: frontend view ABIs match the Solidity interface signatures");
} else {
  const IFACE = new URL("../contracts/src/interfaces/", import.meta.url);
  const ifaceSrc = readdirSync(IFACE)
    .filter((f) => f.endsWith(".sol"))
    .map((f) => readFileSync(new URL(f, IFACE), "utf8"))
    .join("\n");

  // (abi, function name, interface source) -> compare declared outputs to the `returns (...)`
  const shapeChecks: Array<{abi: readonly unknown[]; fn: string; label: string}> = [
    {abi: QUEUE_ABI, fn: "request", label: "QUEUE_ABI.request"},
    {abi: QUEUE_ABI, fn: "redeemCooldown", label: "QUEUE_ABI.redeemCooldown"},
    {abi: QUEUE_ABI, fn: "eligibleToSettleAt", label: "QUEUE_ABI.eligibleToSettleAt"},
  ];

  for (const {abi, fn, label} of shapeChecks) {
    const entry = (abi as Array<{type: string; name?: string; outputs?: unknown[]}>).find(
      (e) => e.type === "function" && e.name === fn,
    );
    check(`shape: ${label} exists in the frontend ABI`, Boolean(entry));
    if (!entry) continue;

    // Pull `function <fn>(...) external view returns ( ... );` out of the interface source
    // and count the comma-separated components at depth 0.
    const re = new RegExp(`function\\s+${fn}\\s*\\([^)]*\\)[^;{]*returns\\s*\\(([^)]*)\\)`, "s");
    const m = ifaceSrc.match(re);
    check(`shape: ${label} found in the Solidity interfaces`, Boolean(m));
    if (!m) continue;
    const solCount = m[1].split(",").map((x) => x.trim()).filter(Boolean).length;
    const abiCount = (entry.outputs ?? []).length;
    check(
      `shape: ${label} declares ${solCount} outputs to match Solidity (has ${abiCount})`,
      abiCount === solCount,
    );
  }

  const queueEventNames = new Set(
    (QUEUE_ABI as readonly {type: string; name?: string}[])
      .filter((entry) => entry.type === "event")
      .map((entry) => entry.name),
  );
  check(
    "shape: queue ABI exposes events needed for live position refresh",
    ["RedemptionRequested", "RequestFilled", "Claimed", "EpochClosed", "RedeemCooldownSet"].every((name) =>
      queueEventNames.has(name)
    ),
  );

  const pointsFns = new Set(
    (POINTS_ABI as readonly {type: string; name?: string}[])
      .filter((entry) => entry.type === "function")
      .map((entry) => entry.name),
  );
  check(
    "shape: points ABI exposes live wallet dashboard reads",
    [
      "pointsOfWallet",
      "pointsBreakdown",
      "trackedBalances",
      "curatorTracked",
      "curatorPointsInClass",
      "curatorFreezeStatus",
      "ratePerUnitDay",
      "usdfrMultiplierBps",
      "curatorMultiplierBps",
      "rateEpochCount",
    ].every((name) => pointsFns.has(name)),
  );

  // ADR-0022 Option Y: a redemption preview MUST use the conservative NAV. If the vault ABI
  // ever loses `previewRedeem`, the only remaining quote is the deposit price, which
  // overstates an exit during an impairment window.
  const vaultFns = new Set(
    (VAULT_ABI as Array<{type: string; name?: string}>)
      .filter((e) => e.type === "function")
      .map((e) => e.name),
  );
  check("shape: VAULT_ABI exposes previewRedeem (ADR-0022 conservative exit quote)", vaultFns.has("previewRedeem"));
  check("shape: VAULT_ABI exposes impairmentSource", vaultFns.has("impairmentSource"));

  const impairmentFns = new Set(
    (IMPAIRMENT_SOURCE_ABI as Array<{type: string; name?: string}>)
      .filter((e) => e.type === "function")
      .map((e) => e.name),
  );
  check(
    "shape: impairment ABI exposes pendingSeniorImpairment",
    impairmentFns.has("pendingSeniorImpairment"),
  );

  const curatorFns = new Set(
    (CURATOR_ABI as Array<{type: string; name?: string}>)
      .filter((e) => e.type === "function")
      .map((e) => e.name),
  );
  check(
    "shape: curator ABI exposes per-class poolBalance",
    curatorFns.has("poolBalance"),
  );

  const transparencyDashboard = readFileSync(
    new URL("./src/components/app/TransparencyDashboard.tsx", import.meta.url),
    "utf8",
  );
  check(
    "transparency: top card sums curator first-loss capital",
    transparencyDashboard.includes("Curator first-loss capital") &&
      transparencyDashboard.includes("curatorPools.reduce"),
  );
  check(
    "transparency: curator capital is measured against outstanding loans",
    transparencyDashboard.includes("(curatorCapital * 10_000n) / deployed") &&
      transparencyDashboard.includes("of outstanding loans"),
  );
  check(
    "transparency: top card shows total and per-event sGROVE backstop",
    transparencyDashboard.includes("sGROVE total backstop") &&
      transparencyDashboard.includes("coverageReserve") &&
      transparencyDashboard.includes("per event"),
  );

  const redeemCard = readFileSync(
    new URL("./src/components/app/RedeemCard.tsx", import.meta.url),
    "utf8",
  );
  check(
    "redeem: external queue events refresh claim state without a page reload",
    redeemCard.includes("useWatchContractEvent") &&
      redeemCard.includes("refetchScanned") &&
      redeemCard.includes("refetchInterval: 60_000"),
  );
  check(
    "redeem: older positions remain discoverable and claimable by request ID",
    redeemCard.includes("Find any request by ID") &&
      redeemCard.includes("lookedUpRequest") &&
      redeemCard.includes('functionName: "claim"'),
  );
  check(
    "redeem: live minimum hold is distinguished from the settlement heartbeat",
    redeemCard.includes('functionName: "redeemCooldown"') &&
      redeemCard.includes("Minimum hold before eligibility") &&
      redeemCard.includes("Settlement heartbeat ends in"),
  );
  check(
    "redeem: queue entry requires explicit non-cancellable lock-up acknowledgement",
    redeemCard.includes("queueAcknowledged") &&
      redeemCard.includes("acknowledgedCooldown === redeemCooldown") &&
      redeemCard.includes("cannot be cancelled or withdrawn") &&
      redeemCard.includes("redeemCooldown !== undefined && queueAcknowledged"),
  );
  // The arithmetic itself is pinned by VALUE above (see "queue eligibility"); this only
  // asserts the component routes through that shared helper rather than re-deriving the
  // hold inline, where it could drift from the contract unnoticed.
  check(
    "redeem: each queued position renders live eligibility from its request timestamp",
    redeemCard.includes("secondsUntilEligible(r.requestedAt, redeemCooldown, now)") &&
      redeemCard.includes('from "@/lib/queue"') &&
      redeemCard.includes("First eligible in") &&
      redeemCard.includes("settlement may be later"),
  );
  // RC-05: switching redeem mode resets both flows, so it must be unavailable while a
  // write is in flight — otherwise the in-flight transaction is orphaned.
  check(
    "redeem: the mode toggle is disabled while either write flow is busy",
    redeemCard.includes("disabled={flow.busy || claimFlow.busy}"),
  );
  check(
    "write flow: reset refuses to orphan an in-flight transaction",
    readFileSync(
      new URL("./src/components/app/useWriteFlow.ts", import.meta.url),
      "utf8",
    ).includes('if (phase === "simulating" || phase === "signing" || phase === "pending") return;'),
  );

  const pointsPage = readFileSync(
    new URL("./src/app/points/page.tsx", import.meta.url),
    "utf8",
  );
  const pointsDashboard = readFileSync(
    new URL("./src/components/app/PointsDashboard.tsx", import.meta.url),
    "utf8",
  );
  const protocolReads = readFileSync(
    new URL("./src/lib/protocol.ts", import.meta.url),
    "utf8",
  );
  check(
    "points: page uses the live connected-wallet dashboard",
    pointsPage.includes("<PointsDashboard />") &&
      !pointsPage.includes("per-wallet reads not yet wired"),
  );
  check(
    "points: dashboard reads total, breakdown, tracked balances and curator classes",
    pointsDashboard.includes("pointsOfWallet") &&
      pointsDashboard.includes("pointsBreakdown") &&
      pointsDashboard.includes("trackedBalances") &&
      pointsDashboard.includes("curatorFreezeStatus"),
  );
  check(
    "points: typed read layer no longer throws a deployment placeholder",
    protocolReads.includes("function getUserPoints") &&
      protocolReads.includes('functionName: "pointsOfWallet"') &&
      !protocolReads.includes("wire to PointsModule reads"),
  );

  // A streamed exchange rate can advance between previewDeposit and previewRedeem RPC reads.
  // The stake warning must therefore use the canonical impairment source, not compare the two
  // independently timed quotes.
  const stakeCard = readFileSync(
    new URL("./src/components/app/StakeCard.tsx", import.meta.url),
    "utf8",
  );
  check(
    "StakeCard gates its warning on pendingSeniorImpairment",
    stakeCard.includes("(pendingSeniorImpairment ?? 0n) > 0n"),
  );
  check(
    "StakeCard does not infer impairment from previewExitAssets < parsed",
    !/const exitImpaired\s*=[\s\S]{0,160}previewExitAssets\s*<\s*parsed/.test(stakeCard),
  );
  check(
    // AUDIT R14-03 then R15-01. The exposure is
    // `performanceFeeBps * min(grossMark, max(0, totalAssets + 1 - hurdleAssets))`, so BOTH
    // terms are load-bearing: the gap-only predicate went silent at maximal deferral, and the
    // gross-mark-only predicate fired at zero exposure. The gate must reconstruct the
    // asset-denominated hurdle and take the smaller of the two terms.
    "StakeCard gates deferred-fee exposure on both the gross mark and the asset hurdle",
    stakeCard.includes("deferredPerformanceFeeExposure") &&
      stakeCard.includes("chargeableDeferral") &&
      stakeCard.includes("hurdleAssets") &&
      stakeCard.includes('functionName: "performanceFeeImpairment"') &&
      stakeCard.includes('functionName: "totalAssets"'),
  );
  check(
    // AUDIT R15-01. The banner body asserted an ordering the gate does not establish, and
    // printed it in the steady state where the two rates are equal. The comparison clause
    // must be behind its own condition, with the one-wei Ceil/Floor dust excluded.
    "StakeCard renders the rate-comparison clause only when the ordering actually holds",
    stakeCard.includes("performanceNavBelowHurdle") &&
      stakeCard.includes("highWaterMark > feeExchangeRate + 1n"),
  );
  check(
    "StakeCard discloses that deferred fee exposure can exist without exit impairment",
    stakeCard.includes("Global performance-fee exposure is deferred.") &&
      stakeCard.includes("even when queued-exit") &&
      stakeCard.includes("impairment is currently zero"),
  );

  const yieldPanel = readFileSync(
    new URL("./src/components/app/YieldPositionPanel.tsx", import.meta.url),
    "utf8",
  );
  check(
    "position panel headlines projected position income",
    yieldPanel.includes("Projected position income"),
  );
  check(
    "position panel no longer headlines live realized yield",
    !yieldPanel.includes("Live realized sUSDfr yield"),
  );
  check(
    "position panel labels the forward rate current expected yield",
    yieldPanel.includes('label="Current expected yield"'),
  );
  check(
    "position panel derives historical income from zero-vesting-compatible Waterfall distributions",
    yieldPanel.includes('eventName: "Distributed"') &&
      yieldPanel.includes("log.args.toVault") &&
      !/eventName:\s*"YieldStreamStarted"[\s\S]{0,500}recordedIncome/.test(yieldPanel),
  );
}

// ── protocol error-ABI drift guard ───────────────────────────────────
// The frontend's error ABI is hand-maintained and has now drifted THREE separate times:
// SUSDfr_TransferBlocked had user-facing copy but no ABI entry (so a sanctions-blocked
// transfer surfaced as raw hex despite correct copy existing); SUSDfr_NotKYCAllowed lingered
// after the 2026-07-14 compliance re-architecture deleted it; and ADR-0022/0023/0025 added
// Queue_AllInCooldown, SUSDfr_VestingPeriodTooLong and
// ReserveManager_InsufficientIdleValue with none of them reaching the ABI. The
// clean-v1 USDC-only controller later removed Controller_StableNotApproved entirely.
//
// Queue_AllInCooldown is the one that matters most: under ADR-0022 a redeemer hitting the
// cooldown gate is a NORMAL, expected condition and will be the single most common revert
// users see. Undecoded it renders as raw hex.
//
// These checks turn a recurring silent-drift class into a build failure. They read the
// contract sources directly rather than forge artifacts, so they work without a build.
if (!existsSync(new URL("../contracts/src/", import.meta.url))) {
  skip("error drift: user-facing custom errors exist in the contract source");
} else {
  const SRC = new URL("../contracts/src/", import.meta.url);
  const files: string[] = [];
  const walk = (dir: URL) => {
    for (const e of readdirSync(dir, {withFileTypes: true})) {
      const u = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
      if (e.isDirectory()) walk(u);
      else if (e.name.endsWith(".sol")) files.push(readFileSync(u, "utf8"));
    }
  };
  walk(SRC);
  const solidity = files.join("\n");
  const declared = new Set<string>();
  for (const m of solidity.matchAll(/\berror\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) declared.add(m[1]);

  const abiErrors = new Set(
    PROTOCOL_ERRORS.filter((e) => e.type === "error").map((e) => (e as {name: string}).name),
  );

  // (1) every message key must be decodable, or the copy is dead weight
  for (const name of Object.keys(ERROR_MESSAGES)) {
    check(`drift: "${name}" has copy AND an ABI entry`, abiErrors.has(name));
  }

  // (2) no ABI entry may name a PROTOCOL error the contracts no longer declare.
  //     Discriminator: this protocol namespaces every custom error with a module prefix and an
  //     underscore (Queue_, SUSDfr_, ReserveManager_ ...), while inherited OpenZeppelin errors
  //     never contain one (ERC20InsufficientAllowance, AccessControlUnauthorizedAccount,
  //     EnforcedPause). So "has an underscore" cleanly separates ours from theirs, without a
  //     hardcoded allowlist that would silently rot as OZ adds errors.
  for (const name of abiErrors) {
    if (!name.includes("_")) continue; // inherited third-party error, not ours to track
    check(`drift: "${name}" still exists in contracts/src`, declared.has(name));
  }

  // (3) errors a user WILL hit on a normal write path must decode to real copy
  const MUST_DECODE = [
    "Controller_NotKYCAllowed",
    "Controller_AmountTooSmall",
    "SUSDfr_TransferBlocked",
    "USDfr_TransferNotAllowed",
    "Queue_AllInCooldown",
    "Queue_BelowMinRedemption",
    "Queue_HeadNotRedeemable",
    "Queue_NothingClaimable",
    "Queue_NotRequestOwner",
    "ReserveManager_InsufficientIdleValue",
  ];
  for (const name of MUST_DECODE) {
    check(`drift: user-facing "${name}" is in the ABI`, abiErrors.has(name));
    check(`drift: user-facing "${name}" has copy`, typeof ERROR_MESSAGES[name] === "string");
  }
}

// Report skips alongside the verdict. "ALL PASS" on a run that silently skipped
// repo-wide assurance assertions would be exactly the kind of green this suite exists
// to prevent.
const verdict = failures === 0 ? "ALL PASS" : `${failures} FAILURES`;
console.log(skipped === 0 ? `\n${verdict}` : `\n${verdict} (${skipped} skipped — partial checkout)`);
process.exit(failures === 0 ? 0 : 1);
