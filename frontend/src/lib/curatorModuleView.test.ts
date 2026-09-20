import {describe, expect, it} from "vitest";
import {classNotice, needsAllowance, withdrawableNow} from "./curatorModuleView";

const base = {posted: 100n, pool: 250n, required: 60n, headroom: 190n, unresolvedDefaults: 0n};

describe("withdrawableNow", () => {
  it("is the wallet's own posting when the class has headroom for all of it", () => {
    expect(withdrawableNow(base)).toBe(100n);
  });
  it("is capped by the class headroom, which is shared with every other curator", () => {
    expect(withdrawableNow({...base, headroom: 40n})).toBe(40n);
  });
  it("is zero while the class is frozen on an unresolved default, whatever the headroom", () => {
    expect(withdrawableNow({...base, unresolvedDefaults: 1n})).toBe(0n);
  });
  it("is zero while a global pause or custody interlock blocks exits", () => {
    expect(withdrawableNow(base, true)).toBe(0n);
  });
  it("mirrors the live mainnet class 2 state: 100 posted, 100 required, nothing withdrawable", () => {
    expect(withdrawableNow({posted: 100n * 10n ** 18n, headroom: 0n, unresolvedDefaults: 0n})).toBe(0n);
  });
});

describe("needsAllowance", () => {
  it("never asks for an approval with no amount", () => {
    expect(needsAllowance(null, 0n)).toBe(false);
    expect(needsAllowance(0n, 0n)).toBe(false);
  });
  it("asks when the allowance is short or unknown", () => {
    expect(needsAllowance(10n, 9n)).toBe(true);
    expect(needsAllowance(10n, undefined)).toBe(true);
  });
  it("does not ask when the allowance covers the amount", () => {
    expect(needsAllowance(10n, 10n)).toBe(false);
  });
});

describe("classNotice", () => {
  it("names the default freeze first", () => {
    expect(classNotice({...base, unresolvedDefaults: 2n})).toMatch(/in default/);
  });
  it("explains a fully required posting", () => {
    expect(classNotice({...base, headroom: 0n})).toMatch(/nothing is withdrawable/);
  });
  it("says nothing when there is nothing to flag, including for an empty posting", () => {
    expect(classNotice(base)).toBeNull();
    expect(classNotice({...base, posted: 0n, headroom: 0n})).toBeNull();
  });
});
