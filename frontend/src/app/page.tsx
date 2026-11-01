import Image from "next/image";
import Link from "next/link";
import { Section, SectionHead } from "@/components/site/Blocks";
import { CascadeDiagram } from "@/components/site/CascadeDiagram";
import { HeroLiveStats } from "@/components/site/HeroLiveStats";
import { PageAtlas } from "@/components/site/PageAtlas";
import { HeroCapitalTrace, HomeTransparencyPreview, OperateCards, TokenMechanics } from "@/components/site/HomeVisuals";
import { IS_MAINNET } from "@/config/contracts";

export default function Landing() {
  return (
    <>
      {/* ── Hero. Full-bleed, so the first viewport is the page rather than a
             banner sitting inside it. Navy is graded across the brand
             photography from the left, which is where the type sits. ─────── */}
      <section className="hero-frame grain flex min-h-[min(82svh,960px)] flex-col justify-end">
        {/* The LCP element. As a CSS background it shipped one 2400px JPEG to
            every device; through next/image it negotiates AVIF/WebP and a
            width-appropriate variant. The grade, art direction and settle
            animation are unchanged, they live on .hero-img. */}
        <Image
          src="/brand/hero-cover.jpg"
          alt=""
          fill
          priority
          sizes="100vw"
          className="hero-img"
          aria-hidden
        />
        <div className="hero-grade" aria-hidden />
        <HeroCapitalTrace />

        <div className="stage relative z-10 mx-auto w-full max-w-6xl px-5 pb-20 pt-24 md:pb-24">
          <h1 className="display max-w-[19ch] text-[clamp(2.6rem,7vw,4.6rem)] leading-[1.04] text-on-navy">
            Working credit, with an{" "}
            <span className="display-accent">on-chain record</span>.
          </h1>

          <p className="mt-8 max-w-[54ch] text-[17px] leading-relaxed text-on-navy-muted">
            Forest Road Vault records loans Forest Road originates, underwrites,
            and services on-chain. USDfr is backed by reserve assets and deployed
            loan principal; sUSDfr reflects net book performance after fees and
            losses. The Vault covers Media, Renewables, and Digital Assets.
          </p>

          <div className="mt-10 flex flex-wrap items-center gap-x-4 gap-y-3">
            <Link
              href="/app"
              className="rounded-pill bg-raised px-7 py-3 text-[14px] font-semibold text-navy transition-colors hover:bg-on-navy-accent"
            >
              Enter App
            </Link>
            <Link
              href="/how-it-works"
              className="rounded-pill border border-on-navy-line px-7 py-3 text-[14px] text-on-navy transition-colors hover:border-on-navy-accent hover:text-on-navy-accent"
            >
              How it works
            </Link>
            {!IS_MAINNET && (
              <p className="text-[12.5px] leading-snug text-on-navy-faint">
                Testnet build: test assets, no real value.
              </p>
            )}
          </div>

          <HeroLiveStats />
        </div>

      </section>

      {/* ── Provenance: who underwrites this, stated once. ─────────────── */}
      <section className="border-b border-line bg-raised">
        <div className="mx-auto flex max-w-6xl flex-col items-baseline justify-between gap-5 px-5 py-14 md:flex-row">
          <p className="display max-w-[46ch] text-[19px] leading-snug">
            Originated, underwritten, and serviced in-house by{" "}
            <span className="text-accent">Forest Road</span>,
            a specialty finance company lending against real claims
            since 2018.
          </p>
          <div className="flex flex-wrap gap-x-8 gap-y-2">
            <span className="running-head">Specialty finance company</span>
            <span className="running-head">Three sectors</span>
            <span className="running-head">The Vault&apos;s on-chain book</span>
          </div>
        </div>
      </section>

      <PageAtlas />

      {/* ── The two-token model. A pair of panels, differentiated by the
             field they sit on rather than by a coloured edge. ──────────── */}
      <Section id="model" tone="surface">
        {/* The italic is reserved for headings where the emphasis turns the
            sentence, the cascade and the audit claim. Used in every heading it
            stops being emphasis and becomes the section's default voice. */}
        <SectionHead
          title="One credit-backed unit. One staked position."
          lede="USDfr is backed by reserves and deployed loan principal. sUSDfr is a staked position whose value reflects the Vault's net book performance after fees and losses."
        />

        <TokenMechanics />
      </Section>

      <Section tone="light" id="operate">
        <div className="flex flex-col gap-7 lg:flex-row lg:items-end lg:justify-between">
          <SectionHead title="A purpose-built surface for every move." lede="The interface follows the same path as the capital. Each action simulates against current chain state before the wallet opens." />
          <Link href="/app" className="u-link flex-none text-[12px] font-semibold uppercase tracking-[.14em] text-accent">Open the app →</Link>
        </div>
        <OperateCards />
      </Section>

      {/* ── Loss absorption, on the deepest field. The one thing a depositor
             must understand gets the strongest treatment on the page. The
             sector index lives at /sectors, reachable from the nav. The
             landing page stays skinny on purpose. ─────────────────────── */}
      <Section id="cascade" tone="navy-deep">
        <div className="grid gap-14 lg:grid-cols-5">
          <div className="lg:col-span-2">
            <SectionHead
              tone="navy-deep"
              title={
                <>
                  Built for alignment.{" "}
                  <span className="display-accent">
                    Our capital absorbs losses first
                  </span>
                  .
                </>
              }
              lede="Forest Road posts first-loss capital that sits ahead of every depositor. If a loan underperforms, that capital absorbs the loss before depositors are touched. The order is written into the contract."
            />
            <Link
              href="/how-it-works"
              className="u-link mt-9 inline-flex min-h-[24px] items-center text-[13px] font-semibold uppercase tracking-[0.14em] text-on-navy-accent"
            >
              The dual record system →
            </Link>
          </div>
          <div className="lg:col-span-3">
            <CascadeDiagram tone="navy" />
          </div>
        </div>
      </Section>

      <Section tone="navy">
        <HomeTransparencyPreview />
      </Section>

      {/* ── Close. White ground, navy carrying the primary action instead
             of the field, the page's own material rule applied to its own
             foot. ────────────────────────────────────────────────────── */}
      <Section tone="light">
        <div className="flex flex-col gap-10 lg:flex-row lg:items-end lg:justify-between lg:gap-20">
          <div>
            <h2 className="display max-w-[22ch] text-[31px] leading-[1.12] md:text-[46px]">
              {IS_MAINNET
                ? "Contracts deployed. Status stays explicit."
                : "A preview, not a launch claim."}
            </h2>
            <p className="mt-6 max-w-[58ch] text-[17px] leading-relaxed text-ink-muted">
              {IS_MAINNET
                ? "Review the verified contracts and on-chain state together with current entry switches, eligibility requirements, legal disclosures, and risks. A mainnet deployment does not mean every product or transaction path is open."
                : "This Sepolia preview uses valueless test assets. A separate Ethereum mainnet contract deployment exists, but legal, operational, and product-entry status must be checked independently."}
            </p>
          </div>

          <div className="flex flex-none flex-wrap items-center gap-x-7 gap-y-4">
            <Link
              href="/transparency"
              className="rounded-pill bg-navy px-7 py-3 text-[14px] font-semibold text-on-navy transition-colors hover:bg-navy-raised"
            >
              Transparency dashboard
            </Link>
            <Link
              href="/risk"
              className="u-link inline-flex min-h-[24px] items-center text-[13px] font-semibold uppercase tracking-[0.14em] text-accent"
            >
              Read the risks →
            </Link>
          </div>
        </div>
      </Section>
    </>
  );
}
