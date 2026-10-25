/**
 * Third-party markets the site points readers to.
 *
 * None of these is a Forest Road deployment, so none is in the deployment manifest and the
 * production build gate does not check them. Each is pinned once here and imported wherever the
 * site shows or links it, so a page and a card can never name different pools.
 */

import type {Address, Hex} from "viem";

const USDFR_USDC_POOL_ID = "0x72ef9130b1c7bd2daa49405e618b7ad27eb90e03c893629ba1d28a4562fc7b55";
const SUSDFR_USDC_POOL_ID = "0x1d8694445872d16931c729de06086ccbdc4089875ee73fb6119963a922c92d5a";

/**
 * The USDfr/USDC market: a third-party Uniswap v4 pool on Ethereum mainnet. It does not exist on
 * any testnet, so every consumer renders it on mainnet only. Verified on chain: USDC is
 * currency0, USDfr currency1, LP fee 375 (0.0375%), tick spacing 4, no hooks, on the canonical
 * v4 PoolManager.
 */
export const USDFR_USDC_POOL = {
  id: USDFR_USDC_POOL_ID,
  manager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  url: `https://app.uniswap.org/explore/pools/ethereum/${USDFR_USDC_POOL_ID}`,
} as const satisfies {id: Hex; manager: Address; url: string};

/**
 * The sUSDfr/USDC market: a third-party Uniswap v4 pool on Ethereum mainnet, where any address can sell sUSDfr for
 * USDC without the redemption queue. Mainnet only, like the USDfr pool. Verified on chain: USDC is currency0, sUSDfr
 * currency1, LP fee 375 (0.0375%), tick spacing 4, no hooks, on the canonical v4 PoolManager, initialized at block
 * 26,056,130; it is the pool the treasury's sUSDfr liquidity route seeded.
 */
export const SUSDFR_USDC_POOL = {
  id: SUSDFR_USDC_POOL_ID,
  manager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  url: `https://app.uniswap.org/explore/pools/ethereum/${SUSDFR_USDC_POOL_ID}`,
} as const satisfies {id: Hex; manager: Address; url: string};
