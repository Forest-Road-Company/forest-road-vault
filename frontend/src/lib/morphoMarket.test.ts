import {describe, expect, it} from "vitest";
import {decodeFunctionData, encodeAbiParameters, encodeFunctionData, keccak256, parseAbi, parseAbiParameters} from "viem";
import {accrueMarket, assertTreasurySupplyCalls, marketAction, marketLaunch, marketPositionValues, MORPHO_MARKET,
  MORPHO_MARKET_ABI, MARKET_TOKEN_ABI, parseMarketAmount, treasurySupplyCalls, treasurySupplyDigest, type MarketCall} from "./morphoMarket";
import {assertSafeSimulationResult, encodeSafeCalls} from "./morphoSafe";

const wallet = "0x0000000000000000000000000000000000000B0b";
describe("reviewed Morpho market and Treasury bytes", () => {
  it("derives the deployed market id from every exact parameter", () => {
    const p = MORPHO_MARKET.params;
    expect(keccak256(encodeAbiParameters(parseAbiParameters("address,address,address,address,uint256"),
      [p.loanToken,p.collateralToken,p.oracle,p.irm,p.lltv]))).toBe(MORPHO_MARKET.id);
  });
  it("approves exactly 50k and supplies exactly 50k for the Treasury in two zero-value calls", () => {
    const calls = treasurySupplyCalls();
    expect(calls.map(c => [c.to,c.value])).toEqual([[MORPHO_MARKET.params.loanToken,"0"],[MORPHO_MARKET.address,"0"]]);
    expect(decodeFunctionData({abi: MARKET_TOKEN_ABI,data: calls[0].data})).toEqual({functionName:"approve",args:[MORPHO_MARKET.address,50_000_000_000n]});
    expect(decodeFunctionData({abi: MORPHO_MARKET_ABI,data: calls[1].data})).toEqual({functionName:"supply",args:[MORPHO_MARKET.params,50_000_000_000n,0n,MORPHO_MARKET.treasury,"0x"]});
    expect(treasurySupplyDigest()).toMatch(/^0x[0-9a-f]{64}$/);
  });
  it.each([100_000_000_000n,250_000_000_000n])("rejects retired/whole-budget amounts %s", amount => {
    const calls = treasurySupplyCalls();
    calls[1].data = encodeFunctionData({abi:MORPHO_MARKET_ABI,functionName:"supply",args:[MORPHO_MARKET.params,amount,0n,MORPHO_MARKET.treasury,"0x"]});
    expect(() => assertTreasurySupplyCalls(calls)).toThrow(/differs/);
  });
  it.each(["recipient","oracle","target","value","extra","order","delegatecall"])("rejects %s drift", drift => {
    let calls: MarketCall[] = treasurySupplyCalls();
    if (drift === "recipient") calls[1].data = encodeFunctionData({abi:MORPHO_MARKET_ABI,functionName:"supply",args:[MORPHO_MARKET.params,MORPHO_MARKET.seed,0n,wallet,"0x"]});
    if (drift === "oracle") calls[1].data = encodeFunctionData({abi:MORPHO_MARKET_ABI,functionName:"supply",args:[{...MORPHO_MARKET.params,oracle:wallet},MORPHO_MARKET.seed,0n,MORPHO_MARKET.treasury,"0x"]});
    if (drift === "target") calls[0].to = wallet;
    if (drift === "value") calls[0].value = "1" as "0";
    if (drift === "extra") calls.push(calls[0]);
    if (drift === "order") calls = calls.reverse();
    if (drift === "delegatecall") Object.assign(calls[0],{operation:1});
    expect(() => assertTreasurySupplyCalls(calls)).toThrow(/differs/);
  });
  it.each(["supply","withdraw","borrow","repay","supplyCollateral","withdrawCollateral"] as const)("binds %s to the connected wallet", action => {
    const tx = marketAction(action,1n,wallet);
    expect(tx.address).toBe(MORPHO_MARKET.address);
    expect(tx.args[0]).toEqual(MORPHO_MARKET.params);
    expect(tx.args).toContain(wallet);
    if (["withdraw","withdrawCollateral","borrow"].includes(action)) expect(tx.args.slice(-2)).toEqual([wallet,wallet]);
  });
  it("supports closing by shares and refuses simultaneous asset/share inputs", () => {
    expect(marketAction("repay",0n,wallet,123n).args).toEqual([MORPHO_MARKET.params,0n,123n,wallet,"0x"]);
    expect(() => marketAction("repay",1n,wallet,1n)).toThrow(/exclusively/);
    expect(() => marketAction("supplyCollateral",0n,wallet,1n)).toThrow(/no shares/);
  });
});

