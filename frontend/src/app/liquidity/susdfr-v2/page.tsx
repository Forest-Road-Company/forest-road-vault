import type {Metadata} from "next";

import {SusdfrV2LiquidityOperation} from "@/components/app/SusdfrV2LiquidityOperation";
import {PageShell} from "@/components/site/PageShell";

export const metadata: Metadata = {
  title: "sUSDfr / USDC V2 liquidity | Forest Road Vault",
  robots: {index: false, follow: false},
};

export default function SusdfrV2LiquidityPage() {
  return (
    <PageShell
      section="Treasury operation"
      title="sUSDfr / USDC full-range liquidity"
      lede="A wallet-bound Uniswap V2 flow for exactly 25,000 USDC plus $25,000 worth of sUSDfr, with the opening ratio read from the live vault."
    >
      <SusdfrV2LiquidityOperation />
    </PageShell>
  );
}
