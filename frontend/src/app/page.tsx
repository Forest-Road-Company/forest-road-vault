import Image from "next/image";
import Link from "next/link";
import { Section, SectionHead } from "@/components/site/Blocks";
import { CascadeDiagram } from "@/components/site/CascadeDiagram";
import { HeroLiveStats } from "@/components/site/HeroLiveStats";
import { IS_MAINNET } from "@/config/contracts";
import { VERTICALS } from "@/lib/verticals";

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
            Forest Road&apos;s speciality-finance book is on-chain, as a
            KYC-gated, yield-bearing synthetic dollar. The book spans film tax
            credits, renewable energy, life sciences, real estate, and digital
            assets. Yield is variable: the book&apos;s actual performance,
            nothing more.
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
            a speciality-finance merchant bank lending against real claims
            since 2017.
          </p>
          <div className="flex flex-wrap gap-x-8 gap-y-2">
            <span className="running-head">Merchant bank</span>
            <span className="running-head">Five verticals</span>
            <span className="running-head">Ethereum L1</span>
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
          title="Two tokens, one honest split."
          lede="A stable, composable unit of account. A separate instrument for those who choose to bear credit performance. Nobody earns yield without knowingly holding the risk that generates it."
        />

        <div className="mt-16 grid gap-6 md:grid-cols-2">
          <div className="flex h-full flex-col rounded-card border border-line bg-raised p-8 md:p-9">
            <div className="flex items-baseline justify-between gap-3">
              <p className="display text-[19px]">USDfr</p>
              <p className="running-head">The synthetic dollar</p>
            </div>
            <div className="mt-6 h-px w-full bg-line" />
            <p className="display mt-6 text-[25px] leading-snug">
              Backed, verifiably, and built to stay boring.
            </p>
            <ul className="mt-6 space-y-3.5 text-[15px] leading-relaxed text-ink-muted">
              <li>
                Minted 1:1 from approved stablecoins via a KYC-gated controller.
              </li>
              <li>
                Backing is stablecoin reserves, short-term instruments, and
                deployed principal at conservative marks. The contracts
                enforce it as an on-chain invariant, and anyone can check it.
              </li>
              <li>Does not itself yield.</li>
            </ul>

            {/* The panel's third beat: the invariant it exists to state, and
                where a reader goes to check it against live state. Without
                this the pair's equal heights leave the white panel hollow. */}
            <div className="mt-auto pt-8">
              <div className="h-px w-full bg-line" />
              <p className="mt-5 text-[15px] leading-relaxed text-ink">
                supply&nbsp;≤&nbsp;backing, enforced on every mint
              </p>
              <Link
                href="/transparency"
                className="u-link mt-2 inline-flex min-h-[24px] items-center text-[13px] font-medium text-accent"
              >
                Reconcile it against live state →
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
                Stake USDfr into an ERC-4626 vault; value changes through the
                exchange rate as facilities pay interest, reserves earn, losses
                are recognized, and protocol fees crystallize.
              </li>
              <li>
                Nobody promises a fixed rate. Depositors hold the performance
                of real credit.
              </li>
              <li>
                Exits queue by epoch, FIFO, because the underlying is real
                amortizing credit. It&apos;s never instant.
              </li>
              <li>
                Launch fees: 10% of gross interest, then 10% of vault profit
                above one global high-water mark, capped at 20% and variable
                going forward. Management starts at 0% and caps at 2%
                annually in v1.
              </li>
            </ul>
          </div>
        </div>
      </Section>

      {/* ── The book. Five equal tiles at the site's own measure: the class
             list is an index, and what each class finances belongs to the page
             the tile links to rather than to five competing paragraphs. ─── */}
      <Section id="book" tone="light">
        {/* Opened as a two-column argument rather than another stacked
            headline-and-lede: the section vocabulary has to vary or the page
            reads as one slide repeated. */}
        <div className="flex flex-col gap-8 lg:flex-row lg:items-end lg:gap-20">
          <h2 className="display max-w-[15ch] flex-none text-[31px] leading-[1.12] md:text-[46px] lg:w-[6in]">
            Four classes foreclose. One margin-calls.
          </h2>
          <p className="max-w-[56ch] flex-1 text-[17px] leading-relaxed text-ink-muted">
            The receivable-backed verticals enforce through legal foreclosure on
            an assigned claim. The digital-assets class is marked to market and
            enforces through margin and liquidation instead. That&apos;s a
            different mechanism, on a much faster clock, and it&apos;s
            disclosed as such. Different durations, different risks, with
            concentration limits enforced on-chain.
          </p>
        </div>

        <div className="mt-14 grid gap-4 sm:grid-cols-2 md:grid-cols-5">
          {VERTICALS.map((v) => (
            <Link
              key={v.slug}
              href={`/verticals/${v.slug}`}
              className="panel panel-hover group flex h-full flex-col p-5"
            >
              <h3 className="display text-[17px] leading-tight transition-colors group-hover:text-accent">
                {v.name}
              </h3>
              {/* The enforcement mechanism is what the headline promises to
                  distinguish, so it is the one fact the tile carries. */}
              <p className="running-head mt-4 leading-relaxed">
                {v.collateralModel === "receivable"
                  ? "Legal foreclosure"
                  : "Margin & liquidation"}
              </p>
              {/* The related-party facility stays disclosed on the landing
                  page, not only on the class page. */}
              {v.tag ? (
                <p className="running-head mt-1 leading-relaxed text-accent">
                  Related party
                </p>
              ) : null}
              <p className="running-head mt-auto pt-4 leading-relaxed text-ink-faint">
                {v.duration}
              </p>
            </Link>
          ))}
        </div>
      </Section>

      {/* ── Loss absorption, on the deepest field. The one thing a depositor
             must understand gets the strongest treatment on the page. ──── */}
      <Section id="cascade" tone="navy-deep">
        <div className="grid gap-14 lg:grid-cols-5">
          <div className="lg:col-span-2">
            <SectionHead
              tone="navy-deep"
              title={
                <>
                  Losses have an order.{" "}
                  <span className="display-accent">Depositors are last</span>.
                </>
              }
              lede="Every deployed dollar maps to an identified, lien-perfected facility, not a discretionary pool. Every loss flows through a fixed, contract-enforced cascade before it can touch a depositor."
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
                : "Production waits on gates that are still unchecked."}
            </h2>
            <p className="mt-6 max-w-[58ch] text-[17px] leading-relaxed text-ink-muted">
              {IS_MAINNET
                ? "Review the verified contracts, live protocol state, current risks, and production disclosures before interacting."
                : "Every contract ships with its invariants encoded and fuzzed, and the first external review is published in full. The remaining audit, operational, recovery and legal gates are listed where they can be checked."}
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
