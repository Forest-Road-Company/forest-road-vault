import {afterEach, describe, expect, it, vi} from "vitest";
import {GET} from "./route";
afterEach(() => vi.unstubAllEnvs());
describe("GET /api/morpho/launch", () => {
  it("closes every new-position gate by default and forbids caching", async () => {
    vi.stubEnv("MORPHO_LENDING_ENABLED", ""); vi.stubEnv("MORPHO_BORROWING_ENABLED", ""); vi.stubEnv("MORPHO_TREASURY_SUPPLY_ENABLED", "");
    const response = await GET();
    expect(await response.json()).toEqual({lending:false,borrowing:false,treasury:false});
    expect(response.headers.get("cache-control")).toBe("no-store");
  });
  it("keeps Treasury and public borrowing authority separate", async () => {
    vi.stubEnv("MORPHO_LENDING_ENABLED", "true"); vi.stubEnv("MORPHO_BORROWING_ENABLED", "false"); vi.stubEnv("MORPHO_TREASURY_SUPPLY_ENABLED", "false");
    expect(await (await GET()).json()).toEqual({lending:true,borrowing:false,treasury:false});
  });
});
