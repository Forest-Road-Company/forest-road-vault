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
    needle: "  if (!deps) return {ok: true, enabled: false};\n  const deadline = (arrivedAt ?? deps.now()) + REQUEST_BUDGET_MS;",
    replacement: "  if (!deps) return {ok: true, enabled: false};\n  const deadline = deps.now() + REQUEST_BUDGET_MS;",
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
  // Morpho money-moving paths: independent calldata, rounding and behavioral assertions.
  {
    name: "Morpho Safe repay-all drops the atomic approval cushion",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "keeps the cushioned Safe repay-all approval at required",
    needle: "const approve = approvalAction && currentAllowance < (safe.context ? currentApproval : currentRequired);",
    replacement: "const approve = approvalAction && currentAllowance < currentRequired;",
  },
  {
    name: "Morpho repay quote ignores the forward stored-state projection",
    file: "src/lib/morphoMarketActions.ts", testFile: "src/lib/morphoMarketActions.test.ts",
    test: "uses the forward stored-state projection rather than today's trailing-average rate",
    needle: "marketPositionValues(s.projectedMarket, s.account.position, s.price).borrowed + 2n",
    replacement: "marketPositionValues(s.market, s.account.position, s.price).borrowed + 2n",
  },
  {
    name: "Morpho reader reuses the trailing average for the future horizon",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "projects from the original stored market with the exact future IRM average at the same block",
    needle: "lastUpdate: state.lastUpdate - projectionSeconds",
    replacement: "lastUpdate: state.lastUpdate",
  },
  {
    name: "Morpho collateral Max rounds retained collateral down",
    file: "src/lib/morphoMarketActions.ts", testFile: "src/lib/morphoMarketActions.test.ts",
    test: "rounds the retained collateral up at an uneven oracle price",
    needle: "const collateralNeeded = ceilDiv(valueNeeded * ORACLE_SCALE, s.price);",
    replacement: "const collateralNeeded = valueNeeded * ORACLE_SCALE / s.price;",
  },
  {
    name: "Morpho borrow Max omits new-debt forward-interest headroom",
    file: "src/lib/morphoMarketActions.ts", testFile: "src/lib/morphoMarketActions.test.ts",
    test: "finds the largest buffered borrow and respects liquidity",
    needle: " + maximumHorizonInterest(values.borrowed, s.projectionSeconds) + 2n",
    replacement: " + 2n",
  },
  {
    name: "Morpho collateral is accidentally parsed as 18 decimals",
    file: "src/lib/morphoMarket.ts", testFile: "src/lib/morphoMarket.test.ts",
    test: "uses the deployed 24-decimal sUSDfr precision and 6-decimal USDC precision",
    needle: "  collateralDecimals: 24,", replacement: "  collateralDecimals: 18,",
  },
  {
    name: "Morpho Treasury approval goes to the Treasury instead of Morpho",
    file: "src/lib/morphoMarket.ts", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "hands both reviewed zero-value calls to Safe only after atomic simulation",
    needle: "args: [MORPHO_MARKET.address, MORPHO_MARKET.seed]", replacement: "args: [MORPHO_MARKET.treasury, MORPHO_MARKET.seed]",
  },
  {
    name: "Morpho Treasury supplies the retired 250k amount",
    file: "src/lib/morphoMarket.ts", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "hands both reviewed zero-value calls to Safe only after atomic simulation",
    needle: "  seed: 50_000_000_000n,", replacement: "  seed: 250_000_000_000n,",
  },
  {
    name: "Morpho Treasury lending shares go to another wallet",
    file: "src/lib/morphoMarket.ts", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "hands both reviewed zero-value calls to Safe only after atomic simulation",
    needle: 'args: [MORPHO_MARKET.params, MORPHO_MARKET.seed, 0n, MORPHO_MARKET.treasury, "0x"]',
    replacement: 'args: [MORPHO_MARKET.params, MORPHO_MARKET.seed, 0n, MORPHO_MARKET.address, "0x"]',
  },
  {
    name: "Morpho debt rounds down instead of up",
    file: "src/lib/morphoMarket.ts", testFile: "src/lib/morphoMarket.test.ts",
    test: "rounds a non-integral debt up by one raw USDC unit",
    needle: "const borrowed = ceilDiv(p.borrowShares * (m.totalBorrowAssets + 1n), m.totalBorrowShares + 1_000_000n);",
    replacement: "const borrowed = p.borrowShares * (m.totalBorrowAssets + 1n) / (m.totalBorrowShares + 1_000_000n);",
  },
  {
    name: "Morpho repay-all reintroduces the moving buffered-approval loop",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "approves once then repays all when debt grows between reads and entries are off",
    needle: "const approve = approvalAction && currentAllowance < (safe.context ? currentApproval : currentRequired);",
    replacement: "const approve = approvalAction && currentAllowance < currentApproval;",
  },
  {
    name: "Morpho repay-all requires the entire allowance cushion as a cash balance",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "approves once then repays all when debt grows between reads and entries are off",
    needle: "a.usdc < repaymentQuote(s).required", replacement: "a.usdc < repaymentQuote(s).approval",
  },
  {
    name: "Morpho repay-all discards the live debt shares",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "repays all by debt shares instead of a stale asset amount",
    needle: "repayAll ? current.account.position.borrowShares :", replacement: "repayAll ? 1n :",
  },
  {
    name: "Morpho withdraw-all uses stale lending shares",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "withdraws all using the newly read lending shares, not a displayed asset estimate",
    needle: "withdrawAll ? current.account.position.supplyShares : 0n", replacement: "withdrawAll ? account!.position.supplyShares : 0n",
  },
  {
    name: "Morpho's typed borrow bypasses the 80-percent limit",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "blocks typed borrows above the buffer and shows the resulting LTV",
    needle: 'if (action === "borrow" && !withinMarketBuffer(', replacement: 'if (false && action === "borrow" && !withinMarketBuffer(',
  },
  {
    name: "Morpho's collateral withdrawal bypasses the 80-percent limit",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "refuses collateral withdrawal above 80% even when below the liquidation limit",
    needle: 'if (!withinMarketBuffer(after)) return', replacement: 'if (false && !withinMarketBuffer(after)) return',
  },
  {
    name: "Morpho risk buffer is silently raised to the liquidation threshold",
    file: "src/lib/morphoMarketActions.ts", testFile: "src/lib/morphoMarketActions.test.ts",
    test: "retains exactly the collateral needed for the 80% buffer",
    needle: "export const MARKET_BUFFER_LTV_BPS = 8_000n;", replacement: "export const MARKET_BUFFER_LTV_BPS = 8_600n;",
  },
  {
    name: "Morpho reader trusts a stale head",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "refuses 91-second-old head",
    needle: "now - block.timestamp > 90n", replacement: "now - block.timestamp > 900n",
  },
  {
    name: "Morpho reader ignores an oracle identity change",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "refuses changed oracle",
    needle: '["loanToken", "collateralToken", "oracle", "irm"] as const', replacement: '["loanToken", "collateralToken", "irm"] as const',
  },
  {
    name: "Morpho reader skips the oracle bytecode check",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "refuses unverifiable changed oracle code",
    needle: "keccak256(oracleCode) !== MORPHO_MARKET.oracleCodehash", replacement: "false",
  },
  {
    name: "Morpho reader ignores changed collateral decimals",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "refuses unverifiable sUSDfr decimals",
    needle: "collateralDecimals !== MORPHO_MARKET.collateralDecimals", replacement: "false",
  },
  {
    name: "Morpho reader skips its closing reorg check",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "refuses a reorg or lost hash at the closing read",
    needle: "if (canonical.hash !== block.hash ||", replacement: "if (false ||",
  },
  {
    name: "Morpho protection starts at the stale block instead of the read clock",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "issues a full five-minute quote after delayed reads from a",
    needle: "const projectedThrough = BigInt(Math.ceil(checkWindow() / 1_000))",
    replacement: "const projectedThrough = block.timestamp",
  },
  {
    name: "Morpho protection rounds its issuance anchor down",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "rounds a fractional issuance clock up rather than losing a second of protection",
    needle: "BigInt(Math.ceil(checkWindow() / 1_000))", replacement: "BigInt(Math.floor(checkWindow() / 1_000))",
  },
  {
    name: "Morpho borrow Max still protects only 300 block-relative seconds",
    file: "src/lib/morphoMarketActions.ts", testFile: "src/lib/morphoMarketActions.test.ts",
    test: "keeps Max valid in 2,000 independently rounded future states, including changed share prices",
    needle: "maximumHorizonInterest(values.borrowed, s.projectionSeconds)", replacement: "maximumHorizonInterest(values.borrowed, 300n)",
  },
  {
    name: "Morpho reader omits the final post-projection head validation",
    file: "src/lib/morphoMarketReader.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "checks canonicality again after the forward IRM RPC, not only before it",
    needle: "  await validateHead();\n  const issuedAt = checkWindow();", replacement: "  const issuedAt = checkWindow();",
  },
  {
    name: "Morpho stalled reads silently exceed the documented time budget",
    file: "src/lib/morphoMarketProjection.ts", testFile: "src/lib/morphoMarketReader.test.ts",
    test: "times out a stalled RPC and refuses its late continuation",
    needle: "export const MARKET_READ_TIMEOUT_MS = 15_000;", replacement: "export const MARKET_READ_TIMEOUT_MS = 150_000;",
  },
  {
    name: "Morpho accepts the exact expiry instant as live",
    file: "src/lib/morphoMarketProjection.ts", testFile: "src/lib/morphoMarketProjection.test.ts",
    test: "rejects an expired or unverifiable clock",
    needle: "now < quote.expiresAt", replacement: "now <= quote.expiresAt",
  },
  {
    name: "Morpho shared write flow omits the post-gas wallet guard",
    file: "src/components/app/useWriteFlow.ts", testFile: "src/components/app/useWriteFlow.test.tsx",
    test: "does not open the wallet when the quote expires during",
    needle: "        params.assertBeforeWallet?.();", replacement: "        void params.assertBeforeWallet;",
  },
  {
    name: "Morpho page forgets to bind its quote to the wallet guard",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "quote in its final wallet guard",
    needle: "assertBeforeWallet: () => assertMarketQuoteCurrent(current),", replacement: "assertBeforeWallet: undefined,",
  },
  {
    name: "Morpho Safe reserves a Treasury proposal after expiry",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "rejects expiry after the Treasury nonce RPC before reserving a proposal",
    needle: '        assertMarketQuoteCurrent(current);\n        setSafeStatus({phase: "review"});', replacement: '        setSafeStatus({phase: "review"});',
  },
  {
    name: "Morpho Safe sends a batch whose reservation consumed the quote lifetime",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "checks expiry again after browser proposal reservation before Safe handoff",
    needle: "        assertMarketQuoteCurrent(current);\n        const result = await safe.context.sdk.txs.send", replacement: "        const result = await safe.context.sdk.txs.send",
  },
  {
    name: "Morpho Treasury history regresses to an oversized log range",
    file: "src/lib/morphoTreasury.ts", testFile: "src/lib/morphoTreasury.test.ts",
    test: "reads contiguous non-overlapping 1000-block chunks with all filters and a bounded tail",
    needle: "export const TREASURY_HISTORY_CHUNK = 1_000n;", replacement: "export const TREASURY_HISTORY_CHUNK = 50_000n;",
  },
  {
    name: "Morpho Treasury allows another proposal after a reload",
    file: "src/components/app/MorphoMarketSurface.tsx", testFile: "src/components/app/MorphoMarketSurface.test.tsx",
    test: "refuses a duplicate Treasury proposal after a reload and queries the saved hash",
    needle: "?? (treasurySeed && proposal?.record ?", replacement: "?? (false && treasurySeed && proposal?.record ?",
  },
  {
    name: "Morpho Treasury forgets its intent before an uncertain Safe reply",
    file: "src/lib/morphoTreasury.ts", testFile: "src/lib/morphoTreasury.test.ts",
    test: "persists the exact intent before sending, then the Safe hash, and refuses a second intent",
    needle: "  storage.setItem(TREASURY_PROPOSAL_KEY, raw);\n  if (storage.getItem(TREASURY_PROPOSAL_KEY) !== raw) throw new Error(\"The Treasury proposal record could not be saved.\");",
    replacement: "  void raw;",
  },
  {
    name: "Morpho Treasury clears a queued proposal using the snapshot nonce",
    file: "src/lib/morphoTreasury.ts", testFile: "src/lib/morphoTreasury.test.ts",
    test: "does not confuse the proposal nonce with the earlier snapshot nonce",
    needle: "nonce > BigInt(execution.nonce)", replacement: "nonce > BigInt(record.nonce)",
  },
  {
    name: "Morpho Safe batch encodes a DELEGATECALL inner operation",
    file: "src/lib/morphoSafe.ts", testFile: "src/lib/morphoMarket.test.ts",
    test: "encodes only CALL operations and refuses an ETH transfer",
    needle: 'concatHex(["0x00", c.to,', replacement: 'concatHex(["0x01", c.to,',
  },
  {
    name: "Morpho Safe simulation accepts an explicit failure word",
    file: "src/lib/morphoSafe.ts", testFile: "src/lib/morphoMarket.test.ts",
    test: "accepts only the documented intentional success revert",
    needle: 'BigInt(`0x${data.slice(2, 66)}`) !== 1n', replacement: 'BigInt(`0x${data.slice(2, 66)}`) > 1n',
  },
  {
    name: "Morpho SDK trusts subdomains of the canonical Safe origin",
    file: "src/components/app/useMorphoSafe.ts", testFile: "src/components/app/useMorphoSafe.test.tsx",
    test: "accepts only the exact canonical HTTPS parent origin",
    needle: "allowedDomains: [/^https:\\/\\/app\\.safe\\.global$/]", replacement: "allowedDomains: [/^https:\\/\\/.*safe\\.global$/]",
  },
];

