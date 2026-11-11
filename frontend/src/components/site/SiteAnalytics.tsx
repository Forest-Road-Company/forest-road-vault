"use client";

import { Analytics } from "@vercel/analytics/react";
import { useParams, usePathname } from "next/navigation";
import { analyticsPageView, sanitiseAnalyticsEvent } from "@/lib/analytics";

/**
 * Vercel Web Analytics, page views only. A client component because the root layout is a
 * Server Component and cannot pass the `beforeSend` function across that boundary.
 *
 * This mirrors `@vercel/analytics/next` (2.0.1), which reads the pathname and params and hands
 * the React component a `route` and `path`, except that both are sanitised first: the script
 * sends `route` as `dp` without passing it through `beforeSend`, so an address typed into a
 * path that matches no route would otherwise be sent as typed. `framework`, `basePath` and
 * `configString` are what the Next wrapper passes; the last two are Vercel-managed variables,
 * unset unless Vercel sets them. The wrapper's Suspense boundary exists only for its
 * `useSearchParams()`, which this component does not use, so it is not needed here.
 *
 * Because `route` is given, the script's own history tracking is off, and a page view is sent
 * when the component mounts and whenever `route` or `path` changes. Keying on the raw pathname
 * remounts it on every navigation, so two consecutive pages that sanitise to the same values
 * (two different addresses typed into the same missing path) still count twice, never once.
 * The key never leaves the browser.
 *
 * In production the script and its endpoint are the site's own `/_vercel/insights/*`, which
 * the existing `script-src 'self'` and `connect-src 'self'` policy already allows.
 */
export function SiteAnalytics() {
  const pathname = usePathname();
  const params = useParams();
  const { route, path } = analyticsPageView(pathname, params);
  return (
    <Analytics
      key={pathname ?? ""}
      route={route}
      path={path}
      beforeSend={sanitiseAnalyticsEvent}
      framework="next"
      basePath={process.env.NEXT_PUBLIC_VERCEL_OBSERVABILITY_BASEPATH}
      configString={process.env.NEXT_PUBLIC_VERCEL_OBSERVABILITY_CLIENT_CONFIG}
    />
  );
}
