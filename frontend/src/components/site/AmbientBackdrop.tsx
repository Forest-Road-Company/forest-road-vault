import type { CSSProperties } from "react";

/**
 * A single persistent atmosphere for the whole site. Root layouts survive App
 * Router navigation, so these slow paths keep their phase while page content
 * crossfades above them instead of visibly restarting on every route.
 */
export function AmbientBackdrop() {
  return (
    <div
      className="ambient-continuum"
      style={{ viewTransitionName: "ambient-continuum" } as CSSProperties}
      aria-hidden
    >
      <span className="ambient-continuum__wash ambient-continuum__wash--one" />
      <span className="ambient-continuum__wash ambient-continuum__wash--two" />
      <span className="ambient-continuum__scan" />
      <svg
        className="ambient-continuum__paths"
        viewBox="0 0 1600 1000"
        preserveAspectRatio="xMidYMid slice"
      >
        <path d="M-120 790C160 790 176 620 414 620H662C822 620 828 454 1002 454H1278C1448 454 1486 308 1730 308" />
        <path d="M-180 244H228C382 244 394 386 548 386H858C1010 386 1018 684 1194 684H1770" />
        <path d="M340-80V190C340 310 478 320 478 454V840C478 950 620 962 620 1080" />
        <g className="ambient-continuum__nodes">
          <circle cx="228" cy="244" r="4" />
          <circle cx="548" cy="386" r="4" />
          <circle cx="1002" cy="454" r="4" />
          <circle cx="1194" cy="684" r="4" />
          <circle cx="414" cy="620" r="4" />
        </g>
      </svg>
      <span className="ambient-continuum__ledger ambient-continuum__ledger--one">SUPPLY ≤ BACKING</span>
      <span className="ambient-continuum__ledger ambient-continuum__ledger--two">OFF-CHAIN ↔ ON-CHAIN</span>
    </div>
  );
}
