/** Display formatting for on-chain values. Pure helpers, no rounding tricks that
 *  could overstate a balance — truncation, not rounding up (honesty rule). */

import {formatUnits} from "viem";

/** Format a token amount, truncated (never rounded up) to `dp` decimals. */
export function fmtAmount(value: bigint, decimals: number, dp = 2): string {
  const s = formatUnits(value, decimals);
  const [int, frac = ""] = s.split(".");
  const intFmt = BigInt(int).toLocaleString("en-US");
  if (dp === 0) return intFmt;
  const fracCut = frac.slice(0, dp).replace(/0+$/, "");
  return fracCut ? `${intFmt}.${fracCut}` : intFmt;
}

export function shortAddress(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/** Seconds → "3d 4h" / "2h 10m" / "<1m" / "now". */
export function fmtCountdown(seconds: number): string {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86_400);
  const h = Math.floor((seconds % 86_400) / 3_600);
  const m = Math.floor((seconds % 3_600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  // A sub-minute remainder must not render as "0m": on the redemption card that sits
  // beside a hard lock-up and reads as "no wait" when the wait is simply under a minute.
  if (m === 0) return "<1m";
  return `${m}m`;
}
