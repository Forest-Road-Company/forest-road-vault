import type { Metadata } from "next";
import Link from "next/link";
import { PageShell } from "@/components/site/PageShell";
import {
  Section,
  SectionHead,
  KpiBand,
  CardDeck,
  NumberedRows,
  HighlightBox,
} from "@/components/site/Blocks";
import { CuratorInterestForm } from "./CuratorInterestForm";
import { CuratorVaultSection } from "./CuratorVaultSection";

export const metadata: Metadata = {
  title: "Curators | Forest Road Vault",
  description:
    "Curator capital stands first in line for losses on the Forest Road Vault credit book. How the programme works, what it earns in points, and how to register interest.",
};

/* COPY RULES. This page describes a programme run under bilateral agreements with Forest Road.
   It states no rate, no yield and no return, and it does not characterise any instrument; the
   agreement governs and counsel clears any addition to this copy (brief Part 0.5, CLAUDE.md
   directive 6). The points figures and their wording are the ones the /points page carries. */

const facts = [
  {
    value: "First",
    label: "in line for losses",
    note: "layer one of the three-layer cascade, ahead of the sGROVE backstop and ahead of sUSDfr",
  },
  {
    value: "5× → 10×",
    label: "points multiple",
    note: "the curator source multiple, maturing over 365 days; bounded and governance-tunable",
  },
  {
    value: "3 months",
    label: "minimum commitment",
    note: "and three months' notice to withdraw, under the agreement",
  },
  {
    value: "Solana and Ethereum",
    label: "subscriptions first",
    note: "Ethereum is live today through the CuratorModule; Solana through the subscription vault; Canton to follow",
  },
] as const;

const role = [
  {
    title: "Capital that absorbs the first dollar of loss",
    body: "Curator capital is posted per collateral class into the CuratorModule on the Ethereum instance. When a facility in that class realises a loss, curator capital absorbs it before the sGROVE backstop and before any sUSDfr holder is impaired. Senior capital is never subordinated to it.",
  },
  {
    title: "It cannot leave from under a live book",
    body: "Withdrawals are capped at the headroom above live exposure and freeze while any default in the class is unresolved or any custody incident is open. The rules are on chain and the same for every curator, including Forest Road.",
  },
  {
    title: "Forest Road is the anchor curator",
    body: "Forest Road originates, underwrites and services every facility in house and posts first-loss capital itself. Capital committed under this programme funds that position; Forest Road remains the party that posts, holds and withdraws it on chain.",
  },
];

const steps = [
  {
    label: "Register interest",
    body: "The form below. It records a contact and a preference and commits nothing.",
  },
  {
    label: "Eligibility and identity checks",
    body: "Forest Road confirms eligibility for your jurisdiction and completes know-your-customer checks through its provider. No wallet is approved before this is done.",
  },
  {
    label: "The agreement",
    body: "A bilateral agreement between you and Forest Road sets the commercial terms, the minimum commitment period, the notice period and what happens on a loss. It is the governing document; nothing on this page is.",
  },
  {
    label: "Subscription",
    body: "Ethereum-native curators post USDfr into the CuratorModule, which is live, from this page once governance has approved their wallet for a class. Solana-native curators subscribe on this page through a dedicated vault program that records principal, commitment and notice on chain and pays under the agreement; it is audited before it takes a mainnet deposit.",
  },
];

