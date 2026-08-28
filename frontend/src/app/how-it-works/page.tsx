import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import {
  Section,
  SectionHead,
  NumberedRows,
  FramTable,
  HighlightBox,
} from "@/components/site/Blocks";

export const metadata: Metadata = {
  title: "How it works | Forest Road Vault",
};

const depositorSteps = [
  { label: "Connect & verify", body: "Connect a wallet. Minting and redeeming are KYC-gated; holding and viewing are open." },
  { label: "Mint USDfr", body: "Deposit an approved stablecoin, receive USDfr 1:1. Idle reserves sit in short-term instruments." },
  { label: "Stake to sUSDfr", body: "Deposit USDfr into the ERC-4626 vault and receive sUSDfr shares at the current exchange rate." },
  { label: "Net performance accrues", body: "Realized facility and reserve income enters the exchange rate, net of protocol fees. Credit losses and fee-share dilution can lower the per-share rate. Yield is variable." },
  { label: "Redeem via the queue", body: "Request redemption; the request joins an epoch-based FIFO queue and fills as liquidity allows. Then redeem USDfr back to stablecoin." },
];

const borrowerSteps = [
  { label: "Apply & underwrite", body: "Forest Road underwrites each facility in-house. Collateral classes set LTV, maturity, and concentration limits on-chain; the interest rate and payment terms are signed per facility. Clean v1 has no DSRA reserve sizing." },
  { label: "Legal wrapper executes", body: "Off-chain: the receivable is assigned, the UCC-1 lien is filed, escrow is funded. Each fact is attested on-chain by authorized attesters." },
  { label: "Synchronized NFT mint", body: "The loan NFT mints only when every required off-chain attestation and every on-chain condition holds. Escrow cannot release before the NFT exists." },
  { label: "Funding & servicing", body: "Capital deploys against the identified facility. Repayments route automatically: 10% of realized gross interest goes to the protocol at launch, then every remaining interest unit goes to senior sUSDfr." },
  { label: "Repayment or remedy", body: "At maturity the facility repays and closes. In default: the NFT freezes, the waterfall accelerates, and the class's remedy path executes: legal foreclosure and secondary-market sale for the receivable classes; margin-call and collateral liquidation, on a much faster clock, for the marked-to-market digital-assets class." },
];

const feeRows = [
  { label: "Interest fee", value: "10% of realized gross interest at launch. Every remaining interest unit goes to senior sUSDfr." },
  { label: "Performance fee", value: "10% of NAV profit above one protocol-wide high-water mark. Timelocked governance may change this prospectively, up to a 20% cap." },
  { label: "Management fee", value: "Starts at 0%. May change prospectively up to 2% per 365-day year. Each change crystallizes the old rate first." },
  { label: "How fees are paid", value: "Vault fees mint shares to the protocol rather than remove backing assets." },
  { label: "High-water mark", value: "Global, not personal to your entry price. Enter during a drawdown and you share fee-free recovery to the old peak. Crystallized fees are not clawed back after a later loss." },
];

export default function HowItWorksPage() {
  return (
    <PageShell
      bleed
      section="How it works"
      title="Two flows, one synchronized system"
      lede="Depositors provide capital through a two-token model. Borrowers are financed against identified, lien-perfected collateral. Between them sits a dual record system: off-chain legal enforceability and on-chain transparency, kept in sync at every material event."
    >
      {/* ── Depositor flow: numbered rows on the light field. ───────────── */}
      <Section tone="surface">
        <SectionHead
          title="Capital in, performance out."
          lede="Two tokens keep the unit of account separate from the risk-bearing instrument. Nobody earns yield without knowingly holding the risk that generates it."
        />
        <NumberedRows
          heading="The depositor path, end to end."
          aside={
            <>
              Minting and redeeming are KYC-gated. Holding and viewing are open
              to anyone. Redemption is queued by epoch and fills as liquidity
              allows. It&apos;s never instant, because the underlying is real
              amortizing credit.
            </>
          }
          rows={depositorSteps}
        />
      </Section>

      {/* ── Borrower flow: same content shape, inverted tone, so the two
             halves of the system read as counterparts rather than a
             repeated block. ─────────────────────────────────────────────── */}
      <Section tone="navy">
        <SectionHead
          tone="navy"
          title="Underwritten in-house, financed on identified collateral."
          lede="No blind pool. Every facility is an identified borrower against a perfected claim, with a documented remedy path that executes on default."
        />
        <NumberedRows
          tone="navy"
          heading="The borrower path, end to end."
          aside={
            <>
              The loan NFT and the legal wrapper are gated on each other. The
              NFT cannot mint until every required attestation is on-chain, and
              escrow cannot release until the NFT exists. A facility cannot
              be funded on one record alone.
            </>
          }
          rows={borrowerSteps}
        />
      </Section>

      {/* ── Fees: a navy-header table, not another prose slab. ──────────── */}
      <Section tone="light">
        <SectionHead
          title="What the protocol takes, and when."
          lede="Fees are charged on realized performance, never on promised performance. Every rate below is prospective and capped."
        />
        <FramTable caption="Fee stack: sUSDfr" rows={feeRows} />
      </Section>

      {/* ── Dual record: split composition, not a full-width box. ───────── */}
      <Section tone="surface">
        <div className="flex flex-col gap-12 lg:flex-row lg:gap-20">
          <div className="lg:w-[42%] lg:flex-none">
            <SectionHead
              title={
                <>
                  Two records,{" "}
                  <span className="display-accent">neither advances alone.</span>
                </>
              }
            />
          </div>
          <div className="flex-1">
              <p className="max-w-[68ch] text-[15.5px] leading-relaxed text-ink-muted">
                Every facility exists in two synchronized records. Off-chain: an
                SPV holds the position: the security interest is perfected
                (UCC-1 and assignment), cash moves through escrow and controlled
                accounts. On-chain: the loan NFT is the position of record, the
                lender register is reconstructable from events, and the payment
                waterfall runs automatically. Neither side may advance without
                the other. The NFT cannot mint until the legal facts are
                attested, and escrow cannot release until the NFT exists. In
                default, both act at once.
              </p>
            <div className="mt-8">
              <HighlightBox title="Trust boundary, stated plainly">
                On-chain state reflects what authorized attesters assert about
                off-chain facts. If an attestation is false or an attester key
                is compromised, the protocol acts on false information. The
                attester set, signature scheme, and the roadmap toward reduced
                trust are documented openly.
              </HighlightBox>
            </div>
          </div>
        </div>
      </Section>
    </PageShell>
  );
}
