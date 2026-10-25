import {keccak256, type Address, type Hex, type PublicClient} from "viem";
import {accrueMarket, MARKET_ORACLE_ABI, MARKET_SAFE_ABI, MARKET_TOKEN_ABI, MORPHO_MARKET,
  MORPHO_MARKET_ABI, isTreasury, marketPositionValues, type MarketPosition} from "./morphoMarket";
import {MARKET_EXECUTION_MARGIN_SECONDS, MARKET_FUTURE_SKEW_SECONDS, MARKET_READ_TIMEOUT_MS,
  REPAY_INTEREST_SECONDS} from "./morphoMarketProjection";

export async function readMorphoMarket(client: PublicClient, wallet?: Address) {
  const startedAt = Date.now(), startedMonotonic = performance.now();
  let lastWall = startedAt, expired = false;
  const readError = () => new Error("Market read timed out or its clock changed. Refresh to request a new quote.");
  const checkWindow = () => {
    const now = Date.now();
    if (expired || !Number.isSafeInteger(now) || now < lastWall
      || now - startedAt >= MARKET_READ_TIMEOUT_MS || performance.now() - startedMonotonic >= MARKET_READ_TIMEOUT_MS) throw readError();
    lastWall = now;
    return now;
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  // RPC requests themselves may outlive this timer. No late result is accepted, and
  // checkWindow prevents a late phase from starting any further snapshot reads.
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {expired = true; reject(readError());}, MARKET_READ_TIMEOUT_MS);
  });
  try {return await Promise.race([readWithinWindow(client, wallet, checkWindow), deadline]);}
  finally {clearTimeout(timer);}
}

type EthereumHead = {number: bigint | null; hash: Hex | null; timestamp: bigint};
function assertFreshHead(block: EthereumHead, nowMs: number) {
  const now = BigInt(Math.floor(nowMs / 1_000));
  if (!block.number || !block.hash || now - block.timestamp > 90n || block.timestamp > now + MARKET_FUTURE_SKEW_SECONDS) {
    throw new Error("Current Ethereum state is unavailable.");
  }
}

