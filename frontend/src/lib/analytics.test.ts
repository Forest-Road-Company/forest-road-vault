import type {BeforeSend} from "@vercel/analytics/react";
import {describe, expect, it} from "vitest";
import {AUDITS} from "@/content/audits";
import {DOCS} from "@/content/docs";
import {SECTORS, VERTICALS} from "@/lib/verticals";
import {
  ANALYTICS_REDACTED_SEGMENT,
  analyticsPageView,
  isIdentifierSegment,
  sanitiseAnalyticsEvent,
  sanitiseAnalyticsPath,
} from "./analytics";

const ORIGIN = "https://forestroadvault.com";
/** Synthetic values only: the EIP-55 test vector, a patterned hash and the wrapped-SOL mint. */
const ADDRESS = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
const TX_HASH = `0x${"0123456789abcdef".repeat(4)}`;
const SOLANA_ADDRESS = "So11111111111111111111111111111111111111112";
const UUID = "123e4567-e89b-12d3-a456-426614174000";
const BASE64URL_TOKEN = "dpl_Fq2x-9Lb3kZ0mN7pR4tV";

const pageview = (url: string) => ({type: "pageview" as const, url});
const sentUrl = (url: string) => sanitiseAnalyticsEvent(pageview(url))?.url;

// The hook is passed straight to <Analytics beforeSend>; this fails to compile if its type drifts.
const hook: BeforeSend = sanitiseAnalyticsEvent;

describe("analytics sanitiser: what is removed", () => {
  it("drops the query string and the fragment", () => {
    expect(sentUrl(`${ORIGIN}/points?address=${ADDRESS}&ref=abc#${TX_HASH}`)).toBe(`${ORIGIN}/points`);
    expect(sentUrl(`${ORIGIN}/app?wallet=${ADDRESS}`)).toBe(`${ORIGIN}/app`);
    expect(sentUrl(`${ORIGIN}/markets#position-${ADDRESS}`)).toBe(`${ORIGIN}/markets`);
    expect(sentUrl(`${ORIGIN}/?ref=${ADDRESS}`)).toBe(`${ORIGIN}/`);
    expect(sentUrl(`${ORIGIN}/transparency?`)).toBe(`${ORIGIN}/transparency`);
    expect(sentUrl(`${ORIGIN}/transparency#`)).toBe(`${ORIGIN}/transparency`);
  });

  it("drops credentials embedded in the URL", () => {
    expect(sentUrl(`https://user:secret@forestroadvault.com/app`)).toBe(`${ORIGIN}/app`);
  });

  it("replaces a wallet address segment in any case and position", () => {
    expect(sentUrl(`${ORIGIN}/points/${ADDRESS}`)).toBe(`${ORIGIN}/points/[id]`);
    expect(sentUrl(`${ORIGIN}/${ADDRESS.toLowerCase()}`)).toBe(`${ORIGIN}/[id]`);
    expect(sentUrl(`${ORIGIN}/app/${ADDRESS}/positions`)).toBe(`${ORIGIN}/app/[id]/positions`);
    expect(sentUrl(`${ORIGIN}/app/${ADDRESS.slice(2)}`)).toBe(`${ORIGIN}/app/[id]`);
    expect(sentUrl(`${ORIGIN}/app/wallet-${ADDRESS}`)).toBe(`${ORIGIN}/app/[id]`);
  });

  it("replaces a transaction hash segment", () => {
    expect(sentUrl(`${ORIGIN}/transparency/${TX_HASH}`)).toBe(`${ORIGIN}/transparency/[id]`);
    expect(sentUrl(`${ORIGIN}/tx/${TX_HASH.slice(2).toUpperCase()}/`)).toBe(`${ORIGIN}/tx/[id]/`);
  });

  it("replaces truncated addresses, long ids, tokens, UUIDs and email addresses", () => {
    expect(sentUrl(`${ORIGIN}/points/0x5aAe...eAed`)).toBe(`${ORIGIN}/points/[id]`);
    expect(sentUrl(`${ORIGIN}/points/${SOLANA_ADDRESS}`)).toBe(`${ORIGIN}/points/[id]`);
    expect(sentUrl(`${ORIGIN}/r/${BASE64URL_TOKEN}`)).toBe(`${ORIGIN}/r/[id]`);
    expect(sentUrl(`${ORIGIN}/r/${UUID}`)).toBe(`${ORIGIN}/r/[id]`);
    expect(sentUrl(`${ORIGIN}/r/${UUID.toUpperCase()}`)).toBe(`${ORIGIN}/r/[id]`);
    expect(sentUrl(`${ORIGIN}/u/someone@example.com`)).toBe(`${ORIGIN}/u/[id]`);
    expect(sentUrl(`${ORIGIN}/a/${"a".repeat(24)}`)).toBe(`${ORIGIN}/a/[id]`);
  });

  it("checks the decoded segment, so percent-encoding does not hide an identifier", () => {
    const encoded = [...ADDRESS].map((c) => `%${c.charCodeAt(0).toString(16)}`).join("");
    expect(sentUrl(`${ORIGIN}/points/${encoded}`)).toBe(`${ORIGIN}/points/[id]`);
    expect(sentUrl(`${ORIGIN}/u/someone%40example.com`)).toBe(`${ORIGIN}/u/[id]`);
    // A malformed escape cannot be decoded or checked, so it is not sent.
    expect(sentUrl(`${ORIGIN}/points/%E0%A4%A`)).toBe(`${ORIGIN}/points/[id]`);
  });

  it("replaces every identifier segment, not only the first", () => {
    expect(sanitiseAnalyticsPath(`/a/${ADDRESS}/b/${TX_HASH}/${UUID}`)).toBe("/a/[id]/b/[id]/[id]");
  });
});

