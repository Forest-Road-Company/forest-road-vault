import type {Metadata} from "next";
import {PageShell} from "@/components/site/PageShell";
import {ProtocolScene} from "@/components/site/ProtocolScene";
import {MorphoMarketSurface} from "@/components/app/MorphoMarketSurface";
import {socialMetadata} from "@/lib/shareCards";

export const metadata: Metadata = {
  title: "Borrow & lend | Forest Road Vault",
  description: "Lend USDC or borrow it against sUSDfr in Forest Road’s Ethereum market on Morpho.",
  ...socialMetadata({
    card: "markets",
    title: "Borrow & lend | Forest Road Vault",
    description: "Lend USDC or borrow it against sUSDfr in Forest Road’s Ethereum market on Morpho.",
  }),
};

export default function MarketsPage() {
  return <PageShell section="Borrow & lend" title="Put your capital to work."
    lede="Lend USDC to the market, or use sUSDfr as collateral to borrow USDC. Manage your position directly on Morpho, with variable rates and Ethereum settlement."
    visual={<ProtocolScene scene="markets" />}>
    <MorphoMarketSurface />
  </PageShell>;
}
