import {AUDITS} from "@/content/audits";
import {DOCS} from "@/content/docs";
import {SECTORS} from "@/lib/verticals";

/** The canonical public origin that robots.txt and sitemap.xml name. */
export const SITE_ORIGIN = "https://forestroadvault.com";

/**
 * The public pages, in reading order. Left out on purpose: the /verticals URLs (permanent
 * redirects to /sectors), the treasury liquidity screens under /liquidity (noindex) and /api/.
 */
export function publicSitePaths(): string[] {
  return [
    "/",
    "/how-it-works",
    "/sectors",
    ...SECTORS.map((sector) => `/sectors/${sector.slug}`),
    "/transparency",
    "/app",
    "/markets",
    "/points",
    "/curators",
    "/docs",
    ...DOCS.map((doc) => `/docs/${doc.slug}`),
    "/docs/addresses",
    "/docs/audit",
    ...AUDITS.map((audit) => `/docs/audit/${audit.slug}`),
    "/risk",
    "/legal",
    "/terms",
  ];
}
