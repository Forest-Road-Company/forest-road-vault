import type { Metadata } from "next";
import { PageShell } from "@/components/site/PageShell";
import { Reveal } from "@/components/site/Reveal";

export const metadata: Metadata = {
  title: "How it works — Forest Road Vault",
};

const depositorSteps = [
  { t: "Connect & verify", d: "Connect a wallet. Minting and redeeming are KYC-gated; holding and viewing are open." },
  { t: "Mint USDfr", d: "Deposit an approved stablecoin, receive USDfr 1:1. Idle reserves sit in short-term instruments." },
  { t: "Stake to sUSDfr", d: "Deposit USDfr into the ERC-4626 vault and receive sUSDfr shares at the current exchange rate." },
  { t: "Net performance accrues", d: "Realized facility and reserve income enters the exchange rate, net of protocol fees. Credit losses and fee-share dilution can lower the per-share rate. Yield is variable, never promised." },
  { t: "Redeem via the queue", d: "Request redemption; the request joins an epoch-based FIFO queue and fills as liquidity allows. Then redeem USDfr back to stablecoin." },
] as const;

const borrowerSteps = [
  { t: "Apply & underwrite", d: "Forest Road underwrites each facility in-house. Collateral classes set LTV, maturity, and concentration limits on-chain; the interest rate and payment terms are signed per facility. Clean v1 has no DSRA reserve sizing." },
  { t: "Legal wrapper executes", d: "Off-chain: the receivable is assigned, the UCC-1 lien is filed, escrow is funded. Each fact is attested on-chain by authorized attesters." },
  { t: "Synchronized NFT mint", d: "The loan NFT mints only when every required off-chain attestation AND every on-chain condition holds. Escrow cannot release before the NFT exists." },
  { t: "Funding & servicing", d: "Capital deploys against the identified facility. Repayments route automatically: 10% of realized gross interest goes to the protocol at launch, then every remaining interest unit goes to senior sUSDfr." },
  { t: "Repayment — or remedy", d: "At maturity the facility repays and closes. In default: the NFT freezes, the waterfall accelerates, and the class's remedy path executes — legal foreclosure and secondary-market sale for the receivable classes; margin-call and collateral liquidation, on a much faster clock, for the marked-to-market digital-assets class." },
] as const;

function Steps({ steps }: { steps: readonly { t: string; d: string }[] }) {
  return (
    <ol className="mt-8 space-y-0">
      {steps.map((s, i) => (
        <li key={s.t} className="relative border-l border-line pb-8 pl-8 last:pb-0">
          <span className="absolute -left-[13px] top-0 flex h-[26px] w-[26px] items-center justify-center rounded-full border border-moss/40 bg-bg font-mono text-[11px] text-moss">
            {i + 1}
          </span>
          <h3 className="font-grotesk text-[16px] font-semibold tracking-tight text-ink">{s.t}</h3>
          <p className="mt-1.5 max-w-xl text-[14px] leading-relaxed text-ink-muted">{s.d}</p>
        </li>
      ))}
    </ol>
  );
}

export default function HowItWorksPage() {
  return (
    <PageShell
      eyebrow="How it works"
      title="Two flows, one synchronized system"
      lede="Depositors provide capital through a two-token model. Borrowers are financed against identified, lien-perfected collateral. Between them sits a dual record system: off-chain legal enforceability and on-chain transparency, kept in sync at every material event."
    >
      <div className="mt-14 grid gap-14 lg:grid-cols-2">
        <Reveal>
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-gold">For depositors</p>
            <Steps steps={depositorSteps} />
          </div>
        </Reveal>
        <Reveal delay={100}>
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.2em] text-moss">For borrowers</p>
            <Steps steps={borrowerSteps} />
          </div>
        </Reveal>
      </div>

      <Reveal>
        <div className="panel mt-8 p-8">
          <h2 className="font-grotesk text-xl font-semibold tracking-tight">
            Fee accounting
          </h2>
          <p className="mt-3 max-w-3xl text-[14px] leading-relaxed text-ink-muted">
            In addition to the 10% interest fee, sUSDfr charges 10% of
            performance-fee NAV profit above one protocol-wide high-water mark.
            Temporary curator and sGROVE capital can improve the redemption mark
            but is not counted as investment profit. Timelocked governance may
            change performance prospectively up to a 20% cap. Management starts
            at 0% and may change prospectively up to 2% per 365-day year. Each
            change crystallizes the old rate first. Vault fees mint shares to the
            protocol rather than remove backing assets.
          </p>
          <p className="mt-4 max-w-3xl text-[13px] leading-relaxed text-ink-faint">
            The high-water mark is global, not personal to your entry price. If
            you enter during a protocol drawdown, you share fee-free recovery to
            its old peak. Fees already crystallized are not clawed back after a
            later loss.
          </p>
        </div>
      </Reveal>

      <Reveal>
        <div className="panel mt-16 p-8">
          <h2 className="font-grotesk text-xl font-semibold tracking-tight">The dual record system</h2>
          <p className="mt-3 max-w-3xl text-[14px] leading-relaxed text-ink-muted">
            Every facility exists in two synchronized records. Off-chain: an SPV
            holds the position, the security interest is perfected (UCC-1 and
            assignment), cash moves through escrow and controlled accounts.
            On-chain: the loan NFT is the position of record, the lender
            register is reconstructable from events, and the payment waterfall
            runs automatically. Neither side may advance without the other —
            the NFT cannot mint until the legal facts are attested, and escrow
            cannot release until the NFT exists. In default, both act at once.
          </p>
          <p className="mt-4 max-w-3xl text-[13px] leading-relaxed text-ink-faint">
            Trust boundary, stated plainly: on-chain state reflects what
            authorized attesters assert about off-chain facts. If an
            attestation is false or an attester key is compromised, the
            protocol acts on false information. The attester set, signature
            scheme, and the roadmap toward reduced trust are documented
            openly.
          </p>
        </div>
      </Reveal>
    </PageShell>
  );
}
