# ADR-0048: Frontend same-origin `/api/rpc` proxy and Vercel Blob CAS persistence

**Status:** Accepted and deployed in production (`https://forestroadvault.com`, hardened November
2026 across 7 audit rounds and 2 mobile remediation passes).

**Date:** 2026-11-24 (recorded 2026-11-25)

## Context

Exposing third-party RPC provider API keys in `NEXT_PUBLIC_*` client environment variables leaks
credentials into static browser bundles and enables quota abuse. Concurrently, serverless cold
starts computing historical transparency time-series, Morpho collateral points and leaderboard
rankings directly from archive RPC logs risked 503 timeouts and concurrent cache corruption.

## Decision

1. **Same-origin JSON-RPC proxy (`/api/rpc`).** Production browser reads route exclusively
   through `NEXT_PUBLIC_RPC_URL=/api/rpc`, backed by server-only `RPC_PROXY_UPSTREAM_URL`. The
   route enforces a strict JSON-RPC method allowlist, mainnet `eth_getLogs` contract allowlist,
   4-full-block scan cap and request-body limits. `scripts/check-bundle-rpc-secrets.mjs --expect-proxy`
   fails the build if any upstream RPC key appears in compiled client assets.
2. **Private Vercel Blob persistence with CAS locking.** Server-side transparency history
   (`/api/transparency/history`), Morpho/Pendle points snapshots and the points leaderboard persist
   canonical snapshots in private Vercel Blob (`BLOB_READ_WRITE_TOKEN`) using compare-and-swap
   concurrency guards, bounded retries and fail-closed integrity checks (never silently returning
   fabricated or stale-mismatched totals).
3. **Explicit browser vs CDN cache control.** Cached API routes emit explicit `Cache-Control`,
   `CDN-Cache-Control` and `Vercel-CDN-Cache-Control` headers so Vercel Edge caches warm responses
   reliably without stripping browser freshness policy.
4. **Build-time revision binding.** Every production deploy embeds `VERCEL_GIT_COMMIT_SHA` in
   `/api/revision` so external observers can verify the exact served commit against the public
   repository.

## Consequences

- Zero RPC credentials exist in client JavaScript bundles; warm API responses serve in tens of
  milliseconds from Edge/Blob caches with verified on-chain reconciliation.
- Production deployments require `RPC_PROXY_UPSTREAM_URL`, `BLOB_READ_WRITE_TOKEN`, `CRON_SECRET`,
  and `VERCEL_GIT_COMMIT_SHA` to be configured and verified after promotion.
