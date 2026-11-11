import {handleRpcProxyRequest, rpcProxyMethodNotAllowed} from "@/lib/rpcProxy.server";

/**
 * The browser's JSON-RPC endpoint: a same-origin proxy so no provider key ships in the bundle.
 * Every rule lives in `@/lib/rpcProxy.server`; the per-IP rate limit is a Vercel WAF rule.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return handleRpcProxyRequest(request);
}

// Explicit, so Next.js neither answers OPTIONS itself (with an Allow list) nor derives HEAD.
export function GET(): Response {
  return rpcProxyMethodNotAllowed();
}
export function HEAD(): Response {
  return rpcProxyMethodNotAllowed();
}
export function OPTIONS(): Response {
  return rpcProxyMethodNotAllowed();
}
export function PUT(): Response {
  return rpcProxyMethodNotAllowed();
}
export function PATCH(): Response {
  return rpcProxyMethodNotAllowed();
}
export function DELETE(): Response {
  return rpcProxyMethodNotAllowed();
}
