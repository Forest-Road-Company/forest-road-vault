import type {Metadata} from "next";
import { pageMetadata } from "@/lib/shareCards";

import {SusdfrV2LiquidityOperation} from "@/components/app/SusdfrV2LiquidityOperation";
import {PageShell} from "@/components/site/PageShell";
import {ProtocolScene} from "@/components/site/ProtocolScene";

export const metadata: Metadata = pageMetadata({
  title: "sUSDfr / USDC V2 liquidity | Forest Road Vault",
  description: "A wallet-bound execution screen for Forest Road's full-range sUSDfr / USDC Uniswap V2 liquidity.",
  robots: {index: false, follow: false},
});

export default function SusdfrV2LiquidityPage() {
  return (
    <PageShell
      section="Treasury operation"
      title="sUSDfr / USDC full-range liquidity"
      lede="A wallet-bound Uniswap V2 flow for exactly 25,000 USDC plus $25,000 worth of sUSDfr, with the opening ratio read from the live vault."
      visual={<ProtocolScene scene="markets" />}
    >
      <SusdfrV2LiquidityOperation />
    </PageShell>
  );
}
