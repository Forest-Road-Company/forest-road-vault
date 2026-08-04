import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { Reveal } from "@/components/site/Reveal";
import { PointsDashboard } from "@/components/app/PointsDashboard";

export const metadata: Metadata = {
  title: "Points — Forest Road Vault",
};

/** The three earning positions and their governance-set multiples (points-v2, live on Sepolia). */
const multiples = [
  { source: "sUSDfr staked", weight: "1× → 2×", note: "the base rate — you already earn yield" },
  { source: "USDfr held", weight: "3× → 6×", note: "in lieu of yield stakers receive" },
  { source: "Curator first-loss", weight: "5× → 10×", note: "the deepest, first-to-absorb risk" },
] as const;

/** Static SVG of the maturity ramp: 1.0× → 2.0× over 12 months, then flat. */
function MaturityRamp() {
  return (
    <svg viewBox="0 0 560 200" className="w-full" role="img" aria-label="Maturity multiplier ramps linearly from 1x to 2x over twelve months, then stays at 2x">
      <line x1="40" y1="160" x2="540" y2="160" stroke="var(--color-line-strong)" strokeWidth="1" />
      <line x1="40" y1="20" x2="40" y2="160" stroke="var(--color-line-strong)" strokeWidth="1" />
      <line x1="40" y1="40" x2="540" y2="40" stroke="var(--color-line)" strokeDasharray="3 5" strokeWidth="1" />
      <path d="M 40 160 L 340 40 L 540 40" fill="none" stroke="var(--color-moss)" strokeWidth="2.5" strokeLinejoin="round" />
      <path d="M 40 160 L 340 40 L 540 40 L 540 160 Z" fill="var(--color-moss-faint)" stroke="none" />
      <circle cx="340" cy="40" r="4" fill="var(--color-moss)" />
      <text x="34" y="164" textAnchor="end" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-mono)">1.0×</text>
      <text x="34" y="44" textAnchor="end" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-mono)">2.0×</text>
      <text x="340" y="182" textAnchor="middle" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-mono)">12 months</text>
      <text x="540" y="182" textAnchor="end" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-mono)">time →</text>
    </svg>
  );
}

export default function PointsPage() {
  return (
    <PageShell
      eyebrow="Points"
      title="Participation, measured honestly"
      lede="Points track genuine, sustained participation — USDfr held, sUSDfr staked, and curator first-loss capital, each accruing per unit held over time at its own multiple. They are a measure of contribution. They are not a token, not a promise of one, and not an implied return: any future utility is discretionary and subject to counsel review."
    >
      <PointsDashboard />

      <Reveal>
        <div className="panel mt-5 p-7">
          <div className="grid items-center gap-8 lg:grid-cols-2">
            <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
              How accrual works
            </p>
            <p className="mt-3 max-w-xl text-[14px] leading-relaxed text-ink-muted">
              Every eligible position&apos;s forward accrual rate ramps linearly
              over 365 days: sUSDfr currently moves from 1× to 2×, USDfr from
              3× to 6×, and curator first-loss from 5× to 10×. Adding capital
              blends the position&apos;s maturity timestamp toward the current
              time in proportion to the amount added. Withdrawing leaves the
              remaining balance&apos;s maturity unchanged; transferred or
              redeposited capital starts or blends at the current time.
            </p>
            </div>
            <div>
              <MaturityRamp />
            </div>
          </div>
        </div>
      </Reveal>

      {/* mechanics */}
      <div className="mt-5 grid gap-5 md:grid-cols-3">
        <Reveal>
          <div className="panel h-full p-6">
            <h3 className="font-grotesk text-[15px] font-semibold tracking-tight text-ink">
              Time-weighted, not volume-based
            </h3>
            <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
              Points accrue as balance × time, never per transaction. There is
              nothing to farm with churn or wash activity — a year of steady
              holding decisively beats a month of frantic cycling.
            </p>
          </div>
        </Reveal>
        <Reveal delay={70}>
          <div className="panel h-full p-6">
            <h3 className="font-grotesk text-[15px] font-semibold tracking-tight text-ink">
              Per wallet, linear by design
            </h3>
            <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
              Accrual is per wallet — no identity binding, no KYC needed to earn.
              Splitting a balance across addresses cannot increase the flat
              per-unit rate. Moving seasoned capital to a fresh wallet restarts
              that position&apos;s maturity ramp at 1×, so churn can only reduce
              its forward accrual.
            </p>
          </div>
        </Reveal>
        <Reveal delay={140}>
          <div className="panel h-full p-6">
            <h3 className="font-grotesk text-[15px] font-semibold tracking-tight text-ink">
              Flat rate, no size penalty
            </h3>
            <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">
              Every unit earns the same per-unit rate — a large holder is never
              penalised for size. What sets your rate is the{" "}
              <span className="text-ink">position type and maturity</span>, not
              the amount. Current start→mature ranges:
            </p>
            <table className="mt-3 w-full font-mono text-[11px] text-ink-muted">
              <tbody>
                {multiples.map((m) => (
                  <tr key={m.source} className="border-t border-line">
                    <td className="py-1.5">{m.source}</td>
                    <td className="py-1.5 text-right text-ink">{m.weight}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Reveal>
      </div>

      {/* why USDfr earns a multiple */}
      <Reveal>
        <div className="mt-5 panel p-7">
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">
            Why USDfr earns more than sUSDfr
          </p>
          <p className="mt-3 max-w-3xl text-[13.5px] leading-relaxed text-ink-muted">
            sUSDfr stakers already receive the protocol&apos;s variable yield, so
            their points start at the 1× base and mature to 2×. USDfr holders
            forgo that yield — they
            hold a plain, transferable dollar — so points compensate at a governance-set
            source multiple (3×→6× today){" "}
            <span className="text-ink">in lieu of yield</span>.
            Curator first-loss capital, which absorbs the very first dollar of any
            loss, earns the most (5×→10× today). All three source multiples are bounded and
            governance-tunable; changes apply going forward, never retroactively.
          </p>
        </div>
      </Reveal>

      {/* leaderboard requires event indexing; individual wallet accounting is fully on-chain */}
      <Reveal>
        <div className="mt-5 rounded-card border border-dashed border-line-strong bg-raised/60 p-8 text-center">
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-ink-faint">
            Leaderboard
          </p>
          <p className="mx-auto mt-3 max-w-md text-[13.5px] leading-relaxed text-ink-muted">
            Individual wallet points are fully on-chain and shown above. A global
            ranking requires an event indexer to discover the participant set; no
            leaderboard is published until that index is complete and independently
            reconcilable to PointsModule reads.
          </p>
        </div>
      </Reveal>

      {/* the honest box */}
      <Reveal>
        <div className="mt-10 rounded-card border border-gold/30 bg-gold-faint p-7">
          <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-gold">
            What points are not
          </p>
          <p className="mt-3 max-w-3xl text-[13.5px] leading-relaxed text-ink-muted">
            Points are not a token, a security, a yield, or a claim on one.
            Nothing here promises conversion to any asset, and no conversion
            rate, date, or allocation exists. If Forest Road ever proposes a
            use for points, that decision is discretionary and passes through
            the same securities-counsel review that gates the rest of the
            protocol before mainnet. Anyone telling you otherwise is not
            speaking for the protocol.
          </p>
        </div>
      </Reveal>
    </PageShell>
  );
}
