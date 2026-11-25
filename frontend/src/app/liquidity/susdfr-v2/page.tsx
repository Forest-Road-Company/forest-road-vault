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
      lede="Internal wallet-bound execution and reconciliation surface for Forest Road's full-range sUSDfr / USDC Uniswap V2 position (25,000 USDC plus $25,000 worth of sUSDfr priced from the live vault)."
      visual={<ProtocolScene scene="markets" />}
    >
      <SusdfrV2LiquidityOperation />
    </PageShell>
  );
}
