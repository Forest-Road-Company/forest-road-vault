import { cleanup, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sanitiseAnalyticsEvent } from "@/lib/analytics";
import { SiteAnalytics } from "./SiteAnalytics";

/*
 * Drives the REAL @vercel/analytics/react component. Before Vercel's script loads, the
 * package queues every call in window.vaq, so the queue is exactly what the script will
 * receive: the beforeSend hook, then one ["pageview", {route, path}] per page view, whose
 * route the script sends as `dp` and whose path becomes the URL that beforeSend sees.
 * Only the router hooks are stubbed; jsdom never fetches the injected script.
 */
const ADDRESS_A = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"; // the EIP-55 test vector
const ADDRESS_B = "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"; // another EIP-55 test vector
const navigation = vi.hoisted(() => ({ pathname: "/", params: {} as Record<string, string | string[]> }));

vi.mock("next/navigation", () => ({
  usePathname: () => navigation.pathname,
  useParams: () => navigation.params,
}));

type QueueEntry = [string, unknown?];
const analyticsWindow = window as unknown as { va?: unknown; vaq?: QueueEntry[]; vai?: unknown; vam?: unknown };

const resetAnalyticsGlobals = () => {
  delete analyticsWindow.va;
  delete analyticsWindow.vaq;
  delete analyticsWindow.vai;
  delete analyticsWindow.vam;
  document.head.querySelectorAll("script").forEach((script) => script.remove());
};

const pageViews = () => (analyticsWindow.vaq ?? []).filter(([command]) => command === "pageview").map(([, args]) => args);

const visit = (pathname: string, params: Record<string, string | string[]> = {}) => {
  navigation.pathname = pathname;
  navigation.params = params;
};

beforeEach(resetAnalyticsGlobals);
afterEach(() => {
  cleanup();
  resetAnalyticsGlobals();
});

describe("SiteAnalytics with the real Vercel component", () => {
  it("registers the sanitiser and turns off the script's own history tracking", () => {
    visit("/app");
    render(<SiteAnalytics />);

    expect(analyticsWindow.vaq?.filter(([command]) => command === "beforeSend")).toEqual([
      ["beforeSend", sanitiseAnalyticsEvent],
    ]);
    const scripts = document.head.querySelectorAll("script");
    expect(scripts).toHaveLength(1);
    // Set because a route is given: the script then never sends page views of its own.
    expect(scripts[0].dataset.disableAutoTrack).toBe("1");
    expect(scripts[0].dataset.sdkn).toBe("@vercel/analytics/next");
  });

  it("sends a sanitised route and path for an address typed into a path that matches no route", () => {
    visit(`/${ADDRESS_A}`);
    render(<SiteAnalytics />);

    expect(pageViews()).toEqual([{ route: "/[id]", path: "/[id]" }]);
    expect(JSON.stringify(analyticsWindow.vaq).toLowerCase()).not.toContain(ADDRESS_A.slice(2).toLowerCase());
  });

  it("sends exactly one page view per navigation: none missed, none doubled", () => {
    visit("/");
    const view = render(<SiteAnalytics />);
    expect(pageViews()).toEqual([{ route: "/", path: "/" }]);

    // Re-rendering the same page is not a navigation.
    view.rerender(<SiteAnalytics />);
    expect(pageViews()).toHaveLength(1);

    visit("/docs/how-to", { slug: "how-to" });
    view.rerender(<SiteAnalytics />);
    visit("/app");
    view.rerender(<SiteAnalytics />);
    // Two different addresses sanitise to identical values, and still count as two views.
    visit(`/${ADDRESS_A}`);
    view.rerender(<SiteAnalytics />);
    visit(`/${ADDRESS_B}`);
    view.rerender(<SiteAnalytics />);
    view.rerender(<SiteAnalytics />);

    expect(pageViews()).toEqual([
      { route: "/", path: "/" },
      { route: "/docs/[slug]", path: "/docs/how-to" },
      { route: "/app", path: "/app" },
      { route: "/[id]", path: "/[id]" },
      { route: "/[id]", path: "/[id]" },
    ]);
    // Remounting on navigation never injects a second script.
    expect(document.head.querySelectorAll("script")).toHaveLength(1);
  });
});
