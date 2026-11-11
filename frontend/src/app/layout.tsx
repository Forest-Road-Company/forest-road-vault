import type { Metadata } from "next";
import { ViewTransition } from "react";
import { Merriweather, Inter_Tight, Azeret_Mono } from "next/font/google";
import "./globals.css";
import { AmbientBackdrop } from "@/components/site/AmbientBackdrop";
import { ViewportReplayController } from "@/components/site/ViewportReplayController";
import { SiteAnalytics } from "@/components/site/SiteAnalytics";
import { SiteNav } from "@/components/site/SiteNav";
import { SiteFooter } from "@/components/site/SiteFooter";
import { TestnetBanner } from "@/components/site/TestnetBanner";
import { Providers } from "@/components/app/Providers";
import { IS_TESTNET } from "@/config/contracts";
import { pageMetadata } from "@/lib/shareCards";

/* The parent brand's faces, read off forestroad.com: Merriweather 600/700
   sets every headline there (its italic is the emphasis device), and Inter
   Tight carries nav and UI. Azeret Mono is reserved for on-chain strings such as
   addresses, hashes and calldata, where mono is a legibility requirement
   rather than a stylistic choice. */
const merriweather = Merriweather({
  variable: "--font-merriweather",
  subsets: ["latin"],
  style: ["normal", "italic"],
  display: "swap",
});

const interTight = Inter_Tight({
  variable: "--font-inter-tight",
  subsets: ["latin"],
  style: ["normal", "italic"],
  display: "swap",
});

const azeretMono = Azeret_Mono({
  variable: "--font-azeret",
  subsets: ["latin"],
  display: "swap",
});

const SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL?.trim() ||
  (process.env.VERCEL_ENV === "preview"
    ? "https://forest-road-vault-design-staging.vercel.app"
    : "https://forestroadvault.com");

/* The homepage's own title, description and share text. Every other route sets its own (see
   lib/shareCards.ts), because a page that set only a description would otherwise inherit these. */
export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  ...pageMetadata({
    title: "Forest Road Vault | specialty finance credit, on-chain",
    description: `Forest Road Vault records specialty-finance credit across Media, Renewables, and Digital Assets on-chain. USDfr backing includes reserves and deployed loan principal; sUSDfr reflects net book performance after fees and losses.${IS_TESTNET ? " Testnet preview." : ""}`,
    socialDescription:
      "The Vault's on-chain credit book: USDfr backing includes reserves and deployed loan principal; sUSDfr reflects net performance after fees and losses.",
  }),
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${merriweather.variable} ${interTight.variable} ${azeretMono.variable} h-full antialiased`}
    >
      <body className="min-h-full">
        <AmbientBackdrop />
        <ViewportReplayController />
        <Providers>
          <div className="site-stack flex min-h-dvh flex-col">
            <TestnetBanner />
            <SiteNav />
            <ViewTransition name="page-content" default="page-crossfade">
              <main className="site-main flex-1">{children}</main>
            </ViewTransition>
            <SiteFooter />
          </div>
        </Providers>
        <SiteAnalytics />
      </body>
    </html>
  );
}
