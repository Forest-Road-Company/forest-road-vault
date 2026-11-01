import Link from "next/link";
import { ProtocolScene, type ProtocolSceneName } from "@/components/site/ProtocolScene";

const pages: Array<{
  href: string;
  title: string;
  copy: string;
  scene: ProtocolSceneName;
  signal: string;
}> = [
  {
    href: "/docs/overview",
    title: "Protocol overview",
    copy: "Follow reserve capital through two tokens, identified loans and returning cash.",
    scene: "capital",
    signal: "Capital path",
  },
  {
    href: "/transparency",
    title: "Live transparency",
    copy: "Reconcile supply, backing, reserves and the book against live contract state.",
    scene: "transparency",
    signal: "Backing invariant",
  },
  {
    href: "/how-it-works",
    title: "How the Vault works",
    copy: "Move from USDC to USDfr and sUSDfr, then exit through the cash-paced queue.",
    scene: "lifecycle",
    signal: "Position lifecycle",
  },
  {
    href: "/risk",
    title: "Risk factors",
    copy: "See where an attestation failure or realised loss enters—and the order it travels.",
    scene: "risk",
    signal: "Loss propagation",
  },
  {
    href: "/markets",
    title: "Borrow & lend",
    copy: "Lend USDC or post sUSDfr as collateral in the variable-rate Morpho market.",
    scene: "markets",
    signal: "Liquidity flow",
  },
  {
    href: "/sectors",
    title: "The three sectors",
    copy: "Three distinct collateral models feed one class-limited, identified loan book.",
    scene: "sectors",
    signal: "Collateral classes",
  },
];

export function PageAtlas() {
  return (
    <section className="page-atlas section-motion section-light" aria-labelledby="page-atlas-title">
      <div className="mx-auto max-w-6xl px-5 py-20 md:py-28">
        <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p className="scene-kicker"><i /> System map</p>
            <h2 id="page-atlas-title" className="display mt-5 max-w-[18ch] text-[31px] leading-[1.12] md:text-[46px]">
              One system, explained from every angle.
            </h2>
          </div>
          <p className="max-w-[54ch] text-[16px] leading-relaxed text-ink-muted">
            Every page below answers a different question about the same flow of capital. The motion changes because the mechanism changes: capital travels, backing reconciles, losses descend and liquidity turns.
          </p>
        </div>

        <div className="atlas-system mt-14">
          <div className="atlas-system__visual"><ProtocolScene scene="capital" /></div>
          <div className="atlas-system__copy">
            <p className="running-head text-accent">The complete loop</p>
            <h3 className="display mt-4 text-[27px] leading-tight">Reserve in. Credit out. Repayments home.</h3>
            <ol className="mt-7 space-y-5">
              <li><span>01</span><p><strong>Issue USDfr.</strong> USDC enters reserve and USDfr is minted only against recognized backing.</p></li>
              <li><span>02</span><p><strong>Put it to work.</strong> Staked USDfr finances named facilities after legal and on-chain records agree.</p></li>
              <li><span>03</span><p><strong>Return the cash.</strong> Principal and interest flow back through the waterfall, vault and redemption queue.</p></li>
            </ol>
            <Link href="/how-it-works" className="u-link mt-7 inline-flex text-[12px] font-semibold uppercase tracking-[.14em] text-accent">Trace the complete system →</Link>
          </div>
        </div>

        <div className="mt-6 grid gap-5 md:grid-cols-2 lg:grid-cols-3">
          {pages.map((page) => (
            <Link key={page.href} href={page.href} className="atlas-card atlas-card--semantic group">
              <span className="atlas-card__signal"><i />{page.signal}</span>
              <ProtocolScene scene={page.scene} compact />
              <span className="atlas-card__copy">
                <span className="display text-[22px] leading-tight">{page.title}</span>
                <span className="mt-2 block text-[13px] leading-relaxed">{page.copy}</span>
                <span className="mt-5 inline-flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[.14em]">Explore <span aria-hidden>↗</span></span>
              </span>
            </Link>
          ))}
        </div>
      </div>
    </section>
  );
}
