/**
 * The Buy tab's exact transactions against the real USDfr/USDC Uniswap v4 pool, the real
 * Universal Router, V4Quoter and Permit2, and the live USDfr, on an anvil fork of Ethereum
 * mainnet pinned to block 26,099,500.
 *
 *   MAINNET_RPC_URL=<archive RPC> npm run test:fork      (needs anvil; skipped without the URL)
 *
 * Every calldata byte comes from `src/lib/uniswapV4Swap.ts`, the module the Buy tab calls, and
 * every transaction goes simulate, then estimate plus the write flow's 300,000 gas headroom,
 * then send, as `useWriteFlow` does. Outcomes are read back from chain state. Covered:
 *   - the quote the tab shows (V4Quoter, eth_call);
 *   - a first buy: the one-time maximum USDC approval to Permit2, a signed PermitSingle for exactly
 *     the amount, and execute(PERMIT2_PERMIT, V4_SWAP) paying at least the minimum and exactly the
 *     quote; then the same account's second buy: a signature and the swap only, no approval;
 *   - a buyer whose router allowance already covers the amount: one V4_SWAP command, no signature;
 *   - a minimum one wei above the quote reverts with V4TooLittleReceived, in simulation and mined;
 *   - an expired deadline reverts with TransactionDeadlinePassed;
 *   - a replayed permit is skipped by the router's allow-revert flag; with no standing allowance,
 *     the swap reverts with InsufficientAllowance and the UI explains the new permit did not apply;
 *   - a buyer short of USDC reverts with Permit2's TRANSFER_FROM_FAILED;
 *   - a jurisdiction-blocked buyer: the compliance pre-check says no, and the swap reverts inside
 *     the pool's USDfr payout with WrappedError(USDfr_TransferNotAllowed), decoded to words.
 *   - a compliance block after a signed permit and the pre-check still reverts atomically.
 * Impersonation and storage writes below are anvil-only and cannot reach the real chain.
 */
import {spawn, type ChildProcess} from "node:child_process";
import {readFileSync} from "node:fs";
import {createServer} from "node:net";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  maxUint256,
  numberToHex,
  parseAbi,
  type Address,
  type PrivateKeyAccount,
} from "viem";
import {generatePrivateKey, privateKeyToAccount} from "viem/accounts";
import {mainnet} from "viem/chains";
import {afterAll, beforeAll, describe, expect, it} from "vitest";

import {COMPLIANCE_ABI, ERC20_ABI} from "@/lib/abi";
import {PERMIT2_ABI, POOL_ID, STATE_VIEW_ABI, V4_POOL_MANAGER, V4_STATE_VIEW} from "@/lib/uniswapV4Liquidity";
import {
  DEFAULT_SLIPPAGE_BPS,
  PERMIT2,
  SWAP_ERROR_MESSAGES,
  UNIVERSAL_ROUTER,
  USDC,
  USDFR,
  V4_QUOTER,
  assertBuyArgsMatch,
  buildBuyExecuteArgs,
  buildPermitSingle,
  buyRequest,
  decodeBuyCalldata,
  decodeQuoteResult,
  decodeSwapError,
  describeParity,
  encodeBuyCalldata,
  encodeQuoteCall,
  minAmountOut,
  needsPermit,
  needsPermit2Approval,
  permit2ApprovalRequest,
  permitTypedData,
  priceE18,
  swapDeadline,
  type SignedPermit,
} from "@/lib/uniswapV4Swap";
import {fmtAmount} from "@/lib/format";

const FORK_BLOCK = 26_099_500n;
const USD = 10n ** 6n;
/** useWriteFlow's POINTS_HOOK_GAS_HEADROOM, added to every estimate before submission. */
const WRITE_FLOW_GAS_HEADROOM = 300_000n;

const manifest = JSON.parse(
  readFileSync(new URL("../../contracts/deployments/1-production-v2.json", import.meta.url), "utf8"),
) as {compliance: Address; opsAdmin: Address; usdfr: Address};
const COMPLIANCE_ADMIN_ROLE = keccak256(new TextEncoder().encode("COMPLIANCE_ADMIN_ROLE"));
const COMPLIANCE_ADMIN_ABI = parseAbi([
  "function setJurisdictionBlocked(address account, bool blocked)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
]);
const PERMIT2_APPROVE_ABI = parseAbi(["function approve(address token, address spender, uint160 amount, uint48 expiration)"]);

