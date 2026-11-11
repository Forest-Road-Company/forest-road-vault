import {describe, expect, it} from "vitest";
import robots from "@/app/robots";
import sitemap from "@/app/sitemap";
import {AUDITS} from "@/content/audits";
import {DOCS} from "@/content/docs";
import {SECTORS} from "@/lib/verticals";

describe("robots.txt", () => {
  it("allows the site, keeps crawlers out of /api/ and names the sitemap", () => {
    expect(robots()).toEqual({
      rules: {userAgent: "*", allow: "/", disallow: "/api/"},
      sitemap: "https://forestroadvault.com/sitemap.xml",
    });
  });
});

describe("sitemap.xml", () => {
  const urls = sitemap().map((entry) => entry.url);

  it("lists every URL once, on the canonical origin", () => {
    expect(new Set(urls).size).toBe(urls.length);
    for (const url of urls) expect(url.startsWith("https://forestroadvault.com")).toBe(true);
    expect(urls[0]).toBe("https://forestroadvault.com");
  });

  it("includes the public pages, each sector, document and audit report", () => {
    for (const path of ["/how-it-works", "/sectors", "/transparency", "/app", "/markets", "/points", "/curators", "/docs", "/docs/addresses", "/docs/audit", "/risk", "/legal", "/terms"]) {
      expect(urls).toContain(`https://forestroadvault.com${path}`);
    }
    for (const sector of SECTORS) expect(urls).toContain(`https://forestroadvault.com/sectors/${sector.slug}`);
    for (const doc of DOCS) expect(urls).toContain(`https://forestroadvault.com/docs/${doc.slug}`);
    for (const audit of AUDITS) expect(urls).toContain(`https://forestroadvault.com/docs/audit/${audit.slug}`);
  });

  it("leaves out redirects, the noindex treasury screens and the API", () => {
    for (const url of urls) {
      expect(url).not.toMatch(/\/(verticals|liquidity|api)(\/|$)/);
    }
  });
});
