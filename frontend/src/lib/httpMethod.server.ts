/**
 * Shared 405 Method Not Allowed response for API route handlers so unmapped verbs
 * (including OPTIONS, PUT, PATCH, DELETE) always return an accurate `Allow` header
 * and `Cache-Control: no-store` instead of Next.js auto-implemented fallbacks.
 */
export function methodNotAllowed(allow: "GET" | "POST"): Response {
  return Response.json(
    {ok: false, error: "Method not allowed."},
    {status: 405, headers: {allow, "cache-control": "no-store"}},
  );
}
