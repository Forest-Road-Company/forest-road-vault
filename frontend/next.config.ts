import {execFileSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import type { NextConfig } from "next";
import {PHASE_PRODUCTION_BUILD} from "next/constants.js";

const isDevelopment = process.env.NODE_ENV === "development";
const isLocalFork = process.env.NEXT_PUBLIC_CHAIN_ID === "31337";
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
] as const;

export default function createNextConfig(phase: string): NextConfig {
  if (phase === PHASE_PRODUCTION_BUILD) {
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
