import type { Metadata } from "next";
import { pageMetadata } from "@/lib/shareCards";
import Image from "next/image";
import { PointsDashboard } from "@/components/app/PointsDashboard";
import { PointsLeaderboard } from "@/components/app/PointsLeaderboard";
import { PointsHeroStage, PointsMaturityLab, PointsRuleExperiments } from "@/components/site/PointsVisuals";
import { IS_MAINNET } from "@/config/contracts";

export const metadata: Metadata = pageMetadata({
  title: "Points | Forest Road Vault",
  description: "Points measure sustained participation in USDfr, sUSDfr and curator first-loss capital over time.",
  socialTitle: "Participation, measured over time | Forest Road Vault",
});

const positions = [
  { name: "sUSDfr staked", range: "1× → 2×", copy: "Stakers already receive the vault’s variable income." },
  { name: "USDfr held", range: "3× → 6×", copy: "Holders forgo staking income, so participation carries more weight." },
  { name: "Curator first-loss", range: "5× → 10×", copy: "Capital absorbing the first realised loss receives the highest weight." },
] as const;

export default function PointsPage() {
  return (
    <div className="points-experience">
      <section className="points-main-hero" data-viewport-replay="">
        <div className="points-main-hero__field" aria-hidden />
        <div className="mx-auto grid max-w-6xl gap-12 px-5 py-20 lg:grid-cols-[.95fr_1.05fr] lg:items-center lg:py-28">
          <div>
            <p className="scene-kicker"><i /> On-chain participation</p>
            <h1 className="display mt-7 max-w-[10ch] text-[clamp(3.1rem,7vw,5.3rem)] leading-[1.04]">Participation, <span className="display-accent">measured</span> over time.</h1>
            <p className="mt-7 max-w-[48ch] text-[17px] leading-relaxed text-ink-muted">Points track how long capital stays in the vault. USDfr held, sUSDfr staked and curator first-loss capital accrue every block at their own multiple.</p>
            <div className="mt-8 flex flex-wrap items-center gap-4">
              <a href="#wallet-ledger" className="rounded-pill bg-navy px-6 py-3 text-[13px] font-semibold text-white transition-transform hover:-translate-y-0.5">Check my points</a>
              <a href="#accrual" className="u-link text-[13px] font-semibold text-ink">See how points accrue →</a>
            </div>
            <p className="mt-4 text-[13px] text-ink-faint">Read-only. Connecting never requests a transaction.</p>
          </div>
          <PointsHeroStage />
        </div>
      </section>

      <section id="wallet-ledger" className="points-wallet-section scroll-mt-24">
        <div className="mx-auto max-w-6xl px-5 py-20 md:py-28">
          <div className="points-section-head points-section-head--center">
            <p>Live wallet read</p><h2 className="display">Connect to inspect your ledger.</h2><span>The read is public and transaction-free. Connecting neither starts nor resets accrual.</span>
          </div>
          <PointsDashboard />
        </div>
      </section>

      <section id="accrual" className="points-accrual scroll-mt-24">
        <div className="mx-auto max-w-6xl px-5 py-20 md:py-28">
          <p className="scene-kicker"><i /> Accrual model</p>
          <h2 className="display mt-6 max-w-[17ch] text-[clamp(2.5rem,5vw,4.3rem)] leading-[1.06]">Forgone yield and first loss earn more.</h2>
          <p className="mt-6 max-w-[64ch] text-[16px] leading-relaxed text-ink-muted">Each position begins at its base multiple and climbs in a straight line for 365 days, ending at double. Move the timeline to inspect the exact relationship.</p>
          <div className="points-accrual__grid mt-14">
            <div className="points-position-list">
              {positions.map((position)=><div key={position.name}><p><strong>{position.name}</strong><span>{position.range}</span></p><small>{position.copy}</small></div>)}
            </div>
            <PointsMaturityLab />
          </div>
        </div>
      </section>

      <section id="community" className="points-community scroll-mt-24" data-viewport-replay="">
        <div className="mx-auto grid max-w-6xl gap-12 px-5 py-20 lg:grid-cols-[1.15fr_.85fr] lg:items-center md:py-24">
          <div><p className="scene-kicker"><i /> A separate participation record</p><h2 className="display mt-6 text-[clamp(2.6rem,5vw,4.3rem)] text-white">Community points.</h2><p className="mt-6 max-w-[60ch] text-[16px] leading-relaxed text-on-navy-muted">Sign in with X, complete verified campaign tasks, invite others and take part in the weekly race. Community points remain separate from the on-chain ledger above.</p><div className="mt-8 flex flex-wrap items-center gap-6"><a href="https://points.forestroadvault.com/enter" className="rounded-pill bg-white px-6 py-3 text-[13px] font-semibold text-navy">Enter the points app →</a><a href="https://points.forestroadvault.com/switch-x" className="u-link text-[13px] text-on-navy-muted">Lost access to X?</a></div></div>
          <div className="points-community__card"><div><small>All-time tasks</small><strong>Verified</strong><p>X actions, Discord membership and qualified referrals.</p></div><div><small>Weekly race</small><strong>Monday—Monday</strong><p>Social and protocol scores, with a rank multiplier.</p></div><span>Verified activity and live standings use the points app’s production verification flows.</span></div>
        </div>
      </section>

      <section id="leaderboard" className="points-ledger-dark scroll-mt-24" data-viewport-replay="">
        <div className="mx-auto max-w-6xl px-5 py-20 md:py-28">
          <div className="points-ledger-dark__head">
            <div><p className="scene-kicker"><i /> Reconciled protocol standings</p><h2 className="display mt-6 text-[clamp(2.7rem,5vw,4.5rem)] text-white">Leaderboard.</h2><p>Wallets ranked by PointsModule points plus enabled Forest Road Pendle and Morpho pass-through calculations. Protocol wallets and pooled venue contracts are shown separately.</p></div>
            <span><i /> Live Ethereum ledger</span>
          </div>
          {!IS_MAINNET ? <p className="points-ledger-dark__network-note">This staging build operates on Sepolia; the ranking below is the read-only live Ethereum board from points.forestroadvault.com.</p> : null}
          <div className="mt-8"><PointsLeaderboard endpoint={IS_MAINNET ? "/api/points/leaderboard" : "/api/points/live-leaderboard"} /></div>
        </div>
      </section>

      <section id="rules" className="points-rules-section scroll-mt-24">
        <div className="mx-auto max-w-6xl px-5 py-20 md:py-28">
          <div className="points-section-head points-section-head--center"><p>Simple by design</p><h2 className="display">What doesn’t earn points.</h2><span>The model rewards committed capital and time—not activity for activity’s sake.</span></div>
          <div className="points-formula"><span>points</span><b>=</b><span>balance</span><b>×</b><span>time</span><b>×</b><span>multiple</span></div>
          <PointsRuleExperiments />
        </div>
      </section>

      <section className="points-why">
        <div className="mx-auto grid max-w-6xl gap-12 px-5 py-20 lg:grid-cols-[.8fr_1.2fr] md:py-24">
          <h2 className="display text-[clamp(2.2rem,4vw,3.6rem)] leading-[1.08]">Why USDfr earns more than sUSDfr.</h2>
          <div className="points-why__copy"><p>sUSDfr stakers already receive the protocol’s variable yield, so their points start at the 1× base and mature to 2×. USDfr holders forgo that yield. They hold a plain, transferable dollar, so points compensate at a governance-set source multiple—3× to 6× today—in lieu of yield. Curator first-loss capital absorbs the first dollar of loss and earns the most.</p><aside><strong>One linear formula.</strong><span>Adding capital partially restarts the clock in proportion to the amount added. Withdrawing never resets what remains; moving capital to a fresh wallet starts it at day zero.</span></aside></div>
        </div>
      </section>

      <section id="disclosure" className="points-disclosure scroll-mt-24" data-viewport-replay="">
        <Image src="/brand/hero-cover.jpg" alt="" fill sizes="100vw" className="points-disclosure__image" aria-hidden />
        <div className="points-disclosure__grade" aria-hidden />
        <div className="relative z-10 mx-auto grid max-w-6xl gap-10 px-5 py-20 lg:grid-cols-[1.25fr_.75fr] md:py-24">
          <div><p className="running-head text-on-navy-accent">Plain-language disclosure</p><h2 className="display mt-5 text-[clamp(2.5rem,5vw,4.2rem)] text-white">What points are not.</h2><p className="mt-6 max-w-[65ch] text-[15px] leading-relaxed text-on-navy-muted">Points are not a token, a security, a yield, or a claim on one. Nothing here promises conversion to any asset, and no conversion rate, date or allocation exists. Any future use would be discretionary and subject to securities-counsel review.</p><strong className="mt-6 block text-white">Anyone telling you otherwise is not speaking for the protocol.</strong></div>
          <div className="points-disclosure__card"><p className="running-head text-on-navy-accent">Community points</p><h3 className="display mt-4 text-[29px] leading-tight text-white">Participation beyond the on-chain ledger.</h3><p className="mt-5 text-[13px] leading-relaxed text-on-navy-muted">Verified X tasks, qualified referrals and the weekly race live in the points app.</p><a href="https://points.forestroadvault.com/enter" className="u-link mt-7 inline-flex text-[13px] font-semibold text-white">Open the app →</a></div>
        </div>
      </section>
    </div>
  );
}
