"use client";

import Link from "next/link";
import { useReadContracts } from "wagmi";
import { CONTRACTS } from "@/config/contracts";
import { BRIDGE_ABI, ERC20_ABI, RESERVES_ABI, VAULT_ABI } from "@/lib/abi";
import { fmtAmount } from "@/lib/format";
import { PROTOCOL_POLL } from "@/lib/polling";

export function HeroCapitalTrace() {
  return (
    <div className="hero-capital-trace" aria-hidden data-viewport-replay="">
      <svg viewBox="0 0 760 620" preserveAspectRatio="xMidYMid slice">
        <path className="hero-capital-trace__bed" d="M765 42C650 105 690 188 573 242S436 338 484 410 417 549 289 610" />
        <path className="hero-capital-trace__line" d="M765 42C650 105 690 188 573 242S436 338 484 410 417 549 289 610" />
      </svg>
      <span className="hero-capital-trace__pulse hero-capital-trace__pulse--one" />
      <span className="hero-capital-trace__pulse hero-capital-trace__pulse--two" />
      <span className="hero-capital-trace__label hero-capital-trace__label--one">reserve</span>
      <span className="hero-capital-trace__label hero-capital-trace__label--two">identified credit</span>
      <span className="hero-capital-trace__label hero-capital-trace__label--three">repayment</span>
    </div>
  );
}

export function TokenMechanics() {
  return (
    <div className="token-mechanics mt-16 grid gap-6 md:grid-cols-2">
      <article className="token-instrument token-instrument--usdfr" data-viewport-replay="" data-viewport-reveal="">
        <div className="token-instrument__head"><span>USDfr</span><small>The credit-backed unit</small></div>
        <h3 className="display mt-6 text-[26px] leading-tight">Backing moves with supply.</h3>
        <p className="mt-4 max-w-[42ch] text-[14.5px] leading-relaxed text-ink-muted">Minted 1:1 from USDC. Backing includes idle USDC and deployed loan principal; the contract refuses a mint that would put supply above recognized backing.</p>
        <div className="token-backing" aria-label="USDfr supply and backing rise together, with supply never greater than backing">
          <div><span>Supply</span><i><b /></i></div>
          <strong>≤</strong>
          <div><span>Backing</span><i><b /></i></div>
          <em><i /> invariant checked on every mint</em>
        </div>
        <Link href="/transparency" className="u-link mt-auto inline-flex pt-7 text-[12px] font-semibold uppercase tracking-[.14em] text-accent">Check the backing →</Link>
      </article>

      <article className="token-instrument token-instrument--susdfr" data-viewport-replay="" data-viewport-reveal="">
        <div className="token-instrument__head"><span>sUSDfr</span><small>The staked position</small></div>
        <h3 className="display mt-6 text-[26px] leading-tight">Net performance moves share value.</h3>
        <p className="mt-4 max-w-[42ch] text-[14.5px] leading-relaxed text-on-navy-muted">Stake USDfr into the vault. Its rate reflects book performance after fees and losses, and can fall if losses reach depositors.</p>
        <div className="token-income" aria-label="Illustrative share value path driven by realised book income">
          <svg viewBox="0 0 520 130" preserveAspectRatio="none" aria-hidden>
            <defs><linearGradient id="token-income-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#8eb0dc" stopOpacity=".3"/><stop offset="1" stopColor="#8eb0dc" stopOpacity="0"/></linearGradient></defs>
            <path className="token-income__fill" d="M0 112C70 108 102 96 151 91s72-18 112-28 75-1 118-20 70-19 139-31V130H0Z" />
            <path className="token-income__line" d="M0 112C70 108 102 96 151 91s72-18 112-28 75-1 118-20 70-19 139-31" />
          </svg>
          <span className="token-income__dot" /><small>net book performance</small>
        </div>
        <Link href="/app" className="u-link mt-auto inline-flex pt-7 text-[12px] font-semibold uppercase tracking-[.14em] text-on-navy-accent">View the live vault →</Link>
      </article>
    </div>
  );
}

