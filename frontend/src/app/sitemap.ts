import type {MetadataRoute} from "next";
import {publicSitePaths, SITE_ORIGIN} from "@/lib/sitePages";

/** Every public page, on the canonical origin. */
export default function sitemap(): MetadataRoute.Sitemap {
  return publicSitePaths().map((path) => ({url: path === "/" ? SITE_ORIGIN : `${SITE_ORIGIN}${path}`}));
}