describe("analytics sanitiser: what is kept", () => {
  it.each([
    "/",
    "/app",
    "/markets",
    "/transparency",
    "/points",
    "/curators",
    "/how-it-works",
    "/legal",
    "/terms",
    "/risk",
    "/liquidity",
    "/liquidity/susdfr",
    "/liquidity/susdfr-v2",
    "/docs",
    "/docs/addresses",
    "/docs/audit",
    "/sectors",
    "/sectors/digital-assets",
    "/docs/audit/2026-07-30-adr-0031-instant-recognition-recheck",
    "/docs/audit/2026-08-16-mainnet-v1-full-audit",
    "/docs/audit/2026-09-13-corrovera-dual-chain-ensemble",
  ])("leaves the site path %s unchanged", (path) => {
    expect(sentUrl(`${ORIGIN}${path}`)).toBe(`${ORIGIN}${path}`);
  });

  it("leaves every generated content page unchanged, so the dashboard can tell them apart", () => {
    const paths = [
      ...DOCS.map((d) => `/docs/${d.slug}`),
      ...AUDITS.map((a) => `/docs/audit/${a.slug}`),
      ...SECTORS.map((s) => `/sectors/${s.slug}`),
      ...VERTICALS.map((v) => `/verticals/${v.slug}`),
    ];
    expect(paths.length).toBeGreaterThan(20);
    for (const path of paths) expect(sanitiseAnalyticsPath(path)).toBe(path);
  });

  it("keeps the origin, including a preview host and a local port", () => {
    expect(sentUrl("https://forest-road-vault-git-feat-x-team.vercel.app/app")).toBe(
      "https://forest-road-vault-git-feat-x-team.vercel.app/app",
    );
    expect(sentUrl("http://localhost:3000/markets?x=1")).toBe("http://localhost:3000/markets");
  });

  it("keeps short and readable segments that only resemble identifiers", () => {
    for (const segment of ["0x12", "10x-returns", "susdfr-v2", "a".repeat(23), "2026-09-20"]) {
      expect(isIdentifierSegment(segment)).toBe(false);
    }
    expect(ANALYTICS_REDACTED_SEGMENT).toBe("[id]");
  });

  it("returns a new page-view event with only the type and the sanitised URL", () => {
    const event = {type: "pageview" as const, url: `${ORIGIN}/points?a=1`, extra: ADDRESS};
    const result = hook(event);
    expect(result).toEqual({type: "pageview", url: `${ORIGIN}/points`});
    expect(result).not.toBe(event);
    expect(event.url).toBe(`${ORIGIN}/points?a=1`);
  });
});

