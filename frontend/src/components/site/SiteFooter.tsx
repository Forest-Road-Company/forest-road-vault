import Image from "next/image";
import Link from "next/link";
import {IS_TESTNET} from "@/config/contracts";

/**
 * The closing navy moment. The deck runs "FOREST ROAD ASSET MANAGEMENT"
 * along the foot of every slide; here that running head sits under the
 * white lockup on a navy band.
 */
export function SiteFooter() {
  return (
    /* A visible rule at the seam: the closing anchor above is also navy, and
       without it the two bands read as one dark mass at a glance. */
    <footer className="navy-band-deep border-t border-white/20">
      <div className="mx-auto max-w-6xl px-5 py-14">
        <div className="flex flex-col gap-10 md:flex-row md:justify-between">
          <div className="max-w-md space-y-4">
            <Image
              src="/brand/fram-lockup-white.png"
              alt="Forest Road Asset Management"
              width={264}
              height={267}
              className="h-12 w-auto"
            />
            <p className="text-[13px] leading-relaxed text-on-navy-faint">
              A KYC-gated, legally-wrapped RWA credit protocol bringing Forest
              Road&apos;s speciality-finance book on-chain. Yield is variable and
              reflects the actual performance of the loan book and reserves.
              Nothing here promises a fixed return. Token characterization is a
              matter for counsel; nothing on this site is legal, tax, or
              investment advice, or an offer of securities.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-x-16 gap-y-8 text-[13px] sm:grid-cols-3 sm:gap-y-2">
            <div className="space-y-2">
              <p className="running-head text-on-navy-accent">Protocol</p>
              <Link href="/how-it-works" className="block text-on-navy-muted hover:text-on-navy">
                How it works
              </Link>
              <Link href="/verticals" className="block text-on-navy-muted hover:text-on-navy">
                Verticals
              </Link>
              <Link href="/transparency" className="block text-on-navy-muted hover:text-on-navy">
                Transparency
              </Link>
              <Link href="/docs" className="block text-on-navy-muted hover:text-on-navy">
                Docs
              </Link>
              <Link href="/points" className="block text-on-navy-muted hover:text-on-navy">
                Points
              </Link>
              <Link href="/app" className="block text-on-navy-muted hover:text-on-navy">
                App
              </Link>
            </div>
            <div className="space-y-2">
              <p className="running-head text-on-navy-accent">Legal</p>
              <Link href="/legal" className="block text-on-navy-muted hover:text-on-navy">
                Disclosures
              </Link>
              <Link href="/risk" className="block text-on-navy-muted hover:text-on-navy">
                Risk factors
              </Link>
              <Link href="/terms" className="block text-on-navy-muted hover:text-on-navy">
                Terms
              </Link>
            </div>
            <div className="space-y-2">
              <p className="running-head text-on-navy-accent">Community</p>
              {/* External destinations: plain anchors, not next/link — off-origin URLs are never
                  client-side navigations, so Link adds nothing and obscures the intent. */}
              <a
                href="https://discord.gg/3rrEx8bxWr"
                target="_blank"
                rel="noreferrer noopener"
                className="block text-on-navy-muted hover:text-on-navy"
              >
                Discord
              </a>
              <a
                href="https://x.com/forestroadvault"
                target="_blank"
                rel="noreferrer noopener"
                className="block text-on-navy-muted hover:text-on-navy"
              >
                X
              </a>
            </div>
          </div>
        </div>

        <div className="mt-12 flex flex-col gap-3 border-t border-on-navy-line pt-6 md:flex-row md:items-baseline md:justify-between">
          <p className="text-[11px] font-medium uppercase tracking-[0.16em] text-on-navy-faint">
            Forest Road Asset Management
          </p>
          <p className="max-w-3xl text-[11px] leading-relaxed text-on-navy-faint md:text-right">
            {IS_TESTNET
              ? "TESTNET ONLY: this build never touches mainnet or real value. Mainnet remains gated on the published launch checklist."
              : "ETHEREUM MAINNET: smart-contract, liquidity, credit, legal, oracle, governance, and operational risks remain. Review all disclosures; nothing here is legal, tax, or investment advice."}
          </p>
        </div>
      </div>
    </footer>
  );
}
