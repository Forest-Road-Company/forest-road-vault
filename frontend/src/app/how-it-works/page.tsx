import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import {
  Section,
  SectionHead,
  NumberedRows,
  FramTable,
} from "@/components/site/Blocks";

export const metadata: Metadata = {
  title: "How it works | Forest Road Vault",
};

const depositorSteps = [
  { label: "Connect & verify", body: "Connect a wallet. Minting and redeeming are KYC-gated; holding and viewing are open." },
  { label: "Mint USDfr", body: "Deposit an approved stablecoin, receive USDfr 1:1. Idle reserves sit in short-term instruments." },
  { label: "Stake to sUSDfr", body: "Deposit USDfr into the ERC-4626 vault and receive sUSDfr shares at the current exchange rate." },
  { label: "Net performance accrues", body: "Realized facility and reserve income enters the exchange rate, net of protocol fees. Credit losses can lower the per-share rate. Yield is variable." },
  { label: "Redeem via the queue", body: "Request redemption. Requests join the redemption queue, which settles in fixed windows (epochs), first in, first out, as loan repayments come in. Then redeem USDfr back to stablecoin." },
];

const borrowerSteps = [
  { label: "Apply & underwrite", body: "Forest Road underwrites each facility in-house. Sectors set LTV, maturity, and concentration limits on-chain; the interest rate and payment terms are signed per facility." },
  { label: "Legal wrapper executes", body: "Off-chain: the receivable is assigned, the UCC-1 lien is filed, escrow is funded. Each fact is recorded on-chain by authorized attesters: named parties who certify off-chain facts to the contracts." },
  { label: "Synchronized NFT mint", body: "Each loan is recorded on-chain as an identified position, the loan NFT. It mints only when every required off-chain attestation and every on-chain condition holds, and escrow cannot release before it exists." },
  { label: "Funding & servicing", body: "Capital deploys against the identified facility. Repayments route automatically through a fixed order of priority written into the contract." },
  { label: "Repayment or remedy", body: "At maturity the facility repays and closes. In default, the facility freezes and the sector's documented remedy path executes." },
];

const feeRows = [
  { label: "Origination fee", value: "Proposed: up to 2% of funded principal, charged once when a facility is funded." },
  { label: "Share of interest", value: "Proposed: up to 10% of gross interest received. The balance goes to sUSDfr stakers." },
  { label: "Performance fee", value: "10% of vault profit above one protocol-wide high-water mark. Timelocked governance may change this prospectively, up to a 20% cap." },
  { label: "Management fee", value: "Starts at 0%. May change prospectively up to 2% per 365-day year. Each change locks in fees owed at the old rate first." },
  { label: "How fees are paid", value: "Vault fees mint shares to the protocol rather than remove backing assets." },
  { label: "High-water mark", value: "Global, not personal to your entry price. Enter during a drawdown and you share fee-free recovery to the old peak. Crystallized fees are not clawed back after a later loss." },
];

export default function HowItWorksPage() {
  return (
    <PageShell
      bleed
      section="How it works"
      title="How the Vault works"
      lede="Depositors provide capital through two tokens. Borrowers are financed against specific, named collateral. Between them sits a dual record: legally enforceable off-chain, visible on-chain, kept in sync."
    >
      {/* ── Depositor flow: numbered rows on the light field. ───────────── */}
      <Section tone="surface">
        <SectionHead
          title="How depositors earn"
          lede="Two tokens keep the stable dollar separate from the investment. Hold USDfr as a dollar, or stake it into sUSDfr and get invested in the loan book."
        />
        <NumberedRows
          heading="The depositor path, end to end."
          aside={
            <>
              Minting and redeeming are KYC-gated. Holding and viewing are open
              to anyone. Redemption settles in fixed windows called epochs,
              first in, first out, paced by the cash the book receives.
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
          title="How loans are made"
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
          lede="Fees are charged on realized performance, not on projections. Every rate below is prospective and capped. Final fees are set in definitive documents and may vary by sector and facility."
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
                  <span className="display-accent">always in step.</span>
                </>
              }
            />
          </div>
          <div className="flex-1">
              <p className="max-w-[68ch] text-[15.5px] leading-relaxed text-ink-muted">
                Every facility exists in two synchronized records. Off-chain: an
                SPV holds the position, the security interest is perfected
                (UCC-1 and assignment), cash moves through escrow and controlled
                accounts. On-chain: the loan NFT is the position of record, the
                lender register is reconstructable from events, and the payment
                waterfall runs automatically. Neither side may advance without
                the other. The NFT cannot mint until the legal facts are
                attested, and escrow cannot release until the NFT exists. In
                default, both act at once.
              </p>
          </div>
        </div>
      </Section>
    </PageShell>
  );
}
