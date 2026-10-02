import type {Metadata} from "next";
import Link from "next/link";

import {SusdfrLiquidityOperation} from "@/components/app/SusdfrLiquidityOperation";
import {PageShell} from "@/components/site/PageShell";

export const metadata: Metadata = {
  title: "sUSDfr / USDC liquidity | Forest Road Vault",
  robots: {index: false, follow: false},
};

export default function SusdfrLiquidityPage() {
  return (
    <PageShell
      section="Treasury operation"
      title="sUSDfr / USDC liquidity"
      lede="A wallet-bound, two-step Uniswap v4 flow: initialize and verify a 50 USDC in-range seed, then add the USDC-only 0.85–0.95 buy wall."
    >
      <SusdfrLiquidityOperation />
      <p className="mx-auto mt-8 max-w-4xl text-[13px] text-ink-muted">
        The separate full-range V2 opening is available in the{" "}
        <Link className="underline" href="/liquidity/susdfr-v2">
          guarded V2 liquidity flow
        </Link>
        .
      </p>
    </PageShell>
  );
}