describe("token precision and financial quotes", () => {
  it("uses the deployed 24-decimal sUSDfr precision and 6-decimal USDC precision", () => {
    expect(MORPHO_MARKET.collateralDecimals).toBe(24);
    expect(parseMarketAmount("1",MORPHO_MARKET.collateralDecimals)).toBe(10n ** 24n);
    expect(parseMarketAmount("50000",MORPHO_MARKET.loanDecimals)).toBe(50_000_000_000n);
    expect(parseMarketAmount("0.000000000000000000000001",24)).toBe(1n);
  });
  it.each(["1.0000001","1e6","-1","NaN","","0","1,000","1.","01","9".repeat(90)])("refuses invalid USDC %s without rounding", value => {
    expect(parseMarketAmount(value,6)).toBeNull();
  });
  it("values a whole sUSDfr in USDC using Morpho's 1e36 scale", () => {
    const m = {totalSupplyAssets:1_000_000n,totalSupplyShares:1_000_000_000_000n,totalBorrowAssets:0n,totalBorrowShares:0n,lastUpdate:1n,fee:0n};
    const p = marketPositionValues(m,{supplyShares:0n,borrowShares:0n,collateral:10n ** 24n},10n ** 18n);
    expect(p.collateralValue).toBe(1_000_000n);
    expect(p.liquidationDebt).toBe(860_000n);
    expect(p.borrowAvailable).toBe(860_000n);
  });
  it("includes accrued interest and fee-share dilution in lender and borrower views", () => {
    const m = {totalSupplyAssets:1_000_000n,totalSupplyShares:1_000_000_000_000n,totalBorrowAssets:500_000n,totalBorrowShares:500_000_000_000n,lastUpdate:100n,fee:100_000_000_000_000_000n};
    const accrued = accrueMarket(m,10n ** 12n,1_100n);
    expect(accrued.totalBorrowAssets).toBe(500_500n);
    expect(accrued.totalSupplyAssets).toBe(1_000_500n);
    // floor(50 * (1e12 + 1e6) / (1,000,500 - 50 + 1)) = 49,977,510 fee shares.
    expect(accrued.totalSupplyShares).toBe(1_000_049_977_510n);
    const v = marketPositionValues(accrued,{supplyShares:m.totalSupplyShares,borrowShares:m.totalBorrowShares,collateral:10n ** 24n},10n ** 18n);
    expect(v.supplied).toBe(1_000_449n);
    expect(v.borrowed).toBe(500_500n);
    expect(v.liquidity).toBe(500_000n);
  });
  it("rounds a non-integral debt up by one raw USDC unit", () => {
    const m = {totalSupplyAssets: 1000n, totalSupplyShares: 1_000_000n, totalBorrowAssets: 100n,
      totalBorrowShares: 1_000_000n, lastUpdate: 1n, fee: 0n};
    expect(marketPositionValues(m, {supplyShares: 0n, borrowShares: 1n, collateral: 0n}, 0n).borrowed).toBe(1n);
  });
  it("never enables a release gate implicitly", () => {
    expect(marketLaunch({})).toEqual({lending:false,borrowing:false,treasury:false});
    expect(marketLaunch({MORPHO_LENDING_ENABLED:"1",MORPHO_BORROWING_ENABLED:"TRUE"})).toEqual({lending:false,borrowing:false,treasury:false});
  });
});

describe("atomic Safe simulation", () => {
  it("accepts only the documented intentional success revert", () => {
    const success = `0x${"0".repeat(63)}1${"0".repeat(64)}` as const;
    expect(() => assertSafeSimulationResult(success)).not.toThrow();
    expect(() => assertSafeSimulationResult(`0x${"0".repeat(128)}`)).toThrow();
    expect(() => assertSafeSimulationResult(undefined)).toThrow();
    expect(() => assertSafeSimulationResult("0x08c379a0")).toThrow();
    expect(() => assertSafeSimulationResult(`${success}00`)).toThrow();
  });
  it("encodes only CALL operations and refuses an ETH transfer", () => {
    const calls = treasurySupplyCalls();
    const decoded = decodeFunctionData({abi: parseAbi(["function multiSend(bytes transactions)"]), data: encodeSafeCalls(calls)});
    const packed = decoded.args![0].slice(2);
    let offset = 0;
    for (const call of calls) {
      expect(packed.slice(offset,offset+2)).toBe("00");offset+=2;
      expect(`0x${packed.slice(offset,offset+40)}`.toLowerCase()).toBe(call.to.toLowerCase());offset+=40;
      expect(BigInt(`0x${packed.slice(offset,offset+64)}`)).toBe(0n);offset+=64;
      const length = Number(BigInt(`0x${packed.slice(offset,offset+64)}`));offset+=64;
      expect(`0x${packed.slice(offset,offset+length*2)}`).toBe(call.data);offset+=length*2;
    }
    expect(offset).toBe(packed.length);
    expect(() => encodeSafeCalls([{...treasurySupplyCalls()[0],value:"1" as "0"}])).toThrow(/zero-ETH/);
  });
});
