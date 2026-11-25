# Forest Road Vault website

This Next.js (App Router) application is the depositor, borrower/lender, curator, points and
transparency interface plus the public protocol documentation for **Forest Road Vault**
(`https://forestroadvault.com`).

Ethereum V2 is live on mainnet. Minting USDfr and redeeming it directly for USDC require a
KYC-verified address; holding, transferring, staking (`sUSDfr`), Uniswap v4 swaps (via the
in-app Buy tab), Morpho Blue lending/borrowing (`/markets`) and points tracking (`/points`) are
open to any address that is not sanctions- or jurisdiction-blocked.

The site derives every mainnet contract address and deployment identity from required build
variables (`tools/frontend-env-from-manifest.mjs --verify-build-env`) and refuses an incomplete
mainnet configuration. Current public documentation lives in `src/content/docs/`. Keep
`src/content/docs/status.md`, `src/app/docs/addresses/page.tsx` and the audit register
(`src/content/audits.ts`) synchronized with every release. The USD 100 million Ethereum value is a
bootstrap concentration floor for credit exposure, not a deposit cap.

## Key Routes

- `/` — Protocol overview and live on-chain telemetry
- `/app` — Deposit/Mint, Buy (Uniswap v4), Stake (`sUSDfr`), Redeem (instant par/sub-par USDfr
  or FIFO sUSDfr queue) and position tracking
- `/markets` — Live Ethereum Morpho Blue USDC/sUSDfr lending and borrowing surface (with Safe
  multisig batching support), gated by server-evaluated launch switches (`/api/morpho/launch`)
- `/curators` — First-loss curator programme, live Ethereum `CuratorModule` actions and Solana
  devnet curator-vault preview
- `/points` — Participation points across on-chain balances, Morpho collateral and Pendle SY/YT/LP
- `/transparency` — Live on-chain solvency, loan book, loss cascade, redemption queue and
  historical charts (`/api/transparency/history`)
- `/docs/*` — Public protocol documentation, deployed addresses and dated audit register
- `/liquidity`, `/liquidity/susdfr`, `/liquidity/susdfr-v2` — Internal (`noindex`) Treasury
  Uniswap execution and verification surfaces

## Local Development

```bash
npm ci
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). The landing page entry point is
`src/app/page.tsx`, and the application loads `Merriweather`, `Inter_Tight` and `Azeret_Mono`
via `next/font/google` in `src/app/layout.tsx`.

## Verification Gates

Run the full local suite from `frontend/` before opening a pull request:

```bash
npx tsc --noEmit
npm run lint
npm run test:logic          # node audit-logic-test.mts
npm run test:sync           # node contract-ui-sync-test.mts
npm run test:render         # vitest run (use --maxWorkers=2 when parallelized)
npm run test:mutations      # 76 compiled mutation controls (run sequentially; mutates files during run)
npm run test:server         # server route tests (points-route-server-test.mts + rpc-route-server-test.mts)
npm run build               # next build --webpack + check-bundle-rpc-secrets.mjs
```

> **Sequential rule:** Do not run `npm run test:render` or `npm run build` concurrently with
> `npm run test:mutations`, because `scripts/mutation-controls.mjs` temporarily mutates source
> files in place and restores them on completion.

## Production Environment & Vercel Deployment

Production builds (`next build --webpack`) require Vercel's 40-character `VERCEL_GIT_COMMIT_SHA`
and run `scripts/check-bundle-rpc-secrets.mjs` to ensure zero upstream RPC credentials leak into
client bundles:

- **Same-origin RPC proxy:** Browser JSON-RPC traffic routes through `/api/rpc` using server-only
  `RPC_PROXY_UPSTREAM_URL` (with `NEXT_PUBLIC_RPC_URL=/api/rpc` in production). Verify no
  credentials are embedded with `node scripts/check-bundle-rpc-secrets.mjs --expect-proxy`.
- **Persistence & caching:** Private Vercel Blob (`BLOB_READ_WRITE_TOKEN`) backs server-side
  transparency history, Morpho/Pendle points snapshots, leaderboard caches (with CAS locking) and
  curator rate-limit gates.
- **Morpho market switches:** `MORPHO_LENDING_ENABLED`, `MORPHO_BORROWING_ENABLED` and
  `MORPHO_TREASURY_SUPPLY_ENABLED` control `/markets` actions via `/api/morpho/launch`.
- **Hourly cleanup cron & WAF:** `CRON_SECRET` authorizes the **hourly** cron in `vercel.json`
  (`0 * * * *` → `/api/internal/curator-rate-cleanup`), which deletes only expired
  `curators-rate/` Blob objects alongside a fixed-window WAF rule on
  `POST /api/curators/interest` (max 16 requests per source IP per 600 seconds).
- **WalletConnect / Reown origins:** The Reown project must allow both custom domains and the
  stable Vercel production domain; `prebuild` verifies the public origin policy.

After promoting a production deployment, bind the served site to the exact reviewed commit:

```bash
node tools/verify-frontend-revision.mjs \
  --url https://forestroadvault.com \
  --commit <40-character-final-commit>
```
