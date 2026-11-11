import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { sanitiseAnalyticsEvent } from "@/lib/analytics";

/*
 * Renders the real root layout down to Vercel's <Analytics>, with the layout's
 * other children stubbed: fonts are compiled by Next, not available here, and
 * the wallet providers and site chrome are irrelevant to this assertion.
 */
const ADDRESS = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"; // the EIP-55 test vector
const { Analytics, navigation } = vi.hoisted(() => ({
  Analytics: vi.fn((_props: object) => null),
  navigation: { pathname: "/", params: {} as Record<string, string | string[]> },
}));

vi.mock("@vercel/analytics/react", () => ({ Analytics }));
vi.mock("next/navigation", () => ({
  usePathname: () => navigation.pathname,
  useParams: () => navigation.params,
}));
vi.mock("next/font/google", () => {
  const font = () => ({ variable: "font-variable", className: "font-class" });
  return { Merriweather: font, Inter_Tight: font, Azeret_Mono: font };
});
vi.mock("react", async (importOriginal) => {
  // Next supplies ViewTransition from its own React build; the installed React has none.
  const actual = await importOriginal<typeof import("react")>();
  return { ...actual, ViewTransition: ({ children }: { children: ReactNode }) => children };
});
vi.mock("@/components/app/Providers", () => ({
  Providers: ({ children }: { children: ReactNode }) => children,
}));
vi.mock("@/components/site/AmbientBackdrop", () => ({ AmbientBackdrop: () => null }));
vi.mock("@/components/site/ViewportReplayController", () => ({ ViewportReplayController: () => null }));
vi.mock("@/components/site/SiteNav", () => ({ SiteNav: () => null }));
vi.mock("@/components/site/SiteFooter", () => ({ SiteFooter: () => null }));
vi.mock("@/components/site/TestnetBanner", () => ({ TestnetBanner: () => null }));
vi.mock("@/config/contracts", () => ({ IS_TESTNET: true }));

import RootLayout from "./layout";

afterEach(() => {
  Analytics.mockClear();
});

const renderLayout = () =>
  renderToStaticMarkup(
    <RootLayout>
      <p>page body</p>
    </RootLayout>,
  );

describe("root layout analytics", () => {
  it("renders Vercel Analytics exactly once, with the sanitiser and sanitised route and path", () => {
    // A URL that matches no route: empty params, and an address typed into the path.
    navigation.pathname = `/${ADDRESS}`;
    navigation.params = {};
    const html = renderLayout();

    expect(html).toContain("<p>page body</p>");
    expect(Analytics).toHaveBeenCalledTimes(1);
    const props = Analytics.mock.calls[0][0] as Record<string, unknown>;
    // Only what the Next wrapper passes: no mode, scriptSrc or endpoint that could send elsewhere.
    expect(Object.keys(props).sort()).toEqual(
      ["basePath", "beforeSend", "configString", "framework", "path", "route"],
    );
    expect(props.beforeSend).toBe(sanitiseAnalyticsEvent);
    expect(props).toMatchObject({ route: "/[id]", path: "/[id]", framework: "next" });
    expect(JSON.stringify(props).toLowerCase()).not.toContain(ADDRESS.slice(2).toLowerCase());
  });

  it("passes a content page's route pattern and path through unchanged", () => {
    navigation.pathname = "/docs/how-to";
    navigation.params = { slug: "how-to" };
    renderLayout();

    expect(Analytics).toHaveBeenCalledTimes(1);
    expect(Analytics.mock.calls[0][0]).toMatchObject({ route: "/docs/[slug]", path: "/docs/how-to" });
  });
});
