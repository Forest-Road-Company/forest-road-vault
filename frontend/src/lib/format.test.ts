import {describe, expect, it} from "vitest";
import {fmtAmount, fmtCountdown} from "@/lib/format";

describe("fmtAmount", () => {
  it("truncates positive values without rounding up", () => {
    expect(fmtAmount(1_999_999_999_999_999_999n, 18, 2)).toBe("1.99");
    expect(fmtAmount(1_043_965_000_000_000_000n, 18, 4)).toBe("1.0439");
    expect(fmtAmount(1_043_965_000_000_000_000n, 18, 0)).toBe("1");
  });

  it("preserves negative signs for values in (-1, 0) and drops negative zero", () => {
    expect(fmtAmount(-500_000_000_000_000_000n, 18, 2)).toBe("-0.5");
    expect(fmtAmount(-123_400_000_000_000_000n, 18, 4)).toBe("-0.1234");
    expect(fmtAmount(-1_500_000_000_000_000_000n, 18, 2)).toBe("-1.5");
    // Truncates to zero at dp=2 -> must not display "-0"
    expect(fmtAmount(-1_000_000_000_000n, 18, 2)).toBe("0");
    expect(fmtAmount(0n, 18, 2)).toBe("0");
  });
});

describe("fmtCountdown", () => {
  it("formats sub-minute, hours, days, and elapsed durations", () => {
    expect(fmtCountdown(0)).toBe("now");
    expect(fmtCountdown(-5)).toBe("now");
    expect(fmtCountdown(45)).toBe("<1m");
    expect(fmtCountdown(3_720)).toBe("1h 2m");
    expect(fmtCountdown(90_000)).toBe("1d 1h");
  });
});
