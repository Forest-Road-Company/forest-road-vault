import {describe, expect, it} from "vitest";
import {SUSDFR_USDC_POOL, USDFR_USDC_POOL} from "@/config/markets";
import {POOL_ID, V4_POOL_MANAGER} from "@/lib/uniswapV4Liquidity";
import {SUSDFR_POOL_ID} from "@/lib/uniswapV4SusdfrLiquidity";

/**
 * The site sends visitors to this pool to buy USDfr, so the link must name the pool derived from
 * the canonical pool key (USDC, mainnet USDfr, fee 375, tick spacing 4, no hooks), the same key
 * the treasury's liquidity route uses, and not a hand-copied ID that could name a look-alike.
 */
describe("USDfr/USDC market config", () => {
  it("names the pool derived from the canonical USDC/USDfr pool key", () => {
    expect(USDFR_USDC_POOL.id).toBe(POOL_ID);
    expect(USDFR_USDC_POOL.manager).toBe(V4_POOL_MANAGER);
  });

  it("links to that pool on Uniswap's Ethereum explorer", () => {
    expect(USDFR_USDC_POOL.url).toBe(`https://app.uniswap.org/explore/pools/ethereum/${POOL_ID}`);
  });
});

/**
 * The docs send sUSDfr holders to this pool as the alternative to the redemption queue, so the link must name the pool
 * derived from the canonical USDC/sUSDfr key (fee 375, tick spacing 4, no hooks) that the treasury's sUSDfr liquidity
 * route uses, not a hand-copied ID.
 */
describe("sUSDfr/USDC market config", () => {
  it("names the pool derived from the canonical USDC/sUSDfr pool key", () => {
    expect(SUSDFR_USDC_POOL.id).toBe(SUSDFR_POOL_ID);
    expect(SUSDFR_USDC_POOL.manager).toBe(V4_POOL_MANAGER);
  });

  it("links to that pool on Uniswap's Ethereum explorer", () => {
    expect(SUSDFR_USDC_POOL.url).toBe(`https://app.uniswap.org/explore/pools/ethereum/${SUSDFR_POOL_ID}`);
  });
});
