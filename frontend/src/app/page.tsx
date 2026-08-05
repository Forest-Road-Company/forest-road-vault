import Link from "next/link";
import { Reveal } from "@/components/site/Reveal";
import { CascadeDiagram } from "@/components/site/CascadeDiagram";
import { HeroLiveStats } from "@/components/site/HeroLiveStats";
import { IS_MAINNET } from "@/config/contracts";
import { VERTICALS } from "@/lib/verticals";

export default function Landing() {
  return (
    <>
      {/* ── Hero: framed terrain ─────────────────────────────────────── */}
      <section className="px-2 pt-2 md:px-3 md:pt-3">
        <div className="hero-frame grain flex min-h-[min(88svh,1100px)] flex-col justify-between">
          <div className="hero-img" aria-hidden />
          <div className="hero-grade" aria-hidden />

          <div className="relative z-10 mx-auto w-full max-w-6xl px-6 pt-24 md:pt-32">
            <Reveal>
              <p className="font-mono text-[11px] uppercase tracking-[0.26em] text-cream/80">
                Forest Road Vault · {IS_MAINNET ? "Ethereum mainnet" : "Testnet build in progress"}
              </p>
            </Reveal>
          </div>

          <div className="relative z-10 mx-auto w-full max-w-6xl px-6 pb-14 md:pb-20">
            <Reveal delay={120}>
              <h1 className="serif-display max-w-3xl text-[44px] leading-[1.06] text-cream md:text-[64px]">
                The dollar built on
                <span className="serif-accent"> working credit</span>.
              </h1>
            </Reveal>
            <Reveal delay={220}>
              <p className="mt-6 max-w-xl text-[15.5px] leading-relaxed text-cream/85">
                Forest Road&apos;s speciality-finance book — film tax credits,
                renewable energy, life sciences, real estate, and digital
                assets — on-chain, as a KYC-gated, yield-bearing synthetic
                dollar. Yield is variable: the book&apos;s actual performance,
                nothing more.
              </p>
            </Reveal>
            <Reveal delay={320}>
              <div className="mt-9 flex flex-wrap items-center gap-3">
                <Link
                  href="/app"
                  className="rounded-pill bg-cream px-6 py-2.5 text-[13.5px] font-medium text-cream-ink transition-transform hover:scale-[1.03]"
                >
                  Enter App
                </Link>
                <Link
                  href="/how-it-works"
                  className="rounded-pill border border-cream/35 bg-cream/10 px-6 py-2.5 text-[13.5px] text-cream backdrop-blur-sm transition-colors hover:bg-cream/20"
                >
                  How it works
                </Link>
              </div>
            </Reveal>
            <Reveal delay={420}>
              <HeroLiveStats />
            </Reveal>
          </div>

          <p className="absolute bottom-3 right-4 z-10 font-mono text-[9px] tracking-wide text-cream/35">
            terrain: NASA astronaut photography, public domain
          </p>
        </div>
      </section>

      {/* ── Provenance row ───────────────────────────────────────────── */}
      <section className="mx-auto max-w-6xl px-5 py-14">
        <Reveal>
          <div className="flex flex-col items-baseline justify-between gap-4 md:flex-row">
            <p className="max-w-xl font-grotesk text-[17px] tracking-tight text-ink-muted">
              Originated, underwritten, and serviced in-house by{" "}
              <span className="text-ink">The Forest Road Company</span> — a
              speciality-finance merchant bank, lending against real claims
              since 2017.
            </p>
            <div className="flex gap-7 font-mono text-[10.5px] uppercase tracking-[0.18em] text-ink-faint">
              <span>Merchant bank</span>
              <span>Five verticals</span>
              <span>Ethereum L1</span>
            </div>
          </div>
        </Reveal>
      </section>

      {/* ── Cream editorial: the two-token model ─────────────────────── */}
      <section id="model" className="px-2 md:px-3">
        <div className="rounded-[22px] bg-cream px-6 py-20 md:px-14 md:py-28">
          <div className="mx-auto max-w-6xl">
            <Reveal>
              <p className="font-mono text-[11px] uppercase tracking-[0.24em] text-cream-ink-muted">
                The model
              </p>
              <h2 className="serif-display mt-5 max-w-2xl text-[38px] leading-[1.08] text-cream-ink md:text-[52px]">
                Two tokens, <span className="serif-accent">one honest split.</span>
              </h2>
              <p className="mt-5 max-w-xl text-[15px] leading-relaxed text-cream-ink-muted">
                A stable, composable unit of account — and a separate
                instrument for those who choose to bear credit performance.
                Nobody earns yield without knowingly holding the risk that
                generates it.
              </p>
            </Reveal>

            <div className="mt-14 grid gap-6 md:grid-cols-2">
              <Reveal delay={80}>
                <div className="flex h-full flex-col rounded-[16px] border border-cream-line bg-cream-deep/50 p-8">
                  <div className="flex items-baseline justify-between">
                    <p className="font-mono text-[12px] uppercase tracking-[0.22em] text-cream-ink">
                      USDfr
                    </p>
                    <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-cream-ink-muted">
                      the synthetic dollar
                    </p>
                  </div>
                  <p className="serif-display mt-6 text-[26px] leading-snug text-cream-ink">
                    Stable. Composable. Fully backed, verifiably.
                  </p>
                  <ul className="mt-6 space-y-3 text-[14px] leading-relaxed text-cream-ink-muted">
                    <li>Minted 1:1 from approved stablecoins via a KYC-gated controller.</li>
                    <li>
                      Backing — stablecoin reserves, short-term instruments,
                      and deployed principal at conservative marks — is an
                      on-chain invariant, enforced in the contracts and checked
                      by anyone.
                    </li>
                    <li>Does not itself yield.</li>
                  </ul>
                </div>
              </Reveal>
              <Reveal delay={180}>
                <div className="flex h-full flex-col rounded-[16px] border border-pine bg-pine p-8 text-cream shadow-[0_24px_48px_-24px_rgba(16,35,27,0.5)]">
                  <div className="flex items-baseline justify-between">
                    <p className="font-mono text-[12px] uppercase tracking-[0.22em] text-moss-bright">
                      sUSDfr
                    </p>
                    <p className="font-mono text-[10.5px] uppercase tracking-[0.16em] text-cream/60">
                      the yield-bearing vault
                    </p>
                  </div>
                  <p className="serif-display mt-6 text-[26px] leading-snug text-cream">
                    Variable yield, from the book&apos;s real performance.
                  </p>
                  <ul className="mt-6 space-y-3 text-[14px] leading-relaxed text-cream/75">
                    <li>
                      Stake USDfr into an ERC-4626 vault; value changes through
                      the exchange rate as facilities pay interest, reserves
                      earn, losses are recognized, and protocol fees crystallize.
                    </li>
                    <li>
                      No fixed rate is promised, ever — depositors hold the
                      performance of real credit.
                    </li>
                    <li>
                      Exits queue by epoch, FIFO, because the underlying is
                      real amortizing credit. Never presented as instant.
                    </li>
                    <li>
                      Launch fees: 10% of gross interest, then 10% of vault
                      profit above one global high-water mark. Performance is
                      prospectively variable up to a 20% cap; management starts
                      at 0% and is capped at 2% annually in v1.
                    </li>
                  </ul>
                </div>
              </Reveal>
            </div>
          </div>
        </div>
      </section>

      {/* ── Verticals: the five-class book ───────────────────────────── */}
      <section id="book" className="mx-auto max-w-6xl px-5 py-24 md:py-32">
        <Reveal>
          <p className="eyebrow">The book</p>
          <h2 className="serif-display mt-5 max-w-2xl text-[38px] leading-[1.08] text-ink md:text-[52px]">
            Five collateral classes,
            <br />
            <span className="serif-accent text-moss-bright">one diversified book.</span>
          </h2>
          <p className="mt-5 max-w-xl text-[15px] leading-relaxed text-ink-muted">
            Four receivable-backed verticals with legal-enforcement remedies —
            and one marked-to-market class with margin mechanics. Different
            durations, different risks, uncorrelated by design, with
            concentration limits enforced on-chain.
          </p>
        </Reveal>

        <div className="mt-14 grid gap-5 md:grid-cols-6">
          {VERTICALS.map((v, i) => (
            <Reveal
              key={v.slug}
              delay={i * 70}
              className={i < 2 ? "md:col-span-3" : "md:col-span-2"}
            >
              <Link
                href={`/verticals/${v.slug}`}
                className="panel panel-hover group flex h-full flex-col p-7"
              >
                <div className="flex items-start justify-between gap-3">
                  <h3 className="font-grotesk text-[19px] font-semibold tracking-tight text-ink group-hover:text-moss-bright">
                    {v.name}
                  </h3>
                  <span className="mt-1 h-1.5 w-1.5 shrink-0 rounded-full bg-moss glow-dot" />
                </div>
                {v.tag ? (
                  <p className="mt-2 inline-block self-start rounded-pill border border-gold/30 bg-gold-faint px-2.5 py-1 font-mono text-[9.5px] uppercase tracking-[0.14em] text-gold">
                    {v.tag}
                  </p>
                ) : null}
                <p className="mt-3 text-[13.5px] leading-relaxed text-ink-muted">
                  {v.financed}
                </p>
                <p className="mt-auto pt-5 font-mono text-[10.5px] uppercase tracking-[0.15em] text-ink-faint">
                  {v.duration}
                </p>
              </Link>
            </Reveal>
          ))}
        </div>
      </section>

      {/* ── Cascade ──────────────────────────────────────────────────── */}
      <section id="cascade" className="border-t border-line bg-surface/40">
        <div className="mx-auto max-w-6xl px-5 py-24 md:py-32">
          <div className="grid gap-12 lg:grid-cols-5">
            <Reveal className="lg:col-span-2">
              <p className="eyebrow">Loss absorption</p>
              <h2 className="serif-display mt-5 text-[38px] leading-[1.08] text-ink md:text-[46px]">
                Losses have an order.
                <br />
                <span className="serif-accent text-moss-bright">Depositors are last.</span>
              </h2>
              <p className="mt-5 text-[15px] leading-relaxed text-ink-muted">
                Every deployed dollar maps to an identified, lien-perfected
                facility — not a discretionary pool — and every loss flows
                through a fixed, contract-enforced cascade before it can touch
                a depositor.
              </p>
              <Link
                href="/how-it-works"
                className="u-link mt-7 inline-block font-mono text-[12px] uppercase tracking-[0.18em] text-moss"
              >
                The dual record system →
              </Link>
            </Reveal>
            <Reveal delay={150} className="lg:col-span-3">
              <CascadeDiagram />
            </Reveal>
          </div>
        </div>
      </section>

      {/* ── Closing ──────────────────────────────────────────────────── */}
      <section className="relative overflow-hidden">
        <div className="hero-mesh absolute inset-0" aria-hidden />
        <div className="relative mx-auto max-w-6xl px-5 py-24 text-center md:py-32">
          <Reveal>
            <p className="eyebrow">Built in the open</p>
            <h2 className="serif-display mx-auto mt-6 max-w-2xl text-[38px] leading-[1.1] text-ink md:text-[54px]">
              {IS_MAINNET ? "Live on-chain and built to be" : "On testnet until it’s"}
              <span className="serif-accent text-moss-bright"> proven</span>.
            </h2>
            <p className="mx-auto mt-5 max-w-lg text-[14.5px] leading-relaxed text-ink-muted">
              {IS_MAINNET
                ? "Review the verified contracts, live protocol state, current risks, and production disclosures before interacting."
                : "Every contract ships with its invariants encoded and fuzzed, and the first external review is published in full. Production waits on the remaining audit, operational, recovery and legal gates."}
            </p>
            <div className="mt-9 flex justify-center gap-3">
              <Link
                href="/transparency"
                className="rounded-pill bg-moss px-6 py-2.5 text-[13.5px] font-medium text-raised transition-transform hover:scale-[1.03] hover:bg-moss-bright"
              >
                Transparency dashboard
              </Link>
              <Link
                href="/risk"
                className="rounded-pill border border-line-strong px-6 py-2.5 text-[13.5px] text-ink-muted transition-colors hover:border-moss/50 hover:text-ink"
              >
                Read the risks
              </Link>
            </div>
          </Reveal>
        </div>
      </section>
    </>
  );
}
