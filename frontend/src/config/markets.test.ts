import {describe, expect, it} from "vitest";
import {USDFR_USDC_POOL} from "@/config/markets";
import {POOL_ID, V4_POOL_MANAGER} from "@/lib/uniswapV4Liquidity";

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
