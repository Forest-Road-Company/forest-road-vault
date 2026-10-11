import type {Address} from "viem";

/**
 * Who the public points leaderboard leaves out of its ranks (Forest Road direction, 11 October
 * 2026). Mainnet only: the leaderboard is off on a testnet build.
 *
 * Forest Road's own wallets are not ranked; their points are summed into one labelled line under
 * the table, so the board still adds up. Forest Road chose not to publish which wallets those are,
 * so they are server-only configuration (`forestRoadWallets` in `pointsLeaderboard.server.ts`),
 * never in source or the client bundle. Every other address ranks as an ordinary participant.
 */

/**
 * Contracts that hold sUSDfr or USDfr on behalf of many people. The PointsModule credits the
 * contract itself, so its points are no one's personal balance: each is shown as its own line under
 * the table, never ranked. Pendle and Morpho positions are credited to their owners instead, as
 * computed points that do rank.
 */
export const POINTS_VENUES: readonly {key: string; label: string; address: Address; note: string}[] = Object.freeze([
  {
    key: "uniswap-v4",
    label: "Uniswap v4 PoolManager",
    address: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    note: "Liquidity in Uniswap v4 pools. The PoolManager holds every pool's tokens, so its points are not attributed to individual liquidity providers.",
  },
  {
    key: "uniswap-v2-susdfr",
    label: "sUSDfr/USDC Uniswap v2 pair",
    address: "0xA3A922Ecfa8cb41154AcA336462c822F16FEfab4",
    note: "Liquidity in the Uniswap v2 pair. Its points are not attributed to individual liquidity providers.",
  },
  {
    key: "pendle-sy-susdfr",
    label: "Pendle SY-sUSDfr",
    address: "0xa6E23d9A6F7F4FB5EC305b50b29418dD119Eb692",
    note: "sUSDfr held through Pendle. Its YT holders, LPs and direct SY holders are credited as Pendle points in the table; PT earns nothing.",
  },
  {
    key: "pendle-sy-usdfr",
    label: "Pendle SY-USDfr",
    address: "0xef10D4eD86E12B57f1fA178D3AB7BFd5cC2F97DF",
    note: "USDfr held through Pendle. Its YT holders, LPs and direct SY holders are credited as Pendle points in the table; PT earns nothing.",
  },
  {
    key: "morpho-blue",
    label: "Morpho Blue",
    address: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    note: "sUSDfr posted as collateral on Morpho. Each owner of that collateral is credited with Morpho points in the table.",
  },
]);

/** How many ranked rows one answer carries; the count of every ranked wallet is reported beside them. */
export const LEADERBOARD_MAX_ROWS = 1_000;