const args = process.argv.slice(2);
if (args.some(arg => arg !== "--morpho")) throw new Error("Only --morpho or the default full gate is supported.");
const selected = args.includes("--morpho") ? cases.filter(c => /morpho(Market|Safe|Treasury)|MorphoMarketSurface|useMorphoSafe/.test(c.file) || c.name.startsWith("Morpho ")) : cases;
const escapeRegex = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
function runTests(files, name) {
  const result = spawnSync(join(root, "node_modules/.bin/vitest"),
    ["run", ...files, "--reporter=json", ...(name ? ["-t", escapeRegex(name)] : [])],
    {cwd: root, encoding: "utf8", timeout: 120_000, maxBuffer: 16 * 1024 * 1024});
  let report;
  try {report = JSON.parse(result.stdout);} catch {throw new Error(`Test runner did not return a JSON report (exit ${result.status}). ${result.stderr ?? ""}`);}
  return {result, assertions: report.testResults.flatMap(suite => suite.assertionResults)};
}
// A mutant cannot be counted as killed by an already-failing or missing test.
const baseline = runTests([...new Set(selected.map(c => c.testFile))]);
if (baseline.result.status !== 0) throw new Error("The unmodified baseline failed; no mutation controls were counted.");
for (const control of selected) {
  const assertions = baseline.assertions.filter(test => test.fullName.includes(control.test));
  if (!assertions.length || assertions.some(test => test.status !== "passed")) throw new Error(`${control.name}: its exact baseline test was not passed`);
}
process.stdout.write(`Unmodified baseline passed for ${selected.length} mutation controls.\n`);
for (const control of selected) {
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
    const {result, assertions} = runTests([control.testFile], control.test);
    if (result.status === 0) throw new Error(`${control.name}: mutation survived`);
    if (!assertions.some(test => test.fullName.includes(control.test) && test.status === "failed")) {
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

process.stdout.write(`All ${selected.length} frontend mutation controls passed.\n`);
