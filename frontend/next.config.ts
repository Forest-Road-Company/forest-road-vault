import {execFileSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import type { NextConfig } from "next";
import {PHASE_PRODUCTION_BUILD} from "next/constants.js";

const isDevelopment = process.env.NODE_ENV === "development";
const isLocalFork = process.env.NEXT_PUBLIC_CHAIN_ID === "31337";
const sourceRevision = process.env.VERCEL_GIT_COMMIT_SHA?.toLowerCase();
if (process.env.VERCEL === "1" && !/^[0-9a-f]{40}$/.test(sourceRevision ?? "")) {
  throw new Error("VERCEL_GIT_COMMIT_SHA must identify the exact source revision for a Vercel build");
}
/**
 * Production is built only from `main` through the Vercel Git integration (Forest Road decision,
 * 25 September 2026). A CLI upload (`vercel --prod`) ships whatever is on the uploader's disk,
 * possibly stale or uncommitted, and silently replaces what main deployed; four such uploads
 * reached production that day between Git deploys. The Git variables cannot tell the two apart:
 * the CLI reports the uploader's own checkout, and build variables can be set by hand. What an
 * upload cannot carry is the repository itself, because the CLI never uploads `.git` while an
 * integration build runs inside a clone. So a production build must run in a git checkout whose
 * HEAD is the reported commit on main. This is a guardrail against mistakes, not a security
 * boundary, and an instant rollback to an earlier deployment rebuilds nothing, so it stays open.
 */
export function evaluateDeploySource(
  env: Readonly<Record<string, string | undefined>>,
  checkoutHead: string | null,
): {enforced: boolean; allowed: boolean; summary: string} {
  const target = env.VERCEL_ENV || "unknown";
  const branch = env.VERCEL_GIT_COMMIT_REF || "none";
  const commit = (env.VERCEL_GIT_COMMIT_SHA ?? "").toLowerCase();
  const head = checkoutHead?.trim().toLowerCase() || null;
  const problems: string[] = [];
  if (branch !== "main") problems.push(`branch ${branch} is not main`);
  if (!/^[0-9a-f]{40}$/.test(commit)) problems.push("no commit SHA was reported");
  if (head === null) {
    problems.push("the build is not running in a git checkout, so it is an upload, not a Git integration build");
  } else if (head !== commit) {
    problems.push(`the checkout is at ${head.slice(0, 7)}, not the reported commit`);
  }
  const enforced = env.VERCEL_ENV === "production";
  const allowed = problems.length === 0;
  return {
    enforced,
    allowed,
    summary:
      `Deploy source gate: ${target} build of ${commit.slice(0, 7) || "an unreported commit"} on ${branch}: ` +
      `${allowed ? "built from git main" : problems.join("; ")}` +
      `${enforced ? "" : " (reported only; enforced for production)"}.`,
  };
}

function checkoutHead(): string | null {
  try {
    return execFileSync("git", ["-c", "safe.directory=*", "rev-parse", "HEAD"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

const localConnectSources = isDevelopment || isLocalFork
  ? " http://localhost:* http://127.0.0.1:* ws://localhost:* ws://127.0.0.1:*"
  : "";

const contentSecurityPolicy = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline'${isDevelopment ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https://api.web3modal.org https://secure.walletconnect.org",
  "font-src 'self' data: https://fonts.reown.com",
  "frame-src https://verify.walletconnect.com https://verify.walletconnect.org",
  // Public RPC and WalletConnect/Reown traffic is HTTPS/WSS only outside local-fork builds.
  `connect-src 'self' https: wss:${localConnectSources}`,
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  ...(isDevelopment || isLocalFork ? [] : ["upgrade-insecure-requests"]),
].join("; ");

const securityHeaders = [
  {key: "Content-Security-Policy", value: contentSecurityPolicy},
  {key: "Referrer-Policy", value: "strict-origin-when-cross-origin"},
  {key: "X-Content-Type-Options", value: "nosniff"},
  {key: "X-Frame-Options", value: "DENY"},
  {key: "Cross-Origin-Opener-Policy", value: "same-origin"},
  {key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()"},
  {key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload"},
  ...(sourceRevision ? [{key: "X-FRV-Source-Revision", value: sourceRevision}] : []),
] as const;

export default function createNextConfig(phase: string): NextConfig {
  if (phase === PHASE_PRODUCTION_BUILD) {
    // Any Vercel build, including a local `vercel build --prod`, reports where it came from;
    // only production refuses. Plain local `next build` runs have no VERCEL_ENV and skip it.
    if (process.env.VERCEL_ENV) {
      const source = evaluateDeploySource(process.env, checkoutHead());
      console.log(source.summary);
      if (source.enforced && !source.allowed) {
        throw new Error(
          `${source.summary} Production deploys come only from main through the Git integration: ` +
            "merge to main instead of running `vercel --prod`.",
        );
      }
    }
    // This runs from Next's own production-build phase, so `next build` cannot
    // bypass the receipt-bound deployment verifier by skipping npm lifecycle hooks.
    execFileSync(
      process.execPath,
      [
        fileURLToPath(
          new URL("../tools/frontend-env-from-manifest.mjs", import.meta.url),
        ),
        "--verify-build-env",
      ],
      {stdio: "inherit", env: process.env},
    );
  }

  return {
    poweredByHeader: false,
    turbopack: {
      root: process.cwd(),
    },
    async redirects() {
      return [
        // "Verticals" became "sectors" (Aug 2026 content review), and the
        // film-tax-credits class was folded into the broader media sector.
        {
          source: "/verticals/film-tax-credits",
          destination: "/sectors/media",
          permanent: true,
        },
        // Life sciences and real estate remain on-chain classes but are no longer
        // marketed as sectors, so /sectors/<slug> would 404. Both URLs are live today,
        // and a permanent redirect into a 404 is cached by the browser forever. Send
        // them to the sector index instead. MUST precede the generic rule below.
        {
          source: "/verticals/life-sciences",
          destination: "/sectors",
          permanent: true,
        },
        {
          source: "/verticals/real-estate",
          destination: "/sectors",
          permanent: true,
        },
        {
          source: "/verticals/:slug",
          destination: "/sectors/:slug",
          permanent: true,
        },
        {
          source: "/verticals",
          destination: "/sectors",
          permanent: true,
        },
      ];
    },
    async headers() {
      return [
        {
          source: "/(.*)",
          headers: [...securityHeaders],
        },
      ];
    },
  };
}
