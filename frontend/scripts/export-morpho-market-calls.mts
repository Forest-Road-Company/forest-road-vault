import {writeFileSync} from "node:fs";
import {createRequire} from "node:module";
import {encodeFunctionData} from "viem";
import type * as MarketModule from "../src/lib/morphoMarket";
// Node's built-in type stripping needs the runtime .ts extension; keep the import fully typed.
const {MORPHO_MARKET, marketAction, treasurySupplyCalls, treasurySupplyDigest}: typeof MarketModule =
  createRequire(import.meta.url)("../src/lib/morphoMarket.ts");

// Synthetic fork fixtures only; this script cannot connect to a wallet or submit a proposal.
const args = process.argv.slice(2);
if (args.length > 1) throw new Error("Pass one new output filename, or omit it to print the fixture.");
const borrower = "0x0000000000000000000000000000000000000B0b";
const samples: [string, MarketModule.MarketAction, bigint, bigint][] = [
  ["supply", "supply", 1_000_000_000n, 0n],
  ["withdraw", "withdraw", 1_000_000_000n, 0n],
  ["collateral", "supplyCollateral", 100n * 10n ** 24n, 0n],
  ["borrow", "borrow", 20_000_000n, 0n],
  ["repay", "repay", 10_000_000n, 0n],
  ["withdrawCollateral", "withdrawCollateral", 50n * 10n ** 24n, 0n],
  ["repayAll", "repay", 0n, 20_000_000_000_000n],
  ["withdrawAll", "withdraw", 0n, 1_000_000_000_000_000n],
];
const actions = Object.fromEntries(samples.map(([name, action, assets, shares]) =>
  [name, encodeFunctionData(marketAction(action, assets, borrower, shares) as Parameters<typeof encodeFunctionData>[0]) as string]));
const fixture = {at: new Date().toISOString(), chainId: 1, marketId: MORPHO_MARKET.id, treasury: MORPHO_MARKET.treasury,
  borrower, calls: treasurySupplyCalls(), callDigest: treasurySupplyDigest(), actions, conditionalOnly: true, executionReady: false};
const json = JSON.stringify(fixture, null, 2) + "\n";
if (args[0]) {
  writeFileSync(args[0], json, {flag: "wx", mode: 0o600});
  console.log(JSON.stringify({exported: true, actions: Object.keys(actions), digest: fixture.callDigest, conditionalOnly: true, executionReady: false}));
} else process.stdout.write(json);
