import {encodeAbiParameters, encodeFunctionData, keccak256, parseAbi, parseUnits, type Address, type Hex} from "viem";

/** One reviewed Ethereum market. No URL, wallet input or API response selects its identity. */
export const MORPHO_MARKET = {
  chainId: 1,
  address: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
  id: "0xf25b12a81e96dfcc882038cd53ec32a6d74ac46186c867ade041d1cf34e2e897",
  fromBlock: 26_232_245n,
  oracleCodehash: "0x26ef6287f527737bb7b5a37bea8681a08d5f98ddcd941338570408621c2035b3",
  treasury: "0x0687a13c490B2573d4666fb3a7c21826a621215E",
  seed: 50_000_000_000n,
  loanDecimals: 6,
  collateralDecimals: 24,
  params: {
    loanToken: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    collateralToken: "0xAF559d1D59B33ca4b950AB2091372Af8a773E234",
    oracle: "0xa60a8c2824A2696D9D3ff05870cfa3c01BF9C4Eb",
    irm: "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",
    lltv: 860_000_000_000_000_000n,
  },
} as const;

export const MORPHO_MARKET_ABI = parseAbi([
  "struct MarketParams { address loanToken; address collateralToken; address oracle; address irm; uint256 lltv; }",
  "struct Market { uint128 totalSupplyAssets; uint128 totalSupplyShares; uint128 totalBorrowAssets; uint128 totalBorrowShares; uint128 lastUpdate; uint128 fee; }",
  "function idToMarketParams(bytes32) view returns (MarketParams)",
  "function market(bytes32) view returns (uint128 totalSupplyAssets,uint128 totalSupplyShares,uint128 totalBorrowAssets,uint128 totalBorrowShares,uint128 lastUpdate,uint128 fee)",
  "function position(bytes32,address) view returns (uint256 supplyShares,uint128 borrowShares,uint128 collateral)",
  "function supply(MarketParams marketParams,uint256 assets,uint256 shares,address onBehalf,bytes data) returns (uint256,uint256)",
  "function withdraw(MarketParams marketParams,uint256 assets,uint256 shares,address onBehalf,address receiver) returns (uint256,uint256)",
  "function supplyCollateral(MarketParams marketParams,uint256 assets,address onBehalf,bytes data)",
  "function withdrawCollateral(MarketParams marketParams,uint256 assets,address onBehalf,address receiver)",
  "function borrow(MarketParams marketParams,uint256 assets,uint256 shares,address onBehalf,address receiver) returns (uint256,uint256)",
  "function repay(MarketParams marketParams,uint256 assets,uint256 shares,address onBehalf,bytes data) returns (uint256,uint256)",
  "function borrowRateView(MarketParams marketParams,Market market) view returns (uint256)",
]);
export const MARKET_TOKEN_ABI = parseAbi([
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);
export const MARKET_ORACLE_ABI = parseAbi([
  "function price() view returns (uint256)",
  "function vault() view returns (address)",
  "function controller() view returns (address)",
  "function reserves() view returns (address)",
  "function loanToken() view returns (address)",
]);
export const MARKET_SAFE_ABI = parseAbi([
  "function nonce() view returns (uint256)",
  "function getOwners() view returns (address[])",
  "function getThreshold() view returns (uint256)",
]);
export const WAD = 10n ** 18n;
export const ORACLE_SCALE = 10n ** 36n;
export type MarketState = {
  totalSupplyAssets: bigint; totalSupplyShares: bigint;
  totalBorrowAssets: bigint; totalBorrowShares: bigint; lastUpdate: bigint; fee: bigint;
};
export type MarketPosition = {supplyShares: bigint; borrowShares: bigint; collateral: bigint};
export type MarketAction = "supply" | "withdraw" | "supplyCollateral" | "withdrawCollateral" | "borrow" | "repay";
export type MarketCall = {to: Address; value: "0"; data: Hex};
export type MarketLaunch = {lending: boolean; borrowing: boolean; treasury: boolean};
export const CLOSED_MARKET_LAUNCH: MarketLaunch = {lending: false, borrowing: false, treasury: false};
export const isTreasury = (wallet: Address) => wallet.toLowerCase() === MORPHO_MARKET.treasury.toLowerCase();
export const ceilDiv = (n: bigint, d: bigint) => (n + d - 1n) / d;

export function parseMarketAmount(text: string, decimals: number): bigint | null {
  // parseUnits rounds overprecision; reject it before parsing money.
  if (text.length > 80 || !new RegExp(`^(?:0|[1-9]\\d*)(?:\\.\\d{1,${decimals}})?$`).test(text)) return null;
  const amount = parseUnits(text, decimals);
  return amount > 0n && amount < 2n ** 128n ? amount : null;
}

/** Morpho's interest, fee-share dilution and virtual offsets, with its exact rounding. */
export function accrueMarket(m: MarketState, rate: bigint, timestamp: bigint): MarketState {
  const elapsed = timestamp - m.lastUpdate;
  if (elapsed <= 0n) return m;
  const first = rate * elapsed;
  const second = first * first / (2n * WAD);
  const third = second * first / (3n * WAD);
  const interest = m.totalBorrowAssets * (first + second + third) / WAD;
  const supplyAssets = m.totalSupplyAssets + interest;
  const feeAssets = interest * m.fee / WAD;
  const feeShares = feeAssets * (m.totalSupplyShares + 1_000_000n) / (supplyAssets - feeAssets + 1n);
  return {...m, totalSupplyAssets: supplyAssets, totalSupplyShares: m.totalSupplyShares + feeShares,
    totalBorrowAssets: m.totalBorrowAssets + interest, lastUpdate: timestamp};
}

export function marketPositionValues(m: MarketState, p: MarketPosition, price: bigint) {
  const supplied = p.supplyShares * (m.totalSupplyAssets + 1n) / (m.totalSupplyShares + 1_000_000n);
  const borrowed = ceilDiv(p.borrowShares * (m.totalBorrowAssets + 1n), m.totalBorrowShares + 1_000_000n);
  const collateralValue = p.collateral * price / ORACLE_SCALE;
  const liquidationDebt = collateralValue * MORPHO_MARKET.params.lltv / WAD;
  const liquidity = m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0n;
  const remaining = liquidationDebt > borrowed ? liquidationDebt - borrowed : 0n;
  return {supplied, borrowed, collateralValue, liquidationDebt, liquidity,
    borrowAvailable: remaining < liquidity ? remaining : liquidity,
    ltvBps: collateralValue === 0n ? null : ceilDiv(borrowed * 10_000n, collateralValue)};
}

/** A user can only create/manage their own position and receive into that same wallet. */
export function marketAction(action: MarketAction, amount: bigint, wallet: Address, shares = 0n) {
  if (amount < 0n || shares < 0n || (amount === 0n && shares === 0n) || (amount > 0n && shares > 0n)) {
    throw new Error("Choose a positive asset amount or share amount, exclusively.");
  }
  const p = MORPHO_MARKET.params;
  const args = action === "supplyCollateral" ? [p, amount, wallet, "0x"] as const
    : action === "withdrawCollateral" ? [p, amount, wallet, wallet] as const
    : action === "supply" || action === "repay" ? [p, amount, shares, wallet, "0x"] as const
    : [p, amount, shares, wallet, wallet] as const;
  if ((action === "supplyCollateral" || action === "withdrawCollateral") && shares !== 0n) throw new Error("Collateral has no shares.");
  return {address: MORPHO_MARKET.address, abi: MORPHO_MARKET_ABI, functionName: action, args};
}

/** Fixed seed: deliberately accepts no amount, oracle, market or recipient arguments. */
export function treasurySupplyCalls(): [MarketCall, MarketCall] {
  return [
    {to: MORPHO_MARKET.params.loanToken, value: "0", data: encodeFunctionData({abi: MARKET_TOKEN_ABI,
      functionName: "approve", args: [MORPHO_MARKET.address, MORPHO_MARKET.seed]})},
    {to: MORPHO_MARKET.address, value: "0", data: encodeFunctionData({abi: MORPHO_MARKET_ABI,
      functionName: "supply", args: [MORPHO_MARKET.params, MORPHO_MARKET.seed, 0n, MORPHO_MARKET.treasury, "0x"]})},
  ];
}

export function assertTreasurySupplyCalls(calls: readonly MarketCall[]) {
  const expected = treasurySupplyCalls();
  if (calls.length !== 2 || calls.some((c, i) => c.to.toLowerCase() !== expected[i].to.toLowerCase()
    || c.value !== "0" || c.data.toLowerCase() !== expected[i].data.toLowerCase()
    || Object.keys(c).sort().join(",") !== "data,to,value")) throw new Error("Treasury batch differs from the exact reviewed 50,000-USDC calls.");
}

/** Review digest binds chain, Safe, order, targets, values and calldata. It is not a Safe tx hash. */
export function treasurySupplyDigest() {
  const calls = treasurySupplyCalls();
  return keccak256(encodeAbiParameters([
    {type: "uint256"}, {type: "address"},
    {type: "tuple[]", components: [{name: "to", type: "address"}, {name: "value", type: "uint256"}, {name: "data", type: "bytes"}]},
  ], [1n, MORPHO_MARKET.treasury, calls.map(c => ({...c, value: 0n}))]));
}

/** Failed/missing release configuration never enables a financial entry action. */
export function marketLaunch(env: Readonly<Record<string, string | undefined>>): MarketLaunch {
  return {
    lending: env.MORPHO_LENDING_ENABLED === "true",
    borrowing: env.MORPHO_BORROWING_ENABLED === "true",
    treasury: env.MORPHO_TREASURY_SUPPLY_ENABLED === "true",
  };
}
