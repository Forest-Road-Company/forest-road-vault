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
      lede="Internal wallet-bound execution and reconciliation surface for Forest Road's approved USDfr / USDC Uniswap v4 position (enforcing 50 USDC pilot verification before preparing any remaining tranche)."
      visual={<ProtocolScene scene="markets" />}
    >
      <LiquidityOperation />
    </PageShell>
  );
}
