import {afterEach, describe, expect, it} from "vitest";
import {GET} from "./route";

const original = {
  commit: process.env.VERCEL_GIT_COMMIT_SHA,
  environment: process.env.VERCEL_ENV,
  deploymentId: process.env.VERCEL_DEPLOYMENT_ID,
};

afterEach(() => {
  if (original.commit === undefined) delete process.env.VERCEL_GIT_COMMIT_SHA;
  else process.env.VERCEL_GIT_COMMIT_SHA = original.commit;
  if (original.environment === undefined) delete process.env.VERCEL_ENV;
  else process.env.VERCEL_ENV = original.environment;
  if (original.deploymentId === undefined) delete process.env.VERCEL_DEPLOYMENT_ID;
  else process.env.VERCEL_DEPLOYMENT_ID = original.deploymentId;
});

describe("served revision evidence", () => {
  it("returns the exact Vercel source commit in the body and header", async () => {
    const commit = "ab".repeat(20);
    process.env.VERCEL_GIT_COMMIT_SHA = commit;
    process.env.VERCEL_ENV = "production";
    process.env.VERCEL_DEPLOYMENT_ID = "dpl_fixture";

    const response = await GET();
    expect(response.status).toBe(200);
    expect(response.headers.get("x-frv-source-revision")).toBe(commit);
    await expect(response.json()).resolves.toEqual({
      ok: true,
      commit,
      environment: "production",
      deploymentId: "dpl_fixture",
    });
  });

  it.each([undefined, "", "not-a-commit", "ab".repeat(19)])(
    "fails closed when the deployment revision is %j",
    async (commit) => {
      if (commit === undefined) delete process.env.VERCEL_GIT_COMMIT_SHA;
      else process.env.VERCEL_GIT_COMMIT_SHA = commit;
      const response = await GET();
      expect(response.status).toBe(503);
      expect(response.headers.get("x-frv-source-revision")).toBeNull();
    },
  );
});
