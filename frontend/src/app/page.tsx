import Image from "next/image";
import Link from "next/link";
import { Section, SectionHead } from "@/components/site/Blocks";
import { CascadeDiagram } from "@/components/site/CascadeDiagram";
import { HeroLiveStats } from "@/components/site/HeroLiveStats";
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
            animation are unchanged — they live on .hero-img. */}
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

        <div className="stage relative z-10 mx-auto w-full max-w-6xl px-5 pb-20 pt-24 md:pb-24">
          <h1 className="display max-w-[19ch] text-[clamp(2.6rem,7vw,4.6rem)] leading-[1.04] text-on-navy">
            The dollar built on{" "}
            <span className="display-accent">working credit</span>.
          </h1>

          <p className="mt-8 max-w-[54ch] text-[17px] leading-relaxed text-on-navy-muted">
            Forest Road&apos;s specialty finance book is on-chain. Deposit
            approved stablecoins to mint USDfr, stake it into sUSDfr, and
            earn what the loan book earns. The book spans media &amp;
            entertainment, renewable energy, and digital assets.
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
            <p className="text-[12.5px] leading-snug text-on-navy-faint">
              {IS_MAINNET
                ? "KYC-gated. Review the risk disclosures first."
                : "Testnet build: test assets, no real value."}
            </p>
          </div>

          <HeroLiveStats />
        </div>

        <p className="absolute bottom-3 right-4 z-10 text-[11px] tracking-[0.08em] text-on-navy/30">
          Forest Road Asset Management brand photography
        </p>
      </section>

      {/* ── Provenance: who underwrites this, stated once. ─────────────── */}
      <section className="border-b border-line bg-raised">
        <div className="mx-auto flex max-w-6xl flex-col items-baseline justify-between gap-5 px-5 py-14 md:flex-row">
          <p className="display max-w-[46ch] text-[19px] leading-snug">
            Originated, underwritten, and serviced in-house by{" "}
            <span className="text-accent">The Forest Road Company</span>,
            a specialty finance investment firm lending against real claims
            since 2018.
          </p>
          <div className="flex flex-wrap gap-x-8 gap-y-2">
            <span className="running-head">Investment firm</span>
            <span className="running-head">Three sectors</span>
            <span className="running-head">On-chain loan book</span>
          </div>
        </div>
      </section>

      {/* ── The two-token model. A pair of panels, differentiated by the
             field they sit on rather than by a coloured edge. ──────────── */}
      <Section id="model" tone="surface">
        {/* The italic is reserved for headings where the emphasis turns the
            sentence — the cascade and the audit claim. Used in every heading it
            stops being emphasis and becomes the section's default voice. */}
        <SectionHead
          title="One stable dollar. One way to earn."
          lede="USDfr is the stable dollar. Stake it into sUSDfr and it is put to work in loans Forest Road originates, underwrites and services."
        />

        <div className="mt-16 grid gap-6 md:grid-cols-2">
          <div className="flex h-full flex-col rounded-card border border-line bg-raised p-8 md:p-9">
            <div className="flex items-baseline justify-between gap-3">
              <p className="display text-[19px]">USDfr</p>
              <p className="running-head">The stablecoin</p>
            </div>
            <div className="mt-6 h-px w-full bg-line" />
            <p className="display mt-6 text-[25px] leading-snug">
              Fully backed, and verifiable on-chain.
            </p>
            <ul className="mt-6 space-y-3.5 text-[15px] leading-relaxed text-ink-muted">
              <li>
                Minted 1:1 from approved stablecoins via a KYC-gated controller.
              </li>
              <li>
                Backing is stablecoin reserves, short-term instruments, and
                deployed loan principal, and can be checked on chain at any
                time.
              </li>
              <li>It is a dollar claim and earns nothing on its own.</li>
            </ul>

            {/* The panel's third beat: the invariant it exists to state, and
                where a reader goes to check it against live state. Without
                this the pair's equal heights leave the white panel hollow. */}
            <div className="mt-auto pt-8">
              <div className="h-px w-full bg-line" />
              <p className="mt-5 text-[15px] leading-relaxed text-ink">
                Never more supply than backing, enforced on every mint.
              </p>
              <Link
                href="/transparency"
                className="u-link mt-2 inline-flex min-h-[24px] items-center text-[13px] font-medium text-accent"
              >
                Check it live →
              </Link>
            </div>
          </div>

          <div className="navy-band-deep flex h-full flex-col rounded-card border border-navy-border p-8 md:p-9">
            <div className="flex items-baseline justify-between gap-3">
              <p className="display text-[19px] text-on-navy-accent">sUSDfr</p>
              <p className="running-head">The yield-bearing vault</p>
            </div>
            <div className="mt-6 h-px w-full bg-on-navy-line" />
            <p className="display mt-6 text-[25px] leading-snug">
              Variable yield, from the book&apos;s actual performance.
            </p>
            <ul className="mt-6 space-y-3.5 text-[14.5px] leading-relaxed text-on-navy-muted">
              <li>
                Stake USDfr to get it. It pays what the loan book earns, and
                its value can fall if loans lose money.
              </li>
              <li>
                Redemptions are filled first in, first out, in step with the
                cash the book actually receives.
              </li>
              <li>
                Fees come out of realized performance only, at capped,
                disclosed rates.
              </li>
            </ul>
          </div>
        </div>
      </Section>

      {/* ── Loss absorption, on the deepest field. The one thing a depositor
             must understand gets the strongest treatment on the page. The
             sector index lives at /sectors, reachable from the nav — the
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
              lede="Forest Road and its partners post first-loss capital that sits ahead of every depositor. If a loan underperforms, that capital absorbs the loss before depositors are touched. The order is written into the contract."
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

      {/* ── Close. White ground, navy carrying the primary action instead
             of the field — the page's own material rule applied to its own
             foot. ────────────────────────────────────────────────────── */}
      <Section tone="light">
        <div className="flex flex-col gap-10 lg:flex-row lg:items-end lg:justify-between lg:gap-20">
          <div>
            <h2 className="display max-w-[22ch] text-[31px] leading-[1.12] md:text-[46px]">
              {IS_MAINNET
                ? "Live on-chain, and still auditable line by line."
                : "Built, tested, and audited."}
            </h2>
            <p className="mt-6 max-w-[58ch] text-[17px] leading-relaxed text-ink-muted">
              {IS_MAINNET
                ? "Review the verified contracts, live protocol state, current risks, and production disclosures before interacting."
                : "The protocol is written, tested and independently audited. The remaining launch gates — audit, operational, recovery and legal — are listed where they can be checked."}
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