export default function CuratorsPage() {
  return (
    <PageShell
      bleed
      section="Curators"
      title="Capital that stands first in line"
      lede="Curators commit capital that absorbs losses on the credit book before anyone else. Forest Road runs the programme under bilateral agreements with approved curators. This page describes it and takes registrations of interest; it is not an offer."
    >
      {/* ── The facts, as numbers. ──────────────────────────────────────── */}
      <Section tone="navy">
        <KpiBand items={facts.map((f) => ({ value: f.value, label: f.label, note: f.note }))} preserveLabelCase />
      </Section>

      {/* ── What a curator is, here. ─────────────────────────────────────── */}
      <Section tone="light">
        <SectionHead
          title={
            <>
              A curator is a{" "}
              <span className="display-accent">first-loss investor.</span>
            </>
          }
          lede="The three-layer loss cascade is the protocol's safety spec: curator first-loss, then the sGROVE backstop, then sUSDfr principal, in that order and never inverted. Curator capital is the first layer."
        />
        <CardDeck columns={3} items={role} />
        <p className="mt-10 max-w-[64ch] text-[14px] leading-relaxed text-ink-muted">
          The mechanics are documented in full on{" "}
          <Link href="/how-it-works" className="text-accent underline-offset-4 hover:underline">
            How it works
          </Link>{" "}
          and in the{" "}
          <Link href="/docs" className="text-accent underline-offset-4 hover:underline">
            protocol docs
          </Link>
          ; the live curator position per class is on{" "}
          <Link href="/transparency" className="text-accent underline-offset-4 hover:underline">
            Transparency
          </Link>
          .
        </p>
      </Section>

      {/* ── Points, in the /points page's words. ────────────────────────── */}
      <Section tone="surface">
        <div className="flex flex-col gap-12 lg:flex-row lg:gap-16">
          <div className="lg:w-[42%] lg:flex-none">
            <SectionHead
              title={
                <>
                  Deeper risk earns the{" "}
                  <span className="display-accent">highest multiple.</span>
                </>
              }
            />
          </div>
          <div className="flex-1">
            <p className="max-w-[64ch] text-[14.5px] leading-relaxed text-ink-muted">
              Points track sustained participation. sUSDfr stakers already receive the
              protocol&apos;s variable yield, so their points start at the 1× base and mature to
              2×. USDfr holders forgo that yield and earn 3× to 6× in lieu of it. Curator
              first-loss capital, which absorbs the very first dollar of any loss, earns the
              most: <span className="text-ink">5× today, maturing to 10× over 365 days</span>.
              All three multiples are bounded and governance-tunable; changes apply going
              forward, never retroactively.
            </p>
            <p className="mt-4 max-w-[64ch] text-[14.5px] leading-relaxed text-ink-muted">
              Points represent live first-loss capital, not the amount originally posted: when a
              class absorbs a loss, the affected positions freeze at the loss and resume on what
              remains. Points are not a token, not a promise of one, and not an implied return;
              any future utility is discretionary and subject to counsel review.
            </p>
            <div className="mt-8">
              <HighlightBox title="Where the numbers come from">
                The multiples and the maturity ramp are parameters of the on-chain PointsModule,
                described on the{" "}
                <Link href="/points" className="text-accent underline-offset-4 hover:underline">
                  Points
                </Link>{" "}
                page. Positions subscribed through the Solana vault will be scored by the same
                formula from the vault&apos;s own event log and shown separately until the two
                ledgers are reconciled in one index.
              </HighlightBox>
            </div>
          </div>
        </div>
      </Section>

      {/* ── How joining works. ──────────────────────────────────────────── */}
      <Section tone="light">
        <NumberedRows
          heading="How the programme works."
          aside="Four steps, none of which happens on this page except the first."
          rows={steps}
        />
      </Section>

      {/* ── Your position: the wallet surface for approved curators. ──── */}
      <CuratorVaultSection />

      {/* ── Register interest. ─────────────────────────────────────────── */}
      <Section tone="surface" id="register">
        <div className="flex flex-col gap-12 lg:flex-row lg:gap-16">
          <div className="lg:w-[42%] lg:flex-none">
            <SectionHead
              title="Register interest."
              lede="Tell us where your capital sits and roughly how much. Forest Road follows up on eligibility; terms are settled directly and in writing."
            />
            <div className="mt-8">
              <HighlightBox title="What this is not">
                Not an offer, not a solicitation, and not a place to deposit. Whether any
                instrument in this programme is a security is a matter for counsel; nothing here
                is legal, tax or investment advice.
              </HighlightBox>
            </div>
          </div>
          <div className="flex-1">
            <CuratorInterestForm />
          </div>
        </div>
      </Section>
    </PageShell>
  );
}
