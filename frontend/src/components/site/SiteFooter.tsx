import Link from "next/link";
import {IS_TESTNET} from "@/config/contracts";

export function SiteFooter() {
  return (
    <footer className="border-t border-line bg-surface">
      <div className="mx-auto max-w-6xl px-5 py-12">
        <div className="flex flex-col gap-10 md:flex-row md:justify-between">
          <div className="max-w-md space-y-3">
            <p className="font-grotesk text-[15px] font-semibold tracking-tight">
              Forest Road <span className="text-moss">Vault</span>
            </p>
            <p className="text-[13px] leading-relaxed text-ink-faint">
              A KYC-gated, legally-wrapped RWA credit protocol bringing Forest
              Road&apos;s speciality-finance book on-chain. Yield is variable and
              reflects the actual performance of the loan book and reserves —
              nothing here promises a fixed return. Token characterization is a
              matter for counsel; nothing on this site is legal, tax, or
              investment advice, or an offer of securities.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-x-16 gap-y-2 text-[13px]">
            <div className="space-y-2">
              <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint">
                Protocol
              </p>
              <Link href="/how-it-works" className="block text-ink-muted hover:text-ink">
                How it works
              </Link>
              <Link href="/verticals" className="block text-ink-muted hover:text-ink">
                Verticals
              </Link>
              <Link href="/transparency" className="block text-ink-muted hover:text-ink">
                Transparency
              </Link>
              <Link href="/points" className="block text-ink-muted hover:text-ink">
                Points
              </Link>
              <Link href="/app" className="block text-ink-muted hover:text-ink">
                App
              </Link>
            </div>
            <div className="space-y-2">
              <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint">
                Legal
              </p>
              <Link href="/legal" className="block text-ink-muted hover:text-ink">
                Disclosures
              </Link>
              <Link href="/risk" className="block text-ink-muted hover:text-ink">
                Risk factors
              </Link>
              <Link href="/terms" className="block text-ink-muted hover:text-ink">
                Terms
              </Link>
            </div>
          </div>
        </div>

        <div className="mt-10 border-t border-line pt-6">
          <p className="font-mono text-[11px] tracking-wide text-ink-faint">
            {IS_TESTNET
              ? "TESTNET ONLY — this build never touches mainnet or real value. Mainnet remains gated on the published launch checklist."
              : "ETHEREUM MAINNET — smart-contract, liquidity, credit, legal, oracle, governance, and operational risks remain. Review all disclosures; nothing here is legal, tax, or investment advice."}
          </p>
        </div>
      </div>
    </footer>
  );
}
