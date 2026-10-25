import type {Metadata} from "next";
import {PageShell} from "@/components/site/PageShell";
import {MorphoMarketSurface} from "@/components/app/MorphoMarketSurface";

export const metadata: Metadata = {
  title: "Borrow & lend | Forest Road Vault",
  description: "Lend USDC or borrow it against sUSDfr in Forest Road’s Ethereum market on Morpho.",
};

export default function MarketsPage() {
  return <PageShell section="Borrow & lend" title="Put your capital to work."
    lede="Lend USDC to the market, or use sUSDfr as collateral to borrow USDC. Manage your position directly on Morpho, with variable rates and Ethereum settlement.">
    <MorphoMarketSurface />
  </PageShell>;
}