const amount = (value: bigint | undefined, decimals = 18) => value === undefined ? "—" : fmtAmount(value, decimals, 0);

export function HomeTransparencyPreview() {
  const { data } = useReadContracts({
    query: PROTOCOL_POLL,
    contracts: [
      { address: CONTRACTS.USDfr!, abi: ERC20_ABI, functionName: "totalSupply" },
      { address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "totalBackingValue" },
      { address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "idleReserve" },
      { address: CONTRACTS.ReserveManager!, abi: RESERVES_ABI, functionName: "deployedPrincipal" },
      { address: CONTRACTS.sUSDfr!, abi: VAULT_ABI, functionName: "currentExchangeRate" },
      { address: CONTRACTS.ClaimBridge!, abi: BRIDGE_ABI, functionName: "totalOriginated" },
    ],
  });
  const value = (index: number) => data?.[index]?.result as bigint | undefined;
  const supply = value(0);
  const backing = value(1);
  const idle = value(2);
  const deployed = value(3);
  const rate = value(4);
  const facilities = value(5);
  const holding = supply !== undefined && backing !== undefined && supply <= backing;

  return (
    <div className="home-transparency">
      <div className="home-transparency__head">
        <div><p className="scene-kicker"><i /> Live contract state</p><h2 className="display mt-5 text-[31px] leading-[1.12] md:text-[46px]">Transparency should move at the speed of the book.</h2></div>
        <p>Supply, backing, deployed principal, the vault rate and facilities are public reads—not an off-chain summary.</p>
      </div>
      <div className="home-transparency__console" data-viewport-replay="" data-viewport-reveal="">
        <div className="home-transparency__status"><span><i /> {holding ? "Backing invariant holding" : "Read pending"}</span><b>SUPPLY ≤ BACKING</b></div>
        <div className="home-transparency__balance">
          <div><small>USDfr supply</small><strong>{amount(supply)}</strong><span><i style={{ width: holding ? "82%" : "42%" }} /></span></div>
          <em>≤</em>
          <div><small>Backing value</small><strong>${amount(backing)}</strong><span><i style={{ width: holding ? "82%" : "42%" }} /></span></div>
        </div>
        <div className="home-transparency__metrics">
          <div><small>Idle reserve</small><strong>${amount(idle)}</strong></div>
          <div><small>Deployed principal</small><strong>${amount(deployed)}</strong></div>
          <div><small>sUSDfr / USDfr</small><strong>{rate === undefined ? "—" : amount(rate, 18)}</strong></div>
          <div><small>Facilities originated</small><strong>{facilities?.toString() ?? "—"}</strong></div>
        </div>
      </div>
      <Link href="/transparency" className="rounded-pill bg-raised px-7 py-3 text-[14px] font-semibold text-navy transition-transform hover:-translate-y-0.5">Open the live book</Link>
    </div>
  );
}

export function OperateCards() {
  const cards = [
    { href: "/app", label: "Deposit", token: "USDC → USDfr", copy: "Mint only against verified backing.", scene: "mint" },
    { href: "/app#stake-card", label: "Stake", token: "USDfr → sUSDfr", copy: "Receive a share of actual book performance.", scene: "stake" },
    { href: "/app", label: "Redeem", token: "sUSDfr → queue", copy: "Exit in order as cash becomes available.", scene: "redeem" },
  ];
  return (
    <div className="operate-cards mt-14 grid gap-5 md:grid-cols-3">
      {cards.map((card, index) => <Link href={card.href} key={card.label} className={`operate-card operate-card--${card.scene}`} data-viewport-replay="">
        <span className="operate-card__index">0{index + 1}</span>
        <div className="operate-card__visual"><i /><i /><i /></div>
        <p className="running-head text-accent">{card.token}</p><h3 className="display mt-3 text-[24px]">{card.label}</h3><p className="mt-3 text-[14px] leading-relaxed text-ink-muted">{card.copy}</p><span className="operate-card__cta">Open surface ↗</span>
      </Link>)}
    </div>
  );
}
