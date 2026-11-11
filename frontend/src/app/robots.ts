import type {MetadataRoute} from "next";
import {SITE_ORIGIN} from "@/lib/sitePages";

/**
 * Crawlers may read every page. The JSON endpoints under /api/ are not pages, and several of them
 * do real work per request, so they are excluded. The treasury liquidity screens are not listed
 * here: they carry their own noindex, which a crawler can only see if it is allowed to fetch them.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: {userAgent: "*", allow: "/", disallow: "/api/"},
    sitemap: `${SITE_ORIGIN}/sitemap.xml`,
  };
}
