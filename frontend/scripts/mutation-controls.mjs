#!/usr/bin/env node

import {spawnSync} from "node:child_process";
import {readFileSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const cases = [
  {
    name: "a vanished class cannot retarget an Ethereum write",
    file: "src/components/curators/EthereumCuratorPanel.tsx",
    testFile: "src/components/curators/EthereumCuratorPanel.test.tsx",
    test: "binds the initial default so its disappearance cannot retarget a write",
    needle: "  const effectiveSelected = selected ?? defaultClass;",
    replacement: "  const effectiveSelected = defaultClass;",
  },
  {
    name: "a failed record write releases its source admission gate",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "releases only its own source gate when the durable record write fails",
    needle: "        await releaseGates(admissionGates);",
    replacement: "        void admissionGates;",
  },
  {
    name: "a conflicting source gate is a bounded refusal",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "returns 429 after one constant-cost write when the current source sub-window is occupied",
    needle: "    if (!conflict(error)) throw error;",
    replacement: "    if (conflict(error)) throw error;",
  },
  {
    name: "a corrected submission gets the next source sub-window",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "stores a corrected resubmission in a later sub-window instead of treating the email as a duplicate",
    needle: "  const sourceSlot = Math.floor(now / SOURCE_SLOT_MS);",
    replacement: "  const sourceSlot = Math.floor(now / SOURCE_WINDOW_MS);",
  },
  {
    name: "independent sources do not share one admission gate",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "has no shared email gate that can delete a concurrent request's admission",
    needle: "  const sourceDigest = digest(secret, `source:${sourceAddress(request)}`);",
    replacement: "  const sourceDigest = digest(secret, \"source:shared\");",
  },
  {
    name: "a filled automation trap cannot report success",
    file: "src/app/api/curators/interest/route.ts",
    testFile: "src/app/api/curators/interest/route.test.ts",
    test: "visibly refuses a filled non-semantic trap without writing",
    needle: "  if (text(raw.faxExtension, 200)) return json({ok: false, error: \"Malformed request.\"}, 400);",
    replacement: "  if (text(raw.faxExtension, 200)) return json({ok: true}, 200);",
  },
  {
    name: "the gate cleanup remains authenticated",
    file: "src/app/api/internal/curator-rate-cleanup/route.ts",
    testFile: "src/app/api/internal/curator-rate-cleanup/route.test.ts",
    test: "requires the Vercel cron bearer secret",
    needle: "  if (!authorized(request, secret)) {",
    replacement: "  if (false && !authorized(request, secret)) {",
  },
  {
    name: "the served revision body remains bound to the Vercel commit",
    file: "src/app/api/revision/route.ts",
    testFile: "src/app/api/revision/route.test.ts",
    test: "returns the exact Vercel source commit in the body and header",
    needle: "      commit,",
    replacement: "      commit: commit.slice(1),",
  },
  {
    name: "an allowlisted empty position cannot be closed by accident",
    file: "src/components/curators/CuratorVaultPanel.tsx",
    testFile: "src/components/curators/CuratorVaultPanel.connected.test.tsx",
    test: "does not offer to close a freshly allowlisted empty position",
    needle: "  const canClose =\n    revoked\n    && p.principal === 0n",
    replacement: "  const canClose =\n    p.principal === 0n",
  },
  {
    name: "a late confirmation cannot restore the previous wallet's book",
    file: "src/components/curators/CuratorVaultPanel.tsx",
    testFile: "src/components/curators/CuratorVaultPanel.connected.test.tsx",
    test: "ignores wallet A's late confirmation refresh after switching to wallet B",
    needle: "        if (!actionWalletIsCurrent()) return;",
    replacement: "        if (false && !actionWalletIsCurrent()) return;",
  },
  {
    name: "owners held at zero are never checked (MORPHO-55)",
    file: "src/lib/morphoPoints.server.ts",
    testFile: "src/lib/morphoPoints.server.test.ts",
    test: "fails closed when the omitted round trip spans one of the owner's check blocks",
    needle: "!== 0n || i % every === phase,",
    replacement: "!== 0n || (i < 0 && i % every === phase),",
  },
  {
    name: "every owner is checked at every chunk again (MORPHO-55's cost)",
    file: "src/lib/morphoPoints.server.ts",
    testFile: "src/lib/morphoPoints.server.test.ts",
    test: "between its check blocks under-counts and never over-counts",
    needle: "!== 0n || i % every === phase,",
    replacement: "!== 0n || i % every === phase || true,",
  },
  {
    name: "a resumed history starts its chunks where the last request stopped (M1001-m4-06)",
    file: "src/lib/morphoPoints.server.ts",
    testFile: "src/lib/morphoPoints.server.test.ts",
    test: "checks them at the same blocks when the history was extended from a head mid-chunk",
    needle: "    const to = end < toBlock ? end : toBlock;",
    replacement: "    const to = from + BLOCK_CHUNK - 1n < toBlock ? from + BLOCK_CHUNK - 1n : toBlock;",
  },
  {
    name: "every owner held at zero is checked in one chunk of 16 again (M1001-m4-07)",
    file: "src/lib/morphoPoints.server.ts",
    testFile: "src/lib/morphoPoints.server.test.ts",
    test: "checks a sixteenth of the owners held at zero at each chunk's end",
    needle: "!== 0n || i % every === phase,",
    replacement: "!== 0n || (phase === 0 && i >= 0),",
  },
  {
    name: "a queued request runs a second chunk past its deadline (M1001-m4-07)",
    file: "src/lib/morphoPoints.server.ts",
    testFile: "src/lib/morphoPoints.server.test.ts",
    test: "bounds a request queued behind another build",
    needle:
      "    if (chunks >= MAX_CHUNKS_PER_REQUEST || (chunks > 0 && deps.now() > deadline)) {\n" +
      "      throw new MorphoPointsNotReadyError(\"points: catching up on market history\");",
    replacement:
      "    if (chunks >= MAX_CHUNKS_PER_REQUEST || (chunks > 1 && deps.now() > deadline)) {\n" +
      "      throw new MorphoPointsNotReadyError(\"points: catching up on market history\");",
  },
  {
    name: "the budget starts when the build starts (MORPHO-71)",
    file: "src/lib/morphoPoints.server.ts",
    testFile: "src/lib/morphoPoints.server.test.ts",
    test: "measures its budget from the request's arrival",
    needle: "  const deadline = (arrivedAt ?? deps.now()) + REQUEST_BUDGET_MS;",
    replacement: "  const deadline = (arrivedAt === undefined ? deps.now() : deps.now()) + REQUEST_BUDGET_MS;",
  },
  {
    name: "the route does not pass the request's arrival (MORPHO-71)",
    file: "src/app/api/points/morpho/route.ts",
    testFile: "src/app/api/points/morpho/route.test.ts",
    test: "measures the loader's budget from the request's arrival",
    needle: "    const result = await loadMorphoCollateralPoints(canonical, undefined, arrivedAt);",
    replacement: "    const result = await loadMorphoCollateralPoints(canonical, undefined, arrivedAt + 1_000_000);",
  },
  // ── Buy tab (Uniswap v4 route) ──
  {
    name: "the buy swaps the wrong way (zeroForOne false sells USDfr)",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/lib/uniswapV4Swap.test.ts",
    test: "decodes back to exactly SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL with the intended values",
    needle: "const BUY_ZERO_FOR_ONE = true;",
    replacement: "const BUY_ZERO_FOR_ONE = false;",
  },
  {
    name: "the buy ignores its minimum received",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/lib/uniswapV4Swap.test.ts",
    test: "decodes back to exactly SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL with the intended values",
    needle: "  const minimum = amountOutMinimum;",
    replacement: "  const minimum = 0n;",
  },
  {
    name: "the buy drops its deadline",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/lib/uniswapV4Swap.test.ts",
    test: "is one V4_SWAP command when the router already holds a Permit2 allowance",
    needle: "  return [commands, inputs, args.deadline] as const;",
    replacement: "  return [commands, inputs, (1n << 256n) - 1n] as const;",
  },
  {
    name: "Buy is not the default tab",
    file: "src/components/app/GetUsdfrCard.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "opens on Buy on mainnet, with Mint 1:1 beside it",
    needle: '  const [tab, setTab] = useState<GetUsdfrTab>("buy");',
    replacement: '  const [tab, setTab] = useState<GetUsdfrTab>("mint");',
  },
  {
    name: "a testnet shows the Buy tab",
    file: "src/components/app/GetUsdfrCard.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "shows a testnet the mint card alone: no tabs, no Buy, no pool",
    needle: "  if (IS_TESTNET) return <MintCard writesEnabled={writesEnabled} chainOk={chainOk} />;",
    replacement: "  if (false && IS_TESTNET) return <MintCard writesEnabled={writesEnabled} chainOk={chainOk} />;",
  },
  {
    name: "the 0.99 warning stays silent just below the floor",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/lib/uniswapV4Swap.test.ts",
    test: "warns strictly below 0.99 USDfr per USDC and not at it",
    needle: "  return amountOut * BPS < amountIn * PARITY_SCALE * WARNING_FLOOR_BPS;",
    replacement: "  return amountOut * BPS < amountIn * PARITY_SCALE * (WARNING_FLOOR_BPS - 1n);",
  },
  {
    name: "a jurisdiction-blocked buyer is asked to sign anyway",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "tells a jurisdiction-blocked address in words, before any signature or transaction",
    needle:
      '      if (!canReceive) {\n' +
      '        setPrep({phase: "error", message: BLOCKED_MESSAGE, errorName: "USDfr_TransferNotAllowed"});\n' +
      '        return;\n' +
      '      }\n' +
      '      const deadline = swapDeadline(block.timestamp);',
    replacement:
      '      if (false && !canReceive) {\n' +
      '        setPrep({phase: "error", message: BLOCKED_MESSAGE, errorName: "USDfr_TransferNotAllowed"});\n' +
      '        return;\n' +
      '      }\n' +
      '      const deadline = swapDeadline(block.timestamp);',
  },
  {
    name: "a Permit2 allowance that lapses before the deadline is reused",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/lib/uniswapV4Swap.test.ts",
    test: "reuses a router allowance only when it covers the amount until the deadline",
    needle: "  return allowance.amount < amountIn || BigInt(allowance.expiration) < deadline;",
    replacement: "  return allowance.amount < amountIn;",
  },
  // The one-time Permit2 approval (owner decision, 1 October 2026): the maximum, as Uniswap's app.
  {
    name: "the one-time Permit2 approval grants less than the maximum",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "first approves Permit2 once, for the maximum, when USDC's allowance is short",
    // Permit2's own uint160 ceiling: a plausible confusion, and less than USDC's maximum.
    needle: "export const PERMIT2_APPROVAL_AMOUNT = maxUint256;",
    replacement: "export const PERMIT2_APPROVAL_AMOUNT = (1n << 160n) - 1n;",
  },
  {
    name: "the Permit2 approval is skipped while USDC's allowance is short",
    file: "src/lib/uniswapV4Swap.ts",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "first approves Permit2 once, for the maximum, when USDC's allowance is short",
    needle: "  return allowance < amountIn;",
    replacement: "  return false;",
  },
  {
    name: "a blocked first-time buyer is offered the unlimited approval",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "does not ask a blocked first-time buyer for an unlimited Permit2 approval",
    needle:
      '      if (!canReceive) {\n' +
      '        setPrep({phase: "error", message: BLOCKED_MESSAGE, errorName: "USDfr_TransferNotAllowed"});\n' +
      '        return;\n' +
      '      }\n' +
      '      setPrep({phase: "idle"});\n' +
      '      void flow.run(permit2ApprovalRequest());',
    replacement:
      '      if (false && !canReceive) {\n' +
      '        setPrep({phase: "error", message: BLOCKED_MESSAGE, errorName: "USDfr_TransferNotAllowed"});\n' +
      '        return;\n' +
      '      }\n' +
      '      setPrep({phase: "idle"});\n' +
      '      void flow.run(permit2ApprovalRequest());',
  },
  {
    name: "a changing quote replaces the minimum during wallet confirmation",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "keeps the calldata minimum visible while the write flow asks for confirmation and waits for the receipt",
    needle: '  const quoteLocked = busy || prep.phase === "reviewReuse";',
    replacement: '  const quoteLocked = prep.phase === "reviewReuse";',
  },
  {
    name: "a Buy forgets its hash after a receipt timeout",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "signs a permit for exactly the amount, then hands the write flow the router call it reviewed",
    needle: "        keepPendingUntilReceipt: true,",
    replacement: "        keepPendingUntilReceipt: false,",
  },
  {
    name: "an older router allowance is used without its fresh-read review",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "warns before Buy that an old allowance may pay if a new permit is not applied",
    needle: "      if (standingAllowance && (",
    replacement: "      if (false && standingAllowance && (",
  },
  {
    name: "a changed router allowance skips the second acknowledgement",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "repeats the allowance review if the second live read changes before the wallet opens",
    needle:
      "        reviewed.amount !== permitAmount || reviewed.expiration !== permitExpiration ||\n" +
      "        reviewed.nonce !== permitNonce || reviewed.directReuse !== !signing",
    replacement: "        false || reviewed.directReuse !== !signing",
  },
  {
    name: "an unlimited Permit2 allowance is presented as an enormous finite number",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "names an unlimited allowance from the fresh Buy read even when the displayed poll was stale",
    needle: '  return amount === MAX_PERMIT2_ALLOWANCE ? "an unlimited amount of USDC"',
    replacement: '  return false ? "an unlimited amount of USDC"',
  },
  {
    name: "a late permit signature submits after the connected wallet switches",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "does not submit an old wallet's buy if the account switches during permit signing",
    needle: "        if (!stillCurrent()) return;\n        signedPermit = {permit, signature};",
    replacement: "        if (false && !stillCurrent()) return;\n        signedPermit = {permit, signature};",
  },
  {
    name: "a late permit signature submits after Buy unmounts",
    file: "src/components/app/BuyUsdfrPanel.tsx",
    testFile: "src/components/app/GetUsdfrCard.test.tsx",
    test: "does not submit a Buy if the card unmounts while its permit signature is pending",
    needle: "  useEffect(() => () => { prepGeneration.current += 1; }, []);",
    replacement: "  useEffect(() => () => { void prepGeneration.current; }, []);",
  },
  {
    name: "an uncertain Buy receipt poll never reaches its 30-minute stop",
    file: "src/components/app/useWriteFlow.ts",
    testFile: "src/components/app/useWriteFlow.test.tsx",
    test: "keeps the hash and Buy lock when receipt checks reach the 30-minute limit",
    needle: "            if (Date.now() - receiptStartedAt >= MAX_BUY_RECEIPT_WAIT_MS) {",
    replacement: "            if (false && Date.now() - receiptStartedAt >= MAX_BUY_RECEIPT_WAIT_MS) {",
  },
  {
    name: "an unmounted Buy flow keeps polling its old receipt",
    file: "src/components/app/useWriteFlow.ts",
    testFile: "src/components/app/useWriteFlow.test.tsx",
    test: "does not report a late receipt or start another poll after its card unmounts",
    needle: "    flowGeneration.current += 1;\n  }, []);",
    replacement: "    void flowGeneration.current;\n  }, []);",
  },
];

for (const control of cases) {
  const path = join(root, control.file);
  const original = readFileSync(path, "utf8");
  const matches = original.split(control.needle).length - 1;
  if (matches !== 1) {
    throw new Error(`${control.name}: expected one mutation target, found ${matches}`);
  }
  const mutated = original.replace(control.needle, control.replacement);
  if (mutated === original) throw new Error(`${control.name}: source did not change`);
  try {
    writeFileSync(path, mutated);
    const result = spawnSync(
      join(root, "node_modules/.bin/vitest"),
      ["run", control.testFile, "-t", control.test],
      {cwd: root, encoding: "utf8"},
    );
    if (result.status === 0) throw new Error(`${control.name}: mutation survived`);
    const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
    if (!output.includes("failed")) {
      process.stderr.write(output);
      throw new Error(`${control.name}: test failed for an unrelated reason`);
    }
    process.stdout.write(`Mutation killed: ${control.name}.\n`);
  } finally {
    writeFileSync(path, original);
    if (readFileSync(path, "utf8") !== original) {
      throw new Error(`${control.name}: failed to restore ${control.file}`);
    }
  }
}

process.stdout.write(`All ${cases.length} frontend mutation controls passed.\n`);
