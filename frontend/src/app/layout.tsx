import type { Metadata } from "next";
import {
  Inter,
  Schibsted_Grotesk,
  IBM_Plex_Mono,
  Instrument_Serif,
} from "next/font/google";
import "./globals.css";
import { SiteNav } from "@/components/site/SiteNav";
import { SiteFooter } from "@/components/site/SiteFooter";
import { TestnetBanner } from "@/components/site/TestnetBanner";
import { Providers } from "@/components/app/Providers";
import {IS_TESTNET} from "@/config/contracts";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
});

const schibsted = Schibsted_Grotesk({
  variable: "--font-schibsted",
  subsets: ["latin"],
});

const plexMono = IBM_Plex_Mono({
  variable: "--font-plex-mono",
  weight: ["400", "500"],
  subsets: ["latin"],
});

const instrumentSerif = Instrument_Serif({
  variable: "--font-instrument-serif",
  weight: "400",
  style: ["normal", "italic"],
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Forest Road Vault — speciality-finance credit, on-chain",
  description:
    `On-chain access to Forest Road's diversified speciality-finance credit — film tax credits, renewable energy, life sciences, real estate, and digital assets — as a KYC-gated, yield-bearing synthetic dollar.${IS_TESTNET ? " Testnet build." : ""}`,
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${inter.variable} ${schibsted.variable} ${plexMono.variable} ${instrumentSerif.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
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