async function readWithinWindow(client: PublicClient, wallet: Address | undefined, checkWindow: () => number) {
  if (await client.getChainId() !== 1) throw new Error("This market is on Ethereum mainnet.");
  checkWindow();
  const block = await client.getBlock({blockTag: "latest"});
  assertFreshHead(block, checkWindow());
  const blockNumber = block.number!;
  const validateHead = async () => {
    const [canonical, latest] = await Promise.all([client.getBlock({blockNumber}), client.getBlock({blockTag: "latest"})]);
    const now = checkWindow();
    if (canonical.hash !== block.hash || !latest.number || latest.number < blockNumber || latest.timestamp < block.timestamp
      || (latest.number === blockNumber && latest.hash !== block.hash)) throw new Error("Ethereum reorganized during the market read. Refresh to retry.");
    assertFreshHead(latest, now);
  };
  const {params: p, address, id} = MORPHO_MARKET;
  const [params, stored, oracleCode, price, loanDecimals, collateralDecimals] = await Promise.all([
    client.readContract({address, abi: MORPHO_MARKET_ABI, functionName: "idToMarketParams", args: [id], blockNumber}),
    client.readContract({address, abi: MORPHO_MARKET_ABI, functionName: "market", args: [id], blockNumber}),
    client.getCode({address: p.oracle, blockNumber}),
    client.readContract({address: p.oracle, abi: MARKET_ORACLE_ABI, functionName: "price", blockNumber}),
    client.readContract({address: p.loanToken, abi: MARKET_TOKEN_ABI, functionName: "decimals", blockNumber}),
    client.readContract({address: p.collateralToken, abi: MARKET_TOKEN_ABI, functionName: "decimals", blockNumber}),
  ]);
  checkWindow();
  for (const key of ["loanToken", "collateralToken", "oracle", "irm"] as const) {
    if (params[key].toLowerCase() !== p[key].toLowerCase()) throw new Error("The live market identity differs from the reviewed market.");
  }
  if (params.lltv !== p.lltv || stored[4] < REPAY_INTEREST_SECONDS || stored[4] > block.timestamp
    || !oracleCode || keccak256(oracleCode) !== MORPHO_MARKET.oracleCodehash
    || loanDecimals !== MORPHO_MARKET.loanDecimals || collateralDecimals !== MORPHO_MARKET.collateralDecimals) {
    throw new Error("The live market or oracle could not be verified.");
  }
  const state = {totalSupplyAssets: stored[0], totalSupplyShares: stored[1], totalBorrowAssets: stored[2],
    totalBorrowShares: stored[3], lastUpdate: stored[4], fee: stored[5]};
  // The immutable IRM uses timestamp - lastUpdate, not lastUpdate independently.
  // Read today's trailing average first; the forward view is issued only after all
  // prerequisite reads and canonical/latest-head validation below.
  const rate = await client.readContract({address: p.irm, abi: MORPHO_MARKET_ABI,
    functionName: "borrowRateView", args: [p, state], blockNumber});
  checkWindow();
  const market = accrueMarket(state, rate, block.timestamp);
  const liquidity = market.totalSupplyAssets - market.totalBorrowAssets;
  if (liquidity < 0n) throw new Error("Market accounting is inconsistent.");
  const utilization = market.totalSupplyAssets === 0n ? 0n : market.totalBorrowAssets * 10n ** 18n / market.totalSupplyAssets;
  let account: null | {wallet: Address; position: MarketPosition; usdc: bigint; collateral: bigint; usdcAllowance: bigint; collateralAllowance: bigint;
    values: ReturnType<typeof marketPositionValues>; safeNonce: bigint | null} = null;
  if (wallet) {
    const [pos, usdc, collateral, usdcAllowance, collateralAllowance, safeNonce] = await Promise.all([
      client.readContract({address, abi: MORPHO_MARKET_ABI, functionName: "position", args: [id, wallet], blockNumber}),
      client.readContract({address: p.loanToken, abi: MARKET_TOKEN_ABI, functionName: "balanceOf", args: [wallet], blockNumber}),
      client.readContract({address: p.collateralToken, abi: MARKET_TOKEN_ABI, functionName: "balanceOf", args: [wallet], blockNumber}),
      client.readContract({address: p.loanToken, abi: MARKET_TOKEN_ABI, functionName: "allowance", args: [wallet, address], blockNumber}),
      client.readContract({address: p.collateralToken, abi: MARKET_TOKEN_ABI, functionName: "allowance", args: [wallet, address], blockNumber}),
      isTreasury(wallet) ? client.readContract({address: wallet, abi: MARKET_SAFE_ABI, functionName: "nonce", blockNumber}) : Promise.resolve(null),
    ]);
    checkWindow();
    const position = {supplyShares: pos[0], borrowShares: pos[1], collateral: pos[2]};
    account = {wallet, position, usdc, collateral, usdcAllowance, collateralAllowance,
      values: marketPositionValues(market, position, price), safeNonce};
  }
  await validateHead();
  // S1021MF-01: cover five minutes from COMPLETED issuance, not from a potentially
  // 90-second-old block. Reserving the entire bounded read budget covers the remaining
  // forward RPC and final head checks. Also allow the accepted clock skew and one slot.
  const projectedThrough = BigInt(Math.ceil(checkWindow() / 1_000)) + REPAY_INTEREST_SECONDS
    + BigInt(MARKET_READ_TIMEOUT_MS / 1_000) + MARKET_FUTURE_SKEW_SECONDS + MARKET_EXECUTION_MARGIN_SECONDS;
  const projectionSeconds = projectedThrough - block.timestamp;
  if (state.lastUpdate < projectionSeconds) throw new Error("The live market or oracle could not be verified.");
  // Shift ORIGINAL stored state: this computes the exact future IRM average,
  // including idle-market adaptation, without reusing today's trailing rate.
  const horizonRate = await client.readContract({address: p.irm, abi: MORPHO_MARKET_ABI,
    functionName: "borrowRateView", args: [p, {...state, lastUpdate: state.lastUpdate - projectionSeconds}], blockNumber});
  checkWindow();
  const projectedMarket = accrueMarket(state, horizonRate, projectedThrough);
  await validateHead();
  const issuedAt = checkWindow();
  const expiresAt = issuedAt + Number(REPAY_INTEREST_SECONDS) * 1_000;
  return {block: blockNumber, blockHash: block.hash!, timestamp: block.timestamp, readAt: issuedAt,
    issuedAt, expiresAt, projectedThrough, projectionSeconds, market, projectedMarket, price, rate,
    supplyRate: rate * utilization / 10n ** 18n * (10n ** 18n - market.fee) / 10n ** 18n, liquidity, account};
}

export type MorphoMarketSnapshot = Awaited<ReturnType<typeof readMorphoMarket>>;
