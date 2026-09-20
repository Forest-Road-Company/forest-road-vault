import {describe, expect, it} from "vitest";
import {walletMetadata} from "./walletMetadata";

describe("wallet metadata", () => {
  it("uses the requesting origin for both the application URL and icon", () => {
    expect(walletMetadata("https://forest-road-vault.vercel.app")).toEqual(expect.objectContaining({
      url: "https://forest-road-vault.vercel.app",
      icons: ["https://forest-road-vault.vercel.app/favicon.ico"],
    }));
  });

  it("normalizes away paths and refuses non-web schemes", () => {
    expect(walletMetadata("https://www.forestroadvault.com/curators").url).toBe("https://www.forestroadvault.com");
    expect(() => walletMetadata("javascript:alert(1)")).toThrow(/HTTP\(S\) origin/);
  });

  it("falls back safely when a sandboxed document has an opaque origin", () => {
    expect(walletMetadata("null")).toEqual(expect.objectContaining({
      url: "https://forestroadvault.com",
      icons: ["https://forestroadvault.com/favicon.ico"],
    }));
  });
});
