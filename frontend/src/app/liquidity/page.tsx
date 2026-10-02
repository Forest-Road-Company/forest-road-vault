import type {Metadata} from "next";
import {LiquidityOperation} from "@/components/app/LiquidityOperation";
import {PageShell} from "@/components/site/PageShell";

export const metadata: Metadata = {
  title: "Treasury liquidity operation | Forest Road Vault",
  robots: {index: false, follow: false},
};

export default function LiquidityPage() {
  return (
    <PageShell
      section="Treasury operation"
      title="USDfr / USDC liquidity"
      lede="A wallet-bound, two-step execution surface for the approved Uniswap v4 position. The 50 USDC pilot must settle and verify on-chain before the remaining position can be prepared."
    >
      <LiquidityOperation />
    </PageShell>
  );
}
