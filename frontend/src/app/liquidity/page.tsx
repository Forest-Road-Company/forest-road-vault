import type {Metadata} from "next";
import { pageMetadata } from "@/lib/shareCards";
import {LiquidityOperation} from "@/components/app/LiquidityOperation";
import {PageShell} from "@/components/site/PageShell";
import {ProtocolScene} from "@/components/site/ProtocolScene";

export const metadata: Metadata = pageMetadata({
  title: "Treasury liquidity operation | Forest Road Vault",
  description: "A wallet-bound execution screen for Forest Road's USDfr / USDC Uniswap v4 liquidity position.",
  robots: {index: false, follow: false},
});

export default function LiquidityPage() {
  return (
    <PageShell
      section="Treasury operation"
      title="USDfr / USDC liquidity"
      lede="A wallet-bound, two-step execution surface for the approved Uniswap v4 position. The 50 USDC pilot must settle and verify on-chain before the remaining position can be prepared."
      visual={<ProtocolScene scene="markets" />}
    >
      <LiquidityOperation />
    </PageShell>
  );
}
