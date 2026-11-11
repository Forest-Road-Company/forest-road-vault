"use client";

import { useMemo, useState, type CSSProperties } from "react";

const position = (day: number, start: number) => start * (1 + day / 365);

export function PointsHeroStage() {
  const positions = [
    { label: "sUSDfr", range: "1× → 2×", level: "31%", value: "1.00×", tone: "light" },
    { label: "USDfr", range: "3× → 6×", level: "55%", value: "3.00×", tone: "mid" },
    { label: "Curator first-loss", range: "5× → 10×", level: "82%", value: "5.01×", tone: "deep" },
  ];
  return (
    <figure className="points-hero-stage" aria-label="Three points positions begin at different source multiples and mature over 365 days" data-viewport-replay="">
      <div className="points-hero-stage__head"><span>365-day maturity ramp</span><b><i /> day 1 · every block</b></div>
      <div className="points-hero-stage__vessels">
        {positions.map((item, index) => <div key={item.label} className="points-hero-stage__item">
          <strong>{item.value}</strong>
          <span className={`points-beaker points-beaker--${item.tone}`}><i style={{ "--points-level": item.level } as CSSProperties} /><b /></span>
          <em>{item.label}</em><small>{item.range}</small>
          <u style={{ animationDelay: `${index * -1.8}s` }} />
        </div>)}
      </div>
    </figure>
  );
}

export function PointsMaturityLab() {
  const [day, setDay] = useState(142);
  const factors = useMemo(() => [1, 3, 5].map((base) => position(day, base)), [day]);
  const x = 54 + (day / 365) * 536;
  const y = (value: number) => 254 - (value / 10) * 205;
  const colors = ["#8eb9d7", "#5d83bd", "#203c63"];
  return (
    <div className="points-maturity-lab" data-viewport-replay="" data-viewport-reveal="">
      <div className="points-maturity-lab__head">
        <div><p>Maturity multiplier</p><strong>Day {day} of 365</strong></div>
        <div>{[[0,"Day 0"],[142,"Example"],[365,"Day 365"]].map(([value,label])=><button key={label} type="button" onClick={()=>setDay(Number(value))} aria-pressed={day===value}>{label}</button>)}</div>
      </div>
      {/* The axis labels are HTML over the drawing rather than SVG text: the drawing scales with its
          column, and on a phone SVG text would shrink with it to about half its size. */}
      <div className="points-maturity-lab__chart">
        <svg viewBox="0 0 640 290" role="img" aria-label={`At day ${day}, sUSDfr earns ${factors[0].toFixed(2)} times, USDfr earns ${factors[1].toFixed(2)} times and curator capital earns ${factors[2].toFixed(2)} times`}>
          {[0,2,4,6,8,10].map((tick)=><line key={tick} x1="54" x2="590" y1={y(tick)} y2={y(tick)} />)}
          {[1,3,5].map((base,index)=><g key={base}><path d={`M54 ${y(base)} L${x} ${y(factors[index])}`} style={{stroke:colors[index]}} /><circle cx={x} cy={y(factors[index])} r="4" style={{fill:colors[index]}} /></g>)}
          <line className="points-maturity-lab__cursor" x1={x} x2={x} y1="38" y2="254" />
        </svg>
        <div className="points-maturity-lab__axis" aria-hidden>
          {[0,2,4,6,8,10].map((tick)=><span key={tick} style={{right: `${100 - (44 / 640) * 100}%`, top: `${(y(tick) / 290) * 100}%`}}>{tick}×</span>)}
          <span style={{left: `${(54 / 640) * 100}%`, top: `${(275 / 290) * 100}%`}}>0</span>
          <span style={{right: `${100 - (590 / 640) * 100}%`, top: `${(275 / 290) * 100}%`}}>365 days</span>
        </div>
      </div>
      <label><span>Move through the first year</span><input type="range" min="0" max="365" value={day} onChange={(event)=>setDay(Number(event.target.value))} /></label>
      <dl>{[["sUSDfr",factors[0]],["USDfr",factors[1]],["Curator",factors[2]]].map(([label,value])=><div key={String(label)}><dt>{label}</dt><dd>{Number(value).toFixed(2)}×</dd></div>)}</dl>
    </div>
  );
}

type Rule = { title: string; copy: string; kind: "volume" | "split" | "size" };
const rules: Rule[] = [
  { title: "Volume", copy: "Trading in and out adds nothing. Only balance held over time accrues.", kind: "volume" },
  { title: "Wallet-splitting", copy: "Two wallets earn exactly what one wallet would; moving restarts the new wallet’s ramp.", kind: "split" },
  { title: "Size", copy: "Every unit earns the same per-unit rate. Position type and time—not size—set the rate.", kind: "size" },
];

function RuleExperiment({ rule }: { rule: Rule }) {
  const labels = rule.kind === "volume" ? ["Held", "Traded"] : rule.kind === "split" ? ["One wallet", "Split in two"] : ["Small", "Large"];
  return <article className={`points-rule points-rule--${rule.kind}`} data-viewport-replay="">
    <div className="points-rule__lab">
      <span className="points-rule__beaker points-rule__beaker--a"><i /><b /></span>
      <span className="points-rule__beaker points-rule__beaker--b"><i /><b /></span>
      <em>{labels[0]}</em><em>{labels[1]}</em>
      <u />
    </div>
    <h3 className="display text-[24px]">{rule.title}</h3><p>{rule.copy}</p>
  </article>;
}

export function PointsRuleExperiments() {
  const [replay, setReplay] = useState(0);
  return (
    <div className="points-rules">
      <div className="points-rules__actions"><button type="button" onClick={()=>setReplay((value)=>value+1)}>Replay experiments ↻</button></div>
      <div className="points-rules__grid" key={replay}>{rules.map((rule)=><RuleExperiment key={rule.title} rule={rule} />)}</div>
    </div>
  );
}
