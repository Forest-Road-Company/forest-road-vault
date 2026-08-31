import type { Metadata } from "next";
import { PageShell, PageBody } from "@/components/site/PageShell";
import {
  Section,
  SectionHead,
  KpiBand,
  CardDeck,
  HighlightBox,
} from "@/components/site/Blocks";
import { PointsDashboard } from "@/components/app/PointsDashboard";

export const metadata: Metadata = {
  title: "Points — Forest Road Vault",
};

/** The three earning positions and their governance-set multiples (points-v2, live on Sepolia). */
const multiples = [
  { source: "sUSDfr staked", weight: "1× → 2×", note: "the base rate, you already earn yield" },
  { source: "USDfr held", weight: "3× → 6×", note: "in lieu of yield stakers receive" },
  { source: "Curator first-loss", weight: "5× → 10×", note: "the deepest, first-to-absorb risk" },
] as const;

const mechanics = [
  {
    title: "Time-weighted, not volume-based",
    body: "Points accrue as balance × time.",
  },
  {
    title: "Per wallet, linear by design",
    body: "Accrual is per wallet. No identity binding, no KYC needed to earn. Splitting a balance across addresses cannot increase the flat per-unit rate. Moving seasoned capital to a fresh wallet restarts that position's maturity ramp at 1×, so churn can only reduce its forward accrual.",
  },
  {
    title: "Flat rate, no size penalty",
    body: "Every unit earns the same per-unit rate. A large holder is never penalised for size. What sets your rate is the position type and maturity, not the amount.",
  },
];

/** Static SVG of the maturity ramp: 1.0× → 2.0× over 12 months, then flat. */
function MaturityRamp() {
  return (
    <svg viewBox="0 0 560 200" className="w-full" role="img" aria-label="Maturity multiplier ramps linearly from 1x to 2x over twelve months, then stays at 2x">
      <line x1="40" y1="160" x2="540" y2="160" stroke="var(--color-line-strong)" strokeWidth="1" />
      <line x1="40" y1="20" x2="40" y2="160" stroke="var(--color-line-strong)" strokeWidth="1" />
      <line x1="40" y1="40" x2="540" y2="40" stroke="var(--color-line)" strokeDasharray="3 5" strokeWidth="1" />
      <path d="M 40 160 L 340 40 L 540 40" fill="none" stroke="var(--color-accent)" strokeWidth="2.5" strokeLinejoin="round" />
      <path d="M 40 160 L 340 40 L 540 40 L 540 160 Z" fill="var(--color-accent-faint)" stroke="none" />
      <circle cx="340" cy="40" r="4" fill="var(--color-accent)" />
      <text x="34" y="164" textAnchor="end" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-body)">1.0×</text>
      <text x="34" y="44" textAnchor="end" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-body)">2.0×</text>
      <text x="340" y="182" textAnchor="middle" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-body)">12 months</text>
      <text x="540" y="182" textAnchor="end" fontSize="11" fill="var(--color-ink-faint)" fontFamily="var(--font-body)">time →</text>
    </svg>
  );
}

export default function PointsPage() {
  return (
    <PageShell
      bleed
      section="Points"
      title="Participation, measured over time"
      lede="Points track sustained participation: USDfr held, sUSDfr staked, and curator first-loss capital, each accruing per unit over time at its own multiple. They are not a token, not a promise of one, and not an implied return: any future utility is discretionary and subject to counsel review."
    >
      {/* ── Live wallet position. ───────────────────────────────────────── */}
      <PageBody tone="light">
        <PointsDashboard />
      </PageBody>

      {/* ── Accrual: prose against the ramp. ────────────────────────────── */}
      <Section tone="surface">
        <div className="flex flex-col gap-12 lg:flex-row lg:items-center lg:gap-16">
          <div className="lg:w-[45%] lg:flex-none">
            <SectionHead
              title={
                <>
                  Every position{" "}
                  <span className="display-accent">ramps up over a year.</span>
                </>
              }
            />
              <p className="mt-6 max-w-[64ch] text-[14px] leading-relaxed text-ink-muted">
                Each position&apos;s rate ramps up over 365 days: sUSDfr from
                1× to 2×, USDfr from 3× to 6×, and curator first-loss from
                5× to 10×. Adding new capital partially restarts the clock,
                in proportion to the amount added. Withdrawing never resets
                what remains; capital moved to a new wallet starts fresh.
              </p>
          </div>
          <div className="flex-1">
            <MaturityRamp />
          </div>
        </div>
      </Section>

      {/* ── The three multiples, as the numbers they are. ───────────────── */}
      <Section tone="navy">
        <SectionHead
          tone="navy"
          title="Deeper risk earns a higher multiple."
          lede="A curator is a first-loss investor: capital committed to absorb losses ahead of depositors. All three source multiples are bounded and governance-tunable. Changes apply going forward, never retroactively."
        />
        <div className="mt-12">
          <KpiBand
            items={multiples.map((m) => ({
              value: m.weight,
              label: m.source,
              note: m.note,
            }))}
            preserveLabelCase
            className="border border-navy-border"
          />
        </div>
      </Section>

      {/* ── Mechanics: three cards, three columns. ──────────────────────── */}
      <Section tone="light">
        <SectionHead
          title="What doesn't earn points."
          lede="The accrual rules are chosen so that churn, wallet-splitting and transaction volume cannot manufacture points."
        />
        <CardDeck columns={3} items={mechanics} />
      </Section>

      {/* ── Why the differential exists, plus the leaderboard state. ────── */}
      <Section tone="surface">
        <div className="flex flex-col gap-12 lg:flex-row lg:gap-16">
          <div className="lg:w-[42%] lg:flex-none">
            <SectionHead
              title="Why USDfr earns more than sUSDfr."
            />
          </div>
          <div className="flex-1">
              <p className="max-w-[64ch] text-[14.5px] leading-relaxed text-ink-muted">
                sUSDfr stakers already receive the protocol&apos;s variable yield, so
                their points start at the 1× base and mature to 2×. USDfr holders
                forgo that yield. They hold a plain, transferable dollar, so
                points compensate at a governance-set source multiple (3×→6× today){" "}
                <span className="text-ink">in lieu of yield</span>. Curator
                first-loss capital, which absorbs the very first dollar of any
                loss, earns the most (5×→10× today).
              </p>
            <div className="mt-8">
              <HighlightBox title="Leaderboard">
                Individual wallet points are fully on-chain and shown above. A
                global ranking requires an event indexer to discover the
                participant set; no leaderboard is published until that index is
                complete and independently reconcilable to PointsModule reads.
              </HighlightBox>
            </div>
          </div>
        </div>
      </Section>

      {/* ── The disclaimer, given the weight it deserves. ───────────────── */}
      <Section tone="navy-deep">
        <div className="flex flex-col gap-10 lg:flex-row lg:gap-20">
          <div className="lg:w-[40%] lg:flex-none">
            <SectionHead
              tone="navy-deep"
              title="What points are not."
            />
          </div>
          <div className="flex-1">
            <p className="max-w-[64ch] text-[15px] leading-relaxed text-on-navy-muted">
              Points are not a token, a security, a yield, or a claim on one.
              Nothing here promises conversion to any asset, and no conversion
              rate, date, or allocation exists. If Forest Road ever proposes a
              use for points, that decision is discretionary and passes through
              the same securities-counsel review that gates the rest of the
              protocol before mainnet.{" "}
              <span className="text-on-navy">
                Anyone telling you otherwise is not speaking for the protocol.
              </span>
            </p>
          </div>
        </div>
      </Section>
    </PageShell>
  );
}