const forkUrl = process.env.MAINNET_RPC_URL?.trim() ?? "";
let anvil: ChildProcess | null = null;
let rpc = "";

function clients() {
  const transport = http(rpc, {timeout: 120_000});
  return {
    pub: createPublicClient({chain: mainnet, transport}),
    wallet: createWalletClient({chain: mainnet, transport}),
    test: createTestClient({chain: mainnet, mode: "anvil", transport}),
  };
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => (typeof address === "object" && address ? resolve(address.port) : reject(new Error("no port"))));
    });
  });
}

/** A fresh buyer with 1 ETH and `usdc` USDC (mainnet USDC keeps balances at mapping slot 9). */
async function freshBuyer(usdc: bigint): Promise<PrivateKeyAccount> {
  const account = privateKeyToAccount(generatePrivateKey());
  const {pub, test} = clients();
  await test.setBalance({address: account.address, value: 10n ** 18n});
  const slot = keccak256(encodeAbiParameters([{type: "address"}, {type: "uint256"}], [account.address, 9n]));
  await test.setStorageAt({address: USDC, index: slot, value: numberToHex(usdc, {size: 32})});
  expect(await balanceOf(USDC, account.address)).toBe(usdc);
  expect(await pub.getTransactionCount({address: account.address})).toBe(0);
  return account;
}

async function balanceOf(token: Address, owner: Address): Promise<bigint> {
  return clients().pub.readContract({address: token, abi: ERC20_ABI, functionName: "balanceOf", args: [owner]});
}

async function quote(amountIn: bigint) {
  const result = await clients().pub.call({to: V4_QUOTER, data: encodeQuoteCall(amountIn)});
  return decodeQuoteResult(amountIn, result.data);
}

/** The write flow's sequence: simulate, estimate plus headroom, send, wait. */
async function send(
  account: PrivateKeyAccount,
  request: {address: Address; abi: readonly unknown[]; functionName: string; args: readonly unknown[]},
) {
  const {pub, wallet} = clients();
  const call = {account, address: request.address, abi: request.abi, functionName: request.functionName, args: request.args} as never;
  await pub.simulateContract(call);
  const estimate = await pub.estimateContractGas(call);
  const hash = await wallet.writeContract({...(call as object), gas: estimate + WRITE_FLOW_GAS_HEADROOM, chain: mainnet} as never);
  const receipt = await pub.waitForTransactionReceipt({hash});
  return {hash, receipt, estimate};
}

/** Approval, fresh reads and (when needed) a signed permit, as the Buy tab prepares a buy. */
async function prepareBuy(buyer: PrivateKeyAccount, amountIn: bigint, amountOutMinimum: bigint, deadlineOverride?: bigint) {
  const {pub} = clients();
  const [block, [amount, expiration, nonce]] = await Promise.all([
    pub.getBlock(),
    pub.readContract({address: PERMIT2, abi: PERMIT2_ABI, functionName: "allowance", args: [buyer.address, USDC, UNIVERSAL_ROUTER]}),
  ]);
  const deadline = deadlineOverride ?? swapDeadline(block.timestamp);
  let signedPermit: SignedPermit | null = null;
  if (needsPermit({amount, expiration, nonce}, amountIn, deadline)) {
    const permit = buildPermitSingle({amount: amountIn, nonce, deadline});
    signedPermit = {permit, signature: await buyer.signTypedData(permitTypedData(permit))};
  }
  const args = buildBuyExecuteArgs({amountIn, amountOutMinimum, deadline, signedPermit});
  assertBuyArgsMatch(args, signedPermit
    ? {amountIn, amountOutMinimum, deadline, withPermit: true, permitNonce: nonce}
    : {amountIn, amountOutMinimum, deadline, withPermit: false});
  return {args, deadline, signedPermit};
}

async function expectSimulationError(buyer: PrivateKeyAccount, args: Parameters<typeof buyRequest>[0], signedPermit = false) {
  try {
    await clients().pub.simulateContract({account: buyer, ...buyRequest(args)});
  } catch (err) {
    return decodeSwapError(err, signedPermit);
  }
  throw new Error("The swap simulated successfully; a revert was expected.");
}