describe("analytics sanitiser: what is dropped", () => {
  it("drops every non-page-view event, so no custom event is ever sent", () => {
    expect(sanitiseAnalyticsEvent({type: "event", url: `${ORIGIN}/app`})).toBeNull();
  });

  it.each([
    ["undefined", undefined],
    ["null", null],
    ["a string", `${ORIGIN}/app`],
    ["a number", 42],
    ["an array", [`${ORIGIN}/app`]],
    ["an empty object", {}],
    ["a missing url", {type: "pageview"}],
    ["a non-string url", {type: "pageview", url: 42}],
    ["a relative url", {type: "pageview", url: "/app"}],
    ["an unparseable url", {type: "pageview", url: "http://[::1"}],
    ["an empty url", {type: "pageview", url: ""}],
    ["a javascript: url", {type: "pageview", url: "javascript:alert(1)"}],
    ["a data: url", {type: "pageview", url: "data:text/html,hi"}],
    ["a file: url", {type: "pageview", url: "file:///etc/passwd"}],
  ])("returns null without throwing for %s", (_label, input) => {
    expect(() => sanitiseAnalyticsEvent(input)).not.toThrow();
    expect(sanitiseAnalyticsEvent(input)).toBeNull();
  });

  it("returns null without throwing when reading the event throws", () => {
    const hostile = {
      get type(): string {
        throw new Error("getter");
      },
    };
    expect(sanitiseAnalyticsEvent(hostile)).toBeNull();
  });
});

describe("analytics route and path (the script's dp field and page path)", () => {
  // useParams() on a URL that matches no route is an empty object, so the route is the path as typed.
  it("sends an address typed into a path that matches no route as /[id] in both", () => {
    expect(analyticsPageView(`/${ADDRESS}`, {})).toEqual({route: "/[id]", path: "/[id]"});
    expect(analyticsPageView(`/${ADDRESS.toLowerCase()}`, {})).toEqual({route: "/[id]", path: "/[id]"});
    expect(analyticsPageView(`/app/${ADDRESS}/x`, {})).toEqual({route: "/app/[id]/x", path: "/app/[id]/x"});
    expect(analyticsPageView(`/tx/${TX_HASH}`, {})).toEqual({route: "/tx/[id]", path: "/tx/[id]"});
  });

  it("gives a content page its route pattern and keeps its path", () => {
    for (const {slug} of DOCS) {
      expect(analyticsPageView(`/docs/${slug}`, {slug})).toEqual({route: "/docs/[slug]", path: `/docs/${slug}`});
    }
    for (const {slug} of AUDITS) {
      expect(analyticsPageView(`/docs/audit/${slug}`, {slug})).toEqual({
        route: "/docs/audit/[slug]",
        path: `/docs/audit/${slug}`,
      });
    }
    for (const {slug} of SECTORS) {
      expect(analyticsPageView(`/sectors/${slug}`, {slug})).toEqual({route: "/sectors/[slug]", path: `/sectors/${slug}`});
    }
  });

  it("keeps an identifier typed into a slug route out of both", () => {
    expect(analyticsPageView(`/docs/${ADDRESS}`, {slug: ADDRESS})).toEqual({route: "/docs/[slug]", path: "/docs/[id]"});
  });

  it.each(["/", "/app", "/markets", "/transparency", "/points", "/docs/addresses"])(
    "leaves the static page %s unchanged in both",
    (path) => {
      expect(analyticsPageView(path, {})).toEqual({route: path, path});
    },
  );

  it("replaces a catch-all param with the package's [...name] form", () => {
    expect(analyticsPageView("/guide/a/b", {parts: ["a", "b"]})).toEqual({route: "/guide/[...parts]", path: "/guide/a/b"});
  });

  it("skips an empty optional catch-all instead of falling back to the raw pathname", () => {
    expect(analyticsPageView("/guide", {parts: undefined})).toEqual({route: "/guide", path: "/guide"});
    expect(analyticsPageView("/docs/how-to", {slug: "how-to", rest: undefined})).toEqual({
      route: "/docs/[slug]",
      path: "/docs/how-to",
    });
  });

  it("sends no route when there are no params, and nothing when there is no pathname, as the Next wrapper does", () => {
    expect(analyticsPageView("/app", null)).toEqual({route: null, path: "/app"});
    expect(analyticsPageView(null, {})).toEqual({route: null, path: null});
    expect(analyticsPageView("", {})).toEqual({route: null, path: null});
  });
});
