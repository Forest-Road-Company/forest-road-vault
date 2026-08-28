import type { Metadata } from "next";
import { Merriweather, Inter_Tight, Azeret_Mono } from "next/font/google";
import "./globals.css";
import { SiteNav } from "@/components/site/SiteNav";
import { SiteFooter } from "@/components/site/SiteFooter";
import { TestnetBanner } from "@/components/site/TestnetBanner";
import { Providers } from "@/components/app/Providers";
import { IS_TESTNET } from "@/config/contracts";

/* The parent brand's faces, read off forestroad.com: Merriweather 600/700
   sets every headline there (its italic is the emphasis device), and Inter
   Tight carries nav and UI. Azeret Mono is reserved for on-chain strings, addresses, hashes, calldata, where mono is a legibility requirement
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

export const metadata: Metadata = {
  title: "Forest Road Vault | speciality-finance credit, on-chain",
  description:
    `On-chain access to Forest Road's diversified speciality-finance credit, film tax credits, renewable energy, life sciences, real estate, and digital assets, as a KYC-gated, yield-bearing synthetic dollar.${IS_TESTNET ? " Testnet build." : ""}`,
};

/* The direction contract for this build. It ships in the emitted markup so
   the render can be audited against what was committed to. */
const DIRECTION_CONTRACT = `<!--
IMPECCABLE DIRECTION CONTRACT, seed f1401973

THESIS: The arrangement an allocator already expects from an on-chain credit
protocol, executed at the craft level of Ethena, Sky, Morpho and Maple. It
refuses the FRAM slide deck ported to the web: eyebrow, keyline, uniform card
grid, one section per slide.

OWN-WORLD: White ground, navy elements. #ffffff ground, #f4f6f9 alternating
band, white panels, hairline rules. Navy (#1c2d48, #0f1a2e) is placed ON the
field as material, never as background: the nav mark, the primary action, the
figure band, table headers, the hero, the cascade, and the interior pages'
closing bands. The landing closes on the white field instead, with navy
carrying only its primary action.
Merriweather 600 display with its italic as the only emphasis device; Inter
Tight for UI and body; mono for on-chain strings only. No gradient washes.

STORY: This dollar is backed by identified, lien-perfected credit; the yield is
that book's actual performance and nothing more; it is on testnet; enter the
app.

FIRST VIEWPORT: Full-bleed navy graded over brand photography, ending on a hard
edge against the white field. Headline bottom-anchored at the left, the figure
strip beneath it on a rule that draws in, Enter App as the primary action
beside How it works, testnet caveat inline.

FORM: Canon, the standing exit, chosen deliberately over the dealt roll and
its three challengers. Seed key f1401973.

FINISH: unreviewed and undocumented is unfinished; this build ends with the
finish review, the verdict, and DESIGN.md
-->`;

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
      <body className="flex min-h-full flex-col">
        <div hidden dangerouslySetInnerHTML={{ __html: DIRECTION_CONTRACT }} />
        <Providers>
          <TestnetBanner />
          <SiteNav />
          <main className="flex-1">{children}</main>
          <SiteFooter />
        </Providers>
      </body>
    </html>
  );
}
