import {computeRoute} from "@vercel/analytics";
import type {BeforeSendEvent} from "@vercel/analytics/react";

/**
 * Privacy filter for Vercel Web Analytics (owner request, 10 November 2026).
 *
 * The site counts page views and must never send a wallet address, transaction hash or other
 * identifier. A page view carries three values this module controls:
 *
 * - `path` and `route` (`dp`), which `SiteAnalytics` hands to the script from
 *   `analyticsPageView`. Both are sanitised here, because the script sends the route as given
 *   and never passes it through `beforeSend`.
 * - The URL, which the script passes through `beforeSend` (`sanitiseAnalyticsEvent`):
 *   - Only page views are sent. Any other event type is dropped, so a custom event (billed
 *     separately, and able to carry arbitrary data) cannot be added without changing this rule.
 *   - The URL keeps only its origin and path. The query string, the fragment and any
 *     credentials are removed, so `?address=0x...` or `#0x...` can never be sent.
 *   - A URL that cannot be parsed, or is not http(s), is dropped rather than sent as received.
 *
 * In all three, every path segment shaped like an identifier becomes `[id]`
 * (see `isIdentifierSegment`).
 *
 * Limit: the script also sends an external referrer with the first page view of a visit. That
 * value is whatever the referring site's own Referrer-Policy releases (usually its origin only),
 * and nothing here can change it.
 */

export const ANALYTICS_REDACTED_SEGMENT = "[id]";

/** 24 or more letters and digits with no separator: `0x` + 40 or 64 hex, bare hex, base58, base64. */
const LONG_ALPHANUMERIC_RUN = /[A-Za-z0-9]{24,}/;
/** A `0x` value of 4 or more hex digits, including truncated (`0x1234...`) or embedded forms. */
const HEX_VALUE = /(?:^|[^A-Za-z0-9])0x[0-9a-f]{4,}/i;
/** Maximal runs of the base64url alphabet, the characters a token is built from. */
const BASE64URL_RUN = /[A-Za-z0-9_-]+/g;
/** A readable slug: lower-case words and numbers joined by single hyphens. */
const READABLE_SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const HEX_AND_HYPHENS = /^[0-9a-f-]+$/i;
const TOKEN_LENGTH = 24;

/**
 * True when a decoded path segment looks like an address, hash, token or other identifier.
 *
 * A base64url run of 24 or more characters counts unless it reads as a slug, so long content
 * slugs such as `2026-07-30-adr-0031-composition-recheck` stay readable in the dashboard, while
 * mixed-case or underscore tokens, and hex split by hyphens (a UUID), are still replaced.
 */
export function isIdentifierSegment(segment: string): boolean {
  if (segment.includes("@")) return true; // an email address
  if (HEX_VALUE.test(segment)) return true;
  if (LONG_ALPHANUMERIC_RUN.test(segment)) return true;
  for (const run of segment.match(BASE64URL_RUN) ?? []) {
    if (run.length < TOKEN_LENGTH) continue;
    if (!READABLE_SLUG.test(run)) return true;
    if (HEX_AND_HYPHENS.test(run) && run.replaceAll("-", "").length >= TOKEN_LENGTH) return true;
  }
  return false;
}

function sanitiseSegment(segment: string): string {
  if (segment === "") return segment;
  let decoded: string;
  try {
    decoded = decodeURIComponent(segment);
  } catch {
    return ANALYTICS_REDACTED_SEGMENT; // malformed escapes cannot be checked, so they are not sent
  }
  return isIdentifierSegment(decoded) ? ANALYTICS_REDACTED_SEGMENT : segment;
}

/** Replaces every identifier-shaped segment of a URL path; separators and other segments stay. */
export function sanitiseAnalyticsPath(pathname: string): string {
  return pathname.split("/").map(sanitiseSegment).join("/");
}

/**
 * The `beforeSend` hook for `<Analytics />`. Returns the page view with a sanitised URL, or null
 * to drop the event. It never throws: anything unexpected is dropped.
 */
export function sanitiseAnalyticsEvent(event: unknown): BeforeSendEvent | null {
  try {
    if (typeof event !== "object" || event === null) return null;
    const {type, url} = event as {type?: unknown; url?: unknown};
    if (type !== "pageview" || typeof url !== "string") return null;
    const parsed = new URL(url);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
    return {type: "pageview", url: `${parsed.origin}${sanitiseAnalyticsPath(parsed.pathname)}`};
  } catch {
    return null;
  }
}

/** App Router route params, as `useParams()` returns them (an empty optional catch-all is undefined). */
export type AnalyticsRouteParams = Record<string, string | string[] | undefined>;

/**
 * The `route` and `path` that `SiteAnalytics` passes to Vercel's `<Analytics />`.
 *
 * Mirrors `useRoute` in `@vercel/analytics/next` (2.0.1): with no params there is no route, and
 * otherwise the package's own `computeRoute` replaces each param value in the pathname with
 * `[name]`, so `/docs/how-to` becomes `/docs/[slug]`. Two deliberate differences:
 *
 * - Both results pass through `sanitiseAnalyticsPath`. A URL that matches no route has empty
 *   params, so its route is the path as typed; an address typed there becomes `[id]` here
 *   instead of reaching the script's `dp` field.
 * - The wrapper falls back to query-string values when params are empty. That is not
 *   mirrored, so nothing from the query string can enter the route.
 *
 * A param with no value (an empty optional catch-all) is skipped: passed through, it would
 * make `computeRoute` throw internally and fall back to the whole raw pathname.
 */
export function analyticsPageView(
  pathname: string | null,
  params: AnalyticsRouteParams | null,
): {route: string | null; path: string | null} {
  if (!pathname) return {route: null, path: null};
  const path = sanitiseAnalyticsPath(pathname);
  if (!params) return {route: null, path};
  const valued = Object.fromEntries(
    Object.entries(params).filter((entry): entry is [string, string | string[]] => entry[1] !== undefined),
  );
  return {route: sanitiseAnalyticsPath(computeRoute(pathname, valued) ?? pathname), path};
}
