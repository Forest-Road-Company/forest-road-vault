export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SHA = /^[0-9a-f]{40}$/;

export async function GET() {
  const commit = process.env.VERCEL_GIT_COMMIT_SHA?.toLowerCase() ?? "";
  if (!SHA.test(commit)) {
    return Response.json(
      {ok: false, error: "Source revision unavailable."},
      {status: 503, headers: {"cache-control": "no-store"}},
    );
  }
  return Response.json(
    {
      ok: true,
      commit,
      environment: process.env.VERCEL_ENV ?? null,
      deploymentId: process.env.VERCEL_DEPLOYMENT_ID ?? null,
    },
    {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "x-frv-source-revision": commit,
      },
    },
  );
}