describe.skipIf(forkUrl === "")("Buy USDfr through Uniswap on a pinned mainnet fork", () => {
  beforeAll(async () => {
    const port = await freePort();
    rpc = `http://127.0.0.1:${port}`;
    // stdio is ignored: anvil's banner prints the fork URL, which carries the provider key.
    anvil = spawn(
      "anvil",
      ["--fork-url", forkUrl, "--fork-block-number", FORK_BLOCK.toString(), "--chain-id", "1", "--port", String(port), "--silent"],
      {stdio: "ignore"},
    );
    for (let attempt = 0; ; attempt++) {
      try {
        await clients().pub.getBlockNumber();
        break;
      } catch {
        if (attempt > 240) throw new Error("anvil did not start");
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
    }
    expect(await clients().pub.getBlockNumber()).toBe(FORK_BLOCK);
  }, 180_000);

  afterAll(() => {
    anvil?.kill("SIGTERM");
  });

  it("is the live pool: the manifest's USDfr, initialized, with the fee the tab displays", async () => {
    const {pub} = clients();
    expect(manifest.usdfr.toLowerCase()).toBe(USDFR.toLowerCase());
    const [sqrtPriceX96, tick, protocolFee, lpFee] = await pub.readContract({
      address: V4_STATE_VIEW,
      abi: STATE_VIEW_ABI,
      functionName: "getSlot0",
      args: [POOL_ID],
    });
    console.log(`[pool] block ${FORK_BLOCK}: sqrtPriceX96 ${sqrtPriceX96}, tick ${tick}, protocolFee ${protocolFee}, lpFee ${lpFee}`);
    expect(sqrtPriceX96).toBeGreaterThan(0n);
    expect(lpFee).toBe(375);
  });

  it("a first buy approves Permit2 once (the maximum), signs and swaps; the same account's second buy only signs and swaps", async () => {
    const firstIn = 1_000n * USD;
    const secondIn = 500n * USD;
    const buyer = await freshBuyer(firstIn + secondIn);
    const {pub} = clients();
    const usdcAllowanceToPermit2 = () =>
      pub.readContract({address: USDC, abi: ERC20_ABI, functionName: "allowance", args: [buyer.address, PERMIT2]});
    const routerAllowance = () =>
      pub.readContract({address: PERMIT2, abi: PERMIT2_ABI, functionName: "allowance", args: [buyer.address, USDC, UNIVERSAL_ROUTER]});
    const shown = await quote(firstIn);
    const minimum = minAmountOut(shown.amountOut, DEFAULT_SLIPPAGE_BPS);
    console.log(
      `[quote] ${fmtAmount(firstIn, 6, 6)} USDC -> ${fmtAmount(shown.amountOut, 18, 6)} USDfr ` +
        `(1 USDC = ${fmtAmount(priceE18(firstIn, shown.amountOut), 18, 6)} USDfr, ${describeParity(firstIn, shown.amountOut)}); ` +
        `quoter gas estimate ${shown.gasEstimate}; minimum at the default slippage: ${fmtAmount(minimum, 18, 6)} USDfr`,
    );

    // FIRST BUY. Step 1, "Approve USDC for Uniswap (once)": the tab's own request, the maximum.
    expect(needsPermit2Approval(await usdcAllowanceToPermit2(), firstIn)).toBe(true);
    const approval = await send(buyer, permit2ApprovalRequest());
    expect(approval.receipt.status).toBe("success");
    expect(await usdcAllowanceToPermit2()).toBe(maxUint256);

    // Step 2, "Buy USDfr": the tab's pre-check, the permit for exactly this amount, then execute.
    expect(
      await pub.readContract({
        address: manifest.compliance,
        abi: COMPLIANCE_ABI,
        functionName: "canTransfer",
        args: [USDFR, V4_POOL_MANAGER, buyer.address],
      }),
    ).toBe(true);
    const first = await prepareBuy(buyer, firstIn, minimum);
    expect(first.signedPermit?.permit.details.amount).toBe(firstIn);
    expect(first.signedPermit?.permit.details.nonce).toBe(0);
    expect(decodeBuyCalldata(encodeBuyCalldata(first.args)).commands).toBe("0x8a10");
    const atExecution = await quote(firstIn);
    const firstSwap = await send(buyer, buyRequest(first.args));
    expect(firstSwap.receipt.status).toBe("success");
    expect(firstSwap.receipt.to?.toLowerCase()).toBe(UNIVERSAL_ROUTER.toLowerCase());
    const firstReceived = await balanceOf(USDFR, buyer.address);
    console.log(
      `[first buy] approval tx ${approval.hash}: gas used ${approval.receipt.gasUsed}; swap tx ${firstSwap.hash}: ` +
        `paid ${fmtAmount(firstIn, 6, 6)} USDC, received ${fmtAmount(firstReceived, 18, 18)} USDfr ` +
        `(quote ${atExecution.amountOut}, minimum ${minimum}); gas used ${firstSwap.receipt.gasUsed} of limit ` +
        `${firstSwap.estimate + WRITE_FLOW_GAS_HEADROOM} (estimate ${firstSwap.estimate}); ` +
        `first buy total ${approval.receipt.gasUsed + firstSwap.receipt.gasUsed}`,
    );
    expect(firstReceived).toBeGreaterThanOrEqual(minimum);
    expect(firstReceived).toBe(atExecution.amountOut);
    expect(atExecution.amountOut).toBe(shown.amountOut);
    // USDC decrements even the maximum; what is left covers any later buy. The signed router
    // allowance was exactly the amount, so none of it is left, and Permit2's nonce moved on.
    expect(await usdcAllowanceToPermit2()).toBe(maxUint256 - firstIn);
    const [leftAfterFirst, , nonceAfterFirst] = await routerAllowance();
    expect(leftAfterFirst).toBe(0n);
    expect(nonceAfterFirst).toBe(1);
    expect(await pub.getTransactionCount({address: buyer.address})).toBe(2);

    // SECOND BUY by the same account: no approval step, a signature and the swap only.
    expect(needsPermit2Approval(await usdcAllowanceToPermit2(), secondIn)).toBe(false);
    const secondShown = await quote(secondIn);
    const secondMinimum = minAmountOut(secondShown.amountOut, DEFAULT_SLIPPAGE_BPS);
    const second = await prepareBuy(buyer, secondIn, secondMinimum);
    expect(second.signedPermit?.permit.details.amount).toBe(secondIn);
    expect(second.signedPermit?.permit.details.nonce).toBe(1);
    expect(second.args[0]).toBe("0x8a10");
    const usdfrBeforeSecond = await balanceOf(USDFR, buyer.address);
    const secondSwap = await send(buyer, buyRequest(second.args));
    expect(secondSwap.receipt.status).toBe("success");
    const secondReceived = (await balanceOf(USDFR, buyer.address)) - usdfrBeforeSecond;
    console.log(
      `[second buy] swap tx ${secondSwap.hash} (no approval): paid ${fmtAmount(secondIn, 6, 6)} USDC, received ` +
        `${fmtAmount(secondReceived, 18, 18)} USDfr (quote ${secondShown.amountOut}, minimum ${secondMinimum}); ` +
        `gas used ${secondSwap.receipt.gasUsed} of limit ${secondSwap.estimate + WRITE_FLOW_GAS_HEADROOM} ` +
        `(estimate ${secondSwap.estimate})`,
    );
    expect(secondReceived).toBeGreaterThanOrEqual(secondMinimum);
    expect(secondReceived).toBe(secondShown.amountOut);
    // Exactly one transaction for the second buy: the swap.
    expect(await pub.getTransactionCount({address: buyer.address})).toBe(3);
    expect(await balanceOf(USDC, buyer.address)).toBe(0n);
    expect(await usdcAllowanceToPermit2()).toBe(maxUint256 - firstIn - secondIn);
    const [leftAfterSecond, , nonceAfterSecond] = await routerAllowance();
    expect(leftAfterSecond).toBe(0n);
    expect(nonceAfterSecond).toBe(2);

    // The router skips a stale signed permit. With no usable router allowance left, the swap still
    // fails, and the Buy card's signed-permit error explains that the new permission did not apply.
    await clients().test.setStorageAt({
      address: USDC,
      index: keccak256(encodeAbiParameters([{type: "address"}, {type: "uint256"}], [buyer.address, 9n])),
      value: numberToHex(firstIn, {size: 32}),
    });
    const replay = buildBuyExecuteArgs({
      amountIn: firstIn,
      amountOutMinimum: minAmountOut((await quote(firstIn)).amountOut, DEFAULT_SLIPPAGE_BPS),
      deadline: first.signedPermit!.permit.sigDeadline,
      signedPermit: first.signedPermit,
    });
    const replayed = await expectSimulationError(buyer, replay, true);
    expect(replayed.errorName).toBe("InsufficientAllowance");
    expect(replayed.message).toContain("did not apply this buy's new signature");
  });

  it("a buyer whose router allowance already covers the amount sends one V4_SWAP command and signs nothing", async () => {
    const amountIn = 250n * USD;
    const buyer = await freshBuyer(amountIn);
    await send(buyer, permit2ApprovalRequest());
    const block = await clients().pub.getBlock();
    // As a wallet that used Uniswap's own interface would have: a standing Permit2 allowance.
    await send(buyer, {
      address: PERMIT2,
      abi: PERMIT2_APPROVE_ABI,
      functionName: "approve",
      args: [USDC, UNIVERSAL_ROUTER, amountIn, Number(block.timestamp + 86_400n)],
    });
    const shown = await quote(amountIn);
    const minimum = minAmountOut(shown.amountOut, DEFAULT_SLIPPAGE_BPS);
    const {args, signedPermit} = await prepareBuy(buyer, amountIn, minimum);
    expect(signedPermit).toBeNull();
    expect(args[0]).toBe("0x10");
    const swap = await send(buyer, buyRequest(args));
    expect(swap.receipt.status).toBe("success");
    const received = await balanceOf(USDFR, buyer.address);
    console.log(
      `[returning buy] tx ${swap.hash}: ${fmtAmount(amountIn, 6, 6)} USDC -> ${fmtAmount(received, 18, 18)} USDfr ` +
        `(quote ${shown.amountOut}); gas used ${swap.receipt.gasUsed}`,
    );
    expect(received).toBe(shown.amountOut);
    expect(received).toBeGreaterThanOrEqual(minimum);
  });

  it("a minimum one wei above the quote reverts with the slippage error, in simulation and when mined", async () => {
    const amountIn = 100n * USD;
    const buyer = await freshBuyer(amountIn);
    await send(buyer, permit2ApprovalRequest());
    const shown = await quote(amountIn);
    const {args} = await prepareBuy(buyer, amountIn, shown.amountOut + 1n);
    expect(await expectSimulationError(buyer, args)).toEqual({
      message: SWAP_ERROR_MESSAGES.V4TooLittleReceived,
      errorName: "V4TooLittleReceived",
    });
    // Mined anyway, with a fixed limit, it reverts and moves nothing.
    const {pub, wallet} = clients();
    const hash = await wallet.sendTransaction({
      account: buyer,
      to: UNIVERSAL_ROUTER,
      data: encodeBuyCalldata(args),
      gas: 1_000_000n,
      chain: mainnet,
    });
    const receipt = await pub.waitForTransactionReceipt({hash});
    expect(receipt.status).toBe("reverted");
    expect(await balanceOf(USDC, buyer.address)).toBe(amountIn);
    expect(await balanceOf(USDFR, buyer.address)).toBe(0n);
  });

  it("an expired deadline reverts with TransactionDeadlinePassed", async () => {
    const amountIn = 100n * USD;
    const buyer = await freshBuyer(amountIn);
    await send(buyer, permit2ApprovalRequest());
    const shown = await quote(amountIn);
    const block = await clients().pub.getBlock();
    const {args} = await prepareBuy(buyer, amountIn, minAmountOut(shown.amountOut, DEFAULT_SLIPPAGE_BPS), block.timestamp - 1n);
    expect(await expectSimulationError(buyer, args)).toEqual({
      message: SWAP_ERROR_MESSAGES.TransactionDeadlinePassed,
      errorName: "TransactionDeadlinePassed",
    });
  });

  it("a buyer short of USDC is refused by Permit2's transfer, in words", async () => {
    const amountIn = 100n * USD;
    const buyer = await freshBuyer(amountIn - 1n);
    await send(buyer, permit2ApprovalRequest());
    const shown = await quote(amountIn);
    const {args} = await prepareBuy(buyer, amountIn, minAmountOut(shown.amountOut, DEFAULT_SLIPPAGE_BPS));
    expect(await expectSimulationError(buyer, args)).toEqual({
      message: SWAP_ERROR_MESSAGES.TRANSFER_FROM_FAILED,
      errorName: "TRANSFER_FROM_FAILED",
    });
  });

  it("a jurisdiction-blocked buyer is told before signing, and the swap reverts inside the pool's USDfr payout", async () => {
    const amountIn = 100n * USD;
    const buyer = await freshBuyer(amountIn);
    await send(buyer, permit2ApprovalRequest());
    const {pub, wallet, test} = clients();
    expect(
      await pub.readContract({
        address: manifest.compliance,
        abi: COMPLIANCE_ADMIN_ABI,
        functionName: "hasRole",
        args: [COMPLIANCE_ADMIN_ROLE, manifest.opsAdmin],
      }),
    ).toBe(true);
    await test.impersonateAccount({address: manifest.opsAdmin});
    await test.setBalance({address: manifest.opsAdmin, value: 10n ** 18n});
    const blockHash = await wallet.writeContract({
      account: manifest.opsAdmin,
      address: manifest.compliance,
      abi: COMPLIANCE_ADMIN_ABI,
      functionName: "setJurisdictionBlocked",
      args: [buyer.address, true],
      chain: mainnet,
    });
    expect((await pub.waitForTransactionReceipt({hash: blockHash})).status).toBe("success");
    await test.stopImpersonatingAccount({address: manifest.opsAdmin});

    // The Buy tab's pre-check, before any signature.
    expect(
      await pub.readContract({
        address: manifest.compliance,
        abi: COMPLIANCE_ABI,
        functionName: "canTransfer",
        args: [USDFR, V4_POOL_MANAGER, buyer.address],
      }),
    ).toBe(false);
    // And the simulation, had it got that far: USDfr refuses the PoolManager's payment.
    const shown = await quote(amountIn);
    const {args} = await prepareBuy(buyer, amountIn, minAmountOut(shown.amountOut, DEFAULT_SLIPPAGE_BPS));
    const decoded = await expectSimulationError(buyer, args);
    expect(decoded).toEqual({message: SWAP_ERROR_MESSAGES.USDfr_TransferNotAllowed, errorName: "USDfr_TransferNotAllowed"});
    console.log(`[blocked buyer] ${decoded.errorName}: ${decoded.message}`);
  });

  it("a compliance flip after precheck rolls back the entire signed buy", async () => {
    const amountIn = 100n * USD;
    const buyer = await freshBuyer(amountIn);
    await send(buyer, permit2ApprovalRequest());
    const {pub, wallet, test} = clients();
    const canReceive = () => pub.readContract({
      address: manifest.compliance,
      abi: COMPLIANCE_ABI,
      functionName: "canTransfer",
      args: [USDFR, V4_POOL_MANAGER, buyer.address],
    });
    const routerAllowance = () => pub.readContract({
      address: PERMIT2,
      abi: PERMIT2_ABI,
      functionName: "allowance",
      args: [buyer.address, USDC, UNIVERSAL_ROUTER],
    });
    expect(await canReceive()).toBe(true);
    const shown = await quote(amountIn);
    const minimum = minAmountOut(shown.amountOut, DEFAULT_SLIPPAGE_BPS);
    const {args, signedPermit} = await prepareBuy(buyer, amountIn, minimum);
    expect(signedPermit).not.toBeNull();
    expect(await routerAllowance()).toEqual([0n, 0, 0]);

    // An operator changes compliance after the Buy card has checked eligibility and
    // the wallet has signed, but before the prepared transaction reaches the chain.
    await test.impersonateAccount({address: manifest.opsAdmin});
    await test.setBalance({address: manifest.opsAdmin, value: 10n ** 18n});
    const blockHash = await wallet.writeContract({
      account: manifest.opsAdmin,
      address: manifest.compliance,
      abi: COMPLIANCE_ADMIN_ABI,
      functionName: "setJurisdictionBlocked",
      args: [buyer.address, true],
      chain: mainnet,
    });
    expect((await pub.waitForTransactionReceipt({hash: blockHash})).status).toBe("success");
    await test.stopImpersonatingAccount({address: manifest.opsAdmin});
    expect(await canReceive()).toBe(false);
    const decoded = await expectSimulationError(buyer, args, true);
    expect(decoded.errorName).toBe("USDfr_TransferNotAllowed");

    // Ignore the UI's failed simulation on this disposable fork to prove the
    // on-chain transaction is atomic even when signed calldata is broadcast.
    const hash = await wallet.sendTransaction({
      account: buyer,
      to: UNIVERSAL_ROUTER,
      data: encodeBuyCalldata(args),
      gas: 2_000_000n,
      chain: mainnet,
    });
    const receipt = await pub.waitForTransactionReceipt({hash});
    expect(receipt.status).toBe("reverted");
    expect(await balanceOf(USDC, buyer.address)).toBe(amountIn);
    expect(await balanceOf(USDFR, buyer.address)).toBe(0n);
    expect(await routerAllowance()).toEqual([0n, 0, 0]);
  });
});
